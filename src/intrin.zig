// Copyright (C) 2024 Drew P.
// This file is part of picoatxt.
//
// picoatxt is free software: you can redistribute it and/or modify it under the terms of the
// GNU General Public License as published by the Free Software Foundation, either
// version 3 of the License, or (at your option) any later version.
//
// picoatxt is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
// without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
// See the GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along with picoatxt.
// If not, see <https://www.gnu.org/licenses/>.
pub inline fn cpsidi() void {
    asm volatile ("CPSID i" ::: "memory");
}

pub inline fn cpsiei() void {
    asm volatile ("CPSIE i" ::: "memory");
}

pub inline fn wfi() void {
    asm volatile ("WFI" ::: "memory");
}

///nop
pub inline fn nop() void {
    asm volatile ("nop");
}
