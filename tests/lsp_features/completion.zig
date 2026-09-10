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

test "generic function with comptime labeled block breaks" {
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

test "zero-parameter type function comptime evaluation" {
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

    var unexpected = try set_difference(actual, expected);
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
