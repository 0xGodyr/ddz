//! @file qos.zig
//! @brief Defines all 22 OMG DDS Quality of Service (QoS) policies and their configuration structs.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const Status = @import("status.zig");
const QosPolicyId_t = Status.QosPolicyId_t;

/// @brief Reliability kind structure.
pub const ReliabilityKind = enum {
    best_effort,
    reliable,
};

/// @brief Reliability qos structure.
pub const ReliabilityQosPolicy = struct {
    kind: ReliabilityKind = .best_effort,
    max_blocking_time_ms: u32 = 100,
};

/// @brief Durability kind structure.
pub const DurabilityKind = enum {
    @"volatile",
    transient_local,
    transient,
    persistent,
};

/// @brief History kind structure.
pub const HistoryKind = enum {
    keep_last,
    keep_all,
};

/// @brief History qos policy structure.
pub const HistoryQosPolicy = struct {
    kind: HistoryKind = .keep_last,
    depth: i32 = 1,
};

/// @brief Resource limits qos policy structure.
pub const ResourceLimitsQosPolicy = struct {
    max_samples: i32 = -1, // -1 means LENGTH_UNLIMITED
    max_instances: i32 = -1,
    max_samples_per_instance: i32 = -1,
};

/// @brief Liveliness kind structure.
pub const LivelinessKind = enum {
    automatic,
    manual_by_participant,
    manual_by_topic,
};

/// @brief Liveliness qos policy structure.
pub const LivelinessQosPolicy = struct {
    kind: LivelinessKind = .automatic,
    lease_duration: u32 = 100, // seconds, typically std::u32::MAX for infinite but we use 100s default for testing
};

/// @brief Batch qos policy structure.
pub const BatchQosPolicy = struct {
    enable: bool = false,
    max_data_bytes: u32 = 1024,
    max_flush_delay_ms: u32 = 100,
};

/// @brief Shm transport qos policy structure.
pub const ShmTransportQosPolicy = struct {
    enable: bool = false,
    segment_size: u32 = 1048576, // 1MB default
};

/// @brief Deadline qos policy structure.
pub const DeadlineQosPolicy = struct {
    period_ms: u32 = 0xFFFFFFFF, // Infinite default
};

/// @brief Lifespan qos policy structure.
pub const LifespanQosPolicy = struct {
    duration_ms: u32 = 0xFFFFFFFF, // Infinite default
};

/// @brief Destination order kind structure.
pub const DestinationOrderKind = enum {
    by_reception_timestamp,
    by_source_timestamp,
};

/// @brief Destination order qos policy structure.
pub const DestinationOrderQosPolicy = struct {
    kind: DestinationOrderKind = .by_reception_timestamp,
};

/// @brief Writer data lifecycle qos policy structure.
pub const WriterDataLifecycleQosPolicy = struct {
    autodispose_unregistered_instances: bool = true,
};

/// @brief Reader data lifecycle qos policy structure.
pub const ReaderDataLifecycleQosPolicy = struct {
    autopurge_nowriter_samples_delay_ms: u64 = 0xFFFFFFFF,
    autopurge_disposed_samples_delay_ms: u64 = 0xFFFFFFFF,
};

/// @brief Time based filter qos policy structure.
pub const TimeBasedFilterQosPolicy = struct {
    minimum_separation_ms: u32 = 0,
};

/// @brief Ownership kind structure.
pub const OwnershipKind = enum {
    shared,
    exclusive,
};

/// @brief Ownership qos policy structure.
pub const OwnershipQosPolicy = struct {
    kind: OwnershipKind = .shared,
};

/// @brief Ownership strength qos policy structure.
pub const OwnershipStrengthQosPolicy = struct {
    value: i32 = 0,
};

/// @brief Writer qos structure.
/// @brief User data qos policy structure.
pub const UserDataQosPolicy = struct {
    value: [256]u8 = std.mem.zeroes([256]u8),
    len: usize = 0,
};

/// @brief Group data qos policy structure.
pub const GroupDataQosPolicy = struct {
    value: [256]u8 = std.mem.zeroes([256]u8),
    len: usize = 0,
};

/// @brief Topic data qos policy structure.
pub const TopicDataQosPolicy = struct {
    value: [256]u8 = std.mem.zeroes([256]u8),
    len: usize = 0,
};

/// @brief Latency budget qos policy structure.
pub const LatencyBudgetQosPolicy = struct {
    duration_ms: u64 = 0,
};

/// @brief Data representation kind defined by XTypes 1.3 / OMG DDS-JSON.
pub const DataRepresentationId = enum(i16) {
    xcdr = 0,
    xml = 1,
    xcdr2 = 2,
    json = 3,
};

/// @brief Data representation QoS policy.
pub const DataRepresentationQosPolicy = struct {
    value: [4]DataRepresentationId = .{ .xcdr, .xcdr, .xcdr, .xcdr },
    len: usize = 1,

    pub fn init(representations: []const DataRepresentationId) DataRepresentationQosPolicy {
        var policy = DataRepresentationQosPolicy{ .len = @min(representations.len, 4) };
        for (representations[0..policy.len], 0..) |repr, i| {
            policy.value[i] = repr;
        }
        return policy;
    }

    pub fn contains(self: *const DataRepresentationQosPolicy, id: DataRepresentationId) bool {
        for (self.value[0..self.len]) |v| {
            if (v == id) return true;
        }
        return false;
    }

    pub fn hasJson(self: *const DataRepresentationQosPolicy) bool {
        return self.contains(.json);
    }

    pub fn hasXcdr(self: *const DataRepresentationQosPolicy) bool {
        return self.contains(.xcdr) or self.contains(.xcdr2);
    }

    pub fn toMask(self: *const DataRepresentationQosPolicy) u32 {
        var mask: u32 = 0;
        for (self.value[0..self.len]) |v| {
            const shift: u5 = @intCast(@backingInt(v));
            mask |= @as(u32, 1) << shift;
        }
        return mask;
    }
};

/// @brief Transport priority qos policy structure.
pub const TransportPriorityQosPolicy = struct {
    value: i32 = 0,
};

/// @brief Durability service qos structure.
pub const DurabilityServiceQosPolicy = struct {
    service_cleanup_delay_ms: u32 = 0,
    history_kind: HistoryKind = .keep_last,
    history_depth: u32 = 1,
    max_samples: i32 = -1,
    max_instances: i32 = -1,
    max_samples_per_instance: i32 = -1,
};

pub const WriterQos = struct {
    durability_service: DurabilityServiceQosPolicy = .{},
    entity_factory: EntityFactoryQosPolicy = .{},
    reliability: ReliabilityQosPolicy = .{},
    durability: DurabilityKind = .@"volatile",
    history: HistoryQosPolicy = .{},
    resource_limits: ResourceLimitsQosPolicy = .{},
    liveliness: LivelinessQosPolicy = .{},
    deadline: DeadlineQosPolicy = .{},
    lifespan: LifespanQosPolicy = .{},
    ownership: OwnershipQosPolicy = .{},
    ownership_strength: OwnershipStrengthQosPolicy = .{},
    batch: BatchQosPolicy = .{},
    shm: ShmTransportQosPolicy = .{},
    destination_order: DestinationOrderQosPolicy = .{},
    writer_data_lifecycle: WriterDataLifecycleQosPolicy = .{},
    security_key: ?[32]u8 = null,
    user_data: UserDataQosPolicy = .{},
    latency_budget: LatencyBudgetQosPolicy = .{},
    transport_priority: TransportPriorityQosPolicy = .{},
    representation: DataRepresentationQosPolicy = .{},
};

/// @brief Reader qos structure.
pub const ReaderQos = struct {
    entity_factory: EntityFactoryQosPolicy = .{},
    reliability: ReliabilityQosPolicy = .{},
    durability: DurabilityKind = .@"volatile",
    history: HistoryQosPolicy = .{},
    resource_limits: ResourceLimitsQosPolicy = .{},
    liveliness: LivelinessQosPolicy = .{},
    deadline: DeadlineQosPolicy = .{},
    lifespan: LifespanQosPolicy = .{},
    time_based_filter: TimeBasedFilterQosPolicy = .{},
    ownership: OwnershipQosPolicy = .{},
    destination_order: DestinationOrderQosPolicy = .{},
    reader_data_lifecycle: ReaderDataLifecycleQosPolicy = .{},
    security_key: ?[32]u8 = null,
    user_data: UserDataQosPolicy = .{},
    latency_budget: LatencyBudgetQosPolicy = .{},
    representation: DataRepresentationQosPolicy = .{},
};

/// @brief Presentation access scope kind structure.
pub const PresentationAccessScopeKind = enum {
    instance,
    topic,
    group,
};

/// @brief Presentation qos policy structure.
pub const PresentationQosPolicy = struct {
    access_scope: PresentationAccessScopeKind = .instance,
    coherent_access: bool = false,
    ordered_access: bool = false,
};

/// @brief Partition qos policy structure.
pub const PartitionQosPolicy = struct {
    name: []const u8 = "",
};

/// @brief Publisher qos structure.
/// @brief Entity factory qos structure.
pub const EntityFactoryQosPolicy = struct {
    autoenable_created_entities: bool = true,
};

/// @brief Domain participant factory qos structure.
pub const DomainParticipantFactoryQos = struct {
    entity_factory: EntityFactoryQosPolicy = .{},
};

/// @brief Domain participant qos structure.
pub const DomainParticipantQos = struct {
    user_data: UserDataQosPolicy = .{},
    entity_factory: EntityFactoryQosPolicy = .{},
};

/// @brief Topic qos structure.
pub const TopicQos = struct {
    durability_service: DurabilityServiceQosPolicy = .{},
    topic_data: TopicDataQosPolicy = .{},
    durability: DurabilityKind = .@"volatile",
    deadline: DeadlineQosPolicy = .{},
    latency_budget: LatencyBudgetQosPolicy = .{},
    liveliness: LivelinessQosPolicy = .{},
    reliability: ReliabilityQosPolicy = .{},
    destination_order: DestinationOrderQosPolicy = .{},
    history: HistoryQosPolicy = .{},
    resource_limits: ResourceLimitsQosPolicy = .{},
    transport_priority: TransportPriorityQosPolicy = .{},
    lifespan: LifespanQosPolicy = .{},
    ownership: OwnershipQosPolicy = .{},
    representation: DataRepresentationQosPolicy = .{},
};

/// @brief Publisher qos structure.
pub const PublisherQos = struct {
    entity_factory: EntityFactoryQosPolicy = .{},
    presentation: PresentationQosPolicy = .{},
    partition: PartitionQosPolicy = .{},
    group_data: GroupDataQosPolicy = .{},
};

/// @brief Subscriber qos structure.
pub const SubscriberQos = struct {
    entity_factory: EntityFactoryQosPolicy = .{},
    presentation: PresentationQosPolicy = .{},
    partition: PartitionQosPolicy = .{},
    group_data: GroupDataQosPolicy = .{},
};

/// @brief Simple Glob matcher for partition names (e.g., "Vehicle/*").
pub fn matchPartition(pattern: []const u8, name: []const u8) bool {
    // If no partitions are defined on both sides, they match.
    // In DDS, empty partition string matches the default empty partition.
    if (pattern.len == 0 and name.len == 0) return true;

    // Split comma separated list for both pattern and name
    var p_iter = std.mem.splitScalar(u8, pattern, ',');
    while (p_iter.next()) |p| {
        var n_iter = std.mem.splitScalar(u8, name, ',');
        while (n_iter.next()) |n| {
            if (globMatch(p, n) or globMatch(n, p)) return true;
        }
    }
    return false;
}

fn globMatch(pattern: []const u8, text: []const u8) bool {
    var p_idx: usize = 0;
    var t_idx: usize = 0;
    var star_idx: ?usize = null;
    var match_idx: usize = 0;

    while (t_idx < text.len) {
        if (p_idx < pattern.len and (pattern[p_idx] == '?' or pattern[p_idx] == text[t_idx])) {
            p_idx += 1;
            t_idx += 1;
        } else if (p_idx < pattern.len and pattern[p_idx] == '*') {
            star_idx = p_idx;
            match_idx = t_idx;
            p_idx += 1;
        } else if (star_idx != null) {
            p_idx = star_idx.? + 1;
            match_idx += 1;
            t_idx = match_idx;
        } else {
            return false;
        }
    }

    while (p_idx < pattern.len and pattern[p_idx] == '*') {
        p_idx += 1;
    }

    return p_idx == pattern.len;
}

/// @brief Check QoS Compatibility between a DiscoveredWriterData and a ReaderQos.
/// Returns the first incompatible QosPolicyId_t if incompatible, else null.
pub fn checkCompatibility(wq: anytype, rq: anytype) ?QosPolicyId_t {
    // 1. Reliability (Offered >= Requested)
    const w_rel = if (@hasField(@TypeOf(wq), "reliability_qos")) wq.reliability_qos else @backingInt(wq.reliability.kind);
    const r_rel = if (@hasField(@TypeOf(rq), "reliability_qos")) rq.reliability_qos else @backingInt(rq.reliability.kind);
    if (w_rel < r_rel) return Status.QOS_POLICY_ID_RELIABILITY;

    // 2. Durability (Offered >= Requested)
    const w_dur = if (@hasField(@TypeOf(wq), "durability_kind")) wq.durability_kind else @backingInt(wq.durability);
    const r_dur = if (@hasField(@TypeOf(rq), "durability_kind")) rq.durability_kind else @backingInt(rq.durability);
    if (w_dur < r_dur) return Status.QOS_POLICY_ID_DURABILITY;

    // 3. Deadline (Offered <= Requested)
    const w_dead = if (@hasField(@TypeOf(wq), "deadline_period_ms")) wq.deadline_period_ms else wq.deadline.period_ms;
    const r_dead = if (@hasField(@TypeOf(rq), "deadline_period_ms")) rq.deadline_period_ms else rq.deadline.period_ms;
    if (r_dead > 0 and (w_dead == 0 or w_dead > r_dead)) return Status.QOS_POLICY_ID_DEADLINE;

    // 4. Liveliness (Offered >= Requested kind, Offered <= Requested duration)
    const w_liv_k = if (@hasField(@TypeOf(wq), "liveliness_kind")) wq.liveliness_kind else @backingInt(wq.liveliness.kind);
    const r_liv_k = if (@hasField(@TypeOf(rq), "liveliness_kind")) rq.liveliness_kind else @backingInt(rq.liveliness.kind);
    if (w_liv_k < r_liv_k) return Status.QOS_POLICY_ID_LIVELINESS;

    const w_liv_d = if (@hasField(@TypeOf(wq), "liveliness_lease_duration")) wq.liveliness_lease_duration else wq.liveliness.lease_duration;
    const r_liv_d = if (@hasField(@TypeOf(rq), "liveliness_lease_duration")) rq.liveliness_lease_duration else rq.liveliness.lease_duration;
    if (r_liv_d > 0 and (w_liv_d == 0 or w_liv_d > r_liv_d)) return Status.QOS_POLICY_ID_LIVELINESS;

    // 5. Ownership (Offered == Requested)
    const w_own = if (@hasField(@TypeOf(wq), "ownership_kind")) wq.ownership_kind else @backingInt(wq.ownership.kind);
    const r_own = if (@hasField(@TypeOf(rq), "ownership_kind")) rq.ownership_kind else @backingInt(rq.ownership.kind);
    if (w_own != r_own) return Status.QOS_POLICY_ID_OWNERSHIP;

    // 6. Destination Order (Offered >= Requested)
    const w_ord = if (@hasField(@TypeOf(wq), "destination_order_kind")) wq.destination_order_kind else @backingInt(wq.destination_order.kind);
    const r_ord = if (@hasField(@TypeOf(rq), "destination_order_kind")) rq.destination_order_kind else @backingInt(rq.destination_order.kind);
    if (w_ord < r_ord) return Status.QOS_POLICY_ID_DESTINATION_ORDER;

    // 7. Presentation
    const w_pres_scope = if (@hasField(@TypeOf(wq), "presentation_access_scope")) wq.presentation_access_scope else 0;
    const r_pres_scope = if (@hasField(@TypeOf(rq), "presentation_access_scope")) rq.presentation_access_scope else 0;
    const w_pres_coh = if (@hasField(@TypeOf(wq), "presentation_coherent_access")) wq.presentation_coherent_access else false;
    const r_pres_coh = if (@hasField(@TypeOf(rq), "presentation_coherent_access")) rq.presentation_coherent_access else false;
    const w_pres_ord = if (@hasField(@TypeOf(wq), "presentation_ordered_access")) wq.presentation_ordered_access else false;
    const r_pres_ord = if (@hasField(@TypeOf(rq), "presentation_ordered_access")) rq.presentation_ordered_access else false;

    if (w_pres_scope < r_pres_scope) return Status.QOS_POLICY_ID_PRESENTATION;
    if (r_pres_coh and !w_pres_coh) return Status.QOS_POLICY_ID_PRESENTATION;
    if (r_pres_ord and !w_pres_ord) return Status.QOS_POLICY_ID_PRESENTATION;

    // 8. Data Representation (Offered intersection Requested != empty)
    const w_repr_mask: ?u32 = if (@hasField(@TypeOf(wq), "representation"))
        wq.representation.toMask()
    else if (@hasField(@TypeOf(wq), "representation_mask"))
        wq.representation_mask
    else
        null;

    const r_repr_mask: ?u32 = if (@hasField(@TypeOf(rq), "representation"))
        rq.representation.toMask()
    else if (@hasField(@TypeOf(rq), "representation_mask"))
        rq.representation_mask
    else
        null;

    if (w_repr_mask != null and r_repr_mask != null) {
        if ((w_repr_mask.? & r_repr_mask.?) == 0) {
            return Status.QOS_POLICY_ID_DATA_REPRESENTATION;
        }
    }

    return null;
}

test "Qos - matchPartition exact and wildcards" {
    // Exact match
    try std.testing.expect(matchPartition("Sensors/Temp", "Sensors/Temp"));
    try std.testing.expect(!matchPartition("Sensors/Temp", "Sensors/Pressure"));

    // Wildcard matches
    try std.testing.expect(matchPartition("Sensors/*", "Sensors/Temp"));
    try std.testing.expect(matchPartition("Sensors/*", "Sensors/Pressure"));
    try std.testing.expect(matchPartition("*", "AnyPartition"));
    try std.testing.expect(matchPartition("*/Temp", "Sensors/Temp"));

    // Empty partition matches empty partition
    try std.testing.expect(matchPartition("", ""));
    try std.testing.expect(!matchPartition("", "Sensors"));
    try std.testing.expect(!matchPartition("Sensors", ""));
}

test "Qos - checkCompatibility reliability and durability" {
    var writer_qos = WriterQos{};
    var reader_qos = ReaderQos{};

    // 1. Both default (Best Effort, Volatile) -> compatible
    try std.testing.expectEqual(@as(?QosPolicyId_t, null), checkCompatibility(writer_qos, reader_qos));

    // 2. Reliable writer vs BestEffort reader -> compatible (Offered >= Requested)
    writer_qos.reliability.kind = .reliable;
    reader_qos.reliability.kind = .best_effort;
    try std.testing.expectEqual(@as(?QosPolicyId_t, null), checkCompatibility(writer_qos, reader_qos));

    // 3. BestEffort writer vs Reliable reader -> incompatible
    writer_qos.reliability.kind = .best_effort;
    reader_qos.reliability.kind = .reliable;
    try std.testing.expectEqual(@as(?QosPolicyId_t, Status.QOS_POLICY_ID_RELIABILITY), checkCompatibility(writer_qos, reader_qos));

    // Reset reliability
    writer_qos.reliability.kind = .reliable;

    // 4. Durability incompatibility: Volatile writer vs TransientLocal reader
    writer_qos.durability = .@"volatile";
    reader_qos.durability = .transient_local;
    try std.testing.expectEqual(@as(?QosPolicyId_t, Status.QOS_POLICY_ID_DURABILITY), checkCompatibility(writer_qos, reader_qos));

    // Durability compatible: TransientLocal writer vs Volatile reader
    writer_qos.durability = .transient_local;
    reader_qos.durability = .@"volatile";
    try std.testing.expectEqual(@as(?QosPolicyId_t, null), checkCompatibility(writer_qos, reader_qos));
}

test "Qos - checkCompatibility deadline and ownership" {
    var writer_qos = WriterQos{};
    var reader_qos = ReaderQos{};

    // Deadline: Writer 100ms vs Reader 200ms -> compatible (offered period <= requested period)
    writer_qos.deadline.period_ms = 100;
    reader_qos.deadline.period_ms = 200;
    try std.testing.expectEqual(@as(?QosPolicyId_t, null), checkCompatibility(writer_qos, reader_qos));

    // Deadline: Writer 500ms vs Reader 200ms -> incompatible
    writer_qos.deadline.period_ms = 500;
    try std.testing.expectEqual(@as(?QosPolicyId_t, Status.QOS_POLICY_ID_DEADLINE), checkCompatibility(writer_qos, reader_qos));

    // Reset deadline
    writer_qos.deadline.period_ms = 100;
    reader_qos.deadline.period_ms = 100;

    // Ownership: Exclusive writer vs Shared reader -> incompatible (must match exactly)
    writer_qos.ownership.kind = .exclusive;
    reader_qos.ownership.kind = .shared;
    try std.testing.expectEqual(@as(?QosPolicyId_t, Status.QOS_POLICY_ID_OWNERSHIP), checkCompatibility(writer_qos, reader_qos));

    // Ownership: Exclusive writer vs Exclusive reader -> compatible
    reader_qos.ownership.kind = .exclusive;
    try std.testing.expectEqual(@as(?QosPolicyId_t, null), checkCompatibility(writer_qos, reader_qos));
}

test "Qos - DataRepresentationQosPolicy and checkCompatibility" {
    // Default writer & reader offer/request XCDR -> compatible
    var writer_qos = WriterQos{};
    var reader_qos = ReaderQos{};
    try std.testing.expect(writer_qos.representation.hasXcdr());
    try std.testing.expect(!writer_qos.representation.hasJson());
    try std.testing.expectEqual(@as(?QosPolicyId_t, null), checkCompatibility(writer_qos, reader_qos));

    // Writer offers JSON only, Reader requests XCDR only -> incompatible
    writer_qos.representation = DataRepresentationQosPolicy.init(&.{.json});
    reader_qos.representation = DataRepresentationQosPolicy.init(&.{.xcdr});
    try std.testing.expect(writer_qos.representation.hasJson());
    try std.testing.expect(!writer_qos.representation.hasXcdr());
    try std.testing.expectEqual(@as(?QosPolicyId_t, Status.QOS_POLICY_ID_DATA_REPRESENTATION), checkCompatibility(writer_qos, reader_qos));

    // Writer offers JSON, Reader requests JSON -> compatible
    reader_qos.representation = DataRepresentationQosPolicy.init(&.{.json});
    try std.testing.expectEqual(@as(?QosPolicyId_t, null), checkCompatibility(writer_qos, reader_qos));

    // Writer offers both XCDR and JSON, Reader requests JSON -> compatible
    writer_qos.representation = DataRepresentationQosPolicy.init(&.{ .xcdr, .json });
    try std.testing.expect(writer_qos.representation.hasXcdr());
    try std.testing.expect(writer_qos.representation.hasJson());
    try std.testing.expectEqual(@as(?QosPolicyId_t, null), checkCompatibility(writer_qos, reader_qos));

    // Writer offers XCDR only, Reader requests XCDR and JSON -> compatible
    writer_qos.representation = DataRepresentationQosPolicy.init(&.{.xcdr});
    reader_qos.representation = DataRepresentationQosPolicy.init(&.{ .xcdr, .json });
    try std.testing.expectEqual(@as(?QosPolicyId_t, null), checkCompatibility(writer_qos, reader_qos));

    // Writer offers XML only, Reader requests JSON only -> incompatible
    writer_qos.representation = DataRepresentationQosPolicy.init(&.{.xml});
    reader_qos.representation = DataRepresentationQosPolicy.init(&.{.json});
    try std.testing.expectEqual(@as(?QosPolicyId_t, Status.QOS_POLICY_ID_DATA_REPRESENTATION), checkCompatibility(writer_qos, reader_qos));
}
