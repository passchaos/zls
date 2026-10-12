fn Result(comptime first: usize, comptime second: usize, comptime third: usize) type {
    return struct { first: [first]u8, second: [second]u8, third: [third]u8 };
}
pub fn source_untagged_same() type {
    const U = union { a: u8, b: u8 };
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn source_untagged_mixed() type {
    const U = union { a: u8, b: u32 };
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn source_extern() type {
    const U = extern union { a: u8, b: u32 };
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn source_extern_array() type {
    const U = extern union { bytes: [3]u8, number: u16 };
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn source_tagged_small() type {
    const U = union(enum) { a: u8, b: u8 };
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn source_tagged_mixed() type {
    const U = union(enum) { a: u8, b: u32 };
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn source_tagged_void() type {
    const U = union(enum) { a, b };
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn source_tagged_single() type {
    const U = union(enum) { a: u8 };
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn source_single_void() type {
    const U = union(enum) { a };
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn source_single_untagged() type {
    const U = union { a: u8 };
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn source_aligned_payload() type {
    const U = union(enum) { a: u8 align(16), b: u8 };
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn source_extern_aligned() type {
    const U = extern union { a: u8 align(16), b: u32 };
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn source_packed() type {
    const U = packed union { a: u5, b: u5 };
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn source_tagged_large_tag() type {
    const U = union(enum(u32)) { a: u8, b: u8 };
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn generated_extern() type {
    const U = @Union(.@"extern", null, &.{ "a", "b" }, &.{ u8, u32 }, &.{ .{}, .{} });
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn generated_untagged() type {
    const U = @Union(.auto, null, &.{ "a", "b" }, &.{ u8, u32 }, &.{ .{}, .{} });
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn generated_tagged() type {
    const U = @Union(.auto, @Enum(u8, .exhaustive, &.{ "a", "b" }, &.{ 1, 3 }), &.{ "a", "b" }, &.{ u8, u32 }, &.{ .{}, .{} });
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn generated_packed() type {
    const U = @Union(.@"packed", null, &.{ "a", "b" }, &.{ u5, u5 }, &.{ .{}, .{} });
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn generated_aligned() type {
    const U = @Union(.auto, @Enum(u8, .exhaustive, &.{ "a", "b" }, &.{ 1, 3 }), &.{ "a", "b" }, &.{ u8, u8 }, &.{ .{ .@"align" = 16 }, .{} });
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}

pub fn source_tagged_payload_padding() type {
    const U = union(enum) { bytes: [3]u8, word: u16 };
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn source_tagged_tag_padding() type {
    const U = union(enum(u16)) { bytes: [3]u8, byte: u8 };
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn source_aligned_zero_payload() type {
    const U = union(enum) { empty: void align(16), other: void };
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn source_single_explicit_tag() type {
    const U = union(enum(u32)) { a: u8 };
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn source_lower_alignment() type {
    const U = union(enum) { a: u32 align(1), b: u8 };
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn source_noreturn_payload() type {
    const U = union(enum(u64)) { impossible: noreturn, value: u8 };
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn source_noreturn_alignment() type {
    const U = union(enum) { impossible: noreturn align(32), value: u8 };
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn source_packed_wide() type {
    const U = packed union { a: u17, b: i17 };
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn source_packed_zero() type {
    const U = packed union { a: u0, b: void };
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn source_extern_zero() type {
    const U = extern union { a: [0]u8, b: [0]u8 };
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn source_nested_union() type {
    const Inner = union(enum) { a: u8, b: u32 };
    const U = union(enum) { inner: Inner, number: u16 };
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn source_union_array() type {
    const U = union(enum) { a: u8, b: u32 };
    return Result(@sizeOf([2]U), @alignOf([2]U), @bitSizeOf([2]U));
}
pub fn explicit_safety_off() type {
    @setRuntimeSafety(false);
    const U = union { a: u8, b: u32 };
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn explicit_safety_on() type {
    @setRuntimeSafety(true);
    const U = union { a: u8, b: u32 };
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn generated_safety_off() type {
    @setRuntimeSafety(false);
    const U = @Union(.auto, null, &.{ "a", "b" }, &.{ u8, u32 }, &.{ .{}, .{} });
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn generated_safety_on() type {
    @setRuntimeSafety(true);
    const U = @Union(.auto, null, &.{ "a", "b" }, &.{ u8, u32 }, &.{ .{}, .{} });
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}

pub fn nested_safety_setting() type {
    @setRuntimeSafety(false);
    const U = block: {
        @setRuntimeSafety(true);
        break :block union { a: u8, b: u32 };
    };
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}

pub fn declaration_before_safety_setting() type {
    const U = union { a: u8, b: u32 };
    @setRuntimeSafety(false);
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}

pub fn generic_safety_setting() type {
    const Unsafe = Safety(false);
    const Safe = Safety(true);
    return Result(@sizeOf(Unsafe), @sizeOf(Safe), @intFromBool(Unsafe == Safe));
}
fn Safety(comptime enabled: bool) type {
    @setRuntimeSafety(enabled);
    return @Union(.auto, null, &.{ "a", "b" }, &.{ u8, u32 }, &.{ .{}, .{} });
}

pub fn generic_union_payloads() type {
    const Small = Payload(u8);
    const Large = Payload(u32);
    return Result(@sizeOf(Small), @sizeOf(Large), @alignOf(Large));
}
fn Payload(comptime T: type) type {
    return union(enum) { item: T, empty };
}

pub fn source_packed_float() type {
    const U = packed union { bits: u32, value: f32 };
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}

pub fn generated_source_payload() type {
    const Item = extern struct { count: u32, small: u8 };
    const Tag = enum { item, empty };
    const U = @Union(.auto, Tag, &.{ "item", "empty" }, &.{ Item, void }, &.{ .{}, .{} });
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}

pub fn source_safety_effects() type {
    var executions: usize = 0;
    @setRuntimeSafety(block: {
        executions += 1;
        break :block false;
    });
    const U = union { a: u8, b: u32 };
    return Result(@sizeOf(U), executions, @alignOf(U));
}
pub fn generated_safety_effects() type {
    var executions: usize = 0;
    @setRuntimeSafety(block: {
        executions += 1;
        break :block false;
    });
    const U = @Union(.auto, null, &.{ "a", "b" }, &.{ u8, u32 }, &.{ .{}, .{} });
    return Result(@sizeOf(U), executions, @alignOf(U));
}

const GlobalUnion = union { a: u8, b: u32 };
const GlobalGeneratedUnion = @Union(.auto, null, &.{ "a", "b" }, &.{ u8, u32 }, &.{ .{}, .{} });
pub fn global_union_in_unsafe_scope() type {
    @setRuntimeSafety(false);
    return Result(@sizeOf(GlobalUnion), @alignOf(GlobalUnion), @bitSizeOf(GlobalUnion));
}
pub fn global_generated_union_in_unsafe_scope() type {
    @setRuntimeSafety(false);
    return Result(@sizeOf(GlobalGeneratedUnion), @alignOf(GlobalGeneratedUnion), @bitSizeOf(GlobalGeneratedUnion));
}
pub fn generated_before_safety_setting() type {
    const U = @Union(.auto, null, &.{ "a", "b" }, &.{ u8, u32 }, &.{ .{}, .{} });
    @setRuntimeSafety(false);
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn safety_restored_after_block() type {
    @setRuntimeSafety(false);
    const Inner = block: {
        @setRuntimeSafety(true);
        break :block union { a: u8, b: u32 };
    };
    const Outer = union { a: u8, b: u32 };
    return Result(@sizeOf(Inner), @sizeOf(Outer), @alignOf(Outer));
}
pub fn declaration_before_safety_effects() type {
    const U = union { a: u8, b: u32 };
    var executions: usize = 0;
    @setRuntimeSafety(block: {
        executions += 1;
        break :block false;
    });
    return Result(@sizeOf(U), executions, @alignOf(U));
}

fn PlainUnion() type {
    return union { a: u8, b: u32 };
}
fn GenericPlainUnion(comptime count: usize) type {
    return union { a: u8, b: [count]u32 };
}
pub fn caller_safety_does_not_change_callee() type {
    @setRuntimeSafety(false);
    return Result(@sizeOf(PlainUnion()), @sizeOf(GenericPlainUnion(1)), @alignOf(PlainUnion()));
}
fn UnsafeContainer() type {
    @setRuntimeSafety(false);
    return struct {
        const Member = union { a: u8, b: u32 };
        fn Create() type {
            return union { a: u8, b: u32 };
        }
        fn ForceOff() type {
            @setRuntimeSafety(false);
            return union { a: u8, b: u32 };
        }
    };
}
pub fn container_safety_scope() type {
    const Container = UnsafeContainer();
    return Result(@sizeOf(Container.Member), @sizeOf(Container.Create()), @sizeOf(Container.ForceOff()));
}
fn EffectfulContainer() type {
    var executions: usize = 0;
    @setRuntimeSafety(block: {
        executions += 1;
        break :block false;
    });
    const count = executions;
    return struct {
        const Member = union { a: u8, b: u32 };
        pub const calls = count;
    };
}
pub fn container_safety_effects_boundary() type {
    const Container = EffectfulContainer();
    return Result(@sizeOf(Container.Member), @alignOf(Container.Member), Container.calls);
}

fn FirstUnsafe(comptime enabled: bool) type {
    @setRuntimeSafety(enabled);
    return union { a: u8, b: u32 };
}
fn FirstSafe(comptime enabled: bool) type {
    @setRuntimeSafety(enabled);
    return union { a: u8, b: u32 };
}
pub fn source_safety_first_unsafe_identity() type {
    const First = FirstUnsafe(false);
    const Second = FirstUnsafe(true);
    return Result(@intFromBool(First == Second), @sizeOf(Second), @sizeOf(First));
}
pub fn source_safety_first_safe_identity() type {
    const First = FirstSafe(true);
    const Second = FirstSafe(false);
    return Result(@intFromBool(First == Second), @sizeOf(Second), @sizeOf(First));
}
fn CapturedSafety(comptime enabled: bool) type {
    @setRuntimeSafety(enabled);
    return union { a: u8, b: if (enabled) u32 else u32 };
}
pub fn source_safety_captured_identity() type {
    const Off = CapturedSafety(false);
    const On = CapturedSafety(true);
    return Result(@intFromBool(Off == On), @sizeOf(Off), @sizeOf(On));
}
fn DeclarationSafety(comptime enabled: bool) type {
    @setRuntimeSafety(enabled);
    return union {
        a: u8,
        b: u32,
        pub const setting = enabled;
    };
}
pub fn source_safety_declaration_capture() type {
    const Off = DeclarationSafety(false);
    const On = DeclarationSafety(true);
    return Result(@intFromBool(Off == On), @intFromBool(Off.setting), @intFromBool(On.setting));
}
fn MethodSafety(comptime enabled: bool) type {
    @setRuntimeSafety(enabled);
    return union {
        a: u8,
        b: u32,
        pub fn Setting() bool {
            return enabled;
        }
    };
}
pub fn source_safety_method_capture() type {
    const Off = MethodSafety(false);
    const On = MethodSafety(true);
    return Result(@intFromBool(Off == On), @intFromBool(Off.Setting()), @intFromBool(On.Setting()));
}
pub fn source_packed_bool() type {
    const U = packed union { a: bool, b: u1 };
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn source_packed_nested() type {
    const U = packed union { a: packed union { x: u8, y: i8 }, b: packed struct { x: u8 } };
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn source_packed_enum() type {
    const U = packed union { a: enum(u8) { x, y }, b: u8 };
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn source_extern_optional_pointer() type {
    const U = extern union { value: ?*u8 };
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn source_extern_vector() type {
    const U = extern union { value: @Vector(4, bool) };
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn source_extern_wide() type {
    const U = extern union { value: u128 };
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn source_extern_explicit_packed() type {
    const U = extern union { value: packed struct(u8) { x: u8 } };
    return Result(@sizeOf(U), @alignOf(U), @bitSizeOf(U));
}
pub fn source_uninstantiable_bits() type {
    return Result(@bitSizeOf(union {}), @bitSizeOf(union { a: noreturn, b: noreturn }), @bitSizeOf(union(enum) {}));
}
pub fn source_comptime_layout() type {
    const U = union(enum(u64)) { a: type, b: u32 };
    return Result(@alignOf(U), @bitSizeOf(U), @bitSizeOf(union { a: comptime_int }));
}
pub fn generated_comptime_layout() type {
    const U = @Union(.auto, null, &.{ "a", "b" }, &.{ type, u8 }, &.{ .{}, .{} });
    return Result(@alignOf(U), @bitSizeOf(U), @bitSizeOf(@Union(.auto, null, &.{}, &.{}, &.{})));
}
