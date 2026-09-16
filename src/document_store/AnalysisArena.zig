//! Optional bulk-owned storage for a document's AST and derived indexes.
const std = @import("std");

const AnalysisArena = @This();

arena: ?*std.heap.ArenaAllocator = null,

pub const none: AnalysisArena = .{};

pub fn init(
    owner_allocator: std.mem.Allocator,
    backing_allocator: ?std.mem.Allocator,
) error{OutOfMemory}!AnalysisArena {
    const backing = backing_allocator orelse return .none;
    const arena = try owner_allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(backing);
    return .{ .arena = arena };
}

pub fn allocator(self: AnalysisArena, fallback: std.mem.Allocator) std.mem.Allocator {
    return if (self.arena) |arena| arena.allocator() else fallback;
}

pub fn isActive(self: AnalysisArena) bool {
    return self.arena != null;
}

pub fn sameStorage(a: AnalysisArena, b: AnalysisArena) bool {
    return a.arena == b.arena;
}

pub fn deinit(self: *AnalysisArena, owner_allocator: std.mem.Allocator) void {
    const arena = self.arena orelse {
        self.* = undefined;
        return;
    };
    arena.deinit();
    owner_allocator.destroy(arena);
    self.* = undefined;
}

test "optional arena ownership" {
    var none_instance: AnalysisArena = try .init(std.testing.allocator, null);
    try std.testing.expect(!none_instance.isActive());
    try std.testing.expectEqual(std.testing.allocator, none_instance.allocator(std.testing.allocator));
    none_instance.deinit(std.testing.allocator);

    var arena_instance: AnalysisArena = try .init(std.testing.allocator, std.testing.allocator);
    defer arena_instance.deinit(std.testing.allocator);
    try std.testing.expect(arena_instance.isActive());
    try std.testing.expect(arena_instance.sameStorage(arena_instance));
    _ = try arena_instance.allocator(std.testing.allocator).alloc(u8, 1024);
}
