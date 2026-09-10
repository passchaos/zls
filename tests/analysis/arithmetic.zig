const add_u8_i16 = runtime_u8 + runtime_i16;
//    ^^^^^^^^^^ (i16)()

const add_wrap_u8_i16 = runtime_u8 +% runtime_i16;
//    ^^^^^^^^^^^^^^^ (i16)()

const add_sat_u8_i16 = runtime_u8 +| runtime_i16;
//    ^^^^^^^^^^^^^^ (i16)()

const sub_u8_i16 = runtime_u8 - runtime_i16;
//    ^^^^^^^^^^ (i16)()

const sub_wrap_u8_i16 = runtime_u8 -% runtime_i16;
//    ^^^^^^^^^^^^^^^ (i16)()

const sub_sat_u8_i16 = runtime_u8 -| runtime_i16;
//    ^^^^^^^^^^^^^^ (i16)()

const negation_i16 = -runtime_i16;
//    ^^^^^^^^^^^^ (i16)()

const negation_wrap_i16 = -%runtime_i16;
//    ^^^^^^^^^^^^^^^^^ (i16)()

const mul_u8_i16 = runtime_u8 * runtime_i16;
//    ^^^^^^^^^^ (i16)()

const mul_wrap_u8_i16 = runtime_u8 *% runtime_i16;
//    ^^^^^^^^^^^^^^^ (i16)()

const mul_sat_u8_i16 = runtime_u8 *| runtime_i16;
//    ^^^^^^^^^^^^^^ (i16)()

const div_u8_u16 = runtime_u8 / runtime_u16;
//    ^^^^^^^^^^ (u16)()

// TODO this should be `unknown`
const div_u8_i16 = runtime_u8 / runtime_i16;
//    ^^^^^^^^^^ (i16)()

const mod_u8_u16 = runtime_u8 % runtime_u16;
//    ^^^^^^^^^^ (u16)()

// TODO this should be `unknown`
const mod_u8_i16 = runtime_u8 % runtime_i16;
//    ^^^^^^^^^^ (i16)()

const shl_i16_u4 = runtime_i16 << runtime_u4;
//    ^^^^^^^^^^ (i16)()

// TODO this should be `unknown`
const shl_i16_u8 = runtime_i16 << runtime_u8;
//    ^^^^^^^^^^ (i16)()

const shl_sat_i16_u16 = runtime_i16 <<| runtime_u16;
//    ^^^^^^^^^^^^^^^ (i16)()

const shr_i16_u4 = runtime_i16 >> runtime_u4;
//    ^^^^^^^^^^ (i16)()
const zero_shl_runtime = @as(u8, 0) << runtime_u3;
//    ^^^^^^^^^^^^^^^^ (u8)(0)
const zero_shr_runtime = @as(u8, 0) >> runtime_u3;
//    ^^^^^^^^^^^^^^^^ (u8)(0)
const signed_all_ones_shr_runtime = @as(i8, -1) >> runtime_u3;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^ (i8)(-1)
const unsigned_all_ones_shr_runtime = @as(u8, 255) >> runtime_u3;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)()
const signed_all_ones_shr_undefined = @as(i8, -1) >> undefined_u3;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (i8)()
const zero_shl_sat_runtime = @as(u8, 0) <<| runtime_u3;
//    ^^^^^^^^^^^^^^^^^^^^ (u8)(0)
const nonzero_shl_runtime = @as(u8, 1) << runtime_u3;
//    ^^^^^^^^^^^^^^^^^^^ (u8)()
const undefined_shl_runtime = @as(u8, undefined) << runtime_u3;
//    ^^^^^^^^^^^^^^^^^^^^^ (u8)()

// TODO this should be `unknown`
const shr_i16_u8 = runtime_i16 >> runtime_u8;
//    ^^^^^^^^^^ (i16)()

const bit_and_u8_i16 = runtime_u8 & runtime_i16;
//    ^^^^^^^^^^^^^^ (i16)()

const bit_or_u8_i16 = runtime_u8 | runtime_i16;
//    ^^^^^^^^^^^^^ (i16)()

const bit_xor_u8_i16 = runtime_u8 ^ runtime_i16;
//    ^^^^^^^^^^^^^^ (i16)()

const bit_not_u8 = ~runtime_u8;
//    ^^^^^^^^^^ (u8)()
const integer_mul_zero_runtime = runtime_u8 * @as(u8, 0);
//    ^^^^^^^^^^^^^^^^^^^^^^^^ (u8)(0)
const integer_and_zero_runtime = runtime_u8 & @as(u8, 0);
//    ^^^^^^^^^^^^^^^^^^^^^^^^ (u8)(0)
const integer_or_ones_runtime = runtime_u8 | @as(u8, 255);
//    ^^^^^^^^^^^^^^^^^^^^^^^ (u8)(255)
const signed_or_ones_runtime = runtime_i8 | @as(i8, -1);
//    ^^^^^^^^^^^^^^^^^^^^^^ (i8)(-1)
const integer_add_zero_runtime = runtime_u8 + @as(u8, 0);
//    ^^^^^^^^^^^^^^^^^^^^^^^^ (u8)()
const integer_mul_zero_undefined = @as(u8, undefined) * @as(u8, 0);
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)()
const integer_mod_one_runtime = runtime_u8 % @as(u8, 1);
//    ^^^^^^^^^^^^^^^^^^^^^^^ (u8)(0)
const integer_mod_two_runtime = runtime_u8 % @as(u8, 2);
//    ^^^^^^^^^^^^^^^^^^^^^^^ (u8)()
const integer_mod_one_undefined = @as(u8, undefined) % @as(u8, 1);
//    ^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)()
const mul_wrap_zero_runtime = runtime_u8 *% @as(u8, 0);
//    ^^^^^^^^^^^^^^^^^^^^^ (u8)(0)
const mul_sat_zero_runtime = runtime_u8 *| @as(u8, 0);
//    ^^^^^^^^^^^^^^^^^^^^ (u8)(0)
const add_sat_max_runtime = runtime_u8 +| @as(u8, 255);
//    ^^^^^^^^^^^^^^^^^^^ (u8)(255)
const sub_sat_zero_runtime = @as(u8, 0) -| runtime_u8;
//    ^^^^^^^^^^^^^^^^^^^^ (u8)(0)
const add_wrap_zero_runtime = runtime_u8 +% @as(u8, 0);
//    ^^^^^^^^^^^^^^^^^^^^^ (u8)()
const mul_wrap_zero_undefined = @as(u8, undefined) *% @as(u8, 0);
//    ^^^^^^^^^^^^^^^^^^^^^^^ (u8)()
const bool_and_runtime_false = runtime_bool and false;
//    ^^^^^^^^^^^^^^^^^^^^^^ (bool)(false)
const bool_or_runtime_true = runtime_bool or true;
//    ^^^^^^^^^^^^^^^^^^^^ (bool)(true)
const bool_and_runtime_true = runtime_bool and true;
//    ^^^^^^^^^^^^^^^^^^^^^ (bool)()
const bool_or_runtime_false = runtime_bool or false;
//    ^^^^^^^^^^^^^^^^^^^^^ (bool)()
const bool_and_undefined = @as(bool, undefined) and false;
//    ^^^^^^^^^^^^^^^^^^ (bool)()
const bool_bit_and_value = true & false;
//    ^^^^^^^^^^^^^^^^^^ (bool)(false)
const bool_bit_or_value = false | true;
//    ^^^^^^^^^^^^^^^^^ (bool)(true)
const bool_bit_xor_value = true ^ false;
//    ^^^^^^^^^^^^^^^^^^ (bool)(true)
const bool_bit_and_runtime_false = runtime_bool & false;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)(false)
const bool_bit_or_runtime_true = runtime_bool | true;
//    ^^^^^^^^^^^^^^^^^^^^^^^^ (bool)(true)
const bool_bit_xor_runtime_true = runtime_bool ^ true;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)()
const bool_bit_and_undefined = undefined_bool & false;
//    ^^^^^^^^^^^^^^^^^^^^^^ (bool)()
const bool_bit_or_undefined = undefined_bool | true;
//    ^^^^^^^^^^^^^^^^^^^^^ (bool)()
const unsigned_lte_max = runtime_u8 <= @as(u8, 255);
//    ^^^^^^^^^^^^^^^^ (bool)(true)
const unsigned_gt_max = runtime_u8 > @as(u8, 255);
//    ^^^^^^^^^^^^^^^ (bool)(false)
const unsigned_gte_min = runtime_u8 >= @as(u8, 0);
//    ^^^^^^^^^^^^^^^^ (bool)(true)
const unsigned_lt_min = runtime_u8 < @as(u8, 0);
//    ^^^^^^^^^^^^^^^ (bool)(false)
const signed_lte_max = runtime_i8 <= @as(i8, 127);
//    ^^^^^^^^^^^^^^ (bool)(true)
const signed_gt_max = runtime_i8 > @as(i8, 127);
//    ^^^^^^^^^^^^^ (bool)(false)
const signed_gte_min = runtime_i8 >= @as(i8, -128);
//    ^^^^^^^^^^^^^^ (bool)(true)
const signed_lt_min = runtime_i8 < @as(i8, -128);
//    ^^^^^^^^^^^^^ (bool)(false)
const unsigned_min_lte = @as(u8, 0) <= runtime_u8;
//    ^^^^^^^^^^^^^^^^ (bool)(true)
const unsigned_max_lt = @as(u8, 255) < runtime_u8;
//    ^^^^^^^^^^^^^^^ (bool)(false)
const unsigned_min_gt = @as(u8, 0) > runtime_u8;
//    ^^^^^^^^^^^^^^^ (bool)(false)
const unsigned_max_gte = @as(u8, 255) >= runtime_u8;
//    ^^^^^^^^^^^^^^^^ (bool)(true)
const signed_min_lte = @as(i8, -128) <= runtime_i8;
//    ^^^^^^^^^^^^^^ (bool)(true)
const signed_max_lt = @as(i8, 127) < runtime_i8;
//    ^^^^^^^^^^^^^ (bool)(false)
const signed_min_gt = @as(i8, -128) > runtime_i8;
//    ^^^^^^^^^^^^^ (bool)(false)
const signed_max_gte = @as(i8, 127) >= runtime_i8;
//    ^^^^^^^^^^^^^^ (bool)(true)
const unsigned_lt_middle = runtime_u8 < @as(u8, 100);
//    ^^^^^^^^^^^^^^^^^^ (bool)()
const undefined_lte_max = @as(u8, undefined) <= @as(u8, 255);
//    ^^^^^^^^^^^^^^^^^ (bool)()
const integer_self_equal = runtime_u8 == runtime_u8;
//    ^^^^^^^^^^^^^^^^^^ (bool)(true)
const integer_self_not_equal = runtime_i8 != runtime_i8;
//    ^^^^^^^^^^^^^^^^^^^^^^ (bool)(false)
const integer_self_lte = runtime_u8 <= runtime_u8;
//    ^^^^^^^^^^^^^^^^ (bool)(true)
const integer_self_gt = runtime_i8 > runtime_i8;
//    ^^^^^^^^^^^^^^^ (bool)(false)
const bool_self_equal = runtime_bool == runtime_bool;
//    ^^^^^^^^^^^^^^^ (bool)(true)
const bool_self_xor = runtime_bool ^ runtime_bool;
//    ^^^^^^^^^^^^^ (bool)(false)
const float_self_equal = runtime_f32 == runtime_f32;
//    ^^^^^^^^^^^^^^^^ (bool)()
const undefined_self_equal = @as(u8, undefined) == @as(u8, undefined);
//    ^^^^^^^^^^^^^^^^^^^^ (bool)()
const integer_self_xor = runtime_i8 ^ runtime_i8;
//    ^^^^^^^^^^^^^^^^ (i8)(0)
const integer_complement_and = runtime_u8 & ~runtime_u8;
//    ^^^^^^^^^^^^^^^^^^^^^^ (u8)(0)
const integer_reverse_complement_and = ~runtime_u8 & runtime_u8;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)(0)
const integer_complement_or = runtime_u8 | ~runtime_u8;
//    ^^^^^^^^^^^^^^^^^^^^^ (u8)(255)
const integer_complement_xor = runtime_i8 ^ ~runtime_i8;
//    ^^^^^^^^^^^^^^^^^^^^^^ (i8)(-1)
const integer_complement_add = runtime_u8 + ~runtime_u8;
//    ^^^^^^^^^^^^^^^^^^^^^^ (u8)(255)
const integer_reverse_complement_add = ~runtime_i8 + runtime_i8;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (i8)(-1)
const integer_complement_add_wrap = runtime_u8 +% ~runtime_u8;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)(255)
const integer_complement_add_sat = runtime_i8 +| ~runtime_i8;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^ (i8)(-1)
const integer_self_sub = runtime_i8 - runtime_i8;
//    ^^^^^^^^^^^^^^^^ (i8)(0)
const integer_self_sub_wrap = runtime_i8 -% runtime_i8;
//    ^^^^^^^^^^^^^^^^^^^^^ (i8)(0)
const integer_self_sub_sat = runtime_i8 -| runtime_i8;
//    ^^^^^^^^^^^^^^^^^^^^ (i8)(0)
const undefined_self_xor = @as(i8, undefined) ^ @as(i8, undefined);
//    ^^^^^^^^^^^^^^^^^^ (i8)()
const undefined_self_sub = undefined_i8 - undefined_i8;
//    ^^^^^^^^^^^^^^^^^^ (i8)()
const undefined_bool_self_xor = undefined_bool ^ undefined_bool;
//    ^^^^^^^^^^^^^^^^^^^^^^^ (bool)()
const integer_undefined_complement_and = undefined_u8 & ~undefined_u8;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)()
const integer_undefined_complement_add = undefined_u8 + ~undefined_u8;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)()
const bool_complement_and = runtime_bool and !runtime_bool;
//    ^^^^^^^^^^^^^^^^^^^ (bool)(false)
const bool_reverse_complement_and = !runtime_bool and runtime_bool;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)(false)
const bool_complement_or = runtime_bool or !runtime_bool;
//    ^^^^^^^^^^^^^^^^^^ (bool)(true)
const bool_complement_xor = runtime_bool ^ !runtime_bool;
//    ^^^^^^^^^^^^^^^^^^^ (bool)(true)
const bool_undefined_complement_and = undefined_bool and !undefined_bool;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)()
const integer_complement_equal = runtime_u8 == ~runtime_u8;
//    ^^^^^^^^^^^^^^^^^^^^^^^^ (bool)(false)
const integer_reverse_complement_not_equal = ~runtime_u8 != runtime_u8;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)(true)
const bool_complement_equal = runtime_bool == !runtime_bool;
//    ^^^^^^^^^^^^^^^^^^^^^ (bool)(false)
const bool_complement_not_equal = runtime_bool != !runtime_bool;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)(true)
const undefined_complement_equal = undefined_u8 == ~undefined_u8;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)()
const enum_self_equal = runtime_enum == runtime_enum;
//    ^^^^^^^^^^^^^^^ (bool)(true)
const enum_self_not_equal = runtime_enum != runtime_enum;
//    ^^^^^^^^^^^^^^^^^^^ (bool)(false)
const error_self_equal = runtime_error == runtime_error;
//    ^^^^^^^^^^^^^^^^ (bool)(true)
const error_self_not_equal = runtime_error != runtime_error;
//    ^^^^^^^^^^^^^^^^^^^^ (bool)(false)
const pointer_self_equal = runtime_pointer == runtime_pointer;
//    ^^^^^^^^^^^^^^^^^^ (bool)(true)
const pointer_self_not_equal = runtime_pointer != runtime_pointer;
//    ^^^^^^^^^^^^^^^^^^^^^^ (bool)(false)
const undefined_error_self_equal = undefined_error == undefined_error;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)()
const undefined_pointer_self_equal = undefined_pointer == undefined_pointer;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)()
const undefined_enum_self_equal = undefined_enum == undefined_enum;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)()

const vector_add_value = (@as(@Vector(2, u8), .{ 1, 2 }) + @as(@Vector(2, u8), .{ 3, 4 }))[1];
//    ^^^^^^^^^^^^^^^^ (u8)(6)
const vector_sub_value = (@as(@Vector(2, i8), .{ 7, -2 }) - @as(@Vector(2, i8), .{ 3, 4 }))[1];
//    ^^^^^^^^^^^^^^^^ (i8)(-6)
const vector_mul_value = (@as(@Vector(2, u8), .{ 3, 4 }) * @as(@Vector(2, u8), .{ 5, 6 }))[1];
//    ^^^^^^^^^^^^^^^^ (u8)(24)
const vector_div_value = (@as(@Vector(2, u8), .{ 8, 9 }) / @as(@Vector(2, u8), .{ 2, 3 }))[1];
//    ^^^^^^^^^^^^^^^^ (u8)(3)
const vector_mod_value = (@as(@Vector(2, u8), .{ 8, 10 }) % @as(@Vector(2, u8), .{ 3, 4 }))[1];
//    ^^^^^^^^^^^^^^^^ (u8)(2)
const vector_float_div_value = (@as(@Vector(2, f32), .{ 8.0, 5.0 }) / @as(@Vector(2, f32), .{ 2.0, 2.0 }))[1];
//    ^^^^^^^^^^^^^^^^^^^^^^ (f32)(2.5)
const vector_equal_value = (@as(@Vector(2, u8), .{ 1, 2 }) == @as(@Vector(2, u8), .{ 1, 3 }))[0];
//    ^^^^^^^^^^^^^^^^^^ (bool)(true)
const vector_less_value = (@as(@Vector(2, i8), .{ 1, 4 }) < @as(@Vector(2, i8), .{ 2, 3 }))[1];
//    ^^^^^^^^^^^^^^^^^ (bool)(false)
const vector_bit_not_value = (~@as(@Vector(2, u8), .{ 0, 255 }))[0];
//    ^^^^^^^^^^^^^^^^^^^^ (u8)(255)
const vector_negation_value = (-@as(@Vector(2, i8), .{ 3, -4 }))[1];
//    ^^^^^^^^^^^^^^^^^^^^^ (i8)(4)
const vector_wrapping_negation_value = (-%@as(@Vector(2, u8), .{ 1, 2 }))[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)(255)
const vector_float_negation_value = (-@as(@Vector(2, f32), .{ 2.5, -4.5 }))[1];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^ (f32)(4.5)
const vector_add_wrap_value = (@as(@Vector(2, u8), @splat(255)) +% @as(@Vector(2, u8), @splat(1)))[0];
//    ^^^^^^^^^^^^^^^^^^^^^ (u8)(0)
const vector_add_sat_value = (@as(@Vector(2, u8), @splat(255)) +| @as(@Vector(2, u8), @splat(1)))[1];
//    ^^^^^^^^^^^^^^^^^^^^ (u8)(255)
const vector_sub_wrap_value = (@as(@Vector(2, u8), @splat(1)) -% @as(@Vector(2, u8), @splat(2)))[0];
//    ^^^^^^^^^^^^^^^^^^^^^ (u8)(255)
const vector_sub_sat_value = (@as(@Vector(2, u8), @splat(1)) -| @as(@Vector(2, u8), @splat(2)))[1];
//    ^^^^^^^^^^^^^^^^^^^^ (u8)(0)
const vector_mul_wrap_value = (@as(@Vector(2, i8), @splat(127)) *% @as(@Vector(2, i8), @splat(2)))[0];
//    ^^^^^^^^^^^^^^^^^^^^^ (i8)(-2)
const vector_mul_sat_value = (@as(@Vector(2, i8), @splat(127)) *| @as(@Vector(2, i8), @splat(2)))[1];
//    ^^^^^^^^^^^^^^^^^^^^ (i8)(127)
const vector_shl_sat_value = (@as(@Vector(2, u8), @splat(0x40)) <<| @as(@Vector(2, u3), @splat(2)))[0];
//    ^^^^^^^^^^^^^^^^^^^^ (u8)(255)
const vector_shl_value = (@as(@Vector(2, u8), .{ 3, 12 }) << @as(@Vector(2, u3), @splat(2)))[0];
//    ^^^^^^^^^^^^^^^^ (u8)(12)
const vector_shr_value = (@as(@Vector(2, i8), .{ -4, -12 }) >> @as(@Vector(2, u3), @splat(2)))[0];
//    ^^^^^^^^^^^^^^^^ (i8)(-1)
const vector_shl_exact_value = @shlExact(@as(@Vector(2, u8), .{ 4, 12 }), @as(@Vector(2, u3), @splat(2)))[0];
//    ^^^^^^^^^^^^^^^^^^^^^^ (u8)(16)
const vector_shr_exact_value = @shrExact(@as(@Vector(2, u8), .{ 4, 12 }), @as(@Vector(2, u3), @splat(2)))[1];
//    ^^^^^^^^^^^^^^^^^^^^^^ (u8)(3)
const vector_zero_shl_runtime = (@as(@Vector(2, u8), @splat(0)) << runtime_u3_vector)[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^ (u8)(0)
const vector_zero_shr_runtime = (@as(@Vector(2, u8), @splat(0)) >> runtime_u3_vector)[1];
//    ^^^^^^^^^^^^^^^^^^^^^^^ (u8)(0)
const vector_signed_all_ones_shr_runtime = (@as(@Vector(2, i8), @splat(-1)) >> runtime_u3_vector)[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (i8)(-1)
const vector_signed_all_ones_shr_undefined = (@as(@Vector(2, i8), @splat(-1)) >> partially_undefined_u3_vector)[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (i8)()
const vector_signed_all_ones_shr_known = (@as(@Vector(2, i8), @splat(-1)) >> partially_undefined_u3_vector)[1];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (i8)(-1)
const vector_zero_shl_sat_runtime = (@as(@Vector(2, u8), @splat(0)) <<| runtime_u3_vector)[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)(0)
const vector_bool_not_value = (!@as(@Vector(2, bool), .{ true, false }))[1];
//    ^^^^^^^^^^^^^^^^^^^^^ (bool)(true)
const vector_bool_and_value = (@as(@Vector(2, bool), .{ true, false }) & @as(@Vector(2, bool), .{ true, true }))[0];
//    ^^^^^^^^^^^^^^^^^^^^^ (bool)(true)
const vector_bool_or_value = (@as(@Vector(2, bool), .{ true, false }) | @as(@Vector(2, bool), .{ false, true }))[1];
//    ^^^^^^^^^^^^^^^^^^^^ (bool)(true)
const vector_bool_xor_value = (@as(@Vector(2, bool), .{ true, false }) ^ @as(@Vector(2, bool), .{ true, true }))[1];
//    ^^^^^^^^^^^^^^^^^^^^^ (bool)(true)
const vector_bool_not_runtime = !runtime_bool_vector;
//    ^^^^^^^^^^^^^^^^^^^^^^^ (@Vector(2,bool))()
const vector_bool_and_runtime = (runtime_bool_vector & @as(@Vector(2, bool), @splat(false)))[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^ (bool)(false)
const vector_bool_or_runtime = (runtime_bool_vector | @as(@Vector(2, bool), @splat(true)))[1];
//    ^^^^^^^^^^^^^^^^^^^^^^ (bool)(true)
const vector_bool_xor_runtime = (runtime_bool_vector ^ @as(@Vector(2, bool), @splat(true)))[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^ (bool)()
const vector_bool_complement_and = (runtime_bool_vector & !runtime_bool_vector)[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)(false)
const vector_bool_complement_or = (runtime_bool_vector | !runtime_bool_vector)[1];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)(true)
const vector_bool_complement_xor = (runtime_bool_vector ^ !runtime_bool_vector)[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)(true)
const vector_bool_complement_equal = (runtime_bool_vector == !runtime_bool_vector)[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)(false)
const vector_bool_complement_not_equal = (runtime_bool_vector != !runtime_bool_vector)[1];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)(true)
const vector_bool_self_xor = (runtime_bool_vector ^ runtime_bool_vector)[1];
//    ^^^^^^^^^^^^^^^^^^^^ (bool)(false)
const vector_undefined_bool_self_xor = (undefined_bool_vector ^ undefined_bool_vector)[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)()
const vector_partially_undefined_bool_self_xor = (partially_undefined_bool_vector ^ partially_undefined_bool_vector)[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)()
const vector_known_bool_lane_self_xor = (partially_undefined_bool_vector ^ partially_undefined_bool_vector)[1];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)(false)
const vector_bool_and_undefined = (@as(@Vector(2, bool), .{ undefined, true }) & @as(@Vector(2, bool), @splat(false)))[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)()
const vector_integer_mul_zero_runtime = (runtime_u8_vector * @as(@Vector(2, u8), @splat(0)))[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)(0)
const vector_integer_and_zero_runtime = (runtime_u8_vector & @as(@Vector(2, u8), @splat(0)))[1];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)(0)
const vector_integer_or_ones_runtime = (runtime_u8_vector | @as(@Vector(2, u8), @splat(255)))[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)(255)
const vector_integer_add_runtime = (runtime_u8_vector + @as(@Vector(2, u8), @splat(0)))[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)()
const vector_integer_mul_undefined = (@as(@Vector(2, u8), .{ undefined, 1 }) * @as(@Vector(2, u8), @splat(0)))[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)()
const vector_integer_self_xor = (runtime_i8_vector ^ runtime_i8_vector)[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^ (i8)(0)
const vector_integer_complement_and = (runtime_i8_vector & ~runtime_i8_vector)[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (i8)(0)
const vector_integer_complement_or = (runtime_i8_vector | ~runtime_i8_vector)[1];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (i8)(-1)
const vector_integer_complement_xor = (runtime_i8_vector ^ ~runtime_i8_vector)[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (i8)(-1)
const vector_integer_complement_add = (runtime_i8_vector + ~runtime_i8_vector)[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (i8)(-1)
const vector_integer_complement_add_wrap = (runtime_i8_vector +% ~runtime_i8_vector)[1];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (i8)(-1)
const vector_integer_complement_add_sat = (runtime_i8_vector +| ~runtime_i8_vector)[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (i8)(-1)
const vector_integer_complement_equal = (runtime_i8_vector == ~runtime_i8_vector)[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)(false)
const vector_integer_complement_not_equal = (~runtime_i8_vector != runtime_i8_vector)[1];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)(true)
const vector_integer_self_sub = (runtime_i8_vector - runtime_i8_vector)[1];
//    ^^^^^^^^^^^^^^^^^^^^^^^ (i8)(0)
const vector_integer_self_sub_wrap = (runtime_i8_vector -% runtime_i8_vector)[1];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (i8)(0)
const vector_integer_self_sub_sat = (runtime_i8_vector -| runtime_i8_vector)[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^ (i8)(0)
const vector_undefined_self_xor = (undefined_i8_vector ^ undefined_i8_vector)[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^ (i8)()
const vector_undefined_self_sub = (undefined_i8_vector - undefined_i8_vector)[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^ (i8)()
const vector_partially_undefined_self_sub = (partially_undefined_i8_vector - partially_undefined_i8_vector)[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (i8)()
const vector_known_lane_self_sub = (partially_undefined_i8_vector - partially_undefined_i8_vector)[1];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^ (i8)(0)
const vector_partially_undefined_complement_and = (partially_undefined_i8_vector & ~partially_undefined_i8_vector)[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (i8)()
const vector_known_lane_complement_and = (partially_undefined_i8_vector & ~partially_undefined_i8_vector)[1];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (i8)(0)
const vector_partially_undefined_complement_add = (partially_undefined_i8_vector + ~partially_undefined_i8_vector)[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (i8)()
const vector_known_lane_complement_add = (partially_undefined_i8_vector + ~partially_undefined_i8_vector)[1];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (i8)(-1)
const vector_partially_undefined_complement_equal = (partially_undefined_i8_vector == ~partially_undefined_i8_vector)[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)()
const vector_known_lane_complement_equal = (partially_undefined_i8_vector == ~partially_undefined_i8_vector)[1];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)(false)
const vector_integer_self_equal = (runtime_i8_vector == runtime_i8_vector)[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)(true)
const vector_integer_self_not_equal = (runtime_i8_vector != runtime_i8_vector)[1];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)(false)
const vector_integer_self_lte = (runtime_i8_vector <= runtime_i8_vector)[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^ (bool)(true)
const vector_integer_self_gte = (runtime_i8_vector >= runtime_i8_vector)[1];
//    ^^^^^^^^^^^^^^^^^^^^^^^ (bool)(true)
const vector_integer_self_lt = (runtime_i8_vector < runtime_i8_vector)[0];
//    ^^^^^^^^^^^^^^^^^^^^^^ (bool)(false)
const vector_integer_self_gt = (runtime_i8_vector > runtime_i8_vector)[1];
//    ^^^^^^^^^^^^^^^^^^^^^^ (bool)(false)
const vector_bool_self_equal = (runtime_bool_vector == runtime_bool_vector)[0];
//    ^^^^^^^^^^^^^^^^^^^^^^ (bool)(true)
const vector_bool_self_not_equal = (runtime_bool_vector != runtime_bool_vector)[1];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)(false)
const vector_float_self_equal = (runtime_f32_vector == runtime_f32_vector)[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^ (bool)()
const vector_undefined_self_equal = (undefined_i8_vector == undefined_i8_vector)[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)()
const vector_partially_undefined_self_equal = (partially_undefined_i8_vector == partially_undefined_i8_vector)[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)()
const vector_known_lane_self_equal = (partially_undefined_i8_vector == partially_undefined_i8_vector)[1];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)(true)
const vector_unsigned_lte_max = (runtime_u8_vector <= @as(@Vector(2, u8), @splat(255)))[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^ (bool)(true)
const vector_unsigned_lt_min = (runtime_u8_vector < @as(@Vector(2, u8), @splat(0)))[1];
//    ^^^^^^^^^^^^^^^^^^^^^^ (bool)(false)
const vector_signed_gte_min = (runtime_i8_vector >= @as(@Vector(2, i8), @splat(-128)))[0];
//    ^^^^^^^^^^^^^^^^^^^^^ (bool)(true)
const vector_signed_gt_max = (runtime_i8_vector > @as(@Vector(2, i8), @splat(127)))[1];
//    ^^^^^^^^^^^^^^^^^^^^ (bool)(false)
const vector_unsigned_lt_middle = (runtime_u8_vector < @as(@Vector(2, u8), @splat(100)))[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)()
const vector_unsigned_lte_undefined = (@as(@Vector(2, u8), .{ undefined, 1 }) <= @as(@Vector(2, u8), @splat(255)))[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)()
const vector_mul_wrap_zero_runtime = (runtime_u8_vector *% @as(@Vector(2, u8), @splat(0)))[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)(0)
const vector_mul_sat_zero_runtime = (runtime_u8_vector *| @as(@Vector(2, u8), @splat(0)))[1];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)(0)
const vector_add_sat_max_runtime = (runtime_u8_vector +| @as(@Vector(2, u8), @splat(255)))[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)(255)
const vector_sub_sat_zero_runtime = (@as(@Vector(2, u8), @splat(0)) -| runtime_u8_vector)[1];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)(0)
const vector_add_wrap_runtime = (runtime_u8_vector +% @as(@Vector(2, u8), @splat(0)))[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^ (u8)()
const vector_mul_wrap_undefined = (@as(@Vector(2, u8), .{ undefined, 1 }) *% @as(@Vector(2, u8), @splat(0)))[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)()

var runtime_u4: u4 = 4;
var runtime_u8: u8 = 8;
var runtime_u16: u16 = 16;
var runtime_i8: i8 = -8;
var runtime_i16: i16 = -16;
var runtime_bool: bool = undefined;
var runtime_f32: f32 = undefined;
var runtime_bool_vector: @Vector(2, bool) = undefined;
var runtime_f32_vector: @Vector(2, f32) = undefined;
var runtime_u3: u3 = undefined;
var runtime_u3_vector: @Vector(2, u3) = undefined;
var runtime_u8_vector: @Vector(2, u8) = undefined;
var runtime_i8_vector: @Vector(2, i8) = undefined;
const RuntimeEnum = enum { first, second };
const RuntimeError = error{ first, second };
var runtime_enum: RuntimeEnum = .first;
var runtime_error: RuntimeError = error.first;
var pointer_storage: u8 = 0;
var runtime_pointer: *u8 = &pointer_storage;
const undefined_i8: i8 = undefined;
const undefined_u8: u8 = undefined;
const undefined_bool: bool = undefined;
const undefined_u3: u3 = undefined;
const undefined_i8_vector: @Vector(2, i8) = undefined;
const partially_undefined_i8_vector: @Vector(2, i8) = .{ undefined, 1 };
const undefined_bool_vector: @Vector(2, bool) = undefined;
const partially_undefined_bool_vector: @Vector(2, bool) = .{ undefined, true };
const partially_undefined_u3_vector: @Vector(2, u3) = .{ undefined, 2 };
const undefined_error: RuntimeError = undefined;
const undefined_pointer: *u8 = undefined;
const undefined_enum: RuntimeEnum = undefined;
