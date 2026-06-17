// fpgrep_std_mt_tuned - multithreaded + per-thread reused growable buffer +
// prefix binary-check. Each worker reuses ONE byte buffer (and one lowercase
// buffer) across all files it processes. Reads a 64 KB prefix first, NUL-checks
// it, and only reads the rest if the prefix passed.
{$mode objfpc}{$H+}
program grep_mt_tuned;

uses
  cthreads, // MUST be first on Unix
  BaseUnix, SysUtils, Classes, SyncObjs;

var
  Pat: RawByteString = '';
  LPat: RawByteString = '';
  PatSet: Boolean = False;
  CI: Boolean = False;
  Recursive: Boolean = False;
  Multi: Boolean = False;
  Matched: LongInt = 0;

  FileList: array of RawByteString;
  NFiles: SizeInt = 0;
  NextIdx: LongInt = -1;
  OutLock: TCriticalSection;

const
  PREFIX = 65536;

procedure AsciiLower(Dst, Src: PByte; N: SizeInt);
var i: SizeInt; b: Byte;
begin
  for i := 0 to N - 1 do
  begin
    b := Src[i];
    if (b >= 65) and (b <= 90) then Dst[i] := b + 32 else Dst[i] := b;
  end;
end;

function ByteIndex(Hay: PByte; HLen: SizeInt; Needle: PByte; NLen: SizeInt; Start: SizeInt): SizeInt;
var i, j: SizeInt; first: Byte; ok: Boolean;
begin
  if NLen = 0 then begin ByteIndex := Start; Exit; end;
  if Start < 0 then Start := 0;
  first := Needle[0];
  i := Start;
  while i + NLen <= HLen do
  begin
    if Hay[i] = first then
    begin
      ok := True; j := 1;
      while j < NLen do
      begin
        if Hay[i + j] <> Needle[j] then begin ok := False; Break; end;
        Inc(j);
      end;
      if ok then begin ByteIndex := i; Exit; end;
    end;
    Inc(i);
  end;
  ByteIndex := -1;
end;

function LineStart(Data: PByte; M: SizeInt): SizeInt;
var i: SizeInt;
begin
  i := M - 1;
  while i >= 0 do
  begin
    if Data[i] = 10 then begin LineStart := i + 1; Exit; end;
    Dec(i);
  end;
  LineStart := 0;
end;

function LineEnd(Data: PByte; M, Len: SizeInt): SizeInt;
var i: SizeInt;
begin
  i := M;
  while i < Len do
  begin
    if Data[i] = 10 then begin LineEnd := i; Exit; end;
    Inc(i);
  end;
  LineEnd := Len;
end;

type
  // Per-thread state: each worker owns its reused buffers (true reuse across
  // all files the thread processes).
  PWorker = ^TWorker;
  TWorker = record
    Data: PByte;     // reused growable data buffer
    DataCap: SizeInt;
    Low: PByte;      // reused growable lowercase buffer
    LowCap: SizeInt;
    Out: PByte;      // reused growable output buffer (per file, reused across files)
    OutCap: SizeInt;
    OutLen: SizeInt;
  end;

procedure EnsureData(w: PWorker; N: SizeInt);
begin
  if N > w^.DataCap then
  begin
    if w^.Data <> nil then FreeMem(w^.Data);
    w^.DataCap := N + (N div 2) + 4096;
    GetMem(w^.Data, w^.DataCap);
  end;
end;

procedure EnsureLow(w: PWorker; N: SizeInt);
begin
  if N > w^.LowCap then
  begin
    if w^.Low <> nil then FreeMem(w^.Low);
    w^.LowCap := N + (N div 2) + 4096;
    GetMem(w^.Low, w^.LowCap);
  end;
end;

procedure EmitBytes(w: PWorker; P: PByte; N: SizeInt);
var nc: SizeInt;
begin
  if N <= 0 then Exit;
  if w^.OutLen + N > w^.OutCap then
  begin
    nc := (w^.OutLen + N) * 2 + 4096;
    ReAllocMem(w^.Out, nc);
    w^.OutCap := nc;
  end;
  Move(P^, (w^.Out + w^.OutLen)^, N);
  Inc(w^.OutLen, N);
end;

procedure EmitByte(w: PWorker; B: Byte);
begin
  if w^.OutLen + 1 > w^.OutCap then
  begin
    w^.OutCap := w^.OutCap * 2 + 4096;
    ReAllocMem(w^.Out, w^.OutCap);
  end;
  (w^.Out + w^.OutLen)^ := B;
  Inc(w^.OutLen);
end;

procedure SearchFile(w: PWorker; const Path: RawByteString);
var
  Hay, Needle, FData: PByte;
  Len, NLen, Peek, Pos, m, ls, le, i, got, off: SizeInt;
  fd: cint;
  st: Stat;
  pfx: RawByteString;
begin
  fd := FpOpen(Path, O_RDONLY);
  if fd < 0 then Exit;
  if FpFStat(fd, st) <> 0 then begin FpClose(fd); Exit; end;
  Len := st.st_size;
  EnsureData(w, Len);
  FData := w^.Data;

  // Read only the 64 KB prefix first.
  Peek := Len;
  if Peek > PREFIX then Peek := PREFIX;
  off := 0;
  while off < Peek do
  begin
    got := FpRead(fd, (FData + off)^, Peek - off);
    if got <= 0 then Break;
    Inc(off, got);
  end;
  if off < Peek then begin Peek := off; Len := off; end;

  // NUL-check the prefix; only read the rest if it passes.
  for i := 0 to Peek - 1 do
    if (FData + i)^ = 0 then begin FpClose(fd); Exit; end; // binary

  // Read the remainder.
  while off < Len do
  begin
    got := FpRead(fd, (FData + off)^, Len - off);
    if got <= 0 then Break;
    Inc(off, got);
  end;
  FpClose(fd);
  if off < Len then Len := off;

  Hay := FData;
  if CI then
  begin
    EnsureLow(w, Len);
    AsciiLower(w^.Low, FData, Len);
    Hay := w^.Low;
    Needle := PByte(LPat); NLen := Length(LPat);
  end
  else
  begin
    Needle := PByte(Pat); NLen := Length(Pat);
  end;

  w^.OutLen := 0;
  if Multi then pfx := Path + ':' else pfx := '';
  Pos := 0;
  while Pos < Len do
  begin
    m := ByteIndex(Hay, Len, Needle, NLen, Pos);
    if m < 0 then Break;
    ls := LineStart(FData, m);
    le := LineEnd(FData, m, Len);
    InterlockedExchange(Matched, 1);
    if Multi then EmitBytes(w, PByte(@pfx[1]), Length(pfx));
    if le > ls then EmitBytes(w, FData + ls, le - ls);
    EmitByte(w, 10);
    Pos := le + 1;
  end;

  if w^.OutLen > 0 then
  begin
    OutLock.Acquire;
    try
      FpWrite(1, w^.Out^, w^.OutLen);
    finally
      OutLock.Release;
    end;
  end;
end;

// BeginThread worker: avoids FPC's TThread.WaitFor 100ms timed-futex join.
function Worker(p: Pointer): PtrInt;
var
  w: PWorker;
  idx: LongInt;
begin
  w := PWorker(p);
  repeat
    idx := InterlockedIncrement(NextIdx);
    if idx >= NFiles then Break;
    SearchFile(w, FileList[idx]);
  until False;
  if w^.Data <> nil then FreeMem(w^.Data);
  if w^.Low <> nil then FreeMem(w^.Low);
  if w^.Out <> nil then FreeMem(w^.Out);
  Worker := 0;
end;

procedure AddFile(const Path: RawByteString);
begin
  if NFiles >= Length(FileList) then SetLength(FileList, (NFiles + 1) * 2);
  FileList[NFiles] := Path;
  Inc(NFiles);
end;

procedure WalkDir(const Dir: RawByteString); forward;

procedure Collect(const Path: RawByteString);
var st: Stat;
begin
  if FpLStat(Path, st) <> 0 then Exit;
  if fpS_ISLNK(st.st_mode) then Exit;
  if fpS_ISDIR(st.st_mode) then
  begin
    if Recursive then WalkDir(Path);
  end
  else if fpS_ISREG(st.st_mode) then
    AddFile(Path);
end;

procedure WalkDir(const Dir: RawByteString);
var
  pd: PDir;
  ent: PDirent;
  name: RawByteString;
begin
  pd := FpOpenDir(Dir);
  if pd = nil then Exit;
  repeat
    ent := FpReadDir(pd^);
    if ent = nil then Break;
    name := PChar(@ent^.d_name[0]);
    if (name = '.') or (name = '..') then Continue;
    Collect(Dir + '/' + name);
  until False;
  FpCloseDir(pd^);
end;

procedure Usage;
const
  Msg: RawByteString = 'usage: fpgrep [-r] [-i] PATTERN PATH...'#10;
begin
  FpWrite(2, Msg[1], Length(Msg));
  Halt(2);
end;

function NumThreads: LongInt;
var
  fd: cint;
  buf: array[0..65535] of Byte;
  n, i, cnt: SizeInt;
begin
  cnt := 0;
  fd := FpOpen('/proc/cpuinfo', O_RDONLY);
  if fd >= 0 then
  begin
    repeat
      n := FpRead(fd, buf[0], SizeOf(buf));
      if n <= 0 then Break;
      i := 0;
      while i + 9 <= n do
      begin
        if (buf[i] = Ord('p')) and (buf[i+1] = Ord('r')) and (buf[i+2] = Ord('o'))
          and (buf[i+3] = Ord('c')) and (buf[i+4] = Ord('e')) and (buf[i+5] = Ord('s'))
          and (buf[i+6] = Ord('s')) and (buf[i+7] = Ord('o')) and (buf[i+8] = Ord('r'))
          and ((i = 0) or (buf[i-1] = 10)) then
          Inc(cnt);
        Inc(i);
      end;
    until n < SizeOf(buf);
    FpClose(fd);
  end;
  if cnt < 1 then cnt := 6;
  NumThreads := cnt;
end;

var
  Paths: array of RawByteString;
  NPaths: SizeInt = 0;
  i, k: Integer;
  a: RawByteString;
  NoMore: Boolean = False;
  c: Char;
  st: Stat;
  NT: LongInt;
  WS: array of TWorker;
  Threads: array of TThreadID;
begin
  SetLength(Paths, ParamCount);
  for i := 1 to ParamCount do
  begin
    a := ParamStr(i);
    if (not NoMore) and (Length(a) >= 2) and (a[1] = '-') then
    begin
      if a = '--' then begin NoMore := True; Continue; end;
      for k := 2 to Length(a) do
      begin
        c := a[k];
        case c of
          'i': CI := True;
          'r': Recursive := True;
        else Usage;
        end;
      end;
    end
    else if not PatSet then begin Pat := a; PatSet := True; end
    else begin Paths[NPaths] := a; Inc(NPaths); end;
  end;

  if (not PatSet) or (NPaths = 0) then Usage;

  SetLength(LPat, Length(Pat));
  if Length(Pat) > 0 then
    AsciiLower(PByte(@LPat[1]), PByte(@Pat[1]), Length(Pat));
  Multi := Recursive or (NPaths > 1);

  for i := 0 to NPaths - 1 do
  begin
    if FpLStat(Paths[i], st) <> 0 then Continue;
    if fpS_ISDIR(st.st_mode) then
    begin
      if Recursive then WalkDir(Paths[i]);
    end
    else if fpS_ISREG(st.st_mode) then AddFile(Paths[i])
    else if fpS_ISLNK(st.st_mode) then
    begin
      if FpStat(Paths[i], st) = 0 then
      begin
        if fpS_ISREG(st.st_mode) then AddFile(Paths[i])
        else if fpS_ISDIR(st.st_mode) and Recursive then WalkDir(Paths[i]);
      end;
    end;
  end;

  OutLock := TCriticalSection.Create;
  NT := NumThreads;
  if NT > NFiles then NT := NFiles;
  if NT < 1 then NT := 1;

  if NFiles > 0 then
  begin
    SetLength(WS, NT);
    SetLength(Threads, NT);
    FillChar(WS[0], NT * SizeOf(TWorker), 0); // zero all per-thread buffer state
    for i := 0 to NT - 1 do
      Threads[i] := BeginThread(@Worker, @WS[i]);
    for i := 0 to NT - 1 do
      WaitForThreadTerminate(Threads[i], 0);
  end;

  OutLock.Free;
  if Matched <> 0 then Halt(0) else Halt(1);
end.
