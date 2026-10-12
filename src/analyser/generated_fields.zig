//! Source provenance for fields copied through comptime reflection and generated containers.
const std = @import("std");
const Analyser = @import("../analysis.zig");

pub fn source(
    analyser: *Analyser,
    container: Analyser.Type,
    name: []const u8,
) error{OutOfMemory}!?Analyser.TokenWithHandle {
    const ty = if (container.is_type_val) container else try container.typeOf(analyser);
    if (ty.ipIndex()) |index| {
        if (analyser.generatedFields(index)) |fields| {
            for (fields) |field| {
                if (std.mem.eql(u8, field.name, name)) return field.source;
            }
        }
    }
    const declaration = try analyser.lookupSymbolContainer(ty, name, .field) orelse return null;
    return .{ .handle = declaration.handle, .token = declaration.nameToken() };
}

pub fn nameValue(
    analyser: *Analyser,
    container: Analyser.Type,
    name: []const u8,
    string_type: Analyser.Type,
) error{OutOfMemory}!Analyser.Type {
    var value = try analyser.stringValueWithType(name, string_type);
    value.data.string_value.source = try source(analyser, container, name);
    return value;
}
