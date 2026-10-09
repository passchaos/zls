const std = @import("std");
const fixture = @import("../fixtures/comptime_storage.zig");
const testCompletion = @import("completion.zig").testCompletion;

test "comptime storage snapshots agree with Zig" {
    const cases = .{
        "successive_snapshots",
        "independent_cells",
        "pointer_alias_and_snapshot",
        "nested_child_snapshot",
        "nested_field_snapshot",
        "whole_array_replacement",
        "by_value_argument",
        "captured_type_bindings",
        "snapshot_during_initializer",
        "tuple_snapshot",
        "vector_snapshot",
        "element_pointer",
        "early_return_snapshot",
        "loop_carried_values",
        "effectful_index",
        "nested_effectful_index",
        "temporary_effectful_index",
        "pointer_effectful_index",
        "labeled_switch_array",
        "vector_effectful_index",
    };
    inline for (cases) |name| {
        errdefer std.debug.print("comptime storage case: {s}\n", .{name});
        const Expected = @field(fixture, name)();
        const source = try std.fmt.allocPrint(
            std.testing.allocator,
            "{s}\nconst selected: {s}() = undefined;\nconst field = selected.<cursor>\n",
            .{ @embedFile("../fixtures/comptime_storage.zig"), name },
        );
        defer std.testing.allocator.free(source);
        try testCompletion(source, &.{
            .{ .label = "first", .kind = .Field, .detail = @typeName(@FieldType(Expected, "first")) },
            .{ .label = "second", .kind = .Field, .detail = @typeName(@FieldType(Expected, "second")) },
            .{ .label = "third", .kind = .Field, .detail = @typeName(@FieldType(Expected, "third")) },
        });
    }
}
