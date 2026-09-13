const std = @import("std");
const zls = @import("zls");

const Context = @import("../context.zig").Context;
const ErrorBuilder = @import("../ErrorBuilder.zig");

const types = zls.lsp.types;
const offsets = zls.offsets;

const allocator: std.mem.Allocator = std.testing.allocator;

const Completion = struct {
    label: []const u8,
    labelDetails: ?types.completion.Item.LabelDetails = null,
    kind: types.completion.Item.Kind,
    detail: ?[]const u8 = null,
    documentation: ?[]const u8 = null,
    deprecated: bool = false,
};

test "root scope" {
    try testCompletion(
        \\const foo = 5;
        \\const bar = <cursor>;
    , &.{
        .{ .label = "foo", .kind = .Constant },
    });

    try testCompletion(
        \\var foo = 5;
        \\const bar = <cursor>
    , &.{
        .{ .label = "foo", .kind = .Variable },
    });

    try testCompletion(
        \\const foo = 5;
        \\const bar = <cursor>;
        \\const baz = 5;
    , &.{
        .{ .label = "foo", .kind = .Constant },
        .{ .label = "baz", .kind = .Constant },
    });
}

test "access root scope through '@This()' builtin" {
    try testCompletion(
        \\const foo = 5;
        \\const Self = @This();
        \\const bar = Self.<cursor>
    , &.{
        .{ .label = "foo", .kind = .Constant },
        .{ .label = "Self", .kind = .Struct },
    });
}

test "root scope with self referential decl" {
    try testCompletion(
        \\const foo = foo;
        \\const bar = <cursor>
    , &.{
        .{ .label = "foo", .kind = .Constant },
    });
}

test "completion with incomplete surrounding code" {
    try testCompletion(
        \\const S = struct { field: u32 };
        \\fn use(value: S) void {
        \\    value.<cursor>
    , &.{
        .{ .label = "field", .kind = .Field, .detail = "u32" },
    });

    try testCompletionWithOptions(
        \\const known = 5;
        \\const broken =
        \\const result = kn<cursor>
    , &.{
        .{ .label = "known", .kind = .Constant },
    }, .{ .allow_additional_completions = true });

    try testCompletion(
        \\const S = struct { field: u32 };
        \\fn use(value: S) void {
        \\    consume(
        \\    value.<cursor>
        \\}
    , &.{
        .{ .label = "field", .kind = .Field, .detail = "u32" },
    });

    try testCompletion(
        \\const S = struct { field: u32 };
        \\fn use(value: S) void {
        \\    const broken = ;
        \\    value.<cursor>
        \\}
    , &.{
        .{ .label = "field", .kind = .Field, .detail = "u32" },
    });

    try testCompletion(
        \\const known = 5;
        \\fn use() void {
        \\    const broken =
        \\    const result = kn<cursor>
        \\}
    , &.{
        .{ .label = "known", .kind = .Constant },
        .{ .label = "use", .kind = .Function, .detail = "fn () void" },
    });

    try testCompletionWithOptions(
        \\const S = struct { field: u32 };
        \\fn use(value: S) void {
        \\    const broken =
        \\    const result = val<cursor>
        \\}
    , &.{
        .{ .label = "value", .kind = .Constant, .detail = "S" },
    }, .{ .allow_additional_completions = true });

    try testCompletionWithOptions(
        \\const known_before = 1;
        \\const result = known<cursor>
        \\const known_after = 2;
    , &.{
        .{ .label = "known_before", .kind = .Constant },
        .{ .label = "known_after", .kind = .Constant },
    }, .{ .allow_additional_completions = true });

    try testCompletion(
        \\const S = struct { field: u32 };
        \\fn use(value: S) void {
        \\    value.<cursor>
        \\    {
        \\        _ = value.field;
        \\    }
        \\    _ = value.field;
        \\}
    , &.{
        .{ .label = "field", .kind = .Field, .detail = "u32" },
    });

    try testCompletionWithOptions(
        \\const std = @import("std");
        \\fn use() void {
        \\    const broken = 1
        \\    std.<cursor>
        \\}
    , &.{
        .{ .label = "ArrayList", .kind = .Struct },
    }, .{ .allow_additional_completions = true });

    try testCompletion(
        \\const S = struct { field: u32 };
        \\fn use(value: S) void {
        \\    value.<cursor>
        \\    const unfinished =
        \\}
    , &.{
        .{ .label = "field", .kind = .Field, .detail = "u32" },
    });

    try testCompletion(
        \\const S = struct { field: u32 };
        \\fn use(value: S) void {
        \\    value.<cursor>
        \\    value.field
        \\}
    , &.{
        .{ .label = "field", .kind = .Field, .detail = "u32" },
    });
}

test "completion prefix recovery preserves the original text edit range" {
    try testCompletionTextEdit(.{
        .source =
        \\const S = struct { field: u32 };
        \\fn use(value: S) void {
        \\    value.fi<cursor>eld
        \\    const unfinished =
        \\}
        ,
        .label = "field",
        .expected_insert_line = "    value.fieldeld",
        .expected_replace_line = "    value.field",
    });

    try testCompletionTextEdit(.{
        .source =
        \\const S = struct { field: u32 };
        \\fn use(value: S) void {
        \\    value.fi<cursor>eld
        ,
        .label = "field",
        .expected_insert_line = "    value.fieldeld",
        .expected_replace_line = "    value.field",
    });
}

test "local scope" {
    if (true) return error.SkipZigTest;
    try testCompletion(
        \\const foo = {
        \\    var bar = 5;
        \\    const alpha = <cursor>;
        \\    const baz = 3;
        \\};
    , &.{
        .{ .label = "bar", .kind = .Variable },
    });
}

test "symbol lookup on escaped identifiers" {
    // decl name:   unescaped
    // symbol name: unescaped
    try testCompletion(
        \\const Bar = struct { const Some = u32; };
        \\const Outer = struct { const Inner = Bar; };
        \\const foo = Outer.Inner.<cursor>
    , &.{
        .{ .label = "Some", .kind = .Constant, .detail = "u32" },
    });
    try testCompletion(
        \\const Bar = struct { const Some = u32; };
        \\const Outer = struct { const Inner = Bar; };
        \\const Inner = Outer.Inner;
        \\const foo = Inner.<cursor>
    , &.{
        .{ .label = "Some", .kind = .Constant, .detail = "u32" },
    });
    // decl name:   escaped
    // symbol name: unescaped
    try testCompletion(
        \\const Bar = struct { const Some = u32; };
        \\const Outer = struct { const @"Inner" = Bar; };
        \\const foo = Outer.Inner.<cursor>
    , &.{
        .{ .label = "Some", .kind = .Constant, .detail = "u32" },
    });
    try testCompletion(
        \\const Bar = struct { const Some = u32; };
        \\const Outer = struct { const @"Inner" = Bar; };
        \\const Inner = Outer.Inner;
        \\const foo = Inner.<cursor>
    , &.{
        .{ .label = "Some", .kind = .Constant, .detail = "u32" },
    });
    // decl name:   unescaped
    // symbol name: escaped
    try testCompletion(
        \\const Bar = struct { const Some = u32; };
        \\const Outer = struct { const Inner = Bar; };
        \\const foo = Outer.@"Inner".<cursor>
    , &.{
        .{ .label = "Some", .kind = .Constant, .detail = "u32" },
    });
    try testCompletion(
        \\const Bar = struct { const Some = u32; };
        \\const Outer = struct { const Inner = Bar; };
        \\const Inner = Outer.@"Inner";
        \\const foo = Inner.<cursor>
    , &.{
        .{ .label = "Some", .kind = .Constant, .detail = "u32" },
    });
    // decl name:   escaped
    // symbol name: escaped
    try testCompletion(
        \\const Bar = struct { const Some = u32; };
        \\const Outer = struct { const @"Inner" = Bar; };
        \\const foo = Outer.@"Inner".<cursor>
    , &.{
        .{ .label = "Some", .kind = .Constant, .detail = "u32" },
    });
    try testCompletion(
        \\const Bar = struct { const Some = u32; };
        \\const Outer = struct { const Inner = Bar; };
        \\const Inner = Outer.@"Inner";
        \\const foo = Inner.<cursor>
    , &.{
        .{ .label = "Some", .kind = .Constant, .detail = "u32" },
    });
}

test "escaped identifier normalization" {
    if (true) return error.SkipZigTest; // TODO
    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\var s: @"\x53" = undefined;
        \\const foo = @"\x73".<cursor>
    , &.{
        .{ .label = "foo", .kind = .Constant },
    });
}

test "symbol lookup on identifier named after primitive" {
    try testCompletion(
        \\const Outer = struct { const @"u32" = Bar; };
        \\const Bar = struct { const Some = u32; };
        \\const foo = Outer.@"u32".<cursor>
    , &.{
        .{ .label = "Some", .kind = .Constant, .detail = "u32" },
    });
    try testCompletion(
        \\const Outer = struct { const @"undefined" = Bar; };
        \\const Bar = struct { const Some = u32; };
        \\const foo = Outer.@"undefined".<cursor>
    , &.{
        .{ .label = "Some", .kind = .Constant, .detail = "u32" },
    });
    try testCompletion(
        \\const @"unreachable" = struct { const Some = u32; };
        \\const foo = @"unreachable".<cursor>
    , &.{
        .{ .label = "Some", .kind = .Constant, .detail = "u32" },
    });
    try testCompletion(
        \\const @"true" = struct { const Some = u32; };
        \\const foo = @"true".<cursor>
    , &.{
        .{ .label = "Some", .kind = .Constant, .detail = "u32" },
    });
}

test "field access iterator resolves builtin values" {
    const source =
        \\const a = true;
        \\const b = false;
        \\const c = null;
        \\const d = undefined;
    ;
    var ctx: Context = try .init();
    defer ctx.deinit();

    const uri = try ctx.addDocument(.{ .source = source });
    const handle = ctx.server.document_store.getHandle(uri).?;
    var analyser = ctx.server.initAnalyser(ctx.arena.allocator(), handle);
    defer analyser.deinit();

    for ([_]struct { name: []const u8, expected: zls.analyser.InternPool.Index }{
        .{ .name = "true", .expected = .bool_true },
        .{ .name = "false", .expected = .bool_false },
        .{ .name = "null", .expected = .null_value },
        .{ .name = "undefined", .expected = .undefined_value },
    }) |case| {
        const start = std.mem.find(u8, source, case.name).?;
        const value = try analyser.getFieldAccessType(handle, source.len, .{
            .start = start,
            .end = start + case.name.len,
        }) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(case.expected, value.ipIndex().?);
    }
}

test "assign destructure" {
    try testCompletion(
        \\test {
        \\    const foo, var bar: u32 = .{42, 7};
        \\    <cursor>
        \\}
    , &.{
        .{ .label = "foo", .kind = .Constant, .detail = "comptime_int" },
        .{ .label = "bar", .kind = .Variable, .detail = "u32" },
    });
    try testCompletion(
        \\test {
        \\    var foo, const bar = .{@as(u32, 42), @as(u64, 7)};
        \\    <cursor>
        \\}
    , &.{
        .{ .label = "foo", .kind = .Variable, .detail = "u32" },
        .{ .label = "bar", .kind = .Constant, .detail = "u64" },
    });
    try testCompletion(
        \\test {
        \\    var foo: u32 = undefined;
        \\    foo, const bar: u64, var baz = [_]u32{1, 2, 3};
        \\    <cursor>
        \\}
    , &.{
        .{ .label = "foo", .kind = .Variable, .detail = "u32" },
        .{ .label = "bar", .kind = .Constant, .detail = "u64" },
        .{ .label = "baz", .kind = .Variable, .detail = "u32" },
    });
}

test "function" {
    try testCompletion(
        \\fn foo(alpha: u32, beta: []const u8) void {
        \\    <cursor>
        \\}
    , &.{
        .{
            .label = "foo",
            .labelDetails = .{
                .detail = "(alpha: u32, beta: []const u8)",
                .description = "void",
            },
            .kind = .Function,
            .detail = "fn (alpha: u32, beta: []const u8) void",
        },
        .{ .label = "alpha", .kind = .Constant, .detail = "u32" },
        .{ .label = "beta", .kind = .Constant, .detail = "[]const u8" },
    });
    try testCompletion(
        \\fn foo(
        \\    comptime T: type,
        \\    value: anytype,
        \\) void {
        \\  <cursor>
        \\}
    , &.{
        .{
            .label = "foo",
            .labelDetails = .{
                .detail = "(comptime T: type, value: anytype)",
                .description = "void",
            },
            .kind = .Function,
            .detail = "fn (comptime T: type, value: anytype) void",
        },
        .{ .label = "T", .kind = .Constant, .detail = "type" },
        .{ .label = "value", .kind = .Constant },
    });

    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\fn foo() S { return undefined; }
        \\const bar = foo().<cursor>;
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
}

test "function alias" {
    try testCompletion(
        \\fn foo() void {
        \\    <cursor>
        \\}
        \\const bar = foo;
        \\const baz = &foo;
    , &.{
        .{
            .label = "foo",
            .kind = .Function,
            .detail = "fn () void",
        },
        .{
            .label = "bar",
            .kind = .Function,
            .detail = "fn () void",
        },
        .{
            .label = "baz",
            .kind = .Function,
            // TODO detail should be '*fn () void' or '*const fn () void'
            .detail = "fn () void",
        },
    });
    try testCompletion(
        \\const S = struct {
        \\    fn foo() void {}
        \\    const bar = foo;
        \\    const baz = &foo;
        \\};
        \\const _ = S.<cursor>
    , &.{
        .{
            .label = "foo",
            .kind = .Function,
            .detail = "fn () void",
        },
        .{
            .label = "bar",
            .kind = .Function,
            .detail = "fn () void",
        },
        .{
            .label = "baz",
            .kind = .Function,
            // TODO detail should be '*fn () void' or '*const fn () void'
            .detail = "fn () void",
        },
    });
    try testCompletion(
        \\const S = struct {
        \\    alpha: u32,
        \\    fn foo(_: S) void {}
        \\    const bar = foo;
        \\};
        \\const baz = S.bar(.<cursor>);
    , &.{
        .{
            .label = "alpha",
            .kind = .Field,
            .detail = "u32",
        },
    });
}

test "generic function" {
    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\fn ArrayList(comptime T: type) type {
        \\    return struct { items: []const T };
        \\}
        \\const array_list: ArrayList(S) = undefined;
        \\const foo = array_list.items[0].<cursor>
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });

    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\fn foo(comptime T: type) T {}
        \\const s = foo(S);
        \\const foo = s.<cursor>
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\fn foo(any: anytype, comptime T: type) T {}
        \\const s = foo(null, S);
        \\const foo = s.<cursor>
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });

    try testCompletion(
        \\const S = struct {
        \\    alpha: u32,
        \\    fn foo(self: S, comptime T: type) T {}
        \\};
        \\const s1: S = undefined;
        \\const s2 = s1.foo(S);
        \\const foo = s2.<cursor>;
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
        .{ .label = "foo", .kind = .Method, .detail = "fn (self: S, comptime T: type) T" },
    });
    try testCompletion(
        \\const S = struct {
        \\    alpha: u32,
        \\    fn foo(self: S, any: anytype, comptime T: type) T {}
        \\};
        \\const s1: S = undefined;
        \\const s2 = s1.foo(null, S);
        \\const foo = s2.<cursor>;
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
        .{ .label = "foo", .kind = .Method, .detail = "fn (self: S, any: anytype, comptime T: type) T" },
    });
}

test "generic function with comptime value parameter" {
    try testCompletion(
        \\fn Vector(comptime N: usize, comptime T: type) type {
        \\    return struct { items: [N]T };
        \\}
        \\const vector: Vector(4, u8) = undefined;
        \\const items = vector.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
    });

    try testCompletion(
        \\fn Vector(comptime N: usize, comptime T: type) type {
        \\    return struct { items: [N]T };
        \\}
        \\const vector: Vector(if (true) 4 else 2, u8) = undefined;
        \\const items = vector.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
    });

    try testCompletion(
        \\fn Vector(comptime N: usize, comptime T: type) type {
        \\    return struct { items: [N]T };
        \\}
        \\const vector: Vector(2 + 2, u8) = undefined;
        \\const items = vector.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
    });

    try testCompletion(
        \\fn Vector(comptime N: usize, comptime T: type) type {
        \\    return struct { items: [N]T };
        \\}
        \\const len = 4;
        \\const vector: Vector(len, u8) = undefined;
        \\const items = vector.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
    });

    try testCompletion(
        \\fn Vector(comptime N: usize, comptime T: type) type {
        \\    return struct { items: [N]T };
        \\}
        \\const vector: Vector(1 / 0, u8) = undefined;
        \\const items = vector.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[?]u8" },
    });
}

test "generic function with comptime string length" {
    try testCompletion(
        \\fn Buffer(comptime N: usize) type {
        \\    return struct { items: [N]u8 };
        \\}
        \\const buffer: Buffer("hello".len) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[5]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime N: usize) type {
        \\    return struct { items: [N]u8 };
        \\}
        \\const name = "界";
        \\const buffer: Buffer(name.len) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[3]u8" },
    });
}

test "generic function with comptime anytype value parameter" {
    try testCompletion(
        \\fn Vector(comptime N: anytype, comptime T: type) type {
        \\    return struct { items: [N]T };
        \\}
        \\const vector: Vector(4, u8) = undefined;
        \\const items = vector.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with comptime field expressions" {
    const cases = [_]struct { field_type: []const u8, detail: []const u8 }{
        .{ .field_type = "[N + 1]T", .detail = "[5]u8" },
        .{ .field_type = "[(N + 1) * 2]T", .detail = "[10]u8" },
        .{ .field_type = "*[N]T", .detail = "*[4]u8" },
        .{ .field_type = "?*[N + 1]T", .detail = "?*[5]u8" },
        .{ .field_type = "[N - 1][N + 1]T", .detail = "[3][5]u8" },
        .{ .field_type = "[if (N > 2) N else 2]T", .detail = "[4]u8" },
        .{ .field_type = "[if (N < 2) 2 else N + 1]T", .detail = "[5]u8" },
        .{ .field_type = "[@as(usize, N + 1)]T", .detail = "[5]u8" },
        .{ .field_type = "@Vector(N, T)", .detail = "@Vector(4,u8)" },
        .{ .field_type = "[N:N]T", .detail = "[4:4]u8" },
        .{ .field_type = "error{}!*[N]T", .detail = "error{}!*[4]u8" },
        .{ .field_type = "[comptime N + 1]T", .detail = "[5]u8" },
        .{ .field_type = "(if (N > 2) [N]T else [2]u16)", .detail = "[4]u8" },
        .{ .field_type = "[if (N > 2) N else @compileError(\"unselected\")]T", .detail = "[4]u8" },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(allocator,
            \\fn Vector(comptime N: usize, comptime T: type) type {{
            \\    return struct {{ items: {s} }};
            \\}}
            \\const vector: Vector(4, u8) = undefined;
            \\const items = vector.<cursor>
        , .{case.field_type});
        defer allocator.free(source);
        try testCompletion(source, &.{
            .{ .label = "items", .kind = .Field, .detail = case.detail },
        });
    }
}

test "generic function with comptime tuple values" {
    try testCompletion(
        \\fn Select(comptime N: usize) type {
        \\    const tuple = .{ N + 1, N == 4 };
        \\    return if (tuple[0] == 5 and tuple[1])
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\var runtime: u8 = undefined;
        \\fn Select(comptime N: usize) type {
        \\    const tuple = .{ N, runtime };
        \\    return if (tuple.@"0" == 4)
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with comptime array values" {
    try testCompletion(
        \\fn Select(comptime N: u8) type {
        \\    const inferred = [_]u8{ 2, N, 6 };
        \\    const explicit = [3]u8{ 3, 5, 7 };
        \\    return if (inferred[1] == 4 and explicit[2] == 7)
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\var runtime: u8 = undefined;
        \\fn Select(comptime N: u8) type {
        \\    const values = [2]u8{ N, runtime };
        \\    return if (values[0] == 4)
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime N: u8) type {
        \\    const joined = [_]u8{ 1, N } ++ [_]u8{ 3, 4 };
        \\    const repeated = [_]u8{ N, 6 } ** 3;
        \\    return if (joined[2] == 3 and repeated[4] == N)
        \\        struct { composed: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(2) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "composed", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with comptime compound assignments" {
    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    var capacity = base;
        \\    capacity += 2;
        \\    capacity *= 3;
        \\    return struct { items: [capacity]u8 };
        \\}
        \\const buffer: Buffer(4) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[18]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    var dimensions: [2]usize = undefined;
        \\    dimensions[0] = base;
        \\    dimensions[1] = 2;
        \\    dimensions[0] += 1;
        \\    dimensions[1] *= 3;
        \\    return struct { items: [dimensions[0] * dimensions[1]]u8 };
        \\}
        \\const buffer: Buffer(4) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[30]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    var dimensions = [_]usize{ 1, 2 };
        \\    dimensions[0] += base;
        \\    dimensions[1] *= 3;
        \\    return struct { items: [dimensions[0] * dimensions[1]]u8 };
        \\}
        \\const buffer: Buffer(4) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[30]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    var dimensions = [_]usize{ 1, 2 };
        \\    var dimensions_ptr = &dimensions;
        \\    dimensions_ptr[0] += base;
        \\    dimensions_ptr[1] *= 3;
        \\    return struct { items: [dimensions[0] * dimensions[1]]u8 };
        \\}
        \\const buffer: Buffer(4) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[30]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    var dimensions = [_]usize{ 1, 2 };
        \\    const dimensions_ptr = &dimensions;
        \\    dimensions_ptr.*[0] += base;
        \\    dimensions_ptr.*[1] *= 3;
        \\    return struct { items: [dimensions[0] * dimensions[1]]u8 };
        \\}
        \\const buffer: Buffer(4) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[30]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    var capacity = base;
        \\    for ([_]usize{ 2, 3 }) |factor| capacity *= factor;
        \\    return struct { items: [capacity]u8 };
        \\}
        \\const buffer: Buffer(4) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[24]u8" },
    });

    try testCompletion(
        \\fn Select() type {
        \\    var value: u8 = 10;
        \\    value -= 2;
        \\    value *= 3;
        \\    value /= 4;
        \\    value %= 4;
        \\    value <<= 2;
        \\    value >>= 1;
        \\    value |= 8;
        \\    value ^= 4;
        \\    value &= 10;
        \\    var wrapping: u8 = 255;
        \\    wrapping +%= 2;
        \\    wrapping -%= 2;
        \\    wrapping *%= 2;
        \\    var saturating: u8 = 250;
        \\    saturating +|= 10;
        \\    saturating -|= 250;
        \\    saturating *|= 100;
        \\    saturating <<|= 1;
        \\    return if (value == 8 and wrapping == 254 and saturating == 255)
        \\        struct { selected: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "u8" },
    });
}

test "comptime interpreter evaluates compound assignment targets once" {
    const cases = [_]struct { operator: []const u8, initial: u8, operand: u8, expected: []const u8 }{
        .{ .operator = "+=", .initial = 4, .operand = 2, .expected = "[6]u8" },
        .{ .operator = "-=", .initial = 4, .operand = 2, .expected = "[2]u8" },
        .{ .operator = "*=", .initial = 4, .operand = 2, .expected = "[8]u8" },
        .{ .operator = "/=", .initial = 4, .operand = 2, .expected = "[2]u8" },
        .{ .operator = "%=", .initial = 5, .operand = 2, .expected = "[1]u8" },
        .{ .operator = "&=", .initial = 6, .operand = 3, .expected = "[2]u8" },
        .{ .operator = "|=", .initial = 4, .operand = 2, .expected = "[6]u8" },
        .{ .operator = "^=", .initial = 6, .operand = 2, .expected = "[4]u8" },
        .{ .operator = "+%=", .initial = 255, .operand = 2, .expected = "[1]u8" },
        .{ .operator = "-%=", .initial = 1, .operand = 2, .expected = "[255]u8" },
        .{ .operator = "*%=", .initial = 128, .operand = 2, .expected = "[0]u8" },
        .{ .operator = "+|=", .initial = 254, .operand = 2, .expected = "[255]u8" },
        .{ .operator = "-|=", .initial = 1, .operand = 2, .expected = "[0]u8" },
        .{ .operator = "*|=", .initial = 128, .operand = 2, .expected = "[255]u8" },
        .{ .operator = "<<=", .initial = 3, .operand = 1, .expected = "[6]u8" },
        .{ .operator = ">>=", .initial = 6, .operand = 1, .expected = "[3]u8" },
        .{ .operator = "<<|=", .initial = 128, .operand = 1, .expected = "[255]u8" },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(allocator,
            \\fn Select() type {{
            \\    var values: [1][2]u8 = .{{.{{ {d}, 7 }}}};
            \\    var order: usize = 0;
            \\    values[row: {{ order += 1; break :row 0; }}][column: {{
            \\        order = order * 10 + 2;
            \\        break :column 0;
            \\    }}] {s} operand: {{
            \\        order = order * 10 + 3;
            \\        break :operand {d};
            \\    }};
            \\    return struct {{ items: [values[0][0]]u8, sibling: [values[0][1]]u8, order: [order]u8 }};
            \\}}
            \\const selected: Select() = undefined;
            \\const field = selected.<cursor>
        , .{ case.initial, case.operator, case.operand });
        defer allocator.free(source);
        errdefer std.debug.print("compound assignment source:\n{s}\n", .{source});
        try testCompletion(source, &.{
            .{ .label = "items", .kind = .Field, .detail = case.expected },
            .{ .label = "sibling", .kind = .Field, .detail = "[7]u8" },
            .{ .label = "order", .kind = .Field, .detail = "[123]u8" },
        });
    }
}

test "comptime interpreter snapshots compound assignment operands" {
    try testCompletion(
        \\fn Select() type {
        \\    var values: [2]u8 = .{ 4, 7 };
        \\    var index: usize = 0;
        \\    values[index] += operand: {
        \\        index = 1;
        \\        values[0] = 20;
        \\        break :operand 2;
        \\    };
        \\    var pointer = &values[0];
        \\    pointer.* *= operand: {
        \\        pointer = &values[1];
        \\        break :operand 2;
        \\    };
        \\    const pointed = pointer.*;
        \\    return struct { items: [values[0]]u8, sibling: [values[1]]u8, pointer: [pointed]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[12]u8" },
        .{ .label = "sibling", .kind = .Field, .detail = "[7]u8" },
        .{ .label = "pointer", .kind = .Field, .detail = "[7]u8" },
    });
}

test "comptime interpreter propagates compound assignment operand types" {
    try testCompletion(
        \\fn Select() type {
        \\    var value: u8 = 4;
        \\    var order: usize = 0;
        \\    value += if (true) @intCast(operand: {
        \\        order += 1;
        \\        break :operand @as(u16, 2);
        \\    }) else unreachable;
        \\    value <<= @intCast(operand: {
        \\        order = order * 10 + 2;
        \\        break :operand @as(u8, 1);
        \\    });
        \\    var lanes: @Vector(2, u8) = .{ 2, 3 };
        \\    lanes += @splat(@as(u16, 2));
        \\    lanes <<= @splat(@as(u8, 1));
        \\    return struct { items: [value + lanes[0] + lanes[1]]u8, order: [order]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[30]u8" },
        .{ .label = "order", .kind = .Field, .detail = "[12]u8" },
    });
}

test "comptime interpreter preserves compound vector lane knowledge" {
    try testCompletion(
        \\var runtime: u8 = undefined;
        \\fn Select() type {
        \\    var values: @Vector(2, u8) = .{ runtime, 4 };
        \\    values += .{ 1, 2 };
        \\    values <<= @splat(@as(u8, 1));
        \\    var saturated: @Vector(2, u8) = .{ 128, 1 };
        \\    saturated <<|= @as(@Vector(2, u8), .{ 8, 9 });
        \\    var flags: @Vector(2, bool) = .{ true, false };
        \\    flags ^= .{ true, true };
        \\    var float: f32 = 1.5;
        \\    float += @floatCast(@as(f64, 2.5));
        \\    return struct {
        \\        unknown: [values[0]]u8,
        \\        known: [values[1]]u8,
        \\        saturated_first: [saturated[0]]u8,
        \\        saturated_second: [saturated[1]]u8,
        \\        flags: [if (!flags[0] and flags[1]) 1 else 99]u8,
        \\        float: [if (@TypeOf(float) == f32 and float == 4.0) 1 else 99]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "unknown", .kind = .Field, .detail = "[?]u8" },
        .{ .label = "known", .kind = .Field, .detail = "[12]u8" },
        .{ .label = "saturated_first", .kind = .Field, .detail = "[255]u8" },
        .{ .label = "saturated_second", .kind = .Field, .detail = "[255]u8" },
        .{ .label = "flags", .kind = .Field, .detail = "[1]u8" },
        .{ .label = "float", .kind = .Field, .detail = "[1]u8" },
    });
}

test "comptime interpreter rejects invalid compound operands" {
    const assignments = [_][]const u8{
        "value += @intCast(@as(u16, 256));",
        "value += true;",
        "value <<= @intCast(@as(u8, 8));",
        "value >>= @as(u8, 8);",
        "value <<|= @intCast(@as(u16, 8));",
    };
    for (assignments) |assignment| {
        const source = try std.fmt.allocPrint(allocator,
            \\fn invalid() u8 {{
            \\    var value: u8 = 4;
            \\    {s}
            \\    return value;
            \\}}
            \\fn Select() type {{
            \\    var marker: usize = 0;
            \\    marker += 1;
            \\    const value = invalid();
            \\    return struct {{ items: [value]u8, value: @TypeOf(value) }};
            \\}}
            \\const selected: Select() = undefined;
            \\const field = selected.<cursor>
        , .{assignment});
        defer allocator.free(source);
        errdefer std.debug.print("invalid compound assignment: {s}\n", .{assignment});
        try testCompletion(source, &.{
            .{ .label = "items", .kind = .Field, .detail = "[?]u8" },
            .{ .label = "value", .kind = .Field, .detail = "u8" },
        });
    }
}

test "comptime interpreter saturates oversized compound shifts" {
    try testCompletion(
        \\fn Select() type {
        \\    var positive: i8 = 1;
        \\    var negative: i8 = -1;
        \\    var zero: u8 = 0;
        \\    var wide: u256 = 1;
        \\    positive <<|= 8;
        \\    negative <<|= 9;
        \\    zero <<|= 100;
        \\    wide <<|= 256;
        \\    return struct {
        \\        positive: [if (positive == 127) 1 else 99]u8,
        \\        negative: [if (negative == -128) 1 else 99]u8,
        \\        zero: [zero]u8,
        \\        wide: [if (wide == ~@as(u256, 0)) 1 else 99]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "positive", .kind = .Field, .detail = "[1]u8" },
        .{ .label = "negative", .kind = .Field, .detail = "[1]u8" },
        .{ .label = "zero", .kind = .Field, .detail = "[0]u8" },
        .{ .label = "wide", .kind = .Field, .detail = "[1]u8" },
    });
}

test "generic function with partially known array concatenation" {
    try testCompletion(
        \\var runtime: [2]u8 = undefined;
        \\fn Select(comptime N: u8) type {
        \\    const runtime_lhs = runtime ++ [2]u8{ N, N + 1 };
        \\    const runtime_rhs = [2]u8{ N + 2, N + 3 } ++ runtime;
        \\    return if (runtime_lhs[2] == 4 and runtime_lhs[3] == 5 and
        \\        runtime_rhs[0] == 6 and runtime_rhs[1] == 7)
        \\        struct { concatenated: [N]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "concatenated", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with peer-typed array concatenation" {
    try testCompletion(
        \\fn Select(comptime N: u8) type {
        \\    const joined = [_]u8{ 1, N } ++ [_]u16{ 300, 400 };
        \\    return if (@TypeOf(joined) == [4]u16 and joined[0] == 1 and
        \\        joined[1] == N and joined[2] == 300)
        \\        struct { concatenated: [N]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "concatenated", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with comptime splat value" {
    try testCompletion(
        \\fn Select(comptime N: u8) type {
        \\    const values: @Vector(4, u8) = @splat(N);
        \\    return if (values[3] == 7)
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(7) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with nested comptime splat mutation" {
    try testCompletion(
        \\fn Select(comptime value: u8) type {
        \\    var total: usize = 1;
        \\    const values = @as(@Vector(4, u8), @splat(scalar: {
        \\        total *= 2;
        \\        break :scalar value;
        \\    }));
        \\    return if (values[3] == 7)
        \\        struct { order: [total]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(7) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "order", .kind = .Field, .detail = "[2]u8" },
    });
}

test "generic function preserves runtime unknown comptime splat type" {
    try testCompletion(
        \\var runtime_u8: u8 = undefined;
        \\fn Select() type {
        \\    var total: usize = 1;
        \\    const values = @as(@Vector(4, u8), @splat(scalar: {
        \\        total += 1;
        \\        break :scalar runtime_u8;
        \\    }));
        \\    return struct {
        \\        value: @TypeOf(values),
        \\        items: [total]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[2]u8" },
        .{ .label = "value", .kind = .Field, .detail = "@Vector(4,u8)" },
    });
}

test "generic function with comptime integer and boolean reductions" {
    try testCompletion(
        \\fn Select(comptime N: u8) type {
        \\    const integers: @Vector(4, u8) = @splat(N);
        \\    const truths: @Vector(3, bool) = @splat(true);
        \\    const falses: @Vector(3, bool) = @splat(false);
        \\    return if (@reduce(.Add, integers) == 232 and @reduce(.Mul, @as(@Vector(4, u8), @splat(4))) == 0 and
        \\        @reduce(.And, integers) == N and @reduce(.Or, integers) == N and @reduce(.Xor, integers) == 0 and
        \\        @reduce(.Min, integers) == N and @reduce(.Max, integers) == N and
        \\        @reduce(.And, truths) and !@reduce(.Or, falses) and @reduce(.Xor, truths))
        \\        struct { reduced: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(250) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "reduced", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with partially known boolean reductions" {
    try testCompletion(
        \\var runtime: bool = undefined;
        \\fn Select(comptime N: u8) type {
        \\    const values: @Vector(3, bool) = .{ runtime, false, true };
        \\    return if (!@reduce(.And, values) and @reduce(.Or, values))
        \\        struct { reduced: [N]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "reduced", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with partially known integer reductions" {
    try testCompletion(
        \\var runtime: u8 = undefined;
        \\fn Select(comptime N: u8) type {
        \\    const multiplied = @reduce(.Mul, @as(@Vector(3, u8), .{ runtime, 0, N }));
        \\    const masked = @reduce(.And, @as(@Vector(3, u8), .{ runtime, 0, N }));
        \\    return if (multiplied == 0 and masked == 0)
        \\        struct { reduced: [N]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "reduced", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with even runtime splat xor reductions" {
    try testCompletion(
        \\var runtime_u8: u8 = undefined;
        \\var runtime_bool: bool = undefined;
        \\fn Select(comptime N: u8) type {
        \\    const integer = @reduce(.Xor, @as(@Vector(4, u8), @splat(runtime_u8)));
        \\    const boolean = @reduce(.Xor, @as(@Vector(4, bool), @splat(runtime_bool)));
        \\    return if (integer == 0 and !boolean)
        \\        struct { reduced: [N]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "reduced", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with integer reduction boundaries" {
    try testCompletion(
        \\var runtime_u8: u8 = undefined;
        \\var runtime_i8: i8 = undefined;
        \\fn Select(comptime N: u8) type {
        \\    const unsigned_or = @reduce(.Or, @as(@Vector(3, u8), .{ runtime_u8, 255, N }));
        \\    const signed_or = @reduce(.Or, @as(@Vector(3, i8), .{ runtime_i8, -1, 0 }));
        \\    const minimum = @reduce(.Min, @as(@Vector(3, i8), .{ runtime_i8, -128, 7 }));
        \\    const maximum = @reduce(.Max, @as(@Vector(3, i8), .{ runtime_i8, 127, -7 }));
        \\    return if (unsigned_or == 255 and signed_or == -1 and minimum == -128 and maximum == 127)
        \\        struct { reduced: [N]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "reduced", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with comptime float reductions" {
    try testCompletion(
        \\fn Select(comptime value: f32) type {
        \\    const values: @Vector(4, f32) = @splat(value);
        \\    return if (@reduce(.Add, values) == 10 and
        \\        @reduce(.Mul, @as(@Vector(3, f64), @splat(-2.0))) == -8 and
        \\        @reduce(.Min, @as(@Vector(2, f32), .{ 0.0, -0.0 })) == -0.0 and
        \\        @reduce(.Max, @as(@Vector(2, f64), .{ -0.0, 0.0 })) == 0.0)
        \\        struct { reduced: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(2.5) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "reduced", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with comptime vector float builtins" {
    try testCompletion(
        \\fn Select(comptime value: f32) type {
        \\    const values: @Vector(2, f32) = @splat(value);
        \\    const negative_values: @Vector(2, f32) = @splat(-value);
        \\    return if (@sqrt(@as(@Vector(2, f32), @splat(9.0)))[0] == 3 and
        \\        @sin(@as(@Vector(2, f32), @splat(0.0)))[1] == 0 and @cos(@as(@Vector(2, f32), @splat(0.0)))[0] == 1 and
        \\        @tan(@as(@Vector(2, f32), @splat(0.0)))[1] == 0 and @exp(@as(@Vector(2, f32), @splat(0.0)))[0] == 1 and
        \\        @exp2(@as(@Vector(2, f32), @splat(3.0)))[1] == 8 and @log(@as(@Vector(2, f32), @splat(1.0)))[0] == 0 and
        \\        @log2(@as(@Vector(2, f32), @splat(8.0)))[1] == 3 and @log10(@as(@Vector(2, f32), @splat(100.0)))[0] == 2 and
        \\        @abs(negative_values)[0] == 2.5 and @floor(negative_values)[1] == -3 and @ceil(negative_values)[0] == -2 and
        \\        @trunc(negative_values)[1] == -2 and @round(negative_values)[0] == -3)
        \\        struct { evaluated: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(2.5) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "evaluated", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with comptime vector numeric casts" {
    try testCompletion(
        \\fn Select(comptime N: i16) type {
        \\    const ints: @Vector(2, i8) = @intFromFloat(@as(@Vector(2, f32), .{ -2.75, 4.5 }));
        \\    const floats: @Vector(2, f32) = @floatFromInt(@as(@Vector(2, i16), .{ N, 5 }));
        \\    const narrowed: @Vector(2, f16) = @floatCast(@as(@Vector(2, f32), .{ 2.5, 4.5 }));
        \\    const casted: @Vector(2, u8) = @intCast(@as(@Vector(2, u16), .{ 4, 7 }));
        \\    const truncated: @Vector(2, u8) = @truncate(@as(@Vector(2, u16), .{ 0x104, 0x107 }));
        \\    return if (ints[0] == -2 and ints[1] == 4 and floats[0] == -3 and floats[1] == 5 and
        \\        narrowed[0] == 2.5 and narrowed[1] == 4.5 and casted[0] == 4 and casted[1] == 7 and
        \\        truncated[0] == 4 and truncated[1] == 7)
        \\        struct { converted: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(-3) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "converted", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with comptime vector bit builtins" {
    try testCompletion(
        \\fn Select(comptime N: u8) type {
        \\    const values: @Vector(2, u8) = .{ N, 1 };
        \\    const signed: @Vector(2, i8) = .{ -16, 1 };
        \\    const words: @Vector(2, u16) = .{ 0x1234, 0xabcd };
        \\    return if (@clz(values)[0] == 2 and @ctz(values)[1] == 0 and
        \\        @popCount(signed)[0] == 4 and @bitReverse(values)[1] == 128 and
        \\        @byteSwap(words)[0] == 0x3412)
        \\        struct { evaluated: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(0b00110000) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "evaluated", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with comptime vector select" {
    try testCompletion(
        \\fn Select(comptime N: u8) type {
        \\    const values = @select(
        \\        u8,
        \\        @as(@Vector(4, bool), .{ true, false, true, false }),
        \\        @as(@Vector(4, u8), .{ 1, N, 3, N }),
        \\        @as(@Vector(4, u8), .{ N, 6, N, 8 }),
        \\    );
        \\    return if (values[0] == 1 and values[1] == 6 and values[2] == 3 and values[3] == 8)
        \\        struct { selected: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(42) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\var runtime: u8 = undefined;
        \\fn Select(comptime N: u8) type {
        \\    const values = @select(
        \\        u8,
        \\        @as(@Vector(2, bool), .{ true, false }),
        \\        @as(@Vector(2, u8), .{ N, runtime }),
        \\        @as(@Vector(2, u8), .{ runtime, N + 1 }),
        \\    );
        \\    return if (values[0] == 4 and values[1] == 5)
        \\        struct { selected: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with partially known vector select" {
    try testCompletion(
        \\var runtime_bool: bool = undefined;
        \\var runtime_u8: u8 = undefined;
        \\fn Select(comptime N: u8) type {
        \\    const partial = @select(
        \\        u8,
        \\        @as(@Vector(3, bool), .{ true, false, runtime_bool }),
        \\        @as(@Vector(3, u8), .{ N, runtime_u8, 9 }),
        \\        @as(@Vector(3, u8), .{ runtime_u8, N + 1, 9 }),
        \\    );
        \\    const equal = @select(
        \\        u8,
        \\        @as(@Vector(2, bool), @splat(runtime_bool)),
        \\        @as(@Vector(2, u8), @splat(N + 2)),
        \\        @as(@Vector(2, u8), @splat(N + 2)),
        \\    );
        \\    const runtime_lhs = @select(
        \\        u8,
        \\        @as(@Vector(2, bool), .{ false, true }),
        \\        @as(@Vector(2, u8), @splat(runtime_u8)),
        \\        @as(@Vector(2, u8), .{ N + 3, N + 4 }),
        \\    );
        \\    return if (partial[0] == 4 and partial[1] == 5 and partial[2] == 9 and
        \\        equal[0] == 6 and runtime_lhs[0] == 7)
        \\        struct { selected: [N]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with comptime vector arithmetic" {
    try testCompletion(
        \\fn Select(comptime N: u8) type {
        \\    const lhs: @Vector(4, u8) = @splat(N);
        \\    const rhs: @Vector(4, u8) = @splat(2);
        \\    const sum = lhs + rhs;
        \\    const difference = lhs - rhs;
        \\    const product = lhs * rhs;
        \\    const quotient = lhs / rhs;
        \\    const remainder = lhs % @as(@Vector(4, u8), @splat(3));
        \\    const float_quotient = @as(@Vector(2, f32), .{ 8.0, 5.0 }) / @as(@Vector(2, f32), @splat(2.0));
        \\    return if (sum[0] == 6 and @reduce(.Add, sum) == 24 and difference[1] == 2 and
        \\        product[2] == 8 and quotient[3] == 2 and remainder[0] == 1 and float_quotient[1] == 2.5)
        \\        struct { vector: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "vector", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with comptime vector unary operators" {
    try testCompletion(
        \\fn Select(comptime N: i8) type {
        \\    const signed: @Vector(2, i8) = .{ N, -128 };
        \\    const unsigned: @Vector(2, u8) = .{ 1, 2 };
        \\    const floats: @Vector(2, f32) = .{ 2.5, -4.5 };
        \\    return if (@abs(signed)[0] == 4 and @abs(signed)[1] == 128 and
        \\        (-signed)[0] == 4 and (-%signed)[1] == -128 and
        \\        (~unsigned)[0] == 254 and (-floats)[1] == 4.5)
        \\        struct { evaluated: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(-4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "evaluated", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with comptime wide integer unary operators" {
    try testCompletion(
        \\fn Select(comptime N: i256) type {
        \\    return if (@ctz(~@as(u256, 1)) == 1 and
        \\        ~@as(i256, -8) == 7 and -N == -4 and
        \\        @popCount(-%@as(u256, 1)) == 256)
        \\        struct { evaluated: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "evaluated", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with comptime wide integer bitwise operations" {
    try testCompletion(
        \\fn Select(comptime N: u256) type {
        \\    const high = N | @as(u256, 57896044618658097711785492504343953926634992332820282019728792003956564819968);
        \\    return if (@ctz(high & (high | 2)) == 0 and
        \\        @popCount(high ^ 3) == 2 and (@as(i256, -8) | 3) == -5)
        \\        struct { evaluated: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(1) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "evaluated", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with comptime vector wrapping and saturating arithmetic" {
    try testCompletion(
        \\fn Select(comptime N: u8) type {
        \\    const value: @Vector(2, u8) = @splat(N);
        \\    const one: @Vector(2, u8) = @splat(1);
        \\    const two: @Vector(2, u8) = @splat(2);
        \\    const signed_max: @Vector(2, i8) = @splat(127);
        \\    const signed_two: @Vector(2, i8) = @splat(2);
        \\    const shifts: @Vector(2, u3) = @splat(2);
        \\    return if ((value +% one)[0] == 0 and (value +| one)[1] == 255 and
        \\        (one -% two)[0] == 255 and (one -| two)[1] == 0 and
        \\        (signed_max *% signed_two)[0] == -2 and (signed_max *| signed_two)[1] == 127 and
        \\        (@as(@Vector(2, u8), @splat(0x40)) <<| shifts)[0] == 255)
        \\        struct { evaluated: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(255) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "evaluated", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with partially known vector wrapping and saturating arithmetic" {
    try testCompletion(
        \\var runtime: @Vector(2, u8) = undefined;
        \\fn Select(comptime N: u8) type {
        \\    const zeros: @Vector(2, u8) = @splat(0);
        \\    const maximums: @Vector(2, u8) = @splat(255);
        \\    return if ((runtime *% zeros)[0] == 0 and (runtime *| zeros)[1] == 0 and
        \\        (runtime +| maximums)[0] == 255 and (zeros -| runtime)[1] == 0)
        \\        struct { evaluated: [N]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "evaluated", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with comptime vector shifts" {
    try testCompletion(
        \\fn Select(comptime N: u8) type {
        \\    const values: @Vector(2, u8) = .{ N, 12 };
        \\    const signed: @Vector(2, i8) = .{ -4, -12 };
        \\    const shifts: @Vector(2, u3) = @splat(2);
        \\    const exact: @Vector(2, u8) = .{ 4, 12 };
        \\    return if ((values << shifts)[0] == 12 and (signed >> shifts)[0] == -1 and
        \\        @shlExact(exact, shifts)[0] == 16 and @shrExact(exact, shifts)[1] == 3)
        \\        struct { shifted: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(3) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "shifted", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with partially known zero shifts" {
    try testCompletion(
        \\var shift: u3 = undefined;
        \\var shifts: @Vector(2, u3) = undefined;
        \\fn Select(comptime N: u8) type {
        \\    const zero: @Vector(2, u8) = @splat(0);
        \\    const ones: @Vector(2, i8) = @splat(-1);
        \\    return if ((@as(u8, 0) << shift) == 0 and (@as(u8, 0) >> shift) == 0 and
        \\        (@as(i8, -1) >> shift) == -1 and
        \\        (@as(u8, 0) <<| shift) == 0 and @shlExact(@as(u8, 0), shift) == 0 and
        \\        @shrExact(@as(u8, 0), shift) == 0 and @reduce(.And, (zero << shifts) == zero) and
        \\        @reduce(.And, (zero >> shifts) == zero) and @reduce(.And, (ones >> shifts) == ones) and
        \\        @reduce(.And, (zero <<| shifts) == zero) and
        \\        @reduce(.And, @shlExact(zero, shifts) == zero) and @reduce(.And, @shrExact(zero, shifts) == zero))
        \\        struct { shifted: [N]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "shifted", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with comptime boolean vector operators" {
    try testCompletion(
        \\fn Select(comptime enabled: bool) type {
        \\    const a: @Vector(2, bool) = .{ enabled, false };
        \\    const b: @Vector(2, bool) = .{ true, true };
        \\    return if ((a & b)[0] and (a | b)[1] and !(a ^ b)[0] and (!a)[1] and
        \\        @reduce(.And, a == @as(@Vector(2, bool), .{ true, false })))
        \\        struct { evaluated: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(true) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "evaluated", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with partially known boolean vector operators" {
    try testCompletion(
        \\var runtime: bool = undefined;
        \\fn Select(comptime N: u8) type {
        \\    const values: @Vector(2, bool) = @splat(runtime);
        \\    const falses: @Vector(2, bool) = @splat(false);
        \\    const truths: @Vector(2, bool) = @splat(true);
        \\    return if (!(values & falses)[0] and (values | truths)[1])
        \\        struct { evaluated: [N]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "evaluated", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with partially known integer vector operations" {
    try testCompletion(
        \\var runtime: @Vector(2, u8) = undefined;
        \\fn Select(comptime N: u8) type {
        \\    const zeros: @Vector(2, u8) = @splat(0);
        \\    const ones: @Vector(2, u8) = @splat(255);
        \\    return if ((runtime * zeros)[0] == 0 and (runtime & zeros)[1] == 0 and
        \\        (runtime | ones)[0] == 255)
        \\        struct { evaluated: [N]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "evaluated", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with partially known boolean operators" {
    try testCompletion(
        \\var runtime: bool = undefined;
        \\fn Select(comptime N: u8) type {
        \\    return if (!(runtime and false) and (runtime or true) and
        \\        !(runtime & false) and (runtime | true))
        \\        struct { evaluated: [N]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "evaluated", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with integer comparison boundaries" {
    try testCompletion(
        \\var runtime_u8: u8 = undefined;
        \\var runtime_i8: i8 = undefined;
        \\fn Select(comptime N: u8) type {
        \\    return if (runtime_u8 <= @as(u8, 255) and runtime_u8 >= @as(u8, 0) and
        \\        !(runtime_u8 > @as(u8, 255)) and !(runtime_u8 < @as(u8, 0)) and
        \\        runtime_i8 <= @as(i8, 127) and runtime_i8 >= @as(i8, -128) and
        \\        !(runtime_i8 > @as(i8, 127)) and !(runtime_i8 < @as(i8, -128)))
        \\        struct { bounded: [N]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "bounded", .kind = .Field, .detail = "[4]u8" },
    });

    try testCompletion(
        \\var runtime_u256: u256 = undefined;
        \\var runtime_i256: i256 = undefined;
        \\fn Select(comptime N: u8) type {
        \\    return if (runtime_u256 <= @as(u256, 115792089237316195423570985008687907853269984665640564039457584007913129639935) and
        \\        !(runtime_u256 > @as(u256, 115792089237316195423570985008687907853269984665640564039457584007913129639935)) and runtime_u256 >= @as(u256, 0) and
        \\        runtime_i256 >= @as(i256, -57896044618658097711785492504343953926634992332820282019728792003956564819968) and
        \\        !(runtime_i256 < @as(i256, -57896044618658097711785492504343953926634992332820282019728792003956564819968)) and
        \\        runtime_i256 <= @as(i256, 57896044618658097711785492504343953926634992332820282019728792003956564819967))
        \\        struct { bounded: [N]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "bounded", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with runtime self comparisons" {
    try testCompletion(
        \\var runtime_u8: u8 = undefined;
        \\var runtime_i8: i8 = undefined;
        \\var runtime_bool: bool = undefined;
        \\fn Select(comptime N: u8) type {
        \\    return if (runtime_u8 == runtime_u8 and !(runtime_i8 != runtime_i8) and
        \\        runtime_u8 <= runtime_u8 and !(runtime_i8 > runtime_i8) and
        \\        runtime_bool == runtime_bool)
        \\        struct { matched: [N]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with runtime error and pointer self equality" {
    try testCompletion(
        \\const Failure = error{failed, stopped};
        \\var runtime_failure: Failure = error.failed;
        \\var storage: u8 = 0;
        \\var runtime_pointer: *u8 = &storage;
        \\fn Select(comptime N: u8) type {
        \\    return if (runtime_failure == runtime_failure and !(runtime_failure != runtime_failure) and
        \\        runtime_pointer == runtime_pointer and !(runtime_pointer != runtime_pointer))
        \\        struct { matched: [N]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with runtime enum self equality" {
    try testCompletion(
        \\const Choice = enum { first, second };
        \\var runtime_choice: Choice = .first;
        \\fn Select(comptime N: u8) type {
        \\    return if (runtime_choice == runtime_choice and !(runtime_choice != runtime_choice))
        \\        struct { matched: [N]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with runtime vector self comparisons" {
    try testCompletion(
        \\var runtime: @Vector(2, i8) = undefined;
        \\var runtime_bool: @Vector(2, bool) = undefined;
        \\fn Select(comptime N: u8) type {
        \\    return if (@reduce(.And, runtime == runtime) and
        \\        !@reduce(.Or, runtime != runtime) and
        \\        @reduce(.And, runtime <= runtime) and
        \\        @reduce(.And, runtime >= runtime) and
        \\        !@reduce(.Or, runtime < runtime) and
        \\        !@reduce(.Or, runtime > runtime) and
        \\        @reduce(.And, runtime_bool == runtime_bool) and
        \\        !@reduce(.Or, runtime_bool != runtime_bool))
        \\        struct { matched: [N]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with runtime self integer operations" {
    try testCompletion(
        \\var runtime: i8 = undefined;
        \\fn Select(comptime N: u8) type {
        \\    return if ((runtime ^ runtime) == 0 and (runtime - runtime) == 0 and
        \\        (runtime -% runtime) == 0 and
        \\        (runtime -| runtime) == 0)
        \\        struct { matched: [N]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with runtime vector self integer operations" {
    try testCompletion(
        \\var runtime: @Vector(2, i8) = undefined;
        \\fn Select(comptime N: u8) type {
        \\    const zero: @Vector(2, i8) = @splat(0);
        \\    return if (@reduce(.And, (runtime ^ runtime) == zero) and
        \\        @reduce(.And, (runtime - runtime) == zero) and
        \\        @reduce(.And, (runtime -% runtime) == zero) and
        \\        @reduce(.And, (runtime -| runtime) == zero))
        \\        struct { matched: [N]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with runtime boolean self xor" {
    try testCompletion(
        \\var scalar: bool = undefined;
        \\var vector: @Vector(2, bool) = undefined;
        \\fn Select(comptime N: u8) type {
        \\    return if (!(scalar ^ scalar) and !@reduce(.Or, vector ^ vector))
        \\        struct { matched: [N]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with runtime complement identities" {
    try testCompletion(
        \\var runtime_u8: u8 = undefined;
        \\var runtime_i8: @Vector(2, i8) = undefined;
        \\var runtime_bool: bool = undefined;
        \\var runtime_bools: @Vector(2, bool) = undefined;
        \\fn Select(comptime N: u8) type {
        \\    return if ((runtime_u8 & ~runtime_u8) == 0 and
        \\        (runtime_u8 | ~runtime_u8) == 255 and
        \\        (runtime_u8 + ~runtime_u8) == 255 and
        \\        (runtime_u8 +% ~runtime_u8) == 255 and
        \\        (runtime_u8 +| ~runtime_u8) == 255 and
        \\        @reduce(.And, (runtime_i8 & ~runtime_i8) == @as(@Vector(2, i8), @splat(0))) and
        \\        @reduce(.And, (runtime_i8 ^ ~runtime_i8) == @as(@Vector(2, i8), @splat(-1))) and
        \\        @reduce(.And, (runtime_i8 + ~runtime_i8) == @as(@Vector(2, i8), @splat(-1))) and
        \\        (runtime_bool and !runtime_bool) == false and
        \\        (runtime_bool or !runtime_bool) == true and
        \\        !@reduce(.Or, runtime_bools & !runtime_bools) and
        \\        @reduce(.And, runtime_bools | !runtime_bools))
        \\        struct { matched: [N]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with runtime complement comparisons" {
    try testCompletion(
        \\var runtime_u8: u8 = undefined;
        \\var runtime_i8: @Vector(2, i8) = undefined;
        \\var runtime_bool: bool = undefined;
        \\var runtime_bools: @Vector(2, bool) = undefined;
        \\fn Select(comptime N: u8) type {
        \\    return if (!(runtime_u8 == ~runtime_u8) and runtime_u8 != ~runtime_u8 and
        \\        !@reduce(.Or, runtime_i8 == ~runtime_i8) and
        \\        @reduce(.And, runtime_i8 != ~runtime_i8) and
        \\        !(runtime_bool == !runtime_bool) and runtime_bool != !runtime_bool and
        \\        !@reduce(.Or, runtime_bools == !runtime_bools) and
        \\        @reduce(.And, runtime_bools != !runtime_bools))
        \\        struct { matched: [N]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with partially known integer operations" {
    try testCompletion(
        \\var runtime_u8: u8 = undefined;
        \\var runtime_i8: i8 = undefined;
        \\fn Select(comptime N: u8) type {
        \\    return if (runtime_u8 * @as(u8, 0) == 0 and runtime_u8 & @as(u8, 0) == 0 and
        \\        runtime_u8 | @as(u8, 255) == 255 and runtime_i8 | @as(i8, -1) == -1)
        \\        struct { evaluated: [N]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "evaluated", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with partially known wrapping and saturating integer operations" {
    try testCompletion(
        \\var runtime: u8 = undefined;
        \\fn Select(comptime N: u8) type {
        \\    return if (runtime *% @as(u8, 0) == 0 and runtime *| @as(u8, 0) == 0 and
        \\        runtime +| @as(u8, 255) == 255 and @as(u8, 0) -| runtime == 0)
        \\        struct { evaluated: [N]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "evaluated", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with comptime vector int from bool" {
    try testCompletion(
        \\fn Select(comptime enabled: bool) type {
        \\    const values = @intFromBool(@as(@Vector(3, bool), .{ enabled, false, true }));
        \\    return if (values[0] == 1 and values[1] == 0 and values[2] == 1)
        \\        struct { converted: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(true) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "converted", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with nested comptime intFromBool mutation" {
    try testCompletion(
        \\fn Buffer(comptime enabled: bool) type {
        \\    var total: usize = 1;
        \\    const bit = @intFromBool(value: {
        \\        defer total += 1;
        \\        total *= 2;
        \\        break :value enabled;
        \\    });
        \\    return struct { items: [if (bit == 1) total * 2 else 99]u8 };
        \\}
        \\const buffer: Buffer(true) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[6]u8" },
    });
}

test "generic function with comptime unknown intFromBool types" {
    try testCompletion(
        \\var runtime_bool: bool = undefined;
        \\var runtime_vector: @Vector(2, bool) = undefined;
        \\fn Select() type {
        \\    var total: usize = 0;
        \\    const scalar = @intFromBool(operand: {
        \\        total += 1;
        \\        break :operand runtime_bool;
        \\    });
        \\    const vector = @intFromBool(operand: {
        \\        total += 1;
        \\        break :operand runtime_vector;
        \\    });
        \\    total += 1;
        \\    return struct {
        \\        scalar: @TypeOf(scalar),
        \\        vector: @TypeOf(vector),
        \\        items: [total]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "scalar", .kind = .Field, .detail = "u1" },
        .{ .label = "vector", .kind = .Field, .detail = "@Vector(2,u1)" },
        .{ .label = "items", .kind = .Field, .detail = "[3]u8" },
    });
}

test "generic function with comptime vector comparison" {
    try testCompletion(
        \\fn Select(comptime N: u8) type {
        \\    const lhs: @Vector(4, u8) = .{ 1, N, 3, 4 };
        \\    const rhs: @Vector(4, u8) = .{ 1, 5, 2, 4 };
        \\    return if (!@reduce(.And, lhs == rhs) and @reduce(.Or, lhs < rhs))
        \\        struct { compared: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(2) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "compared", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with comptime wide integer comparison" {
    try testCompletion(
        \\fn Select(comptime value: u256) type {
        \\    return if (value == 115792089237316195423570985008687907853269984665640564039457584007913129639935 and
        \\        value > 57896044618658097711785492504343953926634992332820282019728792003956564819968 and
        \\        @as(i256, -1) < value)
        \\        struct { compared: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(115792089237316195423570985008687907853269984665640564039457584007913129639935) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "compared", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with integer vector comparison boundaries" {
    try testCompletion(
        \\var runtime_u8: @Vector(2, u8) = undefined;
        \\var runtime_i8: @Vector(2, i8) = undefined;
        \\fn Select(comptime N: u8) type {
        \\    const unsigned_max: @Vector(2, u8) = @splat(255);
        \\    const unsigned_min: @Vector(2, u8) = @splat(0);
        \\    const signed_max: @Vector(2, i8) = @splat(127);
        \\    const signed_min: @Vector(2, i8) = @splat(-128);
        \\    return if (@reduce(.And, runtime_u8 <= unsigned_max) and
        \\        !@reduce(.Or, runtime_u8 < unsigned_min) and
        \\        @reduce(.And, runtime_i8 >= signed_min) and
        \\        !@reduce(.Or, runtime_i8 > signed_max))
        \\        struct { bounded: [N]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "bounded", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with comptime vector shuffle" {
    try testCompletion(
        \\fn Select(comptime N: u8) type {
        \\    const a: @Vector(2, u8) = .{ 1, N };
        \\    const b: @Vector(2, u8) = .{ 3, 4 };
        \\    const values = @shuffle(u8, a, b, @Vector(3, i32){ 1, -1, -2 });
        \\    return if (values[0] == 2 and values[1] == 3 and values[2] == 4)
        \\        struct { shuffled: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(2) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "shuffled", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with partially known vector shuffle" {
    try testCompletion(
        \\var runtime: u8 = undefined;
        \\fn Select(comptime N: u8) type {
        \\    const runtime_lhs = @shuffle(
        \\        u8,
        \\        @as(@Vector(2, u8), @splat(runtime)),
        \\        @as(@Vector(2, u8), .{ N, N + 1 }),
        \\        @Vector(2, i32){ -1, -2 },
        \\    );
        \\    const runtime_rhs = @shuffle(
        \\        u8,
        \\        @as(@Vector(2, u8), .{ N + 2, N + 3 }),
        \\        @as(@Vector(2, u8), @splat(runtime)),
        \\        @Vector(2, i32){ 0, 1 },
        \\    );
        \\    return if (runtime_lhs[0] == 4 and runtime_lhs[1] == 5 and
        \\        runtime_rhs[0] == 6 and runtime_rhs[1] == 7)
        \\        struct { shuffled: [N]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "shuffled", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with comptime overflow builtins" {
    try testCompletion(
        \\fn Select(comptime value: u8) type {
        \\    const add = @addWithOverflow(value, 10);
        \\    const sub = @subWithOverflow(@as(u8, 2), 3);
        \\    const mul = @mulWithOverflow(@as(i8, 40), 4);
        \\    const shl = @shlWithOverflow(@as(u8, 0x40), 2);
        \\    const no_overflow = @addWithOverflow(@as(u8, 2), 3);
        \\    return if (add[0] == 4 and add[1] == 1 and sub[0] == 255 and sub[1] == 1 and
        \\        mul[0] == -96 and mul[1] == 1 and shl[0] == 0 and shl[1] == 1 and
        \\        no_overflow[0] == 5 and no_overflow[1] == 0)
        \\        struct { overflowed: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(250) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "overflowed", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime value: u128) type {
        \\    const result = @addWithOverflow(value, 1);
        \\    return if (result[0] == 0 and result[1] == 1)
        \\        struct { wide: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(340282366920938463463374607431768211455) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "wide", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with nested comptime overflow mutations" {
    try testCompletion(
        \\fn Select() type {
        \\    var add_total: usize = 1;
        \\    var sub_total: usize = 1;
        \\    var mul_total: usize = 1;
        \\    var shl_total: usize = 1;
        \\    const add = @addWithOverflow(lhs: { add_total += 1; break :lhs @as(u8, 250); }, rhs: { add_total *= 2; break :rhs 10; });
        \\    const sub = @subWithOverflow(lhs: { sub_total += 1; break :lhs @as(u8, 2); }, rhs: { sub_total *= 2; break :rhs 3; });
        \\    const mul = @mulWithOverflow(lhs: { mul_total += 1; break :lhs @as(i8, 40); }, rhs: { mul_total *= 2; break :rhs 4; });
        \\    const shl = @shlWithOverflow(lhs: { shl_total += 1; break :lhs @as(u8, 0x40); }, rhs: { shl_total *= 2; break :rhs 2; });
        \\    return if (add[0] == 4 and add[1] == 1 and sub[0] == 255 and sub[1] == 1 and
        \\        mul[0] == -96 and mul[1] == 1 and shl[0] == 0 and shl[1] == 1)
        \\        struct {
        \\            add_order: [add_total]u8,
        \\            sub_order: [sub_total]u8,
        \\            mul_order: [mul_total]u8,
        \\            shl_order: [shl_total]u8,
        \\        }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "add_order", .kind = .Field, .detail = "[4]u8" },
        .{ .label = "sub_order", .kind = .Field, .detail = "[4]u8" },
        .{ .label = "mul_order", .kind = .Field, .detail = "[4]u8" },
        .{ .label = "shl_order", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with comptime overflow identities" {
    try testCompletion(
        \\var runtime_u8: u8 = undefined;
        \\var runtime_i8: i8 = undefined;
        \\fn Select() type {
        \\    var total: usize = 1;
        \\    total += 1;
        \\    const self_sub = @subWithOverflow(runtime_u8, runtime_u8);
        \\    const unsigned_complement = @addWithOverflow(runtime_u8, ~runtime_u8);
        \\    const signed_complement = @addWithOverflow(runtime_i8, ~runtime_i8);
        \\    return if (self_sub[0] == 0 and self_sub[1] == 0 and
        \\        unsigned_complement[0] == 255 and unsigned_complement[1] == 0 and
        \\        signed_complement[0] == -1 and signed_complement[1] == 0)
        \\        struct { identities: [total]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "identities", .kind = .Field, .detail = "[2]u8" },
    });
}

test "generic function with comptime runtime binary identities" {
    try testCompletion(
        \\var runtime_u8: u8 = undefined;
        \\var runtime_i8: i8 = undefined;
        \\var runtime_vector: @Vector(2, u8) = undefined;
        \\var runtime_bool: bool = undefined;
        \\var runtime_bools: @Vector(2, bool) = undefined;
        \\fn Select() type {
        \\    var total: usize = 1;
        \\    total += 1;
        \\    const vector_zero = runtime_vector ^ runtime_vector;
        \\    const vector_ones = runtime_vector | ~runtime_vector;
        \\    const vector_truth = runtime_bools | !runtime_bools;
        \\    return if (runtime_u8 - runtime_u8 == 0 and
        \\        runtime_u8 ^ runtime_u8 == 0 and runtime_u8 & ~runtime_u8 == 0 and
        \\        runtime_u8 | ~runtime_u8 == 255 and runtime_u8 + ~runtime_u8 == 255 and
        \\        runtime_i8 + ~runtime_i8 == -1 and runtime_u8 -% runtime_u8 == 0 and
        \\        runtime_u8 -| runtime_u8 == 0 and vector_zero[0] == 0 and
        \\        vector_ones[1] == 255 and runtime_bool ^ !runtime_bool and vector_truth[0])
        \\        struct { identities: [total]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "identities", .kind = .Field, .detail = "[2]u8" },
    });
}

test "generic function with comptime unknown negation types" {
    try testCompletion(
        \\var runtime_i8: i8 = undefined;
        \\var runtime_u8: u8 = undefined;
        \\var runtime_f32: f32 = undefined;
        \\var runtime_i8_vector: @Vector(2, i8) = undefined;
        \\var runtime_u8_vector: @Vector(2, u8) = undefined;
        \\var runtime_f32_vector: @Vector(2, f32) = undefined;
        \\fn Select() type {
        \\    var total: usize = 1;
        \\    total += 1;
        \\    const negated = -runtime_i8;
        \\    const wrapped = -%runtime_u8;
        \\    const negated_float = -runtime_f32;
        \\    const negated_vector = -runtime_i8_vector;
        \\    const wrapped_vector = -%runtime_u8_vector;
        \\    const negated_float_vector = -runtime_f32_vector;
        \\    total += 1;
        \\    return struct {
        \\        signed: @TypeOf(negated),
        \\        unsigned: @TypeOf(wrapped),
        \\        float: @TypeOf(negated_float),
        \\        signed_vector: @TypeOf(negated_vector),
        \\        unsigned_vector: @TypeOf(wrapped_vector),
        \\        float_vector: @TypeOf(negated_float_vector),
        \\        items: [total]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "signed", .kind = .Field, .detail = "i8" },
        .{ .label = "unsigned", .kind = .Field, .detail = "u8" },
        .{ .label = "float", .kind = .Field, .detail = "f32" },
        .{ .label = "signed_vector", .kind = .Field, .detail = "@Vector(2,i8)" },
        .{ .label = "unsigned_vector", .kind = .Field, .detail = "@Vector(2,u8)" },
        .{ .label = "float_vector", .kind = .Field, .detail = "@Vector(2,f32)" },
        .{ .label = "items", .kind = .Field, .detail = "[3]u8" },
    });
}

test "generic function with partially known overflow builtins" {
    try testCompletion(
        \\var runtime_u8: u8 = undefined;
        \\var runtime_i8: i8 = undefined;
        \\var runtime_u3: u3 = undefined;
        \\fn Select(comptime N: u8) type {
        \\    const add = @addWithOverflow(runtime_u8, @as(u8, 0));
        \\    const complement_add = @addWithOverflow(runtime_u8, ~runtime_u8);
        \\    const sub = @subWithOverflow(runtime_u8, @as(u8, 0));
        \\    const self_sub = @subWithOverflow(runtime_u8, runtime_u8);
        \\    const mul_zero = @mulWithOverflow(runtime_i8, @as(i8, 0));
        \\    const mul_one = @mulWithOverflow(runtime_i8, @as(i8, 1));
        \\    const shl = @shlWithOverflow(runtime_u8, @as(u3, 0));
        \\    const zero_shl = @shlWithOverflow(@as(u8, 0), runtime_u3);
        \\    return if (add[1] == 0 and complement_add[0] == 255 and complement_add[1] == 0 and
        \\        sub[1] == 0 and self_sub[0] == 0 and
        \\        self_sub[1] == 0 and mul_zero[0] == 0 and
        \\        mul_zero[1] == 0 and mul_one[1] == 0 and shl[1] == 0 and
        \\        zero_shl[0] == 0 and zero_shl[1] == 0)
        \\        struct { checked: [N]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "checked", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with comptime integer expressions" {
    const cases = [_][]const u8{
        "N + 2 == 8",
        "N - 2 == 4",
        "N * 2 == 12",
        "N / 2 == 3",
        "N % 4 == 2",
        "(N & 3) == 2",
        "(N ^ 3) == 5",
        "(N | 1) == 7",
        "(N << 1) == 12",
        "(N >> 1) == 3",
        "N != 5",
        "N < 7",
        "N <= 6",
        "N > 5",
        "N >= 6",
        "!(N == 5)",
    };
    for (cases) |condition| {
        const source = try std.fmt.allocPrint(allocator,
            \\fn Select(comptime N: usize) type {{
            \\    return if ({s})
            \\        struct {{ matched: u8 }}
            \\    else
            \\        struct {{ unmatched: u8 }};
            \\}}
            \\const selected: Select(6) = undefined;
            \\const field = selected.<cursor>
        , .{condition});
        defer allocator.free(source);
        try testCompletion(source, &.{
            .{ .label = "matched", .kind = .Field, .detail = "u8" },
        });
    }
}

test "generic function with full-width comptime integer expressions" {
    try testCompletion(
        \\fn Select(comptime N: u256) type {
        \\    return if (N + 5 == 28948022309329048855892746252171976963317496166410141009864396001978282409989 and
        \\        N - 5 == 28948022309329048855892746252171976963317496166410141009864396001978282409979 and
        \\        N * 3 == 86844066927987146567678238756515930889952488499230423029593188005934847229952)
        \\        struct { wide: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(28948022309329048855892746252171976963317496166410141009864396001978282409984) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "wide", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime N: u256) type {
        \\    return if (N << 255 == 57896044618658097711785492504343953926634992332820282019728792003956564819968 and
        \\        @as(u256, 115792089237316195423570985008687907853269984665640564039457584007913129639935) >> 200 == 72057594037927935 and
        \\        @as(i512, -2037035976334486086268445688409378161051468393665936250636140449354381299763336706183397376) >> 300 == -1)
        \\        struct { shifted: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(1) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "shifted", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime N: u128) type {
        \\    return if (N + 5 == 170141183460469231731687303715884105733 and
        \\        N - 5 == 170141183460469231731687303715884105723 and
        \\        N * 1 == 170141183460469231731687303715884105728 and
        \\        N / 2 == 85070591730234615865843651857942052864 and
        \\        N % 7 == 2 and (N | 3) == 170141183460469231731687303715884105731)
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(170141183460469231731687303715884105728) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime N: u128) type {
        \\    return if (@shlExact(N, 1) == 170141183460469231731687303715884105728 and
        \\        @shrExact(N, 126) == 1)
        \\        struct { shifted: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(85070591730234615865843651857942052864) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "shifted", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime N: u8) type {
        \\    return if (@shrExact(N, 1) == 1)
        \\        struct { exact: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(3) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "exact", .kind = .Field, .detail = "u8" },
        .{ .label = "fallback", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with wrapping and saturating comptime integers" {
    const cases = [_]struct { expression: []const u8, detail: []const u8 }{
        .{ .expression = "@as(u8, 250) +% 10", .detail = "[4]u8" },
        .{ .expression = "@as(u8, 250) +| 10", .detail = "[255]u8" },
        .{ .expression = "@as(u8, 2) -% 3", .detail = "[255]u8" },
        .{ .expression = "@as(u8, 2) -| 3", .detail = "[0]u8" },
        .{ .expression = "@as(u8, 40) *% 7", .detail = "[24]u8" },
        .{ .expression = "@as(u8, 40) *| 7", .detail = "[255]u8" },
        .{ .expression = "@as(u8, 0x40) <<| 2", .detail = "[255]u8" },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(allocator,
            \\fn Buffer(comptime N: usize) type {{
            \\    return struct {{ items: [N]u8 }};
            \\}}
            \\const buffer: Buffer({s}) = undefined;
            \\const fields = buffer.<cursor>
        , .{case.expression});
        defer allocator.free(source);
        try testCompletion(source, &.{
            .{ .label = "items", .kind = .Field, .detail = case.detail },
        });
    }

    try testCompletion(
        \\fn Select(comptime N: i8) type {
        \\    return if (N +% 20 == -116 and N +| 20 == 127)
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(120) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime N: i8) type {
        \\    return if (N -% 20 == 116 and N -| 20 == -128 and @as(i8, 40) *% 4 == -96 and @as(i8, 40) *| 4 == 127)
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(-120) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime shift: u16) type {
        \\    return if (@as(i16, 0x4000) <<| shift == 32767)
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(2) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with comptime size builtins" {
    try testCompletion(
        \\fn Buffer(comptime T: type) type {
        \\    return struct { bits: [@bitSizeOf(T)]u8, bytes: [@sizeOf(T)]u8 };
        \\}
        \\const buffer: Buffer(u13) = undefined;
        \\const bits = buffer.<cursor>
    , &.{
        .{ .label = "bits", .kind = .Field, .detail = "[13]u8" },
        .{ .label = "bytes", .kind = .Field, .detail = "[2]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime T: type) type {
        \\    return struct { bits: [@bitSizeOf(T)]u8, bytes: [@sizeOf(T)]u8 };
        \\}
        \\const buffer: Buffer([3]u5) = undefined;
        \\const bits = buffer.<cursor>
    , &.{
        .{ .label = "bits", .kind = .Field, .detail = "[21]u8" },
        .{ .label = "bytes", .kind = .Field, .detail = "[3]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime T: type) type {
        \\    return struct { bits: [@bitSizeOf(T)]u8, bytes: [@sizeOf(T)]u8 };
        \\}
        \\const buffer: Buffer([3:0]u13) = undefined;
        \\const fields = buffer.<cursor>
    , &.{
        .{ .label = "bits", .kind = .Field, .detail = "[61]u8" },
        .{ .label = "bytes", .kind = .Field, .detail = "[8]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime T: type) type {
        \\    return struct { bits: [@bitSizeOf(T)]u8, bytes: [@sizeOf(T)]u8 };
        \\}
        \\const vector: Buffer(@Vector(3, u13)) = undefined;
        \\const slice: Buffer([]u8) = undefined;
        \\const vector_fields = vector.<cursor>
    , &.{
        .{ .label = "bits", .kind = .Field, .detail = "[39]u8" },
        .{ .label = "bytes", .kind = .Field, .detail = "[8]u8" },
    });

    const pointer_bits = @bitSizeOf(usize);
    const source =
        \\fn Buffer(comptime T: type) type {
        \\    return struct { bits: [@bitSizeOf(T)]u8, bytes: [@sizeOf(T)]u8 };
        \\}
        \\const buffer: Buffer([]u8) = undefined;
        \\const fields = buffer.<cursor>
    ;
    const slice_bits = try std.fmt.allocPrint(allocator, "[{}]u8", .{pointer_bits * 2});
    defer allocator.free(slice_bits);
    const slice_bytes = try std.fmt.allocPrint(allocator, "[{}]u8", .{@sizeOf(usize) * 2});
    defer allocator.free(slice_bytes);
    try testCompletion(source, &.{
        .{ .label = "bits", .kind = .Field, .detail = slice_bits },
        .{ .label = "bytes", .kind = .Field, .detail = slice_bytes },
    });

    try testCompletion(
        \\fn Buffer(comptime T: type) type {
        \\    const AstEnum = enum(T) { value = 1 };
        \\    const GeneratedEnum = @Enum(T, .exhaustive, &.{"value"}, &.{1});
        \\    return if (@bitSizeOf(AstEnum) == 13 and @sizeOf(AstEnum) == 2 and
        \\        @bitSizeOf(GeneratedEnum) == 13 and @sizeOf(GeneratedEnum) == 2)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Buffer(u13) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u13" },
    });

    try testCompletion(
        \\fn Buffer(comptime T: type) type {
        \\    return struct { bytes: [@sizeOf(T)]u8 };
        \\}
        \\const buffer: Buffer(u24) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "bytes", .kind = .Field, .detail = "[4]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime T: type) type {
        \\    return struct { bytes: [@sizeOf(T)]u8 };
        \\}
        \\const buffer: Buffer(u40) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "bytes", .kind = .Field, .detail = "[8]u8" },
    });
}

test "generic function with nested comptime size builtin mutations" {
    try testCompletion(
        \\fn Buffer(comptime T: type) type {
        \\    var size_total: usize = 1;
        \\    var bits_total: usize = 1;
        \\    var align_total: usize = 1;
        \\    const size = @sizeOf(value: {
        \\        defer size_total += 1;
        \\        size_total *= 2;
        \\        break :value T;
        \\    });
        \\    const bits = @bitSizeOf(value: {
        \\        defer bits_total += 1;
        \\        bits_total *= 2;
        \\        break :value T;
        \\    });
        \\    const alignment = @alignOf(value: {
        \\        defer align_total += 1;
        \\        align_total *= 2;
        \\        break :value T;
        \\    });
        \\    return struct {
        \\        size: [size * size_total]u8,
        \\        bits: [bits * bits_total]u8,
        \\        alignment: [alignment * align_total]u8,
        \\    };
        \\}
        \\const buffer: Buffer(u16) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "size", .kind = .Field, .detail = "[6]u8" },
        .{ .label = "bits", .kind = .Field, .detail = "[48]u8" },
        .{ .label = "alignment", .kind = .Field, .detail = "[6]u8" },
    });
}

test "generic function with comptime Int type constructor" {
    try testCompletion(
        \\const std = @import("std");
        \\fn Number(comptime signedness: std.builtin.Signedness, comptime bits: u16) type {
        \\    return struct { value: @Int(signedness, bits) };
        \\}
        \\const number: Number(.signed, 13) = undefined;
        \\const field = number.<cursor>
    , &.{
        .{ .label = "value", .kind = .Field, .detail = "i13" },
    });

    try testCompletion(
        \\const std = @import("std");
        \\fn Number(comptime signedness: std.builtin.Signedness, comptime bits: u16) type {
        \\    return struct { value: @Int(signedness, bits) };
        \\}
        \\const number: Number(.unsigned, 256) = undefined;
        \\const field = number.<cursor>
    , &.{
        .{ .label = "value", .kind = .Field, .detail = "u256" },
    });
}

test "generic function with comptime Tuple type constructor" {
    try testCompletion(
        \\fn Pair(comptime T: type, comptime U: type) type {
        \\    return @Tuple(&.{ T, U });
        \\}
        \\const pair: Pair(u8, i16) = undefined;
        \\const field = pair.<cursor>
    , &.{
        .{ .label = "@\"0\"", .kind = .Field, .detail = "u8" },
        .{ .label = "@\"1\"", .kind = .Field, .detail = "i16" },
    });

    try testCompletion(
        \\fn Pair(comptime T: type, comptime U: type) type {
        \\    const fields = &.{ T, U };
        \\    return @Tuple(fields);
        \\}
        \\const pair: Pair(u16, bool) = undefined;
        \\const field = pair.<cursor>
    , &.{
        .{ .label = "@\"0\"", .kind = .Field, .detail = "u16" },
        .{ .label = "@\"1\"", .kind = .Field, .detail = "bool" },
    });
}

test "generic function with nested comptime Tuple mutation" {
    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    var total: usize = 1;
        \\    const Pair = @Tuple(fields: {
        \\        total *= 2;
        \\        break :fields &.{ T, bool };
        \\    });
        \\    return if (Pair == @Tuple(&.{ u8, bool }))
        \\        struct { order: [total]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u8) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "order", .kind = .Field, .detail = "[2]u8" },
    });
}

test "generic function with comptime Pointer type constructor" {
    try testCompletion(
        \\const std = @import("std");
        \\fn Holder(comptime size: std.builtin.Type.Pointer.Size, comptime T: type) type {
        \\    return struct { ptr: @Pointer(size, .{ .@"const" = true }, T, null) };
        \\}
        \\const holder: Holder(.one, u8) = undefined;
        \\const field = holder.<cursor>
    , &.{
        .{ .label = "ptr", .kind = .Field, .detail = "*const u8" },
    });

    try testCompletion(
        \\const std = @import("std");
        \\fn Holder(comptime T: type, comptime sentinel: T) type {
        \\    return struct { ptr: @Pointer(.slice, .{ .@"const" = true }, T, sentinel) };
        \\}
        \\const holder: Holder(u8, 0) = undefined;
        \\const field = holder.<cursor>
    , &.{
        .{ .label = "ptr", .kind = .Field, .detail = "[:0]const u8" },
    });

    try testCompletion(
        \\const std = @import("std");
        \\fn Holder(comptime T: type) type {
        \\    const attrs = .{ .@"const" = true, .@"align" = 4 };
        \\    return struct { ptr: @Pointer(.many, attrs, T, null) };
        \\}
        \\const holder: Holder(u32) = undefined;
        \\const field = holder.<cursor>
    , &.{
        .{ .label = "ptr", .kind = .Field, .detail = "[*]align(4) const u32" },
    });
}

test "generic function with dependent comptime value parameter" {
    try testCompletion(
        \\fn Select(comptime T: type, comptime value: T) type {
        \\    return if (value == @as(T, 4))
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16, 4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });
}

test "generic function with comptime Fn type constructor" {
    try testCompletion(
        \\fn Holder(comptime T: type, comptime U: type) type {
        \\    const Callback = @Fn(&.{T}, &.{.{}}, U, .{});
        \\    return struct { callback: *const Callback };
        \\}
        \\const holder: Holder(u8, i16) = undefined;
        \\const field = holder.<cursor>
    , &.{
        .{ .label = "callback", .kind = .Field, .detail = "*const fn(u8) i16" },
    });

    try testCompletion(
        \\fn Holder(comptime T: type, comptime U: type) type {
        \\    const parameters = &.{ T, bool };
        \\    const Callback = @Fn(parameters, &.{ .{}, .{} }, U, .{});
        \\    return struct { callback: *const Callback };
        \\}
        \\const holder: Holder(u16, void) = undefined;
        \\const field = holder.<cursor>
    , &.{
        .{ .label = "callback", .kind = .Field, .detail = "*const fn(u16, bool) void" },
    });

    try testCompletion(
        \\fn Holder(comptime T: type) type {
        \\    const Callback = @Fn(&.{*T}, &.{.{ .@"noalias" = true }}, void, .{});
        \\    return struct { callback: *const Callback };
        \\}
        \\const holder: Holder(u8) = undefined;
        \\const field = holder.<cursor>
    , &.{
        .{ .label = "callback", .kind = .Field, .detail = "*const fn(noalias *u8) void" },
    });

    try testCompletion(
        \\fn Holder(comptime T: type) type {
        \\    const Callback = @Fn(&.{T}, &.{.{}}, void, .{ .@"callconv" = .c, .varargs = true });
        \\    return struct { callback: *const Callback };
        \\}
        \\const holder: Holder(u8) = undefined;
        \\const field = holder.<cursor>
    , &.{
        .{ .label = "callback", .kind = .Field, .detail = "*const fn(u8, ...) callconv(.c) void" },
    });

    try testCompletion(
        \\fn Holder(comptime T: type) type {
        \\    const param_attrs = &.{.{ .@"noalias" = true }};
        \\    const fn_attrs = .{ .@"callconv" = .c, .varargs = true };
        \\    const Callback = @Fn(&.{*T}, param_attrs, void, fn_attrs);
        \\    return struct { callback: *const Callback };
        \\}
        \\const holder: Holder(u8) = undefined;
        \\const field = holder.<cursor>
    , &.{
        .{ .label = "callback", .kind = .Field, .detail = "*const fn(noalias *u8, ...) callconv(.c) void" },
    });
}

test "generic function with comptime std meta ArgsTuple generated function" {
    try testCompletion(
        \\const std = @import("std");
        \\fn Holder(comptime T: type) type {
        \\    const F = @Fn(&.{ T, u8 }, &.{ .{}, .{} }, void, .{});
        \\    return struct { args: std.meta.ArgsTuple(F) };
        \\}
        \\const holder: Holder(u16) = undefined;
        \\const fields = holder.args.<cursor>
    , &.{
        .{ .label = "@\"0\"", .kind = .Field, .detail = "u16" },
        .{ .label = "@\"1\"", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with comptime Struct type constructor" {
    try testCompletion(
        \\fn Record(comptime T: type) type {
        \\    return @Struct(.auto, null, &.{ "value", "enabled" }, &.{ T, bool }, &.{ .{}, .{} });
        \\}
        \\const record: Record(u16) = undefined;
        \\const field = record.<cursor>
    , &.{
        .{ .label = "value", .kind = .Field, .detail = "value: u16" },
        .{ .label = "enabled", .kind = .Field, .detail = "enabled: bool" },
    });

    try testCompletion(
        \\fn Record(comptime T: type, comptime alignment: u16) type {
        \\    return @Struct(.auto, null, &.{"value"}, &.{T}, &.{.{ .@"align" = alignment }});
        \\}
        \\const record: Record(u8, 4) = undefined;
        \\const field = record.<cursor>
    , &.{
        .{ .label = "value", .kind = .Field, .detail = "value: align(4) u8" },
    });

    try testCompletion(
        \\fn Record(comptime T: type, comptime alignment: u16) type {
        \\    const names = &.{ "value", "enabled" };
        \\    const types = &.{ T, bool };
        \\    const attrs = &.{ .{ .@"align" = alignment }, .{} };
        \\    return @Struct(.auto, null, names, types, attrs);
        \\}
        \\const record: Record(u16, 8) = undefined;
        \\const field = record.<cursor>
    , &.{
        .{ .label = "value", .kind = .Field, .detail = "value: align(8) u16" },
        .{ .label = "enabled", .kind = .Field, .detail = "enabled: bool" },
    });

    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const Extern = @Struct(.@"extern", null, &.{"value"}, &.{T}, &.{.{} });
        \\    const Packed = @Struct(.@"packed", null, &.{ "low", "high" }, &.{ u3, T }, &.{ .{}, .{} });
        \\    const Explicit = @Struct(.@"packed", i8, &.{ "low", "high" }, &.{ u3, T }, &.{ .{}, .{} });
        \\    return if (@typeInfo(Extern).@"struct".layout == .@"extern" and
        \\        @typeInfo(Packed).@"struct".backing_integer.? == u8 and
        \\        @typeInfo(Explicit).@"struct".backing_integer.? == i8 and
        \\        @bitSizeOf(Packed) == 8 and @sizeOf(Packed) == 1 and @alignOf(Packed) == 1)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u5) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u5" },
    });
}

test "generic Struct with mutable comptime field arrays" {
    try testCompletion(
        \\const std = @import("std");
        \\fn Record(comptime T: type) type {
        \\    comptime var names: [2][:0]const u8 = undefined;
        \\    comptime var types: [2]type = undefined;
        \\    comptime var attrs: [2]std.builtin.Type.StructField.Attributes = undefined;
        \\    inline for (.{ "value", "enabled" }, .{ T, bool }, 0..) |name, Field, index| {
        \\        names[index] = name;
        \\        types[index] = Field;
        \\        attrs[index] = .{};
        \\    }
        \\    return @Struct(.auto, null, &names, &types, &attrs);
        \\}
        \\const record: Record(u16) = undefined;
        \\const field = record.<cursor>
    , &.{
        .{ .label = "value", .kind = .Field, .detail = "value: u16" },
        .{ .label = "enabled", .kind = .Field, .detail = "enabled: bool" },
    });
}

test "generic Struct with helper writes and AST field types" {
    try testCompletion(
        \\const std = @import("std");
        \\fn Model(comptime T: type) type {
        \\    return struct {
        \\        value: T = 0,
        \\        pub fn call(_: @This(), value: T) T { return value; }
        \\    };
        \\}
        \\fn setField(comptime index: usize, comptime name: [:0]const u8, comptime T: type,
        \\    names: anytype, types: anytype, attrs: anytype) void
        \\{
        \\    const Default = struct { const value: T = .{}; };
        \\    names[index] = name;
        \\    types[index] = T;
        \\    attrs[index] = .{ .default_value_ptr = @ptrCast(&Default.value) };
        \\}
        \\fn Requirements(comptime capabilities: anytype) type {
        \\    const fields = @typeInfo(@TypeOf(capabilities)).@"struct".fields;
        \\    comptime var names: [fields.len][:0]const u8 = undefined;
        \\    comptime var types: [fields.len]type = undefined;
        \\    comptime var attrs: [fields.len]std.builtin.Type.StructField.Attributes = undefined;
        \\    inline for (fields, 0..) |field, index| {
        \\        const T = @field(capabilities, field.name);
        \\        if (@TypeOf(T) == type) {
        \\            setField(index, field.name, Model(T), &names, &types, &attrs);
        \\            continue;
        \\        }
        \\    }
        \\    return @Struct(.auto, null, &names, &types, &attrs);
        \\}
        \\const capabilities: Requirements(.{ .reader = u8, .seekable = u64 }) = .{};
        \\const method = capabilities.seekable.<cursor>
    , &.{
        .{ .label = "value", .kind = .Field, .detail = "u64" },
        .{ .label = "call", .kind = .Method },
    });
}

test "named generic Struct result preserves generated fields" {
    try testCompletion(
        \\const std = @import("std");
        \\fn Model(comptime T: type) type {
        \\    return struct {
        \\        value: T = 0,
        \\        pub fn call(_: @This(), value: T) T { return value; }
        \\    };
        \\}
        \\fn setField(comptime index: usize, comptime name: [:0]const u8, comptime T: type,
        \\    names: anytype, types: anytype, attrs: anytype) void
        \\{
        \\    const Default = struct { const value: T = .{}; };
        \\    names[index] = name;
        \\    types[index] = T;
        \\    attrs[index] = .{ .default_value_ptr = @ptrCast(&Default.value) };
        \\}
        \\fn Requirements(comptime capabilities: anytype) type {
        \\    const fields = @typeInfo(@TypeOf(capabilities)).@"struct".fields;
        \\    comptime var names: [fields.len][:0]const u8 = undefined;
        \\    comptime var types: [fields.len]type = undefined;
        \\    comptime var attrs: [fields.len]std.builtin.Type.StructField.Attributes = undefined;
        \\    inline for (fields, 0..) |field, index| {
        \\        const T = @field(capabilities, field.name);
        \\        setField(index, field.name, Model(T), &names, &types, &attrs);
        \\    }
        \\    return @Struct(.auto, null, &names, &types, &attrs);
        \\}
        \\const Capabilities = Requirements(.{
        \\    .reader = u8,
        \\    .seekable = u64,
        \\});
        \\const capabilities: Capabilities = .{};
        \\const capability = capabilities.<cursor>
    , &.{
        .{ .label = "reader", .kind = .Field },
        .{ .label = "seekable", .kind = .Field },
    });
}

test "generic Struct rejects unknown or invalid field arrays" {
    const template =
        \\const std = @import("std");
        \\var runtime: bool = false;
        \\fn Record(comptime T: type) type {
        \\    comptime var names: [1][:0]const u8 = undefined;
        \\    comptime var types: [1]type = undefined;
        \\    comptime var attrs: [1]std.builtin.Type.StructField.Attributes = undefined;
        \\    BODY
        \\    return @Struct(.auto, null, &names, &types, &attrs);
        \\}
        \\const record: Record(u16) = undefined;
        \\const field = record.<cursor>
    ;
    for ([_][]const u8{
        "types[0] = T; attrs[0] = .{};",
        "names[1] = \"bad\"; types[0] = T; attrs[0] = .{};",
        "if (runtime) names[0] = \"a\" else names[0] = \"b\"; types[0] = T; attrs[0] = .{};",
        "inline for (0..1000000) |_| {} names[0] = \"value\"; types[0] = T; attrs[0] = .{};",
        "const recurse = struct { fn run() void { run(); } }; recurse.run(); names[0] = \"value\"; types[0] = T; attrs[0] = .{};",
    }) |body| {
        const source = try std.mem.replaceOwned(u8, allocator, template, "BODY", body);
        defer allocator.free(source);
        try testCompletion(source, &.{});
    }
}

test "generic Struct preserves explicit implementation values" {
    try testCompletion(
        \\const std = @import("std");
        \\fn Model(comptime T: type) type { return struct { value: T = 0 }; }
        \\fn Record(comptime capabilities: anytype) type {
        \\    const fields = @typeInfo(@TypeOf(capabilities)).@"struct".fields;
        \\    comptime var names: [fields.len][:0]const u8 = undefined;
        \\    comptime var types: [fields.len]type = undefined;
        \\    comptime var attrs: [fields.len]std.builtin.Type.StructField.Attributes = undefined;
        \\    inline for (fields, 0..) |field, index| {
        \\        names[index] = field.name;
        \\        const capability = @field(capabilities, field.name);
        \\        types[index] = if (@TypeOf(capability) == type) Model(capability) else @TypeOf(capability);
        \\        attrs[index] = .{};
        \\    }
        \\    return @Struct(.auto, null, &names, &types, &attrs);
        \\}
        \\const model = Model(u32){ .value = 42 };
        \\const record: Record(.{ .first = u8, .second = model }) = undefined;
        \\const value = record.second.<cursor>
    , &.{.{ .label = "value", .kind = .Field, .detail = "u32" }});
}

test "generic function with comptime generated Struct values" {
    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const S = @Struct(.auto, null, &.{ "count", "payload" }, &.{ u8, T }, &.{ .{}, .{} });
        \\    const value = S{ .payload = 42, .count = 7 };
        \\    return if (value.count == 7 and value.payload == 42)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });

    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const S = @Struct(.auto, null, &.{ "count", "payload" }, &.{ u8, T }, &.{ .{}, .{} });
        \\    const value: S = .{ .count = undefined, .payload = 42 };
        \\    return if (value.count == 7)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
        .{ .label = "fallback", .kind = .Field, .detail = "u8" },
    });
}

test "generic generated type identity" {
    try testCompletion(
        \\fn Record(comptime T: type) type {
        \\    return @Struct(.auto, null, &.{"value"}, &.{T}, &.{.{}});
        \\}
        \\fn Select(comptime T: type) type {
        \\    const A = Record(T);
        \\    const B = Record(T);
        \\    const Other = Record(u8);
        \\    const value = A{ .value = 1 };
        \\    return if (A == B and A != Other and @TypeOf(value) == A)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });

    try testCompletion(
        \\fn Value(comptime T: type) type {
        \\    return @Union(.auto, null, &.{"value"}, &.{T}, &.{.{}});
        \\}
        \\fn Select(comptime T: type) type {
        \\    const A = Value(T);
        \\    const B = Value(T);
        \\    const Other = Value(u8);
        \\    const value = A{ .value = 1 };
        \\    return if (A == B and A != Other and @TypeOf(value) == A)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });

    try testCompletion(
        \\fn Mode(comptime T: type) type {
        \\    return @Enum(T, .exhaustive, &.{"value"}, &.{1});
        \\}
        \\fn Select(comptime T: type) type {
        \\    const A = Mode(T);
        \\    const B = Mode(T);
        \\    const Other = Mode(u8);
        \\    return if (A == B and A != Other and @TypeOf(A.value) == A)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });
}

test "generic function with comptime Union type constructor" {
    try testCompletion(
        \\fn Value(comptime T: type) type {
        \\    return @Union(.auto, null, &.{ "value", "enabled" }, &.{ T, bool }, &.{ .{}, .{} });
        \\}
        \\const value: Value(u16) = undefined;
        \\const field = value.<cursor>
    , &.{
        .{ .label = "value", .kind = .Field, .detail = "value: u16" },
        .{ .label = "enabled", .kind = .Field, .detail = "enabled: bool" },
    });

    try testCompletion(
        \\fn Value(comptime T: type, comptime alignment: u16) type {
        \\    return @Union(.auto, null, &.{"value"}, &.{T}, &.{.{ .@"align" = alignment }});
        \\}
        \\const value: Value(u8, 4) = undefined;
        \\const field = value.<cursor>
    , &.{
        .{ .label = "value", .kind = .Field, .detail = "value: align(4) u8" },
    });

    try testCompletion(
        \\const std = @import("std");
        \\fn Select(comptime T: type) type {
        \\    const Tag = @Enum(u8, .exhaustive, &.{ "value", "enabled" }, &.{ 1, 2 });
        \\    const U = @Union(.auto, Tag, &.{ "value", "enabled" }, &.{ T, bool }, &.{ .{}, .{} });
        \\    const info = @typeInfo(U).@"union";
        \\    return if (info.tag_type.? == Tag and std.meta.Tag(U) == Tag)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });

    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const U = @Union(.@"extern", null, &.{ "value", "enabled" }, &.{ T, bool }, &.{ .{}, .{} });
        \\    const info = @typeInfo(U).@"union";
        \\    return if (info.layout == .@"extern" and info.tag_type == null)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });

    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const Inferred = @Union(.@"packed", null, &.{ "unsigned", "signed" }, &.{ T, i5 }, &.{ .{}, .{} });
        \\    const Explicit = @Union(.@"packed", i5, &.{ "unsigned", "signed" }, &.{ T, i5 }, &.{ .{}, .{} });
        \\    return if (@typeInfo(Inferred).@"union".layout == .@"packed" and
        \\        @typeInfo(Inferred).@"union".tag_type == null and
        \\        @bitSizeOf(Inferred) == 5 and @sizeOf(Inferred) == 1 and
        \\        @bitSizeOf(Explicit) == 5 and @alignOf(Explicit) == 1)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u5) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u5" },
    });
}

test "generic function with comptime generated Union values" {
    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const U = @Union(.auto, null, &.{ "count", "payload" }, &.{ u8, T }, &.{ .{}, .{} });
        \\    const direct = U{ .payload = 42 };
        \\    const initialized = @unionInit(U, "count", 7);
        \\    return if (direct.payload == 42 and @field(initialized, "count") == 7)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });

    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const U = @Union(.auto, null, &.{ "count", "payload" }, &.{ u8, T }, &.{ .{}, .{} });
        \\    const value: U = .{ .count = undefined };
        \\    return if (value.count == 7)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
        .{ .label = "fallback", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with nested comptime unionInit mutations" {
    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const U = @Union(.auto, null, &.{ "count", "payload" }, &.{ u16, T }, &.{ .{}, .{} });
        \\    var total: usize = 1;
        \\    const initialized = @unionInit(union_type: {
        \\        total += 1;
        \\        break :union_type U;
        \\    }, field_name: {
        \\        total *= 2;
        \\        break :field_name "count";
        \\    }, value: {
        \\        total += 3;
        \\        break :value 7;
        \\    });
        \\    return if (@field(initialized, "count") == 7)
        \\        struct { order: [total]T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u8) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "order", .kind = .Field, .detail = "[7]u8" },
    });

    try testCompletion(
        \\var runtime: u16 = undefined;
        \\fn Select() type {
        \\    const Tag = @Enum(u8, .exhaustive, &.{ "count", "other" }, &.{ 0, 1 });
        \\    const U = @Union(.auto, Tag, &.{ "count", "other" }, &.{ u16, void }, &.{ .{}, .{} });
        \\    var total: usize = 1;
        \\    const initialized = @unionInit(union_type: {
        \\        total += 1;
        \\        break :union_type U;
        \\    }, field_name: {
        \\        total *= 2;
        \\        break :field_name "count";
        \\    }, value: {
        \\        total += 3;
        \\        break :value runtime;
        \\    });
        \\    return switch (initialized) {
        \\        .count => struct { active: [total]u8 },
        \\        .other => struct { fallback: u8 },
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "active", .kind = .Field, .detail = "[7]u8" },
    });
}

test "comptime interpreter preserves unionInit result locations" {
    const cases = [_]struct { type: []const u8, initializer: []const u8, count: []const u8, generated: bool = true }{
        .{ .type = "usize", .initializer = "small", .count = "payload" },
        .{ .type = "?usize", .initializer = "small", .count = "payload.?" },
        .{ .type = "[1]usize", .initializer = ".{small}", .count = "payload[0]" },
        .{ .type = "?[1]usize", .initializer = ".{small}", .count = "payload.?[0]" },
        .{ .type = "Config", .initializer = ".{ .capacity = small }", .count = "payload.capacity", .generated = false },
        .{ .type = "?Config", .initializer = ".{ .capacity = small }", .count = "payload.?.capacity", .generated = false },
        .{ .type = "[]const u8", .initializer = "\"text\"", .count = "payload.len" },
    };
    for (cases) |case| {
        for ([_]bool{ false, true }) |generated| {
            if (generated and !case.generated) continue;
            const declaration = if (generated)
                try std.fmt.allocPrint(allocator, "@Union(.auto, @Enum(u8, .exhaustive, &.{{ \"payload\", \"empty\" }}, &.{{ 0, 1 }}), &.{{ \"payload\", \"empty\" }}, &.{{ {s}, void }}, &.{{ .{{}}, .{{}} }})", .{case.type})
            else
                try std.fmt.allocPrint(allocator, "union(enum) {{ payload: {s}, empty }}", .{case.type});
            defer allocator.free(declaration);
            const source = try std.fmt.allocPrint(allocator,
                \\const Config = struct {{ capacity: usize }};
                \\fn Select() type {{
                \\    const U = {s};
                \\    const small: u8 = 4;
                \\    var executions: usize = 0;
                \\    const value = @unionInit(union_type: {{
                \\        executions += 1;
                \\        break :union_type U;
                \\    }}, field_name: {{
                \\        executions = executions * 10 + 2;
                \\        break :field_name "payload";
                \\    }}, result: {{
                \\        executions = executions * 10 + 3;
                \\        break :result {s};
                \\    }});
                \\    return switch (value) {{
                \\        .payload => |payload| struct {{
                \\            items: [if (@TypeOf({s}) == usize) {s} else 99]u8,
                \\            executions: [executions]u8,
                \\        }},
                \\        .empty => struct {{ fallback: u8 }},
                \\    }};
                \\}}
                \\const selected: Select() = undefined;
                \\const field = selected.<cursor>
            , .{ declaration, case.initializer, case.count, case.count });
            defer allocator.free(source);
            errdefer std.debug.print("unionInit source:\n{s}\n", .{source});
            try testCompletion(source, &.{
                .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
                .{ .label = "executions", .kind = .Field, .detail = "[123]u8" },
            });
        }
    }
}

test "comptime interpreter preserves nested unionInit casts and mutations" {
    try testCompletion(
        \\const U = union(enum) { payload: usize, empty };
        \\fn Select() type {
        \\    var executions: usize = 0;
        \\    const values = .{ @unionInit(U, "payload", @intCast(result: {
        \\        executions += 1;
        \\        break :result @as(u16, 4);
        \\    })), @unionInit(U, "empty", {}) };
        \\    var value = values[0];
        \\    switch (value) {
        \\        .payload => |*payload| payload.* += 2,
        \\        .empty => {},
        \\    }
        \\    return struct {
        \\        original: [values[0].payload]u8,
        \\        changed: [value.payload]u8,
        \\        executions: [executions]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "original", .kind = .Field, .detail = "[4]u8" },
        .{ .label = "changed", .kind = .Field, .detail = "[6]u8" },
        .{ .label = "executions", .kind = .Field, .detail = "[1]u8" },
    });
}

test "comptime interpreter validates unionInit optional payloads" {
    const cases = [_]struct { initializer: []const u8, valid: bool }{
        .{ .initializer = "runtime_u8", .valid = true },
        .{ .initializer = "null", .valid = true },
        .{ .initializer = "runtime_bool", .valid = false },
        .{ .initializer = "\"invalid\"", .valid = false },
        .{ .initializer = ".{1, 2}", .valid = false },
    };
    for (cases) |case| {
        for ([_]bool{ false, true }) |generated| {
            const source = try std.fmt.allocPrint(allocator,
                \\var runtime_u8: u8 = undefined;
                \\var runtime_bool: bool = undefined;
                \\fn Select() type {{
                \\    const U = {s};
                \\    var executions: usize = 0;
                \\    const value = @unionInit(U, "payload", result: {{
                \\        executions += 1;
                \\        break :result {s};
                \\    }});
                \\    return switch (value) {{
                \\        .payload => struct {{ accepted: [executions]u8 }},
                \\        .empty => struct {{ fallback: u8 }},
                \\    }};
                \\}}
                \\const selected: Select() = undefined;
                \\const field = selected.<cursor>
            , .{
                if (generated)
                    "@Union(.auto, @Enum(u8, .exhaustive, &.{ \"payload\", \"empty\" }, &.{ 0, 1 }), &.{ \"payload\", \"empty\" }, &.{ ?usize, void }, &.{ .{}, .{} })"
                else
                    "union(enum) { payload: ?usize, empty }",
                case.initializer,
            });
            defer allocator.free(source);
            errdefer std.debug.print("unionInit validation source:\n{s}\n", .{source});
            try testCompletion(source, if (case.valid) &.{
                .{ .label = "accepted", .kind = .Field, .detail = "[1]u8" },
            } else &.{
                .{ .label = "accepted", .kind = .Field },
                .{ .label = "fallback", .kind = .Field, .detail = "u8" },
            });
        }
    }
}

test "generic function coerces runtime unknown comptime unionInit payload" {
    try testCompletion(
        \\var runtime_u8: u8 = undefined;
        \\fn Select() type {
        \\    const Tag = @Enum(u8, .exhaustive, &.{ "count", "empty" }, &.{ 0, 1 });
        \\    const U = @Union(.auto, Tag, &.{ "count", "empty" }, &.{ u16, void }, &.{ .{}, .{} });
        \\    const value = @unionInit(U, "count", runtime_u8);
        \\    return switch (value) {
        \\        .count => struct { accepted: u8 },
        \\        .empty => struct { fallback: u8 },
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "accepted", .kind = .Field, .detail = "u8" },
    });
}

test "generic function rejects invalid runtime unknown comptime unionInit payload" {
    try testCompletion(
        \\var runtime_bool: bool = undefined;
        \\fn Select() type {
        \\    const Tag = @Enum(u8, .exhaustive, &.{ "count", "empty" }, &.{ 0, 1 });
        \\    const U = @Union(.auto, Tag, &.{ "count", "empty" }, &.{ u16, void }, &.{ .{}, .{} });
        \\    const value = @unionInit(U, "count", runtime_bool);
        \\    return switch (value) {
        \\        .count => struct { accepted: u8 },
        \\        .empty => struct { fallback: u8 },
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "accepted", .kind = .Field, .detail = "u8" },
        .{ .label = "fallback", .kind = .Field, .detail = "u8" },
    });
}

test "generic function coerces runtime unknown comptime union literal payload" {
    try testCompletion(
        \\var runtime_u8: u8 = undefined;
        \\fn Select() type {
        \\    const Tag = @Enum(u8, .exhaustive, &.{ "count", "empty" }, &.{ 0, 1 });
        \\    const U = @Union(.auto, Tag, &.{ "count", "empty" }, &.{ u16, void }, &.{ .{}, .{} });
        \\    const value = U{ .count = runtime_u8 };
        \\    return switch (value) {
        \\        .count => struct { accepted: u8 },
        \\        .empty => struct { fallback: u8 },
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "accepted", .kind = .Field, .detail = "u8" },
    });
}

test "generic function rejects invalid runtime unknown comptime union literal payload" {
    try testCompletion(
        \\var runtime_bool: bool = undefined;
        \\fn Select() type {
        \\    const Tag = @Enum(u8, .exhaustive, &.{ "count", "empty" }, &.{ 0, 1 });
        \\    const U = @Union(.auto, Tag, &.{ "count", "empty" }, &.{ u16, void }, &.{ .{}, .{} });
        \\    const value = U{ .count = runtime_bool };
        \\    return switch (value) {
        \\        .count => struct { accepted: u8 },
        \\        .empty => struct { fallback: u8 },
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "accepted", .kind = .Field, .detail = "u8" },
        .{ .label = "fallback", .kind = .Field, .detail = "u8" },
    });
}

test "comptime interpreter preserves union initializer result locations" {
    const cases = [_]struct { type: []const u8, initializer: []const u8, value: []const u8 }{
        .{ .type = "usize", .initializer = "small", .value = "value.payload" },
        .{ .type = "?usize", .initializer = "small", .value = "value.payload.?" },
        .{ .type = "[1]usize", .initializer = ".{small}", .value = "value.payload[0]" },
        .{ .type = "?[1]usize", .initializer = ".{small}", .value = "value.payload.?[0]" },
        .{ .type = "Config", .initializer = ".{ .capacity = small }", .value = "value.payload.capacity" },
        .{ .type = "?Config", .initializer = ".{ .capacity = small }", .value = "value.payload.?.capacity" },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(allocator,
            \\const Config = struct {{ capacity: usize }};
            \\const U = union(enum) {{ payload: {s}, empty }};
            \\fn Select() type {{
            \\    const small: u8 = 4;
            \\    var executions: usize = 0;
            \\    const value = U{{ .payload = result: {{
            \\        executions += 1;
            \\        break :result if (small == 4) {s} else {s};
            \\    }} }};
            \\    const count = {s};
            \\    return switch (value) {{
            \\        .payload => struct {{
            \\            items: [if (@TypeOf(count) == usize) count else 99]u8,
            \\            executions: [executions]u8,
            \\        }},
            \\        .empty => struct {{ fallback: u8 }},
            \\    }};
            \\}}
            \\const selected: Select() = undefined;
            \\const field = selected.<cursor>
        , .{ case.type, case.initializer, case.initializer, case.value });
        defer allocator.free(source);
        errdefer std.debug.print("union initializer source:\n{s}\n", .{source});
        try testCompletion(source, &.{
            .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
            .{ .label = "executions", .kind = .Field, .detail = "[1]u8" },
        });
    }
}

test "comptime interpreter preserves generated struct initializer values" {
    try testCompletion(
        \\const Config = struct { capacity: usize };
        \\fn Select() type {
        \\    const S = @Struct(.auto, null, &.{ "count", "config", "sibling" }, &.{ ?usize, Config, usize }, &.{ .{}, .{}, .{} });
        \\    const small: u8 = 4;
        \\    var executions: usize = 0;
        \\    const value = S{
        \\        .config = config: {
        \\            executions += 1;
        \\            break :config .{ .capacity = small };
        \\        },
        \\        .sibling = @intCast(@as(u16, 7)),
        \\        .count = count: {
        \\            executions = executions * 10 + 2;
        \\            break :count small;
        \\        },
        \\    };
        \\    const count = value.count.?;
        \\    return struct {
        \\        items: [if (@TypeOf(count) == usize and @TypeOf(value.config.capacity) == usize)
        \\            count + value.config.capacity
        \\        else
        \\            99]u8,
        \\        executions: [executions]u8,
        \\        sibling: [value.sibling]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[8]u8" },
        .{ .label = "executions", .kind = .Field, .detail = "[12]u8" },
        .{ .label = "sibling", .kind = .Field, .detail = "[7]u8" },
    });
}

test "comptime interpreter preserves generated union initializer values" {
    try testCompletion(
        \\fn Select() type {
        \\    const Tag = @Enum(u8, .exhaustive, &.{ "payload", "empty" }, &.{ 0, 1 });
        \\    const U = @Union(.auto, Tag, &.{ "payload", "empty" }, &.{ ?[1]usize, void }, &.{ .{}, .{} });
        \\    const small: u8 = 4;
        \\    var executions: usize = 0;
        \\    const value = U{ .payload = result: {
        \\        executions += 1;
        \\        break :result .{small};
        \\    } };
        \\    return switch (value) {
        \\        .payload => |payload| struct {
        \\            items: [if (@TypeOf(payload.?[0]) == usize) payload.?[0] else 99]u8,
        \\            executions: [executions]u8,
        \\        },
        \\        .empty => struct { fallback: u8 },
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
        .{ .label = "executions", .kind = .Field, .detail = "[1]u8" },
    });
}

test "comptime interpreter preserves contextual initializer casts" {
    for ([_]bool{ false, true }) |generated| {
        const source = try std.fmt.allocPrint(allocator,
            \\fn Select() type {{
            \\    const S = {s};
            \\    var executions: usize = 0;
            \\    const value = S{{
            \\        .count = @intCast(result: {{
            \\            executions += 1;
            \\            break :result @as(u16, 4);
            \\        }}),
            \\        .lanes = @splat(result: {{
            \\            executions = executions * 10 + 2;
            \\            break :result @as(u8, 3);
            \\        }}),
            \\    }};
            \\    return struct {{
            \\        items: [value.count + value.lanes[0] + value.lanes[1]]u8,
            \\        executions: [executions]u8,
            \\    }};
            \\}}
            \\const selected: Select() = undefined;
            \\const field = selected.<cursor>
        , .{if (generated)
            "@Struct(.auto, null, &.{ \"count\", \"lanes\" }, &.{ u8, @Vector(2, u8) }, &.{ .{}, .{} })"
        else
            "struct { count: u8, lanes: @Vector(2, u8) }"});
        defer allocator.free(source);
        try testCompletion(source, &.{
            .{ .label = "items", .kind = .Field, .detail = "[10]u8" },
            .{ .label = "executions", .kind = .Field, .detail = "[12]u8" },
        });
    }
}

test "comptime interpreter preserves union contextual initializer casts" {
    for ([_]bool{ false, true }) |generated| {
        const source = try std.fmt.allocPrint(allocator,
            \\fn Select() type {{
            \\    const U = {s};
            \\    var executions: usize = 0;
            \\    const value = U{{ .payload = @intCast(result: {{
            \\        executions += 1;
            \\        break :result @as(u16, 4);
            \\    }}) }};
            \\    return switch (value) {{
            \\        .payload => |payload| struct {{ items: [payload]u8, executions: [executions]u8 }},
            \\        .empty => struct {{ fallback: u8 }},
            \\    }};
            \\}}
            \\const selected: Select() = undefined;
            \\const field = selected.<cursor>
        , .{if (generated)
            "@Union(.auto, @Enum(u8, .exhaustive, &.{ \"payload\", \"empty\" }, &.{ 0, 1 }), &.{ \"payload\", \"empty\" }, &.{ u8, void }, &.{ .{}, .{} })"
        else
            "union(enum) { payload: u8, empty }"});
        defer allocator.free(source);
        try testCompletion(source, &.{
            .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
            .{ .label = "executions", .kind = .Field, .detail = "[1]u8" },
        });
    }
}

test "comptime interpreter rejects out of range contextual integer casts" {
    for ([_][]const u8{ "@as(i16, -1)", "@as(u16, 256)" }) |operand| {
        const source = try std.fmt.allocPrint(allocator,
            \\const U = union(enum) {{ payload: u8, empty }};
            \\fn Select() type {{
            \\    var executions: usize = 0;
            \\    const value = U{{ .payload = @intCast(result: {{
            \\        executions += 1;
            \\        break :result {s};
            \\    }}) }};
            \\    return switch (value) {{
            \\        .payload => struct {{ accepted: u8 }},
            \\        .empty => struct {{ fallback: u8 }},
            \\    }};
            \\}}
            \\const selected: Select() = undefined;
            \\const field = selected.<cursor>
        , .{operand});
        defer allocator.free(source);
        try testCompletion(source, &.{
            .{ .label = "accepted", .kind = .Field, .detail = "u8" },
            .{ .label = "fallback", .kind = .Field, .detail = "u8" },
        });
    }
}

test "comptime interpreter mutates generated initializer values" {
    try testCompletion(
        \\const Config = struct { capacity: usize };
        \\fn Select() type {
        \\    const S = @Struct(.auto, null, &.{ "config", "sibling" }, &.{ ?Config, usize }, &.{ .{}, .{} });
        \\    var state = S{ .config = .{ .capacity = 4 }, .sibling = 7 };
        \\    const original = state;
        \\    const pointer = &state.config;
        \\    pointer.* = .{ .capacity = @as(u8, 6) };
        \\    const Tag = @Enum(u8, .exhaustive, &.{ "payload", "empty" }, &.{ 0, 1 });
        \\    const U = @Union(.auto, Tag, &.{ "payload", "empty" }, &.{ ?[1]usize, void }, &.{ .{}, .{} });
        \\    var value = U{ .payload = .{@as(u8, 4)} };
        \\    switch (value) {
        \\        .payload => |*payload| payload.* = .{@as(u8, 6)},
        \\        .empty => {},
        \\    }
        \\    return struct {
        \\        original: [original.config.?.capacity]u8,
        \\        changed: [state.config.?.capacity + value.payload.?[0]]u8,
        \\        sibling: [state.sibling]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "original", .kind = .Field, .detail = "[4]u8" },
        .{ .label = "changed", .kind = .Field, .detail = "[12]u8" },
        .{ .label = "sibling", .kind = .Field, .detail = "[7]u8" },
    });
}

test "comptime interpreter rejects invalid nested union initializer payloads" {
    for ([_][]const u8{ ".{true}", ".{1, 2}", ".{}" }) |initializer| {
        const source = try std.fmt.allocPrint(allocator,
            \\const U = union(enum) {{ payload: ?[1]usize, empty }};
            \\fn Select() type {{
            \\    var executions: usize = 0;
            \\    const value = U{{ .payload = result: {{
            \\        executions += 1;
            \\        break :result {s};
            \\    }} }};
            \\    return switch (value) {{
            \\        .payload => struct {{ accepted: u8 }},
            \\        .empty => struct {{ fallback: u8 }},
            \\    }};
            \\}}
            \\const selected: Select() = undefined;
            \\const field = selected.<cursor>
        , .{initializer});
        defer allocator.free(source);
        errdefer std.debug.print("invalid nested initializer: {s}\n", .{initializer});
        try testCompletion(source, &.{
            .{ .label = "accepted", .kind = .Field, .detail = "u8" },
            .{ .label = "fallback", .kind = .Field, .detail = "u8" },
        });
    }
}

test "comptime interpreter rejects invalid union initializer payloads" {
    for ([_]bool{ false, true }) |generated| {
        for ([_][]const u8{ "runtime_u8", "runtime_bool", "true", "\"invalid\"", ".{}", ".{ 1, 2 }" }) |initializer| {
            const valid = std.mem.eql(u8, initializer, "runtime_u8");
            const source = try std.fmt.allocPrint(allocator,
                \\var runtime_u8: u8 = undefined;
                \\var runtime_bool: bool = undefined;
                \\fn Select() type {{
                \\    const U = {s};
                \\    var executions: usize = 0;
                \\    const value = U{{ .payload = result: {{
                \\        executions += 1;
                \\        break :result {s};
                \\    }} }};
                \\    return switch (value) {{
                \\        .payload => struct {{ accepted: [executions]u8 }},
                \\        .empty => struct {{ fallback: [executions]u8 }},
                \\    }};
                \\}}
                \\const selected: Select() = undefined;
                \\const field = selected.<cursor>
            , .{
                if (generated)
                    "@Union(.auto, @Enum(u8, .exhaustive, &.{ \"payload\", \"empty\" }, &.{ 0, 1 }), &.{ \"payload\", \"empty\" }, &.{ ?usize, void }, &.{ .{}, .{} })"
                else
                    "union(enum) { payload: ?usize, empty }",
                initializer,
            });
            defer allocator.free(source);
            errdefer std.debug.print("union validation source:\n{s}\n", .{source});
            try testCompletion(source, if (valid) &.{
                .{ .label = "accepted", .kind = .Field, .detail = "[1]u8" },
            } else &.{
                .{ .label = "accepted", .kind = .Field },
                .{ .label = "fallback", .kind = .Field },
            });
        }
    }
}

test "comptime interpreter validates source union literal payloads" {
    try testCompletion(
        \\var runtime_u8: u8 = undefined;
        \\fn Select() type {
        \\    const U = union(enum) { count: u16, empty };
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const value = U{ .count = runtime_u8 };
        \\    return switch (value) {
        \\        .count => struct { accepted: u8 },
        \\        .empty => struct { fallback: u8 },
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "accepted", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\var runtime_bool: bool = undefined;
        \\fn Select() type {
        \\    const U = union(enum) { count: u16, empty };
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const value = U{ .count = runtime_bool };
        \\    return switch (value) {
        \\        .count => struct { accepted: u8 },
        \\        .empty => struct { fallback: u8 },
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "accepted", .kind = .Field, .detail = "u8" },
        .{ .label = "fallback", .kind = .Field, .detail = "u8" },
    });
}

test "comptime interpreter merges unknown if expression branches" {
    try testCompletion(
        \\fn Select() type {
        \\    var condition = true;
        \\    condition = false;
        \\    return if (condition)
        \\        struct { selected: u8 }
        \\    else
        \\        struct { rejected: u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "rejected", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\var runtime_bool: bool = undefined;
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    return if (runtime_bool)
        \\        struct { selected: u8 }
        \\    else
        \\        struct { rejected: u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "u8" },
        .{ .label = "rejected", .kind = .Field, .detail = "u8" },
    });
}

test "comptime interpreter validates non-IP source union literal payloads" {
    try testCompletion(
        \\fn Select() type {
        \\    const U = union(enum) { text: []const u8, empty };
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const value = U{ .text = "accepted" };
        \\    return switch (value) {
        \\        .text => struct { accepted: u8 },
        \\        .empty => struct { fallback: u8 },
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "accepted", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select() type {
        \\    const U = union(enum) { count: u16, empty };
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const value = U{ .count = "rejected" };
        \\    return switch (value) {
        \\        .count => struct { accepted: u8 },
        \\        .empty => struct { fallback: u8 },
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "accepted", .kind = .Field, .detail = "u8" },
        .{ .label = "fallback", .kind = .Field, .detail = "u8" },
    });
}

test "nested comptime calls validate source union literal payloads" {
    try testCompletion(
        \\const U = union(enum) { count: u16, empty };
        \\var runtime_u8: u8 = undefined;
        \\fn identity(comptime value: U) U { return value; }
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const value = identity(.{ .count = runtime_u8 });
        \\    return switch (value) {
        \\        .count => struct { accepted: u8 },
        \\        .empty => struct { fallback: u8 },
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "accepted", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\const U = union(enum) { count: u16, empty };
        \\var runtime_bool: bool = undefined;
        \\fn identity(comptime value: U) U { return value; }
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const value = identity(.{ .count = runtime_bool });
        \\    return switch (value) {
        \\        .count => struct { accepted: u8 },
        \\        .empty => struct { fallback: u8 },
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "accepted", .kind = .Field, .detail = "u8" },
        .{ .label = "fallback", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\const U = union(enum) { text: []const u8, empty };
        \\fn identity(comptime value: U) U { return value; }
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const value = identity(.{ .text = "accepted" });
        \\    return switch (value) {
        \\        .text => struct { accepted: u8 },
        \\        .empty => struct { fallback: u8 },
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "accepted", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\const U = union(enum) { count: u16, empty };
        \\fn identity(comptime value: U) U { return value; }
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const value = identity(.{ .count = "rejected" });
        \\    return switch (value) {
        \\        .count => struct { accepted: u8 },
        \\        .empty => struct { fallback: u8 },
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "accepted", .kind = .Field, .detail = "u8" },
        .{ .label = "fallback", .kind = .Field, .detail = "u8" },
    });
}

test "comptime interpreter validates function return types" {
    try testCompletion(
        \\var runtime_u8: u8 = undefined;
        \\fn widened() u16 { return runtime_u8; }
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const value = widened();
        \\    return struct { result: @TypeOf(value) };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "result", .kind = .Field, .detail = "u16" },
    });

    try testCompletion(
        \\var runtime_u8: u8 = undefined;
        \\fn widened(comptime T: type) T { return runtime_u8; }
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const value = widened(u16);
        \\    return struct { result: @TypeOf(value) };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "result", .kind = .Field, .detail = "u16" },
    });

    try testCompletion(
        \\fn text() []const u8 { return "accepted"; }
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const value = text();
        \\    return if (value.len == 8)
        \\        struct { accepted: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "accepted", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn invalid() u16 { return "rejected"; }
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const value = invalid();
        \\    return struct { result: @TypeOf(value) };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "result", .kind = .Field, .detail = "u16" },
    });
}

test "comptime interpreter validates non-IP function parameter types" {
    try testCompletion(
        \\fn identity(comptime value: []const u8) []const u8 { return value; }
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const value = identity("accepted");
        \\    return if (value.len == 8)
        \\        struct { accepted: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "accepted", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn identity(comptime value: u16) u16 { return value; }
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const value = identity("rejected");
        \\    return struct { result: @TypeOf(value) };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "result", .kind = .Field, .detail = "u16" },
    });
}

test "comptime interpreter validates declared type function returns" {
    try testCompletion(
        \\fn invalid() type { return 4; }
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const T = invalid();
        \\    return if (@TypeOf(T) == type)
        \\        struct { accepted: u8 }
        \\    else
        \\        struct { leaked: u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "accepted", .kind = .Field, .detail = "u8" },
    });
}

test "comptime interpreter preserves explicit array and tuple initializers" {
    const cases = [_]struct { type: []const u8, element: []const u8, first: []const u8, second: []const u8 }{
        .{ .type = "[2]Config", .element = ".{ .capacity = small }", .first = "value[0].capacity", .second = "value[1].capacity" },
        .{ .type = "[_]Config", .element = ".{ .capacity = small }", .first = "value[0].capacity", .second = "value[1].capacity" },
        .{ .type = "[2]?Config", .element = ".{ .capacity = small }", .first = "value[0].?.capacity", .second = "value[1].?.capacity" },
        .{ .type = "Pair", .element = ".{ .capacity = small }", .first = "value.@\"0\".capacity", .second = "value.@\"1\".?.capacity" },
        .{ .type = "[2:0]usize", .element = "small", .first = "value[0]", .second = "value[1]" },
        .{ .type = "[_:0]usize", .element = "small", .first = "value[0]", .second = "value[1]" },
        .{ .type = "[2]usize", .element = "small", .first = "value[0]", .second = "value[1]" },
        .{ .type = "[_]usize", .element = "small", .first = "value[0]", .second = "value[1]" },
        .{ .type = "@Vector(2, usize)", .element = "small", .first = "value[0]", .second = "value[1]" },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(allocator,
            \\const Config = struct {{ capacity: usize }};
            \\const Pair = struct {{ Config, ?Config }};
            \\fn Select() type {{
            \\    const small: u8 = 4;
            \\    var executions: usize = 0;
            \\    const value = {s}{{
            \\        first: {{
            \\            executions += 1;
            \\            break :first {s};
            \\        }},
            \\        second: {{
            \\            executions = executions * 10 + 2;
            \\            break :second {s};
            \\        }},
            \\    }};
            \\    const first = {s};
            \\    const second = {s};
            \\    return struct {{
            \\        items: [if (@TypeOf(first) == usize and @TypeOf(second) == usize) first + second else 99]u8,
            \\        executions: [executions]u8,
            \\    }};
            \\}}
            \\const selected: Select() = undefined;
            \\const field = selected.<cursor>
        , .{ case.type, case.element, case.element, case.first, case.second });
        defer allocator.free(source);
        errdefer std.debug.print("explicit aggregate source:\n{s}\n", .{source});
        try testCompletion(source, &.{
            .{ .label = "items", .kind = .Field, .detail = "[8]u8" },
            .{ .label = "executions", .kind = .Field, .detail = "[12]u8" },
        });
    }
}

test "comptime interpreter preserves typed explicit initializer elements" {
    const cases = [_]struct { setup: []const u8, first_type: []const u8, first: []const u8, second: []const u8 }{
        .{ .setup = "const values = [2]u16{ runtime_u8, 4 };", .first_type = "u16", .first = "values[0]", .second = "values[1]" },
        .{ .setup = "const values = [2]u16{ true, 4 };", .first_type = "u16", .first = "values[0]", .second = "values[1]" },
        .{ .setup = "const values = [2]u16{ 65536, 4 };", .first_type = "u16", .first = "values[0]", .second = "values[1]" },
        .{ .setup = "const values = [2]Config{ .{ .capacity = runtime_u8 }, .{ .capacity = 4 } };", .first_type = "Config", .first = "values[0].capacity", .second = "values[1].capacity" },
        .{ .setup = "const values = [2]Config{ .{ .capacity = true }, .{ .capacity = 4 } };", .first_type = "Config", .first = "values[0].capacity", .second = "values[1].capacity" },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(allocator,
            \\const Config = struct {{ capacity: usize }};
            \\var runtime_u8: u8 = undefined;
            \\fn Select() type {{
            \\    var marker: usize = 0;
            \\    marker += 1;
            \\    {s}
            \\    return struct {{
            \\        typed: [if (@TypeOf(values[0]) == {s}) 1 else 99]u8,
            \\        unknown: [{s}]u8,
            \\        known: [{s}]u8,
            \\    }};
            \\}}
            \\const selected: Select() = undefined;
            \\const field = selected.<cursor>
        , .{ case.setup, case.first_type, case.first, case.second });
        defer allocator.free(source);
        errdefer std.debug.print("typed explicit aggregate source:\n{s}\n", .{source});
        try testCompletion(source, &.{
            .{ .label = "typed", .kind = .Field, .detail = "[1]u8" },
            .{ .label = "unknown", .kind = .Field, .detail = "[?]u8" },
            .{ .label = "known", .kind = .Field, .detail = "[4]u8" },
        });
    }
}

test "comptime interpreter mutates explicit aggregate initializer values" {
    try testCompletion(
        \\const Config = struct { capacity: usize };
        \\fn Select() type {
        \\    var configs = [_]Config{ .{ .capacity = 1 }, .{ .capacity = 2 } };
        \\    const original = configs;
        \\    inline for (&configs) |*config| config.capacity += 4;
        \\    const Pair = struct { Config, ?Config };
        \\    var pair = Pair{ configs[0], null };
        \\    pair.@"1" = .{ .capacity = 7 };
        \\    return struct {
        \\        original: [original[0].capacity + original[1].capacity]u8,
        \\        changed: [configs[0].capacity + configs[1].capacity]u8,
        \\        tuple: [pair.@"0".capacity + pair.@"1".?.capacity]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "original", .kind = .Field, .detail = "[3]u8" },
        .{ .label = "changed", .kind = .Field, .detail = "[11]u8" },
        .{ .label = "tuple", .kind = .Field, .detail = "[12]u8" },
    });
}

test "comptime interpreter preserves explicit struct initializer result locations" {
    try testCompletion(
        \\const Config = struct { capacity: usize };
        \\const State = struct { values: ?[1]usize, config: ?Config, sibling: usize = 7 };
        \\fn Select() type {
        \\    const small: u8 = 4;
        \\    var executions: usize = 0;
        \\    const state = State{
        \\        .values = values: {
        \\            executions += 1;
        \\            break :values .{small};
        \\        },
        \\        .config = config: {
        \\            executions = executions * 10 + 2;
        \\            break :config .{ .capacity = small };
        \\        },
        \\    };
        \\    const first = state.values.?[0];
        \\    const second = state.config.?.capacity;
        \\    return struct {
        \\        items: [if (@TypeOf(first) == usize and @TypeOf(second) == usize) first + second else 99]u8,
        \\        executions: [executions]u8,
        \\        sibling: [state.sibling]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[8]u8" },
        .{ .label = "executions", .kind = .Field, .detail = "[12]u8" },
        .{ .label = "sibling", .kind = .Field, .detail = "[7]u8" },
    });
}

test "comptime interpreter propagates contextual local initializer types" {
    const cases = [_]struct { type: []const u8, initializer: []const u8, count: []const u8 }{
        .{ .type = "u8", .initializer = "@intCast(@as(u16, 4))", .count = "value" },
        .{ .type = "u8", .initializer = "if (true) @truncate(@as(u16, 260)) else unreachable", .count = "value" },
        .{ .type = "@Vector(2, usize)", .initializer = "@splat(@as(u8, 4))", .count = "value[0]" },
        .{ .type = "Mode", .initializer = "@enumFromInt(@as(u8, 4))", .count = "@intFromEnum(value)" },
    };
    for (cases) |case| {
        for ([_][]const u8{ "const", "var" }) |modifier| {
            const source = try std.fmt.allocPrint(allocator,
                \\const Mode = enum(u8) {{ selected = 4, other = 9 }};
                \\fn Select() type {{
                \\    var executions: usize = 0;
                \\    {s} value: destination: {{
                \\        executions += 1;
                \\        break :destination {s};
                \\    }} = result: {{
                \\        executions = executions * 10 + 2;
                \\        break :result {s};
                \\    }};
                \\    return struct {{ items: [{s}]u8, executions: [executions]u8 }};
                \\}}
                \\const selected: Select() = undefined;
                \\const field = selected.<cursor>
            , .{ modifier, case.type, case.initializer, case.count });
            defer allocator.free(source);
            errdefer std.debug.print("contextual local initializer:\n{s}\n", .{source});
            try testCompletion(source, &.{
                .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
                .{ .label = "executions", .kind = .Field, .detail = "[12]u8" },
            });
        }
    }
}

test "comptime interpreter evaluates assignment targets before values" {
    try testCompletion(
        \\fn Select() type {
        \\    var values: [1][2]u8 = .{.{ 0, 7 }};
        \\    var executions: usize = 0;
        \\    values[row: {
        \\        executions += 1;
        \\        break :row 0;
        \\    }][column: {
        \\        executions = executions * 10 + 2;
        \\        break :column 0;
        \\    }] = result: {
        \\        executions = executions * 10 + 3;
        \\        break :result @intCast(@as(u16, 4));
        \\    };
        \\    return struct {
        \\        items: [values[0][0]]u8,
        \\        sibling: [values[0][1]]u8,
        \\        executions: [executions]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
        .{ .label = "sibling", .kind = .Field, .detail = "[7]u8" },
        .{ .label = "executions", .kind = .Field, .detail = "[123]u8" },
    });
}

test "comptime interpreter preserves assignment target selection" {
    try testCompletion(
        \\fn Select() type {
        \\    var values: [2]u8 = .{ 0, 7 };
        \\    var index: usize = 0;
        \\    values[index] = result: {
        \\        index = 1;
        \\        break :result @intCast(@as(u16, 4));
        \\    };
        \\    var pointer = &values[0];
        \\    pointer.* = result: {
        \\        pointer = &values[1];
        \\        break :result @intCast(@as(u16, 6));
        \\    };
        \\    const pointed = pointer.*;
        \\    return struct {
        \\        selected: [values[0]]u8,
        \\        sibling: [values[1]]u8,
        \\        pointer: [pointed]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "[6]u8" },
        .{ .label = "sibling", .kind = .Field, .detail = "[7]u8" },
        .{ .label = "pointer", .kind = .Field, .detail = "[7]u8" },
    });
}

test "comptime interpreter propagates contextual assignment types" {
    try testCompletion(
        \\const State = struct { count: u8, lanes: @Vector(2, usize), optional: ?u8 };
        \\fn Select() type {
        \\    var state = State{ .count = 0, .lanes = .{ 0, 0 }, .optional = 0 };
        \\    var evaluations: usize = 0;
        \\    state.count = if (true) @intCast(operand: {
        \\        evaluations += 1;
        \\        break :operand @as(u16, 4);
        \\    }) else unreachable;
        \\    const pointer = &state.lanes;
        \\    pointer.* = result: {
        \\        evaluations = evaluations * 10 + 2;
        \\        break :result @splat(@as(u8, 4));
        \\    };
        \\    state.optional.? = @truncate(operand: {
        \\        evaluations = evaluations * 10 + 3;
        \\        break :operand @as(u16, 260);
        \\    });
        \\    return struct {
        \\        items: [state.count + state.lanes[0] + state.lanes[1] + state.optional.?]u8,
        \\        evaluations: [evaluations]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[16]u8" },
        .{ .label = "evaluations", .kind = .Field, .detail = "[123]u8" },
    });
}

test "comptime interpreter preserves unknown contextual locals" {
    try testCompletion(
        \\var runtime: u16 = undefined;
        \\fn Select() type {
        \\    var evaluations: usize = 0;
        \\    const declared: u8 = @intCast(operand: {
        \\        evaluations += 1;
        \\        break :operand runtime;
        \\    });
        \\    var assigned: u8 = 7;
        \\    assigned = @intCast(operand: {
        \\        evaluations = evaluations * 10 + 2;
        \\        break :operand runtime;
        \\    });
        \\    const invalid: u8 = @intCast(@as(u16, 256));
        \\    return struct {
        \\        declared: @TypeOf(declared),
        \\        assigned: @TypeOf(assigned),
        \\        unknown: [declared + assigned]u8,
        \\        invalid: [invalid]u8,
        \\        evaluations: [evaluations]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "declared", .kind = .Field, .detail = "u8" },
        .{ .label = "assigned", .kind = .Field, .detail = "u8" },
        .{ .label = "unknown", .kind = .Field, .detail = "[?]u8" },
        .{ .label = "invalid", .kind = .Field, .detail = "[?]u8" },
        .{ .label = "evaluations", .kind = .Field, .detail = "[12]u8" },
    });
}

test "comptime interpreter coerces explicitly typed local declarations" {
    try testCompletion(
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const small: u8 = 4;
        \\    const widened: usize = small;
        \\    return struct { items: [widened]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
    });

    try testCompletion(
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const text: []const u8 = "accepted";
        \\    return if (text.len == 8)
        \\        struct { accepted: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "accepted", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const T: type = 4;
        \\    return if (@TypeOf(T) == type)
        \\        struct { accepted: u8 }
        \\    else
        \\        struct { leaked: u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "accepted", .kind = .Field, .detail = "u8" },
    });
}

test "comptime interpreter validates explicitly typed array declarations" {
    try testCompletion(
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const small: u8 = 4;
        \\    const values: [1]usize = .{small};
        \\    return struct { items: [if (@TypeOf(values[0]) == usize) values[0] else 99]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
    });

    try testCompletion(
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const values: [1]u16 = .{"rejected"};
        \\    return if (@TypeOf(values[0]) == u16)
        \\        struct { accepted: u8 }
        \\    else
        \\        struct { leaked: u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "accepted", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const values: [2]u16 = .{1};
        \\    return if (@TypeOf(values) == [2]u16)
        \\        struct { accepted: u8 }
        \\    else
        \\        struct { leaked: u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "accepted", .kind = .Field, .detail = "u8" },
    });
}

test "comptime interpreter validates explicitly typed struct declarations" {
    try testCompletion(
        \\const Config = struct { capacity: usize };
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const small: u8 = 4;
        \\    const config: Config = .{ .capacity = small };
        \\    return struct { items: [if (@TypeOf(config.capacity) == usize) config.capacity else 99]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
    });

    try testCompletion(
        \\const Config = struct { text: []const u8 };
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const config: Config = .{ .text = "accepted" };
        \\    return if (@TypeOf(config.text) == []const u8 and config.text.len == 8)
        \\        struct { accepted: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "accepted", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\const Config = struct { capacity: u16, enabled: bool };
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const config: Config = .{ .capacity = "rejected", .enabled = true };
        \\    return if (@TypeOf(config.capacity) == u16 and config.enabled)
        \\        struct { accepted: u8 }
        \\    else
        \\        struct { leaked: u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "accepted", .kind = .Field, .detail = "u8" },
    });
}

test "comptime interpreter validates explicitly typed union declarations" {
    try testCompletion(
        \\const Value = union(enum) { count: usize, empty };
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const small: u8 = 4;
        \\    const value: Value = .{ .count = small };
        \\    return switch (value) {
        \\        .count => |count| struct { items: [if (@TypeOf(count) == usize) count else 99]u8 },
        \\        .empty => struct { fallback: u8 },
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
    });

    try testCompletion(
        \\const Value = union(enum) { text: []const u8, empty };
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const value: Value = .{ .text = "accepted" };
        \\    return switch (value) {
        \\        .text => |text| if (@TypeOf(text) == []const u8 and text.len == 8)
        \\            struct { accepted: u8 }
        \\        else
        \\            struct { fallback: u8 },
        \\        .empty => struct { fallback: u8 },
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "accepted", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\const Value = union(enum) { count: u16, empty };
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const value: Value = .{ .count = "rejected" };
        \\    return switch (value) {
        \\        .count => |count| if (@TypeOf(count) == u16)
        \\            struct { accepted: u8 }
        \\        else
        \\            struct { leaked: u8 },
        \\        .empty => struct { fallback: u8 },
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "accepted", .kind = .Field, .detail = "u8" },
    });
}

test "comptime interpreter coerces typed aggregate destructuring declarations" {
    try testCompletion(
        \\const Config = struct { capacity: usize };
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const small: u8 = 4;
        \\    const values: [1]usize, const config: Config = .{ .{small}, .{ .capacity = small } };
        \\    return struct {
        \\        items: [if (@TypeOf(values[0]) == usize and @TypeOf(config.capacity) == usize)
        \\            values[0] + config.capacity
        \\        else
        \\            99]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[8]u8" },
    });

    try testCompletion(
        \\const Value = union(enum) { count: usize, empty };
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const small: u8 = 4;
        \\    const value: Value, const enabled: bool = .{ .{ .count = small }, true };
        \\    return switch (value) {
        \\        .count => |count| if (@TypeOf(count) == usize and enabled)
        \\            struct { items: [count]u8 }
        \\        else
        \\            struct { leaked: u8 },
        \\        .empty => struct { fallback: u8 },
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
    });
}

test "comptime interpreter coerces typed aggregate reassignments" {
    try testCompletion(
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const small: u8 = 4;
        \\    var values: [1]usize = undefined;
        \\    values = .{small};
        \\    return struct { items: [if (@TypeOf(values[0]) == usize) values[0] else 99]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
    });

    try testCompletion(
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const small: u8 = 4;
        \\    var values: [1]usize = undefined;
        \\    const pointer = &values;
        \\    pointer.* = .{small};
        \\    return struct { items: [if (@TypeOf(values[0]) == usize) values[0] else 99]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
    });

    try testCompletion(
        \\const Config = struct { capacity: usize };
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const small: u8 = 4;
        \\    var config = Config{ .capacity = 0 };
        \\    config = .{ .capacity = small };
        \\    return struct { items: [if (@TypeOf(config.capacity) == usize) config.capacity else 99]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
    });

    try testCompletion(
        \\const Value = union(enum) { count: usize, empty };
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const small: u8 = 4;
        \\    var value = Value{ .empty = {} };
        \\    value = .{ .count = small };
        \\    return switch (value) {
        \\        .count => |count| struct { items: [if (@TypeOf(count) == usize) count else 99]u8 },
        \\        .empty => struct { fallback: u8 },
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
    });
}

test "comptime interpreter coerces typed aggregate destructuring reassignments" {
    try testCompletion(
        \\const Config = struct { capacity: usize };
        \\const Value = union(enum) { count: usize, empty };
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const small: u8 = 4;
        \\    var values: [1]usize = undefined;
        \\    var config = Config{ .capacity = 0 };
        \\    var value = Value{ .empty = {} };
        \\    values, config, value = .{ .{small}, .{ .capacity = small }, .{ .count = small } };
        \\    return switch (value) {
        \\        .count => |count| struct {
        \\            items: [if (@TypeOf(values[0]) == usize and
        \\                @TypeOf(config.capacity) == usize and @TypeOf(count) == usize)
        \\                values[0] + config.capacity + count
        \\            else
        \\                99]u8,
        \\        },
        \\        .empty => struct { fallback: u8 },
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[12]u8" },
    });
}

test "comptime interpreter coerces nested aggregate result locations" {
    try testCompletion(
        \\const Config = struct { capacity: usize };
        \\const Value = union(enum) { count: usize, empty };
        \\const State = struct { values: [1]usize, config: Config, value: Value };
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const small: u8 = 4;
        \\    const state: State = .{
        \\        .values = .{small},
        \\        .config = .{ .capacity = small },
        \\        .value = .{ .count = small },
        \\    };
        \\    return switch (state.value) {
        \\        .count => |count| struct {
        \\            items: [if (@TypeOf(state.values[0]) == usize and
        \\                @TypeOf(state.config.capacity) == usize and @TypeOf(count) == usize)
        \\                state.values[0] + state.config.capacity + count
        \\            else
        \\                99]u8,
        \\        },
        \\        .empty => struct { fallback: u8 },
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[12]u8" },
    });

    try testCompletion(
        \\const Config = struct { capacity: usize };
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const small: u8 = 4;
        \\    var configs: [1]Config = undefined;
        \\    configs = .{.{ .capacity = small }};
        \\    return struct {
        \\        items: [if (@TypeOf(configs[0].capacity) == usize) configs[0].capacity else 99]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
    });

    try testCompletion(
        \\const Config = struct { capacity: usize };
        \\const Value = union(enum) { count: usize, empty };
        \\const State = struct { values: [1]usize, config: Config, value: Value };
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const small: u8 = 4;
        \\    var state = State{
        \\        .values = undefined,
        \\        .config = .{ .capacity = 0 },
        \\        .value = .{ .empty = {} },
        \\    };
        \\    state = .{
        \\        .values = .{small},
        \\        .config = .{ .capacity = small },
        \\        .value = .{ .count = small },
        \\    };
        \\    return switch (state.value) {
        \\        .count => |count| struct {
        \\            items: [if (@TypeOf(state.values[0]) == usize and
        \\                @TypeOf(state.config.capacity) == usize and @TypeOf(count) == usize)
        \\                state.values[0] + state.config.capacity + count
        \\            else
        \\                99]u8,
        \\        },
        \\        .empty => struct { fallback: u8 },
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[12]u8" },
    });
}

test "comptime interpreter coerces grouped aggregate result locations" {
    try testCompletion(
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const small: u8 = 4;
        \\    const declared: [1]usize = (.{small});
        \\    var assigned: [1]usize = undefined;
        \\    assigned = (.{small});
        \\    return struct {
        \\        items: [if (@TypeOf(declared[0]) == usize and @TypeOf(assigned[0]) == usize)
        \\            declared[0] + assigned[0]
        \\        else
        \\            99]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[8]u8" },
    });

    try testCompletion(
        \\const Config = struct { capacity: usize };
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const small: u8 = 4;
        \\    const declared: [1]usize, const declared_config: Config =
        \\        (.{ .{small}, .{ .capacity = small } });
        \\    var assigned: [1]usize = undefined;
        \\    var assigned_config = Config{ .capacity = 0 };
        \\    assigned, assigned_config = (.{ .{small}, .{ .capacity = small } });
        \\    return struct {
        \\        items: [if (@TypeOf(declared[0]) == usize and
        \\            @TypeOf(declared_config.capacity) == usize and
        \\            @TypeOf(assigned[0]) == usize and
        \\            @TypeOf(assigned_config.capacity) == usize)
        \\            declared[0] + declared_config.capacity + assigned[0] + assigned_config.capacity
        \\        else
        \\            99]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[16]u8" },
    });
}

test "comptime interpreter coerces conditional aggregate result locations" {
    try testCompletion(
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const small: u8 = 4;
        \\    const declared: [1]usize = if (marker == 1) .{small} else .{9};
        \\    var assigned: [1]usize = undefined;
        \\    assigned = if (marker != 1) .{9} else .{small};
        \\    return struct {
        \\        items: [if (@TypeOf(declared[0]) == usize and @TypeOf(assigned[0]) == usize)
        \\            declared[0] + assigned[0]
        \\        else
        \\            99]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[8]u8" },
    });

    try testCompletion(
        \\const Config = struct { capacity: usize };
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const small: u8 = 4;
        \\    var values: [1]usize = undefined;
        \\    var config = Config{ .capacity = 0 };
        \\    values, config = if (marker == 1)
        \\        .{ .{small}, .{ .capacity = small } }
        \\    else
        \\        .{ .{9}, .{ .capacity = 9 } };
        \\    return struct {
        \\        items: [if (@TypeOf(values[0]) == usize and @TypeOf(config.capacity) == usize)
        \\            values[0] + config.capacity
        \\        else
        \\            99]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[8]u8" },
    });
}

test "comptime interpreter coerces switched aggregate result locations" {
    try testCompletion(
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const small: u8 = 4;
        \\    const declared: [1]usize = switch (marker) {
        \\        1 => .{small},
        \\        else => .{9},
        \\    };
        \\    var assigned: [1]usize = undefined;
        \\    assigned = switch (marker) {
        \\        0 => .{9},
        \\        else => .{small},
        \\    };
        \\    return struct {
        \\        items: [if (@TypeOf(declared[0]) == usize and @TypeOf(assigned[0]) == usize)
        \\            declared[0] + assigned[0]
        \\        else
        \\            99]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[8]u8" },
    });

    try testCompletion(
        \\const Config = struct { capacity: usize };
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const small: u8 = 4;
        \\    var values: [1]usize = undefined;
        \\    var config = Config{ .capacity = 0 };
        \\    values, config = switch (marker) {
        \\        1 => .{ .{small}, .{ .capacity = small } },
        \\        else => .{ .{9}, .{ .capacity = 9 } },
        \\    };
        \\    return struct {
        \\        items: [if (@TypeOf(values[0]) == usize and @TypeOf(config.capacity) == usize)
        \\            values[0] + config.capacity
        \\        else
        \\            99]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[8]u8" },
    });
}

test "comptime interpreter coerces orelse aggregate result locations" {
    try testCompletion(
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const small: u8 = 4;
        \\    const missing: ?[1]usize = null;
        \\    const declared: [1]usize = missing orelse .{small};
        \\    var assigned: [1]usize = undefined;
        \\    assigned = missing orelse .{small};
        \\    return struct {
        \\        items: [if (@TypeOf(declared[0]) == usize and @TypeOf(assigned[0]) == usize)
        \\            declared[0] + assigned[0]
        \\        else
        \\            99]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[8]u8" },
    });
}

test "comptime interpreter promotes typed values to optionals" {
    try testCompletion(
        \\const Config = struct { capacity: usize };
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const small: u8 = 4;
        \\    const optional_scalar: ?usize = small;
        \\    const optional_values: ?[1]usize = .{small};
        \\    const optional_config: ?Config = .{ .capacity = small };
        \\    const copied_scalar: ?usize = optional_scalar;
        \\    const absent_scalar: ?usize = null;
        \\    const scalar = optional_scalar orelse 99;
        \\    const values = optional_values orelse .{9};
        \\    const config = optional_config orelse .{ .capacity = 9 };
        \\    const copied = copied_scalar orelse 99;
        \\    const absent = absent_scalar orelse 5;
        \\    return struct {
        \\        promoted_items: [scalar + values[0] + config.capacity]u8,
        \\        copied_items: [copied]u8,
        \\        absent_items: [absent]u8,
        \\        typed_items: [if (@TypeOf(scalar) == usize and @TypeOf(values[0]) == usize and
        \\            @TypeOf(config.capacity) == usize and @TypeOf(copied) == usize)
        \\            1
        \\        else
        \\            99]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "promoted_items", .kind = .Field, .detail = "[12]u8" },
        .{ .label = "copied_items", .kind = .Field, .detail = "[4]u8" },
        .{ .label = "absent_items", .kind = .Field, .detail = "[5]u8" },
        .{ .label = "typed_items", .kind = .Field, .detail = "[1]u8" },
    });
}

test "comptime interpreter promotes call boundary values to optionals" {
    try testCompletion(
        \\const Config = struct { capacity: usize };
        \\fn parameterCapacity(comptime config: ?Config) usize {
        \\    const resolved = config orelse .{ .capacity = 9 };
        \\    return if (@TypeOf(resolved.capacity) == usize) resolved.capacity else 99;
        \\}
        \\fn returnedConfig(comptime capacity: u8) ?Config {
        \\    return if (capacity == 4)
        \\        .{ .capacity = capacity }
        \\    else
        \\        .{ .capacity = 9 };
        \\}
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const small: u8 = 4;
        \\    const parameter_value = parameterCapacity(if (small == 4)
        \\        .{ .capacity = small }
        \\    else
        \\        .{ .capacity = 9 });
        \\    const returned_value = (returnedConfig(small) orelse
        \\        .{ .capacity = 9 }).capacity;
        \\    return struct {
        \\        parameter_items: [parameter_value]u8,
        \\        returned_items: [returned_value]u8,
        \\        typed_items: [if (@TypeOf(parameter_value) == usize and
        \\            @TypeOf(returned_value) == usize)
        \\            1
        \\        else
        \\            99]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "parameter_items", .kind = .Field, .detail = "[4]u8" },
        .{ .label = "returned_items", .kind = .Field, .detail = "[4]u8" },
        .{ .label = "typed_items", .kind = .Field, .detail = "[1]u8" },
    });
}

test "comptime interpreter promotes explicit coercions to optionals" {
    try testCompletion(
        \\const Config = struct { capacity: usize };
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const small: u8 = 4;
        \\    const optional_scalar = @as(?usize, small);
        \\    const optional_values = @as(?[1]usize, if (small == 4)
        \\        .{small}
        \\    else
        \\        .{9});
        \\    const optional_config = @as(?Config, if (small == 4)
        \\        .{ .capacity = small }
        \\    else
        \\        .{ .capacity = 9 });
        \\    const scalar = optional_scalar orelse 99;
        \\    const values = optional_values orelse .{9};
        \\    const config = optional_config orelse .{ .capacity = 9 };
        \\    return struct {
        \\        items: [if (@TypeOf(scalar) == usize and @TypeOf(values[0]) == usize and
        \\            @TypeOf(config.capacity) == usize)
        \\            scalar + values[0] + config.capacity
        \\        else
        \\            99]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[12]u8" },
    });
}

test "comptime interpreter promotes block results to optionals" {
    try testCompletion(
        \\const Config = struct { capacity: usize };
        \\fn Select() type {
        \\    var executions: usize = 0;
        \\    const small: u8 = 4;
        \\    const optional_values: ?[1]usize = values: {
        \\        executions += 1;
        \\        break :values .{small};
        \\    };
        \\    const optional_config: ?Config = config: {
        \\        executions += 1;
        \\        break :config .{ .capacity = small };
        \\    };
        \\    const values = optional_values orelse .{9};
        \\    const config = optional_config orelse .{ .capacity = 9 };
        \\    return struct {
        \\        items: [if (@TypeOf(values[0]) == usize and @TypeOf(config.capacity) == usize)
        \\            values[0] + config.capacity + executions
        \\        else
        \\            99]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[10]u8" },
    });
}

test "comptime interpreter promotes loop results to optionals" {
    try testCompletion(
        \\const Config = struct { capacity: usize };
        \\fn Select() type {
        \\    var executions: usize = 0;
        \\    const small: u8 = 4;
        \\    const optional_values: ?[1]usize = for (0..1) |_| {
        \\        executions += 1;
        \\        break .{small};
        \\    } else .{9};
        \\    var running = true;
        \\    const optional_config: ?Config = while (running) {
        \\        executions += 1;
        \\        running = false;
        \\        break .{ .capacity = small };
        \\    } else .{ .capacity = 9 };
        \\    const values = optional_values orelse .{9};
        \\    const config = optional_config orelse .{ .capacity = 9 };
        \\    return struct {
        \\        items: [if (@TypeOf(values[0]) == usize and @TypeOf(config.capacity) == usize)
        \\            values[0] + config.capacity + executions
        \\        else
        \\            99]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[10]u8" },
    });
}

test "comptime interpreter promotes comptime expression results to optionals" {
    try testCompletion(
        \\const Config = struct { capacity: usize };
        \\fn Select() type {
        \\    var executions: usize = 0;
        \\    const small: u8 = 4;
        \\    const optional_values: ?[1]usize = comptime values: {
        \\        executions += 1;
        \\        break :values if (small == 4) .{small} else .{9};
        \\    };
        \\    const optional_config: ?Config = comptime config: {
        \\        executions += 1;
        \\        break :config if (small == 4) .{ .capacity = small } else .{ .capacity = 9 };
        \\    };
        \\    const values = optional_values orelse .{9};
        \\    const config = optional_config orelse .{ .capacity = 9 };
        \\    return struct {
        \\        items: [if (@TypeOf(values[0]) == usize and @TypeOf(config.capacity) == usize)
        \\            values[0] + config.capacity + executions
        \\        else
        \\            99]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[10]u8" },
    });
}

test "comptime interpreter coerces assignments to typed locals" {
    try testCompletion(
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const small: u8 = 4;
        \\    var widened: usize = 0;
        \\    widened = small;
        \\    return struct { items: [if (@TypeOf(widened) == usize) widened else 99]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
    });

    try testCompletion(
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const small: u8 = 4;
        \\    var widened: usize = 0;
        \\    const pointer = &widened;
        \\    pointer.* = small;
        \\    return struct { items: [if (@TypeOf(widened) == usize) widened else 99]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
    });

    try testCompletion(
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    var text: []const u8 = "";
        \\    text = "accepted";
        \\    return if (@TypeOf(text) == []const u8 and text.len == 8)
        \\        struct { accepted: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "accepted", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    var value: u16 = 0;
        \\    value = "rejected";
        \\    return if (@TypeOf(value) == u16)
        \\        struct { accepted: u8 }
        \\    else
        \\        struct { leaked: u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "accepted", .kind = .Field, .detail = "u8" },
    });
}

test "comptime interpreter coerces assignments to typed aggregate elements" {
    try testCompletion(
        \\const Config = struct { capacity: usize };
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const small: u8 = 4;
        \\    var config = Config{ .capacity = 0 };
        \\    config.capacity = small;
        \\    return struct { items: [if (@TypeOf(config.capacity) == usize) config.capacity else 99]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
    });

    try testCompletion(
        \\const Config = struct { capacity: usize };
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const small: u8 = 4;
        \\    var config = Config{ .capacity = 0 };
        \\    const pointer = &config.capacity;
        \\    pointer.* = small;
        \\    return struct { items: [if (@TypeOf(config.capacity) == usize) config.capacity else 99]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
    });

    try testCompletion(
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const small: u8 = 4;
        \\    var values: [1]usize = undefined;
        \\    values[0] = small;
        \\    return struct { items: [if (@TypeOf(values[0]) == usize) values[0] else 99]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
    });

    try testCompletion(
        \\const Config = struct { capacity: u16 };
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    var config = Config{ .capacity = 0 };
        \\    config.capacity = "rejected";
        \\    return if (@TypeOf(config.capacity) == u16)
        \\        struct { accepted: u8 }
        \\    else
        \\        struct { leaked: u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "accepted", .kind = .Field, .detail = "u8" },
    });
}

test "comptime interpreter coerces subobject aggregate assignments" {
    const cases = [_]struct { setup: []const u8, target: []const u8, initializer: []const u8, value: []const u8, sibling: []const u8 }{
        .{
            .setup = "var state = struct { values: [1]usize, sibling: usize }{ .values = .{0}, .sibling = 7 };",
            .target = "state.values",
            .initializer = ".{small}",
            .value = "state.values[0]",
            .sibling = "state.sibling",
        },
        .{
            .setup = "var state: [2]Config = .{ .{ .capacity = 0 }, .{ .capacity = 7 } };",
            .target = "state[0]",
            .initializer = ".{ .capacity = small }",
            .value = "state[0].capacity",
            .sibling = "state[1].capacity",
        },
        .{
            .setup = "var state: struct { ?Config, usize } = .{ null, 7 };",
            .target = "state.@\"0\"",
            .initializer = ".{ .capacity = small }",
            .value = "state.@\"0\".?.capacity",
            .sibling = "state.@\"1\"",
        },
        .{
            .setup = "var state: struct { values: ?[1]usize, sibling: usize } = .{ .values = .{0}, .sibling = 7 };",
            .target = "state.values.?",
            .initializer = ".{small}",
            .value = "state.values.?[0]",
            .sibling = "state.sibling",
        },
        .{
            .setup = "var state = struct { value: ?usize, sibling: usize }{ .value = null, .sibling = 7 };",
            .target = "state.value",
            .initializer = "small",
            .value = "state.value.?",
            .sibling = "state.sibling",
        },
        .{
            .setup = "var state = struct { value: union(enum) { count: usize, empty }, sibling: usize }{ .value = .{ .empty = {} }, .sibling = 7 };",
            .target = "state.value",
            .initializer = ".{ .count = small }",
            .value = "state.value.count",
            .sibling = "state.sibling",
        },
    };
    for (cases) |case| {
        for ([_]bool{ false, true }) |through_pointer| {
            const source = try std.fmt.allocPrint(allocator,
                \\const Config = struct {{ capacity: usize }};
                \\fn Select() type {{
                \\    const small: u8 = 4;
                \\    var executions: usize = 0;
                \\    {s}
                \\    {s}{s}{s}
                \\    {s} = result: {{
                \\        executions += 1;
                \\        break :result if (small == 4) {s} else {s};
                \\    }};
                \\    const value = {s};
                \\    return struct {{
                \\        items: [if (@TypeOf(value) == usize) value else 99]u8,
                \\        executions: [executions]u8,
                \\        sibling: [{s}]u8,
                \\    }};
                \\}}
                \\const selected: Select() = undefined;
                \\const field = selected.<cursor>
            , .{
                case.setup,
                if (through_pointer) "const pointer = &" else "",
                if (through_pointer) case.target else "",
                if (through_pointer) ";" else "",
                if (through_pointer) "pointer.*" else case.target,
                case.initializer,
                case.initializer,
                case.value,
                case.sibling,
            });
            defer allocator.free(source);
            errdefer std.debug.print("subobject assignment source:\n{s}\n", .{source});
            try testCompletion(source, &.{
                .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
                .{ .label = "executions", .kind = .Field, .detail = "[1]u8" },
                .{ .label = "sibling", .kind = .Field, .detail = "[7]u8" },
            });
        }
    }
}

test "comptime interpreter preserves types after invalid subobject assignments" {
    for ([_][]const u8{ ".{\"invalid\"}", ".{1, 2}", "[_]u8{4}" }) |initializer| {
        for ([_]bool{ false, true }) |through_pointer| {
            const source = try std.fmt.allocPrint(allocator,
                \\fn Select() type {{
                \\    var state: struct {{ values: [1]usize, sibling: usize }} = .{{ .values = .{{0}}, .sibling = 7 }};
                \\    {s}
                \\    {s} = {s};
                \\    return struct {{
                \\        typed: [if (@TypeOf(state.values[0]) == usize) 1 else 99]u8,
                \\        items: [state.values[0]]u8,
                \\        sibling: [state.sibling]u8,
                \\    }};
                \\}}
                \\const selected: Select() = undefined;
                \\const field = selected.<cursor>
            , .{
                if (through_pointer) "const pointer = &state.values;" else "",
                if (through_pointer) "pointer.*" else "state.values",
                initializer,
            });
            defer allocator.free(source);
            errdefer std.debug.print("invalid subobject assignment source:\n{s}\n", .{source});
            try testCompletion(source, &.{
                .{ .label = "typed", .kind = .Field, .detail = "[1]u8" },
                .{ .label = "items", .kind = .Field, .detail = "[?]u8" },
                .{ .label = "sibling", .kind = .Field, .detail = "[7]u8" },
            });
        }
    }
}

test "comptime interpreter coerces subobject destructuring assignments" {
    try testCompletion(
        \\const Config = struct { capacity: usize };
        \\fn Select() type {
        \\    const small: u8 = 4;
        \\    var state = struct { values: [1]usize, config: ?Config }{ .values = .{0}, .config = null };
        \\    const pointer = &state.config;
        \\    state.values, pointer.* = .{ .{small}, .{ .capacity = small } };
        \\    const capacity = state.config.?.capacity;
        \\    return struct {
        \\        items: [if (@TypeOf(state.values[0]) == usize and @TypeOf(capacity) == usize)
        \\            state.values[0] + capacity
        \\        else
        \\            99]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[8]u8" },
    });
}

test "source union typed comptime arguments validate runtime unknown payloads" {
    try testCompletion(
        \\const U = union(enum) { count: u16, empty };
        \\var runtime_u8: u8 = undefined;
        \\fn Select(comptime value: U) type {
        \\    return switch (value) {
        \\        .count => struct { accepted: u8 },
        \\        .empty => struct { fallback: u8 },
        \\    };
        \\}
        \\const selected: Select(U{ .count = runtime_u8 }) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "accepted", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\const U = union(enum) { count: u16, empty };
        \\var runtime_bool: bool = undefined;
        \\fn Select(comptime value: U) type {
        \\    return switch (value) {
        \\        .count => struct { accepted: u8 },
        \\        .empty => struct { fallback: u8 },
        \\    };
        \\}
        \\const selected: Select(U{ .count = runtime_bool }) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "accepted", .kind = .Field, .detail = "u8" },
        .{ .label = "fallback", .kind = .Field, .detail = "u8" },
    });
}

test "generic function reflecting comptime container constructors" {
    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const S = @Struct(.auto, null, &.{"value"}, &.{T}, &.{.{}});
        \\    const U = @Union(.auto, null, &.{"enabled"}, &.{bool}, &.{.{}});
        \\    return if (@hasField(S, "value") and @FieldType(S, "value") == T and
        \\        @hasField(U, "enabled") and @FieldType(U, "enabled") == bool)
        \\        struct { reflected: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "reflected", .kind = .Field, .detail = "u16" },
    });
}

test "generic function with nested comptime Vector mutations" {
    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    var total: usize = 1;
        \\    const V = @Vector(len: {
        \\        total += 1;
        \\        break :len 4;
        \\    }, child: {
        \\        total *= 2;
        \\        break :child T;
        \\    });
        \\    return if (V == @Vector(4, u8))
        \\        struct { order: [total]V }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u8) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "order", .kind = .Field, .detail = "[4]@Vector(4,u8)" },
    });
}

test "generic function with comptime Enum type constructor" {
    try testCompletion(
        \\fn Mode(comptime Tag: type) type {
        \\    return @Enum(Tag, .exhaustive, &.{ "low", "high" }, &.{ 1, 7 });
        \\}
        \\const value: Mode(u8) = undefined;
        \\const field = value.<cursor>
    , &.{
        .{ .label = "low", .kind = .Field, .detail = "1" },
        .{ .label = "high", .kind = .Field, .detail = "7" },
    });

    try testCompletion(
        \\fn Mode(comptime Tag: type, comptime high: Tag) type {
        \\    const names = &.{ "low", "high" };
        \\    const values = &.{ 1, high };
        \\    return @Enum(Tag, .exhaustive, names, values);
        \\}
        \\const value: Mode(u16, 9) = undefined;
        \\const field = value.<cursor>
    , &.{
        .{ .label = "low", .kind = .Field, .detail = "1" },
        .{ .label = "high", .kind = .Field, .detail = "9" },
    });

    try testCompletion(
        \\fn Mode(comptime Tag: type) type {
        \\    return @Enum(Tag, .nonexhaustive, &.{"known"}, &.{1});
        \\}
        \\const value: Mode(u8) = undefined;
        \\const field = value.<cursor>
    , &.{
        .{ .label = "known", .kind = .Field, .detail = "1" },
    });
}

test "generic function with comptime generated Enum values" {
    try testCompletion(
        \\fn Select(comptime Tag: type) type {
        \\    const Mode = @Enum(Tag, .exhaustive, &.{ "low", "high" }, &.{ 1, 7 });
        \\    const mode = Mode.high;
        \\    const from_int: Mode = @enumFromInt(7);
        \\    return switch (mode) {
        \\        .high => if (@intFromEnum(mode) == 7 and @tagName(mode)[0] == 'h' and
        \\            @intFromEnum(from_int) == 7)
        \\            struct { matched: Tag }
        \\        else
        \\            struct { fallback: u8 },
        \\        else => struct { fallback: u8 },
        \\    };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });
}

test "generic function with comptime std meta enum tag" {
    const enum_types = [_][]const u8{
        "enum(T) { value = 1 }",
        "@Enum(T, .exhaustive, &.{\"value\"}, &.{1})",
    };
    for (enum_types) |enum_type| {
        const source = try std.fmt.allocPrint(allocator,
            \\const std = @import("std");
            \\fn Select(comptime T: type) type {{
            \\    const E = {s};
            \\    return if (std.meta.Tag(E) == T)
            \\        struct {{ matched: T }}
            \\    else
            \\        struct {{ fallback: u8 }};
            \\}}
            \\const selected: Select(u13) = undefined;
            \\const field = selected.<cursor>
        , .{enum_type});
        defer allocator.free(source);
        try testCompletion(source, &.{
            .{ .label = "matched", .kind = .Field, .detail = "u13" },
        });
    }

    try testCompletion(
        \\const std = @import("std");
        \\fn Select(comptime T: type) type {
        \\    const U = union(enum) { value: T };
        \\    const Tag = std.meta.Tag(U);
        \\    return if (std.meta.Tag(Tag) == u0)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u13) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u13" },
    });

    try testCompletion(
        \\const std = @import("std");
        \\fn Select(comptime T: type) type {
        \\    const E = enum {};
        \\    return if (std.meta.Tag(E) == u0)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u13) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u13" },
    });
}

test "generic function with comptime std meta type utilities" {
    try testCompletion(
        \\const std = @import("std");
        \\fn Select(comptime T: type) type {
        \\    const S = struct { value: T };
        \\    const Child = std.meta.Child(@Vector(4, *S));
        \\    const Elem = std.meta.Elem(*@Vector(4, *S));
        \\    const P = @Struct(.@"packed", null, &.{"value"}, &.{u8}, &.{.{} });
        \\    const U = @Union(.@"extern", null, &.{"value"}, &.{T}, &.{.{} });
        \\    return if (Child == *S and Elem == *S and std.meta.containerLayout(P) == .@"packed" and
        \\        std.meta.containerLayout(U) == .@"extern")
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });

    try testCompletion(
        \\const std = @import("std");
        \\fn Select(comptime T: type) type {
        \\    const S = struct { value: T };
        \\    return if (std.meta.alignment(*align(32) S) == 32 and
        \\        std.meta.alignment(?*align(32) S) == 32 and std.meta.alignment(*u16) == 2)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });
}

test "generic function with comptime std meta FieldEnum" {
    try testCompletion(
        \\const std = @import("std");
        \\fn Select(comptime T: type) type {
        \\    const S = struct { value: T, enabled: bool };
        \\    const Fields = std.meta.FieldEnum(S);
        \\    return if (@typeInfo(Fields).@"enum".fields.len == 2 and
        \\        @tagName(Fields.value)[0] == 'v' and @intFromEnum(Fields.enabled) == 1)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });

    try testCompletion(
        \\const std = @import("std");
        \\fn Select(comptime T: type) type {
        \\    const Tag = enum { value, enabled };
        \\    const U = union(Tag) { value: T, enabled: bool };
        \\    const Untagged = union { value: T, enabled: bool };
        \\    const Generated = std.meta.FieldEnum(Untagged);
        \\    return if (std.meta.FieldEnum(U) == Tag and @intFromEnum(Generated.enabled) == 1)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });
}

test "generic function with comptime std meta field index" {
    try testCompletion(
        \\const std = @import("std");
        \\fn Select(comptime T: type) type {
        \\    const S = @Struct(.auto, null, &.{ "value", "enabled" }, &.{ T, bool }, &.{ .{}, .{} });
        \\    const U = @Union(.auto, null, &.{ "payload", "empty" }, &.{ T, void }, &.{ .{}, .{} });
        \\    return if (std.meta.fieldIndex(S, "value").? == 0 and
        \\        std.meta.fieldIndex(U, "empty").? == 1 and
        \\        std.meta.fieldIndex(S, "missing") == null)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });
}

test "generic function with comptime std meta fields" {
    try testCompletion(
        \\const std = @import("std");
        \\fn Select(comptime T: type) type {
        \\    const S = @Struct(.auto, null, &.{ "value", "enabled" }, &.{ T, bool }, &.{ .{}, .{} });
        \\    const fields = std.meta.fields(S);
        \\    return if (fields.len == 2 and fields[0].name[0] == 'v' and fields[0].type == T and
        \\        fields[1].name[0] == 'e' and fields[1].type == bool)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });

    try testCompletion(
        \\const std = @import("std");
        \\fn Select(comptime T: type) type {
        \\    const U = @Union(.auto, null, &.{ "payload", "empty" }, &.{ T, void }, &.{ .{}, .{} });
        \\    const E = @Enum(u8, .exhaustive, &.{ "low", "high" }, &.{ 4, 9 });
        \\    const union_fields = std.meta.fields(U);
        \\    const enum_fields = std.meta.fields(E);
        \\    const errors = std.meta.fields(error{ Oops, Failed });
        \\    return if (union_fields.len == 2 and union_fields[0].type == T and
        \\        enum_fields[1].value == 9 and errors.len == 2 and errors[0].name[0] == 'O')
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });
}

test "generic function with comptime std meta declarations" {
    try testCompletion(
        \\const std = @import("std");
        \\fn Select(comptime T: type) type {
        \\    const S = struct {
        \\        pub const Alpha = T;
        \\        const hidden = false;
        \\        pub fn beta() void {}
        \\    };
        \\    const decls = std.meta.declarations(S);
        \\    const Generated = @Struct(.auto, null, &.{"value"}, &.{T}, &.{.{} });
        \\    return if (decls.len == 2 and decls[0].name[0] == 'A' and decls[1].name[0] == 'b' and
        \\        std.meta.declarations(Generated).len == 0)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });
}

test "generic function with comptime std meta DeclEnum" {
    try testCompletion(
        \\const std = @import("std");
        \\fn Select(comptime T: type) type {
        \\    const S = struct {
        \\        pub const Alpha = T;
        \\        const hidden = false;
        \\        pub fn beta() void {}
        \\    };
        \\    const Names = std.meta.DeclEnum(S);
        \\    const Generated = @Struct(.auto, null, &.{"value"}, &.{T}, &.{.{} });
        \\    const EmptyNames = std.meta.DeclEnum(Generated);
        \\    return if (Names == std.meta.DeclEnum(S) and @intFromEnum(Names.Alpha) == 0 and
        \\        @intFromEnum(Names.beta) == 1 and
        \\        @tagName(Names.beta)[0] == 'b' and std.meta.Tag(Names) == u1 and
        \\        std.meta.Tag(EmptyNames) == u0)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });
}

test "generic function with comptime std meta declaration info" {
    try testCompletion(
        \\const std = @import("std");
        \\fn Select(comptime T: type) type {
        \\    const S = struct {
        \\        pub const Alpha = T;
        \\        const hidden = false;
        \\        pub fn beta() void {}
        \\    };
        \\    const alpha = std.meta.declarationInfo(S, "Alpha");
        \\    const beta = std.meta.declarationInfo(S, "beta");
        \\    return if (alpha.name[0] == 'A' and beta.name[0] == 'b')
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });
}

test "generic function with comptime std meta field info" {
    try testCompletion(
        \\const std = @import("std");
        \\fn Select(comptime T: type) type {
        \\    const S = struct {
        \\        payload: T,
        \\        comptime enabled: bool = true,
        \\    };
        \\    const payload = std.meta.fieldInfo(S, .payload);
        \\    const enabled = std.meta.fieldInfo(S, .enabled);
        \\    return if (payload.type == T and payload.name[0] == 'p' and
        \\        !payload.is_comptime and enabled.type == bool and enabled.is_comptime)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });
}

test "generic function with comptime std meta field names" {
    try testCompletion(
        \\const std = @import("std");
        \\fn Select(comptime T: type) type {
        \\    const S = @Struct(.auto, null, &.{ "payload", "enabled" }, &.{ T, bool }, &.{ .{}, .{} });
        \\    const names = std.meta.fieldNames(S);
        \\    return if (names.len == 2 and names[0][0] == 'p' and names[0].len == 7 and
        \\        names[1][0] == 'e' and names[1].len == 7)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });
}

test "generic function with comptime std meta tags" {
    try testCompletion(
        \\const std = @import("std");
        \\fn Select(comptime T: type) type {
        \\    const E = @Enum(u8, .exhaustive, &.{ "low", "high" }, &.{ 4, 9 });
        \\    const U = union(enum) { low: T, high: bool };
        \\    const enum_tags = std.meta.tags(E);
        \\    const union_tags = std.meta.tags(std.meta.Tag(U));
        \\    const error_tags = std.meta.tags(error{ Oops, Failed });
        \\    return if (enum_tags.len == 2 and enum_tags[0] == E.low and
        \\        @intFromEnum(enum_tags[1]) == 9 and @tagName(enum_tags[1])[0] == 'h' and
        \\        union_tags.len == 2 and @intFromEnum(union_tags[1]) == 1 and
        \\        error_tags.len == 2 and error_tags[1] == error.Failed)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });
}

test "generic function with comptime std meta string to enum" {
    try testCompletion(
        \\const std = @import("std");
        \\fn Select(comptime T: type) type {
        \\    const E = @Enum(u8, .exhaustive, &.{ "low", "high" }, &.{ 4, 9 });
        \\    const found = std.meta.stringToEnum(E, "high");
        \\    const missing = std.meta.stringToEnum(E, "missing");
        \\    return if (found != null and found.? == E.high and
        \\        @intFromEnum(found.?) == 9 and @tagName(found.?)[0] == 'h' and missing == null)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });
}

test "generic function with nested comptime typeInfo mutation" {
    try testCompletion(
        \\fn Buffer(comptime T: type) type {
        \\    var total: usize = 1;
        \\    const info = @typeInfo(value: {
        \\        defer total += 1;
        \\        total *= 2;
        \\        break :value T;
        \\    });
        \\    return struct { items: [@tagName(info).len * total]u8 };
        \\}
        \\const buffer: Buffer(u16) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[9]u8" },
    });
}

test "generic function switching on comptime type info" {
    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    return if (@TypeOf(@typeInfo(T)) == @TypeOf(@typeInfo(u8)))
        \\        switch (@typeInfo(T)) {
        \\            .int => struct { matched: T },
        \\            else => struct { fallback: u8 },
        \\        }
        \\    else
        \\        struct { wrong_type: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });

    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const S = @Struct(.auto, null, &.{"value"}, &.{T}, &.{.{}});
        \\    const U = @Union(.auto, null, &.{"value"}, &.{T}, &.{.{}});
        \\    const E = @Enum(u8, .exhaustive, &.{"value"}, &.{1});
        \\    return switch (@typeInfo(S)) {
        \\        .@"struct" => switch (@typeInfo(U)) {
        \\            .@"union" => switch (@typeInfo(E)) {
        \\                .@"enum" => struct { matched: T },
        \\                else => struct { fallback: u8 },
        \\            },
        \\            else => struct { fallback: u8 },
        \\        },
        \\        else => struct { fallback: u8 },
        \\    };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });
}

test "generic function capturing comptime type info payload" {
    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    return switch (@typeInfo(T)) {
        \\        .int => |info| if (info.signedness == .signed and info.bits == 16)
        \\            struct { matched: T }
        \\        else
        \\            struct { fallback: u8 },
        \\        else => struct { fallback: u8 },
        \\    };
        \\}
        \\const selected: Select(i16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "i16" },
    });

    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    return switch (@typeInfo(*const T)) {
        \\        .pointer => |info| if (info.size == .one and info.is_const and info.child == T)
        \\            struct { matched: T }
        \\        else
        \\            struct { fallback: u8 },
        \\        else => struct { fallback: u8 },
        \\    };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });

    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const S = @Struct(.auto, null, &.{"value"}, &.{T}, &.{.{}});
        \\    return switch (@typeInfo(S)) {
        \\        .@"struct" => |info| if (info.layout == .auto and !info.is_tuple)
        \\            struct { matched: T }
        \\        else
        \\            struct { fallback: u8 },
        \\        else => struct { fallback: u8 },
        \\    };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });
}

test "generic function with comptime type info payload values" {
    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const info = @typeInfo(T).int;
        \\    return if (info.signedness == .signed and info.bits == 16)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(i16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "i16" },
    });

    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const P = @Pointer(.one, .{ .@"const" = true, .@"volatile" = true }, T, null);
        \\    const info = @typeInfo(P).pointer;
        \\    return if (info.size == .one and info.is_const and info.is_volatile and
        \\        info.child == T and !info.is_allowzero)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });

    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const array = @typeInfo([4]T).array;
        \\    const vector = @typeInfo(@Vector(8, T)).vector;
        \\    const optional = @typeInfo(?T).optional;
        \\    const error_union = @typeInfo(error{Oops}!T).error_union;
        \\    const float = @typeInfo(f32).float;
        \\    return if (array.len == 4 and array.child == T and
        \\        vector.len == 8 and vector.child == T and
        \\        optional.child == T and error_union.error_set == error{Oops} and
        \\        error_union.payload == T and float.bits == 32)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(i16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "i16" },
    });

    const cases = [_][]const u8{
        "@typeInfo(*const S).pointer.child == S",
        "@typeInfo([4]S).array.child == S",
        "@typeInfo(?S).optional.child == S",
        "@typeInfo(error{Oops}!S).error_union.payload == S",
    };
    for (cases) |condition| {
        const source = try std.fmt.allocPrint(allocator,
            \\fn Select(comptime T: type) type {{
            \\    const S = struct {{ value: T }};
            \\    return if ({s})
            \\        struct {{ matched: T }}
            \\    else
            \\        struct {{ fallback: u8 }};
            \\}}
            \\const selected: Select(u16) = undefined;
            \\const field = selected.<cursor>
        , .{condition});
        defer allocator.free(source);
        try testCompletion(source, &.{
            .{ .label = "matched", .kind = .Field, .detail = "u16" },
        });
    }
}

test "generic function with comptime pointer type info attributes" {
    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const P = @Pointer(.one, .{ .@"align" = 4, .@"addrspace" = .generic }, T, null);
        \\    const explicit = @typeInfo(P).pointer;
        \\    const implicit = @typeInfo(*T).pointer;
        \\    return if (explicit.alignment.? == 4 and explicit.address_space == .generic and
        \\        implicit.alignment == null and implicit.address_space == .generic)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });

    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const S = struct { value: T };
        \\    const info = @typeInfo(*align(4) addrspace(.generic) allowzero const volatile S).pointer;
        \\    return if (info.size == .one and info.is_const and info.is_volatile and
        \\        info.is_allowzero and info.alignment.? == 4 and
        \\        info.address_space == .generic and info.child == S)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });

    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const S = struct { value: T };
        \\    const V = @Vector(4, *S);
        \\    const info = @typeInfo(V).vector;
        \\    const Rebuilt = @Vector(info.len, info.child);
        \\    return if (info.len == 4 and info.child == *S and Rebuilt == V and
        \\        @bitSizeOf(V) == 256 and @sizeOf(V) == 32 and @alignOf(V) == 32)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });

    try testCompletion(
        \\fn Vector(comptime T: type) type {
        \\    const S = struct { value: T };
        \\    return @Vector(4, *S);
        \\}
        \\const vector: Vector(u16) = undefined;
        \\const pointer = vector[0];
        \\const field = pointer.*.<cursor>
    , &.{
        .{ .label = "value", .kind = .Field, .detail = "u16" },
    });

    try testCompletion(
        \\fn Vector(comptime T: type) type {
        \\    const S = struct { value: T };
        \\    return @Vector(4, *S);
        \\}
        \\const vector: Vector(u16) = undefined;
        \\const length = vector.<cursor>
    , &.{
        .{ .label = "len", .kind = .Field, .detail = "usize = 4" },
    });
}

test "generic function with nominal tuple type info" {
    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const S = struct { value: T };
        \\    const Tuple = @Tuple(&.{ S, u8 });
        \\    const info = @typeInfo(Tuple).@"struct";
        \\    const field = info.fields[0];
        \\    return if (info.is_tuple and info.fields.len == 2 and info.decls.len == 0 and
        \\        field.name[0] == '0' and field.type == S and !field.is_comptime and
        \\        field.default_value_ptr == null and field.alignment == null)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const result = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });
}

test "generic function with comptime type info sentinel presence" {
    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const plain_pointer = @typeInfo([*]T).pointer;
        \\    const sentinel_pointer = @typeInfo([*:0]T).pointer;
        \\    const plain_array = @typeInfo([4]T).array;
        \\    const sentinel_array = @typeInfo([4:0]T).array;
        \\    return if (plain_pointer.sentinel_ptr == null and sentinel_pointer.sentinel_ptr != null and
        \\        plain_array.sentinel_ptr == null and sentinel_array.sentinel_ptr != null)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });
}

test "generic function with comptime container type info payload values" {
    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const S = @Struct(.auto, null, &.{"value"}, &.{T}, &.{.{}});
        \\    const U = @Union(.auto, null, &.{"value"}, &.{T}, &.{.{}});
        \\    const E = @Enum(u8, .exhaustive, &.{"value"}, &.{1});
        \\    const F = @Fn(&.{T}, &.{.{}}, u8, .{ .@"callconv" = .c, .varargs = true });
        \\    const struct_info = @typeInfo(S).@"struct";
        \\    const tuple_info = @typeInfo(@Tuple(&.{T})).@"struct";
        \\    const union_info = @typeInfo(U).@"union";
        \\    const enum_info = @typeInfo(E).@"enum";
        \\    const fn_info = @typeInfo(F).@"fn";
        \\    return if (struct_info.layout == .auto and struct_info.backing_integer == null and
        \\        !struct_info.is_tuple and tuple_info.is_tuple and union_info.layout == .auto and
        \\        union_info.tag_type == null and enum_info.tag_type == u8 and
        \\        enum_info.is_exhaustive and !fn_info.is_generic and fn_info.is_var_args and
        \\        fn_info.return_type.? == u8)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });
}

test "generic function with comptime AST container type info payload values" {
    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const S = struct { value: T };
        \\    const U = union { value: T };
        \\    const E = enum(u8) { value = 1 };
        \\    const Open = enum(u8) { value = 1, _ };
        \\    const F = fn (T) u8;
        \\    const struct_info = @typeInfo(S).@"struct";
        \\    const union_info = @typeInfo(U).@"union";
        \\    const enum_info = @typeInfo(E).@"enum";
        \\    const open_info = @typeInfo(Open).@"enum";
        \\    const fn_info = @typeInfo(F).@"fn";
        \\    return if (struct_info.layout == .auto and struct_info.backing_integer == null and
        \\        !struct_info.is_tuple and union_info.layout == .auto and union_info.tag_type == null and
        \\        enum_info.tag_type == u8 and enum_info.is_exhaustive and !open_info.is_exhaustive and
        \\        !fn_info.is_generic and !fn_info.is_var_args and fn_info.return_type.? == u8)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });
}

test "generic function with comptime type info collection lengths" {
    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const S = @Struct(.auto, null, &.{ "a", "b" }, &.{ T, u8 }, &.{ .{}, .{} });
        \\    const U = @Union(.auto, null, &.{ "a", "b" }, &.{ T, u8 }, &.{ .{}, .{} });
        \\    const E = @Enum(u8, .exhaustive, &.{ "a", "b" }, &.{ 1, 2 });
        \\    const F = @Fn(&.{ T, u8 }, &.{ .{}, .{} }, void, .{});
        \\    return if (@typeInfo(S).@"struct".fields.len == 2 and
        \\        @typeInfo(U).@"union".fields.len == 2 and
        \\        @typeInfo(E).@"enum".fields.len == 2 and
        \\        @typeInfo(F).@"fn".params.len == 2)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });

    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const S = struct { a: T, b: u8 };
        \\    const U = union { a: T, b: u8 };
        \\    const E = enum { a, b };
        \\    const F = fn (T, u8) void;
        \\    return if (@typeInfo(S).@"struct".fields.len == 2 and
        \\        @typeInfo(U).@"union".fields.len == 2 and
        \\        @typeInfo(E).@"enum".fields.len == 2 and
        \\        @typeInfo(F).@"fn".params.len == 2)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });
}

test "generic function with comptime type info descriptors" {
    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const S = @Struct(.auto, null, &.{ "a", "b" }, &.{ u8, T }, &.{ .{}, .{} });
        \\    const U = @Union(.auto, null, &.{ "a", "b" }, &.{ T, u8 }, &.{ .{}, .{} });
        \\    const E = @Enum(u8, .exhaustive, &.{ "a", "b" }, &.{ 4, 9 });
        \\    const F = @Fn(&.{ *T, u16 }, &.{ .{ .@"noalias" = true }, .{} }, void, .{});
        \\    const sf = @typeInfo(S).@"struct".fields[1];
        \\    const uf = @typeInfo(U).@"union".fields[0];
        \\    const ef = @typeInfo(E).@"enum".fields[1];
        \\    const fp = @typeInfo(F).@"fn".params[0];
        \\    return if (sf.name.len == 1 and sf.name[0] == 'b' and sf.type == T and
        \\        uf.name[0] == 'a' and uf.type == T and ef.name[0] == 'b' and ef.value == 9 and
        \\        !fp.is_generic and fp.is_noalias and fp.type.? == *T)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });

    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const S = struct { a: u8, b: T };
        \\    const U = union { a: T, b: u8 };
        \\    const E = enum(u8) { a = 4, b = 9 };
        \\    const F = fn (noalias *T, u16) void;
        \\    const sf = @typeInfo(S).@"struct".fields[1];
        \\    const uf = @typeInfo(U).@"union".fields[0];
        \\    const ef = @typeInfo(E).@"enum".fields[1];
        \\    const fp = @typeInfo(F).@"fn".params[0];
        \\    return if (sf.name[0] == 'b' and sf.type == T and uf.name[0] == 'a' and uf.type == T and
        \\        ef.name[0] == 'b' and ef.value == 9 and !fp.is_generic and fp.is_noalias and
        \\        fp.type.? == *T)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });
}

test "generic function with comptime generic parameter descriptors" {
    try testCompletion(
        \\fn generic(a: anytype, comptime b: anytype, comptime T: type, value: T) void {
        \\    _ = a;
        \\    _ = b;
        \\    _ = value;
        \\}
        \\fn Select(comptime Result: type) type {
        \\    const info = @typeInfo(@TypeOf(generic)).@"fn";
        \\    return if (info.is_generic and info.params[0].is_generic and info.params[0].type == null and
        \\        info.params[1].is_generic and info.params[1].type == null and
        \\        !info.params[2].is_generic and info.params[2].type.? == type and
        \\        info.params[3].is_generic and info.params[3].type == null)
        \\        struct { matched: Result }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });
}

test "generic function with comptime type info field attributes" {
    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const S = @Struct(.auto, null, &.{ "a", "b" }, &.{ u8, T },
        \\        &.{ .{}, .{ .@"align" = 4 } });
        \\    const U = @Union(.auto, null, &.{"value"}, &.{T}, &.{.{ .@"align" = 8 }});
        \\    const sf = @typeInfo(S).@"struct".fields[1];
        \\    const uf = @typeInfo(U).@"union".fields[0];
        \\    return if (!sf.is_comptime and sf.default_value_ptr == null and sf.alignment.? == 4 and
        \\        uf.alignment.? == 8)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });

    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const S = struct {
        \\        comptime fixed: u8 = 3,
        \\        value: T align(4),
        \\    };
        \\    const fixed = @typeInfo(S).@"struct".fields[0];
        \\    const value = @typeInfo(S).@"struct".fields[1];
        \\    return if (fixed.is_comptime and fixed.default_value_ptr != null and fixed.alignment == null and
        \\        !value.is_comptime and value.default_value_ptr == null and value.alignment.? == 4)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });
}

test "generic function with inferred AST packed struct backing type" {
    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const S = packed struct { low: u3, high: T };
        \\    const info = @typeInfo(S).@"struct";
        \\    return if (info.layout == .@"packed" and info.backing_integer.? == u8 and
        \\        @bitSizeOf(S) == 8 and @sizeOf(S) == 1 and @alignOf(S) == 1)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u5) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u5" },
    });
}

test "generic function rebuilding types from comptime type info" {
    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const int_info = @typeInfo(T).int;
        \\    const Int = @Int(int_info.signedness, int_info.bits);
        \\    const optional_info = @typeInfo(?T).optional;
        \\    const Optional = ?optional_info.child;
        \\    const array_info = @typeInfo([4]T).array;
        \\    const Array = [array_info.len]array_info.child;
        \\    const vector_info = @typeInfo(@Vector(8, T)).vector;
        \\    const Vector = @Vector(vector_info.len, vector_info.child);
        \\    return if (Int == T and Optional == ?T and Array == [4]T and Vector == @Vector(8, T))
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(i16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "i16" },
    });

    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const S = @Struct(.auto, null, &.{"value"}, &.{T}, &.{.{} });
        \\    const P = *align(4) const S;
        \\    const info = @typeInfo(P).pointer;
        \\    const Rebuilt = @Pointer(info.size, .{
        \\        .@"const" = info.is_const,
        \\        .@"volatile" = info.is_volatile,
        \\        .@"allowzero" = info.is_allowzero,
        \\        .@"addrspace" = info.address_space,
        \\        .@"align" = info.alignment,
        \\    }, info.child, null);
        \\    return if (Rebuilt == P and @typeInfo(Rebuilt).pointer.child == S)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });

    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const F = @Fn(&.{T}, &.{.{}}, u8, .{ .@"callconv" = .c, .varargs = true });
        \\    const info = @typeInfo(F).@"fn";
        \\    const Rebuilt = @Fn(&.{T}, &.{.{}}, info.return_type.?, .{
        \\        .@"callconv" = info.calling_convention,
        \\        .varargs = info.is_var_args,
        \\    });
        \\    return if (Rebuilt == F)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });

    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const S = struct { value: T };
        \\    const Original = fn (S) S;
        \\    const info = @typeInfo(Original).@"fn";
        \\    const Rebuilt = @Fn(&.{info.params[0].type.?}, &.{.{}}, info.return_type.?, .{});
        \\    const rebuilt_info = @typeInfo(Rebuilt).@"fn";
        \\    return if (Rebuilt == Original and rebuilt_info.params[0].type.? == S and
        \\        rebuilt_info.return_type.? == S)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });
}

test "generic function with AST function calling convention type info" {
    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const Auto = fn (T) u8;
        \\    const Naked = fn () callconv(.naked) noreturn;
        \\    const auto_name = @tagName(@typeInfo(Auto).@"fn".calling_convention);
        \\    const naked_name = @tagName(@typeInfo(Naked).@"fn".calling_convention);
        \\    return if (auto_name.len == 4 and auto_name[1] == 'u' and
        \\        naked_name.len == 5 and naked_name[0] == 'n')
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });

    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const Generated = @Fn(&.{T}, &.{.{}}, void, .{});
        \\    const Ast = fn () callconv(.naked) noreturn;
        \\    return if (@typeInfo(Generated).@"fn".calling_convention == .auto and
        \\        @typeInfo(Ast).@"fn".calling_convention == .naked and
        \\        @typeInfo(Generated).@"fn".calling_convention != .naked)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });
}

test "generic function with nominal function signature type info" {
    const cases = [_][]const u8{
        "info.params[0].type.? == S",
        "info.params[1].type.? == U",
        "info.params[2].type.? == E",
        "info.return_type.? == S",
        "!info.is_generic",
    };
    for (cases) |condition| {
        const source = try std.fmt.allocPrint(allocator,
            \\fn Select(comptime T: type) type {{
            \\    const S = struct {{ value: T }};
            \\    const U = union {{ value: T }};
            \\    const E = enum {{ value }};
            \\    const info = @typeInfo(fn (S, U, E) S).@"fn";
            \\    return if ({s})
            \\        struct {{ matched: T }}
            \\    else
            \\        struct {{ fallback: u8 }};
            \\}}
            \\const selected: Select(u16) = undefined;
            \\const field = selected.<cursor>
        , .{condition});
        defer allocator.free(source);
        try testCompletion(source, &.{
            .{ .label = "matched", .kind = .Field, .detail = "u16" },
        });
    }
}

test "generic function with implicit tagged union type info" {
    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const U = union(enum) { alpha: T, beta: u8 };
        \\    const A = @typeInfo(U).@"union".tag_type.?;
        \\    const B = @typeInfo(U).@"union".tag_type.?;
        \\    const info = @typeInfo(A).@"enum";
        \\    return if (A == B and @tagName(A.beta)[0] == 'b' and
        \\        info.fields.len == 2 and info.fields[0].name[0] == 'a' and
        \\        info.fields[1].name[0] == 'b')
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });
}

test "generic function with comptime error set type info" {
    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const errors = @typeInfo(error{ Oops, Failed }).error_set.?;
        \\    return if (errors.len == 2 and @typeInfo(error{}).error_set.?.len == 0 and
        \\        errors[0].name[0] == 'O' and
        \\        errors[1].name[0] == 'F' and @typeInfo(error{Oops}).error_set != null and
        \\        @typeInfo(anyerror).error_set == null)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });
}

test "generic function with comptime type info declarations" {
    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const S = struct {
        \\        field: T,
        \\        pub const Alpha = 1;
        \\        const hidden = 2;
        \\        pub fn beta() void {}
        \\        test {}
        \\        comptime {}
        \\    };
        \\    const U = union { value: T, pub const Alpha = 1; const hidden = 2; };
        \\    const E = enum { value, pub const Alpha = 1; const hidden = 2; };
        \\    const O = opaque { pub const Alpha = 1; const hidden = 2; };
        \\    const struct_decls = @typeInfo(S).@"struct".decls;
        \\    const union_decls = @typeInfo(U).@"union".decls;
        \\    const enum_decls = @typeInfo(E).@"enum".decls;
        \\    const opaque_decls = @typeInfo(O).@"opaque".decls;
        \\    return if (struct_decls.len == 2 and struct_decls[0].name[0] == 'A' and
        \\        struct_decls[1].name[0] == 'b' and union_decls.len == 1 and
        \\        union_decls[0].name[0] == 'A' and enum_decls.len == 1 and
        \\        enum_decls[0].name[0] == 'A' and opaque_decls.len == 1 and
        \\        opaque_decls[0].name[0] == 'A')
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });

    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const S = @Struct(.auto, null, &.{"value"}, &.{T}, &.{.{} });
        \\    const U = @Union(.auto, null, &.{"value"}, &.{T}, &.{.{} });
        \\    const E = @Enum(u8, .exhaustive, &.{"value"}, &.{1});
        \\    return if (@typeInfo(S).@"struct".decls.len == 0 and
        \\        @typeInfo(U).@"union".decls.len == 0 and
        \\        @typeInfo(E).@"enum".decls.len == 0)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });
}

test "generic function with comptime alignOf" {
    try testCompletion(
        \\fn Select(comptime bits: u16) type {
        \\    const T = @Int(.unsigned, bits);
        \\    return if (@alignOf(T) == 2 and @alignOf([3]T) == 2 and
        \\        @alignOf(bool) == 1 and @alignOf(void) == 1)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });

    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    return if (@alignOf(T) == 4)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(f32) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "f32" },
    });

    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    return if (@alignOf(T) == 16)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(f80) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "f80" },
    });
}

test "generic function with comptime value builtins" {
    const cases = [_]struct { expression: []const u8, detail: []const u8 }{
        .{ .expression = "@intFromFloat(@sqrt(@as(f32, 81.0)))", .detail = "[9]u8" },
        .{ .expression = "@intFromFloat(@abs(@as(f32, -4.75)))", .detail = "[4]u8" },
        .{ .expression = "@min(@as(u128, 340282366920938463463374607431768211455), 7)", .detail = "[7]u8" },
        .{ .expression = "@bitReverse(@as(u8, 0b0000_0011))", .detail = "[192]u8" },
        .{ .expression = "@byteSwap(@as(u16, 0x1234))", .detail = "[13330]u8" },
        .{ .expression = "@ctz(@bitReverse(@as(u256, 1)))", .detail = "[255]u8" },
        .{ .expression = "@ctz(@byteSwap(@as(u256, 1)))", .detail = "[248]u8" },
        .{ .expression = "@shlExact(@as(u8, 3), 2)", .detail = "[12]u8" },
        .{ .expression = "@shrExact(@as(u8, 12), 2)", .detail = "[3]u8" },
        .{ .expression = "@ctz(@shlExact(@as(u256, 1), 200))", .detail = "[200]u8" },
        .{ .expression = "@shrExact(@as(u256, 1606938044258990275541962092341162602522202993782792835301376), 200)", .detail = "[1]u8" },
        .{ .expression = "@intFromBool(true)", .detail = "[1]u8" },
        .{ .expression = "@intFromBool(false)", .detail = "[0]u8" },
        .{ .expression = "@min(4, 7)", .detail = "[4]u8" },
        .{ .expression = "@max(4, 7)", .detail = "[7]u8" },
        .{ .expression = "@min(9, 4, 7)", .detail = "[4]u8" },
        .{ .expression = "@max(4, 9, 7)", .detail = "[9]u8" },
        .{ .expression = "@min(@as(u8, 4), 7)", .detail = "[4]u8" },
        .{ .expression = "@clz(@as(u8, 0b00110000))", .detail = "[2]u8" },
        .{ .expression = "@ctz(@as(u8, 0b00110000))", .detail = "[4]u8" },
        .{ .expression = "@popCount(@as(u8, 0b00110000))", .detail = "[2]u8" },
        .{ .expression = "@clz(@as(u13, 0b1_0000))", .detail = "[8]u8" },
        .{ .expression = "@ctz(@as(u13, 0b1_0000))", .detail = "[4]u8" },
        .{ .expression = "@popCount(@as(i8, -16))", .detail = "[4]u8" },
        .{ .expression = "@clz(@as(u8, 0))", .detail = "[8]u8" },
        .{ .expression = "@ctz(@as(u8, 0))", .detail = "[8]u8" },
        .{ .expression = "@abs(-4)", .detail = "[4]u8" },
        .{ .expression = "@abs(@as(i8, -4))", .detail = "[4]u8" },
        .{ .expression = "@intCast(@abs(@as(i256, -4)))", .detail = "[4]u8" },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(allocator,
            \\fn Buffer(comptime N: usize) type {{
            \\    return struct {{ items: [N]u8 }};
            \\}}
            \\const buffer: Buffer({s}) = undefined;
            \\const fields = buffer.<cursor>
        , .{case.expression});
        defer allocator.free(source);
        try testCompletion(source, &.{
            .{ .label = "items", .kind = .Field, .detail = case.detail },
        });
    }

    try testCompletion(
        \\fn Select(comptime N: comptime_int) type {
        \\    return if (@min(N, -2) == -3)
        \\        struct { selected: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(-3) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime value: u128) type {
        \\    return if (@bitReverse(value) == 170141183460469231731687303715884105728 and
        \\        @byteSwap(@as(u128, 0x0123456789abcdef0011223344556677)) == 158709475186131821931889503309083779841)
        \\        struct { selected: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(1) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime value: u128) type {
        \\    const maximum = @max(value, 7);
        \\    return if (maximum == 340282366920938463463374607431768211455)
        \\        struct { selected: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(340282366920938463463374607431768211455) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime value: i8) type {
        \\    return if (@bitReverse(value) == -128 and @byteSwap(value) == 1)
        \\        struct { selected: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(1) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime cast_value: u16, comptime truncate_value: u16) type {
        \\    const narrowed: u8 = @intCast(cast_value);
        \\    const truncated: u8 = @truncate(truncate_value);
        \\    return if (narrowed == 42 and truncated == 42)
        \\        struct { selected: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(42, 0x12a) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime cast_value: u129, comptime bit_value: u128) type {
        \\    const casted: u128 = @intCast(cast_value);
        \\    const truncated: u128 = @truncate((@as(u256, 1) << 128) | 5);
        \\    const signed: i128 = @bitCast(bit_value);
        \\    const unsigned: u128 = @bitCast(signed);
        \\    return if (casted == 170141183460469231731687303715884105728 and truncated == 5 and
        \\        signed == -170141183460469231731687303715884105728 and unsigned == bit_value)
        \\        struct { wide: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(170141183460469231731687303715884105728, 170141183460469231731687303715884105728) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "wide", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime value: u512) type {
        \\    const truncated: u256 = @truncate(value);
        \\    return if (truncated == 5)
        \\        struct { wide: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(2037035976334486086268445688409378161051468393665936250636140449354381299763336706183397381) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "wide", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Buffers(comptime cast_value: u8, comptime truncate_value: u8) type {
        \\    return struct {
        \\        casted: [cast_value]u8,
        \\        truncated: [truncate_value]u8,
        \\    };
        \\}
        \\const buffers: Buffers(@intCast(4), @truncate(@as(u16, 0x104))) = undefined;
        \\const fields = buffers.<cursor>
    , &.{
        .{ .label = "casted", .kind = .Field, .detail = "[4]u8" },
        .{ .label = "truncated", .kind = .Field, .detail = "[4]u8" },
    });

    try testCompletion(
        \\fn Select(comptime value: u8) type {
        \\    const signed: i8 = @bitCast(value);
        \\    const unsigned: u8 = @bitCast(signed);
        \\    return if (signed == -1 and unsigned == 255)
        \\        struct { selected: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(255) = undefined;
        \\const fields = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "u8" },
    });
    try testCompletion(
        \\fn Select(comptime value: u256) type {
        \\    const signed: i256 = @bitCast(value);
        \\    const unsigned: u256 = @bitCast(signed);
        \\    return if (signed == -1 and unsigned == value)
        \\        struct { selected: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(115792089237316195423570985008687907853269984665640564039457584007913129639935) = undefined;
        \\const fields = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "u8" },
    });
    try testCompletion(
        \\fn Direct(comptime value: i8) type {
        \\    return if (value == -1) struct { direct: u8 } else struct { fallback: u8 };
        \\}
        \\const direct: Direct(@bitCast(@as(u8, 255))) = undefined;
        \\const fields = direct.<cursor>
    , &.{
        .{ .label = "direct", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime positive: u8, comptime negative: i8) type {
        \\    return if (positive == 42 and negative == -42)
        \\        struct { selected: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(@intFromFloat(@as(f32, 42.75)), @intFromFloat(@as(f64, -42.75))) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime positive: f32, comptime negative: f64) type {
        \\    const positive_int: u8 = @intFromFloat(positive);
        \\    const negative_int: i8 = @intFromFloat(negative);
        \\    return if (positive_int == 42 and negative_int == -42)
        \\        struct { selected: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(@floatFromInt(@as(u16, 42)), @floatFromInt(@as(i16, -42))) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime positive: u128, comptime negative: i128) type {
        \\    const positive_float: f128 = @floatFromInt(positive);
        \\    const negative_float: f128 = @floatFromInt(negative);
        \\    const positive_int: u128 = @intFromFloat(positive_float + 0.75);
        \\    const negative_int: i128 = @intFromFloat(negative_float - 0.75);
        \\    return if (positive_float == @as(f128, 18446744073709551616.0) and
        \\        negative_float == @as(f128, -18446744073709551616.0) and
        \\        positive_int == positive and negative_int == negative)
        \\        struct { wide: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(18446744073709551616, -18446744073709551616) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "wide", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime value: f64) type {
        \\    const narrowed: f32 = @floatCast(value);
        \\    const as_int: u8 = @intFromFloat(narrowed);
        \\    return if (as_int == 42) struct { selected: u8 } else struct { fallback: u8 };
        \\}
        \\const selected: Select(42.75) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "u8" },
    });
    try testCompletion(
        \\fn Select(comptime value: f32) type {
        \\    const as_int: i8 = @intFromFloat(value);
        \\    return if (as_int == -42) struct { direct: u8 } else struct { fallback: u8 };
        \\}
        \\const selected: Select(@floatCast(@as(f64, -42.75))) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "direct", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime low: f32, comptime high: f64) type {
        \\    const minimum: i8 = @intFromFloat(@min(low, high));
        \\    const maximum: i8 = @intFromFloat(@max(-low, -high));
        \\    return if (minimum == 2 and maximum == -2)
        \\        struct { selected: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(2.5, 4.5) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime value: f64) type {
        \\    const floored: i8 = @intFromFloat(@floor(value));
        \\    const ceiled: i8 = @intFromFloat(@ceil(value));
        \\    const truncated: i8 = @intFromFloat(@trunc(value));
        \\    const rounded: i8 = @intFromFloat(@round(value));
        \\    return if (floored == -3 and ceiled == -2 and truncated == -2 and rounded == -3)
        \\        struct { selected: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(-2.75) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime zero32: f32, comptime zero64: f64) type {
        \\    return if (@sin(zero32) == 0 and @cos(zero64) == 1 and @tan(zero32) == 0 and
        \\        @exp(zero64) == 1 and @exp2(@as(f32, 3.0)) == 8 and
        \\        @log(@as(f64, 1.0)) == 0 and @log2(@as(f32, 8.0)) == 3 and
        \\        @log10(@as(f64, 100.0)) == 2)
        \\        struct { selected: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(0.0, 0.0) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime a: f32, comptime b: f32, comptime c: f32) type {
        \\    return if (@mulAdd(f32, a, b, c) == 9)
        \\        struct { selected: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(2.5, 4.0, -1.0) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime value: f32) type {
        \\    const T = @Vector(2, f32);
        \\    const result = @mulAdd(T, @as(T, .{ value, 3.0 }), @as(T, .{ 4.0, 5.0 }), @as(T, .{ -1.0, 2.0 }));
        \\    return if (result[0] == 9 and result[1] == 17)
        \\        struct { fused: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(2.5) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "fused", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime value: f32) type {
        \\    return if (value + 2 == 4.5 and 7 - @as(f64, value) == 4.5 and
        \\        value * 4 == 10 and 9 / @as(f64, value - 0.5) == 4.5)
        \\        struct { selected: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(2.5) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime value: f32) type {
        \\    return if (value + 1 == 16777216)
        \\        struct { rounded: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(16777216.0) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "rounded", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with nested comptime bit count mutations" {
    try testCompletion(
        \\fn Select(comptime value: u8) type {
        \\    var clz_total: usize = 1;
        \\    var ctz_total: usize = 1;
        \\    var pop_total: usize = 1;
        \\    const leading = @clz(operand: {
        \\        defer clz_total += 1;
        \\        clz_total *= 2;
        \\        break :operand value;
        \\    });
        \\    const trailing = @ctz(operand: {
        \\        defer ctz_total += 1;
        \\        ctz_total *= 2;
        \\        break :operand value;
        \\    });
        \\    const population = @popCount(operand: {
        \\        defer pop_total += 1;
        \\        pop_total *= 2;
        \\        break :operand value;
        \\    });
        \\    return if (leading == 2 and trailing == 4 and population == 2) struct {
        \\        clz_order: [clz_total]u8,
        \\        ctz_order: [ctz_total]u8,
        \\        pop_order: [pop_total]u8,
        \\    } else struct { fallback: u8 };
        \\}
        \\const selected: Select(0b0011_0000) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "clz_order", .kind = .Field, .detail = "[3]u8" },
        .{ .label = "ctz_order", .kind = .Field, .detail = "[3]u8" },
        .{ .label = "pop_order", .kind = .Field, .detail = "[3]u8" },
    });
}

test "generic function with nested comptime bit permutation mutations" {
    try testCompletion(
        \\fn Select(comptime reverse_value: u8, comptime swap_value: u16) type {
        \\    var reverse_total: usize = 1;
        \\    var swap_total: usize = 1;
        \\    const reversed = @bitReverse(operand: {
        \\        defer reverse_total += 1;
        \\        reverse_total *= 2;
        \\        break :operand reverse_value;
        \\    });
        \\    const swapped = @byteSwap(operand: {
        \\        defer swap_total += 1;
        \\        swap_total *= 2;
        \\        break :operand swap_value;
        \\    });
        \\    return if (reversed == 192 and swapped == 13330) struct {
        \\        reverse_order: [reverse_total]u8,
        \\        swap_order: [swap_total]u8,
        \\    } else struct { fallback: u8 };
        \\}
        \\const selected: Select(3, 0x1234) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "reverse_order", .kind = .Field, .detail = "[3]u8" },
        .{ .label = "swap_order", .kind = .Field, .detail = "[3]u8" },
    });
}

test "generic function with comptime unknown bit builtin types" {
    try testCompletion(
        \\var runtime_u8: u8 = undefined;
        \\var runtime_i8: i8 = undefined;
        \\var runtime_u16: u16 = undefined;
        \\var runtime_u8_vector: @Vector(2, u8) = undefined;
        \\var runtime_i8_vector: @Vector(2, i8) = undefined;
        \\var runtime_u16_vector: @Vector(2, u16) = undefined;
        \\fn Select() type {
        \\    var total: usize = 0;
        \\    const leading = @clz(operand: {
        \\        total += 1;
        \\        break :operand runtime_u8;
        \\    });
        \\    const trailing = @ctz(operand: {
        \\        total += 1;
        \\        break :operand runtime_u8;
        \\    });
        \\    const population = @popCount(operand: {
        \\        total += 1;
        \\        break :operand runtime_i8;
        \\    });
        \\    const reversed = @bitReverse(operand: {
        \\        total += 1;
        \\        break :operand runtime_u8;
        \\    });
        \\    const swapped = @byteSwap(operand: {
        \\        total += 1;
        \\        break :operand runtime_u16;
        \\    });
        \\    const vector_population = @popCount(operand: {
        \\        total += 1;
        \\        break :operand runtime_i8_vector;
        \\    });
        \\    const vector_reversed = @bitReverse(operand: {
        \\        total += 1;
        \\        break :operand runtime_u8_vector;
        \\    });
        \\    const vector_swapped = @byteSwap(operand: {
        \\        total += 1;
        \\        break :operand runtime_u16_vector;
        \\    });
        \\    total += 1;
        \\    return struct {
        \\        leading: @TypeOf(leading),
        \\        trailing: @TypeOf(trailing),
        \\        population: @TypeOf(population),
        \\        reversed: @TypeOf(reversed),
        \\        swapped: @TypeOf(swapped),
        \\        vector_population: @TypeOf(vector_population),
        \\        vector_reversed: @TypeOf(vector_reversed),
        \\        vector_swapped: @TypeOf(vector_swapped),
        \\        items: [total]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "leading", .kind = .Field, .detail = "u4" },
        .{ .label = "trailing", .kind = .Field, .detail = "u4" },
        .{ .label = "population", .kind = .Field, .detail = "u4" },
        .{ .label = "reversed", .kind = .Field, .detail = "u8" },
        .{ .label = "swapped", .kind = .Field, .detail = "u16" },
        .{ .label = "vector_population", .kind = .Field, .detail = "@Vector(2,u4)" },
        .{ .label = "vector_reversed", .kind = .Field, .detail = "@Vector(2,u8)" },
        .{ .label = "vector_swapped", .kind = .Field, .detail = "@Vector(2,u16)" },
        .{ .label = "items", .kind = .Field, .detail = "[9]u8" },
    });
}

test "generic function with nested comptime exact shift mutations" {
    try testCompletion(
        \\fn Select(comptime lhs: u8, comptime rhs: u8, comptime shift: u3) type {
        \\    var left_total: usize = 1;
        \\    var right_total: usize = 1;
        \\    const shifted_left = @shlExact(value: {
        \\        left_total += 1;
        \\        break :value lhs;
        \\    }, amount: {
        \\        left_total *= 2;
        \\        break :amount shift;
        \\    });
        \\    const shifted_right = @shrExact(value: {
        \\        right_total += 1;
        \\        break :value rhs;
        \\    }, amount: {
        \\        right_total *= 2;
        \\        break :amount shift;
        \\    });
        \\    return if (shifted_left == 12 and shifted_right == 3) struct {
        \\        left_order: [left_total]u8,
        \\        right_order: [right_total]u8,
        \\    } else struct { fallback: u8 };
        \\}
        \\const selected: Select(3, 12, 2) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "left_order", .kind = .Field, .detail = "[4]u8" },
        .{ .label = "right_order", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with cmpxchg result type" {
    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const result = @cmpxchgStrong(T, undefined, undefined, undefined, .seq_cst, .seq_cst);
        \\    return if (@TypeOf(result) == ?T)
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u32) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u32" },
    });
}

test "generic function with comptime division builtins" {
    const cases = [_]struct { expression: []const u8, detail: []const u8 }{
        .{ .expression = "@divTrunc(7, 3)", .detail = "[2]u8" },
        .{ .expression = "@divFloor(7, 3)", .detail = "[2]u8" },
        .{ .expression = "@divExact(8, 2)", .detail = "[4]u8" },
        .{ .expression = "@mod(7, 3)", .detail = "[1]u8" },
        .{ .expression = "@rem(7, 3)", .detail = "[1]u8" },
        .{ .expression = "@mod(@as(i256, -28948022309329048855892746252171976963317496166410141009864396001978282409989), 7)", .detail = "[5]u8" },
        .{ .expression = "@rem(@as(i256, 28948022309329048855892746252171976963317496166410141009864396001978282409989), 7)", .detail = "[2]u8" },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(allocator,
            \\fn Buffer(comptime N: usize) type {{
            \\    return struct {{ items: [N]u8 }};
            \\}}
            \\const buffer: Buffer({s}) = undefined;
            \\const fields = buffer.<cursor>
        , .{case.expression});
        defer allocator.free(source);
        try testCompletion(source, &.{
            .{ .label = "items", .kind = .Field, .detail = case.detail },
        });
    }

    try testCompletion(
        \\fn Select(comptime value: u256) type {
        \\    return if (@divExact(value, 8) == 7237005577332262213973186563042994240829374041602535252466099000494570602496 and
        \\        @divTrunc(@as(i256, -28948022309329048855892746252171976963317496166410141009864396001978282409989), 7) == -4135431758475578407984678036024568137616785166630020144266342285996897487141 and
        \\        @divFloor(@as(i256, -28948022309329048855892746252171976963317496166410141009864396001978282409989), 7) == -4135431758475578407984678036024568137616785166630020144266342285996897487142)
        \\        struct { wide: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(57896044618658097711785492504343953926634992332820282019728792003956564819968) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "wide", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime lhs: f32, comptime rhs: f64) type {
        \\    const modulo: u8 = @intFromFloat(@mod(lhs, rhs));
        \\    const remainder: i8 = @intFromFloat(@rem(-lhs, rhs));
        \\    return if (modulo == 2 and remainder == -2)
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(7.5, 5.0) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime N: i8) type {
        \\    const lhs: @Vector(2, i8) = .{ N, 8 };
        \\    const rhs: @Vector(2, i8) = .{ 3, 2 };
        \\    const float_lhs: @Vector(2, f32) = .{ -7.5, 8.0 };
        \\    const float_rhs: @Vector(2, f32) = .{ 2.0, 2.0 };
        \\    return if (@divTrunc(lhs, rhs)[0] == -2 and @divFloor(lhs, rhs)[0] == -3 and
        \\        @divExact(@as(@Vector(2, i8), .{ 6, 8 }), rhs)[1] == 4 and
        \\        @mod(lhs, rhs)[0] == 2 and @rem(lhs, rhs)[0] == -1 and
        \\        @divFloor(float_lhs, float_rhs)[0] == -4)
        \\        struct { evaluated: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(-7) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "evaluated", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\var runtime_i8: i8 = undefined;
        \\var runtime_vector: @Vector(2, i8) = undefined;
        \\fn Select(comptime N: u8) type {
        \\    return if (@mod(runtime_i8, @as(i8, 1)) == 0 and
        \\        @rem(runtime_i8, @as(i8, 1)) == 0 and
        \\        @reduce(.And, @mod(runtime_vector, @as(@Vector(2, i8), @splat(1))) ==
        \\            @as(@Vector(2, i8), @splat(0))) and
        \\        @reduce(.And, @rem(runtime_vector, @as(@Vector(2, i8), @splat(1))) ==
        \\            @as(@Vector(2, i8), @splat(0))))
        \\        struct { reduced: [N]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "reduced", .kind = .Field, .detail = "[4]u8" },
    });

    try testCompletion(
        \\fn Select(comptime value: f32) type {
        \\    return if (@min(value, 4) == 2.5 and @max(4, value) == 4 and
        \\        @divTrunc(-value * 3, 2) == -3 and @divFloor(-value * 3, 2) == -4 and
        \\        @divExact(value * 4, 2) == 5 and @mod(-value * 3, 5) == 2.5 and
        \\        @rem(-value * 3, 5) == -2.5)
        \\        struct { mixed: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(2.5) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "mixed", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime lhs: f32, comptime rhs: f64) type {
        \\    return if (@divTrunc(lhs, rhs) == -3 and @divFloor(lhs, rhs) == -4 and
        \\        @divExact(@as(f32, 8.0), rhs) == 4)
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(-7.5, 2.0) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime N: comptime_int) type {
        \\    return if (@divTrunc(N, 3) == -2 and @divFloor(N, 3) == -3 and @mod(N, 3) == 2 and @rem(N, 3) == -1)
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(-7) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime N: comptime_int) type {
        \\    return if (@divExact(N, 3) == 2)
        \\        struct { exact: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(7) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "exact", .kind = .Field, .detail = "u8" },
        .{ .label = "fallback", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime lhs: f32, comptime rhs: f64) type {
        \\    return if (@divExact(lhs, rhs) == 2)
        \\        struct { exact: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(5.0, 2.0) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "exact", .kind = .Field, .detail = "u8" },
        .{ .label = "fallback", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime N: u128) type {
        \\    return if (@divTrunc(N, 2) == 85070591730234615865843651857942052864 and
        \\        @divFloor(N, 2) == 85070591730234615865843651857942052864 and
        \\        @divExact(N, 2) == 85070591730234615865843651857942052864 and
        \\        @mod(N, 7) == 2 and @rem(N, 7) == 2)
        \\        struct { wide: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(170141183460469231731687303715884105728) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "wide", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with nested comptime division mutations" {
    try testCompletion(
        \\fn Select(comptime lhs: u8, comptime rhs: u8) type {
        \\    var trunc_total: usize = 1;
        \\    var floor_total: usize = 1;
        \\    var exact_total: usize = 1;
        \\    var mod_total: usize = 1;
        \\    var rem_total: usize = 1;
        \\    const truncated = @divTrunc(value: { trunc_total += 1; break :value lhs; }, divisor: { trunc_total *= 2; break :divisor rhs; });
        \\    const floored = @divFloor(value: { floor_total += 1; break :value lhs; }, divisor: { floor_total *= 2; break :divisor rhs; });
        \\    const exact = @divExact(value: { exact_total += 1; break :value lhs; }, divisor: { exact_total *= 2; break :divisor rhs; });
        \\    const modulo = @mod(value: { mod_total += 1; break :value lhs; }, divisor: { mod_total *= 2; break :divisor rhs; });
        \\    const remainder = @rem(value: { rem_total += 1; break :value lhs; }, divisor: { rem_total *= 2; break :divisor rhs; });
        \\    return if (truncated == 4 and floored == 4 and exact == 4 and modulo == 0 and remainder == 0) struct {
        \\        trunc_order: [trunc_total]u8,
        \\        floor_order: [floor_total]u8,
        \\        exact_order: [exact_total]u8,
        \\        mod_order: [mod_total]u8,
        \\        rem_order: [rem_total]u8,
        \\    } else struct { fallback: u8 };
        \\}
        \\const selected: Select(8, 2) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "trunc_order", .kind = .Field, .detail = "[4]u8" },
        .{ .label = "floor_order", .kind = .Field, .detail = "[4]u8" },
        .{ .label = "exact_order", .kind = .Field, .detail = "[4]u8" },
        .{ .label = "mod_order", .kind = .Field, .detail = "[4]u8" },
        .{ .label = "rem_order", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with comptime unknown exact shift types" {
    try testCompletion(
        \\var runtime_u8: u8 = undefined;
        \\var runtime_u3: u3 = undefined;
        \\var runtime_vector: @Vector(2, u8) = undefined;
        \\var runtime_shifts: @Vector(2, u3) = undefined;
        \\fn Select() type {
        \\    var total: usize = 0;
        \\    const left = @shlExact(value: {
        \\        total += 1;
        \\        break :value runtime_u8;
        \\    }, amount: {
        \\        total += 1;
        \\        break :amount @as(u3, 2);
        \\    });
        \\    const right = @shrExact(value: {
        \\        total += 1;
        \\        break :value @as(u8, 12);
        \\    }, amount: {
        \\        total += 1;
        \\        break :amount runtime_u3;
        \\    });
        \\    const vector_left = @shlExact(value: {
        \\        total += 1;
        \\        break :value runtime_vector;
        \\    }, amount: {
        \\        total += 1;
        \\        break :amount @as(@Vector(2, u3), @splat(2));
        \\    });
        \\    const vector_right = @shrExact(value: {
        \\        total += 1;
        \\        break :value runtime_vector;
        \\    }, amount: {
        \\        total += 1;
        \\        break :amount runtime_shifts;
        \\    });
        \\    total += 1;
        \\    return struct {
        \\        left: @TypeOf(left),
        \\        right: @TypeOf(right),
        \\        vector_left: @TypeOf(vector_left),
        \\        vector_right: @TypeOf(vector_right),
        \\        items: [total]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "left", .kind = .Field, .detail = "u8" },
        .{ .label = "right", .kind = .Field, .detail = "u8" },
        .{ .label = "vector_left", .kind = .Field, .detail = "@Vector(2,u8)" },
        .{ .label = "vector_right", .kind = .Field, .detail = "@Vector(2,u8)" },
        .{ .label = "items", .kind = .Field, .detail = "[9]u8" },
    });
}

test "generic function with comptime member reflection" {
    try testCompletion(
        \\const S = struct { @"hello\nworld": u8 };
        \\fn Select(comptime T: type, comptime name: []const u8) type {
        \\    return if (@hasField(T, name))
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(S, "hello\nworld") = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });
    try testCompletion(
        \\const S = struct {
        \\    @"\x66ield": u8,
        \\    const @"decl\x21" = 1;
        \\};
        \\fn Select(comptime T: type) type {
        \\    return if (@hasField(T, "field") and @hasDecl(T, "decl!"))
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(S) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\const S = struct { field: u8 };
        \\fn Select(comptime T: type, comptime name: anytype) type {
        \\    return if (@TypeOf(name) == []const u8 and @hasField(T, name))
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const name = @as([]const u8, "field");
        \\const selected: Select(S, name) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });
    try testCompletion(
        \\const S = struct { field: u8 };
        \\fn Select(comptime T: type, comptime name: anytype) type {
        \\    return if (@TypeOf(name) == [:0]const u8 and name.len == 5 and
        \\        name[name.len] == 0 and @hasField(T, name))
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(S, @as([:0]const u8, "field")) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\const S = struct { ababab: u8 };
        \\fn Select(comptime T: type, comptime name: anytype) type {
        \\    return if (@TypeOf(name) == *const [6:0]u8 and @hasField(T, name))
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const name = "ab" ** 3;
        \\const selected: Select(S, name) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });
    try testCompletion(
        \\const S = struct { empty: u8 };
        \\fn Select(comptime T: type, comptime name: anytype) type {
        \\    return if (@TypeOf(name) == *const [0:0]u8 and name.len == 0 and
        \\        @hasField(T, name ++ "empty"))
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(S, "ab" ** 0) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });
    try testCompletion(
        \\const S = struct { aa: u8, ab: u8 };
        \\fn Select(comptime T: type) type {
        \\    const repeated = "ab"[0..1] ** 2;
        \\    const joined = "ab"[0..1] ++ "ab"[1..2];
        \\    return if (@TypeOf(repeated) == *const [2]u8 and
        \\        @TypeOf(joined) == *const [2]u8 and
        \\        @hasField(T, repeated) and @hasField(T, joined))
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(S) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\const S = struct { field: u8 };
        \\fn Select(comptime T: type, comptime name: []const u8) type {
        \\    return if (@hasField(T, name))
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(S,
        \\    \\field
        \\) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });
    try testCompletion(
        \\const S = struct { hello: u8, world: u8 };
        \\fn Select(comptime T: type, comptime name: []const u8) type {
        \\    return if (name.len == 11 and name[5] == '\n' and
        \\        @hasField(T, name[0..5]) and @hasField(T, name[6..]))
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(S,
        \\    \\hello
        \\    \\world
        \\) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\const S = struct { field: u8 };
        \\fn Select(comptime T: type, comptime name: []const u8) type {
        \\    return if (@hasField(T, name[1..]))
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(S, "_field") = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });
    try testCompletion(
        \\const S = struct { field: u8 };
        \\fn Select(comptime T: type, comptime name: []const u8) type {
        \\    const field = name[1..6];
        \\    return if (@TypeOf(name) == []const u8 and @TypeOf(field) == *const [5]u8 and
        \\        name.len == 7 and field.len == 5 and field[0] == 'f' and @hasField(T, field))
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(S, "_field!") = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\const S = struct { field: u8, const decl = 1; };
        \\fn Select(comptime T: type) type {
        \\    return if (@hasField(T, "field") and @hasDecl(T, "decl"))
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(S) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\const E = enum { tag, const decl = 1; };
        \\fn Select(comptime T: type) type {
        \\    return if (@hasField(T, "tag") and !@hasDecl(T, "tag") and @hasDecl(T, "decl"))
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(E) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\const S = struct { field: u8 };
        \\fn Select(comptime T: type) type {
        \\    return if (@hasField(T, "missing") or @hasDecl(T, "missing"))
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(S) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "fallback", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\const S = struct { field: u8 };
        \\fn Select(comptime T: type, comptime name: []const u8) type {
        \\    return if (@hasField(T, name))
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(S, undefined) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
        .{ .label = "fallback", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    return if (@hasField(T, "1") and !@hasField(T, "2"))
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(struct { u8, bool }) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\const S = struct { field: u8 };
        \\fn Select(comptime T: type) type {
        \\    const name = "field";
        \\    return if (@hasField(T, name))
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(S) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\const S = struct { field: u8 };
        \\fn Select(comptime T: type, comptime name: []const u8) type {
        \\    return if (@hasField(T, name))
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(S, "field") = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\const S = struct { @"hello world": u8 };
        \\fn Select(comptime T: type, comptime name: []const u8) type {
        \\    return if (@hasField(T, name))
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const name = "hello " ++ "world";
        \\const selected: Select(S, name) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\const S = struct { @"hello world": u8 };
        \\fn Select(comptime T: type, comptime name: []const u8) type {
        \\    return if (@hasField(T, name))
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(S, "hello\x20world") = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with nested comptime member reflection mutations" {
    try testCompletion(
        \\const S = struct { field: u8, const decl = 1; };
        \\fn Select(comptime T: type) type {
        \\    var field_total: usize = 1;
        \\    var decl_total: usize = 1;
        \\    const has_field = @hasField(type_value: {
        \\        field_total += 1;
        \\        break :type_value T;
        \\    }, name_value: {
        \\        field_total *= 2;
        \\        break :name_value "field";
        \\    });
        \\    const has_decl = @hasDecl(type_value: {
        \\        decl_total += 1;
        \\        break :type_value T;
        \\    }, name_value: {
        \\        decl_total *= 2;
        \\        break :name_value "decl";
        \\    });
        \\    return if (has_field and has_decl) struct {
        \\        field_order: [field_total]u8,
        \\        decl_order: [decl_total]u8,
        \\    } else struct { fallback: u8 };
        \\}
        \\const selected: Select(S) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "field_order", .kind = .Field, .detail = "[4]u8" },
        .{ .label = "decl_order", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with nested comptime field reflection mutations" {
    try testCompletion(
        \\const Mode = enum { fast, safe };
        \\const S = struct { payload: u16 };
        \\fn Select() type {
        \\    var field_total: usize = 1;
        \\    var field_type_total: usize = 1;
        \\    const mode = @field(container: {
        \\        field_total += 1;
        \\        break :container Mode;
        \\    }, name: {
        \\        field_total *= 2;
        \\        break :name "safe";
        \\    });
        \\    const Payload = @FieldType(container: {
        \\        field_type_total += 1;
        \\        break :container S;
        \\    }, name: {
        \\        field_type_total *= 2;
        \\        break :name "payload";
        \\    });
        \\    return if (mode == .safe and Payload == u16) struct {
        \\        field_order: [field_total]u8,
        \\        field_type_order: [field_type_total]u8,
        \\    } else struct { fallback: u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "field_order", .kind = .Field, .detail = "[4]u8" },
        .{ .label = "field_type_order", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with nested comptime import mutation" {
    try testCompletion(
        \\fn Select() type {
        \\    var total: usize = 1;
        \\    const builtin_module = @import(path: {
        \\        total *= 2;
        \\        break :path "builtin";
        \\    });
        \\    return if (@hasDecl(builtin_module, "zig_version"))
        \\        struct { order: [total]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "order", .kind = .Field, .detail = "[2]u8" },
    });
}

test "generic function with nested comptime control builtin mutations" {
    try testCompletion(
        \\fn Select() type {
        \\    var quota_total: usize = 1;
        \\    var safety_total: usize = 1;
        \\    _ = @setEvalBranchQuota(quota: {
        \\        quota_total *= 2;
        \\        break :quota 10_000;
        \\    });
        \\    _ = @setRuntimeSafety(enabled: {
        \\        safety_total += 2;
        \\        break :enabled true;
        \\    });
        \\    return struct {
        \\        quota_order: [quota_total]u8,
        \\        safety_order: [safety_total]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "quota_order", .kind = .Field, .detail = "[2]u8" },
        .{ .label = "safety_order", .kind = .Field, .detail = "[3]u8" },
    });
}

test "generic function with nested comptime compileLog mutations" {
    try testCompletion(
        \\fn Select() type {
        \\    var total: usize = 1;
        \\    _ = @compileLog(first: {
        \\        total += 1;
        \\        break :first total;
        \\    }, second: {
        \\        total *= 2;
        \\        break :second total;
        \\    });
        \\    return struct { order: [total]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "order", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with nested comptime min max mutations" {
    try testCompletion(
        \\fn Select(comptime a: usize, comptime b: usize, comptime c: usize) type {
        \\    var min_total: usize = 1;
        \\    var max_total: usize = 1;
        \\    const minimum = @min(first: { min_total += 1; break :first a; }, second: { min_total *= 2; break :second b; }, third: { min_total += 3; break :third c; });
        \\    const maximum = @max(first: { max_total += 1; break :first b; }, second: { max_total *= 2; break :second a; }, third: { max_total += 3; break :third c; });
        \\    return if (minimum == 4 and maximum == 9) struct {
        \\        min_order: [min_total]u8,
        \\        max_order: [max_total]u8,
        \\    } else struct { fallback: u8 };
        \\}
        \\const selected: Select(9, 4, 7) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "min_order", .kind = .Field, .detail = "[7]u8" },
        .{ .label = "max_order", .kind = .Field, .detail = "[7]u8" },
    });
}

test "generic function with nested comptime abs mutation" {
    try testCompletion(
        \\fn Select(comptime value: i8) type {
        \\    var total: usize = 1;
        \\    const magnitude = @abs(operand: {
        \\        total += 2;
        \\        break :operand value;
        \\    });
        \\    return if (magnitude == 4)
        \\        struct { items: [total]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(-4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[3]u8" },
    });
}

test "generic function with nested comptime float unary mutations" {
    try testCompletion(
        \\fn Select(comptime initial: usize) type {
        \\    var total: usize = initial;
        \\    const sine = @sin(value: { total += 1; break :value @as(f64, 0.0); });
        \\    const cosine = @cos(value: { total += 1; break :value @as(f64, 0.0); });
        \\    const tangent = @tan(value: { total += 1; break :value @as(f64, 0.0); });
        \\    const exponential = @exp(value: { total += 1; break :value @as(f64, 0.0); });
        \\    const exponential2 = @exp2(value: { total += 1; break :value @as(f64, 3.0); });
        \\    const logarithm = @log(value: { total += 1; break :value @as(f64, 1.0); });
        \\    const logarithm2 = @log2(value: { total += 1; break :value @as(f64, 8.0); });
        \\    const logarithm10 = @log10(value: { total += 1; break :value @as(f64, 100.0); });
        \\    const square_root = @sqrt(value: { total += 1; break :value @as(f64, 81.0); });
        \\    _ = .{ sine, cosine, tangent, exponential, exponential2, logarithm, logarithm2, logarithm10, square_root };
        \\    return struct { items: [total]u8 };
        \\}
        \\const selected: Select(0) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[9]u8" },
    });
}

test "generic function with nested comptime float rounding mutations" {
    try testCompletion(
        \\fn Select(comptime initial: usize) type {
        \\    var total: usize = initial;
        \\    const floored = @floor(value: { total += 1; break :value @as(f64, -2.75); });
        \\    const ceiled = @ceil(value: { total += 1; break :value @as(f64, -2.75); });
        \\    const truncated = @trunc(value: { total += 1; break :value @as(f64, -2.75); });
        \\    const rounded = @round(value: { total += 1; break :value @as(f64, -2.75); });
        \\    _ = .{ floored, ceiled, truncated, rounded };
        \\    return struct { items: [total]u8 };
        \\}
        \\const selected: Select(0) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with nested comptime mulAdd mutations" {
    try testCompletion(
        \\fn Select(comptime a: f32, comptime b: f32, comptime c: f32) type {
        \\    var total: usize = 1;
        \\    const result = @mulAdd(type_value: { total += 1; break :type_value f32; }, lhs: { total *= 2; break :lhs a; }, rhs: { total += 3; break :rhs b; }, addend: { total *= 2; break :addend c; });
        \\    _ = result;
        \\    return struct { items: [total]u8 };
        \\}
        \\const selected: Select(2.5, 4.0, -1.0) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[14]u8" },
    });
}

test "generic function with nested comptime vector select mutations" {
    try testCompletion(
        \\fn Select(comptime value: u8) type {
        \\    var total: usize = 1;
        \\    const selected = @select(element: { total += 1; break :element u8; }, predicate: { total *= 2; break :predicate @as(@Vector(2, bool), .{ true, false }); }, lhs: { total += 3; break :lhs @as(@Vector(2, u8), .{ value, 0 }); }, rhs: { total *= 2; break :rhs @as(@Vector(2, u8), .{ 0, value + 1 }); });
        \\    _ = selected;
        \\    return struct { items: [total]u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[14]u8" },
    });
}

test "generic function with nested comptime vector shuffle mutations" {
    try testCompletion(
        \\fn Select(comptime value: u8) type {
        \\    var total: usize = 1;
        \\    const shuffled = @shuffle(element: { total += 1; break :element u8; }, lhs: { total *= 2; break :lhs @as(@Vector(2, u8), .{ 1, value }); }, rhs: { total += 3; break :rhs @as(@Vector(2, u8), .{ 3, 4 }); }, mask: { total *= 2; break :mask @Vector(3, i32){ 1, -1, -2 }; });
        \\    _ = shuffled;
        \\    return struct { items: [total]u8 };
        \\}
        \\const selected: Select(2) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[14]u8" },
    });
}

test "generic function with comptime vector min max" {
    try testCompletion(
        \\fn Select(comptime N: i8) type {
        \\    const a: @Vector(2, i8) = .{ N, -2 };
        \\    const b: @Vector(2, i8) = .{ 3, 7 };
        \\    const c: @Vector(2, i8) = .{ 5, 1 };
        \\    const minimum = @min(a, b, c);
        \\    const maximum = @max(a, b, c);
        \\    const min_zero = @min(@as(@Vector(2, f32), .{ 0.0, 2.0 }), @as(@Vector(2, f32), .{ -0.0, 3.0 }));
        \\    const max_zero = @max(@as(@Vector(2, f32), .{ -0.0, 2.0 }), @as(@Vector(2, f32), .{ 0.0, 3.0 }));
        \\    return if (minimum[0] == 3 and minimum[1] == -2 and maximum[0] == 5 and maximum[1] == 7 and
        \\        min_zero[0] == -0.0 and max_zero[0] == 0.0)
        \\        struct { selected: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with partially known vector min max" {
    try testCompletion(
        \\var runtime: @Vector(2, i8) = undefined;
        \\fn Select(comptime N: u8) type {
        \\    const minimum = @min(runtime, @as(@Vector(2, i8), @splat(-128)));
        \\    const maximum = @max(runtime, @as(@Vector(2, i8), @splat(127)));
        \\    return if (minimum[0] == -128 and maximum[1] == 127)
        \\        struct { bounded: [N]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "bounded", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with partially known scalar min max" {
    try testCompletion(
        \\var runtime_i8: i8 = undefined;
        \\var runtime_u8: u8 = undefined;
        \\fn Select(comptime N: u8) type {
        \\    const signed_min = @min(runtime_i8, @as(i8, -128));
        \\    const signed_max = @max(runtime_i8, @as(i8, 127));
        \\    const unsigned_min = @min(runtime_u8, @as(u8, 0));
        \\    const unsigned_max = @max(runtime_u8, @as(u8, 255));
        \\    return if (signed_min == -128 and signed_max == 127 and
        \\        unsigned_min == 0 and unsigned_max == 255)
        \\        struct { bounded: [N]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "bounded", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with comptime local constants" {
    try testCompletion(
        \\fn Vector(comptime N: usize, comptime T: type) type {
        \\    const length = N + 1;
        \\    return struct { items: [length]T };
        \\}
        \\const vector: Vector(4, u8) = undefined;
        \\const items = vector.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[5]u8" },
    });
    try testCompletion(
        \\fn Vector(comptime N: usize, comptime T: type) type {
        \\    return struct {
        \\        const length: usize = N + 1;
        \\        items: [length]T,
        \\    };
        \\}
        \\const vector: Vector(4, u8) = undefined;
        \\const items = vector.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[5]u8" },
    });
}

test "generic function with comptime nested container" {
    try testCompletion(
        \\fn Vector(comptime N: usize, comptime T: type) type {
        \\    return struct { inner: struct { items: [N + 1]T } };
        \\}
        \\const vector: Vector(4, u8) = undefined;
        \\const items = vector.inner.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[5]u8" },
    });
}

test "generic function with comptime nested calls" {
    try testCompletion(
        \\fn Inner(comptime N: usize, comptime T: type) type {
        \\    return struct { items: [N + 1]T };
        \\}
        \\fn Outer(comptime N: usize, comptime T: type) type {
        \\    return struct { inner: Inner(N * 2, T) };
        \\}
        \\const vector: Outer(4, u8) = undefined;
        \\const items = vector.inner.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[9]u8" },
    });
}

test "comptime interpreter coerces aggregate call arguments" {
    const cases = [_]struct { type: []const u8, initializer: []const u8, count: []const u8 }{
        .{ .type = "usize", .initializer = "small", .count = "value" },
        .{ .type = "Config", .initializer = ".{}", .count = "value.capacity" },
        .{ .type = "Config", .initializer = ".{ .capacity = small }", .count = "value.capacity" },
        .{ .type = "[1]usize", .initializer = ".{small}", .count = "value[0]" },
        .{ .type = "[1]Config", .initializer = ".{.{ .capacity = small }}", .count = "value[0].capacity" },
        .{ .type = "struct { Config, ?usize }", .initializer = ".{ .{}, small }", .count = "value.@\"0\".capacity + value.@\"1\".? - 4" },
        .{ .type = "union(enum) { count: usize, empty }", .initializer = ".{ .count = small }", .count = "value.count" },
    };
    for (cases) |case| {
        for ([_][]const u8{ "comptime ", "" }) |modifier| {
            const source = try std.fmt.allocPrint(allocator,
                \\const Config = struct {{ capacity: usize = @as(u8, 4) }};
                \\fn count({s}value: {s}) usize {{
                \\    return if (@TypeOf({s}) == usize) {s} else 99;
                \\}}
                \\fn Select() type {{
                \\    const small: u8 = 4;
                \\    var executions: usize = 0;
                \\    const result = count(argument: {{
                \\        executions += 1;
                \\        break :argument {s};
                \\    }});
                \\    return struct {{ items: [result]u8, executions: [executions]u8 }};
                \\}}
                \\const selected: Select() = undefined;
                \\const field = selected.<cursor>
            , .{ modifier, case.type, case.count, case.count, case.initializer });
            defer allocator.free(source);
            errdefer std.debug.print("aggregate call argument source:\n{s}\n", .{source});
            try testCompletion(source, &.{
                .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
                .{ .label = "executions", .kind = .Field, .detail = "[1]u8" },
            });
        }
    }
}

test "comptime interpreter coerces aggregate call returns" {
    const cases = [_]struct { type: []const u8, initializer: []const u8, count: []const u8 }{
        .{ .type = "Config", .initializer = ".{}", .count = "value.capacity" },
        .{ .type = "Config", .initializer = ".{ .capacity = small }", .count = "value.capacity" },
        .{ .type = "[1]usize", .initializer = ".{small}", .count = "value[0]" },
        .{ .type = "[1]Config", .initializer = ".{.{ .capacity = small }}", .count = "value[0].capacity" },
        .{ .type = "struct { Config, ?usize }", .initializer = ".{ .{}, small }", .count = "value.@\"0\".capacity + value.@\"1\".? - 4" },
        .{ .type = "union(enum) { count: usize, empty }", .initializer = ".{ .count = small }", .count = "value.count" },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(allocator,
            \\const Config = struct {{ capacity: usize = @as(u8, 4) }};
            \\fn produce(comptime small: u8, executions: *usize) {s} {{
            \\    return result: {{
            \\        executions.* += 1;
            \\        break :result {s};
            \\    }};
            \\}}
            \\fn Select() type {{
            \\    var executions: usize = 0;
            \\    const value = produce(4, &executions);
            \\    return struct {{
            \\        items: [if (@TypeOf({s}) == usize) {s} else 99]u8,
            \\        executions: [executions]u8,
            \\    }};
            \\}}
            \\const selected: Select() = undefined;
            \\const field = selected.<cursor>
        , .{ case.type, case.initializer, case.count, case.count });
        defer allocator.free(source);
        errdefer std.debug.print("aggregate call return source:\n{s}\n", .{source});
        try testCompletion(source, &.{
            .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
            .{ .label = "executions", .kind = .Field, .detail = "[1]u8" },
        });
    }
}

test "comptime interpreter preserves contextual return casts" {
    const cases = [_]struct { type: []const u8, builtin: []const u8, operand: []const u8, matches: []const u8 }{
        .{ .type = "u8", .builtin = "@intCast", .operand = "@as(u16, 4)", .matches = "value == 4" },
        .{ .type = "u8", .builtin = "@truncate", .operand = "@as(u16, 260)", .matches = "value == 4" },
        .{ .type = "i8", .builtin = "@bitCast", .operand = "@as(u8, 252)", .matches = "value == -4" },
        .{ .type = "usize", .builtin = "@intFromFloat", .operand = "@as(f64, 4.75)", .matches = "value == 4" },
        .{ .type = "f32", .builtin = "@floatFromInt", .operand = "@as(u16, 4)", .matches = "value == 4.0" },
        .{ .type = "f32", .builtin = "@floatCast", .operand = "@as(f64, 4.5)", .matches = "value == 4.5" },
        .{ .type = "@Vector(2, usize)", .builtin = "@splat", .operand = "@as(u8, 4)", .matches = "value[0] == 4 and value[1] == 4" },
        .{ .type = "Mode", .builtin = "@enumFromInt", .operand = "@as(u8, 4)", .matches = "value == .selected" },
    };
    for (cases) |case| {
        for ([_]bool{ false, true }) |generic| {
            const source = try std.fmt.allocPrint(allocator,
                \\const Mode = enum(u8) {{ selected = 4, other = 9 }};
                \\fn produce({s}executions: *usize) {s} {{
                \\    defer executions.* = executions.* * 10 + 2;
                \\    return {s}(operand: {{
                \\        executions.* += 1;
                \\        break :operand {s};
                \\    }});
                \\}}
                \\fn Select() type {{
                \\    var executions: usize = 0;
                \\    const value = produce({s}{s}&executions);
                \\    return struct {{
                \\        matched: [if (@TypeOf(value) == {s} and ({s})) 4 else 99]u8,
                \\        executions: [executions]u8,
                \\    }};
                \\}}
                \\const selected: Select() = undefined;
                \\const field = selected.<cursor>
            , .{
                if (generic) "comptime T: type, " else "",
                if (generic) "T" else case.type,
                case.builtin,
                case.operand,
                if (generic) case.type else "",
                if (generic) ", " else "",
                case.type,
                case.matches,
            });
            defer allocator.free(source);
            errdefer std.debug.print("contextual return source:\n{s}\n", .{source});
            try testCompletion(source, &.{
                .{ .label = "matched", .kind = .Field, .detail = "[4]u8" },
                .{ .label = "executions", .kind = .Field, .detail = "[12]u8" },
            });
        }
    }
}

test "comptime interpreter propagates contextual branch and block casts" {
    const wrappers = [_]struct { prefix: []const u8, suffix: []const u8 }{
        .{ .prefix = "(", .suffix = ")" },
        .{ .prefix = "comptime ", .suffix = "" },
        .{ .prefix = "nosuspend ", .suffix = "" },
        .{ .prefix = "if (true) ", .suffix = " else unreachable" },
        .{ .prefix = "if (false) unreachable else ", .suffix = "" },
        .{ .prefix = "switch (@as(u8, 1)) { 1 => ", .suffix = ", else => unreachable }" },
        .{ .prefix = "@as(?Payload, null) orelse ", .suffix = "" },
        .{ .prefix = "result: { break :result ", .suffix = "; }" },
        .{ .prefix = "for (0..1) |_| { break ", .suffix = "; } else unreachable" },
        .{ .prefix = "for (0..0) |_| { unreachable; } else ", .suffix = "" },
        .{ .prefix = "while (true) { break ", .suffix = "; } else unreachable" },
        .{ .prefix = "while (false) { unreachable; } else ", .suffix = "" },
    };
    for (wrappers) |wrapper| {
        for ([_]bool{ false, true }) |vector| {
            const source = try std.fmt.allocPrint(allocator,
                \\const Payload = {s};
                \\fn produce(executions: *usize) Payload {{
                \\    defer executions.* = executions.* * 10 + 2;
                \\    return {s}{s}(operand: {{
                \\        executions.* += 1;
                \\        break :operand @as(u16, 4);
                \\    }}){s};
                \\}}
                \\fn Select() type {{
                \\    var executions: usize = 0;
                \\    const value = produce(&executions);
                \\    return struct {{
                \\        items: [if (@TypeOf(value) == Payload) {s} else 99]u8,
                \\        executions: [executions]u8,
                \\    }};
                \\}}
                \\const selected: Select() = undefined;
                \\const field = selected.<cursor>
            , .{
                if (vector) "@Vector(2, usize)" else "u8",
                wrapper.prefix,
                if (vector) "@splat" else "@intCast",
                wrapper.suffix,
                if (vector) "value[0] + value[1]" else "value",
            });
            defer allocator.free(source);
            errdefer std.debug.print("contextual branch source:\n{s}\n", .{source});
            try testCompletion(source, &.{
                .{ .label = "items", .kind = .Field, .detail = if (vector) "[8]u8" else "[4]u8" },
                .{ .label = "executions", .kind = .Field, .detail = "[12]u8" },
            });
        }
    }
}

test "comptime interpreter isolates nested break result types" {
    try testCompletion(
        \\fn produce(executions: *usize) u8 {
        \\    return outer: {
        \\        defer executions.* = executions.* * 10 + 4;
        \\        const inner = @as(u16, nested: {
        \\            defer executions.* = executions.* * 10 + 2;
        \\            break :nested @intCast(operand: {
        \\                executions.* += 1;
        \\                break :operand @as(u32, 260);
        \\            });
        \\        });
        \\        for (0..1) |_| {
        \\            break :outer @truncate(operand: {
        \\                executions.* = executions.* * 10 + 3;
        \\                break :operand inner;
        \\            });
        \\        }
        \\        unreachable;
        \\    };
        \\}
        \\fn Select() type {
        \\    var executions: usize = 0;
        \\    const value = produce(&executions);
        \\    return struct { items: [value]u8, executions: [executions]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
        .{ .label = "executions", .kind = .Field, .detail = "[1234]u8" },
    });
}

test "comptime interpreter propagates contextual branch casts at typed boundaries" {
    try testCompletion(
        \\fn consume(value: @Vector(2, usize)) usize { return value[0] + value[1]; }
        \\fn Select() type {
        \\    var executions: usize = 0;
        \\    const values = consume(if (true) @splat(operand: {
        \\        executions += 1;
        \\        break :operand @as(u8, 4);
        \\    }) else unreachable);
        \\    const config = struct { count: u8 }{ .count = switch (values) {
        \\        8 => @intCast(operand: {
        \\            executions = executions * 10 + 2;
        \\            break :operand @as(u16, 4);
        \\        }),
        \\        else => unreachable,
        \\    } };
        \\    const count = @as(u8, result: {
        \\        while (true) {
        \\            break :result @intCast(operand: {
        \\                executions = executions * 10 + 3;
        \\                break :operand @as(u16, 4);
        \\            });
        \\        }
        \\        unreachable;
        \\    });
        \\    return struct { items: [values + config.count + count]u8, executions: [executions]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[16]u8" },
        .{ .label = "executions", .kind = .Field, .detail = "[123]u8" },
    });
}

test "comptime interpreter skips unselected contextual cast branches" {
    try testCompletion(
        \\fn produce(comptime selected: bool, executions: *usize) u8 {
        \\    return if (condition: {
        \\        executions.* += 1;
        \\        break :condition selected;
        \\    }) @intCast(operand: {
        \\        executions.* = executions.* * 10 + 2;
        \\        break :operand @as(u16, 4);
        \\    }) else @intCast(operand: {
        \\        executions.* = executions.* * 10 + 3;
        \\        break :operand @as(u16, 7);
        \\    });
        \\}
        \\fn Select() type {
        \\    var then_executions: usize = 0;
        \\    var else_executions: usize = 0;
        \\    const a = produce(true, &then_executions);
        \\    const b = produce(false, &else_executions);
        \\    return struct {
        \\        items: [a + b]u8,
        \\        then_executions: [then_executions]u8,
        \\        else_executions: [else_executions]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[11]u8" },
        .{ .label = "then_executions", .kind = .Field, .detail = "[12]u8" },
        .{ .label = "else_executions", .kind = .Field, .detail = "[13]u8" },
    });
}

test "comptime interpreter preserves unknown contextual branch types" {
    const expressions = [_][]const u8{
        "if (true) @intCast(runtime_u16) else unreachable",
        "result: { break :result @intCast(runtime_u16); }",
        "while (true) { break @intCast(runtime_u16); } else unreachable",
        "if (runtime_bool) @intCast(@as(u16, 4)) else @intCast(@as(u16, 7))",
        "result: { break :result @intCast(@as(u16, 256)); }",
        "for (0..1) |_| { break @intCast(true); } else unreachable",
    };
    for (expressions) |expression| {
        const source = try std.fmt.allocPrint(allocator,
            \\var runtime_u16: u16 = undefined;
            \\var runtime_bool: bool = undefined;
            \\fn produce() u8 {{ return {s}; }}
            \\fn Select() type {{
            \\    var marker: usize = 0;
            \\    marker += 1;
            \\    const value = produce();
            \\    return struct {{ value: @TypeOf(value), items: [value]u8 }};
            \\}}
            \\const selected: Select() = undefined;
            \\const field = selected.<cursor>
        , .{expression});
        defer allocator.free(source);
        errdefer std.debug.print("unknown contextual branch: {s}\n", .{expression});
        try testCompletion(source, &.{
            .{ .label = "value", .kind = .Field, .detail = "u8" },
            .{ .label = "items", .kind = .Field, .detail = "[?]u8" },
        });
    }
}

test "comptime interpreter isolates nested return cast types" {
    try testCompletion(
        \\fn inner(executions: *usize) u16 {
        \\    return @intCast(operand: {
        \\        executions.* = executions.* * 10 + 2;
        \\        break :operand @as(usize, 4);
        \\    });
        \\}
        \\fn outer(executions: *usize) u8 {
        \\    executions.* += 1;
        \\    defer executions.* = executions.* * 10 + 3;
        \\    if (executions.* == 1) return @intCast(inner(executions));
        \\    return 99;
        \\}
        \\fn Select() type {
        \\    var executions: usize = 0;
        \\    const value = outer(&executions);
        \\    return struct {
        \\        items: [if (@TypeOf(value) == u8) value else 99]u8,
        \\        executions: [executions]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
        .{ .label = "executions", .kind = .Field, .detail = "[123]u8" },
    });
}

test "comptime interpreter preserves unknown contextual return types" {
    const cases = [_]struct { type: []const u8, initializer: []const u8, count: []const u8, detail: []const u8 }{
        .{ .type = "u8", .initializer = "@intCast(runtime_u16)", .count = "value", .detail = "u8" },
        .{ .type = "usize", .initializer = "@intFromFloat(runtime_float)", .count = "value", .detail = "usize" },
        .{ .type = "@Vector(2, usize)", .initializer = "@splat(runtime_u8)", .count = "value[0]", .detail = "@Vector(2,usize)" },
        .{ .type = "u8", .initializer = "@intCast(@as(u16, 256))", .count = "value", .detail = "u8" },
        .{ .type = "u8", .initializer = "@intCast(true)", .count = "value", .detail = "u8" },
        .{ .type = "usize", .initializer = "@intFromFloat(@as(f64, -1.5))", .count = "value", .detail = "usize" },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(allocator,
            \\var runtime_u16: u16 = undefined;
            \\var runtime_u8: u8 = undefined;
            \\var runtime_float: f64 = undefined;
            \\fn produce() {s} {{ return {s}; }}
            \\fn Select() type {{
            \\    var marker: usize = 0;
            \\    marker += 1;
            \\    const value = produce();
            \\    return struct {{ result: @TypeOf(value), items: [{s}]u8 }};
            \\}}
            \\const selected: Select() = undefined;
            \\const field = selected.<cursor>
        , .{ case.type, case.initializer, case.count });
        defer allocator.free(source);
        errdefer std.debug.print("unknown return source:\n{s}\n", .{source});
        try testCompletion(source, &.{
            .{ .label = "result", .kind = .Field, .detail = case.detail },
            .{ .label = "items", .kind = .Field, .detail = "[?]u8" },
        });
    }
}

test "comptime interpreter validates float coercion precision" {
    try testCompletion(
        \\fn exact() f32 { return @as(f64, 4.5); }
        \\fn lossy() f32 { return @as(f64, 16777217.0); }
        \\fn explicit() f32 { return @floatCast(@as(f64, 16777217.0)); }
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const a = exact();
        \\    const b = lossy();
        \\    const c = explicit();
        \\    const literal = @as(f32, 16777217.0);
        \\    return struct {
        \\        exact: [if (@TypeOf(a) == f32 and a == 4.5) 1 else 99]u8,
        \\        lossy: [if (b == 16777216.0) 1 else 99]u8,
        \\        explicit: [if (c == 16777216.0) 1 else 99]u8,
        \\        literal: [if (literal == 16777216.0) 1 else 99]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "exact", .kind = .Field, .detail = "[1]u8" },
        .{ .label = "lossy", .kind = .Field, .detail = "[?]u8" },
        .{ .label = "explicit", .kind = .Field, .detail = "[1]u8" },
        .{ .label = "literal", .kind = .Field, .detail = "[1]u8" },
    });
}

test "comptime interpreter preserves dependent call parameter types" {
    try testCompletion(
        \\const Config = struct { capacity: usize };
        \\fn identity(comptime T: type, value: T) T { return value; }
        \\fn inferred(value: anytype) type { return @TypeOf(value); }
        \\fn Select() type {
        \\    const small: u8 = 4;
        \\    var executions: usize = 0;
        \\    const value = identity(Config, argument: {
        \\        executions += 1;
        \\        break :argument .{ .capacity = small };
        \\    });
        \\    const scalar = identity(usize, small);
        \\    const vector = identity(@Vector(2, usize), @splat(@as(u8, 4)));
        \\    return struct {
        \\        aggregate: [value.capacity]u8,
        \\        scalar: [scalar]u8,
        \\        vector: [vector[0]]u8,
        \\        typed: [if (@TypeOf(value.capacity) == usize and @TypeOf(scalar) == usize and inferred(small) == u8) 1 else 99]u8,
        \\        executions: [executions]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "aggregate", .kind = .Field, .detail = "[4]u8" },
        .{ .label = "scalar", .kind = .Field, .detail = "[4]u8" },
        .{ .label = "vector", .kind = .Field, .detail = "[4]u8" },
        .{ .label = "typed", .kind = .Field, .detail = "[1]u8" },
        .{ .label = "executions", .kind = .Field, .detail = "[1]u8" },
    });
}

test "comptime interpreter preserves unknown call boundary elements" {
    try testCompletion(
        \\var runtime_u8: u8 = undefined;
        \\fn identity(value: [2]usize) [2]usize { return value; }
        \\fn produce() [2]usize { return .{ runtime_u8, @as(u8, 4) }; }
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const argument = identity(.{ runtime_u8, @as(u8, 4) });
        \\    const returned = produce();
        \\    return struct {
        \\        unknown: [argument[0] + returned[0]]u8,
        \\        known: [argument[1] + returned[1]]u8,
        \\        typed: [if (@TypeOf(argument[0]) == usize and @TypeOf(returned[0]) == usize) 1 else 99]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "unknown", .kind = .Field, .detail = "[?]u8" },
        .{ .label = "known", .kind = .Field, .detail = "[8]u8" },
        .{ .label = "typed", .kind = .Field, .detail = "[1]u8" },
    });
}

test "comptime interpreter rejects invalid call boundary union payloads" {
    for ([_][]const u8{ "true", "256", "\"invalid\"" }) |initializer| {
        for ([_]bool{ false, true }) |returned| {
            const call = try std.fmt.allocPrint(allocator, "identity(.{{ .count = {s} }})", .{initializer});
            defer allocator.free(call);
            const source = try std.fmt.allocPrint(allocator,
                \\const U = union(enum) {{ count: u8, empty }};
                \\fn identity(value: U) U {{ return value; }}
                \\fn produce() U {{ return .{{ .count = {s} }}; }}
                \\fn Select() type {{
                \\    var marker: usize = 0;
                \\    marker += 1;
                \\    const value = {s};
                \\    return switch (value) {{
                \\        .count => struct {{ accepted: u8 }},
                \\        .empty => struct {{ fallback: u8 }},
                \\    }};
                \\}}
                \\const selected: Select() = undefined;
                \\const field = selected.<cursor>
            , .{
                initializer,
                if (returned) "produce()" else call,
            });
            defer allocator.free(source);
            try testCompletion(source, &.{
                .{ .label = "accepted", .kind = .Field, .detail = "u8" },
                .{ .label = "fallback", .kind = .Field, .detail = "u8" },
            });
        }
    }
}

test "generic function with typed comptime aggregate argument mutations" {
    try testCompletion(
        \\const Config = struct { width: usize };
        \\fn width(comptime config: Config) usize {
        \\    return config.width;
        \\}
        \\fn Buffer(comptime base: usize) type {
        \\    var total: usize = base;
        \\    const selected = width(.{ .width = value: {
        \\        defer total += 1;
        \\        total *= 2;
        \\        break :value total;
        \\    } });
        \\    return struct { items: [selected * total]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[20]u8" },
    });

    try testCompletion(
        \\fn sum(comptime values: [2]usize) usize {
        \\    return values[0] + values[1];
        \\}
        \\fn Buffer(comptime base: usize) type {
        \\    var total: usize = base;
        \\    const selected = sum(.{ value: {
        \\        total += 1;
        \\        break :value total;
        \\    }, value: {
        \\        total *= 2;
        \\        break :value total;
        \\    } });
        \\    return struct { items: [selected * total]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[54]u8" },
    });
}

test "generic function with typed comptime scalar argument mutation" {
    try testCompletion(
        \\fn width(comptime value: u8) usize {
        \\    return if (@TypeOf(value) == u8) value else 99;
        \\}
        \\fn Buffer(comptime base: usize) type {
        \\    var total: usize = base;
        \\    const selected = width(value: {
        \\        defer total += 1;
        \\        total *= 2;
        \\        break :value total;
        \\    });
        \\    return struct { items: [selected * total]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[20]u8" },
    });
}

test "comptime interpreter preserves as aggregate result locations" {
    const cases = [_]struct { type: []const u8, initializer: []const u8, count: []const u8 }{
        .{ .type = "Config", .initializer = ".{}", .count = "value.capacity" },
        .{ .type = "Config", .initializer = ".{ .capacity = small }", .count = "value.capacity" },
        .{ .type = "[1]usize", .initializer = ".{small}", .count = "value[0]" },
        .{ .type = "[1]Config", .initializer = ".{.{}}", .count = "value[0].capacity" },
        .{ .type = "struct { Config, ?usize }", .initializer = ".{ .{}, small }", .count = "value.@\"0\".capacity + value.@\"1\".? - 4" },
        .{ .type = "union(enum) { count: usize, empty }", .initializer = ".{ .count = small }", .count = "value.count" },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(allocator,
            \\const Config = struct {{ capacity: usize = @as(u8, 4) }};
            \\fn Select() type {{
            \\    const small: u8 = 4;
            \\    var executions: usize = 0;
            \\    const value = @as(destination: {{
            \\        executions += 1;
            \\        break :destination {s};
            \\    }}, result: {{
            \\        executions = executions * 10 + 2;
            \\        break :result {s};
            \\    }});
            \\    const count = {s};
            \\    return struct {{
            \\        items: [if (@TypeOf(count) == usize) count else 99]u8,
            \\        executions: [executions]u8,
            \\    }};
            \\}}
            \\const selected: Select() = undefined;
            \\const field = selected.<cursor>
        , .{ case.type, case.initializer, case.count });
        defer allocator.free(source);
        errdefer std.debug.print("as aggregate source:\n{s}\n", .{source});
        try testCompletion(source, &.{
            .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
            .{ .label = "executions", .kind = .Field, .detail = "[12]u8" },
        });
    }
}

test "comptime interpreter preserves nested as aggregate evaluation" {
    try testCompletion(
        \\const Config = struct { capacity: usize = @as(u8, 4) };
        \\fn Select() type {
        \\    var executions: usize = 0;
        \\    const pair = .{ @as(Config, result: {
        \\        executions += 1;
        \\        break :result .{};
        \\    }), @as([1]usize, result: {
        \\        executions = executions * 10 + 2;
        \\        break :result .{@as(u8, 4)};
        \\    }) };
        \\    return struct {
        \\        items: [pair[0].capacity + pair[1][0]]u8,
        \\        executions: [executions]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[8]u8" },
        .{ .label = "executions", .kind = .Field, .detail = "[12]u8" },
    });
}

test "comptime interpreter preserves generated as aggregate values" {
    try testCompletion(
        \\const Config = struct { capacity: usize = @as(u8, 4) };
        \\fn Select() type {
        \\    const S = @Struct(.auto, null, &.{ "config", "sibling" }, &.{ Config, usize }, &.{ .{}, .{} });
        \\    const U = @Union(.auto, @Enum(u8, .exhaustive, &.{ "count", "empty" }, &.{ 0, 1 }), &.{ "count", "empty" }, &.{ usize, void }, &.{ .{}, .{} });
        \\    var state = @as(S, .{ .config = .{}, .sibling = @as(u8, 7) });
        \\    const original = state;
        \\    state.config.capacity += 2;
        \\    const value = @as(U, .{ .count = @as(u8, 4) });
        \\    return switch (value) {
        \\        .count => |count| struct {
        \\            original: [original.config.capacity]u8,
        \\            changed: [state.config.capacity + count]u8,
        \\            sibling: [state.sibling]u8,
        \\        },
        \\        .empty => struct { fallback: u8 },
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "original", .kind = .Field, .detail = "[4]u8" },
        .{ .label = "changed", .kind = .Field, .detail = "[10]u8" },
        .{ .label = "sibling", .kind = .Field, .detail = "[7]u8" },
    });
}

test "comptime interpreter keeps invalid as union payloads unknown" {
    for ([_][]const u8{ "true", "256", "\"invalid\"" }) |payload| {
        const source = try std.fmt.allocPrint(allocator,
            \\const U = union(enum) {{ count: u8, empty }};
            \\fn Select() type {{
            \\    var marker: usize = 0;
            \\    marker += 1;
            \\    const value = @as(U, .{{ .count = {s} }});
            \\    return switch (value) {{
            \\        .count => struct {{ accepted: u8 }},
            \\        .empty => struct {{ fallback: u8 }},
            \\    }};
            \\}}
            \\const selected: Select() = undefined;
            \\const field = selected.<cursor>
        , .{payload});
        defer allocator.free(source);
        try testCompletion(source, &.{
            .{ .label = "accepted", .kind = .Field, .detail = "u8" },
            .{ .label = "fallback", .kind = .Field, .detail = "u8" },
        });
    }
}

test "comptime interpreter preserves unknown as aggregate element types" {
    try testCompletion(
        \\var runtime_u8: u8 = undefined;
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const values = @as([2]usize, .{ runtime_u8, @as(u8, 4) });
        \\    return struct {
        \\        unknown: [values[0]]u8,
        \\        known: [values[1]]u8,
        \\        typed: [if (@TypeOf(values[0]) == usize and @TypeOf(values[1]) == usize) 1 else 99]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "unknown", .kind = .Field, .detail = "[?]u8" },
        .{ .label = "known", .kind = .Field, .detail = "[4]u8" },
        .{ .label = "typed", .kind = .Field, .detail = "[1]u8" },
    });
}

test "generic function with nested comptime as coercion mutation" {
    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    var total: usize = base;
        \\    const selected = @as(u8, value: {
        \\        defer total += 1;
        \\        total *= 2;
        \\        break :value total;
        \\    });
        \\    return struct {
        \\        items: [if (@TypeOf(selected) == u8) selected * total else 99]u8,
        \\    };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[20]u8" },
    });
}

test "generic function preserves runtime unknown comptime as type" {
    try testCompletion(
        \\var runtime_u8: u8 = undefined;
        \\fn Select() type {
        \\    var total: usize = 1;
        \\    const widened = @as(u16, value: {
        \\        total += 1;
        \\        break :value runtime_u8;
        \\    });
        \\    return struct {
        \\        value: @TypeOf(widened),
        \\        items: [total]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[2]u8" },
        .{ .label = "value", .kind = .Field, .detail = "u16" },
    });
}

test "generic function with nested contextual cast mutations" {
    try testCompletion(
        \\fn Select(comptime small: u16, comptime wide: u16, comptime bits: u8, comptime float32: f32, comptime float64: f64) type {
        \\    var int_cast_total: usize = 1;
        \\    var truncate_total: usize = 1;
        \\    var bit_cast_total: usize = 1;
        \\    var int_from_float_total: usize = 1;
        \\    var float_from_int_total: usize = 1;
        \\    var float_cast_total: usize = 1;
        \\    const int_casted = @as(u8, @intCast(value: { int_cast_total *= 2; break :value small; }));
        \\    const truncated = @as(u8, @truncate(value: { truncate_total *= 2; break :value wide; }));
        \\    const bit_casted = @as(i8, @bitCast(value: { bit_cast_total *= 2; break :value bits; }));
        \\    const int_from_float = @as(u8, @intFromFloat(value: { int_from_float_total *= 2; break :value float32; }));
        \\    const float_from_int = @as(f32, @floatFromInt(value: { float_from_int_total *= 2; break :value small; }));
        \\    const float_casted = @as(f32, @floatCast(value: { float_cast_total *= 2; break :value float64; }));
        \\    return if (int_casted == 4 and truncated == 4 and bit_casted == -1 and
        \\        int_from_float == 4 and float_from_int == 4.0 and float_casted == 4.5)
        \\        struct {
        \\            int_cast_order: [int_cast_total]u8,
        \\            truncate_order: [truncate_total]u8,
        \\            bit_cast_order: [bit_cast_total]u8,
        \\            int_from_float_order: [int_from_float_total]u8,
        \\            float_from_int_order: [float_from_int_total]u8,
        \\            float_cast_order: [float_cast_total]u8,
        \\        }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4, 0x104, 255, 4.75, 4.5) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "int_cast_order", .kind = .Field, .detail = "[2]u8" },
        .{ .label = "truncate_order", .kind = .Field, .detail = "[2]u8" },
        .{ .label = "bit_cast_order", .kind = .Field, .detail = "[2]u8" },
        .{ .label = "int_from_float_order", .kind = .Field, .detail = "[2]u8" },
        .{ .label = "float_from_int_order", .kind = .Field, .detail = "[2]u8" },
        .{ .label = "float_cast_order", .kind = .Field, .detail = "[2]u8" },
    });

    try testCompletion(
        \\fn Select(comptime source: @Vector(2, u16)) type {
        \\    var total: usize = 1;
        \\    const values = @as(@Vector(2, u8), @intCast(operand: {
        \\        total *= 2;
        \\        break :operand source;
        \\    }));
        \\    return if (values[0] == 4 and values[1] == 7)
        \\        struct { vector_order: [total]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(.{ 4, 7 }) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "vector_order", .kind = .Field, .detail = "[2]u8" },
    });
}

test "generic function preserves runtime unknown contextual cast types" {
    try testCompletion(
        \\var runtime_u16: u16 = undefined;
        \\var runtime_u8: u8 = undefined;
        \\var runtime_f32: f32 = undefined;
        \\var runtime_f64: f64 = undefined;
        \\fn Select() type {
        \\    var total: usize = 1;
        \\    const int_casted = @as(u8, @intCast(value: { total += 1; break :value runtime_u16; }));
        \\    const truncated = @as(u8, @truncate(value: { total += 1; break :value runtime_u16; }));
        \\    const bit_casted = @as(i8, @bitCast(value: { total += 1; break :value runtime_u8; }));
        \\    const int_from_float = @as(u8, @intFromFloat(value: { total += 1; break :value runtime_f32; }));
        \\    const float_from_int = @as(f32, @floatFromInt(value: { total += 1; break :value runtime_u16; }));
        \\    const float_casted = @as(f32, @floatCast(value: { total += 1; break :value runtime_f64; }));
        \\    return struct {
        \\        int_casted: @TypeOf(int_casted),
        \\        truncated: @TypeOf(truncated),
        \\        bit_casted: @TypeOf(bit_casted),
        \\        int_from_float: @TypeOf(int_from_float),
        \\        float_from_int: @TypeOf(float_from_int),
        \\        float_casted: @TypeOf(float_casted),
        \\        items: [total]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "bit_casted", .kind = .Field, .detail = "i8" },
        .{ .label = "float_casted", .kind = .Field, .detail = "f32" },
        .{ .label = "float_from_int", .kind = .Field, .detail = "f32" },
        .{ .label = "int_casted", .kind = .Field, .detail = "u8" },
        .{ .label = "int_from_float", .kind = .Field, .detail = "u8" },
        .{ .label = "items", .kind = .Field, .detail = "[7]u8" },
        .{ .label = "truncated", .kind = .Field, .detail = "u8" },
    });
}

test "generic function preserves runtime unknown contextual vector cast types" {
    try testCompletion(
        \\var runtime_u16: @Vector(2, u16) = undefined;
        \\var runtime_f32: @Vector(2, f32) = undefined;
        \\var runtime_f64: @Vector(2, f64) = undefined;
        \\fn Select() type {
        \\    var total: usize = 1;
        \\    const int_casted = @as(@Vector(2, u8), @intCast(value: { total += 1; break :value runtime_u16; }));
        \\    const truncated = @as(@Vector(2, u8), @truncate(value: { total += 1; break :value runtime_u16; }));
        \\    const int_from_float = @as(@Vector(2, u8), @intFromFloat(value: { total += 1; break :value runtime_f32; }));
        \\    const float_from_int = @as(@Vector(2, f32), @floatFromInt(value: { total += 1; break :value runtime_u16; }));
        \\    const float_casted = @as(@Vector(2, f32), @floatCast(value: { total += 1; break :value runtime_f64; }));
        \\    return struct {
        \\        int_casted: @TypeOf(int_casted),
        \\        truncated: @TypeOf(truncated),
        \\        int_from_float: @TypeOf(int_from_float),
        \\        float_from_int: @TypeOf(float_from_int),
        \\        float_casted: @TypeOf(float_casted),
        \\        items: [total]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "float_casted", .kind = .Field, .detail = "@Vector(2,f32)" },
        .{ .label = "float_from_int", .kind = .Field, .detail = "@Vector(2,f32)" },
        .{ .label = "int_casted", .kind = .Field, .detail = "@Vector(2,u8)" },
        .{ .label = "int_from_float", .kind = .Field, .detail = "@Vector(2,u8)" },
        .{ .label = "items", .kind = .Field, .detail = "[6]u8" },
        .{ .label = "truncated", .kind = .Field, .detail = "@Vector(2,u8)" },
    });
}

test "generic function preserves runtime unknown contextual vector bitCast type" {
    try testCompletion(
        \\var runtime_vector: @Vector(2, u16) = undefined;
        \\fn Select() type {
        \\    var total: usize = 1;
        \\    const bit_casted = @as(@Vector(4, u8), @bitCast(value: {
        \\        total += 1;
        \\        break :value runtime_vector;
        \\    }));
        \\    return struct {
        \\        value: @TypeOf(bit_casted),
        \\        items: [total]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[2]u8" },
        .{ .label = "value", .kind = .Field, .detail = "@Vector(4,u8)" },
    });
}

test "generic function preserves runtime unknown general bitCast types" {
    try testCompletion(
        \\var runtime_scalar: u32 = undefined;
        \\var runtime_float: f32 = undefined;
        \\var runtime_vector: @Vector(4, u8) = undefined;
        \\var runtime_array: [4]u8 = undefined;
        \\fn Select() type {
        \\    var total: usize = 0;
        \\    const vector = @as(@Vector(4, u8), @bitCast(value: {
        \\        total += 1;
        \\        break :value runtime_scalar;
        \\    }));
        \\    const scalar = @as(u32, @bitCast(value: {
        \\        total += 1;
        \\        break :value runtime_vector;
        \\    }));
        \\    const float_bits = @as(u32, @bitCast(value: {
        \\        total += 1;
        \\        break :value runtime_float;
        \\    }));
        \\    const array = @as([4]u8, @bitCast(value: {
        \\        total += 1;
        \\        break :value runtime_vector;
        \\    }));
        \\    const array_vector = @as(@Vector(4, u8), @bitCast(value: {
        \\        total += 1;
        \\        break :value runtime_array;
        \\    }));
        \\    return struct {
        \\        vector: @TypeOf(vector),
        \\        scalar: @TypeOf(scalar),
        \\        float_bits: @TypeOf(float_bits),
        \\        array: @TypeOf(array),
        \\        array_vector: @TypeOf(array_vector),
        \\        items: [total]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "array", .kind = .Field, .detail = "[4]u8" },
        .{ .label = "array_vector", .kind = .Field, .detail = "@Vector(4,u8)" },
        .{ .label = "float_bits", .kind = .Field, .detail = "u32" },
        .{ .label = "items", .kind = .Field, .detail = "[5]u8" },
        .{ .label = "scalar", .kind = .Field, .detail = "u32" },
        .{ .label = "vector", .kind = .Field, .detail = "@Vector(4,u8)" },
    });
}

test "generic function with comptime unknown field expressions" {
    try testCompletion(
        \\fn Vector(comptime N: usize, comptime T: type) type {
        \\    return struct { items: [N + 1]T };
        \\}
        \\const vector: Vector(undefined, u8) = undefined;
        \\const items = vector.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[?]u8" },
    });
    try testCompletion(
        \\fn Vector(comptime N: usize, comptime T: type) type {
        \\    return struct { items: [N / 0]T };
        \\}
        \\const vector: Vector(4, u8) = undefined;
        \\const items = vector.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[?]u8" },
    });
}

test "generic function with comptime condition" {
    try testCompletion(
        \\fn Select(comptime value: f32) type {
        \\    return if (value == 4 and value > 3 and -value < -3)
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4.0) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });
    try testCompletion(
        \\fn Select(comptime value: f32) type {
        \\    return if (value != 16777217 and value < 16777217)
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(16777216.0) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime lhs: f32, comptime rhs: f64) type {
        \\    return if (lhs + rhs == 8.0 and lhs - rhs == 4.0 and
        \\        lhs * rhs == 12.0 and lhs / rhs == 3.0)
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(6.0, 2.0) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime lhs: f32, comptime rhs: f64) type {
        \\    return if (lhs == rhs and -42.5 < lhs and @as(f32, -0.0) == @as(f64, 0.0))
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(42.5, 42.5) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime value: u128) type {
        \\    return if (value > 5 and value == 340282366920938463463374607431768211455)
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(340282366920938463463374607431768211455) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime name: anytype) type {
        \\    return if (name[name.len] == 0)
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select("field") = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });
    try testCompletion(
        \\fn Select(comptime name: [:0]const u8) type {
        \\    return if (name[name.len] == 0)
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select("field") = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime name: []const u8) type {
        \\    return if (name.len == 5 and name[0] == 'f')
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select("field") = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });
    try testCompletion(
        \\fn Select(comptime name: []const u8) type {
        \\    return if (name[0] == 'f')
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select("other") = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "fallback", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime enabled: bool) type {
        \\    return if (enabled)
        \\        struct { active: u8 }
        \\    else
        \\        struct { inactive: u8 };
        \\}
        \\const selected: Select(true) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "active", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime enabled: bool) type {
        \\    return if (enabled)
        \\        struct { active: u8 }
        \\    else
        \\        struct { inactive: u8 };
        \\}
        \\const selected: Select(false) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "inactive", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime width: usize) type {
        \\    return if (width == 4)
        \\        struct { exact: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(2 + 2) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "exact", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime enabled: bool) type {
        \\    return if (enabled and @compileError("unselected"))
        \\        struct { active: u8 }
        \\    else
        \\        struct { inactive: u8 };
        \\}
        \\const selected: Select(false) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "inactive", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime enabled: bool) type {
        \\    return if (enabled or @compileError("unselected"))
        \\        struct { active: u8 }
        \\    else
        \\        struct { inactive: u8 };
        \\}
        \\const selected: Select(true) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "active", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime width: usize) type {
        \\    return if (width == width)
        \\        struct { exact: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(undefined) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "exact", .kind = .Field, .detail = "u8" },
        .{ .label = "fallback", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime bits: u8) type {
        \\    return if (~bits == 0)
        \\        struct { zero: u8 }
        \\    else
        \\        struct { nonzero: u8 };
        \\}
        \\const selected: Select(255) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "zero", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime value: u8) type {
        \\    return if (-%value == 255)
        \\        struct { wrapped: u8 }
        \\    else
        \\        struct { other: u8 };
        \\}
        \\const selected: Select(1) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "wrapped", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime value: i8) type {
        \\    return if (@TypeOf(-value) == i8 and -value == -1)
        \\        struct { negated: u8 }
        \\    else
        \\        struct { other: u8 };
        \\}
        \\const selected: Select(1) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "negated", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime signed: i128, comptime unsigned: u128) type {
        \\    return if (@abs(signed) == 170141183460469231731687303715884105728 and
        \\        -%signed == signed and ~unsigned == 170141183460469231731687303715884105727)
        \\        struct { wide: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(-170141183460469231731687303715884105728, 170141183460469231731687303715884105728) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "wide", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime signed: i128, comptime unsigned: u128) type {
        \\    return if (unsigned +% 1 == 0 and unsigned +| 1 == unsigned and
        \\        @as(u128, 1) -% 2 == unsigned and @as(u128, 1) -| 2 == 0 and
        \\        @as(u128, 170141183460469231731687303715884105728) <<| 1 == unsigned and
        \\        signed +% 1 == -170141183460469231731687303715884105728 and signed +| 1 == signed)
        \\        struct { wide: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(170141183460469231731687303715884105727, 340282366920938463463374607431768211455) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "wide", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime enabled: bool, comptime T: type) type {
        \\    return if (enabled == true and T != u16)
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(true, u8) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with comptime switch" {
    const cases = [_]struct { value: []const u8, label: []const u8 }{
        .{ .value = "0", .label = "zero" },
        .{ .value = "4", .label = "even" },
        .{ .value = "7", .label = "range" },
        .{ .value = "9", .label = "fallback" },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(allocator,
            \\fn Select(comptime N: usize) type {{
            \\    return switch (N) {{
            \\        0 => struct {{ zero: u8 }},
            \\        2, 4 => struct {{ even: u8 }},
            \\        5...8 => struct {{ range: u8 }},
            \\        else => struct {{ fallback: u8 }},
            \\    }};
            \\}}
            \\const selected: Select({s}) = undefined;
            \\const field = selected.<cursor>
        , .{case.value});
        defer allocator.free(source);
        try testCompletion(source, &.{
            .{ .label = case.label, .kind = .Field, .detail = "u8" },
        });
    }

    try testCompletion(
        \\fn Select(comptime N: usize) type {
        \\    return switch (N) {
        \\        0 => struct { zero: u8 },
        \\        else => struct { fallback: u8 },
        \\    };
        \\}
        \\const selected: Select(undefined) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "zero", .kind = .Field, .detail = "u8" },
        .{ .label = "fallback", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime value: u21) type {
        \\    return switch (value) {
        \\        'A' => struct { ascii: u8 },
        \\        '界' => struct { unicode: u8 },
        \\        else => struct { fallback: u8 },
        \\    };
        \\}
        \\const selected: Select('界') = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "unicode", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with comptime enum switch" {
    try testCompletion(
        \\const Mode = enum { fast, safe };
        \\fn Select(comptime name: []const u8) type {
        \\    const mode = @field(Mode, name);
        \\    return if (mode == .safe and @tagName(mode)[0] == 's')
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select("safe") = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });
    try testCompletion(
        \\const Mode = enum { @"safe mode" };
        \\fn Select(comptime name: []const u8) type {
        \\    const mode = @field(Mode, name);
        \\    return if (@tagName(mode)[4] == ' ')
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select("safe mode") = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\const Mode = enum { fast, safe };
        \\fn Select(comptime mode: anytype) type {
        \\    return if (@TypeOf(mode) == Mode and mode == .safe and @tagName(mode)[0] == 's')
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(@as(Mode, .safe)) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\const Mode = enum { fast, safe };
        \\fn Select(comptime mode: Mode) type {
        \\    return switch (mode) {
        \\        .fast => struct { optimized: u8 },
        \\        .safe => struct { checked: u8 },
        \\    };
        \\}
        \\const selected: Select(.fast) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "optimized", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\const Mode = enum { fast, safe };
        \\fn Select(comptime mode: Mode) type {
        \\    return if (mode == .safe)
        \\        struct { checked: u8 }
        \\    else
        \\        struct { optimized: u8 };
        \\}
        \\const selected: Select(Mode.safe) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "checked", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\const Mode = enum { fast, safe };
        \\fn Select(comptime mode: Mode) type {
        \\    return if (mode == .safe)
        \\        struct { checked: u8 }
        \\    else
        \\        struct { optimized: u8 };
        \\}
        \\var mode: Mode = .safe;
        \\const selected: Select(mode) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "checked", .kind = .Field, .detail = "u8" },
        .{ .label = "optimized", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\const Mode = enum { fast, safe };
        \\fn Select(comptime mode: Mode) type {
        \\    return if (mode == .safe)
        \\        struct { checked: u8 }
        \\    else
        \\        struct { optimized: u8 };
        \\}
        \\const mode: Mode = .safe;
        \\const selected: Select(mode) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "checked", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\const Mode = enum { fast, safe };
        \\fn Select(comptime mode: Mode) type {
        \\    return switch (mode) {
        \\        Mode.fast => struct { optimized: u8 },
        \\        Mode.safe => struct { checked: u8 },
        \\    };
        \\}
        \\const mode = Mode.fast;
        \\const selected: Select(mode) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "optimized", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\const Mode = enum { fast, safe };
        \\fn Inner(comptime mode: Mode) type {
        \\    return if (mode == .safe)
        \\        struct { checked: u8 }
        \\    else
        \\        struct { optimized: u8 };
        \\}
        \\fn Outer(comptime mode: Mode) type {
        \\    return struct { inner: Inner(mode) };
        \\}
        \\const selected: Outer(.safe) = undefined;
        \\const field = selected.inner.<cursor>
    , &.{
        .{ .label = "checked", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with comptime switch return statements" {
    try testCompletion(
        \\fn Select(comptime signed: i256, comptime unsigned: u256) type {
        \\    const minimum: i256 = -57896044618658097711785492504343953926634992332820282019728792003956564819968;
        \\    const high: u256 = 57896044618658097711785492504343953926634992332820282019728792003956564819968;
        \\    return if (unsigned +% 1 == 0 and unsigned +| 1 == unsigned and
        \\        @as(u256, 1) -% 2 == unsigned and @as(u256, 1) -| 2 == 0 and
        \\        high *% 2 == 0 and high *| 2 == unsigned and high <<| 2 == unsigned and
        \\        signed +% 1 == minimum and signed +| 1 == signed and
        \\        minimum -% 1 == signed and minimum -| 1 == minimum)
        \\        struct { wide: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(57896044618658097711785492504343953926634992332820282019728792003956564819967, 115792089237316195423570985008687907853269984665640564039457584007913129639935) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "wide", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime N: u8) type {
        \\    switch (N) {
        \\        0 => return struct { zero: u8 },
        \\        1...3 => return struct { range: u8 },
        \\        else => return struct { fallback: u8 },
        \\    }
        \\}
        \\const selected: Select(2) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "range", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\const Mode = enum { fast, safe };
        \\fn Select(comptime mode: Mode) type {
        \\    switch (mode) {
        \\        .fast => return struct { optimized: u8 },
        \\        .safe => return struct { checked: u8 },
        \\    }
        \\}
        \\const selected: Select(.safe) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "checked", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with runtime switch before return" {
    try testCompletion(
        \\var runtime: u8 = undefined;
        \\fn Select(comptime N: u8) type {
        \\    switch (runtime) {
        \\        0 => _ = N,
        \\        1...3 => _ = N + 1,
        \\        else => _ = N + 2,
        \\    }
        \\    return struct { selected: [N]u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with identical runtime switch return types" {
    try testCompletion(
        \\var runtime: u8 = undefined;
        \\fn Select(comptime N: u8) type {
        \\    const Result = struct { matched: [N]u8 };
        \\    switch (runtime) {
        \\        0 => return Result,
        \\        1...3 => return Result,
        \\        else => return Result,
        \\    }
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with runtime while before return" {
    try testCompletion(
        \\var runtime: bool = undefined;
        \\fn Select(comptime N: u8) type {
        \\    while (runtime) {
        \\        break;
        \\    } else {
        \\        _ = N;
        \\    }
        \\    return struct { selected: [N]u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with peer-typed loop expressions" {
    try testCompletion(
        \\var runtime: bool = undefined;
        \\fn Select(comptime N: u8) type {
        \\    const while_value = while (runtime) {
        \\        if (runtime) break @as(u8, N);
        \\        break @as(u16, N + 300);
        \\    } else @as(u8, N + 2);
        \\    const for_value = for ([_]u8{ 1, 2 }) |_| {
        \\        if (runtime) break @as(u8, N + 3);
        \\        break @as(u16, N + 300);
        \\    } else @as(u8, N + 5);
        \\    return if (@TypeOf(while_value) == u16 and @TypeOf(for_value) == u16)
        \\        struct { merged: [N]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "merged", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with comptime destructuring assignment" {
    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    var width: usize = 1;
        \\    var height: usize = 2;
        \\    width, height = [_]usize{ height + base, width + 2 };
        \\    return struct { items: [width * height]u8 };
        \\}
        \\const buffer: Buffer(3) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[15]u8" },
    });

    try testCompletion(
        \\const State = struct { dimensions: [2]usize };
        \\fn Buffer(comptime base: usize) type {
        \\    var state = State{ .dimensions = [2]usize{ 1, 2 } };
        \\    state.dimensions[0], state.dimensions[1] = [_]usize{ base + 1, 6 };
        \\    return struct { items: [state.dimensions[0] * state.dimensions[1]]u8 };
        \\}
        \\const buffer: Buffer(4) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[30]u8" },
    });

    try testCompletion(
        \\fn Buffer() type {
        \\    var width: usize = 2;
        \\    var height: usize = 3;
        \\    width, _, height = .{ height, 99, width };
        \\    return struct { items: [width * height]u8 };
        \\}
        \\const buffer: Buffer() = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[6]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    const width, var height: usize = .{ base + 1, 2 };
        \\    height += width;
        \\    return struct { items: [width * height]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[15]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    const width: usize, const height: usize = .{ base + 1, 2 };
        \\    return struct { items: [width * height]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[6]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    var depth: usize = 1;
        \\    const width: usize, depth, var height = [_]usize{ base + 1, 4, 2 };
        \\    height *= width;
        \\    depth += height;
        \\    return struct { items: [width * depth]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[30]u8" },
    });
}

test "generic function with comptime tuple field mutation" {
    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    var dimensions = .{ @as(usize, 1), @as(usize, 2) };
        \\    dimensions.@"0" += base;
        \\    dimensions.@"1" *= 3;
        \\    return struct { items: [dimensions.@"0" * dimensions.@"1"]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[18]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    var state = .{ @as(usize, 2), .{ @as(usize, 3), @as(usize, 4) } };
        \\    state.@"0" += base;
        \\    state.@"1".@"1" += base;
        \\    return struct { items: [state.@"0" * state.@"1".@"0" * state.@"1".@"1"]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[72]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    var dimensions = .{ @as(usize, 1), @as(usize, 2) };
        \\    const dimensions_ptr = &dimensions;
        \\    dimensions_ptr.*.@"0" += base;
        \\    dimensions_ptr.*.@"1" *= 3;
        \\    return struct { items: [dimensions.@"0" * dimensions.@"1"]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[18]u8" },
    });
}

test "generic function with comptime while expression branches" {
    try testCompletion(
        \\fn Select(comptime enabled: bool, comptime N: u8) type {
        \\    const count = while (enabled) {
        \\        break N;
        \\    } else @as(u16, N + 300);
        \\    return struct { selected: [count]u8 };
        \\}
        \\const selected: Select(true, 4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "[4]u8" },
    });

    try testCompletion(
        \\fn Select(comptime enabled: bool, comptime N: u8) type {
        \\    const count = while (enabled) {
        \\        break @as(u16, N + 300);
        \\    } else N;
        \\    return struct { selected: [count]u8 };
        \\}
        \\const selected: Select(false, 4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "[4]u8" },
    });

    try testCompletion(
        \\fn Select(comptime enabled: bool, comptime N: u8) type {
        \\    const count = while (enabled) {
        \\        break N;
        \\    };
        \\    return struct { selected: [count]u8 };
        \\}
        \\const selected: Select(true, 4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "[4]u8" },
    });

    try testCompletion(
        \\fn Select(comptime enabled: bool) type {
        \\    const value = while (enabled) {
        \\        unreachable;
        \\    };
        \\    return if (@TypeOf(value) == void)
        \\        struct { selected: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(false) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with empty for expression" {
    try testCompletion(
        \\fn Select(comptime N: u8) type {
        \\    const count = for ([_]u8{}, 0..) |_, _| {
        \\        break @as(u16, N + 300);
        \\    } else N;
        \\    return struct { selected: [count]u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "[4]u8" },
    });

    try testCompletion(
        \\fn Select() type {
        \\    const value = for ([_]u8{}) |_| {
        \\        unreachable;
        \\    };
        \\    return if (@TypeOf(value) == void)
        \\        struct { selected: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime N: u8) type {
        \\    const count = for (N..N) |_| {
        \\        break @as(u16, N + 300);
        \\    } else N;
        \\    return struct { selected: [count]u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with empty for return statements" {
    try testCompletion(
        \\fn Select(comptime N: u8) type {
        \\    for (N..N) |_| {
        \\        return struct { unreachable_body: u8 };
        \\    }
        \\    return struct { selected: [N]u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "[4]u8" },
    });

    try testCompletion(
        \\fn Select(comptime N: u8) type {
        \\    for ([_]u8{}) |_| {
        \\        return struct { unreachable_body: u8 };
        \\    } else {
        \\        return struct { selected_else: [N]u8 };
        \\    }
        \\    return struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected_else", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with comptime while return statements" {
    try testCompletion(
        \\fn Select(comptime enabled: bool) type {
        \\    while (!enabled) {
        \\        return struct { unreachable_branch: u8 };
        \\    }
        \\    return struct { selected: u8 };
        \\}
        \\const selected: Select(true) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime enabled: bool) type {
        \\    while (!enabled) {} else {
        \\        return struct { selected_else: u8 };
        \\    }
        \\    return struct { fallback: u8 };
        \\}
        \\const selected: Select(true) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected_else", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime enabled: bool) type {
        \\    while (enabled) {
        \\        return struct { selected_body: u8 };
        \\    }
        \\    return struct { fallback: u8 };
        \\}
        \\const selected: Select(true) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected_body", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with comptime while mutation" {
    try testCompletion(
        \\fn Buffer(comptime limit: usize) type {
        \\    var index: usize = 0;
        \\    var capacity: usize = 1;
        \\    while (index < limit) : (index += 1) {
        \\        if (index == 1) continue;
        \\        capacity *= 2;
        \\    }
        \\    return struct { items: [capacity]u8 };
        \\}
        \\const buffer: Buffer(4) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[8]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime limit: usize) type {
        \\    var index: usize = 0;
        \\    var capacity: usize = 1;
        \\    while (index < limit) : (index += 1) {
        \\        capacity += 2;
        \\        if (capacity == 5) break;
        \\    } else {
        \\        capacity = 100;
        \\    }
        \\    return struct { items: [capacity]u8 };
        \\}
        \\const buffer: Buffer(4) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[5]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime limit: usize) type {
        \\    var index: usize = 0;
        \\    var capacity: usize = 1;
        \\    while (index < limit) : (index += 1) capacity *= 2 else capacity += 1;
        \\    return struct { items: [capacity]u8 };
        \\}
        \\const buffer: Buffer(3) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[9]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime limit: ?u8) type {
        \\    var current = limit;
        \\    var capacity: u8 = 1;
        \\    while (current) |value| : (current = null) {
        \\        capacity += value;
        \\    } else {
        \\        capacity += 1;
        \\    }
        \\    return struct { items: [capacity]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
    });
}

test "comptime interpreter evaluates switch conditions once" {
    try testCompletion(
        \\fn Select() type {
        \\    var value: u8 = 4;
        \\    var evaluations: usize = 0;
        \\    const selected = switch (condition: {
        \\        evaluations += 1;
        \\        break :condition value;
        \\    }) {
        \\        1...5 => |captured| result: {
        \\            value = 9;
        \\            break :result captured + captured;
        \\        },
        \\        else => 99,
        \\    };
        \\    return struct { items: [selected]u8, evaluations: [evaluations]u8, changed: [value]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[8]u8" },
        .{ .label = "evaluations", .kind = .Field, .detail = "[1]u8" },
        .{ .label = "changed", .kind = .Field, .detail = "[9]u8" },
    });
}

test "comptime interpreter snapshots switch union captures" {
    for ([_]bool{ false, true }) |inline_tag| {
        const source = try std.fmt.allocPrint(allocator,
            \\const U = union(enum) {{ count: usize, empty }};
            \\fn Select() type {{
            \\    var value = U{{ .count = 4 }};
            \\    var evaluations: usize = 0;
            \\    const selected = switch (condition: {{
            \\        evaluations += 1;
            \\        break :condition value;
            \\    }}) {{
            \\        {s}.count => |captured{s}| result: {{
            \\            value = .{{ .empty = {{}} }};
            \\            break :result {s}captured + captured{s};
            \\        }},
            \\        .empty => 99,
            \\    }};
            \\    return struct {{ items: [selected]u8, evaluations: [evaluations]u8 }};
            \\}}
            \\const selected: Select() = undefined;
            \\const field = selected.<cursor>
        , .{
            if (inline_tag) "inline " else "",
            if (inline_tag) ", tag" else "",
            if (inline_tag) "if (tag == .count) " else "",
            if (inline_tag) " else 99" else "",
        });
        defer allocator.free(source);
        try testCompletion(source, &.{
            .{ .label = "items", .kind = .Field, .detail = "[8]u8" },
            .{ .label = "evaluations", .kind = .Field, .detail = "[1]u8" },
        });
    }
}

test "comptime interpreter evaluates switch pointer lvalues once" {
    try testCompletion(
        \\const U = union(enum) { count: usize, empty };
        \\fn Select() type {
        \\    var values: [1][2]U = .{.{ .{ .count = 4 }, .{ .count = 7 } }};
        \\    var evaluations: usize = 0;
        \\    switch (values[row: {
        \\        evaluations += 1;
        \\        break :row 0;
        \\    }][column: {
        \\        evaluations = evaluations * 10 + 2;
        \\        break :column 0;
        \\    }]) {
        \\        .count => |*payload| payload.* += 2,
        \\        .empty => {},
        \\    }
        \\    return struct {
        \\        changed: [values[0][0].count]u8,
        \\        sibling: [values[0][1].count]u8,
        \\        evaluations: [evaluations]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "changed", .kind = .Field, .detail = "[6]u8" },
        .{ .label = "sibling", .kind = .Field, .detail = "[7]u8" },
        .{ .label = "evaluations", .kind = .Field, .detail = "[12]u8" },
    });
}

test "comptime interpreter snapshots switch type info captures" {
    try testCompletion(
        \\fn Select() type {
        \\    var T: type = u8;
        \\    var evaluations: usize = 0;
        \\    const bits = switch (condition: {
        \\        evaluations += 1;
        \\        break :condition @typeInfo(T);
        \\    }) {
        \\        .int => |info| result: {
        \\            T = u16;
        \\            break :result info.bits + info.bits;
        \\        },
        \\        else => 99,
        \\    };
        \\    return struct { items: [bits]u8, evaluations: [evaluations]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[16]u8" },
        .{ .label = "evaluations", .kind = .Field, .detail = "[1]u8" },
    });
}

test "comptime interpreter preserves switch else capture semantics" {
    for ([_]bool{ false, true }) |inline_else| {
        const source = try std.fmt.allocPrint(allocator,
            \\const U = union(enum) {{ count: usize, empty }};
            \\fn Select() type {{
            \\    var value = U{{ .count = 4 }};
            \\    var evaluations: usize = 0;
            \\    const selected = switch (condition: {{
            \\        evaluations += 1;
            \\        break :condition value;
            \\    }}) {{
            \\        .empty => 99,
            \\        {s}else => |captured| result: {{
            \\            value = .{{ .empty = {{}} }};
            \\            break :result {s};
            \\        }},
            \\    }};
            \\    return struct {{ items: [selected]u8, evaluations: [evaluations]u8 }};
            \\}}
            \\const selected: Select() = undefined;
            \\const field = selected.<cursor>
        , .{
            if (inline_else) "inline " else "",
            if (inline_else) "captured + captured" else "captured.count + captured.count",
        });
        defer allocator.free(source);
        errdefer std.debug.print("switch else source:\n{s}\n", .{source});
        try testCompletion(source, &.{
            .{ .label = "items", .kind = .Field, .detail = "[8]u8" },
            .{ .label = "evaluations", .kind = .Field, .detail = "[1]u8" },
        });
    }
}

test "comptime interpreter snapshots generated switch tags" {
    try testCompletion(
        \\fn Select() type {
        \\    const Tag = @Enum(u8, .exhaustive, &.{ "count", "empty" }, &.{ 0, 1 });
        \\    const U = @Union(.auto, Tag, &.{ "count", "empty" }, &.{ usize, void }, &.{ .{}, .{} });
        \\    var value = U{ .count = 4 };
        \\    var evaluations: usize = 0;
        \\    const selected = switch (condition: {
        \\        evaluations += 1;
        \\        break :condition value;
        \\    }) {
        \\        inline .count, .empty => |payload, tag| result: {
        \\            value = .{ .empty = {} };
        \\            break :result if (tag == .count) payload + payload else 99;
        \\        },
        \\    };
        \\    return struct { items: [selected]u8, evaluations: [evaluations]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[8]u8" },
        .{ .label = "evaluations", .kind = .Field, .detail = "[1]u8" },
    });
}

test "comptime interpreter preserves switch condition uncertainty" {
    try testCompletion(
        \\const U = union(enum) { count: usize, empty };
        \\var runtime: usize = undefined;
        \\fn Select() type {
        \\    var evaluations: usize = 0;
        \\    const value = U{ .count = runtime };
        \\    return switch (condition: {
        \\        evaluations += 1;
        \\        break :condition value;
        \\    }) {
        \\        .count => |payload| struct { items: [payload]u8, evaluations: [evaluations]u8 },
        \\        .empty => struct { fallback: u8 },
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[?]u8" },
        .{ .label = "evaluations", .kind = .Field, .detail = "[1]u8" },
    });

    try testCompletion(
        \\var runtime: u8 = undefined;
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    return switch (runtime) {
        \\        4 => struct { matched: u8 },
        \\        else => struct { fallback: u8 },
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
        .{ .label = "fallback", .kind = .Field, .detail = "u8" },
    });
}

test "comptime interpreter evaluates unknown switch conditions once" {
    try testCompletion(
        \\var runtime: u8 = undefined;
        \\fn condition(evaluations: *usize) u8 {
        \\    evaluations.* += 1;
        \\    return runtime;
        \\}
        \\fn Select() type {
        \\    var evaluations: usize = 0;
        \\    const selected = switch (condition(&evaluations)) {
        \\        4 => @as(usize, 4),
        \\        else => @as(usize, 7),
        \\    };
        \\    return struct { items: [selected]u8, evaluations: [evaluations]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[?]u8" },
        .{ .label = "evaluations", .kind = .Field, .detail = "[1]u8" },
    });
}

test "comptime interpreter evaluates labeled switch loops" {
    try testCompletion(
        \\fn Select() type {
        \\    var trace: usize = 0;
        \\    state: switch (@as(u8, 0)) {
        \\        0 => {
        \\            defer trace = trace * 10 + 1;
        \\            continue :state 1;
        \\        },
        \\        1 => {
        \\            defer trace = trace * 10 + 2;
        \\            continue :state 2;
        \\        },
        \\        2 => {
        \\            defer trace = trace * 10 + 3;
        \\            break :state;
        \\        },
        \\        else => unreachable,
        \\    }
        \\    return struct { trace: [trace]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{.{ .label = "trace", .kind = .Field, .detail = "[123]u8" }});

    try testCompletion(
        \\const State = union(enum) { a, b: usize, c: usize };
        \\fn Select() type {
        \\    var trace: usize = 0;
        \\    const selected = state: switch (State{ .a = {} }) {
        \\        .a => |payload, tag| {
        \\            trace = if (payload == {} and tag == .a) 1 else 99;
        \\            continue :state .{ .b = 4 };
        \\        },
        \\        .b => |payload, tag| {
        \\            trace = trace * 10 + if (tag == .b) payload else 99;
        \\            continue :state .{ .c = 7 };
        \\        },
        \\        .c => |payload, tag| break :state if (tag == .c) payload else 99,
        \\    };
        \\    return struct { items: [selected]u8, trace: [trace]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[7]u8" },
        .{ .label = "trace", .kind = .Field, .detail = "[14]u8" },
    });

    try testCompletion(
        \\const State = enum { start, done };
        \\fn Select(comptime initial: State) type {
        \\    return state: switch (initial) {
        \\        .start => continue :state .done,
        \\        .done => struct { resolved: u8 },
        \\    };
        \\}
        \\const selected: Select(.start) = undefined;
        \\const field = selected.<cursor>
    , &.{.{ .label = "resolved", .kind = .Field, .detail = "u8" }});

    try testCompletion(
        \\fn Select() type {
        \\    var evaluations: usize = 0;
        \\    var trace: usize = 0;
        \\    const selected: usize = state: switch (condition: {
        \\        evaluations += 1;
        \\        break :condition @as(usize, 8);
        \\    }) {
        \\        0...2 => |value| break :state value + trace,
        \\        else => |value| {
        \\            defer trace += 1;
        \\            continue :state value / 2;
        \\        },
        \\    };
        \\    return struct {
        \\        items: [selected]u8,
        \\        evaluations: [evaluations]u8,
        \\        trace: [trace]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
        .{ .label = "evaluations", .kind = .Field, .detail = "[1]u8" },
        .{ .label = "trace", .kind = .Field, .detail = "[2]u8" },
    });

    try testCompletion(
        \\const State = enum { start, middle, done };
        \\fn Select() type {
        \\    var transitions: usize = 0;
        \\    const selected: usize = state: switch (@as(State, .start)) {
        \\        .start => {
        \\            transitions += 1;
        \\            continue :state .middle;
        \\        },
        \\        .middle => {
        \\            transitions += 1;
        \\            continue :state .done;
        \\        },
        \\        .done => 5,
        \\    };
        \\    return struct { items: [selected]u8, transitions: [transitions]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[5]u8" },
        .{ .label = "transitions", .kind = .Field, .detail = "[2]u8" },
    });

    try testCompletion(
        \\const State = union(enum) { start, count: usize };
        \\fn Select() type {
        \\    var initial = State{ .start = {} };
        \\    var next = State{ .count = 4 };
        \\    const selected: usize = state: switch (initial) {
        \\        .start => continue :state next,
        \\        .count => |*value| result: {
        \\            value.* += 2;
        \\            break :result value.*;
        \\        },
        \\    };
        \\    return struct { items: [selected]u8, changed: [next.count]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[6]u8" },
        .{ .label = "changed", .kind = .Field, .detail = "[6]u8" },
    });

    try testCompletion(
        \\const State = union(enum) { start, count: usize };
        \\fn Select() type {
        \\    var initial = State{ .start = {} };
        \\    const selected = state: switch (initial) {
        \\        .start => continue :state .{ .count = 4 },
        \\        .count => |*payload| break :state payload.*,
        \\    };
        \\    return struct { items: [selected]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{.{ .label = "items", .kind = .Field, .detail = "[?]u8" }});

    try testCompletion(
        \\const State = union(enum) { count: usize, done };
        \\fn Select() type {
        \\    const selected = state: switch (State{ .count = 4 }) {
        \\        .count => |*payload| result: {
        \\            payload.* += 2;
        \\            break :result payload.*;
        \\        },
        \\        .done => 0,
        \\    };
        \\    return struct { items: [selected]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{.{ .label = "items", .kind = .Field, .detail = "[?]u8" }});

    try testCompletion(
        \\const State = error{ Start, Middle, Done };
        \\fn Select() type {
        \\    var transitions: usize = 0;
        \\    const selected: usize = state: switch (@as(State, error.Start)) {
        \\        error.Start => {
        \\            transitions += 1;
        \\            continue :state error.Middle;
        \\        },
        \\        error.Middle => {
        \\            transitions += 1;
        \\            continue :state error.Done;
        \\        },
        \\        error.Done => 5,
        \\    };
        \\    return struct { items: [selected]u8, transitions: [transitions]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[5]u8" },
        .{ .label = "transitions", .kind = .Field, .detail = "[2]u8" },
    });

    try testCompletion(
        \\const State = packed struct { value: u8, mode: u8 };
        \\fn Select() type {
        \\    var transitions: usize = 0;
        \\    const selected = state: switch (State{ .value = 1, .mode = 7 }) {
        \\        .{ .mode = 7, .value = 3 } => |value| break :state value.value,
        \\        else => |value| {
        \\            transitions += 1;
        \\            continue :state .{ .value = value.value + 1, .mode = value.mode };
        \\        },
        \\    };
        \\    return struct { items: [selected]u8, transitions: [transitions]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[3]u8" },
        .{ .label = "transitions", .kind = .Field, .detail = "[2]u8" },
    });

    try testCompletion(
        \\const State = packed union { unsigned: u8, signed: i8 };
        \\fn Select() type {
        \\    const selected = state: switch (State{ .unsigned = 1 }) {
        \\        .{ .unsigned = 3 } => |value| break :state value.unsigned,
        \\        else => |value| continue :state .{ .unsigned = value.unsigned + 1 },
        \\    };
        \\    return struct { items: [selected]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{.{ .label = "items", .kind = .Field, .detail = "[3]u8" }});
}

test "generic function with comptime switch mutation" {
    try testCompletion(
        \\fn Buffer(comptime mode: u8) type {
        \\    var capacity: usize = 1;
        \\    switch (mode) {
        \\        0 => capacity += 1,
        \\        1...3 => {
        \\            capacity *= 2;
        \\            capacity += 1;
        \\        },
        \\        else => capacity = 8,
        \\    }
        \\    return struct { items: [capacity]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[3]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime mode: u8) type {
        \\    var capacity: usize = 1;
        \\    switch (mode) {
        \\        0 => capacity += 1,
        \\        else => capacity = 8,
        \\    }
        \\    return struct { items: [capacity]u8 };
        \\}
        \\const buffer: Buffer(9) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[8]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime mode: u8) type {
        \\    var capacity: u8 = 1;
        \\    switch (mode) {
        \\        1...3 => |value| capacity += value,
        \\        else => capacity = 8,
        \\    }
        \\    return struct { items: [capacity]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[3]u8" },
    });

    try testCompletion(
        \\const Config = union(enum) { fixed: u8, fallback };
        \\fn Buffer(comptime config: Config) type {
        \\    var capacity: u8 = 1;
        \\    switch (config) {
        \\        .fixed => |value| capacity += value,
        \\        .fallback => capacity = 8,
        \\    }
        \\    return struct { items: [capacity]u8 };
        \\}
        \\const buffer: Buffer(.{ .fixed = 2 }) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[3]u8" },
    });

    try testCompletion(
        \\const Config = union(enum) { fixed: u8, fallback };
        \\fn Buffer(comptime config: Config) type {
        \\    var capacity: u8 = 1;
        \\    switch (config) {
        \\        inline .fixed => |value, tag| {
        \\            if (tag == .fixed) capacity += value else capacity = 9;
        \\        },
        \\        .fallback => capacity = 8,
        \\    }
        \\    return struct { items: [capacity]u8 };
        \\}
        \\const buffer: Buffer(.{ .fixed = 2 }) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[3]u8" },
    });
}

test "generic function with comptime switch pointer capture mutation" {
    try testCompletion(
        \\const Config = union(enum) { fixed: usize, fallback };
        \\fn Buffer(comptime base: usize) type {
        \\    var config = Config{ .fixed = 1 };
        \\    switch (config) {
        \\        .fixed => |*value| value.* += base,
        \\        .fallback => {},
        \\    }
        \\    return struct { items: [config.fixed]u8 };
        \\}
        \\const buffer: Buffer(3) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
    });

    try testCompletion(
        \\const Config = union(enum) { fixed: usize, fallback };
        \\const State = struct { config: Config };
        \\fn Buffer(comptime scale: usize) type {
        \\    var state = State{ .config = Config{ .fixed = 2 } };
        \\    switch (state.config) {
        \\        .fixed => |*value| {
        \\            state.config.fixed += 1;
        \\            value.* *= scale;
        \\        },
        \\        .fallback => {},
        \\    }
        \\    return struct { items: [state.config.fixed]u8 };
        \\}
        \\const buffer: Buffer(3) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[9]u8" },
    });
}

test "generic function with comptime struct field mutation" {
    try testCompletion(
        \\const Config = struct { capacity: usize };
        \\fn Buffer(comptime base: usize) type {
        \\    var config = Config{ .capacity = 1 };
        \\    const config_ptr = &config;
        \\    config_ptr.capacity += base;
        \\    config.capacity *= 2;
        \\    return struct { items: [config.capacity]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[6]u8" },
    });

    try testCompletion(
        \\const Config = struct { capacity: usize };
        \\fn Buffer(comptime base: usize) type {
        \\    var config = Config{ .capacity = 1 };
        \\    const config_ptr = &config;
        \\    config_ptr.*.capacity += base;
        \\    config_ptr.*.capacity *= 2;
        \\    return struct { items: [config.capacity]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[6]u8" },
    });

    try testCompletion(
        \\const Config = struct { capacity: usize = 1, scale: usize = 2 };
        \\fn Buffer(comptime base: usize) type {
        \\    var config = Config{};
        \\    config.capacity += base;
        \\    config.scale *= 3;
        \\    return struct { items: [config.capacity * config.scale]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[18]u8" },
    });
}

test "comptime interpreter coerces nested field defaults" {
    const cases = [_]struct { declaration: []const u8, value: []const u8 }{
        .{ .declaration = "value: usize = @as(u8, 4)", .value = "state.value" },
        .{ .declaration = "value: ?usize = @as(u8, 4)", .value = "state.value.?" },
        .{ .declaration = "value: ?[1]usize = .{@as(u8, 4)}", .value = "state.value.?[0]" },
        .{ .declaration = "value: ?Config = .{}", .value = "state.value.?.capacity" },
        .{ .declaration = "value: [1]Config = .{.{}}", .value = "state.value[0].capacity" },
        .{ .declaration = "value: usize = @intCast(@as(u16, 4))", .value = "state.value" },
    };
    for (cases) |case| {
        for ([_][]const u8{ "State{}", ".{}" }) |initializer| {
            const source = try std.fmt.allocPrint(allocator,
                \\const Config = struct {{ capacity: usize = @as(u8, 4) }};
                \\const State = struct {{ {s}, sibling: usize = 7 }};
                \\fn Select() type {{
                \\    var marker: usize = 0;
                \\    marker += 1;
                \\    const state: State = {s};
                \\    const value = {s};
                \\    return struct {{
                \\        items: [if (@TypeOf(value) == usize) value else 99]u8,
                \\        repeated: [{s}]u8,
                \\        sibling: [state.sibling]u8,
                \\    }};
                \\}}
                \\const selected: Select() = undefined;
                \\const field = selected.<cursor>
            , .{ case.declaration, initializer, case.value, case.value });
            defer allocator.free(source);
            errdefer std.debug.print("field default source:\n{s}\n", .{source});
            try testCompletion(source, &.{
                .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
                .{ .label = "repeated", .kind = .Field, .detail = "[4]u8" },
                .{ .label = "sibling", .kind = .Field, .detail = "[7]u8" },
            });
        }
    }
}

test "comptime interpreter keeps default value copies independent" {
    try testCompletion(
        \\const Config = struct { capacity: usize = @as(u8, 4) };
        \\const State = struct { optional: ?Config = .{}, values: [1]Config = .{.{}} };
        \\fn Select() type {
        \\    var state = State{};
        \\    const original = state;
        \\    const other = State{};
        \\    state.optional.?.capacity += 2;
        \\    state.values[0].capacity += 3;
        \\    return struct {
        \\        original: [original.optional.?.capacity + original.values[0].capacity]u8,
        \\        other: [other.optional.?.capacity + other.values[0].capacity]u8,
        \\        changed: [state.optional.?.capacity + state.values[0].capacity]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "original", .kind = .Field, .detail = "[8]u8" },
        .{ .label = "other", .kind = .Field, .detail = "[8]u8" },
        .{ .label = "changed", .kind = .Field, .detail = "[13]u8" },
    });
}

test "comptime interpreter resolves specialized field defaults" {
    try testCompletion(
        \\fn Config(comptime base: u8) type {
        \\    return struct {
        \\        count: ?usize = base,
        \\        values: ?[1]usize = .{base},
        \\        nested: struct { capacity: usize = base } = .{},
        \\    };
        \\}
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const first = Config(4){};
        \\    const second = Config(7){};
        \\    return struct {
        \\        first: [first.count.? + first.values.?[0] + first.nested.capacity]u8,
        \\        second: [second.count.? + second.values.?[0] + second.nested.capacity]u8,
        \\        repeated: [first.count.? + first.values.?[0] + first.nested.capacity]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "first", .kind = .Field, .detail = "[12]u8" },
        .{ .label = "second", .kind = .Field, .detail = "[21]u8" },
        .{ .label = "repeated", .kind = .Field, .detail = "[12]u8" },
    });
}

test "comptime interpreter isolates field default locals" {
    try testCompletion(
        \\const Config = struct {
        \\    capacity: usize = value: {
        \\        var small: u8 = 1;
        \\        small += 3;
        \\        break :value small;
        \\    },
        \\    unused: usize = 99,
        \\};
        \\fn Select() type {
        \\    var state = Config{ .unused = 7 };
        \\    const original = state;
        \\    const other = Config{ .unused = 8 };
        \\    state.capacity += 2;
        \\    return struct {
        \\        original: [original.capacity]u8,
        \\        other: [other.capacity]u8,
        \\        changed: [state.capacity]u8,
        \\        overridden: [state.unused + other.unused]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "original", .kind = .Field, .detail = "[4]u8" },
        .{ .label = "other", .kind = .Field, .detail = "[4]u8" },
        .{ .label = "changed", .kind = .Field, .detail = "[6]u8" },
        .{ .label = "overridden", .kind = .Field, .detail = "[15]u8" },
    });
}

test "cross-file comptime field defaults preserve generic bindings" {
    var ctx: Context = try .init();
    defer ctx.deinit();
    _ = try ctx.addDocument(.{ .source =
        \\pub fn Config(comptime base: u8) type {
        \\    const Inner = struct { capacity: usize = base };
        \\    return struct { optional: ?Inner = .{} };
        \\}
    });
    const source =
        \\const api = @import("Untitled-0.zig");
        \\fn Select() type {
        \\    var state = api.Config(4){};
        \\    const original = state;
        \\    const other = api.Config(7){};
        \\    state.optional.?.capacity += 2;
        \\    return struct { items: [original.optional.?.capacity + other.optional.?.capacity + state.optional.?.capacity]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    ;
    const cursor_idx = std.mem.find(u8, source, "<cursor>").?;
    const uri = try ctx.addDocument(.{ .source = source[0..cursor_idx] });
    const response = (try ctx.server.sendRequestSync(ctx.arena.allocator(), "textDocument/completion", types.completion.Params{
        .textDocument = .{ .uri = uri.raw },
        .position = offsets.indexToPosition(source, cursor_idx, ctx.server.offset_encoding),
    })).?.completion_list;
    try std.testing.expectEqual(@as(usize, 1), response.items.len);
    try std.testing.expectEqualStrings("items", response.items[0].label);
    try std.testing.expectEqualStrings("[17]u8", response.items[0].detail.?);
}

test "comptime interpreter keeps invalid field defaults unknown" {
    for ([_][]const u8{ "\"invalid\"", "Config{}.capacity" }) |value| {
        const source = try std.fmt.allocPrint(allocator,
            \\const Config = struct {{ capacity: usize = {s}, sibling: usize = 7 }};
            \\fn Select() type {{
            \\    var marker: usize = 0;
            \\    marker += 1;
            \\    const state = Config{{}};
            \\    return struct {{ items: [state.capacity]u8, sibling: [state.sibling]u8 }};
            \\}}
            \\const selected: Select() = undefined;
            \\const field = selected.<cursor>
        , .{value});
        defer allocator.free(source);
        try testCompletion(source, &.{
            .{ .label = "items", .kind = .Field, .detail = "[?]u8" },
            .{ .label = "sibling", .kind = .Field, .detail = "[7]u8" },
        });
    }
}

test "generic function with nested comptime aggregate mutation" {
    try testCompletion(
        \\const Inner = struct { capacity: usize = 1 };
        \\const State = struct { inner: Inner = .{}, dimensions: [2]usize = .{ 1, 2 } };
        \\fn Buffer(comptime base: usize) type {
        \\    var state = State{ .inner = Inner{}, .dimensions = [2]usize{ 1, 2 } };
        \\    state.inner.capacity += base;
        \\    state.dimensions[0] += base;
        \\    state.dimensions[1] *= 3;
        \\    return struct { items: [state.inner.capacity * state.dimensions[0] * state.dimensions[1]]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[54]u8" },
    });

    try testCompletion(
        \\const Inner = struct { capacity: usize = 1 };
        \\const State = struct { inner: Inner = .{}, dimensions: [2]usize = .{ 1, 2 } };
        \\fn Buffer(comptime base: usize) type {
        \\    var state = State{};
        \\    state.inner.capacity += base;
        \\    state.dimensions[0] += base;
        \\    state.dimensions[1] *= 3;
        \\    return struct { items: [state.inner.capacity * state.dimensions[0] * state.dimensions[1]]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[54]u8" },
    });
}

test "generic function with comptime pointer deref mutation" {
    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    var capacity: usize = 0;
        \\    var capacity_ptr = &capacity;
        \\    capacity_ptr.* = 1;
        \\    capacity_ptr.* += base;
        \\    capacity_ptr.* *= 2;
        \\    return struct { items: [capacity]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[6]u8" },
    });

    try testCompletion(
        \\const State = struct { capacity: usize, dimensions: [2]usize };
        \\fn Buffer(comptime base: usize) type {
        \\    var state = State{ .capacity = 1, .dimensions = .{ 1, 2 } };
        \\    var dimension_index: usize = 1;
        \\    const capacity_ptr = &state.capacity;
        \\    const height_ptr = &state.dimensions[dimension_index];
        \\    dimension_index = 0;
        \\    state.capacity += base;
        \\    state.dimensions[1] += base;
        \\    capacity_ptr.* *= 2;
        \\    height_ptr.* *= 3;
        \\    return struct { items: [state.capacity * state.dimensions[1]]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[72]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    var dimensions = .{ @as(usize, 1), @as(usize, 2) };
        \\    const width_ptr = &dimensions.@"0";
        \\    dimensions.@"0" += base;
        \\    width_ptr.* *= 2;
        \\    return struct { items: [dimensions.@"0" * dimensions.@"1"]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[12]u8" },
    });
}

test "generic function with nested comptime pointer deref mutation" {
    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    var total: usize = base;
        \\    var capacity: usize = 3;
        \\    const selected = (pointer: {
        \\        defer total += 1;
        \\        total *= 2;
        \\        break :pointer &capacity;
        \\    }).*;
        \\    return struct { items: [selected * total]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[15]u8" },
    });
}

test "generic function with comptime for pointer capture mutation" {
    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    var dimensions = [_]usize{ 1, 2, 3 };
        \\    for (&dimensions, 0..) |*dimension, index| {
        \\        dimension.* += base + index;
        \\    }
        \\    return struct { items: [dimensions[0] * dimensions[1] * dimensions[2]]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[105]u8" },
    });

    try testCompletion(
        \\const State = struct { dimensions: [2]usize };
        \\fn Buffer(comptime scale: usize) type {
        \\    var state = State{ .dimensions = .{ 2, 3 } };
        \\    for (&state.dimensions) |*dimension| {
        \\        dimension.* *= scale;
        \\    }
        \\    return struct { items: [state.dimensions[0] * state.dimensions[1]]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[24]u8" },
    });
}

test "generic function with runtime if before return" {
    try testCompletion(
        \\var runtime: bool = undefined;
        \\fn Select(comptime N: u8) type {
        \\    if (runtime) {
        \\        _ = N;
        \\    } else {
        \\        _ = N + 1;
        \\    }
        \\    return struct { selected: [N]u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with identical runtime if return types" {
    try testCompletion(
        \\var runtime: bool = undefined;
        \\fn Select(comptime N: u8) type {
        \\    const Result = struct { matched: [N]u8 };
        \\    if (runtime) return Result else return Result;
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with wrapped comptime return statements" {
    try testCompletion(
        \\fn Select(comptime enabled: bool) type {
        \\    comptime {
        \\        if (enabled) return struct { selected: u8 };
        \\    }
        \\    return struct { fallback: u8 };
        \\}
        \\const selected: Select(true) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select() type {
        \\    nosuspend {
        \\        return struct { selected: u8 };
        \\    }
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with comptime nosuspend statements" {
    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    var capacity: usize = base;
        \\    nosuspend {
        \\        defer capacity += 2;
        \\        capacity *= 3;
        \\    }
        \\    return struct { items: [capacity]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[8]u8" },
    });

    try testCompletion(
        \\fn Select(comptime base: usize) type {
        \\    var capacity: usize = base;
        \\    nosuspend {
        \\        capacity += 1;
        \\        return if (capacity == 3)
        \\            struct { selected: u8 }
        \\        else
        \\            struct { fallback: u8 };
        \\    }
        \\}
        \\const selected: Select(2) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with comptime expression wrappers" {
    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    var total: usize = base;
        \\    const selected = comptime value: {
        \\        defer total += 2;
        \\        total *= 3;
        \\        break :value total;
        \\    };
        \\    return struct { items: [selected * total]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[48]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    var total: usize = base;
        \\    const selected = nosuspend value: {
        \\        defer total += 1;
        \\        total *= 2;
        \\        break :value total;
        \\    };
        \\    return struct { items: [selected * total]u8 };
        \\}
        \\const buffer: Buffer(3) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[42]u8" },
    });
}

test "generic function with nested comptime arithmetic mutations" {
    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    var total: usize = base;
        \\    const selected = (value: {
        \\        defer total += 2;
        \\        total *= 3;
        \\        break :value total;
        \\    }) + 4;
        \\    return struct { items: [selected * total]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[80]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    var total: usize = base;
        \\    const selected = ((value: {
        \\        total += 1;
        \\        break :value total;
        \\    }) << 2) | 1;
        \\    return struct { items: [selected * total]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[39]u8" },
    });
}

test "generic function with nested comptime comparison mutations" {
    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    var total: usize = base;
        \\    const selected = (value: {
        \\        defer total += 1;
        \\        total *= 3;
        \\        break :value total;
        \\    }) == 6;
        \\    return struct { items: [if (selected) total else 99]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[7]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    var total: usize = base;
        \\    const selected = 4 < (value: {
        \\        total += 3;
        \\        break :value total;
        \\    });
        \\    return struct { items: [if (selected) total else 99]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[5]u8" },
    });
}

test "generic function with nested comptime unary mutations" {
    try testCompletion(
        \\fn Select(comptime base: i8) type {
        \\    var total: i8 = base;
        \\    const negated = -(value: {
        \\        total += 1;
        \\        break :value total;
        \\    });
        \\    const inverted = ~(value: {
        \\        total += 1;
        \\        break :value total;
        \\    });
        \\    const toggled = !(value: {
        \\        total += 1;
        \\        break :value false;
        \\    });
        \\    return if (negated == -3 and inverted == -5 and toggled and total == 5)
        \\        struct { selected: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(2) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with comptime labeled block breaks" {
    try testCompletion(
        \\fn Buffer(comptime enabled: bool) type {
        \\    var capacity: usize = 1;
        \\    outer: {
        \\        while (true) {
        \\            capacity += 2;
        \\            if (enabled) break :outer;
        \\            break;
        \\        }
        \\        capacity = 9;
        \\    }
        \\    return struct { items: [capacity]u8 };
        \\}
        \\const buffer: Buffer(true) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[3]u8" },
    });

    try testCompletion(
        \\fn Select(comptime enabled: bool) type {
        \\    const T = blk: {
        \\        if (!enabled) break :blk struct { fallback: u8 };
        \\        break :blk struct { selected: u8 };
        \\    };
        \\    return T;
        \\}
        \\const selected: Select(true) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    var capacity: usize = base;
        \\    const selected = blk: {
        \\        defer capacity += 100;
        \\        capacity += 1;
        \\        break :blk capacity * 2;
        \\    };
        \\    return struct { items: [selected + capacity]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[109]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    var capacity: usize = 1;
        \\    const selected = outer: {
        \\        defer capacity *= 2;
        \\        inner: {
        \\            defer capacity += 1;
        \\            capacity += base;
        \\            break :outer capacity;
        \\        }
        \\    };
        \\    return struct { items: [selected * capacity]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[24]u8" },
    });

    try testCompletion(
        \\fn Select(comptime enabled: bool) type {
        \\    const value = blk: {
        \\        if (enabled) break :blk;
        \\        break :blk;
        \\    };
        \\    return if (@TypeOf(value) == void)
        \\        struct { selected: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(true) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\var runtime: bool = undefined;
        \\fn Select(comptime N: u8) type {
        \\    const value = blk: {
        \\        if (runtime) break :blk @as(i32, N);
        \\        break :blk @as(i64, N);
        \\    };
        \\    return if (@TypeOf(value) == i64)
        \\        struct { selected: [N]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "[4]u8" },
    });

    try testCompletion(
        \\fn Select(comptime N: u8) type {
        \\    return blk: {
        \\        switch (N) {
        \\            0 => break :blk struct { zero: u8 },
        \\            1...3 => break :blk struct { range: u8 },
        \\            else => break :blk struct { fallback: u8 },
        \\        }
        \\    };
        \\}
        \\const selected: Select(2) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "range", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\var runtime: bool = undefined;
        \\fn Select(comptime N: u8) type {
        \\    const count = blk: {
        \\        if (runtime) break :blk N;
        \\        break :blk N;
        \\    };
        \\    return struct { items: [count]u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with comptime defer mutations" {
    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    var capacity: usize = base;
        \\    {
        \\        defer capacity += 2;
        \\        defer capacity *= 3;
        \\        capacity += 4;
        \\    }
        \\    return struct { items: [capacity]u8 };
        \\}
        \\const buffer: Buffer(1) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[17]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    var capacity: usize = base;
        \\    outer: {
        \\        defer capacity *= 3;
        \\        {
        \\            defer capacity += 2;
        \\            break :outer;
        \\        }
        \\        capacity = 100;
        \\    }
        \\    return struct { items: [capacity]u8 };
        \\}
        \\const buffer: Buffer(1) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[9]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime limit: usize) type {
        \\    var capacity: usize = 1;
        \\    var index: usize = 0;
        \\    while (index < limit) : (index += 1) {
        \\        defer capacity += 1;
        \\        capacity *= 2;
        \\        continue;
        \\    }
        \\    return struct { items: [capacity]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[7]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    var value: usize = base;
        \\    defer value *= 10;
        \\    return if (value == 2)
        \\        struct { selected: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "selected", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with comptime labeled loop breaks" {
    try testCompletion(
        \\fn Buffer(comptime limit: usize) type {
        \\    var outer_index: usize = 0;
        \\    var capacity: usize = 1;
        \\    outer: while (outer_index < limit) : (outer_index += 1) {
        \\        var inner_index: usize = 0;
        \\        while (inner_index < 2) : (inner_index += 1) {
        \\            capacity += 1;
        \\            if (capacity == 3) break :outer;
        \\        }
        \\        capacity = 9;
        \\    } else {
        \\        capacity = 100;
        \\    }
        \\    return struct { items: [capacity]u8 };
        \\}
        \\const buffer: Buffer(4) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[3]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime limit: usize) type {
        \\    var capacity: usize = 1;
        \\    outer: for (0..limit) |_| {
        \\        for (0..2) |_| {
        \\            capacity += 1;
        \\            if (capacity == 3) break :outer;
        \\        }
        \\        capacity = 9;
        \\    } else {
        \\        capacity = 100;
        \\    }
        \\    return struct { items: [capacity]u8 };
        \\}
        \\const buffer: Buffer(4) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[3]u8" },
    });
}

test "generic function with comptime loop expression values" {
    try testCompletion(
        \\fn Buffer(comptime limit: usize) type {
        \\    var total: usize = 0;
        \\    const selected = outer: for (0..limit) |index| {
        \\        defer total += 1;
        \\        total += index;
        \\        if (index == 1) break :outer total * 2;
        \\    } else 99;
        \\    return struct { items: [selected * total]u8 };
        \\}
        \\const buffer: Buffer(3) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[12]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime limit: usize) type {
        \\    var total: usize = 0;
        \\    const selected = for (0..limit) |index| {
        \\        total += index;
        \\    } else total + 1;
        \\    return struct { items: [selected]u8 };
        \\}
        \\const buffer: Buffer(3) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime limit: usize) type {
        \\    var index: usize = 0;
        \\    var total: usize = 1;
        \\    const selected = outer: while (index < limit) : (index += 1) {
        \\        defer total += 1;
        \\        total *= 2;
        \\        if (index == 1) break :outer total;
        \\    } else 99;
        \\    return struct { items: [selected * total]u8 };
        \\}
        \\const buffer: Buffer(3) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[42]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    var capacity: ?usize = 1;
        \\    const selected = if (capacity) |*payload| value: {
        \\        payload.* += base;
        \\        break :value payload.*;
        \\    } else 99;
        \\    return struct { items: [selected * capacity.?]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[9]u8" },
    });

    try testCompletion(
        \\const Config = union(enum) { fixed: usize, fallback };
        \\fn Buffer(comptime base: usize) type {
        \\    var config = Config{ .fixed = 2 };
        \\    const selected = switch (config) {
        \\        .fixed => |*payload| value: {
        \\            payload.* += base;
        \\            break :value payload.*;
        \\        },
        \\        .fallback => 99,
        \\    };
        \\    return struct { items: [selected * config.fixed]u8 };
        \\}
        \\const buffer: Buffer(3) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[25]u8" },
    });
}

test "generic function with comptime branch expression mutations" {
    try testCompletion(
        \\fn Buffer(comptime enabled: bool) type {
        \\    var total: usize = 1;
        \\    const selected = if (enabled) value: {
        \\        defer total += 1;
        \\        total *= 3;
        \\        break :value total;
        \\    } else 99;
        \\    return struct { items: [selected * total]u8 };
        \\}
        \\const buffer: Buffer(true) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[12]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime mode: u8) type {
        \\    var total: usize = 2;
        \\    const selected = switch (mode) {
        \\        1 => value: {
        \\            defer total += 1;
        \\            total *= 3;
        \\            break :value total;
        \\        },
        \\        else => 99,
        \\    };
        \\    return struct { items: [selected * total]u8 };
        \\}
        \\const buffer: Buffer(1) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[42]u8" },
    });
}

test "generic function with comptime labeled continues" {
    try testCompletion(
        \\fn Buffer(comptime limit: usize) type {
        \\    var outer_index: usize = 0;
        \\    var capacity: usize = 0;
        \\    outer: while (outer_index < limit) : (outer_index += 1) {
        \\        var inner_index: usize = 0;
        \\        while (inner_index < 2) : (inner_index += 1) {
        \\            capacity += 1;
        \\            continue :outer;
        \\        }
        \\        capacity = 99;
        \\    } else {
        \\        capacity += 10;
        \\    }
        \\    return struct { items: [capacity]u8 };
        \\}
        \\const buffer: Buffer(3) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[13]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime limit: usize) type {
        \\    var capacity: usize = 0;
        \\    outer: for (0..limit) |_| {
        \\        for (0..2) |_| {
        \\            capacity += 1;
        \\            continue :outer;
        \\        }
        \\        capacity = 99;
        \\    } else {
        \\        capacity += 10;
        \\    }
        \\    return struct { items: [capacity]u8 };
        \\}
        \\const buffer: Buffer(3) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[13]u8" },
    });
}

test "generic function with comptime intFromEnum" {
    try testCompletion(
        \\const Mode = enum(u128) { low = 1, high = 170141183460469231731687303715884105728 };
        \\fn Select(comptime raw: u128) type {
        \\    const mode: Mode = @enumFromInt(raw);
        \\    return if (mode == .high and @intFromEnum(mode) == raw)
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(170141183460469231731687303715884105728) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\const Mode = enum(u8) { fast = 3, safe = 7 };
        \\fn Select(comptime mode: Mode) type {
        \\    return if (mode == .safe)
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(@enumFromInt(7)) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\const Mode = enum(u8) { fast = 3, safe = 7 };
        \\fn Select(comptime raw: u8) type {
        \\    const mode: Mode = @enumFromInt(raw);
        \\    return if (mode == .safe and @tagName(mode)[0] == 's')
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(7) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });
    try testCompletion(
        \\const Mode = enum(i8) { negative = -4, zero = 0, positive };
        \\fn Select(comptime raw: i8) type {
        \\    const mode: Mode = @enumFromInt(raw);
        \\    return switch (mode) {
        \\        .negative => struct { matched: u8 },
        \\        else => struct { fallback: u8 },
        \\    };
        \\}
        \\const selected: Select(-4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });
    try testCompletion(
        \\const Mode = enum { zero, one, two };
        \\fn Select(comptime raw: u8) type {
        \\    const mode: Mode = @enumFromInt(raw);
        \\    return if (mode == .two)
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(2) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });
    try testCompletion(
        \\const Mode = enum(u8) { first, second, _ };
        \\fn Select(comptime raw: u8) type {
        \\    const mode: Mode = @enumFromInt(raw);
        \\    return switch (mode) {
        \\        .first => struct { first: u8 },
        \\        .second => struct { second: u8 },
        \\        _ => struct { other: u8 },
        \\    };
        \\}
        \\const selected: Select(42) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "first", .kind = .Field, .detail = "u8" },
        .{ .label = "second", .kind = .Field, .detail = "u8" },
        .{ .label = "other", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\const Mode = enum { zero, one, two };
        \\fn Buffer(comptime mode: Mode) type {
        \\    return struct { items: [@intFromEnum(mode)]u8 };
        \\}
        \\const buffer: Buffer(.two) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[2]u8" },
    });

    try testCompletion(
        \\const Mode = enum(u8) { first = 4, second, third = 9 };
        \\fn Buffer(comptime mode: Mode) type {
        \\    return struct { items: [@intFromEnum(mode)]u8 };
        \\}
        \\const mode = Mode.second;
        \\const buffer: Buffer(mode) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[5]u8" },
    });

    try testCompletion(
        \\const Mode = enum(i8) { negative = -4, zero = 0 };
        \\fn Select(comptime mode: Mode) type {
        \\    return if (@intFromEnum(mode) == -4)
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(.negative) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\const Only = enum { value };
        \\fn Select(comptime value: Only) type {
        \\    return if (@TypeOf(@intFromEnum(value)) == u0 and @intFromEnum(value) == 0)
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(.value) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with nested contextual enumFromInt mutations" {
    try testCompletion(
        \\const Mode = enum(u8) { fast = 3, safe = 7 };
        \\fn Select(comptime raw: u8) type {
        \\    var total: usize = 1;
        \\    const mode = @as(Mode, @enumFromInt(value: {
        \\        total *= 2;
        \\        break :value raw;
        \\    }));
        \\    return if (mode == .safe and @intFromEnum(mode) == raw)
        \\        struct { order: [total]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(7) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "order", .kind = .Field, .detail = "[2]u8" },
    });

    try testCompletion(
        \\fn Select(comptime raw: u8) type {
        \\    const Mode = @Enum(u8, .exhaustive, &.{ "fast", "safe" }, &.{ 3, 7 });
        \\    var total: usize = 1;
        \\    const mode = @as(Mode, @enumFromInt(value: {
        \\        total += 2;
        \\        break :value raw;
        \\    }));
        \\    return if (mode == Mode.safe and @intFromEnum(mode) == raw)
        \\        struct { generated_order: [total]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(7) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "generated_order", .kind = .Field, .detail = "[3]u8" },
    });
}

test "generic function preserves runtime unknown contextual enumFromInt type" {
    try testCompletion(
        \\const Mode = enum(u8) { fast = 3, safe = 7 };
        \\var runtime_u8: u8 = undefined;
        \\fn Select() type {
        \\    var total: usize = 1;
        \\    const mode = @as(Mode, @enumFromInt(value: {
        \\        total += 1;
        \\        break :value runtime_u8;
        \\    }));
        \\    return struct {
        \\        value: @TypeOf(mode),
        \\        items: [total]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[2]u8" },
        .{ .label = "value", .kind = .EnumMember, .detail = "Mode" },
    });
}

test "generic function with nested comptime intFromEnum mutation" {
    try testCompletion(
        \\const Mode = enum(u8) { fast = 3, safe = 7 };
        \\fn Buffer(comptime mode: Mode) type {
        \\    var total: usize = 1;
        \\    const raw = @intFromEnum(value: {
        \\        defer total += 1;
        \\        total *= 2;
        \\        break :value mode;
        \\    });
        \\    return struct { items: [raw * total]u8 };
        \\}
        \\const buffer: Buffer(.safe) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[21]u8" },
    });
}

test "generic function with comptime enum tagName length" {
    try testCompletion(
        \\const Mode = enum { @"safe\x20mode" };
        \\const Fields = struct { @"safe mode": u8 };
        \\fn Select(comptime mode: Mode) type {
        \\    const name = @tagName(mode);
        \\    return if (name.len == 9 and name[4] == ' ' and @hasField(Fields, name))
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(.@"safe\x20mode") = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\const Mode = enum { fast, safety };
        \\const Fields = struct { fast: u8, safety: u8 };
        \\fn Select(comptime mode: Mode) type {
        \\    const name = @tagName(mode);
        \\    return if (name[0] == 's' and @hasField(Fields, name))
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(.safety) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\const Mode = enum { fast, safety };
        \\fn Buffer(comptime mode: Mode) type {
        \\    return struct { name: [@tagName(mode).len]u8 };
        \\}
        \\const buffer: Buffer(.safety) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "name", .kind = .Field, .detail = "[6]u8" },
    });

    try testCompletion(
        \\const Mode = enum { @"快速", slow };
        \\fn Buffer(comptime mode: Mode) type {
        \\    return struct { name: [@tagName(mode).len]u8 };
        \\}
        \\const buffer: Buffer(.@"快速") = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "name", .kind = .Field, .detail = "[6]u8" },
    });

    try testCompletion(
        \\const Mode = enum { fast, safety };
        \\fn Buffer(comptime mode: Mode) type {
        \\    return struct { name: [@tagName(mode).len]u8 };
        \\}
        \\const buffer: Buffer(undefined) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "name", .kind = .Field, .detail = "[?]u8" },
    });
}

test "generic function with nested comptime tagName mutation" {
    try testCompletion(
        \\const Mode = enum { fast, safe };
        \\fn Buffer(comptime mode: Mode) type {
        \\    var total: usize = 1;
        \\    const name = @tagName(value: {
        \\        defer total += 1;
        \\        total *= 2;
        \\        break :value mode;
        \\    });
        \\    return struct { items: [name.len * total]u8 };
        \\}
        \\const buffer: Buffer(.safe) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[12]u8" },
    });
}

test "generic function preserves runtime unknown comptime name types" {
    try testCompletion(
        \\const Mode = enum { fast, safe };
        \\const Value = union(enum) { integer: u8, none };
        \\var runtime_mode: Mode = undefined;
        \\var runtime_value: Value = undefined;
        \\var runtime_error: anyerror = undefined;
        \\fn Select() type {
        \\    var total: usize = 1;
        \\    const tag_name = @tagName(value: {
        \\        total += 1;
        \\        break :value runtime_mode;
        \\    });
        \\    const union_name = @tagName(value: {
        \\        total += 1;
        \\        break :value runtime_value;
        \\    });
        \\    const error_name = @errorName(value: {
        \\        total += 1;
        \\        break :value runtime_error;
        \\    });
        \\    return struct {
        \\        tag_name: @TypeOf(tag_name),
        \\        union_name: @TypeOf(union_name),
        \\        error_name: @TypeOf(error_name),
        \\        items: [total]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "error_name", .kind = .Field, .detail = "[:0]const u8" },
        .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
        .{ .label = "tag_name", .kind = .Field, .detail = "[:0]const u8" },
        .{ .label = "union_name", .kind = .Field, .detail = "[:0]const u8" },
    });
}

test "generic function with comptime errorName" {
    try testCompletion(
        \\const Fields = struct { Missing: u8 };
        \\fn Select(comptime err: anyerror) type {
        \\    const name = @errorName(err);
        \\    return if (@TypeOf(name) == [:0]const u8 and name.len == 7 and
        \\        name[0] == 'M' and @hasField(Fields, name))
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(error.Missing) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with nested comptime errorName mutation" {
    try testCompletion(
        \\fn Buffer(comptime err: anyerror) type {
        \\    var total: usize = 1;
        \\    const name = @errorName(value: {
        \\        defer total += 1;
        \\        total *= 2;
        \\        break :value err;
        \\    });
        \\    return struct { items: [name.len * total]u8 };
        \\}
        \\const buffer: Buffer(error.Missing) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[21]u8" },
    });
}

test "generic function with comptime catch" {
    try testCompletion(
        \\var runtime_error_union: error{Failure}!u8 = undefined;
        \\fn Select(comptime err: anyerror) type {
        \\    const fallback = err catch 9;
        \\    const widened = runtime_error_union catch @as(u16, 11);
        \\    return if (fallback == 9 and @TypeOf(widened) == u16)
        \\        struct { caught: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(error.Failure) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "caught", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with nested comptime typeName mutation" {
    try testCompletion(
        \\fn Buffer(comptime T: type) type {
        \\    var total: usize = 1;
        \\    const name = @typeName(value: {
        \\        defer total += 1;
        \\        total *= 2;
        \\        break :value T;
        \\    });
        \\    return struct { items: [name.len * total]u8 };
        \\}
        \\const buffer: Buffer(u16) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[9]u8" },
    });
}

test "generic function with comptime typeName" {
    try testCompletion(
        \\const Fields = struct { @"[]const u8": u8 };
        \\fn Select(comptime T: type) type {
        \\    const name = @typeName(T);
        \\    return if (@TypeOf(name) == *const [10:0]u8 and name[0] == '[' and
        \\        @hasField(Fields, name))
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select([]const u8) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\const Fields = struct { u16: u8 };
        \\fn Select(comptime T: type) type {
        \\    const name = @typeName(?T);
        \\    return if (@TypeOf(name) == *const [4:0]u8 and name[0] == '?' and
        \\        @hasField(Fields, name[1..]))
        \\        struct { matched: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime T: type) type {
        \\    const Pair = @Tuple(&.{ T, bool });
        \\    const name = @typeName(Pair);
        \\    return if (name.len == 20 and name[0] == 's' and name[9] == 'u' and name[14] == 'b')
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });

    try testCompletion(
        \\const Names = struct {
        \\    @"fn (u16, bool) u8": void,
        \\    @"fn (noalias *u8, ...) callconv(.c) void": void,
        \\};
        \\fn Select(comptime T: type) type {
        \\    const Plain = @Fn(&.{ T, bool }, &.{ .{}, .{} }, u8, .{});
        \\    const C = @Fn(&.{*u8}, &.{.{ .@"noalias" = true }}, void,
        \\        .{ .@"callconv" = .c, .varargs = true });
        \\    const plain_name = @typeName(Plain);
        \\    const c_name = @typeName(C);
        \\    return if (plain_name.len == 17 and @hasField(Names, plain_name) and
        \\        c_name.len == 39 and @hasField(Names, c_name))
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });

    try testCompletion(
        \\const Names = struct {
        \\    @"error{Apple,Zebra}": void,
        \\    @"error{Apple,Zebra}!u16": void,
        \\};
        \\fn Select(comptime T: type) type {
        \\    const E = error{ Zebra, Apple };
        \\    const error_name = @typeName(E);
        \\    const union_name = @typeName(E!T);
        \\    return if (error_name.len == 18 and @hasField(Names, error_name) and
        \\        union_name.len == 22 and @hasField(Names, union_name))
        \\        struct { matched: T }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(u16) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "u16" },
    });
}

test "enum declarations are not comptime enum values" {
    try testCompletion(
        \\const Mode = enum {
        \\    fast,
        \\    safe,
        \\    const Settings = struct { enabled: bool };
        \\};
        \\const settings: Mode.Settings = undefined;
        \\const field = settings.<cursor>
    , &.{
        .{ .label = "enabled", .kind = .Field, .detail = "bool" },
    });
}

test "cross-file generic function with comptime enum switch" {
    var ctx: Context = try .init();
    defer ctx.deinit();

    _ = try ctx.addDocument(.{ .source =
        \\pub const Mode = enum { fast, safe };
        \\pub fn Select(comptime mode: Mode) type {
        \\    return switch (mode) {
        \\        .fast => struct { optimized: u8 },
        \\        .safe => struct { checked: u8 },
        \\    };
        \\}
    });

    const source =
        \\const api = @import("Untitled-0.zig");
        \\const selected: api.Select(api.Mode.safe) = undefined;
        \\const field = selected.<cursor>
    ;
    const cursor_idx = std.mem.find(u8, source, "<cursor>").?;
    const text = try std.mem.concat(allocator, u8, &.{ source[0..cursor_idx], source[cursor_idx + "<cursor>".len ..] });
    defer allocator.free(text);
    const uri = try ctx.addDocument(.{ .source = text });

    const response = (try ctx.server.sendRequestSync(ctx.arena.allocator(), "textDocument/completion", types.completion.Params{
        .textDocument = .{ .uri = uri.raw },
        .position = offsets.indexToPosition(source, cursor_idx, ctx.server.offset_encoding),
    })).?.completion_list;

    var found_checked = false;
    for (response.items) |item| {
        if (std.mem.eql(u8, item.label, "optimized")) return error.MissingOrUnexpectedCompletions;
        if (std.mem.eql(u8, item.label, "checked")) {
            found_checked = true;
            try std.testing.expectEqual(types.completion.Item.Kind.Field, item.kind.?);
            try std.testing.expectEqualStrings("u8", item.detail.?);
        }
    }
    try std.testing.expect(found_checked);
}

test "cross-file generic function with comptime member reflection" {
    var ctx: Context = try .init();
    defer ctx.deinit();

    _ = try ctx.addDocument(.{ .source =
        \\pub const Feature = true;
        \\pub fn Select(comptime T: type) type {
        \\    return if (@hasDecl(T, "Feature"))
        \\        struct { enabled: u8 }
        \\    else
        \\        struct { disabled: u8 };
        \\}
    });

    const source =
        \\const api = @import("Untitled-0.zig");
        \\const selected: api.Select(api) = undefined;
        \\const field = selected.<cursor>
    ;
    const cursor_idx = std.mem.find(u8, source, "<cursor>").?;
    const text = try std.mem.concat(allocator, u8, &.{ source[0..cursor_idx], source[cursor_idx + "<cursor>".len ..] });
    defer allocator.free(text);
    const uri = try ctx.addDocument(.{ .source = text });

    const response = (try ctx.server.sendRequestSync(ctx.arena.allocator(), "textDocument/completion", types.completion.Params{
        .textDocument = .{ .uri = uri.raw },
        .position = offsets.indexToPosition(source, cursor_idx, ctx.server.offset_encoding),
    })).?.completion_list;

    var found_enabled = false;
    for (response.items) |item| {
        if (std.mem.eql(u8, item.label, "disabled")) return error.MissingOrUnexpectedCompletions;
        if (std.mem.eql(u8, item.label, "enabled")) {
            found_enabled = true;
            try std.testing.expectEqual(types.completion.Item.Kind.Field, item.kind.?);
            try std.testing.expectEqualStrings("u8", item.detail.?);
        }
    }
    try std.testing.expect(found_enabled);
}

test "comptime interpreter evaluates labeled error switch fallbacks" {
    for ([_]struct { initial: []const u8, items: []const u8, transitions: []const u8 }{
        .{ .initial = "4", .items = "[8]u8", .transitions = "[0]u8" },
        .{ .initial = "error.Start", .items = "[10]u8", .transitions = "[1]u8" },
    }) |case| {
        const source = try std.fmt.allocPrint(allocator,
            \\const State = error{{ Start, Done }};
            \\fn Select(comptime initial: State!usize) type {{
            \\    var transitions: usize = 0;
            \\    const selected = initial catch |err| state: switch (err) {{
            \\        error.Start => {{
            \\            transitions += 1;
            \\            continue :state error.Done;
            \\        }},
            \\        error.Done => break :state 5,
            \\    }};
            \\    return struct {{ items: [selected * 2]u8, transitions: [transitions]u8 }};
            \\}}
            \\const selected: Select({s}) = undefined;
            \\const field = selected.<cursor>
        , .{case.initial});
        defer allocator.free(source);
        try testCompletion(source, &.{
            .{ .label = "items", .kind = .Field, .detail = case.items },
            .{ .label = "transitions", .kind = .Field, .detail = case.transitions },
        });
    }
}

test "comptime interpreter executes known error catch fallbacks" {
    for ([_]struct { initial: []const u8, runs: []const u8 }{
        .{ .initial = "error.Failure", .runs = "[1]u8" },
        .{ .initial = "4", .runs = "[0]u8" },
    }) |case| {
        const source = try std.fmt.allocPrint(allocator,
            \\fn Select() type {{
            \\    var fallback_runs: usize = 0;
            \\    const value: error{{Failure}}!usize = {s};
            \\    const selected = value catch |err| fallback: {{
            \\        fallback_runs += 1;
            \\        break :fallback if (err == error.Failure) 4 else 99;
            \\    }};
            \\    return struct {{ items: [selected]u8, runs: [fallback_runs]u8 }};
            \\}}
            \\const selected: Select() = undefined;
            \\const field = selected.<cursor>
        , .{case.initial});
        defer allocator.free(source);
        try testCompletion(source, &.{
            .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
            .{ .label = "runs", .kind = .Field, .detail = case.runs },
        });
    }
}

test "comptime interpreter propagates known try results" {
    for ([_]struct { initial: []const u8, expected: []const Completion }{
        .{ .initial = "4", .expected = &.{.{ .label = "items", .kind = .Field, .detail = "[4]u8" }} },
        .{ .initial = "error.Failure", .expected = &.{.{ .label = "failure", .kind = .Field, .detail = "u8" }} },
    }) |case| {
        const source = try std.fmt.allocPrint(allocator,
            \\fn TryArray(comptime initial: error{{Failure}}!usize) error{{Failure}}!type {{
            \\    const selected = try initial;
            \\    return struct {{ items: [selected]u8 }};
            \\}}
            \\fn Select() type {{
            \\    return TryArray({s}) catch struct {{ failure: u8 }};
            \\}}
            \\const selected: Select() = undefined;
            \\const field = selected.<cursor>
        , .{case.initial});
        defer allocator.free(source);
        try testCompletion(source, case.expected);
    }

    for ([_]struct { initial: []const u8, expected: []const Completion }{
        .{ .initial = "{}", .expected = &.{.{ .label = "success", .kind = .Field, .detail = "u8" }} },
        .{ .initial = "error.Failure", .expected = &.{.{ .label = "failure", .kind = .Field, .detail = "u8" }} },
    }) |case| {
        const source = try std.fmt.allocPrint(allocator,
            \\fn TryStatement(comptime initial: error{{Failure}}!void) error{{Failure}}!type {{
            \\    try initial;
            \\    return struct {{ success: u8 }};
            \\}}
            \\fn Select() type {{
            \\    return TryStatement({s}) catch struct {{ failure: u8 }};
            \\}}
            \\const selected: Select() = undefined;
            \\const field = selected.<cursor>
        , .{case.initial});
        defer allocator.free(source);
        try testCompletion(source, case.expected);
    }
}

test "comptime interpreter propagates early returns from expressions" {
    for ([_]struct { expression: []const u8, items: []const u8, trace: []const u8 }{
        .{ .expression = "@as(?usize, null) orelse return 7", .items = "[7]u8", .trace = "[1]u8" },
        .{ .expression = "@as(?usize, 4) orelse return 7", .items = "[4]u8", .trace = "[21]u8" },
        .{ .expression = "@as(error{Failure}!usize, error.Failure) catch return 7", .items = "[7]u8", .trace = "[1]u8" },
        .{ .expression = "@as(error{Failure}!usize, 4) catch return 7", .items = "[4]u8", .trace = "[21]u8" },
        .{ .expression = "{ defer trace.* = trace.* * 10 + 3; return 7; }", .items = "[7]u8", .trace = "[31]u8" },
        .{ .expression = "while (true) { return 7; }", .items = "[7]u8", .trace = "[1]u8" },
        .{ .expression = "for (0..1) |_| { return 7; } else 4", .items = "[7]u8", .trace = "[1]u8" },
    }) |case| {
        const source = try std.fmt.allocPrint(allocator,
            \\fn choose(trace: *usize) usize {{
            \\    defer trace.* = trace.* * 10 + 1;
            \\    const value: usize = {s};
            \\    trace.* = trace.* * 10 + 2;
            \\    return value;
            \\}}
            \\fn Select() type {{
            \\    var trace: usize = 0;
            \\    const value = choose(&trace);
            \\    return struct {{ items: [value]u8, trace: [trace]u8 }};
            \\}}
            \\const selected: Select() = undefined;
            \\const field = selected.<cursor>
        , .{case.expression});
        defer allocator.free(source);
        try testCompletion(source, &.{
            .{ .label = "items", .kind = .Field, .detail = case.items },
            .{ .label = "trace", .kind = .Field, .detail = case.trace },
        });
    }
}

test "comptime interpreter propagates breaks and continues from expressions" {
    try testCompletion(
        \\fn Select() type {
        \\    var total: usize = 0;
        \\    var trace: usize = 0;
        \\    for ([_]?usize{ 2, null, 3 }) |optional| {
        \\        defer trace = trace * 10 + 1;
        \\        const value = optional orelse continue;
        \\        total += value;
        \\    }
        \\    const result: usize = outer: {
        \\        defer trace = trace * 10 + 2;
        \\        const ignored: usize = {
        \\            defer trace = trace * 10 + 3;
        \\            break :outer @intCast(total + 2);
        \\        };
        \\        break :outer ignored + 99;
        \\    };
        \\    return struct { items: [result]u8, trace: [trace]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[7]u8" },
        .{ .label = "trace", .kind = .Field, .detail = "[11132]u8" },
    });

    try testCompletion(
        \\fn Select() type {
        \\    var trace: usize = 0;
        \\    var iterations: usize = 0;
        \\    const result: usize = outer: while (iterations < 4) : (iterations += 1) {
        \\        defer trace = trace * 10 + 1;
        \\        const value: usize = while (true) {
        \\            if (iterations == 0) continue :outer;
        \\            const failure: error{Stop}!usize = error.Stop;
        \\            const ignored = failure catch break :outer 7;
        \\            break ignored;
        \\        };
        \\        trace += value;
        \\    } else 99;
        \\    return struct { items: [result]u8, trace: [trace]u8, iterations: [iterations]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[7]u8" },
        .{ .label = "trace", .kind = .Field, .detail = "[11]u8" },
        .{ .label = "iterations", .kind = .Field, .detail = "[1]u8" },
    });
}

test "comptime interpreter stops evaluating operands after expression returns" {
    for ([_][]const u8{
        "_ = (@as(?usize, null) orelse return 7) + changed(trace);",
        "_ = if (@as(?bool, null) orelse return 7) changed(trace) else changed(trace);",
        "_ = switch (@as(?usize, null) orelse return 7) { 0 => changed(trace), else => changed(trace) };",
        "_ = while (false) {} else return 7;",
        "_ = for (0..0) |_| {} else return 7;",
        "while (true) : (return 7) {}",
        "@as(?void, null) orelse return 7;",
    }) |statement| {
        const source = try std.fmt.allocPrint(allocator,
            \\fn changed(trace: *usize) usize {{
            \\    trace.* += 10;
            \\    return 0;
            \\}}
            \\fn choose(trace: *usize) usize {{
            \\    defer trace.* += 1;
            \\    {s}
            \\    return 99;
            \\}}
            \\fn Select() type {{
            \\    var trace: usize = 0;
            \\    const value = choose(&trace);
            \\    return struct {{ items: [value]u8, trace: [trace]u8 }};
            \\}}
            \\const selected: Select() = undefined;
            \\const field = selected.<cursor>
        , .{statement});
        defer allocator.free(source);
        try testCompletion(source, &.{
            .{ .label = "items", .kind = .Field, .detail = "[7]u8" },
            .{ .label = "trace", .kind = .Field, .detail = "[1]u8" },
        });
    }
}

test "comptime interpreter resolves pure optional early returns" {
    for ([_][]const u8{ "null", "u32" }) |initial| {
        const source = try std.fmt.allocPrint(allocator,
            \\fn Select(comptime optional: ?type) type {{
            \\    const T = optional orelse return struct {{ fallback: u8 }};
            \\    return struct {{ item: T }};
            \\}}
            \\const selected: Select({s}) = undefined;
            \\const field = selected.<cursor>
        , .{initial});
        defer allocator.free(source);
        try testCompletion(source, if (std.mem.eql(u8, initial, "null"))
            &.{.{ .label = "fallback", .kind = .Field, .detail = "u8" }}
        else
            &.{.{ .label = "item", .kind = .Field, .detail = "u32" }});
    }
}

test "comptime interpreter unwinds expression error returns once" {
    for ([_][]const u8{
        "@as(?usize, null) orelse return error.Failure",
        "@as(error{Failure}!usize, error.Failure) catch |err| return @as(error{Failure}!usize, err)",
        "try @as(error{Failure}!usize, error.Failure)",
    }) |expression| {
        const source = try std.fmt.allocPrint(allocator,
            \\fn choose(trace: *usize) error{{Failure}}!usize {{
            \\    defer trace.* = trace.* * 10 + 1;
            \\    errdefer |err| trace.* = trace.* * 10 + if (err == error.Failure) 2 else 9;
            \\    const value: usize = result: {{
            \\        defer trace.* = trace.* * 10 + 3;
            \\        break :result {s};
            \\    }};
            \\    trace.* = 99;
            \\    return value;
            \\}}
            \\fn Select() type {{
            \\    var trace: usize = 0;
            \\    const value = choose(&trace) catch 7;
            \\    return struct {{ items: [value]u8, trace: [trace]u8 }};
            \\}}
            \\const selected: Select() = undefined;
            \\const field = selected.<cursor>
        , .{expression});
        defer allocator.free(source);
        try testCompletion(source, &.{
            .{ .label = "items", .kind = .Field, .detail = "[7]u8" },
            .{ .label = "trace", .kind = .Field, .detail = "[321]u8" },
        });
    }
}

test "comptime interpreter runs errdefers on propagated errors" {
    for ([_]struct { mode: []const u8, trace: []const u8 }{
        .{ .mode = "0", .trace = "[413]u8" },
        .{ .mode = "1", .trace = "[123]u8" },
        .{ .mode = "2", .trace = "[123]u8" },
    }) |case| {
        const source = try std.fmt.allocPrint(allocator,
            \\fn update(comptime mode: u8, trace: *usize) error{{Failure}}!void {{
            \\    defer trace.* = trace.* * 10 + 3;
            \\    errdefer |err| trace.* = trace.* * 10 + if (err == error.Failure) 2 else 9;
            \\    defer trace.* = trace.* * 10 + 1;
            \\    if (mode == 1) return error.Failure;
            \\    const initial: error{{Failure}}!void = if (mode == 2) error.Failure else {{}};
            \\    try initial;
            \\    trace.* = trace.* * 10 + 4;
            \\}}
            \\fn Select() type {{
            \\    var trace: usize = 0;
            \\    update({s}, &trace) catch {{}};
            \\    return struct {{ trace: [trace]u8 }};
            \\}}
            \\const selected: Select() = undefined;
            \\const field = selected.<cursor>
        , .{case.mode});
        defer allocator.free(source);
        try testCompletion(source, &.{.{ .label = "trace", .kind = .Field, .detail = case.trace }});
    }
}

test "comptime interpreter branches on known error unions" {
    for ([_]struct { initial: []const u8, items: []const u8, runs: []const u8 }{
        .{ .initial = "4", .items = "[6]u8", .runs = "[1]u8" },
        .{ .initial = "error.Failure", .items = "[7]u8", .runs = "[1]u8" },
    }) |case| {
        const source = try std.fmt.allocPrint(allocator,
            \\fn Select(comptime initial: error{{Failure}}!usize) type {{
            \\    var runs: usize = 0;
            \\    const selected = if (condition: {{
            \\        runs += 1;
            \\        break :condition initial;
            \\    }}) |payload| payload + 2 else |err| if (err == error.Failure) 7 else 99;
            \\    var mutable: error{{}}!usize = 4;
            \\    if (mutable) |*payload| payload.* += 2 else |_| unreachable;
            \\    const from_while = while (initial) |payload| {{
            \\        break payload + 1;
            \\    }} else |err| if (err == error.Failure) 3 else 99;
            \\    return struct {{
            \\        items: [selected]u8,
            \\        runs: [runs]u8,
            \\        mutable: [mutable catch 99]u8,
            \\        loop: [from_while]u8,
            \\    }};
            \\}}
            \\const selected: Select({s}) = undefined;
            \\const field = selected.<cursor>
        , .{case.initial});
        defer allocator.free(source);
        try testCompletion(source, &.{
            .{ .label = "items", .kind = .Field, .detail = case.items },
            .{ .label = "runs", .kind = .Field, .detail = case.runs },
            .{ .label = "mutable", .kind = .Field, .detail = "[6]u8" },
            .{ .label = "loop", .kind = .Field, .detail = if (std.mem.eql(u8, case.initial, "4")) "[5]u8" else "[3]u8" },
        });
    }
}

test "comptime interpreter snapshots error union if captures" {
    for ([_][]const u8{ "4", "error.Failure" }) |initial| {
        const source = try std.fmt.allocPrint(allocator,
            \\fn Select() type {{
            \\    var value: error{{Failure}}!usize = {s};
            \\    const selected = if (value) |payload| result: {{
            \\        value = 9;
            \\        break :result payload + payload;
            \\    }} else |err| result: {{
            \\        value = 9;
            \\        break :result if (err == error.Failure) 7 else 99;
            \\    }};
            \\    return struct {{ items: [selected]u8, changed: [value catch 99]u8 }};
            \\}}
            \\const selected: Select() = undefined;
            \\const field = selected.<cursor>
        , .{initial});
        defer allocator.free(source);
        try testCompletion(source, &.{
            .{ .label = "items", .kind = .Field, .detail = if (std.mem.eql(u8, initial, "4")) "[8]u8" else "[7]u8" },
            .{ .label = "changed", .kind = .Field, .detail = "[9]u8" },
        });
    }
}

test "comptime interpreter evaluates error union pointer capture lvalues once" {
    try testCompletion(
        \\fn Select() type {
        \\    var values: [2]error{Done}!usize = .{ 3, 7 };
        \\    var evaluations: usize = 0;
        \\    var iterations: usize = 0;
        \\    var total: usize = 0;
        \\    var completed: usize = 0;
        \\    while (values[index: {
        \\        evaluations += 1;
        \\        break :index 0;
        \\    }]) |*payload| : (iterations += 1) {
        \\        total += payload.*;
        \\        payload.* -= 1;
        \\        if (payload.* == 0) values[0] = error.Done;
        \\        continue;
        \\    } else |err| {
        \\        completed = if (err == error.Done) 1 else 99;
        \\    }
        \\    return struct {
        \\        items: [total]u8,
        \\        evaluations: [evaluations]u8,
        \\        iterations: [iterations]u8,
        \\        completed: [completed]u8,
        \\        sibling: [values[1] catch 99]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[6]u8" },
        .{ .label = "evaluations", .kind = .Field, .detail = "[4]u8" },
        .{ .label = "iterations", .kind = .Field, .detail = "[3]u8" },
        .{ .label = "completed", .kind = .Field, .detail = "[1]u8" },
        .{ .label = "sibling", .kind = .Field, .detail = "[7]u8" },
    });
}

test "comptime interpreter branches on error unions without payload captures" {
    for ([_][]const u8{ "if", "while" }) |branch| {
        for ([_][]const u8{ "{}", "error.Failure" }) |initial| {
            const source = try std.fmt.allocPrint(allocator,
                \\fn Select(comptime initial: error{{Failure}}!void) type {{
                \\    return {s} (initial) {s}struct {{ success: u8 }}{s} else |err|
                \\        if (err == error.Failure) struct {{ failure: u8 }} else struct {{ unexpected: u8 }};
                \\}}
                \\const selected: Select({s}) = undefined;
                \\const field = selected.<cursor>
            , .{ branch, if (std.mem.eql(u8, branch, "while")) "{ break " else "", if (std.mem.eql(u8, branch, "while")) "; }" else "", initial });
            defer allocator.free(source);
            try testCompletion(source, &.{.{
                .label = if (std.mem.eql(u8, initial, "{}")) "success" else "failure",
                .kind = .Field,
                .detail = "u8",
            }});
        }
    }
}

test "comptime interpreter evaluates optional if conditions once" {
    for ([_][]const u8{ "4", "null" }) |initial| {
        const source = try std.fmt.allocPrint(allocator,
            \\fn Select() type {{
            \\    var optional: ?usize = {s};
            \\    var evaluations: usize = 0;
            \\    const selected = if (condition: {{
            \\        evaluations += 1;
            \\        break :condition optional;
            \\    }}) |payload| result: {{
            \\        optional = 9;
            \\        break :result payload + payload;
            \\    }} else 7;
            \\    return struct {{ items: [selected]u8, evaluations: [evaluations]u8 }};
            \\}}
            \\const selected: Select() = undefined;
            \\const field = selected.<cursor>
        , .{initial});
        defer allocator.free(source);
        try testCompletion(source, &.{
            .{ .label = "items", .kind = .Field, .detail = if (std.mem.eql(u8, initial, "4")) "[8]u8" else "[7]u8" },
            .{ .label = "evaluations", .kind = .Field, .detail = "[1]u8" },
        });
    }
}

test "comptime interpreter snapshots optional if captures" {
    try testCompletion(
        \\fn Select() type {
        \\    var optional: ?usize = 4;
        \\    var selected: usize = 0;
        \\    if (optional) |payload| {
        \\        optional = 9;
        \\        selected = payload + payload;
        \\    }
        \\    return struct { items: [selected]u8, changed: [optional.?]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[8]u8" },
        .{ .label = "changed", .kind = .Field, .detail = "[9]u8" },
    });
}

test "comptime interpreter evaluates optional while conditions once" {
    try testCompletion(
        \\fn next(value: *usize, evaluations: *usize) ?usize {
        \\    evaluations.* += 1;
        \\    if (value.* == 0) return null;
        \\    value.* -= 1;
        \\    return value.* + 1;
        \\}
        \\fn Select() type {
        \\    var remaining: usize = 3;
        \\    var evaluations: usize = 0;
        \\    var total: usize = 0;
        \\    var completed: usize = 0;
        \\    while (next(&remaining, &evaluations)) |payload| {
        \\        total += payload + payload;
        \\    } else completed += 1;
        \\    return struct {
        \\        items: [total]u8,
        \\        evaluations: [evaluations]u8,
        \\        completed: [completed]u8,
        \\        remaining: [remaining]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[12]u8" },
        .{ .label = "evaluations", .kind = .Field, .detail = "[4]u8" },
        .{ .label = "completed", .kind = .Field, .detail = "[1]u8" },
        .{ .label = "remaining", .kind = .Field, .detail = "[0]u8" },
    });
}

test "comptime interpreter evaluates optional pointer capture lvalues once" {
    try testCompletion(
        \\fn Select() type {
        \\    var values: [2]?usize = .{ 4, 7 };
        \\    var evaluations: usize = 0;
        \\    var selected: usize = 0;
        \\    if (values[index: {
        \\        evaluations += 1;
        \\        break :index 0;
        \\    }]) |*payload| {
        \\        payload.* += 2;
        \\        selected = payload.*;
        \\    }
        \\    return struct {
        \\        items: [selected]u8,
        \\        evaluations: [evaluations]u8,
        \\        changed: [values[0].?]u8,
        \\        sibling: [values[1].?]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[6]u8" },
        .{ .label = "evaluations", .kind = .Field, .detail = "[1]u8" },
        .{ .label = "changed", .kind = .Field, .detail = "[6]u8" },
        .{ .label = "sibling", .kind = .Field, .detail = "[7]u8" },
    });
}

test "comptime interpreter evaluates nested optional pointer lvalues once" {
    try testCompletion(
        \\fn Select() type {
        \\    var values: [1][2]?usize = .{.{ 4, 7 }};
        \\    var evaluations: usize = 0;
        \\    if (values[row: {
        \\        evaluations += 1;
        \\        break :row 0;
        \\    }][column: {
        \\        evaluations = evaluations * 10 + 2;
        \\        break :column 0;
        \\    }]) |*payload| payload.* += 2;
        \\    return struct {
        \\        changed: [values[0][0].?]u8,
        \\        sibling: [values[0][1].?]u8,
        \\        evaluations: [evaluations]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "changed", .kind = .Field, .detail = "[6]u8" },
        .{ .label = "sibling", .kind = .Field, .detail = "[7]u8" },
        .{ .label = "evaluations", .kind = .Field, .detail = "[12]u8" },
    });
}

test "comptime interpreter refreshes optional while captures" {
    try testCompletion(
        \\fn Select() type {
        \\    var optional: ?usize = 3;
        \\    var total: usize = 0;
        \\    var continuations: usize = 0;
        \\    while (optional) |payload| : (continuations += 1) {
        \\        optional = if (payload > 1) payload - 1 else null;
        \\        total += payload;
        \\        if (payload == 2) continue;
        \\        total += payload;
        \\    }
        \\    return struct { items: [total]u8, continuations: [continuations]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[10]u8" },
        .{ .label = "continuations", .kind = .Field, .detail = "[3]u8" },
    });
}

test "comptime interpreter evaluates while pointer conditions once" {
    try testCompletion(
        \\fn Select() type {
        \\    var values: [2]?usize = .{ 3, 7 };
        \\    var evaluations: usize = 0;
        \\    var total: usize = 0;
        \\    var completed: usize = 0;
        \\    while (values[index: {
        \\        evaluations += 1;
        \\        break :index 0;
        \\    }]) |*payload| {
        \\        total += payload.*;
        \\        if (payload.* > 1) payload.* -= 1 else values[0] = null;
        \\    } else completed += 1;
        \\    return struct {
        \\        items: [total]u8,
        \\        evaluations: [evaluations]u8,
        \\        completed: [completed]u8,
        \\        sibling: [values[1].?]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[6]u8" },
        .{ .label = "evaluations", .kind = .Field, .detail = "[4]u8" },
        .{ .label = "completed", .kind = .Field, .detail = "[1]u8" },
        .{ .label = "sibling", .kind = .Field, .detail = "[7]u8" },
    });
}

test "comptime interpreter evaluates boolean while conditions once" {
    try testCompletion(
        \\fn Select() type {
        \\    var evaluations: usize = 0;
        \\    var total: usize = 0;
        \\    while (condition: {
        \\        evaluations += 1;
        \\        break :condition total < 3;
        \\    }) total += 1;
        \\    return struct { items: [total]u8, evaluations: [evaluations]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[3]u8" },
        .{ .label = "evaluations", .kind = .Field, .detail = "[4]u8" },
    });
}

test "comptime interpreter preserves optional condition uncertainty" {
    try testCompletion(
        \\var runtime: u8 = undefined;
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    const present: ?usize = runtime;
        \\    return if (present) |payload|
        \\        struct { value: @TypeOf(payload), items: [payload]u8 }
        \\    else
        \\        struct { absent: u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "value", .kind = .Field, .detail = "usize" },
        .{ .label = "items", .kind = .Field, .detail = "[?]u8" },
    });

    try testCompletion(
        \\var runtime: ?usize = undefined;
        \\fn Select() type {
        \\    var marker: usize = 0;
        \\    marker += 1;
        \\    return if (runtime) |payload|
        \\        struct { present: @TypeOf(payload) }
        \\    else
        \\        struct { absent: u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "present", .kind = .Field, .detail = "usize" },
        .{ .label = "absent", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with comptime optional condition" {
    try testCompletion(
        \\fn Select(comptime value: ?usize) type {
        \\    return if (value == null)
        \\        struct { none: u8 }
        \\    else
        \\        struct { some: u8 };
        \\}
        \\const selected: Select(null) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "none", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime value: ?usize) type {
        \\    return if (value != null)
        \\        struct { some: u8 }
        \\    else
        \\        struct { none: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "some", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with comptime optional payload mutation" {
    try testCompletion(
        \\fn Buffer(comptime value: ?u8) type {
        \\    var capacity: u8 = 1;
        \\    if (value) |payload| {
        \\        capacity += payload;
        \\    } else {
        \\        capacity = 8;
        \\    }
        \\    return struct { items: [capacity]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[3]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime value: ?u8) type {
        \\    var capacity: u8 = 1;
        \\    if (value) |payload| {
        \\        capacity += payload;
        \\    } else {
        \\        capacity = 8;
        \\    }
        \\    return struct { items: [capacity]u8 };
        \\}
        \\const buffer: Buffer(null) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[8]u8" },
    });
}

test "generic function with comptime optional pointer capture mutation" {
    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    var capacity: ?usize = 1;
        \\    if (capacity) |*payload| {
        \\        payload.* += base;
        \\    }
        \\    return struct { items: [capacity.?]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[3]u8" },
    });

    try testCompletion(
        \\const State = struct { capacity: ?usize };
        \\fn Buffer(comptime scale: usize) type {
        \\    var state = State{ .capacity = 2 };
        \\    while (state.capacity) |*payload| {
        \\        payload.* *= scale;
        \\        break;
        \\    }
        \\    return struct { items: [state.capacity.?]u8 };
        \\}
        \\const buffer: Buffer(3) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[6]u8" },
    });
}

test "generic function with comptime optional unwrap mutation" {
    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    var capacity: ?usize = 1;
        \\    capacity.? += base;
        \\    return struct { items: [capacity.?]u8 };
        \\}
        \\const buffer: Buffer(3) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
    });

    try testCompletion(
        \\const State = struct { capacity: ?usize };
        \\fn Buffer(comptime scale: usize) type {
        \\    var state = State{ .capacity = 2 };
        \\    state.capacity.? += 1;
        \\    const capacity_ptr = &state.capacity.?;
        \\    state.capacity.? += 1;
        \\    capacity_ptr.* *= scale;
        \\    return struct { items: [state.capacity.?]u8 };
        \\}
        \\const buffer: Buffer(3) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[12]u8" },
    });
}

test "generic function with runtime optional orelse null type" {
    try testCompletion(
        \\var runtime_optional: ?u8 = null;
        \\fn Select(comptime Expected: type) type {
        \\    const value = runtime_optional orelse null;
        \\    return if (@TypeOf(value) == Expected)
        \\        struct { preserved: u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(?u8) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "preserved", .kind = .Field, .detail = "u8" },
    });
}

test "generic function with runtime optional self equality" {
    try testCompletion(
        \\var runtime_integer: ?u8 = null;
        \\var runtime_boolean: ?bool = null;
        \\var storage: u8 = 0;
        \\var runtime_pointer: ?*u8 = &storage;
        \\fn Select(comptime N: u8) type {
        \\    return if (runtime_integer == runtime_integer and
        \\        !(runtime_boolean != runtime_boolean) and
        \\        runtime_pointer == runtime_pointer)
        \\        struct { matched: [N]u8 }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select(4) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "matched", .kind = .Field, .detail = "[4]u8" },
    });
}

test "generic function with comptime optional payload" {
    try testCompletion(
        \\fn Buffer(comptime value: ?usize) type {
        \\    return struct { items: [value orelse 4]u8 };
        \\}
        \\const buffer: Buffer(null) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime value: ?usize) type {
        \\    return struct {
        \\        fallback: [value orelse 4]u8,
        \\        unwrapped: [value.?]u8,
        \\        short_circuit: [value orelse @compileError("unselected")]u8,
        \\    };
        \\}
        \\const buffer: Buffer(3) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "fallback", .kind = .Field, .detail = "[3]u8" },
        .{ .label = "unwrapped", .kind = .Field, .detail = "[3]u8" },
        .{ .label = "short_circuit", .kind = .Field, .detail = "[3]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime value: ?usize) type {
        \\    return struct { items: [(value orelse 3) + 1]u8 };
        \\}
        \\const buffer: Buffer(null) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime value: ?usize) type {
        \\    return struct { items: [value orelse 4]u8 };
        \\}
        \\const buffer: Buffer(undefined) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[?]u8" },
    });
}

test "generic function with comptime orelse expression mutations" {
    try testCompletion(
        \\fn Buffer(comptime value: ?usize) type {
        \\    var total: usize = 1;
        \\    const selected = value orelse fallback: {
        \\        defer total += 1;
        \\        total *= 3;
        \\        break :fallback total;
        \\    };
        \\    return struct { items: [selected * total]u8 };
        \\}
        \\const buffer: Buffer(null) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[12]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime value: ?usize) type {
        \\    var total: usize = 1;
        \\    const selected = value orelse fallback: {
        \\        total = 99;
        \\        break :fallback total;
        \\    };
        \\    return struct { items: [selected * total]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[2]u8" },
    });
}

test "generic function with nested comptime optional unwrap mutation" {
    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    var total: usize = base;
        \\    const selected = (value: {
        \\        defer total += 1;
        \\        total *= 2;
        \\        break :value @as(?usize, total);
        \\    }).?;
        \\    return struct { items: [selected * total]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[20]u8" },
    });
}

test "generic function with nested comptime aggregate access mutations" {
    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    var total: usize = base;
        \\    const selected = (value: {
        \\        defer total += 1;
        \\        total *= 2;
        \\        break :value .{ total, total + 1 };
        \\    }).@"1";
        \\    return struct { items: [selected * total]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[25]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    var total: usize = base;
        \\    const selected = (value: {
        \\        total += 1;
        \\        break :value .{ total, total * 2 };
        \\    })[1];
        \\    return struct { items: [selected * total]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[18]u8" },
    });
}

test "generic function with comptime unknown array index type" {
    try testCompletion(
        \\var runtime_index: usize = undefined;
        \\fn Select() type {
        \\    var total: usize = 1;
        \\    const selected = (source: {
        \\        total += 1;
        \\        break :source [_]i16{ 10, 20 };
        \\    })[index: {
        \\        total *= 2;
        \\        break :index runtime_index;
        \\    }];
        \\    total += 1;
        \\    return struct { value: @TypeOf(selected), items: [total]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "value", .kind = .Field, .detail = "i16" },
        .{ .label = "items", .kind = .Field, .detail = "[5]u8" },
    });
}

test "generic function with nested comptime array operator mutations" {
    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    var total: usize = base;
        \\    const repeated = (source: {
        \\        defer total += 1;
        \\        total *= 2;
        \\        break :source [_]usize{ total, total + 1 };
        \\    }) ** (count: {
        \\        total += 1;
        \\        break :count 2;
        \\    });
        \\    const combined = (left: {
        \\        total += repeated[3];
        \\        break :left [_]usize{total};
        \\    }) ++ (right: {
        \\        defer total += 1;
        \\        total *= 2;
        \\        break :right [_]usize{ total, total + 1 };
        \\    });
        \\    return struct { items: [combined[0] + combined[2] + total]u8 };
        \\}
        \\const buffer: Buffer(2) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[57]u8" },
    });
}

test "generic function with nested comptime slice mutations" {
    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    var total: usize = base;
        \\    const selected = (source: {
        \\        total += 1;
        \\        break :source [_]usize{ 10, 20, 30, 40 };
        \\    })[(start: {
        \\        total *= 2;
        \\        break :start 1;
        \\    })..(end: {
        \\        defer total += 1;
        \\        break :end 3;
        \\    })];
        \\    return struct { items: [selected[0] + selected[1] + total]u8 };
        \\}
        \\const buffer: Buffer(1) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[55]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    var total: usize = base;
        \\    const selected = (source: {
        \\        total += 1;
        \\        break :source [_]usize{ 10, 20, 30 };
        \\    })[(start: {
        \\        defer total += 1;
        \\        total *= 2;
        \\        break :start 1;
        \\    })..];
        \\    return struct { items: [selected[0] + selected[1] + total]u8 };
        \\}
        \\const buffer: Buffer(1) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[55]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime base: usize) type {
        \\    var total: usize = base;
        \\    const selected = (source: {
        \\        total += 1;
        \\        break :source [_:0]usize{ 10, 20, 30 };
        \\    })[(start: {
        \\        total *= 2;
        \\        break :start 1;
        \\    })..(end: {
        \\        total += 1;
        \\        break :end 3;
        \\    }) :(sentinel: {
        \\        defer total += 1;
        \\        total *= 2;
        \\        break :sentinel 0;
        \\    })];
        \\    return struct { items: [selected[0] + selected[1] + total]u8 };
        \\}
        \\const buffer: Buffer(1) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[61]u8" },
    });
}

test "generic function with comptime unknown slice bound types" {
    try testCompletion(
        \\var runtime_start: usize = undefined;
        \\var runtime_end: usize = undefined;
        \\fn Select() type {
        \\    var total: usize = 1;
        \\    const open = (source: {
        \\        total += 1;
        \\        break :source [_]i16{ 10, 20, 30, 40 };
        \\    })[(start: {
        \\        total *= 2;
        \\        break :start runtime_start;
        \\    })..];
        \\    const ranged = (source: {
        \\        total += 1;
        \\        break :source [_]i16{ 10, 20, 30, 40 };
        \\    })[(start: {
        \\        total *= 2;
        \\        break :start runtime_start;
        \\    })..(end: {
        \\        total += 3;
        \\        break :end runtime_end;
        \\    })];
        \\    total += 1;
        \\    return struct {
        \\        open: @TypeOf(open),
        \\        ranged: @TypeOf(ranged),
        \\        items: [total]u8,
        \\    };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "open", .kind = .Field, .detail = "[]i16" },
        .{ .label = "ranged", .kind = .Field, .detail = "[]i16" },
        .{ .label = "items", .kind = .Field, .detail = "[14]u8" },
    });
}

test "generic function with comptime boolean short circuit mutations" {
    try testCompletion(
        \\fn Buffer(comptime enabled: bool) type {
        \\    var total: usize = 1;
        \\    const selected = enabled and branch: {
        \\        defer total += 1;
        \\        total *= 3;
        \\        break :branch total == 3;
        \\    };
        \\    return struct { items: [if (selected) total else 99]u8 };
        \\}
        \\const buffer: Buffer(true) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[4]u8" },
    });

    try testCompletion(
        \\fn Buffer(comptime enabled: bool) type {
        \\    var total: usize = 1;
        \\    const selected = enabled or branch: {
        \\        total = 99;
        \\        break :branch false;
        \\    };
        \\    return struct { items: [if (selected) total else 200]u8 };
        \\}
        \\const buffer: Buffer(true) = undefined;
        \\const field = buffer.<cursor>
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[1]u8" },
    });
}

test "zero-parameter type function comptime evaluation" {
    try testCompletion(
        \\fn capacity() usize {
        \\    var value: usize = 1;
        \\    value += 2;
        \\    return value;
        \\}
        \\fn Select() type {
        \\    return struct { items: [capacity()]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{.{ .label = "items", .kind = .Field, .detail = "[3]u8" }});

    try testCompletion(
        \\fn capacity() usize {
        \\    var value: usize = 2;
        \\    value *= 3;
        \\    return value;
        \\}
        \\fn forwardedCapacity() usize {
        \\    return capacity();
        \\}
        \\fn Select() type {
        \\    return struct { items: [forwardedCapacity()]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{.{ .label = "items", .kind = .Field, .detail = "[6]u8" }});

    try testCompletion(
        \\fn capacity() comptime_int {
        \\    var value = 2;
        \\    value *= 4;
        \\    return value;
        \\}
        \\fn Select() type {
        \\    return struct { items: [capacity()]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{.{ .label = "items", .kind = .Field, .detail = "[8]u8" }});

    try testCompletion(
        \\fn capacity(base: u8) usize {
        \\    var value: usize = base;
        \\    value += 3;
        \\    return value;
        \\}
        \\fn Select() type {
        \\    return struct { items: [capacity(4)]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{.{ .label = "items", .kind = .Field, .detail = "[7]u8" }});

    try testCompletion(
        \\fn capacity() i32 {
        \\    var value: i32 = 2;
        \\    value += 3;
        \\    return value;
        \\}
        \\fn Select() type {
        \\    return struct { items: [capacity()]u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{.{ .label = "items", .kind = .Field, .detail = "[5]u8" }});

    try testCompletion(
        \\fn signedValue() i32 {
        \\    var value: i32 = 1;
        \\    value -= 2;
        \\    return value;
        \\}
        \\fn Select() type {
        \\    return if (signedValue() == -1)
        \\        struct { preserved: u8 }
        \\    else
        \\        struct { corrupted: u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{.{ .label = "preserved", .kind = .Field, .detail = "u8" }});

    try testCompletion(
        \\fn Select() type {
        \\    return if (@inComptime())
        \\        struct { comptime_only: u8 }
        \\    else
        \\        struct { runtime_only: u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "comptime_only", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Recursive() type {
        \\    return Recursive();
        \\}
        \\const selected: Recursive() = undefined;
        \\const field = selected.<cursor>
    , &.{});

    try testCompletion(
        \\fn Select(comptime enabled: bool) type {
        \\    if (enabled) {
        \\        const marker = 1;
        \\        _ = marker;
        \\    } else return struct { inactive: u8 };
        \\    return struct { active: u8 };
        \\}
        \\const selected: Select(true) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "active", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime enabled: bool) type {
        \\    if (enabled) return struct { active: u8 } else return struct { inactive: u8 };
        \\}
        \\const selected: Select(false) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "inactive", .kind = .Field, .detail = "u8" },
    });
}

test "type function with comptime early returns" {
    try testCompletion(
        \\fn Select(comptime enabled: bool) type {
        \\    if (enabled) return struct { active: u8 };
        \\    return struct { inactive: u8 };
        \\}
        \\const selected: Select(true) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "active", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime value: usize) type {
        \\    if (value == 1) return struct { one: u8 };
        \\    if (value == 2) return struct { two: u8 };
        \\    return struct { other: u8 };
        \\}
        \\const selected: Select(2) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "two", .kind = .Field, .detail = "u8" },
    });

    try testCompletion(
        \\fn Select(comptime enabled: bool) type {
        \\    if (enabled) return struct { active: u8 };
        \\    return struct { inactive: u8 };
        \\}
        \\const selected: Select(undefined) = undefined;
        \\const field = selected.<cursor>
    , &.{});

    try testCompletion(
        \\fn Select(comptime value: ?usize) type {
        \\    if (value) |_| return struct { some: u8 };
        \\    return struct { none: u8 };
        \\}
        \\const selected: Select(null) = undefined;
        \\const field = selected.<cursor>
    , &.{
        .{ .label = "none", .kind = .Field, .detail = "u8" },
    });
}

test "nested generic function" {
    try testCompletion(
        \\fn ArrayList(comptime T: type) type {
        \\    return ArrayListAligned(T, null);
        \\}
        \\
        \\fn ArrayListAligned(comptime T: type) type {
        \\    return struct {
        \\        items: []T,
        \\
        \\        const empty: @This() = .{
        \\            .items = &.{},
        \\        };
        \\    };
        \\}
        \\
        \\var list: ArrayList(u8) = .<cursor>;
    , &.{
        .{ .label = "items", .kind = .Field, .detail = "[]u8" },
        .{ .label = "empty", .kind = .Constant, .detail = "ArrayListAligned(u8)" },
    });
}

test "recursive generic function" {
    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\fn ArrayList(comptime T: type) type {
        \\    return ArrayList(T);
        \\}
        \\const array_list: ArrayList(S) = undefined;
        \\const foo = array_list.<cursor>
    , &.{});
    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\fn ArrayList(comptime T: type) type {
        \\    return ArrayList(T);
        \\}
        \\const foo = ArrayList(S).<cursor>
    , &.{});
    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\fn Foo(comptime T: type) type {
        \\    return Bar(T);
        \\}
        \\fn Bar(comptime T: type) type {
        \\    return Foo(T);
        \\}
        \\const foo: Foo(S) = undefined;
        \\const value = array_list.<cursor>
    , &.{});
}

test "generic function without body" {
    try testCompletion(
        \\const Foo: fn (type) type = undefined;
        \\const Bar = Foo(u32);
        \\const value = Bar.<cursor>;
    , &.{});
}

test "std.ArrayList" {
    try testCompletion(
        \\const std = @import("std");
        \\const S = struct { alpha: u32 };
        \\const array_list: std.ArrayList(S) = undefined;
        \\const foo = array_list.items[0].<cursor>
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
}

test "std.array_hash_map" {
    try testCompletion(
        \\const std = @import("std");
        \\const map: std.array_hash_map.String(void) = undefined;
        \\const key = map.getKey("");
        \\const foo = key.?.<cursor>
    , &.{
        .{ .label = "len", .kind = .Field, .detail = "usize" },
        .{ .label = "ptr", .kind = .Field, .detail = "[*]const u8" },
    });
    try testCompletion(
        \\const std = @import("std");
        \\const S = struct { alpha: u32 };
        \\const map: std.array_hash_map.Auto(u32, S) = undefined;
        \\const s = map.get(0);
        \\const foo = s.?.<cursor>
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
    try testCompletion(
        \\const std = @import("std");
        \\const S = struct { alpha: u32 };
        \\const map: std.array_hash_map.Auto(u32, S) = undefined;
        \\const gop = try map.getOrPut(undefined, 0);
        \\const foo = gop.value_ptr.<cursor>
    , &.{
        .{ .label = "*", .kind = .Operator, .detail = "S" },
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
}

test "std.HashMap" {
    try testCompletion(
        \\const std = @import("std");
        \\const map: std.StringHashMapUnmanaged(void) = undefined;
        \\const key = map.getKey("");
        \\const foo = key.?.<cursor>
    , &.{
        .{ .label = "len", .kind = .Field, .detail = "usize" },
        .{ .label = "ptr", .kind = .Field, .detail = "[*]const u8" },
    });
    try testCompletion(
        \\const std = @import("std");
        \\const S = struct { alpha: u32 };
        \\const map: std.AutoHashMapUnmanaged(u32, S) = undefined;
        \\const s = map.get(0);
        \\const foo = s.?.<cursor>
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
    try testCompletion(
        \\const std = @import("std");
        \\const S = struct { alpha: u32 };
        \\const map: std.AutoHashMapUnmanaged(u32, S) = undefined;
        \\const gop = try map.getOrPut(undefined, 0);
        \\const foo = gop.value_ptr.<cursor>
    , &.{
        .{ .label = "*", .kind = .Operator, .detail = "S" },
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
}

test "function call" {
    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\fn func() S {}
        \\const foo = func().<cursor>;
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\fn func() S {}
        \\const foo = func();
        \\const bar = foo.<cursor>;
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });

    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\const func: fn() S = undefined;
        \\const foo = func().<cursor>;
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\const func: fn() S = undefined;
        \\const foo = func();
        \\const bar = foo.<cursor>;
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });

    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\const func: *const fn() S = undefined;
        \\const foo = func().<cursor>;
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\const func: *const fn() S = undefined;
        \\const foo = func();
        \\const bar = foo.<cursor>;
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
}

test "chained function call" {
    try testCompletion(
        \\const S1 = struct {
        \\    alpha: u32,
        \\    fn init() S1 {}
        \\    fn foo(_: S1, _: S2) void {}
        \\};
        \\const S2 = struct {
        \\    beta: []const u8,
        \\};
        \\const bar = S1.init().foo(.{.<cursor>});
    , &.{
        .{ .label = "beta", .kind = .Field, .detail = "[]const u8" },
    });
}

test "resolve return type of function with invalid parameter" {
    try testCompletion(
        \\fn Foo(foo: unknown) type {
        \\    _ = foo;
        \\    return struct { alpha: u32 };
        \\}
        \\var foo: Foo() = undefined;
        \\const bar = foo.<cursor>
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
}

test "resolve parameters of function with invalid return type" {
    try testCompletion(
        \\fn foo(_: struct { alpha: u32 }) unknown {}
        \\const bar = foo(.<cursor>)
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
}

test "optional" {
    try testCompletion(
        \\const foo: ?u32 = undefined;
        \\const bar = foo.<cursor>
    , &.{
        .{ .label = "?", .kind = .Operator, .detail = "u32" },
    });

    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\const foo: ?S = undefined;
        \\const bar = foo.?.<cursor>
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
}

test "optional type" {
    try testCompletion(
        \\const foo = ?u32;
        \\const bar = foo.<cursor>
    , &.{});
}

test "pointer deref" {
    try testCompletion(
        \\const foo: *u32 = undefined;
        \\const bar = foo.<cursor>
    , &.{
        .{ .label = "*", .kind = .Operator, .detail = "u32" },
    });
    try testCompletion(
        \\const foo: [*c]u32 = undefined;
        \\const bar = foo.<cursor>
    , &.{
        .{ .label = "*", .kind = .Operator, .detail = "u32" },
        .{ .label = "?", .kind = .Operator, .detail = "[*c]u32" },
    });
    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\const foo: *S = undefined;
        \\const bar = foo.*.<cursor>
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\const foo: *S = undefined;
        \\const bar = foo.<cursor>
    , &.{
        .{ .label = "*", .kind = .Operator, .detail = "S" },
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\const foo: [*c]S = undefined;
        \\const bar = foo.<cursor>
    , &.{
        .{ .label = "*", .kind = .Operator, .detail = "S" },
        .{ .label = "?", .kind = .Operator, .detail = "[*c]S" },
    });
}

test "pointer array access" {
    try testCompletion(
        \\const S = struct {
        \\    alpha: u32,
        \\};
        \\const foo: [*]S = undefined;
        \\const bar = foo[0].<cursor>
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\const foo: []S = undefined;
        \\const bar = foo[0].<cursor>
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
    try testCompletion(
        \\const S = struct {
        \\    alpha: u32,
        \\};
        \\const foo: [*c]S = undefined;
        \\const bar = foo[0].<cursor>
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
    try testCompletion(
        \\const S = struct {
        \\    alpha: u32,
        \\};
        \\const foo: []S = undefined;
        \\const bar = foo.ptr[0].<cursor>
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
}

test "pointer subslicing" {
    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\const foo: []S = undefined;
        \\const bar = foo[0..].<cursor>
    , &.{
        .{ .label = "len", .kind = .Field, .detail = "usize" },
        .{ .label = "ptr", .kind = .Field, .detail = "[*]S" },
    });
    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\const foo: []S = undefined;
        \\const bar = foo.ptr[0..].<cursor>
    , &.{});
    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\const foo: [*c]S = undefined;
        \\const bar = foo.ptr[0..].<cursor>
    , &.{});
}

test "pointer subslicing parser correctness" {
    try testCompletion(
        \\const foo: [*]u32 = undefined;
        \\const bar = foo[foo[0]..].<cursor>
    , &.{});
    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\const foo: []S = undefined;
        \\const bar = foo.ptr[foo[0]..][0].<cursor>
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
    try testCompletion(
        \\const foo: [*]u32 = undefined;
        \\const bar = foo[foo[0..2]..].<cursor>
    , &.{});
    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\const foo: [*c]S = undefined;
        \\const bar = foo[foo[0..2]..foo[0..]].<cursor>
    , &.{
        .{ .label = "len", .kind = .Field, .detail = "usize" },
        .{ .label = "ptr", .kind = .Field, .detail = "[*]S" },
    });
    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\const foo: [*c]S = undefined;
        \\const bar = foo[foo[0..2]..foo[0..]][0].<cursor>
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
}

test "slice pointer" {
    try testCompletion(
        \\const foo: []const u8 = undefined;
        \\const bar = foo.<cursor>
    , &.{
        .{ .label = "len", .kind = .Field, .detail = "usize" },
        .{ .label = "ptr", .kind = .Field, .detail = "[*]const u8" },
    });
}

test "many item pointer" {
    try testCompletion(
        \\const foo: [*]u32 = undefined;
        \\const bar = foo.<cursor>
    , &.{});
    try testCompletion(
        \\const S = struct {
        \\    alpha: u32,
        \\};
        \\const foo: []S = undefined;
        \\const bar = foo.ptr.<cursor>
    , &.{});
}

test "address of" {
    try testCompletion(
        \\const value: u32 = undefined;
        \\const value_ptr = &value;
        \\const foo = value_ptr.<cursor>;
    , &.{
        .{ .label = "*", .kind = .Operator, .detail = "u32" },
    });
    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\const value: S = undefined;
        \\const value_ptr = &value;
        \\const foo = value_ptr.<cursor>;
    , &.{
        .{ .label = "*", .kind = .Operator, .detail = "S" },
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
}

test "pointer type" {
    try testCompletion(
        \\const foo = *u32;
        \\const bar = foo.<cursor>
    , &.{});
    try testCompletion(
        \\const foo = [*]u32;
        \\const bar = foo.<cursor>
    , &.{});
    try testCompletion(
        \\const foo = []u32;
        \\const bar = foo.<cursor>
    , &.{});
    try testCompletion(
        \\const foo = [*c]u32;
        \\const bar = foo.<cursor>
    , &.{});
}

test "array" {
    try testCompletion(
        \\const foo: [3]u32 = undefined;
        \\const bar = foo.<cursor>
    , &.{
        .{ .label = "len", .kind = .Field, .detail = "usize = 3" },
    });
    try testCompletion(
        \\const length = 3;
        \\const foo: [length]u32 = undefined;
        \\const bar = foo.<cursor>
    , &.{
        .{ .label = "len", .kind = .Field, .detail = "usize = 3" },
    });
    try testCompletion(
        \\const S = struct {
        \\    alpha: u32,
        \\};
        \\const foo: [1]S = undefined;
        \\const bar = foo[0].<cursor>
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
    try testCompletion(
        \\const foo: [3]u32 = undefined;
        \\var index: usize = undefined;
        \\const bar = foo[0..index].<cursor>
    , &.{
        .{ .label = "len", .kind = .Field, .detail = "usize" },
        .{ .label = "ptr", .kind = .Field, .detail = "[*]u32" },
    });
}

test "single pointer to slice" {
    try testCompletion(
        \\const foo: *[]u32 = undefined;
        \\const bar = foo.<cursor>
    , &.{
        .{ .label = "*", .kind = .Operator, .detail = "[]u32" },
        .{ .label = "len", .kind = .Field, .detail = "usize" },
        .{ .label = "ptr", .kind = .Field, .detail = "[*]u32" },
    });
}

test "single pointer to array" {
    try testCompletion(
        \\const foo: *[3]u32 = undefined;
        \\const bar = foo.<cursor>
    , &.{
        .{ .label = "*", .kind = .Operator, .detail = "[3]u32" },
        .{ .label = "len", .kind = .Field, .detail = "usize = 3" },
    });
    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\const foo: *[2]S = undefined;
        \\const bar = foo[0].<cursor>
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
    try testCompletion(
        \\const foo: *[3]u32 = undefined;
        \\const bar = foo[0..3].<cursor>
    , &.{
        .{ .label = "len", .kind = .Field, .detail = "usize" },
        .{ .label = "ptr", .kind = .Field, .detail = "[*]u32" },
    });
}

test "array type" {
    try testCompletion(
        \\const foo = [3]u32;
        \\const bar = foo.<cursor>
    , &.{});
}

test "tuple fields" {
    try testCompletion(
        \\fn foo() void {
        \\    var a: f32 = 0;
        \\    var b: i64 = 1;
        \\    const foo = .{ b, a };
        \\    const bar = foo.<cursor>
        \\}
    , &.{
        .{ .label = "@\"0\"", .kind = .Field, .detail = "i64" },
        .{ .label = "@\"1\"", .kind = .Field, .detail = "f32" },
    });
    try testCompletion(
        \\fn foo() void {
        \\    const foo: struct { i64, f32 } = .{ 1, 0 };
        \\    const bar = foo.<cursor>
        \\}
    , &.{
        .{ .label = "@\"0\"", .kind = .Field, .detail = "i64" },
        .{ .label = "@\"1\"", .kind = .Field, .detail = "f32" },
    });
}

test "if/for/while/catch scopes" {
    try testCompletion(
        \\const S = struct { pub const T = u32; };
        \\test {
        \\    if (true) {
        \\        S.<cursor>
        \\    }
        \\}
    , &.{
        .{ .label = "T", .kind = .Constant, .detail = "u32" },
    });
    try testCompletion(
        \\const S = struct { pub const T = u32; };
        \\test {
        \\    if (true) S.<cursor>
        \\}
    , &.{
        .{ .label = "T", .kind = .Constant, .detail = "u32" },
    });
    try testCompletion(
        \\const S = struct { pub const T = u32; };
        \\test {
        \\    if (true) {
        \\    } else {
        \\        S.<cursor>
        \\    }
        \\}
    , &.{
        .{ .label = "T", .kind = .Constant, .detail = "u32" },
    });
    try testCompletion(
        \\const S = struct { pub const T = u32; };
        \\test {
        \\    for (undefined) |_| {
        \\        S.<cursor>
        \\    }
        \\}
    , &.{
        .{ .label = "T", .kind = .Constant, .detail = "u32" },
    });
    try testCompletion(
        \\const S = struct { pub const T = u32; };
        \\test {
        \\    for (undefined) |_| {
        \\
        \\    } else {
        \\        S.<cursor>
        \\    }
        \\}
    , &.{
        .{ .label = "T", .kind = .Constant, .detail = "u32" },
    });
    try testCompletion(
        \\const S = struct { pub const T = u32; };
        \\test {
        \\    while (true) {
        \\        S.<cursor>
        \\    }
        \\}
    , &.{
        .{ .label = "T", .kind = .Constant, .detail = "u32" },
    });
    try testCompletion(
        \\const S = struct { pub const T = u32; };
        \\test {
        \\    for (undefined) {
        \\
        \\    } else {
        \\        S.<cursor>
        \\    }
        \\}
    , &.{
        .{ .label = "T", .kind = .Constant, .detail = "u32" },
    });
    try testCompletion(
        \\const S = struct { pub const T = u32; };
        \\test {
        \\    error.Foo catch {
        \\        S.<cursor>
        \\    }
        \\}
    , &.{
        .{ .label = "T", .kind = .Constant, .detail = "u32" },
    });
}

test "if captures" {
    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\fn foo(bar: ?S) void {
        \\    if(bar) |baz| {
        \\        baz.<cursor>
        \\    }
        \\}
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\fn foo(maybe_maybe_s: ??S) void {
        \\    if (maybe_maybe_s) |maybe_s| if (maybe_s) |s| {
        \\        s.<cursor>
        \\    };
        \\}
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });

    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\fn foo(bar: ?S) void {
        \\    if (bar) |baz| {
        \\        baz.<cursor>
        \\    } else {
        \\        return;
        \\    }
        \\}
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });

    // TODO fix value capture without block scope
    // try testCompletion(
    //     \\const S = struct { alpha: u32 };
    //     \\const foo: ?S = undefined;
    //     \\const bar = if(foo) |baz| baz.<cursor>
    // , &.{
    //     .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    // });

    try testCompletion(
        \\const E = error{ X, Y };
        \\const S = struct { alpha: u32 };
        \\fn foo() E!S { return undefined; }
        \\fn bar() void {
        \\    if (foo()) |baz| {
        \\        baz.<cursor>
        \\    } else |err| {
        \\        _ = err;
        \\    }
        \\}
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
}

test "if capture by ref" {
    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\fn foo(bar: ?S) void {
        \\    if (bar) |*baz| {
        \\        baz.<cursor>
        \\    }
        \\}
    , &.{
        .{ .label = "*", .kind = .Operator, .detail = "S" },
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
}

test "for captures" {
    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\fn foo(items: []S) void {
        \\    for (items, 0..) |bar, i| {
        \\        bar.<cursor>
        \\    }
        \\}
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });

    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\fn foo(items: [2]S) void {
        \\    for (items) |bar| {
        \\        bar.<cursor>
        \\    }
        \\}
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });

    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\fn foo(items: []S) void {
        \\    for (items, items) |_, baz| {
        \\        baz.<cursor>
        \\    }
        \\}
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });

    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\fn foo() void {
        \\    const manyptr: [*]S = undefined;
        \\    for (manyptr[0..10]) |s| {
        \\        s.<cursor>
        \\    }
        \\}
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });

    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\fn foo() void {
        \\    const optmanyptr: ?[*]S = undefined;
        \\    for (optmanyptr.?[0..10]) |s| {
        \\        s.<cursor>
        \\    }
        \\}
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
}

test "for capture by ref" {
    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\fn foo(items: []S) void {
        \\    for (items, 0..) |*bar, i| {
        \\        bar.<cursor>
        \\    }
        \\}
    , &.{
        .{ .label = "*", .kind = .Operator, .detail = "S" },
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
}

test "while captures" {
    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\fn foo(bar: ?S) void {
        \\    while (bar) |baz| {
        \\        baz.<cursor>
        \\    }
        \\}
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
    try testCompletion(
        \\const E = error{ X, Y };
        \\const S = struct { alpha: u32 };
        \\fn foo() E!S { return undefined; }
        \\fn bar() void {
        \\    while (foo()) |baz| {
        \\        baz.<cursor>
        \\    } else |err| {
        \\        _ = err;
        \\    }
        \\}
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
}

test "while capture by ref" {
    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\fn foo(bar: ?S) void {
        \\    while (bar) |*baz| {
        \\        baz.<cursor>
        \\    }
        \\}
    , &.{
        .{ .label = "*", .kind = .Operator, .detail = "S" },
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
}

test "catch captures" {
    try testCompletion(
        \\const E = error{ X, Y };
        \\const S = struct { alpha: u32 };
        \\fn foo() E!S { return undefined; }
        \\fn bar() void {
        \\    const baz = foo() catch |err| {
        \\        _ = err;
        \\        return;
        \\    };
        \\    baz.<cursor>
        \\}
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
}

test "switch capture by ref" {
    try testCompletion(
        \\const U = union { alpha: ?u32 };
        \\fn foo(bar: U) void {
        \\    switch (bar) {
        \\        .alpha => |*a| {
        \\            a.<cursor>
        \\        }
        \\    }
        \\}
    , &.{
        .{ .label = "*", .kind = .Operator, .detail = "?u32" },
        .{ .label = "?", .kind = .Operator, .detail = "u32" },
    });
}

test "namespace" {
    try testCompletion(
        \\const namespace = struct {};
        \\const bar = namespace.<cursor>
    , &.{});
    try testCompletion(
        \\const namespace = struct {
        \\    fn alpha() void {}
        \\    fn beta(_: anytype) void {}
        \\    fn gamma(_: @This()) void {}
        \\};
        \\const bar = namespace.<cursor>
    , &.{
        .{ .label = "alpha", .kind = .Function, .detail = "fn () void" },
        .{ .label = "beta", .kind = .Function, .detail = "fn (_: anytype) void" },
        .{ .label = "gamma", .kind = .Function, .detail = "fn (_: namespace) void" },
    });
    try testCompletion(
        \\const namespace = struct {
        \\    fn alpha() void {}
        \\    fn beta(_: anytype) void {}
        \\    fn gamma(_: @This()) void {}
        \\};
        \\const instance: namespace = undefined;
        \\const bar = instance.<cursor>
    , &.{
        .{ .label = "beta", .kind = .Function, .detail = "fn (_: anytype) void" },
        .{ .label = "gamma", .kind = .Function, .detail = "fn (_: namespace) void" },
    });
    try testCompletion(
        \\fn alpha() void {}
        \\fn beta(_: anytype) void {}
        \\fn gamma(_: @This()) void {}
        \\
        \\const foo: @This() = undefined;
        \\const bar = foo.<cursor>;
    , &.{
        .{ .label = "beta", .kind = .Function, .detail = "fn (_: anytype) void" },
        .{ .label = "gamma", .kind = .Function, .detail = "fn (_: Untitled-0) void" },
    });
}

test "struct" {
    try testCompletion(
        \\const S = struct {
        \\    alpha: u32,
        \\    beta: []const u8,
        \\};
        \\const foo: S = undefined;
        \\const bar = foo.<cursor>
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
        .{ .label = "beta", .kind = .Field, .detail = "[]const u8" },
    });

    try testCompletion(
        \\const S = struct {
        \\    alpha: u32,
        \\    beta: []const u8,
        \\};
        \\const foo = S{ .alpha = 0, .beta = "" };
        \\const bar = foo.<cursor>
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
        .{ .label = "beta", .kind = .Field, .detail = "[]const u8" },
    });

    try testCompletion(
        \\const Foo = struct {
        \\    alpha: u32,
        \\    fn add(foo: Foo) Foo {}
        \\};
        \\test {
        \\    var builder = Foo{};
        \\    builder
        \\        // Comments should
        \\        // get ignored
        \\        .<cursor>
        \\}
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
        .{ .label = "add", .kind = .Method, .detail = "fn (foo: Foo) Foo" },
    });

    try testCompletion(
        \\fn doNothingWithInteger(a: u32) void { _ = a; }
        \\const S = struct {
        \\    alpha: u32,
        \\    beta: []const u8,
        \\    fn foo(self: S) void {
        \\        doNothingWithInteger(self.<cursor>
        \\    }
        \\};
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
        .{ .label = "beta", .kind = .Field, .detail = "[]const u8" },
        .{ .label = "foo", .kind = .Method, .detail = "fn (self: S) void" },
    });

    try testCompletion(
        \\const S = struct {
        \\    const Mode = enum { alpha, beta, };
        \\    fn foo(mode: <cursor>
        \\};
    , &.{
        .{ .label = "S", .kind = .Struct, .detail = "type" },
        .{ .label = "Mode", .kind = .Enum, .detail = "type" },
    });

    try testCompletion(
        \\fn fooImpl(_: Foo) void {}
        \\fn barImpl(_: *const Foo) void {}
        \\fn bazImpl(_: u32) void {}
        \\const Foo = struct {
        \\    alpha: u32,
        \\    pub const foo = fooImpl;
        \\    pub const bar = barImpl;
        \\    pub const baz = bazImpl;
        \\};
        \\const foo = Foo{};
        \\const baz = foo.<cursor>;
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
        .{ .label = "foo", .kind = .Method, .detail = "fn (_: Foo) void" },
        .{ .label = "bar", .kind = .Method, .detail = "fn (_: *const Foo) void" },
    });
    try testCompletion(
        \\alpha: u32,
        \\
        \\fn alpha() void {}
        \\fn beta(_: anytype) void {}
        \\fn gamma(_: @This()) void {}
        \\
        \\const Self = @This();
        \\const bar = Self.<cursor>;
    , &.{
        .{ .label = "alpha", .kind = .Function, .detail = "fn () void" },
        .{ .label = "beta", .kind = .Function, .detail = "fn (_: anytype) void" },
        .{ .label = "gamma", .kind = .Function, .detail = "fn (_: Untitled-0) void" },
        .{ .label = "Self", .kind = .Struct },
        .{ .label = "bar", .kind = .Struct },
    });

    try testCompletion(
        \\const S = struct {
        \\    alpha: u32,
        \\    beta: []const u8,
        \\};
        \\const foo = (S{}).<cursor>;
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
        .{ .label = "beta", .kind = .Field, .detail = "[]const u8" },
    });
}

test "union" {
    try testCompletion(
        \\const U = union {
        \\    alpha: u32,
        \\    beta: []const u8,
        \\};
        \\const foo: U = undefined;
        \\const bar = foo.<cursor>
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
        .{ .label = "beta", .kind = .Field, .detail = "[]const u8" },
    });

    try testCompletion(
        \\const U = union { alpha: ?u32 };
        \\fn foo(bar: U) void {
        \\    switch (bar) {
        \\        .alpha => |a| {
        \\            a.<cursor>
        \\        }
        \\    }
        \\}
    , &.{
        .{ .label = "?", .kind = .Operator, .detail = "u32" },
    });
}

test "enum" {
    try testCompletion(
        \\const E = enum {
        \\    alpha,
        \\    beta,
        \\};
        \\const foo = E.<cursor>
    , &.{
        .{ .label = "alpha", .kind = .EnumMember },
        .{ .label = "beta", .kind = .EnumMember },
    });
    try testCompletion(
        \\const E = enum(u8) {
        \\    alpha,
        \\    beta = 42,
        \\    const bar = 5;
        \\};
        \\const foo: E = .<cursor>
    , &.{
        .{ .label = "alpha", .kind = .EnumMember, .detail = "E" },
        .{ .label = "beta", .kind = .EnumMember, .detail = "E = 42" },
    });
    try testCompletion(
        \\const E = enum {
        \\    _,
        \\    const bar = 5;
        \\    fn inner(_: E) void {}
        \\};
        \\const foo = E.<cursor>
    , &.{
        .{ .label = "bar", .kind = .Constant, .detail = "comptime_int" },
        .{ .label = "inner", .kind = .Function, .detail = "fn (_: E) void" },
    });
    try testCompletion(
        \\const E = enum {
        \\    _,
        \\    const bar = 5;
        \\    fn inner(_: E) void {}
        \\};
        \\const e: E = undefined;
        \\const foo = e.<cursor>
    , &.{
        .{ .label = "inner", .kind = .Method, .detail = "fn (_: E) void" },
    });
    // Because current logic is to list all enums if all else fails,
    // the following tests include an extra enum to ensure that we're not just 'getting lucky'
    try testCompletion(
        \\const Birdie = enum {
        \\    canary,
        \\};
        \\const SomeEnum = enum {
        \\    sef1,
        \\    sef2,
        \\};
        \\fn retEnum(se: SomeEnum) void {
        \\    if (se == .<cursor>) {}
        \\}
    , &.{
        .{ .label = "sef1", .kind = .EnumMember },
        .{ .label = "sef2", .kind = .EnumMember },
    });
    try testCompletion(
        \\const Birdie = enum {
        \\    canary,
        \\};
        \\const SomeEnum = enum {
        \\    sef1,
        \\    sef2,
        \\};
        \\fn retEnum() SomeEnum {}
        \\test {
        \\    retEnum() == .<cursor>
        \\}
    , &.{
        .{ .label = "sef1", .kind = .EnumMember },
        .{ .label = "sef2", .kind = .EnumMember },
    });
    try testCompletion(
        \\const Birdie = enum {
        \\    canary,
        \\};
        \\const SomeEnum = enum {
        \\    sef1,
        \\    sef2,
        \\};
        \\const S = struct {
        \\    pub fn retEnum() SomeEnum {}
        \\};
        \\test {
        \\    S.retEnum() == .<cursor>
        \\}
    , &.{
        .{ .label = "sef1", .kind = .EnumMember },
        .{ .label = "sef2", .kind = .EnumMember },
    });
    try testCompletion(
        \\const Birdie = enum {
        \\    canary,
        \\};
        \\const SomeEnum = enum {
        \\    sef1,
        \\    sef2,
        \\};
        \\const S = struct {
        \\    pub fn retEnum(self: S) SomeEnum {}
        \\};
        \\test {
        \\    const s = S{};
        \\    s.retEnum() == .<cursor>
        \\}
    , &.{
        .{ .label = "sef1", .kind = .EnumMember },
        .{ .label = "sef2", .kind = .EnumMember },
    });
    try testCompletion(
        \\const Birdie = enum {
        \\    canary,
        \\};
        \\const SomeEnum = enum {
        \\    sef1,
        \\    sef2,
        \\};
        \\const S = struct {
        \\    se: SomeEnum = .sef1,
        \\};
        \\test {
        \\    const s = S{};
        \\    s.se == .<cursor>
        \\}
    , &.{
        .{ .label = "sef1", .kind = .EnumMember },
        .{ .label = "sef2", .kind = .EnumMember },
    });
    try testCompletion(
        \\const Birdie = enum {
        \\    canary,
        \\};
        \\const S = struct {
        \\    mye: enum {
        \\        myef1,
        \\        myef2,
        \\    };
        \\};
        \\test {
        \\    const s = S{};
        \\    s.mye == .<cursor>
        \\}
    , &.{
        .{ .label = "myef1", .kind = .EnumMember },
        .{ .label = "myef2", .kind = .EnumMember },
    });
    try testCompletion(
        \\const Birdie = enum {
        \\    canary,
        \\};
        \\const SomeEnum = enum {
        \\    sef1,
        \\    sef2,
        \\};
        \\const S = struct {
        \\    const Self = @This();
        \\    pub fn f(_: *Self, _: SomeEnum) void {}
        \\};
        \\test {
        \\    S.f(null, .<cursor>
        \\}
    , &.{
        .{ .label = "sef1", .kind = .EnumMember },
        .{ .label = "sef2", .kind = .EnumMember },
    });
    try testCompletion(
        \\const Birdie = enum {
        \\    canary,
        \\};
        \\const SomeEnum = enum {
        \\    sef1,
        \\    sef2,
        \\};
        \\const S = struct {
        \\    alpha: u32,
        \\    const Self = @This();
        \\    pub fn f(_: *Self, _: SomeEnum) void {}
        \\};
        \\test {
        \\    const s = S{};
        \\    s.f(.<cursor>
        \\}
    , &.{
        .{ .label = "sef1", .kind = .EnumMember },
        .{ .label = "sef2", .kind = .EnumMember },
    });
    try testCompletion(
        \\const Birdie = enum {
        \\    canary,
        \\};
        \\const SomeEnum = enum {
        \\    sef1,
        \\    sef2,
        \\};
        \\const SCE = struct{
        \\    se: SomeEnum,
        \\};
        \\const S = struct {
        \\    alpha: u32,
        \\    const Self = @This();
        \\    pub fn f(_: *Self, _: SCE) void {}
        \\};
        \\test {
        \\    const s = S{};
        // XXX This doesn't work without the closing brace at the end
        \\    s.f(.{.se = .<cursor>}
        \\}
    , &.{
        .{ .label = "sef1", .kind = .EnumMember },
        .{ .label = "sef2", .kind = .EnumMember },
    });
    try testCompletion(
        \\const Birdie = enum {
        \\    canary,
        \\};
        \\const SomeEnum = enum {
        \\    sef1,
        \\    sef2,
        \\};
        \\const S = struct {
        \\    se: ?SomeEnum = null,
        \\};
        \\test {
        \\    const s = S{};
        \\    s.se = .<cursor>
        \\}
    , &.{
        .{ .label = "sef1", .kind = .EnumMember },
        .{ .label = "sef2", .kind = .EnumMember },
    });
}

test "enum - explicit and implicit ordinal values" {
    try testCompletionWithOptions(
        \\const E = enum(u8) {
        \\    alpha = 0,
        \\    beta,
        \\    gamma = 3,
        \\    delta,
        \\};
        \\const foo: E = .<cursor>
    , &.{
        .{ .label = "alpha", .kind = .EnumMember },
        .{ .label = "beta", .kind = .EnumMember },
        .{ .label = "delta", .kind = .EnumMember },
        .{ .label = "gamma", .kind = .EnumMember },
    }, .{
        .check_order = true,
    });
}

test "decl literal" {
    try testCompletion(
        \\const S = struct {
        \\    field: u32,
        \\
        \\    pub const foo: error{OutOfMemory}!S = .{};
        \\    const bar: *const S = &.{};
        \\    var baz: @This() = .{};
        \\    var qux: u32 = .{};
        \\
        \\    fn init() ?S {}
        \\    fn create() !*S {}
        \\    fn func() void {}
        \\};
        \\const s: S = .<cursor>;
    , &.{
        .{ .label = "field", .kind = .Field, .detail = "u32" },
        .{ .label = "foo", .kind = .Constant },
        .{ .label = "bar", .kind = .Constant },
        .{ .label = "baz", .kind = .Variable },
        .{ .label = "init", .kind = .Function, .detail = "fn () ?S" },
        .{ .label = "create", .kind = .Function, .detail = "fn () !*S" },
    });
}

test "decl literal function" {
    try testCompletion(
        \\const Inner = struct {
        \\    fn init() Inner {}
        \\};
        \\const Outer = struct {
        \\    inner: Inner,
        \\};
        \\const foo: Outer = .{
        \\    .inner = .in<cursor>it(),
        \\};
    , &.{
        .{ .label = "init", .kind = .Function, .detail = "fn () Inner" },
    });
    try testCompletion(
        \\fn Empty() type {
        \\    return struct {
        \\        fn init() @This() {}
        \\    };
        \\}
        \\const foo: Empty() = .in<cursor>it();
    , &.{
        .{ .label = "init", .kind = .Function, .detail = "fn () Empty()" },
    });
}

test "decl literal function call" {
    try testCompletion(
        \\const S = struct {
        \\    field: u32,
        \\
        \\    const default: S = .{};
        \\    fn init() S {}
        \\};
        \\fn foo(s: S) void {}
        \\fn bar() void {
        \\    foo(.<cursor>);
        \\}
    , &.{
        .{ .label = "field", .kind = .Field, .detail = "u32" },
        .{ .label = "default", .kind = .Constant },
        .{ .label = "init", .kind = .Function, .detail = "fn () S" },
    });
}

test "enum literal" {
    try testCompletion(
        \\const literal = .foo;
        \\const foo = <cursor>
    , &.{
        .{ .label = "literal", .kind = .EnumMember, .detail = "@EnumLiteral()" },
    });
}

test "tagged union" {
    try testCompletion(
        \\const Birdie = enum {
        \\    canary,
        \\};
        \\const Ue = union(enum) {
        \\    alpha,
        \\    beta: []const u8,
        \\};
        \\const S = struct{ foo: Ue };
        \\test {
        \\    const s = S{};
        \\    s.foo = .<cursor>
        \\}
    , &.{
        .{ .label = "alpha", .kind = .EnumMember },
        .{ .label = "beta", .kind = .Field },
    });
}

test "switch cases" {
    // Because current logic is to list all enums if all else fails,
    // the following tests include an extra enum to ensure that we're not just 'getting lucky'
    try testCompletion(
        \\const Birdie = enum {
        \\    canary,
        \\};
        \\const SomeEnum = enum {
        \\    sef1,
        \\    sef2,
        \\};
        \\fn retEnum() SomeEnum {}
        \\test {
        \\    switch(retEnum()) {.<cursor>}
        \\}
    , &.{
        .{ .label = "sef1", .kind = .EnumMember },
        .{ .label = "sef2", .kind = .EnumMember },
    });
    try testCompletion(
        \\const Birdie = enum {
        \\    canary,
        \\};
        \\const SomeEnum = enum {
        \\    sef1,
        \\    sef2,
        \\};
        \\fn retEnum(se: SomeEnum) void {
        \\    switch(se) {.<cursor>}
        \\}
    , &.{
        .{ .label = "sef1", .kind = .EnumMember },
        .{ .label = "sef2", .kind = .EnumMember },
    });

    try testCompletion(
        \\const Birdie = enum {
        \\    canary,
        \\};
        \\const SomeEnum = enum {
        \\    sef1,
        \\    sef2,
        \\    sef3,
        \\    sef4,
        \\};
        \\fn retEnum(se: SomeEnum) void {
        \\    switch(se) {
        \\       .sef1 => {},
        \\       .sef4 => {},
        \\       .<cursor>
        \\    }
        \\}
    , &.{
        .{ .label = "sef2", .kind = .EnumMember },
        .{ .label = "sef3", .kind = .EnumMember },
    });

    try testCompletion(
        \\const Birdie = enum {
        \\    canary,
        \\};
        \\const SomeEnum = enum {
        \\    sef1,
        \\    sef2,
        \\    sef3,
        \\    sef4,
        \\};
        \\fn retEnum(se: SomeEnum) void {
        \\    switch(se) {
        \\       .sef1, .sef4 => {},
        \\       .<cursor>
        \\       .sef3 => {},
        \\    }
        \\}
    , &.{
        .{ .label = "sef2", .kind = .EnumMember },
    });
    try testCompletion(
        \\const Birdie = enum {
        \\    canary,
        \\};
        \\const SomeEnum = enum {
        \\    sef1,
        \\    sef2,
        \\};
        \\fn retEnum() SomeEnum {}
        \\test {
        \\    var se = retEnum();
        \\    switch(se) {.<cursor>}
        \\}
    , &.{
        .{ .label = "sef1", .kind = .EnumMember },
        .{ .label = "sef2", .kind = .EnumMember },
    });
    try testCompletion(
        \\const Birdie = enum {
        \\    canary,
        \\};
        \\const SomeEnum = enum {
        \\    sef1,
        \\    sef2,
        \\};
        \\const S = struct {
        \\    pub fn retEnum() SomeEnum {}
        \\};
        \\test {
        \\    switch(S.retEnum()) {.<cursor>}
        \\}
    , &.{
        .{ .label = "sef1", .kind = .EnumMember },
        .{ .label = "sef2", .kind = .EnumMember },
    });
    try testCompletion(
        \\const Birdie = enum {
        \\    canary,
        \\};
        \\const SomeEnum = enum {
        \\    sef1,
        \\    sef2,
        \\};
        \\const S = struct {
        \\    pub fn retEnum(self: S) SomeEnum {}
        \\};
        \\test {
        \\    const s = S{};
        \\    switch(s.retEnum()) {.<cursor>}
        \\}
    , &.{
        .{ .label = "sef1", .kind = .EnumMember },
        .{ .label = "sef2", .kind = .EnumMember },
    });
    try testCompletion(
        \\const Birdie = enum {
        \\    canary,
        \\};
        \\const SomeEnum = enum {
        \\    sef1,
        \\    sef2,
        \\};
        \\fn retEnum() anyerror!SomeEnum {}
        \\test {
        \\    switch (try retEnum()) {.<cursor>}
        \\}
    , &.{
        .{ .label = "sef1", .kind = .EnumMember },
        .{ .label = "sef2", .kind = .EnumMember },
    });
    try testCompletion(
        \\const Birdie = enum {
        \\    canary,
        \\};
        \\const SomeEnum = enum {
        \\    sef1,
        \\    sef2,
        \\    pub fn retEnum() anyerror!SomeEnum {}
        \\};
        \\test {
        \\    switch (try SomeEnum.retEnum()) {.<cursor>}
        \\}
    , &.{
        .{ .label = "sef1", .kind = .EnumMember },
        .{ .label = "sef2", .kind = .EnumMember },
    });
    try testCompletion(
        \\const Birdie = enum {
        \\    canary,
        \\};
        \\const SomeEnum = enum {
        \\    sef1,
        \\    sef2,
        \\};
        \\fn retEnum() SomeEnum {}
        \\test {
        \\    switch(retEnum()) {
        \\        .sef1 => {const a = 1;},
        \\        .<cursor>
        \\    }
        \\}
    , &.{
        .{ .label = "sef2", .kind = .EnumMember },
    });
}

test "switch on error set - all values are suggested" {
    try testCompletion(
        \\const err: error{E1, E2} = undefined;
        \\switch(err) {
        \\    error.<cursor>
        \\}
    , &.{
        .{ .label = "error.E1", .kind = .Constant },
        .{ .label = "error.E2", .kind = .Constant },
    });
}

test "switch on error set - already used values are not suggested" {
    try testCompletion(
        \\const err: error{E1, E2} = undefined;
        \\switch(err) {
        \\    error.E1 => {},
        \\    error.<cursor>
        \\}
    , &.{
        .{ .label = "error.E2", .kind = .Constant },
    });
}

test "switch on error set - error unions get all values" {
    try testCompletion(
        \\const Err2 = error{F1, F2};
        \\const Err = error{E1, E2} || Err2;
        \\const err: Err = undefined;
        \\switch(err) {
        \\    error.<cursor>
        \\}
    , &.{
        .{ .label = "error.E1", .kind = .Constant },
        .{ .label = "error.E2", .kind = .Constant },
        .{ .label = "error.F1", .kind = .Constant },
        .{ .label = "error.F2", .kind = .Constant },
    });
}

test "switch on error set - text edits result" {
    try testCompletionTextEdit(.{
        .source =
        \\const err: error{E1, E2} = undefined;
        \\switch(err) {
        \\    error.<cursor>
        \\}
        ,
        .label = "error.E1",
        .expected_insert_line = "    error.E1",
        .expected_replace_line = "    error.E1",
        .enable_snippets = false,
    });
}
test "switch on error set - insert/replace text edits" {
    try testCompletionTextEdit(.{
        .source =
        \\const err: error{Err1, Err2} = undefined;
        \\switch(err) {
        \\    error.E<cursor>0
        \\}
        ,
        .label = "error.Err1",
        .expected_insert_line = "    error.Err10",
        .expected_replace_line = "    error.Err1",
        .enable_snippets = false,
    });
}

test "switch on error set - completion inside catch block works" {
    try testCompletion(
        \\fn idk() error{ E1, E2 }!void {}
        \\test {
        \\  idk() catch |err| {
        \\      switch (err) {
        \\          error.<cursor>
        \\      }
        \\  };
        \\}
    , &.{
        .{ .label = "error.E1", .kind = .Constant },
        .{ .label = "error.E2", .kind = .Constant },
    });
}

test "switch on error set - completion inside catch statement" {
    if (true) return error.SkipZigTest; // TODO un-skip after https://github.com/zigtools/zls/issues/2341 and/or https://github.com/zigtools/zls/issues/1112
    try testCompletion(
        \\fn idk() error{ E1, E2 }!void {}
        \\test {
        \\  idk() catch |err| switch (err) {
        \\      error.<cursor>
        \\  };
        \\}
    , &.{
        .{ .label = "error.E1", .kind = .Constant },
        .{ .label = "error.E2", .kind = .Constant },
    });
}

test "switch on error set - Works in a function of a container" {
    if (true) return error.SkipZigTest; // TODO un-skip after https://github.com/zigtools/zls/issues/1535
    try testCompletion(
        \\fn idk() error{ E1, E2 }!void {}
        \\pub const Manager = struct {
        \\    pub fn testIt() void {
        \\        _ = idk() catch |err| {
        \\            switch(err) {
        \\                error.<cursor>
        \\            }
        \\        };
        \\    }
        \\};
    , &.{
        .{ .label = "error.E1", .kind = .Constant },
        .{ .label = "error.E2", .kind = .Constant },
    });
}

test "error set" {
    try testCompletion(
        \\const E = error {
        \\    foo,
        \\    bar,
        \\};
        \\const baz = E.<cursor>
    , &.{
        .{ .label = "foo", .kind = .Constant, .detail = "error.foo" },
        .{ .label = "bar", .kind = .Constant, .detail = "error.bar" },
    });
    try testCompletion(
        \\const E1 = error {
        \\    foo,
        \\    bar,
        \\};
        \\const E2 = error {
        \\    baz,
        \\    ///hello
        \\    qux,
        \\};
        \\const baz = E2.<cursor>
    , &.{
        .{ .label = "baz", .kind = .Constant, .detail = "error.baz" },
        .{ .label = "qux", .kind = .Constant, .detail = "error.qux" },
    });
}

test "merged error sets" {
    try testCompletion(
        \\const FirstSet = error{
        \\    x,
        \\    y,
        \\};
        \\const SecondSet = error{
        \\    foo,
        \\    bar,
        \\} || FirstSet;
        \\const e = SecondSet.<cursor>
    , &.{
        .{ .label = "x", .kind = .Constant, .detail = "error.x" },
        .{ .label = "y", .kind = .Constant, .detail = "error.y" },
        .{ .label = "foo", .kind = .Constant, .detail = "error.foo" },
        .{ .label = "bar", .kind = .Constant, .detail = "error.bar" },
    });

    try testCompletion(
        \\const Error = error{Foo} || error{Bar};
        \\const E = <cursor>
    , &.{
        .{ .label = "Error", .kind = .Constant, .detail = "error{Bar,Foo}" },
    });
}

test "error union" {
    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\fn foo() error{Foo}!S {}
        \\fn bar() error{Foo}!void {
        \\    const baz = try foo();
        \\    baz.<cursor>
        \\}
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });

    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\fn foo() !S {}
        \\fn bar() !void {
        \\    const baz = try foo();
        \\    baz.<cursor>
        \\}
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });

    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\fn foo() error{Foo}!S {}
        \\fn bar() error{Foo}!void {
        \\    (try foo()).<cursor>
        \\}
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });

    try testCompletion(
        \\const S1 = struct { alpha: u32 };
        \\const S2 = struct {
        \\    pub fn baz(_: S2) !S1 {}
        \\};
        \\fn foo() error{Foo}!S2 {}
        \\fn bar() error{Foo}!void {
        \\    (try (try foo()).baz()).<cursor>;
        \\}
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });

    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\fn foo() error{Foo}!S {}
        \\fn bar() error{Foo}!void {
        \\    const baz = foo() catch return;
        \\    baz.<cursor>
        \\}
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
}

test "structinit" {
    try testCompletion(
        \\const S = struct {
        \\    alpha: u32,
        \\    beta: []const u8,
        \\};
        \\const foo = S{ .<cursor> };
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
        .{ .label = "beta", .kind = .Field, .detail = "[]const u8" },
    });
    try testCompletion(
        \\const S = struct {
        \\    alpha: u32,
        \\    beta: []const u8,
        \\    gamma: ?*S,
        \\};
        \\const foo = S{ .alpha = 3, .<cursor>, .gamma = null };
    , &.{
        .{ .label = "beta", .kind = .Field, .detail = "[]const u8" },
    });
    try testCompletion(
        \\const S = struct {
        \\    alpha: *const S,
        \\    beta: []const u8,
        \\};
        \\const foo = S{ .alpha = S{ .beta = "{}" }, .<cursor> };
    , &.{
        .{ .label = "beta", .kind = .Field, .detail = "[]const u8" },
    });
    try testCompletion(
        \\const S = struct {
        \\    alpha: *const S,
        \\    beta: u32,
        \\};
        \\const foo = S{ .alpha = S{ .<cursor> } };
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "*const S" },
        .{ .label = "beta", .kind = .Field, .detail = "u32" },
    });
    // Incomplete struct field
    try testCompletion(
        \\const S = struct {
        \\    alpha: *const S,
        \\    beta: u32,
        \\};
        \\const foo = S{ .alpha = S{ .alp<cursor> } };
    , &.{
        // clients do the filtering
        .{ .label = "alpha", .kind = .Field, .detail = "*const S" },
        .{ .label = "beta", .kind = .Field, .detail = "u32" },
    });
    try testCompletion(
        \\const S = struct {
        \\    alpha: *const S,
        \\    beta: u32,
        \\    gamma: ?*S,
        \\};
        \\const foo = S{ .gamma = undefined, .<cursor> , .alpha = undefined };
    , &.{
        .{ .label = "beta", .kind = .Field, .detail = "u32" },
    });
    try testCompletion(
        \\const S = struct {
        \\    alpha: *const S,
        \\    beta: u32,
        \\    gamma: ?S,
        \\};
        \\const foo = S{ .gamma = .{.<cursor>};
    , &.{
        .{ .label = "gamma", .kind = .Field, .detail = "?S" },
        .{ .label = "beta", .kind = .Field, .detail = "u32" },
        .{ .label = "alpha", .kind = .Field, .detail = "*const S" },
    });
    try testCompletion(
        \\const S = struct {
        \\    alpha: *const S,
        \\    beta: u32,
        \\    gamma: ?S = null,
        \\};
        \\test {
        \\    const foo: S = undefined;
        \\    foo.gamma = .{.<cursor>}
        \\}
    , &.{
        .{ .label = "gamma", .kind = .Field, .detail = "?S = null" },
        .{ .label = "beta", .kind = .Field, .detail = "u32" },
        .{ .label = "alpha", .kind = .Field, .detail = "*const S" },
    });
    try testCompletion(
        \\const S = struct {
        \\    alpha: *const S,
        \\    beta: u32,
        \\    gamma: ?S = null,
        \\};
        \\test {
        \\    const foo: S = undefined;
        \\    foo.gamma = .<cursor>
        \\}
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "*const S" },
        .{ .label = "beta", .kind = .Field, .detail = "u32" },
        .{ .label = "gamma", .kind = .Field, .detail = "?S = null" },
    });
    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\fn foo(s: S) void {}
        \\test {
        \\    foo(.<cursor>)
        \\}
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\fn foo(s: *S) void { s = .{.<cursor>} }
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\fn foo(s: *S) void { s.* = .{.<cursor>} }
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\fn foo() S {}
        \\test { foo(){.<cursor>} }
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\fn foo() anyerror!S {}
        \\test { try foo(){.<cursor>} }
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\const nmspc = struct {
        \\    fn foo() anyerror!S {}
        \\};
        \\test { try nmspc.foo(){.<cursor>} }
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
    try testCompletion(
        \\const nmspc = struct {
        \\    fn foo() type {
        \\        return struct {
        \\            alpha: u32,
        \\        };
        \\    }
        \\};
        \\test { nmspc.foo(){.<cursor>} }
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
    // Aliases
    try testCompletion(
        \\pub const Outer = struct {
        \\    pub const Inner = struct {
        \\        isf1: bool = true,
        \\        isf2: bool = false,
        \\    };
        \\};
        \\const Alias0 = Outer.Inner;
        \\const Alias = Alias0;
        \\
        \\fn alias() void {
        \\    var s = Alias{.<cursor>};
        \\}
    , &.{
        .{ .label = "isf1", .kind = .Field, .detail = "bool = true" },
        .{ .label = "isf2", .kind = .Field, .detail = "bool = false" },
    });
    // Parser workaround for when used before defined
    try testCompletion(
        \\fn alias() void {
        \\    var s = Alias{1.<cursor>};
        \\}
        \\pub const Outer = struct {
        \\    pub const Inner = struct {
        \\        isf1: bool = true,
        \\        isf2: bool = false,
        \\    };
        \\};
        \\const Alias0 = Outer.Inner;
        \\const Alias = Alias0;
    , &.{
        .{ .label = "isf1", .kind = .Field, .detail = "bool = true" },
        .{ .label = "isf2", .kind = .Field, .detail = "bool = false" },
    });
    // Parser workaround for completing within Self
    try testCompletion(
        \\const MyStruct = struct {
        \\    a: bool,
        \\    b: bool,
        \\    fn inside() void {
        \\        var s = MyStruct{1.<cursor>};
        \\    }
        \\};
    , &.{
        .{ .label = "a", .kind = .Field, .detail = "bool" },
        .{ .label = "b", .kind = .Field, .detail = "bool" },
    });
    try testCompletion(
        \\fn ref(p0: A, p1: B) void {}
        \\const A = struct {
        \\    this_is_a: u32 = 9,
        \\    arefb: B = 8,
        \\};
        \\const B = struct {
        \\    brefa: A,
        \\    this_is_b: []const u8,
        \\};
        \\ref(.{ .arefb = .{ .brefa = .{.<cursor>} } });
    , &.{
        .{ .label = "arefb", .kind = .Field, .detail = "B = 8" },
        .{ .label = "this_is_a", .kind = .Field, .detail = "u32 = 9" },
    });
    try testCompletion(
        \\const MyEnum = enum {
        \\  ef1,
        \\  ef2,
        \\};
        \\const S1 = struct { s1f1: u8, s1f2: u32 = 1, ref3: S3 = undefined };
        \\const S2 = struct { s2f1: u8, s2f2: u32 = 1, ref1: S1, mye: MyEnum = .ef1};
        \\const S3 = struct {
        \\  s3f1: u8,
        \\  s3f2: u32 = 1,
        \\  ref2: S2,
        \\  pub fn s3(p0: S1, p1: S2) void {}
        \\};
        \\const refs = S3{ .ref2 = .{ .ref1 = .{ .ref3 = .{ .ref2 = .{ .ref1 = .{.<cursor>} } } } } };
    , &.{
        .{ .label = "s1f1", .kind = .Field, .detail = "u8" },
        .{ .label = "s1f2", .kind = .Field, .detail = "u32 = 1" },
        .{ .label = "ref3", .kind = .Field, .detail = "S3 = undefined" },
    });
    // Method of T requiring explicit self param
    try testCompletion(
        \\const MyEnum = enum {
        \\  ef1,
        \\  ef2,
        \\};
        \\const S1 = struct { s1f1: u8, s1f2: u32 = 1, ref3: S3 = undefined };
        \\const S2 = struct { s2f1: u8, s2f2: u32 = 1, ref1: S1, mye: MyEnum = .ef1};
        \\const S3 = struct {
        \\  s3f1: u8,
        \\  s3f2: u32 = 1,
        \\  ref2: S2,
        \\  const Self = @This();
        \\  pub fn s3(self: *Self, p0: S1, p1: S2) void {}
        \\};
        \\S3.s3(null, .{ .mye = .{} }, .{ .ref1 = .{ .ref3 = .{ .ref2 = .{ .ref1 = .{.<cursor>} } } } });
    , &.{
        .{ .label = "s1f1", .kind = .Field, .detail = "u8" },
        .{ .label = "s1f2", .kind = .Field, .detail = "u32 = 1" },
        .{ .label = "ref3", .kind = .Field, .detail = "S3 = undefined" },
    });
    // Instance of T w/ self param + multitype (`switch`)
    try testCompletion(
        \\const MyEnum = enum {
        \\  ef1,
        \\  ef2,
        \\};
        \\const es = switch (1) {
        \\    1 => S1,
        \\    2 => S2,
        \\    3 => S3,
        \\};
        \\const S1 = struct { s1f1: u8, s1f2: u32 = 1, ref3: S3 = undefined };
        \\const S2 = struct { s2f1: u8, s2f2: u32 = 1, ref1: S1, mye: MyEnum = .ef1};
        \\const S3 = struct {
        \\  s3f1: u8,
        \\  s3f2: u32 = 1,
        \\  ref2: S2,
        \\  const Self = @This();
        \\  pub fn s3(self: Self, p0: es, p1: S1) void {}
        \\};
        \\const iofs3 = S3{};
        \\iofs3.s3(.{.<cursor>});
    , &.{
        .{ .label = "s1f1", .kind = .Field, .detail = "u8" },
        .{ .label = "s1f2", .kind = .Field, .detail = "u32 = 1" },
        .{ .label = "ref3", .kind = .Field, .detail = "S3 = undefined" },
        .{ .label = "s2f1", .kind = .Field, .detail = "u8" },
        .{ .label = "s2f2", .kind = .Field, .detail = "u32 = 1" },
        .{ .label = "ref1", .kind = .Field, .detail = "S1" },
        .{ .label = "s3f1", .kind = .Field, .detail = "u8" },
        .{ .label = "s3f2", .kind = .Field, .detail = "u32 = 1" },
        .{ .label = "ref2", .kind = .Field, .detail = "S2" },
        .{ .label = "mye", .kind = .Field, .detail = "MyEnum = .ef1" },
    });
    try testCompletion(
        \\const MyEnum = enum {
        \\  ef1,
        \\  ef2,
        \\};
        \\const oes = struct {
        \\  const es = if (true) S1 else S2;
        \\};
        \\const S1 = struct { s1f1: u8, s1f2: u32 = 1, ref3: S3 = undefined };
        \\const S2 = struct { s2f1: u8, s2f2: u32 = 1, ref1: S1, mye: MyEnum = .ef1};
        \\const oesi: oes.es = .{ .<cursor>};
    , &.{
        .{ .label = "s1f1", .kind = .Field, .detail = "u8" },
        .{ .label = "s1f2", .kind = .Field, .detail = "u32 = 1" },
        .{ .label = "ref3", .kind = .Field, .detail = "S3 = undefined" },
        .{ .label = "s2f1", .kind = .Field, .detail = "u8" },
        .{ .label = "s2f2", .kind = .Field, .detail = "u32 = 1" },
        .{ .label = "ref1", .kind = .Field, .detail = "S1" },
        .{ .label = "mye", .kind = .Field, .detail = "MyEnum = .ef1" },
    });
}

test "structinit - fields with and without default value" {
    try testCompletionWithOptions(
        \\const S = struct {
        \\    alpha: u32 = 0,
        \\    beta: []const u8,
        \\    gamma: bool = false,
        \\    delta: f64,
        \\};
        \\const foo = S{ .<cursor> };
    , &.{
        .{ .label = "beta", .kind = .Field },
        .{ .label = "delta", .kind = .Field },
        .{ .label = "alpha", .kind = .Field },
        .{ .label = "gamma", .kind = .Field },
    }, .{
        .check_order = true,
    });
}

test "return - enum" {
    try testCompletion(
        \\const E = enum {
        \\    alpha,
        \\    beta,
        \\};
        \\fn foo() E {
        \\    return .<cursor>
        \\}
    , &.{
        .{ .label = "alpha", .kind = .EnumMember },
        .{ .label = "beta", .kind = .EnumMember },
    });
}

test "return - decl literal" {
    try testCompletion(
        \\const S = struct {
        \\    alpha: u32,
        \\    beta: []const u8,
        \\
        \\    const default: S = .{};
        \\    fn init() S {}
        \\};
        \\fn foo() S {
        \\    return .<cursor>;
        \\}
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
        .{ .label = "beta", .kind = .Field, .detail = "[]const u8" },
        .{ .label = "init", .kind = .Function, .detail = "fn () S" },
        .{ .label = "default", .kind = .Constant },
    });
}

test "return - generic decl literal" {
    try testCompletion(
        \\fn S(T: type) type {
        \\    return struct {
        \\        alpha: T,
        \\        beta: []const u8,
        \\
        \\        const default: @This() = .{};
        \\        fn init() @This() {}
        \\    };
        \\}
        \\fn foo() S(u8) {
        \\    return .<cursor>;
        \\}
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u8" },
        .{ .label = "beta", .kind = .Field, .detail = "[]const u8" },
        .{ .label = "init", .kind = .Function, .detail = "fn () S(u8)" },
        .{ .label = "default", .kind = .Constant, .detail = "S(u8)" },
    });
}

test "return - structinit" {
    try testCompletion(
        \\const S = struct {
        \\    alpha: u32,
        \\    beta: []const u8,
        \\};
        \\fn foo() S {
        \\    return .{ .<cursor> }
        \\}
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
        .{ .label = "beta", .kind = .Field, .detail = "[]const u8" },
    });
    try testCompletion(
        \\const S = struct {
        \\    alpha: *const S,
        \\    beta: u32,
        \\    gamma: ?S,
        \\};
        \\fn foo() S {
        \\    return .{ .gamma = .{ .<cursor> }
        \\}
    , &.{
        .{ .label = "gamma", .kind = .Field, .detail = "?S" },
        .{ .label = "beta", .kind = .Field, .detail = "u32" },
        .{ .label = "alpha", .kind = .Field, .detail = "*const S" },
    });
}

test "return - structinit decl literal" {
    try testCompletion(
        \\const S = struct {
        \\    alpha: *const S,
        \\    beta: u32,
        \\    gamma: ?S,
        \\
        \\    const default: S = .{};
        \\    fn init() S {}
        \\};
        \\fn foo() S {
        \\    return .{ .gamma = .<cursor> }
        \\}
    , &.{
        .{ .label = "gamma", .kind = .Field, .detail = "?S" },
        .{ .label = "beta", .kind = .Field, .detail = "u32" },
        .{ .label = "alpha", .kind = .Field, .detail = "*const S" },
        .{ .label = "init", .kind = .Function, .detail = "fn () S" },
        .{ .label = "default", .kind = .Constant },
    });
}

test "break - enum/decl literal" {
    try testCompletion(
        \\const E = enum {
        \\    alpha,
        \\    beta,
        \\
        \\    const default: E = .alpha;
        \\    fn init() E {}
        \\};
        \\const foo: E = while (true) {
        \\    break .<cursor>
        \\};
    , &.{
        .{ .label = "alpha", .kind = .EnumMember },
        .{ .label = "beta", .kind = .EnumMember },
        .{ .label = "init", .kind = .Function, .detail = "fn () E" },
        .{ .label = "default", .kind = .EnumMember },
    });
}

test "break - structinit" {
    try testCompletion(
        \\const S = struct {
        \\    alpha: u32,
        \\    beta: []const u8,
        \\};
        \\const foo: S = while (true) {
        \\    break .{ .<cursor> }
        \\};
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
        .{ .label = "beta", .kind = .Field, .detail = "[]const u8" },
    });
    try testCompletion(
        \\const S = struct {
        \\    alpha: *const S,
        \\    beta: u32,
        \\    gamma: ?S,
        \\};
        \\const foo: S = while (true) {
        \\    break .{ .gamma = .{ .<cursor> }
        \\};
    , &.{
        .{ .label = "gamma", .kind = .Field, .detail = "?S" },
        .{ .label = "beta", .kind = .Field, .detail = "u32" },
        .{ .label = "alpha", .kind = .Field, .detail = "*const S" },
    });
}

test "break with label - enum/decl literal" {
    try testCompletion(
        \\const E = enum {
        \\    alpha,
        \\    beta,
        \\
        \\    const default: E = .alpha;
        \\    fn init() E {}
        \\};
        \\const foo: E = blk: {
        \\    break :blk .<cursor>
        \\};
    , &.{
        .{ .label = "alpha", .kind = .EnumMember },
        .{ .label = "beta", .kind = .EnumMember },
        .{ .label = "init", .kind = .Function, .detail = "fn () E" },
        .{ .label = "default", .kind = .EnumMember },
    });
}

test "break with label - structinit" {
    try testCompletion(
        \\const S = struct {
        \\    alpha: u32,
        \\    beta: []const u8,
        \\};
        \\const foo: S = blk: {
        \\    break :blk .{ .<cursor> }
        \\};
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
        .{ .label = "beta", .kind = .Field, .detail = "[]const u8" },
    });
    try testCompletion(
        \\const S = struct {
        \\    alpha: *const S,
        \\    beta: u32,
        \\    gamma: ?S,
        \\};
        \\const foo: S = blk: {
        \\    break :blk .{ .gamma = .{ .<cursor> }
        \\};
    , &.{
        .{ .label = "gamma", .kind = .Field, .detail = "?S" },
        .{ .label = "beta", .kind = .Field, .detail = "u32" },
        .{ .label = "alpha", .kind = .Field, .detail = "*const S" },
    });
}

test "continue with label - enum/decl literal" {
    try testCompletion(
        \\const E = enum {
        \\    alpha,
        \\    beta,
        \\
        \\    const default: E = .alpha;
        \\    fn init() E {}
        \\};
        \\const foo: E = .alpha;
        \\const bar = blk: switch (foo) {
        \\    .alpha => continue :blk .<cursor>,
        \\};
    , &.{
        // TODO this should have the following completion items
        // .{ .label = "alpha", .kind = .EnumMember },
        // .{ .label = "beta", .kind = .EnumMember },
        // .{ .label = "init", .kind = .Function, .detail = "fn () E" },
        // .{ .label = "default", .kind = .EnumMember },
    });
    try testCompletion(
        \\const E = enum {
        \\    alpha,
        \\    beta,
        \\
        \\    const default: E = .alpha;
        \\    fn init() E {}
        \\};
        \\const foo: E = .alpha;
        \\const bar = blk: switch (foo) {
        \\    .alpha => {
        \\        continue :blk .<cursor>
        \\    },
        \\};
    , &.{
        .{ .label = "alpha", .kind = .EnumMember },
        .{ .label = "beta", .kind = .EnumMember },
        .{ .label = "init", .kind = .Function, .detail = "fn () E" },
        .{ .label = "default", .kind = .EnumMember },
    });
}

test "continue with label - structinit" {
    try testCompletion(
        \\const U = union(enum) {
        \\    alpha: u32,
        \\    beta: []const u8,
        \\};
        \\const foo: U = .{};
        \\const bar = blk: switch (foo) {
        \\    .alpha => continue :blk .{ .<cursor> }
        \\};
    , &.{
        // TODO this should have the following completion items
        // .{ .label = "alpha", .kind = .Field, .detail = "u32" },
        // .{ .label = "beta", .kind = .Field, .detail = "[]const u8" },
    });
    try testCompletion(
        \\const U = union(enum) {
        \\    alpha: u32,
        \\    beta: []const u8,
        \\};
        \\const foo: U = .{};
        \\const bar = blk: switch (foo) {
        \\    .alpha => {
        \\        continue :blk .{ .<cursor> }
        \\    },
        \\};
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
        .{ .label = "beta", .kind = .Field, .detail = "[]const u8" },
    });
    try testCompletion(
        \\const U = union(enum) {
        \\    alpha: *const U,
        \\    beta: u32,
        \\    gamma: ?U,
        \\};
        \\const foo: U = .{};
        \\const bar = blk: switch (foo) {
        \\    .alpha => continue :blk .{ .gamma = .{ .<cursor> }
        \\};
    , &.{
        // TODO this should have the following completion items
        // .{ .label = "gamma", .kind = .Field, .detail = "?U" },
        // .{ .label = "beta", .kind = .Field, .detail = "u32" },
        // .{ .label = "alpha", .kind = .Field, .detail = "*const U" },
    });
    try testCompletion(
        \\const U = union(enum) {
        \\    alpha: *const U,
        \\    beta: u32,
        \\    gamma: ?U,
        \\};
        \\const foo: U = .{};
        \\const bar = blk: switch (foo) {
        \\    .alpha => {
        \\        continue :blk .{ .gamma = .{ .<cursor> }
        \\    },
        \\};
    , &.{
        .{ .label = "gamma", .kind = .Field, .detail = "?U" },
        .{ .label = "beta", .kind = .Field, .detail = "u32" },
        .{ .label = "alpha", .kind = .Field, .detail = "*const U" },
    });
}

test "deprecated" {
    // removed symbols from the standard library are ofted marked with a compile error
    try testCompletion(
        \\const foo = @compileError("Deprecated; some message");
        \\const bar = <cursor>
    , &.{
        .{
            .label = "foo",
            .kind = .Constant,
            .documentation = "Deprecated; some message",
            .deprecated = true,
        },
    });
}

test "deprecated sorting" {
    try testCompletionWithOptions(
        \\pub const Test = struct {
        \\  pub const a = @compileError("Deprecated; some message");
        \\  pub const b = true;
        \\};
        \\const foo = Test.<cursor>
    , &.{
        .{
            .label = "b",
            .kind = .Constant,
            .deprecated = false,
        },
        .{
            .label = "a",
            .kind = .Constant,
            .documentation = "Deprecated; some message",
            .deprecated = true,
        },
    }, .{
        .check_order = true,
    });
}

test "declarations" {
    try testCompletion(
        \\const S = struct {
        \\    pub const Public = u32;
        \\    const Private = u32;
        \\};
        \\const foo = S.<cursor>
    , &.{
        .{ .label = "Public", .kind = .Constant, .detail = "u32" },
        .{ .label = "Private", .kind = .Constant, .detail = "u32" },
    });
    try testCompletion(
        \\const S: type = struct {
        \\    pub const Public = u32;
        \\    const Private: type = u32;
        \\};
        \\const foo = S.<cursor>
    , &.{
        .{ .label = "Public", .kind = .Constant, .detail = "u32" },
        .{ .label = "Private", .kind = .Constant, .detail = "u32" },
    });

    try testCompletion(
        \\const S = struct {
        \\    pub fn public(self: S) S {}
        \\    fn private(self: S) !void {}
        \\};
        \\const foo: S = undefined;
        \\const bar = foo.<cursor>
    , &.{
        .{ .label = "public", .kind = .Function, .detail = "fn (self: S) S" },
        .{ .label = "private", .kind = .Function, .detail = "fn (self: S) !void" },
    });
}

test "declarations - meta type" {
    try testCompletion(
        \\const S: type = struct {
        \\    pub fn public() S {}
        \\    fn private() !void {}
        \\};
        \\const foo = S.<cursor>
    , &.{
        .{ .label = "public", .kind = .Function, .detail = "fn () S" },
        .{ .label = "private", .kind = .Function, .detail = "fn () !void" },
    });
}

test "generic method - @This() parameter" {
    try testCompletion(
        \\fn Foo(T: type) type {
        \\    return struct {
        \\        field: T,
        \\        fn bar(self: @This()) void {
        \\            _ = self;
        \\        }
        \\    };
        \\}
        \\const foo: Foo(u8) = .{};
        \\const bar = foo.<cursor>
    , &.{
        .{ .label = "field", .kind = .Field, .detail = "u8" },
        .{ .label = "bar", .kind = .Method, .detail = "fn (self: Foo(u8)) void" },
    });
}

test "generic method - Self parameter" {
    try testCompletion(
        \\fn Foo(T: type) type {
        \\    return struct {
        \\        field: T,
        \\        const Self = @This();
        \\        fn bar(self: Self) void {
        \\            _ = self;
        \\        }
        \\    };
        \\}
        \\const foo: Foo(u8) = .{};
        \\const bar = foo.<cursor>
    , &.{
        .{ .label = "field", .kind = .Field, .detail = "u8" },
        .{ .label = "bar", .kind = .Method, .detail = "fn (self: Foo(u8)) void" },
    });
}

test "generic method - recursive self parameter" {
    try testCompletion(
        \\fn Foo(T: type) type {
        \\    return struct {
        \\        field: T,
        \\        fn bar(self: Foo(T)) void {
        \\            _ = self;
        \\        }
        \\    };
        \\}
        \\const foo: Foo(u8) = .{};
        \\const bar = foo.<cursor>
    , &.{
        .{ .label = "field", .kind = .Field, .detail = "u8" },
        .{ .label = "bar", .kind = .Method, .detail = "fn (self: Foo(u8)) void" },
    });
}

test "generic method from forwarded type function with dependent comptime value" {
    try testCompletion(
        \\const std = @import("std");
        \\const Reader = struct {
        \\    const Associated = struct { Error: type = anyerror };
        \\    fn Methods(comptime Self: type, comptime assoc: Associated) type {
        \\        return struct { read: fn (Self, []u8) assoc.Error!usize };
        \\    }
        \\};
        \\fn associatedFor(comptime C: type, comptime _: type) C.Associated {
        \\    return .{};
        \\}
        \\fn methodsType(comptime C: type, comptime Subject: type, comptime associated: C.Associated) type {
        \\    return C.Methods(Subject, associated);
        \\}
        \\fn Method(comptime C: type, comptime Subject: type, comptime associated: C.Associated) type {
        \\    return std.meta.FieldEnum(methodsType(C, Subject, associated));
        \\}
        \\fn methodType(comptime C: type, comptime Subject: type, comptime associated: C.Associated, comptime method: Method(C, Subject, associated)) type {
        \\    return @FieldType(methodsType(C, Subject, associated), @tagName(method));
        \\}
        \\fn Impl(comptime C: type, comptime Subject: type) type {
        \\    return ImplWith(C, Subject, associatedFor(C, Subject));
        \\}
        \\fn ImplWith(
        \\    comptime C: type,
        \\    comptime Subject: type,
        \\    comptime associated: C.Associated,
        \\) type {
        \\    const M = Method(C, Subject, associated);
        \\    return struct {
        \\        bindings: u8 = 0,
        \\        const Self = @This();
        \\        pub inline fn call(
        \\            comptime _: Self,
        \\            comptime method: M,
        \\            args: std.meta.ArgsTuple(methodType(C, Subject, associated, method)),
        \\        ) @typeInfo(methodType(C, Subject, associated, method)).@"fn".return_type.? {
        \\            return @call(.auto, @field(Subject, @tagName(method)), args);
        \\        }
        \\        pub fn wrongSubject(comptime _: ImplWith(C, u16, associated)) void {}
        \\    };
        \\}
        \\const Buffer = struct {
        \\    fn read(_: *Buffer, _: []u8) anyerror!usize { return 0; }
        \\};
        \\fn count(comptime impl: Impl(Reader, *Buffer)) void {
        \\    _ = impl.<cursor>
        \\}
    , &.{
        .{ .label = "bindings", .kind = .Field, .detail = "u8" },
        .{ .label = "call", .kind = .Method },
    });
}

test "enum argument of method on generated type" {
    try testCompletion(
        \\const std = @import("std");
        \\const Reader = struct {
        \\    const Associated = struct { Error: type = anyerror };
        \\    fn Methods(comptime Subject: type, comptime assoc: Associated) type {
        \\        return struct { read: fn (Subject, []u8) assoc.Error!usize };
        \\    }
        \\};
        \\fn associatedFor(comptime C: type, comptime _: type) C.Associated {
        \\    return .{};
        \\}
        \\fn methodsType(comptime C: type, comptime Subject: type, comptime associated: C.Associated) type {
        \\    return C.Methods(Subject, associated);
        \\}
        \\fn Method(comptime C: type, comptime Subject: type, comptime associated: C.Associated) type {
        \\    return std.meta.FieldEnum(methodsType(C, Subject, associated));
        \\}
        \\fn Impl(comptime C: type, comptime Subject: type) type {
        \\    return ImplWith(C, Subject, associatedFor(C, Subject));
        \\}
        \\fn ImplWith(comptime C: type, comptime Subject: type, comptime associated: C.Associated) type {
        \\    const M = Method(C, Subject, associated);
        \\    return struct {
        \\        state: u8 = 0,
        \\        const Self = @This();
        \\        fn call(comptime _: Self, comptime method: M) void {
        \\            _ = method;
        \\        }
        \\    };
        \\}
        \\fn count(comptime impl: Impl(Reader, *u8)) void {
        \\    impl.call(.<cursor>);
        \\}
    , &.{
        .{ .label = "read", .kind = .EnumMember },
    });
}

test "function taking a generic struct arg" {
    try testCompletion(
        \\fn Foo(T: type) type {
        \\    return struct {
        \\        field: T,
        \\    };
        \\}
        \\fn foo(_: Foo(u8)) void {}
        \\const bar = foo(.{.<cursor>
    , &.{
        .{ .label = "field", .kind = .Field, .detail = "u8" },
    });
}

test "anytype resolution based on callsite-references" {
    try testCompletion(
        \\const Writer1 = struct {
        \\    fn write1(self: Writer1) void {}
        \\    fn writeAll1(self: Writer1) void {}
        \\};
        \\const Writer2 = struct {
        \\    fn write2(self: Writer2) void {}
        \\    fn writeAll2(self: Writer2) void {}
        \\};
        \\fn caller(a: Writer1, b: Writer2) void {
        \\    callee(a);
        \\    callee(b);
        \\}
        \\fn callee(writer: anytype) void {
        \\    writer.<cursor>
        \\}
    , &.{
        .{ .label = "write1", .kind = .Function, .detail = "fn (self: Writer1) void" },
        .{ .label = "write2", .kind = .Function, .detail = "fn (self: Writer2) void" },
        .{ .label = "writeAll1", .kind = .Function, .detail = "fn (self: Writer1) void" },
        .{ .label = "writeAll2", .kind = .Function, .detail = "fn (self: Writer2) void" },
    });
    try testCompletion(
        \\const Writer1 = struct {
        \\    fn write1(self: Writer1) void {}
        \\    fn writeAll1(self: Writer1) void {}
        \\};
        \\const Writer2 = struct {
        \\    fn write2(self: Writer2) void {}
        \\    fn writeAll2(self: Writer2) void {}
        \\};
        \\fn caller(a: Writer1, b: Writer2) void {
        \\    callee(a);
        \\    // callee(b);
        \\}
        \\fn callee(writer: anytype) void {
        \\    writer.<cursor>
        \\}
    , &.{
        .{ .label = "write1", .kind = .Function, .detail = "fn (self: Writer1) void" },
        .{ .label = "writeAll1", .kind = .Function, .detail = "fn (self: Writer1) void" },
    });
}

test "@field" {
    try testCompletion(
        \\pub const chip_mod = struct {
        \\    pub const devices = struct {
        \\        pub const chip1 = struct {
        \\            pub const peripherals = struct {};
        \\        };
        \\    };
        \\};
        \\test {
        \\    const chip = @field(chip_mod.devices, "chip1");
        \\    chip.<cursor>
        \\}
    , &.{
        .{ .label = "peripherals", .kind = .Struct, .detail = "type" },
    });
}

test "@FieldType" {
    try testCompletion(
        \\test {
        \\    const Foo = struct {
        \\        alpha: u32,
        \\    };
        \\    const Bar = struct {
        \\        beta: Foo,
        \\    };
        \\    const foo: @FieldType(Bar, "beta") = undefined;
        \\    foo.<cursor>
        \\}
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
}

test "@extern" {
    try testCompletion(
        \\test {
        \\    const S = struct {
        \\        alpha: u32,
        \\    };
        \\    const foo = @extern(*S, .{});
        \\    foo.<cursor>
        \\}
    , &.{
        .{ .label = "*", .kind = .Operator, .detail = "S" },
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });
}

test "builtin fns return type" {
    try testCompletion(
        \\pub const chip_mod = struct {
        \\    pub const devices = struct {
        \\        pub const chip1 = struct {
        \\            pub const peripherals = struct {};
        \\        };
        \\    };
        \\};
        \\test {
        \\    const chip_name = "chip1";
        \\    const chip = @field(chip_mod.devices, chip_name);
        \\    chip.<cursor>
        \\}
    , &.{
        .{ .label = "peripherals", .kind = .Struct, .detail = "type" },
    });
    try testCompletion(
        \\pub const chip_mod = struct {
        \\    pub const devices = struct {
        \\        pub const @"chip-1" = struct {
        \\            pub const peripherals = struct {};
        \\        };
        \\    };
        \\};
        \\test {
        \\    const chips = struct {
        \\          pub const chip_name: []const u8 = "chip-1";
        \\      };
        \\    const chip = @field(chip_mod.devices, chips.chip_name);
        \\    chip.<cursor>
        \\}
    , &.{
        .{ .label = "peripherals", .kind = .Struct, .detail = "type" },
    });
    try testCompletion(
        \\test {
        \\    const src = @src();
        \\    src.<cursor>
        \\}
    , &.{
        .{ .label = "module", .kind = .Field, .detail = "[:0]const u8" },
        .{ .label = "file", .kind = .Field, .detail = "[:0]const u8" },
        .{ .label = "fn_name", .kind = .Field, .detail = "[:0]const u8" },
        .{ .label = "line", .kind = .Field, .detail = "u32" },
        .{ .label = "column", .kind = .Field, .detail = "u32" },
    });
    try testCompletion(
        \\test {
        \\    const ti = @typeInfo().<cursor>;
        \\}
    , &.{
        .{ .label = "type", .kind = .Field, .detail = "void" },
        .{ .label = "void", .kind = .Field, .detail = "void" },
        .{ .label = "bool", .kind = .Field, .detail = "void" },
        .{ .label = "noreturn", .kind = .Field, .detail = "void" },
        .{ .label = "int", .kind = .Field, .detail = "Int" },
        .{ .label = "float", .kind = .Field, .detail = "Float" },
        .{ .label = "pointer", .kind = .Field, .detail = "Pointer" },
        .{ .label = "array", .kind = .Field, .detail = "Array" },
        .{ .label = "@\"struct\"", .kind = .Field, .detail = "Struct" },
        .{ .label = "comptime_float", .kind = .Field, .detail = "void" },
        .{ .label = "comptime_int", .kind = .Field, .detail = "void" },
        .{ .label = "undefined", .kind = .Field, .detail = "void" },
        .{ .label = "null", .kind = .Field, .detail = "void" },
        .{ .label = "optional", .kind = .Field, .detail = "Optional" },
        .{ .label = "error_union", .kind = .Field, .detail = "ErrorUnion" },
        .{ .label = "error_set", .kind = .Field, .detail = "?[]const Error" },
        .{ .label = "@\"enum\"", .kind = .Field, .detail = "Enum" },
        .{ .label = "@\"union\"", .kind = .Field, .detail = "Union" },
        .{ .label = "@\"fn\"", .kind = .Field, .detail = "Fn" },
        .{ .label = "@\"opaque\"", .kind = .Field, .detail = "Opaque" },
        .{ .label = "frame", .kind = .Field, .detail = "Frame" },
        .{ .label = "@\"anyframe\"", .kind = .Field, .detail = "AnyFrame" },
        .{ .label = "vector", .kind = .Field, .detail = "Vector" },
        .{ .label = "enum_literal", .kind = .Field, .detail = "void" },
    });
}

test "function arguments of @Int" {
    try testCompletion(
        \\test {
        \\    @Int(.<cursor>)
        \\}
    , &.{
        .{ .label = "signed", .kind = .EnumMember },
        .{ .label = "unsigned", .kind = .EnumMember },
    });
}

test "function arguments of @Pointer" {
    try testCompletion(
        \\test {
        \\    @Pointer(.<cursor>)
        \\}
    , &.{
        .{ .label = "one", .kind = .EnumMember },
        .{ .label = "many", .kind = .EnumMember },
        .{ .label = "slice", .kind = .EnumMember },
        .{ .label = "c", .kind = .EnumMember },
    });
    try testCompletion(
        \\test {
        \\    @Pointer(undefined, .<cursor>)
        \\}
    , &.{
        .{ .label = "@\"const\"", .kind = .Field, .detail = "bool = false" },
        .{ .label = "@\"volatile\"", .kind = .Field, .detail = "bool = false" },
        .{ .label = "@\"allowzero\"", .kind = .Field, .detail = "bool = false" },
        .{ .label = "@\"addrspace\"", .kind = .Field, .detail = "?AddressSpace = null" },
        .{ .label = "@\"align\"", .kind = .Field, .detail = "?usize = null" },
    });
}

test "function arguments of @Fn" {
    try testCompletion(
        \\test {
        \\    @Fn(undefined, undefined, undefined, .{.<cursor>})
        \\}
    , &.{
        .{ .label = "@\"callconv\"", .kind = .Field, .detail = "CallingConvention = .auto" },
        .{ .label = "varargs", .kind = .Field, .detail = "bool = false" },
    });
}

test "function arguments of @Struct" {
    try testCompletion(
        \\test {
        \\    @Struct(.<cursor>)
        \\}
    , &.{
        .{ .label = "@\"extern\"", .kind = .EnumMember },
        .{ .label = "@\"packed\"", .kind = .EnumMember },
        .{ .label = "auto", .kind = .EnumMember },
    });
}

test "function arguments of @Union" {
    try testCompletion(
        \\test {
        \\    @Union(.<cursor>)
        \\}
    , &.{
        .{ .label = "@\"extern\"", .kind = .EnumMember },
        .{ .label = "@\"packed\"", .kind = .EnumMember },
        .{ .label = "auto", .kind = .EnumMember },
    });
}

test "function arguments of @Enum" {
    try testCompletion(
        \\test {
        \\    @Enum(undefined, .<cursor>)
        \\}
    , &.{
        .{ .label = "exhaustive", .kind = .EnumMember },
        .{ .label = "nonexhaustive", .kind = .EnumMember },
    });
}

test "function arguments of @setFloatMode" {
    try testCompletion(
        \\test {
        \\    @setFloatMode(.<cursor>)
        \\}
    , &.{
        .{ .label = "strict", .kind = .EnumMember },
        .{ .label = "optimized", .kind = .EnumMember },
    });
}

test "function arguments of @prefetch" {
    try testCompletion(
        \\test {
        \\    @prefetch(, .{.<cursor>})
        \\}
    , &.{
        .{ .label = "rw", .kind = .Field, .detail = "Rw = .read" },
        .{ .label = "locality", .kind = .Field, .detail = "u2 = 3" },
        .{ .label = "cache", .kind = .Field, .detail = "Cache = .data" },
    });
}

test "function arguments of @reduce" {
    try testCompletion(
        \\test {
        \\    @reduce(.<cursor>
        \\}
    , &.{
        .{ .label = "And", .kind = .EnumMember },
        .{ .label = "Or", .kind = .EnumMember },
        .{ .label = "Xor", .kind = .EnumMember },
        .{ .label = "Min", .kind = .EnumMember },
        .{ .label = "Max", .kind = .EnumMember },
        .{ .label = "Add", .kind = .EnumMember },
        .{ .label = "Mul", .kind = .EnumMember },
    });
}

test "function arguments of @export" {
    try testCompletionTextEdit(.{
        .source = "comptime { @export(foo ,.<cursor>",
        .label = "name",
        .expected_insert_line = "comptime { @export(foo ,.{ .name = ",
        .expected_replace_line = "comptime { @export(foo ,.{ .name = ",
        .enable_snippets = false,
    });
}

test "function arguments of @extern" {
    try testCompletionTextEdit(.{
        .source = "test { @extern(T , .<cursor>",
        .label = "is_thread_local",
        .expected_insert_line = "test { @extern(T , .{ .is_thread_local = ",
        .expected_replace_line = "test { @extern(T , .{ .is_thread_local = ",
        .enable_snippets = false,
    });
}

test "function arguments of @cmpxchgWeak" {
    try testCompletionTextEdit(.{
        .source = "test { @cmpxchgWeak(1,2,3,4, .<cursor>",
        .label = "acq_rel",
        .expected_insert_line = "test { @cmpxchgWeak(1,2,3,4, .acq_rel",
        .expected_replace_line = "test { @cmpxchgWeak(1,2,3,4, .acq_rel",
        .enable_snippets = false,
    });
}

test "function arguments of @cmpxchgStrong" {
    try testCompletionTextEdit(.{
        .source = "test { @cmpxchgStrong(1,2,3,4,5,.<cursor>",
        .label = "acq_rel",
        .expected_insert_line = "test { @cmpxchgStrong(1,2,3,4,5,.acq_rel",
        .expected_replace_line = "test { @cmpxchgStrong(1,2,3,4,5,.acq_rel",
        .enable_snippets = false,
    });
}

test "function arguments of @atomicLoad" {
    try testCompletionTextEdit(.{
        .source = "test { @atomicLoad(1,2,.<cursor>",
        .label = "acq_rel",
        .expected_insert_line = "test { @atomicLoad(1,2,.acq_rel",
        .expected_replace_line = "test { @atomicLoad(1,2,.acq_rel",
        .enable_snippets = false,
    });
}

test "function arguments of @atomicStore" {
    try testCompletionTextEdit(.{
        .source = "test { @atomicStore(1,2,3,.<cursor>",
        .label = "acq_rel",
        .expected_insert_line = "test { @atomicStore(1,2,3,.acq_rel",
        .expected_replace_line = "test { @atomicStore(1,2,3,.acq_rel",
        .enable_snippets = false,
    });
}

test "function arguments of @atomicRmw" {
    try testCompletionTextEdit(.{
        .source = "test { @atomicRmw(1,2,.<cursor>",
        .label = "Add",
        .expected_insert_line = "test { @atomicRmw(1,2,.Add",
        .expected_replace_line = "test { @atomicRmw(1,2,.Add",
        .enable_snippets = false,
    });
    try testCompletionTextEdit(.{
        .source = "test { @atomicRmw(1,2,3,4,.<cursor>",
        .label = "acq_rel",
        .expected_insert_line = "test { @atomicRmw(1,2,3,4,.acq_rel",
        .expected_replace_line = "test { @atomicRmw(1,2,3,4,.acq_rel",
        .enable_snippets = false,
    });
}

test "function arguments of @call" {
    try testCompletion(
        \\test {
        \\    @call(.<cursor>
        \\}
    , &.{
        .{ .label = "auto", .kind = .EnumMember },
        .{ .label = "never_tail", .kind = .EnumMember },
        .{ .label = "never_inline", .kind = .EnumMember },
        .{ .label = "always_tail", .kind = .EnumMember },
        .{ .label = "always_inline", .kind = .EnumMember },
        .{ .label = "compile_time", .kind = .EnumMember },
        .{ .label = "no_suspend", .kind = .EnumMember },
    });
}

test "function attributes" {
    try testCompletionTextEdit(.{
        .source = "var a: u16 addrspace(.<cursor>",
        .label = "constant",
        .expected_insert_line = "var a: u16 addrspace(.constant",
        .expected_replace_line = "var a: u16 addrspace(.constant",
    });
    try testCompletionTextEdit(.{
        .source = "fn foo() callconv(.<cursor>",
        .label = "arm_aapcs",
        .expected_insert_line = "fn foo() callconv(.{ .arm_aapcs = ",
        .expected_replace_line = "fn foo() callconv(.{ .arm_aapcs = ",
    });
}

test "label" {
    try testCompletion(
        \\const foo = blk: {
        \\    break :<cursor>
        \\};
    , &.{
        .{ .label = "blk", .kind = .Text }, // idk what kind this should be
    });
    try testCompletion(
        \\comptime {
        \\    sw: switch (0) {
        \\        else => break :<cursor>,
        \\    }
        \\}
    , &.{
        .{ .label = "sw", .kind = .Text },
    });
    try testCompletion(
        \\comptime {
        \\    closed: {
        \\        break :closed;
        \\    }
        \\    active: switch (0) {
        \\        else => break :<cursor>,
        \\    }
        \\}
    , &.{
        .{ .label = "active", .kind = .Text },
    });

    try testCompletion(
        \\const S = struct { alpha: u32 };
        \\const foo: S = undefined;
        \\const bar = blk: {
        \\    break :blk foo;
        \\};
        \\const baz = bar.<cursor>
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
    });

    try testCompletionTextEdit(.{
        .source =
        \\const foo = blk: {
        \\    break :<cursor>
        \\};
        ,
        .label = "blk",
        .expected_insert_line = "    break :blk",
        .expected_replace_line = "    break :blk",
    });
}

test "either" {
    try testCompletion(
        \\const Alpha = struct {
        \\    fn alpha(_: @This()) void {}
        \\};
        \\const Beta = struct {
        \\    field: u32,
        \\    fn beta(_: @This()) void {}
        \\};
        \\const foo: if (undefined) Alpha else Beta = undefined;
        \\const bar = foo.<cursor>
    , &.{
        .{ .label = "field", .kind = .Field, .detail = "u32" },
        .{ .label = "alpha", .kind = .Function, .detail = "fn (_: Alpha) void" },
        .{ .label = "beta", .kind = .Method, .detail = "fn (_: Beta) void" },
    });
    try testCompletion(
        \\const Alpha = struct {
        \\    fn alpha(_: @This()) void {}
        \\};
        \\const Beta = struct {
        \\    field: u32,
        \\    fn beta(_: @This()) void {}
        \\};
        \\const alpha: Alpha = undefined;
        \\const beta: Beta = undefined;
        \\const gamma = if (undefined) alpha else beta;
        \\const foo = gamma.<cursor>
    , &.{
        .{ .label = "field", .kind = .Field, .detail = "u32" },
        .{ .label = "alpha", .kind = .Function, .detail = "fn (_: Alpha) void" },
        .{ .label = "beta", .kind = .Method, .detail = "fn (_: Beta) void" },
    });

    try testCompletion(
        \\const Alpha = struct {
        \\    fn alpha(_: @This()) void {}
        \\};
        \\const Beta = struct {
        \\    fn beta(_: @This()) void {}
        \\};
        \\const T = if (undefined) Alpha else Beta;
        \\const bar = T.<cursor>
    , &.{
        .{ .label = "alpha", .kind = .Function, .detail = "fn (_: Alpha) void" },
        .{ .label = "beta", .kind = .Function, .detail = "fn (_: Beta) void" },
    });
}

test "either - fields and methods with same name" {
    try testCompletionWithOptions(
        \\const Foo = struct {
        \\    alpha: u32,
        \\    beta: []const u8,
        \\    fn gamma(_: @This()) void {}
        \\    fn delta(_: @This()) f32 {}
        \\};
        \\const Bar = struct {
        \\    alpha: u32,
        \\    beta: bool,
        \\    fn gamma(_: @This()) void {}
        \\    fn delta(_: @This()) f64 {}
        \\};
        \\const fizz: if (undefined) Foo else Bar = undefined;
        \\const buzz = fizz.<cursor>
    , &.{
        .{
            .label = "alpha",
            .labelDetails = .{
                .detail = null,
                .description = "u32",
            },
            .kind = .Field,
            .detail = "u32",
        },
        .{
            .label = "beta",
            .labelDetails = null,
            .kind = .Field,
            .detail = null,
        },
        .{
            .label = "gamma",
            .labelDetails = .{
                .detail = "()",
                .description = "void",
            },
            .kind = .Method,
            .detail = null,
        },
        .{
            .label = "delta",
            .labelDetails = null,
            .kind = .Method,
            .detail = null,
        },
    }, .{
        .check_null_fields = true,
    });
}

test "either instance field preserves all candidate types" {
    try testCompletion(
        \\const AlphaValue = struct { alpha: u8 };
        \\const BetaValue = struct { beta: u16 };
        \\const Alpha = struct { nested: AlphaValue };
        \\const Beta = struct { nested: BetaValue };
        \\const Either = if (undefined) Alpha else Beta;
        \\const value: Either = undefined;
        \\const nested = value.nested;
        \\const field = nested.<cursor>
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u8" },
        .{ .label = "beta", .kind = .Field, .detail = "u16" },
    });
}

test "either callable preserves all return types" {
    try testCompletion(
        \\var runtime: bool = undefined;
        \\const Alpha = struct { alpha: u8 };
        \\const Beta = struct { beta: u16 };
        \\fn alpha() Alpha { return undefined; }
        \\fn beta() Beta { return undefined; }
        \\const function = if (runtime) alpha else beta;
        \\const value = function();
        \\const field = value.<cursor>
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u8" },
        .{ .label = "beta", .kind = .Field, .detail = "u16" },
    });

    try testCompletion(
        \\var runtime: bool = undefined;
        \\const Alpha = struct { alpha: u8 };
        \\const Beta = struct { beta: u16 };
        \\fn alpha(_: u8) Alpha { return undefined; }
        \\fn beta(_: u8) Beta { return undefined; }
        \\const function = if (runtime) alpha else beta;
        \\const value = function(4);
        \\const field = value.<cursor>
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u8" },
        .{ .label = "beta", .kind = .Field, .detail = "u16" },
    });
}

test "container type inside switch case value" {
    try testCompletion(
        \\test {
        \\    switch (undefined) {
        \\        struct {
        \\            const This = @This();
        \\            fn func() void {
        \\                This.<cursor>
        \\            }
        \\        } => {},
        \\    }
        \\}
    , &.{
        .{ .label = "This", .kind = .Struct, .detail = "type" },
        .{ .label = "func", .kind = .Function, .detail = "fn () void" },
    });
}

// https://github.com/zigtools/zls/issues/1370
test "cyclic struct init field" {
    try testCompletion(
        \\_ = .{} .foo = .{ .<cursor>foo
    , &.{});
}

test "integer overflow in struct init field without lhs" {
    try testCompletion(
        \\= .{ .<cursor>foo
    , &.{});
}

test "integer overflow in dot completions at beginning of file" {
    try testCompletion(
        \\.<cursor>
    , &.{});
}

test "enum completion on out of bound parameter index" {
    try testCompletion(
        \\fn foo() void {}
        \\const foo = foo(,.<cursor>);
    , &.{});
}

test "enum completion on out of bound token index" {
    try testCompletion(
        \\ = 1.<cursor>
    , &.{});
    try testCompletion(
        \\) { .<cursor>
    , &.{});
}

test "combine doc comments of declaration and definition" {
    if (true) return error.SkipZigTest; // TODO
    try testCompletion(
        \\const foo = struct {
        \\    /// A
        \\    const bar = fizz.buzz;
        \\};
        \\const fizz = struct {
        \\    /// B
        \\    const buzz = struct {};
        \\};
        \\test {
        \\    foo.<cursor>
        \\}
    , &.{
        .{
            .label = "bar",
            .kind = .Struct,
            .detail = "struct",
            .documentation =
            \\ A
            \\
            \\ B
            ,
        },
    });
}

test "top-level doc comment" {
    try testCompletion(
        \\//! B
        \\
        \\/// A
        \\const Foo = @This();
        \\
        \\const Bar = <cursor>
    , &.{
        .{
            .label = "Foo",
            .kind = .Struct,
            .detail = "type",
            .documentation =
            \\A
            \\
            \\B
            ,
        },
    });
}

test "filesystem" {
    if (@import("builtin").target.cpu.arch.isWasm()) return error.SkipZigTest;

    try testCompletion(
        \\const foo = @import("<cursor>");
    , &.{
        .{
            .label = "std",
            .kind = .Module,
        },
        .{
            .label = "builtin",
            .kind = .Module,
        },
    });
}

test "filesystem string literal ends with non ASCII symbol" {
    if (@import("builtin").target.cpu.arch.isWasm()) return error.SkipZigTest;

    try testCompletion(
        \\const foo = @import("<cursor> 🠁
    , &.{
        .{
            .label = "std",
            .kind = .Module,
        },
        .{
            .label = "builtin",
            .kind = .Module,
        },
    });
}

test "filesystem unterminated string literal with newline" {
    try testCompletion(
        \\const foo = @import("
        \\  <cursor>
    , &.{});
}

test "label details disabled" {
    try testCompletionWithOptions(
        \\const S = struct {
        \\    alpha: u32,
        \\    fn f(self: S) void {}
        \\};
        \\const s = S{};
        \\s.<cursor>
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
        .{
            .label = "f",
            .labelDetails = .{
                .detail = "()",
                .description = "void",
            },
            .kind = .Method,
            .detail = "fn (self: S) void",
        },
    }, .{
        .completion_label_details = false,
    });
    try testCompletionWithOptions(
        \\const S = struct {
        \\    alpha: u32,
        \\    fn f(self: S, value: u32) !void {}
        \\};
        \\const s = S{};
        \\s.<cursor>
    , &.{
        .{ .label = "alpha", .kind = .Field, .detail = "u32" },
        .{
            .label = "f",
            .labelDetails = .{
                .detail = "(...)",
                .description = "!void",
            },
            .kind = .Method,
            .detail = "fn (self: S, value: u32) !void",
        },
    }, .{
        .completion_label_details = false,
    });
}

test "insert replace behaviour - keyword" {
    try testCompletionTextEdit(.{
        .source = "const foo = <cursor>@abs(5);",
        .label = "comptime",
        .expected_insert_line = "const foo = comptime@abs(5);",
        .expected_replace_line = "const foo = comptime@abs(5);",
    });
    try testCompletionTextEdit(.{
        .source = "const foo = <cursor>comptime;",
        .label = "comptime_float",
        .expected_insert_line = "const foo = comptime_floatcomptime;",
        .expected_replace_line = "const foo = comptime_float;",
    });
    try testCompletionTextEdit(.{
        .source = "const foo = <cursor>comptime;",
        .label = "comptime_float",
        .expected_insert_line = "const foo = comptime_floatcomptime;",
        .expected_replace_line = "const foo = comptime_float;",
    });
    try testCompletionTextEdit(.{
        .source = "const foo = comp<cursor>;",
        .label = "comptime",
        .expected_insert_line = "const foo = comptime;",
        .expected_replace_line = "const foo = comptime;",
    });
    try testCompletionTextEdit(.{
        .source = "const foo = comp<cursor>time;",
        .label = "comptime",
        .expected_insert_line = "const foo = comptimetime;",
        .expected_replace_line = "const foo = comptime;",
    });
    try testCompletionTextEdit(.{
        .source = "const foo = comptime<cursor>;",
        .label = "comptime",
        .expected_insert_line = "const foo = comptime;",
        .expected_replace_line = "const foo = comptime;",
    });
    try testCompletionTextEdit(.{
        .source = "const foo = comptime<cursor>;",
        .label = "comptime_float",
        .expected_insert_line = "const foo = comptime_float;",
        .expected_replace_line = "const foo = comptime_float;",
    });
    try testCompletionTextEdit(.{
        .source = "const foo = comptime <cursor>;",
        .label = "comptime_float",
        .expected_insert_line = "const foo = comptime comptime_float;",
        .expected_replace_line = "const foo = comptime comptime_float;",
    });
}

test "insert replace behaviour - builtin" {
    try testCompletionTextEdit(.{
        .source = "const foo = @<cursor>;",
        .label = "@abs",
        .expected_insert_line = "const foo = @abs;",
        .expected_replace_line = "const foo = @abs;",
    });
    try testCompletionTextEdit(.{
        .source = "const foo = @a<cursor>;",
        .label = "@abs",
        .expected_insert_line = "const foo = @abs;",
        .expected_replace_line = "const foo = @abs;",
    });
    try testCompletionTextEdit(.{
        .source = "const foo = @<cursor>abs;",
        .label = "@abs",
        .expected_insert_line = "const foo = @absabs;",
        .expected_replace_line = "const foo = @abs;",
    });
    try testCompletionTextEdit(.{
        .source = "const foo = @a<cursor>bs;",
        .label = "@abs",
        .expected_insert_line = "const foo = @absbs;",
        .expected_replace_line = "const foo = @abs;",
    });

    try testCompletionTextEdit(.{
        .source = "const foo = @<cursor>(5);",
        .label = "@abs",
        .expected_insert_line = "const foo = @abs(5);",
        .expected_replace_line = "const foo = @abs(5);",
    });
    try testCompletionTextEdit(.{
        .source = "const foo = @a<cursor>(5);",
        .label = "@abs",
        .expected_insert_line = "const foo = @abs(5);",
        .expected_replace_line = "const foo = @abs(5);",
    });
    try testCompletionTextEdit(.{
        .source = "const foo = @<cursor>abs(5);",
        .label = "@abs",
        .expected_insert_line = "const foo = @absabs(5);",
        .expected_replace_line = "const foo = @abs(5);",
    });
    try testCompletionTextEdit(.{
        .source = "const foo = @a<cursor>bs(5);",
        .label = "@abs",
        .expected_insert_line = "const foo = @absbs(5);",
        .expected_replace_line = "const foo = @abs(5);",
    });
}

test "insert replace behaviour - builtin with no parameters" {
    try testCompletionTextEdit(.{
        .source = "const foo = @<cursor>;",
        .label = "@src",
        .expected_insert_line = "const foo = @src;",
        .expected_replace_line = "const foo = @src;",
    });
    try testCompletionTextEdit(.{
        .source = "const foo = @<cursor>();",
        .label = "@src",
        .expected_insert_line = "const foo = @src();",
        .expected_replace_line = "const foo = @src();",
    });
    try testCompletionTextEdit(.{
        .source = "const foo = @<cursor>(5);",
        .label = "@src",
        .expected_insert_line = "const foo = @src(5);",
        .expected_replace_line = "const foo = @src(5);",
    });
}

test "insert replace behaviour - builtin with snippets" {
    try testCompletionTextEdit(.{
        .source = "const foo = @<cursor>;",
        .label = "@as",
        .expected_insert_line = "const foo = @as(${1:comptime T: type}, ${2:expression});",
        .expected_replace_line = "const foo = @as(${1:comptime T: type}, ${2:expression});",
        .enable_snippets = true,
        .enable_argument_placeholders = true,
    });
    try testCompletionTextEdit(.{
        .source = "const foo = @<cursor>(;",
        .label = "@as",
        .expected_insert_line = "const foo = @as(;",
        .expected_replace_line = "const foo = @as(;",
        .enable_snippets = true,
        .enable_argument_placeholders = true,
    });
    try testCompletionTextEdit(.{
        .source = "const foo = @<cursor>();",
        .label = "@as",
        .expected_insert_line = "const foo = @as(${1:comptime T: type}, ${2:expression});",
        .expected_replace_line = "const foo = @as(${1:comptime T: type}, ${2:expression});",
        .enable_snippets = true,
        .enable_argument_placeholders = true,
    });
    try testCompletionTextEdit(.{
        .source = "const foo = @<cursor>;",
        .label = "@src",
        .expected_insert_line = "const foo = @src();",
        .expected_replace_line = "const foo = @src();",
        .enable_snippets = true,
        .enable_argument_placeholders = false,
    });
    try testCompletionTextEdit(.{
        .source = "const foo = @<cursor>;",
        .label = "@as",
        .expected_insert_line = "const foo = @as(${1:});",
        .expected_replace_line = "const foo = @as(${1:});",
        .enable_snippets = true,
        .enable_argument_placeholders = false,
    });

    // remove the following test when partial argument placeholders are supported (see test below)
    try testCompletionTextEdit(.{
        .source = "const foo = @<cursor>(u32);",
        .label = "@as",
        .expected_insert_line = "const foo = @as(u32);",
        .expected_replace_line = "const foo = @as(u32);",
        .enable_snippets = true,
        .enable_argument_placeholders = true,
    });
}

test "insert replace behaviour - builtin with snippets - @errorFromInt" {
    try testCompletionTextEdit(.{
        .source = "const foo = @<cursor>;",
        .label = "@errorFromInt",
        .expected_insert_line = "const foo = @errorFromInt(${1:value: @Int(.unsigned, @bitSizeOf(anyerror))});",
        .expected_replace_line = "const foo = @errorFromInt(${1:value: @Int(.unsigned, @bitSizeOf(anyerror))});",
        .enable_snippets = true,
        .enable_argument_placeholders = true,
    });
}

test "insert replace behaviour - builtin with partial argument placeholders" {
    if (true) return error.SkipZigTest; // TODO
    try testCompletionTextEdit(.{
        .source = "const foo = @<cursor>(u32,);",
        .label = "@as",
        .expected_insert_line = "const foo = @as(u32, ${1:expression});",
        .expected_replace_line = "const foo = @as(u32, ${1:expression});",
        .enable_snippets = true,
        .enable_argument_placeholders = true,
    });
    try testCompletionTextEdit(.{
        .source = "const foo = @<cursor>( , 5);",
        .label = "@as",
        .expected_insert_line = "const foo = @as(${1:comptime T: type}, 5);",
        .expected_replace_line = "const foo = @as(${1:comptime T: type}, 5);",
        .enable_snippets = true,
        .enable_argument_placeholders = true,
    });
    try testCompletionTextEdit(.{
        .source = "const foo = @<cursor>(u32, 5);",
        .label = "@as",
        .expected_insert_line = "const foo = @as(u32, 5);",
        .expected_replace_line = "const foo = @as(u32, 5);",
        .enable_snippets = true,
        .enable_argument_placeholders = true,
    });
}

test "insert replace behaviour - prepend on builtin or enum literal" {
    try testCompletionTextEdit(.{
        .source = "const foo = <cursor>@",
        .label = "comptime_int",
        .expected_insert_line = "const foo = comptime_int@",
        .expected_replace_line = "const foo = comptime_int@",
    });
    try testCompletionTextEdit(.{
        .source =
        \\const E = enum{ A, B };
        \\const foo: E = <cursor>.
        ,
        .label = "comptime_int",
        .expected_insert_line = "const foo: E = comptime_int.",
        .expected_replace_line = "const foo: E = comptime_int.",
    });
}

test "insert replace behaviour - function" {
    try testCompletionTextEdit(.{
        .source =
        \\fn foo() void {}
        \\const _ = <cursor>bar()
        ,
        .label = "foo",
        .expected_insert_line = "const _ = foobar()",
        .expected_replace_line = "const _ = foo()",
    });
    try testCompletionTextEdit(.{
        .source =
        \\fn foo(number: u32) void {}
        \\const _ = <cursor>bar()
        ,
        .label = "foo",
        .expected_insert_line = "const _ = foobar()",
        .expected_replace_line = "const _ = foo()",
    });
    try testCompletionTextEdit(.{
        .source =
        \\fn foo(a: u32, b: u32) void {}
        \\const _ = <cursor>
        ,
        .label = "foo",
        .expected_insert_line = "const _ = foo",
        .expected_replace_line = "const _ = foo",
    });
    try testCompletionTextEdit(.{
        .source =
        \\fn foo(number: u32) void {}
        \\const _ = <cursor>()
        ,
        .label = "foo",
        .expected_insert_line = "const _ = foo(${1:})",
        .expected_replace_line = "const _ = foo(${1:})",
        .enable_snippets = true,
        .enable_argument_placeholders = false,
    });
}

test "insert replace behaviour - function 'self parameter' detection" {
    try testCompletionTextEdit(.{
        .source =
        \\const S = struct {
        \\    alpha: u32,
        \\    fn f(self: S) void {}
        \\};
        \\const s = S{};
        \\s.<cursor>
        ,
        .label = "f",
        .expected_insert_line = "s.f()",
        .expected_replace_line = "s.f()",
        .enable_snippets = true,
    });
    try testCompletionTextEdit(.{
        .source =
        \\const S = struct {
        \\    alpha: u32,
        \\    fn f(self: S) void {}
        \\};
        \\S.<cursor>
        ,
        .label = "f",
        .expected_insert_line = "S.f(${1:})",
        .expected_replace_line = "S.f(${1:})",
        .enable_snippets = true,
    });

    try testCompletionTextEdit(.{
        .source =
        \\const S = struct {
        \\    alpha: u32,
        \\    fn f(self: @This()) void {}
        \\};
        \\const s = S{};
        \\s.<cursor>
        ,
        .label = "f",
        .expected_insert_line = "s.f()",
        .expected_replace_line = "s.f()",
        .enable_snippets = true,
    });
    try testCompletionTextEdit(.{
        .source =
        \\const S = struct {
        \\    alpha: u32,
        \\    fn f(self: anytype) void {}
        \\};
        \\const s = S{};
        \\s.<cursor>
        ,
        .label = "f",
        .expected_insert_line = "s.f()",
        .expected_replace_line = "s.f()",
        .enable_snippets = true,
    });
    try testCompletionTextEdit(.{
        .source =
        \\const S = struct {
        \\    alpha: u32,
        \\    fn f(self: S, number: u32) void {}
        \\};
        \\const s = S{};
        \\s.<cursor>
        ,
        .label = "f",
        .expected_insert_line = "s.f(${1:})",
        .expected_replace_line = "s.f(${1:})",
        .enable_snippets = true,
    });
}

test "insert replace behaviour - function with snippets" {
    try testCompletionTextEdit(.{
        .source =
        \\fn func(comptime T: type, number: u32) void {}
        \\const foo = <cursor>;
        ,
        .label = "func",
        .expected_insert_line = "const foo = func(${1:comptime T: type}, ${2:number: u32});",
        .expected_replace_line = "const foo = func(${1:comptime T: type}, ${2:number: u32});",
        .enable_snippets = true,
        .enable_argument_placeholders = true,
    });
    try testCompletionTextEdit(.{
        .source =
        \\fn func(comptime T: type, number: u32) void {}
        \\const foo = <cursor>(;
        ,
        .label = "func",
        .expected_insert_line = "const foo = func(;",
        .expected_replace_line = "const foo = func(;",
        .enable_snippets = true,
        .enable_argument_placeholders = true,
    });
    try testCompletionTextEdit(.{
        .source =
        \\fn func(comptime T: type, number: u32) void {}
        \\const foo = <cursor>();
        ,
        .label = "func",
        .expected_insert_line = "const foo = func(${1:comptime T: type}, ${2:number: u32});",
        .expected_replace_line = "const foo = func(${1:comptime T: type}, ${2:number: u32});",
        .enable_snippets = true,
        .enable_argument_placeholders = true,
    });
}

test "insert replace behaviour - function with escaped snippet" {
    try testCompletionTextEdit(.{
        .source =
        \\fn @"${}"(e: error{}) void {}
        \\const foo = <cursor>;
        ,
        .label = "@\"${}\"",
        .expected_insert_line =
        \\const foo = @"\${\}"(${1:e: error{\}});
        ,
        .expected_replace_line =
        \\const foo = @"\${\}"(${1:e: error{\}});
        ,
        .enable_snippets = true,
        .enable_argument_placeholders = true,
    });
}

test "insert replace behaviour - function with snippets - 'self parameter' with placeholder" {
    try testCompletionTextEdit(.{
        .source =
        \\const S = struct {
        \\    alpha: u32,
        \\    fn f(self: S) void {}
        \\};
        \\S.<cursor>
        ,
        .label = "f",
        .expected_insert_line = "S.f(${1:self: S})",
        .expected_replace_line = "S.f(${1:self: S})",
        .enable_snippets = true,
        .enable_argument_placeholders = true,
    });
    try testCompletionTextEdit(.{
        .source =
        \\const S = struct {
        \\    alpha: u32,
        \\    fn f(self: S, number: u32) void {}
        \\};
        \\var s = S{};
        \\s.<cursor>
        ,
        .label = "f",
        .expected_insert_line = "s.f(${1:number: u32})",
        .expected_replace_line = "s.f(${1:number: u32})",
        .enable_snippets = true,
        .enable_argument_placeholders = true,
    });
    try testCompletionTextEdit(.{
        .source =
        \\const S = struct {
        \\    alpha: u32,
        \\    fn f(self: S) void {}
        \\};
        \\const s = S{};
        \\s.<cursor>
        ,
        .label = "f",
        .expected_insert_line = "s.f()",
        .expected_replace_line = "s.f()",
        .enable_snippets = true,
        .enable_argument_placeholders = false,
    });
    try testCompletionTextEdit(.{
        .source =
        \\const S = struct {
        \\    alpha: u32,
        \\    fn f(self: S) void {}
        \\};
        \\S.<cursor>
        ,
        .label = "f",
        .expected_insert_line = "S.f(${1:})",
        .expected_replace_line = "S.f(${1:})",
        .enable_snippets = true,
        .enable_argument_placeholders = false,
    });
}

test "insert replace behaviour - function with snippets - partial argument placeholders" {
    // remove the following tests when partial argument placeholders are supported (see test below)
    try testCompletionTextEdit(.{
        .source =
        \\fn func(comptime T: type, number: u32) void {}
        \\const foo = <cursor>(u32);
        ,
        .label = "func",
        .expected_insert_line = "const foo = func(u32);",
        .expected_replace_line = "const foo = func(u32);",
        .enable_snippets = true,
        .enable_argument_placeholders = true,
    });
    try testCompletionTextEdit(.{
        .source =
        \\fn func(comptime T: type, number: u32) void {}
        \\const foo = <cursor>c(u32);
        ,
        .label = "func",
        .expected_insert_line = "const foo = funcc(u32);",
        .expected_replace_line = "const foo = func(u32);",
        .enable_snippets = true,
        .enable_argument_placeholders = true,
    });
}

test "insert replace behaviour - function with partial argument placeholders" {
    if (true) return error.SkipZigTest; // TODO
    try testCompletionTextEdit(.{
        .source =
        \\fn func(comptime T: type, number: u32) void {}
        \\const foo = <cursor>(u32,);
        ,
        .label = "func",
        .expected_insert_line = "const foo = func(u32, ${1:number: u32});",
        .expected_replace_line = "const foo = func(u32, ${1:number: u32});",
        .enable_snippets = true,
        .enable_argument_placeholders = true,
    });
    try testCompletionTextEdit(.{
        .source =
        \\fn func(comptime T: type, number: u32) void {}
        \\const foo = <cursor>( , 5);
        ,
        .label = "func",
        .expected_insert_line = "const foo = func(${1:comptime T: type}, 5);",
        .expected_replace_line = "const foo = func(${1:comptime T: type}, 5);",
        .enable_snippets = true,
        .enable_argument_placeholders = true,
    });
    try testCompletionTextEdit(.{
        .source =
        \\fn func(comptime T: type, number: u32) void {}
        \\const foo = <cursor>(u32, 5);
        ,
        .label = "func",
        .expected_insert_line = "const foo = func(u32, 5);",
        .expected_replace_line = "const foo = func(u32, 5);",
        .enable_snippets = true,
        .enable_argument_placeholders = true,
    });
}

test "insert replace behaviour - function alias" {
    try testCompletionTextEdit(.{
        .source =
        \\fn func() void {}
        \\const alias = func;
        \\const foo = <cursor>();
        ,
        .label = "alias",
        .expected_insert_line = "const foo = alias();",
        .expected_replace_line = "const foo = alias();",
    });
    try testCompletionTextEdit(.{
        .source =
        \\fn func() void {}
        \\const alias = func;
        \\const foo = <cursor>();
        ,
        .label = "alias",
        .expected_insert_line = "const foo = alias();",
        .expected_replace_line = "const foo = alias();",
        .enable_snippets = true,
        .enable_argument_placeholders = true,
    });
}

test "insert replace behaviour - escaped identifier" {
    try testCompletionTextEdit(.{
        .source =
        \\const @"foo bar" = 5;
        \\const foo = @"foo<cursor>
        ,
        .label = "@\"foo bar\"",
        .expected_insert_line = "const foo = @\"foo bar\"",
        .expected_replace_line = "const foo = @\"foo bar\"",
    });
    try testCompletionTextEdit(.{
        .source =
        \\fn @"foo bar"() void {}
        \\const foo = <cursor>@"foo
        ,
        .label = "@\"foo bar\"",
        .expected_insert_line = "const foo = @\"foo bar\"@\"foo",
        .expected_replace_line = "const foo = @\"foo bar\"",
    });
    try testCompletionTextEdit(.{
        .source =
        \\fn @"foo bar"() void {}
        \\const foo = @"foo <cursor>
        ,
        .label = "@\"foo bar\"",
        .expected_insert_line = "const foo = @\"foo bar\"",
        .expected_replace_line = "const foo = @\"foo bar\"",
    });
}

test "insert replace behaviour - decl literal function" {
    try testCompletionTextEdit(.{
        .source =
        \\const S = struct {
        \\    fn init() S {}
        \\};
        \\const foo: S = .<cursor>;
        ,
        .label = "init",
        .expected_insert_line = "const foo: S = .init;",
        .expected_replace_line = "const foo: S = .init;",
    });
}

test "insert replace behaviour - struct literal" {
    try testCompletionTextEdit(.{
        .source =
        \\const S = struct { alpha: u32 };
        \\const foo: S = .{ .<cursor>
        ,
        .label = "alpha",
        .expected_insert_line = "const foo: S = .{ .alpha = ",
        .expected_replace_line = "const foo: S = .{ .alpha = ",
        .enable_snippets = true,
    });
    try testCompletionTextEdit(.{
        .source =
        \\const S = struct { alpha: u32 };
        \\const foo: S = .<cursor>
        ,
        .label = "alpha",
        .expected_insert_line = "const foo: S = .{ .alpha = ",
        .expected_replace_line = "const foo: S = .{ .alpha = ",
    });
    try testCompletionTextEdit(.{
        .source =
        \\const S = struct { alpha: u32 };
        \\const foo: S = .<cursor>
        ,
        .label = "alpha",
        .expected_insert_line = "const foo: S = .{ .alpha = $1 \\}$0",
        .expected_replace_line = "const foo: S = .{ .alpha = $1 \\}$0",
        .enable_snippets = true,
    });
}

test "insert replace behaviour - struct literal with escaped snippet" {
    try testCompletionTextEdit(.{
        .source =
        \\const S = struct { @"${}": u32 };
        \\const foo: S = .<cursor>
        ,
        .label = "@\"${}\"",
        .expected_insert_line =
        \\const foo: S = .{ .@"\${\}" = $1 \}$0
        ,
        .expected_replace_line =
        \\const foo: S = .{ .@"\${\}" = $1 \}$0
        ,
        .enable_snippets = true,
    });
}

test "insert replace behaviour - struct literal - check for equal sign" {
    try testCompletionTextEdit(.{
        .source =
        \\const S = struct { alpha: u32 };
        \\const foo: S = .{ .<cursor> = 5 };
        ,
        .label = "alpha",
        .expected_insert_line = "const foo: S = .{ .alpha = 5 };",
        .expected_replace_line = "const foo: S = .{ .alpha = 5 };",
        .enable_snippets = true,
    });
    try testCompletionTextEdit(.{
        .source =
        \\const S = struct { alpha: u32 };
        \\const foo: S = .{ . <cursor> = 5 };
        ,
        .label = "alpha",
        .expected_insert_line = "const foo: S = .{ . alpha = 5 };",
        .expected_replace_line = "const foo: S = .{ . alpha = 5 };",
        .enable_snippets = true,
    });
    try testCompletionTextEdit(.{
        .source =
        \\const S = struct { alpha: u32 };
        \\const foo: S = .{ .<cursor>= 5 };
        ,
        .label = "alpha",
        .expected_insert_line = "const foo: S = .{ .alpha= 5 };",
        .expected_replace_line = "const foo: S = .{ .alpha= 5 };",
        .enable_snippets = true,
    });
}

test "insert replace behaviour - tagged union" {
    try testCompletionTextEdit(.{
        .source =
        \\const Birdie = enum { canary };
        \\const U = union(enum) { alpha: []const u8 };
        \\const foo: U = .<cursor>
        ,
        .label = "alpha",
        .expected_insert_line = "const foo: U = .{ .alpha = $1 \\}$0",
        .expected_replace_line = "const foo: U = .{ .alpha = $1 \\}$0",
        .enable_snippets = true,
    });
    try testCompletionTextEdit(.{
        .source =
        \\const Birdie = enum { canary };
        \\const U = union(enum) { alpha: []const u8 };
        \\const foo: U = .<cursor>
        ,
        .label = "alpha",
        .expected_insert_line = "const foo: U = .{ .alpha = ",
        .expected_replace_line = "const foo: U = .{ .alpha = ",
    });
    try testCompletionTextEdit(.{
        .source =
        \\const U = union(enum) { alpha: []const u8 };
        \\const u: U = undefined;
        \\const boolean = u == .<cursor>
        ,
        .label = "alpha",
        .expected_insert_line = "const boolean = u == .alpha",
        .expected_replace_line = "const boolean = u == .alpha",
    });
    try testCompletionTextEdit(.{
        .source =
        \\const E = union(enum) {
        \\    foo: []const u8,
        \\    bar,
        \\};
        \\
        \\test {
        \\    var e: E = undefined;
        \\    switch (e) {.<cursor>}
        \\}
        ,
        .label = "foo",
        .expected_insert_line = "    switch (e) {.foo}",
        .expected_replace_line = "    switch (e) {.foo}",
        .enable_snippets = true,
    });
}

test "insert replace behaviour - tagged union - zero-bit field" {
    try testCompletionTextEdit(.{
        .source =
        \\const U = union(enum) { alpha: void };
        \\const foo: U = .<cursor>
        ,
        .label = "alpha",
        .expected_insert_line = "const foo: U = .alpha",
        .expected_replace_line = "const foo: U = .alpha",
    });
    try testCompletionTextEdit(.{
        .source =
        \\const U = union(enum) { alpha: u0 };
        \\const foo: U = .<cursor>
        ,
        .label = "alpha",
        .expected_insert_line = "const foo: U = .alpha",
        .expected_replace_line = "const foo: U = .alpha",
    });
}

test "insert replace behaviour - doc test name" {
    try testCompletionTextEdit(.{
        .source =
        \\fn foo() void {};
        \\test <cursor>
        ,
        .label = "foo",
        .expected_insert_line = "test foo",
        .expected_replace_line = "test foo",
        .enable_snippets = true,
        .enable_argument_placeholders = true,
    });
    try testCompletionTextEdit(.{
        .source =
        \\fn foo() void {};
        \\test f<cursor> {}
        ,
        .label = "foo",
        .expected_insert_line = "test foo {}",
        .expected_replace_line = "test foo {}",
        .enable_snippets = true,
        .enable_argument_placeholders = true,
    });
    try testCompletionTextEdit(.{
        .source =
        \\fn foo() void {};
        \\test <cursor>oo {}
        ,
        .label = "foo",
        .expected_insert_line = "test foooo {}",
        .expected_replace_line = "test foo {}",
        .enable_snippets = true,
        .enable_argument_placeholders = true,
    });
}

test "insert replace behaviour - file system completions" {
    // zig fmt: off
    try testCompletionTextEdit(.{
        .source = \\const std = @import("<cursor>");
        , .label = "std"
        , .expected_insert_line = \\const std = @import("std");
        , .expected_replace_line = \\const std = @import("std");
        ,
    });
    try testCompletionTextEdit(.{
        .source = \\const std = @import("s<cursor>td");
        , .label = "std"
        , .expected_insert_line = \\const std = @import("stdtd");
        , .expected_replace_line = \\const std = @import("std");
        ,
    });
    try testCompletionTextEdit(.{
        .source = \\const std = @import("<cursor>std");
        , .label = "std"
        , .expected_insert_line = \\const std = @import("stdstd");
        , .expected_replace_line = \\const std = @import("std");
        ,
    });
    try testCompletionTextEdit(.{
        .source = \\const std = @import("<cursor>.zig");
        , .label = "std"
        , .expected_insert_line = \\const std = @import("std.zig");
        , .expected_replace_line = \\const std = @import("std");
        ,
    });
    try testCompletionTextEdit(.{
        .source = \\const std = @import("st<cursor>.zig");
        , .label = "std"
        , .expected_insert_line = \\const std = @import("std.zig");
        , .expected_replace_line = \\const std = @import("std");
        ,
    });
    if (true) return error.SkipZigTest; // TODO
    try testCompletionTextEdit(.{
        .source = \\const std = @import("file<cursor>.zig");
        , .label = "file.zig"
        , .expected_insert_line = \\const std = @import("file.zig");
        , .expected_replace_line = \\const std = @import("file.zig");
        ,
    });
    try testCompletionTextEdit(.{
        .source = \\const std = @import("fi<cursor>le.zig");
        , .label = "file.zig"
        , .expected_insert_line = \\const std = @import("filele.zig");
        , .expected_replace_line = \\const std = @import("file.zig");
        ,
    });
    // zig fmt: on
}

test "insert replace behaviour - expression inside parens/braces/brackets" {
    try testCompletionTextEdit(.{
        .source =
        \\const foo = 5;
        \\const bar = foo(<cursor>);
        ,
        .label = "foo",
        .expected_insert_line = "const bar = foo(foo);",
        .expected_replace_line = "const bar = foo(foo);",
    });
    try testCompletionTextEdit(.{
        .source =
        \\const foo = 5;
        \\const bar = foo(f<cursor>oo);
        ,
        .label = "foo",
        .expected_insert_line = "const bar = foo(foooo);",
        .expected_replace_line = "const bar = foo(foo);",
    });
    try testCompletionTextEdit(.{
        .source =
        \\const foo = 5;
        \\const bar = foo(<cursor>foo);
        ,
        .label = "foo",
        .expected_insert_line = "const bar = foo(foofoo);",
        .expected_replace_line = "const bar = foo(foo);",
    });
    try testCompletionTextEdit(.{
        .source =
        \\const foo = 5;
        \\const bar = foo{<cursor>};
        ,
        .label = "foo",
        .expected_insert_line = "const bar = foo{foo};",
        .expected_replace_line = "const bar = foo{foo};",
    });
    try testCompletionTextEdit(.{
        .source =
        \\const foo = 5;
        \\const bar = foo[<cursor>];
        ,
        .label = "foo",
        .expected_insert_line = "const bar = foo[foo];",
        .expected_replace_line = "const bar = foo[foo];",
    });
}

test "generic function with @This() as self param" {
    try testCompletion(
        \\const Foo = struct {
        \\    fn bar(_: *const @This(), comptime _: type) void {}
        \\};
        \\const foo: Foo = .{};
        \\const _ = foo.<cursor>
    , &.{
        .{
            .label = "bar",
            .kind = .Function,
            .detail = "fn (_: *const Foo, comptime _: type) void",
        },
    });
}

test "methods of branching type" {
    try testCompletion(
        \\const Reader = switch (undefined) {
        \\    .windows => struct {
        \\        fn foo(_: *Reader) bool {}
        \\    },
        \\    else => struct {
        \\        fn bar(_: *Reader) bool {}
        \\    },
        \\};
        \\test {
        \\    var reader: Reader = undefined;
        \\    reader.<cursor>
        \\}
    , &.{
        .{
            .label = "foo",
            .kind = .Function,
            .detail = "fn (_: *either type) bool",
        },
        .{
            .label = "bar",
            .kind = .Function,
            .detail = "fn (_: *either type) bool",
        },
    });
}

test "doctest name" {
    try testCompletion(
        \\fn foo() void {};
        \\test <cursor>
    , &.{
        .{ .label = "foo", .kind = .Function, .detail = "fn () void" },
    });
}

test "dot after try" {
    try testCompletion(
        \\const E = error{Err};
        \\const Foo = struct {
        \\  fn init() Foo { return undefined; }
        \\  fn initErr() E!Foo { return undefined; }
        \\};
        \\
        \\fn foo() !void {
        \\  const f: Foo = try .<cursor>
        \\}
    , &.{
        .{
            .label = "initErr",
            .kind = .Function,
            .detail = "fn () error{Err}!Foo",
        },
        .{
            .label = "init",
            .kind = .Function,
            .detail = "fn () Foo",
        },
    });
}

test "null-terminated slice" {
    try testCompletion(
        \\const foo = if (undefined) "a" else "ab";
        \\const bar = foo.<cursor>
    , &.{
        .{ .label = "len", .kind = .Field, .detail = "usize" },
        .{ .label = "ptr", .kind = .Field, .detail = "[*:0]const u8" },
    });
}

fn testCompletion(source: []const u8, expected_completions: []const Completion) !void {
    try testCompletionWithOptions(source, expected_completions, .{});
}

fn testCompletionWithOptions(
    source: []const u8,
    expected_completions: []const Completion,
    options: struct {
        enable_argument_placeholders: bool = true,
        enable_snippets: bool = true,
        completion_label_details: bool = true,
        check_order: bool = false,
        check_null_fields: bool = false,
        allow_additional_completions: bool = false,
    },
) !void {
    const cursor_idx = std.mem.find(u8, source, "<cursor>").?;
    const text = try std.mem.concat(allocator, u8, &.{ source[0..cursor_idx], source[cursor_idx + "<cursor>".len ..] });
    defer allocator.free(text);

    var ctx: Context = try .init();
    defer ctx.deinit();

    ctx.server.client_capabilities.completion_doc_supports_md = true;
    ctx.server.client_capabilities.supports_snippets = true;
    ctx.server.client_capabilities.label_details_support = true;
    ctx.server.client_capabilities.supports_completion_deprecated_old = true;
    ctx.server.client_capabilities.supports_completion_deprecated_tag = true;

    ctx.server.config_manager.config.enable_argument_placeholders = options.enable_argument_placeholders;
    ctx.server.config_manager.config.enable_snippets = options.enable_snippets;
    ctx.server.config_manager.config.completion_label_details = options.completion_label_details;

    const test_uri = try ctx.addDocument(.{ .source = text });

    const params: types.completion.Params = .{
        .textDocument = .{ .uri = test_uri.raw },
        .position = offsets.indexToPosition(source, cursor_idx, ctx.server.offset_encoding),
    };

    @setEvalBranchQuota(5000);
    const response = try ctx.server.sendRequestSync(ctx.arena.allocator(), "textDocument/completion", params);

    const completion_list: types.completion.List = (response orelse {
        if (expected_completions.len == 0) return;
        std.debug.print("Server returned `null` as the result\n", .{});
        return error.InvalidResponse;
    }).completion_list;

    for (completion_list.items) |item| {
        std.debug.assert(!(!options.enable_snippets and item.insertTextFormat == .Snippet));
        std.debug.assert(!(item.kind == .Snippet and item.insertTextFormat != .Snippet));
    }

    var actual = try extractCompletionLabels(completion_list.items);
    defer actual.deinit(allocator);

    var expected = try extractCompletionLabels(expected_completions);
    defer expected.deinit(allocator);

    var found = try set_intersection(actual, expected);
    defer found.deinit(allocator);

    var missing = try set_difference(expected, actual);
    defer missing.deinit(allocator);

    var unexpected = if (options.allow_additional_completions)
        std.array_hash_map.String(void).empty
    else
        try set_difference(actual, expected);
    defer unexpected.deinit(allocator);

    var error_builder: ErrorBuilder = .init(allocator);
    defer error_builder.deinit();
    errdefer error_builder.writeDebug();

    try error_builder.addFile(test_uri.raw, text);

    for (found.keys()) |label| {
        const actual_completion: types.completion.Item = blk: {
            for (completion_list.items) |item| {
                if (std.mem.eql(u8, label, item.label)) break :blk item;
            }
            unreachable;
        };

        const expected_completion: Completion = blk: {
            for (expected_completions) |item| {
                if (std.mem.eql(u8, label, item.label)) break :blk item;
            }
            unreachable;
        };

        if (actual_completion.kind == null or expected_completion.kind != actual_completion.kind.?) {
            try error_builder.msgAtIndex("completion item '{s}' should be of kind '{t}' but was '{?t}'!", test_uri.raw, cursor_idx, .err, .{
                label,
                expected_completion.kind,
                if (actual_completion.kind) |kind| kind else null,
            });
            return error.InvalidCompletionKind;
        }

        if (expected_completion.documentation) |expected_doc| doc_blk: {
            const actual_doc = if (actual_completion.documentation) |doc| blk: {
                const markup_context = doc.markup_content;
                try std.testing.expectEqual(types.MarkupKind.markdown, markup_context.kind);
                break :blk markup_context.value;
            } else null;

            if (actual_doc != null and std.mem.eql(u8, expected_doc, actual_doc.?)) break :doc_blk;

            try error_builder.msgAtIndex("completion item '{s}' should have doc '{f}' but was '{?f}'!", test_uri.raw, cursor_idx, .err, .{
                label,
                std.zig.fmtString(expected_doc),
                if (actual_doc) |str| std.zig.fmtString(str) else null,
            });
            return error.InvalidCompletionDoc;
        } else blk: {
            if (!options.check_null_fields) break :blk;
            const actual_doc = actual_completion.documentation orelse break :blk;
            try error_builder.msgAtIndex("completion item '{s}' has unexpected doc '{f}'", test_uri.raw, cursor_idx, .err, .{
                label,
                std.zig.fmtString(actual_doc.markup_content.value),
            });
            return error.InvalidCompletionDoc;
        }

        try std.testing.expect(actual_completion.insertText == null); // 'insertText' is subject to interpretation on the client so 'textEdit' should be preferred

        if (!ctx.server.client_capabilities.supports_snippets) {
            try std.testing.expectEqual(types.InsertTextFormat.PlainText, actual_completion.insertTextFormat orelse .PlainText);
        }

        if (expected_completion.detail) |expected_detail| blk: {
            if (actual_completion.detail != null and std.mem.eql(u8, expected_detail, actual_completion.detail.?)) break :blk;

            try error_builder.msgAtIndex("completion item '{s}' should have detail '{s}' but was '{?s}'!", test_uri.raw, cursor_idx, .err, .{
                label,
                expected_detail,
                actual_completion.detail,
            });
            return error.InvalidCompletionDetail;
        } else blk: {
            if (!options.check_null_fields) break :blk;
            const actual_detail = actual_completion.detail orelse break :blk;
            try error_builder.msgAtIndex("completion item '{s}' has unexpected detail '{s}'", test_uri.raw, cursor_idx, .err, .{
                label,
                actual_detail,
            });
            return error.InvalidCompletionDetail;
        }

        if (expected_completion.labelDetails) |expected_label_details| {
            const actual_label_details = actual_completion.labelDetails orelse {
                try error_builder.msgAtIndex("expected label details on completion item '{s}'!", test_uri.raw, cursor_idx, .err, .{label});
                return error.InvalidCompletionLabelDetails;
            };
            const detail_ok = (expected_label_details.detail == null and actual_label_details.detail == null) or
                (expected_label_details.detail != null and actual_label_details.detail != null and std.mem.eql(u8, expected_label_details.detail.?, actual_label_details.detail.?));

            if (!detail_ok) {
                try error_builder.msgAtIndex("completion item '{s}' should have label detail '{?s}' but was '{?s}'!", test_uri.raw, cursor_idx, .err, .{
                    label,
                    expected_label_details.detail,
                    actual_label_details.detail,
                });
                return error.InvalidCompletionLabelDetails;
            }

            const description_ok = (expected_label_details.description == null and actual_label_details.description == null) or
                (expected_label_details.description != null and actual_label_details.description != null and std.mem.eql(u8, expected_label_details.description.?, actual_label_details.description.?));

            if (!description_ok) {
                try error_builder.msgAtIndex("completion item '{s}' should have label detail description '{?s}' but was '{?s}'!", test_uri.raw, cursor_idx, .err, .{
                    label,
                    expected_label_details.description,
                    actual_label_details.description,
                });
                return error.InvalidCompletionLabelDetails;
            }
        } else blk: {
            if (!options.check_null_fields) break :blk;
            if (actual_completion.labelDetails == null) break :blk;
            try error_builder.msgAtIndex("completion item '{s}' has unexpected label details", test_uri.raw, cursor_idx, .err, .{
                label,
            });
            return error.InvalidCompletionLabelDetails;
        }

        blk: {
            const actual_deprecated = if (actual_completion.tags) |tags|
                std.mem.findScalar(types.completion.Item.Tag, tags, .Deprecated) != null
            else
                false;
            std.debug.assert(actual_deprecated == (actual_completion.deprecated orelse false));
            if (expected_completion.deprecated == actual_deprecated) break :blk;

            try error_builder.msgAtIndex("completion item '{s}' should {s} be marked as deprecated but {s}!", test_uri.raw, cursor_idx, .err, .{
                label,
                if (expected_completion.deprecated) "" else "not",
                if (actual_deprecated) "was" else "wasn't",
            });
            return error.InvalidCompletionDeprecation;
        }
    }

    if (missing.count() != 0 or unexpected.count() != 0) {
        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(allocator);

        try printLabels(&buffer, found, "found");
        try printLabels(&buffer, missing, "missing");
        try printLabels(&buffer, unexpected, "unexpected");
        try error_builder.msgAtIndex("invalid completions\n{s}", test_uri.raw, cursor_idx, .err, .{buffer.items});
        return error.MissingOrUnexpectedCompletions;
    }

    if (options.check_order) {
        const Item = types.completion.Item;

        const items: []Item = try allocator.dupe(Item, completion_list.items);
        defer allocator.free(items);

        std.mem.sort(Item, items, {}, struct {
            fn sort(_: void, lhs: Item, rhs: Item) bool {
                return std.mem.lessThan(u8, lhs.sortText.?, rhs.sortText.?);
            }
        }.sort);

        for (0..expected_completions.len) |i| {
            const expected_completion = expected_completions[i];
            const actual_completion = items[i];

            try std.testing.expectEqualStrings(expected_completion.label, actual_completion.label);
        }
    }
}

fn extractCompletionLabels(items: anytype) error{ DuplicateCompletionLabel, OutOfMemory }!std.array_hash_map.String(void) {
    var set: std.array_hash_map.String(void) = .empty;
    errdefer set.deinit(allocator);
    try set.ensureTotalCapacity(allocator, items.len);
    for (items) |item| {
        const maybe_kind = switch (@typeInfo(@TypeOf(item.kind))) {
            .optional => item.kind,
            else => @as(?@TypeOf(item.kind), item.kind),
        };
        if (maybe_kind) |kind| {
            switch (kind) {
                .Keyword, .Snippet => continue,
                else => {},
            }
        }
        if (set.fetchPutAssumeCapacity(item.label, {}) != null) return error.DuplicateCompletionLabel;
    }
    return set;
}

fn set_intersection(a: std.array_hash_map.String(void), b: std.array_hash_map.String(void)) error{OutOfMemory}!std.array_hash_map.String(void) {
    var result: std.array_hash_map.String(void) = .empty;
    errdefer result.deinit(allocator);
    for (a.keys()) |key| {
        if (b.contains(key)) try result.putNoClobber(allocator, key, {});
    }
    return result;
}

fn set_difference(a: std.array_hash_map.String(void), b: std.array_hash_map.String(void)) error{OutOfMemory}!std.array_hash_map.String(void) {
    var result: std.array_hash_map.String(void) = .empty;
    errdefer result.deinit(allocator);
    for (a.keys()) |key| {
        if (!b.contains(key)) try result.putNoClobber(allocator, key, {});
    }
    return result;
}

fn printLabels(output: *std.ArrayList(u8), labels: std.array_hash_map.String(void), name: []const u8) error{OutOfMemory}!void {
    if (labels.count() != 0) {
        try output.print(allocator, "{s}:\n", .{name});
        for (labels.keys()) |label| {
            try output.print(allocator, "  - {s}\n", .{label});
        }
    }
}

/// TODO this function should allow asserting where the cursor is placed after the text edit
fn testCompletionTextEdit(
    options: struct {
        source: []const u8,
        /// label of the completion item that should be applied
        label: []const u8,
        /// expected line when `textDocument.completion.insertReplaceSupport` is unset or the 'insert' text edit is applied.
        expected_insert_line: []const u8,
        /// expected line when `textDocument.completion.insertReplaceSupport` is set and the 'replace' text edit is applied.
        expected_replace_line: []const u8,

        enable_argument_placeholders: bool = false,
        enable_snippets: bool = false,
    },
) !void {
    const cursor_idx = std.mem.find(u8, options.source, "<cursor>").?;
    const text = try std.mem.concat(allocator, u8, &.{ options.source[0..cursor_idx], options.source[cursor_idx + "<cursor>".len ..] });
    defer allocator.free(text);

    const cursor_line_loc = offsets.lineLocAtIndex(text, cursor_idx);

    const expected_insert_text = try std.mem.concat(allocator, u8, &.{ text[0..cursor_line_loc.start], options.expected_insert_line, text[cursor_line_loc.end..] });
    defer allocator.free(expected_insert_text);

    const expected_replace_text = try std.mem.concat(allocator, u8, &.{ text[0..cursor_line_loc.start], options.expected_replace_line, text[cursor_line_loc.end..] });
    defer allocator.free(expected_replace_text);

    var ctx: Context = try .init();
    defer ctx.deinit();

    ctx.server.client_capabilities.supports_snippets = true;
    ctx.server.client_capabilities.supports_completion_insert_replace_support = true;

    ctx.server.config_manager.config.enable_argument_placeholders = options.enable_argument_placeholders;
    ctx.server.config_manager.config.enable_snippets = options.enable_snippets;

    const test_uri = try ctx.addDocument(.{ .source = text });

    const cursor_position = offsets.indexToPosition(options.source, cursor_idx, ctx.server.offset_encoding);
    const params: types.completion.Params = .{
        .textDocument = .{ .uri = test_uri.raw },
        .position = cursor_position,
    };

    @setEvalBranchQuota(5000);
    const response = try ctx.server.sendRequestSync(ctx.arena.allocator(), "textDocument/completion", params) orelse {
        std.debug.print("Server returned `null` as the result\n", .{});
        return error.InvalidResponse;
    };
    const completion_item = try searchCompletionItemWithLabel(response.completion_list, options.label);

    std.debug.assert(completion_item.additionalTextEdits == null); // unsupported
    std.debug.assert(!(!options.enable_snippets and completion_item.insertTextFormat == .Snippet));
    std.debug.assert(!(completion_item.kind == .Snippet and completion_item.insertTextFormat != .Snippet));

    // Assumes that a `insert_replace_edit` response is sent. This doesn't have to be the case if the text edits for insert and replace are the same.
    const edit: types.completion.Item.InsertReplaceEdit = completion_item.textEdit.?.insert_replace_edit;

    try std.testing.expect(edit.insert.start.line == edit.insert.end.line); // text edit range must be a single line
    try std.testing.expect(edit.replace.start.line == edit.replace.end.line); // text edit range must be a single line
    try std.testing.expect(offsets.positionInsideRange(cursor_position, edit.insert)); // text edit range must contain the cursor position
    try std.testing.expect(offsets.positionInsideRange(cursor_position, edit.replace)); // text edit range must contain the cursor position
    try std.testing.expect(offsets.orderPosition(edit.insert.start, edit.replace.start) == .eq); // insert and replace text edits must start at the same position
    try std.testing.expect(edit.insert.end.character <= edit.replace.end.character); // insert text edit must be a prefix of the replace text edit

    const insert_text_edit: types.TextEdit = .{ .newText = edit.newText, .range = edit.insert };
    const replace_text_edit: types.TextEdit = .{ .newText = edit.newText, .range = edit.replace };

    const actual_insert_text = try zls.diff.applyTextEdits(allocator, text, &.{insert_text_edit}, ctx.server.offset_encoding);
    defer allocator.free(actual_insert_text);

    const actual_replace_text = try zls.diff.applyTextEdits(allocator, text, &.{replace_text_edit}, ctx.server.offset_encoding);
    defer allocator.free(actual_replace_text);

    try std.testing.expectEqualStrings(expected_insert_text, actual_insert_text);
    try std.testing.expectEqualStrings(expected_replace_text, actual_replace_text);
}

fn searchCompletionItemWithLabel(completion_list: types.completion.List, label: []const u8) !types.completion.Item {
    for (completion_list.items) |item| {
        if (std.mem.eql(u8, item.label, label)) return item;
    }

    const stderr = std.debug.lockStderr(&.{}).terminal();
    defer std.debug.unlockStderr();

    try stderr.writer.print(
        \\server returned no completion item with label '{s}'
        \\
        \\labels:
        \\
    , .{label});
    for (completion_list.items) |item| {
        try stderr.writer.print("  - {s}\n", .{item.label});
    }

    return error.MissingCompletionItem;
}
