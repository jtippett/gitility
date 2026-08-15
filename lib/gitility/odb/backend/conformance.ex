defmodule Gitility.ODB.Backend.Conformance do
  @moduledoc """
  Reusable ExUnit conformance case for `Gitility.ODB.Backend` implementations.

  The using module supplies a backend, its init argument, and a
  `backend_objects/0` fixture returning at least two objects that the backend
  serves. The generated tests cover complete batch maps, miss/error
  distinction, concurrent callback safety, header fallback equivalence,
  optional prefetch tolerance, and verified provider round trips.

      defmodule MyApp.PostgresObjectsConformanceTest do
        use Gitility.ODB.Backend.Conformance,
          backend: MyApp.PostgresObjects,
          init_arg: :test_repository,
          concurrency: 4

        def backend_objects do
          MyApp.ObjectFixtures.objects()
        end
      end

  `backend_objects/0` must return `Gitility.Object` structs with populated
  OIDs. Conformance tests are intentionally not async because they start a
  provider supervision tree and exercise native round trips.
  """

  alias Gitility.{Object, ObjectHeader}

  defmacro __using__(opts) do
    backend = Keyword.fetch!(opts, :backend)
    init_arg = Keyword.get(opts, :init_arg)
    concurrency = Keyword.get(opts, :concurrency, 4)

    quote bind_quoted: [
            backend: backend,
            init_arg: init_arg,
            concurrency: concurrency
          ] do
      use ExUnit.Case, async: false

      import Gitility.ODB.Backend.Conformance,
        only: [fallback_headers: 3, validate_batch: 2]

      @conformance_backend backend
      @conformance_init_arg init_arg
      @conformance_concurrency concurrency

      setup do
        objects = backend_objects()
        true = length(objects) >= 2
        {:ok, state} = @conformance_backend.init(@conformance_init_arg)
        %{objects: objects, oids: Enum.map(objects, & &1.oid), state: state}
      end

      test "backend returns one result for every requested OID", context do
        reply = @conformance_backend.read_many(context.oids, context.state)
        assert :ok = validate_batch(context.oids, reply)
      end

      test ":not_found is a per-object result distinct from backend failure", context do
        first = hd(context.oids)
        missing = Gitility.ODB.Backend.Conformance.missing_oid(first)
        reply = @conformance_backend.read_many([first, missing], context.state)
        assert :ok = validate_batch([first, missing], reply)
        assert {:ok, results} = reply
        assert results[first] != :not_found
        assert results[missing] == :not_found

        assert :backend_error =
                 Gitility.ODB.Backend.Conformance.classify_reply({:error, :sentinel})
      end

      test "callbacks are safe under configured concurrency", context do
        tasks =
          for _ <- 1..@conformance_concurrency do
            Task.async(fn -> @conformance_backend.read_many(context.oids, context.state) end)
          end

        Enum.each(tasks, fn task ->
          assert :ok = validate_batch(context.oids, Task.await(task, 5_000))
        end)
      end

      test "read_headers matches the documented read_many fallback", context do
        expected = fallback_headers(context.oids, context.state, @conformance_backend)

        actual =
          if function_exported?(@conformance_backend, :read_headers, 2) do
            apply(@conformance_backend, :read_headers, [context.oids, context.state])
          else
            expected
          end

        assert :ok = validate_batch(context.oids, actual)
        assert actual == expected
      end

      test "optional prefetch is tolerant", context do
        if function_exported?(@conformance_backend, :prefetch, 2) do
          result = @conformance_backend.prefetch(context.oids, context.state)
          assert result == :ok or match?({:error, _reason}, result)
        else
          assert true
        end
      end

      test "objects round-trip through a verified provider store", context do
        assert {:ok, odb} =
                 Gitility.ODB.start_link(
                   backend: {@conformance_backend, @conformance_init_arg},
                   concurrency: @conformance_concurrency
                 )

        assert {:ok, returned} = Gitility.ODB.read_many(odb, context.oids)

        Enum.each(context.objects, fn object ->
          assert returned[object.oid] == object
        end)
      end
    end
  end

  @doc false
  def validate_batch(oids, {:ok, results}) when is_map(results) do
    expected = MapSet.new(oids)
    actual = results |> Map.keys() |> MapSet.new()

    cond do
      map_size(results) != length(oids) -> {:error, :incomplete_batch}
      actual != expected -> {:error, :wrong_object_ids}
      true -> :ok
    end
  end

  def validate_batch(_oids, {:error, _reason}), do: {:error, :backend_error}
  def validate_batch(_oids, _reply), do: {:error, :invalid_return}

  @doc false
  def classify_reply({:ok, results}) when is_map(results), do: :object_results
  def classify_reply({:error, _reason}), do: :backend_error
  def classify_reply(_reply), do: :invalid_return

  @doc false
  def fallback_headers(oids, state, backend) do
    case backend.read_many(oids, state) do
      {:ok, objects} ->
        {:ok,
         Map.new(objects, fn
           {oid, :not_found} ->
             {oid, :not_found}

           {oid, %Object{} = object} ->
             {oid,
              %ObjectHeader{
                oid: oid,
                type: object.type,
                size: byte_size(object.data)
              }}
         end)}

      error ->
        error
    end
  end

  @doc false
  def missing_oid(%Gitility.OID{algorithm: algorithm, bytes: bytes}) do
    replacement = :binary.copy(<<255>>, byte_size(bytes))
    %Gitility.OID{algorithm: algorithm, bytes: replacement}
  end
end
