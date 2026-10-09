//! Field names are immutable within a materialized value. Wide values share
//! this index across copies; small values retain allocation-free linear lookup.
const std = @import("std");
const Index = @This();

names: std.StringHashMapUnmanaged(usize) = .empty,
pub const minimum_fields = 16;

pub fn create(allocator: std.mem.Allocator, fields: anytype) error{OutOfMemory}!?*const Index {
    if (fields.len < minimum_fields) return null;
    const index = try allocator.create(Index);
    errdefer allocator.destroy(index);
    index.* = .{};
    errdefer index.names.deinit(allocator);
    try index.names.ensureTotalCapacity(allocator, @intCast(fields.len));
    for (fields, 0..) |field, position| {
        // Match the first entry on malformed input, just like linear lookup.
        const entry = index.names.getOrPutAssumeCapacity(field.name);
        if (!entry.found_existing) entry.value_ptr.* = position;
    }
    return index;
}

pub fn lookup(index: ?*const Index, fields: anytype, name: []const u8) ?usize {
    if (index) |indexed| return indexed.names.get(name);
    for (fields, 0..) |field, position| {
        if (std.mem.eql(u8, field.name, name)) return position;
    }
    return null;
}
