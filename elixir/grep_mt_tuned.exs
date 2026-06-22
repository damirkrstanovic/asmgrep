# exgrep_std_mt_tuned - idiomatic Elixir + Task.async_stream + prefix binary-check.
#
# Tuning vs grep_mt.exs (the "memory / I/O strategy" pillar):
#   * PREFIX CHECK: open the file, read only a 64 KB prefix (:file.read/2),
#     NUL-check THAT, and read the rest only if the prefix is clean. A binary
#     file (NUL in the first 64 KB) costs one 64 KB read instead of slurping the
#     whole thing -- "don't read data you'll skip" (e.g. a 291 MB .git pack).
#
# BUFFER REUSE -- DELIBERATE DEVIATION (same as Haskell):
#   The "reuse one mutable buffer per worker" pillar (C/Zig/Odin tuned tiers)
#   does NOT map to the BEAM: Erlang binaries are IMMUTABLE. There is no mutable
#   read buffer to reuse; every :file.read produces a fresh, GC-managed binary,
#   and any binary handed to :binary.match / the output iolist must own its bytes.
#   So this variant keeps the prefix-check win (the part that DOES map) and does
#   not attempt buffer reuse. Allocation per file is the prefix (<=64 KB) plus,
#   for text files, the remainder -- one fresh allocation per file, minus the
#   wasted full read on binaries.

defmodule ExGrep do
  @prefix 65536

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

  # Prefix binary-check read: pull first 64 KB, NUL-check it, read the rest only
  # if clean. Returns {:ok, binary} or :skip (binary file / read error).
  # :raw :file.read/2 may return FEWER bytes than requested mid-file (a single
  # read() syscall), so fill the prefix in a loop — otherwise a short read looks
  # like EOF and the file's tail is silently dropped.
  defp read_prefix(_fd, acc) when byte_size(acc) >= @prefix, do: {:ok, acc}

  defp read_prefix(fd, acc) do
    case :file.read(fd, @prefix - byte_size(acc)) do
      {:ok, chunk} -> read_prefix(fd, acc <> chunk)
      :eof -> {:ok, acc}
      other -> other
    end
  end

  # read the rest of the file in chunks until EOF. (`:file.read(fd, :all)` is NOT
  # valid — it returns {:error, :badarg}, which silently skipped every file ≥64 KB.)
  defp read_rest(fd, acc) do
    case :file.read(fd, 1_048_576) do
      {:ok, chunk} -> read_rest(fd, [acc, chunk])
      :eof -> {:ok, IO.iodata_to_binary(acc)}
      other -> other
    end
  end

  def read_checked(path) do
    case :file.open(path, [:read, :binary, :raw]) do
      {:ok, fd} ->
        result =
          case read_prefix(fd, <<>>) do
            {:ok, prefix} ->
              if :binary.match(prefix, <<0>>) != :nomatch do
                :skip
              else
                if byte_size(prefix) < @prefix do
                  {:ok, prefix}
                else
                  case read_rest(fd, []) do
                    {:ok, rest} -> {:ok, prefix <> rest}
                    {:error, _} -> :skip
                  end
                end
              end

            :eof ->
              :skip

            {:error, _} ->
              :skip
          end

        :file.close(fd)
        result

      {:error, _} ->
        :skip
    end
  end

  def search_file(cfg, path) do
    case read_checked(path) do
      :skip ->
        {false, []}

      {:ok, data} ->
        len = byte_size(data)

        if len == 0 do
          {false, []}
        else
          # Empty pattern matches every line; :binary.match rejects an empty
          # needle, so collect each line directly.
          if cfg.pat == "" do
            {true, all_lines(cfg, path, data, len, 0, [])}
          else
            {hay, needle} =
              if cfg.ci, do: {ascii_lower(data), cfg.lpat}, else: {data, cfg.pat}

            scan(cfg, path, data, hay, needle, len, 0, false, [])
          end
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
