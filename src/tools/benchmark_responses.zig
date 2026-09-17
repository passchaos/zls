//! Run with `zig build bench-responses -Doptimize=ReleaseFast -- [rounds] [large-symbol-count]`.
//! Compare identical response sizes, options, result counts, and checksums across revisions.
const std = @import("std");
const lsp = @import("zls").lsp;
const types = lsp.types;

const default_rounds = 128;
const default_large_symbol_count = 2048;
const sample_count = 9;

const AllocationStats = struct {
    allocations: usize,
    resizes: usize,
    remap_attempts: usize,
    remaps: usize,
    frees: usize,
    allocated_bytes: usize,
    peak_live_bytes: usize,
};

const CountingAllocator = struct {
    child: std.mem.Allocator,
    allocations: usize = 0,
    resizes: usize = 0,
    remap_attempts: usize = 0,
    remaps: usize = 0,
    frees: usize = 0,
    allocated_bytes: usize = 0,
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
        self.allocated_bytes += len;
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
        self.remap_attempts += 1;
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
            .remap_attempts = self.remap_attempts,
            .remaps = self.remaps,
            .frees = self.frees,
            .allocated_bytes = self.allocated_bytes,
            .peak_live_bytes = self.peak_live_bytes,
        };
    }
};

const Response = lsp.TypedJsonRPCResponse(types.workspace.Symbol.Result);

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    if (args.len > 3) return usage();

    const rounds = if (args.len >= 2)
        std.fmt.parseInt(usize, args[1], 10) catch return usage()
    else
        default_rounds;
    const large_symbol_count = if (args.len >= 3)
        std.fmt.parseInt(usize, args[2], 10) catch return usage()
    else
        default_large_symbol_count;
    if (rounds == 0 or large_symbol_count == 0) return usage();

    std.debug.print("{d} rounds per response sample, {d} samples\n", .{ rounds, sample_count });
    try benchmarkCase(io, allocator, "empty", 0, rounds);
    try benchmarkCase(io, allocator, "small", 8, rounds);
    try benchmarkCase(io, allocator, "large", large_symbol_count, rounds);
}

fn benchmarkCase(
    io: std.Io,
    allocator: std.mem.Allocator,
    name: []const u8,
    symbol_count: usize,
    rounds: usize,
) !void {
    const symbols = try allocator.alloc(types.workspace.Symbol, symbol_count);
    defer allocator.free(symbols);

    for (symbols, 0..) |*symbol, index| {
        const line: u32 = @intCast(index / 8);
        const character: u32 = @intCast(index % 8);
        symbol.* = .{
            .name = "representative_workspace_symbol",
            .kind = .Function,
            .location = .{ .location = .{
                .uri = "file:///workspace/src/representative.zig",
                .range = .{
                    .start = .{ .line = line, .character = character },
                    .end = .{ .line = line, .character = character + 31 },
                },
            } },
        };
    }

    const response: Response = .{
        .id = .{ .number = 1 },
        .result_or_error = .{ .result = .{ .workspace_symbols = symbols } },
    };

    const allocation_stats, const response_bytes = try measureAllocations(allocator, response);
    const time_ns, const checksum_value = try measureTime(io, allocator, response, rounds);
    const expected_checksum = response_bytes *% rounds *% sample_count;
    if (checksum_value != expected_checksum) return error.UnstableChecksum;

    std.debug.print(
        "{s}: {d} symbols, {d} bytes, {d} ns/response, checksum={d}\n" ++
            "  allocations={d} resizes={d} remap-attempts={d} remaps={d} frees={d} allocated={d} peak-live={d}\n",
        .{
            name,
            symbol_count,
            response_bytes,
            time_ns,
            checksum_value,
            allocation_stats.allocations,
            allocation_stats.resizes,
            allocation_stats.remap_attempts,
            allocation_stats.remaps,
            allocation_stats.frees,
            allocation_stats.allocated_bytes,
            allocation_stats.peak_live_bytes,
        },
    );
}

fn measureAllocations(allocator: std.mem.Allocator, response: Response) !struct { AllocationStats, usize } {
    var counter: CountingAllocator = .{ .child = allocator };
    const counting_allocator = counter.allocator();
    const json = try stringifyResponse(counting_allocator, response);
    const response_bytes = json.len;
    counting_allocator.free(json);
    if (counter.live_bytes != 0) return error.UnreleasedMemory;
    return .{ counter.stats(), response_bytes };
}

fn measureTime(io: std.Io, allocator: std.mem.Allocator, response: Response, rounds: usize) !struct { u64, usize } {
    var samples: [sample_count]u64 = undefined;
    var total_checksum: usize = 0;
    for (&samples) |*sample| {
        var checksum_value: usize = 0;
        const before = std.Io.Clock.awake.now(io);
        for (0..rounds) |_| {
            const json = try stringifyResponse(allocator, response);
            checksum_value +%= json.len;
            allocator.free(json);
        }
        const elapsed_ns = before.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds();
        sample.* = @intCast(@divTrunc(elapsed_ns, @as(i96, @intCast(rounds))));
        total_checksum +%= checksum_value;
    }
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    return .{ samples[sample_count / 2], total_checksum };
}

fn stringifyResponse(allocator: std.mem.Allocator, response: Response) error{OutOfMemory}![]u8 {
    return try std.json.Stringify.valueAlloc(allocator, response, .{
        .emit_null_optional_fields = false,
    });
}

fn usage() error{InvalidArguments} {
    std.debug.print(
        "Usage: zig build bench-responses -Doptimize=ReleaseFast -- [rounds] [large-symbol-count]\n",
        .{},
    );
    return error.InvalidArguments;
}
