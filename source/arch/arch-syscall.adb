--  arch-syscall.adb: Syscall table and implementation.
--  Copyright (C) 2021 streaksu
--
--  This program is free software: you can redistribute it and/or modify
--  it under the terms of the GNU General Public License as published by
--  the Free Software Foundation, either version 3 of the License, or
--  (at your option) any later version.
--
--  This program is distributed in the hope that it will be useful,
--  but WITHOUT ANY WARRANTY; without even the implied warranty of
--  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
--  GNU General Public License for more details.
--
--  You should have received a copy of the GNU General Public License
--  along with this program.  If not, see <http://www.gnu.org/licenses/>.

with System; use System;
with System.Storage_Elements; use System.Storage_Elements;
with Arch.Wrappers;
with Lib.Messages;
with Lib;
with Userland.Process; use Userland.Process;
with Userland.Loader;
with VFS.File; use VFS.File;
with Scheduler;
with Memory.Virtual; use Memory.Virtual;
with Memory.Physical;
with Memory; use Memory;
with Ada.Unchecked_Deallocation;

package body Arch.Syscall is
   --  Errno values, they are ABI and arbitrary.
   Error_No_Error        : constant := 0;
   Error_Bad_Access      : constant := 1002; -- EACCES.
   Error_Would_Block     : constant := 1006; -- EAGAIN.
   Error_Invalid_Value   : constant := 1026; -- EINVAL.
   Error_No_Entity       : constant := 1043; -- ENOENT.
   Error_Not_Implemented : constant := 1051; -- ENOSYS.
   Error_Not_Supported   : constant := 1057; -- ENOSUP.
   Error_Invalid_Seek    : constant := 1069; -- ESPIPE.
   Error_Bad_File        : constant := 1081; -- EBADFD.

   --  Whether we are to print syscall information.
   Is_Tracing : Boolean := False;

   type String_Acc is access all String;
   procedure Free_Str is new Ada.Unchecked_Deallocation (String, String_Acc);

   procedure Set_Tracing (Value : Boolean) is
   begin
      Is_Tracing := Value;
   end Set_Tracing;

   procedure Syscall_Handler (Number : Integer; State : access ISR_GPRs) is
      Returned : Unsigned_64 := Unsigned_64'Last;
      Errno    : Unsigned_64 := Error_No_Error;
      pragma Unreferenced (Number);
   begin
      --  Swap to kernel GS and enable interrupts.
      Interrupts.Set_Interrupt_Flag (True);
      Wrappers.Swap_GS;

      --  Call the inner syscall.
      --  RAX is the return value, as well as the syscall number.
      --  RDX is the returned errno.
      --  Arguments can be RDI, RSI, RDX, RCX, R8, and R9, in that order.
      case State.RAX is
         when 0 =>
            Syscall_Exit (State.RDI);
         when 1 =>
            Returned := Syscall_Set_TCB (State.RDI, Errno);
         when 2 =>
            Returned := Syscall_Open (State.RDI, State.RSI, Errno);
         when 3 =>
            Returned := Syscall_Close (State.RDI, Errno);
         when 4 =>
            Returned := Syscall_Read (State.RDI, State.RSI, State.RDX, Errno);
         when 5 =>
            Returned := Syscall_Write (State.RDI, State.RSI, State.RDX, Errno);
         when 6 =>
            Returned := Syscall_Seek (State.RDI, State.RSI, State.RDX, Errno);
         when 7 =>
            Returned := Syscall_Mmap (State.RDI, State.RSI, State.RDX,
                                      State.RCX, State.R8, State.R9, Errno);
         when 8 =>
            Returned := Syscall_Munmap (State.RDI, State.RSI, Errno);
         when 9 =>
            Returned := Syscall_Get_PID;
         when 10 =>
            Returned := Syscall_Get_Parent_PID;
         when 11 =>
            Returned := Syscall_Thread_Preference (State.RDI, Errno);
         when 12 =>
            Returned := Syscall_Exec (State.RDI, State.RSI, State.RDX, Errno);
         when 13 =>
            Returned := Syscall_Fork (State, Errno);
         when others =>
            Errno := Error_Not_Implemented;
      end case;

      --  Assign the return values and swap back to user GS.
      State.RAX := Returned;
      State.RDX := Errno;
      Wrappers.Swap_GS;
   end Syscall_Handler;

   procedure Syscall_Exit (Error_Code : Unsigned_64) is
      Current_Thread  : constant Scheduler.TID := Scheduler.Get_Current_Thread;
      Current_Process : constant Userland.Process.Process_Data_Acc :=
            Userland.Process.Get_By_Thread (Current_Thread);
   begin
      if Is_Tracing then
         Lib.Messages.Put ("syscall exit(");
         Lib.Messages.Put (Error_Code);
         Lib.Messages.Put_Line (")");
      end if;

      Userland.Process.Flush_Threads  (Current_Process);
      Userland.Process.Flush_Files    (Current_Process);
      Userland.Process.Delete_Process (Current_Process);
      Scheduler.Bail;
   end Syscall_Exit;

   function Syscall_Set_TCB
      (Address : Unsigned_64;
       Errno   : out Unsigned_64) return Unsigned_64 is
   begin
      if Is_Tracing then
         Lib.Messages.Put ("syscall set_tcb(");
         Lib.Messages.Put (Address);
         Lib.Messages.Put_Line (")");
      end if;
      if Address = 0 then
         Errno := Error_Invalid_Value;
         return Unsigned_64'Last;
      else
         Wrappers.Write_FS (Address);
         Errno := Error_No_Error;
         return 0;
      end if;
   end Syscall_Set_TCB;

   function Syscall_Open
      (Address : Unsigned_64;
       Flags   : Unsigned_64;
       Errno   : out Unsigned_64) return Unsigned_64
   is
      Addr : constant System.Address := To_Address (Integer_Address (Address));
   begin
      if Address = 0 then
         if Is_Tracing then
            Lib.Messages.Put ("syscall open(null, ");
            Lib.Messages.Put (Flags);
            Lib.Messages.Put_Line (")");
         end if;
         goto Error_Return;
      end if;
      declare
         Path_Length  : constant Natural := Lib.C_String_Length (Addr);
         Path_String  : String (1 .. Path_Length) with Address => Addr;
         Current_Thre : constant Scheduler.TID := Scheduler.Get_Current_Thread;
         Current_Proc : constant Userland.Process.Process_Data_Acc :=
            Userland.Process.Get_By_Thread (Current_Thre);
         Open_Mode    : VFS.File.Access_Mode;
         Opened_File  : VFS.File.File_Acc;
         Returned_FD  : Natural;
      begin
         if Is_Tracing then
            Lib.Messages.Put ("syscall open(");
            Lib.Messages.Put (Path_String);
            Lib.Messages.Put (", ");
            Lib.Messages.Put (Flags);
            Lib.Messages.Put_Line (")");
         end if;
         --  Parse the mode.
         if (Flags and O_RDWR) /= 0 then
            Open_Mode := VFS.File.Access_RW;
         elsif (Flags and O_RDONLY) /= 0 then
            Open_Mode := VFS.File.Access_R;
         elsif (Flags and O_WRONLY) /= 0 then
            Open_Mode := VFS.File.Access_W;
         else
            --  XXX: This should go to Error_Return, yet mlibc's dynamic linker
            --  passes flags = 0 for no reason, so we will put a default.
            --  This should not be the case, and it is to be fixed.
            --  goto Error_Return;
            Open_Mode := VFS.File.Access_R;
         end if;

         --  Open the file with an absolute path.
         if Path_String'Length <= 2 then
            goto Error_Return;
         end if;

         --  Actually open the file.
         Opened_File := VFS.File.Open (Path_String, Open_Mode);
         if Opened_File = null then
            goto Error_Return;
         else
            if not Userland.Process.Add_File
               (Current_Proc, Opened_File, Returned_FD)
            then
               goto Error_Return;
            else
               Errno := Error_No_Error;
               return Unsigned_64 (Returned_FD);
            end if;
         end if;
      end;
   <<Error_Return>>
      Errno := Error_Invalid_Value;
      return Unsigned_64'Last;
   end Syscall_Open;

   function Syscall_Close
      (File_D : Unsigned_64;
       Errno  : out Unsigned_64) return Unsigned_64
   is
      Current_Thread  : constant Scheduler.TID := Scheduler.Get_Current_Thread;
      Current_Process : constant Userland.Process.Process_Data_Acc :=
         Userland.Process.Get_By_Thread (Current_Thread);
      File            : constant Natural := Natural (File_D);
   begin
      if Is_Tracing then
         Lib.Messages.Put ("syscall close(");
         Lib.Messages.Put (File_D);
         Lib.Messages.Put_Line (")");
      end if;
      Userland.Process.Remove_File (Current_Process, File);
      Errno := Error_No_Error;
      return 0;
   end Syscall_Close;

   function Syscall_Read
      (File_D : Unsigned_64;
       Buffer : Unsigned_64;
       Count  : Unsigned_64;
       Errno  : out Unsigned_64) return Unsigned_64
   is
      Buffer_Addr     : constant System.Address :=
         To_Address (Integer_Address (Buffer));
      Current_Thread  : constant Scheduler.TID := Scheduler.Get_Current_Thread;
      Current_Process : constant Userland.Process.Process_Data_Acc :=
         Userland.Process.Get_By_Thread (Current_Thread);
      File : constant VFS.File.File_Acc :=
         Current_Process.File_Table (Natural (File_D));
   begin
      if Is_Tracing then
         Lib.Messages.Put ("syscall read(");
         Lib.Messages.Put (File_D);
         Lib.Messages.Put (", ");
         Lib.Messages.Put (Buffer, False, True);
         Lib.Messages.Put (", ");
         Lib.Messages.Put (Count);
         Lib.Messages.Put_Line (")");
      end if;
      if File = null then
         Errno := Error_Bad_File;
         return Unsigned_64'Last;
      end if;
      if Buffer = 0 then
         Errno := Error_Invalid_Value;
         return Unsigned_64'Last;
      end if;

      Errno := Error_No_Error;
      return Unsigned_64 (VFS.File.Read (File, Integer (Count), Buffer_Addr));
   end Syscall_Read;

   function Syscall_Write
      (File_D : Unsigned_64;
       Buffer : Unsigned_64;
       Count  : Unsigned_64;
       Errno  : out Unsigned_64) return Unsigned_64
   is
      Buffer_Addr     : constant System.Address :=
         To_Address (Integer_Address (Buffer));
      Current_Thread  : constant Scheduler.TID := Scheduler.Get_Current_Thread;
      Current_Process : constant Userland.Process.Process_Data_Acc :=
         Userland.Process.Get_By_Thread (Current_Thread);
      File : constant File_Acc :=
         Current_Process.File_Table (Natural (File_D));
   begin
      if Is_Tracing then
         Lib.Messages.Put ("syscall write(");
         Lib.Messages.Put (File_D);
         Lib.Messages.Put (", ");
         Lib.Messages.Put (Buffer, False, True);
         Lib.Messages.Put (", ");
         Lib.Messages.Put (Count);
         Lib.Messages.Put_Line (")");
      end if;

      if File = null then
         Errno := Error_Bad_File;
         return Unsigned_64'Last;
      end if;
      if Buffer = 0 then
         Errno := Error_Invalid_Value;
         return Unsigned_64'Last;
      end if;

      Errno := Error_No_Error;
      return Unsigned_64 (VFS.File.Write (File, Integer (Count), Buffer_Addr));
   end Syscall_Write;

   function Syscall_Seek
      (File_D : Unsigned_64;
       Offset : Unsigned_64;
       Whence : Unsigned_64;
       Errno  : out Unsigned_64) return Unsigned_64
   is
      Current_Thread  : constant Scheduler.TID := Scheduler.Get_Current_Thread;
      Current_Process : constant Userland.Process.Process_Data_Acc :=
         Userland.Process.Get_By_Thread (Current_Thread);
      File : constant VFS.File.File_Acc :=
         Current_Process.File_Table (Natural (File_D));
      Passed_Offset : constant Natural := Natural (Offset);
   begin
      if Is_Tracing then
         Lib.Messages.Put ("syscall seek(");
         Lib.Messages.Put (File_D);
         Lib.Messages.Put (", ");
         Lib.Messages.Put (Offset);
         Lib.Messages.Put (", ");
         Lib.Messages.Put (Whence);
         Lib.Messages.Put_Line (")");
      end if;
      --  TODO: If the FD is a pipe or tty we need to set this errno.
      --  This is a quicky to be changed later for something more general.
      if File_D = 0 or File_D = 1 or File_D = 2 then
         Errno := Error_Invalid_Seek;
         return Unsigned_64'Last;
      end if;

      if File = null then
         Errno := Error_Bad_File;
         return Unsigned_64'Last;
      end if;

      case Whence is
         when SEEK_SET =>
            File.Index := Passed_Offset;
         when SEEK_CURRENT =>
            File.Index := File.Index + Passed_Offset;
         when SEEK_END =>
            File.Index := VFS.File.Get_Size (File) + Passed_Offset;
         when others =>
            Errno := Error_Invalid_Value;
            return Unsigned_64'Last;
      end case;

      Errno := Error_No_Error;
      return Unsigned_64 (File.Index);
   end Syscall_Seek;

   function Syscall_Mmap
      (Hint       : Unsigned_64;
       Length     : Unsigned_64;
       Protection : Unsigned_64;
       Flags      : Unsigned_64;
       File_D     : Unsigned_64;
       Offset     : Unsigned_64;
       Errno      : out Unsigned_64) return Unsigned_64
   is
      Current_Thread  : constant Scheduler.TID := Scheduler.Get_Current_Thread;
      Current_Process : constant Userland.Process.Process_Data_Acc :=
         Userland.Process.Get_By_Thread (Current_Thread);
      Map : constant Memory.Virtual.Page_Map_Acc := Current_Process.Common_Map;

      Map_Not_Execute : Boolean := True;
      Map_Flags : Memory.Virtual.Page_Flags := (
         Present         => True,
         Read_Write      => False,
         User_Supervisor => True,
         Write_Through   => False,
         Cache_Disable   => False,
         Accessed        => False,
         Dirty           => False,
         PAT             => False,
         Global          => False
      );

      Aligned_Hint : Unsigned_64 := Lib.Align_Up (Hint, Page_Size);
   begin
      if Is_Tracing then
         Lib.Messages.Put ("syscall mmap(");
         Lib.Messages.Put (Hint, False, True);
         Lib.Messages.Put (", ");
         Lib.Messages.Put (Length, False, True);
         Lib.Messages.Put (", ");
         Lib.Messages.Put (Protection, False, True);
         Lib.Messages.Put (", ");
         Lib.Messages.Put (Flags, False, True);
         Lib.Messages.Put (", ");
         Lib.Messages.Put (File_D);
         Lib.Messages.Put (", ");
         Lib.Messages.Put (Offset, False, True);
         Lib.Messages.Put_Line (")");
      end if;

      --  Check protection flags.
      Map_Flags.Read_Write := (Protection and Protection_Write)  /= 0;
      Map_Not_Execute      := (Protection and Protection_Execute) = 0;

      --  Check that we got a length.
      if Length = 0 then
         Errno := Error_Invalid_Value;
         return Unsigned_64'Last;
      end if;

      --  Set our own hint if none was provided.
      if Hint = 0 then
         Aligned_Hint := Current_Process.Alloc_Base;
         Current_Process.Alloc_Base := Current_Process.Alloc_Base + Length;
      end if;

      --  Check for fixed.
      if (Flags and Map_Fixed) /= 0 and Aligned_Hint /= Hint then
         Errno := Error_Invalid_Value;
         return Unsigned_64'Last;
      end if;

      --  We only support anonymous right now, so if its not anon, we cry.
      if (Flags and Map_Anon) = 0 then
         Errno := Error_Not_Implemented;
         return Unsigned_64'Last;
      end if;

      --  Allocate the requested block and map it.
      declare
         A : constant Virtual_Address := Memory.Physical.Alloc (Size (Length));
      begin
         Memory.Virtual.Map_Range (
            Map,
            Virtual_Address (Aligned_Hint),
            A - Memory_Offset,
            Length,
            Map_Flags,
            Map_Not_Execute,
            True
         );
         Errno := Error_No_Error;
         return Aligned_Hint;
      end;
   end Syscall_Mmap;

   function Syscall_Munmap
      (Address    : Unsigned_64;
       Length     : Unsigned_64;
       Errno      : out Unsigned_64) return Unsigned_64
   is
      Current_Thread  : constant Scheduler.TID := Scheduler.Get_Current_Thread;
      Current_Process : constant Userland.Process.Process_Data_Acc :=
         Userland.Process.Get_By_Thread (Current_Thread);
      Map : constant Memory.Virtual.Page_Map_Acc := Current_Process.Common_Map;
      Addr : constant Physical_Address :=
         Memory.Virtual.Virtual_To_Physical (Map, Virtual_Address (Address));
   begin
      if Is_Tracing then
         Lib.Messages.Put ("syscall munmap(");
         Lib.Messages.Put (Address, False, True);
         Lib.Messages.Put (", ");
         Lib.Messages.Put (Length, False, True);
         Lib.Messages.Put_Line (")");
      end if;
      --  We only support MAP_ANON and MAP_FIXED, so we can just assume we want
      --  to free.
      --  TODO: Actually unmap, not only free.
      Memory.Physical.Free (Addr);
      Errno := Error_No_Error;
      return 0;
   end Syscall_Munmap;

   function Syscall_Get_PID return Unsigned_64 is
      Current_Thread  : constant Scheduler.TID := Scheduler.Get_Current_Thread;
      Current_Process : constant Userland.Process.Process_Data_Acc :=
         Userland.Process.Get_By_Thread (Current_Thread);
   begin
      if Is_Tracing then
         Lib.Messages.Put_Line ("syscall getpid()");
      end if;
      return Unsigned_64 (Current_Process.Process_PID);
   end Syscall_Get_PID;

   function Syscall_Get_Parent_PID return Unsigned_64 is
      Current_Thread  : constant Scheduler.TID := Scheduler.Get_Current_Thread;
      Current_Process : constant Userland.Process.Process_Data_Acc :=
         Userland.Process.Get_By_Thread (Current_Thread);
      Parent_Process : constant Natural := Current_Process.Parent_PID;
   begin
      if Is_Tracing then
         Lib.Messages.Put_Line ("syscall getppid()");
      end if;
      return Unsigned_64 (Parent_Process);
   end Syscall_Get_Parent_PID;

   function Syscall_Thread_Preference
      (Preference : Unsigned_64;
       Errno      : out Unsigned_64) return Unsigned_64
   is
      Thread : constant Scheduler.TID := Scheduler.Get_Current_Thread;
   begin
      if Is_Tracing then
         Lib.Messages.Put ("syscall thread_preference(");
         Lib.Messages.Put (Preference);
         Lib.Messages.Put_Line (")");
      end if;

      --  Check if we have a valid preference before doing anything with it.
      if Preference > Unsigned_64 (Positive'Last) then
         Errno := Error_Invalid_Value;
         return Unsigned_64'Last;
      end if;

      --  If 0, we have to return the current preference, else, we gotta set
      --  it to the passed value.
      if Preference = 0 then
         declare
            Pr : constant Natural := Scheduler.Get_Thread_Preference (Thread);
         begin
            --  If we got error preference, return that, even tho that should
            --  be impossible.
            if Pr = 0 then
               Errno := Error_Not_Supported;
               return Unsigned_64'Last;
            else
               Errno := Error_No_Error;
               return Unsigned_64 (Pr);
            end if;
         end;
      else
         Scheduler.Set_Thread_Preference (Thread, Natural (Preference));
         Errno := Error_No_Error;
         return Unsigned_64 (Scheduler.Get_Thread_Preference (Thread));
      end if;
   end Syscall_Thread_Preference;

   function Syscall_Exec
      (Address : Unsigned_64;
       Argv    : Unsigned_64;
       Envp    : Unsigned_64;
       Errno   : out Unsigned_64) return Unsigned_64
   is
      --  FIXME: This type should be dynamic ideally and not have a maximum.
      type Arg_Arr is array (1 .. 40) of Unsigned_64;

      Current_Thread  : constant Scheduler.TID := Scheduler.Get_Current_Thread;
      Current_Process : constant Userland.Process.Process_Data_Acc :=
         Userland.Process.Get_By_Thread (Current_Thread);

      Addr : constant System.Address := To_Address (Integer_Address (Address));
      Path_Length : constant Natural := Lib.C_String_Length (Addr);
      Path_String : String (1 .. Path_Length) with Address => Addr;
      Opened_File : constant File_Acc := Open (Path_String, Access_R);

      Args_Raw : Arg_Arr with Address => To_Address (Integer_Address (Argv));
      Env_Raw  : Arg_Arr with Address => To_Address (Integer_Address (Envp));
      Args_Count : Natural := 0;
      Env_Count  : Natural := 0;
   begin
      if Is_Tracing then
         Lib.Messages.Put ("syscall exec(" & Path_String & ")");
      end if;

      if Opened_File = null then
         Errno := Error_No_Entity;
         return Unsigned_64'Last;
      end if;

      --  Count the args and envp we have, and copy them to Ada arrays.
      for I in Args_Raw'Range loop
         exit when Args_Raw (I) = 0;
         Args_Count := Args_Count + 1;
      end loop;
      for I in Env_Raw'Range loop
         exit when Env_Raw (I) = 0;
         Env_Count := Env_Count + 1;
      end loop;

      declare
         Args : Userland.Argument_Arr    (1 .. Args_Count);
         Env  : Userland.Environment_Arr (1 .. Env_Count);
      begin
         for I in 1 .. Args_Count loop
            declare
               Addr : constant System.Address :=
                  To_Address (Integer_Address (Args_Raw (I)));
               Arg_Length : constant Natural := Lib.C_String_Length (Addr);
               Arg_String : String (1 .. Arg_Length) with Address => Addr;
            begin
               Args (I) := new String'(Arg_String);
            end;
         end loop;
         for I in 1 .. Env_Count loop
            declare
               Addr : constant System.Address :=
                  To_Address (Integer_Address (Env_Raw (I)));
               Arg_Length : constant Natural := Lib.C_String_Length (Addr);
               Arg_String : String (1 .. Arg_Length) with Address => Addr;
            begin
               Env (I) := new String'(Arg_String);
            end;
         end loop;

         Userland.Process.Flush_Threads (Current_Process);
         if not Userland.Loader.Start_Program
            (Opened_File, Args, Env, Current_Process)
         then
            Errno := Error_Bad_Access;
            return Unsigned_64'Last;
         end if;

         for Arg of Args loop
            Free_Str (Arg);
         end loop;
         for En of Env loop
            Free_Str (En);
         end loop;

         Userland.Process.Remove_Thread (Current_Process, Current_Thread);
         Scheduler.Bail;
         Errno := Error_No_Error;
         return 0;
      end;
   end Syscall_Exec;

   function Syscall_Fork
      (State_To_Fork : access ISR_GPRs;
       Errno         : out Unsigned_64) return Unsigned_64
   is
      Current_Thread  : constant Scheduler.TID := Scheduler.Get_Current_Thread;
      Current_Process : constant Userland.Process.Process_Data_Acc :=
         Userland.Process.Get_By_Thread (Current_Thread);
      Forked_Process : constant Userland.Process.Process_Data_Acc :=
         Userland.Process.Fork (Current_Process);
   begin
      if Is_Tracing then
         Lib.Messages.Put_Line ("syscall fork()");
      end if;

      --  Fork the process.
      if Forked_Process = null then
         Errno := Error_Would_Block;
         return Unsigned_64'Last;
      end if;

      --  Set a good memory map.
      Forked_Process.Common_Map := Memory.Virtual.Clone_Space (Current_Process.Common_Map);

      --  Create a running thread cloning the caller.
      if not Add_Thread (Forked_Process,
         Scheduler.Create_User_Thread (State_To_Fork, Forked_Process.Common_Map))
      then
         Errno := Error_Would_Block;
         return Unsigned_64'Last;
      end if;

      Errno := Error_No_Error;
      return Unsigned_64 (Forked_Process.Process_PID);
   end Syscall_Fork;
end Arch.Syscall;
