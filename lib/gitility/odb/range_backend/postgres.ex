defmodule Gitility.ODB.RangeBackend.Postgres do
  @moduledoc """
  Optional Postgrex-backed range store using 1 MiB `bytea` chunks.

  Pack and index chunks are immutable rows keyed by
  `(pack_id, artifact, chunk_index)`. A singleton manifest row carries both
  the publisher generation column and the JSON manifest. `publish/3` inserts
  all missing chunks and updates the manifest in one database transaction, so
  readers observe the previous generation or the complete new one.

  Postgrex is an optional Gitility dependency. Applications that use this
  backend must include `{:postgrex, "~> 0.22.4"}`; calls return the explicit
  `:postgrex_not_available` error when it was omitted.

      {:ok, supervisor} =
        Gitility.ODB.PackFetch.start_link(
          backend: {Gitility.ODB.RangeBackend.Postgres,
                    [url: System.fetch_env!("DATABASE_URL")]},
          into: {:dir, "/var/cache/gitility"}
        )

  `init/1` accepts `connection: pid` or Postgrex connection options such as
  `url:`. The optional `prefix:` (default `"gitility_pack"`) is restricted to
  SQL identifier characters. `publish/3` takes a repository, either a pid,
  URL, or Postgrex options, and backend options such as `prefix:`.
  """

  @behaviour Gitility.ODB.RangeBackend

  alias Gitility.ODB.RangeBackend.LocalDirectory

  @chunk_bytes 1024 * 1024
  @default_prefix "gitility_pack"

  @impl true
  def init(opts) when is_list(opts) do
    with :ok <- ensure_postgrex(),
         {:ok, prefix} <- prefix(Keyword.get(opts, :prefix, @default_prefix)),
         {:ok, conn, owns?} <- open_init_connection(opts) do
      case initialize_connection(conn, prefix) do
        :ok ->
          {:ok, %{conn: conn, owns?: owns?, prefix: prefix}}

        {:error, _reason} = error ->
          close_owned(conn, owns?)
          error
      end
    end
  end

  def init(_opts), do: {:error, :invalid_postgres_options}

  @impl true
  def manifest(%{conn: conn, prefix: prefix}), do: fetch_manifest(conn, prefix)

  @impl true
  def read_ranges(ranges, %{conn: conn, prefix: prefix}) when is_list(ranges) do
    Enum.reduce_while(ranges, {:ok, %{}}, fn range, {:ok, replies} ->
      case read_range(conn, prefix, range) do
        {:ok, bytes} -> {:cont, {:ok, Map.put(replies, range, bytes)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @impl true
  def terminate(_reason, %{conn: conn, owns?: true}) do
    if Process.alive?(conn), do: GenServer.stop(conn)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @doc """
  Publishes a local repository into PostgreSQL.

  `connection` may be a Postgrex connection pid, a database URL, or Postgrex
  start options. `opts` currently accepts `prefix:`. A temporary local
  directory is used only by this explicit publisher to normalize loose-only
  repositories into ordinary pack/index files.
  """
  @spec publish(Path.t(), pid() | binary() | keyword(), keyword()) :: :ok | {:error, term()}
  def publish(repository, connection, opts \\ [])

  def publish(repository, connection, opts)
      when is_binary(repository) and is_list(opts) do
    temp =
      Path.join(
        System.tmp_dir!(),
        "gitility-postgres-publish-#{System.unique_integer([:positive, :monotonic])}"
      )

    # `temp` is bound outside the try so `after` can always clean it up (a
    # `rescue` on the def head cannot see body variables).
    try do
      with :ok <- ensure_postgrex(),
           {:ok, prefix} <- prefix(Keyword.get(opts, :prefix, @default_prefix)),
           {:ok, conn, owns?} <- open_publish_connection(connection) do
        try do
          with :ok <- ensure_schema(conn, prefix),
               :ok <- LocalDirectory.publish(repository, temp),
               {:ok, manifest_json} <- File.read(Path.join(temp, "manifest.json")),
               {:ok, manifest} <- Jason.decode(manifest_json),
               {:ok, :ok} <-
                 Postgrex.transaction(conn, fn transaction ->
                   publish_chunks(transaction, prefix, temp, manifest)
                   publish_manifest(transaction, prefix, manifest_json, manifest["generation"])
                 end) do
            :ok
          else
            {:error, reason} = error ->
              if is_exception(reason), do: {:error, Exception.message(reason)}, else: error
          end
        after
          close_owned(conn, owns?)
        end
      else
        {:error, reason} = error ->
          if is_exception(reason), do: {:error, Exception.message(reason)}, else: error
      end
    rescue
      exception -> {:error, Exception.message(exception)}
    after
      File.rm_rf(temp)
    end
  end

  def publish(_repository, _connection, _opts), do: {:error, :invalid_postgres_options}

  defp publish_chunks(conn, prefix, temp, manifest) do
    Enum.each(manifest["packs"], fn pack ->
      publish_artifact(conn, prefix, temp, pack["id"], "pack", pack["pack_key"])
      publish_artifact(conn, prefix, temp, pack["id"], "idx", pack["index_key"])
    end)
  end

  defp publish_artifact(conn, prefix, temp, pack_id, artifact, key) do
    sql = """
    INSERT INTO #{chunks_table(prefix)} (pack_id, artifact, chunk_index, bytes)
    VALUES ($1, $2, $3, $4)
    ON CONFLICT (pack_id, artifact, chunk_index) DO NOTHING
    """

    temp
    |> Path.join(key)
    |> File.stream!([], @chunk_bytes)
    |> Stream.with_index()
    |> Enum.each(fn {bytes, index} ->
      {:ok, _result} = Postgrex.query(conn, sql, [pack_id, artifact, index, bytes])
    end)
  end

  defp publish_manifest(conn, prefix, json, generation) do
    sql = """
    INSERT INTO #{manifest_table(prefix)} (singleton, generation, manifest_json)
    VALUES (TRUE, $1, $2)
    ON CONFLICT (singleton) DO UPDATE
      SET generation = EXCLUDED.generation,
          manifest_json = EXCLUDED.manifest_json
    """

    case Postgrex.query(conn, sql, [generation, json]) do
      {:ok, _result} -> :ok
      {:error, error} -> Postgrex.rollback(conn, error)
    end
  end

  defp fetch_manifest(conn, prefix) do
    sql = "SELECT manifest_json FROM #{manifest_table(prefix)} WHERE singleton = TRUE"

    with {:ok, %{rows: [[json]]}} <- Postgrex.query(conn, sql, []),
         {:ok, decoded} <- Jason.decode(json),
         {:ok, hash} <- decode_hash(decoded["hash"]),
         {:ok, packs} <- decode_descriptors(decoded["packs"]) do
      {:ok,
       %Gitility.PackManifest{
         version: decoded["version"],
         generation: decoded["generation"],
         hash: hash,
         packs: packs,
         loose: decoded["loose"] || []
       }}
    else
      {:ok, %{rows: []}} -> {:error, :manifest_not_published}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_manifest}
    end
  end

  defp decode_descriptors(packs) when is_list(packs) do
    try do
      {:ok,
       Enum.map(packs, fn pack ->
         %Gitility.PackDescriptor{
           id: Map.fetch!(pack, "id"),
           pack_key: Map.fetch!(pack, "pack_key"),
           index_key: Map.fetch!(pack, "index_key"),
           pack_size: Map.fetch!(pack, "pack_size"),
           index_size: Map.fetch!(pack, "index_size"),
           etag: Map.get(pack, "etag")
         }
       end)}
    rescue
      KeyError -> {:error, :invalid_manifest}
    end
  end

  defp decode_descriptors(_packs), do: {:error, :invalid_manifest}
  defp decode_hash("sha1"), do: {:ok, :sha1}
  defp decode_hash("sha256"), do: {:ok, :sha256}
  defp decode_hash(_hash), do: {:error, :invalid_hash}

  defp read_range(_conn, _prefix, %Gitility.ByteRange{length: 0}), do: {:ok, <<>>}

  defp read_range(conn, prefix, %Gitility.ByteRange{} = range)
       when is_integer(range.offset) and range.offset >= 0 and is_integer(range.length) and
              range.length > 0 do
    with {:ok, pack_id, artifact} <- parse_key(range.key),
         first = div(range.offset, @chunk_bytes),
         last = div(range.offset + range.length - 1, @chunk_bytes),
         sql =
           "SELECT chunk_index, bytes FROM #{chunks_table(prefix)} " <>
             "WHERE pack_id = $1 AND artifact = $2 AND chunk_index BETWEEN $3 AND $4 " <>
             "ORDER BY chunk_index",
         {:ok, %{rows: rows}} <- Postgrex.query(conn, sql, [pack_id, artifact, first, last]),
         true <- length(rows) == last - first + 1,
         combined = IO.iodata_to_binary(Enum.map(rows, fn [_index, bytes] -> bytes end)),
         inner = rem(range.offset, @chunk_bytes),
         true <- byte_size(combined) >= inner + range.length do
      {:ok, binary_part(combined, inner, range.length)}
    else
      false -> {:error, :short_read}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_range(_conn, _prefix, _range), do: {:error, :invalid_range}

  defp parse_key(key) when is_binary(key) do
    case Regex.run(~r/^packs\/pack-([0-9a-fA-F]{40}|[0-9a-fA-F]{64})\.(pack|idx)$/, key) do
      [_, id, artifact] -> {:ok, String.downcase(id), artifact}
      _other -> {:error, :invalid_key}
    end
  end

  defp parse_key(_key), do: {:error, :invalid_key}

  defp ensure_schema(conn, prefix) do
    statements = [
      """
      CREATE TABLE IF NOT EXISTS #{chunks_table(prefix)} (
        pack_id TEXT NOT NULL,
        artifact TEXT NOT NULL CHECK (artifact IN ('pack', 'idx')),
        chunk_index BIGINT NOT NULL CHECK (chunk_index >= 0),
        bytes BYTEA NOT NULL,
        PRIMARY KEY (pack_id, artifact, chunk_index)
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{manifest_table(prefix)} (
        singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
        generation TEXT NOT NULL,
        manifest_json TEXT NOT NULL
      )
      """
    ]

    Enum.reduce_while(statements, :ok, fn sql, :ok ->
      case Postgrex.query(conn, sql, []) do
        {:ok, _result} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp initialize_connection(conn, prefix) do
    with :ok <- ensure_schema(conn, prefix),
         {:ok, _manifest} <- fetch_manifest(conn, prefix) do
      :ok
    end
  end

  defp open_init_connection(opts) do
    case Keyword.get(opts, :connection) do
      conn when is_pid(conn) -> {:ok, conn, false}
      nil -> start_connection(Keyword.drop(opts, [:connection, :prefix]))
      _other -> {:error, :invalid_postgres_connection}
    end
  end

  defp open_publish_connection(conn) when is_pid(conn), do: {:ok, conn, false}
  defp open_publish_connection(url) when is_binary(url), do: start_connection(url: url)
  defp open_publish_connection(opts) when is_list(opts), do: start_connection(opts)
  defp open_publish_connection(_conn), do: {:error, :invalid_postgres_connection}

  defp start_connection(opts) do
    # Postgrex has no `url:` option (that is an Ecto convention). Translate a
    # `postgresql://` URL into Postgrex options here; a `?host=/dir` query
    # (libpq style) selects a Unix socket directory. Explicit Postgrex keys
    # given alongside `url:` win.
    opts =
      case Keyword.pop(opts, :url) do
        {nil, rest} -> rest
        {url, rest} -> Keyword.merge(url_to_postgrex_options(url), rest)
      end

    case Postgrex.start_link(opts) do
      {:ok, conn} -> {:ok, conn, true}
      {:error, reason} -> {:error, reason}
    end
  end

  defp close_owned(conn, true) do
    if Process.alive?(conn), do: GenServer.stop(conn)
    :ok
  end

  defp close_owned(_conn, false), do: :ok

  defp prefix(value) when is_binary(value) do
    if Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_]*$/, value) do
      {:ok, value}
    else
      {:error, :invalid_table_prefix}
    end
  end

  defp prefix(_value), do: {:error, :invalid_table_prefix}
  defp chunks_table(prefix), do: prefix <> "_chunks"
  defp manifest_table(prefix), do: prefix <> "_manifest"

  defp ensure_postgrex do
    if Code.ensure_loaded?(Postgrex) do
      :ok
    else
      {:error, :postgrex_not_available}
    end
  end

  @doc false
  def url_to_postgrex_options(url) when is_binary(url) do
    uri = URI.parse(url)
    query = if uri.query, do: URI.decode_query(uri.query), else: %{}

    {username, password} =
      case uri.userinfo do
        nil ->
          {nil, nil}

        info ->
          case String.split(info, ":", parts: 2) do
            [u, p] -> {URI.decode(u), URI.decode(p)}
            [u] -> {URI.decode(u), nil}
          end
      end

    database =
      case uri.path do
        nil -> nil
        "/" -> nil
        "/" <> db -> URI.decode(db)
      end

    host = query["host"] || uri.host

    # Postgrex requires :username (no libpq-style OS-user default). Mirror
    # libpq: fall back to the current OS user, which is what peer auth over
    # a Unix socket expects.
    username = username || System.get_env("PGUSER") || os_user()

    []
    |> put_present(:username, username)
    |> put_present(:password, password)
    |> put_present(:database, database)
    |> put_present(:port, uri.port)
    |> then(fn acc ->
      cond do
        is_binary(host) and String.starts_with?(host, "/") -> Keyword.put(acc, :socket_dir, host)
        is_binary(host) and host != "" -> Keyword.put(acc, :hostname, host)
        true -> acc
      end
    end)
  end

  defp os_user do
    case System.get_env("USER") do
      nil -> ~c"id -un" |> :os.cmd() |> to_string() |> String.trim()
      user -> user
    end
  end

  defp put_present(opts, _key, nil), do: opts
  defp put_present(opts, key, value), do: Keyword.put(opts, key, value)
end
