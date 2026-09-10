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
const splat_value: @Vector(4, u8) = @splat(7);
const splat_value_index = splat_value[2];
//    ^^^^^^^^^^^^^^^^^ (u8)(7)
const reduce_add_value = @reduce(.Add, @as(@Vector(4, u8), @splat(250)));
//    ^^^^^^^^^^^^^^^^ (u8)(232)
const reduce_mul_value = @reduce(.Mul, @as(@Vector(4, u8), @splat(4)));
//    ^^^^^^^^^^^^^^^^ (u8)(0)
const reduce_and_value = @reduce(.And, @as(@Vector(3, u8), @splat(11)));
//    ^^^^^^^^^^^^^^^^ (u8)(11)
const reduce_or_value = @reduce(.Or, @as(@Vector(3, u8), @splat(11)));
//    ^^^^^^^^^^^^^^^ (u8)(11)
const reduce_xor_value = @reduce(.Xor, @as(@Vector(4, u8), @splat(11)));
//    ^^^^^^^^^^^^^^^^ (u8)(0)
const reduce_min_value = @reduce(.Min, @as(@Vector(3, i8), @splat(-5)));
//    ^^^^^^^^^^^^^^^^ (i8)(-5)
const reduce_max_value = @reduce(.Max, @as(@Vector(3, i8), @splat(-5)));
//    ^^^^^^^^^^^^^^^^ (i8)(-5)
const reduce_bool_and_value = @reduce(.And, @as(@Vector(3, bool), @splat(true)));
//    ^^^^^^^^^^^^^^^^^^^^^ (bool)(true)
const reduce_bool_or_value = @reduce(.Or, @as(@Vector(3, bool), @splat(false)));
//    ^^^^^^^^^^^^^^^^^^^^ (bool)(false)
const reduce_bool_xor_value = @reduce(.Xor, @as(@Vector(3, bool), @splat(true)));
//    ^^^^^^^^^^^^^^^^^^^^^ (bool)(true)
const reduce_bool_and_partial = @reduce(.And, @as(@Vector(3, bool), .{ runtime_bool, false, true }));
//    ^^^^^^^^^^^^^^^^^^^^^^^ (bool)(false)
const reduce_bool_or_partial = @reduce(.Or, @as(@Vector(3, bool), .{ runtime_bool, false, true }));
//    ^^^^^^^^^^^^^^^^^^^^^^ (bool)(true)
const reduce_bool_xor_partial = @reduce(.Xor, @as(@Vector(3, bool), .{ runtime_bool, false, true }));
//    ^^^^^^^^^^^^^^^^^^^^^^^ (bool)()
const reduce_even_integer_runtime_splat = @reduce(.Xor, @as(@Vector(4, u8), @splat(runtime_u8)));
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)(0)
const reduce_odd_integer_runtime_splat = @reduce(.Xor, @as(@Vector(3, u8), @splat(runtime_u8)));
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)()
const reduce_even_bool_runtime_splat = @reduce(.Xor, @as(@Vector(4, bool), @splat(runtime_bool)));
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)(false)
const reduce_odd_bool_runtime_splat = @reduce(.Xor, @as(@Vector(3, bool), @splat(runtime_bool)));
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)()
const reduce_even_undefined_splat = @reduce(.Xor, @as(@Vector(4, u8), @splat(undefined_u8)));
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)()
const reduce_bool_and_undefined = @reduce(.And, @as(@Vector(2, bool), .{ false, undefined }));
//    ^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)()
var runtime_u8: u8 = undefined;
var runtime_i8: i8 = undefined;
const reduce_integer_mul_partial = @reduce(.Mul, @as(@Vector(3, u8), .{ runtime_u8, 0, 7 }));
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)(0)
const reduce_integer_and_partial = @reduce(.And, @as(@Vector(3, u8), .{ runtime_u8, 0, 255 }));
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)(0)
const reduce_integer_or_partial = @reduce(.Or, @as(@Vector(3, u8), .{ runtime_u8, 255, 0 }));
//    ^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)(255)
const reduce_signed_or_partial = @reduce(.Or, @as(@Vector(3, i8), .{ runtime_i8, -1, 0 }));
//    ^^^^^^^^^^^^^^^^^^^^^^^^ (i8)(-1)
const reduce_integer_min_partial = @reduce(.Min, @as(@Vector(3, i8), .{ runtime_i8, -128, 7 }));
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^ (i8)(-128)
const reduce_integer_max_partial = @reduce(.Max, @as(@Vector(3, i8), .{ runtime_i8, 127, -7 }));
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^ (i8)(127)
const reduce_integer_add_partial = @reduce(.Add, @as(@Vector(3, u8), .{ runtime_u8, 0, 7 }));
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)()
const reduce_integer_and_undefined = @reduce(.And, @as(@Vector(2, u8), .{ 0, undefined }));
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)()
const reduce_float_add_value = @reduce(.Add, @as(@Vector(4, f32), @splat(2.5)));
//    ^^^^^^^^^^^^^^^^^^^^^^ (f32)(10)
const reduce_float_mul_value = @reduce(.Mul, @as(@Vector(3, f64), @splat(-2.0)));
//    ^^^^^^^^^^^^^^^^^^^^^^ (f64)(-8)
const reduce_float_min_zero = @reduce(.Min, @as(@Vector(2, f32), .{ 0.0, -0.0 }));
//    ^^^^^^^^^^^^^^^^^^^^^ (f32)(-0)
const reduce_float_max_zero = @reduce(.Max, @as(@Vector(2, f64), .{ -0.0, 0.0 }));
//    ^^^^^^^^^^^^^^^^^^^^^ (f64)(0)
const vector_sqrt_value = @sqrt(@as(@Vector(2, f32), .{ 4.0, 9.0 }))[1];
//    ^^^^^^^^^^^^^^^^^ (f32)(3)
const vector_sin_value = @sin(@as(@Vector(2, f32), @splat(0.0)))[0];
//    ^^^^^^^^^^^^^^^^ (f32)(0)
const vector_cos_value = @cos(@as(@Vector(2, f64), @splat(0.0)))[1];
//    ^^^^^^^^^^^^^^^^ (f64)(1)
const vector_tan_value = @tan(@as(@Vector(2, f32), @splat(0.0)))[0];
//    ^^^^^^^^^^^^^^^^ (f32)(0)
const vector_exp_value = @exp(@as(@Vector(2, f64), @splat(0.0)))[1];
//    ^^^^^^^^^^^^^^^^ (f64)(1)
const vector_exp2_value = @exp2(@as(@Vector(2, f32), @splat(3.0)))[0];
//    ^^^^^^^^^^^^^^^^^ (f32)(8)
const vector_log_value = @log(@as(@Vector(2, f64), @splat(1.0)))[1];
//    ^^^^^^^^^^^^^^^^ (f64)(0)
const vector_log2_value = @log2(@as(@Vector(2, f32), @splat(8.0)))[0];
//    ^^^^^^^^^^^^^^^^^ (f32)(3)
const vector_log10_value = @log10(@as(@Vector(2, f64), @splat(100.0)))[1];
//    ^^^^^^^^^^^^^^^^^^ (f64)(2)
const vector_abs_value = @abs(@as(@Vector(2, f32), @splat(-4.5)))[0];
//    ^^^^^^^^^^^^^^^^ (f32)(4.5)
const vector_floor_value = @floor(@as(@Vector(2, f64), @splat(-2.5)))[1];
//    ^^^^^^^^^^^^^^^^^^ (f64)(-3)
const vector_ceil_value = @ceil(@as(@Vector(2, f32), @splat(-2.5)))[0];
//    ^^^^^^^^^^^^^^^^^ (f32)(-2)
const vector_trunc_value = @trunc(@as(@Vector(2, f64), @splat(-2.5)))[1];
//    ^^^^^^^^^^^^^^^^^^ (f64)(-2)
const vector_round_value = @round(@as(@Vector(2, f32), @splat(-2.5)))[0];
//    ^^^^^^^^^^^^^^^^^^ (f32)(-3)
const vector_int_from_bool_value = @intFromBool(@as(@Vector(3, bool), .{ true, false, true }))[1];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^ (u1)(0)
var runtime_bool = true;
const vector_int_from_bool_partial = @intFromBool(@as(@Vector(3, bool), .{ runtime_bool, false, true }))[1];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (u1)(0)
const vector_int_from_bool_runtime = @intFromBool(@as(@Vector(3, bool), @splat(runtime_bool)));
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (@Vector(3,u1))()
const vector_clz_value = @clz(@as(@Vector(2, u8), .{ 0b00110000, 1 }))[0];
//    ^^^^^^^^^^^^^^^^ (u4)(2)
const vector_ctz_value = @ctz(@as(@Vector(2, u8), .{ 0b00110000, 1 }))[1];
//    ^^^^^^^^^^^^^^^^ (u4)(0)
const vector_pop_count_value = @popCount(@as(@Vector(2, i8), .{ -16, 1 }))[0];
//    ^^^^^^^^^^^^^^^^^^^^^^ (u4)(4)
const vector_bit_reverse_value = @bitReverse(@as(@Vector(2, u8), .{ 0b00110000, 1 }))[1];
//    ^^^^^^^^^^^^^^^^^^^^^^^^ (u8)(128)
const vector_byte_swap_value = @byteSwap(@as(@Vector(2, u16), .{ 0x1234, 0xabcd }))[0];
//    ^^^^^^^^^^^^^^^^^^^^^^ (u16)(13330)
const select_value = @select(
    u8,
    @as(@Vector(4, bool), .{ true, false, true, false }),
    @as(@Vector(4, u8), .{ 1, 2, 3, 4 }),
    @as(@Vector(4, u8), .{ 5, 6, 7, 8 }),
);
const select_value_index = select_value[1];
//    ^^^^^^^^^^^^^^^^^^ (u8)(6)
const select_equal_unknown_predicate = @select(
    u8,
    @as(@Vector(3, bool), .{ true, false, runtime_bool }),
    @as(@Vector(3, u8), .{ 7, runtime_u8, 9 }),
    @as(@Vector(3, u8), .{ runtime_u8, 8, 9 }),
);
const select_equal_unknown_predicate_value = select_equal_unknown_predicate[2];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)(9)
const select_equal_runtime_predicate = @select(
    u8,
    @as(@Vector(2, bool), @splat(runtime_bool)),
    @as(@Vector(2, u8), @splat(5)),
    @as(@Vector(2, u8), @splat(5)),
);
const select_equal_runtime_predicate_value = select_equal_runtime_predicate[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)(5)
const select_runtime_lhs = @select(
    u8,
    @as(@Vector(2, bool), .{ false, true }),
    @as(@Vector(2, u8), @splat(runtime_u8)),
    @as(@Vector(2, u8), .{ 3, 4 }),
);
const select_runtime_lhs_value = select_runtime_lhs[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^ (u8)(3)
const select_undefined_predicate = @select(
    u8,
    @as(@Vector(1, bool), .{undefined}),
    @as(@Vector(1, u8), .{5}),
    @as(@Vector(1, u8), .{5}),
);
const select_undefined_predicate_value = select_undefined_predicate[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)()
const shuffle_value = @shuffle(
    u8,
    @as(@Vector(2, u8), .{ 1, 2 }),
    @as(@Vector(2, u8), .{ 3, 4 }),
    @Vector(3, i32){ 1, -1, -2 },
);
const shuffle_value_index = shuffle_value[2];
//    ^^^^^^^^^^^^^^^^^^^ (u8)(4)
const unequal_shuffle_value = @shuffle(
    u8,
    @as(@Vector(2, u8), .{ 1, 2 }),
    @as(@Vector(3, u8), .{ 3, 4, 5 }),
    @Vector(2, i32){ 1, -3 },
);
const unequal_shuffle_value_index = unequal_shuffle_value[1];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)(5)
const shuffle_runtime_lhs = @shuffle(
    u8,
    @as(@Vector(2, u8), @splat(runtime_u8)),
    @as(@Vector(2, u8), .{ 3, 4 }),
    @Vector(2, i32){ -1, -2 },
);
const shuffle_runtime_lhs_value = shuffle_runtime_lhs[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)(3)
const shuffle_runtime_rhs = @shuffle(
    u8,
    @as(@Vector(2, u8), .{ 5, 6 }),
    @as(@Vector(2, u8), @splat(runtime_u8)),
    @Vector(2, i32){ 0, 1 },
);
const shuffle_runtime_rhs_value = shuffle_runtime_rhs[1];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)(6)

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
const add_overflow_value = @addWithOverflow(@as(u8, 250), 10)[0];
//    ^^^^^^^^^^^^^^^^^^ (u8)(4)
const add_overflow_flag = @addWithOverflow(@as(u8, 250), 10)[1];
//    ^^^^^^^^^^^^^^^^^ (u1)(1)
const sub_overflow_value = @subWithOverflow(@as(u8, 2), 3)[0];
//    ^^^^^^^^^^^^^^^^^^ (u8)(255)
const sub_overflow_flag = @subWithOverflow(@as(u8, 2), 3)[1];
//    ^^^^^^^^^^^^^^^^^ (u1)(1)
const mul_overflow_value = @mulWithOverflow(@as(i8, 40), 4)[0];
//    ^^^^^^^^^^^^^^^^^^ (i8)(-96)
const mul_overflow_flag = @mulWithOverflow(@as(i8, 40), 4)[1];
//    ^^^^^^^^^^^^^^^^^ (u1)(1)
const shl_overflow_value = @shlWithOverflow(@as(u8, 0x40), 2)[0];
//    ^^^^^^^^^^^^^^^^^^ (u8)(0)
const shl_overflow_flag = @shlWithOverflow(@as(u8, 0x40), 2)[1];
//    ^^^^^^^^^^^^^^^^^ (u1)(1)
const add_no_overflow_value = @addWithOverflow(@as(u8, 2), 3)[0];
//    ^^^^^^^^^^^^^^^^^^^^^ (u8)(5)
const add_no_overflow_flag = @addWithOverflow(@as(u8, 2), 3)[1];
//    ^^^^^^^^^^^^^^^^^^^^ (u1)(0)
const add_zero_runtime = @addWithOverflow(runtime_u8, @as(u8, 0));
const add_zero_runtime_value = add_zero_runtime[0];
//    ^^^^^^^^^^^^^^^^^^^^^^ (u8)()
const add_zero_runtime_flag = add_zero_runtime[1];
//    ^^^^^^^^^^^^^^^^^^^^^ (u1)(0)
const add_complement_runtime = @addWithOverflow(runtime_u8, ~runtime_u8);
const add_complement_runtime_value = add_complement_runtime[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)(255)
const add_complement_runtime_flag = add_complement_runtime[1];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^ (u1)(0)
const add_complement_undefined = @addWithOverflow(undefined_u8, ~undefined_u8);
const add_complement_undefined_value = add_complement_undefined[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)()
const add_complement_undefined_flag = add_complement_undefined[1];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (u1)()
const sub_zero_runtime_flag = @subWithOverflow(runtime_u8, @as(u8, 0))[1];
//    ^^^^^^^^^^^^^^^^^^^^^ (u1)(0)
const sub_self_runtime = @subWithOverflow(runtime_u8, runtime_u8);
const sub_self_runtime_value = sub_self_runtime[0];
//    ^^^^^^^^^^^^^^^^^^^^^^ (u8)(0)
const sub_self_runtime_flag = sub_self_runtime[1];
//    ^^^^^^^^^^^^^^^^^^^^^ (u1)(0)
const sub_self_undefined = @subWithOverflow(undefined_u8, undefined_u8);
const sub_self_undefined_value = sub_self_undefined[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^ (u8)()
const sub_self_undefined_flag = sub_self_undefined[1];
//    ^^^^^^^^^^^^^^^^^^^^^^^ (u1)()
const mul_zero_runtime_value = @mulWithOverflow(runtime_i8, @as(i8, 0))[0];
//    ^^^^^^^^^^^^^^^^^^^^^^ (i8)(0)
const mul_zero_runtime_flag = @mulWithOverflow(runtime_i8, @as(i8, 0))[1];
//    ^^^^^^^^^^^^^^^^^^^^^ (u1)(0)
const mul_one_runtime_flag = @mulWithOverflow(runtime_i8, @as(i8, 1))[1];
//    ^^^^^^^^^^^^^^^^^^^^ (u1)(0)
const shl_zero_runtime_flag = @shlWithOverflow(runtime_u8, @as(u3, 0))[1];
//    ^^^^^^^^^^^^^^^^^^^^^ (u1)(0)
const shl_zero_lhs_runtime = @shlWithOverflow(@as(u8, 0), runtime_u3);
const shl_zero_lhs_runtime_value = shl_zero_lhs_runtime[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)(0)
const shl_zero_lhs_runtime_flag = shl_zero_lhs_runtime[1];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^ (u1)(0)
const shl_zero_lhs_undefined = @shlWithOverflow(@as(u8, 0), undefined_u3);
const shl_zero_lhs_undefined_value = shl_zero_lhs_undefined[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)()
const shl_zero_lhs_undefined_flag = shl_zero_lhs_undefined[1];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^ (u1)()
const mul_zero_undefined_flag = @mulWithOverflow(@as(u8, undefined), @as(u8, 0))[1];
//    ^^^^^^^^^^^^^^^^^^^^^^^ (u1)()
const cmpxchg_strong = @cmpxchgStrong(u32, undefined, undefined, undefined, .unordered, .unordered);
//    ^^^^^^^^^^^^^^ (?u32)()
//                                                                          ^^^^^^^^^^ (AtomicOrder)()
//                                                                                      ^^^^^^^^^^ (AtomicOrder)()
const cmpxchg_weak = @cmpxchgWeak(u32, undefined, undefined, undefined, .unordered, .unordered);
//    ^^^^^^^^^^^^ (?u32)()
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
const abs_vector_i8_value = @abs(@as(@Vector(2, i8), .{ -128, 4 }))[0];
//    ^^^^^^^^^^^^^^^^^^^ (u8)(128)

const abs_comptime_value = @abs(-42);
//    ^^^^^^^^^^^^^^^^^^ (comptime_int)(42)
const abs_i8_value = @abs(@as(i8, -128));
//    ^^^^^^^^^^^^ (u8)(128)
const abs_i128_value = @abs(@as(i128, -170141183460469231731687303715884105728));
//    ^^^^^^^^^^^^^^ (u128)(170141183460469231731687303715884105728)
const abs_i256_value = @abs(@as(i256, -1606938044258990275541962092341162602522202993782792835301376));
//    ^^^^^^^^^^^^^^ (u256)(1606938044258990275541962092341162602522202993782792835301376)
const abs_min_i256_value = @abs(@as(i256, -57896044618658097711785492504343953926634992332820282019728792003956564819968));
//    ^^^^^^^^^^^^^^^^^^ (u256)(57896044618658097711785492504343953926634992332820282019728792003956564819968)
const abs_u256_value = @abs(@as(u256, 1606938044258990275541962092341162602522202993782792835301376));
//    ^^^^^^^^^^^^^^ (u256)(1606938044258990275541962092341162602522202993782792835301376)
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
const bit_reverse_u256_value = @bitReverse(@as(u256, 1));
//    ^^^^^^^^^^^^^^^^^^^^^^ (u256)(57896044618658097711785492504343953926634992332820282019728792003956564819968)
const bit_reverse_i256_value = @bitReverse(@as(i256, 1));
//    ^^^^^^^^^^^^^^^^^^^^^^ (i256)(-57896044618658097711785492504343953926634992332820282019728792003956564819968)
const byte_swap_u16_value = @byteSwap(@as(u16, 0x1234));
//    ^^^^^^^^^^^^^^^^^^^ (u16)(13330)
const byte_swap_u24_value = @byteSwap(@as(u24, 0x123456));
//    ^^^^^^^^^^^^^^^^^^^ (u24)(5649426)
const byte_swap_u256_value = @byteSwap(@as(u256, 1));
//    ^^^^^^^^^^^^^^^^^^^^ (u256)(452312848583266388373324160190187140051835877600158453279131187530910662656)
const byte_swap_i16_value = @byteSwap(@as(i16, 0x1234));
//    ^^^^^^^^^^^^^^^^^^^ (i16)(13330)
const bit_reverse_u128_value = @bitReverse(@as(u128, 1));
//    ^^^^^^^^^^^^^^^^^^^^^^ (u128)(170141183460469231731687303715884105728)
const bit_reverse_i128_value = @bitReverse(@as(i128, 1));
//    ^^^^^^^^^^^^^^^^^^^^^^ (i128)(-170141183460469231731687303715884105728)
const byte_swap_u128_value = @byteSwap(@as(u128, 0x0123456789abcdef0011223344556677));
//    ^^^^^^^^^^^^^^^^^^^^ (u128)(158709475186131821931889503309083779841)
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
const int_cast_u128_value: u128 = @intCast(@as(u129, 170141183460469231731687303715884105728));
//    ^^^^^^^^^^^^^^^^^^^ (u128)(170141183460469231731687303715884105728)
const truncate_u128_value: u128 = @truncate((@as(u256, 1) << 128) | 5);
//    ^^^^^^^^^^^^^^^^^^^ (u128)(5)
const truncate_u256_value: u256 = @truncate(@as(u512, 2037035976334486086268445688409378161051468393665936250636140449354381299763336706183397381));
//    ^^^^^^^^^^^^^^^^^^^ (u256)(5)
const truncate_i256_value: i256 = @truncate(@as(i512, -1));
//    ^^^^^^^^^^^^^^^^^^^ (i256)(-1)
const bit_cast_i128_value: i128 = @bitCast(@as(u128, 170141183460469231731687303715884105728));
//    ^^^^^^^^^^^^^^^^^^^ (i128)(-170141183460469231731687303715884105728)
const bit_cast_u128_value: u128 = @bitCast(bit_cast_i128_value);
//    ^^^^^^^^^^^^^^^^^^^ (u128)(170141183460469231731687303715884105728)
const bit_cast_i256_value: i256 = @bitCast(@as(u256, 115792089237316195423570985008687907853269984665640564039457584007913129639935));
//    ^^^^^^^^^^^^^^^^^^^ (i256)(-1)
const bit_cast_u256_value: u256 = @bitCast(bit_cast_i256_value);
//    ^^^^^^^^^^^^^^^^^^^ (u256)(115792089237316195423570985008687907853269984665640564039457584007913129639935)
const bit_cast_min_i256_value: i256 = @bitCast(@as(u256, 57896044618658097711785492504343953926634992332820282019728792003956564819968));
//    ^^^^^^^^^^^^^^^^^^^^^^^ (i256)(-57896044618658097711785492504343953926634992332820282019728792003956564819968)
const vector_int_from_float: @Vector(2, i8) = @intFromFloat(@as(@Vector(2, f32), .{ -2.75, 4.5 }));
const vector_int_from_float_value = vector_int_from_float[1];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^ (i8)(4)
const vector_float_from_int: @Vector(2, f32) = @floatFromInt(@as(@Vector(2, i16), .{ -3, 5 }));
const vector_float_from_int_value = vector_float_from_int[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^ (f32)(-3)
const vector_float_cast: @Vector(2, f16) = @floatCast(@as(@Vector(2, f32), .{ 2.5, 4.5 }));
const vector_float_cast_value = vector_float_cast[1];
//    ^^^^^^^^^^^^^^^^^^^^^^^ (f16)(4.5)
const vector_int_cast: @Vector(2, u8) = @intCast(@as(@Vector(2, u16), .{ 4, 7 }));
const vector_int_cast_value = vector_int_cast[0];
//    ^^^^^^^^^^^^^^^^^^^^^ (u8)(4)
const vector_truncate: @Vector(2, u8) = @truncate(@as(@Vector(2, u16), .{ 0x104, 0x107 }));
const vector_truncate_value = vector_truncate[1];
//    ^^^^^^^^^^^^^^^^^^^^^ (u8)(7)
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
const float_from_int_u128_value: f128 = @floatFromInt(@as(u128, 18446744073709551616));
//    ^^^^^^^^^^^^^^^^^^^^^^^^^ (f128)(18446744073709552000)
const float_from_int_i128_value: f128 = @floatFromInt(@as(i128, -18446744073709551616));
//    ^^^^^^^^^^^^^^^^^^^^^^^^^ (f128)(-18446744073709552000)
const int_from_float_u128_value: u128 = @intFromFloat(@as(f128, 18446744073709551616.75));
//    ^^^^^^^^^^^^^^^^^^^^^^^^^ (u128)(18446744073709551616)
const int_from_float_i128_value: i128 = @intFromFloat(@as(f128, -18446744073709551616.75));
//    ^^^^^^^^^^^^^^^^^^^^^^^^^ (i128)(-18446744073709551616)
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
const scalar_min_runtime_boundary = @min(runtime_i8, @as(i8, -128));
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^ (i8)(-128)
const scalar_max_runtime_boundary = @max(runtime_i8, @as(i8, 127));
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^ (i8)(127)
const scalar_min_unsigned_boundary = @min(runtime_u8, @as(u8, 0));
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)(0)
const scalar_max_unsigned_boundary = @max(runtime_u8, @as(u8, 255));
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)(255)
const scalar_min_runtime_middle = @min(runtime_i8, @as(i8, -10));
//    ^^^^^^^^^^^^^^^^^^^^^^^^^ (i8)()
const scalar_min_undefined_boundary = @min(@as(i8, undefined), @as(i8, -128));
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (i8)()
const float_min_negative_zero = @min(@as(f32, 0.0), @as(f32, -0.0));
//    ^^^^^^^^^^^^^^^^^^^^^^^ (f32)(-0)
const float_max_positive_zero = @max(@as(f64, -0.0), @as(f64, 0.0));
//    ^^^^^^^^^^^^^^^^^^^^^^^ (f64)(0)
const vector_min = @min(
    @as(@Vector(2, i8), .{ 4, -2 }),
    @as(@Vector(2, i8), .{ 3, 7 }),
    @as(@Vector(2, i8), .{ 5, 1 }),
);
const vector_min_value = vector_min[0];
//    ^^^^^^^^^^^^^^^^ (i8)(3)
const vector_max = @max(
    @as(@Vector(2, i8), .{ 4, -2 }),
    @as(@Vector(2, i8), .{ 3, 7 }),
    @as(@Vector(2, i8), .{ 5, 1 }),
);
const vector_max_value = vector_max[1];
//    ^^^^^^^^^^^^^^^^ (i8)(7)
var runtime_i8_vector: @Vector(2, i8) = undefined;
const undefined_u8: u8 = undefined;
const vector_min_runtime_boundary = @min(runtime_i8_vector, @as(@Vector(2, i8), @splat(-128)))[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^ (i8)(-128)
const vector_max_runtime_boundary = @max(runtime_i8_vector, @as(@Vector(2, i8), @splat(127)))[1];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^ (i8)(127)
const vector_min_runtime_middle = @min(runtime_i8_vector, @as(@Vector(2, i8), @splat(-10)))[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^ (i8)()
const vector_min_undefined_boundary = @min(@as(@Vector(2, i8), .{ undefined, 0 }), @as(@Vector(2, i8), @splat(-128)))[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (i8)()
const vector_min_zero = @min(@as(@Vector(2, f32), .{ 0.0, 2.0 }), @as(@Vector(2, f32), .{ -0.0, 3.0 }))[0];
//    ^^^^^^^^^^^^^^^ (f32)(-0)
const vector_max_zero = @max(@as(@Vector(2, f32), .{ -0.0, 2.0 }), @as(@Vector(2, f32), .{ 0.0, 3.0 }))[0];
//    ^^^^^^^^^^^^^^^ (f32)(0)
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
const vector_mul_add = @mulAdd(
    @Vector(2, f32),
    @as(@Vector(2, f32), .{ 2.5, 3.0 }),
    @as(@Vector(2, f32), .{ 4.0, 5.0 }),
    @as(@Vector(2, f32), .{ -1.0, 2.0 }),
);
const vector_mul_add_value = vector_mul_add[1];
//    ^^^^^^^^^^^^^^^^^^^^ (f32)(17)
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
const wide_i256_div_trunc_value = @divTrunc(@as(i256, -28948022309329048855892746252171976963317496166410141009864396001978282409989), 7);
//    ^^^^^^^^^^^^^^^^^^^^^^^^^ (i256)(-4135431758475578407984678036024568137616785166630020144266342285996897487141)
const wide_i256_div_floor_value = @divFloor(@as(i256, -28948022309329048855892746252171976963317496166410141009864396001978282409989), 7);
//    ^^^^^^^^^^^^^^^^^^^^^^^^^ (i256)(-4135431758475578407984678036024568137616785166630020144266342285996897487142)
const wide_i256_rem_value = @rem(@as(i256, -28948022309329048855892746252171976963317496166410141009864396001978282409989), 7);
//    ^^^^^^^^^^^^^^^^^^^ (i256)(-2)
const wide_i256_mod_value = @mod(@as(i256, -28948022309329048855892746252171976963317496166410141009864396001978282409989), 7);
//    ^^^^^^^^^^^^^^^^^^^ (i256)(5)
const wide_u256_div_exact_value = @divExact(@as(u256, 57896044618658097711785492504343953926634992332820282019728792003956564819968), 8);
//    ^^^^^^^^^^^^^^^^^^^^^^^^^ (u256)(7237005577332262213973186563042994240829374041602535252466099000494570602496)
const mod_one_runtime = @mod(runtime_i8, @as(i8, 1));
//    ^^^^^^^^^^^^^^^ (i8)(0)
const rem_one_runtime = @rem(runtime_i8, @as(i8, 1));
//    ^^^^^^^^^^^^^^^ (i8)(0)
const mod_one_undefined = @mod(@as(i8, undefined), @as(i8, 1));
//    ^^^^^^^^^^^^^^^^^ (i8)()
const shl_exact_u8_value = @shlExact(@as(u8, 3), 2);
//    ^^^^^^^^^^^^^^^^^^ (u8)(12)
const shr_exact_i8_value = @shrExact(@as(i8, -12), 2);
//    ^^^^^^^^^^^^^^^^^^ (i8)(-3)
const shl_exact_zero_runtime = @shlExact(@as(u8, 0), runtime_u3);
//    ^^^^^^^^^^^^^^^^^^^^^^ (u8)(0)
const shr_exact_zero_runtime = @shrExact(@as(u8, 0), runtime_u3);
//    ^^^^^^^^^^^^^^^^^^^^^^ (u8)(0)
const shl_exact_u128_value = @shlExact(@as(u128, 1), 127);
//    ^^^^^^^^^^^^^^^^^^^^ (u128)(170141183460469231731687303715884105728)
const shr_exact_u128_value = @shrExact(@as(u128, 170141183460469231731687303715884105728), 127);
//    ^^^^^^^^^^^^^^^^^^^^ (u128)(1)
const shl_exact_u256_value = @shlExact(@as(u256, 1), 200);
//    ^^^^^^^^^^^^^^^^^^^^ (u256)(1606938044258990275541962092341162602522202993782792835301376)
const shr_exact_u256_value = @shrExact(@as(u256, 1606938044258990275541962092341162602522202993782792835301376), 200);
//    ^^^^^^^^^^^^^^^^^^^^ (u256)(1)
const shr_exact_i256_value = @shrExact(@as(i256, -8), 3);
//    ^^^^^^^^^^^^^^^^^^^^ (i256)(-1)
const vector_div_trunc_value = @divTrunc(@as(@Vector(2, i8), .{ -7, 8 }), @as(@Vector(2, i8), .{ 3, 2 }))[0];
//    ^^^^^^^^^^^^^^^^^^^^^^ (i8)(-2)
const vector_div_floor_value = @divFloor(@as(@Vector(2, i8), .{ -7, 8 }), @as(@Vector(2, i8), .{ 3, 2 }))[0];
//    ^^^^^^^^^^^^^^^^^^^^^^ (i8)(-3)
const vector_div_exact_value = @divExact(@as(@Vector(2, i8), .{ 6, 8 }), @as(@Vector(2, i8), .{ 3, 2 }))[1];
//    ^^^^^^^^^^^^^^^^^^^^^^ (i8)(4)
var runtime_u3: u3 = undefined;
const undefined_u3: u3 = undefined;
const vector_shl_exact_zero_runtime = @shlExact(@as(@Vector(2, u8), @splat(0)), @as(@Vector(2, u3), @splat(runtime_u3)))[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)(0)
const vector_shr_exact_zero_runtime = @shrExact(@as(@Vector(2, u8), @splat(0)), @as(@Vector(2, u3), @splat(runtime_u3)))[1];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)(0)
const vector_mod_value = @mod(@as(@Vector(2, i8), .{ -7, 8 }), @as(@Vector(2, i8), .{ 3, 2 }))[0];
//    ^^^^^^^^^^^^^^^^ (i8)(2)
const vector_rem_value = @rem(@as(@Vector(2, i8), .{ -7, 8 }), @as(@Vector(2, i8), .{ 3, 2 }))[0];
//    ^^^^^^^^^^^^^^^^ (i8)(-1)
const vector_mod_one_runtime = @mod(runtime_i8_vector, @as(@Vector(2, i8), @splat(1)))[0];
//    ^^^^^^^^^^^^^^^^^^^^^^ (i8)(0)
const vector_rem_one_runtime = @rem(runtime_i8_vector, @as(@Vector(2, i8), @splat(1)))[1];
//    ^^^^^^^^^^^^^^^^^^^^^^ (i8)(0)
const vector_float_div_floor_value = @divFloor(@as(@Vector(2, f32), .{ -7.5, 8.0 }), @as(@Vector(2, f32), .{ 2.0, 2.0 }))[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (f32)(-4)

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
const WideEnum = enum(u128) { low = 1, high = 170141183460469231731687303715884105728 };
const wide_enum_from_int: WideEnum = @enumFromInt(170141183460469231731687303715884105728);
const wide_enum_to_int = @intFromEnum(wide_enum_from_int);
//    ^^^^^^^^^^^^^^^^ (u128)(170141183460469231731687303715884105728)

const panic = @panic("foo");
//    ^^^^^ (noreturn)()
const trap = @trap();
//    ^^^^ (noreturn)()

const Int = @Int(.signed, 16);
//    ^^^ (type)(i16)
//               ^^^^^^^ (Signedness)()
const UnsignedInt = @Int(.unsigned, 256);
//    ^^^^^^^^^^^ (type)(u256)
const Tuple = @Tuple(&.{ u8, i16 });
//    ^^^^^ (type)(struct { u8, i16 })
const TupleFields = &.{ i32, bool };
const AliasedTuple = @Tuple(TupleFields);
//    ^^^^^^^^^^^^ (type)(struct { i32, bool })
const Pointer = @Pointer(.one, undefined, undefined, undefined);
//    ^^^^^^^ (type)()
//                       ^^^^ (Size)()
const ConstPointer = @Pointer(.one, .{ .@"const" = true }, u8, null);
//    ^^^^^^^^^^^^ (type)(*const u8)
const SentinelSlice = @Pointer(.slice, .{ .@"const" = true }, u8, 0);
//    ^^^^^^^^^^^^^ (type)([:0]const u8)
const AttributedManyPointer = @Pointer(.many, .{ .@"volatile" = true, .@"allowzero" = true, .@"align" = 4 }, u32, null);
//    ^^^^^^^^^^^^^^^^^^^^^ (type)([*]allowzero align(4) volatile u32)
const GenericAddressPointer = @Pointer(.one, .{ .@"addrspace" = .generic }, u8, null);
//    ^^^^^^^^^^^^^^^^^^^^^ (type)(*u8)
const Struct = @Struct(.auto, undefined, &.{"foo"}, &.{i32}, &.{.{}});
//    ^^^^^^ (type)()
//                     ^^^^^ (ContainerLayout)()
//                                        ^ ([1][]const u8)()
//                                                            ^ ([?]Attributes)()
//                                                              ^ (Attributes)()
const ConcreteStruct = @Struct(.auto, null, &.{ "foo", "bar" }, &.{ u8, i16 }, &.{ .{}, .{} });
//    ^^^^^^^^^^^^^^ (type)(struct { foo: u8, bar: i16 })
const AlignedStruct = @Struct(.auto, null, &.{"value"}, &.{u8}, &.{.{ .@"align" = 4 }});
//    ^^^^^^^^^^^^^ (type)(struct { value: u8 align(4) })
const GeneratedStructFieldType = @FieldType(ConcreteStruct, "foo");
//    ^^^^^^^^^^^^^^^^^^^^^^^^ (type)(u8)
const GeneratedStructHasField = @hasField(ConcreteStruct, "bar");
//    ^^^^^^^^^^^^^^^^^^^^^^^ (bool)(true)
const generated_struct_value = ConcreteStruct{ .bar = 9, .foo = 7 };
const generated_struct_foo = generated_struct_value.foo;
//    ^^^^^^^^^^^^^^^^^^^^ (u8)(7)
const generated_struct_bar = @field(generated_struct_value, "bar");
//    ^^^^^^^^^^^^^^^^^^^^ (i16)(9)
const generated_struct_unknown = ConcreteStruct{ .foo = 1, .bar = undefined };
const generated_struct_unknown_bar = generated_struct_unknown.bar;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (i16)()
const Union = @Union(.auto, undefined, &.{"foo"}, &.{i32}, &.{.{}});
//    ^^^^^ (type)()
//                   ^^^^^ (ContainerLayout)()
//                                      ^ ([1][]const u8)()
//                                                          ^ ([?]Attributes)()
//                                                            ^ (Attributes)()
const ConcreteUnion = @Union(.auto, null, &.{ "foo", "bar" }, &.{ u8, i16 }, &.{ .{}, .{} });
//    ^^^^^^^^^^^^^ (type)(union { foo: u8, bar: i16 })
const AlignedUnion = @Union(.auto, null, &.{"value"}, &.{u8}, &.{.{ .@"align" = 4 }});
//    ^^^^^^^^^^^^ (type)(union { value: u8 align(4) })
const GeneratedUnionFieldType = @FieldType(ConcreteUnion, "bar");
//    ^^^^^^^^^^^^^^^^^^^^^^^ (type)(i16)
const GeneratedUnionHasField = @hasField(ConcreteUnion, "foo");
//    ^^^^^^^^^^^^^^^^^^^^^^ (bool)(true)
const generated_union_value = ConcreteUnion{ .bar = 9 };
const generated_union_bar = generated_union_value.bar;
//    ^^^^^^^^^^^^^^^^^^^ (i16)(9)
const generated_union_inactive_foo = generated_union_value.foo;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)()
const generated_union_init = @unionInit(ConcreteUnion, "foo", 7);
const generated_union_foo = @field(generated_union_init, "foo");
//    ^^^^^^^^^^^^^^^^^^^ (u8)(7)
const generated_union_unknown = ConcreteUnion{ .foo = undefined };
const generated_union_unknown_foo = generated_union_unknown.foo;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)()
const Enum = @Enum(undefined, .exhaustive, undefined, undefined);
//    ^^^^ (type)()
//                            ^^^^^^^^^^^ (Mode)()
const ConcreteEnum = @Enum(u8, .exhaustive, &.{ "low", "high" }, &.{ 1, 7 });
//    ^^^^^^^^^^^^ (type)(enum(u8) { low = 1, high = 7 })
const NonexhaustiveEnum = @Enum(u8, .nonexhaustive, &.{"known"}, &.{1});
//    ^^^^^^^^^^^^^^^^^ (type)(enum(u8) { known = 1, _ })
const generated_enum_value = ConcreteEnum.high;
//    ^^^^^^^^^^^^^^^^^^^^ (enum(u8) { low = 1, high = 7 })()
const generated_enum_int = @intFromEnum(generated_enum_value);
//    ^^^^^^^^^^^^^^^^^^ (u8)(7)
const generated_enum_name = @tagName(generated_enum_value);
//    ^^^^^^^^^^^^^^^^^^^ (*const [4:0]u8)()
const generated_enum_name_first = generated_enum_name[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)(104)
const generated_enum_from_int: ConcreteEnum = @enumFromInt(1);
const generated_enum_roundtrip = @intFromEnum(generated_enum_from_int);
//    ^^^^^^^^^^^^^^^^^^^^^^^^ (u8)(1)
const Fn = @Fn(&.{i32}, &.{.{}}, undefined, .{});
//    ^^ (type)()
//                       ^ ([?]Attributes)()
//                         ^ (Attributes)()
//                                          ^ (Attributes)()
const ConcreteFn = @Fn(&.{ i32, bool }, &.{ .{}, .{} }, u8, .{});
//    ^^^^^^^^^^ (type)(fn(i32, bool) u8)
const NoaliasFn = @Fn(&.{*anyopaque}, &.{.{ .@"noalias" = true }}, void, .{});
//    ^^^^^^^^^ (type)(fn(noalias *anyopaque) void)
const VariadicFn = @Fn(&.{i32}, &.{.{}}, void, .{ .@"callconv" = .c, .varargs = true });
//    ^^^^^^^^^^ (type)(fn(i32, ...) callconv(.c) void)

const type_enum_literal: @EnumLiteral() = .foo;
//    ^^^^^^^^^^^^^^^^^ (@EnumLiteral())()

const type_info = @typeInfo(u8);
//    ^^^^^^^^^ (Type)()
const type_info_tag_name = @tagName(type_info);
//    ^^^^^^^^^^^^^^^^^^ (*const [3:0]u8)()
const type_info_tag_name_first = type_info_tag_name[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^ (u8)(105)

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
