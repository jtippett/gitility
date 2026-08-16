# Checkpoint C1: PackFetch hydration at real scale.
#
# Design target (docs/plans/2026-08-14-gitility-design.md): a snapshot load
# from a same-region backend should complete within ~3s per 100MB, i.e.
# >= 33.3 MB/s sustained. The M2e fixtures are ~8KB and never exercised this;
# this script publishes a real 100MB+ repository to both reference range
# backends and times cold hydration. The result decides whether the lazy
# PackRange reader stays scheduled as Milestone 5 or moves post-1.0.
#
# Usage (on the Linux test sprite — never load the NIF locally):
#   GITILITY_BUILD=1 mix run bench/c1_hydration.exs <bare-repo> <work-dir>
#
# Postgres timings run only when GITILITY_TEST_POSTGRES_URL is set.
# into: :memory runs only where supported and needs /dev/shm sized above the
# pack (the sprite default is 64M — remount first).

defmodule C1.Bench do
  alias Gitility.{Limits, ODB, Snapshot}
  alias Gitility.ODB.PackFetch
  alias Gitility.ODB.RangeBackend.{LocalDirectory, Postgres}

  @target_mb_s 100 / 3

  def main([repo, work_dir]) do
    repo = Path.expand(repo)
    work_dir = Path.expand(work_dir)
    File.mkdir_p!(work_dir)

    head = git!(repo, ["rev-parse", "HEAD"])
    limits = Limits.new(timeout_ms: 600_000)

    store = Path.join(work_dir, "localdir-store")

    {publish_s, :ok} = timed(fn -> LocalDirectory.publish(repo, store) end)
    bytes = published_bytes(store)
    mb = bytes / 1_000_000
    IO.puts("source: #{repo}")
    IO.puts("published: #{fmt_mb(bytes)} (pack+idx) in #{fmt_s(publish_s)} -> #{store}")
    IO.puts("target: >= #{Float.round(@target_mb_s, 1)} MB/s (<= 3s per 100MB)\n")

    results =
      [
        hydrate_case(
          "localdir cold",
          {LocalDirectory, store},
          {:dir, Path.join(work_dir, "hydrated-local-cold")},
          limits,
          bytes,
          head
        ),
        # Same BEAM, same destination volume: the process-local verified set
        # plus on-disk reuse make refresh O(new packs).
        hydrate_case(
          "localdir warm (reused volume, same BEAM)",
          {LocalDirectory, store},
          {:dir, Path.join(work_dir, "hydrated-local-cold")},
          limits,
          bytes,
          head
        ),
        memory_case({LocalDirectory, store}, limits, bytes, head)
      ] ++ postgres_cases(repo, work_dir, limits, bytes, head)

    IO.puts("\n== C1 summary (pack+idx #{fmt_mb(bytes)}) ==")

    for {label, seconds} <- results, is_number(seconds) do
      rate = mb / seconds
      verdict = if rate >= @target_mb_s, do: "PASS", else: "FAIL"

      IO.puts(
        "#{String.pad_trailing(label, 44)} #{fmt_s(seconds)}  #{fmt_rate(rate)}  #{verdict}"
      )
    end

    for {label, {:skipped, reason}} <- results do
      IO.puts("#{String.pad_trailing(label, 44)} skipped: #{inspect(reason)}")
    end
  end

  def main(_argv) do
    IO.puts("usage: mix run bench/c1_hydration.exs <bare-repo> <work-dir>")
    System.halt(2)
  end

  defp hydrate_case(label, backend, into, limits, bytes, head) do
    {seconds, result} =
      timed(fn ->
        PackFetch.start_link(
          backend: backend,
          into: into,
          limits: limits,
          max_bytes: 2 * 1024 * 1024 * 1024
        )
      end)

    case result do
      {:ok, supervisor} ->
        {:ok, odb} = ODB.handle(supervisor)
        {:ok, %Snapshot{}} = Snapshot.open(odb, head)
        :ok = Supervisor.stop(supervisor)

        IO.puts(
          "#{label}: #{fmt_s(seconds)} (#{fmt_rate(bytes / 1_000_000 / seconds)}), HEAD snapshot OK"
        )

        {label, seconds}

      {:error, reason} ->
        IO.puts("#{label}: ERROR #{inspect(reason)}")
        {label, {:skipped, reason}}
    end
  end

  defp memory_case(backend, limits, bytes, head) do
    label = "localdir -> into: :memory (tmpfs)"

    with true <- PackFetch.memory_supported?(),
         {:ok, %{size: shm}} when shm > bytes <- shm_capacity() do
      hydrate_case(label, backend, :memory, limits, bytes, head)
    else
      _ -> {label, {:skipped, :dev_shm_unavailable_or_too_small}}
    end
  end

  # File.stat on the mountpoint reports the directory, not the tmpfs size, so
  # read the size= mount option from /proc/mounts.
  defp shm_capacity do
    with {:ok, mounts} <- File.read("/proc/mounts"),
         [line | _rest] <-
           for(l <- String.split(mounts, "\n"), String.contains?(l, " /dev/shm "), do: l),
         [size_kb | _fields] <- Regex.run(~r/size=(\d+)k/, line, capture: :all_but_first) do
      {:ok, %{size: String.to_integer(size_kb) * 1024}}
    else
      _ -> {:ok, %{size: 0}}
    end
  end

  defp postgres_cases(repo, work_dir, limits, bytes, head) do
    case System.get_env("GITILITY_TEST_POSTGRES_URL") do
      nil ->
        [{"postgres", {:skipped, :GITILITY_TEST_POSTGRES_URL_unset}}]

      url ->
        prefix = "c1_bench"

        {publish_s, publish} =
          timed(fn -> Postgres.publish(repo, url, prefix: prefix) end)

        case publish do
          :ok ->
            IO.puts("postgres publish: #{fmt_s(publish_s)} (1 MiB bytea chunks)")

            [
              hydrate_case(
                "postgres cold",
                {Postgres, [url: url, prefix: prefix]},
                {:dir, Path.join(work_dir, "hydrated-postgres-cold")},
                limits,
                bytes,
                head
              ),
              # The default Postgrex pool is a single connection, so the 8
              # concurrent read_ranges callbacks serialize on it; this variant
              # shows how much of the gap is pool contention.
              hydrate_case(
                "postgres cold (pool_size 8)",
                {Postgres, [url: url, prefix: prefix, pool_size: 8]},
                {:dir, Path.join(work_dir, "hydrated-postgres-pool8")},
                limits,
                bytes,
                head
              )
            ]

          {:error, reason} ->
            [{"postgres publish", {:skipped, reason}}]
        end
    end
  end

  defp published_bytes(store) do
    store
    |> Path.join("packs/pack-*")
    |> Path.wildcard()
    |> Enum.map(&File.stat!(&1).size)
    |> Enum.sum()
  end

  defp git!(repo, args) do
    {out, 0} = System.cmd("git", ["-C", repo | args])
    String.trim(out)
  end

  defp timed(fun) do
    {us, result} = :timer.tc(fun)
    {us / 1_000_000, result}
  end

  defp fmt_s(s), do: "#{Float.round(s * 1.0, 2)}s"
  defp fmt_mb(bytes), do: "#{Float.round(bytes / 1_000_000, 1)} MB"
  defp fmt_rate(rate), do: "#{Float.round(rate * 1.0, 1)} MB/s"
end

C1.Bench.main(System.argv())
