//! Implementation of [`textDocument/foldingRange`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_foldingRange)

const std = @import("std");
const Ast = std.zig.Ast;

const ast = @import("../ast.zig");
const types = @import("lsp").types;
const offsets = @import("../offsets.zig");
const tracy = @import("tracy");

const FoldingRange = struct {
    loc: offsets.Loc,
    kind: ?types.FoldingRange.Kind = null,
};

const PositionTarget = struct {
    source_index: u32,
    /// `result index * 2`, plus one for an end position.
    output_slot: u32,

    fn lessThan(_: void, lhs: PositionTarget, rhs: PositionTarget) bool {
        return lhs.source_index < rhs.source_index;
    }
};

const stack_mapping_capacity = 64;

comptime {
    std.debug.assert(@sizeOf(PositionTarget) == 8);
}

const Inclusivity = enum {
    /// Include the token itself as part of the folding range.
    inclusive,
    /// Do not include the token itself as part of the folding range.
    exclusive,
    /// Same as `exclusive` but will also not include any adjacent whitespace.
    exclusive_ignore_space,
};

/// Check if a node is an @import() call or an alias/field access based on an import.
/// This drills down field accesses to find the base, assuming identifiers are aliases.
fn isImportOrAlias(tree: *const Ast, init_node: Ast.Node.Index) bool {
    var node = init_node;
    while (true) {
        switch (tree.nodeTag(node)) {
            .builtin_call_two, .builtin_call_two_comma => {
                // Check if this is @import("...")
                const token = tree.nodeMainToken(node);
                const builtin_name = offsets.tokenToSlice(tree, token);
                if (!std.mem.eql(u8, builtin_name, "@import")) return false;

                const first_param, const second_param = tree.nodeData(node).opt_node_and_opt_node;
                const param_node = first_param.unwrap() orelse return false;
                if (second_param != .none) return false;
                return tree.nodeTag(param_node) == .string_literal;
            },
            .field_access => {
                // Field access like @import("foo").bar or std.ascii
                // Continue drilling down to check the left side
                node = tree.nodeData(node).node_and_token[0];
            },
            .identifier => {
                // Assume identifiers are aliases like `const ascii = std.ascii`
                return true;
            },
            else => return false,
        }
    }
}

const Builder = struct {
    allocator: std.mem.Allocator,
    locations: std.ArrayList(FoldingRange),
    tree: *const Ast,
    encoding: offsets.Encoding,

    fn deinit(builder: *Builder) void {
        builder.locations.deinit(builder.allocator);
    }

    fn add(
        builder: *Builder,
        kind: ?types.FoldingRange.Kind,
        start: Ast.TokenIndex,
        end: Ast.TokenIndex,
        start_reach: Inclusivity,
        end_reach: Inclusivity,
    ) error{OutOfMemory}!void {
        if (start >= end) return;
        if (builder.tree.tokensOnSameLine(start, end)) return;

        const start_index = switch (start_reach) {
            .inclusive => builder.tree.tokenStart(start),
            .exclusive => offsets.tokenToLoc(builder.tree, start).end,
            .exclusive_ignore_space => blk: {
                const start_index = offsets.tokenToLoc(builder.tree, start).end;
                const end_index = builder.tree.tokenStart(end);
                break :blk std.mem.findNonePos(u8, builder.tree.source[0..end_index], start_index, " \t") orelse end_index;
            },
        };

        const end_index = switch (end_reach) {
            .inclusive => offsets.tokenToLoc(builder.tree, end).end,
            .exclusive => builder.tree.tokenStart(end),
            .exclusive_ignore_space => std.mem.findLastNone(u8, builder.tree.source[0..builder.tree.tokenStart(end)], " \t") orelse 0,
        };

        std.debug.assert(start_index <= end_index);
        if (start_index == end_index) return;

        try builder.locations.append(builder.allocator, .{
            .loc = .{ .start = start_index, .end = end_index },
            .kind = kind,
        });
    }

    fn addNode(
        builder: *Builder,
        kind: ?types.FoldingRange.Kind,
        node: Ast.Node.Index,
        start_reach: Inclusivity,
        end_reach: Inclusivity,
    ) error{OutOfMemory}!void {
        try builder.add(kind, builder.tree.firstToken(node), ast.lastToken(builder.tree, node), start_reach, end_reach);
    }

    fn addCommentLoc(builder: *Builder, start: usize, end: usize) error{OutOfMemory}!void {
        if (std.mem.findScalar(u8, builder.tree.source[start..end], '\n') == null) return;
        try builder.locations.append(builder.allocator, .{
            .loc = .{ .start = start, .end = end },
            .kind = .comment,
        });
    }

    fn getRanges(builder: Builder) error{OutOfMemory}![]types.FoldingRange {
        const tracy_zone = tracy.trace(@src());
        defer tracy_zone.end();

        return convertRanges(
            builder.allocator,
            builder.tree.source,
            builder.locations.items,
            builder.encoding,
        );
    }
};

fn isDocumentComment(source: []const u8, comment_start: usize, comment_end: usize) bool {
    const comment = source[comment_start..comment_end];
    return std.mem.startsWith(u8, comment, "//!") or
        (std.mem.startsWith(u8, comment, "///") and !std.mem.startsWith(u8, comment, "////"));
}

fn isRegionComment(source: []const u8, comment_start: usize, comment_end: usize) bool {
    const comment = source[comment_start..comment_end];
    return std.mem.startsWith(u8, comment, "//#region") or
        std.mem.startsWith(u8, comment, "//#endregion");
}

fn addLineCommentRangesInTrivia(builder: *Builder, trivia_start: usize, trivia_end: usize) error{OutOfMemory}!void {
    const source = builder.tree.source;
    var group_start: ?usize = null;
    var group_end: usize = 0;
    var search_index = trivia_start;
    var line_start = if (std.mem.findLast(u8, source[0..trivia_start], "\n")) |newline| newline + 1 else 0;

    while (std.mem.findPos(u8, source[0..trivia_end], search_index, "//")) |comment_start| {
        if (std.mem.findLast(u8, source[search_index..comment_start], "\n")) |newline| {
            line_start = search_index + newline + 1;
        }
        const line_end_with_cr = std.mem.findScalarPos(u8, source[0..trivia_end], comment_start, '\n') orelse trivia_end;
        const comment_end = if (line_end_with_cr > comment_start and source[line_end_with_cr - 1] == '\r')
            line_end_with_cr - 1
        else
            line_end_with_cr;
        const is_full_line = std.mem.trim(u8, source[line_start..comment_start], " \t\r").len == 0;
        const is_foldable = is_full_line and
            !isDocumentComment(source, comment_start, comment_end) and
            !isRegionComment(source, comment_start, comment_end);

        if (!is_foldable) {
            if (group_start) |start| try builder.addCommentLoc(start, group_end);
            group_start = null;
        } else if (group_start) |start| {
            _ = start;
            const between = source[group_end..comment_start];
            if (std.mem.count(u8, between, "\n") != 1) {
                try builder.addCommentLoc(group_start.?, group_end);
                group_start = comment_start;
            }
            group_end = comment_end;
        } else {
            group_start = comment_start;
            group_end = comment_end;
        }

        search_index = line_end_with_cr + @intFromBool(line_end_with_cr < trivia_end);
        line_start = search_index;
    }

    if (group_start) |start| try builder.addCommentLoc(start, group_end);
}

fn addLineCommentRanges(builder: *Builder) error{OutOfMemory}!void {
    var trivia_start: usize = 0;
    for (0..builder.tree.tokens.len) |i| {
        const token: Ast.TokenIndex = @intCast(i);
        const token_start = builder.tree.tokenStart(token);
        try addLineCommentRangesInTrivia(builder, trivia_start, token_start);
        trivia_start = offsets.tokenToLoc(builder.tree, token).end;
    }
    try addLineCommentRangesInTrivia(builder, trivia_start, builder.tree.source.len);
}

fn convertRanges(
    allocator: std.mem.Allocator,
    source: []const u8,
    locations: []const FoldingRange,
    encoding: offsets.Encoding,
) error{OutOfMemory}![]types.FoldingRange {
    const mapping_count = std.math.mul(usize, locations.len, 2) catch return error.OutOfMemory;
    if (mapping_count > std.math.maxInt(u32)) return error.OutOfMemory;
    var stack_mappings: [stack_mapping_capacity]PositionTarget = undefined;
    const heap_mappings = if (mapping_count > stack_mappings.len)
        try allocator.alloc(PositionTarget, mapping_count)
    else
        null;
    defer if (heap_mappings) |mappings| allocator.free(mappings);
    const mappings = heap_mappings orelse stack_mappings[0..mapping_count];

    var results: std.ArrayList(types.FoldingRange) = try .initCapacity(allocator, locations.len);
    errdefer results.deinit(allocator);
    for (locations, 0..) |location, index| {
        const result = results.addOneAssumeCapacity();
        result.* = .{
            .startLine = undefined,
            .startCharacter = undefined,
            .endLine = undefined,
            .endCharacter = undefined,
            .kind = location.kind,
            // TODO this should be simplified https://codeberg.org/ziglang/zig/issues/30627
            .collapsedText = if (location.kind != null and location.kind.? == .imports) "@import(...)" else null,
        };
        mappings[2 * index + 0] = .{ .source_index = @intCast(location.loc.start), .output_slot = @intCast(2 * index + 0) };
        mappings[2 * index + 1] = .{ .source_index = @intCast(location.loc.end), .output_slot = @intCast(2 * index + 1) };
    }

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
        const output = &results.items[mapping.output_slot / 2];
        if (mapping.output_slot & 1 == 0) {
            output.startLine = position.line;
            output.startCharacter = position.character;
        } else {
            output.endLine = position.line;
            output.endCharacter = position.character;
        }
    }

    var result_count: usize = 0;
    for (results.items) |result| {
        if (result.startLine == result.endLine) continue;
        results.items[result_count] = result;
        result_count += 1;
    }
    results.shrinkRetainingCapacity(result_count);
    return try results.toOwnedSlice(allocator);
}

test "convert folding ranges uses one allocation for small batches" {
    const source = "one\ntwo\nthree";
    const locations = [_]FoldingRange{
        .{ .loc = .{ .start = 4, .end = source.len }, .kind = .region },
        .{ .loc = .{ .start = 0, .end = 3 } },
        .{ .loc = .{ .start = 0, .end = 7 }, .kind = .imports },
    };
    var failing_allocator: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 1 });
    const allocator = failing_allocator.allocator();
    const result = try convertRanges(allocator, source, &locations, .@"utf-16");
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 1), failing_allocator.allocations);
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqual(@as(u32, 1), result[0].startLine);
    try std.testing.expectEqual(@as(u32, 2), result[0].endLine);
    try std.testing.expectEqual(types.FoldingRange.Kind.region, result[0].kind.?);
    try std.testing.expectEqual(@as(u32, 0), result[1].startLine);
    try std.testing.expectEqual(@as(u32, 1), result[1].endLine);
    try std.testing.expectEqualStrings("@import(...)", result[1].collapsedText.?);
}

test "convert folding ranges uses two allocations for large batches" {
    const source = "a\n" ** 33;
    var locations: [33]FoldingRange = undefined;
    for (&locations, 0..) |*location, index| {
        location.* = .{ .loc = .{ .start = index * 2, .end = index * 2 + 2 } };
    }

    var failing_allocator: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 2 });
    const allocator = failing_allocator.allocator();
    const result = try convertRanges(allocator, source, &locations, .@"utf-16");
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 2), failing_allocator.allocations);
    try std.testing.expectEqual(locations.len, result.len);
    for (result, 0..) |range, index| {
        try std.testing.expectEqual(@as(u32, @intCast(index)), range.startLine);
        try std.testing.expectEqual(@as(u32, @intCast(index + 1)), range.endLine);
    }
}

pub fn generateFoldingRanges(allocator: std.mem.Allocator, tree: *const Ast, encoding: offsets.Encoding) error{OutOfMemory}![]types.FoldingRange {
    var builder: Builder = .{
        .allocator = allocator,
        .locations = .empty,
        .tree = tree,
        .encoding = encoding,
    };
    defer builder.deinit();

    var start_doc_comment: ?Ast.TokenIndex = null;
    var end_doc_comment: ?Ast.TokenIndex = null;
    for (0..tree.tokens.len) |i| {
        const token: Ast.TokenIndex = @intCast(i);
        switch (tree.tokenTag(token)) {
            .doc_comment,
            .container_doc_comment,
            => {
                if (start_doc_comment == null) {
                    start_doc_comment = token;
                    end_doc_comment = token;
                } else {
                    end_doc_comment = token;
                }
            },
            else => {
                if (start_doc_comment != null and end_doc_comment != null) {
                    try builder.add(.comment, start_doc_comment.?, end_doc_comment.?, .inclusive, .inclusive);
                    start_doc_comment = null;
                    end_doc_comment = null;
                }
            },
        }
    }

    try addLineCommentRanges(&builder);

    // Folding range for top level imports
    if (tree.mode == .zig) blk: {
        var start_import: ?Ast.Node.Index = null;
        var end_import: ?Ast.Node.Index = null;
        var import_count: usize = 0;

        const root_decls = tree.rootDecls();
        for (root_decls) |node| {
            const is_import = is_import: {
                if (tree.nodeTag(node) != .simple_var_decl) break :is_import false;
                const var_decl = tree.simpleVarDecl(node);
                const init_node = var_decl.ast.init_node.unwrap() orelse break :is_import false;

                break :is_import isImportOrAlias(tree, init_node);
            };

            if (is_import) {
                if (start_import == null) {
                    start_import = node;
                }
                end_import = node;
                import_count += 1;
                continue;
            }
            defer {
                start_import = null;
                end_import = null;
                import_count = 0;
            }

            const start = start_import orelse continue;
            const end = end_import orelse continue;
            if (import_count < 3) continue;
            try builder.add(.imports, tree.firstToken(start), ast.lastToken(tree, end) + 1, .inclusive, .inclusive);
        }

        // Handle the case where imports continue to the end of the file
        const start = start_import orelse break :blk;
        const end = end_import orelse break :blk;
        if (import_count < 3) break :blk;
        try builder.add(.imports, tree.firstToken(start), ast.lastToken(tree, end) + 1, .inclusive, .inclusive);
    }

    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @enumFromInt(i);

        switch (tree.nodeTag(node)) {
            .root => continue,

            .if_simple,
            .@"if",
            => {
                const if_node = ast.fullIf(tree, node).?;
                try builder.add(null, if_node.ast.if_token + 1, ast.lastToken(tree, if_node.ast.cond_expr), .exclusive, .inclusive);
            },
            .while_simple,
            .while_cont,
            .@"while",
            => {
                const while_node = ast.fullWhile(tree, node).?;
                try builder.add(null, while_node.ast.while_token + 1, ast.lastToken(tree, while_node.ast.cond_expr), .exclusive, .inclusive);
            },
            .for_simple,
            .@"for",
            => {
                const for_node = ast.fullFor(tree, node).?;
                try builder.add(null, for_node.ast.for_token + 1, ast.lastToken(tree, for_node.ast.inputs[for_node.ast.inputs.len - 1]), .exclusive, .inclusive);
            },

            .fn_proto,
            .fn_proto_multi,
            .fn_proto_one,
            .fn_proto_simple,
            // .fn_decl
            => {
                var buffer: [1]Ast.Node.Index = undefined;
                const fn_proto = tree.fullFnProto(&buffer, node).?;

                var last_param: ?Ast.full.FnProto.Param = null;
                var it: ast.FnParamIterator = .init(&fn_proto, tree);
                while (it.next()) |param| {
                    last_param = param;
                }

                const list_start_tok = fn_proto.lparen;
                const last_param_tok = ast.paramLastToken(tree, last_param orelse continue);
                const param_has_comma = last_param_tok + 1 < tree.tokens.len and tree.tokenTag(last_param_tok + 1) == .comma;
                const list_end_tok = last_param_tok + @intFromBool(param_has_comma);

                try builder.add(null, list_start_tok, list_end_tok, .exclusive, .inclusive);
            },

            .block_two,
            .block_two_semicolon,
            .block,
            .block_semicolon,
            => {
                try builder.addNode(null, node, .exclusive, .exclusive_ignore_space);
            },
            .@"switch",
            .switch_comma,
            => {
                const lhs = tree.nodeData(node).node_and_extra[0];
                const start_tok = ast.lastToken(tree, lhs) + 2; // lparen + rbrace
                const end_tok = ast.lastToken(tree, node);
                try builder.add(null, start_tok, end_tok, .exclusive, .exclusive_ignore_space);
            },

            .switch_case_one,
            .switch_case_inline_one,
            .switch_case,
            .switch_case_inline,
            => {
                const switch_case = tree.fullSwitchCase(node).?.ast;
                if (switch_case.values.len >= 4) {
                    const first_value = switch_case.values[0];
                    const last_value = switch_case.values[switch_case.values.len - 1];

                    const last_token = ast.lastToken(tree, last_value);
                    const last_value_has_comma = last_token + 1 < tree.tokens.len and tree.tokenTag(last_token + 1) == .comma;

                    const start_tok = tree.firstToken(first_value);
                    const end_tok = last_token + @intFromBool(last_value_has_comma);
                    try builder.add(null, start_tok, end_tok, .inclusive, .inclusive);
                }
            },

            .container_decl,
            .container_decl_trailing,
            .container_decl_arg,
            .container_decl_arg_trailing,
            .container_decl_two,
            .container_decl_two_trailing,
            .tagged_union,
            .tagged_union_trailing,
            .tagged_union_two,
            .tagged_union_two_trailing,
            .tagged_union_enum_tag,
            .tagged_union_enum_tag_trailing,
            => {
                var buffer: [2]Ast.Node.Index = undefined;
                const container_decl = tree.fullContainerDecl(&buffer, node).?;
                if (container_decl.ast.members.len != 0) {
                    const first_member = container_decl.ast.members[0];
                    var start_tok = tree.firstToken(first_member) -| 1;
                    while (start_tok != 0 and
                        (tree.tokenTag(start_tok) == .doc_comment or tree.tokenTag(start_tok) == .container_doc_comment))
                    {
                        start_tok -= 1;
                    }
                    const end_tok = ast.lastToken(tree, node);
                    try builder.add(null, start_tok, end_tok, .exclusive, .exclusive_ignore_space);
                } else { // no members (yet), ie `const T = type {};`
                    var start_tok = tree.firstToken(node);
                    while (tree.tokenTag(start_tok) != .l_brace) start_tok += 1;
                    const end_tok = ast.lastToken(tree, node);
                    try builder.add(null, start_tok, end_tok, .exclusive, .exclusive_ignore_space);
                }
            },

            .call,
            .call_comma,
            .call_one,
            .call_one_comma,
            .array_init,
            .array_init_one,
            .array_init_dot_two,
            .array_init_one_comma,
            .array_init_dot_two_comma,
            .array_init_dot,
            .array_init_dot_comma,
            .array_init_comma,
            .struct_init,
            .struct_init_one,
            .struct_init_one_comma,
            .struct_init_dot_two,
            .struct_init_dot_two_comma,
            .struct_init_dot,
            .struct_init_dot_comma,
            .struct_init_comma,
            => {
                const start = tree.nodeMainToken(node);
                try builder.add(null, start, ast.lastToken(tree, node), .exclusive, .exclusive_ignore_space);
            },
            .builtin_call,
            .builtin_call_comma,
            .builtin_call_two,
            .builtin_call_two_comma,
            .error_set_decl,
            => {
                const start = tree.nodeMainToken(node) + 1;
                try builder.add(null, start, ast.lastToken(tree, node), .exclusive, .exclusive_ignore_space);
            },

            .multiline_string_literal => {
                try builder.addNode(null, node, .inclusive, .inclusive);
            },

            else => {},
        }
    }

    // We add opened folding regions to a stack as we go and pop one off when we find a closing brace.
    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(allocator);

    var i: usize = 0;
    while (std.mem.findPos(u8, tree.source, i, "//#")) |possible_region| {
        i = possible_region + "//#".len;
        i = std.mem.findScalarPos(u8, tree.source, i, '\n') orelse tree.source.len;

        if (std.mem.startsWith(u8, tree.source[possible_region..], "//#region")) {
            try stack.append(allocator, possible_region);
        } else if (std.mem.startsWith(u8, tree.source[possible_region..], "//#endregion")) {
            const start_index = stack.pop() orelse break; // null means there are more endregions than regions
            try builder.locations.append(allocator, .{
                .loc = .{
                    .start = start_index,
                    .end = i,
                },
                .kind = .region,
            });
        }
    }

    return try builder.getRanges();
}
