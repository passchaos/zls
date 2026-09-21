//! Implementation of [`workspace/symbol`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#workspace_symbol)

const std = @import("std");

const lsp = @import("lsp");
const types = lsp.types;

const DocumentStore = @import("../DocumentStore.zig");
const offsets = @import("../offsets.zig");
const Server = @import("../Server.zig");
const TrigramStore = @import("../TrigramStore.zig");
const Uri = @import("../Uri.zig");

pub fn handler(server: *Server, arena: std.mem.Allocator, request: types.workspace.Symbol.Params) error{ OutOfMemory, Canceled }!?types.workspace.Symbol.Result {
    var workspace_uri_stack = std.heap.stackFallback(512, server.document_store.allocator);
    const workspace_uri_allocator = workspace_uri_stack.get();
    var workspace_uris: std.ArrayList(Uri.SchemeAndPath) = try .initCapacity(workspace_uri_allocator, server.workspaces.items.len);
    defer workspace_uris.deinit(workspace_uri_allocator);

    for (server.workspaces.items) |workspace| {
        workspace_uris.appendAssumeCapacity(workspace.uri.schemeAndPath());
    }

    const handle_stack_size = 512;
    var handle_stack = std.heap.stackFallback(handle_stack_size, server.document_store.allocator);
    const handle_allocator = handle_stack.get();
    var handles = try server.document_store.loadTrigramStoreList(
        workspace_uris.items,
        handle_allocator,
        handle_stack_size / @sizeOf(*DocumentStore.Handle),
    );
    defer handles.deinit(handle_allocator);

    var symbols: std.ArrayList(types.SymbolInformation) = .empty;
    var declaration_stack = std.heap.stackFallback(512, server.document_store.allocator);
    const declaration_allocator = declaration_stack.get();
    var declaration_buffer: std.ArrayList(TrigramStore.Declaration.Index) = .empty;
    defer declaration_buffer.deinit(declaration_allocator);
    var prepared_query: ?TrigramStore.Query = if (request.query.len != 0 and handles.items.len > 1) try .init(arena, request.query) else null;
    defer if (prepared_query) |*query| query.deinit(arena);

    for (handles.items) |handle| {
        const trigram_store = handle.trigram_store.getCached();

        declaration_buffer.clearRetainingCapacity();
        const declarations = if (request.query.len == 0) all: {
            try declaration_buffer.resize(declaration_allocator, trigram_store.declarations.len);
            for (declaration_buffer.items, 0..) |*declaration, index| {
                declaration.* = @enumFromInt(index);
            }
            break :all declaration_buffer.items;
        } else if (prepared_query) |*query|
            try trigram_store.declarationSliceForPreparedQuery(declaration_allocator, query, &declaration_buffer)
        else
            try trigram_store.declarationSliceForQuery(declaration_allocator, request.query, &declaration_buffer);

        const slice = trigram_store.declarations.slice();
        const names = slice.items(.name);
        const kinds = slice.items(.kind);

        var last_index: usize = 0;
        var last_position: offsets.Position = .{ .line = 0, .character = 0 };

        try symbols.ensureUnusedCapacity(arena, declarations.len);
        for (declarations) |declaration| {
            const name_token = names[@intFromEnum(declaration)];
            const cached_position = trigram_store.declarationPosition(declaration);
            const kind = kinds[@intFromEnum(declaration)];

            const start = handle.tree.tokenStart(name_token);
            const raw_name = if (cached_position.name_len) |name_len|
                handle.tree.source[start..][0..name_len]
            else
                handle.tree.tokenSlice(name_token);
            const loc: offsets.Loc = .{ .start = start, .end = start + raw_name.len };
            const name = @import("document_symbol.zig").tokenNameFromSlice(
                raw_name,
                handle.tree.tokenTag(name_token),
            );

            const start_position: offsets.Position = if (cached_position.line) |line| blk: {
                const line_start = if (std.mem.findScalarLast(u8, handle.tree.source[0..loc.start], '\n')) |newline| newline + 1 else 0;
                break :blk offsets.advancePosition(
                    handle.tree.source,
                    .{ .line = line, .character = 0 },
                    line_start,
                    loc.start,
                    server.offset_encoding,
                );
            } else blk: {
                const position = offsets.advancePosition(handle.tree.source, last_position, last_index, loc.start, server.offset_encoding);
                trigram_store.cacheDeclarationLine(declaration, position.line);
                break :blk position;
            };
            const end_position: offsets.Position = if (server.offset_encoding == .@"utf-8" or cached_position.is_ascii)
                .{ .line = start_position.line, .character = start_position.character + @as(u32, @intCast(raw_name.len)) }
            else
                offsets.advancePosition(handle.tree.source, start_position, loc.start, loc.end, server.offset_encoding);
            last_index = loc.end;
            last_position = end_position;

            symbols.appendAssumeCapacity(.{
                .name = name,
                .kind = switch (kind) {
                    .variable => .Variable,
                    .constant => .Constant,
                    .field => .Field,
                    .function => .Function,
                    .test_function => .Method, // there is no SymbolKind that represents a tests,
                },
                .location = .{
                    .uri = handle.uri.raw,
                    .range = .{
                        .start = start_position,
                        .end = end_position,
                    },
                },
            });
        }
    }

    return .{ .symbol_informations = symbols.items };
}
