defmodule Gitility.IdentityTest do
  use ExUnit.Case, async: true

  alias Gitility.Identity

  defp identity(tz) do
    %Identity{name: "A U Thor", email: "a@example.com", time: 1_700_000_000, tz: tz}
  end

  test "utc_offset parses positive and negative offsets" do
    assert {:ok, 36_000, false} = Identity.utc_offset(identity("+1000"))
    assert {:ok, -19_800, false} = Identity.utc_offset(identity("-0530"))
    assert {:ok, 0, false} = Identity.utc_offset(identity("+0000"))
  end

  test "utc_offset flags the -0000 unknown-offset encoding" do
    assert {:ok, 0, true} = Identity.utc_offset(identity("-0000"))
  end

  test "utc_offset rejects malformed timezone fields" do
    for tz <- ["", "1000", "+10", "+abcd", "UTC"] do
      assert {:error, %Gitility.Error{code: :malformed_object}} =
               Identity.utc_offset(identity(tz))
    end
  end

  test "to_datetime is UTC" do
    assert {:ok, datetime} = Identity.to_datetime(identity("+1000"))
    assert datetime.time_zone == "Etc/UTC"
    assert DateTime.to_unix(datetime) == 1_700_000_000
  end
end
