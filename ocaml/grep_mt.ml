(* ocgrep_std_mt - idiomatic OCaml + naive Domains. One worker Domain per CPU
   pulls files off a shared Atomic index. Each file is read IN FULL with a
   fresh In_channel.input_all + fresh string/Bytes before the binary check
   (deliberately allocation-heavy tier). Per-file output block is serialized
   under a Mutex; cross-file order is unspecified. *)

let pat = ref ""
let lpat = ref ""
let ci = ref false
let recursive = ref false
let multi = ref false
let any_match = Atomic.make false
let out_mutex = Mutex.create ()

let ascii_lower_copy (s : string) : string =
  let b = Bytes.of_string s in
  for i = 0 to Bytes.length b - 1 do
    let c = Char.code (Bytes.unsafe_get b i) in
    if c >= 65 && c <= 90 then Bytes.unsafe_set b i (Char.unsafe_chr (c + 32))
  done;
  Bytes.unsafe_to_string b

let index_nul (s : string) (len : int) : int =
  let rec go i = if i >= len then -1
    else if Char.code (String.unsafe_get s i) = 0 then i else go (i + 1)
  in go 0

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

let line_start (s : string) (m : int) : int =
  let rec go i = if i < 0 then 0
    else if String.unsafe_get s i = '\n' then i + 1 else go (i - 1)
  in go (m - 1)

let line_end (s : string) (m : int) : int =
  let len = String.length s in
  let rec go i = if i >= len then len
    else if String.unsafe_get s i = '\n' then i else go (i + 1)
  in go m

(* Returns this file's output (or empty) in a fresh per-call Buffer. *)
let search_file (path : string) : unit =
  match In_channel.with_open_bin path In_channel.input_all with
  | exception _ -> ()
  | data ->
    let len = String.length data in
    let peek = if len > 65536 then 65536 else len in
    if index_nul data peek >= 0 then ()
    else begin
      let hay, needle =
        if !ci then ascii_lower_copy data, !lpat else data, !pat
      in
      let buf = Buffer.create 256 in
      let found = ref false in
      let pos = ref 0 in
      let cont = ref true in
      while !cont && !pos < len do
        let m = find_sub hay needle !pos in
        if m < 0 then cont := false
        else begin
          let ls = line_start data m in
          let le = line_end data m in
          found := true;
          if !multi then begin
            Buffer.add_string buf path; Buffer.add_char buf ':'
          end;
          Buffer.add_substring buf data ls (le - ls);
          Buffer.add_char buf '\n';
          pos := le + 1
        end
      done;
      if !found then begin
        Atomic.set any_match true;
        Mutex.lock out_mutex;
        print_string (Buffer.contents buf);
        Mutex.unlock out_mutex
      end
    end

let usage () =
  output_string stderr "usage: ocgrep [-r] [-i] PATTERN PATH...\n";
  exit 2

let rec collect (acc : string list ref) (path : string) : unit =
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
            | Unix.S_DIR -> collect acc child
            | Unix.S_REG -> acc := child :: !acc
            | _ -> ()));
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

  (* Build full work list of regular files to search. *)
  let files = ref [] in
  List.iter (fun p ->
    match Unix.lstat p with
    | exception _ -> ()
    | st ->
      (match st.Unix.st_kind with
       | Unix.S_DIR -> if !recursive then collect files p
       | Unix.S_REG -> files := p :: !files
       | _ -> ())) paths;
  let work = Array.of_list (List.rev !files) in
  let n = Array.length work in

  let ndom =
    let c = Domain.recommended_domain_count () in
    if c >= 1 then c else 6
  in
  let idx = Atomic.make 0 in
  let worker () =
    let rec loop () =
      let i = Atomic.fetch_and_add idx 1 in
      if i < n then begin search_file work.(i); loop () end
    in loop ()
  in
  if n = 0 then ()
  else begin
    let spawn = if ndom > n then n else ndom in
    let doms = Array.init (spawn - 1) (fun _ -> Domain.spawn worker) in
    worker ();  (* main domain participates too *)
    Array.iter Domain.join doms
  end;
  flush stdout;
  exit (if Atomic.get any_match then 0 else 1)
