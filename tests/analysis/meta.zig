const std = @import("std");

const EnumA = enum {
    foo,
    bar,
};

const TaggedUnionA = union(EnumA) {
    foo: u8,
    bar: i32,
};

const TaggedUnionB = union(enum) {
    fizz: u16,
    buzz: i64,
};

const TagA = std.meta.Tag(TaggedUnionA);
//    ^^^^ (type)(EnumA)

const TagB = std.meta.Tag(TaggedUnionB);
//    ^^^^ (type)(@typeInfo(TaggedUnionB).@"union".tag_type.?)

const ExplicitEnum = enum(u8) {
    foo,
    bar,
};

const TagEnum = std.meta.Tag(ExplicitEnum);
//    ^^^^^^^ (type)(u8)

const EmptyEnum = enum {};
const TagEmptyEnum = std.meta.Tag(EmptyEnum);
//    ^^^^^^^^^^^^ (type)(u0)

const GeneratedEnum = @Enum(u13, .exhaustive, &.{"value"}, &.{1});
const TagGeneratedEnum = std.meta.Tag(GeneratedEnum);
//    ^^^^^^^^^^^^^^^^ (type)(u13)

const TagBBacking = std.meta.Tag(TagB);
//    ^^^^^^^^^^^ (type)(u1)

const ArgsTupleA = std.meta.ArgsTuple(fn (u8, i32) void);
//    ^^^^^^^^^^ (type)(struct { u8, i32 })

fn function(_: u16, _: i64) void {}

const ArgsTupleB = std.meta.ArgsTuple(@TypeOf(function));
//    ^^^^^^^^^^ (type)(struct { u16, i64 })

const GeneratedFunction = @Fn(&.{ u8, i32 }, &.{ .{}, .{} }, void, .{});
const ArgsTupleGenerated = std.meta.ArgsTuple(GeneratedFunction);
//    ^^^^^^^^^^^^^^^^^^ (type)(struct { u8, i32 })

const MetaNominal = struct { value: u8 };
const ChildNominalVector = std.meta.Child(@Vector(4, *MetaNominal));
//    ^^^^^^^^^^^^^^^^^^ (type)(*MetaNominal)
const ElemNominalVector = std.meta.Elem(*@Vector(4, *MetaNominal));
//    ^^^^^^^^^^^^^^^^^ (type)(*MetaNominal)
const MetaPacked = @Struct(.@"packed", null, &.{"value"}, &.{u8}, &.{.{}});
const LayoutPacked = std.meta.containerLayout(MetaPacked);
const layout_packed_name = @tagName(LayoutPacked)[0];
//    ^^^^^^^^^^^^^^^^^^ (u8)(112)
const MetaExtern = extern struct { value: u8 };
const layout_extern_name = @tagName(std.meta.containerLayout(MetaExtern))[0];
//    ^^^^^^^^^^^^^^^^^^ (u8)(101)
const MetaUnion = @Union(.auto, null, &.{"value"}, &.{u8}, &.{.{}});
const layout_union_name = @tagName(std.meta.containerLayout(MetaUnion))[0];
//    ^^^^^^^^^^^^^^^^^ (u8)(97)
const explicit_pointer_alignment = std.meta.alignment(*align(32) MetaNominal);
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^ (comptime_int)(32)
const optional_pointer_alignment = std.meta.alignment(?*align(32) MetaNominal);
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^ (comptime_int)(32)
const implicit_pointer_alignment = std.meta.alignment(*u16);
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^ (comptime_int)(2)

const FieldStruct = struct { alpha: u8, beta: u16 };
const StructFieldEnum = std.meta.FieldEnum(FieldStruct);
//    ^^^^^^^^^^^^^^^ (type)(enum(u1) { alpha = 0, beta = 1 })
const FieldUnion = union { alpha: u8, beta: u16 };
const UnionFieldEnum = std.meta.FieldEnum(FieldUnion);
//    ^^^^^^^^^^^^^^ (type)(enum(u1) { alpha = 0, beta = 1 })
const structurally_same_field_enums = StructFieldEnum == UnionFieldEnum;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)(true)
const ConsecutiveTag = enum { alpha, beta };
const ConsecutiveUnion = union(ConsecutiveTag) { alpha: u8, beta: u16 };
const ReusedFieldEnum = std.meta.FieldEnum(ConsecutiveUnion);
//    ^^^^^^^^^^^^^^^ (type)(ConsecutiveTag)

const first_field_index = std.meta.fieldIndex(FieldStruct, "alpha").?;
//    ^^^^^^^^^^^^^^^^^ (comptime_int)(0)
const second_field_index = std.meta.fieldIndex(FieldUnion, "beta").?;
//    ^^^^^^^^^^^^^^^^^^ (comptime_int)(1)
const missing_field_index = std.meta.fieldIndex(FieldStruct, "missing") == null;
//    ^^^^^^^^^^^^^^^^^^^ (bool)(true)

const StructFields = std.meta.fields(FieldStruct);
const struct_fields_len = StructFields.len;
//    ^^^^^^^^^^^^^^^^^ (usize)(2)
const struct_field_type = StructFields[1].type;
//    ^^^^^^^^^^^^^^^^^ (type)(u16)
const UnionFields = std.meta.fields(FieldUnion);
const union_field_type = UnionFields[0].type;
//    ^^^^^^^^^^^^^^^^ (type)(u8)
const EnumFields = std.meta.fields(ConsecutiveTag);
const enum_field_value = EnumFields[1].value;
//    ^^^^^^^^^^^^^^^^ (comptime_int)(1)
const ErrorFields = std.meta.fields(error{ Alpha, Beta });
const error_field_name_first = ErrorFields[0].name[0];
//    ^^^^^^^^^^^^^^^^^^^^^^ (u8)(65)

const DeclStruct = struct {
    pub const Alpha = 1;
    const hidden = 2;
    pub fn beta() void {}
};
const StructDecls = std.meta.declarations(DeclStruct);
const struct_decls_len = StructDecls.len;
//    ^^^^^^^^^^^^^^^^ (usize)(2)
const struct_decl_first_name = StructDecls[0].name[0];
//    ^^^^^^^^^^^^^^^^^^^^^^ (u8)(65)
const struct_decl_second_name = StructDecls[1].name[0];
//    ^^^^^^^^^^^^^^^^^^^^^^^ (u8)(98)
const GeneratedDecls = std.meta.declarations(MetaPacked);
const generated_decls_len = GeneratedDecls.len;
//    ^^^^^^^^^^^^^^^^^^^ (usize)(0)

const DeclNames = std.meta.DeclEnum(DeclStruct);
const decl_alpha_value = @intFromEnum(DeclNames.Alpha);
//    ^^^^^^^^^^^^^^^^ (u1)(0)
const decl_beta_name = @tagName(DeclNames.beta)[0];
//    ^^^^^^^^^^^^^^ (u8)(98)
const same_decl_names = std.meta.DeclEnum(DeclStruct) == std.meta.DeclEnum(DeclStruct);
//    ^^^^^^^^^^^^^^^ (bool)(true)
const SameDeclStruct = struct {
    pub const Alpha = 2;
    pub fn beta() void {}
};
const structurally_same_decl_names = std.meta.DeclEnum(DeclStruct) == std.meta.DeclEnum(SameDeclStruct);
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)(true)
const CrossHelperNames = struct { Alpha: u8, beta: u8 };
const cross_helper_enum_distinct = std.meta.DeclEnum(DeclStruct) != std.meta.FieldEnum(CrossHelperNames);
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)(true)
const EmptyDeclNames = std.meta.DeclEnum(MetaPacked);
const empty_decl_tag = std.meta.Tag(EmptyDeclNames);
//    ^^^^^^^^^^^^^^ (type)(u0)

const DeclUnion = union {
    payload: u8,
    pub const Gamma = 1;
};
const union_decl_value = @intFromEnum(std.meta.DeclEnum(DeclUnion).Gamma);
//    ^^^^^^^^^^^^^^^^ (u0)(0)
const DeclTag = enum {
    payload,
    pub const delta = 1;
};
const enum_decl_name = @tagName(std.meta.DeclEnum(DeclTag).delta)[0];
//    ^^^^^^^^^^^^^^ (u8)(100)
const DeclOpaque = opaque {
    pub const Omega = 1;
};
const opaque_decl_value = @intFromEnum(std.meta.DeclEnum(DeclOpaque).Omega);
//    ^^^^^^^^^^^^^^^^^ (u0)(0)
const AnyopaqueDeclNames = std.meta.DeclEnum(anyopaque);
const anyopaque_decl_tag = std.meta.Tag(AnyopaqueDeclNames);
//    ^^^^^^^^^^^^^^^^^^ (type)(u0)
const DeclTaggedUnion = union(enum) { payload: u8 };
const ImplicitTagDeclNames = std.meta.DeclEnum(std.meta.Tag(DeclTaggedUnion));
const implicit_tag_decl_tag = std.meta.Tag(ImplicitTagDeclNames);
//    ^^^^^^^^^^^^^^^^^^^^^ (type)(u0)

const AlphaDecl = std.meta.declarationInfo(DeclStruct, "Alpha");
const alpha_decl_name = AlphaDecl.name[0];
//    ^^^^^^^^^^^^^^^ (u8)(65)
const BetaDecl = std.meta.declarationInfo(DeclStruct, "beta");
const beta_decl_name = BetaDecl.name[0];
//    ^^^^^^^^^^^^^^ (u8)(98)
const UnionDeclInfo = std.meta.declarationInfo(DeclUnion, "Gamma");
const union_decl_name = UnionDeclInfo.name[0];
//    ^^^^^^^^^^^^^^^ (u8)(71)
const EnumDeclInfo = std.meta.declarationInfo(DeclTag, "delta");
const enum_decl_info_name = EnumDeclInfo.name[0];
//    ^^^^^^^^^^^^^^^^^^^ (u8)(100)
const OpaqueDeclInfo = std.meta.declarationInfo(DeclOpaque, "Omega");
const opaque_decl_name = OpaqueDeclInfo.name[0];
//    ^^^^^^^^^^^^^^^^ (u8)(79)
const EscapedDecl = struct {
    pub const @"quoted-name" = 1;
};
const EscapedDeclInfo = std.meta.declarationInfo(EscapedDecl, "quoted-name");
const escaped_decl_name = EscapedDeclInfo.name[0];
//    ^^^^^^^^^^^^^^^^^ (u8)(113)

const FieldInfoStruct = struct {
    payload: u16,
    comptime enabled: bool = true,
};
const PayloadFieldInfo = std.meta.fieldInfo(FieldInfoStruct, .payload);
const payload_field_info_type = PayloadFieldInfo.type;
//    ^^^^^^^^^^^^^^^^^^^^^^^ (type)(u16)
const EnabledFieldInfo = std.meta.fieldInfo(FieldInfoStruct, .enabled);
const enabled_field_is_comptime = EnabledFieldInfo.is_comptime;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)(true)
const UnionFieldInfo = std.meta.fieldInfo(FieldUnion, .beta);
const union_field_info_type = UnionFieldInfo.type;
//    ^^^^^^^^^^^^^^^^^^^^^ (type)(u16)
const EnumFieldInfo = std.meta.fieldInfo(ConsecutiveTag, .beta);
const enum_field_info_value = EnumFieldInfo.value;
//    ^^^^^^^^^^^^^^^^^^^^^ (comptime_int)(1)
const ErrorFieldInfo = std.meta.fieldInfo(error{ Alpha, Beta }, .Beta);
const error_field_info_name = ErrorFieldInfo.name[0];
//    ^^^^^^^^^^^^^^^^^^^^^ (u8)(66)
const StructFieldNames = std.meta.FieldEnum(FieldInfoStruct);
const QualifiedFieldInfo = std.meta.fieldInfo(FieldInfoStruct, StructFieldNames.enabled);
const qualified_field_is_comptime = QualifiedFieldInfo.is_comptime;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^ (bool)(true)
const IntegerFieldInfo = std.meta.fieldInfo(FieldInfoStruct, @enumFromInt(0));
const integer_field_info_type = IntegerFieldInfo.type;
//    ^^^^^^^^^^^^^^^^^^^^^^^ (type)(u16)
const GeneratedFieldInfo = std.meta.fieldInfo(MetaPacked, .value);
const generated_field_info_type = GeneratedFieldInfo.type;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^ (type)(u8)

const StructFieldNamesList = std.meta.fieldNames(FieldInfoStruct);
const struct_field_names_len = StructFieldNamesList.len;
//    ^^^^^^^^^^^^^^^^^^^^^^ (usize)(2)
const struct_field_name_first = StructFieldNamesList[0][0];
//    ^^^^^^^^^^^^^^^^^^^^^^^ (u8)(112)
const struct_field_name_second_len = StructFieldNamesList[1].len;
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^ (usize)(7)
const union_field_name_second = std.meta.fieldNames(FieldUnion)[1][0];
//    ^^^^^^^^^^^^^^^^^^^^^^^ (u8)(98)
const enum_field_name_second = std.meta.fieldNames(ConsecutiveTag)[1][0];
//    ^^^^^^^^^^^^^^^^^^^^^^ (u8)(98)
const error_field_name_second = std.meta.fieldNames(error{ Alpha, Beta })[1][0];
//    ^^^^^^^^^^^^^^^^^^^^^^^ (u8)(66)
const generated_field_name_first = std.meta.fieldNames(MetaPacked)[0][0];
//    ^^^^^^^^^^^^^^^^^^^^^^^^^^ (u8)(118)
const tuple_field_name_first = std.meta.fieldNames(struct { u8, u16 })[0][0];
//    ^^^^^^^^^^^^^^^^^^^^^^ (u8)(48)
const EscapedFieldStruct = struct { @"quoted-field": u8 };
const escaped_field_name_len = std.meta.fieldNames(EscapedFieldStruct)[0].len;
//    ^^^^^^^^^^^^^^^^^^^^^^ (usize)(12)
