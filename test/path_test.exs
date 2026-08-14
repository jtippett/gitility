defmodule Gitility.PathTest do
  use ExUnit.Case, async: true

  alias Gitility.Path

  doctest Gitility.Path

  describe "encode/decode round trip" do
    test "plain ASCII is identity" do
      assert Path.encode("lib/acme/widget.ex") == "lib/acme/widget.ex"
    end

    test "valid multibyte UTF-8 passes through" do
      assert Path.encode("docs/café/日本語.md") == "docs/café/日本語.md"
    end

    test "percent signs are escaped so the encoding stays unambiguous" do
      assert Path.encode("a%b") == "a%25b"
      assert Path.decode("a%25b") == "a%b"
    end

    test "invalid UTF-8, control bytes, and NUL round-trip exactly" do
      for original <- [
            <<"caf", 0xE9, ".txt">>,
            <<0xFF, 0xFE, "name">>,
            "tab\there",
            <<"nul", 0, "byte">>,
            <<0xC3>>,
            :crypto.strong_rand_bytes(64)
          ] do
        encoded = Path.encode(original)
        assert String.valid?(encoded), "encode must produce valid UTF-8"
        assert Path.decode(encoded) == original
      end
    end
  end

  describe "display/1" do
    test "valid UTF-8 is unchanged" do
      assert Path.display("docs/café.md") == "docs/café.md"
    end

    test "invalid bytes become U+FFFD and the result is printable" do
      displayed = Path.display(<<"caf", 0xE9, ".txt">>)
      assert String.valid?(displayed)
      assert displayed == "caf�.txt"
    end
  end
end
