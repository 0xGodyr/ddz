//! @file status.zig
//! @brief Defines DDS communication statuses (e.g., Liveliness Lost, Deadline Missed, Publication Matched).
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");

/// @brief Status kinds as defined by DDS.
pub const StatusKind = enum(u32) {
    inconsistent_topic = 1 << 0,
    offered_deadline_missed = 1 << 1,
    requested_deadline_missed = 1 << 2,
    offered_incompatible_qos = 1 << 5,
    requested_incompatible_qos = 1 << 6,
    sample_lost = 1 << 7,
    sample_rejected = 1 << 8,
    data_on_readers = 1 << 9,
    data_available = 1 << 10,
    liveliness_lost = 1 << 11,
    liveliness_changed = 1 << 12,
    publication_matched = 1 << 13,
    subscription_matched = 1 << 14,
};

/// @brief Sample rejected reason.
pub const SampleRejectedStatusKind = enum {
    rejected_by_instances_limit,
    rejected_by_samples_limit,
    rejected_by_samples_per_instance_limit,
};

/// @brief Status payload for Sample Rejected.
pub const SampleRejectedStatus = struct {
    total_count: u32 = 0,
    total_count_change: i32 = 0,
    last_reason: SampleRejectedStatusKind = .rejected_by_samples_limit,
    last_instance_handle: [16]u8 = std.mem.zeroes([16]u8),
};

/// @brief Status payload for Deadline Missed.
pub const DeadlineMissedStatus = struct {
    total_count: u32 = 0,
    total_count_change: i32 = 0,
    last_instance_handle: [16]u8 = std.mem.zeroes([16]u8),
};

/// @brief Status payload for Liveliness Changed.
pub const LivelinessChangedStatus = struct {
    alive_count: u32 = 0,
    not_alive_count: u32 = 0,
    alive_count_change: i32 = 0,
    not_alive_count_change: i32 = 0,
    last_publication_handle: [16]u8 = std.mem.zeroes([16]u8),
};

/// @brief Status payload for Publication/Subscription Matched.
pub const MatchedStatus = struct {
    total_count: u32 = 0,
    total_count_change: i32 = 0,
    current_count: u32 = 0,
    current_count_change: i32 = 0,
    last_publication_handle: [16]u8 = std.mem.zeroes([16]u8),
};

/// @brief Status payload for Inconsistent Topic.
/// @brief QosPolicyId_t definition.
pub const QosPolicyId_t = u32;

pub const QOS_POLICY_ID_DURABILITY: QosPolicyId_t = 1;
pub const QOS_POLICY_ID_DEADLINE: QosPolicyId_t = 2;
pub const QOS_POLICY_ID_LATENCY_BUDGET: QosPolicyId_t = 3;
pub const QOS_POLICY_ID_LIVELINESS: QosPolicyId_t = 4;
pub const QOS_POLICY_ID_RELIABILITY: QosPolicyId_t = 5;
pub const QOS_POLICY_ID_DESTINATION_ORDER: QosPolicyId_t = 6;
pub const QOS_POLICY_ID_HISTORY: QosPolicyId_t = 7;
pub const QOS_POLICY_ID_RESOURCE_LIMITS: QosPolicyId_t = 8;
pub const QOS_POLICY_ID_USER_DATA: QosPolicyId_t = 9;
pub const QOS_POLICY_ID_OWNERSHIP: QosPolicyId_t = 10;
pub const QOS_POLICY_ID_PRESENTATION: QosPolicyId_t = 11;
pub const QOS_POLICY_ID_DATA_REPRESENTATION: QosPolicyId_t = 23;

/// @brief Status payload for Incompatible QoS.
pub const IncompatibleQosStatus = struct {
    total_count: u32 = 0,
    total_count_change: i32 = 0,
    last_policy_id: QosPolicyId_t = 0,
};

/// @brief Status payload for Inconsistent Topic.
pub const InconsistentTopicStatus = struct {
    total_count: u32 = 0,
    total_count_change: i32 = 0,
};

/// @brief Status payload for Liveliness Lost.
pub const LivelinessLostStatus = struct {
    total_count: u32 = 0,
    total_count_change: i32 = 0,
};
