defmodule Gitility.M6.BundleRepositoryTest do
  use ExUnit.Case, async: false

  alias Gitility.{Bundle, Bundle.Format, Bundle.Writer, Error, Repository}
  alias Gitility.Fetch.Locks

  @moduletag :gitility_engine
  @maximum_generation 18_446_744_073_709_551_615

  setup do
    directory =
      Path.join(
        System.tmp_dir!(),
        "gitility-m6-bundle-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(directory) end)
    %{directory: directory}
  end

  test "explicit generations, strict unborn HEAD, and writer mode are preserved", context do
    source = Path.join(context.directory, "empty.git")
    git!(["init", "--bare", source])
    git!(["-C", source, "symbolic-ref", "HEAD", "refs/heads/trunk"])
    path = Path.join(context.directory, "mirror.bundle")

    assert {:ok, receipt} =
             Bundle.write(path,
               source: {:repository, source},
               generation: 7,
               strict_refs: true,
               mode: 0o600
             )

    assert receipt.generation == 7
    assert receipt.refs == 0
    assert receipt.warnings == []
    assert {:ok, toc} = Format.parse(path)
    assert toc.generation == 7
    assert toc.refs == []
    assert toc.metadata["head_symref"] == "refs/heads/trunk"
    assert {:ok, stat} = File.stat(path)
    assert Bitwise.band(stat.mode, 0o777) == 0o600

    assert {:error, %Error{code: :invalid_argument}} =
             Bundle.write(path,
               source: {:repository, source},
               generation: 7,
               strict_refs: true
             )

    assert {:ok, %{generation: 9, warnings: []}} =
             Bundle.write(path,
               source: {:repository, source},
               generation: 9,
               strict_refs: true
             )

    for generation <- [0, @maximum_generation + 1] do
      assert {:error, %Error{code: :invalid_argument}} =
               Bundle.write(Path.join(context.directory, "bad-#{generation}.bundle"),
                 source: {:repository, source},
                 generation: generation
               )
    end

    assert {:error, %Error{code: :invalid_argument}} =
             Bundle.write(path, [{:source, {:repository, source}} | :improper])
  end

  test "default generation reports exhaustion without overflowing the v1 field", context do
    source = Path.join(context.directory, "empty.git")
    git!(["init", "--bare", source])
    path = Path.join(context.directory, "exhausted.bundle")

    assert {:ok, %{generation: @maximum_generation}} =
             Writer.write(path,
               pairs: [],
               hash_algorithm: :sha1,
               generation: @maximum_generation,
               metadata: %{"source_identity" => "m6:test"},
               refs: []
             )

    assert {:error,
            %Error{
              code: :unsupported_operation,
              message: "bundle generation space exhausted"
            }} = Bundle.write(path, source: {:repository, source})

    assert {:ok, %{generation: @maximum_generation}} = Format.parse(path)
  end

  test "strict refs reject missing targets while lenient writes retain warnings", context do
    source = Path.join(context.directory, "dangling.git")
    git!(["init", "--bare", source])
    File.mkdir_p!(Path.join(source, "refs/heads"))
    File.write!(Path.join(source, "refs/heads/main"), String.duplicate("f", 40) <> "\n")
    File.write!(Path.join(source, "HEAD"), "ref: refs/heads/main\n")

    strict_path = Path.join(context.directory, "strict.bundle")

    assert {:error, %Error{code: :missing_object}} =
             Bundle.write(strict_path,
               source: {:repository, source},
               strict_refs: true
             )

    refute File.exists?(strict_path)

    lenient_path = Path.join(context.directory, "lenient.bundle")
    assert {:ok, receipt} = Bundle.write(lenient_path, source: {:repository, source})
    assert Enum.any?(receipt.warnings, &(&1.code == :malformed_ref))
  end

  test "strict refs allow only a valid branch symref for an unborn HEAD", context do
    for {name, symref} <- [
          {"tag", "refs/tags/missing"},
          {"self", "HEAD"},
          {"invalid", "refs/heads/bad..name"}
        ] do
      source = Path.join(context.directory, "#{name}.git")
      git!(["init", "--bare", source])
      File.write!(Path.join(source, "HEAD"), "ref: #{symref}\n")
      path = Path.join(context.directory, "#{name}.bundle")

      assert {:error, %Error{code: :malformed_ref}} =
               Bundle.write(path,
                 source: {:repository, source},
                 strict_refs: true
               )

      refute File.exists?(path)
    end
  end

  test "init_bare validates without touching the filesystem", context do
    unsupported = Path.join([context.directory, "missing-parent", "sha256.git"])

    assert {:error, %Error{code: :unsupported_hash}} =
             Repository.init_bare(unsupported, hash: :sha256)

    refute File.exists?(Path.dirname(unsupported))

    nonempty = Path.join(context.directory, "nonempty")
    File.mkdir_p!(nonempty)
    marker = Path.join(nonempty, "keep")
    File.write!(marker, "untouched")

    assert {:error, %Error{code: :invalid_argument}} = Repository.init_bare(nonempty)
    assert File.read!(marker) == "untouched"
    assert {:error, %Error{code: :invalid_argument}} = Repository.init_bare(nonempty, nope: true)
    assert {:error, %Error{code: :invalid_argument}} = Repository.init_bare(nonempty, :not_a_list)
  end

  test "bundle and writer cleanup leave pre-existing decoy temporary paths untouched", context do
    source = Path.join(context.directory, "decoy-source.git")
    git!(["init", "--bare", source])
    path = Path.join(context.directory, "decoy.bundle")
    staging = Path.join(context.directory, ".decoy.bundle.staging-#{String.duplicate("a", 32)}")
    writer = Path.join(context.directory, ".decoy.bundle.tmp-#{String.duplicate("b", 32)}")
    marker = Path.join(staging, "owner")

    File.mkdir!(staging)
    File.write!(marker, "staging owner")
    File.write!(writer, "writer owner")

    assert {:ok, _receipt} = Bundle.write(path, source: {:repository, source})
    assert File.read!(marker) == "staging owner"
    assert File.read!(writer) == "writer owner"
  end

  test "init_bare shares the fetch lease and returns busy without touching the path", context do
    destination = Path.join(context.directory, "leased-init.git")
    expanded = Path.expand(destination)
    assert :ok = Locks.acquire(expanded, 5_000)

    try do
      assert {:error,
              %Error{code: :busy, operation: :repository_init_bare, retryable: true}} =
               Repository.init_bare(destination)

      refute File.exists?(destination)
    after
      Locks.release(expanded)
    end
  end

  defp git!(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed (#{status}): #{output}")
    end
  end
end
