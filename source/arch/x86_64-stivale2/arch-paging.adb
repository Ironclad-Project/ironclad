--  arch-paging.adb: Virtual memory manager.
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

with Arch.Wrappers;
with Lib.Panic;
with Arch.MMU;

package body Arch.Paging is
   procedure Init
      (Memmap : access Arch.Stivale2.Memmap_Tag;
       PMRs   : access Arch.Stivale2.PMR_Tag)
   is
      Index : Physical_Address := 0;
      Flags : constant Page_Flags :=
         (Present         => True,
          Read_Write      => True,
          User_Supervisor => False,
          Write_Through   => False,
          Cache_Disable   => False,
          Accessed        => False,
          Dirty           => False,
          PAT             => False,
          Global          => False);
      Page_Size        : constant := 16#1000#;
      Hardcoded_Region : constant := 16#100000000#;
   begin
      --  Initialize the kernel pagemap.
      Kernel_Map := new Page_Map;

      --  Map PMRs of the kernel.
      --  This will always be mapped, so we can mark them global.
      for E of PMRs.Entries loop
         declare
            Phys_Addr : constant Physical_Address := E.Base - Kernel_Offset;
            Virt_Addr : constant Virtual_Address  := E.Base;
            Flags     : Page_Flags :=
               (Present => True, Read_Write => True, User_Supervisor => False,
                Write_Through => False, Cache_Disable => False,
                Accessed => False, Dirty => False, PAT => False,
                Global => True);
            Not_Execute : Boolean := True;
         begin
            if (E.Permissions and Arch.Stivale2.PMR_Executable_Mask) /= 0 then
               Not_Execute := False;
            end if;

            if (E.Permissions and Arch.Stivale2.PMR_Writable_Mask) /= 0 then
               Flags.Read_Write := True;
            elsif (E.Permissions and Arch.Stivale2.PMR_Readable_Mask) /= 0 then
               Flags.Read_Write := False;
            end if;

            Map_Range (Kernel_Map, Virt_Addr, Phys_Addr, E.Length,
               Flags, Not_Execute);
         end;
      end loop;

      --  Map the first 2 GiB (except 0) to the window and identity mapped.
      --  This is done instead of following the pagemap to ensure that all
      --  I/O and memory tables that may not be in the memmap are mapped.
      Map_Range (Kernel_Map, Page_Size, Page_Size,
         Hardcoded_Region - Page_Size, Flags, False);
      Map_Range (Kernel_Map, Page_Size + Memory_Offset, Page_Size,
         Hardcoded_Region - Page_Size, Flags, False);

      --  Map the memmap memory (that is not kernel or already mapped)
      --  identity mapped and to the memory window.
      Index := 0;
      for E of Memmap.Entries loop
         if E.EntryType /= Arch.Stivale2.Memmap_Entry_Kernel_And_Modules and
            E.Base + Physical_Address (E.Length) > Hardcoded_Region
         then
            while Size (Index) < E.Length loop
               declare
                  Addr  : constant Virtual_Address := E.Base + Index;
                  KAddr : constant Virtual_Address := Addr + Memory_Offset;
               begin
                  if Addr >= Hardcoded_Region then
                     Map_Page (Kernel_Map, Addr,  Addr, Flags, False);
                     Map_Page (Kernel_Map, KAddr, Addr, Flags, False);
                  end if;
                  Index := Index + Page_Size;
               end;
            end loop;
            Index := 0;
         end if;
      end loop;

      --  Make active.
      Make_Active (Kernel_Map);

      --  Assign the architectural interface map to the actual map.
      MMU.Kernel_Table := MMU.Page_Table (Kernel_Map.all'Address);
   end Init;

   procedure Make_Active (Map : Page_Map_Acc) is
      Addr : constant Unsigned_64 := Unsigned_64 (Physical_Address
         (To_Integer (Map.PML4_Level'Address) - Memory_Offset));
   begin
      --  Make the pagemap active on the callee core by writing the top-level
      --  address to CR3.
      if Arch.Wrappers.Read_CR3 /= Addr then
         Arch.Wrappers.Write_CR3 (Addr);
      end if;
   end Make_Active;

   procedure Map_Page
      (Map         : Page_Map_Acc;
       Virtual     : Virtual_Address;
       Physical    : Physical_Address;
       Flags       : Page_Flags;
       Not_Execute : Boolean)
   is
      Page_Address : constant Virtual_Address := Get_Page (Map, Virtual, True);
      Entry_Body   : Page with Address => To_Address (Page_Address);
   begin
      Entry_Body.Addr  := Chomp_Flags (Physical);
      Entry_Body.Flags := Flags;
      Entry_Body.NX    := Not_Execute;
   end Map_Page;

   procedure Map_Range
      (Map         : Page_Map_Acc;
       Virtual     : Virtual_Address;
       Physical    : Physical_Address;
       Length      : Unsigned_64;
       Flags       : Page_Flags;
       Not_Execute : Boolean)
   is
      PStart : constant Physical_Address := (Physical / Page_Size) * Page_Size;
      VStart : constant Virtual_Address  := (Virtual  / Page_Size) * Page_Size;
      I : Physical_Address := 0;
   begin
      while Unsigned_64 (I) < Length loop
         Map_Page (Map, VStart + I, PStart + I, Flags, Not_Execute);
         I := I + Page_Size;
      end loop;
   end Map_Range;

   procedure Remap_Range
      (Map         : Page_Map_Acc;
       Virtual     : Virtual_Address;
       Length      : Unsigned_64;
       Flags       : Page_Flags;
       Not_Execute : Boolean)
   is
      VStart : constant Virtual_Address  := (Virtual / Page_Size) * Page_Size;
      I      : Physical_Address := 0;
   begin
      while Unsigned_64 (I) < Length loop
         Change_Page_Flags (Map, VStart + I, Flags, Not_Execute);
         I := I + Page_Size;
      end loop;
   end Remap_Range;

   procedure Unmap_Range
      (Map     : Page_Map_Acc;
       Virtual : Virtual_Address;
       Length  : Unsigned_64)
   is
      VStart : constant Virtual_Address  := (Virtual / Page_Size) * Page_Size;
      I      : Physical_Address := 0;
   begin
      while Unsigned_64 (I) < Length loop
         Unmap_Page (Map, VStart + I);
         I := I + Page_Size;
      end loop;
   end Unmap_Range;

   procedure Unmap_Page (Map : Page_Map_Acc; Virtual : Virtual_Address) is
      Map_Loaded   : constant Boolean         := Is_Loaded (Map);
      Page_Address : constant Virtual_Address := Get_Page (Map, Virtual, True);
      Entry_Body   : Page with Address => To_Address (Page_Address);
   begin
      Entry_Body.Flags.Present := False;
      if Map_Loaded then
         Arch.Wrappers.Invalidate_Page (Virtual);
      end if;
   end Unmap_Page;

   procedure Change_Page_Flags
      (Map         : Page_Map_Acc;
       Virtual     : Virtual_Address;
       Flags       : Page_Flags;
       Not_Execute : Boolean)
   is
      Map_Loaded   : constant Boolean         := Is_Loaded (Map);
      Page_Address : constant Virtual_Address := Get_Page (Map, Virtual, True);
      Entry_Body   : Page with Address => To_Address (Page_Address);
   begin
      Entry_Body.Flags := Flags;
      Entry_Body.NX    := Not_Execute;
      if Map_Loaded then
         Arch.Wrappers.Invalidate_Page (Virtual);
      end if;
   end Change_Page_Flags;

   function New_Map return Page_Map_Acc is
      Returned : constant Page_Map_Acc := new Page_Map;
   begin
      --  Copy the higher half mappings from the kernel map.
      for I in 256 .. 512 loop
         Returned.PML4_Level (I) := Kernel_Map.PML4_Level (I);
      end loop;
      return Returned;
   end New_Map;

   function Is_Loaded (Map : Page_Map_Acc) return Boolean is
      Current : constant Unsigned_64 := Arch.Wrappers.Read_CR3;
      PAddr : constant Integer_Address := To_Integer (Map.PML4_Level'Address);
   begin
      return Current = Unsigned_64 (PAddr - Memory_Offset);
   end Is_Loaded;

   function Virtual_To_Physical
      (Map     : Page_Map_Acc;
       Virtual : Virtual_Address) return Physical_Address
   is
      Result : Physical_Address;
   begin
      declare
         Addr     : constant Virtual_Address := Get_Page (Map, Virtual, False);
         Searched : Page with Address => To_Address (Addr);
      begin
         Result := Searched.Addr;
      end;
      return Result;
   end Virtual_To_Physical;

   function Get_Address_Components
      (Virtual : Virtual_Address) return Address_Components is
      Addr   : constant Unsigned_64 := Unsigned_64 (Virtual);
      PML4_E : constant Unsigned_64 := Addr and Shift_Left (16#1FF#, 39);
      PML3_E : constant Unsigned_64 := Addr and Shift_Left (16#1FF#, 30);
      PML2_E : constant Unsigned_64 := Addr and Shift_Left (16#1FF#, 21);
      PML1_E : constant Unsigned_64 := Addr and Shift_Left (16#1FF#, 12);
   begin
      return (PML4_Entry => Shift_Right (PML4_E, 39),
              PML3_Entry => Shift_Right (PML3_E, 30),
              PML2_Entry => Shift_Right (PML2_E, 21),
              PML1_Entry => Shift_Right (PML1_E, 12));
   end Get_Address_Components;

   function Get_Next_Level
      (Current_Level       : Physical_Address;
       Index               : Unsigned_64;
       Create_If_Not_Found : Boolean) return Physical_Address is
      Entry_Addr : constant Virtual_Address :=
         Current_Level + Memory_Offset + Physical_Address (Index * 8);
      Entry_Body : Page_Table_Entry with Address => To_Address (Entry_Addr);
   begin
      if Entry_Body.Flags.Present then
         return Add_Flags (Entry_Body.Addr);
      elsif Create_If_Not_Found then
         --  Allocate and put some default flags.
         declare
            type PML4_Acc is access PML4;
            New_Entry      : constant PML4_Acc := new PML4;
            New_Entry_Addr : constant Physical_Address :=
               To_Integer (New_Entry.all'Address) - Memory_Offset;
         begin
            Entry_Body.Addr := Chomp_Flags (New_Entry_Addr);
            Entry_Body.Flags.Present    := True;
            Entry_Body.Flags.Read_Write := True;
            Entry_Body.Flags.User_Supervisor := True;
            return New_Entry_Addr;
         end;
      end if;
      return Null_Address;
   end Get_Next_Level;

   function Get_Page
      (Map      : Page_Map_Acc;
       Virtual  : Virtual_Address;
       Allocate : Boolean) return Virtual_Address is
      Addr  : constant Address_Components := Get_Address_Components (Virtual);
      Addr4 : constant Physical_Address :=
         To_Integer (Map.PML4_Level'Address) - Memory_Offset;
      Addr3 : Physical_Address := Null_Address;
      Addr2 : Physical_Address := Null_Address;
      Addr1 : Physical_Address := Null_Address;
   begin
      --  Find the entries.
      Addr3 := Get_Next_Level (Addr4, Addr.PML4_Entry, Allocate);
      if Addr3 = Null_Address then
         goto Error_Return;
      end if;
      Addr2 := Get_Next_Level (Addr3, Addr.PML3_Entry, Allocate);
      if Addr2 = Null_Address then
         goto Error_Return;
      end if;
      Addr1 := Get_Next_Level (Addr2, Addr.PML2_Entry, Allocate);
      if Addr1 = Null_Address then
         goto Error_Return;
      end if;

      return Addr1 + Memory_Offset + (Physical_Address (Addr.PML1_Entry) * 8);

   <<Error_Return>>
      Lib.Panic.Soft_Panic ("Address could not be found");
      return Null_Address;
   end Get_Page;

   function Chomp_Flags (Address : Physical_Address) return Physical_Address is
      Addr_Int : constant Unsigned_64 := Unsigned_64 (Address);
   begin
      return Physical_Address (Shift_Right (Addr_Int, 12));
   end Chomp_Flags;

   function Add_Flags (Address : Physical_Address) return Physical_Address is
      Addr_Int : constant Unsigned_64 := Unsigned_64 (Address);
   begin
      return Physical_Address (Shift_Left (Addr_Int, 12));
   end Add_Flags;
end Arch.Paging;