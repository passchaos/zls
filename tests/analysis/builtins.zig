const some_float: f32 = undefined;
const some_vector: @Vector(4, f32) = undefined;

const vector_indexing = some_vector[0];
//    ^^^^^^^^^^^^^^^ (f32)()

const vector_slice_open_1 = some_vector[1..];
//    ^^^^^^^^^^^^^^^^^^^ (*const [3]f32)() TODO this should be `unknown`

const vector_slice_0_2 = some_vector[0..2];
//    ^^^^^^^^^^^^^^^^ (*const [2]f32)() TODO this should be `unknown`

const vector_loop = for (some_vector) |elem| {
    _ = elem;
    //  ^^^^ (f32)() TODO this should be `unknown`
};

const float_builtin_00 = @sqrt(some_float);
//    ^^^^^^^^^^^^^^^^ (f32)()
const float_builtin_01 = @sin(some_float);
//    ^^^^^^^^^^^^^^^^ (f32)()
const float_builtin_02 = @cos(some_float);
//    ^^^^^^^^^^^^^^^^ (f32)()
const float_builtin_03 = @tan(some_float);
//    ^^^^^^^^^^^^^^^^ (f32)()
const float_builtin_04 = @exp(some_float);
//    ^^^^^^^^^^^^^^^^ (f32)()
const float_builtin_05 = @exp2(some_float);
//    ^^^^^^^^^^^^^^^^ (f32)()
const float_builtin_06 = @log(some_float);
//    ^^^^^^^^^^^^^^^^ (f32)()
const float_builtin_07 = @log2(some_float);
//    ^^^^^^^^^^^^^^^^ (f32)()
const float_builtin_08 = @log10(some_float);
//    ^^^^^^^^^^^^^^^^ (f32)()
const float_builtin_09 = @abs(some_float);
//    ^^^^^^^^^^^^^^^^ (f32)()
const float_builtin_10 = @floor(some_float);
//    ^^^^^^^^^^^^^^^^ (f32)()
const float_builtin_11 = @ceil(some_float);
//    ^^^^^^^^^^^^^^^^ (f32)()
const float_builtin_12 = @trunc(some_float);
//    ^^^^^^^^^^^^^^^^ (f32)()
const float_builtin_13 = @round(some_float);
//    ^^^^^^^^^^^^^^^^ (f32)()

const vector_builtin_00 = @sqrt(some_vector);
//    ^^^^^^^^^^^^^^^^^ (@Vector(4,f32))()
const vector_builtin_01 = @sin(some_vector);
//    ^^^^^^^^^^^^^^^^^ (@Vector(4,f32))()
const vector_builtin_02 = @cos(some_vector);
//    ^^^^^^^^^^^^^^^^^ (@Vector(4,f32))()
const vector_builtin_03 = @tan(some_vector);
//    ^^^^^^^^^^^^^^^^^ (@Vector(4,f32))()
const vector_builtin_04 = @exp(some_vector);
//    ^^^^^^^^^^^^^^^^^ (@Vector(4,f32))()
const vector_builtin_05 = @exp2(some_vector);
//    ^^^^^^^^^^^^^^^^^ (@Vector(4,f32))()
const vector_builtin_06 = @log(some_vector);
//    ^^^^^^^^^^^^^^^^^ (@Vector(4,f32))()
const vector_builtin_07 = @log2(some_vector);
//    ^^^^^^^^^^^^^^^^^ (@Vector(4,f32))()
const vector_builtin_08 = @log10(some_vector);
//    ^^^^^^^^^^^^^^^^^ (@Vector(4,f32))()
const vector_builtin_09 = @abs(some_vector);
//    ^^^^^^^^^^^^^^^^^ (@Vector(4,f32))()
const vector_builtin_10 = @floor(some_vector);
//    ^^^^^^^^^^^^^^^^^ (@Vector(4,f32))()
const vector_builtin_11 = @ceil(some_vector);
//    ^^^^^^^^^^^^^^^^^ (@Vector(4,f32))()
const vector_builtin_12 = @trunc(some_vector);
//    ^^^^^^^^^^^^^^^^^ (@Vector(4,f32))()
const vector_builtin_13 = @round(some_vector);
//    ^^^^^^^^^^^^^^^^^ (@Vector(4,f32))()

const invalid_builtin_00 = @sqrt(null);
//    ^^^^^^^^^^^^^^^^^^ (unknown)()
const invalid_builtin_01 = @sin(null);
//    ^^^^^^^^^^^^^^^^^^ (unknown)()
const invalid_builtin_02 = @cos(null);
//    ^^^^^^^^^^^^^^^^^^ (unknown)()
const invalid_builtin_03 = @tan(null);
//    ^^^^^^^^^^^^^^^^^^ (unknown)()
const invalid_builtin_04 = @exp(null);
//    ^^^^^^^^^^^^^^^^^^ (unknown)()
const invalid_builtin_05 = @exp2(null);
//    ^^^^^^^^^^^^^^^^^^ (unknown)()
const invalid_builtin_06 = @log(null);
//    ^^^^^^^^^^^^^^^^^^ (unknown)()
const invalid_builtin_07 = @log2(null);
//    ^^^^^^^^^^^^^^^^^^ (unknown)()
const invalid_builtin_08 = @log10(null);
//    ^^^^^^^^^^^^^^^^^^ (unknown)()
const invalid_builtin_09 = @abs(null);
//    ^^^^^^^^^^^^^^^^^^ (unknown)()
const invalid_builtin_10 = @floor(null);
//    ^^^^^^^^^^^^^^^^^^ (unknown)()
const invalid_builtin_11 = @ceil(null);
//    ^^^^^^^^^^^^^^^^^^ (unknown)()
const invalid_builtin_12 = @trunc(null);
//    ^^^^^^^^^^^^^^^^^^ (unknown)()
const invalid_builtin_13 = @round(null);
//    ^^^^^^^^^^^^^^^^^^ (unknown)()

const as = @as(bool, undefined);
//    ^^ (bool)()
const atomic_load = @atomicLoad(bool, undefined, .unordered);
//    ^^^^^^^^^^^ (bool)()
//                                               ^^^^^^^^^^ (AtomicOrder)()
const atomic_rmw = @atomicRmw(bool, undefined, .Xchg, undefined, .unordered);
//    ^^^^^^^^^^ (bool)()
//                                             ^^^^^ (AtomicRmwOp)()
//                                                               ^^^^^^^^^^ (AtomicOrder)()
const atomic_store = @atomicStore(undefined, undefined, undefined, .unordered);
//    ^^^^^^^^^^^^ (void)()
//                                                                 ^^^^^^^^^^ (AtomicOrder)()
const mul_add = @mulAdd(f32, undefined, undefined, undefined);
//    ^^^^^^^ (f32)()
const cmpxchg_strong = @cmpxchgStrong(u32, undefined, undefined, undefined, .unordered, .unordered);
//    ^^^^^^^^^^^^^^ (unknown)() TODO this should be `?u32`
//                                                                          ^^^^^^^^^^ (AtomicOrder)()
//                                                                                      ^^^^^^^^^^ (AtomicOrder)()
const cmpxchg_weak = @cmpxchgWeak(u32, undefined, undefined, undefined, .unordered, .unordered);
//    ^^^^^^^^^^^^ (unknown)() TODO this should be `?u32`
//                                                                      ^^^^^^^^^^ (AtomicOrder)()
//                                                                                  ^^^^^^^^^^ (AtomicOrder)()
const call = @call(.always_inline, undefined, undefined);
//    ^^^^ (unknown)() TODO
//                 ^^^^^^^^^^^^^^ (CallModifier)()
const export_ = @export(undefined, .{ .name = undefined });
//    ^^^^^^^ (void)()
//                                    ^^^^^ ([]const u8)()
const extern_ = @extern([*]u8, .{ .name = undefined });
//    ^^^^^^^ ([*]u8)()
//                                ^^^^^ ([]const u8)()
const prefetch = @prefetch(undefined, .{ .locality = 3 });
//    ^^^^^^^^ (void)()
//                                       ^^^^^^^^^ (u2)()
const reduce = @reduce(.And, undefined);
//    ^^^^^^ (unknown)() TODO
//                     ^^^^ (ReduceOp)()
const set_float_mode = @setFloatMode(.strict);
//    ^^^^^^^^^^^^^^ (void)()
//                                   ^^^^^^^ (FloatMode)()
const union_init = @unionInit(union {}, undefined, undefined);
//    ^^^^^^^^^^ (union {})()

const abs_i32 = @abs(@as(i32, undefined));
//    ^^^^^^^ (u32)()
const abs_u32 = @abs(@as(u32, undefined));
//    ^^^^^^^ (u32)()
const abs_i33 = @abs(@as(i33, undefined));
//    ^^^^^^^ (u33)()
const abs_u33 = @abs(@as(u33, undefined));
//    ^^^^^^^ (u33)()
const abs_isize = @abs(@as(isize, undefined));
//    ^^^^^^^^^ (usize)()
const abs_usize = @abs(@as(usize, undefined));
//    ^^^^^^^^^ (usize)()
const abs_c_int = @abs(@as(c_int, undefined));
//    ^^^^^^^^^ (c_uint)()
const abs_c_uint = @abs(@as(c_uint, undefined));
//    ^^^^^^^^^^ (c_uint)()
const abs_vector_i8 = @abs(@as(@Vector(4, i8), undefined));
//    ^^^^^^^^^^^^^ (@Vector(4,u8))()
const abs_vector_u8 = @abs(@as(@Vector(4, u8), undefined));
//    ^^^^^^^^^^^^^ (@Vector(4,u8))()

const abs_comptime_value = @abs(-42);
//    ^^^^^^^^^^^^^^^^^^ (comptime_int)(42)
const abs_i8_value = @abs(@as(i8, -128));
//    ^^^^^^^^^^^^ (u8)(128)
const abs_i128_value = @abs(@as(i128, -170141183460469231731687303715884105728));
//    ^^^^^^^^^^^^^^ (u128)(170141183460469231731687303715884105728)
const abs_u8_value = @abs(@as(u8, 42));
//    ^^^^^^^^^^^^ (u8)(42)
const abs_comptime_float_value = @abs(-42.75);
//    ^^^^^^^^^^^^^^^^^^^^^^^^ (comptime_float)(42.75)
const abs_f32_value = @abs(@as(f32, -42.75));
//    ^^^^^^^^^^^^^ (f32)(42.75)
const abs_f64_value = @abs(@as(f64, -42.75));
//    ^^^^^^^^^^^^^ (f64)(42.75)
const bit_reverse_u8_value = @bitReverse(@as(u8, 0b0000_0011));
//    ^^^^^^^^^^^^^^^^^^^^ (u8)(192)
const bit_reverse_i8_value = @bitReverse(@as(i8, 1));
//    ^^^^^^^^^^^^^^^^^^^^ (i8)(-128)
const byte_swap_u16_value = @byteSwap(@as(u16, 0x1234));
//    ^^^^^^^^^^^^^^^^^^^ (u16)(13330)
const byte_swap_u24_value = @byteSwap(@as(u24, 0x123456));
//    ^^^^^^^^^^^^^^^^^^^ (u24)(5649426)
const byte_swap_i16_value = @byteSwap(@as(i16, 0x1234));
//    ^^^^^^^^^^^^^^^^^^^ (i16)(13330)
const int_cast_i8_value: i8 = @intCast(@as(i16, -42));
//    ^^^^^^^^^^^^^^^^^ (i8)(-42)
const truncate_u8_value: u8 = @truncate(@as(u16, 0x1ff));
//    ^^^^^^^^^^^^^^^^^ (u8)(255)
const truncate_i8_value: i8 = @truncate(@as(i16, -1));
//    ^^^^^^^^^^^^^^^^^ (i8)(-1)
const bit_cast_i8_value: i8 = @bitCast(@as(u8, 255));
//    ^^^^^^^^^^^^^^^^^ (i8)(-1)
const bit_cast_u8_value: u8 = @bitCast(@as(i8, -1));
//    ^^^^^^^^^^^^^^^^^ (u8)(255)
const float_coercion_value: f32 = @as(f32, 42.75);
//    ^^^^^^^^^^^^^^^^^^^^ (f32)(42.75)
const negative_float_value: f64 = -@as(f64, 42.75);
//    ^^^^^^^^^^^^^^^^^^^^ (f64)(-42.75)
const int_from_float_u8_value: u8 = @intFromFloat(@as(f32, 42.75));
//    ^^^^^^^^^^^^^^^^^^^^^^^ (u8)(42)
const int_from_float_i8_value: i8 = @intFromFloat(@as(f64, -42.75));
//    ^^^^^^^^^^^^^^^^^^^^^^^ (i8)(-42)
const float_from_int_f32_value: f32 = @floatFromInt(@as(u16, 42));
//    ^^^^^^^^^^^^^^^^^^^^^^^^ (f32)(42)
const float_from_int_f64_value: f64 = @floatFromInt(@as(i16, -42));
//    ^^^^^^^^^^^^^^^^^^^^^^^^ (f64)(-42)
const float_cast_f32_value: f32 = @floatCast(@as(f64, 42.75));
//    ^^^^^^^^^^^^^^^^^^^^ (f32)(42.75)
const float_cast_f64_value: f64 = @floatCast(@as(f32, -42.75));
//    ^^^^^^^^^^^^^^^^^^^^ (f64)(-42.75)
const float_equal = @as(f32, 42.5) == @as(f64, 42.5);
//    ^^^^^^^^^^^ (bool)(true)
const float_less_than = @as(f64, -42.5) < @as(f32, 42.5);
//    ^^^^^^^^^^^^^^^ (bool)(true)
const float_signed_zero_equal = @as(f32, -0.0) == @as(f64, 0.0);
//    ^^^^^^^^^^^^^^^^^^^^^^^ (bool)(true)
const float_int_equal = @as(f32, 4.0) == 4;
//    ^^^^^^^^^^^^^^^ (bool)(true)
const float_int_less = @as(f32, 16777216.0) < 16777217;
//    ^^^^^^^^^^^^^^ (bool)(true)
const negative_float_int_less = @as(f64, -4.5) < -4;
//    ^^^^^^^^^^^^^^^^^^^^^^^ (bool)(true)
const float_min_value = @min(@as(f32, 2.5), @as(f64, 4.5));
//    ^^^^^^^^^^^^^^^ (f64)(2.5)
const float_max_value = @max(@as(f32, -2.5), @as(f64, -4.5));
//    ^^^^^^^^^^^^^^^ (f64)(-2.5)
const mixed_float_min_value = @min(@as(f32, 2.5), 4);
//    ^^^^^^^^^^^^^^^^^^^^^ (f32)(2.5)
const mixed_float_max_value = @max(4, @as(f64, 2.5));
//    ^^^^^^^^^^^^^^^^^^^^^ (f64)(4)
const float_min_negative_zero = @min(@as(f32, 0.0), @as(f32, -0.0));
//    ^^^^^^^^^^^^^^^^^^^^^^^ (f32)(-0)
const float_max_positive_zero = @max(@as(f64, -0.0), @as(f64, 0.0));
//    ^^^^^^^^^^^^^^^^^^^^^^^ (f64)(0)
const float_add_value = @as(f32, 6.0) + @as(f64, 2.0);
//    ^^^^^^^^^^^^^^^ (f64)(8)
const float_sub_value = @as(f32, 6.0) - @as(f64, 2.0);
//    ^^^^^^^^^^^^^^^ (f64)(4)
const float_mul_value = @as(f32, 6.0) * @as(f64, 2.0);
//    ^^^^^^^^^^^^^^^ (f64)(12)
const float_div_value = @as(f32, 6.0) / @as(f64, 2.0);
//    ^^^^^^^^^^^^^^^ (f64)(3)
const mixed_float_add_value = @as(f32, 2.5) + 2;
//    ^^^^^^^^^^^^^^^^^^^^^ (f32)(4.5)
const mixed_float_sub_value = 7 - @as(f64, 2.5);
//    ^^^^^^^^^^^^^^^^^^^^^ (f64)(4.5)
const mixed_float_mul_value = @as(f32, -2.5) * 4;
//    ^^^^^^^^^^^^^^^^^^^^^ (f32)(-10)
const mixed_float_div_value = 9 / @as(f64, 2.0);
//    ^^^^^^^^^^^^^^^^^^^^^ (f64)(4.5)
const mixed_float_rounding_value = @as(f32, 16777216.0) + 1;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^ (f32)(16777216)
const mul_add_f32_value = @mulAdd(f32, 2.5, 4.0, -1.0);
//    ^^^^^^^^^^^^^^^^^ (f32)(9)
const mul_add_f64_value = @mulAdd(f64, -2.0, 4.0, 1.0);
//    ^^^^^^^^^^^^^^^^^ (f64)(-7)
const floor_value = @floor(@as(f32, -2.75));
//    ^^^^^^^^^^^ (f32)(-3)
const ceil_value = @ceil(@as(f64, -2.75));
//    ^^^^^^^^^^ (f64)(-2)
const trunc_value = @trunc(@as(f32, -2.75));
//    ^^^^^^^^^^^ (f32)(-2)
const round_value = @round(@as(f64, -2.75));
//    ^^^^^^^^^^^ (f64)(-3)
const sqrt_f32_value = @sqrt(@as(f32, 9.0));
//    ^^^^^^^^^^^^^^ (f32)(3)
const sqrt_f64_negative_zero = @sqrt(@as(f64, -0.0));
//    ^^^^^^^^^^^^^^^^^^^^^^ (f64)(-0)
const sin_f32_value = @sin(@as(f32, 0.0));
//    ^^^^^^^^^^^^^ (f32)(0)
const cos_f64_value = @cos(@as(f64, 0.0));
//    ^^^^^^^^^^^^^ (f64)(1)
const tan_f32_value = @tan(@as(f32, 0.0));
//    ^^^^^^^^^^^^^ (f32)(0)
const exp_f64_value = @exp(@as(f64, 0.0));
//    ^^^^^^^^^^^^^ (f64)(1)
const exp2_f32_value = @exp2(@as(f32, 3.0));
//    ^^^^^^^^^^^^^^ (f32)(8)
const log_f64_value = @log(@as(f64, 1.0));
//    ^^^^^^^^^^^^^ (f64)(0)
const log2_f32_value = @log2(@as(f32, 8.0));
//    ^^^^^^^^^^^^^^ (f32)(3)
const log10_f64_value = @log10(@as(f64, 100.0));
//    ^^^^^^^^^^^^^^^ (f64)(2)
const float_mod_value = @mod(@as(f32, -7.5), @as(f64, 5.0));
//    ^^^^^^^^^^^^^^^ (f64)(2.5)
const float_rem_value = @rem(@as(f32, -7.5), @as(f64, 5.0));
//    ^^^^^^^^^^^^^^^ (f64)(-2.5)
const float_div_trunc_value = @divTrunc(@as(f32, -7.5), @as(f64, 2.0));
//    ^^^^^^^^^^^^^^^^^^^^^ (f64)(-3)
const float_div_floor_value = @divFloor(@as(f32, -7.5), @as(f64, 2.0));
//    ^^^^^^^^^^^^^^^^^^^^^ (f64)(-4)
const float_div_exact_value = @divExact(@as(f32, 8.0), @as(f64, 2.0));
//    ^^^^^^^^^^^^^^^^^^^^^ (f64)(4)
const mixed_float_div_trunc_value = @divTrunc(@as(f32, -7.5), 2);
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^ (f32)(-3)
const mixed_float_div_floor_value = @divFloor(@as(f32, -7.5), 2);
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^ (f32)(-4)
const mixed_float_div_exact_value = @divExact(@as(f32, 8.0), 2);
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^ (f32)(4)
const mixed_float_mod_value = @mod(@as(f32, -7.5), 5);
//    ^^^^^^^^^^^^^^^^^^^^^ (f32)(2.5)
const mixed_float_rem_value = @rem(@as(f32, -7.5), 5);
//    ^^^^^^^^^^^^^^^^^^^^^ (f32)(-2.5)
const wide_div_trunc_value = @divTrunc(@as(u128, 170141183460469231731687303715884105728), 2);
//    ^^^^^^^^^^^^^^^^^^^^ (u128)(85070591730234615865843651857942052864)
const wide_div_floor_value = @divFloor(@as(u128, 170141183460469231731687303715884105728), 2);
//    ^^^^^^^^^^^^^^^^^^^^ (u128)(85070591730234615865843651857942052864)
const wide_div_exact_value = @divExact(@as(u128, 170141183460469231731687303715884105728), 2);
//    ^^^^^^^^^^^^^^^^^^^^ (u128)(85070591730234615865843651857942052864)
const wide_mod_value = @mod(@as(u128, 170141183460469231731687303715884105728), 7);
//    ^^^^^^^^^^^^^^ (u128)(2)
const wide_rem_value = @rem(@as(u128, 170141183460469231731687303715884105728), 7);
//    ^^^^^^^^^^^^^^ (u128)(2)

const IntEnum = enum(u8) { first = 4, second };
const int_from_enum = @intFromEnum(IntEnum.second);
//    ^^^^^^^^^^^^^ (u8)(5)
const InferredEnum = enum { zero, one, two };
const int_from_inferred_enum = @intFromEnum(InferredEnum.two);
//    ^^^^^^^^^^^^^^^^^^^^^^ (u2)(2)
const enum_tag_name = @tagName(IntEnum.second);
//    ^^^^^^^^^^^^^ (*const [6:0]u8)()
const enum_tag_name_len = enum_tag_name.len;
//    ^^^^^^^^^^^^^^^^^ (usize)(6)
const enum_from_int: IntEnum = @enumFromInt(5);
//    ^^^^^^^^^^^^^ (IntEnum)()

const panic = @panic("foo");
//    ^^^^^ (noreturn)()
const trap = @trap();
//    ^^^^ (noreturn)()

const Int = @Int(.signed, 16);
//    ^^^ (type)()
//               ^^^^^^^ (Signedness)()
const Pointer = @Pointer(.one, undefined, undefined, undefined);
//    ^^^^^^^ (type)()
//                       ^^^^ (Size)()
const Struct = @Struct(.auto, undefined, &.{"foo"}, &.{i32}, &.{.{}});
//    ^^^^^^ (type)()
//                     ^^^^^ (ContainerLayout)()
//                                        ^ ([1][]const u8)()
//                                                            ^ ([?]Attributes)()
//                                                              ^ (Attributes)()
const Union = @Union(.auto, undefined, &.{"foo"}, &.{i32}, &.{.{}});
//    ^^^^^ (type)()
//                   ^^^^^ (ContainerLayout)()
//                                      ^ ([1][]const u8)()
//                                                          ^ ([?]Attributes)()
//                                                            ^ (Attributes)()
const Enum = @Enum(undefined, .exhaustive, undefined, undefined);
//    ^^^^ (type)()
//                            ^^^^^^^^^^^ (Mode)()
const Fn = @Fn(&.{i32}, &.{.{}}, undefined, .{});
//    ^^ (type)()
//                       ^ ([?]Attributes)()
//                         ^ (Attributes)()
//                                          ^ (Attributes)()

const type_enum_literal: @EnumLiteral() = .foo;
//    ^^^^^^^^^^^^^^^^^ (@EnumLiteral())()

const type_info = @typeInfo(u8);
//    ^^^^^^^^^ (Type)()

const type_name = @typeName(u8);
//    ^^^^^^^^^ (*const [2:0]u8)()

const tag_name = @tagName(type_enum_literal);
//    ^^^^^^^^ ([:0]const u8)()

const error_name = @errorName(error.Foo);
//    ^^^^^^^^^^ ([:0]const u8)()

comptime {
    // Use @compileLog to verify the expected type with the compiler
    // @compileLog(vector_builtin_13);
}

fn builtin_calls() void {
    @branchHint(.none);
    //          ^^^^^ (BranchHint)()

    const trace = @errorReturnTrace();
    //    ^^^^^ (?*StackTrace)()
    _ = trace;

    const src = @src();
    //    ^^^ (SourceLocation)()
    _ = src;
}

fn varargs(...) callconv(.c) void {
    var ap = @cVaStart();
    //  ^^ (either type)()
    const copy = @cVaCopy(&ap);
    //    ^^^^ (either type)()
    const arg = @cVaArg(&ap, c_int);
    //    ^^^ (c_int)()
    const end = @cVaEnd(&ap);
    //    ^^^ (void)()
    _ = .{ copy, arg, end };
}
