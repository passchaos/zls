//! Keys and binding comparisons for context-dependent analyser caches.
const std = @import("std");
const Analyser = @import("../analysis.zig");
const DocumentStore = @import("../DocumentStore.zig");
const Uri = @import("../Uri.zig");
const Type = Analyser.Type;
const NodeWithUri = Analyser.NodeWithUri;
const TokenWithHandle = Analyser.TokenWithHandle;
const TokenToTypeMap = Analyser.TokenToTypeMap;
const TokenToNodeMap = Analyser.TokenToNodeMap;

pub fn hashTypeBindings(hasher: anytype, bindings: TokenToTypeMap) void {
    var bindings_hash: u64 = 0;
    for (bindings.keys(), bindings.values()) |token_handle, ty| {
        var binding_hasher: std.hash.Wyhash = .init(0);
        token_handle.hashWithHasher(&binding_hasher);
        ty.hashWithHasher(&binding_hasher);
        bindings_hash ^= binding_hasher.final();
    }
    std.hash.autoHash(hasher, bindings.count());
    std.hash.autoHash(hasher, bindings_hash);
}

/// Exact representation comparison also preserves navigation and presentation
/// metadata that semantic Type.eql intentionally ignores.
pub fn bindingOverlayChanges(outer: anytype, overlay: @TypeOf(outer)) bool {
    for (overlay.keys(), overlay.values()) |key, value| {
        const existing = outer.get(key) orelse return true;
        if (!std.meta.eql(existing, value)) return true;
    }
    return false;
}

test "generic binding overlays preserve exact values and navigation metadata" {
    const allocator = std.testing.allocator;
    var handle: DocumentStore.Handle = undefined;
    handle.uri = try Uri.parse(allocator, "file:///bindings.zig");
    defer handle.uri.deinit(allocator);
    const token: TokenWithHandle = .{ .handle = &handle, .token = 0 };
    var string_type: Type = .{ .is_type_val = true, .data = .{ .ip_index = .{ .type = .type_type, .index = .u8_type } } };
    const first: Type = .{ .is_type_val = false, .data = .{ .string_value = .{
        .string_type = &string_type,
        .bytes = "field",
        .source = token,
    } } };
    var second = first;
    second.data.string_value.source.?.token = 1;
    try std.testing.expect(first.eql(second));
    var outer: TokenToTypeMap = .empty;
    defer outer.deinit(allocator);
    try outer.put(allocator, token, first);
    var overlay = try outer.clone(allocator);
    defer overlay.deinit(allocator);
    try std.testing.expect(!bindingOverlayChanges(outer, overlay));
    try overlay.put(allocator, token, second);
    try std.testing.expect(bindingOverlayChanges(outer, overlay));
    try overlay.put(allocator, .{ .handle = &handle, .token = 2 }, first);
    try std.testing.expect(bindingOverlayChanges(outer, overlay));
}

test "generic container cache hashes ignore binding insertion order" {
    const allocator = std.testing.allocator;
    var handle: DocumentStore.Handle = undefined;
    handle.uri = try Uri.parse(allocator, "file:///bindings.zig");
    defer handle.uri.deinit(allocator);
    const first_token: TokenWithHandle = .{ .handle = &handle, .token = 0 };
    const second_token: TokenWithHandle = .{ .handle = &handle, .token = 1 };
    const u8_type: Type = .{ .is_type_val = true, .data = .{ .ip_index = .{ .type = .type_type, .index = .u8_type } } };
    const u16_type: Type = .{ .is_type_val = true, .data = .{ .ip_index = .{ .type = .type_type, .index = .u16_type } } };
    var forward: TokenToTypeMap = .empty;
    defer forward.deinit(allocator);
    var reverse: TokenToTypeMap = .empty;
    defer reverse.deinit(allocator);
    try forward.put(allocator, first_token, u8_type);
    try forward.put(allocator, second_token, u16_type);
    try reverse.put(allocator, second_token, u16_type);
    try reverse.put(allocator, first_token, u8_type);
    const first_type: Type = .{ .is_type_val = true, .data = .{ .container = .{
        .scope_handle = .{ .handle = &handle, .scope = .root },
        .bound_params = forward,
    } } };
    var second_type = first_type;
    second_type.data.container.bound_params = reverse;
    try std.testing.expect(first_type.eql(second_type));
    try std.testing.expectEqual(first_type.hash64(), second_type.hash64());
    const node: NodeWithUri = .{ .uri = handle.uri, .node = .root };
    const first_key = Key.init(node, first_type, forward, .empty);
    const second_key = Key.init(node, second_type, reverse, .empty);
    try std.testing.expect(Key.Context.eql(.{}, first_key, second_key));
    try std.testing.expectEqual(first_key.hash, second_key.hash);
    var cache: std.HashMapUnmanaged(Key, u8, Key.Context, 80) = .empty;
    defer cache.deinit(allocator);
    try cache.put(allocator, first_key, 42);
    try std.testing.expectEqual(@as(?u8, 42), cache.get(second_key));
    try reverse.put(allocator, second_token, u8_type);
    second_type.data.container.bound_params = reverse;
    const changed_key = Key.init(node, second_type, reverse, .empty);
    try std.testing.expect(!Key.Context.eql(.{}, first_key, changed_key));
    try std.testing.expect(cache.get(changed_key) == null);
    var display: TokenToNodeMap = .empty;
    defer display.deinit(allocator);
    try display.put(allocator, first_token, .of(.root, &handle));
    const display_key = Key.init(node, first_type, forward, display);
    try std.testing.expect(cache.get(display_key) == null);
}

pub fn eqlTypeBindings(a: TokenToTypeMap, b: TokenToTypeMap) bool {
    if (a.count() != b.count()) return false;
    for (a.keys(), a.values()) |token_handle, ty| {
        const other = b.get(token_handle) orelse return false;
        if (!ty.eql(other)) return false;
    }
    return true;
}

pub fn hashDisplayBindings(hasher: anytype, bindings: TokenToNodeMap) void {
    var bindings_hash: u64 = 0;
    for (bindings.keys(), bindings.values()) |token_handle, node_handle| {
        var binding_hasher: std.hash.Wyhash = .init(0);
        token_handle.hashWithHasher(&binding_hasher);
        std.hash.autoHash(&binding_hasher, node_handle.node);
        std.hash.autoHash(&binding_hasher, node_handle.handle.uri.hash());
        bindings_hash ^= binding_hasher.final();
    }
    std.hash.autoHash(hasher, bindings.count());
    std.hash.autoHash(hasher, bindings_hash);
}

pub fn eqlDisplayBindings(a: TokenToNodeMap, b: TokenToNodeMap) bool {
    if (a.count() != b.count()) return false;
    for (a.keys(), a.values()) |token_handle, node_handle| {
        const other = b.get(token_handle) orelse return false;
        if (!node_handle.eql(other)) return false;
    }
    return true;
}

pub const Key = struct {
    node: NodeWithUri,
    container_type: ?Type,
    bindings: TokenToTypeMap,
    display_bindings: TokenToNodeMap,
    hash: u64,

    pub fn init(node: NodeWithUri, container_type: ?Type, bindings: TokenToTypeMap, display_bindings: TokenToNodeMap) Key {
        const key: Key = .{
            .node = node,
            .container_type = container_type,
            .bindings = bindings,
            .display_bindings = display_bindings,
            .hash = undefined,
        };
        var result = key;
        result.hash = result.computeHash();
        return result;
    }

    fn computeHash(key: Key) u64 {
        var hasher: std.hash.Wyhash = .init(0);
        std.hash.autoHash(&hasher, key.node.node);
        std.hash.autoHash(&hasher, key.node.uri.hash());
        if (key.container_type) |container_type| {
            hasher.update(&.{1});
            container_type.hashWithHasher(&hasher);
        } else {
            hasher.update(&.{0});
        }
        hashTypeBindings(&hasher, key.bindings);
        hashDisplayBindings(&hasher, key.display_bindings);
        return hasher.final();
    }

    pub const Context = struct {
        pub fn hash(_: Context, key: Key) u64 {
            return key.hash;
        }

        pub fn eql(_: Context, a: Key, b: Key) bool {
            if (a.node.node != b.node.node or !a.node.uri.eql(b.node.uri)) return false;
            if ((a.container_type == null) != (b.container_type == null)) return false;
            if (a.container_type) |container_type| {
                if (!container_type.eql(b.container_type.?)) return false;
            }
            return eqlTypeBindings(a.bindings, b.bindings) and eqlDisplayBindings(a.display_bindings, b.display_bindings);
        }
    };
};

/// Keep only pointers in the hash table: full binding keys are considerably
/// larger than the pointer and need stable storage only for occupied entries.
pub fn Map(comptime V: type) type {
    return struct {
        table: Table = .empty,

        const Self = @This();
        const PointerContext = struct {
            pub fn hash(_: @This(), key: *const Key) u64 {
                return key.hash;
            }
            pub fn eql(_: @This(), a: *const Key, b: *const Key) bool {
                return a == b or Key.Context.eql(.{}, a.*, b.*);
            }
        };
        const LookupContext = struct {
            pub fn hash(_: @This(), key: Key) u64 {
                return key.hash;
            }
            pub fn eql(_: @This(), a: Key, b: *const Key) bool {
                return Key.Context.eql(.{}, a, b.*);
            }
        };
        const Table = std.HashMapUnmanaged(*const Key, V, PointerContext, 80);

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.table.deinit(allocator);
        }

        pub fn count(self: Self) usize {
            return self.table.count();
        }

        pub fn get(self: Self, key: Key) ?V {
            return self.table.getAdapted(key, LookupContext{});
        }

        pub fn getPtr(self: Self, key: Key) ?*V {
            return self.table.getPtrAdapted(key, LookupContext{});
        }

        pub fn remove(self: *Self, key: Key) bool {
            return self.table.removeAdapted(key, LookupContext{});
        }

        pub fn getOrPut(self: *Self, allocator: std.mem.Allocator, arena: std.mem.Allocator, key: Key) error{OutOfMemory}!struct { value_ptr: *V, found_existing: bool } {
            if (self.getPtr(key)) |value_ptr| return .{ .value_ptr = value_ptr, .found_existing = true };
            const snapshot = try arena.create(Key);
            snapshot.* = key;
            snapshot.bindings = try key.bindings.clone(arena);
            snapshot.display_bindings = try key.display_bindings.clone(arena);
            const entry = try self.table.getOrPut(allocator, snapshot);
            return .{ .value_ptr = entry.value_ptr, .found_existing = entry.found_existing };
        }

        pub fn put(self: *Self, allocator: std.mem.Allocator, arena: std.mem.Allocator, key: Key, value: V) error{OutOfMemory}!void {
            const entry = try self.getOrPut(allocator, arena, key);
            entry.value_ptr.* = value;
        }
    };
}

test "specialization map snapshots bindings and preserves pending entries during growth" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var handle: DocumentStore.Handle = undefined;
    handle.uri = .{ .raw = "file:///snapshot.zig" };
    const token: TokenWithHandle = .{ .handle = &handle, .token = 0 };
    const u8_type: Type = .{ .is_type_val = true, .data = .{ .ip_index = .{ .type = .type_type, .index = .u8_type } } };
    const u16_type: Type = .{ .is_type_val = true, .data = .{ .ip_index = .{ .type = .type_type, .index = .u16_type } } };
    var bindings: TokenToTypeMap = .empty;
    try bindings.put(arena.allocator(), token, u8_type);
    var display: TokenToNodeMap = .empty;
    try display.put(arena.allocator(), token, .of(.root, &handle));
    const original_bindings = try bindings.clone(arena.allocator());
    const original_display = try display.clone(arena.allocator());
    const node: NodeWithUri = .{ .uri = handle.uri, .node = .root };
    const original = Key.init(node, null, original_bindings, original_display);
    var cache: Map(?u8) = .{};
    defer cache.deinit(allocator);
    const pending = try cache.getOrPut(allocator, arena.allocator(), Key.init(node, null, bindings, display));
    try std.testing.expect(!pending.found_existing);
    pending.value_ptr.* = null;
    try bindings.put(arena.allocator(), token, u16_type);
    try display.put(arena.allocator(), token, .of(@enumFromInt(1), &handle));
    const changed = Key.init(node, null, bindings, display);
    try std.testing.expect(cache.getPtr(changed) == null);
    for (1..100) |index| {
        try cache.put(allocator, arena.allocator(), Key.init(.{
            .uri = handle.uri,
            .node = @enumFromInt(index),
        }, null, bindings, display), 7);
    }
    try std.testing.expectEqual(@as(usize, 100), cache.count());
    try std.testing.expect(cache.getPtr(original) != null);
    try std.testing.expect(cache.getPtr(original).?.* == null);
    cache.getPtr(original).?.* = 42;
    const found = try cache.getOrPut(allocator, arena.allocator(), original);
    try std.testing.expect(found.found_existing);
    try std.testing.expectEqual(@as(?u8, 42), found.value_ptr.*);
    try std.testing.expectEqual(@as(usize, 100), cache.count());
    try std.testing.expect(cache.remove(original));
    try std.testing.expect(cache.getPtr(original) == null);
}
