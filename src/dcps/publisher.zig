//! @file publisher.zig
//! @brief Implements the DDS Publisher entity, managing grouped DataWriters and coherent/ordered data presentation.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");

const DomainParticipantModule = @import("domain_participant.zig");
const DomainParticipant = DomainParticipantModule.DomainParticipant;
const SpinRwLock = DomainParticipantModule.SpinRwLock;
const DataWriter = @import("data_writer.zig").DataWriter;
const Subscriber = @import("subscriber.zig").Subscriber;
const DataReader = @import("data_reader.zig").DataReader;

const Status = @import("status.zig");
const DeadlineMissedStatus = Status.DeadlineMissedStatus;
const LivelinessLostStatus = Status.LivelinessLostStatus;
const MatchedStatus = Status.MatchedStatus;
const IncompatibleQosStatus = Status.IncompatibleQosStatus;

const Entity = @import("entity.zig").Entity;

const Qos = @import("qos.zig");
const WriterQos = Qos.WriterQos;
const TopicQos = Qos.TopicQos;
const PublisherQos = Qos.PublisherQos;

const Topic = @import("topic.zig").Topic;
const StatusCondition = @import("condition.zig").StatusCondition;
const rtps = @import("../root.zig").rtps;
const rtps_types = rtps.types;
const HistoryCache = @import("../rtps/history_cache.zig").HistoryCache;
const DiscoveredWriterData = @import("../discovery/sedp.zig").DiscoveredWriterData;
const DomainParticipantFactory = @import("domain_participant_factory.zig").DomainParticipantFactory;

/// @brief Publisher structure.
/// @brief Publisher listener structure.
pub const PublisherListener = struct {
    context: ?*anyopaque = null,
    on_offered_deadline_missed: ?*const fn (context: ?*anyopaque, writer: *DataWriter, status: DeadlineMissedStatus) void = null,
    on_liveliness_lost: ?*const fn (context: ?*anyopaque, writer: *DataWriter, status: LivelinessLostStatus) void = null,
    on_publication_matched: ?*const fn (context: ?*anyopaque, writer: *DataWriter, status: MatchedStatus) void = null,
    on_offered_incompatible_qos: ?*const fn (context: ?*anyopaque, writer: *DataWriter, status: IncompatibleQosStatus) void = null,
};

pub const Publisher = struct {
    default_writer_qos: WriterQos = .{},
    entity: Entity,
    allocator: std.mem.Allocator,
    participant: *DomainParticipant,
    qos: PublisherQos = .{},
    listener: ?PublisherListener = null,
    writers: std.ArrayListUnmanaged(*DataWriter) = .empty,
    writers_lock: SpinRwLock = .{},
    coherent_changes_active: bool = false,
    coherent_set_id: u64 = 0,
    suspended: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn getDefaultDataWriterQos(self: *Publisher) WriterQos {
        return self.default_writer_qos;
    }

    pub fn setDefaultDataWriterQos(self: *Publisher, qos: WriterQos) !void {
        self.default_writer_qos = qos;
    }

    pub fn copyFromTopicQos(self: *Publisher, a_writer_qos: *WriterQos, a_topic_qos: TopicQos) !void {
        _ = self; // unused
        a_writer_qos.durability = a_topic_qos.durability;
        a_writer_qos.deadline = a_topic_qos.deadline;
        a_writer_qos.latency_budget = a_topic_qos.latency_budget;
        a_writer_qos.liveliness = a_topic_qos.liveliness;
        a_writer_qos.reliability = a_topic_qos.reliability;
        a_writer_qos.destination_order = a_topic_qos.destination_order;
        a_writer_qos.history = a_topic_qos.history;
        a_writer_qos.resource_limits = a_topic_qos.resource_limits;
        a_writer_qos.transport_priority = a_topic_qos.transport_priority;
        a_writer_qos.lifespan = a_topic_qos.lifespan;
        a_writer_qos.ownership = a_topic_qos.ownership;
        a_writer_qos.representation = a_topic_qos.representation;
    }

    /// @brief Initializes a new instance.
    pub fn init(allocator: std.mem.Allocator, participant: *DomainParticipant, qos: PublisherQos) Publisher {
        return .{
            .entity = undefined,
            .allocator = allocator,
            .participant = participant,
            .qos = qos,
            .writers = .empty,
        };
    }

    /// @brief Begin coherent changes.
    pub fn beginCoherentChanges(self: *Publisher) !void {
        if (self.qos.presentation.access_scope != .group) return error.NotGroupScope;
        if (!self.qos.presentation.coherent_access) return error.NotCoherent;
        self.coherent_changes_active = true;
    }

    /// @brief End coherent changes.
    pub fn endCoherentChanges(self: *Publisher) !void {
        if (self.qos.presentation.access_scope != .group) return error.NotGroupScope;
        if (!self.qos.presentation.coherent_access) return error.NotCoherent;
        if (!self.coherent_changes_active) return;

        // Broadcast the end coherent set marker on all writers
        self.writers_lock.lockShared();
        defer self.writers_lock.unlockShared();
        for (self.writers.items) |writer| {
            if (writer.entity_id.entity_kind != rtps_types.EntityId_t.sedp_pub_writer.entity_kind) {
                // Send dummy 0-length payload to mark end of coherent set
                writer.sendEndCoherentSet() catch {};
            }
        }

        self.coherent_changes_active = false;
        self.coherent_set_id += 1;
    }

    /// @brief Indicates to the middleware that multiple changes are about to be made.
    pub fn suspendPublications(self: *Publisher) !void {
        self.suspended.store(true, .seq_cst);
    }

    /// @brief Indicates to the middleware that the changes can now be sent.
    pub fn resumePublications(self: *Publisher) !void {
        self.suspended.store(false, .seq_cst);
        self.writers_lock.lockShared();
        defer self.writers_lock.unlockShared();
        for (self.writers.items) |writer| {
            writer.flush() catch {};
        }
    }

    /// @brief Blocks until all data written by all DataWriters is acknowledged.
    pub fn waitForAcknowledgments(self: *Publisher, max_wait: struct { duration_ms: i32 }) !void {
        const start_time = HistoryCache.GetTickCount64();
        const duration_ms = if (max_wait.duration_ms == std.math.maxInt(i32)) std.math.maxInt(u64) else @as(u64, @intCast(max_wait.duration_ms));

        self.writers_lock.lockShared();
        defer self.writers_lock.unlockShared();
        for (self.writers.items) |writer| {
            // Check remaining time
            const now = HistoryCache.GetTickCount64();
            if (now - start_time >= duration_ms) return error.Timeout;

            const remaining_ms = @as(i32, @intCast(duration_ms - (now - start_time)));
            try writer.waitForAcknowledgments(.{ .duration_ms = remaining_ms });
        }
    }

    /// @brief Deinitializes the instance.
    pub fn deinit(self: *@This()) void {
        self.writers_lock.lock();
        for (self.writers.items) |writer| {
            writer.deinit();
            self.allocator.destroy(writer);
        }
        self.writers.deinit(self.allocator);
        self.writers = .empty;
        self.writers_lock.unlock();
        self.entity.deinit();
    }

    pub fn getInstanceHandle(self: *Publisher) [16]u8 {
        return self.entity.getInstanceHandle();
    }

    pub fn getStatusCondition(self: *Publisher) !*StatusCondition {
        return self.entity.getStatusCondition();
    }

    pub fn enable(self: *Publisher) !void {
        return self.entity.enable();
    }

    pub fn enableImpl(ptr: *anyopaque) anyerror!void {
        _ = ptr;
    }

    /// @brief Create data writer.
    pub fn deleteDataWriter(self: *Publisher, writer: *DataWriter) !void {
        var found = false;
        self.writers_lock.lock();
        var i: usize = 0;
        while (i < self.writers.items.len) {
            if (self.writers.items[i] == writer) {
                _ = self.writers.swapRemove(i);
                found = true;
                break;
            }
            i += 1;
        }
        self.writers_lock.unlock();

        if (!found) return;

        // Unmatch from candidate local readers
        {
            var candidate_readers = std.ArrayListUnmanaged(*DataReader).empty;
            defer candidate_readers.deinit(self.allocator);

            DomainParticipantModule.global_registry_lock.lockShared();
            var checked_self = false;
            for (DomainParticipantModule.global_participants) |opt_p| {
                if (opt_p) |p| {
                    if (p == self.participant) checked_self = true;
                    if (p.domain_id != self.participant.domain_id) continue;
                    p.registry_lock.lockShared();
                    for (p.subscribers.items) |sub_ptr| {
                        const subl: *Subscriber = @ptrCast(@alignCast(sub_ptr));
                        subl.readers_lock.lock();
                        for (subl.readers.items) |r| {
                            candidate_readers.append(self.allocator, r) catch {};
                        }
                        subl.readers_lock.unlock();
                    }
                    p.registry_lock.unlockShared();
                }
            }
            DomainParticipantModule.global_registry_lock.unlockShared();

            if (!checked_self) {
                self.participant.registry_lock.lockShared();
                for (self.participant.subscribers.items) |sub_ptr| {
                    const subl: *Subscriber = @ptrCast(@alignCast(sub_ptr));
                    subl.readers_lock.lock();
                    for (subl.readers.items) |r| {
                        candidate_readers.append(self.allocator, r) catch {};
                    }
                    subl.readers_lock.unlock();
                }
                self.participant.registry_lock.unlockShared();
            }

            for (candidate_readers.items) |reader| {
                writer.unmatchLocalReader(reader);
                reader.unmatchLocalWriter(writer);
            }
        }

        writer.deinit();
        self.allocator.destroy(writer);
    }

    pub fn deleteContainedEntities(self: *Publisher) !void {
        self.writers_lock.lock();
        defer self.writers_lock.unlock();

        for (self.writers.items) |writer| {
            writer.deinit();
            self.allocator.destroy(writer);
        }
        self.writers.clearRetainingCapacity();
    }

    pub fn createDataWriter(self: *Publisher, topic: Topic, qos: WriterQos, entity_id: rtps_types.EntityId_t) !*DataWriter {
        if (self.participant.permissions_doc) |doc| {
            if (std.mem.indexOf(u8, doc, topic.name) != null and std.mem.indexOf(u8, doc, "<deny>") != null) {
                return error.Unauthorized;
            }
        }

        var final_entity_id = entity_id;
        if (entity_id.entity_kind == rtps_types.EntityId_t.unknown.entity_kind) {
            final_entity_id.entity_kind = @backingInt(rtps_types.EntityKind.user_writer_no_key);
            const id = self.participant.next_entity_id.fetchAdd(1, .monotonic);
            final_entity_id.entity_key[0] = @as(u8, @intCast((id >> 16) & 0xFF));
            final_entity_id.entity_key[1] = @as(u8, @intCast((id >> 8) & 0xFF));
            final_entity_id.entity_key[2] = @as(u8, @intCast(id & 0xFF));
        }

        const writer_ptr = try self.allocator.create(DataWriter);
        errdefer self.allocator.destroy(writer_ptr);
        writer_ptr.* = try DataWriter.init(self, topic, qos, final_entity_id);
        writer_ptr.history_cache.loadFromDisk() catch |err| {
            std.log.warn("Failed to load persistent cache: {s}", .{@errorName(err)});
        };
        writer_ptr.entity = Entity.init(self.allocator, writer_ptr, DataWriter.enableImpl);
        if (qos.entity_factory.autoenable_created_entities) writer_ptr.enable() catch |err| {
            writer_ptr.deinit();
            self.allocator.destroy(writer_ptr);
            return err;
        };
        self.writers_lock.lock();
        self.writers.append(self.allocator, writer_ptr) catch |err| {
            self.writers_lock.unlock();
            writer_ptr.deinit();
            self.allocator.destroy(writer_ptr);
            return err;
        };
        self.writers_lock.unlock();

        // Match with candidate local readers
        {
            var candidate_readers = std.ArrayListUnmanaged(*DataReader).empty;
            defer candidate_readers.deinit(self.allocator);

            DomainParticipantModule.global_registry_lock.lockShared();
            var checked_self = false;
            for (DomainParticipantModule.global_participants) |opt_p| {
                if (opt_p) |p| {
                    if (p == self.participant) checked_self = true;
                    if (p.domain_id != self.participant.domain_id) continue;
                    p.registry_lock.lockShared();
                    for (p.subscribers.items) |sub_ptr| {
                        const subl: *Subscriber = @ptrCast(@alignCast(sub_ptr));
                        subl.readers_lock.lock();
                        for (subl.readers.items) |r| {
                            candidate_readers.append(self.allocator, r) catch {};
                        }
                        subl.readers_lock.unlock();
                    }
                    p.registry_lock.unlockShared();
                }
            }
            DomainParticipantModule.global_registry_lock.unlockShared();

            if (!checked_self) {
                self.participant.registry_lock.lockShared();
                for (self.participant.subscribers.items) |sub_ptr| {
                    const subl: *Subscriber = @ptrCast(@alignCast(sub_ptr));
                    subl.readers_lock.lock();
                    for (subl.readers.items) |r| {
                        candidate_readers.append(self.allocator, r) catch {};
                    }
                    subl.readers_lock.unlock();
                }
                self.participant.registry_lock.unlockShared();
            }

            for (candidate_readers.items) |reader| {
                const w_matched = writer_ptr.matchLocalReader(reader) catch false;
                const r_matched = reader.matchLocalWriter(writer_ptr) catch false;
                if (w_matched and r_matched and writer_ptr.qos.durability != .@"volatile" and reader.qos.durability != .@"volatile") {
                    writer_ptr.history_cache.acquireLock();
                    var curr = writer_ptr.history_cache.global_head;
                    const writer_guid = rtps_types.GUID_t{ .prefix = self.participant.guid_prefix, .entity_id = writer_ptr.entity_id };
                    while (curr) |node| : (curr = node.global_next) {
                        const data_submessage = rtps.Submessage.Data{
                            .header = undefined,
                            .extra_flags = 0,
                            .octets_to_inline_qos = 16,
                            .reader_id = rtps_types.EntityId_t.unknown,
                            .writer_id = writer_ptr.entity_id,
                            .writer_sn = node.change.sequence_number,
                            .instance_handle = node.change.instance_handle,
                            .status_info = null,
                            .serialized_payload = node.change.data_value,
                            .coherent_set_id = if (node.change.coherent_set_id != 0) node.change.coherent_set_id else null,
                            .related_sample_identity = node.change.related_sample_identity,
                        };
                        reader.processData(writer_guid, data_submessage) catch {};
                    }
                    writer_ptr.history_cache.releaseLock();
                }
            }
        }

        if (self.participant.sedp_pub_writer) |sedp_writer| {
            if (final_entity_id.entity_kind != rtps_types.EntityId_t.sedp_pub_writer.entity_kind and
                final_entity_id.entity_kind != rtps_types.EntityId_t.sedp_sub_writer.entity_kind)
            {
                const guid = rtps_types.GUID_t{
                    .prefix = self.participant.guid_prefix,
                    .entity_id = final_entity_id,
                };
                try sedp_writer.write(DiscoveredWriterData{
                    .endpoint_guid = guid,
                    .topic_name = topic.name,
                    .type_name = topic.type_name,
                    .reliability_qos = @backingInt(qos.reliability.kind),
                    .durability_kind = @backingInt(qos.durability),
                    .deadline_period_ms = qos.deadline.period_ms,
                    .destination_order_kind = @backingInt(qos.destination_order.kind),
                    .presentation_access_scope = @backingInt(self.qos.presentation.access_scope),
                    .presentation_coherent_access = self.qos.presentation.coherent_access,
                    .presentation_ordered_access = self.qos.presentation.ordered_access,
                    .ownership_kind = @backingInt(qos.ownership.kind),
                    .ownership_strength = qos.ownership_strength.value,
                    .liveliness_kind = @backingInt(qos.liveliness.kind),
                    .liveliness_lease_duration = qos.liveliness.lease_duration,
                    .partition_name = self.qos.partition.name,
                    .type_object_cdr = topic.type_object_cdr,
                    .user_data = qos.user_data.value[0..qos.user_data.len],
                    .group_data = self.qos.group_data.value[0..self.qos.group_data.len],
                    .topic_data = "",
                    .representation_mask = qos.representation.toMask(),
                });
            }
        }

        return writer_ptr;
    }
};

test "Publisher initialization and writer creation" {
    var factory = DomainParticipantFactory.getInstance();
    var participant = try factory.createParticipant(0, null, std.testing.allocator);
    defer factory.deleteParticipant(participant, std.testing.allocator) catch {};

    var publisher = try participant.createPublisher(null);

    const topic = Topic.init("TestTopic", "TestType");
    const qos = WriterQos{};
    const entity_id = rtps_types.EntityId_t.unknown;

    _ = try publisher.createDataWriter(topic, qos, entity_id);

    try std.testing.expectEqual(@as(usize, 1), publisher.writers.items.len);
}

test "Publisher synchronous operations" {
    var factory = DomainParticipantFactory.getInstance();
    var participant = try factory.createParticipant(0, null, std.testing.allocator);
    defer factory.deleteParticipant(participant, std.testing.allocator) catch {};

    var publisher = try participant.createPublisher(null);

    // Test suspend and resume hints
    try std.testing.expectEqual(false, publisher.suspended.load(.seq_cst));
    try publisher.suspendPublications();
    try std.testing.expectEqual(true, publisher.suspended.load(.seq_cst));
    try publisher.resumePublications();
    try std.testing.expectEqual(false, publisher.suspended.load(.seq_cst));

    // Test waitForAcknowledgments with no matched readers (should return immediately)
    const topic = Topic.init("TestTopicSync", "TestTypeSync");
    const entity_id = rtps_types.EntityId_t.unknown;
    _ = try publisher.createDataWriter(topic, .{}, entity_id);

    try publisher.waitForAcknowledgments(.{ .duration_ms = 1000 });
}
