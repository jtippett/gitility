defmodule GitilityTest do
  use ExUnit.Case, async: true

  test "native library loads and responds" do
    assert Gitility.ping() == :pong
  end
end
