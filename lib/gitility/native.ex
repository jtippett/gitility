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
  def runtime_start(_config), do: :erlang.nif_error(:nif_not_loaded)
  def runtime_shutdown(_runtime), do: :erlang.nif_error(:nif_not_loaded)
  def runtime_stats(_runtime), do: :erlang.nif_error(:nif_not_loaded)
  def open_local(_path, _opts), do: :erlang.nif_error(:nif_not_loaded)
  def static_from_objects(_objects, _hash), do: :erlang.nif_error(:nif_not_loaded)
  def provider_store_new(_hash, _opts), do: :erlang.nif_error(:nif_not_loaded)
  def packfetch_store_new(_hash, _opts), do: :erlang.nif_error(:nif_not_loaded)
  def layered_store_new(_stores, _cache, _cache_index), do: :erlang.nif_error(:nif_not_loaded)
  def provider_reply(_request, _reply), do: :erlang.nif_error(:nif_not_loaded)
  def range_reply(_request, _reply), do: :erlang.nif_error(:nif_not_loaded)
  def provider_failed(_store), do: :erlang.nif_error(:nif_not_loaded)
  def provider_refresh(_store), do: :erlang.nif_error(:nif_not_loaded)
  def packfetch_stats(_store), do: :erlang.nif_error(:nif_not_loaded)
  def packfetch_hydrate(_runtime, _store, _limits), do: :erlang.nif_error(:nif_not_loaded)
  def packfetch_refresh(_runtime, _store, _limits), do: :erlang.nif_error(:nif_not_loaded)

  def job_submit_snapshot_open(_runtime, _resource, _oid, _limits),
    do: :erlang.nif_error(:nif_not_loaded)

  def job_submit_odb_header(_runtime, _resource, _oid, _limits),
    do: :erlang.nif_error(:nif_not_loaded)

  def job_submit_odb_read(_runtime, _resource, _oid, _max_bytes, _limits),
    do: :erlang.nif_error(:nif_not_loaded)

  def job_submit_odb_read_many(_runtime, _resource, _oids, _max_total_bytes, _limits),
    do: :erlang.nif_error(:nif_not_loaded)

  def job_submit_list_tree(
        _runtime,
        _resource,
        _commit_oid,
        _tree_oid,
        _opts,
        _limits,
        _detach
      ),
      do: :erlang.nif_error(:nif_not_loaded)

  def job_submit_read_file(
        _runtime,
        _resource,
        _commit_oid,
        _tree_oid,
        _path,
        _opts,
        _limits,
        _detach
      ),
      do: :erlang.nif_error(:nif_not_loaded)

  def job_submit_peel(_runtime, _resource, _oid, _to, _limits),
    do: :erlang.nif_error(:nif_not_loaded)

  def job_register_waiter(_job), do: :erlang.nif_error(:nif_not_loaded)
  def job_deregister_waiter(_job), do: :erlang.nif_error(:nif_not_loaded)
  def job_cancel(_job), do: :erlang.nif_error(:nif_not_loaded)
  def job_state(_job), do: :erlang.nif_error(:nif_not_loaded)
  def job_take_result(_job), do: :erlang.nif_error(:nif_not_loaded)
  def error_codes(), do: :erlang.nif_error(:nif_not_loaded)
end
