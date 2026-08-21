defmodule Gitility.Error do
  @moduledoc """
  The normalized error type for every Gitility operation.

  Normal failures return `{:error, %Gitility.Error{}}` — the public API does
  not raise for repository data, missing objects, timeouts, or backend
  failures. Callers branch on `code` and `retryable`; backend-specific
  reasons appear only in a sanitized `cause`.

  The struct is also an exception, so `!`-variants and truly exceptional
  paths can `raise` it directly.

  ## Stable error codes

  ```text
  invalid_argument          invalid_oid              invalid_path
  invalid_cursor            unsupported_hash         unsupported_operation
  unsupported_regex         not_a_commit             not_a_tree
  not_a_blob                ref_not_found            ambiguous_prefix
  not_found                 missing_object           shallow_boundary
  malformed_object          malformed_bundle        malformed_ref
  hash_mismatch             pack_checksum_mismatch   index_checksum_mismatch
  object_too_large          budget_exceeded          result_too_large
  timeout                   await_timeout            cancelled
  busy                      conflict                 authentication_failed
  network_error             cleanup_failed           credentials_unavailable
  provider_down             provider_timeout         provider_protocol_error
  backend_error             runtime_mismatch         internal_error
  ```

  Two timeouts are deliberately distinct: `:await_timeout` means
  `Gitility.Job.await/2` gave up waiting but **the job is still running**;
  `:timeout` means the job's own budget expired and the work was cancelled.
  """

  @codes ~w(
    invalid_argument invalid_oid invalid_path invalid_cursor
    unsupported_hash unsupported_operation unsupported_regex
    not_a_commit not_a_tree not_a_blob ref_not_found ambiguous_prefix
    not_found missing_object shallow_boundary malformed_object malformed_bundle malformed_ref
    hash_mismatch pack_checksum_mismatch index_checksum_mismatch
    object_too_large budget_exceeded result_too_large
    timeout await_timeout cancelled busy conflict
    authentication_failed network_error cleanup_failed credentials_unavailable
    provider_down provider_timeout provider_protocol_error backend_error
    runtime_mismatch internal_error
  )a

  @enforce_keys [:code, :message]
  defexception [:code, :message, :operation, :cause, retryable: false, details: %{}]

  @typedoc "One of the stable error codes — see the moduledoc."
  @type code :: unquote(Enum.reduce(@codes, &{:|, [], [&1, &2]}))

  @type t :: %__MODULE__{
          code: code(),
          message: String.t(),
          operation: atom() | nil,
          retryable: boolean(),
          details: map(),
          cause: term()
        }

  @doc "All stable error codes."
  @spec codes() :: [code()]
  def codes, do: @codes

  @doc """
  Builds an error. Used pervasively inside Gitility; also handy in backend
  implementations that want to surface normalized errors.
  """
  @spec new(code(), String.t(), keyword()) :: t()
  def new(code, message, opts \\ []) when code in @codes and is_binary(message) do
    struct!(__MODULE__, [code: code, message: message] ++ opts)
  end

  @impl Exception
  def message(%__MODULE__{code: code, message: message, operation: nil}),
    do: "#{message} (#{code})"

  def message(%__MODULE__{code: code, message: message, operation: op}),
    do: "#{message} (#{code} in #{op})"
end
