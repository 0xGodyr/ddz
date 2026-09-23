//! @file dynamic_data_reader.zig
//! @brief DataReader wrapper supporting runtime type decoding via XTypes TypeObjects.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const root = @import("../root.zig");
const rtps = root.rtps;
const cdr = root.cdr;
const domain_participant = @import("../dcps/domain_participant.zig");
const DomainParticipant = domain_participant.DomainParticipant;
const Topic = @import("../dcps/topic.zig").Topic;
const Publisher = @import("../dcps/publisher.zig").Publisher;
const Subscriber = @import("../dcps/subscriber.zig").Subscriber;
const DataReader = @import("../dcps/data_reader.zig").DataReader;
const ReaderQos = @import("../dcps/qos.zig").ReaderQos;
const xtypes = @import("xtypes.zig");
const sedp = @import("../discovery/sedp.zig");
const DiscoveredWriterData = sedp.DiscoveredWriterData;
const Deserializer = @import("../cdr/deserializer.zig").Deserializer;
const Requester = @import("../rpc/rpc.zig").Requester;

/// @brief Dynamic data reader structure.
pub const DynamicDataReader = struct {
    allocator: std.mem.Allocator,
    subscriber: *Subscriber,
    participant: *DomainParticipant,
    underlying_reader: *DataReader,
    type_obj: ?xtypes.TypeObject = null,
    topic_name: []const u8,

    /// @brief Initializes a new instance.
    pub fn init(subscriber: *Subscriber, topic_name: []const u8, qos: ReaderQos) !DynamicDataReader {
        // Create an untyped Topic struct
        const topic = Topic.init(topic_name, "");
        const reader = try subscriber.createDataReader(topic, qos, rtps.types.EntityId_t.unknown);

        return .{
            .allocator = subscriber.allocator,
            .subscriber = subscriber,
            .participant = subscriber.participant,
            .underlying_reader = reader,
            .topic_name = topic_name,
        };
    }

    /// @brief Deinitializes the instance.
    pub fn deinit(self: *DynamicDataReader) void {
        if (self.type_obj) |*t| t.deinit(self.allocator);
        self.subscriber.deleteDataReader(self.underlying_reader) catch {};
    }

    /// @brief Read dynamic without removing from cache.
    pub fn readDynamic(self: *DynamicDataReader, seq_num: rtps.types.SequenceNumber_t) !?xtypes.DynamicValue {
        if (self.type_obj == null) {
            try self.resolveTypeObject();
        }
        const type_obj = self.type_obj orelse return null;
        const change = self.underlying_reader.history_cache.getChange(seq_num) orelse return null;
        return try xtypes.deserializeDynamic(self.allocator, change.data_value, &type_obj);
    }

    /// @brief Take dynamic, removing the change from the cache.
    pub fn takeDynamic(self: *DynamicDataReader, seq_num: rtps.types.SequenceNumber_t) !?xtypes.DynamicValue {
        if (self.type_obj == null) {
            try self.resolveTypeObject();
        }
        const type_obj = self.type_obj orelse return null;

        self.underlying_reader.history_cache.acquireLock();
        defer self.underlying_reader.history_cache.releaseLock();

        var current = self.underlying_reader.history_cache.global_tail;
        while (current) |node| {
            const sn = node.change.sequence_number;
            if (sn.high == seq_num.high and sn.low == seq_num.low) {
                if (node.change.withheld) return null;
                const val = try xtypes.deserializeDynamic(self.allocator, node.change.data_value, &type_obj);
                self.underlying_reader.history_cache.removeNode(node);
                return val;
            }
            current = node.global_prev;
        }
        return null;
    }
    pub fn takeDynamicPayload(self: *DynamicDataReader, payload: []const u8) !?xtypes.DynamicValue {
        // 1. Try to resolve TypeObject if we don't have it yet
        if (self.type_obj == null) {
            try self.resolveTypeObject();
        }

        const type_obj = self.type_obj orelse return null;

        // 2. Get the payload from the underlying reader

        // 3. Dynamically deserialize
        return try xtypes.deserializeDynamic(self.allocator, payload, &type_obj);
    }

    /// @brief Resolve type object.
    fn resolveTypeObject(self: *DynamicDataReader) !void {
        if (self.type_obj != null) return;

        const participant = self.underlying_reader.subscriber.participant;

        // 0. Check local registry first (if writer is in same process)
        const DomainParticipantModule = domain_participant;
        DomainParticipantModule.global_registry_lock.lockShared();
        for (DomainParticipantModule.global_participants) |opt_p| {
            if (opt_p) |p| {
                if (p.domain_id != participant.domain_id) continue;
                p.registry_lock.lockShared();
                for (p.publishers.items) |pub_ptr| {
                    const publisher: *Publisher = @ptrCast(@alignCast(pub_ptr));
                    for (publisher.writers.items) |writer| {
                        if (std.mem.eql(u8, writer.topic.name, self.underlying_reader.topic.name)) {
                            if (writer.topic.type_object_cdr.len > 0) {
                                self.type_obj = xtypes.deserializeTypeObject(self.allocator, writer.topic.type_object_cdr) catch null;
                                if (self.type_obj != null) {
                                    p.registry_lock.unlockShared();
                                    DomainParticipantModule.global_registry_lock.unlockShared();
                                    return;
                                }
                            }
                            if (p.type_objects.get(writer.topic.type_name)) |local_obj| {
                                const cdr_bytes = xtypes.serializeTypeObject(self.allocator, local_obj) catch null;
                                if (cdr_bytes) |bytes| {
                                    defer self.allocator.free(bytes);
                                    self.type_obj = xtypes.deserializeTypeObject(self.allocator, bytes) catch null;
                                    if (self.type_obj != null) {
                                        p.registry_lock.unlockShared();
                                        DomainParticipantModule.global_registry_lock.unlockShared();
                                        return;
                                    }
                                }
                            }
                        }
                    }
                }
                p.registry_lock.unlockShared();
            }
        }
        DomainParticipantModule.global_registry_lock.unlockShared();

        const sedp_reader = participant.sedp_pub_reader orelse return;

        var matching_cdr: ?[]u8 = null;
        var matching_type_name_buf: [128]u8 = undefined;
        var matching_type_name_len: usize = 0;

        {
            sedp_reader.history_cache.acquireLock();
            defer sedp_reader.history_cache.releaseLock();

            var current = sedp_reader.history_cache.global_head;
            while (current) |node| : (current = node.global_next) {
                const data_value = node.change.data_value;
                var des = Deserializer.init(data_value, .Little);
                const discovered = des.deserialize(DiscoveredWriterData) catch continue;

                if (std.mem.eql(u8, discovered.topic_name, self.topic_name)) {
                    if (discovered.type_object_cdr.len > 0) {
                        matching_cdr = self.allocator.dupe(u8, discovered.type_object_cdr) catch null;
                        break;
                    } else if (matching_type_name_len == 0 and discovered.type_name.len <= matching_type_name_buf.len) {
                        @memcpy(matching_type_name_buf[0..discovered.type_name.len], discovered.type_name);
                        matching_type_name_len = discovered.type_name.len;
                    }
                }
            }
        }

        if (matching_cdr) |m_cdr| {
            defer self.allocator.free(m_cdr);
            self.type_obj = try xtypes.deserializeTypeObject(self.allocator, m_cdr);
            return;
        }

        if (matching_type_name_len > 0) {
            const discovered_type_name = matching_type_name_buf[0..matching_type_name_len];
            if (participant.type_lookup_req_writer != null and participant.type_lookup_rep_reader != null) {
                var req = xtypes.TypeLookupRequest{
                    .type_name_len = @as(u32, @intCast(matching_type_name_len)),
                };
                @memcpy(req.type_name[0..matching_type_name_len], discovered_type_name);

                var requester = Requester(xtypes.TypeLookupRequest, xtypes.TypeLookupReply).init(participant.type_lookup_req_writer.?, participant.type_lookup_rep_reader.?);

                const req_id = try requester.sendRequest(req);
                std.log.debug("[Subscriber] Sent TypeLookupRequest for type: {s}", .{discovered_type_name});
                if (try requester.waitForReply(req_id, 2000)) |rep| {
                    if (rep.type_object_len > 0 and rep.type_object_len <= rep.type_object_cdr.len) {
                        std.log.debug("[Subscriber] Received TypeLookupReply! length: {d}", .{rep.type_object_len});
                        self.type_obj = try xtypes.deserializeTypeObject(self.allocator, rep.type_object_cdr[0..rep.type_object_len]);
                        return;
                    }
                }
            }
        }
    }
};
