//! Conservative names for a function and its syntactic const aliases.
const std = @import("std");
const Analyser = @import("../analysis.zig");
const Handle = @import("../DocumentStore.zig").Handle;

pub fn collect(analyser: *Analyser, target: Analyser.DeclWithHandle, handles: []const *Handle) Analyser.Error!std.BufSet {
    var names: std.BufSet = .init(analyser.arena);
    const target_name = try analyser.identifierTokenName(&target.handle.tree, target.nameToken()) orelse return names;
    try names.insert(target_name);

    var aliases: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
    for (handles) |handle| {
        const scope = try handle.getDocumentScope();
        const tree = &handle.tree;
        for (0..scope.declarations.len) |index| {
            const declaration = scope.declarations.get(index);
            if (declaration != .ast_node) continue;
            const variable = tree.fullVarDecl(declaration.ast_node) orelse continue;
            if (tree.tokenTag(variable.ast.mut_token) != .keyword_const) continue;
            const initializer = variable.ast.init_node.unwrap() orelse continue;
            const source_token = switch (tree.nodeTag(initializer)) {
                .identifier => tree.nodeMainToken(initializer),
                .field_access => tree.nodeData(initializer).node_and_token[1],
                else => continue,
            };
            const name = try analyser.identifierTokenName(tree, declaration.nameToken(tree)) orelse continue;
            const source = try analyser.identifierTokenName(tree, source_token) orelse continue;
            const aliases_of_source = try aliases.getOrPutValue(analyser.arena, source, .empty);
            try aliases_of_source.value_ptr.append(analyser.arena, name);
        }
    }
    // Names alone do not establish identity. This closure only removes calls
    // that cannot reach the target; normal declaration resolution still
    // distinguishes shadowed names and unrelated members with the same name.
    var pending: std.ArrayList([]const u8) = .empty;
    try pending.append(analyser.arena, target_name);
    var cursor: usize = 0;
    while (cursor < pending.items.len) : (cursor += 1) {
        const next = aliases.get(pending.items[cursor]) orelse continue;
        for (next.items) |name| {
            if (names.contains(name)) continue;
            try names.insert(name);
            try pending.append(analyser.arena, name);
        }
    }
    return names;
}
