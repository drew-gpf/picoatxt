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
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "zig_runner",
        .root_source_file = .{ .path = "zig_runner.zig" },
        .target = target,
        .optimize = mode,
    });

    b.installArtifact(exe);
}