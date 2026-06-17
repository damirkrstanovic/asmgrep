// fpgrep_std_mt - naive multithreaded grep -F clone.
// One worker thread per CPU pulls files off a shared index (InterlockedIncrement).
// Each file is read IN FULL (fresh buffer) before the binary check (alloc-heavy).
{$mode objfpc}{$H+}
program grep_mt;

uses
  cthreads, // MUST be first on Unix for TThread/heap-mgr threading
  BaseUnix, SysUtils, Classes, SyncObjs;

var
  Pat: RawByteString = '';
  LPat: RawByteString = '';
  PatSet: Boolean = False;
  CI: Boolean = False;
  Recursive: Boolean = False;
  Multi: Boolean = False;
  Matched: LongInt = 0; // set atomically

  FileList: array of RawByteString;
  NFiles: SizeInt = 0;
  NextIdx: LongInt = -1; // InterlockedIncrement -> 0-based via pre-increment
  OutLock: TCriticalSection;

const
  OUTCAP = 1 shl 16;

procedure FlushBuf(var Buf: array of Byte; var Len: SizeInt);
begin
  if Len > 0 then
  begin
    FpWrite(1, Buf[0], Len);
    Len := 0;
  end;
end;

procedure AsciiLower(Dst, Src: PByte; N: SizeInt);
var
  i: SizeInt;
  b: Byte;
begin
  for i := 0 to N - 1 do
  begin
    b := Src[i];
    if (b >= 65) and (b <= 90) then Dst[i] := b + 32 else Dst[i] := b;
  end;
end;

function ByteIndex(Hay: PByte; HLen: SizeInt; Needle: PByte; NLen: SizeInt; Start: SizeInt): SizeInt;
var
  i, j: SizeInt;
  first: Byte;
  ok: Boolean;
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

// Search one file. Writes its full output block, then emits under OutLock.
procedure SearchFile(const Path: RawByteString);
var
  Data, Low: RawByteString;
  OB: array of Byte;
  OL: SizeInt;
  Hay, Needle: PByte;
  Len, NLen, Peek, Pos, m, ls, le, i, got, off: SizeInt;
  fd: cint;
  st: Stat;
  pfx: RawByteString;

  procedure Emit(const P: PByte; N: SizeInt);
  begin
    if N <= 0 then Exit;
    if OL + N > Length(OB) then SetLength(OB, (OL + N) * 2 + 64);
    Move(P^, OB[OL], N);
    Inc(OL, N);
  end;
  procedure EmitB(B: Byte);
  begin
    if OL + 1 > Length(OB) then SetLength(OB, (OL + 1) * 2 + 64);
    OB[OL] := B; Inc(OL);
  end;

begin
  fd := FpOpen(Path, O_RDONLY);
  if fd < 0 then Exit;
  if FpFStat(fd, st) <> 0 then begin FpClose(fd); Exit; end;
  Len := st.st_size;
  SetLength(Data, Len); // fresh full buffer each file (naive)
  off := 0;
  while off < Len do
  begin
    got := FpRead(fd, Data[off + 1], Len - off);
    if got <= 0 then Break;
    Inc(off, got);
  end;
  FpClose(fd);
  if off < Len then begin Len := off; SetLength(Data, Len); end;

  Peek := Len;
  if Peek > 65536 then Peek := 65536;
  for i := 0 to Peek - 1 do
    if Byte(Data[i + 1]) = 0 then Exit; // binary

  if Len = 0 then Hay := nil else Hay := PByte(@Data[1]);

  if CI then
  begin
    SetLength(Low, Len);
    if Len > 0 then AsciiLower(PByte(@Low[1]), Hay, Len);
    if Len > 0 then Hay := PByte(@Low[1]) else Hay := nil;
    Needle := PByte(LPat); NLen := Length(LPat);
  end
  else
  begin
    Needle := PByte(Pat); NLen := Length(Pat);
  end;

  OL := 0;
  SetLength(OB, 4096);
  pfx := Path + ':';
  Pos := 0;
  while Pos < Len do
  begin
    m := ByteIndex(Hay, Len, Needle, NLen, Pos);
    if m < 0 then Break;
    ls := LineStart(PByte(@Data[1]), m);
    le := LineEnd(PByte(@Data[1]), m, Len);
    InterlockedExchange(Matched, 1);
    if Multi then Emit(PByte(@pfx[1]), Length(pfx));
    if le > ls then Emit(@Data[ls + 1], le - ls);
    EmitB(10);
    Pos := le + 1;
  end;

  if OL > 0 then
  begin
    OutLock.Acquire;
    try
      FpWrite(1, OB[0], OL);
    finally
      OutLock.Release;
    end;
  end;
end;

// BeginThread worker: avoids FPC's TThread.WaitFor 100ms timed-futex join.
function Worker(p: Pointer): PtrInt;
var
  idx: LongInt;
begin
  repeat
    idx := InterlockedIncrement(NextIdx);
    if idx >= NFiles then Break;
    SearchFile(FileList[idx]);
  until False;
  Worker := 0;
end;

procedure AddFile(const Path: RawByteString);
begin
  if NFiles >= Length(FileList) then
    SetLength(FileList, (NFiles + 1) * 2);
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

// Count online CPUs by scanning /proc/cpuinfo for "processor" lines; fallback 6.
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

  // Collect files
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
    SetLength(Threads, NT);
    for i := 0 to NT - 1 do
      Threads[i] := BeginThread(@Worker);
    for i := 0 to NT - 1 do
      WaitForThreadTerminate(Threads[i], 0);
  end;

  OutLock.Free;
  if Matched <> 0 then Halt(0) else Halt(1);
end.
