const std = @import("std");

fn Result(comptime first: usize, comptime second: usize, comptime third: usize) type {
    return struct { first: [first]u8, second: [second]u8, third: [third]u8 };
}

fn selectedType(executions: *usize) type {
    executions.* += 1;
    return usize;
}

fn returnTyped(comptime executions: *usize, value: usize) selectedType(executions) {
    return value + 1;
}

fn parameterTyped(comptime executions: *usize, value: selectedType(executions)) usize {
    return value + 1;
}

pub fn return_type_effect() type {
    var executions: usize = 0;
    const value = returnTyped(&executions, 3);
    return Result(value, executions, 0);
}

pub fn parameter_type_effect() type {
    var executions: usize = 0;
    const value = parameterTyped(&executions, 3);
    return Result(value, executions, 0);
}

fn bothTyped(comptime executions: *usize, value: selectedType(executions)) selectedType(executions) {
    return value + 1;
}

pub fn parameter_and_return_effects() type {
    var executions: usize = 0;
    const value = bothTyped(&executions, 3);
    return Result(value, executions, 0);
}

pub fn repeated_signature_calls() type {
    var executions: usize = 0;
    const first = bothTyped(&executions, 3);
    const second = bothTyped(&executions, 5);
    return Result(first, second, executions);
}

pub fn signature_call_builtin() type {
    var executions: usize = 0;
    const value = @call(.auto, bothTyped, .{ &executions, @as(usize, 3) });
    return Result(value, executions, 0);
}

fn recursiveTyped(comptime executions: *usize, comptime depth: usize) selectedType(executions) {
    if (depth == 0) return 1;
    return recursiveTyped(executions, depth - 1) + 1;
}

pub fn recursive_signature_calls() type {
    var executions: usize = 0;
    const value = recursiveTyped(&executions, 2);
    return Result(value, executions, 0);
}

fn orderedType(trace: *usize, comptime digit: usize) type {
    trace.* = trace.* * 10 + digit;
    return usize;
}

fn orderedArgument(trace: *usize, comptime digit: usize) usize {
    trace.* = trace.* * 10 + digit;
    return 3;
}

fn ordered(comptime trace: *usize, first: orderedType(trace, 2), second: orderedType(trace, 4)) orderedType(trace, 5) {
    trace.* = trace.* * 10 + 6;
    return first + second;
}

pub fn signature_argument_order() type {
    var trace: usize = 0;
    const value = ordered(&trace, orderedArgument(&trace, 1), orderedArgument(&trace, 3));
    return Result(value, trace, 0);
}

pub fn signature_builtin_argument_order() type {
    var trace: usize = 0;
    const value = @call(.auto, ordered, .{ &trace, orderedArgument(&trace, 1), orderedArgument(&trace, 3) });
    return Result(value, trace, 0);
}

fn narrowType(executions: *usize) type {
    executions.* += 1;
    return u8;
}

fn narrow(comptime executions: *usize, value: usize) narrowType(executions) {
    return @intCast(value);
}

pub fn signature_return_cast() type {
    var executions: usize = 0;
    const value = narrow(&executions, 7);
    return Result(value, executions, @intFromBool(@TypeOf(value) == u8));
}

fn errorReturn(comptime executions: *usize) !narrowType(executions) {
    return 7;
}

pub fn signature_inferred_error() type {
    var executions: usize = 0;
    const value = errorReturn(&executions) catch unreachable;
    return Result(value, executions, @intFromBool(@TypeOf(value) == u8));
}

const Check = struct {
    value: usize,

    fn read(comptime self: @This(), comptime executions: *usize) selectedType(executions) {
        return self.value;
    }

    fn increment(self: *@This(), comptime executions: *usize, amount: selectedType(executions)) selectedType(executions) {
        self.value += amount;
        return self.value;
    }
};

pub fn signature_instance_methods() type {
    var executions: usize = 0;
    var check = Check{ .value = 2 };
    const value = check.increment(&executions, 3);
    const observed = check.read(&executions);
    return Result(value, observed, executions);
}

fn callbackType(executions: *usize) type {
    executions.* += 1;
    return fn (usize, u8) void;
}

pub fn signature_argument_tuple() type {
    var executions: usize = 0;
    const Direct = std.meta.ArgsTuple(callbackType(&executions));
    const Indirect = @call(.auto, std.meta.ArgsTuple, .{callbackType(&executions)});
    return Result(@intFromBool(@FieldType(Direct, "0") == usize), @intFromBool(@FieldType(Indirect, "1") == u8), executions);
}

pub fn signature_argument_tuple_metadata() type {
    const Attributes = fn (comptime usize, noalias *u8, u16) void;
    const Tuple = std.meta.ArgsTuple(Attributes);
    const Empty = std.meta.ArgsTuple(fn () void);
    return Result(@intFromBool(@FieldType(Tuple, "0") == usize), @intFromBool(@FieldType(Tuple, "1") == *u8), @typeInfo(Empty).@"struct".fields.len);
}

fn generated(comptime value: usize) type {
    const captured = value;
    return struct { items: [captured]u8 };
}

fn countedArgument(executions: *usize) usize {
    executions.* += 1;
    return 3;
}

pub fn cached_type_argument_effects() type {
    var executions: usize = 0;
    const First = generated(countedArgument(&executions));
    const Second = generated(countedArgument(&executions));
    const Other = generated(4);
    return Result(@typeInfo(@FieldType(First, "items")).array.len, @intFromBool(First == Second and First != Other), executions);
}

const PointerInput = struct { executions: *usize };

fn fromPointerInput(comptime input: PointerInput) type {
    input.executions.* += 1;
    return struct { value: u8 };
}

pub fn aggregate_pointer_call_effects() type {
    var executions: usize = 0;
    const First = fromPointerInput(.{ .executions = &executions });
    const Second = fromPointerInput(.{ .executions = &executions });
    return Result(@intFromBool(First == Second), executions, 0);
}

fn usingPointer(comptime input: ?*usize) type {
    if (input) |executions| executions.* += 1;
    return struct { value: u8 };
}

pub fn optional_pointer_call_effects() type {
    var executions: usize = 0;
    const First = usingPointer(&executions);
    const Second = usingPointer(&executions);
    return Result(@intFromBool(First == Second), executions, 0);
}
