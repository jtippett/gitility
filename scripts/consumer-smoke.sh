#!/usr/bin/env bash
# Verify the published package boundary from a consumer that deliberately
# does not depend on Req. Run on Linux: force-building the NIF is intentional.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/gitility-consumer.XXXXXX")"
package_dir="$scratch/gitility-package"
consumer_dir="$scratch/consumer"

cleanup() {
  rm -rf -- "$scratch"
}
trap cleanup EXIT INT TERM

(
  cd "$repo_root"
  MIX_ENV=prod mix hex.build --unpack --output "$package_dir" >/dev/null
)

mkdir -p "$consumer_dir"

cat >"$consumer_dir/mix.exs" <<'ELIXIR'
defmodule GitilityConsumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :gitility_consumer,
      version: "0.0.0",
      elixir: "~> 1.17",
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:gitility, path: System.fetch_env!("GITILITY_PACKAGE_PATH")},
      {:rustler, "~> 0.38"}
    ]
  end
end
ELIXIR

cat >"$consumer_dir/smoke.exs" <<'ELIXIR'
if Code.ensure_loaded?(Req) do
  raise "Req unexpectedly entered the consumer dependency graph"
end

case Gitility.ObjectStore.S3.init([]) do
  {:error, {:unsupported_operation, message}} when is_binary(message) -> :ok
  other -> raise "S3 without Req returned #{inspect(other)}"
end

Code.require_file(System.fetch_env!("GITILITY_SMART_HTTP_HELPER"))

defmodule GitilityConsumer.Smoke do
  def git!(directory, args) do
    prefix = if is_nil(directory), do: [], else: ["-C", directory]

    case System.cmd("git", prefix ++ args, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> raise "git #{Enum.join(args, " ")} exited #{status}: #{output}"
    end
  end

  def refs(repository) do
    repository
    |> git!(["for-each-ref", "--format=%(refname) %(objectname)"])
    |> String.split("\n", trim: true)
    |> MapSet.new()
  end

  def objects(repository) do
    repository
    |> git!(["cat-file", "--batch-all-objects", "--batch-check=%(objectname)"])
    |> String.split("\n", trim: true)
    |> MapSet.new()
  end
end

root = Path.join(System.tmp_dir!(), "gitility-consumer-#{System.unique_integer([:positive])}")
work = Path.join(root, "work")
upstream = Path.join(root, "upstream.git")
seed_mirror = Path.join(root, "seed.git")
restored = Path.join(root, "restored.git")
fresh = Path.join(root, "fresh.git")
store = {Gitility.ObjectStore.Local, [root: Path.join(root, "store")]}
key = "consumer/mirror.bundle"
refspecs = ["+refs/heads/*:refs/remotes/origin/*"]

try do
  GitilityConsumer.Smoke.git!(nil, ["init", "--initial-branch=main", work])
  GitilityConsumer.Smoke.git!(work, ["config", "user.name", "Gitility Consumer"])
  GitilityConsumer.Smoke.git!(work, ["config", "user.email", "consumer@gitility.invalid"])
  File.write!(Path.join(work, "README.md"), "generation one\n")
  GitilityConsumer.Smoke.git!(work, ["add", "README.md"])
  GitilityConsumer.Smoke.git!(work, ["commit", "-m", "generation one"])
  GitilityConsumer.Smoke.git!(nil, ["clone", "--bare", work, upstream])
  GitilityConsumer.Smoke.git!(work, ["remote", "add", "upstream", upstream])

  {:ok, started_server} =
    Gitility.TestSupport.SmartHTTPServer.start_link(project_root: root)

  Process.put({GitilityConsumer.Smoke, :server}, started_server)
  url = Gitility.TestSupport.SmartHTTPServer.url(started_server, "upstream.git")

  {:ok, seed_fetch} = Gitility.Fetch.fetch(seed_mirror, url, refspecs)
  true = seed_fetch.pack_received

  {:ok, %Gitility.Mirror.Receipt{generation: 1}} =
    Gitility.Mirror.publish(seed_mirror, store, key)

  {:ok, %Gitility.Mirror.Restore{generation: 1}} =
    Gitility.Mirror.restore(store, key, restored)

  File.write!(Path.join(work, "README.md"), "generation one\ngeneration two\n")
  GitilityConsumer.Smoke.git!(work, ["commit", "-am", "generation two"])
  GitilityConsumer.Smoke.git!(work, ["push", "upstream", "main"])

  {:ok, incremental} = Gitility.Fetch.fetch(restored, url, refspecs)
  true = incremental.updated_refs != []

  {:ok, %Gitility.Mirror.Receipt{generation: 2}} =
    Gitility.Mirror.publish(restored, store, key)

  {:ok, fresh_fetch} = Gitility.Fetch.fetch(fresh, url, refspecs)
  true = fresh_fetch.pack_received
  true = GitilityConsumer.Smoke.refs(restored) == GitilityConsumer.Smoke.refs(fresh)
  true = GitilityConsumer.Smoke.objects(restored) == GitilityConsumer.Smoke.objects(fresh)

  IO.puts(
    "consumer-smoke: COMPILE WITHOUT REQ + RESTORE -> FETCH -> PUBLISH PARITY OK"
  )
after
  case Process.delete({GitilityConsumer.Smoke, :server}) do
    server when is_pid(server) -> if Process.alive?(server), do: GenServer.stop(server)
    _other -> :ok
  end

  File.rm_rf!(root)
end
ELIXIR

export GITILITY_PACKAGE_PATH="$package_dir"
export GITILITY_SMART_HTTP_HELPER="$repo_root/test/support/smart_http_server.ex"
export GITILITY_BUILD=1
export CARGO_TARGET_DIR="${GITILITY_CONSUMER_CARGO_TARGET_DIR:-$repo_root/target}"

cd "$consumer_dir"
MIX_ENV=prod mix deps.get >/dev/null

if [ -e deps/req ]; then
  echo "consumer-smoke: Req unexpectedly resolved" >&2
  exit 1
fi

MIX_ENV=prod mix compile --warnings-as-errors
MIX_ENV=prod mix run --no-compile smoke.exs
