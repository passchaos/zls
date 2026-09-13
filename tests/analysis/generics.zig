fn Foo(T: type) type {
    return struct {
        fn bar(U: type, t: ?T, u: ?U) void {
            _ = .{ t, u };
        }

        fn baz(U: type, t: T, u: U) T {
            return t + u;
        }

        fn qux(U: type, t: T, u: U) @TypeOf(t, u) {
            return t + u;
        }
    };
}

const foo = Foo(u8){};
//    ^^^ (Foo(u8))()

const bar_fn = Foo(u8).bar;
//    ^^^^^^ (fn (U: type, ?u8, ?U) void)()

const bar_call = Foo(u8).bar(i32, null, null);
//    ^^^^^^^^ (void)()

const baz_fn = Foo(i32).baz;
//    ^^^^^^ (fn (U: type, i32, U) i32)()

const baz_call = Foo(i32).baz(u8, -42, 42);
//    ^^^^^^^^ (i32)()

const qux_fn = Foo(u8).qux;
//    ^^^^^^ (fn (U: type, u8, U) anytype)()

const qux_call = Foo(u8).qux(i32, 42, -42);
//    ^^^^^^^^ (i32)()

fn fizz(T: type) ?fn () error{}!struct { ??T } {
    return null;
}

const fizz_fn = fizz;
//    ^^^^^^^ (fn (T: type) ?fn () error{}!struct { ??T })()

const fizz_call = fizz(u8);
//    ^^^^^^^^^ (?fn () error{}!struct { ??u8 })()

fn Point1(comptime T: type) type {
    return struct {
        x: T,
        y: T,
        fn normSquared(self: Point1(T)) T {
            _ = self;
            //  ^^^^ (Point1(T))()
        }
    };
}

fn parameter(comptime T: type, in: T) void {
    _ = in;
    //  ^^ (T)()
}

fn taggedUnion(comptime T: type, in: union(enum) { a: T, b: T }) void {
    switch (in) {
        .a => |a| {
            _ = a;
            //  ^ (T)()
        },
        .b => |b| {
            _ = b;
            //  ^ (T)()
        },
    }
}

fn Option(comptime T: type) type {
    return struct {
        item: ?T,
        const none: @This() = undefined;
        const alias = none;
        const default = init();
        fn init() @This() {}
    };
}

const option_none: Option(u8) = .none;
//                              ^^^^^ (Option(u8))()

const option_alias: Option(u8) = .alias;
//                               ^^^^^^ (Option(u8))()

const option_default: Option(u8) = .default;
//                                 ^^^^^^^^ (Option(u8))()

const option_init: Option(u8) = .init();
//                              ^^^^^ (fn () Option(u8))()

fn GenericUnion(T: type) type {
    return union {
        field: T,
        const decl: T = undefined;
    };
}

const generic_union_decl = GenericUnion(u8).decl;
//    ^^^^^^^^^^^^^^^^^^ (u8)()

const generic_union: GenericUnion(u8) = .{ .field = 1 };
//    ^^^^^^^^^^^^^ (GenericUnion(u8))()

const generic_union_field = generic_union.field;
//    ^^^^^^^^^^^^^^^^^^^ (u8)()

const generic_union_tag = GenericUnion(u8).field;
//    ^^^^^^^^^^^^^^^^^ (unknown)()

fn GenericTaggedUnion(T: type) type {
    return union(enum) {
        field: T,
        const decl: T = undefined;
    };
}

const generic_tagged_union_decl = GenericTaggedUnion(u8).decl;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)()

const generic_tagged_union: GenericTaggedUnion(u8) = .{ .field = 1 };
//    ^^^^^^^^^^^^^^^^^^^^ (GenericTaggedUnion(u8))()

const generic_tagged_union_field = generic_tagged_union.field;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)()

const generic_tagged_union_tag = GenericTaggedUnion(u8).field;
//    ^^^^^^^^^^^^^^^^^^^^^^^^ (@typeInfo(GenericTaggedUnion(u8)).@"union".tag_type.?)()

fn GenericEnum(T: type) type {
    return enum {
        field,
        const decl: T = undefined;
    };
}

const generic_enum_decl = GenericEnum(u8).decl;
//    ^^^^^^^^^^^^^^^^^ (u8)()

const generic_enum: GenericEnum(u8) = .field;
//    ^^^^^^^^^^^^ (GenericEnum(u8))()

const generic_enum_field = generic_enum.field;
//    ^^^^^^^^^^^^^^^^^^ (unknown)()

const generic_enum_tag = GenericEnum(u8).field;
//    ^^^^^^^^^^^^^^^^ (GenericEnum(u8))()

fn GenericStruct(T: type) type {
    return struct {
        field: T,
        const decl: T = undefined;
    };
}

const generic_struct_decl = GenericStruct(u8).decl;
//    ^^^^^^^^^^^^^^^^^^^ (u8)()

const generic_struct: GenericStruct(u8) = .{ .field = 1 };
//    ^^^^^^^^^^^^^^ (GenericStruct(u8))()

const generic_struct_field = generic_struct.field;
//    ^^^^^^^^^^^^^^^^^^^^ (u8)()

const generic_struct_tag = GenericStruct(u8).field;
//    ^^^^^^^^^^^^^^^^^^ (unknown)()

fn Map(Context: type) type {
    return struct {
        unmanaged: MapUnmanaged(Context),
        ctx: Context,
        const Self = @This();
        fn clone(self: Self) Self {
            const unmanaged = self.unmanaged.cloneContext(self.ctx);
            //    ^^^^^^^^^ (MapUnmanaged(Context))()
            return .{ .unmanaged = unmanaged, .ctx = self.ctx };
        }
        fn clone2(self: Self) Self {
            const unmanaged = self.unmanaged.cloneContext2(self.ctx);
            //    ^^^^^^^^^ (MapUnmanaged(*Context))()
            return .{ .unmanaged = unmanaged, .ctx = self.ctx };
        }
    };
}

fn MapUnmanaged(Context: type) type {
    return struct {
        size: u32,
        const Self = @This();
        fn clone(self: Self) Self {
            const cloned = self.cloneContext(@as(Context, undefined));
            //    ^^^^^^ (MapUnmanaged(Context))()
            return cloned;
        }
        fn cloneContext(self: Self, new_ctx: anytype) MapUnmanaged(@TypeOf(new_ctx)) {
            _ = self;
        }
        fn clone2(self: Self) Self {
            const cloned = self.cloneContext2(@as(Context, undefined));
            //    ^^^^^^ (MapUnmanaged(*Context))()
            return cloned;
        }
        fn cloneContext2(self: Self, new_ctx: anytype) MapUnmanaged(*@TypeOf(new_ctx)) {
            _ = self;
        }
    };
}

const some_list: std.ArrayList(u8) = .empty;
//    ^^^^^^^^^ (Aligned(u8))()

const some_list_items = some_list.items;
//    ^^^^^^^^^^^^^^^ ([]u8)()

const std = @import("std");

fn Identity(comptime T: type) T {}
// ^^^^^^^^ (fn (T: type) T)()

const identity_of_i32 = Identity(i32);
//    ^^^^^^^^^^^^^^^ (i32)()

const identity_of_f64 = Identity(f64);
//    ^^^^^^^^^^^^^^^ (f64)()

const identity_of_unknown_type = Identity(@as(type, undefined));
//    ^^^^^^^^^^^^^^^^^^^^^^^^ ((unknown type))()

fn anytypeFn1(a: anytype) @TypeOf(a) {
    return a;
}
const anytype_1_int = anytypeFn1(42);
//    ^^^^^^^^^^^^^ (comptime_int)()
const anytype_1_bool = anytypeFn1(true);
//    ^^^^^^^^^^^^^^ (bool)()

fn anytypeFn2(a: anytype, b: anytype) @TypeOf(a, b) {
    return a + b;
}
const anytype_2_u8_u16 = anytypeFn2(@as(u8, 42), @as(u16, 42));
//    ^^^^^^^^^^^^^^^^ (u16)()
const anytype_2_i8_i16 = anytypeFn2(@as(i8, 42), @as(i16, 42));
//    ^^^^^^^^^^^^^^^^ (i16)()

fn peerType(comptime T: type, comptime U: type) type {
    return @TypeOf(@as(T, undefined), @as(U, undefined));
}
const peer_optional: peerType(?u8, u8) = undefined;
//    ^^^^^^^^^^^^^ (?u8)()
const peer_error_union: peerType(error{Bad}!u8, u8) = undefined;
//    ^^^^^^^^^^^^^^^^ (error{Bad}!u8)()
const peer_incompatible: peerType(u8, bool) = undefined;
//    ^^^^^^^^^^^^^^^^^ ((unknown type))()

fn FixedVector(comptime N: usize, comptime T: type) type {
    return struct {
        const length = N + 1;
        items: [length]T,
        pointer: ?*[N]T,
        conditional: [if (N > 2) N else 2]T,
    };
}

const unknown_vector: FixedVector(undefined, u32) = undefined;
const unknown_values_before = unknown_vector.items;
//    ^^^^^^^^^^^^^^^^^^^^^ ([?]u32)()

const first_vector: FixedVector(4, u8) = undefined;
const first_values = first_vector.items;
//    ^^^^^^^^^^^^ ([5]u8)()
const first_pointer = first_vector.pointer;
//    ^^^^^^^^^^^^^ (?*[4]u8)()
const first_conditional = first_vector.conditional;
//    ^^^^^^^^^^^^^^^^^ ([4]u8)()

const second_vector: FixedVector(1, u16) = undefined;
const second_values = second_vector.items;
//    ^^^^^^^^^^^^^ ([2]u16)()
const second_pointer = second_vector.pointer;
//    ^^^^^^^^^^^^^^ (?*[1]u16)()
const second_conditional = second_vector.conditional;
//    ^^^^^^^^^^^^^^^^^^ ([2]u16)()

const first_values_again = first_vector.items;
//    ^^^^^^^^^^^^^^^^^^ ([5]u8)()

fn FixedArray(comptime N: usize, comptime T: type) type {
    return [N + 1]T;
}

const fixed_array: FixedArray(4, u8) = undefined;
//    ^^^^^^^^^^^ ([5]u8)()

const selected_length = if (true) 4 else 2;
const selected_length_copy = selected_length + 0;
//    ^^^^^^^^^^^^^^^^^^^^ (comptime_int)(4)
const selected_array: FixedArray(selected_length, u8) = undefined;
//    ^^^^^^^^^^^^^^ ([5]u8)()

const selected_switch_length = switch (@as(u8, 1)) {
    1 => 4,
    else => 2,
};
const selected_switch_length_copy = selected_switch_length + 0;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^ (comptime_int)(4)
const selected_switch_array: FixedArray(selected_switch_length, u8) = undefined;
//    ^^^^^^^^^^^^^^^^^^^^^ ([5]u8)()

fn ZeroParameterArray() type {
    return [@intFromBool(@inComptime())]u8;
}

const zero_parameter_array: ZeroParameterArray() = undefined;
//    ^^^^^^^^^^^^^^^^^^^^ ([1]u8)()

fn computedCapacity() usize {
    var value: usize = 1;
    value += 2;
    return value;
}

fn HelperCallContainer() type {
    return struct { items: [computedCapacity()]u8 };
}

const helper_call_container: HelperCallContainer() = undefined;
//    ^^^^^^^^^^^^^^^^^^^^^ (HelperCallContainer())()

fn computedFloatCapacity() f64 {
    var value: f64 = 1.5;
    value += 3.0;
    return value;
}

fn FloatHelperContainer() type {
    return struct { items: [@intFromFloat(computedFloatCapacity())]u8 };
}

const float_helper_container: FloatHelperContainer() = undefined;
//    ^^^^^^^^^^^^^^^^^^^^^^ (FloatHelperContainer())()

fn EmbeddedFileArray() type {
    var total: usize = 1;
    const bytes = @embedFile(path: {
        total += 1;
        break :path "generics.zig";
    });
    return if (bytes.len > 3 and bytes[0] == 'f' and bytes[1] == 'n' and bytes[2] == ' ') [total]u8 else bool;
}

const embedded_file_array: EmbeddedFileArray() = undefined;
//    ^^^^^^^^^^^^^^^^^^^ ([2]u8)()
const embedded_file = @embedFile("generics.zig");
const embedded_file_first = embedded_file[0];
//    ^^^^^^^^^^^^^^^^^^^ (u8)(102)

fn RaisedQuotaArray() type {
    @setEvalBranchQuota(1_000_000);
    @setEvalBranchQuota(0);
    var i: usize = 0;
    while (i < 2_000) : (i += 1) {}
    return [i]u8;
}

const raised_quota_array: RaisedQuotaArray() = undefined;
//    ^^^^^^^^^^^^^^^^^^ ([2000]u8)()

fn SubobjectArray(comptime small: u8) type {
    const Config = struct { capacity: usize };
    var state: struct { values: [1]usize, config: ?Config } = .{ .values = .{0}, .config = null };
    const pointer = &state.config;
    state.values, pointer.* = .{ .{small}, .{ .capacity = small } };
    return [
        if (@TypeOf(state.values[0]) == usize and @TypeOf(state.config.?.capacity) == usize)
            state.values[0] + state.config.?.capacity
        else
            99
    ]u8;
}

const first_subobject_array: SubobjectArray(4) = undefined;
//    ^^^^^^^^^^^^^^^^^^^^^ ([8]u8)()
const second_subobject_array: SubobjectArray(3) = undefined;
//    ^^^^^^^^^^^^^^^^^^^^^^ ([6]u8)()

fn ExplicitAggregateArray(comptime small: u8) type {
    const Config = struct { capacity: usize };
    var marker: usize = 0;
    marker += 1;
    const values = [_]Config{.{ .capacity = small }};
    const state = struct { optional: ?Config }{ .optional = .{ .capacity = small } };
    return [values[0].capacity + state.optional.?.capacity]u8;
}

const explicit_aggregate_first: ExplicitAggregateArray(4) = undefined;
//    ^^^^^^^^^^^^^^^^^^^^^^^^ ([8]u8)()
const explicit_aggregate_second: ExplicitAggregateArray(3) = undefined;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^ ([6]u8)()

fn UnionInitializerArray(comptime small: u8) type {
    const Config = struct { capacity: usize };
    const U = union(enum) { payload: ?Config, empty };
    var executions: usize = 0;
    const value = U{ .payload = result: {
        executions += 1;
        break :result .{ .capacity = small };
    } };
    return [value.payload.?.capacity + executions]u8;
}

const first_union_initializer: UnionInitializerArray(4) = undefined;
//    ^^^^^^^^^^^^^^^^^^^^^^^ ([5]u8)()
const second_union_initializer: UnionInitializerArray(3) = undefined;
//    ^^^^^^^^^^^^^^^^^^^^^^^^ ([4]u8)()

fn BuiltinUnionInitializerArray(comptime small: u8) type {
    const Config = struct { capacity: usize };
    const U = union(enum) { payload: ?Config, empty };
    var executions: usize = 0;
    const value = @unionInit(U, "payload", result: {
        executions += 1;
        break :result .{ .capacity = small };
    });
    return [value.payload.?.capacity + executions]u8;
}

const first_builtin_union: BuiltinUnionInitializerArray(4) = undefined;
//    ^^^^^^^^^^^^^^^^^^^ ([5]u8)()
const second_builtin_union: BuiltinUnionInitializerArray(3) = undefined;
//    ^^^^^^^^^^^^^^^^^^^^ ([4]u8)()

fn DefaultFieldArray(comptime base: u8) type {
    const Config = struct { capacity: ?usize = base };
    var state = Config{};
    const original = state;
    state.capacity.? += 1;
    return [original.capacity.? + state.capacity.?]u8;
}

const first_default_array: DefaultFieldArray(4) = undefined;
//    ^^^^^^^^^^^^^^^^^^^ ([9]u8)()
const second_default_array: DefaultFieldArray(3) = undefined;
//    ^^^^^^^^^^^^^^^^^^^^ ([7]u8)()

fn AsAggregateArray(comptime base: u8) type {
    const Config = struct { capacity: usize = base };
    var state = @as(Config, .{});
    const original = state;
    state.capacity += 1;
    return [original.capacity + state.capacity]u8;
}

const first_as_aggregate: AsAggregateArray(4) = undefined;
//    ^^^^^^^^^^^^^^^^^^ ([9]u8)()
const second_as_aggregate: AsAggregateArray(3) = undefined;
//    ^^^^^^^^^^^^^^^^^^^ ([7]u8)()

fn CallBoundaryArray(comptime base: u8) type {
    const Config = struct { capacity: usize };
    const Helpers = struct {
        fn produce(small: u8) Config {
            return .{ .capacity = small };
        }
        fn count(value: Config) usize {
            return value.capacity;
        }
    };
    var executions: usize = 0;
    const value = Helpers.count(argument: {
        executions += 1;
        break :argument .{ .capacity = base };
    });
    const returned = Helpers.produce(base);
    return [value + returned.capacity + executions]u8;
}

const first_call_boundary: CallBoundaryArray(4) = undefined;
//    ^^^^^^^^^^^^^^^^^^^ ([9]u8)()
const second_call_boundary: CallBoundaryArray(3) = undefined;
//    ^^^^^^^^^^^^^^^^^^^^ ([7]u8)()

fn ReturnCastArray(comptime base: u16) type {
    const Helpers = struct {
        fn narrow(comptime T: type, value: u16, executions: *usize) T {
            defer executions.* += 1;
            return @intCast(operand: {
                executions.* += 1;
                break :operand value;
            });
        }
    };
    var executions: usize = 0;
    const value = Helpers.narrow(u8, base, &executions);
    return [value + executions]u8;
}

const first_return_cast: ReturnCastArray(4) = undefined;
//    ^^^^^^^^^^^^^^^^^ ([6]u8)()
const second_return_cast: ReturnCastArray(3) = undefined;
//    ^^^^^^^^^^^^^^^^^^ ([5]u8)()

fn BranchCastArray(comptime base: u16) type {
    const Helpers = struct {
        fn narrow(value: u16, executions: *usize) u8 {
            return result: {
                defer executions.* += 1;
                for (0..1) |_| {
                    break :result if (value < 10) @intCast(value) else unreachable;
                }
                unreachable;
            };
        }
    };
    var executions: usize = 0;
    const value = Helpers.narrow(base, &executions);
    return [value + executions]u8;
}

const first_branch_cast: BranchCastArray(4) = undefined;
//    ^^^^^^^^^^^^^^^^^ ([5]u8)()
const second_branch_cast: BranchCastArray(3) = undefined;
//    ^^^^^^^^^^^^^^^^^^ ([4]u8)()

fn OptionalCaptureArray(comptime base: usize) type {
    var optional: ?usize = base;
    var evaluations: usize = 0;
    const value = if (condition: {
        evaluations += 1;
        break :condition optional;
    }) |payload| result: {
        optional = 9;
        break :result payload + payload;
    } else 0;
    return [value + evaluations]u8;
}

const first_optional_capture: OptionalCaptureArray(4) = undefined;
//    ^^^^^^^^^^^^^^^^^^^^^^ ([9]u8)()
const second_optional_capture: OptionalCaptureArray(3) = undefined;
//    ^^^^^^^^^^^^^^^^^^^^^^^ ([7]u8)()

fn SwitchCaptureArray(comptime base: usize) type {
    const U = union(enum) { count: usize, empty };
    var value = U{ .count = base };
    var evaluations: usize = 0;
    const selected = switch (condition: {
        evaluations += 1;
        break :condition value;
    }) {
        .count => |captured| result: {
            value = .{ .empty = {} };
            break :result captured + captured;
        },
        .empty => 0,
    };
    return [selected + evaluations]u8;
}

const first_switch_capture: SwitchCaptureArray(4) = undefined;
//    ^^^^^^^^^^^^^^^^^^^^ ([9]u8)()
const second_switch_capture: SwitchCaptureArray(3) = undefined;
//    ^^^^^^^^^^^^^^^^^^^^^ ([7]u8)()

fn LocalContextArray(comptime base: u16) type {
    var executions: usize = 0;
    const initial: u8 = result: {
        executions += 1;
        break :result @intCast(base);
    };
    var values: [2]u8 = .{ initial, 7 };
    var index: usize = 0;
    values[index] = result: {
        index = 1;
        break :result @intCast(base + 1);
    };
    return [initial + values[0] + executions]u8;
}

const first_local_context: LocalContextArray(4) = undefined;
//    ^^^^^^^^^^^^^^^^^^^ ([10]u8)()
const second_local_context: LocalContextArray(3) = undefined;
//    ^^^^^^^^^^^^^^^^^^^^ ([8]u8)()

fn CompoundContextArray(comptime base: u8) type {
    var values: [2]u8 = .{ base, 7 };
    var index: usize = 0;
    values[index] += operand: {
        index = 1;
        break :operand @intCast(@as(u16, 2));
    };
    values[0] <<= @intCast(@as(u8, 1));
    return [values[0] + values[1]]u8;
}

const first_compound_context: CompoundContextArray(4) = undefined;
//    ^^^^^^^^^^^^^^^^^^^^^^ ([19]u8)()
const second_compound_context: CompoundContextArray(3) = undefined;
//    ^^^^^^^^^^^^^^^^^^^^^^^ ([17]u8)()

fn ErrorCatchArray(comptime initial: error{Failure}!usize) type {
    var fallback_runs: usize = 0;
    const selected = initial catch |err| fallback: {
        fallback_runs += 1;
        break :fallback if (err == error.Failure) 4 else 99;
    };
    return [selected + fallback_runs]u8;
}

const failed_error_catch: ErrorCatchArray(error.Failure) = undefined;
//    ^^^^^^^^^^^^^^^^^^ ([5]u8)()
const successful_error_catch: ErrorCatchArray(4) = undefined;
//    ^^^^^^^^^^^^^^^^^^^^^^ ([4]u8)()

fn TryArray(comptime initial: error{Failure}!usize) error{Failure}!type {
    const selected = try initial;
    return [selected]u8;
}

fn ResolveTryArray(comptime initial: error{Failure}!usize) type {
    return TryArray(initial) catch [9]u8;
}

const successful_try: ResolveTryArray(4) = undefined;
//    ^^^^^^^^^^^^^^ ([4]u8)()
const failed_try: ResolveTryArray(error.Failure) = undefined;
//    ^^^^^^^^^^ ([9]u8)()

fn TryStatement(comptime initial: error{Failure}!void) error{Failure}!type {
    try initial;
    return [4]u8;
}

fn ResolveTryStatement(comptime initial: error{Failure}!void) type {
    return TryStatement(initial) catch [9]u8;
}

const successful_try_statement: ResolveTryStatement({}) = undefined;
//    ^^^^^^^^^^^^^^^^^^^^^^^^ ([4]u8)()
const failed_try_statement: ResolveTryStatement(error.Failure) = undefined;
//    ^^^^^^^^^^^^^^^^^^^^ ([9]u8)()

fn ErrorDeferArray(comptime mode: u8) type {
    const Helpers = struct {
        fn update(comptime selected: u8, trace: *usize) error{Failure}!void {
            defer trace.* = trace.* * 10 + 3;
            errdefer |err| trace.* = trace.* * 10 + if (err == error.Failure) 2 else 9;
            defer trace.* = trace.* * 10 + 1;
            if (selected == 1) return error.Failure;
            const initial: error{Failure}!void = if (selected == 2) error.Failure else {};
            try initial;
            trace.* = trace.* * 10 + 4;
        }
    };
    var trace: usize = 0;
    Helpers.update(mode, &trace) catch {};
    return [trace]u8;
}

const successful_errdefer: ErrorDeferArray(0) = undefined;
//    ^^^^^^^^^^^^^^^^^^^ ([413]u8)()
const returned_errdefer: ErrorDeferArray(1) = undefined;
//    ^^^^^^^^^^^^^^^^^ ([123]u8)()
const failed_errdefer: ErrorDeferArray(2) = undefined;
//    ^^^^^^^^^^^^^^^ ([123]u8)()

fn ErrorUnionBranchArray(comptime initial: error{Failure}!usize) type {
    var runs: usize = 0;
    const selected = if (condition: {
        runs += 1;
        break :condition initial;
    }) |payload| payload + 2 else |err| if (err == error.Failure) 7 else 99;
    var mutable: error{}!usize = 4;
    if (mutable) |*payload| payload.* += 2 else |_| unreachable;
    const from_while = while (initial) |payload| {
        break payload + 1;
    } else |err| if (err == error.Failure) 3 else 99;
    return [selected + runs + (mutable catch 99) + from_while]u8;
}

const successful_error_union_branch: ErrorUnionBranchArray(4) = undefined;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ ([18]u8)()
const failed_error_union_branch: ErrorUnionBranchArray(error.Failure) = undefined;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^ ([17]u8)()

fn ErrorUnionLoopArray() type {
    var values: [2]error{Done}!usize = .{ 3, 7 };
    var evaluations: usize = 0;
    var iterations: usize = 0;
    var total: usize = 0;
    var completed: usize = 0;
    while (values[
        index: {
            evaluations += 1;
            break :index 0;
        }
    ]) |*payload| : (iterations += 1) {
        total += payload.*;
        payload.* -= 1;
        if (payload.* == 0) values[0] = error.Done;
        continue;
    } else |err| {
        completed = if (err == error.Done) 1 else 99;
    }
    return [total + evaluations + iterations + completed + (values[1] catch 99)]u8;
}

const error_union_loop: ErrorUnionLoopArray() = undefined;
//    ^^^^^^^^^^^^^^^^ ([21]u8)()

fn ExpressionReturnArray(comptime initial: ?usize) type {
    const Helpers = struct {
        fn choose(optional: ?usize, trace: *usize) usize {
            defer trace.* = trace.* * 10 + 1;
            const value = optional orelse return 7;
            trace.* = trace.* * 10 + 2;
            return value;
        }
    };
    var trace: usize = 0;
    const value = Helpers.choose(initial, &trace);
    return [value + trace]u8;
}

const early_expression_return: ExpressionReturnArray(null) = undefined;
//    ^^^^^^^^^^^^^^^^^^^^^^^ ([8]u8)()
const present_expression_value: ExpressionReturnArray(4) = undefined;
//    ^^^^^^^^^^^^^^^^^^^^^^^^ ([25]u8)()

fn ExpressionBreakArray() type {
    var total: usize = 0;
    var trace: usize = 0;
    for ([_]?usize{ 2, null, 3 }) |optional| {
        defer trace = trace * 10 + 1;
        const value = optional orelse continue;
        total += value;
    }
    const result: usize = outer: {
        defer trace = trace * 10 + 2;
        const ignored: usize = {
            defer trace = trace * 10 + 3;
            break :outer @intCast(total + 2);
        };
        break :outer ignored + 99;
    };
    return [result + trace]u8;
}

const nested_expression_break: ExpressionBreakArray() = undefined;
//    ^^^^^^^^^^^^^^^^^^^^^^^ ([11139]u8)()

fn LabeledSwitchArray() type {
    var evaluations: usize = 0;
    var trace: usize = 0;
    const selected: usize = state: switch (condition: {
        evaluations += 1;
        break :condition @as(usize, 8);
    }) {
        0...2 => |value| break :state value + trace,
        else => |value| {
            defer trace += 1;
            continue :state value / 2;
        },
    };
    return [selected + evaluations + trace]u8;
}

const labeled_switch: LabeledSwitchArray() = undefined;
//    ^^^^^^^^^^^^^^ ([7]u8)()

fn LabeledEnumSwitchArray() type {
    const State = enum { start, middle, done };
    var transitions: usize = 0;
    const selected: usize = state: switch (@as(State, .start)) {
        .start => {
            transitions += 1;
            continue :state .middle;
        },
        .middle => {
            transitions += 1;
            continue :state .done;
        },
        .done => 5,
    };
    return [selected + transitions]u8;
}

const labeled_enum_switch: LabeledEnumSwitchArray() = undefined;
//    ^^^^^^^^^^^^^^^^^^^ ([7]u8)()

fn LabeledUnionSwitchArray() type {
    const State = union(enum) { start, count: usize };
    var initial = State{ .start = {} };
    var next = State{ .count = 4 };
    const selected: usize = state: switch (initial) {
        .start => continue :state next,
        .count => |*value| result: {
            value.* += 2;
            break :result value.*;
        },
    };
    return [selected + next.count]u8;
}

const labeled_union_switch: LabeledUnionSwitchArray() = undefined;
//    ^^^^^^^^^^^^^^^^^^^^ ([12]u8)()

fn LabeledErrorSwitchArray() type {
    const State = error{ Start, Middle, Done };
    var transitions: usize = 0;
    const selected: usize = state: switch (@as(State, error.Start)) {
        error.Start => {
            transitions += 1;
            continue :state error.Middle;
        },
        error.Middle => {
            transitions += 1;
            continue :state error.Done;
        },
        error.Done => 5,
    };
    return [selected + transitions]u8;
}

const labeled_error_switch: LabeledErrorSwitchArray() = undefined;
//    ^^^^^^^^^^^^^^^^^^^^ ([7]u8)()

fn PureLabeledSwitch(comptime initial: enum { start, done }) type {
    return state: switch (initial) {
        .start => continue :state .done,
        .done => struct { resolved: u8 },
    };
}

const pure_labeled_switch: PureLabeledSwitch(.start) = undefined;
//    ^^^^^^^^^^^^^^^^^^^ (struct { resolved: u8 })()

fn PackedLabeledSwitchArray() type {
    const State = packed struct { value: u8, mode: u8 };
    var transitions: usize = 0;
    const selected = state: switch (State{ .value = 1, .mode = 7 }) {
        .{ .mode = 7, .value = 3 } => |value| break :state value.value,
        else => |value| {
            transitions += 1;
            continue :state .{ .value = value.value + 1, .mode = value.mode };
        },
    };
    return [selected + transitions]u8;
}

const packed_labeled_switch: PackedLabeledSwitchArray() = undefined;
//    ^^^^^^^^^^^^^^^^^^^^^ ([5]u8)()

fn PackedUnionLabeledSwitchArray() type {
    const State = packed union { unsigned: u8, signed: i8 };
    const selected = state: switch (State{ .unsigned = 1 }) {
        .{ .unsigned = 3 } => |value| break :state value.unsigned,
        else => |value| continue :state .{ .unsigned = value.unsigned + 1 },
    };
    return [selected]u8;
}

const packed_union_labeled_switch: PackedUnionLabeledSwitchArray() = undefined;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^ ([3]u8)()

fn TaggedUnionCaptureSwitchArray() type {
    const State = union(enum) { a, b: usize, c: usize };
    var trace: usize = 0;
    const selected = state: switch (State{ .a = {} }) {
        .a => |payload, tag| {
            trace = if (payload == {} and tag == .a) 1 else 99;
            continue :state .{ .b = 4 };
        },
        .b => |payload, tag| {
            trace = trace * 10 + if (tag == .b) payload else 99;
            continue :state .{ .c = 7 };
        },
        .c => |payload, tag| break :state if (tag == .c) payload else 99,
    };
    return [selected + trace]u8;
}

const tagged_union_capture_switch: TaggedUnionCaptureSwitchArray() = undefined;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^ ([21]u8)()

comptime {
    if (@TypeOf(successful_error_union_branch) != [18]u8) @compileError("unexpected successful error union branch");
    if (@TypeOf(failed_error_union_branch) != [17]u8) @compileError("unexpected failed error union branch");
    if (@TypeOf(error_union_loop) != [21]u8) @compileError("unexpected error union loop");
    if (@TypeOf(labeled_switch) != [7]u8) @compileError("unexpected labeled switch result");
    if (@TypeOf(labeled_enum_switch) != [7]u8) @compileError("unexpected labeled enum switch result");
    if (@TypeOf(labeled_union_switch) != [12]u8) @compileError("unexpected labeled union switch result");
    if (@TypeOf(labeled_error_switch) != [7]u8) @compileError("unexpected labeled error switch result");
    if (!@hasField(@TypeOf(pure_labeled_switch), "resolved")) @compileError("unexpected pure labeled switch result");
    if (@TypeOf(packed_labeled_switch) != [5]u8) @compileError("unexpected packed labeled switch result");
    if (@TypeOf(packed_union_labeled_switch) != [3]u8) @compileError("unexpected packed union labeled switch result");
    if (@TypeOf(tagged_union_capture_switch) != [21]u8) @compileError("unexpected tagged union capture switch result");
    // Use @compileLog to verify the expected type with the compiler:
    // @compileLog(anytype_2_i8_i16);
}
