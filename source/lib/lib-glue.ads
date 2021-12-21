--  lib-glue.ads: Specification of the glue functions.
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

with System;

--  This are glue functions generated by the compiler that we must fill.
--  Most of them are for error-reporting, and the names are preset.

package Lib.Glue is
   procedure Access_Check (File : System.Address; Line : Integer);
   pragma Export (C, Access_Check, "__gnat_rcheck_CE_Access_Check");

   procedure Range_Check (File : System.Address; Line : Integer);
   pragma Export (C, Range_Check, "__gnat_rcheck_CE_Range_Check");

   procedure Accessib_Check (File : System.Address; Line : Integer);
   pragma Export (C, Accessib_Check, "__gnat_rcheck_PE_Accessibility_Check");

   procedure Overflow_Check (File : System.Address; Line : Integer);
   pragma Export (C, Overflow_Check, "__gnat_rcheck_CE_Overflow_Check");
end Lib.Glue;
