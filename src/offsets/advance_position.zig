//! Incremental source positions without rescanning previously visited text.
const std = @import("std");
const offsets = @import("lsp").offsets;
const Encoding = offsets.Encoding;
const Position = offsets.Position;

/// Advances an already-known position without rescanning the current line.
/// Asserts that `position` corresponds to `from_index` and `from_index <= to_index`.
pub fn advancePosition(
    text: []const u8,
    position: Position,
    from_index: usize,
    to_index: usize,
    encoding: Encoding,
) Position {
    std.debug.assert(from_index <= to_index);
    std.debug.assert(to_index <= text.len);

    var result = position;
    switch (encoding) {
        .@"utf-8" => {
            const slice = text[from_index..to_index];
            if (slice.len >= 64) {
                const line_count = std.mem.countScalar(u8, slice, '\n');
                if (line_count == 0) {
                    result.character += @intCast(slice.len);
                } else {
                    result.line += @intCast(line_count);
                    result.character = @intCast(slice.len - std.mem.findScalarLast(u8, slice, '\n').? - 1);
                }
            } else for (slice) |c| {
                if (c == '\n') {
                    result.line += 1;
                    result.character = 0;
                } else {
                    result.character += 1;
                }
            }
        },
        .@"utf-16" => {
            const slice = text[from_index..to_index];
            if (slice.len >= 64) {
                const line_count = std.mem.countScalar(u8, slice, '\n');
                const relevant_slice = if (line_count == 0) slice else blk: {
                    result.line += @intCast(line_count);
                    result.character = 0;
                    break :blk slice[std.mem.findScalarLast(u8, slice, '\n').? + 1 ..];
                };
                result.character += @intCast(countUtf16Units(relevant_slice));
            } else for (slice) |c| {
                if (c == '\n') {
                    result.line += 1;
                    result.character = 0;
                } else if (c < 0x80) {
                    result.character += 1;
                } else if (c >= 0xF0) {
                    result.character += 2;
                } else if (c >= 0xC0) {
                    result.character += 1;
                }
            }
        },
        .@"utf-32" => {
            const slice = text[from_index..to_index];
            if (slice.len >= 64) {
                const line_count = std.mem.countScalar(u8, slice, '\n');
                const relevant_slice = if (line_count == 0) slice else blk: {
                    result.line += @intCast(line_count);
                    result.character = 0;
                    break :blk slice[std.mem.findScalarLast(u8, slice, '\n').? + 1 ..];
                };
                // No newlines remain, so the codepoint count can be vectorized.
                var characters: usize = 0;
                for (relevant_slice) |c| characters += @intFromBool(c < 0x80 or c >= 0xC0);
                result.character += @intCast(characters);
            } else for (slice) |c| {
                if (c == '\n') {
                    result.line += 1;
                    result.character = 0;
                } else if (c < 0x80 or c >= 0xC0) {
                    result.character += 1;
                }
            }
        },
    }
    return result;
}

// The caller has already removed newlines. Count UTF-8 leading bytes, with an
// extra unit for the surrogate pair used by each four-byte sequence.
fn countUtf16Units(text: []const u8) usize {
    var units: usize = 0;
    var index: usize = 0;
    if (@import("builtin").zig_backend == .stage2_llvm) {
        if (std.simd.suggestVectorLength(u8)) |block_size| {
            const Block = @Vector(block_size, u8);
            while (text.len - index >= block_size) : (index += block_size) {
                const bytes: Block = text[index..][0..block_size].*;
                const continuations = bytes & @as(Block, @splat(0xC0)) == @as(Block, @splat(0x80));
                const supplementary = bytes >= @as(Block, @splat(0xF0));
                units += block_size;
                units -= std.simd.countTrues(continuations);
                units += std.simd.countTrues(supplementary);
            }
        }
    }
    // Handle the tail and targets without SIMD using the same byte counts.
    for (text[index..]) |c| {
        if (c < 0x80) {
            units += 1;
        } else if (c >= 0xF0) {
            units += 2;
        } else if (c >= 0xC0) {
            units += 1;
        }
    }
    return units;
}

test advancePosition {
    try testAdvancePositionBoundaries("a¶↉🠁\r\nxy\n🇺🇸 end");

    const long_text = "a" ** 62 ++ "\n" ++ "b" ** 64 ++ "\ntrailer";
    inline for (.{ 63, 64, 65, 127, 128, long_text.len }) |to_index| {
        inline for (.{ Encoding.@"utf-8", Encoding.@"utf-16", Encoding.@"utf-32" }) |encoding| {
            const expected = offsets.advancePosition(long_text, .{ .line = 0, .character = 0 }, 0, to_index, encoding);
            const actual = advancePosition(long_text, .{ .line = 0, .character = 0 }, 0, to_index, encoding);
            try std.testing.expectEqual(expected, actual);
        }
    }
}

test "advancePosition long Unicode spans" {
    try testAdvancePositionBoundaries("a" ** 64 ++ "\ntrailer¶↉🠁");
    try testAdvancePositionBoundaries("¶↉🠁" ** 16 ++ "end");
    try testAdvancePositionBoundaries("prefix¶\r\n" ++ "¶↉🠁\r\n" ** 16 ++ "end🇺🇸");
    try testAdvancePositionBoundaries("prefix¶\r\n" ++ "¶↉🠁" ** 24 ++ "\n🠁end");
    try testAdvancePositionBoundaries("¶\n" ++ "\n" ** 64 ++ "\r\n🠁\n");
    try testAdvancePositionBoundaries("\x7F\u{80}\u{7FF}\u{800}\u{D7FF}\u{E000}\u{FFFF}\u{10000}\u{10FFFF}" ** 4);
}

fn testAdvancePositionBoundaries(comptime text: []const u8) !void {
    var boundaries: [text.len + 1]usize = undefined;
    var boundary_count: usize = 1;
    boundaries[0] = 0;
    var index: usize = 0;
    while (index < text.len) {
        index += std.unicode.utf8ByteSequenceLength(text[index]) catch unreachable;
        boundaries[boundary_count] = index;
        boundary_count += 1;
    }

    inline for (.{ Encoding.@"utf-8", Encoding.@"utf-16", Encoding.@"utf-32" }) |encoding| {
        for (boundaries[0..boundary_count], 0..) |from_index, from_boundary| {
            const from_position = offsets.indexToPosition(text, from_index, encoding);
            for (boundaries[from_boundary..boundary_count]) |to_index| {
                const expected = offsets.advancePosition(text, from_position, from_index, to_index, encoding);
                const actual = advancePosition(text, from_position, from_index, to_index, encoding);
                try std.testing.expectEqual(expected, actual);
            }
        }
    }
}
