defmodule Gitility.ErrorTest do
  use ExUnit.Case, async: true

  alias Gitility.Error

  test "the stable code list matches the design document" do
    design_codes = ~w(
      invalid_argument invalid_oid invalid_path invalid_cursor
      unsupported_hash unsupported_operation unsupported_regex
      not_a_commit not_a_tree not_a_blob ref_not_found ambiguous_prefix
      missing_object shallow_boundary malformed_object malformed_ref
      hash_mismatch pack_checksum_mismatch index_checksum_mismatch
      object_too_large budget_exceeded result_too_large
      timeout await_timeout cancelled busy
      authentication_failed network_error cleanup_failed credentials_unavailable
      provider_down provider_timeout provider_protocol_error backend_error
      runtime_mismatch internal_error
    )a

    assert Error.codes() == design_codes
  end

  test "new/3 builds errors and rejects unknown codes" do
    error = Error.new(:missing_object, "tree object unavailable", retryable: true)
    assert error.code == :missing_object
    assert error.retryable

    assert_raise FunctionClauseError, fn ->
      apply(Error, :new, [:no_such_code, "nope"])
    end
  end

  test "is an exception with a useful message" do
    error = Error.new(:timeout, "budget exhausted", operation: :search)
    assert Exception.message(error) == "budget exhausted (timeout in search)"
    assert_raise Error, fn -> raise error end
  end
end
