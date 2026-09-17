//! Run with `zig build bench-trigrams -Doptimize=ReleaseFast -- [declarations] [rounds]`.
//! Compare identical sizes, options, result counts, and checksums across revisions.
const std = @import("std");
const TrigramStore = @import("zls").TrigramStore;

const default_declaration_count = 8192;
const default_rounds = 256;
const sample_count = 9;

const AllocationStats = struct {
    allocations: usize,
    resizes: usize,
    remaps: usize,
    frees: usize,
    requested_bytes: usize,
    peak_live_bytes: usize,
};

const CountingAllocator = struct {
    child: std.mem.Allocator,
    allocations: usize = 0,
    resizes: usize = 0,
    remaps: usize = 0,
    frees: usize = 0,
    requested_bytes: usize = 0,
    live_bytes: usize = 0,
    peak_live_bytes: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const result = self.child.rawAlloc(len, alignment, return_address) orelse return null;
        self.allocations += 1;
        self.requested_bytes += len;
        self.live_bytes += len;
        self.peak_live_bytes = @max(self.peak_live_bytes, self.live_bytes);
        return result;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        if (!self.child.rawResize(memory, alignment, new_len, return_address)) return false;
        self.resizes += 1;
        self.live_bytes = self.live_bytes - memory.len + new_len;
        self.peak_live_bytes = @max(self.peak_live_bytes, self.live_bytes);
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const result = self.child.rawRemap(memory, alignment, new_len, return_address) orelse return null;
        self.remaps += 1;
        self.live_bytes = self.live_bytes - memory.len + new_len;
        self.peak_live_bytes = @max(self.peak_live_bytes, self.live_bytes);
        return result;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.child.rawFree(memory, alignment, return_address);
        self.frees += 1;
        self.live_bytes -= memory.len;
    }

    fn stats(self: *const CountingAllocator) AllocationStats {
        return .{
            .allocations = self.allocations,
            .resizes = self.resizes,
            .remaps = self.remaps,
            .frees = self.frees,
            .requested_bytes = self.requested_bytes,
            .peak_live_bytes = self.peak_live_bytes,
        };
    }
};

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
            "const unique_tail_common_symbol = 0;\n" ++
            "const common_symbol_rare = 0;\n",
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
    for (0..declaration_count) |index| {
        try source_writer.writer.print("const left_xyz_{d} = 0;\n", .{index});
        try source_writer.writer.print("const right_yzq_{d} = 0;\n", .{index});
    }
    const partial_count = (declaration_count + 6) / 7;
    for (0..declaration_count) |index| {
        if (index % 7 == 0) {
            try source_writer.writer.print("const partial_pqrt_{d} = 0;\n", .{index});
        } else {
            try source_writer.writer.print("const partial_pqr_{d} = 0;\n", .{index});
            try source_writer.writer.print("const partial_qrt_{d} = 0;\n", .{index});
        }
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
        .{ .name = "common", .query = "common_symbol", .expected_count = declaration_count + 3 },
        .{ .name = "inline-late", .query = "common_symbol_rare", .expected_count = 1 },
        .{ .name = "late-selective", .query = "common_symbol_unique_tail", .expected_count = 1 },
        .{ .name = "early-selective", .query = "unique_tail_common_symbol", .expected_count = 1 },
        .{ .name = "equal-near-miss", .query = "abcde", .expected_count = declaration_count },
        .{ .name = "equal-disjoint", .query = "xyzq", .expected_count = 0 },
        .{ .name = "equal-partial", .query = "pqrt", .expected_count = partial_count },
        .{ .name = "short-repeated-hit", .query = "aaaaaaaa", .expected_count = declaration_count },
        .{ .name = "repeated-hit", .query = "aaaaaaaaaaaaaaaaaaaa", .expected_count = declaration_count },
        .{ .name = "periodic-hit", .query = "abcabcabcabcabcabcabc", .expected_count = declaration_count },
        .{ .name = "repeated", .query = "common_symbol_common_symbol_unique_tail", .expected_count = 0 },
        .{ .name = "missing", .query = "common_symbol_missing_tail", .expected_count = 0 },
    };

    std.debug.print(
        "{d} generated declarations, {d} source bytes, parse={d} ns init={d} ns, {d} rounds per query sample\n",
        .{ 8 * declaration_count + 5 - partial_count, source.len, parse_ns, init_ns, rounds },
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
    const allocation_stats = try measureStoreAllocations(allocator, &tree);
    var store = try TrigramStore.init(allocator, &tree);
    defer store.deinit(allocator);
    const stats = store.statistics();
    var missing_query_buffer: [64]u8 = undefined;
    missing_query_buffer[0] = @truncate(stats.longest_trigram);
    missing_query_buffer[1] = @truncate(stats.longest_trigram >> 8);
    missing_query_buffer[2] = @truncate(stats.longest_trigram >> 16);
    const missing_suffix = "__zls_missing_suffix";
    @memcpy(missing_query_buffer[3..][0..missing_suffix.len], missing_suffix);
    const missing_query = missing_query_buffer[0 .. 3 + missing_suffix.len];
    var missing_buffer: std.ArrayList(TrigramStore.Declaration.Index) = .empty;
    defer missing_buffer.deinit(allocator);
    const missing_result = try store.declarationSliceForQuery(allocator, missing_query, &missing_buffer);
    if (missing_result.len != 0) return error.UnexpectedResultCount;
    const missing_ns, const missing_sum = try measureRaw(io, allocator, &store, missing_query, 1024);
    if (missing_sum != 0) return error.UnstableChecksum;
    std.debug.print(
        "{s}: {d} bytes parse={d} ns init={d} ns longest-miss={d} ns allocs={d} resizes={d} remaps={d} frees={d} requested-bytes={d} peak-live-bytes={d} root-decls={d} declaration-hint={d} declarations={d} trigrams={d} postings={d} singleton={d} pair={d} filtered={d} longest={d} longest-trigram={X:0>6} filter-bytes={d}\n",
        .{
            path,
            source.len,
            parse_ns,
            init_ns,
            missing_ns,
            allocation_stats.allocations,
            allocation_stats.resizes,
            allocation_stats.remaps,
            allocation_stats.frees,
            allocation_stats.requested_bytes,
            allocation_stats.peak_live_bytes,
            tree.rootDecls().len,
            TrigramStore.estimatedDeclarationCapacity(&tree),
            stats.declarations,
            stats.trigrams,
            stats.postings,
            stats.singleton_postings,
            stats.pair_postings,
            stats.filtered_postings,
            stats.longest_posting,
            stats.longest_trigram,
            stats.filter_bytes,
        },
    );

    const query_rounds = 1024;
    for ([_][]const u8{ "allocator", "type", "parse" }) |query| {
        try benchmarkFileQuery(io, allocator, &store, query, query_rounds);
    }
}

fn benchmarkFileQuery(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: *const TrigramStore,
    text: []const u8,
    rounds: usize,
) !void {
    var query = try TrigramStore.Query.init(allocator, text);
    defer query.deinit(allocator);

    var raw_buffer: std.ArrayList(TrigramStore.Declaration.Index) = .empty;
    defer raw_buffer.deinit(allocator);
    const raw = try store.declarationSliceForQuery(allocator, text, &raw_buffer);
    var prepared_buffer: std.ArrayList(TrigramStore.Declaration.Index) = .empty;
    defer prepared_buffer.deinit(allocator);
    const prepared = try store.declarationSliceForPreparedQuery(allocator, &query, &prepared_buffer);
    if (!std.mem.eql(TrigramStore.Declaration.Index, raw, prepared)) return error.ResultMismatch;

    const expected_checksum = checksum(raw);
    const raw_ns, const raw_sum = try measureRaw(io, allocator, store, text, rounds);
    const prepared_ns, const prepared_sum = try measurePrepared(io, allocator, store, &query, rounds);
    if (raw_sum != prepared_sum or raw_sum != expected_checksum *% rounds *% sample_count) {
        return error.UnstableChecksum;
    }
    std.debug.print(
        "  query {s}: {d} results raw={d} ns/query prepared={d} ns/query checksum={d}\n",
        .{ text, raw.len, raw_ns, prepared_ns, raw_sum },
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

fn measureStoreAllocations(allocator: std.mem.Allocator, tree: *const std.zig.Ast) !AllocationStats {
    var counter: CountingAllocator = .{ .child = allocator };
    const counting_allocator = counter.allocator();
    var store = try TrigramStore.init(counting_allocator, tree);
    store.deinit(counting_allocator);
    if (counter.live_bytes != 0) return error.UnreleasedMemory;
    return counter.stats();
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
