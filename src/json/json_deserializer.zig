//! @file json_deserializer.zig
//! @brief High-performance deserializer for DDS-JSON payloads complying with OMG DDS-JSON specification.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");

pub const JsonDeserializer = struct {
    /// Standard OMG DDS-JSON RTPS wire encapsulation header (identifier = 0x0005, options = 0x0000).
    pub const ENCAPSULATION_HEADER_JSON: [4]u8 = .{ 0x00, 0x05, 0x00, 0x00 };

    /// Checks whether the payload starts with an OMG DDS-JSON RTPS encapsulation header.
    pub fn hasWireHeader(payload: []const u8) bool {
        if (payload.len < 4) return false;
        return payload[0] == ENCAPSULATION_HEADER_JSON[0] and
            payload[1] == ENCAPSULATION_HEADER_JSON[1];
    }

    /// Strips the OMG DDS-JSON 4-byte encapsulation header if present; otherwise returns payload as-is.
    pub fn stripWireHeader(payload: []const u8) []const u8 {
        if (hasWireHeader(payload)) {
            return payload[4..];
        }
        return payload;
    }

    /// Deserializes a DDS-JSON payload (with or without encapsulation header) into a Parsed(T).
    /// The returned `std.json.Parsed(T)` owns an arena for parsed dynamic types and must be cleaned up via `deinit()`.
    pub fn deserialize(
        comptime T: type,
        allocator: std.mem.Allocator,
        payload: []const u8,
        options: std.json.ParseOptions,
    ) !std.json.Parsed(T) {
        const json_slice = stripWireHeader(payload);
        return std.json.parseFromSlice(T, allocator, json_slice, options);
    }

    /// Deserializes a DDS-JSON payload (with or without encapsulation header) into T.
    /// Dynamic sub-objects are allocated from `allocator` and not tracked individually.
    /// Recommended for arena allocators or POD types with no heap fields.
    pub fn deserializeLeaky(
        comptime T: type,
        allocator: std.mem.Allocator,
        payload: []const u8,
        options: std.json.ParseOptions,
    ) !T {
        const json_slice = stripWireHeader(payload);
        return std.json.parseFromSliceLeaky(T, allocator, json_slice, options);
    }
};
