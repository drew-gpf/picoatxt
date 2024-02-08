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
const c = @import("sdk.zig");
const intrin = @import("intrin.zig");
const std = @import("std");

/// Pin assignments
const clk_in = 21;
const data_in = 20;

const clk_out = 11;
const data_out = 10;

const default_timer = 0;
const command_timer = 1;

const num_xt_cycles = 9; // 1 start + 8 data
const num_at_cycles = 11; // 1 start + 8 data + 1 parity + 1 stop

/// The detected keyboard protocol
var protocol: Protocol = undefined;

/// True if we are in the middle of clocking a bit sequence
var clocking: bool = undefined;
var last_alarm_time: u64 = undefined;

var waiting_for_clk: bool = undefined;
var writing: bool = undefined;

/// Whether or not this is a legacy XT keyboard which:
/// - does not send us a BAT status when powered on
/// - (probably) does not have multibyte scancodes (e.g. right alt) with a 0xE0 or 0xE1 prefix
/// - (MAY) lower the clock before returning it to normal at the end of a sequence
/// - (COULD) have random transient clock pulses
/// These also might happen on non-legacy keyboards
var legacy: bool = false;
var final_edge_time: u64 = undefined;

/// Packet ring buffer
var ring: [64]u8 = undefined;
var fail: bool = undefined;

var current_packet: u6 = undefined;
var next_packet: u6 = undefined;
var will_overflow: bool = undefined;

/// Serial shift register
var clocked_bits: usize = undefined;
var shift_reg: usize = undefined;

var last_command: ?u8 = undefined;
var xt_detect_first: bool = undefined;
var xt_detect_second: bool = undefined;

var rtsIrq: *const fn () callconv(.C) void = undefined;

var bat_status: enum {
    wait,
    err,
    done,
    timer,
} = .wait;

pub fn init() !Protocol {
    // .data is turned into .bss and the pico does not care about clearing its SRAM
    // so we have to initialize everything manually
    protocol = .at;
    clocked_bits = 0;
    shift_reg = 0;
    bat_status = .wait;
    clocking = false;
    current_packet = 0;
    next_packet = 0;
    fail = false;
    will_overflow = false;
    last_alarm_time = 0;
    last_command = null;
    waiting_for_clk = false;
    writing = false;
    xt_detect_first = false;
    xt_detect_second = false;
    legacy = false;
    final_edge_time = c.time_us_64();

    c.gpio_init_mask((1 << clk_in) | (1 << data_in) | (1 << data_out) | (1 << clk_out));
    c.gpio_set_dir_out_masked((1 << data_out) | (1 << clk_out));

    c.gpio_set_drive_strength(clk_out, c.GPIO_DRIVE_STRENGTH_2MA);
    c.gpio_set_drive_strength(data_out, c.GPIO_DRIVE_STRENGTH_2MA);

    c.gpio_set_slew_rate(clk_out, c.GPIO_SLEW_RATE_FAST);
    c.gpio_set_slew_rate(data_out, c.GPIO_SLEW_RATE_FAST);

    // Init timer IRQ on timer0
    // NOTE THAT the "alarm" subsystem loves to acquire spinlocks,
    // so as long as a timer is active, do not mess with it if IRQs are enabled.
    c.hardware_alarm_claim(default_timer);
    c.hardware_alarm_claim(command_timer);
    c.hardware_alarm_set_callback(default_timer, batTimerExpire);
    c.hardware_alarm_set_callback(command_timer, xtBatCheckExpire);

    var next_absolute_time: c.absolute_time_t = undefined;
    c.update_us_since_boot(&next_absolute_time, c.time_us_64() + (1000 * 2500));

    if (c.hardware_alarm_set_target(command_timer, next_absolute_time)) @panic("Failed to start XT BAT timer");

    // Trigger on keyboard request-to-send i.e. initial keyboard falling clk edge
    // A naive implementation might interpret this as the "first bit", but a genuine XT keyboard
    // will not start clocking bits until later leading to some to call it a "second" start bit.
    c.irq_set_exclusive_handler(c.IO_IRQ_BANK0, batClkEdge);
    c.irq_set_enabled(c.IO_IRQ_BANK0, true);
    c.gpio_set_irq_enabled(clk_in, c.GPIO_IRQ_EDGE_RISE, true); // (note that the bit we read is inverted)

    while (true) {
        intrin.cpsidi();

        if (bat_status != .wait) {
            intrin.cpsiei();
            break;
        }

        intrin.wfi();
        intrin.cpsiei();
    }

    switch (bat_status) {
        .wait => unreachable,
        .err => {
            std.log.err("Failed to start event timer", .{});
            return error.FailedToReadBat;
        },
        .done => {
            switch (protocol) {
                .xt => {
                    if (shift_reg != 0x155) {
                        if (shift_reg == 0x1F9 or xt_detect_first) {
                            std.log.err("BAT (XT) returned failure code 0x{X}", .{shift_reg});
                            return error.FailedToReadBat;
                        }

                        c.gpio_set_irq_enabled(clk_in, c.GPIO_IRQ_EDGE_RISE, false);
                        c.gpio_set_irq_enabled(clk_in, c.GPIO_IRQ_EDGE_FALL, false);
                        c.gpio_put(data_out, false);

                        // Lower clk for 12.5ms (clk was already lowered by the bat clk edge irq)
                        if (!startCommandTimer(.xt)) @panic("Failed to start XT BAT command timer");

                        // This could be a legacy keyboard and we received a regular scancode. Try to reset
                        // the board and see what happens.
                        legacy = true;
                        xt_detect_first = true;
                        clocking = false;
                        clocked_bits = 0;
                        shift_reg = 0;
                        bat_status = .wait;

                        while (true) {
                            intrin.cpsidi();

                            if (bat_status != .wait) {
                                intrin.cpsiei();
                                break;
                            }

                            intrin.wfi();
                            intrin.cpsiei();
                        }

                        if (bat_status != .done) {
                            std.log.err("Failed to get legacy BAT status code; is a keyboard plugged in? shift reg: 0x{X} clocked bits: {}", .{ shift_reg, clocked_bits });
                            return error.FailedToGetXtBat;
                        }

                        if (shift_reg != 0x155) {
                            std.log.err("BAT (XT) returned 0x{X} (should be 0x155)", .{shift_reg});
                            return error.FailedToReadBat;
                        }
                    }
                },

                .at => {
                    // We expect:
                    // 0 (start)
                    // 10101010 (data = 0xAA)
                    // 1 (parity)
                    // x (end; some keyboards use arbitrary values)
                    // Note that if the parity bit is 0 we might have an AT/XT keyboard that changes
                    // its protocol depending on if we send an AT reset/resend command in response or not.
                    if (shift_reg & ((1 << 10) - 1) != 0x354) {
                        std.log.err("BAT (AT) returned 0x{X} (should be 0x354 or 0x754)", .{shift_reg});
                        return error.FailedToReadBat;
                    }
                },
            }
        },
        .timer => {
            std.log.err("Timer expired (clocked {} bits reading 0x{X})", .{ clocked_bits, shift_reg });
            return error.FailedToReadBat;
        },
    }

    clocking = false;
    rtsIrq = switch (protocol) {
        .at => buildRTSIrq(.at),
        .xt => buildRTSIrq(.xt),
    };

    const command_timer_expire = switch (protocol) {
        .at => &commandTimerExpireAt,
        .xt => &commandTimerExpireXt,
    };

    // clk is forced low (reads as 1), so we only enable the irq a bit after releasing clk/data
    // use a generic edge irq that only differs based on the num of cycles the protocol requires.
    // We have an IRQ that fires on the initial rising edge called a request-to-send.
    // At that point, we start the timer and then trigger additional IRQs on each falling edge
    // to read each bit.
    c.irq_remove_handler(c.IO_IRQ_BANK0, batClkEdge);
    c.irq_set_exclusive_handler(c.IO_IRQ_BANK0, rtsIrq);
    c.hardware_alarm_set_callback(default_timer, timerExpire);
    c.hardware_alarm_set_callback(command_timer, command_timer_expire);

    c.gpio_clr_mask((1 << clk_out) | (1 << data_out));
    c.gpio_set_irq_enabled(clk_in, c.GPIO_IRQ_EDGE_RISE, true);

    return protocol;
}

/// Get packet, or null if none available. If not null, this function
/// must be called immediately once finished data processing (while IRQs are still masked),
/// because it can hold on to previously received data.
/// This function must be called with IRQs disabled.
pub inline fn getPacket() ?Packet {
    const cmd_buf = last_command;
    if (current_packet == next_packet and !will_overflow) {
        if (fail) {
            // If the last packet was more than we can store we need to request it again
            // At this point data and clk are forced low.
            fail = false;
            last_command = null;

            return Packet{ .data = null, .last_command = cmd_buf };
        }

        return null;
    }

    const ret = ring[current_packet];
    current_packet +%= 1; // note that current_packet is u6 and ring is [0, 63)
    will_overflow = false;
    last_command = null;

    return Packet{ .data = ret, .last_command = cmd_buf };
}

/// Send a command to the keyboard. This function must be called with IRQs masked and with an empty ring buffer
/// i.e. where getPacket returned null or indicated a transmission error.
/// This function will not immediately send the command but instead start a timer to eventually send the command
/// after holding the keyboard's clock line low for a certain amount of time. Afterwards, it will clock the actual
/// command byte. In all cases, the keyboard will reply with a status depending on what command was sent,
/// which must be checked with getPacket().
///
/// If the routine determines that the keyboard had not received the command it will indicate an error
/// when getPacket() is next called by setting the data member to null. Otherwise, the next byte received
/// must be related to the command previously sent, such as an ACK or a BAT status or an echo (0xEE).
/// Of course, if any command other than "reset" is sent to an XT keyboard, this function will return an error.
/// Also, under certain clocking conditions for AT keyboards, this function may sporadically fail, in which case
/// the command must be sent at the next moment getPacket() returns null.
pub inline fn sendCommand(command: Command) CommandError!void {
    switch (protocol) {
        .xt => {
            if (command != .reset) return error.AtXt;
            try requestToSend(.xt);

            c.gpio_put(data_out, false);
            last_command = @intFromEnum(Command.reset);
        },

        .at => {
            try sendAtCommand(@intFromEnum(command));
        },
    }
}

/// Like sendCommand, but you can send an arbitrary byte.
pub inline fn sendAtCommand(byte: u8) CommandError!void {
    if (protocol != .at) return error.AtXt;
    if (clocking and clocked_bits >= 8) return error.Clocking;
    if (writing) return error.Contention;

    try requestToSend(.at);
    c.gpio_put(data_out, false);

    // Take over shift_reg and clocked_bits which are reset normally anyways
    shift_reg = @as(usize, byte) | ((~@as(usize, @popCount(byte) & 1) & 1) << 8);
    clocked_bits = 0;

    c.irq_remove_handler(c.IO_IRQ_BANK0, rtsIrq);
    c.irq_set_exclusive_handler(c.IO_IRQ_BANK0, clockAtCommand);
    last_command = byte;
}

pub const Command = enum(u8) {
    /// Reset the keyboard. For XT this will also drive the reset line to ground.
    /// This is the only supported command for XT keyboards. The keyboard will respond with an ACK
    /// and then a BAT status for AT, while XT will just respond with a BAT status.
    reset = 0xFF,

    /// Ask the keyboard to resend the most recent response.
    resend = 0xFE,

    /// Set the status of the locklights. After receiving an ACK, send an arbitrary command
    /// containing the setting of each lock light (see LockLightStatus).
    set_locklights = 0xED,

    /// Send an echo back (0xEE) instead of an ACK.
    echo = 0xEE,

    /// Set typematic delay. Useless because the USB HID keyboard specification only allows us to indicate
    /// if keys are pressed or not. After sending back an ACK, will take the next command as the actual typematic delay.
    set_delay = 0xF3,

    /// Enable scanning if it was disabled. Responds with an ACK.
    enable_scanning = 0xF4,

    /// Disable scanning if it is disabled, and reset keyboard settings to power-on defaults; see reset_changes. Responds with an ACK.
    disable_scanning = 0xF5,

    /// Resets settings (like typematic delay) to power-on defaults and clears the output buffer. Responds with an ACK.
    reset_changes = 0xF6,
};

pub const LockLightStatus = packed struct(u8) {
    scroll_lock: u1,
    num_lock: u1,
    caps_lock: u1,
    /// must be 0
    reserved: u5,
};

pub const CommandError = error{
    /// Failed to send command because too many bits have been clocked by the keyboard and would
    /// be thrown out; please wait for the next packet. Impossible if the protocol is XT.
    Clocking,

    /// Failed to send command because there is still data to process in the ring buffer; please empty
    /// the buffer using getPacket() before continuing.
    RingBufferNotEmpty,

    /// Tried to send an AT-only command on an XT keyboard (i.e. not a reset)
    AtXt,

    /// Tried to send a command while a command was being clocked by the keyboard,
    /// or tried to send a command while waiting for a response from another command.
    Contention,
};

pub const Packet = struct {
    /// If null, data transmission failed (or too many packets) and clk/data are forced low;
    /// depending on the protocol, you must either send a reset
    /// or ask for the packet again. This is guaranteed to be the most recent packet,
    /// and new packets can't be sent until the reset packet is sent to the keyboard.
    data: ?u8,

    /// Indicates if this packet is related to a command that was just sent.
    last_command: ?u8,
};

pub const Protocol = enum {
    xt,
    at,

    pub fn numCycles(this: Protocol) usize {
        return switch (this) {
            .xt => num_xt_cycles,
            .at => num_at_cycles,
        };
    }
};

inline fn requestToSend(comptime which_protocol: Protocol) !void {
    // Make sure the main loop has to receive the response packet next
    // instead of thinking it has to send another command.
    // For example, if one packet causes a command to be sent, it will have to go through
    // the entire ring buffer until it reaches the ACK; if any intermediate command
    // also causes a command to be sent, or contains an ACK, problems will likely occur.
    if (will_overflow or next_packet != current_packet) return error.RingBufferNotEmpty;
    if (waiting_for_clk) return error.Contention;
    if (last_command != null) return error.Contention;

    clocking = false;
    waiting_for_clk = true;
    c.gpio_set_irq_enabled(clk_in, c.GPIO_IRQ_EDGE_RISE, false);
    c.gpio_set_irq_enabled(clk_in, c.GPIO_IRQ_EDGE_FALL, false);
    c.gpio_put(clk_out, true);

    if (!startCommandTimer(which_protocol)) @panic("Failed to start command timer");
}

/// Called before clocking next bit
fn clockAtCommand() callconv(.C) void {
    defer c.gpio_acknowledge_irq(clk_in, c.GPIO_IRQ_EDGE_RISE);
    clocked_bits += 1;

    if (clocked_bits < num_at_cycles) {
        // Instead of writing a bit on a specific edge we wait for the falling edge and after 10us
        // write whatever data bit we're supposed to write. This should provide enough time for both
        // falling and rising edge triggered readers.
        // TODO look into why only one keyboard had problems without a busy wait
        c.busy_wait_us(10);

        if (clocked_bits == (num_at_cycles - 1)) {
            c.gpio_put(data_out, false);
        } else {
            c.gpio_put(data_out, @as(u1, @truncate(shift_reg)) == 0);
            shift_reg >>= 1;
        }
    } else {
        c.irq_remove_handler(c.IO_IRQ_BANK0, clockAtCommand);
        c.irq_set_exclusive_handler(c.IO_IRQ_BANK0, rtsIrq);

        // End bit was just clocked as 1; make sure the keyboard is forcing it low
        // Apparently this breaks for obscure AT keyboards because they just... don't do this,
        // and they don't have the accompanying clock edge to go with it.
        // The fix would probably be to have a strict timeout that when reached can recognize
        // that the entire data packet was sent but the keyboard never bothered with an ACK.
        // TODO this probably shouldnt panic
        if (!gpioGet(data_in)) @panic("Keyboard did not force data low at end of command");

        writing = false;
        c.hardware_alarm_cancel(default_timer);
    }
}

/// Request-to-send IRQ (initial rising edge)
/// If data is being forced low, we have up to 250 microseconds here to
/// allow data to go high, or else the keyboard will store the byte it wants to send
/// in an internal buffer.
fn buildRTSIrq(comptime which_protocol: Protocol) *const fn () callconv(.C) void {
    return struct {
        const scope_protocol = which_protocol;

        pub fn callback() callconv(.C) void {
            if (clocking) {
                defer c.gpio_acknowledge_irq(clk_in, c.GPIO_IRQ_EDGE_FALL);
                const clock_callback = comptime switch (scope_protocol) {
                    .at => clockAtBit,
                    .xt => clockXtBit,
                };

                const bit_setting = !gpioGet(data_in);

                // Some "legacy" keyboards like the XT model F have a random clock pulse that's very short
                // but not short enough to elude our interrupts, so implement a really lazy check
                // to see if this is a real clock pulse.
                // TODO look into if this is caused by not using pullups on the clk line, faulty breadboard connections, etc
                if (comptime scope_protocol == .xt) {
                    if (legacy) {
                        c.busy_wait_us(20);
                        if (gpioGet(clk_in)) return;
                    }
                }

                shift_reg |= @as(usize, @intFromBool(bit_setting)) << @as(u5, @intCast(clocked_bits));
                clocked_bits += 1;

                if (clock_callback()) {
                    c.hardware_alarm_cancel(default_timer);
                    c.gpio_set_irq_enabled(clk_in, c.GPIO_IRQ_EDGE_RISE, true);
                    c.gpio_set_irq_enabled(clk_in, c.GPIO_IRQ_EDGE_FALL, false);

                    final_edge_time = c.time_us_64();
                    clocking = false;
                }
            } else {
                defer c.gpio_acknowledge_irq(clk_in, c.GPIO_IRQ_EDGE_RISE);
                if (fail) return; // ignore false positives caused by us forcing the line low
                if (!startTimer(scope_protocol)) @panic("Failed to start timer");

                if (comptime scope_protocol == .xt) {
                    // Make sure this is actually a new packet. On IBM XT keyboards,
                    // there is a final rising edge that occurs when transitioning from
                    // the clk being low by default (after the request-to-send)
                    // to the normal state, where the clk is high and idle.
                    // TODO check if there's a better way to do this.
                    const current_time = c.time_us_64();
                    if ((current_time -% final_edge_time) <= 60) return;
                }

                // Start clocking bits on falling edge (keyboard rising edge)
                c.gpio_set_irq_enabled(clk_in, c.GPIO_IRQ_EDGE_RISE, false);
                c.gpio_set_irq_enabled(clk_in, c.GPIO_IRQ_EDGE_FALL, true);
                shift_reg = 0;
                clocked_bits = 0;
                clocking = true;
            }
        }
    }.callback;
}

fn timerExpire(_: c.uint) callconv(.C) void {
    // If we haven't reached the set time then this IRQ was misfired.
    if (c.time_us_64() < last_alarm_time) return;
    if (writing) @panic("Keyboard did not clock command");

    // If we aren't clocking bits then this IRQ was misfired.
    if (!clocking) return;

    c.gpio_set_irq_enabled(clk_in, c.GPIO_IRQ_EDGE_RISE, false);
    c.gpio_set_irq_enabled(clk_in, c.GPIO_IRQ_EDGE_FALL, false);

    clocking = false;
    markFail();
}

fn commandTimerExpireAt(_: c.uint) callconv(.C) void {
    c.gpio_set_irq_enabled(clk_in, c.GPIO_IRQ_EDGE_RISE, true);

    waiting_for_clk = false;
    writing = true;

    c.gpio_put(data_out, true);
    @fence(.SeqCst);
    c.busy_wait_us(10);

    if (!startTimer(.at)) @panic("Failed to start timer while sending a command");

    // (triggers falling edge IRQ)
    c.gpio_put(clk_out, false);
}

fn commandTimerExpireXt(_: c.uint) callconv(.C) void {
    // The 5155 reference manual says that the XT keyboard will clock 9 bits to read the reset command
    // but every XT keyboard I'm testing with will just go right to resetting itself if clock is lowered
    // for 12.5ms, causing us to 'absorb' the BAT status.
    c.gpio_set_irq_enabled(clk_in, c.GPIO_IRQ_EDGE_RISE, true);
    c.gpio_put(clk_out, false);
    waiting_for_clk = false;
}

fn xtBatCheckExpire(_: c.uint) callconv(.C) void {
    legacy = true;

    if (clocking) return;
    if (xt_detect_second) @panic("Probably no keyboard connected");

    if (!xt_detect_first) {
        xt_detect_first = true;

        // Lower clk for 12.5ms
        c.gpio_set_irq_enabled(clk_in, c.GPIO_IRQ_EDGE_RISE, false);
        if (!startCommandTimer(.xt)) @panic("Failed to start XT BAT command timer");
        c.gpio_put(clk_out, true);
    } else {
        c.gpio_set_irq_enabled(clk_in, c.GPIO_IRQ_EDGE_RISE, true);
        c.gpio_put(clk_out, false);

        var next_absolute_time: c.absolute_time_t = undefined;
        c.update_us_since_boot(&next_absolute_time, c.time_us_64() + (1000 * 2500));

        if (c.hardware_alarm_set_target(command_timer, next_absolute_time)) @panic("Failed to start XT BAT timer");
        xt_detect_second = true;
    }
}

inline fn clockXtBit() bool {
    if (clocked_bits == num_xt_cycles) {
        if (@as(u1, @truncate(shift_reg)) == 0) {
            markFail();
        } else {
            addByteToRing(@as(u8, @intCast(shift_reg >> 1)));
        }

        return true;
    }

    return false;
}

inline fn clockAtBit() bool {
    if (clocked_bits == num_at_cycles) {
        if (@as(u1, @truncate(shift_reg)) == 1 or @as(u1, @truncate(@popCount(@as(u9, @truncate(shift_reg >> 1))))) == 0) {
            markFail();
        } else {
            addByteToRing(@as(u8, @truncate(shift_reg >> 1)));
        }

        return true;
    }

    return false;
}

inline fn addByteToRing(val: u8) void {
    if (will_overflow) {
        markFail();
    } else {
        ring[next_packet] = val;
        next_packet +%= 1;

        if (next_packet == current_packet) will_overflow = true;
    }
}

inline fn markFail() void {
    fail = true;
    c.gpio_set_mask((1 << clk_out) | (1 << data_out));
}

fn batTimerExpire(_: c.uint) callconv(.C) void {
    if (bat_status == .wait and clocking) {
        c.gpio_set_mask((1 << clk_out) | (1 << data_out));
        c.gpio_set_irq_enabled(clk_in, c.GPIO_IRQ_EDGE_FALL, false);

        bat_status = .timer;
    }
}

fn batClkEdge() callconv(.C) void {
    if (clocking) {
        defer c.gpio_acknowledge_irq(clk_in, c.GPIO_IRQ_EDGE_FALL);
        if (bat_status != .wait) return;

        const bit_setting = !gpioGet(data_in);
        if (legacy or @as(u1, @truncate(shift_reg)) == 1) {
            c.busy_wait_us(20);
            if (gpioGet(clk_in)) {
                legacy = true;
                return;
            }
        }

        shift_reg |= @as(usize, @intFromBool(bit_setting)) << @as(u5, @intCast(clocked_bits));
        clocked_bits += 1;

        switch (clocked_bits) {
            num_xt_cycles => {
                if (@as(u1, @truncate(shift_reg)) == 1) {
                    // XT start bit with 9 bits clocked
                    bat_status = .done;
                    protocol = .xt;
                    final_edge_time = c.time_us_64();
                }
            },

            num_at_cycles => {
                if (@as(u1, @truncate(shift_reg)) == 0) {
                    // AT start bit with 11 bits clocked
                    bat_status = .done;
                }
            },

            else => {},
        }

        if (bat_status == .done) {
            // Force clk and data low (keyboard side) and disable this IRQ
            c.gpio_set_irq_enabled(clk_in, c.GPIO_IRQ_EDGE_FALL, false);
            c.gpio_set_mask((1 << clk_out) | (1 << data_out));
            c.hardware_alarm_cancel(default_timer);
        }
    } else {
        defer c.gpio_acknowledge_irq(clk_in, c.GPIO_IRQ_EDGE_RISE);
        c.hardware_alarm_cancel(command_timer);

        if (bat_status != .wait) return;
        if (!startTimer(.at)) {
            bat_status = .err;
            return;
        }

        c.gpio_set_irq_enabled(clk_in, c.GPIO_IRQ_EDGE_FALL, true);
        c.gpio_set_irq_enabled(clk_in, c.GPIO_IRQ_EDGE_RISE, false);

        clocking = true;
    }
}

/// !!Only to be called with IRQs disabled!!
/// Returns if timer could actually be started
fn startTimer(comptime which_protocol: Protocol) bool {
    // Each edge lasts up to ~50us, one full cycle is twice that
    const period_us = 50 * 2;
    const time_wait = 4 * which_protocol.numCycles() * period_us;
    const next_time = c.time_us_64() + time_wait;
    last_alarm_time = next_time;

    var next_absolute_time: c.absolute_time_t = undefined;
    c.update_us_since_boot(&next_absolute_time, next_time);

    return c.hardware_alarm_set_target(default_timer, next_absolute_time) == false;
}

/// Only to be called with IRQs disabled
/// Returns if timer could actually be started
fn startCommandTimer(comptime which_protocol: Protocol) bool {
    const duration_us = switch (which_protocol) {
        .at => 60,
        .xt => 12500,
    };

    var next_absolute_time: c.absolute_time_t = undefined;
    c.update_us_since_boot(&next_absolute_time, c.time_us_64() + duration_us);

    return c.hardware_alarm_set_target(command_timer, next_absolute_time) == false;
}

inline fn gpioGet(gpio: u5) bool {
    // The regular gpio_get uses volatile in a really weird way which causes
    // the translate-c mechanism to throw it out and access the sio word incorrectly,
    // so do it manually here.
    const temp = @as(*align(4) volatile u32, @ptrFromInt(@intFromPtr(c.sio_hw) + 4)).*;
    return (temp & (@as(u32, 1) << gpio)) != 0;
}
