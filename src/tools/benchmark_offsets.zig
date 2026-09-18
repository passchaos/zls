//! Run with `zig build bench-offsets -Doptimize=ReleaseFast -- file.zig ...`.
//! Compare identical inputs, compiler options, and checksums across revisions.
const std = @import("std");
const zls = @import("zls");
const offsets = zls.offsets;
const baseline_offsets = zls.lsp.offsets;

const PositionToIndexMode = enum { baseline, production };
const RangeToLocMode = enum { baseline, production };
const MultipleMode = enum { allocation_baseline, mapping_baseline, production };
const BatchOrder = enum { ordered, reversed, interleaved, last_swapped };
const stack_mapping_capacity = 64;

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
        try benchmarkMultipleConversions(io, allocator, path, source);
    }

    const long_line = try allocator.alloc(u8, 256 * 1024);
    defer allocator.free(long_line);
    @memset(long_line, 'a');
    try benchmarkPositionToIndex(io, allocator, "synthetic-long-line", long_line);

    const sparse_unicode_line = try allocator.alloc(u8, 67 * 4096);
    defer allocator.free(sparse_unicode_line);
    for (0..4096) |index| {
        const chunk = sparse_unicode_line[index * 67 ..][0..67];
        @memset(chunk[0..63], 'a');
        @memcpy(chunk[63..], "🠁");
    }
    try benchmarkPositionToIndex(io, allocator, "synthetic-sparse-unicode-line", sparse_unicode_line);

    const dense_newlines = try allocator.alloc(u8, 2 * 1024 * 1024);
    defer allocator.free(dense_newlines);
    @memset(dense_newlines, '\n');
    try benchmarkPositionToIndex(io, allocator, "synthetic-dense-newlines", dense_newlines);
}

fn benchmarkMultipleConversions(
    io: std.Io,
    allocator: std.mem.Allocator,
    name: []const u8,
    source: []const u8,
) !void {
    for ([_]usize{ 1, 8, 32, 64, 128 }) |range_count| {
        const indices = try allocator.alloc(usize, range_count);
        defer allocator.free(indices);
        const positions = try allocator.alloc(offsets.Position, range_count);
        defer allocator.free(positions);
        const locs = try allocator.alloc(offsets.Loc, range_count);
        defer allocator.free(locs);
        const ranges = try allocator.alloc(offsets.Range, range_count);
        defer allocator.free(ranges);
        inline for ([_]BatchOrder{ .ordered, .reversed, .interleaved, .last_swapped }) |order| {
            for (locs, indices, 0..) |*loc, *source_index, index| {
                const rank = switch (order) {
                    .ordered => index,
                    .reversed => range_count - index - 1,
                    .interleaved => (index * 5) % range_count,
                    .last_swapped => if (range_count < 2 or index < range_count - 2)
                        index
                    else
                        2 * range_count - index - 3,
                };
                const start = (source.len * rank) / range_count;
                loc.* = .{ .start = start, .end = @min(source.len, start + 32) };
                source_index.* = start;
            }

            const rounds = @max(1, (16 * 1024 * 1024) / @max(1, source.len));
            try benchmarkBatchLocToRange(io, allocator, name, source, locs, ranges, order, rounds);
            try benchmarkBatchIndexToPosition(io, allocator, name, source, indices, positions, order, rounds);
        }
    }
}

fn benchmarkBatchLocToRange(
    io: std.Io,
    allocator: std.mem.Allocator,
    name: []const u8,
    source: []const u8,
    locs: []const offsets.Loc,
    ranges: []offsets.Range,
    order: BatchOrder,
    rounds: usize,
) !void {
    inline for ([_]MultipleMode{ .allocation_baseline, .mapping_baseline, .production }) |mode| {
        var samples: [7]u64 = undefined;
        var checksum: u64 = 0;
        for (&samples) |*sample| {
            const before = std.Io.Clock.awake.now(io);
            for (0..rounds) |_| {
                switch (mode) {
                    .allocation_baseline => try multipleLocToRangeAllocationBaseline(allocator, source, locs, ranges, .@"utf-16"),
                    .mapping_baseline => try multipleLocToRangeMappingBaseline(allocator, source, locs, ranges, .@"utf-16"),
                    .production => try offsets.multiple.locToRange(allocator, source, locs, ranges, .@"utf-16"),
                }
                for (ranges) |range| {
                    checksum +%= (@as(u64, range.start.line) << 32) | range.start.character;
                    checksum +%= (@as(u64, range.end.line) << 32) | range.end.character;
                }
            }
            sample.* = @intCast(before.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds());
        }
        std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
        std.debug.print("{s}: batch-loc-to-range {t} {t} count={d}: {d} ns/batch checksum={d}\n", .{
            name, mode, order, locs.len, samples[samples.len / 2] / rounds, checksum,
        });
    }
}

fn benchmarkBatchIndexToPosition(
    io: std.Io,
    allocator: std.mem.Allocator,
    name: []const u8,
    source: []const u8,
    indices: []const usize,
    positions: []offsets.Position,
    order: BatchOrder,
    rounds: usize,
) !void {
    inline for ([_]MultipleMode{ .allocation_baseline, .mapping_baseline, .production }) |mode| {
        var samples: [7]u64 = undefined;
        var checksum: u64 = 0;
        for (&samples) |*sample| {
            const before = std.Io.Clock.awake.now(io);
            for (0..rounds) |_| {
                switch (mode) {
                    .allocation_baseline => try multipleIndexToPositionAllocationBaseline(allocator, source, indices, positions, .@"utf-16"),
                    .mapping_baseline => try multipleIndexToPositionMappingBaseline(allocator, source, indices, positions, .@"utf-16"),
                    .production => try offsets.multiple.indexToPosition(allocator, source, indices, positions, .@"utf-16"),
                }
                for (positions) |position| {
                    checksum +%= (@as(u64, position.line) << 32) | position.character;
                }
            }
            sample.* = @intCast(before.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds());
        }
        std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
        std.debug.print("{s}: batch-index-to-position {t} {t} count={d}: {d} ns/batch checksum={d}\n", .{
            name, mode, order, indices.len, samples[samples.len / 2] / rounds, checksum,
        });
    }
}

fn multipleIndexToPositionAllocationBaseline(
    allocator: std.mem.Allocator,
    text: []const u8,
    indices: []const usize,
    positions: []offsets.Position,
    encoding: offsets.Encoding,
) error{OutOfMemory}!void {
    const mappings = try allocator.alloc(offsets.multiple.IndexToPositionMapping, indices.len);
    defer allocator.free(mappings);

    for (mappings, indices, positions) |*mapping, index, *position| {
        mapping.* = .{ .output = position, .source_index = index };
    }
    indexToPositionWithMappingsBaseline(text, mappings, encoding);
}

fn multipleIndexToPositionMappingBaseline(
    allocator: std.mem.Allocator,
    text: []const u8,
    indices: []const usize,
    positions: []offsets.Position,
    encoding: offsets.Encoding,
) error{OutOfMemory}!void {
    var stack_mappings: [stack_mapping_capacity]offsets.multiple.IndexToPositionMapping = undefined;
    const heap_mappings = if (indices.len > stack_mappings.len)
        try allocator.alloc(offsets.multiple.IndexToPositionMapping, indices.len)
    else
        null;
    defer if (heap_mappings) |mappings| allocator.free(mappings);
    const mappings = heap_mappings orelse stack_mappings[0..indices.len];

    for (mappings, indices, positions) |*mapping, index, *position| {
        mapping.* = .{ .output = position, .source_index = index };
    }
    offsets.multiple.indexToPositionWithMappings(text, mappings, encoding);
}

fn multipleLocToRangeAllocationBaseline(
    allocator: std.mem.Allocator,
    text: []const u8,
    locs: []const offsets.Loc,
    ranges: []offsets.Range,
    encoding: offsets.Encoding,
) error{OutOfMemory}!void {
    const mappings = try allocator.alloc(offsets.multiple.IndexToPositionMapping, locs.len * 2);
    defer allocator.free(mappings);

    for (locs, ranges, 0..) |loc, *range, index| {
        mappings[2 * index + 0] = .{ .output = &range.start, .source_index = loc.start };
        mappings[2 * index + 1] = .{ .output = &range.end, .source_index = loc.end };
    }
    indexToPositionWithMappingsBaseline(text, mappings, encoding);
}

fn multipleLocToRangeMappingBaseline(
    allocator: std.mem.Allocator,
    text: []const u8,
    locs: []const offsets.Loc,
    ranges: []offsets.Range,
    encoding: offsets.Encoding,
) error{OutOfMemory}!void {
    const mapping_count = locs.len * 2;
    var stack_mappings: [stack_mapping_capacity]offsets.multiple.IndexToPositionMapping = undefined;
    const heap_mappings = if (mapping_count > stack_mappings.len)
        try allocator.alloc(offsets.multiple.IndexToPositionMapping, mapping_count)
    else
        null;
    defer if (heap_mappings) |mappings| allocator.free(mappings);
    const mappings = heap_mappings orelse stack_mappings[0..mapping_count];

    for (locs, ranges, 0..) |loc, *range, index| {
        mappings[2 * index + 0] = .{ .output = &range.start, .source_index = loc.start };
        mappings[2 * index + 1] = .{ .output = &range.end, .source_index = loc.end };
    }
    offsets.multiple.indexToPositionWithMappings(text, mappings, encoding);
}

fn indexToPositionWithMappingsBaseline(
    text: []const u8,
    mappings: []offsets.multiple.IndexToPositionMapping,
    encoding: offsets.Encoding,
) void {
    std.mem.sort(offsets.multiple.IndexToPositionMapping, mappings, {}, struct {
        fn lessThan(_: void, lhs: offsets.multiple.IndexToPositionMapping, rhs: offsets.multiple.IndexToPositionMapping) bool {
            return lhs.source_index < rhs.source_index;
        }
    }.lessThan);

    var last_index: usize = 0;
    var last_position: offsets.Position = .{ .line = 0, .character = 0 };
    for (mappings) |mapping| {
        const position = offsets.advancePosition(text, last_position, last_index, mapping.source_index, encoding);
        last_index = mapping.source_index;
        last_position = position;
        mapping.output.* = position;
    }
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
