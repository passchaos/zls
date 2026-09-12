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
        reference: *Cell,
        /// Source-backed value used when an aggregate element cannot be
        /// materialized by the intern pool but can still be copied at comptime.
        expression: Analyser.NodeWithHandle,
    },

    pub const Field = struct { name: []const u8, value: Type };
    pub const Cell = struct { value: Type };

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
            .reference => |cell| std.hash.autoHash(hasher, @intFromPtr(cell)),
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
            .reference => |cell| return cell == other.data.reference,
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
        if (value.data == .comptime_value and value.data.comptime_value.data == .reference)
            return value.data.comptime_value.data.reference.value;
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
    const Flow = union(enum) { next, returned: Type, continued: ?Ast.TokenIndex, stopped: ?Ast.TokenIndex, unknown };

    pub fn needed(handle: *Handle, body: Ast.Node.Index) bool {
        const tree = &handle.tree;
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, body) orelse return false;
        for (statements) |node| {
            if (tree.fullVarDecl(node)) |decl| {
                if (tree.tokenTag(decl.ast.mut_token) == .keyword_var) return true;
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
        switch (handle.tree.nodeTag(node)) {
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
        const storage = try self.cell(handle, node) orelse return null;
        const ty = try self.analyser.resolveAddressOf(false, storage.value);
        return try Value.create(self.analyser, try ty.typeOf(self.analyser), .{ .reference = storage });
    }

    fn mutationStorage(self: *Interpreter, handle: *Handle, node: Ast.Node.Index) Error!?*Value.Cell {
        if (try self.cell(handle, node)) |storage| {
            if (storage.value.data == .comptime_value and storage.value.data.comptime_value.data == .reference) {
                return storage.value.data.comptime_value.data.reference;
            }
            return storage;
        }
        const pointer = try self.eval(handle, node) orelse return null;
        if (pointer.data != .comptime_value or pointer.data.comptime_value.data != .reference) return null;
        return pointer.data.comptime_value.data.reference;
    }

    fn mutableElements(self: *Interpreter, value: Type) Error!?[]const Type {
        if (Value.elements(value)) |items| return items;
        const payload = switch (value.data) {
            .ip_index => |payload| payload,
            else => return null,
        };
        const value_index = payload.index orelse return null;
        const aggregate = switch (self.analyser.ip.indexToKey(value_index)) {
            .aggregate => |aggregate| aggregate,
            else => return null,
        };
        if (aggregate.ty != payload.type) return null;
        switch (self.analyser.ip.indexToKey(payload.type)) {
            .array_type, .vector_type, .tuple_type => {},
            else => return null,
        }
        const items = try self.analyser.arena.alloc(Type, aggregate.values.len);
        for (items, 0..) |*item, index| {
            const item_index = aggregate.values.at(@intCast(index), self.analyser.ip);
            item.* = Type.fromIP(self.analyser, self.analyser.ip.typeOf(item_index), item_index);
        }
        return items;
    }

    fn write(self: *Interpreter, handle: *Handle, node: Ast.Node.Index, value: Type) Error!bool {
        const analyser = self.analyser;
        const tree = &handle.tree;
        if (tree.nodeTag(node) == .array_access) {
            const base, const index_node = tree.nodeData(node).node_and_node;
            const storage = try self.mutationStorage(handle, base) orelse return false;
            const current = storage.value;
            const items = try self.mutableElements(current) orelse return false;
            const index = try self.integer(handle, index_node) orelse return false;
            if (index >= items.len) return false;
            const updated = try analyser.arena.dupe(Type, items);
            updated[index] = value;
            storage.value = try Value.create(analyser, try current.typeOf(analyser), .{ .array = updated });
            return true;
        }
        if (tree.nodeTag(node) == .field_access) {
            const base, const field_token = tree.nodeData(node).node_and_token;
            const storage = try self.mutationStorage(handle, base) orelse return false;
            const current = storage.value;
            const fields = Value.fieldEntries(current) orelse return false;
            const field_name = offsets.identifierTokenToNameSlice(tree, field_token);
            const updated = try analyser.arena.dupe(Value.Field, fields);
            for (updated) |*field| {
                if (!std.mem.eql(u8, field.name, field_name)) continue;
                field.value = value;
                storage.value = try Value.create(analyser, try current.typeOf(analyser), .{ .fields = updated });
                return true;
            }
            return false;
        }
        if (tree.nodeTag(node) == .deref) {
            const storage = try self.mutationStorage(handle, tree.nodeData(node).node) orelse return false;
            storage.value = value;
            return true;
        }
        const storage = try self.cell(handle, node) orelse return false;
        storage.value = value;
        return true;
    }

    fn captureCells(self: *Interpreter, value: Type) Error!Type {
        var result = value;
        if (result.data != .container or self.cells.count() == 0) return result;

        var info = result.data.container;
        var bindings = try info.bound_params.clone(self.analyser.arena);
        for (self.cells.keys(), self.cells.values()) |token_handle, storage| {
            try bindings.put(self.analyser.arena, token_handle, storage.value);
        }
        info.bound_params = bindings;
        result.data = .{ .container = info };
        return result;
    }

    fn statement(self: *Interpreter, handle: *Handle, node: Ast.Node.Index) Error!Flow {
        if (!self.tick()) return .unknown;
        const analyser = self.analyser;
        const tree = &handle.tree;
        var buffer: [2]Ast.Node.Index = undefined;
        if (tree.blockStatements(&buffer, node)) |statements| {
            for (statements) |child| {
                const flow = try self.statement(handle, child);
                switch (flow) {
                    .next => {},
                    .stopped => |target| {
                        const label_token = ast.blockLabel(tree, node) orelse return flow;
                        const target_token = target orelse return flow;
                        if (!std.mem.eql(u8, tree.tokenSlice(label_token), tree.tokenSlice(target_token))) return flow;
                        return .next;
                    },
                    else => return flow,
                }
            }
            return .next;
        }
        if (tree.fullVarDecl(node)) |decl| {
            const init_node = decl.ast.init_node.unwrap() orelse return .unknown;
            var value = try self.eval(handle, init_node) orelse Type.unknown_type;
            if (decl.ast.type_node.unwrap()) |type_node| {
                const ty = try self.eval(handle, type_node) orelse return .unknown;
                if (tree.fullArrayType(type_node)) |array| {
                    const len = try self.integer(handle, array.ast.elem_count) orelse return .unknown;
                    if (len > self.budget.steps) return .unknown;
                    if (Value.elements(value) == null) {
                        const items = try analyser.arena.alloc(Type, len);
                        @memset(items, Type.fromIP(analyser, .undefined_type, .undefined_value));
                        value = try Value.create(analyser, ty, .{ .array = items });
                    }
                } else if (!ty.isMetaType() and value.data != .comptime_value and !value.is_type_val) {
                    if (ty.ipIndex()) |type_index| {
                        if (value.ipIndex()) |index| {
                            const coerced = try analyser.coerceIP(type_index, index) orelse return .unknown;
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
            return .next;
        }
        switch (tree.nodeTag(node)) {
            .@"comptime" => return self.statement(handle, tree.nodeData(node).node),
            .@"return" => return .{ .returned = if (tree.nodeData(node).opt_node.unwrap()) |expression|
                try self.captureCells(try self.eval(handle, expression) orelse return .unknown)
            else
                Type.fromIP(analyser, .void_type, .void_value) },
            .@"continue" => {
                const label, const operand = tree.nodeData(node).opt_token_and_opt_node;
                if (operand != .none) return .unknown;
                return .{ .continued = label.unwrap() };
            },
            .@"break" => {
                const label, const operand = tree.nodeData(node).opt_token_and_opt_node;
                if (operand != .none) return .unknown;
                return .{ .stopped = label.unwrap() };
            },
            .if_simple, .@"if" => {
                const branch = ast.fullIf(tree, node).?;
                if (branch.error_token != null) return .unknown;
                if (branch.payload_token) |payload_token| {
                    if (tree.tokenTag(payload_token) == .asterisk) return .unknown;
                }
                const known = try analyser.resolveIfConditionValue(.of(branch.ast.cond_expr, handle)) orelse return .unknown;
                return self.statement(handle, if (known) branch.ast.then_expr else branch.ast.else_expr.unwrap() orelse return .next);
            },
            .for_simple, .@"for" => return self.forLoop(handle, tree.fullFor(node).?),
            .while_simple, .while_cont, .@"while" => return self.whileLoop(handle, ast.fullWhile(tree, node).?),
            .@"switch", .switch_comma => {
                const switch_node = tree.switchFull(node);
                if (switch_node.label_token != null) return .unknown;
                const target = try analyser.resolveKnownSwitchTarget(.of(node, handle)) orelse return .unknown;
                for (switch_node.ast.cases) |case| {
                    const switch_case = tree.fullSwitchCase(case).?;
                    if (switch_case.ast.target_expr != target) continue;
                    if (switch_case.payload_token) |payload_token| {
                        if (tree.tokenTag(payload_token) == .asterisk) return .unknown;
                        if (tree.tokenTag(payload_token + 1) == .comma) {
                            const condition = try self.eval(handle, switch_node.ast.condition) orelse return .unknown;
                            if (try analyser.resolveKnownUnionFieldName(condition) == null) return .unknown;
                        }
                    }
                }
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

    fn forLoop(self: *Interpreter, handle: *Handle, loop_node: Ast.full.For) Error!Flow {
        const analyser = self.analyser;
        const tree = &handle.tree;
        const Input = union(enum) { sequence: Type, range: usize };
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
                const sequence = try self.eval(handle, input) orelse return .unknown;
                resolved.* = .{ .sequence = sequence };
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
                if (tree.tokenTag(token) == .asterisk) return .unknown;
                const value = switch (input) {
                    .sequence => |sequence| try analyser.resolveBracketAccessType(sequence, .{ .single = index }) orelse return .unknown,
                    .range => |start| Type.fromIP(analyser, .comptime_int_type, try analyser.ip.get(.{ .int_u64_value = .{
                        .ty = .comptime_int_type,
                        .int = std.math.add(usize, start, index) catch return .unknown,
                    } })),
                };
                try self.bind(handle, token, value);
                token += 2;
            }
            const flow = try self.statement(handle, loop_node.ast.then_expr);
            switch (flow) {
                .next => {},
                .continued => |target| if (!targetsLoop(tree, loop_node.label_token, target)) return flow,
                .stopped => |target| return if (targetsLoop(tree, loop_node.label_token, target)) .next else flow,
                .returned, .unknown => return flow,
            }
        }
        if (loop_node.ast.else_expr.unwrap()) |else_node| return self.statement(handle, else_node);
        return .next;
    }

    fn whileLoop(self: *Interpreter, handle: *Handle, loop_node: Ast.full.While) Error!Flow {
        if (loop_node.error_token != null) return .unknown;
        if (loop_node.payload_token) |payload_token| {
            if (handle.tree.tokenTag(payload_token) == .asterisk) return .unknown;
        }
        while (true) {
            const condition = try self.analyser.resolveIfConditionValue(.of(loop_node.ast.cond_expr, handle)) orelse return .unknown;
            if (!condition) {
                if (loop_node.ast.else_expr.unwrap()) |else_node| return self.statement(handle, else_node);
                return .next;
            }

            const flow = try self.statement(handle, loop_node.ast.then_expr);
            switch (flow) {
                .next => {},
                .continued => |target| if (!targetsLoop(&handle.tree, loop_node.label_token, target)) return flow,
                .stopped => |target| return if (targetsLoop(&handle.tree, loop_node.label_token, target)) .next else flow,
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
            const value = if (parameter.modifier == .comptime_param and parameter.type.data != .anytype_parameter)
                try analyser.resolveAggregateComptimeArgument(parameter.type, handle, argument) orelse try self.eval(handle, argument) orelse return .unknown
            else
                try self.eval(handle, argument) orelse return .unknown;
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
