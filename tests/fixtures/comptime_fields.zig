fn Result(comptime a: usize, comptime b: usize, comptime c: usize) type {
    return struct { first: [a]u8, second: [b]u8, third: [c]u8 };
}

const Wide = struct {
    field_0: usize = 1,
    field_1: usize = 2,
    field_2: usize = 3,
    field_3: usize = 4,
    field_4: usize = 5,
    field_5: usize = 6,
    field_6: usize = 7,
    field_7: usize = 8,
    field_8: usize = 9,
    field_9: usize = 10,
    field_10: usize = 11,
    field_11: usize = 12,
    field_12: usize = 13,
    field_13: usize = 14,
    field_14: usize = 15,
    field_15: usize = 16,
    field_16: usize = 17,
    field_17: usize = 18,
    field_18: usize = 19,
    field_19: usize = 20,
    field_20: usize = 21,
    field_21: usize = 22,
    field_22: usize = 23,
    field_23: usize = 24,
    field_24: usize = 25,
    field_25: usize = 26,
    field_26: usize = 27,
    field_27: usize = 28,
    field_28: usize = 29,
    field_29: usize = 30,
    field_30: usize = 31,
    field_31: usize = 32,
    pub const limit = 7;
};

pub fn wide_snapshots() type {
    var values: Wide = .{};
    values.field_31 = 40;
    values.field_0 = 2;
    const first = values;
    values.field_31 = 41;
    values.field_0 = 3;
    const second = values;
    values.field_31 = 42;
    return Result(first.field_31, second.field_31, values.field_31);
}

pub fn partial_values_and_defaults() type {
    var values: Wide = .{ .field_31 = 5, .field_0 = 6 };
    values.field_30 = 7;
    const saved = values;
    values.field_31 = 8;
    return Result(saved.field_31, values.field_30, values.field_1);
}

pub fn reordered_initializers() type {
    var values: Wide = .{
        .field_31 = 32,
        .field_30 = 31,
        .field_29 = 30,
        .field_28 = 29,
        .field_27 = 28,
        .field_26 = 27,
        .field_25 = 26,
        .field_24 = 25,
        .field_23 = 24,
        .field_22 = 23,
        .field_21 = 22,
        .field_20 = 21,
        .field_19 = 20,
        .field_18 = 19,
        .field_17 = 18,
        .field_16 = 17,
        .field_15 = 16,
        .field_14 = 15,
        .field_13 = 14,
        .field_12 = 13,
        .field_11 = 12,
        .field_10 = 11,
        .field_9 = 10,
        .field_8 = 9,
        .field_7 = 8,
        .field_6 = 7,
        .field_5 = 6,
        .field_4 = 5,
        .field_3 = 4,
        .field_2 = 3,
        .field_1 = 2,
        .field_0 = 1,
    };
    values.field_31 = 40;
    values.field_15 = 20;
    const saved = values;
    values.field_31 = 41;
    return Result(saved.field_31, values.field_15, values.field_0);
}

pub fn appended_fields() type {
    var values: Wide = .{};
    values.field_0 = 1;
    values.field_1 = 2;
    values.field_2 = 3;
    values.field_3 = 4;
    values.field_4 = 5;
    values.field_5 = 6;
    values.field_6 = 7;
    values.field_7 = 8;
    values.field_8 = 9;
    values.field_9 = 10;
    values.field_10 = 11;
    values.field_11 = 12;
    values.field_12 = 13;
    values.field_13 = 14;
    values.field_14 = 15;
    values.field_15 = 16;
    values.field_16 = 17;
    values.field_17 = 18;
    values.field_18 = 19;
    values.field_19 = 20;
    values.field_20 = 21;
    values.field_21 = 22;
    values.field_22 = 23;
    values.field_23 = 24;
    values.field_24 = 25;
    values.field_25 = 26;
    values.field_26 = 27;
    values.field_27 = 28;
    values.field_28 = 29;
    values.field_29 = 30;
    values.field_30 = 31;
    values.field_31 = 32;
    const saved = values;
    values.field_31 = 40;
    return Result(saved.field_31, values.field_31, values.field_0);
}

pub fn initializer_self_reads() type {
    var values: Wide = .{};
    values = .{
        .field_0 = 1,
        .field_1 = values.field_0 + 1,
        .field_2 = values.field_1 + 1,
        .field_3 = values.field_2 + 1,
        .field_4 = values.field_3 + 1,
        .field_5 = values.field_4 + 1,
        .field_6 = values.field_5 + 1,
        .field_7 = values.field_6 + 1,
        .field_8 = values.field_7 + 1,
        .field_9 = values.field_8 + 1,
        .field_10 = values.field_9 + 1,
        .field_11 = values.field_10 + 1,
        .field_12 = values.field_11 + 1,
        .field_13 = values.field_12 + 1,
        .field_14 = values.field_13 + 1,
        .field_15 = values.field_14 + 1,
        .field_16 = values.field_15 + 1,
        .field_17 = values.field_16 + 1,
        .field_18 = values.field_17 + 1,
        .field_19 = values.field_18 + 1,
        .field_20 = values.field_19 + 1,
        .field_21 = values.field_20 + 1,
        .field_22 = values.field_21 + 1,
        .field_23 = values.field_22 + 1,
        .field_24 = values.field_23 + 1,
        .field_25 = values.field_24 + 1,
        .field_26 = values.field_25 + 1,
        .field_27 = values.field_26 + 1,
        .field_28 = values.field_27 + 1,
        .field_29 = values.field_28 + 1,
        .field_30 = values.field_29 + 1,
        .field_31 = values.field_30 + 1,
    };
    return Result(values.field_0, values.field_15, values.field_31);
}

pub fn dynamic_field_names() type {
    var values: Wide = .{};
    const names = .{ "field_31", "field_0", "field_15" };
    for (names) |name| @field(values, name) += 1;
    const saved = values;
    @field(values, "field_31") += 1;
    return Result(saved.field_31, @field(values, "field_31"), @field(values, "field_15"));
}

pub fn builtin_assign_reads() type {
    var values: Wide = .{};
    const names = .{
        "field_0",  "field_1",  "field_2",  "field_3",  "field_4",  "field_5",  "field_6",  "field_7",
        "field_8",  "field_9",  "field_10", "field_11", "field_12", "field_13", "field_14", "field_15",
        "field_16", "field_17", "field_18", "field_19", "field_20", "field_21", "field_22", "field_23",
        "field_24", "field_25", "field_26", "field_27", "field_28", "field_29", "field_30", "field_31",
    };
    for (0..2) |_| {
        for (names) |name| @field(values, name) = @field(values, name) + 1;
    }
    const saved = values;
    @field(values, "field_31") = @field(values, "field_31") + 1;
    return Result(saved.field_31, values.field_31, values.field_15);
}

pub fn nested_wide_snapshot() type {
    var outer = struct { wide: Wide, count: usize }{ .wide = .{}, .count = 0 };
    outer.wide.field_31 = 40;
    const saved = outer.wide;
    outer.count = 1;
    outer.wide.field_31 = 41;
    return Result(saved.field_31, outer.wide.field_31, outer.count);
}

pub fn pointer_after_reordering() type {
    var values: Wide = .{};
    const pointer = &values.field_31;
    values.field_31 = 40;
    const saved = values;
    values = .{ .field_31 = 41, .field_0 = 2 };
    pointer.* += 1;
    return Result(saved.field_31, pointer.*, values.field_0);
}

pub fn generated_wide_type() type {
    const Generated = @Struct(
        .auto,
        null,
        &.{ "field_0", "field_1", "field_2", "field_3", "field_4", "field_5", "field_6", "field_7", "field_8", "field_9", "field_10", "field_11", "field_12", "field_13", "field_14", "field_15", "field_16", "field_17", "field_18", "field_19", "field_20", "field_21", "field_22", "field_23", "field_24", "field_25", "field_26", "field_27", "field_28", "field_29", "field_30", "field_31" },
        &([_]type{usize} ** 32),
        &([_]@import("std").builtin.Type.StructField.Attributes{.{ .default_value_ptr = &@as(usize, 1) }} ** 32),
    );
    var values: Generated = .{};
    values.field_31 = 40;
    const saved = values;
    values.field_0 = 2;
    values.field_31 = 41;
    return Result(saved.field_31, values.field_31, values.field_15);
}

pub fn quoted_fields() type {
    const Quoted = struct {
        @"space field": usize,
        @"quote\"field": usize,
        @"back\\slash": usize,
        field_0: usize = 0,
        field_1: usize = 0,
        field_2: usize = 0,
        field_3: usize = 0,
        field_4: usize = 0,
        field_5: usize = 0,
        field_6: usize = 0,
        field_7: usize = 0,
        field_8: usize = 0,
        field_9: usize = 0,
        field_10: usize = 0,
        field_11: usize = 0,
        field_12: usize = 0,
        field_13: usize = 0,
        field_14: usize = 0,
        field_15: usize = 0,
    };
    var values: Quoted = .{
        .@"space field" = 1,
        .@"quote\"field" = 2,
        .@"back\\slash" = 3,
        .field_0 = 0,
        .field_1 = 1,
        .field_2 = 2,
        .field_3 = 3,
        .field_4 = 4,
        .field_5 = 5,
        .field_6 = 6,
        .field_7 = 7,
        .field_8 = 8,
        .field_9 = 9,
        .field_10 = 10,
        .field_11 = 11,
        .field_12 = 12,
        .field_13 = 13,
        .field_14 = 14,
        .field_15 = 15,
    };
    @field(values, "quote\"field") = 4;
    const saved = values;
    @field(values, "space field") = 5;
    return Result(saved.@"space field", values.@"quote\"field", values.@"back\\slash");
}

fn counted(counter: *usize) [1]usize {
    counter.* += 1;
    return .{counter.*};
}

pub fn repeated_array_pointer() type {
    var count: usize = 0;
    const pointer = &(counted(&count) ** 2);
    return Result(pointer[0], pointer[1], count);
}

pub fn concatenated_array_pointer() type {
    var count: usize = 0;
    const pointer = &(counted(&count) ++ counted(&count));
    return Result(pointer[0], pointer[1], count);
}
