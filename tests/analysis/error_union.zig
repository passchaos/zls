const Error = error{ Foo, Bar };
//    ^^^^^ (type)(error{Foo,Bar})

const Unknown: type = undefined.Unknown;
//    ^^^^^^^ (type)((unknown type))

const ErrorUnionType = Error!u32;
//    ^^^^^^^^^^^^^^ (type)()

const InvalidErrorUnionTypeUnwrap = ErrorUnionType catch |err| err;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^ (unknown)()
//                                                        ^^^ (unknown)()

const known_error_catch = error.Foo catch 9;
//    ^^^^^^^^^^^^^^^^^ (comptime_int)(9)

var runtime_error_union: Error!u8 = undefined;
const widened_catch = runtime_error_union catch @as(u16, 9);
//    ^^^^^^^^^^^^^ (u16)()

const DuplicateErrorName = error{ Foo, Foo } || error{Bar};
//    ^^^^^^^^^^^^^^^^^^ (type)(error{Bar,Foo})

const ErrorUnionUnknownError = Unknown!u32;
//    ^^^^^^^^^^^^^^^^^^^^^^ (type)((unknown type)!u32)

const ErrorUnionUnknownPayload = Error!Unknown;
//    ^^^^^^^^^^^^^^^^^^^^^^^^ (type)(error{Foo,Bar}!(unknown type))
