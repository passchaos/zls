//! The ZLS analysis backend.
//!
//! The most frequently used functions are:
//! - `resolveTypeOfNode`
//! - `getPositionContext`
//! - `lookupSymbolGlobal`
//! - `lookupSymbolContainer`
//!

const builtin = @import("builtin");
const std = @import("std");
const DocumentStore = @import("DocumentStore.zig");
const Ast = std.zig.Ast;
const offsets = @import("offsets.zig");
const Uri = @import("Uri.zig");
const log = std.log.scoped(.analysis);
const ast = @import("ast.zig");
const tracy = @import("tracy");
const InternPool = @import("analyser/InternPool.zig");
const ErrorMsg = @import("analyser/error_msg.zig").ErrorMsg;
const references = @import("features/references.zig");

pub const DocumentScope = @import("DocumentScope.zig");
pub const Declaration = DocumentScope.Declaration;
pub const Scope = DocumentScope.Scope;

const version_data = @import("version_data");

const Analyser = @This();

gpa: std.mem.Allocator,
arena: std.mem.Allocator,
store: *DocumentStore,
ip: *InternPool,
resolved_callsites: std.AutoHashMapUnmanaged(Declaration.Param, ?Type) = .empty,
resolved_nodes: std.HashMapUnmanaged(NodeWithUri, ?Binding, NodeWithUri.Context, std.hash_map.default_max_load_percentage) = .empty,
resolved_values: std.HashMapUnmanaged(NodeWithUri, ?Binding, NodeWithUri.Context, std.hash_map.default_max_load_percentage) = .empty,
resolved_control_flow_values: std.HashMapUnmanaged(NodeWithUri, ?Binding, NodeWithUri.Context, std.hash_map.default_max_load_percentage) = .empty,
resolving_specialized_nodes: NodeSet = .empty,
collect_callsite_references: bool,
/// avoid unnecessarily parsing number literals
resolve_number_literal_values: bool,
/// Evaluate basic comptime expressions instead of preserving only their type.
evaluate_comptime_values: bool,
/// Select a known branch while evaluating comptime control flow.
evaluate_comptime_control_flow: bool,
/// Scoped bindings must survive recursive resolution without an explicit container.
generic_bindings: ?*const TokenToTypeMap,
/// handle of the doc where the request originated
root_handle: ?*DocumentStore.Handle,
max_conditional_combos: usize = 200,

const NodeSet = std.HashMapUnmanaged(NodeWithUri, void, NodeWithUri.Context, std.hash_map.default_max_load_percentage);

pub const Error = std.mem.Allocator.Error || std.Io.Cancelable;

pub fn init(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    store: *DocumentStore,
    ip: *InternPool,
    root_handle: ?*DocumentStore.Handle,
) Analyser {
    return .{
        .gpa = gpa,
        .arena = arena,
        .store = store,
        .ip = ip,
        .collect_callsite_references = true,
        .resolve_number_literal_values = false,
        .evaluate_comptime_values = false,
        .evaluate_comptime_control_flow = false,
        .generic_bindings = null,
        .root_handle = root_handle,
    };
}

pub fn deinit(self: *Analyser) void {
    self.resolved_callsites.deinit(self.gpa);
    self.resolved_nodes.deinit(self.gpa);
    self.resolved_values.deinit(self.gpa);
    self.resolved_control_flow_values.deinit(self.gpa);
    self.resolving_specialized_nodes.deinit(self.gpa);
}

fn allocType(analyser: *Analyser, ty: Type) error{OutOfMemory}!*Type {
    const ptr = try analyser.arena.create(Type);
    ptr.* = ty;
    return ptr;
}

pub fn getDocCommentsBeforeToken(allocator: std.mem.Allocator, tree: *const Ast, base: Ast.TokenIndex) error{OutOfMemory}!?[]const u8 {
    const doc_comment_index = getDocCommentTokenIndex(tree, base) orelse return null;
    return try collectDocComments(allocator, tree, doc_comment_index, false);
}

/// Gets a declaration's doc comments. Caller owns returned memory.
pub fn getDocComments(allocator: std.mem.Allocator, tree: *const Ast, node: Ast.Node.Index) error{OutOfMemory}!?[]const u8 {
    const base = tree.nodeMainToken(node);
    const base_kind = tree.nodeTag(node);

    switch (base_kind) {
        .root => return try collectDocComments(allocator, tree, 0, true),
        .fn_proto,
        .fn_proto_one,
        .fn_proto_simple,
        .fn_proto_multi,
        .fn_decl,
        .local_var_decl,
        .global_var_decl,
        .aligned_var_decl,
        .simple_var_decl,
        .container_field_init,
        .container_field_align,
        .container_field,
        => return try getDocCommentsBeforeToken(allocator, tree, base),
        else => {},
    }
    return null;
}

/// Get the first doc comment of a declaration.
pub fn getDocCommentTokenIndex(tree: *const Ast, base_token: Ast.TokenIndex) ?Ast.TokenIndex {
    var idx = base_token;
    if (idx == 0) return null;
    idx -|= 1;
    if (tree.tokenTag(idx) == .keyword_threadlocal and idx > 0) idx -|= 1;
    if (tree.tokenTag(idx) == .string_literal and idx > 1 and tree.tokenTag(idx -| 1) == .keyword_extern) idx -|= 1;
    if (tree.tokenTag(idx) == .keyword_extern and idx > 0) idx -|= 1;
    if (tree.tokenTag(idx) == .keyword_export and idx > 0) idx -|= 1;
    if (tree.tokenTag(idx) == .keyword_inline and idx > 0) idx -|= 1;
    if (tree.tokenTag(idx) == .identifier and idx > 0) idx -|= 1;
    if (tree.tokenTag(idx) == .keyword_pub and idx > 0) idx -|= 1;

    // Find first doc comment token
    if (!(tree.tokenTag(idx) == .doc_comment))
        return null;
    return while (tree.tokenTag(idx) == .doc_comment) {
        if (idx == 0) break 0;
        idx -|= 1;
    } else idx + 1;
}

pub fn collectDocComments(allocator: std.mem.Allocator, tree: *const Ast, doc_comments: Ast.TokenIndex, container_doc: bool) error{OutOfMemory}![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);

    var lines_start_with_space = true;

    var curr_line_tok = doc_comments;
    while (true) : (curr_line_tok += 1) {
        const comm = tree.tokenTag(curr_line_tok);
        if ((container_doc and comm == .container_doc_comment) or (!container_doc and comm == .doc_comment)) {
            const line = tree.tokenSlice(curr_line_tok)[3..];
            if (line.len > 1 and line[0] != ' ') lines_start_with_space = false;
            try lines.append(allocator, line);
        } else break;
    }

    // If all of the lines that aren't empty start with a space, remove the first space
    if (lines_start_with_space) {
        for (lines.items, 0..) |line, i| {
            if (line.len > 1 and line[0] == ' ') {
                lines.items[i] = line[1..];
            }
        }
    }

    return try std.mem.join(allocator, "\n", lines.items);
}

/// Gets a function's keyword, name, arguments and return value.
pub fn getFunctionSignature(tree: *const Ast, func: Ast.full.FnProto) []const u8 {
    const first_token = func.ast.fn_token;
    const last_token = if (func.ast.return_type.unwrap()) |return_type| ast.lastToken(tree, return_type) else first_token;
    return offsets.tokensToSlice(tree, first_token, last_token);
}

pub const FormatParameterOptions = struct {
    referenced: ?*ReferencedType.Set = null,
    info: Type.Data.Parameter,

    include_modifier: bool,
    include_name: bool,
    include_type: bool,
};

pub fn stringifyParameter(analyser: *Analyser, options: FormatParameterOptions) error{OutOfMemory}![]u8 {
    var aw: std.Io.Writer.Allocating = .init(analyser.arena);
    defer aw.deinit();
    analyser.rawStringifyParameter(&aw.writer, options) catch |err| switch (err) {
        error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
    };
    return try aw.toOwnedSlice();
}

fn rawStringifyParameter(
    analyser: *Analyser,
    writer: *std.Io.Writer,
    options: FormatParameterOptions,
) error{ OutOfMemory, WriteFailed }!void {
    const referenced = options.referenced;
    const info = options.info;
    const include_type_parameter_name =
        !options.include_name and options.include_type and info.name != null and info.type.isMetaType();
    const include_name = options.include_name or include_type_parameter_name;

    // Note that parameter doc comments are being skipped

    if (options.include_modifier) {
        if (info.modifier) |modifier| {
            switch (modifier) {
                // Type parameters are implicitly comptime. Function type
                // formatting keeps their name so dependent types remain
                // meaningful, making the explicit modifier redundant.
                .comptime_param => if (!include_type_parameter_name) try writer.writeAll("comptime "),
                .noalias_param => try writer.writeAll("noalias "),
            }
        }
    }

    if (include_name) {
        if (info.name) |name| {
            try writer.writeAll(name);
        }
    }

    if (options.include_type) {
        const has_parameter_name = include_name and info.name != null;
        if (has_parameter_name) try writer.writeAll(": ");

        try info.type.rawStringify(writer, analyser, .{
            .referenced = referenced,
            .truncate_container_decls = true,
        });
    }
}

pub const FormatFunctionOptions = struct {
    referenced: ?*ReferencedType.Set = null,
    info: Type.Data.Function,

    include_fn_keyword: bool,
    /// only included if available
    include_name: bool,
    override_name: ?[]const u8 = null,
    skip_first_param: bool = false,
    parameters: union(enum) {
        collapse,
        show: struct {
            include_modifiers: bool,
            include_names: bool,
            include_types: bool,
        },
    },
    include_return_type: bool,
    snippet_placeholders: bool,
};

pub fn stringifyFunction(analyser: *Analyser, options: FormatFunctionOptions) error{OutOfMemory}![]u8 {
    var aw: std.Io.Writer.Allocating = .init(analyser.arena);
    defer aw.deinit();
    analyser.rawStringifyFunction(&aw.writer, options) catch |err| switch (err) {
        error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
    };
    return try aw.toOwnedSlice();
}

fn rawStringifyFunction(
    analyser: *Analyser,
    writer: *std.Io.Writer,
    options: FormatFunctionOptions,
) error{ OutOfMemory, WriteFailed }!void {
    const referenced = options.referenced;
    const info = options.info;
    var parameters = info.parameters;

    var snippet_escaping_writer: SnippetEscapingWriter = .init(writer);
    const escaping_writer = if (options.snippet_placeholders) &snippet_escaping_writer.interface else writer;

    if (options.include_fn_keyword) {
        try writer.writeAll("fn ");
    }

    if (options.include_name) no_name: {
        const name = options.override_name orelse info.name orelse break :no_name;
        try escaping_writer.writeAll(name);
    }

    try writer.writeByte('(');

    if (options.skip_first_param) {
        if (parameters.len >= 1) {
            parameters = parameters[1..];
        }
    }

    switch (options.parameters) {
        .collapse => {
            const has_arguments = parameters.len != 0;
            if (has_arguments) {
                if (options.snippet_placeholders) {
                    try writer.writeAll("${1:...}");
                } else {
                    try writer.writeAll("...");
                }
            }
        },
        .show => |parameter_options| {
            for (parameters, 0..) |param_info, index| {
                if (index != 0) try writer.writeAll(", ");
                if (options.snippet_placeholders) {
                    try writer.print("${{{d}:", .{index + 1});
                }

                try analyser.rawStringifyParameter(escaping_writer, .{
                    .referenced = referenced,
                    .info = param_info,
                    .include_modifier = parameter_options.include_modifiers,
                    .include_name = parameter_options.include_names,
                    .include_type = parameter_options.include_types,
                });
                if (options.snippet_placeholders) {
                    try writer.writeByte('}');
                }
            }
        },
    }

    if (info.has_varargs) {
        if (parameters.len != 0) {
            try writer.writeAll(", ");
        }
        try writer.writeAll("...");
    }

    try writer.writeByte(')');

    // ignoring align_expr
    // ignoring addrspace_expr
    // ignoring section_expr
    // ignoring callconv_expr

    if (options.include_return_type) {
        try writer.writeByte(' ');

        const return_type = try options.info.return_value.typeOf(analyser);
        try return_type.rawStringify(escaping_writer, analyser, .{
            .referenced = referenced,
            .truncate_container_decls = true,
        });
    }
}

const SnippetEscapingWriter = struct {
    out: *std.Io.Writer,
    interface: std.Io.Writer,

    pub fn init(writer: *std.Io.Writer) SnippetEscapingWriter {
        return .{
            .out = writer,
            .interface = .{
                .vtable = &.{
                    .drain = &drain,
                    .flush = std.Io.Writer.noopFlush,
                    .rebase = std.Io.Writer.failingRebase,
                },
                .buffer = &.{},
            },
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *SnippetEscapingWriter = @fieldParentPtr("interface", w);
        const out = self.out;
        std.debug.assert(w.buffer.len == 0);
        for (data, 0..) |vec, i| {
            const segment_index = std.mem.findAny(u8, vec, "$}\\") orelse continue;
            if (i != 0) {
                return try out.writeSplat(data[0..i], splat);
            }
            const segment = vec[0..segment_index];
            const unescaped_char = vec[segment_index];
            const bytes_written = try out.write(segment);
            if (bytes_written < segment.len) return bytes_written;
            try out.writeAll(&.{ '\\', unescaped_char });
            return bytes_written + 1;
        } else {
            return try out.writeSplat(data, splat);
        }
    }

    fn writeAll(raw_text: []const u8, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var written: usize = 0;
        for (raw_text, 0..) |c, i| {
            switch (c) {
                '$', '}', '\\' => {
                    try writer.writeAll(raw_text[written..i]);
                    try writer.writeAll(&.{ '\\', c });
                    written = i + 1;
                },
                else => continue,
            }
        }
        try writer.writeAll(raw_text[written..]);
    }
};

pub fn fmtEscapedSnippet(raw_text: []const u8) std.fmt.Alt([]const u8, SnippetEscapingWriter.writeAll) {
    return .{ .data = raw_text };
}

pub fn renderBuiltinFunctionSignature(
    arena: std.mem.Allocator,
    name: []const u8,
    builtin_data: version_data.Builtin,
    multi_line: bool,
) error{OutOfMemory}![]u8 {
    var signature: std.ArrayList(u8) = .empty;
    try signature.appendSlice(arena, name);
    try signature.append(arena, '(');
    if (multi_line) try signature.append(arena, '\n');
    for (builtin_data.parameters, 0..) |parameter, i| {
        if (multi_line) {
            try signature.appendSlice(arena, "  ");
        } else if (i != 0) {
            try signature.appendSlice(arena, ", ");
        }
        try signature.appendSlice(arena, parameter.signature);
        if (multi_line) {
            try signature.appendSlice(arena, ",\n");
        }
    }
    try signature.appendSlice(arena, ") ");
    try signature.appendSlice(arena, builtin_data.return_type);
    return signature.items;
}

pub fn isInstanceCall(
    analyser: *Analyser,
    call_handle: *DocumentStore.Handle,
    call: Ast.full.Call,
    func_ty: Type,
) Error!bool {
    std.debug.assert(!func_ty.is_type_val);
    if (call_handle.tree.nodeTag(call.ast.fn_expr) != .field_access) return false;

    const container_node, _ = call_handle.tree.nodeData(call.ast.fn_expr).node_and_token;

    const container_ty = if (try analyser.resolveTypeOfNodeInternal(.of(container_node, call_handle))) |container_instance|
        try container_instance.typeOf(analyser)
    else
        func_ty.data.function.container_type.*;

    std.debug.assert(container_ty.is_type_val);

    return analyser.firstParamIs(func_ty, container_ty);
}

pub fn hasSelfParam(analyser: *Analyser, func_ty: Type) error{OutOfMemory}!bool {
    std.debug.assert(func_ty.isFunc());
    const container = func_ty.data.function.container_type.*;
    if (container.is_type_val) return false;
    const in_container = try container.typeOf(analyser);
    if (in_container.isNamespace()) return false;
    return analyser.firstParamIs(func_ty, in_container);
}

pub fn firstParamIs(
    analyser: *Analyser,
    func_type: Type,
    expected_type: Type,
) bool {
    _ = analyser;
    std.debug.assert(expected_type.is_type_val);
    std.debug.assert(func_type.isFunc());
    const func_info = func_type.data.function;
    if (func_info.parameters.len == 0) return false;
    const resolved_type = func_info.parameters[0].type;
    if (!resolved_type.is_type_val) return false;
    if (resolved_type.data == .anytype_parameter) return true;

    const deref_type = switch (resolved_type.data) {
        .pointer => |info| switch (info.size) {
            .one => info.elem_ty.*,
            .many, .slice, .c => return false,
        },
        else => resolved_type,
    };

    const deref_expected_type = switch (expected_type.data) {
        .pointer => |info| switch (info.size) {
            .one => info.elem_ty.*,
            .many, .slice, .c => return false,
        },
        else => expected_type,
    };

    return switch (deref_type.data) {
        .either => |entries| {
            for (entries) |entry| {
                if (entry.type_data.eql(deref_expected_type.data)) {
                    return true;
                }
            }
            return false;
        },
        else => deref_type.eql(deref_expected_type),
    };
}

pub fn getVariableSignature(
    arena: std.mem.Allocator,
    tree: *const Ast,
    var_decl: Ast.full.VarDecl,
    include_name: bool,
) error{OutOfMemory}![]const u8 {
    const start_token = if (include_name)
        var_decl.ast.mut_token
    else if (var_decl.ast.type_node.unwrap()) |type_node|
        tree.firstToken(type_node)
    else if (var_decl.ast.init_node.unwrap()) |init_node|
        tree.firstToken(init_node)
    else
        return "";

    const init_node = var_decl.ast.init_node.unwrap() orelse {
        const type_node = var_decl.ast.type_node.unwrap() orelse return "";
        return offsets.tokensToSlice(tree, start_token, ast.lastToken(tree, type_node));
    };

    const end_token = switch (tree.nodeTag(init_node)) {
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
        => end_token: {
            var buf: [2]Ast.Node.Index = undefined;
            const container_decl = tree.fullContainerDecl(&buf, init_node).?;

            var token = container_decl.ast.main_token;
            var offset: Ast.TokenIndex = 0;

            // Tagged union: union(enum)
            if (container_decl.ast.enum_token) |enum_token| {
                token = enum_token;
                offset += 1;
            }

            // Backing integer: struct(u32), union(enum(u32))
            // Tagged union: union(ComplexTypeTag)
            if (container_decl.ast.arg.unwrap()) |arg| {
                token = ast.lastToken(tree, arg);
                offset += 1;
            }

            if (container_decl.ast.members.len == 0) break :end_token token + offset;

            // e.g. 'pub const Mode = enum { zig, zon };'
            if (tree.tokensOnSameLine(tree.firstToken(init_node), ast.lastToken(tree, init_node))) {
                break :end_token ast.lastToken(tree, init_node);
            }

            var members_source: std.ArrayList(u8) = .empty;

            for (container_decl.ast.members) |member| {
                const member_line_start = offsets.lineLocUntilIndex(tree.source, tree.tokenStart(tree.firstToken(member))).start;

                const member_source_indented = switch (tree.nodeTag(member)) {
                    .container_field_init,
                    .container_field_align,
                    .container_field,
                    => tree.source[member_line_start..offsets.tokenToLoc(tree, ast.lastToken(tree, member)).end],
                    else => continue,
                };
                try members_source.append(arena, '\n');
                try members_source.appendSlice(arena, try trimCommonIndentation(arena, member_source_indented, 4));
                try members_source.append(arena, ',');
            }

            if (members_source.items.len == 0) break :end_token token + offset;

            return try std.mem.concat(arena, u8, &.{
                offsets.tokensToSlice(tree, start_token, token + offset),
                " {",
                members_source.items,
                "\n}",
            });
        },
        else => ast.lastToken(tree, init_node),
    };

    return offsets.tokensToSlice(tree, start_token, end_token);
}

fn trimCommonIndentation(allocator: std.mem.Allocator, str: []const u8, preserved_indentation_amount: usize) error{OutOfMemory}![]u8 {
    var line_it = std.mem.splitScalar(u8, str, '\n');

    var non_empty_lines: usize = 0;
    var min_indentation: ?usize = null;
    while (line_it.next()) |line| {
        if (line.len == 0) continue;
        const indentation = for (line, 0..) |c, count| {
            if (!std.ascii.isWhitespace(c)) break count;
        } else line.len;
        min_indentation = if (min_indentation) |old| @min(old, indentation) else indentation;
        non_empty_lines += 1;
    }

    var common_indent = min_indentation orelse return try allocator.dupe(u8, str);
    common_indent -|= preserved_indentation_amount;
    if (common_indent == 0) return try allocator.dupe(u8, str);

    const capacity = str.len - non_empty_lines * common_indent;
    var output: std.ArrayList(u8) = try .initCapacity(allocator, capacity);
    std.debug.assert(capacity == output.capacity);
    errdefer @compileError("error would leak here");

    line_it = std.mem.splitScalar(u8, str, '\n');
    var is_first_line = true;
    while (line_it.next()) |line| {
        if (!is_first_line) output.appendAssumeCapacity('\n');
        if (line.len != 0) {
            output.appendSliceAssumeCapacity(line[common_indent..]);
        }
        is_first_line = false;
    }

    std.debug.assert(output.items.len == output.capacity);
    return output.items;
}

test trimCommonIndentation {
    const cases = [_]struct { []const u8, []const u8, usize }{
        .{ "", "", 0 },
        .{ "\n", "\n", 0 },
        .{ "foo", "foo", 0 },
        .{ "foo", "  foo", 0 },
        .{ "foo  ", "    foo  ", 0 },
        .{ "foo\nbar", "    foo\n    bar", 0 },
        .{ "foo\nbar\n", "  foo\n  bar\n", 0 },
        .{ "  foo\nbar", "    foo\n  bar", 0 },
        .{ "foo\n  bar", "    foo\n      bar", 0 },
        .{ "  foo\n\nbar", "    foo\n\n  bar", 0 },

        .{ "  foo\n  bar", "    foo\n    bar", 2 },
        .{ "    foo\n    bar", "    foo\n    bar", 4 },
        .{ "    foo\n    bar", "    foo\n    bar", 8 },
    };

    for (cases) |case| {
        const actual = try trimCommonIndentation(std.testing.allocator, case[1], case[2]);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(case[0], actual);
    }
}

/// Returns whether the given `node` is the identifier `type`.
pub fn isMetaType(tree: *const Ast, node: Ast.Node.Index) bool {
    if (tree.nodeTag(node) == .identifier) {
        return std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "type");
    }
    return false;
}

/// Returns whether the given function returns a `type`.
pub fn isTypeFunction(tree: *const Ast, func: Ast.full.FnProto) bool {
    const return_type = func.ast.return_type.unwrap() orelse return false;
    return isMetaType(tree, return_type);
}

// ANALYSIS ENGINE

/// Resolves variable declarations consisting of chains of imports and field accesses of containers
/// Examples:
///```zig
/// const decl = @import("decl-file.zig").decl;
/// const other = decl.middle.other;
///```
pub fn resolveVarDeclAlias(analyser: *Analyser, decl: DeclWithHandle) Error!?DeclWithHandle {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const initial_node = switch (decl.decl) {
        .ast_node => |node| node,
        else => return null,
    };

    var node_trail: NodeSet = .empty;
    defer node_trail.deinit(analyser.gpa);

    var current: ResolveOptions = .{
        .node_handle = .of(initial_node, decl.handle),
        .container_type = decl.container_type,
    };
    var result: ?DeclWithHandle = null;
    while (true) {
        const node = current.node_handle.node;
        const handle = current.node_handle.handle;
        const tree = &handle.tree;

        const resolved: DeclWithHandle = switch (tree.nodeTag(node)) {
            .identifier => blk: {
                const name_token = ast.identifierTokenFromIdentifierNode(tree, node) orelse break :blk null;
                const name = offsets.identifierTokenToNameSlice(tree, name_token);
                if (current.container_type) |ty| {
                    break :blk try ty.lookupSymbol(analyser, name);
                }
                break :blk try analyser.lookupSymbolGlobal(
                    handle,
                    name,
                    tree.tokenStart(name_token),
                );
            },
            .field_access => blk: {
                const lhs, const field_name = tree.nodeData(node).node_and_token;
                const resolved = (try analyser.resolveTypeOfNode(.{
                    .node_handle = .of(lhs, handle),
                    .container_type = current.container_type,
                })) orelse break :blk null;
                if (!resolved.is_type_val)
                    break :blk null;

                const symbol_name = offsets.identifierTokenToNameSlice(tree, field_name);

                break :blk try resolved.lookupSymbol(analyser, symbol_name);
            },
            .global_var_decl,
            .local_var_decl,
            .aligned_var_decl,
            .simple_var_decl,
            => {
                const var_decl = tree.fullVarDecl(node).?;

                const base_exp = var_decl.ast.init_node.unwrap() orelse return result;
                if (tree.tokenTag(var_decl.ast.mut_token) != .keyword_const) return result;

                const gop = try node_trail.getOrPut(analyser.gpa, .{ .node = base_exp, .uri = handle.uri });
                if (gop.found_existing) return null;

                current.node_handle.node = base_exp;
                continue;
            },
            else => null,
        } orelse return result;

        const resolved_node = switch (resolved.decl) {
            .ast_node => |resolved_node| resolved_node,
            else => return resolved,
        };

        const gop = try node_trail.getOrPut(analyser.gpa, .{ .node = resolved_node, .uri = resolved.handle.uri });
        if (gop.found_existing) return null;

        current = .{
            .node_handle = .of(resolved_node, resolved.handle),
            .container_type = resolved.container_type,
        };
        result = resolved;
    }
}

/// resolves `@field(lhs, field_name)`
pub fn resolveFieldAccess(analyser: *Analyser, lhs: Type, field_name: []const u8) Error!?Type {
    const binding = try analyser.resolveFieldAccessBinding(.{ .type = lhs, .is_const = false }, field_name) orelse return null;
    return binding.type;
}

pub fn resolveFieldAccessBinding(analyser: *Analyser, lhs_binding: Binding, field_name: []const u8) Error!?Binding {
    const lhs = lhs_binding.type;

    if (try analyser.resolveUnionTagAccess(lhs, field_name)) |t|
        return .{ .type = t, .is_const = true };

    // If we are accessing a pointer type, remove one pointerness level :)
    const left_type = (try analyser.resolveDerefType(lhs)) orelse lhs;
    if (left_type.data == .either) {
        var candidates: std.ArrayList(Type.TypeWithDescriptor) = .empty;
        var all_const = true;
        for (left_type.data.either) |entry| {
            const candidate: Type = .{
                .data = entry.type_data,
                .is_type_val = left_type.is_type_val,
            };
            const resolved = try analyser.resolveFieldAccessBinding(.{
                .type = candidate,
                .is_const = lhs_binding.is_const,
            }, field_name) orelse continue;
            try candidates.append(analyser.arena, .{
                .type = resolved.type,
                .descriptor = entry.descriptor,
            });
            all_const = all_const and resolved.is_const;
        }
        return .{
            .type = try Type.fromEither(analyser, candidates.items) orelse return null,
            .is_const = all_const,
        };
    }

    if (try analyser.resolvePropertyType(left_type, field_name)) |t|
        return .{
            .type = t,
            .is_const = lhs_binding.is_const,
        };

    if (try left_type.lookupSymbol(analyser, field_name)) |child|
        return .{
            .type = try child.resolveType(analyser) orelse return null,
            .is_const = if (left_type.is_type_val) child.isConst() else lhs_binding.is_const,
        };

    return null;
}

pub fn resolveGenericType(analyser: *Analyser, ty: Type, bound_params: TokenToTypeMap) error{OutOfMemory}!Type {
    var visiting: Type.Data.GenericSet = .empty;
    defer visiting.deinit(analyser.gpa);
    return analyser.resolveGenericTypeInternal(ty, bound_params, &visiting);
}

fn resolveGenericTypeInternal(
    analyser: *Analyser,
    ty: Type,
    bound_params: TokenToTypeMap,
    visiting: *Type.Data.GenericSet,
) error{OutOfMemory}!Type {
    var resolved = ty;
    if (!ty.is_type_val) {
        resolved = try resolved.typeOf(analyser);
    }
    std.debug.assert(resolved.is_type_val);
    resolved.data = try resolved.data.resolveGeneric(analyser, bound_params, visiting);
    if (!ty.is_type_val) {
        resolved = try resolved.instanceUnchecked(analyser);
    }
    return resolved;
}

fn findReturnStatementInternal(tree: *const Ast, body: Ast.Node.Index, already_found: *bool) ?Ast.Node.Index {
    var result: ?Ast.Node.Index = null;

    var buffer: [2]Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&buffer, body) orelse return null;

    for (statements) |child_idx| {
        if (tree.nodeTag(child_idx) == .@"return") {
            if (already_found.*) return null;
            already_found.* = true;
            result = child_idx;
            continue;
        }

        result = findReturnStatementInternal(tree, child_idx, already_found);
    }

    return result;
}

fn findReturnStatement(tree: *const Ast, body: Ast.Node.Index) ?Ast.Node.Index {
    var already_found = false;
    return findReturnStatementInternal(tree, body, &already_found);
}

const KnownReturn = union(enum) {
    expression: Ast.Node.Index,
    continues,
    unknown,
};

fn mergeKnownReturns(
    analyser: *Analyser,
    handle: *DocumentStore.Handle,
    lhs: KnownReturn,
    rhs: KnownReturn,
) Error!KnownReturn {
    return switch (lhs) {
        .expression => |lhs_expression| switch (rhs) {
            .expression => |rhs_expression| blk: {
                const lhs_type = try analyser.resolveTypeOfNodeInternal(.of(lhs_expression, handle)) orelse
                    break :blk .unknown;
                const rhs_type = try analyser.resolveTypeOfNodeInternal(.of(rhs_expression, handle)) orelse
                    break :blk .unknown;
                break :blk if (lhs_type.eql(rhs_type)) lhs else .unknown;
            },
            .continues, .unknown => .unknown,
        },
        .continues => switch (rhs) {
            .continues => .continues,
            .expression, .unknown => .unknown,
        },
        .unknown => .unknown,
    };
}

fn bodyAlwaysBreaksCurrentLoop(
    analyser: *Analyser,
    handle: *DocumentStore.Handle,
    node: Ast.Node.Index,
) Error!bool {
    const tree = &handle.tree;
    return switch (tree.nodeTag(node)) {
        .@"break" => tree.nodeData(node).opt_token_and_opt_node[0] == .none,
        .@"comptime", .@"nosuspend" => analyser.bodyAlwaysBreaksCurrentLoop(handle, tree.nodeData(node).node),
        .block, .block_semicolon, .block_two, .block_two_semicolon => blk: {
            var buffer: [2]Ast.Node.Index = undefined;
            const statements = tree.blockStatements(&buffer, node) orelse break :blk false;
            for (statements) |statement| {
                if (try analyser.bodyAlwaysBreaksCurrentLoop(handle, statement)) break :blk true;
                if (try analyser.findKnownReturnExpression(handle, statement) != .continues) break :blk false;
            }
            break :blk false;
        },
        .@"if", .if_simple => blk: {
            const if_node = ast.fullIf(tree, node).?;
            const condition = try analyser.resolveIfConditionValue(.of(if_node.ast.cond_expr, handle)) orelse
                break :blk false;
            const selected = if (condition)
                if_node.ast.then_expr
            else
                if_node.ast.else_expr.unwrap() orelse break :blk false;
            break :blk analyser.bodyAlwaysBreaksCurrentLoop(handle, selected);
        },
        else => false,
    };
}

fn resolveKnownSwitchTarget(
    analyser: *Analyser,
    options: ResolveOptions,
) Error!?Ast.Node.Index {
    const handle = options.node_handle.handle;
    const tree = &handle.tree;
    const switch_node = tree.switchFull(options.node_handle.node);
    if (switch_node.label_token != null) return null;

    const condition = try analyser.resolveComptimeValue(.{
        .node_handle = .of(switch_node.ast.condition, handle),
        .container_type = options.container_type,
    }) orelse return null;

    var else_target: ?Ast.Node.Index = null;
    for (switch_node.ast.cases) |case| {
        const switch_case = tree.fullSwitchCase(case).?;
        if (switch_case.ast.values.len == 0) {
            else_target = switch_case.ast.target_expr;
            continue;
        }

        for (switch_case.ast.values) |case_value| {
            if (condition.data == .enum_value) {
                const enum_type = condition.data.enum_value.enum_type.*;
                const case_tag = try analyser.resolveEnumValueTag(enum_type, .of(case_value, handle)) orelse return null;
                if (std.mem.eql(u8, condition.data.enum_value.tag, case_tag)) return switch_case.ast.target_expr;
                continue;
            }
            const matches = if (tree.nodeTag(case_value) == .switch_range) range: {
                const first, const last = tree.nodeData(case_value).node_and_node;
                const first_index = try analyser.resolveInternPoolValue(.{
                    .node_handle = .of(first, handle),
                    .container_type = options.container_type,
                }) orelse return null;
                const last_index = try analyser.resolveInternPoolValue(.{
                    .node_handle = .of(last, handle),
                    .container_type = options.container_type,
                }) orelse return null;
                const first_value = Type.fromIP(analyser, analyser.ip.typeOf(first_index), first_index);
                const last_value = Type.fromIP(analyser, analyser.ip.typeOf(last_index), last_index);
                const at_least_first = analyser.resolveComparisonBool(.greater_or_equal, condition, first_value) orelse return null;
                const at_most_last = analyser.resolveComparisonBool(.less_or_equal, condition, last_value) orelse return null;
                break :range at_least_first and at_most_last;
            } else equal: {
                const value_index = try analyser.resolveInternPoolValue(.{
                    .node_handle = .of(case_value, handle),
                    .container_type = options.container_type,
                }) orelse return null;
                const value = Type.fromIP(analyser, analyser.ip.typeOf(value_index), value_index);
                break :equal analyser.resolveComparisonBool(.equal_equal, condition, value) orelse return null;
            };
            if (matches) return switch_case.ast.target_expr;
        }
    }
    return else_target;
}

fn findKnownReturnExpression(
    analyser: *Analyser,
    handle: *DocumentStore.Handle,
    node: Ast.Node.Index,
) Error!KnownReturn {
    const tree = &handle.tree;
    return switch (tree.nodeTag(node)) {
        .@"return" => if (tree.nodeData(node).opt_node.unwrap()) |expression|
            .{ .expression = expression }
        else
            .unknown,
        .@"comptime", .@"nosuspend" => analyser.findKnownReturnExpression(handle, tree.nodeData(node).node),
        .block, .block_semicolon, .block_two, .block_two_semicolon => blk: {
            var buffer: [2]Ast.Node.Index = undefined;
            const statements = tree.blockStatements(&buffer, node) orelse break :blk .unknown;
            for (statements) |statement| {
                switch (try analyser.findKnownReturnExpression(handle, statement)) {
                    .expression => |expression| break :blk .{ .expression = expression },
                    .unknown => break :blk .unknown,
                    .continues => {},
                }
            }
            break :blk .continues;
        },
        .@"if", .if_simple => blk: {
            const if_node = ast.fullIf(tree, node).?;
            const condition = try analyser.resolveIfConditionValue(.of(if_node.ast.cond_expr, handle)) orelse {
                const then_return = try analyser.findKnownReturnExpression(handle, if_node.ast.then_expr);
                const else_expr = if_node.ast.else_expr.unwrap() orelse break :blk switch (then_return) {
                    .continues => .continues,
                    .expression, .unknown => .unknown,
                };
                const else_return = try analyser.findKnownReturnExpression(handle, else_expr);
                break :blk analyser.mergeKnownReturns(handle, then_return, else_return);
            };
            if (condition) {
                break :blk try analyser.findKnownReturnExpression(handle, if_node.ast.then_expr);
            }
            const else_expr = if_node.ast.else_expr.unwrap() orelse break :blk .continues;
            break :blk try analyser.findKnownReturnExpression(handle, else_expr);
        },
        .@"while", .while_simple, .while_cont => blk: {
            const while_node = ast.fullWhile(tree, node) orelse break :blk .unknown;
            const condition = try analyser.resolveIfConditionValue(.of(while_node.ast.cond_expr, handle)) orelse {
                if (while_node.payload_token != null or
                    !try analyser.bodyAlwaysBreaksCurrentLoop(handle, while_node.ast.then_expr))
                {
                    break :blk .unknown;
                }
                const else_expr = while_node.ast.else_expr.unwrap() orelse break :blk .continues;
                break :blk if (try analyser.findKnownReturnExpression(handle, else_expr) == .continues)
                    .continues
                else
                    .unknown;
            };
            if (condition) {
                if (while_node.payload_token != null) break :blk .unknown;
                break :blk switch (try analyser.findKnownReturnExpression(handle, while_node.ast.then_expr)) {
                    .expression => |expression| .{ .expression = expression },
                    .continues => if (try analyser.bodyAlwaysBreaksCurrentLoop(handle, while_node.ast.then_expr))
                        .continues
                    else
                        .unknown,
                    .unknown => .unknown,
                };
            }
            const else_expr = while_node.ast.else_expr.unwrap() orelse break :blk .continues;
            break :blk try analyser.findKnownReturnExpression(handle, else_expr);
        },
        .@"for", .for_simple => blk: {
            const for_node = ast.fullFor(tree, node).?;
            for (for_node.ast.inputs) |input| {
                if (!try analyser.isKnownEmptyForInput(input, handle, null)) continue;
                const else_expr = for_node.ast.else_expr.unwrap() orelse break :blk .continues;
                break :blk try analyser.findKnownReturnExpression(handle, else_expr);
            }
            break :blk if (findReturnStatement(tree, node) != null) .unknown else .continues;
        },
        .@"switch", .switch_comma => blk: {
            if (try analyser.resolveKnownSwitchTarget(.of(node, handle))) |target| {
                break :blk analyser.findKnownReturnExpression(handle, target);
            }
            const switch_node = tree.switchFull(node);
            var merged: ?KnownReturn = null;
            for (switch_node.ast.cases) |case| {
                const switch_case = tree.fullSwitchCase(case).?;
                const branch = try analyser.findKnownReturnExpression(handle, switch_case.ast.target_expr);
                merged = if (merged) |current|
                    try analyser.mergeKnownReturns(handle, current, branch)
                else
                    branch;
                if (merged.? == .unknown) break :blk .unknown;
            }
            break :blk merged orelse .continues;
        },
        else => if (findReturnStatement(tree, node) != null) .unknown else .continues,
    };
}

/// if `func_type_param` is callable, returns an instance of the return type.
/// otherwise, returns null.
pub fn resolveReturnType(analyser: *Analyser, func_type_param: Type) error{OutOfMemory}!?Type {
    const func_type = try analyser.resolveFuncProtoOfCallable(func_type_param) orelse return null;
    const info = func_type.data.function;
    return info.return_value.*;
}

fn resolveReturnValueOfFuncNode(
    analyser: *Analyser,
    handle: *DocumentStore.Handle,
    func_node: Ast.Node.Index,
) Error!?Type {
    const tree = &handle.tree;

    var buf: [1]Ast.Node.Index = undefined;
    const fn_proto = tree.fullFnProto(&buf, func_node).?;
    const has_body = tree.nodeTag(func_node) == .fn_decl;

    if (isTypeFunction(tree, fn_proto)) {
        if (!has_body) return .unknown_type;
        const body = tree.nodeData(func_node).node_and_node[1];
        if (analyser.generic_bindings != null) {
            return switch (try analyser.findKnownReturnExpression(handle, body)) {
                .expression => |expression| try analyser.resolveTypeOfNodeInternal(.of(expression, handle)) orelse .unknown_type,
                .continues, .unknown => .unknown_type,
            };
        }
        // If this is a type function and it only contains a single return statement that returns
        // a container declaration, we will return that declaration.
        const return_node = findReturnStatement(tree, body) orelse return .unknown_type;
        if (tree.nodeData(return_node).opt_node.unwrap()) |return_expr| {
            return try analyser.resolveTypeOfNodeInternal(.of(return_expr, handle)) orelse .unknown_type;
        }

        return .unknown_type;
    }

    const return_type = fn_proto.ast.return_type.unwrap() orelse return null;
    const child_type = (try analyser.resolveTypeOfNodeInternal(.of(return_type, handle))) orelse
        return null;
    if (!child_type.is_type_val) return null;

    if (ast.hasInferredError(tree, fn_proto)) {
        const ty = try Type.createErrorUnionType(analyser, null, child_type);
        return try ty.instanceUnchecked(analyser);
    }

    return try child_type.instanceTypeVal(analyser);
}

/// `optional.?`
pub fn resolveOptionalUnwrap(analyser: *Analyser, optional: Type) error{OutOfMemory}!?Type {
    if (optional.is_type_val) return null;

    // TODO: some uses of this function don't expect C pointers to be unwrapped
    switch (optional.data) {
        .optional => |child_ty| return try child_ty.instanceUnchecked(analyser),
        .pointer => |ptr| {
            if (ptr.size == .c) return optional;
            return null;
        },
        .ip_index => |payload| switch (analyser.ip.indexToKey(payload.type)) {
            .optional_type => |optional_info| {
                if (analyser.evaluate_comptime_values) {
                    if (payload.index) |index| switch (analyser.ip.indexToKey(index)) {
                        .optional_value => |value| return Type.fromIP(analyser, analyser.ip.typeOf(value.val), value.val),
                        else => {},
                    };
                }
                return Type.fromIP(analyser, optional_info.payload_type, null);
            },
            .pointer_type => |pointer_info| {
                if (pointer_info.flags.size == .c) return optional;
                return null;
            },
            else => return null,
        },
        else => return null,
    }
}

pub fn resolveOrelseType(analyser: *Analyser, lhs: Type, rhs: Type) error{OutOfMemory}!?Type {
    if (rhs.is_type_val) return null;
    return switch (rhs.data) {
        .optional => rhs,
        .ip_index => |payload| switch (analyser.ip.indexToKey(payload.type)) {
            .optional_type => rhs,
            .simple_type => |simple_type| if (simple_type == .null_type) switch (lhs.data) {
                .optional => lhs,
                .ip_index => |lhs_payload| switch (analyser.ip.indexToKey(lhs_payload.type)) {
                    .optional_type => lhs,
                    else => try analyser.resolveOptionalUnwrap(lhs),
                },
                else => try analyser.resolveOptionalUnwrap(lhs),
            } else try analyser.resolveOptionalUnwrap(lhs),
            else => try analyser.resolveOptionalUnwrap(lhs),
        },
        else => try analyser.resolveOptionalUnwrap(lhs),
    };
}

pub fn resolveAddressOf(analyser: *Analyser, is_const: bool, ty: Type) error{OutOfMemory}!Type {
    const elem_ty = try ty.typeOf(analyser);
    const pointer_ty = try Type.createPointerType(analyser, .one, .none, is_const, elem_ty);
    return try pointer_ty.instanceUnchecked(analyser);
}

pub const ErrorUnionSide = enum { error_set, payload };

pub fn resolveUnwrapErrorUnionType(analyser: *Analyser, ty: Type, side: ErrorUnionSide) error{OutOfMemory}!?Type {
    if (ty.is_type_val) return null;

    return switch (ty.data) {
        .error_union => |info| switch (side) {
            .error_set => try (info.error_set orelse return null).instanceTypeVal(analyser),
            .payload => try info.payload.instanceTypeVal(analyser),
        },
        .ip_index => |payload| switch (analyser.ip.indexToKey(payload.type)) {
            .error_union_type => |error_union_info| switch (side) {
                .error_set => {
                    if (error_union_info.error_set_type == .none) return null;
                    return Type.fromIP(analyser, error_union_info.error_set_type, null);
                },
                .payload => return Type.fromIP(analyser, error_union_info.payload_type, null),
            },
            else => return null,
        },
        else => return null,
    };
}

pub fn resolveCatchType(analyser: *Analyser, lhs: Type, rhs: Type) error{OutOfMemory}!?Type {
    if (lhs.is_type_val or rhs.is_type_val) return null;

    const payload = switch (lhs.data) {
        .error_union => |info| try info.payload.instanceTypeVal(analyser) orelse return null,
        .ip_index => |lhs_payload| switch (analyser.ip.indexToKey(lhs_payload.type)) {
            .error_union_type => |info| Type.fromIP(analyser, info.payload_type, null),
            .error_set_type => return rhs,
            else => return null,
        },
        else => return null,
    };
    return try analyser.resolvePeerTypes(payload, rhs) orelse payload;
}

fn resolveUnionTag(analyser: *Analyser, ty: Type) Error!?Type {
    if (!ty.is_type_val)
        return null;

    if (!ty.isTaggedUnion())
        return null;

    const scope_handle = switch (ty.data) {
        .container => |info| info.scope_handle,
        else => return null,
    };
    const node = scope_handle.toNode();
    const handle = scope_handle.handle;

    var buf: [2]Ast.Node.Index = undefined;
    const container_decl = handle.tree.fullContainerDecl(&buf, node) orelse
        return null;

    if (container_decl.ast.enum_token != null)
        return .{ .data = .{ .union_tag = try analyser.allocType(ty) }, .is_type_val = false };

    if (container_decl.ast.arg.unwrap()) |arg| {
        const tag_type = (try analyser.resolveTypeOfNode(.of(arg, handle))) orelse return null;
        return try tag_type.instanceTypeVal(analyser) orelse return null;
    }

    return null;
}

fn resolveSwitchUnionPayload(
    analyser: *Analyser,
    union_type: Type,
    switch_tree: *const Ast,
    switch_node: Ast.full.Switch,
    selected_case: Ast.full.SwitchCase,
) Error!?Type {
    const container = switch (union_type.data) {
        .container => |container| container,
        else => return null,
    };
    const union_tree = &container.scope_handle.handle.tree;

    var payloads: std.ArrayList(Type.TypeWithDescriptor) = .empty;
    if (selected_case.ast.values.len != 0) {
        for (selected_case.ast.values) |case_value| {
            if (switch_tree.nodeTag(case_value) != .enum_literal) return null;
            const name = try analyser.identifierTokenName(switch_tree, switch_tree.nodeMainToken(case_value)) orelse return null;
            const field = try analyser.lookupSymbolContainer(union_type, name, .field) orelse return null;
            const field_type = try field.resolveType(analyser) orelse return null;
            try payloads.append(analyser.arena, .{ .type = field_type, .descriptor = name });
        }
        return Type.fromEither(analyser, payloads.items);
    }

    var container_buffer: [2]Ast.Node.Index = undefined;
    const declaration = union_tree.fullContainerDecl(&container_buffer, container.scope_handle.toNode()) orelse return null;
    for (declaration.ast.members) |member| {
        var field = union_tree.fullContainerField(member) orelse continue;
        field.convertToNonTupleLike(union_tree);
        if (field.ast.tuple_like or union_tree.tokenTag(field.ast.main_token) != .identifier) continue;
        const name = try analyser.identifierTokenName(union_tree, field.ast.main_token) orelse return null;

        var explicitly_matched = false;
        for (switch_node.ast.cases) |case_node| {
            const switch_case = switch_tree.fullSwitchCase(case_node).?;
            for (switch_case.ast.values) |case_value| {
                if (switch_tree.nodeTag(case_value) != .enum_literal) return null;
                const case_name = try analyser.identifierTokenName(switch_tree, switch_tree.nodeMainToken(case_value)) orelse return null;
                if (std.mem.eql(u8, name, case_name)) {
                    explicitly_matched = true;
                    break;
                }
            }
            if (explicitly_matched) break;
        }
        if (explicitly_matched) continue;

        const field_type = try (DeclWithHandle{
            .decl = .{ .ast_node = member },
            .handle = container.scope_handle.handle,
            .container_type = union_type,
        }).resolveType(analyser) orelse return null;
        try payloads.append(analyser.arena, .{ .type = field_type, .descriptor = name });
    }
    return Type.fromEither(analyser, payloads.items);
}

fn resolveUnionTagAccess(analyser: *Analyser, ty: Type, symbol: []const u8) Error!?Type {
    if (!ty.is_type_val)
        return null;

    if (!ty.isTaggedUnion())
        return null;

    const child = try ty.lookupSymbol(analyser, symbol) orelse
        return null;

    if (child.decl != .ast_node or !child.handle.tree.nodeTag(child.decl.ast_node).isContainerField())
        return null;

    return try analyser.resolveUnionTag(ty);
}

pub fn resolveFuncProtoOfCallable(analyser: *Analyser, ty: Type) error{OutOfMemory}!?Type {
    const deref_type = try analyser.resolveDerefType(ty) orelse ty;
    if (!deref_type.isFunc()) return null;
    return deref_type;
}

/// resolve a pointer dereference
/// `pointer.*`
pub fn resolveDerefType(analyser: *Analyser, pointer: Type) error{OutOfMemory}!?Type {
    const binding = try analyser.resolveDerefBinding(pointer) orelse return null;
    return binding.type;
}

pub fn resolveDerefBinding(analyser: *Analyser, pointer: Type) error{OutOfMemory}!?Binding {
    const runtime_pointer = pointer.runtimeType(analyser);
    if (runtime_pointer.is_type_val) return null;

    switch (runtime_pointer.data) {
        .pointer => |info| switch (info.size) {
            .one, .c => return .{
                .type = try info.elem_ty.instanceTypeVal(analyser) orelse return null,
                .is_const = info.is_const,
            },
            .many, .slice => return null,
        },
        .ip_index => |payload| {
            const ty = payload.type;
            switch (analyser.ip.indexToKey(ty)) {
                .pointer_type => |pointer_info| switch (pointer_info.flags.size) {
                    .one, .c => return .{
                        .type = Type.fromIP(analyser, pointer_info.elem_type, null),
                        .is_const = pointer_info.flags.is_const,
                    },
                    .many, .slice => return null,
                },
                else => return null,
            }
        },
        else => return null,
    }
}

pub const BracketAccess = union(enum) {
    /// `lhs[index]`
    single: ?u64,
    /// `lhs[start.. :sentinel]`
    open: struct {
        start: ?u64,
        sentinel: InternPool.Index,
    },
    /// `lhs[start..end :sentinel]`
    range: struct {
        bounds: ?struct { u64, u64 },
        sentinel: InternPool.Index,
    },

    pub fn fromSlice(
        analyser: *Analyser,
        handle: *DocumentStore.Handle,
        slice: Ast.full.Slice,
    ) Error!BracketAccess {
        const start_node = slice.ast.start;
        const end_node = slice.ast.end.unwrap() orelse
            return .{
                .open = .{
                    .start = try analyser.resolveIntegerLiteral(u64, .of(start_node, handle)),
                    .sentinel = try analyser.resolveOptionalIPValue(slice.ast.sentinel, handle),
                },
            };

        const bounds = blk: {
            const start = try analyser.resolveIntegerLiteral(u64, .of(start_node, handle)) orelse
                break :blk null;

            const end = try analyser.resolveIntegerLiteral(u64, .of(end_node, handle)) orelse
                break :blk null;

            break :blk .{ start, end };
        };

        return .{
            .range = .{
                .bounds = bounds,
                .sentinel = try analyser.resolveOptionalIPValue(slice.ast.sentinel, handle),
            },
        };
    }
};

/// Resolves slicing and array access
/// - `lhs[index]` (single)
/// - `lhs[start..]` (open)
/// - `lhs[start..end]` (range)
pub fn resolveBracketAccessType(analyser: *Analyser, lhs: Type, rhs: BracketAccess) error{OutOfMemory}!?Type {
    const binding = try analyser.resolveBracketAccess(.{ .type = lhs, .is_const = false }, rhs) orelse return null;
    return binding.type;
}

fn resolveAggregateValueAt(analyser: *Analyser, ty: Type, index: u64) ?Type {
    if (!analyser.evaluate_comptime_values) return null;
    const payload = switch (ty.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const element_type = switch (analyser.ip.indexToKey(payload.type)) {
        .tuple_type => |tuple| blk: {
            if (index >= tuple.values.len) return null;
            break :blk tuple.types.at(@intCast(index), analyser.ip);
        },
        .array_type => |array| blk: {
            if (index >= array.len) return null;
            break :blk array.child;
        },
        .vector_type => |vector| blk: {
            if (index >= vector.len) return null;
            break :blk vector.child;
        },
        else => return null,
    };
    if (payload.index) |value_index| {
        if (analyser.ip.indexToKey(value_index) == .aggregate) {
            const aggregate = analyser.ip.indexToKey(value_index).aggregate;
            if (aggregate.ty != payload.type or index >= aggregate.values.len) return null;
            const value = aggregate.values.at(@intCast(index), analyser.ip);
            if (value == .none or analyser.ip.isUndefined(value) or analyser.ip.isUnknown(value)) return null;
            return Type.fromIP(analyser, element_type, value);
        }
    }
    const tuple = switch (analyser.ip.indexToKey(payload.type)) {
        .tuple_type => |tuple| tuple,
        else => return null,
    };
    const value = tuple.values.at(@intCast(index), analyser.ip);
    if (value == .none or analyser.ip.isUndefined(value) or analyser.ip.isUnknown(value)) return null;
    return Type.fromIP(analyser, element_type, value);
}

fn resolveStringSliceValue(
    analyser: *Analyser,
    lhs_binding: Binding,
    rhs: BracketAccess,
    bytes: []const u8,
) error{OutOfMemory}!?Binding {
    const old_evaluate_comptime_values = analyser.evaluate_comptime_values;
    analyser.evaluate_comptime_values = false;
    defer analyser.evaluate_comptime_values = old_evaluate_comptime_values;

    const sliced = try analyser.resolveBracketAccess(lhs_binding, rhs) orelse return null;
    return .{
        .type = .{
            .data = .{ .string_value = .{
                .string_type = try analyser.allocType(try sliced.type.typeOf(analyser)),
                .bytes = bytes,
            } },
            .is_type_val = false,
        },
        .is_const = true,
    };
}

fn resolveArrayValue(
    analyser: *Analyser,
    aggregate_type: Type,
    elements: []const Ast.Node.Index,
    handle: *DocumentStore.Handle,
) Error!?Type {
    const type_index = aggregate_type.ipIndex() orelse return null;
    const child, const len = switch (analyser.ip.indexToKey(type_index)) {
        .array_type => |array| .{ array.child, array.len },
        .vector_type => |vector| .{ vector.child, vector.len },
        else => return null,
    };
    if (len != elements.len) return null;

    const values = try analyser.gpa.alloc(InternPool.Index, elements.len);
    defer analyser.gpa.free(values);
    for (elements, values) |element, *value| {
        value.* = try analyser.resolveCoercedIPValue(child, .of(element, handle)) orelse
            try analyser.ip.getUnknown(child);
    }
    const aggregate = try analyser.ip.get(.{ .aggregate = .{
        .ty = type_index,
        .values = try analyser.ip.getIndexSlice(values),
    } });
    return Type.fromIP(analyser, type_index, aggregate);
}

fn resolveSplatValue(
    analyser: *Analyser,
    vector_type: InternPool.Index,
    options: ResolveOptions,
) Error!?InternPool.Index {
    const vector = switch (analyser.ip.indexToKey(vector_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    const scalar = try analyser.resolveCoercedIPValue(vector.child, options) orelse return null;
    if (analyser.ip.isUndefined(scalar) or analyser.ip.isUnknown(scalar)) return null;
    const values = try analyser.gpa.alloc(InternPool.Index, vector.len);
    defer analyser.gpa.free(values);
    @memset(values, scalar);
    return try analyser.ip.get(.{ .aggregate = .{
        .ty = vector_type,
        .values = try analyser.ip.getIndexSlice(values),
    } });
}

fn resolveVectorIntFromBoolValue(analyser: *Analyser, operand: Type) error{OutOfMemory}!?Type {
    const payload = switch (operand.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const vector = switch (analyser.ip.indexToKey(payload.type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    if (vector.child != .bool_type) return null;

    const result_type = try analyser.ip.get(.{ .vector_type = .{
        .len = vector.len,
        .child = .u1_type,
    } });
    const result = Type.fromIP(analyser, result_type, null);
    const source_values = analyser.aggregateValues(operand) orelse return result;
    if (source_values.len != vector.len) return null;

    const values = try analyser.gpa.alloc(InternPool.Index, vector.len);
    defer analyser.gpa.free(values);
    for (values, 0..) |*value, i| {
        value.* = switch (source_values.at(@intCast(i), analyser.ip)) {
            .bool_true => .one_u1,
            .bool_false => .zero_u1,
            else => try analyser.ip.getUnknown(.u1_type),
        };
    }
    return analyser.aggregateValue(result, values);
}

fn resolveVectorCastValue(
    analyser: *Analyser,
    tag: std.zig.BuiltinFn.Tag,
    dest_type: InternPool.Index,
    source: InternPool.Index,
) error{OutOfMemory}!?InternPool.Index {
    const dest_vector = switch (analyser.ip.indexToKey(dest_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    const source_type = analyser.ip.typeOf(source);
    const source_vector = switch (analyser.ip.indexToKey(source_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    if (dest_vector.len != source_vector.len) return null;
    const source_values = analyser.aggregateValues(Type.fromIP(analyser, source_type, source)) orelse return null;
    if (source_values.len != source_vector.len) return null;

    const values = try analyser.gpa.alloc(InternPool.Index, dest_vector.len);
    defer analyser.gpa.free(values);
    for (values, 0..) |*value, i| {
        const source_value = source_values.at(@intCast(i), analyser.ip);
        value.* = switch (tag) {
            .int_from_float => try analyser.intFromFloatValue(dest_vector.child, source_value),
            .float_from_int => try analyser.floatFromIntValue(dest_vector.child, source_value),
            .float_cast => try analyser.coerceFloatValue(dest_vector.child, source_value),
            .truncate => try analyser.truncateIntValue(dest_vector.child, source_value),
            .int_cast => try analyser.coerceIP(dest_vector.child, source_value),
            else => return null,
        } orelse try analyser.ip.getUnknown(dest_vector.child);
    }
    return try analyser.ip.get(.{ .aggregate = .{
        .ty = dest_type,
        .values = try analyser.ip.getIndexSlice(values),
    } });
}

fn resolveAggregateLiteralValue(
    analyser: *Analyser,
    aggregate_type: InternPool.Index,
    options: ResolveOptions,
) Error!?InternPool.Index {
    const tree = &options.node_handle.handle.tree;
    switch (tree.nodeTag(options.node_handle.node)) {
        .array_init_one,
        .array_init_one_comma,
        .array_init_dot_two,
        .array_init_dot_two_comma,
        .array_init_dot,
        .array_init_dot_comma,
        .array_init,
        .array_init_comma,
        => {},
        else => return null,
    }
    var buffer: [2]Ast.Node.Index = undefined;
    const array_init = tree.fullArrayInit(&buffer, options.node_handle.node).?;
    const child_type, const len = switch (analyser.ip.indexToKey(aggregate_type)) {
        .array_type => |array| .{ array.child, array.len },
        .vector_type => |vector| .{ vector.child, vector.len },
        else => return null,
    };
    if (len != array_init.ast.elements.len) return null;

    const values = try analyser.gpa.alloc(InternPool.Index, array_init.ast.elements.len);
    defer analyser.gpa.free(values);
    for (array_init.ast.elements, values) |element, *value| {
        value.* = try analyser.resolveCoercedIPValue(child_type, .of(element, options.node_handle.handle)) orelse
            try analyser.ip.getUnknown(child_type);
    }
    return try analyser.ip.get(.{ .aggregate = .{
        .ty = aggregate_type,
        .values = try analyser.ip.getIndexSlice(values),
    } });
}

fn aggregateValues(analyser: *Analyser, value: Type) ?InternPool.Index.Slice {
    const payload = switch (value.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const value_index = payload.index orelse return null;
    const aggregate = switch (analyser.ip.indexToKey(value_index)) {
        .aggregate => |aggregate| aggregate,
        else => return null,
    };
    if (aggregate.ty != payload.type) return null;
    return aggregate.values;
}

fn aggregateValue(
    analyser: *Analyser,
    result: Type,
    values: []const InternPool.Index,
) error{OutOfMemory}!?Type {
    const payload = switch (result.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const aggregate = try analyser.ip.get(.{ .aggregate = .{
        .ty = payload.type,
        .values = try analyser.ip.getIndexSlice(values),
    } });
    return Type.fromIP(analyser, payload.type, aggregate);
}

fn stringSentinel(analyser: *Analyser, string: Type) ?InternPool.Index {
    const runtime_type = string.runtimeType(analyser);
    const pointer_info = switch (runtime_type.data) {
        .pointer => |info| return switch (info.size) {
            .one => switch (info.elem_ty.data) {
                .array => |array_info| known: {
                    if (array_info.sentinel == .none or array_info.sentinel == .unknown_unknown) return null;
                    break :known array_info.sentinel;
                },
                else => null,
            },
            .many, .slice => if (info.sentinel == .none or info.sentinel == .unknown_unknown)
                null
            else
                info.sentinel,
            .c => null,
        },
        .ip_index => |payload| switch (analyser.ip.indexToKey(payload.type)) {
            .pointer_type => |info| info,
            else => return null,
        },
        else => return null,
    };
    return switch (pointer_info.flags.size) {
        .one => switch (analyser.ip.indexToKey(pointer_info.elem_type)) {
            .array_type => |array_info| if (array_info.sentinel == .none or array_info.sentinel == .unknown_unknown)
                null
            else
                array_info.sentinel,
            else => null,
        },
        .many, .slice => if (pointer_info.sentinel == .none or pointer_info.sentinel == .unknown_unknown)
            null
        else
            pointer_info.sentinel,
        .c => null,
    };
}

// TODO: copy indexing logic from Zig compiler to InternPool, and then delete bracketAccessTypeFromIPIndex
fn bracketAccessTypeFromIPIndex(analyser: *Analyser, ip_index: InternPool.Index) error{OutOfMemory}!Type {
    std.debug.assert(analyser.ip.typeOf(ip_index) == .type_type);
    return switch (analyser.ip.indexToKey(ip_index)) {
        .tuple_type => |info| {
            const types = try info.types.dupe(analyser.gpa, analyser.ip);
            defer analyser.gpa.free(types);

            const elem_ty_slice = try analyser.arena.alloc(Type, types.len);
            for (elem_ty_slice, types) |*elem_ty, ty|
                elem_ty.* = try analyser.bracketAccessTypeFromIPIndex(ty);

            return .{
                .data = .{ .tuple = elem_ty_slice },
                .is_type_val = true,
            };
        },
        .vector_type => |info| .{
            .data = .{
                .array = .{
                    .elem_count = info.len,
                    .sentinel = .none,
                    .elem_ty = try analyser.allocType(try analyser.bracketAccessTypeFromIPIndex(info.child)),
                },
            },
            .is_type_val = true,
        },
        .array_type => |info| .{
            .data = .{
                .array = .{
                    .elem_count = info.len,
                    .sentinel = info.sentinel,
                    .elem_ty = try analyser.allocType(try analyser.bracketAccessTypeFromIPIndex(info.child)),
                },
            },
            .is_type_val = true,
        },
        .pointer_type => |info| .{
            .data = .{
                .pointer = .{
                    .size = info.flags.size,
                    .sentinel = info.sentinel,
                    .is_const = info.flags.is_const,
                    .elem_ty = try analyser.allocType(try analyser.bracketAccessTypeFromIPIndex(info.elem_type)),
                },
            },
            .is_type_val = true,
        },
        else => Type.fromIP(analyser, .type_type, ip_index),
    };
}

pub fn resolveBracketAccess(analyser: *Analyser, lhs_binding: Binding, rhs: BracketAccess) error{OutOfMemory}!?Binding {
    if (analyser.evaluate_comptime_values and lhs_binding.type.data == .string_value) {
        const bytes = lhs_binding.type.data.string_value.bytes;
        switch (rhs) {
            .single => |index| if (index) |i| {
                const value = if (i < bytes.len)
                    try analyser.ip.get(.{ .int_u64_value = .{
                        .ty = .u8_type,
                        .int = bytes[@intCast(i)],
                    } })
                else if (i == bytes.len)
                    analyser.stringSentinel(lhs_binding.type) orelse return null
                else
                    return null;
                return .{
                    .type = Type.fromIP(analyser, analyser.ip.typeOf(value), value),
                    .is_const = true,
                };
            },
            .open => |access| if (access.start != null and
                access.start.? <= bytes.len and
                access.sentinel == .none)
            {
                return analyser.resolveStringSliceValue(
                    lhs_binding,
                    rhs,
                    bytes[@intCast(access.start.?)..],
                );
            },
            .range => |access| if (access.bounds != null and access.sentinel == .none) {
                const start, const end = access.bounds.?;
                if (start <= end and end <= bytes.len) {
                    return analyser.resolveStringSliceValue(
                        lhs_binding,
                        rhs,
                        bytes[@intCast(start)..@intCast(end)],
                    );
                }
            },
        }
    }
    if (rhs == .single) {
        if (rhs.single) |index| {
            if (analyser.resolveAggregateValueAt(lhs_binding.type, index)) |value| {
                return .{ .type = value, .is_const = true };
            }
        }
    }

    const lhs = lhs_binding.type.runtimeType(analyser);
    if (lhs.is_type_val) return null;

    const is_const = switch (lhs.data) {
        .pointer => |info| info.is_const,
        else => lhs_binding.is_const,
    };

    var result: union(enum) { array: ?u64, slice: void } = .slice;
    var sentinel: InternPool.Index = .none;
    const elem_ty = elem: switch (lhs.data) {
        .tuple => |fields| switch (rhs) {
            .single => |index_maybe| {
                const index = index_maybe orelse return null;
                if (index >= fields.len) return null;
                const instance = try fields[@intCast(index)].instanceUnchecked(analyser);
                return .{ .type = instance, .is_const = is_const };
            },
            .open, .range => return null,
        },
        .array => |info| switch (rhs) {
            .single => {
                const instance = try info.elem_ty.instanceUnchecked(analyser);
                return .{ .type = instance, .is_const = is_const };
            },
            .open => |access| {
                if (access.start) |start| {
                    result = .{ .array = null };
                    if (info.elem_count) |elem_count| {
                        if (start <= elem_count) {
                            result = .{ .array = elem_count - start };
                        }
                    }
                }
                sentinel = access.sentinel;
                if (sentinel == .none) sentinel = info.sentinel;
                break :elem info.elem_ty;
            },
            .range => |access| {
                if (access.bounds) |bounds| {
                    result = .{ .array = null };
                    if (info.elem_count) |elem_count| {
                        const start, const end = bounds;
                        if (start <= end and start <= elem_count and end <= elem_count) {
                            result = .{ .array = end - start };
                        }
                    }
                }
                sentinel = access.sentinel;
                break :elem info.elem_ty;
            },
        },
        .pointer => |info| switch (info.size) {
            .one => switch (info.elem_ty.data) {
                .tuple, .array => continue :elem info.elem_ty.data,
                else => switch (rhs) {
                    .single, .open => return null,
                    .range => |access| {
                        if (access.sentinel != .none) return null;
                        const start, const end = access.bounds orelse return null;
                        if (start > end or start > 1 or end > 1) return null;
                        result = .{ .array = end - start };
                        break :elem info.elem_ty;
                    },
                },
            },
            .many, .slice, .c => switch (rhs) {
                .single => {
                    const instance = try info.elem_ty.instanceUnchecked(analyser);
                    return .{ .type = instance, .is_const = is_const };
                },
                .open => |access| {
                    sentinel = access.sentinel;
                    if (sentinel == info.sentinel) return lhs_binding;
                    if (sentinel == .none) sentinel = info.sentinel;
                    break :elem info.elem_ty;
                },
                .range => |access| {
                    if (access.bounds) |bounds| {
                        const start, const end = bounds;
                        result = .{ .array = if (start <= end) end - start else null };
                    }
                    sentinel = access.sentinel;
                    break :elem info.elem_ty;
                },
            },
        },
        .ip_index => |payload| {
            const ty = try analyser.bracketAccessTypeFromIPIndex(payload.type);
            const instance = try ty.instanceUnchecked(analyser);
            const binding: Binding = .{ .type = instance, .is_const = is_const };
            if (lhs.eql(binding.type)) return null;
            return analyser.resolveBracketAccess(binding, rhs);
        },
        else => return null,
    };

    switch (result) {
        .array => |elem_count| {
            const array_ty = try Type.createArrayType(analyser, elem_count, sentinel, elem_ty.*);
            const pointer_ty = try Type.createPointerType(analyser, .one, .none, is_const, array_ty);
            const pointer_instance = try pointer_ty.instanceUnchecked(analyser);
            return .{ .type = pointer_instance, .is_const = true };
        },
        .slice => {
            const slice_ty = try Type.createPointerType(analyser, .slice, sentinel, is_const, elem_ty.*);
            const slice_instance = try slice_ty.instanceUnchecked(analyser);
            return .{ .type = slice_instance, .is_const = true };
        },
    }
}

pub fn resolvePropertyType(analyser: *Analyser, ty: Type, name: []const u8) error{OutOfMemory}!?Type {
    if (ty.data == .string_value and std.mem.eql(u8, "len", name)) {
        const index = try analyser.ip.get(.{
            .int_u64_value = .{ .ty = .usize_type, .int = ty.data.string_value.bytes.len },
        });
        return Type.fromIP(analyser, .usize_type, index);
    }
    if (allDigits(name)) {
        const index = std.fmt.parseUnsigned(u64, name, 10) catch return null;
        if (analyser.resolveAggregateValueAt(ty, index)) |value| return value;
    }

    const runtime_ty = ty.runtimeType(analyser);
    if (runtime_ty.is_type_val)
        return null;

    switch (runtime_ty.data) {
        .pointer => |info| switch (info.size) {
            .one => {
                if (std.mem.eql(u8, "*", name)) {
                    return info.elem_ty.instanceTypeVal(analyser);
                }
                // One level of indirection is handled by resolveDerefType
            },
            .slice => {
                if (std.mem.eql(u8, "len", name)) {
                    return Type.fromIP(analyser, .usize_type, null);
                }

                if (std.mem.eql(u8, "ptr", name)) {
                    return .{
                        .data = .{
                            .pointer = .{
                                .size = .many,
                                .sentinel = info.sentinel,
                                .is_const = info.is_const,
                                .elem_ty = info.elem_ty,
                            },
                        },
                        .is_type_val = false,
                    };
                }
            },
            .many, .c => {},
        },

        .array => |info| {
            if (std.mem.eql(u8, "len", name)) {
                if (info.elem_count) |elem_count| {
                    const index = try analyser.ip.get(
                        .{ .int_u64_value = .{ .ty = .usize_type, .int = elem_count } },
                    );
                    return Type.fromIP(analyser, .usize_type, index);
                }
                return Type.fromIP(analyser, .usize_type, null);
            }
        },

        .tuple => |info| {
            if (std.mem.eql(u8, "len", name)) {
                const index = try analyser.ip.get(
                    .{ .int_u64_value = .{ .ty = .usize_type, .int = info.len } },
                );
                return Type.fromIP(analyser, .usize_type, index);
            }
            if (!allDigits(name)) return null;
            const index = std.fmt.parseInt(u16, name, 10) catch return null;
            return try analyser.resolveBracketAccessType(runtime_ty, .{ .single = index });
        },

        .optional => |child_ty| {
            if (std.mem.eql(u8, "?", name)) {
                return child_ty.instanceTypeVal(analyser);
            }
        },

        .ip_index => |payload| switch (analyser.ip.indexToKey(payload.type)) {
            .pointer_type => |pointer_info| switch (pointer_info.flags.size) {
                .one => {
                    if (std.mem.eql(u8, "*", name)) {
                        return Type.fromIP(analyser, pointer_info.elem_type, null);
                    }
                },
                .slice => {
                    if (std.mem.eql(u8, "len", name)) {
                        return Type.fromIP(analyser, .usize_type, null);
                    }

                    if (std.mem.eql(u8, "ptr", name)) {
                        var slice_ptr_info = pointer_info;
                        slice_ptr_info.flags.size = .many;
                        const slice_ptr_ty = try analyser.ip.get(.{ .pointer_type = slice_ptr_info });
                        return Type.fromIP(analyser, slice_ptr_ty, null);
                    }
                },
                .many, .c => {},
            },

            .array_type => |array_info| {
                if (std.mem.eql(u8, "len", name)) {
                    const index = try analyser.ip.get(.{
                        .int_u64_value = .{
                            .ty = .usize_type,
                            .int = array_info.len,
                        },
                    });
                    return Type.fromIP(analyser, .usize_type, index);
                }
            },

            .tuple_type => |tuple_info| {
                if (std.mem.eql(u8, "len", name)) {
                    const index = try analyser.ip.get(.{
                        .int_u64_value = .{
                            .ty = .usize_type,
                            .int = tuple_info.types.len,
                        },
                    });
                    return Type.fromIP(analyser, .usize_type, index);
                }
                if (!allDigits(name)) return null;
                const index = std.fmt.parseInt(u16, name, 10) catch return null;
                return try analyser.resolveBracketAccessType(ty, .{ .single = index });
            },

            .optional_type => |optional_info| {
                if (std.mem.eql(u8, "?", name)) {
                    return Type.fromIP(analyser, optional_info.payload_type, null);
                }
            },

            else => {},
        },

        else => {},
    }

    return null;
}

fn allDigits(str: []const u8) bool {
    for (str) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn resolveArrayMult(analyser: *Analyser, ty: Type, mult: ?u64) Error!?Type {
    if (ty.is_type_val) return null;
    const array_info = ty.arrayInfo(analyser) orelse return null;
    const old_count, const sentinel, const elem_ty = array_info;
    const new_count = blk: {
        const c = old_count orelse break :blk null;
        const m = mult orelse break :blk null;
        break :blk std.math.mul(u64, c, m) catch null;
    };
    const array_ty = try Type.createArrayType(analyser, new_count, sentinel, elem_ty);
    return try array_ty.instanceUnchecked(analyser);
}

fn resolveArrayMultExpression(analyser: *Analyser, operand: Type, mult: ?u64) Error!?Type {
    var elem_ty = operand.runtimeType(analyser);
    blk: {
        elem_ty = elem_ty.pointerElementType(analyser, .one) orelse break :blk;
        elem_ty = try elem_ty.instanceUnchecked(analyser);
        elem_ty = try analyser.resolveArrayMult(elem_ty, mult) orelse return null;
        elem_ty = try elem_ty.typeOf(analyser);
        const pointer_ty = try Type.createPointerType(analyser, .one, .none, true, elem_ty);
        return try pointer_ty.instanceUnchecked(analyser);
    }
    return try analyser.resolveArrayMult(elem_ty, mult);
}

fn resolveArrayCat(analyser: *Analyser, l_ty: Type, r_ty: Type) Error!?Type {
    if (l_ty.is_type_val) return null;
    if (r_ty.is_type_val) return null;
    const l_info = l_ty.arrayInfo(analyser) orelse return null;
    const r_info = r_ty.arrayInfo(analyser) orelse return null;
    const l_count, const l_sentinel, const l_elem_ty = l_info;
    const r_count, const r_sentinel, const r_elem_ty = r_info;
    const elem_value = try analyser.resolvePeerTypes(
        try l_elem_ty.instanceUnchecked(analyser),
        try r_elem_ty.instanceUnchecked(analyser),
    ) orelse return null;
    const elem_ty = try elem_value.typeOf(analyser);
    const elem_count = blk: {
        const l = l_count orelse break :blk null;
        const r = r_count orelse break :blk null;
        break :blk std.math.add(u64, l, r) catch null;
    };
    const elem_type = elem_ty.ipIndex() orelse return null;
    const sentinel = blk: {
        if (l_sentinel == .unknown_unknown) break :blk .unknown_unknown;
        if (r_sentinel == .unknown_unknown) break :blk .unknown_unknown;
        if (l_sentinel == .none and r_sentinel == .none) break :blk .none;
        if (l_sentinel == .none) break :blk try analyser.coerceArrayElementValue(elem_type, r_sentinel) orelse .unknown_unknown;
        if (r_sentinel == .none) break :blk try analyser.coerceArrayElementValue(elem_type, l_sentinel) orelse .unknown_unknown;
        const coerced_l = try analyser.coerceArrayElementValue(elem_type, l_sentinel) orelse break :blk .unknown_unknown;
        const coerced_r = try analyser.coerceArrayElementValue(elem_type, r_sentinel) orelse break :blk .unknown_unknown;
        if (coerced_l == coerced_r) break :blk coerced_l;
        break :blk .none;
    };
    const array_ty = try Type.createArrayType(analyser, elem_count, sentinel, elem_ty);
    return try array_ty.instanceUnchecked(analyser);
}

fn resolveArrayCatExpression(analyser: *Analyser, lhs: Type, rhs: Type) Error!?Type {
    var l_elem_ty = lhs.runtimeType(analyser);
    var r_elem_ty = rhs.runtimeType(analyser);
    blk: {
        l_elem_ty = l_elem_ty.pointerElementType(analyser, .one) orelse break :blk;
        r_elem_ty = r_elem_ty.pointerElementType(analyser, .one) orelse break :blk;
        l_elem_ty = try l_elem_ty.instanceUnchecked(analyser);
        r_elem_ty = try r_elem_ty.instanceUnchecked(analyser);
        var elem_ty = try analyser.resolveArrayCat(l_elem_ty, r_elem_ty) orelse return null;
        elem_ty = try elem_ty.typeOf(analyser);
        const pointer_ty = try Type.createPointerType(analyser, .one, .none, true, elem_ty);
        return try pointer_ty.instanceUnchecked(analyser);
    }
    return try analyser.resolveArrayCat(l_elem_ty, r_elem_ty);
}

fn coerceArrayElementValue(
    analyser: *Analyser,
    result_type: InternPool.Index,
    value: InternPool.Index,
) error{OutOfMemory}!?InternPool.Index {
    if (value == .none) return try analyser.ip.getUnknown(result_type);
    if (analyser.ip.isUndefined(value)) return try analyser.ip.getUndefined(result_type);
    if (analyser.ip.isUnknown(value)) return try analyser.ip.getUnknown(result_type);
    if (analyser.ip.zigTypeTag(result_type) == .int) {
        const int = analyser.ip.toInt(value, i256) orelse return null;
        return (try analyser.intValueWithType(result_type, int) orelse return null).ipIndex();
    }
    return analyser.coerceIP(result_type, value);
}

fn resolveOptionalIPValue(
    analyser: *Analyser,
    optional_node: Ast.Node.OptionalIndex,
    handle: *DocumentStore.Handle,
) Error!InternPool.Index {
    const node = optional_node.unwrap() orelse return .none;
    return try analyser.resolveInternPoolValue(.of(node, handle)) orelse .unknown_unknown;
}

fn resolveCoercedIPValue(
    analyser: *Analyser,
    ip_ty: InternPool.Index,
    options: ResolveOptions,
) Error!?InternPool.Index {
    if (!analyser.ip.isType(ip_ty)) return null;

    var value_options = options;
    var integer_cast: ?std.zig.BuiltinFn.Tag = null;
    const tree = &options.node_handle.handle.tree;
    if (try analyser.resolveAggregateLiteralValue(ip_ty, options)) |value| return value;
    switch (tree.nodeTag(options.node_handle.node)) {
        .builtin_call,
        .builtin_call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        => {
            const name = tree.tokenSlice(tree.nodeMainToken(options.node_handle.node));
            if (std.mem.eql(u8, name, "@intCast") or
                std.mem.eql(u8, name, "@truncate") or
                std.mem.eql(u8, name, "@bitCast") or
                std.mem.eql(u8, name, "@intFromFloat") or
                std.mem.eql(u8, name, "@floatFromInt") or
                std.mem.eql(u8, name, "@floatCast") or
                std.mem.eql(u8, name, "@splat"))
            {
                var buffer: [2]Ast.Node.Index = undefined;
                const params = tree.builtinCallParams(&buffer, options.node_handle.node).?;
                if (params.len != 1) return null;
                value_options.node_handle.node = params[0];
                integer_cast = if (std.mem.eql(u8, name, "@truncate"))
                    .truncate
                else if (std.mem.eql(u8, name, "@bitCast"))
                    .bit_cast
                else if (std.mem.eql(u8, name, "@intFromFloat"))
                    .int_from_float
                else if (std.mem.eql(u8, name, "@floatFromInt"))
                    .float_from_int
                else if (std.mem.eql(u8, name, "@floatCast"))
                    .float_cast
                else if (std.mem.eql(u8, name, "@splat"))
                    .splat
                else
                    .int_cast;
            }
        },
        else => {},
    }

    const ip_index = try analyser.resolveInternPoolValue(value_options) orelse return null;
    if (analyser.ip.isUndefined(ip_index)) return null;
    const source_tag = analyser.ip.zigTypeTag(analyser.ip.typeOf(ip_index)) orelse return null;
    if (integer_cast) |tag| {
        if (tag == .splat) {
            return try analyser.resolveSplatValue(ip_ty, value_options);
        }
        if (analyser.ip.zigTypeTag(ip_ty) == .vector and source_tag == .vector) {
            return try analyser.resolveVectorCastValue(tag, ip_ty, ip_index);
        }
        if (tag == .int_from_float) {
            if (analyser.ip.zigTypeTag(ip_ty) != .int) return null;
            if (source_tag != .float and source_tag != .comptime_float) return null;
            return try analyser.intFromFloatValue(ip_ty, ip_index);
        }
        if (tag == .float_from_int) {
            if (analyser.ip.zigTypeTag(ip_ty) != .float) return null;
            if (source_tag != .int and source_tag != .comptime_int) return null;
            return try analyser.floatFromIntValue(ip_ty, ip_index);
        }
        if (tag == .float_cast) {
            if (analyser.ip.zigTypeTag(ip_ty) != .float) return null;
            if (source_tag != .float and source_tag != .comptime_float) return null;
            return try analyser.coerceFloatValue(ip_ty, ip_index);
        }
        if (analyser.ip.zigTypeTag(ip_ty) != .int) return null;
        if (source_tag != .int and source_tag != .comptime_int) return null;
        if (tag == .truncate) return try analyser.truncateIntValue(ip_ty, ip_index);
        if (tag == .bit_cast) return try analyser.bitCastIntValue(ip_ty, ip_index);
    }
    if (analyser.ip.zigTypeTag(ip_ty) == .float and
        (source_tag == .float or source_tag == .comptime_float))
    {
        if (try analyser.coerceFloatValue(ip_ty, ip_index)) |coerced| return coerced;
    }

    var arena_allocator: std.heap.ArenaAllocator = .init(analyser.gpa);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    var err_msg: ErrorMsg = undefined;
    const new_index = try analyser.ip.coerce(arena, ip_ty, ip_index, builtin.target, &err_msg);

    if (new_index == .none) return null;
    if (analyser.ip.isUnknown(new_index)) return null;
    return new_index;
}

fn coerceFloatValue(
    analyser: *Analyser,
    dest_ty: InternPool.Index,
    value: InternPool.Index,
) error{OutOfMemory}!?InternPool.Index {
    const float_value = analyser.floatValue(value) orelse return null;
    return switch (dest_ty) {
        .f16_type => try analyser.ip.get(.{ .float_16_value = @floatCast(float_value) }),
        .f32_type => try analyser.ip.get(.{ .float_32_value = @floatCast(float_value) }),
        .f64_type => try analyser.ip.get(.{ .float_64_value = @floatCast(float_value) }),
        .f80_type => try analyser.ip.get(.{ .float_80_value = @floatCast(float_value) }),
        .f128_type => try analyser.ip.get(.{ .float_128_value = float_value }),
        .comptime_float_type => try analyser.ip.get(.{ .float_comptime_value = float_value }),
        else => null,
    };
}

fn floatValue(analyser: *Analyser, value: InternPool.Index) ?f128 {
    return switch (analyser.ip.indexToKey(value)) {
        .float_16_value => |float| @floatCast(float),
        .float_32_value => |float| @floatCast(float),
        .float_64_value => |float| @floatCast(float),
        .float_80_value => |float| @floatCast(float),
        .float_128_value, .float_comptime_value => |float| float,
        else => return null,
    };
}

fn exactFloatFromInt(analyser: *Analyser, value: InternPool.Index) ?f128 {
    if (analyser.ip.toInt(value, i64)) |signed| return @floatFromInt(signed);
    if (analyser.ip.toInt(value, u64)) |unsigned| return @floatFromInt(unsigned);
    return null;
}

fn numericFloatValue(analyser: *Analyser, value: InternPool.Index) ?f128 {
    return analyser.floatValue(value) orelse analyser.exactFloatFromInt(value);
}

fn coerceNumericToFloatValue(
    analyser: *Analyser,
    dest_ty: InternPool.Index,
    value: InternPool.Index,
) error{OutOfMemory}!?InternPool.Index {
    const float_value = analyser.numericFloatValue(value) orelse return null;
    const comptime_value = try analyser.ip.get(.{ .float_comptime_value = float_value });
    return analyser.coerceFloatValue(dest_ty, comptime_value);
}

fn resolveFloatRoundingValue(
    analyser: *Analyser,
    tag: std.zig.BuiltinFn.Tag,
    operand: Type,
) error{OutOfMemory}!?Type {
    const payload = switch (operand.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const index = payload.index orelse return null;
    const value = analyser.floatValue(index) orelse return null;
    if (!std.math.isFinite(value)) return null;
    const result: f128 = switch (tag) {
        .floor => @floor(value),
        .ceil => @ceil(value),
        .trunc => @trunc(value),
        .round => @round(value),
        else => return null,
    };
    const result_index = try analyser.coerceFloatValue(
        payload.type,
        try analyser.ip.get(.{ .float_comptime_value = result }),
    ) orelse return null;
    return Type.fromIP(analyser, payload.type, result_index);
}

fn floatUnaryBuiltinValue(
    comptime T: type,
    tag: std.zig.BuiltinFn.Tag,
    operand: f128,
) ?f128 {
    const value: T = @floatCast(operand);
    if (!std.math.isFinite(value)) return null;
    const result: T = switch (tag) {
        .abs => @abs(value),
        .sin => @sin(value),
        .cos => @cos(value),
        .tan => @tan(value),
        .exp => @exp(value),
        .exp2 => @exp2(value),
        .log => @log(value),
        .log2 => @log2(value),
        .log10 => @log10(value),
        .sqrt => @sqrt(value),
        else => return null,
    };
    if (!std.math.isFinite(result)) return null;
    return @floatCast(result);
}

fn resolveFloatUnaryBuiltinValue(
    analyser: *Analyser,
    tag: std.zig.BuiltinFn.Tag,
    operand: Type,
) error{OutOfMemory}!?Type {
    const payload = switch (operand.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const value = analyser.floatValue(payload.index orelse return null) orelse return null;
    const result = switch (payload.type) {
        .f16_type => floatUnaryBuiltinValue(f16, tag, value),
        .f32_type => floatUnaryBuiltinValue(f32, tag, value),
        .f64_type => floatUnaryBuiltinValue(f64, tag, value),
        .f80_type => floatUnaryBuiltinValue(f80, tag, value),
        .f128_type, .comptime_float_type => floatUnaryBuiltinValue(f128, tag, value),
        else => null,
    } orelse return null;
    const result_index = try analyser.coerceFloatValue(
        payload.type,
        try analyser.ip.get(.{ .float_comptime_value = result }),
    ) orelse return null;
    return Type.fromIP(analyser, payload.type, result_index);
}

fn resolveFloatVectorUnaryValue(
    analyser: *Analyser,
    tag: std.zig.BuiltinFn.Tag,
    operand: Type,
) error{OutOfMemory}!?Type {
    const payload = switch (operand.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const vector = switch (analyser.ip.indexToKey(payload.type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    if (analyser.ip.zigTypeTag(vector.child) != .float) return null;
    const source_values = analyser.aggregateValues(operand) orelse return null;
    if (source_values.len != vector.len) return null;

    const values = try analyser.gpa.alloc(InternPool.Index, vector.len);
    defer analyser.gpa.free(values);
    for (values, 0..) |*value, i| {
        const source = source_values.at(@intCast(i), analyser.ip);
        const element = Type.fromIP(analyser, vector.child, source);
        const result = switch (tag) {
            .floor, .ceil, .trunc, .round => try analyser.resolveFloatRoundingValue(tag, element),
            else => try analyser.resolveFloatUnaryBuiltinValue(tag, element),
        };
        value.* = if (result) |resolved| resolved.ipIndex() orelse try analyser.ip.getUnknown(vector.child) else try analyser.ip.getUnknown(vector.child);
    }
    return analyser.aggregateValue(Type.fromIP(analyser, payload.type, null), values);
}

fn resolveAbsValue(analyser: *Analyser, operand: Type) error{OutOfMemory}!?Type {
    const payload = switch (operand.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const operand_type = payload.type;
    const scalar_tag = analyser.ip.zigTypeTag(operand_type) orelse return null;
    const result_type = switch (scalar_tag) {
        .comptime_float, .float, .comptime_int => operand_type,
        .int => if (analyser.ip.isSignedInt(operand_type, builtin.target))
            try analyser.ip.toUnsigned(operand_type, builtin.target)
        else
            operand_type,
        else => return null,
    };
    const operand_index = payload.index orelse return null;
    if (scalar_tag == .comptime_int) {
        const value = analyser.ip.toInt(operand_index, i256) orelse return null;
        const magnitude = if (value >= 0) value else std.math.sub(i256, 0, value) catch return null;
        return analyser.intValueWithType(result_type, magnitude);
    }
    if (scalar_tag == .int) {
        const info = analyser.ip.intInfo(operand_type, builtin.target);
        if (info.bits > 128) {
            if (info.signedness == .unsigned) return operand;
            return switch (analyser.ip.indexToKey(operand_index)) {
                .int_u64_value => |int_value| analyser.intValueWithType(result_type, int_value.int),
                .int_i64_value => |int_value| analyser.intValueWithType(
                    result_type,
                    if (int_value.int >= 0) int_value.int else -@as(i128, int_value.int),
                ),
                .int_big_value => |int_value| Type.fromIP(
                    analyser,
                    result_type,
                    try analyser.ip.getBigInt(result_type, .{
                        .positive = true,
                        .limbs = int_value.getConst(analyser.ip).limbs,
                    }),
                ),
                else => null,
            };
        }
        const magnitude: i256 = switch (info.signedness) {
            .unsigned => @intCast(analyser.ip.toInt(operand_index, u128) orelse return null),
            .signed => magnitude: {
                const value = analyser.ip.toInt(operand_index, i128) orelse return null;
                break :magnitude if (value >= 0) value else -@as(i256, value);
            },
        };
        return analyser.intValueWithType(result_type, magnitude);
    }
    const value = analyser.floatValue(operand_index) orelse return null;
    if (!std.math.isFinite(value)) return null;
    const result_index = try analyser.coerceFloatValue(
        result_type,
        try analyser.ip.get(.{ .float_comptime_value = @abs(value) }),
    ) orelse return null;
    return Type.fromIP(analyser, result_type, result_index);
}

const VectorUnaryOperation = enum { bit_not, negate, negate_wrap, abs };

fn resolveVectorUnaryValue(
    analyser: *Analyser,
    operation: VectorUnaryOperation,
    operand: Type,
) error{OutOfMemory}!?Type {
    const payload = switch (operand.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const vector = switch (analyser.ip.indexToKey(payload.type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    const result_type = if (operation == .abs and analyser.ip.zigTypeTag(vector.child) == .int and
        analyser.ip.isSignedInt(vector.child, builtin.target))
        try analyser.ip.toUnsigned(payload.type, builtin.target)
    else
        payload.type;
    const result_vector = switch (analyser.ip.indexToKey(result_type)) {
        .vector_type => |result_vector| result_vector,
        else => return null,
    };
    const source_values = analyser.aggregateValues(operand) orelse return Type.fromIP(analyser, result_type, null);
    if (source_values.len != vector.len) return null;

    const values = try analyser.gpa.alloc(InternPool.Index, vector.len);
    defer analyser.gpa.free(values);
    for (values, 0..) |*value, i| {
        const element = Type.fromIP(analyser, vector.child, source_values.at(@intCast(i), analyser.ip));
        const resolved = switch (operation) {
            .bit_not => try analyser.resolveBitNotValue(element),
            .negate => try analyser.resolveNegationValue(element, false),
            .negate_wrap => try analyser.resolveNegationValue(element, true),
            .abs => try analyser.resolveAbsValue(element),
        };
        value.* = if (resolved) |result| result.ipIndex() orelse try analyser.ip.getUnknown(result_vector.child) else try analyser.ip.getUnknown(result_vector.child);
    }
    return analyser.aggregateValue(Type.fromIP(analyser, result_type, null), values);
}

fn floatMulAddValue(comptime T: type, a: f128, b: f128, c: f128) ?f128 {
    const lhs: T = @floatCast(a);
    const rhs: T = @floatCast(b);
    const addend: T = @floatCast(c);
    if (!std.math.isFinite(lhs) or !std.math.isFinite(rhs) or !std.math.isFinite(addend)) return null;
    const result: T = @mulAdd(T, lhs, rhs, addend);
    if (!std.math.isFinite(result)) return null;
    return @floatCast(result);
}

fn resolveFloatMulAddValue(
    analyser: *Analyser,
    result_type: InternPool.Index,
    a: InternPool.Index,
    b: InternPool.Index,
    c: InternPool.Index,
) error{OutOfMemory}!?Type {
    const a_value = analyser.floatValue(a) orelse return null;
    const b_value = analyser.floatValue(b) orelse return null;
    const c_value = analyser.floatValue(c) orelse return null;
    const result = switch (result_type) {
        .f16_type => floatMulAddValue(f16, a_value, b_value, c_value),
        .f32_type => floatMulAddValue(f32, a_value, b_value, c_value),
        .f64_type => floatMulAddValue(f64, a_value, b_value, c_value),
        .f80_type => floatMulAddValue(f80, a_value, b_value, c_value),
        .f128_type, .comptime_float_type => floatMulAddValue(f128, a_value, b_value, c_value),
        else => null,
    } orelse return null;
    const result_index = try analyser.coerceFloatValue(
        result_type,
        try analyser.ip.get(.{ .float_comptime_value = result }),
    ) orelse return null;
    return Type.fromIP(analyser, result_type, result_index);
}

fn resolveFloatVectorMulAddValue(
    analyser: *Analyser,
    result_type: InternPool.Index,
    a: InternPool.Index,
    b: InternPool.Index,
    c: InternPool.Index,
) error{OutOfMemory}!?Type {
    const vector = switch (analyser.ip.indexToKey(result_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    if (analyser.ip.zigTypeTag(vector.child) != .float) return null;
    const a_values = analyser.aggregateValues(Type.fromIP(analyser, result_type, a)) orelse return null;
    const b_values = analyser.aggregateValues(Type.fromIP(analyser, result_type, b)) orelse return null;
    const c_values = analyser.aggregateValues(Type.fromIP(analyser, result_type, c)) orelse return null;
    if (a_values.len != vector.len or b_values.len != vector.len or c_values.len != vector.len) return null;

    const values = try analyser.gpa.alloc(InternPool.Index, vector.len);
    defer analyser.gpa.free(values);
    for (values, 0..) |*value, i| {
        const result = try analyser.resolveFloatMulAddValue(
            vector.child,
            a_values.at(@intCast(i), analyser.ip),
            b_values.at(@intCast(i), analyser.ip),
            c_values.at(@intCast(i), analyser.ip),
        );
        value.* = if (result) |resolved| resolved.ipIndex() orelse try analyser.ip.getUnknown(vector.child) else try analyser.ip.getUnknown(vector.child);
    }
    return analyser.aggregateValue(Type.fromIP(analyser, result_type, null), values);
}

fn floatFromIntValue(
    analyser: *Analyser,
    dest_ty: InternPool.Index,
    value: InternPool.Index,
) error{OutOfMemory}!?InternPool.Index {
    const float_value: f128 = if (analyser.ip.toInt(value, i128)) |signed|
        @floatFromInt(signed)
    else if (analyser.ip.toInt(value, u128)) |unsigned|
        @floatFromInt(unsigned)
    else
        return null;
    const comptime_value = try analyser.ip.get(.{ .float_comptime_value = float_value });
    return analyser.coerceFloatValue(dest_ty, comptime_value);
}

fn intFromFloatValue(
    analyser: *Analyser,
    dest_ty: InternPool.Index,
    value: InternPool.Index,
) error{OutOfMemory}!?InternPool.Index {
    const info = analyser.ip.intInfo(dest_ty, builtin.target);
    if (info.bits > 128) return null;
    const float_value = analyser.floatValue(value) orelse return null;
    if (!std.math.isFinite(float_value)) return null;
    const truncated = @trunc(float_value);
    return switch (info.signedness) {
        .unsigned => unsigned: {
            const upper_bound = std.math.ldexp(@as(f128, 1), info.bits);
            if (truncated < 0 or truncated >= upper_bound) return null;
            const int_value: u128 = @intFromFloat(truncated);
            const result = try analyser.intValueWithType(dest_ty, @intCast(int_value));
            break :unsigned (result orelse return null).ipIndex().?;
        },
        .signed => signed: {
            if (info.bits == 0) return null;
            const magnitude_bound = std.math.ldexp(@as(f128, 1), info.bits - 1);
            if (truncated < -magnitude_bound or truncated >= magnitude_bound) return null;
            const int_value: i128 = @intFromFloat(truncated);
            const result = try analyser.intValueWithType(dest_ty, int_value);
            break :signed (result orelse return null).ipIndex().?;
        },
    };
}

fn bitCastIntValue(
    analyser: *Analyser,
    dest_ty: InternPool.Index,
    value: InternPool.Index,
) error{OutOfMemory}!?InternPool.Index {
    if (analyser.ip.zigTypeTag(dest_ty) != .int) return null;
    const source_ty = analyser.ip.typeOf(value);
    if (analyser.ip.zigTypeTag(source_ty) != .int) return null;
    const dest_info = analyser.ip.intInfo(dest_ty, builtin.target);
    const source_info = analyser.ip.intInfo(source_ty, builtin.target);
    if (dest_info.bits != source_info.bits) return null;
    if (dest_info.bits > 128) {
        var source = try analyser.managedIntegerValue(value) orelse return null;
        defer source.deinit();
        var result: std.math.big.int.Managed = try .init(analyser.gpa);
        defer result.deinit();
        try result.truncate(&source, dest_info.signedness, dest_info.bits);
        return try analyser.ip.getBigInt(dest_ty, result.toConst());
    }

    const raw: u128 = switch (source_info.signedness) {
        .unsigned => analyser.ip.toInt(value, u128) orelse return null,
        .signed => signed: {
            const signed_value = analyser.ip.toInt(value, i128) orelse return null;
            const bits: u128 = @bitCast(signed_value);
            const mask = if (source_info.bits == 128)
                std.math.maxInt(u128)
            else if (source_info.bits == 0)
                0
            else
                (@as(u128, 1) << @intCast(source_info.bits)) - 1;
            break :signed bits & mask;
        },
    };

    const result: i256 = switch (dest_info.signedness) {
        .unsigned => @intCast(raw),
        .signed => signed: {
            if (dest_info.bits == 0 or raw & (@as(u128, 1) << @intCast(dest_info.bits - 1)) == 0) {
                break :signed @intCast(raw);
            }
            break :signed if (dest_info.bits == 128)
                @as(i128, @bitCast(raw))
            else
                @as(i256, @intCast(raw)) - (@as(i256, 1) << @intCast(dest_info.bits));
        },
    };
    return (try analyser.intValueWithType(dest_ty, result) orelse return null).ipIndex();
}

fn truncateIntValue(
    analyser: *Analyser,
    dest_ty: InternPool.Index,
    value: InternPool.Index,
) error{OutOfMemory}!?InternPool.Index {
    if (analyser.ip.zigTypeTag(dest_ty) != .int) return null;
    const info = analyser.ip.intInfo(dest_ty, builtin.target);
    const source_ty = analyser.ip.typeOf(value);
    if (analyser.ip.zigTypeTag(source_ty) == .int and
        analyser.ip.intInfo(source_ty, builtin.target).signedness != info.signedness)
    {
        return null;
    }
    if (info.bits > 128) {
        var source = try analyser.managedIntegerValue(value) orelse return null;
        defer source.deinit();
        var result: std.math.big.int.Managed = try .init(analyser.gpa);
        defer result.deinit();
        try result.truncate(&source, info.signedness, info.bits);
        return try analyser.ip.getBigInt(dest_ty, result.toConst());
    }

    const raw: u256 = if (analyser.ip.toInt(value, u256)) |unsigned|
        unsigned
    else if (analyser.ip.toInt(value, i256)) |signed|
        @bitCast(signed)
    else
        return null;
    const mask: u256 = if (info.bits == 128)
        std.math.maxInt(u128)
    else if (info.bits == 0)
        0
    else
        (@as(u256, 1) << @intCast(info.bits)) - 1;
    const truncated = raw & mask;

    const result: i256 = switch (info.signedness) {
        .unsigned => @intCast(truncated),
        .signed => signed: {
            if (info.bits == 0 or truncated & (@as(u256, 1) << @intCast(info.bits - 1)) == 0) {
                break :signed @intCast(truncated);
            }
            break :signed @as(i256, @intCast(truncated)) - (@as(i256, 1) << @intCast(info.bits));
        },
    };
    return (try analyser.intValueWithType(dest_ty, result) orelse return null).ipIndex();
}

fn resolveInternPoolValue(analyser: *Analyser, options: ResolveOptions) Error!?InternPool.Index {
    const old_resolve_number_literal_values = analyser.resolve_number_literal_values;
    const old_evaluate_comptime_values = analyser.evaluate_comptime_values;
    const old_evaluate_comptime_control_flow = analyser.evaluate_comptime_control_flow;
    analyser.resolve_number_literal_values = true;
    analyser.evaluate_comptime_values = true;
    analyser.evaluate_comptime_control_flow = true;
    defer {
        analyser.resolve_number_literal_values = old_resolve_number_literal_values;
        analyser.evaluate_comptime_values = old_evaluate_comptime_values;
        analyser.evaluate_comptime_control_flow = old_evaluate_comptime_control_flow;
    }

    const resolved_length = try analyser.resolveTypeOfNode(options) orelse return null;
    switch (resolved_length.data) {
        .ip_index => |payload| return payload.index,
        else => return null,
    }
}

fn resolveComptimeValue(analyser: *Analyser, options: ResolveOptions) Error!?Type {
    const old_resolve_number_literal_values = analyser.resolve_number_literal_values;
    const old_evaluate_comptime_values = analyser.evaluate_comptime_values;
    const old_evaluate_comptime_control_flow = analyser.evaluate_comptime_control_flow;
    analyser.resolve_number_literal_values = true;
    analyser.evaluate_comptime_values = true;
    analyser.evaluate_comptime_control_flow = true;
    defer {
        analyser.resolve_number_literal_values = old_resolve_number_literal_values;
        analyser.evaluate_comptime_values = old_evaluate_comptime_values;
        analyser.evaluate_comptime_control_flow = old_evaluate_comptime_control_flow;
    }

    const value = try analyser.resolveTypeOfNode(options) orelse return null;
    return switch (value.data) {
        .ip_index => |payload| if (payload.index != null) value else null,
        .enum_value => value,
        .string_value => value,
        else => null,
    };
}

fn resolveEnumValueTag(
    analyser: *Analyser,
    enum_type: Type,
    node_handle: NodeWithHandle,
) Error!?[]const u8 {
    if (!enum_type.isEnumType()) return null;
    const tree = &node_handle.handle.tree;
    const tag = switch (tree.nodeTag(node_handle.node)) {
        .enum_literal => try analyser.identifierTokenName(tree, tree.nodeMainToken(node_handle.node)) orelse return null,
        .field_access => tag: {
            const lhs_node, const name_token = tree.nodeData(node_handle.node).node_and_token;
            const lhs = try analyser.resolveTypeOfNodeInternal(.of(lhs_node, node_handle.handle)) orelse return null;
            if (!lhs.eql(enum_type)) return null;
            break :tag try analyser.identifierTokenName(tree, name_token) orelse return null;
        },
        .builtin_call,
        .builtin_call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        => tag: {
            if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node_handle.node)), "@enumFromInt")) return null;
            var buffer: [2]Ast.Node.Index = undefined;
            const params = tree.builtinCallParams(&buffer, node_handle.node).?;
            if (params.len != 1) return null;
            const int_value = try analyser.resolveIntegerLiteral(i256, .of(params[0], node_handle.handle)) orelse return null;
            break :tag try analyser.resolveEnumTagFromIntValue(enum_type, int_value) orelse return null;
        },
        else => return null,
    };
    const decl = try enum_type.lookupSymbol(analyser, tag) orelse return null;
    if (decl.decl != .ast_node or !decl.handle.tree.nodeTag(decl.decl.ast_node).isContainerField()) return null;
    return tag;
}

fn enumValue(analyser: *Analyser, enum_type: Type, tag: []const u8) Error!Type {
    return .{
        .data = .{ .enum_value = .{
            .enum_type = try analyser.allocType(enum_type),
            .tag = tag,
            .int_value = try analyser.resolveEnumTagIntValue(enum_type, tag),
        } },
        .is_type_val = false,
    };
}

fn resolveEnumTagIntValue(
    analyser: *Analyser,
    enum_type: Type,
    tag: []const u8,
) Error!?InternPool.Index {
    const container = switch (enum_type.data) {
        .container => |container| container,
        else => return null,
    };
    const handle = container.scope_handle.handle;
    const tree = &handle.tree;
    const node = container.scope_handle.toNode();
    var buffer: [2]Ast.Node.Index = undefined;
    const declaration = tree.fullContainerDecl(&buffer, node) orelse return null;
    if (tree.tokenTag(declaration.ast.main_token) != .keyword_enum) return null;

    var field_count: u32 = 0;
    for (declaration.ast.members) |member| {
        if (tree.fullContainerField(member) != null) field_count += 1;
    }
    if (field_count == 0) return null;

    const tag_type = if (declaration.ast.arg.unwrap()) |arg| blk: {
        const resolved = try analyser.resolveTypeOfNodeInternal(.{
            .node_handle = .of(arg, handle),
            .container_type = enum_type,
        }) orelse return null;
        break :blk resolved.ipIndex() orelse return null;
    } else blk: {
        const bits: u16 = @intCast(std.math.log2_int_ceil(u32, field_count));
        break :blk try analyser.ip.get(.{ .int_type = .{ .signedness = .unsigned, .bits = bits } });
    };

    var next_value: ?i256 = 0;
    for (declaration.ast.members) |member| {
        const field = tree.fullContainerField(member) orelse continue;
        if (field.ast.value_expr.unwrap()) |value_expr| {
            const value_index = try analyser.resolveInternPoolValue(.{
                .node_handle = .of(value_expr, handle),
                .container_type = enum_type,
            });
            next_value = if (value_index) |index| analyser.ip.toInt(index, i256) else null;
        }

        const field_name = try analyser.identifierTokenName(tree, field.ast.main_token) orelse continue;
        if (std.mem.eql(u8, field_name, tag)) {
            const value = next_value orelse return null;
            const raw = try analyser.internComptimeInt(value);
            var err_msg: ErrorMsg = undefined;
            const coerced = try analyser.ip.coerce(analyser.arena, tag_type, raw, builtin.target, &err_msg);
            if (coerced == .none or analyser.ip.isUnknown(coerced)) return null;
            return coerced;
        }

        if (next_value) |value| {
            next_value = std.math.add(i256, value, 1) catch null;
        }
    }
    return null;
}

fn resolveEnumTagFromIntValue(
    analyser: *Analyser,
    enum_type: Type,
    int_value: i256,
) Error!?[]const u8 {
    const container = switch (enum_type.data) {
        .container => |container| container,
        else => return null,
    };
    const handle = container.scope_handle.handle;
    const tree = &handle.tree;
    const node = container.scope_handle.toNode();
    var buffer: [2]Ast.Node.Index = undefined;
    const declaration = tree.fullContainerDecl(&buffer, node) orelse return null;
    if (tree.tokenTag(declaration.ast.main_token) != .keyword_enum) return null;

    var next_value: ?i256 = 0;
    for (declaration.ast.members) |member| {
        const field = tree.fullContainerField(member) orelse continue;
        if (field.ast.value_expr.unwrap()) |value_expr| {
            const value_index = try analyser.resolveInternPoolValue(.{
                .node_handle = .of(value_expr, handle),
                .container_type = enum_type,
            });
            next_value = if (value_index) |index| analyser.ip.toInt(index, i256) else null;
        }

        const tag = try analyser.identifierTokenName(tree, field.ast.main_token) orelse continue;
        if (next_value == int_value) return tag;
        if (next_value) |value| {
            next_value = std.math.add(i256, value, 1) catch null;
        }
    }
    return null;
}

fn tupleFieldCount(analyser: *Analyser, ty: Type) ?usize {
    if (!ty.is_type_val) return null;
    return switch (ty.data) {
        .tuple => |fields| fields.len,
        .ip_index => |payload| switch (analyser.ip.indexToKey(payload.index orelse return null)) {
            .tuple_type => |info| info.types.len,
            else => null,
        },
        else => null,
    };
}

fn resolveIntegerLiteral(analyser: *Analyser, comptime T: type, options: ResolveOptions) Error!?T {
    const ip_index = try analyser.resolveInternPoolValue(options) orelse return null;
    return analyser.ip.toInt(ip_index, T);
}

fn resolveBoolValue(analyser: *Analyser, options: ResolveOptions) Error!?bool {
    return switch (try analyser.resolveInternPoolValue(options) orelse return null) {
        .bool_true => true,
        .bool_false => false,
        else => null,
    };
}

fn resolveIfConditionValue(analyser: *Analyser, options: ResolveOptions) Error!?bool {
    const value = try analyser.resolveComptimeValue(options) orelse return null;
    if (value.data != .ip_index) return null;
    return switch (analyser.ip.indexToKey(value.data.ip_index.index.?)) {
        .simple_value => |simple| switch (simple) {
            .bool_true => true,
            .bool_false => false,
            .null_value => false,
            else => null,
        },
        .null_value => false,
        .optional_value => true,
        else => null,
    };
}

fn internComptimeInt(analyser: *Analyser, value: i256) error{OutOfMemory}!InternPool.Index {
    if (value >= 0 and value <= std.math.maxInt(u64)) {
        return analyser.ip.get(.{ .int_u64_value = .{
            .ty = .comptime_int_type,
            .int = @intCast(value),
        } });
    }
    if (value >= std.math.minInt(i64) and value <= std.math.maxInt(i64)) {
        return analyser.ip.get(.{ .int_i64_value = .{
            .ty = .comptime_int_type,
            .int = @intCast(value),
        } });
    }

    var big_int: std.math.big.int.Managed = try .initSet(analyser.gpa, value);
    defer big_int.deinit();
    return analyser.ip.getBigInt(.comptime_int_type, big_int.toConst());
}

fn intValueWithType(
    analyser: *Analyser,
    result_type: InternPool.Index,
    value: i256,
) error{OutOfMemory}!?Type {
    const raw_value = try analyser.internComptimeInt(value);
    if (result_type == .comptime_int_type) return Type.fromIP(analyser, result_type, raw_value);

    var err_msg: ErrorMsg = undefined;
    const coerced = try analyser.ip.coerce(analyser.arena, result_type, raw_value, builtin.target, &err_msg);
    if (coerced == .none or analyser.ip.isUnknown(coerced)) return null;
    return Type.fromIP(analyser, result_type, coerced);
}

fn resolveSelfBinaryValue(
    analyser: *Analyser,
    tag: Ast.Node.Tag,
    operand: Type,
) error{OutOfMemory}!?Type {
    const payload = switch (operand.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    if (payload.index) |index| {
        if (analyser.ip.isUndefined(index)) return operand.withoutIPIndex(analyser);
    }
    const scalar_tag = analyser.ip.zigTypeTag(payload.type);
    if (scalar_tag == .bool and tag == .bit_xor) {
        return Type.fromIP(analyser, .bool_type, .bool_false);
    }
    if (analyser.fixedWidthIntegerBounds(payload.type) != null) {
        return analyser.intValueWithType(payload.type, 0);
    }

    const vector = switch (analyser.ip.indexToKey(payload.type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    const child_tag = analyser.ip.zigTypeTag(vector.child);
    if (child_tag != .bool or tag != .bit_xor) {
        _ = analyser.fixedWidthIntegerBounds(vector.child) orelse return null;
    }
    if (analyser.aggregateValues(operand)) |source_values| {
        if (source_values.len != vector.len) return null;
        for (0..vector.len) |i| {
            if (analyser.ip.isUndefined(source_values.at(@intCast(i), analyser.ip))) return null;
        }
    }

    const zero: InternPool.Index = if (child_tag == .bool)
        .bool_false
    else
        (try analyser.intValueWithType(vector.child, 0) orelse return null).ipIndex() orelse return null;
    const values = try analyser.gpa.alloc(InternPool.Index, vector.len);
    defer analyser.gpa.free(values);
    @memset(values, zero);
    return analyser.aggregateValue(Type.fromIP(analyser, payload.type, null), values);
}

fn resolveComplementaryBinaryValue(
    analyser: *Analyser,
    tag: Ast.Node.Tag,
    operand: Type,
) error{OutOfMemory}!?Type {
    const payload = switch (operand.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    if (payload.index) |index| {
        if (analyser.ip.isUndefined(index)) return operand.withoutIPIndex(analyser);
    }

    const scalar_tag = analyser.ip.zigTypeTag(payload.type);
    if (scalar_tag == .bool) {
        const value: InternPool.Index = switch (tag) {
            .bool_and, .bit_and => .bool_false,
            .bool_or, .bit_or, .bit_xor => .bool_true,
            else => return null,
        };
        return Type.fromIP(analyser, .bool_type, value);
    }
    if (analyser.fixedWidthIntegerBounds(payload.type)) |bounds| {
        const value: i256 = switch (tag) {
            .bit_and => 0,
            .add, .add_wrap, .add_sat, .bit_or, .bit_xor => if (bounds.min < 0) -1 else bounds.max,
            else => return null,
        };
        return analyser.intValueWithType(payload.type, value);
    }

    const vector = switch (analyser.ip.indexToKey(payload.type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    const known: InternPool.Index = if (analyser.ip.zigTypeTag(vector.child) == .bool)
        switch (tag) {
            .bit_and => .bool_false,
            .bit_or, .bit_xor => .bool_true,
            else => return null,
        }
    else if (analyser.fixedWidthIntegerBounds(vector.child)) |bounds|
        (try analyser.intValueWithType(vector.child, switch (tag) {
            .bit_and => 0,
            .add, .add_wrap, .add_sat, .bit_or, .bit_xor => if (bounds.min < 0) -1 else bounds.max,
            else => return null,
        }) orelse return null).ipIndex() orelse return null
    else
        return null;

    const source_values = analyser.aggregateValues(operand);
    if (source_values) |values| if (values.len != vector.len) return null;
    const unknown = try analyser.ip.getUnknown(vector.child);
    const values = try analyser.gpa.alloc(InternPool.Index, vector.len);
    defer analyser.gpa.free(values);
    for (values, 0..) |*value, i| {
        value.* = if (source_values) |source|
            if (analyser.ip.isUndefined(source.at(@intCast(i), analyser.ip))) unknown else known
        else
            known;
    }
    return analyser.aggregateValue(Type.fromIP(analyser, payload.type, null), values);
}

const IntegerBounds = struct {
    min: i256,
    max: i256,
};

fn fixedWidthIntegerBounds(analyser: *Analyser, int_type: InternPool.Index) ?IntegerBounds {
    if (analyser.ip.zigTypeTag(int_type) != .int) return null;
    const info = analyser.ip.intInfo(int_type, builtin.target);
    if (info.bits == 0 or info.bits > 128) return null;
    return switch (info.signedness) {
        .signed => .{
            .min = -(@as(i256, 1) << @intCast(info.bits - 1)),
            .max = (@as(i256, 1) << @intCast(info.bits - 1)) - 1,
        },
        .unsigned => .{
            .min = 0,
            .max = (@as(i256, 1) << @intCast(info.bits)) - 1,
        },
    };
}

fn resolveIntegerAbsorbingBinaryValue(
    analyser: *Analyser,
    tag: Ast.Node.Tag,
    lhs: Type,
    rhs: Type,
) error{OutOfMemory}!?Type {
    const lhs_payload = switch (lhs.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const rhs_payload = switch (rhs.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    if (lhs_payload.type != rhs_payload.type) return null;
    const bounds = analyser.fixedWidthIntegerBounds(lhs_payload.type) orelse return null;
    if (lhs_payload.index) |index| if (analyser.ip.isUndefined(index)) return null;
    if (rhs_payload.index) |index| if (analyser.ip.isUndefined(index)) return null;

    const absorbing: i256 = switch (tag) {
        .mul, .bit_and => 0,
        .bit_or => if (bounds.min < 0) -1 else bounds.max,
        else => return null,
    };
    const lhs_value = if (lhs_payload.index) |index| analyser.ip.toInt(index, i256) else null;
    const rhs_value = if (rhs_payload.index) |index| analyser.ip.toInt(index, i256) else null;
    if (lhs_value != absorbing and rhs_value != absorbing) return null;
    return analyser.intValueWithType(lhs_payload.type, absorbing);
}

fn resolveFixedWidthIntegerAbsorbingBinaryValue(
    analyser: *Analyser,
    tag: Ast.Node.Tag,
    lhs: Type,
    rhs: Type,
    result_type: InternPool.Index,
) error{OutOfMemory}!?Type {
    const lhs_payload = switch (lhs.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const rhs_payload = switch (rhs.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const bounds = analyser.fixedWidthIntegerBounds(result_type) orelse return null;
    if (lhs_payload.index) |index| if (analyser.ip.isUndefined(index)) return null;
    if (rhs_payload.index) |index| if (analyser.ip.isUndefined(index)) return null;

    const lhs_value = if (lhs_payload.index) |index| analyser.ip.toInt(index, i256) else null;
    const rhs_value = if (rhs_payload.index) |index| analyser.ip.toInt(index, i256) else null;
    const absorbing: ?i256 = switch (tag) {
        .mul_wrap, .mul_sat => if (lhs_value == 0 or rhs_value == 0) 0 else null,
        .shl_sat => if (lhs_value == 0) blk: {
            if (rhs_value) |shift| {
                if (shift < 0 or shift >= analyser.ip.intInfo(result_type, builtin.target).bits) return null;
            } else {
                const shift_bounds = analyser.fixedWidthIntegerBounds(rhs_payload.type) orelse return null;
                if (shift_bounds.min < 0 or shift_bounds.max >= analyser.ip.intInfo(result_type, builtin.target).bits) return null;
            }
            break :blk 0;
        } else null,
        .add_sat => if (bounds.min == 0 and (lhs_value == bounds.max or rhs_value == bounds.max)) bounds.max else null,
        .sub_sat => if (bounds.min == 0 and (lhs_value == 0 or rhs_value == bounds.max)) 0 else null,
        else => null,
    };
    return analyser.intValueWithType(result_type, absorbing orelse return null);
}

fn resolveIntegerRemainderByOneValue(
    analyser: *Analyser,
    lhs: Type,
    rhs: Type,
) error{OutOfMemory}!?Type {
    const lhs_payload = switch (lhs.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const rhs_payload = switch (rhs.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    if (lhs_payload.type != rhs_payload.type) return null;
    _ = analyser.fixedWidthIntegerBounds(lhs_payload.type) orelse return null;
    if (lhs_payload.index) |index| if (analyser.ip.isUndefined(index)) return null;
    const rhs_index = rhs_payload.index orelse return null;
    if (analyser.ip.isUndefined(rhs_index) or analyser.ip.toInt(rhs_index, i256) != 1) return null;
    return analyser.intValueWithType(lhs_payload.type, 0);
}

fn resolveZeroShiftValue(
    analyser: *Analyser,
    operand: Type,
    shift_operand: Type,
) error{OutOfMemory}!?Type {
    const payload = switch (operand.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const shift_payload = switch (shift_operand.data) {
        .ip_index => |shift_value| shift_value,
        else => return null,
    };
    _ = analyser.fixedWidthIntegerBounds(payload.type) orelse return null;
    const operand_index = payload.index orelse return null;
    if (analyser.ip.isUndefined(operand_index) or analyser.ip.toInt(operand_index, i256) != 0) return null;

    const operand_bits = analyser.ip.intInfo(payload.type, builtin.target).bits;
    if (shift_payload.index) |shift_index| {
        if (analyser.ip.isUndefined(shift_index)) return null;
        if (analyser.ip.toInt(shift_index, u16)) |shift| {
            if (shift >= operand_bits) return null;
        } else if (!analyser.ip.isUnknown(shift_index)) {
            return null;
        }
    }
    if (shift_payload.index == null or analyser.ip.isUnknown(shift_payload.index.?)) {
        const shift_bounds = analyser.fixedWidthIntegerBounds(shift_payload.type) orelse return null;
        if (shift_bounds.min < 0 or shift_bounds.max >= operand_bits) return null;
    }
    return analyser.intValueWithType(payload.type, 0);
}

fn resolveAllOnesRightShiftValue(
    analyser: *Analyser,
    operand: Type,
    shift_operand: Type,
) error{OutOfMemory}!?Type {
    const payload = switch (operand.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const shift_payload = switch (shift_operand.data) {
        .ip_index => |shift_value| shift_value,
        else => return null,
    };
    const bounds = analyser.fixedWidthIntegerBounds(payload.type) orelse return null;
    if (bounds.min >= 0) return null;
    const operand_index = payload.index orelse return null;
    if (analyser.ip.isUndefined(operand_index) or analyser.ip.toInt(operand_index, i256) != -1) return null;

    const operand_bits = analyser.ip.intInfo(payload.type, builtin.target).bits;
    if (shift_payload.index) |shift_index| {
        if (analyser.ip.isUndefined(shift_index)) return null;
        if (analyser.ip.toInt(shift_index, u16)) |shift| {
            if (shift >= operand_bits) return null;
        } else if (!analyser.ip.isUnknown(shift_index)) {
            return null;
        }
    }
    if (shift_payload.index == null or analyser.ip.isUnknown(shift_payload.index.?)) {
        const shift_bounds = analyser.fixedWidthIntegerBounds(shift_payload.type) orelse return null;
        if (shift_bounds.min < 0 or shift_bounds.max >= operand_bits) return null;
    }
    return analyser.intValueWithType(payload.type, -1);
}

fn resolveIntegerBinaryValue(
    analyser: *Analyser,
    tag: Ast.Node.Tag,
    lhs: Type,
    rhs: Type,
) error{OutOfMemory}!?Type {
    const lhs_payload = switch (lhs.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const rhs_payload = switch (rhs.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    if (try analyser.resolveIntegerAbsorbingBinaryValue(tag, lhs, rhs)) |value| return value;
    if (tag == .mod) {
        if (try analyser.resolveIntegerRemainderByOneValue(lhs, rhs)) |value| return value;
    }
    if (tag == .shl or tag == .shr) {
        if (try analyser.resolveZeroShiftValue(lhs, rhs)) |value| return value;
        if (tag == .shr) {
            if (try analyser.resolveAllOnesRightShiftValue(lhs, rhs)) |value| return value;
        }
    }
    const lhs_index = lhs_payload.index orelse return null;
    const rhs_index = rhs_payload.index orelse return null;
    const result_type = try analyser.resolvePeerTypesIP(lhs_payload.type, rhs_payload.type) orelse return null;
    const lhs_value = analyser.ip.toInt(lhs_index, i256);
    const rhs_value = analyser.ip.toInt(rhs_index, i256);
    const supports_big_integer = switch (tag) {
        .add, .sub, .mul, .bit_and, .bit_or, .bit_xor, .shl, .shr => true,
        else => false,
    };
    const wide_result = analyser.ip.zigTypeTag(result_type) == .int and
        analyser.ip.intInfo(result_type, builtin.target).bits > 128;
    if (supports_big_integer and (wide_result or lhs_value == null or rhs_value == null)) {
        var lhs_big = try analyser.managedIntegerValue(lhs_index) orelse return null;
        defer lhs_big.deinit();
        var rhs_big = try analyser.managedIntegerValue(rhs_index) orelse return null;
        defer rhs_big.deinit();
        var result: std.math.big.int.Managed = try .init(analyser.gpa);
        defer result.deinit();
        switch (tag) {
            .add => try result.add(&lhs_big, &rhs_big),
            .sub => try result.sub(&lhs_big, &rhs_big),
            .mul => try result.mul(&lhs_big, &rhs_big),
            .bit_and => try result.bitAnd(&lhs_big, &rhs_big),
            .bit_or => try result.bitOr(&lhs_big, &rhs_big),
            .bit_xor => try result.bitXor(&lhs_big, &rhs_big),
            .shl, .shr => {
                const shift = analyser.ip.toInt(rhs_index, u16) orelse return null;
                const lhs_type_tag = analyser.ip.zigTypeTag(lhs_payload.type) orelse return null;
                if (lhs_type_tag == .int) {
                    const info = analyser.ip.intInfo(lhs_payload.type, builtin.target);
                    if (info.bits == 0 or shift >= info.bits) return null;
                    if (tag == .shl) {
                        try result.shiftLeft(&lhs_big, shift);
                        if (!result.fitsInTwosComp(info.signedness, info.bits)) return null;
                    } else {
                        try result.shiftRight(&lhs_big, shift);
                    }
                } else if (lhs_type_tag == .comptime_int) {
                    if (tag == .shl)
                        try result.shiftLeft(&lhs_big, shift)
                    else
                        try result.shiftRight(&lhs_big, shift);
                } else {
                    return null;
                }
            },
            else => unreachable,
        }
        if (result_type != .comptime_int_type) {
            const info = analyser.ip.intInfo(result_type, builtin.target);
            if (!result.fitsInTwosComp(info.signedness, info.bits)) return null;
        }
        if (result.toInt(i256)) |scalar| {
            return analyser.intValueWithType(result_type, scalar);
        } else |_| {
            return Type.fromIP(
                analyser,
                result_type,
                try analyser.ip.getBigInt(result_type, result.toConst()),
            );
        }
    }
    if (lhs_value == null or rhs_value == null) return null;

    const value: i256 = switch (tag) {
        .add => std.math.add(i256, lhs_value.?, rhs_value.?) catch return null,
        .sub => std.math.sub(i256, lhs_value.?, rhs_value.?) catch return null,
        .mul => std.math.mul(i256, lhs_value.?, rhs_value.?) catch return null,
        .div => std.math.divTrunc(i256, lhs_value.?, rhs_value.?) catch return null,
        .mod => std.math.mod(i256, lhs_value.?, rhs_value.?) catch return null,
        .bit_and => lhs_value.? & rhs_value.?,
        .bit_xor => lhs_value.? ^ rhs_value.?,
        .bit_or => lhs_value.? | rhs_value.?,
        .shl => blk: {
            if (rhs_value.? < 0 or rhs_value.? >= @bitSizeOf(i256)) return null;
            break :blk std.math.shlExact(i256, lhs_value.?, @intCast(rhs_value.?)) catch return null;
        },
        .shr => blk: {
            if (rhs_value.? < 0 or rhs_value.? >= @bitSizeOf(i256)) return null;
            break :blk lhs_value.? >> @intCast(rhs_value.?);
        },
        else => return null,
    };

    return analyser.intValueWithType(result_type, value);
}

fn floatBinaryValue(comptime T: type, tag: Ast.Node.Tag, lhs: f128, rhs: f128) ?f128 {
    const a: T = @floatCast(lhs);
    const b: T = @floatCast(rhs);
    if (!std.math.isFinite(a) or !std.math.isFinite(b)) return null;
    const result: T = switch (tag) {
        .add => a + b,
        .sub => a - b,
        .mul => a * b,
        .div => if (b == 0) return null else a / b,
        else => return null,
    };
    if (!std.math.isFinite(result)) return null;
    return @floatCast(result);
}

fn resolveFloatBinaryValue(
    analyser: *Analyser,
    tag: Ast.Node.Tag,
    lhs: Type,
    rhs: Type,
) error{OutOfMemory}!?Type {
    const lhs_index = lhs.ipIndex() orelse return null;
    const rhs_index = rhs.ipIndex() orelse return null;
    const lhs_value = analyser.numericFloatValue(lhs_index) orelse return null;
    const rhs_value = analyser.numericFloatValue(rhs_index) orelse return null;
    const result_type = try analyser.resolvePeerTypesIP(
        analyser.ip.typeOf(lhs_index),
        analyser.ip.typeOf(rhs_index),
    ) orelse return null;
    const result = switch (result_type) {
        .f16_type => floatBinaryValue(f16, tag, lhs_value, rhs_value),
        .f32_type => floatBinaryValue(f32, tag, lhs_value, rhs_value),
        .f64_type => floatBinaryValue(f64, tag, lhs_value, rhs_value),
        .f80_type => floatBinaryValue(f80, tag, lhs_value, rhs_value),
        .f128_type, .comptime_float_type => floatBinaryValue(f128, tag, lhs_value, rhs_value),
        else => null,
    } orelse return null;
    const result_index = try analyser.coerceFloatValue(
        result_type,
        try analyser.ip.get(.{ .float_comptime_value = result }),
    ) orelse return null;
    return Type.fromIP(analyser, result_type, result_index);
}

fn resolveVectorBinaryValue(
    analyser: *Analyser,
    tag: Ast.Node.Tag,
    lhs: Type,
    rhs: Type,
) error{OutOfMemory}!?Type {
    const lhs_payload = switch (lhs.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const rhs_payload = switch (rhs.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const lhs_vector = switch (analyser.ip.indexToKey(lhs_payload.type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    const rhs_vector = switch (analyser.ip.indexToKey(rhs_payload.type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    if (lhs_vector.len != rhs_vector.len) return null;
    const result_type = try analyser.resolvePeerTypesIP(lhs_payload.type, rhs_payload.type) orelse return null;
    const result_vector = switch (analyser.ip.indexToKey(result_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    const lhs_values = analyser.aggregateValues(lhs);
    const rhs_values = analyser.aggregateValues(rhs);
    if ((lhs_values != null and lhs_values.?.len != lhs_vector.len) or
        (rhs_values != null and rhs_values.?.len != rhs_vector.len)) return null;
    const absorbing_value: ?i256 = if (analyser.fixedWidthIntegerBounds(result_vector.child)) |bounds|
        switch (tag) {
            .mul, .bit_and => 0,
            .bit_or => if (bounds.min < 0) -1 else bounds.max,
            else => null,
        }
    else
        null;
    const values = try analyser.gpa.alloc(InternPool.Index, result_vector.len);
    defer analyser.gpa.free(values);
    const unknown_lhs = try analyser.ip.getUnknown(lhs_vector.child);
    const unknown_rhs = try analyser.ip.getUnknown(rhs_vector.child);
    for (values, 0..) |*value, i| {
        const index: u32 = @intCast(i);
        const lhs_value = if (lhs_values) |slice| slice.at(index, analyser.ip) else unknown_lhs;
        const rhs_value = if (rhs_values) |slice| slice.at(index, analyser.ip) else unknown_rhs;
        if (!analyser.ip.isUndefined(lhs_value) and !analyser.ip.isUndefined(rhs_value)) {
            if (absorbing_value) |absorbing| {
                const lhs_int = analyser.ip.toInt(lhs_value, i256);
                const rhs_int = analyser.ip.toInt(rhs_value, i256);
                if (lhs_int == absorbing or rhs_int == absorbing) {
                    value.* = (try analyser.intValueWithType(result_vector.child, absorbing) orelse return null).ipIndex().?;
                    continue;
                }
            }
        }
        const lhs_element = Type.fromIP(analyser, lhs_vector.child, lhs_value);
        const rhs_element = Type.fromIP(analyser, rhs_vector.child, rhs_value);
        const result = try analyser.resolveIntegerBinaryValue(tag, lhs_element, rhs_element) orelse
            try analyser.resolveFloatBinaryValue(tag, lhs_element, rhs_element);
        value.* = if (result) |resolved| resolved.ipIndex() orelse try analyser.ip.getUnknown(result_vector.child) else try analyser.ip.getUnknown(result_vector.child);
    }
    return analyser.aggregateValue(Type.fromIP(analyser, result_type, null), values);
}

fn resolveBoolBinaryValue(
    analyser: *Analyser,
    tag: Ast.Node.Tag,
    lhs: Type,
    rhs: Type,
) ?Type {
    const lhs_payload = switch (lhs.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const rhs_payload = switch (rhs.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    if (lhs_payload.type != .bool_type or rhs_payload.type != .bool_type) return null;
    const lhs_value = lhs_payload.index;
    const rhs_value = rhs_payload.index;
    if (lhs_value) |value| if (analyser.ip.isUndefined(value)) return null;
    if (rhs_value) |value| if (analyser.ip.isUndefined(value)) return null;

    const result: InternPool.Index = switch (tag) {
        .bit_and => if (lhs_value == .bool_false or rhs_value == .bool_false)
            .bool_false
        else if (lhs_value == .bool_true and rhs_value == .bool_true)
            .bool_true
        else
            return null,
        .bit_or => if (lhs_value == .bool_true or rhs_value == .bool_true)
            .bool_true
        else if (lhs_value == .bool_false and rhs_value == .bool_false)
            .bool_false
        else
            return null,
        .bit_xor => if ((lhs_value == .bool_true or lhs_value == .bool_false) and
            (rhs_value == .bool_true or rhs_value == .bool_false))
            if ((lhs_value == .bool_true) != (rhs_value == .bool_true)) .bool_true else .bool_false
        else
            return null,
        else => return null,
    };
    return Type.fromIP(analyser, .bool_type, result);
}

fn resolveVectorBoolBinaryValue(
    analyser: *Analyser,
    tag: Ast.Node.Tag,
    lhs: Type,
    rhs: Type,
) error{OutOfMemory}!?Type {
    const lhs_payload = switch (lhs.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const rhs_payload = switch (rhs.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const lhs_vector = switch (analyser.ip.indexToKey(lhs_payload.type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    const rhs_vector = switch (analyser.ip.indexToKey(rhs_payload.type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    if (lhs_vector.len != rhs_vector.len or lhs_vector.child != .bool_type or rhs_vector.child != .bool_type) {
        return null;
    }
    const lhs_values = analyser.aggregateValues(lhs);
    const rhs_values = analyser.aggregateValues(rhs);
    if ((lhs_values != null and lhs_values.?.len != lhs_vector.len) or
        (rhs_values != null and rhs_values.?.len != rhs_vector.len)) return null;

    const values = try analyser.gpa.alloc(InternPool.Index, lhs_vector.len);
    defer analyser.gpa.free(values);
    for (values, 0..) |*value, i| {
        const index: u32 = @intCast(i);
        const lhs_value = if (lhs_values) |slice| slice.at(index, analyser.ip) else .unknown_unknown;
        const rhs_value = if (rhs_values) |slice| slice.at(index, analyser.ip) else .unknown_unknown;
        if (analyser.ip.isUndefined(lhs_value) or analyser.ip.isUndefined(rhs_value)) {
            value.* = try analyser.ip.getUnknown(.bool_type);
            continue;
        }
        value.* = switch (tag) {
            .bit_and => if (lhs_value == .bool_false or rhs_value == .bool_false)
                .bool_false
            else if (lhs_value == .bool_true and rhs_value == .bool_true)
                .bool_true
            else
                try analyser.ip.getUnknown(.bool_type),
            .bit_or => if (lhs_value == .bool_true or rhs_value == .bool_true)
                .bool_true
            else if (lhs_value == .bool_false and rhs_value == .bool_false)
                .bool_false
            else
                try analyser.ip.getUnknown(.bool_type),
            .bit_xor => if ((lhs_value == .bool_true or lhs_value == .bool_false) and
                (rhs_value == .bool_true or rhs_value == .bool_false))
                if ((lhs_value == .bool_true) != (rhs_value == .bool_true)) .bool_true else .bool_false
            else
                try analyser.ip.getUnknown(.bool_type),
            else => return null,
        };
    }
    return analyser.aggregateValue(Type.fromIP(analyser, lhs_payload.type, null), values);
}

fn resolveVectorBoolNotValue(analyser: *Analyser, operand: Type) error{OutOfMemory}!?Type {
    const payload = switch (operand.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const vector = switch (analyser.ip.indexToKey(payload.type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    if (vector.child != .bool_type) return null;
    const source_values = analyser.aggregateValues(operand) orelse return Type.fromIP(analyser, payload.type, null);
    if (source_values.len != vector.len) return null;

    const values = try analyser.gpa.alloc(InternPool.Index, vector.len);
    defer analyser.gpa.free(values);
    for (values, 0..) |*value, i| {
        value.* = switch (source_values.at(@intCast(i), analyser.ip)) {
            .bool_true => .bool_false,
            .bool_false => .bool_true,
            else => try analyser.ip.getUnknown(.bool_type),
        };
    }
    return analyser.aggregateValue(Type.fromIP(analyser, payload.type, null), values);
}

fn resolveVectorFixedWidthIntegerBinaryValue(
    analyser: *Analyser,
    tag: Ast.Node.Tag,
    lhs: Type,
    rhs: Type,
    result_type_override: ?InternPool.Index,
) error{OutOfMemory}!?Type {
    const lhs_payload = switch (lhs.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const rhs_payload = switch (rhs.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const lhs_vector = switch (analyser.ip.indexToKey(lhs_payload.type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    const rhs_vector = switch (analyser.ip.indexToKey(rhs_payload.type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    if (lhs_vector.len != rhs_vector.len) return null;
    const result_type = result_type_override orelse
        try analyser.resolvePeerTypesIP(lhs_payload.type, rhs_payload.type) orelse return null;
    const result_vector = switch (analyser.ip.indexToKey(result_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    if (analyser.ip.zigTypeTag(result_vector.child) != .int) return null;
    const lhs_values = analyser.aggregateValues(lhs);
    const rhs_values = analyser.aggregateValues(rhs);
    if ((lhs_values != null and lhs_values.?.len != lhs_vector.len) or
        (rhs_values != null and rhs_values.?.len != rhs_vector.len)) return null;
    const values = try analyser.gpa.alloc(InternPool.Index, result_vector.len);
    defer analyser.gpa.free(values);
    const unknown_lhs = try analyser.ip.getUnknown(lhs_vector.child);
    const unknown_rhs = try analyser.ip.getUnknown(rhs_vector.child);
    for (values, 0..) |*value, i| {
        const index: u32 = @intCast(i);
        const lhs_value = if (lhs_values) |slice| slice.at(index, analyser.ip) else unknown_lhs;
        const rhs_value = if (rhs_values) |slice| slice.at(index, analyser.ip) else unknown_rhs;
        const lhs_element = Type.fromIP(analyser, lhs_vector.child, lhs_value);
        const rhs_element = Type.fromIP(analyser, rhs_vector.child, rhs_value);
        const result = try analyser.resolveFixedWidthIntegerBinaryValue(
            tag,
            lhs_element,
            rhs_element,
            result_vector.child,
        );
        value.* = if (result) |resolved| resolved.ipIndex() orelse try analyser.ip.getUnknown(result_vector.child) else try analyser.ip.getUnknown(result_vector.child);
    }
    return analyser.aggregateValue(Type.fromIP(analyser, result_type, null), values);
}

fn floatRemainderValue(comptime T: type, tag: std.zig.BuiltinFn.Tag, lhs: f128, rhs: f128) ?f128 {
    const a: T = @floatCast(lhs);
    const b: T = @floatCast(rhs);
    if (!std.math.isFinite(a) or !std.math.isFinite(b) or b == 0) return null;
    const result: T = switch (tag) {
        .mod => @mod(a, b),
        .rem => @rem(a, b),
        else => return null,
    };
    if (!std.math.isFinite(result)) return null;
    return @floatCast(result);
}

fn resolveFloatRemainderValue(
    analyser: *Analyser,
    tag: std.zig.BuiltinFn.Tag,
    lhs: Type,
    rhs: Type,
) error{OutOfMemory}!?Type {
    const lhs_index = lhs.ipIndex() orelse return null;
    const rhs_index = rhs.ipIndex() orelse return null;
    const lhs_value = analyser.numericFloatValue(lhs_index) orelse return null;
    const rhs_value = analyser.numericFloatValue(rhs_index) orelse return null;
    const result_type = try analyser.resolvePeerTypesIP(
        analyser.ip.typeOf(lhs_index),
        analyser.ip.typeOf(rhs_index),
    ) orelse return null;
    const result = switch (result_type) {
        .f16_type => floatRemainderValue(f16, tag, lhs_value, rhs_value),
        .f32_type => floatRemainderValue(f32, tag, lhs_value, rhs_value),
        .f64_type => floatRemainderValue(f64, tag, lhs_value, rhs_value),
        .f80_type => floatRemainderValue(f80, tag, lhs_value, rhs_value),
        .f128_type, .comptime_float_type => floatRemainderValue(f128, tag, lhs_value, rhs_value),
        else => null,
    } orelse return null;
    const result_index = try analyser.coerceFloatValue(
        result_type,
        try analyser.ip.get(.{ .float_comptime_value = result }),
    ) orelse return null;
    return Type.fromIP(analyser, result_type, result_index);
}

fn floatDivisionValue(comptime T: type, tag: std.zig.BuiltinFn.Tag, lhs: f128, rhs: f128) ?f128 {
    const numerator: T = @floatCast(lhs);
    const denominator: T = @floatCast(rhs);
    if (!std.math.isFinite(numerator) or !std.math.isFinite(denominator) or denominator == 0) return null;
    const result: T = switch (tag) {
        .div_trunc, .div_exact => @divTrunc(numerator, denominator),
        .div_floor => @divFloor(numerator, denominator),
        else => return null,
    };
    if (!std.math.isFinite(result)) return null;
    if (tag == .div_exact and result * denominator != numerator) return null;
    return @floatCast(result);
}

fn resolveFloatDivisionValue(
    analyser: *Analyser,
    tag: std.zig.BuiltinFn.Tag,
    lhs: Type,
    rhs: Type,
) error{OutOfMemory}!?Type {
    const lhs_index = lhs.ipIndex() orelse return null;
    const rhs_index = rhs.ipIndex() orelse return null;
    const lhs_value = analyser.numericFloatValue(lhs_index) orelse return null;
    const rhs_value = analyser.numericFloatValue(rhs_index) orelse return null;
    const result_type = try analyser.resolvePeerTypesIP(
        analyser.ip.typeOf(lhs_index),
        analyser.ip.typeOf(rhs_index),
    ) orelse return null;
    const result = switch (result_type) {
        .f16_type => floatDivisionValue(f16, tag, lhs_value, rhs_value),
        .f32_type => floatDivisionValue(f32, tag, lhs_value, rhs_value),
        .f64_type => floatDivisionValue(f64, tag, lhs_value, rhs_value),
        .f80_type => floatDivisionValue(f80, tag, lhs_value, rhs_value),
        .f128_type, .comptime_float_type => floatDivisionValue(f128, tag, lhs_value, rhs_value),
        else => null,
    } orelse return null;
    const result_index = try analyser.coerceFloatValue(
        result_type,
        try analyser.ip.get(.{ .float_comptime_value = result }),
    ) orelse return null;
    return Type.fromIP(analyser, result_type, result_index);
}

fn resolveVectorDivisionValue(
    analyser: *Analyser,
    tag: std.zig.BuiltinFn.Tag,
    lhs: Type,
    rhs: Type,
) error{OutOfMemory}!?Type {
    const lhs_payload = switch (lhs.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const rhs_payload = switch (rhs.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const lhs_vector = switch (analyser.ip.indexToKey(lhs_payload.type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    const rhs_vector = switch (analyser.ip.indexToKey(rhs_payload.type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    if (lhs_vector.len != rhs_vector.len) return null;
    const result_type = try analyser.resolvePeerTypesIP(lhs_payload.type, rhs_payload.type) orelse return null;
    const result_vector = switch (analyser.ip.indexToKey(result_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    const lhs_values = analyser.aggregateValues(lhs);
    const rhs_values = analyser.aggregateValues(rhs);
    if ((lhs_values != null and lhs_values.?.len != lhs_vector.len) or
        (rhs_values != null and rhs_values.?.len != rhs_vector.len)) return null;
    const values = try analyser.gpa.alloc(InternPool.Index, result_vector.len);
    defer analyser.gpa.free(values);
    const unknown_lhs = try analyser.ip.getUnknown(lhs_vector.child);
    const unknown_rhs = try analyser.ip.getUnknown(rhs_vector.child);
    for (values, 0..) |*value, i| {
        const index: u32 = @intCast(i);
        const lhs_element = Type.fromIP(
            analyser,
            lhs_vector.child,
            if (lhs_values) |slice| slice.at(index, analyser.ip) else unknown_lhs,
        );
        const rhs_element = Type.fromIP(
            analyser,
            rhs_vector.child,
            if (rhs_values) |slice| slice.at(index, analyser.ip) else unknown_rhs,
        );
        const result = try analyser.resolveIntegerDivisionValue(tag, lhs_element, rhs_element) orelse
            try analyser.resolveFloatDivisionValue(tag, lhs_element, rhs_element) orelse
            try analyser.resolveFloatRemainderValue(tag, lhs_element, rhs_element);
        value.* = if (result) |resolved| resolved.ipIndex() orelse try analyser.ip.getUnknown(result_vector.child) else try analyser.ip.getUnknown(result_vector.child);
    }
    return analyser.aggregateValue(Type.fromIP(analyser, result_type, null), values);
}

fn resolveFixedWidthIntegerBinaryValue(
    analyser: *Analyser,
    tag: Ast.Node.Tag,
    lhs: Type,
    rhs: Type,
    result_type_override: ?InternPool.Index,
) error{OutOfMemory}!?Type {
    const lhs_payload = switch (lhs.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const rhs_payload = switch (rhs.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const result_type = result_type_override orelse
        try analyser.resolvePeerTypesIP(lhs_payload.type, rhs_payload.type) orelse return null;
    if (try analyser.resolveFixedWidthIntegerAbsorbingBinaryValue(tag, lhs, rhs, result_type)) |value| return value;
    const lhs_index = lhs_payload.index orelse return null;
    const rhs_index = rhs_payload.index orelse return null;
    if (analyser.ip.zigTypeTag(result_type) != .int) return null;
    const int_info = analyser.ip.intInfo(result_type, builtin.target);
    if (int_info.bits == 0) return null;
    if (int_info.bits > 128) {
        var lhs_big = try analyser.managedIntegerValue(lhs_index) orelse return null;
        defer lhs_big.deinit();
        var rhs_big = try analyser.managedIntegerValue(rhs_index) orelse return null;
        defer rhs_big.deinit();
        var result: std.math.big.int.Managed = try .init(analyser.gpa);
        defer result.deinit();
        switch (tag) {
            .add_wrap => _ = try result.addWrap(&lhs_big, &rhs_big, int_info.signedness, int_info.bits),
            .sub_wrap => _ = try result.subWrap(&lhs_big, &rhs_big, int_info.signedness, int_info.bits),
            .mul_wrap => try result.mulWrap(&lhs_big, &rhs_big, int_info.signedness, int_info.bits),
            .add_sat => try result.addSat(&lhs_big, &rhs_big, int_info.signedness, int_info.bits),
            .sub_sat => try result.subSat(&lhs_big, &rhs_big, int_info.signedness, int_info.bits),
            .mul_sat => {
                try result.mul(&lhs_big, &rhs_big);
                try result.saturate(&result, int_info.signedness, int_info.bits);
            },
            .shl_sat => {
                const shift = analyser.ip.toInt(rhs_index, u16) orelse return null;
                if (shift >= int_info.bits) return null;
                try result.shiftLeftSat(&lhs_big, shift, int_info.signedness, int_info.bits);
            },
            else => return null,
        }
        if (result.toInt(i256)) |scalar| {
            return analyser.intValueWithType(result_type, scalar);
        } else |_| {
            return Type.fromIP(
                analyser,
                result_type,
                try analyser.ip.getBigInt(result_type, result.toConst()),
            );
        }
    }

    const value: i256 = switch (int_info.signedness) {
        .unsigned => unsigned: {
            const a = analyser.ip.toInt(lhs_index, u128) orelse return null;
            const b = analyser.ip.toInt(rhs_index, u128) orelse return null;
            const a_wide: u256 = a;
            const b_wide: u256 = b;
            const modulus = @as(u256, 1) << @intCast(int_info.bits);
            const max = modulus - 1;
            const result: u256 = switch (tag) {
                .add_wrap => (a_wide + b_wide) & max,
                .sub_wrap => (a_wide + modulus - b_wide) & max,
                .mul_wrap => (a_wide * b_wide) & max,
                .add_sat => @min(a_wide + b_wide, max),
                .sub_sat => if (a_wide >= b_wide) a_wide - b_wide else 0,
                .mul_sat => @min(a_wide * b_wide, max),
                .shl_sat => blk: {
                    if (b_wide >= int_info.bits) return null;
                    break :blk @min(a_wide << @intCast(b_wide), max);
                },
                else => return null,
            };
            break :unsigned @intCast(result);
        },
        .signed => signed: {
            const a = analyser.ip.toInt(lhs_index, i128) orelse return null;
            const b = analyser.ip.toInt(rhs_index, i128) orelse return null;
            const a_wide: i256 = a;
            const b_wide: i256 = b;
            const min = -(@as(i256, 1) << @intCast(int_info.bits - 1));
            const max = (@as(i256, 1) << @intCast(int_info.bits - 1)) - 1;
            const mathematical: i256 = switch (tag) {
                .add_wrap, .add_sat => a_wide + b_wide,
                .sub_wrap, .sub_sat => a_wide - b_wide,
                .mul_wrap, .mul_sat => a_wide * b_wide,
                .shl_sat => blk: {
                    if (b_wide < 0 or b_wide >= int_info.bits) return null;
                    break :blk a_wide * (@as(i256, 1) << @intCast(b_wide));
                },
                else => return null,
            };
            break :signed switch (tag) {
                .add_sat, .sub_sat, .mul_sat, .shl_sat => std.math.clamp(mathematical, min, max),
                .add_wrap, .sub_wrap, .mul_wrap => blk: {
                    const modulus = @as(u256, 1) << @intCast(int_info.bits);
                    const mask = modulus - 1;
                    const raw = @as(u256, @bitCast(mathematical)) & mask;
                    const sign_bit = @as(u256, 1) << @intCast(int_info.bits - 1);
                    break :blk if (raw & sign_bit == 0)
                        @intCast(raw)
                    else
                        @as(i256, @intCast(raw)) - @as(i256, @intCast(modulus));
                },
                else => return null,
            };
        },
    };
    return analyser.intValueWithType(result_type, value);
}

fn overflowTupleValue(
    analyser: *Analyser,
    result_type: InternPool.Index,
    result_value: ?InternPool.Index,
    overflowed: ?bool,
) error{OutOfMemory}!Type {
    const tuple_type = try analyser.ip.get(.{ .tuple_type = .{
        .types = try analyser.ip.getIndexSlice(&.{ result_type, .u1_type }),
        .values = try analyser.ip.getIndexSlice(&.{ .none, .none }),
    } });
    const aggregate = try analyser.ip.get(.{ .aggregate = .{
        .ty = tuple_type,
        .values = try analyser.ip.getIndexSlice(&.{
            result_value orelse try analyser.ip.getUnknown(result_type),
            if (overflowed) |value|
                if (value) .one_u1 else .zero_u1
            else
                try analyser.ip.getUnknown(.u1_type),
        }),
    } });
    return Type.fromIP(analyser, tuple_type, aggregate);
}

fn coerceKnownIntegerValue(
    analyser: *Analyser,
    result_type: InternPool.Index,
    value: ?InternPool.Index,
) error{OutOfMemory}!?InternPool.Index {
    const index = value orelse return null;
    const int = analyser.ip.toInt(index, i256) orelse return null;
    return (try analyser.intValueWithType(result_type, int) orelse return null).ipIndex();
}

fn resolveOverflowValue(
    analyser: *Analyser,
    tag: std.zig.BuiltinFn.Tag,
    lhs: Type,
    rhs: Type,
    same_operand: bool,
    complementary_operands: bool,
) error{OutOfMemory}!?Type {
    const lhs_payload = switch (lhs.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const rhs_payload = switch (rhs.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const result_type = if (tag == .shl_with_overflow)
        lhs_payload.type
    else
        try analyser.resolvePeerTypesIP(lhs_payload.type, rhs_payload.type) orelse return null;
    const bounds = analyser.fixedWidthIntegerBounds(result_type) orelse return null;
    if (lhs_payload.index) |index| if (analyser.ip.isUndefined(index)) return null;
    if (rhs_payload.index) |index| if (analyser.ip.isUndefined(index)) return null;

    const lhs_value = if (lhs_payload.index) |index| analyser.ip.toInt(index, i256) else null;
    const rhs_value = if (rhs_payload.index) |index| analyser.ip.toInt(index, i256) else null;
    const zero = (try analyser.intValueWithType(result_type, 0) orelse return null).ipIndex().?;
    switch (tag) {
        .add_with_overflow => {
            if (complementary_operands) {
                const all_ones = (try analyser.intValueWithType(
                    result_type,
                    if (bounds.min < 0) -1 else bounds.max,
                ) orelse return null).ipIndex().?;
                return try analyser.overflowTupleValue(result_type, all_ones, false);
            }
            if (lhs_value == 0 or rhs_value == 0) {
                const source_value = if (lhs_value == 0) rhs_payload.index else lhs_payload.index;
                const result_value = try analyser.coerceKnownIntegerValue(result_type, source_value);
                return try analyser.overflowTupleValue(result_type, result_value, false);
            }
        },
        .sub_with_overflow => {
            if (same_operand) return try analyser.overflowTupleValue(result_type, zero, false);
            if (rhs_value == 0) {
                const result_value = try analyser.coerceKnownIntegerValue(result_type, lhs_payload.index);
                return try analyser.overflowTupleValue(result_type, result_value, false);
            }
        },
        .mul_with_overflow => {
            if (lhs_value == 0 or rhs_value == 0) {
                return try analyser.overflowTupleValue(result_type, zero, false);
            }
            if (lhs_value == 1 or rhs_value == 1) {
                const source_value = if (lhs_value == 1) rhs_payload.index else lhs_payload.index;
                const result_value = try analyser.coerceKnownIntegerValue(result_type, source_value);
                return try analyser.overflowTupleValue(result_type, result_value, false);
            }
        },
        .shl_with_overflow => {
            if (try analyser.resolveZeroShiftValue(lhs, rhs)) |result| {
                return try analyser.overflowTupleValue(result_type, result.ipIndex(), false);
            }
            if (rhs_value == 0) {
                const result_value = try analyser.coerceKnownIntegerValue(result_type, lhs_payload.index);
                return try analyser.overflowTupleValue(result_type, result_value, false);
            }
        },
        else => return null,
    }

    const lhs_index = lhs_payload.index orelse return null;
    const rhs_index = rhs_payload.index orelse return null;
    const info = analyser.ip.intInfo(result_type, builtin.target);

    const result: i256, const overflowed = switch (info.signedness) {
        .unsigned => unsigned: {
            const a: u256 = analyser.ip.toInt(lhs_index, u128) orelse return null;
            const b: u256 = analyser.ip.toInt(rhs_index, u128) orelse return null;
            const modulus = @as(u256, 1) << @intCast(info.bits);
            const max = modulus - 1;
            const mathematical: u256 = switch (tag) {
                .add_with_overflow => a + b,
                .sub_with_overflow => if (a >= b) a - b else a + modulus - b,
                .mul_with_overflow => a * b,
                .shl_with_overflow => blk: {
                    if (b >= info.bits) return null;
                    break :blk a << @intCast(b);
                },
                else => return null,
            };
            const overflow = switch (tag) {
                .sub_with_overflow => a < b,
                else => mathematical > max,
            };
            break :unsigned .{ @as(i256, @intCast(mathematical & max)), overflow };
        },
        .signed => signed: {
            const a: i256 = analyser.ip.toInt(lhs_index, i128) orelse return null;
            const b: i256 = analyser.ip.toInt(rhs_index, i128) orelse return null;
            const min = -(@as(i256, 1) << @intCast(info.bits - 1));
            const max = (@as(i256, 1) << @intCast(info.bits - 1)) - 1;
            const mathematical: i256 = switch (tag) {
                .add_with_overflow => a + b,
                .sub_with_overflow => a - b,
                .mul_with_overflow => a * b,
                .shl_with_overflow => blk: {
                    if (b < 0 or b >= info.bits) return null;
                    break :blk a * (@as(i256, 1) << @intCast(b));
                },
                else => return null,
            };
            const modulus = @as(u256, 1) << @intCast(info.bits);
            const mask = modulus - 1;
            const raw = @as(u256, @bitCast(mathematical)) & mask;
            const sign_bit = @as(u256, 1) << @intCast(info.bits - 1);
            const wrapped: i256 = if (raw & sign_bit == 0)
                @intCast(raw)
            else
                @as(i256, @intCast(raw)) - @as(i256, @intCast(modulus));
            break :signed .{ wrapped, mathematical < min or mathematical > max };
        },
    };
    const result_value = (try analyser.intValueWithType(result_type, result) orelse return null).ipIndex().?;
    return try analyser.overflowTupleValue(result_type, result_value, overflowed);
}

fn resolveReduceOperation(
    analyser: *Analyser,
    node_handle: NodeWithHandle,
) Error!?std.builtin.ReduceOp {
    const tree = &node_handle.handle.tree;
    if (tree.nodeTag(node_handle.node) == .enum_literal) {
        const name = try analyser.identifierTokenName(tree, tree.nodeMainToken(node_handle.node)) orelse return null;
        return std.meta.stringToEnum(std.builtin.ReduceOp, name);
    }
    const value = try analyser.resolveTypeOfNodeInternal(.of(node_handle.node, node_handle.handle)) orelse return null;
    return switch (value.data) {
        .enum_value => |enum_value| std.meta.stringToEnum(std.builtin.ReduceOp, enum_value.tag),
        else => null,
    };
}

fn resolveSignedness(
    analyser: *Analyser,
    node_handle: NodeWithHandle,
) Error!?std.builtin.Signedness {
    const tree = &node_handle.handle.tree;
    if (tree.nodeTag(node_handle.node) == .enum_literal) {
        const name = try analyser.identifierTokenName(tree, tree.nodeMainToken(node_handle.node)) orelse return null;
        return std.meta.stringToEnum(std.builtin.Signedness, name);
    }
    const value = try analyser.resolveTypeOfNodeInternal(.of(node_handle.node, node_handle.handle)) orelse return null;
    return switch (value.data) {
        .enum_value => |enum_value| std.meta.stringToEnum(std.builtin.Signedness, enum_value.tag),
        else => null,
    };
}

fn resolvePointerSize(
    analyser: *Analyser,
    node_handle: NodeWithHandle,
) Error!?std.builtin.Type.Pointer.Size {
    const tree = &node_handle.handle.tree;
    if (tree.nodeTag(node_handle.node) == .enum_literal) {
        const name = try analyser.identifierTokenName(tree, tree.nodeMainToken(node_handle.node)) orelse return null;
        return std.meta.stringToEnum(std.builtin.Type.Pointer.Size, name);
    }
    const value = try analyser.resolveTypeOfNodeInternal(.of(node_handle.node, node_handle.handle)) orelse return null;
    return switch (value.data) {
        .enum_value => |enum_value| std.meta.stringToEnum(std.builtin.Type.Pointer.Size, enum_value.tag),
        else => null,
    };
}

fn resolveAddressSpace(
    analyser: *Analyser,
    options: ResolveOptions,
) Error!?std.builtin.AddressSpace {
    const tree = &options.node_handle.handle.tree;
    if (tree.nodeTag(options.node_handle.node) == .enum_literal) {
        const name = try analyser.identifierTokenName(tree, tree.nodeMainToken(options.node_handle.node)) orelse return null;
        return std.meta.stringToEnum(std.builtin.AddressSpace, name);
    }
    const value = try analyser.resolveComptimeValue(options) orelse return null;
    if (value.ipIndex()) |index| if (analyser.ip.isNull(index)) return .generic;
    return switch (value.data) {
        .enum_value => |enum_value| std.meta.stringToEnum(std.builtin.AddressSpace, enum_value.tag),
        else => null,
    };
}

fn resolvePointerAttributes(
    analyser: *Analyser,
    size: std.builtin.Type.Pointer.Size,
    options: ResolveOptions,
) Error!?InternPool.Key.Pointer.Flags {
    const node_handle = options.node_handle;
    const tree = &node_handle.handle.tree;
    var buffer: [2]Ast.Node.Index = undefined;
    const literal = tree.fullStructInit(&buffer, node_handle.node) orelse return null;
    if (literal.ast.type_expr.unwrap() != null) return null;

    var flags: InternPool.Key.Pointer.Flags = .{ .size = size };
    for (literal.ast.fields) |field_node| {
        const field_name_token = tree.firstToken(field_node) - 2;
        if (tree.tokenTag(field_name_token) != .identifier) return null;
        const field_name = try analyser.identifierTokenName(tree, field_name_token) orelse return null;
        const field_options: ResolveOptions = .{
            .node_handle = .of(field_node, node_handle.handle),
            .container_type = options.container_type,
        };
        if (std.mem.eql(u8, field_name, "const")) {
            flags.is_const = try analyser.resolveBoolValue(field_options) orelse return null;
        } else if (std.mem.eql(u8, field_name, "volatile")) {
            flags.is_volatile = try analyser.resolveBoolValue(field_options) orelse return null;
        } else if (std.mem.eql(u8, field_name, "allowzero")) {
            flags.is_allowzero = try analyser.resolveBoolValue(field_options) orelse return null;
        } else if (std.mem.eql(u8, field_name, "align")) {
            const alignment_value = try analyser.resolveComptimeValue(field_options) orelse return null;
            if (alignment_value.ipIndex()) |index| {
                if (analyser.ip.isNull(index)) continue;
            }
            const alignment = try analyser.resolveIntegerLiteral(u16, field_options) orelse return null;
            if (!std.math.isPowerOfTwo(alignment)) return null;
            flags.alignment = alignment;
        } else if (std.mem.eql(u8, field_name, "addrspace")) {
            flags.address_space = try analyser.resolveAddressSpace(field_options) orelse return null;
        } else {
            return null;
        }
    }
    return flags;
}

fn resolveTupleTypeConstructor(
    analyser: *Analyser,
    options: ResolveOptions,
) Error!?Type {
    if (try analyser.resolveTypeOfNodeInternal(options)) |fields| {
        if (fields.data == .ip_index) {
            const pointer = switch (analyser.ip.indexToKey(fields.data.ip_index.type)) {
                .pointer_type => |pointer| pointer,
                else => null,
            };
            if (pointer) |info| if (info.flags.size == .one) {
                const field_values = switch (analyser.ip.indexToKey(info.elem_type)) {
                    .tuple_type => |tuple| tuple.values,
                    else => null,
                };
                if (field_values) |values| {
                    const element_types = try analyser.arena.alloc(Type, values.len);
                    for (element_types, 0..) |*element_type, i| {
                        const value = values.at(@intCast(i), analyser.ip);
                        if (value == .none or analyser.ip.typeOf(value) != .type_type) break;
                        element_type.* = Type.fromIP(analyser, .type_type, value);
                    } else return try Type.createTupleType(analyser, element_types);
                }
            };
        }
    }

    const literal_options = try analyser.resolveConstInitializer(options) orelse return null;

    const node_handle = literal_options.node_handle;
    const tree = &node_handle.handle.tree;
    if (tree.nodeTag(node_handle.node) != .address_of) return null;
    const literal_node = tree.nodeData(node_handle.node).node;
    var buffer: [2]Ast.Node.Index = undefined;
    const literal = tree.fullArrayInit(&buffer, literal_node) orelse return null;
    if (literal.ast.type_expr.unwrap() != null) return null;
    const element_types = try analyser.arena.alloc(Type, literal.ast.elements.len);
    for (literal.ast.elements, element_types) |element_node, *element_type| {
        element_type.* = try analyser.resolveTypeOfNodeInternal(.{
            .node_handle = .of(element_node, node_handle.handle),
            .container_type = literal_options.container_type,
        }) orelse return null;
        if (!element_type.is_type_val) return null;
    }
    return try Type.createTupleType(analyser, element_types);
}

fn resolveConstInitializer(analyser: *Analyser, options: ResolveOptions) Error!?ResolveOptions {
    const declaration = try analyser.resolveVarDeclAlias(.{
        .decl = .{ .ast_node = options.node_handle.node },
        .handle = options.node_handle.handle,
        .container_type = options.container_type,
    }) orelse return options;
    const declaration_node = switch (declaration.decl) {
        .ast_node => |decl_node| decl_node,
        else => return null,
    };
    const tree = &declaration.handle.tree;
    const variable = tree.fullVarDecl(declaration_node) orelse return null;
    if (tree.tokenTag(variable.ast.mut_token) != .keyword_const) return null;
    return .{
        .node_handle = .of(variable.ast.init_node.unwrap() orelse return null, declaration.handle),
        .container_type = declaration.container_type,
    };
}

fn resolveStringListLiteral(
    analyser: *Analyser,
    options: ResolveOptions,
) Error!?[]const []const u8 {
    const literal_options = try analyser.resolveConstInitializer(options) orelse return null;
    const node_handle = literal_options.node_handle;
    const tree = &node_handle.handle.tree;
    if (tree.nodeTag(node_handle.node) != .address_of) return null;
    const literal_node = tree.nodeData(node_handle.node).node;
    var buffer: [2]Ast.Node.Index = undefined;
    const literal = tree.fullArrayInit(&buffer, literal_node) orelse return null;
    if (literal.ast.type_expr.unwrap() != null) return null;

    const strings = try analyser.arena.alloc([]const u8, literal.ast.elements.len);
    for (literal.ast.elements, strings, 0..) |element, *string, i| {
        string.* = try analyser.resolveStringLiteral(.{
            .node_handle = .of(element, node_handle.handle),
            .container_type = literal_options.container_type,
        }) orelse return null;
        for (strings[0..i]) |previous| {
            if (std.mem.eql(u8, previous, string.*)) return null;
        }
    }
    return strings;
}

fn resolveContainerLayout(
    analyser: *Analyser,
    node_handle: NodeWithHandle,
) Error!?std.builtin.Type.ContainerLayout {
    const tree = &node_handle.handle.tree;
    if (tree.nodeTag(node_handle.node) == .enum_literal) {
        const name = try analyser.identifierTokenName(tree, tree.nodeMainToken(node_handle.node)) orelse return null;
        return std.meta.stringToEnum(std.builtin.Type.ContainerLayout, name);
    }
    const value = try analyser.resolveTypeOfNodeInternal(.of(node_handle.node, node_handle.handle)) orelse return null;
    return switch (value.data) {
        .enum_value => |enum_value| std.meta.stringToEnum(std.builtin.Type.ContainerLayout, enum_value.tag),
        else => null,
    };
}

fn isNullComptimeValue(analyser: *Analyser, options: ResolveOptions) Error!bool {
    const value = try analyser.resolveComptimeValue(options) orelse return false;
    return if (value.ipIndex()) |index| analyser.ip.isNull(index) else false;
}

fn isEmptyStructAttributeList(
    node_handle: NodeWithHandle,
    expected_len: usize,
) bool {
    const tree = &node_handle.handle.tree;
    if (tree.nodeTag(node_handle.node) != .address_of) return false;
    const literal_node = tree.nodeData(node_handle.node).node;
    var buffer: [2]Ast.Node.Index = undefined;
    const literal = tree.fullArrayInit(&buffer, literal_node) orelse return false;
    if (literal.ast.type_expr.unwrap() != null or literal.ast.elements.len != expected_len) return false;
    for (literal.ast.elements) |element| {
        var struct_buffer: [2]Ast.Node.Index = undefined;
        const attributes = tree.fullStructInit(&struct_buffer, element) orelse return false;
        if (attributes.ast.type_expr.unwrap() != null or attributes.ast.fields.len != 0) return false;
    }
    return true;
}

fn resolveStructFieldAlignments(
    analyser: *Analyser,
    options: ResolveOptions,
    expected_len: usize,
) Error!?[]const u16 {
    const literal_options = try analyser.resolveConstInitializer(options) orelse return null;
    const node_handle = literal_options.node_handle;
    const tree = &node_handle.handle.tree;
    if (tree.nodeTag(node_handle.node) != .address_of) return null;
    const literal_node = tree.nodeData(node_handle.node).node;
    var buffer: [2]Ast.Node.Index = undefined;
    const literal = tree.fullArrayInit(&buffer, literal_node) orelse return null;
    if (literal.ast.type_expr.unwrap() != null or literal.ast.elements.len != expected_len) return null;

    const alignments = try analyser.arena.alloc(u16, expected_len);
    @memset(alignments, 0);
    for (literal.ast.elements, alignments) |element, *alignment| {
        var struct_buffer: [2]Ast.Node.Index = undefined;
        const attributes = tree.fullStructInit(&struct_buffer, element) orelse return null;
        if (attributes.ast.type_expr.unwrap() != null) return null;
        var seen_comptime = false;
        var seen_align = false;
        var seen_default = false;
        for (attributes.ast.fields) |field_node| {
            const field_name_token = tree.firstToken(field_node) - 2;
            if (tree.tokenTag(field_name_token) != .identifier) return null;
            const field_name = try analyser.identifierTokenName(tree, field_name_token) orelse return null;
            const field_options: ResolveOptions = .{
                .node_handle = .of(field_node, node_handle.handle),
                .container_type = literal_options.container_type,
            };
            if (std.mem.eql(u8, field_name, "comptime")) {
                if (seen_comptime) return null;
                seen_comptime = true;
                if (try analyser.resolveBoolValue(field_options) orelse return null) return null;
            } else if (std.mem.eql(u8, field_name, "align")) {
                if (seen_align) return null;
                seen_align = true;
                if (try analyser.isNullComptimeValue(field_options)) continue;
                alignment.* = try analyser.resolveIntegerLiteral(u16, field_options) orelse return null;
                if (!std.math.isPowerOfTwo(alignment.*)) return null;
            } else if (std.mem.eql(u8, field_name, "default_value_ptr")) {
                if (seen_default) return null;
                seen_default = true;
                if (!try analyser.isNullComptimeValue(field_options)) return null;
            } else {
                return null;
            }
        }
    }
    return alignments;
}

fn resolveStructTypeConstructor(
    analyser: *Analyser,
    params: []const Ast.Node.Index,
    handle: *DocumentStore.Handle,
    container_type: ?Type,
) Error!?Type {
    if (params.len != 5) return null;
    const layout = try analyser.resolveContainerLayout(.of(params[0], handle)) orelse return null;
    if (layout != .auto) return null;
    if (!try analyser.isNullComptimeValue(.{
        .node_handle = .of(params[1], handle),
        .container_type = container_type,
    })) return null;

    const names = try analyser.resolveStringListLiteral(.{
        .node_handle = .of(params[2], handle),
        .container_type = container_type,
    }) orelse return null;
    const field_tuple = try analyser.resolveTupleTypeConstructor(.{
        .node_handle = .of(params[3], handle),
        .container_type = container_type,
    }) orelse return null;
    const field_tuple_index = field_tuple.ipIndex() orelse return null;
    const field_type_slice = switch (analyser.ip.indexToKey(field_tuple_index)) {
        .tuple_type => |tuple| tuple.types,
        else => return null,
    };
    if (names.len != field_type_slice.len) return null;
    const alignments = try analyser.resolveStructFieldAlignments(.{
        .node_handle = .of(params[4], handle),
        .container_type = container_type,
    }, names.len) orelse return null;
    const field_types = try field_type_slice.dupe(analyser.gpa, analyser.ip);
    defer analyser.gpa.free(field_types);

    var fields: std.array_hash_map.Auto(InternPool.String, InternPool.Struct.Field) = .empty;
    errdefer fields.deinit(analyser.gpa);
    try fields.ensureTotalCapacity(analyser.gpa, names.len);
    for (names, field_types, alignments) |name, field_type, alignment| {
        const name_index = try analyser.ip.string_pool.getOrPutString(analyser.store.io, analyser.gpa, name);
        fields.putAssumeCapacityNoClobber(name_index, .{ .ty = field_type, .alignment = alignment });
    }

    const struct_index = try analyser.ip.createStruct(.{
        .fields = fields,
        .owner_decl = .none,
        .namespace = .none,
        .layout = .auto,
        .backing_int_ty = .none,
        .status = .fully_resolved,
    });
    fields = .empty;
    const struct_type = try analyser.ip.get(.{ .struct_type = struct_index });
    return Type.fromIP(analyser, .type_type, struct_type);
}

fn resolveUnionFieldAlignments(
    analyser: *Analyser,
    options: ResolveOptions,
    expected_len: usize,
) Error!?[]const u16 {
    const literal_options = try analyser.resolveConstInitializer(options) orelse return null;
    const node_handle = literal_options.node_handle;
    const tree = &node_handle.handle.tree;
    if (tree.nodeTag(node_handle.node) != .address_of) return null;
    const literal_node = tree.nodeData(node_handle.node).node;
    var buffer: [2]Ast.Node.Index = undefined;
    const literal = tree.fullArrayInit(&buffer, literal_node) orelse return null;
    if (literal.ast.type_expr.unwrap() != null or literal.ast.elements.len != expected_len) return null;

    const alignments = try analyser.arena.alloc(u16, expected_len);
    @memset(alignments, 0);
    for (literal.ast.elements, alignments) |element, *alignment| {
        var struct_buffer: [2]Ast.Node.Index = undefined;
        const attributes = tree.fullStructInit(&struct_buffer, element) orelse return null;
        if (attributes.ast.type_expr.unwrap() != null) return null;
        var seen_align = false;
        for (attributes.ast.fields) |field_node| {
            const field_name_token = tree.firstToken(field_node) - 2;
            if (tree.tokenTag(field_name_token) != .identifier) return null;
            const field_name = try analyser.identifierTokenName(tree, field_name_token) orelse return null;
            if (!std.mem.eql(u8, field_name, "align") or seen_align) return null;
            seen_align = true;
            const field_options: ResolveOptions = .{
                .node_handle = .of(field_node, node_handle.handle),
                .container_type = literal_options.container_type,
            };
            if (try analyser.isNullComptimeValue(field_options)) continue;
            alignment.* = try analyser.resolveIntegerLiteral(u16, field_options) orelse return null;
            if (!std.math.isPowerOfTwo(alignment.*)) return null;
        }
    }
    return alignments;
}

fn resolveUnionTypeConstructor(
    analyser: *Analyser,
    params: []const Ast.Node.Index,
    handle: *DocumentStore.Handle,
    container_type: ?Type,
) Error!?Type {
    if (params.len != 5) return null;
    const layout = try analyser.resolveContainerLayout(.of(params[0], handle)) orelse return null;
    if (layout != .auto) return null;
    if (!try analyser.isNullComptimeValue(.{
        .node_handle = .of(params[1], handle),
        .container_type = container_type,
    })) return null;

    const names = try analyser.resolveStringListLiteral(.{
        .node_handle = .of(params[2], handle),
        .container_type = container_type,
    }) orelse return null;
    const field_tuple = try analyser.resolveTupleTypeConstructor(.{
        .node_handle = .of(params[3], handle),
        .container_type = container_type,
    }) orelse return null;
    const field_tuple_index = field_tuple.ipIndex() orelse return null;
    const field_type_slice = switch (analyser.ip.indexToKey(field_tuple_index)) {
        .tuple_type => |tuple| tuple.types,
        else => return null,
    };
    if (names.len != field_type_slice.len) return null;
    const alignments = try analyser.resolveUnionFieldAlignments(.{
        .node_handle = .of(params[4], handle),
        .container_type = container_type,
    }, names.len) orelse return null;
    const field_types = try field_type_slice.dupe(analyser.gpa, analyser.ip);
    defer analyser.gpa.free(field_types);

    var fields: std.array_hash_map.Auto(InternPool.String, InternPool.Union.Field) = .empty;
    errdefer fields.deinit(analyser.gpa);
    try fields.ensureTotalCapacity(analyser.gpa, names.len);
    for (names, field_types, alignments) |name, field_type, alignment| {
        const name_index = try analyser.ip.string_pool.getOrPutString(analyser.store.io, analyser.gpa, name);
        fields.putAssumeCapacityNoClobber(name_index, .{ .ty = field_type, .alignment = alignment });
    }

    const union_index = try analyser.ip.createUnion(.{
        .tag_type = .none,
        .fields = fields,
        .namespace = .none,
        .layout = .auto,
        .status = .fully_resolved,
    });
    fields = .empty;
    const union_type = try analyser.ip.get(.{ .union_type = union_index });
    return Type.fromIP(analyser, .type_type, union_type);
}

fn resolveFnParameterAttributes(
    analyser: *Analyser,
    options: ResolveOptions,
    expected_len: usize,
) Error!?std.StaticBitSet(32) {
    if (expected_len > 32) return null;
    const node_handle = options.node_handle;
    const tree = &node_handle.handle.tree;
    if (tree.nodeTag(node_handle.node) != .address_of) return null;
    const literal_node = tree.nodeData(node_handle.node).node;
    var buffer: [2]Ast.Node.Index = undefined;
    const literal = tree.fullArrayInit(&buffer, literal_node) orelse return null;
    if (literal.ast.type_expr.unwrap() != null or literal.ast.elements.len != expected_len) return null;

    var noalias_bits: std.StaticBitSet(32) = .empty;
    for (literal.ast.elements, 0..) |element, i| {
        var struct_buffer: [2]Ast.Node.Index = undefined;
        const attributes = tree.fullStructInit(&struct_buffer, element) orelse return null;
        if (attributes.ast.type_expr.unwrap() != null) return null;
        for (attributes.ast.fields) |field_node| {
            const field_name_token = tree.firstToken(field_node) - 2;
            if (tree.tokenTag(field_name_token) != .identifier) return null;
            const field_name = try analyser.identifierTokenName(tree, field_name_token) orelse return null;
            if (!std.mem.eql(u8, field_name, "noalias")) return null;
            const value = try analyser.resolveBoolValue(.{
                .node_handle = .of(field_node, node_handle.handle),
                .container_type = options.container_type,
            }) orelse return null;
            noalias_bits.setValue(i, value);
        }
    }
    return noalias_bits;
}

fn resolveCallingConventionTag(
    analyser: *Analyser,
    node_handle: NodeWithHandle,
) Error!?std.builtin.CallingConvention.Tag {
    const tree = &node_handle.handle.tree;
    if (tree.nodeTag(node_handle.node) != .enum_literal) return null;
    const name = try analyser.identifierTokenName(tree, tree.nodeMainToken(node_handle.node)) orelse return null;
    if (std.mem.eql(u8, name, "c")) {
        const convention = builtin.target.cCallingConvention() orelse return null;
        return convention;
    }
    if (!std.mem.eql(u8, name, "auto") and
        !std.mem.eql(u8, name, "async") and
        !std.mem.eql(u8, name, "naked") and
        !std.mem.eql(u8, name, "inline")) return null;
    return std.meta.stringToEnum(std.builtin.CallingConvention.Tag, name);
}

fn resolveFnAttributes(
    analyser: *Analyser,
    options: ResolveOptions,
) Error!?InternPool.Key.Function.Flags {
    const node_handle = options.node_handle;
    const tree = &node_handle.handle.tree;
    var buffer: [2]Ast.Node.Index = undefined;
    const literal = tree.fullStructInit(&buffer, node_handle.node) orelse return null;
    if (literal.ast.type_expr.unwrap() != null) return null;

    var flags: InternPool.Key.Function.Flags = .{};
    var seen_callconv = false;
    var seen_varargs = false;
    for (literal.ast.fields) |field_node| {
        const field_name_token = tree.firstToken(field_node) - 2;
        if (tree.tokenTag(field_name_token) != .identifier) return null;
        const field_name = try analyser.identifierTokenName(tree, field_name_token) orelse return null;
        if (std.mem.eql(u8, field_name, "callconv")) {
            if (seen_callconv) return null;
            seen_callconv = true;
            flags.calling_convention = try analyser.resolveCallingConventionTag(.of(field_node, node_handle.handle)) orelse return null;
        } else if (std.mem.eql(u8, field_name, "varargs")) {
            if (seen_varargs) return null;
            seen_varargs = true;
            flags.is_var_args = try analyser.resolveBoolValue(.{
                .node_handle = .of(field_node, node_handle.handle),
                .container_type = options.container_type,
            }) orelse return null;
        } else {
            return null;
        }
    }
    if (flags.is_var_args) {
        const convention = builtin.target.cCallingConvention() orelse return null;
        const c_tag: std.builtin.CallingConvention.Tag = convention;
        if (flags.calling_convention != c_tag) return null;
    }
    return flags;
}

fn floatReduceValue(
    comptime T: type,
    analyser: *Analyser,
    operation: std.builtin.ReduceOp,
    values: InternPool.Index.Slice,
) ?f128 {
    var result: T = @floatCast(analyser.floatValue(values.at(0, analyser.ip)) orelse return null);
    if (!std.math.isFinite(result)) return null;
    for (1..values.len) |i| {
        const value: T = @floatCast(analyser.floatValue(values.at(@intCast(i), analyser.ip)) orelse return null);
        if (!std.math.isFinite(value)) return null;
        result = switch (operation) {
            .Min => @min(result, value),
            .Max => @max(result, value),
            .Add => result + value,
            .Mul => result * value,
            else => return null,
        };
        if (!std.math.isFinite(result)) return null;
    }
    return @floatCast(result);
}

fn resolveReduceValue(
    analyser: *Analyser,
    operation: std.builtin.ReduceOp,
    operand: Type,
) error{OutOfMemory}!?Type {
    const payload = switch (operand.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const vector = switch (analyser.ip.indexToKey(payload.type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    if (vector.len == 0) return null;
    const values = analyser.aggregateValues(operand) orelse return null;
    if (values.len != vector.len) return null;

    if (vector.child == .bool_type) {
        if (operation != .And and operation != .Or and operation != .Xor) return null;
        for (0..values.len) |i| {
            if (analyser.ip.isUndefined(values.at(@intCast(i), analyser.ip))) return null;
        }
        var result = switch (operation) {
            .And => true,
            .Or, .Xor => false,
            else => unreachable,
        };
        var has_unknown = false;
        for (0..values.len) |i| {
            const value = switch (values.at(@intCast(i), analyser.ip)) {
                .bool_true => true,
                .bool_false => false,
                else => {
                    has_unknown = true;
                    continue;
                },
            };
            result = switch (operation) {
                .And => if (!value) return Type.fromIP(analyser, .bool_type, .bool_false) else result,
                .Or => if (value) return Type.fromIP(analyser, .bool_type, .bool_true) else result,
                .Xor => result != value,
                else => unreachable,
            };
        }
        if (has_unknown) return null;
        return Type.fromIP(analyser, .bool_type, if (result) .bool_true else .bool_false);
    }
    if (analyser.ip.zigTypeTag(vector.child) == .float) {
        const result = switch (vector.child) {
            .f16_type => floatReduceValue(f16, analyser, operation, values),
            .f32_type => floatReduceValue(f32, analyser, operation, values),
            .f64_type => floatReduceValue(f64, analyser, operation, values),
            .f80_type => floatReduceValue(f80, analyser, operation, values),
            .f128_type => floatReduceValue(f128, analyser, operation, values),
            else => null,
        } orelse return null;
        const result_index = try analyser.coerceFloatValue(
            vector.child,
            try analyser.ip.get(.{ .float_comptime_value = result }),
        ) orelse return null;
        return Type.fromIP(analyser, vector.child, result_index);
    }

    if (analyser.ip.zigTypeTag(vector.child) != .int) return null;
    for (0..values.len) |i| {
        if (analyser.ip.isUndefined(values.at(@intCast(i), analyser.ip))) return null;
    }
    if (analyser.fixedWidthIntegerBounds(vector.child)) |bounds| {
        const absorbing_value: ?i256 = switch (operation) {
            .Mul, .And => 0,
            .Or => if (bounds.min < 0) -1 else bounds.max,
            .Min => bounds.min,
            .Max => bounds.max,
            else => null,
        };
        if (absorbing_value) |absorbing| {
            for (0..values.len) |i| {
                const value = values.at(@intCast(i), analyser.ip);
                if (analyser.ip.toInt(value, i256)) |int| {
                    if (int == absorbing) return analyser.intValueWithType(vector.child, absorbing);
                }
            }
        }
    }
    var result = Type.fromIP(analyser, vector.child, values.at(0, analyser.ip));
    for (1..values.len) |i| {
        const candidate = Type.fromIP(analyser, vector.child, values.at(@intCast(i), analyser.ip));
        result = switch (operation) {
            .Add => try analyser.resolveFixedWidthIntegerBinaryValue(.add_wrap, result, candidate, vector.child),
            .Mul => try analyser.resolveFixedWidthIntegerBinaryValue(.mul_wrap, result, candidate, vector.child),
            .And => try analyser.resolveIntegerBinaryValue(.bit_and, result, candidate),
            .Or => try analyser.resolveIntegerBinaryValue(.bit_or, result, candidate),
            .Xor => try analyser.resolveIntegerBinaryValue(.bit_xor, result, candidate),
            .Min => if (analyser.resolveComparisonBool(.less_than, candidate, result) orelse return null) candidate else result,
            .Max => if (analyser.resolveComparisonBool(.greater_than, candidate, result) orelse return null) candidate else result,
        } orelse return null;
    }
    return result;
}

fn resolveEvenRuntimeSplatXorReduction(
    analyser: *Analyser,
    tree: *const Ast,
    handle: *DocumentStore.Handle,
    operand_node: Ast.Node.Index,
    operand: Type,
) error{OutOfMemory}!?Type {
    const payload = switch (operand.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const vector = switch (analyser.ip.indexToKey(payload.type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    if (vector.len == 0 or vector.len % 2 != 0) return null;

    var node = operand_node;
    switch (tree.nodeTag(node)) {
        .builtin_call,
        .builtin_call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        => {
            if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@as")) return null;
            var as_buffer: [2]Ast.Node.Index = undefined;
            const as_params = tree.builtinCallParams(&as_buffer, node).?;
            if (as_params.len != 2) return null;
            node = as_params[1];
        },
        else => {},
    }
    switch (tree.nodeTag(node)) {
        .builtin_call,
        .builtin_call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        => {},
        else => return null,
    }
    if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@splat")) return null;
    var splat_buffer: [2]Ast.Node.Index = undefined;
    const splat_params = tree.builtinCallParams(&splat_buffer, node).?;
    if (splat_params.len != 1 or
        !try analyser.isMutableIdentifierExpression(tree, handle, splat_params[0])) return null;

    if (vector.child == .bool_type) return Type.fromIP(analyser, .bool_type, .bool_false);
    _ = analyser.fixedWidthIntegerBounds(vector.child) orelse return null;
    return analyser.intValueWithType(vector.child, 0);
}

fn resolveSelectValue(
    analyser: *Analyser,
    element_type: InternPool.Index,
    predicate: Type,
    lhs: Type,
    rhs: Type,
) error{OutOfMemory}!?Type {
    const predicate_payload = switch (predicate.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const lhs_payload = switch (lhs.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const rhs_payload = switch (rhs.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const predicate_vector = switch (analyser.ip.indexToKey(predicate_payload.type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    const lhs_vector = switch (analyser.ip.indexToKey(lhs_payload.type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    const rhs_vector = switch (analyser.ip.indexToKey(rhs_payload.type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    if (predicate_vector.child != .bool_type or
        predicate_vector.len != lhs_vector.len or
        predicate_vector.len != rhs_vector.len or
        lhs_vector.child != element_type or
        rhs_vector.child != element_type) return null;

    const result_type = lhs_payload.type;
    const predicate_values = analyser.aggregateValues(predicate);
    const lhs_values = analyser.aggregateValues(lhs);
    const rhs_values = analyser.aggregateValues(rhs);

    const values = try analyser.gpa.alloc(InternPool.Index, lhs_vector.len);
    defer analyser.gpa.free(values);
    for (values, 0..) |*value, i| {
        const index: u32 = @intCast(i);
        const predicate_value = if (predicate_values) |slice| slice.at(index, analyser.ip) else .unknown_unknown;
        const lhs_value = if (lhs_values) |slice| slice.at(index, analyser.ip) else null;
        const rhs_value = if (rhs_values) |slice| slice.at(index, analyser.ip) else null;
        value.* = switch (predicate_value) {
            .bool_true => lhs_value orelse try analyser.ip.getUnknown(element_type),
            .bool_false => rhs_value orelse try analyser.ip.getUnknown(element_type),
            else => if (!analyser.ip.isUndefined(predicate_value) and
                lhs_value != null and
                rhs_value != null and
                lhs_value.? == rhs_value.? and
                !analyser.ip.isUndefined(lhs_value.?) and
                !analyser.ip.isUnknown(lhs_value.?))
                lhs_value.?
            else
                try analyser.ip.getUnknown(element_type),
        };
    }
    return analyser.aggregateValue(Type.fromIP(analyser, result_type, null), values);
}

fn resolveShuffleValue(
    analyser: *Analyser,
    element_type: InternPool.Index,
    lhs: Type,
    rhs: Type,
    mask: Type,
) error{OutOfMemory}!?Type {
    const lhs_payload = switch (lhs.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const rhs_payload = switch (rhs.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const mask_payload = switch (mask.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const lhs_vector = switch (analyser.ip.indexToKey(lhs_payload.type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    const rhs_vector = switch (analyser.ip.indexToKey(rhs_payload.type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    const mask_vector = switch (analyser.ip.indexToKey(mask_payload.type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    if (lhs_vector.child != element_type or
        rhs_vector.child != element_type or
        analyser.ip.zigTypeTag(mask_vector.child) != .int) return null;

    const result_type = try analyser.ip.get(.{ .vector_type = .{
        .len = mask_vector.len,
        .child = element_type,
    } });
    const lhs_values = analyser.aggregateValues(lhs);
    const rhs_values = analyser.aggregateValues(rhs);
    const mask_values = analyser.aggregateValues(mask);
    if (mask_values == null) return Type.fromIP(analyser, result_type, null);

    const values = try analyser.gpa.alloc(InternPool.Index, mask_vector.len);
    defer analyser.gpa.free(values);
    for (values, 0..) |*value, i| {
        const mask_value = analyser.ip.toInt(mask_values.?.at(@intCast(i), analyser.ip), i64) orelse {
            value.* = try analyser.ip.getUnknown(element_type);
            continue;
        };
        if (mask_value >= 0) {
            const index: u64 = @intCast(mask_value);
            value.* = if (index < lhs_vector.len and lhs_values != null)
                lhs_values.?.at(@intCast(index), analyser.ip)
            else
                try analyser.ip.getUnknown(element_type);
        } else {
            const index: u64 = @intCast(~mask_value);
            value.* = if (index < rhs_vector.len and rhs_values != null)
                rhs_values.?.at(@intCast(index), analyser.ip)
            else
                try analyser.ip.getUnknown(element_type);
        }
    }
    return analyser.aggregateValue(Type.fromIP(analyser, result_type, null), values);
}

fn resolveIntegerDivisionValue(
    analyser: *Analyser,
    tag: std.zig.BuiltinFn.Tag,
    lhs: Type,
    rhs: Type,
) error{OutOfMemory}!?Type {
    const lhs_payload = switch (lhs.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const rhs_payload = switch (rhs.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    if (tag == .mod or tag == .rem) {
        if (try analyser.resolveIntegerRemainderByOneValue(lhs, rhs)) |value| return value;
    }
    const lhs_index = lhs_payload.index orelse return null;
    const rhs_index = rhs_payload.index orelse return null;
    const result_type = try analyser.resolvePeerTypesIP(lhs_payload.type, rhs_payload.type) orelse return null;
    const lhs_value = analyser.ip.toInt(lhs_index, i256);
    const rhs_value = analyser.ip.toInt(rhs_index, i256);
    const wide_result = analyser.ip.zigTypeTag(result_type) == .int and
        analyser.ip.intInfo(result_type, builtin.target).bits > 128;
    if (wide_result or lhs_value == null or rhs_value == null) {
        var lhs_big = try analyser.managedIntegerValue(lhs_index) orelse return null;
        defer lhs_big.deinit();
        var rhs_big = try analyser.managedIntegerValue(rhs_index) orelse return null;
        defer rhs_big.deinit();
        if (rhs_big.toConst().eqlZero()) return null;

        var quotient: std.math.big.int.Managed = try .init(analyser.gpa);
        defer quotient.deinit();
        var remainder: std.math.big.int.Managed = try .init(analyser.gpa);
        defer remainder.deinit();
        const use_floor = tag == .div_floor or tag == .mod;
        if (use_floor) {
            try quotient.divFloor(&remainder, &lhs_big, &rhs_big);
        } else {
            try quotient.divTrunc(&remainder, &lhs_big, &rhs_big);
        }
        if (tag == .div_exact and !remainder.toConst().eqlZero()) return null;
        const result = switch (tag) {
            .mod, .rem => &remainder,
            .div_trunc, .div_floor, .div_exact => &quotient,
            else => return null,
        };
        if (result_type != .comptime_int_type) {
            const info = analyser.ip.intInfo(result_type, builtin.target);
            if (!result.fitsInTwosComp(info.signedness, info.bits)) return null;
        }
        if (result.toInt(i256)) |scalar| {
            return analyser.intValueWithType(result_type, scalar);
        } else |_| {
            return Type.fromIP(
                analyser,
                result_type,
                try analyser.ip.getBigInt(result_type, result.toConst()),
            );
        }
    }
    if (lhs_value == null or rhs_value == null) return null;
    if (rhs_value.? == 0 or (lhs_value.? == std.math.minInt(i256) and rhs_value.? == -1)) return null;

    const value: i256 = switch (tag) {
        .div_trunc => @divTrunc(lhs_value.?, rhs_value.?),
        .div_floor => @divFloor(lhs_value.?, rhs_value.?),
        .div_exact => blk: {
            if (@rem(lhs_value.?, rhs_value.?) != 0) return null;
            break :blk @divTrunc(lhs_value.?, rhs_value.?);
        },
        .mod => @mod(lhs_value.?, rhs_value.?),
        .rem => @rem(lhs_value.?, rhs_value.?),
        else => return null,
    };

    return analyser.intValueWithType(result_type, value);
}

fn resolveIntegerBoundaryComparison(
    analyser: *Analyser,
    tag: Ast.Node.Tag,
    lhs: Type,
    rhs: Type,
) ?bool {
    const lhs_payload = switch (lhs.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const rhs_payload = switch (rhs.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    if (lhs_payload.type != rhs_payload.type or analyser.ip.zigTypeTag(lhs_payload.type) != .int) return null;
    if (lhs_payload.index) |index| if (analyser.ip.isUndefined(index)) return null;
    if (rhs_payload.index) |index| if (analyser.ip.isUndefined(index)) return null;

    const lhs_known = if (lhs_payload.index) |index| !analyser.ip.isUnknown(index) else false;
    const rhs_known = if (rhs_payload.index) |index| !analyser.ip.isUnknown(index) else false;
    if (lhs_known == rhs_known) return null;

    const known_index = if (lhs_known) lhs_payload.index.? else rhs_payload.index.?;
    const boundary = integerBoundary(analyser, lhs_payload.type, known_index) orelse return null;
    return if (lhs_known) switch (tag) {
        .less_than => if (boundary == .max) false else null,
        .less_or_equal => if (boundary == .min) true else null,
        .greater_than => if (boundary == .min) false else null,
        .greater_or_equal => if (boundary == .max) true else null,
        else => null,
    } else switch (tag) {
        .less_than => if (boundary == .min) false else null,
        .less_or_equal => if (boundary == .max) true else null,
        .greater_than => if (boundary == .max) false else null,
        .greater_or_equal => if (boundary == .min) true else null,
        else => null,
    };
}

fn integerBoundary(
    analyser: *Analyser,
    int_type: InternPool.Index,
    value: InternPool.Index,
) ?enum { min, max } {
    const info = analyser.ip.intInfo(int_type, builtin.target);
    if (info.bits == 0) return null;
    if (info.bits <= 128) {
        const scalar = analyser.ip.toInt(value, i256) orelse return null;
        const bounds = analyser.fixedWidthIntegerBounds(int_type).?;
        if (scalar == bounds.min) return .min;
        if (scalar == bounds.max) return .max;
        return null;
    }

    if (info.signedness == .unsigned and analyser.ip.isZero(value)) return .min;
    const big = switch (analyser.ip.indexToKey(value)) {
        .int_big_value => |int_value| int_value.getConst(analyser.ip),
        else => return null,
    };
    return switch (info.signedness) {
        .unsigned => if (big.positive and big.bitCountAbs() == info.bits and big.popCount(info.bits) == info.bits) .max else null,
        .signed => if (big.positive)
            if (big.bitCountAbs() == info.bits - 1 and big.popCount(info.bits) == info.bits - 1) .max else null
        else if (big.bitCountAbs() == info.bits and big.abs().popCount(info.bits) == 1)
            .min
        else
            null,
    };
}

fn resolveComparisonValue(
    analyser: *Analyser,
    tag: Ast.Node.Tag,
    lhs: Type,
    rhs: Type,
) ?Type {
    if (analyser.resolveIntegerBoundaryComparison(tag, lhs, rhs)) |value| {
        return Type.fromIP(analyser, .bool_type, if (value) .bool_true else .bool_false);
    }
    if (lhs.data == .enum_value and rhs.data == .enum_value) {
        const lhs_value = lhs.data.enum_value;
        const rhs_value = rhs.data.enum_value;
        if (!lhs_value.enum_type.eql(rhs_value.enum_type.*)) return null;
        const equal = std.mem.eql(u8, lhs_value.tag, rhs_value.tag);
        return switch (tag) {
            .equal_equal => Type.fromIP(analyser, .bool_type, if (equal) .bool_true else .bool_false),
            .bang_equal => Type.fromIP(analyser, .bool_type, if (equal) .bool_false else .bool_true),
            else => null,
        };
    }

    const lhs_index = lhs.ipIndex();
    const rhs_index = rhs.ipIndex();
    if (lhs_index) |index| {
        if (analyser.ip.isUndefined(index) or analyser.ip.isUnknown(index)) return null;
    }
    if (rhs_index) |index| {
        if (analyser.ip.isUndefined(index) or analyser.ip.isUnknown(index)) return null;
    }
    const integer_order: ?std.math.Order = if (lhs_index != null and rhs_index != null and
        isIntegerValue(analyser, lhs_index.?) and isIntegerValue(analyser, rhs_index.?))
        integerValueOrder(analyser, lhs_index.?, rhs_index.?)
    else
        null;
    const lhs_int = if (lhs_index) |index| analyser.ip.toInt(index, i256) else null;
    const rhs_int = if (rhs_index) |index| analyser.ip.toInt(index, i256) else null;
    const lhs_float = if (lhs_index) |index| analyser.floatValue(index) else null;
    const rhs_float = if (rhs_index) |index| analyser.floatValue(index) else null;
    const lhs_numeric_float = lhs_float orelse if (lhs_index) |index| analyser.exactFloatFromInt(index) else null;
    const rhs_numeric_float = rhs_float orelse if (rhs_index) |index| analyser.exactFloatFromInt(index) else null;
    const result = switch (tag) {
        .equal_equal, .bang_equal => blk: {
            const equal = if (integer_order) |order|
                order == .eq
            else if (lhs_int != null and rhs_int != null)
                lhs_int.? == rhs_int.?
            else if (lhs_float != null and rhs_float != null)
                lhs_float.? == rhs_float.?
            else if (lhs_float != null or rhs_float != null)
                if (lhs_numeric_float != null and rhs_numeric_float != null)
                    lhs_numeric_float.? == rhs_numeric_float.?
                else
                    return null
            else if (lhs_index != null and rhs_index != null)
                lhs_index.? == rhs_index.?
            else if (lhs.is_type_val and rhs.is_type_val and lhs.data != .ip_index and rhs.data != .ip_index)
                lhs.eql(rhs)
            else
                return null;
            break :blk if (tag == .equal_equal) equal else !equal;
        },
        .less_than,
        .greater_than,
        .less_or_equal,
        .greater_or_equal,
        => blk: {
            if (integer_order) |order| {
                break :blk switch (tag) {
                    .less_than => order == .lt,
                    .greater_than => order == .gt,
                    .less_or_equal => order != .gt,
                    .greater_or_equal => order != .lt,
                    else => unreachable,
                };
            }
            if (lhs_int != null and rhs_int != null) {
                break :blk switch (tag) {
                    .less_than => lhs_int.? < rhs_int.?,
                    .greater_than => lhs_int.? > rhs_int.?,
                    .less_or_equal => lhs_int.? <= rhs_int.?,
                    .greater_or_equal => lhs_int.? >= rhs_int.?,
                    else => unreachable,
                };
            }
            if (lhs_float != null and rhs_float != null) {
                break :blk switch (tag) {
                    .less_than => lhs_float.? < rhs_float.?,
                    .greater_than => lhs_float.? > rhs_float.?,
                    .less_or_equal => lhs_float.? <= rhs_float.?,
                    .greater_or_equal => lhs_float.? >= rhs_float.?,
                    else => unreachable,
                };
            }
            if ((lhs_float != null or rhs_float != null) and
                lhs_numeric_float != null and rhs_numeric_float != null)
            {
                break :blk switch (tag) {
                    .less_than => lhs_numeric_float.? < rhs_numeric_float.?,
                    .greater_than => lhs_numeric_float.? > rhs_numeric_float.?,
                    .less_or_equal => lhs_numeric_float.? <= rhs_numeric_float.?,
                    .greater_or_equal => lhs_numeric_float.? >= rhs_numeric_float.?,
                    else => unreachable,
                };
            }
            return null;
        },
        else => return null,
    };
    return Type.fromIP(analyser, .bool_type, if (result) .bool_true else .bool_false);
}

fn isIntegerValue(analyser: *Analyser, index: InternPool.Index) bool {
    return switch (analyser.ip.zigTypeTag(analyser.ip.typeOf(index)) orelse return false) {
        .int, .comptime_int => true,
        else => false,
    };
}

fn integerValueOrder(
    analyser: *Analyser,
    lhs: InternPool.Index,
    rhs: InternPool.Index,
) ?std.math.Order {
    const lhs_key = analyser.ip.indexToKey(lhs);
    const rhs_key = analyser.ip.indexToKey(rhs);
    return switch (lhs_key) {
        inline .int_u64_value, .int_i64_value => |lhs_value| switch (rhs_key) {
            inline .int_u64_value, .int_i64_value => |rhs_value| std.math.order(@as(i128, lhs_value.int), @as(i128, rhs_value.int)),
            .int_big_value => |rhs_value| rhs_value.getConst(analyser.ip).orderAgainstScalar(lhs_value.int).invert(),
            else => null,
        },
        .int_big_value => |lhs_value| switch (rhs_key) {
            inline .int_u64_value, .int_i64_value => |rhs_value| lhs_value.getConst(analyser.ip).orderAgainstScalar(rhs_value.int),
            .int_big_value => |rhs_value| lhs_value.getConst(analyser.ip).order(rhs_value.getConst(analyser.ip)),
            else => null,
        },
        else => null,
    };
}

fn resolveSelfComparisonValue(
    analyser: *Analyser,
    tag: Ast.Node.Tag,
    operand: Type,
) error{OutOfMemory}!?Type {
    const payload = switch (operand.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const result = switch (tag) {
        .equal_equal, .less_or_equal, .greater_or_equal => true,
        .bang_equal, .less_than, .greater_than => false,
        else => return null,
    };
    const type_tag = analyser.ip.zigTypeTag(payload.type);
    const equality = tag == .equal_equal or tag == .bang_equal;
    if (type_tag == .int or
        (equality and (type_tag == .bool or
            type_tag == .error_set or
            (type_tag == .pointer and operand.pointerSize(analyser) != .slice))))
    {
        if (payload.index) |index| {
            if (analyser.ip.isUndefined(index)) return Type.fromIP(analyser, .bool_type, null);
        }
        return Type.fromIP(analyser, .bool_type, if (result) .bool_true else .bool_false);
    }

    const vector = switch (analyser.ip.indexToKey(payload.type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    const child_tag = analyser.ip.zigTypeTag(vector.child);
    if (child_tag != .int and
        !(child_tag == .bool and (tag == .equal_equal or tag == .bang_equal)))
    {
        return null;
    }
    const result_type = try analyser.ip.get(.{ .vector_type = .{
        .len = vector.len,
        .child = .bool_type,
    } });
    if (payload.index) |index| {
        if (analyser.ip.isUndefined(index)) return Type.fromIP(analyser, result_type, null);
    }

    const source_values = analyser.aggregateValues(operand);
    if (source_values) |values| if (values.len != vector.len) return null;
    const known = if (result) InternPool.Index.bool_true else .bool_false;
    const unknown = try analyser.ip.getUnknown(.bool_type);
    const values = try analyser.gpa.alloc(InternPool.Index, vector.len);
    defer analyser.gpa.free(values);
    for (values, 0..) |*value, i| {
        value.* = if (source_values) |source|
            if (analyser.ip.isUndefined(source.at(@intCast(i), analyser.ip))) unknown else known
        else
            known;
    }
    return analyser.aggregateValue(Type.fromIP(analyser, result_type, null), values);
}

fn hasReflexiveEquality(analyser: *Analyser, ty: InternPool.Index) bool {
    const type_tag = analyser.ip.zigTypeTag(ty) orelse return false;
    return switch (type_tag) {
        .int, .bool, .error_set, .@"enum" => true,
        .pointer => switch (analyser.ip.indexToKey(ty).pointer_type.flags.size) {
            .one, .many, .c => true,
            .slice => false,
        },
        .optional => analyser.hasReflexiveEquality(analyser.ip.childType(ty)),
        else => false,
    };
}

fn resolveComplementaryComparisonValue(
    analyser: *Analyser,
    tag: Ast.Node.Tag,
    operand: Type,
) error{OutOfMemory}!?Type {
    const payload = switch (operand.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const result = switch (tag) {
        .equal_equal => false,
        .bang_equal => true,
        else => return null,
    };
    if (payload.index) |index| {
        if (analyser.ip.isUndefined(index)) return null;
    }

    const type_tag = analyser.ip.zigTypeTag(payload.type);
    if (type_tag == .bool or analyser.fixedWidthIntegerBounds(payload.type) != null) {
        return Type.fromIP(analyser, .bool_type, if (result) .bool_true else .bool_false);
    }

    const vector = switch (analyser.ip.indexToKey(payload.type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    const child_tag = analyser.ip.zigTypeTag(vector.child);
    if (child_tag != .bool and analyser.fixedWidthIntegerBounds(vector.child) == null) return null;
    const result_type = try analyser.ip.get(.{ .vector_type = .{
        .len = vector.len,
        .child = .bool_type,
    } });
    const source_values = analyser.aggregateValues(operand);
    if (source_values) |values| if (values.len != vector.len) return null;
    const known = if (result) InternPool.Index.bool_true else .bool_false;
    const unknown = try analyser.ip.getUnknown(.bool_type);
    const values = try analyser.gpa.alloc(InternPool.Index, vector.len);
    defer analyser.gpa.free(values);
    for (values, 0..) |*value, i| {
        value.* = if (source_values) |source|
            if (analyser.ip.isUndefined(source.at(@intCast(i), analyser.ip))) unknown else known
        else
            known;
    }
    return analyser.aggregateValue(Type.fromIP(analyser, result_type, null), values);
}

fn resolveVectorComparisonValue(
    analyser: *Analyser,
    tag: Ast.Node.Tag,
    lhs: Type,
    rhs: Type,
) error{OutOfMemory}!?Type {
    const lhs_payload = switch (lhs.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const rhs_payload = switch (rhs.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const lhs_vector = switch (analyser.ip.indexToKey(lhs_payload.type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    const rhs_vector = switch (analyser.ip.indexToKey(rhs_payload.type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    if (lhs_vector.len != rhs_vector.len) return null;
    if (try analyser.resolvePeerTypesIP(lhs_vector.child, rhs_vector.child) == null) return null;

    const result_type = try analyser.ip.get(.{ .vector_type = .{
        .len = lhs_vector.len,
        .child = .bool_type,
    } });
    const lhs_values = analyser.aggregateValues(lhs);
    const rhs_values = analyser.aggregateValues(rhs);
    if ((lhs_values != null and lhs_values.?.len != lhs_vector.len) or
        (rhs_values != null and rhs_values.?.len != rhs_vector.len)) return null;

    const values = try analyser.gpa.alloc(InternPool.Index, lhs_vector.len);
    defer analyser.gpa.free(values);
    const unknown_lhs = try analyser.ip.getUnknown(lhs_vector.child);
    const unknown_rhs = try analyser.ip.getUnknown(rhs_vector.child);
    for (values, 0..) |*value, i| {
        const index: u32 = @intCast(i);
        const lhs_value = if (lhs_values) |slice| slice.at(index, analyser.ip) else unknown_lhs;
        const rhs_value = if (rhs_values) |slice| slice.at(index, analyser.ip) else unknown_rhs;
        const lhs_element = Type.fromIP(analyser, lhs_vector.child, lhs_value);
        const rhs_element = Type.fromIP(analyser, rhs_vector.child, rhs_value);
        const comparison = analyser.resolveComparisonValue(tag, lhs_element, rhs_element);
        value.* = if (comparison) |resolved| resolved.ipIndex() orelse try analyser.ip.getUnknown(.bool_type) else try analyser.ip.getUnknown(.bool_type);
    }
    return analyser.aggregateValue(Type.fromIP(analyser, result_type, null), values);
}

fn resolveVectorMinMaxValue(
    analyser: *Analyser,
    tag: std.zig.BuiltinFn.Tag,
    operands: []const Type,
    result_type: InternPool.Index,
) error{OutOfMemory}!?Type {
    const result_vector = switch (analyser.ip.indexToKey(result_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    const result_values = try analyser.gpa.alloc(InternPool.Index, result_vector.len);
    defer analyser.gpa.free(result_values);
    const unknown = try analyser.ip.getUnknown(result_vector.child);
    const boundary: ?i256 = if (analyser.fixedWidthIntegerBounds(result_vector.child)) |bounds|
        switch (tag) {
            .min => bounds.min,
            .max => bounds.max,
            else => null,
        }
    else
        null;

    for (result_values, 0..) |*result_value, i| {
        var selected: ?Type = null;
        var has_unknown = false;
        var has_undefined = false;
        for (operands) |operand| {
            const payload = switch (operand.data) {
                .ip_index => |payload| payload,
                else => return null,
            };
            const vector = switch (analyser.ip.indexToKey(payload.type)) {
                .vector_type => |vector| vector,
                else => return null,
            };
            if (vector.len != result_vector.len) return null;
            const values = analyser.aggregateValues(operand) orelse {
                has_unknown = true;
                continue;
            };
            if (values.len != vector.len) return null;
            const candidate_index = values.at(@intCast(i), analyser.ip);
            if (analyser.ip.isUndefined(candidate_index)) {
                has_undefined = true;
                continue;
            }
            if (candidate_index == .none or analyser.ip.isUnknown(candidate_index)) {
                has_unknown = true;
                continue;
            }
            const candidate = Type.fromIP(analyser, vector.child, candidate_index);
            if (selected == null) {
                selected = candidate;
                continue;
            }
            const prefer_candidate = switch (tag) {
                .min => analyser.resolveComparisonBool(.less_than, candidate, selected.?) orelse return Type.fromIP(analyser, result_type, null),
                .max => analyser.resolveComparisonBool(.greater_than, candidate, selected.?) orelse return Type.fromIP(analyser, result_type, null),
                else => return null,
            };
            if (prefer_candidate) {
                selected = candidate;
            } else if (analyser.floatValue(candidate.ipIndex() orelse .none)) |candidate_float| {
                const selected_float = analyser.floatValue(selected.?.ipIndex() orelse .none) orelse return null;
                if (candidate_float == 0 and selected_float == 0) {
                    if ((tag == .min and std.math.signbit(candidate_float) and !std.math.signbit(selected_float)) or
                        (tag == .max and !std.math.signbit(candidate_float) and std.math.signbit(selected_float)))
                    {
                        selected = candidate;
                    }
                }
            }
        }
        if (has_undefined or selected == null) {
            result_value.* = unknown;
            continue;
        }
        const selected_index = selected.?.ipIndex() orelse {
            result_value.* = unknown;
            continue;
        };
        const coerced = if (analyser.ip.zigTypeTag(result_vector.child) == .float)
            try analyser.coerceNumericToFloatValue(result_vector.child, selected_index) orelse
                unknown
        else
            try analyser.coerceIP(result_vector.child, selected_index) orelse
                unknown;
        if (has_unknown and (boundary == null or analyser.ip.toInt(coerced, i256) != boundary.?)) {
            result_value.* = unknown;
        } else {
            result_value.* = coerced;
        }
    }
    return analyser.aggregateValue(Type.fromIP(analyser, result_type, null), result_values);
}

fn resolveComparisonBool(
    analyser: *Analyser,
    tag: Ast.Node.Tag,
    lhs: Type,
    rhs: Type,
) ?bool {
    const result = analyser.resolveComparisonValue(tag, lhs, rhs) orelse return null;
    return switch (result.ipIndex() orelse return null) {
        .bool_true => true,
        .bool_false => false,
        else => null,
    };
}

fn managedIntegerValue(
    analyser: *Analyser,
    index: InternPool.Index,
) error{OutOfMemory}!?std.math.big.int.Managed {
    var result: std.math.big.int.Managed = try .init(analyser.gpa);
    errdefer result.deinit();
    switch (analyser.ip.indexToKey(index)) {
        inline .int_u64_value, .int_i64_value => |int_value| try result.set(int_value.int),
        .int_big_value => |int_value| try result.copy(int_value.getConst(analyser.ip)),
        else => {
            result.deinit();
            return null;
        },
    }
    return result;
}

fn resolveBitNotValue(analyser: *Analyser, operand: Type) error{OutOfMemory}!?Type {
    const payload = switch (operand.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const index = payload.index orelse return null;

    if (payload.type == .comptime_int_type) {
        const value = analyser.ip.toInt(index, i256) orelse return null;
        const result = std.math.sub(i256, -1, value) catch return null;
        return analyser.intValueWithType(payload.type, result);
    }

    if (analyser.ip.zigTypeTag(payload.type) != .int) return null;
    const int_info = analyser.ip.intInfo(payload.type, builtin.target);
    if (int_info.bits > 128) {
        var source = try analyser.managedIntegerValue(index) orelse return null;
        defer source.deinit();
        var result: std.math.big.int.Managed = try .init(analyser.gpa);
        defer result.deinit();
        try result.bitNotWrap(&source, int_info.signedness, int_info.bits);
        return Type.fromIP(
            analyser,
            payload.type,
            try analyser.ip.getBigInt(payload.type, result.toConst()),
        );
    }

    const result: i256 = switch (int_info.signedness) {
        .unsigned => blk: {
            const value = analyser.ip.toInt(index, u128) orelse return null;
            const mask = if (int_info.bits == 128)
                std.math.maxInt(u128)
            else if (int_info.bits == 0)
                0
            else
                (@as(u128, 1) << @intCast(int_info.bits)) - 1;
            break :blk @intCast((~value) & mask);
        },
        .signed => blk: {
            const value = analyser.ip.toInt(index, i128) orelse return null;
            break :blk -@as(i256, value) - 1;
        },
    };
    return analyser.intValueWithType(payload.type, result);
}

fn resolveNegationValue(
    analyser: *Analyser,
    operand: Type,
    wrapping: bool,
) error{OutOfMemory}!?Type {
    const payload = switch (operand.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const index = payload.index orelse return null;
    if (analyser.ip.zigTypeTag(payload.type) == .float or payload.type == .comptime_float_type) {
        if (wrapping) return null;
        const result_index = switch (analyser.ip.indexToKey(index)) {
            .float_16_value => |value| try analyser.ip.get(.{ .float_16_value = -value }),
            .float_32_value => |value| try analyser.ip.get(.{ .float_32_value = -value }),
            .float_64_value => |value| try analyser.ip.get(.{ .float_64_value = -value }),
            .float_80_value => |value| try analyser.ip.get(.{ .float_80_value = -value }),
            .float_128_value => |value| try analyser.ip.get(.{ .float_128_value = -value }),
            .float_comptime_value => |value| try analyser.ip.get(.{ .float_comptime_value = -value }),
            else => return null,
        };
        return Type.fromIP(analyser, payload.type, result_index);
    }

    if (payload.type == .comptime_int_type) {
        if (analyser.ip.indexToKey(index) == .int_big_value) {
            var result = try analyser.managedIntegerValue(index) orelse return null;
            defer result.deinit();
            result.negate();
            const result_index = try analyser.ip.getBigInt(payload.type, result.toConst());
            return Type.fromIP(analyser, payload.type, result_index);
        }
        const value = analyser.ip.toInt(index, i256) orelse return null;
        const result = std.math.sub(i256, 0, value) catch return null;
        return analyser.intValueWithType(payload.type, result);
    }

    if (analyser.ip.zigTypeTag(payload.type) != .int) return null;
    const int_info = analyser.ip.intInfo(payload.type, builtin.target);
    if (int_info.bits == 0) return null;
    if (int_info.bits > 128) {
        if (!wrapping and int_info.signedness == .unsigned) {
            return if (analyser.ip.isZero(index)) operand else null;
        }

        var source = try analyser.managedIntegerValue(index) orelse return null;
        defer source.deinit();
        var result: std.math.big.int.Managed = try .init(analyser.gpa);
        defer result.deinit();
        if (wrapping) {
            var zero: std.math.big.int.Managed = try .initSet(analyser.gpa, 0);
            defer zero.deinit();
            _ = try result.subWrap(&zero, &source, int_info.signedness, int_info.bits);
        } else {
            try result.copy(source.toConst());
            result.negate();
            if (!result.fitsInTwosComp(int_info.signedness, int_info.bits)) return null;
        }
        return Type.fromIP(
            analyser,
            payload.type,
            try analyser.ip.getBigInt(payload.type, result.toConst()),
        );
    }

    const result: i256 = switch (int_info.signedness) {
        .unsigned => blk: {
            const value = analyser.ip.toInt(index, u128) orelse return null;
            if (!wrapping) {
                if (value != 0) return null;
                break :blk 0;
            }
            const mask = if (int_info.bits == 128)
                std.math.maxInt(u128)
            else
                (@as(u128, 1) << @intCast(int_info.bits)) - 1;
            break :blk @intCast((0 -% value) & mask);
        },
        .signed => blk: {
            const value = analyser.ip.toInt(index, i128) orelse return null;
            if (!wrapping) {
                break :blk -@as(i256, value);
            }

            const raw: u128 = @bitCast(value);
            const mask = if (int_info.bits == 128)
                std.math.maxInt(u128)
            else
                (@as(u128, 1) << @intCast(int_info.bits)) - 1;
            const result_raw = (0 -% raw) & mask;
            const sign_bit = @as(u128, 1) << @intCast(int_info.bits - 1);
            break :blk if (result_raw & sign_bit == 0)
                @intCast(result_raw)
            else
                @as(i256, @intCast(result_raw)) - (@as(i256, 1) << @intCast(int_info.bits));
        },
    };
    return analyser.intValueWithType(payload.type, result);
}

fn resolveTypeBitSize(analyser: *Analyser, ty: Type) ?u64 {
    if (!ty.is_type_val) return null;
    return switch (ty.data) {
        .pointer => |info| switch (info.size) {
            .slice => @as(u64, builtin.target.ptrBitWidth()) * 2,
            .one, .many, .c => builtin.target.ptrBitWidth(),
        },
        .array => |info| blk: {
            const declared_len = info.elem_count orelse break :blk null;
            const len = std.math.add(u64, declared_len, @intFromBool(info.sentinel != .none)) catch break :blk null;
            if (len == 0) break :blk 0;
            const elem_bits = analyser.resolveTypeBitSize(info.elem_ty.*) orelse break :blk null;
            const elem_bytes = analyser.resolveTypeByteSize(info.elem_ty.*) orelse break :blk null;
            const preceding_bits = std.math.mul(u64, len - 1, std.math.mul(u64, elem_bytes, 8) catch break :blk null) catch break :blk null;
            break :blk std.math.add(u64, preceding_bits, elem_bits) catch null;
        },
        .ip_index => |payload| blk: {
            const type_index = payload.index orelse break :blk null;
            const type_tag = analyser.ip.zigTypeTag(type_index) orelse break :blk null;
            break :blk switch (type_tag) {
                .int => analyser.ip.intInfo(type_index, builtin.target).bits,
                .float => analyser.ip.floatBits(type_index, builtin.target),
                .bool => 1,
                .void, .noreturn => 0,
                .pointer => switch (analyser.ip.indexToKey(type_index).pointer_type.flags.size) {
                    .slice => @as(u64, builtin.target.ptrBitWidth()) * 2,
                    .one, .many, .c => builtin.target.ptrBitWidth(),
                },
                .array => array: {
                    const info = analyser.ip.indexToKey(type_index).array_type;
                    const len = std.math.add(u64, info.len, @intFromBool(info.sentinel != .none)) catch break :array null;
                    if (len == 0) break :array 0;
                    const elem_ty = Type.fromIP(analyser, .type_type, info.child);
                    const elem_bits = analyser.resolveTypeBitSize(elem_ty) orelse break :array null;
                    const elem_bytes = analyser.resolveTypeByteSize(elem_ty) orelse break :array null;
                    const preceding_bits = std.math.mul(u64, len - 1, std.math.mul(u64, elem_bytes, 8) catch break :array null) catch break :array null;
                    break :array std.math.add(u64, preceding_bits, elem_bits) catch null;
                },
                .vector => vector: {
                    const info = analyser.ip.indexToKey(type_index).vector_type;
                    const elem_bits = analyser.resolveTypeBitSize(Type.fromIP(analyser, .type_type, info.child)) orelse break :vector null;
                    break :vector std.math.mul(u64, info.len, elem_bits) catch null;
                },
                else => null,
            };
        },
        else => null,
    };
}

fn resolveTypeByteSize(analyser: *Analyser, ty: Type) ?u64 {
    if (!ty.is_type_val) return null;
    return switch (ty.data) {
        .pointer => |info| switch (info.size) {
            .slice => @as(u64, builtin.target.ptrBitWidth() / 8) * 2,
            .one, .many, .c => builtin.target.ptrBitWidth() / 8,
        },
        .array => |info| blk: {
            const declared_len = info.elem_count orelse break :blk null;
            const len = std.math.add(u64, declared_len, @intFromBool(info.sentinel != .none)) catch break :blk null;
            const elem_bytes = analyser.resolveTypeByteSize(info.elem_ty.*) orelse break :blk null;
            break :blk std.math.mul(u64, len, elem_bytes) catch null;
        },
        .ip_index => |payload| blk: {
            const type_index = payload.index orelse break :blk null;
            const type_tag = analyser.ip.zigTypeTag(type_index) orelse break :blk null;
            break :blk switch (type_tag) {
                .int => (@as(u64, analyser.ip.intInfo(type_index, builtin.target).bits) + 7) / 8,
                .float => switch (type_index) {
                    .f80_type => @sizeOf(f80),
                    .c_longdouble_type => builtin.target.cTypeByteSize(.longdouble),
                    else => (@as(u64, analyser.ip.floatBits(type_index, builtin.target)) + 7) / 8,
                },
                .bool => 1,
                .void, .noreturn => 0,
                .pointer => switch (analyser.ip.indexToKey(type_index).pointer_type.flags.size) {
                    .slice => @as(u64, builtin.target.ptrBitWidth() / 8) * 2,
                    .one, .many, .c => builtin.target.ptrBitWidth() / 8,
                },
                .array => array: {
                    const info = analyser.ip.indexToKey(type_index).array_type;
                    const len = std.math.add(u64, info.len, @intFromBool(info.sentinel != .none)) catch break :array null;
                    const elem_bytes = analyser.resolveTypeByteSize(Type.fromIP(analyser, .type_type, info.child)) orelse break :array null;
                    break :array std.math.mul(u64, len, elem_bytes) catch null;
                },
                .vector => vector: {
                    const info = analyser.ip.indexToKey(type_index).vector_type;
                    const elem_bits = analyser.resolveTypeBitSize(Type.fromIP(analyser, .type_type, info.child)) orelse break :vector null;
                    const total_bits = std.math.mul(u64, info.len, elem_bits) catch break :vector null;
                    const byte_count = std.math.divCeil(u64, total_bits, 8) catch break :vector null;
                    break :vector if (byte_count == 0) 0 else std.math.ceilPowerOfTwo(u64, byte_count) catch null;
                },
                else => null,
            };
        },
        else => null,
    };
}

fn comptimeIntValue(analyser: *Analyser, value: u64) error{OutOfMemory}!Type {
    const index = try analyser.ip.get(.{
        .int_u64_value = .{ .ty = .comptime_int_type, .int = value },
    });
    return Type.fromIP(analyser, .comptime_int_type, index);
}

fn staticStringType(analyser: *Analyser, len: u64) error{OutOfMemory}!Type {
    const pointer_type = try analyser.ip.get(.{ .pointer_type = .{
        .elem_type = try analyser.ip.get(.{ .array_type = .{
            .child = .u8_type,
            .len = len,
            .sentinel = .zero_u8,
        } }),
        .flags = .{
            .size = .one,
            .is_const = true,
        },
    } });
    return Type.fromIP(analyser, pointer_type, null);
}

fn stringValueWithType(analyser: *Analyser, bytes: []const u8, string_type: Type) error{OutOfMemory}!Type {
    std.debug.assert(string_type.is_type_val);
    return .{
        .data = .{ .string_value = .{
            .string_type = try analyser.allocType(string_type),
            .bytes = bytes,
        } },
        .is_type_val = false,
    };
}

fn stringValue(analyser: *Analyser, bytes: []const u8) error{OutOfMemory}!Type {
    const string_type = try analyser.staticStringType(bytes.len);
    return analyser.stringValueWithType(bytes, try string_type.typeOf(analyser));
}

fn isStringSliceType(analyser: *Analyser, ty: Type) bool {
    if (!ty.is_type_val) return false;
    return switch (ty.data) {
        .pointer => |info| info.size == .slice and
            info.is_const and
            (info.sentinel == .none or info.sentinel == .zero_u8) and
            info.elem_ty.ipIndex() == .u8_type,
        .ip_index => |payload| switch (analyser.ip.indexToKey(payload.index orelse return false)) {
            .pointer_type => |info| info.flags.size == .slice and
                info.flags.is_const and
                (info.sentinel == .none or info.sentinel == .zero_u8) and
                info.elem_type == .u8_type,
            else => false,
        },
        else => false,
    };
}

fn canResolveTypeName(analyser: *Analyser, ty: Type) bool {
    if (!ty.is_type_val) return false;
    return switch (ty.data) {
        .pointer => |info| analyser.canResolveTypeName(info.elem_ty.*),
        .array => |info| info.elem_count != null and
            info.sentinel != .unknown_unknown and
            analyser.canResolveTypeName(info.elem_ty.*),
        .optional => |child_ty| analyser.canResolveTypeName(child_ty.*),
        .ip_index => |payload| switch (analyser.ip.indexToKey(payload.index orelse return false)) {
            .simple_type => |simple| switch (simple) {
                .empty_struct_type,
                .null_type,
                .undefined_type,
                .enum_literal_type,
                .unknown,
                .generic_poison,
                => false,
                .f16,
                .f32,
                .f64,
                .f80,
                .f128,
                .usize,
                .isize,
                .c_char,
                .c_short,
                .c_ushort,
                .c_int,
                .c_uint,
                .c_long,
                .c_ulong,
                .c_longlong,
                .c_ulonglong,
                .c_longdouble,
                .anyopaque,
                .bool,
                .void,
                .type,
                .anyerror,
                .comptime_int,
                .comptime_float,
                .noreturn,
                .anyframe_type,
                => true,
                else => false,
            },
            .int_type => true,
            .pointer_type => |info| info.sentinel != .unknown_unknown and
                analyser.canResolveTypeName(Type.fromIP(analyser, .type_type, info.elem_type)),
            .array_type => |info| info.sentinel != .unknown_unknown and
                analyser.canResolveTypeName(Type.fromIP(analyser, .type_type, info.child)),
            .optional_type => |info| analyser.canResolveTypeName(Type.fromIP(analyser, .type_type, info.payload_type)),
            .vector_type => |info| analyser.canResolveTypeName(Type.fromIP(analyser, .type_type, info.child)),
            else => false,
        },
        else => false,
    };
}

fn resolveBitCountValue(
    analyser: *Analyser,
    tag: std.zig.BuiltinFn.Tag,
    operand: Type,
) error{OutOfMemory}!?Type {
    const payload = switch (operand.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const index = payload.index orelse return null;
    if (analyser.ip.zigTypeTag(payload.type) != .int) return null;
    const int_info = analyser.ip.intInfo(payload.type, builtin.target);
    if (int_info.bits == 0) return null;

    const value: u64 = if (int_info.bits > 128) value: {
        const bit_count: std.math.big.Limb = int_info.bits;
        break :value switch (analyser.ip.indexToKey(index)) {
            inline .int_u64_value, .int_i64_value => |int_value| scalar: {
                var buffer: [std.math.big.int.calcTwosCompLimbCount(64)]std.math.big.Limb = undefined;
                var big_int: std.math.big.int.Mutable = .init(&buffer, int_value.int);
                const int = big_int.toConst();
                break :scalar @intCast(switch (tag) {
                    .clz => int.clz(bit_count),
                    .ctz => int.ctz(bit_count),
                    .pop_count => int.popCount(bit_count),
                    else => return null,
                });
            },
            .int_big_value => |int_value| @intCast(switch (tag) {
                .clz => int_value.getConst(analyser.ip).clz(bit_count),
                .ctz => int_value.getConst(analyser.ip).ctz(bit_count),
                .pop_count => int_value.getConst(analyser.ip).popCount(bit_count),
                else => return null,
            }),
            else => return null,
        };
    } else value: {
        const raw: u128 = switch (int_info.signedness) {
            .unsigned => analyser.ip.toInt(index, u128) orelse return null,
            .signed => signed: {
                const signed_value = analyser.ip.toInt(index, i128) orelse return null;
                const bits: u128 = @bitCast(signed_value);
                const mask = if (int_info.bits == 128)
                    std.math.maxInt(u128)
                else
                    (@as(u128, 1) << @intCast(int_info.bits)) - 1;
                break :signed bits & mask;
            },
        };
        break :value switch (tag) {
            .clz => if (raw == 0) int_info.bits else @clz(raw) - (128 - int_info.bits),
            .ctz => if (raw == 0) int_info.bits else @ctz(raw),
            .pop_count => @popCount(raw),
            else => return null,
        };
    };

    const result_bits: u16 = @intCast(std.math.log2_int_ceil(u32, @as(u32, int_info.bits) + 1));
    const result_type = try analyser.ip.get(.{ .int_type = .{
        .signedness = .unsigned,
        .bits = result_bits,
    } });
    const result_index = try analyser.ip.get(.{ .int_u64_value = .{
        .ty = result_type,
        .int = value,
    } });
    return Type.fromIP(analyser, result_type, result_index);
}

fn resolveVectorBitCountValue(
    analyser: *Analyser,
    tag: std.zig.BuiltinFn.Tag,
    operand: Type,
) error{OutOfMemory}!?Type {
    const payload = switch (operand.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const vector = switch (analyser.ip.indexToKey(payload.type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    if (analyser.ip.zigTypeTag(vector.child) != .int) return null;
    const bits = analyser.ip.intInfo(vector.child, builtin.target).bits;
    if (bits == 0) return null;
    const result_bits: u16 = @intCast(std.math.log2_int_ceil(u32, @as(u32, bits) + 1));
    const result_child = try analyser.ip.get(.{ .int_type = .{
        .signedness = .unsigned,
        .bits = result_bits,
    } });
    const result_type = try analyser.ip.get(.{ .vector_type = .{
        .len = vector.len,
        .child = result_child,
    } });
    const source_values = analyser.aggregateValues(operand) orelse return Type.fromIP(analyser, result_type, null);
    if (source_values.len != vector.len) return null;

    const values = try analyser.gpa.alloc(InternPool.Index, vector.len);
    defer analyser.gpa.free(values);
    for (values, 0..) |*value, i| {
        const element = Type.fromIP(analyser, vector.child, source_values.at(@intCast(i), analyser.ip));
        const resolved = try analyser.resolveBitCountValue(tag, element);
        value.* = if (resolved) |result| result.ipIndex() orelse try analyser.ip.getUnknown(result_child) else try analyser.ip.getUnknown(result_child);
    }
    return analyser.aggregateValue(Type.fromIP(analyser, result_type, null), values);
}

fn resolveBitPermutationValue(
    analyser: *Analyser,
    tag: std.zig.BuiltinFn.Tag,
    operand: Type,
) error{OutOfMemory}!?Type {
    const payload = switch (operand.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const index = payload.index orelse return null;
    if (analyser.ip.zigTypeTag(payload.type) != .int) return null;
    const int_info = analyser.ip.intInfo(payload.type, builtin.target);
    if (tag == .byte_swap and int_info.bits % 8 != 0) return null;
    if (int_info.bits > 128) {
        var source = try analyser.managedIntegerValue(index) orelse return null;
        defer source.deinit();
        var result: std.math.big.int.Managed = try .initCapacity(
            analyser.gpa,
            std.math.big.int.calcTwosCompLimbCount(int_info.bits),
        );
        defer result.deinit();
        var mutable = result.toMutable();
        switch (tag) {
            .bit_reverse => mutable.bitReverse(source.toConst(), int_info.signedness, int_info.bits),
            .byte_swap => mutable.byteSwap(source.toConst(), int_info.signedness, int_info.bits / 8),
            else => return null,
        }
        result.setMetadata(mutable.positive, mutable.len);
        return Type.fromIP(
            analyser,
            payload.type,
            try analyser.ip.getBigInt(payload.type, result.toConst()),
        );
    }

    const raw: u128 = switch (int_info.signedness) {
        .unsigned => analyser.ip.toInt(index, u128) orelse return null,
        .signed => signed: {
            const value = analyser.ip.toInt(index, i128) orelse return null;
            const bits: u128 = @bitCast(value);
            const mask = if (int_info.bits == 128)
                std.math.maxInt(u128)
            else if (int_info.bits == 0)
                0
            else
                (@as(u128, 1) << @intCast(int_info.bits)) - 1;
            break :signed bits & mask;
        },
    };
    const result_raw = switch (tag) {
        .bit_reverse => if (int_info.bits == 0) 0 else @bitReverse(raw) >> @intCast(128 - int_info.bits),
        .byte_swap => if (int_info.bits == 0) 0 else @byteSwap(raw) >> @intCast(128 - int_info.bits),
        else => return null,
    };
    const result: i256 = switch (int_info.signedness) {
        .unsigned => @intCast(result_raw),
        .signed => signed: {
            if (int_info.bits == 0 or result_raw & (@as(u128, 1) << @intCast(int_info.bits - 1)) == 0) {
                break :signed @intCast(result_raw);
            }
            break :signed if (int_info.bits == 128)
                @as(i128, @bitCast(result_raw))
            else
                @as(i256, @intCast(result_raw)) - (@as(i256, 1) << @intCast(int_info.bits));
        },
    };
    return analyser.intValueWithType(payload.type, result);
}

fn resolveVectorBitPermutationValue(
    analyser: *Analyser,
    tag: std.zig.BuiltinFn.Tag,
    operand: Type,
) error{OutOfMemory}!?Type {
    const payload = switch (operand.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const vector = switch (analyser.ip.indexToKey(payload.type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    if (analyser.ip.zigTypeTag(vector.child) != .int) return null;
    const source_values = analyser.aggregateValues(operand) orelse return Type.fromIP(analyser, payload.type, null);
    if (source_values.len != vector.len) return null;

    const values = try analyser.gpa.alloc(InternPool.Index, vector.len);
    defer analyser.gpa.free(values);
    for (values, 0..) |*value, i| {
        const element = Type.fromIP(analyser, vector.child, source_values.at(@intCast(i), analyser.ip));
        const resolved = try analyser.resolveBitPermutationValue(tag, element);
        value.* = if (resolved) |result| result.ipIndex() orelse try analyser.ip.getUnknown(vector.child) else try analyser.ip.getUnknown(vector.child);
    }
    return analyser.aggregateValue(Type.fromIP(analyser, payload.type, null), values);
}

fn resolveExactShiftValue(
    analyser: *Analyser,
    tag: std.zig.BuiltinFn.Tag,
    operand: Type,
    shift_operand: Type,
) error{OutOfMemory}!?Type {
    const payload = switch (operand.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    if (try analyser.resolveZeroShiftValue(operand, shift_operand)) |value| return value;
    const index = payload.index orelse return null;
    const shift_index = shift_operand.ipIndex() orelse return null;
    const shift = analyser.ip.toInt(shift_index, u16) orelse return null;

    const type_tag = analyser.ip.zigTypeTag(payload.type) orelse return null;
    if (type_tag != .int and type_tag != .comptime_int) return null;
    if (type_tag == .int) {
        const info = analyser.ip.intInfo(payload.type, builtin.target);
        if (info.bits == 0 or shift >= info.bits) return null;
        if (info.bits > 128) {
            var source = try analyser.managedIntegerValue(index) orelse return null;
            defer source.deinit();
            var result: std.math.big.int.Managed = try .init(analyser.gpa);
            defer result.deinit();
            switch (tag) {
                .shl_exact => {
                    try result.shiftLeft(&source, shift);
                    if (!result.fitsInTwosComp(info.signedness, info.bits)) return null;
                },
                .shr_exact => {
                    if (source.toConst().ctz(info.bits) < shift) return null;
                    try result.shiftRight(&source, shift);
                },
                else => return null,
            }
            return Type.fromIP(
                analyser,
                payload.type,
                try analyser.ip.getBigInt(payload.type, result.toConst()),
            );
        }
    }
    const value = analyser.ip.toInt(index, i256) orelse return null;
    if (shift >= @bitSizeOf(i256)) return null;

    const result: i256 = switch (tag) {
        .shl_exact => std.math.shlExact(i256, value, @intCast(shift)) catch return null,
        .shr_exact => blk: {
            const discarded_mask = if (shift == 0)
                0
            else
                (@as(u256, 1) << @intCast(shift)) - 1;
            if (@as(u256, @bitCast(value)) & discarded_mask != 0) return null;
            break :blk value >> @intCast(shift);
        },
        else => return null,
    };
    return analyser.intValueWithType(payload.type, result);
}

const VectorShiftOperation = enum { shl, shr, shl_exact, shr_exact };

fn resolveVectorShiftValue(
    analyser: *Analyser,
    operation: VectorShiftOperation,
    operand: Type,
    shift_operand: Type,
) error{OutOfMemory}!?Type {
    const payload = switch (operand.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const shift_payload = switch (shift_operand.data) {
        .ip_index => |shift_value| shift_value,
        else => return null,
    };
    const vector = switch (analyser.ip.indexToKey(payload.type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    const shift_vector = switch (analyser.ip.indexToKey(shift_payload.type)) {
        .vector_type => |shift_vector| shift_vector,
        else => return null,
    };
    if (vector.len != shift_vector.len) return null;
    const source_values = analyser.aggregateValues(operand);
    const shift_values = analyser.aggregateValues(shift_operand);
    if ((source_values != null and source_values.?.len != vector.len) or
        (shift_values != null and shift_values.?.len != shift_vector.len)) return null;

    const values = try analyser.gpa.alloc(InternPool.Index, vector.len);
    defer analyser.gpa.free(values);
    const unknown_operand = try analyser.ip.getUnknown(vector.child);
    const unknown_shift = try analyser.ip.getUnknown(shift_vector.child);
    for (values, 0..) |*value, i| {
        const index: u32 = @intCast(i);
        const element = Type.fromIP(
            analyser,
            vector.child,
            if (source_values) |slice| slice.at(index, analyser.ip) else unknown_operand,
        );
        const shift_element = Type.fromIP(
            analyser,
            shift_vector.child,
            if (shift_values) |slice| slice.at(index, analyser.ip) else unknown_shift,
        );
        const resolved = switch (operation) {
            .shl => try analyser.resolveIntegerBinaryValue(.shl, element, shift_element),
            .shr => try analyser.resolveIntegerBinaryValue(.shr, element, shift_element),
            .shl_exact => try analyser.resolveExactShiftValue(.shl_exact, element, shift_element),
            .shr_exact => try analyser.resolveExactShiftValue(.shr_exact, element, shift_element),
        };
        if ((operation == .shl_exact or operation == .shr_exact) and resolved == null) {
            return Type.fromIP(analyser, payload.type, null);
        }
        value.* = if (resolved) |result| result.ipIndex() orelse try analyser.ip.getUnknown(vector.child) else try analyser.ip.getUnknown(vector.child);
    }
    return analyser.aggregateValue(Type.fromIP(analyser, payload.type, null), values);
}

const primitives: std.StaticStringMap(InternPool.Index) = .initComptime(.{
    .{ "anyerror", .anyerror_type },
    .{ "anyframe", .anyframe_type },
    .{ "anyopaque", .anyopaque_type },
    .{ "bool", .bool_type },
    .{ "c_int", .c_int_type },
    .{ "c_long", .c_long_type },
    .{ "c_longdouble", .c_longdouble_type },
    .{ "c_longlong", .c_longlong_type },
    .{ "c_char", .c_char_type },
    .{ "c_short", .c_short_type },
    .{ "c_uint", .c_uint_type },
    .{ "c_ulong", .c_ulong_type },
    .{ "c_ulonglong", .c_ulonglong_type },
    .{ "c_ushort", .c_ushort_type },
    .{ "comptime_float", .comptime_float_type },
    .{ "comptime_int", .comptime_int_type },
    .{ "f128", .f128_type },
    .{ "f16", .f16_type },
    .{ "f32", .f32_type },
    .{ "f64", .f64_type },
    .{ "f80", .f80_type },
    .{ "false", .bool_false },
    .{ "i16", .i16_type },
    .{ "i32", .i32_type },
    .{ "i64", .i64_type },
    .{ "i128", .i128_type },
    .{ "i8", .i8_type },
    .{ "isize", .isize_type },
    .{ "noreturn", .noreturn_type },
    .{ "null", .null_value },
    .{ "true", .bool_true },
    .{ "type", .type_type },
    .{ "u16", .u16_type },
    .{ "u29", .u29_type },
    .{ "u32", .u32_type },
    .{ "u64", .u64_type },
    .{ "u128", .u128_type },
    .{ "u1", .u1_type },
    .{ "u8", .u8_type },
    .{ "undefined", .undefined_value },
    .{ "usize", .usize_type },
    .{ "void", .void_type },
});

pub fn resolvePrimitive(analyser: *Analyser, identifier_name: []const u8) error{OutOfMemory}!?InternPool.Index {
    if (primitives.get(identifier_name)) |primitive| return primitive;

    if (identifier_name.len < 2) return null;
    const signedness: std.builtin.Signedness = switch (identifier_name[0]) {
        'i' => .signed,
        'u' => .unsigned,
        else => return null,
    };
    for (identifier_name[1..]) |c| {
        switch (c) {
            '0'...'9' => {},
            else => return null,
        }
    }

    const bits = std.fmt.parseUnsigned(u16, identifier_name[1..], 10) catch return null;

    return try analyser.ip.get(.{ .int_type = .{
        .bits = bits,
        .signedness = signedness,
    } });
}

fn resolveStringLiteral(analyser: *Analyser, options: ResolveOptions) Error!?[]const u8 {
    const old_evaluate_comptime_values = analyser.evaluate_comptime_values;
    analyser.evaluate_comptime_values = true;
    defer analyser.evaluate_comptime_values = old_evaluate_comptime_values;

    if (try analyser.resolveBindingOfNodeInternal(options)) |binding| {
        if (binding.type.data == .string_value) return binding.type.data.string_value.bytes;
    }

    var node_with_handle = options.node_handle;
    if (try analyser.resolveVarDeclAlias(.{
        .decl = .{ .ast_node = options.node_handle.node },
        .handle = options.node_handle.handle,
        .container_type = options.container_type,
    })) |decl_with_handle| {
        if (decl_with_handle.decl == .ast_node) {
            node_with_handle = .{
                .node = decl_with_handle.decl.ast_node,
                .handle = decl_with_handle.handle,
            };
        }
    }
    if (!node_with_handle.eql(options.node_handle)) {
        if (try analyser.resolveBindingOfNodeInternal(.of(node_with_handle.node, node_with_handle.handle))) |binding| {
            if (binding.type.data == .string_value) return binding.type.data.string_value.bytes;
        }
    }
    const string_literal_node = switch (node_with_handle.handle.tree.nodeTag(node_with_handle.node)) {
        .string_literal => node_with_handle.node,
        .global_var_decl,
        .local_var_decl,
        .aligned_var_decl,
        .simple_var_decl,
        => blk: {
            const var_decl = node_with_handle.handle.tree.fullVarDecl(node_with_handle.node).?;
            const init_node = var_decl.ast.init_node.unwrap() orelse return null;
            if (node_with_handle.handle.tree.nodeTag(init_node) != .string_literal) return null;
            break :blk init_node;
        },
        else => return null,
    };
    const field_name_token = node_with_handle.handle.tree.nodeMainToken(string_literal_node);
    const field_name = offsets.tokenToSlice(&node_with_handle.handle.tree, field_name_token);

    // Need at least one char between the quotes, eg "a"
    if (field_name.len < 2) return null;
    return field_name[1 .. field_name.len - 1];
}

fn resolveErrorSetIPIndex(analyser: *Analyser, options: ResolveOptions) Error!?InternPool.Index {
    const ty = try analyser.resolveTypeOfNodeInternal(options) orelse return null;
    if (!ty.is_type_val) return null;
    const ip_index = switch (ty.data) {
        .ip_index => |payload| payload.index orelse return null,
        else => return null,
    };
    if (analyser.ip.zigTypeTag(ip_index) != .error_set) return null;
    return ip_index;
}

fn coerceIP(analyser: *Analyser, dest_ty: InternPool.Index, inst: InternPool.Index) error{OutOfMemory}!?InternPool.Index {
    if (inst == .none)
        return .none;
    var err_msg: ErrorMsg = undefined;
    const coerced_sentinel = try analyser.ip.coerce(analyser.arena, dest_ty, inst, builtin.target, &err_msg);
    if (coerced_sentinel != .none)
        return coerced_sentinel;
    return null;
}

fn resolvePeerTypes(analyser: *Analyser, a: Type, b: Type) error{OutOfMemory}!?Type {
    if (a.is_type_val or b.is_type_val) return null;
    if (a.eql(b)) return a;

    if (a.data == .ip_index and b.data == .ip_index) {
        const a_type = a.data.ip_index.type;
        const b_type = b.data.ip_index.type;
        if (try analyser.resolvePeerTypesIP(a_type, b_type)) |resolved_type| {
            return Type.fromIP(analyser, resolved_type, null);
        }
    }

    return try analyser.resolvePeerTypesInternal(a, b) orelse try analyser.resolvePeerTypesInternal(b, a);
}

fn resolvePeerTypesIP(analyser: *Analyser, a: InternPool.Index, b: InternPool.Index) error{OutOfMemory}!?InternPool.Index {
    const resolved = try analyser.ip.resolvePeerTypes(&.{ a, b }, builtin.target);
    if (resolved == .none) return null;
    return resolved;
}

fn resolvePeerErrorSets(analyser: *Analyser, a: Type, b: Type) error{OutOfMemory}!?Type {
    if (a.data != .ip_index) return null;
    if (b.data != .ip_index) return null;
    if (a.data.ip_index.type != .type_type) return null;
    if (b.data.ip_index.type != .type_type) return null;
    const a_index = a.data.ip_index.index orelse return null;
    const b_index = b.data.ip_index.index orelse return null;
    if (analyser.ip.zigTypeTag(a_index) != .error_set) return null;
    if (analyser.ip.zigTypeTag(b_index) != .error_set) return null;
    const resolved_index = try analyser.ip.errorSetMerge(a_index, b_index);
    return Type.fromIP(analyser, .type_type, resolved_index);
}

fn resolvePeerTypesInternal(analyser: *Analyser, a: Type, b: Type) error{OutOfMemory}!?Type {
    switch (a.data) {
        .compile_error => return b,
        .optional => |a_type| {
            if (a_type.eql(try b.typeOf(analyser))) {
                return a;
            }
            switch (b.data) {
                .error_union => |b_info| {
                    if (a_type.eql(b_info.payload.*)) {
                        return .{
                            .data = .{
                                .error_union = .{
                                    .error_set = b_info.error_set,
                                    .payload = try analyser.allocType(try a.typeOf(analyser)),
                                },
                            },
                            .is_type_val = false,
                        };
                    }
                },
                else => {},
            }
        },
        .error_union => |a_info| {
            if (a_info.payload.eql(try b.typeOf(analyser))) {
                return a;
            }
            switch (b.data) {
                .error_union => |b_info| {
                    const resolved_error_set = blk: {
                        const a_error_set = a_info.error_set orelse break :blk null;
                        const b_error_set = b_info.error_set orelse break :blk null;
                        if (a_error_set.eql(b_error_set.*)) break :blk a_error_set;
                        const resolved_error_set = try analyser.resolvePeerErrorSets(a_error_set.*, b_error_set.*) orelse break :blk null;
                        break :blk try analyser.allocType(resolved_error_set);
                    };
                    const resolved_payload = blk: {
                        if (a_info.payload.eql(b_info.payload.*)) break :blk a_info.payload;
                        const a_instance = try a_info.payload.instanceTypeVal(analyser) orelse return null;
                        const b_instance = try b_info.payload.instanceTypeVal(analyser) orelse return null;
                        const resolved_instance = try analyser.resolvePeerTypes(a_instance, b_instance) orelse return null;
                        break :blk try analyser.allocType(try resolved_instance.typeOf(analyser));
                    };
                    return .{
                        .data = .{
                            .error_union = .{
                                .error_set = resolved_error_set,
                                .payload = resolved_payload,
                            },
                        },
                        .is_type_val = false,
                    };
                },
                else => {},
            }
        },
        .ip_index => |a_payload| switch (analyser.ip.zigTypeTag(a_payload.type) orelse return null) {
            .noreturn => return b,
            .null => switch (b.data) {
                .optional => return b,
                .error_union => |b_info| {
                    return .{
                        .data = .{
                            .error_union = .{
                                .error_set = b_info.error_set,
                                .payload = try analyser.allocType(.{
                                    .data = .{ .optional = try analyser.allocType(b_info.payload.*) },
                                    .is_type_val = true,
                                }),
                            },
                        },
                        .is_type_val = false,
                    };
                },
                else => return .{
                    .data = .{ .optional = try analyser.allocType(try b.typeOf(analyser)) },
                    .is_type_val = false,
                },
            },
            .error_set => switch (b.data) {
                .error_union => |b_info| {
                    const resolved_error_set = blk: {
                        const a_error_set = try a.typeOf(analyser);
                        const b_error_set = b_info.error_set orelse break :blk null;
                        if (a_error_set.eql(b_error_set.*)) break :blk b_error_set;
                        const resolved_error_set = try analyser.resolvePeerErrorSets(a_error_set, b_error_set.*) orelse break :blk null;
                        break :blk try analyser.allocType(resolved_error_set);
                    };
                    return .{
                        .data = .{
                            .error_union = .{
                                .error_set = resolved_error_set,
                                .payload = b_info.payload,
                            },
                        },
                        .is_type_val = false,
                    };
                },
                else => return .{
                    .data = .{
                        .error_union = .{
                            .error_set = try analyser.allocType(try a.typeOf(analyser)),
                            .payload = try analyser.allocType(try b.typeOf(analyser)),
                        },
                    },
                    .is_type_val = false,
                },
            },
            else => {},
        },
        else => {},
    }

    return null;
}

fn resolveCallsiteReferences(analyser: *Analyser, decl_handle: DeclWithHandle) Error!?Type {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const pay = switch (decl_handle.decl) {
        .function_parameter => |pay| pay,
        else => return null,
    };

    const tree = &decl_handle.handle.tree;
    const is_cimport = std.mem.eql(u8, std.Io.Dir.path.basename(decl_handle.handle.uri.raw), "cimport.zig");

    if (is_cimport or !analyser.collect_callsite_references) return null;

    // protection against recursive callsite resolution
    const gop_resolved = try analyser.resolved_callsites.getOrPut(analyser.gpa, pay);
    if (gop_resolved.found_existing) return gop_resolved.value_ptr.*;
    gop_resolved.value_ptr.* = null;

    const func_decl: Declaration = .{ .ast_node = pay.func };

    var func_buf: [1]Ast.Node.Index = undefined;
    const func = tree.fullFnProto(&func_buf, pay.func).?;

    var func_params_len: usize = 0;

    var it: ast.FnParamIterator = .init(&func, tree);
    while (it.next()) |_| {
        func_params_len += 1;
    }

    const refs = try references.callsiteReferences(
        analyser,
        .{ .decl = func_decl, .handle = decl_handle.handle, .container_type = decl_handle.container_type },
        false,
    );

    var possible: std.ArrayList(Type.TypeWithDescriptor) = .empty;

    for (refs.items) |ref| {
        var call_buf: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&call_buf, ref.node).?;

        const real_param_idx = if (func_params_len != 0 and pay.param_index != 0 and call.ast.params.len == func_params_len - 1)
            pay.param_index - 1
        else
            pay.param_index;

        if (real_param_idx >= call.ast.params.len) continue;

        var ty = resolve_ty: {
            // don't resolve callsite references while resolving callsite references
            const old_collect_callsite_references = analyser.collect_callsite_references;
            defer analyser.collect_callsite_references = old_collect_callsite_references;
            analyser.collect_callsite_references = false;

            break :resolve_ty try analyser.resolveTypeOfNode(.of(
                // TODO?: this is a """heuristic based approach"""
                // perhaps it would be better to use proper self detection
                // maybe it'd be a perf issue and this is fine?
                // you figure it out future contributor <3
                call.ast.params[real_param_idx],
                ref.handle,
            )) orelse continue;
        };

        ty = try ty.typeOf(analyser);
        std.debug.assert(ty.is_type_val);

        const loc = offsets.tokenToPosition(tree, tree.nodeMainToken(call.ast.params[real_param_idx]), .@"utf-8");
        try possible.append(analyser.arena, .{
            .type = ty,
            .descriptor = try std.fmt.allocPrint(analyser.arena, "{s}:{d}:{d}", .{ ref.handle.uri.raw, loc.line + 1, loc.character + 1 }),
        });
    }

    const maybe_type = try Type.fromEither(analyser, possible.items);
    if (maybe_type) |ty| analyser.resolved_callsites.getPtr(pay).?.* = ty;
    return maybe_type;
}

fn resolveFunctionTypeFromCall(
    analyser: *Analyser,
    handle: *DocumentStore.Handle,
    call: Ast.full.Call,
    func_ty: Type,
) Error!Type {
    const func_info = func_ty.data.function;
    const func_tree = &func_info.handle.tree;
    const can_evaluate_type_function = func_ty.isTypeFunc() and
        func_tree.nodeTag(func_info.fn_node) == .fn_decl;
    if (!func_ty.isGenericType() and !func_ty.isGenericFunc() and !can_evaluate_type_function) {
        return func_ty;
    }

    var meta_params: TokenToTypeMap = switch (func_info.container_type.data) {
        .container => |info| try info.bound_params.clone(analyser.arena),
        else => .empty,
    };
    errdefer meta_params.deinit(analyser.arena);
    var value_params = try meta_params.clone(analyser.arena);
    errdefer value_params.deinit(analyser.arena);

    const has_self_param = call.ast.params.len + 1 == func_info.parameters.len and
        try analyser.isInstanceCall(handle, call, func_ty);

    const parameters = func_info.parameters[@intFromBool(has_self_param)..];
    const arguments = call.ast.params;
    const min_len = @min(parameters.len, arguments.len);
    var has_callsite_bindings = false;
    for (parameters[0..min_len], arguments[0..min_len]) |param, arg| {
        const param_name_token = param.name_token orelse continue;
        const param_type = if (param.type.isGenericType())
            try analyser.resolveGenericType(param.type, meta_params)
        else
            param.type;
        const parameter_token_handle: TokenWithHandle = .{
            .token = param_name_token,
            .handle = func_info.handle,
        };

        if (param_type.data != .anytype_parameter and
            param.modifier == .comptime_param and
            param_type.is_type_val and
            (param_type.ipIndex() != null or param_type.isEnumType()) and
            param_type.ipIndex() != .type_type)
        {
            var bound_value: ?Type = null;
            if (param_type.isEnumType()) {
                const resolved_argument = try analyser.resolveComptimeValue(.of(arg, handle));
                const tag = if (resolved_argument != null and
                    resolved_argument.?.data == .enum_value and
                    resolved_argument.?.data.enum_value.enum_type.eql(param_type))
                    resolved_argument.?.data.enum_value.tag
                else
                    try analyser.resolveEnumValueTag(param_type, .of(arg, handle));
                if (tag) |enum_tag| {
                    bound_value = try analyser.enumValue(param_type, enum_tag);
                }
            } else if (param_type.ipIndex()) |param_type_index| {
                if (try analyser.resolveCoercedIPValue(param_type_index, .of(arg, handle))) |value| {
                    bound_value = Type.fromIP(analyser, analyser.ip.typeOf(value), value);
                } else if (try analyser.resolveInternPoolValue(.of(arg, handle))) |argument_value| {
                    var err_msg: ErrorMsg = undefined;
                    const coerced_value = try analyser.ip.coerce(
                        analyser.arena,
                        param_type_index,
                        argument_value,
                        builtin.target,
                        &err_msg,
                    );
                    if (coerced_value != .none) {
                        const value = if (analyser.ip.isUnknown(coerced_value)) argument_value else coerced_value;
                        bound_value = Type.fromIP(analyser, analyser.ip.typeOf(value), value);
                    }
                }
            }
            if (bound_value) |value| {
                try meta_params.put(analyser.arena, parameter_token_handle, value);
                try value_params.put(analyser.arena, parameter_token_handle, value);
                has_callsite_bindings = true;
                continue;
            }
        }

        const argument_type = (try analyser.resolveTypeOfNodeInternal(.of(arg, handle))) orelse continue;
        switch (param_type.data) {
            .ip_index => |info| {
                if (info.index == .type_type and argument_type.is_type_val) {
                    const token_handle: TokenWithHandle = .{ .token = param_name_token, .handle = func_info.handle };
                    try meta_params.put(analyser.arena, token_handle, argument_type);
                    try value_params.put(analyser.arena, token_handle, argument_type);
                    has_callsite_bindings = true;
                }
            },
            .anytype_parameter => |info| {
                const argument_meta_type = try argument_type.typeOf(analyser);
                try meta_params.put(analyser.arena, info.token_handle, argument_meta_type);
                has_callsite_bindings = true;
                if (param.modifier == .comptime_param) {
                    if (try analyser.resolveComptimeValue(.of(arg, handle))) |argument_value| {
                        try value_params.put(analyser.arena, parameter_token_handle, argument_value);
                    } else {
                        try value_params.put(analyser.arena, parameter_token_handle, argument_type);
                    }
                } else {
                    try value_params.put(analyser.arena, parameter_token_handle, argument_type);
                }
            },
            else => {},
        }

        if (param.modifier == .comptime_param) {
            if (try analyser.resolveStringLiteral(.of(arg, handle))) |bytes| {
                const string_type = if (param_type.data == .anytype_parameter)
                    try argument_type.typeOf(analyser)
                else
                    param_type;
                try value_params.put(
                    analyser.arena,
                    .{ .token = param_name_token, .handle = func_info.handle },
                    try analyser.stringValueWithType(bytes, string_type),
                );
                has_callsite_bindings = true;
                continue;
            }
        }

        if (param.modifier == .comptime_param and
            param_type.isOptionalType(analyser) and
            argument_type.ipIndex() != null and
            analyser.ip.isNull(argument_type.ipIndex().?))
        {
            const token_handle: TokenWithHandle = .{ .token = param_name_token, .handle = func_info.handle };
            try meta_params.put(analyser.arena, token_handle, argument_type);
            try value_params.put(analyser.arena, token_handle, argument_type);
            has_callsite_bindings = true;
        }
    }

    var resolved = try analyser.resolveGenericType(func_ty, meta_params);
    // Type functions are initially analyzed without concrete arguments. Once
    // the call binds those arguments, re-evaluate the return expression so
    // comptime values can select branches and shape generated types.
    if ((has_callsite_bindings or can_evaluate_type_function) and
        func_tree.nodeTag(func_info.fn_node) == .fn_decl)
    {
        const old_bindings = analyser.generic_bindings;
        analyser.generic_bindings = &value_params;
        defer analyser.generic_bindings = old_bindings;

        if (try analyser.resolveReturnValueOfFuncNode(func_info.handle, func_info.fn_node)) |return_value| {
            resolved.data.function.return_value = try analyser.allocType(return_value);
        }
    }

    return resolved;
}

fn resolveEitherCallResult(
    analyser: *Analyser,
    handle: *DocumentStore.Handle,
    call: Ast.full.Call,
    callable: Type,
) Error!?Type {
    const entries = switch (callable.data) {
        .either => |entries| entries,
        else => return null,
    };

    var return_types: std.ArrayList(Type.TypeWithDescriptor) = .empty;
    for (entries) |entry| {
        const candidate: Type = .{
            .data = entry.type_data,
            .is_type_val = callable.is_type_val,
        };
        var func_ty = try analyser.resolveFuncProtoOfCallable(candidate) orelse return null;
        if (func_ty.is_type_val) return null;
        func_ty = try analyser.resolveFunctionTypeFromCall(handle, call, func_ty);
        try return_types.append(analyser.arena, .{
            .type = func_ty.data.function.return_value.*,
            .descriptor = entry.descriptor,
        });
    }
    return Type.fromEither(analyser, return_types.items);
}

fn isKnownEmptyIterable(analyser: *Analyser, iterable: Type) bool {
    return switch (iterable.data) {
        .array => |info| info.elem_count == 0,
        .tuple => |fields| fields.len == 0,
        .pointer => |info| info.size == .one and isKnownEmptyIterable(analyser, info.elem_ty.*),
        .ip_index => |payload| isKnownEmptyIterableType(analyser, if (iterable.is_type_val)
            payload.index orelse return false
        else
            payload.type),
        else => false,
    };
}

fn isKnownEmptyForInput(
    analyser: *Analyser,
    input: Ast.Node.Index,
    handle: *DocumentStore.Handle,
    container_type: ?Type,
) Error!bool {
    const tree = &handle.tree;
    if (tree.nodeTag(input) == .for_range) {
        const start, const end_optional = tree.nodeData(input).node_and_opt_node;
        const end = end_optional.unwrap() orelse return false;
        const start_value = try analyser.resolveComptimeValue(.{
            .node_handle = .of(start, handle),
            .container_type = container_type,
        }) orelse return false;
        const end_value = try analyser.resolveComptimeValue(.{
            .node_handle = .of(end, handle),
            .container_type = container_type,
        }) orelse return false;
        return analyser.resolveComparisonBool(.equal_equal, start_value, end_value) orelse false;
    }

    const iterable = try analyser.resolveTypeOfNodeInternal(.{
        .node_handle = .of(input, handle),
        .container_type = container_type,
    }) orelse return false;
    return isKnownEmptyIterable(analyser, iterable);
}

fn isKnownEmptyIterableType(analyser: *Analyser, type_index: InternPool.Index) bool {
    return switch (analyser.ip.indexToKey(type_index)) {
        .array_type => |info| info.len == 0,
        .tuple_type => |info| info.types.len == 0,
        .pointer_type => |info| info.flags.size == .one and
            isKnownEmptyIterableType(analyser, info.elem_type),
        else => false,
    };
}

const BreakIterator = struct {
    const Value = union(enum) {
        operand: Ast.Node.Index,
        void,
    };

    walker: ast.Walker,
    label: ?[]const u8,
    allow_unlabeled: bool,
    loop_depth: u32 = 0,

    fn next(
        it: *BreakIterator,
        analyser: *Analyser,
        handle: *DocumentStore.Handle,
        container_type: ?Type,
    ) Error!?Value {
        const tree = &handle.tree;
        while (true) {
            const event = try it.walker.next(analyser.gpa, tree) orelse return null;
            switch (event) {
                .open => |node| switch (tree.nodeTag(node)) {
                    .@"break" => {
                        const opt_label_token, const opt_operand = tree.nodeData(node).opt_token_and_opt_node;
                        if (try it.isInKnownUnselectedBranch(analyser, handle, container_type)) continue;

                        if (it.label) |label| {
                            const label_token = opt_label_token.unwrap() orelse continue;
                            if (!std.mem.eql(u8, label, offsets.identifierTokenToNameSlice(tree, label_token))) continue;
                            return if (opt_operand.unwrap()) |operand| .{ .operand = operand } else .void;
                        }

                        if (it.allow_unlabeled and it.loop_depth == 0 and opt_label_token == .none) {
                            return if (opt_operand.unwrap()) |operand| .{ .operand = operand } else .void;
                        }
                    },

                    .@"while",
                    .while_simple,
                    .while_cont,
                    .@"for",
                    .for_simple,
                    => {
                        if (it.label == null) {
                            // We can ignore the inner loop
                            it.walker.skip();
                            continue;
                        }
                        it.loop_depth += 1;
                    },
                    else => {},
                },
                .close => |node| switch (tree.nodeTag(node)) {
                    .@"while",
                    .while_simple,
                    .while_cont,
                    .@"for",
                    .for_simple,
                    => {
                        it.loop_depth -= 1;
                    },
                    else => {},
                },
            }
        }
    }

    fn isInKnownUnselectedBranch(
        it: *const BreakIterator,
        analyser: *Analyser,
        handle: *DocumentStore.Handle,
        container_type: ?Type,
    ) Error!bool {
        const tree = &handle.tree;
        const stack = it.walker.stack.items;
        if (stack.len < 2) return false;
        for (stack[0 .. stack.len - 1], stack[1..]) |ancestor, child| {
            switch (tree.nodeTag(ancestor.node)) {
                .@"if", .if_simple => {
                    const if_node = ast.fullIf(tree, ancestor.node).?;
                    if (child.node == if_node.ast.cond_expr) continue;
                    const condition = try analyser.resolveIfConditionValue(.{
                        .node_handle = .of(if_node.ast.cond_expr, handle),
                        .container_type = container_type,
                    }) orelse continue;
                    if ((!condition and child.node == if_node.ast.then_expr) or
                        (condition and if_node.ast.else_expr.unwrap() == child.node)) return true;
                },
                .@"switch", .switch_comma => {
                    const switch_node = tree.switchFull(ancestor.node);
                    if (child.node == switch_node.ast.condition) continue;
                    const selected_target = try analyser.resolveKnownSwitchTarget(.{
                        .node_handle = .of(ancestor.node, handle),
                        .container_type = container_type,
                    }) orelse continue;
                    const switch_case = tree.fullSwitchCase(child.node) orelse continue;
                    if (switch_case.ast.target_expr != selected_target) return true;
                },
                else => {},
            }
        }
        return false;
    }
};

pub fn resolveInstanceOfNode(analyser: *Analyser, options: ResolveOptions) Error!?Type {
    const ty = try analyser.resolveTypeOfNode(options) orelse return null;
    return ty.instanceTypeVal(analyser);
}

/// Resolves the type of an Ast Node.
/// Returns `null` if the type could not be resolved.
pub fn resolveTypeOfNode(analyser: *Analyser, options: ResolveOptions) Error!?Type {
    const binding = try analyser.resolveBindingOfNode(options) orelse return null;
    return binding.type;
}

fn resolveTypeOfNodeInternal(analyser: *Analyser, options: ResolveOptions) Error!?Type {
    const binding = try analyser.resolveBindingOfNodeInternal(options) orelse return null;
    return binding.type;
}

pub fn resolveBindingOfNode(analyser: *Analyser, options: ResolveOptions) Error!?Binding {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    return analyser.resolveBindingOfNodeInternal(options);
}

fn resolveBindingOfNodeInternal(analyser: *Analyser, options: ResolveOptions) Error!?Binding {
    const old_bindings = analyser.generic_bindings;
    defer analyser.generic_bindings = old_bindings;

    var merged_bindings: TokenToTypeMap = .empty;
    if (options.container_type) |*container_type| {
        if (container_type.data == .container) {
            const bindings = &container_type.data.container.bound_params;
            for (bindings.values()) |binding| {
                if (!binding.hasKnownValue(analyser)) continue;
                if (old_bindings) |outer_bindings| {
                    merged_bindings = try outer_bindings.clone(analyser.arena);
                    for (bindings.keys(), bindings.values()) |key, bound| {
                        try merged_bindings.put(analyser.arena, key, bound);
                    }
                    analyser.generic_bindings = &merged_bindings;
                } else {
                    analyser.generic_bindings = bindings;
                }
                break;
            }
        }
    }

    // Specializations must not populate caches keyed only by the source node.
    if (analyser.generic_bindings != null) {
        const node_with_uri: NodeWithUri = .{
            .node = options.node_handle.node,
            .uri = options.node_handle.handle.uri,
        };
        const gop = try analyser.resolving_specialized_nodes.getOrPut(analyser.gpa, node_with_uri);
        if (gop.found_existing) return null;
        defer std.debug.assert(analyser.resolving_specialized_nodes.remove(node_with_uri));
        return analyser.resolveBindingOfNodeUncached(options);
    }

    const node_handle = options.node_handle;
    const node_with_uri: NodeWithUri = .{
        .node = node_handle.node,
        .uri = node_handle.handle.uri,
    };
    const cache = if (analyser.evaluate_comptime_control_flow)
        &analyser.resolved_control_flow_values
    else if (analyser.evaluate_comptime_values)
        &analyser.resolved_values
    else
        &analyser.resolved_nodes;
    const gop = try cache.getOrPut(analyser.gpa, node_with_uri);
    if (gop.found_existing) return gop.value_ptr.*;

    // we insert null before resolving the type so that a recursive definition doesn't result in an infinite loop
    gop.value_ptr.* = null;

    const binding = try analyser.resolveBindingOfNodeUncached(options);
    if (binding != null) {
        cache.getPtr(node_with_uri).?.* = binding;
    }

    return binding;
}

fn resolveTypeOfNodeUncached(analyser: *Analyser, options: ResolveOptions) Error!?Type {
    const node_handle = options.node_handle;
    const node = node_handle.node;
    const handle = node_handle.handle;
    const tree = &handle.tree;

    switch (tree.nodeTag(node)) {
        .global_var_decl,
        .local_var_decl,
        .simple_var_decl,
        .aligned_var_decl,
        => {
            const var_decl = tree.fullVarDecl(node).?;
            const mut_token_tag = tree.tokenTag(var_decl.ast.mut_token);
            const old_evaluate_comptime_values = analyser.evaluate_comptime_values;
            if (mut_token_tag == .keyword_const and analyser.resolve_number_literal_values) {
                analyser.evaluate_comptime_values = true;
            }
            defer analyser.evaluate_comptime_values = old_evaluate_comptime_values;
            var fallback_type: ?Type = null;

            if (var_decl.ast.type_node.unwrap()) |type_node| blk: {
                const decl_type = try analyser.resolveTypeOfNodeInternal(.{
                    .node_handle = .of(type_node, handle),
                    .container_type = options.container_type,
                }) orelse break :blk;
                if (decl_type.isMetaType()) {
                    fallback_type = .unknown_type;
                    break :blk;
                }
                if (mut_token_tag == .keyword_const) num: {
                    const init_node = var_decl.ast.init_node.unwrap() orelse break :num;
                    if (decl_type.isEnumType()) {
                        if (try analyser.resolveEnumValueTag(decl_type, .of(init_node, handle))) |tag| {
                            return try analyser.enumValue(decl_type, tag);
                        }
                    }
                    const ip_ty = decl_type.ipIndex() orelse break :num;
                    const ip_index = try analyser.resolveCoercedIPValue(ip_ty, .of(init_node, handle)) orelse break :num;
                    return Type.fromIP(analyser, analyser.ip.typeOf(ip_index), ip_index);
                }
                return try decl_type.instanceTypeVal(analyser);
            }

            if (var_decl.ast.init_node.unwrap()) |init_node| blk: {
                const ty = try analyser.resolveTypeOfNodeInternal(.of(init_node, handle)) orelse break :blk;
                if (mut_token_tag == .keyword_var)
                    return ty.withoutIPIndex(analyser);
                return ty;
            }

            return fallback_type;
        },
        .call,
        .call_comma,
        .call_one,
        .call_one_comma,
        => {
            var buffer: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&buffer, node).?;

            const ty = try analyser.resolveTypeOfNodeInternal(.of(call.ast.fn_expr, handle)) orelse return null;
            if (ty.data == .either) {
                return try analyser.resolveEitherCallResult(handle, call, ty);
            }
            var func_ty = try analyser.resolveFuncProtoOfCallable(ty) orelse return null;
            if (func_ty.is_type_val) return null;

            func_ty = try analyser.resolveFunctionTypeFromCall(handle, call, func_ty);
            const func_info = func_ty.data.function;
            const func_uri = func_info.handle.uri.raw;

            if (std.mem.endsWith(u8, func_uri, "/std/meta.zig") and func_info.name != null) {
                const func_name = func_info.name.?;

                if (std.mem.eql(u8, func_name, "ArgsTuple")) {
                    if (call.ast.params.len < 1) return .unknown_type;
                    const arg = call.ast.params[0];
                    const arg_ty = try analyser.resolveTypeOfNodeInternal(.of(arg, handle)) orelse return .unknown_type;
                    if (!arg_ty.is_type_val or arg_ty.data != .function) return .unknown_type;
                    const arg_func_info = arg_ty.data.function;
                    if (arg_func_info.has_varargs) return .unknown_type;
                    const arg_func_params = arg_func_info.parameters;
                    const elem_ty_slice = try analyser.arena.alloc(Type, arg_func_params.len);
                    for (arg_func_params, elem_ty_slice) |param, *elem_ty| {
                        if (param.type.data == .anytype_parameter) return .unknown_type;
                        elem_ty.* = param.type;
                    }
                    return try Type.createTupleType(analyser, elem_ty_slice);
                }

                if (std.mem.eql(u8, func_name, "Tag")) {
                    if (call.ast.params.len < 1) return .unknown_type;
                    const arg = call.ast.params[0];
                    const arg_ty = try analyser.resolveTypeOfNodeInternal(.of(arg, handle)) orelse return .unknown_type;
                    // TODO: handle enum tag, e.g. `enum(u8)`
                    const tag_type = try analyser.resolveUnionTag(arg_ty) orelse return .unknown_type;
                    return try tag_type.typeOf(analyser);
                }
            }

            return func_info.return_value.*;
        },
        .container_field,
        .container_field_init,
        .container_field_align,
        => {
            const container_type = options.container_type orelse try analyser.innermostContainer(handle, tree.tokenStart(tree.firstToken(node)));
            if (container_type.isEnumType())
                return try container_type.instanceTypeVal(analyser);

            var field = tree.fullContainerField(node).?;

            if (container_type.isTaggedUnion()) {
                field.convertToNonTupleLike(tree);
                if (field.ast.type_expr == .none)
                    return Type.fromIP(analyser, .void_type, null);
            }

            const base = field.ast.type_expr.unwrap().?;
            const base_type = (try analyser.resolveTypeOfNodeInternal(.{
                .node_handle = .of(base, handle),
                .container_type = options.container_type,
            })) orelse return null;
            return try base_type.instanceTypeVal(analyser);
        },
        .@"comptime",
        .@"nosuspend",
        => return try analyser.resolveTypeOfNodeInternal(.of(tree.nodeData(node).node, handle)),
        .grouped_expression,
        => return try analyser.resolveTypeOfNodeInternal(.of(tree.nodeData(node).node_and_token[0], handle)),
        .struct_init,
        .struct_init_comma,
        .struct_init_one,
        .struct_init_one_comma,
        => {
            var buffer: [2]Ast.Node.Index = undefined;
            const struct_init = tree.fullStructInit(&buffer, node).?;

            const type_expr = struct_init.ast.type_expr.unwrap().?;
            const lhs = try analyser.resolveTypeOfNodeInternal(.of(type_expr, handle)) orelse return null;

            if (lhs.data == .array and lhs.data.array.elem_count == null) {
                var ty = lhs;
                ty.data.array.elem_count = struct_init.ast.fields.len;
                return try ty.instanceTypeVal(analyser);
            }
            return try lhs.instanceTypeVal(analyser);
        },
        .unwrap_optional => {
            const lhs_node, _ = tree.nodeData(node).node_and_token;

            const base_type = try analyser.resolveTypeOfNodeInternal(.of(lhs_node, handle)) orelse return null;

            return try analyser.resolveOptionalUnwrap(base_type);
        },
        .@"orelse" => {
            const lhs_node, const rhs_node = tree.nodeData(node).node_and_node;

            const lhs = try analyser.resolveTypeOfNodeInternal(.of(lhs_node, handle)) orelse return null;
            if (analyser.evaluate_comptime_values) {
                if (lhs.ipIndex()) |index| switch (analyser.ip.indexToKey(index)) {
                    .null_value => return try analyser.resolveTypeOfNodeInternal(.of(rhs_node, handle)),
                    .optional_value => |value| return Type.fromIP(analyser, analyser.ip.typeOf(value.val), value.val),
                    else => {},
                };
            }

            const rhs = try analyser.resolveTypeOfNodeInternal(.of(rhs_node, handle)) orelse return try analyser.resolveOptionalUnwrap(lhs);

            return try analyser.resolveOrelseType(lhs, rhs);
        },
        .@"catch" => {
            const lhs_node, const rhs_node = tree.nodeData(node).node_and_node;

            const lhs = try analyser.resolveTypeOfNodeInternal(.of(lhs_node, handle)) orelse return null;
            if (analyser.evaluate_comptime_values) {
                if (lhs.ipIndex()) |index| switch (analyser.ip.indexToKey(index)) {
                    .error_value => return try analyser.resolveTypeOfNodeInternal(.of(rhs_node, handle)),
                    else => {},
                };
            }

            const rhs = try analyser.resolveTypeOfNodeInternal(.of(rhs_node, handle)) orelse
                return try analyser.resolveUnwrapErrorUnionType(lhs, .payload);
            return try analyser.resolveCatchType(lhs, rhs);
        },
        .@"try" => {
            const expr_node = tree.nodeData(node).node;

            const base_type = try analyser.resolveTypeOfNodeInternal(.of(expr_node, handle)) orelse return null;

            return try analyser.resolveUnwrapErrorUnionType(base_type, .payload);
        },
        .optional_type => {
            const expr_node = tree.nodeData(node).node;

            const child_ty = try analyser.resolveTypeOfNodeInternal(.of(expr_node, handle)) orelse return null;
            if (!child_ty.is_type_val) return null;

            return try Type.createOptionalType(analyser, child_ty);
        },
        .ptr_type_aligned,
        .ptr_type_sentinel,
        .ptr_type,
        .ptr_type_bit_range,
        => {
            const ptr_info = ast.fullPtrType(tree, node).?;
            const size = ptr_info.size;
            const is_const = ptr_info.const_token != null;

            const sentinel = try analyser.resolveOptionalIPValue(ptr_info.ast.sentinel, handle);

            const elem_ty = try analyser.resolveTypeOfNodeInternal(.of(ptr_info.ast.child_type, handle)) orelse return null;
            if (!elem_ty.is_type_val) return null;

            return try Type.createPointerType(analyser, size, sentinel, is_const, elem_ty);
        },
        .array_type,
        .array_type_sentinel,
        => {
            const array_info = tree.fullArrayType(node).?;
            const elem_count = try analyser.resolveIntegerLiteral(u64, .{
                .node_handle = .of(array_info.ast.elem_count, handle),
                .container_type = options.container_type,
            });
            const sentinel = try analyser.resolveOptionalIPValue(array_info.ast.sentinel, handle);

            const elem_ty = try analyser.resolveTypeOfNodeInternal(.{
                .node_handle = .of(array_info.ast.elem_type, handle),
                .container_type = options.container_type,
            }) orelse return null;
            if (!elem_ty.is_type_val) return null;

            return try Type.createArrayType(analyser, elem_count, sentinel, elem_ty);
        },
        .array_init_one,
        .array_init_one_comma,
        .array_init_dot_two,
        .array_init_dot_two_comma,
        .array_init_dot,
        .array_init_dot_comma,
        .array_init,
        .array_init_comma,
        => {
            var buffer: [2]Ast.Node.Index = undefined;
            const array_init_info = tree.fullArrayInit(&buffer, node).?;

            if (array_init_info.ast.type_expr.unwrap()) |type_expr| blk: {
                var array_ty = try analyser.resolveTypeOfNode(.of(type_expr, handle)) orelse break :blk;
                if (array_ty.data == .array and array_ty.data.array.elem_count == null) {
                    const info = array_ty.data.array;
                    array_ty = try Type.createArrayType(
                        analyser,
                        array_init_info.ast.elements.len,
                        info.sentinel,
                        info.elem_ty.*,
                    );
                }
                if (analyser.evaluate_comptime_values) {
                    if (try analyser.resolveArrayValue(array_ty, array_init_info.ast.elements, handle)) |value| {
                        return value;
                    }
                }
                return try array_ty.instanceTypeVal(analyser);
            }

            const elem_ty_slice = try analyser.arena.alloc(Type, array_init_info.ast.elements.len);
            for (elem_ty_slice, array_init_info.ast.elements) |*elem_ty, element| {
                elem_ty.* = try analyser.resolveTypeOfNodeInternal(.of(element, handle)) orelse return null;
            }
            if (analyser.evaluate_comptime_values) {
                if (try Type.createTupleValue(analyser, elem_ty_slice)) |tuple| return tuple;
            }
            for (elem_ty_slice) |*elem_ty| {
                elem_ty.* = try elem_ty.typeOf(analyser);
            }
            const tuple_ty = try Type.createTupleType(analyser, elem_ty_slice);
            return try tuple_ty.instanceUnchecked(analyser);
        },
        .error_union => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;

            const error_set = try analyser.resolveTypeOfNodeInternal(.of(lhs, handle)) orelse return null;
            if (!error_set.is_type_val) return null;

            const payload = try analyser.resolveTypeOfNodeInternal(.of(rhs, handle)) orelse return null;
            if (!payload.is_type_val) return null;

            return try Type.createErrorUnionType(analyser, error_set, payload);
        },

        .merge_error_sets => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            const lhs_index = try analyser.resolveErrorSetIPIndex(.of(lhs, handle)) orelse return null;
            const rhs_index = try analyser.resolveErrorSetIPIndex(.of(rhs, handle)) orelse return null;
            const ip_index = try analyser.ip.errorSetMerge(lhs_index, rhs_index);
            return Type.fromIP(analyser, .type_type, ip_index);
        },

        .error_set_decl => {
            const lbrace, const rbrace = tree.nodeData(node).token_and_token;
            var strings: std.array_hash_map.Auto(InternPool.String, void) = .empty;
            defer strings.deinit(analyser.gpa);
            var i: usize = 0;
            for (lbrace + 1..rbrace) |tok_i| {
                if (tree.tokenTag(@intCast(tok_i)) != .identifier) continue;
                const identifier_token: Ast.TokenIndex = @intCast(tok_i);
                defer i += 1;
                const name = offsets.tokenToSlice(tree, identifier_token);
                const index = try analyser.ip.string_pool.getOrPutString(analyser.store.io, analyser.gpa, name);
                try strings.put(analyser.gpa, index, {});
            }
            const names = try analyser.ip.getStringSlice(strings.keys());
            const ip_index = try analyser.ip.get(.{ .error_set_type = .{ .owner_decl = .none, .names = names } });
            return Type.fromIP(analyser, .type_type, ip_index);
        },

        .container_decl,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        => |tag| {
            not_a_tuple: {
                switch (tag) {
                    .container_decl,
                    .container_decl_trailing,
                    .container_decl_two,
                    .container_decl_two_trailing,
                    => {},
                    else => break :not_a_tuple,
                }

                var buffer: [2]Ast.Node.Index = undefined;
                const container_decl = tree.fullContainerDecl(&buffer, node).?;
                if (container_decl.ast.members.len == 0) break :not_a_tuple; // technically a tuple
                if (tree.tokenTag(container_decl.ast.main_token) != .keyword_struct) break :not_a_tuple;
                const elem_ty_slice = try analyser.arena.alloc(Type, container_decl.ast.members.len);

                var has_unresolved_fields = false;
                for (elem_ty_slice, container_decl.ast.members) |*elem_ty, member_node| {
                    const container_field = tree.fullContainerField(member_node) orelse break :not_a_tuple;
                    if (!container_field.ast.tuple_like) break :not_a_tuple;
                    const type_expr = container_field.ast.type_expr.unwrap().?;
                    elem_ty.* = try analyser.resolveTypeOfNodeInternal(.of(type_expr, handle)) orelse {
                        has_unresolved_fields = true;
                        continue;
                    };
                }

                if (has_unresolved_fields) return null;
                return try Type.createTupleType(analyser, elem_ty_slice);
            }

            return try analyser.innermostContainer(handle, tree.tokenStart(tree.firstToken(node)));
        },
        .builtin_call,
        .builtin_call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        => {
            var buffer: [2]Ast.Node.Index = undefined;
            const params = tree.builtinCallParams(&buffer, node).?;

            const call_name = tree.tokenSlice(tree.nodeMainToken(node));

            const item = std.zig.BuiltinFn.list.get(call_name) orelse return null;
            switch (item.tag) {
                .This => {
                    if (params.len != 0) return null;
                    return options.container_type orelse try analyser.innermostContainer(handle, tree.tokenStart(tree.firstToken(node)));
                },
                .as => {
                    if (params.len < 1) return null;
                    const ty = (try analyser.resolveTypeOfNodeInternal(.of(params[0], handle))) orelse return null;
                    if (analyser.evaluate_comptime_values and params.len >= 2 and ty.isEnumType()) {
                        if (try analyser.resolveEnumValueTag(ty, .of(params[1], handle))) |tag| {
                            return try analyser.enumValue(ty, tag);
                        }
                    }
                    if (analyser.evaluate_comptime_values and
                        params.len >= 2 and
                        analyser.isStringSliceType(ty))
                    {
                        const operand = try analyser.resolveTypeOfNodeInternal(.of(params[1], handle)) orelse return null;
                        if (operand.data == .string_value) {
                            return try analyser.stringValueWithType(operand.data.string_value.bytes, ty);
                        }
                    }
                    num: {
                        if (params.len < 2) break :num;
                        const ip_ty = ty.ipIndex() orelse break :num;
                        const ip_index = try analyser.resolveCoercedIPValue(ip_ty, .of(params[1], handle)) orelse break :num;
                        return Type.fromIP(analyser, analyser.ip.typeOf(ip_index), ip_index);
                    }
                    return try ty.instanceTypeVal(analyser);
                },
                .atomic_load,
                .atomic_rmw,
                .@"extern",
                .union_init,
                => {
                    if (params.len < 1) return null;
                    const ty = (try analyser.resolveTypeOfNodeInternal(.of(params[0], handle))) orelse return null;
                    return try ty.instanceTypeVal(analyser);
                },
                .cmpxchg_strong, .cmpxchg_weak => {
                    if (params.len != 6) return null;
                    const child_type = try analyser.resolveTypeOfNodeInternal(.of(params[0], handle)) orelse return null;
                    if (!child_type.is_type_val) return null;
                    const optional_type = try Type.createOptionalType(analyser, child_type);
                    return try optional_type.instanceUnchecked(analyser);
                },
                .mul_add => {
                    if (params.len != 4) return null;
                    const ty = try analyser.resolveTypeOfNodeInternal(.of(params[0], handle)) orelse return null;
                    const result_type = ty.ipIndex() orelse return null;
                    const result = try ty.instanceTypeVal(analyser) orelse return null;
                    if (!analyser.evaluate_comptime_values) return result;
                    const a = try analyser.resolveCoercedIPValue(result_type, .of(params[1], handle)) orelse return result;
                    const b = try analyser.resolveCoercedIPValue(result_type, .of(params[2], handle)) orelse return result;
                    const c = try analyser.resolveCoercedIPValue(result_type, .of(params[3], handle)) orelse return result;
                    if (analyser.ip.zigTypeTag(result_type) == .vector) {
                        return try analyser.resolveFloatVectorMulAddValue(result_type, a, b, c) orelse result;
                    }
                    return try analyser.resolveFloatMulAddValue(result_type, a, b, c) orelse result;
                },

                .c_va_arg => {
                    if (params.len < 2) return null;
                    const ty = (try analyser.resolveTypeOfNodeInternal(.of(params[1], handle))) orelse return null;
                    return try ty.instanceTypeVal(analyser);
                },
                .sin,
                .cos,
                .tan,
                .exp,
                .exp2,
                .log,
                .log2,
                .log10,
                .sqrt,
                => |tag| {
                    if (params.len != 1) return null;
                    const ty = (try analyser.resolveTypeOfNodeInternal(.of(params[0], handle))) orelse return null;
                    const payload = switch (ty.data) {
                        .ip_index => |payload| payload,
                        else => return null,
                    };
                    if (!analyser.ip.isFloat(analyser.ip.scalarType(payload.type))) return null;
                    if (analyser.evaluate_comptime_values) {
                        if (analyser.ip.zigTypeTag(payload.type) == .vector) {
                            if (try analyser.resolveFloatVectorUnaryValue(tag, ty)) |value| return value;
                        } else if (try analyser.resolveFloatUnaryBuiltinValue(tag, ty)) |value| {
                            return value;
                        }
                    }
                    return Type.fromIP(analyser, payload.type, null);
                },
                .floor,
                .ceil,
                .trunc,
                .round,
                => |tag| {
                    if (params.len != 1) return null;
                    const ty = (try analyser.resolveTypeOfNodeInternal(.of(params[0], handle))) orelse return null;
                    const payload = switch (ty.data) {
                        .ip_index => |payload| payload,
                        else => return null,
                    };
                    if (!analyser.ip.isFloat(analyser.ip.scalarType(payload.type))) return null;
                    if (analyser.evaluate_comptime_values) {
                        if (analyser.ip.zigTypeTag(payload.type) == .vector) {
                            if (try analyser.resolveFloatVectorUnaryValue(tag, ty)) |value| return value;
                        } else if (try analyser.resolveFloatRoundingValue(tag, ty)) |value| {
                            return value;
                        }
                    }
                    return Type.fromIP(analyser, payload.type, null);
                },
                .abs => {
                    if (params.len != 1) return null;

                    const ty = try analyser.resolveTypeOfNodeInternal(.of(params[0], handle)) orelse return null;

                    const payload = switch (ty.data) {
                        .ip_index => |payload| payload,
                        else => return null,
                    };

                    // Based on Sema.zirAbs
                    const operand_ty = payload.type;
                    const scalar_ty = analyser.ip.scalarType(operand_ty);
                    const scalar_tag = analyser.ip.zigTypeTag(scalar_ty) orelse return null;
                    const result_ty = switch (scalar_tag) {
                        .comptime_float, .float, .comptime_int => operand_ty,
                        .int => if (analyser.ip.isSignedInt(scalar_ty, builtin.target))
                            try analyser.ip.toUnsigned(operand_ty, builtin.target)
                        else
                            operand_ty,
                        else => return null,
                    };
                    if (analyser.evaluate_comptime_values) {
                        if (analyser.ip.zigTypeTag(operand_ty) == .vector) {
                            if (try analyser.resolveVectorUnaryValue(.abs, ty)) |value| return value;
                        } else if (try analyser.resolveAbsValue(ty)) |value| {
                            return value;
                        }
                    }

                    return Type.fromIP(analyser, result_ty, null);
                },
                .TypeOf => {
                    if (params.len < 1) return null;
                    var resolved_type = try analyser.resolveTypeOfNodeInternal(.of(params[0], handle)) orelse return null;
                    for (params[1..]) |param| {
                        const candidate = try analyser.resolveTypeOfNodeInternal(.of(param, handle)) orelse return .unknown_type;
                        resolved_type = try analyser.resolvePeerTypes(resolved_type, candidate) orelse {
                            if (!resolved_type.isGenericType() and !candidate.isGenericType()) return .unknown_type;
                            return .{
                                .data = .{ .anytype_parameter = .{
                                    .token_handle = .{ .token = tree.nodeMainToken(node), .handle = handle },
                                    .type_from_callsite_references = null,
                                } },
                                .is_type_val = true,
                            };
                        };
                    }
                    return try resolved_type.typeOf(analyser);
                },
                .bit_size_of, .size_of => |tag| {
                    if (params.len != 1) return null;
                    if (!analyser.evaluate_comptime_values) {
                        return Type.fromIP(analyser, .comptime_int_type, null);
                    }
                    const ty = try analyser.resolveTypeOfNodeInternal(.of(params[0], handle)) orelse return null;
                    const value = switch (tag) {
                        .bit_size_of => analyser.resolveTypeBitSize(ty),
                        .size_of => analyser.resolveTypeByteSize(ty),
                        else => unreachable,
                    } orelse return Type.fromIP(analyser, .comptime_int_type, null);
                    return try analyser.comptimeIntValue(value);
                },
                .int_from_bool => {
                    if (params.len != 1) return null;
                    const operand = try analyser.resolveTypeOfNodeInternal(.of(params[0], handle)) orelse return null;
                    if (try analyser.resolveVectorIntFromBoolValue(operand)) |result| {
                        return if (analyser.evaluate_comptime_values) result else result.withoutIPIndex(analyser);
                    }
                    if (!analyser.evaluate_comptime_values) {
                        return Type.fromIP(analyser, .u1_type, null);
                    }
                    const value = try analyser.resolveBoolValue(.of(params[0], handle)) orelse
                        return Type.fromIP(analyser, .u1_type, null);
                    return Type.fromIP(analyser, .u1_type, if (value) .one_u1 else .zero_u1);
                },
                .in_comptime => {
                    if (params.len != 0) return null;
                    if (analyser.evaluate_comptime_control_flow or analyser.generic_bindings != null) {
                        return Type.fromIP(analyser, .bool_type, .bool_true);
                    }
                    return Type.fromIP(analyser, .bool_type, null);
                },
                .int_from_enum => {
                    if (params.len != 1) return null;
                    const operand = try analyser.resolveTypeOfNodeInternal(.of(params[0], handle)) orelse return null;
                    if (operand.data == .enum_value) {
                        const int_value = operand.data.enum_value.int_value orelse return .unknown_type;
                        return Type.fromIP(analyser, analyser.ip.typeOf(int_value), int_value);
                    }
                    const enum_type = if (operand.is_type_val) operand else try operand.typeOf(analyser);
                    const container = switch (enum_type.data) {
                        .container => |container| container,
                        else => return .unknown_type,
                    };
                    const enum_tree = &container.scope_handle.handle.tree;
                    const enum_node = container.scope_handle.toNode();
                    var enum_buffer: [2]Ast.Node.Index = undefined;
                    const declaration = enum_tree.fullContainerDecl(&enum_buffer, enum_node) orelse return .unknown_type;
                    if (enum_tree.tokenTag(declaration.ast.main_token) != .keyword_enum) return .unknown_type;
                    if (declaration.ast.arg.unwrap()) |arg| {
                        const tag_type = try analyser.resolveTypeOfNodeInternal(.{
                            .node_handle = .of(arg, container.scope_handle.handle),
                            .container_type = enum_type,
                        }) orelse return .unknown_type;
                        return try tag_type.instanceTypeVal(analyser) orelse .unknown_type;
                    }
                    var field_count: u32 = 0;
                    for (declaration.ast.members) |member| {
                        if (enum_tree.fullContainerField(member) != null) field_count += 1;
                    }
                    if (field_count == 0) return .unknown_type;
                    const bits: u16 = @intCast(std.math.log2_int_ceil(u32, field_count));
                    const tag_type = try analyser.ip.get(.{ .int_type = .{ .signedness = .unsigned, .bits = bits } });
                    return Type.fromIP(analyser, tag_type, null);
                },
                .tag_name => {
                    if (params.len != 1) return null;
                    const operand = try analyser.resolveTypeOfNodeInternal(.of(params[0], handle)) orelse return null;
                    if (operand.data == .enum_value) {
                        if (analyser.evaluate_comptime_values) {
                            return try analyser.stringValue(operand.data.enum_value.tag);
                        }
                        return try analyser.staticStringType(operand.data.enum_value.tag.len);
                    }
                    return analyser.resolveLangrefType(version_data.builtins.get(call_name).?.return_type);
                },
                .error_name => {
                    if (params.len != 1) return null;
                    const result = try analyser.resolveLangrefType(
                        version_data.builtins.get(call_name).?.return_type,
                    ) orelse return null;
                    if (!analyser.evaluate_comptime_values) return result;

                    const operand = try analyser.resolveTypeOfNodeInternal(.of(params[0], handle)) orelse return result;
                    const index = operand.ipIndex() orelse return result;
                    const error_value = switch (analyser.ip.indexToKey(index)) {
                        .error_value => |value| value,
                        else => return result,
                    };
                    const bytes = try analyser.ip.string_pool.stringToSliceAlloc(
                        analyser.store.io,
                        analyser.arena,
                        error_value.error_tag_name,
                    );
                    return try analyser.stringValueWithType(bytes, try result.typeOf(analyser));
                },
                .type_name => {
                    if (params.len != 1) return null;
                    const fallback = try analyser.resolveLangrefType(
                        version_data.builtins.get(call_name).?.return_type,
                    );
                    if (!analyser.evaluate_comptime_values) return fallback;

                    const operand = try analyser.resolveTypeOfNodeInternal(.of(params[0], handle)) orelse return fallback;
                    if (!analyser.canResolveTypeName(operand)) return fallback;
                    const bytes = try operand.stringifyTypeVal(analyser, .{ .truncate_container_decls = false });
                    return try analyser.stringValue(bytes);
                },
                .min, .max => |tag| {
                    if (params.len < 2) return null;
                    const resolved = try analyser.arena.alloc(Type, params.len);
                    const types = try analyser.arena.alloc(InternPool.Index, params.len);
                    for (params, resolved, types) |param, *value, *ty| {
                        value.* = try analyser.resolveTypeOfNodeInternal(.of(param, handle)) orelse return null;
                        if (value.is_type_val) return null;
                        ty.* = (try value.typeOf(analyser)).ipIndex() orelse return null;
                    }

                    const result_type = try analyser.ip.resolvePeerTypes(types, builtin.target);
                    if (result_type == .none) return null;
                    if (!analyser.evaluate_comptime_values) {
                        return Type.fromIP(analyser, result_type, null);
                    }
                    if (analyser.ip.zigTypeTag(result_type) == .vector) {
                        return try analyser.resolveVectorMinMaxValue(tag, resolved, result_type) orelse
                            Type.fromIP(analyser, result_type, null);
                    }
                    if (analyser.fixedWidthIntegerBounds(result_type)) |bounds| {
                        const boundary = switch (tag) {
                            .min => bounds.min,
                            .max => bounds.max,
                            else => unreachable,
                        };
                        var has_boundary = false;
                        var has_undefined = false;
                        for (resolved) |value| {
                            const index = value.ipIndex() orelse continue;
                            if (analyser.ip.isUndefined(index)) {
                                has_undefined = true;
                                continue;
                            }
                            if (analyser.ip.toInt(index, i256) == boundary) has_boundary = true;
                        }
                        if (has_boundary and !has_undefined) {
                            return try analyser.intValueWithType(result_type, boundary) orelse
                                Type.fromIP(analyser, result_type, null);
                        }
                    }

                    var selected = resolved[0];
                    switch (analyser.ip.zigTypeTag(result_type) orelse return Type.fromIP(analyser, result_type, null)) {
                        .int, .comptime_int => {
                            var selected_value = analyser.ip.toInt(selected.ipIndex() orelse return Type.fromIP(analyser, result_type, null), i256) orelse
                                return Type.fromIP(analyser, result_type, null);
                            for (resolved[1..]) |candidate| {
                                const candidate_value = analyser.ip.toInt(candidate.ipIndex() orelse return Type.fromIP(analyser, result_type, null), i256) orelse
                                    return Type.fromIP(analyser, result_type, null);
                                const prefer_candidate = switch (tag) {
                                    .min => candidate_value < selected_value,
                                    .max => candidate_value > selected_value,
                                    else => unreachable,
                                };
                                if (prefer_candidate) {
                                    selected = candidate;
                                    selected_value = candidate_value;
                                }
                            }
                        },
                        .float, .comptime_float => {
                            var selected_value = analyser.numericFloatValue(selected.ipIndex() orelse return Type.fromIP(analyser, result_type, null)) orelse
                                return Type.fromIP(analyser, result_type, null);
                            if (!std.math.isFinite(selected_value)) return Type.fromIP(analyser, result_type, null);
                            for (resolved[1..]) |candidate| {
                                const candidate_value = analyser.numericFloatValue(candidate.ipIndex() orelse return Type.fromIP(analyser, result_type, null)) orelse
                                    return Type.fromIP(analyser, result_type, null);
                                if (!std.math.isFinite(candidate_value)) return Type.fromIP(analyser, result_type, null);
                                const prefer_candidate = switch (tag) {
                                    .min => candidate_value < selected_value or
                                        (candidate_value == 0 and selected_value == 0 and
                                            std.math.signbit(candidate_value) and !std.math.signbit(selected_value)),
                                    .max => candidate_value > selected_value or
                                        (candidate_value == 0 and selected_value == 0 and
                                            !std.math.signbit(candidate_value) and std.math.signbit(selected_value)),
                                    else => unreachable,
                                };
                                if (prefer_candidate) {
                                    selected = candidate;
                                    selected_value = candidate_value;
                                }
                            }
                        },
                        else => return Type.fromIP(analyser, result_type, null),
                    }
                    const selected_index = selected.ipIndex().?;
                    if (analyser.ip.typeOf(selected_index) == result_type) return selected;
                    if (analyser.ip.zigTypeTag(result_type) == .float) {
                        const coerced = try analyser.coerceNumericToFloatValue(result_type, selected_index) orelse
                            return Type.fromIP(analyser, result_type, null);
                        return Type.fromIP(analyser, result_type, coerced);
                    }
                    var err_msg: ErrorMsg = undefined;
                    const coerced = try analyser.ip.coerce(analyser.arena, result_type, selected_index, builtin.target, &err_msg);
                    if (coerced == .none or analyser.ip.isUnknown(coerced)) {
                        return Type.fromIP(analyser, result_type, null);
                    }
                    return Type.fromIP(analyser, result_type, coerced);
                },
                .clz, .ctz, .pop_count => |tag| {
                    if (params.len != 1) return null;
                    const operand = try analyser.resolveTypeOfNodeInternal(.of(params[0], handle)) orelse return null;
                    if (operand.is_type_val) return null;
                    if (analyser.evaluate_comptime_values) {
                        if (operand.ipIndex()) |index| {
                            if (analyser.ip.zigTypeTag(analyser.ip.typeOf(index)) == .vector) {
                                if (try analyser.resolveVectorBitCountValue(tag, operand)) |value| return value;
                            } else if (try analyser.resolveBitCountValue(tag, operand)) |value| {
                                return value;
                            }
                        }
                    }
                    const operand_type = (try operand.typeOf(analyser)).ipIndex() orelse return null;
                    const scalar_type = analyser.ip.scalarType(operand_type);
                    if (analyser.ip.zigTypeTag(scalar_type) != .int) return null;
                    const bits = analyser.ip.intInfo(scalar_type, builtin.target).bits;
                    if (bits == 0) return null;
                    const result_bits: u16 = @intCast(std.math.log2_int_ceil(u32, @as(u32, bits) + 1));
                    const result_child = try analyser.ip.get(.{ .int_type = .{
                        .signedness = .unsigned,
                        .bits = result_bits,
                    } });
                    const result_type = if (analyser.ip.zigTypeTag(operand_type) == .vector)
                        try analyser.ip.get(.{ .vector_type = .{
                            .len = analyser.ip.vectorLen(operand_type),
                            .child = result_child,
                        } })
                    else
                        result_child;
                    return Type.fromIP(analyser, result_type, null);
                },
                .bit_reverse, .byte_swap => |tag| {
                    if (params.len != 1) return null;
                    const operand = try analyser.resolveTypeOfNodeInternal(.of(params[0], handle)) orelse return null;
                    if (operand.is_type_val) return null;
                    if (analyser.evaluate_comptime_values) {
                        if (operand.ipIndex()) |index| {
                            if (analyser.ip.zigTypeTag(analyser.ip.typeOf(index)) == .vector) {
                                if (try analyser.resolveVectorBitPermutationValue(tag, operand)) |value| return value;
                            } else if (try analyser.resolveBitPermutationValue(tag, operand)) |value| {
                                return value;
                            }
                        }
                    }
                    return operand.withoutIPIndex(analyser);
                },
                .div_trunc, .div_floor, .div_exact, .mod, .rem => |tag| {
                    if (params.len != 2) return null;
                    var lhs = try analyser.resolveTypeOfNodeInternal(.of(params[0], handle)) orelse return null;
                    var rhs = try analyser.resolveTypeOfNodeInternal(.of(params[1], handle)) orelse return null;
                    if (lhs.is_type_val or rhs.is_type_val) return null;
                    if (analyser.evaluate_comptime_values) {
                        if (try analyser.resolveIntegerDivisionValue(tag, lhs, rhs) orelse
                            try analyser.resolveFloatDivisionValue(tag, lhs, rhs) orelse
                            try analyser.resolveFloatRemainderValue(tag, lhs, rhs) orelse
                            try analyser.resolveVectorDivisionValue(tag, lhs, rhs)) |value| return value;
                    }
                    lhs = lhs.withoutIPIndex(analyser);
                    rhs = rhs.withoutIPIndex(analyser);
                    return analyser.resolvePeerTypes(lhs, rhs);
                },
                .shl_exact, .shr_exact => |tag| {
                    if (params.len != 2) return null;
                    const operand = try analyser.resolveTypeOfNodeInternal(.of(params[0], handle)) orelse return null;
                    if (operand.is_type_val) return null;
                    if (analyser.evaluate_comptime_values) {
                        const shift_operand = try analyser.resolveTypeOfNodeInternal(.of(params[1], handle)) orelse
                            return operand.withoutIPIndex(analyser);
                        if (!shift_operand.is_type_val) {
                            if (operand.ipIndex()) |index| {
                                if (analyser.ip.zigTypeTag(analyser.ip.typeOf(index)) == .vector) {
                                    const operation: VectorShiftOperation = if (tag == .shl_exact) .shl_exact else .shr_exact;
                                    if (try analyser.resolveVectorShiftValue(operation, operand, shift_operand)) |value| return value;
                                } else if (try analyser.resolveExactShiftValue(tag, operand, shift_operand)) |value| {
                                    return value;
                                }
                            }
                        }
                    }
                    return operand.withoutIPIndex(analyser);
                },
                .add_with_overflow,
                .sub_with_overflow,
                .mul_with_overflow,
                .shl_with_overflow,
                => |tag| {
                    if (params.len != 2) return null;
                    const lhs = try analyser.resolveTypeOfNodeInternal(.of(params[0], handle)) orelse return null;
                    const rhs = try analyser.resolveTypeOfNodeInternal(.of(params[1], handle)) orelse return null;
                    if (lhs.is_type_val or rhs.is_type_val) return null;
                    const lhs_type = (try lhs.typeOf(analyser)).ipIndex() orelse return null;
                    const rhs_type = (try rhs.typeOf(analyser)).ipIndex() orelse return null;
                    const result_type = if (tag == .shl_with_overflow)
                        lhs_type
                    else
                        try analyser.resolvePeerTypesIP(lhs_type, rhs_type) orelse return null;
                    if (analyser.ip.zigTypeTag(result_type) != .int) return null;
                    if (analyser.evaluate_comptime_values) {
                        const same_operand = tag == .sub_with_overflow and
                            try analyser.areSameIdentifierExpression(tree, params[0], params[1]);
                        const complementary_operands = tag == .add_with_overflow and
                            (try analyser.complementaryIdentifierOperand(tree, params[0], params[1], .bit_not)) != null;
                        if (try analyser.resolveOverflowValue(tag, lhs, rhs, same_operand, complementary_operands)) |value| return value;
                    }
                    var element_types = [_]Type{
                        Type.fromIP(analyser, .type_type, result_type),
                        Type.fromIP(analyser, .type_type, .u1_type),
                    };
                    const tuple_type = try Type.createTupleType(analyser, &element_types);
                    return try tuple_type.instanceUnchecked(analyser);
                },
                .reduce => {
                    if (params.len != 2) return null;
                    const operand = try analyser.resolveTypeOfNodeInternal(.of(params[1], handle)) orelse return null;
                    const payload = switch (operand.data) {
                        .ip_index => |payload| payload,
                        else => return null,
                    };
                    const vector = switch (analyser.ip.indexToKey(payload.type)) {
                        .vector_type => |vector| vector,
                        else => return null,
                    };
                    if (analyser.evaluate_comptime_values) {
                        const operation = try analyser.resolveReduceOperation(.of(params[0], handle));
                        if (operation) |op| {
                            if (try analyser.resolveReduceValue(op, operand)) |value| return value;
                            if (op == .Xor) {
                                if (try analyser.resolveEvenRuntimeSplatXorReduction(tree, handle, params[1], operand)) |value| return value;
                            }
                        }
                    }
                    return Type.fromIP(analyser, vector.child, null);
                },
                .select => {
                    if (params.len != 4) return null;
                    const element = try analyser.resolveTypeOfNodeInternal(.of(params[0], handle)) orelse return null;
                    if (!element.is_type_val) return null;
                    const element_type = element.ipIndex() orelse return null;
                    const predicate = try analyser.resolveTypeOfNodeInternal(.of(params[1], handle)) orelse return null;
                    const lhs = try analyser.resolveTypeOfNodeInternal(.of(params[2], handle)) orelse return null;
                    const rhs = try analyser.resolveTypeOfNodeInternal(.of(params[3], handle)) orelse return null;
                    if (analyser.evaluate_comptime_values) {
                        if (try analyser.resolveSelectValue(element_type, predicate, lhs, rhs)) |value| return value;
                    }
                    return try analyser.resolveSelectValue(element_type, predicate.withoutIPIndex(analyser), lhs.withoutIPIndex(analyser), rhs.withoutIPIndex(analyser));
                },
                .shuffle => {
                    if (params.len != 4) return null;
                    const element = try analyser.resolveTypeOfNodeInternal(.of(params[0], handle)) orelse return null;
                    if (!element.is_type_val) return null;
                    const element_type = element.ipIndex() orelse return null;
                    const lhs = try analyser.resolveTypeOfNodeInternal(.of(params[1], handle)) orelse return null;
                    const rhs = try analyser.resolveTypeOfNodeInternal(.of(params[2], handle)) orelse return null;
                    const mask = try analyser.resolveTypeOfNodeInternal(.of(params[3], handle)) orelse return null;
                    if (analyser.evaluate_comptime_values) {
                        if (try analyser.resolveShuffleValue(element_type, lhs, rhs, mask)) |value| return value;
                    }
                    return try analyser.resolveShuffleValue(
                        element_type,
                        lhs.withoutIPIndex(analyser),
                        rhs.withoutIPIndex(analyser),
                        mask.withoutIPIndex(analyser),
                    );
                },
                .has_field, .has_decl => |tag| {
                    if (params.len != 2) return null;
                    if (!analyser.evaluate_comptime_values) {
                        return Type.fromIP(analyser, .bool_type, null);
                    }
                    const container_type = try analyser.resolveTypeOfNodeInternal(.of(params[0], handle)) orelse
                        return Type.fromIP(analyser, .bool_type, null);
                    if (!container_type.is_type_val) return Type.fromIP(analyser, .bool_type, null);
                    const name = try analyser.resolveStringLiteral(.of(params[1], handle)) orelse
                        return Type.fromIP(analyser, .bool_type, null);
                    const kind: DocumentScope.DeclarationLookup.Kind = switch (tag) {
                        .has_field => .field,
                        .has_decl => .other,
                        else => unreachable,
                    };
                    const found = if (analyser.tupleFieldCount(container_type)) |field_count| switch (tag) {
                        .has_field => blk: {
                            const index = std.fmt.parseUnsigned(usize, name, 10) catch break :blk false;
                            break :blk index < field_count;
                        },
                        .has_decl => false,
                        else => unreachable,
                    } else try analyser.lookupSymbolContainer(container_type, name, kind) != null;
                    return Type.fromIP(analyser, .bool_type, if (found) .bool_true else .bool_false);
                },
                .import => {
                    if (params.len == 0) return null;
                    const import_param = params[0];
                    if (tree.nodeTag(import_param) != .string_literal) return null;

                    const string_literal = tree.tokenSlice(tree.nodeMainToken(import_param));
                    const import_string = string_literal[1 .. string_literal.len - 1];
                    if (std.mem.endsWith(u8, import_string, ".zon")) {
                        // TODO
                        return null;
                    }

                    if (try analyser.resolveImportString(handle, import_string)) |ty| return ty;
                    if (try analyser.resolveImportString(analyser.root_handle orelse return null, import_string)) |ty| return ty;
                    return null;
                },
                .c_import => {
                    if (!DocumentStore.supports_build_system) return null;
                    const cimport_uri = (try analyser.store.resolveCImport(handle, node)) orelse return null;

                    const new_handle = try analyser.store.getOrLoadHandle(cimport_uri) orelse return null;

                    return .{
                        .data = .{ .container = .root(new_handle) },
                        .is_type_val = true,
                    };
                },
                .FieldType => {
                    if (params.len < 2) return null;

                    const container_type = (try analyser.resolveTypeOfNodeInternal(.of(params[0], handle))) orelse return null;
                    const instance = try container_type.instanceTypeVal(analyser) orelse return null;

                    const field_name = try analyser.resolveStringLiteral(.of(params[1], handle)) orelse return null;

                    const field = try instance.lookupSymbol(analyser, field_name) orelse return null;
                    const result = try field.resolveType(analyser) orelse return null;
                    return try result.typeOf(analyser);
                },
                .field => {
                    if (params.len < 2) return null;

                    const lhs = (try analyser.resolveTypeOfNodeInternal(.of(params[0], handle))) orelse return null;

                    const field_name = try analyser.resolveStringLiteral(.of(params[1], handle)) orelse return null;
                    if (analyser.evaluate_comptime_values and lhs.isEnumType()) {
                        const decl = try analyser.lookupSymbolContainer(lhs, field_name, .field);
                        if (decl != null) return try analyser.enumValue(lhs, field_name);
                    }

                    return try analyser.resolveFieldAccess(lhs, field_name);
                },
                .compile_error => {
                    return .{ .data = .{ .compile_error = node_handle }, .is_type_val = false };
                },
                .EnumLiteral => {
                    return Type.fromIP(analyser, .type_type, .enum_literal_type);
                },
                .Int => {
                    if (params.len != 2) return null;
                    const signedness = try analyser.resolveSignedness(.of(params[0], handle)) orelse return null;
                    const bits = try analyser.resolveIntegerLiteral(u16, .of(params[1], handle)) orelse return null;
                    const int_type = try analyser.ip.get(.{ .int_type = .{
                        .signedness = signedness,
                        .bits = bits,
                    } });
                    return Type.fromIP(analyser, .type_type, int_type);
                },
                .Tuple => {
                    if (params.len != 1) return null;
                    return try analyser.resolveTupleTypeConstructor(.{
                        .node_handle = .of(params[0], handle),
                        .container_type = options.container_type,
                    });
                },
                .Pointer => {
                    if (params.len != 4) return .unknown_type;
                    const size = try analyser.resolvePointerSize(.of(params[0], handle)) orelse return .unknown_type;
                    const flags = try analyser.resolvePointerAttributes(size, .{
                        .node_handle = .of(params[1], handle),
                        .container_type = options.container_type,
                    }) orelse return .unknown_type;
                    const child = try analyser.resolveTypeOfNodeInternal(.{
                        .node_handle = .of(params[2], handle),
                        .container_type = options.container_type,
                    }) orelse return .unknown_type;
                    if (!child.is_type_val) return .unknown_type;
                    const child_type = child.ipIndex() orelse return .unknown_type;
                    const sentinel_value = try analyser.resolveComptimeValue(.{
                        .node_handle = .of(params[3], handle),
                        .container_type = options.container_type,
                    }) orelse return .unknown_type;
                    const sentinel = if (sentinel_value.ipIndex()) |index|
                        if (analyser.ip.isNull(index))
                            InternPool.Index.none
                        else
                            try analyser.coerceIP(child_type, index) orelse return .unknown_type
                    else
                        return .unknown_type;
                    if (sentinel != .none and (size == .one or size == .c)) return .unknown_type;
                    const pointer_type = try analyser.ip.get(.{ .pointer_type = .{
                        .elem_type = child_type,
                        .sentinel = sentinel,
                        .flags = flags,
                    } });
                    return Type.fromIP(analyser, .type_type, pointer_type);
                },
                .Fn => {
                    if (params.len != 4) return .unknown_type;
                    const parameter_tuple = try analyser.resolveTupleTypeConstructor(.{
                        .node_handle = .of(params[0], handle),
                        .container_type = options.container_type,
                    }) orelse return .unknown_type;
                    const parameter_tuple_index = parameter_tuple.ipIndex() orelse return .unknown_type;
                    const parameter_types = switch (analyser.ip.indexToKey(parameter_tuple_index)) {
                        .tuple_type => |tuple| tuple.types,
                        else => return .unknown_type,
                    };
                    const noalias_bits = try analyser.resolveFnParameterAttributes(.{
                        .node_handle = .of(params[1], handle),
                        .container_type = options.container_type,
                    }, parameter_types.len) orelse return .unknown_type;
                    const return_type = try analyser.resolveTypeOfNodeInternal(.{
                        .node_handle = .of(params[2], handle),
                        .container_type = options.container_type,
                    }) orelse return .unknown_type;
                    if (!return_type.is_type_val) return .unknown_type;
                    const return_type_index = return_type.ipIndex() orelse return .unknown_type;
                    const flags = try analyser.resolveFnAttributes(.{
                        .node_handle = .of(params[3], handle),
                        .container_type = options.container_type,
                    }) orelse return .unknown_type;
                    const function_type = try analyser.ip.get(.{ .function_type = .{
                        .args = parameter_types,
                        .args_is_noalias = noalias_bits,
                        .return_type = return_type_index,
                        .flags = flags,
                    } });
                    return Type.fromIP(analyser, .type_type, function_type);
                },
                .Struct => return try analyser.resolveStructTypeConstructor(
                    params,
                    handle,
                    options.container_type,
                ) orelse .unknown_type,
                .Union => return try analyser.resolveUnionTypeConstructor(
                    params,
                    handle,
                    options.container_type,
                ) orelse .unknown_type,
                .Vector => {
                    if (params.len != 2) return null;

                    const child_ty = try analyser.resolveTypeOfNodeInternal(.of(params[1], handle)) orelse return null;
                    if (!child_ty.is_type_val) return null;

                    const child_ty_ip_index = switch (child_ty.data) {
                        .ip_index => |payload| payload.index orelse try analyser.ip.getUnknown(payload.type),
                        else => return null,
                    };

                    const len = try analyser.resolveIntegerLiteral(u32, .of(params[0], handle)) orelse
                        return null; // `InternPool.Key.Vector.len` can't represent unknown length yet

                    const vector_ty_ip_index = try analyser.ip.get(.{
                        .vector_type = .{
                            .len = len,
                            .child = child_ty_ip_index,
                        },
                    });

                    return Type.fromIP(analyser, .type_type, vector_ty_ip_index);
                },
                else => {
                    const data = version_data.builtins.get(call_name) orelse return null;
                    return analyser.resolveLangrefType(data.return_type);
                },
            }
        },
        .fn_proto,
        .fn_proto_multi,
        .fn_proto_one,
        .fn_proto_simple,
        .fn_decl,
        => {
            var buf: [1]Ast.Node.Index = undefined;
            const fn_proto = tree.fullFnProto(&buf, node).?;

            const container_type = options.container_type orelse try analyser.innermostContainer(handle, tree.tokenStart(fn_proto.ast.fn_token));
            const doc_comments = try getDocComments(analyser.arena, tree, node);
            const name = if (fn_proto.name_token) |t| tree.tokenSlice(t) else null;

            var parameters: std.ArrayList(Type.Data.Parameter) = .empty;
            var has_varargs = false;

            var it: ast.FnParamIterator = .init(&fn_proto, tree);
            while (it.next()) |param| {
                if (has_varargs) {
                    return null;
                }

                var param_comments: ?[]const u8 = null;
                if (param.first_doc_comment) |dc| {
                    param_comments = try collectDocComments(analyser.arena, tree, dc, false);
                }

                var param_modifier: ?Type.Data.Parameter.Modifier = null;
                if (param.comptime_noalias) |token_index| {
                    switch (tree.tokenTag(token_index)) {
                        .keyword_comptime => param_modifier = .comptime_param,
                        .keyword_noalias => param_modifier = .noalias_param,
                        else => unreachable,
                    }
                }

                var param_name: ?[]const u8 = null;
                if (param.name_token) |name_token| {
                    param_name = tree.tokenSlice(name_token);
                }

                const param_type: Type = param_type: {
                    if (param.type_expr) |type_expr| blk: {
                        const ty = try analyser.resolveTypeOfNode(.of(type_expr, handle)) orelse {
                            break :blk;
                        };
                        if (!ty.is_type_val) {
                            break :blk;
                        }
                        break :param_type ty;
                    }
                    if (param.anytype_ellipsis3) |token_index| {
                        switch (tree.tokenTag(token_index)) {
                            .keyword_anytype => {
                                break :param_type .{
                                    .data = .{
                                        .anytype_parameter = .{
                                            .token_handle = .{ .token = token_index, .handle = handle },
                                            .type_from_callsite_references = null,
                                        },
                                    },
                                    .is_type_val = true,
                                };
                            },
                            .ellipsis3 => {
                                has_varargs = true;
                                continue;
                            },
                            else => unreachable,
                        }
                    }
                    break :param_type .unknown_type;
                };

                try parameters.append(analyser.arena, .{
                    .doc_comments = param_comments,
                    .modifier = param_modifier,
                    .name = param_name,
                    .name_token = param.name_token,
                    .type = param_type,
                });
            }

            const return_value = try analyser.resolveReturnValueOfFuncNode(handle, node) orelse
                Type.fromIP(analyser, .unknown_type, null);

            const info: Type.Data.Function = .{
                .fn_node = node,
                .handle = handle,
                .fn_token = fn_proto.ast.fn_token,
                .container_type = try analyser.allocType(container_type),
                .doc_comments = doc_comments,
                .name = name,
                .parameters = parameters.items,
                .has_varargs = has_varargs,
                .return_value = try analyser.allocType(return_value),
            };

            // This is a function type
            if (fn_proto.name_token == null) {
                return .{ .data = .{ .function = info }, .is_type_val = true };
            }

            return .{ .data = .{ .function = info }, .is_type_val = false };
        },
        .@"if", .if_simple => {
            const if_node = ast.fullIf(tree, node).?;
            if (analyser.evaluate_comptime_values or
                analyser.evaluate_comptime_control_flow or
                analyser.generic_bindings != null)
            {
                if (try analyser.resolveIfConditionValue(.{
                    .node_handle = .of(if_node.ast.cond_expr, handle),
                    .container_type = options.container_type,
                })) |condition| {
                    const selected = if (condition)
                        if_node.ast.then_expr
                    else
                        if_node.ast.else_expr.unwrap() orelse return Type.fromIP(analyser, .void_type, .void_value);
                    return try analyser.resolveTypeOfNodeInternal(.{
                        .node_handle = .of(selected, handle),
                        .container_type = options.container_type,
                    });
                }
            }

            var either_buffer: [2]Type.TypeWithDescriptor = undefined;
            var either: std.ArrayList(Type.TypeWithDescriptor) = .initBuffer(&either_buffer);

            if (try analyser.resolveTypeOfNodeInternal(.of(if_node.ast.then_expr, handle))) |t| {
                either.appendAssumeCapacity(.{ .type = t, .descriptor = offsets.nodeToSlice(tree, if_node.ast.cond_expr) });
            }
            if (if_node.ast.else_expr.unwrap()) |else_expr| {
                if (try analyser.resolveTypeOfNodeInternal(.of(else_expr, handle))) |t| {
                    either.appendAssumeCapacity(.{ .type = t, .descriptor = try std.fmt.allocPrint(analyser.arena, "!({s})", .{offsets.nodeToSlice(tree, if_node.ast.cond_expr)}) });
                }
            }
            return Type.fromEither(analyser, either.items);
        },
        .@"switch",
        .switch_comma,
        => {
            const switch_node = tree.switchFull(node);

            if ((analyser.evaluate_comptime_values or
                analyser.evaluate_comptime_control_flow or
                analyser.generic_bindings != null) and
                switch_node.label_token == null)
            {
                if (try analyser.resolveKnownSwitchTarget(options)) |target| {
                    return try analyser.resolveTypeOfNodeInternal(.{
                        .node_handle = .of(target, handle),
                        .container_type = options.container_type,
                    });
                }
            }

            var either: std.ArrayList(Type.TypeWithDescriptor) = .empty;

            if (switch_node.label_token) |label_token| {
                var it: BreakIterator = .{
                    .walker = try .init(analyser.gpa, tree, node),
                    .label = offsets.identifierTokenToNameSlice(tree, label_token),
                    .allow_unlabeled = false,
                };
                defer it.walker.deinit(analyser.gpa);
                while (try it.next(analyser, handle, options.container_type)) |value| {
                    const value_type = switch (value) {
                        .operand => |operand| try analyser.resolveTypeOfNodeInternal(.of(operand, handle)) orelse continue,
                        .void => Type.fromIP(analyser, .void_type, .void_value),
                    };
                    {
                        try either.append(analyser.arena, .{
                            .type = value_type,
                            .descriptor = "break",
                        });
                    }
                }
            }

            for (switch_node.ast.cases) |case| {
                const switch_case = tree.fullSwitchCase(case).?;
                var descriptor: std.ArrayList(u8) = .empty;

                for (switch_case.ast.values, 0..) |values, index| {
                    try descriptor.appendSlice(analyser.arena, offsets.nodeToSlice(tree, values));
                    if (index != switch_case.ast.values.len - 1) try descriptor.appendSlice(analyser.arena, ", ");
                }

                if (try analyser.resolveTypeOfNodeInternal(.of(switch_case.ast.target_expr, handle))) |t|
                    try either.append(analyser.arena, .{
                        .type = t,
                        .descriptor = try descriptor.toOwnedSlice(analyser.arena),
                    });
            }

            return Type.fromEither(analyser, either.items);
        },
        .@"while",
        .while_simple,
        .while_cont,
        .@"for",
        .for_simple,
        => {
            const loop: struct {
                label_token: ?Ast.TokenIndex,
                condition_expr: ?Ast.Node.Index,
                inputs: []const Ast.Node.Index,
                then_expr: Ast.Node.Index,
                else_expr: Ast.Node.OptionalIndex,
            } = if (ast.fullWhile(tree, node)) |while_node|
                .{
                    .label_token = while_node.label_token,
                    .condition_expr = while_node.ast.cond_expr,
                    .inputs = &.{},
                    .then_expr = while_node.ast.then_expr,
                    .else_expr = while_node.ast.else_expr,
                }
            else if (ast.fullFor(tree, node)) |for_node|
                .{
                    .label_token = for_node.label_token,
                    .condition_expr = null,
                    .inputs = for_node.ast.inputs,
                    .then_expr = for_node.ast.then_expr,
                    .else_expr = for_node.ast.else_expr,
                }
            else
                unreachable;

            const else_expr = loop.else_expr.unwrap();
            const known_condition = if (loop.condition_expr) |condition_expr|
                try analyser.resolveIfConditionValue(.{
                    .node_handle = .of(condition_expr, handle),
                    .container_type = options.container_type,
                })
            else
                null;
            const known_empty = for (loop.inputs) |input| {
                if (try analyser.isKnownEmptyForInput(input, handle, options.container_type)) break true;
            } else false;
            if (known_condition == false or known_empty) {
                const selected = else_expr orelse return Type.fromIP(analyser, .void_type, .void_value);
                return try analyser.resolveTypeOfNodeInternal(.{
                    .node_handle = .of(selected, handle),
                    .container_type = options.container_type,
                });
            }
            if (known_condition != true and !known_empty and else_expr == null) return null;

            var results: std.ArrayList(Type.TypeWithDescriptor) = .empty;
            if (known_condition != true) {
                if (try analyser.resolveTypeOfNodeInternal(.of(else_expr.?, handle))) |else_type| {
                    try results.append(analyser.arena, .{
                        .type = if (analyser.evaluate_comptime_values) else_type else else_type.withoutIPIndex(analyser),
                        .descriptor = "else",
                    });
                }
            }

            var it: BreakIterator = .{
                .walker = try .init(analyser.gpa, tree, loop.then_expr),
                .label = if (loop.label_token) |token| offsets.identifierTokenToNameSlice(tree, token) else null,
                .allow_unlabeled = true,
            };
            defer it.walker.deinit(analyser.gpa);

            while (try it.next(analyser, handle, options.container_type)) |value| {
                const value_type = switch (value) {
                    .operand => |operand| if (try analyser.resolveTypeOfNodeInternal(.of(operand, handle))) |operand_type|
                        if (analyser.evaluate_comptime_values) operand_type else operand_type.withoutIPIndex(analyser)
                    else
                        continue,
                    .void => Type.fromIP(analyser, .void_type, .void_value),
                };
                try results.append(analyser.arena, .{
                    .type = value_type,
                    .descriptor = "break",
                });
            }
            if (known_condition == true and results.items.len == 0) {
                return Type.fromIP(analyser, .noreturn_type, null);
            }
            return Type.fromEither(analyser, results.items);
        },
        .block,
        .block_semicolon,
        .block_two,
        .block_two_semicolon,
        => {
            var buffer: [2]Ast.Node.Index = undefined;
            const statements = tree.blockStatements(&buffer, node).?;
            if (statements.len == 0) {
                return Type.fromIP(analyser, .void_type, .void_value);
            }

            const label_token = ast.blockLabel(tree, node) orelse {
                const last_statement = statements[statements.len - 1];
                if (try analyser.resolveTypeOfNodeInternal(.of(last_statement, handle))) |ty| {
                    if ((try ty.typeOf(analyser)).isNoreturnType()) {
                        return Type.fromIP(analyser, .noreturn_type, null);
                    }
                }
                return Type.fromIP(analyser, .void_type, .void_value);
            };

            var it: BreakIterator = .{
                .walker = try .init(analyser.gpa, tree, node),
                .label = offsets.identifierTokenToNameSlice(tree, label_token),
                .allow_unlabeled = false,
            };
            defer it.walker.deinit(analyser.gpa);

            var breaks: std.ArrayList(Type.TypeWithDescriptor) = .empty;
            while (try it.next(analyser, handle, options.container_type)) |value| {
                const value_type = switch (value) {
                    .operand => |operand| if (try analyser.resolveTypeOfNodeInternal(.of(operand, handle))) |operand_type|
                        if (analyser.evaluate_comptime_values) operand_type else operand_type.withoutIPIndex(analyser)
                    else
                        continue,
                    .void => Type.fromIP(analyser, .void_type, .void_value),
                };
                try breaks.append(analyser.arena, .{
                    .type = value_type,
                    .descriptor = "break",
                });
            }
            return Type.fromEither(analyser, breaks.items);
        },

        .for_range => {},

        .equal_equal,
        .bang_equal,
        .less_than,
        .greater_than,
        .less_or_equal,
        .greater_or_equal,
        => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            if (analyser.evaluate_comptime_values) {
                var lhs_ty = try analyser.resolveTypeOfNodeInternal(.of(lhs, handle)) orelse return null;
                const complementary_operand = try analyser.complementaryIdentifierOperand(tree, lhs, rhs, .bit_not) orelse
                    try analyser.complementaryIdentifierOperand(tree, lhs, rhs, .bool_not);
                if (complementary_operand) |operand| {
                    const operand_type = try analyser.resolveTypeOfNodeInternal(.of(operand, handle)) orelse return null;
                    if (try analyser.resolveComplementaryComparisonValue(tree.nodeTag(node), operand_type)) |value| return value;
                }
                const same_operand = try analyser.areSameIdentifierExpression(tree, lhs, rhs);
                if (same_operand) {
                    if (try analyser.resolveSelfComparisonValue(tree.nodeTag(node), lhs_ty)) |value| return value;
                    const tag = tree.nodeTag(node);
                    if ((tag == .equal_equal or tag == .bang_equal) and
                        try analyser.isMutableIdentifierExpression(tree, handle, lhs))
                    {
                        const operand_type = try lhs_ty.typeOf(analyser);
                        const reflexive = operand_type.isEnumType() or
                            if (operand_type.ipIndex()) |type_index|
                                analyser.hasReflexiveEquality(type_index)
                            else
                                false;
                        if (reflexive) {
                            return Type.fromIP(
                                analyser,
                                .bool_type,
                                if (tag == .equal_equal) .bool_true else .bool_false,
                            );
                        }
                    }
                }
                var rhs_ty = try analyser.resolveTypeOfNodeInternal(.of(rhs, handle)) orelse return null;
                if (try analyser.resolveVectorComparisonValue(tree.nodeTag(node), lhs_ty, rhs_ty)) |value| {
                    return value;
                }
                if (tree.nodeTag(node) == .equal_equal or tree.nodeTag(node) == .bang_equal) {
                    if (lhs_ty.data == .enum_value and rhs_ty.data != .enum_value) {
                        const enum_type = lhs_ty.data.enum_value.enum_type.*;
                        if (try analyser.resolveEnumValueTag(enum_type, .of(rhs, handle))) |enum_tag| {
                            rhs_ty = try analyser.enumValue(enum_type, enum_tag);
                        }
                    } else if (rhs_ty.data == .enum_value and lhs_ty.data != .enum_value) {
                        const enum_type = rhs_ty.data.enum_value.enum_type.*;
                        if (try analyser.resolveEnumValueTag(enum_type, .of(lhs, handle))) |enum_tag| {
                            lhs_ty = try analyser.enumValue(enum_type, enum_tag);
                        }
                    }
                }
                if (analyser.resolveComparisonValue(tree.nodeTag(node), lhs_ty, rhs_ty)) |value| return value;
            }

            const ty = try analyser.resolveTypeOfNodeInternal(.of(lhs, handle)) orelse
                return Type.fromIP(analyser, .bool_type, null);
            const typeof = try ty.typeOf(analyser);

            if (typeof.ipIndex()) |index| {
                const key = analyser.ip.indexToKey(index);
                if (key == .vector_type) {
                    const vector_ty_ip_index = try analyser.ip.get(.{
                        .vector_type = .{
                            .len = key.vector_type.len,
                            .child = .bool_type,
                        },
                    });

                    return Type.fromIP(analyser, vector_ty_ip_index, null);
                }
            }
            return Type.fromIP(analyser, .bool_type, null);
        },

        .bool_and, .bool_or => |tag| {
            if (analyser.evaluate_comptime_values) {
                const lhs, const rhs = tree.nodeData(node).node_and_node;
                if (try analyser.complementaryIdentifierOperand(tree, lhs, rhs, .bool_not)) |operand| {
                    const operand_type = try analyser.resolveTypeOfNodeInternal(.of(operand, handle)) orelse
                        return Type.fromIP(analyser, .bool_type, null);
                    if (try analyser.resolveComplementaryBinaryValue(tag, operand_type)) |value| return value;
                }
                const lhs_type = try analyser.resolveTypeOfNodeInternal(.of(lhs, handle)) orelse
                    return Type.fromIP(analyser, .bool_type, null);
                const lhs_index = lhs_type.ipIndex();
                if (lhs_index) |index| {
                    if (analyser.ip.isUndefined(index)) return Type.fromIP(analyser, .bool_type, null);
                    switch (tag) {
                        .bool_and => if (index == .bool_false) return Type.fromIP(analyser, .bool_type, .bool_false),
                        .bool_or => if (index == .bool_true) return Type.fromIP(analyser, .bool_type, .bool_true),
                        else => unreachable,
                    }
                }

                const rhs_type = try analyser.resolveTypeOfNodeInternal(.of(rhs, handle)) orelse
                    return Type.fromIP(analyser, .bool_type, null);
                const rhs_index = rhs_type.ipIndex() orelse return Type.fromIP(analyser, .bool_type, null);
                if (analyser.ip.isUndefined(rhs_index)) return Type.fromIP(analyser, .bool_type, null);
                if (lhs_index == .bool_true or lhs_index == .bool_false) {
                    return switch (rhs_index) {
                        .bool_true, .bool_false => Type.fromIP(analyser, .bool_type, rhs_index),
                        else => Type.fromIP(analyser, .bool_type, null),
                    };
                }
                return switch (tag) {
                    .bool_and => if (rhs_index == .bool_false)
                        Type.fromIP(analyser, .bool_type, .bool_false)
                    else
                        Type.fromIP(analyser, .bool_type, null),
                    .bool_or => if (rhs_index == .bool_true)
                        Type.fromIP(analyser, .bool_type, .bool_true)
                    else
                        Type.fromIP(analyser, .bool_type, null),
                    else => unreachable,
                };
            }
            return Type.fromIP(analyser, .bool_type, null);
        },
        .bool_not => {
            const operand = tree.nodeData(node).node;
            const operand_type = try analyser.resolveTypeOfNodeInternal(.of(operand, handle)) orelse
                return Type.fromIP(analyser, .bool_type, null);
            if (try analyser.resolveVectorBoolNotValue(operand_type)) |value| {
                return if (analyser.evaluate_comptime_values) value else value.withoutIPIndex(analyser);
            }
            if (analyser.evaluate_comptime_values) {
                const value = try analyser.resolveBoolValue(.of(operand, handle)) orelse return Type.fromIP(analyser, .bool_type, null);
                return Type.fromIP(analyser, .bool_type, if (value) .bool_false else .bool_true);
            }
            return Type.fromIP(analyser, .bool_type, null);
        },

        .bit_not => {
            const ty = try analyser.resolveTypeOfNodeInternal(.of(tree.nodeData(node).node, handle)) orelse return null;
            if (ty.is_type_val) return null;
            if (analyser.evaluate_comptime_values) {
                if (ty.ipIndex()) |index| {
                    if (analyser.ip.zigTypeTag(analyser.ip.typeOf(index)) == .vector) {
                        if (try analyser.resolveVectorUnaryValue(.bit_not, ty)) |value| return value;
                    } else if (try analyser.resolveBitNotValue(ty)) |value| {
                        return value;
                    }
                }
            }
            return ty.withoutIPIndex(analyser);
        },
        .negation, .negation_wrap => |tag| {
            const ty = try analyser.resolveTypeOfNodeInternal(.of(tree.nodeData(node).node, handle)) orelse return null;
            if (ty.is_type_val) return null;
            if (analyser.evaluate_comptime_values) {
                if (ty.ipIndex()) |index| {
                    if (analyser.ip.zigTypeTag(analyser.ip.typeOf(index)) == .vector) {
                        const operation: VectorUnaryOperation = if (tag == .negation_wrap) .negate_wrap else .negate;
                        if (try analyser.resolveVectorUnaryValue(operation, ty)) |value| return value;
                    } else if (try analyser.resolveNegationValue(ty, tag == .negation_wrap)) |value| {
                        return value;
                    }
                }
            }
            return ty.withoutIPIndex(analyser);
        },

        .multiline_string_literal => {
            const start, const end = tree.nodeData(node).token_and_token;

            var length: u64 = 0;

            for (start..end + 1, 0..) |token_index, i| {
                const slice = tree.tokenSlice(@intCast(token_index));
                length += slice.len - 2 + @intFromBool(i != 0);
            }

            if (analyser.evaluate_comptime_values) {
                const bytes = try analyser.arena.alloc(u8, length);
                var offset: usize = 0;
                for (start..end + 1, 0..) |token_index, i| {
                    const slice = tree.tokenSlice(@intCast(token_index))[2..];
                    if (i != 0) {
                        bytes[offset] = '\n';
                        offset += 1;
                    }
                    @memcpy(bytes[offset..][0..slice.len], slice);
                    offset += slice.len;
                }
                std.debug.assert(offset == bytes.len);
                return try analyser.stringValue(bytes);
            }
            return try analyser.staticStringType(length);
        },
        .string_literal => {
            const token_bytes = tree.tokenSlice(tree.nodeMainToken(node));

            var discarding_writer: std.Io.Writer.Discarding = .init(&.{});
            const result = std.zig.string_literal.parseWrite(&discarding_writer.writer, token_bytes) catch |err| switch (err) {
                error.WriteFailed => unreachable,
            };
            switch (result) {
                .success => {},
                .failure => return null,
            }

            if (analyser.evaluate_comptime_values) {
                const decoded = try analyser.arena.alloc(u8, discarding_writer.count);
                var writer: std.Io.Writer = .fixed(decoded);
                const parsed = std.zig.string_literal.parseWrite(&writer, token_bytes) catch |err| switch (err) {
                    error.WriteFailed => unreachable,
                };
                if (parsed != .success) return null;
                return try analyser.stringValue(decoded);
            }
            return try analyser.staticStringType(discarding_writer.count);
        },
        .error_value => {
            const name_token = tree.nodeMainToken(node) + 2;
            if (tree.tokenTag(name_token) != .identifier) return null;
            const name = offsets.identifierTokenToNameSlice(tree, name_token);
            const name_index = try analyser.ip.string_pool.getOrPutString(analyser.store.io, analyser.gpa, name);

            const error_set_type = try analyser.ip.get(.{ .error_set_type = .{
                .owner_decl = .none,
                .names = try analyser.ip.getStringSlice(&.{name_index}),
            } });
            const error_value = try analyser.ip.get(.{ .error_value = .{
                .ty = error_set_type,
                .error_tag_name = name_index,
            } });
            return Type.fromIP(analyser, error_set_type, error_value);
        },

        .char_literal => {
            if (!analyser.resolve_number_literal_values) {
                return Type.fromIP(analyser, .comptime_int_type, null);
            }
            const bytes = offsets.tokenToSlice(tree, tree.nodeMainToken(node));
            const value = switch (std.zig.parseCharLiteral(bytes)) {
                .success => |codepoint| codepoint,
                .failure => return Type.fromIP(analyser, .comptime_int_type, null),
            };
            const index = try analyser.ip.get(.{
                .int_u64_value = .{ .ty = .comptime_int_type, .int = value },
            });
            return Type.fromIP(analyser, .comptime_int_type, index);
        },

        .number_literal => {
            const bytes = offsets.tokenToSlice(tree, tree.nodeMainToken(node));
            const result = std.zig.parseNumberLiteral(bytes);
            const ty: InternPool.Index = switch (result) {
                .int,
                .big_int,
                => .comptime_int_type,
                .float => .comptime_float_type,
                .failure => return null,
            };
            if (!analyser.resolve_number_literal_values) {
                return Type.fromIP(analyser, ty, null);
            }
            const value: ?InternPool.Index = switch (result) {
                .float => blk: {
                    break :blk try analyser.ip.get(
                        .{ .float_comptime_value = std.fmt.parseFloat(f128, bytes) catch break :blk null },
                    );
                },
                .int => blk: {
                    break :blk if (bytes[0] == '-')
                        try analyser.ip.get(
                            .{ .int_i64_value = .{ .ty = ty, .int = std.fmt.parseInt(i64, bytes, 0) catch break :blk null } },
                        )
                    else
                        try analyser.ip.get(
                            .{ .int_u64_value = .{ .ty = ty, .int = std.fmt.parseInt(u64, bytes, 0) catch break :blk null } },
                        );
                },
                .big_int => |base| blk: {
                    var big_int: std.math.big.int.Managed = try .init(analyser.gpa);
                    defer big_int.deinit();
                    const prefix_length: usize = if (base != .decimal) 2 else 0;
                    big_int.setString(@intFromEnum(base), bytes[prefix_length..]) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => break :blk null,
                    };
                    std.debug.assert(ty == .comptime_int_type);
                    break :blk try analyser.ip.getBigInt(ty, big_int.toConst());
                },
                .failure => unreachable, // checked above
            };

            return if (value) |v| Type.fromIP(analyser, ty, v) else Type.fromIP(analyser, ty, null);
        },

        .enum_literal => {
            const source_token = tree.tokenStart(tree.nodeMainToken(node));
            const lineage = try ast.nodesOverlappingIndex(analyser.arena, tree, source_token);
            defer analyser.arena.free(lineage);

            const tag = offsets.identifierTokenToNameSlice(tree, tree.nodeMainToken(node));
            const decl = (try analyser.lookupSymbolFieldInit(handle, tag, node, lineage[1..])) orelse return Type.fromIP(analyser, .enum_literal_type, null);
            return decl.resolveType(analyser);
        },

        .unreachable_literal => return Type.fromIP(analyser, .noreturn_type, null),
        .anyframe_literal => return Type.fromIP(analyser, .anyframe_type, null),

        .anyframe_type => return .unknown_type,

        .mul,
        .div,
        .mod,
        .mul_wrap,
        .mul_sat,
        .add_wrap,
        .sub_wrap,
        .add_sat,
        .sub_sat,
        .bit_and,
        .bit_xor,
        .bit_or,
        => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            var lhs_ty = try analyser.resolveTypeOfNodeInternal(.of(lhs, handle)) orelse return null;
            if (lhs_ty.is_type_val) return null;
            var rhs_ty = try analyser.resolveTypeOfNodeInternal(.of(rhs, handle)) orelse return null;
            if (rhs_ty.is_type_val) return null;
            if (analyser.evaluate_comptime_values) {
                const tag = tree.nodeTag(node);
                const complementary_operand = try analyser.complementaryIdentifierOperand(tree, lhs, rhs, .bit_not) orelse
                    try analyser.complementaryIdentifierOperand(tree, lhs, rhs, .bool_not);
                if (complementary_operand) |operand| {
                    const operand_type = try analyser.resolveTypeOfNodeInternal(.of(operand, handle)) orelse return null;
                    if (try analyser.resolveComplementaryBinaryValue(tag, operand_type)) |value| return value;
                }
                if ((tag == .bit_xor or tag == .sub_wrap or tag == .sub_sat) and
                    try analyser.areSameIdentifierExpression(tree, lhs, rhs))
                {
                    if (try analyser.resolveSelfBinaryValue(tag, lhs_ty)) |value| return value;
                }
                const value = switch (tree.nodeTag(node)) {
                    .mul_wrap, .mul_sat, .add_wrap, .sub_wrap, .add_sat, .sub_sat => try analyser.resolveFixedWidthIntegerBinaryValue(tree.nodeTag(node), lhs_ty, rhs_ty, null) orelse
                        try analyser.resolveVectorFixedWidthIntegerBinaryValue(tree.nodeTag(node), lhs_ty, rhs_ty, null),
                    else => try analyser.resolveIntegerBinaryValue(tree.nodeTag(node), lhs_ty, rhs_ty) orelse
                        try analyser.resolveFloatBinaryValue(tree.nodeTag(node), lhs_ty, rhs_ty) orelse
                        analyser.resolveBoolBinaryValue(tree.nodeTag(node), lhs_ty, rhs_ty) orelse
                        try analyser.resolveVectorBoolBinaryValue(tree.nodeTag(node), lhs_ty, rhs_ty) orelse
                        try analyser.resolveVectorBinaryValue(tree.nodeTag(node), lhs_ty, rhs_ty),
                };
                if (value) |resolved| return resolved;
            }
            lhs_ty = lhs_ty.withoutIPIndex(analyser);
            rhs_ty = rhs_ty.withoutIPIndex(analyser);
            return analyser.resolvePeerTypes(lhs_ty, rhs_ty);
        },

        .add => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            var lhs_ty = try analyser.resolveTypeOfNodeInternal(.of(lhs, handle)) orelse return null;
            if (lhs_ty.is_type_val) return null;
            var rhs_ty = try analyser.resolveTypeOfNodeInternal(.of(rhs, handle)) orelse return null;
            if (rhs_ty.is_type_val) return null;
            if (analyser.evaluate_comptime_values) {
                if (try analyser.complementaryIdentifierOperand(tree, lhs, rhs, .bit_not)) |operand| {
                    const operand_type = try analyser.resolveTypeOfNodeInternal(.of(operand, handle)) orelse return null;
                    if (try analyser.resolveComplementaryBinaryValue(.add, operand_type)) |value| return value;
                }
                if (try analyser.resolveIntegerBinaryValue(.add, lhs_ty, rhs_ty) orelse
                    try analyser.resolveFloatBinaryValue(.add, lhs_ty, rhs_ty) orelse
                    try analyser.resolveVectorBinaryValue(.add, lhs_ty, rhs_ty)) |value| return value;
            }
            lhs_ty = lhs_ty.withoutIPIndex(analyser);
            rhs_ty = rhs_ty.withoutIPIndex(analyser);
            if (lhs_ty.pointerSize(analyser)) |lhs_size| {
                return switch (lhs_size) {
                    .many, .c => lhs_ty,
                    else => null,
                };
            }
            return try analyser.resolvePeerTypes(lhs_ty, rhs_ty);
        },

        .sub => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            var lhs_ty = try analyser.resolveTypeOfNodeInternal(.of(lhs, handle)) orelse return null;
            if (lhs_ty.is_type_val) return null;
            var rhs_ty = try analyser.resolveTypeOfNodeInternal(.of(rhs, handle)) orelse return null;
            if (rhs_ty.is_type_val) return null;
            if (analyser.evaluate_comptime_values) {
                if (try analyser.areSameIdentifierExpression(tree, lhs, rhs)) {
                    if (try analyser.resolveSelfBinaryValue(.sub, lhs_ty)) |value| return value;
                }
                if (try analyser.resolveIntegerBinaryValue(.sub, lhs_ty, rhs_ty) orelse
                    try analyser.resolveFloatBinaryValue(.sub, lhs_ty, rhs_ty) orelse
                    try analyser.resolveVectorBinaryValue(.sub, lhs_ty, rhs_ty)) |value| return value;
            }
            lhs_ty = lhs_ty.withoutIPIndex(analyser);
            rhs_ty = rhs_ty.withoutIPIndex(analyser);
            if (lhs_ty.pointerSize(analyser)) |lhs_size| {
                if (rhs_ty.pointerSize(analyser)) |rhs_size| {
                    if (lhs_size == .slice) return null;
                    if (rhs_size == .slice) return null;
                    return Type.fromIP(analyser, .usize_type, null);
                } else {
                    return switch (lhs_size) {
                        .many, .c => lhs_ty,
                        else => null,
                    };
                }
            }
            return try analyser.resolvePeerTypes(lhs_ty, rhs_ty);
        },

        .shl,
        .shl_sat,
        .shr,
        => |tag| {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            const lhs_ty = try analyser.resolveTypeOfNodeInternal(.of(lhs, handle)) orelse return null;
            if (lhs_ty.is_type_val) return null;
            if (analyser.evaluate_comptime_values) {
                const rhs_ty = try analyser.resolveTypeOfNodeInternal(.of(rhs, handle)) orelse return null;
                if (!rhs_ty.is_type_val) {
                    const value = if (tag == .shl_sat)
                        try analyser.resolveFixedWidthIntegerBinaryValue(tag, lhs_ty, rhs_ty, (try lhs_ty.typeOf(analyser)).ipIndex()) orelse
                            try analyser.resolveVectorFixedWidthIntegerBinaryValue(tag, lhs_ty, rhs_ty, (try lhs_ty.typeOf(analyser)).ipIndex())
                    else
                        try analyser.resolveIntegerBinaryValue(tag, lhs_ty, rhs_ty) orelse
                            try analyser.resolveVectorShiftValue(if (tag == .shl) .shl else .shr, lhs_ty, rhs_ty);
                    if (value) |resolved| return resolved;
                }
            }
            return lhs_ty.withoutIPIndex(analyser);
        },

        .array_mult => {
            const elem_idx, const mult_idx = tree.nodeData(node).node_and_node;

            const elem_ty = try analyser.resolveTypeOfNodeInternal(.of(elem_idx, handle)) orelse return null;
            if (elem_ty.is_type_val) return null;

            const mult_lit = try analyser.resolveIntegerLiteral(u64, .of(mult_idx, handle));
            const result = try analyser.resolveArrayMultExpression(elem_ty, mult_lit) orelse return null;
            if (analyser.evaluate_comptime_values and
                elem_ty.data == .string_value and
                mult_lit != null)
            {
                const source = elem_ty.data.string_value.bytes;
                const multiplier = std.math.cast(usize, mult_lit.?) orelse return null;
                const len = std.math.mul(usize, source.len, multiplier) catch return null;
                const bytes = try analyser.arena.alloc(u8, len);
                for (0..multiplier) |i| {
                    const offset = i * source.len;
                    @memcpy(bytes[offset..][0..source.len], source);
                }
                return try analyser.stringValueWithType(bytes, try result.typeOf(analyser));
            }
            if (analyser.evaluate_comptime_values and mult_lit != null) {
                if (analyser.aggregateValues(elem_ty)) |source_values| {
                    const source = try source_values.dupe(analyser.gpa, analyser.ip);
                    defer analyser.gpa.free(source);
                    const multiplier = std.math.cast(usize, mult_lit.?) orelse return result;
                    const len = std.math.mul(usize, source.len, multiplier) catch return result;
                    const values = try analyser.gpa.alloc(InternPool.Index, len);
                    defer analyser.gpa.free(values);
                    for (0..multiplier) |i| {
                        @memcpy(values[i * source.len ..][0..source.len], source);
                    }
                    return try analyser.aggregateValue(result, values) orelse result;
                }
            }
            return result;
        },
        .array_cat => {
            const l_elem_idx, const r_elem_idx = tree.nodeData(node).node_and_node;

            const l_elem_ty = try analyser.resolveTypeOfNodeInternal(.of(l_elem_idx, handle)) orelse return null;
            if (l_elem_ty.is_type_val) return null;

            const r_elem_ty = try analyser.resolveTypeOfNodeInternal(.of(r_elem_idx, handle)) orelse return null;
            if (r_elem_ty.is_type_val) return null;

            const result = try analyser.resolveArrayCatExpression(l_elem_ty, r_elem_ty) orelse return null;
            if (analyser.evaluate_comptime_values and
                l_elem_ty.data == .string_value and
                r_elem_ty.data == .string_value)
            {
                const bytes = try std.mem.concat(analyser.arena, u8, &.{
                    l_elem_ty.data.string_value.bytes,
                    r_elem_ty.data.string_value.bytes,
                });
                return try analyser.stringValueWithType(bytes, try result.typeOf(analyser));
            }
            if (analyser.evaluate_comptime_values) {
                const lhs_values = analyser.aggregateValues(l_elem_ty);
                const rhs_values = analyser.aggregateValues(r_elem_ty);
                const result_payload = switch (result.data) {
                    .ip_index => |payload| payload,
                    else => return result,
                };
                const result_array = switch (analyser.ip.indexToKey(result_payload.type)) {
                    .array_type => |array| array,
                    else => return result,
                };
                const lhs_len = std.math.cast(usize, (l_elem_ty.arrayInfo(analyser) orelse return result)[0] orelse return result) orelse return result;
                const rhs_len = std.math.cast(usize, (r_elem_ty.arrayInfo(analyser) orelse return result)[0] orelse return result) orelse return result;
                const value_len = std.math.add(usize, lhs_len, rhs_len) catch return result;
                if (value_len != result_array.len or
                    (lhs_values != null and lhs_values.?.len != lhs_len) or
                    (rhs_values != null and rhs_values.?.len != rhs_len)) return result;

                const values = try analyser.gpa.alloc(InternPool.Index, result_array.len);
                defer analyser.gpa.free(values);
                const unknown = try analyser.ip.getUnknown(result_array.child);
                if (lhs_values) |source| {
                    for (values[0..lhs_len], 0..) |*value, i| {
                        value.* = try analyser.coerceArrayElementValue(
                            result_array.child,
                            source.at(@intCast(i), analyser.ip),
                        ) orelse unknown;
                    }
                } else {
                    @memset(values[0..lhs_len], unknown);
                }
                if (rhs_values) |source| {
                    for (values[lhs_len..], 0..) |*value, i| {
                        value.* = try analyser.coerceArrayElementValue(
                            result_array.child,
                            source.at(@intCast(i), analyser.ip),
                        ) orelse unknown;
                    }
                } else {
                    @memset(values[lhs_len..], unknown);
                }
                return try analyser.aggregateValue(result, values) orelse result;
            }
            return result;
        },

        .assign_mul,
        .assign_div,
        .assign_mod,
        .assign_add,
        .assign_sub,
        .assign_shl,
        .assign_shl_sat,
        .assign_shr,
        .assign_bit_and,
        .assign_bit_xor,
        .assign_bit_or,
        .assign_mul_wrap,
        .assign_add_wrap,
        .assign_sub_wrap,
        .assign_mul_sat,
        .assign_add_sat,
        .assign_sub_sat,
        .assign,
        .assign_destructure,
        => {},

        .struct_init_dot_two,
        .struct_init_dot_two_comma,
        .struct_init_dot,
        .struct_init_dot_comma,
        => {},

        .root,
        .test_decl,
        .@"errdefer",
        .@"defer",
        .switch_case_one,
        .switch_case_inline_one,
        .switch_case,
        .switch_case_inline,
        .switch_range,
        => {},
        .@"continue",
        .@"break",
        .@"return",
        => {
            return Type.fromIP(analyser, .noreturn_type, null);
        },

        .@"suspend",
        .@"resume",
        => {},

        .asm_simple,
        .@"asm",
        .asm_output,
        .asm_input,
        => {},

        .identifier,
        .address_of,
        .field_access,
        .slice,
        .slice_sentinel,
        .slice_open,
        .array_access,
        .deref,
        => {
            const binding = try analyser.resolveBindingOfNodeUncached(options) orelse return null;
            return binding.type;
        },
    }
    return null;
}

fn resolveBindingOfNodeUncached(analyser: *Analyser, options: ResolveOptions) Error!?Binding {
    const node_handle = options.node_handle;
    const node = node_handle.node;
    const handle = node_handle.handle;
    const tree = &handle.tree;

    switch (tree.nodeTag(node)) {
        .identifier => {
            const name_token = ast.identifierTokenFromIdentifierNode(tree, node) orelse return null;
            const name = offsets.identifierTokenToNameSlice(tree, name_token);

            const is_escaped_identifier = tree.source[tree.tokenStart(name_token)] == '@';
            if (!is_escaped_identifier) {
                if (std.mem.eql(u8, name, "_")) return null;
                if (try analyser.resolvePrimitive(name)) |primitive| {
                    return .{
                        .type = Type.fromIP(analyser, analyser.ip.typeOf(primitive), primitive),
                        .is_const = true,
                    };
                }
            }

            const child = try analyser.lookupSymbolGlobal(handle, name, tree.tokenStart(name_token)) orelse return null;
            const token_handle: TokenWithHandle = .{
                .token = child.nameToken(),
                .handle = child.handle,
            };
            if (analyser.generic_bindings) |bindings| {
                if (bindings.get(token_handle)) |bound| {
                    return .{ .type = bound, .is_const = true };
                }
            }
            if (options.container_type) |container_type| {
                if (container_type.data == .container) {
                    if (container_type.data.container.bound_params.get(token_handle)) |bound| {
                        return .{ .type = bound, .is_const = true };
                    }
                }
            }
            const child_ty = try child.resolveType(analyser) orelse return null;
            return .{
                .type = child_ty,
                .is_const = child.isConst(),
            };
        },

        .address_of => {
            const expr_node = tree.nodeData(node).node;

            const base_binding = try analyser.resolveBindingOfNodeInternal(.of(expr_node, handle)) orelse return null;

            return .{
                .type = try analyser.resolveAddressOf(base_binding.is_const, base_binding.type),
                .is_const = true,
            };
        },

        .field_access => {
            const lhs_node, const field_name = tree.nodeData(node_handle.node).node_and_token;

            const lhs = (try analyser.resolveBindingOfNodeInternal(.of(lhs_node, handle))) orelse return null;

            const symbol = try analyser.identifierTokenName(tree, field_name) orelse return null;
            if (analyser.evaluate_comptime_values and
                lhs.type.is_type_val and
                lhs.type.isEnumType())
            {
                const decl = try lhs.type.lookupSymbol(analyser, symbol);
                if (decl != null and
                    decl.?.decl == .ast_node and
                    decl.?.handle.tree.nodeTag(decl.?.decl.ast_node).isContainerField())
                {
                    return .{
                        .type = try analyser.enumValue(lhs.type, symbol),
                        .is_const = true,
                    };
                }
            }

            return try analyser.resolveFieldAccessBinding(lhs, symbol);
        },

        .slice,
        .slice_sentinel,
        .slice_open,
        => {
            const slice = tree.fullSlice(node).?;

            const sliced = try analyser.resolveBindingOfNodeInternal(.of(slice.ast.sliced, handle)) orelse return null;

            const kind: BracketAccess = try .fromSlice(analyser, handle, slice);

            return try analyser.resolveBracketAccess(sliced, kind);
        },

        .array_access => {
            const lhs_node, const rhs_node = tree.nodeData(node).node_and_node;

            const lhs = try analyser.resolveBindingOfNodeInternal(.of(lhs_node, handle)) orelse return null;

            const index = try analyser.resolveIntegerLiteral(u64, .of(rhs_node, handle));

            return try analyser.resolveBracketAccess(lhs, .{ .single = index });
        },

        .deref => {
            const expr_node = tree.nodeData(node).node;

            const base_type = try analyser.resolveTypeOfNodeInternal(.of(expr_node, handle)) orelse return null;

            return try analyser.resolveDerefBinding(base_type);
        },

        else => return .{
            .type = try analyser.resolveTypeOfNodeUncached(options) orelse return null,
            .is_const = true,
        },
    }
}

pub const ResolveOptions = struct {
    node_handle: NodeWithHandle,
    container_type: ?Type,

    pub fn of(node: Ast.Node.Index, handle: *DocumentStore.Handle) ResolveOptions {
        return .{
            .node_handle = .of(node, handle),
            .container_type = null,
        };
    }
};

pub const Binding = struct {
    type: Type,
    is_const: bool,
};

/// Represents a resolved Zig type.
/// This is the return type of `resolveTypeOfNode`.
pub const Type = struct {
    data: Data,
    /// If true, the type `type`, the attached data is the value of the type value.
    /// ```zig
    /// const foo = u32; // is_type_val == true
    /// const bar = @as(u32, ...); // is_type_val == false
    /// ```
    /// if `data == .ip_index` then this field is equivalent to `data.ip_index.type == .type_type`
    is_type_val: bool,

    pub const Data = union(enum) {
        /// - `*const T`
        /// - `[*]T`
        /// - `[]const T`
        /// - `[*c]T`
        pointer: struct {
            size: std.builtin.Type.Pointer.Size,
            /// `.none` means no sentinel, `.unknown_unknown` means unknown sentinel
            sentinel: InternPool.Index,
            is_const: bool,
            elem_ty: *Type,
        },

        /// `[elem_count :sentinel]elem_ty`
        array: struct {
            elem_count: ?u64,
            /// `.none` means no sentinel, `.unknown_unknown` means unknown sentinel
            sentinel: InternPool.Index,
            elem_ty: *Type,
        },

        /// `.{a,b}`
        tuple: []Type,

        /// `?T`
        optional: *Type,

        /// `error_set!payload`
        error_union: struct {
            /// `null` if inferred error
            error_set: ?*Type,
            payload: *Type,
        },

        /// `Foo` in `Foo.bar` where `Foo = union(enum) { bar }`
        union_tag: *Type,

        /// - `struct {}`
        /// - `enum {}`
        /// - `union {}`
        /// - `opaque {}`
        container: Container,

        /// - Function: `fn () Foo`, `fn foo() Foo`
        function: Function,

        /// - `@compileError("")`
        compile_error: NodeWithHandle,

        /// `T` in `fn Foo(comptime T: type) type`
        type_parameter: TokenWithHandle,

        /// A caller-dependent type, such as `anytype` in
        /// `fn foo(bar: anytype) @TypeOf(bar)`.
        anytype_parameter: struct {
            token_handle: TokenWithHandle,
            type_from_callsite_references: ?*Type,
        },

        /// Branching types
        either: []const EitherEntry,

        /// A comptime-known value of an AST-backed enum type.
        enum_value: struct {
            enum_type: *Type,
            tag: []const u8,
            int_value: ?InternPool.Index,
        },

        /// A comptime-known string and its pointer-to-array type.
        string_value: struct {
            string_type: *Type,
            bytes: []const u8,
        },

        /// Primitive type: `u8`, `bool`, `type`, etc.
        /// Primitive value: `true`, `false`, `null`, `undefined`
        ip_index: struct {
            type: InternPool.Index,
            index: ?InternPool.Index,
        },

        pub const Container = struct {
            scope_handle: ScopeWithHandle,
            bound_params: TokenToTypeMap,

            pub fn root(handle: *DocumentStore.Handle) Container {
                return .{
                    .scope_handle = .{ .handle = handle, .scope = .root },
                    .bound_params = .empty,
                };
            }
        };

        pub const Function = struct {
            fn_node: Ast.Node.Index,
            fn_token: Ast.TokenIndex,
            handle: *DocumentStore.Handle,

            container_type: *Type,
            doc_comments: ?[]const u8,
            name: ?[]const u8,
            parameters: []Parameter,
            has_varargs: bool,
            return_value: *Type,
        };

        pub const Parameter = struct {
            doc_comments: ?[]const u8,
            modifier: ?Modifier,
            name: ?[]const u8,
            name_token: ?Ast.TokenIndex,
            type: Type,

            pub const Modifier = enum {
                comptime_param,
                noalias_param,
            };
        };

        pub const EitherEntry = struct {
            /// the `is_type_val` property is inherited from the containing `Type`
            type_data: Data,
            descriptor: []const u8,
        };

        fn createPointer(
            analyser: *Analyser,
            size: std.builtin.Type.Pointer.Size,
            sentinel: InternPool.Index,
            is_const: bool,
            elem_ty: Type,
        ) !Data {
            std.debug.assert(elem_ty.is_type_val);
            blk: {
                const elem_type = elem_ty.ipIndex() orelse break :blk;
                const index = try analyser.ip.get(.{
                    .pointer_type = .{
                        .elem_type = elem_type,
                        .sentinel = try analyser.coerceIP(elem_type, sentinel) orelse break :blk,
                        .flags = .{
                            .size = size,
                            .is_const = is_const,
                        },
                    },
                });
                return .{ .ip_index = .{ .type = .type_type, .index = index } };
            }
            return .{
                .pointer = .{
                    .size = size,
                    .sentinel = sentinel,
                    .is_const = is_const,
                    .elem_ty = try analyser.allocType(elem_ty),
                },
            };
        }

        fn createArray(
            analyser: *Analyser,
            elem_count: ?u64,
            sentinel: InternPool.Index,
            elem_ty: Type,
        ) !Data {
            std.debug.assert(elem_ty.is_type_val);
            blk: {
                const len = elem_count orelse break :blk;
                const child = elem_ty.ipIndex() orelse break :blk;
                const index = try analyser.ip.get(.{
                    .array_type = .{
                        .len = len,
                        .child = child,
                        .sentinel = try analyser.coerceIP(child, sentinel) orelse break :blk,
                    },
                });
                return .{ .ip_index = .{ .type = .type_type, .index = index } };
            }
            return .{
                .array = .{
                    .elem_count = elem_count,
                    .sentinel = sentinel,
                    .elem_ty = try analyser.allocType(elem_ty),
                },
            };
        }

        fn createTuple(analyser: *Analyser, elem_tys: []Type) !Data {
            const tys = try analyser.gpa.alloc(InternPool.Index, elem_tys.len);
            defer analyser.gpa.free(tys);

            const vals = try analyser.gpa.alloc(InternPool.Index, elem_tys.len);
            defer analyser.gpa.free(vals);

            for (tys, vals, elem_tys) |*ty, *val, elem_ty| {
                ty.* = elem_ty.ipIndex() orelse break;
                val.* = .none;
            } else {
                const types = try analyser.ip.getIndexSlice(tys);
                const values = try analyser.ip.getIndexSlice(vals);
                const index = try analyser.ip.get(.{ .tuple_type = .{ .types = types, .values = values } });
                return .{ .ip_index = .{ .type = .type_type, .index = index } };
            }

            return .{ .tuple = elem_tys };
        }

        fn createTupleValue(analyser: *Analyser, elements: []Type) !?Type {
            const types = try analyser.gpa.alloc(InternPool.Index, elements.len);
            defer analyser.gpa.free(types);
            const values = try analyser.gpa.alloc(InternPool.Index, elements.len);
            defer analyser.gpa.free(values);

            for (elements, types, values) |element, *ty, *value| {
                ty.* = (try element.typeOf(analyser)).ipIndex() orelse return null;
                value.* = element.ipIndex() orelse .none;
                if (value.* != .none and
                    (analyser.ip.isUndefined(value.*) or analyser.ip.isUnknown(value.*)))
                {
                    value.* = .none;
                }
            }

            const tuple_type = try analyser.ip.get(.{ .tuple_type = .{
                .types = try analyser.ip.getIndexSlice(types),
                .values = try analyser.ip.getIndexSlice(values),
            } });
            return Type.fromIP(analyser, tuple_type, null);
        }

        fn createOptional(analyser: *Analyser, child_ty: Type) !Data {
            std.debug.assert(child_ty.is_type_val);
            if (child_ty.ipIndex()) |payload_type| {
                const index = try analyser.ip.get(.{ .optional_type = .{ .payload_type = payload_type } });
                return .{ .ip_index = .{ .type = .type_type, .index = index } };
            }
            return .{ .optional = try analyser.allocType(child_ty) };
        }

        fn createErrorUnion(
            analyser: *Analyser,
            error_set: ?Type,
            payload: Type,
        ) !Data {
            std.debug.assert(error_set == null or error_set.?.is_type_val);
            std.debug.assert(payload.is_type_val);
            blk: {
                const error_set_type: InternPool.Index =
                    if (error_set) |e|
                        e.ipIndex() orelse break :blk
                    else
                        .none;
                const payload_type = payload.ipIndex() orelse break :blk;
                const index = try analyser.ip.get(.{
                    .error_union_type = .{
                        .error_set_type = error_set_type,
                        .payload_type = payload_type,
                    },
                });
                return .{ .ip_index = .{ .type = .type_type, .index = index } };
            }
            return .{
                .error_union = .{
                    .error_set = if (error_set) |e| try analyser.allocType(e) else null,
                    .payload = try analyser.allocType(payload),
                },
            };
        }

        pub fn hashWithHasher(data: Data, hasher: anytype) void {
            hasher.update(&.{@intFromEnum(data)});
            switch (data) {
                .pointer => |info| {
                    std.hash.autoHash(hasher, info.size);
                    std.hash.autoHash(hasher, info.sentinel);
                    std.hash.autoHash(hasher, info.is_const);
                    info.elem_ty.hashWithHasher(hasher);
                },
                .array => |info| {
                    std.hash.autoHash(hasher, info.elem_count);
                    std.hash.autoHash(hasher, info.sentinel);
                    info.elem_ty.hashWithHasher(hasher);
                },
                .tuple => |elem_ty_slice| {
                    for (elem_ty_slice) |elem_ty| {
                        elem_ty.hashWithHasher(hasher);
                    }
                },
                .optional, .union_tag => |t| t.hashWithHasher(hasher),
                .error_union => |info| {
                    if (info.error_set) |error_set| {
                        error_set.hashWithHasher(hasher);
                    }
                    info.payload.hashWithHasher(hasher);
                },
                .container => |info| {
                    info.scope_handle.hashWithHasher(hasher);
                    for (info.bound_params.keys(), info.bound_params.values()) |token_handle, ty| {
                        token_handle.hashWithHasher(hasher);
                        ty.hashWithHasher(hasher);
                    }
                },
                .function => |info| {
                    std.hash.autoHash(hasher, info.fn_node);
                    std.hash.autoHash(hasher, info.fn_token);
                    hasher.update(info.handle.uri.raw);
                    info.container_type.hashWithHasher(hasher);
                    for (info.parameters) |param| {
                        param.type.hashWithHasher(hasher);
                    }
                    info.return_value.hashWithHasher(hasher);
                },
                .compile_error => |node_handle| {
                    std.hash.autoHash(hasher, node_handle.node);
                    hasher.update(node_handle.handle.uri.raw);
                },
                .type_parameter => |token_handle| token_handle.hashWithHasher(hasher),
                .anytype_parameter => |info| {
                    info.token_handle.hashWithHasher(hasher);
                    if (info.type_from_callsite_references) |t| {
                        t.hashWithHasher(hasher);
                    }
                },
                .either => |entries| {
                    for (entries) |entry| {
                        hasher.update(entry.descriptor);
                        entry.type_data.hashWithHasher(hasher);
                    }
                },
                .enum_value => |value| {
                    value.enum_type.hashWithHasher(hasher);
                    hasher.update(value.tag);
                    std.hash.autoHash(hasher, value.int_value);
                },
                .string_value => |value| {
                    value.string_type.hashWithHasher(hasher);
                    hasher.update(value.bytes);
                },
                .ip_index => |payload| {
                    std.hash.autoHash(hasher, payload.type);
                    std.hash.autoHash(hasher, payload.index);
                },
            }
        }

        pub fn eql(a: Data, b: Data) bool {
            if (@intFromEnum(a) != @intFromEnum(b)) return false;

            switch (a) {
                .pointer => |a_type| {
                    const b_type = b.pointer;
                    if (a_type.size != b_type.size) return false;
                    if (a_type.sentinel != b_type.sentinel) return false;
                    if (!a_type.elem_ty.eql(b_type.elem_ty.*)) return false;
                },
                .array => |a_type| {
                    const b_type = b.array;
                    if (!std.meta.eql(a_type.elem_count, b_type.elem_count)) return false;
                    if (a_type.sentinel != b_type.sentinel) return false;
                    if (!a_type.elem_ty.eql(b_type.elem_ty.*)) return false;
                },
                .tuple => |a_slice| {
                    const b_slice = b.tuple;
                    if (a_slice.len != b_slice.len) return false;
                    for (a_slice, b_slice) |a_type, b_type| {
                        if (!a_type.eql(b_type)) return false;
                    }
                },
                inline .optional,
                .union_tag,
                => |a_type, name| {
                    const b_type = @field(b, @tagName(name));
                    if (!a_type.eql(b_type.*)) return false;
                },
                .error_union => |info| {
                    const b_info = b.error_union;
                    if (!info.payload.eql(b_info.payload.*)) return false;
                    if ((info.error_set == null) != (b_info.error_set == null)) return false;
                    if (info.error_set) |a_error_set| {
                        if (!a_error_set.eql(b_info.error_set.?.*)) return false;
                    }
                },
                .container => |a_info| {
                    const b_info = b.container;
                    if (!a_info.scope_handle.eql(b_info.scope_handle)) return false;
                    if (a_info.bound_params.count() != b_info.bound_params.count()) return false;
                    for (a_info.bound_params.keys(), a_info.bound_params.values()) |a_token_handle, a_type| {
                        const b_type = b_info.bound_params.get(a_token_handle) orelse return false;
                        if (!a_type.eql(b_type)) return false;
                    }
                },
                .function => |a_info| {
                    const b_info = b.function;
                    if (a_info.fn_node != b_info.fn_node) return false;
                    if (a_info.fn_token != b_info.fn_token) return false;
                    if (!a_info.handle.uri.eql(b_info.handle.uri)) return false;
                    if (!a_info.container_type.eql(b_info.container_type.*)) return false;
                    if (a_info.parameters.len != b_info.parameters.len) return false;
                    for (a_info.parameters, b_info.parameters) |a_param, b_param| {
                        if (!a_param.type.eql(b_param.type)) return false;
                    }
                    if (!a_info.return_value.eql(b_info.return_value.*)) return false;
                },
                .compile_error => |a_node_handle| return a_node_handle.eql(b.compile_error),
                .type_parameter => |a_token_handle| return a_token_handle.eql(b.type_parameter),
                .anytype_parameter => |a_info| {
                    const b_info = b.anytype_parameter;
                    if (!a_info.token_handle.eql(b_info.token_handle)) return false;
                    const a_type_maybe = a_info.type_from_callsite_references;
                    const b_type_maybe = b_info.type_from_callsite_references;
                    if (a_type_maybe) |a_type| {
                        const b_type = b_type_maybe orelse return false;
                        if (!a_type.eql(b_type.*)) return false;
                    } else {
                        if (b_type_maybe != null) return false;
                    }
                },
                .either => |a_entries| {
                    const b_entries = b.either;

                    if (a_entries.len != b_entries.len) return false;
                    for (a_entries, b_entries) |a_entry, b_entry| {
                        if (!std.mem.eql(u8, a_entry.descriptor, b_entry.descriptor)) return false;
                        if (!a_entry.type_data.eql(b_entry.type_data)) return false;
                    }
                },
                .enum_value => |a_value| {
                    const b_value = b.enum_value;
                    if (!a_value.enum_type.eql(b_value.enum_type.*)) return false;
                    if (!std.mem.eql(u8, a_value.tag, b_value.tag)) return false;
                    if (a_value.int_value != b_value.int_value) return false;
                },
                .string_value => |a_value| {
                    const b_value = b.string_value;
                    if (!a_value.string_type.eql(b_value.string_type.*)) return false;
                    if (!std.mem.eql(u8, a_value.bytes, b_value.bytes)) return false;
                },
                .ip_index => |a_payload| {
                    const b_payload = b.ip_index;

                    if (a_payload.type != b_payload.type) return false;
                    if (a_payload.index != b_payload.index) return false;
                },
            }

            return true;
        }

        fn isGeneric(data: Data) bool {
            return switch (data) {
                .type_parameter => true,
                .anytype_parameter => true,
                .pointer => |info| info.elem_ty.data.isGeneric(),
                .array => |info| info.elem_ty.data.isGeneric(),
                .tuple => |types| {
                    for (types) |t| {
                        if (t.data.isGeneric()) {
                            return true;
                        }
                    }
                    return false;
                },
                .optional => |t| t.data.isGeneric(),
                .error_union => |info| {
                    if (info.payload.data.isGeneric()) {
                        return true;
                    }
                    if (info.error_set) |t| {
                        if (t.data.isGeneric()) { // is this possible?
                            return true;
                        }
                    }
                    return false;
                },
                .union_tag => |t| t.data.isGeneric(),
                .container => |info| info.bound_params.count() != 0,
                .function => |info| {
                    if (info.container_type.data.isGeneric()) {
                        return true;
                    }
                    if (info.return_value.data.isGeneric()) {
                        return true;
                    }
                    for (info.parameters) |param| {
                        if (param.type.data.isGeneric()) {
                            return true;
                        }
                    }
                    return false;
                },
                .either => |entries| {
                    for (entries) |entry| {
                        if (entry.type_data.isGeneric()) {
                            return true;
                        }
                    }
                    return false;
                },
                .enum_value => |value| value.enum_type.data.isGeneric(),
                .string_value => |value| value.string_type.data.isGeneric(),
                .compile_error,
                .ip_index,
                => false,
            };
        }

        const GenericSet = std.HashMapUnmanaged(Data, void, GenericContext, std.hash_map.default_max_load_percentage);

        const GenericContext = struct {
            bound_params: TokenToTypeMap,

            pub fn hash(ctx: GenericContext, data: Data) u64 {
                var hasher: std.hash.Wyhash = .init(0);
                data.hashWithHasher(&hasher);
                for (ctx.bound_params.keys(), ctx.bound_params.values()) |token_handle, ty| {
                    token_handle.hashWithHasher(&hasher);
                    ty.hashWithHasher(&hasher);
                }
                return hasher.final();
            }

            pub fn eql(ctx: GenericContext, a: Data, b: Data) bool {
                _ = ctx;
                return a.eql(b);
            }
        };

        fn resolveGeneric(
            data: Data,
            analyser: *Analyser,
            bound_params: TokenToTypeMap,
            visiting: *GenericSet,
        ) error{OutOfMemory}!Data {
            if (!data.isGeneric()) {
                return data;
            }
            const ctx: GenericContext = .{ .bound_params = bound_params };
            const gop = try visiting.getOrPutContext(analyser.gpa, data, ctx);
            if (gop.found_existing) return data;
            defer std.debug.assert(visiting.removeContext(data, ctx));
            switch (data) {
                .compile_error,
                .ip_index,
                => unreachable,
                .type_parameter => |token_handle| {
                    const t = bound_params.get(token_handle) orelse return data;
                    std.debug.assert(t.is_type_val);
                    return t.data.resolveGeneric(analyser, bound_params, visiting);
                },
                .anytype_parameter => |info| {
                    const t = bound_params.get(info.token_handle) orelse return data;
                    std.debug.assert(t.is_type_val);
                    return t.data.resolveGeneric(analyser, bound_params, visiting);
                },
                .pointer => |info| {
                    const size = info.size;
                    const sentinel = info.sentinel;
                    const is_const = info.is_const;
                    const elem_ty = try analyser.resolveGenericTypeInternal(info.elem_ty.*, bound_params, visiting);
                    return try createPointer(analyser, size, sentinel, is_const, elem_ty);
                },
                .array => |info| {
                    const elem_count = info.elem_count;
                    const sentinel = info.sentinel;
                    const elem_ty = try analyser.resolveGenericTypeInternal(info.elem_ty.*, bound_params, visiting);
                    return try createArray(analyser, elem_count, sentinel, elem_ty);
                },
                .tuple => |info| {
                    const elem_tys = blk: {
                        const types = try analyser.arena.alloc(Type, info.len);
                        for (info, types) |old, *new| {
                            new.* = try analyser.resolveGenericTypeInternal(old, bound_params, visiting);
                        }
                        break :blk types;
                    };
                    return try createTuple(analyser, elem_tys);
                },
                .optional => |info| {
                    const child_ty = try analyser.resolveGenericTypeInternal(info.*, bound_params, visiting);
                    return try createOptional(analyser, child_ty);
                },
                .error_union => |info| {
                    const error_set = if (info.error_set) |t| try analyser.resolveGenericTypeInternal(t.*, bound_params, visiting) else null;
                    const payload = try analyser.resolveGenericTypeInternal(info.payload.*, bound_params, visiting);
                    return try createErrorUnion(analyser, error_set, payload);
                },
                .union_tag => |info| return .{
                    .union_tag = try analyser.allocType(try analyser.resolveGenericTypeInternal(info.*, bound_params, visiting)),
                },
                .enum_value => |value| return .{
                    .enum_value = .{
                        .enum_type = try analyser.allocType(try analyser.resolveGenericTypeInternal(value.enum_type.*, bound_params, visiting)),
                        .tag = value.tag,
                        .int_value = value.int_value,
                    },
                },
                .string_value => |value| return .{
                    .string_value = .{
                        .string_type = try analyser.allocType(try analyser.resolveGenericTypeInternal(value.string_type.*, bound_params, visiting)),
                        .bytes = value.bytes,
                    },
                },
                .container => |info| return .{
                    .container = .{
                        .scope_handle = info.scope_handle,
                        .bound_params = blk: {
                            var new_params: TokenToTypeMap = .empty;
                            try new_params.ensureTotalCapacity(analyser.arena, info.bound_params.count());
                            for (info.bound_params.keys(), info.bound_params.values()) |k, v| {
                                const bound = bound_params.get(k) orelse v;
                                // Re-specializing an enclosing type must not erase inner comptime values.
                                const t = if (bound.hasKnownValue(analyser))
                                    bound
                                else
                                    try analyser.resolveGenericTypeInternal(v, bound_params, visiting);
                                new_params.putAssumeCapacity(k, t);
                            }
                            break :blk new_params;
                        },
                    },
                },
                .function => |info| return .{
                    .function = .{
                        .fn_node = info.fn_node,
                        .fn_token = info.fn_token,
                        .handle = info.handle,
                        .container_type = try analyser.allocType(try analyser.resolveGenericTypeInternal(info.container_type.*, bound_params, visiting)),
                        .doc_comments = info.doc_comments,
                        .name = info.name,
                        .parameters = blk: {
                            const parameters = try analyser.arena.alloc(Parameter, info.parameters.len);
                            for (info.parameters, parameters) |old, *new| {
                                new.* = .{
                                    .doc_comments = old.doc_comments,
                                    .modifier = old.modifier,
                                    .name = old.name,
                                    .name_token = old.name_token,
                                    .type = try analyser.resolveGenericTypeInternal(old.type, bound_params, visiting),
                                };
                            }
                            break :blk parameters;
                        },
                        .has_varargs = info.has_varargs,
                        .return_value = try analyser.allocType(try analyser.resolveGenericTypeInternal(info.return_value.*, bound_params, visiting)),
                    },
                },
                .either => |info| return .{
                    .either = blk: {
                        const entries = try analyser.arena.alloc(EitherEntry, info.len);
                        for (info, entries) |old, *new| {
                            new.* = .{
                                .type_data = try old.type_data.resolveGeneric(analyser, bound_params, visiting),
                                .descriptor = old.descriptor,
                            };
                        }
                        break :blk entries;
                    },
                },
            }
        }
    };

    pub const unknown_type: Type = .{
        .data = .{
            .ip_index = .{
                .type = .type_type,
                .index = null,
            },
        },
        .is_type_val = true,
    };

    fn createPointerType(
        analyser: *Analyser,
        size: std.builtin.Type.Pointer.Size,
        sentinel: InternPool.Index,
        is_const: bool,
        elem_ty: Type,
    ) !Type {
        return .{
            .data = try Data.createPointer(analyser, size, sentinel, is_const, elem_ty),
            .is_type_val = true,
        };
    }

    fn createArrayType(
        analyser: *Analyser,
        elem_count: ?u64,
        sentinel: InternPool.Index,
        elem_ty: Type,
    ) !Type {
        return .{
            .data = try Data.createArray(analyser, elem_count, sentinel, elem_ty),
            .is_type_val = true,
        };
    }

    fn createTupleType(analyser: *Analyser, elem_tys: []Type) !Type {
        return .{
            .data = try Data.createTuple(analyser, elem_tys),
            .is_type_val = true,
        };
    }

    fn createTupleValue(analyser: *Analyser, elements: []Type) !?Type {
        return Data.createTupleValue(analyser, elements);
    }

    fn createOptionalType(analyser: *Analyser, child_ty: Type) !Type {
        return .{
            .data = try Data.createOptional(analyser, child_ty),
            .is_type_val = true,
        };
    }

    fn createErrorUnionType(
        analyser: *Analyser,
        error_set: ?Type,
        payload: Type,
    ) !Type {
        return .{
            .data = try Data.createErrorUnion(analyser, error_set, payload),
            .is_type_val = true,
        };
    }

    pub fn hash32(self: Type) u32 {
        return @truncate(self.hash64());
    }

    pub fn hash64(self: Type) u64 {
        var hasher: std.hash.Wyhash = .init(0);
        self.hashWithHasher(&hasher);
        return hasher.final();
    }

    pub fn hashWithHasher(self: Type, hasher: anytype) void {
        hasher.update(&.{@intFromBool(self.is_type_val)});
        self.data.hashWithHasher(hasher);
    }

    pub fn eql(a: Type, b: Type) bool {
        if (a.is_type_val != b.is_type_val) return false;
        if (!a.data.eql(b.data)) return false;
        return true;
    }

    pub const ArraySet = ArrayMap(void);

    pub fn ArrayMap(comptime V: type) type {
        return std.array_hash_map.Custom(Type, V, ArrayMapContext, true);
    }

    pub const ArrayMapContext = struct {
        pub fn hash(self: ArrayMapContext, ty: Type) u32 {
            _ = self;
            return ty.hash32();
        }

        pub fn eql(self: ArrayMapContext, a: Type, b: Type, b_index: usize) bool {
            _ = self;
            _ = b_index;
            return a.eql(b);
        }
    };

    pub fn ipIndex(self: Type) ?InternPool.Index {
        return switch (self.data) {
            .ip_index => |payload| payload.index,
            else => null,
        };
    }

    fn hasKnownValue(self: Type, analyser: *Analyser) bool {
        return switch (self.data) {
            .enum_value, .string_value => true,
            .ip_index => |payload| if (payload.index) |index|
                !analyser.ip.isUndefined(index) and !analyser.ip.isUnknown(index)
            else
                false,
            else => false,
        };
    }

    fn withoutIPIndex(self: Type, analyser: *Analyser) Type {
        return switch (self.data) {
            .ip_index => |payload| fromIP(analyser, payload.type, null),
            else => self,
        };
    }

    fn runtimeType(self: Type, analyser: *Analyser) Type {
        return switch (self.data) {
            .enum_value => |value| blk: {
                var result = value.enum_type.*;
                result.is_type_val = false;
                break :blk result;
            },
            .string_value => |value| blk: {
                if (value.string_type.ipIndex()) |index| {
                    break :blk Type.fromIP(analyser, index, null);
                }
                var result = value.string_type.*;
                result.is_type_val = false;
                break :blk result;
            },
            else => self,
        };
    }

    pub fn fromIP(analyser: *Analyser, ty: InternPool.Index, index: ?InternPool.Index) Type {
        std.debug.assert(analyser.ip.isType(ty));
        if (index) |idx| std.debug.assert(analyser.ip.typeOf(idx) == ty);
        return .{
            .data = .{ .ip_index = .{ .type = ty, .index = index } },
            .is_type_val = ty == .type_type,
        };
    }

    pub const TypeWithDescriptor = struct {
        type: Type,
        descriptor: []const u8,
    };

    pub fn fromEither(analyser: *Analyser, entries: []const TypeWithDescriptor) error{OutOfMemory}!?Type {
        const arena = analyser.arena;
        if (entries.len == 0)
            return null;

        if (entries.len == 1)
            return entries[0].type;

        peer_type_resolution: {
            var chosen = entries[0].type;
            for (entries[1..]) |entry| {
                const candidate = entry.type;
                chosen = try analyser.resolvePeerTypes(chosen, candidate) orelse break :peer_type_resolution;
            }
            return chosen;
        }

        // Note that we don't hash/equate descriptors to remove
        // duplicates

        const DeduplicatorContext = struct {
            pub fn hash(self: @This(), item: Type.Data.EitherEntry) u32 {
                _ = self;
                const ty: Type = .{ .data = item.type_data, .is_type_val = true };
                return ty.hash32();
            }

            pub fn eql(self: @This(), a: Type.Data.EitherEntry, b: Type.Data.EitherEntry, b_index: usize) bool {
                _ = b_index;
                _ = self;
                const a_ty: Type = .{ .data = a.type_data, .is_type_val = true };
                const b_ty: Type = .{ .data = b.type_data, .is_type_val = true };
                return a_ty.eql(b_ty);
            }
        };
        const Deduplicator = std.array_hash_map.Custom(Type.Data.EitherEntry, void, DeduplicatorContext, true);

        var deduplicator: Deduplicator = .empty;
        defer deduplicator.deinit(arena);

        const has_type_val = for (entries) |entry| {
            if (entry.type.data == .compile_error) {
                continue;
            }
            break entry.type.is_type_val;
        } else entries[0].type.is_type_val;

        for (entries) |entry| {
            try deduplicator.put(
                arena,
                .{ .type_data = entry.type.data, .descriptor = entry.descriptor },
                {},
            );
            if (entry.type.data == .compile_error) {
                continue;
            }
            if (entry.type.is_type_val != has_type_val) {
                return null;
            }
        }

        if (deduplicator.count() == 1)
            return entries[0].type;

        return .{
            .data = .{ .either = try arena.dupe(Type.Data.EitherEntry, deduplicator.keys()) },
            .is_type_val = has_type_val,
        };
    }

    /// Resolves all possible types by recursively expanding any conditional types.
    /// Drops duplicates
    pub fn getAllTypesWithHandles(ty: Type, analyser: *Analyser) error{OutOfMemory}![]const Type {
        var all_types: ArraySet = .empty;
        _ = try ty.getAllTypesWithHandlesArraySet(analyser, &all_types);
        return all_types.keys();
    }

    fn isConditional(ty: Type) bool {
        return switch (ty.data) {
            .either => true,
            .anytype_parameter => true,
            .optional => |child_ty| child_ty.isConditional(),
            .pointer => |info| info.elem_ty.isConditional(),
            .array => |info| info.elem_ty.isConditional(),
            .tuple => |types| {
                for (types) |t|
                    if (t.isConditional()) return true;
                return false;
            },
            .container => |info| {
                for (info.bound_params.values()) |t|
                    if (t.isConditional()) return true;
                return false;
            },
            .error_union => |info| {
                if (info.payload.isConditional()) return true;
                if (info.error_set) |e|
                    if (e.isConditional()) return true;
                return false;
            },
            .function => |info| {
                if (info.container_type.isConditional()) return true;
                if (info.return_value.isConditional()) return true;
                for (info.parameters) |param|
                    if (param.type.isConditional()) return true;
                return false;
            },
            .union_tag,
            .compile_error,
            .type_parameter,
            .enum_value,
            .string_value,
            .ip_index,
            => false,
        };
    }

    /// Returns true if we have reached the limit for analyzing combinations
    pub fn getAllTypesWithHandlesArraySet(ty: Type, analyser: *Analyser, all_types: *ArraySet) error{OutOfMemory}!bool {
        if (all_types.count() >= analyser.max_conditional_combos) {
            return true;
        }
        const arena = analyser.arena;
        if (!ty.isConditional()) {
            try all_types.put(arena, ty, {});
            return false;
        }
        switch (ty.data) {
            .union_tag,
            .compile_error,
            .type_parameter,
            .enum_value,
            .string_value,
            .ip_index,
            => unreachable,
            .either => |entries| {
                for (entries) |entry| {
                    const entry_ty: Type = .{ .data = entry.type_data, .is_type_val = ty.is_type_val };
                    if (try entry_ty.getAllTypesWithHandlesArraySet(analyser, all_types)) {
                        return true;
                    }
                }
            },
            .anytype_parameter => |info| {
                if (info.type_from_callsite_references) |t| {
                    if (try t.getAllTypesWithHandlesArraySet(analyser, all_types)) {
                        return true;
                    }
                } else {
                    try all_types.put(arena, ty, {});
                }
            },
            .optional => |child_ty| {
                for (try child_ty.getAllTypesWithHandles(analyser)) |t| {
                    if (all_types.count() >= analyser.max_conditional_combos) {
                        return true;
                    }
                    const new_child_ty = try analyser.allocType(t);
                    try all_types.put(arena, .{ .data = .{ .optional = new_child_ty }, .is_type_val = ty.is_type_val }, {});
                }
            },
            inline .pointer, .array => |info, tag| {
                for (try info.elem_ty.getAllTypesWithHandles(analyser)) |t| {
                    if (all_types.count() >= analyser.max_conditional_combos) {
                        return true;
                    }
                    var new_info = info;
                    new_info.elem_ty = try analyser.allocType(t);
                    const data = @unionInit(Type.Data, @tagName(tag), new_info);
                    try all_types.put(arena, .{ .data = data, .is_type_val = ty.is_type_val }, {});
                }
            },
            .tuple => |types| {
                var possible_types: ArrayMap([]const Type) = .empty;
                for (types) |t| {
                    try possible_types.put(arena, t, try t.getAllTypesWithHandles(analyser));
                }
                var iter: ComboIterator = try .init(arena, &possible_types);
                while (iter.next()) |combo| {
                    if (all_types.count() >= analyser.max_conditional_combos) {
                        return true;
                    }
                    const new_types = try arena.alloc(Type, types.len);
                    for (new_types, types) |*new, old| new.* = combo.get(old).?;
                    try all_types.put(arena, .{ .data = .{ .tuple = new_types }, .is_type_val = ty.is_type_val }, {});
                }
            },
            .container => |info| {
                var possible_types: ArrayMap([]const Type) = .empty;
                const types = info.bound_params.values();
                for (types) |t| {
                    try possible_types.put(arena, t, try t.getAllTypesWithHandles(analyser));
                }
                var iter: ComboIterator = try .init(arena, &possible_types);
                while (iter.next()) |combo| {
                    if (all_types.count() >= analyser.max_conditional_combos) {
                        return true;
                    }
                    const new_types = try arena.alloc(Type, types.len);
                    for (new_types, types) |*new, old| new.* = combo.get(old).?;
                    var new_info = info;
                    new_info.bound_params = try .init(arena, info.bound_params.keys(), new_types);
                    try all_types.put(arena, .{ .data = .{ .container = new_info }, .is_type_val = ty.is_type_val }, {});
                }
            },
            .error_union => |info| {
                var possible_types: ArrayMap([]const Type) = .empty;
                try possible_types.put(arena, info.payload.*, try info.payload.getAllTypesWithHandles(analyser));
                if (info.error_set) |t| {
                    try possible_types.put(arena, t.*, try t.getAllTypesWithHandles(analyser));
                }
                var iter: ComboIterator = try .init(arena, &possible_types);
                while (iter.next()) |combo| {
                    if (all_types.count() >= analyser.max_conditional_combos) {
                        return true;
                    }
                    var new_info = info;
                    new_info.payload = try analyser.allocType(combo.get(info.payload.*).?);
                    if (info.error_set) |t| {
                        new_info.error_set = try analyser.allocType(combo.get(t.*).?);
                    }
                    try all_types.put(arena, .{ .data = .{ .error_union = new_info }, .is_type_val = ty.is_type_val }, {});
                }
            },
            .function => |info| {
                var possible_types: ArrayMap([]const Type) = .empty;
                try possible_types.put(arena, info.container_type.*, try info.container_type.getAllTypesWithHandles(analyser));
                for (info.parameters) |param| {
                    try possible_types.put(arena, param.type, try param.type.getAllTypesWithHandles(analyser));
                }
                if (info.return_value.is_type_val) {
                    try possible_types.put(arena, info.return_value.*, try info.return_value.getAllTypesWithHandles(analyser));
                } else {
                    const return_type = try info.return_value.typeOf(analyser);
                    try possible_types.put(arena, return_type, try return_type.getAllTypesWithHandles(analyser));
                }
                var iter: ComboIterator = try .init(arena, &possible_types);
                while (iter.next()) |combo| {
                    if (all_types.count() >= analyser.max_conditional_combos) {
                        return true;
                    }
                    var new_info = info;
                    new_info.container_type = try analyser.allocType(combo.get(info.container_type.*).?);
                    new_info.parameters = try arena.alloc(Data.Parameter, info.parameters.len);
                    @memcpy(new_info.parameters, info.parameters);
                    for (new_info.parameters, info.parameters) |*new, old| {
                        new.type = combo.get(old.type).?;
                    }
                    if (info.return_value.is_type_val) {
                        new_info.return_value = try analyser.allocType(combo.get(info.return_value.*).?);
                    } else {
                        const return_type = try info.return_value.typeOf(analyser);
                        const return_value = try combo.get(return_type).?.instanceUnchecked(analyser);
                        new_info.return_value = try analyser.allocType(return_value);
                    }
                    try all_types.put(arena, .{ .data = .{ .function = new_info }, .is_type_val = ty.is_type_val }, {});
                }
            },
        }
        return false;
    }

    const ComboIterator = struct {
        possible_types: *const ArrayMap([]const Type),
        current_combo: ArrayMap(Type),
        total_combos: usize,
        counter: usize,

        fn init(
            arena: std.mem.Allocator,
            possible_types: *const ArrayMap([]const Type),
        ) error{OutOfMemory}!ComboIterator {
            var current_combo: ArrayMap(Type) = .empty;
            try current_combo.entries.resize(arena, possible_types.count());
            @memcpy(current_combo.keys(), possible_types.keys());
            try current_combo.reIndex(arena);

            var total_combos: usize = 1;
            for (possible_types.values()) |types| {
                total_combos *= types.len;
            }

            return .{
                .possible_types = possible_types,
                .current_combo = current_combo,
                .total_combos = total_combos,
                .counter = 0,
            };
        }

        fn next(iter: *ComboIterator) ?*const ArrayMap(Type) {
            if (iter.counter == iter.total_combos) return null;
            var x = iter.counter;
            for (iter.current_combo.values(), iter.possible_types.values()) |*t, types| {
                t.* = types[x % types.len];
                x /= types.len;
            }
            iter.counter += 1;
            return &iter.current_combo;
        }
    };

    pub fn instanceTypeVal(self: Type, analyser: *Analyser) error{OutOfMemory}!?Type {
        if (!self.is_type_val) return null;
        return try self.instanceUnchecked(analyser);
    }

    pub fn instanceUnchecked(self: Type, analyser: *Analyser) error{OutOfMemory}!Type {
        std.debug.assert(self.is_type_val);
        return switch (self.data) {
            .ip_index => |payload| fromIP(analyser, payload.index orelse try analyser.ip.getUnknown(payload.type), null),
            .either => |old_entries| {
                const new_entries = try analyser.arena.alloc(Type.Data.EitherEntry, old_entries.len);
                for (old_entries, new_entries) |old, *new| {
                    const old_type: Type = .{ .data = old.type_data, .is_type_val = self.is_type_val };
                    const new_type = try old_type.instanceUnchecked(analyser);
                    new.* = .{
                        .type_data = new_type.data,
                        .descriptor = old.descriptor,
                    };
                }
                return .{
                    .data = .{ .either = new_entries },
                    .is_type_val = false,
                };
            },
            else => .{ .data = self.data, .is_type_val = false },
        };
    }

    pub fn typeOf(self: Type, analyser: *Analyser) error{OutOfMemory}!Type {
        if (self.is_type_val) {
            return fromIP(analyser, .type_type, .type_type);
        }

        if (self.data == .enum_value) {
            return self.data.enum_value.enum_type.*;
        }
        if (self.data == .string_value) {
            return self.data.string_value.string_type.*;
        }

        if (self.data == .ip_index) {
            return fromIP(analyser, .type_type, self.data.ip_index.type);
        }

        if (self.data == .either) {
            const old_entries = self.data.either;
            const new_entries = try analyser.arena.alloc(Type.Data.EitherEntry, old_entries.len);
            for (old_entries, new_entries) |old, *new| {
                const old_type: Type = .{ .data = old.type_data, .is_type_val = self.is_type_val };
                const new_type = try old_type.typeOf(analyser);
                new.* = .{
                    .type_data = new_type.data,
                    .descriptor = old.descriptor,
                };
            }
            return .{
                .data = .{ .either = new_entries },
                .is_type_val = true,
            };
        }

        return .{
            .data = self.data,
            .is_type_val = true,
        };
    }

    fn isRoot(self: Type) bool {
        switch (self.data) {
            .container => |info| return info.scope_handle.scope == Scope.Index.root,
            else => return false,
        }
    }

    pub fn isGenericType(self: Type) bool {
        return self.data.isGeneric();
    }

    fn getContainerKind(self: Type) ?std.zig.Token.Tag {
        const scope_handle = switch (self.data) {
            .container => |info| info.scope_handle,
            else => return null,
        };
        if (scope_handle.scope == .root) return .keyword_struct;

        const node = scope_handle.toNode();

        const tree = scope_handle.handle.tree;
        return tree.tokenTag(tree.nodeMainToken(node));
    }

    fn isContainerKind(self: Type, container_kind_tok: std.zig.Token.Tag) bool {
        return self.getContainerKind() == container_kind_tok;
    }

    pub fn isStructType(self: Type, analyser: *Analyser) bool {
        if (!self.is_type_val) return false;
        return switch (self.data) {
            .tuple => true,
            .ip_index => |payload| {
                const index = payload.index orelse return false;
                return analyser.ip.zigTypeTag(index) == .@"struct";
            },
            else => self.isContainerKind(.keyword_struct) or self.isRoot(),
        };
    }

    pub fn isNamespace(self: Type) bool {
        const scope_handle = switch (self.data) {
            .tuple => |fields| return fields.len == 0,
            .container => |info| info.scope_handle,
            else => return false,
        };
        if (!self.isContainerKind(.keyword_struct)) return false;
        const node = scope_handle.toNode();
        const tree = &scope_handle.handle.tree;
        var buf: [2]Ast.Node.Index = undefined;
        const full = tree.fullContainerDecl(&buf, node) orelse return true;
        for (full.ast.members) |member| {
            if (tree.nodeTag(member).isContainerField()) return false;
        }
        return true;
    }

    pub fn isEnumType(self: Type) bool {
        return self.isContainerKind(.keyword_enum);
    }

    pub fn isUnionType(self: Type) bool {
        return self.isContainerKind(.keyword_union);
    }

    pub fn isOpaqueType(self: Type) bool {
        return self.isContainerKind(.keyword_opaque);
    }

    pub fn isTaggedUnion(self: Type) bool {
        return switch (self.data) {
            .container => |info| ast.isTaggedUnion(&info.scope_handle.handle.tree, info.scope_handle.toNode()),
            else => false,
        };
    }

    /// returns whether the given type is of type `type`.
    pub fn isMetaType(self: Type) bool {
        if (!self.is_type_val) return false;
        switch (self.data) {
            .ip_index => |payload| return payload.index == .type_type,
            else => return false,
        }
    }

    pub fn isErrorSetType(self: Type, analyser: *Analyser) bool {
        if (!self.is_type_val) return false;
        switch (self.data) {
            .ip_index => |payload| {
                const ip_index = payload.index orelse return false;
                return analyser.ip.zigTypeTag(ip_index) == .error_set;
            },
            else => return false,
        }
    }

    pub fn isEnumLiteral(self: Type) bool {
        switch (self.data) {
            .ip_index => |payload| return payload.type == .enum_literal_type,
            else => return false,
        }
    }

    fn isOptionalType(self: Type, analyser: *Analyser) bool {
        if (!self.is_type_val) return false;
        return switch (self.data) {
            .optional => true,
            .ip_index => |payload| if (payload.index) |index|
                analyser.ip.zigTypeTag(index) == .optional
            else
                false,
            else => false,
        };
    }

    pub fn resolveDeclLiteralResultType(ty: Type) Type {
        var result_type = ty;
        while (true) {
            result_type = switch (result_type.data) {
                .optional => |child_ty| child_ty.*,
                .error_union => |info| info.payload.*,
                .pointer => |child_ty| child_ty.elem_ty.*,
                .enum_value => |value| value.enum_type.*,
                else => return result_type,
            };
        }
    }

    pub fn isTypeFunc(self: Type) bool {
        return switch (self.data) {
            .function => |info| info.return_value.is_type_val,
            else => false,
        };
    }

    /// Returns whether the given function has a `anytype` parameter.
    pub fn isGenericFunc(self: Type) bool {
        return switch (self.data) {
            .function => |info| {
                for (info.parameters) |param| {
                    if (param.type.data == .anytype_parameter or param.modifier == .comptime_param) {
                        return true;
                    }
                }
                return false;
            },
            else => false,
        };
    }

    pub fn isFunc(self: Type) bool {
        return switch (self.data) {
            .function => true,
            else => false,
        };
    }

    pub fn isNoreturnType(self: Type) bool {
        if (!self.is_type_val) return false;
        return switch (self.data) {
            .compile_error => true,
            .ip_index => |payload| payload.index == .noreturn_type,
            else => false,
        };
    }

    fn pointerSize(self: Type, analyser: *Analyser) ?std.builtin.Type.Pointer.Size {
        if (self.is_type_val) return null;
        return switch (self.data) {
            .pointer => |info| info.size,
            .ip_index => |payload| switch (analyser.ip.indexToKey(payload.type)) {
                .pointer_type => |pointer_info| pointer_info.flags.size,
                else => null,
            },
            else => null,
        };
    }

    fn pointerElementType(
        self: Type,
        analyser: *Analyser,
        size: std.builtin.Type.Pointer.Size,
    ) ?Type {
        if (self.is_type_val) return null;
        return switch (self.data) {
            .pointer => |info| {
                if (info.size != size) return null;
                return info.elem_ty.*;
            },
            .ip_index => |payload| switch (analyser.ip.indexToKey(payload.type)) {
                .pointer_type => |pointer_info| {
                    if (pointer_info.flags.size != size) return null;
                    return Type.fromIP(analyser, .type_type, pointer_info.elem_type);
                },
                else => null,
            },
            else => null,
        };
    }

    fn arrayInfo(ty: Type, analyser: *Analyser) ?struct { ?u64, InternPool.Index, Type } {
        if (ty.is_type_val) return null;
        return switch (ty.data) {
            .array => |info| .{
                info.elem_count,
                info.sentinel,
                info.elem_ty.*,
            },
            .ip_index => |payload| switch (analyser.ip.indexToKey(payload.type)) {
                .array_type => |array_info| .{
                    array_info.len,
                    array_info.sentinel,
                    Type.fromIP(analyser, .type_type, array_info.child),
                },
                else => null,
            },
            else => null,
        };
    }

    pub fn typeDefinitionToken(self: Type) ?TokenWithHandle {
        return switch (self.data) {
            .container => |info| {
                const container = info.scope_handle.toNode();
                var buf: [2]Ast.Node.Index = undefined;
                const tree = &info.scope_handle.handle.tree;
                // try to parse something that looks like (and only looks like) `const X = @This();`
                if (tree.fullContainerDecl(&buf, container)) |container_decl| {
                    for (container_decl.ast.members) |decl| {
                        const full_decl = tree.fullVarDecl(decl) orelse continue;

                        const init_node = full_decl.ast.init_node.unwrap() orelse continue;
                        if (!ast.isBuiltinCall(tree, init_node)) continue;
                        const builtin_name = tree.nodeMainToken(init_node);
                        std.debug.assert(tree.tokenTag(builtin_name) == .builtin);
                        const builtin_name_text = tree.tokenSlice(builtin_name);
                        if (!std.mem.eql(u8, builtin_name_text, "@This")) continue;

                        return .{
                            .token = full_decl.ast.mut_token + 1,
                            .handle = info.scope_handle.handle,
                        };
                    }
                }

                return .{
                    .token = info.scope_handle.handle.tree.firstToken(info.scope_handle.toNode()),
                    .handle = info.scope_handle.handle,
                };
            },
            .function => |info| .{
                .token = info.fn_token,
                .handle = info.handle,
            },
            else => null,
        };
    }

    pub fn docComments(self: Type, allocator: std.mem.Allocator) error{OutOfMemory}!?[]const u8 {
        if (self.is_type_val) {
            switch (self.data) {
                .container => |info| return try getDocComments(allocator, &info.scope_handle.handle.tree, info.scope_handle.toNode()),
                .function => |info| return info.doc_comments,
                else => {},
            }
        }
        return null;
    }

    pub fn lookupSymbol(
        self: Type,
        analyser: *Analyser,
        symbol: []const u8,
    ) Error!?DeclWithHandle {
        switch (self.data) {
            .either => |entries| {
                // TODO: Return all options instead of first valid one
                for (entries) |entry| {
                    const entry_ty: Type = .{ .data = entry.type_data, .is_type_val = self.is_type_val };
                    if (try entry_ty.lookupSymbol(analyser, symbol)) |decl| {
                        return decl;
                    }
                }
                return null;
            },
            else => {},
        }
        if (self.is_type_val) {
            if (self.isEnumType() or self.isTaggedUnion()) {
                if (try analyser.lookupSymbolContainer(self, symbol, .field)) |decl| {
                    return decl;
                }
            }
            return try analyser.lookupSymbolContainer(self, symbol, .other);
        } else {
            if (try analyser.lookupSymbolContainer(self, symbol, .other)) |decl| {
                const ty = try decl.resolveType(analyser) orelse return null;
                const func_type = try analyser.resolveFuncProtoOfCallable(ty) orelse return null;
                if (analyser.firstParamIs(func_type, try self.typeOf(analyser))) {
                    return decl;
                }
            }
            if (self.isEnumType()) {
                return null;
            }
            return try analyser.lookupSymbolContainer(self, symbol, .field);
        }
    }

    pub fn stringifyTypeOf(ty: Type, analyser: *Analyser, options: FormatOptions) error{OutOfMemory}![]const u8 {
        const typeof = try ty.typeOf(analyser);
        var aw: std.Io.Writer.Allocating = .init(analyser.arena);
        defer aw.deinit();
        rawStringify(typeof, &aw.writer, analyser, options) catch |err| switch (err) {
            error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
        };
        return aw.toOwnedSlice();
    }

    pub fn stringifyTypeVal(ty: Type, analyser: *Analyser, options: FormatOptions) error{OutOfMemory}![]const u8 {
        std.debug.assert(ty.data == .ip_index or ty.is_type_val);
        var aw: std.Io.Writer.Allocating = .init(analyser.arena);
        defer aw.deinit();
        rawStringify(ty, &aw.writer, analyser, options) catch |err| switch (err) {
            error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
        };
        return aw.toOwnedSlice();
    }

    fn writeString(str: []const u8, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(str);
    }

    pub const FormatOptions = struct {
        referenced: ?*ReferencedType.Set = null,
        truncate_container_decls: bool,
    };

    fn rawStringify(
        ty: Type,
        writer: *std.Io.Writer,
        analyser: *Analyser,
        options: FormatOptions,
    ) error{ OutOfMemory, WriteFailed }!void {
        const referenced = options.referenced;

        switch (ty.data) {
            .pointer => |info| {
                switch (info.size) {
                    .one => try writer.writeByte('*'),
                    .many => {
                        try writer.writeAll("[*");
                        if (info.sentinel != .none) {
                            try writer.writeByte(':');
                            if (info.sentinel != .unknown_unknown) {
                                try writer.print("{f}", .{info.sentinel.fmt(analyser.ip)});
                            } else {
                                try writer.writeByte('?');
                            }
                        }
                        try writer.writeByte(']');
                    },
                    .slice => {
                        try writer.writeAll("[");
                        if (info.sentinel != .none) {
                            try writer.writeByte(':');
                            if (info.sentinel != .unknown_unknown) {
                                try writer.print("{f}", .{info.sentinel.fmt(analyser.ip)});
                            } else {
                                try writer.writeByte('?');
                            }
                        }
                        try writer.writeByte(']');
                    },
                    .c => try writer.writeAll("[*c]"),
                }
                if (info.is_const) try writer.writeAll("const ");
                try info.elem_ty.rawStringify(writer, analyser, options);
            },
            .array => |info| {
                try writer.writeByte('[');
                if (info.elem_count) |count| {
                    try writer.print("{d}", .{count});
                } else {
                    try writer.writeAll("?");
                }
                if (info.sentinel != .none) {
                    try writer.writeByte(':');
                    if (info.sentinel != .unknown_unknown) {
                        try writer.print("{f}", .{info.sentinel.fmt(analyser.ip)});
                    } else {
                        try writer.writeByte('?');
                    }
                }
                try writer.writeByte(']');
                try info.elem_ty.rawStringify(writer, analyser, options);
            },
            .tuple => |elem_ty_slice| {
                try writer.writeAll("struct { ");
                for (elem_ty_slice, 0..) |elem_ty, i| {
                    if (i != 0) {
                        try writer.writeAll(", ");
                    }
                    try elem_ty.rawStringify(writer, analyser, options);
                }
                try writer.writeAll(" }");
            },
            .optional => |child_ty| {
                try writer.writeByte('?');
                try child_ty.rawStringify(writer, analyser, options);
            },
            .error_union => |info| {
                if (info.error_set) |error_set| {
                    try error_set.rawStringify(writer, analyser, options);
                }
                try writer.writeByte('!');
                try info.payload.rawStringify(writer, analyser, options);
            },
            .union_tag => |t| {
                try writer.writeAll("@typeInfo(");
                try t.rawStringify(writer, analyser, options);
                try writer.writeAll(").@\"union\".tag_type.?");
            },
            .enum_value => |value| {
                try writer.writeByte('.');
                try writer.writeAll(value.tag);
            },
            .string_value => |value| try writer.print("\"{s}\"", .{value.bytes}),
            .container => |info| {
                const scope_handle = info.scope_handle;
                const handle = scope_handle.handle;
                const tree = &handle.tree;

                const node = scope_handle.toNode();

                switch (handle.tree.nodeTag(node)) {
                    .root => {
                        const path = handle.uri.toFsPath(analyser.arena) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.UnsupportedScheme => handle.uri.raw,
                        };
                        const str = std.Io.Dir.path.stem(path);
                        try writer.writeAll(str);
                        if (referenced) |r| try r.put(analyser.arena, .of(str, handle, tree.firstToken(node)), {});
                    },

                    .container_decl,
                    .container_decl_arg,
                    .container_decl_arg_trailing,
                    .container_decl_trailing,
                    .container_decl_two,
                    .container_decl_two_trailing,
                    .tagged_union,
                    .tagged_union_trailing,
                    .tagged_union_two,
                    .tagged_union_two_trailing,
                    .tagged_union_enum_tag,
                    .tagged_union_enum_tag_trailing,
                    => {
                        // This is a hacky nightmare but it works :P
                        const token = tree.firstToken(node);
                        // `Foo = struct`
                        if (token >= 2 and tree.tokenTag(token - 2) == .identifier and tree.tokenTag(token - 1) == .equal) {
                            var str_token = token - 2;
                            // `Foo: type = struct`
                            if (token >= 4 and tree.tokenTag(token - 4) == .identifier and tree.tokenTag(token - 3) == .colon) {
                                str_token = token - 4;
                            }
                            const str = tree.tokenSlice(str_token);
                            try writer.writeAll(str);
                            if (referenced) |r| try r.put(analyser.arena, .of(str, handle, str_token), {});
                            return;
                        }
                        if (token >= 1 and tree.tokenTag(token - 1) == .keyword_return) blk: {
                            const doc_scope = try handle.getDocumentScope();
                            const function_scope = innermostScopeAtIndexWithTag(doc_scope, tree.tokenStart(token - 1), .initOne(.function)).unwrap() orelse break :blk;
                            const function_node = doc_scope.getScopeAstNode(function_scope).?;
                            var buf: [1]Ast.Node.Index = undefined;
                            const func = tree.fullFnProto(&buf, function_node).?;
                            const func_name_token = func.name_token orelse break :blk;
                            const func_name = offsets.tokenToSlice(tree, func_name_token);
                            try writer.writeAll(func_name);
                            if (referenced) |r| try r.put(analyser.arena, .of(func_name, handle, func_name_token), {});
                            var first = true;
                            try writer.writeByte('(');
                            var it: ast.FnParamIterator = .init(&func, tree);
                            while (it.next()) |param| {
                                const param_name_token = param.name_token orelse continue;
                                const token_handle: TokenWithHandle = .{ .token = param_name_token, .handle = handle };
                                const param_ty = info.bound_params.get(token_handle) orelse continue;
                                if (!param_ty.is_type_val and !param_ty.hasKnownValue(analyser)) continue;
                                if (param_ty.ipIndex()) |index| {
                                    if (analyser.ip.isNull(index)) continue;
                                }
                                if (!first) {
                                    try writer.writeByte(',');
                                }

                                try param_ty.rawStringify(writer, analyser, .{
                                    .referenced = referenced,
                                    .truncate_container_decls = options.truncate_container_decls,
                                });
                                first = false;
                            }
                            try writer.writeByte(')');
                            return;
                        }

                        if (!options.truncate_container_decls) {
                            try writer.writeAll(offsets.nodeToSlice(tree, node));
                            return;
                        }

                        var container_decl_buffer: [2]Ast.Node.Index = undefined;
                        const container_decl = tree.fullContainerDecl(&container_decl_buffer, node).?;

                        const start_token = container_decl.layout_token orelse container_decl.ast.main_token;
                        const end_token = if (container_decl.ast.arg.unwrap()) |arg|
                            @min(ast.lastToken(tree, arg) + 1, tree.tokens.len)
                        else if (container_decl.ast.enum_token) |enum_token|
                            @min(enum_token + 1, tree.tokens.len)
                        else
                            container_decl.ast.main_token;

                        try writer.writeAll(offsets.tokensToSlice(tree, start_token, end_token));
                        if (container_decl.ast.members.len == 0) {
                            try writer.writeAll(" {}");
                        } else {
                            try writer.writeAll(" {...}");
                        }
                    },

                    else => unreachable,
                }
            },
            .function => |info| {
                try analyser.rawStringifyFunction(writer, .{
                    .referenced = referenced,
                    .info = info,
                    .include_fn_keyword = true,
                    .include_name = false,
                    .skip_first_param = false,
                    .parameters = .{ .show = .{
                        .include_modifiers = true,
                        .include_names = false,
                        .include_types = true,
                    } },
                    .include_return_type = true,
                    .snippet_placeholders = false,
                });
            },
            .ip_index => |payload| {
                const ip_index = payload.index orelse try analyser.ip.getUnknown(payload.type);
                try analyser.ip.print(ip_index, writer, .{
                    .truncate_container = options.truncate_container_decls,
                });
            },
            .either => try writer.writeAll("either type"), // TODO
            .compile_error => |node_handle| {
                if (options.truncate_container_decls) {
                    try writer.writeAll("@compileError(...)");
                } else {
                    try writer.writeAll(offsets.nodeToSlice(&node_handle.handle.tree, node_handle.node));
                }
            },
            .type_parameter => |token_handle| {
                const token = token_handle.token;
                const handle = token_handle.handle;
                const str = handle.tree.tokenSlice(token);
                try writer.writeAll(str);
                if (referenced) |r| try r.put(analyser.arena, .of(str, handle, token), {});
            },
            .anytype_parameter => {
                try writer.writeAll("anytype");
            },
        }
    }
};

pub const ScopeWithHandle = struct {
    handle: *DocumentStore.Handle,
    scope: Scope.Index,

    pub fn toNode(scope_handle: ScopeWithHandle) Ast.Node.Index {
        if (scope_handle.scope == Scope.Index.root) return .root;
        var doc_scope = scope_handle.handle.document_scope.getCached();
        return doc_scope.getScopeAstNode(scope_handle.scope).?;
    }

    pub fn hashWithHasher(scope_handle: ScopeWithHandle, hasher: anytype) void {
        hasher.update(scope_handle.handle.uri.raw);
        std.hash.autoHash(hasher, scope_handle.scope);
    }

    pub fn eql(a: ScopeWithHandle, b: ScopeWithHandle) bool {
        if (a.scope != b.scope) return false;
        if (!a.handle.uri.eql(b.handle.uri)) return false;
        return true;
    }
};

pub fn resolveImportString(analyser: *Analyser, handle: *DocumentStore.Handle, import_string: []const u8) Error!?Type {
    const result = try analyser.store.uriFromImportStr(analyser.arena, handle, import_string);
    switch (result) {
        .none => return null,
        .one => |uri| {
            const node_handle = try analyser.store.getOrLoadHandle(uri) orelse return null;
            return .{
                .data = .{ .container = .root(node_handle) },
                .is_type_val = true,
            };
        },
        .many => |uris| {
            var entries: std.ArrayList(Type.Data.EitherEntry) = try .initCapacity(analyser.arena, uris.len);
            for (uris) |uri| {
                const node_handle = try analyser.store.getOrLoadHandle(uri) orelse continue;
                entries.appendAssumeCapacity(.{
                    .type_data = .{ .container = .root(node_handle) },
                    .descriptor = "",
                });
            }
            return .{
                .data = .{ .either = entries.items },
                .is_type_val = true,
            };
        },
    }
}

fn resolveLangrefType(analyser: *Analyser, type_str: []const u8) Error!?Type {
    if (try analyser.resolvePrimitive(type_str)) |primitive|
        return Type.fromIP(analyser, primitive, null);

    // e.g. `?type`
    if (std.mem.startsWith(u8, type_str, "?")) {
        const elem_str = type_str[1..];
        const elem_instance = try analyser.resolveLangrefType(elem_str) orelse return null;
        const elem_ty = try elem_instance.typeOf(analyser);
        const optional_ty = try Type.createOptionalType(analyser, elem_ty);
        return try optional_ty.instanceUnchecked(analyser);
    }

    // e.g. `*const anyopaque`
    if (std.mem.startsWith(u8, type_str, "*")) {
        var elem_str = type_str[1..];
        const is_const = std.mem.startsWith(u8, elem_str, "const ");
        if (is_const)
            elem_str = elem_str[6..];
        const elem_instance = try analyser.resolveLangrefType(elem_str) orelse return null;
        const elem_ty = try elem_instance.typeOf(analyser);
        const pointer_ty = try Type.createPointerType(analyser, .one, .none, is_const, elem_ty);
        return try pointer_ty.instanceUnchecked(analyser);
    }

    // e.g. `[]const u8`
    if (std.mem.startsWith(u8, type_str, "[")) {
        const bracket_idx = std.mem.findScalar(u8, type_str, ']') orelse return null;

        var is_slice = bracket_idx == 1;
        var sentinel: InternPool.Index = .none;

        // e.g. `[:0]const u8`
        if (std.mem.findScalarLast(u8, type_str[0..bracket_idx], ':')) |colon_idx| {
            is_slice = colon_idx == 1;
            const sentinel_str = type_str[colon_idx + 1 .. bracket_idx];
            if (std.mem.eql(u8, sentinel_str, "0"))
                sentinel = .zero_comptime_int
            else
                sentinel = .unknown_unknown;
        }

        // e.g. `[N:0]u8`
        if (!is_slice) {
            const elem_str = type_str[bracket_idx + 1 ..];
            const elem_instance = try analyser.resolveLangrefType(elem_str) orelse return null;
            const elem_ty = try elem_instance.typeOf(analyser);
            const array_ty = try Type.createArrayType(analyser, null, sentinel, elem_ty);
            return try array_ty.instanceUnchecked(analyser);
        }

        var elem_str = type_str[bracket_idx + 1 ..];
        const is_const = std.mem.startsWith(u8, elem_str, "const ");
        if (is_const)
            elem_str = elem_str[6..];
        const elem_instance = try analyser.resolveLangrefType(elem_str) orelse return null;
        const elem_ty = try elem_instance.typeOf(analyser);
        const slice_ty = try Type.createPointerType(analyser, .slice, sentinel, is_const, elem_ty);
        return try slice_ty.instanceUnchecked(analyser);
    }

    return analyser.instanceStdBuiltinType(type_str);
}

/// Look up `type_name` in 'zig_lib_dir/std/builtin.zig' and return it as an instance
/// Useful for functionality related to builtin fns
pub fn instanceStdBuiltinType(analyser: *Analyser, type_name: []const u8) Error!?Type {
    const zig_lib_dir = analyser.store.config.zig_lib_dir orelse return null;
    const builtin_path = try zig_lib_dir.join(analyser.arena, &.{ "std", "builtin.zig" });
    const builtin_uri: Uri = try .fromPath(analyser.arena, builtin_path);

    const builtin_handle = try analyser.store.getOrLoadHandle(builtin_uri) orelse return null;
    const builtin_root_struct_type: Type = .{
        .data = .{ .container = .root(builtin_handle) },
        .is_type_val = true,
    };

    var result_ty = builtin_root_struct_type;
    var i: usize = 0;
    while (i < type_name.len) {
        const end = std.mem.findScalarPos(u8, type_name, i, '.') orelse type_name.len;
        const name = type_name[i..end];
        i = 1 + end;
        const decl = try result_ty.lookupSymbol(analyser, name) orelse return null;
        result_ty = try decl.resolveType(analyser) orelse return null;
    }
    return try result_ty.instanceTypeVal(analyser);
}

pub const NodeWithUri = struct {
    node: Ast.Node.Index,
    uri: Uri,

    const Context = struct {
        pub fn hash(self: Context, item: NodeWithUri) u64 {
            _ = self;
            var hasher: std.hash.Wyhash = .init(0);
            std.hash.autoHash(&hasher, item.node);
            hasher.update(item.uri.raw);
            return hasher.final();
        }

        pub fn eql(self: Context, a: NodeWithUri, b: NodeWithUri) bool {
            _ = self;
            if (a.node != b.node) return false;
            return a.uri.eql(b.uri);
        }
    };
};

pub const NodeWithHandle = struct {
    node: Ast.Node.Index,
    handle: *DocumentStore.Handle,

    pub fn of(node: Ast.Node.Index, handle: *DocumentStore.Handle) NodeWithHandle {
        return .{ .node = node, .handle = handle };
    }

    pub fn eql(a: NodeWithHandle, b: NodeWithHandle) bool {
        if (a.node != b.node) return false;
        return a.handle.uri.eql(b.handle.uri);
    }
};

pub fn getFieldAccessType(
    analyser: *Analyser,
    handle: *DocumentStore.Handle,
    source_index: usize,
    loc: offsets.Loc,
) Error!?Type {
    const held_range = try analyser.arena.dupeSentinel(u8, offsets.locToSlice(handle.tree.source, loc), 0);
    var tokenizer: std.zig.Tokenizer = .init(held_range);
    var current_type: ?Type = null;

    var do_unwrap_error_payload = false; // .keyword_try seen, ie `(try foo())`

    while (true) {
        const tok = tokenizer.next();
        switch (tok.tag) {
            .eof => return current_type,
            .identifier => {
                const symbol_name = offsets.identifierIndexToSlice(tokenizer.buffer, tok.loc.start, .name);
                if (try analyser.lookupSymbolGlobal(
                    handle,
                    symbol_name,
                    source_index,
                )) |child| {
                    current_type = (try child.resolveType(analyser)) orelse return null;
                } else return null;
            },
            .period => {
                const after_period = tokenizer.next();
                switch (after_period.tag) {
                    .eof => {
                        // function labels cannot be dot accessed
                        if (current_type) |ct| {
                            if (ct.isFunc()) return null;
                            return ct;
                        } else {
                            return null;
                        }
                    },
                    .identifier => {
                        if (after_period.loc.end == tokenizer.buffer.len) {
                            return current_type;
                        }

                        const symbol = offsets.identifierIndexToSlice(tokenizer.buffer, after_period.loc.start, .name);

                        current_type = try analyser.resolveFieldAccess(current_type orelse return null, symbol) orelse return null;
                    },
                    .question_mark => {
                        if (after_period.loc.end == tokenizer.buffer.len) {
                            return current_type;
                        }

                        current_type = (try analyser.resolveOptionalUnwrap(current_type orelse return null)) orelse return null;
                    },
                    else => {
                        log.debug("Unrecognized token {} after period.", .{after_period.tag});
                        return null;
                    },
                }
            },
            .period_asterisk => {
                if (tok.loc.end == tokenizer.buffer.len) {
                    return current_type;
                }

                current_type = (try analyser.resolveDerefType(current_type orelse return null)) orelse return null;
            },
            .l_paren => {
                if (current_type == null) {
                    // Likely `(expr)`
                    // Look for the corresponding .r_paren to form a slice of the contents
                    var paren_count: usize = 1;
                    var next = tokenizer.next();
                    while (next.tag != .eof) : (next = tokenizer.next()) {
                        if (next.tag == .r_paren) {
                            paren_count -= 1;
                            if (paren_count == 0) break;
                        } else if (next.tag == .l_paren) {
                            paren_count += 1;
                        }
                    } else return null;
                    current_type = try getFieldAccessType(
                        analyser,
                        handle,
                        source_index,
                        .{
                            // tok.loc and next.loc are offsets within held_range,
                            // add to loc.start to get offsets within handle.tree.source
                            .start = loc.start + tok.loc.end,
                            .end = loc.start + next.loc.start,
                        },
                    ) orelse return null;
                    continue;
                }

                const ty = try analyser.resolveFuncProtoOfCallable(current_type.?) orelse return null;

                // Can't call a function type, we need a function type instance.
                if (current_type.?.is_type_val) return null;

                // TODO Actually bind params here when calling functions instead of just skipping args.
                current_type = try analyser.resolveReturnType(ty) orelse return null;

                if (do_unwrap_error_payload) {
                    if (try analyser.resolveUnwrapErrorUnionType(current_type.?, .payload)) |unwrapped| current_type = unwrapped;
                    do_unwrap_error_payload = false;
                }

                // Skip to the right paren
                var paren_count: usize = 1;
                var next = tokenizer.next();
                while (next.tag != .eof) : (next = tokenizer.next()) {
                    if (next.tag == .r_paren) {
                        paren_count -= 1;
                        if (paren_count == 0) break;
                    } else if (next.tag == .l_paren) {
                        paren_count += 1;
                    }
                } else return null;
            },
            .l_bracket => {
                var bracket_count: usize = 1;
                var kind: BracketAccess = .{ .single = null };

                while (true) {
                    const token = tokenizer.next();
                    switch (token.tag) {
                        .eof => return null,
                        .r_bracket => {
                            bracket_count -= 1;
                            if (bracket_count == 0) break;
                        },
                        .l_bracket => {
                            bracket_count += 1;
                        },
                        .ellipsis2 => {
                            if (bracket_count == 1) {
                                kind = .{ .open = .{ .start = null, .sentinel = .none } };
                            }
                        },
                        else => {
                            if (bracket_count == 1 and kind == .open) {
                                kind = .{ .range = .{ .bounds = null, .sentinel = .none } };
                            }
                        },
                    }
                } else unreachable;

                current_type = (try analyser.resolveBracketAccessType(current_type orelse return null, kind)) orelse return null;
            },
            .builtin => {
                const binfn_name = tokenizer.buffer[tok.loc.start..tok.loc.end];

                if (std.mem.eql(u8, binfn_name, "@import")) {
                    if (tokenizer.next().tag != .l_paren) return null;
                    const import_str_tok = tokenizer.next(); // should be the .string_literal
                    if (import_str_tok.tag != .string_literal) return null;
                    if (import_str_tok.loc.end - import_str_tok.loc.start < 2) return null;
                    const import_str = offsets.locToSlice(tokenizer.buffer, .{
                        .start = import_str_tok.loc.start + 1,
                        .end = import_str_tok.loc.end - 1,
                    });
                    current_type = try analyser.resolveImportString(handle, import_str) orelse return null;
                    _ = tokenizer.next(); // eat the .r_paren
                    continue; // Outermost `while`
                }

                if (std.mem.eql(u8, binfn_name, "@typeInfo")) {
                    current_type = try analyser.instanceStdBuiltinType("Type") orelse return null;
                    // Skip to the right paren
                    var paren_count: usize = 0;
                    var next = tokenizer.next();
                    while (next.tag != .eof) : (next = tokenizer.next()) {
                        if (next.tag == .r_paren) {
                            paren_count -= 1;
                            if (paren_count == 0) break;
                        } else if (next.tag == .l_paren) {
                            paren_count += 1;
                        }
                    } else return null;
                    continue; // Outermost `while`
                }

                log.debug("Unhandled builtin: {s}", .{offsets.locToSlice(tokenizer.buffer, tok.loc)});
                return null;
            },
            // only hit when `(try foo())` otherwise getPositionContext never includes the `try` keyword
            .keyword_try => do_unwrap_error_payload = true,
            .l_brace => {
                var brace_count: usize = 1;
                var next = tokenizer.next();
                while (next.tag != .eof) : (next = tokenizer.next()) {
                    if (next.tag == .r_brace) {
                        brace_count -= 1;
                        if (brace_count == 0) break;
                    } else if (next.tag == .l_brace) {
                        brace_count += 1;
                    }
                } else return null;
                if (current_type) |ct| {
                    if (ct.isStructType(analyser) or ct.isUnionType()) {
                        // struct initialization
                        current_type = try ct.instanceTypeVal(analyser);
                    }
                }
            },
            else => {
                log.debug("Unimplemented token: {}", .{tok.tag});
                return null;
            },
        }
    }

    return current_type;
}

pub const PositionContext = union(enum) {
    builtin: offsets.Loc,
    import_string_literal: offsets.Loc,
    cinclude_string_literal: offsets.Loc,
    embedfile_string_literal: offsets.Loc,
    string_literal: offsets.Loc,
    field_access: offsets.Loc,
    var_access: offsets.Loc,
    /// `break :blk`
    /// `continue :blk`
    label_access: offsets.Loc,
    /// - `blk: {`
    /// - `blk: for`
    /// - `blk: while`
    /// - `blk: switch`
    label_decl: offsets.Loc,
    test_doctest_name: offsets.Loc,
    enum_literal: offsets.Loc,
    number_literal: offsets.Loc,
    char_literal: offsets.Loc,
    /// XXX: Internal use only, currently points to the loc of the first l_paren
    parens_expr: offsets.Loc,
    keyword: Ast.TokenIndex,
    error_access: offsets.Loc,
    comment,
    other,
    empty,

    pub fn loc(self: PositionContext, tree: *const Ast) ?offsets.Loc {
        return switch (self) {
            .builtin,
            .import_string_literal,
            .cinclude_string_literal,
            .embedfile_string_literal,
            .string_literal,
            .field_access,
            .var_access,
            .label_access,
            .label_decl,
            .test_doctest_name,
            .enum_literal,
            .number_literal,
            .char_literal,
            .parens_expr,
            => |l| return l,
            .keyword => |token_index| return offsets.tokenToLoc(tree, token_index),
            .error_access,
            .comment,
            .other,
            .empty,
            => return null,
        };
    }

    /// Asserts that `self` is one of the following:
    ///  - `.import_string_literal`
    ///  - `.cinclude_string_literal`
    ///  - `.embedfile_string_literal`
    ///  - `.string_literal`
    pub fn stringLiteralContentLoc(self: PositionContext, source: []const u8) offsets.Loc {
        var location = switch (self) {
            .import_string_literal,
            .cinclude_string_literal,
            .embedfile_string_literal,
            .string_literal,
            => |l| l,
            else => unreachable,
        };

        const string_literal_slice = offsets.locToSlice(source, location);
        if (std.mem.startsWith(u8, string_literal_slice, "\"")) {
            location.start += 1;
            if (std.mem.endsWith(u8, string_literal_slice[1..], "\"")) {
                location.end -= 1;
            }
            location.end = std.mem.findAnyPos(u8, source, location.start, &.{ '\n', '"' }) orelse source.len;
        } else if (std.mem.startsWith(u8, string_literal_slice, "\\")) {
            location.start += 2;
            location.end = std.mem.findScalarPos(u8, source, location.start, '\n') orelse source.len;
        }
        return location;
    }
};

const Stack = struct {
    states: std.ArrayList(State),

    const State = struct {
        ctx: PositionContext,
        scope: State.Scope,

        const Scope = enum { parens, brackets, braces, global };

        /// Indicates whether the current context is an ErrorSet definition, ie `error{...}`
        pub fn isErrSetDef(self: *Stack.State) bool {
            return (self.scope == .braces and self.ctx == .error_access);
        }
    };

    pub fn initCapacity(allocator: std.mem.Allocator, capacity: usize) error{OutOfMemory}!Stack {
        std.debug.assert(capacity > 0); // See `peek`.
        return .{ .states = try .initCapacity(allocator, capacity) };
    }

    pub fn deinit(self: *Stack, allocator: std.mem.Allocator) void {
        self.states.deinit(allocator);
    }

    pub fn push(self: *Stack, allocator: std.mem.Allocator, state: *const State) error{OutOfMemory}!void {
        try self.states.append(allocator, state.*);
    }

    pub fn peek(self: *Stack) *Stack.State {
        if (self.states.items.len == 0) {
            self.states.appendAssumeCapacity(.{ .ctx = .empty, .scope = .global });
        }
        return &self.states.items[self.states.items.len - 1];
    }

    /// Pops the last state off the stack. Sets previous state's ctx to .empty if !scopes_match
    pub fn pop(
        self: *Stack,
        /// Indicate whether the current state's scope matches the one being closed
        scopes_match: bool,
    ) void {
        if (self.states.items.len != 0) self.states.items.len -= 1;
        if (!scopes_match) self.peek().ctx = .empty;
    }
};

fn tokenLocAppend(prev: offsets.Loc, token: std.zig.Token) offsets.Loc {
    return .{
        .start = prev.start,
        .end = token.loc.end,
    };
}

/// Given a byte index in a document (typically cursor offset), classify what kind of entity is at that index.
///
/// Classification is based on the lexical structure -- we fetch the line containing index, and look at the
/// sequence of tokens just before the cursor. Due to the nice way zig is designed (only line comments, etc)
/// lexing just a single line is always correct.
pub fn getPositionContext(
    allocator: std.mem.Allocator,
    tree: *const Ast,
    source_index: usize,
    /// Should we look beyond the `source_index`? `false` for completions, `true` otherwise (hover, goto, etc.)
    lookahead: bool,
) error{OutOfMemory}!PositionContext {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    var line_loc = if (lookahead) offsets.lineLocAtIndex(tree.source, source_index) else offsets.lineLocUntilIndex(tree.source, source_index);

    if (std.mem.startsWith(u8, std.mem.trimStart(u8, offsets.locToSlice(tree.source, line_loc), " \t"), "//")) return .comment;

    // Check if the (trimmed) line starts with a '.', ie a continuation
    while (line_loc.start > 0) {
        while (std.mem.startsWith(u8, std.mem.trimStart(u8, offsets.locToSlice(tree.source, line_loc), " \t\r"), ".")) {
            if (line_loc.start > 1) {
                line_loc.start -= 2; // jump over a (potential) preceding '\n'
            } else break;
            while (line_loc.start > 0) : (line_loc.start -= 1) {
                if (tree.source[line_loc.start] == '\n') {
                    line_loc.start += 1; // eat the `\n`
                    break;
                }
            } else break;
        }
        if (line_loc.start != 0 and std.mem.startsWith(u8, std.mem.trimStart(u8, offsets.locToSlice(tree.source, line_loc), " \t"), "//")) {
            const prev_line_loc = offsets.lineLocAtIndex(tree.source, line_loc.start - 1); // `- 1` => prev line's `\n`
            line_loc.start = prev_line_loc.start;
            continue;
        }
        break;
    }

    // Check if the previous line ends with a ',', ie a continuation - targets multiline ErrorSet definitions
    var lloc = line_loc;
    while (true) {
        while (lloc.start > 0) {
            if (tree.source[lloc.start] != '\n') lloc.start -= 1 else break;
        } else break;
        while (lloc.start > 0 and tree.source[lloc.start] == '\n') lloc.start -= 1;
        if (lloc.start == 0) break;
        lloc = offsets.lineLocAtIndex(tree.source, lloc.start);
        // Check if it's a comment first
        while (lloc.start > 0 and std.mem.startsWith(u8, std.mem.trimStart(u8, offsets.locToSlice(tree.source, lloc), " \t"), "//")) {
            const prev_line_loc = offsets.lineLocAtIndex(tree.source, lloc.start - 1); // `- 1` => prev line's `\n`
            lloc = prev_line_loc;
        }
        if (std.mem.endsWith(u8, std.mem.trimEnd(u8, offsets.locToSlice(tree.source, lloc), " \t\r\n"), ",")) continue;
        line_loc.start = lloc.start;
        break;
    }

    var stack: Stack = try .initCapacity(allocator, 8);
    defer stack.deinit(allocator);
    var should_do_lookahead = lookahead;

    var current_token = offsets.sourceIndexToTokenIndex(tree, line_loc.start).preferLeft();
    var previous_token_end = line_loc.start;

    while (true) : (current_token += 1) {
        var tok: std.zig.Token = .{
            .tag = tree.tokenTag(current_token),
            .loc = offsets.tokenToLoc(tree, current_token),
        };
        tok.loc.end = @min(tok.loc.end, line_loc.end);
        defer previous_token_end = tok.loc.end;

        // Single '@' do not return a builtin token so we check this on our own.
        if (tok.tag == .invalid and tree.source[tok.loc.start] == '@') {
            if (std.mem.startsWith(u8, tree.source[tok.loc.start..], "@\"")) {
                tok.tag = .identifier;
                tok.loc = .{ .start = tok.loc.start, .end = @min(line_loc.end, tree.tokenStart(current_token + 1)) };
            } else if (std.mem.startsWith(u8, tree.source[tok.loc.start..], "@")) {
                tok.tag = .builtin;
                tok.loc = .{ .start = tok.loc.start, .end = tok.loc.start + 1 };
            }
        }

        if (source_index < tok.loc.start) break;
        if (source_index == tok.loc.start) {
            // Tie-breaking, the cursor is exactly between two tokens, and
            // `tok` is the latter of the two.
            if (!should_do_lookahead) break;
            should_do_lookahead = false;
            const curr_ctx = stack.peek();
            switch (tok.tag) {
                .identifier,
                .builtin,
                .number_literal,
                .string_literal,
                .multiline_string_literal_line,
                => {},
                .period => switch (curr_ctx.ctx) {
                    .empty => {},
                    else => if (previous_token_end == tok.loc.start) break,
                },
                else => if (previous_token_end == tok.loc.start) break,
            }
        }

        switch (tok.tag) {
            .invalid => {
                const s = tree.source[tok.loc.start..tok.loc.end];
                const q = std.mem.find(u8, s, "\"") orelse return .other;
                if (s[q -| 1] == '@') {
                    tok.tag = .identifier;
                } else {
                    tok.tag = .string_literal;
                }
            },
            .eof => break,
            else => {},
        }

        const curr_ctx: *Stack.State = stack.peek();
        defer switch (stack.peek().ctx) {
            .field_access => |*loc| loc.* = tokenLocAppend(loc.*, tok),
            else => {},
        };
        const new_state: PositionContext = switch (tok.tag) {
            .multiline_string_literal_line => .{ .string_literal = tok.loc },
            .string_literal,
            => new_state: {
                const string_literal_slice = offsets.locToSlice(tree.source, tok.loc);
                var content_loc = tok.loc;

                if (std.mem.startsWith(u8, string_literal_slice, "\"")) {
                    content_loc.start += 1;
                    if (std.mem.endsWith(u8, string_literal_slice[1..], "\"")) {
                        content_loc.end -= 1;
                    }
                }

                var new_state: PositionContext = .{ .string_literal = tok.loc };
                if (source_index < content_loc.start or content_loc.end < source_index) break :new_state new_state;

                if (curr_ctx.scope == .parens and
                    stack.states.items.len >= 2)
                {
                    const perhaps_builtin = stack.states.items[stack.states.items.len - 2];

                    switch (perhaps_builtin.ctx) {
                        .builtin => |loc| {
                            const builtin_name = tree.source[loc.start..loc.end];
                            if (std.mem.eql(u8, builtin_name, "@import")) {
                                new_state = .{ .import_string_literal = tok.loc };
                            } else if (std.mem.eql(u8, builtin_name, "@cInclude")) {
                                new_state = .{ .cinclude_string_literal = tok.loc };
                            } else if (std.mem.eql(u8, builtin_name, "@embedFile")) {
                                new_state = .{ .embedfile_string_literal = tok.loc };
                            }
                        },
                        else => {},
                    }
                }
                break :new_state new_state;
            },
            .identifier => if (curr_ctx.isErrSetDef())
                continue // Intent is to skip everything between the `error{...}` braces
            else switch (curr_ctx.ctx) {
                .enum_literal => |loc| .{ .enum_literal = tokenLocAppend(loc, tok) },
                .field_access => |loc| .{ .field_access = tokenLocAppend(loc, tok) },
                .label_access => |loc| if (loc.start == loc.end)
                    .{ .label_access = tok.loc }
                else
                    .{ .var_access = tok.loc },
                .test_doctest_name => .{ .test_doctest_name = tok.loc },
                else => .{ .var_access = tok.loc },
            },
            .builtin => .{ .builtin = tok.loc },
            .period => switch (curr_ctx.ctx) {
                .empty, .label_access => .{ .enum_literal = tok.loc },
                .enum_literal => .empty,
                .keyword => |token_index| switch (tree.tokenTag(token_index)) {
                    .keyword_break => .{ .enum_literal = tok.loc },
                    else => .other,
                },
                .comment, .other, .error_access => curr_ctx.ctx,
                .test_doctest_name, .var_access, .field_access => |loc| .{ .field_access = tokenLocAppend(loc, tok) },
                else => .{ .field_access = tokenLocAppend(curr_ctx.ctx.loc(tree) orelse tok.loc, tok) },
            },
            .period_asterisk => .{ .field_access = tokenLocAppend(curr_ctx.ctx.loc(tree) orelse tok.loc, tok) },
            .question_mark => switch (curr_ctx.ctx) {
                .field_access => |loc| .{ .field_access = tokenLocAppend(loc, tok) },
                else => .empty,
            },
            .colon => switch (curr_ctx.ctx) {
                .keyword => |token_index| switch (tree.tokenTag(token_index)) {
                    .keyword_break,
                    .keyword_continue,
                    => .{ .label_access = .{ .start = tok.loc.end, .end = tok.loc.end } },
                    else => .empty,
                },
                else => .empty,
            },
            .l_paren => {
                if (curr_ctx.ctx == .empty) curr_ctx.ctx = .{ .parens_expr = tok.loc };
                const scope: Stack.State.Scope = if (curr_ctx.ctx == .keyword) switch (tree.tokenTag(curr_ctx.ctx.keyword)) {
                    .keyword_for,
                    .keyword_if,
                    .keyword_while,
                    => .global,
                    else => .parens,
                } else .parens;
                try stack.push(allocator, &.{ .ctx = .empty, .scope = scope });
                continue;
            },
            .r_paren => {
                stack.pop(curr_ctx.scope == .parens);
                continue;
            },
            .l_bracket => {
                try stack.push(allocator, &.{ .ctx = .empty, .scope = .brackets });
                continue;
            },
            .r_bracket => {
                stack.pop(curr_ctx.scope == .brackets);
                continue;
            },
            .l_brace => {
                try stack.push(allocator, &.{ .ctx = if (curr_ctx.ctx == .error_access) curr_ctx.ctx else .empty, .scope = .braces });
                continue;
            },
            .r_brace => {
                stack.pop(curr_ctx.scope == .braces);
                continue;
            },
            .keyword_error => .{ .error_access = tok.loc },
            .number_literal => {
                if (tok.loc.start <= source_index and tok.loc.end >= source_index) {
                    return .{ .number_literal = tok.loc };
                }
                continue;
            },
            .char_literal => {
                if (tok.loc.start <= source_index and tok.loc.end >= source_index) {
                    return .{ .char_literal = tok.loc };
                }
                continue;
            },
            .keyword_addrspace,
            .keyword_break,
            .keyword_callconv,
            .keyword_continue,
            .keyword_for,
            .keyword_if,
            .keyword_switch,
            .keyword_while,
            => |tag| new_state: {
                std.debug.assert(tree.tokenTag(current_token) == tag);
                break :new_state .{ .keyword = current_token };
            },
            .keyword_test => .{ .test_doctest_name = .{ .start = tok.loc.end, .end = tok.loc.end } },
            .container_doc_comment => .comment,
            .doc_comment => new_state: {
                if (!curr_ctx.isErrSetDef()) break :new_state .comment; // Intent is to skip everything between the `error{...}` braces
                continue;
            },
            .comma => new_state: {
                if (!curr_ctx.isErrSetDef()) break :new_state .empty; // Intent is to skip everything between the `error{...}` braces
                continue;
            },
            else => .empty,
        };
        curr_ctx.ctx = new_state;
    }

    if (stack.states.pop()) |state| {
        switch (state.ctx) {
            .parens_expr => |loc| return .{ .var_access = loc },
            .var_access => |loc| {
                if (tree.tokenTag(current_token) == .colon) {
                    switch (tree.tokenTag(current_token + 1)) {
                        .l_brace,
                        .keyword_for,
                        .keyword_while,
                        .keyword_switch,
                        => return .{ .label_decl = loc },
                        else => {},
                    }
                }
                return state.ctx;
            },
            else => return state.ctx,
        }
    }

    return .empty;
}

pub const TokenToTypeMap = std.array_hash_map.Custom(TokenWithHandle, Type, TokenWithHandle.Context, true);

pub const TokenWithHandle = struct {
    token: Ast.TokenIndex,
    handle: *DocumentStore.Handle,

    pub fn hashWithHasher(token_handle: TokenWithHandle, hasher: anytype) void {
        std.hash.autoHash(hasher, token_handle.token);
        hasher.update(token_handle.handle.uri.raw);
    }

    pub fn eql(a: TokenWithHandle, b: TokenWithHandle) bool {
        if (a.token != b.token) return false;
        if (!a.handle.uri.eql(b.handle.uri)) return false;
        return true;
    }

    const Context = struct {
        pub fn hash(self: Context, token_handle: TokenWithHandle) u32 {
            _ = self;
            var hasher: std.hash.Wyhash = .init(0);
            token_handle.hashWithHasher(&hasher);
            return @truncate(hasher.final());
        }

        pub fn eql(self: Context, a: TokenWithHandle, b: TokenWithHandle, b_index: usize) bool {
            _ = self;
            _ = b_index;
            return a.eql(b);
        }
    };
};

pub const DeclWithHandle = struct {
    decl: Declaration,
    handle: *DocumentStore.Handle,
    container_type: ?Type = null,

    pub fn eql(a: DeclWithHandle, b: DeclWithHandle) bool {
        return a.decl.eql(b.decl) and a.handle.uri.eql(b.handle.uri);
    }

    /// Returns a `.identifier` or `.builtin` token.
    pub fn nameToken(self: DeclWithHandle) Ast.TokenIndex {
        return self.decl.nameToken(&self.handle.tree);
    }

    pub fn definitionToken(self: DeclWithHandle, analyser: *Analyser, resolve_alias: bool) Error!TokenWithHandle {
        if (resolve_alias) {
            if (try analyser.resolveVarDeclAlias(self)) |result| {
                return result.definitionToken(analyser, resolve_alias);
            }
            if (try self.resolveType(analyser)) |resolved_type| {
                if (resolved_type.is_type_val) {
                    if (resolved_type.typeDefinitionToken()) |token| {
                        return token;
                    }
                }
            }
        }
        return .{ .token = self.nameToken(), .handle = self.handle };
    }

    pub fn typeDeclarationNode(self: DeclWithHandle) error{OutOfMemory}!?NodeWithHandle {
        const tree = &self.handle.tree;
        switch (self.decl) {
            .ast_node => |node| switch (tree.nodeTag(node)) {
                .global_var_decl,
                .local_var_decl,
                .simple_var_decl,
                .aligned_var_decl,
                => {
                    const var_decl = tree.fullVarDecl(node).?;
                    const type_node = var_decl.ast.type_node.unwrap() orelse return null;
                    return .of(type_node, self.handle);
                },
                .container_field_init,
                .container_field_align,
                .container_field,
                => {
                    const container_field = tree.fullContainerField(node).?;
                    const type_expr = container_field.ast.type_expr.unwrap() orelse return null;
                    return .of(type_expr, self.handle);
                },
                .fn_proto,
                .fn_proto_multi,
                .fn_proto_one,
                .fn_proto_simple,
                .fn_decl,
                => return null,
                else => unreachable,
            },
            .assign_destructure => |payload| {
                const var_decl = payload.getFullVarDecl(tree);
                const type_node = var_decl.ast.type_node.unwrap() orelse return null;
                return .of(type_node, self.handle);
            },
            .function_parameter => |payload| {
                const param = payload.get(tree).?;
                const type_expr = param.type_expr orelse return null;
                return .of(type_expr, self.handle);
            },
            .optional_payload,
            .error_union_payload,
            .error_union_error,
            .for_loop_payload,
            .switch_payload,
            .switch_inline_tag_payload,
            => return null, // the payloads can't have a type specifier

            .label,
            .error_token,
            => return null,
        }
    }

    pub fn isConst(self: DeclWithHandle) bool {
        const tree = &self.handle.tree;
        return switch (self.decl) {
            .ast_node => |node| switch (tree.nodeTag(node)) {
                .global_var_decl,
                .local_var_decl,
                .aligned_var_decl,
                .simple_var_decl,
                => {
                    const mut_token = tree.fullVarDecl(node).?.ast.mut_token;
                    switch (tree.tokenTag(mut_token)) {
                        .keyword_var => return false,
                        .keyword_const => return true,
                        else => unreachable,
                    }
                },
                .container_field,
                .container_field_init,
                .container_field_align,
                .fn_proto,
                .fn_proto_multi,
                .fn_proto_one,
                .fn_proto_simple,
                .fn_decl,
                => true,
                else => unreachable,
            },
            .assign_destructure => |payload| {
                const mut_token = payload.getFullVarDecl(tree).ast.mut_token;
                switch (tree.tokenTag(mut_token)) {
                    .keyword_var => return false,
                    .keyword_const => return true,
                    else => unreachable,
                }
            },
            // some payload may be capture by ref but the pointer value is constant
            .function_parameter,
            .optional_payload,
            .for_loop_payload,
            .error_union_payload,
            .error_union_error,
            .switch_payload,
            .switch_inline_tag_payload,
            .label,
            .error_token,
            => true,
        };
    }

    pub fn isCaptureByRef(self: DeclWithHandle) bool {
        const tree = &self.handle.tree;
        return switch (self.decl) {
            .ast_node,
            .function_parameter,
            .error_union_error,
            .assign_destructure,
            .label,
            .error_token,
            .switch_inline_tag_payload,
            => false,
            inline .optional_payload,
            .for_loop_payload,
            .error_union_payload,
            => |payload| tree.tokenTag(payload.identifier - 1) == .asterisk,
            .switch_payload => |payload| tree.tokenTag(payload.getCase(tree).payload_token.?) == .asterisk,
        };
    }

    pub fn docComments(self: DeclWithHandle, allocator: std.mem.Allocator) error{OutOfMemory}!?[]const u8 {
        const tree = &self.handle.tree;
        return switch (self.decl) {
            .ast_node => |node| try getDocComments(allocator, tree, node),
            .function_parameter => |pay| {
                const param = pay.get(tree).?;
                const doc_comments = param.first_doc_comment orelse return null;
                return try collectDocComments(allocator, tree, doc_comments, false);
            },
            .error_token => |token| try getDocCommentsBeforeToken(allocator, tree, token),
            else => null,
        };
    }

    pub fn isPublic(self: DeclWithHandle) bool {
        const tree = self.handle.tree;
        var buf: [1]Ast.Node.Index = undefined;
        return switch (self.decl) {
            .ast_node => |node| switch (tree.nodeTag(node)) {
                .global_var_decl,
                .local_var_decl,
                .simple_var_decl,
                .aligned_var_decl,
                => tree.fullVarDecl(node).?.visib_token != null,
                .fn_proto,
                .fn_proto_multi,
                .fn_proto_one,
                .fn_proto_simple,
                .fn_decl,
                => tree.fullFnProto(&buf, node).?.visib_token != null,
                .container_field,
                .container_field_init,
                .container_field_align,
                => true,
                else => unreachable,
            },
            else => true,
        };
    }

    pub fn isStatic(self: DeclWithHandle) error{OutOfMemory}!bool {
        const tree = &self.handle.tree;
        return switch (self.decl) {
            .ast_node => |node| switch (tree.nodeTag(node)) {
                .global_var_decl,
                .local_var_decl,
                .simple_var_decl,
                .aligned_var_decl,
                => blk: {
                    const document_scope = try self.handle.getDocumentScope();
                    const token_index = tree.nodeMainToken(node);
                    const source_index = tree.tokenStart(token_index);
                    const scope_index = Analyser.innermostScopeAtIndex(document_scope, source_index);
                    break :blk document_scope.getScopeTag(scope_index).isContainer();
                },
                .container_field,
                .container_field_init,
                .container_field_align,
                .fn_proto,
                .fn_proto_multi,
                .fn_proto_one,
                .fn_proto_simple,
                .fn_decl,
                => false,
                else => unreachable,
            },
            else => false,
        };
    }

    pub fn resolveType(self: DeclWithHandle, analyser: *Analyser) Error!?Type {
        const tracy_zone = tracy.trace(@src());
        defer tracy_zone.end();

        const tree = &self.handle.tree;
        var resolved_ty = switch (self.decl) {
            .ast_node => |node| try analyser.resolveTypeOfNodeInternal(.{
                .node_handle = .of(node, self.handle),
                .container_type = self.container_type,
            }),
            .function_parameter => |pay| blk: {
                // the `get` function never fails on declarations from the DocumentScope but
                // there may be manually created Declarations with invalid parameter indices.
                const param = pay.get(tree) orelse return null;

                // handle anytype
                const type_expr = param.type_expr orelse {
                    const anytype_token = param.anytype_ellipsis3 orelse return null;
                    if (tree.tokenTag(anytype_token) != .keyword_anytype) return null;
                    const ty = try analyser.resolveCallsiteReferences(self);
                    break :blk Type{
                        .data = .{
                            .anytype_parameter = .{
                                .token_handle = .{ .token = anytype_token, .handle = self.handle },
                                .type_from_callsite_references = if (ty) |t| try analyser.allocType(t) else null,
                            },
                        },
                        .is_type_val = false,
                    };
                };

                const param_type = try analyser.resolveTypeOfNodeInternal(.of(type_expr, self.handle)) orelse return null;

                if (param_type.isMetaType()) {
                    const name_token = self.decl.nameToken(tree);
                    break :blk Type{
                        .data = .{ .type_parameter = .{ .token = name_token, .handle = self.handle } },
                        .is_type_val = true,
                    };
                }

                break :blk try param_type.instanceTypeVal(analyser);
            },
            .optional_payload => |pay| blk: {
                const ty = (try analyser.resolveTypeOfNodeInternal(.of(pay.condition, self.handle))) orelse return null;
                break :blk try analyser.resolveOptionalUnwrap(ty);
            },
            .error_union_payload => |pay| try analyser.resolveUnwrapErrorUnionType(
                (try analyser.resolveTypeOfNodeInternal(.of(pay.condition, self.handle))) orelse return null,
                .payload,
            ),
            .error_union_error => |pay| try analyser.resolveUnwrapErrorUnionType(
                (try analyser.resolveTypeOfNodeInternal(.of(
                    pay.condition.unwrap() orelse return null,
                    self.handle,
                ))) orelse return null,
                .error_set,
            ),
            .for_loop_payload => |pay| blk: {
                if (tree.nodeTag(pay.condition) == .for_range) {
                    break :blk Type.fromIP(analyser, .usize_type, null);
                }
                break :blk try analyser.resolveBracketAccessType(
                    (try analyser.resolveTypeOfNodeInternal(.of(pay.condition, self.handle))) orelse return null,
                    .{ .single = null },
                );
            },
            .assign_destructure => |pay| blk: {
                const var_decl = pay.getFullVarDecl(tree);
                if (var_decl.ast.type_node.unwrap()) |type_node| {
                    if (try analyser.resolveTypeOfNode(.of(type_node, self.handle))) |ty|
                        break :blk try ty.instanceTypeVal(analyser);
                }

                const init_node = tree.nodeData(pay.node).extra_and_node[1];
                const node = try analyser.resolveTypeOfNode(.of(init_node, self.handle)) orelse return null;
                if (node.is_type_val) return null;
                break :blk switch (node.data) {
                    .array => |array_info| try array_info.elem_ty.instanceTypeVal(analyser),
                    .tuple => try analyser.resolveBracketAccessType(node, .{ .single = pay.index }),
                    .ip_index => |payload| switch (analyser.ip.indexToKey(payload.type)) {
                        .vector_type => |vector_info| Type.fromIP(analyser, vector_info.child, null),
                        .array_type => |array_info| Type.fromIP(analyser, array_info.child, null),
                        .tuple_type => try analyser.resolveBracketAccessType(node, .{ .single = pay.index }),
                        else => null,
                    },
                    else => null,
                };
            },
            .label => |decl| try analyser.resolveTypeOfNodeInternal(.of(decl.block, self.handle)),
            .switch_payload,
            .switch_inline_tag_payload,
            => |payload| blk: {
                const cond = tree.nodeData(payload.node).node_and_extra[0];
                const case = payload.getCase(tree);

                const switch_expr_type: Type = (try analyser.resolveTypeOfNodeInternal(.of(cond, self.handle))) orelse return null;
                const switch_expr_type_type = try switch_expr_type.typeOf(analyser);
                if (switch_expr_type_type.ipIndex()) |type_index| {
                    const type_tag = analyser.ip.zigTypeTag(type_index);
                    if (type_tag == .null or type_tag == .undefined) return null;
                }

                if (self.decl == .switch_inline_tag_payload) {
                    return try analyser.resolveUnionTag(switch_expr_type_type);
                }

                if (switch_expr_type.isEnumType()) break :blk switch_expr_type;
                if (!switch_expr_type.isUnionType()) return switch_expr_type;

                if (case.ast.values.len == 0) {
                    if (case.inline_token == null) {
                        return switch_expr_type;
                    }
                }
                break :blk try analyser.resolveSwitchUnionPayload(switch_expr_type, tree, tree.switchFull(payload.node), case);
            },
            .error_token => return null,
        } orelse return null;

        if (self.container_type) |container_ty| {
            switch (container_ty.data) {
                .container => |info| {
                    resolved_ty = try analyser.resolveGenericType(resolved_ty, info.bound_params);
                },
                else => {},
            }
        }

        if (!self.isCaptureByRef()) return resolved_ty;

        const elem_ty = try resolved_ty.typeOf(analyser);
        const pointer_ty = try Type.createPointerType(analyser, .one, .none, false, elem_ty);
        return try pointer_ty.instanceUnchecked(analyser);
    }
};

/// Collects all symbols/declarations that can be a accessed on the given container type.
pub fn collectDeclarationsOfContainer(
    analyser: *Analyser,
    /// A container type (i.e. `struct`, `union`, `enum`, `opaque`)
    container_type: Type,
    original_handle: *DocumentStore.Handle,
    /// Whether or not the container type is a instance of its type.
    /// ```zig
    /// const NotInstance = struct{};
    /// const instance = @as(struct{}, ...);
    /// ```
    instance_access: bool,
    /// allocated with `analyser.arena`
    decl_collection: *std.ArrayList(DeclWithHandle),
) Analyser.Error!void {
    const info = switch (container_type.data) {
        .container => |info| info,
        .either => |entries| {
            for (entries) |entry| {
                const ty: Type = .{ .data = entry.type_data, .is_type_val = container_type.is_type_val };
                try analyser.collectDeclarationsOfContainer(ty, original_handle, instance_access, decl_collection);
            }
            return;
        },
        else => return,
    };
    const container_scope = info.scope_handle;
    const scope = container_scope.scope;
    const handle = container_scope.handle;

    const tree = &handle.tree;
    const document_scope = try handle.getDocumentScope();
    const container_node = container_scope.toNode();
    const main_token = tree.nodeMainToken(container_node);

    const is_enum = tree.tokenTag(main_token) == .keyword_enum;

    const scope_decls = document_scope.getScopeDeclarationsConst(scope);

    for (scope_decls) |decl_index| {
        const decl = document_scope.declarations.get(@intFromEnum(decl_index));
        const decl_with_handle: DeclWithHandle = .{ .decl = decl, .handle = handle, .container_type = container_type };
        if (handle != original_handle and !decl_with_handle.isPublic()) continue;

        switch (decl) {
            .ast_node => |node| switch (tree.nodeTag(node)) {
                .container_field_init,
                .container_field_align,
                .container_field,
                => {
                    if (is_enum) {
                        if (instance_access) continue;
                        const field_name = offsets.tokenToSlice(tree, tree.nodeMainToken(node));
                        if (std.mem.eql(u8, field_name, "_")) continue;
                    } else {
                        if (!instance_access) continue;
                    }
                },
                .fn_proto,
                .fn_proto_multi,
                .fn_proto_one,
                .fn_proto_simple,
                .fn_decl,
                .global_var_decl,
                .local_var_decl,
                .simple_var_decl,
                .aligned_var_decl,
                => {
                    if (instance_access) {
                        // allow declarations which evaluate to functions where
                        // the first parameter has the type of the container:
                        const alias_type = try decl_with_handle.resolveType(analyser) orelse continue;
                        const func_ty = try analyser.resolveFuncProtoOfCallable(alias_type) orelse continue;

                        if (!analyser.firstParamIs(func_ty, .{
                            .data = .{ .container = info },
                            .is_type_val = true,
                        })) continue;
                    }
                },
                else => unreachable,
            },
            .label => continue,
            else => {},
        }

        try decl_collection.append(analyser.arena, decl_with_handle);
    }
}

/// Collects all symbols/declarations that are accessible at the given source index.
pub fn collectAllSymbolsAtSourceIndex(
    analyser: *Analyser,
    /// a handle to a Document
    handle: *DocumentStore.Handle,
    /// a byte-index into `handle.tree.source`
    source_index: usize,
    /// allocated with `analyser.arena`
    decl_collection: *std.ArrayList(DeclWithHandle),
) error{OutOfMemory}!void {
    std.debug.assert(source_index <= handle.tree.source.len);

    const document_scope = try handle.getDocumentScope();
    var scope_iterator = iterateEnclosingScopes(document_scope, source_index);
    while (scope_iterator.next().unwrap()) |scope_index| {
        const scope_decls = document_scope.getScopeDeclarationsConst(scope_index);
        for (scope_decls) |decl_index| {
            const decl = document_scope.declarations.get(@intFromEnum(decl_index));
            if (decl == .ast_node and handle.tree.nodeTag(decl.ast_node).isContainerField()) continue;
            if (decl == .label) continue;
            try decl_collection.append(analyser.arena, .{ .decl = decl, .handle = handle });
        }
    }
}

pub const EnclosingScopeIterator = struct {
    document_scope: *const DocumentScope,
    current_scope: Scope.OptionalIndex,
    source_index: usize,

    pub fn next(self: *EnclosingScopeIterator) Scope.OptionalIndex {
        const current_scope = self.current_scope.unwrap() orelse return .none;
        const scopes = self.document_scope.getScopeChildScopesConst(current_scope);
        const scope_locs = self.document_scope.scopes.items(.loc);
        const result = self.current_scope;

        const Context = struct {
            scope_locs: []const DocumentScope.Scope.SmallLoc,
            source_index: usize,

            fn compare(ctx: @This(), scope_index: Scope.Index) std.math.Order {
                const child_scope = ctx.scope_locs[@intFromEnum(scope_index)];
                if (ctx.source_index < child_scope.start) return .lt;
                if (child_scope.end < ctx.source_index) return .gt;
                return .eq;
            }
        };

        self.current_scope = if (std.sort.binarySearch(
            Scope.Index,
            scopes,
            Context{ .scope_locs = scope_locs, .source_index = self.source_index },
            Context.compare,
        )) |scope_index| scopes[scope_index].toOptional() else .none;

        return result;
    }
};

fn iterateEnclosingScopes(document_scope: *const DocumentScope, source_index: usize) EnclosingScopeIterator {
    return .{
        .document_scope = document_scope,
        .current_scope = .root,
        .source_index = source_index,
    };
}

pub fn iterateLabels(handle: *DocumentStore.Handle, source_index: usize, comptime callback: anytype, context: anytype) error{OutOfMemory}!void {
    const document_scope = try handle.getDocumentScope();
    var scope_iterator = iterateEnclosingScopes(document_scope, source_index);
    while (scope_iterator.next().unwrap()) |scope_index| {
        for (document_scope.getScopeDeclarationsConst(scope_index)) |decl_index| {
            const decl = document_scope.declarations.get(@intFromEnum(decl_index));
            if (decl != .label) continue;
            try callback(context, .{ .decl = decl, .handle = handle });
        }
    }
}

pub fn innermostScopeAtIndex(
    document_scope: *const DocumentScope,
    source_index: usize,
) Scope.Index {
    return innermostScopeAtIndexWithTag(document_scope, source_index, .full).unwrap().?;
}

pub fn innermostScopeAtIndexWithTag(
    document_scope: *const DocumentScope,
    source_index: usize,
    tag_filter: std.EnumSet(Scope.Tag),
) Scope.OptionalIndex {
    var scope_iterator = iterateEnclosingScopes(document_scope, source_index);
    var scope_index: Scope.OptionalIndex = .none;
    while (scope_iterator.next().unwrap()) |inner_scope| {
        const scope_tag = document_scope.getScopeTag(inner_scope);
        if (!tag_filter.contains(scope_tag)) continue;
        scope_index = inner_scope.toOptional();
    }
    return scope_index;
}

pub fn innermostContainer(analyser: *Analyser, handle: *DocumentStore.Handle, source_index: usize) error{OutOfMemory}!Type {
    const tree = &handle.tree;
    const document_scope = try handle.getDocumentScope();
    if (document_scope.scopes.len == 1) return .{
        .data = .{ .container = .root(handle) },
        .is_type_val = true,
    };

    var pending_meta_params: TokenToTypeMap = .empty;
    defer pending_meta_params.deinit(analyser.gpa);

    var current: DocumentScope.Scope.Index = .root;
    var meta_params: TokenToTypeMap = .empty;
    var scope_iterator = iterateEnclosingScopes(document_scope, source_index);
    while (scope_iterator.next().unwrap()) |scope_index| {
        switch (document_scope.getScopeTag(scope_index)) {
            .container => {
                current = scope_index;
                for (pending_meta_params.keys(), pending_meta_params.values()) |token_handle, ty| {
                    try meta_params.put(analyser.arena, token_handle, ty);
                }
                pending_meta_params.clearRetainingCapacity();
            },
            .function => {
                const function_node = document_scope.getScopeAstNode(scope_index).?;
                var buf: [1]Ast.Node.Index = undefined;
                const func = tree.fullFnProto(&buf, function_node).?;
                var it: ast.FnParamIterator = .init(&func, tree);
                while (it.next()) |param| {
                    const param_name_token = param.name_token orelse continue;
                    const token_handle: TokenWithHandle = .{ .token = param_name_token, .handle = handle };
                    if (analyser.generic_bindings) |bindings| {
                        if (bindings.get(token_handle)) |bound| {
                            try pending_meta_params.put(analyser.gpa, token_handle, bound);
                            continue;
                        }
                    }

                    const param_type_expr = param.type_expr orelse continue;
                    const ty: Type = if (Analyser.isMetaType(tree, param_type_expr))
                        .{ .data = .{ .type_parameter = token_handle }, .is_type_val = true }
                    else blk: {
                        const modifier = param.comptime_noalias orelse continue;
                        if (tree.tokenTag(modifier) != .keyword_comptime) continue;
                        const param_ty = analyser.resolveTypeOfNode(.of(param_type_expr, handle)) catch |err| switch (err) {
                            error.Canceled => continue,
                            error.OutOfMemory => return error.OutOfMemory,
                        } orelse continue;
                        if (!param_ty.is_type_val) continue;
                        break :blk try param_ty.instanceTypeVal(analyser) orelse continue;
                    };
                    try pending_meta_params.put(analyser.gpa, token_handle, ty);
                }
            },
            else => {},
        }
    }
    return .{
        .data = .{
            .container = .{
                .scope_handle = .{
                    .handle = handle,
                    .scope = current,
                },
                .bound_params = meta_params,
            },
        },
        .is_type_val = true,
    };
}

pub fn lookupLabel(
    handle: *DocumentStore.Handle,
    symbol: []const u8,
    source_index: usize,
) error{OutOfMemory}!?DeclWithHandle {
    const document_scope = try handle.getDocumentScope();
    var scope_iterator = iterateEnclosingScopes(document_scope, source_index);
    while (scope_iterator.next().unwrap()) |scope_index| {
        const decl_index = document_scope.getScopeDeclaration(.{
            .scope = scope_index,
            .name = symbol,
            .kind = .label,
        }).unwrap() orelse continue;
        const decl = document_scope.declarations.get(@intFromEnum(decl_index));

        std.debug.assert(decl == .label);

        return .{ .decl = decl, .handle = handle };
    }
    return null;
}

pub fn lookupSymbolGlobal(
    _: *Analyser,
    handle: *DocumentStore.Handle,
    symbol: []const u8,
    source_index: usize,
) error{OutOfMemory}!?DeclWithHandle {
    const tree = &handle.tree;
    const document_scope = try handle.getDocumentScope();
    var current_scope = innermostScopeAtIndex(document_scope, source_index);

    while (true) {
        if (document_scope.getScopeDeclaration(.{
            .scope = current_scope,
            .name = symbol,
            .kind = .field,
        }).unwrap()) |decl_index| {
            const decl = document_scope.declarations.get(@intFromEnum(decl_index));
            std.debug.assert(decl == .ast_node);

            var field = tree.fullContainerField(decl.ast_node).?;
            field.convertToNonTupleLike(tree);

            const field_name = offsets.tokenToLoc(tree, field.ast.main_token);
            if (field_name.start <= source_index and source_index <= field_name.end) {
                return .{ .decl = decl, .handle = handle };
            }
        }

        if (document_scope.getScopeDeclaration(.{
            .scope = current_scope,
            .name = symbol,
            .kind = .other,
        }).unwrap()) |decl_index| {
            const decl = document_scope.declarations.get(@intFromEnum(decl_index));
            return .{ .decl = decl, .handle = handle };
        }

        current_scope = document_scope.getScopeParent(current_scope).unwrap() orelse break;
    }

    return null;
}

fn identifierTokenMatches(
    analyser: *Analyser,
    tree: *const Ast,
    token: Ast.TokenIndex,
    expected: []const u8,
) error{OutOfMemory}!bool {
    const name = try analyser.identifierTokenName(tree, token) orelse return false;
    return std.mem.eql(u8, name, expected);
}

fn identifierTokenName(
    analyser: *Analyser,
    tree: *const Ast,
    token: Ast.TokenIndex,
) error{OutOfMemory}!?[]const u8 {
    const raw = tree.tokenSlice(token);
    if (!std.mem.startsWith(u8, raw, "@\"")) return offsets.identifierTokenToNameSlice(tree, token);

    var discarding_writer: std.Io.Writer.Discarding = .init(&.{});
    const parsed = std.zig.string_literal.parseWrite(&discarding_writer.writer, raw[1..]) catch |err| switch (err) {
        error.WriteFailed => unreachable,
    };
    if (parsed != .success) return null;

    const decoded = try analyser.arena.alloc(u8, discarding_writer.count);
    var writer: std.Io.Writer = .fixed(decoded);
    const decoded_result = std.zig.string_literal.parseWrite(&writer, raw[1..]) catch |err| switch (err) {
        error.WriteFailed => unreachable,
    };
    if (decoded_result != .success) return null;
    return decoded;
}

fn areSameIdentifierExpression(
    analyser: *Analyser,
    tree: *const Ast,
    lhs: Ast.Node.Index,
    rhs: Ast.Node.Index,
) error{OutOfMemory}!bool {
    if (lhs == rhs) return true;
    if (tree.nodeTag(lhs) != .identifier or tree.nodeTag(rhs) != .identifier) return false;
    const lhs_token = ast.identifierTokenFromIdentifierNode(tree, lhs) orelse return false;
    const rhs_token = ast.identifierTokenFromIdentifierNode(tree, rhs) orelse return false;
    const lhs_name = try analyser.identifierTokenName(tree, lhs_token) orelse return false;
    const rhs_name = try analyser.identifierTokenName(tree, rhs_token) orelse return false;
    return std.mem.eql(u8, lhs_name, rhs_name);
}

fn isMutableIdentifierExpression(
    analyser: *Analyser,
    tree: *const Ast,
    handle: *DocumentStore.Handle,
    node: Ast.Node.Index,
) error{OutOfMemory}!bool {
    if (tree.nodeTag(node) != .identifier) return false;
    const token = ast.identifierTokenFromIdentifierNode(tree, node) orelse return false;
    const name = try analyser.identifierTokenName(tree, token) orelse return false;
    const declaration = try analyser.lookupSymbolGlobal(
        handle,
        name,
        tree.tokenStart(token),
    ) orelse return false;
    return !declaration.isConst();
}

fn complementaryIdentifierOperand(
    analyser: *Analyser,
    tree: *const Ast,
    lhs: Ast.Node.Index,
    rhs: Ast.Node.Index,
    unary_tag: Ast.Node.Tag,
) error{OutOfMemory}!?Ast.Node.Index {
    if (tree.nodeTag(lhs) == unary_tag) {
        const operand = tree.nodeData(lhs).node;
        if (try analyser.areSameIdentifierExpression(tree, operand, rhs)) return operand;
    }
    if (tree.nodeTag(rhs) == unary_tag) {
        const operand = tree.nodeData(rhs).node;
        if (try analyser.areSameIdentifierExpression(tree, lhs, operand)) return operand;
    }
    return null;
}

pub fn lookupSymbolContainer(
    analyser: *Analyser,
    container_type: Type,
    symbol: []const u8,
    kind: DocumentScope.DeclarationLookup.Kind,
) error{OutOfMemory}!?DeclWithHandle {
    const info = switch (container_type.data) {
        .container => |info| info,
        else => return null,
    };
    const container_scope = info.scope_handle;
    const handle = container_scope.handle;
    const document_scope = try handle.getDocumentScope();

    if (document_scope.getScopeDeclaration(.{
        .scope = container_scope.scope,
        .name = symbol,
        .kind = kind,
    }).unwrap()) |decl_index| {
        const decl = document_scope.declarations.get(@intFromEnum(decl_index));
        return .{ .decl = decl, .handle = handle, .container_type = container_type };
    }

    for (document_scope.getScopeDeclarationsConst(container_scope.scope)) |decl_index| {
        const index = @intFromEnum(decl_index);
        const lookup = document_scope.declaration_lookup_map.keys()[index];
        if (lookup.kind != kind) continue;
        if (std.mem.findScalar(u8, lookup.name, '\\') == null) continue;

        const decl = document_scope.declarations.get(index);
        if (try analyser.identifierTokenMatches(&handle.tree, decl.nameToken(&handle.tree), symbol)) {
            return .{ .decl = decl, .handle = handle, .container_type = container_type };
        }
    }

    return null;
}

pub fn lookupSymbolFieldInit(
    analyser: *Analyser,
    handle: *DocumentStore.Handle,
    field_name: []const u8,
    node: Ast.Node.Index,
    ancestors: []const Ast.Node.Index,
) Error!?DeclWithHandle {
    var container_type = (try analyser.resolveExpressionType(
        handle,
        node,
        ancestors,
    )) orelse return null;

    if (container_type.is_type_val) return null;

    const is_struct_init = switch (handle.tree.nodeTag(node)) {
        .struct_init_one,
        .struct_init_one_comma,
        .struct_init_dot_two,
        .struct_init_dot_two_comma,
        .struct_init_dot,
        .struct_init_dot_comma,
        .struct_init,
        .struct_init_comma,
        => true,
        else => false,
    };

    container_type = try container_type
        .resolveDeclLiteralResultType()
        .instanceTypeVal(analyser) orelse container_type;

    if (is_struct_init) {
        return try container_type.lookupSymbol(analyser, field_name);
    }

    switch (container_type.getContainerKind() orelse return null) {
        .keyword_struct, .keyword_opaque => {},
        .keyword_enum => if (try (try container_type.typeOf(analyser)).lookupSymbol(analyser, field_name)) |ty| return ty,
        .keyword_union => if (try container_type.lookupSymbol(analyser, field_name)) |ty| return ty,
        else => return null,
    }

    // Assume we are doing decl literals
    const decl = try (try container_type.typeOf(analyser)).lookupSymbol(analyser, field_name) orelse return null;
    var resolved_type = try decl.resolveType(analyser) orelse return null;
    resolved_type = try analyser.resolveReturnType(resolved_type) orelse resolved_type;
    resolved_type = resolved_type.resolveDeclLiteralResultType();
    if (resolved_type.eql(container_type) or resolved_type.eql(try container_type.typeOf(analyser))) return decl;
    return null;
}

pub fn resolveExpressionType(
    analyser: *Analyser,
    handle: *DocumentStore.Handle,
    node: Ast.Node.Index,
    ancestors: []const Ast.Node.Index,
) Error!?Type {
    return (try analyser.resolveExpressionTypeFromAncestors(
        handle,
        node,
        ancestors,
    )) orelse (try analyser.resolveTypeOfNode(.of(node, handle)));
}

pub fn resolveExpressionTypeFromAncestors(
    analyser: *Analyser,
    handle: *DocumentStore.Handle,
    node: Ast.Node.Index,
    ancestors: []const Ast.Node.Index,
) Error!?Type {
    if (ancestors.len == 0) return null;

    const tree = &handle.tree;

    switch (tree.nodeTag(ancestors[0])) {
        .struct_init_one,
        .struct_init_one_comma,
        .struct_init_dot_two,
        .struct_init_dot_two_comma,
        .struct_init_dot,
        .struct_init_dot_comma,
        .struct_init,
        .struct_init_comma,
        => {
            var buffer: [2]Ast.Node.Index = undefined;
            const struct_init = tree.fullStructInit(&buffer, ancestors[0]).?;
            if (std.mem.findScalar(Ast.Node.Index, struct_init.ast.fields, node) != null) {
                const field_name_token = tree.firstToken(node) - 2;
                if (tree.tokenTag(field_name_token) != .identifier) return null;
                const field_name = offsets.identifierTokenToNameSlice(tree, field_name_token);
                if (try analyser.lookupSymbolFieldInit(handle, field_name, ancestors[0], ancestors[1..])) |field_decl| {
                    return try field_decl.resolveType(analyser);
                }
            }
        },
        .array_init_one,
        .array_init_one_comma,
        .array_init_dot_two,
        .array_init_dot_two_comma,
        .array_init_dot,
        .array_init_dot_comma,
        .array_init,
        .array_init_comma,
        => {
            var buffer: [2]Ast.Node.Index = undefined;
            const array_init = tree.fullArrayInit(&buffer, ancestors[0]).?;
            const element_index = std.mem.findScalar(Ast.Node.Index, array_init.ast.elements, node) orelse
                return null;

            if (try analyser.resolveExpressionType(
                handle,
                ancestors[0],
                ancestors[1..],
            )) |array_type| {
                return (try analyser.resolveBracketAccessType(array_type, .{ .single = element_index }));
            }
        },
        .container_field_init,
        .container_field_align,
        .container_field,
        => {
            const container_field = tree.fullContainerField(ancestors[0]).?;
            if (node.toOptional() == container_field.ast.value_expr) {
                return try analyser.resolveTypeOfNode(.of(ancestors[0], handle));
            }
        },
        .global_var_decl,
        .local_var_decl,
        .simple_var_decl,
        .aligned_var_decl,
        => {
            const var_decl = tree.fullVarDecl(ancestors[0]).?;
            if (node.toOptional() == var_decl.ast.init_node) {
                return try analyser.resolveTypeOfNode(.of(ancestors[0], handle));
            }
            if (node.toOptional() == var_decl.ast.addrspace_node) {
                return analyser.instanceStdBuiltinType("AddressSpace");
            }
            if (node.toOptional() == var_decl.ast.section_node) {
                const ty = try analyser.ip.get(.{
                    .pointer_type = .{
                        .elem_type = .u8_type,
                        .sentinel = .none,
                        .flags = .{
                            .size = .slice,
                            .is_const = true,
                        },
                    },
                });
                return Type.fromIP(analyser, ty, null);
            }
        },
        .if_simple,
        .@"if",
        => {
            const if_node = ast.fullIf(tree, ancestors[0]).?;
            if (node == if_node.ast.then_expr or node.toOptional() == if_node.ast.else_expr) {
                return try analyser.resolveExpressionType(
                    handle,
                    ancestors[0],
                    ancestors[1..],
                );
            }
        },
        .for_simple,
        .@"for",
        => {
            const for_node = ast.fullFor(tree, ancestors[0]).?;
            if (node.toOptional() == for_node.ast.else_expr) {
                return try analyser.resolveExpressionType(
                    handle,
                    ancestors[0],
                    ancestors[1..],
                );
            }
        },
        .while_simple,
        .while_cont,
        .@"while",
        => {
            const while_node = ast.fullWhile(tree, ancestors[0]).?;
            if (node.toOptional() == while_node.ast.else_expr) {
                return try analyser.resolveExpressionType(
                    handle,
                    ancestors[0],
                    ancestors[1..],
                );
            }
        },
        .switch_case_one,
        .switch_case_inline_one,
        .switch_case,
        .switch_case_inline,
        => {
            const switch_case = tree.fullSwitchCase(ancestors[0]).?;
            if (ancestors.len == 1) return null;

            const ancestor_switch = tree.fullSwitch(ancestors[1]) orelse return null;

            if (node == switch_case.ast.target_expr) {
                return try analyser.resolveExpressionType(
                    handle,
                    ancestors[1],
                    ancestors[2..],
                );
            }

            for (switch_case.ast.values) |value| {
                if (node == value) {
                    return try analyser.resolveTypeOfNode(.of(ancestor_switch.ast.condition, handle));
                }
            }
        },
        .call,
        .call_comma,
        .call_one,
        .call_one_comma,
        => {
            var buffer: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&buffer, ancestors[0]).?;

            if (call.ast.fn_expr == node) {
                return try analyser.resolveExpressionType(
                    handle,
                    ancestors[0],
                    ancestors[1..],
                );
            }

            const arg_index = std.mem.findScalar(Ast.Node.Index, call.ast.params, node) orelse return null;

            var fn_type = if (tree.nodeTag(call.ast.fn_expr) == .enum_literal) blk: {
                const field_name = offsets.identifierTokenToNameSlice(tree, tree.nodeMainToken(call.ast.fn_expr));
                const decl = try analyser.lookupSymbolFieldInit(handle, field_name, call.ast.fn_expr, ancestors) orelse return null;
                const ty = try decl.resolveType(analyser) orelse return null;
                break :blk try analyser.resolveFuncProtoOfCallable(ty) orelse return null;
            } else blk: {
                const ty = try analyser.resolveTypeOfNode(.of(call.ast.fn_expr, handle)) orelse return null;
                break :blk try analyser.resolveFuncProtoOfCallable(ty) orelse return null;
            };
            if (fn_type.is_type_val) return null;

            fn_type = try analyser.resolveFunctionTypeFromCall(handle, call, fn_type);
            const has_self_param = try analyser.isInstanceCall(handle, call, fn_type);
            const parameters = fn_type.data.function.parameters[@intFromBool(has_self_param)..];
            if (arg_index >= parameters.len) return null;
            const param_ty = parameters[arg_index].type;
            return try param_ty.instanceTypeVal(analyser);
        },
        .assign => {
            const lhs, const rhs = tree.nodeData(ancestors[0]).node_and_node;
            if (node == rhs) {
                return try analyser.resolveTypeOfNode(.of(lhs, handle));
            }
        },
        .ptr_type_aligned,
        .ptr_type_sentinel,
        .ptr_type,
        .ptr_type_bit_range,
        => {
            const ptr = tree.fullPtrType(ancestors[0]).?;
            if (node.toOptional() == ptr.ast.sentinel) {
                return analyser.resolveInstanceOfNode(.of(ptr.ast.child_type, handle));
            }
            if (node.toOptional() == ptr.ast.addrspace_node) {
                return analyser.instanceStdBuiltinType("AddressSpace");
            }
        },
        .array_type_sentinel => {
            const array_type = tree.fullArrayType(ancestors[0]).?;
            if (node.toOptional() == array_type.ast.sentinel) {
                return analyser.resolveInstanceOfNode(.of(array_type.ast.elem_type, handle));
            }
        },

        .equal_equal, .bang_equal => {
            const lhs, const rhs = tree.nodeData(ancestors[0]).node_and_node;
            if (node == lhs) {
                return try analyser.resolveTypeOfNode(.of(rhs, handle));
            }
            if (node == rhs) {
                return try analyser.resolveTypeOfNode(.of(lhs, handle));
            }
        },

        .@"return" => {
            const return_expr = tree.nodeData(ancestors[0]).opt_node.unwrap() orelse return null;
            if (node != return_expr) return null;

            var func_buf: [1]Ast.Node.Index = undefined;
            for (1..ancestors.len) |index| {
                const func = tree.fullFnProto(&func_buf, ancestors[index]) orelse continue;
                const return_type = func.ast.return_type.unwrap() orelse continue;
                const return_ty = try analyser.resolveTypeOfNode(.of(return_type, handle)) orelse return null;
                return try return_ty.instanceTypeVal(analyser);
            }
        },

        .@"continue" => {
            const opt_target, const opt_continue_expr = tree.nodeData(ancestors[0]).opt_token_and_opt_node;
            const target = opt_target.unwrap() orelse return null;
            const continue_expr = opt_continue_expr.unwrap() orelse return null;
            if (node != continue_expr) return null;

            const continue_label = tree.tokenSlice(target);

            const ancestor_switch = for (ancestors[1..]) |ancestor| {
                if (tree.fullSwitch(ancestor)) |switch_node| {
                    const switch_label_token = switch_node.label_token orelse continue;
                    const switch_label = tree.tokenSlice(switch_label_token);
                    if (std.mem.eql(u8, continue_label, switch_label)) {
                        break switch_node;
                    }
                }
            } else {
                return null;
            };

            const condition = try analyser.resolveTypeOfNode(.of(ancestor_switch.ast.condition, handle)) orelse return null;
            if (condition.data == .enum_value) {
                return try condition.data.enum_value.enum_type.instanceTypeVal(analyser);
            }
            return condition;
        },

        .@"break" => {
            const opt_target, const opt_break_expr = tree.nodeData(ancestors[0]).opt_token_and_opt_node;
            const break_expr = opt_break_expr.unwrap() orelse return null;
            if (node != break_expr) return null;

            const break_label_maybe: ?[]const u8 = if (opt_target.unwrap()) |target|
                tree.tokenSlice(target)
            else
                null;

            const index = ast.indexOfBreakTarget(tree, ancestors, break_label_maybe) orelse return null;

            return try analyser.resolveExpressionType(
                handle,
                ancestors[index],
                ancestors[index + 1 ..],
            );
        },

        .grouped_expression,
        .@"try",
        .@"comptime",
        => {
            return try analyser.resolveExpressionType(
                handle,
                ancestors[0],
                ancestors[1..],
            );
        },

        .builtin_call,
        .builtin_call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        => {
            var buffer: [2]Ast.Node.Index = undefined;
            const params = tree.builtinCallParams(&buffer, ancestors[0]).?;
            const call_name = tree.tokenSlice(tree.nodeMainToken(ancestors[0]));

            if (std.mem.eql(u8, call_name, "@as")) {
                if (params.len != 2) return null;
                if (params[1] != node) return null;
                const ty = try analyser.resolveTypeOfNode(.of(params[0], handle)) orelse return null;
                return try ty.instanceTypeVal(analyser);
            }

            if (version_data.builtins.get(call_name)) |data| {
                const index = std.mem.findScalar(Ast.Node.Index, params, node) orelse return null;
                if (index >= data.parameters.len) return null;
                const parameter = data.parameters[index];
                const colon_index = std.mem.findScalar(u8, parameter.signature, ':') orelse return null;
                const type_str = parameter.signature[colon_index + 2 ..];
                return analyser.resolveLangrefType(type_str);
            }
        },

        .@"orelse" => {
            const lhs, const rhs = tree.nodeData(ancestors[0]).node_and_node;
            if (node == rhs) {
                const lhs_ty = try analyser.resolveTypeOfNode(.of(lhs, handle)) orelse return null;
                return try analyser.resolveOptionalUnwrap(lhs_ty);
            }
        },

        .@"catch" => {
            const lhs, const rhs = tree.nodeData(ancestors[0]).node_and_node;
            if (node == rhs) {
                const lhs_ty = try analyser.resolveTypeOfNode(.of(lhs, handle)) orelse return null;
                return try analyser.resolveUnwrapErrorUnionType(lhs_ty, .payload);
            }
        },

        .address_of => {
            std.debug.assert(node == tree.nodeData(ancestors[0]).node);

            const expr_ty = try analyser.resolveExpressionType(
                handle,
                ancestors[0],
                ancestors[1..],
            ) orelse return null;

            if (try analyser.resolveDerefType(expr_ty)) |ty| {
                return ty;
            }

            switch (expr_ty.data) {
                .pointer => |info| switch (info.size) {
                    .slice => {
                        var buffer: [2]Ast.Node.Index = undefined;
                        const array_init = tree.fullArrayInit(&buffer, node) orelse return null;
                        return .{
                            .data = .{
                                .array = .{
                                    .elem_count = array_init.ast.elements.len,
                                    .sentinel = info.sentinel,
                                    .elem_ty = info.elem_ty,
                                },
                            },
                            .is_type_val = false,
                        };
                    },
                    else => {},
                },
                .ip_index => |payload| switch (analyser.ip.indexToKey(payload.type)) {
                    .pointer_type => |pointer_info| switch (pointer_info.flags.size) {
                        .slice => {
                            var buffer: [2]Ast.Node.Index = undefined;
                            const array_init = tree.fullArrayInit(&buffer, node) orelse return null;
                            const ty = try analyser.ip.get(.{
                                .array_type = .{
                                    .len = array_init.ast.elements.len,
                                    .child = pointer_info.elem_type,
                                    .sentinel = pointer_info.sentinel,
                                },
                            });
                            return Type.fromIP(analyser, ty, null);
                        },
                        else => {},
                    },
                    else => {},
                },
                else => {},
            }

            return null;
        },
        .fn_proto_simple,
        .fn_proto_multi,
        .fn_proto_one,
        .fn_proto,
        => {
            var buf: [1]Ast.Node.Index = undefined;
            const proto = tree.fullFnProto(&buf, ancestors[0]).?;
            if (node.toOptional() == proto.ast.addrspace_expr) {
                return analyser.instanceStdBuiltinType("AddressSpace");
            }
            if (node.toOptional() == proto.ast.callconv_expr) {
                return analyser.instanceStdBuiltinType("CallingConvention");
            }
            if (node.toOptional() == proto.ast.section_expr) {
                const ty = try analyser.ip.get(.{
                    .pointer_type = .{
                        .elem_type = .u8_type,
                        .sentinel = .none,
                        .flags = .{
                            .size = .slice,
                            .is_const = true,
                        },
                    },
                });
                return Type.fromIP(analyser, ty, null);
            }
        },
        .asm_simple,
        .@"asm",
        => {
            const full = tree.fullAsm(ancestors[0]).?;
            if (node.toOptional() == full.ast.clobbers) {
                return analyser.instanceStdBuiltinType("assembly.Clobbers");
            }
        },

        else => {},
    }

    return null;
}

pub fn getSymbolEnumLiteral(
    analyser: *Analyser,
    handle: *DocumentStore.Handle,
    source_index: usize,
    name: []const u8,
) Error!?DeclWithHandle {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const tree = &handle.tree;
    const nodes = try ast.nodesOverlappingIndex(analyser.arena, tree, source_index);
    if (nodes.len == 0) return null;
    return try analyser.lookupSymbolFieldInit(handle, name, nodes[0], nodes[1..]);
}

pub fn resolveStructInitType(
    analyser: *Analyser,
    handle: *DocumentStore.Handle,
    source_index: usize,
) Error!?Type {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    const tree = &handle.tree;
    const nodes = try ast.nodesOverlappingIndex(analyser.arena, tree, source_index);
    if (nodes.len == 0) return null;
    var ty = try analyser.resolveExpressionType(handle, nodes[0], nodes[1..]) orelse return null;
    while (true) {
        const unwrapped =
            try analyser.resolveUnwrapErrorUnionType(ty, .payload) orelse
            try analyser.resolveOptionalUnwrap(ty) orelse
            break;
        ty = unwrapped;
    }
    return ty;
}

/// Multiple when using branched types
pub fn getSymbolFieldAccesses(
    analyser: *Analyser,
    arena: std.mem.Allocator,
    handle: *DocumentStore.Handle,
    source_index: usize,
    held_loc: offsets.Loc,
    name: []const u8,
) Error!?[]const DeclWithHandle {
    var decls_with_handles: std.ArrayList(DeclWithHandle) = .empty;
    var property_types: std.ArrayList(Type) = .empty;
    try analyser.getSymbolFieldAccessesArrayList(arena, handle, source_index, held_loc, name, &decls_with_handles, &property_types);
    return try decls_with_handles.toOwnedSlice(arena);
}

pub fn getSymbolFieldAccessesArrayList(
    analyser: *Analyser,
    arena: std.mem.Allocator,
    handle: *DocumentStore.Handle,
    source_index: usize,
    held_loc: offsets.Loc,
    name: []const u8,
    decls_with_handles: *std.ArrayList(DeclWithHandle),
    property_types: *std.ArrayList(Type),
) Error!void {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    if (try analyser.getFieldAccessType(handle, source_index, held_loc)) |ty| {
        const container_handle = try analyser.resolveDerefType(ty) orelse ty;

        const container_handle_nodes = try container_handle.getAllTypesWithHandles(analyser);

        for (container_handle_nodes) |t| {
            if (try t.lookupSymbol(analyser, name)) |decl_handle|
                try decls_with_handles.append(arena, decl_handle);
            if (try analyser.resolvePropertyType(ty, name)) |p|
                try property_types.append(arena, p);
        }
    }
}

pub fn getSymbolFieldAccessesHighlight(
    analyser: *Analyser,
    arena: std.mem.Allocator,
    handle: *DocumentStore.Handle,
    source_index: usize,
    loc: offsets.Loc,
    decls_with_handles: *std.ArrayList(DeclWithHandle),
    property_types: *std.ArrayList(Type),
) Error!?offsets.Loc {
    const name_loc, const highlight_loc = blk: {
        const name_token, const name_loc = offsets.identifierTokenAndLocFromIndex(&handle.tree, source_index) orelse {
            const token = offsets.sourceIndexToTokenIndex(&handle.tree, source_index).pickPreferred(&.{ .question_mark, .period_asterisk }, &handle.tree) orelse return null;
            switch (handle.tree.tokenTag(token)) {
                .question_mark => {
                    const token_loc = offsets.tokenToLoc(&handle.tree, token);
                    break :blk .{ token_loc, token_loc };
                },
                .period_asterisk => {
                    var name_loc = offsets.tokenToLoc(&handle.tree, token);
                    name_loc.start += 1; // trim the period
                    break :blk .{ name_loc, name_loc };
                },
                else => return null,
            }
        };
        break :blk .{ name_loc, offsets.tokenToLoc(&handle.tree, name_token) };
    };
    const name = offsets.locToSlice(handle.tree.source, name_loc);
    const held_loc = offsets.locMerge(loc, name_loc);
    try analyser.getSymbolFieldAccessesArrayList(arena, handle, source_index, held_loc, name, decls_with_handles, property_types);
    return highlight_loc;
}

pub const ReferencedType = struct {
    str: []const u8,
    handle: *DocumentStore.Handle,
    token: Ast.TokenIndex,

    pub fn of(
        str: []const u8,
        handle: *DocumentStore.Handle,
        token: Ast.TokenIndex,
    ) ReferencedType {
        return .{ .str = str, .handle = handle, .token = token };
    }

    pub const Set = std.array_hash_map.Custom(ReferencedType, void, SetContext, true);

    const SetContext = struct {
        pub fn hash(self: SetContext, item: ReferencedType) u32 {
            _ = self;
            var hasher: std.hash.Wyhash = .init(0);
            hasher.update(item.str);
            hasher.update(item.handle.uri.raw);
            hasher.update(&std.mem.toBytes(item.token));
            return @truncate(hasher.final());
        }

        pub fn eql(self: SetContext, a: ReferencedType, b: ReferencedType, b_index: usize) bool {
            _ = self;
            _ = b_index;
            return std.mem.eql(u8, a.str, b.str) and
                a.handle.uri.eql(b.handle.uri) and
                a.token == b.token;
        }
    };
};
