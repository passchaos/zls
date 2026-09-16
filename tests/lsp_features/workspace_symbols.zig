const std = @import("std");
const zls = @import("zls");

const Context = @import("../context.zig").Context;

const types = zls.lsp.types;

const allocator: std.mem.Allocator = std.testing.allocator;

test "workspace symbols" {
    var ctx: Context = try .init();
    defer ctx.deinit();

    try ctx.addWorkspace("Animal Shelter", "/animal_shelter/");

    _ = try ctx.addDocument(.{ .source =
        \\const SalamanderCrab = struct {
        \\    fn salamander_crab() void {}
        \\};
        \\test "国際化" {}
    , .base_directory = "/animal_shelter/" });

    _ = try ctx.addDocument(.{ .source =
        \\const Dog = struct {
        \\    const sheltie: Dog = .{};
        \\    var @"Mr Crabs" = @compileError("hold up");
        \\};
        \\test "walk the dog" {
        \\    const dog: Dog = .sheltie;
        \\    _ = dog; // nah
        \\}
    , .base_directory = "/animal_shelter/" });

    _ = try ctx.addDocument(.{ .source =
        \\const Lion = struct {
        \\    extern fn evolveToMonke() void;
        \\    fn roar() void {
        \\        var lion = "cool!";
        \\        const Lion2 = struct {
        \\            const lion_for_real = 0;
        \\        };
        \\    }
        \\};
    , .base_directory = "/animal_shelter/" });

    _ = try ctx.addDocument(.{ .source =
        \\const PotatoDoctor = struct {};
    , .base_directory = "/farm/" });

    try testDocumentSymbol(&ctx, "Sal",
        \\Constant SalamanderCrab
        \\Function salamander_crab
    );
    try testDocumentSymbol(&ctx, "_cr___a_b_",
        \\Constant SalamanderCrab
        \\Function salamander_crab
        \\Variable @"Mr Crabs"
    );
    try testDocumentSymbol(&ctx, "dog",
        \\Constant Dog
        \\Method walk the dog
    );
    try testDocumentSymbol(&ctx, "potato_d", "");
    // Becomes S\x00\x00 which matches nothing
    try testDocumentSymbol(&ctx, "S", "");
    try testDocumentSymbol(&ctx, "lion",
        \\Constant Lion
        \\Constant lion_for_real
    );
    try testDocumentSymbol(&ctx, "monke",
        \\Function evolveToMonke
    );
    try testDocumentSymbol(&ctx, "国際",
        \\Method 国際化
    );

    const unicode_response = try ctx.server.sendRequestSync(
        ctx.arena.allocator(),
        "workspace/symbol",
        .{ .query = "国際" },
    ) orelse return error.InvalidResponse;
    try std.testing.expectEqual(@as(usize, 1), unicode_response.workspace_symbols.len);
    try std.testing.expectEqualDeep(
        types.Range{
            .start = .{ .line = 3, .character = 5 },
            .end = .{ .line = 3, .character = 10 },
        },
        unicode_response.workspace_symbols[0].location.location.range,
    );

    for (0..64) |_| {
        _ = try ctx.addDocument(.{
            .source = "",
            .base_directory = "/animal_shelter/",
        });
    }
    try testDocumentSymbol(&ctx, "no_such_symbol", "");
}

test "workspace symbol ranges across long Unicode spans" {
    const source = "// " ++ "¶↉🠁" ** 16 ++ "\r\n" ++
        "const @\"symbol¶↉🠁\" = struct {\r\n" ++
        "    // " ++ "¶↉🠁" ** 16 ++ "\r\n" ++
        "    const symbol_ascii = 0;\r\n};";
    const names = [_][]const u8{ "@\"symbol¶↉🠁\"", "symbol_ascii" };

    for ([_]zls.offsets.Encoding{ .@"utf-8", .@"utf-16", .@"utf-32" }) |encoding| {
        var ctx: Context = try .init();
        defer ctx.deinit();
        ctx.server.offset_encoding = encoding;
        try ctx.addWorkspace("Unicode", "/unicode/");
        const uri = try ctx.addDocument(.{ .source = source, .base_directory = "/unicode/" });
        const response = try ctx.server.sendRequestSync(
            ctx.arena.allocator(),
            "workspace/symbol",
            .{ .query = "symbol" },
        ) orelse return error.InvalidResponse;

        try std.testing.expectEqual(names.len, response.workspace_symbols.len);
        for (response.workspace_symbols, names) |symbol, name| {
            const start = std.mem.find(u8, source, name).?;
            const location = symbol.location.location;
            try std.testing.expectEqualStrings(uri.raw, location.uri);
            try std.testing.expectEqualDeep(types.Range{
                .start = zls.offsets.indexToPosition(source, start, encoding),
                .end = zls.offsets.indexToPosition(source, start + name.len, encoding),
            }, location.range);
        }
    }
}

fn testDocumentSymbol(ctx: *Context, query: []const u8, expected: []const u8) !void {
    const response = try ctx.server.sendRequestSync(
        ctx.arena.allocator(),
        "workspace/symbol",
        .{ .query = query },
    ) orelse {
        std.debug.print("Server returned `null` as the result\n", .{});
        return error.InvalidResponse;
    };

    var actual: std.ArrayList(u8) = .empty;
    defer actual.deinit(allocator);

    for (response.workspace_symbols) |workspace_symbol| {
        std.debug.assert(workspace_symbol.tags == null); // unsupported for now
        std.debug.assert(workspace_symbol.containerName == null); // unsupported for now
        try actual.print(allocator, "{t} {s}\n", .{
            workspace_symbol.kind,
            workspace_symbol.name,
        });
    }

    if (actual.items.len != 0) {
        _ = actual.pop(); // Final \n
    }

    try zls.testing.expectEqualStrings(expected, actual.items);
}
