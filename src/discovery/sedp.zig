//! @file sedp.zig
//! @brief Implements the Simple Endpoint Discovery Protocol (SEDP) for matching remote Readers and Writers.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const rtps = @import("../root.zig").rtps;

/// @brief Discovered writer data structure.
pub const DiscoveredWriterData = struct {
    pub const ddz_extensibility = "MUTABLE";
    endpoint_guid: rtps.types.GUID_t,
    topic_name: []const u8,
    type_name: []const u8,
    reliability_qos: u32,
    durability_kind: u32 = 0,
    deadline_period_ms: u32 = 0,
    destination_order_kind: u32 = 0,
    presentation_access_scope: u32 = 0,
    presentation_coherent_access: bool = false,
    presentation_ordered_access: bool = false,
    ownership_kind: u32 = 0, // 0=shared, 1=exclusive
    ownership_strength: i32 = 0,
    liveliness_kind: u32 = 0,
    liveliness_lease_duration: u32 = 100,
    partition_name: []const u8 = "",
    type_object_cdr: []const u8 = "",
    user_data: []const u8 = "",
    group_data: []const u8 = "",
    topic_data: []const u8 = "",
    representation_mask: u32 = 1,
};

/// @brief Discovered reader data structure.
pub const DiscoveredReaderData = struct {
    pub const ddz_extensibility = "MUTABLE";
    endpoint_guid: rtps.types.GUID_t,
    topic_name: []const u8,
    type_name: []const u8,
    reliability_qos: u32,
    ownership_kind: u32 = 0,
    durability_kind: u32 = 0,
    deadline_period_ms: u32 = 0,
    destination_order_kind: u32 = 0,
    presentation_access_scope: u32 = 0,
    presentation_coherent_access: bool = false,
    presentation_ordered_access: bool = false,
    liveliness_kind: u32 = 0,
    liveliness_lease_duration: u32 = 100,
    partition_name: []const u8 = "",
    type_object_cdr: []const u8 = "",
    user_data: []const u8 = "",
    group_data: []const u8 = "",
    topic_data: []const u8 = "",
    representation_mask: u32 = 1,
};

test "SEDP DiscoveredWriterData Initialization" {
    const writer_data = DiscoveredWriterData{
        .endpoint_guid = std.mem.zeroes(rtps.types.GUID_t),
        .topic_name = "TestTopic",
        .type_name = "TestType",
        .reliability_qos = 1,
    };

    try std.testing.expectEqualStrings("TestTopic", writer_data.topic_name);
    try std.testing.expectEqualStrings("TestType", writer_data.type_name);
    try std.testing.expectEqual(@as(u32, 1), writer_data.reliability_qos);
}

test "SEDP DiscoveredReaderData Initialization" {
    const reader_data = DiscoveredReaderData{
        .endpoint_guid = std.mem.zeroes(rtps.types.GUID_t),
        .topic_name = "TestTopic",
        .type_name = "TestType",
        .reliability_qos = 2,
    };

    try std.testing.expectEqualStrings("TestTopic", reader_data.topic_name);
    try std.testing.expectEqualStrings("TestType", reader_data.type_name);
    try std.testing.expectEqual(@as(u32, 2), reader_data.reliability_qos);
}

test "SEDP DiscoveredWriterData roundtrip with type_object_cdr" {
    const Serializer = @import("../cdr/serializer.zig").Serializer;
    const Deserializer = @import("../cdr/deserializer.zig").Deserializer;

    const writer_data = DiscoveredWriterData{
        .endpoint_guid = std.mem.zeroes(rtps.types.GUID_t),
        .topic_name = "Square",
        .type_name = "ShapeType",
        .reliability_qos = 1,
        .type_object_cdr = "12345678",
    };

    var buf: [1024]u8 = undefined;
    var ser = Serializer.init(&buf, .Little);
    try ser.serialize(writer_data);

    var des = Deserializer.init(buf[0..ser.pos], .Little);
    const parsed = try des.deserialize(DiscoveredWriterData);

    try std.testing.expectEqualStrings("Square", parsed.topic_name);
    try std.testing.expectEqualStrings("ShapeType", parsed.type_name);
    try std.testing.expectEqualStrings("12345678", parsed.type_object_cdr);
}
