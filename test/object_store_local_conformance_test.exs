defmodule Gitility.ObjectStoreLocalConformanceTest do
  use Gitility.ObjectStore.Conformance, store: Gitility.ObjectStore.Local

  def store_setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "gitility-local-store-#{Gitility.ObjectStore.Conformance.random_segment()}"
      )

    Process.put({__MODULE__, :root}, root)
    root
  end

  def store_init_arg do
    [root: Process.get({__MODULE__, :root})]
  end

  def store_teardown(root) do
    Process.delete({__MODULE__, :root})
    File.rm_rf(root)
    :ok
  end
end
