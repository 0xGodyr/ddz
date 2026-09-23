//! @file xtypes.zig
//! @brief Implements the OMG Extensible and Dynamic Topic Types (XTypes) dynamic data definitions.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const Serializer = @import("../cdr/serializer.zig").Serializer;
const Deserializer = @import("../cdr/deserializer.zig").Deserializer;

/// @brief Type kind structure.
pub const TypeKind = enum(u8) {
    Struct,
    Int32,
    UInt32,
    Float32,
    Float64,
    String,
    Array,
    Bool,
    Void,
    Union,
    Map,
    Bitset,
    Optional,
    Int8,
    UInt8,
    Int16,
    UInt16,
    Int64,
    UInt64,
};

/// @brief Extensibility kind.
pub const ExtensibilityKind = enum(u8) {
    FINAL,
    APPENDABLE,
    MUTABLE,
};

/// @brief Field def structure.
pub const FieldDef = struct {
    name: []const u8,
    kind: TypeKind,
    array_len: u32 = 0,
};

/// @brief Type object structure.
pub const TypeObject = struct {
    name: []const u8,
    extensibility: ExtensibilityKind = .FINAL,
    fields: std.ArrayListUnmanaged(FieldDef),
    is_owned: bool = false,

    /// @brief Deinitializes the instance.
    pub fn deinit(self: *TypeObject, allocator: std.mem.Allocator) void {
        if (self.is_owned) {
            allocator.free(self.name);
            for (self.fields.items) |field| {
                allocator.free(field.name);
            }
        }
        self.fields.deinit(allocator);
    }

    /// @brief Checks if schema evolution allows assignment.
    pub fn isAssignable(requested: TypeObject, offered: TypeObject) bool {
        // If names don't match, they aren't assignable unless they are aliased
        if (!std.mem.eql(u8, requested.name, offered.name)) {
            return false;
        }

        if (requested.extensibility == .MUTABLE or offered.extensibility == .MUTABLE) {
            for (requested.fields.items) |r_field| {
                for (offered.fields.items) |o_field| {
                    if (std.mem.eql(u8, r_field.name, o_field.name)) {
                        if (r_field.kind != o_field.kind) {
                            return false;
                        }
                        if (r_field.array_len != o_field.array_len) {
                            return false;
                        }
                        break;
                    }
                }
            }
            return true;
        }

        if (requested.extensibility == .APPENDABLE or offered.extensibility == .APPENDABLE) {
            const min_len = @min(requested.fields.items.len, offered.fields.items.len);
            var i: usize = 0;
            while (i < min_len) : (i += 1) {
                const r_field = requested.fields.items[i];
                const o_field = offered.fields.items[i];
                if (!std.mem.eql(u8, r_field.name, o_field.name)) {
                    return false;
                }
                if (r_field.kind != o_field.kind) {
                    return false;
                }
                if (r_field.array_len != o_field.array_len) {
                    return false;
                }
            }
            if (requested.fields.items.len > offered.fields.items.len) {
                return false;
            }
            return true;
        }

        if (requested.fields.items.len != offered.fields.items.len) {
            return false;
        }
        var i: usize = 0;
        while (i < requested.fields.items.len) : (i += 1) {
            const r_field = requested.fields.items[i];
            const o_field = offered.fields.items[i];
            if (!std.mem.eql(u8, r_field.name, o_field.name)) {
                return false;
            }
            if (r_field.kind != o_field.kind) {
                return false;
            }
            if (r_field.array_len != o_field.array_len) {
                return false;
            }
        }
        return true;
    }
};

/// @brief Dynamic value structure.
pub const DynamicValue = union(TypeKind) {
    Struct: std.StringHashMap(DynamicValue),
    Int32: i32,
    UInt32: u32,
    Float32: f32,
    Float64: f64,
    String: []const u8,
    Array: std.ArrayListUnmanaged(DynamicValue),
    Bool: bool,
    Void: void,
    Union: struct { discriminator: i32, value: *DynamicValue },
    Map: std.StringHashMap(DynamicValue),
    Bitset: std.bit_set.DynamicBitSetUnmanaged,
    Optional: ?*DynamicValue,
    Int8: i8,
    UInt8: u8,
    Int16: i16,
    UInt16: u16,
    Int64: i64,
    UInt64: u64,

    /// @brief Deinitializes the instance.
    pub fn clone(self: *const DynamicValue, allocator: std.mem.Allocator) !DynamicValue {
        switch (self.*) {
            .Struct => |*map| {
                var new_map = std.StringHashMap(DynamicValue).init(allocator);
                errdefer {
                    var it_clean = new_map.valueIterator();
                    while (it_clean.next()) |val| val.deinit(allocator);
                    new_map.deinit();
                }
                var it = map.iterator();
                while (it.next()) |entry| {
                    const v = try entry.value_ptr.clone(allocator);
                    try new_map.put(entry.key_ptr.*, v);
                }
                return DynamicValue{ .Struct = new_map };
            },
            .Array => |*arr| {
                var new_arr = std.ArrayListUnmanaged(DynamicValue).empty;
                errdefer {
                    for (new_arr.items) |*item| item.deinit(allocator);
                    new_arr.deinit(allocator);
                }
                for (arr.items) |*item| {
                    try new_arr.append(allocator, try item.clone(allocator));
                }
                return DynamicValue{ .Array = new_arr };
            },
            .String => |str| {
                const new_str = try allocator.dupe(u8, str);
                return DynamicValue{ .String = new_str };
            },
            .Int8 => |v| return DynamicValue{ .Int8 = v },
            .UInt8 => |v| return DynamicValue{ .UInt8 = v },
            .Int16 => |v| return DynamicValue{ .Int16 = v },
            .UInt16 => |v| return DynamicValue{ .UInt16 = v },
            .Int32 => |v| return DynamicValue{ .Int32 = v },
            .UInt32 => |v| return DynamicValue{ .UInt32 = v },
            .Int64 => |v| return DynamicValue{ .Int64 = v },
            .UInt64 => |v| return DynamicValue{ .UInt64 = v },
            .Float32 => |v| return DynamicValue{ .Float32 = v },
            .Float64 => |v| return DynamicValue{ .Float64 = v },
            .Bool => |v| return DynamicValue{ .Bool = v },
            .Void => return DynamicValue{ .Void = {} },
            .Union => |u| {
                const new_val = try allocator.create(DynamicValue);
                errdefer allocator.destroy(new_val);
                new_val.* = try u.value.clone(allocator);
                return DynamicValue{ .Union = .{ .discriminator = u.discriminator, .value = new_val } };
            },
            .Map => |*map| {
                var new_map = std.StringHashMap(DynamicValue).init(allocator);
                errdefer {
                    var it_clean = new_map.iterator();
                    while (it_clean.next()) |entry| {
                        allocator.free(entry.key_ptr.*);
                        entry.value_ptr.deinit(allocator);
                    }
                    new_map.deinit();
                }
                var it = map.iterator();
                while (it.next()) |entry| {
                    const k = try allocator.dupe(u8, entry.key_ptr.*);
                    errdefer allocator.free(k);
                    const v = try entry.value_ptr.clone(allocator);
                    try new_map.put(k, v);
                }
                return DynamicValue{ .Map = new_map };
            },
            .Bitset => |*bs| {
                const new_bs = try bs.clone(allocator);
                return DynamicValue{ .Bitset = new_bs };
            },
            .Optional => |opt| {
                if (opt) |v| {
                    const new_val = try allocator.create(DynamicValue);
                    errdefer allocator.destroy(new_val);
                    new_val.* = try v.clone(allocator);
                    return DynamicValue{ .Optional = new_val };
                }
                return DynamicValue{ .Optional = null };
            },
        }
    }

    /// @brief Creates an empty Map DynamicValue.
    pub fn createMap(allocator: std.mem.Allocator) DynamicValue {
        return DynamicValue{ .Map = std.StringHashMap(DynamicValue).init(allocator) };
    }

    /// @brief Puts a key-value pair into a Map DynamicValue, taking ownership via duplication.
    pub fn putMap(self: *DynamicValue, allocator: std.mem.Allocator, key: []const u8, val: DynamicValue) !void {
        if (self.* != .Map) return error.TypeMismatch;
        const k = try allocator.dupe(u8, key);
        errdefer allocator.free(k);
        try self.Map.put(k, val);
    }

    /// @brief Creates an Optional DynamicValue.
    pub fn createOptional(allocator: std.mem.Allocator, val_opt: ?DynamicValue) !DynamicValue {
        if (val_opt) |v| {
            const ptr = try allocator.create(DynamicValue);
            ptr.* = v;
            return DynamicValue{ .Optional = ptr };
        }
        return DynamicValue{ .Optional = null };
    }

    /// @brief Creates a Union DynamicValue.
    pub fn createUnion(allocator: std.mem.Allocator, disc: i32, val: DynamicValue) !DynamicValue {
        const ptr = try allocator.create(DynamicValue);
        ptr.* = val;
        return DynamicValue{ .Union = .{ .discriminator = disc, .value = ptr } };
    }

    pub fn deinit(self: *DynamicValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .Struct => |*map| {
                var it = map.valueIterator();
                while (it.next()) |val| {
                    val.deinit(allocator);
                }
                map.deinit();
            },
            .Array => |*arr| {
                for (arr.items) |*val| {
                    val.deinit(allocator);
                }
                arr.deinit(allocator);
            },
            .String => |str| {
                allocator.free(str);
            },
            .Union => |u| {
                u.value.deinit(allocator);
                allocator.destroy(u.value);
            },
            .Map => |*map| {
                var it = map.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                map.deinit();
            },
            .Bitset => |*bs| {
                bs.deinit(allocator);
            },
            .Optional => |opt| {
                if (opt) |v| {
                    v.deinit(allocator);
                    allocator.destroy(v);
                }
            },
            else => {},
        }
    }
};

/// @brief Generate type object.
pub fn generateTypeObject(allocator: std.mem.Allocator, comptime T: type) !TypeObject {
    var ext: ExtensibilityKind = .FINAL;
    if (@hasDecl(T, "ddz_extensibility")) {
        if (std.mem.eql(u8, T.ddz_extensibility, "MUTABLE")) {
            ext = .MUTABLE;
        } else if (std.mem.eql(u8, T.ddz_extensibility, "APPENDABLE")) {
            ext = .APPENDABLE;
        }
    }
    var type_obj = TypeObject{
        .name = @typeName(T),
        .extensibility = ext,
        .fields = .empty,
    };

    const type_info = @typeInfo(T);
    if (type_info != .@"struct") return error.NotAStruct;

    inline for (type_info.@"struct".field_names, type_info.@"struct".field_types) |field_name, FieldType| {
        var kind: TypeKind = .Void;
        var array_len: u32 = 0;

        const field_info = @typeInfo(FieldType);

        switch (field_info) {
            .int => |int_info| {
                if (int_info.signedness == .signed and int_info.bits == 32) kind = .Int32 else if (int_info.signedness == .unsigned and int_info.bits == 32) kind = .UInt32 else if (int_info.signedness == .signed and int_info.bits == 64) kind = .Int64 else if (int_info.signedness == .unsigned and int_info.bits == 64) kind = .UInt64 else if (int_info.signedness == .signed and int_info.bits == 16) kind = .Int16 else if (int_info.signedness == .unsigned and int_info.bits == 16) kind = .UInt16 else if (int_info.signedness == .signed and int_info.bits == 8) kind = .Int8 else if (int_info.signedness == .unsigned and int_info.bits == 8) kind = .UInt8 else return error.UnsupportedIntType;
            },
            .float => |float_info| {
                if (float_info.bits == 32) kind = .Float32 else if (float_info.bits == 64) kind = .Float64 else return error.UnsupportedFloatType;
            },
            .bool => kind = .Bool,
            .array => |array_info| {
                if (array_info.child == u8) {
                    kind = .String; // Treat u8 arrays as strings for MVP
                    array_len = array_info.len;
                } else {
                    kind = .Array;
                    array_len = array_info.len;
                }
            },
            .@"enum" => {
                kind = .UInt32;
            },
            else => return error.UnsupportedFieldType,
        }

        try type_obj.fields.append(allocator, .{
            .name = field_name,
            .kind = kind,
            .array_len = array_len,
        });
    }

    return type_obj;
}

fn serializeDynamicValue(ser: *Serializer, v: DynamicValue) !void {
    try ser.serialize(@as(u8, @backingInt(@as(TypeKind, v))));
    switch (v) {
        .Int8 => try ser.serialize(v.Int8),
        .UInt8 => try ser.serialize(v.UInt8),
        .Int16 => try ser.serialize(v.Int16),
        .UInt16 => try ser.serialize(v.UInt16),
        .Int32 => try ser.serialize(v.Int32),
        .UInt32 => try ser.serialize(v.UInt32),
        .Int64 => try ser.serialize(v.Int64),
        .UInt64 => try ser.serialize(v.UInt64),
        .Float32 => try ser.serialize(v.Float32),
        .Float64 => try ser.serialize(v.Float64),
        .Bool => try ser.serialize(v.Bool),
        .String => try ser.serialize(v.String),
        .Void => {},
        .Optional => {
            if (v.Optional) |inner| {
                try ser.serialize(@as(u8, 1));
                try serializeDynamicValue(ser, inner.*);
            } else {
                try ser.serialize(@as(u8, 0));
            }
        },
        .Union => {
            try ser.serialize(v.Union.discriminator);
            try serializeDynamicValue(ser, v.Union.value.*);
        },
        .Bitset => {
            const num_bits = @as(u32, @intCast(v.Bitset.bit_length));
            try ser.serialize(num_bits);
            const num_bytes = (num_bits + 7) / 8;
            var byte_idx: usize = 0;
            while (byte_idx < num_bytes) : (byte_idx += 1) {
                var b: u8 = 0;
                var bit_idx: usize = 0;
                while (bit_idx < 8) : (bit_idx += 1) {
                    const bit = byte_idx * 8 + bit_idx;
                    if (bit < num_bits and v.Bitset.isSet(bit)) {
                        b |= @as(u8, 1) << @as(u3, @intCast(bit_idx));
                    }
                }
                try ser.serialize(b);
            }
        },
        .Map => {
            const count = @as(u32, @intCast(v.Map.count()));
            try ser.serialize(count);
            var it = v.Map.iterator();
            while (it.next()) |entry| {
                try ser.serialize(entry.key_ptr.*);
                try serializeDynamicValue(ser, entry.value_ptr.*);
            }
        },
        .Array => {
            const count = @as(u32, @intCast(v.Array.items.len));
            try ser.serialize(count);
            for (v.Array.items) |item| {
                try serializeDynamicValue(ser, item);
            }
        },
        .Struct => return error.NestedStructUnsupportedInDynamicValue,
    }
}

fn deserializeDynamicValue(allocator: std.mem.Allocator, des: *Deserializer) !DynamicValue {
    const kind_byte = try des.deserialize(u8);
    const kind: TypeKind = std.enums.fromInt(TypeKind, kind_byte) orelse return error.InvalidTypeKind;
    switch (kind) {
        .Int8 => return .{ .Int8 = try des.deserialize(i8) },
        .UInt8 => return .{ .UInt8 = try des.deserialize(u8) },
        .Int16 => return .{ .Int16 = try des.deserialize(i16) },
        .UInt16 => return .{ .UInt16 = try des.deserialize(u16) },
        .Int32 => return .{ .Int32 = try des.deserialize(i32) },
        .UInt32 => return .{ .UInt32 = try des.deserialize(u32) },
        .Int64 => return .{ .Int64 = try des.deserialize(i64) },
        .UInt64 => return .{ .UInt64 = try des.deserialize(u64) },
        .Float32 => return .{ .Float32 = try des.deserialize(f32) },
        .Float64 => return .{ .Float64 = try des.deserialize(f64) },
        .Bool => return .{ .Bool = try des.deserialize(bool) },
        .String => {
            const s = try des.deserialize([]const u8);
            const duped = try allocator.dupe(u8, s);
            return .{ .String = duped };
        },
        .Void => return .{ .Void = {} },
        .Optional => {
            const pres = try des.deserialize(u8);
            if (pres != 0) {
                const inner = try deserializeDynamicValue(allocator, des);
                const ptr = try allocator.create(DynamicValue);
                ptr.* = inner;
                return .{ .Optional = ptr };
            }
            return .{ .Optional = null };
        },
        .Union => {
            const disc = try des.deserialize(i32);
            const inner = try deserializeDynamicValue(allocator, des);
            const ptr = try allocator.create(DynamicValue);
            ptr.* = inner;
            return .{ .Union = .{ .discriminator = disc, .value = ptr } };
        },
        .Bitset => {
            const num_bits = try des.deserialize(u32);
            var bs = try std.bit_set.DynamicBitSetUnmanaged.initEmpty(allocator, num_bits);
            errdefer bs.deinit(allocator);
            const num_bytes = (num_bits + 7) / 8;
            var byte_idx: usize = 0;
            while (byte_idx < num_bytes) : (byte_idx += 1) {
                const b = try des.deserialize(u8);
                var bit_idx: usize = 0;
                while (bit_idx < 8) : (bit_idx += 1) {
                    const bit = byte_idx * 8 + bit_idx;
                    if (bit < num_bits) {
                        if ((b & (@as(u8, 1) << @as(u3, @intCast(bit_idx)))) != 0) {
                            bs.set(bit);
                        }
                    }
                }
            }
            return .{ .Bitset = bs };
        },
        .Map => {
            const count = try des.deserialize(u32);
            var map = std.StringHashMap(DynamicValue).init(allocator);
            errdefer {
                var it = map.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                map.deinit();
            }
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                const key_slice = try des.deserialize([]const u8);
                const key = try allocator.dupe(u8, key_slice);
                const v = try deserializeDynamicValue(allocator, des);
                try map.put(key, v);
            }
            return .{ .Map = map };
        },
        .Array => {
            const count = try des.deserialize(u32);
            var arr = try std.ArrayListUnmanaged(DynamicValue).initCapacity(allocator, count);
            errdefer {
                for (arr.items) |*item| item.deinit(allocator);
                arr.deinit(allocator);
            }
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                const item = try deserializeDynamicValue(allocator, des);
                try arr.append(allocator, item);
            }
            return .{ .Array = arr };
        },
        .Struct => return error.NestedStructUnsupportedInDynamicValue,
    }
}

/// @brief Deserialize dynamic.
pub fn deserializeDynamic(allocator: std.mem.Allocator, buffer: []const u8, type_obj: *const TypeObject) !DynamicValue {
    var des = Deserializer.init(buffer, .Little);

    var struct_map = std.StringHashMap(DynamicValue).init(allocator);
    errdefer {
        var it = struct_map.valueIterator();
        while (it.next()) |val| val.deinit(allocator);
        struct_map.deinit();
    }

    for (type_obj.fields.items) |field| {
        var val: DynamicValue = undefined;
        switch (field.kind) {
            .Int8 => {
                const v = try des.deserialize(i8);
                val = .{ .Int8 = v };
            },
            .UInt8 => {
                const v = try des.deserialize(u8);
                val = .{ .UInt8 = v };
            },
            .Int16 => {
                const v = try des.deserialize(i16);
                val = .{ .Int16 = v };
            },
            .UInt16 => {
                const v = try des.deserialize(u16);
                val = .{ .UInt16 = v };
            },
            .Int32 => {
                const v = try des.deserialize(i32);
                val = .{ .Int32 = v };
            },
            .UInt32 => {
                const v = try des.deserialize(u32);
                val = .{ .UInt32 = v };
            },
            .Int64 => {
                const v = try des.deserialize(i64);
                val = .{ .Int64 = v };
            },
            .UInt64 => {
                const v = try des.deserialize(u64);
                val = .{ .UInt64 = v };
            },
            .Float32 => {
                const v = try des.deserialize(f32);
                val = .{ .Float32 = v };
            },
            .Float64 => {
                const v = try des.deserialize(f64);
                val = .{ .Float64 = v };
            },
            .Bool => {
                const v = try des.deserialize(bool);
                val = .{ .Bool = v };
            },
            .String => {
                // In our MVP, Strings are fixed u8 arrays
                const str_buf = try allocator.alloc(u8, field.array_len);
                errdefer allocator.free(str_buf);

                // CDR arrays are just consecutive bytes
                const bytes = try des.readAll(field.array_len);
                @memcpy(str_buf, bytes);

                val = .{ .String = str_buf };
            },
            .Array => {
                const count = if (field.array_len > 0) field.array_len else try des.deserialize(u32);
                var arr = try std.ArrayListUnmanaged(DynamicValue).initCapacity(allocator, count);
                errdefer {
                    for (arr.items) |*item| item.deinit(allocator);
                    arr.deinit(allocator);
                }
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const item = try deserializeDynamicValue(allocator, &des);
                    try arr.append(allocator, item);
                }
                val = .{ .Array = arr };
            },
            .Union => {
                const disc = try des.deserialize(i32);
                const inner = try deserializeDynamicValue(allocator, &des);
                const ptr = try allocator.create(DynamicValue);
                ptr.* = inner;
                val = .{ .Union = .{ .discriminator = disc, .value = ptr } };
            },
            .Map => {
                const count = try des.deserialize(u32);
                var map = std.StringHashMap(DynamicValue).init(allocator);
                errdefer {
                    var it = map.iterator();
                    while (it.next()) |entry| {
                        allocator.free(entry.key_ptr.*);
                        entry.value_ptr.deinit(allocator);
                    }
                    map.deinit();
                }
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const key_slice = try des.deserialize([]const u8);
                    const key = try allocator.dupe(u8, key_slice);
                    const v = try deserializeDynamicValue(allocator, &des);
                    try map.put(key, v);
                }
                val = .{ .Map = map };
            },
            .Bitset => {
                const num_bits = try des.deserialize(u32);
                var bs = try std.bit_set.DynamicBitSetUnmanaged.initEmpty(allocator, num_bits);
                errdefer bs.deinit(allocator);
                const num_bytes = (num_bits + 7) / 8;
                var byte_idx: usize = 0;
                while (byte_idx < num_bytes) : (byte_idx += 1) {
                    const b = try des.deserialize(u8);
                    var bit_idx: usize = 0;
                    while (bit_idx < 8) : (bit_idx += 1) {
                        const bit = byte_idx * 8 + bit_idx;
                        if (bit < num_bits) {
                            if ((b & (@as(u8, 1) << @as(u3, @intCast(bit_idx)))) != 0) {
                                bs.set(bit);
                            }
                        }
                    }
                }
                val = .{ .Bitset = bs };
            },
            .Optional => {
                const pres = try des.deserialize(u8);
                if (pres != 0) {
                    const inner = try deserializeDynamicValue(allocator, &des);
                    const ptr = try allocator.create(DynamicValue);
                    ptr.* = inner;
                    val = .{ .Optional = ptr };
                } else {
                    val = .{ .Optional = null };
                }
            },
            else => return error.UnsupportedDynamicType,
        }
        try struct_map.put(field.name, val);
    }
    return DynamicValue{ .Struct = struct_map };
}

/// @brief Serialize dynamic.
pub fn serializeDynamic(allocator: std.mem.Allocator, val: DynamicValue, type_obj: *const TypeObject) ![]const u8 {
    const buf = try allocator.alloc(u8, 8192);
    errdefer allocator.free(buf);
    var ser = Serializer.init(buf, .Little);

    if (val != .Struct) return error.RootMustBeStruct;
    const struct_map = val.Struct;

    for (type_obj.fields.items) |field| {
        const field_val = struct_map.get(field.name) orelse return error.MissingField;

        switch (field.kind) {
            .Int8 => {
                if (field_val != .Int8) return error.TypeMismatch;
                try ser.serialize(field_val.Int8);
            },
            .UInt8 => {
                if (field_val != .UInt8) return error.TypeMismatch;
                try ser.serialize(field_val.UInt8);
            },
            .Int16 => {
                if (field_val != .Int16) return error.TypeMismatch;
                try ser.serialize(field_val.Int16);
            },
            .UInt16 => {
                if (field_val != .UInt16) return error.TypeMismatch;
                try ser.serialize(field_val.UInt16);
            },
            .Int32 => {
                if (field_val != .Int32) return error.TypeMismatch;
                try ser.serialize(field_val.Int32);
            },
            .UInt32 => {
                if (field_val != .UInt32) return error.TypeMismatch;
                try ser.serialize(field_val.UInt32);
            },
            .Int64 => {
                if (field_val != .Int64) return error.TypeMismatch;
                try ser.serialize(field_val.Int64);
            },
            .UInt64 => {
                if (field_val != .UInt64) return error.TypeMismatch;
                try ser.serialize(field_val.UInt64);
            },
            .Float32 => {
                if (field_val != .Float32) return error.TypeMismatch;
                try ser.serialize(field_val.Float32);
            },
            .Float64 => {
                if (field_val != .Float64) return error.TypeMismatch;
                try ser.serialize(field_val.Float64);
            },
            .Bool => {
                if (field_val != .Bool) return error.TypeMismatch;
                try ser.serialize(field_val.Bool);
            },
            .String => {
                if (field_val != .String) return error.TypeMismatch;
                const str_val = field_val.String;
                if (str_val.len > field.array_len) return error.StringTooLong;

                // Write exactly array_len bytes (pad with zeroes)
                try ser.writeAll(str_val);
                const padding = field.array_len - @as(u32, @intCast(str_val.len));
                var i: u32 = 0;
                while (i < padding) : (i += 1) {
                    try ser.writeAll(&[_]u8{0});
                }
            },
            .Array => {
                if (field_val != .Array) return error.TypeMismatch;
                if (field.array_len == 0) {
                    try ser.serialize(@as(u32, @intCast(field_val.Array.items.len)));
                }
                for (field_val.Array.items) |item| {
                    try serializeDynamicValue(&ser, item);
                }
            },
            .Union => {
                if (field_val != .Union) return error.TypeMismatch;
                try ser.serialize(field_val.Union.discriminator);
                try serializeDynamicValue(&ser, field_val.Union.value.*);
            },
            .Map => {
                if (field_val != .Map) return error.TypeMismatch;
                const count = @as(u32, @intCast(field_val.Map.count()));
                try ser.serialize(count);
                var it = field_val.Map.iterator();
                while (it.next()) |entry| {
                    try ser.serialize(entry.key_ptr.*);
                    try serializeDynamicValue(&ser, entry.value_ptr.*);
                }
            },
            .Bitset => {
                if (field_val != .Bitset) return error.TypeMismatch;
                const num_bits = @as(u32, @intCast(field_val.Bitset.bit_length));
                try ser.serialize(num_bits);
                const num_bytes = (num_bits + 7) / 8;
                var byte_idx: usize = 0;
                while (byte_idx < num_bytes) : (byte_idx += 1) {
                    var b: u8 = 0;
                    var bit_idx: usize = 0;
                    while (bit_idx < 8) : (bit_idx += 1) {
                        const bit = byte_idx * 8 + bit_idx;
                        if (bit < num_bits and field_val.Bitset.isSet(bit)) {
                            b |= @as(u8, 1) << @as(u3, @intCast(bit_idx));
                        }
                    }
                    try ser.serialize(b);
                }
            },
            .Optional => {
                if (field_val != .Optional) return error.TypeMismatch;
                if (field_val.Optional) |inner| {
                    try ser.serialize(@as(u8, 1));
                    try serializeDynamicValue(&ser, inner.*);
                } else {
                    try ser.serialize(@as(u8, 0));
                }
            },
            else => return error.UnsupportedDynamicType,
        }
    }
    return allocator.realloc(buf, ser.pos);
}

/// @brief Serialize type object.
pub fn serializeTypeObject(allocator: std.mem.Allocator, type_obj: TypeObject) ![]const u8 {
    const buf = try allocator.alloc(u8, 4096);
    errdefer allocator.free(buf);
    var ser = Serializer.init(buf, .Little);

    try ser.serialize(@as([]const u8, type_obj.name));
    try ser.serialize(type_obj.extensibility);
    try ser.serialize(@as(u32, @intCast(type_obj.fields.items.len)));

    for (type_obj.fields.items) |field| {
        try ser.serialize(@as([]const u8, field.name));
        try ser.serialize(field.kind);
        try ser.serialize(field.array_len);
    }

    // We realloc to shrink, or just return slice (the latter leaks the unused tail if we don't shrink,
    // but in MVP it's acceptable for short lived allocations, or we can just shrink it)
    return allocator.realloc(buf, ser.pos);
}

/// @brief Deserialize type object.
pub fn deserializeTypeObject(allocator: std.mem.Allocator, buffer: []const u8) !TypeObject {
    var des = Deserializer.init(buffer, .Little);

    const name_slice = try des.deserialize([]const u8);
    const name = try allocator.dupe(u8, name_slice);
    errdefer allocator.free(name);

    const ext = try des.deserialize(ExtensibilityKind);

    var fields: std.ArrayListUnmanaged(FieldDef) = .empty;
    errdefer {
        for (fields.items) |field| {
            allocator.free(field.name);
        }
        fields.deinit(allocator);
    }

    const len = try des.deserialize(u32);

    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const fname_slice = try des.deserialize([]const u8);
        const fname = try allocator.dupe(u8, fname_slice);
        errdefer allocator.free(fname);
        const kind = try des.deserialize(TypeKind);
        const arr_len = try des.deserialize(u32);
        try fields.append(allocator, .{ .name = fname, .kind = kind, .array_len = arr_len });
    }

    return TypeObject{
        .name = name,
        .extensibility = ext,
        .fields = fields,
        .is_owned = true,
    };
}

pub const TypeLookupRequest = struct {
    type_name: [256]u8 = std.mem.zeroes([256]u8),
    type_name_len: u32 = 0,
};

pub const TypeLookupReply = struct {
    type_name: [256]u8 = std.mem.zeroes([256]u8),
    type_name_len: u32 = 0,
    type_object_cdr: [4096]u8 = std.mem.zeroes([4096]u8),
    type_object_len: u32 = 0,
};

test "xtypes - generate and dynamic serialize" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const TestStruct = struct {
        a: i32,
        b: f32,
    };

    // 1. Generate TypeObject
    var type_obj = try generateTypeObject(alloc, TestStruct);
    defer type_obj.deinit(alloc);

    try testing.expect(std.mem.endsWith(u8, type_obj.name, "TestStruct"));
    try testing.expectEqual(@as(usize, 2), type_obj.fields.items.len);

    // 2. Create DynamicValue
    var dyn_val = DynamicValue{ .Struct = std.StringHashMap(DynamicValue).init(alloc) };
    try dyn_val.Struct.put("a", DynamicValue{ .Int32 = 42 });
    try dyn_val.Struct.put("b", DynamicValue{ .Float32 = 3.14 });
    defer dyn_val.deinit(alloc);

    // 3. Serialize
    const ser = try serializeDynamic(alloc, dyn_val, &type_obj);
    defer alloc.free(ser);

    // 4. Deserialize
    var deser_val = try deserializeDynamic(alloc, ser, &type_obj);
    defer deser_val.deinit(alloc);

    try testing.expectEqual(@as(i32, 42), deser_val.Struct.get("a").?.Int32);
    try testing.expectEqual(@as(f32, 3.14), deser_val.Struct.get("b").?.Float32);
}

test "xtypes - TypeObject isAssignable rules for FINAL, APPENDABLE, and MUTABLE" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // 1. FINAL matching
    var final1 = TypeObject{ .name = "MyType", .extensibility = .FINAL, .fields = .empty };
    defer final1.deinit(alloc);
    try final1.fields.append(alloc, .{ .name = "x", .kind = .Int32 });
    try final1.fields.append(alloc, .{ .name = "y", .kind = .Float32 });

    var final2 = TypeObject{ .name = "MyType", .extensibility = .FINAL, .fields = .empty };
    defer final2.deinit(alloc);
    try final2.fields.append(alloc, .{ .name = "x", .kind = .Int32 });
    try final2.fields.append(alloc, .{ .name = "y", .kind = .Float32 });

    try testing.expect(TypeObject.isAssignable(final1, final2));

    // Mismatched field name in FINAL
    var final_mismatch = TypeObject{ .name = "MyType", .extensibility = .FINAL, .fields = .empty };
    defer final_mismatch.deinit(alloc);
    try final_mismatch.fields.append(alloc, .{ .name = "x", .kind = .Int32 });
    try final_mismatch.fields.append(alloc, .{ .name = "z", .kind = .Float32 });
    try testing.expect(!TypeObject.isAssignable(final1, final_mismatch));

    // 2. APPENDABLE matching
    var app_req = TypeObject{ .name = "AppType", .extensibility = .APPENDABLE, .fields = .empty };
    defer app_req.deinit(alloc);
    try app_req.fields.append(alloc, .{ .name = "a", .kind = .Int32 });

    var app_off = TypeObject{ .name = "AppType", .extensibility = .APPENDABLE, .fields = .empty };
    defer app_off.deinit(alloc);
    try app_off.fields.append(alloc, .{ .name = "a", .kind = .Int32 });
    try app_off.fields.append(alloc, .{ .name = "b", .kind = .Int64 }); // appended extra field

    // Requested has prefix of offered -> assignable
    try testing.expect(TypeObject.isAssignable(app_req, app_off));
    // Offered has fewer fields than requested -> not assignable
    try testing.expect(!TypeObject.isAssignable(app_off, app_req));

    // 3. MUTABLE matching
    var mut_req = TypeObject{ .name = "MutType", .extensibility = .MUTABLE, .fields = .empty };
    defer mut_req.deinit(alloc);
    try mut_req.fields.append(alloc, .{ .name = "f2", .kind = .String, .array_len = 16 });
    try mut_req.fields.append(alloc, .{ .name = "f1", .kind = .Int32 });

    var mut_off = TypeObject{ .name = "MutType", .extensibility = .MUTABLE, .fields = .empty };
    defer mut_off.deinit(alloc);
    try mut_off.fields.append(alloc, .{ .name = "f1", .kind = .Int32 }); // reordered
    try mut_off.fields.append(alloc, .{ .name = "f2", .kind = .String, .array_len = 16 });
    try mut_off.fields.append(alloc, .{ .name = "f3", .kind = .Bool }); // extra field

    try testing.expect(TypeObject.isAssignable(mut_req, mut_off));

    // Incompatible type in common field -> false
    var mut_incompat = TypeObject{ .name = "MutType", .extensibility = .MUTABLE, .fields = .empty };
    defer mut_incompat.deinit(alloc);
    try mut_incompat.fields.append(alloc, .{ .name = "f1", .kind = .Float32 }); // float vs int
    try testing.expect(!TypeObject.isAssignable(mut_req, mut_incompat));
}

test "xtypes - generateTypeObject with ddz_extensibility" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const DefaultFinal = struct { id: u32 };
    const MutableStruct = struct {
        pub const ddz_extensibility = "MUTABLE";
        id: u32,
        val: f32,
    };
    const AppendableStruct = struct {
        pub const ddz_extensibility = "APPENDABLE";
        id: u32,
    };

    var to_final = try generateTypeObject(alloc, DefaultFinal);
    defer to_final.deinit(alloc);
    try testing.expectEqual(ExtensibilityKind.FINAL, to_final.extensibility);

    var to_mut = try generateTypeObject(alloc, MutableStruct);
    defer to_mut.deinit(alloc);
    try testing.expectEqual(ExtensibilityKind.MUTABLE, to_mut.extensibility);

    var to_app = try generateTypeObject(alloc, AppendableStruct);
    defer to_app.deinit(alloc);
    try testing.expectEqual(ExtensibilityKind.APPENDABLE, to_app.extensibility);
}

test "xtypes - DynamicValue Union, Map, Bitset, Optional, Array serialize and deserialize" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Build a TypeObject schema with advanced types
    var to = TypeObject{
        .name = "AdvancedType",
        .extensibility = .FINAL,
        .fields = .empty,
    };
    defer to.deinit(alloc);

    try to.fields.append(alloc, .{ .name = "my_array", .kind = .Array, .array_len = 2 });
    try to.fields.append(alloc, .{ .name = "my_union", .kind = .Union });
    try to.fields.append(alloc, .{ .name = "my_map", .kind = .Map });
    try to.fields.append(alloc, .{ .name = "my_bitset", .kind = .Bitset });
    try to.fields.append(alloc, .{ .name = "opt_some", .kind = .Optional });
    try to.fields.append(alloc, .{ .name = "opt_none", .kind = .Optional });

    // Build DynamicValue sample
    var sample = DynamicValue{ .Struct = std.StringHashMap(DynamicValue).init(alloc) };
    defer sample.deinit(alloc);

    // Array
    var arr = std.ArrayListUnmanaged(DynamicValue).empty;
    try arr.append(alloc, DynamicValue{ .Int32 = 10 });
    try arr.append(alloc, DynamicValue{ .Int32 = 20 });
    try sample.Struct.put("my_array", DynamicValue{ .Array = arr });

    // Union
    const u_val = try DynamicValue.createUnion(alloc, 1, DynamicValue{ .Float32 = 99.5 });
    try sample.Struct.put("my_union", u_val);

    // Map
    var map_val = DynamicValue.createMap(alloc);
    try map_val.putMap(alloc, "alpha", DynamicValue{ .Int32 = 1 });
    try map_val.putMap(alloc, "beta", DynamicValue{ .Int32 = 2 });
    try sample.Struct.put("my_map", map_val);

    // Bitset
    var bs = try std.bit_set.DynamicBitSetUnmanaged.initEmpty(alloc, 16);
    bs.set(1);
    bs.set(7);
    try sample.Struct.put("my_bitset", DynamicValue{ .Bitset = bs });

    // Optional present
    const opt_some = try DynamicValue.createOptional(alloc, DynamicValue{ .Int32 = 777 });
    try sample.Struct.put("opt_some", opt_some);

    // Optional null
    const opt_none = try DynamicValue.createOptional(alloc, null);
    try sample.Struct.put("opt_none", opt_none);

    // Serialize
    const ser = try serializeDynamic(alloc, sample, &to);
    defer alloc.free(ser);

    // Deserialize
    var deser = try deserializeDynamic(alloc, ser, &to);
    defer deser.deinit(alloc);

    // Verify Array
    const deser_arr = deser.Struct.get("my_array").?.Array;
    try testing.expectEqual(@as(usize, 2), deser_arr.items.len);
    try testing.expectEqual(@as(i32, 10), deser_arr.items[0].Int32);
    try testing.expectEqual(@as(i32, 20), deser_arr.items[1].Int32);

    // Verify Union
    const deser_u = deser.Struct.get("my_union").?.Union;
    try testing.expectEqual(@as(i32, 1), deser_u.discriminator);
    try testing.expectEqual(@as(f32, 99.5), deser_u.value.Float32);

    // Verify Map
    const deser_map = deser.Struct.get("my_map").?.Map;
    try testing.expectEqual(@as(u32, 2), deser_map.count());
    try testing.expectEqual(@as(i32, 1), deser_map.get("alpha").?.Int32);
    try testing.expectEqual(@as(i32, 2), deser_map.get("beta").?.Int32);

    // Verify Bitset
    const deser_bs = deser.Struct.get("my_bitset").?.Bitset;
    try testing.expect(deser_bs.isSet(1));
    try testing.expect(deser_bs.isSet(7));
    try testing.expect(!deser_bs.isSet(0));
    try testing.expect(!deser_bs.isSet(2));

    // Verify Optional
    const deser_opt_some = deser.Struct.get("opt_some").?.Optional;
    try testing.expect(deser_opt_some != null);
    try testing.expectEqual(@as(i32, 777), deser_opt_some.?.Int32);

    const deser_opt_none = deser.Struct.get("opt_none").?.Optional;
    try testing.expect(deser_opt_none == null);
}
