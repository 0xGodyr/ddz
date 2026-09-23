//! @file message.zig
//! @brief Defines the core RTPS wire protocol header and message structures.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const rtps_types = @import("types.zig");

/// @brief Header structure.
pub const Header = extern struct {
    protocol: [4]u8,
    version: rtps_types.ProtocolVersion_t,
    vendor_id: rtps_types.VendorId_t,
    guid_prefix: rtps_types.GuidPrefix_t,

    pub const rtps_magic = [4]u8{ 'R', 'T', 'P', 'S' };

    pub const ParseError = error{
        BufferTooSmall,
        InvalidProtocol,
    };

    /// @brief Parse.
    pub fn parse(buffer: []const u8) ParseError!Header {
        if (buffer.len < @sizeOf(Header)) {
            return error.BufferTooSmall;
        }

        var header: Header = undefined;
        @memcpy(std.mem.asBytes(&header), buffer[0..@sizeOf(Header)]);

        if (!std.mem.eql(u8, &header.protocol, &rtps_magic)) {
            return error.InvalidProtocol;
        }

        return header;
    }

    /// @brief Serialize.
    pub fn serialize(self: *const Header, buffer: []u8) !usize {
        if (buffer.len < @sizeOf(Header)) {
            return error.BufferTooSmall;
        }

        @memcpy(buffer[0..@sizeOf(Header)], std.mem.asBytes(self));
        return @sizeOf(Header);
    }
};

test "RTPS Header Parse & Serialize" {
    var header = Header{
        .protocol = Header.rtps_magic,
        .version = rtps_types.ProtocolVersion_t.current,
        .vendor_id = rtps_types.vendor_ddz,
        .guid_prefix = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 },
    };

    var buf: [32]u8 = undefined;
    const len = try header.serialize(&buf);
    try std.testing.expectEqual(@sizeOf(Header), len);

    const parsed = try Header.parse(buf[0..len]);
    try std.testing.expectEqual(header.version.major, parsed.version.major);
    try std.testing.expectEqual(header.vendor_id[0], parsed.vendor_id[0]);
    try std.testing.expectEqualSlices(u8, &header.guid_prefix, &parsed.guid_prefix);
}

test "RTPS Header - Truncated" {
    const buffer = [_]u8{ 'R', 'T', 'P', 'S' };
    const result = Header.parse(&buffer);
    try std.testing.expectError(error.BufferTooSmall, result);
}

test "RTPS Header - Invalid Protocol" {
    var buffer: [20]u8 = undefined;
    @memset(&buffer, 0);
    buffer[0] = 'H';
    buffer[1] = 'T';
    buffer[2] = 'T';
    buffer[3] = 'P';

    const result = Header.parse(&buffer);
    try std.testing.expectError(error.InvalidProtocol, result);
}
