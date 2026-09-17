const std = @import("std");
const builtin = @import("builtin");
const zls = @import("zls");
const test_options = @import("test_options");

const io = std.testing.io;
const allocator = std.testing.allocator;

test "LSP lifecycle" {
    var environ_map: std.process.Environ.Map = .init(std.testing.failing_allocator);
    var config_manager: zls.configuration.Manager = try .init(io, allocator, &environ_map);
    defer config_manager.deinit();

    var arena_allocator: std.heap.ArenaAllocator = .init(allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    if (builtin.target.os.tag != .wasi) {
        const cwd = try std.process.currentPathAlloc(io, allocator);
        defer allocator.free(cwd);

        try config_manager.setConfiguration(.frontend, &.{
            .zig_exe_path = try std.Io.Dir.path.resolve(arena, &.{ cwd, test_options.zig_exe_path }),
            .zig_lib_path = try std.Io.Dir.path.resolve(arena, &.{ cwd, test_options.zig_lib_path }),
            .global_cache_path = try std.Io.Dir.path.resolve(arena, &.{ cwd, test_options.global_cache_path }),
        });
    }

    var server: *zls.Server = try .create(.{
        .io = io,
        .allocator = allocator,
        .transport = null,
        .config_manager = &config_manager,
    });
    defer server.destroy();

    try std.testing.expectEqual(zls.Server.Status.uninitialized, server.status);
    _ = try server.sendRequestSync(arena, "initialize", .{ .capabilities = .{} });
    try std.testing.expectEqual(zls.Server.Status.initializing, server.status);
    try server.sendNotificationSync(arena, "initialized", .{});
    try std.testing.expectEqual(zls.Server.Status.initialized, server.status);
    _ = try server.sendRequestSync(arena, "shutdown", {});
    try std.testing.expectEqual(zls.Server.Status.shutdown, server.status);
    try server.sendNotificationSync(arena, "exit", {});
    try std.testing.expectEqual(zls.Server.Status.exiting_success, server.status);
}

test "raw didChange messages update document text" {
    var environ_map: std.process.Environ.Map = .init(std.testing.failing_allocator);
    var config_manager: zls.configuration.Manager = try .init(io, allocator, &environ_map);
    defer config_manager.deinit();

    var arena_allocator: std.heap.ArenaAllocator = .init(allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    if (builtin.target.os.tag != .wasi) {
        const cwd = try std.process.currentPathAlloc(io, allocator);
        defer allocator.free(cwd);
        try config_manager.setConfiguration(.frontend, &.{
            .zig_exe_path = try std.Io.Dir.path.resolve(arena, &.{ cwd, test_options.zig_exe_path }),
            .zig_lib_path = try std.Io.Dir.path.resolve(arena, &.{ cwd, test_options.zig_lib_path }),
            .global_cache_path = try std.Io.Dir.path.resolve(arena, &.{ cwd, test_options.global_cache_path }),
        });
    }

    const server: *zls.Server = try .create(.{
        .io = io,
        .allocator = allocator,
        .transport = null,
        .config_manager = &config_manager,
    });
    defer server.destroy();
    _ = try server.sendRequestSync(arena, "initialize", .{ .capabilities = .{} });
    try server.sendNotificationSync(arena, "initialized", .{});

    const uri = "untitled:///change.zig";
    const document_uri = try zls.Uri.parse(arena, uri);
    try server.sendNotificationSync(arena, "textDocument/didOpen", .{ .textDocument = .{
        .uri = uri,
        .languageId = .{ .custom_value = "zig" },
        .version = 1,
        .text = "const value = 1;",
    } });

    try std.testing.expect((try server.sendJsonMessageSync(
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"untitled:///change.zig\",\"version\":2},\"contentChanges\":[{\"text\":\"const value = 2;\"}]}}",
    )) == null);
    try std.testing.expectEqualStrings("const value = 2;", server.document_store.getHandle(document_uri).?.tree.source);

    try std.testing.expect((try server.sendJsonMessageSync(
        "{\"params\":{\"contentChanges\":[{\"text\":\"other\",\"rangeLength\":5,\"range\":{\"start\":{\"line\":0,\"character\":6},\"end\":{\"line\":0,\"character\":11}}}],\"textDocument\":{\"version\":3,\"uri\":\"untitled:///change.zig\"}},\"method\":\"textDocument/didChange\",\"jsonrpc\":\"2.0\"}",
    )) == null);
    const changed_source = server.document_store.getHandle(document_uri).?.tree.source;
    try std.testing.expectEqualStrings("const other = 2;", changed_source);

    try std.testing.expect((try server.sendJsonMessageSync(
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{\"uri\":\"untitled:///change.zig\",\"version\":4},\"contentChanges\":[{\"range\":{\"start\":{\"line\":0,\"character\":6},\"end\":{\"line\":0,\"character\":11}},\"text\":\"other\"}]}}",
    )) == null);
    try std.testing.expectEqual(changed_source.ptr, server.document_store.getHandle(document_uri).?.tree.source.ptr);

    _ = try server.sendRequestSync(arena, "shutdown", {});
    try server.sendNotificationSync(arena, "exit", {});
}

test "file workspace during initialization" {
    try testFileWorkspace(.initialize);
}

test "file workspace added after initialization" {
    try testFileWorkspace(.did_change_workspace_folders);
}

const FileWorkspaceMode = enum { initialize, did_change_workspace_folders };

fn testFileWorkspace(mode: FileWorkspaceMode) !void {
    if (builtin.target.os.tag == .wasi) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "Translator.zig",
        .data = "const answer = 42;\n",
    });

    const file_path = try tmp.dir.realPathFileAlloc(io, "Translator.zig", allocator);
    defer allocator.free(file_path);
    const file_uri: zls.Uri = try .fromPath(allocator, file_path);
    defer file_uri.deinit(allocator);

    var environ_map: std.process.Environ.Map = .init(std.testing.failing_allocator);
    var config_manager: zls.configuration.Manager = try .init(io, allocator, &environ_map);
    defer config_manager.deinit();

    var arena_allocator: std.heap.ArenaAllocator = .init(allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    try config_manager.setConfiguration(.frontend, &.{
        .enable_build_on_save = true,
        .zig_exe_path = try std.Io.Dir.path.resolve(arena, &.{ cwd, test_options.zig_exe_path }),
        .zig_lib_path = try std.Io.Dir.path.resolve(arena, &.{ cwd, test_options.zig_lib_path }),
        .global_cache_path = try std.Io.Dir.path.resolve(arena, &.{ cwd, test_options.global_cache_path }),
    });

    var server: *zls.Server = try .create(.{
        .io = io,
        .allocator = allocator,
        .transport = null,
        .config_manager = &config_manager,
    });
    defer server.destroy();

    const workspace_folders: []const zls.lsp.types.workspace.Folder = &.{.{
        .uri = file_uri.raw,
        .name = "Translator.zig",
    }};
    _ = try server.sendRequestSync(arena, "initialize", .{
        .capabilities = .{
            .textDocument = .{
                .publishDiagnostics = .{},
            },
        },
        .workspaceFolders = if (mode == .initialize) workspace_folders else null,
    });
    try server.sendNotificationSync(arena, "initialized", .{});

    if (mode == .did_change_workspace_folders) {
        try server.sendNotificationSync(arena, "workspace/didChangeWorkspaceFolders", .{
            .event = .{
                .added = workspace_folders,
                .removed = &.{},
            },
        });
    }

    try std.testing.expect(server.document_store.getHandle(file_uri) != null);
    try std.testing.expectEqual(@as(usize, 1), server.workspaces.items.len);
    try std.testing.expect(server.workspaces.items[0].build_on_save_mode == null);
    try std.testing.expect(server.workspaces.items[0].build_on_save == null);

    _ = try server.sendRequestSync(arena, "shutdown", {});
    try server.sendNotificationSync(arena, "exit", {});
    try std.testing.expectEqual(zls.Server.Status.exiting_success, server.status);
}
