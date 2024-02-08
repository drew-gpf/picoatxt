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

/// Indicates USB scancode. Note that values 0-3 are reserved so we use them internally
/// to indicate controls. All except 0xE0 -> 0xE7 are bit positions in the 'keys' array,
/// where those USB scancodes must start at keys[21].
pub const Scancode = enum(u8) {
    /// unrecognized, ignore or reset
    none = 0,
    /// overrun condition
    ///
    /// The keyboard behavior will vary at this point. My IBM Model F from 1984 with an NEC 8048 clone
    /// will only send this code if too many keys are made/broken in an instant. Practically however
    /// it is only possible to be reached if too many keys are broken, which causes the worst
    /// behavior which is that a bunch of keys remain pressed. We could reset but it might be distracting
    /// if the keyboard has lock light LEDs and will be much slower if we need to probe the reset line.
    ///
    /// In fact, USB boot keyboards need to replace all key scancodes with the overrun scancode
    /// if an overrun condition occurs.
    overrun = 1,
    /// 0xF0 (AT only); go to next byte
    break_next = 0xDD,
    /// 0xE0 or 0xE1; switch shift states (both protocols function identically in this case)
    extended = 0xDE,
    /// bit 7 set (XT only); unmask bit 7 and break scancode
    /// The resulting scancode is guaranteed to correspond to a valid USB scancode;
    /// an unrecognized or control scancode will never have a break but not make code.
    break_code = 0xDF,

    /// Scancode
    _,
};

/// Shift state, or scancode table selector
pub const ShiftState = enum(u2) {
    /// Use normal scancode table
    normal = 0,
    /// Use "extended" scancode table
    extended = 1,
    /// Look for ctrl or break code
    pause = 2,
    /// Look for nmlk
    pause_next = 3,
};

// zig fmt: off
pub const xt_normal = [256]Scancode{
    .overrun, // 0x00

    @enumFromInt(c.HID_KEY_ESCAPE),           @enumFromInt(c.HID_KEY_1),                    @enumFromInt(c.HID_KEY_2),
    @enumFromInt(c.HID_KEY_3),                @enumFromInt(c.HID_KEY_4),                    @enumFromInt(c.HID_KEY_5),
    @enumFromInt(c.HID_KEY_6),                @enumFromInt(c.HID_KEY_7),                    @enumFromInt(c.HID_KEY_8),
    @enumFromInt(c.HID_KEY_9),                @enumFromInt(c.HID_KEY_0),                    @enumFromInt(c.HID_KEY_MINUS),
    @enumFromInt(c.HID_KEY_EQUAL),            @enumFromInt(c.HID_KEY_BACKSPACE),            @enumFromInt(c.HID_KEY_TAB),
    @enumFromInt(c.HID_KEY_Q),                @enumFromInt(c.HID_KEY_W),                    @enumFromInt(c.HID_KEY_E),
    @enumFromInt(c.HID_KEY_R),                @enumFromInt(c.HID_KEY_T),                    @enumFromInt(c.HID_KEY_Y),
    @enumFromInt(c.HID_KEY_U),                @enumFromInt(c.HID_KEY_I),                    @enumFromInt(c.HID_KEY_O),
    @enumFromInt(c.HID_KEY_P),                @enumFromInt(c.HID_KEY_BRACKET_LEFT),         @enumFromInt(c.HID_KEY_BRACKET_RIGHT),
    @enumFromInt(c.HID_KEY_ENTER),            @enumFromInt(c.HID_KEY_CONTROL_LEFT),         @enumFromInt(c.HID_KEY_A),
    @enumFromInt(c.HID_KEY_S),                @enumFromInt(c.HID_KEY_D),                    @enumFromInt(c.HID_KEY_F),
    @enumFromInt(c.HID_KEY_G),                @enumFromInt(c.HID_KEY_H),                    @enumFromInt(c.HID_KEY_J),
    @enumFromInt(c.HID_KEY_K),                @enumFromInt(c.HID_KEY_L),                    @enumFromInt(c.HID_KEY_SEMICOLON),
    @enumFromInt(c.HID_KEY_APOSTROPHE),       @enumFromInt(c.HID_KEY_GRAVE),                @enumFromInt(c.HID_KEY_SHIFT_LEFT),
    @enumFromInt(c.HID_KEY_BACKSLASH),        @enumFromInt(c.HID_KEY_Z),                    @enumFromInt(c.HID_KEY_X),
    @enumFromInt(c.HID_KEY_C),                @enumFromInt(c.HID_KEY_V),                    @enumFromInt(c.HID_KEY_B),
    @enumFromInt(c.HID_KEY_N),                @enumFromInt(c.HID_KEY_M),                    @enumFromInt(c.HID_KEY_COMMA),
    @enumFromInt(c.HID_KEY_PERIOD),           @enumFromInt(c.HID_KEY_SLASH),                @enumFromInt(c.HID_KEY_SHIFT_RIGHT),
    // should be HID_KEY_KEYPAD_MULTIPLY but i want print screen
    @enumFromInt(c.HID_KEY_PRINT_SCREEN),     @enumFromInt(c.HID_KEY_ALT_LEFT),             @enumFromInt(c.HID_KEY_SPACE),
    @enumFromInt(c.HID_KEY_CAPS_LOCK),        @enumFromInt(c.HID_KEY_F1),                   @enumFromInt(c.HID_KEY_F2),
    @enumFromInt(c.HID_KEY_F3),               @enumFromInt(c.HID_KEY_F4),                   @enumFromInt(c.HID_KEY_F5),
    @enumFromInt(c.HID_KEY_F6),               @enumFromInt(c.HID_KEY_F7),                   @enumFromInt(c.HID_KEY_F8),
    @enumFromInt(c.HID_KEY_F9),               @enumFromInt(c.HID_KEY_F10),                  @enumFromInt(c.HID_KEY_NUM_LOCK),
    @enumFromInt(c.HID_KEY_SCROLL_LOCK),      @enumFromInt(c.HID_KEY_KEYPAD_7),             @enumFromInt(c.HID_KEY_KEYPAD_8),
    @enumFromInt(c.HID_KEY_KEYPAD_9),         @enumFromInt(c.HID_KEY_KEYPAD_SUBTRACT),      @enumFromInt(c.HID_KEY_KEYPAD_4),
    @enumFromInt(c.HID_KEY_KEYPAD_5),         @enumFromInt(c.HID_KEY_KEYPAD_6),             @enumFromInt(c.HID_KEY_KEYPAD_ADD),
    @enumFromInt(c.HID_KEY_KEYPAD_1),         @enumFromInt(c.HID_KEY_KEYPAD_2),             @enumFromInt(c.HID_KEY_KEYPAD_3),
    @enumFromInt(c.HID_KEY_KEYPAD_0),         @enumFromInt(c.HID_KEY_KEYPAD_DECIMAL),       @enumFromInt(c.HID_KEY_PRINT_SCREEN), .none,
    @enumFromInt(c.HID_KEY_EUROPE_2),         @enumFromInt(c.HID_KEY_F11),                  @enumFromInt(c.HID_KEY_F12), // 0x58

    .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none,
    .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none,
    .none, // 0x7F

    .none, // 0x80

    .break_code, .break_code, .break_code,
    .break_code, .break_code, .break_code,
    .break_code, .break_code, .break_code,
    .break_code, .break_code, .break_code,
    .break_code, .break_code, .break_code,
    .break_code, .break_code, .break_code,
    .break_code, .break_code, .break_code,
    .break_code, .break_code, .break_code,
    .break_code, .break_code, .break_code,
    .break_code, .break_code, .break_code,
    .break_code, .break_code, .break_code,
    .break_code, .break_code, .break_code,
    .break_code, .break_code, .break_code,
    .break_code, .break_code, .break_code,
    .break_code, .break_code, .break_code,
    .break_code, .break_code, .break_code,
    .break_code, .break_code, .break_code,
    .break_code, .break_code, .break_code,
    .break_code, .break_code, .break_code,
    .break_code, .break_code, .break_code,
    .break_code, .break_code, .break_code,
    .break_code, .break_code, .break_code,
    .break_code, .break_code, .break_code,
    .break_code, .break_code, .break_code,
    .break_code, .break_code, .break_code,
    .break_code, .break_code, .break_code,
    .break_code, .break_code, .break_code,
    .break_code, .break_code, .break_code, .none,
    .break_code, .break_code, .break_code, // 0xD8

    .none, .none, .none, .none, .none, .none, .none, // 0xDF
    .extended, .extended, // 0xE1

    .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none,
    .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none,
    .none,

    .overrun, // 0xFF
};

// zig fmt: on
pub const xt_extended = blk: {
    var array_ret = [_]Scancode{.none} ** 256;
    const alt_scancode_list = [_](struct { code: c_int, val: u8 }){
        .{ .code = c.HID_KEY_KEYPAD_ENTER, .val = 0x1C },
        .{ .code = c.HID_KEY_CONTROL_RIGHT, .val = 0x1D },
        .{ .code = c.HID_KEY_KEYPAD_DIVIDE, .val = 0x35 },
        .{ .code = c.HID_KEY_PRINT_SCREEN, .val = 0x37 },
        .{ .code = c.HID_KEY_ALT_RIGHT, .val = 0x38 },
        .{ .code = c.HID_KEY_PAUSE, .val = 0x46 },
        .{ .code = c.HID_KEY_HOME, .val = 0x47 },
        .{ .code = c.HID_KEY_ARROW_UP, .val = 0x48 },
        .{ .code = c.HID_KEY_PAGE_UP, .val = 0x49 },
        .{ .code = c.HID_KEY_ARROW_LEFT, .val = 0x4B },
        .{ .code = c.HID_KEY_ARROW_RIGHT, .val = 0x4D },
        .{ .code = c.HID_KEY_END, .val = 0x4F },
        .{ .code = c.HID_KEY_ARROW_DOWN, .val = 0x50 },
        .{ .code = c.HID_KEY_PAGE_DOWN, .val = 0x51 },
        .{ .code = c.HID_KEY_INSERT, .val = 0x52 },
        .{ .code = c.HID_KEY_DELETE, .val = 0x53 },
    };

    array_ret[0x00] = .overrun;
    array_ret[0xFF] = .overrun;
    array_ret[0xE0] = .extended;
    array_ret[0xE1] = .extended;

    for (alt_scancode_list) |code| {
        array_ret[code.val] = @enumFromInt(code.code);
        array_ret[code.val | 0x80] = .break_code;
    }

    break :blk array_ret;
};

pub const xt_pause = blk: {
    var array_ret = [_]Scancode{.none} ** 256;

    array_ret[0x00] = .overrun;
    array_ret[0xFF] = .overrun;
    array_ret[0x1D] = .extended;
    array_ret[0xE0] = .extended;
    array_ret[0xE1] = .extended;
    array_ret[0x9D] = .extended;

    break :blk array_ret;
};

pub const xt_pause_next = blk: {
    var array_ret = [_]Scancode{.none} ** 256;

    array_ret[0x45] = @as(Scancode, @enumFromInt(c.HID_KEY_PAUSE));
    array_ret[0x00] = .overrun;
    array_ret[0xFF] = .overrun;
    array_ret[0xE0] = .extended;
    array_ret[0xE1] = .extended;

    break :blk array_ret;
};

// zig fmt: off

pub const at_normal = [256]Scancode{ 
    .overrun, // 0x00

    @enumFromInt(c.HID_KEY_F9),                 .none,                                  @enumFromInt(c.HID_KEY_F5),
    @enumFromInt(c.HID_KEY_F3),                 @enumFromInt(c.HID_KEY_F1),             @enumFromInt(c.HID_KEY_F2),
    @enumFromInt(c.HID_KEY_F12),                .none,                                  @enumFromInt(c.HID_KEY_F10),
    @enumFromInt(c.HID_KEY_F8),                 @enumFromInt(c.HID_KEY_F6),             @enumFromInt(c.HID_KEY_F4),
    @enumFromInt(c.HID_KEY_TAB),                @enumFromInt(c.HID_KEY_GRAVE),          .none,
    .none,                                      @enumFromInt(c.HID_KEY_ALT_LEFT),       @enumFromInt(c.HID_KEY_SHIFT_LEFT),
    .none,                                      @enumFromInt(c.HID_KEY_CONTROL_LEFT),   @enumFromInt(c.HID_KEY_Q),
    @enumFromInt(c.HID_KEY_1),                  .none,                                  .none,
    .none,                                      @enumFromInt(c.HID_KEY_Z),              @enumFromInt(c.HID_KEY_S),
    @enumFromInt(c.HID_KEY_A),                  @enumFromInt(c.HID_KEY_W),              @enumFromInt(c.HID_KEY_2),
    .none,                                      .none,                                  @enumFromInt(c.HID_KEY_C),
    @enumFromInt(c.HID_KEY_X),                  @enumFromInt(c.HID_KEY_D),              @enumFromInt(c.HID_KEY_E),
    @enumFromInt(c.HID_KEY_4),                  @enumFromInt(c.HID_KEY_3),              .none,
    .none,                                      @enumFromInt(c.HID_KEY_SPACE),          @enumFromInt(c.HID_KEY_V),
    @enumFromInt(c.HID_KEY_F),                  @enumFromInt(c.HID_KEY_T),              @enumFromInt(c.HID_KEY_R),
    @enumFromInt(c.HID_KEY_5),                  .none,                                  .none,
    @enumFromInt(c.HID_KEY_N),                  @enumFromInt(c.HID_KEY_B),              @enumFromInt(c.HID_KEY_H),
    @enumFromInt(c.HID_KEY_G),                  @enumFromInt(c.HID_KEY_Y),              @enumFromInt(c.HID_KEY_6),
    .none,                                      .none,                                  .none,
    @enumFromInt(c.HID_KEY_M),                  @enumFromInt(c.HID_KEY_J),              @enumFromInt(c.HID_KEY_U),
    @enumFromInt(c.HID_KEY_7),                  @enumFromInt(c.HID_KEY_8),              .none,
    .none,                                      @enumFromInt(c.HID_KEY_COMMA),          @enumFromInt(c.HID_KEY_K),
    @enumFromInt(c.HID_KEY_I),                  @enumFromInt(c.HID_KEY_O),              @enumFromInt(c.HID_KEY_0),
    @enumFromInt(c.HID_KEY_9),                  .none,                                  .none,
    @enumFromInt(c.HID_KEY_PERIOD),             @enumFromInt(c.HID_KEY_SLASH),          @enumFromInt(c.HID_KEY_L),
    @enumFromInt(c.HID_KEY_SEMICOLON),          @enumFromInt(c.HID_KEY_P),              @enumFromInt(c.HID_KEY_MINUS),
    .none,                                      .none,                                  .none,
    @enumFromInt(c.HID_KEY_APOSTROPHE),         .none,                                  @enumFromInt(c.HID_KEY_BRACKET_LEFT),
    @enumFromInt(c.HID_KEY_EQUAL),              .none,                                  .none,
    @enumFromInt(c.HID_KEY_CAPS_LOCK),          @enumFromInt(c.HID_KEY_SHIFT_RIGHT),    @enumFromInt(c.HID_KEY_ENTER),
    @enumFromInt(c.HID_KEY_BRACKET_RIGHT),      .none,                                  @enumFromInt(c.HID_KEY_BACKSLASH),
    .none,                                      .none,                                  .none,
    .none,                                      .none,                                  .none,
    .none,                                      .none,                                  @enumFromInt(c.HID_KEY_BACKSPACE),
    .none,                                      .none,                                  @enumFromInt(c.HID_KEY_KEYPAD_1),
    .none,                                      @enumFromInt(c.HID_KEY_KEYPAD_4),       @enumFromInt(c.HID_KEY_KEYPAD_7),
    .none,                                      .none,                                  .none,
    @enumFromInt(c.HID_KEY_KEYPAD_0),           @enumFromInt(c.HID_KEY_KEYPAD_DECIMAL), @enumFromInt(c.HID_KEY_KEYPAD_2),
    @enumFromInt(c.HID_KEY_KEYPAD_5),           @enumFromInt(c.HID_KEY_KEYPAD_6),       @enumFromInt(c.HID_KEY_KEYPAD_8),
    @enumFromInt(c.HID_KEY_ESCAPE),             @enumFromInt(c.HID_KEY_NUM_LOCK),       @enumFromInt(c.HID_KEY_F11),
    @enumFromInt(c.HID_KEY_KEYPAD_ADD),         @enumFromInt(c.HID_KEY_KEYPAD_3),       @enumFromInt(c.HID_KEY_KEYPAD_SUBTRACT),
    @enumFromInt(c.HID_KEY_KEYPAD_MULTIPLY),    @enumFromInt(c.HID_KEY_KEYPAD_9),       @enumFromInt(c.HID_KEY_SCROLL_LOCK),
    .none,                                      .none,                                  .none,
    .none,                                      @enumFromInt(c.HID_KEY_F7), // 0x83

    .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none,
    .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none,
    .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none,
    .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, // 0xDF

    .extended, .extended, // 0xE1

    .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, // 0xEF

    .break_next, // 0xF0

    .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none, .none,
    
    .overrun, // 0xFF
};

// zig fmt: on

pub const at_extended = blk: {
    var array_ret = [_]Scancode{.none} ** 256;
    const alt_scancode_list = [_](struct { code: c_int, val: u8 }){
        .{ .code = c.HID_KEY_KEYPAD_ENTER, .val = 0x5A },
        .{ .code = c.HID_KEY_CONTROL_RIGHT, .val = 0x14 },
        .{ .code = c.HID_KEY_KEYPAD_DIVIDE, .val = 0x4A },
        .{ .code = c.HID_KEY_PRINT_SCREEN, .val = 0x7C },
        .{ .code = c.HID_KEY_ALT_RIGHT, .val = 0x11 },
        .{ .code = c.HID_KEY_PAUSE, .val = 0x7E },
        .{ .code = c.HID_KEY_HOME, .val = 0x6C },
        .{ .code = c.HID_KEY_ARROW_UP, .val = 0x75 },
        .{ .code = c.HID_KEY_PAGE_UP, .val = 0x7D },
        .{ .code = c.HID_KEY_ARROW_LEFT, .val = 0x6B },
        .{ .code = c.HID_KEY_ARROW_RIGHT, .val = 0x74 },
        .{ .code = c.HID_KEY_END, .val = 0x69 },
        .{ .code = c.HID_KEY_ARROW_DOWN, .val = 0x72 },
        .{ .code = c.HID_KEY_PAGE_DOWN, .val = 0x7A },
        .{ .code = c.HID_KEY_INSERT, .val = 0x70 },
        .{ .code = c.HID_KEY_DELETE, .val = 0x71 },
    };

    array_ret[0x00] = .overrun;
    array_ret[0xFF] = .overrun;
    array_ret[0xE0] = .extended;
    array_ret[0xE1] = .extended;
    array_ret[0xF0] = .break_next;

    for (alt_scancode_list) |code| {
        array_ret[code.val] = @as(Scancode, @enumFromInt(code.code));
    }

    break :blk array_ret;
};

pub const at_pause = blk: {
    var array_ret = [_]Scancode{.none} ** 256;

    array_ret[0x00] = .overrun;
    array_ret[0xFF] = .overrun;
    array_ret[0x14] = .extended;
    array_ret[0xE0] = .extended;
    array_ret[0xE1] = .extended;
    array_ret[0xF0] = .break_next;

    break :blk array_ret;
};

pub const at_pause_next = blk: {
    var array_ret = [_]Scancode{.none} ** 256;

    array_ret[0x77] = @as(Scancode, @enumFromInt(c.HID_KEY_PAUSE));
    array_ret[0x00] = .overrun;
    array_ret[0xFF] = .overrun;
    array_ret[0xE0] = .extended;
    array_ret[0xE1] = .extended;
    array_ret[0xF0] = .break_next; // a 'break' on PAUSE (0x77) will be ignored

    break :blk array_ret;
};

pub const xt_tables = [_][]const Scancode{
    xt_normal[0..],
    xt_extended[0..],
    xt_pause[0..],
    xt_pause_next[0..],
};

pub const at_tables = [_][]const Scancode{
    at_normal[0..],
    at_extended[0..],
    at_pause[0..],
    at_pause_next[0..],
};
