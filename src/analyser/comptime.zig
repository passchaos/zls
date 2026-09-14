const std = @import("std");
const builtin = @import("builtin");
const Analyser = @import("../analysis.zig");
const ast = @import("../ast.zig");
const offsets = @import("../offsets.zig");
const Ast = std.zig.Ast;
const Type = Analyser.Type;
const Handle = @import("../DocumentStore.zig").Handle;
const Error = Analyser.Error;
const InternPool = @import("InternPool.zig");

pub const Value = struct {
    ty: Type,
    data: union(enum) {
        array: []const Type,
        sequence: Sequence,
        fields: []const Field,
        optional: ?Type,
        error_union: ErrorUnion,
        reference: *Reference,
        pointee: Pointee,
        /// Source-backed value used when an aggregate element cannot be
        /// materialized by the intern pool but can still be copied at comptime.
        expression: Analyser.NodeWithHandle,
    },

    pub const Field = struct { name: []const u8, value: Type };
    pub const Sequence = struct {
        backing: []const Type,
        offset: usize,
        len: usize,
        elements_valid: bool,
        origin: ?Pointee = null,

        fn sameBacking(self: Sequence, other: Sequence, analyser: *Analyser) ?bool {
            if (self.origin) |origin| {
                const other_origin = other.origin orelse return null;
                return origin.eql(other_origin);
            } else if (other.origin != null) return null;
            if (self.backing.ptr == other.backing.ptr) return true;
            for (self.backing) |item| if (!isKnown(item, analyser, 0)) return null;
            for (other.backing) |item| if (!isKnown(item, analyser, 0)) return null;
            if (self.backing.len != other.backing.len) return false;
            for (self.backing, other.backing) |lhs, rhs| if (!lhs.eql(rhs)) return false;
            return true;
        }

        fn sameAddress(self: Sequence, other: Sequence, analyser: *Analyser) ?bool {
            return (self.sameBacking(other, analyser) orelse return null) and self.offset == other.offset;
        }
    };
    pub const ErrorUnion = union(enum) {
        payload: Type,
        failure: Type,
    };
    pub const Cell = struct { value: Type };
    pub const Pointee = struct {
        value: Type,
        source: Analyser.NodeWithHandle,
        container_type: ?Type,
        path: []const Reference.Access,
        is_static: bool,

        fn hash(self: Pointee, hasher: anytype) void {
            std.hash.autoHash(hasher, self.is_static);
            if (!self.is_static) self.value.hashWithHasher(hasher);
            std.hash.autoHash(hasher, self.source.node);
            hasher.update(self.source.handle.uri.raw);
            std.hash.autoHash(hasher, self.container_type != null);
            if (self.container_type) |container_type| container_type.hashWithHasher(hasher);
            hashPath(self.path, hasher);
        }

        fn eql(self: Pointee, other: Pointee) bool {
            if (!self.source.eql(other.source) or
                self.is_static != other.is_static or
                (self.container_type == null) != (other.container_type == null) or
                self.path.len != other.path.len) return false;
            if (!self.is_static and !self.value.eql(other.value)) return false;
            if (self.container_type) |container_type| {
                if (!container_type.eql(other.container_type.?)) return false;
            }
            for (self.path, other.path) |lhs, rhs| {
                if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return false;
                switch (lhs) {
                    .field => |name| if (!std.mem.eql(u8, name, rhs.field)) return false,
                    .index => |index| if (index != rhs.index) return false,
                    .optional_payload, .error_union_payload => {},
                }
            }
            return true;
        }
    };
    pub const Reference = struct {
        storage: *Cell,
        path: []const Access,

        pub const Access = union(enum) {
            field: []const u8,
            index: usize,
            optional_payload,
            error_union_payload,
        };

        fn hash(self: Reference, hasher: anytype) void {
            std.hash.autoHash(hasher, @intFromPtr(self.storage));
            for (self.path) |access| {
                std.hash.autoHash(hasher, std.meta.activeTag(access));
                switch (access) {
                    .field => |name| hasher.update(name),
                    .index => |index| std.hash.autoHash(hasher, index),
                    .optional_payload, .error_union_payload => {},
                }
            }
        }

        fn eql(self: Reference, other: Reference) bool {
            if (self.storage != other.storage or self.path.len != other.path.len) return false;
            return pathEql(self.path, other.path);
        }
    };

    pub fn hash(self: *const Value, hasher: anytype) void {
        self.ty.hashWithHasher(hasher);
        std.hash.autoHash(hasher, std.meta.activeTag(self.data));
        switch (self.data) {
            .array => |items| for (items) |item| item.hashWithHasher(hasher),
            .sequence => |view| {
                for (view.backing) |item| item.hashWithHasher(hasher);
                std.hash.autoHash(hasher, view.offset);
                std.hash.autoHash(hasher, view.len);
                std.hash.autoHash(hasher, view.elements_valid);
                std.hash.autoHash(hasher, view.origin != null);
                if (view.origin) |origin| origin.hash(hasher);
            },
            .fields => |fields| {
                var fields_hash: u64 = 0;
                for (fields) |entry| {
                    var field_hasher: std.hash.Wyhash = .init(0);
                    field_hasher.update(entry.name);
                    entry.value.hashWithHasher(&field_hasher);
                    fields_hash +%= field_hasher.final();
                }
                std.hash.autoHash(hasher, fields.len);
                std.hash.autoHash(hasher, fields_hash);
            },
            .optional => |payload| {
                std.hash.autoHash(hasher, payload != null);
                if (payload) |value| value.hashWithHasher(hasher);
            },
            .error_union => |value| {
                std.hash.autoHash(hasher, std.meta.activeTag(value));
                switch (value) {
                    inline else => |item| item.hashWithHasher(hasher),
                }
            },
            .reference => |reference| reference.hash(hasher),
            .pointee => |pointee| pointee.hash(hasher),
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
            .sequence => |view| {
                const other_sequence = other.data.sequence;
                if (view.offset != other_sequence.offset or view.len != other_sequence.len or
                    view.elements_valid != other_sequence.elements_valid or
                    (view.origin == null) != (other_sequence.origin == null) or
                    view.backing.len != other_sequence.backing.len) return false;
                if (view.origin) |origin| if (!origin.eql(other_sequence.origin.?)) return false;
                for (view.backing, other_sequence.backing) |a, b| if (!a.eql(b)) return false;
            },
            .fields => |fields| {
                if (fields.len != other.data.fields.len) return false;
                for (fields) |a| for (other.data.fields) |b| {
                    if (!std.mem.eql(u8, a.name, b.name)) continue;
                    if (!a.value.eql(b.value)) return false;
                    break;
                } else return false;
            },
            .optional => |payload| {
                if ((payload == null) != (other.data.optional == null)) return false;
                if (payload) |value| if (!value.eql(other.data.optional.?)) return false;
            },
            .error_union => |value| {
                if (std.meta.activeTag(value) != std.meta.activeTag(other.data.error_union)) return false;
                return switch (value) {
                    .payload => |item| item.eql(other.data.error_union.payload),
                    .failure => |item| item.eql(other.data.error_union.failure),
                };
            },
            .reference => |reference| return reference.eql(other.data.reference.*),
            .pointee => |pointee| return pointee.eql(other.data.pointee),
            .expression => |node_handle| return node_handle.eql(other.data.expression),
        }
        return true;
    }

    fn isKnown(value: Type, analyser: *Analyser, depth: u8) bool {
        if (depth == 128) return false;
        return switch (value.data) {
            .ip_index => |payload| if (payload.index) |index|
                !analyser.ip.isUndefined(index) and !analyser.ip.isUnknown(index)
            else
                false,
            .enum_value, .string_value, .type_info_value => true,
            .comptime_value => |comptime_value| switch (comptime_value.data) {
                .array => |items| for (items) |item| {
                    if (!isKnown(item, analyser, depth + 1)) break false;
                } else true,
                .sequence => |view| for (view.backing) |item| {
                    if (!isKnown(item, analyser, depth + 1)) break false;
                } else true,
                .fields => |fields| for (fields) |entry| {
                    if (!isKnown(entry.value, analyser, depth + 1)) break false;
                } else true,
                .optional => |payload| if (payload) |item| isKnown(item, analyser, depth + 1) else true,
                .error_union => |result| switch (result) {
                    inline else => |item| isKnown(item, analyser, depth + 1),
                },
                .reference, .pointee => true,
                .expression => false,
            },
            else => value.is_type_val,
        };
    }

    pub fn pointerIdentityEql(analyser: *Analyser, lhs: Type, rhs: Type) ?bool {
        return pointerIdentityEqlDepth(analyser, lhs, rhs, 0);
    }

    fn hasPointerIdentity(value: Type, depth: u8) bool {
        if (depth == 128 or value.data != .comptime_value) return false;
        return switch (value.data.comptime_value.data) {
            .reference, .pointee, .sequence => true,
            .optional => |payload| if (payload) |item| hasPointerIdentity(item, depth + 1) else false,
            else => false,
        };
    }

    fn pointerIdentityEqlDepth(analyser: *Analyser, lhs: Type, rhs: Type, depth: u8) ?bool {
        if (depth == 128) return null;
        const lhs_type = lhs.typeOf(analyser) catch return null;
        const rhs_type = rhs.typeOf(analyser) catch return null;
        if (!lhs_type.hasComparablePointerIdentity(analyser, rhs_type)) return null;
        if (lhs.ipIndex()) |index| {
            if (analyser.ip.isNull(index) and hasPointerIdentity(rhs, depth + 1)) return false;
        }
        if (rhs.ipIndex()) |index| {
            if (analyser.ip.isNull(index) and hasPointerIdentity(lhs, depth + 1)) return false;
        }
        if (lhs.data == .comptime_value and lhs.data.comptime_value.data == .optional) {
            return if (lhs.data.comptime_value.data.optional) |payload|
                pointerIdentityEqlDepth(analyser, payload, rhs, depth + 1)
            else if (hasPointerIdentity(rhs, depth + 1)) false else null;
        }
        if (rhs.data == .comptime_value and rhs.data.comptime_value.data == .optional) {
            return if (rhs.data.comptime_value.data.optional) |payload|
                pointerIdentityEqlDepth(analyser, lhs, payload, depth + 1)
            else if (hasPointerIdentity(lhs, depth + 1)) false else null;
        }
        if (lhs.data != .comptime_value or rhs.data != .comptime_value) return null;
        switch (lhs.data.comptime_value.data) {
            .reference => |lhs_reference| switch (rhs.data.comptime_value.data) {
                .reference => |rhs_reference| return lhs_reference.eql(rhs_reference.*),
                else => {},
            },
            .pointee => |lhs_pointee| switch (rhs.data.comptime_value.data) {
                .pointee => |rhs_pointee| return lhs_pointee.eql(rhs_pointee),
                else => {},
            },
            else => {},
        }
        if (lhs.data.comptime_value.ty.isManyPointerType(analyser) and
            rhs.data.comptime_value.ty.isManyPointerType(analyser))
        {
            if (sequence(lhs)) |lhs_sequence| {
                if (sequence(rhs)) |rhs_sequence|
                    return lhs_sequence.sameAddress(rhs_sequence, analyser);
            }
        }
        return switch (lhs.data.comptime_value.data) {
            .reference => |lhs_reference| switch (rhs.data.comptime_value.data) {
                .reference => |rhs_reference| lhs_reference.eql(rhs_reference.*),
                else => null,
            },
            .pointee => |lhs_pointee| switch (rhs.data.comptime_value.data) {
                .pointee => |rhs_pointee| lhs_pointee.eql(rhs_pointee),
                else => null,
            },
            .sequence => |lhs_sequence| switch (rhs.data.comptime_value.data) {
                .sequence => |rhs_sequence| lhs_sequence.sameAddress(rhs_sequence, analyser),
                else => null,
            },
            else => null,
        };
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
        if (value.data == .comptime_value) {
            return switch (value.data.comptime_value.data) {
                .reference => |reference| if (reference.path.len == 0) reference.storage.value else value,
                .pointee => |pointee| pointee.value,
                else => value,
            };
        }
        return value;
    }

    pub fn elements(value: Type) ?[]const Type {
        const resolved = deref(value);
        if (resolved.data != .comptime_value) return null;
        return switch (resolved.data.comptime_value.data) {
            .array => |items| items,
            .sequence => |view| if (view.elements_valid) view.backing[view.offset..][0..view.len] else null,
            else => null,
        };
    }

    pub fn sequence(value: Type) ?Sequence {
        const resolved = deref(value);
        if (resolved.data != .comptime_value) return null;
        return switch (resolved.data.comptime_value.data) {
            .array => |items| .{ .backing = items, .offset = 0, .len = items.len, .elements_valid = true },
            .sequence => |sequence_value| sequence_value,
            else => null,
        };
    }

    pub fn sequenceAlloc(analyser: *Analyser, value: Type) error{OutOfMemory}!?Sequence {
        if (value.data == .comptime_value and value.data.comptime_value.data == .pointee) {
            const pointee = value.data.comptime_value.data.pointee;
            const items = elements(pointee.value) orelse interned: {
                const payload = switch (pointee.value.data) {
                    .ip_index => |payload| payload,
                    else => return null,
                };
                const value_index = payload.index orelse return null;
                const aggregate = switch (analyser.ip.indexToKey(value_index)) {
                    .aggregate => |aggregate| aggregate,
                    else => return null,
                };
                const indices = try aggregate.values.dupe(analyser.arena, analyser.ip);
                const result = try analyser.arena.alloc(Type, indices.len);
                for (indices, result) |index, *item| {
                    item.* = Type.fromIP(analyser, analyser.ip.typeOf(index), index);
                }
                break :interned result;
            };
            return .{
                .backing = items,
                .offset = 0,
                .len = items.len,
                .elements_valid = true,
                .origin = pointee,
            };
        }
        if (sequence(value)) |sequence_value| return sequence_value;
        return null;
    }

    pub fn sequenceOffsetDifference(analyser: *Analyser, lhs: Type, rhs: Type) error{OutOfMemory}!?usize {
        const lhs_sequence = try sequenceAlloc(analyser, lhs) orelse return null;
        const rhs_sequence = try sequenceAlloc(analyser, rhs) orelse return null;
        if (!(lhs_sequence.sameBacking(rhs_sequence, analyser) orelse return null)) return null;
        return std.math.sub(usize, lhs_sequence.offset, rhs_sequence.offset) catch null;
    }

    pub fn pointerOffsetDifference(analyser: *Analyser, lhs: Type, rhs: Type) error{OutOfMemory}!?usize {
        if (lhs.data != .comptime_value or rhs.data != .comptime_value) return null;
        const lhs_pointer = lhs.data.comptime_value.ty.instanceUnchecked(analyser) catch return null;
        const rhs_pointer = rhs.data.comptime_value.ty.instanceUnchecked(analyser) catch return null;
        if (!lhs.data.comptime_value.ty.hasSamePointerElementType(analyser, rhs.data.comptime_value.ty)) return null;
        switch (lhs_pointer.pointerSize(analyser) orelse return null) {
            .one, .many => {},
            .slice, .c => return null,
        }
        switch (rhs_pointer.pointerSize(analyser) orelse return null) {
            .one, .many => {},
            .slice, .c => return null,
        }
        if (try sequenceOffsetDifference(analyser, lhs, rhs)) |difference| return difference;
        return switch (lhs.data.comptime_value.data) {
            .reference => |lhs_reference| switch (rhs.data.comptime_value.data) {
                .reference => |rhs_reference| if (lhs_reference.storage == rhs_reference.storage)
                    pathOffsetDifference(lhs_reference.path, rhs_reference.path)
                else
                    null,
                else => null,
            },
            .pointee => |lhs_pointee| switch (rhs.data.comptime_value.data) {
                .pointee => |rhs_pointee| if (lhs_pointee.source.eql(rhs_pointee.source) and
                    optionalTypeEql(lhs_pointee.container_type, rhs_pointee.container_type))
                    pathOffsetDifference(lhs_pointee.path, rhs_pointee.path)
                else
                    null,
                else => null,
            },
            else => null,
        };
    }

    fn optionalTypeEql(lhs: ?Type, rhs: ?Type) bool {
        if ((lhs == null) != (rhs == null)) return false;
        return if (lhs) |lhs_type| lhs_type.eql(rhs.?) else true;
    }

    fn pathEql(lhs: []const Reference.Access, rhs: []const Reference.Access) bool {
        if (lhs.len != rhs.len) return false;
        for (lhs, rhs) |lhs_access, rhs_access| {
            if (std.meta.activeTag(lhs_access) != std.meta.activeTag(rhs_access)) return false;
            switch (lhs_access) {
                .field => |name| if (!std.mem.eql(u8, name, rhs_access.field)) return false,
                .index => |index| if (index != rhs_access.index) return false,
                .optional_payload, .error_union_payload => {},
            }
        }
        return true;
    }

    fn hashPath(path: []const Reference.Access, hasher: anytype) void {
        for (path) |access| {
            std.hash.autoHash(hasher, std.meta.activeTag(access));
            switch (access) {
                .field => |name| hasher.update(name),
                .index => |index| std.hash.autoHash(hasher, index),
                .optional_payload, .error_union_payload => {},
            }
        }
    }

    fn pathOffsetDifference(lhs: []const Reference.Access, rhs: []const Reference.Access) ?usize {
        if (lhs.len != rhs.len) return null;
        if (pathEql(lhs, rhs)) return 0;
        if (lhs.len == 0 or !pathEql(lhs[0 .. lhs.len - 1], rhs[0 .. rhs.len - 1])) return null;
        const lhs_index = switch (lhs[lhs.len - 1]) {
            .index => |index| index,
            else => return null,
        };
        const rhs_index = switch (rhs[rhs.len - 1]) {
            .index => |index| index,
            else => return null,
        };
        return std.math.sub(usize, lhs_index, rhs_index) catch null;
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
    container_type: ?Type = null,
    cells: std.array_hash_map.Custom(Analyser.TokenWithHandle, *Value.Cell, Analyser.TokenWithHandle.Context, true) = .empty,
    budget: *Budget,
    return_type: ?Type = null,
    pending_flow: ?Flow = null,
    break_context: ?*const BreakContext = null,

    const BreakContext = struct {
        parent: ?*const BreakContext,
        label: ?Ast.TokenIndex,
        destination: ?Type,
        is_loop: bool,
        preserve_capture_target: bool = false,
        continue_destination: ?Type = null,
        continue_by_ref: bool = false,
    };
    const ContinueResult = struct {
        value: Type,
        reference: ?*Value.Reference = null,
    };
    const default_step_quota = 8192;
    /// Keep editor requests bounded even when source code requests an enormous quota.
    const max_step_quota = 1_000_000;
    const Budget = struct {
        steps: usize = default_step_quota,
        quota: usize = default_step_quota,
        depth: usize = 0,
        expression_depth: usize = 0,

        fn raiseQuota(self: *Budget, requested: u32) void {
            const new_quota = @min(@as(usize, requested), max_step_quota);
            if (new_quota <= self.quota) return;
            self.steps += new_quota - self.quota;
            self.quota = new_quota;
        }
    };
    const Flow = union(enum) {
        next,
        value: EvaluatedSource,
        returned: EvaluatedSource,
        continued: struct { target: ?Ast.TokenIndex, result: ?ContinueResult },
        stopped: struct { target: ?Ast.TokenIndex, result: ?EvaluatedSource },
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
    const IntegerValue = union(enum) {
        known: u64,
        unknown,
    };
    const EvaluatedSource = struct {
        value: Type,
        source_node: ?Ast.Node.Index,
        capture_target: ?CaptureTarget = null,
    };

    pub fn needed(handle: *Handle, body: Ast.Node.Index) bool {
        return nodeNeedsEvaluation(&handle.tree, body, 0);
    }

    fn nodeNeedsEvaluation(tree: *const Ast, node: Ast.Node.Index, depth: u8) bool {
        if (depth == 128) return true;
        if (node != .root and ast.isContainer(tree, node)) return false;
        switch (tree.nodeTag(node)) {
            .fn_decl, .fn_proto, .fn_proto_one, .fn_proto_simple, .fn_proto_multi => return false,
            .@"comptime", .@"try", .@"catch", .@"orelse", .@"errdefer" => return true,
            .@"if" => {
                const branch = ast.fullIf(tree, node).?;
                if (branch.error_token != null or
                    if (branch.payload_token) |token| tree.tokenTag(token) == .asterisk else false) return true;
            },
            .@"while" => {
                const loop = ast.fullWhile(tree, node).?;
                if (loop.error_token != null or
                    if (loop.payload_token) |token| tree.tokenTag(token) == .asterisk else false) return true;
            },
            .@"for", .for_simple => {
                const loop = ast.fullFor(tree, node).?;
                var token = loop.payload_token;
                for (loop.ast.inputs) |_| {
                    if (tree.tokenTag(token) == .asterisk) return true;
                    token += 2;
                }
            },
            .@"switch", .switch_comma => {
                const switch_node = tree.switchFull(node);
                if (switch_node.label_token != null or switchHasPointerCapture(tree, switch_node)) return true;
            },
            .assign_destructure => {
                for (tree.assignDestructure(node).ast.variables) |lhs| {
                    if (tree.fullVarDecl(lhs) != null) return true;
                }
            },
            else => {},
        }
        if (tree.fullVarDecl(node)) |decl| {
            if (tree.tokenTag(decl.ast.mut_token) == .keyword_var) return true;
        }
        var iterator: ast.Iterator = .init(tree, node);
        while (iterator.next(tree)) |child| {
            if (nodeNeedsEvaluation(tree, child, depth + 1)) return true;
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
            .returned => |result| result.value,
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

    pub fn evaluateTyped(
        analyser: *Analyser,
        handle: *Handle,
        node: Ast.Node.Index,
        destination: Type,
    ) Error!?Type {
        if (analyser.comptime_interpreter) |interpreter|
            return interpreter.evaluateTypedExpression(handle, node, destination);
        var budget: Budget = .{};
        var interpreter: Interpreter = .{
            .analyser = analyser,
            .bindings = if (analyser.generic_bindings) |bindings| try bindings.clone(analyser.arena) else .empty,
            .budget = &budget,
        };
        if (!interpreter.enterExpression()) return null;
        defer interpreter.leaveExpression();
        const old_bindings = analyser.generic_bindings;
        const old_values = analyser.evaluate_comptime_values;
        const old_numbers = analyser.resolve_number_literal_values;
        const old_flow = analyser.evaluate_comptime_control_flow;
        analyser.comptime_interpreter = &interpreter;
        analyser.generic_bindings = &interpreter.bindings;
        analyser.evaluate_comptime_values = true;
        analyser.resolve_number_literal_values = true;
        analyser.evaluate_comptime_control_flow = true;
        defer {
            analyser.comptime_interpreter = null;
            analyser.generic_bindings = old_bindings;
            analyser.evaluate_comptime_values = old_values;
            analyser.resolve_number_literal_values = old_numbers;
            analyser.evaluate_comptime_control_flow = old_flow;
        }
        return interpreter.evaluateTypedExpression(handle, node, destination);
    }

    fn evaluateTypedWithContainer(
        self: *Interpreter,
        handle: *Handle,
        node: Ast.Node.Index,
        destination: Type,
        container_type: ?Type,
    ) Error!?Type {
        const analyser = self.analyser;
        var child: Interpreter = .{
            .analyser = analyser,
            .bindings = try self.bindings.clone(analyser.arena),
            .container_type = container_type orelse self.container_type,
            .budget = self.budget,
        };
        var display_bindings = if (analyser.display_bindings) |bindings|
            try bindings.clone(analyser.arena)
        else
            Analyser.TokenToNodeMap.empty;
        if (container_type) |container| {
            if (container.data == .container) {
                const info = container.data.container;
                for (info.bound_params.keys(), info.bound_params.values()) |key, value| {
                    try child.bindings.put(analyser.arena, key, value);
                }
                for (info.display_params.keys(), info.display_params.values()) |key, value| {
                    try display_bindings.put(analyser.arena, key, value);
                }
            }
        }
        if (!child.enterExpression()) return null;
        defer child.leaveExpression();
        const old_interpreter = analyser.comptime_interpreter;
        const old_bindings = analyser.generic_bindings;
        const old_display_bindings = analyser.display_bindings;
        analyser.comptime_interpreter = &child;
        analyser.generic_bindings = &child.bindings;
        analyser.display_bindings = &display_bindings;
        defer {
            analyser.comptime_interpreter = old_interpreter;
            analyser.generic_bindings = old_bindings;
            analyser.display_bindings = old_display_bindings;
        }
        return child.evaluateTypedExpression(handle, node, destination);
    }

    const StaticPointeeTarget = struct {
        declaration: Analyser.DeclWithHandle,
        path: []const Value.Reference.Access,
    };
    const CaptureTarget = union(enum) {
        reference: *Value.Reference,
        pointee: Value.Pointee,
    };
    const CaptureOperand = struct {
        value: Type,
        target: ?CaptureTarget,
    };

    fn captureOperand(
        self: *Interpreter,
        handle: *Handle,
        node: Ast.Node.Index,
        depth: u8,
    ) Error!?CaptureOperand {
        if (depth == 128) return null;
        const tree = &handle.tree;
        const unwrapped = unwrapGroupedSource(tree, node);
        var block_buffer: [2]Ast.Node.Index = undefined;
        if (tree.blockStatements(&block_buffer, unwrapped) != null) {
            if (!self.tick()) return null;
            const result = self.expressionResult(try self.block(handle, unwrapped, null, true)) orelse return null;
            return .{ .value = result.value, .target = result.capture_target };
        }
        if (tree.nodeTag(unwrapped) == .if_simple or tree.nodeTag(unwrapped) == .@"if") {
            return switch (try self.ifTarget(handle, unwrapped) orelse return null) {
                .node => |target| self.captureOperand(handle, target, depth + 1),
                .none => .{
                    .value = Type.fromIP(self.analyser, .void_type, .void_value),
                    .target = null,
                },
            };
        }
        if (tree.nodeTag(unwrapped) == .@"switch" or tree.nodeTag(unwrapped) == .switch_comma) {
            if (tree.switchFull(unwrapped).label_token != null) return null;
            const target = try self.switchTarget(handle, unwrapped) orelse return null;
            return self.captureOperand(handle, target, depth + 1);
        }
        if (tree.nodeTag(unwrapped) == .@"for" or tree.nodeTag(unwrapped) == .for_simple) {
            const result = self.expressionResult(try self.forLoop(
                handle,
                tree.fullFor(unwrapped).?,
                true,
                null,
                true,
            )) orelse return null;
            return .{ .value = result.value, .target = result.capture_target };
        }
        if (tree.nodeTag(unwrapped) == .@"while" or tree.nodeTag(unwrapped) == .while_simple or
            tree.nodeTag(unwrapped) == .while_cont)
        {
            const result = self.expressionResult(try self.whileLoop(
                handle,
                ast.fullWhile(tree, unwrapped).?,
                true,
                null,
                true,
            )) orelse return null;
            return .{ .value = result.value, .target = result.capture_target };
        }
        if (tree.nodeTag(unwrapped) == .array_access) {
            const base, const index_node = tree.nodeData(unwrapped).node_and_node;
            const base_operand = try self.captureOperand(handle, base, depth + 1) orelse return null;
            const index = try self.integer(handle, index_node) orelse return null;
            const value = try self.analyser.resolveBracketAccessType(base_operand.value, .{ .single = index }) orelse return null;
            if (try Value.sequenceAlloc(self.analyser, base_operand.value)) |sequence| {
                if (index >= sequence.len) return null;
                if (sequence.origin) |origin| {
                    const offset = std.math.add(usize, sequence.offset, index) catch return null;
                    return .{
                        .value = value,
                        .target = .{ .pointee = try self.extendPointee(origin, value, .{ .index = offset }) },
                    };
                }
            }
            const base_type = try base_operand.value.typeOf(self.analyser);
            const pointer_size = (try base_type.instanceUnchecked(self.analyser)).pointerSize(self.analyser);
            if (pointer_size == null) {
                return .{
                    .value = value,
                    .target = if (base_operand.target) |target|
                        try self.extendCaptureTarget(target, value, .{ .index = index })
                    else
                        null,
                };
            }
            return .{ .value = value, .target = null };
        }
        if (tree.nodeTag(unwrapped) == .field_access) {
            const base, const field_token = tree.nodeData(unwrapped).node_and_token;
            const base_operand = try self.captureOperand(handle, base, depth + 1) orelse return null;
            const field_name = offsets.identifierTokenToNameSlice(tree, field_token);
            const value = try self.analyser.resolveFieldAccess(base_operand.value, field_name) orelse return null;
            const target = try self.aggregateCaptureTarget(base_operand);
            if (target == null) return .{ .value = value, .target = null };
            const aggregate = try self.captureAggregateValue(base_operand.value);
            const aggregate_type = try aggregate.typeOf(self.analyser);
            if (aggregate_type.isTupleType(self.analyser)) {
                const index = std.fmt.parseUnsigned(usize, field_name, 10) catch return .{ .value = value, .target = null };
                return .{
                    .value = value,
                    .target = try self.extendCaptureTarget(target.?, value, .{ .index = index }),
                };
            }
            if (!aggregate_type.isStructType(self.analyser) and !aggregate_type.isUnionType()) {
                return .{ .value = value, .target = null };
            }
            return .{
                .value = value,
                .target = try self.extendCaptureTarget(target.?, value, .{ .field = field_name }),
            };
        }
        if (tree.nodeTag(unwrapped) == .unwrap_optional) {
            const base = tree.nodeData(unwrapped).node_and_token[0];
            const base_operand = try self.captureOperand(handle, base, depth + 1) orelse return null;
            const value = try self.analyser.resolveOptionalUnwrap(base_operand.value) orelse return null;
            return .{
                .value = value,
                .target = if (base_operand.target) |target|
                    try self.extendCaptureTarget(target, value, .optional_payload)
                else
                    null,
            };
        }
        if (tree.nodeTag(unwrapped) == .@"orelse") {
            const lhs, const rhs = tree.nodeData(unwrapped).node_and_node;
            const base_result = try self.captureOperand(handle, lhs, depth + 1);
            const base_operand = base_result orelse return null;
            return switch (try self.optionalValue(base_operand.value) orelse return null) {
                .payload => |value| .{
                    .value = value,
                    .target = if (base_operand.target) |target|
                        try self.extendCaptureTarget(target, value, .optional_payload)
                    else
                        null,
                },
                .absent => blk: {
                    const result = try self.captureOperand(handle, rhs, depth + 1);
                    break :blk result;
                },
            };
        }
        if (tree.nodeTag(unwrapped) == .@"try") {
            const base_operand = try self.captureOperand(handle, tree.nodeData(unwrapped).node, depth + 1) orelse return null;
            return switch (try self.errorUnionValue(base_operand.value) orelse return null) {
                .payload => |value| .{
                    .value = value,
                    .target = if (base_operand.target) |target|
                        try self.extendCaptureTarget(target, value, .error_union_payload)
                    else
                        null,
                },
                .failure => |failure| {
                    self.pending_flow = .{ .returned = .{ .value = failure, .source_node = null } };
                    return null;
                },
            };
        }
        if (tree.nodeTag(unwrapped) == .@"catch") {
            const lhs, const rhs = tree.nodeData(unwrapped).node_and_node;
            const base_operand = try self.captureOperand(handle, lhs, depth + 1) orelse return null;
            return switch (try self.errorUnionValue(base_operand.value) orelse return null) {
                .payload => |value| .{
                    .value = value,
                    .target = if (base_operand.target) |target|
                        try self.extendCaptureTarget(target, value, .error_union_payload)
                    else
                        null,
                },
                .failure => |failure| blk: {
                    if (self.catchCaptureToken(handle, unwrapped)) |token| try self.bind(handle, token, failure);
                    break :blk self.captureOperand(handle, rhs, depth + 1);
                },
            };
        }
        if (tree.nodeTag(unwrapped) == .deref) {
            const pointer_operand = try self.captureOperand(handle, tree.nodeData(unwrapped).node, depth + 1) orelse return null;
            const value = try self.analyser.resolveDerefType(pointer_operand.value) orelse return null;
            return .{
                .value = value,
                .target = try self.captureTargetFromPointer(pointer_operand.value, value),
            };
        }
        if (ast.isBuiltinCall(tree, unwrapped) and
            std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(unwrapped)), "@field"))
        {
            var buffer: [2]Ast.Node.Index = undefined;
            const params = tree.builtinCallParams(&buffer, unwrapped).?;
            if (params.len != 2) return null;
            const base_operand = try self.captureOperand(handle, params[0], depth + 1) orelse return null;
            const name_value = try self.eval(handle, params[1]) orelse return null;
            if (name_value.data != .string_value) return null;
            const field_name = name_value.data.string_value.bytes;
            const value = try self.analyser.resolveComptimeFieldValue(base_operand.value, field_name) orelse return null;
            const target = try self.aggregateCaptureTarget(base_operand);
            if (target == null) return .{ .value = value, .target = null };
            return .{
                .value = value,
                .target = try self.extendCaptureTarget(target.?, value, .{ .field = field_name }),
            };
        }
        return self.captureOperandFallback(handle, unwrapped, depth);
    }

    fn captureAggregateValue(self: *Interpreter, value: Type) Error!Type {
        return switch (value.data) {
            .comptime_value => |comptime_value| switch (comptime_value.data) {
                .reference => |reference| try self.readReference(reference) orelse value,
                .pointee => |pointee| pointee.value,
                else => value,
            },
            else => value,
        };
    }

    fn aggregateCaptureTarget(self: *Interpreter, operand: CaptureOperand) Error!?CaptureTarget {
        return try self.captureTargetFromPointer(
            operand.value,
            try self.captureAggregateValue(operand.value),
        ) orelse operand.target;
    }

    fn captureTargetFromPointer(
        self: *Interpreter,
        pointer: Type,
        value: Type,
    ) Error!?CaptureTarget {
        if (pointer.data != .comptime_value) return null;
        return switch (pointer.data.comptime_value.data) {
            .reference => |reference| .{ .reference = reference },
            .pointee => |pointee| pointee: {
                var updated = pointee;
                updated.value = value;
                break :pointee .{ .pointee = updated };
            },
            .sequence => |sequence| sequence_target: {
                const pointer_type = try pointer.data.comptime_value.ty.instanceUnchecked(self.analyser);
                if (pointer_type.pointerSize(self.analyser) != .one) break :sequence_target null;
                const origin = sequence.origin orelse break :sequence_target null;
                break :sequence_target .{ .pointee = try self.extendPointee(
                    origin,
                    value,
                    .{ .index = sequence.offset },
                ) };
            },
            else => null,
        };
    }

    fn captureOperandFallback(
        self: *Interpreter,
        handle: *Handle,
        node: Ast.Node.Index,
        depth: u8,
    ) Error!?CaptureOperand {
        if (try self.referenceForNode(handle, node)) |reference| {
            return .{
                .value = try self.readReference(reference) orelse return null,
                .target = .{ .reference = reference },
            };
        }
        if (try self.staticPointeeTarget(handle, node, depth)) |target| {
            const value = try self.staticCaptureValue(handle, node) orelse
                try self.eval(handle, node) orelse return null;
            if (try self.pointeeForTarget(target, value)) |pointee| {
                return .{ .value = value, .target = .{ .pointee = pointee } };
            }
            return .{ .value = value, .target = null };
        }
        return .{ .value = try self.eval(handle, node) orelse return null, .target = null };
    }

    fn extendPointee(
        self: *Interpreter,
        pointee: Value.Pointee,
        value: Type,
        access: Value.Reference.Access,
    ) Error!Value.Pointee {
        const path = try self.analyser.arena.alloc(Value.Reference.Access, pointee.path.len + 1);
        @memcpy(path[0..pointee.path.len], pointee.path);
        path[pointee.path.len] = access;
        var result = pointee;
        result.value = value;
        result.path = path;
        return result;
    }

    fn extendCaptureTarget(
        self: *Interpreter,
        target: CaptureTarget,
        value: Type,
        access: Value.Reference.Access,
    ) Error!CaptureTarget {
        return switch (target) {
            .reference => |reference| .{ .reference = try self.extendReference(reference, access) },
            .pointee => |pointee| .{ .pointee = try self.extendPointee(pointee, value, access) },
        };
    }

    fn pointeeForTarget(
        self: *Interpreter,
        target: StaticPointeeTarget,
        value: Type,
    ) Error!?Value.Pointee {
        if (!target.declaration.isConst()) return null;
        const is_static = try target.declaration.isStatic();
        if (!is_static) {
            const key: Analyser.TokenWithHandle = .{
                .handle = target.declaration.handle,
                .token = target.declaration.nameToken(),
            };
            if (!self.bindings.contains(key)) return null;
        }
        const declaration_node = switch (target.declaration.decl) {
            .ast_node => |node| node,
            else => return null,
        };
        return .{
            .value = value,
            .source = .of(declaration_node, target.declaration.handle),
            .container_type = target.declaration.container_type,
            .path = target.path,
            .is_static = is_static,
        };
    }

    fn captureTargetPointer(
        self: *Interpreter,
        target: CaptureTarget,
        payload: Type,
        access: ?Value.Reference.Access,
    ) Error!?Type {
        return switch (target) {
            .reference => |reference| self.referenceValue(if (access) |payload_access|
                try self.extendReference(reference, payload_access)
            else
                reference),
            .pointee => |pointee| blk: {
                const result = if (access) |payload_access|
                    try self.extendPointee(pointee, payload, payload_access)
                else result: {
                    var updated = pointee;
                    updated.value = payload;
                    break :result updated;
                };
                const pointer = try self.analyser.resolveAddressOf(true, payload);
                break :blk @as(?Type, try Value.create(
                    self.analyser,
                    try pointer.typeOf(self.analyser),
                    .{ .pointee = result },
                ));
            },
        };
    }

    fn staticPointeeTarget(
        self: *Interpreter,
        handle: *Handle,
        node: Ast.Node.Index,
        depth: u8,
    ) Error!?StaticPointeeTarget {
        if (depth == 128) return null;
        const tree = &handle.tree;
        const unwrapped = unwrapGroupedSource(tree, node);
        if (tree.nodeTag(unwrapped) == .@"orelse") {
            const lhs, const rhs = tree.nodeData(unwrapped).node_and_node;
            const value = try self.staticCaptureValue(handle, lhs) orelse return null;
            return switch (try self.optionalValue(value) orelse return null) {
                .payload => {
                    const parent = try self.staticPointeeTarget(handle, lhs, depth + 1) orelse return null;
                    const path = try self.analyser.arena.alloc(Value.Reference.Access, parent.path.len + 1);
                    @memcpy(path[0..parent.path.len], parent.path);
                    path[parent.path.len] = .optional_payload;
                    return .{ .declaration = parent.declaration, .path = path };
                },
                .absent => self.staticPointeeTarget(handle, rhs, depth + 1),
            };
        }
        if (tree.nodeTag(unwrapped) == .@"try" or tree.nodeTag(unwrapped) == .@"catch") {
            const base = switch (tree.nodeTag(unwrapped)) {
                .@"try" => tree.nodeData(unwrapped).node,
                .@"catch" => tree.nodeData(unwrapped).node_and_node[0],
                else => unreachable,
            };
            const value = try self.staticCaptureValue(handle, base) orelse return null;
            if (switch (try self.errorUnionValue(value) orelse return null) {
                .payload => false,
                .failure => true,
            }) return null;
            const parent = try self.staticPointeeTarget(handle, base, depth + 1) orelse return null;
            const path = try self.analyser.arena.alloc(Value.Reference.Access, parent.path.len + 1);
            @memcpy(path[0..parent.path.len], parent.path);
            path[parent.path.len] = .error_union_payload;
            return .{ .declaration = parent.declaration, .path = path };
        }
        if (tree.nodeTag(unwrapped) == .deref) {
            const pointer_node = tree.nodeData(unwrapped).node;
            const evaluated = try self.eval(handle, pointer_node);
            const pointer = if (evaluated != null and evaluated.?.data == .comptime_value and
                evaluated.?.data.comptime_value.data == .pointee)
                evaluated.?
            else
                try self.staticCaptureValue(handle, pointer_node) orelse return null;
            if (pointer.data != .comptime_value or pointer.data.comptime_value.data != .pointee) return null;
            const pointee = pointer.data.comptime_value.data.pointee;
            return .{
                .declaration = .{
                    .decl = .{ .ast_node = pointee.source.node },
                    .handle = pointee.source.handle,
                    .container_type = pointee.container_type,
                },
                .path = pointee.path,
            };
        }
        sequence_origin: {
            if (tree.nodeTag(unwrapped) != .array_access) break :sequence_origin;
            const base, const index_node = tree.nodeData(unwrapped).node_and_node;
            const evaluated = try self.eval(handle, base) orelse break :sequence_origin;
            const base_type = try (try evaluated.typeOf(self.analyser)).instanceUnchecked(self.analyser);
            const pointer_size = base_type.pointerSize(self.analyser) orelse break :sequence_origin;
            if (pointer_size != .many and pointer_size != .slice) break :sequence_origin;
            const index = try self.staticIndex(handle, index_node) orelse break :sequence_origin;
            const value = if (try Value.sequenceAlloc(self.analyser, evaluated) != null)
                evaluated
            else
                try self.staticCaptureValue(handle, base) orelse break :sequence_origin;
            const sequence = try Value.sequenceAlloc(self.analyser, value) orelse break :sequence_origin;
            if (index >= sequence.len) break :sequence_origin;
            if (sequence.origin) |origin| {
                const offset = std.math.add(usize, sequence.offset, index) catch break :sequence_origin;
                const path = try self.analyser.arena.alloc(Value.Reference.Access, origin.path.len + 1);
                @memcpy(path[0..origin.path.len], origin.path);
                path[origin.path.len] = .{ .index = offset };
                return .{
                    .declaration = .{
                        .decl = .{ .ast_node = origin.source.node },
                        .handle = origin.source.handle,
                        .container_type = origin.container_type,
                    },
                    .path = path,
                };
            }
        }
        if (ast.isBuiltinCall(tree, unwrapped) and
            std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(unwrapped)), "@field"))
        {
            var buffer: [2]Ast.Node.Index = undefined;
            const params = tree.builtinCallParams(&buffer, unwrapped).?;
            if (params.len != 2) return null;
            const name_node = unwrapGroupedSource(tree, params[1]);
            if (tree.nodeTag(name_node) != .string_literal) return null;
            const name_value = try self.eval(handle, name_node) orelse return null;
            if (name_value.data != .string_value) return null;
            const parent = try self.staticPointeeTarget(handle, params[0], depth + 1) orelse return null;
            const path = try self.analyser.arena.alloc(Value.Reference.Access, parent.path.len + 1);
            @memcpy(path[0..parent.path.len], parent.path);
            path[parent.path.len] = .{ .field = name_value.data.string_value.bytes };
            return .{ .declaration = parent.declaration, .path = path };
        }
        if (try self.analyser.resolveDeclarationOfNode(.of(unwrapped, handle))) |resolved| {
            var declaration = resolved;
            if (declaration.container_type == null and self.container_type != null and
                tree.nodeTag(unwrapped) == .identifier)
            {
                const name = try self.analyser.identifierTokenName(tree, tree.nodeMainToken(unwrapped)) orelse return null;
                if (try self.container_type.?.lookupSymbol(self.analyser, name)) |specialized| {
                    if (declaration.eql(specialized)) declaration = specialized;
                }
            }
            return .{ .declaration = declaration, .path = &.{} };
        }
        const base, const access: Value.Reference.Access = switch (tree.nodeTag(unwrapped)) {
            .field_access => blk: {
                const base, const name_token = tree.nodeData(unwrapped).node_and_token;
                const name = try self.analyser.identifierTokenName(tree, name_token) orelse return null;
                break :blk .{ base, .{ .field = name } };
            },
            .array_access => blk: {
                const base, const index_node = tree.nodeData(unwrapped).node_and_node;
                const index = try self.staticIndex(handle, index_node) orelse return null;
                break :blk .{ base, .{ .index = index } };
            },
            .unwrap_optional => .{ tree.nodeData(unwrapped).node_and_token[0], .optional_payload },
            else => return null,
        };
        const parent = try self.staticPointeeTarget(handle, base, depth + 1) orelse return null;
        const path = try self.analyser.arena.alloc(Value.Reference.Access, parent.path.len + 1);
        @memcpy(path[0..parent.path.len], parent.path);
        path[parent.path.len] = access;
        return .{ .declaration = parent.declaration, .path = path };
    }

    fn staticIndex(self: *Interpreter, handle: *Handle, node: Ast.Node.Index) Error!?usize {
        if (!isPureStaticIntegerExpression(&handle.tree, node, 0)) return null;
        return self.integer(handle, node);
    }

    fn isPureStaticIntegerExpression(tree: *const Ast, node: Ast.Node.Index, depth: u8) bool {
        if (depth == 128) return false;
        const unwrapped = unwrapGroupedSource(tree, node);
        return switch (tree.nodeTag(unwrapped)) {
            .number_literal, .identifier => true,
            .negation, .negation_wrap, .bit_not => isPureStaticIntegerExpression(tree, tree.nodeData(unwrapped).node, depth + 1),
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
            => blk: {
                const lhs, const rhs = tree.nodeData(unwrapped).node_and_node;
                break :blk isPureStaticIntegerExpression(tree, lhs, depth + 1) and
                    isPureStaticIntegerExpression(tree, rhs, depth + 1);
            },
            else => false,
        };
    }

    pub fn enterExpression(self: *Interpreter) bool {
        if (self.pending_flow != null or self.budget.expression_depth >= 128 or !self.tick()) return false;
        self.budget.expression_depth += 1;
        return true;
    }

    pub fn leaveExpression(self: *Interpreter) void {
        self.budget.expression_depth -= 1;
    }

    pub fn evaluateFieldDefault(analyser: *Analyser, decl: Analyser.DeclWithHandle) Error!?Type {
        const field_node = switch (decl.decl) {
            .ast_node => |node| node,
            else => return null,
        };
        const field = decl.handle.tree.fullContainerField(field_node) orelse return null;
        const value_node = field.ast.value_expr.unwrap() orelse return null;
        var budget: Budget = .{};
        var child: Interpreter = .{
            .analyser = analyser,
            .bindings = if (analyser.generic_bindings) |bindings| try bindings.clone(analyser.arena) else .empty,
            .container_type = decl.container_type,
            .budget = if (analyser.comptime_interpreter) |parent| parent.budget else &budget,
        };
        var display_bindings = if (analyser.display_bindings) |bindings| try bindings.clone(analyser.arena) else Analyser.TokenToNodeMap.empty;
        if (decl.container_type) |container| {
            if (container.data == .container) {
                const info = container.data.container;
                for (info.bound_params.keys(), info.bound_params.values()) |key, value| {
                    try child.bindings.put(analyser.arena, key, value);
                }
                for (info.display_params.keys(), info.display_params.values()) |key, value| {
                    try display_bindings.put(analyser.arena, key, value);
                }
            }
        }
        if (!child.enterExpression()) return null;
        defer child.leaveExpression();
        const old_interpreter = analyser.comptime_interpreter;
        const old_bindings = analyser.generic_bindings;
        const old_display_bindings = analyser.display_bindings;
        const old_values = analyser.evaluate_comptime_values;
        const old_numbers = analyser.resolve_number_literal_values;
        const old_flow = analyser.evaluate_comptime_control_flow;
        analyser.comptime_interpreter = &child;
        analyser.generic_bindings = &child.bindings;
        analyser.display_bindings = &display_bindings;
        analyser.evaluate_comptime_values = true;
        analyser.resolve_number_literal_values = true;
        analyser.evaluate_comptime_control_flow = true;
        defer {
            analyser.comptime_interpreter = old_interpreter;
            analyser.generic_bindings = old_bindings;
            analyser.display_bindings = old_display_bindings;
            analyser.evaluate_comptime_values = old_values;
            analyser.resolve_number_literal_values = old_numbers;
            analyser.evaluate_comptime_control_flow = old_flow;
        }
        const field_value = try decl.resolveType(analyser) orelse return null;
        return child.evaluateTypedExpression(decl.handle, value_node, try field_value.typeOf(analyser));
    }

    pub fn evaluateExpression(self: *Interpreter, handle: *Handle, node: Ast.Node.Index) Error!?Type {
        return self.eval(handle, node);
    }

    pub fn evaluateTypedExpression(self: *Interpreter, handle: *Handle, node: Ast.Node.Index, destination: Type) Error!?Type {
        const evaluated = try self.evalTypedSource(handle, node, destination) orelse return null;
        return self.coerceAssignmentFromSource(handle, destination, evaluated.value, evaluated.source_node, null);
    }

    pub fn evaluateArrayInit(self: *Interpreter, handle: *Handle, destination: Type, elements: []const Ast.Node.Index) Error!?Type {
        const len = self.assignmentAggregateLength(destination) orelse return null;
        if (len != elements.len or len > self.budget.steps) return destination.instanceTypeVal(self.analyser);
        const values = try self.analyser.arena.alloc(Type, len);
        for (elements, values, 0..) |element, *value, index| {
            const element_type = try self.assignmentChildType(destination, .{ .index = index }) orelse return null;
            value.* = try self.evaluateTypedExpression(handle, element, element_type) orelse
                try element_type.instanceTypeVal(self.analyser) orelse return null;
        }
        if (destination.ipIndex()) |type_index| intern: {
            const indices = try self.analyser.arena.alloc(InternPool.Index, len);
            for (values, indices) |value, *index| {
                if (value.data != .ip_index) break :intern;
                index.* = value.ipIndex() orelse try self.analyser.ip.getUnknown(value.data.ip_index.type);
            }
            const aggregate = try self.analyser.ip.get(.{ .aggregate = .{
                .ty = type_index,
                .values = try self.analyser.ip.getIndexSlice(indices),
            } });
            return Type.fromIP(self.analyser, type_index, aggregate);
        }
        return @as(?Type, try Value.create(self.analyser, destination, .{ .array = values }));
    }

    fn isUnionType(self: *Interpreter, ty: Type) bool {
        if (ty.isUnionType()) return true;
        const index = ty.ipIndex() orelse return false;
        return self.analyser.ip.zigTypeTag(index) == .@"union";
    }

    pub fn evaluateStructInit(self: *Interpreter, handle: *Handle, destination: Type, field_nodes: []const Ast.Node.Index) Error!?Type {
        const analyser = self.analyser;
        const tree = &handle.tree;
        const is_union = self.isUnionType(destination);
        if (is_union and field_nodes.len != 1) return destination.instanceTypeVal(analyser);
        if (!is_union and !destination.isStructType(analyser)) return destination.instanceTypeVal(analyser);
        const ip_struct = if (destination.ipIndex()) |index| switch (analyser.ip.indexToKey(index)) {
            .struct_type => |struct_index| analyser.ip.getStruct(struct_index),
            else => null,
        } else null;
        const len = if (ip_struct) |info| info.fields.count() else field_nodes.len;
        if (field_nodes.len > len or len > self.budget.steps) return destination.instanceTypeVal(analyser);
        const fields = try analyser.arena.alloc(Value.Field, len);
        var initialized: std.StringHashMapUnmanaged(void) = .empty;
        defer initialized.deinit(analyser.gpa);
        for (field_nodes, fields[0..field_nodes.len]) |field_node, *field| {
            const name_token = tree.firstToken(field_node) - 2;
            const name = try analyser.identifierTokenName(tree, name_token) orelse return null;
            const entry = try initialized.getOrPut(analyser.gpa, name);
            if (entry.found_existing) return destination.instanceTypeVal(analyser);
            const field_type = try self.assignmentChildType(destination, .{ .field = name }) orelse
                return destination.instanceTypeVal(analyser);
            const evaluated = try self.evalTypedSource(handle, field_node, field_type) orelse return destination.instanceTypeVal(analyser);
            field.* = .{
                .name = name,
                .value = try self.coerceFromSource(handle, field_type, evaluated.value, evaluated.source_node, null, !is_union) orelse
                    return destination.instanceTypeVal(analyser),
            };
        }
        if (ip_struct) |info| {
            var next = field_nodes.len;
            for (info.fields.keys(), info.fields.values()) |name_index, field| {
                const name = try analyser.ip.string_pool.stringToSliceAlloc(analyser.store.io, analyser.arena, name_index);
                if (initialized.contains(name)) continue;
                if (field.default_value == .none) return destination.instanceTypeVal(analyser);
                fields[next] = .{ .name = name, .value = Type.fromIP(analyser, field.ty, field.default_value) };
                next += 1;
            }
        }
        return @as(?Type, try Value.create(analyser, destination, .{ .fields = fields }));
    }

    pub fn evaluateAs(self: *Interpreter, handle: *Handle, params: []const Ast.Node.Index) Error!?Type {
        if (params.len != 2) return null;
        const destination = try self.eval(handle, params[0]) orelse return null;
        const evaluated = try self.evalTypedSource(handle, params[1], destination) orelse return null;
        return self.coerceFromSource(
            handle,
            destination,
            evaluated.value,
            evaluated.source_node,
            null,
            self.optionalPayloadType(destination) != null,
        );
    }

    pub fn evaluateUnionInit(self: *Interpreter, handle: *Handle, params: []const Ast.Node.Index) Error!?Type {
        if (params.len != 3) return null;
        const union_type = try self.eval(handle, params[0]) orelse return null;
        const field_name = try self.eval(handle, params[1]) orelse return null;
        const fallback = try union_type.instanceTypeVal(self.analyser);
        if (!union_type.is_type_val or !self.isUnionType(union_type)) return fallback;
        if (field_name.data != .string_value) return fallback;
        const name = field_name.data.string_value.bytes;
        const field_type = try self.assignmentChildType(union_type, .{ .field = name }) orelse return fallback;
        const evaluated = try self.evalTypedSource(handle, params[2], field_type) orelse return fallback;
        const value = try self.coerceFromSource(handle, field_type, evaluated.value, evaluated.source_node, null, false) orelse return fallback;
        const fields = try self.analyser.arena.alloc(Value.Field, 1);
        fields[0] = .{ .name = name, .value = value };
        return @as(?Type, try Value.create(self.analyser, union_type, .{ .fields = fields }));
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

    fn expressionResult(self: *Interpreter, flow: Flow) ?EvaluatedSource {
        return switch (flow) {
            .next => .{
                .value = Type.fromIP(self.analyser, .void_type, .void_value),
                .source_node = null,
            },
            .value => |result| result,
            .returned, .stopped, .continued => {
                self.pending_flow = flow;
                return null;
            },
            .unknown => null,
        };
    }

    fn eval(self: *Interpreter, handle: *Handle, node: Ast.Node.Index) Error!?Type {
        if (self.pending_flow != null) return null;
        if (!self.tick()) return null;
        var block_buffer: [2]Ast.Node.Index = undefined;
        if (handle.tree.blockStatements(&block_buffer, node) != null) {
            const result = self.expressionResult(try self.block(handle, node, null, false)) orelse return null;
            return result.value;
        }
        switch (handle.tree.nodeTag(node)) {
            .address_of => {
                const operand = handle.tree.nodeData(node).node;
                if (handle.tree.nodeTag(operand) == .deref) {
                    const pointer = try self.eval(handle, handle.tree.nodeData(operand).node) orelse return null;
                    if (pointer.data == .comptime_value and
                        (try pointer.data.comptime_value.ty.instanceUnchecked(self.analyser)).pointerSize(self.analyser) == .one and
                        try self.analyser.resolveDerefType(pointer) != null and
                        (pointer.data.comptime_value.data == .reference or
                            pointer.data.comptime_value.data == .pointee)) return pointer;
                }
                if (handle.tree.nodeTag(operand) == .array_access) {
                    const base, const index_node = handle.tree.nodeData(operand).node_and_node;
                    if (handle.tree.nodeTag(base) == .identifier) {
                        if (try self.eval(handle, base)) |sequence_value| {
                            const pointer_size = if (sequence_value.data == .comptime_value)
                                (try sequence_value.data.comptime_value.ty.instanceUnchecked(self.analyser)).pointerSize(self.analyser)
                            else
                                null;
                            if ((pointer_size == .many or pointer_size == .slice) and
                                Value.sequence(sequence_value) != null)
                            {
                                const sequence = Value.sequence(sequence_value).?;
                                const index = try self.integer(handle, index_node) orelse return null;
                                if (index >= sequence.len) return null;
                                const offset = std.math.add(usize, sequence.offset, index) catch return null;
                                const pointer = try self.analyser.resolveTypeOfNode(.of(node, handle)) orelse return null;
                                return @as(?Type, try Value.create(self.analyser, try pointer.typeOf(self.analyser), .{ .sequence = .{
                                    .backing = sequence.backing,
                                    .offset = offset,
                                    .len = 1,
                                    .elements_valid = sequence.elements_valid,
                                    .origin = sequence.origin,
                                } }));
                            }
                        }
                    }
                }
                if (try self.address(handle, operand)) |value| return value;
                const pointer = try self.analyser.resolveTypeOfNode(.of(node, handle)) orelse return null;
                const destination = try pointer.typeOf(self.analyser);
                return try self.coerceFromSource(handle, destination, pointer, node, null, false) orelse pointer;
            },
            .@"return", .@"break", .@"continue" => {
                _ = self.expressionResult(try self.statement(handle, node));
                return null;
            },
            .@"comptime", .@"nosuspend" => return self.eval(handle, handle.tree.nodeData(node).node),
            .grouped_expression => return self.eval(handle, handle.tree.nodeData(node).node_and_token[0]),
            .if_simple, .@"if" => {
                const target = try self.ifTarget(handle, node) orelse
                    return self.analyser.resolveTypeOfNode(.of(node, handle));
                return switch (target) {
                    .none => Type.fromIP(self.analyser, .void_type, .void_value),
                    .node => |target_node| self.eval(handle, target_node),
                };
            },
            .for_simple, .@"for" => {
                const result = self.expressionResult(try self.forLoop(handle, handle.tree.fullFor(node).?, true, null, false)) orelse return null;
                return result.value;
            },
            .while_simple, .while_cont, .@"while" => {
                const result = self.expressionResult(try self.whileLoop(handle, ast.fullWhile(&handle.tree, node).?, true, null, false)) orelse return null;
                return result.value;
            },
            .@"switch", .switch_comma => {
                if (handle.tree.switchFull(node).label_token != null) {
                    const result = self.expressionResult(try self.switchLoop(handle, node, true, null)) orelse return null;
                    return result.value;
                }
                const target = try self.switchTarget(handle, node) orelse
                    return self.analyser.resolveTypeOfNode(.of(node, handle));
                return self.eval(handle, target);
            },
            .@"orelse" => {
                const lhs, const rhs = handle.tree.nodeData(node).node_and_node;
                const optional = try self.eval(handle, lhs) orelse return null;
                return switch (try self.optionalValue(optional) orelse
                    return self.analyser.resolveTypeOfNode(.of(node, handle))) {
                    .absent => self.eval(handle, rhs),
                    .payload => |payload| payload,
                };
            },
            .@"catch" => {
                const lhs, const rhs = handle.tree.nodeData(node).node_and_node;
                const error_union = try self.eval(handle, lhs) orelse return null;
                return switch (try self.errorUnionValue(error_union) orelse
                    return self.analyser.resolveTypeOfNode(.of(node, handle))) {
                    .payload => |payload| payload,
                    .failure => |failure| {
                        if (self.catchCaptureToken(handle, node)) |token| try self.bind(handle, token, failure);
                        return self.eval(handle, rhs);
                    },
                };
            },
            .@"try" => {
                const error_union = try self.eval(handle, handle.tree.nodeData(node).node) orelse return null;
                return switch (try self.errorUnionValue(error_union) orelse return null) {
                    .payload => |payload| payload,
                    .failure => |failure| {
                        self.pending_flow = .{ .returned = .{ .value = failure, .source_node = null } };
                        return null;
                    },
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
                const options = try self.analyser.resolveComptimeBinaryOptions(
                    &handle.tree,
                    lhs,
                    rhs,
                    tag,
                    true,
                );
                return self.analyser.resolveComptimeBinaryValue(tag, lhs_value, rhs_value, options);
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
                const field_name = offsets.identifierTokenToNameSlice(&handle.tree, field_token);
                const value = if (std.mem.eql(u8, field_name, "ptr"))
                    try self.staticSequenceValue(handle, base) orelse try self.eval(handle, base) orelse return null
                else
                    try self.eval(handle, base) orelse return null;
                return self.analyser.resolveFieldAccess(value, field_name);
            },
            .array_access => {
                const base, const index_node = handle.tree.nodeData(node).node_and_node;
                const value = try self.eval(handle, base) orelse return null;
                const index = switch (try self.integerValue(handle, index_node) orelse return null) {
                    .known => |known| known,
                    .unknown => null,
                };
                return self.analyser.resolveBracketAccessType(value, .{ .single = index });
            },
            .slice, .slice_open, .slice_sentinel => {
                const slice = handle.tree.fullSlice(node).?;
                const value = try self.staticSequenceValue(handle, slice.ast.sliced) orelse
                    try self.eval(handle, slice.ast.sliced) orelse return null;
                const start_value = try self.integerValue(handle, slice.ast.start) orelse return null;
                const end = if (slice.ast.end.unwrap()) |end_node|
                    try self.integerValue(handle, end_node) orelse return null
                else
                    null;
                const sentinel = if (slice.ast.sentinel.unwrap()) |sentinel_node|
                    (try self.eval(handle, sentinel_node) orelse return null).ipIndex() orelse return null
                else
                    .none;
                const access: Analyser.BracketAccess = if (end) |end_value|
                    .{ .range = .{
                        .bounds = if (start_value == .known and end_value == .known)
                            .{ start_value.known, end_value.known }
                        else
                            null,
                        .sentinel = sentinel,
                    } }
                else
                    .{ .open = .{
                        .start = switch (start_value) {
                            .known => |known| known,
                            .unknown => null,
                        },
                        .sentinel = sentinel,
                    } };
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
                const qualifier_cast: ?Type.PointerQualifierCast = if (std.mem.eql(u8, name, "@constCast"))
                    .discard_const
                else if (std.mem.eql(u8, name, "@volatileCast"))
                    .discard_volatile
                else
                    null;
                if (qualifier_cast) |kind| {
                    var buffer: [2]Ast.Node.Index = undefined;
                    const params = handle.tree.builtinCallParams(&buffer, node).?;
                    if (params.len != 1) return null;
                    const operand = try self.eval(handle, params[0]) orelse return null;
                    const source_type = try operand.typeOf(self.analyser);
                    const destination = try source_type.qualifierCastType(self.analyser, kind) orelse return null;
                    return self.pointerCastValue(destination, operand, kind);
                }
                if (std.mem.eql(u8, name, "@as")) {
                    var buffer: [2]Ast.Node.Index = undefined;
                    const params = handle.tree.builtinCallParams(&buffer, node).?;
                    return self.evaluateAs(handle, params);
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
                if (std.mem.eql(u8, name, "@unionInit")) {
                    var buffer: [2]Ast.Node.Index = undefined;
                    const params = handle.tree.builtinCallParams(&buffer, node).?;
                    return self.evaluateUnionInit(handle, params);
                }
                if (std.mem.eql(u8, name, "@Vector")) {
                    var buffer: [2]Ast.Node.Index = undefined;
                    const params = handle.tree.builtinCallParams(&buffer, node).?;
                    if (params.len != 2) return null;
                    const len_value = try self.eval(handle, params[0]) orelse return null;
                    const len = self.analyser.ip.toInt(len_value.ipIndex() orelse return null, u32) orelse return null;
                    const child_type = try self.eval(handle, params[1]) orelse return null;
                    return self.analyser.resolveComptimeVectorType(len, child_type);
                }
                if (std.mem.eql(u8, name, "@Tuple")) {
                    var buffer: [2]Ast.Node.Index = undefined;
                    const params = handle.tree.builtinCallParams(&buffer, node).?;
                    if (params.len != 1) return null;
                    const fields = try self.eval(handle, params[0]) orelse return null;
                    return self.analyser.resolveComptimeTupleTypeValue(fields);
                }
                if (std.mem.eql(u8, name, "@import")) {
                    var buffer: [2]Ast.Node.Index = undefined;
                    const params = handle.tree.builtinCallParams(&buffer, node).?;
                    if (params.len != 1) return null;
                    const import_path = try self.eval(handle, params[0]) orelse return null;
                    if (import_path.data != .string_value) return null;
                    return self.analyser.resolveComptimeImportValue(
                        handle,
                        import_path.data.string_value.bytes,
                    );
                }
                if (std.mem.eql(u8, name, "@embedFile")) {
                    var buffer: [2]Ast.Node.Index = undefined;
                    const params = handle.tree.builtinCallParams(&buffer, node).?;
                    if (params.len != 1) return null;
                    const path = try self.eval(handle, params[0]) orelse return null;
                    if (path.data != .string_value) return null;
                    return self.analyser.resolveComptimeEmbedFileValue(handle, path.data.string_value.bytes);
                }
                if (std.mem.eql(u8, name, "@setEvalBranchQuota")) {
                    var buffer: [2]Ast.Node.Index = undefined;
                    const params = handle.tree.builtinCallParams(&buffer, node).?;
                    if (params.len != 1) return null;
                    const quota = try self.eval(handle, params[0]) orelse return null;
                    const requested = self.analyser.ip.toInt(quota.ipIndex() orelse return null, u32) orelse return null;
                    self.budget.raiseQuota(requested);
                    return Type.fromIP(self.analyser, .void_type, .void_value);
                }
                if (std.mem.eql(u8, name, "@setRuntimeSafety")) {
                    var buffer: [2]Ast.Node.Index = undefined;
                    const params = handle.tree.builtinCallParams(&buffer, node).?;
                    if (params.len != 1) return null;
                    const enabled = try self.eval(handle, params[0]) orelse return null;
                    _ = try self.boolValue(enabled) orelse return null;
                    return Type.fromIP(self.analyser, .void_type, .void_value);
                }
                if (std.mem.eql(u8, name, "@compileLog")) {
                    var buffer: [2]Ast.Node.Index = undefined;
                    const params = handle.tree.builtinCallParams(&buffer, node).?;
                    for (params) |param| _ = try self.eval(handle, param) orelse return null;
                    return Type.fromIP(self.analyser, .void_type, .void_value);
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
                if (std.mem.eql(u8, name, "@shuffle")) {
                    var buffer: [2]Ast.Node.Index = undefined;
                    const params = handle.tree.builtinCallParams(&buffer, node).?;
                    if (params.len != 4) return null;
                    const element_type = try self.eval(handle, params[0]) orelse return null;
                    const lhs = try self.eval(handle, params[1]) orelse return null;
                    const rhs = try self.eval(handle, params[2]) orelse return null;
                    const mask = try self.eval(handle, params[3]) orelse return null;
                    return self.analyser.resolveComptimeShuffleValue(element_type, lhs, rhs, mask);
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
                if (std.mem.eql(u8, name, "@field") or std.mem.eql(u8, name, "@FieldType")) {
                    var buffer: [2]Ast.Node.Index = undefined;
                    const params = handle.tree.builtinCallParams(&buffer, node).?;
                    if (params.len != 2) return null;
                    const container = try self.eval(handle, params[0]) orelse return null;
                    const name_value = try self.eval(handle, params[1]) orelse return null;
                    if (name_value.data != .string_value) return null;
                    const field_name = name_value.data.string_value.bytes;
                    if (std.mem.eql(u8, name, "@field")) {
                        return self.analyser.resolveComptimeFieldValue(container, field_name);
                    }
                    return self.analyser.resolveComptimeFieldTypeValue(container, field_name);
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
                if (std.mem.eql(u8, name, "@addWithOverflow") or
                    std.mem.eql(u8, name, "@subWithOverflow") or
                    std.mem.eql(u8, name, "@mulWithOverflow") or
                    std.mem.eql(u8, name, "@shlWithOverflow"))
                {
                    var buffer: [2]Ast.Node.Index = undefined;
                    const params = handle.tree.builtinCallParams(&buffer, node).?;
                    if (params.len != 2) return null;
                    const lhs = try self.eval(handle, params[0]) orelse return null;
                    const rhs = try self.eval(handle, params[1]) orelse return null;
                    const kind: Analyser.ComptimeOverflowKind = if (std.mem.eql(u8, name, "@addWithOverflow"))
                        .add
                    else if (std.mem.eql(u8, name, "@subWithOverflow"))
                        .sub
                    else if (std.mem.eql(u8, name, "@mulWithOverflow"))
                        .mul
                    else
                        .shl;
                    const options = try self.analyser.resolveComptimeOverflowOptions(
                        &handle.tree,
                        params[0],
                        params[1],
                        kind,
                        true,
                    );
                    return self.analyser.resolveComptimeOverflowValue(lhs, rhs, kind, options);
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

    fn evalTypedSource(self: *Interpreter, handle: *Handle, node: Ast.Node.Index, destination: Type) Error!?EvaluatedSource {
        return self.evalSourceWithType(handle, node, destination);
    }

    fn pointerCastValue(
        self: *Interpreter,
        destination: Type,
        operand: Type,
        qualifier_cast: ?Type.PointerQualifierCast,
    ) Error!?Type {
        const source_type = try operand.typeOf(self.analyser);
        const preserves_identity = if (qualifier_cast) |kind|
            destination.preservesIdentityThroughQualifierCast(self.analyser, source_type, kind)
        else
            destination.preservesIdentityThroughPtrCast(self.analyser, source_type);
        if (!preserves_identity) return null;
        const destination_payload = self.optionalPayloadType(destination);
        const source_payload = self.optionalPayloadType(source_type);
        if (destination_payload) |payload_type| {
            if (source_payload == null) {
                const casted = try self.pointerCastValue(payload_type, operand, qualifier_cast) orelse return null;
                return @as(?Type, try Value.create(self.analyser, destination, .{ .optional = casted }));
            }
            if (operand.ipIndex()) |index| {
                if (self.analyser.ip.isNull(index))
                    return @as(?Type, try Value.create(self.analyser, destination, .{ .optional = null }));
                if (self.analyser.ip.isUndefined(index) or self.analyser.ip.isUnknown(index)) return null;
            }
            if (operand.data != .comptime_value or operand.data.comptime_value.data != .optional) return null;
            const payload = operand.data.comptime_value.data.optional orelse
                return @as(?Type, try Value.create(self.analyser, destination, .{ .optional = null }));
            const casted = try self.pointerCastValue(payload_type, payload, qualifier_cast) orelse return null;
            return @as(?Type, try Value.create(self.analyser, destination, .{ .optional = casted }));
        }
        if (source_payload != null) {
            if (operand.ipIndex()) |index| {
                if (self.analyser.ip.isNull(index) or self.analyser.ip.isUndefined(index) or
                    self.analyser.ip.isUnknown(index)) return null;
            }
            if (operand.data != .comptime_value or operand.data.comptime_value.data != .optional) return null;
            const payload = operand.data.comptime_value.data.optional orelse return null;
            return self.pointerCastValue(destination, payload, qualifier_cast);
        }
        if (destination.isManyPointerType(self.analyser)) {
            if (Value.sequence(operand)) |sequence| {
                var casted = sequence;
                casted.elements_valid = casted.elements_valid and destination.hasSamePointerElementType(self.analyser, source_type);
                return @as(?Type, try Value.create(self.analyser, destination, .{ .sequence = casted }));
            }
        }
        return switch (operand.data) {
            .comptime_value => |comptime_value| switch (comptime_value.data) {
                .reference => |reference| @as(?Type, try Value.create(self.analyser, destination, .{ .reference = reference })),
                .pointee => |pointee| @as(?Type, try Value.create(self.analyser, destination, .{ .pointee = pointee })),
                .sequence => |sequence| blk: {
                    var casted = sequence;
                    casted.elements_valid = casted.elements_valid and destination.hasSamePointerElementType(self.analyser, source_type);
                    break :blk @as(?Type, try Value.create(self.analyser, destination, .{ .sequence = casted }));
                },
                else => null,
            },
            else => null,
        };
    }

    fn evalSource(self: *Interpreter, handle: *Handle, node: Ast.Node.Index) Error!?EvaluatedSource {
        return self.evalSourceWithType(handle, node, null);
    }

    fn evalSourceWithType(self: *Interpreter, handle: *Handle, node: Ast.Node.Index, destination: ?Type) Error!?EvaluatedSource {
        if (self.pending_flow != null) return null;
        const tree = &handle.tree;
        if (destination) |ty| if (ast.isBuiltinCall(tree, node)) {
            const name = tree.tokenSlice(tree.nodeMainToken(node));
            const kind: ?Analyser.ComptimeCastKind = if (std.mem.eql(u8, name, "@intCast"))
                .int_cast
            else if (std.mem.eql(u8, name, "@truncate"))
                .truncate
            else if (std.mem.eql(u8, name, "@bitCast"))
                .bit_cast
            else if (std.mem.eql(u8, name, "@intFromFloat"))
                .int_from_float
            else if (std.mem.eql(u8, name, "@floatFromInt"))
                .float_from_int
            else if (std.mem.eql(u8, name, "@floatCast"))
                .float_cast
            else
                null;
            const is_splat = std.mem.eql(u8, name, "@splat");
            const is_enum = std.mem.eql(u8, name, "@enumFromInt");
            const is_pointer = std.mem.eql(u8, name, "@ptrCast");
            const qualifier_cast: ?Type.PointerQualifierCast = if (std.mem.eql(u8, name, "@constCast"))
                .discard_const
            else if (std.mem.eql(u8, name, "@volatileCast"))
                .discard_volatile
            else
                null;
            if (kind != null or is_splat or is_enum or is_pointer or qualifier_cast != null) {
                if (!self.tick()) return null;
                var buffer: [2]Ast.Node.Index = undefined;
                const params = tree.builtinCallParams(&buffer, node).?;
                if (params.len != 1) return null;
                const operand = try self.eval(handle, params[0]) orelse return null;
                const value: ?Type = if (kind) |cast_kind|
                    try self.analyser.resolveComptimeCastValue(ty, operand, cast_kind)
                else if (is_splat)
                    try self.analyser.resolveComptimeSplatValue(ty, operand)
                else if (is_enum)
                    try self.analyser.resolveComptimeEnumFromIntValue(ty, operand)
                else
                    try self.pointerCastValue(ty, operand, qualifier_cast);
                return .{ .value = value orelse return null, .source_node = null };
            }
        };
        var block_buffer: [2]Ast.Node.Index = undefined;
        if (tree.blockStatements(&block_buffer, node) != null) {
            if (!self.tick()) return null;
            return self.expressionResult(try self.block(handle, node, destination, false));
        }
        return switch (tree.nodeTag(node)) {
            .@"comptime", .@"nosuspend" => blk: {
                if (!self.tick()) return null;
                break :blk self.evalSourceWithType(handle, tree.nodeData(node).node, destination);
            },
            .grouped_expression => blk: {
                if (!self.tick()) return null;
                break :blk self.evalSourceWithType(handle, tree.nodeData(node).node_and_token[0], destination);
            },
            .if_simple, .@"if" => blk: {
                if (!self.tick()) return null;
                const target = try self.ifTarget(handle, node) orelse break :blk .{
                    .value = try self.analyser.resolveTypeOfNode(.of(node, handle)) orelse return null,
                    .source_node = null,
                };
                break :blk switch (target) {
                    .none => .{
                        .value = Type.fromIP(self.analyser, .void_type, .void_value),
                        .source_node = null,
                    },
                    .node => |target_node| self.evalSourceWithType(handle, target_node, destination),
                };
            },
            .for_simple, .@"for" => blk: {
                if (!self.tick()) return null;
                break :blk self.expressionResult(try self.forLoop(handle, tree.fullFor(node).?, true, destination, false));
            },
            .while_simple, .while_cont, .@"while" => blk: {
                if (!self.tick()) return null;
                break :blk self.expressionResult(try self.whileLoop(handle, ast.fullWhile(tree, node).?, true, destination, false));
            },
            .@"switch", .switch_comma => blk: {
                if (!self.tick()) return null;
                if (tree.switchFull(node).label_token != null)
                    break :blk self.expressionResult(try self.switchLoop(handle, node, true, destination));
                const target = try self.switchTarget(handle, node) orelse {
                    if (self.pending_flow) |pending| {
                        self.pending_flow = null;
                        break :blk self.expressionResult(pending);
                    }
                    break :blk .{
                        .value = try self.analyser.resolveTypeOfNode(.of(node, handle)) orelse return null,
                        .source_node = null,
                    };
                };
                break :blk self.evalSourceWithType(handle, target, destination);
            },
            .@"orelse" => blk: {
                if (!self.tick()) return null;
                const lhs, const rhs = tree.nodeData(node).node_and_node;
                const optional = try self.eval(handle, lhs) orelse return null;
                break :blk switch (try self.optionalValue(optional) orelse break :blk .{
                    .value = try self.analyser.resolveTypeOfNode(.of(node, handle)) orelse return null,
                    .source_node = null,
                }) {
                    .absent => self.evalSourceWithType(handle, rhs, destination),
                    .payload => |payload| .{ .value = payload, .source_node = null },
                };
            },
            .@"catch" => blk: {
                if (!self.tick()) return null;
                const lhs, const rhs = tree.nodeData(node).node_and_node;
                const error_union = try self.eval(handle, lhs) orelse return null;
                break :blk switch (try self.errorUnionValue(error_union) orelse break :blk .{
                    .value = try self.analyser.resolveTypeOfNode(.of(node, handle)) orelse return null,
                    .source_node = null,
                }) {
                    .payload => |payload| .{ .value = payload, .source_node = null },
                    .failure => |failure| {
                        if (self.catchCaptureToken(handle, node)) |token| try self.bind(handle, token, failure);
                        break :blk self.evalSourceWithType(handle, rhs, destination);
                    },
                };
            },
            else => .{
                .value = try self.eval(handle, node) orelse return null,
                .source_node = node,
            },
        };
    }

    fn integer(self: *Interpreter, handle: *Handle, node: Ast.Node.Index) Error!?usize {
        return switch (try self.integerValue(handle, node) orelse return null) {
            .known => |value| std.math.cast(usize, value),
            .unknown => null,
        };
    }

    fn integerValue(self: *Interpreter, handle: *Handle, node: Ast.Node.Index) Error!?IntegerValue {
        const value = try self.eval(handle, node) orelse return null;
        const payload = switch (value.data) {
            .ip_index => |payload| payload,
            else => return null,
        };
        switch (self.analyser.ip.zigTypeTag(payload.type) orelse return null) {
            .int, .comptime_int => {},
            else => return null,
        }
        const index = payload.index orelse return .unknown;
        if (self.analyser.ip.isUndefined(index)) return null;
        if (self.analyser.ip.isUnknown(index)) return .unknown;
        return .{ .known = self.analyser.ip.toInt(index, u64) orelse return null };
    }

    fn coerce(self: *Interpreter, destination: Type, value: Type) Error!?Type {
        if (!destination.is_type_val) return null;
        const type_index = destination.ipIndex() orelse return value;
        if (type_index == .type_type) return if (value.is_type_val) value else null;
        if (value.data == .ip_index) {
            const coerced = try self.analyser.coerceComptimeIPValue(type_index, value) orelse return null;
            return Type.fromIP(self.analyser, type_index, coerced);
        }
        const source_type = try value.typeOf(self.analyser);
        if (source_type.ipIndex()) |source_type_index| {
            const source_value = Type.fromIP(self.analyser, source_type_index, null);
            _ = try self.analyser.coerceComptimeIPValue(type_index, source_value) orelse return null;
        }
        return switch (value.data) {
            .string_value => |string| try self.analyser.stringValueWithType(string.bytes, destination),
            .comptime_value => |comptime_value| switch (comptime_value.data) {
                .reference => |reference| try Value.create(self.analyser, destination, .{ .reference = reference }),
                .pointee => |pointee| try Value.create(self.analyser, destination, .{ .pointee = pointee }),
                .sequence => |sequence| try Value.create(self.analyser, destination, .{ .sequence = sequence }),
                else => value,
            },
            else => value,
        };
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
        const reference = try self.referenceForNode(handle, node);
        const value = if (reference) |target|
            try self.readReference(target) orelse return null
        else
            try self.eval(handle, node) orelse return null;
        if (value.data == .comptime_value and value.data.comptime_value.data == .reference)
            return value.data.comptime_value.data.reference;
        return reference;
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
        return self.readValuePath(target.storage.value, target.path);
    }

    fn coerceAssignmentTo(self: *Interpreter, destination: Type, value: Type) Error!?Type {
        return try self.coerce(destination, value) orelse
            try destination.instanceTypeVal(self.analyser);
    }

    fn assignmentChildType(
        self: *Interpreter,
        aggregate_type: Type,
        access: Value.Reference.Access,
    ) Error!?Type {
        const aggregate = try aggregate_type.instanceTypeVal(self.analyser) orelse return null;
        const child = switch (access) {
            .index => |index| try self.analyser.resolveBracketAccessType(aggregate, .{ .single = index }) orelse return null,
            .field => |name| try self.analyser.resolveFieldAccess(aggregate, name) orelse return null,
            .optional_payload => try self.analyser.resolveOptionalUnwrap(aggregate) orelse return null,
            .error_union_payload => try self.analyser.resolveUnwrapErrorUnionType(aggregate, .payload) orelse return null,
        };
        return @as(?Type, try child.typeOf(self.analyser));
    }

    fn isOptionalOrNullValue(self: *Interpreter, value: Type) Error!bool {
        const source_type = try value.typeOf(self.analyser);
        return switch (source_type.data) {
            .optional => true,
            .ip_index => |payload| switch (self.analyser.ip.indexToKey(payload.index orelse return false)) {
                .optional_type => true,
                .simple_type => |simple| simple == .null_type,
                else => false,
            },
            else => false,
        };
    }

    fn optionalPayloadType(self: *Interpreter, destination: Type) ?Type {
        if (!destination.is_type_val) return null;
        return switch (destination.data) {
            .optional => |payload| payload.*,
            .ip_index => |payload| switch (self.analyser.ip.indexToKey(payload.index orelse return null)) {
                .optional_type => |optional| Type.fromIP(self.analyser, .type_type, optional.payload_type),
                else => null,
            },
            else => null,
        };
    }

    const ErrorUnionTypes = struct {
        error_set: ?Type,
        payload: Type,
    };

    fn errorUnionTypes(self: *Interpreter, ty: Type) ?ErrorUnionTypes {
        if (!ty.is_type_val) return null;
        return switch (ty.data) {
            .error_union => |info| .{
                .error_set = if (info.error_set) |error_set| error_set.* else null,
                .payload = info.payload.*,
            },
            .ip_index => |value| switch (self.analyser.ip.indexToKey(value.index orelse return null)) {
                .error_union_type => |info| .{
                    .error_set = if (info.error_set_type != .none)
                        Type.fromIP(self.analyser, .type_type, info.error_set_type)
                    else
                        null,
                    .payload = Type.fromIP(self.analyser, .type_type, info.payload_type),
                },
                else => null,
            },
            else => null,
        };
    }

    fn isErrorValue(self: *Interpreter, value: Type) bool {
        const index = value.ipIndex() orelse return false;
        return self.analyser.ip.indexToKey(index) == .error_value;
    }

    fn isErrorUnionValue(self: *Interpreter, value: Type) Error!bool {
        if (value.data == .comptime_value and value.data.comptime_value.data == .error_union) return true;
        return self.errorUnionTypes(try value.typeOf(self.analyser)) != null;
    }

    fn errorUnionValue(self: *Interpreter, value: Type) Error!?Value.ErrorUnion {
        const resolved = try self.deref(value) orelse return null;
        if (resolved.data == .comptime_value and resolved.data.comptime_value.data == .error_union) {
            return resolved.data.comptime_value.data.error_union;
        }
        if (self.isErrorValue(resolved)) return .{ .failure = resolved };
        return null;
    }

    fn catchCaptureToken(self: *Interpreter, handle: *Handle, node: Ast.Node.Index) ?Ast.TokenIndex {
        _ = self;
        const token = handle.tree.nodeMainToken(node) + 2;
        if (token >= handle.tree.tokens.len or
            handle.tree.tokenTag(token - 1) != .pipe or
            handle.tree.tokenTag(token) != .identifier) return null;
        return token;
    }

    fn coerceArrayLiteral(
        self: *Interpreter,
        handle: *Handle,
        destination: Type,
        value: Type,
        item_nodes: []const Ast.Node.Index,
        allow_invalid: bool,
    ) Error!?Type {
        const coerced = try self.analyser.arena.alloc(Type, item_nodes.len);
        for (item_nodes, coerced, 0..) |item_node, *result, index| {
            const item = try self.analyser.resolveBracketAccessType(value, .{ .single = index }) orelse return null;
            const element_type = try self.assignmentChildType(destination, .{ .index = index }) orelse return null;
            result.* = try self.coerceFromSource(
                handle,
                element_type,
                item,
                item_node,
                null,
                allow_invalid,
            ) orelse return null;
        }
        return @as(?Type, try Value.create(self.analyser, destination, .{ .array = coerced }));
    }

    fn unknownArray(self: *Interpreter, destination: Type, len: usize) Error!?Type {
        const items = try self.analyser.arena.alloc(Type, len);
        for (items, 0..) |*item, index| {
            const element_type = try self.assignmentChildType(destination, .{ .index = index }) orelse return null;
            item.* = try element_type.instanceTypeVal(self.analyser) orelse return null;
        }
        return @as(?Type, try Value.create(self.analyser, destination, .{ .array = items }));
    }

    fn coerceFieldLiteral(
        self: *Interpreter,
        handle: *Handle,
        destination: Type,
        fields: []const Value.Field,
        field_nodes: []const Ast.Node.Index,
        allow_invalid: bool,
    ) Error!?Type {
        if (fields.len != field_nodes.len) return null;
        const tree = &handle.tree;
        const coerced = try self.analyser.arena.alloc(Value.Field, fields.len);
        for (fields, coerced) |field, *result| {
            const field_type = try self.assignmentChildType(destination, .{ .field = field.name }) orelse return null;
            const field_node = for (field_nodes) |node| {
                const name_token = tree.firstToken(node) - 2;
                if (tree.tokenTag(name_token) != .identifier) return null;
                const name = offsets.identifierTokenToNameSlice(tree, name_token);
                if (std.mem.eql(u8, field.name, name)) break node;
            } else return null;
            result.* = .{
                .name = field.name,
                .value = try self.coerceFromSource(
                    handle,
                    field_type,
                    field.value,
                    field_node,
                    null,
                    allow_invalid,
                ) orelse return null,
            };
        }
        return @as(?Type, try Value.create(self.analyser, destination, .{ .fields = coerced }));
    }

    fn assignmentAggregateLength(self: *Interpreter, destination: Type) ?usize {
        if (!destination.is_type_val) return null;
        const len: u64 = switch (destination.data) {
            .array => |array| array.elem_count orelse return null,
            .vector => |vector| vector.len,
            .tuple => |items| items.len,
            .ip_index => |payload| switch (self.analyser.ip.indexToKey(payload.index orelse return null)) {
                .array_type => |array| array.len,
                .vector_type => |vector| vector.len,
                .tuple_type => |tuple| tuple.types.len,
                else => return null,
            },
            else => return null,
        };
        return std.math.cast(usize, len);
    }

    fn unwrapGroupedSource(tree: *const Ast, node: Ast.Node.Index) Ast.Node.Index {
        var result = node;
        while (tree.nodeTag(result) == .grouped_expression) {
            result = tree.nodeData(result).node_and_token[0];
        }
        return result;
    }

    fn coerceAssignmentFromSource(
        self: *Interpreter,
        handle: *Handle,
        destination: Type,
        value: Type,
        source_node: ?Ast.Node.Index,
        declared_array_len: ?usize,
    ) Error!?Type {
        return self.coerceFromSource(handle, destination, value, source_node, declared_array_len, true);
    }

    fn coerceFromSource(
        self: *Interpreter,
        handle: *Handle,
        destination: Type,
        value: Type,
        source_node: ?Ast.Node.Index,
        declared_array_len: ?usize,
        allow_invalid: bool,
    ) Error!?Type {
        const analyser = self.analyser;
        const tree = &handle.tree;
        const source_is_unknown = if (value.ipIndex()) |index|
            analyser.ip.isUndefined(index) or analyser.ip.isUnknown(index)
        else
            false;
        if (self.errorUnionTypes(destination)) |types| {
            if (source_is_unknown) return self.coerce(destination, value);
            if (try self.errorUnionValue(value)) |error_union| {
                const coerced = switch (error_union) {
                    .payload => |payload| Value.ErrorUnion{ .payload = try self.coerceFromSource(
                        handle,
                        types.payload,
                        payload,
                        source_node,
                        declared_array_len,
                        allow_invalid,
                    ) orelse return null },
                    .failure => |failure| Value.ErrorUnion{ .failure = if (types.error_set) |error_set|
                        try self.coerce(error_set, failure) orelse return null
                    else
                        failure },
                };
                return @as(?Type, try Value.create(analyser, destination, .{ .error_union = coerced }));
            }
            if (!try self.isErrorUnionValue(value)) {
                if (self.isErrorValue(value)) {
                    const failure = if (types.error_set) |error_set|
                        try self.coerce(error_set, value) orelse return null
                    else
                        value;
                    return @as(?Type, try Value.create(analyser, destination, .{
                        .error_union = .{ .failure = failure },
                    }));
                }
                const payload = try self.coerceFromSource(
                    handle,
                    types.payload,
                    value,
                    source_node,
                    declared_array_len,
                    allow_invalid,
                ) orelse return null;
                return @as(?Type, try Value.create(analyser, destination, .{
                    .error_union = .{ .payload = payload },
                }));
            }
        }
        if (self.optionalPayloadType(destination)) |payload_type| {
            if (source_is_unknown) return self.coerce(destination, value);
            if (!try self.isOptionalOrNullValue(value)) {
                const payload = try self.coerceFromSource(
                    handle,
                    payload_type,
                    value,
                    source_node,
                    declared_array_len,
                    allow_invalid,
                ) orelse return null;
                return @as(?Type, try Value.create(analyser, destination, .{ .optional = payload }));
            }
        }
        var buffer: [2]Ast.Node.Index = undefined;
        if (source_node) |node| {
            const literal_node = unwrapGroupedSource(tree, node);
            if (tree.nodeTag(literal_node) == .address_of) static_pointer: {
                const pointee_type = destination.constMaterializedPointerChild(analyser) orelse break :static_pointer;
                const operand = unwrapGroupedSource(tree, tree.nodeData(literal_node).node);
                const target = try self.staticPointeeTarget(handle, operand, 0) orelse break :static_pointer;
                const declaration = target.declaration;
                const declaration_node = switch (declaration.decl) {
                    .ast_node => |decl_node| decl_node,
                    else => break :static_pointer,
                };
                const is_static = try declaration.isStatic();
                const pointee = if (is_static and declaration.isConst())
                    try self.staticCaptureValue(handle, operand) orelse
                        return if (allow_invalid) destination.instanceTypeVal(analyser) else null
                else if (target.path.len != 0)
                    try self.evaluateTypedWithContainer(
                        handle,
                        operand,
                        pointee_type,
                        declaration.container_type,
                    ) orelse return if (allow_invalid) destination.instanceTypeVal(analyser) else null
                else switch (declaration.handle.tree.nodeTag(declaration_node)) {
                    .fn_decl => try self.evaluateTypedWithContainer(
                        handle,
                        operand,
                        pointee_type,
                        declaration.container_type,
                    ) orelse
                        return if (allow_invalid) destination.instanceTypeVal(analyser) else null,
                    .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => blk: {
                        if (!declaration.isConst()) break :static_pointer;
                        if (!is_static) {
                            break :blk self.bindings.get(.{
                                .handle = declaration.handle,
                                .token = declaration.nameToken(),
                            }) orelse break :static_pointer;
                        }
                        const variable = declaration.handle.tree.fullVarDecl(declaration_node).?;
                        const initializer = variable.ast.init_node.unwrap() orelse break :static_pointer;
                        break :blk try self.evaluateTypedWithContainer(
                            declaration.handle,
                            initializer,
                            pointee_type,
                            declaration.container_type,
                        ) orelse
                            return if (allow_invalid) destination.instanceTypeVal(analyser) else null;
                    },
                    else => break :static_pointer,
                };
                return @as(?Type, try Value.create(analyser, destination, .{ .pointee = .{
                    .value = pointee,
                    .source = .of(declaration_node, declaration.handle),
                    .container_type = declaration.container_type,
                    .path = target.path,
                    .is_static = is_static,
                } }));
            }
            if (tree.nodeTag(literal_node) == .address_of) aggregate_pointer: {
                const pointee = destination.constAggregatePointerChild(analyser) orelse break :aggregate_pointer;
                const operand = unwrapGroupedSource(tree, tree.nodeData(literal_node).node);
                const literal = tree.fullStructInit(&buffer, operand) orelse break :aggregate_pointer;
                if (literal.ast.type_expr != .none) break :aggregate_pointer;
                const pointee_value = try self.evaluateTypedExpression(handle, operand, pointee) orelse
                    return if (allow_invalid) destination.instanceTypeVal(analyser) else null;
                const fields = Value.fieldEntries(pointee_value) orelse
                    return if (allow_invalid) destination.instanceTypeVal(analyser) else null;
                return @as(?Type, try Value.create(analyser, destination, .{ .fields = fields }));
            }
            if (tree.nodeTag(literal_node) == .address_of and
                destination.isConstSequencePointerType(analyser))
            {
                const operand = unwrapGroupedSource(tree, tree.nodeData(literal_node).node);
                if (tree.fullArrayInit(&buffer, operand)) |literal| {
                    if (literal.ast.type_expr == .none) {
                        if (destination.sequencePointerLength(analyser)) |len| {
                            if (literal.ast.elements.len != len)
                                return if (allow_invalid) destination.instanceTypeVal(analyser) else null;
                        }
                        if (literal.ast.elements.len > self.budget.steps)
                            return if (allow_invalid) destination.instanceTypeVal(analyser) else null;
                        const items = try analyser.arena.alloc(Type, literal.ast.elements.len);
                        for (literal.ast.elements, items, 0..) |item_node, *item, index| {
                            const element_type = try self.assignmentChildType(destination, .{ .index = index }) orelse
                                return null;
                            item.* = try self.evaluateTypedExpression(handle, item_node, element_type) orelse
                                if (allow_invalid)
                                    try element_type.instanceTypeVal(analyser) orelse return null
                                else
                                    return null;
                        }
                        return @as(?Type, try Value.create(analyser, destination, .{ .array = items }));
                    }
                }
            }
            if (tree.nodeTag(literal_node) == .enum_literal) {
                if (destination.isEnumType(analyser)) {
                    const tag = try analyser.resolveEnumValueTag(destination, .of(literal_node, handle)) orelse return null;
                    return @as(?Type, try analyser.enumValue(destination, tag));
                }
                if (destination.ipIndex() == .enum_literal_type) {
                    const tag = try analyser.identifierTokenName(tree, tree.nodeMainToken(literal_node)) orelse return null;
                    return @as(?Type, try analyser.enumValue(destination, tag));
                }
            }
            if (tree.fullArrayInit(&buffer, literal_node)) |literal| {
                if (literal.ast.type_expr == .none) {
                    if (declared_array_len orelse self.assignmentAggregateLength(destination)) |len| {
                        if (len > self.budget.steps) return if (allow_invalid) destination.instanceTypeVal(analyser) else null;
                        if (literal.ast.elements.len == len) {
                            if (try self.coerceArrayLiteral(handle, destination, value, literal.ast.elements, allow_invalid)) |result| return result;
                        }
                        return if (allow_invalid) self.unknownArray(destination, len) else null;
                    }
                }
            }
            if (tree.fullStructInit(&buffer, literal_node)) |literal| {
                if (literal.ast.type_expr == .none and literal.ast.fields.len == 0) {
                    if (self.assignmentAggregateLength(destination)) |len| {
                        if (len == 0) return @as(?Type, try Value.create(analyser, destination, .{ .array = &.{} }));
                        return if (allow_invalid and len <= self.budget.steps) self.unknownArray(destination, len) else null;
                    }
                }
                if (literal.ast.type_expr == .none and
                    (destination.isStructType(analyser) or self.isUnionType(destination)))
                {
                    const fields = Value.fieldEntries(value);
                    if (fields != null and (!self.isUnionType(destination) or literal.ast.fields.len == 1)) {
                        if (try self.coerceFieldLiteral(handle, destination, fields.?, literal.ast.fields, allow_invalid)) |result| return result;
                    }
                    return if (allow_invalid) destination.instanceTypeVal(analyser) else null;
                }
            }
        }
        if (declared_array_len) |len| {
            const items = try self.mutableElements(value);
            return if (items != null)
                try self.coerce(destination, value) orelse try self.unknownArray(destination, len)
            else
                try self.unknownArray(destination, len);
        }
        if (destination.isConstSequencePointerType(analyser) and
            !(try value.typeOf(analyser)).eql(destination))
        {
            if (try Value.sequenceAlloc(analyser, value)) |sequence| {
                _ = try self.coerce(destination, value) orelse
                    return if (allow_invalid) destination.instanceTypeVal(analyser) else null;
                return @as(?Type, try Value.create(analyser, destination, .{ .sequence = sequence }));
            }
        }
        return if (allow_invalid) self.coerceAssignmentTo(destination, value) else self.coerce(destination, value);
    }

    fn writeReference(
        self: *Interpreter,
        handle: *Handle,
        target: *Value.Reference,
        value: Type,
        source_node: ?Ast.Node.Index,
    ) Error!bool {
        const destination = try target.storage.value.typeOf(self.analyser);
        target.storage.value = try self.replaceReferenceValue(handle, target.storage.value, destination, target.path, value, source_node) orelse return false;
        return true;
    }

    fn replaceReferenceValue(
        self: *Interpreter,
        handle: *Handle,
        current: Type,
        destination: Type,
        path: []const Value.Reference.Access,
        value: Type,
        source_node: ?Ast.Node.Index,
    ) Error!?Type {
        if (path.len == 0) return self.coerceAssignmentFromSource(handle, destination, value, source_node, null);
        const analyser = self.analyser;
        const child_destination = try self.assignmentChildType(destination, path[0]) orelse return null;
        switch (path[0]) {
            .index => |index| {
                const items = try self.mutableElements(current) orelse return null;
                if (index >= items.len) return null;
                const updated = try analyser.arena.dupe(Type, items);
                updated[index] = try self.replaceReferenceValue(handle, items[index], child_destination, path[1..], value, source_node) orelse return null;
                return try Value.create(analyser, destination, .{ .array = updated });
            },
            .field => |field_name| {
                const old_value = try analyser.resolveFieldAccess(current, field_name) orelse return null;
                const new_value = try self.replaceReferenceValue(handle, old_value, child_destination, path[1..], value, source_node) orelse return null;
                const fields = Value.fieldEntries(current) orelse return null;
                const updated = try analyser.arena.dupe(Value.Field, fields);
                for (updated) |*field| {
                    if (!std.mem.eql(u8, field.name, field_name)) continue;
                    field.value = new_value;
                    return try Value.create(analyser, destination, .{ .fields = updated });
                }
                if (!destination.isStructType(analyser)) return null;
                if (try analyser.lookupSymbolContainer(try destination.instanceUnchecked(analyser), field_name, .field) == null) return null;
                const extended = try analyser.arena.alloc(Value.Field, fields.len + 1);
                @memcpy(extended[0..fields.len], fields);
                extended[fields.len] = .{ .name = field_name, .value = new_value };
                return try Value.create(analyser, destination, .{ .fields = extended });
            },
            .optional_payload => {
                const old_value = try analyser.resolveOptionalUnwrap(current) orelse return null;
                const new_value = try self.replaceReferenceValue(handle, old_value, child_destination, path[1..], value, source_node) orelse return null;
                return try Value.create(analyser, destination, .{ .optional = new_value });
            },
            .error_union_payload => {
                const old_value = switch (try self.errorUnionValue(current) orelse return null) {
                    .payload => |payload| payload,
                    .failure => return null,
                };
                const new_value = try self.replaceReferenceValue(handle, old_value, child_destination, path[1..], value, source_node) orelse return null;
                return try Value.create(analyser, destination, .{ .error_union = .{ .payload = new_value } });
            },
        }
    }

    fn conditionValue(
        self: *Interpreter,
        handle: *Handle,
        condition: Ast.Node.Index,
        payload_token: ?Ast.TokenIndex,
        error_token: ?Ast.TokenIndex,
    ) Error!?bool {
        if (payload_token == null and error_token == null)
            return self.boolValue(try self.eval(handle, condition) orelse return null);
        const capture_by_ref = if (payload_token) |token| handle.tree.tokenTag(token) == .asterisk else false;
        const operand: CaptureOperand = if (capture_by_ref)
            try self.captureOperand(handle, condition, 0) orelse return null
        else
            .{ .value = try self.eval(handle, condition) orelse return null, .target = null };
        const value = operand.value;
        if (error_token) |failure_token| {
            return switch (try self.errorUnionValue(value) orelse return null) {
                .failure => |failure| failure: {
                    try self.bind(handle, failure_token, failure);
                    break :failure false;
                },
                .payload => |payload| success: {
                    if (payload_token) |payload_capture| {
                        const captured = if (capture_by_ref)
                            try self.captureTargetPointer(
                                operand.target orelse return null,
                                payload,
                                .error_union_payload,
                            ) orelse return null
                        else
                            payload;
                        try self.bind(handle, payload_capture + @intFromBool(capture_by_ref), captured);
                    }
                    break :success true;
                },
            };
        }
        const payload = switch (try self.optionalValue(value) orelse return null) {
            .absent => return false,
            .payload => |payload| payload,
        };
        const captured = if (capture_by_ref)
            try self.captureTargetPointer(
                operand.target orelse return null,
                payload,
                .optional_payload,
            ) orelse return null
        else
            payload;
        const token = payload_token.?;
        try self.bind(handle, token + @intFromBool(capture_by_ref), captured);
        return true;
    }

    fn staticCaptureValue(self: *Interpreter, handle: *Handle, condition: Ast.Node.Index) Error!?Type {
        return self.staticCaptureValueDepth(handle, condition, 0);
    }

    fn staticSequenceValue(self: *Interpreter, handle: *Handle, node: Ast.Node.Index) Error!?Type {
        const target = try self.staticPointeeTarget(handle, node, 0) orelse return null;
        if (!target.declaration.isConst() or !try target.declaration.isStatic()) return null;
        const value = try self.staticCaptureValue(handle, node) orelse return null;
        if (try Value.sequenceAlloc(self.analyser, value)) |sequence| {
            if (sequence.origin != null) return value;
        }
        const declaration_node = switch (target.declaration.decl) {
            .ast_node => |declaration| declaration,
            else => return null,
        };
        const origin: Value.Pointee = .{
            .value = value,
            .source = .of(declaration_node, target.declaration.handle),
            .container_type = target.declaration.container_type,
            .path = target.path,
            .is_static = true,
        };
        const pointer = try self.analyser.resolveAddressOf(true, value);
        const pointee = try Value.create(
            self.analyser,
            try pointer.typeOf(self.analyser),
            .{ .pointee = origin },
        );
        const sequence = try Value.sequenceAlloc(self.analyser, pointee) orelse return null;
        return @as(?Type, try Value.create(self.analyser, try value.typeOf(self.analyser), .{ .sequence = sequence }));
    }

    fn staticCaptureValueDepth(
        self: *Interpreter,
        handle: *Handle,
        condition: Ast.Node.Index,
        depth: u8,
    ) Error!?Type {
        if (depth == 128) return null;
        const target = try self.staticPointeeTarget(handle, condition, 0) orelse return null;
        if (!target.declaration.isConst() or !try target.declaration.isStatic()) return null;
        const declaration_node = switch (target.declaration.decl) {
            .ast_node => |node| node,
            else => return null,
        };
        const variable = target.declaration.handle.tree.fullVarDecl(declaration_node) orelse return null;
        const initializer = variable.ast.init_node.unwrap() orelse return null;
        const declaration_value = try target.declaration.resolveType(self.analyser) orelse return null;
        const destination = try declaration_value.typeOf(self.analyser);
        const root_value = if (try self.staticCaptureValueDepth(target.declaration.handle, initializer, depth + 1)) |value|
            try self.coerceAssignmentFromSource(
                target.declaration.handle,
                destination,
                value,
                initializer,
                null,
            ) orelse return null
        else
            try self.evaluateTypedWithContainer(
                target.declaration.handle,
                initializer,
                destination,
                target.declaration.container_type,
            ) orelse return null;
        return self.readValuePath(root_value, target.path);
    }

    fn readValuePath(
        self: *Interpreter,
        value: Type,
        path: []const Value.Reference.Access,
    ) Error!?Type {
        var current = value;
        for (path) |access| {
            current = switch (access) {
                .index => |index| blk: {
                    const items = try self.mutableElements(current) orelse return null;
                    if (index >= items.len) return null;
                    break :blk items[index];
                },
                .field => |name| try self.analyser.resolveFieldAccess(current, name) orelse return null,
                .optional_payload => try self.analyser.resolveOptionalUnwrap(current) orelse return null,
                .error_union_payload => switch (try self.errorUnionValue(current) orelse return null) {
                    .payload => |payload| payload,
                    .failure => return null,
                },
            };
        }
        return current;
    }

    fn sequenceElementPointer(self: *Interpreter, value: Type, index: usize) Error!?Type {
        const sequence = try Value.sequenceAlloc(self.analyser, value) orelse return null;
        if (index >= sequence.len or !sequence.elements_valid) return null;
        const offset = std.math.add(usize, sequence.offset, index) catch return null;
        const item = sequence.backing[offset];
        const pointer = try self.analyser.resolveAddressOf(true, item);
        if (sequence.origin) |origin| {
            const path = try self.analyser.arena.alloc(Value.Reference.Access, origin.path.len + 1);
            @memcpy(path[0..origin.path.len], origin.path);
            path[origin.path.len] = .{ .index = offset };
            return @as(?Type, try Value.create(self.analyser, try pointer.typeOf(self.analyser), .{ .pointee = .{
                .value = item,
                .source = origin.source,
                .container_type = origin.container_type,
                .path = path,
                .is_static = origin.is_static,
            } }));
        }
        return @as(?Type, try Value.create(self.analyser, try pointer.typeOf(self.analyser), .{ .sequence = .{
            .backing = sequence.backing,
            .offset = offset,
            .len = 1,
            .elements_valid = true,
        } }));
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
            .simple_value => |simple| if (simple == .null_value) .absent else null,
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
            return self.writeReference(handle, current.data.comptime_value.data.reference, updated, null);
        }
        return self.write(handle, base, updated, null);
    }

    fn write(
        self: *Interpreter,
        handle: *Handle,
        node: Ast.Node.Index,
        value: Type,
        source_node: ?Ast.Node.Index,
    ) Error!bool {
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
            const aggregate_type = try current.typeOf(analyser);
            const destination = try self.assignmentChildType(aggregate_type, .{ .index = index }) orelse return false;
            updated[index] = try self.coerceAssignmentFromSource(handle, destination, value, source_node, null) orelse return false;
            const updated_value = try Value.create(analyser, aggregate_type, .{ .array = updated });
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
                const destination = try self.assignmentChildType(aggregate_type, .{ .index = index }) orelse return false;
                updated[index] = try self.coerceAssignmentFromSource(handle, destination, value, source_node, null) orelse return false;
                const updated_value = try Value.create(analyser, aggregate_type, .{ .array = updated });
                return self.writeAggregate(handle, base, base_value, updated_value);
            }
            const destination = try self.assignmentChildType(aggregate_type, .{ .field = field_name }) orelse return false;
            const coerced = try self.coerceAssignmentFromSource(handle, destination, value, source_node, null) orelse return false;
            const fields = Value.fieldEntries(current) orelse return false;
            const updated = try analyser.arena.dupe(Value.Field, fields);
            for (updated) |*field| {
                if (!std.mem.eql(u8, field.name, field_name)) continue;
                field.value = coerced;
                const updated_value = try Value.create(analyser, aggregate_type, .{ .fields = updated });
                return self.writeAggregate(handle, base, base_value, updated_value);
            }
            if (!aggregate_type.isStructType(analyser)) return false;
            if (try analyser.lookupSymbolContainer(try aggregate_type.instanceUnchecked(analyser), field_name, .field) == null) return false;
            const extended = try analyser.arena.alloc(Value.Field, fields.len + 1);
            @memcpy(extended[0..fields.len], fields);
            extended[fields.len] = .{ .name = field_name, .value = coerced };
            const updated_value = try Value.create(analyser, aggregate_type, .{ .fields = extended });
            return self.writeAggregate(handle, base, base_value, updated_value);
        }
        if (tree.nodeTag(node) == .unwrap_optional) {
            const base = tree.nodeData(node).node_and_token[0];
            const base_value = try self.eval(handle, base) orelse return false;
            const current = try self.deref(base_value) orelse return false;
            const aggregate_type = try current.typeOf(analyser);
            if (try analyser.resolveOptionalUnwrap(current) == null) return false;
            const destination = try self.assignmentChildType(aggregate_type, .optional_payload) orelse return false;
            const coerced = try self.coerceAssignmentFromSource(handle, destination, value, source_node, null) orelse return false;
            const updated_value = try Value.create(analyser, aggregate_type, .{ .optional = coerced });
            return self.writeAggregate(handle, base, base_value, updated_value);
        }
        if (tree.nodeTag(node) == .deref) {
            const pointer = try self.eval(handle, tree.nodeData(node).node) orelse return false;
            if (pointer.data != .comptime_value or pointer.data.comptime_value.data != .reference) return false;
            return self.writeReference(handle, pointer.data.comptime_value.data.reference, value, source_node);
        }
        const storage = try self.cell(handle, node) orelse return false;
        const destination = try storage.value.typeOf(analyser);
        storage.value = try self.coerceAssignmentFromSource(
            handle,
            destination,
            value,
            source_node,
            null,
        ) orelse return false;
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

    fn containsOwnedReference(self: *Interpreter, value: Type, depth: u8) bool {
        if (depth == 128 or value.data != .comptime_value) return depth == 128;
        return switch (value.data.comptime_value.data) {
            .reference => |reference| for (self.cells.values()) |storage| {
                if (reference.storage == storage) break true;
            } else false,
            .pointee => |pointee| self.containsOwnedReference(pointee.value, depth + 1),
            .array => |items| for (items) |item| {
                if (self.containsOwnedReference(item, depth + 1)) break true;
            } else false,
            .sequence => |sequence| for (sequence.backing) |item| {
                if (self.containsOwnedReference(item, depth + 1)) break true;
            } else false,
            .fields => |fields| for (fields) |field| {
                if (self.containsOwnedReference(field.value, depth + 1)) break true;
            } else false,
            .optional => |payload| if (payload) |item| self.containsOwnedReference(item, depth + 1) else false,
            .error_union => |result| switch (result) {
                inline else => |item| self.containsOwnedReference(item, depth + 1),
            },
            .expression => false,
        };
    }

    fn declare(
        self: *Interpreter,
        handle: *Handle,
        decl: Ast.full.VarDecl,
        initial_value: Type,
        initial_node: ?Ast.Node.Index,
        declared_type: ?Type,
    ) Error!bool {
        const analyser = self.analyser;
        const tree = &handle.tree;
        var value = initial_value;
        if (declared_type) |ty| {
            const len = if (tree.fullArrayType(decl.ast.type_node.unwrap().?) != null)
                self.assignmentAggregateLength(ty) orelse return false
            else
                null;
            if (len) |count| if (count > self.budget.steps) return false;
            value = try self.coerceAssignmentFromSource(handle, ty, value, initial_node, len) orelse return false;
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

    fn block(
        self: *Interpreter,
        handle: *Handle,
        node: Ast.Node.Index,
        destination: ?Type,
        preserve_capture_target: bool,
    ) Error!Flow {
        const tree = &handle.tree;
        const context: BreakContext = .{
            .parent = self.break_context,
            .label = ast.blockLabel(tree, node),
            .destination = destination,
            .is_loop = false,
            .preserve_capture_target = preserve_capture_target,
        };
        self.break_context = &context;
        defer self.break_context = context.parent;
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, node) orelse return .unknown;
        var executed_count: usize = 0;
        var block_flow: Flow = .next;
        for (statements) |child| {
            executed_count += 1;
            if (tree.nodeTag(child) == .@"defer" or tree.nodeTag(child) == .@"errdefer") continue;
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
                        if (stopped.result) |result| .{ .value = result } else .next
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
        const failure = switch (block_flow) {
            .returned => |result| if (try self.errorUnionValue(result.value)) |error_union| switch (error_union) {
                .failure => |value| value,
                .payload => null,
            } else null,
            else => null,
        };
        while (executed_count > 0) {
            executed_count -= 1;
            const child = statements[executed_count];
            const deferred = switch (tree.nodeTag(child)) {
                .@"defer" => tree.nodeData(child).node,
                .@"errdefer" => if (failure) |value| blk: {
                    const payload, const expression = tree.nodeData(child).opt_token_and_node;
                    if (payload.unwrap()) |token| try self.bind(handle, token, value);
                    break :blk expression;
                } else continue,
                else => continue,
            };
            if (try self.statement(handle, deferred) != .next) return .unknown;
        }
        return block_flow;
    }

    fn ifTarget(self: *Interpreter, handle: *Handle, node: Ast.Node.Index) Error!?BranchTarget {
        const branch = ast.fullIf(&handle.tree, node).?;
        const known = try self.conditionValue(handle, branch.ast.cond_expr, branch.payload_token, branch.error_token) orelse return null;
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
        const has_pointer_capture = switchHasPointerCapture(tree, switch_node);
        const operand: CaptureOperand = if (has_pointer_capture)
            try self.captureOperand(handle, switch_node.ast.condition, 0) orelse return null
        else
            .{ .value = try self.eval(handle, switch_node.ast.condition) orelse return null, .target = null };
        return self.switchTargetForCondition(handle, node, operand.value, operand.target);
    }

    fn switchHasPointerCapture(tree: *const Ast, switch_node: Ast.full.Switch) bool {
        return for (switch_node.ast.cases) |case| {
            if (tree.fullSwitchCase(case).?.payload_token) |token| {
                if (tree.tokenTag(token) == .asterisk) break true;
            }
        } else false;
    }

    fn switchTargetForCondition(
        self: *Interpreter,
        handle: *Handle,
        node: Ast.Node.Index,
        condition: Type,
        capture_target: ?CaptureTarget,
    ) Error!?Ast.Node.Index {
        const tree = &handle.tree;
        const switch_node = tree.switchFull(node);
        const target = try self.analyser.resolveKnownSwitchTargetFromValue(.of(node, handle), condition) orelse return null;
        for (switch_node.ast.cases) |case| {
            const switch_case = tree.fullSwitchCase(case).?;
            if (switch_case.ast.target_expr != target) continue;
            if (switch_case.payload_token) |payload_token| {
                const capture_by_ref = tree.tokenTag(payload_token) == .asterisk;
                const name_token = payload_token + @intFromBool(capture_by_ref);
                const captured = if (capture_by_ref) captured: {
                    var literal_buffer: [2]Ast.Node.Index = undefined;
                    const aggregate_case = for (switch_case.ast.values) |case_value| {
                        if (tree.fullStructInit(&literal_buffer, case_value) != null or
                            tree.fullArrayInit(&literal_buffer, case_value) != null) break true;
                    } else false;
                    const active_field = if (aggregate_case)
                        null
                    else
                        try self.analyser.resolveKnownUnionFieldName(condition);
                    const has_payload_field = active_field != null and
                        (switch_case.ast.values.len != 0 or switch_case.inline_token != null);
                    const payload = try self.analyser.resolveSwitchCaptureValue(
                        condition,
                        tree,
                        switch_node,
                        switch_case,
                        false,
                    ) orelse return null;
                    break :captured try self.captureTargetPointer(
                        capture_target orelse return null,
                        payload,
                        if (has_payload_field) .{ .field = active_field.? } else null,
                    ) orelse return null;
                } else try self.analyser.resolveSwitchCaptureValue(condition, tree, switch_node, switch_case, false) orelse return null;
                try self.bind(handle, name_token, captured);
                if (tree.tokenTag(name_token + 1) == .comma) {
                    const tag = try self.analyser.resolveSwitchCaptureValue(condition, tree, switch_node, switch_case, true) orelse return null;
                    try self.bind(handle, name_token + 2, tag);
                }
            }
            return target;
        }
        return null;
    }

    fn switchLoop(
        self: *Interpreter,
        handle: *Handle,
        node: Ast.Node.Index,
        expression: bool,
        destination: ?Type,
    ) Error!Flow {
        const tree = &handle.tree;
        const switch_node = tree.switchFull(node);
        const label_token = switch_node.label_token orelse return .unknown;
        const continue_by_ref = switchHasPointerCapture(tree, switch_node);
        var reference = if (continue_by_ref)
            try self.referenceForNode(handle, switch_node.ast.condition) orelse return .unknown
        else
            null;
        var condition = if (reference) |target|
            try self.readReference(target) orelse return .unknown
        else
            try self.eval(handle, switch_node.ast.condition) orelse return .unknown;
        const condition_type = try condition.typeOf(self.analyser);
        const context: BreakContext = .{
            .parent = self.break_context,
            .label = label_token,
            .destination = destination,
            .is_loop = false,
            .continue_destination = condition_type,
            .continue_by_ref = continue_by_ref,
        };
        self.break_context = &context;
        defer self.break_context = context.parent;

        while (true) {
            const target = try self.switchTargetForCondition(
                handle,
                node,
                condition,
                if (reference) |value| .{ .reference = value } else null,
            ) orelse return .unknown;
            const flow: Flow = if (expression) expression_flow: {
                const result = try self.evalSourceWithType(handle, target, destination);
                if (self.pending_flow) |pending| {
                    self.pending_flow = null;
                    break :expression_flow pending;
                }
                break :expression_flow if (result) |value| .{ .value = value } else .unknown;
            } else try self.statement(handle, target);
            switch (flow) {
                .continued => |continued| {
                    const target_label = continued.target orelse return flow;
                    if (!std.mem.eql(u8, tree.tokenSlice(label_token), tree.tokenSlice(target_label))) return flow;
                    const next = continued.result orelse return .unknown;
                    condition = next.value;
                    reference = next.reference;
                },
                .stopped => |stopped| {
                    const target_label = stopped.target orelse return flow;
                    if (!std.mem.eql(u8, tree.tokenSlice(label_token), tree.tokenSlice(target_label))) return flow;
                    if (stopped.result) |result| return if (expression) .{ .value = result } else .unknown;
                    return .next;
                },
                else => return flow,
            }
        }
    }

    fn internVectorOperand(self: *Interpreter, value: Type) Error!?Type {
        if (value.data != .comptime_value) return value;
        const type_index = value.data.comptime_value.ty.ipIndex() orelse return value;
        const vector = switch (self.analyser.ip.indexToKey(type_index)) {
            .vector_type => |vector| vector,
            else => return value,
        };
        const items = Value.elements(value) orelse return null;
        if (items.len != vector.len) return null;
        const indices = try self.analyser.arena.alloc(InternPool.Index, items.len);
        for (items, indices) |item, *index| {
            index.* = try self.analyser.coerceComptimeIPValue(vector.child, item) orelse return null;
        }
        const aggregate = try self.analyser.ip.get(.{ .aggregate = .{
            .ty = type_index,
            .values = try self.analyser.ip.getIndexSlice(indices),
        } });
        return Type.fromIP(self.analyser, type_index, aggregate);
    }

    fn compoundOperandType(self: *Interpreter, destination: Type, operation: Ast.Node.Tag) Error!?Type {
        if (operation == .shl_sat) return null;
        if (operation == .shl or operation == .shr) {
            const type_index = destination.ipIndex() orelse return null;
            if (type_index == .comptime_int_type) return destination;
            switch (self.analyser.ip.indexToKey(type_index)) {
                .vector_type => |vector| {
                    const child = try self.compoundOperandType(Type.fromIP(self.analyser, .type_type, vector.child), operation) orelse return null;
                    return self.analyser.resolveComptimeVectorType(vector.len, child);
                },
                else => {},
            }
            if (self.analyser.ip.zigTypeTag(type_index) != .int) return null;
            const bits = self.analyser.ip.intInfo(type_index, builtin.target).bits;
            const shift_type = try self.analyser.ip.get(.{ .int_type = .{
                .signedness = .unsigned,
                .bits = if (bits == 0) 0 else std.math.log2_int_ceil(u16, bits),
            } });
            return Type.fromIP(self.analyser, .type_type, shift_type);
        }
        const pointer_size = switch (destination.data) {
            .pointer => |pointer| pointer.size,
            .ip_index => |payload| switch (self.analyser.ip.indexToKey(payload.index orelse return destination)) {
                .pointer_type => |pointer| pointer.flags.size,
                else => null,
            },
            else => null,
        };
        if (pointer_size == .many or pointer_size == .c) {
            if (operation == .add or operation == .sub) return Type.fromIP(self.analyser, .type_type, .usize_type);
        }
        return destination;
    }

    fn statement(self: *Interpreter, handle: *Handle, node: Ast.Node.Index) Error!Flow {
        const flow = if (self.pending_flow == null) try self.statementInner(handle, node) else .unknown;
        if (self.pending_flow) |pending| {
            self.pending_flow = null;
            return pending;
        }
        return flow;
    }

    fn statementInner(self: *Interpreter, handle: *Handle, node: Ast.Node.Index) Error!Flow {
        if (!self.tick()) return .unknown;
        const analyser = self.analyser;
        const tree = &handle.tree;
        var buffer: [2]Ast.Node.Index = undefined;
        if (tree.blockStatements(&buffer, node) != null) {
            return switch (try self.block(handle, node, null, false)) {
                .value => .next,
                else => |flow| flow,
            };
        }
        if (tree.fullVarDecl(node)) |decl| {
            const init_node = decl.ast.init_node.unwrap() orelse return .unknown;
            const declared_type = if (decl.ast.type_node.unwrap()) |type_node|
                try self.eval(handle, type_node) orelse return .unknown
            else
                null;
            const evaluated = try self.evalSourceWithType(handle, init_node, declared_type);
            const value = if (evaluated) |result| result.value else Type.unknown_type;
            const source_node = if (evaluated) |result| result.source_node else init_node;
            if (!try self.declare(handle, decl, value, source_node, declared_type)) return .unknown;
            return .next;
        }
        switch (tree.nodeTag(node)) {
            .@"comptime", .@"nosuspend" => return self.statement(handle, tree.nodeData(node).node),
            .@"try" => {
                _ = try self.eval(handle, node) orelse return .unknown;
                return .next;
            },
            .@"catch", .@"orelse" => {
                _ = try self.eval(handle, node) orelse return .unknown;
                return .next;
            },
            .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => {
                const value = try self.eval(handle, node) orelse return .unknown;
                if (value.ipIndex() != .void_value) return .unknown;
                return .next;
            },
            .@"return" => return .{ .returned = if (tree.nodeData(node).opt_node.unwrap()) |expression| blk: {
                const result = (if (self.return_type) |destination|
                    try self.evalTypedSource(handle, expression, destination)
                else
                    try self.evalSource(handle, expression)) orelse return .unknown;
                break :blk .{
                    .value = try self.captureBindings(result.value),
                    .source_node = result.source_node,
                };
            } else .{
                .value = Type.fromIP(analyser, .void_type, .void_value),
                .source_node = null,
            } },
            .@"continue" => {
                const label, const operand = tree.nodeData(node).opt_token_and_opt_node;
                const target_label = label.unwrap();
                const result: ?ContinueResult = if (operand.unwrap()) |expression| blk: {
                    var context = self.break_context;
                    const target: *const BreakContext = while (context) |target| : (context = target.parent) {
                        const continue_label = target_label orelse continue;
                        const context_label = target.label orelse continue;
                        if (std.mem.eql(u8, tree.tokenSlice(continue_label), tree.tokenSlice(context_label)) and
                            target.continue_destination != null) break target;
                    } else return .unknown;
                    if (target.continue_by_ref) {
                        const reference = try self.referenceForNode(handle, expression) orelse return .unknown;
                        const value = try self.readReference(reference) orelse return .unknown;
                        _ = try self.coerce(target.continue_destination.?, value) orelse return .unknown;
                        break :blk .{
                            .value = value,
                            .reference = reference,
                        };
                    }
                    const evaluated = try self.evalTypedSource(handle, expression, target.continue_destination.?) orelse return .unknown;
                    const value = try self.coerceFromSource(
                        handle,
                        target.continue_destination.?,
                        evaluated.value,
                        evaluated.source_node,
                        null,
                        self.optionalPayloadType(target.continue_destination.?) != null,
                    ) orelse return .unknown;
                    break :blk .{ .value = value };
                } else null;
                return .{ .continued = .{ .target = target_label, .result = result } };
            },
            .@"break" => {
                const label, const operand = tree.nodeData(node).opt_token_and_opt_node;
                const result: ?EvaluatedSource = if (operand.unwrap()) |expression| blk: {
                    var context = self.break_context;
                    const break_target: ?*const BreakContext = while (context) |target| : (context = target.parent) {
                        if (label.unwrap()) |target_label| {
                            const context_label = target.label orelse continue;
                            if (!std.mem.eql(u8, tree.tokenSlice(target_label), tree.tokenSlice(context_label))) continue;
                        } else if (!target.is_loop) continue;
                        break target;
                    } else null;
                    const destination = if (break_target) |target| target.destination else null;
                    if (break_target) |target| {
                        if (target.preserve_capture_target) {
                            const captured = try self.captureOperand(handle, expression, 0) orelse return .unknown;
                            break :blk .{
                                .value = try self.captureBindings(captured.value),
                                .source_node = expression,
                                .capture_target = captured.target,
                            };
                        }
                    }
                    const evaluated = try self.evalSourceWithType(handle, expression, destination) orelse return .unknown;
                    break :blk .{
                        .value = try self.captureBindings(evaluated.value),
                        .source_node = evaluated.source_node,
                    };
                } else null;
                return .{ .stopped = .{ .target = label.unwrap(), .result = result } };
            },
            .if_simple, .@"if" => {
                const target = try self.ifTarget(handle, node) orelse return .unknown;
                return switch (target) {
                    .none => .next,
                    .node => |target_node| self.statement(handle, target_node),
                };
            },
            .for_simple, .@"for" => return self.forLoop(handle, tree.fullFor(node).?, false, null, false),
            .while_simple, .while_cont, .@"while" => return self.whileLoop(handle, ast.fullWhile(tree, node).?, false, null, false),
            .@"switch", .switch_comma => {
                if (tree.switchFull(node).label_token != null) return self.switchLoop(handle, node, false, null);
                const target = try self.switchTarget(handle, node) orelse return .unknown;
                return self.statement(handle, target);
            },
            .assign => {
                const lhs, const rhs = tree.nodeData(node).node_and_node;
                if (tree.nodeTag(lhs) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(lhs)), "_")) {
                    _ = try self.eval(handle, rhs);
                    return .next;
                }
                const target = try self.referenceForNode(handle, lhs) orelse return .unknown;
                const current = try self.readReference(target) orelse return .unknown;
                const destination = try current.typeOf(analyser);
                const evaluated = try self.evalTypedSource(handle, rhs, destination) orelse return .unknown;
                if (!try self.writeReference(handle, target, evaluated.value, evaluated.source_node)) return .unknown;
                return .next;
            },
            .assign_destructure => {
                const assignment = tree.assignDestructure(node);
                const evaluated = try self.evalSource(handle, assignment.ast.value_expr) orelse return .unknown;
                const value = evaluated.value;
                const items = try self.mutableElements(value) orelse return .unknown;
                if (items.len != assignment.ast.variables.len) return .unknown;
                var literal_buffer: [2]Ast.Node.Index = undefined;
                const literal_elements = if (evaluated.source_node) |source_node|
                    if (tree.fullArrayInit(&literal_buffer, unwrapGroupedSource(tree, source_node))) |literal|
                        if (literal.ast.elements.len == items.len) literal.ast.elements else null
                    else
                        null
                else
                    null;
                for (assignment.ast.variables, items, 0..) |lhs, item, index| {
                    const item_node = if (literal_elements) |elements| elements[index] else null;
                    if (tree.fullVarDecl(lhs)) |decl| {
                        const declared_type = if (decl.ast.type_node.unwrap()) |type_node|
                            try self.eval(handle, type_node) orelse return .unknown
                        else
                            null;
                        if (!try self.declare(handle, decl, item, item_node, declared_type)) return .unknown;
                        continue;
                    }
                    if (tree.nodeTag(lhs) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(lhs)), "_")) continue;
                    if (!try self.write(handle, lhs, item, item_node)) return .unknown;
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
                const target = try self.referenceForNode(handle, lhs) orelse return .unknown;
                const lhs_value = try self.readReference(target) orelse return .unknown;
                const destination = try lhs_value.typeOf(analyser);
                const operand_type = try self.compoundOperandType(destination, operation_tag);
                const evaluated = try self.evalSourceWithType(handle, rhs, operand_type) orelse return .unknown;
                const rhs_value = if (operand_type) |ty|
                    try self.coerceFromSource(handle, ty, evaluated.value, evaluated.source_node, null, false) orelse return .unknown
                else
                    evaluated.value;
                const value = try analyser.resolveComptimeBinaryValue(
                    operation_tag,
                    try self.internVectorOperand(lhs_value) orelse return .unknown,
                    try self.internVectorOperand(rhs_value) orelse return .unknown,
                    .{},
                ) orelse return .unknown;
                if (!try self.writeReference(handle, target, value, null)) return .unknown;
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

    fn forLoop(
        self: *Interpreter,
        handle: *Handle,
        loop_node: Ast.full.For,
        expression: bool,
        destination: ?Type,
        preserve_capture_target: bool,
    ) Error!Flow {
        const analyser = self.analyser;
        const tree = &handle.tree;
        const context: BreakContext = .{
            .parent = self.break_context,
            .label = loop_node.label_token,
            .destination = destination,
            .is_loop = true,
            .preserve_capture_target = preserve_capture_target,
        };
        self.break_context = &context;
        defer self.break_context = context.parent;
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
                if (try Value.sequenceAlloc(analyser, sequence)) |view| {
                    count = view.len;
                } else {
                    const length = try analyser.resolveFieldAccess(sequence, "len") orelse return .unknown;
                    count = analyser.ip.toInt(length.ipIndex() orelse return .unknown, usize) orelse return .unknown;
                }
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
                        if (sequence.reference) |reference| {
                            const element = try self.extendReference(reference, .{ .index = index });
                            break :blk try self.referenceValue(element) orelse return .unknown;
                        }
                        break :blk try self.sequenceElementPointer(sequence.value, index) orelse return .unknown;
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
                .continued => |continued| if (!targetsLoop(tree, loop_node.label_token, continued.target) or continued.result != null) return flow,
                .stopped => |stopped| {
                    if (!targetsLoop(tree, loop_node.label_token, stopped.target)) return flow;
                    if (stopped.result) |result| return if (expression) .{ .value = result } else .unknown;
                    return .next;
                },
                .value, .returned, .unknown => return flow,
            }
        }
        if (loop_node.ast.else_expr.unwrap()) |else_node| {
            if (expression) return .{ .value = try self.evalSourceWithType(handle, else_node, destination) orelse return .unknown };
            return self.statement(handle, else_node);
        }
        return .next;
    }

    fn whileLoop(
        self: *Interpreter,
        handle: *Handle,
        loop_node: Ast.full.While,
        expression: bool,
        destination: ?Type,
        preserve_capture_target: bool,
    ) Error!Flow {
        const context: BreakContext = .{
            .parent = self.break_context,
            .label = loop_node.label_token,
            .destination = destination,
            .is_loop = true,
            .preserve_capture_target = preserve_capture_target,
        };
        self.break_context = &context;
        defer self.break_context = context.parent;
        while (true) {
            const condition = try self.conditionValue(handle, loop_node.ast.cond_expr, loop_node.payload_token, loop_node.error_token) orelse return .unknown;
            if (!condition) {
                if (loop_node.ast.else_expr.unwrap()) |else_node| {
                    if (expression) return .{ .value = try self.evalSourceWithType(handle, else_node, destination) orelse return .unknown };
                    return self.statement(handle, else_node);
                }
                return .next;
            }
            const flow = try self.statement(handle, loop_node.ast.then_expr);
            switch (flow) {
                .next => {},
                .continued => |continued| if (!targetsLoop(&handle.tree, loop_node.label_token, continued.target) or continued.result != null) return flow,
                .stopped => |stopped| {
                    if (!targetsLoop(&handle.tree, loop_node.label_token, stopped.target)) return flow;
                    if (stopped.result) |result| return if (expression) .{ .value = result } else .unknown;
                    return .next;
                },
                .value => return .unknown,
                .returned => |result| return .{ .returned = result },
                .unknown => return .unknown,
            }
            if (loop_node.ast.cont_expr.unwrap()) |cont_expr| {
                const cont_flow = try self.statement(handle, cont_expr);
                if (cont_flow != .next) return cont_flow;
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
        var fn_buffer: [1]Ast.Node.Index = undefined;
        const fn_proto = info.handle.tree.fullFnProto(&fn_buffer, info.fn_node).?;
        var child: Interpreter = .{
            .analyser = analyser,
            .bindings = if (info.container_type.data == .container)
                try info.container_type.data.container.bound_params.clone(analyser.arena)
            else
                .empty,
            .container_type = if (info.container_type.data == .container and
                info.container_type.data.container.scope_handle.scope != .root)
                info.container_type.*
            else
                null,
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
            const parameter_type = try analyser.resolveGenericType(parameter.type, child.bindings);
            const value = if (parameter.type.data == .anytype_parameter or !parameter_type.is_type_val)
                try self.eval(handle, argument) orelse return .unknown
            else value: {
                const evaluated = try self.evalTypedSource(handle, argument, parameter_type) orelse return .unknown;
                break :value try self.coerceFromSource(
                    handle,
                    parameter_type,
                    evaluated.value,
                    evaluated.source_node,
                    null,
                    self.optionalPayloadType(parameter_type) != null,
                ) orelse return .unknown;
            };
            try child.bind(info.handle, parameter.name_token orelse return .unknown, value);
            if (parameter.type.data == .anytype_parameter) {
                try child.bindings.put(analyser.arena, parameter.type.data.anytype_parameter.token_handle, try value.typeOf(analyser));
            }
        }
        const is_type_function = Analyser.isTypeFunction(&info.handle.tree, fn_proto);
        const return_type = if (is_type_function)
            Type.fromIP(analyser, .type_type, .type_type)
        else return_type: {
            const return_value = try analyser.resolveGenericType(info.return_value.*, child.bindings);
            break :return_type try return_value.typeOf(analyser);
        };
        child.return_type = return_type;
        const flow = try child.run(info.handle, info.handle.tree.nodeData(info.fn_node).node_and_node[1]);
        const old_interpreter = analyser.comptime_interpreter;
        const old_bindings = analyser.generic_bindings;
        analyser.comptime_interpreter = &child;
        analyser.generic_bindings = &child.bindings;
        defer {
            analyser.comptime_interpreter = old_interpreter;
            analyser.generic_bindings = old_bindings;
        }
        return switch (flow) {
            .next => blk: {
                const coerced = try child.coerceFromSource(
                    info.handle,
                    return_type,
                    Type.fromIP(analyser, .void_type, .void_value),
                    null,
                    null,
                    child.optionalPayloadType(return_type) != null,
                ) orelse return .unknown;
                break :blk .{ .returned = .{ .value = coerced, .source_node = null } };
            },
            .returned => |result| blk: {
                if (child.containsOwnedReference(result.value, 0)) return .unknown;
                const coerced = try child.coerceFromSource(
                    info.handle,
                    return_type,
                    result.value,
                    result.source_node,
                    null,
                    child.optionalPayloadType(return_type) != null,
                ) orelse if (is_type_function)
                    try return_type.instanceUnchecked(analyser)
                else
                    return .unknown;
                break :blk .{ .returned = .{ .value = coerced, .source_node = null } };
            },
            else => flow,
        };
    }

    fn callValue(self: *Interpreter, handle: *Handle, node: Ast.Node.Index) Error!?Type {
        return switch (try self.invoke(handle, node)) {
            .returned => |result| result.value,
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

test "comptime interpreter evaluation quota remains bounded and monotonic" {
    var budget: Interpreter.Budget = .{};
    budget.steps -= 10;

    budget.raiseQuota(0);
    budget.raiseQuota(10);
    try std.testing.expectEqual(Interpreter.default_step_quota, budget.quota);
    try std.testing.expectEqual(Interpreter.default_step_quota - 10, budget.steps);

    budget.raiseQuota(10_000);
    try std.testing.expectEqual(@as(usize, 10_000), budget.quota);
    try std.testing.expectEqual(@as(usize, 9_990), budget.steps);

    budget.raiseQuota(std.math.maxInt(u32));
    try std.testing.expectEqual(Interpreter.max_step_quota, budget.quota);
    try std.testing.expectEqual(Interpreter.max_step_quota - 10, budget.steps);
}
