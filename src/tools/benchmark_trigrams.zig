//! Run with `zig build bench-trigrams -Doptimize=ReleaseFast -- [declarations] [rounds]`.
//! Compare identical sizes, options, result counts, and checksums across revisions.
const std = @import("std");
const TrigramStore = @import("zls").TrigramStore;

const default_declaration_count = 8192;
const default_rounds = 256;
const sample_count = 9;

const Case = struct {
    name: []const u8,
    query: []const u8,
    expected_count: usize,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    if (args.len >= 2 and std.mem.eql(u8, args[1], "--files")) {
        if (args.len == 2) return usage();
        for (args[2..]) |path| try benchmarkFile(io, allocator, path);
        return;
    }
    if (args.len > 3) return usage();

    const declaration_count = if (args.len >= 2)
        std.fmt.parseInt(usize, args[1], 10) catch return usage()
    else
        default_declaration_count;
    const rounds = if (args.len >= 3)
        std.fmt.parseInt(usize, args[2], 10) catch return usage()
    else
        default_rounds;
    if (declaration_count == 0 or rounds == 0) return usage();

    var source_writer: std.Io.Writer.Allocating = .init(allocator);
    defer source_writer.deinit();
    for (0..declaration_count) |index| {
        try source_writer.writer.print("const common_symbol_{d} = 0;\n", .{index});
    }
    try source_writer.writer.writeAll(
        "const common_symbol_unique_tail = 0;\n" ++
            "const unique_tail_common_symbol = 0;\n",
    );
    for (0..declaration_count) |index| {
        try source_writer.writer.print("const equal_posting_{d}_abcde = 0;\n", .{index});
    }
    for (0..declaration_count) |index| {
        try source_writer.writer.print("const repeated_aaaaaaaaaaaaaaaaaaaa_{d} = 0;\n", .{index});
    }
    for (0..declaration_count) |index| {
        try source_writer.writer.print("const periodic_abcabcabcabcabcabcabc_{d} = 0;\n", .{index});
    }
    try source_writer.writer.writeAll(
        "const equal_posting_abcd_only = 0;\n" ++
            "const equal_posting_cde_only = 0;\n",
    );
    const source = try source_writer.toOwnedSliceSentinel(0);
    defer allocator.free(source);

    const parse_ns = try measureParse(io, allocator, source);
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) return error.InvalidGeneratedSource;
    const init_ns = try measureStoreInit(io, allocator, &tree);
    var store = try TrigramStore.init(allocator, &tree);
    defer store.deinit(allocator);

    const cases = [_]Case{
        .{ .name = "common", .query = "common_symbol", .expected_count = declaration_count + 2 },
        .{ .name = "late-selective", .query = "common_symbol_unique_tail", .expected_count = 1 },
        .{ .name = "early-selective", .query = "unique_tail_common_symbol", .expected_count = 1 },
        .{ .name = "equal-near-miss", .query = "abcde", .expected_count = declaration_count },
        .{ .name = "short-repeated-hit", .query = "aaaaaaaa", .expected_count = declaration_count },
        .{ .name = "repeated-hit", .query = "aaaaaaaaaaaaaaaaaaaa", .expected_count = declaration_count },
        .{ .name = "periodic-hit", .query = "abcabcabcabcabcabcabc", .expected_count = declaration_count },
        .{ .name = "repeated", .query = "common_symbol_common_symbol_unique_tail", .expected_count = 0 },
        .{ .name = "missing", .query = "common_symbol_missing_tail", .expected_count = 0 },
    };

    std.debug.print(
        "{d} generated declarations, {d} source bytes, parse={d} ns init={d} ns, {d} rounds per query sample\n",
        .{ 4 * declaration_count + 4, source.len, parse_ns, init_ns, rounds },
    );
    for (cases) |case| try benchmarkCase(io, allocator, &store, case, rounds);
}

fn benchmarkFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    const source = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        allocator,
        .limited(std.zig.max_src_size),
        .of(u8),
        0,
    );
    defer allocator.free(source);

    const parse_ns = try measureParse(io, allocator, source);
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) return error.InvalidZigSource;
    const init_ns = try measureStoreInit(io, allocator, &tree);
    var store = try TrigramStore.init(allocator, &tree);
    defer store.deinit(allocator);
    const stats = store.statistics();
    std.debug.print(
        "{s}: {d} bytes parse={d} ns init={d} ns declarations={d} trigrams={d} postings={d} singleton={d} pair={d} filtered={d} longest={d} filter-bytes={d}\n",
        .{
            path,
            source.len,
            parse_ns,
            init_ns,
            stats.declarations,
            stats.trigrams,
            stats.postings,
            stats.singleton_postings,
            stats.pair_postings,
            stats.filtered_postings,
            stats.longest_posting,
            stats.filter_bytes,
        },
    );
}

fn measureParse(io: std.Io, allocator: std.mem.Allocator, source: [:0]const u8) !u64 {
    var samples: [sample_count]u64 = undefined;
    for (&samples) |*sample| {
        const before = std.Io.Clock.awake.now(io);
        var tree = try std.zig.Ast.parse(allocator, source, .zig);
        sample.* = @intCast(before.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds());
        defer tree.deinit(allocator);
        if (tree.errors.len != 0) return error.InvalidGeneratedSource;
        std.mem.doNotOptimizeAway(&tree);
    }
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    return samples[sample_count / 2];
}

fn measureStoreInit(io: std.Io, allocator: std.mem.Allocator, tree: *const std.zig.Ast) !u64 {
    var samples: [sample_count]u64 = undefined;
    for (&samples) |*sample| {
        const before = std.Io.Clock.awake.now(io);
        var store = try TrigramStore.init(allocator, tree);
        sample.* = @intCast(before.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds());
        defer store.deinit(allocator);
        std.mem.doNotOptimizeAway(&store);
    }
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    return samples[sample_count / 2];
}

fn usage() error{InvalidArguments} {
    std.debug.print(
        "Usage: zig build bench-trigrams -Doptimize=ReleaseFast -- [declarations] [rounds]\n" ++
            "       zig build bench-trigrams -Doptimize=ReleaseFast -- --files file.zig ...\n",
        .{},
    );
    return error.InvalidArguments;
}

fn benchmarkCase(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: *const TrigramStore,
    case: Case,
    rounds: usize,
) !void {
    var prepared = try TrigramStore.Query.init(allocator, case.query);
    defer prepared.deinit(allocator);
    var raw_buffer: std.ArrayList(TrigramStore.Declaration.Index) = .empty;
    defer raw_buffer.deinit(allocator);
    var prepared_buffer: std.ArrayList(TrigramStore.Declaration.Index) = .empty;
    defer prepared_buffer.deinit(allocator);

    const raw = try store.declarationSliceForQuery(allocator, case.query, &raw_buffer);
    const prepared_result = try store.declarationSliceForPreparedQuery(allocator, &prepared, &prepared_buffer);
    if (raw.len != case.expected_count) return error.UnexpectedResultCount;
    if (!std.mem.eql(TrigramStore.Declaration.Index, raw, prepared_result)) return error.ResultMismatch;
    const expected_checksum = checksum(raw);

    const raw_ns, const raw_sum = try measureRaw(io, allocator, store, case.query, rounds);
    const prepared_ns, const prepared_sum = try measurePrepared(io, allocator, store, &prepared, rounds);
    const transient_ns, const transient_sum = try measureTransientPrepared(io, allocator, store, case.query, rounds);
    if (raw_sum != prepared_sum or raw_sum != transient_sum or
        raw_sum != expected_checksum *% rounds *% sample_count)
    {
        return error.UnstableChecksum;
    }
    std.debug.print(
        "  {s}: {d} results raw={d} ns/query prepared={d} ns/query transient={d} ns/query checksum={d}\n",
        .{ case.name, raw.len, raw_ns, prepared_ns, transient_ns, raw_sum },
    );
}

fn measureRaw(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: *const TrigramStore,
    query: []const u8,
    rounds: usize,
) !struct { u64, u64 } {
    var buffer: std.ArrayList(TrigramStore.Declaration.Index) = .empty;
    defer buffer.deinit(allocator);
    var samples: [sample_count]u64 = undefined;
    var sum: u64 = 0;
    for (&samples) |*sample| {
        const before = std.Io.Clock.awake.now(io);
        for (0..rounds) |_| {
            buffer.clearRetainingCapacity();
            const result = try store.declarationSliceForQuery(allocator, query, &buffer);
            sum +%= checksum(result);
            std.mem.doNotOptimizeAway(result.ptr);
        }
        sample.* = @intCast(before.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds());
    }
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    return .{ samples[sample_count / 2] / rounds, sum };
}

fn measurePrepared(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: *const TrigramStore,
    query: *const TrigramStore.Query,
    rounds: usize,
) !struct { u64, u64 } {
    var buffer: std.ArrayList(TrigramStore.Declaration.Index) = .empty;
    defer buffer.deinit(allocator);
    var samples: [sample_count]u64 = undefined;
    var sum: u64 = 0;
    for (&samples) |*sample| {
        const before = std.Io.Clock.awake.now(io);
        for (0..rounds) |_| {
            buffer.clearRetainingCapacity();
            const result = try store.declarationSliceForPreparedQuery(allocator, query, &buffer);
            sum +%= checksum(result);
            std.mem.doNotOptimizeAway(result.ptr);
        }
        sample.* = @intCast(before.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds());
    }
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    return .{ samples[sample_count / 2] / rounds, sum };
}

fn measureTransientPrepared(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: *const TrigramStore,
    text: []const u8,
    rounds: usize,
) !struct { u64, u64 } {
    var buffer: std.ArrayList(TrigramStore.Declaration.Index) = .empty;
    defer buffer.deinit(allocator);
    var samples: [sample_count]u64 = undefined;
    var sum: u64 = 0;
    for (&samples) |*sample| {
        const before = std.Io.Clock.awake.now(io);
        for (0..rounds) |_| {
            var query = try TrigramStore.Query.init(allocator, text);
            defer query.deinit(allocator);
            buffer.clearRetainingCapacity();
            const result = try store.declarationSliceForPreparedQuery(allocator, &query, &buffer);
            sum +%= checksum(result);
            std.mem.doNotOptimizeAway(result.ptr);
        }
        sample.* = @intCast(before.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds());
    }
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    return .{ samples[sample_count / 2] / rounds, sum };
}

fn checksum(declarations: []const TrigramStore.Declaration.Index) u64 {
    var result: u64 = declarations.len;
    for (declarations) |declaration| result +%= @intFromEnum(declaration) + 1;
    return result;
}
