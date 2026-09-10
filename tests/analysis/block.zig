const empty_block = {};
//    ^^^^^^^^^^^ (void)()

// zig fmt: off
const void_block = { _ = 1; };
//    ^^^^^^^^^^ (void)()

const compile_error_block = { @compileError("foo"); };
//    ^^^^^^^^^^^^^^^^^^^ (noreturn)()

const panic_block = { @panic("foo"); };
//    ^^^^^^^^^^^ (noreturn)()

const labeled_block_0 = blk: { break :blk @as(i32, 1); };
//    ^^^^^^^^^^^^^^^ (i32)()

const labeled_block_1 = blk: {
//    ^^^^^^^^^^^^^^^ (i64)()
    if (false) break :blk @as(i32, 1);
    break :blk @as(i64, 2);
};

const labeled_block_void = blk: {
//    ^^^^^^^^^^^^^^^^^^ (void)()
    break :blk;
};

var runtime_condition = true;
const labeled_block_peer = blk: {
//    ^^^^^^^^^^^^^^^^^^ (i64)()
    if (runtime_condition) break :blk @as(i32, 1);
    break :blk @as(i64, 2);
};

const labeled_block_value = blk: {
//    ^^^^^^^^^^^^^^^^^^^ (u8)(4)
    break :blk @as(u8, 4);
};

const labeled_block_same_value = blk: {
//    ^^^^^^^^^^^^^^^^^^^^^^^^ (u8)(4)
    if (runtime_condition) break :blk @as(u8, 4);
    break :blk @as(u8, 4);
};

const labeled_block_different_value = blk: {
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)()
    if (runtime_condition) break :blk @as(u8, 4);
    break :blk @as(u8, 5);
};

const labeled_block_switch = blk: {
//    ^^^^^^^^^^^^^^^^^^^^ (i64)()
    switch (@as(u8, 2)) {
        0 => break :blk @as(i32, 1),
        1...3 => break :blk @as(i64, 2),
        else => break :blk @as(u16, 3),
    }
};

const while_else_peer = while (runtime_condition) {
    if (runtime_condition) break @as(u8, 1);
    break @as(u16, 300);
} else @as(u8, 2);
const while_else_peer_type = while_else_peer;
//    ^^^^^^^^^^^^^^^^^^^^ (u16)()

const while_false_value = while (false) {
//    ^^^^^^^^^^^^^^^^^ (u8)(4)
    break @as(u16, 300);
} else @as(u8, 4);

const while_true_value = while (true) {
//    ^^^^^^^^^^^^^^^^ (u8)(4)
    break @as(u8, 4);
} else @as(u16, 300);

const while_false_void = while (false) {
//    ^^^^^^^^^^^^^^^^ (void)()
    unreachable;
};

const while_true_break_value = while (true) {
//    ^^^^^^^^^^^^^^^^^^^^^^ (u8)(4)
    break @as(u8, 4);
};

const while_true_noreturn = while (true) {};
//    ^^^^^^^^^^^^^^^^^^^ (noreturn)()

const for_else_peer = for ([_]u8{ 1, 2 }) |_| {
    if (runtime_condition) break @as(u8, 1);
    break @as(u16, 300);
} else @as(u8, 2);
const for_else_peer_type = for_else_peer;
//    ^^^^^^^^^^^^^^^^^^ (u16)()

const for_empty_else_value = for ([_]u8{}) |_| {
//    ^^^^^^^^^^^^^^^^^^^^ (u8)(4)
    break @as(u16, 300);
} else @as(u8, 4);

const for_empty_void = for ([_]u8{}) |_| {
//    ^^^^^^^^^^^^^^ (void)()
    unreachable;
};

const for_empty_range_else_value = for (4..4) |_| {
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)(4)
    break @as(u16, 300);
} else @as(u8, 4);

const for_empty_range_void = for (4..4) |_| {
//    ^^^^^^^^^^^^^^^^^^^^ (void)()
    unreachable;
};
// zig fmt: on

pub fn main() void {
    const return_block = {
        return;
    };
    _ = return_block;
    //  ^^^^^^^^^^^^ (noreturn)()

    for (0..1) |_| {
        const break_block = {
            break;
        };
        _ = break_block;
        //  ^^^^^^^^^^^ (noreturn)()

        const continue_block = {
            continue;
        };
        _ = continue_block;
        //  ^^^^^^^^^^^^^^ (noreturn)()
    }
}
