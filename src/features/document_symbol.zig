//! Implementation of [`textDocument/documentSymbol`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_documentSymbol)

const std = @import("std");
const Ast = std.zig.Ast;

const types = @import("lsp").types;
const offsets = @import("../offsets.zig");
const ast = @import("../ast.zig");
const analysis = @import("../analysis.zig");
const tracy = @import("tracy");

const Symbol = struct {
    name_token: Ast.TokenIndex,
    detail: ?[]const u8 = null,
    kind: types.SymbolKind,
    loc: offsets.Loc,
    selection_loc: offsets.Loc,
    children: std.ArrayList(Symbol),
};

const PositionTarget = struct {
    source_index: u32,
    /// `document symbol index * 4`, plus the position field index.
    output_slot: u32,

    fn lessThan(_: void, lhs: PositionTarget, rhs: PositionTarget) bool {
        return lhs.source_index < rhs.source_index;
    }
};

const stack_mapping_capacity = 64;

comptime {
    std.debug.assert(@sizeOf(PositionTarget) == 8);
}

pub fn tokenNameMaybeQuotes(tree: *const Ast, token: Ast.TokenIndex) []const u8 {
    return tokenNameFromSlice(tree.tokenSlice(token), tree.tokenTag(token));
}

pub fn tokenNameFromSlice(token_slice: []const u8, tag: std.zig.Token.Tag) []const u8 {
    switch (tag) {
        .identifier => return token_slice,
        .string_literal => {
            const name = token_slice[1 .. token_slice.len - 1];
            const trimmed = std.mem.trim(u8, name, &std.ascii.whitespace);
            // LSP spec requires that a symbol name not be empty or consisting only of whitespace,
            // don't trim the quotes in that case so there's something to present.
            // Leading and trailing whitespace might cause ambiguity depending on how the client shows symbols
            // so compensate for that as well
            if (name.len == 0 or name.len != trimmed.len)
                return token_slice;

            return name;
        },
        else => unreachable,
    }
}

test tokenNameFromSlice {
    try std.testing.expectEqualStrings("identifier", tokenNameFromSlice("identifier", .identifier));
    try std.testing.expectEqualStrings("quoted name", tokenNameFromSlice("\"quoted name\"", .string_literal));
    try std.testing.expectEqualStrings("\"\"", tokenNameFromSlice("\"\"", .string_literal));
    try std.testing.expectEqualStrings("\" padded \"", tokenNameFromSlice("\" padded \"", .string_literal));
}

pub fn getDocumentSymbols(
    arena: std.mem.Allocator,
    tree: *const Ast,
    encoding: offsets.Encoding,
) error{OutOfMemory}![]types.DocumentSymbol {
    var symbols: std.ArrayList(Symbol) = .empty;
    var total_symbol_count: usize = 0;

    const StackEntry = struct {
        current_symbols: *std.ArrayList(Symbol),
        last_var_decl_name_token: Ast.OptionalTokenIndex,
        parent_container: Ast.Node.Index,
    };
    var stack: std.ArrayList(StackEntry) = try .initCapacity(arena, 16);
    stack.appendAssumeCapacity(.{
        .current_symbols = &symbols,
        .last_var_decl_name_token = .none,
        .parent_container = .root,
    });

    var walker: ast.Walker = try .init(arena, tree, .root);
    defer walker.deinit(arena);
    while (try walker.next(arena, tree)) |event| {
        const node = switch (event) {
            .open => |node| node,
            .close => {
                stack.items.len -= 1;
                continue;
            },
        };

        try stack.append(arena, stack.getLast());
        const stack_entry: *StackEntry = &stack.items[stack.items.len - 1];

        const symbol: Symbol = switch (tree.nodeTag(node)) {
            .global_var_decl,
            .local_var_decl,
            .simple_var_decl,
            .aligned_var_decl,
            => blk: {
                if (!ast.isContainer(tree, walker.parentNode())) continue;

                const var_decl = tree.fullVarDecl(node).?;
                const var_decl_name_token = var_decl.ast.mut_token + 1;

                stack_entry.last_var_decl_name_token = .fromToken(var_decl_name_token);

                const kind: types.SymbolKind = switch (tree.tokenTag(tree.nodeMainToken(node))) {
                    .keyword_var => .Variable,
                    .keyword_const => .Constant,
                    else => unreachable,
                };

                break :blk .{
                    .name_token = var_decl_name_token,
                    .detail = null,
                    .kind = kind,
                    .loc = offsets.nodeToLoc(tree, node),
                    .selection_loc = offsets.tokenToLoc(tree, var_decl_name_token),
                    .children = .empty,
                };
            },

            .test_decl => blk: {
                const test_name_token = tree.nodeData(node).opt_token_and_node[0].unwrap() orelse continue;

                break :blk .{
                    .name_token = test_name_token,
                    .kind = .Method, // there is no SymbolKind that represents a tests
                    .loc = offsets.nodeToLoc(tree, node),
                    .selection_loc = offsets.tokenToLoc(tree, test_name_token),
                    .children = .empty,
                };
            },

            .fn_proto,
            .fn_proto_multi,
            .fn_proto_one,
            .fn_proto_simple,
            .fn_decl,
            => |tag| blk: {
                if (tag != .fn_decl and tree.nodeTag(walker.parentNode()) == .fn_decl) continue;
                var buffer: [1]Ast.Node.Index = undefined;
                const fn_info = tree.fullFnProto(&buffer, node).?;
                const name_token = fn_info.name_token orelse continue;

                break :blk .{
                    .name_token = name_token,
                    .detail = analysis.getFunctionSignature(tree, fn_info),
                    .kind = .Function,
                    .loc = offsets.nodeToLoc(tree, node),
                    .selection_loc = offsets.tokenToLoc(tree, name_token),
                    .children = .empty,
                };
            },

            .container_field_init,
            .container_field_align,
            .container_field,
            => blk: {
                const container_kind = switch (tree.nodeTag(stack_entry.parent_container)) {
                    .root => .keyword_struct,
                    .container_decl,
                    .container_decl_trailing,
                    .container_decl_arg,
                    .container_decl_arg_trailing,
                    .container_decl_two,
                    .container_decl_two_trailing,
                    => tree.tokenTag(tree.nodeMainToken(stack_entry.parent_container)),
                    .tagged_union,
                    .tagged_union_trailing,
                    .tagged_union_enum_tag,
                    .tagged_union_enum_tag_trailing,
                    .tagged_union_two,
                    .tagged_union_two_trailing,
                    => .keyword_union,
                    else => unreachable,
                };

                const kind: types.SymbolKind = switch (container_kind) {
                    .keyword_struct => .Field,
                    .keyword_union => .Field,
                    .keyword_enum => .EnumMember,
                    .keyword_opaque => continue,
                    else => unreachable,
                };

                var container_field = tree.fullContainerField(node).?;
                switch (container_kind) {
                    .keyword_struct => {},
                    .keyword_enum, .keyword_union => container_field.convertToNonTupleLike(tree),
                    else => unreachable,
                }
                if (container_field.ast.tuple_like) continue;

                const decl_name_token = container_field.ast.main_token;

                if (tree.tokenTag(decl_name_token) != .identifier) {
                    _ = ast.identifierTokenFromIdentifierNode; // possibly related
                    continue;
                }

                const guessed_container_name = if (stack_entry.last_var_decl_name_token.unwrap()) |name_token|
                    offsets.identifierTokenToNameSlice(tree, name_token)
                else
                    null;

                break :blk .{
                    .name_token = decl_name_token,
                    .detail = guessed_container_name,
                    .kind = kind,
                    .loc = offsets.nodeToLoc(tree, node),
                    .selection_loc = offsets.tokenToLoc(tree, decl_name_token),
                    .children = .empty,
                };
            },
            .container_decl,
            .container_decl_trailing,
            .container_decl_arg,
            .container_decl_arg_trailing,
            .container_decl_two,
            .container_decl_two_trailing,
            .tagged_union,
            .tagged_union_trailing,
            .tagged_union_enum_tag,
            .tagged_union_enum_tag_trailing,
            .tagged_union_two,
            .tagged_union_two_trailing,
            => {
                stack_entry.parent_container = node;
                continue;
            },
            else => continue,
        };

        switch (tree.tokenTag(symbol.name_token)) {
            .identifier, .string_literal => {},
            else => unreachable,
        }

        try stack_entry.current_symbols.append(arena, symbol);
        stack_entry.current_symbols = &stack_entry.current_symbols.items[stack_entry.current_symbols.items.len - 1].children;
        total_symbol_count += 1;
    }

    std.debug.assert(stack.items.len == 0);

    return try convertSymbols(
        arena,
        tree,
        symbols.items,
        total_symbol_count,
        encoding,
    );
}

/// converts `Symbol` to `types.DocumentSymbol`
fn convertSymbols(
    arena: std.mem.Allocator,
    tree: *const Ast,
    root_symbols: []const Symbol,
    total_symbol_count: usize,
    encoding: offsets.Encoding,
) error{OutOfMemory}![]types.DocumentSymbol {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    var symbol_buffer: std.ArrayList(types.DocumentSymbol) = .empty;
    try symbol_buffer.ensureTotalCapacityPrecise(arena, total_symbol_count);

    const mapping_count = std.math.mul(usize, total_symbol_count, 4) catch return error.OutOfMemory;
    if (mapping_count > std.math.maxInt(u32)) return error.OutOfMemory;
    var stack_mappings: [stack_mapping_capacity]PositionTarget = undefined;
    const heap_mappings = if (mapping_count > stack_mappings.len)
        try arena.alloc(PositionTarget, mapping_count)
    else
        null;
    defer if (heap_mappings) |mappings| arena.free(mappings);
    const mappings = heap_mappings orelse stack_mappings[0..mapping_count];
    var mapping_index: usize = 0;

    const root_document_symbols = symbol_buffer.addManyAsSliceAssumeCapacity(root_symbols.len);

    const QueueEntry = struct { symbols: []const Symbol, outputs: []types.DocumentSymbol, output_start: usize };
    var queue: std.ArrayList(QueueEntry) = .empty;
    defer queue.deinit(arena);
    try queue.append(arena, .{ .symbols = root_symbols, .outputs = root_document_symbols, .output_start = 0 });

    while (queue.pop()) |item| {
        for (item.symbols, item.outputs, 0..) |symbol, *document_symbol, sibling_index| {
            const symbol_children = symbol.children.items;
            const children_start = symbol_buffer.items.len;
            const document_symbol_children = symbol_buffer.addManyAsSliceAssumeCapacity(symbol_children.len);
            try queue.append(arena, .{
                .symbols = symbol_children,
                .outputs = document_symbol_children,
                .output_start = children_start,
            });

            document_symbol.* = .{
                .name = tokenNameMaybeQuotes(tree, symbol.name_token),
                .detail = symbol.detail,
                .kind = symbol.kind,
                // will be set later through the mapping below
                .range = undefined,
                .selectionRange = undefined,
                .children = document_symbol_children,
            };
            const output_slot: u32 = @intCast((item.output_start + sibling_index) * 4);
            mappings[mapping_index..][0..4].* = .{
                .{ .source_index = @intCast(symbol.loc.start), .output_slot = output_slot + 0 },
                .{ .source_index = @intCast(symbol.selection_loc.start), .output_slot = output_slot + 1 },
                .{ .source_index = @intCast(symbol.selection_loc.end), .output_slot = output_slot + 2 },
                .{ .source_index = @intCast(symbol.loc.end), .output_slot = output_slot + 3 },
            };
            mapping_index += 4;
        }
    }
    std.debug.assert(symbol_buffer.items.len == total_symbol_count);
    std.debug.assert(mapping_index == mappings.len);

    writePositions(tree.source, symbol_buffer.items, mappings, encoding);

    return root_document_symbols;
}

fn writePositions(
    source: []const u8,
    symbols: []types.DocumentSymbol,
    mappings: []PositionTarget,
    encoding: offsets.Encoding,
) void {
    if (!std.sort.isSorted(PositionTarget, mappings, {}, PositionTarget.lessThan)) {
        std.mem.sort(PositionTarget, mappings, {}, PositionTarget.lessThan);
    }

    var last_index: usize = 0;
    var last_position: offsets.Position = .{ .line = 0, .character = 0 };
    for (mappings) |mapping| {
        const source_index: usize = mapping.source_index;
        const position = offsets.advancePosition(source, last_position, last_index, source_index, encoding);
        last_index = source_index;
        last_position = position;

        const symbol = &symbols[mapping.output_slot / 4];
        switch (mapping.output_slot % 4) {
            0 => symbol.range.start = position,
            1 => symbol.selectionRange.start = position,
            2 => symbol.selectionRange.end = position,
            3 => symbol.range.end = position,
            else => unreachable,
        }
    }
}

test "convert document symbols uses stack mappings for small batches" {
    const source = "const foo = 1;";
    var tree = try Ast.parse(std.testing.allocator, source, .zig);
    defer tree.deinit(std.testing.allocator);

    const node = tree.rootDecls()[0];
    const name_token = tree.fullVarDecl(node).?.ast.mut_token + 1;
    const symbols = [_]Symbol{.{
        .name_token = name_token,
        .kind = .Constant,
        .loc = offsets.nodeToLoc(&tree, node),
        .selection_loc = offsets.tokenToLoc(&tree, name_token),
        .children = .empty,
    }};

    var failing_allocator: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 2 });
    const allocator = failing_allocator.allocator();
    const result = try convertSymbols(allocator, &tree, &symbols, symbols.len, .@"utf-16");
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 2), failing_allocator.allocations);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("foo", result[0].name);
    try std.testing.expectEqual(
        offsets.locToRange(source, symbols[0].loc, .@"utf-16"),
        result[0].range,
    );
    try std.testing.expectEqual(
        offsets.locToRange(source, symbols[0].selection_loc, .@"utf-16"),
        result[0].selectionRange,
    );
}
