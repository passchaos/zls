//! Mutable comptime storage. Each owned node is private to this cell until a
//! snapshot of it (or an ancestor) escapes. Writes then copy just that path.
const Cell = @This();
const std = @import("std");
const Analyser = @import("../analysis.zig");
const Type = Analyser.Type;
const Value = @import("comptime.zig").Value;
const Access = Value.Reference.Access;

/// Borrow only while inspecting storage. Freeze the relevant path before
/// returning a value whose backing storage can escape to another expression.
value: Type,
owned: ?*Owned = null,

pub fn snapshot(self: *Cell) Type {
    self.owned = null;
    return self.value;
}

pub fn freezePath(self: *Cell, path: []const Access) void {
    if (path.len == 0) {
        self.owned = null;
        return;
    }
    var node = self.owned orelse return;
    for (path, 0..) |access, depth| {
        const index = node.indexOf(access) orelse return;
        if (depth == path.len - 1) {
            _ = node.children.remove(index);
            return;
        }
        node = node.children.get(index) orelse return;
    }
}

pub fn replace(self: *Cell, value: Type) void {
    self.owned = null;
    self.value = value;
}

/// The replacement has already been coerced. A false result requests the
/// interpreter's fallback for values not yet materialized as aggregates.
pub fn writePath(self: *Cell, analyser: *Analyser, path: []const Access, value: Type) error{OutOfMemory}!bool {
    std.debug.assert(path.len != 0);
    var node = self.owned orelse blk: {
        const copy = try Owned.clone(analyser, self.value) orelse return false;
        self.owned = copy;
        self.value = copy.asType();
        break :blk copy;
    };
    for (path, 0..) |access, depth| {
        const index = node.indexOf(access) orelse return false;
        const slot = node.child(index);
        if (depth == path.len - 1) {
            _ = node.children.remove(index);
            slot.* = value;
            return true;
        }
        node = node.children.get(index) orelse blk: {
            const copy = try Owned.clone(analyser, slot.*) orelse return false;
            try node.children.put(analyser.arena, index, copy);
            slot.* = copy.asType();
            break :blk copy;
        };
    }
    unreachable;
}

const Owned = struct {
    value: *Value,
    data: union(enum) { array: []Type, fields: []Value.Field, wrapper },
    children: std.AutoHashMapUnmanaged(usize, *Owned) = .empty,

    fn clone(analyser: *Analyser, current: Type) error{OutOfMemory}!?*Owned {
        if (current.data != .comptime_value) return null;
        var copy = current.data.comptime_value.*;
        const data: @FieldType(Owned, "data") = switch (copy.data) {
            .array => |items| blk: {
                const values = try analyser.arena.dupe(Type, items);
                copy.data = .{ .array = values };
                break :blk .{ .array = values };
            },
            .fields => |fields| blk: {
                const values = try analyser.arena.dupe(Value.Field, fields);
                copy.data = .{ .fields = values };
                break :blk .{ .fields = values };
            },
            .optional => |payload| if (payload != null) .wrapper else return null,
            .error_union => |result| if (result == .payload) .wrapper else return null,
            else => return null,
        };
        const value = try analyser.arena.create(Value);
        value.* = copy;
        const node = try analyser.arena.create(Owned);
        node.* = .{ .value = value, .data = data };
        return node;
    }

    fn asType(self: *Owned) Type {
        return .{ .data = .{ .comptime_value = self.value }, .is_type_val = false };
    }

    fn indexOf(self: *Owned, access: Access) ?usize {
        return switch (access) {
            .index, .tuple_index => |index| if (self.data == .array and index < self.data.array.len) index else null,
            .field => |name| self.value.fieldIndex(name),
            .optional_payload => if (self.value.data == .optional and self.value.data.optional != null) 0 else null,
            .error_union_payload => if (self.value.data == .error_union and self.value.data.error_union == .payload) 0 else null,
        };
    }

    fn child(self: *Owned, index: usize) *Type {
        return switch (self.data) {
            .array => |items| &items[index],
            .fields => |fields| &fields[index].value,
            .wrapper => switch (self.value.data) {
                .optional => |*payload| &payload.*.?,
                .error_union => |*result| &result.payload,
                else => unreachable,
            },
        };
    }
};
