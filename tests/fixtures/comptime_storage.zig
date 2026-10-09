fn Result(comptime a: usize, comptime b: usize, comptime c: usize) type {
    return struct { first: [a]u8, second: [b]u8, third: [c]u8 };
}

pub fn successive_snapshots() type {
    var values = [3]usize{ 1, 2, 3 };
    values[0] = 4;
    values[1] = 5;
    const first = values;
    values[0] = 6;
    values[1] = 7;
    const second = values;
    values[0] = 8;
    values[1] = 9;
    return Result(first[0] + first[1], second[0] + second[1], values[0] + values[1]);
}

pub fn independent_cells() type {
    var values = [2]usize{ 1, 2 };
    values[0] = 3;
    var copy = values;
    copy[0] = 4;
    values[1] = 5;
    copy[1] = 6;
    return Result(values[0], values[1], copy[0] + copy[1]);
}

pub fn pointer_alias_and_snapshot() type {
    var values = [2]usize{ 1, 2 };
    const alias = &values;
    alias[0] = 3;
    const copy = alias.*;
    alias[0] = 4;
    values[1] = 5;
    return Result(copy[0] + copy[1], alias[0], alias[1]);
}

pub fn nested_child_snapshot() type {
    var values = [2][2]usize{ .{ 1, 2 }, .{ 3, 4 } };
    values[0][0] = 5;
    const row = values[0];
    const all = values;
    values[0][0] = 6;
    values[1][1] = 7;
    return Result(row[0], all[1][1], values[0][0] + values[1][1]);
}

pub fn nested_field_snapshot() type {
    const Item = struct { count: usize };
    var values = [2]Item{ .{ .count = 1 }, .{ .count = 2 } };
    values[0].count = 3;
    const item = values[0];
    values[0].count = 4;
    values[1].count = 5;
    return Result(item.count, values[0].count, values[1].count);
}

pub fn whole_array_replacement() type {
    var values = [2]usize{ 1, 2 };
    values[0] = 3;
    const first = values;
    values = .{ 4, 5 };
    values[0] = 6;
    const second = values;
    values = .{ 7, values[0] + 1 };
    return Result(first[0], second[0], values[1]);
}

fn readAndMutate(copy: [2]usize, pointer: *[2]usize) usize {
    pointer[0] = 8;
    pointer[1] = 9;
    return copy[0] + copy[1];
}

pub fn by_value_argument() type {
    var values = [2]usize{ 1, 2 };
    values[0] = 3;
    const sum = readAndMutate(values, &values);
    return Result(sum, values[0], values[1]);
}

pub fn captured_type_bindings() type {
    var values = [2]usize{ 1, 2 };
    values[0] = 3;
    const saved = values;
    const Saved = struct {
        fn sum() usize {
            return saved[0] + saved[1];
        }
    };
    values[0] = 4;
    values[1] = 5;
    return Result(Saved.sum(), values[0], values[1]);
}

pub fn snapshot_during_initializer() type {
    var values = [3]usize{ 1, 2, 3 };
    var saved: [3]usize = undefined;
    values = .{ 4, blk: {
        saved = values;
        break :blk 5;
    }, values[0] + 2 };
    return Result(saved[0] + saved[1], values[1], values[2]);
}

pub fn tuple_snapshot() type {
    const Pair = struct { usize, usize };
    var values: Pair = .{ 1, 2 };
    values[0] = 3;
    const saved = values;
    values[0] = 4;
    values[1] = 5;
    return Result(saved[0], values[0], values[1]);
}

pub fn vector_snapshot() type {
    var values: @Vector(2, usize) = .{ 1, 2 };
    values[0] = 3;
    const saved = values;
    values[0] = 4;
    values[1] = 5;
    return Result(saved[0], values[0], values[1]);
}

pub fn element_pointer() type {
    var values = [2]usize{ 1, 2 };
    values[0] = 3;
    const element = &values[0];
    const saved = values;
    element.* = 4;
    values[1] = 5;
    return Result(saved[0], element.*, values[1]);
}

pub fn early_return_snapshot() type {
    var values = [2]usize{ 1, 2 };
    values[0] = 3;
    const saved = values;
    values = .{ 4, return Result(saved[0], values[0], values[1]) };
}

pub fn loop_carried_values() type {
    var values: [8]usize = undefined;
    values[0] = 1;
    for (1..8) |index| values[index] = values[index - 1] + 1;
    const saved = values;
    for (0..8) |index| values[index] += 1;
    return Result(saved[7], values[0], values[7]);
}

pub fn effectful_index() type {
    var values = [2]usize{ 1, 2 };
    values[0] = 3;
    const saved = values;
    const selected = values[
        blk: {
            values[0] = 4;
            break :blk 0;
        }
    ];
    return Result(saved[0], selected, values[0]);
}

pub fn nested_effectful_index() type {
    var values = [2][2]usize{ .{ 1, 2 }, .{ 3, 4 } };
    values[0][0] = 5;
    const saved = values[0];
    const selected = values[0][
        blk: {
            values[0][0] = 6;
            break :blk 0;
        }
    ];
    return Result(saved[0], selected, values[0][0]);
}

pub fn temporary_effectful_index() type {
    var values = [2]usize{ 1, 2 };
    values[0] = 3;
    const selected = @as([2]usize, values)[
        blk: {
            values[0] = 4;
            break :blk 0;
        }
    ];
    return Result(selected, values[0], values[1]);
}

pub fn pointer_effectful_index() type {
    var values = [2]usize{ 1, 2 };
    values[0] = 3;
    const pointer = &values;
    const selected = pointer[
        blk: {
            values[0] = 4;
            break :blk 0;
        }
    ];
    return Result(selected, values[0], values[1]);
}

pub fn labeled_switch_array() type {
    var values = [2]usize{ 1, 2 };
    values[0] = 3;
    const selected = (next: switch (@as(u8, 0)) {
        0 => continue :next 1,
        else => values,
    })[
        blk: {
            values[0] = 4;
            break :blk 0;
        }
    ];
    return Result(selected, values[0], values[1]);
}

pub fn vector_effectful_index() type {
    var values: @Vector(2, usize) = .{ 1, 2 };
    values[0] = 3;
    const selected = values[
        blk: {
            values[0] = 4;
            break :blk 0;
        }
    ];
    return Result(selected, values[0], values[1]);
}
