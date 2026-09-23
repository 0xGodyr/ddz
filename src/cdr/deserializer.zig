//! @file deserializer.zig
//! @brief Provides compile-time generated CDR (Common Data Representation) deserialization for Zig structs.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const builtin = @import("builtin");
const SerializerModule = @import("serializer.zig");
const Endianness = SerializerModule.Endianness;
const Serializer = SerializerModule.Serializer;

/// @brief Deserializer structure.
pub const Deserializer = struct {
    buffer: []const u8,
    endianness: Endianness,
    pos: usize = 0,

    /// @brief Initializes a new instance.
    pub fn init(buffer: []const u8, endianness: Endianness) Deserializer {
        return .{
            .buffer = buffer,
            .endianness = endianness,
        };
    }

    /// @brief Read all.
    pub fn readAll(self: *Deserializer, len: usize) ![]const u8 {
        if (self.pos + len > self.buffer.len) return error.BufferTooSmall;
        const slice = self.buffer[self.pos .. self.pos + len];
        self.pos += len;
        return slice;
    }

    /// @brief Align to.
    pub fn alignTo(self: *Deserializer, alignment: usize) !void {
        const padding = (alignment - (self.pos % alignment)) % alignment;
        if (padding > 0) {
            _ = try self.readAll(padding);
        }
    }

    /// @brief Deserialize.
    pub fn deserialize(self: *Deserializer, comptime T: type) !T {
        switch (@typeInfo(T)) {
            .int, .float => {
                const align_size = if (@sizeOf(T) < 4) @sizeOf(T) else if (@sizeOf(T) >= 8) 8 else 4;
                try self.alignTo(align_size);
                const bytes = try self.readAll(@sizeOf(T));
                var val: T = undefined;
                @memcpy(std.mem.asBytes(&val), bytes);
                return self.endianness.fromNative(T, val); // fromNative works both ways since it swaps
            },
            .bool => {
                const b = try self.deserialize(u8);
                return b != 0;
            },
            .@"enum" => {
                const int_val = try self.deserialize(@typeInfo(T).@"enum".tag_type);
                return std.enums.fromInt(T, int_val) orelse return error.InvalidEnumValue;
            },
            .@"struct" => |info| {
                var res: T = undefined;
                const is_mutable = @hasDecl(T, "ddz_extensibility") and std.mem.eql(u8, T.ddz_extensibility, "MUTABLE");

                if (is_mutable) {
                    // Pre-fill with defaults or undefined
                    inline for (info.field_names, 0..) |field_name, i| {
                        const FieldType = info.field_types[i];
                        if (info.field_attrs[i].default_value_ptr) |def| {
                            const def_val = @as(*const FieldType, @ptrCast(@alignCast(def))).*;
                            @field(res, field_name) = def_val;
                        } else {
                            @field(res, field_name) = std.mem.zeroes(FieldType);
                        }
                    }

                    while (self.pos < self.buffer.len) {
                        const pid = try self.deserialize(u16);
                        if (pid == 0x0001) break; // PID_SENTINEL

                        const length = try self.deserialize(u16);
                        const next_pos = self.pos + length;
                        const aligned_next_pos = (next_pos + 3) & ~@as(usize, 3);
                        if (aligned_next_pos > self.buffer.len) return error.EndOfStream;

                        // Find matching field
                        inline for (info.field_names, 0..) |field_name, i| {
                            if (pid == i + 0x4000) {
                                const FieldType = info.field_types[i];
                                @field(res, field_name) = try self.deserialize(FieldType);
                            }
                        }

                        // Skip to next parameter aligned
                        self.pos = aligned_next_pos;
                    }
                } else {
                    inline for (info.field_names, 0..) |field_name, i| {
                        const FieldType = info.field_types[i];
                        @field(res, field_name) = try self.deserialize(FieldType);
                    }
                }
                return res;
            },
            .array => |info| {
                var res: T = undefined;
                const is_primitive = switch (@typeInfo(info.child)) {
                    .int, .float => true,
                    else => false,
                };
                if (info.child == u8) {
                    const bytes = try self.readAll(res.len);
                    @memcpy(&res, bytes);
                } else if (is_primitive) {
                    const child_size = @sizeOf(info.child);
                    const align_size = if (child_size < 4) child_size else if (child_size >= 8) 8 else 4;
                    try self.alignTo(align_size);

                    const native_endian = builtin.cpu.arch.endian();
                    const req_endian: std.builtin.Endian = switch (self.endianness) {
                        .Big => .big,
                        .Little => .little,
                    };

                    const total_bytes = res.len * child_size;
                    const bytes = try self.readAll(total_bytes);

                    if (req_endian == native_endian) {
                        @memcpy(std.mem.asBytes(&res), bytes);
                    } else {
                        var offset: usize = 0;
                        for (&res) |*item| {
                            var tmp: info.child = undefined;
                            @memcpy(std.mem.asBytes(&tmp), bytes[offset .. offset + child_size]);
                            item.* = self.endianness.fromNative(info.child, tmp);
                            offset += child_size;
                        }
                    }
                } else {
                    for (&res) |*item| {
                        item.* = try self.deserialize(info.child);
                    }
                }
                return res;
            },
            .pointer => |info| {
                if (info.size == .slice) {
                    const len = try self.deserialize(u32);
                    const is_primitive = switch (@typeInfo(info.child)) {
                        .int, .float => true,
                        else => false,
                    };
                    if (info.child == u8) {
                        return try self.readAll(len);
                    } else if (is_primitive) {
                        const child_size = @sizeOf(info.child);
                        const align_size = if (child_size < 4) child_size else if (child_size >= 8) 8 else 4;
                        try self.alignTo(align_size);

                        const total_bytes = len * child_size;
                        _ = try self.readAll(total_bytes);

                        // We must cast the bytes to a slice of info.child.
                        // Since this slice points directly into the buffer, this is only safe if endianness matches
                        // AND alignment is correct. For a general purpose safe deserializer, it's safer to allocate,
                        // but since we want zero-copy and know the user might just want u8 strings, we just support u8.
                        @compileError("Only []const u8 slices are currently supported for zero-copy deserialization");
                    } else {
                        @compileError("Only []const u8 slices are currently supported for zero-copy deserialization");
                    }
                }
                @compileError("Unsupported pointer type for deserialization: " ++ @typeName(T));
            },
            else => @compileError("Unsupported type for deserialization: " ++ @typeName(T)),
        }
    }
};

test "CDR Deserialize basic struct" {
    const TestStruct = struct {
        id: u32,
        val: u16,
        flag: bool,
    };

    const buf = &[_]u8{ 0x11, 0x22, 0x33, 0x44, 0xAA, 0xBB, 0x01 };
    var des = Deserializer.init(buf, .Big);

    const data = try des.deserialize(TestStruct);

    try std.testing.expectEqual(@as(u32, 0x11223344), data.id);
    try std.testing.expectEqual(@as(u16, 0xAABB), data.val);
    try std.testing.expectEqual(true, data.flag);
    try std.testing.expectEqual(@as(usize, 7), des.pos);
}

test "CDR Deserialize bulk array batching" {
    const TestBatch = struct {
        floats: [4]f32,
        ints: [3]u32,
    };

    var buf: [128]u8 = undefined;
    var ser = Serializer.init(&buf, .Little);

    const original = TestBatch{
        .floats = [_]f32{ 1.0, 2.0, 3.0, 4.0 },
        .ints = [_]u32{ 100, 200, 300 },
    };
    try ser.serialize(original);

    var des = Deserializer.init(buf[0..ser.pos], .Little);
    const decoded = try des.deserialize(TestBatch);

    try std.testing.expectEqualSlices(f32, &original.floats, &decoded.floats);
    try std.testing.expectEqualSlices(u32, &original.ints, &decoded.ints);
}

test "CDR Deserialize out of bounds" {
    var buffer = [_]u8{ 1, 2, 3 }; // Too short
    var des = Deserializer.init(&buffer, .Little);

    const TestStruct = struct {
        a: u32,
        b: u32,
    };

    const result = des.deserialize(TestStruct);
    try std.testing.expectError(error.BufferTooSmall, result);
}

test "CDR Deserialize string overflow" {
    // A string length of 100, but buffer only has 4 bytes of data after length
    var buffer = [_]u8{ 100, 0, 0, 0, 65, 66, 67, 68 };
    var des = Deserializer.init(&buffer, .Little);

    const result = des.deserialize([]const u8);
    try std.testing.expectError(error.BufferTooSmall, result);
}

test "Deserializer BufferTooSmall on Strings" {
    // Length is 10, but buffer is only 4
    var buf = [_]u8{ 10, 0, 0, 0 };
    var des = Deserializer.init(&buf, .Little);

    const result = des.deserialize([]const u8);
    try std.testing.expectError(error.BufferTooSmall, result);
}

test "Deserializer BufferTooSmall on Arrays" {
    var buf = [_]u8{ 1, 2, 3 };
    var des = Deserializer.init(&buf, .Little);

    const result = des.deserialize([4]u8);
    try std.testing.expectError(error.BufferTooSmall, result);
}

test "Deserializer Alignment Requirements" {
    var buf = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 };
    var des = Deserializer.init(&buf, .Little);

    // Read 1 byte
    const b = try des.deserialize(u8);
    try std.testing.expectEqual(@as(u8, 0), b);

    // Next u32 should align to 4 bytes, so pos goes to 4!
    const val = try des.deserialize(u32);
    try std.testing.expectEqual(@as(u32, 0x07060504), val); // bytes 4,5,6,7
}
