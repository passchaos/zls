//! Run with `zig build bench-offsets -Doptimize=ReleaseFast -- file.zig ...`.
//! Compare identical inputs, compiler options, and checksums across revisions.
const std = @import("std");
const zls = @import("zls");
const offsets = zls.offsets;
const baseline_offsets = zls.lsp.offsets;

const PositionToIndexMode = enum { baseline, production };
const RangeToLocMode = enum { baseline, production };

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    if (args.len < 2) {
        std.debug.print("Usage: zig build bench-offsets -Doptimize=ReleaseFast -- file.zig ...\n", .{});
        return error.MissingSourceFile;
    }

    for (args[1..]) |path| {
        const source = try std.Io.Dir.cwd().readFileAllocOptions(io, path, allocator, .limited(std.zig.max_src_size), .of(u8), 0);
        defer allocator.free(source);
        var tree = try std.zig.Ast.parse(allocator, source, .zig);
        defer tree.deinit(allocator);
        if (tree.errors.len != 0) return error.InvalidZigSource;

        std.debug.print("{s}: {d} bytes, {d} tokens\n", .{ path, source.len, tree.tokens.len });
        const starts = tree.tokens.items(.start);
        for ([_]usize{ 1, 64, 1024 }) |stride| {
            for ([_]offsets.Encoding{ .@"utf-8", .@"utf-16", .@"utf-32" }) |encoding| {
                // Verify every measured endpoint against an independent UTF-8 decoder.
                try verify(source, starts, stride, encoding);
                _ = scan(source, starts, stride, encoding);
                const rounds = @max(1, (16 * 1024 * 1024) / @max(1, source.len));
                var samples: [7]u64 = undefined;
                var checksum: u64 = 0;
                for (&samples) |*sample| {
                    const before = std.Io.Clock.awake.now(io);
                    for (0..rounds) |_| {
                        std.mem.doNotOptimizeAway(source.ptr);
                        std.mem.doNotOptimizeAway(starts.ptr);
                        const sum = scan(source, starts, stride, encoding);
                        std.mem.doNotOptimizeAway(sum);
                        checksum +%= sum;
                    }
                    sample.* = @intCast(before.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds());
                }
                std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
                std.debug.print("  {t} stride={d}: {d} ns/scan checksum={d}\n", .{
                    encoding, stride, samples[samples.len / 2] / rounds, checksum,
                });
            }
        }

        try benchmarkPositionToIndex(io, allocator, path, source);
    }

    const long_line = try allocator.alloc(u8, 256 * 1024);
    defer allocator.free(long_line);
    @memset(long_line, 'a');
    try benchmarkPositionToIndex(io, allocator, "synthetic-long-line", long_line);

    const dense_newlines = try allocator.alloc(u8, 2 * 1024 * 1024);
    defer allocator.free(dense_newlines);
    @memset(dense_newlines, '\n');
    try benchmarkPositionToIndex(io, allocator, "synthetic-dense-newlines", dense_newlines);
}

fn benchmarkPositionToIndex(
    io: std.Io,
    allocator: std.mem.Allocator,
    name: []const u8,
    source: []const u8,
) !void {
    const query_count = 256;
    const positions = try allocator.alloc(offsets.Position, query_count);
    defer allocator.free(positions);
    std.debug.print("{s}: {d} bytes, {d} position queries\n", .{ name, source.len, positions.len });

    for ([_]offsets.Encoding{ .@"utf-8", .@"utf-16", .@"utf-32" }) |encoding| {
        for (positions, 0..) |*position, query_index| {
            const source_index = (source.len * query_index) / query_count;
            position.* = offsets.indexToPosition(source, source_index, encoding);
            if (offsets.positionToIndex(source, position.*, encoding) != baseline_offsets.positionToIndex(source, position.*, encoding)) {
                return error.PositionToIndexMismatch;
            }
        }

        inline for ([_]PositionToIndexMode{ .baseline, .production }) |mode| {
            var samples: [7]u64 = undefined;
            var checksum: usize = 0;
            for (&samples) |*sample| {
                const before = std.Io.Clock.awake.now(io);
                for (positions) |position| {
                    checksum +%= switch (mode) {
                        .baseline => baseline_offsets.positionToIndex(source, position, encoding),
                        .production => offsets.positionToIndex(source, position, encoding),
                    };
                }
                sample.* = @intCast(before.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds());
            }
            std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
            std.debug.print("  position-to-index {t} {t}: {d} ns/query checksum={d}\n", .{
                mode,
                encoding,
                samples[samples.len / 2] / positions.len,
                checksum,
            });
        }

        const ranges = try allocator.alloc(offsets.Range, positions.len);
        defer allocator.free(ranges);
        for (ranges, positions, 0..) |*range, start, query_index| {
            const end_index = @min(source.len, (source.len * query_index) / query_count + 32);
            range.* = .{
                .start = start,
                .end = offsets.indexToPosition(source, end_index, encoding),
            };
            const actual = offsets.rangeToLoc(source, range.*, encoding);
            const expected = baseline_offsets.rangeToLoc(source, range.*, encoding);
            if (actual.start != expected.start or actual.end != expected.end) return error.RangeToLocMismatch;
        }
        inline for ([_]RangeToLocMode{ .baseline, .production }) |mode| {
            var samples: [7]u64 = undefined;
            var checksum: usize = 0;
            for (&samples) |*sample| {
                const before = std.Io.Clock.awake.now(io);
                for (ranges) |range| {
                    const loc = switch (mode) {
                        .baseline => baseline_offsets.rangeToLoc(source, range, encoding),
                        .production => offsets.rangeToLoc(source, range, encoding),
                    };
                    checksum +%= loc.start + loc.end;
                }
                sample.* = @intCast(before.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds());
            }
            std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
            std.debug.print("  range-to-loc {t} {t}: {d} ns/query checksum={d}\n", .{
                mode,
                encoding,
                samples[samples.len / 2] / ranges.len,
                checksum,
            });
        }
    }
}

fn scan(source: []const u8, starts: []const u32, stride: usize, encoding: offsets.Encoding) u64 {
    var previous_index: usize = 0;
    var previous_position: offsets.Position = .{ .line = 0, .character = 0 };
    var checksum: u64 = 0;
    var token: usize = 0;
    while (token < starts.len) : (token += stride) {
        const index = starts[token];
        const position = offsets.advancePosition(source, previous_position, previous_index, index, encoding);
        checksum +%= (@as(u64, position.line) << 32) | position.character;
        previous_index = index;
        previous_position = position;
    }
    const end = offsets.advancePosition(source, previous_position, previous_index, source.len, encoding);
    return checksum +% ((@as(u64, end.line) << 32) | end.character);
}

fn verify(source: []const u8, starts: []const u32, stride: usize, encoding: offsets.Encoding) !void {
    var previous_index: usize = 0;
    var expected: offsets.Position = .{ .line = 0, .character = 0 };
    var actual = expected;
    var token: usize = 0;
    while (true) : (token += stride) {
        const index = if (token < starts.len) starts[token] else source.len;
        var iterator: std.unicode.Utf8Iterator = .{ .bytes = source[previous_index..index], .i = 0 };
        while (iterator.nextCodepoint()) |codepoint| {
            if (codepoint == '\n') {
                expected.line += 1;
                expected.character = 0;
            } else {
                expected.character += switch (encoding) {
                    .@"utf-8" => try std.unicode.utf8CodepointSequenceLength(codepoint),
                    .@"utf-16" => @as(u32, 1) + @intFromBool(codepoint >= 0x10000),
                    .@"utf-32" => 1,
                };
            }
        }
        actual = offsets.advancePosition(source, actual, previous_index, index, encoding);
        if (actual.line != expected.line or actual.character != expected.character) return error.PositionMismatch;
        previous_index = index;
        if (token >= starts.len) break;
    }
}
