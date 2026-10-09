fn Result(comptime a: usize, comptime b: usize, comptime c: usize) type {
    return struct { first: [a]u8, second: [b]u8, third: [c]u8 };
}

pub fn struct_field_snapshot() type {
    var state = struct { left: [2]usize, right: [2]usize }{ .left = .{ 1, 2 }, .right = .{ 3, 4 } };
    state.left[0] = 5;
    state.right[0] = 6;
    const left = state.left;
    state.left[0] = 7;
    const all = state;
    state.right[0] = 8;
    return Result(left[0], all.right[0], state.left[0] + state.right[0]);
}

pub fn matrix_row_snapshot() type {
    var values = [_][2]usize{.{ 1, 2 }} ** 3;
    values[0][0] = 3;
    values[0][1] = 4;
    const row = values[0];
    values[0][0] = 5;
    values[1][0] = 6;
    return Result(row[0] + row[1], values[0][0] + values[1][0], values[2][0]);
}

pub fn sibling_array_copy() type {
    var state = struct { left: [2]usize, right: [2]usize }{ .left = .{ 1, 2 }, .right = .{ 3, 4 } };
    state.left[0] = 5;
    state.right = state.left;
    state.left[0] = 6;
    state.right[1] = 7;
    return Result(state.left[0], state.right[0], state.left[1] + state.right[1]);
}

pub fn optional_payload_snapshot() type {
    var values: ?[2]usize = .{ 1, 2 };
    values.?[0] = 3;
    values.?[1] = 4;
    const saved = values.?;
    values.?[0] = 5;
    const wrapper = values;
    values = null;
    values = .{ 6, 7 };
    values.?[0] = 8;
    return Result(saved[0] + saved[1], wrapper.?[0], values.?[0]);
}

pub fn error_payload_snapshot() type {
    var values: error{Missing}![2]usize = .{ 1, 2 };
    const pointer = if (values) |*payload| payload else |_| unreachable;
    pointer[0] = 3;
    pointer[1] = 4;
    const saved = pointer.*;
    pointer[0] = 5;
    const wrapper = values;
    values = error.Missing;
    values = .{ 6, 7 };
    pointer[0] = 8;
    return Result(saved[0] + saved[1], (wrapper catch unreachable)[0], pointer[0]);
}

pub fn union_payload_snapshot() type {
    const Payload = union(enum) { values: [2]usize, empty };
    var payload = Payload{ .values = .{ 1, 2 } };
    payload.values[0] = 3;
    payload.values[1] = 4;
    const saved = payload.values;
    const wrapper = payload;
    payload.values[0] = 5;
    payload = .empty;
    payload = .{ .values = .{ 6, 7 } };
    payload.values[0] = 8;
    return Result(saved[0] + saved[1], wrapper.values[0], payload.values[0]);
}

pub fn tuple_child_snapshot() type {
    const Pair = struct { [2]usize, ?[2]usize };
    var values: Pair = .{ .{ 1, 2 }, .{ 3, 4 } };
    values[0][0] = 5;
    values[1].?[0] = 6;
    const saved = values[1].?;
    values[1].?[0] = 7;
    values[0][1] = 8;
    return Result(saved[0], values[1].?[0], values[0][0] + values[0][1]);
}

pub fn array_of_structs() type {
    const Item = struct { count: usize, values: [2]usize };
    var items = [_]Item{.{ .count = 1, .values = .{ 2, 3 } }} ** 4;
    for (&items) |*item| {
        item.count += 1;
        item.values[0] += 2;
        item.values[1] += 3;
    }
    const saved = items[0];
    items[0].count = 7;
    items[0].values[0] = 8;
    return Result(saved.count + saved.values[0], items[0].count, items[1].values[0]);
}

pub fn undefined_struct_array() type {
    var state: struct { values: [4]usize } = .{ .values = undefined };
    state.values[0] = 1;
    for (1..4) |index| state.values[index] = state.values[index - 1] + 1;
    return Result(state.values[0], state.values[2], state.values[3]);
}

pub fn undefined_matrix() type {
    var values: [2][2]usize = undefined;
    values[0][0] = 1;
    values[0][1] = 2;
    values[1][0] = 3;
    values[1][1] = 4;
    const saved = values[0];
    values[0][0] = 5;
    return Result(saved[0], values[0][0], values[1][1]);
}

pub fn undefined_nested_struct() type {
    const Inner = struct { first: usize, second: usize };
    var state: struct { inner: Inner } = .{ .inner = undefined };
    state.inner.first = 1;
    state.inner.second = 2;
    const saved = state.inner;
    state.inner.first = 3;
    state.inner.second = 4;
    return Result(saved.first + saved.second, state.inner.first, state.inner.second);
}

pub fn nested_pointer_alias() type {
    var values = [2][2]usize{ .{ 1, 2 }, .{ 3, 4 } };
    const row = &values[0];
    row[0] = 5;
    row[1] = 6;
    const saved = row.*;
    values[0] = .{ 7, 8 };
    row[0] = 9;
    return Result(saved[0] + saved[1], row[0], values[0][1]);
}

pub fn nested_aggregate_argument() type {
    var values = [2][2]usize{ .{ 1, 2 }, .{ 3, 4 } };
    values[0][0] = 5;
    const sum = update(values[0], &values[0]);
    return Result(sum, values[0][0], values[1][0]);
}

fn update(saved: [2]usize, values: *[2]usize) usize {
    values[0] = 6;
    values[1] = 7;
    return saved[0] + saved[1];
}

pub fn nested_initializer_snapshot() type {
    var state = struct { values: [3]usize }{ .values = .{ 1, 2, 3 } };
    var saved: [3]usize = undefined;
    state.values = .{ 4, blk: {
        saved = state.values;
        break :blk 5;
    }, state.values[0] + 2 };
    return Result(saved[0] + saved[1], state.values[1], state.values[2]);
}
