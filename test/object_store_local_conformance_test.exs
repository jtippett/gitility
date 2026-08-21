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

  test "sweep removes aged random current and key temps but preserves fresh ones" do
    scratch = Gitility.ObjectStore.Conformance.scratch_directory()
    on_exit(fn -> File.rm_rf(scratch) end)

    root = Path.join(scratch, "store")
    assert {:ok, state} = Local.init(root: root)
    key = "sweep/random-temps"
    object_directory = Path.join([root, "objects", Local.key_hash(key)])
    File.mkdir!(object_directory)

    aged_current = Path.join(object_directory, "current.tmp-#{String.duplicate("a", 32)}")
    aged_key = Path.join(object_directory, "key.tmp-#{String.duplicate("b", 32)}")
    fresh_current = Path.join(object_directory, "current.tmp-#{String.duplicate("c", 32)}")
    fresh_key = Path.join(object_directory, "key.tmp-#{String.duplicate("d", 32)}")
    aged_directory = Path.join(object_directory, "current.tmp-#{String.duplicate("e", 32)}")

    Enum.each([aged_current, aged_key, fresh_current, fresh_key], &File.write!(&1, "temp"))
    File.mkdir!(aged_directory)
    Enum.each([aged_current, aged_key, aged_directory], &age_path!/1)

    assert :ok = Local.force_sweep(state, key)
    refute File.exists?(aged_current)
    refute File.exists?(aged_key)
    assert File.regular?(fresh_current)
    assert File.regular?(fresh_key)
    assert File.dir?(aged_directory)
  end

  test "sweep preserves an aged claimed version through stray messages until release" do
    scratch = Gitility.ObjectStore.Conformance.scratch_directory()
    on_exit(fn -> File.rm_rf(scratch) end)

    root = Path.join(scratch, "store")
    assert {:ok, state} = Local.init(root: root)
    key = "sweep/claimed-version"
    version = String.duplicate("a", 64)
    version_path = Local.version_path(state, key, version)
    File.mkdir_p!(version_path)
    age_path!(version_path)

    server = GenServer.whereis(Local.server(state))
    assert is_pid(server)
    ref = make_ref()
    assert :ok = GenServer.call(server, {:hold, ref})
    assert :ok = GenServer.call(server, {:claim, ref, version})

    send(server, {:stray, make_ref()})

    assert %{claimed_versions: [^version], hold_count: 1} =
             LocalServer.debug_state(server)

    assert GenServer.whereis(Local.server(state)) == server

    assert :ok = Local.force_sweep(state, key)
    assert File.dir?(version_path)

    assert :ok = GenServer.call(server, {:release, ref})
    assert :ok = Local.force_sweep(state, key)
    refute File.exists?(version_path)
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

  test "put holds a short-idle server through slow preparation" do
    scratch = Gitility.ObjectStore.Conformance.scratch_directory()
    on_exit(fn -> File.rm_rf(scratch) end)

    root = Path.join(scratch, "store")
    source = Path.join(scratch, "source")
    File.write!(source, "slow preparation")
    parent = self()
    server_name = LocalServer.name(Path.expand(root))

    before_put = fn ->
      send(parent, {:put_server, :before_put, GenServer.whereis(server_name)})
      :ok
    end

    before_commit = fn ->
      server = GenServer.whereis(server_name)

      send(
        parent,
        {:put_server, :before_commit, server, LocalServer.debug_state(server)}
      )

      Process.sleep(350)
      server = GenServer.whereis(server_name)

      send(
        parent,
        {:put_server, :after_sleep, server, LocalServer.debug_state(server)}
      )

      :ok
    end

    after_commit = fn ->
      send(parent, {:put_server, :after_commit, self()})
      :ok
    end

    assert {:ok, state} =
             Local.init(
               root: root,
               test_hooks: %{
                 idle_timeout: 100,
                 before_put: before_put,
                 before_commit: before_commit,
                 after_commit: after_commit
               }
             )

    assert {:ok, %{etag: _etag}} =
             Local.put(state, source, "idle/held-put",
               timeout: 5_000,
               if_match: :none,
               metadata: %{},
               content_type: @content_type
             )

    assert_receive {:put_server, :before_put, server}
    assert is_pid(server)

    assert_receive {:put_server, :before_commit, ^server,
                    %{claimed_versions: [version], hold_count: 1, idle_timeout: 100}}

    assert File.dir?(Local.version_path(state, "idle/held-put", version))

    assert_receive {:put_server, :after_sleep, ^server,
                    %{claimed_versions: [^version], hold_count: 1, idle_timeout: 100}}

    assert_receive {:put_server, :after_commit, ^server}
  end

  test "with_test_hooks rejects an idle timeout for an existing server" do
    scratch = Gitility.ObjectStore.Conformance.scratch_directory()
    on_exit(fn -> File.rm_rf(scratch) end)

    root = Path.join(scratch, "store")
    assert {:ok, state} = Local.init(root: root, test_hooks: %{idle_timeout: 5_000})
    server = GenServer.whereis(Local.server(state))
    assert is_pid(server)
    assert %{idle_timeout: 5_000} = LocalServer.debug_state(server)

    assert Local.with_test_hooks(state, %{idle_timeout: 1}) == state
    assert %{idle_timeout: 5_000} = LocalServer.debug_state(server)
  end

  test "put caller death releases its monitored server hold" do
    scratch = Gitility.ObjectStore.Conformance.scratch_directory()
    on_exit(fn -> File.rm_rf(scratch) end)

    root = Path.join(scratch, "store")
    source = Path.join(scratch, "source")
    File.write!(source, "killed preparation")
    parent = self()
    server_name = LocalServer.name(Path.expand(root))

    before_commit = fn ->
      server = GenServer.whereis(server_name)
      send(parent, {:held_put, self(), server})
      receive do: (:never -> :ok)
    end

    assert {:ok, state} =
             Local.init(
               root: root,
               test_hooks: %{idle_timeout: 100, before_commit: before_commit}
             )

    caller =
      spawn(fn ->
        result =
          Local.put(state, source, "idle/killed-put",
            timeout: 5_000,
            if_match: :none,
            metadata: %{},
            content_type: @content_type
          )

        send(parent, {:killed_put_result, result})
      end)

    caller_monitor = Process.monitor(caller)
    assert_receive {:held_put, holder, server}, 1_000
    assert is_pid(holder)
    assert is_pid(server)

    assert %{hold_count: 1, monitored_pids: monitored_pids} =
             LocalServer.debug_state(server)

    assert holder in monitored_pids
    server_monitor = Process.monitor(server)
    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 1_000
    assert_receive {:DOWN, ^server_monitor, :process, ^server, :normal}, 1_000
    refute_receive {:killed_put_result, _result}
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
