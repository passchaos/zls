//! Parsing and source preservation for function-completion snippets that
//! replace an existing call containing one or more empty argument slots.

const std = @import("std");
const offsets = @import("../offsets.zig");

pub const PartialCall = struct {
    range: offsets.Range,
    arguments: []const []const u8,
};

pub fn parse(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    identifier_loc: offsets.Loc,
    encoding: offsets.Encoding,
) error{OutOfMemory}!?PartialCall {
    const open_index = identifier_loc.end;
    const scan_result = scan(source, open_index, null) orelse return null;
    if (!scan_result.has_empty) return null;
    const range = offsets.locToRange(source, .{ .start = identifier_loc.start, .end = scan_result.end_index }, encoding);
    if (range.start.line != range.end.line) return null;

    const arguments = try allocator.alloc([]const u8, scan_result.argument_count);
    const verified = scan(source, open_index, arguments).?;
    std.debug.assert(verified.end_index == scan_result.end_index and verified.argument_count == scan_result.argument_count);
    return .{ .range = range, .arguments = arguments };
}

const Scan = struct {
    end_index: usize,
    argument_count: usize,
    has_empty: bool,
};

fn scan(source: [:0]const u8, open_index: usize, output: ?[][]const u8) ?Scan {
    var tokenizer: std.zig.Tokenizer = .init(source[open_index..]);
    if (tokenizer.next().tag != .l_paren) return null;

    var argument_start: usize = open_index + 1;
    var argument_count: usize = 0;
    var paren_depth: usize = 1;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    var has_empty = false;
    while (true) {
        const token = tokenizer.next();
        const token_start = open_index + token.loc.start;
        const token_end = open_index + token.loc.end;
        switch (token.tag) {
            .eof => return null,
            .l_paren => paren_depth += 1,
            .r_paren => {
                paren_depth -= 1;
                if (paren_depth != 0) continue;
                if (bracket_depth != 0 or brace_depth != 0) return null;
                const argument = std.mem.trim(u8, source[argument_start..token_start], " \t\r\n");
                has_empty = has_empty or argument.len == 0;
                if (output) |arguments| arguments[argument_count] = argument;
                argument_count += 1;
                return .{ .end_index = token_end, .argument_count = argument_count, .has_empty = has_empty };
            },
            .l_bracket => bracket_depth += 1,
            .r_bracket => {
                if (bracket_depth == 0) return null;
                bracket_depth -= 1;
            },
            .l_brace => brace_depth += 1,
            .r_brace => {
                if (brace_depth == 0) return null;
                brace_depth -= 1;
            },
            .comma => if (paren_depth == 1 and bracket_depth == 0 and brace_depth == 0) {
                const argument = std.mem.trim(u8, source[argument_start..token_start], " \t\r\n");
                has_empty = has_empty or argument.len == 0;
                if (output) |arguments| arguments[argument_count] = argument;
                argument_count += 1;
                argument_start = token_end;
            },
            else => {},
        }
    }
}

pub fn appendSnippetLiteral(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    literal: []const u8,
) error{OutOfMemory}!void {
    var written: usize = 0;
    for (literal, 0..) |char, index| switch (char) {
        '$', '\\' => {
            try output.appendSlice(allocator, literal[written..index]);
            try output.appendSlice(allocator, &.{ '\\', char });
            written = index + 1;
        },
        else => {},
    };
    try output.appendSlice(allocator, literal[written..]);
}

test parse {
    const allocator = std.testing.allocator;
    const source: [:0]const u8 = "call(@TypeOf(.{ 1, 2 }), , \"a,b\")";
    const parsed = (try parse(allocator, source, .{ .start = 0, .end = 4 }, .@"utf-16")).?;
    defer allocator.free(parsed.arguments);
    try std.testing.expectEqualSlices([]const u8, &.{ "@TypeOf(.{ 1, 2 })", "", "\"a,b\"" }, parsed.arguments);
    try std.testing.expectEqual(offsets.locToRange(source, .{ .start = 0, .end = source.len }, .@"utf-16"), parsed.range);

    try std.testing.expect((try parse(allocator, "call(1, 2)", .{ .start = 0, .end = 4 }, .@"utf-16")) == null);
    try std.testing.expect((try parse(allocator, "call(1,", .{ .start = 0, .end = 4 }, .@"utf-16")) == null);
    try std.testing.expect((try parse(allocator, "call(], )", .{ .start = 0, .end = 4 }, .@"utf-16")) == null);
    try std.testing.expect((try parse(allocator, "call(}, )", .{ .start = 0, .end = 4 }, .@"utf-16")) == null);
    try std.testing.expect((try parse(allocator, "call([1, )", .{ .start = 0, .end = 4 }, .@"utf-16")) == null);
    try std.testing.expect((try parse(allocator, "call(.{ 1, )", .{ .start = 0, .end = 4 }, .@"utf-16")) == null);

    var failing_allocator: std.testing.FailingAllocator = .init(allocator, .{ .fail_index = 0 });
    try std.testing.expect((try parse(failing_allocator.allocator(), "call(1,\n )", .{ .start = 0, .end = 4 }, .@"utf-16")) == null);
}

test appendSnippetLiteral {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendSnippetLiteral(&output, std.testing.allocator, "@TypeOf(\"$\\n\")");
    try std.testing.expectEqualStrings("@TypeOf(\"\\$\\\\n\")", output.items);
}
