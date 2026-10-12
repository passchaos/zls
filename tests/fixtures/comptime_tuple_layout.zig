fn Result(comptime first: usize, comptime second: usize, comptime third: usize) type {
    return struct { first: [first]u8, second: [second]u8, third: [third]u8 };
}
fn Layout(comptime T: type) type {
    return Result(@sizeOf(T), @alignOf(T), @bitSizeOf(T));
}
fn Offsets(comptime T: type) type {
    return Result(@offsetOf(T, "0"), @offsetOf(T, "1"), @offsetOf(T, "2"));
}

pub fn source_tuple() type {
    return Layout(struct { u8, u32, u8 });
}
pub fn source_offsets() type {
    return Offsets(struct { u8, u32, u8 });
}
pub fn generated_tuple() type {
    return Layout(@Tuple(&.{ u8, u32, u8 }));
}
pub fn generated_offsets() type {
    return Offsets(@Tuple(&.{ u8, u32, u8 }));
}
pub fn equal_alignment_tuple() type {
    return Layout(@Tuple(&.{ [3]u8, u8, u16 }));
}
pub fn zero_fields() type {
    return Offsets(struct { u8, void, u32 });
}
pub fn empty_tuple() type {
    return Layout(@Tuple(&.{}));
}
pub fn boolean_tuple() type {
    return Layout(@Tuple(&.{ bool, u3, bool }));
}
pub fn source_payload_tuple() type {
    const Item = struct { a: u8, b: u32 };
    return Layout(@Tuple(&.{ u8, Item, u8 }));
}
pub fn source_payload_offsets() type {
    const Item = struct { a: u8, b: u32 };
    return Offsets(@Tuple(&.{ u8, Item, u8 }));
}
pub fn wrapped_tuple() type {
    return Layout(?@Tuple(&.{ u8, u32 }));
}
pub fn error_union_tuple() type {
    return Layout(error{Missing}!@Tuple(&.{ u8, u32 }));
}
pub fn tuple_array() type {
    return Layout([2]@Tuple(&.{ u8, u32 }));
}
pub fn tuple_struct_field() type {
    return Layout(struct { a: u8, b: @Tuple(&.{ u8, u32 }) });
}
pub fn tuple_union_field() type {
    return Layout(union(enum) { value: @Tuple(&.{ u8, u32 }), empty });
}
pub fn packed_payload_tuple() type {
    return Layout(@Tuple(&.{ u8, packed struct { value: u17 } }));
}
pub fn source_comptime_field() type {
    return Layout(struct { comptime u128 = 1, u8, u32 });
}
pub fn source_comptime_offsets() type {
    const T = struct { comptime u128 = 1, u8, u32 };
    return Result(@offsetOf(T, "1"), @offsetOf(T, "2"), @sizeOf(T));
}
pub fn known_tuple_values() type {
    return Layout(@TypeOf(.{ @as(u8, 1), @as(u32, 2), true }));
}
pub fn known_undefined_tuple() type {
    return Layout(@TypeOf(.{ @as(u8, undefined), @as(u32, 2), true }));
}
pub fn type_valued_tuple() type {
    return Layout(@TypeOf(.{ u8, u32, true }));
}
var runtime: u32 = undefined;
pub fn mixed_tuple_values() type {
    return Layout(@TypeOf(.{ @as(u8, 1), runtime, true }));
}
pub fn mixed_tuple_offset() type {
    const T = @TypeOf(.{ @as(u8, 1), runtime, true });
    return Result(@offsetOf(T, "1"), @alignOf(T), @bitSizeOf(T));
}
pub fn comptime_tuple_bits() type {
    const T = @Tuple(&.{ type, u32, comptime_int });
    return Result(@alignOf(T), @bitSizeOf(T), @bitSizeOf(?T));
}
pub fn comptime_tuple_offsets() type {
    return Offsets(@Tuple(&.{ type, u32, comptime_int }));
}
pub fn tuple_layout_operand_effects() type {
    var executions: usize = 0;
    const size = @sizeOf(block: {
        executions += 1;
        break :block @Tuple(&.{ u8, u32 });
    });
    return Result(size, executions, @alignOf(@Tuple(&.{ u8, u32 })));
}

pub fn known_nominal_tuple() type {
    const Item = struct { value: u32 };
    return Layout(@TypeOf(.{ Item{ .value = 1 }, @as(u8, 2) }));
}
pub fn mixed_nominal_tuple() type {
    const Item = struct { value: u32 };
    return Layout(@TypeOf(.{ Item{ .value = 1 }, runtime }));
}
pub fn nominal_tuple_defaults() type {
    const Item = struct { value: u32 };
    const T = @TypeOf(.{ Item{ .value = 7 }, runtime });
    const field = @typeInfo(T).@"struct".fields[0];
    const pointer: *const Item = @ptrCast(@alignCast(field.default_value_ptr.?));
    return Result(@intFromBool(field.is_comptime), pointer.value, @sizeOf(T));
}
pub fn source_comptime_tuple_reflection() type {
    const T = struct { comptime u128 = 7, u8, u32 };
    const info = @typeInfo(T).@"struct";
    return Result(@intFromBool(info.is_tuple), info.fields[0].name[0], @intFromBool(info.fields[0].is_comptime));
}
pub fn nominal_tuple_identity() type {
    const Item = struct { value: u32 };
    const First = @TypeOf(.{ Item{ .value = 7 }, @as(u8, 2) });
    const Same = @TypeOf(.{ Item{ .value = 7 }, @as(u8, 2) });
    const Different = @TypeOf(.{ Item{ .value = 9 }, @as(u8, 2) });
    return Result(@intFromBool(First == Same), @intFromBool(First == Different), @sizeOf(First));
}
pub fn nominal_tuple_effects() type {
    var executions: usize = 0;
    const Item = struct { value: u32 };
    const tuple = .{ Item{ .value = block: {
        executions += 1;
        break :block 7;
    } }, @as(u8, 2) };
    return Result(@sizeOf(@TypeOf(tuple)), executions, tuple.@"0".value);
}
pub fn args_tuple_layout() type {
    const T = @import("std").meta.ArgsTuple(fn (u8, u32, u8) void);
    return Layout(T);
}
pub fn runtime_value_tuple() type {
    return Layout(@TypeOf(.{ @as(u8, 1), runtime, @as(u8, 2) }));
}
fn Pure() u32 {
    return 7;
}
pub fn unevaluated_nominal_tuple() type {
    const Item = struct { value: u32 };
    return Layout(@TypeOf(.{ Item{ .value = Pure() }, @as(u8, 2) }));
}
pub fn runtime_nominal_tuple() type {
    const Item = struct { value: u32 };
    return Layout(@TypeOf(.{ Item{ .value = runtime }, @as(u8, 2) }));
}
pub fn undefined_nominal_tuple() type {
    const Item = struct { value: u32 };
    const T = @TypeOf(.{ @as(Item, undefined), @as(u8, 2) });
    const field = @typeInfo(T).@"struct".fields[0];
    return Result(@sizeOf(T), @intFromBool(field.is_comptime), @intFromBool(field.default_value_ptr != null));
}
pub fn nominal_tuple_peer_types() type {
    const Item = struct { value: u32 };
    const T = @TypeOf(.{ Item{ .value = 1 }, @as(u8, 2) }, .{ Item{ .value = 3 }, @as(u8, 2) });
    const info = @typeInfo(T).@"struct";
    return Result(@sizeOf(T), @intFromBool(info.fields[0].is_comptime), @intFromBool(info.fields[1].is_comptime));
}
