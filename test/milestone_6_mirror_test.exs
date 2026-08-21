defmodule Gitility.Milestone6MirrorTest.FakeStore do
  @moduledoc false

  @behaviour Gitility.ObjectStore

  @impl true
  def init(%{agent: agent} = state) when is_pid(agent) do
    Agent.update(agent, &Map.update(&1, :init_calls, 1, fn count -> count + 1 end))
    {:ok, state}
  end

  def init(_arg), do: {:error, {:adapter, :invalid_options}}

  @impl true
  def head(%{agent: agent}, key, _opts) do
    Agent.get(agent, fn state ->
      case get_in(state, [:objects, key]) do
        nil -> {:error, :not_found}
        object -> {:ok, Map.take(object, [:etag, :size, :metadata])}
      end
    end)
  end

  @impl true
  def get(%{agent: agent}, key, destination, _opts) do
    case Agent.get(agent, &get_in(&1, [:objects, key])) do
      nil ->
        {:error, :not_found}

      object ->
        part = destination <> ".part"

        with :ok <- File.write(part, object.bytes, [:binary]),
             :ok <- File.rename(part, destination) do
          {:ok,
           %{
             etag: object.etag,
             bytes: byte_size(object.bytes),
             metadata: object.metadata
           }}
        else
          {:error, _reason} -> {:error, {:adapter, :io}}
        end
    end
  end

  @impl true
  def put(%{agent: agent} = adapter, source, key, opts) do
    with {:ok, bytes} <- File.read(source) do
      Agent.get_and_update(agent, fn state ->
        current = get_in(state, [:objects, key])

        if precondition_matches?(current, Keyword.fetch!(opts, :if_match)) do
          sequence = Map.get(state, :sequence, 0) + 1
          etag = "fake-etag-#{sequence}"

          object = %{
            etag: etag,
            size: byte_size(bytes),
            bytes: bytes,
            metadata: Keyword.fetch!(opts, :metadata)
          }

          next =
            state
            |> Map.put(:sequence, sequence)
            |> Map.update(:put_calls, 1, fn count -> count + 1 end)

          case Map.get(adapter, :put_mode, :ok) do
            :ok ->
              {{:ok, %{etag: etag}}, put_in(next, [:objects, key], object)}

            :commit_then_timeout ->
              {{:error, {:transport, :timeout}}, put_in(next, [:objects, key], object)}

            :timeout ->
              {{:error, {:transport, :timeout}}, next}

            :precondition_failed ->
              {{:error, :precondition_failed}, next}
          end
        else
          {{:error, :precondition_failed}, state}
        end
      end)
    else
      {:error, _reason} -> {:error, {:adapter, :io}}
    end
  end

  defp precondition_matches?(nil, :none), do: true
  defp precondition_matches?(%{etag: etag}, etag), do: true
  defp precondition_matches?(_current, _if_match), do: false
end

defmodule Gitility.Milestone6MirrorTest.MissingCallbackStore do
  @moduledoc false

  def init(arg), do: {:ok, arg}
  def head(_state, _key, _opts), do: {:error, :not_found}
  def get(_state, _key, _destination, _opts), do: {:error, :not_found}
end

defmodule Gitility.Milestone6MirrorTest.HTTPStub do
  @moduledoc false

  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def child_spec(opts) do
    %{id: {__MODULE__, make_ref()}, start: {__MODULE__, :start_link, [opts]}}
  end

  def url(server), do: GenServer.call(server, :url)
  def requests(server), do: GenServer.call(server, :requests)

  @impl GenServer
  def init(opts) do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        ip: {127, 0, 0, 1},
        active: false,
        packet: :raw,
        reuseaddr: true
      ])

    {:ok, {_address, port}} = :inet.sockname(listener)
    state = %{listener: listener, mode: Keyword.fetch!(opts, :mode), requests: 0}
    server = self()
    acceptor = spawn_link(fn -> accept_loop(server, listener, state.mode) end)

    {:ok,
     Map.merge(state, %{
       acceptor: acceptor,
       url: "http://127.0.0.1:#{port}"
     })}
  end

  @impl GenServer
  def handle_call(:url, _from, state), do: {:reply, state.url, state}
  def handle_call(:requests, _from, state), do: {:reply, state.requests, state}

  @impl GenServer
  def handle_cast(:request, state), do: {:noreply, %{state | requests: state.requests + 1}}

  @impl GenServer
  def terminate(_reason, state) do
    :gen_tcp.close(state.listener)
    :ok
  end

  defp accept_loop(server, listener, mode) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        spawn_link(fn -> serve(server, socket, mode) end)
        accept_loop(server, listener, mode)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        accept_loop(server, listener, mode)
    end
  end

  defp serve(server, socket, mode) do
    _ = recv_headers(socket, <<>>)
    GenServer.cast(server, :request)

    case mode do
      {:status, status} -> send_response(socket, status, [])
      {:redirect, location} -> send_response(socket, 301, [{"Location", location}])
      :close -> :ok
      :stall -> Process.sleep(5_000)
    end

    :gen_tcp.close(socket)
  end

  defp recv_headers(socket, bytes) do
    if :binary.match(bytes, "\r\n\r\n") == :nomatch do
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, chunk} -> recv_headers(socket, bytes <> chunk)
        error -> error
      end
    else
      {:ok, bytes}
    end
  end

  defp send_response(socket, status, headers) do
    reason =
      case status do
        200 -> "OK"
        301 -> "Moved Permanently"
        403 -> "Forbidden"
        412 -> "Precondition Failed"
        _other -> "Response"
      end

    encoded = Enum.map_join(headers, "", fn {name, value} -> "#{name}: #{value}\r\n" end)

    :gen_tcp.send(
      socket,
      "HTTP/1.1 #{status} #{reason}\r\n#{encoded}Content-Length: 0\r\nConnection: close\r\n\r\n"
    )
  end
end

defmodule Gitility.Milestone6MirrorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Gitility.Bundle
  alias Gitility.Bundle.Format
  alias Gitility.Differential.Oracle
  alias Gitility.Fetch
  alias Gitility.Fetch.Locks
  alias Gitility.Milestone6MirrorTest.{FakeStore, HTTPStub, MissingCallbackStore}
  alias Gitility.Mirror
  alias Gitility.Mirror.{Receipt, Restore}
  alias Gitility.ObjectStore.Local
  alias Gitility.ObjectStore.Local.Server, as: LocalServer
  alias Gitility.ObjectStore.S3
  alias Gitility.Repository
  alias Gitility.TestSupport.SmartHTTPServer
  alias Gitility.{Error, OID}

  @fixtures Path.expand("../fixtures/generated", __DIR__)
  @wildcard "+refs/heads/*:refs/remotes/origin/*"
  @content_type "application/vnd.gitility.bundle"
  @maximum_generation 18_446_744_073_709_551_615
  @owned_hex String.duplicate("a", 32)

  setup do
    scratch =
      Path.join(
        System.tmp_dir!(),
        "gitility-m6-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(scratch)
    on_exit(fn -> File.rm_rf!(scratch) end)

    %{scratch: scratch, store: {Local, [root: Path.join(scratch, "store")]}}
  end

  test "01 publish fresh writes generation-one metadata and a verifiable object", context do
    source = copy_fixture(context.scratch, "fresh", "sha1-basic-packed.git")

    assert {:ok, %Receipt{generation: 1, tips_digest: digest} = receipt} =
             Mirror.publish(source, context.store, "mirrors/fresh")

    assert byte_size(digest) == 64
    assert digest =~ ~r/\A[0-9a-f]{64}\z/

    state = local_state(context.store)
    assert {:ok, head} = Local.head(state, "mirrors/fresh", timeout: 5_000)
    assert head.metadata["generation"] == "1"
    assert head.metadata["tips_digest"] == digest
    assert head.etag == receipt.etag

    downloaded = Path.join(context.scratch, "fresh.bundle")
    assert {:ok, %{bytes: bytes}} = Local.get(state, "mirrors/fresh", downloaded, timeout: 5_000)
    assert bytes == receipt.bytes
    assert :ok = Bundle.verify(downloaded)
  end

  test "02 unchanged publication is not_newer and performs no Local commit", context do
    source = copy_fixture(context.scratch, "unchanged", "sha1-basic-packed.git")
    key = "mirrors/unchanged"
    assert {:ok, %Receipt{etag: etag}} = Mirror.publish(source, context.store, key)

    parent = self()
    {Local, opts} = context.store

    hooked =
      {Local,
       Keyword.put(opts, :test_hooks, %{
         before_commit: fn ->
           send(parent, :commit)
           :ok
         end
       })}

    assert {:ok, :not_newer} = Mirror.publish(source, hooked, key)
    refute_receive :commit, 100
    assert {:ok, %{etag: ^etag}} = Local.head(local_state(context.store), key, timeout: 5_000)
  end

  test "03 fetch of new remote commits publishes generation two with a new digest", context do
    {remote, url} = remote_fixture(context.scratch, "sha1-basic.git")
    source = Path.join(context.scratch, "fetch-mirror.git")
    key = "mirrors/fetched"

    assert {:ok, _result} = Fetch.fetch(source, url, [@wildcard])

    assert {:ok, %Receipt{generation: 1, tips_digest: first}} =
             Mirror.publish(source, context.store, key)

    _new_oid = advance(remote, "refs/heads/main", "m6 generation two")
    assert {:ok, _result} = Fetch.fetch(source, url, [@wildcard])

    assert {:ok, %Receipt{generation: 2, tips_digest: second}} =
             Mirror.publish(source, context.store, key)

    refute first == second
  end

  test "04 a fresh restore is fsck-clean, ref/HEAD/config-identical, and pack-identical",
       context do
    source = copy_fixture(context.scratch, "restore-source", "sha1-basic-packed.git")
    destination = Path.join(context.scratch, "restored.git")
    key = "mirrors/restore"

    assert {:ok, %Receipt{} = published} = Mirror.publish(source, context.store, key)
    assert {:ok, %Restore{} = restored} = Mirror.restore(context.store, key, destination)
    assert restored.generation == published.generation
    assert git!(destination, ["fsck", "--strict"]) =~ ""
    assert refs(destination) == refs(source)
    assert head_state(destination) == head_state(source)
    assert_gc_safe(destination)
    assert pack_artifacts(destination) == pack_artifacts(source)
  end

  test "05 restored and from-scratch mirrors converge after the same incremental fetch",
       context do
    {remote, url} = remote_fixture(context.scratch, "sha1-basic.git")
    published_source = Path.join(context.scratch, "published-source.git")
    restored = Path.join(context.scratch, "restored-incremental.git")
    scratch_fetch = Path.join(context.scratch, "scratch-incremental.git")
    key = "mirrors/incremental"

    assert {:ok, _result} = Fetch.fetch(published_source, url, [@wildcard])
    assert {:ok, %Receipt{}} = Mirror.publish(published_source, context.store, key)
    assert {:ok, %Restore{}} = Mirror.restore(context.store, key, restored)
    _new_oid = advance(remote, "refs/heads/main", "post-restore fetch")

    assert {:ok, restored_result} = Fetch.fetch(restored, url, [@wildcard])
    assert {:ok, scratch_result} = Fetch.fetch(scratch_fetch, url, [@wildcard])

    assert refs(restored) == refs(scratch_fetch)
    assert object_set(restored) == object_set(scratch_fetch)

    assert update_targets(restored_result.updated_refs) ==
             update_targets(scratch_result.updated_refs)

    assert restored_result.rejected_refs == []
    assert scratch_result.rejected_refs == []
  end

  test "06 restore refuses a nonempty destination untouched and replaces an existing empty one",
       context do
    source = copy_fixture(context.scratch, "destination-source", "sha1-basic-packed.git")
    key = "mirrors/destination"
    assert {:ok, %Receipt{}} = Mirror.publish(source, context.store, key)

    nonempty = Path.join(context.scratch, "nonempty.git")
    File.mkdir_p!(nonempty)
    marker = Path.join(nonempty, "owner-data")
    File.write!(marker, "keep")

    assert {:error, %Error{code: :invalid_argument}} =
             Mirror.restore(context.store, key, nonempty)

    assert File.read!(marker) == "keep"
    assert File.ls!(nonempty) == ["owner-data"]

    empty = Path.join(context.scratch, "existing-empty.git")
    File.mkdir_p!(empty)
    assert {:ok, %Restore{}} = Mirror.restore(context.store, key, empty)
    assert git!(empty, ["fsck", "--strict"]) =~ ""
  end

  test "07 a missing key is typed not_found and creates no destination or siblings", context do
    destination = Path.join(context.scratch, "missing.git")

    nested_init_orphan =
      destination <> ".restore-#{@owned_hex}.stage.init-#{@owned_hex}"

    File.mkdir_p!(nested_init_orphan)
    File.write!(Path.join(nested_init_orphan, "partial"), "owned")

    assert {:error, %Error{code: :not_found, operation: :restore}} =
             Mirror.restore(context.store, "mirrors/missing", destination)

    refute File.exists?(destination)
    assert owned_restore_siblings(destination) == []
  end

  test "08 corrupt stored bytes are malformed_bundle and leave no restore artifacts", context do
    source = copy_fixture(context.scratch, "corrupt-source", "sha1-basic-packed.git")
    destination = Path.join(context.scratch, "corrupt-restore.git")
    key = "mirrors/corrupt"
    assert {:ok, %Receipt{}} = Mirror.publish(source, context.store, key)

    data = local_current_data(context.store, key)
    flip_byte!(data, 20)

    assert {:error, %Error{code: :malformed_bundle}} =
             Mirror.restore(context.store, key, destination)

    refute File.exists?(destination)
    assert owned_restore_siblings(destination) == []
  end

  test "09 shallow_roots remains unsupported instead of becoming malformed", context do
    bundle = Path.join(context.scratch, "shallow.bundle")

    write_bundle!(bundle,
      metadata: %{"source_identity" => "m6:shallow", "shallow_roots" => "deadbeef"}
    )

    put_bundle!(context.store, "mirrors/shallow", bundle)
    destination = Path.join(context.scratch, "shallow.git")

    assert {:error, %Error{code: :unsupported_operation, operation: :restore}} =
             Mirror.restore(context.store, "mirrors/shallow", destination)

    refute File.exists?(destination)
  end

  test "10 divergent CAS publishers produce one receipt and one conflict at one generation",
       context do
    base = copy_fixture(context.scratch, "race-base", "sha1-basic-packed.git")
    first = copy_fixture(context.scratch, "race-first", "sha1-basic-packed.git")
    second = copy_fixture(context.scratch, "race-second", "sha1-basic-packed.git")
    key = "mirrors/race"
    assert {:ok, %Receipt{generation: 1}} = Mirror.publish(base, context.store, key)
    _ = advance(first, "refs/heads/main", "divergent one")
    _ = advance(second, "refs/heads/main", "divergent two")

    parent = self()

    hook = fn ->
      send(parent, {:before_commit, self()})
      receive do: (:commit_now -> :ok)
    end

    {Local, opts} = context.store
    raced_store = {Local, Keyword.put(opts, :test_hooks, %{before_commit: hook})}
    one = Task.async(fn -> Mirror.publish(first, raced_store, key) end)
    two = Task.async(fn -> Mirror.publish(second, raced_store, key) end)

    assert_receive {:before_commit, hook_one}, 10_000
    assert_receive {:before_commit, hook_two}, 10_000
    send(hook_one, :commit_now)
    send(hook_two, :commit_now)

    results = [Task.await(one, 15_000), Task.await(two, 15_000)]
    assert Enum.count(results, &match?({:ok, %Receipt{generation: 2}}, &1)) == 1

    assert Enum.count(results, fn
             {:error, %Error{code: :conflict, retryable: true}} -> true
             _other -> false
           end) == 1

    assert {:ok, %{metadata: %{"generation" => "2"}}} =
             Local.head(local_state(context.store), key, timeout: 5_000)
  end

  test "11 publish and restore share Fetch's immediate busy lease", context do
    source = copy_fixture(context.scratch, "lease-source", "sha1-basic-packed.git")
    key = "mirrors/lease"
    assert {:ok, %Receipt{}} = Mirror.publish(source, context.store, key)

    assert :ok = Locks.acquire(Path.expand(source), 5_000)

    try do
      started = System.monotonic_time(:millisecond)

      assert {:error, %Error{code: :busy, operation: :publish, retryable: true}} =
               Mirror.publish(source, context.store, key)

      assert System.monotonic_time(:millisecond) - started < 1_000
    after
      Locks.release(Path.expand(source))
    end

    destination = Path.join(context.scratch, "lease-restore.git")
    assert :ok = Locks.acquire(Path.expand(destination), 5_000)

    try do
      assert {:error, %Error{code: :busy, operation: :restore, retryable: true}} =
               Mirror.restore(context.store, key, destination)
    after
      Locks.release(Path.expand(destination))
    end
  end

  test "12 all creation paths are gc-safe; init validation and reflog contract hold", context do
    direct = Path.join(context.scratch, "direct-init.git")
    assert :ok = Repository.init_bare(direct)

    {remote, url} = remote_fixture(context.scratch, "sha1-basic.git")
    assert File.dir?(remote)
    fetched = Path.join(context.scratch, "fetch-init.git")
    assert {:ok, _result} = Fetch.fetch(fetched, url, [@wildcard])

    source = copy_fixture(context.scratch, "config-source", "sha1-basic-packed.git")
    key = "mirrors/config"
    restored = Path.join(context.scratch, "restore-init.git")
    assert {:ok, %Receipt{}} = Mirror.publish(source, context.store, key)
    assert {:ok, %Restore{}} = Mirror.restore(context.store, key, restored)

    Enum.each([direct, fetched, restored], fn repository ->
      assert_gc_safe(repository)
      before = pack_count(repository)
      _ = git!(repository, ["gc", "--auto"])
      assert pack_count(repository) == before
    end)

    nonempty = Path.join(context.scratch, "init-nonempty.git")
    File.mkdir_p!(nonempty)
    marker = Path.join(nonempty, "marker")
    File.write!(marker, "keep")
    assert {:error, %Error{code: :invalid_argument}} = Repository.init_bare(nonempty)
    assert File.read!(marker) == "keep"

    sha256 = Path.join(context.scratch, "init-sha256.git")

    assert {:error, %Error{code: :unsupported_hash}} =
             Repository.init_bare(sha256, hash: :sha256)

    refute File.exists?(sha256)
    {log_updates, status} = git_result(restored, ["config", "--get", "core.logAllRefUpdates"])
    assert status in [0, 1]
    assert String.trim(log_updates) in ["", "false"]
    refute File.exists?(Path.join(restored, "logs"))
  end

  test "13 explicit bundle generations respect range and monotonic replacement", context do
    source = copy_fixture(context.scratch, "generation-source", "sha1-basic-packed.git")
    bundle = Path.join(context.scratch, "generation.bundle")

    assert {:ok, %{generation: 7}} =
             Bundle.write(bundle, source: {:repository, source}, generation: 7)

    assert {:ok, %{generation: 7}} = Format.parse(bundle)

    for generation <- [0, @maximum_generation + 1, 7, 6] do
      assert {:error, %Error{code: :invalid_argument}} =
               Bundle.write(bundle, source: {:repository, source}, generation: generation)
    end

    fresh = Path.join(context.scratch, "zero.bundle")

    assert {:error, %Error{code: :invalid_argument}} =
             Bundle.write(fresh, source: {:repository, source}, generation: 0)

    refute File.exists?(fresh)
  end

  test "14 tips_digest matches the frozen fixed vector", _context do
    refs = [
      %{name: "refs/tags/v1.0.0", target: :binary.copy(<<0x22>>, 20)},
      %{name: "refs/heads/main", target: :binary.copy(<<0x11>>, 20)},
      %{name: "refs/remotes/origin/main", target: :binary.copy(<<0x33>>, 20)}
    ]

    assert Mirror.tips_digest(refs, "refs/heads/main") ==
             "3996fe4fdc62e0739daccbf3ec7846ca18b73771117c5499c67597f077c52281"
  end

  test "15 credentials, HTTP failures, logs, and redirects retain no secret", context do
    if Code.ensure_loaded?(Req) do
      source = copy_fixture(context.scratch, "hygiene-source", "sha1-basic-packed.git")
      secret = "SENTINEL_SECRET_M6"
      session = "SENTINEL_SESSION_M6"

      credentials = %{
        access_key_id: "sentinel-access",
        secret_access_key: secret,
        session_token: session
      }

      second = start_supervised!({HTTPStub, mode: {:status, 200}})
      first = start_supervised!({HTTPStub, mode: {:redirect, HTTPStub.url(second) <> "/hostile"}})
      redirect_store = s3_store(HTTPStub.url(first), credentials)

      assert {:error, %Error{code: :backend_error, cause: {:http, 301, nil}} = redirect_error} =
               Mirror.publish(source, redirect_store, "redirect/object", timeout: 2_000)

      assert HTTPStub.requests(first) == 1
      assert HTTPStub.requests(second) == 0
      assert_hygienic(redirect_error, [secret, session, "X-Amz-"])

      for {mode, expected_code} <- [
            {{:status, 403}, :authentication_failed},
            {{:status, 412}, :backend_error},
            {:close, :backend_error},
            {:stall, :timeout}
          ] do
        stub = start_supervised!({HTTPStub, mode: mode})
        store = s3_store(HTTPStub.url(stub), credentials)
        parent = self()

        log =
          capture_log([level: :info], fn ->
            timeout = if mode == :stall, do: 100, else: 2_000
            result = Mirror.publish(source, store, "hygiene/#{inspect(mode)}", timeout: timeout)
            send(parent, {:hygiene, result})
          end)

        assert_receive {:hygiene, {:error, %Error{code: ^expected_code} = error}}, 2_000
        assert log == ""
        assert_hygienic(error, [secret, session, "X-Amz-"])
      end

      assert {:ok, state} = S3.init(elem(redirect_store, 1))
      inspected = inspect(state, limit: :infinity)
      refute inspected =~ secret
      refute inspected =~ session
      refute inspected =~ "Req.Request"
    else
      assert {:error, {:unsupported_operation, _message}} =
               S3.init(
                 bucket: "gitility-test",
                 region: "us-east-1",
                 credentials: %{
                   access_key_id: "x",
                   secret_access_key: "SENTINEL_SECRET_M6"
                 }
               )
    end
  end

  test "16 moving symbolic HEAD alone changes the digest/generation and restores the new HEAD",
       context do
    source = copy_fixture(context.scratch, "head-move", "sha1-basic-packed.git")
    oid = git!(source, ["rev-parse", "refs/heads/main"])
    _ = git!(source, ["update-ref", "refs/heads/master", oid])
    _ = git!(source, ["symbolic-ref", "HEAD", "refs/heads/main"])
    key = "mirrors/head-move"

    assert {:ok, %Receipt{generation: 1, tips_digest: first}} =
             Mirror.publish(source, context.store, key)

    _ = git!(source, ["symbolic-ref", "HEAD", "refs/heads/master"])

    assert {:ok, %Receipt{generation: 2, tips_digest: second}} =
             Mirror.publish(source, context.store, key)

    refute first == second
    restored = Path.join(context.scratch, "head-moved-restored.git")
    assert {:ok, %Restore{generation: 2}} = Mirror.restore(context.store, key, restored)
    assert head_state(restored) == {:symbolic, "refs/heads/master", oid}
  end

  test "17 an empty unborn mirror round-trips strictly and can then be populated by fetch",
       context do
    source = Path.join(context.scratch, "empty-source.git")
    assert :ok = Repository.init_bare(source)
    _ = git!(source, ["symbolic-ref", "HEAD", "refs/heads/unborn"])
    key = "mirrors/empty"

    assert {:ok, %Receipt{generation: 1, ref_count: 0}} =
             Mirror.publish(source, context.store, key)

    bundle = Path.join(context.scratch, "empty.bundle")
    state = local_state(context.store)
    assert {:ok, _result} = Local.get(state, key, bundle, timeout: 5_000)

    assert {:ok, %{refs: [], metadata: %{"head_symref" => "refs/heads/unborn"}}} =
             Format.parse(bundle)

    restored = Path.join(context.scratch, "empty-restored.git")
    assert {:ok, %Restore{ref_count: 0}} = Mirror.restore(context.store, key, restored)
    assert head_state(restored) == {:unborn, "refs/heads/unborn"}

    {_remote, url} = remote_fixture(context.scratch, "sha1-basic.git")
    assert {:ok, result} = Fetch.fetch(restored, url, [@wildcard])
    assert result.updated_refs != []
    assert refs(restored) != %{}
  end

  test "18 detached and nondefault unborn HEAD round-trip; malformed HEAD shapes are refused",
       context do
    detached = copy_fixture(context.scratch, "detached-source", "sha1-basic-packed.git")
    detached_oid = git!(detached, ["rev-parse", "refs/heads/main"])
    _ = git!(detached, ["update-ref", "--no-deref", "HEAD", detached_oid])
    detached_key = "mirrors/detached"
    assert {:ok, %Receipt{}} = Mirror.publish(detached, context.store, detached_key)
    detached_restore = Path.join(context.scratch, "detached-restored.git")
    assert {:ok, %Restore{}} = Mirror.restore(context.store, detached_key, detached_restore)
    assert head_state(detached_restore) == {:detached, detached_oid}

    unborn = Path.join(context.scratch, "trunk-source.git")
    assert :ok = Repository.init_bare(unborn)
    _ = git!(unborn, ["symbolic-ref", "HEAD", "refs/heads/trunk"])
    unborn_key = "mirrors/trunk"
    assert {:ok, %Receipt{ref_count: 0}} = Mirror.publish(unborn, context.store, unborn_key)
    unborn_restore = Path.join(context.scratch, "trunk-restored.git")

    assert {:ok, %Restore{ref_count: 0}} =
             Mirror.restore(context.store, unborn_key, unborn_restore)

    assert head_state(unborn_restore) == {:unborn, "refs/heads/trunk"}

    oid = raw_oid(0x44)

    malformed_shapes = [
      {"existing", [%{name: "refs/heads/main", target: oid, kind: :commit}], "refs/heads/main",
       :malformed_ref},
      {"tag", [%{name: "refs/tags/v1", target: oid, kind: :tag}], "refs/tags/v1", :malformed_ref},
      {"self", [], "HEAD", :malformed_ref},
      {"missing", [%{name: "refs/heads/main", target: oid, kind: :commit}], nil, :missing_head}
    ]

    Enum.each(malformed_shapes, fn {label, rows, head_symref, verify_code} ->
      path = Path.join(context.scratch, "crafted-head-#{label}.bundle")
      metadata = maybe_head_metadata(%{"source_identity" => "m6:head:#{label}"}, head_symref)
      write_bundle!(path, refs: rows, metadata: metadata)
      key = "crafted/head/#{label}"
      put_bundle!(context.store, key, path)
      destination = Path.join(context.scratch, "crafted-head-#{label}.git")

      assert {:error, %Error{code: :malformed_bundle, details: %{verify_code: ^verify_code}}} =
               Mirror.restore(context.store, key, destination)

      refute File.exists?(destination)
      assert owned_restore_siblings(destination) == []
    end)

    strict_cases = [
      {"tag", "ref: refs/tags/v1.0.0\n", :error},
      {"branch", "ref: refs/heads/main\n", :ok},
      {"invalid", "ref: refs/heads/bad..name\n", :error},
      {"self", "ref: HEAD\n", :error}
    ]

    Enum.each(strict_cases, fn {label, head_contents, expected} ->
      source = copy_fixture(context.scratch, "strict-head-#{label}", "sha1-basic-packed.git")
      File.write!(Path.join(source, "HEAD"), head_contents)
      bundle = Path.join(context.scratch, "strict-head-#{label}.bundle")
      result = Bundle.write(bundle, source: {:repository, source}, strict_refs: true)

      case expected do
        :ok -> assert {:ok, %{warnings: []}} = result
        :error -> assert {:error, %Error{code: :malformed_ref}} = result
      end
    end)
  end

  test "19 dangling refs, bad indexes, and D/F conflicts are malformed and stages are removed",
       context do
    missing_oid = raw_oid(0x55)
    dangling = Path.join(context.scratch, "dangling.bundle")

    write_bundle!(dangling,
      refs: [
        %{name: "HEAD", target: missing_oid, kind: :commit},
        %{name: "refs/heads/main", target: missing_oid, kind: :commit}
      ],
      metadata: %{"source_identity" => "m6:dangling", "head_symref" => "refs/heads/main"}
    )

    put_bundle!(context.store, "crafted/dangling", dangling)
    dangling_dest = Path.join(context.scratch, "dangling.git")

    assert {:error, %Error{code: :malformed_bundle, details: %{verify_code: :dangling_ref}}} =
             Mirror.restore(context.store, "crafted/dangling", dangling_dest)

    assert owned_restore_siblings(dangling_dest) == []

    source = copy_fixture(context.scratch, "bad-index-source", "sha1-basic-packed.git")
    bad_index = Path.join(context.scratch, "bad-index.bundle")

    assert {:ok, _receipt} =
             Bundle.write(bad_index, source: {:repository, source}, strict_refs: true)

    corrupt_named_section!(bad_index, :idx, 20)
    assert :ok = Bundle.verify(bad_index)
    put_bundle!(context.store, "crafted/bad-index", bad_index)
    bad_index_dest = Path.join(context.scratch, "bad-index.git")

    assert {:error, %Error{code: :malformed_bundle}} =
             Mirror.restore(context.store, "crafted/bad-index", bad_index_dest)

    assert owned_restore_siblings(bad_index_dest) == []

    conflict = Path.join(context.scratch, "df-conflict.bundle")

    write_bundle!(conflict,
      refs: [
        %{name: "HEAD", target: missing_oid, kind: :commit},
        %{name: "refs/heads/a", target: missing_oid, kind: :commit},
        %{name: "refs/heads/a/b", target: missing_oid, kind: :commit}
      ],
      metadata: %{"source_identity" => "m6:df", "head_symref" => "refs/heads/a"}
    )

    put_bundle!(context.store, "crafted/df", conflict)
    conflict_dest = Path.join(context.scratch, "df-conflict.git")

    assert {:error, %Error{code: :malformed_bundle, details: %{verify_code: :malformed_ref}}} =
             Mirror.restore(context.store, "crafted/df", conflict_dest)

    assert owned_restore_siblings(conflict_dest) == []
  end

  test "20 a foreign object blocks publish and remains byte-for-byte untouched", context do
    source = copy_fixture(context.scratch, "foreign-source", "sha1-basic-packed.git")
    foreign = Path.join(context.scratch, "foreign.object")
    File.write!(foreign, "owner-controlled object")
    key = "foreign/object"
    state = local_state(context.store)

    assert {:ok, %{etag: etag}} =
             Local.put(state, foreign, key,
               timeout: 5_000,
               if_match: :none,
               metadata: %{},
               content_type: @content_type
             )

    assert {:error, %Error{code: :backend_error, cause: {:adapter, :foreign_object}}} =
             Mirror.publish(source, context.store, key)

    assert {:ok, %{etag: ^etag}} = Local.head(state, key, timeout: 5_000)
    downloaded = Path.join(context.scratch, "foreign.download")
    assert {:ok, _result} = Local.get(state, key, downloaded, timeout: 5_000)
    assert File.read!(downloaded) == "owner-controlled object"
  end

  test "21 PUT timeout reconciliation distinguishes committed and uncommitted outcomes",
       context do
    source = copy_fixture(context.scratch, "reconcile-source", "sha1-basic-packed.git")

    {:ok, committed_agent} = Agent.start_link(fn -> %{objects: %{}} end)
    committed_store = {FakeStore, %{agent: committed_agent, put_mode: :commit_then_timeout}}

    assert {:ok, %Receipt{generation: 1, etag: "fake-etag-1"}} =
             Mirror.publish(source, committed_store, "reconcile/committed")

    assert Agent.get(committed_agent, & &1.put_calls) == 1

    {:ok, absent_agent} = Agent.start_link(fn -> %{objects: %{}} end)
    absent_store = {FakeStore, %{agent: absent_agent, put_mode: :timeout}}

    assert {:error, %Error{code: :backend_error, retryable: true} = error} =
             Mirror.publish(source, absent_store, "reconcile/absent")

    refute error.details[:indeterminate]
    assert Agent.get(absent_agent, & &1.objects) == %{}
  end

  test "22 raising and malformed S3 credential providers are credentials_unavailable and hygienic",
       context do
    if Code.ensure_loaded?(Req) do
      source = copy_fixture(context.scratch, "credentials-source", "sha1-basic-packed.git")
      secret = "SENTINEL_SECRET_CREDENTIAL_PROVIDER"

      providers = [
        fn -> raise ArgumentError, secret end,
        fn -> %{access_key_id: secret, secret_access_key: nil, session_token: secret} end,
        fn -> {:secret, secret} end
      ]

      Enum.with_index(providers, fn provider, index ->
        store =
          s3_store("http://127.0.0.1:1", provider)

        assert {:error, %Error{code: :credentials_unavailable} = error} =
                 Mirror.publish(source, store, "credentials/#{index}", timeout: 1_000)

        assert_hygienic(error, [secret, "X-Amz-"])
      end)
    else
      assert true
    end
  end

  test "23 caller death releases the lease and the exact owned orphan shapes are swept",
       context do
    source = copy_fixture(context.scratch, "kill-source", "sha1-basic-packed.git")
    key = "mirrors/killed"
    parent = self()

    hook = fn ->
      send(parent, {:blocked_put, self()})
      receive do: (:never -> :ok)
    end

    {Local, opts} = context.store
    blocked = {Local, Keyword.put(opts, :test_hooks, %{before_put: hook})}
    caller = spawn(fn -> send(parent, {:killed_result, Mirror.publish(source, blocked, key)}) end)
    monitor = Process.monitor(caller)
    assert_receive {:blocked_put, _hook_pid}, 10_000
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}, 2_000
    assert :ok = eventually(fn -> not lease_present?(Path.expand(source)) end)

    orphaned = Path.wildcard(source <> ".publish-*.tmp")
    assert orphaned != []
    assert {:ok, %Receipt{}} = Mirror.publish(source, context.store, key)
    assert Enum.all?(orphaned, &(not File.exists?(&1)))

    basename = Path.basename(source)
    parent_dir = Path.dirname(source)
    writer = Path.join(parent_dir, ".#{basename}.publish-#{@owned_hex}.tmp.tmp-1")
    staging = Path.join(parent_dir, ".#{basename}.publish-#{@owned_hex}.tmp.staging-1")
    pack_orphan = Path.join(source, "objects/.gitility-publish-1")
    decoy_sibling = Path.join(parent_dir, "#{basename}.publish-backup")
    decoy_pack = Path.join(source, "objects/pack/keep.me")
    File.write!(writer, "orphan")
    File.mkdir_p!(staging)
    File.mkdir_p!(pack_orphan)
    File.write!(decoy_sibling, "owner")
    File.write!(decoy_pack, "owner")

    assert {:ok, :not_newer} = Mirror.publish(source, context.store, key)
    refute File.exists?(writer)
    refute File.exists?(staging)
    refute File.exists?(pack_orphan)
    assert File.read!(decoy_sibling) == "owner"
    assert File.read!(decoy_pack) == "owner"
    refute_receive {:killed_result, _result}
  end

  test "24 public mirror validation is typed and raise-free for every option shape", context do
    source = copy_fixture(context.scratch, "validation-source", "sha1-basic-packed.git")
    destination = Path.join(context.scratch, "validation-restore.git")
    invalid_store = {MissingCallbackStore, :state}

    publish_calls = [
      fn -> Mirror.publish(source, context.store, "valid/key", unknown: true) end,
      fn -> Mirror.publish(source, context.store, "valid/key", [{:timeout, 10} | :bad]) end,
      fn -> Mirror.publish(source, context.store, "valid/key", timeout: 0) end,
      fn -> Mirror.publish(source, context.store, "valid/key", timeout: 86_400_001) end,
      fn -> Mirror.publish(source, invalid_store, "valid/key") end
    ]

    restore_calls = [
      fn -> Mirror.restore(context.store, "valid/key", destination, unknown: true) end,
      fn -> Mirror.restore(context.store, "valid/key", destination, [{:timeout, 10} | :bad]) end,
      fn -> Mirror.restore(context.store, "valid/key", destination, timeout: 0) end,
      fn -> Mirror.restore(context.store, "valid/key", destination, timeout: 86_400_001) end,
      fn -> Mirror.restore(invalid_store, "valid/key", destination) end
    ]

    Enum.each(publish_calls ++ restore_calls, fn call ->
      assert {:error, %Error{code: :invalid_argument}} = call.()
    end)
  end

  test "25 strict refs reject missing targets while lenient mode warns and publish never uploads",
       context do
    source = copy_fixture(context.scratch, "missing-ref-source", "sha1-basic-packed.git")
    missing_ref = Path.join(source, "refs/heads/missing")
    File.mkdir_p!(Path.dirname(missing_ref))
    File.write!(missing_ref, String.duplicate("a", 40) <> "\n")
    strict = Path.join(context.scratch, "missing-strict.bundle")
    lenient = Path.join(context.scratch, "missing-lenient.bundle")

    assert {:error, %Error{code: :missing_object}} =
             Bundle.write(strict, source: {:repository, source}, strict_refs: true)

    assert {:ok, %{warnings: warnings}} =
             Bundle.write(lenient, source: {:repository, source})

    assert warnings != []
    assert Enum.any?(warnings, &(&1.message =~ "missing"))
    key = "mirrors/missing-ref"
    assert {:error, %Error{code: :missing_object}} = Mirror.publish(source, context.store, key)
    assert {:error, :not_found} = Local.head(local_state(context.store), key, timeout: 5_000)
  end

  test "26 a HEAD row disagreeing with head_symref is malformed_ref and leaves no stage",
       context do
    source = copy_fixture(context.scratch, "head-disagree-source", "sha1-basic-packed.git")
    bundle = Path.join(context.scratch, "head-disagree.bundle")

    assert {:ok, _receipt} =
             Bundle.write(bundle, source: {:repository, source}, strict_refs: true)

    parent = git!(source, ["rev-parse", "refs/heads/main^"]) |> OID.parse!()

    rewrite_bundle!(bundle, fn toc, sections ->
      refs =
        Enum.map(toc.refs, fn
          %{name: "HEAD"} = row -> %{row | target: parent.bytes}
          row -> row
        end)

      {sections, refs, toc.metadata}
    end)

    key = "crafted/head-disagreement"
    put_bundle!(context.store, key, bundle)
    destination = Path.join(context.scratch, "head-disagreement.git")

    assert {:error, %Error{code: :malformed_bundle, details: %{verify_code: :malformed_ref}}} =
             Mirror.restore(context.store, key, destination)

    refute File.exists?(destination)
    assert owned_restore_siblings(destination) == []
  end

  test "27 zero-ref internal pack corruption reaches the deep integrity probe", context do
    source = copy_fixture(context.scratch, "probe-source", "sha1-basic-packed.git")
    bundle = Path.join(context.scratch, "probe-corrupt.bundle")

    assert {:ok, _receipt} =
             Bundle.write(bundle, source: {:repository, source}, strict_refs: true)

    rewrite_bundle!(bundle, fn toc, sections ->
      {sections, [], Map.put(toc.metadata, "head_symref", "refs/heads/main")}
    end)

    corrupt_named_section!(bundle, :pack, 32)
    assert :ok = Bundle.verify(bundle)
    key = "crafted/probe-corrupt"
    put_bundle!(context.store, key, bundle)
    destination = Path.join(context.scratch, "probe-corrupt.git")

    assert {:error, %Error{code: :malformed_bundle}} =
             Mirror.restore(context.store, key, destination)

    refute File.exists?(destination)
    assert owned_restore_siblings(destination) == []
  end

  test "28 mismatched idx, wrong tag kind/peel, and a bundle above 256 MiB get deep checks",
       context do
    multi = copy_fixture(context.scratch, "mismatched-pair-source", "sha1-history-midx.git")
    mismatched = Path.join(context.scratch, "mismatched-pair.bundle")

    assert {:ok, _receipt} =
             Bundle.write(mismatched, source: {:repository, multi}, strict_refs: true)

    rewrite_bundle!(mismatched, fn toc, sections ->
      indices =
        sections
        |> Enum.with_index()
        |> Enum.filter(fn {{kind, _name, _bytes}, _index} -> kind == :idx end)

      assert length(indices) >= 2

      [
        {{:idx, _first_name, _first_bytes}, first_index},
        {{:idx, _second_name, second_bytes}, _} | _
      ] =
        indices

      sections =
        List.update_at(sections, first_index, fn {:idx, first_name, _bytes} ->
          {:idx, first_name, second_bytes}
        end)

      {sections, toc.refs, toc.metadata}
    end)

    put_bundle!(context.store, "crafted/mismatched-pair", mismatched)
    mismatched_dest = Path.join(context.scratch, "mismatched-pair.git")

    assert {:error,
            %Error{code: :malformed_bundle, details: %{verify_code: :pack_index_mismatch}}} =
             Mirror.restore(context.store, "crafted/mismatched-pair", mismatched_dest)

    tagged = copy_fixture(context.scratch, "tag-check-source", "sha1-basic-packed.git")
    tagged_bundle = Path.join(context.scratch, "tag-check.bundle")

    assert {:ok, _receipt} =
             Bundle.write(tagged_bundle, source: {:repository, tagged}, strict_refs: true)

    blob = first_object_of_kind!(tagged, "blob") |> OID.parse!()

    kind_bundle = Path.join(context.scratch, "tag-kind.bundle")
    File.cp!(tagged_bundle, kind_bundle)

    rewrite_bundle!(kind_bundle, fn toc, sections ->
      refs =
        Enum.map(toc.refs, fn
          %{name: "refs/tags/v1.0.0"} = row ->
            %{row | target: blob.bytes, kind: :tag, peeled: nil}

          row ->
            row
        end)

      {sections, refs, toc.metadata}
    end)

    assert :ok = Bundle.verify(kind_bundle)
    put_bundle!(context.store, "crafted/tag-kind", kind_bundle)
    kind_probe = Path.join(context.scratch, "tag-kind-probe.bundle")

    assert {:ok, _result} =
             Local.get(local_state(context.store), "crafted/tag-kind", kind_probe,
               timeout: 30_000
             )

    assert :ok = Bundle.verify(kind_probe)

    assert {:error, %Error{code: :malformed_bundle, details: %{verify_code: :kind_mismatch}}} =
             Mirror.restore(
               context.store,
               "crafted/tag-kind",
               Path.join(context.scratch, "tag-kind.git")
             )

    wrong_peel = Path.join(context.scratch, "wrong-peel.bundle")
    File.cp!(tagged_bundle, wrong_peel)
    wrong_commit = git!(tagged, ["rev-parse", "refs/heads/main^"]) |> OID.parse!()

    rewrite_bundle!(wrong_peel, fn toc, sections ->
      refs =
        Enum.map(toc.refs, fn
          %{name: "refs/tags/v1.0.0"} = row -> %{row | peeled: wrong_commit.bytes}
          row -> row
        end)

      {sections, refs, toc.metadata}
    end)

    assert :ok = Bundle.verify(wrong_peel)
    put_bundle!(context.store, "crafted/wrong-peel", wrong_peel)

    assert {:error, %Error{code: :malformed_bundle, details: %{verify_code: :peel_mismatch}}} =
             Mirror.restore(
               context.store,
               "crafted/wrong-peel",
               Path.join(context.scratch, "wrong-peel.git")
             )

    large_source = large_repository!()
    large_bundle = Path.join(context.scratch, "large.bundle")

    assert {:ok, %{bytes: bytes}} =
             Bundle.write(large_bundle,
               source: {:repository, large_source},
               strict_refs: true,
               mode: 0o600
             )

    assert bytes > 256 * 1024 * 1024
    large_state = local_state(context.store)

    assert {:ok, %{etag: _etag}} =
             Local.put(large_state, large_bundle, "crafted/large",
               timeout: 3_600_000,
               if_match: :none,
               metadata: %{},
               content_type: @content_type
             )

    large_restore = Path.join(context.scratch, "large-restored.git")

    assert {:ok, %Restore{bytes: ^bytes}} =
             Mirror.restore(context.store, "crafted/large", large_restore, timeout: 3_600_000)

    assert git!(large_restore, ["fsck", "--strict"]) =~ ""
  end

  test "29 Local pins readers, drops killed pins, and preserves timeout orphans coherently",
       context do
    root = Path.join(context.scratch, "pin-store")
    parent = self()
    old_source = Path.join(context.scratch, "version-a")
    new_source = Path.join(context.scratch, "version-b")
    File.write!(old_source, "version A")
    File.write!(new_source, "version B")
    key = "local/pins"
    {:ok, plain} = Local.init(root: root)

    assert {:ok, _result} =
             Local.put(plain, old_source, key,
               timeout: 30_000,
               if_match: :none,
               metadata: %{"generation" => "1"},
               content_type: @content_type
             )

    {:ok, %{etag: first_etag}} = Local.head(plain, key, timeout: 5_000)

    block_get = fn ->
      send(parent, {:reader_pinned, self()})
      receive do: (:read_now -> :ok)
    end

    reader_state = Local.with_test_hooks(plain, %{before_get: block_get})
    destination = Path.join(context.scratch, "pinned-download")

    reader =
      spawn(fn ->
        send(parent, {:reader_result, Local.get(reader_state, key, destination, timeout: 30_000)})
      end)

    assert_receive {:reader_pinned, reader_hook}, 2_000
    assert LocalServer.pin_count(Local.server(plain)) == 1

    assert {:ok, _result} =
             Local.put(plain, new_source, key,
               timeout: 30_000,
               if_match: first_etag,
               metadata: %{"generation" => "2"},
               content_type: @content_type
             )

    assert :ok = Local.force_sweep(plain, key)
    send(reader_hook, :read_now)
    assert_receive {:reader_result, {:ok, _result}}, 2_000
    refute Process.alive?(reader)
    assert File.read!(destination) == "version A"

    killed_destination = Path.join(context.scratch, "killed-download")

    killed =
      spawn(fn ->
        Local.get(reader_state, key, killed_destination, timeout: 30_000)
      end)

    assert_receive {:reader_pinned, _killed_hook}, 2_000
    assert LocalServer.pin_count(Local.server(plain)) == 1
    Process.exit(killed, :kill)
    assert :ok = eventually(fn -> LocalServer.pin_count(Local.server(plain)) == 0 end)

    current_before = local_current_version(root, key)

    timeout_hook = fn ->
      send(parent, :commit_hook_entered)
      Process.sleep(:infinity)
    end

    timeout_state = Local.with_test_hooks(plain, %{before_commit: timeout_hook})

    assert {:error, {:transport, :timeout}} =
             Local.put(timeout_state, new_source, key,
               timeout: 50,
               if_match: local_head_etag(plain, key),
               metadata: %{"generation" => "3"},
               content_type: @content_type
             )

    assert_receive :commit_hook_entered
    assert local_current_version(root, key) == current_before
    assert length(local_version_directories(root, key)) >= 2
  end

  test "30 default bundle generation refuses exhaustion at u64 max", context do
    source = copy_fixture(context.scratch, "exhausted-source", "sha1-basic-packed.git")
    exhausted = Path.join(context.scratch, "exhausted.bundle")
    write_bundle!(exhausted, generation: @maximum_generation)

    assert {:error, %Error{code: :unsupported_operation}} =
             Bundle.write(exhausted, source: {:repository, source})
  end

  test "31 over-4096-byte ref names fail strict mode and warn in lenient mode", context do
    source = copy_fixture(context.scratch, "long-ref-source", "sha1-basic-packed.git")
    oid = git!(source, ["rev-parse", "refs/heads/main"])

    long_name =
      "refs/heads/" <>
        Enum.map_join(1..22, "/", fn index ->
          String.duplicate(<<?a + rem(index, 26)>>, 190)
        end)

    assert byte_size(long_name) > 4_096
    packed_refs = Path.join(source, "packed-refs")
    File.write!(packed_refs, "#{oid} #{long_name}\n", [:append])

    assert {:error, %Error{code: :malformed_ref}} =
             Bundle.write(Path.join(context.scratch, "long-strict.bundle"),
               source: {:repository, source},
               strict_refs: true
             )

    assert {:ok, %{warnings: warnings}} =
             Bundle.write(Path.join(context.scratch, "long-lenient.bundle"),
               source: {:repository, source}
             )

    assert warnings != []
  end

  test "32 init_bare sweeps exact orphans and config failure never exposes the destination",
       context do
    destination = Path.join(context.scratch, "orphan-init.git")
    orphan = destination <> ".init-" <> @owned_hex
    decoy = destination <> ".init-backup"
    File.mkdir_p!(orphan)
    File.write!(Path.join(orphan, "partial"), "owned")
    File.mkdir_p!(decoy)
    File.write!(Path.join(decoy, "owner"), "keep")

    assert :ok = Repository.init_bare(destination)
    refute File.exists?(orphan)
    assert File.read!(Path.join(decoy, "owner")) == "keep"

    if :os.type() == {:unix, :linux} do
      locked_parent = Path.join(context.scratch, "locked-parent")
      File.mkdir_p!(locked_parent)
      File.chmod!(locked_parent, 0o500)
      failed = Path.join(locked_parent, "must-not-exist.git")
      permission_probe = Path.join(locked_parent, "permission-probe")

      try do
        case File.mkdir(permission_probe) do
          :ok ->
            # Some container users retain permission-bypass capabilities even
            # with a nonzero uid. That is equivalent to root for this row.
            File.rmdir!(permission_probe)
            assert true

          {:error, _permission_denied} ->
            assert {:error, %Error{code: :backend_error}} = Repository.init_bare(failed)
            refute File.exists?(failed)
        end
      after
        File.chmod!(locked_parent, 0o700)
      end
    else
      assert true
    end
  end

  test "33 malformed mirror metadata is foreign and never overwrites the remote object",
       context do
    source = copy_fixture(context.scratch, "metadata-source", "sha1-basic-packed.git")
    object = Path.join(context.scratch, "metadata-foreign")
    File.write!(object, "owner metadata object")
    state = local_state(context.store)
    digest = String.duplicate("a", 64)

    valid = %{
      "format" => "gitility-bundle/1.0",
      "generation" => "1",
      "tips_digest" => digest,
      "ref_count" => "1",
      "file_count" => "2"
    }

    variants = [
      Map.delete(valid, "format"),
      %{valid | "generation" => "01"},
      %{valid | "generation" => "+1"},
      %{valid | "generation" => "0"},
      %{valid | "generation" => "18446744073709551616"},
      %{valid | "ref_count" => "one"},
      %{valid | "file_count" => "2x"}
    ]

    Enum.with_index(variants)
    |> Enum.each(fn {metadata, index} ->
      key = "metadata/foreign/#{index}"

      assert {:ok, %{etag: etag}} =
               Local.put(state, object, key,
                 timeout: 5_000,
                 if_match: :none,
                 metadata: metadata,
                 content_type: @content_type
               )

      assert {:error, %Error{code: :backend_error, cause: {:adapter, :foreign_object}}} =
               Mirror.publish(source, context.store, key)

      assert {:ok, %{etag: ^etag, metadata: ^metadata}} = Local.head(state, key, timeout: 5_000)
      downloaded = Path.join(context.scratch, "metadata-download-#{index}")
      assert {:ok, _result} = Local.get(state, key, downloaded, timeout: 5_000)
      assert File.read!(downloaded) == "owner metadata object"
    end)
  end

  defp copy_fixture(scratch, label, fixture) do
    destination = Path.join(scratch, "#{label}.git")
    File.cp_r!(Path.join(@fixtures, fixture), destination)
    destination
  end

  defp remote_fixture(scratch, fixture) do
    root = Path.join(scratch, "remote-root-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    remote = Path.join(root, fixture)
    File.cp_r!(Path.join(@fixtures, fixture), remote)
    server = start_supervised!({SmartHTTPServer, project_root: root})
    {remote, SmartHTTPServer.url(server, fixture)}
  end

  defp local_state({Local, opts}) do
    assert {:ok, state} = Local.init(opts)
    state
  end

  defp refs(repository) do
    assert {:ok, rows} = Oracle.refs(repository)
    Map.new(rows, &{&1.name, &1.object})
  end

  defp head_state(repository) do
    case git_result(repository, ["symbolic-ref", "-q", "HEAD"]) do
      {name, 0} ->
        name = String.trim(name)

        case git_result(repository, ["rev-parse", "--verify", "HEAD"]) do
          {oid, 0} -> {:symbolic, name, String.trim(oid)}
          {_output, _status} -> {:unborn, name}
        end

      {_output, _status} ->
        {:detached, git!(repository, ["rev-parse", "--verify", "HEAD"])}
    end
  end

  defp object_set(repository) do
    repository
    |> git!(["cat-file", "--batch-all-objects", "--batch-check=%(objectname) %(objecttype)"])
    |> String.split("\n", trim: true)
    |> MapSet.new()
  end

  defp update_targets(rows) do
    rows
    |> Enum.map(fn row -> {row.name, to_string(row.new_oid)} end)
    |> Enum.sort()
  end

  defp pack_artifacts(repository) do
    repository
    |> Path.join("objects/pack/*")
    |> Path.wildcard()
    |> Enum.filter(&(Path.extname(&1) in [".pack", ".idx"]))
    |> Map.new(fn path -> {Path.basename(path), sha256_file(path)} end)
  end

  defp pack_count(repository) do
    repository
    |> Path.join("objects/pack/*.pack")
    |> Path.wildcard()
    |> length()
  end

  defp assert_gc_safe(repository) do
    assert git!(repository, ["config", "--get", "gc.auto"]) == "0"
    assert git!(repository, ["config", "--get", "maintenance.auto"]) == "false"
    assert git!(repository, ["config", "--get", "receive.autogc"]) == "false"
  end

  defp advance(repository, reference, message) do
    parent = git!(repository, ["rev-parse", reference])
    tree = git!(repository, ["rev-parse", "#{parent}^{tree}"])
    commit = git!(repository, ["commit-tree", tree, "-p", parent, "-m", message])
    _ = git!(repository, ["update-ref", reference, commit])
    commit
  end

  defp git!(repository, arguments) do
    prefix = if repository, do: ["--git-dir", repository], else: []

    case git_command(prefix ++ arguments) do
      {output, 0} -> String.trim(output)
      {output, status} -> raise "git #{Enum.join(arguments, " ")} failed #{status}: #{output}"
    end
  end

  defp git_result(repository, arguments) do
    prefix = if repository, do: ["--git-dir", repository], else: []
    git_command(prefix ++ arguments)
  end

  defp git_command(arguments, opts \\ []) do
    environment =
      Oracle.git_environment() ++
        [
          {"GIT_AUTHOR_NAME", "Gitility Test"},
          {"GIT_AUTHOR_EMAIL", "gitility@example.invalid"},
          {"GIT_COMMITTER_NAME", "Gitility Test"},
          {"GIT_COMMITTER_EMAIL", "gitility@example.invalid"}
        ]

    System.cmd("git", arguments, Keyword.merge([env: environment, stderr_to_stdout: true], opts))
  end

  defp write_bundle!(path, opts) do
    hash = Keyword.get(opts, :hash, :sha1)
    generation = Keyword.get(opts, :generation, 1)
    metadata = Keyword.get(opts, :metadata, %{"source_identity" => "m6:crafted"})
    refs = Keyword.get(opts, :refs, [])
    sections = Keyword.get(opts, :sections, [])

    {entries, payload, toc_offset} =
      Enum.reduce(sections, {[], <<>>, 16}, fn {kind, name, bytes}, {entries, payload, offset} ->
        entry = %{
          kind: kind,
          name: name,
          offset: offset,
          length: byte_size(bytes),
          sha256: :crypto.hash(:sha256, bytes)
        }

        {entries ++ [entry], payload <> bytes, offset + byte_size(bytes)}
      end)

    toc =
      Format.encode_toc(%{
        hash_algorithm: hash,
        generation: generation,
        metadata: metadata,
        files: entries,
        refs: refs
      })

    File.write!(
      path,
      Format.encode_header() <>
        payload <>
        toc <>
        Format.encode_trailer(toc_offset, byte_size(toc), :crypto.hash(:sha256, toc))
    )

    path
  end

  defp rewrite_bundle!(path, fun) do
    assert {:ok, toc} = Format.parse(path)
    bytes = File.read!(path)

    sections =
      Enum.map(toc.sections, fn section ->
        {section.kind, section.name, binary_part(bytes, section.offset, section.length)}
      end)

    {sections, refs, metadata} = fun.(toc, sections)

    write_bundle!(path,
      hash: toc.hash_algorithm,
      generation: toc.generation,
      metadata: metadata,
      refs: refs,
      sections: sections
    )
  end

  defp corrupt_named_section!(path, kind, offset) do
    rewrite_bundle!(path, fn toc, sections ->
      sections =
        Enum.map_reduce(sections, false, fn
          {^kind, name, bytes}, false when byte_size(bytes) > offset ->
            old = :binary.at(bytes, offset)
            replacement = replace_binary(bytes, offset, 1, <<Bitwise.bxor(old, 1)>>)
            {{kind, name, replacement}, true}

          section, changed ->
            {section, changed}
        end)

      {updated, true} = sections
      {updated, toc.refs, toc.metadata}
    end)
  end

  defp replace_binary(binary, offset, length, replacement) do
    prefix = binary_part(binary, 0, offset)
    suffix_offset = offset + length
    suffix = binary_part(binary, suffix_offset, byte_size(binary) - suffix_offset)
    prefix <> replacement <> suffix
  end

  defp put_bundle!(store, key, bundle, metadata \\ %{}) do
    state = local_state(store)

    assert {:ok, %{etag: _etag}} =
             Local.put(state, bundle, key,
               timeout: 30_000,
               if_match: :none,
               metadata: metadata,
               content_type: @content_type
             )

    :ok
  end

  defp local_current_data({Local, opts}, key) do
    root = opts |> Keyword.fetch!(:root) |> Path.expand()
    version = local_current_version(root, key)
    Path.join([root, "objects", key_hash(key), "v-#{version}", "data"])
  end

  defp local_current_version(root, key) do
    root
    |> Path.join("objects")
    |> Path.join(key_hash(key))
    |> Path.join("current")
    |> File.read!()
  end

  defp local_version_directories(root, key) do
    root
    |> Path.join("objects")
    |> Path.join(key_hash(key))
    |> Path.join("v-*")
    |> Path.wildcard()
  end

  defp local_head_etag(state, key) do
    assert {:ok, %{etag: etag}} = Local.head(state, key, timeout: 5_000)
    etag
  end

  defp key_hash(key),
    do: :sha256 |> :crypto.hash(key) |> Base.encode16(case: :lower)

  defp flip_byte!(path, offset) do
    bytes = File.read!(path)
    old = :binary.at(bytes, offset)
    File.write!(path, replace_binary(bytes, offset, 1, <<Bitwise.bxor(old, 1)>>))
  end

  defp owned_restore_siblings(destination) do
    Path.wildcard(destination <> ".restore-*") ++ Path.wildcard(destination <> ".init-*")
  end

  defp raw_oid(byte), do: :binary.copy(<<byte>>, 20)

  defp maybe_head_metadata(metadata, nil), do: metadata
  defp maybe_head_metadata(metadata, symref), do: Map.put(metadata, "head_symref", symref)

  defp s3_store(endpoint, credentials) do
    {S3,
     [
       bucket: "gitility-test",
       region: "us-east-1",
       endpoint_url: endpoint,
       addressing: :path,
       credentials: credentials
     ]}
  end

  defp assert_hygienic(error, sentinels) do
    inspected =
      [
        inspect(error, limit: :infinity),
        error.message,
        inspect(error.details),
        inspect(error.cause)
      ]
      |> Enum.join(" ")

    Enum.each(sentinels, fn sentinel -> refute inspected =~ sentinel end)
  end

  defp lease_present?(key) do
    try do
      Map.has_key?(:sys.get_state(Locks), key)
    catch
      :exit, _reason -> false
    end
  end

  defp eventually(fun, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    eventually_until(fun, deadline)
  end

  defp eventually_until(fun, deadline) do
    case fun.() do
      true ->
        :ok

      :ok ->
        :ok

      result ->
        if System.monotonic_time(:millisecond) >= deadline do
          result
        else
          receive do
          after
            5 -> eventually_until(fun, deadline)
          end
        end
    end
  end

  defp first_object_of_kind!(repository, kind) do
    repository
    |> git!(["rev-list", "--objects", "--all"])
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn line ->
      oid = line |> String.split(" ", parts: 2) |> hd()
      if git!(repository, ["cat-file", "-t", oid]) == kind, do: oid
    end)
    |> case do
      nil -> raise "repository contains no #{kind}"
      oid -> oid
    end
  end

  defp large_repository! do
    cache = Path.join(System.tmp_dir!(), "gitility-m6-large-#{System.pid()}.git")

    if File.regular?(Path.join(cache, "config")) do
      cache
    else
      work = cache <> ".work"
      File.mkdir_p!(work)
      {_, 0} = git_command(["init", work])
      large_file = Path.join(work, "large.bin")

      {dd_output, 0} =
        System.cmd(
          "dd",
          ["if=/dev/urandom", "of=#{large_file}", "bs=1048576", "count=257"],
          stderr_to_stdout: true
        )

      assert is_binary(dd_output)
      {_, 0} = git_command(["-C", work, "add", "large.bin"])
      {_, 0} = git_command(["-C", work, "commit", "-m", "large probe object"])
      {_, 0} = git_command(["clone", "--bare", work, cache])
      _ = git!(cache, ["gc"])
      File.rm_rf!(work)
      cache
    end
  end

  defp sha256_file(path) do
    {:ok, file} = :file.open(String.to_charlist(path), [:read, :raw, :binary])

    try do
      sha256_chunks(file, :crypto.hash_init(:sha256))
    after
      :file.close(file)
    end
  end

  defp sha256_chunks(file, context) do
    case :file.read(file, 1024 * 1024) do
      {:ok, bytes} -> sha256_chunks(file, :crypto.hash_update(context, bytes))
      :eof -> :crypto.hash_final(context)
    end
  end
end
