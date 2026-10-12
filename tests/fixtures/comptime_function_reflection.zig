fn Result(comptime first: bool, comptime second: bool, comptime third: bool) type {
    return struct { first: [@intFromBool(first)]u8, second: [@intFromBool(second)]u8, third: [@intFromBool(third)]u8 };
}

fn identity(value: anytype) @TypeOf(value) {
    return value;
}

fn typed(value: u8) @TypeOf(value) {
    return value;
}

fn byType(comptime T: type) T {
    return undefined;
}

fn byCount(comptime count: usize) [count]u8 {
    return undefined;
}

fn fixed(value: anytype) u8 {
    _ = value;
    return 0;
}

fn factory(comptime T: type) type {
    return struct { value: T };
}

fn uniform(comptime flag: bool) if (flag) u8 else u8 {
    return 0;
}

fn constantType(comptime T: type) type {
    _ = T;
    return u8;
}

fn throughCall(comptime T: type) constantType(T) {
    return 0;
}

fn parameterType(comptime count: usize, value: [count]u8) void {
    _ = value;
}

fn constantParameter(comptime flag: bool, value: if (flag) u8 else u8) void {
    _ = value;
}

fn captured(comptime T: type) type {
    return struct {
        fn fixedReturn(value: anytype) T {
            _ = value;
            return undefined;
        }

        fn ownParameter(comptime U: type) U {
            return undefined;
        }
    };
}

fn escaped(comptime Type: type) Type {
    return undefined;
}

pub fn generic_return_types() type {
    const a = @typeInfo(@TypeOf(identity)).@"fn";
    const b = @typeInfo(@TypeOf(typed)).@"fn";
    const c = @typeInfo(@TypeOf(byType)).@"fn";
    return Result(a.is_generic and a.return_type == null, b.is_generic and b.return_type == null, c.is_generic and c.return_type == null);
}

pub fn value_dependent_returns() type {
    const a = @typeInfo(@TypeOf(byCount)).@"fn";
    const b = @typeInfo(@TypeOf(uniform)).@"fn";
    const c = @typeInfo(@TypeOf(throughCall)).@"fn";
    return Result(a.return_type == null, b.return_type == null, c.return_type == null);
}

pub fn fixed_generic_returns() type {
    const a = @typeInfo(@TypeOf(fixed)).@"fn";
    const b = @typeInfo(@TypeOf(factory)).@"fn";
    const c = @typeInfo(@TypeOf(captured(u16).fixedReturn)).@"fn";
    return Result(a.is_generic and a.return_type.? == u8, b.is_generic and b.return_type.? == type, c.is_generic and c.return_type.? == u16);
}

pub fn dependent_parameters() type {
    const a = @typeInfo(@TypeOf(parameterType)).@"fn";
    const b = @typeInfo(@TypeOf(constantParameter)).@"fn";
    return Result(a.params[1].is_generic and a.params[1].type == null, b.params[1].is_generic and b.params[1].type == null, !a.params[0].is_generic and a.params[0].type.? == usize);
}

pub fn captured_and_escaped_returns() type {
    const a = @typeInfo(@TypeOf(captured(u16).fixedReturn)).@"fn";
    const b = @typeInfo(@TypeOf(captured(u16).ownParameter)).@"fn";
    const c = @typeInfo(@TypeOf(escaped)).@"fn";
    return Result(a.return_type.? == u16, b.return_type == null, c.return_type == null);
}

pub fn calls_do_not_specialize_reflection() type {
    const value = identity(@as(u8, 3));
    const item = typed(value);
    const array = byCount(2);
    const a = @typeInfo(@TypeOf(identity)).@"fn";
    const b = @typeInfo(@TypeOf(typed)).@"fn";
    const c = @typeInfo(@TypeOf(byCount)).@"fn";
    return Result(@TypeOf(item) == u8 and a.return_type == null, @TypeOf(array) == [2]u8 and b.return_type == null, c.return_type == null);
}

fn nestedReturn(comptime T: type) ?*[3]T {
    return null;
}

fn callbackReturn(comptime T: type) fn () T {
    return undefined;
}

fn fieldName(comptime T: type) struct { T: u8 } {
    _ = T;
    return undefined;
}

pub fn nested_signature_dependencies() type {
    const a = @typeInfo(@TypeOf(nestedReturn)).@"fn";
    const b = @typeInfo(@TypeOf(callbackReturn)).@"fn";
    const c = @typeInfo(@TypeOf(fieldName)).@"fn";
    return Result(a.return_type == null, b.return_type == null, c.return_type != null);
}

fn nestedArray(comptime count: usize) struct { values: [count]u8 } {
    return undefined;
}

pub fn nested_array_return_calls() type {
    const item = nestedArray(2);
    const info = @typeInfo(@TypeOf(nestedArray)).@"fn";
    return Result(@TypeOf(item.values) == [2]u8, info.return_type == null, @typeInfo(@TypeOf(item.values)).array.len == 2);
}

fn optionalArray(comptime count: usize) ?[count]u8 {
    return null;
}

fn matrix(comptime count: usize) [1][count]u8 {
    return undefined;
}

fn fallibleArray(comptime count: usize) error{Missing}![count]u8 {
    return error.Missing;
}

pub fn wrapped_array_return_calls() type {
    const optional = optionalArray(2);
    const nested = matrix(3);
    const fallible = fallibleArray(4);
    return Result(@TypeOf(optional) == ?[2]u8, @TypeOf(nested) == [1][3]u8, @TypeOf(fallible) == error{Missing}![4]u8);
}

pub fn reflected_then_called() type {
    const before = @typeInfo(@TypeOf(byCount)).@"fn";
    const a = byCount(2);
    const b = byCount(3);
    const after = @typeInfo(@TypeOf(byCount)).@"fn";
    return Result(before.return_type == null, @TypeOf(a) == [2]u8 and @TypeOf(b) == [3]u8, after.return_type == null);
}

pub fn function_pointer_reflection() type {
    const pointer = &typed;
    const generic = @typeInfo(@TypeOf(pointer.*)).@"fn";
    const concrete = @typeInfo(fn (u8) u8).@"fn";
    const value = pointer(3);
    return Result(generic.is_generic and generic.return_type == null, !concrete.is_generic and concrete.return_type.? == u8, @TypeOf(value) == u8);
}
