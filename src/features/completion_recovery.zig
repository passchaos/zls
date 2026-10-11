//! Source snapshots used to recover completion in incomplete expressions.
const std = @import("std");
const offsets = @import("../offsets.zig");
const types = @import("lsp").types;

pub const identifier_placeholder = "__zls_completion";

pub fn createIdentifierSource(arena: std.mem.Allocator, source: []const u8, index: usize) error{OutOfMemory}![:0]const u8 {
    return std.mem.concatWithSentinel(arena, u8, &.{ source[0..index], identifier_placeholder, source[index..] }, 0);
}

/// Snapshot positions after the inserted identifier refer to later bytes on
/// the same line. Collapse the identifier back to the original empty range.
pub fn restoreIdentifierRanges(items: []types.completion.Item, insertion: types.Position) void {
    for (items) |*item| {
        if (item.textEdit) |*edit| switch (edit.*) {
            .text_edit => |*value| restoreRange(&value.range, insertion),
            .insert_replace_edit => |*value| {
                restoreRange(&value.insert, insertion);
                restoreRange(&value.replace, insertion);
            },
        };
        if (item.additionalTextEdits) |edits| {
            for (@constCast(edits)) |*edit| restoreRange(&edit.range, insertion);
        }
    }
}

fn restoreRange(range: *types.Range, insertion: types.Position) void {
    restorePosition(&range.start, insertion);
    restorePosition(&range.end, insertion);
}

fn restorePosition(position: *types.Position, insertion: types.Position) void {
    if (position.line != insertion.line or position.character <= insertion.character) return;
    position.character -= @min(position.character - insertion.character, identifier_placeholder.len);
}

pub fn createPrefixSource(
    arena: std.mem.Allocator,
    original_source: []const u8,
    source_index: usize,
) error{OutOfMemory}![:0]const u8 {
    var completion_end = source_index;
    while (completion_end < original_source.len and offsets.isSymbolChar(original_source[completion_end])) {
        completion_end += 1;
    }
    const prefix = original_source[0..completion_end];
    const has_trailing_comma = completion_end < original_source.len and original_source[completion_end] == ',';

    var source: std.ArrayList(u8) = .empty;
    try source.appendSlice(arena, prefix);
    for (original_source[completion_end..]) |char| {
        try source.append(arena, if (char == '\n') '\n' else ' ');
    }

    const token_source = try arena.dupeZ(u8, prefix);
    var tokenizer: std.zig.Tokenizer = .init(token_source);
    var delimiters: std.ArrayList(std.zig.Token.Tag) = .empty;
    var last_tag: std.zig.Token.Tag = .eof;
    var previous_tag: std.zig.Token.Tag = .eof;
    var continue_delimiter_depth: ?usize = null;
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        previous_tag = last_tag;
        last_tag = token.tag;
        switch (token.tag) {
            .l_paren, .l_bracket, .l_brace => try delimiters.append(arena, token.tag),
            .r_paren => {
                popMatchingDelimiter(&delimiters, .l_paren);
                if (continue_delimiter_depth) |depth| {
                    if (delimiters.items.len < depth) continue_delimiter_depth = null;
                }
            },
            .r_bracket => {
                popMatchingDelimiter(&delimiters, .l_bracket);
                if (continue_delimiter_depth) |depth| {
                    if (delimiters.items.len < depth) continue_delimiter_depth = null;
                }
            },
            .r_brace => {
                popMatchingDelimiter(&delimiters, .l_brace);
                if (continue_delimiter_depth) |depth| {
                    if (delimiters.items.len < depth) continue_delimiter_depth = null;
                }
            },
            .keyword_continue => continue_delimiter_depth = delimiters.items.len,
            .semicolon => continue_delimiter_depth = null,
            .comma => if (continue_delimiter_depth) |depth| {
                if (delimiters.items.len <= depth) continue_delimiter_depth = null;
            },
            else => {},
        }
    }

    const completing_struct_field = last_tag == .period and
        delimiters.getLastOrNull() == .l_brace and
        (previous_tag == .l_brace or previous_tag == .comma);
    switch (last_tag) {
        .period, .period_asterisk => {
            try source.appendSlice(arena, "__zls_completion");
            if (completing_struct_field) try source.appendSlice(arena, " = undefined");
            if (has_trailing_comma and delimiters.items.len != 0) try source.append(arena, ',');
        },
        else => {},
    }

    var inserted_statement_terminator = has_trailing_comma and delimiters.items.len != 0;
    var delimiter_index = delimiters.items.len;
    var close_struct_initializer = completing_struct_field;
    if (last_tag == .period) {
        if (continue_delimiter_depth) |outer_depth| {
            if (outer_depth < delimiter_index) {
                while (delimiter_index > outer_depth) {
                    delimiter_index -= 1;
                    try source.append(arena, closingDelimiter(delimiters.items[delimiter_index]));
                }
                try source.append(arena, ',');
                inserted_statement_terminator = true;
            }
        }
    }
    while (delimiter_index > 0) {
        delimiter_index -= 1;
        const delimiter = delimiters.items[delimiter_index];
        switch (delimiter) {
            .l_paren, .l_bracket => try source.append(arena, closingDelimiter(delimiter)),
            .l_brace => {
                if (close_struct_initializer) {
                    close_struct_initializer = false;
                    try source.append(arena, '}');
                    continue;
                }
                if (!inserted_statement_terminator) {
                    try source.append(arena, ';');
                    inserted_statement_terminator = true;
                }
                try source.append(arena, '}');
            },
            else => unreachable,
        }
    }
    if (!inserted_statement_terminator or completing_struct_field) try source.append(arena, ';');
    return try source.toOwnedSliceSentinel(arena, 0);
}

fn closingDelimiter(open: std.zig.Token.Tag) u8 {
    return switch (open) {
        .l_paren => ')',
        .l_bracket => ']',
        .l_brace => '}',
        else => unreachable,
    };
}

fn popMatchingDelimiter(delimiters: *std.ArrayList(std.zig.Token.Tag), expected: std.zig.Token.Tag) void {
    if (delimiters.getLastOrNull() == expected) _ = delimiters.pop();
}
