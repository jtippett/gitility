defmodule Gitility.Bundle.Supervisor do
  @moduledoc false

  use Supervisor

  @odb_child Gitility.Bundle.PackFetch
  @refs_child Gitility.Bundle.RefDB

  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> Supervisor.start_link(__MODULE__, opts)
      name -> Supervisor.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl Supervisor
  def init(opts) do
    id = make_ref()
    path = Keyword.fetch!(opts, :path)
    toc = Keyword.fetch!(opts, :toc)
    hash = toc.hash_algorithm
    runtime = Keyword.fetch!(opts, :runtime)
    concurrency = Keyword.fetch!(opts, :concurrency)
    request_timeout = Keyword.fetch!(opts, :request_timeout)

    odb_name = {:global, {__MODULE__, id, :odb}}
    refs_name = {:global, {__MODULE__, id, :refs}}

    packfetch_opts = [
      backend: {Gitility.Bundle.RangeBackend, {:pinned, path, toc}},
      into: Keyword.fetch!(opts, :into),
      name: odb_name,
      hash: hash,
      concurrency: concurrency,
      chunk_bytes: Keyword.fetch!(opts, :chunk_bytes),
      request_timeout: request_timeout,
      verify: Keyword.fetch!(opts, :verify),
      runtime: runtime,
      limits: Keyword.fetch!(opts, :limits),
      max_hydration_bytes: Keyword.fetch!(opts, :max_hydration_bytes),
      max_bytes: Keyword.fetch!(opts, :max_bytes)
    ]

    ref_opts = [
      backend: {Gitility.Bundle.RefBackend, {:pinned, path, toc}},
      name: refs_name,
      runtime: runtime,
      concurrency: concurrency,
      request_timeout: request_timeout
    ]

    children = [
      Supervisor.child_spec({Gitility.ODB.PackFetch, packfetch_opts}, id: @odb_child),
      Supervisor.child_spec({Gitility.RefDB, ref_opts}, id: @refs_child)
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc false
  def child_ids, do: {@odb_child, @refs_child}
end
