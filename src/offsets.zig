//! Conversion functions between the following Units:
//! - A "index" or "source index" is a offset into a utf-8 encoding source file.
//! - `Loc`
//! - `Position`
//! - `Range`
//! - `std.zig.Ast.TokenIndex`
//! - `std.zig.Ast.Node.Index`

const std = @import("std");
const offsets = @import("lsp").offsets;
const ast = @import("ast.zig");
const Ast = std.zig.Ast;

pub const Encoding = offsets.Encoding;
pub const Loc = offsets.Loc;
pub const Position = offsets.Position;
pub const Range = offsets.Range;

pub const indexToPosition = offsets.indexToPosition;

/// Converts an LSP position to a byte index while counting newline blocks in
/// parallel. Out-of-range lines and characters retain the lsp-kit clamping
/// behavior.
pub fn positionToIndex(text: []const u8, position: Position, encoding: Encoding) usize {
    var line_start: usize = 0;
    var lines_remaining = position.line;
    if (lines_remaining != 0) {
        if (@import("builtin").zig_backend == .stage2_llvm) {
            if (std.simd.suggestVectorLength(u8)) |block_size| {
                const Block = @Vector(block_size, u8);
                const newlines: Block = @splat('\n');
                while (text.len - line_start >= block_size) {
                    const bytes: Block = text[line_start..][0..block_size].*;
                    const line_count: u32 = @intCast(std.simd.countTrues(bytes == newlines));
                    if (line_count >= lines_remaining) break;
                    lines_remaining -= line_count;
                    line_start += block_size;
                }
            }
        }

        while (line_start < text.len) : (line_start += 1) {
            if (text[line_start] != '\n') continue;
            lines_remaining -= 1;
            if (lines_remaining == 0) {
                line_start += 1;
                break;
            }
        }
        if (lines_remaining != 0) return text.len;
    }

    const line_text = std.mem.sliceTo(text[line_start..], '\n');
    return line_start + getNCodeUnitByteCount(line_text, position.character, encoding);
}

pub const orderPosition = offsets.orderPosition;

pub const locLength = offsets.locLength;
pub const rangeLength = offsets.rangeLength;

pub const locToSlice = offsets.locToSlice;
pub const locToRange = offsets.locToRange;

pub fn rangeToLoc(text: []const u8, range: Range, encoding: Encoding) Loc {
    std.debug.assert(orderPosition(range.start, range.end) != .gt);
    const start = positionToIndex(text, range.start, encoding);
    const relative_end_position: Position = .{
        .line = range.end.line - range.start.line,
        .character = if (range.start.line == range.end.line)
            range.end.character - range.start.character
        else
            range.end.character,
    };
    return .{
        .start = start,
        .end = start + positionToIndex(text[start..], relative_end_position, encoding),
    };
}

pub fn rangeToSlice(text: []const u8, range: Range, encoding: Encoding) []const u8 {
    return locToSlice(text, rangeToLoc(text, range, encoding));
}

pub const lineLocAtIndex = offsets.lineLocAtIndex;
pub const lineSliceAtIndex = offsets.lineSliceAtIndex;
pub const lineLocAtPosition = offsets.lineLocAtPosition;
pub const lineSliceAtPosition = offsets.lineSliceAtPosition;

pub const lineLocUntilIndex = offsets.lineLocUntilIndex;
pub const lineLocUntilPosition = offsets.lineLocUntilPosition;
pub const lineSliceUntilIndex = offsets.lineSliceUntilIndex;
pub const lineSliceUntilPosition = offsets.lineSliceUntilPosition;

pub const convertPositionEncoding = offsets.convertPositionEncoding;
pub const convertRangeEncoding = offsets.convertRangeEncoding;

pub const advancePosition = @import("offsets/advance_position.zig").advancePosition;
pub const countCodeUnits = offsets.countCodeUnits;
pub const getNCodeUnitByteCount = offsets.getNCodeUnitByteCount;

test "positionToIndex matches lsp offsets" {
    const texts = [_][]const u8{
        "",
        "hello",
        "\n\n\n",
        "a¶↉🠁\r\nsecond line\nthird",
        "a" ** 63 ++ "\n" ++ "b" ** 64 ++ "\ntrailer",
        "\n" ** 129 ++ "end",
    };
    const positions = [_]Position{
        .{ .line = 0, .character = 0 },
        .{ .line = 0, .character = 1 },
        .{ .line = 0, .character = 99 },
        .{ .line = 1, .character = 0 },
        .{ .line = 1, .character = 3 },
        .{ .line = 2, .character = 2 },
        .{ .line = 64, .character = 0 },
        .{ .line = 130, .character = 99 },
    };

    for (texts) |text| {
        inline for (.{ Encoding.@"utf-8", Encoding.@"utf-16", Encoding.@"utf-32" }) |encoding| {
            for (positions) |position| {
                try std.testing.expectEqual(
                    offsets.positionToIndex(text, position, encoding),
                    positionToIndex(text, position, encoding),
                );
            }
        }
    }
}

test "positionToIndex matches random valid positions" {
    const text = "a¶↉🠁\r\nsecond line\n" ** 32 ++ "tail🇺🇸";
    var state: u64 = 0x706f_7369_7469_6f6e;

    inline for (.{ Encoding.@"utf-8", Encoding.@"utf-16", Encoding.@"utf-32" }) |encoding| {
        for (0..512) |_| {
            state = state *% 6_364_136_223_846_793_005 +% 1_442_695_040_888_963_407;
            var index: usize = @intCast(state % (text.len + 1));
            while (index < text.len and text[index] & 0xc0 == 0x80) index -= 1;
            const position = offsets.indexToPosition(text, index, encoding);
            try std.testing.expectEqual(index, positionToIndex(text, position, encoding));
        }
    }
}

test "rangeToLoc matches lsp offsets" {
    const text = "a¶↉🠁\r\nsecond line\nthird";
    const ranges = [_]Range{
        .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } },
        .{ .start = .{ .line = 0, .character = 1 }, .end = .{ .line = 0, .character = 3 } },
        .{ .start = .{ .line = 1, .character = 2 }, .end = .{ .line = 1, .character = 8 } },
        .{ .start = .{ .line = 1, .character = 3 }, .end = .{ .line = 2, .character = 2 } },
        .{ .start = .{ .line = 2, .character = 1 }, .end = .{ .line = 99, .character = 99 } },
    };
    inline for (.{ Encoding.@"utf-8", Encoding.@"utf-16", Encoding.@"utf-32" }) |encoding| {
        for (ranges) |range| {
            try std.testing.expectEqual(
                offsets.rangeToLoc(text, range, encoding),
                rangeToLoc(text, range, encoding),
            );
        }
    }

    const split_surrogate: Range = .{
        .start = .{ .line = 0, .character = 1 },
        .end = .{ .line = 0, .character = 2 },
    };
    try std.testing.expectEqual(
        offsets.rangeToLoc("🠁X", split_surrogate, .@"utf-16"),
        rangeToLoc("🠁X", split_surrogate, .@"utf-16"),
    );
}

pub const SourceIndexToTokenIndexResult = union(enum) {
    /// The source index is inside of whitespace.
    none: struct {
        /// The the first token to the left of the source index, if any.
        left: ?Ast.TokenIndex,
        /// The the first token to the right of the source index, if any.
        /// Will ignore the `.eof` token.
        right: ?Ast.TokenIndex,
    },
    /// The source index is on the edge or inside of a token.
    one: Ast.TokenIndex,
    /// The source index is between two tokens.
    between: struct {
        /// The the first token to the left of the source index.
        left: Ast.TokenIndex,
        /// The the first token to the right of the source index.
        right: Ast.TokenIndex,
    },

    pub fn pickTokenTag(
        result: SourceIndexToTokenIndexResult,
        wanted_token_tag: std.zig.Token.Tag,
        tree: *const Ast,
    ) ?Ast.TokenIndex {
        switch (result) {
            .none => return null,
            .one => |token| return if (tree.tokenTag(token) == wanted_token_tag) token else null,
            .between => |data| {
                if (tree.tokenTag(data.left) == wanted_token_tag) return data.left;
                if (tree.tokenTag(data.right) == wanted_token_tag) return data.right;
                return null;
            },
        }
    }

    pub fn pickPreferred(
        result: SourceIndexToTokenIndexResult,
        preferred_tags: []const std.zig.Token.Tag,
        tree: *const Ast,
    ) ?Ast.TokenIndex {
        switch (result) {
            .none => return null,
            .one => |token| return token,
            .between => |data| {
                if (std.mem.findScalar(std.zig.Token.Tag, preferred_tags, tree.tokenTag(data.left)) != null) {
                    return data.left;
                }
                if (std.mem.findScalar(std.zig.Token.Tag, preferred_tags, tree.tokenTag(data.right)) != null) {
                    return data.right;
                }
                return null;
            },
        }
    }

    pub fn preferLeft(result: SourceIndexToTokenIndexResult) Ast.TokenIndex {
        switch (result) {
            .none => |data| return data.left orelse 0,
            .one => |token| return token,
            .between => |data| return data.left,
        }
    }

    pub fn preferRight(result: SourceIndexToTokenIndexResult, tree: *const Ast) Ast.TokenIndex {
        switch (result) {
            .none => |data| return data.right orelse @intCast(tree.tokens.len - 1),
            .one => |token| return token,
            .between => |data| return data.right,
        }
    }
};

pub fn sourceIndexToTokenIndex(tree: *const Ast, source_index: usize) SourceIndexToTokenIndexResult {
    std.debug.assert(source_index <= tree.source.len);

    var upper_index: Ast.TokenIndex = @intCast(tree.tokens.len - 1);
    var lower_index: Ast.TokenIndex = 0;
    while (upper_index - lower_index > 64) {
        const mid = lower_index + (upper_index - lower_index) / 2;
        if (tree.tokenStart(mid) < source_index) {
            lower_index = mid;
        } else {
            upper_index = mid;
        }
    }

    var tokenizer: std.zig.Tokenizer = .{
        .buffer = tree.source,
        .index = tree.tokenStart(lower_index),
    };

    var previous_token_index: ?Ast.TokenIndex = null;
    var previous_token_loc: ?Loc = null;
    var current_token_index: Ast.TokenIndex = lower_index;
    while (current_token_index <= upper_index) {
        const current_token = tokenizer.next();

        if (previous_token_loc) |previous_loc| {
            if (previous_loc.end == source_index) {
                if (source_index == current_token.loc.start and current_token.tag != .eof) {
                    return .{ .between = .{ .left = previous_token_index.?, .right = current_token_index } };
                } else {
                    return .{ .one = previous_token_index.? };
                }
            }
            if (previous_loc.end < source_index and source_index < current_token.loc.start) {
                return .{ .none = .{ .left = previous_token_index.?, .right = current_token_index } };
            }
        }

        if (current_token.tag == .eof) {
            return .{ .none = .{ .left = previous_token_index, .right = null } };
        }

        if (source_index < current_token.loc.start) {
            return .{ .none = .{ .left = previous_token_index, .right = current_token_index } };
        } else if (source_index < current_token.loc.end) {
            return .{ .one = current_token_index };
        } else {
            // continue to the next iteration
        }

        previous_token_index = current_token_index;
        previous_token_loc = current_token.loc;
        current_token_index += 1;
    }

    unreachable;
}

test sourceIndexToTokenIndex {
    var tree: Ast = try .parse(std.testing.allocator, " a  bb; ", .zig);
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(
        std.zig.Token.Tag,
        &.{ .identifier, .identifier, .semicolon, .eof },
        tree.tokens.items(.tag),
    );

    const Result = SourceIndexToTokenIndexResult;
    const expectEqual = std.testing.expectEqual;

    // zig fmt: off
    try expectEqual(Result{ .none    = .{ .left = null, .right = 0    } }, sourceIndexToTokenIndex(&tree, 0));
    try expectEqual(Result{ .one     = 0                                }, sourceIndexToTokenIndex(&tree, 1));
    try expectEqual(Result{ .one     = 0                                }, sourceIndexToTokenIndex(&tree, 2));
    try expectEqual(Result{ .none    = .{ .left = 0,    .right = 1    } }, sourceIndexToTokenIndex(&tree, 3));
    try expectEqual(Result{ .one     = 1                                }, sourceIndexToTokenIndex(&tree, 4));
    try expectEqual(Result{ .one     = 1                                }, sourceIndexToTokenIndex(&tree, 5));
    try expectEqual(Result{ .between = .{ .left = 1,    .right = 2    } }, sourceIndexToTokenIndex(&tree, 6));
    try expectEqual(Result{ .one     = 2                                }, sourceIndexToTokenIndex(&tree, 7));
    try expectEqual(Result{ .none    = .{ .left = 2,    .right = null } }, sourceIndexToTokenIndex(&tree, 8));
    // zig fmt: on
}

test "sourceIndexToTokenIndex - token at end" {
    var tree: Ast = try .parse(std.testing.allocator, " a", .zig);
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(
        std.zig.Token.Tag,
        &.{ .identifier, .eof },
        tree.tokens.items(.tag),
    );

    const Result = SourceIndexToTokenIndexResult;
    const expectEqual = std.testing.expectEqual;

    try expectEqual(Result{ .none = .{ .left = null, .right = 0 } }, sourceIndexToTokenIndex(&tree, 0));
    try expectEqual(Result{ .one = 0 }, sourceIndexToTokenIndex(&tree, 1));
    try expectEqual(Result{ .one = 0 }, sourceIndexToTokenIndex(&tree, 2));
}

pub const IdentifierIndexRange = enum {
    /// delimiting `@` and `"`s are excluded
    name,
    /// delimiting `@` and `"`s are included
    full,
};

/// The source index must be at the start of the valid identifier.
///
/// Supported formats:
/// - `foo`
/// - `@"foo"`
/// - `@foo`
pub fn identifierIndexToLoc(text: [:0]const u8, source_index: usize, range: IdentifierIndexRange) Loc {
    if (text[source_index] == '@' and text[source_index + 1] == '"') {
        const start_index = source_index + 2;
        var index: usize = start_index;
        while (true) : (index += 1) {
            switch (text[index]) {
                '\n' => break,
                '\\' => index += 1,
                '"' => {
                    // include the closing quote
                    if (range == .full) index += 1;
                    break;
                },
                else => {},
            }
        }
        return .{ .start = if (range == .full) source_index else start_index, .end = index };
    } else {
        const start: usize = source_index + @intFromBool(text[source_index] == '@');
        var index = start;
        while (isSymbolChar(text[index])) : (index += 1) {}
        return .{ .start = if (range == .full) source_index else start, .end = index };
    }
}

test identifierIndexToLoc {
    try std.testing.expectEqualStrings("", identifierIndexToSlice("", 0, .name));
    try std.testing.expectEqualStrings("", identifierIndexToSlice(" ", 0, .name));
    try std.testing.expectEqualStrings("", identifierIndexToSlice(" world", 0, .name));

    try std.testing.expectEqualStrings("hello", identifierIndexToSlice("hello", 0, .name));
    try std.testing.expectEqualStrings("hello", identifierIndexToSlice("hello world", 0, .name));
    try std.testing.expectEqualStrings("world", identifierIndexToSlice("hello world", 6, .name));

    try std.testing.expectEqualStrings("hello", identifierIndexToSlice("@\"hello\"", 0, .name));
    try std.testing.expectEqualStrings("hello", identifierIndexToSlice("@\"hello\" world", 0, .name));
    try std.testing.expectEqualStrings("world", identifierIndexToSlice("@\"hello\" @\"world\"", 9, .name));

    try std.testing.expectEqualStrings("hello", identifierIndexToSlice("@hello", 0, .name));

    try std.testing.expectEqualStrings("\\\"", identifierIndexToSlice("@\"\\\"\"", 0, .name));

    try std.testing.expectEqualStrings("@hello", identifierIndexToSlice("@hello", 0, .full));
    try std.testing.expectEqualStrings("@\"hello\"", identifierIndexToSlice("@\"hello\"", 0, .full));
    try std.testing.expectEqualStrings(
        \\@"\"\\\""
    , identifierIndexToSlice(
        \\@"\"\\\""
    , 0, .full));
}

pub fn identifierIndexToSlice(text: [:0]const u8, source_index: usize, range: IdentifierIndexRange) []const u8 {
    return locToSlice(text, identifierIndexToLoc(text, source_index, range));
}

pub fn identifierTokenToNameLoc(tree: *const Ast, identifier_token: Ast.TokenIndex) Loc {
    std.debug.assert(switch (tree.tokenTag(identifier_token)) {
        .builtin => true, // The Zig parser likes to emit .builtin where a identifier would be expected
        .identifier => true,
        else => false,
    });
    return identifierIndexToLoc(tree.source, tree.tokenStart(identifier_token), .name);
}

pub fn identifierTokenToNameSlice(tree: *const Ast, identifier_token: Ast.TokenIndex) []const u8 {
    return locToSlice(tree.source, identifierTokenToNameLoc(tree, identifier_token));
}

/// See `identifierTokenAndLocFromIndex`.
pub fn identifierLocFromIndex(tree: *const Ast, source_index: usize) ?Loc {
    _, const loc = identifierTokenAndLocFromIndex(tree, source_index) orelse return null;
    return loc;
}

/// Returns the source location of `foo` if the source index is on a valid identifier.
///
/// Supported formats:
/// - `foo`    (identifier)
/// - `@"foo"` (escaped identifier)
/// - `@foo`   (builtin)
pub fn identifierTokenAndLocFromIndex(tree: *const Ast, source_index: usize) ?struct { Ast.TokenIndex, Loc } {
    const token = sourceIndexToTokenIndex(tree, source_index).pickPreferred(&.{ .identifier, .builtin }, tree) orelse return null;
    switch (tree.tokenTag(token)) {
        .identifier, .builtin => {},
        else => return null,
    }
    const token_loc = tokenToLoc(tree, token);
    std.debug.assert(token_loc.start <= source_index and source_index <= token_loc.end);
    return .{ token, identifierIndexToLoc(tree.source, token_loc.start, .name) };
}

test identifierLocFromIndex {
    var tree = try Ast.parse(std.testing.allocator,
        \\ name  @builtin  @"escaped"  @"s p a c e"  end
    , .zig);
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(
        std.zig.Token.Tag,
        &.{ .identifier, .builtin, .identifier, .identifier, .identifier, .eof },
        tree.tokens.items(.tag),
    );

    {
        const expected_loc: Loc = .{ .start = 1, .end = 5 };
        std.debug.assert(std.mem.eql(u8, "name", locToSlice(tree.source, expected_loc)));

        try std.testing.expectEqual(expected_loc, identifierLocFromIndex(&tree, 1));
        try std.testing.expectEqual(expected_loc, identifierLocFromIndex(&tree, 2));
        try std.testing.expectEqual(expected_loc, identifierLocFromIndex(&tree, 5));
    }

    {
        const expected_loc: Loc = .{ .start = 8, .end = 15 };
        std.debug.assert(std.mem.eql(u8, "builtin", locToSlice(tree.source, expected_loc)));

        try std.testing.expectEqual(@as(?Loc, null), identifierLocFromIndex(&tree, 6));
        try std.testing.expectEqual(expected_loc, identifierLocFromIndex(&tree, 7));
        try std.testing.expectEqual(expected_loc, identifierLocFromIndex(&tree, 8));
        try std.testing.expectEqual(expected_loc, identifierLocFromIndex(&tree, 11));
        try std.testing.expectEqual(expected_loc, identifierLocFromIndex(&tree, 15));
        try std.testing.expectEqual(@as(?Loc, null), identifierLocFromIndex(&tree, 16));
    }

    {
        const expected_loc: Loc = .{ .start = 19, .end = 26 };
        std.debug.assert(std.mem.eql(u8, "escaped", locToSlice(tree.source, expected_loc)));

        try std.testing.expectEqual(@as(?Loc, null), identifierLocFromIndex(&tree, 16));
        try std.testing.expectEqual(expected_loc, identifierLocFromIndex(&tree, 17));
        try std.testing.expectEqual(expected_loc, identifierLocFromIndex(&tree, 18));
        try std.testing.expectEqual(expected_loc, identifierLocFromIndex(&tree, 19));
        try std.testing.expectEqual(expected_loc, identifierLocFromIndex(&tree, 23));
        try std.testing.expectEqual(expected_loc, identifierLocFromIndex(&tree, 27));
        try std.testing.expectEqual(@as(?Loc, null), identifierLocFromIndex(&tree, 28));
    }

    {
        const expected_loc: Loc = .{ .start = 43, .end = 46 };
        std.debug.assert(std.mem.eql(u8, "end", locToSlice(tree.source, expected_loc)));

        try std.testing.expectEqual(@as(?Loc, null), identifierLocFromIndex(&tree, 42));
        try std.testing.expectEqual(@as(?Loc, expected_loc), identifierLocFromIndex(&tree, 43));
        try std.testing.expectEqual(@as(?Loc, expected_loc), identifierLocFromIndex(&tree, 45));
        try std.testing.expectEqual(@as(?Loc, expected_loc), identifierLocFromIndex(&tree, 46));
    }
}

pub fn isSymbolChar(char: u8) bool {
    return switch (char) {
        'a'...'z', 'A'...'Z', '_', '0'...'9' => true,
        else => false,
    };
}

pub fn tokensToLoc(tree: *const Ast, first_token: Ast.TokenIndex, last_token: Ast.TokenIndex) Loc {
    return .{ .start = tree.tokenStart(first_token), .end = tokenToLoc(tree, last_token).end };
}

pub fn tokenToLoc(tree: *const Ast, token_index: Ast.TokenIndex) Loc {
    const start = tree.tokenStart(token_index);
    const tag = tree.tokenTag(token_index);

    // Many tokens can be determined entirely by their tag.
    if (tag == .identifier or tag == .builtin) {
        // fast path for identifiers
        return identifierIndexToLoc(tree.source, start, .full);
    } else if (tag.lexeme()) |lexeme| {
        return .{
            .start = start,
            .end = start + lexeme.len,
        };
    } else if (tag == .invalid) {
        // invalid tokens are one byte sized so we scan left and right to find the
        // source location that contains complete code units
        // this assumes that `tree.source` is valid utf8
        var begin = token_index;
        while (begin > 0 and tree.tokenTag(begin - 1) == .invalid) : (begin -= 1) {}

        var end = token_index;
        while (end < tree.tokens.len and tree.tokenTag(end) == .invalid) : (end += 1) {}
        return .{
            .start = tree.tokenStart(begin),
            .end = tree.tokenStart(end),
        };
    }

    // For some tokens, re-tokenization is needed to find the end.
    var tokenizer: std.zig.Tokenizer = .{
        .buffer = tree.source,
        .index = start,
    };

    const token = tokenizer.next();
    // A failure would indicate a corrupted tree.source
    std.debug.assert(token.tag == tag);
    return token.loc;
}

test tokenToLoc {
    try testTokenToLoc("foo", 0, 0, 3);
    try testTokenToLoc("foo\n", 0, 0, 3);
    try testTokenToLoc("\nfoo", 0, 1, 4);
    try testTokenToLoc("foo:", 0, 0, 3);
    try testTokenToLoc(";;", 1, 1, 2);
}

fn testTokenToLoc(text: [:0]const u8, token_index: Ast.TokenIndex, start: usize, end: usize) !void {
    var tree = try Ast.parse(std.testing.allocator, text, .zig);
    defer tree.deinit(std.testing.allocator);

    const actual = tokenToLoc(&tree, token_index);

    try std.testing.expectEqual(start, actual.start);
    try std.testing.expectEqual(end, actual.end);
}

pub fn tokenToSlice(tree: *const Ast, token_index: Ast.TokenIndex) []const u8 {
    return locToSlice(tree.source, tokenToLoc(tree, token_index));
}

pub fn tokensToSlice(tree: *const Ast, first_token: Ast.TokenIndex, last_token: Ast.TokenIndex) []const u8 {
    std.debug.assert(first_token <= last_token);
    return locToSlice(tree.source, tokensToLoc(tree, first_token, last_token));
}

pub fn tokenToPosition(tree: *const Ast, token_index: Ast.TokenIndex, encoding: Encoding) Position {
    const start = tree.tokenStart(token_index);
    return indexToPosition(tree.source, start, encoding);
}

pub fn tokenToRange(tree: *const Ast, token_index: Ast.TokenIndex, encoding: Encoding) Range {
    const start = tokenToPosition(tree, token_index, encoding);
    const loc = tokenToLoc(tree, token_index);

    return .{
        .start = start,
        .end = advancePosition(tree.source, start, loc.start, loc.end, encoding),
    };
}

pub fn tokenLength(tree: *const Ast, token_index: Ast.TokenIndex, encoding: Encoding) usize {
    const loc = tokenToLoc(tree, token_index);
    return locLength(tree.source, loc, encoding);
}

pub fn tokenIndexLength(text: [:0]const u8, index: usize, encoding: Encoding) usize {
    const loc = tokenIndexToLoc(text, index);
    return locLength(text, loc, encoding);
}

pub fn tokenIndexToLoc(text: [:0]const u8, index: usize) Loc {
    var tokenizer: std.zig.Tokenizer = .{
        .buffer = text,
        .index = index,
    };

    const token = tokenizer.next();
    return .{ .start = token.loc.start, .end = token.loc.end };
}

test tokenIndexToLoc {
    try std.testing.expectEqual(Loc{ .start = 0, .end = 0 }, tokenIndexToLoc("", 0));
    try std.testing.expectEqual(Loc{ .start = 0, .end = 3 }, tokenIndexToLoc("foo", 0));
    try std.testing.expectEqual(Loc{ .start = 3, .end = 4 }, tokenIndexToLoc("0, 0", 3));
    try std.testing.expectEqual(Loc{ .start = 1, .end = 4 }, tokenIndexToLoc(" bar ", 0));
}

pub fn tokenPositionToLoc(text: [:0]const u8, position: Position, encoding: Encoding) Loc {
    const index = positionToIndex(text, position, encoding);
    return tokenIndexToLoc(text, index);
}

pub fn tokenIndexToSlice(text: [:0]const u8, index: usize) []const u8 {
    return locToSlice(text, tokenIndexToLoc(text, index));
}

pub fn tokenPositionToSlice(text: [:0]const u8, position: Position) []const u8 {
    return locToSlice(text, tokenPositionToLoc(text, position));
}

pub fn tokenIndexToRange(text: [:0]const u8, index: usize, encoding: Encoding) Range {
    const start = indexToPosition(text, index, encoding);
    const loc = tokenIndexToLoc(text, index);

    return .{
        .start = start,
        .end = advancePosition(text, start, loc.start, loc.end, encoding),
    };
}

pub fn tokenPositionToRange(text: [:0]const u8, position: Position, encoding: Encoding) Range {
    const index = positionToIndex(text, position, encoding);
    const loc = tokenIndexToLoc(text, index);

    return .{
        .start = position,
        .end = advancePosition(text, position, loc.start, loc.end, encoding),
    };
}

pub fn nodeToLoc(tree: *const Ast, node: Ast.Node.Index) Loc {
    return tokensToLoc(tree, tree.firstToken(node), ast.lastToken(tree, node));
}

pub fn nodeToSlice(tree: *const Ast, node: Ast.Node.Index) []const u8 {
    return locToSlice(tree.source, nodeToLoc(tree, node));
}

pub fn nodeToRange(tree: *const Ast, node: Ast.Node.Index, encoding: Encoding) Range {
    return locToRange(tree.source, nodeToLoc(tree, node), encoding);
}

/// return the source location
/// that starts `n` lines before the line at which `index` is located
/// and    ends `n` lines after  the line at which `index` is located.
/// `n == 0` is equivalent to calling `lineLocAtIndex`.
pub fn multilineLocAtIndex(text: []const u8, index: usize, n: usize) Loc {
    const start = blk: {
        var i: usize = index;
        var num_lines: usize = 0;
        while (i != 0) : (i -= 1) {
            if (text[i - 1] != '\n') continue;
            if (num_lines >= n) break :blk i;
            num_lines += 1;
        }
        break :blk 0;
    };
    const end = blk: {
        var i: usize = index;
        var num_lines: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] != '\n') continue;
            if (num_lines >= n) break :blk i;
            num_lines += 1;
        }
        break :blk text.len;
    };

    return .{
        .start = start,
        .end = end,
    };
}

test multilineLocAtIndex {
    const text =
        \\line0
        \\line1
        \\line2
        \\line3
        \\line4
    ;
    try std.testing.expectEqualStrings(lineSliceAtIndex(text, 0), multilineSliceAtIndex(text, 0, 0));
    try std.testing.expectEqualStrings(lineSliceAtIndex(text, 5), multilineSliceAtIndex(text, 5, 0));
    try std.testing.expectEqualStrings(lineSliceAtIndex(text, 6), multilineSliceAtIndex(text, 6, 0));

    try std.testing.expectEqualStrings("line1\nline2\nline3", multilineSliceAtIndex(text, 15, 1));
    try std.testing.expectEqualStrings("line0\nline1", multilineSliceAtIndex(text, 3, 1));
    try std.testing.expectEqualStrings("line3\nline4", multilineSliceAtIndex(text, 27, 1));
}

/// see `multilineLocAtIndex`
pub fn multilineSliceAtIndex(text: []const u8, index: usize, n: usize) []const u8 {
    return locToSlice(text, multilineLocAtIndex(text, index, n));
}

/// see `multilineLocAtIndex`
pub fn multilineLocAtPosition(text: []const u8, position: Position, n: usize, encoding: Encoding) Loc {
    return lineLocAtIndex(text, positionToIndex(text, position, n, encoding));
}

/// see `multilineLocAtIndex`
pub fn multilineSliceAtPosition(text: []const u8, position: Position, n: usize, encoding: Encoding) []const u8 {
    return locToSlice(text, multilineLocAtPosition(text, position, n, encoding));
}

/// returns true if a and b intersect
pub fn locIntersect(a: Loc, b: Loc) bool {
    std.debug.assert(a.start <= a.end and b.start <= b.end);
    return a.start < b.end and a.end > b.start;
}

test locIntersect {
    const a: Loc = .{ .start = 2, .end = 5 };
    try std.testing.expect(locIntersect(a, .{ .start = 0, .end = 2 }) == false);
    try std.testing.expect(locIntersect(a, .{ .start = 1, .end = 3 }) == true);
    try std.testing.expect(locIntersect(a, .{ .start = 2, .end = 4 }) == true);
    try std.testing.expect(locIntersect(a, .{ .start = 3, .end = 5 }) == true);
    try std.testing.expect(locIntersect(a, .{ .start = 4, .end = 6 }) == true);
    try std.testing.expect(locIntersect(a, .{ .start = 5, .end = 7 }) == false);
}

/// returns true if a is inside b
pub fn locInside(inner: Loc, outer: Loc) bool {
    std.debug.assert(inner.start <= inner.end and outer.start <= outer.end);
    return outer.start <= inner.start and inner.end <= outer.end;
}

test locInside {
    const outer: Loc = .{ .start = 2, .end = 5 };
    try std.testing.expect(locInside(.{ .start = 0, .end = 2 }, outer) == false);
    try std.testing.expect(locInside(.{ .start = 1, .end = 3 }, outer) == false);
    try std.testing.expect(locInside(.{ .start = 2, .end = 4 }, outer) == true);
    try std.testing.expect(locInside(.{ .start = 3, .end = 5 }, outer) == true);
    try std.testing.expect(locInside(.{ .start = 4, .end = 6 }, outer) == false);
    try std.testing.expect(locInside(.{ .start = 5, .end = 7 }, outer) == false);
}

/// returns the union of a and b
pub fn locMerge(a: Loc, b: Loc) Loc {
    std.debug.assert(a.start <= a.end and b.start <= b.end);
    return .{
        .start = @min(a.start, b.start),
        .end = @max(a.end, b.end),
    };
}

test locMerge {
    const a: Loc = .{ .start = 2, .end = 5 };
    try std.testing.expectEqualDeep(locMerge(a, .{ .start = 0, .end = 2 }), Loc{ .start = 0, .end = 5 });
    try std.testing.expectEqualDeep(locMerge(a, .{ .start = 1, .end = 3 }), Loc{ .start = 1, .end = 5 });
    try std.testing.expectEqualDeep(locMerge(a, .{ .start = 2, .end = 4 }), Loc{ .start = 2, .end = 5 });
    try std.testing.expectEqualDeep(locMerge(a, .{ .start = 3, .end = 5 }), Loc{ .start = 2, .end = 5 });
    try std.testing.expectEqualDeep(locMerge(a, .{ .start = 4, .end = 6 }), Loc{ .start = 2, .end = 6 });
    try std.testing.expectEqualDeep(locMerge(a, .{ .start = 5, .end = 7 }), Loc{ .start = 2, .end = 7 });
}

pub fn positionInsideRange(inner: Position, outer: Range) bool {
    std.debug.assert(orderPosition(outer.start, outer.end) != .gt);
    return orderPosition(outer.start, inner) != .gt and orderPosition(inner, outer.end) != .gt;
}

test positionInsideRange {
    const range: Range = .{
        .start = .{ .line = 1, .character = 2 },
        .end = .{ .line = 2, .character = 4 },
    };
    try std.testing.expect(!positionInsideRange(.{ .line = 0, .character = 0 }, range));
    try std.testing.expect(!positionInsideRange(.{ .line = 0, .character = 2 }, range));
    try std.testing.expect(!positionInsideRange(.{ .line = 0, .character = 4 }, range));
    try std.testing.expect(!positionInsideRange(.{ .line = 1, .character = 0 }, range));
    try std.testing.expect(!positionInsideRange(.{ .line = 1, .character = 1 }, range));

    try std.testing.expect(positionInsideRange(.{ .line = 1, .character = 2 }, range));
    try std.testing.expect(positionInsideRange(.{ .line = 1, .character = 4 }, range));
    try std.testing.expect(positionInsideRange(.{ .line = 2, .character = 0 }, range));
    try std.testing.expect(positionInsideRange(.{ .line = 2, .character = 2 }, range));
    try std.testing.expect(positionInsideRange(.{ .line = 2, .character = 4 }, range));

    try std.testing.expect(!positionInsideRange(.{ .line = 2, .character = 6 }, range));
    try std.testing.expect(!positionInsideRange(.{ .line = 3, .character = 0 }, range));
    try std.testing.expect(!positionInsideRange(.{ .line = 3, .character = 2 }, range));
    try std.testing.expect(!positionInsideRange(.{ .line = 3, .character = 4 }, range));
    try std.testing.expect(!positionInsideRange(.{ .line = 3, .character = 6 }, range));
}

/// More efficient conversion functions that operate on multiple elements.
pub const multiple = struct {
    const stack_mapping_capacity = 64;

    /// a mapping from a source index to a line character pair
    pub const IndexToPositionMapping = struct {
        output: *Position,
        source_index: usize,

        fn lessThan(_: void, lhs: IndexToPositionMapping, rhs: IndexToPositionMapping) bool {
            return lhs.source_index < rhs.source_index;
        }
    };

    pub fn indexToPositionWithMappings(
        text: []const u8,
        mappings: []IndexToPositionMapping,
        encoding: Encoding,
    ) void {
        if (!std.sort.isSorted(IndexToPositionMapping, mappings, {}, IndexToPositionMapping.lessThan)) {
            return indexToPositionWithUnsortedMappings(text, mappings, encoding);
        }
        indexToPositionWithOrderedMappings(text, mappings, encoding);
    }

    fn indexToPositionWithUnsortedMappings(
        text: []const u8,
        mappings: []IndexToPositionMapping,
        encoding: Encoding,
    ) void {
        std.mem.sort(IndexToPositionMapping, mappings, {}, IndexToPositionMapping.lessThan);
        indexToPositionWithOrderedMappings(text, mappings, encoding);
    }

    fn indexToPositionWithOrderedMappings(
        text: []const u8,
        mappings: []const IndexToPositionMapping,
        encoding: Encoding,
    ) void {
        var last_index: usize = 0;
        var last_position: Position = .{ .line = 0, .character = 0 };
        for (mappings) |mapping| {
            const index = mapping.source_index;
            const position = advancePosition(text, last_position, last_index, index, encoding);
            defer last_index = index;
            defer last_position = position;

            mapping.output.* = position;
        }
    }

    pub fn indexToPosition(
        allocator: std.mem.Allocator,
        text: []const u8,
        source_indices: []const usize,
        result_positions: []Position,
        encoding: Encoding,
    ) error{OutOfMemory}!void {
        std.debug.assert(source_indices.len == result_positions.len);

        if (std.sort.isSorted(usize, source_indices, {}, std.sort.asc(usize))) {
            var last_index: usize = 0;
            var last_position: Position = .{ .line = 0, .character = 0 };
            for (source_indices, result_positions) |index, *position| {
                position.* = advancePosition(text, last_position, last_index, index, encoding);
                last_index = index;
                last_position = position.*;
            }
            return;
        }

        var stack_mappings: [stack_mapping_capacity]IndexToPositionMapping = undefined;
        const heap_mappings = if (source_indices.len > stack_mappings.len)
            try allocator.alloc(IndexToPositionMapping, source_indices.len)
        else
            null;
        defer if (heap_mappings) |mappings| allocator.free(mappings);
        const mappings = heap_mappings orelse stack_mappings[0..source_indices.len];

        for (mappings, source_indices, result_positions) |*mapping, index, *position| {
            mapping.* = .{ .output = position, .source_index = index };
        }

        indexToPositionWithUnsortedMappings(text, mappings, encoding);
    }

    test "indexToPosition" {
        const text =
            \\hello
            \\world
        ;

        const source_indices: []const usize = &.{ 3, 9, 6, 0 };
        var result_positions: [4]Position = undefined;
        try multiple.indexToPosition(std.testing.allocator, text, source_indices, &result_positions, .@"utf-16");

        try std.testing.expectEqualSlices(Position, &.{
            .{ .line = 0, .character = 3 },
            .{ .line = 1, .character = 3 },
            .{ .line = 1, .character = 0 },
            .{ .line = 0, .character = 0 },
        }, &result_positions);

        const ordered_indices: []const usize = &.{ 0, 3, 3, 6, 9 };
        var ordered_positions: [ordered_indices.len]Position = undefined;
        try multiple.indexToPosition(std.testing.allocator, text, ordered_indices, &ordered_positions, .@"utf-16");
        for (ordered_indices, ordered_positions) |index, position| {
            try std.testing.expectEqual(offsets.indexToPosition(text, index, .@"utf-16"), position);
        }

        var ordered_large_indices: [stack_mapping_capacity + 1]usize = undefined;
        for (&ordered_large_indices, 0..) |*index, i| index.* = text.len * i / stack_mapping_capacity;
        var ordered_large_positions: [stack_mapping_capacity + 1]Position = undefined;
        inline for (.{ Encoding.@"utf-8", Encoding.@"utf-16", Encoding.@"utf-32" }) |encoding| {
            try multiple.indexToPosition(
                std.testing.failing_allocator,
                text,
                &ordered_large_indices,
                &ordered_large_positions,
                encoding,
            );
            for (ordered_large_indices, ordered_large_positions) |index, position| {
                try std.testing.expectEqual(offsets.indexToPosition(text, index, encoding), position);
            }
        }

        const unicode_text = "a¶↉🠁\r\nsecond line\nthird";
        const valid_indices = [_]usize{ 0, 1, 3, 6, 10, 11, 12, 18, 23, unicode_text.len };
        var indices: [stack_mapping_capacity + 1]usize = undefined;
        for (&indices, 0..) |*index, i| index.* = valid_indices[(i * 7) % valid_indices.len];
        var positions: [stack_mapping_capacity + 1]Position = undefined;

        inline for (.{ Encoding.@"utf-8", Encoding.@"utf-16", Encoding.@"utf-32" }) |encoding| {
            for ([_]usize{ stack_mapping_capacity, stack_mapping_capacity + 1 }) |count| {
                try multiple.indexToPosition(
                    std.testing.allocator,
                    unicode_text,
                    indices[0..count],
                    positions[0..count],
                    encoding,
                );
                for (indices[0..count], positions[0..count]) |index, position| {
                    try std.testing.expectEqual(offsets.indexToPosition(unicode_text, index, encoding), position);
                }
            }
        }

        try multiple.indexToPosition(
            std.testing.failing_allocator,
            unicode_text,
            indices[0..stack_mapping_capacity],
            positions[0..stack_mapping_capacity],
            .@"utf-16",
        );

        try std.testing.expectError(error.OutOfMemory, multiple.indexToPosition(
            std.testing.failing_allocator,
            unicode_text,
            &indices,
            &positions,
            .@"utf-16",
        ));
    }

    pub fn locToRange(
        allocator: std.mem.Allocator,
        text: []const u8,
        locs: []const Loc,
        ranges: []Range,
        encoding: Encoding,
    ) error{OutOfMemory}!void {
        std.debug.assert(locs.len == ranges.len);

        if (locsAreOrdered(locs)) {
            var last_index: usize = 0;
            var last_position: Position = .{ .line = 0, .character = 0 };
            for (locs, ranges) |loc, *range| {
                range.start = advancePosition(text, last_position, last_index, loc.start, encoding);
                range.end = advancePosition(text, range.start, loc.start, loc.end, encoding);
                last_index = loc.end;
                last_position = range.end;
            }
            return;
        }

        // one mapping for every start and end position
        var stack_mappings: [stack_mapping_capacity]IndexToPositionMapping = undefined;
        const mapping_count = locs.len * 2;
        const heap_mappings = if (mapping_count > stack_mappings.len)
            try allocator.alloc(IndexToPositionMapping, mapping_count)
        else
            null;
        defer if (heap_mappings) |mappings| allocator.free(mappings);
        const mappings = heap_mappings orelse stack_mappings[0..mapping_count];

        for (locs, ranges, 0..) |loc, *range, i| {
            mappings[2 * i + 0] = .{ .output = &range.start, .source_index = loc.start };
            mappings[2 * i + 1] = .{ .output = &range.end, .source_index = loc.end };
        }

        indexToPositionWithUnsortedMappings(text, mappings, encoding);
    }

    test "locToRange" {
        const text =
            \\hello
            \\world
        ;

        const locs: []const Loc = &.{
            .{ .start = 3, .end = 9 },
            .{ .start = 6, .end = 0 },
        };
        var result_ranges: [2]Range = undefined;
        try multiple.locToRange(std.testing.allocator, text, locs, &result_ranges, .@"utf-16");

        try std.testing.expectEqualSlices(Range, &.{
            .{ .start = .{ .line = 0, .character = 3 }, .end = .{ .line = 1, .character = 3 } },
            .{ .start = .{ .line = 1, .character = 0 }, .end = .{ .line = 0, .character = 0 } },
        }, &result_ranges);

        var ordered_large_locs: [stack_mapping_capacity / 2 + 1]Loc = undefined;
        for (&ordered_large_locs, 0..) |*loc, i| {
            const index = text.len * i / (ordered_large_locs.len - 1);
            loc.* = .{ .start = index, .end = index };
        }
        var ordered_large_ranges: [stack_mapping_capacity / 2 + 1]Range = undefined;
        inline for (.{ Encoding.@"utf-8", Encoding.@"utf-16", Encoding.@"utf-32" }) |encoding| {
            try multiple.locToRange(
                std.testing.failing_allocator,
                text,
                &ordered_large_locs,
                &ordered_large_ranges,
                encoding,
            );
            for (ordered_large_locs, ordered_large_ranges) |loc, range| {
                try std.testing.expectEqual(offsets.locToRange(text, loc, encoding), range);
            }
        }

        const unicode_text = "a¶↉🠁\r\nsecond line\nthird";
        const valid_indices = [_]usize{ 0, 1, 3, 6, 10, 11, 12, 18, 23, unicode_text.len };
        var boundary_locs: [stack_mapping_capacity / 2 + 1]Loc = undefined;
        for (&boundary_locs, 0..) |*loc, i| {
            const first = valid_indices[(i * 7) % valid_indices.len];
            const second = valid_indices[(i * 3 + 1) % valid_indices.len];
            loc.* = .{
                .start = @min(first, second),
                .end = @max(first, second),
            };
        }
        var boundary_ranges: [stack_mapping_capacity / 2 + 1]Range = undefined;

        inline for (.{ Encoding.@"utf-8", Encoding.@"utf-16", Encoding.@"utf-32" }) |encoding| {
            for ([_]usize{ stack_mapping_capacity / 2, stack_mapping_capacity / 2 + 1 }) |count| {
                try multiple.locToRange(
                    std.testing.allocator,
                    unicode_text,
                    boundary_locs[0..count],
                    boundary_ranges[0..count],
                    encoding,
                );
                for (boundary_locs[0..count], boundary_ranges[0..count]) |loc, range| {
                    try std.testing.expectEqual(offsets.locToRange(unicode_text, loc, encoding), range);
                }
            }
        }

        try multiple.locToRange(
            std.testing.failing_allocator,
            unicode_text,
            boundary_locs[0 .. stack_mapping_capacity / 2],
            boundary_ranges[0 .. stack_mapping_capacity / 2],
            .@"utf-16",
        );

        try std.testing.expectError(error.OutOfMemory, multiple.locToRange(
            std.testing.failing_allocator,
            unicode_text,
            &boundary_locs,
            &boundary_ranges,
            .@"utf-16",
        ));
    }

    fn locsAreOrdered(locs: []const Loc) bool {
        var previous_end: usize = 0;
        for (locs) |loc| {
            if (loc.start < previous_end or loc.end < loc.start) return false;
            previous_end = loc.end;
        }
        return true;
    }
};

comptime {
    std.testing.refAllDecls(multiple);
}
