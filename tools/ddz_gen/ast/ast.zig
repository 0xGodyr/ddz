//! @file ast.zig
//! @brief Abstract Syntax Tree (AST) definitions for IDL and ROS2 message specifications.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");

pub const PrimitiveKind = enum {
    boolean,
    octet,
    char,
    wchar,
    short,
    unsigned_short,
    long,
    unsigned_long,
    long_long,
    unsigned_long_long,
    float,
    double,
    long_double,
    string,
    wstring,
    fixed,
    void,
    int8,
    uint8,
    int16,
    uint16,
    int32,
    uint32,
    int64,
    uint64,
};

pub const ScopedName = struct {
    segments: []const []const u8,

    pub fn format(self: ScopedName, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        for (self.segments, 0..) |seg, i| {
            if (i > 0) try writer.writeAll("::");
            try writer.writeAll(seg);
        }
    }

    pub fn last(self: ScopedName) []const u8 {
        if (self.segments.len == 0) return "";
        return self.segments[self.segments.len - 1];
    }
};

pub const TypeRef = union(enum) {
    primitive: PrimitiveKind,
    scoped_name: ScopedName,
    sequence: *SequenceType,
    array: *ArrayType,
    string_bounded: u32,
    wstring_bounded: u32,
};

pub const SequenceType = struct {
    element_type: TypeRef,
    bound: ?u32 = null,
};

pub const ArrayType = struct {
    element_type: TypeRef,
    dimensions: []const u32,
};

pub const Annotation = struct {
    name: []const u8, // e.g. "key", "id", "optional", "default", "extensibility"
    value: ?[]const u8 = null, // e.g. "10", "MUTABLE"
};

pub const Field = struct {
    name: []const u8,
    type_ref: TypeRef,
    annotations: []const Annotation = &.{},
    doc_comment: ?[]const u8 = null,
    default_value: ?[]const u8 = null,

    pub fn isKey(self: Field) bool {
        for (self.annotations) |ann| {
            if (std.mem.eql(u8, ann.name, "key")) return true;
        }
        return false;
    }

    pub fn isOptional(self: Field) bool {
        for (self.annotations) |ann| {
            if (std.mem.eql(u8, ann.name, "optional")) return true;
        }
        return false;
    }

    pub fn getId(self: Field) ?[]const u8 {
        for (self.annotations) |ann| {
            if (std.mem.eql(u8, ann.name, "id")) return ann.value;
        }
        return null;
    }
};

pub const StructDef = struct {
    name: []const u8,
    base_type: ?ScopedName = null,
    fields: []const Field,
    annotations: []const Annotation = &.{},
    doc_comment: ?[]const u8 = null,

    pub fn hasKeys(self: StructDef) bool {
        for (self.fields) |f| {
            if (f.isKey()) return true;
        }
        return false;
    }
};

pub const EnumMember = struct {
    name: []const u8,
    value: ?i64 = null,
    doc_comment: ?[]const u8 = null,
};

pub const EnumDef = struct {
    name: []const u8,
    members: []const EnumMember,
    annotations: []const Annotation = &.{},
    doc_comment: ?[]const u8 = null,
};

pub const UnionCaseLabel = union(enum) {
    value: i64,
    default_case: void,
};

pub const UnionCase = struct {
    labels: []const UnionCaseLabel,
    field: Field,
};

pub const UnionDef = struct {
    name: []const u8,
    discriminant_type: TypeRef,
    cases: []const UnionCase,
    annotations: []const Annotation = &.{},
    doc_comment: ?[]const u8 = null,
};

pub const BitmaskDef = struct {
    name: []const u8,
    bit_bound: u16 = 32,
    flags: []const []const u8,
    annotations: []const Annotation = &.{},
    doc_comment: ?[]const u8 = null,
};

pub const BitsetField = struct {
    name: []const u8,
    bit_size: u16,
};

pub const BitsetDef = struct {
    name: []const u8,
    fields: []const BitsetField,
    annotations: []const Annotation = &.{},
    doc_comment: ?[]const u8 = null,
};

pub const TypedefDef = struct {
    name: []const u8,
    target_type: TypeRef,
    doc_comment: ?[]const u8 = null,
};

pub const ConstDef = struct {
    name: []const u8,
    const_type: TypeRef,
    value_repr: []const u8,
    int_val: ?i64 = null,
    float_val: ?f64 = null,
    doc_comment: ?[]const u8 = null,
};

pub const ParameterDirection = enum {
    in,
    out,
    inout,
};

pub const Parameter = struct {
    direction: ParameterDirection,
    param_type: TypeRef,
    name: []const u8,
};

pub const Operation = struct {
    name: []const u8,
    return_type: TypeRef,
    params: []const Parameter,
    is_oneway: bool = false,
    doc_comment: ?[]const u8 = null,
};

pub const InterfaceDef = struct {
    name: []const u8,
    base_interface: ?ScopedName = null,
    operations: []const Operation,
    annotations: []const Annotation = &.{},
    doc_comment: ?[]const u8 = null,
};

pub const Declaration = union(enum) {
    module: *ModuleDef,
    struct_def: StructDef,
    enum_def: EnumDef,
    union_def: UnionDef,
    bitmask_def: BitmaskDef,
    bitset_def: BitsetDef,
    typedef_def: TypedefDef,
    const_def: ConstDef,
    interface_def: InterfaceDef,
};

pub const ModuleDef = struct {
    name: []const u8,
    declarations: []const Declaration,
    doc_comment: ?[]const u8 = null,
};

pub const AstRoot = struct {
    declarations: []const Declaration,
};
