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
const CrossTarget = std.zig.CrossTarget;

pub fn build(b: *std.Build) void {
    const no_strip = b.option(bool, "no-strip", "If true, do not strip debug symbols (default false)") orelse false;
    const obj = b.addObject(.{
        .name = "picoatxt_zig",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .thumb,
            .os_tag = .freestanding,
            .cpu_model = CrossTarget.CpuModel{ .explicit = &std.Target.arm.cpu.cortex_m0plus },
            .abi = .eabi,
        }),
        .optimize = b.standardOptimizeOption(.{}),
        .strip = !no_strip,
    });

    // Zig doesn't include any arm-none-eabi libc, so manually include from the GCC toolchain's sysroot.
    if (b.sysroot) |sysroot| {
        obj.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "include" }) });
    }

    // -ffunction-sections
    obj.link_function_sections = true;

    const include_dirs_opt = b.option([]const []const u8, "include-dirs", "List of CC flags for including directories");
    const defs_opt = b.option([]const []const u8, "defs", "List of CC flags for preprocessor definitions");

    if (include_dirs_opt) |include_dirs| {
        for (include_dirs) |dir| {
            // Assume they just gave us the path
            obj.addIncludePath(.{ .cwd_relative = dir });
        }
    }

    if (defs_opt) |defs| {
        for (defs) |def| {
            // Assume general format <name> or <name>=<val>
            const name_str = blk: {
                for (def, 0..) |char, i| {
                    if (char == '=') {
                        break :blk def[0..i];
                    }
                }

                break :blk def;
            };

            const val_str = if (def.len != name_str.len) blk: {
                break :blk def[name_str.len + 1 ..];
            } else null;

            obj.defineCMacro(name_str, val_str);
        }
    }

    obj.root_module.sanitize_c = false;
    obj.root_module.red_zone = false;

    b.getInstallStep().dependOn(&b.addInstallArtifact(obj, .{ .dest_dir = .{ .override = .{ .custom = "out" } } }).step);
}
