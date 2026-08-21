defmodule Gitility.Repository do
  @moduledoc """
  A repository is just an ODB plus an optional RefDB.

  It exists to resolve *selectors* — names for commits — into pinned
  `Gitility.Snapshot`s. Nothing else in the library takes a repository:
  every query takes a snapshot, and a snapshot needs only an ODB and a
  commit ID.

  `init_bare/2` creates a SHA-1 bare repository with automatic garbage
  collection and maintenance disabled. Every bare directory created by
  Gitility has that gc-safe configuration; Gitility does not retrofit or
  otherwise change repositories it did not create. Initialisation shares the
  expanded-path lease used by fetch, publish, and restore; contention returns
  retryable `:busy` immediately.

  Opening is intentionally cheap. The first query in a fresh process also
  starts and warms the native runtime and may take roughly 700 ms; subsequent
  queries reuse it.

  ## Selectors

  Safe selectors resolve a name through the repository's stores:

      {:oid, oid_or_hex}       # no refs needed
      {:ref, "refs/pull/481/head"}
      {:branch, "main"}        # expands to refs/heads/main
      {:tag, "v1.2.0"}         # expands to refs/tags/…, peels annotated tags
      :head

  `{:revspec, string}` is reserved for a future opt-in advanced selector.
  Gitility 0.x always rejects it with `:unsupported_operation`.
  """

  alias Gitility.{Error, Native, NativeSupport, ODB, OID, RefDB, RefTarget, Snapshot}
  alias Gitility.Fetch.Locks

  @init_lease_timeout 600_000

  @typedoc "A repository handle: object store plus optional ref store."
  @type t :: %__MODULE__{
          odb: ODB.t(),
          refs: RefDB.t() | nil,
          ref_error: Error.t() | nil
        }

  @enforce_keys [:odb]
  defstruct [:odb, :refs, :ref_error]

  @typedoc "A commit selector — see the moduledoc."
  @type selector ::
          {:oid, OID.t() | String.t()}
          | {:ref, binary()}
          | {:branch, binary()}
          | {:tag, binary()}
          | :head
          | {:revspec, String.t()}

  @doc """
  Creates a gc-safe bare SHA-1 repository.

  The destination must be absent or an empty directory. Creation is not
  idempotent: a non-empty destination is rejected and never modified. Parent
  directories are created as needed. `hash: :sha256` is reported as
  `:unsupported_hash` before the filesystem is touched. The `:gitility`
  application must be started so creation can acquire the shared
  `Gitility.Fetch.Locks` lease; if that process is not running, creation
  returns a non-retryable `:backend_error`.
  """
  @spec init_bare(Path.t(), keyword()) :: :ok | {:error, Error.t()}
  def init_bare(path, opts \\ []) do
    with :ok <- validate_init_path(path),
         {:ok, options} <- validate_init_options(opts),
         :ok <- validate_init_hash(options.hash),
         expanded <- Path.expand(path),
         :ok <- validate_init_destination(expanded),
         :ok <- acquire_init_lease(expanded) do
      try do
        case Native.repo_init_bare(expanded, options.hash) do
          :ok -> :ok
          {:error, error} -> {:error, NativeSupport.nif_error(error, :repository_init_bare)}
        end
      after
        release_init_lease(expanded)
      end
    end
  end

  @doc """
  Opens a local repository directory — bare or normal, though queries never
  read worktree files either way.

  ## Options

    * `:require_bare` — reject a non-bare repository (default `false`).
    * `:object_cache_bytes` — native object cache ceiling (default 64 MiB).
    * `:verify_pack_checksums` — deep-check pack and index checksums before
      the first object read (default `false`).
    * `:runtime` — the `Gitility.Runtime` to attach to (default: shared).

  ## Example

      {:ok, repo} =
        Gitility.Repository.open("/srv/git/acme/widgets.git", require_bare: true)

      {:ok, snapshot} = Gitility.Repository.snapshot(repo, {:branch, "main"})
  """
  @spec open(Path.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def open(path, opts \\ []) do
    opts =
      Keyword.validate!(opts,
        require_bare: false,
        object_cache_bytes: 64 * 1024 * 1024,
        verify_pack_checksums: false,
        runtime: :default
      )

    unless is_binary(path) do
      raise ArgumentError, "expected repository path to be a binary"
    end

    require_bare = NativeSupport.boolean_option!(opts, :require_bare)
    verify_pack_checksums = NativeSupport.boolean_option!(opts, :verify_pack_checksums)

    _object_cache_bytes = opts[:object_cache_bytes]

    with {:ok, runtime, _runtime_resource} <-
           NativeSupport.runtime_and_resource(opts[:runtime]) do
      case Native.open_local(path, %{
             require_bare: require_bare,
             verify_pack_checksums: verify_pack_checksums
           }) do
        {:ok, {resource, ref_resource, hash, ref_error}} ->
          odb = %ODB{kind: :local, ref: resource, hash: hash, runtime: runtime}

          refs =
            if ref_resource,
              do: %RefDB{kind: :local, ref: ref_resource, runtime: runtime},
              else: nil

          ref_error =
            if ref_error,
              do: NativeSupport.nif_error(ref_error, :repository_open_refs),
              else: nil

          {:ok, %__MODULE__{odb: odb, refs: refs, ref_error: ref_error}}

        {:error, error} ->
          {:error, NativeSupport.nif_error(error, :repository_open)}
      end
    end
  end

  @doc """
  Composes independently-created stores into a repository. The stores must
  share a runtime (`:runtime_mismatch` otherwise).

  Store identity is otherwise deliberately not compared. Cross-repository
  composition — for example, refs from one repository with an ODB from
  another — is the caller's responsibility and is not detected by Gitility.

  ## Options

    * `:odb` (required) — a `Gitility.ODB` handle.
    * `:refs` — a `Gitility.RefDB` handle; omit for an ODB-only repository
      (only `{:oid, _}` selectors will resolve).
  """
  @spec from_stores(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def from_stores(stores) do
    stores = Keyword.validate!(stores, odb: nil, refs: nil)

    case {stores[:odb], stores[:refs]} do
      {%ODB{} = odb, nil} ->
        {:ok, %__MODULE__{odb: odb, refs: nil, ref_error: nil}}

      {%ODB{} = odb, %RefDB{} = refs} when odb.runtime == refs.runtime ->
        {:ok, %__MODULE__{odb: odb, refs: refs, ref_error: nil}}

      {%ODB{}, %RefDB{}} ->
        {:error,
         Error.new(:runtime_mismatch, "object and reference stores use different runtimes",
           operation: :repository_from_stores
         )}

      {nil, _refs} ->
        NativeSupport.invalid_argument(":odb is required")

      {_odb, _refs} ->
        NativeSupport.invalid_argument(
          ":odb must be a Gitility.ODB and :refs must be a Gitility.RefDB or nil"
        )
    end
  end

  @doc """
  Resolves a selector and pins it as an immutable snapshot.

  Resolution happens once, here: the returned snapshot records the commit
  and root tree IDs and never moves, no matter what the underlying refs do
  afterwards.
  """
  @spec snapshot(t(), selector(), keyword()) :: {:ok, Snapshot.t()} | {:error, Error.t()}
  def snapshot(repo, selector, opts \\ [])

  def snapshot(%__MODULE__{odb: odb}, {:oid, oid}, opts) do
    opts = Keyword.validate!(opts, limits: nil)
    Snapshot.open(odb, oid, opts)
  end

  def snapshot(%__MODULE__{} = repo, {:ref, name}, opts) when is_binary(name) do
    snapshot_from_ref(repo, name, :direct, opts)
  end

  def snapshot(%__MODULE__{} = repo, {:branch, name}, opts) when is_binary(name) do
    snapshot_from_ref(repo, <<"refs/heads/", name::binary>>, :direct, opts)
  end

  def snapshot(%__MODULE__{} = repo, {:tag, name}, opts) when is_binary(name) do
    snapshot_from_ref(repo, <<"refs/tags/", name::binary>>, :peel, opts)
  end

  def snapshot(%__MODULE__{} = repo, :head, opts) do
    snapshot_from_ref(repo, "HEAD", :direct, opts)
  end

  def snapshot(%__MODULE__{}, {:revspec, revspec}, opts) when is_binary(revspec) do
    _opts = Keyword.validate!(opts, limits: nil)

    {:error,
     Error.new(
       :unsupported_operation,
       "advanced revspec selectors are unavailable in Gitility 0.x",
       operation: :repository_snapshot,
       details: %{capability: :revspec}
     )}
  end

  def snapshot(%__MODULE__{}, _selector, opts) do
    _opts = Keyword.validate!(opts, limits: nil)
    NativeSupport.invalid_argument("selector is not a supported safe selector")
  end

  defp snapshot_from_ref(%__MODULE__{refs: nil, ref_error: ref_error}, _name, _mode, opts) do
    _opts = Keyword.validate!(opts, limits: nil)

    reason =
      case ref_error do
        %Error{details: %{reason: reason}} when is_binary(reason) -> reason
        %Error{message: message} -> message
        nil -> "repository has no reference store"
      end

    {:error,
     Error.new(:unsupported_operation, "repository has no reference store",
       operation: :repository_snapshot,
       details: %{capability: :refs, reason: reason}
     )}
  end

  defp snapshot_from_ref(%__MODULE__{odb: odb, refs: refs}, name, mode, opts) do
    opts = Keyword.validate!(opts, limits: nil)

    case RefDB.resolve(refs, name, opts) do
      {:ok, :not_found} ->
        {:error,
         Error.new(:ref_not_found, "reference was not found",
           operation: :repository_snapshot,
           details: %{ref: name}
         )}

      {:ok, %RefTarget{kind: :direct} = target} ->
        oid = if mode == :peel, do: target.peeled || target.oid, else: target.oid

        if oid.algorithm != odb.hash do
          {:error,
           Error.new(:hash_mismatch, "reference target hash does not match the object store",
             operation: :repository_snapshot,
             details: %{ref: name, ref_hash: oid.algorithm, odb_hash: odb.hash}
           )}
        else
          if mode == :peel do
            Snapshot.open(odb, oid, opts)
          else
            Snapshot.open_direct(odb, oid, opts)
          end
        end

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp validate_init_path(path) when is_binary(path) and byte_size(path) > 0 do
    if String.valid?(path) and not String.contains?(path, <<0>>) do
      :ok
    else
      init_invalid("repository path must be valid UTF-8 without NUL bytes")
    end
  end

  defp validate_init_path(_path), do: init_invalid("repository path must be a non-empty binary")

  defp validate_init_options(opts) when is_list(opts) do
    if proper_list?(opts) do
      Enum.reduce_while(opts, {:ok, %{hash: :sha1}}, fn
        {:hash, value}, {:ok, options} when value in [:sha1, :sha256] ->
          {:cont, {:ok, %{options | hash: value}}}

        {key, _value}, _acc when is_atom(key) ->
          {:halt, init_invalid("unknown or invalid init_bare option: #{inspect(key)}")}

        _malformed, _acc ->
          {:halt, init_invalid("init_bare options must be a keyword list")}
      end)
    else
      init_invalid("init_bare options must be a keyword list")
    end
  end

  defp validate_init_options(_opts), do: init_invalid("init_bare options must be a keyword list")

  defp validate_init_hash(:sha1), do: :ok

  defp validate_init_hash(:sha256) do
    {:error,
     Error.new(:unsupported_hash, "SHA-256 bare repositories are not supported",
       operation: :repository_init_bare
     )}
  end

  defp validate_init_destination(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, %{type: :directory}} ->
        case File.ls(path) do
          {:ok, []} -> :ok
          {:ok, _entries} -> init_invalid("repository path must not exist or must be empty")
          {:error, reason} -> init_io_error("could not inspect repository directory", reason)
        end

      {:ok, _stat} ->
        init_invalid("repository path must not exist or must be an empty directory")

      {:error, reason} ->
        init_io_error("could not inspect repository path", reason)
    end
  end

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_tail), do: false

  defp acquire_init_lease(path) do
    try do
      case Locks.acquire(path, @init_lease_timeout) do
        :ok ->
          :ok

        {:error, %Error{} = error} ->
          {:error, %{error | operation: :repository_init_bare}}

        _bad_return ->
          init_lock_error()
      end
    rescue
      _exception -> init_lock_error()
    catch
      :exit, {:noproc, _details} -> init_application_not_started_error()
      :exit, :noproc -> init_application_not_started_error()
      :exit, _reason -> init_lock_error()
      _kind, _reason -> init_lock_error()
    end
  end

  defp release_init_lease(path) do
    try do
      _ = Locks.release(path)
      :ok
    rescue
      _exception -> :ok
    catch
      _kind, _reason -> :ok
    end
  end

  defp init_lock_error do
    {:error,
     Error.new(:backend_error, "fetch lock manager is unavailable",
       operation: :repository_init_bare,
       retryable: true
     )}
  end

  defp init_application_not_started_error do
    {:error,
     Error.new(
       :backend_error,
       "the :gitility application must be started (Gitility.Fetch.Locks is not running)",
       operation: :repository_init_bare,
       retryable: false
     )}
  end

  defp init_invalid(message) do
    {:error, Error.new(:invalid_argument, message, operation: :repository_init_bare)}
  end

  defp init_io_error(message, reason) do
    {:error,
     Error.new(:backend_error, message,
       operation: :repository_init_bare,
       retryable: reason in [:eagain, :eintr, :eio, :emfile, :enfile, :estale],
       details: %{reason: reason}
     )}
  end
end
