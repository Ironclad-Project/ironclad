--  userland-mac.ads: Mandatory access control.
--  Copyright (C) 2023 streaksu
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

with Ada.Characters.Latin_1;

package Userland.MAC is
   --  MAC (Mandatory Access Control) is configured by a bitmap of some
   --  broad permissions, called capabilities (not to be confused with Linux).
   type Capabilities is record
      Can_Change_Scheduling : Boolean;
      Can_Spawn_Others      : Boolean;
      Can_Access_Entropy    : Boolean;
      Can_Modify_Memory     : Boolean;
      Can_Use_Networking    : Boolean;
      Can_Manage_Networking : Boolean;
      Can_Manage_Mounts     : Boolean;
      Can_Manage_Power      : Boolean;
      Can_Trace_Children    : Boolean;
      Can_Change_UIDs       : Boolean;
   end record;

   --  Permissions a filter can give.
   type Filter_Permissions is record
      Includes_Contents : Boolean; --  Affects contained files&directories.
      Deny_Instead      : Boolean; --  Instead of allow whats passed, deny it.
      Can_Read          : Boolean; --  Read permissions.
      Can_Write         : Boolean; --  Write permissions.
      Can_Execute       : Boolean; --  Execute permissions.
      Can_Append_Only   : Boolean; --  Can append only, conflicts with write.
      Can_Lock_Files    : Boolean; --  Can lock the affected files.
   end record;

   --  Filter, that has a string used as absolute path and permissions.
   Filter_Path_Length : constant := 75;
   type Filter is record
      Path   : String (1 .. Filter_Path_Length);
      Length : Natural range 0 .. 75;
      Perms  : Filter_Permissions;
   end record;

   --  An array of filters is just a list of filters.
   --  If several rules cover the same directory, the more restrictive one
   --  is used.
   type Filter_Arr is array (Natural range <>) of Filter;

   --  Structure to pack together the MAC permissions of a process.
   type Enforcement is (Deny, Deny_And_Scream, Kill);
   type Permissions is record
      Action  : Enforcement;
      Caps    : Capabilities;
      Filters : Filter_Arr (1 .. 30);
   end record;

   --  Default permissions are all, and the user deescalates from there.
   Default_Permissions : constant Permissions :=
      (Action  => Deny,
       Caps    => (others => True),
       Filters => (1 =>
         (Path   => (1 => '/', others => Ada.Characters.Latin_1.NUL),
          Length => 1,
          Perms  => (others => True)),
                   others =>
         (Path   => (others => Ada.Characters.Latin_1.NUL),
          Length => 0,
          Perms  => (others => False))));

   --  Check whether the passed filter conflicts with any on the list.
   --  That means, it offers another set of permissions for an already
   --  defined path (taking into account specifying permissions inside a dir).
   function Is_Conflicting (F : Filter; Filters : Filter_Arr) return Boolean;

   --  Check the permissions a path can be accessed with, it has to be an
   --  absolute path.
   function Check_Path_Permissions
      (Path    : String;
       Filters : Filter_Arr) return Filter_Permissions
   with Pre => (Path'First <= Integer'Last - 75);
end Userland.MAC;
