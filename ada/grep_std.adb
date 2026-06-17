-- adagrep_std - idiomatic single-threaded Ada literal grep.
-- Reads each file in full (Stream_IO into a byte-exact String), prefix
-- NUL-checks the first 64 KB, byte-exact substring search via a hand scan,
-- ASCII-only case-insensitivity, buffered output. Matches `grep -F`.
with Ada.Command_Line;        use Ada.Command_Line;
with Ada.Directories;         use Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Text_IO;
with GNAT.OS_Lib;

procedure Grep_Std is

   PREFIX : constant := 65536;

   --  A String is a byte array in Ada: Character is 8-bit Latin-1 and
   --  Character'Pos = the raw byte. We operate on bytes throughout.

   type Str_Acc is access String;

   Pat       : Str_Acc := null;
   LPat      : Str_Acc := null;
   Pat_Set   : Boolean := False;
   CI        : Boolean := False;
   Recursive : Boolean := False;
   Multi     : Boolean := False;
   Matched   : Boolean := False;

   --  Reused buffers (single-threaded, so global reuse is fine).
   Data : Str_Acc := null;  -- raw file bytes (1-based)
   Low  : Str_Acc := null;  -- ASCII-lowercase copy

   --  Buffered stdout: accumulate raw bytes, flush once at the end.
   Out_Buf : Str_Acc := null;
   Out_Len : Natural := 0;

   procedure Ensure (Buf : in out Str_Acc; N : Natural) is
   begin
      if Buf = null or else Buf'Length < N then
         Buf := new String (1 .. N + N / 2 + 4096);
      end if;
   end Ensure;

   --  Write raw bytes to fd 1, no newline translation, handling partial
   --  writes. Uses the libc write(2) directly via GNAT.OS_Lib so pipes and
   --  redirects work (Stream_IO on /dev/stdout would seek and fail on a pipe).
   procedure Flush_Out is
      Off : Natural := 1;
      N   : Integer;
   begin
      while Off <= Out_Len loop
         N := GNAT.OS_Lib.Write
                (1, Out_Buf (Off)'Address, Out_Len - Off + 1);
         exit when N <= 0;
         Off := Off + N;
      end loop;
   end Flush_Out;

   procedure Emit_Byte (B : Character) is
   begin
      if Out_Buf = null or else Out_Len + 1 > Out_Buf'Length then
         declare
            New_Cap : constant Natural :=
              (if Out_Buf = null then 65536 else Out_Buf'Length * 2);
            Nb : Str_Acc := new String (1 .. New_Cap);
         begin
            if Out_Buf /= null then
               Nb (1 .. Out_Len) := Out_Buf (1 .. Out_Len);
            end if;
            Out_Buf := Nb;
         end;
      end if;
      Out_Buf (Out_Len + 1) := B;
      Out_Len := Out_Len + 1;
   end Emit_Byte;

   procedure Emit (S : String) is
   begin
      if S'Length = 0 then
         return;
      end if;
      if Out_Buf = null or else Out_Len + S'Length > Out_Buf'Length then
         declare
            New_Cap : Natural := (if Out_Buf = null then 65536
                                  else Out_Buf'Length);
            Nb : Str_Acc;
         begin
            while New_Cap < Out_Len + S'Length loop
               New_Cap := New_Cap * 2;
            end loop;
            Nb := new String (1 .. New_Cap);
            if Out_Buf /= null then
               Nb (1 .. Out_Len) := Out_Buf (1 .. Out_Len);
            end if;
            Out_Buf := Nb;
         end;
      end if;
      Out_Buf (Out_Len + 1 .. Out_Len + S'Length) := S;
      Out_Len := Out_Len + S'Length;
   end Emit;

   procedure Ascii_Lower (Dst : in out String; Src : String; N : Natural) is
      B : Character;
   begin
      for I in 1 .. N loop
         B := Src (Src'First + I - 1);
         if B in 'A' .. 'Z' then
            Dst (Dst'First + I - 1) := Character'Val (Character'Pos (B) + 32);
         else
            Dst (Dst'First + I - 1) := B;
         end if;
      end loop;
   end Ascii_Lower;

   --  Find Needle in Hay (1 .. HLen) at or after Start (1-based). Return
   --  index, or 0 if none. Empty needle => returns Start (handled by caller).
   function Byte_Index
     (Hay : String; HLen : Natural; Needle : String; NLen : Natural;
      Start : Natural) return Natural
   is
      First : Character;
      OK    : Boolean;
   begin
      if NLen = 0 then
         return Start;
      end if;
      First := Needle (Needle'First);
      for I in Start .. HLen - NLen + 1 loop
         if Hay (I) = First then
            OK := True;
            for J in 1 .. NLen - 1 loop
               if Hay (I + J) /= Needle (Needle'First + J) then
                  OK := False;
                  exit;
               end if;
            end loop;
            if OK then
               return I;
            end if;
         end if;
      end loop;
      return 0;
   end Byte_Index;

   --  Index of byte just past the LF before position M, or 1.
   function Line_Start (D : String; M : Natural) return Natural is
   begin
      for I in reverse 1 .. M - 1 loop
         if D (I) = Character'Val (10) then
            return I + 1;
         end if;
      end loop;
      return 1;
   end Line_Start;

   --  Index of LF at/after M minus 1, or Len (inclusive last byte of line).
   function Line_End (D : String; M : Natural; Len : Natural) return Natural is
   begin
      for I in M .. Len loop
         if D (I) = Character'Val (10) then
            return I - 1;
         end if;
      end loop;
      return Len;
   end Line_End;

   procedure Search_File (Path : String) is
      use Ada.Streams;
      use Ada.Streams.Stream_IO;
      File   : File_Type;
      Len    : Natural;
      Peek   : Natural;
      Hay    : Str_Acc;
      Needle : Str_Acc;
      NLen   : Natural;
      Pos    : Natural;
      M, LS, LE : Natural;
   begin
      begin
         Open (File, In_File, Path);
      exception
         when others =>
            return;
      end;
      Len := Natural (Size (File));
      Ensure (Data, Natural'Max (Len, 1));

      if Len > 0 then
         declare
            SEA  : Stream_Element_Array (1 .. Stream_Element_Offset (Len));
            Last : Stream_Element_Offset;
         begin
            Read (File, SEA, Last);
            Len := Natural (Last);  -- bytes actually read
            for I in 1 .. Len loop
               Data (I) :=
                 Character'Val (Natural (SEA (Stream_Element_Offset (I))));
            end loop;
         end;
      end if;
      Close (File);

      --  Binary check on the first 64 KB.
      Peek := (if Len < PREFIX then Len else PREFIX);
      for I in 1 .. Peek loop
         if Data (I) = Character'Val (0) then
            return;  -- binary, skip
         end if;
      end loop;

      if CI then
         Ensure (Low, Natural'Max (Len, 1));
         Ascii_Lower (Low.all, Data.all, Len);
         Hay := Low;
         Needle := LPat;
         NLen := (if LPat = null then 0 else LPat'Length);
      else
         Hay := Data;
         Needle := Pat;
         NLen := (if Pat = null then 0 else Pat'Length);
      end if;

      Pos := 1;
      while Pos <= Len loop
         M := Byte_Index (Hay.all, Len, Needle.all, NLen, Pos);
         exit when M = 0;
         LS := Line_Start (Data.all, M);
         LE := Line_End (Data.all, M, Len);
         Matched := True;
         if Multi then
            Emit (Path);
            Emit_Byte (':');
         end if;
         if LE >= LS then
            Emit (Data (LS .. LE));
         end if;
         Emit_Byte (Character'Val (10));
         Pos := LE + 2;
      end loop;
   end Search_File;

   procedure Walk (Dir : String) is
      Srch : Search_Type;
      Ent  : Directory_Entry_Type;
   begin
      Start_Search
        (Srch, Dir, "",
         Filter => (Ordinary_File => True, Directory => True,
                    Special_File => False));
      while More_Entries (Srch) loop
         Get_Next_Entry (Srch, Ent);
         declare
            Nm : constant String := Simple_Name (Ent);
            Fp : constant String := Full_Name (Ent);
            K  : constant File_Kind := Kind (Ent);
         begin
            if Nm = "." or else Nm = ".." then
               null;
            elsif K = Directory then
               Walk (Fp);
            elsif K = Ordinary_File then
               Search_File (Fp);
            end if;
         end;
      end loop;
      End_Search (Srch);
   exception
      when others =>
         null;
   end Walk;

   procedure Usage is
      Msg : constant String :=
        "usage: adagrep [-r] [-i] PATTERN PATH..." & Character'Val (10);
   begin
      Ada.Text_IO.Put (Ada.Text_IO.Standard_Error, Msg);
      GNAT.OS_Lib.OS_Exit (2);
   end Usage;

   Paths   : array (1 .. Argument_Count) of Str_Acc;
   N_Paths : Natural := 0;
   No_More : Boolean := False;

begin
   for I in 1 .. Argument_Count loop
      declare
         A : constant String := Argument (I);
      begin
         if not No_More and then A'Length >= 2 and then A (A'First) = '-' then
            if A = "--" then
               No_More := True;
            else
               for K in A'First + 1 .. A'Last loop
                  case A (K) is
                     when 'i' => CI := True;
                     when 'r' => Recursive := True;
                     when others => Usage;
                  end case;
               end loop;
            end if;
         elsif not Pat_Set then
            Pat := new String'(A);
            Pat_Set := True;
         else
            N_Paths := N_Paths + 1;
            Paths (N_Paths) := new String'(A);
         end if;
      end;
   end loop;

   if not Pat_Set or else N_Paths = 0 then
      Usage;
   end if;

   if Pat'Length > 0 then
      LPat := new String (1 .. Pat'Length);
      Ascii_Lower (LPat.all, Pat.all, Pat'Length);
   else
      LPat := new String (1 .. 0);
   end if;
   Multi := Recursive or else N_Paths > 1;

   for I in 1 .. N_Paths loop
      declare
         P : constant String := Paths (I).all;
      begin
         if Exists (P) then
            case Kind (P) is
               when Directory =>
                  if Recursive then
                     Walk (P);
                  end if;
               when Ordinary_File =>
                  Search_File (P);
               when others =>
                  null;
            end case;
         end if;
      exception
         when others =>
            null;
      end;
   end loop;

   Flush_Out;
   if Matched then
      GNAT.OS_Lib.OS_Exit (0);
   else
      GNAT.OS_Lib.OS_Exit (1);
   end if;
end Grep_Std;
