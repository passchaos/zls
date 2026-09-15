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
const comptime_eval = @import("analyser/comptime.zig");

gpa: std.mem.Allocator,
arena: std.mem.Allocator,
store: *DocumentStore,
ip: *InternPool,
resolved_callsites: std.AutoHashMapUnmanaged(Declaration.Param, ?Type) = .empty,
resolved_nodes: std.HashMapUnmanaged(NodeWithUri, ?Binding, NodeWithUri.Context, std.hash_map.default_max_load_percentage) = .empty,
resolved_values: std.HashMapUnmanaged(NodeWithUri, ?Binding, NodeWithUri.Context, std.hash_map.default_max_load_percentage) = .empty,
resolved_control_flow_values: std.HashMapUnmanaged(NodeWithUri, ?Binding, NodeWithUri.Context, std.hash_map.default_max_load_percentage) = .empty,
resolved_specialized_nodes: std.HashMapUnmanaged(GeneratedContainerTypeKey, ?Binding, GeneratedContainerTypeKey.Context, std.hash_map.default_max_load_percentage) = .empty,
generated_container_types: std.HashMapUnmanaged(GeneratedContainerTypeKey, Type, GeneratedContainerTypeKey.Context, std.hash_map.default_max_load_percentage) = .empty,
resolved_enum_literals: std.HashMapUnmanaged(EnumLiteralCacheKey, ?DeclWithHandle, EnumLiteralCacheKey.Context, std.hash_map.default_max_load_percentage) = .empty,
comptime_interpreter_needed: std.HashMapUnmanaged(NodeWithUri, bool, NodeWithUri.Context, std.hash_map.default_max_load_percentage) = .empty,
sequential_enum_types: std.HashMapUnmanaged(SequentialEnumKey, Type, SequentialEnumKey.Context, std.hash_map.default_max_load_percentage) = .empty,
resolving_specialized_nodes: NodeSet = .empty,
collect_callsite_references: bool,
callsite_reference_depth: u8,
/// avoid unnecessarily parsing number literals
resolve_number_literal_values: bool,
/// Evaluate basic comptime expressions instead of preserving only their type.
evaluate_comptime_values: bool,
/// Select a known branch while evaluating comptime control flow.
evaluate_comptime_control_flow: bool,
/// Scoped bindings must survive recursive resolution without an explicit container.
generic_bindings: ?*const TokenToTypeMap,
/// Source expressions for comptime arguments that are retained for type
/// presentation but must not participate in semantic substitution.
display_bindings: ?*const TokenToNodeMap,
comptime_interpreter: ?*comptime_eval.Interpreter = null,
generated_struct_fields: std.AutoHashMapUnmanaged(InternPool.Index, []const GeneratedField) = .empty,

/// handle of the doc where the request originated
root_handle: ?*DocumentStore.Handle,
max_conditional_combos: usize = 200,

pub const GeneratedField = struct {
    name: []const u8,
    ty: Type,
    default_value: ?Type = null,
    alignment: u16 = 0,
};

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
        .callsite_reference_depth = 0,
        .resolve_number_literal_values = false,
        .evaluate_comptime_values = false,
        .evaluate_comptime_control_flow = false,
        .generic_bindings = null,
        .display_bindings = null,
        .root_handle = root_handle,
    };
}

pub fn deinit(self: *Analyser) void {
    self.resolved_callsites.deinit(self.gpa);
    self.resolved_nodes.deinit(self.gpa);
    self.resolved_values.deinit(self.gpa);
    self.resolved_control_flow_values.deinit(self.gpa);
    self.resolved_specialized_nodes.deinit(self.gpa);
    self.generated_container_types.deinit(self.gpa);
    self.resolved_enum_literals.deinit(self.gpa);
    self.comptime_interpreter_needed.deinit(self.gpa);
    self.sequential_enum_types.deinit(self.gpa);
    self.resolving_specialized_nodes.deinit(self.gpa);
    self.generated_struct_fields.deinit(self.gpa);
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
        .container => |actual| switch (deref_expected_type.data) {
            .container => |expected| containersHaveCompatibleIdentity(actual, expected),
            else => false,
        },
        else => deref_type.eql(deref_expected_type),
    };
}

fn containersHaveCompatibleIdentity(actual: Type.Data.Container, expected: Type.Data.Container) bool {
    if (!actual.scope_handle.eql(expected.scope_handle)) return false;
    if (actual.bound_params.count() > expected.bound_params.count()) return false;
    if (actual.bound_params.count() == 0) return expected.bound_params.count() == 0;

    // A generated container may be reached through a forwarding type function
    // before ZLS can model every comptime value passed to it. Treat a missing
    // binding as unknown, while still rejecting bindings that are known to
    // disagree. This keeps instance methods visible without conflating
    // concrete specializations such as Foo(u8) and Foo(u16).
    for (actual.bound_params.keys(), actual.bound_params.values()) |key, actual_value| {
        const expected_value = expected.bound_params.get(key) orelse return false;
        if (!actual_value.eql(expected_value)) return false;
    }
    return true;
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

pub fn resolveDeclarationOfNode(analyser: *Analyser, options: ResolveOptions) Error!?DeclWithHandle {
    const node = options.node_handle.node;
    const handle = options.node_handle.handle;
    const tree = &handle.tree;
    return switch (tree.nodeTag(node)) {
        .identifier => blk: {
            const name_token = ast.identifierTokenFromIdentifierNode(tree, node) orelse break :blk null;
            const name = offsets.identifierTokenToNameSlice(tree, name_token);
            if (options.container_type) |ty| {
                if (try ty.lookupSymbol(analyser, name)) |symbol| break :blk symbol;
            }
            break :blk try analyser.lookupSymbolGlobal(handle, name, tree.tokenStart(name_token));
        },
        .field_access => blk: {
            const lhs, const field_name = tree.nodeData(node).node_and_token;
            const resolved = (try analyser.resolveTypeOfNode(.{
                .node_handle = .of(lhs, handle),
                .container_type = options.container_type,
            })) orelse break :blk null;
            if (!resolved.is_type_val) break :blk null;
            const symbol_name = offsets.identifierTokenToNameSlice(tree, field_name);
            break :blk try resolved.lookupSymbol(analyser, symbol_name);
        },
        else => null,
    };
}

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
            .identifier, .field_access => try analyser.resolveDeclarationOfNode(current),
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
    if (lhs.data == .comptime_value and lhs.data.comptime_value.data == .reference) {
        if (analyser.comptime_interpreter) |interpreter| {
            const target = try interpreter.readReference(lhs.data.comptime_value.data.reference) orelse return null;
            return analyser.resolveFieldAccessBinding(.{ .type = target, .is_const = false }, field_name);
        }
    }
    if (comptime_eval.Value.field(lhs, field_name)) |value| return .{ .type = value, .is_const = true };
    const dereferenced_lhs = comptime_eval.Value.deref(lhs);
    if (dereferenced_lhs.data == .comptime_value and dereferenced_lhs.data.comptime_value.data == .fields) {
        const ty = dereferenced_lhs.data.comptime_value.ty;
        const container_ty = if (ty.data == .container)
            ty
        else
            ty.constAggregatePointerChild(analyser) orelse ty;
        if (container_ty.data == .container) {
            if (try analyser.lookupSymbolContainer(try container_ty.instanceUnchecked(analyser), field_name, .field)) |decl| {
                if (decl.decl == .ast_node) {
                    const field = decl.handle.tree.fullContainerField(decl.decl.ast_node) orelse return null;
                    if (field.ast.value_expr != .none) {
                        return .{
                            .type = try comptime_eval.Interpreter.evaluateFieldDefault(analyser, decl) orelse return null,
                            .is_const = true,
                        };
                    }
                }
            }
        }
    }
    if (comptime_eval.Value.elements(lhs)) |items| {
        if (std.mem.eql(u8, field_name, "ptr")) {
            const value_type = if (lhs.data == .comptime_value)
                try lhs.data.comptime_value.ty.instanceUnchecked(analyser)
            else
                lhs;
            const pointer = try analyser.resolvePropertyType(value_type, field_name) orelse pointer: {
                const pointer_type = try value_type.typeOf(analyser);
                const pointer_info = pointer_type.typePointerInfo(analyser) orelse break :pointer null;
                if (pointer_info.size != .one) break :pointer null;
                const array = try pointer_info.elem_ty.instanceUnchecked(analyser);
                const array_info = array.arrayInfo(analyser) orelse
                    break :pointer null;
                const sentinel = array_info[1];
                const elem_type = array_info[2];
                const many_pointer = try Type.createPointerTypeWithFlags(
                    analyser,
                    .{
                        .size = .many,
                        .is_const = pointer_info.is_const,
                        .is_volatile = pointer_info.is_volatile,
                        .is_allowzero = pointer_info.is_allowzero,
                        .address_space = pointer_info.address_space,
                        .alignment = @intCast(pointer_info.alignment),
                    },
                    pointer_info.packed_offset,
                    sentinel,
                    elem_type,
                );
                break :pointer try many_pointer.instanceUnchecked(analyser);
            };
            if (pointer != null) {
                if (comptime_eval.Value.sequence(lhs)) |view| return .{
                    .type = try comptime_eval.Value.create(analyser, try pointer.?.typeOf(analyser), .{ .sequence = .{
                        .backing = view.backing,
                        .offset = view.offset,
                        .len = view.backing.len - view.offset,
                        .elements_valid = view.elements_valid,
                        .origin = view.origin,
                    } }),
                    .is_const = true,
                };
                return .{
                    .type = try comptime_eval.Value.create(analyser, try pointer.?.typeOf(analyser), .{ .array = items }),
                    .is_const = true,
                };
            }
        }
        if (std.mem.eql(u8, field_name, "len")) {
            const value_type = if (lhs.data == .comptime_value)
                try lhs.data.comptime_value.ty.instanceUnchecked(analyser)
            else
                lhs;
            const pointer_size = value_type.pointerSize(analyser);
            if (pointer_size != .many and pointer_size != .c)
                return .{ .type = try analyser.comptimeIntValue(items.len), .is_const = true };
        }
        const value_type = try comptime_eval.Value.deref(lhs).typeOf(analyser);
        if (value_type.isTupleType(analyser) and allDigits(field_name)) {
            const index = std.fmt.parseUnsigned(usize, field_name, 10) catch return null;
            if (index < items.len) return .{ .type = items[index], .is_const = true };
            return null;
        }
    }
    if (lhs.data == .string_value) {
        if (std.mem.eql(u8, field_name, "ptr")) {
            const string_type = lhs.data.string_value.string_type.*;
            const pointer = switch (analyser.ip.indexToKey(string_type.ipIndex() orelse return null)) {
                .pointer_type => |pointer| pointer,
                else => return null,
            };
            if (pointer.flags.size != .one) return null;
            const array = switch (analyser.ip.indexToKey(pointer.elem_type)) {
                .array_type => |array| array,
                else => return null,
            };
            var many_pointer = pointer;
            many_pointer.flags.size = .many;
            many_pointer.elem_type = array.child;
            many_pointer.sentinel = array.sentinel;
            const pointer_type = try analyser.ip.get(.{ .pointer_type = many_pointer });
            const bytes = lhs.data.string_value.bytes;
            const items = try analyser.arena.alloc(Type, bytes.len);
            for (bytes, items) |byte, *item| {
                const index = try analyser.ip.get(.{ .int_u64_value = .{
                    .ty = .u8_type,
                    .int = byte,
                } });
                item.* = Type.fromIP(analyser, .u8_type, index);
            }
            return .{
                .type = try comptime_eval.Value.create(analyser, Type.fromIP(analyser, .type_type, pointer_type), .{ .sequence = .{
                    .backing = items,
                    .offset = 0,
                    .len = items.len,
                    .elements_valid = true,
                } }),
                .is_const = true,
            };
        }
        if (try analyser.resolvePropertyType(lhs, field_name)) |t| {
            return .{ .type = t, .is_const = true };
        }
    }
    if (lhs.data == .type_info_value) {
        if (try analyser.resolveTypeInfoFieldAccess(lhs.data.type_info_value, field_name)) |field| {
            return .{ .type = field, .is_const = true };
        }
    }
    if (lhs.is_type_val) if (lhs.ipIndex()) |type_index| {
        if (analyser.ip.zigTypeTag(type_index) == .@"enum" and
            try analyser.resolveEnumTagIntValue(lhs, field_name) != null)
        {
            return .{ .type = try analyser.enumValue(lhs, field_name), .is_const = true };
        }
    };

    if (try analyser.resolveUnionTagAccess(lhs, field_name)) |t|
        return .{ .type = t, .is_const = true };

    // If we are accessing a pointer type, remove one pointerness level :)
    const runtime_lhs = lhs.runtimeType(analyser);
    const left_type = (try analyser.resolveDerefType(runtime_lhs)) orelse runtime_lhs;
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

fn resolveStaticConstValue(
    analyser: *Analyser,
    options: ResolveOptions,
    destination: Type,
) Error!?Type {
    var declaration = try analyser.resolveDeclarationOfNode(options) orelse return null;
    declaration = try analyser.resolveVarDeclAlias(declaration) orelse declaration;
    if (!declaration.isConst() or !try declaration.isStatic()) return null;
    const declaration_node = switch (declaration.decl) {
        .ast_node => |node| node,
        else => return null,
    };
    const variable = declaration.handle.tree.fullVarDecl(declaration_node) orelse return null;
    const initializer = variable.ast.init_node.unwrap() orelse return null;
    return comptime_eval.Interpreter.evaluateTyped(
        analyser,
        declaration.handle,
        initializer,
        try destination.typeOf(analyser),
    );
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

pub fn resolveKnownUnionFieldName(analyser: *Analyser, value: Type) Error!?[]const u8 {
    if (value.data == .comptime_value and value.data.comptime_value.data == .fields) {
        const fields = value.data.comptime_value.data.fields;
        const ty = value.data.comptime_value.ty;
        const is_union = ty.isUnionType() or if (ty.ipIndex()) |index| analyser.ip.zigTypeTag(index) == .@"union" else false;
        if (is_union and fields.len == 1) return fields[0].name;
        return null;
    }
    const payload = switch (value.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const value_index = payload.index orelse return null;
    const union_value = switch (analyser.ip.indexToKey(value_index)) {
        .union_value => |union_value| union_value,
        else => return null,
    };
    if (union_value.ty != payload.type) return null;
    const union_index = switch (analyser.ip.indexToKey(payload.type)) {
        .union_type => |union_index| union_index,
        else => return null,
    };
    const fields = analyser.ip.getUnion(union_index).fields;
    if (union_value.field_index >= fields.count()) return null;
    return try analyser.ip.string_pool.stringToSliceAlloc(
        analyser.store.io,
        analyser.arena,
        fields.keys()[union_value.field_index],
    );
}

pub fn resolveKnownSwitchTarget(
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
    return analyser.resolveKnownSwitchTargetFromValue(options, condition);
}

pub fn resolveKnownSwitchTargetFromValue(
    analyser: *Analyser,
    options: ResolveOptions,
    condition: Type,
) Error!?Ast.Node.Index {
    const handle = options.node_handle.handle;
    const tree = &handle.tree;
    const switch_node = tree.switchFull(options.node_handle.node);
    const union_field_name = try analyser.resolveKnownUnionFieldName(condition);

    var else_target: ?Ast.Node.Index = null;
    for (switch_node.ast.cases) |case| {
        const switch_case = tree.fullSwitchCase(case).?;
        if (switch_case.ast.values.len == 0) {
            else_target = switch_case.ast.target_expr;
            continue;
        }

        for (switch_case.ast.values) |case_value| {
            var literal_buffer: [2]Ast.Node.Index = undefined;
            const is_aggregate_literal = tree.fullStructInit(&literal_buffer, case_value) != null or
                tree.fullArrayInit(&literal_buffer, case_value) != null;
            if (is_aggregate_literal) {
                const interpreter = analyser.comptime_interpreter orelse return null;
                const condition_type = try condition.typeOf(analyser);
                const value = try interpreter.evaluateTypedExpression(handle, case_value, condition_type) orelse return null;
                if (comptime_eval.Value.deref(condition).eql(comptime_eval.Value.deref(value))) {
                    return switch_case.ast.target_expr;
                }
                continue;
            }
            if (union_field_name) |field_name| {
                if (tree.nodeTag(case_value) != .enum_literal) return null;
                const case_name = try analyser.identifierTokenName(tree, tree.nodeMainToken(case_value)) orelse return null;
                if (std.mem.eql(u8, field_name, case_name)) return switch_case.ast.target_expr;
                continue;
            }
            if (condition.data == .type_info_value) {
                if (tree.nodeTag(case_value) != .enum_literal) return null;
                const case_tag_name = try analyser.identifierTokenName(tree, tree.nodeMainToken(case_value)) orelse return null;
                const case_tag = std.meta.stringToEnum(std.builtin.TypeId, case_tag_name) orelse return null;
                if (condition.data.type_info_value.tag == case_tag) return switch_case.ast.target_expr;
                continue;
            }
            if (condition.data == .enum_value) {
                const enum_type = condition.data.enum_value.enum_type.*;
                const case_tag = if (enum_type.ipIndex() == .enum_literal_type)
                    if (tree.nodeTag(case_value) == .enum_literal)
                        try analyser.identifierTokenName(tree, tree.nodeMainToken(case_value)) orelse return null
                    else
                        return null
                else
                    try analyser.resolveEnumValueTag(enum_type, .of(case_value, handle)) orelse return null;
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
            if (try analyser.comptimeInterpreterNeeded(handle, body)) {
                if (try comptime_eval.Interpreter.evaluate(analyser, handle, body)) |value| return value;
            }
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

fn comptimeInterpreterNeeded(analyser: *Analyser, handle: *DocumentStore.Handle, body: Ast.Node.Index) error{OutOfMemory}!bool {
    const key: NodeWithUri = .{ .node = body, .uri = handle.uri };
    const cached = try analyser.comptime_interpreter_needed.getOrPut(analyser.gpa, key);
    if (!cached.found_existing) cached.value_ptr.* = comptime_eval.Interpreter.needed(handle, body);
    return cached.value_ptr.*;
}

/// `optional.?`
pub fn resolveOptionalUnwrap(analyser: *Analyser, optional: Type) error{OutOfMemory}!?Type {
    if (optional.is_type_val) return null;

    // TODO: some uses of this function don't expect C pointers to be unwrapped
    switch (optional.data) {
        .comptime_value => |value| switch (value.data) {
            .optional => |payload| return payload,
            else => return null,
        },
        .type_info_value => |value| {
            if (value.optional_type_payload) |payload| return payload.*;
            if (value.collection == null or
                value.collection.?.kind != .error_set_errors or
                !value.collection.?.is_optional) return null;
            const unwrapped_type = try analyser.resolveOptionalUnwrap(value.value_type.*) orelse return null;
            var collection = value.collection.?;
            collection.is_optional = false;
            return .{ .data = .{ .type_info_value = .{
                .value_type = try analyser.allocType(unwrapped_type),
                .reflected_type = value.reflected_type,
                .tag = value.tag,
                .is_payload = value.is_payload,
                .collection = collection,
            } }, .is_type_val = false };
        },
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
        .comptime_value => |value| blk: {
            if (value.data != .error_union) break :blk null;
            if (analyser.evaluate_comptime_values) switch (value.data.error_union) {
                .payload => |payload| if (side == .payload) break :blk payload,
                .failure => |failure| if (side == .error_set) break :blk failure,
            };
            break :blk try analyser.resolveUnwrapErrorUnionType(ty.runtimeType(analyser), side);
        },
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

    if (lhs.data == .ip_index and analyser.ip.indexToKey(lhs.data.ip_index.type) == .error_set_type) return rhs;
    const payload = try analyser.resolveUnwrapErrorUnionType(lhs, .payload) orelse return null;
    return try analyser.resolvePeerTypes(payload, rhs) orelse payload;
}

fn resolveUnionTag(analyser: *Analyser, ty: Type) Error!?Type {
    if (!ty.is_type_val) return null;

    if (ty.data == .ip_index) {
        const type_index = ty.data.ip_index.index orelse return null;
        const union_info = switch (analyser.ip.indexToKey(type_index)) {
            .union_type => |union_index| analyser.ip.getUnion(union_index),
            else => return null,
        };
        if (union_info.tag_type == .none) return null;
        return Type.fromIP(analyser, union_info.tag_type, null);
    }

    if (!ty.isTaggedUnion()) return null;

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

fn resolveEnumTagType(analyser: *Analyser, enum_type: Type) Error!?Type {
    if (!enum_type.isEnumType(analyser)) return null;

    return switch (enum_type.data) {
        .ip_index => |payload| switch (analyser.ip.indexToKey(payload.index orelse return null)) {
            .enum_type => |enum_index| Type.fromIP(
                analyser,
                .type_type,
                analyser.ip.getEnum(enum_index).tag_type,
            ),
            else => null,
        },
        .container => blk: {
            var buffer: [2]Ast.Node.Index = undefined;
            const info = astContainerTypeInfo(enum_type, &buffer) orelse break :blk null;
            if (info.handle.tree.tokenTag(info.declaration.ast.main_token) != .keyword_enum) break :blk null;
            break :blk try analyser.astEnumTagType(enum_type, info.declaration, info.handle);
        },
        .union_tag => |union_type| blk: {
            var buffer: [2]Ast.Node.Index = undefined;
            const info = astContainerTypeInfo(union_type.*, &buffer) orelse break :blk null;
            if (info.handle.tree.tokenTag(info.declaration.ast.main_token) != .keyword_union or
                info.declaration.ast.enum_token == null) break :blk null;
            break :blk try analyser.astEnumTagType(union_type.*, info.declaration, info.handle);
        },
        else => null,
    };
}

fn resolveArgsTupleType(analyser: *Analyser, function_type: Type) Error!?Type {
    if (!function_type.is_type_val) return null;

    const parameter_types = switch (function_type.data) {
        .function => |info| blk: {
            if (info.has_varargs) return null;
            const types = try analyser.arena.alloc(Type, info.parameters.len);
            for (info.parameters, types) |parameter, *parameter_type| {
                if (parameter.type.data == .anytype_parameter) return null;
                parameter_type.* = parameter.type;
            }
            break :blk types;
        },
        .ip_index => |payload| switch (analyser.ip.indexToKey(payload.index orelse return null)) {
            .function_type => |info| blk: {
                if (info.flags.is_var_args) return null;
                const types = try analyser.arena.alloc(Type, info.args.len);
                for (types, 0..) |*parameter_type, index| {
                    const parameter = info.args.at(@intCast(index), analyser.ip);
                    if (parameter == .none or info.args_is_generic.isSet(index)) return null;
                    parameter_type.* = Type.fromIP(analyser, .type_type, parameter);
                }
                break :blk types;
            },
            else => return null,
        },
        else => return null,
    };
    return try Type.createTupleType(analyser, parameter_types);
}

fn metaFieldNames(analyser: *Analyser, container_type: Type) Error!?[]const []const u8 {
    if (!container_type.is_type_val) return null;
    return switch (container_type.data) {
        .tuple => |fields| blk: {
            const names = try analyser.arena.alloc([]const u8, fields.len);
            for (names, 0..) |*name, index| {
                name.* = try std.fmt.allocPrint(analyser.arena, "{d}", .{index});
            }
            break :blk names;
        },
        .container => blk: {
            const kind = container_type.getContainerKind() orelse return null;
            if (kind != .keyword_struct and kind != .keyword_union and kind != .keyword_enum) return null;
            var buffer: [2]Ast.Node.Index = undefined;
            const info = astContainerTypeInfo(container_type, &buffer) orelse return null;
            const skip_discard = kind == .keyword_enum;
            const count = if (skip_discard)
                astEnumFieldCount(info.declaration, info.handle)
            else
                astContainerFieldCount(info.declaration, info.handle);
            const names = try analyser.arena.alloc([]const u8, count);
            var index: usize = 0;
            for (info.declaration.ast.members) |member| {
                const field = info.handle.tree.fullContainerField(member) orelse continue;
                const name = try analyser.identifierTokenName(&info.handle.tree, field.ast.main_token) orelse continue;
                if (skip_discard and std.mem.eql(u8, name, "_")) continue;
                names[index] = name;
                index += 1;
            }
            break :blk names;
        },
        .ip_index => |payload| switch (analyser.ip.indexToKey(payload.index orelse return null)) {
            .struct_type => |struct_index| blk: {
                const fields = analyser.ip.getStruct(struct_index).fields;
                const names = try analyser.arena.alloc([]const u8, fields.count());
                for (fields.keys(), names) |field_name, *name| {
                    name.* = try analyser.ip.string_pool.stringToSliceAlloc(analyser.store.io, analyser.arena, field_name);
                }
                break :blk names;
            },
            .union_type => |union_index| blk: {
                const fields = analyser.ip.getUnion(union_index).fields;
                const names = try analyser.arena.alloc([]const u8, fields.count());
                for (fields.keys(), names) |field_name, *name| {
                    name.* = try analyser.ip.string_pool.stringToSliceAlloc(analyser.store.io, analyser.arena, field_name);
                }
                break :blk names;
            },
            .enum_type => |enum_index| blk: {
                const fields = analyser.ip.getEnum(enum_index).fields;
                const names = try analyser.arena.alloc([]const u8, fields.count());
                for (fields.keys(), names) |field_name, *name| {
                    name.* = try analyser.ip.string_pool.stringToSliceAlloc(analyser.store.io, analyser.arena, field_name);
                }
                break :blk names;
            },
            .error_set_type => |error_set| blk: {
                const names = try analyser.arena.alloc([]const u8, error_set.names.len);
                for (names, 0..) |*name, index| {
                    name.* = try analyser.ip.string_pool.stringToSliceAlloc(
                        analyser.store.io,
                        analyser.arena,
                        error_set.names.at(@intCast(index), analyser.ip),
                    );
                }
                break :blk names;
            },
            .tuple_type => |tuple| blk: {
                const names = try analyser.arena.alloc([]const u8, tuple.types.len);
                for (names, 0..) |*name, index| {
                    name.* = try std.fmt.allocPrint(analyser.arena, "{d}", .{index});
                }
                break :blk names;
            },
            else => null,
        },
        .union_tag => |union_type| analyser.metaFieldNames(union_type.*),
        else => null,
    };
}

fn metaFieldNameAt(
    analyser: *Analyser,
    container_type: Type,
    wanted_index: u32,
) error{OutOfMemory}!?[]const u8 {
    if (!container_type.is_type_val) return null;
    return switch (container_type.data) {
        .tuple => |fields| if (wanted_index < fields.len)
            try std.fmt.allocPrint(analyser.arena, "{d}", .{wanted_index})
        else
            null,
        .container => blk: {
            const kind = container_type.getContainerKind() orelse return null;
            if (kind != .keyword_struct and kind != .keyword_union and kind != .keyword_enum) return null;
            var buffer: [2]Ast.Node.Index = undefined;
            const info = astContainerTypeInfo(container_type, &buffer) orelse return null;
            const skip_discard = kind == .keyword_enum;
            var index: u32 = 0;
            for (info.declaration.ast.members) |member| {
                const field = info.handle.tree.fullContainerField(member) orelse continue;
                const name = try analyser.identifierTokenName(&info.handle.tree, field.ast.main_token) orelse continue;
                if (skip_discard and std.mem.eql(u8, name, "_")) continue;
                if (index == wanted_index) break :blk name;
                index += 1;
            }
            break :blk null;
        },
        .ip_index => |payload| switch (analyser.ip.indexToKey(payload.index orelse return null)) {
            .struct_type => |struct_index| blk: {
                const fields = analyser.ip.getStruct(struct_index).fields;
                if (wanted_index >= fields.count()) break :blk null;
                break :blk try analyser.ip.string_pool.stringToSliceAlloc(
                    analyser.store.io,
                    analyser.arena,
                    fields.keys()[wanted_index],
                );
            },
            .union_type => |union_index| blk: {
                const fields = analyser.ip.getUnion(union_index).fields;
                if (wanted_index >= fields.count()) break :blk null;
                break :blk try analyser.ip.string_pool.stringToSliceAlloc(
                    analyser.store.io,
                    analyser.arena,
                    fields.keys()[wanted_index],
                );
            },
            .enum_type => |enum_index| blk: {
                const fields = analyser.ip.getEnum(enum_index).fields;
                if (wanted_index >= fields.count()) break :blk null;
                break :blk try analyser.ip.string_pool.stringToSliceAlloc(
                    analyser.store.io,
                    analyser.arena,
                    fields.keys()[wanted_index],
                );
            },
            .error_set_type => |error_set| blk: {
                if (wanted_index >= error_set.names.len) break :blk null;
                break :blk try analyser.ip.string_pool.stringToSliceAlloc(
                    analyser.store.io,
                    analyser.arena,
                    error_set.names.at(wanted_index, analyser.ip),
                );
            },
            .tuple_type => |tuple| if (wanted_index < tuple.types.len)
                try std.fmt.allocPrint(analyser.arena, "{d}", .{wanted_index})
            else
                null,
            else => null,
        },
        .union_tag => |union_type| analyser.metaFieldNameAt(union_type.*, wanted_index),
        else => null,
    };
}

fn resolveFieldEnumType(analyser: *Analyser, container_type: Type) Error!?Type {
    const names = try analyser.metaFieldNames(container_type) orelse return null;
    if (try analyser.resolveUnionTag(container_type)) |tag_value| reuse_tag: {
        const tag_type = try tag_value.typeOf(analyser);
        const field_count = switch (tag_type.data) {
            .ip_index => |payload| switch (analyser.ip.indexToKey(payload.index orelse break :reuse_tag)) {
                .enum_type => |enum_index| analyser.ip.getEnum(enum_index).fields.count(),
                else => break :reuse_tag,
            },
            .container => blk: {
                if (tag_type.getContainerKind() != .keyword_enum) break :reuse_tag;
                var buffer: [2]Ast.Node.Index = undefined;
                const info = astContainerTypeInfo(tag_type, &buffer) orelse break :reuse_tag;
                break :blk astEnumFieldCount(info.declaration, info.handle);
            },
            .union_tag => ast_field_count: {
                var buffer: [2]Ast.Node.Index = undefined;
                const info = astContainerTypeInfo(tag_type.data.union_tag.*, &buffer) orelse break :reuse_tag;
                break :ast_field_count astContainerFieldCount(info.declaration, info.handle);
            },
            else => break :reuse_tag,
        };
        if (field_count != names.len) break :reuse_tag;
        for (names, 0..) |name, index| {
            const value = try analyser.resolveEnumTagIntValue(tag_type, name) orelse break :reuse_tag;
            if (analyser.ip.toInt(value, usize) != index) break :reuse_tag;
        }
        return tag_type;
    }
    return analyser.createSequentialEnumType(.field, names);
}

fn createSequentialEnumType(
    analyser: *Analyser,
    kind: SequentialEnumKey.Kind,
    names: []const []const u8,
) Error!?Type {
    const key: SequentialEnumKey = .{ .kind = kind, .names = names };
    if (analyser.sequential_enum_types.get(key)) |enum_type| return enum_type;

    const bits: u16 = if (names.len == 0) 0 else @intCast(std.math.log2_int_ceil(usize, names.len));
    const tag_type = try analyser.ip.get(.{ .int_type = .{ .signedness = .unsigned, .bits = bits } });
    var fields: std.array_hash_map.Auto(InternPool.String, void) = .empty;
    errdefer fields.deinit(analyser.gpa);
    var values: std.array_hash_map.Auto(InternPool.Index, void) = .empty;
    errdefer values.deinit(analyser.gpa);
    try fields.ensureTotalCapacity(analyser.gpa, names.len);
    try values.ensureTotalCapacity(analyser.gpa, names.len);
    for (names, 0..) |name, index| {
        const name_index = try analyser.ip.string_pool.getOrPutString(analyser.store.io, analyser.gpa, name);
        const value = (try analyser.intValueWithType(tag_type, index) orelse return null).ipIndex().?;
        fields.putAssumeCapacityNoClobber(name_index, {});
        values.putAssumeCapacityNoClobber(value, {});
    }
    const enum_index = try analyser.ip.createEnum(.{
        .tag_type = tag_type,
        .fields = fields,
        .values = values,
        .namespace = .none,
        .is_exhaustive = true,
    });
    fields = .empty;
    values = .empty;
    const enum_type = Type.fromIP(analyser, .type_type, try analyser.ip.get(.{ .enum_type = enum_index }));
    const owned_names = try analyser.arena.alloc([]const u8, names.len);
    for (names, owned_names) |name, *owned_name| {
        owned_name.* = try analyser.arena.dupe(u8, name);
    }
    try analyser.sequential_enum_types.put(analyser.gpa, .{ .kind = kind, .names = owned_names }, enum_type);
    return enum_type;
}

fn metaDeclarationNames(analyser: *Analyser, container_type: Type) Error!?[]const []const u8 {
    return switch (container_type.data) {
        .tuple => &.{},
        .container => blk: {
            const kind = container_type.getContainerKind() orelse return null;
            if (kind != .keyword_struct and kind != .keyword_union and
                kind != .keyword_enum and kind != .keyword_opaque) return null;
            var buffer: [2]Ast.Node.Index = undefined;
            const info = astContainerTypeInfo(container_type, &buffer) orelse return null;
            const names = try analyser.arena.alloc([]const u8, astContainerDeclarationCount(info.declaration, info.handle));
            var index: usize = 0;
            for (info.declaration.ast.members) |member| {
                const name_token = astContainerDeclarationNameToken(&info.handle.tree, member) orelse continue;
                names[index] = try analyser.identifierTokenName(&info.handle.tree, name_token) orelse return null;
                index += 1;
            }
            break :blk names;
        },
        .ip_index => |payload| switch (analyser.ip.indexToKey(payload.index orelse return null)) {
            .struct_type, .tuple_type, .union_type, .enum_type => &.{},
            .simple_type => |simple| if (simple == .anyopaque) &.{} else null,
            else => null,
        },
        .union_tag => &.{},
        else => null,
    };
}

fn resolveDeclEnumType(analyser: *Analyser, container_type: Type) Error!?Type {
    const names = try analyser.metaDeclarationNames(container_type) orelse return null;
    return analyser.createSequentialEnumType(.declaration, names);
}

fn resolveMetaFieldsValue(
    analyser: *Analyser,
    container_type: Type,
    value_type: Type,
) Error!?Type {
    const tag = analyser.resolveTypeInfoTag(container_type) orelse return null;
    const kind: Type.TypeInfoCollectionKind = switch (tag) {
        .@"struct" => .struct_fields,
        .@"union" => .union_fields,
        .@"enum" => .enum_fields,
        .error_set => .error_set_errors,
        else => return null,
    };
    const names = try analyser.metaFieldNames(container_type) orelse return null;
    return .{ .data = .{ .type_info_value = .{
        .value_type = try analyser.allocType(value_type),
        .reflected_type = try analyser.allocType(container_type),
        .tag = tag,
        .is_payload = true,
        .collection = .{ .kind = kind, .len = names.len, .index = null },
    } }, .is_type_val = false };
}

fn resolveMetaFieldValue(
    analyser: *Analyser,
    container_type: Type,
    field_name: []const u8,
    value_type: Type,
) Error!?Type {
    const tag = analyser.resolveTypeInfoTag(container_type) orelse return null;
    const kind: Type.TypeInfoCollectionKind = switch (tag) {
        .@"struct" => .struct_fields,
        .@"union" => .union_fields,
        .@"enum" => .enum_fields,
        .error_set => .error_set_errors,
        else => return null,
    };
    const names = try analyser.metaFieldNames(container_type) orelse return null;
    const field_index = for (names, 0..) |name, index| {
        if (std.mem.eql(u8, name, field_name)) break index;
    } else return null;
    return .{ .data = .{ .type_info_value = .{
        .value_type = try analyser.allocType(value_type),
        .reflected_type = try analyser.allocType(container_type),
        .tag = tag,
        .is_payload = true,
        .collection = .{ .kind = kind, .len = names.len, .index = @intCast(field_index) },
    } }, .is_type_val = false };
}

fn resolveMetaFieldNamesValue(
    analyser: *Analyser,
    container_type: Type,
    value_type: Type,
) Error!?Type {
    const tag = analyser.resolveTypeInfoTag(container_type) orelse return null;
    switch (tag) {
        .@"struct", .@"union", .@"enum", .error_set => {},
        else => return null,
    }
    const names = try analyser.metaFieldNames(container_type) orelse return null;
    return .{ .data = .{ .type_info_value = .{
        .value_type = try analyser.allocType(value_type),
        .reflected_type = try analyser.allocType(container_type),
        .tag = tag,
        .is_payload = true,
        .collection = .{ .kind = .field_names, .len = names.len, .index = null },
    } }, .is_type_val = false };
}

fn resolveMetaTagsValue(
    analyser: *Analyser,
    container_type: Type,
    value_type: Type,
) Error!?Type {
    const tag = analyser.resolveTypeInfoTag(container_type) orelse return null;
    switch (tag) {
        .@"enum", .error_set => {},
        else => return null,
    }
    const names = try analyser.metaFieldNames(container_type) orelse return null;
    return .{ .data = .{ .type_info_value = .{
        .value_type = try analyser.allocType(value_type),
        .reflected_type = try analyser.allocType(container_type),
        .tag = tag,
        .is_payload = true,
        .collection = .{ .kind = .tags, .len = names.len, .index = null },
    } }, .is_type_val = false };
}

fn metaTagValueAt(
    analyser: *Analyser,
    container_type: Type,
    wanted_index: u32,
) error{OutOfMemory}!?Type {
    const name = try analyser.metaFieldNameAt(container_type, wanted_index) orelse return null;
    return switch (analyser.resolveTypeInfoTag(container_type) orelse return null) {
        .@"enum" => analyser.enumValue(container_type, name) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return null,
        },
        .error_set => blk: {
            const error_set_type = container_type.ipIndex() orelse return null;
            if (analyser.ip.indexToKey(error_set_type) != .error_set_type) return null;
            const name_index = try analyser.ip.string_pool.getOrPutString(analyser.store.io, analyser.gpa, name);
            const error_value = try analyser.ip.get(.{ .error_value = .{
                .ty = error_set_type,
                .error_tag_name = name_index,
            } });
            break :blk Type.fromIP(analyser, error_set_type, error_value);
        },
        else => null,
    };
}

fn resolveMetaDeclarationsValue(
    analyser: *Analyser,
    container_type: Type,
    value_type: Type,
) Error!?Type {
    const tag = analyser.resolveTypeInfoTag(container_type) orelse return null;
    const declaration_names = try analyser.metaDeclarationNames(container_type) orelse return null;
    return .{ .data = .{ .type_info_value = .{
        .value_type = try analyser.allocType(value_type),
        .reflected_type = try analyser.allocType(container_type),
        .tag = tag,
        .is_payload = true,
        .collection = .{ .kind = .container_decls, .len = declaration_names.len, .index = null },
    } }, .is_type_val = false };
}

fn resolveMetaDeclarationValue(
    analyser: *Analyser,
    container_type: Type,
    declaration_name: []const u8,
    value_type: Type,
) Error!?Type {
    const tag = analyser.resolveTypeInfoTag(container_type) orelse return null;
    const declaration_names = try analyser.metaDeclarationNames(container_type) orelse return null;
    const declaration_index = for (declaration_names, 0..) |name, index| {
        if (std.mem.eql(u8, name, declaration_name)) break index;
    } else return null;
    return .{ .data = .{ .type_info_value = .{
        .value_type = try analyser.allocType(value_type),
        .reflected_type = try analyser.allocType(container_type),
        .tag = tag,
        .is_payload = true,
        .collection = .{
            .kind = .container_decls,
            .len = declaration_names.len,
            .index = @intCast(declaration_index),
        },
    } }, .is_type_val = false };
}

fn resolveSwitchUnionPayload(
    analyser: *Analyser,
    union_type: Type,
    switch_tree: *const Ast,
    switch_node: Ast.full.Switch,
    selected_case: Ast.full.SwitchCase,
) Error!?Type {
    if (try analyser.resolveKnownUnionFieldName(union_type)) |active_field| {
        if (selected_case.ast.values.len == 0 and selected_case.inline_token != null) {
            return analyser.resolveFieldAccess(union_type, active_field);
        }
        for (selected_case.ast.values) |case_value| {
            if (switch_tree.nodeTag(case_value) != .enum_literal) break;
            const case_name = try analyser.identifierTokenName(switch_tree, switch_tree.nodeMainToken(case_value)) orelse break;
            if (std.mem.eql(u8, active_field, case_name)) {
                return analyser.resolveFieldAccess(union_type, active_field);
            }
        }
    }
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

pub fn resolveSwitchCaptureValue(
    analyser: *Analyser,
    condition: Type,
    tree: *const Ast,
    switch_node: Ast.full.Switch,
    case: Ast.full.SwitchCase,
    tag_capture: bool,
) Error!?Type {
    const condition_type = try condition.typeOf(analyser);
    if (condition_type.ipIndex()) |type_index| {
        const type_tag = analyser.ip.zigTypeTag(type_index);
        if (type_tag == .null or type_tag == .undefined) return null;
    }
    if (tag_capture) {
        const tag_value = try analyser.resolveUnionTag(condition_type) orelse return null;
        const active_field = try analyser.resolveKnownUnionFieldName(condition) orelse return tag_value;
        return try analyser.enumValue(try tag_value.typeOf(analyser), active_field);
    }
    if (condition.data == .type_info_value and case.ast.values.len == 1) {
        const case_value = case.ast.values[0];
        if (tree.nodeTag(case_value) == .enum_literal) {
            const case_tag_name = try analyser.identifierTokenName(tree, tree.nodeMainToken(case_value)) orelse return null;
            if (std.mem.eql(u8, case_tag_name, @tagName(condition.data.type_info_value.tag))) {
                return analyser.resolveTypeInfoFieldAccess(condition.data.type_info_value, case_tag_name);
            }
        }
    }
    if (condition.isEnumType(analyser)) return condition;
    var literal_buffer: [2]Ast.Node.Index = undefined;
    const aggregate_case = for (case.ast.values) |case_value| {
        if (tree.fullStructInit(&literal_buffer, case_value) != null or
            tree.fullArrayInit(&literal_buffer, case_value) != null) break true;
    } else false;
    if (aggregate_case) return condition;
    if (!condition_type.isUnionType() and
        if (condition_type.ipIndex()) |index| analyser.ip.zigTypeTag(index) != .@"union" else true)
    {
        return condition;
    }
    if (case.ast.values.len == 0 and case.inline_token == null) return condition;
    return analyser.resolveSwitchUnionPayload(condition, tree, switch_node, case);
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
    if (pointer.data == .comptime_value) {
        const comptime_value = pointer.data.comptime_value;
        switch (comptime_value.data) {
            .reference => |reference| {
                const target = if (analyser.comptime_interpreter) |interpreter|
                    interpreter.readReference(reference) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.Canceled => return null,
                    }
                else if (reference.path.len == 0) reference.storage.value else null;
                if (target) |value| return .{ .type = value, .is_const = false };
            },
            .array => |items| {
                const pointer_instance = try comptime_value.ty.instanceUnchecked(analyser);
                const pointee = try analyser.resolveDerefType(pointer_instance) orelse return null;
                return .{
                    .type = try comptime_eval.Value.create(analyser, try pointee.typeOf(analyser), .{ .array = items }),
                    .is_const = true,
                };
            },
            .sequence => |sequence| {
                if (!sequence.elements_valid) return null;
                const pointer_instance = try comptime_value.ty.instanceUnchecked(analyser);
                const pointee = try analyser.resolveDerefType(pointer_instance) orelse return null;
                if (comptime_value.ty.sequencePointerLength(analyser) == null) {
                    if (sequence.len != 1) return null;
                    return .{
                        .type = sequence.backing[sequence.offset],
                        .is_const = true,
                    };
                }
                return .{
                    .type = try comptime_eval.Value.create(
                        analyser,
                        try pointee.typeOf(analyser),
                        .{ .array = sequence.backing[sequence.offset..][0..sequence.len] },
                    ),
                    .is_const = true,
                };
            },
            .fields => |fields| {
                const pointer_instance = try comptime_value.ty.instanceUnchecked(analyser);
                const pointee = try analyser.resolveDerefType(pointer_instance) orelse return null;
                return .{
                    .type = try comptime_eval.Value.create(analyser, try pointee.typeOf(analyser), .{ .fields = fields }),
                    .is_const = true,
                };
            },
            .pointee => |pointee| return .{ .type = pointee.value, .is_const = true },
            else => {},
        }
    }
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

fn resolveSplatValueFromIndex(
    analyser: *Analyser,
    vector_type: InternPool.Index,
    scalar: InternPool.Index,
) error{OutOfMemory}!?InternPool.Index {
    const vector = switch (analyser.ip.indexToKey(vector_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    if (analyser.ip.isUndefined(scalar) or analyser.ip.isUnknown(scalar)) return null;
    const values = try analyser.gpa.alloc(InternPool.Index, vector.len);
    defer analyser.gpa.free(values);
    @memset(values, scalar);
    return try analyser.ip.get(.{ .aggregate = .{
        .ty = vector_type,
        .values = try analyser.ip.getIndexSlice(values),
    } });
}

pub fn resolveComptimeSplatValue(
    analyser: *Analyser,
    vector_type_value: Type,
    scalar: Type,
) error{OutOfMemory}!?Type {
    if (!vector_type_value.is_type_val) return null;
    const vector_type = vector_type_value.ipIndex() orelse return null;
    const vector = switch (analyser.ip.indexToKey(vector_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    if (scalar.data != .ip_index) {
        const scalar_type = (try scalar.typeOf(analyser)).ipIndex() orelse return null;
        const child_type = Type.fromIP(analyser, .type_type, vector.child);
        const coerced = if (scalar_type == vector.child)
            scalar
        else blk: {
            _ = try analyser.coerceComptimeIPValue(
                vector.child,
                Type.fromIP(analyser, scalar_type, null),
            ) orelse return null;
            if (scalar.data != .comptime_value) return null;
            break :blk switch (scalar.data.comptime_value.data) {
                .reference => |reference| try comptime_eval.Value.create(analyser, child_type, .{ .reference = reference }),
                .pointee => |pointee| try comptime_eval.Value.create(analyser, child_type, .{ .pointee = pointee }),
                .sequence => |sequence| try comptime_eval.Value.create(analyser, child_type, .{ .sequence = sequence }),
                else => return null,
            };
        };
        const values = try analyser.arena.alloc(Type, vector.len);
        @memset(values, coerced);
        return @as(?Type, try comptime_eval.Value.create(
            analyser,
            Type.fromIP(analyser, .type_type, vector_type),
            .{ .array = values },
        ));
    }
    const scalar_payload = switch (scalar.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    if (scalar_payload.type == .unknown_type) return null;
    const coerced = try analyser.coerceComptimeIPValue(vector.child, scalar) orelse return null;
    if (analyser.ip.isUndefined(coerced)) return null;
    if (analyser.ip.isUnknown(coerced)) return Type.fromIP(analyser, vector_type, null);
    const value = try analyser.resolveSplatValueFromIndex(vector_type, coerced) orelse return null;
    return Type.fromIP(analyser, vector_type, value);
}

fn resolveVectorIntFromBoolValue(analyser: *Analyser, operand: Type) error{OutOfMemory}!?Type {
    const operand_type = (try operand.typeOf(analyser)).ipIndex() orelse return null;
    const vector = switch (analyser.ip.indexToKey(operand_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    if (vector.child != .bool_type) return null;

    const result_type = try analyser.ip.get(.{ .vector_type = .{
        .len = vector.len,
        .child = .u1_type,
    } });
    const result = Type.fromIP(analyser, result_type, null);
    const source_items = comptime_eval.Value.elements(operand);
    const source_values = analyser.aggregateValues(operand);
    if (source_items == null and source_values == null) return result;
    if ((source_items != null and source_items.?.len != vector.len) or
        (source_values != null and source_values.?.len != vector.len)) return null;

    const values = try analyser.gpa.alloc(InternPool.Index, vector.len);
    defer analyser.gpa.free(values);
    for (values, 0..) |*value, i| {
        const source = if (source_items) |items|
            items[i].ipIndex() orelse .unknown_unknown
        else
            source_values.?.at(@intCast(i), analyser.ip);
        value.* = switch (source) {
            .bool_true => .one_u1,
            .bool_false => .zero_u1,
            else => try analyser.ip.getUnknown(.u1_type),
        };
    }
    return analyser.aggregateValue(result, values);
}

pub fn resolveComptimeIntFromBoolValue(analyser: *Analyser, operand: Type) error{OutOfMemory}!?Type {
    if (try analyser.resolveVectorIntFromBoolValue(operand)) |result| return result;
    const payload = switch (operand.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    if (payload.type != .bool_type) return null;
    const value = payload.index orelse return Type.fromIP(analyser, .u1_type, null);
    return switch (value) {
        .bool_true => Type.fromIP(analyser, .u1_type, .one_u1),
        .bool_false => Type.fromIP(analyser, .u1_type, .zero_u1),
        else => if (analyser.ip.isUnknown(value)) Type.fromIP(analyser, .u1_type, null) else null,
    };
}

fn resolveVectorCastValue(
    analyser: *Analyser,
    tag: std.zig.BuiltinFn.Tag,
    dest_type: InternPool.Index,
    source: Type,
) error{OutOfMemory}!?InternPool.Index {
    const dest_vector = switch (analyser.ip.indexToKey(dest_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    const source_type = (try source.typeOf(analyser)).ipIndex() orelse return null;
    const source_vector = switch (analyser.ip.indexToKey(source_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    if (dest_vector.len != source_vector.len) return null;
    const source_items = comptime_eval.Value.elements(source);
    const source_values = analyser.aggregateValues(source);
    if (source_items == null and source_values == null) return null;
    if ((source_items != null and source_items.?.len != source_vector.len) or
        (source_values != null and source_values.?.len != source_vector.len)) return null;

    const values = try analyser.gpa.alloc(InternPool.Index, dest_vector.len);
    defer analyser.gpa.free(values);
    for (values, 0..) |*value, i| {
        const source_value = if (source_items) |items|
            items[i].ipIndex() orelse try analyser.ip.getUnknown(source_vector.child)
        else
            source_values.?.at(@intCast(i), analyser.ip);
        value.* = switch (tag) {
            .int_from_float => try analyser.intFromFloatValue(dest_vector.child, source_value),
            .float_from_int => try analyser.floatFromIntValue(dest_vector.child, source_value),
            .float_cast => try analyser.coerceFloatValue(dest_vector.child, source_value),
            .bit_cast => try analyser.bitCastIntValue(dest_vector.child, source_value),
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
            const struct_init = tree.fullStructInit(&buffer, options.node_handle.node).?;
            return switch (analyser.ip.indexToKey(aggregate_type)) {
                .struct_type => |struct_index| analyser.resolveStructLiteralValue(
                    aggregate_type,
                    struct_index,
                    struct_init.ast.fields,
                    options,
                ),
                .union_type => |union_index| analyser.resolveUnionLiteralValue(
                    aggregate_type,
                    union_index,
                    struct_init.ast.fields,
                    options,
                ),
                else => null,
            };
        },
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

fn resolveStructLiteralValue(
    analyser: *Analyser,
    struct_type: InternPool.Index,
    struct_index: InternPool.Struct.Index,
    fields: []const Ast.Node.Index,
    options: ResolveOptions,
) Error!?InternPool.Index {
    const tree = &options.node_handle.handle.tree;
    const struct_info = analyser.ip.getStruct(struct_index);
    const values = try analyser.gpa.alloc(InternPool.Index, struct_info.fields.count());
    defer analyser.gpa.free(values);
    var initialized = try std.DynamicBitSetUnmanaged.initEmpty(analyser.gpa, values.len);
    defer initialized.deinit(analyser.gpa);
    for (struct_info.fields.values(), values) |field, *value| {
        value.* = if (field.default_value != .none)
            field.default_value
        else
            try analyser.ip.getUnknown(field.ty);
    }
    for (fields) |field_node| {
        const field_name_token = tree.firstToken(field_node) - 2;
        if (tree.tokenTag(field_name_token) != .identifier) return null;
        const field_name = try analyser.identifierTokenName(tree, field_name_token) orelse return null;
        const name_index = analyser.ip.string_pool.getString(analyser.store.io, field_name) orelse return null;
        const field_index = struct_info.fields.getIndex(name_index) orelse return null;
        if (initialized.isSet(field_index)) return null;
        initialized.set(field_index);
        const field_type = struct_info.fields.values()[field_index].ty;
        values[field_index] = try analyser.resolveCoercedIPValue(field_type, .{
            .node_handle = .of(field_node, options.node_handle.handle),
            .container_type = options.container_type,
        }) orelse try analyser.ip.getUnknown(field_type);
    }
    if (initialized.count() != values.len) {
        for (struct_info.fields.values(), 0..) |field, field_index| {
            if (!initialized.isSet(field_index) and field.default_value == .none) return null;
        }
    }
    return try analyser.ip.get(.{ .aggregate = .{
        .ty = struct_type,
        .values = try analyser.ip.getIndexSlice(values),
    } });
}

fn resolveUnionLiteralValue(
    analyser: *Analyser,
    union_type: InternPool.Index,
    union_index: InternPool.Union.Index,
    fields: []const Ast.Node.Index,
    options: ResolveOptions,
) Error!?InternPool.Index {
    if (fields.len != 1) return null;
    const tree = &options.node_handle.handle.tree;
    const field_node = fields[0];
    const field_name_token = tree.firstToken(field_node) - 2;
    if (tree.tokenTag(field_name_token) != .identifier) return null;
    const field_name = try analyser.identifierTokenName(tree, field_name_token) orelse return null;
    const union_info = analyser.ip.getUnion(union_index);
    const name_index = analyser.ip.string_pool.getString(analyser.store.io, field_name) orelse return null;
    const field_index = union_info.fields.getIndex(name_index) orelse return null;
    const field_type = union_info.fields.values()[field_index].ty;
    const value_options: ResolveOptions = .{
        .node_handle = .of(field_node, options.node_handle.handle),
        .container_type = options.container_type,
    };
    const value = try analyser.resolveCoercedIPValue(field_type, value_options) orelse value: {
        const source_value = try analyser.resolveTypeOfNodeInternal(value_options) orelse
            break :value try analyser.ip.getUnknown(field_type);
        break :value try analyser.coerceComptimeIPValue(field_type, source_value) orelse return null;
    };
    return try analyser.ip.get(.{ .union_value = .{
        .ty = union_type,
        .field_index = @intCast(field_index),
        .val = value,
    } });
}

const ComptimeUnionInitField = struct {
    union_type: InternPool.Index,
    field_index: u32,
    field_type: InternPool.Index,
};

fn resolveComptimeUnionInitField(
    analyser: *Analyser,
    union_type: Type,
    field_name: []const u8,
) ?ComptimeUnionInitField {
    if (!union_type.is_type_val) return null;
    const type_index = union_type.ipIndex() orelse return null;
    const union_index = switch (analyser.ip.indexToKey(type_index)) {
        .union_type => |union_index| union_index,
        else => return null,
    };
    const union_info = analyser.ip.getUnion(union_index);
    const name_index = analyser.ip.string_pool.getString(analyser.store.io, field_name) orelse return null;
    const field_index = union_info.fields.getIndex(name_index) orelse return null;
    return .{
        .union_type = type_index,
        .field_index = @intCast(field_index),
        .field_type = union_info.fields.values()[field_index].ty,
    };
}

fn comptimeUnionInitValue(
    analyser: *Analyser,
    field: ComptimeUnionInitField,
    value: InternPool.Index,
) error{OutOfMemory}!Type {
    const union_value = try analyser.ip.get(.{ .union_value = .{
        .ty = field.union_type,
        .field_index = field.field_index,
        .val = value,
    } });
    return Type.fromIP(analyser, field.union_type, union_value);
}

pub fn coerceComptimeIPValue(
    analyser: *Analyser,
    destination_type: InternPool.Index,
    value: Type,
) error{OutOfMemory}!?InternPool.Index {
    const value_payload = switch (value.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const value_index = value_payload.index orelse try analyser.ip.getUnknown(value_payload.type);
    const typed_value_index = if (analyser.ip.isUnknown(value_index))
        try analyser.ip.getUnknown(value_payload.type)
    else
        value_index;
    if (destination_type == value_payload.type) return typed_value_index;
    const source_tag = analyser.ip.zigTypeTag(value_payload.type);
    if (!analyser.ip.isUnknown(typed_value_index) and
        analyser.ip.zigTypeTag(destination_type) == .int and
        (source_tag == .int or source_tag == .comptime_int))
    {
        const int = analyser.ip.toInt(typed_value_index, i256) orelse return null;
        return (try analyser.intValueWithType(destination_type, int) orelse return null).ipIndex();
    }
    if (!analyser.ip.isUnknown(typed_value_index) and
        analyser.ip.zigTypeTag(destination_type) == .float and
        (source_tag == .float or source_tag == .comptime_float))
    {
        const coerced = try analyser.coerceFloatValue(destination_type, typed_value_index) orelse return null;
        if (source_tag == .float and
            try analyser.coerceFloatValue(value_payload.type, coerced) != typed_value_index) return null;
        return coerced;
    }
    if (!analyser.ip.isUnknown(typed_value_index) and
        analyser.ip.zigTypeTag(destination_type) == .float and
        source_tag == .comptime_int)
    {
        return analyser.coerceExactIntToFloatValue(destination_type, typed_value_index);
    }
    const coerced = try analyser.coerceIP(destination_type, typed_value_index) orelse return null;
    if (!analyser.ip.isUnknown(typed_value_index) and
        analyser.ip.zigTypeTag(destination_type) == .error_set and
        source_tag == .error_set)
    {
        const error_value = switch (analyser.ip.indexToKey(typed_value_index)) {
            .error_value => |error_value| error_value,
            else => return null,
        };
        return @as(?InternPool.Index, try analyser.ip.get(.{ .error_value = .{
            .ty = destination_type,
            .error_tag_name = error_value.error_tag_name,
        } }));
    }
    return if (analyser.ip.isUnknown(coerced))
        try analyser.ip.getUnknown(destination_type)
    else
        coerced;
}

pub fn resolveComptimeUnionInitValue(
    analyser: *Analyser,
    union_type: Type,
    field_name: []const u8,
    value: Type,
) Error!?Type {
    const fallback = try union_type.instanceTypeVal(analyser);
    const field = analyser.resolveComptimeUnionInitField(union_type, field_name) orelse return fallback;
    const payload = try analyser.coerceComptimeIPValue(field.field_type, value) orelse return fallback;
    return try analyser.comptimeUnionInitValue(field, payload);
}

pub fn resolveComptimeVectorType(
    analyser: *Analyser,
    len: u32,
    child_type: Type,
) error{OutOfMemory}!?Type {
    if (!child_type.is_type_val) return null;
    return .{
        .data = try Type.Data.createVector(analyser, len, child_type),
        .is_type_val = true,
    };
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

fn sequenceSentinel(analyser: *Analyser, value: Type) ?InternPool.Index {
    const ty = switch (value.data) {
        .comptime_value => |comptime_value| comptime_value.ty,
        .string_value => |string_value| string_value.string_type.*,
        else => value,
    };
    const pointer_info = switch (ty.data) {
        .array => |info| return if (info.sentinel == .none or info.sentinel == .unknown_unknown)
            null
        else
            info.sentinel,
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
        .ip_index => |payload| switch (analyser.ip.indexToKey(if (ty.is_type_val)
            payload.index orelse return null
        else
            payload.type)) {
            .array_type => |info| return if (info.sentinel == .none or info.sentinel == .unknown_unknown)
                null
            else
                info.sentinel,
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
                    .is_volatile = info.flags.is_volatile,
                    .is_allowzero = info.flags.is_allowzero,
                    .address_space = info.flags.address_space,
                    .alignment = info.flags.alignment,
                    .packed_offset = info.packed_offset,
                    .elem_ty = try analyser.allocType(try analyser.bracketAccessTypeFromIPIndex(info.elem_type)),
                },
            },
            .is_type_val = true,
        },
        else => Type.fromIP(analyser, .type_type, ip_index),
    };
}

pub fn resolveBracketAccess(analyser: *Analyser, lhs_binding: Binding, rhs: BracketAccess) error{OutOfMemory}!?Binding {
    const lhs_value = comptime_eval.Value.deref(lhs_binding.type);
    const comptime_items: ?[]const Type = comptime_eval.Value.elements(lhs_value) orelse blk: {
        if (!analyser.evaluate_comptime_values) break :blk null;
        const payload = switch (lhs_value.data) {
            .ip_index => |payload| payload,
            else => break :blk null,
        };
        const value_index = payload.index orelse break :blk null;
        const aggregate = switch (analyser.ip.indexToKey(value_index)) {
            .aggregate => |aggregate| aggregate,
            else => break :blk null,
        };
        const item_indices = aggregate.values.dupe(analyser.arena, analyser.ip) catch return error.OutOfMemory;
        const items = try analyser.arena.alloc(Type, item_indices.len);
        for (item_indices, items) |item_index, *item| {
            item.* = Type.fromIP(analyser, analyser.ip.typeOf(item_index), item_index);
        }
        break :blk items;
    };
    if (lhs_binding.type.data == .comptime_value or analyser.comptime_interpreter != null) if (comptime_items) |items| {
        const value_type = switch (lhs_value.data) {
            .comptime_value => |value| value.ty,
            else => try lhs_value.typeOf(analyser),
        };
        switch (rhs) {
            .single => |index_optional| if (index_optional) |index| {
                if (index < items.len) return .{ .type = items[@intCast(index)], .is_const = true };
                if (index == items.len) {
                    const sentinel = analyser.sequenceSentinel(lhs_binding.type) orelse return null;
                    return .{
                        .type = Type.fromIP(analyser, analyser.ip.typeOf(sentinel), sentinel),
                        .is_const = true,
                    };
                }
                return null;
            },
            .open => |access| if (access.start != null) {
                const start = std.math.cast(usize, access.start.?) orelse return null;
                if (start > items.len) return null;
                const sliced = try analyser.resolveBracketAccess(.{
                    .type = try value_type.instanceUnchecked(analyser),
                    .is_const = lhs_binding.is_const,
                }, rhs) orelse return null;
                if (comptime_eval.Value.sequence(lhs_value)) |view| return .{
                    .type = try comptime_eval.Value.create(analyser, try sliced.type.typeOf(analyser), .{ .sequence = .{
                        .backing = view.backing,
                        .offset = view.offset + start,
                        .len = items.len - start,
                        .elements_valid = view.elements_valid,
                        .origin = view.origin,
                    } }),
                    .is_const = true,
                };
                return .{
                    .type = try comptime_eval.Value.create(analyser, try sliced.type.typeOf(analyser), .{ .array = items[start..] }),
                    .is_const = true,
                };
            },
            .range => |access| if (access.bounds != null) {
                const start = std.math.cast(usize, access.bounds.?[0]) orelse return null;
                const end = std.math.cast(usize, access.bounds.?[1]) orelse return null;
                if (start > end or end > items.len) return null;
                const sliced = try analyser.resolveBracketAccess(.{
                    .type = try value_type.instanceUnchecked(analyser),
                    .is_const = lhs_binding.is_const,
                }, rhs) orelse return null;
                if (comptime_eval.Value.sequence(lhs_value)) |view| return .{
                    .type = try comptime_eval.Value.create(analyser, try sliced.type.typeOf(analyser), .{ .sequence = .{
                        .backing = view.backing,
                        .offset = view.offset + start,
                        .len = end - start,
                        .elements_valid = view.elements_valid,
                        .origin = view.origin,
                    } }),
                    .is_const = true,
                };
                return .{
                    .type = try comptime_eval.Value.create(analyser, try sliced.type.typeOf(analyser), .{ .array = items[start..end] }),
                    .is_const = true,
                };
            },
        }
    };
    if (analyser.evaluate_comptime_values and lhs_binding.type.data == .type_info_value) {
        const value = lhs_binding.type.data.type_info_value;
        if (value.collection) |collection| switch (rhs) {
            .single => |index_optional| if (index_optional) |index| {
                if (!collection.is_optional and collection.index == null and index < collection.len) {
                    const element_type = try analyser.resolveBracketAccessType(value.value_type.*, rhs) orelse return null;
                    if (collection.kind == .field_names) {
                        const name = try analyser.metaFieldNameAt(value.reflected_type.*, @intCast(index)) orelse return null;
                        return .{
                            .type = try analyser.stringValueWithType(
                                name,
                                try element_type.typeOf(analyser),
                            ),
                            .is_const = true,
                        };
                    }
                    if (collection.kind == .tags) {
                        return .{
                            .type = try analyser.metaTagValueAt(value.reflected_type.*, @intCast(index)) orelse return null,
                            .is_const = true,
                        };
                    }
                    return .{
                        .type = .{ .data = .{ .type_info_value = .{
                            .value_type = try analyser.allocType(element_type),
                            .reflected_type = value.reflected_type,
                            .tag = value.tag,
                            .is_payload = true,
                            .collection = .{
                                .kind = collection.kind,
                                .len = collection.len,
                                .index = @intCast(index),
                            },
                        } }, .is_type_val = false },
                        .is_const = true,
                    };
                }
            },
            .open, .range => {},
        };
    }
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
                    analyser.sequenceSentinel(lhs_binding.type) orelse return null
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
            if (analyser.evaluate_comptime_values) {
                const lhs = lhs_binding.type.runtimeType(analyser);
                if (lhs.arrayInfo(analyser)) |array_info| {
                    if (array_info[0] == index) {
                        const sentinel = analyser.sequenceSentinel(lhs_binding.type) orelse return null;
                        return .{
                            .type = Type.fromIP(analyser, analyser.ip.typeOf(sentinel), sentinel),
                            .is_const = true,
                        };
                    }
                }
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
        .vector => |info| switch (rhs) {
            .single => {
                const instance = try info.elem_ty.instanceUnchecked(analyser);
                return .{ .type = instance, .is_const = is_const };
            },
            .open, .range => return null,
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
            if (rhs == .single) {
                const child_type = switch (analyser.ip.indexToKey(payload.type)) {
                    .array_type => |array| array.child,
                    .vector_type => |vector| vector.child,
                    .tuple_type => |tuple| tuple_child: {
                        const index = rhs.single orelse return null;
                        if (index >= tuple.types.len) return null;
                        break :tuple_child tuple.types.at(@intCast(index), analyser.ip);
                    },
                    else => null,
                };
                if (child_type) |child| {
                    return .{
                        .type = Type.fromIP(analyser, child, null),
                        .is_const = is_const,
                    };
                }
            }
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
    if (ty.data == .comptime_value) {
        const value = ty.data.comptime_value;
        if (value.data == .optional) {
            if (std.mem.eql(u8, name, "?")) return value.data.optional;
            return null;
        }
    }
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
                                .is_volatile = info.is_volatile,
                                .is_allowzero = info.is_allowzero,
                                .address_space = info.address_space,
                                .alignment = info.alignment,
                                .packed_offset = info.packed_offset,
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

        .vector => |info| {
            if (std.mem.eql(u8, "len", name)) {
                const index = try analyser.ip.get(
                    .{ .int_u64_value = .{ .ty = .usize_type, .int = info.len } },
                );
                return Type.fromIP(analyser, .usize_type, index);
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

            .struct_type => |struct_index| {
                const struct_info = analyser.ip.getStruct(struct_index);
                const name_index = analyser.ip.string_pool.getString(analyser.store.io, name) orelse return null;
                const field_index = struct_info.fields.getIndex(name_index) orelse return null;
                const field_type = struct_info.fields.values()[field_index].ty;
                if (analyser.generated_struct_fields.get(payload.type)) |fields| {
                    const field = fields[field_index];
                    if (field.ty.ipIndex() == null) return try field.ty.instanceUnchecked(analyser);
                }
                const value_index = payload.index orelse return Type.fromIP(analyser, field_type, null);
                const aggregate = switch (analyser.ip.indexToKey(value_index)) {
                    .aggregate => |aggregate| aggregate,
                    else => return Type.fromIP(analyser, field_type, null),
                };
                if (aggregate.ty != payload.type or field_index >= aggregate.values.len)
                    return Type.fromIP(analyser, field_type, null);
                const value = aggregate.values.at(@intCast(field_index), analyser.ip);
                if (value == .none or analyser.ip.isUndefined(value) or analyser.ip.isUnknown(value))
                    return Type.fromIP(analyser, field_type, null);
                return Type.fromIP(analyser, field_type, value);
            },

            .union_type => |union_index| {
                const union_info = analyser.ip.getUnion(union_index);
                const name_index = analyser.ip.string_pool.getString(analyser.store.io, name) orelse return null;
                const field_index = union_info.fields.getIndex(name_index) orelse return null;
                const field_type = union_info.fields.values()[field_index].ty;
                const value_index = payload.index orelse return Type.fromIP(analyser, field_type, null);
                const union_value = switch (analyser.ip.indexToKey(value_index)) {
                    .union_value => |union_value| union_value,
                    else => return Type.fromIP(analyser, field_type, null),
                };
                if (union_value.ty != payload.type or union_value.field_index != field_index)
                    return Type.fromIP(analyser, field_type, null);
                if (analyser.ip.isUndefined(union_value.val) or analyser.ip.isUnknown(union_value.val))
                    return Type.fromIP(analyser, field_type, null);
                return Type.fromIP(analyser, field_type, union_value.val);
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

fn comptimeArrayElements(analyser: *Analyser, value: Type) Error!?[]const Type {
    if (comptime_eval.Value.elements(value)) |items| return items;
    const source = analyser.aggregateValues(value) orelse return null;
    const items = try analyser.arena.alloc(Type, source.len);
    for (items, 0..) |*item, index| {
        const item_index = source.at(@intCast(index), analyser.ip);
        item.* = Type.fromIP(analyser, analyser.ip.typeOf(item_index), item_index);
    }
    return items;
}

fn coerceComptimeArrayElements(
    analyser: *Analyser,
    destination: []Type,
    source: []const Type,
    child_type: InternPool.Index,
) Error!void {
    std.debug.assert(destination.len == source.len);
    const unknown = try analyser.ip.getUnknown(child_type);
    for (destination, source) |*result, item| {
        const item_index = item.ipIndex() orelse {
            result.* = item;
            continue;
        };
        const coerced = try analyser.coerceArrayElementValue(child_type, item_index) orelse unknown;
        result.* = Type.fromIP(analyser, child_type, coerced);
    }
}

pub fn resolveComptimeArrayMultValue(analyser: *Analyser, operand: Type, mult: ?u64) Error!?Type {
    const result = try analyser.resolveArrayMultExpression(operand, mult) orelse return null;
    if (operand.data == .string_value and mult != null) {
        const source = operand.data.string_value.bytes;
        const multiplier = std.math.cast(usize, mult.?) orelse return null;
        const len = std.math.mul(usize, source.len, multiplier) catch return null;
        const bytes = try analyser.arena.alloc(u8, len);
        for (0..multiplier) |index| {
            const offset = index * source.len;
            @memcpy(bytes[offset..][0..source.len], source);
        }
        return try analyser.stringValueWithType(bytes, try result.typeOf(analyser));
    }
    if (mult) |count| {
        if (analyser.aggregateValues(operand)) |source_values| {
            const source = try source_values.dupe(analyser.gpa, analyser.ip);
            defer analyser.gpa.free(source);
            const multiplier = std.math.cast(usize, count) orelse return result;
            const len = std.math.mul(usize, source.len, multiplier) catch return result;
            const values = try analyser.gpa.alloc(InternPool.Index, len);
            defer analyser.gpa.free(values);
            for (0..multiplier) |index| {
                @memcpy(values[index * source.len ..][0..source.len], source);
            }
            return try analyser.aggregateValue(result, values) orelse result;
        }
        if (try analyser.comptimeArrayElements(operand)) |source| {
            const multiplier = std.math.cast(usize, count) orelse return result;
            const len = std.math.mul(usize, source.len, multiplier) catch return result;
            const values = try analyser.arena.alloc(Type, len);
            for (0..multiplier) |index| {
                @memcpy(values[index * source.len ..][0..source.len], source);
            }
            return try comptime_eval.Value.create(analyser, try result.typeOf(analyser), .{ .array = values });
        }
    }
    return result;
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

pub fn resolveComptimeArrayCatValue(analyser: *Analyser, lhs: Type, rhs: Type) Error!?Type {
    const result = try analyser.resolveArrayCatExpression(lhs, rhs) orelse return null;
    if (lhs.data == .string_value and rhs.data == .string_value) {
        const bytes = try std.mem.concat(analyser.arena, u8, &.{
            lhs.data.string_value.bytes,
            rhs.data.string_value.bytes,
        });
        return try analyser.stringValueWithType(bytes, try result.typeOf(analyser));
    }
    if (comptime_eval.Value.elements(lhs) != null or comptime_eval.Value.elements(rhs) != null) {
        const lhs_items = try analyser.comptimeArrayElements(lhs) orelse return result;
        const rhs_items = try analyser.comptimeArrayElements(rhs) orelse return result;
        const result_type = (try result.typeOf(analyser)).ipIndex() orelse return result;
        const child_type = switch (analyser.ip.indexToKey(result_type)) {
            .array_type => |array| array.child,
            else => return result,
        };
        const values = try analyser.arena.alloc(Type, lhs_items.len + rhs_items.len);
        try analyser.coerceComptimeArrayElements(values[0..lhs_items.len], lhs_items, child_type);
        try analyser.coerceComptimeArrayElements(values[lhs_items.len..], rhs_items, child_type);
        return try comptime_eval.Value.create(analyser, Type.fromIP(analyser, .type_type, result_type), .{ .array = values });
    }

    const lhs_values = analyser.aggregateValues(lhs);
    const rhs_values = analyser.aggregateValues(rhs);
    const result_payload = switch (result.data) {
        .ip_index => |payload| payload,
        else => return result,
    };
    const result_array = switch (analyser.ip.indexToKey(result_payload.type)) {
        .array_type => |array| array,
        else => return result,
    };
    const lhs_len = std.math.cast(usize, (lhs.arrayInfo(analyser) orelse return result)[0] orelse return result) orelse return result;
    const rhs_len = std.math.cast(usize, (rhs.arrayInfo(analyser) orelse return result)[0] orelse return result) orelse return result;
    const value_len = std.math.add(usize, lhs_len, rhs_len) catch return result;
    if (value_len != result_array.len or
        (lhs_values != null and lhs_values.?.len != lhs_len) or
        (rhs_values != null and rhs_values.?.len != rhs_len)) return result;

    const values = try analyser.gpa.alloc(InternPool.Index, result_array.len);
    defer analyser.gpa.free(values);
    const unknown = try analyser.ip.getUnknown(result_array.child);
    if (lhs_values) |source| {
        for (values[0..lhs_len], 0..) |*value, index| {
            value.* = try analyser.coerceArrayElementValue(
                result_array.child,
                source.at(@intCast(index), analyser.ip),
            ) orelse unknown;
        }
    } else {
        @memset(values[0..lhs_len], unknown);
    }
    if (rhs_values) |source| {
        for (values[lhs_len..], 0..) |*value, index| {
            value.* = try analyser.coerceArrayElementValue(
                result_array.child,
                source.at(@intCast(index), analyser.ip),
            ) orelse unknown;
        }
    } else {
        @memset(values[lhs_len..], unknown);
    }
    return try analyser.aggregateValue(result, values) orelse result;
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
    if (integer_cast == .splat) {
        const vector = switch (analyser.ip.indexToKey(ip_ty)) {
            .vector_type => |vector| vector,
            else => return null,
        };
        const scalar = try analyser.resolveCoercedIPValueFromIndex(vector.child, ip_index, null) orelse return null;
        return analyser.resolveSplatValueFromIndex(ip_ty, scalar);
    }
    return analyser.resolveCoercedIPValueFromIndex(ip_ty, ip_index, integer_cast);
}

fn resolveCoercedIPValueFromIndex(
    analyser: *Analyser,
    ip_ty: InternPool.Index,
    ip_index: InternPool.Index,
    cast: ?std.zig.BuiltinFn.Tag,
) error{OutOfMemory}!?InternPool.Index {
    if (analyser.ip.isUndefined(ip_index)) return null;
    const source_tag = analyser.ip.zigTypeTag(analyser.ip.typeOf(ip_index)) orelse return null;
    if (cast) |tag| {
        if (analyser.ip.zigTypeTag(ip_ty) == .vector and source_tag == .vector) {
            return try analyser.resolveVectorCastValue(
                tag,
                ip_ty,
                Type.fromIP(analyser, analyser.ip.typeOf(ip_index), ip_index),
            );
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
        if (tag == .int_cast) {
            const int = analyser.ip.toInt(ip_index, i256) orelse return null;
            return (try analyser.intValueWithType(ip_ty, int) orelse return null).ipIndex();
        }
    }
    if (analyser.ip.zigTypeTag(ip_ty) == .float and
        (source_tag == .float or source_tag == .comptime_float))
    {
        if (try analyser.coerceFloatValue(ip_ty, ip_index)) |coerced| return coerced;
    }
    if (analyser.ip.zigTypeTag(ip_ty) == .float and source_tag == .comptime_int) {
        return analyser.coerceExactIntToFloatValue(ip_ty, ip_index);
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

pub const ComptimeCastKind = enum { int_cast, truncate, bit_cast, int_from_float, float_from_int, float_cast };

fn hasWellDefinedRuntimeLayout(analyser: *Analyser, type_index: InternPool.Index) bool {
    const type_tag = analyser.ip.zigTypeTag(type_index) orelse return false;
    return switch (type_tag) {
        .bool, .float, .int, .void, .vector => true,
        .pointer => analyser.ip.indexToKey(type_index).pointer_type.flags.size != .slice,
        .array => analyser.hasWellDefinedRuntimeLayout(
            analyser.ip.indexToKey(type_index).array_type.child,
        ),
        .@"struct" => analyser.ip.getStruct(
            analyser.ip.indexToKey(type_index).struct_type,
        ).layout != .auto,
        .@"union" => analyser.ip.getUnion(
            analyser.ip.indexToKey(type_index).union_type,
        ).layout != .auto,
        else => false,
    };
}

fn isValidRuntimeBitCastType(analyser: *Analyser, type_index: InternPool.Index) bool {
    const type_tag = analyser.ip.zigTypeTag(type_index) orelse return false;
    return switch (type_tag) {
        .bool, .float, .int, .vector => true,
        .array => analyser.hasWellDefinedRuntimeLayout(
            analyser.ip.indexToKey(type_index).array_type.child,
        ),
        .@"struct" => analyser.ip.getStruct(
            analyser.ip.indexToKey(type_index).struct_type,
        ).layout != .auto,
        .@"union" => analyser.ip.getUnion(
            analyser.ip.indexToKey(type_index).union_type,
        ).layout != .auto,
        else => false,
    };
}

fn isValidRuntimeScalarCast(
    analyser: *Analyser,
    destination_type: InternPool.Index,
    source_type: InternPool.Index,
    kind: ComptimeCastKind,
) bool {
    const destination_tag = analyser.ip.zigTypeTag(destination_type) orelse return false;
    const source_tag = analyser.ip.zigTypeTag(source_type) orelse return false;
    return switch (kind) {
        .int_cast => destination_tag == .int and (source_tag == .int or source_tag == .comptime_int),
        .truncate => truncate: {
            if (destination_tag != .int or source_tag != .int) break :truncate false;
            const destination = analyser.ip.intInfo(destination_type, builtin.target);
            const source = analyser.ip.intInfo(source_type, builtin.target);
            break :truncate destination.signedness == source.signedness and destination.bits <= source.bits;
        },
        .bit_cast => destination_tag == .int and source_tag == .int and
            analyser.ip.intInfo(destination_type, builtin.target).bits ==
                analyser.ip.intInfo(source_type, builtin.target).bits,
        .int_from_float => destination_tag == .int and
            (source_tag == .float or source_tag == .comptime_float),
        .float_from_int => destination_tag == .float and
            (source_tag == .int or source_tag == .comptime_int),
        .float_cast => destination_tag == .float and
            (source_tag == .float or source_tag == .comptime_float),
    };
}

fn isValidRuntimeCast(
    analyser: *Analyser,
    destination_type: InternPool.Index,
    source_type: InternPool.Index,
    kind: ComptimeCastKind,
) bool {
    const destination_tag = analyser.ip.zigTypeTag(destination_type) orelse return false;
    const source_tag = analyser.ip.zigTypeTag(source_type) orelse return false;
    if (kind == .bit_cast) {
        if (!analyser.isValidRuntimeBitCastType(destination_type) or
            !analyser.isValidRuntimeBitCastType(source_type)) return false;
        const destination_bits = analyser.resolveTypeBitSize(
            Type.fromIP(analyser, .type_type, destination_type),
        ) orelse return false;
        const source_bits = analyser.resolveTypeBitSize(
            Type.fromIP(analyser, .type_type, source_type),
        ) orelse return false;
        return destination_bits == source_bits;
    }
    if (destination_tag != .vector or source_tag != .vector) {
        return analyser.isValidRuntimeScalarCast(destination_type, source_type, kind);
    }

    const destination = analyser.ip.indexToKey(destination_type).vector_type;
    const source = analyser.ip.indexToKey(source_type).vector_type;
    return destination.len == source.len and
        analyser.isValidRuntimeScalarCast(destination.child, source.child, kind);
}

pub fn resolveComptimeCastValue(
    analyser: *Analyser,
    destination: Type,
    source: Type,
    kind: ComptimeCastKind,
) error{OutOfMemory}!?Type {
    if (!destination.is_type_val) return null;
    const destination_type = destination.ipIndex() orelse return null;
    const source_type = (try source.typeOf(analyser)).ipIndex() orelse return null;
    const tag: std.zig.BuiltinFn.Tag = switch (kind) {
        .int_cast => .int_cast,
        .truncate => .truncate,
        .bit_cast => .bit_cast,
        .int_from_float => .int_from_float,
        .float_from_int => .float_from_int,
        .float_cast => .float_cast,
    };
    if (analyser.ip.zigTypeTag(destination_type) == .vector and
        analyser.ip.zigTypeTag(source_type) == .vector and
        comptime_eval.Value.elements(source) != null)
    {
        const value = try analyser.resolveVectorCastValue(tag, destination_type, source) orelse return null;
        return Type.fromIP(analyser, destination_type, value);
    }
    const source_payload = switch (source.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    const source_index = source_payload.index orelse {
        if (!analyser.isValidRuntimeCast(destination_type, source_payload.type, kind)) return null;
        return Type.fromIP(analyser, destination_type, null);
    };
    if (analyser.ip.isUndefined(source_index)) return null;
    if (analyser.ip.isUnknown(source_index)) {
        if (!analyser.isValidRuntimeCast(destination_type, source_payload.type, kind)) return null;
        return Type.fromIP(analyser, destination_type, null);
    }
    const value = try analyser.resolveCoercedIPValueFromIndex(destination_type, source_index, tag) orelse return null;
    return Type.fromIP(analyser, destination_type, value);
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

fn coerceExactIntToFloatValue(
    analyser: *Analyser,
    dest_ty: InternPool.Index,
    value: InternPool.Index,
) error{OutOfMemory}!?InternPool.Index {
    const precision: u8 = switch (dest_ty) {
        .f16_type => 11,
        .f32_type => 24,
        .f64_type => 53,
        .f80_type => 64,
        .f128_type => 113,
        else => return null,
    };
    const integer, const magnitude: u128 = if (analyser.ip.toInt(value, i128)) |signed|
        .{
            @as(f128, @floatFromInt(signed)),
            if (signed < 0) @as(u128, @intCast(-(signed + 1))) + 1 else @intCast(signed),
        }
    else if (analyser.ip.toInt(value, u128)) |unsigned|
        .{ @as(f128, @floatFromInt(unsigned)), unsigned }
    else
        return null;
    if (magnitude != 0 and
        128 - @clz(magnitude) - @ctz(magnitude) > precision) return null;
    const comptime_value = try analyser.ip.get(.{ .float_comptime_value = integer });
    const coerced = try analyser.coerceFloatValue(dest_ty, comptime_value) orelse return null;
    if (!std.math.isFinite(analyser.floatValue(coerced) orelse return null)) return null;
    return coerced;
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
    const operand_type = (try operand.typeOf(analyser)).ipIndex() orelse return null;
    const vector = switch (analyser.ip.indexToKey(operand_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    if (analyser.ip.zigTypeTag(vector.child) != .float) return null;
    const source_items = comptime_eval.Value.elements(operand);
    const source_values = analyser.aggregateValues(operand);
    if (source_items == null and source_values == null) return null;
    if ((source_items != null and source_items.?.len != vector.len) or
        (source_values != null and source_values.?.len != vector.len)) return null;

    const values = try analyser.gpa.alloc(InternPool.Index, vector.len);
    defer analyser.gpa.free(values);
    for (values, 0..) |*value, i| {
        const element = if (source_items) |items|
            items[i]
        else
            Type.fromIP(analyser, vector.child, source_values.?.at(@intCast(i), analyser.ip));
        const result = switch (tag) {
            .floor, .ceil, .trunc, .round => try analyser.resolveFloatRoundingValue(tag, element),
            else => try analyser.resolveFloatUnaryBuiltinValue(tag, element),
        };
        value.* = if (result) |resolved| resolved.ipIndex() orelse try analyser.ip.getUnknown(vector.child) else try analyser.ip.getUnknown(vector.child);
    }
    return analyser.aggregateValue(Type.fromIP(analyser, operand_type, null), values);
}

pub const ComptimeFloatUnaryKind = enum { sin, cos, tan, exp, exp2, log, log2, log10, sqrt, floor, ceil, trunc, round };

pub fn resolveComptimeFloatUnaryValue(
    analyser: *Analyser,
    operand: Type,
    kind: ComptimeFloatUnaryKind,
) error{OutOfMemory}!?Type {
    const operand_type = (try operand.typeOf(analyser)).ipIndex() orelse return null;
    if (!analyser.ip.isFloat(analyser.ip.scalarType(operand_type))) return null;
    const tag: std.zig.BuiltinFn.Tag = switch (kind) {
        .sin => .sin,
        .cos => .cos,
        .tan => .tan,
        .exp => .exp,
        .exp2 => .exp2,
        .log => .log,
        .log2 => .log2,
        .log10 => .log10,
        .sqrt => .sqrt,
        .floor => .floor,
        .ceil => .ceil,
        .trunc => .trunc,
        .round => .round,
    };
    const fallback = Type.fromIP(analyser, operand_type, null);
    if (analyser.ip.zigTypeTag(operand_type) == .vector) {
        return try analyser.resolveFloatVectorUnaryValue(tag, operand) orelse fallback;
    }
    return switch (kind) {
        .floor, .ceil, .trunc, .round => try analyser.resolveFloatRoundingValue(tag, operand) orelse fallback,
        else => try analyser.resolveFloatUnaryBuiltinValue(tag, operand) orelse fallback,
    };
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
    const operand_type = (try operand.typeOf(analyser)).ipIndex() orelse return null;
    const vector = switch (analyser.ip.indexToKey(operand_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    const child_tag = analyser.ip.zigTypeTag(vector.child) orelse return null;
    switch (operation) {
        .bit_not => if (child_tag != .int) return null,
        .negate => if (child_tag != .float and
            !(child_tag == .int and analyser.ip.isSignedInt(vector.child, builtin.target))) return null,
        .negate_wrap => if (child_tag != .int) return null,
        .abs => if (child_tag != .int and child_tag != .float) return null,
    }
    const result_type = if (operation == .abs and analyser.ip.zigTypeTag(vector.child) == .int and
        analyser.ip.isSignedInt(vector.child, builtin.target))
        try analyser.ip.toUnsigned(operand_type, builtin.target)
    else
        operand_type;
    const result_vector = switch (analyser.ip.indexToKey(result_type)) {
        .vector_type => |result_vector| result_vector,
        else => return null,
    };
    const source_items = comptime_eval.Value.elements(operand);
    const source_values = analyser.aggregateValues(operand);
    if (source_items == null and source_values == null) return Type.fromIP(analyser, result_type, null);
    if ((source_items != null and source_items.?.len != vector.len) or
        (source_values != null and source_values.?.len != vector.len)) return null;

    const values = try analyser.gpa.alloc(InternPool.Index, vector.len);
    defer analyser.gpa.free(values);
    for (values, 0..) |*value, i| {
        const element = if (source_items) |items|
            items[i]
        else
            Type.fromIP(analyser, vector.child, source_values.?.at(@intCast(i), analyser.ip));
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

pub fn resolveComptimeAbsValue(analyser: *Analyser, operand: Type) error{OutOfMemory}!?Type {
    const operand_type = (try operand.typeOf(analyser)).ipIndex() orelse return null;
    const scalar_type = analyser.ip.scalarType(operand_type);
    const scalar_tag = analyser.ip.zigTypeTag(scalar_type) orelse return null;
    const result_type = switch (scalar_tag) {
        .comptime_float, .float, .comptime_int => operand_type,
        .int => if (analyser.ip.isSignedInt(scalar_type, builtin.target))
            try analyser.ip.toUnsigned(operand_type, builtin.target)
        else
            operand_type,
        else => return null,
    };
    const fallback = Type.fromIP(analyser, result_type, null);
    if (analyser.ip.zigTypeTag(operand_type) == .vector) {
        return try analyser.resolveVectorUnaryValue(.abs, operand) orelse fallback;
    }
    return try analyser.resolveAbsValue(operand) orelse fallback;
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
    a: Type,
    b: Type,
    c: Type,
) Error!?Type {
    const vector = switch (analyser.ip.indexToKey(result_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    if (analyser.ip.zigTypeTag(vector.child) != .float) return null;
    const a_values = try analyser.comptimeArrayElements(a) orelse return null;
    const b_values = try analyser.comptimeArrayElements(b) orelse return null;
    const c_values = try analyser.comptimeArrayElements(c) orelse return null;
    if (a_values.len != vector.len or b_values.len != vector.len or c_values.len != vector.len) return null;

    const values = try analyser.gpa.alloc(InternPool.Index, vector.len);
    defer analyser.gpa.free(values);
    for (values, 0..) |*value, i| {
        const unknown = try analyser.ip.getUnknown(vector.child);
        const a_value = try analyser.coerceComptimeIPValue(vector.child, a_values[i]) orelse unknown;
        const b_value = try analyser.coerceComptimeIPValue(vector.child, b_values[i]) orelse unknown;
        const c_value = try analyser.coerceComptimeIPValue(vector.child, c_values[i]) orelse unknown;
        const result = try analyser.resolveFloatMulAddValue(
            vector.child,
            a_value,
            b_value,
            c_value,
        );
        value.* = if (result) |resolved| resolved.ipIndex() orelse unknown else unknown;
    }
    return analyser.aggregateValue(Type.fromIP(analyser, result_type, null), values);
}

fn resolveComptimeMulAddCoercedValue(
    analyser: *Analyser,
    result_type: InternPool.Index,
    a: InternPool.Index,
    b: InternPool.Index,
    c: InternPool.Index,
) Error!?Type {
    if (analyser.ip.zigTypeTag(result_type) == .vector) {
        return analyser.resolveFloatVectorMulAddValue(
            result_type,
            Type.fromIP(analyser, result_type, a),
            Type.fromIP(analyser, result_type, b),
            Type.fromIP(analyser, result_type, c),
        );
    }
    return analyser.resolveFloatMulAddValue(result_type, a, b, c);
}

pub fn resolveComptimeMulAddValue(
    analyser: *Analyser,
    result_type_value: Type,
    a: Type,
    b: Type,
    c: Type,
) Error!?Type {
    if (!result_type_value.is_type_val) return null;
    const result_type = result_type_value.ipIndex() orelse return null;
    const fallback = try result_type_value.instanceTypeVal(analyser) orelse return null;
    if (analyser.ip.zigTypeTag(result_type) == .vector) {
        return try analyser.resolveFloatVectorMulAddValue(result_type, a, b, c) orelse fallback;
    }
    const a_index = try analyser.coerceIP(result_type, a.ipIndex() orelse return fallback) orelse return fallback;
    const b_index = try analyser.coerceIP(result_type, b.ipIndex() orelse return fallback) orelse return fallback;
    const c_index = try analyser.coerceIP(result_type, c.ipIndex() orelse return fallback) orelse return fallback;
    return try analyser.resolveComptimeMulAddCoercedValue(result_type, a_index, b_index, c_index) orelse fallback;
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
        .type_info_value, .comptime_value => value,
        else => if (value.is_type_val) value else null,
    };
}

fn resolveTypeInfoTag(analyser: *Analyser, ty: Type) ?std.builtin.TypeId {
    if (!ty.is_type_val) return null;
    return switch (ty.data) {
        .pointer => .pointer,
        .array => .array,
        .vector => .vector,
        .tuple => .@"struct",
        .optional => .optional,
        .error_union => .error_union,
        .union_tag => .@"enum",
        .container => switch (ty.getContainerKind() orelse return null) {
            .keyword_struct => .@"struct",
            .keyword_enum => .@"enum",
            .keyword_union => .@"union",
            .keyword_opaque => .@"opaque",
            else => null,
        },
        .function => .@"fn",
        .ip_index => |payload| analyser.ip.zigTypeTag(payload.index orelse return null),
        else => null,
    };
}

pub fn resolveComptimeTypeInfoValue(analyser: *Analyser, operand: Type) Error!?Type {
    const result_type = try analyser.resolveLangrefType(
        version_data.builtins.get("@typeInfo").?.return_type,
    ) orelse return null;
    const tag = analyser.resolveTypeInfoTag(operand) orelse return null;
    return .{ .data = .{ .type_info_value = .{
        .value_type = try analyser.allocType(result_type),
        .reflected_type = try analyser.allocType(operand),
        .tag = tag,
        .is_payload = false,
        .collection = null,
    } }, .is_type_val = false };
}

fn resolveTypeInfoFieldAccess(
    analyser: *Analyser,
    value: Type.TypeInfoValue,
    field_name: []const u8,
) Error!?Type {
    if (value.collection) |collection| {
        if (!collection.is_optional) {
            if (collection.index) |index| {
                return analyser.resolveTypeInfoDescriptorField(value, collection.kind, index, field_name);
            }
            const len = collection.len;
            if (std.mem.eql(u8, field_name, "len")) {
                const index = try analyser.ip.get(.{ .int_u64_value = .{ .ty = .usize_type, .int = len } });
                return Type.fromIP(analyser, .usize_type, index);
            }
        }
    }
    const field = try value.value_type.lookupSymbol(analyser, field_name) orelse return null;
    const field_value_type = try field.resolveType(analyser) orelse return null;

    if (!value.is_payload) {
        if (!std.mem.eql(u8, field_name, @tagName(value.tag))) return null;
        if (value.tag == .error_set) {
            return @as(?Type, try analyser.typeInfoErrorSetPayload(value, field_value_type));
        }
        return .{ .data = .{ .type_info_value = .{
            .value_type = try analyser.allocType(field_value_type),
            .reflected_type = value.reflected_type,
            .tag = value.tag,
            .is_payload = true,
            .collection = null,
        } }, .is_type_val = false };
    }

    switch (value.tag) {
        .float => {
            if (std.mem.eql(u8, field_name, "bits")) {
                const type_index = value.reflected_type.ipIndex() orelse return field_value_type;
                const bits: u16 = switch (type_index) {
                    .f16_type => 16,
                    .f32_type => 32,
                    .f64_type => 64,
                    .f80_type => 80,
                    .f128_type => 128,
                    else => return field_value_type,
                };
                const field_type = (try field_value_type.typeOf(analyser)).ipIndex() orelse return field_value_type;
                return try analyser.intValueWithType(field_type, bits);
            }
        },
        .int => {
            const type_index = value.reflected_type.ipIndex() orelse return field_value_type;
            const info = analyser.ip.intInfo(type_index, builtin.target);
            if (std.mem.eql(u8, field_name, "signedness")) {
                const enum_type = try field_value_type.typeOf(analyser);
                return try analyser.enumValue(enum_type, @tagName(info.signedness));
            }
            if (std.mem.eql(u8, field_name, "bits")) {
                const field_type = (try field_value_type.typeOf(analyser)).ipIndex() orelse return field_value_type;
                return try analyser.intValueWithType(field_type, info.bits);
            }
        },
        .pointer => {
            const pointer = switch (value.reflected_type.data) {
                .pointer => |pointer| pointer,
                .ip_index => |payload| switch (analyser.ip.indexToKey(payload.index orelse return field_value_type)) {
                    .pointer_type => |pointer| Type.Pointer{
                        .size = pointer.flags.size,
                        .sentinel = pointer.sentinel,
                        .is_const = pointer.flags.is_const,
                        .is_volatile = pointer.flags.is_volatile,
                        .is_allowzero = pointer.flags.is_allowzero,
                        .address_space = pointer.flags.address_space,
                        .alignment = pointer.flags.alignment,
                        .packed_offset = pointer.packed_offset,
                        .elem_ty = try analyser.allocType(Type.fromIP(analyser, .type_type, pointer.elem_type)),
                    },
                    else => return field_value_type,
                },
                else => return field_value_type,
            };
            if (std.mem.eql(u8, field_name, "size")) {
                const enum_type = try field_value_type.typeOf(analyser);
                return try analyser.enumValue(enum_type, @tagName(pointer.size));
            }
            if (std.mem.eql(u8, field_name, "is_const")) {
                return Type.fromIP(analyser, .bool_type, if (pointer.is_const) .bool_true else .bool_false);
            }
            if (std.mem.eql(u8, field_name, "child")) return pointer.elem_ty.*;
            if (std.mem.eql(u8, field_name, "sentinel_ptr")) {
                return try analyser.optionalPresenceValue(field_value_type, pointer.sentinel != .none);
            }
            if (std.mem.eql(u8, field_name, "is_volatile")) {
                return Type.fromIP(analyser, .bool_type, if (pointer.is_volatile) .bool_true else .bool_false);
            }
            if (std.mem.eql(u8, field_name, "alignment")) {
                const alignment = if (pointer.alignment == 0)
                    InternPool.Index.none
                else
                    (try analyser.intValueWithType(.usize_type, pointer.alignment) orelse return field_value_type).ipIndex() orelse
                        return field_value_type;
                return try analyser.optionalTypeValue(field_value_type, alignment);
            }
            if (std.mem.eql(u8, field_name, "address_space")) {
                const enum_type = try field_value_type.typeOf(analyser);
                return try analyser.enumValue(enum_type, @tagName(pointer.address_space));
            }
            if (std.mem.eql(u8, field_name, "is_allowzero")) {
                return Type.fromIP(analyser, .bool_type, if (pointer.is_allowzero) .bool_true else .bool_false);
            }
        },
        .array, .vector => {
            const len, const child, const sentinel = switch (value.reflected_type.data) {
                .array => |array| .{ array.elem_count orelse return field_value_type, array.elem_ty.*, array.sentinel },
                .vector => |vector| .{ @as(u64, vector.len), vector.elem_ty.*, InternPool.Index.none },
                .ip_index => |payload| switch (analyser.ip.indexToKey(payload.index orelse return field_value_type)) {
                    .array_type => |array| .{ array.len, Type.fromIP(analyser, .type_type, array.child), array.sentinel },
                    .vector_type => |vector| .{ @as(u64, vector.len), Type.fromIP(analyser, .type_type, vector.child), InternPool.Index.none },
                    else => return field_value_type,
                },
                else => return field_value_type,
            };
            if (std.mem.eql(u8, field_name, "len")) {
                return try analyser.comptimeIntValue(len);
            }
            if (std.mem.eql(u8, field_name, "child")) {
                return child;
            }
            if (value.tag == .array and std.mem.eql(u8, field_name, "sentinel_ptr")) {
                return try analyser.optionalPresenceValue(field_value_type, sentinel != .none);
            }
        },
        .optional => {
            if (!std.mem.eql(u8, field_name, "child")) return field_value_type;
            const child = switch (value.reflected_type.data) {
                .optional => |child| child.*,
                .ip_index => |payload| switch (analyser.ip.indexToKey(payload.index orelse return field_value_type)) {
                    .optional_type => |optional| Type.fromIP(analyser, .type_type, optional.payload_type),
                    else => return field_value_type,
                },
                else => return field_value_type,
            };
            return child;
        },
        .error_union => {
            const error_set, const payload = switch (value.reflected_type.data) {
                .error_union => |info| .{ (info.error_set orelse return field_value_type).*, info.payload.* },
                .ip_index => |type_payload| switch (analyser.ip.indexToKey(type_payload.index orelse return field_value_type)) {
                    .error_union_type => |info| .{
                        Type.fromIP(analyser, .type_type, info.error_set_type),
                        Type.fromIP(analyser, .type_type, info.payload_type),
                    },
                    else => return field_value_type,
                },
                else => return field_value_type,
            };
            if (std.mem.eql(u8, field_name, "error_set")) return error_set;
            if (std.mem.eql(u8, field_name, "payload")) return payload;
        },
        .@"struct" => {
            const layout, const backing_integer, const is_tuple, const field_count, const declaration_count = switch (value.reflected_type.data) {
                .tuple => |tuple| .{ std.builtin.Type.ContainerLayout.auto, InternPool.Index.none, true, tuple.len, 0 },
                .ip_index => |payload| switch (analyser.ip.indexToKey(payload.index orelse return field_value_type)) {
                    .struct_type => |struct_index| blk: {
                        const info = analyser.ip.getStruct(struct_index);
                        break :blk .{ info.layout, info.backing_int_ty, false, info.fields.count(), 0 };
                    },
                    .tuple_type => |tuple| .{ std.builtin.Type.ContainerLayout.auto, InternPool.Index.none, true, tuple.types.len, 0 },
                    else => return field_value_type,
                },
                .container => blk: {
                    var buffer: [2]Ast.Node.Index = undefined;
                    const info = astContainerTypeInfo(value.reflected_type.*, &buffer) orelse return field_value_type;
                    if (info.handle.tree.tokenTag(info.declaration.ast.main_token) != .keyword_struct) return field_value_type;
                    const backing_integer = if (info.layout == .@"packed")
                        (try analyser.astPackedStructBackingType(
                            value.reflected_type.*,
                            info.declaration,
                            info.handle,
                        ) orelse return field_value_type).ipIndex() orelse return field_value_type
                    else
                        InternPool.Index.none;
                    break :blk .{
                        info.layout,
                        backing_integer,
                        false,
                        astContainerFieldCount(info.declaration, info.handle),
                        astContainerDeclarationCount(info.declaration, info.handle),
                    };
                },
                else => return field_value_type,
            };
            if (std.mem.eql(u8, field_name, "layout")) {
                const enum_type = try field_value_type.typeOf(analyser);
                return try analyser.enumValue(enum_type, @tagName(layout));
            }
            if (std.mem.eql(u8, field_name, "backing_integer")) {
                return try analyser.optionalTypeValue(field_value_type, backing_integer);
            }
            if (std.mem.eql(u8, field_name, "is_tuple")) {
                return Type.fromIP(analyser, .bool_type, if (is_tuple) .bool_true else .bool_false);
            }
            if (std.mem.eql(u8, field_name, "fields")) {
                return try analyser.typeInfoCollectionValue(value, field_value_type, .struct_fields, field_count);
            }
            if (std.mem.eql(u8, field_name, "decls")) {
                return try analyser.typeInfoCollectionValue(value, field_value_type, .container_decls, declaration_count);
            }
        },
        .@"union" => {
            const layout, const tag_type, const field_count, const declaration_count = switch (value.reflected_type.data) {
                .ip_index => |payload| switch (analyser.ip.indexToKey(payload.index orelse return field_value_type)) {
                    .union_type => |union_index| blk: {
                        const info = analyser.ip.getUnion(union_index);
                        break :blk .{
                            info.layout,
                            if (info.tag_type == .none) null else Type.fromIP(analyser, .type_type, info.tag_type),
                            info.fields.count(),
                            0,
                        };
                    },
                    else => return field_value_type,
                },
                .container => blk: {
                    var buffer: [2]Ast.Node.Index = undefined;
                    const info = astContainerTypeInfo(value.reflected_type.*, &buffer) orelse return field_value_type;
                    if (info.handle.tree.tokenTag(info.declaration.ast.main_token) != .keyword_union) return field_value_type;
                    const tag_type = if (info.declaration.ast.arg.unwrap()) |arg|
                        try analyser.resolveTypeOfNodeInternal(.{
                            .node_handle = .of(arg, info.handle),
                            .container_type = value.reflected_type.*,
                        }) orelse return field_value_type
                    else if (info.declaration.ast.enum_token != null) tag: {
                        const tag_value = try analyser.resolveUnionTag(value.reflected_type.*) orelse return field_value_type;
                        break :tag try tag_value.typeOf(analyser);
                    } else null;
                    break :blk .{
                        info.layout,
                        tag_type,
                        astContainerFieldCount(info.declaration, info.handle),
                        astContainerDeclarationCount(info.declaration, info.handle),
                    };
                },
                else => return field_value_type,
            };
            if (std.mem.eql(u8, field_name, "layout")) {
                const enum_type = try field_value_type.typeOf(analyser);
                return try analyser.enumValue(enum_type, @tagName(layout));
            }
            if (std.mem.eql(u8, field_name, "tag_type")) {
                if (tag_type) |payload| {
                    return try analyser.typeInfoOptionalTypeValue(value, field_value_type, payload);
                }
                return try analyser.optionalTypeValue(field_value_type, .none);
            }
            if (std.mem.eql(u8, field_name, "fields")) {
                return try analyser.typeInfoCollectionValue(value, field_value_type, .union_fields, field_count);
            }
            if (std.mem.eql(u8, field_name, "decls")) {
                return try analyser.typeInfoCollectionValue(value, field_value_type, .container_decls, declaration_count);
            }
        },
        .@"enum" => {
            const tag_type, const is_exhaustive, const field_count, const declaration_count = switch (value.reflected_type.data) {
                .ip_index => |payload| switch (analyser.ip.indexToKey(payload.index orelse return field_value_type)) {
                    .enum_type => |enum_index| blk: {
                        const info = analyser.ip.getEnum(enum_index);
                        break :blk .{ Type.fromIP(analyser, .type_type, info.tag_type), info.is_exhaustive, info.fields.count(), 0 };
                    },
                    else => return field_value_type,
                },
                .container => blk: {
                    var buffer: [2]Ast.Node.Index = undefined;
                    const info = astContainerTypeInfo(value.reflected_type.*, &buffer) orelse return field_value_type;
                    if (info.handle.tree.tokenTag(info.declaration.ast.main_token) != .keyword_enum) return field_value_type;
                    var is_exhaustive = true;
                    for (info.declaration.ast.members) |member| {
                        const enum_field = info.handle.tree.fullContainerField(member) orelse continue;
                        const name = try analyser.identifierTokenName(&info.handle.tree, enum_field.ast.main_token) orelse continue;
                        if (std.mem.eql(u8, name, "_")) {
                            is_exhaustive = false;
                            break;
                        }
                    }
                    break :blk .{
                        try analyser.astEnumTagType(value.reflected_type.*, info.declaration, info.handle) orelse return field_value_type,
                        is_exhaustive,
                        astEnumFieldCount(info.declaration, info.handle),
                        astContainerDeclarationCount(info.declaration, info.handle),
                    };
                },
                .union_tag => |union_type| blk: {
                    var buffer: [2]Ast.Node.Index = undefined;
                    const info = astContainerTypeInfo(union_type.*, &buffer) orelse return field_value_type;
                    if (info.handle.tree.tokenTag(info.declaration.ast.main_token) != .keyword_union or
                        info.declaration.ast.enum_token == null) return field_value_type;
                    break :blk .{
                        try analyser.astEnumTagType(union_type.*, info.declaration, info.handle) orelse return field_value_type,
                        true,
                        astContainerFieldCount(info.declaration, info.handle),
                        0,
                    };
                },
                else => return field_value_type,
            };
            if (std.mem.eql(u8, field_name, "tag_type")) {
                return tag_type;
            }
            if (std.mem.eql(u8, field_name, "is_exhaustive")) {
                return Type.fromIP(analyser, .bool_type, if (is_exhaustive) .bool_true else .bool_false);
            }
            if (std.mem.eql(u8, field_name, "fields")) {
                return try analyser.typeInfoCollectionValue(value, field_value_type, .enum_fields, field_count);
            }
            if (std.mem.eql(u8, field_name, "decls")) {
                return try analyser.typeInfoCollectionValue(value, field_value_type, .container_decls, declaration_count);
            }
        },
        .@"opaque" => {
            const declaration_count = switch (value.reflected_type.data) {
                .container => blk: {
                    var buffer: [2]Ast.Node.Index = undefined;
                    const info = astContainerTypeInfo(value.reflected_type.*, &buffer) orelse return field_value_type;
                    if (info.handle.tree.tokenTag(info.declaration.ast.main_token) != .keyword_opaque) return field_value_type;
                    break :blk astContainerDeclarationCount(info.declaration, info.handle);
                },
                .ip_index => 0,
                else => return field_value_type,
            };
            if (std.mem.eql(u8, field_name, "decls")) {
                return try analyser.typeInfoCollectionValue(value, field_value_type, .container_decls, declaration_count);
            }
        },
        .@"fn" => {
            const calling_convention, const is_generic, const is_var_args, const return_type, const param_count = switch (value.reflected_type.data) {
                .ip_index => |payload| switch (analyser.ip.indexToKey(payload.index orelse return field_value_type)) {
                    .function_type => |info| .{
                        @as(?std.builtin.CallingConvention.Tag, info.flags.calling_convention),
                        info.flags.is_generic,
                        info.flags.is_var_args,
                        Type.fromIP(analyser, .type_type, info.return_type),
                        info.args.len,
                    },
                    else => return field_value_type,
                },
                .function => |info| .{
                    info.calling_convention,
                    value.reflected_type.isGenericFunc(),
                    info.has_varargs,
                    try info.return_value.typeOf(analyser),
                    info.parameters.len,
                },
                else => return field_value_type,
            };
            if (std.mem.eql(u8, field_name, "calling_convention")) {
                const convention = calling_convention orelse return field_value_type;
                const convention_type = try field_value_type.typeOf(analyser);
                return try analyser.enumValue(convention_type, @tagName(convention));
            }
            if (std.mem.eql(u8, field_name, "is_generic")) {
                return Type.fromIP(analyser, .bool_type, if (is_generic) .bool_true else .bool_false);
            }
            if (std.mem.eql(u8, field_name, "is_var_args")) {
                return Type.fromIP(analyser, .bool_type, if (is_var_args) .bool_true else .bool_false);
            }
            if (std.mem.eql(u8, field_name, "return_type")) {
                return try analyser.typeInfoOptionalTypeValue(value, field_value_type, return_type);
            }
            if (std.mem.eql(u8, field_name, "params")) {
                return try analyser.typeInfoCollectionValue(value, field_value_type, .fn_params, param_count);
            }
        },
        else => {},
    }
    return field_value_type;
}

fn optionalTypeValue(
    analyser: *Analyser,
    optional_instance: Type,
    value: InternPool.Index,
) error{OutOfMemory}!Type {
    const optional_type = (try optional_instance.typeOf(analyser)).ipIndex() orelse return optional_instance;
    const optional_value = if (value == .none)
        try analyser.ip.getNull(optional_type)
    else
        try analyser.ip.get(.{ .optional_value = .{ .ty = optional_type, .val = value } });
    return Type.fromIP(analyser, optional_type, optional_value);
}

fn optionalPresenceValue(
    analyser: *Analyser,
    optional_instance: Type,
    is_present: bool,
) error{OutOfMemory}!Type {
    const optional_type = (try optional_instance.typeOf(analyser)).ipIndex() orelse return optional_instance;
    if (!is_present) {
        return Type.fromIP(analyser, optional_type, try analyser.ip.getNull(optional_type));
    }
    const child_type = switch (analyser.ip.indexToKey(optional_type)) {
        .optional_type => |info| info.payload_type,
        else => return optional_instance,
    };
    const child_value = try analyser.ip.getUnknown(child_type);
    const optional_value = try analyser.ip.get(.{ .optional_value = .{
        .ty = optional_type,
        .val = child_value,
    } });
    return Type.fromIP(analyser, optional_type, optional_value);
}

fn optionalIntegerValue(
    analyser: *Analyser,
    optional_instance: Type,
    value: u16,
) error{OutOfMemory}!Type {
    if (value == 0) return analyser.optionalTypeValue(optional_instance, .none);
    const integer = try analyser.intValueWithType(.usize_type, value) orelse return optional_instance;
    return analyser.optionalTypeValue(optional_instance, integer.ipIndex().?);
}

fn optionalComptimeIntValue(analyser: *Analyser, value: ?usize) error{OutOfMemory}!Type {
    const optional_type = try analyser.ip.get(.{ .optional_type = .{ .payload_type = .comptime_int_type } });
    const optional_value = if (value) |integer| blk: {
        const payload = try analyser.internComptimeInt(integer);
        break :blk try analyser.ip.get(.{ .optional_value = .{ .ty = optional_type, .val = payload } });
    } else try analyser.ip.getNull(optional_type);
    return Type.fromIP(analyser, optional_type, optional_value);
}

fn typeInfoCollectionValue(
    analyser: *Analyser,
    parent: Type.TypeInfoValue,
    collection_type: Type,
    kind: Type.TypeInfoCollectionKind,
    len: u64,
) error{OutOfMemory}!Type {
    return .{ .data = .{ .type_info_value = .{
        .value_type = try analyser.allocType(collection_type),
        .reflected_type = parent.reflected_type,
        .tag = parent.tag,
        .is_payload = true,
        .collection = .{ .kind = kind, .len = len, .index = null },
    } }, .is_type_val = false };
}

fn typeInfoErrorSetPayload(
    analyser: *Analyser,
    value: Type.TypeInfoValue,
    payload_type: Type,
) error{OutOfMemory}!Type {
    const reflected_type = value.reflected_type.ipIndex() orelse return payload_type;
    if (reflected_type == .anyerror_type) {
        return .{ .data = .{ .type_info_value = .{
            .value_type = try analyser.allocType(payload_type),
            .reflected_type = value.reflected_type,
            .tag = value.tag,
            .is_payload = true,
            .collection = null,
        } }, .is_type_val = false };
    }
    const error_set = switch (analyser.ip.indexToKey(reflected_type)) {
        .error_set_type => |error_set| error_set,
        else => return payload_type,
    };
    return .{ .data = .{ .type_info_value = .{
        .value_type = try analyser.allocType(payload_type),
        .reflected_type = value.reflected_type,
        .tag = value.tag,
        .is_payload = true,
        .collection = .{
            .kind = .error_set_errors,
            .len = error_set.names.len,
            .index = null,
            .is_optional = true,
        },
    } }, .is_type_val = false };
}

fn typeInfoOptionalTypeValue(
    analyser: *Analyser,
    value: Type.TypeInfoValue,
    optional_type: Type,
    payload: Type,
) error{OutOfMemory}!Type {
    return .{ .data = .{ .type_info_value = .{
        .value_type = try analyser.allocType(optional_type),
        .reflected_type = value.reflected_type,
        .tag = value.tag,
        .is_payload = true,
        .collection = null,
        .optional_type_payload = try analyser.allocType(payload),
    } }, .is_type_val = false };
}

fn resolveTypeInfoDescriptorField(
    analyser: *Analyser,
    value: Type.TypeInfoValue,
    kind: Type.TypeInfoCollectionKind,
    index: u32,
    field_name: []const u8,
) Error!?Type {
    const field = try value.value_type.lookupSymbol(analyser, field_name) orelse return null;
    const field_value_type = try field.resolveType(analyser) orelse return null;

    switch (kind) {
        .struct_fields => {
            const name, const field_type, const is_comptime, const alignment, const has_default = switch (value.reflected_type.data) {
                .tuple => |tuple| blk: {
                    if (index >= tuple.len) return field_value_type;
                    break :blk .{
                        try std.fmt.allocPrint(analyser.arena, "{d}", .{index}),
                        tuple[index],
                        false,
                        0,
                        false,
                    };
                },
                .ip_index => |payload| switch (analyser.ip.indexToKey(payload.index orelse return field_value_type)) {
                    .struct_type => |struct_index| blk: {
                        const info = analyser.ip.getStruct(struct_index);
                        if (index >= info.fields.count()) return field_value_type;
                        const name = try analyser.ip.string_pool.stringToSliceAlloc(
                            analyser.store.io,
                            analyser.arena,
                            info.fields.keys()[index],
                        );
                        const field_info = info.fields.values()[index];
                        break :blk .{
                            name,
                            Type.fromIP(analyser, .type_type, field_info.ty),
                            field_info.is_comptime,
                            field_info.alignment,
                            field_info.default_value != .none,
                        };
                    },
                    .tuple_type => |tuple| blk: {
                        if (index >= tuple.types.len) return field_value_type;
                        break :blk .{
                            try std.fmt.allocPrint(analyser.arena, "{d}", .{index}),
                            Type.fromIP(analyser, .type_type, tuple.types.at(index, analyser.ip)),
                            false,
                            0,
                            false,
                        };
                    },
                    else => return field_value_type,
                },
                .container => blk: {
                    const ast_field = try analyser.astContainerFieldAt(value.reflected_type.*, index, false) orelse
                        return field_value_type;
                    const field_type = try (DeclWithHandle{
                        .decl = .{ .ast_node = ast_field.node },
                        .handle = ast_field.handle,
                        .container_type = value.reflected_type.*,
                    }).resolveType(analyser) orelse return field_value_type;
                    const full_field = ast_field.handle.tree.fullContainerField(ast_field.node).?;
                    const alignment = if (full_field.ast.align_expr.unwrap()) |align_expr|
                        try analyser.resolveIntegerLiteral(u16, .{
                            .node_handle = .of(align_expr, ast_field.handle),
                            .container_type = value.reflected_type.*,
                        }) orelse return field_value_type
                    else
                        0;
                    break :blk .{
                        ast_field.name,
                        try field_type.typeOf(analyser),
                        ast_field.is_comptime,
                        alignment,
                        full_field.ast.value_expr != .none,
                    };
                },
                else => return field_value_type,
            };
            if (std.mem.eql(u8, field_name, "name")) {
                return try analyser.stringValueWithType(name, try field_value_type.typeOf(analyser));
            }
            if (std.mem.eql(u8, field_name, "type")) return field_type;
            if (std.mem.eql(u8, field_name, "is_comptime")) {
                return Type.fromIP(analyser, .bool_type, if (is_comptime) .bool_true else .bool_false);
            }
            if (std.mem.eql(u8, field_name, "alignment")) {
                return try analyser.optionalIntegerValue(field_value_type, alignment);
            }
            if (std.mem.eql(u8, field_name, "default_value_ptr")) {
                return try analyser.optionalPresenceValue(field_value_type, has_default);
            }
        },
        .union_fields => {
            const name, const field_type, const alignment = switch (value.reflected_type.data) {
                .ip_index => |payload| switch (analyser.ip.indexToKey(payload.index orelse return field_value_type)) {
                    .union_type => |union_index| blk: {
                        const info = analyser.ip.getUnion(union_index);
                        if (index >= info.fields.count()) return field_value_type;
                        const name = try analyser.ip.string_pool.stringToSliceAlloc(
                            analyser.store.io,
                            analyser.arena,
                            info.fields.keys()[index],
                        );
                        const field_info = info.fields.values()[index];
                        break :blk .{ name, Type.fromIP(analyser, .type_type, field_info.ty), field_info.alignment };
                    },
                    else => return field_value_type,
                },
                .container => blk: {
                    const ast_field = try analyser.astContainerFieldAt(value.reflected_type.*, index, false) orelse
                        return field_value_type;
                    const field_type = try (DeclWithHandle{
                        .decl = .{ .ast_node = ast_field.node },
                        .handle = ast_field.handle,
                        .container_type = value.reflected_type.*,
                    }).resolveType(analyser) orelse return field_value_type;
                    const full_field = ast_field.handle.tree.fullContainerField(ast_field.node).?;
                    const alignment = if (full_field.ast.align_expr.unwrap()) |align_expr|
                        try analyser.resolveIntegerLiteral(u16, .{
                            .node_handle = .of(align_expr, ast_field.handle),
                            .container_type = value.reflected_type.*,
                        }) orelse return field_value_type
                    else
                        0;
                    break :blk .{ ast_field.name, try field_type.typeOf(analyser), alignment };
                },
                else => return field_value_type,
            };
            if (std.mem.eql(u8, field_name, "name")) {
                return try analyser.stringValueWithType(name, try field_value_type.typeOf(analyser));
            }
            if (std.mem.eql(u8, field_name, "type")) return field_type;
            if (std.mem.eql(u8, field_name, "alignment")) {
                return try analyser.optionalIntegerValue(field_value_type, alignment);
            }
        },
        .enum_fields => {
            const name, const int_value = switch (value.reflected_type.data) {
                .ip_index => |payload| switch (analyser.ip.indexToKey(payload.index orelse return field_value_type)) {
                    .enum_type => |enum_index| blk: {
                        const info = analyser.ip.getEnum(enum_index);
                        if (index >= info.fields.count()) return field_value_type;
                        break :blk .{
                            try analyser.ip.string_pool.stringToSliceAlloc(
                                analyser.store.io,
                                analyser.arena,
                                info.fields.keys()[index],
                            ),
                            info.values.keys()[index],
                        };
                    },
                    else => return field_value_type,
                },
                .container => blk: {
                    const ast_field = try analyser.astContainerFieldAt(value.reflected_type.*, index, true) orelse
                        return field_value_type;
                    break :blk .{
                        ast_field.name,
                        try analyser.resolveEnumTagIntValue(value.reflected_type.*, ast_field.name) orelse return field_value_type,
                    };
                },
                .union_tag => |union_type| blk: {
                    const ast_field = try analyser.astContainerFieldAt(union_type.*, index, false) orelse
                        return field_value_type;
                    break :blk .{ ast_field.name, try analyser.internComptimeInt(index) };
                },
                else => return field_value_type,
            };
            if (std.mem.eql(u8, field_name, "name")) {
                return try analyser.stringValueWithType(name, try field_value_type.typeOf(analyser));
            }
            if (std.mem.eql(u8, field_name, "value")) {
                const int = analyser.ip.toInt(int_value, i256) orelse return field_value_type;
                return Type.fromIP(analyser, .comptime_int_type, try analyser.internComptimeInt(int));
            }
        },
        .fn_params => {
            const param_type, const is_generic, const is_noalias = switch (value.reflected_type.data) {
                .ip_index => |payload| switch (analyser.ip.indexToKey(payload.index orelse return field_value_type)) {
                    .function_type => |info| blk: {
                        if (index >= info.args.len) return field_value_type;
                        const parameter_type = info.args.at(index, analyser.ip);
                        break :blk .{
                            if (parameter_type == .none) null else Type.fromIP(analyser, .type_type, parameter_type),
                            info.args_is_generic.isSet(index),
                            info.args_is_noalias.isSet(index),
                        };
                    },
                    else => return field_value_type,
                },
                .function => |info| blk: {
                    if (index >= info.parameters.len) return field_value_type;
                    const parameter = info.parameters[index];
                    const is_generic = parameter.type.data == .anytype_parameter or
                        (parameter.type.hasUnresolvedGenericType() and !parameter.type.isMetaType());
                    const parameter_type: ?Type = if (is_generic)
                        null
                    else
                        parameter.type;
                    break :blk .{ parameter_type, is_generic, parameter.modifier == .noalias_param };
                },
                else => return field_value_type,
            };
            if (std.mem.eql(u8, field_name, "is_generic")) {
                return Type.fromIP(analyser, .bool_type, if (is_generic) .bool_true else .bool_false);
            }
            if (std.mem.eql(u8, field_name, "is_noalias")) {
                return Type.fromIP(analyser, .bool_type, if (is_noalias) .bool_true else .bool_false);
            }
            if (std.mem.eql(u8, field_name, "type")) {
                if (param_type) |payload| {
                    return try analyser.typeInfoOptionalTypeValue(value, field_value_type, payload);
                }
                return try analyser.optionalTypeValue(field_value_type, .none);
            }
        },
        .error_set_errors => {
            const type_index = value.reflected_type.ipIndex() orelse return field_value_type;
            const error_set = switch (analyser.ip.indexToKey(type_index)) {
                .error_set_type => |error_set| error_set,
                else => return field_value_type,
            };
            if (index >= error_set.names.len) return field_value_type;
            if (std.mem.eql(u8, field_name, "name")) {
                const name = try analyser.ip.string_pool.stringToSliceAlloc(
                    analyser.store.io,
                    analyser.arena,
                    error_set.names.at(index, analyser.ip),
                );
                return try analyser.stringValueWithType(name, try field_value_type.typeOf(analyser));
            }
        },
        .container_decls => {
            const declaration = try analyser.astContainerDeclarationAt(value.reflected_type.*, index) orelse
                return field_value_type;
            if (std.mem.eql(u8, field_name, "name")) {
                return try analyser.stringValueWithType(declaration.name, try field_value_type.typeOf(analyser));
            }
        },
        .field_names, .tags => {},
    }
    return field_value_type;
}

fn astContainerFieldAt(
    analyser: *Analyser,
    container_type: Type,
    wanted_index: u32,
    skip_discard: bool,
) Error!?struct {
    node: Ast.Node.Index,
    handle: *DocumentStore.Handle,
    name: []const u8,
    is_comptime: bool,
} {
    var buffer: [2]Ast.Node.Index = undefined;
    const info = astContainerTypeInfo(container_type, &buffer) orelse return null;
    var index: u32 = 0;
    for (info.declaration.ast.members) |member| {
        const field = info.handle.tree.fullContainerField(member) orelse continue;
        const name = try analyser.identifierTokenName(&info.handle.tree, field.ast.main_token) orelse continue;
        if (skip_discard and std.mem.eql(u8, name, "_")) continue;
        if (index == wanted_index) return .{
            .node = member,
            .handle = info.handle,
            .name = name,
            .is_comptime = field.comptime_token != null,
        };
        index += 1;
    }
    return null;
}

fn astContainerFieldCount(declaration: Ast.full.ContainerDecl, handle: *DocumentStore.Handle) usize {
    var count: usize = 0;
    for (declaration.ast.members) |member| {
        if (handle.tree.fullContainerField(member) != null) count += 1;
    }
    return count;
}

fn astEnumFieldCount(declaration: Ast.full.ContainerDecl, handle: *DocumentStore.Handle) usize {
    var count: usize = 0;
    for (declaration.ast.members) |member| {
        const field = handle.tree.fullContainerField(member) orelse continue;
        const name = offsets.tokenToSlice(&handle.tree, field.ast.main_token);
        if (!std.mem.eql(u8, name, "_")) count += 1;
    }
    return count;
}

fn astContainerDeclarationCount(declaration: Ast.full.ContainerDecl, handle: *DocumentStore.Handle) usize {
    var count: usize = 0;
    for (declaration.ast.members) |member| {
        count += @intFromBool(astContainerDeclarationNameToken(&handle.tree, member) != null);
    }
    return count;
}

fn astContainerDeclarationNameToken(tree: *const Ast, member: Ast.Node.Index) ?Ast.TokenIndex {
    return switch (tree.nodeTag(member)) {
        .global_var_decl,
        .local_var_decl,
        .simple_var_decl,
        .aligned_var_decl,
        => blk: {
            const variable = tree.fullVarDecl(member).?;
            if (variable.visib_token == null) return null;
            break :blk variable.ast.mut_token + 1;
        },
        .fn_proto,
        .fn_proto_multi,
        .fn_proto_one,
        .fn_proto_simple,
        .fn_decl,
        => blk: {
            var buffer: [1]Ast.Node.Index = undefined;
            const function = tree.fullFnProto(&buffer, member).?;
            if (function.visib_token == null) return null;
            break :blk function.name_token;
        },
        else => null,
    };
}

fn astContainerDeclarationAt(
    analyser: *Analyser,
    container_type: Type,
    wanted_index: u32,
) Error!?struct { name: []const u8 } {
    var container_buffer: [2]Ast.Node.Index = undefined;
    const info = astContainerTypeInfo(container_type, &container_buffer) orelse return null;
    var index: u32 = 0;
    for (info.declaration.ast.members) |member| {
        const name_token = astContainerDeclarationNameToken(&info.handle.tree, member) orelse continue;
        if (index == wanted_index) {
            return .{ .name = try analyser.identifierTokenName(&info.handle.tree, name_token) orelse return null };
        }
        index += 1;
    }
    return null;
}

fn astContainerTypeInfo(
    container_type: Type,
    buffer: *[2]Ast.Node.Index,
) ?struct {
    declaration: Ast.full.ContainerDecl,
    handle: *DocumentStore.Handle,
    layout: std.builtin.Type.ContainerLayout,
} {
    const container = switch (container_type.data) {
        .container => |container| container,
        else => return null,
    };
    const handle = container.scope_handle.handle;
    const tree = &handle.tree;
    const declaration = tree.fullContainerDecl(buffer, container.scope_handle.toNode()) orelse return null;
    const layout: std.builtin.Type.ContainerLayout = if (declaration.layout_token) |token| switch (tree.tokenTag(token)) {
        .keyword_extern => .@"extern",
        .keyword_packed => .@"packed",
        else => return null,
    } else .auto;
    return .{ .declaration = declaration, .handle = handle, .layout = layout };
}

fn astPackedStructBackingType(
    analyser: *Analyser,
    struct_type: Type,
    declaration: Ast.full.ContainerDecl,
    handle: *DocumentStore.Handle,
) Error!?Type {
    std.debug.assert(struct_type.isStructType(analyser));
    const explicit_backing_type: ?Type = if (declaration.ast.arg.unwrap()) |arg| blk: {
        const backing_type = try analyser.resolveTypeOfNodeInternal(.{
            .node_handle = .of(arg, handle),
            .container_type = struct_type,
        }) orelse return null;
        if (!backing_type.is_type_val) return null;
        const backing_type_index = backing_type.ipIndex() orelse return null;
        if (analyser.ip.zigTypeTag(backing_type_index) != .int) return null;
        break :blk backing_type;
    } else null;

    var total_bits: u64 = 0;
    for (declaration.ast.members) |member| {
        const field = handle.tree.fullContainerField(member) orelse continue;
        const field_type_node = field.ast.type_expr.unwrap() orelse return null;
        const field_type = try analyser.resolveTypeOfNodeInternal(.{
            .node_handle = .of(field_type_node, handle),
            .container_type = struct_type,
        }) orelse return null;
        const field_bits = analyser.resolveTypeBitSize(field_type) orelse return null;
        total_bits = std.math.add(u64, total_bits, field_bits) catch return null;
    }
    const bits = std.math.cast(u16, total_bits) orelse return null;
    if (explicit_backing_type) |backing_type| {
        if (analyser.ip.intInfo(backing_type.ipIndex().?, builtin.target).bits != bits) return null;
        return backing_type;
    }
    const backing_type = try analyser.ip.get(.{ .int_type = .{ .signedness = .unsigned, .bits = bits } });
    return Type.fromIP(analyser, .type_type, backing_type);
}

fn astEnumTagType(analyser: *Analyser, enum_type: Type, declaration: Ast.full.ContainerDecl, handle: *DocumentStore.Handle) Error!?Type {
    if (declaration.ast.arg.unwrap()) |arg| {
        return analyser.resolveTypeOfNodeInternal(.{
            .node_handle = .of(arg, handle),
            .container_type = enum_type,
        });
    }
    var field_count: u32 = 0;
    for (declaration.ast.members) |member| {
        const field = handle.tree.fullContainerField(member) orelse continue;
        const name = try analyser.identifierTokenName(&handle.tree, field.ast.main_token) orelse continue;
        if (!std.mem.eql(u8, name, "_")) field_count += 1;
    }
    const bits: u16 = if (field_count == 0) 0 else @intCast(std.math.log2_int_ceil(u32, field_count));
    const tag_type = try analyser.ip.get(.{ .int_type = .{ .signedness = .unsigned, .bits = bits } });
    return Type.fromIP(analyser, .type_type, tag_type);
}

pub fn resolveEnumValueTag(
    analyser: *Analyser,
    enum_type: Type,
    node_handle: NodeWithHandle,
) Error!?[]const u8 {
    if (!enum_type.isEnumType(analyser) and !enum_type.isTaggedUnion()) return null;
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
    if (enum_type.isInternPoolEnumType(analyser)) {
        if (try analyser.resolveEnumTagIntValue(enum_type, tag) == null) return null;
    } else {
        const decl = try enum_type.lookupSymbol(analyser, tag) orelse return null;
        if (decl.decl != .ast_node or !decl.handle.tree.nodeTag(decl.decl.ast_node).isContainerField()) return null;
    }
    return tag;
}

pub fn enumValue(analyser: *Analyser, enum_type: Type, tag: []const u8) Error!Type {
    return .{
        .data = .{ .enum_value = .{
            .enum_type = try analyser.allocType(enum_type),
            .tag = tag,
            .int_value = try analyser.resolveEnumTagIntValue(enum_type, tag),
        } },
        .is_type_val = false,
    };
}

pub fn resolveComptimeEnumFromIntValue(
    analyser: *Analyser,
    enum_type: Type,
    integer: Type,
) Error!?Type {
    if (!enum_type.is_type_val or !enum_type.isEnumType(analyser)) return null;
    const integer_payload = switch (integer.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    switch (analyser.ip.zigTypeTag(integer_payload.type) orelse return null) {
        .int, .comptime_int => {},
        else => return null,
    }
    const integer_index = integer_payload.index orelse return enum_type.instanceTypeVal(analyser);
    if (analyser.ip.isUndefined(integer_index)) return null;
    if (analyser.ip.isUnknown(integer_index)) return enum_type.instanceTypeVal(analyser);
    const int_value = analyser.ip.toInt(integer_index, i256) orelse return null;
    const tag = try analyser.resolveEnumTagFromIntValue(enum_type, int_value) orelse return null;
    const value = try analyser.enumValue(enum_type, tag);
    return value;
}

pub fn resolveComptimeIntFromEnumValue(analyser: *Analyser, operand: Type) Error!?Type {
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
}

pub fn resolveComptimeTagNameValue(analyser: *Analyser, operand: Type) Error!?Type {
    const tag_name = switch (operand.data) {
        .type_info_value => |value| @tagName(value.tag),
        .enum_value => |value| value.tag,
        else => {
            if (operand.is_type_val) return null;
            if (operand.data == .ip_index) {
                const index = operand.data.ip_index.index;
                if (index != null and analyser.ip.isUndefined(index.?)) return null;
            }
            const operand_type = try operand.typeOf(analyser);
            if (!operand_type.isEnumType(analyser) and try analyser.resolveUnionTag(operand_type) == null) return null;
            return analyser.resolveLangrefType(version_data.builtins.get("@tagName").?.return_type);
        },
    };
    return try analyser.stringValue(tag_name);
}

pub fn resolveComptimeErrorNameValue(analyser: *Analyser, operand: Type) Error!?Type {
    const payload = switch (operand.data) {
        .ip_index => |payload| payload,
        else => return null,
    };
    if (analyser.ip.zigTypeTag(payload.type) != .error_set) return null;
    const index = payload.index orelse return analyser.resolveLangrefType(
        version_data.builtins.get("@errorName").?.return_type,
    );
    if (analyser.ip.isUndefined(index)) return null;
    if (analyser.ip.isUnknown(index)) return analyser.resolveLangrefType(
        version_data.builtins.get("@errorName").?.return_type,
    );
    const error_value = switch (analyser.ip.indexToKey(index)) {
        .error_value => |value| value,
        else => return null,
    };
    const bytes = try analyser.ip.string_pool.stringToSliceAlloc(
        analyser.store.io,
        analyser.arena,
        error_value.error_tag_name,
    );
    const result = try analyser.resolveLangrefType(
        version_data.builtins.get("@errorName").?.return_type,
    ) orelse return null;
    return try analyser.stringValueWithType(bytes, try result.typeOf(analyser));
}

fn resolveEnumTagIntValue(
    analyser: *Analyser,
    enum_type: Type,
    tag: []const u8,
) Error!?InternPool.Index {
    const container, const is_union_tag = switch (enum_type.data) {
        .ip_index => |payload| {
            const enum_info = switch (analyser.ip.indexToKey(payload.index orelse return null)) {
                .enum_type => |enum_index| analyser.ip.getEnum(enum_index),
                else => return null,
            };
            const name_index = analyser.ip.string_pool.getString(analyser.store.io, tag) orelse return null;
            const field_index = enum_info.fields.getIndex(name_index) orelse return null;
            return enum_info.values.keys()[field_index];
        },
        .container => |container| .{ container, false },
        .union_tag => |union_type| switch (union_type.data) {
            .container => |container| .{ container, true },
            else => return null,
        },
        else => return null,
    };
    const handle = container.scope_handle.handle;
    const tree = &handle.tree;
    const node = container.scope_handle.toNode();
    var buffer: [2]Ast.Node.Index = undefined;
    const declaration = tree.fullContainerDecl(&buffer, node) orelse return null;
    const expected_container_tag: std.zig.Token.Tag = if (is_union_tag) .keyword_union else .keyword_enum;
    if (tree.tokenTag(declaration.ast.main_token) != expected_container_tag) return null;

    var field_count: u32 = 0;
    for (declaration.ast.members) |member| {
        if (tree.fullContainerField(member) != null) field_count += 1;
    }
    if (field_count == 0) return null;

    const tag_type = if (is_union_tag) blk: {
        const bits: u16 = @intCast(std.math.log2_int_ceil(u32, field_count));
        break :blk try analyser.ip.get(.{ .int_type = .{ .signedness = .unsigned, .bits = bits } });
    } else if (declaration.ast.arg.unwrap()) |arg| blk: {
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
        .ip_index => |payload| {
            const enum_info = switch (analyser.ip.indexToKey(payload.index orelse return null)) {
                .enum_type => |enum_index| analyser.ip.getEnum(enum_index),
                else => return null,
            };
            for (enum_info.values.keys(), enum_info.fields.keys()) |value, name| {
                if (analyser.ip.toInt(value, i256) == int_value) {
                    return try analyser.ip.string_pool.stringToSliceAlloc(analyser.store.io, analyser.arena, name);
                }
            }
            return null;
        },
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

fn internPoolHasField(analyser: *Analyser, container_type: Type, name: []const u8) ?bool {
    if (!container_type.is_type_val) return null;
    const type_index = container_type.ipIndex() orelse return null;
    return switch (analyser.ip.indexToKey(type_index)) {
        .struct_type => |struct_index| blk: {
            const name_index = analyser.ip.string_pool.getString(analyser.store.io, name) orelse break :blk false;
            break :blk analyser.ip.getStruct(struct_index).fields.contains(name_index);
        },
        .union_type => |union_index| blk: {
            const name_index = analyser.ip.string_pool.getString(analyser.store.io, name) orelse break :blk false;
            break :blk analyser.ip.getUnion(union_index).fields.contains(name_index);
        },
        .enum_type => |enum_index| blk: {
            const name_index = analyser.ip.string_pool.getString(analyser.store.io, name) orelse break :blk false;
            break :blk analyser.ip.getEnum(enum_index).fields.contains(name_index);
        },
        .tuple_type => |tuple| blk: {
            const index = std.fmt.parseUnsigned(usize, name, 10) catch break :blk false;
            break :blk index < tuple.types.len;
        },
        else => null,
    };
}

pub const ComptimeMemberKind = enum { field, declaration };

pub fn resolveComptimeMemberPresenceValue(
    analyser: *Analyser,
    container_type: Type,
    name: []const u8,
    kind: ComptimeMemberKind,
) Error!?Type {
    if (!container_type.is_type_val) return null;
    const found = switch (kind) {
        .field => analyser.internPoolHasField(container_type, name) orelse
            if (analyser.tupleFieldCount(container_type)) |field_count| blk: {
                const index = std.fmt.parseUnsigned(usize, name, 10) catch break :blk false;
                break :blk index < field_count;
            } else try analyser.lookupSymbolContainer(container_type, name, .field) != null,
        .declaration => if (analyser.tupleFieldCount(container_type) != null)
            false
        else
            try analyser.lookupSymbolContainer(container_type, name, .other) != null,
    };
    return Type.fromIP(analyser, .bool_type, if (found) .bool_true else .bool_false);
}

pub fn resolveComptimeFieldValue(
    analyser: *Analyser,
    container: Type,
    field_name: []const u8,
) Error!?Type {
    if (container.isEnumType(analyser)) {
        const declaration = try analyser.lookupSymbolContainer(container, field_name, .field);
        if (declaration != null) return try analyser.enumValue(container, field_name);
    }
    return analyser.resolveFieldAccess(container, field_name);
}

fn internPoolFieldType(analyser: *Analyser, container_type: Type, name: []const u8) ?Type {
    if (!container_type.is_type_val) return null;
    const type_index = container_type.ipIndex() orelse return null;
    if (analyser.generated_struct_fields.get(type_index)) |fields| {
        for (fields) |field| if (std.mem.eql(u8, field.name, name)) return field.ty;
    }
    return switch (analyser.ip.indexToKey(type_index)) {
        .struct_type => |struct_index| blk: {
            const name_index = analyser.ip.string_pool.getString(analyser.store.io, name) orelse return null;
            const field = analyser.ip.getStruct(struct_index).fields.get(name_index) orelse return null;
            break :blk Type.fromIP(analyser, .type_type, field.ty);
        },
        .union_type => |union_index| blk: {
            const name_index = analyser.ip.string_pool.getString(analyser.store.io, name) orelse return null;
            const field = analyser.ip.getUnion(union_index).fields.get(name_index) orelse return null;
            break :blk Type.fromIP(analyser, .type_type, field.ty);
        },
        .tuple_type => |tuple| blk: {
            const index = std.fmt.parseUnsigned(u32, name, 10) catch return null;
            if (index >= tuple.types.len) return null;
            break :blk Type.fromIP(analyser, .type_type, tuple.types.at(index, analyser.ip));
        },
        else => null,
    };
}

pub fn resolveComptimeFieldTypeValue(
    analyser: *Analyser,
    container_type: Type,
    field_name: []const u8,
) Error!?Type {
    if (!container_type.is_type_val) return null;
    if (analyser.internPoolFieldType(container_type, field_name)) |field_type| return field_type;
    const instance = try container_type.instanceTypeVal(analyser) orelse return null;
    const field = try instance.lookupSymbol(analyser, field_name) orelse return null;
    const result = try field.resolveType(analyser) orelse return null;
    return try result.typeOf(analyser);
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

pub fn resolveIfConditionValue(analyser: *Analyser, options: ResolveOptions) Error!?bool {
    const value = try analyser.resolveComptimeValue(options) orelse return null;
    if (value.data == .comptime_value) {
        return switch (value.data.comptime_value.data) {
            .optional => |payload| payload != null,
            else => null,
        };
    }
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
    const operand_type = (try operand.typeOf(analyser)).ipIndex() orelse return null;
    if (operand.ipIndex()) |index| {
        if (analyser.ip.isUndefined(index)) return operand.withoutIPIndex(analyser);
    }
    const scalar_tag = analyser.ip.zigTypeTag(operand_type);
    if (scalar_tag == .bool and tag == .bit_xor) {
        return Type.fromIP(analyser, .bool_type, .bool_false);
    }
    if (analyser.fixedWidthIntegerBounds(operand_type) != null) {
        return analyser.intValueWithType(operand_type, 0);
    }

    const vector = switch (analyser.ip.indexToKey(operand_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    const child_tag = analyser.ip.zigTypeTag(vector.child);
    if (child_tag != .bool or tag != .bit_xor) {
        _ = analyser.fixedWidthIntegerBounds(vector.child) orelse return null;
    }
    if (comptime_eval.Value.elements(operand)) |items| {
        if (items.len != vector.len) return null;
        for (items) |item| if (item.ipIndex()) |index| {
            if (analyser.ip.isUndefined(index)) return null;
        };
    } else if (analyser.aggregateValues(operand)) |source_values| {
        if (source_values.len != vector.len) return null;
        for (0..vector.len) |i|
            if (analyser.ip.isUndefined(source_values.at(@intCast(i), analyser.ip))) return null;
    }

    const zero: InternPool.Index = if (child_tag == .bool)
        .bool_false
    else
        (try analyser.intValueWithType(vector.child, 0) orelse return null).ipIndex() orelse return null;
    const values = try analyser.gpa.alloc(InternPool.Index, vector.len);
    defer analyser.gpa.free(values);
    @memset(values, zero);
    return analyser.aggregateValue(Type.fromIP(analyser, operand_type, null), values);
}

fn resolveComplementaryBinaryValue(
    analyser: *Analyser,
    tag: Ast.Node.Tag,
    operand: Type,
) error{OutOfMemory}!?Type {
    const operand_type = (try operand.typeOf(analyser)).ipIndex() orelse return null;
    if (operand.ipIndex()) |index| {
        if (analyser.ip.isUndefined(index)) return operand.withoutIPIndex(analyser);
    }

    const scalar_tag = analyser.ip.zigTypeTag(operand_type);
    if (scalar_tag == .bool) {
        const value: InternPool.Index = switch (tag) {
            .bool_and, .bit_and => .bool_false,
            .bool_or, .bit_or, .bit_xor => .bool_true,
            else => return null,
        };
        return Type.fromIP(analyser, .bool_type, value);
    }
    if (analyser.fixedWidthIntegerBounds(operand_type)) |bounds| {
        const value: i256 = switch (tag) {
            .bit_and => 0,
            .add, .add_wrap, .add_sat, .bit_or, .bit_xor => if (bounds.min < 0) -1 else bounds.max,
            else => return null,
        };
        return analyser.intValueWithType(operand_type, value);
    }

    const vector = switch (analyser.ip.indexToKey(operand_type)) {
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

    const source_items = comptime_eval.Value.elements(operand);
    const source_values = analyser.aggregateValues(operand);
    if ((source_items != null and source_items.?.len != vector.len) or
        (source_values != null and source_values.?.len != vector.len)) return null;
    const unknown = try analyser.ip.getUnknown(vector.child);
    const values = try analyser.gpa.alloc(InternPool.Index, vector.len);
    defer analyser.gpa.free(values);
    for (values, 0..) |*value, i| {
        const source = if (source_items) |items|
            items[i].ipIndex()
        else if (source_values) |source|
            source.at(@intCast(i), analyser.ip)
        else
            null;
        value.* = if (source) |index|
            if (analyser.ip.isUndefined(index)) unknown else known
        else
            known;
    }
    return analyser.aggregateValue(Type.fromIP(analyser, operand_type, null), values);
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

/// Resolve the value of a binary operation whose operands have already been
/// analyzed. Keeping this separate from AST traversal lets the comptime
/// interpreter apply the exact same arithmetic semantics to compound
/// assignments.
pub const ComptimeBinaryOperand = enum { lhs, rhs };

pub const ComptimeBinaryOptions = struct {
    same_operand: bool = false,
    complementary_operand: ?ComptimeBinaryOperand = null,
};

pub fn resolveComptimeBinaryOptions(
    analyser: *Analyser,
    tree: *const Ast,
    lhs: Ast.Node.Index,
    rhs: Ast.Node.Index,
    tag: Ast.Node.Tag,
    evaluate_values: bool,
) error{OutOfMemory}!ComptimeBinaryOptions {
    if (!evaluate_values) return .{};

    const same_operand = switch (tag) {
        .sub, .sub_wrap, .sub_sat, .bit_xor => try analyser.areSameIdentifierExpression(tree, lhs, rhs),
        else => false,
    };
    const complementary_bit_not = switch (tag) {
        .add, .add_wrap, .add_sat, .bit_and, .bit_or, .bit_xor => (try analyser.complementaryIdentifierOperand(tree, lhs, rhs, .bit_not)) != null,
        else => null,
    };
    const complementary_bool_not = if (complementary_bit_not == false)
        (try analyser.complementaryIdentifierOperand(tree, lhs, rhs, .bool_not)) != null
    else
        false;
    return .{
        .same_operand = same_operand,
        .complementary_operand = if (complementary_bit_not == true)
            if (tree.nodeTag(lhs) == .bit_not) .rhs else .lhs
        else if (complementary_bool_not)
            if (tree.nodeTag(lhs) == .bool_not) .rhs else .lhs
        else
            null,
    };
}

fn resolveComptimePointerOffset(
    analyser: *Analyser,
    pointer: Type,
    offset: Type,
    subtract: bool,
) error{OutOfMemory}!?Type {
    if (pointer.data == .comptime_value and pointer.data.comptime_value.data == .numeric_pointer) {
        const info = pointer.data.comptime_value.ty.numericPointerArithmeticInfo(analyser) orelse return null;
        if (info.size != .many and info.size != .c) return null;
        const offset_index = offset.ipIndex() orelse return null;
        if (analyser.ip.isUndefined(offset_index) or analyser.ip.isUnknown(offset_index)) return null;
        const amount = analyser.ip.toInt(offset_index, u64) orelse return null;
        if (amount == 0 or info.element_size == 0) return pointer;
        const byte_offset = std.math.mul(u64, amount, info.element_size) catch return null;
        const numeric_address = pointer.data.comptime_value.data.numeric_pointer;
        const result_address = if (subtract)
            std.math.sub(u64, numeric_address, byte_offset) catch return null
        else
            std.math.add(u64, numeric_address, byte_offset) catch return null;
        return @as(?Type, try comptime_eval.Value.create(
            analyser,
            pointer.data.comptime_value.ty,
            .{ .numeric_pointer = result_address },
        ));
    }
    const pointer_type = if (pointer.data == .comptime_value)
        try pointer.data.comptime_value.ty.instanceUnchecked(analyser)
    else
        pointer.runtimeType(analyser);
    if (pointer_type.pointerSize(analyser) != .many) return null;
    const offset_index = offset.ipIndex() orelse return null;
    if (analyser.ip.isUndefined(offset_index) or analyser.ip.isUnknown(offset_index)) return null;
    const amount = analyser.ip.toInt(offset_index, usize) orelse return null;
    if (amount == 0) return pointer;
    const sequence = try comptime_eval.Value.sequenceAlloc(analyser, pointer) orelse return null;
    const new_offset = if (subtract)
        std.math.sub(usize, sequence.offset, amount) catch return null
    else
        std.math.add(usize, sequence.offset, amount) catch return null;
    if (new_offset > sequence.backing.len) return null;
    return @as(?Type, try comptime_eval.Value.create(
        analyser,
        try pointer.typeOf(analyser),
        .{ .sequence = .{
            .backing = sequence.backing,
            .offset = new_offset,
            .len = sequence.backing.len - new_offset,
            .elements_valid = sequence.elements_valid,
            .origin = sequence.origin,
        } },
    ));
}

pub fn resolveComptimeBinaryValue(
    analyser: *Analyser,
    tag: Ast.Node.Tag,
    lhs: Type,
    rhs: Type,
    options: ComptimeBinaryOptions,
) error{OutOfMemory}!?Type {
    if (tag == .sub and lhs.data == .comptime_value and rhs.data == .comptime_value) {
        if (try comptime_eval.Value.pointerOffsetDifference(analyser, lhs, rhs)) |difference| {
            return analyser.intValueWithType(.usize_type, difference);
        }
    }
    if (tag == .add or tag == .sub) {
        if (try analyser.resolveComptimePointerOffset(lhs, rhs, tag == .sub)) |value| return value;
    }
    if (options.complementary_operand) |operand| {
        if (try analyser.resolveComplementaryBinaryValue(
            tag,
            if (operand == .lhs) lhs else rhs,
        )) |value| return value;
    }
    if (options.same_operand) {
        if (try analyser.resolveSelfBinaryValue(tag, lhs)) |value| return value;
    }
    return switch (tag) {
        .mul_wrap,
        .mul_sat,
        .add_wrap,
        .sub_wrap,
        .add_sat,
        .sub_sat,
        => try analyser.resolveFixedWidthIntegerBinaryValue(tag, lhs, rhs, null) orelse
            try analyser.resolveVectorFixedWidthIntegerBinaryValue(tag, lhs, rhs, null),

        .mul,
        .div,
        .mod,
        .bit_and,
        .bit_xor,
        .bit_or,
        => try analyser.resolveIntegerBinaryValue(tag, lhs, rhs) orelse
            try analyser.resolveFloatBinaryValue(tag, lhs, rhs) orelse
            analyser.resolveBoolBinaryValue(tag, lhs, rhs) orelse
            try analyser.resolveVectorBoolBinaryValue(tag, lhs, rhs) orelse
            try analyser.resolveVectorBinaryValue(tag, lhs, rhs),

        .add,
        .sub,
        => try analyser.resolveIntegerBinaryValue(tag, lhs, rhs) orelse
            try analyser.resolveFloatBinaryValue(tag, lhs, rhs) orelse
            try analyser.resolveVectorBinaryValue(tag, lhs, rhs),

        .shl_sat => blk: {
            const result_type = (try lhs.typeOf(analyser)).ipIndex() orelse break :blk null;
            break :blk try analyser.resolveFixedWidthIntegerBinaryValue(tag, lhs, rhs, result_type) orelse
                try analyser.resolveVectorFixedWidthIntegerBinaryValue(tag, lhs, rhs, result_type);
        },
        .shl, .shr => try analyser.resolveIntegerBinaryValue(tag, lhs, rhs) orelse
            try analyser.resolveVectorShiftValue(if (tag == .shl) .shl else .shr, lhs, rhs),
        else => null,
    };
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
    const lhs_type = (try lhs.typeOf(analyser)).ipIndex() orelse return null;
    const rhs_type = (try rhs.typeOf(analyser)).ipIndex() orelse return null;
    const lhs_vector = switch (analyser.ip.indexToKey(lhs_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    const rhs_vector = switch (analyser.ip.indexToKey(rhs_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    if (lhs_vector.len != rhs_vector.len) return null;
    const result_type = try analyser.resolvePeerTypesIP(lhs_type, rhs_type) orelse return null;
    const result_vector = switch (analyser.ip.indexToKey(result_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    const lhs_items = comptime_eval.Value.elements(lhs);
    const rhs_items = comptime_eval.Value.elements(rhs);
    const lhs_values = analyser.aggregateValues(lhs);
    const rhs_values = analyser.aggregateValues(rhs);
    if ((lhs_items != null and lhs_items.?.len != lhs_vector.len) or
        (rhs_items != null and rhs_items.?.len != rhs_vector.len) or
        (lhs_values != null and lhs_values.?.len != lhs_vector.len) or
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
        const lhs_element = if (lhs_items) |items|
            items[i]
        else
            Type.fromIP(analyser, lhs_vector.child, if (lhs_values) |slice| slice.at(index, analyser.ip) else unknown_lhs);
        const rhs_element = if (rhs_items) |items|
            items[i]
        else
            Type.fromIP(analyser, rhs_vector.child, if (rhs_values) |slice| slice.at(index, analyser.ip) else unknown_rhs);
        const lhs_value = lhs_element.ipIndex() orelse unknown_lhs;
        const rhs_value = rhs_element.ipIndex() orelse unknown_rhs;
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
    const lhs_type = (try lhs.typeOf(analyser)).ipIndex() orelse return null;
    const rhs_type = (try rhs.typeOf(analyser)).ipIndex() orelse return null;
    const lhs_vector = switch (analyser.ip.indexToKey(lhs_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    const rhs_vector = switch (analyser.ip.indexToKey(rhs_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    if (lhs_vector.len != rhs_vector.len or lhs_vector.child != .bool_type or rhs_vector.child != .bool_type) {
        return null;
    }
    const lhs_items = comptime_eval.Value.elements(lhs);
    const rhs_items = comptime_eval.Value.elements(rhs);
    const lhs_values = analyser.aggregateValues(lhs);
    const rhs_values = analyser.aggregateValues(rhs);
    if ((lhs_items != null and lhs_items.?.len != lhs_vector.len) or
        (rhs_items != null and rhs_items.?.len != rhs_vector.len) or
        (lhs_values != null and lhs_values.?.len != lhs_vector.len) or
        (rhs_values != null and rhs_values.?.len != rhs_vector.len)) return null;

    const values = try analyser.gpa.alloc(InternPool.Index, lhs_vector.len);
    defer analyser.gpa.free(values);
    for (values, 0..) |*value, i| {
        const index: u32 = @intCast(i);
        const lhs_value = if (lhs_items) |items|
            items[i].ipIndex() orelse .unknown_unknown
        else if (lhs_values) |slice|
            slice.at(index, analyser.ip)
        else
            .unknown_unknown;
        const rhs_value = if (rhs_items) |items|
            items[i].ipIndex() orelse .unknown_unknown
        else if (rhs_values) |slice|
            slice.at(index, analyser.ip)
        else
            .unknown_unknown;
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
    return analyser.aggregateValue(Type.fromIP(analyser, lhs_type, null), values);
}

fn resolveVectorBoolNotValue(analyser: *Analyser, operand: Type) error{OutOfMemory}!?Type {
    const operand_type = (try operand.typeOf(analyser)).ipIndex() orelse return null;
    const vector = switch (analyser.ip.indexToKey(operand_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    if (vector.child != .bool_type) return null;
    const source_items = comptime_eval.Value.elements(operand);
    const source_values = analyser.aggregateValues(operand);
    if (source_items == null and source_values == null) return Type.fromIP(analyser, operand_type, null);
    if ((source_items != null and source_items.?.len != vector.len) or
        (source_values != null and source_values.?.len != vector.len)) return null;

    const values = try analyser.gpa.alloc(InternPool.Index, vector.len);
    defer analyser.gpa.free(values);
    for (values, 0..) |*value, i| {
        const source = if (source_items) |items|
            items[i].ipIndex() orelse .unknown_unknown
        else
            source_values.?.at(@intCast(i), analyser.ip);
        value.* = switch (source) {
            .bool_true => .bool_false,
            .bool_false => .bool_true,
            else => try analyser.ip.getUnknown(.bool_type),
        };
    }
    return analyser.aggregateValue(Type.fromIP(analyser, operand_type, null), values);
}

fn resolveVectorFixedWidthIntegerBinaryValue(
    analyser: *Analyser,
    tag: Ast.Node.Tag,
    lhs: Type,
    rhs: Type,
    result_type_override: ?InternPool.Index,
) error{OutOfMemory}!?Type {
    const lhs_type = (try lhs.typeOf(analyser)).ipIndex() orelse return null;
    const rhs_type = (try rhs.typeOf(analyser)).ipIndex() orelse return null;
    const lhs_vector = switch (analyser.ip.indexToKey(lhs_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    const rhs_vector = switch (analyser.ip.indexToKey(rhs_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    if (lhs_vector.len != rhs_vector.len) return null;
    const result_type = result_type_override orelse
        try analyser.resolvePeerTypesIP(lhs_type, rhs_type) orelse return null;
    const result_vector = switch (analyser.ip.indexToKey(result_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    if (analyser.ip.zigTypeTag(result_vector.child) != .int) return null;
    const lhs_items = comptime_eval.Value.elements(lhs);
    const rhs_items = comptime_eval.Value.elements(rhs);
    const lhs_values = analyser.aggregateValues(lhs);
    const rhs_values = analyser.aggregateValues(rhs);
    if ((lhs_items != null and lhs_items.?.len != lhs_vector.len) or
        (rhs_items != null and rhs_items.?.len != rhs_vector.len) or
        (lhs_values != null and lhs_values.?.len != lhs_vector.len) or
        (rhs_values != null and rhs_values.?.len != rhs_vector.len)) return null;
    const values = try analyser.gpa.alloc(InternPool.Index, result_vector.len);
    defer analyser.gpa.free(values);
    const unknown_lhs = try analyser.ip.getUnknown(lhs_vector.child);
    const unknown_rhs = try analyser.ip.getUnknown(rhs_vector.child);
    for (values, 0..) |*value, i| {
        const index: u32 = @intCast(i);
        const lhs_element = if (lhs_items) |items|
            items[i]
        else
            Type.fromIP(analyser, lhs_vector.child, if (lhs_values) |slice| slice.at(index, analyser.ip) else unknown_lhs);
        const rhs_element = if (rhs_items) |items|
            items[i]
        else
            Type.fromIP(analyser, rhs_vector.child, if (rhs_values) |slice| slice.at(index, analyser.ip) else unknown_rhs);
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
    const lhs_type = (try lhs.typeOf(analyser)).ipIndex() orelse return null;
    const rhs_type = (try rhs.typeOf(analyser)).ipIndex() orelse return null;
    const lhs_vector = switch (analyser.ip.indexToKey(lhs_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    const rhs_vector = switch (analyser.ip.indexToKey(rhs_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    if (lhs_vector.len != rhs_vector.len) return null;
    const result_type = try analyser.resolvePeerTypesIP(lhs_type, rhs_type) orelse return null;
    const result_vector = switch (analyser.ip.indexToKey(result_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    const lhs_items = comptime_eval.Value.elements(lhs);
    const rhs_items = comptime_eval.Value.elements(rhs);
    const lhs_values = analyser.aggregateValues(lhs);
    const rhs_values = analyser.aggregateValues(rhs);
    if ((lhs_items != null and lhs_items.?.len != lhs_vector.len) or
        (rhs_items != null and rhs_items.?.len != rhs_vector.len) or
        (lhs_values != null and lhs_values.?.len != lhs_vector.len) or
        (rhs_values != null and rhs_values.?.len != rhs_vector.len)) return null;
    const values = try analyser.gpa.alloc(InternPool.Index, result_vector.len);
    defer analyser.gpa.free(values);
    const unknown_lhs = try analyser.ip.getUnknown(lhs_vector.child);
    const unknown_rhs = try analyser.ip.getUnknown(rhs_vector.child);
    for (values, 0..) |*value, i| {
        const index: u32 = @intCast(i);
        const lhs_element = if (lhs_items) |items|
            items[i]
        else
            Type.fromIP(analyser, lhs_vector.child, if (lhs_values) |slice| slice.at(index, analyser.ip) else unknown_lhs);
        const rhs_element = if (rhs_items) |items|
            items[i]
        else
            Type.fromIP(analyser, rhs_vector.child, if (rhs_values) |slice| slice.at(index, analyser.ip) else unknown_rhs);
        const result = try analyser.resolveIntegerDivisionValue(tag, lhs_element, rhs_element) orelse
            try analyser.resolveFloatDivisionValue(tag, lhs_element, rhs_element) orelse
            try analyser.resolveFloatRemainderValue(tag, lhs_element, rhs_element);
        value.* = if (result) |resolved| resolved.ipIndex() orelse try analyser.ip.getUnknown(result_vector.child) else try analyser.ip.getUnknown(result_vector.child);
    }
    return analyser.aggregateValue(Type.fromIP(analyser, result_type, null), values);
}

pub const ComptimeDivisionKind = enum { div_trunc, div_floor, div_exact, mod, rem };

pub fn resolveComptimeDivisionValue(
    analyser: *Analyser,
    lhs: Type,
    rhs: Type,
    kind: ComptimeDivisionKind,
) error{OutOfMemory}!?Type {
    const tag: std.zig.BuiltinFn.Tag = switch (kind) {
        .div_trunc => .div_trunc,
        .div_floor => .div_floor,
        .div_exact => .div_exact,
        .mod => .mod,
        .rem => .rem,
    };
    return try analyser.resolveIntegerDivisionValue(tag, lhs, rhs) orelse
        try analyser.resolveFloatDivisionValue(tag, lhs, rhs) orelse
        try analyser.resolveFloatRemainderValue(tag, lhs, rhs) orelse
        try analyser.resolveVectorDivisionValue(tag, lhs, rhs);
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
                try result.shiftLeftSat(&lhs_big, @min(shift, int_info.bits), int_info.signedness, int_info.bits);
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
                    if (b_wide >= int_info.bits) break :blk if (a_wide == 0) 0 else max;
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
                    if (b_wide < 0) return null;
                    if (b_wide >= int_info.bits) break :blk if (a_wide < 0) min else if (a_wide == 0) 0 else max;
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

fn vectorOverflowTupleValue(
    analyser: *Analyser,
    result_type: InternPool.Index,
    result_values: []const InternPool.Index,
    overflow_values: []const InternPool.Index,
) error{OutOfMemory}!Type {
    const vector = analyser.ip.indexToKey(result_type).vector_type;
    const overflow_type = try analyser.ip.get(.{ .vector_type = .{
        .len = vector.len,
        .child = .u1_type,
    } });
    const tuple_type = try analyser.ip.get(.{ .tuple_type = .{
        .types = try analyser.ip.getIndexSlice(&.{ result_type, overflow_type }),
        .values = try analyser.ip.getIndexSlice(&.{ .none, .none }),
    } });
    const result = try analyser.ip.get(.{ .aggregate = .{
        .ty = result_type,
        .values = try analyser.ip.getIndexSlice(result_values),
    } });
    const overflow = try analyser.ip.get(.{ .aggregate = .{
        .ty = overflow_type,
        .values = try analyser.ip.getIndexSlice(overflow_values),
    } });
    const aggregate = try analyser.ip.get(.{ .aggregate = .{
        .ty = tuple_type,
        .values = try analyser.ip.getIndexSlice(&.{ result, overflow }),
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

fn resolveVectorOverflowValue(
    analyser: *Analyser,
    tag: std.zig.BuiltinFn.Tag,
    lhs: Type,
    rhs: Type,
    result_type: InternPool.Index,
    options: ComptimeOverflowOptions,
) Error!?Type {
    const result_vector = switch (analyser.ip.indexToKey(result_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    if (analyser.ip.zigTypeTag(result_vector.child) != .int) return null;
    const lhs_values = try analyser.comptimeArrayElements(lhs) orelse return null;
    const rhs_values = try analyser.comptimeArrayElements(rhs) orelse return null;
    if (lhs_values.len != result_vector.len or rhs_values.len != result_vector.len) return null;

    const values = try analyser.gpa.alloc(InternPool.Index, result_vector.len);
    defer analyser.gpa.free(values);
    const overflows = try analyser.gpa.alloc(InternPool.Index, result_vector.len);
    defer analyser.gpa.free(overflows);
    const unknown_value = try analyser.ip.getUnknown(result_vector.child);
    const unknown_overflow = try analyser.ip.getUnknown(.u1_type);
    for (values, overflows, lhs_values, rhs_values) |*value, *overflow, lhs_value, rhs_value| {
        const lane = try analyser.resolveOverflowValue(
            tag,
            lhs_value,
            rhs_value,
            options.same_operand,
            options.complementary_operands,
        ) orelse {
            value.* = unknown_value;
            overflow.* = unknown_overflow;
            continue;
        };
        const lane_values = analyser.aggregateValues(lane) orelse {
            value.* = unknown_value;
            overflow.* = unknown_overflow;
            continue;
        };
        if (lane_values.len != 2) return null;
        value.* = lane_values.at(0, analyser.ip);
        overflow.* = lane_values.at(1, analyser.ip);
    }
    return @as(?Type, try analyser.vectorOverflowTupleValue(result_type, values, overflows));
}

pub const ComptimeOverflowKind = enum { add, sub, mul, shl };

pub const ComptimeOverflowOptions = struct {
    evaluate_values: bool = true,
    same_operand: bool = false,
    complementary_operands: bool = false,
};

pub fn resolveComptimeOverflowOptions(
    analyser: *Analyser,
    tree: *const Ast,
    lhs: Ast.Node.Index,
    rhs: Ast.Node.Index,
    kind: ComptimeOverflowKind,
    evaluate_values: bool,
) error{OutOfMemory}!ComptimeOverflowOptions {
    return .{
        .evaluate_values = evaluate_values,
        .same_operand = kind == .sub and evaluate_values and
            try analyser.areSameIdentifierExpression(tree, lhs, rhs),
        .complementary_operands = kind == .add and evaluate_values and
            (try analyser.complementaryIdentifierOperand(tree, lhs, rhs, .bit_not)) != null,
    };
}

pub fn resolveComptimeOverflowValue(
    analyser: *Analyser,
    lhs: Type,
    rhs: Type,
    kind: ComptimeOverflowKind,
    options: ComptimeOverflowOptions,
) Error!?Type {
    const tag: std.zig.BuiltinFn.Tag = switch (kind) {
        .add => .add_with_overflow,
        .sub => .sub_with_overflow,
        .mul => .mul_with_overflow,
        .shl => .shl_with_overflow,
    };
    const lhs_type = (try lhs.typeOf(analyser)).ipIndex() orelse return null;
    const rhs_type = (try rhs.typeOf(analyser)).ipIndex() orelse return null;
    const result_type = if (kind == .shl)
        lhs_type
    else
        try analyser.resolvePeerTypesIP(lhs_type, rhs_type) orelse return null;
    if (analyser.ip.zigTypeTag(result_type) == .vector) {
        const result_vector = analyser.ip.indexToKey(result_type).vector_type;
        if (!options.evaluate_values) {
            const values = try analyser.gpa.alloc(InternPool.Index, result_vector.len);
            defer analyser.gpa.free(values);
            const overflows = try analyser.gpa.alloc(InternPool.Index, result_vector.len);
            defer analyser.gpa.free(overflows);
            @memset(values, try analyser.ip.getUnknown(result_vector.child));
            @memset(overflows, try analyser.ip.getUnknown(.u1_type));
            return @as(?Type, try analyser.vectorOverflowTupleValue(result_type, values, overflows));
        }
        return analyser.resolveVectorOverflowValue(tag, lhs, rhs, result_type, options);
    }
    if (analyser.ip.zigTypeTag(result_type) != .int) return null;
    if (options.evaluate_values) {
        if (try analyser.resolveOverflowValue(
            tag,
            lhs,
            rhs,
            options.same_operand,
            options.complementary_operands,
        )) |value| return value;
    }
    return try analyser.overflowTupleValue(result_type, null, null);
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
    const literal_options = try analyser.resolveConstInitializer(options) orelse return null;
    const node_handle = literal_options.node_handle;
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
            .container_type = literal_options.container_type,
        };
        if (std.mem.eql(u8, field_name, "const")) {
            flags.is_const = try analyser.resolveBoolValue(field_options) orelse return null;
        } else if (std.mem.eql(u8, field_name, "volatile")) {
            flags.is_volatile = try analyser.resolveBoolValue(field_options) orelse return null;
        } else if (std.mem.eql(u8, field_name, "allowzero")) {
            flags.is_allowzero = try analyser.resolveBoolValue(field_options) orelse return null;
        } else if (std.mem.eql(u8, field_name, "align")) {
            const alignment_value = try analyser.resolveComptimeValue(field_options) orelse return null;
            const alignment_index = alignment_value.ipIndex() orelse return null;
            if (analyser.ip.isNull(alignment_index)) continue;
            const alignment_payload = switch (analyser.ip.indexToKey(alignment_index)) {
                .optional_value => |optional| optional.val,
                else => alignment_index,
            };
            const alignment = analyser.ip.toInt(alignment_payload, u16) orelse return null;
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
    if (try analyser.resolveComptimeValue(options)) |value| {
        if (try analyser.resolveComptimeTupleTypeValue(value)) |tuple_type| return tuple_type;
    }
    if (try analyser.resolveTypeOfNodeInternal(options)) |fields| {
        if (try analyser.resolveComptimeTupleTypeValue(fields)) |tuple_type| return tuple_type;
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

pub fn resolveComptimeTupleTypeValue(analyser: *Analyser, fields: Type) error{OutOfMemory}!?Type {
    if (comptime_eval.Value.elements(fields)) |items| {
        for (items) |item| if (!item.is_type_val) return null;
        return try Type.createTupleType(analyser, try analyser.arena.dupe(Type, items));
    }
    if (fields.data != .ip_index) return null;
    const pointer = switch (analyser.ip.indexToKey(fields.data.ip_index.type)) {
        .pointer_type => |pointer| pointer,
        else => return null,
    };
    if (pointer.flags.size != .one) return null;
    const values = switch (analyser.ip.indexToKey(pointer.elem_type)) {
        .tuple_type => |tuple| tuple.values,
        else => return null,
    };
    const element_types = try analyser.arena.alloc(Type, values.len);
    for (element_types, 0..) |*element_type, i| {
        const value = values.at(@intCast(i), analyser.ip);
        if (value == .none or analyser.ip.typeOf(value) != .type_type) return null;
        element_type.* = Type.fromIP(analyser, .type_type, value);
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
    if (try analyser.resolveComptimeValue(options)) |value| {
        if (comptime_eval.Value.elements(value)) |items| {
            const strings = try analyser.arena.alloc([]const u8, items.len);
            for (strings, items, 0..) |*string, item, index| {
                if (item.data != .string_value) return null;
                string.* = item.data.string_value.bytes;
                for (strings[0..index]) |previous| if (std.mem.eql(u8, previous, string.*)) return null;
            }
            return strings;
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

fn metaAlignment(analyser: *Analyser, ty: Type) Error!?u64 {
    if (!ty.is_type_val) return null;
    return switch (ty.data) {
        .pointer => |info| if (info.alignment != 0)
            info.alignment
        else
            try analyser.resolveTypeAlignment(info.elem_ty.*),
        .optional => |child| switch (child.data) {
            .pointer, .function => try analyser.metaAlignment(child.*),
            .ip_index => |payload| switch (analyser.ip.zigTypeTag(payload.index orelse return null) orelse return null) {
                .pointer, .@"fn" => try analyser.metaAlignment(child.*),
                else => try analyser.resolveTypeAlignment(ty),
            },
            else => try analyser.resolveTypeAlignment(ty),
        },
        .ip_index => |payload| switch (analyser.ip.indexToKey(payload.index orelse return null)) {
            .pointer_type => |pointer| if (pointer.flags.alignment != 0)
                pointer.flags.alignment
            else
                try analyser.resolveTypeAlignment(Type.fromIP(analyser, .type_type, pointer.elem_type)),
            .optional_type => |optional| switch (analyser.ip.zigTypeTag(optional.payload_type) orelse return null) {
                .pointer, .@"fn" => try analyser.metaAlignment(Type.fromIP(analyser, .type_type, optional.payload_type)),
                else => try analyser.resolveTypeAlignment(ty),
            },
            else => try analyser.resolveTypeAlignment(ty),
        },
        else => try analyser.resolveTypeAlignment(ty),
    };
}

fn containerTypeLayout(analyser: *Analyser, container_type: Type) ?std.builtin.Type.ContainerLayout {
    if (!container_type.is_type_val) return null;
    return switch (container_type.data) {
        .tuple => .auto,
        .container => blk: {
            var buffer: [2]Ast.Node.Index = undefined;
            break :blk (astContainerTypeInfo(container_type, &buffer) orelse return null).layout;
        },
        .ip_index => |payload| switch (analyser.ip.indexToKey(payload.index orelse return null)) {
            .struct_type => |struct_index| analyser.ip.getStruct(struct_index).layout,
            .tuple_type => .auto,
            .union_type => |union_index| analyser.ip.getUnion(union_index).layout,
            else => null,
        },
        else => null,
    };
}

fn resolveEnumMode(
    analyser: *Analyser,
    node_handle: NodeWithHandle,
) Error!?std.builtin.Type.Enum.Mode {
    const tree = &node_handle.handle.tree;
    if (tree.nodeTag(node_handle.node) == .enum_literal) {
        const name = try analyser.identifierTokenName(tree, tree.nodeMainToken(node_handle.node)) orelse return null;
        return std.meta.stringToEnum(std.builtin.Type.Enum.Mode, name);
    }
    const value = try analyser.resolveTypeOfNodeInternal(.of(node_handle.node, node_handle.handle)) orelse return null;
    return switch (value.data) {
        .enum_value => |enum_value| std.meta.stringToEnum(std.builtin.Type.Enum.Mode, enum_value.tag),
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
    if (try analyser.resolveComptimeValue(options)) |value| {
        if (comptime_eval.Value.elements(value)) |items| {
            if (items.len != expected_len) return null;
            const alignments = try analyser.arena.alloc(u16, items.len);
            @memset(alignments, 0);
            for (items, alignments) |item, *alignment| {
                if (item.data != .comptime_value or item.data.comptime_value.data != .fields) return null;
                for (item.data.comptime_value.data.fields) |field| {
                    if (std.mem.eql(u8, field.name, "align")) {
                        const index = field.value.ipIndex() orelse return null;
                        if (analyser.ip.isNull(index)) continue;
                        alignment.* = analyser.ip.toInt(index, u16) orelse return null;
                        if (!std.math.isPowerOfTwo(alignment.*)) return null;
                    } else if (std.mem.eql(u8, field.name, "comptime")) {
                        if (field.value.ipIndex() != .bool_false) return null;
                    } else if (!std.mem.eql(u8, field.name, "default_value_ptr")) return null;
                }
            }
            return alignments;
        }
    }
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
    const backing_type_value = try analyser.resolveComptimeValue(.{
        .node_handle = .of(params[1], handle),
        .container_type = container_type,
    }) orelse return null;
    var backing_type: InternPool.Index = if (backing_type_value.ipIndex()) |index|
        if (analyser.ip.isNull(index))
            .none
        else if (backing_type_value.is_type_val and analyser.ip.zigTypeTag(index) == .int)
            index
        else
            return null
    else
        return null;
    if (layout != .@"packed" and backing_type != .none) return null;

    const names = try analyser.resolveStringListLiteral(.{
        .node_handle = .of(params[2], handle),
        .container_type = container_type,
    }) orelse return null;
    const field_tuple = try analyser.resolveTupleTypeConstructor(.{
        .node_handle = .of(params[3], handle),
        .container_type = container_type,
    }) orelse return null;
    const resolved_types: []const Type = switch (field_tuple.data) {
        .tuple => |types| types,
        .ip_index => |payload| blk: {
            const tuple = switch (analyser.ip.indexToKey(payload.index orelse return null)) {
                .tuple_type => |tuple| tuple,
                else => return null,
            };
            const types = try analyser.arena.alloc(Type, tuple.types.len);
            for (types, 0..) |*ty, index| ty.* = Type.fromIP(analyser, .type_type, tuple.types.at(@intCast(index), analyser.ip));
            break :blk types;
        },
        else => return null,
    };
    if (names.len != resolved_types.len) return null;
    const alignments = try analyser.resolveStructFieldAlignments(.{
        .node_handle = .of(params[4], handle),
        .container_type = container_type,
    }, names.len) orelse return null;
    const field_types = try analyser.arena.alloc(InternPool.Index, resolved_types.len);
    for (field_types, resolved_types) |*index, ty| index.* = ty.ipIndex() orelse .unknown_type;
    if (layout == .@"packed") {
        var total_bits: u64 = 0;
        for (field_types, alignments) |field_type, alignment| {
            if (alignment != 0) return null;
            const field_bits = analyser.resolveTypeBitSize(Type.fromIP(analyser, .type_type, field_type)) orelse return null;
            total_bits = std.math.add(u64, total_bits, field_bits) catch return null;
        }
        const total_bits_u16 = std.math.cast(u16, total_bits) orelse return null;
        if (backing_type == .none) {
            backing_type = try analyser.ip.get(.{ .int_type = .{
                .signedness = .unsigned,
                .bits = total_bits_u16,
            } });
        } else if (analyser.ip.intInfo(backing_type, builtin.target).bits != total_bits_u16) {
            return null;
        }
    }

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
        .layout = layout,
        .backing_int_ty = backing_type,
        .status = .fully_resolved,
    });
    fields = .empty;
    const struct_type = try analyser.ip.get(.{ .struct_type = struct_index });
    const generated_fields = try analyser.arena.alloc(GeneratedField, names.len);
    for (generated_fields, names, resolved_types, alignments) |*field, name, ty, alignment| field.* = .{
        .name = name,
        .ty = ty,
        .alignment = alignment,
    };
    try analyser.generated_struct_fields.put(analyser.gpa, struct_type, generated_fields);
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
    const argument_type_value = try analyser.resolveComptimeValue(.{
        .node_handle = .of(params[1], handle),
        .container_type = container_type,
    }) orelse return null;
    const argument_type = argument_type_value.ipIndex() orelse return null;
    const has_argument_type = !analyser.ip.isNull(argument_type);
    if (has_argument_type and !argument_type_value.is_type_val) return null;
    const tag_type: InternPool.Index = if (layout == .auto and has_argument_type) blk: {
        if (analyser.ip.zigTypeTag(argument_type) != .@"enum") return null;
        break :blk argument_type;
    } else .none;
    var backing_int_ty: InternPool.Index = if (layout == .@"packed" and has_argument_type) blk: {
        if (analyser.ip.zigTypeTag(argument_type) != .int) return null;
        break :blk argument_type;
    } else .none;
    if (layout == .@"extern" and has_argument_type) return null;

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
    if (layout == .@"packed") {
        if (field_types.len == 0) return null;
        const field_bits = analyser.resolveTypeBitSize(Type.fromIP(analyser, .type_type, field_types[0])) orelse return null;
        for (field_types, alignments) |field_type, alignment| {
            if (alignment != 0 or analyser.resolveTypeBitSize(Type.fromIP(analyser, .type_type, field_type)) != field_bits) {
                return null;
            }
        }
        const field_bits_u16 = std.math.cast(u16, field_bits) orelse return null;
        if (backing_int_ty == .none) {
            backing_int_ty = try analyser.ip.get(.{ .int_type = .{
                .signedness = .unsigned,
                .bits = field_bits_u16,
            } });
        } else if (analyser.ip.intInfo(backing_int_ty, builtin.target).bits != field_bits_u16) {
            return null;
        }
    }
    if (tag_type != .none) {
        const enum_info = analyser.ip.getEnum(analyser.ip.indexToKey(tag_type).enum_type);
        if (enum_info.fields.count() != names.len) return null;
        for (enum_info.fields.keys(), names) |enum_name, union_name| {
            const interned_union_name = analyser.ip.string_pool.getString(analyser.store.io, union_name) orelse return null;
            if (enum_name != interned_union_name) return null;
        }
    }

    var fields: std.array_hash_map.Auto(InternPool.String, InternPool.Union.Field) = .empty;
    errdefer fields.deinit(analyser.gpa);
    try fields.ensureTotalCapacity(analyser.gpa, names.len);
    for (names, field_types, alignments) |name, field_type, alignment| {
        const name_index = try analyser.ip.string_pool.getOrPutString(analyser.store.io, analyser.gpa, name);
        fields.putAssumeCapacityNoClobber(name_index, .{ .ty = field_type, .alignment = alignment });
    }

    const union_index = try analyser.ip.createUnion(.{
        .tag_type = tag_type,
        .backing_int_ty = backing_int_ty,
        .fields = fields,
        .namespace = .none,
        .layout = layout,
        .status = .fully_resolved,
    });
    fields = .empty;
    const union_type = try analyser.ip.get(.{ .union_type = union_index });
    return Type.fromIP(analyser, .type_type, union_type);
}

fn resolveIntegerValueList(
    analyser: *Analyser,
    result_type: InternPool.Index,
    options: ResolveOptions,
) Error!?[]const InternPool.Index {
    const literal_options = try analyser.resolveConstInitializer(options) orelse return null;
    const node_handle = literal_options.node_handle;
    const tree = &node_handle.handle.tree;
    if (tree.nodeTag(node_handle.node) != .address_of) return null;
    const literal_node = tree.nodeData(node_handle.node).node;
    var buffer: [2]Ast.Node.Index = undefined;
    const literal = tree.fullArrayInit(&buffer, literal_node) orelse return null;
    if (literal.ast.type_expr.unwrap() != null) return null;

    const values = try analyser.arena.alloc(InternPool.Index, literal.ast.elements.len);
    for (literal.ast.elements, values) |element, *value| {
        value.* = try analyser.resolveCoercedIPValue(result_type, .{
            .node_handle = .of(element, node_handle.handle),
            .container_type = literal_options.container_type,
        }) orelse return null;
    }
    return values;
}

fn resolveEnumTypeConstructor(
    analyser: *Analyser,
    params: []const Ast.Node.Index,
    handle: *DocumentStore.Handle,
    container_type: ?Type,
) Error!?Type {
    if (params.len != 4) return null;
    const tag_type = try analyser.resolveTypeOfNodeInternal(.{
        .node_handle = .of(params[0], handle),
        .container_type = container_type,
    }) orelse return null;
    if (!tag_type.is_type_val) return null;
    const tag_type_index = tag_type.ipIndex() orelse return null;
    if (analyser.ip.zigTypeTag(tag_type_index) != .int) return null;
    const mode = try analyser.resolveEnumMode(.of(params[1], handle)) orelse return null;

    const names = try analyser.resolveStringListLiteral(.{
        .node_handle = .of(params[2], handle),
        .container_type = container_type,
    }) orelse return null;
    const raw_values = try analyser.resolveIntegerValueList(tag_type_index, .{
        .node_handle = .of(params[3], handle),
        .container_type = container_type,
    }) orelse return null;
    if (names.len != raw_values.len) return null;

    var fields: std.array_hash_map.Auto(InternPool.String, void) = .empty;
    errdefer fields.deinit(analyser.gpa);
    var values: std.array_hash_map.Auto(InternPool.Index, void) = .empty;
    errdefer values.deinit(analyser.gpa);
    try fields.ensureTotalCapacity(analyser.gpa, names.len);
    try values.ensureTotalCapacity(analyser.gpa, names.len);
    for (names, raw_values) |name, value| {
        if (values.contains(value)) return null;
        const name_index = try analyser.ip.string_pool.getOrPutString(analyser.store.io, analyser.gpa, name);
        fields.putAssumeCapacityNoClobber(name_index, {});
        values.putAssumeCapacityNoClobber(value, {});
    }

    const enum_index = try analyser.ip.createEnum(.{
        .tag_type = tag_type_index,
        .fields = fields,
        .values = values,
        .namespace = .none,
        .is_exhaustive = mode == .exhaustive,
    });
    fields = .empty;
    values = .empty;
    const enum_type = try analyser.ip.get(.{ .enum_type = enum_index });
    return Type.fromIP(analyser, .type_type, enum_type);
}

fn resolveFnParameterAttributes(
    analyser: *Analyser,
    options: ResolveOptions,
    expected_len: usize,
) Error!?std.StaticBitSet(32) {
    if (expected_len > 32) return null;
    const literal_options = try analyser.resolveConstInitializer(options) orelse return null;
    const node_handle = literal_options.node_handle;
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
                .container_type = literal_options.container_type,
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
    const name = if (tree.nodeTag(node_handle.node) == .enum_literal)
        try analyser.identifierTokenName(tree, tree.nodeMainToken(node_handle.node)) orelse return null
    else blk: {
        const value = try analyser.resolveTypeOfNodeInternal(.of(node_handle.node, node_handle.handle)) orelse return null;
        break :blk switch (value.data) {
            .enum_value => |enum_value| enum_value.tag,
            else => return null,
        };
    };
    if (std.mem.eql(u8, name, "c")) {
        const convention = builtin.target.cCallingConvention() orelse return null;
        return convention;
    }
    const convention = std.meta.stringToEnum(std.builtin.CallingConvention.Tag, name) orelse return null;
    if (convention == .auto or convention == .async or convention == .naked or convention == .@"inline") {
        return convention;
    }
    const c_convention: std.builtin.CallingConvention.Tag = builtin.target.cCallingConvention() orelse return null;
    return if (convention == c_convention) convention else null;
}

fn resolveFnAttributes(
    analyser: *Analyser,
    options: ResolveOptions,
) Error!?InternPool.Key.Function.Flags {
    const literal_options = try analyser.resolveConstInitializer(options) orelse return null;
    const node_handle = literal_options.node_handle;
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
                .container_type = literal_options.container_type,
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
    values: []const Type,
) ?f128 {
    var result: T = @floatCast(analyser.floatValue(values[0].ipIndex() orelse return null) orelse return null);
    if (!std.math.isFinite(result)) return null;
    for (1..values.len) |i| {
        const value: T = @floatCast(analyser.floatValue(values[i].ipIndex() orelse return null) orelse return null);
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
) Error!?Type {
    const operand_type = (try operand.typeOf(analyser)).ipIndex() orelse return null;
    const vector = switch (analyser.ip.indexToKey(operand_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    if (vector.len == 0) return null;
    const values = try analyser.comptimeArrayElements(operand) orelse return null;
    if (values.len != vector.len) return null;

    if (vector.child == .bool_type) {
        if (operation != .And and operation != .Or and operation != .Xor) return null;
        for (values) |value| {
            const index = value.ipIndex() orelse return null;
            if (analyser.ip.isUndefined(index)) return null;
        }
        var result = switch (operation) {
            .And => true,
            .Or, .Xor => false,
            else => unreachable,
        };
        var has_unknown = false;
        for (values) |item| {
            const value = switch (item.ipIndex() orelse return null) {
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
    for (values) |value| {
        const index = value.ipIndex() orelse return null;
        if (analyser.ip.isUndefined(index)) return null;
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
            for (values) |value| {
                if (analyser.ip.toInt(value.ipIndex() orelse continue, i256)) |int| {
                    if (int == absorbing) return analyser.intValueWithType(vector.child, absorbing);
                }
            }
        }
    }
    var result = values[0];
    for (1..values.len) |i| {
        const candidate = values[i];
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
    const predicate_type = (try predicate.typeOf(analyser)).ipIndex() orelse return null;
    const lhs_type = (try lhs.typeOf(analyser)).ipIndex() orelse return null;
    const rhs_type = (try rhs.typeOf(analyser)).ipIndex() orelse return null;
    const predicate_vector = switch (analyser.ip.indexToKey(predicate_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    const lhs_vector = switch (analyser.ip.indexToKey(lhs_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    const rhs_vector = switch (analyser.ip.indexToKey(rhs_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    if (predicate_vector.child != .bool_type or
        predicate_vector.len != lhs_vector.len or
        predicate_vector.len != rhs_vector.len or
        lhs_vector.child != element_type or
        rhs_vector.child != element_type) return null;

    const result_type = lhs_type;
    const predicate_items = comptime_eval.Value.elements(predicate);
    const lhs_items = comptime_eval.Value.elements(lhs);
    const rhs_items = comptime_eval.Value.elements(rhs);
    const predicate_values = analyser.aggregateValues(predicate);
    const lhs_values = analyser.aggregateValues(lhs);
    const rhs_values = analyser.aggregateValues(rhs);
    if ((predicate_items != null and predicate_items.?.len != predicate_vector.len) or
        (lhs_items != null and lhs_items.?.len != lhs_vector.len) or
        (rhs_items != null and rhs_items.?.len != rhs_vector.len) or
        (predicate_values != null and predicate_values.?.len != predicate_vector.len) or
        (lhs_values != null and lhs_values.?.len != lhs_vector.len) or
        (rhs_values != null and rhs_values.?.len != rhs_vector.len)) return null;
    if (predicate_items != null or lhs_items != null or rhs_items != null) {
        const selected = try analyser.arena.alloc(Type, lhs_vector.len);
        const unknown = Type.fromIP(analyser, element_type, null);
        for (selected, 0..) |*value, i| {
            const index: u32 = @intCast(i);
            const predicate_value = if (predicate_items) |items|
                items[i].ipIndex() orelse .unknown_unknown
            else if (predicate_values) |slice|
                slice.at(index, analyser.ip)
            else
                .unknown_unknown;
            const lhs_value = if (lhs_items) |items|
                items[i]
            else if (lhs_values) |slice|
                Type.fromIP(analyser, element_type, slice.at(index, analyser.ip))
            else
                unknown;
            const rhs_value = if (rhs_items) |items|
                items[i]
            else if (rhs_values) |slice|
                Type.fromIP(analyser, element_type, slice.at(index, analyser.ip))
            else
                unknown;
            value.* = switch (predicate_value) {
                .bool_true => lhs_value,
                .bool_false => rhs_value,
                else => if (!analyser.ip.isUndefined(predicate_value) and lhs_value.eql(rhs_value))
                    lhs_value
                else
                    unknown,
            };
        }
        return @as(?Type, try comptime_eval.Value.create(
            analyser,
            Type.fromIP(analyser, .type_type, result_type),
            .{ .array = selected },
        ));
    }

    const values = try analyser.gpa.alloc(InternPool.Index, lhs_vector.len);
    defer analyser.gpa.free(values);
    for (values, 0..) |*value, i| {
        const index: u32 = @intCast(i);
        const predicate_value = if (predicate_items) |items|
            items[i].ipIndex() orelse .unknown_unknown
        else if (predicate_values) |slice|
            slice.at(index, analyser.ip)
        else
            .unknown_unknown;
        const lhs_value = if (lhs_items) |items|
            items[i].ipIndex()
        else if (lhs_values) |slice|
            slice.at(index, analyser.ip)
        else
            null;
        const rhs_value = if (rhs_items) |items|
            items[i].ipIndex()
        else if (rhs_values) |slice|
            slice.at(index, analyser.ip)
        else
            null;
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

pub fn resolveComptimeSelectValue(
    analyser: *Analyser,
    element_type_value: Type,
    predicate: Type,
    lhs: Type,
    rhs: Type,
) error{OutOfMemory}!?Type {
    if (!element_type_value.is_type_val) return null;
    const element_type = element_type_value.ipIndex() orelse return null;
    return analyser.resolveSelectValue(element_type, predicate, lhs, rhs);
}

fn resolveShuffleValue(
    analyser: *Analyser,
    element_type: InternPool.Index,
    lhs: Type,
    rhs: Type,
    mask: Type,
) error{OutOfMemory}!?Type {
    const lhs_type = (try lhs.typeOf(analyser)).ipIndex() orelse return null;
    const rhs_type = (try rhs.typeOf(analyser)).ipIndex() orelse return null;
    const mask_type = (try mask.typeOf(analyser)).ipIndex() orelse return null;
    const lhs_vector = switch (analyser.ip.indexToKey(lhs_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    const rhs_vector = switch (analyser.ip.indexToKey(rhs_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    const mask_vector = switch (analyser.ip.indexToKey(mask_type)) {
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
    const lhs_items = comptime_eval.Value.elements(lhs);
    const rhs_items = comptime_eval.Value.elements(rhs);
    const mask_items = comptime_eval.Value.elements(mask);
    const lhs_values = analyser.aggregateValues(lhs);
    const rhs_values = analyser.aggregateValues(rhs);
    const mask_values = analyser.aggregateValues(mask);
    if (mask_items == null and mask_values == null) return Type.fromIP(analyser, result_type, null);
    if ((lhs_items != null and lhs_items.?.len != lhs_vector.len) or
        (rhs_items != null and rhs_items.?.len != rhs_vector.len) or
        (mask_items != null and mask_items.?.len != mask_vector.len) or
        (lhs_values != null and lhs_values.?.len != lhs_vector.len) or
        (rhs_values != null and rhs_values.?.len != rhs_vector.len) or
        (mask_values != null and mask_values.?.len != mask_vector.len)) return null;
    if (lhs_items != null or rhs_items != null or mask_items != null) {
        const shuffled = try analyser.arena.alloc(Type, mask_vector.len);
        const unknown = Type.fromIP(analyser, element_type, null);
        for (shuffled, 0..) |*value, i| {
            const mask_index = if (mask_items) |items|
                items[i].ipIndex() orelse .unknown_unknown
            else
                mask_values.?.at(@intCast(i), analyser.ip);
            const mask_value = analyser.ip.toInt(mask_index, i64) orelse {
                value.* = unknown;
                continue;
            };
            const source_items, const source_values, const source_len, const source_index = if (mask_value >= 0)
                .{ lhs_items, lhs_values, lhs_vector.len, @as(u64, @intCast(mask_value)) }
            else
                .{ rhs_items, rhs_values, rhs_vector.len, @as(u64, @intCast(~mask_value)) };
            if (source_index >= source_len) {
                value.* = unknown;
                continue;
            }
            value.* = if (source_items) |items|
                items[@intCast(source_index)]
            else if (source_values) |source|
                Type.fromIP(analyser, element_type, source.at(@intCast(source_index), analyser.ip))
            else
                unknown;
        }
        return @as(?Type, try comptime_eval.Value.create(
            analyser,
            Type.fromIP(analyser, .type_type, result_type),
            .{ .array = shuffled },
        ));
    }

    const values = try analyser.gpa.alloc(InternPool.Index, mask_vector.len);
    defer analyser.gpa.free(values);
    for (values, 0..) |*value, i| {
        const mask_index = if (mask_items) |items|
            items[i].ipIndex() orelse .unknown_unknown
        else
            mask_values.?.at(@intCast(i), analyser.ip);
        const mask_value = analyser.ip.toInt(mask_index, i64) orelse {
            value.* = try analyser.ip.getUnknown(element_type);
            continue;
        };
        if (mask_value >= 0) {
            const index: u64 = @intCast(mask_value);
            if (index >= lhs_vector.len) {
                value.* = try analyser.ip.getUnknown(element_type);
                continue;
            }
            value.* = if (lhs_items) |items|
                items[@intCast(index)].ipIndex() orelse try analyser.ip.getUnknown(element_type)
            else if (lhs_values) |source|
                source.at(@intCast(index), analyser.ip)
            else
                try analyser.ip.getUnknown(element_type);
        } else {
            const index: u64 = @intCast(~mask_value);
            if (index >= rhs_vector.len) {
                value.* = try analyser.ip.getUnknown(element_type);
                continue;
            }
            value.* = if (rhs_items) |items|
                items[@intCast(index)].ipIndex() orelse try analyser.ip.getUnknown(element_type)
            else if (rhs_values) |source|
                source.at(@intCast(index), analyser.ip)
            else
                try analyser.ip.getUnknown(element_type);
        }
    }
    return analyser.aggregateValue(Type.fromIP(analyser, result_type, null), values);
}

pub fn resolveComptimeShuffleValue(
    analyser: *Analyser,
    element_type_value: Type,
    lhs: Type,
    rhs: Type,
    mask: Type,
) error{OutOfMemory}!?Type {
    if (!element_type_value.is_type_val) return null;
    const element_type = element_type_value.ipIndex() orelse return null;
    return analyser.resolveShuffleValue(element_type, lhs, rhs, mask);
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

fn knownOptionalNull(analyser: *Analyser, value: Type) ?bool {
    if (value.data == .comptime_value) {
        return switch (value.data.comptime_value.data) {
            .optional => |payload| payload == null,
            else => null,
        };
    }
    if (value.data == .type_info_value) {
        const type_info = value.data.type_info_value;
        if (type_info.optional_type_payload != null) return false;
        if (type_info.tag == .error_set and type_info.is_payload) {
            const collection = type_info.collection orelse return true;
            return if (collection.is_optional) false else null;
        }
        return null;
    }
    const index = value.ipIndex() orelse return null;
    return switch (analyser.ip.indexToKey(index)) {
        .simple_value => |simple| if (simple == .null_value) true else null,
        .null_value => true,
        .optional_value => false,
        else => null,
    };
}

fn resolveComparisonValue(
    analyser: *Analyser,
    tag: Ast.Node.Tag,
    lhs: Type,
    rhs: Type,
) ?Type {
    if (comptime_eval.Value.numericPointerOrder(analyser, lhs, rhs)) |order| {
        const result = switch (tag) {
            .equal_equal => order == .eq,
            .bang_equal => order != .eq,
            .less_than => order == .lt,
            .greater_than => order == .gt,
            .less_or_equal => order != .gt,
            .greater_or_equal => order != .lt,
            else => return null,
        };
        return Type.fromIP(analyser, .bool_type, if (result) .bool_true else .bool_false);
    }
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
    if (tag == .equal_equal or tag == .bang_equal) {
        if (comptime_eval.Value.pointerIdentityEql(analyser, lhs, rhs)) |equal| {
            return Type.fromIP(
                analyser,
                .bool_type,
                if (equal == (tag == .equal_equal)) .bool_true else .bool_false,
            );
        }
        if (lhs_index != null and rhs_index != null) {
            const lhs_key = analyser.ip.indexToKey(lhs_index.?);
            const rhs_key = analyser.ip.indexToKey(rhs_index.?);
            if (lhs_key == .error_value and rhs_key == .error_value) {
                const equal = lhs_key.error_value.error_tag_name == rhs_key.error_value.error_tag_name;
                return Type.fromIP(
                    analyser,
                    .bool_type,
                    if (equal == (tag == .equal_equal)) .bool_true else .bool_false,
                );
            }
        }
        const lhs_optional_null = analyser.knownOptionalNull(lhs);
        const rhs_optional_null = analyser.knownOptionalNull(rhs);
        if (lhs_optional_null != null and rhs_optional_null != null and
            (lhs_optional_null.? or rhs_optional_null.?))
        {
            const equal = lhs_optional_null.? == rhs_optional_null.?;
            return Type.fromIP(
                analyser,
                .bool_type,
                if (equal == (tag == .equal_equal)) .bool_true else .bool_false,
            );
        }
    }
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
            else if (lhs.is_type_val and rhs.is_type_val and
                !lhs.hasUnresolvedGenericType() and !rhs.hasUnresolvedGenericType() and
                (lhs.data != .ip_index or lhs_index != null) and (rhs.data != .ip_index or rhs_index != null))
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

pub fn resolveComptimeComparisonValue(
    analyser: *Analyser,
    tag: Ast.Node.Tag,
    lhs: Type,
    rhs: Type,
) error{OutOfMemory}!?Type {
    return try analyser.resolveVectorComparisonValue(tag, lhs, rhs) orelse
        analyser.resolveComparisonValue(tag, lhs, rhs);
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
    const operand_type = (try operand.typeOf(analyser)).ipIndex() orelse return null;
    const result = switch (tag) {
        .equal_equal, .less_or_equal, .greater_or_equal => true,
        .bang_equal, .less_than, .greater_than => false,
        else => return null,
    };
    const type_tag = analyser.ip.zigTypeTag(operand_type);
    const equality = tag == .equal_equal or tag == .bang_equal;
    if (type_tag == .int or
        (equality and (type_tag == .bool or
            type_tag == .error_set or
            (type_tag == .pointer and operand.pointerSize(analyser) != .slice))))
    {
        if (operand.ipIndex()) |index| {
            if (analyser.ip.isUndefined(index)) return Type.fromIP(analyser, .bool_type, null);
        }
        return Type.fromIP(analyser, .bool_type, if (result) .bool_true else .bool_false);
    }

    const vector = switch (analyser.ip.indexToKey(operand_type)) {
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
    if (operand.ipIndex()) |index| {
        if (analyser.ip.isUndefined(index)) return Type.fromIP(analyser, result_type, null);
    }

    const source_items = comptime_eval.Value.elements(operand);
    const source_values = analyser.aggregateValues(operand);
    if ((source_items != null and source_items.?.len != vector.len) or
        (source_values != null and source_values.?.len != vector.len)) return null;
    const known = if (result) InternPool.Index.bool_true else .bool_false;
    const unknown = try analyser.ip.getUnknown(.bool_type);
    const values = try analyser.gpa.alloc(InternPool.Index, vector.len);
    defer analyser.gpa.free(values);
    for (values, 0..) |*value, i| {
        const source = if (source_items) |items|
            items[i].ipIndex()
        else if (source_values) |items|
            items.at(@intCast(i), analyser.ip)
        else
            null;
        value.* = if (source) |index|
            if (analyser.ip.isUndefined(index)) unknown else known
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
    const operand_type = (try operand.typeOf(analyser)).ipIndex() orelse return null;
    const result = switch (tag) {
        .equal_equal => false,
        .bang_equal => true,
        else => return null,
    };
    if (operand.ipIndex()) |index| {
        if (analyser.ip.isUndefined(index)) return null;
    }

    const type_tag = analyser.ip.zigTypeTag(operand_type);
    if (type_tag == .bool or analyser.fixedWidthIntegerBounds(operand_type) != null) {
        return Type.fromIP(analyser, .bool_type, if (result) .bool_true else .bool_false);
    }

    const vector = switch (analyser.ip.indexToKey(operand_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    const child_tag = analyser.ip.zigTypeTag(vector.child);
    if (child_tag != .bool and analyser.fixedWidthIntegerBounds(vector.child) == null) return null;
    const result_type = try analyser.ip.get(.{ .vector_type = .{
        .len = vector.len,
        .child = .bool_type,
    } });
    const source_items = comptime_eval.Value.elements(operand);
    const source_values = analyser.aggregateValues(operand);
    if ((source_items != null and source_items.?.len != vector.len) or
        (source_values != null and source_values.?.len != vector.len)) return null;
    const known = if (result) InternPool.Index.bool_true else .bool_false;
    const unknown = try analyser.ip.getUnknown(.bool_type);
    const values = try analyser.gpa.alloc(InternPool.Index, vector.len);
    defer analyser.gpa.free(values);
    for (values, 0..) |*value, i| {
        const source = if (source_items) |items|
            items[i].ipIndex()
        else if (source_values) |items|
            items.at(@intCast(i), analyser.ip)
        else
            null;
        value.* = if (source) |index|
            if (analyser.ip.isUndefined(index)) unknown else known
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
    const lhs_type = (try lhs.typeOf(analyser)).ipIndex() orelse return null;
    const rhs_type = (try rhs.typeOf(analyser)).ipIndex() orelse return null;
    const lhs_vector = switch (analyser.ip.indexToKey(lhs_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    const rhs_vector = switch (analyser.ip.indexToKey(rhs_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    if (lhs_vector.len != rhs_vector.len) return null;
    if (try analyser.resolvePeerTypesIP(lhs_vector.child, rhs_vector.child) == null) return null;

    const result_type = try analyser.ip.get(.{ .vector_type = .{
        .len = lhs_vector.len,
        .child = .bool_type,
    } });
    const lhs_items = comptime_eval.Value.elements(lhs);
    const rhs_items = comptime_eval.Value.elements(rhs);
    const lhs_values = analyser.aggregateValues(lhs);
    const rhs_values = analyser.aggregateValues(rhs);
    if ((lhs_items != null and lhs_items.?.len != lhs_vector.len) or
        (rhs_items != null and rhs_items.?.len != rhs_vector.len) or
        (lhs_values != null and lhs_values.?.len != lhs_vector.len) or
        (rhs_values != null and rhs_values.?.len != rhs_vector.len)) return null;

    const values = try analyser.gpa.alloc(InternPool.Index, lhs_vector.len);
    defer analyser.gpa.free(values);
    const unknown_lhs = try analyser.ip.getUnknown(lhs_vector.child);
    const unknown_rhs = try analyser.ip.getUnknown(rhs_vector.child);
    for (values, 0..) |*value, i| {
        const index: u32 = @intCast(i);
        const lhs_element = if (lhs_items) |items|
            items[i]
        else
            Type.fromIP(analyser, lhs_vector.child, if (lhs_values) |slice| slice.at(index, analyser.ip) else unknown_lhs);
        const rhs_element = if (rhs_items) |items|
            items[i]
        else
            Type.fromIP(analyser, rhs_vector.child, if (rhs_values) |slice| slice.at(index, analyser.ip) else unknown_rhs);
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
) Error!?Type {
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
            const operand_type = (try operand.typeOf(analyser)).ipIndex() orelse return null;
            const vector = switch (analyser.ip.indexToKey(operand_type)) {
                .vector_type => |vector| vector,
                else => return null,
            };
            if (vector.len != result_vector.len) return null;
            const values = try analyser.comptimeArrayElements(operand) orelse {
                has_unknown = true;
                continue;
            };
            if (values.len != vector.len) return null;
            const candidate_index = values[i].ipIndex() orelse {
                has_unknown = true;
                continue;
            };
            if (analyser.ip.isUndefined(candidate_index)) {
                has_undefined = true;
                continue;
            }
            if (candidate_index == .none or analyser.ip.isUnknown(candidate_index)) {
                has_unknown = true;
                continue;
            }
            const candidate = values[i];
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

pub const ComptimeMinMaxKind = enum { min, max };

pub fn resolveComptimeMinMaxValue(
    analyser: *Analyser,
    operands: []const Type,
    kind: ComptimeMinMaxKind,
) Error!?Type {
    if (operands.len < 2) return null;

    const tag: std.zig.BuiltinFn.Tag = switch (kind) {
        .min => .min,
        .max => .max,
    };
    const types = try analyser.arena.alloc(InternPool.Index, operands.len);
    for (operands, types) |operand, *ty| {
        if (operand.is_type_val) return null;
        ty.* = (try operand.typeOf(analyser)).ipIndex() orelse return null;
    }

    const result_type = try analyser.ip.resolvePeerTypes(types, builtin.target);
    if (result_type == .none) return null;
    const fallback = Type.fromIP(analyser, result_type, null);
    if (analyser.ip.zigTypeTag(result_type) == .vector) {
        return try analyser.resolveVectorMinMaxValue(tag, operands, result_type) orelse fallback;
    }
    if (analyser.fixedWidthIntegerBounds(result_type)) |bounds| {
        const boundary = switch (kind) {
            .min => bounds.min,
            .max => bounds.max,
        };
        var has_boundary = false;
        var has_undefined = false;
        for (operands) |operand| {
            const index = operand.ipIndex() orelse continue;
            if (analyser.ip.isUndefined(index)) {
                has_undefined = true;
                continue;
            }
            if (analyser.ip.toInt(index, i256) == boundary) has_boundary = true;
        }
        if (has_boundary and !has_undefined) {
            return try analyser.intValueWithType(result_type, boundary) orelse fallback;
        }
    }

    var selected = operands[0];
    switch (analyser.ip.zigTypeTag(result_type) orelse return fallback) {
        .int, .comptime_int => {
            var selected_value = analyser.ip.toInt(selected.ipIndex() orelse return fallback, i256) orelse return fallback;
            for (operands[1..]) |candidate| {
                const candidate_value = analyser.ip.toInt(candidate.ipIndex() orelse return fallback, i256) orelse return fallback;
                const prefer_candidate = switch (kind) {
                    .min => candidate_value < selected_value,
                    .max => candidate_value > selected_value,
                };
                if (prefer_candidate) {
                    selected = candidate;
                    selected_value = candidate_value;
                }
            }
        },
        .float, .comptime_float => {
            var selected_value = analyser.numericFloatValue(selected.ipIndex() orelse return fallback) orelse return fallback;
            if (!std.math.isFinite(selected_value)) return fallback;
            for (operands[1..]) |candidate| {
                const candidate_value = analyser.numericFloatValue(candidate.ipIndex() orelse return fallback) orelse return fallback;
                if (!std.math.isFinite(candidate_value)) return fallback;
                const prefer_candidate = switch (kind) {
                    .min => candidate_value < selected_value or
                        (candidate_value == 0 and selected_value == 0 and
                            std.math.signbit(candidate_value) and !std.math.signbit(selected_value)),
                    .max => candidate_value > selected_value or
                        (candidate_value == 0 and selected_value == 0 and
                            !std.math.signbit(candidate_value) and std.math.signbit(selected_value)),
                };
                if (prefer_candidate) {
                    selected = candidate;
                    selected_value = candidate_value;
                }
            }
        },
        else => return fallback,
    }
    const selected_index = selected.ipIndex().?;
    if (analyser.ip.typeOf(selected_index) == result_type) return selected;
    if (analyser.ip.zigTypeTag(result_type) == .float) {
        const coerced = try analyser.coerceNumericToFloatValue(result_type, selected_index) orelse return fallback;
        return Type.fromIP(analyser, result_type, coerced);
    }
    var err_msg: ErrorMsg = undefined;
    const coerced = try analyser.ip.coerce(analyser.arena, result_type, selected_index, builtin.target, &err_msg);
    if (coerced == .none or analyser.ip.isUnknown(coerced)) return fallback;
    return Type.fromIP(analyser, result_type, coerced);
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

pub fn resolveComptimeUnaryValue(
    analyser: *Analyser,
    tag: Ast.Node.Tag,
    operand: Type,
) error{OutOfMemory}!?Type {
    return switch (tag) {
        .bool_not => try analyser.resolveVectorBoolNotValue(operand) orelse switch (operand.data) {
            .ip_index => |payload| if (payload.type != .bool_type)
                null
            else switch (payload.index orelse return Type.fromIP(analyser, .bool_type, null)) {
                .bool_false => Type.fromIP(analyser, .bool_type, .bool_true),
                .bool_true => Type.fromIP(analyser, .bool_type, .bool_false),
                else => Type.fromIP(analyser, .bool_type, null),
            },
            else => null,
        },
        .bit_not => if (analyser.ip.zigTypeTag((try operand.typeOf(analyser)).ipIndex() orelse return null) == .vector)
            analyser.resolveVectorUnaryValue(.bit_not, operand)
        else switch (operand.data) {
            .ip_index => |payload| switch (analyser.ip.zigTypeTag(payload.type) orelse return null) {
                .int, .comptime_int => try analyser.resolveBitNotValue(operand) orelse
                    Type.fromIP(analyser, payload.type, null),
                else => null,
            },
            else => null,
        },
        .negation, .negation_wrap => if (analyser.ip.zigTypeTag((try operand.typeOf(analyser)).ipIndex() orelse return null) == .vector)
            analyser.resolveVectorUnaryValue(
                if (tag == .negation_wrap) .negate_wrap else .negate,
                operand,
            )
        else switch (operand.data) {
            .ip_index => |payload| switch (analyser.ip.zigTypeTag(payload.type) orelse return null) {
                .float, .comptime_float => if (tag == .negation_wrap)
                    null
                else
                    try analyser.resolveNegationValue(operand, false) orelse
                        Type.fromIP(analyser, payload.type, null),
                .comptime_int => try analyser.resolveNegationValue(operand, tag == .negation_wrap) orelse
                    Type.fromIP(analyser, payload.type, null),
                .int => try analyser.resolveNegationValue(operand, tag == .negation_wrap) orelse
                    if (tag == .negation_wrap or analyser.ip.isSignedInt(payload.type, builtin.target))
                        Type.fromIP(analyser, payload.type, null)
                    else
                        null,
                else => null,
            },
            else => null,
        },
        else => null,
    };
}

fn resolveTypeBitSize(analyser: *Analyser, ty: Type) ?u64 {
    if (!ty.is_type_val) return null;
    return switch (ty.data) {
        .container => blk: {
            var buffer: [2]Ast.Node.Index = undefined;
            const info = astContainerTypeInfo(ty, &buffer) orelse break :blk null;
            if (ty.isEnumType(analyser)) {
                const tag_type = (analyser.astEnumTagType(ty, info.declaration, info.handle) catch break :blk null) orelse
                    break :blk null;
                break :blk analyser.resolveTypeBitSize(tag_type);
            }
            if (ty.getContainerKind() != .keyword_struct or info.layout != .@"packed") break :blk null;
            const backing_type = (analyser.astPackedStructBackingType(ty, info.declaration, info.handle) catch break :blk null) orelse
                break :blk null;
            break :blk analyser.resolveTypeBitSize(backing_type);
        },
        .pointer => |info| switch (info.size) {
            .slice => @as(u64, builtin.target.ptrBitWidth()) * 2,
            .one, .many, .c => builtin.target.ptrBitWidth(),
        },
        .vector => |info| blk: {
            const elem_bits = analyser.resolveTypeBitSize(info.elem_ty.*) orelse break :blk null;
            break :blk std.math.mul(u64, info.len, elem_bits) catch null;
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
                .@"enum" => {
                    const info = analyser.ip.getEnum(analyser.ip.indexToKey(type_index).enum_type);
                    break :blk analyser.resolveTypeBitSize(Type.fromIP(analyser, .type_type, info.tag_type));
                },
                .@"struct" => {
                    const info = analyser.ip.getStruct(analyser.ip.indexToKey(type_index).struct_type);
                    if (info.layout != .@"packed" or info.backing_int_ty == .none) break :blk null;
                    break :blk analyser.resolveTypeBitSize(Type.fromIP(analyser, .type_type, info.backing_int_ty));
                },
                .@"union" => {
                    const info = analyser.ip.getUnion(analyser.ip.indexToKey(type_index).union_type);
                    if (info.layout != .@"packed" or info.backing_int_ty == .none) break :blk null;
                    break :blk analyser.resolveTypeBitSize(Type.fromIP(analyser, .type_type, info.backing_int_ty));
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
        .container => blk: {
            var buffer: [2]Ast.Node.Index = undefined;
            const info = astContainerTypeInfo(ty, &buffer) orelse break :blk null;
            if (ty.isEnumType(analyser)) {
                const tag_type = (analyser.astEnumTagType(ty, info.declaration, info.handle) catch break :blk null) orelse
                    break :blk null;
                break :blk analyser.resolveTypeByteSize(tag_type);
            }
            if (ty.getContainerKind() != .keyword_struct or info.layout != .@"packed") break :blk null;
            const backing_type = (analyser.astPackedStructBackingType(ty, info.declaration, info.handle) catch break :blk null) orelse
                break :blk null;
            break :blk analyser.resolveTypeByteSize(backing_type);
        },
        .pointer => |info| switch (info.size) {
            .slice => @as(u64, builtin.target.ptrBitWidth() / 8) * 2,
            .one, .many, .c => builtin.target.ptrBitWidth() / 8,
        },
        .vector => |info| blk: {
            const elem_bits = analyser.resolveTypeBitSize(info.elem_ty.*) orelse break :blk null;
            const total_bits = std.math.mul(u64, info.len, elem_bits) catch break :blk null;
            const byte_count = std.math.divCeil(u64, total_bits, 8) catch break :blk null;
            break :blk if (byte_count == 0) 0 else std.math.ceilPowerOfTwo(u64, byte_count) catch null;
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
                .int => std.zig.target.intByteSize(
                    &builtin.target,
                    analyser.ip.intInfo(type_index, builtin.target).bits,
                ),
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
                .@"enum" => {
                    const info = analyser.ip.getEnum(analyser.ip.indexToKey(type_index).enum_type);
                    break :blk analyser.resolveTypeByteSize(Type.fromIP(analyser, .type_type, info.tag_type));
                },
                .@"struct" => {
                    const info = analyser.ip.getStruct(analyser.ip.indexToKey(type_index).struct_type);
                    if (info.layout != .@"packed" or info.backing_int_ty == .none) break :blk null;
                    break :blk analyser.resolveTypeByteSize(Type.fromIP(analyser, .type_type, info.backing_int_ty));
                },
                .@"union" => {
                    const info = analyser.ip.getUnion(analyser.ip.indexToKey(type_index).union_type);
                    if (info.layout != .@"packed" or info.backing_int_ty == .none) break :blk null;
                    break :blk analyser.resolveTypeByteSize(Type.fromIP(analyser, .type_type, info.backing_int_ty));
                },
                else => null,
            };
        },
        else => null,
    };
}

fn resolveTypeAlignment(analyser: *Analyser, ty: Type) Error!?u64 {
    if (!ty.is_type_val) return null;
    return switch (ty.data) {
        .pointer => std.zig.target.intAlignment(&builtin.target, builtin.target.ptrBitWidth()),
        .array => |info| try analyser.resolveTypeAlignment(info.elem_ty.*),
        .vector => |info| blk: {
            if (info.len == 0) break :blk 1;
            const elem_bits = analyser.resolveTypeBitSize(info.elem_ty.*) orelse break :blk null;
            if (elem_bits == 0) break :blk 1;
            const total_bits = std.math.mul(u64, info.len, elem_bits) catch break :blk null;
            const byte_count = std.math.divCeil(u64, total_bits, 8) catch break :blk null;
            break :blk std.math.ceilPowerOfTwo(u64, byte_count) catch null;
        },
        .container => blk: {
            var buffer: [2]Ast.Node.Index = undefined;
            const info = astContainerTypeInfo(ty, &buffer) orelse break :blk null;
            if (ty.isEnumType(analyser)) {
                const tag_type = try analyser.astEnumTagType(ty, info.declaration, info.handle) orelse break :blk null;
                break :blk try analyser.resolveTypeAlignment(tag_type);
            }
            if (ty.getContainerKind() != .keyword_struct or info.layout != .@"packed") break :blk null;
            const backing_type = try analyser.astPackedStructBackingType(ty, info.declaration, info.handle) orelse break :blk null;
            break :blk try analyser.resolveTypeAlignment(backing_type);
        },
        .ip_index => |payload| blk: {
            const type_index = payload.index orelse break :blk null;
            break :blk switch (analyser.ip.zigTypeTag(type_index) orelse break :blk null) {
                .int => std.zig.target.intAlignment(
                    &builtin.target,
                    analyser.ip.intInfo(type_index, builtin.target).bits,
                ),
                .bool, .void, .noreturn => 1,
                .float => switch (type_index) {
                    .f16_type => 2,
                    .f32_type => builtin.target.cTypeAlignment(.float),
                    .f64_type => if (builtin.target.cTypeBitSize(.double) == 64)
                        builtin.target.cTypeAlignment(.double)
                    else
                        8,
                    .f80_type => if (builtin.target.cTypeBitSize(.longdouble) == 80)
                        builtin.target.cTypeAlignment(.longdouble)
                    else
                        std.zig.target.intAlignment(&builtin.target, 80),
                    .f128_type => if (builtin.target.cTypeBitSize(.longdouble) == 128)
                        builtin.target.cTypeAlignment(.longdouble)
                    else
                        16,
                    .c_longdouble_type => builtin.target.cTypeAlignment(.longdouble),
                    else => break :blk null,
                },
                .pointer => std.zig.target.intAlignment(&builtin.target, builtin.target.ptrBitWidth()),
                .array => try analyser.resolveTypeAlignment(Type.fromIP(
                    analyser,
                    .type_type,
                    analyser.ip.indexToKey(type_index).array_type.child,
                )),
                .@"enum" => try analyser.resolveTypeAlignment(Type.fromIP(
                    analyser,
                    .type_type,
                    analyser.ip.getEnum(analyser.ip.indexToKey(type_index).enum_type).tag_type,
                )),
                .@"struct" => packed_layout: {
                    const info = analyser.ip.getStruct(analyser.ip.indexToKey(type_index).struct_type);
                    if (info.layout != .@"packed" or info.backing_int_ty == .none) break :packed_layout null;
                    break :packed_layout try analyser.resolveTypeAlignment(Type.fromIP(analyser, .type_type, info.backing_int_ty));
                },
                .@"union" => packed_layout: {
                    const info = analyser.ip.getUnion(analyser.ip.indexToKey(type_index).union_type);
                    if (info.layout != .@"packed" or info.backing_int_ty == .none) break :packed_layout null;
                    break :packed_layout try analyser.resolveTypeAlignment(Type.fromIP(analyser, .type_type, info.backing_int_ty));
                },
                else => null,
            };
        },
        else => null,
    };
}

pub const ComptimeTypeSizeKind = enum { bit_size, byte_size, alignment };

pub fn resolveComptimeTypeSizeValue(
    analyser: *Analyser,
    operand: Type,
    kind: ComptimeTypeSizeKind,
) Error!?Type {
    const value = switch (kind) {
        .bit_size => analyser.resolveTypeBitSize(operand),
        .byte_size => analyser.resolveTypeByteSize(operand),
        .alignment => try analyser.resolveTypeAlignment(operand),
    } orelse return null;
    return try analyser.comptimeIntValue(value);
}

pub const ComptimeFieldOffsetKind = enum { bit_offset, byte_offset };

fn alignForwardFieldOffset(offset: u64, alignment: u64) ?u64 {
    if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) return null;
    const with_padding = std.math.add(u64, offset, alignment - 1) catch return null;
    return with_padding & ~(alignment - 1);
}

pub fn resolveComptimeFieldOffsetValue(
    analyser: *Analyser,
    container_type: Type,
    field_name: []const u8,
    kind: ComptimeFieldOffsetKind,
) Error!?Type {
    if (!container_type.is_type_val) return null;

    const bit_offset: u64 = switch (container_type.data) {
        .container => blk: {
            var buffer: [2]Ast.Node.Index = undefined;
            const info = astContainerTypeInfo(container_type, &buffer) orelse return null;
            if (container_type.getContainerKind() != .keyword_struct or info.layout == .auto) return null;

            var offset: u64 = 0;
            for (info.declaration.ast.members) |member| {
                const field = info.handle.tree.fullContainerField(member) orelse continue;
                if (field.ast.tuple_like or field.comptime_token != null) return null;
                const name = try analyser.identifierTokenName(&info.handle.tree, field.ast.main_token) orelse return null;
                const field_type_node = field.ast.type_expr.unwrap() orelse return null;
                const field_type = try analyser.resolveTypeOfNodeInternal(.{
                    .node_handle = .of(field_type_node, info.handle),
                    .container_type = container_type,
                }) orelse return null;
                switch (info.layout) {
                    .@"packed" => {
                        if (std.mem.eql(u8, name, field_name)) break :blk offset;
                        const field_bits = analyser.resolveTypeBitSize(field_type) orelse return null;
                        offset = std.math.add(u64, offset, field_bits) catch return null;
                    },
                    .@"extern" => {
                        const alignment = if (field.ast.align_expr.unwrap()) |align_expr|
                            try analyser.resolveIntegerLiteral(u64, .{
                                .node_handle = .of(align_expr, info.handle),
                                .container_type = container_type,
                            }) orelse return null
                        else
                            try analyser.resolveTypeAlignment(field_type) orelse return null;
                        offset = alignForwardFieldOffset(offset, alignment) orelse return null;
                        if (std.mem.eql(u8, name, field_name)) {
                            break :blk std.math.mul(u64, offset, 8) catch return null;
                        }
                        const field_bytes = analyser.resolveTypeByteSize(field_type) orelse return null;
                        offset = std.math.add(u64, offset, field_bytes) catch return null;
                    },
                    .auto => unreachable,
                }
            }
            return null;
        },
        .ip_index => |payload| blk: {
            const type_index = payload.index orelse return null;
            const struct_info = switch (analyser.ip.indexToKey(type_index)) {
                .struct_type => |struct_index| analyser.ip.getStruct(struct_index),
                else => return null,
            };
            if (struct_info.layout == .auto) return null;
            const name_index = analyser.ip.string_pool.getString(analyser.store.io, field_name) orelse return null;
            const field_index = struct_info.fields.getIndex(name_index) orelse return null;
            if (struct_info.fields.values()[field_index].is_comptime) return null;

            const generated_fields = analyser.generated_struct_fields.get(type_index);
            var offset: u64 = 0;
            for (struct_info.fields.values()[0 .. field_index + 1], 0..) |field, index| {
                if (field.is_comptime) return null;
                const field_type = if (generated_fields) |fields|
                    fields[index].ty
                else
                    Type.fromIP(analyser, .type_type, field.ty);
                switch (struct_info.layout) {
                    .@"packed" => {
                        if (index == field_index) break :blk offset;
                        const field_bits = analyser.resolveTypeBitSize(field_type) orelse return null;
                        offset = std.math.add(u64, offset, field_bits) catch return null;
                    },
                    .@"extern" => {
                        const alignment = if (field.alignment != 0)
                            field.alignment
                        else
                            try analyser.resolveTypeAlignment(field_type) orelse return null;
                        offset = alignForwardFieldOffset(offset, alignment) orelse return null;
                        if (index == field_index) break :blk std.math.mul(u64, offset, 8) catch return null;
                        const field_bytes = analyser.resolveTypeByteSize(field_type) orelse return null;
                        offset = std.math.add(u64, offset, field_bytes) catch return null;
                    },
                    .auto => unreachable,
                }
            }
            unreachable;
        },
        else => return null,
    };

    return @as(?Type, try analyser.comptimeIntValue(switch (kind) {
        .bit_offset => bit_offset,
        .byte_offset => bit_offset / 8,
    }));
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

pub fn stringValueWithType(analyser: *Analyser, bytes: []const u8, string_type: Type) error{OutOfMemory}!Type {
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

fn canResolveTypeName(analyser: *Analyser, ty: Type) error{OutOfMemory}!bool {
    if (!ty.is_type_val) return false;
    return switch (ty.data) {
        .pointer => |info| try analyser.canResolveTypeName(info.elem_ty.*),
        .array => |info| info.elem_count != null and
            info.sentinel != .unknown_unknown and
            try analyser.canResolveTypeName(info.elem_ty.*),
        .vector => |info| try analyser.canResolveTypeName(info.elem_ty.*),
        .tuple => |types| for (types) |element_type| {
            if (!try analyser.canResolveTypeName(element_type)) break false;
        } else true,
        .function => |info| function: {
            if (info.name != null or info.calling_convention == null) break :function false;
            if (!try analyser.canResolveTypeName(try info.return_value.typeOf(analyser))) break :function false;
            for (info.parameters) |parameter| {
                if (parameter.type.data == .anytype_parameter or
                    !try analyser.canResolveTypeName(parameter.type)) break :function false;
            }
            break :function true;
        },
        .optional => |child_ty| try analyser.canResolveTypeName(child_ty.*),
        .error_union => |info| (info.error_set == null or try analyser.canResolveTypeName(info.error_set.?.*)) and
            try analyser.canResolveTypeName(info.payload.*),
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
                try analyser.canResolveTypeName(Type.fromIP(analyser, .type_type, info.elem_type)),
            .array_type => |info| info.sentinel != .unknown_unknown and
                try analyser.canResolveTypeName(Type.fromIP(analyser, .type_type, info.child)),
            .optional_type => |info| try analyser.canResolveTypeName(Type.fromIP(analyser, .type_type, info.payload_type)),
            .error_union_type => |info| (info.error_set_type == .none or
                try analyser.canResolveTypeName(Type.fromIP(analyser, .type_type, info.error_set_type))) and
                try analyser.canResolveTypeName(Type.fromIP(analyser, .type_type, info.payload_type)),
            .error_set_type => true,
            .vector_type => |info| try analyser.canResolveTypeName(Type.fromIP(analyser, .type_type, info.child)),
            .function_type => |info| function: {
                if (info.flags.is_generic or info.flags.alignment != 0) break :function false;
                for (0..info.args.len) |index| {
                    const argument = info.args.at(@intCast(index), analyser.ip);
                    if (!try analyser.canResolveTypeName(Type.fromIP(analyser, .type_type, argument))) break :function false;
                }
                break :function try analyser.canResolveTypeName(Type.fromIP(analyser, .type_type, info.return_type));
            },
            .tuple_type => |info| types: {
                for (0..info.types.len) |index| {
                    const element_type = Type.fromIP(analyser, .type_type, info.types.at(@intCast(index), analyser.ip));
                    if (!try analyser.canResolveTypeName(element_type)) break :types false;
                }
                break :types true;
            },
            else => false,
        },
        else => false,
    };
}

fn resolveTypeNameValue(analyser: *Analyser, ty: Type) error{OutOfMemory}![]const u8 {
    if (ty.data == .ip_index) {
        const index = ty.data.ip_index.index.?;
        switch (analyser.ip.indexToKey(index)) {
            .error_set_type => return analyser.canonicalErrorSetTypeName(index),
            .error_union_type => |info| if (info.error_set_type != .none and
                analyser.ip.indexToKey(info.error_set_type) == .error_set_type)
            {
                const error_set_name = try analyser.canonicalErrorSetTypeName(info.error_set_type);
                const payload_name = try analyser.resolveTypeNameValue(Type.fromIP(analyser, .type_type, info.payload_type));
                return std.mem.concat(analyser.arena, u8, &.{ error_set_name, "!", payload_name });
            },
            else => {},
        }
    }
    const bytes = try ty.stringifyTypeVal(analyser, .{ .truncate_container_decls = false });
    const is_interned_function = switch (ty.data) {
        .ip_index => |payload| analyser.ip.indexToKey(payload.index.?) == .function_type,
        else => false,
    };
    if (is_interned_function and std.mem.startsWith(u8, bytes, "fn(")) {
        return std.mem.concat(analyser.arena, u8, &.{ "fn ", bytes[2..] });
    }
    return bytes;
}

pub fn resolveComptimeTypeNameValue(analyser: *Analyser, operand: Type) error{OutOfMemory}!?Type {
    if (!try analyser.canResolveTypeName(operand)) return null;
    return try analyser.stringValue(try analyser.resolveTypeNameValue(operand));
}

pub fn resolveComptimeSourceLocationValue(
    analyser: *Analyser,
    handle: *DocumentStore.Handle,
    node: Ast.Node.Index,
) Error!?Type {
    const result_type = try analyser.resolveLangrefType(
        version_data.builtins.get("@src").?.return_type,
    ) orelse return null;
    const source_index = handle.tree.tokenStart(handle.tree.firstToken(node));
    const position = offsets.indexToPosition(handle.tree.source, source_index, .@"utf-8");
    const line = std.math.add(u32, position.line, 1) catch return null;
    const column = std.math.add(u32, position.character, 1) catch return null;
    const fields = try analyser.arena.alloc(comptime_eval.Value.Field, 2);
    fields[0] = .{
        .name = "line",
        .value = try analyser.intValueWithType(.u32_type, line) orelse return null,
    };
    fields[1] = .{
        .name = "column",
        .value = try analyser.intValueWithType(.u32_type, column) orelse return null,
    };
    return @as(?Type, try comptime_eval.Value.create(analyser, result_type, .{ .fields = fields }));
}

fn canonicalErrorSetTypeName(analyser: *Analyser, type_index: InternPool.Index) error{OutOfMemory}![]const u8 {
    const error_set = analyser.ip.indexToKey(type_index).error_set_type;
    const names = try error_set.names.dupe(analyser.arena, analyser.ip);
    analyser.ip.string_pool.sortStrings(analyser.store.io, names);

    var result: std.Io.Writer.Allocating = .init(analyser.arena);
    defer result.deinit();
    result.writer.writeAll("error{") catch return error.OutOfMemory;
    for (names, 0..) |name, index| {
        if (index != 0) result.writer.writeByte(',') catch return error.OutOfMemory;
        const bytes = try analyser.ip.string_pool.stringToSliceAlloc(analyser.store.io, analyser.arena, name);
        result.writer.writeAll(bytes) catch return error.OutOfMemory;
    }
    result.writer.writeByte('}') catch return error.OutOfMemory;
    return result.toOwnedSlice();
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
    if (analyser.ip.zigTypeTag(payload.type) != .int) return null;
    const int_info = analyser.ip.intInfo(payload.type, builtin.target);
    if (int_info.bits == 0) return null;
    const result_bits: u16 = @intCast(std.math.log2_int_ceil(u32, @as(u32, int_info.bits) + 1));
    const result_type = try analyser.ip.get(.{ .int_type = .{
        .signedness = .unsigned,
        .bits = result_bits,
    } });
    const index = payload.index orelse return Type.fromIP(analyser, result_type, null);
    if (analyser.ip.isUnknown(index)) return Type.fromIP(analyser, result_type, null);

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
    const operand_type = (try operand.typeOf(analyser)).ipIndex() orelse return null;
    const vector = switch (analyser.ip.indexToKey(operand_type)) {
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
    const source_items = comptime_eval.Value.elements(operand);
    const source_values = analyser.aggregateValues(operand);
    if (source_items == null and source_values == null) return Type.fromIP(analyser, result_type, null);
    if ((source_items != null and source_items.?.len != vector.len) or
        (source_values != null and source_values.?.len != vector.len)) return null;

    const values = try analyser.gpa.alloc(InternPool.Index, vector.len);
    defer analyser.gpa.free(values);
    for (values, 0..) |*value, i| {
        const element = if (source_items) |items|
            items[i]
        else
            Type.fromIP(analyser, vector.child, source_values.?.at(@intCast(i), analyser.ip));
        const resolved = try analyser.resolveBitCountValue(tag, element);
        value.* = if (resolved) |result| result.ipIndex() orelse try analyser.ip.getUnknown(result_child) else try analyser.ip.getUnknown(result_child);
    }
    return analyser.aggregateValue(Type.fromIP(analyser, result_type, null), values);
}

pub const ComptimeBitCountKind = enum { clz, ctz, pop_count };

pub fn resolveComptimeBitCountValue(
    analyser: *Analyser,
    operand: Type,
    kind: ComptimeBitCountKind,
) error{OutOfMemory}!?Type {
    const tag: std.zig.BuiltinFn.Tag = switch (kind) {
        .clz => .clz,
        .ctz => .ctz,
        .pop_count => .pop_count,
    };
    const operand_type = (try operand.typeOf(analyser)).ipIndex() orelse return null;
    if (analyser.ip.zigTypeTag(operand_type) == .vector) {
        return analyser.resolveVectorBitCountValue(tag, operand);
    }
    return analyser.resolveBitCountValue(tag, operand);
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
    if (analyser.ip.zigTypeTag(payload.type) != .int) return null;
    const int_info = analyser.ip.intInfo(payload.type, builtin.target);
    if (tag == .byte_swap and int_info.bits % 8 != 0) return null;
    const index = payload.index orelse return Type.fromIP(analyser, payload.type, null);
    if (analyser.ip.isUnknown(index)) return Type.fromIP(analyser, payload.type, null);
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
    const operand_type = (try operand.typeOf(analyser)).ipIndex() orelse return null;
    const vector = switch (analyser.ip.indexToKey(operand_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    if (analyser.ip.zigTypeTag(vector.child) != .int) return null;
    const int_info = analyser.ip.intInfo(vector.child, builtin.target);
    if (tag == .byte_swap and int_info.bits % 8 != 0) return null;
    const source_items = comptime_eval.Value.elements(operand);
    const source_values = analyser.aggregateValues(operand);
    if (source_items == null and source_values == null) return Type.fromIP(analyser, operand_type, null);
    if ((source_items != null and source_items.?.len != vector.len) or
        (source_values != null and source_values.?.len != vector.len)) return null;

    const values = try analyser.gpa.alloc(InternPool.Index, vector.len);
    defer analyser.gpa.free(values);
    for (values, 0..) |*value, i| {
        const element = if (source_items) |items|
            items[i]
        else
            Type.fromIP(analyser, vector.child, source_values.?.at(@intCast(i), analyser.ip));
        const resolved = try analyser.resolveBitPermutationValue(tag, element);
        value.* = if (resolved) |result| result.ipIndex() orelse try analyser.ip.getUnknown(vector.child) else try analyser.ip.getUnknown(vector.child);
    }
    return analyser.aggregateValue(Type.fromIP(analyser, operand_type, null), values);
}

pub const ComptimeBitPermutationKind = enum { bit_reverse, byte_swap };

pub fn resolveComptimeBitPermutationValue(
    analyser: *Analyser,
    operand: Type,
    kind: ComptimeBitPermutationKind,
) error{OutOfMemory}!?Type {
    const tag: std.zig.BuiltinFn.Tag = switch (kind) {
        .bit_reverse => .bit_reverse,
        .byte_swap => .byte_swap,
    };
    const operand_type = (try operand.typeOf(analyser)).ipIndex() orelse return null;
    if (analyser.ip.zigTypeTag(operand_type) == .vector) {
        return analyser.resolveVectorBitPermutationValue(tag, operand);
    }
    return analyser.resolveBitPermutationValue(tag, operand);
}

fn isValidRuntimeShiftType(
    analyser: *Analyser,
    shift_type: InternPool.Index,
    operand_bits: u16,
) bool {
    if (analyser.ip.zigTypeTag(shift_type) != .int) return false;
    const shift_info = analyser.ip.intInfo(shift_type, builtin.target);
    return shift_info.signedness == .unsigned and
        shift_info.bits <= std.math.log2_int_ceil(u16, operand_bits);
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
    const shift_payload = switch (shift_operand.data) {
        .ip_index => |shift_value| shift_value,
        else => return null,
    };
    if (try analyser.resolveZeroShiftValue(operand, shift_operand)) |value| return value;
    if (payload.index) |index| if (analyser.ip.isUndefined(index)) return null;

    const type_tag = analyser.ip.zigTypeTag(payload.type) orelse return null;
    if (type_tag != .int and type_tag != .comptime_int) return null;
    const operand_bits = if (type_tag == .int) bits: {
        const bits = analyser.ip.intInfo(payload.type, builtin.target).bits;
        if (bits == 0) return null;
        break :bits bits;
    } else null;
    const shift_index = shift_payload.index orelse {
        const bits = operand_bits orelse return null;
        if (!analyser.isValidRuntimeShiftType(shift_payload.type, bits)) return null;
        return Type.fromIP(analyser, payload.type, null);
    };
    if (analyser.ip.isUndefined(shift_index)) return null;
    if (analyser.ip.isUnknown(shift_index)) {
        const bits = operand_bits orelse return null;
        if (!analyser.isValidRuntimeShiftType(shift_payload.type, bits)) return null;
        return Type.fromIP(analyser, payload.type, null);
    }
    const shift = analyser.ip.toInt(shift_index, u16) orelse return null;
    if (operand_bits) |bits| if (shift >= bits) return null;

    const index = payload.index orelse return Type.fromIP(analyser, payload.type, null);
    if (analyser.ip.isUnknown(index)) return Type.fromIP(analyser, payload.type, null);
    if (type_tag == .int) {
        const info = analyser.ip.intInfo(payload.type, builtin.target);
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
    const operand_type = (try operand.typeOf(analyser)).ipIndex() orelse return null;
    const shift_type = (try shift_operand.typeOf(analyser)).ipIndex() orelse return null;
    const vector = switch (analyser.ip.indexToKey(operand_type)) {
        .vector_type => |vector| vector,
        else => return null,
    };
    const shift_vector = switch (analyser.ip.indexToKey(shift_type)) {
        .vector_type => |shift_vector| shift_vector,
        else => return null,
    };
    if (vector.len != shift_vector.len) return null;
    const source_items = comptime_eval.Value.elements(operand);
    const shift_items = comptime_eval.Value.elements(shift_operand);
    const source_values = analyser.aggregateValues(operand);
    const shift_values = analyser.aggregateValues(shift_operand);
    if ((source_items != null and source_items.?.len != vector.len) or
        (shift_items != null and shift_items.?.len != shift_vector.len) or
        (source_values != null and source_values.?.len != vector.len) or
        (shift_values != null and shift_values.?.len != shift_vector.len)) return null;
    if (operation == .shl_exact or operation == .shr_exact) {
        if (analyser.ip.zigTypeTag(vector.child) != .int) return null;
        const operand_bits = analyser.ip.intInfo(vector.child, builtin.target).bits;
        if (operand_bits == 0 or analyser.ip.zigTypeTag(shift_vector.child) != .int) return null;
        if (operand.ipIndex()) |index| if (analyser.ip.isUndefined(index)) return null;
        if (shift_operand.ipIndex()) |index| if (analyser.ip.isUndefined(index)) return null;
        if (!analyser.isValidRuntimeShiftType(shift_vector.child, operand_bits)) {
            for (0..shift_vector.len) |i| {
                const shift_index = if (shift_items) |items|
                    items[i].ipIndex() orelse return null
                else if (shift_values) |values|
                    values.at(@intCast(i), analyser.ip)
                else
                    return null;
                if (analyser.ip.isUndefined(shift_index) or analyser.ip.isUnknown(shift_index)) return null;
            }
        }
    }

    const values = try analyser.gpa.alloc(InternPool.Index, vector.len);
    defer analyser.gpa.free(values);
    const unknown_operand = try analyser.ip.getUnknown(vector.child);
    const unknown_shift = try analyser.ip.getUnknown(shift_vector.child);
    for (values, 0..) |*value, i| {
        const index: u32 = @intCast(i);
        const element = if (source_items) |items|
            items[i]
        else
            Type.fromIP(analyser, vector.child, if (source_values) |slice| slice.at(index, analyser.ip) else unknown_operand);
        const shift_element = if (shift_items) |items|
            items[i]
        else
            Type.fromIP(analyser, shift_vector.child, if (shift_values) |slice| slice.at(index, analyser.ip) else unknown_shift);
        const resolved = switch (operation) {
            .shl => try analyser.resolveIntegerBinaryValue(.shl, element, shift_element),
            .shr => try analyser.resolveIntegerBinaryValue(.shr, element, shift_element),
            .shl_exact => try analyser.resolveExactShiftValue(.shl_exact, element, shift_element),
            .shr_exact => try analyser.resolveExactShiftValue(.shr_exact, element, shift_element),
        };
        value.* = if (resolved) |result|
            result.ipIndex() orelse try analyser.ip.getUnknown(vector.child)
        else switch (operation) {
            .shl, .shr => try analyser.ip.getUnknown(vector.child),
            .shl_exact, .shr_exact => return null,
        };
    }
    return analyser.aggregateValue(Type.fromIP(analyser, operand_type, null), values);
}

pub const ComptimeExactShiftKind = enum { shl_exact, shr_exact };

pub fn resolveComptimeExactShiftValue(
    analyser: *Analyser,
    operand: Type,
    shift_operand: Type,
    kind: ComptimeExactShiftKind,
) error{OutOfMemory}!?Type {
    const tag: std.zig.BuiltinFn.Tag = switch (kind) {
        .shl_exact => .shl_exact,
        .shr_exact => .shr_exact,
    };
    const operand_type = (try operand.typeOf(analyser)).ipIndex() orelse return null;
    if (analyser.ip.zigTypeTag(operand_type) == .vector) {
        const operation: VectorShiftOperation = switch (kind) {
            .shl_exact => .shl_exact,
            .shr_exact => .shr_exact,
        };
        return analyser.resolveVectorShiftValue(operation, operand, shift_operand);
    }
    return analyser.resolveExactShiftValue(tag, operand, shift_operand);
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

pub fn coerceIP(analyser: *Analyser, dest_ty: InternPool.Index, inst: InternPool.Index) error{OutOfMemory}!?InternPool.Index {
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

    if (is_cimport or !analyser.collect_callsite_references or analyser.callsite_reference_depth >= 1) return null;

    // protection against recursive callsite resolution
    const gop_resolved = try analyser.resolved_callsites.getOrPut(analyser.gpa, pay);
    if (gop_resolved.found_existing) return gop_resolved.value_ptr.*;
    gop_resolved.value_ptr.* = null;
    analyser.callsite_reference_depth += 1;
    defer analyser.callsite_reference_depth -= 1;

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

fn isAggregateComptimeArgument(tree: *const Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .array_init_one,
        .array_init_one_comma,
        .array_init_dot_two,
        .array_init_dot_two_comma,
        .array_init_dot,
        .array_init_dot_comma,
        .array_init,
        .array_init_comma,
        .struct_init,
        .struct_init_comma,
        .struct_init_one,
        .struct_init_one_comma,
        => true,
        .address_of, .@"comptime" => isAggregateComptimeArgument(tree, tree.nodeData(node).node),
        .grouped_expression => isAggregateComptimeArgument(tree, tree.nodeData(node).node_and_token[0]),
        else => false,
    };
}

fn displayComptimeArgument(
    analyser: *Analyser,
    handle: *DocumentStore.Handle,
    node: Ast.Node.Index,
) error{OutOfMemory}!?NodeWithHandle {
    if (isAggregateComptimeArgument(&handle.tree, node)) return .of(node, handle);
    if (handle.tree.nodeTag(node) != .identifier) return null;

    const name_token = ast.identifierTokenFromIdentifierNode(&handle.tree, node) orelse return null;
    const name = offsets.identifierTokenToNameSlice(&handle.tree, name_token);
    const decl = try analyser.lookupSymbolGlobal(handle, name, handle.tree.tokenStart(name_token)) orelse return null;
    const bindings = analyser.display_bindings orelse return null;
    return bindings.get(.{ .token = decl.nameToken(), .handle = decl.handle });
}

fn unwrapAggregateComptimeArgument(tree: *const Ast, argument: Ast.Node.Index) Ast.Node.Index {
    var node = argument;
    while (true) switch (tree.nodeTag(node)) {
        .address_of, .@"comptime" => node = tree.nodeData(node).node,
        .grouped_expression => node = tree.nodeData(node).node_and_token[0],
        else => return node,
    };
}

fn aggregateComptimeElementType(analyser: *Analyser, aggregate_type: Type) error{OutOfMemory}!?Type {
    const runtime_type = if (aggregate_type.is_type_val)
        try aggregate_type.instanceTypeVal(analyser) orelse return null
    else
        aggregate_type;
    return switch (runtime_type.data) {
        .array => |info| info.elem_ty.*,
        .pointer => |info| switch (info.size) {
            .one => switch (info.elem_ty.data) {
                .array => |array| array.elem_ty.*,
                else => null,
            },
            .many, .slice, .c => info.elem_ty.*,
        },
        .ip_index => |payload| switch (analyser.ip.indexToKey(payload.type)) {
            .array_type => |array| Type.fromIP(analyser, .type_type, array.child),
            .pointer_type => |pointer| switch (pointer.flags.size) {
                .one => switch (analyser.ip.indexToKey(pointer.elem_type)) {
                    .array_type => |array| Type.fromIP(analyser, .type_type, array.child),
                    else => null,
                },
                .many, .slice, .c => Type.fromIP(analyser, .type_type, pointer.elem_type),
            },
            else => null,
        },
        else => null,
    };
}

pub fn resolveAggregateComptimeArgument(
    analyser: *Analyser,
    parameter_type: Type,
    handle: *DocumentStore.Handle,
    argument: Ast.Node.Index,
) Error!?Type {
    const node = unwrapAggregateComptimeArgument(&handle.tree, argument);
    const aggregate_type = if (parameter_type.is_type_val) parameter_type else try parameter_type.typeOf(analyser);
    if (aggregate_type.isUnionType()) {
        var buffer: [2]Ast.Node.Index = undefined;
        const literal = handle.tree.fullStructInit(&buffer, node) orelse return null;
        if (literal.ast.fields.len != 1) return null;
        const field_node = literal.ast.fields[0];
        const field_name = try analyser.identifierTokenName(&handle.tree, handle.tree.firstToken(field_node) - 2) orelse return null;
        const field_decl = try analyser.lookupSymbolContainer(aggregate_type, field_name, .field) orelse return null;
        const field_type = try field_decl.resolveType(analyser) orelse return null;
        const value = try analyser.resolveAggregateComptimeElement(try field_type.typeOf(analyser), handle, field_node) orelse return null;
        const fields = try analyser.arena.alloc(comptime_eval.Value.Field, 1);
        fields[0] = .{ .name = field_name, .value = value };
        return try comptime_eval.Value.create(analyser, aggregate_type, .{ .fields = fields });
    }
    if (aggregate_type.isStructType(analyser)) {
        var buffer: [2]Ast.Node.Index = undefined;
        const literal = handle.tree.fullStructInit(&buffer, node) orelse return null;
        const fields = try analyser.arena.alloc(comptime_eval.Value.Field, literal.ast.fields.len);
        for (literal.ast.fields, fields) |field_node, *field| {
            const field_name = try analyser.identifierTokenName(&handle.tree, handle.tree.firstToken(field_node) - 2) orelse return null;
            const field_decl = try analyser.lookupSymbolContainer(try aggregate_type.instanceUnchecked(analyser), field_name, .field) orelse return null;
            const field_type = try field_decl.resolveType(analyser) orelse return null;
            const expected_type = try field_type.typeOf(analyser);
            field.* = .{
                .name = field_name,
                .value = try analyser.resolveAggregateComptimeElement(expected_type, handle, field_node) orelse return null,
            };
        }
        return try comptime_eval.Value.create(analyser, aggregate_type, .{ .fields = fields });
    }
    const element_type = try analyser.aggregateComptimeElementType(aggregate_type) orelse return null;
    switch (handle.tree.nodeTag(node)) {
        .call, .call_comma, .call_one, .call_one_comma => {
            const value = try comptime_eval.Interpreter.evaluateCall(analyser, handle, node) orelse return null;
            const items = comptime_eval.Value.elements(value) orelse return null;
            return try comptime_eval.Value.create(analyser, aggregate_type, .{ .array = items });
        },
        else => {},
    }
    var buffer: [2]Ast.Node.Index = undefined;
    const elements = switch (handle.tree.nodeTag(node)) {
        .array_init_one,
        .array_init_one_comma,
        .array_init_dot_two,
        .array_init_dot_two_comma,
        .array_init_dot,
        .array_init_dot_comma,
        .array_init,
        .array_init_comma,
        => handle.tree.fullArrayInit(&buffer, node).?.ast.elements,
        .struct_init,
        .struct_init_comma,
        .struct_init_one,
        .struct_init_one_comma,
        => handle.tree.fullStructInit(&buffer, node).?.ast.fields,
        else => return null,
    };
    const values = try analyser.arena.alloc(Type, elements.len);
    for (elements, values) |element, *value| {
        value.* = try analyser.resolveAggregateComptimeElement(element_type, handle, element) orelse
            try comptime_eval.Value.createExpression(analyser, element_type, .of(element, handle));
    }
    return try comptime_eval.Value.create(analyser, aggregate_type, .{ .array = values });
}

fn resolveAggregateComptimeElement(
    analyser: *Analyser,
    expected_type: Type,
    handle: *DocumentStore.Handle,
    node: Ast.Node.Index,
) Error!?Type {
    if (analyser.comptime_interpreter) |interpreter| {
        const evaluated = try interpreter.evaluateExpression(handle, node) orelse return null;
        if (expected_type.ipIndex()) |expected_index| {
            if (evaluated.data == .ip_index) {
                const coerced = try analyser.coerceComptimeIPValue(expected_index, evaluated) orelse return null;
                return Type.fromIP(analyser, expected_index, coerced);
            }
            const source_type = try evaluated.typeOf(analyser);
            if (source_type.ipIndex()) |source_type_index| {
                const source_value = Type.fromIP(analyser, source_type_index, null);
                _ = try analyser.coerceComptimeIPValue(expected_index, source_value) orelse return null;
            }
        }
        return evaluated;
    }
    if (try analyser.resolveAggregateComptimeArgument(expected_type, handle, node)) |value| return value;
    if (expected_type.ipIndex()) |expected_index| {
        if (try analyser.resolveCoercedIPValue(expected_index, .of(node, handle))) |value_index| {
            return Type.fromIP(analyser, expected_index, value_index);
        }
        if (try analyser.resolveTypeOfNodeInternal(.of(node, handle))) |source_value| {
            if (try analyser.coerceComptimeIPValue(expected_index, source_value)) |value_index| {
                return Type.fromIP(analyser, expected_index, value_index);
            }
        }
    }
    return switch (handle.tree.nodeTag(node)) {
        .call, .call_comma, .call_one, .call_one_comma => try comptime_eval.Interpreter.evaluateCall(analyser, handle, node) orelse
            try comptime_eval.Value.createExpression(analyser, expected_type, .of(node, handle)),
        else => analyser.resolveComptimeValue(.of(node, handle)),
    };
}

pub fn resolveComptimeDisplayArgument(
    analyser: *Analyser,
    token_handle: TokenWithHandle,
    node_handle: NodeWithHandle,
) Error!?Type {
    const decl = try analyser.lookupSymbolGlobal(
        token_handle.handle,
        offsets.identifierTokenToNameSlice(&token_handle.handle.tree, token_handle.token),
        token_handle.handle.tree.tokenStart(token_handle.token),
    ) orelse return null;
    const parameter_type = try decl.resolveType(analyser) orelse return null;
    return try analyser.resolveAggregateComptimeArgument(parameter_type, node_handle.handle, node_handle.node) orelse
        try analyser.resolveComptimeValue(.of(node_handle.node, node_handle.handle));
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
    var display_params: TokenToNodeMap = switch (func_info.container_type.data) {
        .container => |info| try info.display_params.clone(analyser.arena),
        else => .empty,
    };
    errdefer display_params.deinit(analyser.arena);

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

        if (param.modifier == .comptime_param and param_type.data != .anytype_parameter) {
            const display_arg = try analyser.displayComptimeArgument(handle, arg) orelse null;
            if (display_arg) |node_handle| {
                const aggregate_node = unwrapAggregateComptimeArgument(&node_handle.handle.tree, node_handle.node);
                switch (node_handle.handle.tree.nodeTag(aggregate_node)) {
                    .array_init_one,
                    .array_init_one_comma,
                    .array_init_dot_two,
                    .array_init_dot_two_comma,
                    .array_init_dot,
                    .array_init_dot_comma,
                    .array_init,
                    .array_init_comma,
                    => if (try analyser.resolveAggregateComptimeArgument(param_type, node_handle.handle, node_handle.node)) |value| {
                        try display_params.put(analyser.arena, parameter_token_handle, node_handle);
                        try value_params.put(analyser.arena, parameter_token_handle, value);
                        has_callsite_bindings = true;
                        continue;
                    },
                    else => {},
                }
            }
        }

        if (param.modifier == .comptime_param and param_type.data != .anytype_parameter) {
            if (try analyser.resolveAggregateComptimeArgument(param_type, handle, arg)) |value| {
                try meta_params.put(analyser.arena, parameter_token_handle, value);
                try value_params.put(analyser.arena, parameter_token_handle, value);
                has_callsite_bindings = true;
                continue;
            }
        }

        if (param.modifier == .comptime_param) {
            const parameter_instance = if (param_type.is_type_val)
                try param_type.instanceTypeVal(analyser) orelse param_type
            else
                param_type;
            const is_error_union = switch (parameter_instance.data) {
                .error_union => true,
                .ip_index => |payload| analyser.ip.zigTypeTag(payload.type) == .error_union,
                else => false,
            };
            if (is_error_union) {
                if (try comptime_eval.Interpreter.evaluateTyped(analyser, handle, arg, param_type)) |value| {
                    try meta_params.put(analyser.arena, parameter_token_handle, value);
                    try value_params.put(analyser.arena, parameter_token_handle, value);
                    has_callsite_bindings = true;
                    continue;
                }
            }
        }

        if (param_type.data != .anytype_parameter and
            param.modifier == .comptime_param and
            param_type.is_type_val and
            (param_type.ipIndex() != null or param_type.isEnumType(analyser)) and
            param_type.ipIndex() != .type_type)
        {
            var bound_value: ?Type = null;
            if (param_type.isEnumType(analyser)) {
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

        if (param.modifier == .comptime_param and param_type.data != .anytype_parameter) {
            if (try analyser.displayComptimeArgument(handle, arg)) |display_arg| {
                try display_params.put(analyser.arena, parameter_token_handle, display_arg);
                has_callsite_bindings = true;
                continue;
            }
        }

        const argument_type = (if (param.modifier == .comptime_param)
            try analyser.resolveComptimeValue(.of(arg, handle)) orelse try analyser.resolveTypeOfNodeInternal(.of(arg, handle))
        else
            try analyser.resolveTypeOfNodeInternal(.of(arg, handle))) orelse continue;
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
            if (argument_type.hasKnownValue(analyser)) {
                const value = if (argument_type.data == .comptime_value and argument_type.data.comptime_value.data == .array)
                    try comptime_eval.Value.create(analyser, param_type, .{ .array = argument_type.data.comptime_value.data.array })
                else
                    argument_type;
                try meta_params.put(analyser.arena, parameter_token_handle, value);
                try value_params.put(analyser.arena, parameter_token_handle, value);
                has_callsite_bindings = true;
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
        const old_display_bindings = analyser.display_bindings;
        analyser.generic_bindings = &value_params;
        analyser.display_bindings = &display_params;
        defer {
            analyser.generic_bindings = old_bindings;
            analyser.display_bindings = old_display_bindings;
        }

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

fn cachedGeneratedContainerType(analyser: *Analyser, options: ResolveOptions) ?Type {
    const bindings = analyser.generic_bindings orelse return null;
    return analyser.generated_container_types.get(.{
        .node = .{
            .node = options.node_handle.node,
            .uri = options.node_handle.handle.uri,
        },
        .container_type = options.container_type,
        .bindings = bindings.*,
        .display_bindings = if (analyser.display_bindings) |display_bindings| display_bindings.* else .empty,
    });
}

fn cacheGeneratedContainerType(
    analyser: *Analyser,
    options: ResolveOptions,
    generated_type: Type,
) error{OutOfMemory}!void {
    const bindings = analyser.generic_bindings orelse return;
    try analyser.generated_container_types.put(analyser.gpa, .{
        .node = .{
            .node = options.node_handle.node,
            .uri = options.node_handle.handle.uri,
        },
        .container_type = options.container_type,
        .bindings = try bindings.clone(analyser.arena),
        .display_bindings = if (analyser.display_bindings) |display_bindings|
            try display_bindings.clone(analyser.arena)
        else
            .empty,
    }, generated_type);
}

pub fn resolveBindingOfNode(analyser: *Analyser, options: ResolveOptions) Error!?Binding {
    const tracy_zone = tracy.trace(@src());
    defer tracy_zone.end();

    return analyser.resolveBindingOfNodeInternal(options);
}

fn resolveBindingOfNodeInternal(analyser: *Analyser, options: ResolveOptions) Error!?Binding {
    const old_bindings = analyser.generic_bindings;
    const old_display_bindings = analyser.display_bindings;
    defer {
        analyser.generic_bindings = old_bindings;
        analyser.display_bindings = old_display_bindings;
    }

    var merged_bindings: TokenToTypeMap = .empty;
    var merged_display_bindings: TokenToNodeMap = .empty;
    if (options.container_type) |*container_type| {
        if (container_type.data == .container) {
            const bindings = &container_type.data.container.bound_params;
            for (bindings.values()) |binding| {
                const is_concrete_type = binding.is_type_val and !binding.hasUnresolvedGenericType();
                if (!is_concrete_type and !binding.hasKnownValue(analyser)) continue;
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
            const display_bindings = &container_type.data.container.display_params;
            if (display_bindings.count() != 0) {
                if (old_display_bindings) |outer_bindings| {
                    merged_display_bindings = try outer_bindings.clone(analyser.arena);
                    for (display_bindings.keys(), display_bindings.values()) |key, bound| {
                        try merged_display_bindings.put(analyser.arena, key, bound);
                    }
                    analyser.display_bindings = &merged_display_bindings;
                } else {
                    analyser.display_bindings = display_bindings;
                }
            }
        }
    }

    if (analyser.comptime_interpreter) |interpreter| {
        if (!interpreter.enterExpression()) return null;
        defer interpreter.leaveExpression();
        return analyser.resolveBindingOfNodeUncached(options);
    }

    // Specializations must not populate caches keyed only by the source node.
    if (analyser.generic_bindings) |bindings| {
        const node_with_uri: NodeWithUri = .{
            .node = options.node_handle.node,
            .uri = options.node_handle.handle.uri,
        };
        const key: GeneratedContainerTypeKey = .{
            .node = node_with_uri,
            .container_type = options.container_type,
            .bindings = bindings.*,
            .display_bindings = if (analyser.display_bindings) |display_bindings| display_bindings.* else .empty,
        };
        const cached = try analyser.resolved_specialized_nodes.getOrPut(analyser.gpa, key);
        if (cached.found_existing) return cached.value_ptr.*;
        cached.key_ptr.bindings = try bindings.clone(analyser.arena);
        cached.key_ptr.display_bindings = if (analyser.display_bindings) |display_bindings|
            try display_bindings.clone(analyser.arena)
        else
            .empty;
        cached.value_ptr.* = null;
        errdefer _ = analyser.resolved_specialized_nodes.remove(key);

        const gop = try analyser.resolving_specialized_nodes.getOrPut(analyser.gpa, node_with_uri);
        if (gop.found_existing) {
            _ = analyser.resolved_specialized_nodes.remove(key);
            return null;
        }
        defer std.debug.assert(analyser.resolving_specialized_nodes.remove(node_with_uri));
        const binding = try analyser.resolveBindingOfNodeUncached(options);
        analyser.resolved_specialized_nodes.getPtr(key).?.* = binding;
        return binding;
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
                    if (decl_type.isEnumType(analyser)) {
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

            // The current call supplies the concrete arguments. Avoid resolving
            // `anytype` parameters by recursively scanning every callsite while
            // constructing the callee prototype; that can recurse back through
            // this call before specialization is applied.
            const ty = blk: {
                const old_collect_callsite_references = analyser.collect_callsite_references;
                analyser.collect_callsite_references = false;
                defer analyser.collect_callsite_references = old_collect_callsite_references;
                break :blk try analyser.resolveTypeOfNodeInternal(.of(call.ast.fn_expr, handle)) orelse return null;
            };
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

                if (std.mem.eql(u8, func_name, "stringToEnum")) {
                    if (call.ast.params.len < 2) return .unknown_type;
                    const enum_type = try analyser.resolveTypeOfNodeInternal(.of(call.ast.params[0], handle)) orelse
                        return .unknown_type;
                    const name = try analyser.resolveStringLiteral(.of(call.ast.params[1], handle)) orelse
                        return .unknown_type;
                    const optional_type = try Type.createOptionalType(analyser, enum_type);
                    const tag = try analyser.resolveEnumTagIntValue(enum_type, name);
                    return try comptime_eval.Value.create(
                        analyser,
                        optional_type,
                        .{ .optional = if (tag != null) try analyser.enumValue(enum_type, name) else null },
                    );
                }

                if (std.mem.eql(u8, func_name, "ArgsTuple")) {
                    if (call.ast.params.len < 1) return .unknown_type;
                    const arg = call.ast.params[0];
                    const arg_ty = try analyser.resolveTypeOfNodeInternal(.of(arg, handle)) orelse return .unknown_type;
                    return try analyser.resolveArgsTupleType(arg_ty) orelse .unknown_type;
                }

                if (std.mem.eql(u8, func_name, "Tag")) {
                    if (call.ast.params.len < 1) return .unknown_type;
                    const arg = call.ast.params[0];
                    const arg_ty = try analyser.resolveTypeOfNodeInternal(.of(arg, handle)) orelse return .unknown_type;
                    if (try analyser.resolveEnumTagType(arg_ty)) |tag_type| return tag_type;
                    const tag_type = try analyser.resolveUnionTag(arg_ty) orelse return .unknown_type;
                    return try tag_type.typeOf(analyser);
                }

                if (std.mem.eql(u8, func_name, "containerLayout")) {
                    if (call.ast.params.len < 1) return .unknown_type;
                    const arg_type = try analyser.resolveTypeOfNodeInternal(.of(call.ast.params[0], handle)) orelse
                        return .unknown_type;
                    const layout = analyser.containerTypeLayout(arg_type) orelse return .unknown_type;
                    const return_type = try func_info.return_value.typeOf(analyser);
                    return try analyser.enumValue(return_type, @tagName(layout));
                }

                if (std.mem.eql(u8, func_name, "alignment")) {
                    if (call.ast.params.len < 1) return .unknown_type;
                    const arg_type = try analyser.resolveTypeOfNodeInternal(.of(call.ast.params[0], handle)) orelse
                        return .unknown_type;
                    const alignment = try analyser.metaAlignment(arg_type) orelse return .unknown_type;
                    return try analyser.comptimeIntValue(alignment);
                }

                if (std.mem.eql(u8, func_name, "FieldEnum")) {
                    if (call.ast.params.len < 1) return .unknown_type;
                    const arg_type = try analyser.resolveTypeOfNodeInternal(.of(call.ast.params[0], handle)) orelse
                        return .unknown_type;
                    return try analyser.resolveFieldEnumType(arg_type) orelse .unknown_type;
                }

                if (std.mem.eql(u8, func_name, "DeclEnum")) {
                    if (call.ast.params.len < 1) return .unknown_type;
                    const arg_type = try analyser.resolveTypeOfNodeInternal(.of(call.ast.params[0], handle)) orelse
                        return .unknown_type;
                    return try analyser.resolveDeclEnumType(arg_type) orelse .unknown_type;
                }

                if (std.mem.eql(u8, func_name, "fieldIndex")) {
                    if (call.ast.params.len < 2) return .unknown_type;
                    const arg_type = try analyser.resolveTypeOfNodeInternal(.of(call.ast.params[0], handle)) orelse
                        return .unknown_type;
                    const field_name = try analyser.resolveStringLiteral(.of(call.ast.params[1], handle)) orelse
                        return .unknown_type;
                    const field_names = try analyser.metaFieldNames(arg_type) orelse return .unknown_type;
                    const index = for (field_names, 0..) |name, field_index| {
                        if (std.mem.eql(u8, name, field_name)) break field_index;
                    } else null;
                    return try analyser.optionalComptimeIntValue(index);
                }

                if (std.mem.eql(u8, func_name, "fields")) {
                    if (call.ast.params.len < 1) return .unknown_type;
                    const arg_type = try analyser.resolveTypeOfNodeInternal(.of(call.ast.params[0], handle)) orelse
                        return .unknown_type;
                    return try analyser.resolveMetaFieldsValue(arg_type, func_info.return_value.*) orelse .unknown_type;
                }

                if (std.mem.eql(u8, func_name, "fieldInfo")) {
                    if (call.ast.params.len < 2) return .unknown_type;
                    const arg_type = try analyser.resolveTypeOfNodeInternal(.of(call.ast.params[0], handle)) orelse
                        return .unknown_type;
                    const field_enum_type = try analyser.resolveFieldEnumType(arg_type) orelse return .unknown_type;
                    const field_name = try analyser.resolveEnumValueTag(
                        field_enum_type,
                        .of(call.ast.params[1], handle),
                    ) orelse return .unknown_type;
                    return try analyser.resolveMetaFieldValue(
                        arg_type,
                        field_name,
                        func_info.return_value.*,
                    ) orelse .unknown_type;
                }

                if (std.mem.eql(u8, func_name, "fieldNames")) {
                    if (call.ast.params.len < 1) return .unknown_type;
                    const arg_type = try analyser.resolveTypeOfNodeInternal(.of(call.ast.params[0], handle)) orelse
                        return .unknown_type;
                    return try analyser.resolveMetaFieldNamesValue(arg_type, func_info.return_value.*) orelse .unknown_type;
                }

                if (std.mem.eql(u8, func_name, "tags")) {
                    if (call.ast.params.len < 1) return .unknown_type;
                    const arg_type = try analyser.resolveTypeOfNodeInternal(.of(call.ast.params[0], handle)) orelse
                        return .unknown_type;
                    return try analyser.resolveMetaTagsValue(arg_type, func_info.return_value.*) orelse .unknown_type;
                }

                if (std.mem.eql(u8, func_name, "declarations")) {
                    if (call.ast.params.len < 1) return .unknown_type;
                    const arg_type = try analyser.resolveTypeOfNodeInternal(.of(call.ast.params[0], handle)) orelse
                        return .unknown_type;
                    return try analyser.resolveMetaDeclarationsValue(arg_type, func_info.return_value.*) orelse .unknown_type;
                }

                if (std.mem.eql(u8, func_name, "declarationInfo")) {
                    if (call.ast.params.len < 2) return .unknown_type;
                    const arg_type = try analyser.resolveTypeOfNodeInternal(.of(call.ast.params[0], handle)) orelse
                        return .unknown_type;
                    const declaration_name = try analyser.resolveStringLiteral(.of(call.ast.params[1], handle)) orelse
                        return .unknown_type;
                    return try analyser.resolveMetaDeclarationValue(
                        arg_type,
                        declaration_name,
                        func_info.return_value.*,
                    ) orelse .unknown_type;
                }
            }

            if (analyser.resolve_number_literal_values and
                analyser.comptime_interpreter == null and
                func_info.handle.tree.nodeTag(func_info.fn_node) == .fn_decl)
            {
                const return_type = try func_info.return_value.typeOf(analyser);
                const body = func_info.handle.tree.nodeData(func_info.fn_node).node_and_node[1];
                const can_evaluate = switch (return_type.comptimeCallEvaluation(analyser)) {
                    .never => false,
                    .eager => true,
                    .if_needed => analyser.evaluate_comptime_control_flow or
                        try analyser.comptimeInterpreterNeeded(func_info.handle, body),
                };
                if (can_evaluate) {
                    if (try comptime_eval.Interpreter.evaluateCall(analyser, handle, node)) |value| return value;
                }
            }
            return func_info.return_value.*;
        },
        .container_field,
        .container_field_init,
        .container_field_align,
        => {
            const container_type = options.container_type orelse try analyser.innermostContainer(handle, tree.tokenStart(tree.firstToken(node)));
            if (container_type.isEnumType(analyser))
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
            if (analyser.evaluate_comptime_values) {
                if (analyser.comptime_interpreter) |interpreter| {
                    return interpreter.evaluateStructInit(handle, lhs, struct_init.ast.fields);
                }
                if (lhs.ipIndex()) |type_index| {
                    if (try analyser.resolveCoercedIPValue(type_index, options)) |value| {
                        return Type.fromIP(analyser, type_index, value);
                    }
                }
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
                if (lhs.data == .comptime_value and lhs.data.comptime_value.data == .error_union) {
                    switch (lhs.data.comptime_value.data.error_union) {
                        .payload => |payload| return payload,
                        .failure => return try analyser.resolveTypeOfNodeInternal(.of(rhs_node, handle)),
                    }
                }
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

            const sentinel = try analyser.resolveOptionalIPValue(ptr_info.ast.sentinel, handle);
            const alignment = if (ptr_info.ast.align_node.unwrap()) |align_node|
                try analyser.resolveIntegerLiteral(u16, .of(align_node, handle)) orelse return null
            else
                0;
            const address_space = if (ptr_info.ast.addrspace_node.unwrap()) |addrspace_node|
                try analyser.resolveAddressSpace(.of(addrspace_node, handle)) orelse return null
            else
                .generic;
            const packed_offset: InternPool.Key.Pointer.PackedOffset = if (ptr_info.ast.bit_range_start.unwrap()) |bit_offset_node| .{
                .bit_offset = try analyser.resolveIntegerLiteral(u16, .of(bit_offset_node, handle)) orelse return null,
                .host_size = try analyser.resolveIntegerLiteral(u16, .of(ptr_info.ast.bit_range_end.unwrap().?, handle)) orelse return null,
            } else .{ .bit_offset = 0, .host_size = 0 };

            const elem_ty = try analyser.resolveTypeOfNodeInternal(.of(ptr_info.ast.child_type, handle)) orelse return null;
            if (!elem_ty.is_type_val) return null;

            return try Type.createPointerTypeWithFlags(analyser, .{
                .size = size,
                .is_const = ptr_info.const_token != null,
                .is_volatile = ptr_info.volatile_token != null,
                .is_allowzero = ptr_info.allowzero_token != null,
                .address_space = address_space,
                .alignment = alignment,
            }, packed_offset, sentinel, elem_ty);
        },
        .array_type,
        .array_type_sentinel,
        => {
            const array_info = tree.fullArrayType(node).?;
            const count_options: ResolveOptions = .{
                .node_handle = .of(array_info.ast.elem_count, handle),
                .container_type = options.container_type,
            };
            const elem_count = if (try analyser.resolveCoercedIPValue(.usize_type, count_options)) |value|
                analyser.ip.toInt(value, u64)
            else
                try analyser.resolveIntegerLiteral(u64, count_options);
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
                    if (analyser.comptime_interpreter) |interpreter| {
                        return interpreter.evaluateArrayInit(handle, array_ty, array_init_info.ast.elements);
                    }
                    if (try analyser.resolveArrayValue(array_ty, array_init_info.ast.elements, handle)) |value| {
                        return value;
                    }
                }
                return try array_ty.instanceTypeVal(analyser);
            }

            const elem_ty_slice = try analyser.arena.alloc(Type, array_init_info.ast.elements.len);
            for (elem_ty_slice, array_init_info.ast.elements) |*elem_ty, element| {
                elem_ty.* = if (analyser.comptime_interpreter) |interpreter|
                    try interpreter.evaluateExpression(handle, element) orelse return null
                else
                    try analyser.resolveTypeOfNodeInternal(.of(element, handle)) orelse return null;
            }
            if (analyser.evaluate_comptime_values) {
                const can_intern = for (elem_ty_slice) |value| {
                    if (value.ipIndex() == null and (value.is_type_val or value.hasKnownValue(analyser))) break false;
                } else true;
                if (can_intern) if (try Type.createTupleValue(analyser, elem_ty_slice)) |tuple| return tuple;
                if (!can_intern) {
                    const types = try analyser.arena.alloc(Type, elem_ty_slice.len);
                    for (types, elem_ty_slice) |*ty, value| ty.* = try value.typeOf(analyser);
                    return try comptime_eval.Value.create(analyser, try Type.createTupleType(analyser, types), .{ .array = elem_ty_slice });
                }
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
                    if (analyser.comptime_interpreter) |interpreter| {
                        return interpreter.evaluateAs(handle, params);
                    }
                    if (params.len < 1) return null;
                    const ty = (try analyser.resolveTypeOfNodeInternal(.of(params[0], handle))) orelse return null;
                    if (analyser.evaluate_comptime_values and params.len >= 2 and ty.isEnumType(analyser)) {
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
                => {
                    if (params.len < 1) return null;
                    const ty = (try analyser.resolveTypeOfNodeInternal(.of(params[0], handle))) orelse return null;
                    return try ty.instanceTypeVal(analyser);
                },
                .union_init => {
                    if (params.len != 3) return null;
                    if (analyser.comptime_interpreter) |interpreter| {
                        return interpreter.evaluateUnionInit(handle, params);
                    }
                    const union_type = try analyser.resolveTypeOfNodeInternal(.of(params[0], handle)) orelse return null;
                    const fallback = try union_type.instanceTypeVal(analyser);
                    if (!analyser.evaluate_comptime_values) return fallback;
                    const field_name = try analyser.resolveStringLiteral(.of(params[1], handle)) orelse
                        return fallback;
                    const field = analyser.resolveComptimeUnionInitField(union_type, field_name) orelse
                        return fallback;
                    const value_options: ResolveOptions = .{
                        .node_handle = .of(params[2], handle),
                        .container_type = options.container_type,
                    };
                    if (try analyser.resolveCoercedIPValue(field.field_type, value_options)) |value| {
                        return try analyser.comptimeUnionInitValue(field, value);
                    }
                    const source_value = try analyser.resolveTypeOfNodeInternal(value_options) orelse
                        return fallback;
                    return analyser.resolveComptimeUnionInitValue(union_type, field_name, source_value);
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
                    return try analyser.resolveComptimeMulAddCoercedValue(result_type, a, b, c) orelse result;
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
                    const kind: ComptimeFloatUnaryKind = switch (tag) {
                        .sin => .sin,
                        .cos => .cos,
                        .tan => .tan,
                        .exp => .exp,
                        .exp2 => .exp2,
                        .log => .log,
                        .log2 => .log2,
                        .log10 => .log10,
                        .sqrt => .sqrt,
                        else => unreachable,
                    };
                    const result = try analyser.resolveComptimeFloatUnaryValue(ty, kind) orelse return null;
                    return if (analyser.evaluate_comptime_values) result else result.withoutIPIndex(analyser);
                },
                .floor,
                .ceil,
                .trunc,
                .round,
                => |tag| {
                    if (params.len != 1) return null;
                    const ty = (try analyser.resolveTypeOfNodeInternal(.of(params[0], handle))) orelse return null;
                    const kind: ComptimeFloatUnaryKind = switch (tag) {
                        .floor => .floor,
                        .ceil => .ceil,
                        .trunc => .trunc,
                        .round => .round,
                        else => unreachable,
                    };
                    const result = try analyser.resolveComptimeFloatUnaryValue(ty, kind) orelse return null;
                    return if (analyser.evaluate_comptime_values) result else result.withoutIPIndex(analyser);
                },
                .abs => {
                    if (params.len != 1) return null;
                    const ty = try analyser.resolveTypeOfNodeInternal(.of(params[0], handle)) orelse return null;
                    const result = try analyser.resolveComptimeAbsValue(ty) orelse return null;
                    return if (analyser.evaluate_comptime_values) result else result.withoutIPIndex(analyser);
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
                .type_info => {
                    if (params.len != 1) return null;
                    const result_type = try analyser.resolveLangrefType(
                        version_data.builtins.get(call_name).?.return_type,
                    ) orelse return null;
                    if (!analyser.evaluate_comptime_values) return result_type;
                    const operand = try analyser.resolveTypeOfNodeInternal(.of(params[0], handle)) orelse return result_type;
                    return try analyser.resolveComptimeTypeInfoValue(operand) orelse result_type;
                },
                .bit_size_of, .size_of => |tag| {
                    if (params.len != 1) return null;
                    if (!analyser.evaluate_comptime_values) {
                        return Type.fromIP(analyser, .comptime_int_type, null);
                    }
                    const ty = try analyser.resolveTypeOfNodeInternal(.of(params[0], handle)) orelse return null;
                    const kind: ComptimeTypeSizeKind = switch (tag) {
                        .bit_size_of => .bit_size,
                        .size_of => .byte_size,
                        else => unreachable,
                    };
                    return try analyser.resolveComptimeTypeSizeValue(ty, kind) orelse
                        Type.fromIP(analyser, .comptime_int_type, null);
                },
                .align_of => {
                    if (params.len != 1) return null;
                    if (!analyser.evaluate_comptime_values) {
                        return Type.fromIP(analyser, .comptime_int_type, null);
                    }
                    const ty = try analyser.resolveTypeOfNodeInternal(.of(params[0], handle)) orelse return null;
                    return try analyser.resolveComptimeTypeSizeValue(ty, .alignment) orelse
                        Type.fromIP(analyser, .comptime_int_type, null);
                },
                .bit_offset_of, .offset_of => |tag| {
                    if (params.len != 2) return null;
                    if (!analyser.evaluate_comptime_values) {
                        return Type.fromIP(analyser, .comptime_int_type, null);
                    }
                    const container_type = try analyser.resolveTypeOfNodeInternal(.of(params[0], handle)) orelse
                        return Type.fromIP(analyser, .comptime_int_type, null);
                    const field_name = try analyser.resolveStringLiteral(.of(params[1], handle)) orelse
                        return Type.fromIP(analyser, .comptime_int_type, null);
                    const kind: ComptimeFieldOffsetKind = if (tag == .bit_offset_of) .bit_offset else .byte_offset;
                    return try analyser.resolveComptimeFieldOffsetValue(container_type, field_name, kind) orelse
                        Type.fromIP(analyser, .comptime_int_type, null);
                },
                .int_from_bool => {
                    if (params.len != 1) return null;
                    const operand = try analyser.resolveTypeOfNodeInternal(.of(params[0], handle)) orelse return null;
                    if (try analyser.resolveComptimeIntFromBoolValue(operand)) |result| {
                        return if (analyser.evaluate_comptime_values) result else result.withoutIPIndex(analyser);
                    }
                    if (!analyser.evaluate_comptime_values) {
                        return Type.fromIP(analyser, .u1_type, null);
                    }
                    return Type.fromIP(analyser, .u1_type, null);
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
                    return analyser.resolveComptimeIntFromEnumValue(operand);
                },
                .tag_name => {
                    if (params.len != 1) return null;
                    const operand = try analyser.resolveTypeOfNodeInternal(.of(params[0], handle)) orelse return null;
                    if (analyser.evaluate_comptime_values)
                        if (try analyser.resolveComptimeTagNameValue(operand)) |value| return value;
                    if (operand.data == .type_info_value)
                        return try analyser.staticStringType(@tagName(operand.data.type_info_value.tag).len);
                    if (operand.data == .enum_value)
                        return try analyser.staticStringType(operand.data.enum_value.tag.len);
                    return analyser.resolveLangrefType(version_data.builtins.get(call_name).?.return_type);
                },
                .error_name => {
                    if (params.len != 1) return null;
                    if (!analyser.evaluate_comptime_values) {
                        return analyser.resolveLangrefType(version_data.builtins.get(call_name).?.return_type);
                    }

                    const operand = try analyser.resolveTypeOfNodeInternal(.of(params[0], handle)) orelse
                        return analyser.resolveLangrefType(version_data.builtins.get(call_name).?.return_type);
                    if (try analyser.resolveComptimeErrorNameValue(operand)) |value| return value;
                    return analyser.resolveLangrefType(version_data.builtins.get(call_name).?.return_type);
                },
                .type_name => {
                    if (params.len != 1) return null;
                    const fallback = try analyser.resolveLangrefType(
                        version_data.builtins.get(call_name).?.return_type,
                    );
                    if (!analyser.evaluate_comptime_values) return fallback;

                    const operand = try analyser.resolveTypeOfNodeInternal(.of(params[0], handle)) orelse return fallback;
                    return try analyser.resolveComptimeTypeNameValue(operand) orelse fallback;
                },
                .src => {
                    if (params.len != 0) return null;
                    if (analyser.evaluate_comptime_values) {
                        if (try analyser.resolveComptimeSourceLocationValue(handle, node)) |value| return value;
                    }
                    return analyser.resolveLangrefType(version_data.builtins.get(call_name).?.return_type);
                },
                .call => {
                    if (params.len != 3) return null;
                    if (analyser.comptime_interpreter == null) {
                        if (try comptime_eval.Interpreter.evaluateValue(analyser, handle, node)) |value| return value;
                    }
                    return null;
                },
                .min, .max => |tag| {
                    if (params.len < 2) return null;
                    const resolved = try analyser.arena.alloc(Type, params.len);
                    for (params, resolved) |param, *value| {
                        value.* = try analyser.resolveTypeOfNodeInternal(.of(param, handle)) orelse return null;
                    }
                    const kind: ComptimeMinMaxKind = switch (tag) {
                        .min => .min,
                        .max => .max,
                        else => unreachable,
                    };
                    const result = try analyser.resolveComptimeMinMaxValue(resolved, kind) orelse return null;
                    return if (analyser.evaluate_comptime_values) result else result.withoutIPIndex(analyser);
                },
                .clz, .ctz, .pop_count => |tag| {
                    if (params.len != 1) return null;
                    const operand = try analyser.resolveTypeOfNodeInternal(.of(params[0], handle)) orelse return null;
                    if (operand.is_type_val) return null;
                    if (analyser.evaluate_comptime_values) {
                        const kind: ComptimeBitCountKind = switch (tag) {
                            .clz => .clz,
                            .ctz => .ctz,
                            .pop_count => .pop_count,
                            else => unreachable,
                        };
                        if (try analyser.resolveComptimeBitCountValue(operand, kind)) |value| return value;
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
                        const kind: ComptimeBitPermutationKind = switch (tag) {
                            .bit_reverse => .bit_reverse,
                            .byte_swap => .byte_swap,
                            else => unreachable,
                        };
                        if (try analyser.resolveComptimeBitPermutationValue(operand, kind)) |value| return value;
                    }
                    return operand.withoutIPIndex(analyser);
                },
                .div_trunc, .div_floor, .div_exact, .mod, .rem => |tag| {
                    if (params.len != 2) return null;
                    var lhs = try analyser.resolveTypeOfNodeInternal(.of(params[0], handle)) orelse return null;
                    var rhs = try analyser.resolveTypeOfNodeInternal(.of(params[1], handle)) orelse return null;
                    if (lhs.is_type_val or rhs.is_type_val) return null;
                    if (analyser.evaluate_comptime_values) {
                        const kind: ComptimeDivisionKind = switch (tag) {
                            .div_trunc => .div_trunc,
                            .div_floor => .div_floor,
                            .div_exact => .div_exact,
                            .mod => .mod,
                            .rem => .rem,
                            else => unreachable,
                        };
                        if (try analyser.resolveComptimeDivisionValue(lhs, rhs, kind)) |value| return value;
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
                            const kind: ComptimeExactShiftKind = if (tag == .shl_exact) .shl_exact else .shr_exact;
                            if (try analyser.resolveComptimeExactShiftValue(operand, shift_operand, kind)) |value| return value;
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
                    const kind: ComptimeOverflowKind = switch (tag) {
                        .add_with_overflow => .add,
                        .sub_with_overflow => .sub,
                        .mul_with_overflow => .mul,
                        .shl_with_overflow => .shl,
                        else => unreachable,
                    };
                    const overflow_options = try analyser.resolveComptimeOverflowOptions(
                        tree,
                        params[0],
                        params[1],
                        kind,
                        analyser.evaluate_comptime_values,
                    );
                    return analyser.resolveComptimeOverflowValue(lhs, rhs, kind, overflow_options);
                },
                .reduce => {
                    if (params.len != 2) return null;
                    const operand = try analyser.resolveTypeOfNodeInternal(.of(params[1], handle)) orelse return null;
                    const operand_type = (try operand.typeOf(analyser)).ipIndex() orelse return null;
                    const vector = switch (analyser.ip.indexToKey(operand_type)) {
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
                    const predicate = try analyser.resolveTypeOfNodeInternal(.of(params[1], handle)) orelse return null;
                    const lhs = try analyser.resolveTypeOfNodeInternal(.of(params[2], handle)) orelse return null;
                    const rhs = try analyser.resolveTypeOfNodeInternal(.of(params[3], handle)) orelse return null;
                    if (analyser.evaluate_comptime_values) {
                        if (try analyser.resolveComptimeSelectValue(element, predicate, lhs, rhs)) |value| return value;
                    }
                    return analyser.resolveComptimeSelectValue(
                        element,
                        predicate.withoutIPIndex(analyser),
                        lhs.withoutIPIndex(analyser),
                        rhs.withoutIPIndex(analyser),
                    );
                },
                .shuffle => {
                    if (params.len != 4) return null;
                    const element = try analyser.resolveTypeOfNodeInternal(.of(params[0], handle)) orelse return null;
                    const lhs = try analyser.resolveTypeOfNodeInternal(.of(params[1], handle)) orelse return null;
                    const rhs = try analyser.resolveTypeOfNodeInternal(.of(params[2], handle)) orelse return null;
                    const mask = try analyser.resolveTypeOfNodeInternal(.of(params[3], handle)) orelse return null;
                    if (analyser.evaluate_comptime_values) {
                        if (try analyser.resolveComptimeShuffleValue(element, lhs, rhs, mask)) |value| return value;
                    }
                    return analyser.resolveComptimeShuffleValue(
                        element,
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
                    const kind: ComptimeMemberKind = switch (tag) {
                        .has_field => .field,
                        .has_decl => .declaration,
                        else => unreachable,
                    };
                    return try analyser.resolveComptimeMemberPresenceValue(container_type, name, kind) orelse
                        Type.fromIP(analyser, .bool_type, null);
                },
                .import => {
                    if (params.len == 0) return null;
                    const import_param = params[0];
                    if (tree.nodeTag(import_param) != .string_literal) return null;

                    const string_literal = tree.tokenSlice(tree.nodeMainToken(import_param));
                    const import_string = string_literal[1 .. string_literal.len - 1];
                    return analyser.resolveComptimeImportValue(handle, import_string);
                },
                .embed_file => {
                    if (params.len != 1) return null;
                    if (analyser.evaluate_comptime_values) {
                        const path = try analyser.resolveTypeOfNodeInternal(.of(params[0], handle)) orelse return null;
                        if (path.data == .string_value) {
                            if (try analyser.resolveComptimeEmbedFileValue(handle, path.data.string_value.bytes)) |value| {
                                return value;
                            }
                        }
                    }
                    return analyser.resolveLangrefType(version_data.builtins.get(call_name).?.return_type);
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
                    const field_name = try analyser.resolveStringLiteral(.of(params[1], handle)) orelse return null;
                    return analyser.resolveComptimeFieldTypeValue(container_type, field_name);
                },
                .field => {
                    if (params.len < 2) return null;

                    const lhs = (try analyser.resolveTypeOfNodeInternal(.of(params[0], handle))) orelse return null;

                    const field_name = try analyser.resolveStringLiteral(.of(params[1], handle)) orelse return null;
                    if (analyser.evaluate_comptime_values) {
                        if (try analyser.resolveComptimeFieldValue(lhs, field_name)) |value| return value;
                    }
                    return analyser.resolveFieldAccess(lhs, field_name);
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
                    const sentinel_value = try analyser.resolveComptimeValue(.{
                        .node_handle = .of(params[3], handle),
                        .container_type = options.container_type,
                    }) orelse return .unknown_type;
                    const sentinel = if (sentinel_value.ipIndex()) |index|
                        if (analyser.ip.isNull(index))
                            InternPool.Index.none
                        else sentinel: {
                            const child_type = child.ipIndex() orelse return .unknown_type;
                            break :sentinel try analyser.coerceIP(child_type, index) orelse return .unknown_type;
                        }
                    else
                        return .unknown_type;
                    if (sentinel != .none and (size == .one or size == .c)) return .unknown_type;
                    return try Type.createPointerTypeWithFlags(
                        analyser,
                        flags,
                        .{ .bit_offset = 0, .host_size = 0 },
                        sentinel,
                        child,
                    );
                },
                .Fn => {
                    if (params.len != 4) return .unknown_type;
                    const parameter_tuple = try analyser.resolveTupleTypeConstructor(.{
                        .node_handle = .of(params[0], handle),
                        .container_type = options.container_type,
                    }) orelse return .unknown_type;
                    const parameter_types: []const Type = switch (parameter_tuple.data) {
                        .tuple => |types| types,
                        .ip_index => |payload| switch (analyser.ip.indexToKey(payload.index orelse return .unknown_type)) {
                            .tuple_type => |tuple| types: {
                                const types = try analyser.arena.alloc(Type, tuple.types.len);
                                for (types, 0..) |*parameter_type, index| {
                                    parameter_type.* = Type.fromIP(
                                        analyser,
                                        .type_type,
                                        tuple.types.at(@intCast(index), analyser.ip),
                                    );
                                }
                                break :types types;
                            },
                            else => return .unknown_type,
                        },
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
                    const flags = try analyser.resolveFnAttributes(.{
                        .node_handle = .of(params[3], handle),
                        .container_type = options.container_type,
                    }) orelse return .unknown_type;

                    const parameter_indices = try analyser.gpa.alloc(InternPool.Index, parameter_types.len);
                    defer analyser.gpa.free(parameter_indices);
                    const can_intern = for (parameter_types, parameter_indices) |parameter_type, *parameter_index| {
                        parameter_index.* = parameter_type.ipIndex() orelse break false;
                    } else true;
                    if (can_intern) {
                        if (return_type.ipIndex()) |return_type_index| {
                            const function_type = try analyser.ip.get(.{ .function_type = .{
                                .args = try analyser.ip.getIndexSlice(parameter_indices),
                                .args_is_noalias = noalias_bits,
                                .return_type = return_type_index,
                                .flags = flags,
                            } });
                            return Type.fromIP(analyser, .type_type, function_type);
                        }
                    }

                    const function_parameters = try analyser.arena.alloc(Type.Data.Parameter, parameter_types.len);
                    for (function_parameters, parameter_types, 0..) |*parameter, parameter_type, index| {
                        parameter.* = .{
                            .doc_comments = null,
                            .modifier = if (noalias_bits.isSet(index)) .noalias_param else null,
                            .name = null,
                            .name_token = null,
                            .type = parameter_type,
                        };
                    }
                    const enclosing_type = options.container_type orelse
                        try analyser.innermostContainer(handle, tree.tokenStart(tree.nodeMainToken(node)));
                    return .{ .data = .{ .function = .{
                        .fn_node = node,
                        .fn_token = tree.nodeMainToken(node),
                        .handle = handle,
                        .container_type = try analyser.allocType(enclosing_type),
                        .doc_comments = null,
                        .name = null,
                        .parameters = function_parameters,
                        .has_varargs = flags.is_var_args,
                        .calling_convention = flags.calling_convention,
                        .return_value = try analyser.allocType(try return_type.instanceUnchecked(analyser)),
                    } }, .is_type_val = true };
                },
                .Struct, .Union, .Enum => |tag| {
                    if (analyser.cachedGeneratedContainerType(options)) |generated_type| return generated_type;
                    const generated_type = switch (tag) {
                        .Struct => try analyser.resolveStructTypeConstructor(
                            params,
                            handle,
                            options.container_type,
                        ),
                        .Union => try analyser.resolveUnionTypeConstructor(
                            params,
                            handle,
                            options.container_type,
                        ),
                        .Enum => try analyser.resolveEnumTypeConstructor(
                            params,
                            handle,
                            options.container_type,
                        ),
                        else => unreachable,
                    } orelse return .unknown_type;
                    try analyser.cacheGeneratedContainerType(options, generated_type);
                    return generated_type;
                },
                .Vector => {
                    if (params.len != 2) return null;

                    const child_ty = try analyser.resolveTypeOfNodeInternal(.of(params[1], handle)) orelse return null;
                    const len = try analyser.resolveIntegerLiteral(u32, .of(params[0], handle)) orelse
                        return null; // `InternPool.Key.Vector.len` can't represent unknown length yet
                    return analyser.resolveComptimeVectorType(len, child_ty);
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
            const calling_convention = if (fn_proto.ast.callconv_expr.unwrap()) |callconv_expr|
                try analyser.resolveCallingConventionTag(.of(callconv_expr, handle))
            else if (fn_proto.extern_export_inline_token) |token| switch (tree.tokenTag(token)) {
                .keyword_extern, .keyword_export => target: {
                    const convention = builtin.target.cCallingConvention() orelse break :target null;
                    break :target @as(std.builtin.CallingConvention.Tag, convention);
                },
                .keyword_inline => .@"inline",
                else => .auto,
            } else .auto;

            const info: Type.Data.Function = .{
                .fn_node = node,
                .handle = handle,
                .fn_token = fn_proto.ast.fn_token,
                .container_type = try analyser.allocType(container_type),
                .doc_comments = doc_comments,
                .name = name,
                .parameters = parameters.items,
                .has_varargs = has_varargs,
                .calling_convention = calling_convention,
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
                        const reflexive = operand_type.isEnumType(analyser) or
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
                    if (lhs_ty.data == .type_info_value and !lhs_ty.data.type_info_value.is_payload and tree.nodeTag(rhs) == .enum_literal) {
                        const name = try analyser.identifierTokenName(tree, tree.nodeMainToken(rhs)) orelse return null;
                        const equal = std.mem.eql(u8, @tagName(lhs_ty.data.type_info_value.tag), name);
                        return Type.fromIP(analyser, .bool_type, if (equal == (tree.nodeTag(node) == .equal_equal)) .bool_true else .bool_false);
                    }
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
                if (analyser.comptime_interpreter == null and
                    lhs_ty.pointerSize(analyser) != null and
                    rhs_ty.pointerSize(analyser) != null)
                {
                    const destination = Type.fromIP(analyser, .type_type, .bool_type);
                    if (try comptime_eval.Interpreter.evaluateTyped(analyser, handle, node, destination)) |value| return value;
                }
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
                const binary_options = try analyser.resolveComptimeBinaryOptions(tree, lhs, rhs, tag, true);
                const value = try analyser.resolveComptimeBinaryValue(tag, lhs_ty, rhs_ty, binary_options);
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
                const binary_options = try analyser.resolveComptimeBinaryOptions(tree, lhs, rhs, .add, true);
                if (try analyser.resolveComptimeBinaryValue(.add, lhs_ty, rhs_ty, binary_options)) |value| return value;
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
                const binary_options = try analyser.resolveComptimeBinaryOptions(tree, lhs, rhs, .sub, true);
                if (try analyser.resolveComptimeBinaryValue(.sub, lhs_ty, rhs_ty, binary_options)) |value| return value;
                if (analyser.comptime_interpreter == null and
                    lhs_ty.pointerSize(analyser) != null and
                    rhs_ty.pointerSize(analyser) != null)
                {
                    const destination = Type.fromIP(analyser, .type_type, .usize_type);
                    if (try comptime_eval.Interpreter.evaluateTyped(analyser, handle, node, destination)) |value| return value;
                }
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
                    const value = try analyser.resolveComptimeBinaryValue(tag, lhs_ty, rhs_ty, .{});
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
            if (analyser.evaluate_comptime_values)
                return analyser.resolveComptimeArrayMultValue(elem_ty, mult_lit);
            return analyser.resolveArrayMultExpression(elem_ty, mult_lit);
        },
        .array_cat => {
            const l_elem_idx, const r_elem_idx = tree.nodeData(node).node_and_node;

            const l_elem_ty = try analyser.resolveTypeOfNodeInternal(.of(l_elem_idx, handle)) orelse return null;
            if (l_elem_ty.is_type_val) return null;

            const r_elem_ty = try analyser.resolveTypeOfNodeInternal(.of(r_elem_idx, handle)) orelse return null;
            if (r_elem_ty.is_type_val) return null;

            if (analyser.evaluate_comptime_values)
                return analyser.resolveComptimeArrayCatValue(l_elem_ty, r_elem_ty);
            return analyser.resolveArrayCatExpression(l_elem_ty, r_elem_ty);
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
        => {
            if (!analyser.evaluate_comptime_values) return null;
            var buffer: [2]Ast.Node.Index = undefined;
            const literal = tree.fullStructInit(&buffer, node).?;
            const fields = try analyser.arena.alloc(comptime_eval.Value.Field, literal.ast.fields.len);
            var has_type_value = false;
            for (literal.ast.fields, fields) |field_node, *field| {
                field.* = .{
                    .name = try analyser.identifierTokenName(tree, tree.firstToken(field_node) - 2) orelse return null,
                    .value = if (analyser.comptime_interpreter) |interpreter|
                        try interpreter.evaluateExpression(handle, field_node) orelse .unknown_type
                    else
                        try analyser.resolveTypeOfNodeInternal(.of(field_node, handle)) orelse .unknown_type,
                };
                has_type_value = has_type_value or field.value.is_type_val;
            }
            // Outside the interpreter, ordinary result-location struct literals
            // are resolved from their expected type. Only synthesize an
            // anonymous comptime value here when the literal itself carries a
            // type value, as in a generic configuration tuple.
            if (analyser.comptime_interpreter == null and !has_type_value) return null;
            var ip_fields: std.array_hash_map.Auto(InternPool.String, InternPool.Struct.Field) = .empty;
            errdefer ip_fields.deinit(analyser.gpa);
            const generated_fields = try analyser.arena.alloc(GeneratedField, fields.len);
            for (fields, generated_fields) |field, *generated| {
                const ty = try field.value.typeOf(analyser);
                generated.* = .{ .name = field.name, .ty = ty };
                const name = try analyser.ip.string_pool.getOrPutString(analyser.store.io, analyser.gpa, field.name);
                try ip_fields.put(analyser.gpa, name, .{ .ty = ty.ipIndex() orelse .unknown_type });
            }
            const struct_index = try analyser.ip.createStruct(.{
                .fields = ip_fields,
                .owner_decl = .none,
                .namespace = .none,
                .layout = .auto,
                .backing_int_ty = .none,
                .status = .fully_resolved,
            });
            ip_fields = .empty;
            const type_index = try analyser.ip.get(.{ .struct_type = struct_index });
            try analyser.generated_struct_fields.put(analyser.gpa, type_index, generated_fields);
            return try comptime_eval.Value.create(analyser, Type.fromIP(analyser, .type_type, type_index), .{ .fields = fields });
        },

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

            if (analyser.comptime_interpreter) |interpreter| {
                if (try interpreter.read(handle, node)) |value| return .{ .type = value, .is_const = false };
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

            if (analyser.comptime_interpreter) |interpreter| {
                if (try interpreter.address(handle, expr_node)) |value| return .{ .type = value, .is_const = true };
            }
            const base_binding = try analyser.resolveBindingOfNodeInternal(.of(expr_node, handle)) orelse return null;
            const result_type = try analyser.resolveAddressOf(base_binding.is_const, base_binding.type);
            if (comptime_eval.Value.elements(base_binding.type)) |items| return .{
                .type = try comptime_eval.Value.create(analyser, try result_type.typeOf(analyser), .{ .array = items }),
                .is_const = true,
            };
            return .{
                .type = result_type,
                .is_const = true,
            };
        },

        .field_access => {
            const lhs_node, const field_name = tree.nodeData(node_handle.node).node_and_token;

            var lhs = (try analyser.resolveBindingOfNodeInternal(.of(lhs_node, handle))) orelse return null;

            const symbol = try analyser.identifierTokenName(tree, field_name) orelse return null;
            if (analyser.evaluate_comptime_values and
                (std.mem.eql(u8, symbol, "len") or std.mem.eql(u8, symbol, "ptr")) and
                lhs.type.pointerSize(analyser) == .slice)
            {
                if (try analyser.resolveStaticConstValue(.{
                    .node_handle = .of(lhs_node, handle),
                    .container_type = options.container_type,
                }, lhs.type)) |value| lhs.type = value;
            }
            if (analyser.evaluate_comptime_values and
                lhs.type.is_type_val and
                lhs.type.isEnumType(analyser))
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

            var lhs = try analyser.resolveBindingOfNodeInternal(.of(lhs_node, handle)) orelse return null;
            if (analyser.evaluate_comptime_values and lhs.type.pointerSize(analyser) == .slice) {
                if (try analyser.resolveStaticConstValue(.{
                    .node_handle = .of(lhs_node, handle),
                    .container_type = options.container_type,
                }, lhs.type)) |value| lhs.type = value;
            }

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

    const TypeInfoValue = struct {
        value_type: *Type,
        reflected_type: *Type,
        tag: std.builtin.TypeId,
        is_payload: bool,
        collection: ?Collection,
        optional_type_payload: ?*Type = null,

        const Collection = struct {
            kind: TypeInfoCollectionKind,
            len: u64,
            index: ?u32,
            is_optional: bool = false,
        };
    };

    const TypeInfoCollectionKind = enum {
        struct_fields,
        union_fields,
        enum_fields,
        fn_params,
        error_set_errors,
        container_decls,
        field_names,
        tags,
    };

    const Pointer = struct {
        size: std.builtin.Type.Pointer.Size,
        /// `.none` means no sentinel, `.unknown_unknown` means unknown sentinel
        sentinel: InternPool.Index,
        is_const: bool,
        is_volatile: bool = false,
        is_allowzero: bool = false,
        address_space: std.builtin.AddressSpace = .generic,
        alignment: u16 = 0,
        packed_offset: InternPool.Key.Pointer.PackedOffset = .{ .bit_offset = 0, .host_size = 0 },
        elem_ty: *Type,
    };

    const Vector = struct {
        len: u32,
        elem_ty: *Type,
    };

    pub const Data = union(enum) {
        /// - `*const T`
        /// - `[*]T`
        /// - `[]const T`
        /// - `[*c]T`
        pointer: Pointer,

        /// `[elem_count :sentinel]elem_ty`
        array: struct {
            elem_count: ?u64,
            /// `.none` means no sentinel, `.unknown_unknown` means unknown sentinel
            sentinel: InternPool.Index,
            elem_ty: *Type,
        },

        /// `@Vector(len, elem_ty)`
        vector: Vector,

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

        /// A comptime-known enum value.
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

        /// A comptime-known `std.builtin.Type` value.
        type_info_value: TypeInfoValue,
        comptime_value: *const comptime_eval.Value,

        /// Primitive type: `u8`, `bool`, `type`, etc.
        /// Primitive value: `true`, `false`, `null`, `undefined`
        ip_index: struct {
            type: InternPool.Index,
            index: ?InternPool.Index,
        },

        pub const Container = struct {
            scope_handle: ScopeWithHandle,
            bound_params: TokenToTypeMap,
            /// Comptime arguments retained only for type presentation. These
            /// values are intentionally excluded from semantic substitution
            /// and container identity.
            display_params: TokenToNodeMap = .empty,

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
            calling_convention: ?std.builtin.CallingConvention.Tag,
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
            return createPointerWithFlags(analyser, .{
                .size = size,
                .is_const = is_const,
            }, .{ .bit_offset = 0, .host_size = 0 }, sentinel, elem_ty);
        }

        fn createPointerWithFlags(
            analyser: *Analyser,
            flags: InternPool.Key.Pointer.Flags,
            packed_offset: InternPool.Key.Pointer.PackedOffset,
            sentinel: InternPool.Index,
            elem_ty: Type,
        ) !Data {
            std.debug.assert(elem_ty.is_type_val);
            blk: {
                const elem_type = elem_ty.ipIndex() orelse break :blk;
                const index = try analyser.ip.get(.{
                    .pointer_type = .{
                        .elem_type = elem_type,
                        .sentinel = try analyser.coerceIP(elem_type, sentinel) orelse break :blk,
                        .flags = flags,
                        .packed_offset = packed_offset,
                    },
                });
                return .{ .ip_index = .{ .type = .type_type, .index = index } };
            }
            return .{
                .pointer = .{
                    .size = flags.size,
                    .sentinel = sentinel,
                    .is_const = flags.is_const,
                    .is_volatile = flags.is_volatile,
                    .is_allowzero = flags.is_allowzero,
                    .address_space = flags.address_space,
                    .alignment = flags.alignment,
                    .packed_offset = packed_offset,
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

        fn createVector(analyser: *Analyser, len: u32, elem_ty: Type) !Data {
            std.debug.assert(elem_ty.is_type_val);
            if (elem_ty.ipIndex()) |child| {
                const index = try analyser.ip.get(.{ .vector_type = .{
                    .len = len,
                    .child = child,
                } });
                return .{ .ip_index = .{ .type = .type_type, .index = index } };
            }
            return .{ .vector = .{
                .len = len,
                .elem_ty = try analyser.allocType(elem_ty),
            } };
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
                    std.hash.autoHash(hasher, info.is_volatile);
                    std.hash.autoHash(hasher, info.is_allowzero);
                    std.hash.autoHash(hasher, info.address_space);
                    std.hash.autoHash(hasher, info.alignment);
                    std.hash.autoHash(hasher, info.packed_offset);
                    info.elem_ty.hashWithHasher(hasher);
                },
                .array => |info| {
                    std.hash.autoHash(hasher, info.elem_count);
                    std.hash.autoHash(hasher, info.sentinel);
                    info.elem_ty.hashWithHasher(hasher);
                },
                .vector => |info| {
                    std.hash.autoHash(hasher, info.len);
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
                    if (info.name != null) {
                        std.hash.autoHash(hasher, info.fn_node);
                        std.hash.autoHash(hasher, info.fn_token);
                        hasher.update(info.handle.uri.raw);
                        info.container_type.hashWithHasher(hasher);
                    }
                    for (info.parameters) |param| {
                        std.hash.autoHash(hasher, param.modifier);
                        param.type.hashWithHasher(hasher);
                    }
                    std.hash.autoHash(hasher, info.has_varargs);
                    std.hash.autoHash(hasher, info.calling_convention);
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
                .comptime_value => |value| value.hash(hasher),
                .type_info_value => |value| {
                    value.value_type.hashWithHasher(hasher);
                    value.reflected_type.hashWithHasher(hasher);
                    std.hash.autoHash(hasher, value.tag);
                    std.hash.autoHash(hasher, value.is_payload);
                    std.hash.autoHash(hasher, value.collection);
                    if (value.optional_type_payload) |payload| payload.hashWithHasher(hasher);
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
                    if (a_type.is_const != b_type.is_const) return false;
                    if (a_type.is_volatile != b_type.is_volatile) return false;
                    if (a_type.is_allowzero != b_type.is_allowzero) return false;
                    if (a_type.address_space != b_type.address_space) return false;
                    if (a_type.alignment != b_type.alignment) return false;
                    if (!std.meta.eql(a_type.packed_offset, b_type.packed_offset)) return false;
                    if (!a_type.elem_ty.eql(b_type.elem_ty.*)) return false;
                },
                .array => |a_type| {
                    const b_type = b.array;
                    if (!std.meta.eql(a_type.elem_count, b_type.elem_count)) return false;
                    if (a_type.sentinel != b_type.sentinel) return false;
                    if (!a_type.elem_ty.eql(b_type.elem_ty.*)) return false;
                },
                .vector => |a_type| {
                    const b_type = b.vector;
                    if (a_type.len != b_type.len) return false;
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
                    if ((a_info.name == null) != (b_info.name == null)) return false;
                    if (a_info.name != null) {
                        if (a_info.fn_node != b_info.fn_node) return false;
                        if (a_info.fn_token != b_info.fn_token) return false;
                        if (!a_info.handle.uri.eql(b_info.handle.uri)) return false;
                        if (!a_info.container_type.eql(b_info.container_type.*)) return false;
                    }
                    if (a_info.parameters.len != b_info.parameters.len) return false;
                    for (a_info.parameters, b_info.parameters) |a_param, b_param| {
                        if (a_param.modifier != b_param.modifier) return false;
                        if (!a_param.type.eql(b_param.type)) return false;
                    }
                    if (a_info.has_varargs != b_info.has_varargs) return false;
                    if (a_info.calling_convention != b_info.calling_convention) return false;
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
                .comptime_value => |value| return value.eql(b.comptime_value),
                .type_info_value => |a_value| {
                    const b_value = b.type_info_value;
                    if (!a_value.value_type.eql(b_value.value_type.*)) return false;
                    if (!a_value.reflected_type.eql(b_value.reflected_type.*)) return false;
                    if (a_value.tag != b_value.tag) return false;
                    if (a_value.is_payload != b_value.is_payload) return false;
                    if (!std.meta.eql(a_value.collection, b_value.collection)) return false;
                    if ((a_value.optional_type_payload == null) != (b_value.optional_type_payload == null)) return false;
                    if (a_value.optional_type_payload) |a_payload| {
                        if (!a_payload.eql(b_value.optional_type_payload.?.*)) return false;
                    }
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
                .vector => |info| info.elem_ty.data.isGeneric(),
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
                .type_info_value, .comptime_value => false,
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
                .type_info_value,
                .comptime_value,
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
                    const elem_ty = try analyser.resolveGenericTypeInternal(info.elem_ty.*, bound_params, visiting);
                    return try createPointerWithFlags(analyser, .{
                        .size = info.size,
                        .is_const = info.is_const,
                        .is_volatile = info.is_volatile,
                        .is_allowzero = info.is_allowzero,
                        .address_space = info.address_space,
                        .alignment = info.alignment,
                    }, info.packed_offset, info.sentinel, elem_ty);
                },
                .array => |info| {
                    const elem_count = info.elem_count;
                    const sentinel = info.sentinel;
                    const elem_ty = try analyser.resolveGenericTypeInternal(info.elem_ty.*, bound_params, visiting);
                    return try createArray(analyser, elem_count, sentinel, elem_ty);
                },
                .vector => |info| {
                    const elem_ty = try analyser.resolveGenericTypeInternal(info.elem_ty.*, bound_params, visiting);
                    return try createVector(analyser, info.len, elem_ty);
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
                        .display_params = info.display_params,
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
                        .calling_convention = info.calling_convention,
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

    fn createPointerTypeWithFlags(
        analyser: *Analyser,
        flags: InternPool.Key.Pointer.Flags,
        packed_offset: InternPool.Key.Pointer.PackedOffset,
        sentinel: InternPool.Index,
        elem_ty: Type,
    ) !Type {
        return .{
            .data = try Data.createPointerWithFlags(analyser, flags, packed_offset, sentinel, elem_ty),
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
            .enum_value, .string_value, .type_info_value, .comptime_value => true,
            .ip_index => |payload| if (payload.index) |index|
                !analyser.ip.isUndefined(index) and !analyser.ip.isUnknown(index)
            else switch (analyser.ip.indexToKey(payload.type)) {
                .tuple_type => |tuple| for (0..tuple.values.len) |index| {
                    const value = tuple.values.at(@intCast(index), analyser.ip);
                    if (value == .none or analyser.ip.isUndefined(value) or analyser.ip.isUnknown(value)) break false;
                } else true,
                else => false,
            },
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
            .type_info_value => |value| value.value_type.*,
            .comptime_value => |value| blk: {
                var ty = value.ty;
                ty.is_type_val = false;
                break :blk ty;
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
            .vector => |info| info.elem_ty.isConditional(),
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
            .type_info_value,
            .comptime_value,
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
            .type_info_value,
            .comptime_value,
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
            inline .pointer, .array, .vector => |info, tag| {
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
        if (self.data == .type_info_value) {
            return self.data.type_info_value.value_type.typeOf(analyser);
        }
        if (self.data == .comptime_value) return self.data.comptime_value.ty;

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

    pub fn runtimeTypeValue(self: Type, analyser: *Analyser) Type {
        return self.runtimeType(analyser);
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

    fn hasUnresolvedGenericType(self: Type) bool {
        return switch (self.data) {
            .type_parameter, .anytype_parameter => true,
            .pointer => |info| info.elem_ty.hasUnresolvedGenericType(),
            .array => |info| info.elem_ty.hasUnresolvedGenericType(),
            .vector => |info| info.elem_ty.hasUnresolvedGenericType(),
            .tuple => |types| for (types) |ty| {
                if (ty.hasUnresolvedGenericType()) break true;
            } else false,
            .optional, .union_tag => |ty| ty.hasUnresolvedGenericType(),
            .error_union => |info| info.payload.hasUnresolvedGenericType() or
                if (info.error_set) |error_set| error_set.hasUnresolvedGenericType() else false,
            .container => |info| for (info.bound_params.values()) |ty| {
                if (ty.hasUnresolvedGenericType()) break true;
            } else false,
            .function => |info| {
                if (info.container_type.hasUnresolvedGenericType() or
                    info.return_value.hasUnresolvedGenericType()) return true;
                for (info.parameters) |parameter| {
                    if (parameter.type.hasUnresolvedGenericType()) return true;
                }
                return false;
            },
            .either => |entries| for (entries) |entry| {
                const ty: Type = .{ .data = entry.type_data, .is_type_val = self.is_type_val };
                if (ty.hasUnresolvedGenericType()) break true;
            } else false,
            .enum_value => |value| value.enum_type.hasUnresolvedGenericType(),
            .string_value => |value| value.string_type.hasUnresolvedGenericType(),
            .compile_error, .type_info_value, .comptime_value, .ip_index => false,
        };
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

    pub fn isTupleType(self: Type, analyser: *Analyser) bool {
        if (!self.is_type_val) return false;
        return switch (self.data) {
            .tuple => true,
            .ip_index => |payload| if (payload.index) |index|
                analyser.ip.indexToKey(index) == .tuple_type
            else
                false,
            else => false,
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

    pub fn isEnumType(self: Type, analyser: *Analyser) bool {
        return switch (self.data) {
            .union_tag => true,
            .ip_index => |payload| self.is_type_val and
                if (payload.index) |index|
                    analyser.ip.zigTypeTag(index) == .@"enum"
                else
                    false,
            else => self.isContainerKind(.keyword_enum),
        };
    }

    fn isInternPoolEnumType(self: Type, analyser: *Analyser) bool {
        if (!self.is_type_val) return false;
        const payload = switch (self.data) {
            .ip_index => |payload| payload,
            else => return false,
        };
        const index = payload.index orelse return false;
        return analyser.ip.zigTypeTag(index) == .@"enum";
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

    pub fn pointerSize(self: Type, analyser: *Analyser) ?std.builtin.Type.Pointer.Size {
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

    pub fn isConstSequencePointerType(self: Type, analyser: *Analyser) bool {
        const info = self.typePointerInfo(analyser) orelse return false;
        if (!info.is_const) return false;
        return switch (info.size) {
            .slice, .many => true,
            .one => info.elem_ty.isTupleType(analyser) or switch (info.elem_ty.data) {
                .array => true,
                .ip_index => |payload| analyser.ip.indexToKey(payload.index orelse return false) == .array_type,
                else => false,
            },
            .c => false,
        };
    }

    pub fn preservesIdentityThroughPtrCast(destination: Type, analyser: *Analyser, source: Type) bool {
        const dest = destination.pointerCastInfo(analyser) orelse return false;
        const src = source.pointerCastInfo(analyser) orelse return false;
        return (dest.pointer.size == .one or dest.pointer.size == .many) and
            (src.pointer.size == .one or src.pointer.size == .many) and
            dest.pointer.is_const == src.pointer.is_const and
            dest.pointer.is_volatile == src.pointer.is_volatile and
            dest.pointer.is_allowzero == src.pointer.is_allowzero and
            dest.pointer.address_space == src.pointer.address_space and
            std.meta.eql(dest.pointer.packed_offset, src.pointer.packed_offset);
    }

    pub fn hasSamePointerElementType(lhs: Type, analyser: *Analyser, rhs: Type) bool {
        const lhs_info = lhs.pointerCastInfo(analyser) orelse return false;
        const rhs_info = rhs.pointerCastInfo(analyser) orelse return false;
        return lhs_info.pointer.elem_ty.eql(rhs_info.pointer.elem_ty);
    }

    pub fn hasComparablePointerIdentity(lhs: Type, analyser: *Analyser, rhs: Type) bool {
        const lhs_info = lhs.pointerCastInfo(analyser) orelse return false;
        const rhs_info = rhs.pointerCastInfo(analyser) orelse return false;
        if (lhs_info.pointer.size != rhs_info.pointer.size or
            !lhs_info.pointer.elem_ty.eql(rhs_info.pointer.elem_ty) or
            lhs_info.pointer.is_volatile != rhs_info.pointer.is_volatile or
            lhs_info.pointer.is_allowzero != rhs_info.pointer.is_allowzero or
            lhs_info.pointer.address_space != rhs_info.pointer.address_space or
            lhs_info.pointer.alignment != rhs_info.pointer.alignment or
            !std.meta.eql(lhs_info.pointer.packed_offset, rhs_info.pointer.packed_offset) or
            lhs_info.pointer.sentinel != rhs_info.pointer.sentinel) return false;
        return lhs_info.pointer.size == .one or lhs_info.pointer.size == .many;
    }

    pub fn isManyPointerType(self: Type, analyser: *Analyser) bool {
        const info = self.pointerCastInfo(analyser) orelse return false;
        return !info.is_optional and info.pointer.size == .many;
    }

    pub fn isPlainSinglePointerTo(
        self: Type,
        analyser: *Analyser,
        child: Type,
        require_mutable: bool,
    ) Error!bool {
        const info = self.typePointerInfo(analyser) orelse return false;
        if (info.size != .one or
            (require_mutable and info.is_const) or
            info.is_volatile or
            info.is_allowzero or
            info.address_space != .generic or
            info.packed_offset.bit_offset != 0 or
            info.packed_offset.host_size != 0 or
            info.sentinel != .none or
            !info.elem_ty.eql(child)) return false;
        if (info.alignment == 0) return true;
        const natural_alignment = try analyser.resolveTypeAlignment(child) orelse return false;
        return info.alignment >= natural_alignment;
    }

    pub fn isAtomicSinglePointerValueType(self: Type, analyser: *Analyser) bool {
        const info = self.pointerCastInfo(analyser) orelse return false;
        return info.pointer.size == .one and (!info.is_optional or !info.pointer.is_allowzero);
    }

    pub fn isOptionalRuntimePointerType(self: Type, analyser: *Analyser) bool {
        const info = self.pointerCastInfo(analyser) orelse return false;
        return info.is_optional and
            info.pointer.size != .slice and
            info.pointer.size != .c and
            !info.pointer.is_allowzero;
    }

    pub const NumericPointerInfo = struct {
        size: std.builtin.Type.Pointer.Size,
        is_optional: bool,
        allows_zero: bool,
        alignment: u64,
        payload_type: Type,
    };

    pub const NumericPointerArithmeticInfo = struct {
        size: std.builtin.Type.Pointer.Size,
        element_type: Type,
        element_size: u64,
    };

    pub fn numericPointerInfo(self: Type, analyser: *Analyser) Error!?NumericPointerInfo {
        const info = self.pointerCastInfo(analyser) orelse return null;
        if (info.pointer.size == .slice or info.pointer.elem_ty.isFunc() or
            info.pointer.elem_ty.isTupleType(analyser)) return null;
        if (info.is_optional and (info.pointer.size == .c or info.pointer.is_allowzero)) return null;
        const alignment = if (info.pointer.alignment != 0)
            info.pointer.alignment
        else
            try analyser.resolveTypeAlignment(info.pointer.elem_ty) orelse return null;
        return .{
            .size = info.pointer.size,
            .is_optional = info.is_optional,
            .allows_zero = info.is_optional or info.pointer.size == .c or info.pointer.is_allowzero,
            .alignment = alignment,
            .payload_type = if (info.is_optional) switch (self.data) {
                .optional => |optional| optional.*,
                .ip_index => |payload| switch (analyser.ip.indexToKey(payload.index orelse return null)) {
                    .optional_type => |optional| Type.fromIP(analyser, .type_type, optional.payload_type),
                    else => return null,
                },
                else => return null,
            } else self,
        };
    }

    pub fn numericPointerArithmeticInfo(self: Type, analyser: *Analyser) ?NumericPointerArithmeticInfo {
        const info = self.pointerCastInfo(analyser) orelse return null;
        if (info.is_optional or info.pointer.size == .slice or info.pointer.alignment != 0 or
            info.pointer.packed_offset.bit_offset != 0 or info.pointer.packed_offset.host_size != 0) return null;
        const element_type = if (info.pointer.size == .one) switch (info.pointer.elem_ty.data) {
            .array => |array| array.elem_ty.*,
            .ip_index => |payload| switch (analyser.ip.indexToKey(payload.index orelse return null)) {
                .array_type => |array| Type.fromIP(analyser, .type_type, array.child),
                else => info.pointer.elem_ty,
            },
            else => info.pointer.elem_ty,
        } else info.pointer.elem_ty;
        return .{
            .size = info.pointer.size,
            .element_type = element_type,
            .element_size = analyser.resolveTypeByteSize(element_type) orelse return null,
        };
    }

    pub fn isAtomicPackedStructType(self: Type, analyser: *Analyser) bool {
        return self.isStructType(analyser) and analyser.containerTypeLayout(self) == .@"packed";
    }

    pub const PointerQualifierCast = enum { discard_const, discard_volatile, increase_alignment };

    pub fn qualifierCastType(
        source: Type,
        analyser: *Analyser,
        kind: PointerQualifierCast,
    ) error{OutOfMemory}!?Type {
        const cast_info = source.pointerCastInfo(analyser) orelse return null;
        const info = cast_info.pointer;
        switch (info.size) {
            .one, .many, .slice => {},
            .c => return null,
        }
        var flags: InternPool.Key.Pointer.Flags = .{
            .size = info.size,
            .is_const = info.is_const,
            .is_volatile = info.is_volatile,
            .is_allowzero = info.is_allowzero,
            .address_space = info.address_space,
            .alignment = std.math.cast(u16, info.alignment) orelse return null,
        };
        switch (kind) {
            .discard_const => {
                if (!flags.is_const) return null;
                flags.is_const = false;
            },
            .discard_volatile => {
                if (!flags.is_volatile) return null;
                flags.is_volatile = false;
            },
            .increase_alignment => return null,
        }
        const pointer = try Type.createPointerTypeWithFlags(
            analyser,
            flags,
            info.packed_offset,
            info.sentinel,
            info.elem_ty,
        );
        return @as(?Type, if (cast_info.is_optional)
            try Type.createOptionalType(analyser, pointer)
        else
            pointer);
    }

    pub fn preservesIdentityThroughQualifierCast(
        destination: Type,
        analyser: *Analyser,
        source: Type,
        kind: PointerQualifierCast,
    ) bool {
        const dest = destination.pointerCastInfo(analyser) orelse return false;
        const src = source.pointerCastInfo(analyser) orelse return false;
        if (dest.is_optional != src.is_optional or
            dest.pointer.size != src.pointer.size or
            !dest.pointer.elem_ty.eql(src.pointer.elem_ty) or
            dest.pointer.is_allowzero != src.pointer.is_allowzero or
            dest.pointer.address_space != src.pointer.address_space or
            !std.meta.eql(dest.pointer.packed_offset, src.pointer.packed_offset)) return false;
        switch (dest.pointer.size) {
            .one, .many, .slice => {},
            .c => return false,
        }
        return switch (kind) {
            .discard_const => !dest.pointer.is_const and src.pointer.is_const and
                dest.pointer.is_volatile == src.pointer.is_volatile and
                dest.pointer.alignment == src.pointer.alignment,
            .discard_volatile => !dest.pointer.is_volatile and src.pointer.is_volatile and
                dest.pointer.is_const == src.pointer.is_const and
                dest.pointer.alignment == src.pointer.alignment,
            .increase_alignment => dest.pointer.is_const == src.pointer.is_const and
                dest.pointer.is_volatile == src.pointer.is_volatile and
                dest.pointer.alignment >= src.pointer.alignment,
        };
    }

    pub fn constAggregatePointerChild(self: Type, analyser: *Analyser) ?Type {
        const info = self.typePointerInfo(analyser) orelse return null;
        if (info.size != .one or !info.is_const or info.elem_ty.isTupleType(analyser)) return null;
        const is_aggregate = info.elem_ty.isStructType(analyser) or info.elem_ty.isUnionType() or
            if (info.elem_ty.ipIndex()) |index| analyser.ip.zigTypeTag(index) == .@"union" else false;
        if (!is_aggregate) return null;
        return info.elem_ty;
    }

    pub fn constScalarPointerChild(self: Type, analyser: *Analyser) ?Type {
        const info = self.typePointerInfo(analyser) orelse return null;
        if (info.size != .one or !info.is_const) return null;
        if (info.elem_ty.isEnumType(analyser) or info.elem_ty.isErrorSetType(analyser) or
            info.elem_ty.isOptionalType(analyser) or info.elem_ty.data == .error_union) return info.elem_ty;
        const tag = analyser.ip.zigTypeTag(info.elem_ty.ipIndex() orelse return null) orelse return null;
        return switch (tag) {
            .int, .comptime_int, .bool, .float, .comptime_float, .enum_literal, .null, .optional, .error_union => info.elem_ty,
            else => null,
        };
    }

    pub fn constMaterializedPointerChild(self: Type, analyser: *Analyser) ?Type {
        return self.constMaterializedPointerChildDepth(analyser, 0);
    }

    fn materializedPointerChild(self: Type, analyser: *Analyser) ?Type {
        return self.materializedPointerChildDepth(analyser, 0);
    }

    fn isSinglePointerType(self: Type, analyser: *Analyser) bool {
        const info = self.pointerCastInfo(analyser) orelse return false;
        return !info.is_optional and info.pointer.size == .one;
    }

    fn constMaterializedPointerChildDepth(self: Type, analyser: *Analyser, depth: u8) ?Type {
        const info = self.typePointerInfo(analyser) orelse return null;
        if (!info.is_const) return null;
        return self.materializedPointerChildDepth(analyser, depth);
    }

    fn materializedPointerChildDepth(self: Type, analyser: *Analyser, depth: u8) ?Type {
        if (depth == 128) return null;
        const info = self.typePointerInfo(analyser) orelse return null;
        if (info.size != .one) return null;
        const child = info.elem_ty;
        if (child.isFunc() or child.isEnumType(analyser) or child.isErrorSetType(analyser) or
            child.isOptionalType(analyser) or child.isTupleType(analyser) or
            child.isStructType(analyser) or child.isUnionType() or child.data == .error_union) return child;
        return switch (child.data) {
            .array, .vector => child,
            .pointer => if (child.materializedPointerChildDepth(analyser, depth + 1) != null) child else null,
            .ip_index => |payload| switch (analyser.ip.zigTypeTag(payload.index orelse return null) orelse return null) {
                .array,
                .vector,
                .int,
                .comptime_int,
                .bool,
                .float,
                .comptime_float,
                .enum_literal,
                .null,
                .optional,
                .error_union,
                .@"enum",
                .error_set,
                .@"struct",
                .@"union",
                .@"fn",
                => child,
                .pointer => if (child.materializedPointerChildDepth(analyser, depth + 1) != null) child else null,
                else => null,
            },
            else => null,
        };
    }

    const ComptimeCallEvaluation = enum { never, if_needed, eager };

    fn comptimeCallEvaluation(self: Type, analyser: *Analyser) ComptimeCallEvaluation {
        if (!self.is_type_val) return .never;
        return switch (self.data) {
            .array, .vector, .tuple, .optional, .union_tag => .if_needed,
            .container => switch (self.getContainerKind() orelse return .never) {
                .keyword_struct, .keyword_union, .keyword_enum => .if_needed,
                else => .never,
            },
            .pointer => if (self.isConstSequencePointerType(analyser) or
                self.isSinglePointerType(analyser) or
                self.materializedPointerChild(analyser) != null) .if_needed else .never,
            .ip_index => |payload| switch (analyser.ip.zigTypeTag(payload.index orelse return .never) orelse return .never) {
                .int, .comptime_int => .eager,
                .array,
                .vector,
                .bool,
                .float,
                .comptime_float,
                .enum_literal,
                .null,
                .@"enum",
                .optional,
                .error_set,
                .@"struct",
                .@"union",
                => .if_needed,
                .pointer => if (self.isConstSequencePointerType(analyser) or
                    self.isSinglePointerType(analyser) or
                    self.materializedPointerChild(analyser) != null) .if_needed else .never,
                else => .never,
            },
            else => .never,
        };
    }

    pub fn sequencePointerLength(self: Type, analyser: *Analyser) ?usize {
        if (!self.isConstSequencePointerType(analyser)) return null;
        const info = self.typePointerInfo(analyser) orelse return null;
        if (info.size != .one) return null;
        return switch (info.elem_ty.data) {
            .array => |array| std.math.cast(usize, array.elem_count orelse return null),
            .tuple => |tuple| tuple.len,
            .ip_index => |payload| switch (analyser.ip.indexToKey(payload.index orelse return null)) {
                .array_type => |array| std.math.cast(usize, array.len),
                .tuple_type => |tuple| tuple.types.len,
                else => null,
            },
            else => null,
        };
    }

    const TypePointerInfo = struct {
        size: std.builtin.Type.Pointer.Size,
        is_const: bool,
        is_volatile: bool,
        is_allowzero: bool,
        address_space: std.builtin.AddressSpace,
        alignment: u32,
        packed_offset: InternPool.Key.Pointer.PackedOffset,
        sentinel: InternPool.Index,
        elem_ty: Type,
    };

    const PointerCastInfo = struct {
        pointer: TypePointerInfo,
        is_optional: bool,
    };

    fn pointerCastInfo(self: Type, analyser: *Analyser) ?PointerCastInfo {
        if (self.typePointerInfo(analyser)) |pointer| return .{
            .pointer = pointer,
            .is_optional = false,
        };
        if (!self.is_type_val) return null;
        const child = switch (self.data) {
            .optional => |optional| optional.*,
            .ip_index => |payload| switch (analyser.ip.indexToKey(payload.index orelse return null)) {
                .optional_type => |optional| Type.fromIP(analyser, .type_type, optional.payload_type),
                else => return null,
            },
            else => return null,
        };
        return .{
            .pointer = child.typePointerInfo(analyser) orelse return null,
            .is_optional = true,
        };
    }

    fn typePointerInfo(self: Type, analyser: *Analyser) ?TypePointerInfo {
        if (!self.is_type_val) return null;
        return switch (self.data) {
            .pointer => |info| .{
                .size = info.size,
                .is_const = info.is_const,
                .is_volatile = info.is_volatile,
                .is_allowzero = info.is_allowzero,
                .address_space = info.address_space,
                .alignment = info.alignment,
                .packed_offset = info.packed_offset,
                .sentinel = info.sentinel,
                .elem_ty = info.elem_ty.*,
            },
            .ip_index => |payload| switch (analyser.ip.indexToKey(payload.index orelse return null)) {
                .pointer_type => |info| .{
                    .size = info.flags.size,
                    .is_const = info.flags.is_const,
                    .is_volatile = info.flags.is_volatile,
                    .is_allowzero = info.flags.is_allowzero,
                    .address_space = info.flags.address_space,
                    .alignment = info.flags.alignment,
                    .packed_offset = info.packed_offset,
                    .sentinel = info.sentinel,
                    .elem_ty = Type.fromIP(analyser, .type_type, info.elem_type),
                },
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
            if (self.isEnumType(analyser) or self.isTaggedUnion()) {
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
            if (self.isEnumType(analyser)) {
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
        std.debug.assert(ty.data == .ip_index or ty.data == .enum_value or ty.is_type_val);
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
                if (info.is_allowzero and info.size != .c) try writer.writeAll("allowzero ");
                if (info.alignment != 0) {
                    try writer.print("align({d}", .{info.alignment});
                    if (info.packed_offset.bit_offset != 0 or info.packed_offset.host_size != 0) {
                        try writer.print(":{d}:{d}", .{ info.packed_offset.bit_offset, info.packed_offset.host_size });
                    }
                    try writer.writeAll(") ");
                }
                if (info.address_space != .generic) {
                    try writer.print("addrspace(.{t}) ", .{info.address_space});
                }
                if (info.is_const) try writer.writeAll("const ");
                if (info.is_volatile) try writer.writeAll("volatile ");
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
            .vector => |info| {
                try writer.print("@Vector({d}, ", .{info.len});
                try info.elem_ty.rawStringify(writer, analyser, options);
                try writer.writeByte(')');
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
            .type_info_value => |value| try writer.print(".{s}", .{@tagName(value.tag)}),
            .comptime_value => |value| switch (value.data) {
                .array => |items| {
                    const address = switch (value.ty.data) {
                        .pointer => true,
                        .ip_index => |payload| if (payload.index) |index| switch (analyser.ip.indexToKey(index)) {
                            .pointer_type => true,
                            else => false,
                        } else false,
                        else => false,
                    };
                    if (address) try writer.writeByte('&');
                    try writer.writeAll(".{");
                    for (items, 0..) |item, index| {
                        if (index != 0) try writer.writeByte(',');
                        try writer.writeByte(' ');
                        try item.rawStringify(writer, analyser, options);
                    }
                    if (items.len != 0) try writer.writeByte(' ');
                    try writer.writeByte('}');
                },
                .fields => |fields| {
                    try writer.writeAll(".{");
                    for (fields, 0..) |field, index| {
                        if (index != 0) try writer.writeByte(',');
                        try writer.print(" .{s} = ", .{field.name});
                        try field.value.rawStringify(writer, analyser, options);
                    }
                    if (fields.len != 0) try writer.writeByte(' ');
                    try writer.writeByte('}');
                },
                .pointee => |pointee| {
                    try writer.writeByte('&');
                    try pointee.value.rawStringify(writer, analyser, options);
                },
                .expression => |node_handle| try writer.writeAll(offsets.nodeToSlice(&node_handle.handle.tree, node_handle.node)),
                else => try value.ty.rawStringify(writer, analyser, options),
            },
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
                                if (info.bound_params.get(token_handle)) |param_ty| {
                                    if (!param_ty.is_type_val and !param_ty.hasKnownValue(analyser)) continue;
                                    if (param_ty.ipIndex()) |index| {
                                        if (analyser.ip.isNull(index)) continue;
                                    }
                                    if (!first) try writer.writeByte(',');
                                    try param_ty.rawStringify(writer, analyser, .{
                                        .referenced = referenced,
                                        .truncate_container_decls = options.truncate_container_decls,
                                    });
                                } else if (info.display_params.get(token_handle)) |node_handle| {
                                    if (!first) try writer.writeByte(',');
                                    try writer.writeAll(offsets.nodeToSlice(&node_handle.handle.tree, node_handle.node));
                                } else continue;
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

pub fn resolveComptimeImportValue(
    analyser: *Analyser,
    handle: *DocumentStore.Handle,
    import_string: []const u8,
) Error!?Type {
    if (std.mem.endsWith(u8, import_string, ".zon")) {
        // TODO
        return null;
    }

    if (try analyser.resolveImportString(handle, import_string)) |ty| return ty;
    if (try analyser.resolveImportString(analyser.root_handle orelse return null, import_string)) |ty| return ty;
    return null;
}

pub fn resolveComptimeEmbedFileValue(
    analyser: *Analyser,
    handle: *DocumentStore.Handle,
    path: []const u8,
) Error!?Type {
    if (!handle.uri.isFileScheme()) return null;
    const uri = try Uri.resolveImport(analyser.arena, handle.uri, handle.uri.toStdUri(), path);
    const bytes = analyser.store.readFileAlloc(analyser.arena, uri) catch |err| switch (err) {
        error.OutOfMemory, error.Canceled => |e| return e,
        else => return null,
    };
    const value = try analyser.stringValue(bytes);
    return value;
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

fn hashTypeBindings(hasher: anytype, bindings: TokenToTypeMap) void {
    var bindings_hash: u64 = 0;
    for (bindings.keys(), bindings.values()) |token_handle, ty| {
        var binding_hasher: std.hash.Wyhash = .init(0);
        token_handle.hashWithHasher(&binding_hasher);
        ty.hashWithHasher(&binding_hasher);
        bindings_hash ^= binding_hasher.final();
    }
    std.hash.autoHash(hasher, bindings.count());
    std.hash.autoHash(hasher, bindings_hash);
}

fn eqlTypeBindings(a: TokenToTypeMap, b: TokenToTypeMap) bool {
    if (a.count() != b.count()) return false;
    for (a.keys(), a.values()) |token_handle, ty| {
        const other = b.get(token_handle) orelse return false;
        if (!ty.eql(other)) return false;
    }
    return true;
}

fn hashDisplayBindings(hasher: anytype, bindings: TokenToNodeMap) void {
    var bindings_hash: u64 = 0;
    for (bindings.keys(), bindings.values()) |token_handle, node_handle| {
        var binding_hasher: std.hash.Wyhash = .init(0);
        token_handle.hashWithHasher(&binding_hasher);
        std.hash.autoHash(&binding_hasher, node_handle.node);
        binding_hasher.update(node_handle.handle.uri.raw);
        bindings_hash ^= binding_hasher.final();
    }
    std.hash.autoHash(hasher, bindings.count());
    std.hash.autoHash(hasher, bindings_hash);
}

fn eqlDisplayBindings(a: TokenToNodeMap, b: TokenToNodeMap) bool {
    if (a.count() != b.count()) return false;
    for (a.keys(), a.values()) |token_handle, node_handle| {
        const other = b.get(token_handle) orelse return false;
        if (!node_handle.eql(other)) return false;
    }
    return true;
}

const GeneratedContainerTypeKey = struct {
    node: NodeWithUri,
    container_type: ?Type,
    bindings: TokenToTypeMap,
    display_bindings: TokenToNodeMap,

    const Context = struct {
        pub fn hash(_: Context, key: GeneratedContainerTypeKey) u64 {
            var hasher: std.hash.Wyhash = .init(0);
            std.hash.autoHash(&hasher, key.node.node);
            hasher.update(key.node.uri.raw);
            if (key.container_type) |container_type| {
                hasher.update(&.{1});
                container_type.hashWithHasher(&hasher);
            } else {
                hasher.update(&.{0});
            }
            hashTypeBindings(&hasher, key.bindings);
            hashDisplayBindings(&hasher, key.display_bindings);
            return hasher.final();
        }

        pub fn eql(_: Context, a: GeneratedContainerTypeKey, b: GeneratedContainerTypeKey) bool {
            if (a.node.node != b.node.node or !a.node.uri.eql(b.node.uri)) return false;
            if ((a.container_type == null) != (b.container_type == null)) return false;
            if (a.container_type) |container_type| {
                if (!container_type.eql(b.container_type.?)) return false;
            }
            return eqlTypeBindings(a.bindings, b.bindings) and eqlDisplayBindings(a.display_bindings, b.display_bindings);
        }
    };
};

const EnumLiteralCacheKey = struct {
    uri: Uri,
    source_index: usize,
    name: []const u8,
    bindings: TokenToTypeMap,
    display_bindings: TokenToNodeMap,

    const Context = struct {
        pub fn hash(_: Context, key: EnumLiteralCacheKey) u64 {
            var hasher: std.hash.Wyhash = .init(0);
            hasher.update(key.uri.raw);
            std.hash.autoHash(&hasher, key.source_index);
            hasher.update(key.name);
            hashTypeBindings(&hasher, key.bindings);
            hashDisplayBindings(&hasher, key.display_bindings);
            return hasher.final();
        }

        pub fn eql(_: Context, a: EnumLiteralCacheKey, b: EnumLiteralCacheKey) bool {
            if (!a.uri.eql(b.uri) or a.source_index != b.source_index or !std.mem.eql(u8, a.name, b.name)) return false;
            return eqlTypeBindings(a.bindings, b.bindings) and eqlDisplayBindings(a.display_bindings, b.display_bindings);
        }
    };
};

const SequentialEnumKey = struct {
    kind: Kind,
    names: []const []const u8,

    const Kind = enum { field, declaration };

    const Context = struct {
        pub fn hash(_: Context, key: SequentialEnumKey) u64 {
            var hasher: std.hash.Wyhash = .init(0);
            std.hash.autoHash(&hasher, key.kind);
            std.hash.autoHash(&hasher, key.names.len);
            for (key.names) |name| {
                std.hash.autoHash(&hasher, name.len);
                hasher.update(name);
            }
            return hasher.final();
        }

        pub fn eql(_: Context, a: SequentialEnumKey, b: SequentialEnumKey) bool {
            if (a.kind != b.kind or a.names.len != b.names.len) return false;
            for (a.names, b.names) |a_name, b_name| {
                if (!std.mem.eql(u8, a_name, b_name)) return false;
            }
            return true;
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
                } else if (tokenizer.buffer[tok.loc.start] != '@') {
                    const value = try analyser.resolvePrimitive(symbol_name) orelse return null;
                    current_type = Type.fromIP(analyser, analyser.ip.typeOf(value), value);
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
pub const TokenToNodeMap = std.array_hash_map.Custom(TokenWithHandle, NodeWithHandle, TokenWithHandle.Context, true);

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

    pub const Context = struct {
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
                    .vector => |vector_info| try vector_info.elem_ty.instanceTypeVal(analyser),
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

                const condition = try analyser.resolveTypeOfNodeInternal(.of(cond, self.handle)) orelse return null;
                break :blk try analyser.resolveSwitchCaptureValue(
                    condition,
                    tree,
                    tree.switchFull(payload.node),
                    case,
                    self.decl == .switch_inline_tag_payload,
                );
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
    var pending_display_params: TokenToNodeMap = .empty;
    defer pending_display_params.deinit(analyser.gpa);

    var current: DocumentScope.Scope.Index = .root;
    var meta_params: TokenToTypeMap = .empty;
    var display_params: TokenToNodeMap = .empty;
    var scope_iterator = iterateEnclosingScopes(document_scope, source_index);
    while (scope_iterator.next().unwrap()) |scope_index| {
        switch (document_scope.getScopeTag(scope_index)) {
            .container => {
                current = scope_index;
                for (pending_meta_params.keys(), pending_meta_params.values()) |token_handle, ty| {
                    try meta_params.put(analyser.arena, token_handle, ty);
                }
                pending_meta_params.clearRetainingCapacity();
                for (pending_display_params.keys(), pending_display_params.values()) |token_handle, ty| {
                    try display_params.put(analyser.arena, token_handle, ty);
                }
                pending_display_params.clearRetainingCapacity();
            },
            .function => {
                const function_node = document_scope.getScopeAstNode(scope_index).?;
                var buf: [1]Ast.Node.Index = undefined;
                const func = tree.fullFnProto(&buf, function_node).?;
                var it: ast.FnParamIterator = .init(&func, tree);
                while (it.next()) |param| {
                    const param_name_token = param.name_token orelse continue;
                    const token_handle: TokenWithHandle = .{ .token = param_name_token, .handle = handle };
                    if (analyser.display_bindings) |bindings| {
                        if (bindings.get(token_handle)) |node_handle| {
                            try pending_display_params.put(analyser.gpa, token_handle, node_handle);
                            continue;
                        }
                    }
                    if (analyser.generic_bindings) |bindings| {
                        if (bindings.get(token_handle)) |bound| {
                            try pending_meta_params.put(analyser.gpa, token_handle, bound);
                            continue;
                        }
                    }

                    const param_type_expr = param.type_expr orelse continue;
                    const param_type_loc = offsets.nodeToLoc(tree, param_type_expr);
                    if (param_type_loc.start <= source_index and source_index < param_type_loc.end) break;
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
                .display_params = display_params,
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

pub fn identifierTokenName(
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
        .union_tag => |union_type| return analyser.lookupSymbolContainer(union_type.*, symbol, kind),
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

    const key: EnumLiteralCacheKey = .{
        .uri = handle.uri,
        .source_index = source_index,
        .name = name,
        .bindings = if (analyser.generic_bindings) |bindings| bindings.* else .empty,
        .display_bindings = if (analyser.display_bindings) |bindings| bindings.* else .empty,
    };
    const cached = try analyser.resolved_enum_literals.getOrPut(analyser.gpa, key);
    if (cached.found_existing) return cached.value_ptr.*;
    errdefer _ = analyser.resolved_enum_literals.remove(key);
    cached.key_ptr.name = try analyser.arena.dupe(u8, name);
    cached.key_ptr.bindings = if (analyser.generic_bindings) |bindings|
        try bindings.clone(analyser.arena)
    else
        .empty;
    cached.key_ptr.display_bindings = if (analyser.display_bindings) |bindings|
        try bindings.clone(analyser.arena)
    else
        .empty;
    cached.value_ptr.* = null;

    const tree = &handle.tree;
    const nodes = try ast.nodesOverlappingIndex(analyser.arena, tree, source_index);
    if (nodes.len == 0) return null;
    const result = try analyser.lookupSymbolFieldInit(handle, name, nodes[0], nodes[1..]);
    analyser.resolved_enum_literals.getPtr(key).?.* = result;
    return result;
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
