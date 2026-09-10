const OptionalType = ?u32;
//    ^^^^^^^^^^^^ (type)()

const InvalidOptionalTypeUnwrap = OptionalType.?;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^ (unknown)()

const alpha: ?u32 = undefined;
//    ^^^^^ (?u32)()

const beta = alpha.?;
//    ^^^^ (u32)()

const gamma = if (alpha) |value| value else null;
//                        ^^^^^ (u32)()

const delta = alpha orelse unreachable;
//    ^^^^^ (u32)()

const epsilon = alpha.?;
//    ^^^^^^^ (u32)()

const zeta = alpha orelse null;
// TODO   ^^^^ (?u32)()

const eta = alpha orelse 5;
//    ^^^ (u32)()

var runtime_optional_u8: ?u8 = null;
var runtime_optional_bool: ?bool = null;
var pointer_storage: u8 = 0;
var runtime_optional_pointer: ?*u8 = &pointer_storage;
var runtime_optional_f32: ?f32 = null;
const undefined_optional_u8: ?u8 = undefined;

const optional_integer_self_equal = runtime_optional_u8 == runtime_optional_u8;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)(true)
const optional_integer_self_not_equal = runtime_optional_u8 != runtime_optional_u8;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)(false)
const optional_bool_self_equal = runtime_optional_bool == runtime_optional_bool;
//    ^^^^^^^^^^^^^^^^^^^^^^^^ (bool)(true)
const optional_pointer_self_equal = runtime_optional_pointer == runtime_optional_pointer;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)(true)
const optional_float_self_equal = runtime_optional_f32 == runtime_optional_f32;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)()
const undefined_optional_self_equal = undefined_optional_u8 == undefined_optional_u8;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)()

fn orelse_0() void {
    const foo: ?i32 = 5;
    const bar = foo orelse 0;
    //    ^^^ (i32)()
    _ = bar;
}

fn orelse_1() void {
    const foo: ?i32 = 5;
    const bar = foo orelse foo;
    //    ^^^ (i32)(5)
    _ = bar;
}

fn orelse_2() void {
    const foo: ?i32 = 5;
    const bar = foo orelse unreachable;
    //    ^^^ (i32)()
    _ = bar;
}

fn orelse_3(a: ?i32) void {
    const bar = a orelse return;
    //    ^^^ (i32)()
    _ = bar;
}

fn orelse_4() void {
    const array: [1]?i32 = [1]?i32{4};
    for (array) |elem| {
        const bar = elem orelse continue;
        //    ^^^ (i32)()
        _ = bar;
    }
}

fn orelse_5() void {
    var value: u32 = 123;
    const ptr: [*c]u32 = &value;
    const foo = ptr orelse unreachable;
    //    ^^^ ([*c]u32)()
    _ = foo;
}

fn orelse_6() void {
    const S = struct {
        alpha: u32,
    };
    const v: ?*const S = &S{ .alpha = 5 };
    const foo = v orelse {
        return;
    };
    _ = foo;
    //  ^^^ (*const S)()
}
