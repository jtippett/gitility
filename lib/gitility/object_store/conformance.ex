defmodule Gitility.ObjectStore.Conformance do
  @moduledoc """
  Reusable ExUnit conformance case for `Gitility.ObjectStore` adapters.

  The using module supplies `store_init_arg/0`; it is invoked for every test.
  Shared services can be managed with optional `store_setup/0` and
  `store_teardown/1` hooks. The setup hook's return value is passed unchanged
  to teardown.

  Deadline rows also need a deterministic blocking store. Local needs no
  extra hook because the kit installs its test hook in the returned state.
  Other adapters supply `slow_store_init_arg/0`; for S3 this is normally a
  local HTTP endpoint that drips one byte per second and never redirects.

      defmodule MyApp.ObjectStoreConformanceTest do
        use Gitility.ObjectStore.Conformance, store: MyApp.ObjectStore

        def store_init_arg, do: [bucket: "test", prefix: unique_prefix()]
        def slow_store_init_arg, do: MyApp.SlowHTTPStore.init_arg()
      end

  The generated cases are serial because the 64 MiB streaming row samples
  VM-wide memory.
  """

  @content_type "application/vnd.gitility.bundle"
  @normal_timeout 120_000
  @large_bytes 64 * 1024 * 1024

  defmacro __using__(opts) do
    store = Keyword.fetch!(opts, :store)

    quote bind_quoted: [store: store] do
      use ExUnit.Case, async: false

      @object_store store

      setup do
        setup_token =
          if function_exported?(__MODULE__, :store_setup, 0),
            do: apply(__MODULE__, :store_setup, []),
            else: nil

        scratch = Gitility.ObjectStore.Conformance.scratch_directory()
        {:ok, state} = @object_store.init(store_init_arg())

        on_exit(fn ->
          File.rm_rf(scratch)

          if function_exported?(__MODULE__, :store_teardown, 1) do
            apply(__MODULE__, :store_teardown, [setup_token])
          end
        end)

        %{
          state: state,
          scratch: scratch,
          prefix: Gitility.ObjectStore.Conformance.random_segment()
        }
      end

      test "1. missing objects return :not_found from head and get", context do
        key = Gitility.ObjectStore.Conformance.key(context, "missing")
        destination = Path.join(context.scratch, "missing.bundle")

        assert {:error, :not_found} = @object_store.head(context.state, key, timeout: 5_000)

        assert {:error, :not_found} =
                 @object_store.get(context.state, key, destination, timeout: 5_000)

        refute File.exists?(destination)
        refute File.exists?(destination <> ".part")
      end

      test "2. create-only put round-trips bytes, etag, size, and metadata", context do
        key = Gitility.ObjectStore.Conformance.key(context, "round-trip")
        source = Gitility.ObjectStore.Conformance.write_source(context, "source", "hello\0store")
        destination = Path.join(context.scratch, "download")
        metadata = %{"format" => "gitility-bundle/1.0", "generation" => "1"}

        assert {:ok, %{etag: etag}} =
                 @object_store.put(
                   context.state,
                   source,
                   key,
                   Gitility.ObjectStore.Conformance.put_opts(:none, metadata)
                 )

        assert is_binary(etag) and etag != ""

        assert {:ok, %{etag: ^etag, size: 11, metadata: ^metadata}} =
                 @object_store.head(context.state, key, timeout: 5_000)

        assert {:ok, %{etag: ^etag, bytes: 11, metadata: ^metadata}} =
                 @object_store.get(context.state, key, destination, timeout: 5_000)

        assert Gitility.ObjectStore.Conformance.sha256(source) ==
                 Gitility.ObjectStore.Conformance.sha256(destination)
      end

      test "3. create-only put rejects an existing object", context do
        key = Gitility.ObjectStore.Conformance.key(context, "create-conflict")
        source = Gitility.ObjectStore.Conformance.write_source(context, "source", "first")

        assert {:ok, %{etag: _etag}} =
                 @object_store.put(
                   context.state,
                   source,
                   key,
                   Gitility.ObjectStore.Conformance.put_opts(:none, %{})
                 )

        assert {:error, :precondition_failed} =
                 @object_store.put(
                   context.state,
                   source,
                   key,
                   Gitility.ObjectStore.Conformance.put_opts(:none, %{})
                 )
      end

      test "4. if_match on the current etag replaces the object", context do
        key = Gitility.ObjectStore.Conformance.key(context, "replace")
        first = Gitility.ObjectStore.Conformance.write_source(context, "first", "first")
        second = Gitility.ObjectStore.Conformance.write_source(context, "second", "second")

        assert {:ok, %{etag: first_etag}} =
                 @object_store.put(
                   context.state,
                   first,
                   key,
                   Gitility.ObjectStore.Conformance.put_opts(:none, %{})
                 )

        assert {:ok, %{etag: second_etag}} =
                 @object_store.put(
                   context.state,
                   second,
                   key,
                   Gitility.ObjectStore.Conformance.put_opts(first_etag, %{})
                 )

        refute second_etag == first_etag
      end

      test "5. if_match rejects a stale etag", context do
        key = Gitility.ObjectStore.Conformance.key(context, "stale")
        first = Gitility.ObjectStore.Conformance.write_source(context, "first", "first")
        second = Gitility.ObjectStore.Conformance.write_source(context, "second", "second")
        third = Gitility.ObjectStore.Conformance.write_source(context, "third", "third")

        assert {:ok, %{etag: stale}} =
                 @object_store.put(
                   context.state,
                   first,
                   key,
                   Gitility.ObjectStore.Conformance.put_opts(:none, %{})
                 )

        assert {:ok, %{etag: _current}} =
                 @object_store.put(
                   context.state,
                   second,
                   key,
                   Gitility.ObjectStore.Conformance.put_opts(stale, %{})
                 )

        assert {:error, :precondition_failed} =
                 @object_store.put(
                   context.state,
                   third,
                   key,
                   Gitility.ObjectStore.Conformance.put_opts(stale, %{})
                 )
      end

      test "6. 64 MiB put and get stream below the VM memory ceiling", context do
        key = Gitility.ObjectStore.Conformance.key(context, "large")
        source = Path.join(context.scratch, "large-source")
        destination = Path.join(context.scratch, "large-destination")
        :ok = Gitility.ObjectStore.Conformance.write_large_file(source)

        :erlang.garbage_collect()
        baseline = :erlang.memory(:total)
        sampler = Gitility.ObjectStore.Conformance.start_memory_sampler(self(), baseline)

        result =
          try do
            with {:ok, %{etag: etag}} <-
                   @object_store.put(
                     context.state,
                     source,
                     key,
                     Gitility.ObjectStore.Conformance.put_opts(
                       :none,
                       %{"size" => "67108864"},
                       600_000
                     )
                   ),
                 {:ok, %{etag: ^etag, bytes: 67_108_864}} <-
                   @object_store.get(context.state, key, destination, timeout: 600_000) do
              :ok
            end
          after
            send(sampler, {:stop, self()})
          end

        assert :ok = result

        peak =
          receive do
            {:memory_peak, ^sampler, value} -> value
          after
            1_000 -> flunk("memory sampler did not stop")
          end

        assert peak < baseline + 48 * 1024 * 1024

        assert Gitility.ObjectStore.Conformance.sha256(source) ==
                 Gitility.ObjectStore.Conformance.sha256(destination)
      end

      test "7. timed-out get is bounded and leaves neither destination name", context do
        key = Gitility.ObjectStore.Conformance.key(context, "slow-get")
        destination = Path.join(context.scratch, "slow-get")

        if @object_store == Gitility.ObjectStore.Local do
          source = Path.join(context.scratch, "slow-large-source")
          :ok = Gitility.ObjectStore.Conformance.write_large_file(source)

          assert {:ok, %{etag: _etag}} =
                   @object_store.put(
                     context.state,
                     source,
                     key,
                     Gitility.ObjectStore.Conformance.put_opts(:none, %{}, 600_000)
                   )
        end

        slow_phase =
          if @object_store == Gitility.ObjectStore.Local,
            do: :before_chunk,
            else: :before_get

        assert {:ok, slow_state} =
                 Gitility.ObjectStore.Conformance.slow_state(
                   @object_store,
                   context.state,
                   __MODULE__,
                   slow_phase
                 )

        {elapsed, result} =
          Gitility.ObjectStore.Conformance.timed(fn ->
            @object_store.get(slow_state, key, destination, timeout: 50)
          end)

        assert {:error, {:transport, :timeout}} = result
        assert elapsed < 1_000
        refute File.exists?(destination)
        refute File.exists?(destination <> ".part")
      end

      test "8. timed-out head and put are bounded", context do
        key = Gitility.ObjectStore.Conformance.key(context, "slow-phases")
        source = Gitility.ObjectStore.Conformance.write_source(context, "slow-source", "body")

        assert {:ok, head_state} =
                 Gitility.ObjectStore.Conformance.slow_state(
                   @object_store,
                   context.state,
                   __MODULE__,
                   :before_head
                 )

        {head_elapsed, head_result} =
          Gitility.ObjectStore.Conformance.timed(fn ->
            @object_store.head(head_state, key, timeout: 50)
          end)

        assert {:error, {:transport, :timeout}} = head_result
        assert head_elapsed < 1_000

        assert {:ok, put_state} =
                 Gitility.ObjectStore.Conformance.slow_state(
                   @object_store,
                   context.state,
                   __MODULE__,
                   :before_put
                 )

        {put_elapsed, put_result} =
          Gitility.ObjectStore.Conformance.timed(fn ->
            @object_store.put(
              put_state,
              source,
              key,
              Gitility.ObjectStore.Conformance.put_opts(:none, %{}, 50)
            )
          end)

        assert {:error, {:transport, :timeout}} = put_result
        assert put_elapsed < 1_000
      end

      test "9. eight concurrent create-only writers have exactly one winner", context do
        key = Gitility.ObjectStore.Conformance.key(context, "create-race")
        source = Gitility.ObjectStore.Conformance.write_source(context, "race-source", "race")

        tasks =
          for _index <- 1..8 do
            Task.async(fn ->
              @object_store.put(
                context.state,
                source,
                key,
                Gitility.ObjectStore.Conformance.put_opts(:none, %{})
              )
            end)
          end

        results = Enum.map(tasks, &Task.await(&1, 120_000))

        assert Enum.count(results, &match?({:ok, %{etag: _etag}}, &1)) == 1
        assert Enum.count(results, &(&1 == {:error, :precondition_failed})) == 7
      end

      test "10. concurrent overwrite never tears an in-flight read", context do
        key = Gitility.ObjectStore.Conformance.key(context, "read-overwrite")

        old =
          Gitility.ObjectStore.Conformance.write_source(
            context,
            "old",
            :binary.copy("a", 8_388_608)
          )

        new =
          Gitility.ObjectStore.Conformance.write_source(
            context,
            "new",
            :binary.copy("b", 8_388_608)
          )

        destination = Path.join(context.scratch, "concurrent-read")

        assert {:ok, %{etag: old_etag}} =
                 @object_store.put(
                   context.state,
                   old,
                   key,
                   Gitility.ObjectStore.Conformance.put_opts(:none, %{})
                 )

        reader =
          Task.async(fn ->
            @object_store.get(context.state, key, destination, timeout: 120_000)
          end)

        writer =
          Task.async(fn ->
            @object_store.put(
              context.state,
              new,
              key,
              Gitility.ObjectStore.Conformance.put_opts(old_etag, %{})
            )
          end)

        assert {:ok, %{etag: _etag}} = Task.await(writer, 120_000)
        assert {:ok, %{bytes: 8_388_608}} = Task.await(reader, 120_000)

        digest = Gitility.ObjectStore.Conformance.sha256(destination)

        assert digest in [
                 Gitility.ObjectStore.Conformance.sha256(old),
                 Gitility.ObjectStore.Conformance.sha256(new)
               ]
      end

      test "11. every callback rejects invalid keys", context do
        source = Gitility.ObjectStore.Conformance.write_source(context, "invalid-source", "x")

        for {index, key} <-
              Enum.with_index(["", "/a", "a/../b", "a//b", "a/", "a\0"], 1) do
          destination = Path.join(context.scratch, "invalid-#{index}")

          assert {:error, {:invalid_key, _message}} =
                   @object_store.head(context.state, key, timeout: 5_000)

          assert {:error, {:invalid_key, _message}} =
                   @object_store.get(context.state, key, destination, timeout: 5_000)

          assert {:error, {:invalid_key, _message}} =
                   @object_store.put(
                     context.state,
                     source,
                     key,
                     Gitility.ObjectStore.Conformance.put_opts(:none, %{})
                   )
        end
      end

      if @object_store == Gitility.ObjectStore.S3 do
        test "12. S3 URL encoding vectors round-trip without path reinterpretation", context do
          vectors = [
            {"a b", "a%20b"},
            {"a%b", "a%25b"},
            {"a?b", "a%3Fb"},
            {"a#b", "a%23b"},
            {"a+b", "a%2Bb"},
            {"ü/ß", "%C3%BC/%C3%9F"},
            {"x/y/z", "x/y/z"}
          ]

          source = Gitility.ObjectStore.Conformance.write_source(context, "encoded-source", "x")

          Enum.each(vectors, fn {key, encoded} ->
            full_key = Gitility.ObjectStore.Conformance.key(context, key)
            assert {:ok, url} = Gitility.ObjectStore.S3.url_for(context.state, full_key)
            assert String.ends_with?(url, "/#{encoded}")

            assert {:ok, %{etag: etag}} =
                     @object_store.put(
                       context.state,
                       source,
                       full_key,
                       Gitility.ObjectStore.Conformance.put_opts(:none, %{})
                     )

            assert {:ok, %{etag: ^etag, size: 1}} =
                     @object_store.head(context.state, full_key, timeout: 120_000)
          end)
        end
      end

      test "13. metadata boundary values round-trip", context do
        source = Gitility.ObjectStore.Conformance.write_source(context, "metadata-source", "m")

        rows = [
          Map.new(?a..?h, fn letter -> {<<letter>>, "v"} end),
          %{"value" => :binary.copy("x", 128)},
          Map.new(?a..?h, fn letter -> {<<letter>>, :binary.copy(<<letter>>, 127)} end)
        ]

        Enum.with_index(rows, 1)
        |> Enum.each(fn {metadata, index} ->
          key = Gitility.ObjectStore.Conformance.key(context, "metadata-#{index}")
          destination = Path.join(context.scratch, "metadata-#{index}")

          assert {:ok, %{etag: etag}} =
                   @object_store.put(
                     context.state,
                     source,
                     key,
                     Gitility.ObjectStore.Conformance.put_opts(:none, metadata)
                   )

          assert {:ok, %{etag: ^etag, metadata: ^metadata}} =
                   @object_store.head(context.state, key, timeout: 120_000)

          assert {:ok, %{etag: ^etag, metadata: ^metadata}} =
                   @object_store.get(context.state, key, destination, timeout: 120_000)
        end)
      end
    end
  end

  @doc false
  def scratch_directory do
    path = Path.join(System.tmp_dir!(), "gitility-object-store-#{random_segment()}")
    :ok = File.mkdir_p(path)
    path
  end

  @doc false
  def random_segment do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end

  @doc false
  def key(context, suffix), do: "#{context.prefix}/#{suffix}"

  @doc false
  def write_source(context, name, bytes) do
    path = Path.join(context.scratch, name)
    :ok = File.write(path, bytes, [:binary])
    path
  end

  @doc false
  def put_opts(if_match, metadata, timeout \\ @normal_timeout) do
    [
      if_match: if_match,
      metadata: metadata,
      content_type: @content_type,
      timeout: timeout
    ]
  end

  @doc false
  def write_large_file(path) do
    chunk = :binary.copy(<<0, 1, 2, 3, 4, 5, 6, 7>>, div(1024 * 1024, 8))

    case :file.open(String.to_charlist(path), [:raw, :binary, :write, :exclusive]) do
      {:ok, file} ->
        result =
          Enum.reduce_while(1..div(@large_bytes, byte_size(chunk)), :ok, fn _, :ok ->
            case :file.write(file, chunk) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)

        :file.close(file)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def sha256(path) do
    case :file.open(String.to_charlist(path), [:raw, :binary, :read]) do
      {:ok, file} ->
        try do
          sha256_chunks(file, :crypto.hash_init(:sha256))
        after
          :file.close(file)
        end

      {:error, reason} ->
        raise File.Error, reason: reason, action: "open", path: path
    end
  end

  @doc false
  def start_memory_sampler(owner, baseline) do
    spawn_link(fn -> sample_memory(owner, baseline) end)
  end

  @doc false
  def slow_state(Gitility.ObjectStore.Local, state, _module, phase) do
    hook = fn ->
      receive do
        :gitility_object_store_release -> :ok
      end
    end

    {:ok, Gitility.ObjectStore.Local.with_test_hooks(state, %{phase => hook})}
  end

  def slow_state(store, _state, module, _phase) do
    if function_exported?(module, :slow_store_init_arg, 0) do
      store.init(apply(module, :slow_store_init_arg, []))
    else
      {:error, :slow_store_init_arg_not_defined}
    end
  end

  @doc false
  def timed(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - started, result}
  end

  defp sha256_chunks(file, context) do
    case :file.read(file, 8 * 1024 * 1024) do
      {:ok, bytes} -> sha256_chunks(file, :crypto.hash_update(context, bytes))
      :eof -> context |> :crypto.hash_final() |> Base.encode16(case: :lower)
      {:error, reason} -> raise File.Error, reason: reason, action: "read", path: "conformance"
    end
  end

  defp sample_memory(owner, peak) do
    receive do
      {:stop, ^owner} ->
        send(owner, {:memory_peak, self(), max(peak, :erlang.memory(:total))})
    after
      10 -> sample_memory(owner, max(peak, :erlang.memory(:total)))
    end
  end
end
