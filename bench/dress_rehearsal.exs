# Real-world dress rehearsal: take a real repository, bundle it to one file,
# "ship" the file (copy = the S3 round trip; transport is just bytes), open it
# cold, and check every query answer against real git on the source repo.
#
# Covers both product flows:
#   A. Bundle.write/open — "clone a repo to a single S3 file" (refs + objects)
#   B. PackFetch into: {:bundle, path} — hydration snapshot, cold then warm
#      (warm runs under a byte budget far below pack size, so any remote
#      fetch would trip it — success proves the bundle served everything)
#
# Usage (remote sprite only — never load the NIF on a Mac):
#   GITILITY_BUILD=1 mix run bench/dress_rehearsal.exs <source.git> <workdir>

alias Gitility.{Bundle, Repository, RefDB, OID, Limits}
alias Gitility.ODB.PackFetch

defmodule Rehearsal do
  def start, do: Agent.start_link(fn -> [] end, name: __MODULE__)

  def check(name, fun) do
    {us, result} =
      :timer.tc(fn ->
        try do
          fun.()
        rescue
          e -> {:fail, Exception.format(:error, e, __STACKTRACE__)}
        end
      end)

    ms = div(us, 1000)

    case result do
      :ok ->
        IO.puts("[PASS] #{name} (#{ms}ms)")

      {:ok, detail} ->
        IO.puts("[PASS] #{name} (#{ms}ms) — #{detail}")

      {:fail, detail} ->
        Agent.update(__MODULE__, &[name | &1])
        IO.puts("[FAIL] #{name} (#{ms}ms)\n#{indent(detail)}")
    end
  end

  def failures, do: Agent.get(__MODULE__, & &1) |> Enum.reverse()

  defp indent(detail),
    do: detail |> to_string() |> String.split("\n") |> Enum.map_join("\n", &("       " <> &1))

  def git!(dir, args) do
    case System.cmd("git", ["-C", dir | args]) do
      {out, 0} -> out
      {out, code} -> raise "git #{Enum.join(args, " ")} exited #{code}: #{out}"
    end
  end

  def git_lines!(dir, args), do: dir |> git!(args) |> String.split("\n", trim: true)

  def hex(%OID{} = oid), do: OID.to_string(oid)
  def hex(nil), do: nil

  def sha256(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

  def diff_sets(label, expected, actual) do
    missing = MapSet.difference(expected, actual) |> Enum.take(5)
    extra = MapSet.difference(actual, expected) |> Enum.take(5)

    if missing == [] and extra == [] do
      {:ok, "#{label}: #{MapSet.size(actual)} entries match"}
    else
      {:fail,
       "#{label}: expected #{MapSet.size(expected)}, got #{MapSet.size(actual)}\n" <>
         "missing (≤5): #{inspect(missing)}\nextra (≤5): #{inspect(extra)}"}
    end
  end

  def page_all(fetch_page, cursor \\ nil, acc \\ []) do
    case fetch_page.(cursor) do
      {:ok, %{items: items, next_cursor: nil}} -> {:ok, acc ++ items}
      {:ok, %{items: items, next_cursor: next}} -> page_all(fetch_page, next, acc ++ items)
      other -> other
    end
  end
end

[source, workdir] = System.argv()
File.rm_rf!(workdir)
File.mkdir_p!(workdir)
{:ok, _} = Rehearsal.start()

head = source |> Rehearsal.git!(["rev-parse", "HEAD"]) |> String.trim()
head5 = source |> Rehearsal.git!(["rev-parse", "HEAD~5"]) |> String.trim()
identity = "rehearsal:" <> Path.basename(source)

IO.puts("=== Flow A: Bundle.write → ship → open → query (source #{source}, HEAD #{head}) ===")

bundle_a = Path.join(workdir, "clone-a.bundle")
bundle_b = Path.join(workdir, "clone-b.bundle")
shipped = Path.join(workdir, "shipped.bundle")

Rehearsal.check("bundle write", fn ->
  {:ok, receipt} =
    Bundle.write(bundle_a, source: {:repository, source}, source_identity: identity)

  mb = Float.round(receipt.bytes / 1_048_576, 1)

  {:ok,
   "gen=#{receipt.generation} files=#{receipt.files} refs=#{receipt.refs} #{mb}MB warnings=#{inspect(receipt.warnings)}"}
end)

Rehearsal.check("bundle write determinism", fn ->
  {:ok, _} = Bundle.write(bundle_b, source: {:repository, source}, source_identity: identity)

  case {Rehearsal.sha256(bundle_a), Rehearsal.sha256(bundle_b)} do
    {same, same} -> {:ok, "sha256 #{String.slice(same, 0, 16)}… identical"}
    {a, b} -> {:fail, "two writes differ: #{a} vs #{b}"}
  end
end)

Rehearsal.check("bundle verify", fn ->
  :ok = Bundle.verify(bundle_a)
  :ok
end)

Rehearsal.check("bundle info", fn ->
  {:ok, info} = Bundle.info(bundle_a)

  if info.generation == 1 and info.source_identity == identity and info.ref_count > 0 do
    {:ok,
     "v#{info.format_version} #{info.hash_algorithm} refs=#{info.ref_count} files=#{info.file_count}"}
  else
    {:fail, inspect(info)}
  end
end)

File.cp!(bundle_a, shipped)

{:ok, repository} =
  (fn ->
     {us, result} =
       :timer.tc(fn -> Bundle.open(shipped, into: {:dir, Path.join(workdir, "hydrated")}) end)

     IO.puts("[info] Bundle.open on shipped copy: #{div(us, 1000)}ms")
     result
   end).()

Rehearsal.check("refs match git for-each-ref (names, oids, peeled)", fn ->
  {:ok, refs} =
    Rehearsal.page_all(fn cursor -> RefDB.list(repository.refs, limit: 100, cursor: cursor) end)

  ours =
    refs
    |> Enum.filter(&String.starts_with?(&1.name, "refs/"))
    |> Enum.map(fn r ->
      "#{r.name} #{Rehearsal.hex(r.target.oid)} #{Rehearsal.hex(r.target.peeled) || "-"}"
    end)
    |> MapSet.new()

  theirs =
    source
    |> Rehearsal.git_lines!(["for-each-ref", "--format=%(refname) %(objectname) %(*objectname)"])
    |> Enum.map(fn line ->
      case String.split(line, " ") do
        [name, oid, ""] -> "#{name} #{oid} -"
        [name, oid, peeled] -> "#{name} #{oid} #{peeled}"
      end
    end)
    |> MapSet.new()

  Rehearsal.diff_sets("refs", theirs, ours)
end)

{:ok, snapshot} = Repository.snapshot(repository, :head)

Rehearsal.check("read_file README.md byte-identical to git show", fn ->
  {:ok, file} = Gitility.read_file(snapshot, "README.md")
  expected = Rehearsal.git!(source, ["show", "#{head}:README.md"])

  if file.data == expected,
    do: {:ok, "#{byte_size(file.data)} bytes"},
    else: {:fail, "content differs"}
end)

Rehearsal.check("read_file lib/phoenix/router.ex byte-identical to git show", fn ->
  {:ok, file} = Gitility.read_file(snapshot, "lib/phoenix/router.ex", max_bytes: 4_000_000)
  expected = Rehearsal.git!(source, ["show", "#{head}:lib/phoenix/router.ex"])

  if file.data == expected,
    do: {:ok, "#{byte_size(file.data)} bytes"},
    else: {:fail, "content differs"}
end)

Rehearsal.check("list_tree recursive matches git ls-tree -r", fn ->
  {:ok, entries} =
    Rehearsal.page_all(fn cursor ->
      Gitility.list_tree(snapshot, "",
        recursive: true,
        types: [:blob],
        limit: 2000,
        cursor: cursor
      )
    end)

  ours = entries |> Enum.map(& &1.path) |> MapSet.new()

  theirs =
    source
    |> Rehearsal.git_lines!(["ls-tree", "-r", head])
    |> Enum.filter(&String.contains?(&1, " blob "))
    |> Enum.map(fn line -> line |> String.split("\t", parts: 2) |> List.last() end)
    |> MapSet.new()

  Rehearsal.diff_sets("paths", theirs, ours)
end)

Rehearsal.check("log(limit: 30) matches git log order + ids", fn ->
  {:ok, page} = Gitility.log(snapshot, limit: 30)
  ours = Enum.map(page.items, &Rehearsal.hex(&1.id))
  theirs = Rehearsal.git_lines!(source, ["log", "--format=%H", "-n", "30", head])

  if ours == theirs do
    {:ok, "30 commits, identical order"}
  else
    {:fail,
     "ours[0..2]=#{inspect(Enum.take(ours, 3))}\ngit [0..2]=#{inspect(Enum.take(theirs, 3))}\nset_equal=#{MapSet.new(ours) == MapSet.new(theirs)}"}
  end
end)

Rehearsal.check("history of lib/phoenix/router.ex matches git log -- path", fn ->
  {:ok, page} = Gitility.history(snapshot, "lib/phoenix/router.ex", limit: 5)

  ours =
    Enum.map(page.items, fn item ->
      cond do
        match?(%OID{}, Map.get(item, :id)) -> Rehearsal.hex(item.id)
        match?(%{commit: _}, item) -> Rehearsal.hex(item.commit.id)
        true -> inspect(item)
      end
    end)

  theirs =
    Rehearsal.git_lines!(source, [
      "log",
      "--format=%H",
      "-n",
      "5",
      head,
      "--",
      "lib/phoenix/router.ex"
    ])

  if ours == theirs,
    do: {:ok, "5 commits identical"},
    else: {:fail, "ours=#{inspect(ours)}\ngit =#{inspect(theirs)}"}
end)

Rehearsal.check("blame mix.exs lines 1..20 matches git blame --porcelain", fn ->
  {:ok, blame} = Gitility.blame(snapshot, "mix.exs", lines: 1..20)

  ours =
    for hunk <- blame.hunks, line <- hunk.final_range, into: %{} do
      {line, Rehearsal.hex(hunk.commit_oid)}
    end

  theirs =
    source
    |> Rehearsal.git_lines!(["blame", "--porcelain", "-L", "1,20", head, "--", "mix.exs"])
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^([0-9a-f]{40}) \d+ (\d+)/, line) do
        [_, sha, final] -> [{String.to_integer(final), sha}]
        nil -> []
      end
    end)
    |> Map.new()

  if ours == theirs do
    {:ok, "20 lines, #{ours |> Map.values() |> Enum.uniq() |> length()} distinct commits"}
  else
    mismatched = Enum.filter(1..20, &(ours[&1] != theirs[&1]))

    {:fail,
     "lines differing: #{inspect(mismatched)}\nours=#{inspect(Map.take(ours, mismatched))}\ngit =#{inspect(Map.take(theirs, mismatched))}"}
  end
end)

Rehearsal.check("search matches git grep (paths + count)", fn ->
  needle = "defmodule Phoenix.Router do"
  {:ok, results} = Gitility.search(snapshot, needle, pathspecs: ["lib/**"])
  ours = results.items |> Enum.map(& &1.path) |> MapSet.new()

  theirs =
    source
    |> Rehearsal.git_lines!(["grep", "-F", needle, head, "--", "lib/"])
    |> Enum.map(fn line -> line |> String.split(":", parts: 3) |> Enum.at(1) end)
    |> MapSet.new()

  Rehearsal.diff_sets("hit paths", theirs, ours)
end)

Rehearsal.check("diff HEAD~5..HEAD matches git diff --name-only", fn ->
  {:ok, base} = Repository.snapshot(repository, {:oid, OID.parse!(head5)})
  {:ok, diff} = Gitility.diff(base, snapshot, format: :summary)

  ours =
    diff.files
    |> Enum.flat_map(&Enum.reject([&1.old_path, &1.new_path], fn p -> is_nil(p) end))
    |> MapSet.new()

  theirs = source |> Rehearsal.git_lines!(["diff", "--name-only", head5, head]) |> MapSet.new()
  Rehearsal.diff_sets("changed paths", theirs, ours)
end)

IO.puts(
  "\n=== Flow B: PackFetch into: {:bundle, path} — cold hydrate, warm restart under budget ==="
)

odb_bundle = Path.join(workdir, "hydration.bundle")
published = Path.join(workdir, "published")

:ok =
  (fn ->
     {us, result} =
       :timer.tc(fn -> Gitility.ODB.RangeBackend.LocalDirectory.publish(source, published) end)

     IO.puts("[info] LocalDirectory.publish (repo → immutable pack store): #{div(us, 1000)}ms")
     result
   end).()

pack_fetch_opts = fn extra ->
  [
    backend: {Gitility.ODB.RangeBackend.LocalDirectory, published},
    into: {:bundle, odb_bundle},
    limits:
      Limits.new(
        timeout_ms: 120_000,
        max_provider_requests: 1_000_000,
        max_provider_bytes: 2 * 1024 * 1024 * 1024,
        max_result_bytes: 64 * 1024 * 1024
      ),
    hash: :sha1,
    bundle_source_identity: "rehearsal:hydration"
  ] ++ extra
end

cold_sup =
  (fn ->
     {us, {:ok, sup}} = :timer.tc(fn -> PackFetch.start_link(pack_fetch_opts.([])) end)
     IO.puts("[info] cold hydration + publication: #{div(us, 1000)}ms")
     sup
   end).()

Rehearsal.check("hydration bundle published (ODB-only, generation 1)", fn ->
  {:ok, info} = Bundle.info(odb_bundle)

  if info.ref_count == 0 and info.generation == 1 and
       info.source_identity == "rehearsal:hydration" do
    {:ok, "files=#{info.file_count} bytes=#{info.bytes}"}
  else
    {:fail, inspect(info)}
  end
end)

Rehearsal.check("ancestry queries through cold store", fn ->
  {:ok, odb} = Gitility.ODB.handle(cold_sup)

  with {:ok, true} <- Gitility.ancestor?(odb, OID.parse!(head5), OID.parse!(head)),
       {:ok, false} <- Gitility.ancestor?(odb, OID.parse!(head), OID.parse!(head5)) do
    {:ok, "HEAD~5 is ancestor of HEAD, not vice versa"}
  else
    other -> {:fail, inspect(other)}
  end
end)

sha_before_warm = Rehearsal.sha256(odb_bundle)
:ok = Supervisor.stop(cold_sup)

Rehearsal.check("warm restart under 200KB remote budget (bundle must serve everything)", fn ->
  {us, result} =
    :timer.tc(fn -> PackFetch.start_link(pack_fetch_opts.(max_hydration_bytes: 200_000)) end)

  case result do
    {:ok, warm_sup} ->
      {:ok, odb} = Gitility.ODB.handle(warm_sup)
      {:ok, true} = Gitility.ancestor?(odb, OID.parse!(head5), OID.parse!(head))
      :ok = Supervisor.stop(warm_sup)

      if Rehearsal.sha256(odb_bundle) == sha_before_warm do
        {:ok, "warm start #{div(us, 1000)}ms, zero remote bytes possible, bundle unchanged"}
      else
        {:fail, "bundle was rewritten on unchanged warm restart"}
      end

    other ->
      {:fail, "warm start failed (remote reads attempted?): #{inspect(other)}"}
  end
end)

Rehearsal.check("shipped hydration bundle serves file reads fully in memory", fn ->
  shipped_odb = Path.join(workdir, "shipped-hydration.bundle")
  File.cp!(odb_bundle, shipped_odb)
  {:ok, repo} = Bundle.open(shipped_odb, into: :memory)
  {:ok, snap} = Repository.snapshot(repo, {:oid, OID.parse!(head)})
  {:ok, file} = Gitility.read_file(snap, "README.md")
  expected = Rehearsal.git!(source, ["show", "#{head}:README.md"])

  if file.data == expected,
    do: {:ok, "#{byte_size(file.data)} bytes"},
    else: {:fail, "content differs"}
end)

case Rehearsal.failures() do
  [] ->
    IO.puts("\nDRESS REHEARSAL: ALL CHECKS PASSED")

  failed ->
    IO.puts("\nDRESS REHEARSAL: #{length(failed)} FAILURE(S): #{inspect(failed)}")
    System.halt(1)
end
