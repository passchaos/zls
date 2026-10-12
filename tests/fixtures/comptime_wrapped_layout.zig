fn Result(comptime first: usize, comptime second: usize, comptime third: usize) type {
    return struct { first: [first]u8, second: [second]u8, third: [third]u8 };
}

fn Layout(comptime T: type) type {
    return Result(@sizeOf(T), @alignOf(T), @bitSizeOf(T));
}

pub fn optional_integer() type {
    return Layout(?u32);
}
pub fn optional_small_integer() type {
    return Layout(?u3);
}
pub fn optional_abi_padding() type {
    return Layout(?u24);
}
pub fn optional_boolean() type {
    return Layout(?bool);
}
pub fn optional_void() type {
    return Layout(?void);
}
pub fn optional_zero_integer() type {
    return Layout(?u0);
}
pub fn optional_noreturn() type {
    return Layout(?noreturn);
}
pub fn optional_error_set() type {
    return Layout(?error{Missing});
}
pub fn optional_empty_error_set() type {
    return Layout(?error{});
}
pub fn error_union_noreturn() type {
    return Layout(error{Missing}!noreturn);
}
pub fn error_union_empty_noreturn() type {
    return Layout(error{}!noreturn);
}
pub fn optional_pointer() type {
    return Layout(?*u8);
}
pub fn optional_many_pointer() type {
    return Layout(?[*]u8);
}
pub fn optional_c_pointer() type {
    return Layout(?[*c]u8);
}
pub fn optional_allowzero_pointer() type {
    return Layout(?*allowzero u8);
}
pub fn optional_slice() type {
    return Layout(?[]u8);
}
pub fn optional_nested() type {
    return Layout(??u32);
}
pub fn optional_array() type {
    return Layout(?[3]u8);
}
pub fn optional_source_struct() type {
    return Layout(?extern struct { a: u32, b: u8 });
}
pub fn optional_packed_struct() type {
    return Layout(?packed struct { a: u17 });
}
pub fn optional_source_union() type {
    return Layout(?union(enum) { a: u8, b: u32 });
}
pub fn optional_generated_union() type {
    const U = @Union(.auto, @Enum(u8, .exhaustive, &.{ "a", "b" }, &.{ 0, 1 }), &.{ "a", "b" }, &.{ u8, u32 }, &.{ .{}, .{} });
    return Layout(?U);
}
pub fn optional_generic_payload() type {
    const Small = Optional(u8);
    const Large = Optional(u32);
    return Result(@sizeOf(Small), @sizeOf(Large), @alignOf(Large));
}
fn Optional(comptime T: type) type {
    return ?T;
}

pub fn error_union_integer() type {
    return Layout(error{Missing}!u32);
}
pub fn error_union_small_integer() type {
    return Layout(error{Missing}!u3);
}
pub fn error_union_void() type {
    return Layout(error{Missing}!void);
}
pub fn error_union_empty_set() type {
    return Layout(error{}!u32);
}
pub fn error_union_pointer() type {
    return Layout(anyerror!*u8);
}
pub fn error_union_array() type {
    return Layout(error{Missing}![3]u8);
}
pub fn error_union_packed_struct() type {
    return Layout(error{Missing}!packed struct { a: u17 });
}
pub fn error_union_nested_optional() type {
    return Layout(error{Missing}!?u32);
}
pub fn optional_error_union() type {
    return Layout(?(error{Missing}!u32));
}
pub fn error_union_source_union() type {
    return Layout(error{Missing}!union(enum) { a: u8, b: u32 });
}
pub fn error_sets() type {
    return Result(@sizeOf(error{Missing}), @alignOf(anyerror), @bitSizeOf(error{ Missing, Invalid }));
}

pub fn wrapped_union_fields() type {
    const U = union(enum) { optional: ?u32, fallible: error{Missing}!u8 };
    return Layout(U);
}
pub fn wrapped_struct_fields() type {
    const S = struct { first: ?u32, second: ?u32 };
    return Layout(S);
}
pub fn wrapped_layout_effects() type {
    var executions: usize = 0;
    const size = @sizeOf(block: {
        executions += 1;
        break :block ?u32;
    });
    const bits = @bitSizeOf(block: {
        executions += 1;
        break :block error{Missing}!u32;
    });
    return Result(size, bits, executions);
}

fn Nested(comptime depth: usize) type {
    var T: type = u32;
    for (0..depth) |_| T = ?T;
    return T;
}
pub fn deeply_nested_optional() type {
    return Layout(Nested(24));
}

pub fn successive_wrapped_payloads() type {
    var T: type = u8;
    const first = @sizeOf(?T);
    T = u32;
    const second = @sizeOf(?T);
    return Result(first, second, @sizeOf(error{Missing}!T));
}

pub fn generated_wrapped_fields() type {
    const S = @Struct(.auto, null, &.{ "first", "second" }, &.{ ?u32, ?u32 }, &.{ .{}, .{} });
    const U = @Union(.auto, @Enum(u8, .exhaustive, &.{ "first", "second" }, &.{ 0, 1 }), &.{ "first", "second" }, &.{ ?u32, error{Missing}!u8 }, &.{ .{}, .{} });
    return Result(@sizeOf(S), @sizeOf(U), @alignOf(U));
}

pub fn aligned_zero_optional() type {
    return Layout(?[0]u128);
}
pub fn aligned_zero_error_union() type {
    return Layout(error{Missing}![0]u128);
}
pub fn optional_comptime_bits() type {
    return Result(@alignOf(?type), @bitSizeOf(?type), @bitSizeOf(?comptime_int));
}
pub fn error_union_comptime_bits() type {
    return Result(@alignOf(error{Missing}!type), @bitSizeOf(error{Missing}!type), @bitSizeOf(error{Missing}!comptime_int));
}
pub fn optional_uninstantiable_union() type {
    return Layout(?union {});
}
pub fn optional_uninstantiable_struct() type {
    return Layout(?struct { a: noreturn, b: u64 });
}
pub fn nested_uninstantiable_optional() type {
    return Layout(??noreturn);
}
pub fn optional_allowzero_slice() type {
    return Layout(?[]allowzero u8);
}
pub fn nested_optional_error_set() type {
    return Layout(??error{Missing});
}
pub fn optional_zero_comptime_array() type {
    return Layout(?[0]type);
}
pub fn optional_pointer_zero_payload() type {
    return Layout(?*[0]u128);
}
pub fn optional_comptime_container_bits() type {
    const S = struct { a: type, b: u32 };
    const U = union(enum) { a: type, b: u32 };
    return Result(@bitSizeOf(?S), @bitSizeOf(?U), @alignOf(?S));
}
pub fn error_union_comptime_container_bits() type {
    const S = struct { a: type, b: u32 };
    return Result(@bitSizeOf(error{Missing}!S), @alignOf(error{Missing}!S), @bitSizeOf(?[1]type));
}
pub fn nested_comptime_error_union_bits() type {
    const E = error{Missing};
    return Result(@bitSizeOf(?(E!type)), @bitSizeOf(??(E!type)), @bitSizeOf(E!?type));
}
pub fn optional_error_union_uninstantiable() type {
    return Layout(?(error{}!noreturn));
}
pub fn error_union_empty_union() type {
    return Layout(error{Missing}!union {});
}
fn Alternating(comptime depth: usize) type {
    var T: type = u32;
    for (0..depth) |_| T = @Union(.auto, null, &.{"payload"}, &.{?T}, &.{.{}});
    return T;
}
pub fn alternating_wrapped_unions() type {
    return Layout(Alternating(14));
}
