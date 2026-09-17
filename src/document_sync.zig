const std = @import("std");
const types = @import("lsp").types;

const ContentChangeField = enum { range, range_length, text, unknown };

pub const ContentChanges = struct {
    items: []const types.TextDocument.ContentChangeEvent,

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!ContentChanges {
        if (try source.next() != .array_begin) return error.UnexpectedToken;

        var items: std.ArrayList(types.TextDocument.ContentChangeEvent) = .empty;
        errdefer items.deinit(allocator);
        while (try source.peekNextTokenType() != .array_end) {
            try items.append(allocator, try parseContentChange(allocator, source, options));
        }
        std.debug.assert(try source.next() == .array_end);
        return .{ .items = try items.toOwnedSlice(allocator) };
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) std.json.ParseFromValueError!ContentChanges {
        return .{ .items = try std.json.parseFromValueLeaky(
            []const types.TextDocument.ContentChangeEvent,
            allocator,
            source,
            options,
        ) };
    }

    pub fn jsonStringify(changes: ContentChanges, stream: anytype) @TypeOf(stream.*).Error!void {
        try stream.write(changes.items);
    }
};

pub const DidChangeParams = struct {
    textDocument: types.TextDocument.Identifier.Versioned,
    contentChanges: ContentChanges,

    pub fn toLsp(params: DidChangeParams) types.TextDocument.DidChangeParams {
        return .{
            .textDocument = params.textDocument,
            .contentChanges = params.contentChanges.items,
        };
    }
};

fn parseContentChange(
    allocator: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) std.json.ParseError(@TypeOf(source.*))!types.TextDocument.ContentChangeEvent {
    if (try source.next() != .object_begin) return error.UnexpectedToken;

    var range: ?types.Range = null;
    var range_length: ?u32 = null;
    var text: ?[]const u8 = null;
    var saw_range = false;
    var saw_range_length = false;
    var saw_text = false;

    while (true) {
        const field_token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        const field = switch (field_token) {
            .string, .allocated_string => |field| field,
            .object_end => break,
            else => return error.UnexpectedToken,
        };
        const field_kind: ContentChangeField = if (std.mem.eql(u8, field, "range"))
            .range
        else if (std.mem.eql(u8, field, "rangeLength"))
            .range_length
        else if (std.mem.eql(u8, field, "text"))
            .text
        else
            .unknown;
        switch (field_token) {
            .allocated_string => |allocated| allocator.free(allocated),
            else => {},
        }

        switch (field_kind) {
            .range => {
                if (saw_range) return error.DuplicateField;
                saw_range = true;
                range = try std.json.innerParse(?types.Range, allocator, source, options);
            },
            .range_length => {
                if (saw_range_length) return error.DuplicateField;
                saw_range_length = true;
                range_length = try std.json.innerParse(?u32, allocator, source, options);
            },
            .text => {
                if (saw_text) return error.DuplicateField;
                saw_text = true;
                text = try std.json.innerParse([]const u8, allocator, source, options);
            },
            .unknown => if (options.ignore_unknown_fields) {
                try source.skipValue();
            } else {
                return error.UnexpectedToken;
            },
        }
    }

    const parsed_text = text orelse return error.UnexpectedToken;
    if (range) |parsed_range| {
        return .{ .text_document_content_change_partial = .{
            .range = parsed_range,
            .rangeLength = range_length,
            .text = parsed_text,
        } };
    }
    if (!options.ignore_unknown_fields and (saw_range or saw_range_length)) return error.UnexpectedToken;
    return .{ .text_document_content_change_whole_document = .{ .text = parsed_text } };
}

test ContentChanges {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    const json =
        "[{\"text\":\"whole\"},{\"text\":\"partial\",\"rangeLength\":2,\"range\":{\"start\":{\"line\":1,\"character\":2},\"end\":{\"line\":3,\"character\":4}},\"ignored\":true},{\"range\":null,\"text\":\"whole-null\"}]";
    const parsed = try std.json.parseFromSliceLeaky(
        ContentChanges,
        arena.allocator(),
        json,
        .{ .ignore_unknown_fields = true },
    );
    const expected = try std.json.parseFromSliceLeaky(
        []const types.TextDocument.ContentChangeEvent,
        arena.allocator(),
        json,
        .{ .ignore_unknown_fields = true },
    );

    try std.testing.expectEqual(@as(usize, 3), parsed.items.len);
    try std.testing.expectEqualStrings("whole", parsed.items[0].text_document_content_change_whole_document.text);
    const partial = parsed.items[1].text_document_content_change_partial;
    try std.testing.expectEqual(types.Position{ .line = 1, .character = 2 }, partial.range.start);
    try std.testing.expectEqual(types.Position{ .line = 3, .character = 4 }, partial.range.end);
    try std.testing.expectEqual(@as(?u32, 2), partial.rangeLength);
    try std.testing.expectEqualStrings("partial", partial.text);
    try std.testing.expectEqualStrings("whole-null", parsed.items[2].text_document_content_change_whole_document.text);

    const actual_json = try std.json.Stringify.valueAlloc(allocator, parsed.items, .{ .emit_null_optional_fields = false });
    defer allocator.free(actual_json);
    const expected_json = try std.json.Stringify.valueAlloc(allocator, expected, .{ .emit_null_optional_fields = false });
    defer allocator.free(expected_json);
    try std.testing.expectEqualStrings(expected_json, actual_json);
}

test "ContentChanges rejects malformed fields" {
    inline for (.{
        .{ error.UnexpectedToken, "[{}]" },
        .{ error.DuplicateField, "[{\"text\":\"a\",\"text\":\"b\"}]" },
        .{ error.UnexpectedToken, "[{\"text\":\"a\",\"range\":null}]" },
        .{ error.UnexpectedToken, "[{\"text\":\"a\",\"rangeLength\":2}]" },
        .{ error.UnexpectedToken, "[{\"text\":\"a\",\"unknown\":true}]" },
    }) |case| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(case[0], std.json.parseFromSliceLeaky(ContentChanges, arena.allocator(), case[1], .{}));
    }
}

test "DidChangeParams integrates with Message field ordering" {
    const lsp = @import("lsp");
    const RequestParams = union(enum) { other: lsp.MethodWithParams };
    const NotificationParams = union(enum) {
        @"textDocument/didChange": DidChangeParams,
        other: lsp.MethodWithParams,
    };
    const Message = lsp.Message(RequestParams, NotificationParams, .{});
    const cases = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"file:///a.zig\",\"version\":2},\"contentChanges\":[{\"text\":\"next\"}]}}",
        "{\"params\":{\"contentChanges\":[{\"range\":{\"end\":{\"character\":4,\"line\":3},\"start\":{\"character\":2,\"line\":1}},\"text\":\"xy\"}],\"textDocument\":{\"version\":3,\"uri\":\"file:///b.zig\"}},\"method\":\"textDocument/didChange\",\"jsonrpc\":\"2.0\"}",
    };

    for (cases) |json| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const message = try Message.parseFromSliceLeaky(arena.allocator(), json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        const params = message.notification.params.@"textDocument/didChange".toLsp();
        try std.testing.expectEqual(@as(usize, 1), params.contentChanges.len);
    }
}

test "ContentChanges handles every allocation failure" {
    const testParse = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var arena: std.heap.ArenaAllocator = .init(allocator);
            defer arena.deinit();
            const parsed = try std.json.parseFromSliceLeaky(
                ContentChanges,
                arena.allocator(),
                "[{\"text\":\"whole\"},{\"range\":{\"start\":{\"line\":1,\"character\":2},\"end\":{\"line\":3,\"character\":4}},\"text\":\"partial\"}]",
                .{ .allocate = .alloc_always },
            );
            try std.testing.expectEqual(@as(usize, 2), parsed.items.len);
        }
    }.run;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testParse, .{});
}
