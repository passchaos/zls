const std = @import("std");

const EnumA = enum {
    foo,
    bar,
};

const TaggedUnionA = union(EnumA) {
    foo: u8,
    bar: i32,
};

const TaggedUnionB = union(enum) {
    fizz: u16,
    buzz: i64,
};

const TagA = std.meta.Tag(TaggedUnionA);
//    ^^^^ (type)(EnumA)

const TagB = std.meta.Tag(TaggedUnionB);
//    ^^^^ (type)(@typeInfo(TaggedUnionB).@"union".tag_type.?)

const ExplicitEnum = enum(u8) {
    foo,
    bar,
};

const TagEnum = std.meta.Tag(ExplicitEnum);
//    ^^^^^^^ (type)(u8)

const EmptyEnum = enum {};
const TagEmptyEnum = std.meta.Tag(EmptyEnum);
//    ^^^^^^^^^^^^ (type)(u0)

const GeneratedEnum = @Enum(u13, .exhaustive, &.{"value"}, &.{1});
const TagGeneratedEnum = std.meta.Tag(GeneratedEnum);
//    ^^^^^^^^^^^^^^^^ (type)(u13)

const TagBBacking = std.meta.Tag(TagB);
//    ^^^^^^^^^^^ (type)(u1)

const ArgsTupleA = std.meta.ArgsTuple(fn (u8, i32) void);
//    ^^^^^^^^^^ (type)(struct { u8, i32 })

fn function(_: u16, _: i64) void {}

const ArgsTupleB = std.meta.ArgsTuple(@TypeOf(function));
//    ^^^^^^^^^^ (type)(struct { u16, i64 })

const GeneratedFunction = @Fn(&.{ u8, i32 }, &.{ .{}, .{} }, void, .{});
const ArgsTupleGenerated = std.meta.ArgsTuple(GeneratedFunction);
//    ^^^^^^^^^^^^^^^^^^ (type)(struct { u8, i32 })

const MetaNominal = struct { value: u8 };
const ChildNominalVector = std.meta.Child(@Vector(4, *MetaNominal));
//    ^^^^^^^^^^^^^^^^^^ (type)(*MetaNominal)
const ElemNominalVector = std.meta.Elem(*@Vector(4, *MetaNominal));
//    ^^^^^^^^^^^^^^^^^ (type)(*MetaNominal)
const MetaPacked = @Struct(.@"packed", null, &.{"value"}, &.{u8}, &.{.{}});
const LayoutPacked = std.meta.containerLayout(MetaPacked);
const layout_packed_name = @tagName(LayoutPacked)[0];
//    ^^^^^^^^^^^^^^^^^^ (u8)(112)
const MetaExtern = extern struct { value: u8 };
const layout_extern_name = @tagName(std.meta.containerLayout(MetaExtern))[0];
//    ^^^^^^^^^^^^^^^^^^ (u8)(101)
const MetaUnion = @Union(.auto, null, &.{"value"}, &.{u8}, &.{.{}});
const layout_union_name = @tagName(std.meta.containerLayout(MetaUnion))[0];
//    ^^^^^^^^^^^^^^^^^ (u8)(97)
const explicit_pointer_alignment = std.meta.alignment(*align(32) MetaNominal);
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^ (comptime_int)(32)
const optional_pointer_alignment = std.meta.alignment(?*align(32) MetaNominal);
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^ (comptime_int)(32)
const implicit_pointer_alignment = std.meta.alignment(*u16);
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^ (comptime_int)(2)
