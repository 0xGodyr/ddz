//! @file data_reader.zig
//! @brief Implements the DDS DataReader entity for subscribing to, filtering, and accessing typed topic samples.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const root = @import("../root.zig");
const rtps = root.rtps;
const os = @import("../os.zig");
const getTickCount64 = os.getTickCount64;
const GetTickCount64 = getTickCount64;

const Entity = @import("entity.zig").Entity;
const Qos = @import("qos.zig");
const ReaderQos = Qos.ReaderQos;
const Status = @import("status.zig");
const StatusKind = Status.StatusKind;
const SampleRejectedStatus = Status.SampleRejectedStatus;
const DeadlineMissedStatus = Status.DeadlineMissedStatus;
const LivelinessChangedStatus = Status.LivelinessChangedStatus;
const MatchedStatus = Status.MatchedStatus;
const IncompatibleQosStatus = Status.IncompatibleQosStatus;

const Topic = @import("topic.zig").Topic;
const subscriber_mod = @import("subscriber.zig");
const Subscriber = subscriber_mod.Subscriber;
const SubscriberListener = subscriber_mod.SubscriberListener;
const DataWriter = @import("data_writer.zig").DataWriter;
const DomainParticipantListener = @import("domain_participant.zig").DomainParticipantListener;
const DomainParticipantFactory = @import("domain_participant_factory.zig").DomainParticipantFactory;
const Condition = @import("condition.zig");
const ReadCondition = Condition.ReadCondition;
const QueryCondition = Condition.QueryCondition;
const StatusCondition = Condition.StatusCondition;
const SampleInfo = @import("sample_info.zig");
const SampleStateKind = SampleInfo.SampleStateKind;
const ViewStateKind = SampleInfo.ViewStateKind;
const InstanceStateKind = SampleInfo.InstanceStateKind;
const SpinLock = @import("wait_set.zig").SpinLock;

const HistoryCacheModule = @import("../rtps/history_cache.zig");
const HistoryCache = HistoryCacheModule.HistoryCache;
const CacheChange = HistoryCacheModule.CacheChange;
const CacheChangeNode = HistoryCacheModule.CacheChangeNode;
const ChangeKind = HistoryCacheModule.ChangeKind;
const Sql = @import("sql.zig").Sql;
const Sql92 = Sql;

const GUID_t = rtps.types.GUID_t;
const EntityId_t = rtps.types.EntityId_t;
const Locator_t = rtps.types.Locator_t;
const InstanceHandle_t = rtps.types.InstanceHandle_t;
const SequenceNumber_t = rtps.types.SequenceNumber_t;

const Serializer = @import("../cdr/serializer.zig").Serializer;
const Deserializer = @import("../cdr/deserializer.zig").Deserializer;
const json = @import("../json/json.zig");
const xtypes = @import("../types/xtypes.zig");
const DiscoveredWriterData = @import("../discovery/sedp.zig").DiscoveredWriterData;

/// @brief Data reader structure.
pub const DataReader = struct {
    entity: Entity,
    subscriber: *Subscriber,
    topic: Topic,
    qos: ReaderQos,
    entity_id: EntityId_t,
    history_cache: HistoryCache,
    acknack_count: u32 = 1,
    read_conditions: std.ArrayListUnmanaged(*ReadCondition) = .empty,
    registry_lock: SpinLock = .{},
    time_based_filter_state: std.AutoHashMapUnmanaged(InstanceHandle_t, i64) = .empty,
    loaned_nodes: std.ArrayListUnmanaged(*CacheChangeNode) = .empty,
    listener: ?DataReaderListener = null,
    highest_received_sn: u32 = 0,
    status_changes: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    // Status payloads
    sample_rejected_status: SampleRejectedStatus = .{},
    requested_deadline_missed_status: DeadlineMissedStatus = .{},
    liveliness_changed_status: LivelinessChangedStatus = .{},
    subscription_matched_status: MatchedStatus = .{},
    requested_incompatible_qos_status: IncompatibleQosStatus = .{},

    total_lost: u32 = 0,
    total_rejected: u32 = 0,
    matched_writers: std.ArrayListUnmanaged(GUID_t) = .empty,
    incompatible_writers: std.ArrayListUnmanaged(GUID_t) = .empty,
    instance_owners: std.AutoHashMapUnmanaged([16]u8, GUID_t) = .empty,
    writer_liveliness: std.AutoHashMapUnmanaged(GUID_t, i64) = .empty,
    // Deadline tracking
    deadline_lock: SpinLock = .{},
    cache_mutex: SpinLock = .{},
    last_receive_time: std.AutoHashMapUnmanaged([16]u8, i64) = .empty,
    filter_expression: ?[]const u8 = null,
    filter_expression_owned: bool = false,
    expression_parameters: std.ArrayListUnmanaged([]const u8) = .empty,

    /// @brief Initializes a new instance.
    pub fn init(subscriber: *Subscriber, topic: Topic, qos: ReaderQos, entity_id: EntityId_t) DataReader {
        return .{
            .entity = undefined,
            .subscriber = subscriber,
            .topic = topic,
            .qos = qos,
            .entity_id = entity_id,
            .history_cache = HistoryCache.init(subscriber.allocator, qos.history, qos.resource_limits, qos.lifespan, qos.time_based_filter, qos.destination_order, qos.reader_data_lifecycle, null),
        };
    }

    /// @brief Deinitializes the instance.
    pub fn releaseCoherentSet(self: *DataReader, writer_guid: rtps.types.GUID_t, set_id: u64) void {
        while (self.history_cache.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
        defer self.history_cache.lock.store(false, .release);

        var current = self.history_cache.global_head;
        while (current) |node| : (current = node.global_next) {
            if (node.change.withheld and
                std.meta.eql(node.change.writer_guid, writer_guid) and
                node.change.coherent_set_id == set_id)
            {
                node.change.withheld = false;
            }
        }
    }

    pub fn deinit(self: *DataReader) void {
        for (self.read_conditions.items) |rc| {
            if (rc.condition.waitset) |ws| {
                ws.detachCondition(&rc.condition);
            }
            if (rc.condition.kind == .query_condition) {
                const qc: *QueryCondition = @ptrCast(@alignCast(rc));
                self.subscriber.allocator.destroy(qc);
            } else {
                self.subscriber.allocator.destroy(rc);
            }
        }
        self.entity.deinit();
        self.read_conditions.deinit(self.subscriber.allocator);
        self.time_based_filter_state.deinit(self.subscriber.allocator);
        for (self.loaned_nodes.items) |node| {
            self.history_cache.freeNodeMemory(node);
            self.history_cache.node_pool.destroy(node);
        }
        self.loaned_nodes.deinit(self.subscriber.allocator);
        self.history_cache.deinit();
        self.matched_writers.deinit(self.subscriber.participant.allocator);
        self.incompatible_writers.deinit(self.subscriber.participant.allocator);
        self.instance_owners.deinit(self.subscriber.participant.allocator);
        self.writer_liveliness.deinit(self.subscriber.participant.allocator);
        self.last_receive_time.deinit(self.subscriber.participant.allocator);
        if (self.filter_expression_owned) {
            if (self.filter_expression) |fe| {
                self.subscriber.allocator.free(fe);
                self.filter_expression = null;
            }
        }
        for (self.expression_parameters.items) |p| {
            self.subscriber.allocator.free(p);
        }
        self.expression_parameters.deinit(self.subscriber.allocator);
    }

    /// @brief Returns the slice of current expression parameters.
    pub fn get_expression_parameters(self: *const DataReader) []const []const u8 {
        return self.expression_parameters.items;
    }

    /// @brief Replaces current expression parameters without recreating the reader.
    pub fn set_expression_parameters(self: *DataReader, params: []const []const u8) !void {
        for (self.expression_parameters.items) |p| {
            self.subscriber.allocator.free(p);
        }
        self.expression_parameters.clearRetainingCapacity();
        for (params) |p| {
            const copy = try self.subscriber.allocator.dupe(u8, p);
            try self.expression_parameters.append(self.subscriber.allocator, copy);
        }
    }

    /// @brief Create read condition.
    /// @brief Retrieve the StatusCondition for this reader.
    /// @brief Notify of a status change.
    pub fn notifyStatusChange(self: *DataReader, status: StatusKind) void {
        const mask = @backingInt(status);
        _ = self.status_changes.fetchOr(mask, .monotonic);

        var opt_sc: ?*StatusCondition = null;
        var r_listener: ?DataReaderListener = null;
        var s_listener: ?SubscriberListener = null;
        var p_listener: ?DomainParticipantListener = null;
        var sample_rejected: SampleRejectedStatus = undefined;
        var requested_deadline: DeadlineMissedStatus = undefined;
        var liveliness_changed: LivelinessChangedStatus = undefined;
        var subscription_matched: MatchedStatus = undefined;
        var requested_incompatible: IncompatibleQosStatus = undefined;

        {
            self.registry_lock.lock();
            defer self.registry_lock.unlock();

            opt_sc = self.entity.status_condition;
            r_listener = self.listener;
            s_listener = self.subscriber.listener;
            p_listener = self.subscriber.participant.listener;
            sample_rejected = self.sample_rejected_status;
            requested_deadline = self.requested_deadline_missed_status;
            liveliness_changed = self.liveliness_changed_status;
            subscription_matched = self.subscription_matched_status;
            requested_incompatible = self.requested_incompatible_qos_status;
        }

        if (opt_sc) |sc| {
            if ((self.status_changes.load(.monotonic) & sc.enabled_statuses) != 0) {
                sc.condition.setTriggerValue(true);
            }
        }

        // Listener dispatch hierarchy outside lock to prevent deadlocks
        var handled = false;

        // 1. Try DataReaderListener
        if (r_listener) |l| {
            switch (status) {
                .data_available => if (l.on_data_available) |cb| {
                    cb(l.context, self);
                    handled = true;
                },
                .sample_rejected => if (l.on_sample_rejected) |cb| {
                    cb(l.context, self, sample_rejected);
                    handled = true;
                },
                .requested_deadline_missed => if (l.on_requested_deadline_missed) |cb| {
                    cb(l.context, self, requested_deadline);
                    handled = true;
                },
                .liveliness_changed => if (l.on_liveliness_changed) |cb| {
                    cb(l.context, self, liveliness_changed);
                    handled = true;
                },
                .subscription_matched => if (l.on_subscription_matched) |cb| {
                    cb(l.context, self, subscription_matched);
                    handled = true;
                },
                .requested_incompatible_qos => if (l.on_requested_incompatible_qos) |cb| {
                    cb(l.context, self, requested_incompatible);
                    handled = true;
                },
                else => {},
            }
        }

        // 2. Try SubscriberListener
        if (!handled) {
            if (s_listener) |sl| {
                switch (status) {
                    .data_available => if (sl.on_data_available) |cb| {
                        cb(sl.context, self);
                        handled = true;
                    },
                    .sample_rejected => if (sl.on_sample_rejected) |cb| {
                        cb(sl.context, self, sample_rejected);
                        handled = true;
                    },
                    .requested_deadline_missed => if (sl.on_requested_deadline_missed) |cb| {
                        cb(sl.context, self, requested_deadline);
                        handled = true;
                    },
                    .liveliness_changed => if (sl.on_liveliness_changed) |cb| {
                        cb(sl.context, self, liveliness_changed);
                        handled = true;
                    },
                    .subscription_matched => if (sl.on_subscription_matched) |cb| {
                        cb(sl.context, self, subscription_matched);
                        handled = true;
                    },
                    .requested_incompatible_qos => if (sl.on_requested_incompatible_qos) |cb| {
                        cb(sl.context, self, requested_incompatible);
                        handled = true;
                    },
                    else => {},
                }
            }
        }

        // 3. Try DomainParticipantListener
        if (!handled) {
            if (p_listener) |pl| {
                switch (status) {
                    .data_available => if (pl.on_data_available) |cb| {
                        cb(pl.context, self);
                        handled = true;
                    },
                    .sample_rejected => if (pl.on_sample_rejected) |cb| {
                        cb(pl.context, self, sample_rejected);
                        handled = true;
                    },
                    .requested_deadline_missed => if (pl.on_requested_deadline_missed) |cb| {
                        cb(pl.context, self, requested_deadline);
                        handled = true;
                    },
                    .liveliness_changed => if (pl.on_liveliness_changed) |cb| {
                        cb(pl.context, self, liveliness_changed);
                        handled = true;
                    },
                    .subscription_matched => if (pl.on_subscription_matched) |cb| {
                        cb(pl.context, self, subscription_matched);
                        handled = true;
                    },
                    .requested_incompatible_qos => if (pl.on_requested_incompatible_qos) |cb| {
                        cb(pl.context, self, requested_incompatible);
                        handled = true;
                    },
                    else => {},
                }
            }
        }
    }

    pub fn deleteReadCondition(self: *DataReader, cond: *ReadCondition) !void {
        self.registry_lock.lock();
        defer self.registry_lock.unlock();

        var i: usize = 0;
        while (i < self.read_conditions.items.len) {
            if (self.read_conditions.items[i] == cond) {
                _ = self.read_conditions.swapRemove(i);

                if (cond.condition.waitset) |ws| {
                    ws.detachCondition(&cond.condition);
                }
                if (cond.condition.kind == .query_condition) {
                    const qc: *QueryCondition = @ptrCast(@alignCast(cond));
                    self.subscriber.allocator.destroy(qc);
                } else {
                    self.subscriber.allocator.destroy(cond);
                }
                return;
            }
            i += 1;
        }
        return error.PreconditionNotMet;
    }

    pub fn deleteContainedEntities(self: *DataReader) !void {
        self.registry_lock.lock();
        defer self.registry_lock.unlock();

        for (self.read_conditions.items) |cond| {
            if (cond.condition.waitset) |ws| {
                ws.detachCondition(&cond.condition);
            }
            if (cond.condition.kind == .query_condition) {
                const qc: *QueryCondition = @ptrCast(@alignCast(cond));
                self.subscriber.allocator.destroy(qc);
            } else {
                self.subscriber.allocator.destroy(cond);
            }
        }
        self.read_conditions.clearRetainingCapacity();
    }

    pub fn createReadCondition(self: *DataReader, sample_states: SampleInfo.SampleStateMask, view_states: SampleInfo.ViewStateMask, instance_states: SampleInfo.InstanceStateMask) !*Condition.ReadCondition {
        const rc = try self.subscriber.allocator.create(Condition.ReadCondition);
        errdefer self.subscriber.allocator.destroy(rc);
        rc.* = Condition.ReadCondition.init(self, sample_states, view_states, instance_states);

        self.registry_lock.lock();
        defer self.registry_lock.unlock();

        try self.read_conditions.append(self.subscriber.allocator, rc);
        return rc;
    }

    pub fn createQueryCondition(self: *DataReader, sample_states: SampleInfo.SampleStateMask, view_states: SampleInfo.ViewStateMask, instance_states: SampleInfo.InstanceStateMask, query_expression: []const u8) !*Condition.QueryCondition {
        const qc = try self.subscriber.allocator.create(Condition.QueryCondition);
        errdefer self.subscriber.allocator.destroy(qc);
        qc.* = Condition.QueryCondition.init(self, sample_states, view_states, instance_states, query_expression);

        self.registry_lock.lock();
        defer self.registry_lock.unlock();

        try self.read_conditions.append(self.subscriber.allocator, &qc.read_condition);
        return qc;
    }

    /// @brief Process heartbeat.
    /// @brief Process HeartbeatFrag.
    pub fn processHeartbeatFrag(self: *DataReader, writer_guid: rtps.types.GUID_t, hf: rtps.Submessage.HeartbeatFrag) !void {
        if (hf.reader_id.entity_kind != rtps.types.EntityId_t.unknown.entity_kind and
            hf.reader_id.entity_key[0] != self.entity_id.entity_key[0])
        {
            return;
        }

        const current_time = @as(i64, @intCast(GetTickCount64()));
        self.updateLiveliness(writer_guid, current_time);

        self.cache_mutex.lock();
        defer self.cache_mutex.unlock();

        var found = false;
        var first_missing_frag: ?u32 = null;
        var missing_frags_count: u32 = 0;
        var frag_bitmap = std.mem.zeroes([8]u32);

        {
            self.history_cache.acquireLock();
            defer self.history_cache.releaseLock();

            for (self.history_cache.partial_samples.items) |*partial| {
                if (partial.sequence_number.high == hf.writer_sn.high and partial.sequence_number.low == hf.writer_sn.low and
                    std.meta.eql(partial.writer_guid, writer_guid))
                {
                    found = true;
                    var i: u32 = 1; // Fragments are 1-indexed
                    while (i <= hf.last_fragment_num and i <= 64) : (i += 1) {
                        const mask = @as(u64, 1) << @intCast(i - 1);
                        if ((partial.received_frags & mask) == 0) {
                            if (first_missing_frag == null) {
                                first_missing_frag = i;
                            }
                            const offset = i - first_missing_frag.?;
                            if (offset < 256) {
                                const long_idx = offset / 32;
                                const bit_idx = offset % 32;
                                frag_bitmap[long_idx] |= (@as(u32, 1) << @as(u5, @intCast(bit_idx)));
                                missing_frags_count = @max(missing_frags_count, offset + 1);
                            }
                        }
                    }
                    break;
                }
            }
        }

        if (found and missing_frags_count > 0 and first_missing_frag != null) {
            self.sendNackFrag(writer_guid, hf.writer_sn, first_missing_frag.?, missing_frags_count, frag_bitmap) catch {};
        }
    }

    pub fn processHeartbeat(self: *DataReader, writer_guid: rtps.types.GUID_t, hb: rtps.Submessage.Heartbeat) !void {
        if (hb.reader_id.entity_kind != rtps.types.EntityId_t.unknown.entity_kind and
            hb.reader_id.entity_key[0] != self.entity_id.entity_key[0])
        {
            return;
        }

        const current_time = @as(i64, @intCast(getTickCount64()));
        self.updateLiveliness(writer_guid, current_time);

        var missing_base: ?u32 = null;
        var missing_bits: u32 = 0;
        var bitmap: [8]u32 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };

        self.history_cache.acquireLock();

        const start = hb.first_sn.low;
        const end = hb.last_sn.low;

        if (start <= end) {
            var i = start;
            while (i <= end) : (i += 1) {
                const sn = rtps.types.SequenceNumber_t{ .high = 0, .low = i };
                var found = false;
                if (self.history_cache.global_count > 0) {
                    var current = self.history_cache.global_head;
                    while (current) |node| : (current = node.global_next) {
                        const cache_sn = node.change.sequence_number;
                        const cache_guid = node.change.writer_guid;
                        if (cache_sn.low == sn.low and std.meta.eql(cache_guid, writer_guid)) {
                            found = true;
                            break;
                        }
                    }
                }

                if (!found) {
                    var partial_found = false;
                    for (self.history_cache.partial_samples.items) |*partial| {
                        if (partial.sequence_number.low == sn.low and std.meta.eql(partial.writer_guid, writer_guid)) {
                            partial_found = true;

                            const max_frag_size = 1024;
                            const total_frags = (partial.buffer.len + max_frag_size - 1) / max_frag_size;

                            var frag_bitmap: [8]u32 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
                            var missing_frags_count: u32 = 0;
                            var first_missing_frag: ?u32 = null;

                            var frag_idx: u32 = 0;
                            while (frag_idx < total_frags) : (frag_idx += 1) {
                                const frag_mask = @as(u64, 1) << @intCast(frag_idx);
                                if ((partial.received_frags & frag_mask) == 0) {
                                    if (first_missing_frag == null) first_missing_frag = frag_idx;

                                    const diff = frag_idx - first_missing_frag.?;
                                    if (diff < 256) {
                                        const long_idx = diff / 32;
                                        const bit_idx = diff % 32;
                                        frag_bitmap[long_idx] |= (@as(u32, 1) << @as(u5, @intCast(bit_idx)));
                                        missing_frags_count = @max(missing_frags_count, diff + 1);
                                    }
                                }
                            }

                            if (missing_frags_count > 0 and first_missing_frag != null) {
                                self.history_cache.releaseLock();
                                self.sendNackFrag(writer_guid, sn, first_missing_frag.? + 1, missing_frags_count, frag_bitmap) catch {};
                                return; // We'll handle other missing SNs on the next heartbeat for simplicity
                            }
                            break;
                        }
                    }

                    if (!partial_found) {
                        if (missing_base == null) {
                            missing_base = i;
                        }
                        const offset = i - missing_base.?;
                        if (offset < 256) {
                            const long_idx = offset / 32;
                            const bit_idx = offset % 32;
                            bitmap[long_idx] |= (@as(u32, 1) << @as(u5, @intCast(bit_idx)));
                            missing_bits = @max(missing_bits, offset + 1);
                        }
                    }
                }
            }
        }

        self.history_cache.releaseLock();

        const base = missing_base orelse (end + 1);
        try self.sendAckNack(writer_guid, base, missing_bits, bitmap);
    }

    /// @brief Send ack nack.
    fn sendAckNack(self: *DataReader, writer_guid: rtps.types.GUID_t, base_low: u32, num_bits: u32, bitmap: [8]u32) !void {
        var msg_buf: [128]u8 = undefined;
        var msg_ser = Serializer.init(&msg_buf, .Little);

        const header = rtps.Message.Header{
            .protocol = rtps.Message.Header.rtps_magic,
            .version = rtps.types.ProtocolVersion_t.current,
            .vendor_id = rtps.types.vendor_ddz,
            .guid_prefix = self.subscriber.participant.guid_prefix,
        };
        const header_len = try header.serialize(&msg_buf);
        msg_ser.pos = header_len;

        const num_longs = (num_bits + 31) / 32;
        const an_len: u16 = @intCast(24 + (num_longs * 4));
        const an_header: u32 = (@as(u32, an_len) << 16) | (@as(u32, 0x01) << 8) | @as(u32, @backingInt(rtps.Submessage.SubmessageKind.ACKNACK));
        try msg_ser.serialize(an_header);

        try msg_ser.serialize(self.entity_id); // readerId
        try msg_ser.serialize(writer_guid.entity_id); // writerId

        try msg_ser.serialize(rtps.types.SequenceNumber_t{ .high = 0, .low = base_low });
        try msg_ser.serialize(num_bits);

        var i: u32 = 0;
        while (i < num_longs) : (i += 1) {
            try msg_ser.serialize(bitmap[i]);
        }

        try msg_ser.serialize(@as(rtps.types.Count_t, @intCast(self.acknack_count)));
        self.acknack_count += 1;

        const packet = msg_buf[0..msg_ser.pos];

        self.subscriber.participant.registry_lock.lockShared();
        const opt_locs = self.subscriber.participant.discovered_participants.items(.metatraffic_unicast_locator);
        self.subscriber.participant.registry_lock.unlockShared();
        for (opt_locs) |opt_loc| {
            if (opt_loc) |loc| {
                _ = try self.subscriber.participant.spdp_socket.sendTo(packet, loc);
            }
        }
    }
    /// @brief Send NackFrag.
    fn sendNackFrag(self: *DataReader, writer_guid: rtps.types.GUID_t, writer_sn: rtps.types.SequenceNumber_t, base_frag: u32, num_bits: u32, bitmap: [8]u32) !void {
        var msg_buf: [128]u8 = undefined;
        var msg_ser = Serializer.init(&msg_buf, .Little);

        const header = rtps.Message.Header{
            .protocol = rtps.Message.Header.rtps_magic,
            .version = rtps.types.ProtocolVersion_t.current,
            .vendor_id = rtps.types.vendor_ddz,
            .guid_prefix = self.subscriber.participant.guid_prefix,
        };
        const header_len = try header.serialize(&msg_buf);
        msg_ser.pos = header_len;

        const num_longs = (num_bits + 31) / 32;
        const an_len: u16 = @intCast(28 + (num_longs * 4));
        const an_header: u32 = (@as(u32, an_len) << 16) | (@as(u32, 0x01) << 8) | @as(u32, @backingInt(rtps.Submessage.SubmessageKind.NACK_FRAG));
        try msg_ser.serialize(an_header);

        try msg_ser.serialize(self.entity_id); // readerId
        try msg_ser.serialize(writer_guid.entity_id); // writerId
        try msg_ser.serialize(writer_sn);

        try msg_ser.serialize(rtps.types.SequenceNumber_t{ .high = 0, .low = base_frag });
        try msg_ser.serialize(num_bits);

        var i: u32 = 0;
        while (i < num_longs) : (i += 1) {
            try msg_ser.serialize(bitmap[i]);
        }

        try msg_ser.serialize(@as(rtps.types.Count_t, @intCast(self.acknack_count)));
        self.acknack_count += 1;

        const packet = msg_buf[0..msg_ser.pos];

        self.subscriber.participant.registry_lock.lockShared();
        const opt_locs = self.subscriber.participant.discovered_participants.items(.metatraffic_unicast_locator);
        self.subscriber.participant.registry_lock.unlockShared();
        for (opt_locs) |opt_loc| {
            if (opt_loc) |loc| {
                _ = try self.subscriber.participant.spdp_socket.sendTo(packet, loc);
            }
        }
    }

    /// @brief Read data samples without removing them.
    pub fn getInstanceHandle(self: *DataReader) [16]u8 {
        return self.entity.getInstanceHandle();
    }

    pub fn getStatusCondition(self: *DataReader) !*StatusCondition {
        return self.entity.getStatusCondition();
    }

    pub fn enable(self: *DataReader) !void {
        return self.entity.enable();
    }

    pub fn enableImpl(ptr: *anyopaque) anyerror!void {
        _ = ptr; // No specific reader enable logic for now
    }

    pub fn isOwner(self: *DataReader, handle: rtps.types.InstanceHandle_t, writer_guid: rtps.types.GUID_t, current_time: i64) !bool {
        if (self.qos.ownership.kind != .exclusive) return true;

        if (self.subscriber.participant.findRemoteWriterData(writer_guid)) |rwd| {
            const current_owner = self.instance_owners.get(handle);
            if (current_owner) |owner_guid| {
                if (std.meta.eql(owner_guid, writer_guid)) {
                    return true;
                }

                if (self.subscriber.participant.findRemoteWriterData(owner_guid)) |od| {
                    const last_liveliness = self.writer_liveliness.get(owner_guid) orelse 0;
                    const lease_ms = @as(i64, od.liveliness_lease_duration) * 1000;
                    if (current_time - last_liveliness <= lease_ms) {
                        if (rwd.ownership_strength < od.ownership_strength) {
                            return false;
                        } else if (rwd.ownership_strength == od.ownership_strength) {
                            var writer_guid_bytes: [16]u8 = undefined;
                            @memcpy(writer_guid_bytes[0..12], writer_guid.prefix[0..12]);
                            @memcpy(writer_guid_bytes[12..15], writer_guid.entity_id.entity_key[0..3]);
                            writer_guid_bytes[15] = writer_guid.entity_id.entity_kind;

                            var owner_guid_bytes: [16]u8 = undefined;
                            @memcpy(owner_guid_bytes[0..12], owner_guid.prefix[0..12]);
                            @memcpy(owner_guid_bytes[12..15], owner_guid.entity_id.entity_key[0..3]);
                            owner_guid_bytes[15] = owner_guid.entity_id.entity_kind;

                            if (!std.mem.lessThan(u8, &writer_guid_bytes, &owner_guid_bytes)) {
                                return false;
                            }
                        }
                    }
                }
            }
            try self.instance_owners.put(self.subscriber.participant.allocator, handle, writer_guid);
            return true;
        }
        return false;
    }

    pub fn read(self: *DataReader, comptime T: type, max_samples: usize, sample_states: SampleInfo.SampleStateMask, view_states: SampleInfo.ViewStateMask, instance_states: SampleInfo.InstanceStateMask) ![]SampleInfo.DataSample(T) {
        return self.readOrTake(T, max_samples, sample_states, view_states, instance_states, false, false, null);
    }

    /// @brief Take data samples, removing them from the cache.
    pub fn take(self: *DataReader, comptime T: type, max_samples: usize, sample_states: SampleInfo.SampleStateMask, view_states: SampleInfo.ViewStateMask, instance_states: SampleInfo.InstanceStateMask) ![]SampleInfo.DataSample(T) {
        return self.readOrTake(T, max_samples, sample_states, view_states, instance_states, true, true, null);
    }

    /// @brief Read with condition.
    pub fn readWithCondition(self: *DataReader, comptime T: type, max_samples: usize, condition: *Condition.ReadCondition) ![]SampleInfo.DataSample(T) {
        return self.readOrTake(T, max_samples, condition.sample_states, condition.view_states, condition.instance_states, false, false, condition);
    }

    /// @brief Take with condition.
    pub fn takeWithCondition(self: *DataReader, comptime T: type, max_samples: usize, condition: *Condition.ReadCondition) ![]SampleInfo.DataSample(T) {
        return self.readOrTake(T, max_samples, condition.sample_states, condition.view_states, condition.instance_states, true, true, condition);
    }

    /// @brief Read the next, non-previously accessed sample.
    pub fn readNextSample(self: *DataReader, comptime T: type) !?SampleInfo.DataSample(T) {
        const samples = try self.readOrTake(T, 1, .{ .not_read = true }, .any, .any, false, false, null);
        defer self.subscriber.allocator.free(samples);
        if (samples.len > 0) {
            return samples[0];
        }
        return null;
    }

    /// @brief Take the next, non-previously accessed sample.
    /// @brief Check if there is data matching the conditions.
    pub fn hasData(self: *DataReader, sample_states: SampleInfo.SampleStateMask, view_states: SampleInfo.ViewStateMask, instance_states: SampleInfo.InstanceStateMask, query_condition: ?*QueryCondition) bool {
        while (self.history_cache.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
        defer self.history_cache.lock.store(false, .release);

        var current = self.history_cache.global_head;
        while (current) |node| {
            var view_st: SampleInfo.ViewStateKind = .not_new;
            var inst_st: SampleInfo.InstanceStateKind = .alive;

            if (self.history_cache.instance_map.get(node.change.instance_handle)) |inst_ptrs| {
                view_st = inst_ptrs.view_state;
                inst_st = inst_ptrs.instance_state;
            }

            const s_match = (node.sample_state == .read and sample_states.read) or
                (node.sample_state == .not_read and sample_states.not_read);
            const v_match = (view_st == .new and view_states.new) or
                (view_st == .not_new and view_states.not_new);
            const i_match = (inst_st == .alive and instance_states.alive) or
                (inst_st == .not_alive_disposed and instance_states.not_alive_disposed) or
                (inst_st == .not_alive_no_writers and instance_states.not_alive_no_writers);

            if (s_match and v_match and i_match) {
                if (query_condition) |_| {
                    if (node.change.kind == .ALIVE) {
                        // For query conditions, we need to know the type to deserialize and evaluate.
                        // However, we can't do that generically here without comptime T.
                        // Wait! The QueryCondition should just return true here and let take() do the filtering!
                        // Actually, this could cause false wakeups, but it prevents deadlocks.
                        return true;
                    }
                }
                return true;
            }
            current = node.global_next;
        }
        return false;
    }

    pub fn takeNextSample(self: *DataReader, comptime T: type) !?SampleInfo.DataSample(T) {
        const samples = try self.readOrTake(T, 1, .{ .not_read = true }, .any, .any, true, false, null);
        defer self.subscriber.allocator.free(samples);
        if (samples.len > 0) {
            return samples[0];
        }
        return null;
    }

    /// @brief Return loaned data.
    pub fn returnLoan(self: *DataReader, comptime T: type, samples: []SampleInfo.DataSample(T)) void {
        self.registry_lock.lock();
        defer self.registry_lock.unlock();

        // or just clear the array if it's the exact same length (simplified).
        var i: usize = 0;
        while (i < self.loaned_nodes.items.len) {
            const node = self.loaned_nodes.items[i];
            var found = false;
            for (samples) |sample| {
                if (std.mem.eql(u8, &sample.info.instance_handle, &node.change.instance_handle) and
                    sample.info.source_timestamp == node.change.source_timestamp_ms)
                {
                    found = true;
                    break;
                }
            }

            if (found) {
                self.history_cache.freeNodeMemory(node);
                self.history_cache.node_pool.destroy(node);
                _ = self.loaned_nodes.swapRemove(i);
            } else {
                i += 1;
            }
        }

        self.subscriber.allocator.free(samples);
    }

    fn readOrTake(self: *DataReader, comptime T: type, max_samples: usize, sample_states: SampleInfo.SampleStateMask, view_states: SampleInfo.ViewStateMask, instance_states: SampleInfo.InstanceStateMask, is_take: bool, is_loan: bool, condition: ?*Condition.ReadCondition) ![]SampleInfo.DataSample(T) {
        self.history_cache.enforceLifecycleQos();

        var result: std.ArrayListUnmanaged(SampleInfo.DataSample(T)) = .empty;
        errdefer result.deinit(self.subscriber.allocator);

        while (self.history_cache.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
        defer self.history_cache.lock.store(false, .release);

        var current = self.history_cache.global_head;
        while (current) |node| {
            const next_node = node.global_next;

            var view_st: SampleInfo.ViewStateKind = .not_new;
            var inst_st: SampleInfo.InstanceStateKind = .alive;

            if (self.history_cache.instance_map.get(node.change.instance_handle)) |inst_ptrs| {
                view_st = inst_ptrs.view_state;
                inst_st = inst_ptrs.instance_state;
            }

            const s_match = (node.sample_state == .read and sample_states.read) or
                (node.sample_state == .not_read and sample_states.not_read);
            const v_match = (view_st == .new and view_states.new) or
                (view_st == .not_new and view_states.not_new);
            const i_match = (inst_st == .alive and instance_states.alive) or
                (inst_st == .not_alive_disposed and instance_states.not_alive_disposed) or
                (inst_st == .not_alive_no_writers and instance_states.not_alive_no_writers);

            var query_match = true;
            if (condition) |cond| {
                if (cond.condition.kind == .query_condition) {
                    const qc: *Condition.QueryCondition = @ptrCast(@alignCast(cond));
                    query_match = Sql92.evaluateWithParams(T, null, qc.query_expression, qc.get_query_parameters());
                }
            }

            if (s_match and v_match and i_match) {
                var des = Deserializer.init(node.change.data_value, .Little);
                const data_val = if (json.hasWireHeader(node.change.data_value) or (self.qos.representation.hasJson() and node.change.data_value.len > 0 and (node.change.data_value[0] == '{' or node.change.data_value[0] == '[')))
                    json.deserializeLeaky(T, self.subscriber.allocator, node.change.data_value, .{}) catch |err| {
                        std.log.warn("Deserialization Error in DataReader: {s}", .{@errorName(err)});
                        current = next_node;
                        continue;
                    }
                else
                    des.deserialize(T) catch |err| {
                        std.log.warn("Deserialization Error in DataReader: {s}", .{@errorName(err)});
                        current = next_node;
                        continue;
                    };

                if (condition) |cond| {
                    if (cond.condition.kind == .query_condition) {
                        const qc: *Condition.QueryCondition = @ptrCast(@alignCast(cond));
                        query_match = Sql92.evaluateWithParams(T, data_val, qc.query_expression, qc.get_query_parameters());
                    }
                }
                if (self.filter_expression) |fe| {
                    if (fe.len > 0 and !Sql92.evaluateWithParams(T, data_val, fe, self.get_expression_parameters())) {
                        query_match = false;
                    }
                }
                if (query_match) {
                    try result.append(self.subscriber.allocator, .{
                        .data = data_val,
                        .info = .{
                            .sample_state = node.sample_state,
                            .view_state = view_st,
                            .instance_state = inst_st,
                            .disposed_generation_count = if (self.history_cache.instance_map.get(node.change.instance_handle)) |inst| inst.disposed_generation_count else 0,
                            .no_writers_generation_count = if (self.history_cache.instance_map.get(node.change.instance_handle)) |inst| inst.no_writers_generation_count else 0,
                            .sample_rank = 0,
                            .generation_rank = 0,
                            .absolute_generation_rank = 0,
                            .source_timestamp = node.change.source_timestamp_ms,
                            .instance_handle = node.change.instance_handle,
                            .publication_handle = std.mem.zeroes([16]u8),
                            .valid_data = true,
                        },
                    });

                    if (!is_take) {
                        node.sample_state = .read;
                    }

                    if (is_take) {
                        if (is_loan) {
                            self.history_cache.unlinkNode(node);
                            self.registry_lock.lock();
                            self.loaned_nodes.append(self.subscriber.allocator, node) catch |err| {
                                std.log.warn("Failed to record loaned node: {s}", .{@errorName(err)});
                                self.history_cache.removeNode(node);
                            };
                            self.registry_lock.unlock();
                        } else {
                            self.history_cache.removeNode(node);
                        }
                    }

                    if (result.items.len >= max_samples) {
                        break;
                    }
                }
            }

            current = next_node;
        }

        return result.toOwnedSlice(self.subscriber.allocator);
    }

    fn updateLiveliness(self: *DataReader, writer_guid: rtps.types.GUID_t, current_time: i64) void {
        self.cache_mutex.lock();
        defer self.cache_mutex.unlock();

        const was_present = self.writer_liveliness.contains(writer_guid);
        self.writer_liveliness.put(self.subscriber.participant.allocator, writer_guid, current_time) catch return;

        if (!was_present) {
            var is_matched = false;

            // Local writers are natively matched automatically without being in matched_writers list
            if (std.mem.eql(u8, &self.subscriber.participant.guid_prefix, &writer_guid.prefix)) {
                is_matched = true;
            } else {
                for (self.matched_writers.items) |guid| {
                    if (std.meta.eql(guid, writer_guid)) {
                        is_matched = true;
                        break;
                    }
                }
            }

            if (is_matched) {
                self.liveliness_changed_status.alive_count += 1;
                self.liveliness_changed_status.alive_count_change += 1;
                @memcpy(&self.liveliness_changed_status.last_publication_handle, &writer_guid.prefix ++ writer_guid.entity_id.entity_key ++ [_]u8{writer_guid.entity_id.entity_kind});
                self.notifyStatusChange(.liveliness_changed);
            }
        }
    }

    pub fn processData(self: *DataReader, writer_guid: rtps.types.GUID_t, data_submsg: rtps.Submessage.Data) !void {
        // Builtin Writers explicitly mapped to Builtin Readers
        if (std.meta.eql(writer_guid.entity_id, rtps.types.EntityId_t.sedp_pub_writer)) {
            if (!std.meta.eql(self.entity_id, rtps.types.EntityId_t.sedp_pub_reader)) return;
        } else if (std.meta.eql(writer_guid.entity_id, rtps.types.EntityId_t.sedp_sub_writer)) {
            if (!std.meta.eql(self.entity_id, rtps.types.EntityId_t.sedp_sub_reader)) return;
        } else if (std.meta.eql(writer_guid.entity_id, rtps.types.EntityId_t.type_lookup_req_writer)) {
            if (!std.meta.eql(self.entity_id, rtps.types.EntityId_t.type_lookup_req_reader)) return;
        } else if (std.meta.eql(writer_guid.entity_id, rtps.types.EntityId_t.type_lookup_rep_writer)) {
            if (!std.meta.eql(self.entity_id, rtps.types.EntityId_t.type_lookup_rep_reader)) return;
        } else if (writer_guid.entity_id.entity_kind == 0xc2) {
            // Unknown built-in writer, drop
            return;
        } else {
            // User Data should not go to built-in readers
            if (self.entity_id.entity_kind == 0xc7) return;
        }

        // Only accept if it matches our reader ID or if it's meant for all readers
        if (data_submsg.reader_id.entity_kind != rtps.types.EntityId_t.unknown.entity_kind and
            data_submsg.reader_id.entity_key[0] != self.entity_id.entity_key[0])
        {
            return;
        }

        self.registry_lock.lock();
        var found = false;
        var incompatible = false;
        for (self.matched_writers.items) |guid| {
            if (std.meta.eql(guid, writer_guid)) {
                found = true;
                break;
            }
        }
        if (!found) {
            for (self.incompatible_writers.items) |guid| {
                if (std.meta.eql(guid, writer_guid)) {
                    incompatible = true;
                    break;
                }
            }
        }
        if (!found and !incompatible) {
            if (self.subscriber.participant.findRemoteWriterData(writer_guid)) |rwd| {
                if (!std.mem.eql(u8, rwd.topic_name, self.topic.name)) {
                    self.registry_lock.unlock();
                    return;
                }
                if (!Qos.matchPartition(rwd.partition_name, self.subscriber.qos.partition.name)) {
                    self.registry_lock.unlock();
                    return;
                }
                if (Qos.checkCompatibility(rwd, self.qos)) |policy_id| {
                    self.incompatible_writers.append(self.subscriber.participant.allocator, writer_guid) catch |err| {
                        std.log.warn("Failed to record incompatible writer: {s}", .{@errorName(err)});
                    };

                    self.requested_incompatible_qos_status.total_count += 1;
                    self.requested_incompatible_qos_status.total_count_change += 1;
                    self.requested_incompatible_qos_status.last_policy_id = policy_id;
                    self.registry_lock.unlock();

                    self.notifyStatusChange(.requested_incompatible_qos);
                    return;
                }

                // XTypes Assignability Check
                if (rwd.type_object_cdr.len > 0 and self.topic.type_object_cdr.len > 0) {
                    const alloc = self.subscriber.participant.allocator;
                    const xt = xtypes;
                    var writer_type = xt.deserializeTypeObject(alloc, rwd.type_object_cdr) catch null;
                    var reader_type = xt.deserializeTypeObject(alloc, self.topic.type_object_cdr) catch null;
                    var assignable = true;
                    if (writer_type != null and reader_type != null) {
                        assignable = xt.TypeObject.isAssignable(reader_type.?, writer_type.?);
                    }
                    if (writer_type != null) writer_type.?.deinit(alloc);
                    if (reader_type != null) reader_type.?.deinit(alloc);

                    if (!assignable) {
                        self.incompatible_writers.append(self.subscriber.participant.allocator, writer_guid) catch |err| {
                            std.log.warn("Failed to record incompatible writer: {s}", .{@errorName(err)});
                        };
                        self.registry_lock.unlock();
                        return;
                    }
                }

                self.matched_writers.append(self.subscriber.participant.allocator, writer_guid) catch |err| {
                    std.log.warn("Failed to record matched writer: {s}", .{@errorName(err)});
                };
                self.subscription_matched_status.total_count += 1;
                self.subscription_matched_status.total_count_change += 1;
                self.subscription_matched_status.current_count += 1;
                self.subscription_matched_status.current_count_change += 1;
                self.registry_lock.unlock();
                self.notifyStatusChange(.subscription_matched);

                // Don't return, allow process to continue
                self.registry_lock.lock();
            } else {
                // If we don't have SEDP data, assume compatible temporarily to bootstrap
                self.matched_writers.append(self.subscriber.participant.allocator, writer_guid) catch |err| {
                    std.log.warn("Failed to record matched writer: {s}", .{@errorName(err)});
                };
                self.subscription_matched_status.total_count += 1;
                self.subscription_matched_status.total_count_change += 1;
                self.subscription_matched_status.current_count += 1;
                self.subscription_matched_status.current_count_change += 1;
                self.registry_lock.unlock();
                self.notifyStatusChange(.subscription_matched);
                self.registry_lock.lock();
            }
        }
        if (incompatible) {
            self.registry_lock.unlock();
            return; // drop sample
        }
        self.registry_lock.unlock();

        const handle = data_submsg.instance_handle orelse std.mem.zeroes([16]u8);

        const current_time = @as(i64, @intCast(getTickCount64()));
        self.updateLiveliness(writer_guid, current_time);

        self.cache_mutex.lock();
        defer self.cache_mutex.unlock();

        if (!try self.isOwner(handle, writer_guid, current_time)) return;

        // TimeBasedFilter QoS
        const now = @as(i64, @intCast(getTickCount64()));
        self.deadline_lock.lock();
        self.last_receive_time.put(self.subscriber.participant.allocator, handle, now) catch {};
        self.deadline_lock.unlock();
        if (self.qos.time_based_filter.minimum_separation_ms > 0) {
            if (self.time_based_filter_state.get(handle)) |last_ts| {
                if (now - last_ts < self.qos.time_based_filter.minimum_separation_ms) {
                    return; // Drop sample
                }
            }
            try self.time_based_filter_state.put(self.subscriber.allocator, handle, now);
        }

        if (data_submsg.writer_sn.low > self.highest_received_sn + 1 and self.highest_received_sn != 0) {
            const lost = data_submsg.writer_sn.low - self.highest_received_sn - 1;
            self.total_lost += lost;
            if (self.listener) |l| {
                if (l.on_sample_lost) |cb| {
                    cb(l.context, self, self.total_lost);
                }
            }
        }
        if (data_submsg.writer_sn.low > self.highest_received_sn) {
            self.highest_received_sn = data_submsg.writer_sn.low;
        }

        if (data_submsg.coherent_set_id) |cs_id| {
            if (data_submsg.serialized_payload.len == 0) {
                // End Coherent Set marker
                if (self.subscriber.qos.presentation.access_scope == .group and self.subscriber.qos.presentation.coherent_access) {
                    self.subscriber.releaseGroupCoherentSet(cs_id);
                } else {
                    self.history_cache.releaseCoherentSet(cs_id);
                    self.notifyStatusChange(.data_available);

                    self.triggerReadConditions();
                }
                return;
            }
        }

        var change_kind: ChangeKind = .ALIVE;
        if (data_submsg.status_info) |si| {
            if ((si[3] & 0x01) != 0) {
                change_kind = .NOT_ALIVE_DISPOSED;
            } else if ((si[3] & 0x02) != 0) {
                change_kind = .NOT_ALIVE_UNREGISTERED;
            }
        }
        self.history_cache.addChange(.{
            .kind = change_kind,
            .writer_guid = writer_guid,
            .instance_handle = handle,
            .sequence_number = data_submsg.writer_sn,
            .data_value = data_submsg.serialized_payload,
            .coherent_set_id = data_submsg.coherent_set_id orelse 0,
            .withheld = data_submsg.coherent_set_id != null,
            .related_sample_identity = data_submsg.related_sample_identity,
        }) catch |err| {
            if (err == error.ResourceLimitReached) {
                self.total_rejected += 1;
                if (self.listener) |l| {
                    if (l.on_sample_rejected) |cb| {
                        cb(l.context, self, self.sample_rejected_status);
                    }
                }
            }
            return;
        };

        self.notifyStatusChange(.data_available);

        self.triggerReadConditions();
    }

    /// @brief Trigger read conditions.
    pub fn triggerReadConditions(self: *DataReader) void {
        self.registry_lock.lock();
        defer self.registry_lock.unlock();
        for (self.read_conditions.items) |rc| {
            rc.condition.setTriggerValue(true);
        }
    }

    /// @brief Process data frag.
    pub fn processDataFrag(self: *DataReader, writer_guid: rtps.types.GUID_t, frag_submsg: rtps.Submessage.DataFrag) !void {
        // Builtin Writers explicitly mapped to Builtin Readers
        if (std.meta.eql(writer_guid.entity_id, rtps.types.EntityId_t.sedp_pub_writer)) {
            if (!std.meta.eql(self.entity_id, rtps.types.EntityId_t.sedp_pub_reader)) return;
        } else if (std.meta.eql(writer_guid.entity_id, rtps.types.EntityId_t.sedp_sub_writer)) {
            if (!std.meta.eql(self.entity_id, rtps.types.EntityId_t.sedp_sub_reader)) return;
        } else if (std.meta.eql(writer_guid.entity_id, rtps.types.EntityId_t.type_lookup_req_writer)) {
            if (!std.meta.eql(self.entity_id, rtps.types.EntityId_t.type_lookup_req_reader)) return;
        } else if (std.meta.eql(writer_guid.entity_id, rtps.types.EntityId_t.type_lookup_rep_writer)) {
            if (!std.meta.eql(self.entity_id, rtps.types.EntityId_t.type_lookup_rep_reader)) return;
        } else if (writer_guid.entity_id.entity_kind == 0xc2) {
            // Unknown built-in writer, drop
            return;
        } else {
            // User Data should not go to built-in readers
            if (self.entity_id.entity_kind == 0xc7) return;
        }

        if (frag_submsg.reader_id.entity_kind != rtps.types.EntityId_t.unknown.entity_kind and
            frag_submsg.reader_id.entity_key[0] != self.entity_id.entity_key[0])
        {
            return;
        }

        self.registry_lock.lock();
        var found = false;
        var incompatible = false;
        for (self.matched_writers.items) |guid| {
            if (std.meta.eql(guid, writer_guid)) {
                found = true;
                break;
            }
        }
        if (!found) {
            for (self.incompatible_writers.items) |guid| {
                if (std.meta.eql(guid, writer_guid)) {
                    incompatible = true;
                    break;
                }
            }
        }
        if (!found and !incompatible) {
            if (self.subscriber.participant.findRemoteWriterData(writer_guid)) |rwd| {
                if (!std.mem.eql(u8, rwd.topic_name, self.topic.name)) {
                    self.registry_lock.unlock();
                    return;
                }
                if (!Qos.matchPartition(rwd.partition_name, self.subscriber.qos.partition.name)) {
                    self.registry_lock.unlock();
                    return;
                }
                if (Qos.checkCompatibility(rwd, self.qos)) |policy_id| {
                    self.incompatible_writers.append(self.subscriber.participant.allocator, writer_guid) catch {};

                    self.requested_incompatible_qos_status.total_count += 1;
                    self.requested_incompatible_qos_status.total_count_change += 1;
                    self.requested_incompatible_qos_status.last_policy_id = policy_id;
                    self.registry_lock.unlock();

                    self.notifyStatusChange(.requested_incompatible_qos);
                    return;
                }

                // XTypes Assignability Check
                if (rwd.type_object_cdr.len > 0 and self.topic.type_object_cdr.len > 0) {
                    const alloc = self.subscriber.participant.allocator;
                    const xt = xtypes;
                    var writer_type = xt.deserializeTypeObject(alloc, rwd.type_object_cdr) catch null;
                    var reader_type = xt.deserializeTypeObject(alloc, self.topic.type_object_cdr) catch null;
                    var assignable = true;
                    if (writer_type != null and reader_type != null) {
                        assignable = xt.TypeObject.isAssignable(reader_type.?, writer_type.?);
                    }
                    if (writer_type != null) writer_type.?.deinit(alloc);
                    if (reader_type != null) reader_type.?.deinit(alloc);

                    if (!assignable) {
                        self.incompatible_writers.append(self.subscriber.participant.allocator, writer_guid) catch {};
                        self.registry_lock.unlock();
                        return;
                    }
                }

                if (self.matched_writers.append(self.subscriber.participant.allocator, writer_guid)) |_| {
                    self.subscription_matched_status.total_count += 1;
                    self.subscription_matched_status.total_count_change += 1;
                    self.subscription_matched_status.current_count += 1;
                    self.subscription_matched_status.current_count_change += 1;
                    self.registry_lock.unlock();
                    self.notifyStatusChange(.subscription_matched);
                    self.registry_lock.lock();
                } else |_| {}
            } else {
                // If we don't have SEDP data, assume compatible temporarily to bootstrap
                if (self.matched_writers.append(self.subscriber.participant.allocator, writer_guid)) |_| {
                    self.subscription_matched_status.total_count += 1;
                    self.subscription_matched_status.total_count_change += 1;
                    self.subscription_matched_status.current_count += 1;
                    self.subscription_matched_status.current_count_change += 1;
                    self.registry_lock.unlock();
                    self.notifyStatusChange(.subscription_matched);
                    self.registry_lock.lock();
                } else |_| {}
            }
        }
        if (incompatible) {
            self.registry_lock.unlock();
            return; // drop sample
        }
        self.registry_lock.unlock();

        const current_time = @as(i64, @intCast(GetTickCount64()));
        self.updateLiveliness(writer_guid, current_time);

        self.cache_mutex.lock();
        defer self.cache_mutex.unlock();

        // Instance handle is usually derived from the sample or DataFrag might not have it if not keyed.
        // For simplicity, we assume 0 or need to parse key hash from inline Qos.
        const handle = std.mem.zeroes([16]u8);
        if (!try self.isOwner(handle, writer_guid, current_time)) return;

        if (frag_submsg.writer_sn.low > self.highest_received_sn + 1 and self.highest_received_sn != 0) {
            const lost = frag_submsg.writer_sn.low - self.highest_received_sn - 1;
            self.total_lost += lost;
            if (self.listener) |l| {
                if (l.on_sample_lost) |cb| {
                    cb(l.context, self, self.total_lost);
                }
            }
        }
        if (frag_submsg.writer_sn.low > self.highest_received_sn) {
            self.highest_received_sn = frag_submsg.writer_sn.low;
        }

        const completed = self.history_cache.addFragment(.ALIVE, writer_guid, frag_submsg.writer_sn, frag_submsg.fragment_starting_num, frag_submsg.fragment_size, frag_submsg.sample_size, frag_submsg.serialized_payload) catch |err| {
            if (err == error.ResourceLimitReached) {
                self.total_rejected += 1;
                if (self.listener) |l| {
                    if (l.on_sample_rejected) |cb| {
                        cb(l.context, self, self.sample_rejected_status);
                    }
                }
            }
            return;
        };
        if (completed) {
            self.notifyStatusChange(.data_available);

            self.triggerReadConditions();
        }
    }

    /// @brief Retrieves the list of currently matched publications.
    pub fn getMatchedPublications(self: *DataReader, allocator: std.mem.Allocator) ![]rtps.types.InstanceHandle_t {
        self.registry_lock.lock();
        defer self.registry_lock.unlock();

        var handles = try allocator.alloc(rtps.types.InstanceHandle_t, self.matched_writers.items.len);
        for (self.matched_writers.items, 0..) |guid, i| {
            handles[i] = rtps.types.guidToInstanceHandle(guid);
        }
        return handles;
    }

    /// @brief Retrieves the data of the matched publication.
    pub fn getMatchedPublicationData(self: *DataReader, handle: rtps.types.InstanceHandle_t) !DiscoveredWriterData {
        const guid = rtps.types.instanceHandleToGuid(handle);

        self.registry_lock.lock();
        var found = false;
        for (self.matched_writers.items) |mw_guid| {
            if (std.meta.eql(mw_guid, guid)) {
                found = true;
                break;
            }
        }
        self.registry_lock.unlock();

        if (!found) return error.NotMatched;

        if (self.subscriber.participant.findRemoteWriterData(guid)) |data| {
            return data;
        }
        return error.NotFound;
    }

    /// @brief Match a local DataWriter and update subscription matched status.
    pub fn matchLocalWriter(self: *DataReader, writer: *DataWriter) !bool {
        if (self.entity_id.entity_kind >= 0xc0 or writer.entity_id.entity_kind >= 0xc0) return false;

        if (!std.mem.eql(u8, self.topic.name, writer.topic.name)) return false;
        if (self.topic.type_name.len > 0 and writer.topic.type_name.len > 0 and !std.mem.eql(u8, self.topic.type_name, writer.topic.type_name)) return false;
        if (!Qos.matchPartition(writer.publisher.qos.partition.name, self.subscriber.qos.partition.name)) return false;

        const writer_guid = rtps.types.GUID_t{
            .prefix = writer.publisher.participant.guid_prefix,
            .entity_id = writer.entity_id,
        };
        const writer_handle = rtps.types.guidToInstanceHandle(writer_guid);

        {
            self.subscriber.participant.registry_lock.lockShared();
            const is_ignored = self.subscriber.participant.ignored_publications.contains(writer_handle);
            self.subscriber.participant.registry_lock.unlockShared();
            if (is_ignored) return false;
        }

        if (Qos.checkCompatibility(writer.qos, self.qos)) |incompat_id| {
            self.registry_lock.lock();
            self.requested_incompatible_qos_status.total_count += 1;
            self.requested_incompatible_qos_status.total_count_change += 1;
            self.requested_incompatible_qos_status.last_policy_id = incompat_id;
            self.registry_lock.unlock();
            self.notifyStatusChange(.requested_incompatible_qos);
            return false;
        }

        self.registry_lock.lock();
        for (self.matched_writers.items) |mw| {
            if (std.meta.eql(mw, writer_guid)) {
                self.registry_lock.unlock();
                return true;
            }
        }

        try self.matched_writers.append(self.subscriber.participant.allocator, writer_guid);
        self.subscription_matched_status.total_count += 1;
        self.subscription_matched_status.total_count_change += 1;
        self.subscription_matched_status.current_count += 1;
        self.subscription_matched_status.current_count_change = 1;
        self.subscription_matched_status.last_publication_handle = writer_handle;
        self.registry_lock.unlock();

        self.notifyStatusChange(.subscription_matched);
        return true;
    }

    /// @brief Unmatch a local DataWriter.
    pub fn unmatchLocalWriter(self: *DataReader, writer: *DataWriter) void {
        const writer_guid = rtps.types.GUID_t{
            .prefix = writer.publisher.participant.guid_prefix,
            .entity_id = writer.entity_id,
        };
        self.registry_lock.lock();
        var found_idx: ?usize = null;
        for (self.matched_writers.items, 0..) |mw, i| {
            if (std.meta.eql(mw, writer_guid)) {
                found_idx = i;
                break;
            }
        }
        if (found_idx) |idx| {
            _ = self.matched_writers.swapRemove(idx);
            if (self.subscription_matched_status.current_count > 0) {
                self.subscription_matched_status.current_count -= 1;
            }
            self.subscription_matched_status.current_count_change = -1;
            self.subscription_matched_status.last_publication_handle = rtps.types.guidToInstanceHandle(writer_guid);
            self.registry_lock.unlock();
            self.notifyStatusChange(.subscription_matched);
        } else {
            self.registry_lock.unlock();
        }
    }

    /// @brief Match a remote DiscoveredWriterData and update subscription matched status.
    pub fn matchRemoteWriter(self: *DataReader, writer_data: DiscoveredWriterData) !bool {
        if (self.entity_id.entity_kind >= 0xc0 or writer_data.endpoint_guid.entity_id.entity_kind >= 0xc0) return false;

        if (!std.mem.eql(u8, self.topic.name, writer_data.topic_name)) return false;
        if (self.topic.type_name.len > 0 and writer_data.type_name.len > 0 and !std.mem.eql(u8, self.topic.type_name, writer_data.type_name)) return false;
        if (!Qos.matchPartition(writer_data.partition_name, self.subscriber.qos.partition.name)) return false;

        const writer_handle = rtps.types.guidToInstanceHandle(writer_data.endpoint_guid);
        {
            self.subscriber.participant.registry_lock.lockShared();
            const is_ignored = self.subscriber.participant.ignored_publications.contains(writer_handle);
            self.subscriber.participant.registry_lock.unlockShared();
            if (is_ignored) return false;
        }

        if (Qos.checkCompatibility(writer_data, self.qos)) |incompat_id| {
            self.registry_lock.lock();
            self.requested_incompatible_qos_status.total_count += 1;
            self.requested_incompatible_qos_status.total_count_change += 1;
            self.requested_incompatible_qos_status.last_policy_id = incompat_id;
            self.registry_lock.unlock();
            self.notifyStatusChange(.requested_incompatible_qos);
            return false;
        }

        self.registry_lock.lock();
        for (self.matched_writers.items) |mw| {
            if (std.meta.eql(mw, writer_data.endpoint_guid)) {
                self.registry_lock.unlock();
                return true;
            }
        }

        try self.matched_writers.append(self.subscriber.participant.allocator, writer_data.endpoint_guid);
        self.subscription_matched_status.total_count += 1;
        self.subscription_matched_status.total_count_change += 1;
        self.subscription_matched_status.current_count += 1;
        self.subscription_matched_status.current_count_change = 1;
        self.subscription_matched_status.last_publication_handle = writer_handle;
        self.registry_lock.unlock();

        self.notifyStatusChange(.subscription_matched);
        return true;
    }
};

test "DataReader initialization and processData" {
    var factory = DomainParticipantFactory.getInstance();
    var participant = try factory.createParticipant(0, null, std.testing.allocator);
    defer factory.deleteParticipant(participant, std.testing.allocator) catch {};

    var subscriber = try participant.createSubscriber(null);

    const topic = Topic.init("TestTopic", "TestType");
    const qos = ReaderQos{};
    const entity_id = rtps.types.EntityId_t.unknown;

    var reader = try subscriber.createDataReader(topic, qos, entity_id);

    // Mock DATA submessage
    const data_submsg = rtps.Submessage.Data{
        .header = undefined,
        .extra_flags = 0,
        .octets_to_inline_qos = 16,
        .reader_id = entity_id,
        .writer_id = rtps.types.EntityId_t.unknown,
        .writer_sn = .{ .high = 0, .low = 1 },
        .serialized_payload = "dummy_payload",
    };

    try reader.processData(rtps.types.GUID_t.unknown, data_submsg);

    const change = reader.history_cache.getChange(.{ .high = 0, .low = 1 });
    try std.testing.expect(change != null);
    try std.testing.expectEqualSlices(u8, "dummy_payload", change.?.data_value);
}

/// @brief Data reader listener structure.
pub const DataReaderListener = struct {
    context: ?*anyopaque = null,
    on_data_available: ?*const fn (context: ?*anyopaque, reader: *DataReader) void = null,
    on_sample_rejected: ?*const fn (context: ?*anyopaque, reader: *DataReader, status: SampleRejectedStatus) void = null,
    on_liveliness_changed: ?*const fn (context: ?*anyopaque, reader: *DataReader, status: LivelinessChangedStatus) void = null,
    on_requested_deadline_missed: ?*const fn (context: ?*anyopaque, reader: *DataReader, status: DeadlineMissedStatus) void = null,
    on_subscription_matched: ?*const fn (context: ?*anyopaque, reader: *DataReader, status: MatchedStatus) void = null,
    on_requested_incompatible_qos: ?*const fn (context: ?*anyopaque, reader: *DataReader, status: IncompatibleQosStatus) void = null,
    on_sample_lost: ?*const fn (context: ?*anyopaque, reader: *DataReader, lost_count: u32) void = null,
};

test "DataReader concurrent processData" {
    var factory = DomainParticipantFactory.getInstance();
    var participant = try factory.createParticipant(0, null, std.testing.allocator);
    defer factory.deleteParticipant(participant, std.testing.allocator) catch {};
    var subscriber = try participant.createSubscriber(null);
    const topic = Topic.init("ConcurrentTopic", "ConcurrentType");
    const qos = ReaderQos{ .history = .{ .depth = 100 } };
    const entity_id = rtps.types.EntityId_t.unknown;
    var reader = try subscriber.createDataReader(topic, qos, entity_id);

    const ThreadFunc = struct {
        fn run(r: *DataReader, writer_id: i32) void {
            var i: u32 = 0;
            while (i < 100) : (i += 1) {
                const data_submsg = rtps.Submessage.Data{
                    .header = undefined,
                    .extra_flags = 0,
                    .octets_to_inline_qos = 0,
                    .reader_id = entity_id,
                    .writer_id = rtps.types.EntityId_t.unknown,
                    .writer_sn = .{ .high = writer_id, .low = i },
                    .serialized_payload = "dummy",
                };
                r.processData(rtps.types.GUID_t.unknown, data_submsg) catch {};
            }
        }
    }.run;

    var t1 = try std.Thread.spawn(.{}, ThreadFunc, .{ reader, 1 });
    var t2 = try std.Thread.spawn(.{}, ThreadFunc, .{ reader, 2 });

    t1.join();
    t2.join();

    try std.testing.expect(reader.history_cache.getLen() <= 100);
}

test "DataReader read and take" {
    const DummyPayload = struct { val: u64 };
    var factory = DomainParticipantFactory.getInstance();
    var participant = try factory.createParticipant(0, null, std.testing.allocator);
    defer factory.deleteParticipant(participant, std.testing.allocator) catch {};
    var subscriber = try participant.createSubscriber(null);
    const topic = Topic.init("ReadTakeTopic", "DummyType");
    const qos = ReaderQos{ .history = .{ .depth = 10 } };
    const entity_id = rtps.types.EntityId_t.unknown;
    var reader = try subscriber.createDataReader(topic, qos, entity_id);

    const data_submsg = rtps.Submessage.Data{
        .header = undefined,
        .extra_flags = 0,
        .octets_to_inline_qos = 0,
        .reader_id = entity_id,
        .writer_id = rtps.types.EntityId_t.unknown,
        .writer_sn = .{ .high = 0, .low = 1 },
        .serialized_payload = "test_payload_1",
    };
    try reader.processData(rtps.types.GUID_t.unknown, data_submsg);

    // Test read
    const read_samples = try reader.read(DummyPayload, 10, .any, .any, .any);
    try std.testing.expectEqual(@as(usize, 1), read_samples.len);
    try std.testing.expectEqual(SampleStateKind.not_read, read_samples[0].info.sample_state);
    reader.returnLoan(DummyPayload, read_samples);

    // Test second read (should be .read state)
    const read_samples2 = try reader.read(DummyPayload, 10, .any, .any, .any);
    try std.testing.expectEqual(@as(usize, 1), read_samples2.len);
    try std.testing.expectEqual(SampleStateKind.read, read_samples2[0].info.sample_state);
    reader.returnLoan(DummyPayload, read_samples2);

    // Test read with not_read mask (should be empty)
    const read_samples3 = try reader.read(DummyPayload, 10, .{ .not_read = true }, .any, .any);
    try std.testing.expectEqual(@as(usize, 0), read_samples3.len);
    reader.returnLoan(DummyPayload, read_samples3);

    // Test take
    const taken_samples = try reader.take(DummyPayload, 10, .any, .any, .any);
    try std.testing.expectEqual(@as(usize, 1), taken_samples.len);
    reader.returnLoan(DummyPayload, taken_samples);

    // Test take again (should be empty, it was taken!)
    const taken_samples2 = try reader.take(DummyPayload, 10, .any, .any, .any);
    try std.testing.expectEqual(@as(usize, 0), taken_samples2.len);
    reader.returnLoan(DummyPayload, taken_samples2);
}
