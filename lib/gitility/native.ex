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
  def open_local(_path, _opts), do: :erlang.nif_error(:nif_not_loaded)
  def static_from_objects(_objects, _hash), do: :erlang.nif_error(:nif_not_loaded)
  def snapshot_open(_resource, _oid, _limits), do: :erlang.nif_error(:nif_not_loaded)
  def odb_header(_resource, _oid, _limits), do: :erlang.nif_error(:nif_not_loaded)
  def odb_read(_resource, _oid, _max_bytes, _limits), do: :erlang.nif_error(:nif_not_loaded)

  def odb_read_many(_resource, _oids, _max_total_bytes, _limits),
    do: :erlang.nif_error(:nif_not_loaded)

  def list_tree(_resource, _commit_oid, _tree_oid, _opts, _limits),
    do: :erlang.nif_error(:nif_not_loaded)

  def read_file(_resource, _commit_oid, _tree_oid, _path, _opts, _limits),
    do: :erlang.nif_error(:nif_not_loaded)

  def peel(_resource, _oid, _to, _limits), do: :erlang.nif_error(:nif_not_loaded)
  def error_codes(), do: :erlang.nif_error(:nif_not_loaded)
end
