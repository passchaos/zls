fn Result(comptime a: usize, comptime b: usize, comptime c: usize) type {
    return struct { first: [a]u8, second: [b]u8, third: [c]u8 };
}

pub fn pointer_sentinel_read() type {
    const T = [*:3]const u8;
    const info = @typeInfo(T).pointer;
    const pointer: *const u8 = @ptrCast(info.sentinel_ptr.?);
    return Result(pointer.*, @intFromBool(info.sentinel_ptr != null), @intFromBool(info.child == u8));
}

pub fn slice_sentinel_read() type {
    const T = [:5]const u8;
    const info = @typeInfo(T).pointer;
    const pointer: *const u8 = @ptrCast(info.sentinel_ptr.?);
    return Result(pointer.*, @intFromBool(info.sentinel_ptr != null), @intFromBool(info.child == u8));
}

pub fn array_sentinel_read() type {
    const T = [2:7]u8;
    const info = @typeInfo(T).array;
    const pointer: *const u8 = @ptrCast(info.sentinel_ptr.?);
    return Result(pointer.*, info.len, @intFromBool(info.child == u8));
}

pub fn pointer_sentinel_method() type {
    const T = [*:3]const u8;
    const info = @typeInfo(T).pointer;

    return Result(info.sentinel().?, @intFromBool(info.sentinel_ptr != null), @intFromBool(@TypeOf(info.sentinel().?) == u8));
}

pub fn array_sentinel_method() type {
    const T = [2:7]u8;
    const info = @typeInfo(T).array;

    return Result(info.sentinel().?, info.len, @intFromBool(@TypeOf(info.sentinel().?) == u8));
}

pub fn no_pointer_sentinel() type {
    const T = [*]const u8;
    const info = @typeInfo(T).pointer;

    return Result(@intFromBool(info.sentinel() == null), @intFromBool(info.sentinel_ptr == null), @intFromBool(info.child == u8));
}

pub fn no_array_sentinel() type {
    const T = [2]u8;
    const info = @typeInfo(T).array;

    return Result(@intFromBool(info.sentinel() == null), info.len, @intFromBool(info.sentinel_ptr == null));
}

pub fn wide_sentinel_read() type {
    const T = [*:300]const u16;
    const info = @typeInfo(T).pointer;
    const pointer: *const u16 = @ptrCast(@alignCast(info.sentinel_ptr.?));
    return Result(pointer.*, @intFromBool(info.child == u16), @intFromBool(info.sentinel_ptr != null));
}

pub fn wide_sentinel_method() type {
    const T = [*:300]const u16;
    const info = @typeInfo(T).pointer;

    return Result(info.sentinel().?, @intFromBool(@TypeOf(info.sentinel().?) == u16), 1);
}

pub fn bool_sentinel_read() type {
    const T = [2:true]bool;
    const info = @typeInfo(T).array;
    const pointer: *const bool = @ptrCast(info.sentinel_ptr.?);
    return Result(@intFromBool(pointer.*), info.len, @intFromBool(info.child == bool));
}

pub fn sentinel_pointer_identity() type {
    const T = [*:3]const u8;
    const info = @typeInfo(T).pointer;
    const again = @typeInfo(T).pointer.sentinel_ptr.?;
    return Result(@intFromBool(info.sentinel_ptr.? == again), @intFromBool(info.sentinel_ptr.? == @as(*const anyopaque, &@as(u8, 3))), 1);
}

pub fn array_pointer_sentinel_identity() type {
    const T = [2:3]u8;
    const info = @typeInfo(T).array;
    const pointer = @typeInfo([*:3]const u8).pointer.sentinel_ptr.?;
    return Result(@intFromBool(info.sentinel_ptr.? == pointer), info.len, 1);
}

pub fn meta_pointer_sentinel() type {
    const std = @import("std");
    const result = std.meta.sentinel([*:3]const u8);
    return Result(result.?, @intFromBool(@TypeOf(result.?) == u8), 1);
}

pub fn meta_array_sentinel() type {
    const std = @import("std");
    const result = std.meta.sentinel([2:7]u8);
    return Result(result.?, @intFromBool(@TypeOf(result.?) == u8), 1);
}

pub fn meta_single_array_pointer_sentinel() type {
    const std = @import("std");
    const result = std.meta.sentinel(*const [2:7]u8);
    return Result(result.?, @intFromBool(@TypeOf(result.?) == u8), 1);
}

pub fn meta_missing_sentinels() type {
    const std = @import("std");
    return Result(@intFromBool(std.meta.sentinel([*]const u8) == null), @intFromBool(std.meta.sentinel([2]u8) == null), @intFromBool(std.meta.sentinel(*const [2]u8) == null));
}

pub fn generic_sentinel_values() type {
    const First = Sentinel(3);
    const Second = Sentinel(5);
    const first = @typeInfo(First).pointer;
    const second = @typeInfo(Second).pointer;
    return Result(first.sentinel().?, second.sentinel().?, @intFromBool(first.sentinel_ptr.? != second.sentinel_ptr.?));
}

fn Sentinel(comptime value: u8) type {
    return [*:value]const u8;
}

pub fn signed_sentinel_value() type {
    const info = @typeInfo([*:-1]const i8).pointer;
    const pointer: *const i8 = @ptrCast(info.sentinel_ptr.?);
    return Result(@intFromBool(pointer.* == -1), @intFromBool(info.sentinel().? == -1), @intFromBool(@TypeOf(pointer.*) == i8));
}

pub fn sentinel_default_shared_identity() type {
    const field = @typeInfo(struct { count: u8 = 3 }).@"struct".fields[0];
    const sentinel = @typeInfo([*:3]const u8).pointer;
    const other = @typeInfo([*:5]const u8).pointer;
    return Result(@intFromBool(field.default_value_ptr.? == sentinel.sentinel_ptr.?), @intFromBool(sentinel.sentinel_ptr.? != other.sentinel_ptr.?), @intFromBool(sentinel.sentinel_ptr.? == @as(*const anyopaque, &@as(u8, 3))));
}

pub fn sentinel_operand_effects() type {
    var executions: usize = 0;
    const pointer: *const u16 = @ptrCast(@alignCast(block: {
        executions += 1;
        break :block @typeInfo([*:300]const u16).pointer.sentinel_ptr.?;
    }));
    return Result(pointer.*, executions, @intFromBool(@TypeOf(pointer.*) == u16));
}

pub fn zero_sentinel_value() type {
    const pointer = @typeInfo([*:0]const u8).pointer;
    const array = @typeInfo([2:0]u8).array;
    return Result(pointer.sentinel().?, array.sentinel().?, @intFromBool(pointer.sentinel_ptr.? == array.sentinel_ptr.?));
}
