const std = @import("std");
const Analyser = @import("../analysis.zig");
const ast = @import("../ast.zig");
const offsets = @import("../offsets.zig");
const Ast = std.zig.Ast;
const Type = Analyser.Type;
const Handle = @import("../DocumentStore.zig").Handle;
const Error = Analyser.Error;

pub const Value = struct {
    ty: Type,
    data: union(enum) {
        array: []const Type,
        fields: []const Field,
        optional: ?Type,
        reference: *Reference,
        /// Source-backed value used when an aggregate element cannot be
        /// materialized by the intern pool but can still be copied at comptime.
        expression: Analyser.NodeWithHandle,
    },

    pub const Field = struct { name: []const u8, value: Type };
    pub const Cell = struct { value: Type };
    pub const Reference = struct {
        storage: *Cell,
        path: []const Access,

        pub const Access = union(enum) {
            field: []const u8,
            index: usize,
            optional_payload,
        };

        fn hash(self: Reference, hasher: anytype) void {
            std.hash.autoHash(hasher, @intFromPtr(self.storage));
            for (self.path) |access| {
                std.hash.autoHash(hasher, std.meta.activeTag(access));
                switch (access) {
                    .field => |name| hasher.update(name),
                    .index => |index| std.hash.autoHash(hasher, index),
                    .optional_payload => {},
                }
            }
        }

        fn eql(self: Reference, other: Reference) bool {
            if (self.storage != other.storage or self.path.len != other.path.len) return false;
            for (self.path, other.path) |lhs, rhs| {
                if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return false;
                switch (lhs) {
                    .field => |name| if (!std.mem.eql(u8, name, rhs.field)) return false,
                    .index => |index| if (index != rhs.index) return false,
                    .optional_payload => {},
                }
            }
            return true;
        }
    };

    pub fn hash(self: *const Value, hasher: anytype) void {
        self.ty.hashWithHasher(hasher);
        std.hash.autoHash(hasher, std.meta.activeTag(self.data));
        switch (self.data) {
            .array => |items| for (items) |item| item.hashWithHasher(hasher),
            .fields => |fields| for (fields) |entry| {
                hasher.update(entry.name);
                entry.value.hashWithHasher(hasher);
            },
            .optional => |payload| {
                std.hash.autoHash(hasher, payload != null);
                if (payload) |value| value.hashWithHasher(hasher);
            },
            .reference => |reference| reference.hash(hasher),
            .expression => |node_handle| {
                std.hash.autoHash(hasher, node_handle.node);
                hasher.update(node_handle.handle.uri.raw);
            },
        }
    }

    pub fn eql(self: *const Value, other: *const Value) bool {
        if (!self.ty.eql(other.ty) or std.meta.activeTag(self.data) != std.meta.activeTag(other.data)) return false;
        switch (self.data) {
            .array => |items| {
                if (items.len != other.data.array.len) return false;
                for (items, other.data.array) |a, b| if (!a.eql(b)) return false;
            },
            .fields => |fields| {
                if (fields.len != other.data.fields.len) return false;
                for (fields, other.data.fields) |a, b| {
                    if (!std.mem.eql(u8, a.name, b.name) or !a.value.eql(b.value)) return false;
                }
            },
            .optional => |payload| {
                if ((payload == null) != (other.data.optional == null)) return false;
                if (payload) |value| if (!value.eql(other.data.optional.?)) return false;
            },
            .reference => |reference| return reference.eql(other.data.reference.*),
            .expression => |node_handle| return node_handle.eql(other.data.expression),
        }
        return true;
    }

    pub fn create(analyser: *Analyser, ty: Type, data: @FieldType(Value, "data")) error{OutOfMemory}!Type {
        const value = try analyser.arena.create(Value);
        value.* = .{ .ty = ty, .data = data };
        return .{ .data = .{ .comptime_value = value }, .is_type_val = false };
    }

    pub fn createExpression(analyser: *Analyser, ty: Type, node_handle: Analyser.NodeWithHandle) error{OutOfMemory}!Type {
        return create(analyser, ty, .{ .expression = node_handle });
    }

    pub fn deref(value: Type) Type {
        if (value.data == .comptime_value and value.data.comptime_value.data == .reference) {
            const reference = value.data.comptime_value.data.reference;
            if (reference.path.len == 0) return reference.storage.value;
        }
        return value;
    }

    pub fn elements(value: Type) ?[]const Type {
        const resolved = deref(value);
        if (resolved.data != .comptime_value or resolved.data.comptime_value.data != .array) return null;
        return resolved.data.comptime_value.data.array;
    }

    pub fn fieldEntries(value: Type) ?[]const Field {
        const resolved = deref(value);
        if (resolved.data != .comptime_value or resolved.data.comptime_value.data != .fields) return null;
        return resolved.data.comptime_value.data.fields;
    }

    pub fn field(value: Type, name: []const u8) ?Type {
        for (fieldEntries(value) orelse return null) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.value;
        }
        return null;
    }
};

pub const Interpreter = struct {
    analyser: *Analyser,
    bindings: Analyser.TokenToTypeMap,
    cells: std.array_hash_map.Custom(Analyser.TokenWithHandle, *Value.Cell, Analyser.TokenWithHandle.Context, true) = .empty,
    budget: *Budget,

    const Budget = struct { steps: usize = 8192, depth: usize = 0, expression_depth: usize = 0 };
    const Flow = union(enum) {
        next,
        value: Type,
        returned: Type,
        continued: ?Ast.TokenIndex,
        stopped: struct { target: ?Ast.TokenIndex, value: ?Type },
        unknown,
    };
    const BranchTarget = union(enum) {
        none,
        node: Ast.Node.Index,
    };
    const OptionalValue = union(enum) {
        absent,
        payload: Type,
    };

    pub fn needed(handle: *Handle, body: Ast.Node.Index) bool {
        const tree = &handle.tree;
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, body) orelse return false;
        for (statements) |node| {
            if (tree.fullVarDecl(node)) |decl| {
                if (tree.tokenTag(decl.ast.mut_token) == .keyword_var) return true;
            }
            if (tree.nodeTag(node) == .assign_destructure) {
                for (tree.assignDestructure(node).ast.variables) |lhs| {
                    if (tree.fullVarDecl(lhs) != null) return true;
                }
            }
            if (tree.nodeTag(node) == .@"comptime") return true;
        }
        return false;
    }

    pub fn evaluate(analyser: *Analyser, handle: *Handle, body: Ast.Node.Index) Error!?Type {
        var budget: Budget = .{};
        var interpreter: Interpreter = .{
            .analyser = analyser,
            .bindings = if (analyser.generic_bindings) |bindings| try bindings.clone(analyser.arena) else .empty,
            .budget = if (analyser.comptime_interpreter) |parent| parent.budget else &budget,
        };
        return switch (try interpreter.run(handle, body)) {
            .returned => |value| value,
            else => null,
        };
    }

    pub fn evaluateCall(analyser: *Analyser, handle: *Handle, node: Ast.Node.Index) Error!?Type {
        var budget: Budget = .{};
        var interpreter: Interpreter = .{
            .analyser = analyser,
            .bindings = if (analyser.generic_bindings) |bindings| try bindings.clone(analyser.arena) else .empty,
            .budget = if (analyser.comptime_interpreter) |parent| parent.budget else &budget,
        };
        return interpreter.callValue(handle, node);
    }

    pub fn enterExpression(self: *Interpreter) bool {
        if (self.budget.expression_depth >= 128 or !self.tick()) return false;
        self.budget.expression_depth += 1;
        return true;
    }

    pub fn leaveExpression(self: *Interpreter) void {
        self.budget.expression_depth -= 1;
    }

    pub fn evaluateExpression(self: *Interpreter, handle: *Handle, node: Ast.Node.Index) Error!?Type {
        return self.eval(handle, node);
    }

    fn tick(self: *Interpreter) bool {
        if (self.budget.steps == 0) return false;
        self.budget.steps -= 1;
        return true;
    }

    fn run(self: *Interpreter, handle: *Handle, body: Ast.Node.Index) Error!Flow {
        if (self.budget.depth >= 32 or !self.tick()) return .unknown;
        self.budget.depth += 1;
        defer self.budget.depth -= 1;
        const analyser = self.analyser;
        const old_interpreter = analyser.comptime_interpreter;
        const old_bindings = analyser.generic_bindings;
        const old_values = analyser.evaluate_comptime_values;
        const old_numbers = analyser.resolve_number_literal_values;
        const old_flow = analyser.evaluate_comptime_control_flow;
        analyser.comptime_interpreter = self;
        analyser.generic_bindings = &self.bindings;
        analyser.evaluate_comptime_values = true;
        analyser.resolve_number_literal_values = true;
        analyser.evaluate_comptime_control_flow = true;
        defer {
            analyser.comptime_interpreter = old_interpreter;
            analyser.generic_bindings = old_bindings;
            analyser.evaluate_comptime_values = old_values;
            analyser.resolve_number_literal_values = old_numbers;
            analyser.evaluate_comptime_control_flow = old_flow;
        }
        return self.statement(handle, body);
    }

    fn eval(self: *Interpreter, handle: *Handle, node: Ast.Node.Index) Error!?Type {
        if (!self.tick()) return null;
        var block_buffer: [2]Ast.Node.Index = undefined;
        if (handle.tree.blockStatements(&block_buffer, node) != null) {
            return switch (try self.block(handle, node)) {
                .next => Type.fromIP(self.analyser, .void_type, .void_value),
                .value => |value| value,
                else => null,
            };
        }
        switch (handle.tree.nodeTag(node)) {
            .@"comptime", .@"nosuspend" => return self.eval(handle, handle.tree.nodeData(node).node),
            .grouped_expression => return self.eval(handle, handle.tree.nodeData(node).node_and_token[0]),
            .if_simple, .@"if" => {
                const target = try self.ifTarget(handle, node) orelse return null;
                return switch (target) {
                    .none => Type.fromIP(self.analyser, .void_type, .void_value),
                    .node => |target_node| self.eval(handle, target_node),
                };
            },
            .for_simple, .@"for" => return switch (try self.forLoop(handle, handle.tree.fullFor(node).?, true)) {
                .next => Type.fromIP(self.analyser, .void_type, .void_value),
                .value => |value| value,
                else => null,
            },
            .while_simple, .while_cont, .@"while" => return switch (try self.whileLoop(handle, ast.fullWhile(&handle.tree, node).?, true)) {
                .next => Type.fromIP(self.analyser, .void_type, .void_value),
                .value => |value| value,
                else => null,
            },
            .@"switch", .switch_comma => {
                const target = try self.switchTarget(handle, node) orelse return null;
                return self.eval(handle, target);
            },
            .@"orelse" => {
                const lhs, const rhs = handle.tree.nodeData(node).node_and_node;
                const optional = try self.eval(handle, lhs) orelse return null;
                return switch (try self.optionalValue(optional) orelse return null) {
                    .absent => self.eval(handle, rhs),
                    .payload => |payload| payload,
                };
            },
            .unwrap_optional => {
                const optional = try self.eval(handle, handle.tree.nodeData(node).node_and_token[0]) orelse return null;
                return switch (try self.optionalValue(optional) orelse return null) {
                    .absent => null,
                    .payload => |payload| payload,
                };
            },
            .bool_and, .bool_or => |tag| {
                const lhs, const rhs = handle.tree.nodeData(node).node_and_node;
                const lhs_value = try self.boolValue(try self.eval(handle, lhs) orelse return null) orelse return null;
                if (tag == .bool_and and !lhs_value) return Type.fromIP(self.analyser, .bool_type, .bool_false);
                if (tag == .bool_or and lhs_value) return Type.fromIP(self.analyser, .bool_type, .bool_true);
                const rhs_value = try self.eval(handle, rhs) orelse return null;
                _ = try self.boolValue(rhs_value) orelse return null;
                return rhs_value;
            },
            .mul,
            .div,
            .mod,
            .mul_wrap,
            .mul_sat,
            .add,
            .sub,
            .add_wrap,
            .sub_wrap,
            .add_sat,
            .sub_sat,
            .shl,
            .shl_sat,
            .shr,
            .bit_and,
            .bit_xor,
            .bit_or,
            => |tag| {
                const lhs, const rhs = handle.tree.nodeData(node).node_and_node;
                const lhs_value = try self.eval(handle, lhs) orelse return null;
                const rhs_value = try self.eval(handle, rhs) orelse return null;
                return self.analyser.resolveComptimeBinaryValue(tag, lhs_value, rhs_value);
            },
            .equal_equal,
            .bang_equal,
            .less_than,
            .greater_than,
            .less_or_equal,
            .greater_or_equal,
            => |tag| {
                const lhs, const rhs = handle.tree.nodeData(node).node_and_node;
                const lhs_value = try self.eval(handle, lhs) orelse return null;
                const rhs_value = try self.eval(handle, rhs) orelse return null;
                return self.analyser.resolveComptimeComparisonValue(tag, lhs_value, rhs_value) orelse
                    self.analyser.resolveTypeOfNode(.of(node, handle));
            },
            .bool_not, .bit_not, .negation, .negation_wrap => |tag| {
                const operand = try self.eval(handle, handle.tree.nodeData(node).node) orelse return null;
                return self.analyser.resolveComptimeUnaryValue(tag, operand);
            },
            .array_mult => {
                const operand_node, const multiplier_node = handle.tree.nodeData(node).node_and_node;
                const operand = try self.eval(handle, operand_node) orelse return null;
                const multiplier_value = try self.eval(handle, multiplier_node) orelse return null;
                const multiplier = self.analyser.ip.toInt(multiplier_value.ipIndex() orelse return null, u64) orelse return null;
                return self.analyser.resolveComptimeArrayMultValue(operand, multiplier);
            },
            .array_cat => {
                const lhs, const rhs = handle.tree.nodeData(node).node_and_node;
                const lhs_value = try self.eval(handle, lhs) orelse return null;
                const rhs_value = try self.eval(handle, rhs) orelse return null;
                return self.analyser.resolveComptimeArrayCatValue(lhs_value, rhs_value);
            },
            .field_access => {
                const base, const field_token = handle.tree.nodeData(node).node_and_token;
                const value = try self.eval(handle, base) orelse return null;
                const field_name = offsets.identifierTokenToNameSlice(&handle.tree, field_token);
                return self.analyser.resolveFieldAccess(value, field_name);
            },
            .array_access => {
                const base, const index_node = handle.tree.nodeData(node).node_and_node;
                const value = try self.eval(handle, base) orelse return null;
                const index = try self.integer(handle, index_node) orelse return null;
                return self.analyser.resolveBracketAccessType(value, .{ .single = index });
            },
            .slice, .slice_open, .slice_sentinel => {
                const slice = handle.tree.fullSlice(node).?;
                const value = try self.eval(handle, slice.ast.sliced) orelse return null;
                const start = try self.integer(handle, slice.ast.start) orelse return null;
                const end = if (slice.ast.end.unwrap()) |end_node|
                    try self.integer(handle, end_node) orelse return null
                else
                    null;
                const sentinel = if (slice.ast.sentinel.unwrap()) |sentinel_node|
                    (try self.eval(handle, sentinel_node) orelse return null).ipIndex() orelse return null
                else
                    .none;
                const access: Analyser.BracketAccess = if (end) |end_index|
                    .{ .range = .{
                        .bounds = .{ start, end_index },
                        .sentinel = sentinel,
                    } }
                else
                    .{ .open = .{ .start = start, .sentinel = sentinel } };
                return self.analyser.resolveBracketAccessType(value, access);
            },
            .deref => {
                const pointer = try self.eval(handle, handle.tree.nodeData(node).node) orelse return null;
                if (pointer.data == .comptime_value and pointer.data.comptime_value.data == .reference)
                    return self.readReference(pointer.data.comptime_value.data.reference);
                return self.analyser.resolveDerefType(pointer);
            },
            .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => {
                const name = handle.tree.tokenSlice(handle.tree.nodeMainToken(node));
                if (std.mem.eql(u8, name, "@as")) {
                    var buffer: [2]Ast.Node.Index = undefined;
                    const params = handle.tree.builtinCallParams(&buffer, node).?;
                    if (params.len != 2) return null;
                    const destination = try self.eval(handle, params[0]) orelse return null;
                    const value = try self.eval(handle, params[1]) orelse return null;
                    return self.coerce(destination, value);
                }
                if (std.mem.eql(u8, name, "@intFromEnum")) {
                    var buffer: [2]Ast.Node.Index = undefined;
                    const params = handle.tree.builtinCallParams(&buffer, node).?;
                    if (params.len != 1) return null;
                    const operand = try self.eval(handle, params[0]) orelse return null;
                    return self.analyser.resolveComptimeIntFromEnumValue(operand);
                }
                if (std.mem.eql(u8, name, "@intFromBool")) {
                    var buffer: [2]Ast.Node.Index = undefined;
                    const params = handle.tree.builtinCallParams(&buffer, node).?;
                    if (params.len != 1) return null;
                    const operand = try self.eval(handle, params[0]) orelse return null;
                    return self.analyser.resolveComptimeIntFromBoolValue(operand);
                }
                if (std.mem.eql(u8, name, "@tagName")) {
                    var buffer: [2]Ast.Node.Index = undefined;
                    const params = handle.tree.builtinCallParams(&buffer, node).?;
                    if (params.len != 1) return null;
                    const operand = try self.eval(handle, params[0]) orelse return null;
                    return self.analyser.resolveComptimeTagNameValue(operand);
                }
                if (std.mem.eql(u8, name, "@errorName")) {
                    var buffer: [2]Ast.Node.Index = undefined;
                    const params = handle.tree.builtinCallParams(&buffer, node).?;
                    if (params.len != 1) return null;
                    const operand = try self.eval(handle, params[0]) orelse return null;
                    return self.analyser.resolveComptimeErrorNameValue(operand);
                }
                if (std.mem.eql(u8, name, "@typeName")) {
                    var buffer: [2]Ast.Node.Index = undefined;
                    const params = handle.tree.builtinCallParams(&buffer, node).?;
                    if (params.len != 1) return null;
                    const operand = try self.eval(handle, params[0]) orelse return null;
                    return self.analyser.resolveComptimeTypeNameValue(operand);
                }
                if (std.mem.eql(u8, name, "@typeInfo")) {
                    var buffer: [2]Ast.Node.Index = undefined;
                    const params = handle.tree.builtinCallParams(&buffer, node).?;
                    if (params.len != 1) return null;
                    const operand = try self.eval(handle, params[0]) orelse return null;
                    return self.analyser.resolveComptimeTypeInfoValue(operand);
                }
                if (std.mem.eql(u8, name, "@min") or std.mem.eql(u8, name, "@max")) {
                    var buffer: [2]Ast.Node.Index = undefined;
                    const params = handle.tree.builtinCallParams(&buffer, node).?;
                    if (params.len < 2) return null;
                    const operands = try self.analyser.arena.alloc(Type, params.len);
                    for (params, operands) |param, *operand| {
                        operand.* = try self.eval(handle, param) orelse return null;
                    }
                    const kind: Analyser.ComptimeMinMaxKind = if (std.mem.eql(u8, name, "@min")) .min else .max;
                    return self.analyser.resolveComptimeMinMaxValue(operands, kind);
                }
                if (std.mem.eql(u8, name, "@abs")) {
                    var buffer: [2]Ast.Node.Index = undefined;
                    const params = handle.tree.builtinCallParams(&buffer, node).?;
                    if (params.len != 1) return null;
                    const operand = try self.eval(handle, params[0]) orelse return null;
                    return self.analyser.resolveComptimeAbsValue(operand);
                }
                if (std.mem.eql(u8, name, "@mulAdd")) {
                    var buffer: [2]Ast.Node.Index = undefined;
                    const params = handle.tree.builtinCallParams(&buffer, node).?;
                    if (params.len != 4) return null;
                    const result_type = try self.eval(handle, params[0]) orelse return null;
                    const a = try self.eval(handle, params[1]) orelse return null;
                    const b = try self.eval(handle, params[2]) orelse return null;
                    const c = try self.eval(handle, params[3]) orelse return null;
                    return self.analyser.resolveComptimeMulAddValue(result_type, a, b, c);
                }
                if (std.mem.eql(u8, name, "@select")) {
                    var buffer: [2]Ast.Node.Index = undefined;
                    const params = handle.tree.builtinCallParams(&buffer, node).?;
                    if (params.len != 4) return null;
                    const element_type = try self.eval(handle, params[0]) orelse return null;
                    const predicate = try self.eval(handle, params[1]) orelse return null;
                    const lhs = try self.eval(handle, params[2]) orelse return null;
                    const rhs = try self.eval(handle, params[3]) orelse return null;
                    return self.analyser.resolveComptimeSelectValue(element_type, predicate, lhs, rhs);
                }
                if (std.mem.eql(u8, name, "@sin") or
                    std.mem.eql(u8, name, "@cos") or
                    std.mem.eql(u8, name, "@tan") or
                    std.mem.eql(u8, name, "@exp") or
                    std.mem.eql(u8, name, "@exp2") or
                    std.mem.eql(u8, name, "@log") or
                    std.mem.eql(u8, name, "@log2") or
                    std.mem.eql(u8, name, "@log10") or
                    std.mem.eql(u8, name, "@sqrt") or
                    std.mem.eql(u8, name, "@floor") or
                    std.mem.eql(u8, name, "@ceil") or
                    std.mem.eql(u8, name, "@trunc") or
                    std.mem.eql(u8, name, "@round"))
                {
                    var buffer: [2]Ast.Node.Index = undefined;
                    const params = handle.tree.builtinCallParams(&buffer, node).?;
                    if (params.len != 1) return null;
                    const operand = try self.eval(handle, params[0]) orelse return null;
                    const kind: Analyser.ComptimeFloatUnaryKind = if (std.mem.eql(u8, name, "@sin"))
                        .sin
                    else if (std.mem.eql(u8, name, "@cos"))
                        .cos
                    else if (std.mem.eql(u8, name, "@tan"))
                        .tan
                    else if (std.mem.eql(u8, name, "@exp"))
                        .exp
                    else if (std.mem.eql(u8, name, "@exp2"))
                        .exp2
                    else if (std.mem.eql(u8, name, "@log"))
                        .log
                    else if (std.mem.eql(u8, name, "@log2"))
                        .log2
                    else if (std.mem.eql(u8, name, "@log10"))
                        .log10
                    else if (std.mem.eql(u8, name, "@sqrt"))
                        .sqrt
                    else if (std.mem.eql(u8, name, "@floor"))
                        .floor
                    else if (std.mem.eql(u8, name, "@ceil"))
                        .ceil
                    else if (std.mem.eql(u8, name, "@trunc"))
                        .trunc
                    else
                        .round;
                    return self.analyser.resolveComptimeFloatUnaryValue(operand, kind);
                }
                if (std.mem.eql(u8, name, "@hasField") or std.mem.eql(u8, name, "@hasDecl")) {
                    var buffer: [2]Ast.Node.Index = undefined;
                    const params = handle.tree.builtinCallParams(&buffer, node).?;
                    if (params.len != 2) return null;
                    const container_type = try self.eval(handle, params[0]) orelse return null;
                    const name_value = try self.eval(handle, params[1]) orelse return null;
                    if (name_value.data != .string_value) return null;
                    const kind: Analyser.ComptimeMemberKind = if (std.mem.eql(u8, name, "@hasField"))
                        .field
                    else
                        .declaration;
                    return self.analyser.resolveComptimeMemberPresenceValue(
                        container_type,
                        name_value.data.string_value.bytes,
                        kind,
                    );
                }
                if (std.mem.eql(u8, name, "@clz") or
                    std.mem.eql(u8, name, "@ctz") or
                    std.mem.eql(u8, name, "@popCount"))
                {
                    var buffer: [2]Ast.Node.Index = undefined;
                    const params = handle.tree.builtinCallParams(&buffer, node).?;
                    if (params.len != 1) return null;
                    const operand = try self.eval(handle, params[0]) orelse return null;
                    const kind: Analyser.ComptimeBitCountKind = if (std.mem.eql(u8, name, "@clz"))
                        .clz
                    else if (std.mem.eql(u8, name, "@ctz"))
                        .ctz
                    else
                        .pop_count;
                    return self.analyser.resolveComptimeBitCountValue(operand, kind);
                }
                if (std.mem.eql(u8, name, "@bitReverse") or std.mem.eql(u8, name, "@byteSwap")) {
                    var buffer: [2]Ast.Node.Index = undefined;
                    const params = handle.tree.builtinCallParams(&buffer, node).?;
                    if (params.len != 1) return null;
                    const operand = try self.eval(handle, params[0]) orelse return null;
                    const kind: Analyser.ComptimeBitPermutationKind = if (std.mem.eql(u8, name, "@bitReverse"))
                        .bit_reverse
                    else
                        .byte_swap;
                    return self.analyser.resolveComptimeBitPermutationValue(operand, kind);
                }
                if (std.mem.eql(u8, name, "@shlExact") or std.mem.eql(u8, name, "@shrExact")) {
                    var buffer: [2]Ast.Node.Index = undefined;
                    const params = handle.tree.builtinCallParams(&buffer, node).?;
                    if (params.len != 2) return null;
                    const operand = try self.eval(handle, params[0]) orelse return null;
                    const shift_operand = try self.eval(handle, params[1]) orelse return null;
                    const kind: Analyser.ComptimeExactShiftKind = if (std.mem.eql(u8, name, "@shlExact"))
                        .shl_exact
                    else
                        .shr_exact;
                    return self.analyser.resolveComptimeExactShiftValue(operand, shift_operand, kind);
                }
                if (std.mem.eql(u8, name, "@divTrunc") or
                    std.mem.eql(u8, name, "@divFloor") or
                    std.mem.eql(u8, name, "@divExact") or
                    std.mem.eql(u8, name, "@mod") or
                    std.mem.eql(u8, name, "@rem"))
                {
                    var buffer: [2]Ast.Node.Index = undefined;
                    const params = handle.tree.builtinCallParams(&buffer, node).?;
                    if (params.len != 2) return null;
                    const lhs = try self.eval(handle, params[0]) orelse return null;
                    const rhs = try self.eval(handle, params[1]) orelse return null;
                    const kind: Analyser.ComptimeDivisionKind = if (std.mem.eql(u8, name, "@divTrunc"))
                        .div_trunc
                    else if (std.mem.eql(u8, name, "@divFloor"))
                        .div_floor
                    else if (std.mem.eql(u8, name, "@divExact"))
                        .div_exact
                    else if (std.mem.eql(u8, name, "@mod"))
                        .mod
                    else
                        .rem;
                    if (try self.analyser.resolveComptimeDivisionValue(lhs, rhs, kind)) |value| return value;
                }
                if (std.mem.eql(u8, name, "@sizeOf") or
                    std.mem.eql(u8, name, "@bitSizeOf") or
                    std.mem.eql(u8, name, "@alignOf"))
                {
                    var buffer: [2]Ast.Node.Index = undefined;
                    const params = handle.tree.builtinCallParams(&buffer, node).?;
                    if (params.len != 1) return null;
                    const operand = try self.eval(handle, params[0]) orelse return null;
                    const kind: Analyser.ComptimeTypeSizeKind = if (std.mem.eql(u8, name, "@sizeOf"))
                        .byte_size
                    else if (std.mem.eql(u8, name, "@bitSizeOf"))
                        .bit_size
                    else
                        .alignment;
                    return self.analyser.resolveComptimeTypeSizeValue(operand, kind);
                }
            },
            .call, .call_comma, .call_one, .call_one_comma => {
                if (try self.callValue(handle, node)) |value| return value;
            },
            else => {},
        }
        return self.analyser.resolveTypeOfNode(.of(node, handle));
    }

    fn integer(self: *Interpreter, handle: *Handle, node: Ast.Node.Index) Error!?usize {
        const value = try self.eval(handle, node) orelse return null;
        return self.analyser.ip.toInt(value.ipIndex() orelse return null, usize);
    }

    fn coerce(self: *Interpreter, destination: Type, value: Type) Error!?Type {
        if (!destination.is_type_val) return null;
        const type_index = destination.ipIndex() orelse return value;
        if (type_index == .type_type) return value;
        const value_index = value.ipIndex() orelse return value;
        const coerced = try self.analyser.coerceIP(type_index, value_index) orelse return null;
        return Type.fromIP(self.analyser, type_index, coerced);
    }

    fn bind(self: *Interpreter, handle: *Handle, token: Ast.TokenIndex, value: Type) Error!void {
        try self.bindings.put(self.analyser.arena, .{ .handle = handle, .token = token }, value);
    }

    pub fn cell(self: *Interpreter, handle: *Handle, node: Ast.Node.Index) Error!?*Value.Cell {
        const tree = &handle.tree;
        if (tree.nodeTag(node) != .identifier) return null;
        const token = tree.nodeMainToken(node);
        const name = offsets.identifierTokenToNameSlice(tree, token);
        const decl = try self.analyser.lookupSymbolGlobal(handle, name, tree.tokenStart(token)) orelse return null;
        return self.cells.get(.{ .handle = decl.handle, .token = decl.nameToken() });
    }

    pub fn read(self: *Interpreter, handle: *Handle, node: Ast.Node.Index) Error!?Type {
        const storage = try self.cell(handle, node) orelse return null;
        return storage.value;
    }

    pub fn address(self: *Interpreter, handle: *Handle, node: Ast.Node.Index) Error!?Type {
        const target = try self.referenceForNode(handle, node) orelse return null;
        return self.referenceValue(target);
    }

    fn referenceValue(self: *Interpreter, target: *Value.Reference) Error!?Type {
        const current = try self.readReference(target) orelse return null;
        const ty = try self.analyser.resolveAddressOf(false, current);
        return try Value.create(self.analyser, try ty.typeOf(self.analyser), .{ .reference = target });
    }

    fn referenceForNode(self: *Interpreter, handle: *Handle, node: Ast.Node.Index) Error!?*Value.Reference {
        if (try self.cell(handle, node)) |storage| {
            const result = try self.analyser.arena.create(Value.Reference);
            result.* = .{ .storage = storage, .path = &.{} };
            return result;
        }
        const tree = &handle.tree;
        switch (tree.nodeTag(node)) {
            .array_access => {
                const base, const index_node = tree.nodeData(node).node_and_node;
                const parent = try self.aggregateReference(handle, base) orelse return null;
                const current = try self.readReference(parent) orelse return null;
                const items = try self.mutableElements(current) orelse return null;
                const index = try self.integer(handle, index_node) orelse return null;
                if (index >= items.len) return null;
                return self.extendReference(parent, .{ .index = index });
            },
            .field_access => {
                const base, const field_token = tree.nodeData(node).node_and_token;
                const parent = try self.aggregateReference(handle, base) orelse return null;
                const current = try self.readReference(parent) orelse return null;
                const field_name = offsets.identifierTokenToNameSlice(tree, field_token);
                const aggregate_type = try current.typeOf(self.analyser);
                if (aggregate_type.isTupleType(self.analyser)) {
                    const index = std.fmt.parseUnsigned(usize, field_name, 10) catch return null;
                    const items = try self.mutableElements(current) orelse return null;
                    if (index >= items.len) return null;
                    return self.extendReference(parent, .{ .index = index });
                }
                if (try self.analyser.resolveFieldAccess(current, field_name) == null) return null;
                return self.extendReference(parent, .{ .field = field_name });
            },
            .unwrap_optional => {
                const base = tree.nodeData(node).node_and_token[0];
                const parent = try self.aggregateReference(handle, base) orelse return null;
                const current = try self.readReference(parent) orelse return null;
                if (try self.analyser.resolveOptionalUnwrap(current) == null) return null;
                return self.extendReference(parent, .optional_payload);
            },
            .deref => {
                const pointer = try self.eval(handle, tree.nodeData(node).node) orelse return null;
                if (pointer.data != .comptime_value or pointer.data.comptime_value.data != .reference) return null;
                return pointer.data.comptime_value.data.reference;
            },
            .grouped_expression => return self.referenceForNode(handle, tree.nodeData(node).node_and_token[0]),
            else => return null,
        }
    }

    fn aggregateReference(self: *Interpreter, handle: *Handle, node: Ast.Node.Index) Error!?*Value.Reference {
        const value = try self.eval(handle, node) orelse return null;
        if (value.data == .comptime_value and value.data.comptime_value.data == .reference)
            return value.data.comptime_value.data.reference;
        return self.referenceForNode(handle, node);
    }

    fn extendReference(self: *Interpreter, reference_value: *Value.Reference, access: Value.Reference.Access) Error!*Value.Reference {
        const path = try self.analyser.arena.alloc(Value.Reference.Access, reference_value.path.len + 1);
        @memcpy(path[0..reference_value.path.len], reference_value.path);
        path[reference_value.path.len] = access;
        const result = try self.analyser.arena.create(Value.Reference);
        result.* = .{ .storage = reference_value.storage, .path = path };
        return result;
    }

    pub fn readReference(self: *Interpreter, target: *Value.Reference) Error!?Type {
        var current = target.storage.value;
        for (target.path) |access| {
            current = switch (access) {
                .index => |index| blk: {
                    const items = try self.mutableElements(current) orelse return null;
                    if (index >= items.len) return null;
                    break :blk items[index];
                },
                .field => |name| try self.analyser.resolveFieldAccess(current, name) orelse return null,
                .optional_payload => try self.analyser.resolveOptionalUnwrap(current) orelse return null,
            };
        }
        return current;
    }

    fn writeReference(self: *Interpreter, target: *Value.Reference, value: Type) Error!bool {
        target.storage.value = try self.replaceReferenceValue(target.storage.value, target.path, value) orelse return false;
        return true;
    }

    fn replaceReferenceValue(
        self: *Interpreter,
        current: Type,
        path: []const Value.Reference.Access,
        value: Type,
    ) Error!?Type {
        if (path.len == 0) return value;
        const analyser = self.analyser;
        const aggregate_type = try current.typeOf(analyser);
        switch (path[0]) {
            .index => |index| {
                const items = try self.mutableElements(current) orelse return null;
                if (index >= items.len) return null;
                const updated = try analyser.arena.dupe(Type, items);
                updated[index] = try self.replaceReferenceValue(items[index], path[1..], value) orelse return null;
                return try Value.create(analyser, aggregate_type, .{ .array = updated });
            },
            .field => |field_name| {
                const old_value = try analyser.resolveFieldAccess(current, field_name) orelse return null;
                const new_value = try self.replaceReferenceValue(old_value, path[1..], value) orelse return null;
                const fields = Value.fieldEntries(current) orelse return null;
                const updated = try analyser.arena.dupe(Value.Field, fields);
                for (updated) |*field| {
                    if (!std.mem.eql(u8, field.name, field_name)) continue;
                    field.value = new_value;
                    return try Value.create(analyser, aggregate_type, .{ .fields = updated });
                }
                if (!aggregate_type.isStructType(analyser)) return null;
                if (try analyser.lookupSymbolContainer(try aggregate_type.instanceUnchecked(analyser), field_name, .field) == null) return null;
                const extended = try analyser.arena.alloc(Value.Field, fields.len + 1);
                @memcpy(extended[0..fields.len], fields);
                extended[fields.len] = .{ .name = field_name, .value = new_value };
                return try Value.create(analyser, aggregate_type, .{ .fields = extended });
            },
            .optional_payload => {
                const old_value = try analyser.resolveOptionalUnwrap(current) orelse return null;
                const new_value = try self.replaceReferenceValue(old_value, path[1..], value) orelse return null;
                return try Value.create(analyser, aggregate_type, .{ .optional = new_value });
            },
        }
    }

    fn bindOptionalPointerPayload(
        self: *Interpreter,
        handle: *Handle,
        condition: Ast.Node.Index,
        payload_token: Ast.TokenIndex,
    ) Error!bool {
        if (handle.tree.tokenTag(payload_token) != .asterisk) return true;
        const optional = try self.referenceForNode(handle, condition) orelse return false;
        const payload = try self.extendReference(optional, .optional_payload);
        const value = try self.referenceValue(payload) orelse return false;
        try self.bind(handle, payload_token + 1, value);
        return true;
    }

    fn bindSwitchPointerPayload(
        self: *Interpreter,
        handle: *Handle,
        switch_node: Ast.full.Switch,
        selected_case: Ast.full.SwitchCase,
        payload_token: Ast.TokenIndex,
    ) Error!bool {
        const tree = &handle.tree;
        if (tree.tokenTag(payload_token) != .asterisk) return true;
        const union_reference = try self.referenceForNode(handle, switch_node.ast.condition) orelse return false;
        const union_value = try self.readReference(union_reference) orelse return false;
        const active_field = try self.analyser.resolveKnownUnionFieldName(union_value) orelse return false;
        for (selected_case.ast.values) |case_value| {
            if (tree.nodeTag(case_value) != .enum_literal) continue;
            const case_name = offsets.identifierTokenToNameSlice(tree, tree.nodeMainToken(case_value));
            if (!std.mem.eql(u8, active_field, case_name)) continue;
            const payload_reference = try self.extendReference(union_reference, .{ .field = active_field });
            const value = try self.referenceValue(payload_reference) orelse return false;
            try self.bind(handle, payload_token + 1, value);
            return true;
        }
        return false;
    }

    fn deref(self: *Interpreter, value: Type) Error!?Type {
        if (value.data == .comptime_value and value.data.comptime_value.data == .reference)
            return self.readReference(value.data.comptime_value.data.reference);
        return value;
    }

    fn optionalValue(self: *Interpreter, value: Type) Error!?OptionalValue {
        const resolved = try self.deref(value) orelse return null;
        if (resolved.data == .comptime_value) {
            return switch (resolved.data.comptime_value.data) {
                .optional => |payload| if (payload) |item| .{ .payload = item } else .absent,
                else => null,
            };
        }
        const payload = switch (resolved.data) {
            .ip_index => |payload| payload,
            else => return null,
        };
        const index = payload.index orelse return null;
        return switch (self.analyser.ip.indexToKey(index)) {
            .null_value => .absent,
            .optional_value => |optional| .{
                .payload = Type.fromIP(self.analyser, self.analyser.ip.typeOf(optional.val), optional.val),
            },
            else => null,
        };
    }

    fn boolValue(self: *Interpreter, value: Type) Error!?bool {
        const resolved = try self.deref(value) orelse return null;
        const index = resolved.ipIndex() orelse return null;
        return switch (index) {
            .bool_false => false,
            .bool_true => true,
            else => null,
        };
    }

    fn mutableElements(self: *Interpreter, value: Type) Error!?[]const Type {
        if (Value.elements(value)) |items| return items;
        const payload = switch (value.data) {
            .ip_index => |payload| payload,
            else => return null,
        };
        const type_key = self.analyser.ip.indexToKey(payload.type);
        switch (type_key) {
            .array_type, .vector_type, .tuple_type => {},
            else => return null,
        }
        const values = if (payload.index) |value_index| blk: {
            const aggregate = switch (self.analyser.ip.indexToKey(value_index)) {
                .aggregate => |aggregate| aggregate,
                else => return null,
            };
            if (aggregate.ty != payload.type) return null;
            break :blk aggregate.values;
        } else switch (type_key) {
            .tuple_type => |tuple| tuple.values,
            else => return null,
        };
        const items = try self.analyser.arena.alloc(Type, values.len);
        for (items, 0..) |*item, index| {
            const item_index = values.at(@intCast(index), self.analyser.ip);
            if (item_index == .none or self.analyser.ip.isUndefined(item_index) or self.analyser.ip.isUnknown(item_index)) return null;
            item.* = Type.fromIP(self.analyser, self.analyser.ip.typeOf(item_index), item_index);
        }
        return items;
    }

    fn writeAggregate(self: *Interpreter, handle: *Handle, base: Ast.Node.Index, current: Type, updated: Type) Error!bool {
        if (current.data == .comptime_value and current.data.comptime_value.data == .reference) {
            return self.writeReference(current.data.comptime_value.data.reference, updated);
        }
        return self.write(handle, base, updated);
    }

    fn write(self: *Interpreter, handle: *Handle, node: Ast.Node.Index, value: Type) Error!bool {
        const analyser = self.analyser;
        const tree = &handle.tree;
        if (tree.nodeTag(node) == .array_access) {
            const base, const index_node = tree.nodeData(node).node_and_node;
            const base_value = try self.eval(handle, base) orelse return false;
            const current = try self.deref(base_value) orelse return false;
            const items = try self.mutableElements(current) orelse return false;
            const index = try self.integer(handle, index_node) orelse return false;
            if (index >= items.len) return false;
            const updated = try analyser.arena.dupe(Type, items);
            updated[index] = value;
            const updated_value = try Value.create(analyser, try current.typeOf(analyser), .{ .array = updated });
            return self.writeAggregate(handle, base, base_value, updated_value);
        }
        if (tree.nodeTag(node) == .field_access) {
            const base, const field_token = tree.nodeData(node).node_and_token;
            const base_value = try self.eval(handle, base) orelse return false;
            const current = try self.deref(base_value) orelse return false;
            const field_name = offsets.identifierTokenToNameSlice(tree, field_token);
            const aggregate_type = try current.typeOf(analyser);
            if (aggregate_type.isTupleType(analyser)) {
                const index = std.fmt.parseUnsigned(usize, field_name, 10) catch return false;
                const items = try self.mutableElements(current) orelse return false;
                if (index >= items.len) return false;
                const updated = try analyser.arena.dupe(Type, items);
                updated[index] = value;
                const updated_value = try Value.create(analyser, aggregate_type, .{ .array = updated });
                return self.writeAggregate(handle, base, base_value, updated_value);
            }
            const fields = Value.fieldEntries(current) orelse return false;
            const updated = try analyser.arena.dupe(Value.Field, fields);
            for (updated) |*field| {
                if (!std.mem.eql(u8, field.name, field_name)) continue;
                field.value = value;
                const updated_value = try Value.create(analyser, aggregate_type, .{ .fields = updated });
                return self.writeAggregate(handle, base, base_value, updated_value);
            }
            if (!aggregate_type.isStructType(analyser)) return false;
            if (try analyser.lookupSymbolContainer(try aggregate_type.instanceUnchecked(analyser), field_name, .field) == null) return false;
            const extended = try analyser.arena.alloc(Value.Field, fields.len + 1);
            @memcpy(extended[0..fields.len], fields);
            extended[fields.len] = .{ .name = field_name, .value = value };
            const updated_value = try Value.create(analyser, aggregate_type, .{ .fields = extended });
            return self.writeAggregate(handle, base, base_value, updated_value);
        }
        if (tree.nodeTag(node) == .unwrap_optional) {
            const base = tree.nodeData(node).node_and_token[0];
            const base_value = try self.eval(handle, base) orelse return false;
            const current = try self.deref(base_value) orelse return false;
            const aggregate_type = try current.typeOf(analyser);
            if (try analyser.resolveOptionalUnwrap(current) == null) return false;
            const updated_value = try Value.create(analyser, aggregate_type, .{ .optional = value });
            return self.writeAggregate(handle, base, base_value, updated_value);
        }
        if (tree.nodeTag(node) == .deref) {
            const pointer = try self.eval(handle, tree.nodeData(node).node) orelse return false;
            if (pointer.data != .comptime_value or pointer.data.comptime_value.data != .reference) return false;
            return self.writeReference(pointer.data.comptime_value.data.reference, value);
        }
        const storage = try self.cell(handle, node) orelse return false;
        storage.value = value;
        return true;
    }

    fn captureBindings(self: *Interpreter, value: Type) Error!Type {
        var result = value;
        if (result.data != .container or (self.bindings.count() == 0 and self.cells.count() == 0)) return result;

        var info = result.data.container;
        var bindings = try info.bound_params.clone(self.analyser.arena);
        for (self.bindings.keys(), self.bindings.values()) |token_handle, bound| {
            try bindings.put(self.analyser.arena, token_handle, bound);
        }
        for (self.cells.keys(), self.cells.values()) |token_handle, storage| {
            try bindings.put(self.analyser.arena, token_handle, storage.value);
        }
        info.bound_params = bindings;
        result.data = .{ .container = info };
        return result;
    }

    fn declare(self: *Interpreter, handle: *Handle, decl: Ast.full.VarDecl, initial_value: Type) Error!bool {
        const analyser = self.analyser;
        const tree = &handle.tree;
        var value = initial_value;
        if (decl.ast.type_node.unwrap()) |type_node| {
            const ty = try self.eval(handle, type_node) orelse return false;
            if (tree.fullArrayType(type_node)) |array| {
                const len = try self.integer(handle, array.ast.elem_count) orelse return false;
                if (len > self.budget.steps) return false;
                if (Value.elements(value) == null) {
                    const items = try analyser.arena.alloc(Type, len);
                    @memset(items, Type.fromIP(analyser, .undefined_type, .undefined_value));
                    value = try Value.create(analyser, ty, .{ .array = items });
                }
            } else if (!ty.isMetaType() and value.data != .comptime_value and !value.is_type_val) {
                if (ty.ipIndex()) |type_index| {
                    if (value.ipIndex()) |index| {
                        const coerced = try analyser.coerceIP(type_index, index) orelse return false;
                        value = Type.fromIP(analyser, type_index, coerced);
                    } else value = try ty.instanceTypeVal(analyser) orelse value;
                }
            }
        }
        const token = decl.ast.mut_token + 1;
        if (tree.tokenTag(decl.ast.mut_token) == .keyword_var) {
            const storage = try analyser.arena.create(Value.Cell);
            storage.* = .{ .value = value };
            try self.cells.put(analyser.arena, .{ .handle = handle, .token = token }, storage);
        }
        try self.bind(handle, token, value);
        return true;
    }

    fn block(self: *Interpreter, handle: *Handle, node: Ast.Node.Index) Error!Flow {
        const tree = &handle.tree;
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, node) orelse return .unknown;
        var executed_count: usize = 0;
        var block_flow: Flow = .next;
        for (statements) |child| {
            executed_count += 1;
            if (tree.nodeTag(child) == .@"defer") continue;
            const flow = try self.statement(handle, child);
            switch (flow) {
                .next => {},
                .stopped => |stopped| {
                    const label_token = ast.blockLabel(tree, node) orelse {
                        block_flow = flow;
                        break;
                    };
                    const target_token = stopped.target orelse {
                        block_flow = flow;
                        break;
                    };
                    block_flow = if (std.mem.eql(u8, tree.tokenSlice(label_token), tree.tokenSlice(target_token)))
                        if (stopped.value) |value| .{ .value = value } else .next
                    else
                        flow;
                    break;
                },
                else => {
                    block_flow = flow;
                    break;
                },
            }
        }
        while (executed_count > 0) {
            executed_count -= 1;
            const child = statements[executed_count];
            if (tree.nodeTag(child) != .@"defer") continue;
            if (try self.statement(handle, tree.nodeData(child).node) != .next) return .unknown;
        }
        return block_flow;
    }

    fn ifTarget(self: *Interpreter, handle: *Handle, node: Ast.Node.Index) Error!?BranchTarget {
        const branch = ast.fullIf(&handle.tree, node).?;
        if (branch.error_token != null) return null;
        const known = try self.analyser.resolveIfConditionValue(.of(branch.ast.cond_expr, handle)) orelse return null;
        if (known) if (branch.payload_token) |payload_token| {
            if (!try self.bindOptionalPointerPayload(handle, branch.ast.cond_expr, payload_token)) return null;
        };
        return if (known)
            .{ .node = branch.ast.then_expr }
        else if (branch.ast.else_expr.unwrap()) |else_node|
            .{ .node = else_node }
        else
            .none;
    }

    fn switchTarget(self: *Interpreter, handle: *Handle, node: Ast.Node.Index) Error!?Ast.Node.Index {
        const tree = &handle.tree;
        const switch_node = tree.switchFull(node);
        if (switch_node.label_token != null) return null;
        const target = try self.analyser.resolveKnownSwitchTarget(.of(node, handle)) orelse return null;
        for (switch_node.ast.cases) |case| {
            const switch_case = tree.fullSwitchCase(case).?;
            if (switch_case.ast.target_expr != target) continue;
            if (switch_case.payload_token) |payload_token| {
                if (!try self.bindSwitchPointerPayload(handle, switch_node, switch_case, payload_token)) return null;
                const name_token = payload_token + @intFromBool(tree.tokenTag(payload_token) == .asterisk);
                if (tree.tokenTag(name_token + 1) == .comma) {
                    const condition = try self.eval(handle, switch_node.ast.condition) orelse return null;
                    if (try self.analyser.resolveKnownUnionFieldName(condition) == null) return null;
                }
            }
            return target;
        }
        return null;
    }

    fn statement(self: *Interpreter, handle: *Handle, node: Ast.Node.Index) Error!Flow {
        if (!self.tick()) return .unknown;
        const analyser = self.analyser;
        const tree = &handle.tree;
        var buffer: [2]Ast.Node.Index = undefined;
        if (tree.blockStatements(&buffer, node) != null) {
            return switch (try self.block(handle, node)) {
                .value => .next,
                else => |flow| flow,
            };
        }
        if (tree.fullVarDecl(node)) |decl| {
            const init_node = decl.ast.init_node.unwrap() orelse return .unknown;
            const value = try self.eval(handle, init_node) orelse Type.unknown_type;
            if (!try self.declare(handle, decl, value)) return .unknown;
            return .next;
        }
        switch (tree.nodeTag(node)) {
            .@"comptime", .@"nosuspend" => return self.statement(handle, tree.nodeData(node).node),
            .@"return" => return .{ .returned = if (tree.nodeData(node).opt_node.unwrap()) |expression|
                try self.captureBindings(try self.eval(handle, expression) orelse return .unknown)
            else
                Type.fromIP(analyser, .void_type, .void_value) },
            .@"continue" => {
                const label, const operand = tree.nodeData(node).opt_token_and_opt_node;
                if (operand != .none) return .unknown;
                return .{ .continued = label.unwrap() };
            },
            .@"break" => {
                const label, const operand = tree.nodeData(node).opt_token_and_opt_node;
                const value = if (operand.unwrap()) |expression|
                    try self.captureBindings(try self.eval(handle, expression) orelse return .unknown)
                else
                    null;
                return .{ .stopped = .{ .target = label.unwrap(), .value = value } };
            },
            .if_simple, .@"if" => {
                const target = try self.ifTarget(handle, node) orelse return .unknown;
                return switch (target) {
                    .none => .next,
                    .node => |target_node| self.statement(handle, target_node),
                };
            },
            .for_simple, .@"for" => return self.forLoop(handle, tree.fullFor(node).?, false),
            .while_simple, .while_cont, .@"while" => return self.whileLoop(handle, ast.fullWhile(tree, node).?, false),
            .@"switch", .switch_comma => {
                const target = try self.switchTarget(handle, node) orelse return .unknown;
                return self.statement(handle, target);
            },
            .assign => {
                const lhs, const rhs = tree.nodeData(node).node_and_node;
                if (tree.nodeTag(lhs) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(lhs)), "_")) {
                    _ = try self.eval(handle, rhs);
                    return .next;
                }
                const value = try self.eval(handle, rhs) orelse return .unknown;
                if (!try self.write(handle, lhs, value)) return .unknown;
                return .next;
            },
            .assign_destructure => {
                const assignment = tree.assignDestructure(node);
                const value = try self.eval(handle, assignment.ast.value_expr) orelse return .unknown;
                const items = try self.mutableElements(value) orelse return .unknown;
                if (items.len != assignment.ast.variables.len) return .unknown;
                for (assignment.ast.variables, items) |lhs, item| {
                    if (tree.fullVarDecl(lhs)) |decl| {
                        if (!try self.declare(handle, decl, item)) return .unknown;
                        continue;
                    }
                    if (tree.nodeTag(lhs) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(lhs)), "_")) continue;
                    if (!try self.write(handle, lhs, item)) return .unknown;
                }
                return .next;
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
            => |assignment_tag| {
                const lhs, const rhs = tree.nodeData(node).node_and_node;
                const operation_tag: Ast.Node.Tag = switch (assignment_tag) {
                    .assign_mul => .mul,
                    .assign_div => .div,
                    .assign_mod => .mod,
                    .assign_add => .add,
                    .assign_sub => .sub,
                    .assign_shl => .shl,
                    .assign_shl_sat => .shl_sat,
                    .assign_shr => .shr,
                    .assign_bit_and => .bit_and,
                    .assign_bit_xor => .bit_xor,
                    .assign_bit_or => .bit_or,
                    .assign_mul_wrap => .mul_wrap,
                    .assign_add_wrap => .add_wrap,
                    .assign_sub_wrap => .sub_wrap,
                    .assign_mul_sat => .mul_sat,
                    .assign_add_sat => .add_sat,
                    .assign_sub_sat => .sub_sat,
                    else => unreachable,
                };
                const lhs_value = try self.eval(handle, lhs) orelse return .unknown;
                const rhs_value = try self.eval(handle, rhs) orelse return .unknown;
                const value = try analyser.resolveComptimeBinaryValue(operation_tag, lhs_value, rhs_value) orelse return .unknown;
                if (!try self.write(handle, lhs, value)) return .unknown;
                return .next;
            },
            .call, .call_comma, .call_one, .call_one_comma => return self.call(handle, node),
            else => return .unknown,
        }
    }

    fn targetsLoop(tree: *const Ast, label_token: ?Ast.TokenIndex, target: ?Ast.TokenIndex) bool {
        const target_token = target orelse return true;
        const loop_label_token = label_token orelse return false;
        return std.mem.eql(u8, tree.tokenSlice(loop_label_token), tree.tokenSlice(target_token));
    }

    fn forLoop(self: *Interpreter, handle: *Handle, loop_node: Ast.full.For, expression: bool) Error!Flow {
        const analyser = self.analyser;
        const tree = &handle.tree;
        const Input = union(enum) {
            sequence: struct {
                value: Type,
                reference: ?*Value.Reference,
            },
            range: usize,
        };
        const inputs = try analyser.arena.alloc(Input, loop_node.ast.inputs.len);
        var len: ?usize = null;
        for (loop_node.ast.inputs, inputs) |input, *resolved| {
            var count: ?usize = null;
            if (tree.nodeTag(input) == .for_range) {
                const start_node, const end_node = tree.nodeData(input).node_and_opt_node;
                const start = try self.integer(handle, start_node) orelse return .unknown;
                resolved.* = .{ .range = start };
                if (end_node.unwrap()) |end| {
                    const end_value = try self.integer(handle, end) orelse return .unknown;
                    count = std.math.sub(usize, end_value, start) catch return .unknown;
                }
            } else {
                const evaluated = try self.eval(handle, input) orelse return .unknown;
                const reference = if (evaluated.data == .comptime_value and evaluated.data.comptime_value.data == .reference)
                    evaluated.data.comptime_value.data.reference
                else
                    null;
                const sequence = if (reference) |target| try self.readReference(target) orelse return .unknown else evaluated;
                resolved.* = .{ .sequence = .{ .value = sequence, .reference = reference } };
                const length = try analyser.resolveFieldAccess(sequence, "len") orelse return .unknown;
                count = analyser.ip.toInt(length.ipIndex() orelse return .unknown, usize) orelse return .unknown;
            }
            if (count) |n| {
                if (len != null and len.? != n) return .unknown;
                len = n;
            }
        }
        const count = len orelse return .unknown;
        if (count > self.budget.steps) return .unknown;
        for (0..count) |index| {
            var token = loop_node.payload_token;
            for (inputs) |input| {
                const capture_by_ref = tree.tokenTag(token) == .asterisk;
                const name_token = token + @intFromBool(capture_by_ref);
                const value = switch (input) {
                    .sequence => |sequence| if (capture_by_ref) blk: {
                        const reference = sequence.reference orelse return .unknown;
                        const element = try self.extendReference(reference, .{ .index = index });
                        break :blk try self.referenceValue(element) orelse return .unknown;
                    } else try analyser.resolveBracketAccessType(sequence.value, .{ .single = index }) orelse return .unknown,
                    .range => |start| if (capture_by_ref) return .unknown else Type.fromIP(analyser, .comptime_int_type, try analyser.ip.get(.{ .int_u64_value = .{
                        .ty = .comptime_int_type,
                        .int = std.math.add(usize, start, index) catch return .unknown,
                    } })),
                };
                try self.bind(handle, name_token, value);
                token = name_token + 2;
            }
            const flow = try self.statement(handle, loop_node.ast.then_expr);
            switch (flow) {
                .next => {},
                .continued => |target| if (!targetsLoop(tree, loop_node.label_token, target)) return flow,
                .stopped => |stopped| {
                    if (!targetsLoop(tree, loop_node.label_token, stopped.target)) return flow;
                    if (stopped.value) |value| return if (expression) .{ .value = value } else .unknown;
                    return .next;
                },
                .value, .returned, .unknown => return flow,
            }
        }
        if (loop_node.ast.else_expr.unwrap()) |else_node| {
            if (expression) return .{ .value = try self.eval(handle, else_node) orelse return .unknown };
            return self.statement(handle, else_node);
        }
        return .next;
    }

    fn whileLoop(self: *Interpreter, handle: *Handle, loop_node: Ast.full.While, expression: bool) Error!Flow {
        if (loop_node.error_token != null) return .unknown;
        while (true) {
            const condition = try self.analyser.resolveIfConditionValue(.of(loop_node.ast.cond_expr, handle)) orelse return .unknown;
            if (!condition) {
                if (loop_node.ast.else_expr.unwrap()) |else_node| {
                    if (expression) return .{ .value = try self.eval(handle, else_node) orelse return .unknown };
                    return self.statement(handle, else_node);
                }
                return .next;
            }
            if (loop_node.payload_token) |payload_token| {
                if (!try self.bindOptionalPointerPayload(handle, loop_node.ast.cond_expr, payload_token)) return .unknown;
            }

            const flow = try self.statement(handle, loop_node.ast.then_expr);
            switch (flow) {
                .next => {},
                .continued => |target| if (!targetsLoop(&handle.tree, loop_node.label_token, target)) return flow,
                .stopped => |stopped| {
                    if (!targetsLoop(&handle.tree, loop_node.label_token, stopped.target)) return flow;
                    if (stopped.value) |value| return if (expression) .{ .value = value } else .unknown;
                    return .next;
                },
                .value => return .unknown,
                .returned => |value| return .{ .returned = value },
                .unknown => return .unknown,
            }
            if (loop_node.ast.cont_expr.unwrap()) |cont_expr| {
                if (try self.statement(handle, cont_expr) != .next) return .unknown;
            }
        }
    }

    fn invoke(self: *Interpreter, handle: *Handle, node: Ast.Node.Index) Error!Flow {
        const analyser = self.analyser;
        var buffer: [1]Ast.Node.Index = undefined;
        const call_node = handle.tree.fullCall(&buffer, node).?;
        const callable = try self.eval(handle, call_node.ast.fn_expr) orelse return .unknown;
        const function = try analyser.resolveFuncProtoOfCallable(callable) orelse return .unknown;
        const info = function.data.function;
        if (info.parameters.len != call_node.ast.params.len or info.handle.tree.nodeTag(info.fn_node) != .fn_decl) return .unknown;
        var child: Interpreter = .{
            .analyser = analyser,
            .bindings = if (info.container_type.data == .container)
                try info.container_type.data.container.bound_params.clone(analyser.arena)
            else
                .empty,
            .budget = self.budget,
        };
        if (info.container_type.data == .container) {
            const display_params = &info.container_type.data.container.display_params;
            for (display_params.keys(), display_params.values()) |token_handle, node_handle| {
                const value = try analyser.resolveComptimeDisplayArgument(token_handle, node_handle) orelse continue;
                try child.bindings.put(analyser.arena, token_handle, value);
            }
        }
        for (info.parameters, call_node.ast.params) |parameter, argument| {
            var value = if (parameter.modifier == .comptime_param and parameter.type.data != .anytype_parameter)
                try analyser.resolveAggregateComptimeArgument(parameter.type, handle, argument) orelse try self.eval(handle, argument) orelse return .unknown
            else
                try self.eval(handle, argument) orelse return .unknown;
            if (parameter.modifier == .comptime_param and parameter.type.is_type_val) {
                value = try self.coerce(parameter.type, value) orelse return .unknown;
            }
            try child.bind(info.handle, parameter.name_token orelse return .unknown, value);
            if (parameter.type.data == .anytype_parameter) {
                try child.bindings.put(analyser.arena, parameter.type.data.anytype_parameter.token_handle, try value.typeOf(analyser));
            }
        }
        return child.run(info.handle, info.handle.tree.nodeData(info.fn_node).node_and_node[1]);
    }

    fn callValue(self: *Interpreter, handle: *Handle, node: Ast.Node.Index) Error!?Type {
        return switch (try self.invoke(handle, node)) {
            .returned => |value| value,
            else => null,
        };
    }

    fn call(self: *Interpreter, handle: *Handle, node: Ast.Node.Index) Error!Flow {
        return switch (try self.invoke(handle, node)) {
            .next, .returned => .next,
            else => .unknown,
        };
    }
};
