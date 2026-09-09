const comptime_integer = 42;
//    ^^^^^^^^^^^^^^^^ (comptime_int)(42)

const comptime_plus = 2 + 3;
//    ^^^^^^^^^^^^^ (comptime_int)(5)

const comptime_sub = 2 - 3;
//    ^^^^^^^^^^^^ (comptime_int)(-1)

const comptime_mul = 2 * 3;
//    ^^^^^^^^^^^^ (comptime_int)(6)

const comptime_div = 2 / 3;
//    ^^^^^^^^^^^^ (comptime_int)(0)

const comptime_and = 2 & 3;
//    ^^^^^^^^^^^^ (comptime_int)(2)

const comptime_shl = 2 << 3;
//    ^^^^^^^^^^^^ (comptime_int)(16)

const one_plus_one = 1 + 1;
//    ^^^^^^^^^^^^ (comptime_int)(2)

const negation_one = -1;
//    ^^^^^^^^^^^^ (comptime_int)(-1)

const negation_wrap_one = -%1;
//    ^^^^^^^^^^^^^^^^^ (comptime_int)(-1)

const bit_not_one = ~1;
//    ^^^^^^^^^^^ (comptime_int)(-2)

const const_u8: u8 = 42;
//    ^^^^^^^^ (u8)(42)

var var_u8: u8 = 42;
//  ^^^^^^ (u8)((unknown value))

const as_u8 = @as(u8, 42);
//    ^^^^^ (u8)(42)

const as_u8_too_big = @as(u8, 256);
//    ^^^^^^^^^^^^^ (u8)((unknown value))

const as_u8_negative = @as(u8, -1);
//    ^^^^^^^^^^^^^^ (u8)((unknown value))

var var_as_u8 = @as(u8, 42);
//  ^^^^^^^^^ (u8)((unknown value))

const comptime_plus_u8 = 2 + @as(u8, 3);
//    ^^^^^^^^^^^^^^^^ (u8)(5)

const u8_plus_comptime = @as(u8, 2) + 3;
//    ^^^^^^^^^^^^^^^^ (u8)(5)

const ascii_char = 'A';
//    ^^^^^^^^^^ (comptime_int)(65)

const escaped_char = '\n';
//    ^^^^^^^^^^^^ (comptime_int)(10)

const unicode_char = '界';
//    ^^^^^^^^^^^^ (comptime_int)(30028)

const bit_size_u13 = @bitSizeOf(u13);
//    ^^^^^^^^^^^^ (comptime_int)(13)

const byte_size_u13 = @sizeOf(u13);
//    ^^^^^^^^^^^^^ (comptime_int)(2)

const wide_clz = @clz(@as(u65535, 0));
//    ^^^^^^^^ (u16)((unknown value))

const max_u128: u128 = 340282366920938463463374607431768211455;
const max_u128_equal = max_u128 == 340282366920938463463374607431768211455;
//    ^^^^^^^^^^^^^^ (bool)(true)
const max_u128_greater = max_u128 > 5;
//    ^^^^^^^^^^^^^^^^ (bool)(true)
const signed_unsigned_order = @as(i128, -1) < max_u128;
//    ^^^^^^^^^^^^^^^^^^^^^ (bool)(true)

const high_u128: u128 = 170141183460469231731687303715884105728;
const high_u128_add = high_u128 + 5;
//    ^^^^^^^^^^^^^ (u128)(170141183460469231731687303715884105733)
const high_u128_sub = high_u128 - 5;
//    ^^^^^^^^^^^^^ (u128)(170141183460469231731687303715884105723)
const high_u128_mul = high_u128 * 1;
//    ^^^^^^^^^^^^^ (u128)(170141183460469231731687303715884105728)
const high_u128_div = high_u128 / 2;
//    ^^^^^^^^^^^^^ (u128)(85070591730234615865843651857942052864)
const high_u128_mod = high_u128 % 7;
//    ^^^^^^^^^^^^^ (u128)(2)
const high_u128_or = high_u128 | 3;
//    ^^^^^^^^^^^^ (u128)(170141183460469231731687303715884105731)
const high_u128_not = ~high_u128;
//    ^^^^^^^^^^^^^ (u128)(170141183460469231731687303715884105727)
const high_i128_neg = -@as(i128, 170141183460469231731687303715884105727);
//    ^^^^^^^^^^^^^ (i128)(-170141183460469231731687303715884105727)
const min_i128_neg_wrap = -%@as(i128, -170141183460469231731687303715884105728);
//    ^^^^^^^^^^^^^^^^^ (i128)(-170141183460469231731687303715884105728)
const max_u128_add_wrap = @as(u128, 340282366920938463463374607431768211455) +% 1;
//    ^^^^^^^^^^^^^^^^^ (u128)(0)
const max_u128_add_sat = @as(u128, 340282366920938463463374607431768211455) +| 1;
//    ^^^^^^^^^^^^^^^^ (u128)(340282366920938463463374607431768211455)
const one_u128_sub_wrap = @as(u128, 1) -% 2;
//    ^^^^^^^^^^^^^^^^^ (u128)(340282366920938463463374607431768211455)
const one_u128_sub_sat = @as(u128, 1) -| 2;
//    ^^^^^^^^^^^^^^^^ (u128)(0)
const high_u128_shl_sat = @as(u128, 170141183460469231731687303715884105728) <<| 1;
//    ^^^^^^^^^^^^^^^^^ (u128)(340282366920938463463374607431768211455)
const max_i128_add_wrap = @as(i128, 170141183460469231731687303715884105727) +% 1;
//    ^^^^^^^^^^^^^^^^^ (i128)(-170141183460469231731687303715884105728)
const max_i128_add_sat = @as(i128, 170141183460469231731687303715884105727) +| 1;
//    ^^^^^^^^^^^^^^^^ (i128)(170141183460469231731687303715884105727)

comptime {
    @compileLog(comptime_div);
}
