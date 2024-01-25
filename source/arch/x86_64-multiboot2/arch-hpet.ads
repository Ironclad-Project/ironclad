--  arch-hpet.ads: Specification of the HPET driver.
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

package Arch.HPET is
   --  True if initialized.
   Is_Initialized : Boolean;

   --  Initialize the HPET, if found.
   procedure Init;

   --  Loop for the passed microseconds.
   procedure USleep (Microseconds : Positive);

   --  Do the same for nanoseconds.
   procedure NSleep (Nanoseconds : Positive);
end Arch.HPET;
