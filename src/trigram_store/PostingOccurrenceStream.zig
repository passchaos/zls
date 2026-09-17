const std = @import("std");

const PostingOccurrenceStream = @This();

pub const small_end_marker = std.math.maxInt(u16);
pub const large_end_marker = std.math.maxInt(u32);

small: std.ArrayList(u16) = .empty,
large: ?std.ArrayList(u32) = null,

pub fn deinit(stream: *PostingOccurrenceStream, allocator: std.mem.Allocator) void {
    stream.clearAndFree(allocator);
    stream.* = undefined;
}

pub fn clearAndFree(stream: *PostingOccurrenceStream, allocator: std.mem.Allocator) void {
    stream.small.deinit(allocator);
    if (stream.large) |*large| large.deinit(allocator);
    stream.* = .{};
}

pub fn appendPostingIndex(
    stream: *PostingOccurrenceStream,
    allocator: std.mem.Allocator,
    index: usize,
) error{OutOfMemory}!void {
    if (index >= large_end_marker) return error.OutOfMemory;
    if (stream.large) |*large| {
        try large.append(allocator, @intCast(index));
        return;
    }
    if (index < small_end_marker) {
        try stream.small.append(allocator, @intCast(index));
        return;
    }

    var large: std.ArrayList(u32) = .empty;
    errdefer large.deinit(allocator);
    try large.ensureTotalCapacity(allocator, stream.small.items.len + 1);
    for (stream.small.items) |entry| {
        large.appendAssumeCapacity(if (entry == small_end_marker) large_end_marker else entry);
    }
    large.appendAssumeCapacity(@intCast(index));
    stream.small.deinit(allocator);
    stream.small = .empty;
    stream.large = large;
}

pub fn appendDeclarationEnd(
    stream: *PostingOccurrenceStream,
    allocator: std.mem.Allocator,
) error{OutOfMemory}!void {
    if (stream.large) |*large| {
        try large.append(allocator, large_end_marker);
    } else {
        try stream.small.append(allocator, small_end_marker);
    }
}

test PostingOccurrenceStream {
    const allocator = std.testing.allocator;
    var stream: PostingOccurrenceStream = .{};
    defer stream.deinit(allocator);

    try stream.appendPostingIndex(allocator, 1);
    try stream.appendDeclarationEnd(allocator);
    try std.testing.expectEqualSlices(u16, &.{ 1, small_end_marker }, stream.small.items);
    try std.testing.expect(stream.large == null);

    try stream.appendPostingIndex(allocator, small_end_marker);
    try std.testing.expectEqual(@as(usize, 0), stream.small.items.len);
    try std.testing.expectEqualSlices(u32, &.{ 1, large_end_marker, small_end_marker }, stream.large.?.items);

    try stream.appendDeclarationEnd(allocator);
    try std.testing.expectEqual(large_end_marker, stream.large.?.getLast());
}

test "upgrade preserves a populated small stream" {
    const allocator = std.testing.allocator;
    var stream: PostingOccurrenceStream = .{};
    defer stream.deinit(allocator);

    for (0..256) |index| try stream.appendPostingIndex(allocator, index);
    try stream.appendDeclarationEnd(allocator);
    try stream.appendPostingIndex(allocator, small_end_marker);

    const large = stream.large.?.items;
    try std.testing.expectEqual(@as(usize, 258), large.len);
    for (large[0..256], 0..) |entry, index| try std.testing.expectEqual(index, entry);
    try std.testing.expectEqual(large_end_marker, large[256]);
    try std.testing.expectEqual(@as(u32, small_end_marker), large[257]);
}
