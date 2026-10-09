//! Mutable comptime storage. Values leaving a cell are immutable snapshots;
//! consecutive element stores can reuse backing storage until it is observed.
const Cell = @This();
const Analyser = @import("../analysis.zig");
const Type = Analyser.Type;
const Value = @import("comptime.zig").Value;

/// Borrow only while inspecting storage or selecting an immutable child.
/// Use snapshot when the complete value can escape to another expression.
value: Type,
owned_array: ?[]Type = null,

pub fn snapshot(self: *Cell) Type {
    self.owned_array = null;
    return self.value;
}

pub fn replace(self: *Cell, value: Type) void {
    self.owned_array = null;
    self.value = value;
}

pub fn replaceElement(self: *Cell, analyser: *Analyser, index: usize, value: Type) error{OutOfMemory}!void {
    const current = self.value.data.comptime_value;
    const items = self.owned_array orelse blk: {
        const copy = try analyser.arena.dupe(Type, current.data.array);
        // Allocate the wrapper before changing either the cell or its elements.
        const result = try Value.create(analyser, current.ty, .{ .array = copy });
        self.value = result;
        self.owned_array = copy;
        break :blk copy;
    };
    items[index] = value;
}
