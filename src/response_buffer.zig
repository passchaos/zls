const std = @import("std");
const types = @import("lsp").types;

const stack_buffer_size = 4096;

/// Serialize a JSON value into caller-owned memory while keeping the initial
/// output growth on the stack. Responses larger than the stack buffer transfer
/// directly to the fallback allocator; smaller responses need one final copy
/// into caller-owned memory.
pub fn stringifyAlloc(
    allocator: std.mem.Allocator,
    value: anytype,
    options: std.json.Stringify.Options,
) error{OutOfMemory}![]u8 {
    return stringifyAllocCapacity(allocator, value, options, 0);
}

pub fn stringifyAllocCapacity(
    allocator: std.mem.Allocator,
    value: anytype,
    options: std.json.Stringify.Options,
    initial_capacity: usize,
) error{OutOfMemory}![]u8 {
    if (initial_capacity > stack_buffer_size) {
        var output: std.Io.Writer.Allocating = try .initCapacity(allocator, initial_capacity);
        defer output.deinit();
        std.json.Stringify.value(value, options, &output.writer) catch return error.OutOfMemory;
        return output.toOwnedSlice();
    }

    var stack_allocator = std.heap.stackFallback(stack_buffer_size, allocator);
    const temporary_allocator = stack_allocator.get();
    const stringified = try std.json.Stringify.valueAlloc(temporary_allocator, value, options);

    if (!stack_allocator.fixed_buffer_allocator.ownsSlice(stringified)) return stringified;
    defer temporary_allocator.free(stringified);
    return try allocator.dupe(u8, stringified);
}

pub fn workspaceSymbolCapacityHint(result: ?types.workspace.Symbol.Result) usize {
    const symbol_result = result orelse return 0;
    var capacity: usize = 64;
    switch (symbol_result) {
        .workspace_symbols => |symbols| for (symbols) |symbol| {
            const uri = switch (symbol.location) {
                .location => |location| location.uri,
                .location_uri_only => |location| location.uri,
            };
            capacity +|= 128 +| symbol.name.len +| uri.len;
        },
        .symbol_informations => |symbols| for (symbols) |symbol| {
            capacity +|= 128 +| symbol.name.len +| symbol.location.uri.len;
        },
    }
    return capacity;
}

pub fn responseCapacityHint(result: anytype) usize {
    const Result = @TypeOf(result);
    if (Result == ?types.workspace.Symbol.Result) {
        return workspaceSymbolCapacityHint(result);
    }
    if (Result == ?[]types.Location) {
        const locations = result orelse return 0;
        var capacity: usize = 64;
        for (locations) |location| capacity +|= 96 +| location.uri.len;
        return capacity;
    }
    if (Result == ?[]types.DocumentHighlight) {
        const highlights = result orelse return 0;
        return 64 +| 96 *| highlights.len;
    }
    if (Result == ?types.WorkspaceEdit) {
        const workspace_edit = result orelse return 0;
        const changes = workspace_edit.changes orelse return 0;
        var capacity: usize = 64;
        var iterator = changes.map.iterator();
        while (iterator.next()) |entry| {
            capacity +|= 32 +| entry.key_ptr.*.len;
            for (entry.value_ptr.*) |edit| capacity +|= 96 +| edit.newText.len;
        }
        return capacity;
    }
    return 0;
}

test stringifyAlloc {
    const allocator = std.testing.allocator;

    const small = try stringifyAlloc(allocator, .{ .message = "small" }, .{});
    defer allocator.free(small);
    try std.testing.expectEqualStrings("{\"message\":\"small\"}", small);

    const input = "a" ** (stack_buffer_size * 2);
    const large = try stringifyAlloc(allocator, .{ .message = input }, .{});
    defer allocator.free(large);
    try std.testing.expectEqual(input.len + "{\"message\":\"\"}".len, large.len);

    const hinted = try stringifyAllocCapacity(allocator, .{ .message = input }, .{}, input.len + 64);
    defer allocator.free(hinted);
    try std.testing.expectEqualStrings(large, hinted);

    const underestimated = try stringifyAllocCapacity(allocator, .{ .message = input }, .{}, stack_buffer_size + 1);
    defer allocator.free(underestimated);
    try std.testing.expectEqualStrings(large, underestimated);
}

test workspaceSymbolCapacityHint {
    const uri = "file:///workspace/example.zig";
    const symbols = [_]types.workspace.Symbol{
        .{
            .name = "first",
            .kind = .Function,
            .location = .{ .location = .{
                .uri = uri,
                .range = .{
                    .start = .{ .line = 1, .character = 2 },
                    .end = .{ .line = 1, .character = 7 },
                },
            } },
        },
        .{
            .name = "second",
            .kind = .Variable,
            .location = .{ .location_uri_only = .{ .uri = uri } },
        },
    };
    const result: types.workspace.Symbol.Result = .{ .workspace_symbols = &symbols };
    try std.testing.expectEqual(
        64 + 128 + "first".len + uri.len + 128 + "second".len + uri.len,
        workspaceSymbolCapacityHint(result),
    );
    const symbol_information = [_]types.SymbolInformation{.{
        .name = "legacy",
        .kind = .Function,
        .location = .{
            .uri = uri,
            .range = .{
                .start = .{ .line = 0, .character = 0 },
                .end = .{ .line = 0, .character = 6 },
            },
        },
    }};
    try std.testing.expectEqual(
        64 + 128 + "legacy".len + uri.len,
        workspaceSymbolCapacityHint(.{ .symbol_informations = &symbol_information }),
    );
    try std.testing.expectEqual(0, workspaceSymbolCapacityHint(null));
    try std.testing.expectEqual(64, workspaceSymbolCapacityHint(.{ .symbol_informations = &.{} }));
}

test "response capacity hints" {
    const allocator = std.testing.allocator;
    const uri = "file:///workspace/example.zig";
    const locations = [_]types.Location{.{
        .uri = uri,
        .range = .{
            .start = .{ .line = 1, .character = 2 },
            .end = .{ .line = 1, .character = 7 },
        },
    }};
    const highlights = [_]types.DocumentHighlight{.{
        .range = locations[0].range,
        .kind = .Text,
    }};

    try std.testing.expect(responseCapacityHint(@as(?[]types.Location, @constCast(&locations))) > uri.len);
    try std.testing.expect(responseCapacityHint(@as(?[]types.DocumentHighlight, @constCast(&highlights))) > 64);

    const edits = [_]types.TextEdit{.{
        .range = locations[0].range,
        .newText = "replacement",
    }};
    var workspace_edit: types.WorkspaceEdit = .{ .changes = .{} };
    defer workspace_edit.changes.?.map.deinit(allocator);
    try workspace_edit.changes.?.map.putNoClobber(allocator, uri, &edits);
    try std.testing.expect(responseCapacityHint(@as(?types.WorkspaceEdit, workspace_edit)) > uri.len + edits[0].newText.len);

    try std.testing.expectEqual(0, responseCapacityHint(@as(?[]types.Location, null)));
    try std.testing.expectEqual(0, responseCapacityHint(@as(?types.WorkspaceEdit, null)));
}

test "workspace symbol result representations serialize identically" {
    const allocator = std.testing.allocator;
    const uri = "file:///workspace/example.zig";
    const location: types.Location = .{
        .uri = uri,
        .range = .{
            .start = .{ .line = 123, .character = 45 },
            .end = .{ .line = 123, .character = 51 },
        },
    };
    const workspace_symbols = [_]types.workspace.Symbol{.{
        .name = "symbol",
        .kind = .Function,
        .location = .{ .location = location },
    }};
    const symbol_informations = [_]types.SymbolInformation{.{
        .name = "symbol",
        .kind = .Function,
        .location = location,
    }};

    const workspace_json = try stringifyAlloc(allocator, types.workspace.Symbol.Result{ .workspace_symbols = &workspace_symbols }, .{
        .emit_null_optional_fields = false,
    });
    defer allocator.free(workspace_json);
    const information_json = try stringifyAlloc(allocator, types.workspace.Symbol.Result{ .symbol_informations = &symbol_informations }, .{
        .emit_null_optional_fields = false,
    });
    defer allocator.free(information_json);

    try std.testing.expectEqualStrings(workspace_json, information_json);
    try std.testing.expect(@sizeOf(types.SymbolInformation) < @sizeOf(types.workspace.Symbol));
}
