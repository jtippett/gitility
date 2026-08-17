defmodule Gitility.RefDB.Backend.Conformance do
  @moduledoc """
  Reusable ExUnit conformance case for `Gitility.RefDB.Backend` modules.

  The using module supplies `backend_refs/0`, returning at least two
  `Gitility.Ref` values in strict byte order. The generated suite checks the
  miss/error distinction, concurrent resolution, optional listing, provider
  protocol validation, and end-to-end DTO conversion.

      use Gitility.RefDB.Backend.Conformance,
        backend: MyApp.Refs,
        init_arg: :test_repository,
        concurrency: 4
  """

  alias Gitility.{Page, Ref, RefQuery, RefTarget}

  defmacro __using__(opts) do
    backend = Keyword.fetch!(opts, :backend)
    init_arg = Keyword.get(opts, :init_arg)
    concurrency = Keyword.get(opts, :concurrency, 4)
    expected_failure = Keyword.get(opts, :expected_failure)

    quote bind_quoted: [
            backend: backend,
            init_arg: init_arg,
            concurrency: concurrency,
            expected_failure: expected_failure
          ] do
      use ExUnit.Case, async: false

      @conformance_backend backend
      @conformance_init_arg init_arg
      @conformance_concurrency concurrency
      @conformance_expected_failure expected_failure

      setup do
        refs = backend_refs()
        true = length(refs) >= 2
        {:ok, state} = @conformance_backend.init(@conformance_init_arg)
        %{refs: refs, state: state}
      end

      if @conformance_expected_failure do
        test "generated conformance suite rejects the broken resolve reply", context do
          first = hd(context.refs)
          reply = @conformance_backend.resolve(first.name, context.state)

          assert {:error, @conformance_expected_failure} ==
                   Gitility.RefDB.Backend.Conformance.validate_resolve(reply)
        end

        test "generated conformance suite rejects the broken backend end to end", context do
          assert {:ok, supervisor} =
                   Gitility.RefDB.start_link(
                     backend: {@conformance_backend, @conformance_init_arg},
                     concurrency: @conformance_concurrency
                   )

          assert {:ok, refs} = Gitility.RefDB.handle(supervisor)
          first = hd(context.refs)
          result = Gitility.RefDB.resolve(refs, first.name)
          assert match?({:error, error} when error.code == :provider_protocol_error, result)
        end
      else
        test "resolve returns valid targets and a distinct missing result", context do
          Enum.each(context.refs, fn ref ->
            assert :ok ==
                     Gitility.RefDB.Backend.Conformance.validate_resolve(
                       @conformance_backend.resolve(ref.name, context.state)
                     )
          end)

          missing = Gitility.RefDB.Backend.Conformance.missing_name(context.refs)
          assert {:ok, :not_found} == @conformance_backend.resolve(missing, context.state)

          assert :backend_error ==
                   Gitility.RefDB.Backend.Conformance.classify_reply({:error, :sentinel})
        end

        test "resolve callbacks are safe under configured concurrency", context do
          first = hd(context.refs)

          tasks =
            for _ <- 1..@conformance_concurrency do
              Task.async(fn -> @conformance_backend.resolve(first.name, context.state) end)
            end

          Enum.each(tasks, fn task ->
            assert :ok ==
                     Gitility.RefDB.Backend.Conformance.validate_resolve(
                       Task.await(task, 5_000)
                     )
          end)
        end

        if function_exported?(@conformance_backend, :list, 2) do
          test "list returns one ordered Gitility.Page", context do
            query = Gitility.RefDB.Backend.Conformance.query(length(context.refs))
            reply = @conformance_backend.list(query, context.state)

            assert :ok ==
                     Gitility.RefDB.Backend.Conformance.validate_page(query, reply)
          end
        else
          @tag skip: ":skipped — backend does not export optional list/2"
          test "list :skipped (optional callback not exported)", do: :ok
        end

        test "targets round-trip through the supervised provider", context do
          assert {:ok, supervisor} =
                   Gitility.RefDB.start_link(
                     backend: {@conformance_backend, @conformance_init_arg},
                     concurrency: @conformance_concurrency
                   )

          assert {:ok, refs} = Gitility.RefDB.handle(supervisor)

          Enum.each(context.refs, fn expected ->
            assert {:ok, actual} = Gitility.RefDB.resolve(refs, expected.name)
            assert actual == expected.target
          end)

          if function_exported?(@conformance_backend, :list, 2) do
            assert {:ok, page} = Gitility.RefDB.list(refs, limit: length(context.refs))
            assert page.items == context.refs
          end
        end
      end
    end
  end

  @doc false
  def validate_resolve({:ok, :not_found}), do: :ok
  def validate_resolve({:ok, %RefTarget{} = target}), do: validate_target(target)
  def validate_resolve({:error, _reason}), do: {:error, :backend_error}
  def validate_resolve(_reply), do: {:error, :invalid_return}

  @doc false
  def validate_page(%RefQuery{} = query, {:ok, %Page{} = page}) do
    if Enum.all?(page.items, &match?(%Ref{}, &1)) do
      names = Enum.map(page.items, & &1.name)

      cond do
        length(page.items) > query.limit -> {:error, :limit_exceeded}
        names != Enum.sort(names) -> {:error, :not_sorted}
        length(names) != MapSet.size(MapSet.new(names)) -> {:error, :duplicate_names}
        Enum.any?(page.items, fn %Ref{target: target} -> validate_target(target) != :ok end) ->
          {:error, :invalid_target}

        page.truncated != is_binary(page.next_cursor) -> {:error, :cursor_mismatch}
        true -> :ok
      end
    else
      {:error, :invalid_item}
    end
  end

  def validate_page(_query, {:error, _reason}), do: {:error, :backend_error}
  def validate_page(_query, _reply), do: {:error, :invalid_return}

  @doc false
  def classify_reply({:ok, :not_found}), do: :not_found
  def classify_reply({:ok, %RefTarget{}}), do: :target
  def classify_reply({:error, _reason}), do: :backend_error
  def classify_reply(_reply), do: :invalid_return

  @doc false
  def query(limit), do: struct!(RefQuery, prefix: nil, limit: limit, cursor: nil)

  @doc false
  def missing_name(refs) do
    names = MapSet.new(Enum.map(refs, & &1.name))

    Stream.iterate(0, &(&1 + 1))
    |> Stream.map(&"refs/heads/gitility-conformance-missing-#{&1}")
    |> Enum.find(&(not MapSet.member?(names, &1)))
  end

  defp validate_target(%RefTarget{
         kind: :direct,
         oid: %Gitility.OID{} = oid,
         symbolic_target: nil,
         peeled: peeled
       }) do
    if valid_oid?(oid) and
         (is_nil(peeled) or
            (valid_oid?(peeled) and peeled.algorithm == oid.algorithm)) do
      :ok
    else
      {:error, :invalid_target}
    end
  end

  defp validate_target(%RefTarget{
         kind: :symbolic,
         oid: nil,
         symbolic_target: target,
         peeled: nil
       })
       when is_binary(target),
       do: :ok

  defp validate_target(_target), do: {:error, :invalid_target}

  defp valid_oid?(%Gitility.OID{algorithm: :sha1, bytes: bytes}),
    do: is_binary(bytes) and byte_size(bytes) == 20

  defp valid_oid?(%Gitility.OID{algorithm: :sha256, bytes: bytes}),
    do: is_binary(bytes) and byte_size(bytes) == 32

  defp valid_oid?(_oid), do: false
end
