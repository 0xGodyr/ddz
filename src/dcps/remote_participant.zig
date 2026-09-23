//! @file remote_participant.zig
//! @brief State tracking and endpoint routing for discovered remote DomainParticipants.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const rtps = @import("../root.zig").rtps;

/// @brief Remote participant structure.
pub const RemoteParticipant = struct {
    guid_prefix: rtps.types.GuidPrefix_t,
    metatraffic_unicast_locator: ?rtps.types.Locator_t = null,
    metatraffic_multicast_locator: ?rtps.types.Locator_t = null,
    last_seen_msec: i64 = 0,
    filter_expression: ?[]const u8 = null,
    public_key: ?[32]u8 = null,

    // Other fields that would come from the SPDP ParameterList
    // (e.g., ParticipantName, Default QoS, UserData)
};
