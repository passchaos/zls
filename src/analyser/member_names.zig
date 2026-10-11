//! Member names passed as strings to reflection builtins.
const std = @import("std");
const Ast = std.zig.Ast;
const Analyser = @import("../analysis.zig");
const ast = @import("../ast.zig");
const offsets = @import("../offsets.zig");
const Handle = @import("../DocumentStore.zig").Handle;

pub const Context = struct {
    container: ?Analyser.Type,
    content: offsets.Loc,
    fields: bool,
    declarations: bool,
    allow_unresolved: bool,
};

pub fn context(analyser: *Analyser, handle: *Handle, source_index: usize) Analyser.Error!?Context {
    const tree = &handle.tree;
    const nodes = try ast.nodesOverlappingIndexIncludingParseErrors(analyser.arena, tree, source_index);
    for (nodes) |node| {
        var buffer: [2]Ast.Node.Index = undefined;
        const params = tree.builtinCallParams(&buffer, node) orelse continue;
        if (params.len < 2 or tree.nodeTag(params[1]) != .string_literal) continue;
        const loc = offsets.nodeToLoc(tree, params[1]);
        if (source_index <= loc.start or source_index >= loc.end) continue;
        const builtin = tree.tokenSlice(tree.nodeMainToken(node));
        const declarations = std.mem.eql(u8, builtin, "@hasDecl") or std.mem.eql(u8, builtin, "@field");
        const fields = std.mem.eql(u8, builtin, "@field") or std.mem.eql(u8, builtin, "@hasField") or
            std.mem.eql(u8, builtin, "@FieldType") or std.mem.eql(u8, builtin, "@offsetOf") or
            std.mem.eql(u8, builtin, "@bitOffsetOf");
        if (!fields and !declarations) continue;
        const old_evaluate_values = analyser.evaluate_comptime_values;
        analyser.evaluate_comptime_values = true;
        defer analyser.evaluate_comptime_values = old_evaluate_values;
        return .{
            .container = try analyser.resolveTypeOfNode(.of(params[0], handle)),
            .content = .{ .start = loc.start + 1, .end = loc.end - 1 },
            .fields = fields,
            .declarations = declarations,
            .allow_unresolved = std.mem.eql(u8, builtin, "@hasDecl"),
        };
    }
    return null;
}

pub const Member = struct {
    name: []const u8,
    source: ?Analyser.TokenWithHandle,
    declaration: ?Analyser.DeclWithHandle,
    is_field: bool,
};

pub fn collect(analyser: *Analyser, handle: *Handle, info: Context) Analyser.Error![]const Member {
    var members: std.ArrayList(Member) = .empty;
    var concrete = false;
    if (info.container) |container| {
        for (try container.getAllTypesWithHandles(analyser)) |possible| {
            const ty = if (possible.is_type_val) possible else try possible.typeOf(analyser);
            if (ty.data == .container or (ty.ipIndex() != null and ty.isStructType(analyser))) concrete = true;
            if (info.fields) {
                if (try analyser.metaFieldNames(ty)) |names| for (names) |name| {
                    try members.append(analyser.arena, .{
                        .name = name,
                        .source = try Analyser.field_sources.source(analyser, ty, name),
                        .declaration = try analyser.lookupSymbolContainer(ty, name, .field),
                        .is_field = true,
                    });
                };
            }
            if (info.declarations) {
                var declarations: std.ArrayList(Analyser.DeclWithHandle) = .empty;
                try analyser.collectDeclarationsOfContainer(ty, handle, false, &declarations);
                for (declarations.items) |declaration| {
                    if (declaration.decl == .ast_node and declaration.handle.tree.nodeTag(declaration.decl.ast_node).isContainerField()) continue;
                    const token = declaration.nameToken();
                    const name = try analyser.identifierTokenName(&declaration.handle.tree, token) orelse continue;
                    try members.append(analyser.arena, .{
                        .name = name,
                        .source = .{ .handle = declaration.handle, .token = token },
                        .declaration = declaration,
                        .is_field = false,
                    });
                }
            }
        }
    }
    // An unresolved generic @hasDecl guard can refer to declarations of any
    // local subject type. Keep the same candidates available in its string.
    if (!concrete and info.allow_unresolved) {
        const scope = try handle.getDocumentScope();
        for (0..scope.declarations.len) |index| {
            const declaration = scope.declarations.get(index);
            if (declaration != .ast_node or handle.tree.nodeTag(declaration.ast_node).isContainerField()) continue;
            const token = declaration.nameToken(&handle.tree);
            const parent = Analyser.innermostScopeAtIndex(scope, handle.tree.tokenStart(token));
            if (parent == .root or !scope.getScopeTag(parent).isContainer()) continue;
            const name = try analyser.identifierTokenName(&handle.tree, token) orelse continue;
            try members.append(analyser.arena, .{
                .name = name,
                .source = .{ .handle = handle, .token = token },
                .declaration = .{ .handle = handle, .decl = declaration },
                .is_field = false,
            });
        }
    }
    return members.items;
}
