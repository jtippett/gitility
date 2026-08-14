defmodule Gitility.Native do
  @moduledoc false
  @version Mix.Project.config()[:version]

  use RustlerPrecompiled,
    otp_app: :gitility,
    crate: "gitility",
    base_url: "https://github.com/jtippett/gitility/releases/download/v#{@version}",
    version: @version,
    targets: ~w(
      aarch64-apple-darwin
      x86_64-apple-darwin
      x86_64-unknown-linux-gnu
      aarch64-unknown-linux-gnu
    ),
    force_build: System.get_env("GITILITY_BUILD") in ["1", "true"]

  def ping(), do: :erlang.nif_error(:nif_not_loaded)
end
