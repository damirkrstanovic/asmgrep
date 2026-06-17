-- adagrep_std_mt - idiomatic + naive Ada tasks. A pool of worker tasks (one
-- per CPU) pull file indices off a shared protected counter. Each file is read
-- IN FULL into a FRESH allocation before the binary check (deliberately
-- allocation-heavy tier: no buffer reuse). Per-file output blocks are
-- serialized to stdout under a protected object. Matches `grep -F`.
with Ada.Command_Line;        use Ada.Command_Line;
with Ada.Directories;         use Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Text_IO;
with GNAT.OS_Lib;
with System.Multiprocessors;

procedure Grep_Mt is

   PREFIX : constant := 65536;

   type Str_Acc is access String;

   Pat       : Str_Acc := null;
   LPat      : Str_Acc := null;
   Pat_Set   : Boolean := False;
   CI        : Boolean := False;
   Recursive : Boolean := False;
   Multi     : Boolean := False;

   --  Set true (by any task) if at least one match was emitted.
   Matched : Boolean := False;
   pragma Atomic (Matched);

   --  Collected regular-file paths (filled single-threaded before tasks run).
   type Path_Vec is array (Positive range <>) of Str_Acc;
   type Path_Vec_Acc is access Path_Vec;
   File_List : Path_Vec_Acc := null;
   N_Files   : Natural := 0;

   procedure Add_File (Path : String) is
   begin
      if File_List = null then
         File_List := new Path_Vec (1 .. 64);
      elsif N_Files >= File_List'Length then
         declare
            Nv : constant Path_Vec_Acc :=
              new Path_Vec (1 .. File_List'Length * 2);
         begin
            Nv (1 .. N_Files) := File_List (1 .. N_Files);
            File_List := Nv;
         end;
      end if;
      N_Files := N_Files + 1;
      File_List (N_Files) := new String'(Path);
   end Add_File;

   --  Shared work counter: each task grabs the next file index atomically.
   protected Dispatcher is
      procedure Next (Idx : out Natural);
   private
      Cur : Natural := 0;
   end Dispatcher;

   protected body Dispatcher is
      procedure Next (Idx : out Natural) is
      begin
         Cur := Cur + 1;
         Idx := Cur;
      end Next;
   end Dispatcher;

   --  Serialize each file's output block (per-file atomic; cross-file order
   --  unspecified). Writes raw bytes to fd 1 (handles partial writes, no
   --  newline translation).
   protected Output is
      procedure Put (Buf : Str_Acc; Len : Natural);
   end Output;

   protected body Output is
      procedure Put (Buf : Str_Acc; Len : Natural) is
         Off : Natural := 1;
         N   : Integer;
      begin
         while Off <= Len loop
            N := GNAT.OS_Lib.Write (1, Buf (Off)'Address, Len - Off + 1);
            exit when N <= 0;
            Off := Off + N;
         end loop;
      end Put;
   end Output;

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

   function Line_Start (D : String; M : Natural) return Natural is
   begin
      for I in reverse 1 .. M - 1 loop
         if D (I) = Character'Val (10) then
            return I + 1;
         end if;
      end loop;
      return 1;
   end Line_Start;

   function Line_End (D : String; M : Natural; Len : Natural) return Natural is
   begin
      for I in M .. Len loop
         if D (I) = Character'Val (10) then
            return I - 1;
         end if;
      end loop;
      return Len;
   end Line_End;

   --  Search one file. FRESH allocation of the full file contents each call
   --  (naive tier). Accumulates output into a local growable buffer and emits
   --  it once under the Output protected object.
   procedure Search_File (Path : String) is
      use Ada.Streams;
      use Ada.Streams.Stream_IO;
      File   : File_Type;
      Len    : Natural;
      Peek   : Natural;
      Data   : Str_Acc;
      Low    : Str_Acc := null;
      Hay    : Str_Acc;
      Needle : Str_Acc;
      NLen   : Natural;
      Pos    : Natural;
      M, LS, LE : Natural;

      Out_Buf : Str_Acc := new String (1 .. 4096);
      Out_Len : Natural := 0;

      procedure Grow (Need : Natural) is
      begin
         if Out_Len + Need > Out_Buf'Length then
            declare
               Cap : Natural := Out_Buf'Length;
               Nb  : Str_Acc;
            begin
               while Cap < Out_Len + Need loop
                  Cap := Cap * 2;
               end loop;
               Nb := new String (1 .. Cap);
               Nb (1 .. Out_Len) := Out_Buf (1 .. Out_Len);
               Out_Buf := Nb;
            end;
         end if;
      end Grow;

      procedure Emit (S : String) is
      begin
         if S'Length = 0 then
            return;
         end if;
         Grow (S'Length);
         Out_Buf (Out_Len + 1 .. Out_Len + S'Length) := S;
         Out_Len := Out_Len + S'Length;
      end Emit;

      procedure Emit_Byte (B : Character) is
      begin
         Grow (1);
         Out_Buf (Out_Len + 1) := B;
         Out_Len := Out_Len + 1;
      end Emit_Byte;

   begin
      begin
         Open (File, In_File, Path);
      exception
         when others =>
            return;
      end;
      Len := Natural (Size (File));
      Data := new String (1 .. Natural'Max (Len, 1));  -- fresh full read

      if Len > 0 then
         declare
            SEA  : Stream_Element_Array (1 .. Stream_Element_Offset (Len));
            Last : Stream_Element_Offset;
         begin
            Read (File, SEA, Last);
            Len := Natural (Last);
            for I in 1 .. Len loop
               Data (I) :=
                 Character'Val (Natural (SEA (Stream_Element_Offset (I))));
            end loop;
         end;
      end if;
      Close (File);

      Peek := (if Len < PREFIX then Len else PREFIX);
      for I in 1 .. Peek loop
         if Data (I) = Character'Val (0) then
            return;  -- binary, skip
         end if;
      end loop;

      if CI then
         Low := new String (1 .. Natural'Max (Len, 1));
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

      if Out_Len > 0 then
         Output.Put (Out_Buf, Out_Len);
      end if;
   end Search_File;

   --  Worker task type: loop pulling indices until exhausted.
   task type Worker;
   task body Worker is
      Idx : Natural;
   begin
      loop
         Dispatcher.Next (Idx);
         exit when Idx > N_Files;
         Search_File (File_List (Idx).all);
      end loop;
   end Worker;

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
               Add_File (Fp);
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

   function Num_Tasks return Positive is
      N : constant Natural := Natural (System.Multiprocessors.Number_Of_CPUs);
   begin
      if N < 1 then
         return 6;
      else
         return N;
      end if;
   end Num_Tasks;

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
                  Add_File (P);
               when others =>
                  null;
            end case;
         end if;
      exception
         when others =>
            null;
      end;
   end loop;

   if N_Files > 0 then
      declare
         NT : constant Positive := Num_Tasks;
         Pool : array (1 .. NT) of Worker;
         pragma Unreferenced (Pool);
      begin
         null;  -- tasks run; block here until all terminate
      end;
   end if;

   if Matched then
      GNAT.OS_Lib.OS_Exit (0);
   else
      GNAT.OS_Lib.OS_Exit (1);
   end if;
end Grep_Mt;
