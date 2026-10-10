const std = @import("std");
const testCompletion = @import("completion.zig").testCompletion;

test "comptime storage snapshots agree with Zig" {
    try testCases(@import("../fixtures/comptime_storage.zig"), @embedFile("../fixtures/comptime_storage.zig"), .{
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
    });
}

test "comptime nested storage snapshots agree with Zig" {
    try testCases(@import("../fixtures/comptime_nested_storage.zig"), @embedFile("../fixtures/comptime_nested_storage.zig"), .{
        "struct_field_snapshot",
        "matrix_row_snapshot",
        "sibling_array_copy",
        "optional_payload_snapshot",
        "error_payload_snapshot",
        "union_payload_snapshot",
        "tuple_child_snapshot",
        "array_of_structs",
        "undefined_struct_array",
        "undefined_matrix",
        "undefined_nested_struct",
        "nested_pointer_alias",
        "nested_aggregate_argument",
        "nested_initializer_snapshot",
    });
}

test "comptime indexed fields agree with Zig" {
    try testCases(@import("../fixtures/comptime_fields.zig"), @embedFile("../fixtures/comptime_fields.zig"), .{
        "wide_snapshots",
        "partial_values_and_defaults",
        "reordered_initializers",
        "appended_fields",
        "initializer_self_reads",
        "dynamic_field_names",
        "nested_wide_snapshot",
        "pointer_after_reordering",
        "generated_wide_type",
        "quoted_fields",
        "repeated_array_pointer",
        "concatenated_array_pointer",
    });
}


test "comptime dynamic fields agree with Zig" {
    try testCases(@import("../fixtures/comptime_dynamic_fields.zig"), @embedFile("../fixtures/comptime_dynamic_fields.zig"), .{
        "scalar_name_effect",
        "aggregate_name_effect",
        "temporary_base",
        "pointer_name_effect",
        "function_base_once",
        "nested_fields_and_index",
        "saved_field_and_alias",
        "dynamic_field_loop",
        "optional_dynamic_field",
        "union_name_effect",
        "tuple_name_effect",
        "field_pointer_name_effect",
        "destructured_fields",
        "escaped_local_and_field",
        "function_field_name_effect",
        "conditional_base",
        "block_base",
        "conditional_pointer_base",
        "error_payload_base",
        "type_namespace_field",
        "bound_type_namespace",
        "explicit_pointer_dereference",
    });
}


fn testCases(comptime fixture: type, comptime fixture_source: []const u8, comptime cases: anytype) !void {
    inline for (cases) |name| {
        errdefer std.debug.print("comptime storage case: {s}\n", .{name});
        const Expected = @field(fixture, name)();
        const source = try std.fmt.allocPrint(
            std.testing.allocator,
            "{s}\nconst selected: {s}() = undefined;\nconst field = selected.<cursor>\n",
            .{ fixture_source, name },
        );
        defer std.testing.allocator.free(source);
        try testCompletion(source, &.{
            .{ .label = "first", .kind = .Field, .detail = @typeName(@FieldType(Expected, "first")) },
            .{ .label = "second", .kind = .Field, .detail = @typeName(@FieldType(Expected, "second")) },
            .{ .label = "third", .kind = .Field, .detail = @typeName(@FieldType(Expected, "third")) },
        });
    }
}

