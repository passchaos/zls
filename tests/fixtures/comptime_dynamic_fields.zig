fn Result(comptime a: usize, comptime b: usize, comptime c: usize) type {
    return struct { first: [a]u8, second: [b]u8, third: [c]u8 };
}

const State = struct { value: usize, values: [2]usize = .{ 3, 4 } };

pub fn scalar_name_effect() type {
    var state = State{ .value = 1 };
    const selected = @field(state, blk: {
        state.value = 2;
        break :blk "value";
    });
    return Result(selected, state.value, 0);
}

pub fn aggregate_name_effect() type {
    var state = State{ .value = 1 };
    const selected = @field(state, blk: {
        state.values = .{ 5, 6 };
        break :blk "values";
    });
    state.values[0] = 7;
    return Result(selected[0], selected[1], state.values[0]);
}

pub fn temporary_base() type {
    var state = State{ .value = 1 };
    const selected = @field(@as(State, state), blk: {
        state.value = 2;
        break :blk "value";
    });
    return Result(selected, state.value, 0);
}

pub fn pointer_name_effect() type {
    var left = State{ .value = 1 };
    var right = State{ .value = 2 };
    var pointer = &left;
    const selected = @field(pointer, blk: {
        pointer = &right;
        left.value = 3;
        break :blk "value";
    });
    return Result(selected, pointer.value, left.value);
}

fn getPointer(count: *usize, state: *State) *State {
    count.* += 1;
    return state;
}

pub fn function_base_once() type {
    var count: usize = 0;
    var state = State{ .value = 1 };
    const selected = @field(getPointer(&count, &state), blk: {
        state.value = 2;
        break :blk "value";
    });
    return Result(selected, state.value, count);
}

pub fn nested_fields_and_index() type {
    var outer = struct { state: State }{ .state = .{ .value = 1 } };
    var count: usize = 0;
    const selected = @field(@field(outer, blk: {
        count += 1;
        break :blk "state";
    }), blk: {
        count += 2;
        break :blk "values";
    })[
        blk: {
            count += 4;
            outer.state.values[0] = 5;
            break :blk 0;
        }
    ];
    return Result(selected, count, outer.state.values[0]);
}

pub fn saved_field_and_alias() type {
    var state = State{ .value = 1 };
    const alias = &@field(state, "values");
    alias[0] = 5;
    const saved = @field(state, "values");
    @field(state, "values")[0] = 6;
    alias[1] = 7;
    return Result(saved[0], @field(state, "values")[0], alias[1]);
}

pub fn dynamic_field_loop() type {
    var state = State{ .value = 1 };
    for (0..4) |_| {
        @field(state, "value") = @field(state, "value") + 1;
        @field(state, "values")[0] = @field(state, "values")[0] + 1;
    }
    return Result(state.value, state.values[0], state.values[1]);
}

pub fn optional_dynamic_field() type {
    var state: ?State = .{ .value = 1 };
    const saved = @field(state.?, "values");
    @field(state.?, "values")[0] = 5;
    @field(state.?, "value") = 6;
    return Result(saved[0], state.?.values[0], state.?.value);
}

pub fn union_name_effect() type {
    const Payload = union(enum) { first: usize, second: usize };
    var payload = Payload{ .first = 1 };
    const selected = @field(payload, blk: {
        payload = .{ .second = 2 };
        break :blk "second";
    });
    return Result(selected, payload.second, 0);
}

pub fn tuple_name_effect() type {
    var values: struct { usize, usize } = .{ 1, 2 };
    const selected = @field(values, blk: {
        values[1] = 3;
        break :blk "1";
    });
    return Result(selected, values[0], values[1]);
}

pub fn field_pointer_name_effect() type {
    var state = State{ .value = 1 };
    var count: usize = 0;
    const pointer = &@field(state, blk: {
        state.value = 2;
        count += 1;
        break :blk "value";
    });
    pointer.* += 1;
    return Result(pointer.*, state.value, count);
}

pub fn destructured_fields() type {
    var state = State{ .value = 1 };
    @field(state, "values")[0], @field(state, "values")[1] = .{
        @field(state, "values")[1], @field(state, "values")[0],
    };
    return Result(state.values[0], state.values[1], state.value);
}

pub fn escaped_local_and_field() type {
    var @"local\"state" = struct { @"field\"name": usize }{ .@"field\"name" = 1 };
    const selected = @field(@"local\"state", blk: {
        @"local\"state".@"field\"name" = 2;
        break :blk "field\"name";
    });
    return Result(selected, @"local\"state".@"field\"name", 0);
}

pub fn function_field_name_effect() type {
    const Container = struct {
        fn one() usize {
            return 1;
        }
        fn two() usize {
            return 2;
        }
    };
    var functions = struct { call: *const fn () usize }{ .call = Container.one };
    const selected = @field(functions, blk: {
        functions.call = Container.two;
        break :blk "call";
    });
    return Result(selected(), functions.call(), 0);
}

pub fn conditional_base() type {
    var left = State{ .value = 1 };
    const right = State{ .value = 2 };
    const selected = @field(if (true) left else right, blk: {
        left.value = 3;
        break :blk "value";
    });
    return Result(selected, left.value, right.value);
}

pub fn block_base() type {
    var state = State{ .value = 1 };
    const selected = @field(blk: {
        break :blk state;
    }, blk: {
        state.values = .{ 5, 6 };
        break :blk "values";
    });
    state.values[0] = 7;
    return Result(selected[0], selected[1], state.values[0]);
}

pub fn conditional_pointer_base() type {
    var left = State{ .value = 1 };
    var right = State{ .value = 2 };
    var pointer = &left;
    const selected = @field(if (true) pointer else &right, blk: {
        pointer = &right;
        left.value = 3;
        break :blk "value";
    });
    return Result(selected, pointer.value, left.value);
}

pub fn error_payload_base() type {
    var value: error{Missing}!State = .{ .value = 1 };
    const pointer = if (value) |*payload| payload else |_| unreachable;
    const selected = @field(value catch unreachable, blk: {
        pointer.value = 2;
        break :blk "value";
    });
    return Result(selected, pointer.value, 0);
}

pub fn type_namespace_field() type {
    const Namespace = struct {
        pub const value = 3;
    };
    return Result(@field(Namespace, "value"), 0, 0);
}

pub fn bound_type_namespace() type {
    var Namespace: type = struct {
        pub const value = 3;
    };
    Namespace = struct {
        pub const value = 4;
    };
    return Result(@field(Namespace, "value"), 0, 0);
}

pub fn explicit_pointer_dereference() type {
    var left = State{ .value = 1 };
    var right = State{ .value = 2 };
    var pointer = &left;
    const selected = @field(pointer.*, blk: {
        pointer = &right;
        left.value = 3;
        break :blk "value";
    });
    return Result(selected, pointer.value, left.value);
}
