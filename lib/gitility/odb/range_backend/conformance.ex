defmodule Gitility.ODB.RangeBackend.Conformance do
  @moduledoc """
  Reusable ExUnit conformance case for `Gitility.ODB.RangeBackend` modules.

  The using test module supplies `backend_init_arg/0`, `backend_artifacts/0`,
  and `backend_publish_artifact/3`. The last callback publishes the supplied
  key and bytes into the initialized test backend. The kit uses it to add a
  deterministic 2 MiB-plus-17-byte artifact, guaranteeing that its range
  matrix crosses the Postgres backend's 1 MiB chunk seam without enlarging a
  repository fixture.

  Generated tests validate the manifest protocol, whole/first/last-byte
  reads, zero-length reads at zero and EOF, a chunk-boundary crossing,
  multiple keys in one request, out-of-bounds short reads, concurrent
  callback safety, and tolerant termination.

      defmodule MyApp.PackStoreConformanceTest do
        use Gitility.ODB.RangeBackend.Conformance,
          backend: MyApp.PackStore,
          concurrency: 4

        def backend_init_arg, do: [bucket: "test-packs"]
        def backend_artifacts, do: MyApp.PackFixtures.artifacts()
        def backend_publish_artifact(state, key, bytes),
          do: MyApp.PackFixtures.publish_artifact(state, key, bytes)
      end

  A deliberately broken backend can set `expected_failure: :short_read`; the
  generated exactness test then asserts that the conformance validator rejects
  it. An immutable backend whose fixture already contains
  `synthetic_artifact/0` can set `prepublished_synthetic: true`. Cases are not
  async because backend state often owns a connection or temporary directory.
  """

  defmacro __using__(opts) do
    backend = Keyword.fetch!(opts, :backend)
    concurrency = Keyword.get(opts, :concurrency, 4)
    expected_failure = Keyword.get(opts, :expected_failure)
    prepublished_synthetic = Keyword.get(opts, :prepublished_synthetic, false)

    quote bind_quoted: [
            backend: backend,
            concurrency: concurrency,
            expected_failure: expected_failure,
            prepublished_synthetic: prepublished_synthetic
          ] do
      use ExUnit.Case, async: false

      @range_backend backend
      @range_concurrency concurrency
      @range_expected_failure expected_failure
      @range_prepublished_synthetic prepublished_synthetic

      setup do
        {:ok, state} = @range_backend.init(backend_init_arg())

        artifacts =
          if @range_expected_failure or @range_prepublished_synthetic do
            backend_artifacts()
          else
            {key, bytes} = Gitility.ODB.RangeBackend.Conformance.synthetic_artifact()
            :ok = apply(__MODULE__, :backend_publish_artifact, [state, key, bytes])
            Map.put(backend_artifacts(), key, bytes)
          end

        on_exit(fn ->
          if function_exported?(@range_backend, :terminate, 2) do
            try do
              apply(@range_backend, :terminate, [:normal, state])
            catch
              _kind, _reason -> :ok
            end
          end
        end)

        %{state: state, artifacts: artifacts}
      end

      test "manifest has the versioned, content-addressed protocol shape", context do
        assert {:ok, manifest} = @range_backend.manifest(context.state)
        assert :ok = Gitility.ODB.RangeBackend.Conformance.validate_manifest(manifest)
      end

      if @range_expected_failure do
        test "conformance rejects the declared broken range reply", context do
          ranges = Gitility.ODB.RangeBackend.Conformance.probe_ranges(context.artifacts)
          reply = @range_backend.read_ranges(ranges, context.state)

          assert {:error, @range_expected_failure} =
                   Gitility.ODB.RangeBackend.Conformance.validate_ranges(ranges, reply)
        end
      else
        test "read_ranges returns exact bytes for arbitrary and boundary ranges", context do
          ranges = Gitility.ODB.RangeBackend.Conformance.probe_ranges(context.artifacts)
          reply = @range_backend.read_ranges(ranges, context.state)
          assert :ok = Gitility.ODB.RangeBackend.Conformance.validate_ranges(ranges, reply)
          assert {:ok, results} = reply

          Enum.each(ranges, fn range ->
            source = Map.fetch!(context.artifacts, range.key)
            assert results[range] == binary_part(source, range.offset, range.length)
          end)
        end

        test "out-of-bounds reads fail as short reads", context do
          range =
            Gitility.ODB.RangeBackend.Conformance.out_of_bounds_range(context.artifacts)

          assert {:error, :short_read} = @range_backend.read_ranges([range], context.state)
        end

        test "callbacks are safe under configured concurrency", context do
          ranges = Gitility.ODB.RangeBackend.Conformance.probe_ranges(context.artifacts)

          tasks =
            for _ <- 1..@range_concurrency do
              Task.async(fn -> @range_backend.read_ranges(ranges, context.state) end)
            end

          Enum.each(tasks, fn task ->
            assert :ok =
                     Gitility.ODB.RangeBackend.Conformance.validate_ranges(
                       ranges,
                       Task.await(task, 5_000)
                     )
          end)
        end

        if function_exported?(@range_backend, :terminate, 2) do
          test "terminate does not poison shared backend state", context do
            _result = apply(@range_backend, :terminate, [:shutdown, context.state])
            assert {:ok, %Gitility.PackManifest{}} = @range_backend.manifest(context.state)
          end
        else
          @tag skip: ":skipped — backend does not export optional terminate/2"
          test "terminate :skipped (optional callback not exported)", do: :ok
        end
      end
    end
  end

  @doc false
  def validate_manifest(%Gitility.PackManifest{} = manifest) do
    expected_length = if manifest.hash == :sha1, do: 40, else: 64

    cond do
      manifest.version != 1 ->
        {:error, :bad_version}

      manifest.hash not in [:sha1, :sha256] ->
        {:error, :bad_hash}

      not is_binary(manifest.generation) or manifest.generation == "" ->
        {:error, :bad_generation}

      not is_list(manifest.packs) ->
        {:error, :bad_packs}

      not is_list(manifest.loose) or
          Enum.any?(manifest.loose, fn key -> not is_binary(key) or key == "" end) ->
        {:error, :bad_loose}

      Enum.any?(manifest.packs, fn pack ->
        not match?(%Gitility.PackDescriptor{}, pack) or
          not is_binary(pack.id) or byte_size(pack.id) != expected_length or
          not String.match?(pack.id, ~r/\A[0-9a-fA-F]+\z/) or
          not is_binary(pack.pack_key) or pack.pack_key == "" or
          not is_binary(pack.index_key) or pack.index_key == "" or
          not is_integer(pack.pack_size) or pack.pack_size <= 0 or
          not is_integer(pack.index_size) or pack.index_size <= 0
      end) ->
        {:error, :bad_descriptor}

      manifest.packs |> Enum.map(&String.downcase(&1.id)) |> Enum.uniq() |> length() !=
          length(manifest.packs) ->
        {:error, :duplicate_id}

      true ->
        :ok
    end
  end

  def validate_manifest(_manifest), do: {:error, :invalid_manifest}

  @doc false
  def validate_ranges(ranges, {:ok, results}) when is_map(results) do
    cond do
      MapSet.new(Map.keys(results)) != MapSet.new(ranges) ->
        {:error, :incomplete_ranges}

      map_size(results) != length(Enum.uniq(ranges)) ->
        {:error, :incomplete_ranges}

      Enum.any?(ranges, fn range ->
        not is_binary(results[range]) or byte_size(results[range]) != range.length
      end) ->
        {:error, :short_read}

      true ->
        :ok
    end
  end

  def validate_ranges(_ranges, {:error, _reason}), do: {:error, :backend_error}
  def validate_ranges(_ranges, _reply), do: {:error, :invalid_return}

  @doc false
  def probe_ranges(artifacts) when is_map(artifacts) and map_size(artifacts) > 0 do
    {key, bytes} = Enum.max_by(artifacts, fn {_key, bytes} -> byte_size(bytes) end)
    size = byte_size(bytes)
    boundary = 1024 * 1024

    {other_key, other_bytes} =
      artifacts
      |> Enum.reject(fn {candidate, _bytes} -> candidate == key end)
      |> Enum.sort_by(&elem(&1, 0))
      |> hd()

    [
      %Gitility.ByteRange{key: key, offset: 0, length: size},
      %Gitility.ByteRange{key: key, offset: 0, length: 1},
      %Gitility.ByteRange{key: key, offset: size - 1, length: 1},
      %Gitility.ByteRange{key: key, offset: 0, length: 0},
      %Gitility.ByteRange{key: key, offset: size, length: 0},
      %Gitility.ByteRange{key: key, offset: boundary - 3, length: 11},
      %Gitility.ByteRange{key: other_key, offset: 0, length: min(byte_size(other_bytes), 7)}
    ]
  end

  @doc false
  def out_of_bounds_range(artifacts) do
    {key, bytes} = Enum.max_by(artifacts, fn {_key, bytes} -> byte_size(bytes) end)
    %Gitility.ByteRange{key: key, offset: byte_size(bytes), length: 1}
  end

  @doc false
  def synthetic_artifact do
    pattern = :binary.list_to_bin(Enum.to_list(0..255))
    bytes = :binary.copy(pattern, 8_192) <> binary_part(pattern, 0, 17)
    {"packs/pack-#{String.duplicate("e", 40)}.pack", bytes}
  end
end
