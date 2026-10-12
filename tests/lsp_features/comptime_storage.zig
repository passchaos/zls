const std = @import("std");
const testCompletion = @import("completion.zig").testCompletion;

test "comptime TypeOf operands agree with Zig" {
    try testCases(@import("../fixtures/comptime_typeof.zig"), @embedFile("../fixtures/comptime_typeof.zig"), .{
        "explicit_comptime_operand",
        "multiple_comptime_operands",
        "nested_comptime_operand",
        "comptime_block_operand",
        "selected_comptime_branch",
        "ordinary_call_with_comptime_argument",
        "signature_typeof_effects",
        "ordinary_operand_not_executed",
        "repeated_type_queries",
        "nested_type_queries",
        "nested_type_query_operand",
        "selected_comptime_switch",
        "mixed_comptime_operands",
        "query_context_restored",
        "nested_query_result_type",
        "comptime_parameter_in_ordinary_call",
        "condition_changes_during_query",
        "query_operands_evaluate_in_order",
        "short_circuit_type_queries",
        "optional_type_queries",
        "error_type_queries",
        "short_circuit_left_snapshot",
        "optional_fallback_left_snapshot",
        "error_fallback_left_snapshot",
        "optional_capture_snapshot",
        "optional_value_capture_snapshot",
        "optional_reference_capture_updates",
        "error_payload_capture_snapshot",
        "error_capture_snapshot",
        "nested_optional_alias_snapshot",
        "call_type_argument_snapshot",
        "call_conditional_argument_snapshot",
        "selected_callable_snapshot",
        "call_length_argument_snapshot",
        "repeated_call_queries",
        "call_enum_argument_snapshot",
        "call_value_receiver_snapshot",
        "call_argument_result_type",
        "call_pointer_value_receiver_snapshot",
        "call_receiver_argument_result_type",
        "nested_call_type_argument_snapshot",
    });
}

test "comptime TypeOf aggregate operands agree with Zig" {
    try testCases(@import("../fixtures/comptime_typeof.zig"), @embedFile("../fixtures/comptime_typeof.zig"), .{
        "cast_type_snapshot",
        "cast_result_type_snapshot",
        "array_type_snapshot",
        "array_length_snapshot",
        "struct_type_snapshot",
        "array_element_result_type",
        "struct_field_result_type",
        "nested_literal_result_type",
        "inferred_array_type_snapshot",
        "tuple_element_result_types",
        "wrapped_literal_result_types",
        "grouped_literal_result_type",
        "union_literal_type_snapshot",
        "union_init_type_snapshot",
        "repeated_aggregate_queries",
    });
}

test "comptime TypeOf anonymous operands agree with Zig" {
    try testCases(@import("../fixtures/comptime_typeof.zig"), @embedFile("../fixtures/comptime_typeof.zig"), .{
        "tuple_value_snapshot",
        "tuple_type_snapshot",
        "anonymous_field_snapshot",
        "array_type_length_operand_snapshot",
        "array_type_sentinel_operand_snapshot",
        "anonymous_ordinary_call_effects",
        "typed_ordinary_call_effects",
        "anonymous_runtime_field_metadata",
        "tuple_runtime_field_metadata",
    });
}

test "comptime TypeOf type constructors agree with Zig" {
    try testCases(@import("../fixtures/comptime_typeof.zig"), @embedFile("../fixtures/comptime_typeof.zig"), .{
        "vector_length_snapshot",
        "pointer_alignment_child_order",
        "pointer_sentinel_child_order",
        "pointer_alignment_type_snapshot",
        "pointer_sentinel_type_snapshot",
        "pointer_qualifier_order",
        "pointer_bit_range_order",
        "pointer_address_space_order",
        "pointer_sentinel_alignment_snapshot",
        "repeated_pointer_type_queries",
    });
}

test "comptime TypeOf builtin constructors agree with Zig" {
    try testCases(@import("../fixtures/comptime_typeof.zig"), @embedFile("../fixtures/comptime_typeof.zig"), .{
        "int_signedness_snapshot",
        "int_bits_result_type",
        "pointer_builtin_size_snapshot",
        "pointer_builtin_attributes_snapshot",
        "pointer_builtin_child_snapshot",
        "pointer_builtin_attribute_result_type",
        "fn_builtin_return_snapshot",
        "fn_builtin_parameter_alias",
        "pointer_builtin_sentinel_result_type",
        "builtin_arguments_evaluate_once",
        "repeated_builtin_type_queries",
        "direct_builtin_result_types",
        "tuple_builtin_array_types",
    });
}

test "comptime TypeOf container constructors agree with Zig" {
    try testCases(@import("../fixtures/comptime_typeof.zig"), @embedFile("../fixtures/comptime_typeof.zig"), .{
        "struct_layout_snapshot",
        "struct_field_type_alias",
        "struct_names_alias",
        "struct_attribute_result_type",
        "union_layout_snapshot",
        "union_tag_snapshot",
        "enum_tag_snapshot",
        "enum_mode_snapshot",
        "enum_value_result_type",
        "struct_backing_snapshot",
        "union_field_type_alias",
        "union_attribute_result_type",
        "enum_names_alias",
        "container_arguments_evaluate_once",
        "successive_container_queries",
        "typed_temporary_array_once",
        "typed_temporary_struct_once",
        "typed_temporary_optional_once",
        "generated_union_source_tag_identity",
        "generated_union_captured_tag_identity",
    });
}

test "comptime generated union tags agree with Zig" {
    try testCases(@import("../fixtures/comptime_union_tags.zig"), @embedFile("../fixtures/comptime_union_tags.zig"), .{
        "explicit_source_tag",
        "explicit_generated_tag",
        "sparse_source_tag",
        "signed_source_tag",
        "switch_source_tag",
        "independent_source_tags",
        "auto_union_tag_identity",
        "meta_union_tag_identity",
        "captured_auto_union_tag",
        "void_source_tag",
        "automatic_tag_switch",
        "repeated_cached_tags",
        "global_source_tag",
        "global_tag_expression_conversions",
        "global_generated_enum_conversion",
    });
}

test "comptime generated union payloads agree with Zig" {
    try testCases(@import("../fixtures/comptime_union_payloads.zig"), @embedFile("../fixtures/comptime_union_payloads.zig"), .{
        "source_struct_payload",
        "source_enum_payload",
        "optional_source_payload",
        "source_array_payload",
        "untagged_source_payload",
        "source_union_payload",
        "source_payload_switch_capture",
        "source_payload_union_init",
        "generic_source_payload",
        "payload_field_array_alias",
        "packed_source_payload",
        "error_source_payload",
        "nested_generated_payload",
        "global_source_union_init",
        "global_source_union_literal",
    });
}

test "comptime generated union boundaries agree with Zig" {
    try testCases(@import("../fixtures/comptime_union_boundaries.zig"), @embedFile("../fixtures/comptime_union_boundaries.zig"), .{
        "argument_source_payload",
        "returned_source_payload",
        "forwarded_source_payload",
        "optional_returned_payload",
        "error_returned_payload",
        "value_argument_snapshot",
        "comptime_value_argument_snapshot",
        "pointer_argument_alias",
        "returned_payload_control_flow",
        "global_typeof_payload_call",
        "optional_null_payload",
        "named_payload_across_scopes",
        "pointer_qualifier_payload",
        "wrapped_same_type_payload",
    });
}

test "comptime generated container identity agrees with Zig" {
    try testCases(@import("../fixtures/comptime_container_identity.zig"), @embedFile("../fixtures/comptime_container_identity.zig"), .{
        "generic_constructor_identity",
        "generic_enum_identity",
        "generic_union_identity",
        "constructor_effects_once",
        "changed_constructor_fields",
        "independent_constructor_positions",
        "changed_constructor_attributes",
        "changed_enum_values",
        "changed_union_tags",
        "generated_values_cross_calls",
        "changed_field_defaults",
        "mutable_name_arguments",
        "same_generated_enum_values",
        "generated_pointer_qualifiers",
    });
}

test "generated comptime Struct fields agree with Zig" {
    try testCases(@import("../fixtures/comptime_generated_fields.zig"), @embedFile("../fixtures/comptime_generated_fields.zig"), .{
        "generated_comptime_scalar",
        "generated_comptime_undefined",
        "explicit_comptime_initializer",
        "generated_comptime_type",
        "generated_comptime_source_value",
        "generated_comptime_layout",
        "comptime_attribute_identity",
        "repeated_comptime_defaults",
        "explicit_comptime_source_initializer",
        "explicit_comptime_type_initializer",
        "same_comptime_field_write",
        "same_comptime_source_write",
        "same_comptime_type_write",
        "aligned_comptime_field",
        "comptime_only_layout",
        "comptime_initializer_result_location",
        "undefined_comptime_default",
    });
}

test "generated comptime Struct fields reject mismatched values" {
    const statements = [_][]const u8{
        "const value = T{ .fixed = 5, .value = 7 };",
        "const value: T = .{ .fixed = 5, .value = 7 };",
        "var value: T = .{ .value = 7 }; value.fixed = 5;",
        "var value: T = .{ .value = 7 }; @field(value, \"fixed\") = 5;",
        "const value: T = .{ .item = .{ .count = 16 }, .value = 7 };",
        "var value: T = .{ .value = 7 }; value.item.count = 16;",
        "var value: T = .{ .value = 7 }; value.Item = u8;",
    };
    for (statements) |statement| {
        const source = try std.fmt.allocPrint(std.testing.allocator,
            \\fn Select() type {{
            \\    const Item = struct {{ count: usize }};
            \\    const Default = struct {{
            \\        const value: u8 = 3;
            \\        const item: Item = .{{ .count = 15 }};
            \\        const ItemType: type = u16;
            \\    }};
            \\    const T = @Struct(.auto, null, &.{{ "fixed", "item", "Item", "value" }}, &.{{ u8, Item, type, u8 }}, &.{{
            \\        .{{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }},
            \\        .{{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.item) }},
            \\        .{{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.ItemType) }}, .{{}},
            \\    }});
            \\    {s}
            \\    const count = value.value;
            \\    return struct {{ items: [count]u8 }};
            \\}}
            \\const selected: Select() = undefined;
            \\const field = selected.<cursor>
        , .{statement});
        defer std.testing.allocator.free(source);
        errdefer std.debug.print("comptime field mismatch: {s}\n", .{statement});
        try testCompletion(source, &.{
            .{ .label = "items", .kind = .Field, .detail = "[?]u8" },
        });
    }
}

test "generated comptime Struct fields validate construction rules" {
    const cases = [_]struct { layout: []const u8, attributes: []const u8 }{
        .{ .layout = ".auto", .attributes = ".{ .@\"comptime\" = true }" },
        .{ .layout = ".@\"extern\"", .attributes = ".{ .@\"comptime\" = true, .default_value_ptr = @ptrCast(&Default.value) }" },
        .{ .layout = ".@\"packed\"", .attributes = ".{ .@\"comptime\" = true, .default_value_ptr = @ptrCast(&Default.value) }" },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(std.testing.allocator,
            \\fn Generated() type {{
            \\    const Default = struct {{ const value: u8 = 3; }};
            \\    return @Struct({s}, null, &.{{"fixed"}}, &.{{u8}}, &.{{{s}}});
            \\}}
            \\const value: Generated() = undefined;
            \\const field = value.<cursor>
        , .{ case.layout, case.attributes });
        defer std.testing.allocator.free(source);
        errdefer std.debug.print("comptime field construction: {s}, {s}\n", .{ case.layout, case.attributes });
        try testCompletion(source, &.{});
    }
}

test "generated comptime Struct complex defaults agree with Zig" {
    try testCases(@import("../fixtures/comptime_generated_defaults.zig"), @embedFile("../fixtures/comptime_generated_defaults.zig"), .{
        "slice_initializer",
        "slice_write",
        "slice_copy_write",
        "slice_self_write",
        "slice_effect_write",
        "array_initializer",
        "array_write",
        "vector_initializer",
        "vector_write",
        "optional_initializer",
        "optional_write",
        "optional_null_initializer",
        "optional_null_write",
        "error_payload_initializer",
        "error_payload_write",
        "error_failure_initializer",
        "error_failure_write",
        "enum_initializer",
        "union_initializer",
        "source_type_write",
        "array_type_initializer",
        "array_function_default",
        "array_copy_write",
        "pointer_initializer",
        "pointer_write",
        "source_nested_initializer",
        "array_type_write",
        "generic_source_type_write",
        "generic_source_default",
        "undefined_array_initializer",
        "slice_backing_write",
        "slice_backing_initializer",
        "source_union_tag_comparisons",
        "generated_union_tag_comparisons",
    });
}

test "generated comptime Struct slice defaults reject different values" {
    const assignments = [_][]const u8{
        "value.fixed = Other.value[1..];",
        "value.fixed = Backing.value[0..2];",
        "value.fixed = Backing.value[1..2];",
    };
    for (assignments) |assignment| {
        const source = try std.fmt.allocPrint(std.testing.allocator,
            \\fn Select() type {{
            \\    const Backing = struct {{ const value = [_]u8{{ 3, 5, 7 }}; }};
            \\    const Other = struct {{ const value = [_]u8{{ 3, 5, 7 }}; }};
            \\    const Default = struct {{ const value: []const u8 = Backing.value[1..]; }};
            \\    const T = @Struct(.auto, null, &.{{ "fixed", "value" }}, &.{{ []const u8, u8 }}, &.{{
            \\        .{{ .@"comptime" = true, .default_value_ptr = @ptrCast(&Default.value) }}, .{{}},
            \\    }});
            \\    var value: T = .{{ .value = 7 }};
            \\    {s}
            \\    const count = value.value;
            \\    return struct {{ items: [count]u8 }};
            \\}}
            \\const selected: Select() = undefined;
            \\const field = selected.<cursor>
        , .{assignment});
        defer std.testing.allocator.free(source);
        errdefer std.debug.print("slice default mismatch: {s}\n", .{assignment});
        try testCompletion(source, &.{
            .{ .label = "items", .kind = .Field, .detail = "[?]u8" },
        });
    }
}

test "generated Struct rejects unknown field attributes" {
    try testCompletion(
        \\const std = @import("std");
        \\var attributes: std.builtin.Type.StructField.Attributes = undefined;
        \\fn Generated() type {
        \\    return @Struct(.auto, null, &.{"fixed"}, &.{u8}, &.{attributes});
        \\}
        \\const value: Generated() = undefined;
        \\const field = value.<cursor>
    , &.{});
}

test "source comptime Struct fields agree with Zig" {
    try testCases(@import("../fixtures/comptime_source_fields.zig"), @embedFile("../fixtures/comptime_source_fields.zig"), .{
        "scalar_default",
        "scalar_undefined",
        "scalar_initializer",
        "scalar_write",
        "scalar_reassignment",
        "source_default",
        "source_initializer",
        "source_write",
        "type_default",
        "type_initializer",
        "type_write",
        "array_write",
        "optional_write",
        "slice_write",
        "generic_source_defaults",
        "repeated_source_defaults",
        "source_pointer_write",
        "source_comptime_only",
        "source_array_default",
        "source_undefined_default",
        "global_source_defaults",
    });
}

test "source comptime Struct fields reject mismatched values" {
    const statements = [_][]const u8{
        "const value = T{ .fixed = 5, .value = 7 };",
        "const value: T = .{ .fixed = 5, .value = 7 };",
        "var value: T = .{ .value = 7 }; value.fixed = 5;",
        "var value: T = .{ .value = 7 }; @field(value, \"fixed\") = 5;",
        "const value: T = .{ .item = .{ .count = 5 }, .value = 7 };",
        "var value: T = .{ .value = 7 }; value.item.count = 5;",
        "const value: T = .{ .ItemType = u8, .value = 7 };",
        "var value: T = .{ .value = 7 }; value.ItemType = u8;",
    };
    for (statements) |statement| {
        const source = try std.fmt.allocPrint(std.testing.allocator,
            \\fn Select() type {{
            \\    const Item = struct {{ count: usize }};
            \\    const T = struct {{
            \\        comptime fixed: u8 = 3,
            \\        comptime item: Item = .{{ .count = 3 }},
            \\        comptime ItemType: type = Item,
            \\        value: u16,
            \\    }};
            \\    {s}
            \\    const count = value.value;
            \\    return struct {{ items: [count]u8 }};
            \\}}
            \\const selected: Select() = undefined;
            \\const field = selected.<cursor>
        , .{statement});
        defer std.testing.allocator.free(source);
        errdefer std.debug.print("source comptime mismatch: {s}\n", .{statement});
        try testCompletion(source, &.{
            .{ .label = "items", .kind = .Field, .detail = "[?]u8" },
        });
    }
}

test "source comptime Struct type defaults preserve completion" {
    try testCompletion(
        \\const Item = struct { count: u16 };
        \\const Record = struct { comptime ItemType: type = Item, value: u8 };
        \\const record: Record = undefined;
        \\const item: record.ItemType = undefined;
        \\const field = item.<cursor>
    , &.{
        .{ .label = "count", .kind = .Field, .detail = "u16" },
    });
}

test "reflected Struct default pointers agree with Zig" {
    try testCases(@import("../fixtures/comptime_reflected_defaults.zig"), @embedFile("../fixtures/comptime_reflected_defaults.zig"), .{
        "source_scalar",
        "source_comptime",
        "source_type",
        "source_array",
        "source_slice",
        "source_aggregate",
        "source_optional",
        "source_optional_null",
        "generated_scalar",
        "generated_source",
        "generated_type",
        "no_default",
        "repeat_pointer_identity",
        "source_equal_defaults_identity",
        "generated_default_identity",
        "different_defaults_identity",
        "generic_reflected_defaults",
        "copied_reflected_fields",
        "reflected_void_default",
        "generated_array_default",
        "reconstructed_defaults",
        "default_value_method",
        "type_default_value_method",
        "generated_default_value_method",
        "reflected_pointer_effects",
        "optional_reflected_pointer",
        "type_identity_through_return",
        "type_identity_through_break",
        "reflected_signed_read",
    });
}

test "reflected Struct type defaults preserve completion" {
    try testCompletion(
        \\const Item = struct { count: u16 };
        \\const Record = struct { comptime ItemType: type = Item };
        \\const field = @typeInfo(Record).@"struct".fields[0];
        \\const Default = field.defaultValue().?;
        \\const item: Default = undefined;
        \\const member = item.<cursor>
    , &.{
        .{ .label = "count", .kind = .Field, .detail = "u16" },
    });
}

test "reflected Struct default pointers keep oversized reads unknown" {
    try testCompletion(
        \\fn Select() type {
        \\    const T = struct { count: u8 = 3 };
        \\    const field = @typeInfo(T).@"struct".fields[0];
        \\    const pointer: *const u16 = @ptrCast(@alignCast(field.default_value_ptr.?));
        \\    const count = pointer.*;
        \\    return struct { items: [count]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{.{ .label = "items", .kind = .Field, .detail = "[?]u8" }});
}

test "reflected sentinel pointers agree with Zig" {
    try testCases(@import("../fixtures/comptime_reflected_sentinels.zig"), @embedFile("../fixtures/comptime_reflected_sentinels.zig"), .{
        "pointer_sentinel_read",
        "slice_sentinel_read",
        "array_sentinel_read",
        "pointer_sentinel_method",
        "array_sentinel_method",
        "no_pointer_sentinel",
        "no_array_sentinel",
        "wide_sentinel_read",
        "wide_sentinel_method",
        "bool_sentinel_read",
        "sentinel_pointer_identity",
        "array_pointer_sentinel_identity",
        "meta_pointer_sentinel",
        "meta_array_sentinel",
        "meta_single_array_pointer_sentinel",
        "meta_missing_sentinels",
        "generic_sentinel_values",
        "signed_sentinel_value",
        "sentinel_default_shared_identity",
        "sentinel_operand_effects",
        "zero_sentinel_value",
    });
}

test "reflected sentinel methods preserve top-level values" {
    const expressions = [_][]const u8{
        "@typeInfo([*:3]const u8).pointer.sentinel().?",
        "@typeInfo([2:3]u8).array.sentinel().?",
        "@import(\"std\").meta.sentinel([*:3]const u8).?",
        "@import(\"std\").meta.sentinel(*const [2:3]u8).?",
    };
    for (expressions) |expression| {
        const source = try std.fmt.allocPrint(std.testing.allocator,
            \\const count = {s};
            \\const Item = struct {{ bytes: [count]u8 }};
            \\const value: Item = undefined;
            \\const field = value.<cursor>
        , .{expression});
        defer std.testing.allocator.free(source);
        errdefer std.debug.print("top-level sentinel method: {s}\n", .{expression});
        try testCompletion(source, &.{
            .{ .label = "bytes", .kind = .Field, .detail = "[3]u8" },
        });
    }
}

test "reflected sentinel pointers keep oversized reads unknown" {
    try testCompletion(
        \\fn Select() type {
        \\    const info = @typeInfo([*:3]const u8).pointer;
        \\    const pointer: *const u16 = @ptrCast(@alignCast(info.sentinel_ptr.?));
        \\    const count = pointer.*;
        \\    return struct { bytes: [count]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{.{ .label = "bytes", .kind = .Field, .detail = "[?]u8" }});
}

test "comptime union layouts agree with Zig" {
    try testCases(@import("../fixtures/comptime_union_layout.zig"), @embedFile("../fixtures/comptime_union_layout.zig"), .{
        "source_untagged_same",
        "source_untagged_mixed",
        "source_extern",
        "source_extern_array",
        "source_tagged_small",
        "source_tagged_mixed",
        "source_tagged_void",
        "source_tagged_single",
        "source_single_void",
        "source_single_untagged",
        "source_aligned_payload",
        "source_extern_aligned",
        "source_packed",
        "source_tagged_large_tag",
        "generated_extern",
        "generated_untagged",
        "generated_tagged",
        "generated_packed",
        "generated_aligned",
        "source_tagged_payload_padding",
        "source_tagged_tag_padding",
        "source_aligned_zero_payload",
        "source_single_explicit_tag",
        "source_lower_alignment",
        "source_noreturn_payload",
        "source_noreturn_alignment",
        "source_packed_wide",
        "source_packed_zero",
        "source_extern_zero",
        "source_nested_union",
        "source_union_array",
        "explicit_safety_off",
        "explicit_safety_on",
        "generated_safety_off",
        "generated_safety_on",
        "nested_safety_setting",
        "declaration_before_safety_setting",
        "generic_safety_setting",
        "generic_union_payloads",
        "source_packed_float",
        "generated_source_payload",
        "source_safety_effects",
        "generated_safety_effects",
        "global_union_in_unsafe_scope",
        "global_generated_union_in_unsafe_scope",
        "generated_before_safety_setting",
        "safety_restored_after_block",
        "declaration_before_safety_effects",
        "caller_safety_does_not_change_callee",
        "container_safety_scope",
        "container_safety_effects_boundary",
        "source_safety_first_unsafe_identity",
        "source_safety_first_safe_identity",
        "source_safety_captured_identity",
        "source_safety_declaration_capture",
        "source_safety_method_capture",
        "source_packed_bool",
        "source_packed_nested",
        "source_packed_enum",
        "source_extern_optional_pointer",
        "source_extern_vector",
        "source_extern_wide",
        "source_extern_explicit_packed",
        "source_uninstantiable_bits",
        "source_comptime_layout",
        "generated_comptime_layout",
    });
}

test "comptime union layouts follow builtin optimize mode" {
    const zls = @import("zls");
    const Context = @import("../context.zig").Context;
    for ([_]struct { mode: []const u8, size: []const u8 }{
        .{ .mode = "Debug", .size = "[8]u8" },
        .{ .mode = "ReleaseSafe", .size = "[8]u8" },
        .{ .mode = "ReleaseFast", .size = "[4]u8" },
        .{ .mode = "ReleaseSmall", .size = "[4]u8" },
    }) |case| {
        var ctx: Context = try .init();
        defer ctx.deinit();
        const builtin_uri = try zls.Uri.fromPath(ctx.arena.allocator(), "/__zls_union_layout_builtin.zig");
        const builtin_source = try std.fmt.allocPrint(ctx.arena.allocator(), "const std = @import(\"std\"); pub const mode: std.builtin.OptimizeMode = .{s};\n", .{case.mode});
        _ = try ctx.addDocument(.{ .source = builtin_source, .uri = builtin_uri });
        ctx.server.document_store.config.builtin_path = "/__zls_union_layout_builtin.zig";
        const source =
            \\const U = union { a: u8, b: u32 };
            \\fn Source() type { return union { a: u8, b: u32 }; }
            \\fn Generated() type { return @Union(.auto, null, &.{"a", "b"}, &.{u8, u32}, &.{.{}, .{}}); }
            \\fn Safe() type { @setRuntimeSafety(true); return union { a: u8, b: u32 }; }
            \\fn Unsafe() type { @setRuntimeSafety(false); return union { a: u8, b: u32 }; }
            \\const Item = struct {
            \\    bytes: [@sizeOf(U)]u8,
            \\    source: [@sizeOf(Source())]u8,
            \\    generated: [@sizeOf(Generated())]u8,
            \\    safe: [@sizeOf(Safe())]u8,
            \\    unsafe: [@sizeOf(Unsafe())]u8,
            \\};
            \\const value: Item = undefined;
            \\const field = value.
        ;
        const uri = try ctx.addDocument(.{ .source = source });
        const cursor = source.len;
        const result = (try ctx.server.sendRequestSync(ctx.arena.allocator(), "textDocument/completion", zls.lsp.types.completion.Params{
            .textDocument = .{ .uri = uri.raw },
            .position = zls.offsets.indexToPosition(source, cursor, ctx.server.offset_encoding),
        })).?.completion_list;
        try std.testing.expectEqual(@as(usize, 5), result.items.len);
        for (result.items) |item| {
            const expected = if (std.mem.eql(u8, item.label, "safe")) "[8]u8" else if (std.mem.eql(u8, item.label, "unsafe")) "[4]u8" else case.size;
            try std.testing.expectEqualStrings(expected, item.detail.?);
        }
    }
}

test "comptime union layouts keep invalid and unresolved layouts unknown" {
    for ([_][]const u8{
        "const U = packed union { a: u3, b: u5 };",
        "const U = union { child: U };",
        "const U = union { a: u8 align(3), b: u32 };",
        "const U = union { a: Missing, b: u32 };",
        "const U = packed union { a: enum { one, two }, b: u1 };",
        "const U = packed union { a: struct { n: u8 }, b: u8 };",
        "const U = packed union { a: [1]u8, b: u8 };",
        "const U = packed union { a: [0]u8, b: u0 };",
        "const U = packed union { a: noreturn, b: u0 };",
        "const U = extern union { a: union { n: u8 }, b: u8 };",
        "const U = extern union { a: struct { n: u8 }, b: u8 };",
        "const U = extern union { a: noreturn, b: u8 };",
        "const U = extern union { value: u256 };",
        "const U = extern union { value: enum(u3) { a, b } };",
        "const U = packed union { value: *u8 };",
        "const U = packed union { value: ?*u8 };",
        "const U = packed union { value: @Vector(4, u8) };",
        "const U = @Union(.@\"packed\", null, &.{\"a\", \"b\"}, &.{struct { x: u8 }, u8}, &.{.{}, .{}});",
        "const U = @Union(.@\"extern\", null, &.{\"a\", \"b\"}, &.{union { x: u8 }, u8}, &.{.{}, .{}});",
        "const U = @Union(.@\"packed\", null, &.{\"a\", \"b\"}, &.{u3, u5}, &.{.{}, .{}});",
    }) |declaration| {
        const source = try std.fmt.allocPrint(std.testing.allocator,
            \\{s}
            \\const Item = struct {{
            \\    bytes: [@sizeOf(U)]u8,
            \\    alignment: [@alignOf(U)]u8,
            \\    bits: [@bitSizeOf(U)]u8,
            \\}};
            \\const value: Item = undefined;
            \\const field = value.<cursor>
        , .{declaration});
        defer std.testing.allocator.free(source);
        errdefer std.debug.print("union layout declaration: {s}\n", .{declaration});
        try testCompletion(source, &.{
            .{ .label = "bytes", .kind = .Field, .detail = "[?]u8" },
            .{ .label = "alignment", .kind = .Field, .detail = "[?]u8" },
            .{ .label = "bits", .kind = .Field, .detail = "[?]u8" },
        });
    }
    for ([_]struct { declaration: []const u8, alignment: []const u8, bits: []const u8 }{
        .{ .declaration = "const U = union {};", .alignment = "[?]u8", .bits = "[0]u8" },
        .{ .declaration = "const U = union { a: noreturn, b: noreturn };", .alignment = "[?]u8", .bits = "[0]u8" },
        .{ .declaration = "const U = union { a: type, b: u32 };", .alignment = "[4]u8", .bits = "[32]u8" },
        .{ .declaration = "const U = union(enum(u64)) { a: comptime_int, b: u8 };", .alignment = "[1]u8", .bits = "[8]u8" },
        .{ .declaration = "const U = @Union(.auto, null, &.{\"a\", \"b\"}, &.{type, u32}, &.{.{}, .{}});", .alignment = "[4]u8", .bits = "[32]u8" },
    }) |case| {
        const source = try std.fmt.allocPrint(std.testing.allocator,
            \\{s}
            \\const Item = struct {{ bytes: [@sizeOf(U)]u8, alignment: [@alignOf(U)]u8, bits: [@bitSizeOf(U)]u8 }};
            \\const value: Item = undefined;
            \\const field = value.<cursor>
        , .{case.declaration});
        defer std.testing.allocator.free(source);
        errdefer std.debug.print("union layout declaration: {s}\n", .{case.declaration});
        try testCompletion(source, &.{
            .{ .label = "bytes", .kind = .Field, .detail = "[?]u8" },
            .{ .label = "alignment", .kind = .Field, .detail = case.alignment },
            .{ .label = "bits", .kind = .Field, .detail = case.bits },
        });
    }
}

test "comptime optional and error union layouts agree with Zig" {
    try testCases(@import("../fixtures/comptime_wrapped_layout.zig"), @embedFile("../fixtures/comptime_wrapped_layout.zig"), .{
        "optional_integer",
        "optional_small_integer",
        "optional_abi_padding",
        "optional_boolean",
        "optional_void",
        "optional_zero_integer",
        "optional_noreturn",
        "optional_error_set",
        "optional_empty_error_set",
        "error_union_noreturn",
        "error_union_empty_noreturn",
        "optional_pointer",
        "optional_many_pointer",
        "optional_c_pointer",
        "optional_allowzero_pointer",
        "optional_slice",
        "optional_nested",
        "optional_array",
        "optional_source_struct",
        "optional_packed_struct",
        "optional_source_union",
        "optional_generated_union",
        "optional_generic_payload",
        "error_union_integer",
        "error_union_small_integer",
        "error_union_void",
        "error_union_empty_set",
        "error_union_pointer",
        "error_union_array",
        "error_union_packed_struct",
        "error_union_nested_optional",
        "optional_error_union",
        "error_union_source_union",
        "error_sets",
        "wrapped_union_fields",
        "wrapped_struct_fields",
        "wrapped_layout_effects",
        "deeply_nested_optional",
        "successive_wrapped_payloads",
        "generated_wrapped_fields",
        "aligned_zero_optional",
        "aligned_zero_error_union",
        "optional_comptime_bits",
        "error_union_comptime_bits",
        "optional_uninstantiable_union",
        "optional_uninstantiable_struct",
        "nested_uninstantiable_optional",
        "optional_allowzero_slice",
        "nested_optional_error_set",
        "optional_zero_comptime_array",
        "optional_pointer_zero_payload",
        "optional_comptime_container_bits",
        "error_union_comptime_container_bits",
        "nested_comptime_error_union_bits",
        "optional_error_union_uninstantiable",
        "error_union_empty_union",
        "alternating_wrapped_unions",
    });
}

test "comptime wrapped layouts preserve unknown and invalid boundaries" {
    for ([_][]const u8{
        "const T = ?Missing;",
        "const T = error{Missing}!Unknown;",
        "const T = ?union { child: @This() };",
        "const T = ?struct { child: @This() };",
        "const T = ?anyopaque;",
        "const T = ?[0]noreturn;",
        "const T = ?*noreturn;",
        "const T = error{Missing}!error{Other};",
    }) |declaration| {
        const source = try std.fmt.allocPrint(std.testing.allocator,
            \\{s}
            \\const Item = struct {{ bytes: [@sizeOf(T)]u8, alignment: [@alignOf(T)]u8, bits: [@bitSizeOf(T)]u8 }};
            \\const selected: Item = undefined;
            \\const field = selected.<cursor>
        , .{declaration});
        defer std.testing.allocator.free(source);
        errdefer std.debug.print("wrapped layout declaration: {s}\n", .{declaration});
        try testCompletion(source, &.{
            .{ .label = "bytes", .kind = .Field, .detail = "[?]u8" },
            .{ .label = "alignment", .kind = .Field, .detail = "[?]u8" },
            .{ .label = "bits", .kind = .Field, .detail = "[?]u8" },
        });
    }
    for ([_]struct { declaration: []const u8, alignment: []const u8, bits: []const u8 }{
        .{ .declaration = "const T = ?type;", .alignment = "[1]u8", .bits = "[8]u8" },
        .{ .declaration = "const T = ?struct { a: type, b: u32 };", .alignment = "[4]u8", .bits = "[64]u8" },
        .{ .declaration = "const T = error{Missing}!comptime_int;", .alignment = "[2]u8", .bits = "[0]u8" },
    }) |case| {
        const source = try std.fmt.allocPrint(std.testing.allocator,
            \\{s}
            \\const Item = struct {{ bytes: [@sizeOf(T)]u8, alignment: [@alignOf(T)]u8, bits: [@bitSizeOf(T)]u8 }};
            \\const selected: Item = undefined;
            \\const field = selected.<cursor>
        , .{case.declaration});
        defer std.testing.allocator.free(source);
        try testCompletion(source, &.{
            .{ .label = "bytes", .kind = .Field, .detail = "[?]u8" },
            .{ .label = "alignment", .kind = .Field, .detail = case.alignment },
            .{ .label = "bits", .kind = .Field, .detail = case.bits },
        });
    }
}

test "comptime aggregate layouts agree with Zig" {
    try testCases(@import("../fixtures/comptime_aggregate_layout.zig"), @embedFile("../fixtures/comptime_aggregate_layout.zig"), .{
        "source_union_chain",
        "source_struct_chain",
        "generated_union_chain",
        "generated_struct_chain",
        "array_union_chain",
        "array_struct_chain",
        "mixed_chain",
        "explicit_alignment",
        "sentinel_array",
        "packed_payload",
        "field_type_effects",
        "unused_struct_bindings",
        "referenced_struct_bindings",
        "method_struct_bindings",
        "duplicated_child_bindings",
        "successive_nested_types",
        "effectful_layout_fields",
    });
}

test "comptime aggregate layout cache preserves depth and recursion boundaries" {
    try testCompletion(
        \\fn Item() type {
        \\    var Leaf: type = u32;
        \\    for (0..8) |_| Leaf = @Struct(.auto, null, &.{"child"}, &.{Leaf}, &.{.{}});
        \\    var Deep = Leaf;
        \\    for (0..60) |_| Deep = @Struct(.auto, null, &.{"child"}, &.{Deep}, &.{.{}});
        \\    const T = @Struct(.auto, null, &.{"shallow", "deep"}, &.{Leaf, Deep}, &.{.{}, .{}});
        \\    return struct { bytes: [@sizeOf(T)]u8, alignment: [@alignOf(T)]u8, bits: [@bitSizeOf(T)]u8 };
        \\}
        \\const selected: Item() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "bytes", .kind = .Field, .detail = "[?]u8" },
        .{ .label = "alignment", .kind = .Field, .detail = "[?]u8" },
        .{ .label = "bits", .kind = .Field, .detail = "[?]u8" },
    });
    try testCompletion(
        \\const Recursive = packed struct { child: Recursive };
        \\const Item = struct { bytes: [@sizeOf(Recursive)]u8, alignment: [@alignOf(Recursive)]u8, bits: [@bitSizeOf(Recursive)]u8 };
        \\const selected: Item = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "bytes", .kind = .Field, .detail = "[?]u8" },
        .{ .label = "alignment", .kind = .Field, .detail = "[?]u8" },
        .{ .label = "bits", .kind = .Field, .detail = "[?]u8" },
    });
}

test "comptime auto struct layouts and offsets agree with Zig" {
    try testCases(@import("../fixtures/comptime_auto_struct_layout.zig"), @embedFile("../fixtures/comptime_auto_struct_layout.zig"), .{
        "mixed_layout",
        "mixed_offsets",
        "same_alignment_layout",
        "same_alignment_offsets",
        "reversed_alignment_offsets",
        "increased_alignment_layout",
        "increased_alignment_offsets",
        "reduced_alignment_layout",
        "reduced_alignment_offsets",
        "aligned_void_layout",
        "aligned_void_offsets",
        "aligned_zero_array_layout",
        "aligned_zero_array_offsets",
        "generated_layout",
        "generated_offsets",
        "generated_alignment",
        "nested_struct",
        "struct_array",
        "struct_optional",
        "struct_error_union",
        "struct_union",
        "packed_struct_field",
        "generic_layout",
        "explicit_comptime_field",
        "comptime_payload_bits",
        "zero_field_source_order",
        "zero_field_before_payload",
        "comptime_offsets",
        "uninstantiable_offsets",
        "comptime_layout_bits",
        "uninstantiable_bits",
        "generated_comptime_offsets",
        "nested_comptime_layout",
        "zero_runtime_comptime_layout",
    });
}

test "comptime auto struct layout boundaries remain unknown" {
    for ([_][]const u8{
        "const T = struct { a: Missing, b: u32 };",
        "const T = struct { a: @This(), b: u32 };",
        "const T = struct { a: u8 align(3), b: u32 };",
    }) |declaration| {
        const source = try std.fmt.allocPrint(std.testing.allocator,
            \\{s}
            \\const Item = struct {{ bytes: [@sizeOf(T)]u8, alignment: [@alignOf(T)]u8, bits: [@bitSizeOf(T)]u8 }};
            \\const selected: Item = undefined;
            \\const field = selected.<cursor>
        , .{declaration});
        defer std.testing.allocator.free(source);
        try testCompletion(source, &.{
            .{ .label = "bytes", .kind = .Field, .detail = "[?]u8" },
            .{ .label = "alignment", .kind = .Field, .detail = "[?]u8" },
            .{ .label = "bits", .kind = .Field, .detail = "[?]u8" },
        });
    }
    try testCompletion(
        \\const T = struct { comptime fixed: usize = 7, a: u8, b: u32 };
        \\const Item = struct { missing: [@offsetOf(T, "missing")]u8, fixed: [@offsetOf(T, "fixed")]u8 };
        \\const selected: Item = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "missing", .kind = .Field, .detail = "[?]u8" },
        .{ .label = "fixed", .kind = .Field, .detail = "[?]u8" },
    });
    try testCompletion(
        \\const T = struct { a: type, b: u32, c: u8 };
        \\const Item = struct { bytes: [@sizeOf(T)]u8, alignment: [@alignOf(T)]u8, bits: [@bitSizeOf(T)]u8 };
        \\const selected: Item = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "bytes", .kind = .Field, .detail = "[?]u8" },
        .{ .label = "alignment", .kind = .Field, .detail = "[4]u8" },
        .{ .label = "bits", .kind = .Field, .detail = "[64]u8" },
    });
}

test "comptime tuple layouts and offsets agree with Zig" {
    try testCases(@import("../fixtures/comptime_tuple_layout.zig"), @embedFile("../fixtures/comptime_tuple_layout.zig"), .{
        "source_tuple",
        "source_offsets",
        "generated_tuple",
        "generated_offsets",
        "equal_alignment_tuple",
        "zero_fields",
        "empty_tuple",
        "boolean_tuple",
        "source_payload_tuple",
        "source_payload_offsets",
        "wrapped_tuple",
        "error_union_tuple",
        "tuple_array",
        "tuple_struct_field",
        "tuple_union_field",
        "packed_payload_tuple",
        "source_comptime_field",
        "source_comptime_offsets",
        "known_tuple_values",
        "known_undefined_tuple",
        "type_valued_tuple",
        "mixed_tuple_values",
        "mixed_tuple_offset",
        "comptime_tuple_bits",
        "comptime_tuple_offsets",
        "tuple_layout_operand_effects",
        "known_nominal_tuple",
        "mixed_nominal_tuple",
        "nominal_tuple_defaults",
        "source_comptime_tuple_reflection",
        "nominal_tuple_identity",
        "nominal_tuple_effects",
        "args_tuple_layout",
        "runtime_value_tuple",
        "unevaluated_nominal_tuple",
        "runtime_nominal_tuple",
        "undefined_nominal_tuple",
        "nominal_tuple_peer_types",
    });
}

test "comptime tuple layout boundaries remain unknown" {
    for ([_][]const u8{
        "const T = @Tuple(&.{noreturn, u32});",
        "const T = struct { u8 align(16), u32 };",
        "const T = @Tuple(&.{Missing, u32});",
    }) |declaration| {
        const source = try std.fmt.allocPrint(std.testing.allocator,
            \\{s}
            \\const Item = struct {{ bytes: [@sizeOf(T)]u8, alignment: [@alignOf(T)]u8, bits: [@bitSizeOf(T)]u8 }};
            \\const selected: Item = undefined;
            \\const field = selected.<cursor>
        , .{declaration});
        defer std.testing.allocator.free(source);
        try testCompletion(source, &.{
            .{ .label = "bytes", .kind = .Field, .detail = "[?]u8" },
            .{ .label = "alignment", .kind = .Field, .detail = "[?]u8" },
            .{ .label = "bits", .kind = .Field, .detail = "[?]u8" },
        });
    }
    try testCompletion(
        \\const T = @Tuple(&.{u8, u32});
        \\const Known = @TypeOf(.{@as(u8,1), @as(u32,2)});
        \\const Item = struct {
        \\    missing: [@offsetOf(T, "2")]u8,
        \\    invalid: [@offsetOf(T, "field")]u8,
        \\    known: [@offsetOf(Known, "0")]u8,
        \\};
        \\const selected: Item = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "missing", .kind = .Field, .detail = "[?]u8" },
        .{ .label = "invalid", .kind = .Field, .detail = "[?]u8" },
        .{ .label = "known", .kind = .Field, .detail = "[?]u8" },
    });
    try testCompletion(
        \\const T = @Tuple(&.{type, u32});
        \\const Item = struct { bytes: [@sizeOf(T)]u8, alignment: [@alignOf(T)]u8, bits: [@bitSizeOf(T)]u8 };
        \\const selected: Item = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "bytes", .kind = .Field, .detail = "[?]u8" },
        .{ .label = "alignment", .kind = .Field, .detail = "[4]u8" },
        .{ .label = "bits", .kind = .Field, .detail = "[32]u8" },
    });
}

test "comptime signature effects agree with Zig" {
    try testCases(@import("../fixtures/comptime_signature_effects.zig"), @embedFile("../fixtures/comptime_signature_effects.zig"), .{
        "return_type_effect",
        "parameter_type_effect",
        "parameter_and_return_effects",
        "repeated_signature_calls",
        "signature_call_builtin",
        "recursive_signature_calls",
        "signature_argument_order",
        "signature_builtin_argument_order",
        "signature_return_cast",
        "signature_inferred_error",
        "signature_instance_methods",
        "signature_argument_tuple",
        "signature_argument_tuple_metadata",
        "cached_type_argument_effects",
        "aggregate_pointer_call_effects",
        "optional_pointer_call_effects",
    });
}

test "comptime function reflection agrees with Zig" {
    try testCases(@import("../fixtures/comptime_function_reflection.zig"), @embedFile("../fixtures/comptime_function_reflection.zig"), .{
        "generic_return_types",
        "value_dependent_returns",
        "fixed_generic_returns",
        "dependent_parameters",
        "captured_and_escaped_returns",
        "calls_do_not_specialize_reflection",
        "nested_signature_dependencies",
        "nested_array_return_calls",
        "wrapped_array_return_calls",
        "reflected_then_called",
        "function_pointer_reflection",
    });
}

test "comptime instance methods agree with Zig" {
    try testCases(@import("../fixtures/comptime_methods.zig"), @embedFile("../fixtures/comptime_methods.zig"), .{
        "local_arguments",
        "expression_arguments",
        "effectful_arguments",
        "void_methods",
        "nested_receiver",
        "temporary_void_receiver",
        "reflected_method_types",
        "reflected_union_tag",
        "lexical_receiver_values",
        "recursive_type_effects",
        "mutable_method_receiver",
        "pointer_method_receiver",
        "nested_mutable_method_receiver",
        "constant_method_receiver",
        "indexed_method_receiver",
        "indexed_pointer_method_receiver",
        "aliased_method_receiver",
        "by_value_receiver_snapshot",
        "returned_pointer_method_receiver",
        "temporary_const_method_receiver",
        "optional_method_receiver",
        "dynamic_field_method_receiver",
        "changed_index_method_receiver",
        "method_receiver_returned_alias",
    });
}

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
        "builtin_assign_reads",
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
