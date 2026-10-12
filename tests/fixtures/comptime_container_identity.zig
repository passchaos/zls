const std = @import("std");

fn Record(comptime T: type, comptime marker: usize) type {
    _ = marker;
    return @Struct(.auto, null, &.{"value"}, &.{T}, &.{.{}});
}

fn Enumeration(comptime marker: usize) type {
    _ = marker;
    return @Enum(u8, .exhaustive, &.{"value"}, &.{1});
}

fn Union(comptime marker: usize) type {
    _ = marker;
    return @Union(.auto, null, &.{"value"}, &.{u8}, &.{.{}});
}

fn Result(comptime first: usize, comptime second: usize, comptime third: usize) type {
    return struct { first: [first]u8, second: [second]u8, third: [third]u8 };
}

pub fn generic_constructor_identity() type {
    const A = Record(u8, 1);
    const Again = Record(u8, 1);
    const Other = Record(u8, 2);
    const Wider = Record(u16, 1);
    return Result(@intFromBool(A == Again), @intFromBool(A != Other), @intFromBool(A != Wider));
}

pub fn generic_enum_identity() type {
    return Result(@intFromBool(Enumeration(1) == Enumeration(1)), @intFromBool(Enumeration(1) != Enumeration(2)), 0);
}

pub fn generic_union_identity() type {
    return Result(@intFromBool(Union(1) == Union(1)), @intFromBool(Union(1) != Union(2)), 0);
}

pub fn constructor_effects_once() type {
    var calls: usize = 0;
    var matches: usize = 0;
    var Original: type = void;
    inline for (0..3) |i| {
        const T = @Struct(.auto, null, &.{"value"}, &.{u8}, attrs: {
            calls += 1;
            break :attrs &.{.{}};
        });
        if (i == 0) Original = T;
        if (T == Original) matches += 1;
    }
    return Result(calls, matches, 0);
}

pub fn changed_constructor_fields() type {
    var Item: type = u8;
    var calls: usize = 0;
    var matches: usize = 0;
    inline for (.{ u8, u16, u8 }) |Field| {
        Item = Field;
        const T = @Struct(.auto, null, &.{"value"}, &.{Item}, attrs: {
            calls += 1;
            break :attrs &.{.{}};
        });
        matches += @intFromBool(@FieldType(T, "value") == Field);
    }
    return Result(calls, matches, 0);
}

pub fn independent_constructor_positions() type {
    const A = @Struct(.auto, null, &.{"value"}, &.{u8}, &.{.{}});
    const B = @Struct(.auto, null, &.{"value"}, &.{u8}, &.{.{}});
    const EA = @Enum(u8, .exhaustive, &.{"value"}, &.{1});
    const EB = @Enum(u8, .exhaustive, &.{"value"}, &.{1});
    const UA = @Union(.auto, null, &.{"value"}, &.{u8}, &.{.{}});
    const UB = @Union(.auto, null, &.{"value"}, &.{u8}, &.{.{}});
    return Result(@intFromBool(A != B), @intFromBool(EA != EB), @intFromBool(UA != UB));
}

pub fn changed_constructor_attributes() type {
    const A = Aligned(4);
    const Same = Aligned(4);
    const B = Aligned(8);
    return Result(@intFromBool(A == Same), @intFromBool(A != B), @typeInfo(B).@"struct".fields[0].alignment.?);
}

fn Aligned(comptime alignment: usize) type {
    return @Struct(.auto, null, &.{"value"}, &.{u8}, &.{.{ .@"align" = alignment }});
}

pub fn changed_enum_values() type {
    const A = EnumValue(3);
    const Same = EnumValue(3);
    const B = EnumValue(7);
    return Result(@intFromBool(A == Same), @intFromBool(A != B), @intFromEnum(B.value));
}

fn EnumValue(comptime value: u8) type {
    return @Enum(u8, .exhaustive, &.{"value"}, &.{value});
}

pub fn changed_union_tags() type {
    const A = enum { value };
    const B = enum { value };
    const UA = Tagged(A);
    const Same = Tagged(A);
    const UB = Tagged(B);
    return Result(@intFromBool(UA == Same), @intFromBool(UA != UB), @intFromBool(@typeInfo(UB).@"union".tag_type.? == B));
}

fn Tagged(comptime Tag: type) type {
    return @Union(.auto, Tag, &.{"value"}, &.{u8}, &.{.{}});
}

pub fn generated_values_cross_calls() type {
    const Value = Record(u8, 1);
    const Handler = struct {
        fn run(value: Record(u8, 2)) Record(u8, 3) {
            return value;
        }
    };
    var executions: usize = 0;
    const value = Handler.run(Value{ .value = block: {
        executions += 1;
        break :block 9;
    } });
    return Result(value.value, executions, @intFromBool(@TypeOf(value) == Value));
}

pub fn changed_field_defaults() type {
    const A = WithDefault(3);
    const Same = WithDefault(3);
    const B = WithDefault(7);
    return Result(@intFromBool(A == Same), @intFromBool(A != B), @as(B, .{}).value);
}

fn WithDefault(comptime value: u8) type {
    const Default = struct {
        const storage: u8 = value;
    };
    return @Struct(.auto, null, &.{"value"}, &.{u8}, &.{.{ .default_value_ptr = @ptrCast(&Default.storage) }});
}

pub fn mutable_name_arguments() type {
    var name: []const u8 = "first";
    var calls: usize = 0;
    var matched: usize = 0;
    inline for (.{ "first", "second", "first" }) |next| {
        name = next;
        const T = @Struct(.auto, null, &.{name}, &.{u8}, attrs: {
            calls += 1;
            break :attrs &.{.{}};
        });
        matched += @intFromBool(@hasField(T, next));
    }
    return Result(calls, matched, 0);
}

pub fn same_generated_enum_values() type {
    const A = EnumValue(3);
    const Handler = struct {
        fn run(value: EnumValue(3)) EnumValue(3) {
            return value;
        }
    };
    var executions: usize = 0;
    executions += 1;
    const value = Handler.run(A.value);
    return Result(@intFromEnum(value), executions, @intFromBool(@TypeOf(value) == A));
}

pub fn generated_pointer_qualifiers() type {
    const A = Record(u8, 1);
    const Handler = struct {
        fn run(value: *const Record(u8, 1)) u8 {
            return value.value;
        }
    };
    var value = A{ .value = 11 };
    const result = Handler.run(&value);
    return Result(result, value.value, @intFromBool(@TypeOf(value) == A));
}
