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
    if (request.query.len == 0) return null;

    var workspace_uris: std.ArrayList(Uri.SchemeAndPath) = try .initCapacity(arena, server.workspaces.items.len);
    defer workspace_uris.deinit(arena);

    for (server.workspaces.items) |workspace| {
        workspace_uris.appendAssumeCapacity(workspace.uri.schemeAndPath());
    }

    var handles = try server.document_store.loadTrigramStoreList(workspace_uris.items);
    defer handles.deinit(server.document_store.allocator);

    var symbols: std.ArrayList(types.workspace.Symbol) = .empty;
    var declaration_stack = std.heap.stackFallback(512, server.document_store.allocator);
    const declaration_allocator = declaration_stack.get();
    var declaration_buffer: std.ArrayList(TrigramStore.Declaration.Index) = .empty;
    defer declaration_buffer.deinit(declaration_allocator);
    var prepared_query: ?TrigramStore.Query = if (handles.items.len > 1) try .init(arena, request.query) else null;
    defer if (prepared_query) |*query| query.deinit(arena);

    for (handles.items) |handle| {
        const trigram_store = handle.trigram_store.getCached();

        declaration_buffer.clearRetainingCapacity();
        const declarations = if (prepared_query) |*query|
            try trigram_store.declarationSliceForPreparedQuery(declaration_allocator, query, &declaration_buffer)
        else
            try trigram_store.declarationSliceForQuery(declaration_allocator, request.query, &declaration_buffer);

        const slice = trigram_store.declarations.slice();
        const names = slice.items(.name);
        const name_lengths = slice.items(.name_len);
        const kinds = slice.items(.kind);

        var last_index: usize = 0;
        var last_position: offsets.Position = .{ .line = 0, .character = 0 };

        try symbols.ensureUnusedCapacity(arena, declarations.len);
        for (declarations) |declaration| {
            const name_token = names[@intFromEnum(declaration)];
            const name_len = name_lengths[@intFromEnum(declaration)];
            const kind = kinds[@intFromEnum(declaration)];

            const start = handle.tree.tokenStart(name_token);
            const loc: offsets.Loc = .{ .start = start, .end = start + name_len.bytes };
            const name = @import("document_symbol.zig").tokenNameFromSlice(
                handle.tree.source[loc.start..loc.end],
                handle.tree.tokenTag(name_token),
            );

            const start_position = offsets.advancePosition(handle.tree.source, last_position, last_index, loc.start, server.offset_encoding);
            const end_position: offsets.Position = if (server.offset_encoding == .@"utf-8" or name_len.is_ascii)
                .{ .line = start_position.line, .character = start_position.character + name_len.bytes }
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
                    .location = .{
                        .uri = handle.uri.raw,
                        .range = .{
                            .start = start_position,
                            .end = end_position,
                        },
                    },
                },
            });
        }
    }

    return .{ .workspace_symbols = symbols.items };
}
