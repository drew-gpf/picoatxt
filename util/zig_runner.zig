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
pub fn main() !u8 {
    // We're given as args a GCC command line and we must interpret them
    // and give them to the main build script.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const args = try std.process.argsAlloc(allocator);

    if (comptime @import("builtin").os.tag == .windows) {
        // ChildProcess stopped being able to parse short paths which GCC loves to use,
        // so ask windows to resolve it and use that path instead
        const copy = try std.unicode.utf8ToUtf16LeWithNull(allocator, try std.mem.concat(allocator, u8, &.{ "\\\\?\\", args[1] }));
        const required_len = GetLongPathNameW(copy, copy, @as(u32, @intCast(copy.len)));

        if (required_len > copy.len) {
            const new_buf = try allocator.allocSentinel(u16, required_len - 1, 0);
            std.debug.assert(required_len == new_buf.len + 1);

            if (GetLongPathNameW(copy, new_buf, required_len) != (required_len - 1)) return error.FailedToGetLongPath;
            args[1] = try std.unicode.utf16leToUtf8AllocZ(allocator, new_buf[4..]);
        } else {
            args[1] = try std.unicode.utf16leToUtf8AllocZ(allocator, copy[4..]);
        }
    }

    // Check the last arg; it should end with cmake_dummy.c (case insensitive).
    // If it does we want to invoke zig build with the given args.
    // In either case we will build the object file verbaitim as we're subverting all C compilation.
    if (std.ascii.endsWithIgnoreCase(args[args.len - 1], "cmake_dummy.c")) {
        var build_args = std.ArrayList([]const u8).init(allocator);

        try build_args.append("zig");
        try build_args.append("build");

        // The way we're executed in the build script we know the path of the zig_runner executable,
        // util/zig-out/bin, which is always an absolute path. We want to go back by 3.
        const project_root = try std.fs.path.resolve(allocator, &[_][]const u8{
            std.fs.path.dirname(args[0]) orelse unreachable, // util/zig-out/bin
            "..", // util/zig-out
            "..", // util
            "..", // <root>
        });

        // We know the C compiler, but we need to use its libc since zig does not come with
        // the arm-none-eabi libc.
        {
            var child = std.ChildProcess.init(&[_][]const u8{ args[1], "-print-sysroot" }, allocator);

            child.stderr_behavior = .Close;
            child.stdin_behavior = .Close;
            child.stdout_behavior = .Pipe;
            child.expand_arg0 = .expand;

            try child.spawn();
            errdefer _ = child.kill() catch {};

            const stdout_reader = child.stdout.?.reader();
            const sysroot = (try stdout_reader.readUntilDelimiterOrEofAlloc(allocator, 0, std.math.maxInt(usize))).?;
            const sysroot_len = for (sysroot, 0..) |char, i| {
                if (char == '\r' or char == '\n') break i;
            } else sysroot.len;

            try build_args.append("--sysroot");
            try build_args.append(sysroot[0..sysroot_len]);

            _ = try child.wait();
        }

        var zig_opt: ?[]const u8 = "-Doptimize=ReleaseFast";

        for (args) |arg| {
            // CMake plays nicely here and we can just assume that include directories look like
            // -I<path> and preprocessor defines look like -D<name> or -D<name>=<val>
            // We specify multiple values by just specifying the arg given to zig build for each arg type.
            // We also want to look for the CMake release type so it can be specified.
            if (arg.len > 2) {
                if (std.mem.startsWith(u8, arg, "-I")) {
                    try build_args.append(try std.fmt.allocPrint(allocator, "-Dinclude-dirs={s}", .{arg[2..]}));
                } else if (std.mem.startsWith(u8, arg, "-D")) {
                    const def = arg[2..];
                    const cmake_build_type_str = "PICO_CMAKE_BUILD_TYPE";

                    // PICO_CMAKE_BUILD_TYPE incidentally contains the CMake build type so we can specify it here.
                    if (std.mem.startsWith(u8, def, cmake_build_type_str)) {
                        // Skip the =" sequence following PICO_CMAKE_BUILD_TYPE
                        const build_type_base = def[cmake_build_type_str.len + 2 ..];
                        const build_type_str = build_type_base[0 .. build_type_base.len - 1];

                        // Debug -> null
                        // Release -> -Drelease-fast
                        // RelWithDebInfo -> -Drelease-safe (debug symbols are stripped by elf2uf2)
                        // MinSizeRel -> -Drelease-small
                        if (std.mem.eql(u8, build_type_str, "Debug")) {
                            zig_opt = null;
                            try build_args.append("-Dno-strip");
                        } else if (std.mem.eql(u8, build_type_str, "Release")) {
                            zig_opt = "-Doptimize=ReleaseFast";
                        } else if (std.mem.eql(u8, build_type_str, "RelWithDebInfo")) {
                            zig_opt = "-Doptimize=ReleaseSafe";
                            try build_args.append("-Dno-strip");
                        } else if (std.mem.eql(u8, build_type_str, "MinSizeRel")) {
                            zig_opt = "-Doptimize=ReleaseSmall";
                        } else unreachable;
                    }

                    try build_args.append(try std.fmt.allocPrint(allocator, "-Ddefs={s}", .{def}));
                }
            }
        }

        if (zig_opt) |zig_opt_unwr| {
            try build_args.append(zig_opt_unwr);
        }

        var child = std.ChildProcess.init(build_args.items, allocator);
        child.cwd = project_root;
        child.expand_arg0 = .expand;

        switch (try child.spawnAndWait()) {
            .Exited => |val| {
                if (val != 0) return val;
            },
            .Signal => return error.Signal,
            .Stopped => return error.Stopped,
            .Unknown => return error.Unknown,
        }
    }

    // Compile object files unconditionally. This is made extremely easy by the fact that
    // the compiler is given in the command line.
    var child = std.ChildProcess.init(args[1..], allocator);
    child.expand_arg0 = .expand;

    return switch (try child.spawnAndWait()) {
        .Exited => |val| val,
        .Signal => error.Signal,
        .Stopped => error.Stopped,
        .Unknown => error.Unknown,
    };
}

extern "kernel32" fn GetLongPathNameW(
    short_path: [*:0]const u16,
    long_path: [*:0]u16,
    buf_len: std.os.windows.DWORD,
) std.os.windows.DWORD;
