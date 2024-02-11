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
const logger = @import("logger.zig");
const intrin = @import("intrin.zig");
const c = @import("sdk.zig");
const atxt = @import("atxt.zig");
const scancodes = @import("scancodes.zig");

pub const std_options: std.Options = .{
    .logFn = log,

    // Uncomment or change to enable logs for any build mode
    // .log_level = .debug;
};

/// stdlib log handler; no logging is done if stdio is disabled.
fn log(comptime level: std.log.Level, comptime scope: @TypeOf(.EnumLiteral), comptime format: []const u8, args: anytype) void {
    if (!logger.stdio_enabled) return;
    _ = scope;

    const prefix = "[" ++ @tagName(level) ++ "]: ";
    if (level == .err) {
        // If we are reporting an error, flash the LED and spew it to stdout forever
        // because it's really annoying to get output within the first 5 seconds
        // of powering the device.
        var toggle: bool = true;

        c.gpio_init(c.PICO_DEFAULT_LED_PIN);
        c.gpio_set_dir(c.PICO_DEFAULT_LED_PIN, true);

        while (true) {
            c.gpio_put(c.PICO_DEFAULT_LED_PIN, toggle);
            logger.log(prefix ++ format ++ "\n", args) catch {};
            c.sleep_ms(1000);

            toggle = !toggle;
            std.atomic.spinLoopHint();
        }
    } else {
        logger.log(prefix ++ format ++ "\n", args) catch {};
    }
}

pub fn panic(_: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    intrin.cpsidi();
    c.gpio_init(c.PICO_DEFAULT_LED_PIN);
    c.gpio_set_dir(c.PICO_DEFAULT_LED_PIN, true);
    c.gpio_put(c.PICO_DEFAULT_LED_PIN, true);

    while (true) {
        intrin.wfi();
    }
}

/// Last state of USB leds
var last_leds: packed struct(u8) {
    num_lock: u1,
    caps_lock: u1,
    scroll_lock: u1,
    compose: u1,
    kana: u1,
    reserved: u3,
} = undefined;

/// Whether or not to change the state of the lock lights
var change_leds: bool = false;

/// Key bitmap
var keys: [22]u8 = undefined;

/// Indicates completed scancode is a break code (AT only)
var is_break: bool = undefined;

/// Current scancode table selected by protocol
var scancode_table: []const []const scancodes.Scancode = undefined;

/// Current scancode table selected by shift state
var scancode_sel: []const scancodes.Scancode = undefined;

/// Number of USB packets to send a pressed PAUSE key
var pause_tick: usize = undefined;

/// Whether or not to reboot to bootsel mode
var reboot_to_bootsel: bool = undefined;

/// Whether or not the host wants us to send boot reports or descriptor reports
var boot_report: bool = undefined;

/// Whether or not this is a "duplicate" report
var duplicate_report: bool = undefined;

/// Whether or not to inhibit "duplicate" reports
var inhibit_duplicates: bool = undefined;

/// 32ms pause duration (note that we subtract and then compare each USB packet)
const pause_tick_default = 32 + 1;

inline fn handleData(data: u8) void {
    switch (scancode_sel[data]) {
        .none => clearShift(),
        .overrun => {
            // Don't set the overrun bit. I don't exactly know how it should work here,
            // since there's no good way to know when to clear it.
            @memset(keys[0..], 0);
            duplicate_report = false;
            clearShift();
        },
        .break_next => is_break = true,
        .extended => shiftTable(switch (data) {
            0xE0 => .extended,
            0xE1 => .pause,
            else => .pause_next,
        }),

        .break_code => toggleKey(@intFromEnum(scancode_sel[@as(u7, @truncate(data))]), false),
        _ => |usb_scancode| toggleKey(@intFromEnum(usb_scancode), !is_break),
    }
}

inline fn toggleKey(usb_scancode: u8, make: bool) void {
    var has_macro: bool = true;
    const new_scancode = getMacroMapping(usb_scancode, false) orelse blk: {
        has_macro = false;
        break :blk usb_scancode;
    };

    setBitmap(new_scancode, make);

    if (has_macro) {
        const macro_key = getMacroMapping(usb_scancode, true).?;

        // If this key has a macro mapping and we're making/breaking this key
        // we always need to break the opposite key.
        const opposite_key = if (usb_scancode == new_scancode) macro_key else usb_scancode;
        setBitmap(opposite_key, false);
    }

    clearShift();
}

/// Get the scancode that a given key maps to, or null if none exist
/// If the retval is equal to usb_scancode then the scancode can have a macro but the layer
/// is not enabled right now. If enable_layer is true, this will always return the macro mapping.
inline fn getMacroMapping(usb_scancode: u8, enable_layer: bool) ?u8 {
    return @as(u8, @intCast(switch (usb_scancode) {
        // Change layer if scroll lock is enabled
        c.HID_KEY_F9,
        c.HID_KEY_F10,
        => blk: {
            if (last_leds.scroll_lock != 0 or enable_layer) {
                break :blk usb_scancode + 2;
            }

            break :blk usb_scancode;
        },

        // Change layer if num lock is disabled
        c.HID_KEY_KEYPAD_1,
        c.HID_KEY_KEYPAD_2,
        c.HID_KEY_KEYPAD_3,
        c.HID_KEY_KEYPAD_4,
        c.HID_KEY_KEYPAD_5,
        c.HID_KEY_KEYPAD_6,
        c.HID_KEY_KEYPAD_7,
        c.HID_KEY_KEYPAD_8,
        c.HID_KEY_KEYPAD_9,
        c.HID_KEY_KEYPAD_0,
        c.HID_KEY_KEYPAD_DECIMAL,
        => blk: {
            if (last_leds.num_lock != 0 and !enable_layer) {
                break :blk usb_scancode;
            }

            break :blk switch (usb_scancode) {
                c.HID_KEY_KEYPAD_1 => c.HID_KEY_END,
                c.HID_KEY_KEYPAD_2 => c.HID_KEY_ARROW_DOWN,
                c.HID_KEY_KEYPAD_3 => c.HID_KEY_PAGE_DOWN,
                c.HID_KEY_KEYPAD_4 => c.HID_KEY_ARROW_LEFT,
                c.HID_KEY_KEYPAD_5 => c.HID_KEY_ARROW_DOWN,
                c.HID_KEY_KEYPAD_6 => c.HID_KEY_ARROW_RIGHT,
                c.HID_KEY_KEYPAD_7 => c.HID_KEY_HOME,
                c.HID_KEY_KEYPAD_8 => c.HID_KEY_ARROW_UP,
                c.HID_KEY_KEYPAD_9 => c.HID_KEY_PAGE_UP,
                c.HID_KEY_KEYPAD_0 => c.HID_KEY_INSERT,
                c.HID_KEY_KEYPAD_DECIMAL => c.HID_KEY_DELETE,

                else => unreachable,
            };
        },

        else => return null,
    }));
}

/// Get whether or not a key is being pressed from its USB scancode
inline fn isKeyPressed(usb_scancode: u8) bool {
    if (usb_scancode < c.HID_KEY_CONTROL_LEFT) {
        return (keys[(usb_scancode - c.MIN_KEY) / 8] & (@as(u8, 1) << @as(u3, @truncate(usb_scancode - c.MIN_KEY)))) != 0;
    } else {
        return (keys[21] & (@as(u8, 1) << @as(u3, @truncate(usb_scancode)))) != 0;
    }
}

inline fn setBitmap(usb_scancode: u8, make: bool) void {
    var byte_write: *u8 = undefined;
    var which_bit: u3 = undefined;

    if (usb_scancode < c.HID_KEY_CONTROL_LEFT) {
        byte_write = &keys[(usb_scancode - c.MIN_KEY) / 8];
        which_bit = @as(u3, @truncate(usb_scancode - c.MIN_KEY));
    } else {
        // (0xE0 is a multiple of 8 so we just need the lower 3 bits)
        byte_write = &keys[21];
        which_bit = @as(u3, @truncate(usb_scancode));
    }

    if (usb_scancode == c.HID_KEY_PAUSE) {
        if (!make) return;
        pause_tick = pause_tick_default;
    }

    const was_set = (byte_write.* & (@as(u8, 1) << which_bit)) != 0;
    if (was_set != make) duplicate_report = false else return;

    if (make) {
        byte_write.* |= @as(u8, 1) << which_bit;
    } else {
        byte_write.* &= ~(@as(u8, 1) << which_bit);
    }
}

inline fn shiftTable(new: scancodes.ShiftState) void {
    scancode_sel = scancode_table[@intFromEnum(new)];
}

/// Called on keyboard reset
fn onReset() void {
    change_leds = last_leds.caps_lock != 0 or last_leds.num_lock != 0 or last_leds.scroll_lock != 0;

    // After a reset, the keyboard will also clear its character buffer so we should reorient ourselves
    pause_tick = 0;
    duplicate_report = false;
    @memset(keys[0..], 0);

    clearShift();
}

/// Call to clear temporary shift states when resending a packet
inline fn clearShift() void {
    shiftTable(.normal);
    is_break = false;
}

fn mainWrap() !void {
    last_leds = @as(@TypeOf(last_leds), @bitCast(@as(u8, 0)));
    @memset(keys[0..], 0);
    change_leds = false;
    is_break = false;
    pause_tick = 0;
    reboot_to_bootsel = false;
    boot_report = false;
    duplicate_report = false;
    inhibit_duplicates = false;

    const protocol = try atxt.init();
    if (!c.tusb_init()) return error.FailedToInitTusb;

    scancode_table = switch (protocol) {
        .xt => scancodes.xt_tables[0..],
        .at => scancodes.at_tables[0..],
    };

    shiftTable(.normal);

    // If true, treat incoming data as a BAT status (AT only)
    var waiting_for_bat: bool = false;

    // Next command to be queued if command is to be sent from the result of a data packet
    // It is always safe to mutate next_command if the packet's last_command is not null because
    // only one last_command can be present at a given moment in the ring buffer
    // as long as IRQs are continuously disabled while clearing it.
    // (This is because, if there is a defined last packet, new commands will cause line contention errors;
    // furthermore, only the top packet will be associated with the last command, with subsequent packets
    // being normal keyboard data packets received while IRQs were still enabled.)
    var next_command: ?u8 = null;
    var last_time_us: u64 = 0;

    intrin.cpsidi();

    // Start a timer that fires every millisecond so we can send keypresses
    c.hardware_alarm_claim(usb_timer);
    c.hardware_alarm_set_callback(usb_timer, usbTimerExpire);
    if (!startUsbTimer()) @panic("Failed to start USB timer");

    while (true) {
        const packet_opt = atxt.getPacket();
        if (packet_opt) |packet| {
            if (packet.data) |data| {
                // byte received
                if (packet.last_command) |cmd| {
                    // reset should be 0xAA
                    // most commands should be ACK (0xFA)
                    // echo is echo
                    // if data is resend (0xFE) we resend last command
                    // note that sometimes the keyboard will send us 0xFC if it doesnt recognize the command
                    if (data == @intFromEnum(atxt.Command.resend)) {
                        next_command = cmd;
                    } else {
                        switch (cmd) {
                            @intFromEnum(atxt.Command.reset) => {
                                if (protocol == .at) {
                                    waiting_for_bat = true;
                                } else {
                                    if (data != 0xAA) {
                                        next_command = cmd;
                                    } else {
                                        onReset();
                                    }
                                }
                            },

                            @intFromEnum(atxt.Command.resend) => {
                                // handle packet normally
                                handleData(data);
                            },

                            @intFromEnum(atxt.Command.disable_scanning),
                            @intFromEnum(atxt.Command.enable_scanning),
                            @intFromEnum(atxt.Command.reset_changes),
                            @intFromEnum(atxt.Command.echo),
                            @intFromEnum(atxt.Command.set_delay),
                            => {},

                            @intFromEnum(atxt.Command.set_locklights) => {
                                // Next, send lock light toggle packet.
                                // Note that this is effectively guaranteed to work because
                                // the keyboard must disable scanning until we send this byte.
                                // In case it doesn't, we only clear led_toggle if the
                                // associated command sends an ACK,
                                // so an overwritten command sequence will just try again.
                                // (invalid commands, like all forms of next_command, send a 0xFC byte)
                                // Finally, we won't try to toggle lock lights separately until contention is resolved
                                // by us receiving the ACK response packet.
                                next_command = @as(u8, @bitCast(atxt.LockLightStatus{
                                    .scroll_lock = last_leds.scroll_lock,
                                    .num_lock = last_leds.num_lock,
                                    .caps_lock = last_leds.caps_lock,
                                    .reserved = 0,
                                }));
                            },

                            else => {
                                // It is only possible for an unrecognized command that we send to be the lock-light status.
                                if (cmd & 0x80 == 0) {
                                    if (data == 0xFA) {
                                        change_leds = false;
                                    }
                                }
                            },
                        }
                    }
                } else {
                    if (waiting_for_bat) {
                        waiting_for_bat = false;
                        if (data != 0xAA) {
                            next_command = @intFromEnum(atxt.Command.reset);
                        } else {
                            onReset();
                        }
                    } else {
                        // handle packet normally
                        handleData(data);
                    }
                }
            } else {
                // (latest) byte received but invalid, or we ran out of space in the ring buffer.
                // At this point, clk and data are forced low; line contention, for example, is impossible.
                if (packet.last_command) |cmd| {
                    atxt.sendAtCommand(cmd) catch |e| switch (e) {
                        error.AtXt => {
                            if (cmd == @intFromEnum(atxt.Command.reset)) {
                                atxt.sendCommand(.reset) catch |e2| switch (e2) {
                                    error.AtXt,
                                    error.Clocking,
                                    error.RingBufferNotEmpty,
                                    error.Contention,
                                    => unreachable,
                                };
                            } else unreachable;
                        },

                        error.Clocking,
                        error.RingBufferNotEmpty,
                        error.Contention,
                        => unreachable,
                    };
                } else {
                    if (waiting_for_bat) {
                        waiting_for_bat = false;
                        atxt.sendCommand(.reset) catch |e| switch (e) {
                            error.AtXt,
                            error.Clocking,
                            error.RingBufferNotEmpty,
                            error.Contention,
                            => unreachable,
                        };
                    } else {
                        atxt.sendCommand(.resend) catch |e| switch (e) {
                            error.AtXt => {
                                // XT keyboard, send reset instead
                                atxt.sendCommand(.reset) catch |e2| switch (e2) {
                                    error.AtXt,
                                    error.Clocking,
                                    error.RingBufferNotEmpty,
                                    error.Contention,
                                    => unreachable,
                                };
                            },

                            error.Clocking,
                            error.RingBufferNotEmpty,
                            error.Contention,
                            => unreachable,
                        };
                    }
                }
            }
        } else {
            if (next_command) |cmd| {
                next_command = null;
                atxt.sendAtCommand(cmd) catch |e| switch (e) {
                    error.AtXt => {
                        if (cmd == @intFromEnum(atxt.Command.reset)) {
                            atxt.sendCommand(.reset) catch |e2| switch (e2) {
                                error.AtXt,
                                error.RingBufferNotEmpty,
                                => unreachable,

                                error.Clocking,
                                error.Contention,
                                => next_command = cmd,
                            };
                        } else unreachable;
                    },

                    error.RingBufferNotEmpty => unreachable,

                    error.Clocking,
                    error.Contention,
                    => next_command = cmd,
                };
            } else {
                // Try update board LEDs
                if (change_leds) {
                    atxt.sendCommand(.set_locklights) catch |e| switch (e) {
                        error.AtXt => change_leds = false,
                        error.RingBufferNotEmpty => unreachable,

                        error.Clocking,
                        error.Contention,
                        => {}, // try again later
                    };
                }
            }

            // no byte, wait for event
            intrin.wfi();
            intrin.cpsiei();
            c.tud_task();

            // handle polling (1ms)
            const current_time_us = c.time_us_64();
            if ((current_time_us -% last_time_us) >= 1000) {
                last_time_us = current_time_us;

                if (c.tud_hid_ready()) {
                    if (reboot_to_bootsel) {
                        // We've sent a packet saying no keys are being pressed, so reboot.
                        _ = c.tud_disconnect();
                        c.reset_usb_boot(0, 0);
                        intrin.cpsidi();

                        while (true) {
                            intrin.wfi();
                        }
                    }

                    if (isKeyPressed(c.HID_KEY_SCROLL_LOCK) and isKeyPressed(c.HID_KEY_KEYPAD_SUBTRACT) and isKeyPressed(c.HID_KEY_SHIFT_RIGHT)) {
                        reboot_to_bootsel = true;
                        pause_tick = 0;
                        duplicate_report = false;
                        @memset(keys[0..], 0);
                    } else {
                        if (pause_tick > 0) {
                            pause_tick -= 1;
                            if (pause_tick == 0) {
                                const actual_scancode = @as(comptime_int, c.HID_KEY_PAUSE - c.MIN_KEY);
                                keys[actual_scancode / 8] &= ~(@as(u8, 1) << @as(u3, @truncate(actual_scancode)));
                                duplicate_report = false;
                            }
                        }
                    }

                    // Our duplicate detection is technically flawed if the boot report descriptor is used
                    // because we might not be able to report the new keypress but will still send
                    // a "redundant" packet. We also always send a packet if clearing the keys bitfield
                    // even if no key was actually unset.
                    if (!duplicate_report or !inhibit_duplicates) {
                        if (boot_report) {
                            const buf = buildBootDescriptor();
                            _ = c.tud_hid_report(0, &buf[0], buf.len);
                        } else {
                            _ = c.tud_hid_report(0, &keys[0], keys.len);
                        }
                    }

                    duplicate_report = true;
                }

                // Reset polling interrupt
                intrin.cpsidi();
                if (!startUsbTimer()) @panic("Failed to reset USB polling IRQ");
            } else {
                intrin.cpsidi();
            }
        }
    }
}

fn buildBootDescriptor() [8]u8 {
    var ret: [8]u8 = undefined;
    ret[0] = keys[21]; // modifiers
    @memset(ret[1..], 0);

    var ret_idx: usize = 2;
    outer: for (keys[0..21], 0..) |byte, i| {
        const scancode_base: u8 = @intCast(c.MIN_KEY + (i * 8));
        var byte_shift = byte;
        var idx: u3 = 0;

        while (byte_shift != 0) : ({
            idx += 1;
            byte_shift >>= 1;
        }) {
            if (byte_shift & 1 != 0) {
                const scancode = scancode_base + idx;
                if (scancode == 1) {
                    // Overrun. This branch currently isn't used since we can't
                    // reliably figure out when to clear this scancode.
                    @memset(ret[2..], scancode);
                    break :outer;
                } else {
                    // Set scancode and exit if full, assume first iteration
                    // is not full.
                    ret[ret_idx] = scancode;
                    ret_idx += 1;
                    if (ret_idx >= ret.len) {
                        std.debug.assert(ret_idx == ret.len);
                        break :outer;
                    }
                }
            }
        }
    }

    return ret;
}

const usb_timer = 2;

fn usbTimerExpire(_: c.uint) callconv(.C) void {}
fn startUsbTimer() bool {
    const duration_us = 1000;

    var next_absolute_time: c.absolute_time_t = undefined;
    c.update_us_since_boot(&next_absolute_time, c.time_us_64() + duration_us);

    return c.hardware_alarm_set_target(usb_timer, next_absolute_time) == false;
}

export fn tud_hid_set_protocol_cb(instance: u8, protocol: u8) void {
    _ = instance;
    boot_report = protocol == c.HID_PROTOCOL_BOOT;
}

export fn tud_hid_set_idle_cb(instance: u8, idle_rate: u8) bool {
    _ = instance;

    // Technically, we can send as many reports as we want as long as the idle rate is nonzero
    inhibit_duplicates = idle_rate == 0;

    return true;
}

/// Receive a report through the control pipe (must be supported by USB boot keyboards)
export fn tud_hid_get_report_cb(instance: u8, report_id: u8, report_type: c.hid_report_type_t, buffer: [*]u8, size: u16) u16 {
    _ = instance;
    _ = report_id;
    const buf = buffer[0..size];

    if (report_type == c.HID_REPORT_TYPE_INPUT) {
        if (boot_report) {
            if (buf.len >= 8) {
                @memcpy(buf[0..8], buildBootDescriptor()[0..]);
                return 8;
            }
        } else {
            if (buf.len >= keys.len) {
                @memcpy(buf[0..keys.len], keys[0..]);
                return keys.len;
            }
        }
    }

    // Invalid request
    return 0;
}

/// Receive an output report like lock light settings
export fn tud_hid_set_report_cb(instance: u8, report_id: u8, report_type: c.hid_report_type_t, buffer: [*]const u8, size: u16) void {
    _ = instance;
    _ = report_id;
    const buf = buffer[0..size];

    if (report_type == c.HID_REPORT_TYPE_OUTPUT) {
        if (buf.len != 0) {
            var current_leds = @as(@TypeOf(last_leds), @bitCast(buf[0]));
            current_leds.reserved = 0;

            if (current_leds.caps_lock != last_leds.caps_lock or current_leds.num_lock != last_leds.num_lock or current_leds.scroll_lock != last_leds.scroll_lock) {
                change_leds = true;
            }

            last_leds = current_leds;
        }
    }
}

export fn main() void {
    logger.initLogger();
    mainWrap() catch |e| {
        intrin.cpsiei();
        std.log.err("{}", .{e});
    };
}
