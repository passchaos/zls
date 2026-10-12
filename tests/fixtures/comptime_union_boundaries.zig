fn Result(comptime first: usize, comptime second: usize, comptime third: usize) type {
    return struct { first: [first]u8, second: [second]u8, third: [third]u8 };
}

const Item = struct { count: usize };
const Tag = enum { item, empty };
const U = @Union(.auto, Tag, &.{ "item", "empty" }, &.{ Item, void }, &.{ .{}, .{} });

fn identity(value: U) U {
    return value;
}
fn produce(executions: *usize) U {
    executions.* += 1;
    return .{ .item = .{ .count = 3 } };
}

pub fn argument_source_payload() type {
    var executions: usize = 0;
    const value = identity(.{ .item = .{ .count = block: {
        executions += 1;
        break :block 5;
    } } });
    return Result(value.item.count, executions, @intFromBool(@TypeOf(value.item) == Item));
}

pub fn returned_source_payload() type {
    var executions: usize = 0;
    const value = produce(&executions);
    return Result(value.item.count, executions, @intFromBool(@TypeOf(value.item) == Item));
}

pub fn forwarded_source_payload() type {
    var executions: usize = 0;
    const value = identity(produce(&executions));
    return Result(value.item.count, executions, @intFromBool(@TypeOf(value.item) == Item));
}

pub fn optional_returned_payload() type {
    const OptionalU = @Union(.auto, Tag, &.{ "item", "empty" }, &.{ ?Item, void }, &.{ .{}, .{} });
    const Producer = struct {
        fn run(executions: *usize) OptionalU {
            executions.* += 1;
            return .{ .item = .{ .count = 7 } };
        }
    };
    var executions: usize = 0;
    const value = Producer.run(&executions);
    return Result(value.item.?.count, executions, @intFromBool(@TypeOf(value.item.?) == Item));
}

pub fn error_returned_payload() type {
    const ErrorU = @Union(.auto, Tag, &.{ "item", "empty" }, &.{ error{Missing}!Item, void }, &.{ .{}, .{} });
    const Producer = struct {
        fn run(executions: *usize) ErrorU {
            executions.* += 1;
            return .{ .item = .{ .count = 9 } };
        }
    };
    var executions: usize = 0;
    const value = Producer.run(&executions);
    const item = value.item catch unreachable;
    return Result(item.count, executions, @intFromBool(@TypeOf(item) == Item));
}

pub fn value_argument_snapshot() type {
    const Reader = struct {
        fn run(value: U, executions: *usize) usize {
            executions.* += 1;
            return value.item.count;
        }
    };
    var value: U = .{ .item = .{ .count = 11 } };
    var executions: usize = 0;
    const count = Reader.run(value, block: {
        value.item.count = 13;
        break :block &executions;
    });
    return Result(count, value.item.count, executions);
}

pub fn comptime_value_argument_snapshot() type {
    const Reader = struct {
        fn run(comptime value: U, executions: *usize) usize {
            executions.* += 1;
            return value.item.count;
        }
    };
    var value: U = .{ .item = .{ .count = 15 } };
    var executions: usize = 0;
    const count = Reader.run(value, block: {
        value.item.count = 17;
        break :block &executions;
    });
    return Result(count, value.item.count, executions);
}

pub fn pointer_argument_alias() type {
    const Reader = struct {
        fn run(value: *const U, executions: *usize) usize {
            executions.* += 1;
            return value.item.count;
        }
    };
    var value: U = .{ .item = .{ .count = 19 } };
    var executions: usize = 0;
    const count = Reader.run(&value, block: {
        value.item.count = 21;
        break :block &executions;
    });
    return Result(count, value.item.count, executions);
}

pub fn returned_payload_control_flow() type {
    const Producer = struct {
        fn run(executions: *usize, selected: bool) U {
            executions.* += 1;
            return if (selected) .{ .item = .{ .count = 23 } } else .empty;
        }
    };
    var executions: usize = 0;
    const value = Producer.run(&executions, true);
    const count = switch (value) {
        .item => |item| item.count,
        .empty => 0,
    };
    return Result(count, executions, @intFromBool(@TypeOf(value.item) == Item));
}

pub fn global_typeof_payload_call() type {
    const T = @TypeOf(identity(.{ .item = .{ .count = 3 } }));
    return Result(@intFromBool(T == U), @intFromBool(@FieldType(T, "item") == Item), 0);
}

pub fn optional_null_payload() type {
    const OptionalU = @Union(.auto, Tag, &.{ "item", "empty" }, &.{ ?Item, void }, &.{ .{}, .{} });
    const Reader = struct {
        fn run(value: OptionalU) bool {
            return value.item == null and @TypeOf(value.item) == ?Item;
        }
    };
    var marker: usize = 0;
    marker += 1;
    const empty = Reader.run(.{ .item = null });
    return Result(@intFromBool(empty), marker, 0);
}

pub fn named_payload_across_scopes() type {
    const Reader = struct {
        fn run(value: U) usize {
            return value.item.count;
        }
    };
    var marker: usize = 0;
    marker += 1;
    const original = Item{ .count = 29 };
    const same: Item = original;
    const result = Reader.run(.{ .item = same });
    return Result(result, marker, @intFromBool(@TypeOf(same) == Item));
}

pub fn pointer_qualifier_payload() type {
    const PointerU = @Union(.auto, Tag, &.{ "item", "empty" }, &.{ *const Item, void }, &.{ .{}, .{} });
    const Reader = struct {
        fn run(value: PointerU) usize {
            return value.item.count;
        }
    };
    var original = Item{ .count = 31 };
    const value = Reader.run(.{ .item = &original });
    return Result(value, original.count, 0);
}

pub fn wrapped_same_type_payload() type {
    const OptionalU = @Union(.auto, Tag, &.{ "item", "empty" }, &.{ ?Item, void }, &.{ .{}, .{} });
    const Reader = struct {
        fn run(value: OptionalU) usize {
            return value.item.?.count;
        }
    };
    var marker: usize = 0;
    marker += 1;
    const original: ?Item = .{ .count = 35 };
    return Result(Reader.run(.{ .item = original }), marker, 0);
}
