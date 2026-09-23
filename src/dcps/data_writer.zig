//! @file data_writer.zig
//! @brief Implements the DDS DataWriter entity for publishing strongly-typed data to matched subscribers.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const root = @import("../root.zig");
const rtps = root.rtps;
const os = @import("../os.zig");
const sleepMs = os.sleepMs;
const getTickCount64 = os.getTickCount64;

const Entity = @import("entity.zig").Entity;
const Qos = @import("qos.zig");
const WriterQos = Qos.WriterQos;
const Status = @import("status.zig");
const StatusKind = Status.StatusKind;
const DeadlineMissedStatus = Status.DeadlineMissedStatus;
const LivelinessLostStatus = Status.LivelinessLostStatus;
const MatchedStatus = Status.MatchedStatus;
const IncompatibleQosStatus = Status.IncompatibleQosStatus;

const Topic = @import("topic.zig").Topic;
const PublisherModule = @import("publisher.zig");
const Publisher = PublisherModule.Publisher;
const PublisherListener = PublisherModule.PublisherListener;
const Subscriber = @import("subscriber.zig").Subscriber;
const DataReader = @import("data_reader.zig").DataReader;
const DomainParticipantModule = @import("domain_participant.zig");
const DomainParticipant = DomainParticipantModule.DomainParticipant;
const DomainParticipantListener = DomainParticipantModule.DomainParticipantListener;
const DomainParticipantFactory = @import("domain_participant_factory.zig").DomainParticipantFactory;
const StatusCondition = @import("condition.zig").StatusCondition;
const SpinLock = @import("wait_set.zig").SpinLock;
const Sql = @import("sql.zig").Sql;
const Sql92 = Sql;

const HistoryCacheModule = @import("../rtps/history_cache.zig");
const HistoryCache = HistoryCacheModule.HistoryCache;
const CacheChange = HistoryCacheModule.CacheChange;
const ChangeKind = HistoryCacheModule.ChangeKind;
const MessageBuilder = rtps.MessageBuilder;
const GUID_t = rtps.types.GUID_t;
const EntityId_t = rtps.types.EntityId_t;
const Locator_t = rtps.types.Locator_t;
const InstanceHandle_t = rtps.types.InstanceHandle_t;
const SampleIdentity_t = rtps.types.SampleIdentity_t;
const SequenceNumber_t = rtps.types.SequenceNumber_t;

const Serializer = @import("../cdr/serializer.zig").Serializer;
const json = @import("../json/json.zig");
const ShmSegment = @import("../transport/shm.zig").ShmSegment;
const xtypes = @import("../types/xtypes.zig");
const DiscoveredReaderData = @import("../discovery/sedp.zig").DiscoveredReaderData;

/// @brief Data writer structure.
pub const DataWriter = struct {
    entity: Entity,
    publisher: *Publisher,
    topic: Topic,
    qos: WriterQos,
    entity_id: EntityId_t,
    sequence_number: SequenceNumber_t,
    history_cache: HistoryCache,
    write_lock: SpinLock = .{},
    heartbeat_thread: ?std.Thread = null,
    heartbeat_count: u32 = 1,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Status tracking
    status_changes: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    offered_deadline_missed_status: DeadlineMissedStatus = .{},
    liveliness_lost_status: LivelinessLostStatus = .{},
    last_liveliness_assertion_time: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    publication_matched_status: MatchedStatus = .{},
    offered_incompatible_qos_status: IncompatibleQosStatus = .{},
    // Deadline tracking
    status_lock: SpinLock = .{},
    deadline_lock: SpinLock = .{},
    last_write_time: std.AutoHashMapUnmanaged([16]u8, i64) = .empty,

    // Batching
    batch_buffer: [65536]u8 = undefined,
    batch_pos: usize = 0,
    batch_lock: SpinLock = .{},
    batch_thread: ?std.Thread = null,

    // SHM Transport
    shm_segment: ?ShmSegment = null,
    shm_name: [32]u8 = undefined,
    listener: ?DataWriterListener = null,
    matched_readers: std.ArrayListUnmanaged(MatchedReader) = .empty,
    incompatible_readers: std.ArrayListUnmanaged(GUID_t) = .empty,

    // Matched Remote Endpoints (SEDP)
    pub const MatchedReader = struct {
        guid: GUID_t,
        locator: ?Locator_t,
        filter_expression: ?[]const u8 = null,
        highest_acked_seq: i64 = 0,
    };

    /// @brief Initializes a new instance.
    pub fn init(publisher: *Publisher, topic: Topic, qos: WriterQos, entity_id: EntityId_t) !DataWriter {
        const persistent_path = if (qos.durability == .persistent) try std.fmt.allocPrint(publisher.allocator, ".ddz_cache_{s}.bin", .{topic.name}) else null;
        return .{
            .entity = undefined,
            .last_liveliness_assertion_time = std.atomic.Value(i64).init(@as(i64, @intCast(getTickCount64()))),
            .publisher = publisher,
            .topic = topic,
            .qos = qos,
            .entity_id = entity_id,
            .sequence_number = .{ .high = 0, .low = 1 },
            .history_cache = HistoryCache.init(publisher.allocator, qos.history, qos.resource_limits, qos.lifespan, .{}, qos.destination_order, .{}, persistent_path),
        };
    }

    /// @brief Sleep.
    const Sleep = sleepMs;

    /// @brief Start.
    pub fn getInstanceHandle(self: *DataWriter) [16]u8 {
        return self.entity.getInstanceHandle();
    }

    pub fn enable(self: *DataWriter) !void {
        return self.entity.enable();
    }

    pub fn enableImpl(ptr: *anyopaque) anyerror!void {
        const self: *DataWriter = @ptrCast(@alignCast(ptr));

        if (self.running.load(.seq_cst)) return;
        self.running.store(true, .seq_cst);

        if (self.qos.shm.enable) {
            @memset(&self.shm_name, 0);
            const name_str = try std.fmt.bufPrint(&self.shm_name, "Local\\DDZ_{}_{}", .{ self.publisher.participant.participant_id, @as(u32, @intCast(self.entity_id.entity_key[0])) });
            self.shm_name[name_str.len] = 0;
            const name_z = self.shm_name[0..name_str.len :0];

            self.shm_segment = try ShmSegment.create(name_z, self.qos.shm.segment_size);
        }

        if (self.qos.reliability.kind == .reliable) {
            self.heartbeat_thread = try std.Thread.spawn(.{}, heartbeatLoop, .{self});
        }
        if (self.qos.batch.enable or self.qos.latency_budget.duration_ms > 0) {
            self.batch_thread = try std.Thread.spawn(.{}, batchFlushLoop, .{self});
        }
    }

    /// @brief Deinitializes the instance.
    /// @brief Retrieve the StatusCondition for this writer.
    pub fn getStatusCondition(self: *DataWriter) !*StatusCondition {
        return self.entity.getStatusCondition();
    }

    /// @brief Notify of a status change.
    pub fn notifyStatusChange(self: *DataWriter, status: StatusKind) void {
        const mask = @backingInt(status);
        _ = self.status_changes.fetchOr(mask, .monotonic);

        var opt_sc: ?*StatusCondition = null;
        var w_listener: ?DataWriterListener = null;
        var p_listener: ?PublisherListener = null;
        var dp_listener: ?DomainParticipantListener = null;
        var offered_deadline: DeadlineMissedStatus = undefined;
        var liveliness_lost: LivelinessLostStatus = undefined;
        var publication_matched: MatchedStatus = undefined;
        var offered_incompatible: IncompatibleQosStatus = undefined;

        {
            self.status_lock.lock();
            defer self.status_lock.unlock();

            opt_sc = self.entity.status_condition;
            w_listener = self.listener;
            p_listener = self.publisher.listener;
            dp_listener = self.publisher.participant.listener;
            offered_deadline = self.offered_deadline_missed_status;
            liveliness_lost = self.liveliness_lost_status;
            publication_matched = self.publication_matched_status;
            offered_incompatible = self.offered_incompatible_qos_status;
        }

        if (opt_sc) |sc| {
            if ((self.status_changes.load(.monotonic) & sc.enabled_statuses) != 0) {
                sc.condition.setTriggerValue(true);
            }
        }

        // Listener dispatch hierarchy outside status_lock to prevent deadlocks
        var handled = false;

        // 1. Try DataWriterListener
        if (w_listener) |l| {
            switch (status) {
                .offered_deadline_missed => if (l.on_offered_deadline_missed) |cb| {
                    cb(l.context, self, offered_deadline);
                    handled = true;
                },
                .liveliness_lost => if (l.on_liveliness_lost) |cb| {
                    cb(l.context, self, liveliness_lost);
                    handled = true;
                },
                .publication_matched => if (l.on_publication_matched) |cb| {
                    cb(l.context, self, publication_matched);
                    handled = true;
                },
                .offered_incompatible_qos => if (l.on_offered_incompatible_qos) |cb| {
                    cb(l.context, self, offered_incompatible);
                    handled = true;
                },
                else => {},
            }
        }

        // 2. Try PublisherListener
        if (!handled) {
            if (p_listener) |pl| {
                switch (status) {
                    .offered_deadline_missed => if (pl.on_offered_deadline_missed) |cb| {
                        cb(pl.context, self, offered_deadline);
                        handled = true;
                    },
                    .liveliness_lost => if (pl.on_liveliness_lost) |cb| {
                        cb(pl.context, self, liveliness_lost);
                        handled = true;
                    },
                    .publication_matched => if (pl.on_publication_matched) |cb| {
                        cb(pl.context, self, publication_matched);
                        handled = true;
                    },
                    .offered_incompatible_qos => if (pl.on_offered_incompatible_qos) |cb| {
                        cb(pl.context, self, offered_incompatible);
                        handled = true;
                    },
                    else => {},
                }
            }
        }

        // 3. Try DomainParticipantListener
        if (!handled) {
            if (dp_listener) |dpl| {
                switch (status) {
                    .offered_deadline_missed => if (dpl.on_offered_deadline_missed) |cb| {
                        cb(dpl.context, self, offered_deadline);
                        handled = true;
                    },
                    .liveliness_lost => if (dpl.on_liveliness_lost) |cb| {
                        cb(dpl.context, self, liveliness_lost);
                        handled = true;
                    },
                    .publication_matched => if (dpl.on_publication_matched) |cb| {
                        cb(dpl.context, self, publication_matched);
                        handled = true;
                    },
                    .offered_incompatible_qos => if (dpl.on_offered_incompatible_qos) |cb| {
                        cb(dpl.context, self, offered_incompatible);
                        handled = true;
                    },
                    else => {},
                }
            }
        }
    }

    pub fn deinit(self: *DataWriter) void {
        if (self.history_cache.persistent_file_path) |p| {
            self.publisher.allocator.free(p);
        }
        self.running.store(false, .seq_cst);
        if (self.heartbeat_thread) |thread| {
            thread.join();
            self.heartbeat_thread = null;
        }
        if (self.batch_thread) |thread| {
            thread.join();
            self.batch_thread = null;
        }
        if (self.shm_segment != null) {
            self.shm_segment.?.deinit();
            self.shm_segment = null;
        }
        self.entity.deinit();
        self.matched_readers.deinit(self.publisher.allocator);
        self.matched_readers = .empty;
        self.incompatible_readers.deinit(self.publisher.allocator);
        self.incompatible_readers = .empty;
        self.last_write_time.deinit(self.publisher.allocator);
        self.history_cache.deinit();
    }

    /// @brief Batch flush loop.
    fn batchFlushLoop(self: *DataWriter) void {
        const sleep_ms = if (self.qos.latency_budget.duration_ms > 0) @as(u32, @intCast(self.qos.latency_budget.duration_ms)) else self.qos.batch.max_flush_delay_ms;
        while (self.running.load(.seq_cst)) {
            var waited_ms: u32 = 0;
            while (waited_ms < sleep_ms and self.running.load(.seq_cst)) {
                sleepMs(1);
                waited_ms += 1;
            }
            self.flush() catch {};
        }
    }

    /// @brief Send packet.
    fn sendPacket(self: *DataWriter, packet: []const u8, locs: []const ?rtps.types.Locator_t) !void {
        // Map logical DDS transport priority to OS-level IP_TOS if non-zero
        // Note: In a shared socket architecture, this is racy. A dedicated socket per DataWriter would be required for strict QoS.
        // Map logical DDS transport priority to OS-level IP_TOS if non-zero
        // Zig 0.17 std.net doesn't expose a cross-platform setsockopt IP_TOS yet.
        if (self.qos.transport_priority.value > 0) {
            // Future: set socket priority
        }

        if (self.qos.shm.enable and self.shm_segment != null) {
            if (self.shm_segment.?.allocate(@as(u32, @intCast(packet.len)))) |offset| {
                @memcpy(self.shm_segment.?.data[offset .. offset + packet.len], packet);

                var msg_buf: [128]u8 = undefined;
                var msg_ser = Serializer.init(&msg_buf, .Little);

                const header = rtps.Message.Header{
                    .protocol = rtps.Message.Header.rtps_magic,
                    .version = rtps.types.ProtocolVersion_t.current,
                    .vendor_id = rtps.types.vendor_ddz,
                    .guid_prefix = self.publisher.participant.guid_prefix,
                };
                const header_len = try header.serialize(&msg_buf);
                msg_ser.pos = header_len;

                const info_shm_len: u32 = 40;
                const shm_header_bytes: u32 = (info_shm_len << 16) | (@as(u32, 0x01) << 8) | @as(u32, @backingInt(rtps.Submessage.SubmessageKind.INFO_SHM));
                try msg_ser.serialize(shm_header_bytes);
                try msg_ser.writeAll(&self.shm_name);
                try msg_ser.serialize(offset);
                try msg_ser.serialize(@as(u32, @intCast(packet.len)));

                const ptr_packet = msg_buf[0..msg_ser.pos];
                for (locs) |opt_loc| {
                    if (opt_loc) |loc| {
                        _ = try self.publisher.participant.user_socket.sendTo(ptr_packet, loc);
                    }
                }
                return;
            } else |_| {
                // Fallback to UDP if SHM full
            }
        }

        if (self.qos.transport_priority.value != 0) {
            self.publisher.participant.user_socket.setTos(self.qos.transport_priority.value);
        }
        for (locs) |opt_loc| {
            if (opt_loc) |loc| {
                _ = try self.publisher.participant.user_socket.sendTo(packet, loc);
            }
        }
    }

    /// @brief Flush.
    pub fn flush(self: *DataWriter) !void {
        self.batch_lock.lock();
        defer self.batch_lock.unlock();

        if (self.batch_pos == 0) return; // Nothing to flush

        const packet = self.batch_buffer[0..self.batch_pos];

        self.publisher.participant.registry_lock.lockShared();
        const opt_locs = self.publisher.participant.discovered_participants.items(.metatraffic_unicast_locator);
        try self.sendPacket(packet, opt_locs);
        self.publisher.participant.registry_lock.unlockShared();

        self.batch_pos = 0; // Reset batch buffer
    }

    /// @brief Heartbeat loop.
    fn heartbeatLoop(self: *DataWriter) void {
        const heartbeat_period_ms = 500; // 500ms heartbeat

        while (self.running.load(.seq_cst)) {
            Sleep(heartbeat_period_ms);
            self.sendHeartbeat() catch {};
        }
    }

    /// @brief Send heartbeat.
    fn sendHeartbeat(self: *DataWriter) !void {
        var msg_buf: [128]u8 = undefined;
        var builder = try rtps.MessageBuilder.init(&msg_buf, self.publisher.participant.guid_prefix);

        // Get first and last available from history cache
        self.history_cache.acquireLock();
        const first_sn = if (self.history_cache.global_head) |h| h.change.sequence_number else rtps.types.SequenceNumber_t{ .high = 0, .low = 1 };
        const last_sn = if (self.history_cache.global_tail) |t| t.change.sequence_number else rtps.types.SequenceNumber_t{ .high = 0, .low = 0 };
        self.history_cache.releaseLock();

        try builder.addHeartbeat(rtps.types.EntityId_t.unknown, self.entity_id, first_sn, last_sn, @intCast(self.heartbeat_count));
        self.heartbeat_count += 1;

        const packet = try builder.finalizeAndEncrypt(self.publisher.participant.crypto_plugin, self.entity_id, self.publisher.participant.allocator);

        // 3. Send to all endpoints
        self.publisher.participant.registry_lock.lockShared();
        const opt_locs = self.publisher.participant.discovered_participants.items(.metatraffic_unicast_locator);
        try self.sendPacket(packet, opt_locs);
        self.publisher.participant.registry_lock.unlockShared();
    }

    /// @brief On new participant discovered.
    pub fn onNewParticipantDiscovered(self: *DataWriter, locator: rtps.types.Locator_t) !void {
        if (self.qos.durability == .@"volatile") return;

        self.history_cache.acquireLock();
        defer self.history_cache.releaseLock();

        if (self.history_cache.global_count == 0) return;

        // In-process delivery to local participants
        const ParticipantModule = DomainParticipantModule;
        var local_readers: std.ArrayListUnmanaged(*DataReader) = .empty;
        defer local_readers.deinit(self.publisher.participant.allocator);

        ParticipantModule.global_registry_lock.lockShared();
        for (ParticipantModule.global_participants) |opt_p| {
            if (opt_p) |local_p| {
                if (local_p != self.publisher.participant) {
                    local_p.registry_lock.lockShared();
                    for (local_p.subscribers.items) |sub_ptr| {
                        const sub: *Subscriber = @ptrCast(@alignCast(sub_ptr));
                        for (sub.readers.items) |reader| {
                            if (!std.mem.eql(u8, self.topic.name, reader.topic.name)) continue;
                            if (reader.topic.type_name.len > 0 and !std.mem.eql(u8, self.topic.type_name, reader.topic.type_name)) continue;
                            if (!Qos.matchPartition(self.publisher.qos.partition.name, sub.qos.partition.name)) continue;
                            if (reader.qos.durability == .@"volatile") continue;
                            local_readers.append(self.publisher.participant.allocator, reader) catch {};
                        }
                    }
                    local_p.registry_lock.unlockShared();
                }
            }
        }
        ParticipantModule.global_registry_lock.unlockShared();

        const writer_guid = GUID_t{ .prefix = self.publisher.participant.guid_prefix, .entity_id = self.entity_id };
        for (local_readers.items) |reader| {
            var curr = self.history_cache.global_head;
            while (curr) |node| : (curr = node.global_next) {
                const data_submessage = rtps.Submessage.Data{
                    .header = undefined,
                    .extra_flags = 0,
                    .octets_to_inline_qos = 16,
                    .reader_id = rtps.types.EntityId_t.unknown,
                    .writer_id = self.entity_id,
                    .writer_sn = node.change.sequence_number,
                    .instance_handle = node.change.instance_handle,
                    .status_info = null,
                    .serialized_payload = node.change.data_value,
                    .coherent_set_id = if (node.change.coherent_set_id != 0) node.change.coherent_set_id else null,
                    .related_sample_identity = node.change.related_sample_identity,
                };
                reader.processData(writer_guid, data_submessage) catch {};
            }
        }

        const locs = [_]?rtps.types.Locator_t{locator};

        var current_node = self.history_cache.global_head;
        while (current_node) |node| : (current_node = node.global_next) {
            const payload = node.change.data_value;
            const sn = node.change.sequence_number;
            const instance_handle = node.change.instance_handle;
            var msg_buf: [2048]u8 = undefined;
            var msg_ser = Serializer.init(&msg_buf, .Little);

            // 1. Header
            const header = rtps.Message.Header{
                .protocol = rtps.Message.Header.rtps_magic,
                .version = rtps.types.ProtocolVersion_t.current,
                .vendor_id = rtps.types.vendor_ddz,
                .guid_prefix = self.publisher.participant.guid_prefix,
            };
            const header_len = try header.serialize(&msg_buf);
            msg_ser.pos = header_len;

            // 2. DATA submessage
            // Inline QoS flag = 0x02
            const data_len = @as(u16, @intCast(44 + payload.len));
            const submsg_header: u32 = (@as(u32, data_len) << 16) | (@as(u32, 0x07) << 8) | @as(u32, @backingInt(rtps.Submessage.SubmessageKind.DATA));
            try msg_ser.serialize(submsg_header);

            // ExtraFlags, OctetsToInlineQos (16)
            try msg_ser.serialize(@as(u16, 0));
            try msg_ser.serialize(@as(u16, 16));

            try msg_ser.serialize(rtps.types.EntityId_t.unknown); // readerId
            try msg_ser.serialize(self.entity_id); // writerId
            try msg_ser.serialize(sn.high);
            try msg_ser.serialize(sn.low);

            // Inline QoS (Instance Handle)
            try msg_ser.serialize(@as(u16, 0x0070));
            try msg_ser.serialize(@as(u16, 16));
            const ih_slice = instance_handle[0..16];
            @memcpy(msg_buf[msg_ser.pos .. msg_ser.pos + 16], ih_slice);
            msg_ser.pos += 16;
            try msg_ser.serialize(@as(u16, 0x0001)); // SENTINEL
            try msg_ser.serialize(@as(u16, 0));

            @memcpy(msg_buf[msg_ser.pos .. msg_ser.pos + payload.len], payload);
            msg_ser.pos += payload.len;

            try self.sendPacket(msg_buf[0..msg_ser.pos], &locs);
        }
    }

    /// @brief Process NackFrag.
    pub fn processNackFrag(self: *DataWriter, reader_guid: rtps.types.GUID_t, nack_frag: rtps.Submessage.NackFrag) !void {
        _ = reader_guid;
        if (nack_frag.writer_id.entity_kind != rtps.types.EntityId_t.unknown.entity_kind and
            nack_frag.writer_id.entity_key[0] != self.entity_id.entity_key[0])
        {
            return;
        }

        self.history_cache.acquireLock();
        var opt_payload: ?[]const u8 = null;
        var opt_instance: ?[16]u8 = null;
        var opt_kind: ?ChangeKind = null;
        var current_nack = self.history_cache.global_head;
        while (current_nack) |node| : (current_nack = node.global_next) {
            const sn = node.change.sequence_number;
            const val = node.change.data_value;
            if (sn.high == nack_frag.writer_sn.high and sn.low == nack_frag.writer_sn.low) {
                opt_payload = val;
                opt_instance = node.change.instance_handle;
                opt_kind = node.change.kind;
                break;
            }
        }
        self.history_cache.releaseLock();

        const payload = opt_payload orelse return;
        const instance_handle = opt_instance orelse std.mem.zeroes([16]u8);

        const max_frag_size = 1024;
        const total_size = payload.len;
        const base_frag = nack_frag.fragment_number_state.base.low;
        const num_bits = nack_frag.fragment_number_state.num_bits;

        var i: u32 = 0;
        while (i < num_bits) : (i += 1) {
            const long_idx = i / 32;
            const bit_idx = i % 32;
            const bit = (nack_frag.fragment_number_state.bitmap[long_idx] >> @as(u5, @intCast(bit_idx))) & 1;

            if (bit == 1) {
                const frag_num = base_frag + i; // 1-indexed
                if (frag_num == 0) continue;

                const offset = (frag_num - 1) * max_frag_size;
                if (offset >= total_size) continue;

                const frag_len = @min(total_size - offset, max_frag_size);
                const frag_data = payload[offset .. offset + frag_len];

                var msg_buf: [2048]u8 = undefined;
                var builder = try rtps.MessageBuilder.init(&msg_buf, self.publisher.participant.guid_prefix);
                try builder.addInfoTs();

                const status_info: ?[4]u8 = if (opt_kind) |k| switch (k) {
                    .ALIVE => null,
                    .NOT_ALIVE_DISPOSED => [4]u8{ 0, 0, 0, 1 },
                    .NOT_ALIVE_UNREGISTERED => [4]u8{ 0, 0, 0, 2 },
                } else null;
                try builder.addDataFrag(nack_frag.reader_id, self.entity_id, nack_frag.writer_sn, instance_handle, frag_num, max_frag_size, @as(u32, @intCast(total_size)), frag_data, status_info, null, null, null, null, null);

                const final_payload = builder.finalizeAndEncrypt(self.publisher.participant.crypto_plugin, self.entity_id, self.publisher.participant.allocator) catch continue;

                self.publisher.participant.registry_lock.lockShared();
                const opt_locs = self.publisher.participant.discovered_participants.items(.metatraffic_unicast_locator);
                try self.sendPacket(final_payload, opt_locs);
                self.publisher.participant.registry_lock.unlockShared();
            }
        }
    }

    /// @brief Process ack nack.
    pub fn processAckNack(self: *DataWriter, reader_guid: rtps.types.GUID_t, an: rtps.Submessage.AckNack) !void {
        if (an.writer_id.entity_kind != rtps.types.EntityId_t.unknown.entity_kind and
            an.writer_id.entity_key[0] != self.entity_id.entity_key[0])
        {
            return;
        }

        self.write_lock.lock();
        var found = false;
        for (self.matched_readers.items) |*mr| {
            if (std.meta.eql(mr.guid, reader_guid)) {
                found = true;
                const acked_up_to = @as(i64, @intCast(an.reader_sn_state.base.low)) - 1;
                mr.highest_acked_seq = @max(mr.highest_acked_seq, acked_up_to);
                break;
            }
        }
        var incompatible = false;
        if (!found) {
            for (self.incompatible_readers.items) |guid| {
                if (std.meta.eql(guid, reader_guid)) {
                    incompatible = true;
                    break;
                }
            }
        }

        if (!found and !incompatible) {
            if (self.publisher.participant.findRemoteReaderData(reader_guid)) |rrd| {
                if (Qos.checkCompatibility(self.qos, rrd)) |policy_id| {
                    try self.incompatible_readers.append(self.publisher.allocator, reader_guid);
                    self.offered_incompatible_qos_status.total_count += 1;
                    self.offered_incompatible_qos_status.total_count_change += 1;
                    self.offered_incompatible_qos_status.last_policy_id = policy_id;
                    self.write_lock.unlock();
                    self.notifyStatusChange(.offered_incompatible_qos);
                    return;
                }

                // XTypes Assignability Check
                if (rrd.type_object_cdr.len > 0 and self.topic.type_object_cdr.len > 0) {
                    const alloc = self.publisher.participant.allocator;
                    const xt = xtypes;
                    var reader_type = xt.deserializeTypeObject(alloc, rrd.type_object_cdr) catch null;
                    var writer_type = xt.deserializeTypeObject(alloc, self.topic.type_object_cdr) catch null;
                    var assignable = true;
                    if (reader_type != null and writer_type != null) {
                        assignable = xt.TypeObject.isAssignable(reader_type.?, writer_type.?);
                    }
                    if (reader_type != null) reader_type.?.deinit(alloc);
                    if (writer_type != null) writer_type.?.deinit(alloc);

                    if (!assignable) {
                        try self.incompatible_readers.append(self.publisher.allocator, reader_guid);
                        self.write_lock.unlock();
                        return;
                    }
                }

                {
                    const acked_up_to = @as(i64, @intCast(an.reader_sn_state.base.low)) - 1;
                    try self.matched_readers.append(self.publisher.allocator, .{ .guid = reader_guid, .locator = null, .highest_acked_seq = @max(0, acked_up_to) });
                    self.publication_matched_status.total_count += 1;
                    self.publication_matched_status.total_count_change += 1;
                    self.publication_matched_status.current_count += 1;
                    self.publication_matched_status.current_count_change += 1;
                    self.write_lock.unlock();
                    self.notifyStatusChange(.publication_matched);

                    self.write_lock.lock(); // Reacquire for rest of function
                }
            } else {
                const acked_up_to = @as(i64, @intCast(an.reader_sn_state.base.low)) - 1;
                try self.matched_readers.append(self.publisher.allocator, .{ .guid = reader_guid, .locator = null, .highest_acked_seq = @max(0, acked_up_to) });
            }
        }

        if (incompatible) {
            self.write_lock.unlock();
            return;
        }
        self.write_lock.unlock();

        const base_low = an.reader_sn_state.base.low;
        const num_bits = an.reader_sn_state.num_bits;

        var i: u32 = 0;
        while (i < num_bits) : (i += 1) {
            const long_idx = i / 32;
            const bit_idx = i % 32;
            const bit = (an.reader_sn_state.bitmap[long_idx] >> @as(u5, @intCast(bit_idx))) & 1;
            if (bit == 1) {
                const sn = rtps.types.SequenceNumber_t{ .high = 0, .low = base_low + i };
                if (self.history_cache.getChange(sn)) |change| {
                    try self.resendData(change, an.reader_id);
                }
            }
        }
    }

    /// @brief Resend data.
    fn resendData(self: *DataWriter, change: CacheChange, reader_id: EntityId_t) !void {
        var msg_buf: [65536]u8 = undefined;
        var builder = try rtps.MessageBuilder.init(&msg_buf, self.publisher.participant.guid_prefix);

        const status_info: ?[4]u8 = switch (change.kind) {
            .ALIVE => null,
            .NOT_ALIVE_DISPOSED => [4]u8{ 0, 0, 0, 1 },
            .NOT_ALIVE_UNREGISTERED => [4]u8{ 0, 0, 0, 2 },
        };
        try builder.addData(reader_id, self.entity_id, change.sequence_number, change.instance_handle, change.data_value, status_info, null, null, null, if (self.publisher.coherent_changes_active) self.publisher.coherent_set_id else null, change.related_sample_identity);

        const final_payload = try builder.finalizeAndEncrypt(self.publisher.participant.crypto_plugin, self.entity_id, self.publisher.participant.allocator);

        self.publisher.participant.registry_lock.lockShared();
        const opt_locs = self.publisher.participant.discovered_participants.items(.metatraffic_unicast_locator);
        try self.sendPacket(final_payload, opt_locs);
        self.publisher.participant.registry_lock.unlockShared();
    }

    /// @brief Evaluate filter.
    pub const evaluateFilter = Sql92.evaluate;

    /// @brief Blocks the calling thread until all data written by the DataWriter is acknowledged by all matched reliable DataReaders, or the duration expires.
    pub fn waitForAcknowledgments(self: *DataWriter, max_wait: struct { duration_ms: i32 }) !void {
        if (self.qos.reliability.kind == .best_effort) return;

        const start_time = getTickCount64();
        const duration_ms = if (max_wait.duration_ms == std.math.maxInt(i32)) std.math.maxInt(u64) else @as(u64, @intCast(max_wait.duration_ms));

        while (true) {
            self.write_lock.lock();
            const target_seq = self.sequence_number.low;
            var all_acked = true;
            for (self.matched_readers.items) |mr| {
                if (mr.highest_acked_seq < target_seq) {
                    all_acked = false;
                    break;
                }
            }
            self.write_lock.unlock();

            if (all_acked) return;

            const now = getTickCount64();
            if (now - start_time >= duration_ms) return error.Timeout;

            sleepMs(10);
        }
    }

    /// @brief Write.
    pub fn write(self: *DataWriter, data: anytype) !void {
        _ = try self.writeWithParams(data, null, .ALIVE);
    }

    pub fn registerInstance(self: *DataWriter, data: anytype) !void {
        _ = try self.writeWithParams(data, null, .ALIVE);
    }

    pub fn dispose(self: *DataWriter, data: anytype, instance_handle: ?[16]u8) !void {
        _ = instance_handle; // We ignore handle because we just serialize the data to get the key anyway
        _ = try self.writeWithParams(data, null, .NOT_ALIVE_DISPOSED);
    }

    pub fn unregisterInstance(self: *DataWriter, data: anytype, instance_handle: ?[16]u8) !void {
        if (self.qos.writer_data_lifecycle.autodispose_unregistered_instances) {
            try self.dispose(data, instance_handle);
        }
        _ = try self.writeWithParams(data, null, .NOT_ALIVE_UNREGISTERED);
    }

    pub fn sendEndCoherentSet(self: *DataWriter) !void {
        var msg_buf: [1024]u8 = undefined;
        var builder = try MessageBuilder.init(&msg_buf, self.publisher.participant.guid_prefix);

        const change = CacheChange{
            .kind = .ALIVE,
            .writer_guid = GUID_t{ .prefix = self.publisher.participant.guid_prefix, .entity_id = self.entity_id },
            .instance_handle = std.mem.zeroes([16]u8),
            .sequence_number = .{ .high = 0, .low = 0 }, // 0 sequence number for marker
            .data_value = "", // 0-length payload
            .coherent_set_id = self.publisher.coherent_set_id,
        };

        try builder.addData(EntityId_t.unknown, self.entity_id, change.sequence_number, change.instance_handle, change.data_value, null, null, null, null, change.coherent_set_id, null);

        const final_payload = try builder.finalizeAndEncrypt(self.publisher.participant.crypto_plugin, self.entity_id, self.publisher.participant.allocator);

        const ParticipantModule = DomainParticipantModule;
        ParticipantModule.global_registry_lock.lockShared();

        var remote_endpoints: std.ArrayListUnmanaged(Locator_t) = .empty;
        defer remote_endpoints.deinit(self.publisher.participant.allocator);

        for (ParticipantModule.global_participants) |opt_p| {
            if (opt_p) |p| {
                if (!std.mem.eql(u8, &p.guid_prefix, &self.publisher.participant.guid_prefix)) {
                    const loc = Locator_t{ .kind = 1, .port = p.sedp_unicast_port, .address = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 127, 0, 0, 1 } };
                    remote_endpoints.append(self.publisher.participant.allocator, loc) catch {};
                } else {
                    p.registry_lock.lockShared();
                    for (p.subscribers.items) |sub_ptr| {
                        const sub: *Subscriber = @ptrCast(@alignCast(sub_ptr));
                        for (sub.readers.items) |reader| {
                            if (!std.mem.eql(u8, self.topic.name, reader.topic.name)) continue;
                            reader.history_cache.releaseCoherentSet(self.publisher.coherent_set_id);
                            reader.triggerReadConditions();
                        }
                    }
                    p.registry_lock.unlockShared();
                }
            }
        }
        ParticipantModule.global_registry_lock.unlockShared();

        if (self.qos.transport_priority.value != 0) {
            self.publisher.participant.user_socket.setTos(self.qos.transport_priority.value);
        }
        for (remote_endpoints.items) |loc| {
            _ = try self.publisher.participant.user_socket.sendTo(final_payload, loc);
        }
    }

    pub fn assertLiveliness(self: *DataWriter) !void {
        const now = @as(i64, @intCast(getTickCount64()));
        self.last_liveliness_assertion_time.store(now, .release);

        if (self.qos.liveliness.kind == .manual_by_topic) {
            // Send a Heartbeat to matched readers to assert liveliness
            const participant = self.publisher.participant;
            participant.registry_lock.lockShared();
            defer participant.registry_lock.unlockShared();

            var first_sn = self.sequence_number;
            var last_sn = self.sequence_number;
            if (first_sn.low == 0) first_sn.low = 1;
            if (last_sn.low == 0) last_sn.low = 1;

            for (participant.subscribers.items) |sub_ptr| {
                const subscriber: *Subscriber = @ptrCast(@alignCast(sub_ptr));
                for (subscriber.readers.items) |r_ptr| {
                    const reader: *DataReader = @ptrCast(@alignCast(r_ptr));
                    if (std.mem.eql(u8, reader.topic.name, self.topic.name)) {
                        // Route internally since they are local
                        const hb_submsg = rtps.Submessage.Heartbeat{
                            .header = undefined,
                            .reader_id = reader.entity_id,
                            .writer_id = self.entity_id,
                            .first_sn = first_sn,
                            .last_sn = last_sn,
                            .count = @as(rtps.types.Count_t, @intCast(self.heartbeat_count)),
                        };
                        const writer_guid = rtps.types.GUID_t{ .prefix = self.publisher.participant.guid_prefix, .entity_id = self.entity_id };
                        reader.processHeartbeat(writer_guid, hb_submsg) catch {};
                    }
                }
            }

            self.heartbeat_count += 1;
        }
    }

    pub fn writeWithParams(self: *DataWriter, data: anytype, related_sample_identity: ?SampleIdentity_t, change_kind: ChangeKind) !SampleIdentity_t {
        self.write_lock.lock();
        defer self.write_lock.unlock();
        var instance_handle = std.mem.zeroes([16]u8);
        const T = @TypeOf(data);
        if (T != []const u8 and @hasDecl(T, "ddz_keys")) {
            var hasher = std.crypto.hash.Md5.init(.{});
            inline for (T.ddz_keys) |key_name| {
                const field_val = @field(data, key_name);
                var key_buf: [1024]u8 = undefined;
                var key_ser = Serializer.init(&key_buf, .Little);
                try key_ser.serialize(field_val);
                hasher.update(key_buf[0..key_ser.pos]);
            }
            hasher.final(&instance_handle);
        }

        // Allocate a large buffer for the serialized payload (e.g., 64KB) to support fragmentation
        const max_payload_size = 65536;
        const payload_buf = try self.publisher.participant.allocator.alloc(u8, max_payload_size);
        defer self.publisher.participant.allocator.free(payload_buf);

        var serialized_payload: []const u8 = undefined;
        if (T == []const u8) {
            serialized_payload = data;
        } else if (self.qos.representation.hasJson() and !self.qos.representation.hasXcdr()) {
            serialized_payload = try json.serializeWireToBuf(payload_buf, data);
        } else {
            var cdr_ser = Serializer.init(payload_buf, .Little);
            try cdr_ser.serialize(data);
            serialized_payload = payload_buf[0..cdr_ser.pos];
        }

        if (self.sequence_number.low == std.math.maxInt(u32)) {
            self.sequence_number.low = 1;
            self.sequence_number.high +%= 1;
        } else {
            self.sequence_number.low += 1;
        }
        self.last_liveliness_assertion_time.store(@as(i64, @intCast(getTickCount64())), .release);
        self.deadline_lock.lock();
        self.last_write_time.put(self.publisher.allocator, instance_handle, @as(i64, @intCast(getTickCount64()))) catch {};
        self.deadline_lock.unlock();

        // Save into HistoryCache for Reliability/Retransmissions
        try self.history_cache.addChange(.{
            .kind = change_kind,
            .writer_guid = GUID_t{ .prefix = self.publisher.participant.guid_prefix, .entity_id = self.entity_id },
            .instance_handle = instance_handle,
            .sequence_number = self.sequence_number,
            .data_value = serialized_payload,
        });

        var remote_endpoints: std.ArrayListUnmanaged(?Locator_t) = .empty;
        var local_readers: std.ArrayListUnmanaged(*DataReader) = .empty;
        defer remote_endpoints.deinit(self.publisher.participant.allocator);
        defer local_readers.deinit(self.publisher.participant.allocator);

        // 0. Deliver to our OWN participant's readers directly!
        self.publisher.participant.registry_lock.lockShared();
        for (self.publisher.participant.subscribers.items) |sub_ptr| {
            const sub: *Subscriber = @ptrCast(@alignCast(sub_ptr));
            for (sub.readers.items) |reader| {
                if (!std.mem.eql(u8, self.topic.name, reader.topic.name)) continue;
                if (reader.topic.type_name.len > 0 and !std.mem.eql(u8, self.topic.type_name, reader.topic.type_name)) continue;
                if (!Qos.matchPartition(self.publisher.qos.partition.name, sub.qos.partition.name)) continue;
                if (self.entity_id.entity_kind < 0xc0) {
                    if (reader.filter_expression) |expr| {
                        if (expr.len > 0 and !evaluateFilter(@TypeOf(data), data, expr)) continue;
                    }
                }
                local_readers.append(self.publisher.participant.allocator, reader) catch {};
            }
        }
        self.publisher.participant.registry_lock.unlockShared();

        // 1. Deliver locally to any discovered participants that share this process
        // We collect readers first to avoid holding participant locks while calling processData (which locks DataReader and calls findRemoteWriterData)

        const ParticipantModule = DomainParticipantModule;
        {
            self.publisher.participant.registry_lock.lockShared();
            defer self.publisher.participant.registry_lock.unlockShared();
            const opt_locs = self.publisher.participant.discovered_participants.items(.metatraffic_unicast_locator);
            const prefixes = self.publisher.participant.discovered_participants.items(.guid_prefix);
            const filters = self.publisher.participant.discovered_participants.items(.filter_expression);

            for (opt_locs, prefixes, filters) |opt_loc, prefix, filter_expr| {
                if (self.entity_id.entity_kind < 0xc0) {
                    if (filter_expr) |expr| {
                        if (expr.len > 0 and !evaluateFilter(@TypeOf(data), data, expr)) continue;
                    }
                }

                if (opt_loc) |loc| {
                    var is_local = false;
                    ParticipantModule.global_registry_lock.lockShared();
                    for (ParticipantModule.global_participants) |opt_p| {
                        if (opt_p) |local_p| {
                            if (std.mem.eql(u8, &local_p.guid_prefix, &prefix)) {
                                is_local = true;
                                local_p.registry_lock.lockShared();
                                for (local_p.subscribers.items) |sub_ptr| {
                                    const sub: *Subscriber = @ptrCast(@alignCast(sub_ptr));
                                    for (sub.readers.items) |reader| {
                                        if (!std.mem.eql(u8, self.topic.name, reader.topic.name)) continue;
                                        if (reader.topic.type_name.len > 0 and !std.mem.eql(u8, self.topic.type_name, reader.topic.type_name)) continue;
                                        if (!Qos.matchPartition(self.publisher.qos.partition.name, sub.qos.partition.name)) continue;
                                        if (self.entity_id.entity_kind < 0xc0) {
                                            if (reader.filter_expression) |expr| {
                                                if (expr.len > 0 and !evaluateFilter(@TypeOf(data), data, expr)) continue;
                                            }
                                        }
                                        local_readers.append(self.publisher.participant.allocator, reader) catch {};
                                    }
                                }
                                local_p.registry_lock.unlockShared();
                                break;
                            }
                        }
                    }
                    ParticipantModule.global_registry_lock.unlockShared();

                    if (!is_local) {
                        remote_endpoints.append(self.publisher.participant.allocator, loc) catch {};
                    }
                }
            }
        } // Unlocked!

        // Now deliver without holding registry_lock
        for (local_readers.items) |reader| {
            const writer_guid = GUID_t{ .prefix = self.publisher.participant.guid_prefix, .entity_id = self.entity_id };
            const status_info_1: ?[4]u8 = switch (change_kind) {
                .ALIVE => null,
                .NOT_ALIVE_DISPOSED => [4]u8{ 0, 0, 0, 1 },
                .NOT_ALIVE_UNREGISTERED => [4]u8{ 0, 0, 0, 2 },
            };
            const data_submessage = rtps.Submessage.Data{
                .header = undefined,
                .extra_flags = 0,
                .octets_to_inline_qos = 16,
                .reader_id = EntityId_t.unknown,
                .writer_id = self.entity_id,
                .writer_sn = self.sequence_number,
                .instance_handle = instance_handle,
                .status_info = status_info_1,
                .serialized_payload = serialized_payload,
                .coherent_set_id = if (self.publisher.coherent_changes_active) self.publisher.coherent_set_id else null,
                .related_sample_identity = related_sample_identity,
            };

            reader.processData(writer_guid, data_submessage) catch {};
        }

        // 2. Deliver to remote endpoints via UDP (with Fragmentation)
        if (remote_endpoints.items.len > 0) {
            const max_frag_size = 1024;
            const total_size = serialized_payload.len;
            var offset: usize = 0;
            var frag_num: u32 = 1;

            while (offset < total_size) {
                const frag_len = @min(total_size - offset, max_frag_size);
                const frag_data = serialized_payload[offset .. offset + frag_len];

                var msg_buf: [2048]u8 = undefined;
                var msg_ser = Serializer.init(&msg_buf, .Little);

                const header = rtps.Message.Header{
                    .protocol = rtps.Message.Header.rtps_magic,
                    .version = rtps.types.ProtocolVersion_t.current,
                    .vendor_id = rtps.types.vendor_ddz,
                    .guid_prefix = self.publisher.participant.guid_prefix,
                };
                const header_len = try header.serialize(&msg_buf);
                msg_ser.pos = header_len;

                const unencrypted_start = msg_ser.pos;

                const info_ts_header: u32 = (@as(u32, 8) << 16) | (@as(u32, 0x01) << 8) | @as(u32, @backingInt(rtps.Submessage.SubmessageKind.INFO_TS));
                try msg_ser.serialize(info_ts_header);
                try msg_ser.serialize(rtps.types.Time_t{ .seconds = 0, .fraction = 0 });

                const has_key = !std.mem.eql(u8, &instance_handle, &std.mem.zeroes([16]u8));
                var inline_qos_len: u32 = 0;
                if (has_key) inline_qos_len += 20;
                if (related_sample_identity != null) inline_qos_len += 28;
                if (inline_qos_len > 0) inline_qos_len += 4; // Sentinel
                const data_flags: u8 = if (inline_qos_len > 0) 0x07 else 0x05; // 0x05 = DataFlag | Endianness, 0x07 = InlineQos | DataFlag | Endianness

                if (total_size <= max_frag_size) {
                    const data_submessage_len: u32 = 20 + inline_qos_len + @as(u32, @intCast(frag_len));
                    const data_header: u32 = (data_submessage_len << 16) | (@as(u32, data_flags) << 8) | @as(u32, @backingInt(rtps.Submessage.SubmessageKind.DATA));
                    try msg_ser.serialize(data_header);
                    try msg_ser.serialize(@as(u16, 0)); // extra_flags
                    try msg_ser.serialize(@as(u16, 16)); // octetsToInlineQos
                    try msg_ser.serialize(rtps.types.EntityId_t.unknown); // readerId
                    try msg_ser.serialize(self.entity_id); // writerId
                    try msg_ser.serialize(self.sequence_number);

                    if (inline_qos_len > 0) {
                        if (has_key) {
                            try msg_ser.serialize(@as(u16, 0x0070)); // PID_KEY_HASH
                            try msg_ser.serialize(@as(u16, 16));
                            try msg_ser.writeAll(&instance_handle);
                        }
                        if (related_sample_identity) |rsi| {
                            try msg_ser.serialize(@as(u16, 0x0083)); // PID_RELATED_SAMPLE_IDENTITY
                            try msg_ser.serialize(@as(u16, 24));
                            try msg_ser.serialize(rsi.writer_guid);
                            try msg_ser.serialize(rsi.sequence_number);
                        }
                        try msg_ser.serialize(@as(u16, 0x0001)); // PID_SENTINEL
                        try msg_ser.serialize(@as(u16, 0));
                    }
                    try msg_ser.writeAll(frag_data);
                } else {
                    const data_frag_submessage_len: u32 = 32 + inline_qos_len + @as(u32, @intCast(frag_len));
                    const data_frag_header: u32 = (@as(u32, @intCast(data_frag_submessage_len)) << 16) | (@as(u32, data_flags) << 8) | @as(u32, @backingInt(rtps.Submessage.SubmessageKind.DATA_FRAG));
                    try msg_ser.serialize(data_frag_header);
                    try msg_ser.serialize(@as(u16, 0)); // extra_flags
                    try msg_ser.serialize(@as(u16, 28)); // octetsToInlineQos
                    try msg_ser.serialize(rtps.types.EntityId_t.unknown); // readerId
                    try msg_ser.serialize(self.entity_id); // writerId
                    try msg_ser.serialize(self.sequence_number);
                    try msg_ser.serialize(frag_num); // fragmentStartingNum
                    try msg_ser.serialize(@as(u16, 1)); // fragmentsInSubmessage
                    try msg_ser.serialize(@as(u16, @intCast(max_frag_size))); // fragmentSize
                    try msg_ser.serialize(@as(u32, @intCast(total_size))); // sampleSize

                    if (inline_qos_len > 0) {
                        if (has_key) {
                            try msg_ser.serialize(@as(u16, 0x0070)); // PID_KEY_HASH
                            try msg_ser.serialize(@as(u16, 16));
                            try msg_ser.writeAll(&instance_handle);
                        }
                        if (related_sample_identity) |rsi| {
                            try msg_ser.serialize(@as(u16, 0x0083)); // PID_RELATED_SAMPLE_IDENTITY
                            try msg_ser.serialize(@as(u16, 24));
                            try msg_ser.serialize(rsi.writer_guid);
                            try msg_ser.serialize(rsi.sequence_number);
                        }
                        try msg_ser.serialize(@as(u16, 0x0001)); // PID_SENTINEL
                        try msg_ser.serialize(@as(u16, 0));
                    }
                    try msg_ser.writeAll(frag_data);
                }

                if (self.publisher.participant.crypto_plugin) |crypto| {
                    const plaintext = msg_buf[unencrypted_start..msg_ser.pos];

                    var ciphertext_buf: [2048]u8 = undefined;
                    // KeyID 1 is a mock static key id for MVP
                    if (crypto.encryptSerializedPayload(plaintext, 1, &ciphertext_buf)) |encrypted| {
                        msg_ser.pos = unencrypted_start;
                        const sec_body_len: u32 = @as(u32, @intCast(encrypted.len));
                        const sec_header: u32 = (sec_body_len << 16) | (@as(u32, 0x01) << 8) | @as(u32, @backingInt(rtps.Submessage.SubmessageKind.SEC_BODY));
                        try msg_ser.serialize(sec_header);
                        try msg_ser.writeAll(encrypted);
                    } else |_| {}
                }

                const packet = msg_buf[0..msg_ser.pos];
                if (self.qos.batch.enable or self.qos.latency_budget.duration_ms > 0 or self.publisher.suspended.load(.seq_cst)) {
                    const max_batch_bytes = @min(self.qos.batch.max_data_bytes, @as(u32, @intCast(self.batch_buffer.len)));
                    if (packet.len > self.batch_buffer.len) {
                        try self.flush();
                        try self.sendPacket(packet, remote_endpoints.items);
                    } else {
                        self.batch_lock.lock();
                        if (self.batch_pos == 0) {
                            @memcpy(self.batch_buffer[0..packet.len], packet);
                            self.batch_pos += packet.len;
                        } else {
                            // Skip the 20-byte header on subsequent messages
                            const submessages = packet[20..];
                            if (self.batch_pos + submessages.len > max_batch_bytes or self.batch_pos + submessages.len > self.batch_buffer.len) {
                                self.batch_lock.unlock(); // Unlock before flushing
                                try self.flush();
                                self.batch_lock.lock();
                                // Now batch_pos is 0 again
                                @memcpy(self.batch_buffer[0..packet.len], packet);
                                self.batch_pos += packet.len;
                            } else {
                                @memcpy(self.batch_buffer[self.batch_pos .. self.batch_pos + submessages.len], submessages);
                                self.batch_pos += submessages.len;
                            }
                        }
                        self.batch_lock.unlock();
                    }
                } else {
                    try self.sendPacket(packet, remote_endpoints.items);
                }

                offset += frag_len;
                frag_num += 1;
            }

            // Send HEARTBEAT_FRAG proactively to announce all fragments are available
            var hb_buf: [256]u8 = undefined;
            var hb_builder = try rtps.MessageBuilder.init(&hb_buf, self.publisher.participant.guid_prefix);
            try hb_builder.addInfoTs();
            try hb_builder.addHeartbeatFrag(rtps.types.EntityId_t.unknown, self.entity_id, self.sequence_number, frag_num - 1, self.heartbeat_count);
            self.heartbeat_count +%= 1;
            const hb_packet = hb_builder.finalizeAndEncrypt(self.publisher.participant.crypto_plugin, self.entity_id, self.publisher.participant.allocator) catch hb_builder.msg_ser.buffer[0..hb_builder.msg_ser.pos];
            try self.sendPacket(hb_packet, remote_endpoints.items);
        }

        return rtps.types.SampleIdentity_t{
            .writer_guid = rtps.types.GUID_t{ .prefix = self.publisher.participant.guid_prefix, .entity_id = self.entity_id },
            .sequence_number = self.sequence_number,
        };
    }

    /// @brief Retrieves the list of currently matched subscriptions.
    pub fn getMatchedSubscriptions(self: *DataWriter, allocator: std.mem.Allocator) ![]rtps.types.InstanceHandle_t {
        self.write_lock.lock();
        defer self.write_lock.unlock();

        var handles = try allocator.alloc(rtps.types.InstanceHandle_t, self.matched_readers.items.len);
        for (self.matched_readers.items, 0..) |mr, i| {
            handles[i] = rtps.types.guidToInstanceHandle(mr.guid);
        }
        return handles;
    }

    /// @brief Retrieves the data of the matched subscription.
    pub fn getMatchedSubscriptionData(self: *DataWriter, handle: rtps.types.InstanceHandle_t) !DiscoveredReaderData {
        const guid = rtps.types.instanceHandleToGuid(handle);

        self.write_lock.lock();
        var found = false;
        for (self.matched_readers.items) |mr| {
            if (std.meta.eql(mr.guid, guid)) {
                found = true;
                break;
            }
        }
        self.write_lock.unlock();

        if (!found) return error.NotMatched;

        if (self.publisher.participant.findRemoteReaderData(guid)) |data| {
            return data;
        }
        return error.NotFound;
    }

    /// @brief Match a local DataReader and update publication matched status.
    pub fn matchLocalReader(self: *DataWriter, reader: *DataReader) !bool {
        if (self.entity_id.entity_kind >= 0xc0 or reader.entity_id.entity_kind >= 0xc0) return false;

        if (!std.mem.eql(u8, self.topic.name, reader.topic.name)) return false;
        if (self.topic.type_name.len > 0 and reader.topic.type_name.len > 0 and !std.mem.eql(u8, self.topic.type_name, reader.topic.type_name)) return false;
        if (!Qos.matchPartition(self.publisher.qos.partition.name, reader.subscriber.qos.partition.name)) return false;

        const reader_guid = GUID_t{
            .prefix = reader.subscriber.participant.guid_prefix,
            .entity_id = reader.entity_id,
        };
        const reader_handle = rtps.types.guidToInstanceHandle(reader_guid);

        {
            self.publisher.participant.registry_lock.lockShared();
            const is_ignored = self.publisher.participant.ignored_subscriptions.contains(reader_handle);
            self.publisher.participant.registry_lock.unlockShared();
            if (is_ignored) return false;
        }

        if (Qos.checkCompatibility(self.qos, reader.qos)) |incompat_id| {
            self.status_lock.lock();
            self.offered_incompatible_qos_status.total_count += 1;
            self.offered_incompatible_qos_status.total_count_change += 1;
            self.offered_incompatible_qos_status.last_policy_id = incompat_id;
            self.status_lock.unlock();
            self.notifyStatusChange(.offered_incompatible_qos);
            return false;
        }

        self.write_lock.lock();
        for (self.matched_readers.items) |mr| {
            if (std.meta.eql(mr.guid, reader_guid)) {
                self.write_lock.unlock();
                return true;
            }
        }

        try self.matched_readers.append(self.publisher.allocator, .{
            .guid = reader_guid,
            .locator = null,
            .highest_acked_seq = 0,
        });
        self.publication_matched_status.total_count += 1;
        self.publication_matched_status.total_count_change += 1;
        self.publication_matched_status.current_count += 1;
        self.publication_matched_status.current_count_change = 1;
        self.publication_matched_status.last_publication_handle = reader_handle;
        self.write_lock.unlock();

        self.notifyStatusChange(.publication_matched);
        return true;
    }

    /// @brief Unmatch a local DataReader.
    pub fn unmatchLocalReader(self: *DataWriter, reader: *DataReader) void {
        const reader_guid = GUID_t{
            .prefix = reader.subscriber.participant.guid_prefix,
            .entity_id = reader.entity_id,
        };
        self.write_lock.lock();
        var found_idx: ?usize = null;
        for (self.matched_readers.items, 0..) |mr, i| {
            if (std.meta.eql(mr.guid, reader_guid)) {
                found_idx = i;
                break;
            }
        }
        if (found_idx) |idx| {
            _ = self.matched_readers.swapRemove(idx);
            if (self.publication_matched_status.current_count > 0) {
                self.publication_matched_status.current_count -= 1;
            }
            self.publication_matched_status.current_count_change = -1;
            self.publication_matched_status.last_publication_handle = rtps.types.guidToInstanceHandle(reader_guid);
            self.write_lock.unlock();
            self.notifyStatusChange(.publication_matched);
        } else {
            self.write_lock.unlock();
        }
    }

    /// @brief Match a remote DiscoveredReaderData and update publication matched status.
    pub fn matchRemoteReader(self: *DataWriter, reader_data: DiscoveredReaderData) !bool {
        if (self.entity_id.entity_kind >= 0xc0 or reader_data.endpoint_guid.entity_id.entity_kind >= 0xc0) return false;

        if (!std.mem.eql(u8, self.topic.name, reader_data.topic_name)) return false;
        if (self.topic.type_name.len > 0 and reader_data.type_name.len > 0 and !std.mem.eql(u8, self.topic.type_name, reader_data.type_name)) return false;
        if (!Qos.matchPartition(self.publisher.qos.partition.name, reader_data.partition_name)) return false;

        const reader_handle = rtps.types.guidToInstanceHandle(reader_data.endpoint_guid);
        {
            self.publisher.participant.registry_lock.lockShared();
            const is_ignored = self.publisher.participant.ignored_subscriptions.contains(reader_handle);
            self.publisher.participant.registry_lock.unlockShared();
            if (is_ignored) return false;
        }

        if (Qos.checkCompatibility(self.qos, reader_data)) |incompat_id| {
            self.status_lock.lock();
            self.offered_incompatible_qos_status.total_count += 1;
            self.offered_incompatible_qos_status.total_count_change += 1;
            self.offered_incompatible_qos_status.last_policy_id = incompat_id;
            self.status_lock.unlock();
            self.notifyStatusChange(.offered_incompatible_qos);
            return false;
        }

        self.write_lock.lock();
        for (self.matched_readers.items) |mr| {
            if (std.meta.eql(mr.guid, reader_data.endpoint_guid)) {
                self.write_lock.unlock();
                return true;
            }
        }

        try self.matched_readers.append(self.publisher.allocator, .{
            .guid = reader_data.endpoint_guid,
            .locator = null,
            .highest_acked_seq = 0,
        });
        self.publication_matched_status.total_count += 1;
        self.publication_matched_status.total_count_change += 1;
        self.publication_matched_status.current_count += 1;
        self.publication_matched_status.current_count_change = 1;
        self.publication_matched_status.last_publication_handle = reader_handle;
        self.write_lock.unlock();

        self.notifyStatusChange(.publication_matched);
        return true;
    }
};

test "DataWriter initialization and write" {
    var factory = DomainParticipantFactory.getInstance();
    var participant = try factory.createParticipant(0, null, std.testing.allocator);
    defer factory.deleteParticipant(participant, std.testing.allocator) catch {};

    var publisher = try participant.createPublisher(null);

    const topic = Topic.init("TestTopic", "TestType");
    const qos = WriterQos{};
    const entity_id = rtps.types.EntityId_t.unknown;

    const writer = try publisher.createDataWriter(topic, qos, entity_id);

    const TestData = struct { x: u32, y: u32 };

    // Write will serialize the payload and increment sequence number.
    // It won't actually send network packets unless there are discovered participants, which there are none here.
    try writer.write(TestData{ .x = 10, .y = 20 });

    try std.testing.expectEqual(@as(i64, 2), writer.sequence_number.low);
}

/// @brief Data writer listener structure.
pub const DataWriterListener = struct {
    context: ?*anyopaque = null,
    on_liveliness_lost: ?*const fn (context: ?*anyopaque, writer: *DataWriter, status: LivelinessLostStatus) void = null,
    on_offered_deadline_missed: ?*const fn (context: ?*anyopaque, writer: *DataWriter, status: DeadlineMissedStatus) void = null,
    on_publication_matched: ?*const fn (context: ?*anyopaque, writer: *DataWriter, status: MatchedStatus) void = null,
    on_offered_incompatible_qos: ?*const fn (context: ?*anyopaque, writer: *DataWriter, status: IncompatibleQosStatus) void = null,
};

test "DataWriter concurrent writes" {
    var factory = DomainParticipantFactory.getInstance();
    var participant = try factory.createParticipant(0, null, std.testing.allocator);
    defer factory.deleteParticipant(participant, std.testing.allocator) catch {};

    var publisher = try participant.createPublisher(null);
    const topic = Topic.init("ConcurrentTopic", "ConcurrentType");
    const qos = WriterQos{};
    const entity_id = rtps.types.EntityId_t.unknown;
    const writer = try publisher.createDataWriter(topic, qos, entity_id);

    const Data = struct { val: u32 };

    const ThreadFunc = struct {
        fn run(w: *DataWriter) void {
            var i: u32 = 0;
            while (i < 100) : (i += 1) {
                w.write(Data{ .val = i }) catch {};
            }
        }
    }.run;

    var t1 = try std.Thread.spawn(.{}, ThreadFunc, .{writer});
    var t2 = try std.Thread.spawn(.{}, ThreadFunc, .{writer});
    var t3 = try std.Thread.spawn(.{}, ThreadFunc, .{writer});

    t1.join();
    t2.join();
    t3.join();

    try std.testing.expectEqual(@as(i64, 301), writer.sequence_number.low);
}

test "DataWriter local pub-sub direct delivery" {
    var factory = DomainParticipantFactory.getInstance();
    var participant = try factory.createParticipant(0, null, std.testing.allocator);
    defer factory.deleteParticipant(participant, std.testing.allocator) catch {};

    var publisher = try participant.createPublisher(null);
    var subscriber = try participant.createSubscriber(null);

    const topic = Topic.init("LocalDeliveryTopic", "TestMsg");
    const writer = try publisher.createDataWriter(topic, .{}, rtps.types.EntityId_t.unknown);
    const reader = try subscriber.createDataReader(topic, .{}, rtps.types.EntityId_t.unknown);

    const TestMsg = struct { id: u32, value: f32 };
    try writer.write(TestMsg{ .id = 42, .value = 3.14 });

    // Local delivery delivers directly into reader's history cache!
    const sample = try reader.takeNextSample(TestMsg);
    try std.testing.expect(sample != null);
    try std.testing.expectEqual(@as(u32, 42), sample.?.data.id);
    try std.testing.expectApproxEqAbs(@as(f32, 3.14), sample.?.data.value, 0.001);
    try std.testing.expect(sample.?.info.valid_data);
}

test "DataWriter dispose and unregister instance lifecycle" {
    var factory = DomainParticipantFactory.getInstance();
    var participant = try factory.createParticipant(0, null, std.testing.allocator);
    defer factory.deleteParticipant(participant, std.testing.allocator) catch {};

    var publisher = try participant.createPublisher(null);
    const topic = Topic.init("LifecycleTopic", "KeyedMsg");
    var qos = WriterQos{};
    qos.history.depth = 10;
    qos.writer_data_lifecycle.autodispose_unregistered_instances = false;
    const writer = try publisher.createDataWriter(topic, qos, rtps.types.EntityId_t.unknown);

    const KeyedMsg = struct { key: u32, val: u32 };
    try writer.write(KeyedMsg{ .key = 1, .val = 100 });
    try writer.dispose(KeyedMsg{ .key = 1, .val = 100 }, null);
    try writer.unregisterInstance(KeyedMsg{ .key = 1, .val = 100 }, null);

    // 3 changes recorded in HistoryCache: ALIVE, NOT_ALIVE_DISPOSED, NOT_ALIVE_UNREGISTERED
    try std.testing.expectEqual(@as(usize, 3), writer.history_cache.getLen());
}

test "DataWriter and DataReader DDS-JSON end-to-end communication" {
    var factory = DomainParticipantFactory.getInstance();
    var participant = try factory.createParticipant(0, null, std.testing.allocator);
    defer factory.deleteParticipant(participant, std.testing.allocator) catch {};

    var publisher = try participant.createPublisher(null);
    var subscriber = try participant.createSubscriber(null);

    const topic = Topic.init("JsonTelemetryTopic", "TelemetryData");

    var writer_qos = WriterQos{};
    writer_qos.representation = Qos.DataRepresentationQosPolicy.init(&.{.json});

    var reader_qos = Qos.ReaderQos{};
    reader_qos.representation = Qos.DataRepresentationQosPolicy.init(&.{.json});

    const writer = try publisher.createDataWriter(topic, writer_qos, rtps.types.EntityId_t.unknown);
    const reader = try subscriber.createDataReader(topic, reader_qos, rtps.types.EntityId_t.unknown);

    const TelemetryData = struct {
        device_id: u32,
        metric: []const u8,
        value: f64,
        enabled: bool,
    };

    const original_sample = TelemetryData{
        .device_id = 777,
        .metric = "temperature_celsius",
        .value = 24.85,
        .enabled = true,
    };

    try writer.write(original_sample);

    // Verify reader history cache received the change
    try std.testing.expectEqual(@as(usize, 1), reader.history_cache.getLen());

    // Verify reading back the sample
    const samples = try reader.read(TelemetryData, 10, .any, .any, .any);
    defer std.testing.allocator.free(samples);

    try std.testing.expectEqual(@as(usize, 1), samples.len);
    const read_sample = samples[0];
    try std.testing.expect(read_sample.info.valid_data);
    try std.testing.expectEqual(@as(u32, 777), read_sample.data.device_id);
    try std.testing.expectEqualStrings("temperature_celsius", read_sample.data.metric);
    try std.testing.expectApproxEqAbs(24.85, read_sample.data.value, 0.001);
    try std.testing.expectEqual(true, read_sample.data.enabled);
}
