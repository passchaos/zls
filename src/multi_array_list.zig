const std = @import("std");

/// Shrinks a MultiArrayList to its current length. The fields are first
/// compacted within the existing backing allocation so allocators that support
/// in-place shrinking can avoid allocating and copying a second buffer.
pub fn shrinkAndFree(allocator: std.mem.Allocator, list: anytype) error{OutOfMemory}!void {
    if (list.capacity == list.len) return;
    if (list.len == 0) {
        list.clearAndFree(allocator);
        return;
    }

    const List = @TypeOf(list.*);
    const fields = std.enums.values(List.Field);
    const old_slice = list.slice();
    const old_byte_len = List.capacityInBytes(list.capacity);
    const new_byte_len = List.capacityInBytes(list.len);

    comptime var max_alignment: usize = 1;
    inline for (fields) |field| {
        const Field = @typeInfo(@TypeOf(old_slice.items(field))).pointer.child;
        max_alignment = @max(max_alignment, @alignOf(Field));
    }

    // Compact fields toward the beginning in physical allocation order so
    // that unread source data is never overwritten.
    for (0..fields.len) |physical_index| {
        inline for (fields) |field| {
            var field_physical_index: usize = 0;
            inline for (fields) |other| {
                field_physical_index += @intFromBool(
                    @intFromPtr(old_slice.ptrs[@intFromEnum(other)]) <
                        @intFromPtr(old_slice.ptrs[@intFromEnum(field)]),
                );
            }
            if (field_physical_index == physical_index) {
                const Field = @typeInfo(@TypeOf(old_slice.items(field))).pointer.child;
                var destination_offset: usize = 0;
                inline for (fields) |other| {
                    const Other = @typeInfo(@TypeOf(old_slice.items(other))).pointer.child;
                    if (@intFromPtr(old_slice.ptrs[@intFromEnum(other)]) <
                        @intFromPtr(old_slice.ptrs[@intFromEnum(field)]))
                    {
                        destination_offset += @sizeOf(Other) * list.len;
                    }
                }
                const destination: [*]Field = @ptrCast(@alignCast(list.bytes + destination_offset));
                @memmove(destination[0..list.len], old_slice.items(field));
            }
        }
    }

    const alignment: std.mem.Alignment = .fromByteUnits(max_alignment);
    if (allocator.rawResize(list.bytes[0..old_byte_len], alignment, new_byte_len, @returnAddress())) {
        list.capacity = list.len;
        return;
    }

    // Restore the original field layout in reverse physical order before
    // falling back to MultiArrayList's allocating implementation.
    var physical_index = fields.len;
    while (physical_index != 0) {
        physical_index -= 1;
        inline for (fields) |field| {
            var field_physical_index: usize = 0;
            inline for (fields) |other| {
                field_physical_index += @intFromBool(
                    @intFromPtr(old_slice.ptrs[@intFromEnum(other)]) <
                        @intFromPtr(old_slice.ptrs[@intFromEnum(field)]),
                );
            }
            if (field_physical_index == physical_index) {
                const Field = @typeInfo(@TypeOf(old_slice.items(field))).pointer.child;
                var source_offset: usize = 0;
                inline for (fields) |other| {
                    const Other = @typeInfo(@TypeOf(old_slice.items(other))).pointer.child;
                    if (@intFromPtr(old_slice.ptrs[@intFromEnum(other)]) <
                        @intFromPtr(old_slice.ptrs[@intFromEnum(field)]))
                    {
                        source_offset += @sizeOf(Other) * list.len;
                    }
                }
                const source: [*]const Field = @ptrCast(@alignCast(list.bytes + source_offset));
                @memmove(old_slice.items(field), source[0..list.len]);
            }
        }
    }
    try list.setCapacity(allocator, list.len);
}

test "in-place compaction preserves multi-array fields" {
    const Item = struct { large: u64, small: u8, medium: u32 };
    var backing: [2048]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&backing);
    const allocator = fixed.allocator();

    var list: std.MultiArrayList(Item) = .empty;
    defer list.deinit(allocator);
    try list.ensureTotalCapacity(allocator, 32);
    for (0..11) |index| {
        try list.append(allocator, .{
            .large = index * 101,
            .small = @intCast(index),
            .medium = @intCast(index * 17),
        });
    }

    const bytes_before = fixed.end_index;
    try shrinkAndFree(allocator, &list);
    try std.testing.expectEqual(list.len, list.capacity);
    try std.testing.expect(fixed.end_index < bytes_before);
    try expectTestItems(list);
}

test "multi-array compaction falls back safely" {
    const Item = struct { large: u64, small: u8, medium: u32 };
    var empty: std.MultiArrayList(Item) = .empty;
    try shrinkAndFree(std.testing.allocator, &empty);
    try std.testing.expectEqual(0, empty.capacity);

    var list: std.MultiArrayList(Item) = .empty;
    defer list.deinit(std.testing.allocator);
    try list.ensureTotalCapacity(std.testing.allocator, 32);
    for (0..11) |index| {
        try list.append(std.testing.allocator, .{
            .large = index * 101,
            .small = @intCast(index),
            .medium = @intCast(index * 17),
        });
    }

    const old_capacity = list.capacity;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
        .resize_fail_index = 0,
    });
    try std.testing.expectError(error.OutOfMemory, shrinkAndFree(failing.allocator(), &list));
    try std.testing.expectEqual(old_capacity, list.capacity);
    try expectTestItems(list);

    var fallback = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .resize_fail_index = 0,
    });
    try shrinkAndFree(fallback.allocator(), &list);
    try std.testing.expectEqual(list.len, list.capacity);
    try std.testing.expectEqual(1, fallback.allocations);
    try expectTestItems(list);
}

fn expectTestItems(list: anytype) !void {
    for (0..list.len) |index| {
        try std.testing.expectEqual(@as(u64, index * 101), list.items(.large)[index]);
        try std.testing.expectEqual(@as(u8, @intCast(index)), list.items(.small)[index]);
        try std.testing.expectEqual(@as(u32, @intCast(index * 17)), list.items(.medium)[index]);
    }
}
