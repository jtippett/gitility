defmodule Gitility.Limits do
  @moduledoc """
  Resource budgets for a single operation.

  All operations accept `limits:` and merge it with these package defaults.
  Operation-specific options (`limit:`, `max_bytes:`, …) may **lower** but
  never raise hard runtime ceilings — passing an explicitly more permissive
  `%Gitility.Limits{}` is the only way to raise one, and that decision then
  sits visibly at the call site.

  A job's full budget includes cache misses and provider work: bytes fetched
  from a backend on your behalf count against `max_provider_bytes` even when
  a later cache hit would have been free.

  When a limit stops work early, the operation still succeeds: the result
  carries `truncated: true`, a cursor when continuation is possible, and the
  stopping limit in its stats — truncation is surfaced, never silent.
  """

  defstruct timeout_ms: 30_000,
            max_objects: 100_000,
            max_object_bytes: 4 * 1024 * 1024,
            max_total_object_bytes: 256 * 1024 * 1024,
            max_provider_requests: 500,
            max_provider_bytes: 256 * 1024 * 1024,
            max_tree_entries: 20_000,
            max_results: 1_000,
            max_diff_files: 1_000,
            max_diff_hunks: 10_000,
            max_diff_lines: 100_000,
            max_result_bytes: 8 * 1024 * 1024,
            max_delta_depth: 128

  @type t :: %__MODULE__{
          timeout_ms: pos_integer(),
          max_objects: pos_integer(),
          max_object_bytes: pos_integer(),
          max_total_object_bytes: pos_integer(),
          max_provider_requests: pos_integer(),
          max_provider_bytes: pos_integer(),
          max_tree_entries: pos_integer(),
          max_results: pos_integer(),
          max_diff_files: pos_integer(),
          max_diff_hunks: pos_integer(),
          max_diff_lines: pos_integer(),
          max_result_bytes: pos_integer(),
          max_delta_depth: pos_integer()
        }

  @doc """
  Builds a limits profile from overrides on the package defaults.

      iex> Gitility.Limits.new(timeout_ms: 5_000).timeout_ms
      5000
      iex> Gitility.Limits.new().max_objects
      100000
  """
  @spec new(keyword() | map()) :: t()
  def new(overrides \\ []), do: struct!(__MODULE__, overrides)
end
