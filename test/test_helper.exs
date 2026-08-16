project_root = Path.expand("..", __DIR__)
fixture_generator = Path.join([project_root, "fixtures", "generate.sh"])
generated_fixtures = Path.join([project_root, "fixtures", "generated"])
completion_marker = Path.join(generated_fixtures, "OIDS")
hash_marker = Path.join(generated_fixtures, "GENERATOR_HASH")

Code.require_file("differential/oracle.ex", __DIR__)
Code.require_file("differential/allowlist.ex", __DIR__)

{generator_hash, 0} = System.cmd("git", ["hash-object", fixture_generator])
fixtures_current? =
  File.regular?(completion_marker) and
    case File.read(hash_marker) do
      {:ok, hash} -> String.trim(hash) == String.trim(generator_hash)
      {:error, _reason} -> false
    end

unless fixtures_current? do
  IO.puts("Generated fixture corpus is missing, incomplete, or stale; running fixtures/generate.sh")

  case System.cmd("bash", [fixture_generator],
         cd: project_root,
         env: Gitility.Differential.Oracle.git_environment(),
         stderr_to_stdout: true
       ) do
    {output, 0} -> IO.write(output)
    {output, status} -> raise "fixture generation failed (#{status}):\n#{output}"
  end
end

pinned_git_version =
  project_root
  |> Path.join("test/differential/GIT_VERSION")
  |> File.read!()
  |> String.trim()

runtime_git_version = Gitility.Differential.Oracle.git_version()

IO.puts(
  "Canonical Git oracle: git version #{runtime_git_version} " <>
    "(pinned #{pinned_git_version})"
)

ExUnit.start(exclude: [soak: true])
