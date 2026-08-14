defmodule Gitility.OIDTest do
  use ExUnit.Case, async: true

  alias Gitility.OID

  doctest Gitility.OID

  @sha1_hex "da39a3ee5e6b4b0d3255bfef95601890afd80709"
  @sha256_hex "473a0f4c3be8a93681a267e3b1e9a7dcda1185436fe141f7749120a303721813"

  describe "parse/1" do
    test "infers sha1 from 40 hex chars" do
      assert {:ok, %OID{algorithm: :sha1, bytes: bytes}} = OID.parse(@sha1_hex)
      assert byte_size(bytes) == 20
    end

    test "infers sha256 from 64 hex chars" do
      assert {:ok, %OID{algorithm: :sha256, bytes: bytes}} = OID.parse(@sha256_hex)
      assert byte_size(bytes) == 32
    end

    test "accepts uppercase, emits lowercase" do
      assert {:ok, oid} = OID.parse(String.upcase(@sha1_hex))
      assert OID.to_string(oid) == @sha1_hex
    end

    test "rejects abbreviations, junk, and non-hex" do
      for bad <- ["da39a3ee", "", "zz" <> binary_part(@sha1_hex, 2, 38), @sha1_hex <> "aa"] do
        assert {:error, %Gitility.Error{code: :invalid_oid}} = OID.parse(bad)
      end
    end
  end

  describe "new/2" do
    test "round-trips with parse" do
      {:ok, parsed} = OID.parse(@sha1_hex)
      assert {:ok, ^parsed} = OID.new(:sha1, parsed.bytes)
    end

    test "rejects wrong digest sizes" do
      assert {:error, %Gitility.Error{code: :invalid_oid}} = OID.new(:sha1, <<0::256>>)
      assert {:error, %Gitility.Error{code: :invalid_oid}} = OID.new(:sha256, <<0::160>>)
    end
  end

  test "String.Chars emits lowercase hex" do
    assert to_string(OID.parse!(@sha1_hex)) == @sha1_hex
  end

  test "inspect shows algorithm and hex, not raw bytes" do
    assert inspect(OID.parse!(@sha1_hex)) == "#Gitility.OID<sha1:#{@sha1_hex}>"
  end

  test "digest_size/1" do
    assert OID.digest_size(:sha1) == 20
    assert OID.digest_size(:sha256) == 32
  end
end
