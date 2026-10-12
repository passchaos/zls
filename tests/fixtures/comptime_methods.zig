const std = @import("std");

fn Result(comptime first: usize, comptime second: usize, comptime third: usize) type {
    return struct { first: [first]u8, second: [second]u8, third: [third]u8 };
}

const Check = struct {
    count: usize,

    fn matches(self: @This(), expected: usize) bool {
        return self.count == expected;
    }

    fn add(self: @This(), amount: usize) @This() {
        return .{ .count = self.count + amount };
    }

    fn record(self: @This(), output: *usize, expected: usize) void {
        if (self.matches(expected)) output.* += 1;
    }

    fn recordComptime(comptime self: @This(), output: *usize) void {
        output.* += self.count;
    }
};

fn make(executions: *usize) Check {
    executions.* += 1;
    return .{ .count = 4 };
}

fn argument(executions: *usize) usize {
    executions.* += 1;
    return 4;
}

pub fn local_arguments() type {
    const check = Check{ .count = 4 };
    const expected: usize = 4;
    var amount: usize = 1;
    amount += 2;
    const added = check.add(amount);
    return Result(@intFromBool(check.matches(expected)), added.count, amount);
}

pub fn expression_arguments() type {
    const check = Check{ .count = 4 };
    const expected: usize = 2;
    const added = check.add(expected + 1);
    return Result(@intFromBool(check.matches(expected * 2)), added.count, expected);
}

pub fn effectful_arguments() type {
    var receivers: usize = 0;
    var arguments: usize = 0;
    const matched = make(&receivers).matches(argument(&arguments));
    return Result(@intFromBool(matched), receivers, arguments);
}

pub fn void_methods() type {
    const check = Check{ .count = 4 };
    var recorded: usize = 0;
    const expected: usize = 4;
    check.record(&recorded, expected);
    check.recordComptime(&recorded);
    return Result(recorded, check.count, expected);
}

pub fn nested_receiver() type {
    const state = .{ .check = Check{ .count = 4 }, .expected = @as(usize, 4) };
    var recorded: usize = 0;
    state.check.record(&recorded, state.expected);
    const matched = state.check.matches(state.expected);
    return Result(recorded, @intFromBool(matched), state.check.count);
}

pub fn temporary_void_receiver() type {
    var receivers: usize = 0;
    var recorded: usize = 0;
    make(&receivers).recordComptime(&recorded);
    return Result(recorded, receivers, 0);
}

fn reflectedSource(executions: *usize) type {
    executions.* += 1;
    return struct { first: u8, @"second field": u16 };
}

pub fn reflected_method_types() type {
    var executions: usize = 0;
    const Tag = std.meta.FieldEnum(reflectedSource(&executions));
    const ThroughCall = @call(.auto, std.meta.FieldEnum, .{reflectedSource(&executions)});
    return Result(@intFromEnum(Tag.@"second field"), @intFromEnum(ThroughCall.first), executions);
}

pub fn reflected_union_tag() type {
    const Tag = enum(u8) { first, second };
    const Source = union(Tag) { first: u8, second: u16 };
    const check = Check{ .count = 4 };
    const Enum = std.meta.FieldEnum(Source);
    return Result(@intFromBool(Enum == Tag), @intFromEnum(Enum.second), @intFromBool(check.matches(4)));
}

pub fn lexical_receiver_values() type {
    var expected: usize = 4;
    const check = Check{ .count = 4 };
    var before: usize = 0;
    var after: usize = 0;
    for (0..2) |index| {
        if (check.matches(expected)) before += index + 1;
        expected += 1;
        if (check.matches(expected)) after += index + 1;
    }
    const first = block: {
        const @"same name" = Check{ .count = 7 };
        break :block @intFromBool(@"same name".matches(7));
    };
    const second = block: {
        const @"same name" = Check{ .count = 9 };
        break :block @intFromBool(@"same name".matches(9));
    };
    return Result(before, after, @as(usize, first) + second);
}

fn recurse(executions: *usize, comptime depth: usize) type {
    executions.* += 1;
    if (depth == 0) return struct { item: u8 };
    return recurse(executions, depth - 1);
}

pub fn recursive_type_effects() type {
    var executions: usize = 0;
    const Generated = recurse(&executions, 3);
    return Result(executions, @sizeOf(Generated), 0);
}

const Counter = struct {
    count: usize,

    fn add(self: *@This(), amount: usize) void {
        self.count += amount;
    }

    fn increment(self: *@This()) usize {
        self.count += 1;
        return self.count;
    }

    fn read(self: *const @This()) usize {
        return self.count;
    }

    fn byValue(self: @This(), amount: usize) usize {
        return self.count + amount;
    }
};

pub fn mutable_method_receiver() type {
    var counter = Counter{ .count = 2 };
    counter.add(3);
    const count = counter.increment();
    return Result(counter.count, count, counter.read());
}

pub fn pointer_method_receiver() type {
    var counter = Counter{ .count = 2 };
    const pointer = &counter;
    pointer.add(3);
    const count = pointer.byValue(1);
    return Result(counter.count, count, pointer.read());
}

pub fn nested_mutable_method_receiver() type {
    var state: struct { counter: Counter, other: usize } = .{ .counter = .{ .count = 2 }, .other = 7 };
    const before = state.counter;
    state.counter.add(3);
    return Result(before.count, state.counter.count, state.other);
}

pub fn constant_method_receiver() type {
    const counter = Counter{ .count = 3 };
    return Result(counter.read(), counter.byValue(1), counter.count);
}

fn selectedIndex(executions: *usize) usize {
    executions.* += 1;
    return 1;
}

pub fn indexed_method_receiver() type {
    var counters = [_]Counter{ .{ .count = 2 }, .{ .count = 4 } };
    var executions: usize = 0;
    counters[selectedIndex(&executions)].add(3);
    return Result(counters[0].count, counters[1].count, executions);
}

pub fn indexed_pointer_method_receiver() type {
    var counters = [_]Counter{ .{ .count = 2 }, .{ .count = 4 } };
    const pointer = &counters;
    var executions: usize = 0;
    pointer[selectedIndex(&executions)].add(3);
    return Result(counters[0].count, counters[1].count, executions);
}

fn redirectedArgument(pointer: **Counter, next: *Counter) usize {
    pointer.* = next;
    return 3;
}

pub fn aliased_method_receiver() type {
    var first = Counter{ .count = 2 };
    var second = Counter{ .count = 4 };
    var pointer = &first;
    pointer.add(redirectedArgument(&pointer, &second));
    return Result(first.count, second.count, pointer.count);
}

fn changedArgument(counter: *Counter) usize {
    counter.count = 9;
    return 3;
}

pub fn by_value_receiver_snapshot() type {
    var counter = Counter{ .count = 2 };
    const pointer = &counter;
    const result = pointer.byValue(changedArgument(pointer));
    return Result(result, counter.count, 0);
}

fn counterPointer(counter: *Counter, executions: *usize) *Counter {
    executions.* += 1;
    return counter;
}

pub fn returned_pointer_method_receiver() type {
    var counter = Counter{ .count = 2 };
    var executions: usize = 0;
    counterPointer(&counter, &executions).add(3);
    return Result(counter.count, executions, counter.read());
}

fn makeCounter(executions: *usize) Counter {
    executions.* += 1;
    return .{ .count = 3 };
}

pub fn temporary_const_method_receiver() type {
    var executions: usize = 0;
    const result = makeCounter(&executions).read();
    return Result(result, executions, 0);
}

pub fn optional_method_receiver() type {
    var counter: ?Counter = .{ .count = 2 };
    counter.?.add(3);
    return Result(counter.?.count, counter.?.read(), 0);
}

fn receiverField(executions: *usize) []const u8 {
    executions.* += 1;
    return "counter";
}

pub fn dynamic_field_method_receiver() type {
    var state: struct { counter: Counter, other: usize } = .{ .counter = .{ .count = 2 }, .other = 7 };
    var executions: usize = 0;
    @field(state, receiverField(&executions)).add(3);
    return Result(state.counter.count, state.other, executions);
}

fn changingIndex(counters: *[2]Counter, executions: *usize) usize {
    executions.* += 1;
    counters[1].count = 8;
    return 1;
}

pub fn changed_index_method_receiver() type {
    var counters = [_]Counter{ .{ .count = 2 }, .{ .count = 4 } };
    var executions: usize = 0;
    counters[changingIndex(&counters, &executions)].add(3);
    return Result(counters[0].count, counters[1].count, executions);
}

pub fn method_receiver_returned_alias() type {
    const Holder = struct {
        counter: Counter,
        fn alias(self: *@This()) *Counter {
            return &self.counter;
        }
    };
    var holder = Holder{ .counter = .{ .count = 2 } };
    const alias = holder.alias();
    alias.add(3);
    return Result(holder.counter.count, alias.count, 0);
}
