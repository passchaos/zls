//! A per-file trigram store for workspace symbols.

const std = @import("std");
const ast = @import("ast.zig");
const Ast = std.zig.Ast;
const assert = std.debug.assert;
const offsets = @import("offsets.zig");
const multi_array_list = @import("multi_array_list.zig");

pub const TrigramStore = @This();

pub const Trigram = [3]u8;

const TrigramContext = struct {
    fn toInt(trigram: Trigram) u32 {
        return @as(u32, trigram[0]) |
            (@as(u32, trigram[1]) << 8) |
            (@as(u32, trigram[2]) << 16);
    }

    pub fn hash(_: TrigramContext, trigram: Trigram) u32 {
        return std.hash.int(toInt(trigram));
    }

    pub fn eql(_: TrigramContext, a: Trigram, b: Trigram, _: usize) bool {
        return toInt(a) == toInt(b);
    }
};

pub const Declaration = struct {
    pub const Index = enum(u32) { _ };

    pub const Kind = enum {
        variable,
        constant,
        field,
        function,
        test_function,
    };

    /// Either `.identifier` or `.string_literal`.
    name: Ast.TokenIndex,
    name_len: packed struct(u32) {
        bytes: u31,
        is_ascii: bool,
    },
    kind: Kind,
};

const PostingList = struct {
    start: u32,
    len: u32,

    fn slice(list: PostingList, postings: []const Declaration.Index) []const Declaration.Index {
        return postings[list.start..][0..list.len];
    }
};

comptime {
    assert(@sizeOf(PostingList) == 2 * @sizeOf(u32));
}

const PostingMap = std.array_hash_map.Custom(Trigram, PostingList, TrigramContext, false);
const PostingListBuilderValue = struct {
    const OptionalIndex = enum(u32) {
        none = std.math.maxInt(u32),
        _,

        fn from(index: Declaration.Index) OptionalIndex {
            const value = @intFromEnum(index);
            assert(value != @intFromEnum(OptionalIndex.none));
            return @enumFromInt(value);
        }

        fn unwrap(index: OptionalIndex) ?Declaration.Index {
            return if (index == .none) null else @enumFromInt(@intFromEnum(index));
        }
    };

    first: Declaration.Index,
    second: OptionalIndex = .none,
    rest: std.ArrayList(Declaration.Index) = .empty,

    fn len(list: PostingListBuilderValue) usize {
        return 1 + @as(usize, @intFromBool(list.second != .none)) + list.rest.items.len;
    }

    fn last(list: PostingListBuilderValue) Declaration.Index {
        return list.rest.getLastOrNull() orelse list.second.unwrap() orelse list.first;
    }

    fn append(list: *PostingListBuilderValue, allocator: std.mem.Allocator, index: Declaration.Index) error{OutOfMemory}!void {
        if (list.last() == index) return;
        if (list.second == .none) {
            list.second = .from(index);
        } else {
            try list.rest.append(allocator, index);
        }
    }

    fn deinit(list: *PostingListBuilderValue, allocator: std.mem.Allocator) void {
        list.rest.deinit(allocator);
    }
};
comptime {
    assert(@sizeOf(PostingListBuilderValue) == 32);
}
const PostingListBuilder = std.array_hash_map.Custom(Trigram, PostingListBuilderValue, TrigramContext, false);

test PostingListBuilderValue {
    const first: Declaration.Index = @enumFromInt(3);
    const second: Declaration.Index = @enumFromInt(7);
    var list: PostingListBuilderValue = .{ .first = first };
    defer list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), list.len());
    try std.testing.expectEqual(first, list.last());
    try std.testing.expectEqual(@as(usize, 0), list.rest.capacity);

    try list.append(std.testing.allocator, first);
    try std.testing.expectEqual(@as(usize, 1), list.len());
    try std.testing.expectEqual(@as(usize, 0), list.rest.capacity);

    try list.append(std.testing.allocator, second);
    try std.testing.expectEqual(@as(usize, 2), list.len());
    try std.testing.expectEqual(second, list.last());
    try std.testing.expectEqual(@as(usize, 0), list.rest.capacity);

    const third: Declaration.Index = @enumFromInt(11);
    try list.append(std.testing.allocator, third);
    try std.testing.expectEqual(@as(usize, 3), list.len());
    try std.testing.expectEqual(third, list.last());
    try std.testing.expect(list.rest.capacity >= 1);
}

const PreparedTrigram = struct {
    value: Trigram,
    map_hash: u32,
};

const PreparedTrigramContext = struct {
    pub fn hash(_: PreparedTrigramContext, trigram: PreparedTrigram) u32 {
        return trigram.map_hash;
    }

    pub fn eql(_: PreparedTrigramContext, a: PreparedTrigram, b: Trigram, _: usize) bool {
        return TrigramContext.toInt(a.value) == TrigramContext.toInt(b);
    }
};

/// A normalized, pre-hashed workspace-symbol query that can be reused across
/// multiple stores. Queries of up to 18 non-underscore characters stay inline.
pub const Query = struct {
    const inline_capacity = 16;
    const deduplicate_scan_limit = 32;

    inline_trigrams: [inline_capacity]PreparedTrigram = undefined,
    heap_trigrams: ?[]PreparedTrigram = null,
    len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, text: []const u8) error{OutOfMemory}!Query {
        assert(text.len != 0);

        var query: Query = .{};
        if (text.len <= 3) {
            if (shortQueryTrigram(text)) |trigram| {
                query.inline_trigrams[0] = .{
                    .value = trigram,
                    .map_hash = TrigramContext.hash(.{}, trigram),
                };
                query.len = 1;
            }
            return query;
        }

        errdefer query.deinit(allocator);
        var iterator: TrigramIterator = .init(text);
        while (iterator.next()) |trigram| {
            const trigram_value = TrigramContext.toInt(trigram);
            const items = if (query.heap_trigrams) |heap_trigrams|
                heap_trigrams[0..query.len]
            else
                query.inline_trigrams[0..query.len];
            for (items[0..@min(query.len, deduplicate_scan_limit)]) |existing| {
                if (TrigramContext.toInt(existing.value) == trigram_value) break;
            } else {
                if (query.len > deduplicate_scan_limit and
                    TrigramContext.toInt(items[query.len - 1].value) == trigram_value)
                {
                    continue;
                }
                if (query.len == inline_capacity) {
                    const heap_trigrams = try allocator.alloc(PreparedTrigram, text.len - 2);
                    @memcpy(heap_trigrams[0..query.len], &query.inline_trigrams);
                    query.heap_trigrams = heap_trigrams;
                }

                const prepared: PreparedTrigram = .{
                    .value = trigram,
                    .map_hash = TrigramContext.hash(.{}, trigram),
                };
                if (query.heap_trigrams) |heap_trigrams| {
                    heap_trigrams[query.len] = prepared;
                } else {
                    query.inline_trigrams[query.len] = prepared;
                }
                query.len += 1;
            }
        }

        return query;
    }

    pub fn deinit(query: *Query, allocator: std.mem.Allocator) void {
        if (query.heap_trigrams) |items| allocator.free(items);
        query.* = undefined;
    }

    fn trigrams(query: *const Query) []const PreparedTrigram {
        if (query.heap_trigrams) |items| return items[0..query.len];
        return query.inline_trigrams[0..query.len];
    }
};

/// A filter pass scans the query before the exact lookup pass. Benchmarks
/// against ZLS and Zig standard-library sources put the break-even point at a
/// first posting list of roughly this size.
const filter_min_posting_len = 160;

filter_buckets: ?[]CuckooFilter.Bucket,
trigram_to_declarations: PostingMap,
postings: []Declaration.Index,
declarations: std.MultiArrayList(Declaration),

fn denseDeclarationCapacity(tree: *const Ast) usize {
    return denseDeclarationCapacityFromTags(tree.nodes.items(.tag));
}

fn denseDeclarationCapacityFromTags(tags: []const Ast.Node.Tag) usize {
    if (tags.len < 4096) return 0;

    const sample_count = 64;
    var declaration_tags: usize = 0;
    for (0..sample_count) |sample_index| {
        const index: usize = @intCast(
            (@as(u64, @intCast(sample_index)) * @as(u64, @intCast(tags.len))) / sample_count,
        );
        switch (tags[index]) {
            .global_var_decl,
            .local_var_decl,
            .simple_var_decl,
            .aligned_var_decl,
            .fn_proto,
            .fn_proto_multi,
            .fn_proto_one,
            .fn_proto_simple,
            .fn_decl,
            .test_decl,
            .container_field,
            .container_field_init,
            .container_field_align,
            => declaration_tags += 1,
            else => {},
        }
    }
    if (declaration_tags <= sample_count / 4) return 0;
    return @intCast(
        (@as(u64, @intCast(declaration_tags)) * @as(u64, @intCast(tags.len))) / sample_count + 16,
    );
}

pub fn init(
    allocator: std.mem.Allocator,
    tree: *const Ast,
) error{OutOfMemory}!TrigramStore {
    var store: TrigramStore = .{
        .filter_buckets = null,
        .trigram_to_declarations = .empty,
        .postings = &.{},
        .declarations = .empty,
    };
    errdefer store.deinit(allocator);
    try store.declarations.ensureTotalCapacity(allocator, denseDeclarationCapacity(tree));

    var posting_lists: PostingListBuilder = .empty;
    defer {
        for (posting_lists.values()) |*list| list.deinit(allocator);
        posting_lists.deinit(allocator);
    }

    var walker_stack = std.heap.stackFallback(1024, allocator);
    const walker_allocator = walker_stack.get();
    var walker: ast.Walker = try .init(walker_allocator, tree, .root);
    defer walker.deinit(walker_allocator);

    var stack_fallback = std.heap.stackFallback(16, allocator);
    const stack_allocator = stack_fallback.get();
    var in_function_stack: std.ArrayList(bool) = try .initCapacity(stack_allocator, 16);
    defer in_function_stack.deinit(stack_allocator);

    while (try walker.next(walker_allocator, tree)) |entry| {
        switch (entry) {
            .open => |node| switch (tree.nodeTag(node)) {
                .fn_decl => try in_function_stack.append(stack_allocator, true),
                .fn_proto,
                .fn_proto_multi,
                .fn_proto_one,
                .fn_proto_simple,
                => {
                    const fn_token = tree.nodeMainToken(node);
                    if (tree.tokenTag(fn_token + 1) != .identifier) continue;

                    try store.appendDeclaration(
                        &posting_lists,
                        allocator,
                        tree,
                        fn_token + 1,
                        .function,
                    );
                },
                .test_decl => {
                    try in_function_stack.append(stack_allocator, true);
                    const test_name_token = tree.nodeData(node).opt_token_and_node[0].unwrap() orelse continue;

                    try store.appendDeclaration(
                        &posting_lists,
                        allocator,
                        tree,
                        test_name_token,
                        .test_function,
                    );
                },
                .container_decl,
                .container_decl_trailing,
                .container_decl_arg,
                .container_decl_arg_trailing,
                .container_decl_two,
                .container_decl_two_trailing,
                .tagged_union,
                .tagged_union_trailing,
                .tagged_union_enum_tag,
                .tagged_union_enum_tag_trailing,
                .tagged_union_two,
                .tagged_union_two_trailing,
                => try in_function_stack.append(stack_allocator, false),

                .global_var_decl,
                .local_var_decl,
                .simple_var_decl,
                .aligned_var_decl,
                => {
                    const in_function = in_function_stack.getLastOrNull() orelse false;
                    if (in_function) continue;

                    const main_token = tree.nodeMainToken(node);

                    const kind: Declaration.Kind = switch (tree.tokenTag(main_token)) {
                        .keyword_var => .variable,
                        .keyword_const => .constant,
                        else => unreachable,
                    };

                    if (isVarDeclAlias(tree, node)) continue;

                    try store.appendDeclaration(
                        &posting_lists,
                        allocator,
                        tree,
                        main_token + 1,
                        kind,
                    );
                },
                .container_field_init,
                .container_field_align,
                .container_field,
                => {
                    const name_token = tree.nodeMainToken(node);
                    if (tree.tokenTag(name_token) != .identifier) continue;

                    try store.appendDeclaration(
                        &posting_lists,
                        allocator,
                        tree,
                        name_token,
                        .field,
                    );
                },
                else => {},
            },
            .close => |node| switch (tree.nodeTag(node)) {
                .fn_decl, .test_decl => assert(in_function_stack.pop().?),
                .container_decl,
                .container_decl_trailing,
                .container_decl_arg,
                .container_decl_arg_trailing,
                .container_decl_two,
                .container_decl_two_trailing,
                .tagged_union,
                .tagged_union_trailing,
                .tagged_union_enum_tag,
                .tagged_union_enum_tag_trailing,
                .tagged_union_two,
                .tagged_union_two_trailing,
                => assert(!in_function_stack.pop().?),
                else => {},
            },
        }
    }

    const lists = posting_lists.values();
    var posting_count: usize = 0;
    for (lists) |list| {
        posting_count = std.math.add(usize, posting_count, list.len()) catch return error.OutOfMemory;
    }
    if (posting_count > std.math.maxInt(u32)) return error.OutOfMemory;

    store.postings = try allocator.alloc(Declaration.Index, posting_count);
    try store.trigram_to_declarations.ensureTotalCapacity(allocator, posting_lists.count());

    var posting_start: usize = 0;
    for (posting_lists.keys(), posting_lists.values()) |trigram, list| {
        store.postings[posting_start] = list.first;
        const inline_len: usize = if (list.second.unwrap()) |second| blk: {
            store.postings[posting_start + 1] = second;
            break :blk 2;
        } else 1;
        @memcpy(store.postings[posting_start + inline_len ..][0..list.rest.items.len], list.rest.items);
        store.trigram_to_declarations.putAssumeCapacityNoClobber(trigram, .{
            .start = @intCast(posting_start),
            .len = @intCast(list.len()),
        });
        posting_start += list.len();
    }
    assert(posting_start == store.postings.len);

    const build_filter = for (store.trigram_to_declarations.values()) |list| {
        if (list.len >= filter_min_posting_len) break true;
    } else false;

    if (build_filter) {
        const trigrams = store.trigram_to_declarations.keys();
        var prng = std.Random.DefaultPrng.init(0);

        const filter_capacity = CuckooFilter.capacityForCount(trigrams.len) catch unreachable;
        const buckets = try allocator.alloc(CuckooFilter.Bucket, filter_capacity);
        errdefer comptime unreachable;

        const filter: CuckooFilter = .{ .buckets = buckets };
        filter.reset();

        for (trigrams) |trigram| {
            filter.append(prng.random(), trigram) catch |err| switch (err) {
                error.EvictionFailed => {
                    // This should generally be quite rare.
                    allocator.free(buckets);
                    break;
                },
            };
        } else {
            store.filter_buckets = buckets;
        }
    }

    try multi_array_list.shrinkAndFree(allocator, &store.trigram_to_declarations.entries);
    try multi_array_list.shrinkAndFree(allocator, &store.declarations);

    return store;
}

pub fn deinit(store: *TrigramStore, allocator: std.mem.Allocator) void {
    if (store.filter_buckets) |buckets| allocator.free(buckets);
    allocator.free(store.postings);
    store.trigram_to_declarations.deinit(allocator);
    store.declarations.deinit(allocator);
    store.* = undefined;
}

/// Asserts `query.len >= 1`. Asserts declaration_buffer.items.len == 0.
pub fn declarationsForQuery(
    store: *const TrigramStore,
    allocator: std.mem.Allocator,
    query: []const u8,
    declaration_buffer: *std.ArrayList(Declaration.Index),
) error{OutOfMemory}!void {
    const declarations = try store.declarationSliceForQuery(allocator, query, declaration_buffer);
    if (declarations.len != 0 and declaration_buffer.items.len == 0) {
        try declaration_buffer.appendSlice(allocator, declarations);
    }
}

/// The returned declarations may borrow storage from `store` or
/// `declaration_buffer` and remain valid while both are alive and unmodified.
/// Asserts `query.len >= 1`. Asserts `declaration_buffer.items.len == 0`.
pub fn declarationSliceForQuery(
    store: *const TrigramStore,
    allocator: std.mem.Allocator,
    query: []const u8,
    declaration_buffer: *std.ArrayList(Declaration.Index),
) error{OutOfMemory}![]const Declaration.Index {
    assert(query.len >= 1);
    assert(declaration_buffer.items.len == 0);
    if (query.len <= 3) return store.declarationsForShortQuery(query);

    var ti: TrigramIterator = .init(query);

    const first_trigram = ti.next() orelse return &.{};
    const first = (store.trigram_to_declarations.get(first_trigram) orelse return &.{}).slice(store.postings);
    const second_trigram = ti.next() orelse return first;

    if (first.len >= filter_min_posting_len) {
        if (store.filter_buckets) |buckets| {
            const filter: CuckooFilter = .{ .buckets = buckets };
            var filter_ti = ti;
            if (!filter.contains(second_trigram)) return &.{};
            while (filter_ti.next()) |trigram| {
                if (!filter.contains(trigram)) return &.{};
            }
        }
    }

    const second = (store.trigram_to_declarations.get(second_trigram) orelse return &.{}).slice(store.postings);
    if (query.len > Query.inline_capacity + 2 and
        first.len >= filter_min_posting_len and second.len >= filter_min_posting_len)
    {
        if (try store.intersectRawQueryFromRarestPostings(
            allocator,
            query,
            declaration_buffer,
            first_trigram,
            first,
            second_trigram,
            second,
        )) |declarations| return declarations;
    }
    try declaration_buffer.resize(allocator, @min(first.len, second.len));
    var len = mergeIntersectionInto(first, second, declaration_buffer.items);
    declaration_buffer.shrinkRetainingCapacity(len);
    if (len == 0) return declaration_buffer.items;

    while (ti.next()) |trigram| {
        len = mergeIntersection(
            (store.trigram_to_declarations.get(trigram) orelse {
                declaration_buffer.clearRetainingCapacity();
                return &.{};
            }).slice(store.postings),
            declaration_buffer.items[0..len],
        );
        declaration_buffer.shrinkRetainingCapacity(len);
        if (len == 0) break;
    }
    return declaration_buffer.items;
}

const PostingSeed = struct {
    trigram: Trigram,
    declarations: []const Declaration.Index,
};

fn seedContainsTrigram(a: PostingSeed, b: ?PostingSeed, trigram: Trigram) bool {
    const value = TrigramContext.toInt(trigram);
    return TrigramContext.toInt(a.trigram) == value or
        (b != null and TrigramContext.toInt(b.?.trigram) == value);
}

fn considerPostingSeed(a: *PostingSeed, b: *?PostingSeed, candidate: PostingSeed) void {
    if (seedContainsTrigram(a.*, b.*, candidate.trigram)) return;
    if (candidate.declarations.len < a.declarations.len) {
        b.* = a.*;
        a.* = candidate;
    } else if (b.* == null or candidate.declarations.len < b.*.?.declarations.len) {
        b.* = candidate;
    }
}

// Keep the extra scan out of the ordinary query path. Long queries with a
// rare suffix can avoid materializing a large common-prefix intersection.
noinline fn intersectRawQueryFromRarestPostings(
    store: *const TrigramStore,
    allocator: std.mem.Allocator,
    query: []const u8,
    declaration_buffer: *std.ArrayList(Declaration.Index),
    first_trigram: Trigram,
    first_declarations: []const Declaration.Index,
    second_trigram: Trigram,
    second_declarations: []const Declaration.Index,
) error{OutOfMemory}!?[]const Declaration.Index {
    var iterator: TrigramIterator = .init(query);
    _ = iterator.next();
    _ = iterator.next();
    var unique: [Query.deduplicate_scan_limit]PostingSeed = undefined;
    unique[0] = .{ .trigram = first_trigram, .declarations = first_declarations };
    var unique_len: usize = 1;
    var unique_overflow = false;
    var saw_duplicate = false;
    var first: PostingSeed = .{ .trigram = first_trigram, .declarations = first_declarations };
    var second: ?PostingSeed = null;
    if (TrigramContext.toInt(second_trigram) == TrigramContext.toInt(first_trigram)) {
        saw_duplicate = true;
    } else {
        unique[1] = .{ .trigram = second_trigram, .declarations = second_declarations };
        unique_len = 2;
        considerPostingSeed(&first, &second, unique[1]);
    }
    while (iterator.next()) |trigram| {
        if (!unique_overflow) {
            const value = TrigramContext.toInt(trigram);
            var is_duplicate = false;
            for (unique[0..unique_len]) |existing| {
                if (TrigramContext.toInt(existing.trigram) == value) {
                    is_duplicate = true;
                    break;
                }
            }
            if (is_duplicate) {
                saw_duplicate = true;
                continue;
            }
            if (unique_len != unique.len) {
                const declarations = (store.trigram_to_declarations.get(trigram) orelse return &.{}).slice(store.postings);
                const candidate: PostingSeed = .{ .trigram = trigram, .declarations = declarations };
                unique[unique_len] = candidate;
                unique_len += 1;
                considerPostingSeed(&first, &second, candidate);
                continue;
            }
            unique_overflow = true;
        }

        if (seedContainsTrigram(first, second, trigram)) continue;
        const declarations = (store.trigram_to_declarations.get(trigram) orelse return &.{}).slice(store.postings);
        considerPostingSeed(&first, &second, .{ .trigram = trigram, .declarations = declarations });
    }
    if (!unique_overflow and unique_len == 1) return unique[0].declarations;

    const other = second orelse return null;
    if ((unique_overflow or !saw_duplicate) and
        !isSkewed(@min(first_declarations.len, second_declarations.len), first.declarations.len))
    {
        return null;
    }

    try declaration_buffer.resize(allocator, @min(first.declarations.len, other.declarations.len));
    var len = mergeIntersectionInto(first.declarations, other.declarations, declaration_buffer.items);
    declaration_buffer.shrinkRetainingCapacity(len);
    if (len == 0) return declaration_buffer.items;

    if (!unique_overflow) {
        for (unique[0..unique_len]) |posting| {
            if (seedContainsTrigram(first, other, posting.trigram)) continue;
            len = mergeIntersection(posting.declarations, declaration_buffer.items[0..len]);
            declaration_buffer.shrinkRetainingCapacity(len);
            if (len == 0) break;
        }
    } else {
        iterator = .init(query);
        while (iterator.next()) |trigram| {
            if (seedContainsTrigram(first, other, trigram)) continue;
            len = mergeIntersection(
                (store.trigram_to_declarations.get(trigram) orelse unreachable).slice(store.postings),
                declaration_buffer.items[0..len],
            );
            declaration_buffer.shrinkRetainingCapacity(len);
            if (len == 0) break;
        }
    }
    return declaration_buffer.items;
}

fn declarationsForShortQuery(
    store: *const TrigramStore,
    query: []const u8,
) []const Declaration.Index {
    const trigram = shortQueryTrigram(query) orelse return &.{};
    return (store.trigram_to_declarations.get(trigram) orelse return &.{}).slice(store.postings);
}

fn shortQueryTrigram(query: []const u8) ?Trigram {
    assert(query.len != 0 and query.len <= 3);
    var trigram: Trigram = @splat(0);
    var len: u2 = 0;
    for (query) |c| {
        if (c == '_') continue;
        trigram[len] = std.ascii.toLower(c);
        len += 1;
    }
    return if (len == 0) null else trigram;
}

/// Asserts `declaration_buffer.items.len == 0`.
pub fn declarationsForPreparedQuery(
    store: *const TrigramStore,
    allocator: std.mem.Allocator,
    query: *const Query,
    declaration_buffer: *std.ArrayList(Declaration.Index),
) error{OutOfMemory}!void {
    const declarations = try store.declarationSliceForPreparedQuery(allocator, query, declaration_buffer);
    if (declarations.len != 0 and declaration_buffer.items.len == 0) {
        try declaration_buffer.appendSlice(allocator, declarations);
    }
}

/// The returned declarations may borrow storage from `store` or
/// `declaration_buffer` and remain valid while both are alive and unmodified.
/// Asserts `declaration_buffer.items.len == 0`.
pub fn declarationSliceForPreparedQuery(
    store: *const TrigramStore,
    allocator: std.mem.Allocator,
    query: *const Query,
    declaration_buffer: *std.ArrayList(Declaration.Index),
) error{OutOfMemory}![]const Declaration.Index {
    assert(declaration_buffer.items.len == 0);

    const trigrams = query.trigrams();
    if (trigrams.len == 0) return &.{};

    const first = (store.trigram_to_declarations.getAdapted(trigrams[0], PreparedTrigramContext{}) orelse return &.{}).slice(store.postings);
    if (trigrams.len == 1) return first;

    if (first.len >= filter_min_posting_len) {
        if (store.filter_buckets) |buckets| {
            const filter: CuckooFilter = .{ .buckets = buckets };
            for (trigrams[1..]) |trigram| {
                if (!filter.contains(trigram.value)) return &.{};
            }
        }
    }

    const second = (store.trigram_to_declarations.getAdapted(trigrams[1], PreparedTrigramContext{}) orelse return &.{}).slice(store.postings);
    if (trigrams.len > Query.inline_capacity and
        first.len >= filter_min_posting_len and second.len >= filter_min_posting_len)
    {
        if (try store.intersectPreparedQueryFromRarestPostings(
            allocator,
            trigrams,
            declaration_buffer,
            first,
            second,
        )) |declarations| return declarations;
    }
    try declaration_buffer.resize(allocator, @min(first.len, second.len));
    var len = mergeIntersectionInto(first, second, declaration_buffer.items);
    declaration_buffer.shrinkRetainingCapacity(len);
    if (len == 0) return declaration_buffer.items;

    for (trigrams[2..]) |trigram| {
        len = mergeIntersection(
            (store.trigram_to_declarations.getAdapted(trigram, PreparedTrigramContext{}) orelse {
                declaration_buffer.clearRetainingCapacity();
                return &.{};
            }).slice(store.postings),
            declaration_buffer.items[0..len],
        );
        declaration_buffer.shrinkRetainingCapacity(len);
        if (len == 0) break;
    }
    return declaration_buffer.items;
}

noinline fn intersectPreparedQueryFromRarestPostings(
    store: *const TrigramStore,
    allocator: std.mem.Allocator,
    trigrams: []const PreparedTrigram,
    declaration_buffer: *std.ArrayList(Declaration.Index),
    first_declarations: []const Declaration.Index,
    second_declarations: []const Declaration.Index,
) error{OutOfMemory}!?[]const Declaration.Index {
    var first: PostingSeed = .{ .trigram = trigrams[0].value, .declarations = first_declarations };
    var second: ?PostingSeed = null;
    considerPostingSeed(&first, &second, .{ .trigram = trigrams[1].value, .declarations = second_declarations });
    for (trigrams[2..]) |trigram| {
        if (seedContainsTrigram(first, second, trigram.value)) continue;
        const declarations = (store.trigram_to_declarations.getAdapted(trigram, PreparedTrigramContext{}) orelse return &.{}).slice(store.postings);
        considerPostingSeed(&first, &second, .{ .trigram = trigram.value, .declarations = declarations });
    }
    const other = second orelse return null;
    if (!isSkewed(@min(first_declarations.len, second_declarations.len), first.declarations.len)) return null;

    try declaration_buffer.resize(allocator, @min(first.declarations.len, other.declarations.len));
    var len = mergeIntersectionInto(first.declarations, other.declarations, declaration_buffer.items);
    declaration_buffer.shrinkRetainingCapacity(len);
    if (len == 0) return declaration_buffer.items;

    for (trigrams) |trigram| {
        if (seedContainsTrigram(first, other, trigram.value)) continue;
        len = mergeIntersection(
            (store.trigram_to_declarations.getAdapted(trigram, PreparedTrigramContext{}) orelse unreachable).slice(store.postings),
            declaration_buffer.items[0..len],
        );
        declaration_buffer.shrinkRetainingCapacity(len);
        if (len == 0) break;
    }
    return declaration_buffer.items;
}

fn appendDeclaration(
    store: *TrigramStore,
    posting_lists: *PostingListBuilder,
    allocator: std.mem.Allocator,
    tree: *const Ast,
    name_token: Ast.TokenIndex,
    kind: Declaration.Kind,
) error{OutOfMemory}!void {
    const raw_name = tree.tokenSlice(name_token);

    const strategy: enum { raw, smart }, const name = switch (tree.tokenTag(name_token)) {
        .string_literal => .{ .raw, raw_name[1 .. raw_name.len - 1] },
        .identifier => if (std.mem.startsWith(u8, raw_name, "@"))
            .{ .raw, raw_name[2 .. raw_name.len - 1] }
        else
            .{ .smart, raw_name },
        else => unreachable,
    };
    const is_ascii = switch (strategy) {
        .smart => true,
        .raw => for (raw_name) |c| {
            if (!std.ascii.isAscii(c)) break false;
        } else true,
    };

    switch (strategy) {
        .raw => {
            if (name.len < 3) return;
            for (0..name.len - 2) |index| {
                var trigram = name[index..][0..3].*;
                for (&trigram) |*char| char.* = std.ascii.toLower(char.*);
                try store.appendOneTrigram(posting_lists, allocator, trigram);
            }
        },
        .smart => {
            var it: TrigramIterator = .init(name);
            while (it.next()) |trigram| {
                try store.appendOneTrigram(posting_lists, allocator, trigram);
            }
        },
    }

    // The AST walker visits declarations in source order. Posting lists inherit
    // this order, and their intersections preserve it.
    if (store.declarations.len != 0) {
        assert(store.declarations.items(.name)[store.declarations.len - 1] < name_token);
    }
    try store.declarations.append(allocator, .{
        .name = name_token,
        .name_len = .{
            .bytes = @intCast(raw_name.len),
            .is_ascii = is_ascii,
        },
        .kind = kind,
    });
}

fn appendOneTrigram(
    store: *TrigramStore,
    posting_lists: *PostingListBuilder,
    allocator: std.mem.Allocator,
    trigram: Trigram,
) error{OutOfMemory}!void {
    const declaration_index: Declaration.Index = @enumFromInt(store.declarations.len);

    const gop = try posting_lists.getOrPut(allocator, trigram);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{ .first = declaration_index };
    } else {
        try gop.value_ptr.append(allocator, declaration_index);
    }
}

/// Check if the init expression is a sequence of field accesses
/// where the last field name matches the var decl name:
///
/// ```zig
/// const Foo = a.Foo; // true
/// const Bar = a.b.Bar; // true
/// const Baz = a.Bar; // false
/// const Biz = 5; // false
/// ```
fn isVarDeclAlias(tree: *const Ast, var_decl: Ast.Node.Index) bool {
    const main_token = tree.nodeMainToken(var_decl);

    if (tree.tokenTag(main_token) != .keyword_const) return false;
    const init_node = tree.fullVarDecl(var_decl).?.ast.init_node.unwrap() orelse return false;

    if (tree.nodeTag(init_node) != .field_access) return false;

    const lhs_node, const field_name_token = tree.nodeData(init_node).node_and_token;
    const alias_name = offsets.identifierTokenToNameSlice(tree, main_token + 1);
    const target_name = offsets.identifierTokenToNameSlice(tree, field_name_token);
    if (!std.mem.eql(u8, alias_name, target_name)) return false;

    var current_node = lhs_node;
    while (true) {
        switch (tree.nodeTag(current_node)) {
            .identifier => return true,
            .field_access => current_node = tree.nodeData(current_node).node_and_token[0],
            else => return false,
        }
    }
}

/// Splits a symbol into trigrams with the following rules:
/// - ignore `_` symbol characters
/// - convert symbol characters to lowercase
/// - append `\x00` (null bytes) to the symbol if symbol length is not divisible by the trigram length
const TrigramIterator = struct {
    symbol: []const u8,
    index: usize,

    trigram_buffer: Trigram,
    trigram_buffer_index: u2,

    pub fn init(symbol: []const u8) TrigramIterator {
        assert(symbol.len != 0);
        return .{
            .symbol = symbol,
            .index = 0,
            .trigram_buffer = @splat(0),
            .trigram_buffer_index = 0,
        };
    }

    pub fn next(ti: *TrigramIterator) ?Trigram {
        while (ti.index < ti.symbol.len) {
            defer ti.index += 1;
            const c = std.ascii.toLower(ti.symbol[ti.index]);
            if (c == '_') continue;

            if (ti.trigram_buffer_index < 3) {
                ti.trigram_buffer[ti.trigram_buffer_index] = c;
                ti.trigram_buffer_index += 1;
                continue;
            }

            defer {
                @memmove(ti.trigram_buffer[0..2], ti.trigram_buffer[1..3]);
                ti.trigram_buffer[2] = c;
            }
            return ti.trigram_buffer;
        } else if (ti.trigram_buffer_index > 0) {
            ti.trigram_buffer_index = 0;
            return ti.trigram_buffer;
        } else {
            return null;
        }
    }
};

test TrigramIterator {
    try testTrigramIterator("a", &.{"a\x00\x00".*});
    try testTrigramIterator("ab", &.{"ab\x00".*});
    try testTrigramIterator("abc", &.{"abc".*});

    try testTrigramIterator("hello", &.{ "hel".*, "ell".*, "llo".* });
    try testTrigramIterator("HELLO", &.{ "hel".*, "ell".*, "llo".* });
    try testTrigramIterator("HellO", &.{ "hel".*, "ell".*, "llo".* });

    try testTrigramIterator("a_", &.{"a\x00\x00".*});
    try testTrigramIterator("ab_", &.{"ab\x00".*});
    try testTrigramIterator("abc_", &.{"abc".*});

    try testTrigramIterator("_a", &.{"a\x00\x00".*});
    try testTrigramIterator("_a_", &.{"a\x00\x00".*});
    try testTrigramIterator("_a__", &.{"a\x00\x00".*});

    try testTrigramIterator("_", &.{});
    try testTrigramIterator("__", &.{});
    try testTrigramIterator("___", &.{});

    try testTrigramIterator("He_ll_O", &.{ "hel".*, "ell".*, "llo".* });
    try testTrigramIterator("He__ll___O", &.{ "hel".*, "ell".*, "llo".* });
    try testTrigramIterator("__He__ll__O_", &.{ "hel".*, "ell".*, "llo".* });

    try testTrigramIterator("HellO__World___HelloWorld", &.{
        "hel".*, "ell".*, "llo".*,
        "low".*, "owo".*, "wor".*,
        "orl".*, "rld".*, "ldh".*,
        "dhe".*, "hel".*, "ell".*,
        "llo".*, "low".*, "owo".*,
        "wor".*, "orl".*, "rld".*,
    });
}

test Query {
    const allocator = std.testing.allocator;

    const ShortCase = struct {
        text: []const u8,
        expected: ?Trigram,
    };
    const short_cases = [_]ShortCase{
        .{ .text = "a", .expected = "a\x00\x00".* },
        .{ .text = "ab", .expected = "ab\x00".* },
        .{ .text = "abc", .expected = "abc".* },
        .{ .text = "ALP", .expected = "alp".* },
        .{ .text = "_a", .expected = "a\x00\x00".* },
        .{ .text = "a_", .expected = "a\x00\x00".* },
        .{ .text = "a_b", .expected = "ab\x00".* },
        .{ .text = "___", .expected = null },
    };
    for (short_cases) |case| {
        var query = try Query.init(allocator, case.text);
        defer query.deinit(allocator);

        try std.testing.expect(query.heap_trigrams == null);
        if (case.expected) |expected| {
            try std.testing.expectEqual(@as(usize, 1), query.trigrams().len);
            try std.testing.expectEqual(expected, query.trigrams()[0].value);
            try std.testing.expectEqual(TrigramContext.hash(.{}, expected), query.trigrams()[0].map_hash);
        } else {
            try std.testing.expectEqual(@as(usize, 0), query.trigrams().len);
        }
    }

    {
        var query = try Query.init(allocator, "_Ab_cAb_");
        defer query.deinit(allocator);

        const expected = [_]Trigram{ "abc".*, "bca".*, "cab".* };
        try std.testing.expect(query.heap_trigrams == null);
        try std.testing.expectEqual(expected.len, query.trigrams().len);
        for (query.trigrams(), expected) |actual, value| {
            try std.testing.expectEqual(value, actual.value);
            try std.testing.expectEqual(TrigramContext.hash(.{}, value), actual.map_hash);
        }
    }

    {
        var query = try Query.init(allocator, "abcdefghijklmnopqr");
        defer query.deinit(allocator);

        try std.testing.expect(query.heap_trigrams == null);
        try std.testing.expectEqual(Query.inline_capacity, query.trigrams().len);
    }

    {
        const text = "abcdefghijklmnopqrs";
        var query = try Query.init(allocator, text);
        defer query.deinit(allocator);

        try std.testing.expect(query.heap_trigrams != null);
        try std.testing.expectEqual(Query.inline_capacity + 1, query.trigrams().len);
        try std.testing.expectEqual(text.len - 2, query.heap_trigrams.?.len);

        try std.testing.checkAllAllocationFailures(allocator, struct {
            fn init(allocator_: std.mem.Allocator, text_: []const u8) !void {
                var result = try Query.init(allocator_, text_);
                defer result.deinit(allocator_);
            }
        }.init, .{text});
    }

    {
        const text = "abcdefghijklmnopqr__";
        var query = try Query.init(allocator, text);
        defer query.deinit(allocator);

        try std.testing.expect(query.heap_trigrams == null);
        try std.testing.expectEqual(Query.inline_capacity, query.trigrams().len);
    }

    {
        var query = try Query.init(allocator, "aaaaaaaaaaaaaaaaaaaa");
        defer query.deinit(allocator);

        try std.testing.expect(query.heap_trigrams == null);
        try std.testing.expectEqual(@as(usize, 1), query.trigrams().len);
        try std.testing.expectEqual("aaa".*, query.trigrams()[0].value);
    }

    {
        var query = try Query.init(allocator, "abcabcabcabcabcabc");
        defer query.deinit(allocator);

        const expected = [_]Trigram{ "abc".*, "bca".*, "cab".* };
        try std.testing.expect(query.heap_trigrams == null);
        try std.testing.expectEqual(expected.len, query.trigrams().len);
        for (query.trigrams(), expected) |actual, value| {
            try std.testing.expectEqual(value, actual.value);
        }
    }

    {
        const unique_prefix = "abcdefghijklmnopqrstuvwxyz0123456789";
        var query = try Query.init(allocator, unique_prefix ++ "zzzzzzzzzz");
        defer query.deinit(allocator);

        try std.testing.expect(query.trigrams().len > Query.deduplicate_scan_limit);
        const trigrams = query.trigrams();
        try std.testing.expectEqual("zzz".*, trigrams[trigrams.len - 1].value);
        try std.testing.expect(TrigramContext.toInt(trigrams[trigrams.len - 2].value) != TrigramContext.toInt("zzz".*));
    }
}

test TrigramContext {
    const context: TrigramContext = .{};
    try std.testing.expectEqual(@as(u32, 0x00636261), TrigramContext.toInt("abc".*));
    try std.testing.expect(context.eql("abc".*, "abc".*, 0));
    try std.testing.expect(!context.eql("abc".*, "abd".*, 0));
    try std.testing.expectEqual(context.hash("abc".*), context.hash("abc".*));
    try std.testing.expect(context.hash("abc".*) != context.hash("abd".*));
}

fn testTrigramIterator(
    input: []const u8,
    expected: []const Trigram,
) !void {
    const allocator = std.testing.allocator;

    var actual_buffer: std.ArrayList(Trigram) = .empty;
    defer actual_buffer.deinit(allocator);

    var it: TrigramIterator = .init(input);
    while (it.next()) |trigram| {
        try actual_buffer.append(allocator, trigram);
    }

    try @import("testing.zig").expectEqual(expected, actual_buffer.items);
}

/// Intersects the sorted inputs in place, storing the result in `b`.
fn mergeIntersection(
    a: []const Declaration.Index,
    b: []Declaration.Index,
) u32 {
    if (a.len == 0 or b.len == 0) return 0;
    if (a.len == b.len and a.len >= filter_min_posting_len) {
        return mergeEqualLengthIntersection(a, b);
    }
    if (isSkewed(a.len, b.len)) return binaryIntersectionInto(b, a, b);
    if (isSkewed(b.len, a.len)) return binaryIntersectionInto(a, b, b);

    var out_idx: u32 = 0;
    var a_idx: u32 = 0;
    var b_idx: u32 = 0;

    while (a_idx < a.len and b_idx < b.len) {
        const a_val = a[a_idx];
        const b_val = b[b_idx];

        if (a_val == b_val) {
            b[out_idx] = a_val;
            out_idx += 1;
            a_idx += 1;
            b_idx += 1;
        } else if (@intFromEnum(a_val) < @intFromEnum(b_val)) {
            a_idx += 1;
        } else {
            b_idx += 1;
        }
    }

    return out_idx;
}

noinline fn mergeEqualLengthIntersection(
    a: []const Declaration.Index,
    b: []Declaration.Index,
) u32 {
    assert(a.len == b.len);
    const common_len = postingCommonPrefixLen(a, b);
    if (common_len == a.len) return @intCast(a.len);

    var out_index: u32 = @intCast(common_len);
    var a_index = common_len;
    var b_index = common_len;
    while (a_index < a.len and b_index < b.len) {
        const a_value = a[a_index];
        const b_value = b[b_index];
        if (a_value == b_value) {
            b[out_index] = a_value;
            out_index += 1;
            a_index += 1;
            b_index += 1;
        } else if (@intFromEnum(a_value) < @intFromEnum(b_value)) {
            a_index += 1;
        } else {
            b_index += 1;
        }
    }
    return out_index;
}

fn postingCommonPrefixLen(a: []const Declaration.Index, b: []const Declaration.Index) usize {
    const len = @min(a.len, b.len);
    var index: usize = 0;
    if (@import("builtin").zig_backend == .stage2_llvm) {
        if (std.simd.suggestVectorLength(u32)) |block_size| {
            const Block = @Vector(block_size, u32);
            while (len - index >= block_size) : (index += block_size) {
                const a_values: Block = @bitCast(a[index..][0..block_size].*);
                const b_values: Block = @bitCast(b[index..][0..block_size].*);
                if (@reduce(.Or, a_values != b_values)) break;
            }
        }
    }
    while (index < len and a[index] == b[index]) : (index += 1) {}
    return index;
}

fn mergeIntersectionInto(
    a: []const Declaration.Index,
    b: []const Declaration.Index,
    output: []Declaration.Index,
) u32 {
    assert(output.len >= @min(a.len, b.len));
    if (a.len == 0 or b.len == 0) return 0;
    if (isSkewed(a.len, b.len)) return binaryIntersectionInto(b, a, output);
    if (isSkewed(b.len, a.len)) return binaryIntersectionInto(a, b, output);

    var out_index: u32 = 0;
    var a_index: usize = 0;
    var b_index: usize = 0;
    while (a_index < a.len and b_index < b.len) {
        const a_value = a[a_index];
        const b_value = b[b_index];
        if (a_value == b_value) {
            output[out_index] = a_value;
            out_index += 1;
            a_index += 1;
            b_index += 1;
        } else if (@intFromEnum(a_value) < @intFromEnum(b_value)) {
            a_index += 1;
        } else {
            b_index += 1;
        }
    }
    return out_index;
}

// Benchmarks with uniformly distributed sorted indexes put the crossover near
// 64:1. Keep moderately skewed inputs on the cache-friendly linear merge.
const binary_intersection_ratio = 64;

fn isSkewed(long_len: usize, short_len: usize) bool {
    return short_len != 0 and long_len / binary_intersection_ratio >= short_len;
}

fn binaryIntersectionInto(
    short: []const Declaration.Index,
    long: []const Declaration.Index,
    output: []Declaration.Index,
) u32 {
    assert(short.len <= output.len);
    var out_index: u32 = 0;
    var long_start: usize = 0;
    for (short) |needle| {
        long_start += lowerBoundDeclaration(long[long_start..], needle);
        if (long_start == long.len) break;
        if (long[long_start] == needle) {
            output[out_index] = needle;
            out_index += 1;
            long_start += 1;
        }
    }
    return out_index;
}

fn lowerBoundDeclaration(items: []const Declaration.Index, needle: Declaration.Index) usize {
    var low: usize = 0;
    var high: usize = items.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (@intFromEnum(items[mid]) < @intFromEnum(needle)) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    return low;
}

test mergeIntersection {
    const I = Declaration.Index;
    try std.testing.expect(!isSkewed(63, 1));
    try std.testing.expect(isSkewed(64, 1));
    try std.testing.expect(!isSkewed(64, 2));

    var empty: [0]I = .{};
    try std.testing.expectEqual(@as(u32, 0), mergeIntersection(&.{}, &empty));
    var empty_output: [0]I = .{};
    try std.testing.expectEqual(@as(u32, 0), mergeIntersectionInto(&.{}, &.{}, &empty_output));

    const a = [_]I{ @enumFromInt(1), @enumFromInt(3), @enumFromInt(5), @enumFromInt(8) };
    var b = [_]I{ @enumFromInt(0), @enumFromInt(1), @enumFromInt(2), @enumFromInt(3), @enumFromInt(4), @enumFromInt(5) };
    var direct: [@min(a.len, b.len)]I = undefined;
    const direct_len = mergeIntersectionInto(&a, &b, &direct);
    const len = mergeIntersection(&a, &b);
    try std.testing.expectEqualSlices(I, &.{ @enumFromInt(1), @enumFromInt(3), @enumFromInt(5) }, b[0..len]);
    try std.testing.expectEqualSlices(I, b[0..len], direct[0..direct_len]);

    var prng: std.Random.DefaultPrng = .init(0);
    const random = prng.random();
    for (0..1_000) |_| {
        var random_a: [64]I = undefined;
        var random_b: [64]I = undefined;
        var expected: [64]I = undefined;
        var a_len: usize = 0;
        var b_len: usize = 0;
        var expected_len: usize = 0;

        for (0..64) |value| {
            const item: I = @enumFromInt(value);
            const in_a = random.boolean();
            const in_b = random.boolean();
            if (in_a) {
                random_a[a_len] = item;
                a_len += 1;
            }
            if (in_b) {
                random_b[b_len] = item;
                b_len += 1;
            }
            if (in_a and in_b) {
                expected[expected_len] = item;
                expected_len += 1;
            }
        }

        var direct_random: [64]I = undefined;
        const direct_random_len = mergeIntersectionInto(random_a[0..a_len], random_b[0..b_len], &direct_random);
        try std.testing.expectEqualSlices(I, expected[0..expected_len], direct_random[0..direct_random_len]);
        const random_len = mergeIntersection(random_a[0..a_len], random_b[0..b_len]);
        try std.testing.expectEqualSlices(I, expected[0..expected_len], random_b[0..random_len]);
    }

    var long: [4096]I = undefined;
    for (&long, 0..) |*item, value| item.* = @enumFromInt(value * 2);
    var same = long;
    try std.testing.expectEqual(long.len, mergeIntersection(&long, &same));
    try std.testing.expectEqualSlices(I, &long, &same);
    var common_prefix = long;
    common_prefix[common_prefix.len - 1] = @enumFromInt(9000);
    try std.testing.expectEqual(long.len - 1, mergeIntersection(&long, &common_prefix));
    try std.testing.expectEqualSlices(I, long[0 .. long.len - 1], common_prefix[0 .. long.len - 1]);
    var odd: [filter_min_posting_len]I = undefined;
    for (&odd, 0..) |*item, value| item.* = @enumFromInt(value * 2 + 1);
    try std.testing.expectEqual(@as(u32, 0), mergeIntersection(long[0..odd.len], &odd));

    const short = [_]I{ @enumFromInt(0), @enumFromInt(2048), @enumFromInt(4095), @enumFromInt(8190), @enumFromInt(9000) };
    const skewed_expected = [_]I{ @enumFromInt(0), @enumFromInt(2048), @enumFromInt(8190) };
    var long_copy = long;
    var short_copy = short;
    const short_into_long_len = mergeIntersection(&short, &long_copy);
    const long_into_short_len = mergeIntersection(&long, &short_copy);
    try std.testing.expectEqualSlices(I, &skewed_expected, long_copy[0..short_into_long_len]);
    try std.testing.expectEqualSlices(I, &skewed_expected, short_copy[0..long_into_short_len]);

    var direct_skewed: [short.len]I = undefined;
    const direct_skewed_len = mergeIntersectionInto(&long, &short, &direct_skewed);
    try std.testing.expectEqualSlices(I, &skewed_expected, direct_skewed[0..direct_skewed_len]);
}

test postingCommonPrefixLen {
    const I = Declaration.Index;
    var a: [65]I = undefined;
    for (&a, 0..) |*item, value| item.* = @enumFromInt(value);

    var b = a;
    try std.testing.expectEqual(a.len, postingCommonPrefixLen(&a, &b));
    inline for (.{ 0, 3, 4, 7, 8, 31, 32, 63, 64 }) |index| {
        b = a;
        b[index] = @enumFromInt(1000 + index);
        try std.testing.expectEqual(index, postingCommonPrefixLen(&a, &b));
    }
    try std.testing.expectEqual(@as(usize, 32), postingCommonPrefixLen(a[0..32], a[0..33]));

    var prng: std.Random.DefaultPrng = .init(0);
    const random = prng.random();
    for (0..1_000) |_| {
        const a_len = random.intRangeAtMost(usize, 0, a.len);
        const b_len = random.intRangeAtMost(usize, 0, b.len);
        b = a;
        if (b_len != 0 and random.boolean()) {
            const different_index = random.intRangeLessThan(usize, 0, b_len);
            b[different_index] = @enumFromInt(1000 + different_index);
        }
        const expected = std.mem.indexOfDiff(I, a[0..a_len], b[0..b_len]) orelse @min(a_len, b_len);
        try std.testing.expectEqual(expected, postingCommonPrefixLen(a[0..a_len], b[0..b_len]));
    }
}

test "declarations and query results stay in source order" {
    const allocator = std.testing.allocator;
    const source: [:0]const u8 =
        \\const symbol_outer = struct {
        \\    const symbol_nested = 1;
        \\    symbol_field: u8,
        \\    fn symbol_method() void {}
        \\};
        \\var symbol_global: u8 = 0;
        \\test "symbol test" {}
        \\extern fn symbol_extern() void;
    ;

    var tree = try Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
    var store = try TrigramStore.init(allocator, &tree);
    defer store.deinit(allocator);

    const names = store.declarations.items(.name);
    const name_lengths = store.declarations.items(.name_len);
    try std.testing.expectEqual(@as(usize, 7), names.len);
    try std.testing.expectEqual(store.declarations.len, store.declarations.capacity);
    for (names[1..], names[0 .. names.len - 1]) |current, previous| {
        try std.testing.expect(previous < current);
    }
    for (names, name_lengths) |name_token, name_len| {
        const loc = offsets.tokenToLoc(&tree, name_token);
        const token_slice = tree.tokenSlice(name_token);
        try std.testing.expectEqual(loc.end - loc.start, name_len.bytes);
        try std.testing.expectEqual(token_slice.len, name_len.bytes);
        try std.testing.expectEqual(std.unicode.utf8CountCodepoints(token_slice) catch unreachable == token_slice.len, name_len.is_ascii);
    }

    var declarations: std.ArrayList(Declaration.Index) = .empty;
    defer declarations.deinit(allocator);
    try store.declarationsForQuery(allocator, "symbol", &declarations);
    try std.testing.expectEqual(names.len, declarations.items.len);
    for (declarations.items, 0..) |declaration, expected| {
        try std.testing.expectEqual(expected, @intFromEnum(declaration));
    }

    var posting_end: usize = 0;
    for (store.trigram_to_declarations.values()) |list| {
        try std.testing.expectEqual(posting_end, list.start);
        const posting_slice = list.slice(store.postings);
        try std.testing.expect(posting_slice.len > 0);
        for (posting_slice[1..], posting_slice[0 .. posting_slice.len - 1]) |current, previous| {
            try std.testing.expect(@intFromEnum(previous) < @intFromEnum(current));
        }
        posting_end += posting_slice.len;
    }
    try std.testing.expectEqual(store.postings.len, posting_end);
    try std.testing.expectEqual(store.trigram_to_declarations.count(), store.trigram_to_declarations.entries.capacity);
}

test "prepared queries match string queries" {
    const allocator = std.testing.allocator;
    const source: [:0]const u8 =
        \\const AlphaBeta = 1;
        \\const alpha_gamma = 2;
        \\const @"alpha delta" = 3;
        \\const repeating_aaaaaaaaaaaaaaaaaaaa = 4;
    ;
    const queries = [_][]const u8{ "a", "ALPHA", "alpha_beta", "alpha delta", "aaaaaaaaaaaaaaaaaaaa", "alpz", "missing", "___" };

    var tree = try Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
    var store = try TrigramStore.init(allocator, &tree);
    defer store.deinit(allocator);

    var string_results: std.ArrayList(Declaration.Index) = .empty;
    defer string_results.deinit(allocator);
    var prepared_results: std.ArrayList(Declaration.Index) = .empty;
    defer prepared_results.deinit(allocator);
    var raw_slice_buffer: std.ArrayList(Declaration.Index) = .empty;
    defer raw_slice_buffer.deinit(allocator);
    var prepared_slice_buffer: std.ArrayList(Declaration.Index) = .empty;
    defer prepared_slice_buffer.deinit(allocator);

    for (queries) |text| {
        try store.declarationsForQuery(allocator, text, &string_results);
        var query = try Query.init(allocator, text);
        defer query.deinit(allocator);
        try store.declarationsForPreparedQuery(allocator, &query, &prepared_results);
        const raw_slice = try store.declarationSliceForQuery(allocator, text, &raw_slice_buffer);
        const prepared_slice = try store.declarationSliceForPreparedQuery(allocator, &query, &prepared_slice_buffer);

        try std.testing.expectEqualSlices(Declaration.Index, string_results.items, prepared_results.items);
        try std.testing.expectEqualSlices(Declaration.Index, string_results.items, raw_slice);
        try std.testing.expectEqualSlices(Declaration.Index, string_results.items, prepared_slice);
        var raw_iterator: TrigramIterator = .init(text);
        _ = raw_iterator.next();
        const raw_has_one_trigram = raw_iterator.next() == null;
        if (raw_has_one_trigram and string_results.items.len != 0) {
            try std.testing.expectEqual(@as(usize, 0), raw_slice_buffer.items.len);
        }
        if (query.trigrams().len == 1 and prepared_results.items.len != 0) {
            try std.testing.expectEqual(@as(usize, 0), prepared_slice_buffer.items.len);
        }
        string_results.clearRetainingCapacity();
        prepared_results.clearRetainingCapacity();
        raw_slice_buffer.clearRetainingCapacity();
        prepared_slice_buffer.clearRetainingCapacity();
    }
}

test "long queries start with rare posting lists" {
    const allocator = std.testing.allocator;

    var source_writer: std.Io.Writer.Allocating = .init(allocator);
    defer source_writer.deinit();
    for (0..filter_min_posting_len) |index| {
        try source_writer.writer.print("const common_symbol_{d} = 0;\n", .{index});
        try source_writer.writer.print("const periodic_abcabcabcabcabcabcabc_{d} = 0;\n", .{index});
        try source_writer.writer.print("const abcdefghijklmnopqrstuvwxyz0123456789_{d} = 0;\n", .{index});
    }
    try source_writer.writer.writeAll("const common_symbol_unique_tail = 0;\n");
    const source = try source_writer.toOwnedSliceSentinel(0);
    defer allocator.free(source);

    var tree = try Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
    var store = try TrigramStore.init(allocator, &tree);
    defer store.deinit(allocator);

    const query_text = "common_symbol_unique_tail";
    var query = try Query.init(allocator, query_text);
    defer query.deinit(allocator);
    try std.testing.expect(query.trigrams().len > Query.inline_capacity);

    var raw_buffer: std.ArrayList(Declaration.Index) = .empty;
    defer raw_buffer.deinit(allocator);
    const raw = try store.declarationSliceForQuery(allocator, query_text, &raw_buffer);
    try std.testing.expectEqual(@as(usize, 1), raw.len);
    try std.testing.expect(raw_buffer.capacity < filter_min_posting_len);

    var prepared_buffer: std.ArrayList(Declaration.Index) = .empty;
    defer prepared_buffer.deinit(allocator);
    const prepared = try store.declarationSliceForPreparedQuery(allocator, &query, &prepared_buffer);
    try std.testing.expectEqualSlices(Declaration.Index, raw, prepared);
    try std.testing.expect(prepared_buffer.capacity < filter_min_posting_len);

    raw_buffer.clearRetainingCapacity();
    const periodic_text = "abcabcabcabcabcabcabc";
    const periodic_raw = try store.declarationSliceForQuery(allocator, periodic_text, &raw_buffer);
    try std.testing.expectEqual(filter_min_posting_len, periodic_raw.len);

    var periodic_query = try Query.init(allocator, periodic_text);
    defer periodic_query.deinit(allocator);
    prepared_buffer.clearRetainingCapacity();
    const periodic_prepared = try store.declarationSliceForPreparedQuery(allocator, &periodic_query, &prepared_buffer);
    try std.testing.expectEqualSlices(Declaration.Index, periodic_raw, periodic_prepared);

    raw_buffer.clearRetainingCapacity();
    const overflow_text = "abcdefghijklmnopqrstuvwxyz0123456789";
    const overflow_raw = try store.declarationSliceForQuery(allocator, overflow_text, &raw_buffer);
    try std.testing.expectEqual(filter_min_posting_len, overflow_raw.len);

    var overflow_query = try Query.init(allocator, overflow_text);
    defer overflow_query.deinit(allocator);
    try std.testing.expect(overflow_query.trigrams().len > Query.deduplicate_scan_limit);
    prepared_buffer.clearRetainingCapacity();
    const overflow_prepared = try store.declarationSliceForPreparedQuery(allocator, &overflow_query, &prepared_buffer);
    try std.testing.expectEqualSlices(Declaration.Index, overflow_raw, overflow_prepared);
}

test "short raw queries match trigram normalization" {
    const allocator = std.testing.allocator;
    const source: [:0]const u8 =
        \\const alpha = 1;
        \\const beta = 2;
        \\const a_b = 3;
    ;
    const queries = [_][]const u8{ "a", "ab", "alp", "ALP", "_a", "a_", "a_b", "___", "zzz" };

    var tree = try Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    var store = try TrigramStore.init(allocator, &tree);
    defer store.deinit(allocator);

    var expected: std.ArrayList(Declaration.Index) = .empty;
    defer expected.deinit(allocator);
    for (queries) |query_text| {
        var iterator: TrigramIterator = .init(query_text);
        const trigram = iterator.next();
        try std.testing.expect(iterator.next() == null);
        if (trigram) |value| {
            if (store.trigram_to_declarations.get(value)) |posting| {
                try expected.appendSlice(allocator, posting.slice(store.postings));
            }
        }

        var scratch: std.ArrayList(Declaration.Index) = .empty;
        defer scratch.deinit(allocator);
        const actual = try store.declarationSliceForQuery(allocator, query_text, &scratch);
        try std.testing.expectEqualSlices(Declaration.Index, expected.items, actual);
        try std.testing.expectEqual(@as(usize, 0), scratch.items.len);
        expected.clearRetainingCapacity();
    }
}

test "empty store has no postings" {
    const allocator = std.testing.allocator;
    var tree = try Ast.parse(allocator, "", .zig);
    defer tree.deinit(allocator);

    var store = try TrigramStore.init(allocator, &tree);
    defer store.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), store.trigram_to_declarations.count());
    try std.testing.expectEqual(@as(usize, 0), store.postings.len);
    try std.testing.expect(store.filter_buckets == null);
}

test "deep container nesting overflows inline function stack" {
    const allocator = std.testing.allocator;
    var source_writer: std.Io.Writer.Allocating = .init(allocator);
    defer source_writer.deinit();

    for (0..20) |_| {
        try source_writer.writer.writeAll("const Nested = struct {\n");
    }
    try source_writer.writer.writeAll("const deepest_symbol = 0;\n");
    for (0..20) |_| {
        try source_writer.writer.writeAll("};\n");
    }
    const source = try source_writer.toOwnedSliceSentinel(0);
    defer allocator.free(source);

    var tree = try Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);

    var store = try TrigramStore.init(allocator, &tree);
    defer store.deinit(allocator);
    var declarations: std.ArrayList(Declaration.Index) = .empty;
    defer declarations.deinit(allocator);
    try store.declarationsForQuery(allocator, "deepest_symbol", &declarations);
    try std.testing.expectEqual(@as(usize, 1), declarations.items.len);
}

test "Cuckoo filter is reserved for queries with long first postings" {
    const allocator = std.testing.allocator;

    const Test = struct {
        fn run(allocator_: std.mem.Allocator, declaration_count: usize, expect_filter: bool) !void {
            var source_writer: std.Io.Writer.Allocating = .init(allocator_);
            defer source_writer.deinit();

            for (0..declaration_count) |_| {
                source_writer.writer.writeAll("const common_symbol = 0;\n") catch return error.OutOfMemory;
            }
            source_writer.writer.writeAll("const rare_unique = 0;\n") catch return error.OutOfMemory;
            const source = try source_writer.toOwnedSliceSentinel(0);
            defer allocator_.free(source);

            var tree = try Ast.parse(allocator_, source, .zig);
            defer tree.deinit(allocator_);
            try std.testing.expectEqual(@as(usize, 0), tree.errors.len);

            var store = try TrigramStore.init(allocator_, &tree);
            defer store.deinit(allocator_);
            try std.testing.expectEqual(expect_filter, store.filter_buckets != null);

            var declarations: std.ArrayList(Declaration.Index) = .empty;
            defer declarations.deinit(allocator_);

            try store.declarationsForQuery(allocator_, "common_symbol", &declarations);
            try std.testing.expectEqual(declaration_count, declarations.items.len);

            declarations.clearRetainingCapacity();
            try store.declarationsForQuery(allocator_, "common_missing", &declarations);
            try std.testing.expectEqual(@as(usize, 0), declarations.items.len);

            declarations.clearRetainingCapacity();
            try store.declarationsForQuery(allocator_, "rare_unique", &declarations);
            try std.testing.expectEqual(@as(usize, 1), declarations.items.len);

            if (store.filter_buckets) |buckets| {
                // Short postings bypass the filter, while long postings use it.
                @memset(buckets, @splat(.none));

                declarations.clearRetainingCapacity();
                try store.declarationsForQuery(allocator_, "rare_unique", &declarations);
                try std.testing.expectEqual(@as(usize, 1), declarations.items.len);

                declarations.clearRetainingCapacity();
                try store.declarationsForQuery(allocator_, "common_symbol", &declarations);
                try std.testing.expectEqual(@as(usize, 0), declarations.items.len);
            }
        }
    };

    try Test.run(allocator, filter_min_posting_len - 1, false);
    try Test.run(allocator, filter_min_posting_len, true);
}

test "TrigramStore.init handles every allocation failure" {
    var source_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer source_writer.deinit();
    for (0..filter_min_posting_len) |_| {
        source_writer.writer.writeAll("const common_symbol = 0;\n") catch return error.OutOfMemory;
    }
    const source = try source_writer.toOwnedSliceSentinel(0);
    defer std.testing.allocator.free(source);

    var tree = try Ast.parse(std.testing.allocator, source, .zig);
    defer tree.deinit(std.testing.allocator);

    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn init(allocator: std.mem.Allocator, ast_tree: *const Ast) !void {
            var store = try TrigramStore.init(allocator, ast_tree);
            defer store.deinit(allocator);
        }
    }.init, .{&tree});
}

test "dense declaration capacity sampling" {
    const small = [_]Ast.Node.Tag{.container_field} ** 4095;
    try std.testing.expectEqual(0, denseDeclarationCapacityFromTags(&small));

    var ordinary = [_]Ast.Node.Tag{.identifier} ** 4096;
    for (0..16) |index| ordinary[index * 64] = .container_field;
    try std.testing.expectEqual(0, denseDeclarationCapacityFromTags(&ordinary));

    const dense = [_]Ast.Node.Tag{.container_field} ** 4096;
    try std.testing.expectEqual(dense.len + 16, denseDeclarationCapacityFromTags(&dense));
}

const CuckooFilter = struct {
    buckets: []Bucket,
    const target_load_percentage = 70;

    pub const Fingerprint = enum(u8) {
        none = std.math.maxInt(u8),
        _,

        const precomputed_odd_hashes = blk: {
            var table: [255]u32 = undefined;

            for (&table, 0..) |*h, index| {
                h.* = @truncate(std.hash.Murmur2_64.hash(&.{index}) | 1);
            }

            break :blk table;
        };

        pub fn oddHash(fingerprint: Fingerprint) u32 {
            assert(fingerprint != .none);
            return precomputed_odd_hashes[@intFromEnum(fingerprint)];
        }
    };

    pub const Bucket = [4]Fingerprint;
    pub const BucketIndex = enum(u32) {
        _,

        pub fn alternate(index: BucketIndex, fingerprint: Fingerprint, len: u32) BucketIndex {
            assert(@intFromEnum(index) < len);
            assert(fingerprint != .none);

            const signed_index: i64 = @intFromEnum(index);
            const odd_hash: i64 = fingerprint.oddHash();

            const unbounded = switch (parity(signed_index)) {
                .even => signed_index + odd_hash,
                .odd => signed_index - odd_hash,
            };
            const bounded: u32 = @intCast(@mod(unbounded, len));

            assert(parity(signed_index) != parity(bounded));

            return @enumFromInt(bounded);
        }
    };

    pub const Triplet = struct {
        fingerprint: Fingerprint,
        index_1: BucketIndex,
        index_2: BucketIndex,

        pub fn initFromTrigram(trigram: Trigram, len: u32) Triplet {
            const split: packed struct {
                fingerprint: Fingerprint,
                padding: u24,
                index_1: u32,
            } = @bitCast(std.hash.Murmur2_64.hash(&trigram));

            const index_1: BucketIndex = @enumFromInt(split.index_1 % len);

            const fingerprint: Fingerprint = if (split.fingerprint == .none)
                @enumFromInt(1)
            else
                split.fingerprint;

            const triplet: Triplet = .{
                .fingerprint = fingerprint,
                .index_1 = index_1,
                .index_2 = index_1.alternate(fingerprint, len),
            };
            assert(triplet.index_2.alternate(fingerprint, len) == index_1);

            return triplet;
        }
    };

    pub fn init(buckets: []Bucket) CuckooFilter {
        assert(parity(buckets.len) == .even);
        return .{ .buckets = buckets };
    }

    pub fn reset(filter: CuckooFilter) void {
        @memset(filter.buckets, @splat(.none));
    }

    pub fn capacityForCount(count: usize) error{Overflow}!usize {
        const bucket_count = std.math.divCeil(usize, try std.math.mul(usize, count, 100), @typeInfo(Bucket).array.len * target_load_percentage) catch |err| switch (err) {
            error.DivisionByZero => unreachable,
            else => |e| return e,
        };
        return bucket_count + (bucket_count & 1);
    }

    pub fn append(filter: CuckooFilter, random: std.Random, trigram: Trigram) error{EvictionFailed}!void {
        const triplet: Triplet = .initFromTrigram(trigram, @intCast(filter.buckets.len));

        if (filter.appendToBucket(triplet.index_1, triplet.fingerprint) or
            filter.appendToBucket(triplet.index_2, triplet.fingerprint))
        {
            return;
        }

        var fingerprint = triplet.fingerprint;
        var index = if (random.boolean()) triplet.index_1 else triplet.index_2;
        for (0..500) |_| {
            fingerprint = filter.swapFromBucket(random, index, fingerprint);
            index = index.alternate(fingerprint, @intCast(filter.buckets.len));

            if (filter.appendToBucket(index, fingerprint)) {
                return;
            }
        }

        return error.EvictionFailed;
    }

    fn bucketAt(filter: CuckooFilter, index: BucketIndex) *Bucket {
        return &filter.buckets[@intFromEnum(index)];
    }

    fn appendToBucket(filter: CuckooFilter, index: BucketIndex, fingerprint: Fingerprint) bool {
        assert(fingerprint != .none);

        const bucket = filter.bucketAt(index);
        for (bucket) |*slot| {
            if (slot.* == .none) {
                slot.* = fingerprint;
                return true;
            }
        }

        return false;
    }

    fn swapFromBucket(
        filter: CuckooFilter,
        random: std.Random,
        index: BucketIndex,
        fingerprint: Fingerprint,
    ) Fingerprint {
        assert(fingerprint != .none);

        comptime assert(@typeInfo(Bucket).array.len == 4);
        const target = &filter.bucketAt(index)[random.int(u2)];

        const old_fingerprint = target.*;
        assert(old_fingerprint != .none);

        target.* = fingerprint;

        return old_fingerprint;
    }

    pub fn contains(filter: CuckooFilter, trigram: Trigram) bool {
        const triplet: Triplet = .initFromTrigram(trigram, @intCast(filter.buckets.len));

        return filter.containsInBucket(triplet.index_1, triplet.fingerprint) or
            filter.containsInBucket(triplet.index_2, triplet.fingerprint);
    }

    fn containsInBucket(filter: CuckooFilter, index: BucketIndex, fingerprint: Fingerprint) bool {
        assert(fingerprint != .none);

        const bucket: u32 = @bitCast(filter.bucketAt(index).*);
        const needle: u32 = @as(u32, @intFromEnum(fingerprint)) * 0x01010101;
        const matches = bucket ^ needle;
        return ((matches -% 0x01010101) & ~matches & 0x80808080) != 0;
    }

    fn parity(integer: anytype) enum(u1) { even, odd } {
        return @enumFromInt(integer & 1);
    }
};

test CuckooFilter {
    const allocator = std.testing.allocator;

    const element_count = 499;
    const filter_size = comptime CuckooFilter.capacityForCount(element_count) catch unreachable;
    comptime assert(filter_size == 180);

    var entries: std.array_hash_map.Auto(Trigram, void) = .empty;
    defer entries.deinit(allocator);
    try entries.ensureTotalCapacity(allocator, element_count);

    var buckets: [filter_size]CuckooFilter.Bucket = undefined;
    var filter: CuckooFilter = .init(&buckets);
    var filter_prng: std.Random.DefaultPrng = .init(42);

    for (0..2_500) |gen_prng_seed| {
        entries.clearRetainingCapacity();
        filter.reset();

        var gen_prng: std.Random.DefaultPrng = .init(gen_prng_seed);
        for (0..element_count) |_| {
            const trigram: Trigram = @bitCast(gen_prng.random().int(u24));
            entries.putAssumeCapacity(trigram, {});
            try filter.append(filter_prng.random(), trigram);
        }

        // No false negatives
        for (entries.keys()) |trigram| {
            try std.testing.expect(filter.contains(trigram));
        }

        // Reasonable false positive rate
        const fpr_count = 2_500;
        var false_positives: usize = 0;
        var negative_prng: std.Random.DefaultPrng = .init(~gen_prng_seed);
        for (0..fpr_count) |_| {
            var trigram: Trigram = @bitCast(negative_prng.random().int(u24));
            while (entries.contains(trigram)) {
                trigram = @bitCast(negative_prng.random().int(u24));
            }

            false_positives += @intFromBool(filter.contains(trigram));
        }

        const fpr = @as(f32, @floatFromInt(false_positives)) / fpr_count;

        errdefer std.log.err("fpr: {d}%", .{fpr * 100});
        try std.testing.expect(fpr < 0.035);
    }
}

test "CuckooFilter - varied sizes" {
    const allocator = std.testing.allocator;
    const element_counts = [_]usize{ 1, 2, 3, 7, 31, 127, 499, 1_023, 4_095 };

    for (element_counts) |element_count| {
        const filter_size = try CuckooFilter.capacityForCount(element_count);
        const buckets = try allocator.alloc(CuckooFilter.Bucket, filter_size);
        defer allocator.free(buckets);
        const filter: CuckooFilter = .init(buckets);
        var entries: std.AutoHashMapUnmanaged(Trigram, void) = .empty;
        defer entries.deinit(allocator);
        try entries.ensureTotalCapacity(allocator, @intCast(element_count));

        for (0..64) |seed| {
            filter.reset();
            entries.clearRetainingCapacity();
            var source_prng: std.Random.DefaultPrng = .init(seed);
            var filter_prng: std.Random.DefaultPrng = .init(~seed);
            while (entries.count() < element_count) {
                const trigram: Trigram = @bitCast(source_prng.random().int(u24));
                if (entries.contains(trigram)) continue;
                entries.putAssumeCapacity(trigram, {});
                try filter.append(filter_prng.random(), trigram);
            }
            var key_iterator = entries.keyIterator();
            while (key_iterator.next()) |trigram| try std.testing.expect(filter.contains(trigram.*));
        }
    }
}

test "CuckooFilter bucket matching" {
    var prng: std.Random.DefaultPrng = .init(0);
    for (0..4_096) |_| {
        var buckets: [2]CuckooFilter.Bucket = undefined;
        prng.random().bytes(std.mem.asBytes(&buckets[0]));
        const filter: CuckooFilter = .init(&buckets);
        for (0..std.math.maxInt(u8)) |value| {
            const fingerprint: CuckooFilter.Fingerprint = @enumFromInt(value);
            const expected = for (buckets[0]) |slot| {
                if (slot == fingerprint) break true;
            } else false;
            try std.testing.expectEqual(expected, filter.containsInBucket(@enumFromInt(0), fingerprint));
        }
    }
}
