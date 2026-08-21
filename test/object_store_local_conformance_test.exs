defmodule Gitility.ObjectStoreLocalConformanceTest do
  use Gitility.ObjectStore.Conformance, store: Gitility.ObjectStore.Local

  alias Gitility.ObjectStore.Local
  alias Gitility.ObjectStore.Local.Server, as: LocalServer

  @content_type "application/vnd.gitility.bundle"

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

  test "init preserves an existing root mode and follows a symlinked root" do
    scratch = Gitility.ObjectStore.Conformance.scratch_directory()
    on_exit(fn -> File.rm_rf(scratch) end)

    existing = Path.join(scratch, "existing")
    File.mkdir!(existing)
    File.chmod!(existing, 0o755)

    assert {:ok, _state} = Local.init(root: existing)
    assert Bitwise.band(File.stat!(existing).mode, 0o777) == 0o755

    target = Path.join(scratch, "target")
    linked = Path.join(scratch, "linked")
    File.mkdir!(target)
    File.ln_s!(target, linked)

    assert {:ok, state} = Local.init(root: linked)
    source = Path.join(scratch, "source")
    destination = Path.join(scratch, "destination")
    File.write!(source, "through symlink")

    assert {:ok, %{etag: etag}} =
             Local.put(state, source, "symlink/root",
               timeout: 5_000,
               if_match: :none,
               metadata: %{},
               content_type: @content_type
             )

    assert {:ok, %{etag: ^etag}} =
             Local.get(state, "symlink/root", destination, timeout: 5_000)

    assert File.read!(destination) == "through symlink"
  end

  test "a damaged key debug file is replaced atomically and current.tmp is untouched" do
    scratch = Gitility.ObjectStore.Conformance.scratch_directory()
    on_exit(fn -> File.rm_rf(scratch) end)

    root = Path.join(scratch, "store")
    assert {:ok, state} = Local.init(root: root)
    key = "debug/key"
    object_directory = Path.join([root, "objects", Local.key_hash(key)])
    File.mkdir!(object_directory)
    File.chmod!(object_directory, 0o700)
    File.write!(Path.join(object_directory, "key"), <<>>)
    File.write!(Path.join(object_directory, "current.tmp"), "decoy")
    source = Path.join(scratch, "source")
    File.write!(source, "body")

    assert {:ok, %{etag: _etag}} =
             Local.put(state, source, key,
               timeout: 5_000,
               if_match: :none,
               metadata: %{},
               content_type: @content_type
             )

    assert File.read!(Path.join(object_directory, "key")) == key
    assert File.read!(Path.join(object_directory, "current.tmp")) == "decoy"
    assert Path.wildcard(Path.join(object_directory, "key.tmp-*")) == []
  end

  test "sweep aborts a key when current is incomplete or unreadable" do
    scratch = Gitility.ObjectStore.Conformance.scratch_directory()
    on_exit(fn -> File.rm_rf(scratch) end)

    root = Path.join(scratch, "store")
    assert {:ok, state} = Local.init(root: root)
    key = "sweep/unreadable-current"
    first = Path.join(scratch, "first")
    second = Path.join(scratch, "second")
    File.write!(first, "first")
    File.write!(second, "second")

    assert {:ok, %{etag: first_etag}} =
             Local.put(state, first, key,
               timeout: 5_000,
               if_match: :none,
               metadata: %{},
               content_type: @content_type
             )

    assert {:ok, %{etag: _second_etag}} =
             Local.put(state, second, key,
               timeout: 5_000,
               if_match: first_etag,
               metadata: %{},
               content_type: @content_type
             )

    assert LocalServer.pin_count(Local.server(state)) == 0
    object_directory = Path.join([root, "objects", Local.key_hash(key)])
    versions = Path.wildcard(Path.join(object_directory, "v-*"))
    current = Path.join(object_directory, "current")
    current_version = File.read!(current)
    Enum.each(versions, &age_path!/1)
    File.write!(current, "short")

    assert :ok = Local.force_sweep(state, key)
    assert Enum.sort(Path.wildcard(Path.join(object_directory, "v-*"))) == Enum.sort(versions)

    File.write!(current, current_version)
    File.chmod!(current, 0o000)

    try do
      case File.read(current) do
        {:ok, _bytes} ->
          # The test process has permission-bypass privileges, so the short
          # read above remains the portable assertion for this environment.
          assert true

        {:error, _reason} ->
          assert :ok = Local.force_sweep(state, key)

          assert Enum.sort(Path.wildcard(Path.join(object_directory, "v-*"))) ==
                   Enum.sort(versions)
      end
    after
      File.chmod!(current, 0o600)
    end
  end

  test "an idle unpinned server exits and a later get revives it" do
    scratch = Gitility.ObjectStore.Conformance.scratch_directory()
    on_exit(fn -> File.rm_rf(scratch) end)

    root = Path.join(scratch, "store")
    assert {:ok, state} = Local.init(root: root)
    source = Path.join(scratch, "source")
    destination = Path.join(scratch, "destination")
    File.write!(source, "survives revival")

    assert {:ok, %{etag: _etag}} =
             Local.put(state, source, "idle/revival",
               timeout: 5_000,
               if_match: :none,
               metadata: %{},
               content_type: @content_type
             )

    server = GenServer.whereis(Local.server(state))
    assert is_pid(server)
    monitor = Process.monitor(server)
    send(server, :timeout)
    assert_receive {:DOWN, ^monitor, :process, ^server, :normal}, 1_000

    assert {:ok, %{bytes: 16}} =
             Local.get(state, "idle/revival", destination, timeout: 5_000)

    revived = GenServer.whereis(Local.server(state))
    assert is_pid(revived)
    refute revived == server
    assert File.read!(destination) == "survives revival"
  end

  defp age_path!(path) do
    old =
      DateTime.utc_now()
      |> DateTime.add(-2 * 60 * 60, :second)
      |> DateTime.to_naive()
      |> NaiveDateTime.to_erl()

    File.touch!(path, old)
  end
end
