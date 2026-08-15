defmodule Gitility.ODB.RangeBackend.Conformance do
  @moduledoc """
  Reusable ExUnit conformance case for `Gitility.ODB.RangeBackend` modules.

  The using test module supplies `backend_init_arg/0` and
  `backend_artifacts/0`. The latter returns a map of manifest keys to complete
  artifact binaries. Generated tests validate the manifest protocol, exact
  byte counts (including arbitrary offsets, last-byte reads, and zero-length
  reads), reply completeness, concurrent callback safety, and tolerant
  termination.

      defmodule MyApp.PackStoreConformanceTest do
        use Gitility.ODB.RangeBackend.Conformance,
          backend: MyApp.PackStore,
          concurrency: 4

        def backend_init_arg, do: [bucket: "test-packs"]
        def backend_artifacts, do: MyApp.PackFixtures.artifacts()
      end

  A deliberately broken backend can set `expected_failure: :short_read`; the
  generated exactness test then asserts that the conformance validator rejects
  it. Cases are not async because backend state often owns a connection or
  temporary directory.
  """

  defmacro __using__(opts) do
    backend = Keyword.fetch!(opts, :backend)
    concurrency = Keyword.get(opts, :concurrency, 4)
    expected_failure = Keyword.get(opts, :expected_failure)

    quote bind_quoted: [
            backend: backend,
            concurrency: concurrency,
            expected_failure: expected_failure
          ] do
      use ExUnit.Case, async: false

      @range_backend backend
      @range_concurrency concurrency
      @range_expected_failure expected_failure

      setup do
        {:ok, state} = @range_backend.init(backend_init_arg())

        on_exit(fn ->
          if function_exported?(@range_backend, :terminate, 2) do
            try do
              @range_backend.terminate(:normal, state)
            catch
              _kind, _reason -> :ok
            end
          end
        end)

        %{state: state, artifacts: backend_artifacts()}
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
          test "terminate tolerates ordinary shutdown", context do
            assert @range_backend.terminate(:shutdown, context.state) != :raise
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
    {key, bytes} = Enum.find(artifacts, fn {_key, bytes} -> byte_size(bytes) >= 2 end)
    middle = div(byte_size(bytes), 2)

    [
      %Gitility.ByteRange{key: key, offset: middle, length: 1},
      %Gitility.ByteRange{key: key, offset: byte_size(bytes) - 1, length: 1},
      %Gitility.ByteRange{key: key, offset: 0, length: 0}
    ]
  end
end
