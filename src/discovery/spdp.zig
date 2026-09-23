//! @file spdp.zig
//! @brief Implements the Simple Participant Discovery Protocol (SPDP) for bootstrapping remote Participant awareness.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const rtps = @import("../root.zig").rtps;

pub const SPDPDiscoveredParticipantData = struct {
    pub const ddz_extensibility = "MUTABLE";

    guid_prefix: rtps.types.GuidPrefix_t,
    metatraffic_unicast_locator: rtps.types.Locator_t,
    filter_expression: []const u8 = "",
    public_key: [32]u8 = std.mem.zeroes([32]u8),
    has_public_key: bool = false,
    user_data: []const u8 = "",
};

pub const DiscoveredTopicData = struct {
    pub const ddz_extensibility = "MUTABLE";

    topic_name: []const u8 = "",
    type_name: []const u8 = "",
    durability_kind: u32 = 0,
    deadline_period_ms: u32 = 0xFFFFFFFF,
    reliability_qos: u32 = 0,
    liveliness_kind: u32 = 0,
    liveliness_lease_duration: u32 = 0,
    destination_order_kind: u32 = 0,
    ownership_kind: u32 = 0,
    topic_data: []const u8 = "",
    type_object_cdr: []const u8 = "",
};
