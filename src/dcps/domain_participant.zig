//! @file domain_participant.zig
//! @brief Implements the top-level DomainParticipant entity, managing discovery, endpoints, and domain isolation.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const root = @import("../root.zig");
const rtps = root.rtps;
const net = root.net;
const RemoteParticipant = @import("remote_participant.zig").RemoteParticipant;

const os = @import("../os.zig");
/// @brief Get tick count64.
const GetTickCount64 = os.getTickCount64;
/// @brief Sleep.
const Sleep = os.sleepMs;
const Publisher = @import("publisher.zig").Publisher;
const Subscriber = @import("subscriber.zig").Subscriber;
const DataWriter = @import("data_writer.zig").DataWriter;
const DataReader = @import("data_reader.zig").DataReader;
const topic = @import("topic.zig");
const Topic = topic.Topic;
const ContentFilteredTopic = topic.ContentFilteredTopic;

const Status = @import("status.zig");
const StatusKind = Status.StatusKind;
const InconsistentTopicStatus = Status.InconsistentTopicStatus;
const DeadlineMissedStatus = Status.DeadlineMissedStatus;
const LivelinessLostStatus = Status.LivelinessLostStatus;
const MatchedStatus = Status.MatchedStatus;
const IncompatibleQosStatus = Status.IncompatibleQosStatus;
const SampleRejectedStatus = Status.SampleRejectedStatus;
const LivelinessChangedStatus = Status.LivelinessChangedStatus;

const Qos = @import("qos.zig");
const PublisherQos = Qos.PublisherQos;
const SubscriberQos = Qos.SubscriberQos;
const TopicQos = Qos.TopicQos;
const ReaderQos = Qos.ReaderQos;
const WriterQos = Qos.WriterQos;
const DomainParticipantQos = Qos.DomainParticipantQos;

const Entity = @import("entity.zig").Entity;
const StatusCondition = @import("condition.zig").StatusCondition;

const AuthenticationPlugin = @import("../security/authentication_plugin.zig").AuthenticationPlugin;
const AccessControlPlugin = @import("../security/access_control_plugin.zig").AccessControlPlugin;
const CryptographyPlugin = @import("../security/cryptography_plugin.zig").CryptographyPlugin;

const xtypes = @import("../types/xtypes.zig");
const TypeObject = xtypes.TypeObject;

const sedp = @import("../discovery/sedp.zig");
const DiscoveredWriterData = sedp.DiscoveredWriterData;
const DiscoveredReaderData = sedp.DiscoveredReaderData;

const spdp = @import("../discovery/spdp.zig");
const SPDPDiscoveredParticipantData = spdp.SPDPDiscoveredParticipantData;

const RtpsReceiver = @import("../rtps/rtps_receiver.zig").RtpsReceiver;
const MessageBuilder = @import("../rtps/message_builder.zig").MessageBuilder;
const Serializer = @import("../cdr/serializer.zig").Serializer;
const Deserializer = @import("../cdr/deserializer.zig").Deserializer;
const rpc = @import("../rpc/rpc.zig");
const DomainParticipantFactory = @import("domain_participant_factory.zig").DomainParticipantFactory;

pub var global_registry_lock: SpinRwLock = .{};
pub var global_participants: [256]?*DomainParticipant = std.mem.zeroes([256]?*DomainParticipant);

/// @brief Domain participant structure.
/// @brief Domain participant listener structure.
pub const DomainParticipantListener = struct {
    context: ?*anyopaque = null,
    // TopicListener
    on_inconsistent_topic: ?*const fn (context: ?*anyopaque, topic: *Topic, status: InconsistentTopicStatus) void = null,
    // PublisherListener
    on_offered_deadline_missed: ?*const fn (context: ?*anyopaque, writer: *DataWriter, status: DeadlineMissedStatus) void = null,
    on_liveliness_lost: ?*const fn (context: ?*anyopaque, writer: *DataWriter, status: LivelinessLostStatus) void = null,
    on_publication_matched: ?*const fn (context: ?*anyopaque, writer: *DataWriter, status: MatchedStatus) void = null,
    on_offered_incompatible_qos: ?*const fn (context: ?*anyopaque, writer: *DataWriter, status: IncompatibleQosStatus) void = null,
    // SubscriberListener
    on_data_on_readers: ?*const fn (context: ?*anyopaque, subscriber: *Subscriber) void = null,
    on_data_available: ?*const fn (context: ?*anyopaque, reader: *DataReader) void = null,
    on_sample_rejected: ?*const fn (context: ?*anyopaque, reader: *DataReader, status: SampleRejectedStatus) void = null,
    on_liveliness_changed: ?*const fn (context: ?*anyopaque, reader: *DataReader, status: LivelinessChangedStatus) void = null,
    on_requested_deadline_missed: ?*const fn (context: ?*anyopaque, reader: *DataReader, status: DeadlineMissedStatus) void = null,
    on_subscription_matched: ?*const fn (context: ?*anyopaque, reader: *DataReader, status: MatchedStatus) void = null,
    on_requested_incompatible_qos: ?*const fn (context: ?*anyopaque, reader: *DataReader, status: IncompatibleQosStatus) void = null,
    on_sample_lost: ?*const fn (context: ?*anyopaque, reader: *DataReader, lost_count: u32) void = null,
};

pub const DomainParticipant = struct {
    default_publisher_qos: PublisherQos = .{},
    default_subscriber_qos: SubscriberQos = .{},
    default_topic_qos: TopicQos = .{},

    entity: Entity,
    qos: DomainParticipantQos,
    listener: ?DomainParticipantListener = null,
    allocator: std.mem.Allocator,
    domain_id: u32,
    participant_id: u32,
    next_entity_id: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    guid_prefix: rtps.types.GuidPrefix_t,
    filter_expression: ?[]const u8 = null,
    filter_expression_owned: bool = false,
    permissions_doc: ?[]const u8 = null,
    auth_plugin: ?*AuthenticationPlugin = null,
    access_plugin: ?*AccessControlPlugin = null,
    crypto_plugin: ?*CryptographyPlugin = null,

    spdp_multicast_port: u16,
    spdp_unicast_port: u16,
    sedp_multicast_port: u16,
    sedp_unicast_port: u16,

    // Sockets
    spdp_socket: net.UdpSocket,
    user_socket: net.UdpSocket,
    sockets_closed: bool = false,
    user_thread: ?std.Thread = null,

    // Registry
    registry_lock: SpinRwLock = .{},
    discovered_participants: std.MultiArrayList(RemoteParticipant),
    shared_keys: std.AutoHashMapUnmanaged(rtps.types.GuidPrefix_t, [32]u8) = .empty,

    // Lifecycle
    spdp_thread: ?std.Thread = null,
    liveliness_thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Registries for routing
    publishers: std.ArrayListUnmanaged(*Publisher) = .empty,
    subscribers: std.ArrayListUnmanaged(*Subscriber) = .empty,

    // Built-in SEDP Endpoints
    sedp_publisher: ?*Publisher = null,
    sedp_subscriber: ?*Subscriber = null,
    sedp_pub_writer: ?*DataWriter = null,
    sedp_sub_writer: ?*DataWriter = null,
    sedp_pub_reader: ?*DataReader = null,
    sedp_sub_reader: ?*DataReader = null,

    type_lookup_req_writer: ?*DataWriter = null,
    type_lookup_req_reader: ?*DataReader = null,
    type_lookup_rep_writer: ?*DataWriter = null,
    type_lookup_rep_reader: ?*DataReader = null,
    type_lookup_thread: ?std.Thread = null,

    // Stored TypeObjects by name (for the replier)
    type_objects: std.StringHashMapUnmanaged(TypeObject) = .empty,

    // Administrative ignore sets
    ignored_participants: std.AutoHashMapUnmanaged(rtps.types.InstanceHandle_t, void) = .empty,
    ignored_topics: std.AutoHashMapUnmanaged(rtps.types.InstanceHandle_t, void) = .empty,
    ignored_publications: std.AutoHashMapUnmanaged(rtps.types.InstanceHandle_t, void) = .empty,
    ignored_subscriptions: std.AutoHashMapUnmanaged(rtps.types.InstanceHandle_t, void) = .empty,

    pub fn getDefaultPublisherQos(self: *DomainParticipant) PublisherQos {
        return self.default_publisher_qos;
    }

    pub fn setDefaultPublisherQos(self: *DomainParticipant, qos: PublisherQos) !void {
        self.default_publisher_qos = qos;
    }

    pub fn getDefaultSubscriberQos(self: *DomainParticipant) SubscriberQos {
        return self.default_subscriber_qos;
    }

    pub fn setDefaultSubscriberQos(self: *DomainParticipant, qos: SubscriberQos) !void {
        self.default_subscriber_qos = qos;
    }

    pub fn getDefaultTopicQos(self: *DomainParticipant) TopicQos {
        return self.default_topic_qos;
    }

    pub fn setDefaultTopicQos(self: *DomainParticipant, qos: TopicQos) !void {
        self.default_topic_qos = qos;
    }

    /// @brief Creates a ContentFilteredTopic linked to a related Topic with filter expression and dynamic parameters.
    pub fn createContentFilteredTopic(self: *DomainParticipant, name: []const u8, related_topic: Topic, filter_expression: []const u8, expression_parameters: []const []const u8) !ContentFilteredTopic {
        return ContentFilteredTopic.initWithParams(self.allocator, name, related_topic, filter_expression, expression_parameters);
    }

    pub const default_domain_id: u32 = 0;

    /// @brief Initializes a new instance.
    pub fn init(allocator: std.mem.Allocator, domain_id: u32, participant_id: u32, qos: DomainParticipantQos) !DomainParticipant {
        // Generate a random GuidPrefix for now
        var guid_prefix: rtps.types.GuidPrefix_t = std.mem.zeroes(rtps.types.GuidPrefix_t);
        const time = @as(u64, @intCast(GetTickCount64()));
        const pid = participant_id;
        guid_prefix[2] = @as(u8, @truncate(time >> 0));
        guid_prefix[3] = @as(u8, @truncate(time >> 8));
        guid_prefix[4] = @as(u8, @truncate(time >> 16));
        guid_prefix[5] = @as(u8, @truncate(time >> 24));
        guid_prefix[6] = @as(u8, @truncate(pid >> 0));
        guid_prefix[7] = @as(u8, @truncate(pid >> 8));
        // Ensure vendor ID is set (using first 2 bytes)
        guid_prefix[0] = rtps.types.vendor_ddz[0];
        guid_prefix[1] = rtps.types.vendor_ddz[1];

        // Standard RTPS Port Formulas
        const pb: u32 = 7400;
        const dg: u32 = 250;
        const pg: u32 = 2;
        const d0: u32 = 0;
        const d1: u32 = 10;
        const d2: u32 = 1;
        const d3: u32 = 11;

        var found_pid = participant_id;
        var spdp_multicast_port: u16 = 0;
        var spdp_unicast_port: u16 = 0;
        var sedp_multicast_port: u16 = 0;
        var sedp_unicast_port: u16 = 0;

        var user_socket = try net.UdpSocket.init();
        errdefer user_socket.deinit();
        try user_socket.setReceiveTimeout(500);

        while (found_pid < 120) : (found_pid += 1) {
            spdp_multicast_port = @intCast(pb + (dg * domain_id) + d0);
            spdp_unicast_port = @intCast(pb + (dg * domain_id) + d1 + (pg * found_pid));
            sedp_multicast_port = @intCast(pb + (dg * domain_id) + d2);
            sedp_unicast_port = @intCast(pb + (dg * domain_id) + d3 + (pg * found_pid));

            if (user_socket.bind(sedp_unicast_port + 2, null, false)) |_| {
                user_socket.enableMulticastLoop() catch {};
                break;
            } else |_| {}
        }

        var spdp_socket = try net.UdpSocket.init();
        errdefer spdp_socket.deinit();
        try spdp_socket.setReceiveTimeout(500);
        try spdp_socket.bind(spdp_multicast_port, null, true);
        spdp_socket.joinMulticastGroup([4]u8{ 239, 255, 0, 1 }) catch |err| {
            std.log.warn("Failed to join multicast group: {}\n", .{err});
        };

        const res = DomainParticipant{
            .entity = undefined,
            .qos = qos,
            .allocator = allocator,
            .domain_id = domain_id,
            .participant_id = found_pid,
            .guid_prefix = guid_prefix,
            .auth_plugin = null,
            .access_plugin = null,
            .crypto_plugin = null,
            .spdp_multicast_port = spdp_multicast_port,
            .spdp_unicast_port = spdp_unicast_port,
            .sedp_multicast_port = sedp_multicast_port,
            .sedp_unicast_port = sedp_unicast_port,
            .spdp_socket = spdp_socket,
            .user_socket = user_socket,
            .discovered_participants = std.MultiArrayList(RemoteParticipant){},
            .publishers = .empty,
            .subscribers = .empty,
            .type_objects = .empty,
        };
        return res;
    }

    /// @brief Deinitializes the instance.
    pub fn deinit(self: *@This()) void {
        self.stop();

        // No need to call p.deinit() manually here since they are in publishers array
        // and we will destroy them below.

        for (self.publishers.items) |pub_typed| {
            pub_typed.deinit();
            self.allocator.destroy(pub_typed);
        }
        self.publishers.deinit(self.allocator);
        self.publishers = .empty;

        for (self.subscribers.items) |sub_typed| {
            sub_typed.deinit();
            self.allocator.destroy(sub_typed);
        }
        self.subscribers.deinit(self.allocator);
        self.subscribers = .empty;

        var it = self.type_objects.valueIterator();
        while (it.next()) |obj| {
            obj.deinit(self.allocator);
        }
        self.type_objects.deinit(self.allocator);
        self.type_objects = .empty;

        self.ignored_participants.deinit(self.allocator);
        self.ignored_topics.deinit(self.allocator);
        self.ignored_publications.deinit(self.allocator);
        self.ignored_subscriptions.deinit(self.allocator);

        for (self.discovered_participants.items(.filter_expression)) |opt_expr| {
            if (opt_expr) |expr| self.allocator.free(expr);
        }
        if (self.filter_expression_owned) {
            if (self.filter_expression) |expr| {
                self.allocator.free(expr);
                self.filter_expression = null;
            }
        }
        self.discovered_participants.deinit(self.allocator);
        self.shared_keys.deinit(self.allocator);
        self.entity.deinit();
    }

    /// @brief Start.
    pub fn getInstanceHandle(self: *DomainParticipant) [16]u8 {
        return self.entity.getInstanceHandle();
    }

    pub fn getStatusCondition(self: *DomainParticipant) !*StatusCondition {
        return self.entity.getStatusCondition();
    }

    pub fn enable(self: *DomainParticipant) !void {
        return self.entity.enable();
    }

    /// @brief Get built-in subscriber.
    pub fn getBuiltinSubscriber(self: *DomainParticipant) ?*Subscriber {
        return self.sedp_subscriber;
    }

    pub fn registerTypeObject(self: *DomainParticipant, type_name: []const u8, type_object: TypeObject) !void {
        self.registry_lock.lock();
        defer self.registry_lock.unlock();
        try self.type_objects.put(self.allocator, type_name, type_object);
    }

    pub fn enableImpl(ptr: *anyopaque) anyerror!void {
        const self: *DomainParticipant = @ptrCast(@alignCast(ptr));
        if (self.running.load(.seq_cst)) return;
        self.running.store(true, .seq_cst);

        try self.initSedp();

        global_registry_lock.lock();
        for (&global_participants) |*p| {
            if (p.* == null) {
                p.* = self;
                break;
            }
        }
        global_registry_lock.unlock();

        // -------------------------------------------------------------
        // Auto-discover local participants to bypass UDP multicast issues
        // -------------------------------------------------------------
        global_registry_lock.lockShared();
        for (global_participants) |opt_p| {
            if (opt_p) |local_p| {
                if (local_p != self) {
                    const local_p_locator = rtps.types.Locator_t{
                        .kind = 1,
                        .port = local_p.sedp_unicast_port,
                        .address = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 127, 0, 0, 1 },
                    };
                    const self_locator = rtps.types.Locator_t{
                        .kind = 1,
                        .port = self.sedp_unicast_port,
                        .address = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 127, 0, 0, 1 },
                    };

                    // Add local_p to self
                    self.registry_lock.lock();
                    self.discovered_participants.append(self.allocator, .{
                        .guid_prefix = local_p.guid_prefix,
                        .metatraffic_unicast_locator = local_p_locator,
                        .last_seen_msec = @as(i64, @intCast(GetTickCount64())),
                        .filter_expression = null,
                        .public_key = null,
                    }) catch {};
                    self.registry_lock.unlock();

                    // Notify self writers
                    self.registry_lock.lockShared();
                    for (self.publishers.items) |publisher_inst| {
                        for (publisher_inst.writers.items) |writer| {
                            writer.onNewParticipantDiscovered(local_p_locator) catch {};
                        }
                    }
                    self.registry_lock.unlockShared();

                    // Add self to local_p
                    local_p.registry_lock.lock();
                    local_p.discovered_participants.append(local_p.allocator, .{
                        .guid_prefix = self.guid_prefix,
                        .metatraffic_unicast_locator = self_locator,
                        .last_seen_msec = @as(i64, @intCast(GetTickCount64())),
                        .filter_expression = null,
                        .public_key = null,
                    }) catch {};
                    local_p.registry_lock.unlock();

                    // Notify local_p writers
                    local_p.registry_lock.lockShared();
                    for (local_p.publishers.items) |publisher_inst| {
                        for (publisher_inst.writers.items) |writer| {
                            writer.onNewParticipantDiscovered(self_locator) catch {};
                        }
                    }
                    local_p.registry_lock.unlockShared();
                }
            }
        }
        global_registry_lock.unlockShared();

        self.spdp_thread = try std.Thread.spawn(.{}, spdpLoop, .{self});
        self.user_thread = try std.Thread.spawn(.{}, userLoop, .{self});
        self.liveliness_thread = try std.Thread.spawn(.{}, livelinessLoop, .{self});
        self.type_lookup_thread = try std.Thread.spawn(.{}, typeLookupLoop, .{self});
    }

    /// @brief Init sedp.
    fn initSedp(self: *DomainParticipant) !void {
        self.sedp_publisher = try self.createPublisher(null);
        self.sedp_subscriber = try self.createSubscriber(null);

        var builtin_reader_qos = ReaderQos{};
        builtin_reader_qos.history.kind = .keep_all;
        builtin_reader_qos.history.depth = 1000;
        builtin_reader_qos.reliability.kind = .reliable;

        var builtin_writer_qos = WriterQos{};
        builtin_writer_qos.reliability.kind = .reliable;

        const sedp_pub_topic = Topic.init("DCPSPublication", "DiscoveredWriterData");
        const sedp_sub_topic = Topic.init("DCPSSubscription", "DiscoveredReaderData");
        const spdp_participant_topic = Topic.init("DCPSParticipant", "SPDPDiscoveredParticipantData");
        const spdp_topic_topic = Topic.init("DCPSTopic", "DiscoveredTopicData");

        _ = try self.sedp_subscriber.?.createDataReader(spdp_participant_topic, builtin_reader_qos, rtps.types.EntityId_t.spdp_sub_reader);
        _ = try self.sedp_subscriber.?.createDataReader(spdp_topic_topic, builtin_reader_qos, rtps.types.EntityId_t.unknown);

        self.sedp_pub_writer = try self.sedp_publisher.?.createDataWriter(sedp_pub_topic, builtin_writer_qos, rtps.types.EntityId_t.sedp_pub_writer);
        self.sedp_pub_reader = try self.sedp_subscriber.?.createDataReader(sedp_pub_topic, builtin_reader_qos, rtps.types.EntityId_t.sedp_pub_reader);

        self.sedp_sub_writer = try self.sedp_publisher.?.createDataWriter(sedp_sub_topic, builtin_writer_qos, rtps.types.EntityId_t.sedp_sub_writer);
        self.sedp_sub_reader = try self.sedp_subscriber.?.createDataReader(sedp_sub_topic, builtin_reader_qos, rtps.types.EntityId_t.sedp_sub_reader);

        // TypeLookup Endpoints
        const tl_req_topic = Topic.init("TypeLookupRequestTopic", "TypeLookupRequest");
        const tl_rep_topic = Topic.init("TypeLookupReplyTopic", "TypeLookupReply");

        self.type_lookup_req_writer = try self.sedp_publisher.?.createDataWriter(tl_req_topic, builtin_writer_qos, rtps.types.EntityId_t.type_lookup_req_writer);
        self.type_lookup_req_reader = try self.sedp_subscriber.?.createDataReader(tl_req_topic, builtin_reader_qos, rtps.types.EntityId_t.type_lookup_req_reader);
        self.type_lookup_rep_writer = try self.sedp_publisher.?.createDataWriter(tl_rep_topic, builtin_writer_qos, rtps.types.EntityId_t.type_lookup_rep_writer);
        self.type_lookup_rep_reader = try self.sedp_subscriber.?.createDataReader(tl_rep_topic, builtin_reader_qos, rtps.types.EntityId_t.type_lookup_rep_reader);
    }

    /// @brief Stop.
    pub fn stop(self: *DomainParticipant) void {
        const was_running = self.running.swap(false, .seq_cst);

        global_registry_lock.lock();
        for (&global_participants) |*p| {
            if (p.* == self) {
                p.* = null;
                break;
            }
        }
        global_registry_lock.unlock();

        if (!self.sockets_closed) {
            self.sockets_closed = true;
            self.spdp_socket.deinit();
            self.user_socket.deinit();
        }

        if (was_running) {
            if (self.spdp_thread) |thread| {
                thread.join();
                self.spdp_thread = null;
            }

            if (self.user_thread) |thread| {
                thread.join();
                self.user_thread = null;
            }

            if (self.liveliness_thread) |thread| {
                thread.join();
                self.liveliness_thread = null;
            }
            if (self.type_lookup_thread) |thread| {
                thread.join();
                self.type_lookup_thread = null;
            }
        }
    }

    /// @brief Liveliness and QoS Enforcement loop.
    fn livelinessLoop(self: *DomainParticipant) void {
        const announce_period_ms: i64 = 1000;
        const lease_duration_ms: i64 = 15000;

        var last_announce: i64 = 0;

        while (self.running.load(.seq_cst)) {
            const now = @as(i64, @intCast(GetTickCount64()));

            // 1. Announce ourselves
            if (now - last_announce >= announce_period_ms) {
                self.announce() catch {};
                self.announceEndpoints() catch {};
                last_announce = now;
            }

            // 2. Check for dead participants
            self.registry_lock.lock();
            var i: usize = 0;
            while (i < self.discovered_participants.len) {
                const last_seen = self.discovered_participants.items(.last_seen_msec)[i];
                if (now - last_seen > lease_duration_ms) {
                    // Participant died/timed out
                    if (self.discovered_participants.items(.filter_expression)[i]) |expr| {
                        self.allocator.free(expr);
                    }
                    _ = self.discovered_participants.swapRemove(i);
                } else {
                    i += 1;
                }
            }
            self.registry_lock.unlock();

            // 3. QoS Enforcement (Deadlines and Writer Liveliness)
            const WriterNotif = struct { writer: *DataWriter, status: StatusKind };
            const ReaderNotif = struct { reader: *DataReader, status: StatusKind };
            var w_notifs = std.ArrayListUnmanaged(WriterNotif).empty;
            defer w_notifs.deinit(self.allocator);
            var r_notifs = std.ArrayListUnmanaged(ReaderNotif).empty;
            defer r_notifs.deinit(self.allocator);

            {
                self.registry_lock.lock();
                defer self.registry_lock.unlock();

                for (self.publishers.items) |publisher| {
                    for (publisher.writers.items) |writer| {

                        // 3.1 Liveliness QoS Enforcement (Writers)
                        if (writer.qos.liveliness.kind == .manual_by_topic) {
                            const lease = @as(i64, writer.qos.liveliness.lease_duration) * 1000;
                            const last_assert = writer.last_liveliness_assertion_time.load(.acquire);
                            if (now - last_assert > lease) {
                                writer.status_lock.lock();
                                writer.liveliness_lost_status.total_count += 1;
                                writer.liveliness_lost_status.total_count_change += 1;
                                writer.status_lock.unlock();

                                writer.last_liveliness_assertion_time.store(now, .release);
                                w_notifs.append(self.allocator, .{ .writer = writer, .status = .liveliness_lost }) catch {};
                            }
                        }

                        // 3.2 Deadline QoS Enforcement (Writers)
                        if (writer.qos.deadline.period_ms != 0xFFFFFFFF) {
                            writer.deadline_lock.lock();
                            var it = writer.last_write_time.iterator();
                            while (it.next()) |entry| {
                                const last = entry.value_ptr.*;
                                if (now - last > writer.qos.deadline.period_ms) {
                                    writer.offered_deadline_missed_status.total_count += 1;
                                    writer.offered_deadline_missed_status.total_count_change += 1;
                                    @memcpy(&writer.offered_deadline_missed_status.last_instance_handle, entry.key_ptr);
                                    entry.value_ptr.* = now;

                                    w_notifs.append(self.allocator, .{ .writer = writer, .status = .offered_deadline_missed }) catch {};
                                }
                            }
                            writer.deadline_lock.unlock();
                        }
                    }
                }

                for (self.subscribers.items) |subscriber| {
                    for (subscriber.readers.items) |reader| {
                        if (reader.qos.deadline.period_ms != 0xFFFFFFFF) {
                            reader.deadline_lock.lock();
                            var it = reader.last_receive_time.iterator();
                            while (it.next()) |entry| {
                                const last = entry.value_ptr.*;
                                if (now - last > reader.qos.deadline.period_ms) {
                                    reader.requested_deadline_missed_status.total_count += 1;
                                    reader.requested_deadline_missed_status.total_count_change += 1;
                                    @memcpy(&reader.requested_deadline_missed_status.last_instance_handle, entry.key_ptr);
                                    entry.value_ptr.* = now;

                                    r_notifs.append(self.allocator, .{ .reader = reader, .status = .requested_deadline_missed }) catch {};
                                }
                            }
                            reader.deadline_lock.unlock();
                        }
                    }
                }
            }

            for (w_notifs.items) |wn| {
                wn.writer.notifyStatusChange(wn.status);
            }
            for (r_notifs.items) |rn| {
                rn.reader.notifyStatusChange(rn.status);
            }

            // 4. Liveliness & Deadline QoS Enforcement (Readers) + DataLifecycle Autopurge
            self.registry_lock.lockShared();
            for (self.subscribers.items) |subscriber| {
                for (subscriber.readers.items) |reader| {
                    reader.deadline_lock.lock();

                    var changed = false;
                    var to_remove: std.ArrayList(rtps.types.GUID_t) = .empty;
                    defer to_remove.deinit(self.allocator);

                    var liv_it = reader.writer_liveliness.iterator();
                    while (liv_it.next()) |entry| {
                        const wguid = entry.key_ptr.*;
                        const last = entry.value_ptr.*;

                        const lease_ms: i64 = @as(i64, reader.qos.liveliness.lease_duration) * 1000;
                        if (lease_ms > 0) {
                            if (now - last > lease_ms) {
                                reader.liveliness_changed_status.alive_count -|= 1;
                                reader.liveliness_changed_status.not_alive_count += 1;
                                reader.liveliness_changed_status.alive_count_change -|= 1;
                                reader.liveliness_changed_status.not_alive_count_change += 1;
                                @memcpy(reader.liveliness_changed_status.last_publication_handle[0..12], &wguid.prefix);
                                @memcpy(reader.liveliness_changed_status.last_publication_handle[12..15], &wguid.entity_id.entity_key);
                                reader.liveliness_changed_status.last_publication_handle[15] = wguid.entity_id.entity_kind;

                                to_remove.append(self.allocator, wguid) catch {};
                                changed = true;

                                reader.history_cache.acquireLock();
                                var curr_node = reader.history_cache.global_head;
                                while (curr_node) |n| : (curr_node = n.global_next) {
                                    if (std.meta.eql(n.change.writer_guid, wguid)) {
                                        if (reader.history_cache.instance_map.getPtr(n.change.instance_handle)) |inst| {
                                            if (inst.instance_state == .alive) {
                                                inst.no_writers_generation_count += 1;
                                                inst.instance_state = .not_alive_no_writers;
                                                inst.not_alive_timestamp_ms = now;
                                            }
                                        }
                                    }
                                }
                                reader.history_cache.releaseLock();
                            }
                        }
                    }

                    for (to_remove.items) |r_guid| {
                        _ = reader.writer_liveliness.remove(r_guid);
                    }

                    reader.deadline_lock.unlock();

                    if (changed) {
                        reader.notifyStatusChange(.liveliness_changed);
                    }

                    // ReaderDataLifecycle Autopurge
                    const autopurge_no_writers_ms = reader.qos.reader_data_lifecycle.autopurge_nowriter_samples_delay_ms;
                    const autopurge_disposed_ms = reader.qos.reader_data_lifecycle.autopurge_disposed_samples_delay_ms;

                    if (autopurge_no_writers_ms != 0xFFFFFFFF or autopurge_disposed_ms != 0xFFFFFFFF) {
                        reader.history_cache.acquireLock();
                        var inst_it = reader.history_cache.instance_map.iterator();
                        var instances_to_purge: std.ArrayList([16]u8) = .empty;
                        defer instances_to_purge.deinit(self.allocator);

                        while (inst_it.next()) |entry| {
                            const inst = entry.value_ptr.*;
                            if (inst.instance_state == .not_alive_no_writers and autopurge_no_writers_ms != 0xFFFFFFFF) {
                                if (now - inst.not_alive_timestamp_ms >= autopurge_no_writers_ms) {
                                    instances_to_purge.append(self.allocator, entry.key_ptr.*) catch {};
                                }
                            } else if (inst.instance_state == .not_alive_disposed and autopurge_disposed_ms != 0xFFFFFFFF) {
                                if (now - inst.not_alive_timestamp_ms >= autopurge_disposed_ms) {
                                    instances_to_purge.append(self.allocator, entry.key_ptr.*) catch {};
                                }
                            }
                        }

                        // Actually purge
                        for (instances_to_purge.items) |handle| {
                            if (reader.history_cache.instance_map.get(handle)) |inst| {
                                var current = inst.head;
                                while (current) |n| {
                                    const next = n.instance_next;
                                    reader.history_cache.removeNode(n);
                                    current = next;
                                }
                                _ = reader.history_cache.instance_map.remove(handle);
                            }
                        }
                        reader.history_cache.releaseLock();
                    }
                }
            }
            self.registry_lock.unlockShared();

            Sleep(100);
        }
    }

    /// @brief Spdp loop.
    fn spdpLoop(self: *DomainParticipant) void {
        while (self.running.load(.seq_cst)) {
            self.processSpdp() catch |err| {
                if (!self.running.load(.seq_cst)) break;
                std.log.warn("spdpLoop error: {}\n", .{err});
            };
        }
    }

    /// @brief User loop.
    fn userLoop(self: *DomainParticipant) void {
        while (self.running.load(.seq_cst)) {
            var buffer: [2048]u8 = undefined;
            var source_locator: rtps.types.Locator_t = undefined;
            const bytes_read = self.user_socket.receiveFrom(&buffer, &source_locator) catch continue;
            RtpsReceiver.processMessage(self, buffer[0..bytes_read], source_locator) catch {};
        }
    }

    /// @brief Create publisher.
    /// @brief TypeLookup Service loop.
    fn typeLookupLoop(self: *DomainParticipant) void {
        var replier = rpc.Replier(xtypes.TypeLookupRequest, xtypes.TypeLookupReply).init(self.allocator, self.type_lookup_req_reader.?, self.type_lookup_rep_writer.?);
        defer replier.deinit();

        while (self.running.load(.seq_cst)) {
            if (replier.receiveRequest(100) catch null) |info| {
                const req = info.data;
                if (req.type_name_len > req.type_name.len) continue;

                const type_name = req.type_name[0..req.type_name_len];

                self.registry_lock.lockShared();
                const opt_obj = self.type_objects.get(type_name);
                self.registry_lock.unlockShared();

                if (opt_obj) |type_obj| {
                    if (xtypes.serializeTypeObject(self.allocator, type_obj)) |cdr_bytes| {
                        defer self.allocator.free(cdr_bytes);

                        var rep: xtypes.TypeLookupReply = undefined;
                        if (cdr_bytes.len > rep.type_object_cdr.len or req.type_name_len > rep.type_name.len) continue;

                        rep.type_name_len = req.type_name_len;
                        rep.type_object_len = @as(u32, @intCast(cdr_bytes.len));
                        @memcpy(rep.type_name[0..req.type_name_len], type_name);
                        @memcpy(rep.type_object_cdr[0..cdr_bytes.len], cdr_bytes);

                        replier.sendReply(rep, info.identity) catch {};
                    } else |_| {}
                } else {}
            }
        }
    }

    /// @brief Register a Type for the TypeLookup Service.
    pub fn registerType(self: *DomainParticipant, comptime T: type) !void {
        const obj = try xtypes.generateTypeObject(self.allocator, T);

        self.registry_lock.lock();
        defer self.registry_lock.unlock();
        try self.type_objects.put(self.allocator, obj.name, obj);
    }

    pub fn createPublisher(self: *DomainParticipant, qos: ?PublisherQos) !*Publisher {
        const actual_qos = qos orelse @TypeOf(qos.?){ .entity_factory = self.qos.entity_factory };
        const pub_ptr = try self.allocator.create(Publisher);
        pub_ptr.* = Publisher.init(self.allocator, self, actual_qos);
        pub_ptr.entity = Entity.init(self.allocator, pub_ptr, Publisher.enableImpl);
        if (actual_qos.entity_factory.autoenable_created_entities) pub_ptr.enable() catch |err| {
            pub_ptr.deinit();
            self.allocator.destroy(pub_ptr);
            return err;
        };

        self.registry_lock.lock();
        self.publishers.append(self.allocator, pub_ptr) catch |err| {
            self.registry_lock.unlock();
            pub_ptr.deinit();
            self.allocator.destroy(pub_ptr);
            return err;
        };
        self.registry_lock.unlock();

        return pub_ptr;
    }

    /// @brief Create subscriber.
    pub fn deletePublisher(self: *DomainParticipant, publisher: *Publisher) !void {
        self.registry_lock.lock();
        defer self.registry_lock.unlock();

        // Must fail if there are any DataWriters
        publisher.writers_lock.lockShared();
        const has_writers = publisher.writers.items.len > 0;
        publisher.writers_lock.unlockShared();
        if (has_writers) return error.PreconditionNotMet;

        var i: usize = 0;
        while (i < self.publishers.items.len) {
            if (self.publishers.items[i] == publisher) {
                _ = self.publishers.swapRemove(i);
                publisher.deinit();
                self.allocator.destroy(publisher);
                return;
            }
            i += 1;
        }
    }

    pub fn deleteSubscriber(self: *DomainParticipant, subscriber: *Subscriber) !void {
        self.registry_lock.lock();
        defer self.registry_lock.unlock();

        subscriber.readers_lock.lockShared();
        const has_readers = subscriber.readers.items.len > 0;
        subscriber.readers_lock.unlockShared();
        if (has_readers) return error.PreconditionNotMet;

        var i: usize = 0;
        while (i < self.subscribers.items.len) {
            if (self.subscribers.items[i] == subscriber) {
                _ = self.subscribers.swapRemove(i);
                subscriber.deinit();
                self.allocator.destroy(subscriber);
                return;
            }
            i += 1;
        }
    }

    pub fn deleteContainedEntities(self: *DomainParticipant) !void {
        self.registry_lock.lock();
        defer self.registry_lock.unlock();

        for (self.publishers.items) |p| {
            try p.deleteContainedEntities();
            p.deinit();
            self.allocator.destroy(p);
        }
        self.publishers.clearRetainingCapacity();

        for (self.subscribers.items) |s| {
            try s.deleteContainedEntities();
            s.deinit();
            self.allocator.destroy(s);
        }
        self.subscribers.clearRetainingCapacity();
    }

    /// @brief Instructs the DomainParticipant to locally ignore a remote DomainParticipant.
    pub fn ignoreParticipant(self: *DomainParticipant, handle: rtps.types.InstanceHandle_t) !void {
        self.registry_lock.lock();
        defer self.registry_lock.unlock();
        try self.ignored_participants.put(self.allocator, handle, {});

        const ignored_guid = rtps.types.instanceHandleToGuid(handle);
        var i: usize = 0;
        while (i < self.discovered_participants.len) {
            const prefix = self.discovered_participants.items(.guid_prefix)[i];
            if (std.mem.eql(u8, &prefix, &ignored_guid.prefix)) {
                if (self.discovered_participants.items(.filter_expression)[i]) |expr| {
                    self.allocator.free(expr);
                }
                _ = self.discovered_participants.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// @brief Instructs the DomainParticipant to locally ignore a Topic.
    pub fn ignoreTopic(self: *DomainParticipant, handle: rtps.types.InstanceHandle_t) !void {
        self.registry_lock.lock();
        defer self.registry_lock.unlock();
        try self.ignored_topics.put(self.allocator, handle, {});
    }

    /// @brief Instructs the DomainParticipant to locally ignore a publication.
    pub fn ignorePublication(self: *DomainParticipant, handle: rtps.types.InstanceHandle_t) !void {
        self.registry_lock.lock();
        defer self.registry_lock.unlock();
        try self.ignored_publications.put(self.allocator, handle, {});
    }

    /// @brief Instructs the DomainParticipant to locally ignore a subscription.
    pub fn ignoreSubscription(self: *DomainParticipant, handle: rtps.types.InstanceHandle_t) !void {
        self.registry_lock.lock();
        defer self.registry_lock.unlock();
        try self.ignored_subscriptions.put(self.allocator, handle, {});
    }

    pub fn createSubscriber(self: *DomainParticipant, qos: ?SubscriberQos) !*Subscriber {
        const actual_qos = qos orelse @TypeOf(qos.?){ .entity_factory = self.qos.entity_factory };
        const sub_ptr = try self.allocator.create(Subscriber);
        sub_ptr.* = Subscriber.init(self.allocator, self, actual_qos);
        sub_ptr.entity = Entity.init(self.allocator, sub_ptr, Subscriber.enableImpl);
        if (actual_qos.entity_factory.autoenable_created_entities) sub_ptr.enable() catch |err| {
            sub_ptr.deinit();
            self.allocator.destroy(sub_ptr);
            return err;
        };

        self.registry_lock.lock();
        self.subscribers.append(self.allocator, sub_ptr) catch |err| {
            self.registry_lock.unlock();
            sub_ptr.deinit();
            self.allocator.destroy(sub_ptr);
            return err;
        };
        self.registry_lock.unlock();

        return sub_ptr;
    }

    /// @brief Announce endpoints.
    /// @brief Find remote writer data from SEDP.
    pub fn findRemoteWriterData(self: *DomainParticipant, guid: rtps.types.GUID_t) ?DiscoveredWriterData {

        // Check local participants first (bypassing SEDP)
        global_registry_lock.lockShared();
        for (global_participants) |opt_p| {
            if (opt_p) |local_p| {
                local_p.registry_lock.lockShared();
                for (local_p.publishers.items) |publisher| {
                    for (publisher.writers.items) |writer| {
                        if (std.meta.eql(writer.entity_id, guid.entity_id) and
                            std.mem.eql(u8, &local_p.guid_prefix, &guid.prefix))
                        {
                            const discovered = DiscoveredWriterData{
                                .endpoint_guid = guid,
                                .topic_name = writer.topic.name,
                                .type_name = writer.topic.type_name,
                                .reliability_qos = @backingInt(writer.qos.reliability.kind),
                                .durability_kind = @backingInt(writer.qos.durability),
                                .deadline_period_ms = writer.qos.deadline.period_ms,
                                .destination_order_kind = @backingInt(writer.qos.destination_order.kind),
                                .presentation_access_scope = @backingInt(publisher.qos.presentation.access_scope),
                                .presentation_coherent_access = publisher.qos.presentation.coherent_access,
                                .presentation_ordered_access = publisher.qos.presentation.ordered_access,
                                .ownership_kind = @backingInt(writer.qos.ownership.kind),
                                .ownership_strength = writer.qos.ownership_strength.value,
                                .liveliness_kind = @backingInt(writer.qos.liveliness.kind),
                                .liveliness_lease_duration = writer.qos.liveliness.lease_duration,
                                .partition_name = publisher.qos.partition.name,
                                .type_object_cdr = writer.topic.type_object_cdr,
                                .user_data = writer.qos.user_data.value[0..writer.qos.user_data.len],
                                .group_data = publisher.qos.group_data.value[0..publisher.qos.group_data.len],
                                .topic_data = "",
                            };
                            local_p.registry_lock.unlockShared();
                            global_registry_lock.unlockShared();
                            return discovered;
                        }
                    }
                }
                local_p.registry_lock.unlockShared();
            }
        }
        global_registry_lock.unlockShared();

        const sedp_reader = self.sedp_pub_reader orelse return null;

        sedp_reader.history_cache.acquireLock();
        defer sedp_reader.history_cache.releaseLock();

        var current = sedp_reader.history_cache.global_head;
        while (current) |node| : (current = node.global_next) {
            const data_value = node.change.data_value;
            var des = Deserializer.init(data_value, .Little);
            const discovered = des.deserialize(DiscoveredWriterData) catch continue;

            if (std.mem.eql(u8, &discovered.endpoint_guid.prefix, &guid.prefix) and
                std.mem.eql(u8, &discovered.endpoint_guid.entity_id.entity_key, &guid.entity_id.entity_key) and
                discovered.endpoint_guid.entity_id.entity_kind == guid.entity_id.entity_kind)
            {
                self.registry_lock.lockShared();
                const is_ignored_pub = self.ignored_publications.contains(rtps.types.guidToInstanceHandle(discovered.endpoint_guid));

                var topic_hash = std.hash.CityHash64.hash(discovered.topic_name);
                var topic_handle = std.mem.zeroes(rtps.types.InstanceHandle_t);
                @memcpy(topic_handle[0..8], std.mem.asBytes(&topic_hash));
                const is_ignored_topic = self.ignored_topics.contains(topic_handle);

                self.registry_lock.unlockShared();

                if (!is_ignored_pub and !is_ignored_topic) {
                    return discovered;
                }
            }
        }
        return null;
    }

    /// @brief Find remote reader data from SEDP.
    pub fn findRemoteReaderData(self: *DomainParticipant, guid: rtps.types.GUID_t) ?DiscoveredReaderData {
        // Check local participants first (bypassing SEDP)
        global_registry_lock.lockShared();
        for (global_participants) |opt_p| {
            if (opt_p) |local_p| {
                local_p.registry_lock.lockShared();
                for (local_p.subscribers.items) |subscriber| {
                    for (subscriber.readers.items) |reader| {
                        if (std.meta.eql(reader.entity_id, guid.entity_id) and
                            std.mem.eql(u8, &local_p.guid_prefix, &guid.prefix))
                        {
                            const discovered = DiscoveredReaderData{
                                .endpoint_guid = guid,
                                .topic_name = reader.topic.name,
                                .type_name = reader.topic.type_name,
                                .reliability_qos = @backingInt(reader.qos.reliability.kind),
                                .ownership_kind = @backingInt(reader.qos.ownership.kind),
                                .liveliness_kind = @backingInt(reader.qos.liveliness.kind),
                                .liveliness_lease_duration = reader.qos.liveliness.lease_duration,
                                .partition_name = subscriber.qos.partition.name,
                                .type_object_cdr = reader.topic.type_object_cdr,
                                .user_data = reader.qos.user_data.value[0..reader.qos.user_data.len],
                                .group_data = subscriber.qos.group_data.value[0..subscriber.qos.group_data.len],
                                .topic_data = "",
                            };
                            local_p.registry_lock.unlockShared();
                            global_registry_lock.unlockShared();
                            return discovered;
                        }
                    }
                }
                local_p.registry_lock.unlockShared();
            }
        }
        global_registry_lock.unlockShared();

        const sedp_reader = self.sedp_sub_reader orelse return null;

        sedp_reader.history_cache.acquireLock();
        defer sedp_reader.history_cache.releaseLock();

        var current = sedp_reader.history_cache.global_head;
        while (current) |node| : (current = node.global_next) {
            const data_value = node.change.data_value;
            var des = Deserializer.init(data_value, .Little);
            const discovered = des.deserialize(DiscoveredReaderData) catch continue;

            if (std.mem.eql(u8, &discovered.endpoint_guid.prefix, &guid.prefix) and
                std.mem.eql(u8, &discovered.endpoint_guid.entity_id.entity_key, &guid.entity_id.entity_key) and
                discovered.endpoint_guid.entity_id.entity_kind == guid.entity_id.entity_kind)
            {
                self.registry_lock.lockShared();
                const is_ignored_sub = self.ignored_subscriptions.contains(rtps.types.guidToInstanceHandle(discovered.endpoint_guid));

                var topic_hash = std.hash.CityHash64.hash(discovered.topic_name);
                var topic_handle = std.mem.zeroes(rtps.types.InstanceHandle_t);
                @memcpy(topic_handle[0..8], std.mem.asBytes(&topic_hash));
                const is_ignored_topic = self.ignored_topics.contains(topic_handle);

                self.registry_lock.unlockShared();

                if (!is_ignored_sub and !is_ignored_topic) {
                    return discovered;
                }
            }
        }
        return null;
    }

    pub fn announceEndpoints(self: *DomainParticipant) !void {
        self.registry_lock.lockShared();
        defer self.registry_lock.unlockShared();

        // We only announce endpoints if the SEDP writers are ready
        if (self.sedp_pub_writer == null or self.sedp_sub_writer == null) return;
        const sedp_pub_writer = self.sedp_pub_writer.?;
        const sedp_sub_writer = self.sedp_sub_writer.?;

        // 1. Announce Publishers' Writers
        for (self.publishers.items) |pub_typed| {
            for (pub_typed.writers.items) |writer| {
                if (writer.entity_id.entity_kind == rtps.types.EntityId_t.sedp_pub_writer.entity_kind or
                    writer.entity_id.entity_kind == rtps.types.EntityId_t.sedp_sub_writer.entity_kind) continue;

                try sedp_pub_writer.write(DiscoveredWriterData{
                    .endpoint_guid = rtps.types.GUID_t{ .prefix = self.guid_prefix, .entity_id = writer.entity_id },
                    .topic_name = writer.topic.name,
                    .type_name = writer.topic.type_name,
                    .reliability_qos = @backingInt(writer.qos.reliability.kind),
                    .durability_kind = @backingInt(writer.qos.durability),
                    .deadline_period_ms = writer.qos.deadline.period_ms,
                    .destination_order_kind = @backingInt(writer.qos.destination_order.kind),
                    .presentation_access_scope = @backingInt(pub_typed.qos.presentation.access_scope),
                    .presentation_coherent_access = pub_typed.qos.presentation.coherent_access,
                    .presentation_ordered_access = pub_typed.qos.presentation.ordered_access,
                    .ownership_kind = @backingInt(writer.qos.ownership.kind),
                    .ownership_strength = writer.qos.ownership_strength.value,
                    .liveliness_kind = @backingInt(writer.qos.liveliness.kind),
                    .liveliness_lease_duration = writer.qos.liveliness.lease_duration,
                    .partition_name = pub_typed.qos.partition.name,
                    .type_object_cdr = writer.topic.type_object_cdr,
                    .user_data = writer.qos.user_data.value[0..writer.qos.user_data.len],
                    .group_data = pub_typed.qos.group_data.value[0..pub_typed.qos.group_data.len],
                    .topic_data = "",
                    .representation_mask = writer.qos.representation.toMask(),
                });
            }
        }

        // 2. Announce Subscribers' Readers
        for (self.subscribers.items) |sub_typed| {
            for (sub_typed.readers.items) |reader| {
                if (reader.entity_id.entity_kind == rtps.types.EntityId_t.sedp_pub_reader.entity_kind or
                    reader.entity_id.entity_kind == rtps.types.EntityId_t.sedp_sub_reader.entity_kind) continue;

                try sedp_sub_writer.write(DiscoveredReaderData{
                    .endpoint_guid = rtps.types.GUID_t{ .prefix = self.guid_prefix, .entity_id = reader.entity_id },
                    .topic_name = reader.topic.name,
                    .type_name = reader.topic.type_name,
                    .reliability_qos = @backingInt(reader.qos.reliability.kind),
                    .durability_kind = @backingInt(reader.qos.durability),
                    .deadline_period_ms = reader.qos.deadline.period_ms,
                    .destination_order_kind = @backingInt(reader.qos.destination_order.kind),
                    .presentation_access_scope = @backingInt(sub_typed.qos.presentation.access_scope),
                    .presentation_coherent_access = sub_typed.qos.presentation.coherent_access,
                    .presentation_ordered_access = sub_typed.qos.presentation.ordered_access,
                    .type_object_cdr = reader.topic.type_object_cdr,
                    .user_data = reader.qos.user_data.value[0..reader.qos.user_data.len],
                    .group_data = sub_typed.qos.group_data.value[0..sub_typed.qos.group_data.len],
                    .topic_data = "",
                    .representation_mask = reader.qos.representation.toMask(),
                });
            }
        }
    }

    /// @brief Announce.
    pub fn announce(self: *DomainParticipant) !void {
        var buffer: [1024]u8 = undefined;
        var builder = try MessageBuilder.init(&buffer, self.guid_prefix);
        try builder.addInfoTs();

        var payload_buf: [512]u8 = undefined;
        var ser = Serializer.init(&payload_buf, .Little);

        const spdp_data = SPDPDiscoveredParticipantData{
            .guid_prefix = self.guid_prefix,
            .metatraffic_unicast_locator = rtps.types.Locator_t{
                .kind = rtps.types.Locator_t.kind_udp_v4,
                .port = self.spdp_unicast_port,
                .address = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 127, 0, 0, 1 },
            },
            .filter_expression = self.filter_expression orelse "",
            .has_public_key = false,
            .user_data = self.qos.user_data.value[0..self.qos.user_data.len],
        };
        try ser.serialize(spdp_data);

        try builder.addData(rtps.types.EntityId_t.unknown, rtps.types.EntityId_t.participant, rtps.types.SequenceNumber_t{ .high = 0, .low = 1 }, std.mem.zeroes([16]u8), payload_buf[0..ser.pos], null, null, null, null, null, null);

        const locator = rtps.types.Locator_t{
            .kind = rtps.types.Locator_t.kind_udp_v4,
            .port = self.spdp_multicast_port,
            .address = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 239, 255, 0, 1 },
        };
        _ = self.user_socket.sendTo(buffer[0..builder.msg_ser.pos], locator) catch {};

        // Localhost unicast peering across candidate participant ports to bypass firewall multicast blocks
        const pb: u32 = 7400;
        const dg: u32 = 250;
        const d3: u32 = 11;
        const pg: u32 = 2;
        var peer_pid: u32 = 0;
        while (peer_pid < 6) : (peer_pid += 1) {
            if (peer_pid == self.participant_id) continue;
            const peer_user_port: u16 = @intCast(pb + (dg * self.domain_id) + d3 + (pg * peer_pid) + 2);
            const peer_loc = rtps.types.Locator_t{
                .kind = rtps.types.Locator_t.kind_udp_v4,
                .port = peer_user_port,
                .address = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 127, 0, 0, 1 },
            };
            _ = self.user_socket.sendTo(buffer[0..builder.msg_ser.pos], peer_loc) catch {};
        }
    }

    /// @brief Process spdp.
    pub fn processSpdp(self: *DomainParticipant) !void {
        var buffer: [2048]u8 = undefined;
        var source_locator: rtps.types.Locator_t = undefined;
        const bytes_read = self.spdp_socket.receiveFrom(&buffer, &source_locator) catch |err| {
            if (err != error.WouldBlock) {
                Sleep(100);
            }
            return;
        };
        try RtpsReceiver.processMessage(self, buffer[0..bytes_read], source_locator);
    }
};

test "DomainParticipant initialization and port calculation" {
    var factory = DomainParticipantFactory.getInstance();
    const participant = try factory.createParticipant(0, null, std.testing.allocator);
    defer factory.deleteParticipant(participant, std.testing.allocator) catch {};

    try std.testing.expectEqual(@as(u16, 7400), participant.spdp_multicast_port);
    try std.testing.expectEqual(@as(u16, 7410), participant.spdp_unicast_port);
    try std.testing.expectEqual(@as(u16, 7401), participant.sedp_multicast_port);
    try std.testing.expectEqual(@as(u16, 7411), participant.sedp_unicast_port);
}

test "DomainParticipant announce does not crash" {
    var factory = DomainParticipantFactory.getInstance();
    const participant = try factory.createParticipant(0, null, std.testing.allocator);
    defer factory.deleteParticipant(participant, std.testing.allocator) catch {};

    // Test that announce builds and sends a payload.
    // If the network is available it will send, else we just ignore the error.
    participant.announce() catch {};
}

pub const SpinRwLock = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// @brief Lock.
    pub fn lock(self: *SpinRwLock) void {
        var spin_count: u32 = 0;
        while (self.state.cmpxchgWeak(0, std.math.maxInt(u32), .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
            spin_count += 1;
            if (spin_count >= 1000) {
                Sleep(0);
                spin_count = 0;
            }
        }
    }

    /// @brief Unlock.
    pub fn unlock(self: *SpinRwLock) void {
        self.state.store(0, .release);
    }

    /// @brief Lock shared.
    pub fn lockShared(self: *SpinRwLock) void {
        var spin_count: u32 = 0;
        while (true) {
            const current = self.state.load(.monotonic);
            if (current == std.math.maxInt(u32)) {
                std.atomic.spinLoopHint();
                spin_count += 1;
                if (spin_count >= 1000) {
                    Sleep(0);
                    spin_count = 0;
                }
                continue;
            }
            if (self.state.cmpxchgWeak(current, current + 1, .acquire, .monotonic) == null) {
                break;
            }
        }
    }

    /// @brief Unlock shared.
    pub fn unlockShared(self: *SpinRwLock) void {
        _ = self.state.fetchSub(1, .release);
    }
};

test "DomainParticipant ignore operations" {
    var factory = DomainParticipantFactory.getInstance();
    const participant = try factory.createParticipant(0, null, std.testing.allocator);
    defer factory.deleteParticipant(participant, std.testing.allocator) catch {};

    var handle = std.mem.zeroes(rtps.types.InstanceHandle_t);
    handle[0] = 1;

    try participant.ignoreParticipant(handle);
    try std.testing.expect(participant.ignored_participants.contains(handle));

    try participant.ignorePublication(handle);
    try std.testing.expect(participant.ignored_publications.contains(handle));

    try participant.ignoreSubscription(handle);
    try std.testing.expect(participant.ignored_subscriptions.contains(handle));

    try participant.ignoreTopic(handle);
    try std.testing.expect(participant.ignored_topics.contains(handle));
}
