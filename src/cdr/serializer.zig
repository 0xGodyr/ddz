//! @file serializer.zig
//! @brief Provides compile-time generated CDR (Common Data Representation) serialization for Zig structs.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const builtin = @import("builtin");
const Deserializer = @import("deserializer.zig").Deserializer;

/// @brief Endianness structure.
pub const Endianness = enum {
    Big,
    Little,

    /// @brief From native.
    pub fn fromNative(self: Endianness, comptime T: type, val: T) T {
        switch (@typeInfo(T)) {
            .int => return switch (self) {
                .Big => std.mem.nativeToBig(T, val),
                .Little => std.mem.nativeToLittle(T, val),
            },
            .float => {
                const IntType = if (@sizeOf(T) == 4) u32 else if (@sizeOf(T) == 8) u64 else u16;
                const int_val: IntType = @bitCast(val);
                const swapped = switch (self) {
                    .Big => std.mem.nativeToBig(IntType, int_val),
                    .Little => std.mem.nativeToLittle(IntType, int_val),
                };
                return @bitCast(swapped);
            },
            else => @compileError("fromNative only supports int and float"),
        }
    }
};

/// @brief Serializer structure.
pub const Serializer = struct {
    buffer: []u8,
    endianness: Endianness,
    pos: usize = 0,

    /// @brief Initializes a new instance.
    pub fn init(buffer: []u8, endianness: Endianness) Serializer {
        return .{
            .buffer = buffer,
            .endianness = endianness,
        };
    }

    /// @brief Write all.
    pub fn writeAll(self: *Serializer, data: []const u8) !void {
        if (self.pos + data.len > self.buffer.len) return error.BufferTooSmall;
        @memcpy(self.buffer[self.pos .. self.pos + data.len], data);
        self.pos += data.len;
    }

    /// @brief Align to.
    pub fn alignTo(self: *Serializer, alignment: usize) !void {
        const padding = (alignment - (self.pos % alignment)) % alignment;
        if (padding > 0) {
            const pad_bytes = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 }; // Max alignment we care about is 8
            try self.writeAll(pad_bytes[0..padding]);
        }
    }

    /// @brief Serialize.
    pub fn serialize(self: *Serializer, value: anytype) !void {
        const T = @TypeOf(value);
        switch (@typeInfo(T)) {
            .int, .float => {
                const align_size = if (@sizeOf(T) < 4) @sizeOf(T) else if (@sizeOf(T) >= 8) 8 else 4;
                try self.alignTo(align_size);
                const converted = self.endianness.fromNative(T, value);
                try self.writeAll(std.mem.asBytes(&converted));
            },
            .bool => {
                const b: u8 = if (value) 1 else 0;
                try self.serialize(b);
            },
            .@"enum" => {
                try self.serialize(@backingInt(value));
            },
            .@"struct" => |info| {
                const is_mutable = @hasDecl(T, "ddz_extensibility") and std.mem.eql(u8, T.ddz_extensibility, "MUTABLE");
                if (is_mutable) {
                    inline for (info.field_names, 0..) |field_name, i| {
                        const pid = @as(u16, @intCast(i + 0x4000));
                        try self.serialize(pid);

                        const len_pos = self.pos;
                        try self.serialize(@as(u16, 0)); // placeholder

                        const start_pos = self.pos;
                        try self.serialize(@field(value, field_name));
                        const actual_len = self.pos - start_pos;

                        // overwrite length
                        const native_endian = builtin.cpu.arch.endian();
                        const req_endian: std.builtin.Endian = switch (self.endianness) {
                            .Big => .big,
                            .Little => .little,
                        };
                        var len_val: u16 = @intCast(actual_len);
                        if (req_endian != native_endian) len_val = @byteSwap(len_val);
                        @memcpy(self.buffer[len_pos .. len_pos + 2], std.mem.asBytes(&len_val));

                        // padding
                        try self.alignTo(4);
                    }
                    try self.serialize(@as(u16, 0x0001)); // PID_SENTINEL
                    try self.serialize(@as(u16, 0));
                } else {
                    inline for (info.field_names) |field_name| {
                        try self.serialize(@field(value, field_name));
                    }
                }
            },
            .array => |info| {
                const is_primitive = switch (@typeInfo(info.child)) {
                    .int, .float => true,
                    else => false,
                };
                if (info.child == u8) {
                    try self.writeAll(&value);
                } else if (is_primitive) {
                    const child_size = @sizeOf(info.child);
                    const align_size = if (child_size < 4) child_size else if (child_size >= 8) 8 else 4;
                    try self.alignTo(align_size);

                    const native_endian = builtin.cpu.arch.endian();
                    const req_endian: std.builtin.Endian = switch (self.endianness) {
                        .Big => .big,
                        .Little => .little,
                    };

                    if (req_endian == native_endian) {
                        try self.writeAll(std.mem.asBytes(&value));
                    } else {
                        // Bulk write with byte swapping
                        for (value) |item| {
                            const converted = self.endianness.fromNative(info.child, item);
                            try self.writeAll(std.mem.asBytes(&converted));
                        }
                    }
                } else {
                    for (value) |item| {
                        try self.serialize(item);
                    }
                }
            },
            .pointer => |info| {
                if (info.size == .slice) {
                    // Sequence: write length (4 bytes)
                    try self.serialize(@as(u32, @intCast(value.len)));

                    const is_primitive = switch (@typeInfo(info.child)) {
                        .int, .float => true,
                        else => false,
                    };
                    if (info.child == u8) {
                        try self.writeAll(value);
                    } else if (is_primitive) {
                        const child_size = @sizeOf(info.child);
                        const align_size = if (child_size < 4) child_size else if (child_size >= 8) 8 else 4;
                        try self.alignTo(align_size);

                        const native_endian = builtin.cpu.arch.endian();
                        const req_endian: std.builtin.Endian = switch (self.endianness) {
                            .Big => .big,
                            .Little => .little,
                        };

                        if (req_endian == native_endian) {
                            try self.writeAll(std.mem.sliceAsBytes(value));
                        } else {
                            for (value) |item| {
                                const converted = self.endianness.fromNative(info.child, item);
                                try self.writeAll(std.mem.asBytes(&converted));
                            }
                        }
                    } else {
                        for (value) |item| {
                            try self.serialize(item);
                        }
                    }
                } else {
                    @compileError("Unsupported pointer type in CDR serialization");
                }
            },
            else => @compileError("Unsupported type: " ++ @typeName(T)),
        }
    }
};

test "CDR Serialize basic struct" {
    const TestStruct = struct {
        id: u32,
        val: u16,
        flag: bool,
    };

    var buf: [128]u8 = undefined;
    var ser = Serializer.init(&buf, .Big);

    const data = TestStruct{ .id = 0x11223344, .val = 0xAABB, .flag = true };
    try ser.serialize(data);

    try std.testing.expectEqual(@as(usize, 7), ser.pos);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x11, 0x22, 0x33, 0x44, 0xAA, 0xBB, 0x01 }, buf[0..7]);
}

test "CDR Serialize bulk array batching" {
    const TestBatch = struct {
        floats: [4]f32,
        ints: [3]u32,
    };

    var buf: [128]u8 = undefined;
    var ser = Serializer.init(&buf, .Little);

    const data = TestBatch{
        .floats = [_]f32{ 1.0, 2.0, 3.0, 4.0 },
        .ints = [_]u32{ 100, 200, 300 },
    };

    try ser.serialize(data);
    try std.testing.expectEqual(@as(usize, 28), ser.pos);
}

test "Mutable Extensibility" {
    const MutableStruct = struct {
        pub const ddz_extensibility = "MUTABLE";
        a: u32 = 10,
        b: u16 = 20,
    };

    var buf: [128]u8 = undefined;
    var ser = Serializer.init(&buf, .Little);
    try ser.serialize(MutableStruct{ .a = 123, .b = 456 });

    var des = Deserializer.init(buf[0..ser.pos], .Little);
    const parsed = try des.deserialize(MutableStruct);
    try std.testing.expectEqual(@as(u32, 123), parsed.a);
    try std.testing.expectEqual(@as(u16, 456), parsed.b);
}
