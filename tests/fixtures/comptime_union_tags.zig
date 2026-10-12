fn Result(comptime first: usize, comptime second: usize, comptime third: usize) type {
    return struct { first: [first]u8, second: [second]u8, third: [third]u8 };
}

pub fn explicit_source_tag() type {
    const Tag = enum(u8) { first = 3, second = 7 };
    const U = @Union(.auto, Tag, &.{ "first", "second" }, &.{ u8, u16 }, &.{ .{}, .{} });
    const value = U{ .second = 300 };
    const tag: Tag = value;
    const fields = @typeInfo(U).@"union".fields;
    return Result(@intFromEnum(tag), @intFromBool(@typeInfo(U).@"union".tag_type.? == Tag), @intFromBool(fields[0].name[0] == 'f' and @FieldType(U, "second") == u16));
}

pub fn explicit_generated_tag() type {
    const Tag = @Enum(u8, .exhaustive, &.{ "first", "second" }, &.{ 3, 7 });
    const U = @Union(.auto, Tag, &.{ "first", "second" }, &.{ u8, u16 }, &.{ .{}, .{} });
    const value = U{ .first = 3 };
    const tag: Tag = value;
    return Result(@intFromEnum(tag), @intFromBool(@typeInfo(U).@"union".tag_type.? == Tag), @intFromBool(@FieldType(U, "first") == u8));
}

pub fn sparse_source_tag() type {
    const Tag = enum(u8) { first = 3, second = 7 };
    const U = @Union(.auto, Tag, &.{ "first", "second" }, &.{ u8, u16 }, &.{ .{}, .{} });
    const value = U{ .second = 300 };
    const tag: Tag = value;
    return Result(@intFromEnum(tag), @bitSizeOf(Tag), @intFromBool(@typeInfo(U).@"union".tag_type.? == Tag));
}

pub fn signed_source_tag() type {
    const Tag = enum(i8) { first = -3, second = 7 };
    const U = @Union(.auto, Tag, &.{ "first", "second" }, &.{ u8, u16 }, &.{ .{}, .{} });
    const value = U{ .first = 3 };
    const tag: Tag = value;
    return Result(@intFromBool(@intFromEnum(tag) == -3), @intFromBool(@TypeOf(@intFromEnum(tag)) == i8), @intFromBool(@typeInfo(U).@"union".tag_type.? == Tag));
}

pub fn switch_source_tag() type {
    const Tag = enum(u8) { first = 3, second = 7 };
    const U = @Union(.auto, Tag, &.{ "first", "second" }, &.{ u8, u16 }, &.{ .{}, .{} });
    const value = U{ .second = 300 };
    const payload = switch (value) {
        .first => |item| item,
        inline else => |item, tag| item + @intFromEnum(tag),
    };
    return Result(payload, @intFromBool(@FieldType(U, "second") == u16), 0);
}

pub fn independent_source_tags() type {
    const A = enum(u8) { first = 3, second = 7 };
    const B = enum(u8) { first = 3, second = 7 };
    const UA = @Union(.auto, A, &.{ "first", "second" }, &.{ u8, u16 }, &.{ .{}, .{} });
    const UB = @Union(.auto, B, &.{ "first", "second" }, &.{ u8, u16 }, &.{ .{}, .{} });
    return Result(@intFromBool(@typeInfo(UA).@"union".tag_type.? == A), @intFromBool(@typeInfo(UB).@"union".tag_type.? == B), @intFromBool(@typeInfo(UA).@"union".tag_type.? != @typeInfo(UB).@"union".tag_type.?));
}

pub fn auto_union_tag_identity() type {
    const Base = union(enum) { first: u8, second: u16 };
    const Tag = @typeInfo(Base).@"union".tag_type.?;
    const U = @Union(.auto, Tag, &.{ "first", "second" }, &.{ u8, u16 }, &.{ .{}, .{} });
    const tag: Tag = U{ .second = 300 };
    return Result(@intFromBool(@typeInfo(U).@"union".tag_type.? == Tag), @intFromEnum(tag), @intFromBool(@TypeOf(tag) == Tag));
}

pub fn meta_union_tag_identity() type {
    const std = @import("std");
    const Base = union(enum) { first: u8, second: u16 };
    const Tag = std.meta.Tag(Base);
    const U = @Union(.auto, Tag, &.{ "first", "second" }, &.{ u8, u16 }, &.{ .{}, .{} });
    const tag: Tag = U{ .first = 3 };
    return Result(@intFromBool(std.meta.Tag(U) == Tag), @intFromEnum(tag), @intFromBool(@TypeOf(tag) == Tag));
}

pub fn captured_auto_union_tag() type {
    return autoTagFactory(u8);
}

fn autoTagFactory(comptime Item: type) type {
    const Base = union(enum) { first: Item, second: u16 };
    const Tag = @typeInfo(Base).@"union".tag_type.?;
    const U = @Union(.auto, Tag, &.{ "first", "second" }, &.{ Item, u16 }, &.{ .{}, .{} });
    const value = U{ .second = 300 };
    const tag: Tag = value;
    return Result(@intFromBool(@typeInfo(U).@"union".tag_type.? == Tag), @intFromEnum(tag), @intFromBool(@FieldType(U, "first") == Item));
}

pub fn void_source_tag() type {
    const Tag = enum(u8) { none = 3, some = 7 };
    const U = @Union(.auto, Tag, &.{ "none", "some" }, &.{ void, u8 }, &.{ .{}, .{} });
    const value: U = .none;
    const tag: Tag = value;
    return Result(@intFromEnum(tag), @intFromBool(@typeInfo(U).@"union".tag_type.? == Tag), @intFromBool(@TypeOf(tag) == Tag));
}

pub fn automatic_tag_switch() type {
    const Base = union(enum) { first: u8, second: u16 };
    const Tag = @typeInfo(Base).@"union".tag_type.?;
    const U = @Union(.auto, Tag, &.{ "first", "second" }, &.{ u8, u16 }, &.{ .{}, .{} });
    const value = U{ .second = 300 };
    const result = switch (value) {
        .first => |payload| payload,
        inline else => |payload, tag| payload + @intFromEnum(tag),
    };
    return Result(result, @intFromBool(@typeInfo(U).@"union".tag_type.? == Tag), 0);
}

pub fn repeated_cached_tags() type {
    const A = enum(u8) { first = 3, second = 7 };
    const B = enum(u8) { first = 3, second = 7 };
    const UA = tagFactory(A);
    const UB = tagFactory(B);
    const Repeated = tagFactory(A);
    return Result(@intFromBool(@typeInfo(UA).@"union".tag_type.? == A), @intFromBool(@typeInfo(UB).@"union".tag_type.? == B), @intFromBool(@typeInfo(Repeated).@"union".tag_type.? == A));
}

fn tagFactory(comptime Tag: type) type {
    return @Union(.auto, Tag, &.{ "first", "second" }, &.{ u8, u16 }, &.{ .{}, .{} });
}

const GlobalTag = enum(u8) { first = 3, second = 7 };
const GlobalUnion = @Union(.auto, GlobalTag, &.{ "first", "second" }, &.{ u8, u16 }, &.{ .{}, .{} });

pub fn global_source_tag() type {
    const value: GlobalUnion = .{ .second = 300 };
    const tag: GlobalTag = value;
    return Result(@intFromEnum(tag), @intFromBool(@typeInfo(GlobalUnion).@"union".tag_type.? == GlobalTag), @intFromBool(@FieldType(GlobalUnion, "second") == u16));
}

fn globalUnionValue() GlobalUnion {
    return .{ .second = 300 };
}

pub fn global_tag_expression_conversions() type {
    const from_call: GlobalTag = globalUnionValue();
    const from_block: GlobalTag = block: {
        break :block GlobalUnion{ .first = 3 };
    };
    const wrapper = struct { value: GlobalUnion = .{ .second = 300 } }{};
    const from_field: GlobalTag = wrapper.value;
    return Result(@intFromEnum(from_call), @intFromEnum(from_block), @intFromEnum(from_field));
}

pub fn global_generated_enum_conversion() type {
    const Tag = @Enum(u8, .exhaustive, &.{ "first", "second" }, &.{ 3, 7 });
    const U = @Union(.auto, Tag, &.{ "first", "second" }, &.{ u8, u16 }, &.{ .{}, .{} });
    const selected = U{ .second = 300 };
    const from_value: Tag = selected;
    const from_block: Tag = block: {
        break :block U{ .first = 3 };
    };
    return Result(@intFromEnum(from_value), @intFromEnum(from_block), @intFromBool(@TypeOf(from_value) == Tag));
}
