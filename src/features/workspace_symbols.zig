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

    const handles = try server.document_store.loadTrigramStores(workspace_uris.items);
    defer server.document_store.allocator.free(handles);

    var symbols: std.ArrayList(types.workspace.Symbol) = .empty;
    var declaration_buffer: std.ArrayList(TrigramStore.Declaration.Index) = .empty;
    var prepared_query: ?TrigramStore.Query = if (handles.len > 1) try .init(arena, request.query) else null;
    defer if (prepared_query) |*query| query.deinit(arena);

    for (handles) |handle| {
        const trigram_store = handle.trigram_store.getCached();

        declaration_buffer.clearRetainingCapacity();
        if (prepared_query) |*query| {
            try trigram_store.declarationsForPreparedQuery(arena, query, &declaration_buffer);
        } else {
            try trigram_store.declarationsForQuery(arena, request.query, &declaration_buffer);
        }

        const slice = trigram_store.declarations.slice();
        const names = slice.items(.name);
        const kinds = slice.items(.kind);

        var last_index: usize = 0;
        var last_position: offsets.Position = .{ .line = 0, .character = 0 };

        try symbols.ensureUnusedCapacity(arena, declaration_buffer.items.len);
        for (declaration_buffer.items) |declaration| {
            const name_token = names[@intFromEnum(declaration)];
            const kind = kinds[@intFromEnum(declaration)];

            const loc = offsets.tokenToLoc(&handle.tree, name_token);
            const name = @import("document_symbol.zig").tokenNameMaybeQuotes(&handle.tree, name_token);

            const start_position = offsets.advancePosition(handle.tree.source, last_position, last_index, loc.start, server.offset_encoding);
            const end_position = offsets.advancePosition(handle.tree.source, start_position, loc.start, loc.end, server.offset_encoding);
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
