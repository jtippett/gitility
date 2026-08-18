defmodule Gitility.Bundle.RefBackend do
  @moduledoc """
  Direct-reference backend backed by a pinned bundle TOC.

  The provider contract passes one state term to every callback, so an Agent
  is used as the backend's explicit atomic refresh cell. Reads copy one table
  snapshot per callback; `refresh/1` parses the replacement completely before
  swapping it in.
  """

  @behaviour Gitility.RefDB.Backend

  alias Gitility.{Bundle.Format, Error, OID, Page, Ref, RefQuery, RefTarget}

  @impl true
  def init(path) when is_binary(path) do
    path = Path.expand(path)

    with {:ok, toc} <- Format.parse(path),
         {:ok, state} <- pinned_state(path, toc) do
      {:ok, state}
    end
  end

  def init({:pinned, path, toc}) when is_binary(path) and is_map(toc),
    do: pinned_state(Path.expand(path), toc)

  def init(_path),
    do: {:error, Error.new(:invalid_argument, "bundle path must be a binary")}

  @impl true
  def resolve(name, %{agent: agent}) when is_binary(name) do
    Agent.get(agent, fn state ->
      case Map.fetch(state.by_name, name) do
        {:ok, %Ref{target: target}} -> {:ok, target}
        :error -> {:ok, :not_found}
      end
    end)
  end

  def resolve(_name, _state), do: {:error, :invalid_ref_name}

  @impl true
  def list(%RefQuery{} = query, %{agent: agent}) do
    with {:ok, resume} <- decode_cursor(query.cursor) do
      Agent.get(agent, fn state -> list_from(state.rows, query, resume) end)
    end
  end

  @impl true
  def refresh(%{path: path, agent: agent}) do
    with {:ok, toc} <- Format.parse(path) do
      Agent.update(agent, fn _old -> table(path, toc) end)
    end
  end

  @impl true
  def terminate(_reason, %{agent: agent}) do
    if Process.alive?(agent), do: Agent.stop(agent)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp table(path, toc) do
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
      path: path,
      generation: toc.generation,
      toc_sha256: toc.toc_sha256,
      rows: rows,
      by_name: Map.new(rows, &{&1.name, &1})
    }
  end

  defp pinned_state(path, toc) do
    with {:ok, agent} <- Agent.start_link(fn -> table(path, toc) end) do
      {:ok, %{path: path, agent: agent}}
    end
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
end
