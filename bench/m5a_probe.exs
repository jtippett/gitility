# Scratch diagnostic for the M5a sprite failures. NOT part of the suite;
# deleted before commit. Run on the sprite:
#   GITILITY_BUILD=1 mix run bench/m5a_probe.exs
Code.require_file("test/support/smart_http_server.ex")

defmodule M5aProbe do
  alias Gitility.Fetch

  def run do
    scratch = Path.join(System.tmp_dir!(), "m5a-probe-#{System.os_time(:millisecond)}")
    File.mkdir_p!(scratch)
    remote = Path.join(scratch, "remote.git")

    {_, 0} = System.cmd("git", ["init", "--bare", "--quiet", remote])
    work = Path.join(scratch, "work")
    {_, 0} = System.cmd("git", ["clone", "--quiet", remote, work], stderr_to_stdout: true)
    File.write!(Path.join(work, "file.txt"), "hello\n")

    git = fn args ->
      {out, code} =
        System.cmd("git", args,
          cd: work,
          stderr_to_stdout: true,
          env: [
            {"GIT_AUTHOR_NAME", "p"},
            {"GIT_AUTHOR_EMAIL", "p@p"},
            {"GIT_COMMITTER_NAME", "p"},
            {"GIT_COMMITTER_EMAIL", "p@p"},
            {"GIT_AUTHOR_DATE", "2026-01-01T00:00:00Z"},
            {"GIT_COMMITTER_DATE", "2026-01-01T00:00:00Z"}
          ]
        )

      if code != 0, do: raise("git #{inspect(args)} failed: #{out}")
    end

    git.(["add", "."])
    git.(["commit", "--quiet", "-m", "one"])
    git.(["push", "--quiet", "origin", "HEAD:refs/heads/main"])

    auth = "Basic Zm9vOmJhcg=="

    {:ok, server} =
      Gitility.TestSupport.SmartHTTPServer.start_link(
        project_root: scratch,
        require_authorization: auth
      )

    url = Gitility.TestSupport.SmartHTTPServer.url(server) <> "/remote.git"
    wildcard = "+refs/heads/*:refs/heads/*"

    step = fn label, dest, opts ->
      result = Fetch.fetch(Path.join(scratch, dest), url, [wildcard], opts)
      alive = Process.alive?(server)

      IO.puts(
        "#{label}: #{inspect(elem(result, 0))} " <>
          inspect(
            case result do
              {:ok, r} -> {:updated, length(r.updated_refs)}
              {:error, e} -> {e.code, e.message}
            end
          ) <> " | server_alive=#{alive}"
      )
    end

    step.("good-1", "d1.git", authorization: auth)
    step.("good-2 same dest", "d1.git", authorization: auth)
    step.("good-3 new dest", "d2.git", authorization: auth)
    step.("bad-auth", "d3.git", authorization: "Basic bad")
    step.("good-after-bad", "d4.git", authorization: auth)
    step.("no-auth", "d5.git", [])
  end
end

M5aProbe.run()
