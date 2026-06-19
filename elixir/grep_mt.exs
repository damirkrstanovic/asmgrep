# exgrep_std_mt - idiomatic multithreaded Elixir on the BEAM.
#
# BEAM parallelism is natural and idiomatic: collect the file list, then
# Task.async_stream over it -- the scheduler spreads the work across all cores
# (one scheduler thread per core by default). Each file is read fresh (per-file
# File.read!); each task returns a built output iolist + matched flag. The parent
# process serializes the IO.binwrite so concurrent lines never interleave.
#
# Same literal scan as exgrep_std: :binary.match/2 (C BIF), ASCII -i folding,
# immutable binaries, NUL-in-first-64KB binary skip.

defmodule ExGrep do
  def ascii_lower(bin) do
    bin
    |> :binary.bin_to_list()
    |> Enum.map(fn b -> if b >= ?A and b <= ?Z, do: b + 32, else: b end)
    |> :binary.list_to_bin()
  end

  defp line_start(data, m) do
    case :binary.matches(:binary.part(data, 0, m), "\n") do
      [] -> 0
      list -> (List.last(list) |> elem(0)) + 1
    end
  end

  defp line_end(data, m, len) do
    case :binary.match(data, "\n", scope: {m, len - m}) do
      :nomatch -> len
      {pos, _} -> pos
    end
  end

  # Returns {matched?, iolist} for one file -- no IO here (done in parent).
  def search_file(cfg, path) do
    case File.read(path) do
      {:error, _} ->
        {false, []}

      {:ok, data} ->
        len = byte_size(data)
        peek = min(len, 65536)

        binary? =
          peek > 0 and :binary.match(data, <<0>>, scope: {0, peek}) != :nomatch

        cond do
          binary? or len == 0 ->
            {false, []}

          # Empty pattern matches every line (grep -F "" behaviour); :binary.match
          # rejects an empty needle, so collect each line directly.
          cfg.pat == "" ->
            {true, all_lines(cfg, path, data, len, 0, [])}

          true ->
            {hay, needle} =
              if cfg.ci, do: {ascii_lower(data), cfg.lpat}, else: {data, cfg.pat}

            scan(cfg, path, data, hay, needle, len, 0, false, [])
        end
    end
  end

  defp all_lines(_cfg, _path, _data, len, pos, acc) when pos >= len,
    do: Enum.reverse(acc)

  defp all_lines(cfg, path, data, len, pos, acc) do
    le = line_end(data, pos, len)
    line = :binary.part(data, pos, le - pos)
    chunk = if cfg.multi, do: [path, ?:, line, ?\n], else: [line, ?\n]
    all_lines(cfg, path, data, len, le + 1, [chunk | acc])
  end

  defp scan(cfg, path, data, hay, needle, len, pos, matched, acc) do
    if pos >= len do
      {matched, Enum.reverse(acc)}
    else
      case :binary.match(hay, needle, scope: {pos, len - pos}) do
        :nomatch ->
          {matched, Enum.reverse(acc)}

        {m, _mlen} ->
          ls = line_start(data, m)
          le = line_end(data, m, len)
          line = :binary.part(data, ls, le - ls)

          chunk =
            if cfg.multi, do: [path, ?:, line, ?\n], else: [line, ?\n]

          scan(cfg, path, data, hay, needle, len, le + 1, true, [chunk | acc])
      end
    end
  end

  def walk(cfg, path, acc) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        acc

      {:ok, %File.Stat{type: :directory}} ->
        case File.ls(path) do
          {:ok, entries} ->
            Enum.reduce(entries, acc, fn e, a -> walk(cfg, Path.join(path, e), a) end)

          {:error, _} ->
            acc
        end

      {:ok, %File.Stat{type: :regular}} ->
        [path | acc]

      _ ->
        acc
    end
  end

  def collect(cfg, recursive, path, acc) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        if recursive, do: walk(cfg, path, acc), else: acc

      {:ok, _} ->
        [path | acc]

      {:error, _} ->
        acc
    end
  end

  defp strip_launcher_dashes(["--" | rest]), do: rest
  defp strip_launcher_dashes(args), do: args

  def parse_args(args), do: parse(args, false, false, nil, [], false)

  defp parse([], ci, rec, pat, paths, _no_more) do
    case {pat, paths} do
      {nil, _} -> :error
      {_, []} -> :error
      {p, ps} -> {:ok, ci, rec, p, Enum.reverse(ps)}
    end
  end

  defp parse(["--" | rest], ci, rec, pat, paths, false),
    do: parse(rest, ci, rec, pat, paths, true)

  defp parse([a | rest], ci, rec, pat, paths, false = nm)
       when binary_part(a, 0, 1) == "-" and byte_size(a) >= 2 do
    case parse_flags(String.to_charlist(binary_part(a, 1, byte_size(a) - 1)), ci, rec) do
      {:ok, ci2, rec2} -> parse(rest, ci2, rec2, pat, paths, nm)
      :error -> :error
    end
  end

  defp parse([a | rest], ci, rec, nil, paths, nm),
    do: parse(rest, ci, rec, a, paths, nm)

  defp parse([a | rest], ci, rec, pat, paths, nm),
    do: parse(rest, ci, rec, pat, [a | paths], nm)

  defp parse_flags([], ci, rec), do: {:ok, ci, rec}
  defp parse_flags([?i | cs], _ci, rec), do: parse_flags(cs, true, rec)
  defp parse_flags([?r | cs], ci, _rec), do: parse_flags(cs, ci, true)
  defp parse_flags(_, _ci, _rec), do: :error

  def main(args) do
    args = strip_launcher_dashes(args)

    case parse_args(args) do
      :error ->
        IO.binwrite(:stderr, "usage: exgrep [-r] [-i] PATTERN PATH...\n")
        System.halt(2)

      {:ok, ci, recursive, pat, paths} ->
        multi = recursive or length(paths) > 1
        cfg = %{pat: pat, lpat: ascii_lower(pat), ci: ci, multi: multi}

        files =
          Enum.reduce(paths, [], fn p, acc -> collect(cfg, recursive, p, acc) end)
          |> Enum.reverse()

        # Task.async_stream: BEAM spreads files across schedulers (one/core).
        # ordered: false lets results stream back as workers finish; the parent
        # serializes binwrite so lines never interleave.
        matched =
          files
          |> Task.async_stream(
            fn f -> search_file(cfg, f) end,
            ordered: false,
            max_concurrency: System.schedulers_online(),
            timeout: :infinity
          )
          |> Enum.reduce(false, fn {:ok, {m, iolist}}, acc ->
            if iolist != [], do: IO.binwrite(:stdio, iolist)
            m or acc
          end)

        System.halt(if matched, do: 0, else: 1)
    end
  end
end

ExGrep.main(System.argv())
