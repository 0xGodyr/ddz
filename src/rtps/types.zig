//! @file types.zig
//! @brief Fundamental RTPS types (GUID, Locator, SequenceNumber, EntityId).
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");

/// Uniquely identifies a DomainParticipant within a DDS Domain.
pub const GuidPrefix_t = [12]u8;

/// @brief Entity kind structure.
pub const EntityKind = enum(u8) {
    user_unknown = 0x00,
    built_in_unknown = 0xc0,
    user_participant = 0x01,
    built_in_participant = 0xc1,
    user_writer_with_key = 0x02,
    built_in_writer_with_key = 0xc2,
    user_writer_no_key = 0x03,
    built_in_writer_no_key = 0xc3,
    user_reader_with_key = 0x04,
    built_in_reader_with_key = 0xc7,
    user_reader_no_key = 0x07,
    built_in_reader_no_key = 0xc4,
    _,
};

/// Uniquely identifies an Endpoint within a DomainParticipant.
pub const EntityId_t = struct {
    entity_key: [3]u8,
    entity_kind: u8,

    pub const unknown = EntityId_t{ .entity_key = .{ 0, 0, 0 }, .entity_kind = @backingInt(EntityKind.user_unknown) };
    pub const participant = EntityId_t{ .entity_key = .{ 0, 0, 0x01 }, .entity_kind = @backingInt(EntityKind.built_in_participant) };
    pub const spdp_sub_writer = EntityId_t{ .entity_key = .{ 0, 0, 0x01 }, .entity_kind = 0xc2 };
    pub const spdp_sub_reader = EntityId_t{ .entity_key = .{ 0, 0, 0x01 }, .entity_kind = 0xc7 };
    pub const sedp_pub_writer = EntityId_t{ .entity_key = .{ 0, 0, 0x03 }, .entity_kind = 0xc2 };
    pub const sedp_pub_reader = EntityId_t{ .entity_key = .{ 0, 0, 0x03 }, .entity_kind = 0xc7 };
    pub const sedp_sub_writer = EntityId_t{ .entity_key = .{ 0, 0, 0x04 }, .entity_kind = 0xc2 };
    pub const sedp_sub_reader = EntityId_t{ .entity_key = .{ 0, 0, 0x04 }, .entity_kind = 0xc7 };
    pub const type_lookup_req_writer = EntityId_t{ .entity_key = .{ 0, 0, 0x05 }, .entity_kind = 0xc2 };
    pub const type_lookup_req_reader = EntityId_t{ .entity_key = .{ 0, 0, 0x05 }, .entity_kind = 0xc7 };
    pub const type_lookup_rep_writer = EntityId_t{ .entity_key = .{ 0, 0, 0x06 }, .entity_kind = 0xc2 };
    pub const type_lookup_rep_reader = EntityId_t{ .entity_key = .{ 0, 0, 0x06 }, .entity_kind = 0xc7 };
};

/// Globally unique identifier for an RTPS entity.
pub const GUID_t = struct {
    prefix: GuidPrefix_t,
    entity_id: EntityId_t,

    pub const unknown = GUID_t{
        .prefix = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .entity_id = EntityId_t.unknown,
    };
};

/// Sequence number for RTPS messages.
/// Spec defines it as a 64-bit signed integer, transmitted as high (32-bit) and low (32-bit) parts.
pub const SequenceNumber_t = struct {
    high: i32,
    low: u32,

    pub const unknown = SequenceNumber_t{ .high = -1, .low = 0 };

    /// Helper to convert to a standard Zig i64 if needed for arithmetic.
    pub fn toInt(self: SequenceNumber_t) i64 {
        return (@as(i64, self.high) << 32) | @as(i64, self.low);
    }
};

/// @brief Sample Identity for RPC over DDS.
pub const SampleIdentity_t = struct {
    writer_guid: GUID_t,
    sequence_number: SequenceNumber_t,
};

/// Represents an IP address and port for network communication.
pub const Locator_t = struct {
    kind: i32,
    port: u32,
    address: [16]u8,

    pub const kind_invalid: i32 = -1;
    pub const kind_udp_v4: i32 = 1;
    pub const kind_udp_v6: i32 = 2;

    pub const invalid = Locator_t{
        .kind = kind_invalid,
        .port = 0,
        .address = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    };
};

/// RTPS Time representation.
pub const Time_t = struct {
    seconds: i32,
    fraction: u32,

    pub const invalid = Time_t{ .seconds = -1, .fraction = 0xffffffff };
};

/// RTPS Protocol Version.
pub const ProtocolVersion_t = extern struct {
    major: u8,
    minor: u8,

    pub const v2_1 = ProtocolVersion_t{ .major = 2, .minor = 1 };
    pub const v2_4 = ProtocolVersion_t{ .major = 2, .minor = 4 };
    pub const v2_5 = ProtocolVersion_t{ .major = 2, .minor = 5 };

    pub const current = v2_5;
};

/// Vendor ID for the DDS implementation.
pub const VendorId_t = [2]u8;
pub const vendor_unknown: VendorId_t = .{ 0, 0 };
pub const vendor_ddz: VendorId_t = .{ 0x99, 0x99 }; // Custom vendor ID for this library

test "GUID initialization" {
    const guid = GUID_t.unknown;
    try std.testing.expectEqual(guid.entity_id.entity_kind, @backingInt(EntityKind.user_unknown));
}

pub const Count_t = i32;

/// @brief Sequence number set structure.
pub const SequenceNumberSet = struct {
    base: SequenceNumber_t,
    num_bits: u32,
    bitmap: [8]u32 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
};
pub const InstanceHandle_t = [16]u8;

/// @brief Convert a GUID to an InstanceHandle.
pub fn guidToInstanceHandle(guid: GUID_t) InstanceHandle_t {
    var handle: InstanceHandle_t = undefined;
    @memcpy(handle[0..12], &guid.prefix);
    @memcpy(handle[12..15], &guid.entity_id.entity_key);
    handle[15] = guid.entity_id.entity_kind;
    return handle;
}

/// @brief Convert an InstanceHandle to a GUID.
pub fn instanceHandleToGuid(handle: InstanceHandle_t) GUID_t {
    var guid: GUID_t = undefined;
    @memcpy(&guid.prefix, handle[0..12]);
    @memcpy(&guid.entity_id.entity_key, handle[12..15]);
    guid.entity_id.entity_kind = handle[15];
    return guid;
}
