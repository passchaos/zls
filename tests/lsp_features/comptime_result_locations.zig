const std = @import("std");
const fixture = @import("../fixtures/comptime_result_locations.zig");
const testCompletion = @import("completion.zig").testCompletion;

test "comptime aggregate result locations agree with Zig" {
    @setEvalBranchQuota(30000);
    const cases = .{
        .{ "array_assignment", .{ 2, 2, 0 } },
        .{ "typed_array_assignment", .{ 2, 1, 0 } },
        .{ "struct_assignment", .{ 10, 1, 3 } },
        .{ "typed_struct_assignment", .{ 11, 1, 3 } },
        .{ "array_element_types", .{ 4, 5, 0 } },
        .{ "tuple_element_types", .{ 4, 5, 0 } },
        .{ "optional_array_element_types", .{ 4, 5, 0 } },
        .{ "undefined_array_assignment", .{ 4, 5, 0 } },
        .{ "undefined_struct_assignment", .{ 4, 5, 3 } },
        .{ "nested_assignment", .{ 2, 2, 2 } },
        .{ "deferred_assignment", .{ 3, 2, 0 } },
        .{ "early_return", .{ 7, 2, 0 } },
        .{ "destructured_array_assignment", .{ 2, 2, 0 } },
        .{ "scalar_defer", .{ 2, 0, 0 } },
        .{ "later_field_mutation", .{ 5, 6, 3 } },
        .{ "optional_array_assignment", .{ 4, 5, 0 } },
        .{ "error_union_array_assignment", .{ 4, 5, 0 } },
        .{ "nested_wrapped_assignment", .{ 4, 5, 0 } },
        .{ "union_assignment", .{ 4, 5, 0 } },
        .{ "tuple_assignment", .{ 2, 2, 0 } },
        .{ "vector_assignment", .{ 2, 2, 0 } },
        .{ "as_assignment", .{ 2, 1, 0 } },
        .{ "returned_array_assignment", .{ 2, 1, 0 } },
        .{ "generated_struct_assignment", .{ 10, 1, 3 } },
        .{ "nested_result_control_flow", .{ 2, 2, 0 } },
        .{ "scalar_field_defer", .{ 4, 4, 3 } },
        .{ "opaque_array_result", .{ 1, 2, 0 } },
        .{ "nested_loop_result", .{ 1, 2, 0 } },
    };
    inline for (cases) |case| {
        errdefer std.debug.print("comptime result location case: {s}\n", .{case[0]});
        // Compile the exact source that is subsequently sent to the LSP test.
        const Expected = @field(fixture, case[0])();
        inline for (.{ "first", "second", "third" }, case[1]) |name, len| {
            try std.testing.expectEqual([len]u8, @FieldType(Expected, name));
        }
        const source = try std.fmt.allocPrint(
            std.testing.allocator,
            "{s}\nconst selected: {s}() = undefined;\nconst field = selected.<cursor>\n",
            .{ @embedFile("../fixtures/comptime_result_locations.zig"), case[0] },
        );
        defer std.testing.allocator.free(source);
        try testCompletion(source, &.{
            .{ .label = "first", .kind = .Field, .detail = std.fmt.comptimePrint("[{}]u8", .{case[1][0]}) },
            .{ .label = "second", .kind = .Field, .detail = std.fmt.comptimePrint("[{}]u8", .{case[1][1]}) },
            .{ .label = "third", .kind = .Field, .detail = std.fmt.comptimePrint("[{}]u8", .{case[1][2]}) },
        });
    }
}
