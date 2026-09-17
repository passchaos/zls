//! Run with `zig build bench-message-parsing -Doptimize=ReleaseFast -- source.zig [rounds]`.
//! Compare identical inputs, options, checksums, and borrowed-field counts across revisions.
const std = @import("std");
const lsp = @import("zls").lsp;
const types = lsp.types;

const default_rounds = 16;
const sample_count = 9;

const RequestParams = union(enum) {
    @"workspace/symbol": types.workspace.Symbol.Params,
    other: lsp.MethodWithParams,
};

const NotificationParams = union(enum) {
    @"textDocument/didOpen": types.TextDocument.DidOpenParams,
    other: lsp.MethodWithParams,
};

const Message = lsp.Message(RequestParams, NotificationParams, .{});

const AllocationStats = struct {
    allocations: usize,
    remap_attempts: usize,
    remaps: usize,
    frees: usize,
    allocated_bytes: usize,
    peak_live_bytes: usize,
};

const CountingAllocator = struct {
    child: std.mem.Allocator,
    allocations: usize = 0,
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
            .remap_attempts = self.remap_attempts,
            .remaps = self.remaps,
            .frees = self.frees,
            .allocated_bytes = self.allocated_bytes,
            .peak_live_bytes = self.peak_live_bytes,
        };
    }
};

const ParseMode = enum { alloc_always, alloc_if_needed };

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    if (args.len < 2 or args.len > 3) return usage();

    const rounds = if (args.len == 3)
        std.fmt.parseInt(usize, args[2], 10) catch return usage()
    else
        default_rounds;
    if (rounds == 0) return usage();

    const source = try std.Io.Dir.cwd().readFileAlloc(io, args[1], allocator, .limited(std.zig.max_src_size));
    defer allocator.free(source);

    const workspace_json = try std.json.Stringify.valueAlloc(allocator, lsp.TypedJsonRPCRequest(types.workspace.Symbol.Params){
        .id = .{ .number = 1 },
        .method = "workspace/symbol",
        .params = .{ .query = "allocator" },
    }, .{});
    defer allocator.free(workspace_json);

    std.debug.print("{d} source bytes, {d} samples\n", .{ source.len, sample_count });
    try benchmarkCase(io, allocator, "workspace-symbol", workspace_json, rounds * 256, .alloc_always);
    try benchmarkCase(io, allocator, "workspace-symbol", workspace_json, rounds * 256, .alloc_if_needed);

    for ([_]usize{ 64, 256, 512, 1024, 4096, 64 * 1024, source.len }) |source_bytes| {
        const bounded_source = source[0..@min(source.len, source_bytes)];
        const did_open_json = try makeDidOpenJson(allocator, bounded_source);
        defer allocator.free(did_open_json);
        const case_rounds = @max(rounds, (rounds * source.len) / @max(1, bounded_source.len));
        try benchmarkCase(io, allocator, "did-open", did_open_json, case_rounds, .alloc_always);
        try benchmarkCase(io, allocator, "did-open", did_open_json, case_rounds, .alloc_if_needed);
    }
}

fn makeDidOpenJson(allocator: std.mem.Allocator, source: []const u8) error{OutOfMemory}![]u8 {
    return try std.json.Stringify.valueAlloc(allocator, lsp.TypedJsonRPCNotification(types.TextDocument.DidOpenParams){
        .method = "textDocument/didOpen",
        .params = .{ .textDocument = .{
            .uri = "file:///workspace/source.zig",
            .languageId = .{ .custom_value = "zig" },
            .version = 1,
            .text = source,
        } },
    }, .{});
}

fn benchmarkCase(
    io: std.Io,
    allocator: std.mem.Allocator,
    name: []const u8,
    input: []const u8,
    rounds: usize,
    mode: ParseMode,
) !void {
    const stats, const expected_checksum, const borrowed_fields = try measureAllocations(allocator, input, mode);
    var samples: [sample_count]u64 = undefined;
    var total_checksum: usize = 0;

    for (&samples) |*sample| {
        var checksum: usize = 0;
        const before = std.Io.Clock.awake.now(io);
        for (0..rounds) |_| checksum +%= try parseOnce(allocator, input, mode, null);
        const elapsed_ns = before.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds();
        sample.* = @intCast(@divTrunc(elapsed_ns, @as(i96, @intCast(rounds))));
        total_checksum +%= checksum;
    }
    if (total_checksum != expected_checksum *% rounds *% sample_count) return error.UnstableChecksum;
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));

    std.debug.print(
        "{s} {t}: {d} input bytes, {d} ns/message, {d} borrowed fields, checksum={d}\n" ++
            "  allocations={d} remap-attempts={d} remaps={d} frees={d} allocated={d} peak-live={d}\n",
        .{
            name,
            mode,
            input.len,
            samples[sample_count / 2],
            borrowed_fields,
            total_checksum,
            stats.allocations,
            stats.remap_attempts,
            stats.remaps,
            stats.frees,
            stats.allocated_bytes,
            stats.peak_live_bytes,
        },
    );
}

fn measureAllocations(allocator: std.mem.Allocator, input: []const u8, mode: ParseMode) !struct { AllocationStats, usize, usize } {
    var counter: CountingAllocator = .{ .child = allocator };
    var borrowed_fields: usize = 0;
    const checksum = try parseOnce(counter.allocator(), input, mode, &borrowed_fields);
    if (counter.live_bytes != 0) return error.UnreleasedMemory;
    return .{ counter.stats(), checksum, borrowed_fields };
}

fn parseOnce(
    allocator: std.mem.Allocator,
    input: []const u8,
    mode: ParseMode,
    borrowed_fields: ?*usize,
) !usize {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const message = try Message.parseFromSliceLeaky(arena.allocator(), input, .{
        .ignore_unknown_fields = true,
        .max_value_len = null,
        .allocate = switch (mode) {
            .alloc_always => .alloc_always,
            .alloc_if_needed => .alloc_if_needed,
        },
    });

    return switch (message) {
        .request => |request| switch (request.params) {
            .@"workspace/symbol" => |params| blk: {
                if (borrowed_fields) |count| count.* += @intFromBool(isBorrowed(input, params.query));
                break :blk params.query.len + @as(usize, @intCast(request.id.number));
            },
            .other => return error.UnexpectedMessage,
        },
        .notification => |notification| switch (notification.params) {
            .@"textDocument/didOpen" => |params| blk: {
                if (borrowed_fields) |count| {
                    count.* += @intFromBool(isBorrowed(input, params.textDocument.uri));
                    count.* += @intFromBool(isBorrowed(input, params.textDocument.text));
                }
                break :blk params.textDocument.uri.len + params.textDocument.text.len;
            },
            .other => return error.UnexpectedMessage,
        },
        .response => return error.UnexpectedMessage,
    };
}

fn isBorrowed(input: []const u8, value: []const u8) bool {
    const input_start = @intFromPtr(input.ptr);
    const value_start = @intFromPtr(value.ptr);
    return value_start >= input_start and value_start + value.len <= input_start + input.len;
}

fn usage() error{InvalidArguments} {
    std.debug.print("Usage: zig build bench-message-parsing -Doptimize=ReleaseFast -- source.zig [rounds]\n", .{});
    return error.InvalidArguments;
}
