//! @file subscriber.zig
//! @brief Implements the DDS Subscriber entity, managing grouped DataReaders and ordered data access.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const DomainParticipantModule = @import("domain_participant.zig");
const DomainParticipant = DomainParticipantModule.DomainParticipant;
const DataReader = @import("data_reader.zig").DataReader;
const Publisher = @import("publisher.zig").Publisher;
const DataWriter = @import("data_writer.zig").DataWriter;

const Status = @import("status.zig");
const SampleRejectedStatus = Status.SampleRejectedStatus;
const LivelinessChangedStatus = Status.LivelinessChangedStatus;
const DeadlineMissedStatus = Status.DeadlineMissedStatus;
const MatchedStatus = Status.MatchedStatus;
const IncompatibleQosStatus = Status.IncompatibleQosStatus;

const Entity = @import("entity.zig").Entity;

const Qos = @import("qos.zig");
const ReaderQos = Qos.ReaderQos;
const TopicQos = Qos.TopicQos;
const SubscriberQos = Qos.SubscriberQos;

const SampleInfo = @import("sample_info.zig");
const SampleStateMask = SampleInfo.SampleStateMask;
const ViewStateMask = SampleInfo.ViewStateMask;
const InstanceStateMask = SampleInfo.InstanceStateMask;

const StatusCondition = @import("condition.zig").StatusCondition;

const TopicModule = @import("topic.zig");
const Topic = TopicModule.Topic;

const rtps = @import("../root.zig").rtps;
const rtps_types = rtps.types;

const DiscoveredReaderData = @import("../discovery/sedp.zig").DiscoveredReaderData;
const DomainParticipantFactory = @import("domain_participant_factory.zig").DomainParticipantFactory;
const SpinRwLock = DomainParticipantModule.SpinRwLock;

/// @brief Subscriber structure.
/// @brief Subscriber listener structure.
pub const SubscriberListener = struct {
    context: ?*anyopaque = null,
    on_data_on_readers: ?*const fn (context: ?*anyopaque, subscriber: *Subscriber) void = null,
    on_data_available: ?*const fn (context: ?*anyopaque, reader: *DataReader) void = null,
    on_sample_rejected: ?*const fn (context: ?*anyopaque, reader: *DataReader, status: SampleRejectedStatus) void = null,
    on_liveliness_changed: ?*const fn (context: ?*anyopaque, reader: *DataReader, status: LivelinessChangedStatus) void = null,
    on_requested_deadline_missed: ?*const fn (context: ?*anyopaque, reader: *DataReader, status: DeadlineMissedStatus) void = null,
    on_subscription_matched: ?*const fn (context: ?*anyopaque, reader: *DataReader, status: MatchedStatus) void = null,
    on_requested_incompatible_qos: ?*const fn (context: ?*anyopaque, reader: *DataReader, status: IncompatibleQosStatus) void = null,
    on_sample_lost: ?*const fn (context: ?*anyopaque, reader: *DataReader, lost_count: u32) void = null,
};

pub const Subscriber = struct {
    default_reader_qos: ReaderQos = .{},

    entity: Entity,
    allocator: std.mem.Allocator,
    participant: *DomainParticipant,
    readers: std.ArrayListUnmanaged(*DataReader) = .empty,
    readers_lock: SpinRwLock = .{},
    qos: SubscriberQos,
    listener: ?SubscriberListener = null,
    group_access_active: bool = false,

    pub fn getDefaultDataReaderQos(self: *Subscriber) ReaderQos {
        return self.default_reader_qos;
    }

    pub fn setDefaultDataReaderQos(self: *Subscriber, qos: ReaderQos) !void {
        self.default_reader_qos = qos;
    }

    pub fn copyFromTopicQos(self: *Subscriber, a_reader_qos: *ReaderQos, a_topic_qos: TopicQos) !void {
        _ = self; // unused
        a_reader_qos.durability = a_topic_qos.durability;
        a_reader_qos.deadline = a_topic_qos.deadline;
        a_reader_qos.latency_budget = a_topic_qos.latency_budget;
        a_reader_qos.liveliness = a_topic_qos.liveliness;
        a_reader_qos.reliability = a_topic_qos.reliability;
        a_reader_qos.destination_order = a_topic_qos.destination_order;
        a_reader_qos.history = a_topic_qos.history;
        a_reader_qos.resource_limits = a_topic_qos.resource_limits;
        a_reader_qos.ownership = a_topic_qos.ownership;
        a_reader_qos.representation = a_topic_qos.representation;
    }

    /// @brief Initializes a new instance.
    pub fn init(allocator: std.mem.Allocator, participant: *DomainParticipant, qos: SubscriberQos) Subscriber {
        return .{
            .entity = undefined,
            .allocator = allocator,
            .participant = participant,
            .readers = .empty,
            .qos = qos,
        };
    }

    /// @brief Begin access.
    pub fn beginAccess(self: *Subscriber) !void {
        if (self.qos.presentation.access_scope != .group) return error.NotGroupScope;
        self.group_access_active = true;
    }

    /// @brief End access.
    pub fn endAccess(self: *Subscriber) !void {
        if (self.qos.presentation.access_scope != .group) return error.NotGroupScope;
        self.group_access_active = false;
    }

    /// @brief Release a group coherent set across all readers.
    pub fn releaseGroupCoherentSet(self: *Subscriber, cs_id: u64) void {
        for (self.readers.items) |r_ptr| {
            const reader: *DataReader = @ptrCast(@alignCast(r_ptr));
            reader.history_cache.releaseCoherentSet(cs_id);
            reader.triggerReadConditions();
        }
    }

    /// @brief Get data readers with available data.
    pub fn getDataReaders(
        self: *Subscriber,
        sample_states: SampleStateMask,
        view_states: ViewStateMask,
        instance_states: InstanceStateMask,
    ) !std.ArrayListUnmanaged(*DataReader) {
        _ = view_states;
        _ = instance_states;
        var active_readers: std.ArrayListUnmanaged(*DataReader) = .empty;
        errdefer active_readers.deinit(self.allocator);

        self.readers_lock.lockShared();
        defer self.readers_lock.unlockShared();

        for (self.readers.items) |reader| {
            var has_matching = false;

            reader.history_cache.acquireLock();
            var current = reader.history_cache.global_head;
            while (current) |node| : (current = node.global_next) {
                if (node.change.withheld) continue; // Skip withheld coherent set samples
                if (sample_states.not_read and node.sample_state == .not_read) {
                    has_matching = true;
                    break;
                }
            }
            reader.history_cache.releaseLock();

            if (has_matching) {
                try active_readers.append(self.allocator, reader);
            }
        }

        if (self.qos.presentation.ordered_access and self.qos.presentation.access_scope == .group) {
            const SortContext = struct {
                pub fn lessThan(ctx: void, a: *DataReader, b: *DataReader) bool {
                    _ = ctx;
                    var ts_a: i64 = std.math.maxInt(i64);
                    a.history_cache.acquireLock();
                    var curr_a = a.history_cache.global_head;
                    while (curr_a) |node| : (curr_a = node.global_next) {
                        if (!node.change.withheld and node.sample_state == .not_read) {
                            if (node.change.source_timestamp_ms < ts_a) ts_a = node.change.source_timestamp_ms;
                        }
                    }
                    a.history_cache.releaseLock();

                    var ts_b: i64 = std.math.maxInt(i64);
                    b.history_cache.acquireLock();
                    var curr_b = b.history_cache.global_head;
                    while (curr_b) |node| : (curr_b = node.global_next) {
                        if (!node.change.withheld and node.sample_state == .not_read) {
                            if (node.change.source_timestamp_ms < ts_b) ts_b = node.change.source_timestamp_ms;
                        }
                    }
                    b.history_cache.releaseLock();

                    return ts_a < ts_b;
                }
            };
            std.sort.block(*DataReader, active_readers.items, {}, SortContext.lessThan);
        }

        return active_readers;
    }

    pub fn deinit(self: *@This()) void {
        self.readers_lock.lock();
        for (self.readers.items) |reader| {
            reader.deinit();
            self.allocator.destroy(reader);
        }
        self.readers.deinit(self.allocator);
        self.readers = .empty;
        self.readers_lock.unlock();
        self.entity.deinit();
    }

    pub fn getInstanceHandle(self: *Subscriber) [16]u8 {
        return self.entity.getInstanceHandle();
    }

    pub fn getStatusCondition(self: *Subscriber) !*StatusCondition {
        return self.entity.getStatusCondition();
    }

    pub fn enable(self: *Subscriber) !void {
        return self.entity.enable();
    }

    pub fn enableImpl(ptr: *anyopaque) anyerror!void {
        _ = ptr;
    }

    pub fn lookupDataReader(self: *Subscriber, topic_name: []const u8) ?*DataReader {
        self.readers_lock.lockShared();
        defer self.readers_lock.unlockShared();

        for (self.readers.items) |reader| {
            if (std.mem.eql(u8, reader.topic.name, topic_name)) {
                return reader;
            }
        }
        return null;
    }

    /// @brief Create data reader.
    pub fn deleteDataReader(self: *Subscriber, reader: *DataReader) !void {
        var found = false;
        self.readers_lock.lock();
        var i: usize = 0;
        while (i < self.readers.items.len) {
            if (self.readers.items[i] == reader) {
                _ = self.readers.swapRemove(i);
                found = true;
                break;
            }
            i += 1;
        }
        self.readers_lock.unlock();

        if (!found) return;

        // Unmatch from candidate local writers
        {
            var candidate_writers = std.ArrayListUnmanaged(*DataWriter).empty;
            defer candidate_writers.deinit(self.allocator);

            DomainParticipantModule.global_registry_lock.lockShared();
            var checked_self = false;
            for (DomainParticipantModule.global_participants) |opt_p| {
                if (opt_p) |p| {
                    if (p == self.participant) checked_self = true;
                    if (p.domain_id != self.participant.domain_id) continue;
                    p.registry_lock.lockShared();
                    for (p.publishers.items) |pub_ptr| {
                        const publ: *Publisher = @ptrCast(@alignCast(pub_ptr));
                        publ.writers_lock.lock();
                        for (publ.writers.items) |w| {
                            candidate_writers.append(self.allocator, w) catch {};
                        }
                        publ.writers_lock.unlock();
                    }
                    p.registry_lock.unlockShared();
                }
            }
            DomainParticipantModule.global_registry_lock.unlockShared();

            if (!checked_self) {
                self.participant.registry_lock.lockShared();
                for (self.participant.publishers.items) |pub_ptr| {
                    const publ: *Publisher = @ptrCast(@alignCast(pub_ptr));
                    publ.writers_lock.lock();
                    for (publ.writers.items) |w| {
                        candidate_writers.append(self.allocator, w) catch {};
                    }
                    publ.writers_lock.unlock();
                }
                self.participant.registry_lock.unlockShared();
            }

            for (candidate_writers.items) |writer| {
                writer.unmatchLocalReader(reader);
                reader.unmatchLocalWriter(writer);
            }
        }

        reader.deinit();
        self.allocator.destroy(reader);
    }

    pub fn deleteContainedEntities(self: *Subscriber) !void {
        self.readers_lock.lock();
        defer self.readers_lock.unlock();

        for (self.readers.items) |reader| {
            reader.deinit();
            self.allocator.destroy(reader);
        }
        self.readers.clearRetainingCapacity();
    }

    pub fn createDataReader(self: *Subscriber, topic_obj: anytype, qos: ReaderQos, entity_id: rtps_types.EntityId_t) !*DataReader {
        const is_cft = @TypeOf(topic_obj) == TopicModule.ContentFilteredTopic;
        const topic = if (is_cft) topic_obj.related_topic else topic_obj;
        const filter_expr: ?[]const u8 = if (is_cft) topic_obj.filter_expression else null;

        if (self.participant.permissions_doc) |doc| {
            if (std.mem.indexOf(u8, doc, topic.name) != null and std.mem.indexOf(u8, doc, "<deny>") != null) {
                return error.Unauthorized;
            }
        }

        if (filter_expr) |expr| {
            self.participant.registry_lock.lock();
            if (self.participant.filter_expression == null) {
                self.participant.filter_expression = self.participant.allocator.dupe(u8, expr) catch null;
                if (self.participant.filter_expression != null) {
                    self.participant.filter_expression_owned = true;
                }
            }
            self.participant.registry_lock.unlock();
        }

        var final_entity_id = entity_id;
        if (entity_id.entity_kind == rtps_types.EntityId_t.unknown.entity_kind) {
            final_entity_id.entity_kind = @backingInt(rtps_types.EntityKind.user_reader_no_key);
            const id = self.participant.next_entity_id.fetchAdd(1, .monotonic);
            final_entity_id.entity_key[0] = @as(u8, @intCast((id >> 16) & 0xFF));
            final_entity_id.entity_key[1] = @as(u8, @intCast((id >> 8) & 0xFF));
            final_entity_id.entity_key[2] = @as(u8, @intCast(id & 0xFF));
        }

        const reader_ptr = try self.allocator.create(DataReader);
        errdefer self.allocator.destroy(reader_ptr);
        reader_ptr.* = DataReader.init(self, topic, qos, final_entity_id);
        if (filter_expr) |expr| {
            reader_ptr.filter_expression = try self.allocator.dupe(u8, expr);
            reader_ptr.filter_expression_owned = true;
        }
        if (is_cft) {
            for (topic_obj.get_expression_parameters()) |p| {
                const copy = try self.allocator.dupe(u8, p);
                try reader_ptr.expression_parameters.append(self.allocator, copy);
            }
        }
        reader_ptr.entity = Entity.init(self.allocator, reader_ptr, DataReader.enableImpl);
        if (qos.entity_factory.autoenable_created_entities) reader_ptr.enable() catch |err| {
            reader_ptr.deinit();
            self.allocator.destroy(reader_ptr);
            return err;
        };

        self.readers_lock.lock();
        self.readers.append(self.allocator, reader_ptr) catch |err| {
            self.readers_lock.unlock();
            reader_ptr.deinit();
            self.allocator.destroy(reader_ptr);
            return err;
        };
        self.readers_lock.unlock();

        // Match with candidate local writers
        {
            var candidate_writers = std.ArrayListUnmanaged(*DataWriter).empty;
            defer candidate_writers.deinit(self.allocator);

            DomainParticipantModule.global_registry_lock.lockShared();
            var checked_self = false;
            for (DomainParticipantModule.global_participants) |opt_p| {
                if (opt_p) |p| {
                    if (p == self.participant) checked_self = true;
                    if (p.domain_id != self.participant.domain_id) continue;
                    p.registry_lock.lockShared();
                    for (p.publishers.items) |pub_ptr| {
                        const publ: *Publisher = @ptrCast(@alignCast(pub_ptr));
                        publ.writers_lock.lock();
                        for (publ.writers.items) |w| {
                            candidate_writers.append(self.allocator, w) catch {};
                        }
                        publ.writers_lock.unlock();
                    }
                    p.registry_lock.unlockShared();
                }
            }
            DomainParticipantModule.global_registry_lock.unlockShared();

            if (!checked_self) {
                self.participant.registry_lock.lockShared();
                for (self.participant.publishers.items) |pub_ptr| {
                    const publ: *Publisher = @ptrCast(@alignCast(pub_ptr));
                    publ.writers_lock.lock();
                    for (publ.writers.items) |w| {
                        candidate_writers.append(self.allocator, w) catch {};
                    }
                    publ.writers_lock.unlock();
                }
                self.participant.registry_lock.unlockShared();
            }

            for (candidate_writers.items) |writer| {
                _ = writer.matchLocalReader(reader_ptr) catch false;
                _ = reader_ptr.matchLocalWriter(writer) catch false;
            }
        }

        if (reader_ptr.qos.durability != .@"volatile") {
            const HistoricalSample = struct {
                writer_guid: rtps_types.GUID_t,
                submsg: rtps.Submessage.Data,
            };
            var samples_to_deliver: std.ArrayListUnmanaged(HistoricalSample) = .empty;
            defer samples_to_deliver.deinit(self.allocator);

            DomainParticipantModule.global_registry_lock.lockShared();
            for (DomainParticipantModule.global_participants) |opt_p| {
                if (opt_p) |p| {
                    p.registry_lock.lockShared();
                    for (p.publishers.items) |pub_ptr| {
                        const publ: *Publisher = @ptrCast(@alignCast(pub_ptr));
                        for (publ.writers.items) |writer| {
                            if (!std.mem.eql(u8, topic.name, writer.topic.name)) continue;
                            if (topic.type_name.len > 0 and writer.topic.type_name.len > 0 and !std.mem.eql(u8, topic.type_name, writer.topic.type_name)) continue;
                            if (!Qos.matchPartition(publ.qos.partition.name, self.qos.partition.name)) continue;
                            if (writer.qos.durability == .@"volatile") continue;

                            writer.history_cache.acquireLock();
                            const writer_guid = rtps_types.GUID_t{ .prefix = p.guid_prefix, .entity_id = writer.entity_id };
                            var curr = writer.history_cache.global_head;
                            while (curr) |node| : (curr = node.global_next) {
                                const data_submessage = rtps.Submessage.Data{
                                    .header = undefined,
                                    .extra_flags = 0,
                                    .octets_to_inline_qos = 16,
                                    .reader_id = rtps_types.EntityId_t.unknown,
                                    .writer_id = writer.entity_id,
                                    .writer_sn = node.change.sequence_number,
                                    .instance_handle = node.change.instance_handle,
                                    .status_info = null,
                                    .serialized_payload = node.change.data_value,
                                    .coherent_set_id = if (node.change.coherent_set_id != 0) node.change.coherent_set_id else null,
                                    .related_sample_identity = node.change.related_sample_identity,
                                };
                                samples_to_deliver.append(self.allocator, .{
                                    .writer_guid = writer_guid,
                                    .submsg = data_submessage,
                                }) catch {};
                            }
                            writer.history_cache.releaseLock();
                        }
                    }
                    p.registry_lock.unlockShared();
                }
            }
            DomainParticipantModule.global_registry_lock.unlockShared();

            for (samples_to_deliver.items) |item| {
                reader_ptr.processData(item.writer_guid, item.submsg) catch {};
            }
        }

        if (self.participant.sedp_sub_writer) |sedp_writer| {
            if (final_entity_id.entity_kind != rtps_types.EntityId_t.sedp_pub_reader.entity_kind and
                final_entity_id.entity_kind != rtps_types.EntityId_t.sedp_sub_reader.entity_kind)
            {
                const guid = rtps_types.GUID_t{
                    .prefix = self.participant.guid_prefix,
                    .entity_id = final_entity_id,
                };

                try sedp_writer.write(DiscoveredReaderData{
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
                    .ownership_kind = 0,
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

        return reader_ptr;
    }
};

test "Subscriber initialization and reader creation" {
    var factory = DomainParticipantFactory.getInstance();
    var participant = try factory.createParticipant(0, null, std.testing.allocator);
    defer factory.deleteParticipant(participant, std.testing.allocator) catch {};

    var subscriber = try participant.createSubscriber(null);

    const topic = Topic.init("TestTopic", "TestType");
    const qos = ReaderQos{};
    const entity_id = rtps_types.EntityId_t.unknown;

    _ = try subscriber.createDataReader(topic, qos, entity_id);

    try std.testing.expectEqual(@as(usize, 1), subscriber.readers.items.len);
}
