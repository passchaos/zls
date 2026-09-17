//! Run with `zig build bench-responses -Doptimize=ReleaseFast -- [rounds] [large-symbol-count] [large-diagnostic-count]`.
//! Compare identical response sizes, options, result counts, and checksums across revisions.
const std = @import("std");
const zls = @import("zls");
const lsp = zls.lsp;
const types = lsp.types;

const default_rounds = 128;
const default_large_symbol_count = 2048;
const sample_count = 9;
const default_large_diagnostic_count = 512;

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

const WorkspaceResponse = lsp.TypedJsonRPCResponse(types.workspace.Symbol.Result);
const DiagnosticNotification = lsp.TypedJsonRPCNotification(types.publish_diagnostics.Params);
const SerializationMode = enum { standard, stack_prefix, capacity_hint };

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    if (args.len > 4) return usage();

    const rounds = if (args.len >= 2)
        std.fmt.parseInt(usize, args[1], 10) catch return usage()
    else
        default_rounds;
    const large_symbol_count = if (args.len >= 3)
        std.fmt.parseInt(usize, args[2], 10) catch return usage()
    else
        default_large_symbol_count;
    const large_diagnostic_count = if (args.len >= 4)
        std.fmt.parseInt(usize, args[3], 10) catch return usage()
    else
        default_large_diagnostic_count;
    if (rounds == 0 or large_symbol_count == 0 or large_diagnostic_count == 0) return usage();

    std.debug.print("{d} rounds per response sample, {d} samples\n", .{ rounds, sample_count });
    try benchmarkWorkspaceSymbols(io, allocator, "empty-standard", 0, rounds, .standard);
    try benchmarkWorkspaceSymbols(io, allocator, "empty-stack", 0, rounds, .stack_prefix);
    try benchmarkWorkspaceSymbols(io, allocator, "small-standard", 8, rounds, .standard);
    try benchmarkWorkspaceSymbols(io, allocator, "small-stack", 8, rounds, .stack_prefix);
    try benchmarkWorkspaceSymbols(io, allocator, "large-standard", large_symbol_count, rounds, .standard);
    try benchmarkWorkspaceSymbols(io, allocator, "large-stack", large_symbol_count, rounds, .stack_prefix);
    try benchmarkWorkspaceSymbols(io, allocator, "large-hinted", large_symbol_count, rounds, .capacity_hint);

    try benchmarkDiagnostics(io, allocator, "diagnostics-empty-standard", 0, rounds, .standard);
    try benchmarkDiagnostics(io, allocator, "diagnostics-empty-stack", 0, rounds, .stack_prefix);
    try benchmarkDiagnostics(io, allocator, "diagnostics-small-standard", 8, rounds, .standard);
    try benchmarkDiagnostics(io, allocator, "diagnostics-small-stack", 8, rounds, .stack_prefix);
    try benchmarkDiagnostics(io, allocator, "diagnostics-large-standard", large_diagnostic_count, rounds, .standard);
    try benchmarkDiagnostics(io, allocator, "diagnostics-large-stack", large_diagnostic_count, rounds, .stack_prefix);
}

fn benchmarkWorkspaceSymbols(
    io: std.Io,
    allocator: std.mem.Allocator,
    name: []const u8,
    symbol_count: usize,
    rounds: usize,
    mode: SerializationMode,
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

    const response: WorkspaceResponse = .{
        .id = .{ .number = 1 },
        .result_or_error = .{ .result = .{ .workspace_symbols = symbols } },
    };

    const allocation_stats, const response_bytes = try measureAllocations(WorkspaceSerialization, allocator, response, mode);
    const time_ns, const checksum_value = try measureTime(WorkspaceSerialization, io, allocator, response, rounds, mode);
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

fn benchmarkDiagnostics(
    io: std.Io,
    allocator: std.mem.Allocator,
    name: []const u8,
    diagnostic_count: usize,
    rounds: usize,
    mode: SerializationMode,
) !void {
    const diagnostics = try allocator.alloc(types.Diagnostic, diagnostic_count);
    defer allocator.free(diagnostics);
    const tags = [_]types.Diagnostic.Tag{.Unnecessary};
    const related = [_]types.Diagnostic.RelatedInformation{.{
        .location = .{
            .uri = "file:///workspace/src/related.zig",
            .range = .{
                .start = .{ .line = 17, .character = 8 },
                .end = .{ .line = 17, .character = 27 },
            },
        },
        .message = "symbol was originally declared here",
    }};

    for (diagnostics, 0..) |*diagnostic, index| {
        const line: u32 = @intCast(index);
        diagnostic.* = .{
            .range = .{
                .start = .{ .line = line, .character = 4 },
                .end = .{ .line = line, .character = 35 },
            },
            .severity = .Error,
            .code = .{ .string = "representative_error" },
            .source = "zls",
            .message = "representative diagnostic message with escaped \"content\"",
            .tags = if (index % 4 == 0) &tags else null,
            .relatedInformation = if (index % 4 == 0) &related else null,
        };
    }

    const notification: DiagnosticNotification = .{
        .method = "textDocument/publishDiagnostics",
        .params = .{
            .uri = "file:///workspace/src/representative.zig",
            .diagnostics = diagnostics,
        },
    };

    const allocation_stats, const response_bytes = try measureAllocations(DiagnosticSerialization, allocator, notification, mode);
    const time_ns, const checksum_value = try measureTime(DiagnosticSerialization, io, allocator, notification, rounds, mode);
    const expected_checksum = response_bytes *% rounds *% sample_count;
    if (checksum_value != expected_checksum) return error.UnstableChecksum;

    std.debug.print(
        "{s}: {d} diagnostics, {d} bytes, {d} ns/notification, checksum={d}\n" ++
            "  allocations={d} resizes={d} remap-attempts={d} remaps={d} frees={d} allocated={d} peak-live={d}\n",
        .{
            name,
            diagnostic_count,
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

const WorkspaceSerialization = struct {
    const Value = WorkspaceResponse;

    fn stringify(allocator: std.mem.Allocator, response: Value, mode: SerializationMode) error{OutOfMemory}![]u8 {
        return switch (mode) {
            .standard => try std.json.Stringify.valueAlloc(allocator, response, .{ .emit_null_optional_fields = false }),
            .stack_prefix => try zls.response_buffer.stringifyAlloc(allocator, response, .{ .emit_null_optional_fields = false }),
            .capacity_hint => try zls.response_buffer.stringifyAllocCapacity(
                allocator,
                response,
                .{ .emit_null_optional_fields = false },
                zls.response_buffer.workspaceSymbolCapacityHint(response.result_or_error.result),
            ),
        };
    }
};

const DiagnosticSerialization = struct {
    const Value = DiagnosticNotification;

    fn stringify(allocator: std.mem.Allocator, notification: Value, mode: SerializationMode) error{OutOfMemory}![]u8 {
        return switch (mode) {
            .standard => try std.json.Stringify.valueAlloc(allocator, notification, .{ .emit_null_optional_fields = false }),
            .stack_prefix => try zls.response_buffer.stringifyAlloc(allocator, notification, .{ .emit_null_optional_fields = false }),
            .capacity_hint => unreachable,
        };
    }
};

fn measureAllocations(
    comptime Serializer: type,
    allocator: std.mem.Allocator,
    value: Serializer.Value,
    mode: SerializationMode,
) !struct { AllocationStats, usize } {
    var counter: CountingAllocator = .{ .child = allocator };
    const counting_allocator = counter.allocator();
    const json = try Serializer.stringify(counting_allocator, value, mode);
    const response_bytes = json.len;
    counting_allocator.free(json);
    if (counter.live_bytes != 0) return error.UnreleasedMemory;
    return .{ counter.stats(), response_bytes };
}

fn measureTime(
    comptime Serializer: type,
    io: std.Io,
    allocator: std.mem.Allocator,
    value: Serializer.Value,
    rounds: usize,
    mode: SerializationMode,
) !struct { u64, usize } {
    var samples: [sample_count]u64 = undefined;
    var total_checksum: usize = 0;
    for (&samples) |*sample| {
        var checksum_value: usize = 0;
        const before = std.Io.Clock.awake.now(io);
        for (0..rounds) |_| {
            const json = try Serializer.stringify(allocator, value, mode);
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

fn usage() error{InvalidArguments} {
    std.debug.print(
        "Usage: zig build bench-responses -Doptimize=ReleaseFast -- [rounds] [large-symbol-count] [large-diagnostic-count]\n",
        .{},
    );
    return error.InvalidArguments;
}
