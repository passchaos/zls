//! Text diffing between source files.

const std = @import("std");
const types = @import("lsp").types;
const offsets = @import("offsets.zig");
const tracy = @import("tracy");
const DiffMatchPatch = @import("diffz");

pub fn edits(
    io: std.Io,
    allocator: std.mem.Allocator,
    before: []const u8,
    after: []const u8,
    encoding: offsets.Encoding,
) error{OutOfMemory}!std.ArrayList(types.TextEdit) {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const dmp: DiffMatchPatch = .initDefault(io, allocator);
    var diffs = try dmp.diff(
        before,
        after,
        true,
        .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(250) } },
    );
    defer DiffMatchPatch.deinitDiffList(allocator, &diffs);

    var edit_count: usize = 0;
    for (diffs.items) |diff| {
        switch (diff.operation) {
            .delete => edit_count += 1,
            .equal => continue,
            .insert => edit_count += 1,
        }
    }

    var eds: std.ArrayList(types.TextEdit) = try .initCapacity(allocator, edit_count);
    errdefer {
        for (eds.items) |edit| allocator.free(edit.newText);
        eds.deinit(allocator);
    }

    var offset: usize = 0;
    for (diffs.items) |diff| {
        const start = offset;
        switch (diff.operation) {
            .delete => {
                offset += diff.text.len;
                eds.appendAssumeCapacity(.{
                    .range = offsets.locToRange(before, .{ .start = start, .end = offset }, encoding),
                    .newText = "",
                });
            },
            .equal => {
                offset += diff.text.len;
            },
            .insert => {
                eds.appendAssumeCapacity(.{
                    .range = offsets.locToRange(before, .{ .start = start, .end = start }, encoding),
                    .newText = try allocator.dupe(u8, diff.text),
                });
            },
        }
    }
    return eds;
}

/// Caller owns returned memory.
pub fn applyContentChanges(
    allocator: std.mem.Allocator,
    text: []const u8,
    content_changes: []const types.TextDocument.ContentChangeEvent,
    encoding: offsets.Encoding,
) error{OutOfMemory}![:0]const u8 {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const last_full_text_index, const last_full_text = blk: {
        var i: usize = content_changes.len;
        while (i != 0) {
            i -= 1;
            switch (content_changes[i]) {
                .text_document_content_change_whole_document => |content_change| break :blk .{ i, content_change.text },
                .text_document_content_change_partial => continue,
            }
        }
        break :blk .{ null, text };
    };
    if (last_full_text_index) |index| {
        if (index + 1 == content_changes.len) {
            return try allocator.dupeSentinel(u8, last_full_text, 0);
        }
    }

    var text_array: std.ArrayList(u8) = .empty;
    errdefer text_array.deinit(allocator);

    try text_array.appendSlice(allocator, last_full_text);

    // don't even bother applying changes before a full text change
    const changes = content_changes[if (last_full_text_index) |index| index + 1 else 0..];
    var cursor: PositionToIndexCursor = .{};

    for (changes) |item| {
        const content_change = item.text_document_content_change_partial;

        const edit = cursor.rangeToLoc(text_array.items, content_change.range, encoding);
        try text_array.replaceRange(allocator, edit.loc.start, edit.loc.end - edit.loc.start, content_change.text);
        cursor.index = edit.loc.start + content_change.text.len;
        cursor.position = offsets.advancePosition(
            content_change.text,
            edit.start_position,
            0,
            content_change.text.len,
            encoding,
        );
    }

    return try text_array.toOwnedSliceSentinel(allocator, 0);
}

const PositionToIndexCursor = struct {
    index: usize = 0,
    position: offsets.Position = .{ .line = 0, .character = 0 },

    const ResolvedRange = struct {
        loc: offsets.Loc,
        start_position: offsets.Position,
    };

    fn rangeToLoc(cursor: *PositionToIndexCursor, text: []const u8, range: offsets.Range, encoding: offsets.Encoding) ResolvedRange {
        std.debug.assert(offsets.orderPosition(range.start, range.end) != .gt);
        const start = cursor.seek(text, range.start, encoding);
        const start_position = cursor.position;
        const end = cursor.advance(text, .{
            .line = range.end.line - range.start.line,
            .character = if (range.start.line == range.end.line)
                range.end.character - range.start.character
            else
                range.end.character,
        }, encoding);
        return .{ .loc = .{ .start = start, .end = end }, .start_position = start_position };
    }

    fn seek(cursor: *PositionToIndexCursor, text: []const u8, target: offsets.Position, encoding: offsets.Encoding) usize {
        if (offsets.orderPosition(target, cursor.position) == .lt) cursor.* = .{};

        return cursor.advance(text, .{
            .line = target.line - cursor.position.line,
            .character = if (target.line == cursor.position.line)
                target.character - cursor.position.character
            else
                target.character,
        }, encoding);
    }

    fn advance(cursor: *PositionToIndexCursor, text: []const u8, relative: offsets.Position, encoding: offsets.Encoding) usize {
        var lines_remaining = relative.line;
        while (lines_remaining != 0) : (lines_remaining -= 1) {
            const newline = std.mem.findScalarPos(u8, text, cursor.index, '\n') orelse {
                cursor.position = offsets.advancePosition(text, cursor.position, cursor.index, text.len, encoding);
                cursor.index = text.len;
                return cursor.index;
            };
            cursor.index = newline + 1;
            cursor.position.line += 1;
            cursor.position.character = 0;
        }

        const line = std.mem.sliceTo(text[cursor.index..], '\n');
        const byte_delta = offsets.getNCodeUnitByteCount(line, relative.character, encoding);
        cursor.index += byte_delta;
        cursor.position.character += @intCast(offsets.countCodeUnits(line[0..byte_delta], encoding));
        return cursor.index;
    }
};

test applyContentChanges {
    const allocator = std.testing.allocator;

    const full_change = [_]types.TextDocument.ContentChangeEvent{.{
        .text_document_content_change_whole_document = .{ .text = "replacement" },
    }};
    const replaced = try applyContentChanges(allocator, "old", &full_change, .@"utf-8");
    defer allocator.free(replaced);
    try std.testing.expectEqualStrings("replacement", replaced);
    try std.testing.expect(replaced.ptr != full_change[0].text_document_content_change_whole_document.text.ptr);

    const final_full_change = [_]types.TextDocument.ContentChangeEvent{
        .{ .text_document_content_change_partial = .{
            .range = .{
                .start = .{ .line = 0, .character = 0 },
                .end = .{ .line = 0, .character = 1 },
            },
            .text = "ignored",
        } },
        .{ .text_document_content_change_whole_document = .{ .text = "final" } },
    };
    const final = try applyContentChanges(allocator, "old", &final_full_change, .@"utf-8");
    defer allocator.free(final);
    try std.testing.expectEqualStrings("final", final);

    const mixed_changes = [_]types.TextDocument.ContentChangeEvent{
        .{ .text_document_content_change_partial = .{
            .range = .{
                .start = .{ .line = 0, .character = 0 },
                .end = .{ .line = 0, .character = 1 },
            },
            .text = "ignored",
        } },
        .{ .text_document_content_change_whole_document = .{ .text = "abc" } },
        .{ .text_document_content_change_partial = .{
            .range = .{
                .start = .{ .line = 0, .character = 1 },
                .end = .{ .line = 0, .character = 2 },
            },
            .text = "XY",
        } },
    };
    const mixed = try applyContentChanges(allocator, "old", &mixed_changes, .@"utf-8");
    defer allocator.free(mixed);
    try std.testing.expectEqualStrings("aXYc", mixed);

    const unchanged = try applyContentChanges(allocator, "old", &.{}, .@"utf-8");
    defer allocator.free(unchanged);
    try std.testing.expectEqualStrings("old", unchanged);
}

test "applyContentChanges advances and resets its position cursor" {
    const allocator = std.testing.allocator;
    const changes = [_]types.TextDocument.ContentChangeEvent{
        .{ .text_document_content_change_partial = .{
            .range = .{
                .start = .{ .line = 1, .character = 0 },
                .end = .{ .line = 1, .character = 1 },
            },
            .text = "🠁\nq",
        } },
        .{ .text_document_content_change_partial = .{
            .range = .{
                .start = .{ .line = 2, .character = 1 },
                .end = .{ .line = 2, .character = 2 },
            },
            .text = "X",
        } },
        .{ .text_document_content_change_partial = .{
            .range = .{
                .start = .{ .line = 0, .character = 1 },
                .end = .{ .line = 0, .character = 2 },
            },
            .text = "Y",
        } },
    };

    inline for (.{ offsets.Encoding.@"utf-8", offsets.Encoding.@"utf-16", offsets.Encoding.@"utf-32" }) |encoding| {
        const result = try applyContentChanges(allocator, "ab\ncd\nef", &changes, encoding);
        defer allocator.free(result);
        try std.testing.expectEqualStrings("aY\n🠁\nqX\nef", result);
    }
}

test "PositionToIndexCursor matches rangeToLoc" {
    const text = "a¶↉🠁\r\nsecond line\nthird";
    const ranges = [_]offsets.Range{
        .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } },
        .{ .start = .{ .line = 0, .character = 1 }, .end = .{ .line = 0, .character = 3 } },
        .{ .start = .{ .line = 1, .character = 2 }, .end = .{ .line = 1, .character = 8 } },
        .{ .start = .{ .line = 2, .character = 1 }, .end = .{ .line = 9, .character = 99 } },
        .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 1 } },
    };

    inline for (.{ offsets.Encoding.@"utf-8", offsets.Encoding.@"utf-16", offsets.Encoding.@"utf-32" }) |encoding| {
        var cursor: PositionToIndexCursor = .{};
        for (ranges) |range| {
            try std.testing.expectEqual(
                offsets.rangeToLoc(text, range, encoding),
                cursor.rangeToLoc(text, range, encoding).loc,
            );
        }
    }

    var utf16_cursor: PositionToIndexCursor = .{};
    const split_surrogate_range: offsets.Range = .{
        .start = .{ .line = 0, .character = 1 },
        .end = .{ .line = 0, .character = 2 },
    };
    try std.testing.expectEqual(
        offsets.rangeToLoc("🠁X", split_surrogate_range, .@"utf-16"),
        utf16_cursor.rangeToLoc("🠁X", split_surrogate_range, .@"utf-16").loc,
    );
}

// https://cs.opensource.google/go/x/tools/+/master:internal/lsp/diff/diff.go;l=40

fn textEditLessThan(_: void, lhs: types.TextEdit, rhs: types.TextEdit) bool {
    return offsets.orderPosition(lhs.range.start, rhs.range.start) == .lt or offsets.orderPosition(lhs.range.end, rhs.range.end) == .lt;
}

/// Caller owns returned memory.
pub fn applyTextEdits(
    allocator: std.mem.Allocator,
    text: []const u8,
    text_edits: []const types.TextEdit,
    encoding: offsets.Encoding,
) error{OutOfMemory}![]const u8 {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const text_edits_sortable = try allocator.dupe(types.TextEdit, text_edits);
    defer allocator.free(text_edits_sortable);

    std.mem.sort(types.TextEdit, text_edits_sortable, {}, textEditLessThan);

    var final_text: std.ArrayList(u8) = .empty;
    errdefer final_text.deinit(allocator);

    var last: usize = 0;
    for (text_edits_sortable) |te| {
        const start = offsets.positionToIndex(text, te.range.start, encoding);
        if (start > last) {
            try final_text.appendSlice(allocator, text[last..start]);
            last = start;
        }
        try final_text.appendSlice(allocator, te.newText);
        last = offsets.positionToIndex(text, te.range.end, encoding);
    }
    if (last < text.len) {
        try final_text.appendSlice(allocator, text[last..]);
    }

    return try final_text.toOwnedSlice(allocator);
}
