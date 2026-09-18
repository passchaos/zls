//! Implementation of [`textDocument/selectionRange`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_selectionRange)

const std = @import("std");
const Ast = std.zig.Ast;

const DocumentStore = @import("../DocumentStore.zig");
const ast = @import("../ast.zig");
const types = @import("lsp").types;
const offsets = @import("../offsets.zig");

const Mapping = offsets.multiple.IndexToPositionMapping;
const stack_mapping_capacity = 64;
const stack_mapping_bytes = stack_mapping_capacity * @sizeOf(Mapping) + @alignOf(Mapping) - 1;

pub fn generateSelectionRanges(
    arena: std.mem.Allocator,
    handle: *DocumentStore.Handle,
    positions: []const types.Position,
    offset_encoding: offsets.Encoding,
) error{OutOfMemory}!?[]types.SelectionRange {
    const tree = &handle.tree;
    var mapping_allocator_state = std.heap.stackFallback(stack_mapping_bytes, arena);
    const mapping_allocator = mapping_allocator_state.get();
    var mappings: std.ArrayList(Mapping) = .empty;
    defer mappings.deinit(mapping_allocator);
    try mappings.ensureTotalCapacityPrecise(mapping_allocator, stack_mapping_capacity);
    const result = try arena.alloc(types.SelectionRange, positions.len);
    for (positions, result) |position, *root_selection_range| {
        const source_index = offsets.positionToIndex(handle.tree.source, position, offset_encoding);

        var stack: std.ArrayList(struct { Ast.Node.Index, offsets.Loc }) = .empty;
        var walker: ast.Walker = try .init(arena, tree, .root);
        defer walker.deinit(arena);
        while (try walker.next(arena, tree)) |event| {
            switch (event) {
                .open => |node| {
                    const loc = offsets.nodeToLoc(tree, node);
                    if (loc.start <= source_index and source_index <= loc.end) {
                        try stack.append(arena, .{ node, loc });
                    } else {
                        walker.skip();
                    }
                },
                .close => break,
            }
        }

        var builder: Builder = .init(root_selection_range, &mappings, mapping_allocator);
        if (stack.items.len == 0) {
            try builder.add(arena, offsets.nodeToLoc(tree, .root));
            continue;
        }
        while (stack.pop()) |item| {
            const node = item[0];
            const loc = item[1];

            switch (tree.nodeTag(node)) {
                // Function parameters are not stored in the AST explicitly, iterate over them
                // manually.
                .fn_proto, .fn_proto_multi, .fn_proto_one, .fn_proto_simple => {
                    var buffer: [1]Ast.Node.Index = undefined;
                    const fn_proto = handle.tree.fullFnProto(&buffer, node).?;
                    var param_it: ast.FnParamIterator = .init(&fn_proto, &handle.tree);
                    while (param_it.next()) |param| {
                        const param_loc = ast.paramLoc(tree, param, true);
                        if (!(param_loc.start <= source_index and source_index <= param_loc.end)) continue;
                        try builder.add(arena, param_loc);
                        break;
                    }
                },
                else => {},
            }

            try builder.add(arena, loc);
        }
    }
    offsets.multiple.indexToPositionWithMappings(tree.source, mappings.items, offset_encoding);
    return result;
}

const Builder = struct {
    node: *types.SelectionRange,
    is_node_uninitalized: bool,
    mappings: *std.ArrayList(Mapping),
    mapping_allocator: std.mem.Allocator,

    // `add` must be called at least once afterwards to initalize `root_selection_range`.
    fn init(
        root_selection_range: *types.SelectionRange,
        mappings: *std.ArrayList(Mapping),
        mapping_allocator: std.mem.Allocator,
    ) Builder {
        root_selection_range.* = undefined;
        return .{
            .node = root_selection_range,
            .is_node_uninitalized = true,
            .mappings = mappings,
            .mapping_allocator = mapping_allocator,
        };
    }

    fn add(b: *Builder, arena: std.mem.Allocator, loc: offsets.Loc) error{OutOfMemory}!void {
        const new = if (b.is_node_uninitalized) b.node else try arena.create(types.SelectionRange);
        const current = if (b.is_node_uninitalized) null else b.node;
        new.* = .{
            .range = undefined, // set below
            .parent = null,
        };
        if (current) |c| c.parent = new;
        b.node = new;
        b.is_node_uninitalized = false;
        try b.mappings.appendSlice(b.mapping_allocator, &.{
            .{ .output = &new.range.start, .source_index = loc.start },
            .{ .output = &new.range.end, .source_index = loc.end },
        });
    }
};

test "selection range mappings stay on the stack through the common depth" {
    var mapping_allocator_state = std.heap.stackFallback(stack_mapping_bytes, std.testing.failing_allocator);
    const mapping_allocator = mapping_allocator_state.get();
    var mappings: std.ArrayList(Mapping) = .empty;
    defer mappings.deinit(mapping_allocator);
    try mappings.ensureTotalCapacityPrecise(mapping_allocator, stack_mapping_capacity);

    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var root: types.SelectionRange = undefined;
    var builder: Builder = .init(&root, &mappings, mapping_allocator);
    for (0..stack_mapping_capacity / 2) |index| {
        try builder.add(arena, .{ .start = index, .end = index + 1 });
    }
    try std.testing.expectEqual(stack_mapping_capacity, mappings.items.len);
    try std.testing.expectError(
        error.OutOfMemory,
        builder.add(arena, .{ .start = stack_mapping_capacity, .end = stack_mapping_capacity + 1 }),
    );
}
