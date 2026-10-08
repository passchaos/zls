//! The subset of Zig 0.16 AstRlAnnotate needed when interpreting an expression
//! with a known result pointer. Unlike the compiler pass, this also works on
//! intact expressions in a document with unrelated parse errors.
const std = @import("std");
const ast = @import("../ast.zig");
const offsets = @import("../offsets.zig");
const Ast = std.zig.Ast;

pub fn needsPointer(tree: *const Ast, node: Ast.Node.Index) ?bool {
    var scanner: Scanner = .{ .tree = tree };
    return scanner.consumes(node, 0);
}

const Scanner = struct {
    tree: *const Ast,
    remaining: usize = 65536,

    fn enter(self: *Scanner, depth: usize) bool {
        if (depth == 256 or self.remaining == 0) return false;
        self.remaining -= 1;
        return true;
    }

    fn consumes(self: *Scanner, node: Ast.Node.Index, depth: usize) ?bool {
        if (!self.enter(depth)) return null;
        const tree = self.tree;
        var buffer: [2]Ast.Node.Index = undefined;
        if (tree.fullArrayInit(&buffer, node)) |init| return init.ast.type_expr == .none;
        if (tree.fullStructInit(&buffer, node)) |init| return init.ast.type_expr == .none and init.ast.fields.len != 0;
        if (tree.blockStatements(&buffer, node) != null) {
            const label = ast.blockLabel(tree, node) orelse return false;
            return self.breaks(node, label, false, 0, depth + 1);
        }
        return switch (tree.nodeTag(node)) {
            .grouped_expression => self.consumes(tree.nodeData(node).node_and_token[0], depth + 1),
            .@"comptime", .@"nosuspend" => self.consumes(tree.nodeData(node).node, depth + 1),
            .if_simple, .@"if" => blk: {
                const branch = ast.fullIf(tree, node) orelse return null;
                const alternative = branch.ast.else_expr.unwrap() orelse return false;
                if (self.consumes(branch.ast.then_expr, depth + 1) orelse return null) break :blk true;
                break :blk self.consumes(alternative, depth + 1);
            },
            .@"orelse", .@"catch" => self.consumes(tree.nodeData(node).node_and_node[1], depth + 1),
            .for_simple, .@"for" => blk: {
                const loop = ast.fullFor(tree, node) orelse return null;
                if (self.breaks(loop.ast.then_expr, loop.label_token, true, 0, depth + 1) orelse return null) break :blk true;
                break :blk if (loop.ast.else_expr.unwrap()) |alternative| self.consumes(alternative, depth + 1) else false;
            },
            .while_simple, .while_cont, .@"while" => blk: {
                const loop = ast.fullWhile(tree, node) orelse return null;
                if (self.breaks(loop.ast.then_expr, loop.label_token, true, 0, depth + 1) orelse return null) break :blk true;
                if (loop.ast.cont_expr.unwrap()) |continuation| {
                    if (self.breaks(continuation, loop.label_token, true, 0, depth + 1) orelse return null) break :blk true;
                }
                break :blk if (loop.ast.else_expr.unwrap()) |alternative| self.consumes(alternative, depth + 1) else false;
            },
            .@"switch", .switch_comma => blk: {
                const switch_node = tree.switchFull(node);
                for (switch_node.ast.cases) |case| {
                    const target = tree.fullSwitchCase(case).?.ast.target_expr;
                    if (self.consumes(target, depth + 1) orelse return null) break :blk true;
                    if (switch_node.label_token) |label| {
                        if (self.breaks(target, label, false, 0, depth + 1) orelse return null) break :blk true;
                    }
                }
                break :blk false;
            },
            // Calls, casts and explicitly typed initializers materialize a value.
            else => false,
        };
    }

    fn breaks(self: *Scanner, node: Ast.Node.Index, label: ?Ast.TokenIndex, is_loop: bool, nested_loops: usize, depth: usize) ?bool {
        if (!self.enter(depth)) return null;
        const tree = self.tree;
        if (ast.isContainer(tree, node) or tree.nodeTag(node) == .fn_decl) return false;
        switch (tree.nodeTag(node)) {
            .@"break" => {
                const target, const operand = tree.nodeData(node).opt_token_and_opt_node;
                const matches = if (target.unwrap()) |target_label|
                    if (label) |label_token| std.mem.eql(u8, offsets.identifierTokenToNameSlice(tree, label_token), offsets.identifierTokenToNameSlice(tree, target_label)) else false
                else
                    is_loop and nested_loops == 0;
                if (matches) if (operand.unwrap()) |expression| {
                    if (self.consumes(expression, depth + 1) orelse return null) return true;
                };
            },
            .for_simple, .@"for" => {
                const loop = ast.fullFor(tree, node) orelse return null;
                for (loop.ast.inputs) |input| {
                    if (self.breaks(input, label, is_loop, nested_loops, depth + 1) orelse return null) return true;
                }
                if (self.breaks(loop.ast.then_expr, label, is_loop, nested_loops + 1, depth + 1) orelse return null) return true;
                return if (loop.ast.else_expr.unwrap()) |alternative| self.breaks(alternative, label, is_loop, nested_loops, depth + 1) else false;
            },
            .while_simple, .while_cont, .@"while" => {
                const loop = ast.fullWhile(tree, node) orelse return null;
                if (self.breaks(loop.ast.cond_expr, label, is_loop, nested_loops, depth + 1) orelse return null) return true;
                if (self.breaks(loop.ast.then_expr, label, is_loop, nested_loops + 1, depth + 1) orelse return null) return true;
                if (loop.ast.cont_expr.unwrap()) |continuation| {
                    if (self.breaks(continuation, label, is_loop, nested_loops + 1, depth + 1) orelse return null) return true;
                }
                return if (loop.ast.else_expr.unwrap()) |alternative| self.breaks(alternative, label, is_loop, nested_loops, depth + 1) else false;
            },
            else => {},
        }
        var iterator: ast.Iterator = .init(tree, node);
        while (iterator.next(tree)) |child| {
            if (self.breaks(child, label, is_loop, nested_loops, depth + 1) orelse return null) return true;
        }
        return false;
    }
};
