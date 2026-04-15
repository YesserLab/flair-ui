//! Input event types for flair-ui windows.
//!
//! Events are delivered through a polling model: call `window.pollEvent()`
//! which returns `?Event` until all pending events are consumed.

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

/// Keyboard modifier flags.
pub const Modifiers = packed struct(u8) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
    _padding: u4 = 0,
};

/// A key on the keyboard (symbolic).
pub const Key = enum(u32) {
    unknown = 0,

    // Function keys
    f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,

    // Navigation
    up, down, left, right,
    home, end,
    page_up, page_down,
    insert, delete,

    // Modifier keys
    left_shift, right_shift,
    left_ctrl, right_ctrl,
    left_alt, right_alt,
    left_super, right_super,

    // Lock keys
    caps_lock, num_lock, scroll_lock,

    // Special
    escape, @"return", tab, backspace, space,
    print_screen, pause,

    // Numpad
    kp_0, kp_1, kp_2, kp_3, kp_4, kp_5, kp_6, kp_7, kp_8, kp_9,
    kp_add, kp_sub, kp_mul, kp_div, kp_enter, kp_decimal,

    // Alphabet (lowercase)
    a, b, c, d, e, f, g, h, i, j, k, l, m,
    n, o, p, q, r, s, t, u, v, w, x, y, z,

    // Digits
    @"0", @"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8", @"9",

    // Punctuation / misc
    minus, equal, left_bracket, right_bracket, backslash,
    semicolon, apostrophe, grave, comma, period, slash,
};

pub const KeyEvent = struct {
    key: Key,
    scancode: u32,
    mods: Modifiers,
};

// ---------------------------------------------------------------------------
// Mouse
// ---------------------------------------------------------------------------

pub const MouseButton = enum(u8) {
    left = 1,
    right = 2,
    middle = 3,
    button4 = 4,
    button5 = 5,
};

pub const MouseButtonEvent = struct {
    button: MouseButton,
    x: f32,
    y: f32,
    mods: Modifiers,
};

pub const MouseMoveEvent = struct {
    x: f32,
    y: f32,
};

pub const ScrollEvent = struct {
    dx: f32,
    dy: f32,
};

pub const ResizeEvent = struct {
    width: u32,
    height: u32,
};

// ---------------------------------------------------------------------------
// Unified event type
// ---------------------------------------------------------------------------

pub const Event = union(enum) {
    key_press: KeyEvent,
    key_release: KeyEvent,
    key_repeat: KeyEvent,
    mouse_button_press: MouseButtonEvent,
    mouse_button_release: MouseButtonEvent,
    mouse_move: MouseMoveEvent,
    mouse_scroll: ScrollEvent,
    mouse_enter: MouseMoveEvent,
    mouse_leave: MouseMoveEvent,
    resize: ResizeEvent,
    close,
};

// ---------------------------------------------------------------------------
// Linux/Wayland key-code translation
// ---------------------------------------------------------------------------

/// Translate a Linux evdev key code (from xkb / wl_keyboard) to a `Key`.
pub fn keyFromLinux(code: u32) Key {
    return switch (code) {
        1 => .escape,
        2 => .@"1",
        3 => .@"2",
        4 => .@"3",
        5 => .@"4",
        6 => .@"5",
        7 => .@"6",
        8 => .@"7",
        9 => .@"8",
        10 => .@"9",
        11 => .@"0",
        12 => .minus,
        13 => .equal,
        14 => .backspace,
        15 => .tab,
        16 => .q,
        17 => .w,
        18 => .e,
        19 => .r,
        20 => .t,
        21 => .y,
        22 => .u,
        23 => .i,
        24 => .o,
        25 => .p,
        26 => .left_bracket,
        27 => .right_bracket,
        28 => .@"return",
        29 => .left_ctrl,
        30 => .a,
        31 => .s,
        32 => .d,
        33 => .f,
        34 => .g,
        35 => .h,
        36 => .j,
        37 => .k,
        38 => .l,
        39 => .semicolon,
        40 => .apostrophe,
        41 => .grave,
        42 => .left_shift,
        43 => .backslash,
        44 => .z,
        45 => .x,
        46 => .c,
        47 => .v,
        48 => .b,
        49 => .n,
        50 => .m,
        51 => .comma,
        52 => .period,
        53 => .slash,
        54 => .right_shift,
        55 => .kp_mul,
        56 => .left_alt,
        57 => .space,
        58 => .caps_lock,
        59 => .f1,
        60 => .f2,
        61 => .f3,
        62 => .f4,
        63 => .f5,
        64 => .f6,
        65 => .f7,
        66 => .f8,
        67 => .f9,
        68 => .f10,
        69 => .num_lock,
        70 => .scroll_lock,
        71 => .kp_7,
        72 => .kp_8,
        73 => .kp_9,
        74 => .kp_sub,
        75 => .kp_4,
        76 => .kp_5,
        77 => .kp_6,
        78 => .kp_add,
        79 => .kp_1,
        80 => .kp_2,
        81 => .kp_3,
        82 => .kp_0,
        83 => .kp_decimal,
        87 => .f11,
        88 => .f12,
        96 => .kp_enter,
        97 => .right_ctrl,
        98 => .kp_div,
        100 => .right_alt,
        102 => .home,
        103 => .up,
        104 => .page_up,
        105 => .left,
        106 => .right,
        107 => .end,
        108 => .down,
        109 => .page_down,
        110 => .insert,
        111 => .delete,
        119 => .pause,
        125 => .left_super,
        126 => .right_super,
        else => .unknown,
    };
}
