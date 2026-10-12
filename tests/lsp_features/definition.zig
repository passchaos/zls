const std = @import("std");
const zls = @import("zls");

const helper = @import("../helper.zig");
const Context = @import("../context.zig").Context;
const ErrorBuilder = @import("../ErrorBuilder.zig");

const types = zls.lsp.types;
const offsets = zls.offsets;

const allocator: std.mem.Allocator = std.testing.allocator;

test "global variable" {
    try testDefinition(
        \\const <def><decl>foo</decl></def> = 5;
        \\comptime {
        \\    _ = <>foo;
        \\}
    );
    try testDefinition(
        \\const <def><decl>foo</decl></def>: <tdef>u32</tdef> = 5;
        \\comptime {
        \\    _ = <>foo;
        \\}
    );
    try testDefinition(
        \\const <def><decl><>foo</decl></def> = 5;
    );
    try testDefinition(
        \\const <def><decl><>foo</decl></def>: <tdef>u32</tdef> = 5;
    );

    try testDefinition(
        \\const S = <tdef>struct</tdef> { alpha: u32 };
        \\const <def><decl><>s</decl></def>: S  = S{ .alpha = 5 };
    );

    try testDefinition(
        \\const S = <tdef>struct</tdef> { alpha: u32 };
        \\const <def><decl><>s</decl></def> = S{ .alpha = 5 };
    );
}

test "local variable" {
    try testDefinition(
        \\comptime {
        \\    var <def><decl>foo</decl></def> = 5;
        \\    {
        \\        var bar = 5;
        \\        _ = <>foo;
        \\        _ = bar;
        \\    }
        \\}
    );
    try testDefinition(
        \\comptime {
        \\    var foo = 5;
        \\    {
        \\        var <def><decl>bar</decl></def> = 5;
        \\        _ = foo;
        \\        _ = <>bar;
        \\    }
        \\}
    );
}

test "assign destructure" {
    try testDefinition(
        \\test {
        \\    const foo, const <def><decl>bar</decl></def>: <tdef>u32</tdef> = .{ 1, 2 };
        \\    _ = foo;
        \\    _ = <>bar;
        \\}
    );
    try testDefinition(
        \\test {
        \\    var <def><decl>foo</decl></def>: <tdef>u32</tdef> = undefined;
        \\    foo, const bar: u32 = .{ 1, 2 };
        \\    _ = <>foo;
        \\    _ = bar;
        \\}
    );
}

test "function parameter" {
    try testDefinition(
        \\fn f(<def><decl>foo</decl></def>: <tdef>u32</tdef>) void {
        \\    _ = <>foo;
        \\}
    );
}

test "inferred struct init" {
    try testDefinition(
        \\const S = <tdef><def>struct</def></tdef> { alpha: u32 };
        \\const foo: S = .<>{ .alpha = 5 };
    );
    try testDefinition(
        \\const S = <tdef><def>struct</def></tdef> { alpha: u32 };
        \\fn f(_: S) void {}
        \\const foo = f(<>.{ .alpha = 5 });
    );
}

test "struct init field through dependent generic call parameter" {
    try testDefinition(
        \\const Contract = struct {
        \\    const Associated = struct { <def><decl>Error</decl></def>: <tdef>type</tdef> = anyerror };
        \\};
        \\const implementation = struct {
        \\    fn make(comptime C: type, comptime associated: C.Associated) void {
        \\        _ = associated;
        \\    }
        \\};
        \\const api = struct { const make = implementation.make; };
        \\comptime { api.make(Contract, .{ .<>Error = anyerror }); }
    );
}

test "field access" {
    try testDefinition(
        \\const S = struct { <def><decl>alpha</decl></def>: <tdef>u32</tdef> };
        \\var s: S = undefined;
        \\const foo = s.<>alpha;
    );
    try testDefinition(
        \\const S = struct { <def><decl>alpha</decl></def>: <tdef>u32</tdef> };
        \\const foo = (S{ .alpha = undefined }).<>alpha;
    );
    try testDefinition(
        \\const S = struct { <def><decl>callback</decl></def>: *const <tdef>fn</tdef> (arg: S) void };
        \\const s: S = undefined;
        \\const cb = s.<>callback;
    );
    try testDefinition(
        \\const S = struct { <tdef>fn</tdef> <def><decl>method</decl></def>(self: S) void {} };
        \\const s: S = undefined;
        \\s.<>method();
    );
}

test "struct init" {
    try testDefinition(
        \\const S = struct { <def><decl>alpha</decl></def>: <tdef>u32</tdef> };
        \\var s = S{ .<>alpha = 5};
    );
}

test "decl literal on generic type" {
    try testDefinition(
        \\fn Box(comptime T: type) type {
        \\    return <tdef>struct</tdef> {
        \\        item: T,
        \\        const <def><decl>init</decl></def>: @This() = undefined;
        \\    };
        \\};
        \\test {
        \\    const box: Box(u8) = .in<>it;
        \\}
    );
}

test "method on forwarded type function with dependent comptime value" {
    try testDefinition(
        \\const std = @import("std");
        \\const Reader = struct {
        \\    const Associated = struct { Error: type = anyerror };
        \\    fn Methods(comptime Self: type, comptime assoc: Associated) type {
        \\        return struct { read: fn (Self, []u8) assoc.Error!usize };
        \\    }
        \\};
        \\fn associatedFor(comptime C: type, comptime _: type) C.Associated {
        \\    return .{};
        \\}
        \\fn methodsType(comptime C: type, comptime Subject: type, comptime associated: C.Associated) type {
        \\    return C.Methods(Subject, associated);
        \\}
        \\fn Method(comptime C: type, comptime Subject: type, comptime associated: C.Associated) type {
        \\    return std.meta.FieldEnum(methodsType(C, Subject, associated));
        \\}
        \\fn methodType(comptime C: type, comptime Subject: type, comptime associated: C.Associated, comptime method: Method(C, Subject, associated)) type {
        \\    return @FieldType(methodsType(C, Subject, associated), @tagName(method));
        \\}
        \\fn Impl(comptime C: type, comptime Subject: type) type {
        \\    return ImplWith(C, Subject, associatedFor(C, Subject));
        \\}
        \\fn ImplWith(
        \\    comptime C: type,
        \\    comptime Subject: type,
        \\    comptime associated: C.Associated,
        \\) type {
        \\    const M = Method(C, Subject, associated);
        \\    return struct {
        \\        bindings: u8 = 0,
        \\        const Self = @This();
        \\        pub inline <tdef>fn</tdef> <def><decl>call</decl></def>(
        \\            comptime _: Self,
        \\            comptime method: M,
        \\            args: std.meta.ArgsTuple(methodType(C, Subject, associated, method)),
        \\        ) @typeInfo(methodType(C, Subject, associated, method)).@"fn".return_type.? {
        \\            return @call(.auto, @field(Subject, @tagName(method)), args);
        \\        }
        \\    };
        \\}
        \\const Buffer = struct {
        \\    fn read(_: *Buffer, _: []u8) anyerror!usize { return 0; }
        \\};
        \\fn count(comptime impl: Impl(Reader, *Buffer)) void {
        \\    _ = impl.ca<>ll(.read, .{ undefined, undefined });
        \\}
    );
}

test "FieldEnum literal maps to source field" {
    try testDefinition(
        \\const std = @import("std");
        \\const Reader = struct {
        \\    const Associated = struct { Error: type = anyerror };
        \\    fn Methods(comptime Self: type, comptime assoc: Associated) type {
        \\        return struct { <def><decl>read</decl></def>: <tdef>fn</tdef> (Self, []u8) assoc.Error!usize };
        \\    }
        \\};
        \\fn Method(comptime Subject: type) type {
        \\    return std.meta.FieldEnum(Reader.Methods(Subject, .{}));
        \\}
        \\fn use(comptime method: Method(*u8)) void { _ = method; }
        \\comptime { use(.re<>ad); }
    );
}

test "enum literal through dependent generic function argument" {
    try testDefinition(
        \\const api = struct {
        \\    const Access = <tdef>enum</tdef> { read_only, <def><decl>mutable</decl></def> };
        \\    fn use(comptime T: type, comptime value: T, comptime access: Access) bool {
        \\        _ = value;
        \\        return access == .mutable;
        \\    }
        \\};
        \\const result = api.use(u8, 0, .mut<>able);
    );
}

test "error literal maps to local error set member" {
    try testDefinition(
        \\const Failure = error { <def><decl>ExpectedFailure</decl></def> };
        \\fn run() Failure!void { return error.Exp<>ectedFailure; }
    );

    try testDefinition(
        \\const Failure = error { <def><decl>ExpectedFailure</decl></def> };
        \\fn accepts(_: anyerror, _: anytype) void {}
        \\const result = accepts(error.Exp<>ectedFailure, undefined);
    );
}

test "comptime method on generated Struct default" {
    try testDefinition(
        \\const std = @import("std");
        \\const Reader = struct { const Associated = struct { Error: type = anyerror }; };
        \\const Seekable = struct { const Associated = struct { Error: type = anyerror }; };
        \\fn Model(comptime C: type, comptime associated: C.Associated) type {
        \\    std.debug.assert(@sizeOf(C.Associated) != 0);
        \\    const Methods = struct { read: fn () void };
        \\    const Method = std.meta.FieldEnum(Methods);
        \\    return struct {
        \\        binding: ?@FieldType(Methods, @tagName(Method.read)) = null,
        \\        const Self = @This();
        \\        pub <tdef>fn</tdef> <def><decl>associated</decl></def>(comptime _: Self) C.Associated { return associated; }
        \\    };
        \\}
        \\fn makeModel(comptime C: type) type { return Model(C, .{}); }
        \\fn setField(comptime index: usize, comptime name: [:0]const u8, comptime M: type,
        \\    names: anytype, types: anytype, attrs: anytype) void
        \\{
        \\    const Default = struct { const value: M = .{}; };
        \\    names[index] = name;
        \\    types[index] = M;
        \\    attrs[index] = .{ .default_value_ptr = @ptrCast(&Default.value) };
        \\}
        \\fn Generated(comptime capabilities: anytype) type {
        \\    const fields = @typeInfo(@TypeOf(capabilities)).@"struct".fields;
        \\    comptime var names: [fields.len][:0]const u8 = undefined;
        \\    comptime var types: [fields.len]type = undefined;
        \\    comptime var attrs: [fields.len]std.builtin.Type.StructField.Attributes = undefined;
        \\    inline for (fields, 0..) |field, index| {
        \\        const capability = @field(capabilities, field.name);
        \\        const M = if (@TypeOf(capability) == type) makeModel(capability) else @TypeOf(capability);
        \\        setField(index, field.name, M, &names, &types, &attrs);
        \\    }
        \\    return @Struct(.auto, null, &names, &types, &attrs);
        \\}
        \\const broad_reader: Model(Reader, .{ .Error = anyerror }) = .{};
        \\const models: Generated(.{ .reader = broad_reader, .seekable = Seekable }) = .{};
        \\comptime {
        \\    _ = models.reader.asso<>ciated();
        \\}
    );
}

test "definition through runtime struct size selection" {
    try testDefinition(
        \\fn Dynamic(comptime Context: type, comptime Table: type) type {
        \\    return struct {
        \\        context: *Context,
        \\        vtable: *const Table,
        \\    };
        \\}
        \\fn Select() type {
        \\    const AnyReader = Dynamic(u8, u16);
        \\    return if (@sizeOf(AnyReader) == 2 * @sizeOf(usize))
        \\        struct { <def><decl>matched</decl></def>: <tdef>u8</tdef> }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.mat<>ched;
    );
}

test "definition through comptime instance method selection" {
    try testDefinition(
        \\const Decision = struct {
        \\    enabled: bool,
        \\    fn select(self: @This()) type {
        \\        return if (self.enabled)
        \\            struct { <def><decl>matched</decl></def>: <tdef>u8</tdef> }
        \\        else
        \\            struct { fallback: u8 };
        \\    }
        \\};
        \\fn Select() type {
        \\    const decision = Decision{ .enabled = true };
        \\    return decision.select();
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.mat<>ched;
    );
}

test "definition through nested aggregate comptime value" {
    try testDefinition(
        \\const ConcreteError = error{Failed};
        \\const Contract = struct { const Associated = struct { Error: type = anyerror }; };
        \\fn associatedFor() Contract.Associated {
        \\    return .{ .Error = ConcreteError };
        \\}
        \\fn Inner(comptime associated: Contract.Associated) type {
        \\    return struct { const stored = associated; };
        \\}
        \\fn Outer() type {
        \\    return Inner(associatedFor());
        \\}
        \\fn Select() type {
        \\    return if (Outer().stored.Error == ConcreteError)
        \\        struct { <def><decl>matched</decl></def>: <tdef>u8</tdef> }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.mat<>ched;
    );
}

test "definition through generated Struct default method result" {
    try testDefinition(
        \\const std = @import("std");
        \\fn Bindings() type {
        \\    const Default = struct { const value: ?fn () void = null; };
        \\    return @Struct(.auto, null, &.{"read"}, &.{?fn () void}, &.{.{
        \\        .default_value_ptr = @ptrCast(&Default.value),
        \\    }});
        \\}
        \\fn Model() type {
        \\    return struct {
        \\        bindings: Bindings() = .{},
        \\        fn missing(comptime self: @This()) bool {
        \\            return @field(self.bindings, "read") == null;
        \\        }
        \\    };
        \\}
        \\const model: Model() = .{};
        \\fn Select() type {
        \\    return if (model.missing())
        \\        struct { <def><decl>matched</decl></def>: <tdef>u8</tdef> }
        \\    else
        \\        struct { fallback: u8 };
        \\}
        \\const selected: Select() = undefined;
        \\const field = selected.mat<>ched;
    );
}

test "generated Struct field falls back to its type definition" {
    try testDefinition(
        \\const Model = struct {
        \\    const <def><tdef>Self</tdef></def> = @This();
        \\    value: u8 = 0,
        \\};
        \\fn Generated() type {
        \\    return @Struct(.auto, null, &.{"reader"}, &.{Model}, &.{.{} });
        \\}
        \\const models: Generated() = .{};
        \\const selected = models.rea<>der;
    );
    try testDefinition(
        \\const Callback = <def><tdef>fn</tdef></def> (u8) void;
        \\fn Generated() type {
        \\    return @Struct(.auto, null, &.{"callback"}, &.{?Callback}, &.{.{} });
        \\}
        \\const value: Generated() = .{ .call<>back = null };
    );
}

test "comptime error integer roundtrip selects definition" {
    try testDefinition(
        \\const Wrong = struct { const selected: u16 = 0; };
        \\const Right = struct { const <def><decl>selected</decl></def>: <tdef>u8</tdef> = 1; };
        \\fn select() type {
        \\    const code = @intFromError(error.Failure);
        \\    if (@errorFromInt(code) == error.Failure) return Right;
        \\    return Wrong;
        \\}
        \\const Choice = select();
        \\const value = Choice.sel<>ected;
    );
}

test "comptime read-only pointer reinterpretation selects definition" {
    try testDefinition(
        \\const Wrong = struct { const selected: u16 = 0; };
        \\const Right = struct { const <def><decl>selected</decl></def>: <tdef>u8</tdef> = 1; };
        \\fn bytes() [*]const u8 { return &.{ 1, 255 }; }
        \\fn signed() [*]const i8 { return @ptrCast(bytes()); }
        \\fn select() type {
        \\    if (signed()[0] == 1 and signed()[1] == -1) return Right;
        \\    return Wrong;
        \\}
        \\const Choice = select();
        \\const value = Choice.sel<>ected;
    );
}

test "comptime float bitCast selects definition" {
    try testDefinition(
        \\const Wrong = struct { const selected: u16 = 0; };
        \\const Right = struct { const <def><decl>selected</decl></def>: <tdef>u8</tdef> = 1; };
        \\fn select() type {
        \\    const bits: u32 = @bitCast(@as(f32, 1.0));
        \\    if (bits == 0x3f800000) return Right;
        \\    return Wrong;
        \\}
        \\const Choice = select();
        \\const value = Choice.sel<>ected;
    );
}

test "comptime boolean bitCast selects definition" {
    try testDefinition(
        \\const Wrong = struct { const selected: u16 = 0; };
        \\const Right = struct { const <def><decl>selected</decl></def>: <tdef>u8</tdef> = 1; };
        \\fn select() type {
        \\    const value: bool = @bitCast(@as(i1, -1));
        \\    if (value) return Right;
        \\    return Wrong;
        \\}
        \\const Choice = select();
        \\const value = Choice.sel<>ected;
    );
}

test "comptime array vector bitCast selects definition" {
    try testDefinition(
        \\const Wrong = struct { const selected: u16 = 0; };
        \\const Right = struct { const <def><decl>selected</decl></def>: <tdef>u8</tdef> = 1; };
        \\fn select() type {
        \\    const vector: @Vector(4, i8) = .{ 2, 3, -1, 1 };
        \\    const array: [3:0]u8 = @bitCast(vector);
        \\    if (array[2] == 255 and array[3] == 0) return Right;
        \\    return Wrong;
        \\}
        \\const Choice = select();
        \\const value = Choice.sel<>ected;
    );
}

test "generated Struct fields navigate to reflected source names" {
    try testDefinition(
        \\const std = @import("std");
        \\const Methods = struct { <def><decl>read</decl></def>: <tdef>fn</tdef> (u8) void };
        \\fn Bindings(comptime T: type) type {
        \\    const fields = @typeInfo(T).@"struct".fields;
        \\    comptime var names: [fields.len][:0]const u8 = undefined;
        \\    comptime var types: [fields.len]type = undefined;
        \\    inline for (fields, 0..) |field, index| {
        \\        names[index] = field.name;
        \\        types[index] = ?field.type;
        \\    }
        \\    return @Struct(.auto, null, &names, &types, &.{.{} });
        \\}
        \\const bindings: Bindings(Methods) = .{ .re<>ad = null };
    );
    try testDefinition(
        \\const std = @import("std");
        \\const Model = <tdef>struct</tdef> { value: u8 };
        \\fn setName(comptime name: [:0]const u8, names: anytype) void {
        \\    names[0] = name;
        \\}
        \\fn Generated(comptime capabilities: anytype) type {
        \\    const fields = @typeInfo(@TypeOf(capabilities)).@"struct".fields;
        \\    comptime var names: [fields.len][:0]const u8 = undefined;
        \\    inline for (fields) |field| setName(field.name, &names);
        \\    return @Struct(.auto, null, &names, &.{Model}, &.{.{} });
        \\}
        \\const Models = Generated(.{ .<def><decl>reader</decl></def> = Model });
        \\const models: Models = undefined;
        \\const selected = models.rea<>der;
    );
    try testDefinition(
        \\const Source = struct { <def><decl>count</decl></def>: u32 };
        \\fn Generated() type {
        \\    const name = @typeInfo(Source).@"struct".fields[0].name;
        \\    return @Struct(.auto, null, &.{name}, &.{u32}, &.{.{} });
        \\}
        \\const value: Generated() = undefined;
        \\const selected = value.co<>unt;
    );
    try testDefinition(
        \\const std = @import("std");
        \\const Source = struct { <def><decl>count</decl></def>: u32 };
        \\fn Generated() type {
        \\    return @Struct(.auto, null, std.meta.fieldNames(Source), &.{u32}, &.{.{} });
        \\}
        \\const value: Generated() = undefined;
        \\const selected = value.co<>unt;
    );
}

test "generic method definition keeps structural parameter type" {
    try testDefinition(
        \\fn Impl(comptime Subject: type) type {
        \\    return struct {
        \\        const Self = @This();
        \\        pub <tdef>fn</tdef> <def><decl>call</decl></def>(comptime _: Self) void { _ = Subject; }
        \\    };
        \\}
        \\fn generic(value: anytype, comptime impl: Impl(@TypeOf(value))) void {
        \\    impl.ca<>ll();
        \\}
        \\comptime {
        \\    generic(@as(u8, 0), .{});
        \\    generic(@as(u16, 0), .{});
        \\    generic(@as(u32, 0), .{});
        \\}
    );
}

test "hasDecl guard navigates members of an unresolved type" {
    try testDefinition(
        \\const Value = usize;
        \\const S = struct { const <def><decl>Value</decl></def> = u8; };
        \\fn inspect(comptime T: type) void {
        \\    const Base = switch (@typeInfo(T)) { .pointer => |pointer| pointer.child, else => T };
        \\    if (@hasDecl(Base, "Value")) _ = Base.Val<>ue;
        \\}
    );
}

test "reflection member name strings navigate to declarations" {
    try testDefinition(
        \\const S = struct { const <def><decl>Value</decl></def>: <tdef>u8</tdef> = 0; };
        \\const present = @hasDecl(S, "Val<>ue");
    );
    try testDefinition(
        \\const S = struct { <def><decl>value</decl></def>: <tdef>u32</tdef> };
        \\const value: S = undefined;
        \\const field = @field(value, "val<>ue");
    );
    try testDefinition(
        \\const S = struct { const <def><decl>ReaderError</decl></def> = error{Failure}; };
        \\fn inspect(comptime T: type) void {
        \\    if (@hasDecl(T, "Reader<>Error")) {}
        \\}
    );
    try testDefinition(
        \\const S = struct { const Value: u8 = 0; };
        \\const text = "Val<>ue";
    );
}

test "decl literal pointer" {
    try testDefinition(
        \\const S = <tdef>struct</tdef> {
        \\    const value: S = .{};
        \\    const <def><decl>ptr</decl></def>: *const S = &value;
        \\};
        \\test {
        \\    const ptr: *const S = .<>ptr;
        \\}
    );
    try testDefinition(
        \\const S = struct {
        \\    const value: S = .{};
        \\    <tdef>fn</tdef> <def><decl>pointerFn</decl></def>() *const S {
        \\        return &value;
        \\    }
        \\};
        \\test {
        \\    const ptr: *const S = .poi<>nterFn();
        \\}
    );
}

test "capture" {
    try testDefinition(
        \\test {
        \\    const S = <tdef>struct</tdef> {};
        \\    var maybe: ?S = 5;
        \\    if (maybe) |<def><decl><>some</decl></def>| {}
        \\}
    );
    try testDefinition(
        \\test {
        \\    var maybe: <tdef>?u32</tdef> = 5;
        \\    if (maybe) |<def><decl><>some</decl></def>| {}
        \\}
    );
    try testDefinition(
        \\const values = struct { maybe: <tdef>?u32</tdef> }{ .maybe = 5 };
        \\test {
        \\    if (values.maybe) |<def><decl><>some</decl></def>| {}
        \\}
    );
    try testDefinition(
        \\test {
        \\    var result: <tdef>anyerror!u32</tdef> = 5;
        \\    if (result) |<def><decl><>value</decl></def>| {}
        \\}
    );
}

test "label" {
    try testDefinition(
        \\comptime {
        \\    <def><decl>blk</decl></def>: {
        \\        break :<>blk {};
        \\    }
        \\}
    );
    try testDefinition(
        \\comptime {
        \\    <def><decl>sw</decl></def>: switch (0) {
        \\        else => break :<>sw,
        \\    }
        \\}
    );
}

test "different cursor position" {
    try testDefinition(
        \\const <def><decl>foo</decl></def> = 5;
        \\comptime {
        \\    _ = <>foo;
        \\}
    );
    try testDefinition(
        \\const <def><decl>foo</decl></def> = 5;
        \\comptime {
        \\    _ = f<>oo;
        \\}
    );
    try testDefinition(
        \\const <def><decl>foo</decl></def> = 5;
        \\comptime {
        \\    _ = foo<>;
        \\}
    );
    try testDefinition(
        \\const <def><decl>foo</decl></def> = 5;
        \\comptime {
        \\    _ =
        \\<>foo;
        \\}
    );
}

test "alias" {
    try testDefinition(
        \\const <def>Foo</def> = u32;
        \\const <decl>Bar</decl> = Foo;
        \\fn baz(_: <>Bar) void {
        \\}
    );
}

test "escaped identifier - label" {
    try testDefinition(
        \\comptime {
        \\    <def><decl>@"foo bar"</decl></def>: {
        \\        break :<origin><>@"foo bar"</origin> {};
        \\    }
        \\}
    );
}

test "escaped identifier - global" {
    try testDefinition(
        \\const <def><decl>@"foo bar"</decl></def> = 42;
        \\comptime {
        \\    _ = <origin><>@"foo bar"</origin>;
        \\}
    );
}

test "escaped identifier - enum literal" {
    try testDefinition(
        \\const E = <tdef>enum</tdef> { <def><decl>@"foo bar"</decl></def> };
        \\const e: E = .<origin><>@"foo bar"</origin>;
    );
}

test "escaped identifier - field access" {
    try testDefinition(
        \\const S = struct { <def><decl>@"foo bar"</decl></def>: <tdef>u32</tdef> };
        \\var s: S = undefined;
        \\const foo = s.<origin><>@"foo bar"</origin>;
    );
}

test "multiline builder pattern" {
    try testDefinition(
        \\const Foo = struct {
        \\    fn add(foo: Foo) Foo {}
        \\    fn remove(foo: Foo) Foo {}
        \\    fn process(foo: Foo) Foo {}
        \\    <tdef>fn</tdef> <def><decl>finalize</decl></def>(_: Foo) void {}
        \\};
        \\test {
        \\    var builder = Foo{};
        \\    builder
        \\        .add()
        \\        .remove()
        \\        .process()
        \\        // Comments should
        \\        // get ignored
        \\        .finalize<>();
        \\}
    );
}

test "block and decl with same name" {
    try testDefinition(
        \\const x = <def><decl>x</decl></def>: {
        \\    const x: u8 = 1;
        \\    break :<>x x;
        \\};
        \\_ = x;
    );
    try testDefinition(
        \\const x = x: {
        \\    const <def><decl>x</decl></def>: <tdef>u8</tdef> = 1;
        \\    break :x <>x;
        \\};
        \\_ = x;
    );
    try testDefinition(
        \\const <def><decl>x</decl></def> = x: {
        \\    const x: u8 = 1;
        \\    break :x x;
        \\};
        \\_ = <>x;
    );
}

test "non labeled break" {
    try testDefinition(
        \\test {
        \\    while (true) {
        \\        break {
        \\            const <def><decl>foo</decl></def> = 5;
        \\            return foo<>;
        \\        };
        \\    }
        \\}
    );
    try testDefinition(
        \\const <def><decl>num</decl></def>: <tdef>usize</tdef> = 5;
        \\return while (true) {
        \\    break num<>;
        \\};
    );
}

test "type definition unwraps error unions, optionals, pointers" {
    try testDefinition(
        \\const S = <tdef>struct</tdef> {};
        \\const <def><decl><>foo</decl></def>: error{}!S = .{};
    );
    try testDefinition(
        \\const S = <tdef>struct</tdef> {};
        \\const <def><decl><>foo</decl></def>: ?S = .{};
    );
    try testDefinition(
        \\const S = <tdef>struct</tdef> {};
        \\const <def><decl><>foo</decl></def>: *const S = &.{};
    );
    try testDefinition(
        \\const S = <tdef>struct</tdef> {};
        \\const <def><decl><>foo</decl></def>: error{}!?*const S = &.{};
    );
}

test "builtins" {
    try testDefinition(
        \\const S = struct {
        \\    const <tdef><def><decl>Self</decl></def></tdef> = <>@This();
        \\};
    );
    try testDefinition(
        \\const <decl>S</decl> = struct {
        \\    const <tdef><def>Self</def></tdef> = @This();
        \\};
        \\const foo: <>S = .{};
    );
    try testDefinition(
        \\const <tdef><def><decl>S</decl></def></tdef> = @This();
        \\const foo: <>S = .{};
    );
}

test "escaped identifier with same name as primitive" {
    try testDefinition(
        \\const @"null" = undefined;
        \\const foo = <>null;
        \\const bar = @"null";
    );
    try testDefinition(
        \\const @"i32" = undefined;
        \\const foo = <>i32;
        \\const bar = @"i32";
    );
    try testDefinition(
        \\const <def><decl>@"null"</decl></def> = undefined;
        \\const foo = null;
        \\const bar = <>@"null";
    );
    try testDefinition(
        \\const <def><decl>@"i32"</decl></def> = undefined;
        \\const foo = i32;
        \\const bar = <>@"i32";
    );
}

/// - use `<>` to indicate the cursor position
/// - use `<decl>content</decl>` to set the expected range of the declaration
/// - use `<def>content</def>` to set the expected range of the definition
/// - use `<tdef>content</tdef>` to set the expected range of the type definition
///
/// If a declaration is not set, it checks for no response from the Server.
/// Ditto for definition and type definition.
fn testDefinition(source: []const u8) !void {
    var phr = try helper.collectClearPlaceholders(allocator, source);
    defer phr.deinit(allocator);

    var ctx: Context = try .init();
    defer ctx.deinit();

    ctx.server.client_capabilities.supports_textDocument_definition_linkSupport = true;

    const test_uri = try ctx.addDocument(.{ .source = phr.new_source });

    var error_builder: ErrorBuilder = .init(allocator);
    defer error_builder.deinit();
    errdefer error_builder.writeDebug();

    try error_builder.addFile(test_uri.raw, phr.new_source);
    try error_builder.addFile("old_source", source);
    try error_builder.addFile("new_source", phr.new_source);

    const cursor_index: usize = blk: {
        var cursor_index: ?usize = null;
        var cursor_old_loc: ?offsets.Loc = null;
        for (phr.locations.items(.old), phr.locations.items(.new)) |old_loc, new_loc| {
            const str = offsets.locToSlice(source, old_loc);
            if (!std.mem.eql(u8, str, "<>")) continue;
            if (cursor_old_loc) |previous_loc| {
                try error_builder.msgAtLoc("duplicate cursor position", "old_source", old_loc, .err, .{});
                try error_builder.msgAtLoc("previously declared here", "old_source", previous_loc, .err, .{});
                return error.DuplicateCursorPosition;
            } else {
                std.debug.assert(new_loc.start == new_loc.end);
                cursor_index = new_loc.start;
                cursor_old_loc = old_loc;
            }
        }
        break :blk cursor_index orelse {
            std.debug.print("must specify cursor position with `<>`\n", .{});
            return error.ExpectedCursorPosition;
        };
    };

    for (phr.locations.items(.old)) |loc| {
        const str = offsets.locToSlice(source, loc); // e.g. '</decl>'
        const tag_content = str[1 .. str.len - 1]; // e.g. '/decl'
        const is_end = std.mem.startsWith(u8, tag_content, "/");
        const tag_name = tag_content[@intFromBool(is_end)..]; // e.g. 'decl'

        if (std.mem.eql(u8, tag_name, "")) continue; // cursor index
        if (std.mem.eql(u8, tag_name, "decl")) continue;
        if (std.mem.eql(u8, tag_name, "def")) continue;
        if (std.mem.eql(u8, tag_name, "tdef")) continue;
        if (std.mem.eql(u8, tag_name, "origin")) continue;
        std.debug.print("unknown placeholder '{s}'\n", .{str});
        return error.UnknownPlaceholder;
    }

    const declaration_loc: ?offsets.Loc = try parseTaggedLoc(source, phr, "decl");
    const definition_loc: ?offsets.Loc = try parseTaggedLoc(source, phr, "def");
    const type_definition_loc: ?offsets.Loc = try parseTaggedLoc(source, phr, "tdef");
    const origin_loc: ?offsets.Loc = try parseTaggedLoc(source, phr, "origin");

    const cursor_position = offsets.indexToPosition(phr.new_source, cursor_index, ctx.server.offset_encoding);

    const declaration_params: types.declaration.Params = .{ .textDocument = .{ .uri = test_uri.raw }, .position = cursor_position };
    const definition_params: types.Definition.Params = .{ .textDocument = .{ .uri = test_uri.raw }, .position = cursor_position };
    const type_definition_params: types.type_definition.Params = .{ .textDocument = .{ .uri = test_uri.raw }, .position = cursor_position };

    const maybe_declaration_response = try ctx.server.sendRequestSync(ctx.arena.allocator(), "textDocument/declaration", declaration_params);
    const maybe_definition_response = try ctx.server.sendRequestSync(ctx.arena.allocator(), "textDocument/definition", definition_params);
    const maybe_type_definition_response = try ctx.server.sendRequestSync(ctx.arena.allocator(), "textDocument/typeDefinition", type_definition_params);

    if (maybe_declaration_response) |response| {
        try std.testing.expect(response == .definition_links);
        try std.testing.expect(response.definition_links.len == 1);
        try std.testing.expectEqualStrings(test_uri.raw, response.definition_links[0].targetUri);
        const actual_loc = offsets.rangeToLoc(phr.new_source, response.definition_links[0].targetSelectionRange, ctx.server.offset_encoding);
        if (declaration_loc) |expected_loc| {
            if (!std.meta.eql(expected_loc, actual_loc)) {
                try error_builder.msgAtLoc("expected declaration here!", test_uri.raw, expected_loc, .err, .{});
                try error_builder.msgAtLoc("actual declaration here", test_uri.raw, actual_loc, .err, .{});
            }
        } else {
            try error_builder.msgAtLoc("unexpected declaration here", test_uri.raw, actual_loc, .err, .{});
        }
        const actual_origin_loc = offsets.rangeToLoc(phr.new_source, response.definition_links[0].originSelectionRange.?, ctx.server.offset_encoding);
        if (origin_loc) |expected_origin_loc| {
            if (!std.meta.eql(expected_origin_loc, actual_origin_loc)) {
                try error_builder.msgAtLoc("expected declaration origin here!", test_uri.raw, expected_origin_loc, .err, .{});
                try error_builder.msgAtLoc("actual declaration origin here", test_uri.raw, actual_origin_loc, .err, .{});
            }
        }
    } else if (declaration_loc) |expected_loc| {
        try error_builder.msgAtLoc("expected declaration here but got no result instead!", test_uri.raw, expected_loc, .err, .{});
    }

    if (maybe_definition_response) |response| {
        try std.testing.expect(response == .definition_links);
        try std.testing.expect(response.definition_links.len == 1);
        try std.testing.expectEqualStrings(test_uri.raw, response.definition_links[0].targetUri);
        const actual_loc = offsets.rangeToLoc(phr.new_source, response.definition_links[0].targetSelectionRange, ctx.server.offset_encoding);
        if (definition_loc) |expected_loc| {
            if (!std.meta.eql(expected_loc, actual_loc)) {
                try error_builder.msgAtLoc("expected definition here!", test_uri.raw, expected_loc, .err, .{});
                try error_builder.msgAtLoc("actual definition here", test_uri.raw, actual_loc, .err, .{});
            }
        } else {
            try error_builder.msgAtLoc("unexpected definition here", test_uri.raw, actual_loc, .err, .{});
        }
        const actual_origin_loc = offsets.rangeToLoc(phr.new_source, response.definition_links[0].originSelectionRange.?, ctx.server.offset_encoding);
        if (origin_loc) |expected_origin_loc| {
            if (!std.meta.eql(expected_origin_loc, actual_origin_loc)) {
                try error_builder.msgAtLoc("expected definition origin here!", test_uri.raw, expected_origin_loc, .err, .{});
                try error_builder.msgAtLoc("actual definition origin here", test_uri.raw, actual_origin_loc, .err, .{});
            }
        }
    } else if (definition_loc) |expected_loc| {
        try error_builder.msgAtLoc("expected definition here but got no result instead!", test_uri.raw, expected_loc, .err, .{});
    }

    if (maybe_type_definition_response) |response| {
        try std.testing.expect(response == .definition_links);
        try std.testing.expect(response.definition_links.len == 1);
        try std.testing.expectEqualStrings(test_uri.raw, response.definition_links[0].targetUri);
        const actual_loc = offsets.rangeToLoc(phr.new_source, response.definition_links[0].targetSelectionRange, ctx.server.offset_encoding);
        if (type_definition_loc) |expected_loc| {
            if (!std.meta.eql(expected_loc, actual_loc)) {
                try error_builder.msgAtLoc("expected type definition here!", test_uri.raw, expected_loc, .err, .{});
                try error_builder.msgAtLoc("actual type definition here", test_uri.raw, actual_loc, .err, .{});
            }
        } else {
            try error_builder.msgAtLoc("unexpected type definition here", test_uri.raw, actual_loc, .err, .{});
        }
        const actual_origin_loc = offsets.rangeToLoc(phr.new_source, response.definition_links[0].originSelectionRange.?, ctx.server.offset_encoding);
        if (origin_loc) |expected_origin_loc| {
            if (!std.meta.eql(expected_origin_loc, actual_origin_loc)) {
                try error_builder.msgAtLoc("expected type definition origin here!", test_uri.raw, expected_origin_loc, .err, .{});
                try error_builder.msgAtLoc("actual type definition origin here", test_uri.raw, actual_origin_loc, .err, .{});
            }
        }
    } else if (type_definition_loc) |expected_loc| {
        try error_builder.msgAtLoc("expected type definition here but got no result instead!", test_uri.raw, expected_loc, .err, .{});
    }

    if (error_builder.hasMessages()) {
        try error_builder.msgAtIndex("cursor position here", test_uri.raw, cursor_index, .info, .{});
        return error.InvalidResponse;
    }
}

/// finds the source location that is enclosed by `<tag_name>return_value</tag_name>`
fn parseTaggedLoc(old_source: []const u8, phr: helper.CollectPlaceholdersResult, tag_name: []const u8) !?offsets.Loc {
    var old_start_loc: ?offsets.Loc = null;
    var old_end_loc: ?offsets.Loc = null;
    var start: ?usize = null;
    var end: ?usize = null;

    for (phr.locations.items(.old), phr.locations.items(.new)) |old_loc, new_loc| {
        const str = offsets.locToSlice(old_source, old_loc); // e.g. '</decl>'
        const tag_content = str[1 .. str.len - 1]; // e.g. '/decl'
        const is_end = std.mem.startsWith(u8, tag_content, "/");
        const tag = tag_content[@intFromBool(is_end)..]; // e.g. 'decl'
        if (!std.mem.eql(u8, tag_name, tag)) continue;
        if (is_end) {
            end = new_loc.start;
            old_end_loc = old_loc;
        } else {
            start = new_loc.end;
            old_start_loc = old_loc;
        }
    }

    if (start == null and end == null) {
        return null;
    } else if (start != null and end == null) {
        std.debug.print("'{s}' is missing closing tag", .{offsets.locToSlice(old_source, old_start_loc.?)});
        return error.MissingClosingTag;
    } else if (start == null and end != null) {
        std.debug.print("unexpected closing tag '{s}'", .{offsets.locToSlice(old_source, old_end_loc.?)});
        return error.UnexpectedClosingTag;
    }

    if (start.? > end.?) {
        std.debug.print("opening tag of '{s}' is after the closing tag", .{offsets.locToSlice(old_source, old_start_loc.?)});
        return error.MismatchedTags;
    }

    return .{ .start = start.?, .end = end.? };
}
