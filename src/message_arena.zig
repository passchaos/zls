const std = @import("std");

const min_preheat_bytes = 64 * 1024;
const max_preheat_bytes = 16 * 1024 * 1024;

/// Pre-size the arena used to parse large document-sync messages. The temporary
/// allocation is immediately released, retaining only the arena's backing node.
/// This preserves independent string ownership while avoiding geometric arena
/// growth during JSON unescaping. A failed preheat is only a missed
/// optimization; normal parsing can still attempt its smaller allocations.
pub fn preheatForMessage(arena: *std.heap.ArenaAllocator, json_message: []const u8) void {
    if (json_message.len < min_preheat_bytes or json_message.len > max_preheat_bytes) return;
    if (!isDocumentSyncMessage(json_message)) return;

    const allocation = arena.allocator().alloc(u8, json_message.len) catch return;
    arena.allocator().free(allocation);
}

fn isDocumentSyncMessage(json_message: []const u8) bool {
    var fixed_buffer: [256]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&fixed_buffer);
    var scanner = std.json.Scanner.initCompleteInput(fixed.allocator(), json_message);
    defer scanner.deinit();
    const allocator = fixed.allocator();
    const max_token_len = 32;

    if ((scanner.next() catch return false) != .object_begin) return false;
    while (true) {
        const field_token = scanner.nextAllocMax(allocator, .alloc_if_needed, max_token_len) catch return false;
        const field = switch (field_token) {
            .string, .allocated_string => |field| field,
            .object_end => return false,
            else => return false,
        };
        defer if (field_token == .allocated_string) allocator.free(@constCast(field));

        if (std.mem.eql(u8, field, "method")) {
            const method_token = scanner.nextAllocMax(allocator, .alloc_if_needed, max_token_len) catch return false;
            const method = switch (method_token) {
                .string, .allocated_string => |method| method,
                else => return false,
            };
            defer if (method_token == .allocated_string) allocator.free(@constCast(method));
            return std.mem.eql(u8, method, "textDocument/didOpen") or
                std.mem.eql(u8, method, "textDocument/didChange");
        }

        // Avoid scanning a potentially huge value when fields arrive in an
        // unusual order. Missing the optimization is always safe.
        if (!std.mem.eql(u8, field, "jsonrpc")) return false;
        const version = switch (scanner.nextAllocMax(allocator, .alloc_if_needed, max_token_len) catch return false) {
            .string => |version| version,
            else => return false,
        };
        if (!std.mem.eql(u8, version, "2.0")) return false;
    }
}

test isDocumentSyncMessage {
    try std.testing.expect(isDocumentSyncMessage("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{}}"));
    try std.testing.expect(isDocumentSyncMessage("{ \"jsonrpc\": \"2.0\", \"method\": \"textDocument/didChange\", \"params\": {} }"));
    try std.testing.expect(!isDocumentSyncMessage("{ \"id\": 1, \"method\": \"textDocument/didChange\", \"params\": {} }"));
    try std.testing.expect(!isDocumentSyncMessage("{\"method\":\"textDocument/didSave\",\"params\":null}"));
    try std.testing.expect(!isDocumentSyncMessage("{\"jsonrpc\":\"1.0\",\"method\":\"textDocument/didOpen\",\"params\":{}}"));
    try std.testing.expect(!isDocumentSyncMessage("{\"jsonrpc\":\"2.0\",\"method\":\"workspace/symbol\",\"params\":{}}"));
    try std.testing.expect(!isDocumentSyncMessage("{\"params\":{\"method\":\"textDocument/didOpen\"},\"method\":\"textDocument/didOpen\"}"));
    try std.testing.expect(!isDocumentSyncMessage("not json"));
}

test preheatForMessage {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    preheatForMessage(&arena, "{\"method\":\"textDocument/didOpen\"}");
    try std.testing.expectEqual(@as(usize, 0), arena.queryCapacity());

    const below_threshold = try std.testing.allocator.alloc(u8, min_preheat_bytes - 1);
    defer std.testing.allocator.free(below_threshold);
    @memset(below_threshold, ' ');
    const prefix = "{\"method\":\"textDocument/didOpen\",\"params\":null}";
    @memcpy(below_threshold[0..prefix.len], prefix);
    preheatForMessage(&arena, below_threshold);
    try std.testing.expectEqual(@as(usize, 0), arena.queryCapacity());

    const message = try std.testing.allocator.alloc(u8, min_preheat_bytes);
    defer std.testing.allocator.free(message);
    @memset(message, ' ');
    @memcpy(message[0..prefix.len], prefix);
    preheatForMessage(&arena, message);
    try std.testing.expect(arena.queryCapacity() >= message.len);

    var change_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer change_arena.deinit();
    const change_message = try std.testing.allocator.alloc(u8, min_preheat_bytes);
    defer std.testing.allocator.free(change_message);
    @memset(change_message, ' ');
    const change_prefix = "{\"method\":\"textDocument/didChange\",\"params\":null}";
    @memcpy(change_message[0..change_prefix.len], change_prefix);
    preheatForMessage(&change_arena, change_message);
    try std.testing.expect(change_arena.queryCapacity() >= change_message.len);

    var unrelated_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer unrelated_arena.deinit();
    const unrelated = try std.testing.allocator.alloc(u8, min_preheat_bytes);
    defer std.testing.allocator.free(unrelated);
    @memset(unrelated, ' ');
    const unrelated_prefix = "{\"method\":\"workspace/symbol\",\"params\":null}";
    @memcpy(unrelated[0..unrelated_prefix.len], unrelated_prefix);
    preheatForMessage(&unrelated_arena, unrelated);
    try std.testing.expectEqual(@as(usize, 0), unrelated_arena.queryCapacity());

    var oversized_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer oversized_arena.deinit();
    const oversized = try std.testing.allocator.alloc(u8, max_preheat_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, ' ');
    @memcpy(oversized[0..prefix.len], prefix);
    preheatForMessage(&oversized_arena, oversized);
    try std.testing.expectEqual(@as(usize, 0), oversized_arena.queryCapacity());
}
