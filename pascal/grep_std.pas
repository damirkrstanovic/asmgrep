// fpgrep_std - idiomatic single-threaded Free Pascal grep -F clone.
{$mode objfpc}{$H+}
program grep_std;

uses
  BaseUnix, SysUtils;

var
  Pat: RawByteString = '';
  LPat: RawByteString = '';
  PatSet: Boolean = False;
  CI: Boolean = False;
  Recursive: Boolean = False;
  Multi: Boolean = False;
  Matched: Boolean = False;
  // manual output buffer flushed to fd 1
  OutBuf: array of Byte;
  OutLen: SizeInt = 0;

const
  OUTCAP = 1 shl 16;

procedure FlushOut;
begin
  if OutLen > 0 then
  begin
    FpWrite(1, OutBuf[0], OutLen);
    OutLen := 0;
  end;
end;

procedure OutBytes(const P: PByte; N: SizeInt);
begin
  if N <= 0 then Exit;
  if N >= OUTCAP then
  begin
    FlushOut;
    FpWrite(1, P^, N);
    Exit;
  end;
  if OutLen + N > OUTCAP then FlushOut;
  Move(P^, OutBuf[OutLen], N);
  Inc(OutLen, N);
end;

procedure OutByte(B: Byte);
begin
  if OutLen + 1 > OUTCAP then FlushOut;
  OutBuf[OutLen] := B;
  Inc(OutLen);
end;

procedure OutStr(const S: RawByteString);
begin
  if Length(S) > 0 then
    OutBytes(PByte(@S[1]), Length(S));
end;

// ASCII-only length-preserving lowercase (matches grep -iF).
procedure AsciiLower(Dst, Src: PByte; N: SizeInt);
var
  i: SizeInt;
  b: Byte;
begin
  for i := 0 to N - 1 do
  begin
    b := Src[i];
    if (b >= 65) and (b <= 90) then
      Dst[i] := b + 32
    else
      Dst[i] := b;
  end;
end;

// Hand-rolled byte scan: first index >= start where needle occurs in hay[0..hlen-1].
// Returns -1 if not found. Empty needle returns start.
function ByteIndex(Hay: PByte; HLen: SizeInt; Needle: PByte; NLen: SizeInt; Start: SizeInt): SizeInt;
var
  i, j: SizeInt;
  first: Byte;
  ok: Boolean;
begin
  if NLen = 0 then
  begin
    ByteIndex := Start;
    Exit;
  end;
  if Start < 0 then Start := 0;
  first := Needle[0];
  i := Start;
  while i + NLen <= HLen do
  begin
    if Hay[i] = first then
    begin
      ok := True;
      j := 1;
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

// last newline (10) before index m in data[0..m-1], +1; or 0.
function LineStart(Data: PByte; M: SizeInt): SizeInt;
var
  i: SizeInt;
begin
  i := M - 1;
  while i >= 0 do
  begin
    if Data[i] = 10 then begin LineStart := i + 1; Exit; end;
    Dec(i);
  end;
  LineStart := 0;
end;

// first newline (10) at/after m; or len.
function LineEnd(Data: PByte; M, Len: SizeInt): SizeInt;
var
  i: SizeInt;
begin
  i := M;
  while i < Len do
  begin
    if Data[i] = 10 then begin LineEnd := i; Exit; end;
    Inc(i);
  end;
  LineEnd := Len;
end;

procedure SearchFile(const Path: RawByteString);
var
  Data: RawByteString;
  Low: RawByteString;
  Hay, Needle: PByte;
  Len, NLen, Peek, Pos, m, ls, le, i, got, off: SizeInt;
  fd: cint;
  st: Stat;
begin
  fd := FpOpen(Path, O_RDONLY);
  if fd < 0 then Exit;
  if FpFStat(fd, st) <> 0 then begin FpClose(fd); Exit; end;
  Len := st.st_size;
  SetLength(Data, Len);
  off := 0;
  while off < Len do
  begin
    got := FpRead(fd, Data[off + 1], Len - off);
    if got <= 0 then Break;
    Inc(off, got);
  end;
  FpClose(fd);
  if off < Len then Len := off;
  SetLength(Data, Len);

  Peek := Len;
  if Peek > 65536 then Peek := 65536;
  for i := 0 to Peek - 1 do
    if Byte(Data[i + 1]) = 0 then Exit; // binary

  if Len = 0 then
    Hay := nil
  else
    Hay := PByte(@Data[1]);

  if CI then
  begin
    SetLength(Low, Len);
    if Len > 0 then
      AsciiLower(PByte(@Low[1]), Hay, Len);
    if Len > 0 then Hay := PByte(@Low[1]) else Hay := nil;
    Needle := PByte(LPat);
    NLen := Length(LPat);
  end
  else
  begin
    Needle := PByte(Pat);
    NLen := Length(Pat);
  end;

  Pos := 0;
  while Pos < Len do  // < not <= : empty-pattern fix
  begin
    m := ByteIndex(Hay, Len, Needle, NLen, Pos);
    if m < 0 then Break;
    ls := LineStart(PByte(@Data[1]), m);
    le := LineEnd(PByte(@Data[1]), m, Len);
    Matched := True;
    if Multi then
    begin
      OutStr(Path);
      OutByte(Ord(':'));
    end;
    if le > ls then
      OutBytes(@Data[ls + 1], le - ls);
    OutByte(10);
    Pos := le + 1;
  end;
end;

procedure WalkDir(const Dir: RawByteString); forward;

procedure Visit(const Path: RawByteString);
var
  st: Stat;
begin
  if FpLStat(Path, st) <> 0 then Exit;
  if fpS_ISLNK(st.st_mode) then Exit; // never follow symlinks
  if fpS_ISDIR(st.st_mode) then
  begin
    if Recursive then WalkDir(Path);
  end
  else if fpS_ISREG(st.st_mode) then
    SearchFile(Path);
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
    Visit(Dir + '/' + name);
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

var
  Paths: array of RawByteString;
  NPaths: SizeInt = 0;
  i, k: Integer;
  a: RawByteString;
  NoMore: Boolean = False;
  c: Char;
  st: Stat;
begin
  SetLength(OutBuf, OUTCAP);
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
        else
          Usage;
        end;
      end;
    end
    else if not PatSet then
    begin
      Pat := a;
      PatSet := True;
    end
    else
    begin
      Paths[NPaths] := a;
      Inc(NPaths);
    end;
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
    else if fpS_ISREG(st.st_mode) then
      SearchFile(Paths[i])
    else if fpS_ISLNK(st.st_mode) then
    begin
      // top-level symlink: stat through it to decide file vs dir like grep does?
      // spec: use FpLStat to detect; skip symlinks during walk. Top-level arg:
      // grep -F follows top-level symlink args. Resolve once.
      if FpStat(Paths[i], st) = 0 then
      begin
        if fpS_ISREG(st.st_mode) then SearchFile(Paths[i])
        else if fpS_ISDIR(st.st_mode) and Recursive then WalkDir(Paths[i]);
      end;
    end;
  end;

  FlushOut;
  if Matched then Halt(0) else Halt(1);
end.
