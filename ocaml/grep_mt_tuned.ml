(* ocgrep_std_mt_tuned - idiomatic OCaml + Domains + per-Domain reused growable
   Bytes.t buffer (OCaml Bytes is mutable, so true per-worker buffer reuse IS
   feasible) + prefix binary-check. Each worker reads a 64 KB prefix into its
   reused buffer, NUL-checks the prefix, and reads the remainder only if it
   passed. Per-file output is serialized under a Mutex. *)

let pat = ref ""
let lpat = ref ""
let ci = ref false
let recursive = ref false
let multi = ref false
let any_match = Atomic.make false
let out_mutex = Mutex.create ()

let peek_cap = 65536

(* Per-Domain mutable scratch: one read buffer (grown via Buffer.t style manual
   doubling) and one lowercase buffer, both reused across files. *)
type scratch = {
  mutable buf : Bytes.t;       (* file contents *)
  mutable low : Bytes.t;       (* ascii-lower copy when -i *)
  out : Buffer.t;              (* per-file output, cleared between files *)
}

let make_scratch () = {
  buf = Bytes.create peek_cap;
  low = Bytes.create peek_cap;
  out = Buffer.create 256;
}

let ensure (b : Bytes.t) (n : int) : Bytes.t =
  if Bytes.length b >= n then b
  else begin
    let cap = ref (Bytes.length b) in
    if !cap = 0 then cap := 1;
    while !cap < n do cap := !cap * 2 done;
    Bytes.create !cap
  end

(* ASCII lower of a string (used once for the needle). *)
let ascii_lower_copy_str (s : string) : string =
  let b = Bytes.of_string s in
  for i = 0 to Bytes.length b - 1 do
    let c = Char.code (Bytes.unsafe_get b i) in
    if c >= 65 && c <= 90 then Bytes.unsafe_set b i (Char.unsafe_chr (c + 32))
  done;
  Bytes.unsafe_to_string b

(* ASCII lower from src[0:len] into dst[0:len] (dst assumed >= len). *)
let ascii_lower_into (dst : Bytes.t) (src : Bytes.t) (len : int) : unit =
  for i = 0 to len - 1 do
    let c = Char.code (Bytes.unsafe_get src i) in
    Bytes.unsafe_set dst i
      (if c >= 65 && c <= 90 then Char.unsafe_chr (c + 32)
       else Char.unsafe_chr c)
  done

let index_nul (b : Bytes.t) (len : int) : int =
  let rec go i = if i >= len then -1
    else if Char.code (Bytes.unsafe_get b i) = 0 then i else go (i + 1)
  in go 0

(* find needle in hay[0:hlen] at index >= pos. empty needle -> pos. *)
let find_sub (hay : Bytes.t) (hlen : int) (needle : string) (pos : int) : int =
  let nl = String.length needle in
  if nl = 0 then pos
  else begin
    let last = hlen - nl in
    let c0 = String.unsafe_get needle 0 in
    let rec scan i =
      if i > last then -1
      else if Bytes.unsafe_get hay i = c0 then begin
        let rec eq j =
          if j >= nl then true
          else if Bytes.unsafe_get hay (i + j) = String.unsafe_get needle j
          then eq (j + 1) else false
        in
        if eq 1 then i else scan (i + 1)
      end else scan (i + 1)
    in scan pos
  end

let line_start (b : Bytes.t) (m : int) : int =
  let rec go i = if i < 0 then 0
    else if Bytes.unsafe_get b i = '\n' then i + 1 else go (i - 1)
  in go (m - 1)

let line_end (b : Bytes.t) (m : int) (len : int) : int =
  let rec go i = if i >= len then len
    else if Bytes.unsafe_get b i = '\n' then i else go (i + 1)
  in go m

(* Read len bytes from ic into dst[off:], handling short reads. Returns total
   bytes read (may be < len at EOF). *)
let rec read_into ic dst off len total =
  if len <= 0 then total
  else
    let r = In_channel.input ic dst off len in
    if r = 0 then total
    else read_into ic dst (off + r) (len - r) (total + r)

let search_file (sc : scratch) (path : string) : unit =
  match In_channel.open_bin path with
  | exception _ -> ()
  | ic ->
    Fun.protect ~finally:(fun () -> In_channel.close_noerr ic) (fun () ->
      let size =
        match In_channel.length ic with
        | exception _ -> -1L
        | l -> l
      in
      (* prefix size to read first *)
      let want_prefix =
        if size >= 0L && size < Int64.of_int peek_cap
        then Int64.to_int size else peek_cap
      in
      sc.buf <- ensure sc.buf (max want_prefix 1);
      let got = read_into ic sc.buf 0 want_prefix 0 in
      (* NUL-check the prefix we have *)
      let peek = if got > peek_cap then peek_cap else got in
      if index_nul sc.buf peek >= 0 then ()  (* binary, skip *)
      else begin
        (* read remainder only if prefix passed *)
        let total = ref got in
        (* if file may be larger than prefix (unknown size or size>prefix) keep
           reading in chunks into the reused, grown buffer *)
        let more = ref (got = want_prefix) in
        while !more do
          if Bytes.length sc.buf <= !total then
            sc.buf <- (let nb = ensure sc.buf (!total * 2 + 1) in
                       Bytes.blit sc.buf 0 nb 0 !total; nb);
          let space = Bytes.length sc.buf - !total in
          let r = In_channel.input ic sc.buf !total space in
          if r = 0 then more := false
          else total := !total + r
        done;
        let len = !total in
        let hay, needle =
          if !ci then begin
            sc.low <- ensure sc.low (max len 1);
            ascii_lower_into sc.low sc.buf len;
            sc.low, !lpat
          end else sc.buf, !pat
        in
        Buffer.clear sc.out;
        let found = ref false in
        let pos = ref 0 in
        let cont = ref true in
        while !cont && !pos < len do
          let m = find_sub hay len needle !pos in
          if m < 0 then cont := false
          else begin
            let ls = line_start sc.buf m in
            let le = line_end sc.buf m len in
            found := true;
            if !multi then begin
              Buffer.add_string sc.out path; Buffer.add_char sc.out ':'
            end;
            Buffer.add_subbytes sc.out sc.buf ls (le - ls);
            Buffer.add_char sc.out '\n';
            pos := le + 1
          end
        done;
        if !found then begin
          Atomic.set any_match true;
          Mutex.lock out_mutex;
          print_string (Buffer.contents sc.out);
          Mutex.unlock out_mutex
        end
      end)

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
  lpat := ascii_lower_copy_str !pat;
  multi := !recursive || List.length paths > 1;

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
    let sc = make_scratch () in  (* one reused scratch per Domain *)
    let rec loop () =
      let i = Atomic.fetch_and_add idx 1 in
      if i < n then begin search_file sc work.(i); loop () end
    in loop ()
  in
  if n = 0 then ()
  else begin
    let spawn = if ndom > n then n else ndom in
    let doms = Array.init (spawn - 1) (fun _ -> Domain.spawn worker) in
    worker ();
    Array.iter Domain.join doms
  end;
  flush stdout;
  exit (if Atomic.get any_match then 0 else 1)
