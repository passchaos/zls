fn Result(comptime a: usize, comptime b: usize, comptime c: usize) type {
    return struct { first: [a]u8, second: [b]u8, third: [c]u8 };
}

pub fn scalar_default() type {
    const T = struct { comptime fixed: u8 = 3, value: u16 };
    const value: T = .{ .value = 7 };
    return Result(value.fixed, @intFromBool(@FieldType(T, "fixed") == u8), value.value);
}

pub fn scalar_undefined() type {
    const T = struct { comptime fixed: u8 = 3, value: u16 };
    const value: T = undefined;
    return Result(value.fixed, @intFromBool(@FieldType(T, "fixed") == u8), 0);
}

pub fn scalar_initializer() type {
    const T = struct { comptime fixed: u8 = 3, value: u16 };
    var executions: usize = 0;
    const value = T{ .fixed = block: {
        executions += 1;
        break :block 3;
    }, .value = 7 };
    return Result(value.fixed, executions, value.value);
}

pub fn scalar_write() type {
    const T = struct { comptime fixed: u8 = 3, value: u16 };
    var executions: usize = 0;
    var value: T = .{ .value = 7 };
    value.fixed = block: {
        executions += 1;
        break :block 3;
    };
    return Result(value.fixed, executions, value.value);
}

pub fn scalar_reassignment() type {
    const T = struct { comptime fixed: u8 = 3, value: u16 };
    var value: T = .{ .value = 7 };
    value = T{ .fixed = 3, .value = 9 };
    return Result(value.fixed, @intFromBool(@FieldType(T, "fixed") == u8), value.value);
}

pub fn source_default() type {
    const Item = struct { count: usize };
    const T = struct { comptime fixed: Item = .{ .count = 3 }, value: u16 };
    const value: T = .{ .value = 7 };
    return Result(value.fixed.count, @intFromBool(@FieldType(T, "fixed") == Item), value.value);
}

pub fn source_initializer() type {
    const Item = struct { count: usize };
    const T = struct { comptime fixed: Item = .{ .count = 3 }, value: u16 };
    const value: T = .{ .fixed = .{ .count = 3 }, .value = 7 };
    return Result(value.fixed.count, @intFromBool(@FieldType(T, "fixed") == Item), value.value);
}

pub fn source_write() type {
    const Item = struct { count: usize };
    const T = struct { comptime fixed: Item = .{ .count = 3 }, value: u16 };
    var value: T = .{ .value = 7 };
    value.fixed = .{ .count = 3 };
    value.fixed.count = 3;
    return Result(value.fixed.count, @intFromBool(@FieldType(T, "fixed") == Item), value.value);
}

pub fn type_default() type {
    const Item = struct { count: usize };
    const T = struct { comptime fixed: type = Item, value: u16 };
    const value: T = .{ .value = 7 };
    const instance: value.fixed = .{ .count = 3 };
    return Result(instance.count, @intFromBool(value.fixed == Item), value.value);
}

pub fn type_initializer() type {
    const Item = struct { count: usize };
    const T = struct { comptime fixed: type = Item, value: u16 };
    const value = T{ .fixed = Item, .value = 7 };
    const instance: value.fixed = .{ .count = 3 };
    return Result(instance.count, @intFromBool(@FieldType(T, "fixed") == type), value.value);
}

pub fn type_write() type {
    const Item = struct { count: usize };
    const T = struct { comptime fixed: type = Item, value: u16 };
    var value: T = .{ .value = 7 };
    @field(value, "fixed") = Item;
    const instance: value.fixed = .{ .count = 3 };
    return Result(instance.count, @intFromBool(value.fixed == Item), value.value);
}

pub fn array_write() type {
    const T = struct { comptime fixed: [2]u8 = .{ 3, 5 }, value: u16 };
    var value: T = .{ .value = 7 };
    value.fixed = .{ 3, 5 };
    value.fixed[1] = 5;
    return Result(value.fixed[0], value.fixed[1], value.value);
}

pub fn optional_write() type {
    const T = struct { comptime fixed: ?u8 = 3, value: u16 };
    var value: T = .{ .value = 7 };
    value.fixed = 3;
    value.fixed.? = 3;
    return Result(value.fixed.?, @intFromBool(value.fixed != null), value.value);
}

pub fn slice_write() type {
    const T = struct { comptime fixed: []const u8 = "hello", value: u16 };
    var value: T = .{ .value = 7 };
    value.fixed = "hello";
    return Result(value.fixed.len, @intFromBool(value.fixed[0] == 'h'), value.value);
}

pub fn generic_source_defaults() type {
    const T = Generic(3);
    const value: T = .{ .value = 7 };
    return Result(value.fixed, @intFromBool(@FieldType(T, "fixed") == u8), value.value);
}

fn Generic(comptime count: u8) type {
    return struct { comptime fixed: u8 = count, value: u16 };
}

pub fn repeated_source_defaults() type {
    const A = Generic(3);
    const B = Generic(5);
    const a: A = undefined;
    const b: B = undefined;
    return Result(a.fixed, b.fixed, @intFromBool(A != B));
}

pub fn source_pointer_write() type {
    const T = struct { comptime fixed: u8 = 3, value: u16 };
    var executions: usize = 0;
    var value: T = .{ .value = 7 };
    const pointer = &value.fixed;
    pointer.* = block: {
        executions += 1;
        break :block 3;
    };
    return Result(value.fixed, executions, value.value);
}

pub fn source_comptime_only() type {
    const T = struct { comptime fixed: u8 = 3 };
    const value: T = undefined;
    return Result(value.fixed, @sizeOf(T), @alignOf(T));
}

pub fn source_array_default() type {
    const T = struct { comptime fixed: [2]u8 = .{ 3, 5 }, value: u16 };
    const value: T = undefined;
    return Result(value.fixed[0], value.fixed[1], @sizeOf(T));
}

pub fn source_undefined_default() type {
    const T = struct { comptime fixed: u8 = undefined, value: u16 };
    const value: T = .{ .value = 7 };
    return Result(@sizeOf(T), @intFromBool(@FieldType(T, "fixed") == u8), value.value);
}
const Global = struct { comptime fixed: u8 = 3, value: u16 };
pub fn global_source_defaults() type {
    const value: Global = .{ .value = 7 };
    return Result(value.fixed, @intFromBool(@FieldType(Global, "fixed") == u8), value.value);
}
