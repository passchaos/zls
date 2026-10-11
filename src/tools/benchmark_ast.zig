//! Compare full node scanning with traversal of the enclosing AST branch.
//! Run with `zig build bench-ast -Doptimize=ReleaseSafe -- source.zig ...`.
const std = @import("std");
const zls = @import("zls");
const Ast = std.zig.Ast;
const offsets = zls.offsets;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    if (args.len < 2) return error.MissingSourceFile;
    for (args[1..]) |path| {
        const source = try std.Io.Dir.cwd().readFileAllocOptions(init.io, path, allocator, .limited(std.zig.max_src_size), .of(u8), 0);
        defer allocator.free(source);
        var tree = try Ast.parse(allocator, source, .zig);
        defer tree.deinit(allocator);
        if (tree.errors.len != 0) return error.InvalidZigSource;

        var positions: std.ArrayList(usize) = .empty;
        defer positions.deinit(allocator);
        const stride = @max(1, tree.tokens.len / 64);
        var next_token: usize = 0;
        for (tree.tokens.items(.tag), 0..) |tag, index| {
            if (index < next_token or tag != .identifier) continue;
            const loc = offsets.tokenToLoc(&tree, @intCast(index));
            try positions.append(allocator, loc.start + (loc.end - loc.start) / 2);
            next_token = index + stride;
        }
        if (positions.items.len == 0) return error.NoIdentifiers;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        for (positions.items) |position| {
            const scanned = try scan(arena.allocator(), &tree, position);
            const walked = try zls.ast.nodesOverlappingIndex(arena.allocator(), &tree, position);
            // The full scan can contain zero-width optional AST nodes that
            // are not part of the reachable tree. Identifier centers should
            // have the same concrete enclosing nodes and order in both paths.
            if (!std.mem.eql(Ast.Node.Index, scanned, walked)) return error.DifferentNodes;
            _ = arena.reset(.retain_capacity);
        }

        const rounds = 8;
        var scan_samples: [9]u64 = undefined;
        var walk_samples: [9]u64 = undefined;
        var checksum: u64 = 0;
        _ = try batch(.scan, &arena, &tree, positions.items, rounds);
        _ = try batch(.walk, &arena, &tree, positions.items, rounds);
        for (0..9) |sample| {
            // Alternate order in each pair, after the same warmup.
            for (0..2) |side| {
                const mode: Mode = if ((sample + side) % 2 == 0) .scan else .walk;
                const start = std.Io.Clock.awake.now(init.io);
                const sum = try batch(mode, &arena, &tree, positions.items, rounds);
                const elapsed: u64 = @intCast(start.durationTo(std.Io.Clock.awake.now(init.io)).toNanoseconds());
                std.mem.doNotOptimizeAway(sum);
                checksum +%= sum;
                (if (mode == .scan) &scan_samples else &walk_samples)[sample] = elapsed;
            }
        }
        std.mem.sort(u64, &scan_samples, {}, std.sort.asc(u64));
        std.mem.sort(u64, &walk_samples, {}, std.sort.asc(u64));
        const queries = rounds * positions.items.len;
        std.debug.print("{s}: nodes={d} queries={d} scan_ns={d} walk_ns={d} speedup={d:.2} checksum={d}\n", .{
            path,                                                                                tree.nodes.len, queries, scan_samples[4] / queries, walk_samples[4] / queries,
            @as(f64, @floatFromInt(scan_samples[4])) / @as(f64, @floatFromInt(walk_samples[4])), checksum,
        });
    }
}

const Mode = enum { scan, walk };

fn batch(mode: Mode, arena: *std.heap.ArenaAllocator, tree: *const Ast, positions: []const usize, rounds: usize) !u64 {
    var checksum: u64 = 0;
    for (0..rounds) |_| {
        for (positions) |position| {
            const nodes = switch (mode) {
                .scan => try scan(arena.allocator(), tree, position),
                .walk => try zls.ast.nodesOverlappingIndex(arena.allocator(), tree, position),
            };
            for (nodes) |node| checksum = checksum *% 31 +% @intFromEnum(node);
            _ = arena.reset(.retain_capacity);
        }
    }
    return checksum;
}

// Keep the full-scan baseline here so the comparison remains meaningful when
// production uses the reachable-tree fast path for valid documents.
fn scan(allocator: std.mem.Allocator, tree: *const Ast, position: usize) ![]Ast.Node.Index {
    const NodeLoc = struct {
        node: Ast.Node.Index,
        loc: offsets.Loc,
        fn lessThan(_: void, lhs: @This(), rhs: @This()) bool {
            const lhs_len = lhs.loc.end - lhs.loc.start;
            const rhs_len = rhs.loc.end - rhs.loc.start;
            if (lhs_len != rhs_len) return lhs_len < rhs_len;
            if (lhs.loc.start != rhs.loc.start) return lhs.loc.start > rhs.loc.start;
            if (lhs.node == .root or rhs.node == .root) return rhs.node == .root and lhs.node != .root;
            return @intFromEnum(lhs.node) < @intFromEnum(rhs.node);
        }
    };
    var found: std.ArrayList(NodeLoc) = .empty;
    defer found.deinit(allocator);
    for (0..tree.nodes.len) |index| {
        const node: Ast.Node.Index = @enumFromInt(index);
        const loc = offsets.nodeToLoc(tree, node);
        if (loc.start <= position and position <= loc.end) try found.append(allocator, .{ .node = node, .loc = loc });
    }
    std.mem.sort(NodeLoc, found.items, {}, NodeLoc.lessThan);
    const result = try allocator.alloc(Ast.Node.Index, found.items.len);
    for (result, found.items) |*node, item| node.* = item.node;
    return result;
}
