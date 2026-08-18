defmodule Gitility.Bundle.RefBackend do
  @moduledoc """
  Direct-reference backend backed by a pinned bundle TOC.

  The parsed reference table is immutable for the lifetime of the backend.
  `refresh/1` is deliberately a no-op; opening the bundle again is the only
  way to move to a replacement generation.
  """

  @behaviour Gitility.RefDB.Backend

  alias Gitility.{Bundle.Format, Error, OID, Page, Ref, RefQuery, RefTarget}

  @impl true
  def init(path) when is_binary(path) do
    path = Path.expand(path)

    with {:ok, toc} <- Format.parse(path) do
      {:ok, table(toc)}
    end
  end

  def init({:pinned, path, toc}) when is_binary(path) and is_map(toc), do: {:ok, table(toc)}

  def init(_path),
    do: {:error, Error.new(:invalid_argument, "bundle path must be a binary")}

  @impl true
  def resolve(name, %{by_name: by_name}) when is_binary(name) do
    case Map.fetch(by_name, name) do
      {:ok, %Ref{target: target}} -> {:ok, target}
      :error -> {:ok, :not_found}
    end
  end

  def resolve(_name, _state), do: {:error, :invalid_ref_name}

  @impl true
  def list(%RefQuery{} = query, %{rows: rows, by_name: by_name}) do
    with {:ok, resume} <- decode_cursor(query.cursor),
         :ok <- validate_cursor(resume, query, by_name) do
      list_from(rows, query, resume)
    end
  end

  @impl true
  def refresh(_state), do: :ok

  defp table(toc) do
    rows =
      Enum.map(toc.refs, fn row ->
        target = %RefTarget{
          kind: :direct,
          oid: OID.new!(toc.hash_algorithm, row.target),
          symbolic_target: nil,
          peeled: if(row.peeled, do: OID.new!(toc.hash_algorithm, row.peeled))
        }

        %Ref{name: row.name, target: target}
      end)

    %{
      generation: toc.generation,
      rows: rows,
      by_name: Map.new(rows, &{&1.name, &1})
    }
  end

  defp list_from(rows, query, resume) do
    eligible =
      Enum.filter(rows, fn ref ->
        prefix_match?(ref.name, query.prefix) and (is_nil(resume) or ref.name > resume)
      end)

    items = Enum.take(eligible, query.limit)
    truncated = length(eligible) > length(items)

    next_cursor =
      if truncated do
        items
        |> List.last()
        |> Map.fetch!(:name)
        |> Base.url_encode64(padding: false)
      end

    {:ok, %Page{items: items, next_cursor: next_cursor, truncated: truncated}}
  end

  defp prefix_match?(_name, nil), do: true

  defp prefix_match?(name, prefix) do
    byte_size(name) >= byte_size(prefix) and
      binary_part(name, 0, byte_size(prefix)) == prefix
  end

  defp decode_cursor(nil), do: {:ok, nil}

  defp decode_cursor(cursor) when is_binary(cursor) do
    case Base.url_decode64(cursor, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid_cursor}
    end
  end

  defp decode_cursor(_cursor), do: {:error, :invalid_cursor}

  defp validate_cursor(nil, _query, _by_name), do: :ok

  defp validate_cursor(resume, query, by_name) do
    if Map.has_key?(by_name, resume) and prefix_match?(resume, query.prefix),
      do: :ok,
      else: {:error, :invalid_cursor}
  end
end
