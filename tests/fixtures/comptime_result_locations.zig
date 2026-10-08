fn Result(comptime a: usize, comptime b: usize, comptime c: usize) type {
    return struct { first: [a]u8, second: [b]u8, third: [c]u8 };
}

const State = struct { a: usize, b: usize, c: usize = 3 };

pub fn array_assignment() type {
    var values = [2]usize{ 1, 2 };
    values = .{ values[1], values[0] };
    return Result(values[0], values[1], 0);
}

pub fn typed_array_assignment() type {
    var values = [2]usize{ 1, 2 };
    values = [2]usize{ values[1], values[0] };
    return Result(values[0], values[1], 0);
}

pub fn struct_assignment() type {
    var state = State{ .a = 1, .b = 2, .c = 9 };
    state = .{ .b = state.a, .a = state.b + state.c };
    return Result(state.a, state.b, state.c);
}

pub fn typed_struct_assignment() type {
    var state = State{ .a = 1, .b = 2, .c = 9 };
    state = State{ .b = state.a, .a = state.b + state.c };
    return Result(state.a, state.b, state.c);
}

pub fn array_element_types() type {
    const n: u32 = 4;
    const values: [2]u8 = .{ @intCast(n), @intCast(n + 1) };
    return Result(values[0], values[1], 0);
}

pub fn tuple_element_types() type {
    const Pair = struct { u8, u16 };
    const n: u32 = 4;
    const values: Pair = .{ @intCast(n), @intCast(n + 1) };
    return Result(values[0], values[1], 0);
}

pub fn optional_array_element_types() type {
    const n: u32 = 4;
    const values: ?[2]u8 = .{ @intCast(n), @intCast(n + 1) };
    return Result(values.?[0], values.?[1], 0);
}

pub fn undefined_array_assignment() type {
    const n: u32 = 4;
    var values: [2]u8 = undefined;
    values = .{ @intCast(n), values[0] + 1 };
    return Result(values[0], values[1], 0);
}

pub fn undefined_struct_assignment() type {
    var state: State = undefined;
    state = .{ .a = 4, .b = state.a + 1 };
    return Result(state.a, state.b, state.c);
}

pub fn nested_assignment() type {
    var state = struct { values: [2]usize, count: usize }{ .values = .{ 1, 2 }, .count = 0 };
    state = .{ .values = .{ state.values[1], state.values[0] }, .count = state.values[1] };
    return Result(state.values[0], state.values[1], state.count);
}

pub fn deferred_assignment() type {
    var values = [2]usize{ 1, 2 };
    values = blk: {
        defer values[0] += 1;
        break :blk .{ values[1], values[0] };
    };
    return Result(values[0], values[1], 0);
}

pub fn early_return() type {
    var values = [2]usize{ 1, 2 };
    values = .{ 7, return Result(values[0], values[1], 0) };
}

pub fn destructured_array_assignment() type {
    var values = [2]usize{ 1, 2 };
    values, _ = .{ .{ values[1], values[0] }, 0 };
    return Result(values[0], values[1], 0);
}

pub fn scalar_defer() type {
    var value: usize = 1;
    value = blk: {
        defer value += 1;
        break :blk 2;
    };
    return Result(value, 0, 0);
}

pub fn later_field_mutation() type {
    var state = State{ .a = 1, .b = 2 };
    state = .{ .a = 4, .b = blk: {
        state.a += 1;
        break :blk 6;
    } };
    return Result(state.a, state.b, state.c);
}

pub fn optional_array_assignment() type {
    var values: ?[2]usize = null;
    values = .{ 4, values.?[0] + 1 };
    return Result(values.?[0], values.?[1], 0);
}

pub fn error_union_array_assignment() type {
    var values: error{Missing}![2]usize = error.Missing;
    values = .{ 4, (values catch unreachable)[0] + 1 };
    const result = values catch unreachable;
    return Result(result[0], result[1], 0);
}

pub fn nested_wrapped_assignment() type {
    var values: ?(error{Missing}![2]usize) = null;
    values = .{ 4, (values.? catch unreachable)[0] + 1 };
    const result = values.? catch unreachable;
    return Result(result[0], result[1], 0);
}

pub fn union_assignment() type {
    const Payload = union(enum) { values: [2]usize, empty };
    var payload = Payload{ .empty = {} };
    payload = .{ .values = .{ 4, payload.values[0] + 1 } };
    return Result(payload.values[0], payload.values[1], 0);
}

pub fn tuple_assignment() type {
    const Pair = struct { usize, usize };
    var values = Pair{ 1, 2 };
    values = .{ values[1], values[0] };
    return Result(values[0], values[1], 0);
}

pub fn vector_assignment() type {
    var values: @Vector(2, usize) = .{ 1, 2 };
    values = .{ values[1], values[0] };
    return Result(values[0], values[1], 0);
}

pub fn as_assignment() type {
    var values = [2]usize{ 1, 2 };
    values = @as([2]usize, .{ values[1], values[0] });
    return Result(values[0], values[1], 0);
}

fn reverse(values: *[2]usize) [2]usize {
    return .{ values[1], values[0] };
}

pub fn returned_array_assignment() type {
    var values = [2]usize{ 1, 2 };
    values = reverse(&values);
    return Result(values[0], values[1], 0);
}

pub fn generated_struct_assignment() type {
    const Generated = @Struct(.auto, null, &.{ "a", "b", "c" }, &.{ usize, usize, usize }, &.{
        .{}, .{}, .{ .default_value_ptr = &@as(usize, 3) },
    });
    var state = Generated{ .a = 1, .b = 2, .c = 9 };
    state = .{ .b = state.a, .a = state.b + state.c };
    return Result(state.a, state.b, state.c);
}

pub fn nested_result_control_flow() type {
    var values = [2]usize{ 1, 2 };
    values = if (true) for (0..1) |_| {
        break blk: {
            break :blk .{ values[1], values[0] };
        };
    } else unreachable else unreachable;
    return Result(values[0], values[1], 0);
}

pub fn scalar_field_defer() type {
    var state = State{ .a = 1, .b = 2 };
    state = .{ .a = blk: {
        defer state.a += 1;
        break :blk 4;
    }, .b = state.a };
    return Result(state.a, state.b, state.c);
}

pub fn opaque_array_result() type {
    var values = [2]usize{ 1, 2 };
    values = blk: {
        defer values[0] += 1;
        break :blk values;
    };
    return Result(values[0], values[1], 0);
}

pub fn nested_loop_result() type {
    var values = [2]usize{ 1, 2 };
    values = blk: {
        _ = while (true) {
            break .{ 7, 8 };
        };
        defer values[0] += 1;
        break :blk values;
    };
    return Result(values[0], values[1], 0);
}
