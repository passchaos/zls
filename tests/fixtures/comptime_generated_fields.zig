fn Result(comptime first: usize, comptime second: usize, comptime third: usize) type {
    return struct { first: [first]u8, second: [second]u8, third: [third]u8 };
}

fn Record(comptime count: u8, comptime fixed: bool) type {
    const Default = struct {
        const value: u8 = count;
    };
    return @Struct(.auto, null, &.{ "fixed", "value" }, &.{ u8, u16 }, &.{
        .{ .@"comptime" = fixed, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
}

pub fn generated_comptime_scalar() type {
    const T = Record(3, true);
    const value: T = .{ .value = 7 };
    const info = @typeInfo(T).@"struct".fields[0];
    return Result(value.fixed, @intFromBool(info.is_comptime and info.default_value_ptr != null), value.value);
}

pub fn generated_comptime_undefined() type {
    const T = Record(5, true);
    const value: T = undefined;
    return Result(value.fixed, @intFromBool(@FieldType(T, "fixed") == u8), 0);
}

pub fn explicit_comptime_initializer() type {
    const T = Record(7, true);
    var executions: usize = 0;
    const value = T{ .fixed = block: {
        executions += 1;
        break :block 7;
    }, .value = 9 };
    return Result(value.fixed, executions, value.value);
}

pub fn generated_comptime_type() type {
    const Item = struct { count: usize };
    const Default = struct {
        const value: type = Item;
    };
    const T = @Struct(.auto, null, &.{ "Item", "value" }, &.{ type, u8 }, &.{
        .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    const value: T = .{ .value = 11 };
    const instance = value.Item{ .count = 13 };
    return Result(instance.count, @intFromBool(value.Item == Item), value.value);
}

pub fn generated_comptime_source_value() type {
    const Item = struct { count: usize };
    const Default = struct {
        const value: Item = .{ .count = 15 };
    };
    const T = @Struct(.auto, null, &.{ "fixed", "value" }, &.{ Item, u8 }, &.{
        .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    const value: T = undefined;
    return Result(value.fixed.count, @intFromBool(@FieldType(T, "fixed") == Item), @intFromBool(@typeInfo(T).@"struct".fields[0].is_comptime));
}

pub fn generated_comptime_layout() type {
    const T = Record(3, true);
    const Plain = struct { value: u16 };
    return Result(@sizeOf(T), @intFromBool(@sizeOf(T) == @sizeOf(Plain)), @intFromBool(@offsetOf(T, "value") == 0));
}

pub fn comptime_attribute_identity() type {
    const Fixed = Record(3, true);
    const Same = Record(3, true);
    const Runtime = Record(3, false);
    return Result(@intFromBool(Fixed == Same), @intFromBool(Fixed != Runtime), @intFromBool(!@typeInfo(Runtime).@"struct".fields[0].is_comptime));
}

pub fn repeated_comptime_defaults() type {
    const A = Record(3, true);
    const B = Record(5, true);
    const Again = Record(3, true);
    const a: A = undefined;
    const b: B = undefined;
    return Result(a.fixed, b.fixed, @intFromBool(A == Again and A != B));
}

pub fn explicit_comptime_source_initializer() type {
    const Item = struct { count: usize };
    const Default = struct {
        const value: Item = .{ .count = 15 };
    };
    const T = @Struct(.auto, null, &.{ "fixed", "value" }, &.{ Item, u8 }, &.{
        .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    var executions: usize = 0;
    const value: T = .{ .fixed = block: {
        executions += 1;
        break :block .{ .count = 15 };
    }, .value = 9 };
    return Result(value.fixed.count, executions, value.value);
}

pub fn explicit_comptime_type_initializer() type {
    const Item = struct { count: usize };
    const Default = struct {
        const value: type = Item;
    };
    const T = @Struct(.auto, null, &.{ "Item", "value" }, &.{ type, u8 }, &.{
        .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    const value = T{ .Item = Item, .value = 7 };
    const instance: value.Item = .{ .count = 13 };
    return Result(instance.count, @intFromBool(@FieldType(T, "Item") == type), value.value);
}

pub fn same_comptime_field_write() type {
    const T = Record(3, true);
    var executions: usize = 0;
    var value: T = .{ .value = 7 };
    value.fixed = block: {
        executions += 1;
        break :block 3;
    };
    value.value += 2;
    return Result(value.fixed, executions, value.value);
}

pub fn same_comptime_source_write() type {
    const Item = struct { count: usize };
    const Default = struct {
        const value: Item = .{ .count = 15 };
    };
    const T = @Struct(.auto, null, &.{ "fixed", "value" }, &.{ Item, u8 }, &.{
        .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    var value: T = .{ .value = 7 };
    value.fixed = .{ .count = 15 };
    value.fixed.count = 15;
    return Result(value.fixed.count, @intFromBool(@FieldType(T, "fixed") == Item), value.value);
}

pub fn same_comptime_type_write() type {
    const Default = struct {
        const value: type = u16;
    };
    const T = @Struct(.auto, null, &.{ "Item", "value" }, &.{ type, u8 }, &.{
        .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    var value: T = .{ .value = 7 };
    @field(value, "Item") = u16;
    return Result(@sizeOf(value.Item), @intFromBool(value.Item == u16), value.value);
}

pub fn aligned_comptime_field() type {
    const Default = struct {
        const value: u8 = 3;
    };
    const T = @Struct(.auto, null, &.{ "fixed", "value" }, &.{ u8, u16 }, &.{
        .{ .@"comptime" = true, .@"align" = 4, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    return Result(@sizeOf(T), @alignOf(T), @typeInfo(T).@"struct".fields[0].alignment.?);
}

pub fn comptime_only_layout() type {
    const Default = struct {
        const value: u8 = 3;
    };
    const T = @Struct(.auto, null, &.{"fixed"}, &.{u8}, &.{.{
        .@"comptime" = true,
        .default_value_ptr = @ptrCast(&Default.value),
    }});
    const value: T = undefined;
    return Result(@sizeOf(T), @alignOf(T), value.fixed);
}

pub fn comptime_initializer_result_location() type {
    const T = Record(3, true);
    var executions: usize = 0;
    var value: T = .{ .value = 7 };
    value = .{ .fixed = block: {
        executions += 1;
        break :block 3;
    }, .value = 9 };
    return Result(value.fixed, executions, value.value);
}

pub fn undefined_comptime_default() type {
    const Default = struct {
        const value: u8 = undefined;
    };
    const T = @Struct(.auto, null, &.{ "fixed", "value" }, &.{ u8, u16 }, &.{
        .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    const value: T = .{ .value = 7 };
    return Result(@sizeOf(T), @intFromBool(@FieldType(T, "fixed") == u8), value.value);
}
