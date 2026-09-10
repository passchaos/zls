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
const vector_bool_not_value = (!@as(@Vector(2, bool), .{ true, false }))[1];
//    ^^^^^^^^^^^^^^^^^^^^^ (bool)(true)
const vector_bool_and_value = (@as(@Vector(2, bool), .{ true, false }) & @as(@Vector(2, bool), .{ true, true }))[0];
//    ^^^^^^^^^^^^^^^^^^^^^ (bool)(true)
const vector_bool_or_value = (@as(@Vector(2, bool), .{ true, false }) | @as(@Vector(2, bool), .{ false, true }))[1];
//    ^^^^^^^^^^^^^^^^^^^^ (bool)(true)
const vector_bool_xor_value = (@as(@Vector(2, bool), .{ true, false }) ^ @as(@Vector(2, bool), .{ true, true }))[1];
//    ^^^^^^^^^^^^^^^^^^^^^ (bool)(true)

var runtime_u4: u4 = 4;
var runtime_u8: u8 = 8;
var runtime_u16: u16 = 16;
var runtime_i16: i16 = -16;
