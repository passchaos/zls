//! Text diffing between source files.

const std = @import("std");
const types = @import("lsp").types;
const offsets = @import("offsets.zig");
const tracy = @import("tracy");
const DiffMatchPatch = @import("diffz");

const max_noop_change_text_len = 64 * 1024;

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
    return try applyContentChangesIfChanged(allocator, text, content_changes, encoding) orelse
        allocator.dupeSentinel(u8, text, 0);
}

/// Returns independently owned changed text, or `null` if the changes provably
/// leave `text` unchanged.
pub fn applyContentChangesIfChanged(
    allocator: std.mem.Allocator,
    text: []const u8,
    content_changes: []const types.TextDocument.ContentChangeEvent,
    encoding: offsets.Encoding,
) error{OutOfMemory}!?[:0]const u8 {
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

    // don't even bother applying changes before a full text change
    const changes = content_changes[if (last_full_text_index) |index| index + 1 else 0..];
    if (changes.len == 0) return null;
    if (changes.len == 1) {
        const change = changes[0].text_document_content_change_partial;
        const loc = offsets.rangeToLoc(last_full_text, change.range, encoding);
        if (last_full_text_index == null and
            change.text.len <= max_noop_change_text_len and
            std.mem.eql(u8, last_full_text[loc.start..loc.end], change.text)) return null;
        const result_len = std.math.add(usize, last_full_text.len - (loc.end - loc.start), change.text.len) catch
            return error.OutOfMemory;
        const result = try allocator.allocSentinel(u8, result_len, 0);
        @memcpy(result[0..loc.start], last_full_text[0..loc.start]);
        @memcpy(result[loc.start..][0..change.text.len], change.text);
        @memcpy(result[loc.start + change.text.len ..], last_full_text[loc.end..]);
        return result;
    }

    var text_array: std.ArrayList(u8) = .empty;
    errdefer text_array.deinit(allocator);

    try text_array.appendSlice(allocator, last_full_text);
    var cursor: PositionToIndexCursor = .{};

    for (changes) |item| {
        const content_change = item.text_document_content_change_partial;

        const edit = cursor.rangeToLoc(text_array.items, content_change.range, encoding);
        const replaced_length = edit.loc.end - edit.loc.start;
        if (replaced_length == content_change.text.len) {
            @memcpy(text_array.items[edit.loc.start..edit.loc.end], content_change.text);
        } else {
            try text_array.replaceRange(allocator, edit.loc.start, replaced_length, content_change.text);
        }
        cursor.index = edit.loc.start + content_change.text.len;
        cursor.position = offsets.advancePosition(
            content_change.text,
            edit.start_position,
            0,
            content_change.text.len,
            encoding,
        );
        cursor.line_start_index = if (cursor.position.line == edit.start_position.line)
            edit.start_line_index
        else
            edit.loc.start + std.mem.findScalarLast(u8, content_change.text, '\n').? + 1;
    }

    return try text_array.toOwnedSliceSentinel(allocator, 0);
}

const PositionToIndexCursor = struct {
    index: usize = 0,
    line_start_index: usize = 0,
    position: offsets.Position = .{ .line = 0, .character = 0 },

    const ResolvedRange = struct {
        loc: offsets.Loc,
        start_position: offsets.Position,
        start_line_index: usize,
    };

    fn rangeToLoc(cursor: *PositionToIndexCursor, text: []const u8, range: offsets.Range, encoding: offsets.Encoding) ResolvedRange {
        std.debug.assert(offsets.orderPosition(range.start, range.end) != .gt);
        const start = cursor.seek(text, range.start, encoding);
        const start_position = cursor.position;
        const start_line_index = cursor.line_start_index;
        const end = cursor.advance(text, .{
            .line = range.end.line - range.start.line,
            .character = if (range.start.line == range.end.line)
                range.end.character - range.start.character
            else
                range.end.character,
        }, encoding);
        return .{
            .loc = .{ .start = start, .end = end },
            .start_position = start_position,
            .start_line_index = start_line_index,
        };
    }

    fn seek(cursor: *PositionToIndexCursor, text: []const u8, target: offsets.Position, encoding: offsets.Encoding) usize {
        if (offsets.orderPosition(target, cursor.position) == .lt) {
            if (target.line <= cursor.position.line / 2) {
                cursor.* = .{};
            } else {
                cursor.retreatToLine(text, target.line);
            }
        }

        return cursor.advance(text, .{
            .line = target.line - cursor.position.line,
            .character = if (target.line == cursor.position.line)
                target.character - cursor.position.character
            else
                target.character,
        }, encoding);
    }

    fn retreatToLine(cursor: *PositionToIndexCursor, text: []const u8, target_line: u32) void {
        while (cursor.position.line > target_line) {
            std.debug.assert(cursor.line_start_index != 0);
            const preceding_text = text[0 .. cursor.line_start_index - 1];
            cursor.line_start_index = if (std.mem.findScalarLast(u8, preceding_text, '\n')) |newline| newline + 1 else 0;
            cursor.position.line -= 1;
        }
        cursor.index = cursor.line_start_index;
        cursor.position.character = 0;
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
            cursor.line_start_index = cursor.index;
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
    try std.testing.expect(unchanged.ptr != @as([]const u8, "old").ptr);
}

test "applyContentChanges advances and retreats its position cursor" {
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
        .{ .text_document_content_change_partial = .{
            .range = .{
                .start = .{ .line = 2, .character = 0 },
                .end = .{ .line = 2, .character = 1 },
            },
            .text = "Z",
        } },
    };

    inline for (.{ offsets.Encoding.@"utf-8", offsets.Encoding.@"utf-16", offsets.Encoding.@"utf-32" }) |encoding| {
        const result = try applyContentChanges(allocator, "ab\ncd\nef", &changes, encoding);
        defer allocator.free(result);
        try std.testing.expectEqualStrings("aY\n🠁\nZX\nef", result);
    }
}

test "PositionToIndexCursor matches rangeToLoc" {
    const text = "a¶↉🠁\r\nsecond line\nthird";
    const ranges = [_]offsets.Range{
        .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } },
        .{ .start = .{ .line = 0, .character = 1 }, .end = .{ .line = 0, .character = 3 } },
        .{ .start = .{ .line = 1, .character = 2 }, .end = .{ .line = 1, .character = 8 } },
        .{ .start = .{ .line = 2, .character = 1 }, .end = .{ .line = 9, .character = 99 } },
        .{ .start = .{ .line = 1, .character = 3 }, .end = .{ .line = 1, .character = 5 } },
        .{ .start = .{ .line = 1, .character = 1 }, .end = .{ .line = 1, .character = 2 } },
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

test "applyContentChanges matches mixed byte replacements" {
    const allocator = std.testing.allocator;
    const initial_text = "alpha¶\r\nbeta↉\ngamma🠁\ndelta\nepsilon🇺🇸\n";
    const replacements = [_][]const u8{ "", "x", "🠁", "\n", "q\n¶", "xy" };

    inline for (.{ offsets.Encoding.@"utf-8", offsets.Encoding.@"utf-16", offsets.Encoding.@"utf-32" }) |encoding| {
        var expected: std.ArrayList(u8) = .empty;
        defer expected.deinit(allocator);
        try expected.appendSlice(allocator, initial_text);

        var state: u64 = 0xd1ff_c0de_5eed_1234;
        var changes: [128]types.TextDocument.ContentChangeEvent = undefined;
        for (&changes) |*change| {
            var start = pseudoRandomIndex(&state, expected.items.len + 1);
            var end = pseudoRandomIndex(&state, expected.items.len + 1);
            if (start > end) std.mem.swap(usize, &start, &end);
            start = utf8BoundaryAtOrBefore(expected.items, start);
            end = utf8BoundaryAtOrBefore(expected.items, end);

            const replacement = replacements[pseudoRandomIndex(&state, replacements.len)];
            change.* = .{ .text_document_content_change_partial = .{
                .range = offsets.locToRange(expected.items, .{ .start = start, .end = end }, encoding),
                .text = replacement,
            } };
            try expected.replaceRange(allocator, start, end - start, replacement);
        }

        const actual = try applyContentChanges(allocator, initial_text, &changes, encoding);
        defer allocator.free(actual);
        try std.testing.expectEqualStrings(expected.items, actual);
    }
}

test "applyContentChanges constructs a single partial change exactly" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        text: []const u8,
        replacement: []const u8,
        loc: offsets.Loc,
        expected: []const u8,
    }{
        .{ .text = "abcdef", .replacement = "XYZ", .loc = .{ .start = 2, .end = 4 }, .expected = "abXYZef" },
        .{ .text = "abcdef", .replacement = "", .loc = .{ .start = 1, .end = 5 }, .expected = "af" },
        .{ .text = "a¶↉🠁z", .replacement = "🇺🇸\nq", .loc = .{ .start = 1, .end = 6 }, .expected = "a🇺🇸\nq🠁z" },
    };

    inline for (.{ offsets.Encoding.@"utf-8", offsets.Encoding.@"utf-16", offsets.Encoding.@"utf-32" }) |encoding| {
        for (cases) |case| {
            const changes = [_]types.TextDocument.ContentChangeEvent{.{
                .text_document_content_change_partial = .{
                    .range = offsets.locToRange(case.text, case.loc, encoding),
                    .text = case.replacement,
                },
            }};
            const result = try applyContentChanges(allocator, case.text, &changes, encoding);
            defer allocator.free(result);
            try std.testing.expectEqualStrings(case.expected, result);
            try std.testing.expect(result.ptr != case.text.ptr);
            try std.testing.expect(result.ptr != case.replacement.ptr);
        }
    }
}

test "applyContentChangesIfChanged detects provable no-op changes" {
    const partial_changes = [_]types.TextDocument.ContentChangeEvent{.{
        .text_document_content_change_partial = .{
            .range = undefined,
            .text = "🠁",
        },
    }};
    inline for (.{ offsets.Encoding.@"utf-8", offsets.Encoding.@"utf-16", offsets.Encoding.@"utf-32" }) |encoding| {
        var changes = partial_changes;
        changes[0].text_document_content_change_partial.range = offsets.locToRange("a🠁z", .{ .start = 1, .end = 5 }, encoding);
        try std.testing.expect((try applyContentChangesIfChanged(
            std.testing.failing_allocator,
            "a🠁z",
            &changes,
            encoding,
        )) == null);
    }

    try std.testing.expect((try applyContentChangesIfChanged(
        std.testing.failing_allocator,
        "same",
        &.{},
        .@"utf-8",
    )) == null);

    const whole_change = [_]types.TextDocument.ContentChangeEvent{.{
        .text_document_content_change_whole_document = .{ .text = "same" },
    }};
    const copied = try applyContentChangesIfChanged(std.testing.allocator, "same", &whole_change, .@"utf-8");
    defer std.testing.allocator.free(copied.?);
    try std.testing.expectEqualStrings("same", copied.?);

    const large_text = "a" ** (max_noop_change_text_len + 1);
    const bounded_text = large_text[0..max_noop_change_text_len];
    const bounded_partial = [_]types.TextDocument.ContentChangeEvent{.{
        .text_document_content_change_partial = .{
            .range = .{
                .start = .{ .line = 0, .character = 0 },
                .end = .{ .line = 0, .character = bounded_text.len },
            },
            .text = bounded_text,
        },
    }};
    try std.testing.expect((try applyContentChangesIfChanged(
        std.testing.failing_allocator,
        bounded_text,
        &bounded_partial,
        .@"utf-8",
    )) == null);

    const large_partial = [_]types.TextDocument.ContentChangeEvent{.{
        .text_document_content_change_partial = .{
            .range = .{
                .start = .{ .line = 0, .character = 0 },
                .end = .{ .line = 0, .character = large_text.len },
            },
            .text = large_text,
        },
    }};
    const large_result = try applyContentChangesIfChanged(std.testing.allocator, large_text, &large_partial, .@"utf-8");
    defer std.testing.allocator.free(large_result.?);
    try std.testing.expectEqualStrings(large_text, large_result.?);

    const original = "abc";
    const aliased_full_then_partial = [_]types.TextDocument.ContentChangeEvent{
        .{ .text_document_content_change_whole_document = .{ .text = original[0..2] } },
        .{ .text_document_content_change_partial = .{
            .range = .{
                .start = .{ .line = 0, .character = 1 },
                .end = .{ .line = 0, .character = 2 },
            },
            .text = "b",
        } },
    };
    const shortened = try applyContentChangesIfChanged(std.testing.allocator, original, &aliased_full_then_partial, .@"utf-8");
    defer std.testing.allocator.free(shortened.?);
    try std.testing.expectEqualStrings("ab", shortened.?);
}

test "applyContentChanges single partial handles every allocation failure" {
    const Test = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const changes = [_]types.TextDocument.ContentChangeEvent{.{
                .text_document_content_change_partial = .{
                    .range = .{
                        .start = .{ .line = 0, .character = 1 },
                        .end = .{ .line = 0, .character = 3 },
                    },
                    .text = "longer",
                },
            }};
            const result = try applyContentChanges(allocator, "abcd", &changes, .@"utf-8");
            defer allocator.free(result);
            try std.testing.expectEqualStrings("alongerd", result);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Test.run, .{});
}

fn pseudoRandomIndex(state: *u64, upper_bound: usize) usize {
    state.* = state.* *% 6_364_136_223_846_793_005 +% 1_442_695_040_888_963_407;
    return @intCast(state.* % @as(u64, @intCast(upper_bound)));
}

fn utf8BoundaryAtOrBefore(text: []const u8, index: usize) usize {
    var boundary = index;
    while (boundary < text.len and text[boundary] & 0xc0 == 0x80) boundary -= 1;
    return boundary;
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
