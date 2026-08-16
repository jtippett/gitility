defmodule Gitility.Differential.Oracle do
  @moduledoc """
  Byte-oriented adapters around canonical Git plumbing commands.

  Successful queries return `{:ok, normalized_result}`. Failed Git commands
  return `{:error, %{status: status, output: output}}`; the output remains a
  raw binary because corrupt-object diagnostics are not part of the oracle's
  normalized contract.
  """

  @git_environment [
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_CONFIG_SYSTEM", "/dev/null"},
    {"GIT_TERMINAL_PROMPT", "0"},
    {"LC_ALL", "C"}
  ]

  @git_options ["-c", "color.ui=false", "-c", "core.quotePath=false"]

  @type git_error :: %{status: non_neg_integer(), output: binary()}
  @type result(value) :: {:ok, value} | {:error, git_error()}

  @spec git_environment() :: [{binary(), binary()}]
  def git_environment, do: @git_environment

  @spec git_version() :: binary()
  def git_version do
    case System.cmd("git", ["--version"], env: @git_environment, stderr_to_stdout: true) do
      {<<"git version ", version::binary>>, 0} -> trim_metadata(version)
      {output, status} -> raise "git --version failed (#{status}): #{inspect(output)}"
    end
  end

  @spec cat_file(Path.t(), binary()) ::
          result(%{type: binary(), size: non_neg_integer(), content: binary()})
  def cat_file(repository, object) do
    with {:ok, type_output} <- git(repository, ["cat-file", "-t", object]),
         type = trim_metadata(type_output),
         {:ok, size_output} <- git(repository, ["cat-file", "-s", object]),
         {size, ""} <- Integer.parse(trim_metadata(size_output)),
         {:ok, content} <- git(repository, ["cat-file", type, object]) do
      {:ok, %{type: type, size: size, content: content}}
    else
      {:error, _error} = error -> error
      _invalid_size -> {:error, %{status: 1, output: "git cat-file returned an invalid size"}}
    end
  end

  @spec ls_tree(Path.t(), binary(), keyword()) :: result([map()])
  def ls_tree(repository, treeish, options \\ []) do
    options =
      Keyword.validate!(options,
        recursive: true,
        include_trees: false,
        include_size: false,
        path: nil
      )

    arguments =
      ["ls-tree"] ++
        optional_flag(options[:recursive], "-r") ++
        optional_flag(options[:include_trees], "-t") ++
        ["-z"] ++
        optional_flag(options[:include_size], "-l") ++
        ["--full-tree", treeish] ++ path_arguments(options[:path])

    with {:ok, output} <- git(repository, arguments) do
      parse_records(output, &parse_tree_entry/1)
    end
  end

  @spec rev_list(Path.t(), [binary()]) :: result([binary()])
  def rev_list(repository, revisions) when is_list(revisions) do
    with {:ok, output} <- git(repository, ["rev-list", "--topo-order" | revisions]) do
      {:ok, metadata_lines(output)}
    end
  end

  @spec log(Path.t(), binary(), keyword()) :: result([binary()])
  def log(repository, revision, options \\ []) do
    options =
      Keyword.validate!(options,
        order: :chronological,
        first_parent: false,
        since: nil,
        until: nil
      )

    order =
      case options[:order] do
        :chronological -> []
        :topological -> ["--topo-order"]
        :date -> ["--date-order"]
      end

    arguments =
      ["rev-list"] ++
        order ++
        optional_flag(options[:first_parent], "--first-parent") ++
        optional_value(options[:since], "--since") ++
        optional_value(options[:until], "--until") ++
        [revision]

    with {:ok, output} <- git(repository, arguments) do
      {:ok, metadata_lines(output)}
    end
  end

  @doc """
  Runs the pinned `git grep` literal oracle and returns byte-preserving rows.

  Columns are normalized from Git's 1-based display to Gitility's 0-based
  byte-column contract. Regex mode deliberately has no oracle adapter because
  Git and Rust's `regex` crate accept different pattern classes.
  """
  @spec grep(Path.t(), binary(), binary(), keyword()) :: result([map()])
  def grep(repository, revision, pattern, options \\ []) do
    options =
      Keyword.validate!(options,
        ignore_case: false,
        binary: :skip,
        pathspecs: []
      )

    binary_flag =
      case options[:binary] do
        :skip -> "-I"
        :text -> "-a"
      end

    arguments =
      ["grep", "-F"] ++
        optional_flag(options[:ignore_case], "-i") ++
        [
          binary_flag,
          "--line-number",
          "--column",
          "--full-name",
          "--null",
          "-e",
          pattern,
          revision
        ] ++ pathspec_arguments(options[:pathspecs])

    case git(repository, arguments) do
      {:ok, output} -> parse_raw_line_records(output, &parse_grep_record(&1, revision))
      {:error, %{status: 1, output: <<>>}} -> {:ok, []}
      {:error, _error} = error -> error
    end
  end

  @spec rev_parse(Path.t(), binary()) :: result(binary())
  def rev_parse(repository, expression) do
    with {:ok, output} <- git(repository, ["rev-parse", "--verify", expression]) do
      {:ok, trim_metadata(output)}
    end
  end

  @spec tag_refs(Path.t()) :: result([map()])
  def tag_refs(repository) do
    with {:ok, output} <-
           git(repository, [
             "for-each-ref",
             "--format=%(refname)%09%(objectname)%09%(objecttype)",
             "refs/tags"
           ]) do
      parse_records_by_line(output, &parse_tag_ref/1)
    end
  end

  @spec merge_base(Path.t(), binary(), binary(), keyword()) :: result([binary()])
  def merge_base(repository, left, right, options \\ []) do
    options = Keyword.validate!(options, all: true)
    arguments = ["merge-base"] ++ optional_flag(options[:all], "--all") ++ [left, right]

    case git(repository, arguments) do
      {:ok, output} -> {:ok, metadata_lines(output)}
      {:error, %{status: 1, output: <<>>}} -> {:ok, []}
      {:error, _error} = error -> error
    end
  end

  @spec is_ancestor(Path.t(), binary(), binary()) :: result(boolean())
  def is_ancestor(repository, ancestor, descendant) do
    case git(repository, ["merge-base", "--is-ancestor", ancestor, descendant]) do
      {:ok, _output} -> {:ok, true}
      {:error, %{status: 1}} -> {:ok, false}
      {:error, _error} = error -> error
    end
  end

  @spec diff_raw(Path.t(), binary(), binary(), [binary()]) :: result([map()])
  def diff_raw(repository, left, right, options \\ []) do
    arguments =
      ["diff", "--raw", "-z", "--no-abbrev", "--no-ext-diff"] ++
        options ++ [left, right]

    with {:ok, output} <- git(repository, arguments) do
      output
      |> nul_fields()
      |> parse_raw_changes([])
    end
  end

  @doc "Runs `git diff-tree` with a NUL-delimited raw change stream."
  @spec diff_tree_raw(Path.t(), binary(), binary(), [binary()], [binary()]) :: result([map()])
  def diff_tree_raw(repository, left, right, options \\ [], pathspecs \\ []) do
    arguments =
      ["diff-tree", "-r", "--no-commit-id", "--raw", "-z", "--no-abbrev", "--no-ext-diff"] ++
        options ++ [left, right] ++ nul_pathspec_arguments(pathspecs)

    with {:ok, output} <- git(repository, arguments) do
      output
      |> nul_fields()
      |> parse_raw_changes([])
    end
  end

  @doc "Runs `git diff --numstat -z` and preserves raw path bytes."
  @spec diff_numstat(Path.t(), binary(), binary(), [binary()], [binary()]) :: result([map()])
  def diff_numstat(repository, left, right, options \\ [], pathspecs \\ []) do
    arguments =
      ["diff", "--numstat", "-z", "--no-ext-diff"] ++
        options ++ [left, right] ++ nul_pathspec_arguments(pathspecs)

    with {:ok, output} <- git(repository, arguments) do
      parse_records(output, &parse_numstat_record/1)
    end
  end

  @doc "Runs histogram diff for one raw-byte path and returns structured hunks."
  @spec diff_hunks(Path.t(), binary(), binary(), binary(), 0..32) :: result([map()])
  def diff_hunks(repository, left, right, path, context_lines) do
    arguments = [
      "diff",
      "-p",
      "--no-color",
      "--no-ext-diff",
      "--no-renames",
      "--diff-algorithm=histogram",
      "-U#{context_lines}",
      left,
      right,
      "--",
      path
    ]

    with {:ok, output} <- git(repository, arguments) do
      parse_patch_hunks(output)
    end
  end

  @spec diff_patch(Path.t(), binary(), binary(), [binary()]) :: result(binary())
  def diff_patch(repository, left, right, options \\ []) do
    git(
      repository,
      [
        "diff",
        "-p",
        "--no-color",
        "--no-ext-diff",
        "--src-prefix=a/",
        "--dst-prefix=b/"
      ] ++ options ++ [left, right]
    )
  end

  @spec blame(Path.t(), binary(), binary(), [binary()]) :: result([map()])
  def blame(repository, revision, path, options \\ []) do
    with {:ok, output} <-
           git(repository, ["blame", "--porcelain"] ++ options ++ [revision, "--", path]),
         {:ok, lines} <- parse_blame_lines(output, %{}, []) do
      {:ok, coalesce_blame_lines(lines)}
    end
  end

  @doc "Runs the closest Git oracle for Gitility's first-parent tree comparison rule."
  @spec path_history(Path.t(), binary(), binary(), keyword()) :: result([binary()])
  def path_history(repository, revision, path, options \\ []) do
    options = Keyword.validate!(options, follow_renames: true)

    arguments =
      [
        "log",
        "--format=%H",
        "--no-patch",
        "--full-history",
        "--diff-merges=first-parent"
      ] ++
        optional_flag(options[:follow_renames], "--follow") ++
        [revision, "--", path]

    with {:ok, output} <- git(repository, arguments) do
      {:ok, metadata_lines(output)}
    end
  end

  @spec log_follow(Path.t(), binary(), binary(), [binary()]) :: result([map()])
  def log_follow(repository, revision, path, options \\ []) do
    format = "--format=format:%H%x00%P%x00"

    with {:ok, output} <-
           git(
             repository,
             ["log", "--topo-order", "--follow", "--name-status", "-z", format] ++
               options ++ [revision, "--", path]
           ) do
      output
      |> :binary.split(<<0>>, [:global])
      |> parse_log_fields([])
    end
  end

  @spec fsck(Path.t()) :: :ok | {:error, git_error()}
  def fsck(repository) do
    case git(repository, ["fsck", "--full", "--strict", "--no-dangling"]) do
      {:ok, _output} -> :ok
      {:error, _error} = error -> error
    end
  end

  defp git(repository, arguments) do
    command_arguments = @git_options ++ ["-C", Path.expand(repository)] ++ arguments

    case System.cmd("git", command_arguments,
           env: @git_environment,
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, %{status: status, output: output}}
    end
  end

  defp parse_records(output, parser) do
    output
    |> nul_fields()
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, parsed} ->
      case parser.(record) do
        {:ok, value} -> {:cont, {:ok, [value | parsed]}}
        {:error, reason} -> {:halt, {:error, %{status: 1, output: reason}}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp parse_tree_entry(record) do
    with {tab_offset, 1} <- :binary.match(record, <<"\t">>),
         metadata = binary_part(record, 0, tab_offset),
         path = binary_part(record, tab_offset + 1, byte_size(record) - tab_offset - 1),
         fields <-
           metadata
           |> :binary.split(<<" ">>, [:global])
           |> Enum.reject(&(&1 == <<>>)),
         {:ok, entry} <- tree_entry_from_fields(fields, path) do
      {:ok, entry}
    else
      _ -> {:error, "malformed git ls-tree record: #{inspect(record)}"}
    end
  end

  defp tree_entry_from_fields([mode, type, oid], path) do
    {:ok, %{mode: mode, type: type, oid: oid, path: path}}
  end

  defp tree_entry_from_fields([mode, type, oid, <<"-">>], path) do
    {:ok, %{mode: mode, type: type, oid: oid, path: path, size: nil}}
  end

  defp tree_entry_from_fields([mode, type, oid, size], path) do
    case Integer.parse(size) do
      {value, ""} when value >= 0 ->
        {:ok, %{mode: mode, type: type, oid: oid, path: path, size: value}}

      _other ->
        {:error, "invalid git ls-tree size: #{inspect(size)}"}
    end
  end

  defp tree_entry_from_fields(_fields, _path), do: {:error, "invalid ls-tree metadata"}

  defp parse_tag_ref(record) do
    case :binary.split(record, <<"\t">>, [:global]) do
      [ref, oid, type] -> {:ok, %{ref: ref, oid: oid, type: type}}
      _other -> {:error, "malformed git for-each-ref record: #{inspect(record)}"}
    end
  end

  defp parse_grep_record(record, revision) do
    prefix = revision <> ":"

    with {:ok, rest} <- strip_prefix(record, prefix),
         {:ok, path, rest} <- take_field(rest, 0),
         {:ok, line_field, rest} <- take_field(rest, 0),
         {:ok, column_field, line_bytes} <- take_field(rest, 0),
         {line, ""} when line > 0 <- Integer.parse(line_field),
         {column, ""} when column > 0 <- Integer.parse(column_field) do
      {:ok, %{path: path, line: line, column: column - 1, line_bytes: line_bytes}}
    else
      _ -> {:error, "malformed git grep record: #{inspect(record)}"}
    end
  end

  defp strip_prefix(binary, prefix) when byte_size(binary) >= byte_size(prefix) do
    prefix_size = byte_size(prefix)

    case binary do
      <<candidate::binary-size(prefix_size), rest::binary>> when candidate == prefix ->
        {:ok, rest}

      _ ->
        {:error, :prefix_mismatch}
    end
  end

  defp strip_prefix(_binary, _prefix), do: {:error, :prefix_mismatch}

  defp take_field(binary, separator) do
    case :binary.match(binary, <<separator>>) do
      {offset, 1} ->
        value = binary_part(binary, 0, offset)
        rest = binary_part(binary, offset + 1, byte_size(binary) - offset - 1)
        {:ok, value, rest}

      :nomatch ->
        {:error, :missing_separator}
    end
  end

  defp parse_records_by_line(output, parser) do
    output
    |> metadata_lines()
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, parsed} ->
      case parser.(record) do
        {:ok, value} -> {:cont, {:ok, [value | parsed]}}
        {:error, reason} -> {:halt, {:error, %{status: 1, output: reason}}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp parse_raw_line_records(output, parser) do
    output
    |> :binary.split(<<"\n">>, [:global])
    |> drop_trailing_empty_fields()
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, parsed} ->
      case parser.(record) do
        {:ok, value} -> {:cont, {:ok, [value | parsed]}}
        {:error, reason} -> {:halt, {:error, %{status: 1, output: reason}}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp optional_flag(true, flag), do: [flag]
  defp optional_flag(false, _flag), do: []

  defp optional_value(nil, _flag), do: []
  defp optional_value(value, flag), do: ["#{flag}=#{value}"]

  defp path_arguments(nil), do: []
  defp path_arguments(path) when is_binary(path), do: ["--", path]

  defp pathspec_arguments([]), do: []
  # Git's default wildmatch lets `*` cross `/`; Gitility deliberately uses
  # glob magic, so an unprefixed `*.txt` would be a false-positive oracle.
  defp pathspec_arguments(pathspecs), do: ["--" | Enum.map(pathspecs, &(":(glob)" <> &1))]

  defp nul_pathspec_arguments([]), do: []
  defp nul_pathspec_arguments(pathspecs), do: ["--" | pathspecs]

  defp parse_numstat_record(record) do
    with {:ok, additions, rest} <- take_field(record, ?\t),
         {:ok, deletions, path} <- take_field(rest, ?\t),
         {:ok, additions} <- parse_numstat_count(additions),
         {:ok, deletions} <- parse_numstat_count(deletions) do
      {:ok, %{path: path, additions: additions, deletions: deletions}}
    else
      _ -> {:error, "malformed git diff --numstat record: #{inspect(record)}"}
    end
  end

  defp parse_numstat_count(<<"-">>), do: {:ok, nil}

  defp parse_numstat_count(value) do
    case Integer.parse(value) do
      {count, ""} when count >= 0 -> {:ok, count}
      _ -> {:error, :invalid_count}
    end
  end

  defp parse_patch_hunks(output) do
    output
    |> :binary.split(<<"\n">>, [:global])
    |> Enum.reduce({[], nil}, &parse_patch_line/2)
    |> then(fn {hunks, current} ->
      {:ok, hunks |> maybe_finish_hunk(current) |> Enum.reverse()}
    end)
  end

  # A type-change patch is two git file sections for one path; once a hunk
  # has consumed exactly its declared line counts, any following non-hunk
  # line ("diff --git", "--- /dev/null", "+++ b/<path>", index/mode lines)
  # is metadata, never content. The "\\ No newline" marker must still reach
  # the completed hunk's last line, so it bypasses the completion flush.
  defp parse_patch_line(<<"\\ No newline at end of file">> = line, state) do
    do_parse_patch_line(line, state)
  end

  defp parse_patch_line(line, {hunks, current}) when not is_nil(current) do
    if hunk_complete?(current) do
      do_parse_patch_line(line, {maybe_finish_hunk(hunks, current), nil})
    else
      do_parse_patch_line(line, {hunks, current})
    end
  end

  defp parse_patch_line(line, state), do: do_parse_patch_line(line, state)

  defp hunk_complete?(hunk) do
    hunk.old_line - hunk.old_start >= hunk.old_lines and
      hunk.new_line - hunk.new_start >= hunk.new_lines
  end

  defp do_parse_patch_line(<<"@@ ", _rest::binary>> = line, {hunks, current}) do
    hunks = maybe_finish_hunk(hunks, current)

    # Regex.run omits unmatched TRAILING groups, so git's short-form
    # headers ("@@ -1 +1 @@", count omitted when 1) return fewer captures;
    # pad before destructuring.
    case Regex.run(~r/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/, line) do
      [_ | captures] when length(captures) in 3..4 ->
        [old_start, old_lines, new_start, new_lines] =
          case captures ++ ["", "", "", ""] do
            [a, b, c, d | _] -> [a, b, c, d]
          end

        old_lines = if old_lines == "", do: "1", else: old_lines
        new_lines = if new_lines == "", do: "1", else: new_lines
        {hunks, new_patch_hunk(old_start, old_lines, new_start, new_lines)}

      _ ->
        raise "malformed git patch hunk header: #{inspect(line)}"
    end
  end

  defp do_parse_patch_line(
         <<"\\ No newline at end of file">>,
         {hunks, %{lines: [line | rest]} = current}
       ) do
    {hunks, %{current | lines: [%{line | no_newline: true} | rest]}}
  end

  defp do_parse_patch_line(<<"\\ No newline at end of file">>, state), do: state

  defp do_parse_patch_line(<<origin, content::binary>>, {hunks, current})
       when origin in [?\s, ?+, ?-] and not is_nil(current) do
    {line_origin, old_line, new_line, next_old, next_new} =
      case origin do
        ?\s -> {:context, current.old_line, current.new_line, 1, 1}
        ?+ -> {:addition, nil, current.new_line, 0, 1}
        ?- -> {:deletion, current.old_line, nil, 1, 0}
      end

    line = %{
      origin: line_origin,
      content: content,
      old_line: old_line,
      new_line: new_line,
      no_newline: false
    }

    current = %{
      current
      | old_line: current.old_line + next_old,
        new_line: current.new_line + next_new,
        lines: [line | current.lines]
    }

    {hunks, current}
  end

  defp do_parse_patch_line(_metadata, state), do: state

  defp new_patch_hunk(old_start, old_lines, new_start, new_lines) do
    %{
      old_start: String.to_integer(old_start),
      old_lines: String.to_integer(old_lines),
      new_start: String.to_integer(new_start),
      new_lines: String.to_integer(new_lines),
      old_line: String.to_integer(old_start),
      new_line: String.to_integer(new_start),
      lines: []
    }
  end

  defp maybe_finish_hunk(hunks, nil), do: hunks

  defp maybe_finish_hunk(hunks, hunk) do
    [
      hunk
      |> Map.take([:old_start, :old_lines, :new_start, :new_lines, :lines])
      |> Map.update!(:lines, &Enum.reverse/1)
      | hunks
    ]
  end

  defp parse_raw_changes([], changes), do: {:ok, Enum.reverse(changes)}

  defp parse_raw_changes([header | fields], changes) do
    with {:ok, metadata} <- parse_raw_header(header),
         {:ok, paths, remaining} <- take_change_paths(metadata.status, fields) do
      change =
        metadata
        |> Map.put(:path, hd(paths))
        |> maybe_put_destination(paths)

      parse_raw_changes(remaining, [change | changes])
    else
      {:error, reason} -> {:error, %{status: 1, output: reason}}
    end
  end

  defp parse_raw_header(<<":", metadata::binary>>) do
    case :binary.split(metadata, <<" ">>, [:global]) do
      [old_mode, new_mode, old_oid, new_oid, status] ->
        {status_code, similarity} = status_parts(status)

        {:ok,
         %{
           old_mode: old_mode,
           new_mode: new_mode,
           old_oid: old_oid,
           new_oid: new_oid,
           status: status_code,
           similarity: similarity
         }}

      _ ->
        {:error, "malformed git diff --raw header: #{inspect(metadata)}"}
    end
  end

  defp parse_raw_header(other),
    do: {:error, "git diff --raw record does not start with a colon: #{inspect(other)}"}

  defp take_change_paths(status, [source, destination | remaining])
       when status in ["R", "C"],
       do: {:ok, [source, destination], remaining}

  defp take_change_paths(status, [_source | _remaining]) when status in ["R", "C"],
    do: {:error, "rename/copy record is missing its destination path"}

  defp take_change_paths(_status, [path | remaining]), do: {:ok, [path], remaining}
  defp take_change_paths(_status, []), do: {:error, "diff record is missing its path"}

  defp maybe_put_destination(change, [_source, destination]),
    do: Map.put(change, :destination, destination)

  defp maybe_put_destination(change, [_path]), do: change

  defp status_parts(<<status::binary-size(1), score::binary>>) do
    similarity =
      case Integer.parse(score) do
        {value, ""} -> value
        :error -> nil
      end

    {status, similarity}
  end

  defp parse_blame_lines(<<>>, _path_cache, lines), do: {:ok, Enum.reverse(lines)}

  defp parse_blame_lines(output, path_cache, lines) do
    with {:ok, header, rest} <- take_line(output),
         {:ok, commit, original_line, final_line} <- parse_blame_header(header),
         {:ok, original_path, boundary, remaining, next_cache} <-
           consume_blame_metadata(rest, commit, path_cache, nil, false) do
      line = %{
        commit: commit,
        original_line: original_line,
        final_line: final_line,
        original_path: original_path,
        boundary: boundary
      }

      parse_blame_lines(remaining, next_cache, [line | lines])
    end
  end

  defp parse_blame_header(header) do
    case :binary.split(header, <<" ">>, [:global]) do
      [commit, original, final | _group_size] ->
        with {original_line, ""} <- Integer.parse(original),
             {final_line, ""} <- Integer.parse(final) do
          {:ok, commit, original_line, final_line}
        else
          _ -> {:error, "invalid line numbers in blame header: #{inspect(header)}"}
        end

      _ ->
        {:error, "malformed blame header: #{inspect(header)}"}
    end
  end

  defp consume_blame_metadata(output, commit, path_cache, current_path, boundary) do
    with {:ok, line, rest} <- take_line(output) do
      case line do
        <<"\t", _source_line::binary>> ->
          case if(current_path,
                 do: {current_path, boundary},
                 else: Map.get(path_cache, commit)
               ) do
            nil -> {:error, "blame record has no original path for #{commit}"}

            {path, cached_boundary} ->
              {:ok, path, cached_boundary, rest,
               Map.put(path_cache, commit, {path, cached_boundary})}
          end

        <<"filename ", encoded_path::binary>> ->
          with {:ok, path} <- unquote_git_path(encoded_path) do
            consume_blame_metadata(rest, commit, path_cache, path, boundary)
          end

        <<"boundary">> ->
          consume_blame_metadata(rest, commit, path_cache, current_path, true)

        _metadata ->
          consume_blame_metadata(rest, commit, path_cache, current_path, boundary)
      end
    end
  end

  defp coalesce_blame_lines(lines) do
    lines
    |> Enum.reduce([], fn line, hunks ->
      case hunks do
        [last | rest] ->
          {last_original_start, last_original_end} = last.original_range
          {last_final_start, last_final_end} = last.final_range

          if last.commit == line.commit and last.original_path == line.original_path and
               last.boundary == line.boundary and
               last_original_end + 1 == line.original_line and
               last_final_end + 1 == line.final_line do
            [
              %{
                last
                | original_range: {last_original_start, line.original_line},
                  final_range: {last_final_start, line.final_line}
              }
              | rest
            ]
          else
            [blame_hunk(line) | hunks]
          end

        [] ->
          [blame_hunk(line)]
      end
    end)
    |> Enum.reverse()
  end

  defp blame_hunk(line) do
    %{
      commit: line.commit,
      original_path: line.original_path,
      original_range: {line.original_line, line.original_line},
      final_range: {line.final_line, line.final_line},
      boundary: line.boundary
    }
  end

  defp parse_log_fields([], records), do: {:ok, Enum.reverse(records)}
  defp parse_log_fields([<<>>], records), do: {:ok, Enum.reverse(records)}

  defp parse_log_fields([commit, parents_field | fields], records) when commit != <<>> do
    with {:ok, changes, remaining} <- parse_name_status_fields(fields, []) do
      parsed = %{
        commit: commit,
        parents: split_nonempty(parents_field, <<" ">>),
        changes: changes
      }

      parse_log_fields(remaining, [parsed | records])
    end
  end

  defp parse_log_fields(fields, _records),
    do: {:error, %{status: 1, output: "malformed git log field stream: #{inspect(fields)}"}}

  defp parse_name_status_fields([], changes), do: {:ok, Enum.reverse(changes), []}

  defp parse_name_status_fields([<<>> | remaining], changes),
    do: {:ok, Enum.reverse(changes), remaining}

  defp parse_name_status_fields([status_field | fields], changes) do
    status_field = trim_name_status_prefix(status_field)
    {status, similarity} = status_parts(status_field)

    case take_change_paths(status, fields) do
      {:ok, paths, remaining} ->
        change =
          %{status: status, similarity: similarity, path: hd(paths)}
          |> maybe_put_destination(paths)

        parse_name_status_fields(remaining, [change | changes])

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp trim_name_status_prefix(<<"\n", status::binary>>), do: status
  defp trim_name_status_prefix(status), do: status

  defp unquote_git_path(<<"\"", quoted::binary>>) do
    size = byte_size(quoted)

    if size > 0 and :binary.at(quoted, size - 1) == ?" do
      parse_quoted_path(binary_part(quoted, 0, size - 1), [])
    else
      {:error, "unterminated quoted Git path: #{inspect(quoted)}"}
    end
  end

  defp unquote_git_path(path), do: {:ok, path}

  defp parse_quoted_path(<<>>, bytes), do: {:ok, IO.iodata_to_binary(Enum.reverse(bytes))}

  defp parse_quoted_path(<<"\\", a, b, c, rest::binary>>, bytes)
       when a in ?0..?7 and b in ?0..?7 and c in ?0..?7 do
    value = (a - ?0) * 64 + (b - ?0) * 8 + (c - ?0)
    parse_quoted_path(rest, [<<value>> | bytes])
  end

  defp parse_quoted_path(<<"\\", escaped, rest::binary>>, bytes) do
    value =
      case escaped do
        ?a -> 0x07
        ?b -> 0x08
        ?t -> 0x09
        ?n -> 0x0A
        ?v -> 0x0B
        ?f -> 0x0C
        ?r -> 0x0D
        other -> other
      end

    parse_quoted_path(rest, [<<value>> | bytes])
  end

  defp parse_quoted_path(<<byte, rest::binary>>, bytes),
    do: parse_quoted_path(rest, [<<byte>> | bytes])

  defp take_line(binary) do
    case :binary.match(binary, <<"\n">>) do
      {offset, 1} ->
        line = binary_part(binary, 0, offset)
        rest = binary_part(binary, offset + 1, byte_size(binary) - offset - 1)
        {:ok, line, rest}

      :nomatch ->
        {:error, "canonical Git output ended in the middle of a line"}
    end
  end

  defp nul_fields(binary) do
    binary
    |> :binary.split(<<0>>, [:global])
    |> drop_trailing_empty_fields()
  end

  defp drop_trailing_empty_fields(fields) do
    fields
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == <<>>))
    |> Enum.reverse()
  end

  defp metadata_lines(binary),
    do: split_nonempty(trim_metadata(binary), <<"\n">>)

  defp split_nonempty(<<>>, _separator), do: []

  defp split_nonempty(binary, separator),
    do: Enum.reject(:binary.split(binary, separator, [:global]), &(&1 == <<>>))

  defp trim_metadata(binary) do
    binary
    |> trim_metadata_byte(?\n)
    |> trim_metadata_byte(?\r)
  end

  defp trim_metadata_byte(<<>>, _byte), do: <<>>

  defp trim_metadata_byte(binary, byte) do
    size = byte_size(binary)

    if :binary.at(binary, size - 1) == byte do
      binary_part(binary, 0, size - 1)
    else
      binary
    end
  end
end
