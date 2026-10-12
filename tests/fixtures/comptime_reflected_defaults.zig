fn Result(comptime a: usize, comptime b: usize, comptime c: usize) type {
    return struct { first: [a]u8, second: [b]u8, third: [c]u8 };
}

pub fn source_scalar() type {
    const T = struct { count: u8 = 3 };
    const field = @typeInfo(T).@"struct".fields[0];
    const pointer: *const u8 = @ptrCast(@alignCast(field.default_value_ptr.?));
    return Result(pointer.*, @intFromBool(field.default_value_ptr != null), @sizeOf(T));
}

pub fn source_comptime() type {
    const T = struct { comptime count: u8 = 3, value: u16 };
    const field = @typeInfo(T).@"struct".fields[0];
    const pointer: *const u8 = @ptrCast(@alignCast(field.default_value_ptr.?));
    return Result(pointer.*, @intFromBool(field.is_comptime), @sizeOf(T));
}

pub fn source_type() type {
    const Item = struct { count: u8 };
    const T = struct { comptime ItemType: type = Item };
    const field = @typeInfo(T).@"struct".fields[0];
    const pointer: *const type = @ptrCast(@alignCast(field.default_value_ptr.?));
    return Result(@sizeOf(pointer.*), @intFromBool(pointer.* == Item), @intFromBool(field.type == type));
}

pub fn source_array() type {
    const T = struct { bytes: [2]u8 = .{ 3, 5 } };
    const field = @typeInfo(T).@"struct".fields[0];
    const pointer: *const [2]u8 = @ptrCast(@alignCast(field.default_value_ptr.?));
    return Result(pointer.*[0], pointer.*[1], @sizeOf(T));
}

pub fn source_slice() type {
    const T = struct { bytes: []const u8 = "hello" };
    const field = @typeInfo(T).@"struct".fields[0];
    const pointer: *const []const u8 = @ptrCast(@alignCast(field.default_value_ptr.?));
    return Result(pointer.*.len, @intFromBool(pointer.*[0] == 'h'), @intFromBool(field.type == []const u8));
}

pub fn source_aggregate() type {
    const Item = struct { count: u8 };
    const T = struct { item: Item = .{ .count = 3 } };
    const field = @typeInfo(T).@"struct".fields[0];
    const pointer: *const Item = @ptrCast(@alignCast(field.default_value_ptr.?));
    return Result(pointer.*.count, @intFromBool(field.type == Item), @sizeOf(T));
}

pub fn source_optional() type {
    const T = struct { count: ?u8 = 3 };
    const field = @typeInfo(T).@"struct".fields[0];
    const pointer: *const ?u8 = @ptrCast(@alignCast(field.default_value_ptr.?));
    return Result(pointer.*.?, @intFromBool(pointer.* != null), @intFromBool(field.type == ?u8));
}

pub fn source_optional_null() type {
    const T = struct { count: ?u8 = null };
    const field = @typeInfo(T).@"struct".fields[0];
    const pointer: *const ?u8 = @ptrCast(@alignCast(field.default_value_ptr.?));
    return Result(@intFromBool(pointer.* == null), @intFromBool(field.default_value_ptr != null), @intFromBool(field.type == ?u8));
}

pub fn generated_scalar() type {
    const Default = struct {
        const value: u8 = 3;
    };
    const T = @Struct(.auto, null, &.{"count"}, &.{u8}, &.{.{ .default_value_ptr = @ptrCast(&Default.value) }});
    const field = @typeInfo(T).@"struct".fields[0];
    const pointer: *const u8 = @ptrCast(@alignCast(field.default_value_ptr.?));
    return Result(pointer.*, @intFromBool(field.default_value_ptr != null), @sizeOf(T));
}

pub fn generated_source() type {
    const Item = struct { count: u8 };
    const Default = struct {
        const value: Item = .{ .count = 3 };
    };
    const T = @Struct(.auto, null, &.{"item"}, &.{Item}, &.{.{ .default_value_ptr = @ptrCast(&Default.value) }});
    const field = @typeInfo(T).@"struct".fields[0];
    const pointer: *const Item = @ptrCast(@alignCast(field.default_value_ptr.?));
    return Result(pointer.*.count, @intFromBool(field.type == Item), @sizeOf(T));
}

pub fn generated_type() type {
    const Item = struct { count: u8 };
    const Default = struct {
        const value: type = Item;
    };
    const T = @Struct(.auto, null, &.{"item"}, &.{type}, &.{.{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }});
    const field = @typeInfo(T).@"struct".fields[0];
    const pointer: *const type = @ptrCast(@alignCast(field.default_value_ptr.?));
    return Result(@sizeOf(pointer.*), @intFromBool(pointer.* == Item), @intFromBool(field.is_comptime));
}

pub fn no_default() type {
    const T = struct { count: u8 };
    const field = @typeInfo(T).@"struct".fields[0];

    return Result(@intFromBool(field.default_value_ptr == null), @intFromBool(!field.is_comptime), @sizeOf(T));
}

pub fn repeat_pointer_identity() type {
    const T = struct { count: u8 = 3 };
    const field = @typeInfo(T).@"struct".fields[0];
    const again = @typeInfo(T).@"struct".fields[0].default_value_ptr.?;
    return Result(@intFromBool(field.default_value_ptr.? == again), 1, 1);
}

pub fn source_equal_defaults_identity() type {
    const A = struct { first: u8 = 3, second: u8 = 3 };
    const B = struct { first: u8 = 3 };
    const a = @typeInfo(A).@"struct".fields;
    const b = @typeInfo(B).@"struct".fields;
    return Result(@intFromBool(a[0].default_value_ptr.? == a[1].default_value_ptr.?), @intFromBool(a[0].default_value_ptr.? == b[0].default_value_ptr.?), @intFromBool(a[0].default_value_ptr.? == @as(*const anyopaque, &@as(u8, 3))));
}

pub fn generated_default_identity() type {
    const Backing = struct {
        const value: u8 = 3;
    };
    const T = @Struct(.auto, null, &.{ "first", "second" }, &.{ u8, u8 }, &.{
        .{ .default_value_ptr = @ptrCast(&Backing.value) },
        .{ .default_value_ptr = @ptrCast(&Backing.value) },
    });
    const fields = @typeInfo(T).@"struct".fields;
    return Result(@intFromBool(fields[0].default_value_ptr.? == fields[1].default_value_ptr.?), @intFromBool(fields[0].default_value_ptr.? != @as(*const anyopaque, &Backing.value)), @intFromBool(fields[0].default_value_ptr.? == @as(*const anyopaque, &@as(u8, 3))));
}

pub fn different_defaults_identity() type {
    const A = struct { first: u8 = 3, second: u8 = 5, wide: u16 = 3 };
    const fields = @typeInfo(A).@"struct".fields;
    return Result(@intFromBool(fields[0].default_value_ptr.? != fields[1].default_value_ptr.?), @intFromBool(fields[0].default_value_ptr.? != fields[2].default_value_ptr.?), @intFromBool(fields[1].default_value_ptr.? == @as(*const anyopaque, &@as(u8, 5))));
}

pub fn generic_reflected_defaults() type {
    const A = Model(3);
    const B = Model(5);
    const a = @typeInfo(A).@"struct".fields[0];
    const b = @typeInfo(B).@"struct".fields[0];
    const pa: *const u8 = @ptrCast(a.default_value_ptr.?);
    const pb: *const u8 = @ptrCast(b.default_value_ptr.?);
    return Result(pa.*, pb.*, @intFromBool(a.default_value_ptr.? != b.default_value_ptr.?));
}
fn Model(comptime count: u8) type {
    return struct { value: u8 = count };
}

pub fn copied_reflected_fields() type {
    const T = struct { count: u8 = 3 };
    const original = @typeInfo(T).@"struct".fields[0];
    const field = original;
    const pointer: *const u8 = @ptrCast(field.default_value_ptr.?);
    return Result(pointer.*, @intFromBool(field.default_value_ptr.? == original.default_value_ptr.?), @intFromBool(field.type == u8));
}

pub fn reflected_void_default() type {
    const T = struct { empty: void = {} };
    const field = @typeInfo(T).@"struct".fields[0];
    const pointer: *const void = @ptrCast(field.default_value_ptr.?);
    const value = pointer.*;
    return Result(@intFromBool(@TypeOf(value) == void), @sizeOf(T), @intFromBool(field.default_value_ptr != null));
}

pub fn generated_array_default() type {
    const Default = struct {
        const value: [2]u8 = .{ 3, 5 };
    };
    const T = @Struct(.auto, null, &.{"bytes"}, &.{[2]u8}, &.{.{ .default_value_ptr = @ptrCast(&Default.value) }});
    const field = @typeInfo(T).@"struct".fields[0];
    const pointer: *const [2]u8 = @ptrCast(field.default_value_ptr.?);
    return Result(pointer.*[0], pointer.*[1], @sizeOf(T));
}

pub fn reconstructed_defaults() type {
    const Base = struct { count: u8 = 3, bytes: [2]u8 = .{ 3, 5 } };
    const fields = @typeInfo(Base).@"struct".fields;
    const T = @Struct(.auto, null, &.{ fields[0].name, fields[1].name }, &.{ fields[0].type, fields[1].type }, &.{
        .{ .default_value_ptr = fields[0].default_value_ptr },
        .{ .default_value_ptr = fields[1].default_value_ptr },
    });
    const value: T = .{};
    return Result(value.count, value.bytes[1], @intFromBool(@typeInfo(T).@"struct".fields[0].default_value_ptr.? == fields[0].default_value_ptr.?));
}

pub fn default_value_method() type {
    const T = struct { count: u8 = 3, absent: u8, optional: ?u8 = null };
    const fields = @typeInfo(T).@"struct".fields;
    return Result(fields[0].defaultValue().?, @intFromBool(fields[1].defaultValue() == null), @intFromBool(fields[2].defaultValue().? == null));
}

pub fn type_default_value_method() type {
    const Item = struct { count: u8 };
    const T = struct { comptime ItemType: type = Item };
    const field = @typeInfo(T).@"struct".fields[0];
    const Default = field.defaultValue().?;
    const instance: Default = .{ .count = 3 };
    return Result(instance.count, @intFromBool(Default == Item), @intFromBool(field.type == type));
}

pub fn generated_default_value_method() type {
    const Default = struct {
        const value: u8 = 3;
    };
    const T = @Struct(.auto, null, &.{"count"}, &.{u8}, &.{.{ .default_value_ptr = @ptrCast(&Default.value) }});
    const field = @typeInfo(T).@"struct".fields[0];
    return Result(field.defaultValue().?, @intFromBool(field.default_value_ptr != null), @intFromBool(field.type == u8));
}

pub fn reflected_pointer_effects() type {
    const T = struct { count: u8 = 3 };
    var executions: usize = 0;
    const pointer: *const u8 = @ptrCast(@alignCast(block: {
        executions += 1;
        break :block @typeInfo(T).@"struct".fields[0].default_value_ptr.?;
    }));
    return Result(pointer.*, executions, @intFromBool(@TypeOf(pointer.*) == u8));
}

pub fn optional_reflected_pointer() type {
    const T = struct { count: u8 = 3 };
    const pointer: ?*const u8 = @ptrCast(@typeInfo(T).@"struct".fields[0].default_value_ptr);
    return Result(pointer.?.*, @intFromBool(pointer != null), @intFromBool(@TypeOf(pointer.?.*) == u8));
}

pub fn type_identity_through_return() type {
    const Item = struct { count: u8 };
    const Namespace = struct {
        fn identity(comptime T: type) type {
            return T;
        }
    };
    const Forward = Namespace.identity(Item);
    const Again = Namespace.identity(Item);
    return Result(@intFromBool(Forward == Item), @intFromBool(Forward == Again), @sizeOf(Forward));
}

pub fn type_identity_through_break() type {
    const Item = struct { count: u8 };
    const Namespace = struct {
        fn identity(comptime T: type) type {
            return block: {
                var executions: usize = 0;
                executions += 1;
                break :block T;
            };
        }
    };
    const Forward = Namespace.identity(Item);
    const Again = Namespace.identity(Item);
    return Result(@intFromBool(Forward == Item), @intFromBool(Forward == Again), @sizeOf(Forward));
}

pub fn reflected_signed_read() type {
    const T = struct { count: u8 = 255 };
    const field = @typeInfo(T).@"struct".fields[0];
    const pointer: *const i8 = @ptrCast(field.default_value_ptr.?);
    return Result(@intFromBool(pointer.* == -1), @intFromBool(@TypeOf(pointer.*) == i8), 1);
}
