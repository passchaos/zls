const std = @import("std");

fn Result(comptime first: usize, comptime second: usize, comptime third: usize) type {
    return struct { first: [first]u8, second: [second]u8, third: [third]u8 };
}

fn effect(executions: *usize) usize {
    executions.* += 1;
    return 3;
}

pub fn explicit_comptime_operand() type {
    var executions: usize = 0;
    const T = @TypeOf(comptime effect(&executions));
    return Result(@intFromBool(T == usize), executions, 0);
}

pub fn multiple_comptime_operands() type {
    var executions: usize = 0;
    const T = @TypeOf(comptime @as(u8, @intCast(effect(&executions))), comptime @as(u16, @intCast(effect(&executions))));
    return Result(@intFromBool(T == u16), executions, 0);
}

pub fn nested_comptime_operand() type {
    var executions: usize = 0;
    const T = @TypeOf(@as(usize, comptime effect(&executions)) + 1);
    return Result(@intFromBool(T == usize), executions, 0);
}

pub fn comptime_block_operand() type {
    var executions: usize = 0;
    const T = @TypeOf(@as(usize, comptime block: {
        executions += 1;
        break :block 3;
    }));
    return Result(@intFromBool(T == usize), executions, 0);
}

pub fn selected_comptime_branch() type {
    var executions: usize = 0;
    const T = @TypeOf(if (true) comptime effect(&executions) else comptime effect(&executions));
    return Result(@intFromBool(T == usize), executions, 0);
}

fn ordinary(value: usize) usize {
    _ = value;
    return 4;
}

pub fn ordinary_call_with_comptime_argument() type {
    var executions: usize = 0;
    const T = @TypeOf(ordinary(comptime effect(&executions)));
    return Result(@intFromBool(T == usize), executions, 0);
}

fn signature(comptime executions: *usize, value: @TypeOf(comptime effect(executions))) @TypeOf(comptime effect(executions)) {
    return value + 1;
}

pub fn signature_typeof_effects() type {
    var executions: usize = 0;
    const value = signature(&executions, 3);
    return Result(value, executions, @intFromBool(@TypeOf(value) == usize));
}

var runtime_value: usize = 0;

fn ordinaryEffect() usize {
    runtime_value += 1;
    return 3;
}

pub fn ordinary_operand_not_executed() type {
    var executions: usize = 0;
    const T = @TypeOf(ordinaryEffect(), @as(u16, comptime effect(&executions)));
    return Result(@intFromBool(T == usize), executions, 0);
}

pub fn repeated_type_queries() type {
    var executions: usize = 0;
    var matched: usize = 0;
    for (0..3) |_| {
        const T = @TypeOf(comptime effect(&executions));
        if (T == usize) matched += 1;
    }
    return Result(matched, executions, 0);
}

pub fn nested_type_queries() type {
    var executions: usize = 0;
    const T = @TypeOf(comptime block: {
        const A = @TypeOf(comptime effect(&executions));
        const B = @TypeOf(comptime effect(&executions));
        _ = A;
        _ = B;
        break :block 1;
    });
    return Result(@intFromBool(T == comptime_int), executions, 0);
}

pub fn nested_type_query_operand() type {
    var executions: usize = 0;
    const T = @TypeOf(@TypeOf(comptime effect(&executions)));
    return Result(@intFromBool(T == type), executions, 0);
}

pub fn selected_comptime_switch() type {
    var executions: usize = 0;
    const T = @TypeOf(switch (@as(u8, 1)) {
        0 => comptime effect(&executions),
        else => comptime effect(&executions),
    });
    return Result(@intFromBool(T == usize), executions, 0);
}

pub fn mixed_comptime_operands() type {
    var executions: usize = 0;
    const T = @TypeOf(ordinary(comptime effect(&executions)), @as(u8, comptime @intCast(effect(&executions))));
    return Result(@intFromBool(T == usize), executions, 0);
}

pub fn query_context_restored() type {
    var executions: usize = 0;
    const T = @TypeOf(comptime effect(&executions));
    const value = effect(&executions);
    return Result(@intFromBool(T == usize), executions, value);
}

pub fn nested_query_result_type() type {
    var executions: usize = 0;
    const T = @TypeOf(@as(@TypeOf(comptime effect(&executions)), 3));
    return Result(@intFromBool(T == usize), executions, 0);
}

fn compileTimeArgument(comptime ignored: usize) usize {
    _ = ignored;
    return 3;
}

pub fn comptime_parameter_in_ordinary_call() type {
    var executions: usize = 0;
    const T = @TypeOf(compileTimeArgument(comptime effect(&executions)));
    return Result(@intFromBool(T == usize), executions, 0);
}

pub fn condition_changes_during_query() type {
    var condition = true;
    var executions: usize = 0;
    const T = @TypeOf(if (condition) comptime block: {
        condition = false;
        executions += 1;
        break :block @as(u8, 1);
    } else @as(u16, 1));
    return Result(@intFromBool(T == u8), executions, @intFromBool(condition));
}

pub fn query_operands_evaluate_in_order() type {
    var condition = true;
    var executions: usize = 0;
    const T = @TypeOf(if (condition) @as(u8, 1) else @as(u32, 1), comptime block: {
        condition = false;
        executions += 1;
        break :block @as(u16, 1);
    });
    return Result(@intFromBool(T == u16), executions, @intFromBool(condition));
}

fn boolEffect(executions: *usize) bool {
    executions.* += 1;
    return true;
}

pub fn short_circuit_type_queries() type {
    var executions: usize = 0;
    const A = @TypeOf(false and comptime boolEffect(&executions));
    const B = @TypeOf(true or comptime boolEffect(&executions));
    const before = executions;
    const C = @TypeOf(true and comptime boolEffect(&executions));
    return Result(@intFromBool(A == bool and B == bool and C == bool), before, executions);
}

pub fn optional_type_queries() type {
    var executions: usize = 0;
    const A = @TypeOf(@as(?usize, 3) orelse comptime effect(&executions));
    const before = executions;
    const B = @TypeOf(@as(?usize, null) orelse comptime effect(&executions));
    return Result(@intFromBool(A == usize and B == usize), before, executions);
}

pub fn error_type_queries() type {
    var executions: usize = 0;
    const A = @TypeOf(@as(error{Missing}!usize, 3) catch comptime effect(&executions));
    const before = executions;
    const B = @TypeOf(@as(error{Missing}!usize, error.Missing) catch comptime effect(&executions));
    return Result(@intFromBool(A == usize and B == usize), before, executions);
}

pub fn short_circuit_left_snapshot() type {
    var enabled = true;
    const T = @TypeOf(if (enabled and comptime block: {
        enabled = false;
        break :block true;
    }) @as(u8, 1) else @as(u16, 1));
    return Result(@intFromBool(T == u8), @intFromBool(enabled), 0);
}

pub fn optional_fallback_left_snapshot() type {
    var value: ?usize = null;
    const T = @TypeOf(if ((value orelse comptime block: {
        value = 5;
        break :block @as(usize, 0);
    }) == 0) @as(u8, 1) else @as(u16, 1));
    return Result(@intFromBool(T == u8), value.?, 0);
}

pub fn error_fallback_left_snapshot() type {
    var value: error{Missing}!usize = error.Missing;
    const T = @TypeOf(if ((value catch comptime block: {
        value = 5;
        break :block @as(usize, 0);
    }) == 0) @as(u8, 1) else @as(u16, 1));
    return Result(@intFromBool(T == u8), value catch unreachable, 0);
}

pub fn optional_capture_snapshot() type {
    var value: ?type = u8;
    const T = @TypeOf(if (value) |Item| comptime block: {
        value = u16;
        break :block @as(Item, 1);
    } else @as(u32, 1));
    return Result(@intFromBool(T == u8), @intFromBool(value.? == u16), 0);
}

pub fn optional_value_capture_snapshot() type {
    var value: ?usize = 3;
    const T = @TypeOf(if (value) |item| comptime block: {
        value = 7;
        break :block @as([item]u8, undefined);
    } else @as([1]u8, undefined));
    return Result(@typeInfo(T).array.len, value.?, 0);
}

pub fn optional_reference_capture_updates() type {
    var value: ?usize = 3;
    const T = @TypeOf(if (value) |*item| comptime block: {
        item.* += 2;
        break :block @as(u8, 1);
    } else @as(u16, 1));
    return Result(@intFromBool(T == u8), value.?, 0);
}

pub fn error_payload_capture_snapshot() type {
    var value: error{Missing}!type = u8;
    const T = @TypeOf(if (value) |Item| comptime block: {
        value = u16;
        break :block @as(Item, 1);
    } else |_| @as(u32, 1));
    return Result(@intFromBool(T == u8), @intFromBool((value catch unreachable) == u16), 0);
}

pub fn error_capture_snapshot() type {
    var value: error{Missing}!usize = error.Missing;
    const T = @TypeOf(if (value) |_| @as(u16, 1) else |err| comptime block: {
        value = 7;
        break :block @as(if (err == error.Missing) u8 else u32, 1);
    });
    return Result(@intFromBool(T == u8), value catch unreachable, 0);
}

pub fn nested_optional_alias_snapshot() type {
    var state: struct { value: ?usize } = .{ .value = null };
    const alias = &state;
    const T = @TypeOf(if ((alias.value orelse comptime block: {
        state.value = 7;
        break :block @as(usize, 0);
    }) == 0) @as(u8, 1) else @as(u16, 1));
    return Result(@intFromBool(T == u8), state.value.?, 0);
}

fn chosen(comptime T: type, value: usize) T {
    _ = value;
    return undefined;
}

pub fn call_type_argument_snapshot() type {
    var T: type = u8;
    var executions: usize = 0;
    const U = @TypeOf(chosen(T, comptime block: {
        T = u16;
        executions += 1;
        break :block 0;
    }));
    return Result(@intFromBool(U == u8), @intFromBool(T == u16), executions);
}

pub fn call_conditional_argument_snapshot() type {
    var condition = true;
    var executions: usize = 0;
    const U = @TypeOf(chosen(if (condition) u8 else u32, comptime block: {
        condition = false;
        executions += 1;
        break :block 0;
    }));
    return Result(@intFromBool(U == u8), @intFromBool(condition), executions);
}

fn firstCallable(value: usize) u8 {
    _ = value;
    return 0;
}

fn secondCallable(value: usize) u16 {
    _ = value;
    return 0;
}

pub fn selected_callable_snapshot() type {
    var condition = true;
    var executions: usize = 0;
    const U = @TypeOf((if (condition) firstCallable else secondCallable)(comptime block: {
        condition = false;
        executions += 1;
        break :block 0;
    }));
    return Result(@intFromBool(U == u8), @intFromBool(condition), executions);
}

fn arrayCall(comptime count: usize, other: usize) [count]u8 {
    _ = other;
    return undefined;
}

pub fn call_length_argument_snapshot() type {
    var count: usize = 3;
    var executions: usize = 0;
    const T = @TypeOf(arrayCall(count, comptime block: {
        count = 5;
        executions += 1;
        break :block 0;
    }));
    return Result(@typeInfo(T).array.len, count, executions);
}

pub fn repeated_call_queries() type {
    var count: usize = 3;
    var sum: usize = 0;
    inline for (0..2) |_| {
        const T = @TypeOf(arrayCall(count, comptime block: {
            count += 1;
            break :block 0;
        }));
        sum += @typeInfo(T).array.len;
    }
    return Result(sum, count, 0);
}

const CallTag = enum { first, second };

fn enumCall(comptime tag: CallTag, other: usize) if (tag == .first) u8 else u16 {
    _ = other;
    return 0;
}

pub fn call_enum_argument_snapshot() type {
    var tag: CallTag = .first;
    const T = @TypeOf(enumCall(tag, comptime block: {
        tag = .second;
        break :block 0;
    }));
    return Result(@intFromBool(T == u8), @intFromBool(tag == .second), 0);
}

pub fn call_value_receiver_snapshot() type {
    const Value = struct {
        Item: type,
        fn read(comptime self: @This(), other: usize) self.Item {
            _ = other;
            return undefined;
        }
    };
    var value = Value{ .Item = u8 };
    var executions: usize = 0;
    const T = @TypeOf(value.read(comptime block: {
        value.Item = u16;
        executions += 1;
        break :block 0;
    }));
    return Result(@intFromBool(T == u8), @intFromBool(value.Item == u16), executions);
}

fn typedCall(comptime T: type, value: T) T {
    return value;
}

pub fn call_argument_result_type() type {
    var T: type = u8;
    var executions: usize = 0;
    const U = @TypeOf(typedCall(T, comptime @intCast(block: {
        T = u16;
        executions += 1;
        break :block @as(usize, 3);
    })));
    return Result(@intFromBool(U == u8), @intFromBool(T == u16), executions);
}

pub fn call_pointer_value_receiver_snapshot() type {
    const Value = struct {
        Item: type,
        fn read(comptime self: @This(), other: usize) self.Item {
            _ = other;
            return undefined;
        }
    };
    var value = Value{ .Item = u8 };
    const pointer = &value;
    const T = @TypeOf(pointer.read(comptime block: {
        value.Item = u16;
        break :block 0;
    }));
    return Result(@intFromBool(T == u8), @intFromBool(value.Item == u16), 0);
}

pub fn call_receiver_argument_result_type() type {
    const Value = struct {
        Item: type,
        fn identity(comptime self: @This(), value: self.Item) self.Item {
            return value;
        }
    };
    var value = Value{ .Item = u8 };
    var executions: usize = 0;
    const T = @TypeOf(value.identity(comptime @intCast(block: {
        value.Item = u16;
        executions += 1;
        break :block @as(usize, 3);
    })));
    return Result(@intFromBool(T == u8), @intFromBool(value.Item == u16), executions);
}

pub fn nested_call_type_argument_snapshot() type {
    var T: type = u8;
    var executions: usize = 0;
    const U = @TypeOf(typedCall(@TypeOf(chosen(T, 0)), comptime @intCast(block: {
        T = u16;
        executions += 1;
        break :block @as(usize, 3);
    })));
    return Result(@intFromBool(U == u8), @intFromBool(T == u16), executions);
}

pub fn cast_type_snapshot() type {
    var T: type = u8;
    const U = @TypeOf(@as(T, comptime block: {
        T = u16;
        break :block 3;
    }));
    return Result(@intFromBool(U == u8), @intFromBool(T == u16), 0);
}

pub fn cast_result_type_snapshot() type {
    var T: type = u8;
    var executions: usize = 0;
    const U = @TypeOf(@as(T, comptime @intCast(block: {
        T = u16;
        executions += 1;
        break :block @as(usize, 3);
    })));
    return Result(@intFromBool(U == u8), @intFromBool(T == u16), executions);
}

pub fn array_type_snapshot() type {
    var T: type = u8;
    const U = @TypeOf([1]T{comptime block: {
        T = u16;
        break :block 3;
    }});
    return Result(@intFromBool(U == [1]u8), @intFromBool(T == u16), 0);
}

pub fn array_length_snapshot() type {
    var count: usize = 1;
    const U = @TypeOf([count]u8{comptime block: {
        count = 2;
        break :block 3;
    }});
    return Result(@typeInfo(U).array.len, count, 0);
}

pub fn struct_type_snapshot() type {
    const A = struct { item: u8 };
    const B = struct { item: u16 };
    var T: type = A;
    const U = @TypeOf(T{ .item = comptime block: {
        T = B;
        break :block 3;
    } });
    return Result(@intFromBool(U == A), @intFromBool(T == B), 0);
}

pub fn array_element_result_type() type {
    var executions: usize = 0;
    const U = @TypeOf([1]u8{comptime @intCast(block: {
        executions += 1;
        break :block @as(usize, 3);
    })});
    return Result(@intFromBool(U == [1]u8), executions, 0);
}

pub fn struct_field_result_type() type {
    const Value = struct { item: u8 };
    var executions: usize = 0;
    const U = @TypeOf(Value{ .item = comptime @intCast(block: {
        executions += 1;
        break :block @as(usize, 3);
    }) });
    return Result(@intFromBool(U == Value), executions, 0);
}

pub fn nested_literal_result_type() type {
    const Value = struct { items: [1]u8 };
    var executions: usize = 0;
    const U = @TypeOf(@as(Value, .{ .items = .{comptime @intCast(block: {
        executions += 1;
        break :block @as(usize, 3);
    })} }));
    return Result(@intFromBool(U == Value), executions, 0);
}

pub fn inferred_array_type_snapshot() type {
    var T: type = u8;
    const U = @TypeOf([_]T{comptime block: {
        T = u16;
        break :block 3;
    }});
    return Result(@intFromBool(U == [1]u8), @intFromBool(T == u16), 0);
}

pub fn tuple_element_result_types() type {
    var executions: usize = 0;
    const U = @TypeOf(@as(struct { u8, u16 }, .{
        comptime @intCast(block: {
            executions += 1;
            break :block @as(usize, 3);
        }),
        comptime @intCast(block: {
            executions += 1;
            break :block @as(usize, 300);
        }),
    }));
    return Result(@intFromBool(@FieldType(U, "0") == u8), @intFromBool(@FieldType(U, "1") == u16), executions);
}

pub fn wrapped_literal_result_types() type {
    const Value = struct { items: [1]u8 };
    var executions: usize = 0;
    const A = @TypeOf(@as(?Value, .{ .items = .{comptime @intCast(block: {
        executions += 1;
        break :block @as(usize, 3);
    })} }));
    const B = @TypeOf(@as(error{Missing}!Value, .{ .items = .{comptime @intCast(block: {
        executions += 1;
        break :block @as(usize, 3);
    })} }));
    return Result(@intFromBool(A == ?Value), @intFromBool(B == error{Missing}!Value), executions);
}

pub fn grouped_literal_result_type() type {
    const Value = struct { items: [1]u8 };
    var executions: usize = 0;
    const U = @TypeOf(@as(Value, (.{ .items = (.{comptime @intCast(block: {
        executions += 1;
        break :block @as(usize, 3);
    })}) })));
    return Result(@intFromBool(U == Value), executions, 0);
}

pub fn union_literal_type_snapshot() type {
    const A = union(enum) { item: u8 };
    const B = union(enum) { item: u16 };
    var T: type = A;
    var executions: usize = 0;
    const U = @TypeOf(T{ .item = comptime @intCast(block: {
        T = B;
        executions += 1;
        break :block @as(usize, 3);
    }) });
    return Result(@intFromBool(U == A), @intFromBool(T == B), executions);
}

pub fn union_init_type_snapshot() type {
    const A = union(enum) { first: u8, second: u16 };
    const B = union(enum) { first: u32, second: u64 };
    var T: type = A;
    var name: []const u8 = "first";
    var executions: usize = 0;
    const U = @TypeOf(@unionInit(T, name, comptime @intCast(block: {
        T = B;
        name = "second";
        executions += 1;
        break :block @as(usize, 3);
    })));
    return Result(@intFromBool(U == A), @intFromBool(T == B and name[0] == 's'), executions);
}

pub fn repeated_aggregate_queries() type {
    var T: type = u8;
    var executions: usize = 0;
    const A = @TypeOf(@as(T, comptime block: {
        T = u16;
        executions += 1;
        break :block 3;
    }));
    const B = @TypeOf([1]T{comptime block: {
        T = u32;
        executions += 1;
        break :block 3;
    }});
    return Result(@intFromBool(A == u8), @intFromBool(B == [1]u16), executions);
}

pub fn tuple_value_snapshot() type {
    var value: usize = 1;
    const U = @TypeOf(.{ value, comptime block: {
        value = 2;
        break :block 0;
    } });
    const original: U = undefined;
    return Result(@intFromBool(@typeInfo(U).@"struct".fields[0].is_comptime), original[0], value);
}

pub fn tuple_type_snapshot() type {
    var T: type = u8;
    const U = @TypeOf(.{ T, comptime block: {
        T = u16;
        break :block 0;
    } });
    const original: U = undefined;
    return Result(@intFromBool(original[0] == u8), @intFromBool(T == u16), 0);
}

pub fn anonymous_field_snapshot() type {
    var T: type = u8;
    const U = @TypeOf(.{ .Item = T, .effect = comptime block: {
        T = u16;
        break :block 0;
    } });
    const original: U = undefined;
    return Result(@intFromBool(original.Item == u8), @intFromBool(T == u16), 0);
}

pub fn array_type_length_operand_snapshot() type {
    var count: usize = 1;
    const U = @TypeOf(@as([count]block: {
        break :block @TypeOf(comptime effect: {
            count = 2;
            break :effect @as(u8, 3);
        });
    }, undefined));
    return Result(@typeInfo(U).array.len, count, 0);
}

pub fn array_type_sentinel_operand_snapshot() type {
    var count: usize = 1;
    var sentinel: u8 = 0;
    const U = @TypeOf(@as([count:sentinel]block: {
        break :block @TypeOf(comptime effect: {
            count = 2;
            sentinel = 1;
            break :effect @as(u8, 3);
        });
    }, undefined));
    const info = @typeInfo(U).array;
    const actual_sentinel = @intFromBool(U == [1:1]u8);
    return Result(info.len, actual_sentinel, count);
}

pub fn anonymous_ordinary_call_effects() type {
    var executions: usize = 0;
    const U = @TypeOf(.{ ordinaryQueryEffect(), comptime countEffect(&executions) });
    return Result(@intFromBool(@FieldType(U, "0") == usize), executions, 0);
}

pub fn typed_ordinary_call_effects() type {
    var executions: usize = 0;
    const U = @TypeOf([2]usize{ ordinaryQueryEffect(), comptime countEffect(&executions) });
    return Result(@intFromBool(U == [2]usize), executions, 0);
}

fn countEffect(executions: *usize) usize {
    executions.* += 1;
    return 3;
}

var anonymous_runtime_value: usize = undefined;

fn ordinaryQueryEffect() usize {
    anonymous_runtime_value += 1;
    return 3;
}

pub fn anonymous_runtime_field_metadata() type {
    var executions: usize = 0;
    const U = @TypeOf(.{ .known = @as(u8, 1), .unknown = anonymous_runtime_value, .effect = comptime countEffect(&executions) });
    const fields = @typeInfo(U).@"struct".fields;
    return Result(@intFromBool(fields[0].is_comptime and fields[0].default_value_ptr != null), @intFromBool(!fields[1].is_comptime and fields[1].default_value_ptr == null), executions);
}

pub fn tuple_runtime_field_metadata() type {
    var executions: usize = 0;
    const U = @TypeOf(.{ @as(u8, 1), anonymous_runtime_value, comptime countEffect(&executions) });
    const fields = @typeInfo(U).@"struct".fields;
    return Result(@intFromBool(fields[0].is_comptime and fields[0].default_value_ptr != null), @intFromBool(!fields[1].is_comptime and fields[1].default_value_ptr == null), executions);
}

pub fn vector_length_snapshot() type {
    var count: u32 = 2;
    const U = @TypeOf(@as(@Vector(count, block: {
        break :block @TypeOf(comptime effect: {
            count = 4;
            break :effect @as(u8, 3);
        });
    }), undefined));
    return Result(@typeInfo(U).vector.len, count, 0);
}

pub fn pointer_alignment_child_order() type {
    var alignment: u16 = 4;
    const U = @TypeOf(@as(*align(alignment) block: {
        break :block @TypeOf(comptime effect: {
            alignment = 8;
            break :effect @as(u8, 3);
        });
    }, undefined));
    return Result(@typeInfo(U).pointer.alignment.?, alignment, 0);
}

pub fn pointer_sentinel_child_order() type {
    var sentinel: u8 = 0;
    const U = @TypeOf(@as([*:sentinel]block: {
        break :block @TypeOf(comptime effect: {
            sentinel = 1;
            break :effect @as(u8, 3);
        });
    }, undefined));
    return Result(@intFromBool(U == [*:0]u8), @intFromBool(U == [*:1]u8), sentinel);
}

pub fn pointer_alignment_type_snapshot() type {
    var T: type = u8;
    var executions: usize = 0;
    const U = @TypeOf(@as(*align(block: {
        const A = @TypeOf(comptime effect: {
            T = u16;
            executions += 1;
            break :effect @as(u8, 3);
        });
        _ = A;
        break :block 4;
    }) T, undefined));
    return Result(@intFromBool(@typeInfo(U).pointer.child == u8), @intFromBool(T == u16), executions);
}

pub fn pointer_sentinel_type_snapshot() type {
    var T: type = u8;
    var executions: usize = 0;
    const U = @TypeOf(@as([*:block: {
        const A = @TypeOf(comptime effect: {
            T = u16;
            executions += 1;
            break :effect @as(u8, 3);
        });
        _ = A;
        break :block 0;
    }]T, undefined));
    return Result(@intFromBool(@typeInfo(U).pointer.child == u8), @intFromBool(T == u16), executions);
}

pub fn pointer_qualifier_order() type {
    var trace: usize = 0;
    const U = @TypeOf(@as([*:block: {
        const A = @TypeOf(comptime effect: {
            trace = trace * 10 + 1;
            break :effect @as(u8, 3);
        });
        _ = A;
        break :block 0;
    }]align(block: {
        const A = @TypeOf(comptime effect: {
            trace = trace * 10 + 2;
            break :effect @as(u8, 3);
        });
        _ = A;
        break :block 4;
    }) block: {
        break :block @TypeOf(comptime effect: {
            trace = trace * 10 + 3;
            break :effect @as(u8, 3);
        });
    }, undefined));
    return Result(trace, @typeInfo(U).pointer.alignment.?, @intFromBool(U == [*:0]align(4) u8));
}

pub fn pointer_bit_range_order() type {
    var offset: u16 = 0;
    var host: u16 = 1;
    const U = @TypeOf(@as(*align(1:offset:host) block: {
        break :block @TypeOf(comptime effect: {
            offset = 1;
            host = 2;
            break :effect @as(u3, 3);
        });
    }, undefined));
    return Result(@intFromBool(U == *align(1:0:1) u3), @intFromBool(U == *align(1:1:2) u3), offset);
}

pub fn pointer_address_space_order() type {
    var trace: usize = 0;
    const U = @TypeOf(@as([*:block: {
        const A = @TypeOf(comptime effect: {
            trace = trace * 10 + 1;
            break :effect @as(u8, 3);
        });
        _ = A;
        break :block 0;
    }]align(block: {
        const A = @TypeOf(comptime effect: {
            trace = trace * 10 + 2;
            break :effect @as(u8, 3);
        });
        _ = A;
        break :block 4;
    }) addrspace(block: {
        const A = @TypeOf(comptime effect: {
            trace = trace * 10 + 4;
            break :effect @as(u8, 3);
        });
        _ = A;
        break :block .generic;
    }) block: {
        break :block @TypeOf(comptime effect: {
            trace = trace * 10 + 3;
            break :effect @as(u8, 3);
        });
    }, undefined));
    return Result(trace, @typeInfo(U).pointer.alignment.?, @intFromBool(U == [*:0]align(4) u8));
}

pub fn pointer_sentinel_alignment_snapshot() type {
    var sentinel: u8 = 0;
    var executions: usize = 0;
    const U = @TypeOf(@as([*:sentinel]align(block: {
        const A = @TypeOf(comptime effect: {
            sentinel = 1;
            executions += 1;
            break :effect @as(u8, 3);
        });
        _ = A;
        break :block 4;
    }) u8, undefined));
    return Result(@intFromBool(U == [*:0]align(4) u8), sentinel, executions);
}

pub fn repeated_pointer_type_queries() type {
    var T: type = u8;
    var executions: usize = 0;
    const A = @TypeOf(@as(*align(block: {
        const U = @TypeOf(comptime effect: {
            T = u16;
            executions += 1;
            break :effect @as(u8, 3);
        });
        _ = U;
        break :block 4;
    }) T, undefined));
    const B = @TypeOf(@as(*align(block: {
        const U = @TypeOf(comptime effect: {
            T = u32;
            executions += 1;
            break :effect @as(u8, 3);
        });
        _ = U;
        break :block 4;
    }) T, undefined));
    return Result(@intFromBool(@typeInfo(A).pointer.child == u8), @intFromBool(@typeInfo(B).pointer.child == u16), executions);
}

pub fn int_signedness_snapshot() type {
    var signedness: std.builtin.Signedness = .unsigned;
    const U = @TypeOf(@as(@Int(signedness, block: {
        const Seen = @TypeOf(comptime effect: {
            signedness = .signed;
            break :effect @as(u8, 0);
        });
        _ = Seen;
        break :block 8;
    }), undefined));
    return Result(@intFromBool(U == u8), @intFromBool(signedness == .signed), 0);
}

pub fn int_bits_result_type() type {
    var executions: usize = 0;
    const U = @TypeOf(@as(@Int(.unsigned, @intCast(block: {
        const Seen = @TypeOf(comptime effect: {
            executions += 1;
            break :effect @as(u8, 0);
        });
        _ = Seen;
        break :block @as(usize, 8);
    })), undefined));
    return Result(@intFromBool(U == u8), executions, 0);
}

pub fn pointer_builtin_size_snapshot() type {
    var size: std.builtin.Type.Pointer.Size = .many;
    const U = @TypeOf(@as(@Pointer(size, .{}, u8, block: {
        const Seen = @TypeOf(comptime effect: {
            size = .slice;
            break :effect @as(u8, 0);
        });
        _ = Seen;
        break :block null;
    }), undefined));
    return Result(@intFromBool(U == [*]u8), @intFromBool(size == .slice), 0);
}

pub fn pointer_builtin_attributes_snapshot() type {
    var attributes: std.builtin.Type.Pointer.Attributes = .{ .@"const" = false, .@"align" = 4 };
    const U = @TypeOf(@as(@Pointer(.many, attributes, u8, block: {
        const Seen = @TypeOf(comptime effect: {
            attributes.@"const" = true;
            attributes.@"align" = 8;
            break :effect @as(u8, 0);
        });
        _ = Seen;
        break :block null;
    }), undefined));
    return Result(@intFromBool(U == [*]align(4) u8), @intFromBool(attributes.@"const"), attributes.@"align".?);
}

pub fn pointer_builtin_child_snapshot() type {
    var T: type = u8;
    const U = @TypeOf(@as(@Pointer(.many, .{}, T, block: {
        const Seen = @TypeOf(comptime effect: {
            T = u16;
            break :effect @as(u8, 0);
        });
        _ = Seen;
        break :block 0;
    }), undefined));
    return Result(@intFromBool(U == [*:0]u8), @intFromBool(T == u16), 0);
}

pub fn pointer_builtin_attribute_result_type() type {
    var executions: usize = 0;
    const U = @TypeOf(@as(@Pointer(.many, .{ .@"align" = @intCast(block: {
        const Seen = @TypeOf(comptime effect: {
            executions += 1;
            break :effect @as(u8, 0);
        });
        _ = Seen;
        break :block @as(usize, 4);
    }) }, u8, null), undefined));
    return Result(@intFromBool(U == [*]align(4) u8), executions, 0);
}

pub fn fn_builtin_return_snapshot() type {
    var T: type = u8;
    const U = @TypeOf(@as(@Fn(&.{u16}, &.{.{}}, T, block: {
        const Seen = @TypeOf(comptime effect: {
            T = u32;
            break :effect @as(u8, 0);
        });
        _ = Seen;
        break :block .{};
    }), undefined));
    return Result(@intFromBool(@typeInfo(U).@"fn".return_type.? == u8), @intFromBool(T == u32), 0);
}

pub fn fn_builtin_parameter_alias() type {
    var parameters = [_]type{u8};
    const U = @TypeOf(@as(@Fn(&parameters, &.{.{}}, void, block: {
        const Seen = @TypeOf(comptime effect: {
            parameters[0] = u16;
            break :effect @as(u8, 0);
        });
        _ = Seen;
        break :block .{};
    }), undefined));
    return Result(@intFromBool(@typeInfo(U).@"fn".params[0].type.? == u16), @intFromBool(parameters[0] == u16), 0);
}

pub fn pointer_builtin_sentinel_result_type() type {
    var executions: usize = 0;
    const U = @TypeOf(@as(@Pointer(.many, .{}, u8, @intCast(block: {
        const Seen = @TypeOf(comptime effect: {
            executions += 1;
            break :effect @as(u8, 0);
        });
        _ = Seen;
        break :block @as(usize, 3);
    })), undefined));
    return Result(@intFromBool(U == [*:3]u8), executions, 0);
}

pub fn builtin_arguments_evaluate_once() type {
    var trace: usize = 0;
    const U = @TypeOf(@as(@Pointer(size: {
        trace = trace * 10 + 1;
        break :size .many;
    }, attributes: {
        trace = trace * 10 + 2;
        break :attributes .{ .@"const" = true };
    }, child: {
        trace = trace * 10 + 3;
        break :child u8;
    }, sentinel: {
        const Seen = @TypeOf(comptime effect: {
            trace = trace * 10 + 4;
            break :effect @as(u8, 0);
        });
        _ = Seen;
        break :sentinel 0;
    }), undefined));
    return Result(@intFromBool(U == [*:0]const u8), trace, 0);
}

pub fn repeated_builtin_type_queries() type {
    var signedness: std.builtin.Signedness = .unsigned;
    var executions: usize = 0;
    const A = @TypeOf(@as(@Int(signedness, block: {
        const Seen = @TypeOf(comptime effect: {
            signedness = .signed;
            executions += 1;
            break :effect @as(u8, 0);
        });
        _ = Seen;
        break :block 8;
    }), undefined));
    const B = @TypeOf(@as(@Int(signedness, block: {
        const Seen = @TypeOf(comptime effect: {
            signedness = .unsigned;
            executions += 1;
            break :effect @as(u8, 0);
        });
        _ = Seen;
        break :block 16;
    }), undefined));
    return Result(@intFromBool(A == u8), @intFromBool(B == i16), executions);
}

pub fn direct_builtin_result_types() type {
    var executions: usize = 0;
    const A = @Int(.unsigned, @intCast(block: {
        executions += 1;
        break :block @as(usize, 8);
    }));
    const B = @Pointer(.many, .{}, u8, @intCast(block: {
        executions += 1;
        break :block @as(usize, 3);
    }));
    return Result(@intFromBool(A == u8), @intFromBool(B == [*:3]u8), executions);
}

pub fn tuple_builtin_array_types() type {
    var parameters = [_]type{ u8, u16 };
    const A = @Tuple(&parameters);
    parameters[0] = u32;
    const B = @Tuple(&parameters);
    return Result(@intFromBool(@FieldType(A, "0") == u8), @intFromBool(@FieldType(B, "0") == u32), @intFromBool(@FieldType(B, "1") == u16));
}

pub fn struct_layout_snapshot() type {
    var layout: std.builtin.Type.ContainerLayout = .auto;
    const U = @TypeOf(@as(@Struct(layout, null, &.{"item"}, &.{u8}, attributes: {
        const Seen = @TypeOf(comptime effect: {
            layout = .@"extern";
            break :effect @as(u8, 0);
        });
        _ = Seen;
        break :attributes &.{.{}};
    }), undefined));
    return Result(@intFromBool(@typeInfo(U).@"struct".layout == .auto), @intFromBool(layout == .@"extern"), 0);
}

pub fn struct_field_type_alias() type {
    var fields = [_]type{u8};
    const U = @TypeOf(@as(@Struct(.auto, null, &.{"item"}, &fields, attributes: {
        const Seen = @TypeOf(comptime effect: {
            fields[0] = u16;
            break :effect @as(u8, 0);
        });
        _ = Seen;
        break :attributes &.{.{}};
    }), undefined));
    return Result(@intFromBool(@FieldType(U, "item") == u16), @intFromBool(fields[0] == u16), 0);
}

pub fn struct_names_alias() type {
    var names = [_][]const u8{"earlier"};
    const U = @TypeOf(@as(@Struct(.auto, null, &names, &.{u8}, attributes: {
        const Seen = @TypeOf(comptime effect: {
            names[0] = "later";
            break :effect @as(u8, 0);
        });
        _ = Seen;
        break :attributes &.{.{}};
    }), undefined));
    return Result(@intFromBool(@hasField(U, "later")), @intFromBool(@hasField(U, "earlier")), 0);
}

pub fn struct_attribute_result_type() type {
    var executions: usize = 0;
    const U = @TypeOf(@as(@Struct(.auto, null, &.{"item"}, &.{u8}, &.{.{ .@"align" = @intCast(block: {
        const Seen = @TypeOf(comptime effect: {
            executions += 1;
            break :effect @as(u8, 0);
        });
        _ = Seen;
        break :block @as(usize, 4);
    }) }}), undefined));
    return Result(@typeInfo(U).@"struct".fields[0].alignment.?, executions, 0);
}

pub fn union_layout_snapshot() type {
    var layout: std.builtin.Type.ContainerLayout = .auto;
    const U = @TypeOf(@as(@Union(layout, null, &.{"item"}, &.{u8}, attributes: {
        const Seen = @TypeOf(comptime effect: {
            layout = .@"extern";
            break :effect @as(u8, 0);
        });
        _ = Seen;
        break :attributes &.{.{}};
    }), undefined));
    return Result(@intFromBool(@typeInfo(U).@"union".layout == .auto), @intFromBool(layout == .@"extern"), 0);
}

pub fn union_tag_snapshot() type {
    var Tag: type = enum { item };
    const Original = Tag;
    const U = @TypeOf(@as(@Union(.auto, Tag, &.{"item"}, &.{u8}, attributes: {
        const Seen = @TypeOf(comptime effect: {
            Tag = enum { other };
            break :effect @as(u8, 0);
        });
        _ = Seen;
        break :attributes &.{.{}};
    }), undefined));
    return Result(@intFromBool(@typeInfo(U).@"union".tag_type.? == Original), @intFromBool(Tag != Original), 0);
}

pub fn enum_tag_snapshot() type {
    var Tag: type = u8;
    const U = @TypeOf(@as(@Enum(Tag, .exhaustive, &.{"item"}, values: {
        const Seen = @TypeOf(comptime effect: {
            Tag = u16;
            break :effect @as(u8, 0);
        });
        _ = Seen;
        break :values &.{1};
    }), undefined));
    return Result(@intFromBool(@typeInfo(U).@"enum".tag_type == u8), @intFromBool(Tag == u16), 0);
}

pub fn enum_mode_snapshot() type {
    var mode: std.builtin.Type.Enum.Mode = .exhaustive;
    const U = @TypeOf(@as(@Enum(u8, mode, &.{"item"}, values: {
        const Seen = @TypeOf(comptime effect: {
            mode = .nonexhaustive;
            break :effect @as(u8, 0);
        });
        _ = Seen;
        break :values &.{1};
    }), undefined));
    return Result(@intFromBool(@typeInfo(U).@"enum".is_exhaustive), @intFromBool(mode == .nonexhaustive), 0);
}

pub fn enum_value_result_type() type {
    var executions: usize = 0;
    const U = @TypeOf(@as(@Enum(u8, .exhaustive, &.{"item"}, &.{@intCast(block: {
        const Seen = @TypeOf(comptime effect: {
            executions += 1;
            break :effect @as(u8, 0);
        });
        _ = Seen;
        break :block @as(usize, 3);
    })}), undefined));
    return Result(@typeInfo(U).@"enum".fields[0].value, executions, 0);
}

pub fn struct_backing_snapshot() type {
    var Backing: type = u8;
    const U = @TypeOf(@as(@Struct(.@"packed", Backing, &.{"item"}, &.{u8}, attributes: {
        const Seen = @TypeOf(comptime effect: {
            Backing = i8;
            break :effect @as(u8, 0);
        });
        _ = Seen;
        break :attributes &.{.{}};
    }), undefined));
    return Result(@intFromBool(@typeInfo(U).@"struct".backing_integer.? == u8), @intFromBool(Backing == i8), 0);
}

pub fn union_field_type_alias() type {
    var fields = [_]type{u8};
    const U = @TypeOf(@as(@Union(.auto, null, &.{"item"}, &fields, attributes: {
        const Seen = @TypeOf(comptime effect: {
            fields[0] = u16;
            break :effect @as(u8, 0);
        });
        _ = Seen;
        break :attributes &.{.{}};
    }), undefined));
    return Result(@intFromBool(@FieldType(U, "item") == u16), @intFromBool(fields[0] == u16), 0);
}

pub fn union_attribute_result_type() type {
    var executions: usize = 0;
    const U = @TypeOf(@as(@Union(.auto, null, &.{"item"}, &.{u8}, &.{.{ .@"align" = @intCast(block: {
        const Seen = @TypeOf(comptime effect: {
            executions += 1;
            break :effect @as(u8, 0);
        });
        _ = Seen;
        break :block @as(usize, 4);
    }) }}), undefined));
    return Result(@typeInfo(U).@"union".fields[0].alignment.?, executions, 0);
}

pub fn enum_names_alias() type {
    var names = [_][]const u8{"earlier"};
    const U = @TypeOf(@as(@Enum(u8, .exhaustive, &names, values: {
        const Seen = @TypeOf(comptime effect: {
            names[0] = "later";
            break :effect @as(u8, 0);
        });
        _ = Seen;
        break :values &.{1};
    }), undefined));
    return Result(@intFromBool(@hasField(U, "later")), @intFromBool(@hasField(U, "earlier")), 0);
}

pub fn container_arguments_evaluate_once() type {
    var trace: usize = 0;
    const U = @TypeOf(@as(@Struct(layout: {
        trace = trace * 10 + 1;
        break :layout .auto;
    }, backing: {
        trace = trace * 10 + 2;
        break :backing null;
    }, names: {
        trace = trace * 10 + 3;
        break :names &.{"item"};
    }, fields: {
        trace = trace * 10 + 4;
        break :fields &.{u8};
    }, attributes: {
        const Seen = @TypeOf(comptime effect: {
            trace = trace * 10 + 5;
            break :effect @as(u8, 0);
        });
        _ = Seen;
        break :attributes &.{.{}};
    }), undefined));
    return Result(@intFromBool(@FieldType(U, "item") == u8), trace, 0);
}

pub fn successive_container_queries() type {
    var fields = [_]type{u8};
    var executions: usize = 0;
    const A = @TypeOf(@as(@Struct(.auto, null, &.{"item"}, &fields, attributes: {
        const Seen = @TypeOf(comptime effect: {
            executions += 1;
            fields[0] = u16;
            break :effect @as(u8, 0);
        });
        _ = Seen;
        break :attributes &.{.{}};
    }), undefined));
    const B = @TypeOf(@as(@Struct(.auto, null, &.{"item"}, &fields, attributes: {
        const Seen = @TypeOf(comptime effect: {
            executions += 1;
            fields[0] = u32;
            break :effect @as(u8, 0);
        });
        _ = Seen;
        break :attributes &.{.{}};
    }), undefined));
    return Result(@intFromBool(@FieldType(A, "item") == u16), @intFromBool(@FieldType(B, "item") == u32), executions);
}

pub fn typed_temporary_array_once() type {
    var executions: usize = 0;
    const pointer: *const [1]u8 = &.{@intCast(block: {
        executions += 1;
        break :block @as(usize, 3);
    })};
    return Result(pointer[0], executions, @intFromBool(@TypeOf(pointer[0]) == u8));
}

pub fn typed_temporary_struct_once() type {
    const Item = struct { value: u8 };
    var executions: usize = 0;
    const pointer: *const Item = &.{ .value = @intCast(block: {
        executions += 1;
        break :block @as(usize, 3);
    }) };
    return Result(pointer.value, executions, @intFromBool(@TypeOf(pointer.value) == u8));
}

pub fn typed_temporary_optional_once() type {
    var executions: usize = 0;
    const pointer: ?*const [1]u8 = &.{@intCast(block: {
        executions += 1;
        break :block @as(usize, 3);
    })};
    return Result(pointer.?[0], executions, @intFromBool(@TypeOf(pointer.?[0]) == u8));
}

pub fn generated_union_source_tag_identity() type {
    const Tag = enum(u8) { first = 3, second = 7 };
    var executions: usize = 0;
    const U = @Union(.auto, Tag, &.{ "first", "second" }, &.{ u8, u16 }, &.{ .{}, .{} });
    const value = U{ .second = block: {
        executions += 1;
        break :block 300;
    } };
    const tag: Tag = value;
    return Result(@intFromBool(@typeInfo(U).@"union".tag_type.? == Tag), @intFromEnum(tag), executions);
}

pub fn generated_union_captured_tag_identity() type {
    const Tag = enum { item };
    var executions: usize = 0;
    const U = @Union(.auto, Tag, &.{"item"}, &.{u8}, &.{.{}});
    const first: U = .{ .item = 3 };
    executions += first.item;
    return Result(@intFromBool(@typeInfo(U).@"union".tag_type.? == Tag), executions, @intFromBool(@typeInfo(U).@"union".tag_type.? == @TypeOf(@as(Tag, first))));
}
