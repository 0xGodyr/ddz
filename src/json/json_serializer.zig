//! @file json_serializer.zig
//! @brief High-performance serializer for DDS-JSON payloads complying with OMG DDS-JSON specification.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");

/// Options for JSON stringification.
pub const Options = std.json.Stringify.Options;

pub const JsonSerializer = struct {
    /// Standard OMG DDS-JSON RTPS wire encapsulation header (identifier = 0x0005, options = 0x0000).
    pub const ENCAPSULATION_HEADER_JSON: [4]u8 = .{ 0x00, 0x05, 0x00, 0x00 };

    /// Serializes a value into a newly allocated UTF-8 JSON byte slice without encapsulation header.
    /// Caller owns the returned slice and must free it with allocator.
    pub fn serialize(allocator: std.mem.Allocator, value: anytype, options: Options) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try std.json.Stringify.value(value, options, &out.writer);
        return out.toOwnedSlice();
    }

    /// Serializes a value into a newly allocated wire payload with the 4-byte OMG DDS-JSON encapsulation header prepended.
    /// Caller owns the returned slice and must free it with allocator.
    pub fn serializeWire(allocator: std.mem.Allocator, value: anytype, options: Options) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try out.writer.writeAll(&ENCAPSULATION_HEADER_JSON);
        try std.json.Stringify.value(value, options, &out.writer);
        return out.toOwnedSlice();
    }

    /// Serializes a value into a user-provided buffer without encapsulation header (zero heap allocations).
    /// Returns a slice of the written bytes.
    pub fn serializeToBuf(buf: []u8, value: anytype) ![]const u8 {
        return std.fmt.bufPrint(buf, "{f}", .{std.json.fmt(value, .{})});
    }

    /// Serializes a value into a user-provided buffer with the 4-byte OMG DDS-JSON encapsulation header prepended.
    /// Returns a slice of the written wire bytes.
    pub fn serializeWireToBuf(buf: []u8, value: anytype) ![]const u8 {
        if (buf.len < ENCAPSULATION_HEADER_JSON.len) return error.NoSpaceLeft;
        @memcpy(buf[0..4], &ENCAPSULATION_HEADER_JSON);
        const json_str = try std.fmt.bufPrint(buf[4..], "{f}", .{std.json.fmt(value, .{})});
        return buf[0 .. 4 + json_str.len];
    }

    /// Streams JSON formatting directly to a std.Io.Writer.
    pub fn stringify(value: anytype, options: Options, writer: *std.Io.Writer) !void {
        try std.json.Stringify.value(value, options, writer);
    }
};
