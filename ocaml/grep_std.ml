(* ocgrep_std - idiomatic single-threaded OCaml: In_channel.input_all + Buffer
   + a hand-rolled byte scan (stdlib has no substring search). Operates on raw
   bytes (OCaml string/Bytes are byte sequences). Matches `grep -F` semantics. *)

let pat = ref ""
let lpat = ref ""
let ci = ref false
let recursive = ref false
let multi = ref false
let matched = ref false
let out = Buffer.create (1 lsl 16)

(* ASCII-only, length-preserving lowercase (matches grep -iF; A-Z -> +32). *)
let ascii_lower_copy (s : string) : string =
  let b = Bytes.of_string s in
  for i = 0 to Bytes.length b - 1 do
    let c = Char.code (Bytes.unsafe_get b i) in
    if c >= 65 && c <= 90 then Bytes.unsafe_set b i (Char.unsafe_chr (c + 32))
  done;
  Bytes.unsafe_to_string b

(* index of first 0 byte in s[0:len], or -1 *)
let index_nul (s : string) (len : int) : int =
  let rec go i = if i >= len then -1
    else if Char.code (String.unsafe_get s i) = 0 then i else go (i + 1)
  in go 0

(* first occurrence of needle in hay at index >= pos, else -1.
   Empty needle returns pos (caller's loop guard prevents phantom trailing). *)
let find_sub (hay : string) (needle : string) (pos : int) : int =
  let hl = String.length hay and nl = String.length needle in
  if nl = 0 then pos
  else begin
    let last = hl - nl in
    let c0 = String.unsafe_get needle 0 in
    let rec scan i =
      if i > last then -1
      else if String.unsafe_get hay i = c0 then begin
        let rec eq j =
          if j >= nl then true
          else if String.unsafe_get hay (i + j) = String.unsafe_get needle j
          then eq (j + 1) else false
        in
        if eq 1 then i else scan (i + 1)
      end else scan (i + 1)
    in scan pos
  end

(* last '\n' before index m in s[0:m], +1; or 0 *)
let line_start (s : string) (m : int) : int =
  let rec go i = if i < 0 then 0
    else if String.unsafe_get s i = '\n' then i + 1 else go (i - 1)
  in go (m - 1)

(* first '\n' at/after m, or String.length s *)
let line_end (s : string) (m : int) : int =
  let len = String.length s in
  let rec go i = if i >= len then len
    else if String.unsafe_get s i = '\n' then i else go (i + 1)
  in go m

let search_file (path : string) : unit =
  match In_channel.with_open_bin path In_channel.input_all with
  | exception _ -> ()
  | data ->
    let len = String.length data in
    let peek = if len > 65536 then 65536 else len in
    if index_nul data peek >= 0 then ()  (* binary, skip *)
    else begin
      let hay, needle =
        if !ci then ascii_lower_copy data, !lpat else data, !pat
      in
      let pos = ref 0 in
      let cont = ref true in
      while !cont && !pos < len do
        let m = find_sub hay needle !pos in
        if m < 0 then cont := false
        else begin
          let ls = line_start data m in
          let le = line_end data m in
          matched := true;
          if !multi then begin
            Buffer.add_string out path; Buffer.add_char out ':'
          end;
          Buffer.add_substring out data ls (le - ls);
          Buffer.add_char out '\n';
          pos := le + 1
        end
      done
    end

let usage () =
  output_string stderr "usage: ocgrep [-r] [-i] PATTERN PATH...\n";
  exit 2

let rec walk (path : string) : unit =
  match Unix.opendir path with
  | exception _ -> ()
  | dh ->
    let rec loop () =
      match Unix.readdir dh with
      | exception End_of_file -> Unix.closedir dh
      | "." | ".." -> loop ()
      | name ->
        let child = Filename.concat path name in
        (match Unix.lstat child with
         | exception _ -> ()
         | st ->
           (match st.Unix.st_kind with
            | Unix.S_DIR -> walk child
            | Unix.S_REG -> search_file child
            | _ -> ()));  (* skip symlinks etc. *)
        loop ()
    in loop ()

let () =
  set_binary_mode_out stdout true;
  let pat_set = ref false in
  let paths = ref [] in
  let no_more = ref false in
  let argv = Sys.argv in
  for k = 1 to Array.length argv - 1 do
    let a = argv.(k) in
    if (not !no_more) && String.length a >= 2 && a.[0] = '-' then begin
      if a = "--" then no_more := true
      else
        for j = 1 to String.length a - 1 do
          match a.[j] with
          | 'i' -> ci := true
          | 'r' -> recursive := true
          | _ -> usage ()
        done
    end
    else if not !pat_set then begin pat := a; pat_set := true end
    else paths := a :: !paths
  done;
  let paths = List.rev !paths in
  if (not !pat_set) || paths = [] then usage ();
  lpat := ascii_lower_copy !pat;
  multi := !recursive || List.length paths > 1;
  List.iter (fun p ->
    match Unix.lstat p with
    | exception _ -> ()
    | st ->
      (match st.Unix.st_kind with
       | Unix.S_DIR -> if !recursive then walk p
       | Unix.S_REG -> search_file p
       | _ -> ())) paths;
  print_string (Buffer.contents out);
  flush stdout;
  exit (if !matched then 0 else 1)
