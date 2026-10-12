fn Result(comptime first: usize, comptime second: usize, comptime third: usize) type {
    return struct { first: [first]u8, second: [second]u8, third: [third]u8 };
}

pub fn source_struct_payload() type {
    const Item = struct { count: usize };
    const Tag = enum { item, empty };
    const U = @Union(.auto, Tag, &.{ "item", "empty" }, &.{ Item, void }, &.{ .{}, .{} });
    const value: U = .{ .item = .{ .count = 3 } };
    return Result(value.item.count, @intFromBool(@FieldType(U, "item") == Item), @intFromBool(@typeInfo(U).@"union".fields[0].type == Item));
}

pub fn source_enum_payload() type {
    const Item = enum(u8) { first = 3, second = 7 };
    const Tag = enum { item, empty };
    const U = @Union(.auto, Tag, &.{ "item", "empty" }, &.{ Item, void }, &.{ .{}, .{} });
    const value = U{ .item = .second };
    return Result(@intFromEnum(value.item), @intFromBool(@FieldType(U, "item") == Item), @intFromBool(@TypeOf(value.item) == Item));
}

pub fn optional_source_payload() type {
    const Item = struct { count: usize };
    const Tag = enum { item, empty };
    const U = @Union(.auto, Tag, &.{ "item", "empty" }, &.{ ?Item, void }, &.{ .{}, .{} });
    const value = U{ .item = .{ .count = 5 } };
    return Result(value.item.?.count, @intFromBool(@FieldType(U, "item") == ?Item), @intFromBool(@TypeOf(value.item.?) == Item));
}

pub fn source_array_payload() type {
    const Item = struct { count: usize };
    const Tag = enum { item, empty };
    const U = @Union(.auto, Tag, &.{ "item", "empty" }, &.{ [1]Item, void }, &.{ .{}, .{} });
    const value = U{ .item = .{.{ .count = 7 }} };
    return Result(value.item[0].count, @intFromBool(@FieldType(U, "item") == [1]Item), @intFromBool(@TypeOf(value.item[0]) == Item));
}

pub fn untagged_source_payload() type {
    const Item = struct { count: usize };
    const U = @Union(.auto, null, &.{ "item", "empty" }, &.{ Item, void }, &.{ .{}, .{} });
    var executions: usize = 0;
    const value = U{ .item = .{ .count = block: {
        executions += 1;
        break :block 9;
    } } };
    return Result(value.item.count, @intFromBool(@FieldType(U, "item") == Item), executions);
}

pub fn source_union_payload() type {
    const Item = union(enum) { count: usize, empty };
    const Tag = enum { item, empty };
    const U = @Union(.auto, Tag, &.{ "item", "empty" }, &.{ Item, void }, &.{ .{}, .{} });
    const value = U{ .item = .{ .count = 11 } };
    const count = switch (value.item) {
        .count => |n| n,
        .empty => 0,
    };
    return Result(count, @intFromBool(@FieldType(U, "item") == Item), @intFromBool(@typeInfo(U).@"union".fields[0].type == Item));
}

pub fn source_payload_switch_capture() type {
    const Item = struct { count: usize };
    const Tag = enum { item, empty };
    const U = @Union(.auto, Tag, &.{ "item", "empty" }, &.{ Item, void }, &.{ .{}, .{} });
    const value = U{ .item = .{ .count = 13 } };
    const count = switch (value) {
        .item => |item| item.count,
        .empty => 0,
    };
    return Result(count, @intFromBool(@FieldType(U, "item") == Item), 0);
}

pub fn source_payload_union_init() type {
    const Item = struct { count: usize };
    const Tag = enum { item, empty };
    const U = @Union(.auto, Tag, &.{ "item", "empty" }, &.{ Item, void }, &.{ .{}, .{} });
    const value = @unionInit(U, "item", .{ .count = 15 });
    return Result(value.item.count, @intFromBool(@FieldType(U, "item") == Item), @intFromBool(@TypeOf(value.item) == Item));
}

pub fn generic_source_payload() type {
    return PayloadFor(u16);
}

fn PayloadFor(comptime Count: type) type {
    const Item = struct { count: Count };
    const Tag = enum { item, empty };
    const U = @Union(.auto, Tag, &.{ "item", "empty" }, &.{ Item, void }, &.{ .{}, .{} });
    const value = U{ .item = .{ .count = 17 } };
    return Result(value.item.count, @intFromBool(@FieldType(U, "item") == Item), @intFromBool(@FieldType(@FieldType(U, "item"), "count") == Count));
}

pub fn payload_field_array_alias() type {
    const A = struct { count: usize };
    const B = struct { count: usize };
    var fields = [_]type{ A, void };
    const Tag = enum { item, empty };
    const U = @Union(.auto, Tag, &.{ "item", "empty" }, &fields, attributes: {
        fields[0] = B;
        break :attributes &.{ .{}, .{} };
    });
    const value = U{ .item = .{ .count = 19 } };
    return Result(value.item.count, @intFromBool(@FieldType(U, "item") == B), @intFromBool(@FieldType(U, "item") != A));
}

pub fn packed_source_payload() type {
    const Item = packed struct { low: u3, high: u5 };
    const U = @Union(.@"packed", null, &.{ "item", "raw" }, &.{ Item, u8 }, &.{ .{}, .{} });
    var executions: usize = 0;
    const value = U{ .item = .{ .low = 3, .high = block: {
        executions += 1;
        break :block 4;
    } } };
    return Result(value.item.low + @as(usize, value.item.high), @intFromBool(@FieldType(U, "item") == Item), @bitSizeOf(U));
}

pub fn error_source_payload() type {
    const Item = struct { count: usize };
    const Tag = enum { item, empty };
    const U = @Union(.auto, Tag, &.{ "item", "empty" }, &.{ error{Missing}!Item, void }, &.{ .{}, .{} });
    const value = U{ .item = .{ .count = 21 } };
    const item = value.item catch unreachable;
    return Result(item.count, @intFromBool(@FieldType(U, "item") == error{Missing}!Item), @intFromBool(@TypeOf(item) == Item));
}

pub fn nested_generated_payload() type {
    const Item = struct { count: usize };
    const InnerTag = enum { item, empty };
    const Inner = @Union(.auto, InnerTag, &.{ "item", "empty" }, &.{ Item, void }, &.{ .{}, .{} });
    const OuterTag = enum { inner, empty };
    const Outer = @Union(.auto, OuterTag, &.{ "inner", "empty" }, &.{ Inner, void }, &.{ .{}, .{} });
    const value = Outer{ .inner = .{ .item = .{ .count = 23 } } };
    return Result(value.inner.item.count, @intFromBool(@FieldType(Inner, "item") == Item), @intFromBool(@FieldType(Outer, "inner") == Inner));
}

const GlobalItem = struct { count: usize };
const GlobalPayload = @Union(.auto, null, &.{ "item", "empty" }, &.{ GlobalItem, void }, &.{ .{}, .{} });

pub fn global_source_union_init() type {
    const value = @unionInit(GlobalPayload, "item", GlobalItem{ .count = 25 });
    return Result(value.item.count, @intFromBool(@FieldType(GlobalPayload, "item") == GlobalItem), @intFromBool(@TypeOf(value.item) == GlobalItem));
}

pub fn global_source_union_literal() type {
    const value: GlobalPayload = .{ .item = .{ .count = 27 } };
    return Result(value.item.count, @intFromBool(@FieldType(GlobalPayload, "item") == GlobalItem), @intFromBool(@TypeOf(value.item) == GlobalItem));
}
