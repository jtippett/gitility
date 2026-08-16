defmodule Gitility.Differential.Allowlist do
  @moduledoc """
  Exact-case allowlisting for triaged canonical-Git divergences.

  `compare/4` records an allowlisted mismatch in the calling test process only
  when both its case id and operation/fixture/query context exactly match the
  triaged entry. Exact matches do not need an entry, and unknown or
  context-mismatched divergences fail immediately. Callers may additionally
  assert result-specific expectations stored on the returned entry.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  @allowlist_path Path.join(__DIR__, "allowlist.exs")
  @external_resource @allowlist_path
  @required_keys [
    :id,
    :operation,
    :fixture_repo,
    :query,
    :classification,
    :explanation,
    :git_version_triaged
  ]
  @context_keys [:operation, :fixture_repo, :query]
  @record_key {__MODULE__, :allowlisted_divergences}

  {allowlist_entries, _binding} = Code.eval_file(@allowlist_path)
  @entries allowlist_entries

  @spec entries() :: [map()]
  def entries, do: @entries

  @spec validate() :: :ok | {:error, binary()}
  def validate, do: validate_entries(entries())

  @spec validate_entries(term()) :: :ok | {:error, binary()}
  def validate_entries(entries) when is_list(entries) do
    with :ok <- validate_each(entries),
         :ok <- validate_unique_ids(entries) do
      :ok
    end
  end

  def validate_entries(_other), do: {:error, "allowlist must evaluate to a list"}

  @spec compare(term(), map(), term(), term()) :: :ok | {:allowlisted, map()}
  def compare(case_id, context, expected, actual) when is_map(context) do
    cond do
      expected == actual ->
        :ok

      entry = Enum.find(entries(), &(&1.id == case_id)) ->
        recorded_context = Map.take(entry, @context_keys)
        actual_context = Map.take(context, @context_keys)

        if recorded_context == actual_context do
          record(entry)
          IO.puts("ALLOWLISTED differential divergence: #{entry.id} (#{entry.operation})")
          {:allowlisted, entry}
        else
          flunk("""
          allowlist context mismatch for #{inspect(case_id)}
          recorded context: #{inspect(recorded_context, limit: :infinity)}
          actual context:   #{inspect(actual_context, limit: :infinity)}
          expected: #{inspect(expected, limit: :infinity)}
          actual:   #{inspect(actual, limit: :infinity)}
          """)
        end

      true ->
        flunk("""
        unallowlisted differential divergence for #{inspect(case_id)}
        expected: #{inspect(expected, limit: :infinity)}
        actual:   #{inspect(actual, limit: :infinity)}
        """)
    end
  end

  def compare(case_id, context, _expected, _actual) do
    flunk("""
    invalid differential context for #{inspect(case_id)}
    expected a map with #{inspect(@context_keys)}, got: #{inspect(context)}
    """)
  end

  @spec records() :: [map()]
  def records, do: Process.get(@record_key, []) |> Enum.reverse()

  @spec reset_records() :: :ok
  def reset_records do
    Process.delete(@record_key)
    :ok
  end

  defp validate_each(entries) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case validate_entry(entry) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_entry(entry) when is_map(entry) do
    missing = @required_keys -- Map.keys(entry)

    cond do
      missing != [] ->
        {:error, "allowlist entry is missing keys: #{inspect(missing)}"}

      not valid_id?(entry.id) ->
        {:error, "allowlist entry id must be a non-empty atom or binary"}

      not is_atom(entry.operation) ->
        {:error, "allowlist entry #{inspect(entry.id)} has an invalid operation"}

      not nonempty_binary?(entry.fixture_repo) ->
        {:error, "allowlist entry #{inspect(entry.id)} has no fixture repository"}

      is_nil(entry.query) ->
        {:error, "allowlist entry #{inspect(entry.id)} has no query"}

      not valid_id?(entry.classification) ->
        {:error, "allowlist entry #{inspect(entry.id)} has no classification"}

      not nonempty_binary?(entry.explanation) ->
        {:error, "allowlist entry #{inspect(entry.id)} has no explanation"}

      not valid_git_version?(entry.git_version_triaged) ->
        {:error, "allowlist entry #{inspect(entry.id)} has no valid triaged Git version"}

      not valid_expected_results?(Map.get(entry, :expected_results)) ->
        {:error, "allowlist entry #{inspect(entry.id)} has invalid expected results"}

      true ->
        :ok
    end
  end

  defp validate_entry(_entry), do: {:error, "every allowlist entry must be a map"}

  defp validate_unique_ids(entries) do
    ids = Enum.map(entries, & &1.id)

    if length(ids) == MapSet.size(MapSet.new(ids)) do
      :ok
    else
      {:error, "allowlist entry ids must be unique"}
    end
  end

  defp valid_id?(value) when is_atom(value), do: value not in [nil, false, true]
  defp valid_id?(value), do: nonempty_binary?(value)

  defp nonempty_binary?(value), do: is_binary(value) and byte_size(value) > 0

  defp valid_git_version?(version) when is_binary(version) do
    case Regex.run(~r/^\d+\.\d+(?:\.\d+)?(?:[-.][0-9A-Za-z]+)*$/, version) do
      nil -> false
      _match -> true
    end
  end

  defp valid_git_version?(_version), do: false

  defp valid_expected_results?(nil), do: true

  defp valid_expected_results?(%{git: git, gitility: gitility})
       when is_list(git) and is_list(gitility) do
    Enum.all?(git, &nonempty_binary?/1) and Enum.all?(gitility, &nonempty_binary?/1)
  end

  defp valid_expected_results?(_other), do: false

  defp record(entry) do
    Process.put(@record_key, [entry | Process.get(@record_key, [])])
  end
end
