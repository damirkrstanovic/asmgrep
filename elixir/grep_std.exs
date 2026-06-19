# exgrep_std - idiomatic single-threaded Elixir on the BEAM.
#
# The exotic VM in the set. Immutable binaries all the way (byte-exact offsets),
# :binary.match/2 (a C BIF) for the literal search -- NOT Regex (which would treat
# the pattern as a regular expression and isn't the fast literal scan we want).
# File.ls!/File.lstat for the walk; symlinks are never followed. No threads.
#
# Whole-file read via File.read!. NUL-in-first-64KB binary skip. ASCII-only
# case folding for -i (NOT String.downcase, which is Unicode and could change
# byte length / offsets -- we map bytes A-Z -> a-z ourselves to match grep -iF).

defmodule ExGrep do
  # ASCII-only, length-preserving lowercase: byte map A-Z (65..90) -> a-z.
  # Done with :binary.bin_to_list + map; immutable, builds a fresh binary.
  def ascii_lower(bin) do
    bin
    |> :binary.bin_to_list()
    |> Enum.map(fn b -> if b >= ?A and b <= ?Z, do: b + 32, else: b end)
    |> :binary.list_to_bin()
  end

  # last index of \n strictly before m, or -1  => line start = that + 1
  defp line_start(data, m) do
    case :binary.matches(:binary.part(data, 0, m), "\n") do
      [] -> 0
      list -> (List.last(list) |> elem(0)) + 1
    end
  end

  # first index of \n at/after m, or len
  defp line_end(data, m, len) do
    case :binary.match(data, "\n", scope: {m, len - m}) do
      :nomatch -> len
      {pos, _} -> pos
    end
  end

  def search_file(cfg, path) do
    case File.read(path) do
      {:error, _} ->
        false

      {:ok, data} ->
        len = byte_size(data)
        peek = min(len, 65536)

        binary? =
          peek > 0 and :binary.match(data, <<0>>, scope: {0, peek}) != :nomatch

        cond do
          binary? ->
            false

          len == 0 ->
            false

          # Empty pattern matches every line (grep -F "" behaviour).
          # :binary.match rejects an empty needle, so emit each line directly.
          cfg.pat == "" ->
            emit_all_lines(cfg, path, data, len, 0)
            true

          true ->
            {hay, needle} =
              if cfg.ci, do: {ascii_lower(data), cfg.lpat}, else: {data, cfg.pat}

            scan(cfg, path, data, hay, needle, len, 0, false)
        end
    end
  end

  defp emit_all_lines(_cfg, _path, _data, len, pos) when pos >= len, do: :ok

  defp emit_all_lines(cfg, path, data, len, pos) do
    le = line_end(data, pos, len)
    line = :binary.part(data, pos, le - pos)

    if cfg.multi do
      IO.binwrite(:stdio, [path, ?:, line, ?\n])
    else
      IO.binwrite(:stdio, [line, ?\n])
    end

    emit_all_lines(cfg, path, data, len, le + 1)
  end

  # Drive :binary.match across the haystack, printing each matching line once
  # then resuming past its end (le + 1). Returns whether anything matched.
  defp scan(cfg, path, data, hay, needle, len, pos, matched) do
    if pos >= len do
      matched
    else
      case :binary.match(hay, needle, scope: {pos, len - pos}) do
        :nomatch ->
          matched

        {m, _mlen} ->
          ls = line_start(data, m)
          le = line_end(data, m, len)
          line = :binary.part(data, ls, le - ls)

          if cfg.multi do
            IO.binwrite(:stdio, [path, ?:, line, ?\n])
          else
            IO.binwrite(:stdio, [line, ?\n])
          end

          scan(cfg, path, data, hay, needle, len, le + 1, true)
      end
    end
  end

  # Recursive walk: regular files only, never follow symlinks.
  def walk(cfg, path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        false

      {:ok, %File.Stat{type: :directory}} ->
        case File.ls(path) do
          {:ok, entries} ->
            Enum.reduce(entries, false, fn e, acc ->
              walk(cfg, Path.join(path, e)) or acc
            end)

          {:error, _} ->
            false
        end

      {:ok, %File.Stat{type: :regular}} ->
        search_file(cfg, path)

      _ ->
        false
    end
  end

  def process_path(cfg, recursive, path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        if recursive, do: walk(cfg, path), else: false

      {:ok, _} ->
        search_file(cfg, path)

      {:error, _} ->
        false
    end
  end

  # Parse args: flags may combine (-ri); -- ends options; first non-flag = PATTERN.
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
    # The bin/ launcher execs `elixir grep_std.exs -- "$@"`; that leading "--"
    # shields elixir's own arg parser from user flags and DOES appear in argv.
    # Strip exactly one so a user-supplied "--" is still honored by parse_args.
    args = strip_launcher_dashes(args)

    case parse_args(args) do
      :error ->
        IO.binwrite(:stderr, "usage: exgrep [-r] [-i] PATTERN PATH...\n")
        System.halt(2)

      {:ok, ci, recursive, pat, paths} ->
        multi = recursive or length(paths) > 1

        cfg = %{
          pat: pat,
          lpat: ascii_lower(pat),
          ci: ci,
          multi: multi
        }

        matched =
          Enum.reduce(paths, false, fn p, acc ->
            process_path(cfg, recursive, p) or acc
          end)

        System.halt(if matched, do: 0, else: 1)
    end
  end
end

ExGrep.main(System.argv())
