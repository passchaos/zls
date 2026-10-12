fn Layout(comptime T: type) type {
    return struct { first: [@sizeOf(T)]u8, second: [@alignOf(T)]u8, third: [@bitSizeOf(T)]u8 };
}

const Shape = enum { source_union, source_struct, generated_union, generated_struct, array_union, array_struct, mixed };
fn Chain(comptime depth: usize, comptime shape: Shape) type {
    var T: type = u32;
    for (0..depth) |_| {
        const Child = T;
        T = switch (shape) {
            .source_union => union { payload: Child },
            .source_struct => struct { payload: Child },
            .generated_union => @Union(.auto, null, &.{"payload"}, &.{Child}, &.{.{}}),
            .generated_struct => @Struct(.auto, null, &.{"payload"}, &.{Child}, &.{.{}}),
            .array_union => @Union(.auto, null, &.{"payload"}, &.{[1]?Child}, &.{.{}}),
            .array_struct => @Struct(.auto, null, &.{"payload"}, &.{[1]?Child}, &.{.{}}),
            .mixed => @Struct(.auto, null, &.{"payload"}, &.{[1]?@Union(.auto, null, &.{"payload"}, &.{Child}, &.{.{}})}, &.{.{}}),
        };
    }
    return T;
}

pub fn source_union_chain() type {
    return Layout(Chain(14, .source_union));
}
pub fn source_struct_chain() type {
    return Layout(Chain(14, .source_struct));
}
pub fn generated_union_chain() type {
    return Layout(Chain(14, .generated_union));
}
pub fn generated_struct_chain() type {
    return Layout(Chain(14, .generated_struct));
}
pub fn array_union_chain() type {
    return Layout(Chain(14, .array_union));
}
pub fn array_struct_chain() type {
    return Layout(Chain(14, .array_struct));
}
pub fn mixed_chain() type {
    return Layout(Chain(10, .mixed));
}

pub fn explicit_alignment() type {
    const Inner = extern struct { a: u32, b: u8 };
    const Outer = extern struct { value: [2]Inner align(16), flag: u8 };
    return Layout(Outer);
}
pub fn sentinel_array() type {
    return Layout([2:null]?u32);
}
pub fn packed_payload() type {
    const Inner = packed struct { value: u17 };
    return Layout(union(enum) { payload: Inner, empty });
}
pub fn field_type_effects() type {
    var executions: usize = 0;
    const Child = block: {
        executions += 1;
        break :block [1]?u32;
    };
    const T = @Struct(.auto, null, &.{"payload"}, &.{Child}, &.{.{}});
    const count = executions;
    return struct { first: [@sizeOf(T)]u8, second: [count]u8, third: [@bitSizeOf(T)]u8 };
}

fn Fixed(comptime unused: bool) type {
    _ = unused;
    return struct { value: u32 };
}
pub fn unused_struct_bindings() type {
    const First = Fixed(false);
    const Second = Fixed(true);
    return struct { first: [@intFromBool(First == Second)]u8, second: [@sizeOf(First)]u8, third: [@sizeOf(Second)]u8 };
}
fn Captured(comptime enabled: bool) type {
    return struct { value: if (enabled) u32 else u32 };
}
pub fn referenced_struct_bindings() type {
    const First = Captured(false);
    const Second = Captured(true);
    return struct { first: [@intFromBool(First == Second)]u8, second: [@sizeOf(First)]u8, third: [@sizeOf(Second)]u8 };
}
fn WithMethod(comptime enabled: bool) type {
    return struct {
        value: u32,
        pub fn Setting() bool {
            return enabled;
        }
    };
}
pub fn method_struct_bindings() type {
    const First = WithMethod(false);
    const Second = WithMethod(true);
    return struct { first: [@intFromBool(First == Second)]u8, second: [@intFromBool(First.Setting())]u8, third: [@intFromBool(Second.Setting())]u8 };
}
pub fn duplicated_child_bindings() type {
    var T: type = u32;
    for (0..14) |_| {
        const Child = T;
        T = struct { first: Child, second: Child };
    }
    return Layout(T);
}

fn Pair(comptime T: type) type {
    return struct { first: T, second: T };
}
pub fn successive_nested_types() type {
    var T: type = u8;
    const First = @sizeOf(Pair(T));
    T = u32;
    const Second = @sizeOf(Pair(T));
    const alignment = @alignOf(Pair(T));
    return struct { first: [First]u8, second: [Second]u8, third: [alignment]u8 };
}

pub fn effectful_layout_fields() type {
    const S = extern struct {
        first: block: {
            var count: usize = @sizeOf(u32);
            count += 1;
            break :block [count]u8;
        },
        second: u8,
    };
    const size = @sizeOf(S);
    const alignment = @alignOf(S);
    return struct { first: [size]u8, second: [alignment]u8, third: [@bitSizeOf(S)]u8 };
}
