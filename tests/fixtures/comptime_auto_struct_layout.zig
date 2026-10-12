fn Result(comptime first: usize, comptime second: usize, comptime third: usize) type {
    return struct { first: [first]u8, second: [second]u8, third: [third]u8 };
}
fn Layout(comptime T: type) type {
    return Result(@sizeOf(T), @alignOf(T), @bitSizeOf(T));
}
fn Offsets(comptime T: type) type {
    return Result(@offsetOf(T, "a"), @offsetOf(T, "b"), @offsetOf(T, "c"));
}

const Mixed = struct { a: u8, b: u32, c: u8 };
const SameAlignment = struct { a: [3]u8, b: u8, c: u16 };
const ReversedSameAlignment = struct { a: u8, b: [3]u8, c: u16 };
const IncreasedAlignment = struct { a: u8 align(8), b: u32, c: u8 };
const ReducedAlignment = struct { a: u32 align(1), b: u8, c: u16 };
const AlignedVoid = struct { a: void align(16), b: u32, c: u8 };
const AlignedZeroArray = struct { a: u8, b: [0]u128, c: u8 };

pub fn mixed_layout() type {
    return Layout(Mixed);
}
pub fn mixed_offsets() type {
    return Offsets(Mixed);
}
pub fn same_alignment_layout() type {
    return Layout(SameAlignment);
}
pub fn same_alignment_offsets() type {
    return Offsets(SameAlignment);
}
pub fn reversed_alignment_offsets() type {
    return Offsets(ReversedSameAlignment);
}
pub fn increased_alignment_layout() type {
    return Layout(IncreasedAlignment);
}
pub fn increased_alignment_offsets() type {
    return Offsets(IncreasedAlignment);
}
pub fn reduced_alignment_layout() type {
    return Layout(ReducedAlignment);
}
pub fn reduced_alignment_offsets() type {
    return Offsets(ReducedAlignment);
}
pub fn aligned_void_layout() type {
    return Layout(AlignedVoid);
}
pub fn aligned_void_offsets() type {
    return Offsets(AlignedVoid);
}
pub fn aligned_zero_array_layout() type {
    return Layout(AlignedZeroArray);
}
pub fn aligned_zero_array_offsets() type {
    return Offsets(AlignedZeroArray);
}

fn Generated() type {
    return @Struct(.auto, null, &.{ "a", "b", "c" }, &.{ u8, u32, u8 }, &.{ .{}, .{}, .{} });
}
pub fn generated_layout() type {
    return Layout(Generated());
}
pub fn generated_offsets() type {
    return Offsets(Generated());
}
pub fn generated_alignment() type {
    const T = @Struct(.auto, null, &.{ "a", "b", "c" }, &.{ u8, u32, u8 }, &.{ .{ .@"align" = 8 }, .{}, .{} });
    return Layout(T);
}
pub fn nested_struct() type {
    return Layout(struct { a: u8, b: Mixed, c: u16 });
}
pub fn struct_array() type {
    return Layout([3]Mixed);
}
pub fn struct_optional() type {
    return Layout(?Mixed);
}
pub fn struct_error_union() type {
    return Layout(error{Missing}!Mixed);
}
pub fn struct_union() type {
    return Layout(union(enum) { value: Mixed, empty });
}
pub fn packed_struct_field() type {
    return Layout(struct { a: u8, b: packed struct { value: u17 }, c: u8 });
}
pub fn generic_layout() type {
    return Layout(Generic(u64));
}
fn Generic(comptime T: type) type {
    return struct { a: u8, b: T, c: u16 };
}
pub fn explicit_comptime_field() type {
    return Layout(struct { comptime fixed: usize = 7, a: u8, b: u32, c: u8 });
}
pub fn comptime_payload_bits() type {
    const T = struct { fixed: type, a: u8, b: u32, c: u8 };
    return Result(@alignOf(?T), @bitSizeOf(?T), @bitSizeOf(error{Missing}!T));
}
pub fn zero_field_source_order() type {
    return Offsets(struct { a: u8, b: u32, c: void });
}
pub fn zero_field_before_payload() type {
    return Offsets(struct { a: type, b: u8, c: u32 });
}
pub fn comptime_offsets() type {
    return Offsets(struct { a: u8, b: u32, c: comptime_int });
}
pub fn uninstantiable_offsets() type {
    return Offsets(struct { a: u8, b: noreturn align(16), c: u32 });
}
pub fn comptime_layout_bits() type {
    const T = struct { a: u8, b: u32, c: comptime_int };
    return Result(@alignOf(T), @bitSizeOf(T), @bitSizeOf(struct { a: type, b: comptime_int }));
}
pub fn uninstantiable_bits() type {
    return Result(@bitSizeOf(struct { a: u8, b: noreturn, c: u32 }), @sizeOf(?struct { a: u8, b: noreturn, c: u32 }), @alignOf(?struct { a: u8, b: noreturn, c: u32 }));
}
pub fn generated_comptime_offsets() type {
    const T = @Struct(.auto, null, &.{ "a", "b", "c" }, &.{ u8, u32, type }, &.{ .{}, .{}, .{} });
    return Offsets(T);
}
pub fn nested_comptime_layout() type {
    return Result(@alignOf(struct { a: u8, b: struct { t: type, count: u32 } }), @bitSizeOf(struct { a: u8, b: struct { t: type, count: u32 } }), @bitSizeOf(?struct { a: u8, b: struct { t: type, count: u32 } }));
}
pub fn zero_runtime_comptime_layout() type {
    const T = struct { a: type, b: void, c: u0 };
    return Result(@bitSizeOf(T), @bitSizeOf(error{Missing}!T), @bitSizeOf(?T));
}
