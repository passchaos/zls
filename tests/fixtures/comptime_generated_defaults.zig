fn Result(comptime a: usize, comptime b: usize, comptime c: usize) type {
    return struct { first: [a]u8, second: [b]u8, third: [c]u8 };
}

pub fn array_initializer() type {
    const Field = [2]u8;
    const Default = struct {
        const value: Field = .{ 3, 5 };
    };
    const T = @Struct(.auto, null, &.{ "fixed", "value" }, &.{ Field, u8 }, &.{
        .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    const value: T = .{ .fixed = .{ 3, 5 }, .value = 7 };
    return Result(value.fixed[0], value.fixed[1], value.value);
}

pub fn array_write() type {
    const Field = [2]u8;
    const Default = struct {
        const value: Field = .{ 3, 5 };
    };
    const T = @Struct(.auto, null, &.{ "fixed", "value" }, &.{ Field, u8 }, &.{
        .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    var value: T = .{ .value = 7 };
    value.fixed = .{ 3, 5 };
    value.fixed[1] = 5;
    return Result(value.fixed[0], value.fixed[1], value.value);
}

pub fn vector_initializer() type {
    const Field = @Vector(2, u8);
    const Default = struct {
        const value: Field = .{ 3, 5 };
    };
    const T = @Struct(.auto, null, &.{ "fixed", "value" }, &.{ Field, u8 }, &.{
        .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    const value = T{ .fixed = .{ 3, 5 }, .value = 7 };
    return Result(value.fixed[0], value.fixed[1], value.value);
}

pub fn vector_write() type {
    const Field = @Vector(2, u8);
    const Default = struct {
        const value: Field = .{ 3, 5 };
    };
    const T = @Struct(.auto, null, &.{ "fixed", "value" }, &.{ Field, u8 }, &.{
        .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    var value: T = .{ .value = 7 };
    value.fixed = .{ 3, 5 };
    return Result(value.fixed[0], value.fixed[1], value.value);
}

pub fn optional_initializer() type {
    const Field = ?u8;
    const Default = struct {
        const value: Field = 3;
    };
    const T = @Struct(.auto, null, &.{ "fixed", "value" }, &.{ Field, u8 }, &.{
        .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    const value = T{ .fixed = 3, .value = 7 };
    return Result(value.fixed.?, @intFromBool(value.fixed != null), value.value);
}

pub fn optional_write() type {
    const Field = ?u8;
    const Default = struct {
        const value: Field = 3;
    };
    const T = @Struct(.auto, null, &.{ "fixed", "value" }, &.{ Field, u8 }, &.{
        .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    var value: T = .{ .value = 7 };
    value.fixed = 3;
    value.fixed.? = 3;
    return Result(value.fixed.?, @intFromBool(value.fixed != null), value.value);
}

pub fn optional_null_initializer() type {
    const Field = ?u8;
    const Default = struct {
        const value: Field = null;
    };
    const T = @Struct(.auto, null, &.{ "fixed", "value" }, &.{ Field, u8 }, &.{
        .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    const value = T{ .fixed = null, .value = 7 };
    return Result(@intFromBool(value.fixed == null), 1, value.value);
}

pub fn optional_null_write() type {
    const Field = ?u8;
    const Default = struct {
        const value: Field = null;
    };
    const T = @Struct(.auto, null, &.{ "fixed", "value" }, &.{ Field, u8 }, &.{
        .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    var value: T = .{ .value = 7 };
    value.fixed = null;
    return Result(@intFromBool(value.fixed == null), 1, value.value);
}

pub fn error_payload_initializer() type {
    const Field = error{Failure}!u8;
    const Default = struct {
        const value: Field = 3;
    };
    const T = @Struct(.auto, null, &.{ "fixed", "value" }, &.{ Field, u8 }, &.{
        .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    const value = T{ .fixed = 3, .value = 7 };
    return Result(value.fixed catch 99, 1, value.value);
}

pub fn error_payload_write() type {
    const Field = error{Failure}!u8;
    const Default = struct {
        const value: Field = 3;
    };
    const T = @Struct(.auto, null, &.{ "fixed", "value" }, &.{ Field, u8 }, &.{
        .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    var value: T = .{ .value = 7 };
    value.fixed = 3;
    return Result(value.fixed catch 99, 1, value.value);
}

pub fn error_failure_initializer() type {
    const Field = error{Failure}!u8;
    const Default = struct {
        const value: Field = error.Failure;
    };
    const T = @Struct(.auto, null, &.{ "fixed", "value" }, &.{ Field, u8 }, &.{
        .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    const value = T{ .fixed = error.Failure, .value = 7 };
    return Result(value.fixed catch 3, 1, value.value);
}

pub fn error_failure_write() type {
    const Field = error{Failure}!u8;
    const Default = struct {
        const value: Field = error.Failure;
    };
    const T = @Struct(.auto, null, &.{ "fixed", "value" }, &.{ Field, u8 }, &.{
        .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    var value: T = .{ .value = 7 };
    value.fixed = error.Failure;
    return Result(value.fixed catch 3, 1, value.value);
}

pub fn enum_initializer() type {
    const Field = enum { low, high };
    const Default = struct {
        const value: Field = .high;
    };
    const T = @Struct(.auto, null, &.{ "fixed", "value" }, &.{ Field, u8 }, &.{
        .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    const value = T{ .fixed = .high, .value = 7 };
    return Result(@intFromEnum(value.fixed), 1, value.value);
}

pub fn union_initializer() type {
    const Field = union(enum) { count: u8, empty };
    const Default = struct {
        const value: Field = .{ .count = 3 };
    };
    const T = @Struct(.auto, null, &.{ "fixed", "value" }, &.{ Field, u8 }, &.{
        .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    const value = T{ .fixed = .{ .count = 3 }, .value = 7 };
    return Result(value.fixed.count, @intFromBool(value.fixed == .count), value.value);
}

pub fn source_type_write() type {
    const Item = struct { count: u8 };
    const Field = type;
    const Default = struct {
        const value: Field = Item;
    };
    const T = @Struct(.auto, null, &.{ "fixed", "value" }, &.{ Field, u8 }, &.{
        .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    var value: T = .{ .value = 7 };
    value.fixed = Item;
    return Result(@sizeOf(value.fixed), @intFromBool(value.fixed == Item), value.value);
}

pub fn array_type_initializer() type {
    const Field = [2]type;
    const Default = struct {
        const value: Field = .{ u8, u16 };
    };
    const T = @Struct(.auto, null, &.{ "fixed", "value" }, &.{ Field, u8 }, &.{
        .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    const value = T{ .fixed = .{ u8, u16 }, .value = 7 };
    return Result(@sizeOf(value.fixed[0]), @sizeOf(value.fixed[1]), value.value);
}

fn array() [2]u8 {
    return .{ 3, 5 };
}

pub fn array_function_default() type {
    const Field = [2]u8;
    const Default = struct {
        const value: Field = .{ 3, 5 };
    };
    const T = @Struct(.auto, null, &.{ "fixed", "value" }, &.{ Field, u8 }, &.{
        .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    const value = T{ .fixed = array(), .value = 7 };
    return Result(value.fixed[0], value.fixed[1], value.value);
}

pub fn array_copy_write() type {
    const Field = [2]u8;
    const Default = struct {
        const value: Field = .{ 3, 5 };
    };
    const T = @Struct(.auto, null, &.{ "fixed", "value" }, &.{ Field, u8 }, &.{
        .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    var value: T = .{ .value = 7 };
    const replacement = Default.value;
    value.fixed = replacement;
    return Result(value.fixed[0], value.fixed[1], value.value);
}

pub fn slice_initializer() type {
    const Field = []const u8;
    const Default = struct {
        const value: Field = "hello";
    };
    const T = @Struct(.auto, null, &.{ "fixed", "value" }, &.{ Field, u8 }, &.{
        .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    const value = T{ .fixed = "hello", .value = 7 };
    return Result(value.fixed.len, @intFromBool(value.fixed[0] == 'h'), value.value);
}

pub fn slice_write() type {
    const Field = []const u8;
    const Default = struct {
        const value: Field = "hello";
    };
    const T = @Struct(.auto, null, &.{ "fixed", "value" }, &.{ Field, u8 }, &.{
        .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    var value: T = .{ .value = 7 };
    value.fixed = "hello";
    return Result(value.fixed.len, @intFromBool(value.fixed[0] == 'h'), value.value);
}

pub fn pointer_initializer() type {
    const Backing = struct {
        const value: u8 = 3;
    };
    const Field = *const u8;
    const Default = struct {
        const value: Field = &Backing.value;
    };
    const T = @Struct(.auto, null, &.{ "fixed", "value" }, &.{ Field, u8 }, &.{
        .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    const value = T{ .fixed = &Backing.value, .value = 7 };
    return Result(value.fixed.*, @intFromBool(value.fixed == &Backing.value), value.value);
}

pub fn pointer_write() type {
    const Backing = struct {
        const value: u8 = 3;
    };
    const Field = *const u8;
    const Default = struct {
        const value: Field = &Backing.value;
    };
    const T = @Struct(.auto, null, &.{ "fixed", "value" }, &.{ Field, u8 }, &.{
        .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    var value: T = .{ .value = 7 };
    value.fixed = &Backing.value;
    return Result(value.fixed.*, @intFromBool(value.fixed == &Backing.value), value.value);
}

pub fn source_nested_initializer() type {
    const Field = struct { data: [2]u8, item: ?u8 };
    const Default = struct {
        const value: Field = .{ .data = .{ 3, 5 }, .item = 9 };
    };
    const T = @Struct(.auto, null, &.{ "fixed", "value" }, &.{ Field, u8 }, &.{
        .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    const value: T = .{ .fixed = .{ .item = 9, .data = .{ 3, 5 } }, .value = 7 };
    return Result(value.fixed.data[0], value.fixed.item.?, value.value);
}

pub fn array_type_write() type {
    const Field = [2]type;
    const Default = struct {
        const value: Field = .{ u8, u16 };
    };
    const T = @Struct(.auto, null, &.{ "fixed", "value" }, &.{ Field, u8 }, &.{
        .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    var value: T = .{ .value = 7 };
    value.fixed = .{ u8, u16 };
    value.fixed[1] = u16;
    return Result(@sizeOf(value.fixed[0]), @sizeOf(value.fixed[1]), value.value);
}

fn Model(comptime count: usize) type {
    return struct { bytes: [count]u8 };
}

pub fn generic_source_type_write() type {
    const Field = type;
    const Default = struct {
        const value: Field = Model(3);
    };
    const T = @Struct(.auto, null, &.{ "fixed", "value" }, &.{ Field, u8 }, &.{
        .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    var value: T = .{ .value = 7 };
    value.fixed = Model(3);
    return Result(@sizeOf(value.fixed), @intFromBool(value.fixed == Model(3)), value.value);
}

pub fn generic_source_default() type {
    const Field = Model(3);
    const Default = struct {
        const value: Field = .{ .bytes = .{ 3, 5, 7 } };
    };
    const T = @Struct(.auto, null, &.{ "fixed", "value" }, &.{ Field, u8 }, &.{
        .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    const value: T = .{ .fixed = .{ .bytes = .{ 3, 5, 7 } }, .value = 7 };
    return Result(value.fixed.bytes[0], value.fixed.bytes[1], value.value);
}

pub fn undefined_array_initializer() type {
    const Field = [2]u8;
    const Default = struct {
        const value: Field = .{ 3, undefined };
    };
    const T = @Struct(.auto, null, &.{ "fixed", "value" }, &.{ Field, u8 }, &.{
        .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    const value: T = .{ .fixed = .{ 3, undefined }, .value = 7 };
    return Result(value.fixed[0], @sizeOf(@FieldType(T, "fixed")), value.value);
}

pub fn slice_copy_write() type {
    const Field = []const u8;
    const Default = struct {
        const value: Field = "hello";
    };
    const T = @Struct(.auto, null, &.{ "fixed", "value" }, &.{ Field, u8 }, &.{
        .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    var value: T = .{ .value = 7 };
    const replacement = Default.value;
    value.fixed = replacement;
    return Result(value.fixed.len, @intFromBool(value.fixed[0] == 'h'), value.value);
}

pub fn slice_self_write() type {
    const Field = []const u8;
    const Default = struct {
        const value: Field = "hello";
    };
    const T = @Struct(.auto, null, &.{ "fixed", "value" }, &.{ Field, u8 }, &.{
        .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    var value: T = .{ .value = 7 };
    value.fixed = value.fixed;
    return Result(value.fixed.len, @intFromBool(value.fixed[0] == 'h'), value.value);
}

pub fn slice_effect_write() type {
    const Field = []const u8;
    const Default = struct {
        const value: Field = "hello";
    };
    const T = @Struct(.auto, null, &.{ "fixed", "value" }, &.{ Field, u8 }, &.{
        .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    var value: T = .{ .value = 7 };
    var executions: usize = 0;
    value.fixed = block: {
        executions += 1;
        break :block "hello";
    };
    return Result(value.fixed.len, executions, value.value);
}

pub fn slice_backing_write() type {
    const Backing = struct {
        const value = [_]u8{ 3, 5, 7 };
    };
    const Default = struct {
        const value: []const u8 = Backing.value[1..];
    };
    const T = @Struct(.auto, null, &.{ "fixed", "value" }, &.{ []const u8, u8 }, &.{
        .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    var value: T = .{ .value = 7 };
    value.fixed = Backing.value[1..];
    return Result(value.fixed[0], value.fixed.len, value.value);
}

pub fn slice_backing_initializer() type {
    const Backing = struct {
        const value = [_]u8{ 3, 5, 7 };
    };
    const Default = struct {
        const value: []const u8 = Backing.value[1..];
    };
    const T = @Struct(.auto, null, &.{ "fixed", "value" }, &.{ []const u8, u8 }, &.{
        .{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }, .{},
    });
    const value = T{ .fixed = Backing.value[1..], .value = 7 };
    return Result(value.fixed[0], value.fixed.len, value.value);
}

pub fn source_union_tag_comparisons() type {
    const U = union(enum) { count: u8, empty };
    const value: U = .{ .count = 3 };
    const Tag = @typeInfo(U).@"union".tag_type.?;
    const tag: Tag = .count;
    return Result(@intFromBool(value == .count and .count == value), @intFromBool(value != .empty and .empty != value), @intFromBool(value == tag and tag == value));
}

pub fn generated_union_tag_comparisons() type {
    const U = @Union(.auto, @Enum(u8, .exhaustive, &.{ "count", "empty" }, &.{ 1, 3 }), &.{ "count", "empty" }, &.{ u8, void }, &.{ .{}, .{} });
    const value: U = .{ .count = 3 };
    const Tag = @typeInfo(U).@"union".tag_type.?;
    const tag: Tag = .count;
    return Result(@intFromBool(value == .count and .count == value), @intFromBool(value != .empty and .empty != value), @intFromBool(value == tag and tag == value));
}
