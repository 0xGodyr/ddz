//! @file dds_xml_parser.zig
//! @brief OMG DDS-XML compliant configuration and profile parser for DDZ.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const element = @import("element.zig");
const Document = element.Document;
const Element = element.Element;
const Qos = @import("../dcps/qos.zig");

pub const ParticipantProfile = struct {
    profile_name: []const u8,
    is_default: bool = false,
    domain_id: u32 = 0,
    participant_name: ?[]const u8 = null,
    shm_transport: Qos.ShmTransportQosPolicy = .{},
    qos: Qos.DomainParticipantQos = .{},
};

pub const TopicProfile = struct {
    profile_name: []const u8,
    topic_name: []const u8,
    type_name: ?[]const u8 = null,
    qos: Qos.TopicQos = .{},
};

pub const WriterProfile = struct {
    profile_name: []const u8,
    topic_name: ?[]const u8 = null,
    qos: Qos.WriterQos = .{},
};

pub const ReaderProfile = struct {
    profile_name: []const u8,
    topic_name: ?[]const u8 = null,
    qos: Qos.ReaderQos = .{},
};

pub const PublisherProfile = struct {
    profile_name: []const u8,
    qos: Qos.PublisherQos = .{},
};

pub const SubscriberProfile = struct {
    profile_name: []const u8,
    qos: Qos.SubscriberQos = .{},
};

pub const DdsXmlParser = struct {
    allocator: std.mem.Allocator,
    doc: Document,

    participant_profiles: std.StringHashMapUnmanaged(ParticipantProfile) = .empty,
    topic_profiles: std.StringHashMapUnmanaged(TopicProfile) = .empty,
    writer_profiles: std.StringHashMapUnmanaged(WriterProfile) = .empty,
    reader_profiles: std.StringHashMapUnmanaged(ReaderProfile) = .empty,
    publisher_profiles: std.StringHashMapUnmanaged(PublisherProfile) = .empty,
    subscriber_profiles: std.StringHashMapUnmanaged(SubscriberProfile) = .empty,

    default_participant_profile: ?[]const u8 = null,

    pub fn parseString(allocator: std.mem.Allocator, xml_content: []const u8) !DdsXmlParser {
        var doc = try Document.parse(allocator, xml_content);
        errdefer doc.deinit();

        var parser = DdsXmlParser{
            .allocator = allocator,
            .doc = doc,
        };
        errdefer parser.deinit();

        try parser.extractProfiles();
        return parser;
    }

    pub fn parseFile(allocator: std.mem.Allocator, file_path: []const u8) !DdsXmlParser {
        const io = std.Options.debug_io;
        var file = try std.Io.Dir.cwd().openFile(io, file_path, .{});
        defer file.close(io);

        const len = try file.length(io);
        const buffer = try allocator.alloc(u8, len);
        defer allocator.free(buffer);

        _ = try file.readPositionalAll(io, buffer, 0);
        return try parseString(allocator, buffer);
    }

    pub fn deinit(self: *DdsXmlParser) void {
        self.participant_profiles.deinit(self.allocator);
        self.topic_profiles.deinit(self.allocator);
        self.writer_profiles.deinit(self.allocator);
        self.reader_profiles.deinit(self.allocator);
        self.publisher_profiles.deinit(self.allocator);
        self.subscriber_profiles.deinit(self.allocator);
        self.doc.deinit();
    }

    pub fn getParticipantProfile(self: *const DdsXmlParser, name: []const u8) ?ParticipantProfile {
        return self.participant_profiles.get(name);
    }

    pub fn getTopicProfile(self: *const DdsXmlParser, name: []const u8) ?TopicProfile {
        return self.topic_profiles.get(name);
    }

    pub fn getWriterProfile(self: *const DdsXmlParser, name: []const u8) ?WriterProfile {
        return self.writer_profiles.get(name);
    }

    pub fn getReaderProfile(self: *const DdsXmlParser, name: []const u8) ?ReaderProfile {
        return self.reader_profiles.get(name);
    }

    pub fn getPublisherProfile(self: *const DdsXmlParser, name: []const u8) ?PublisherProfile {
        return self.publisher_profiles.get(name);
    }

    pub fn getSubscriberProfile(self: *const DdsXmlParser, name: []const u8) ?SubscriberProfile {
        return self.subscriber_profiles.get(name);
    }

    fn extractProfiles(self: *DdsXmlParser) !void {
        const root = self.doc.root;
        // <dds> can have direct profile elements or inside <profiles>
        var container = root;
        if (root.findChild("profiles")) |p| {
            container = p;
        }

        for (container.children) |child| {
            if (std.mem.eql(u8, child.name, "participant")) {
                try self.parseParticipant(child);
            } else if (std.mem.eql(u8, child.name, "topic")) {
                try self.parseTopic(child);
            } else if (std.mem.eql(u8, child.name, "data_writer") or std.mem.eql(u8, child.name, "datawriter")) {
                try self.parseWriter(child);
            } else if (std.mem.eql(u8, child.name, "data_reader") or std.mem.eql(u8, child.name, "datareader")) {
                try self.parseReader(child);
            } else if (std.mem.eql(u8, child.name, "publisher")) {
                try self.parsePublisher(child);
            } else if (std.mem.eql(u8, child.name, "subscriber")) {
                try self.parseSubscriber(child);
            }
        }
    }

    fn parseParticipant(self: *DdsXmlParser, elem: *const Element) !void {
        const profile_name = elem.getAttribute("profile_name") orelse elem.getAttribute("name") orelse "default";
        const is_def = elem.getChildBool("is_default_profile") orelse (if (elem.getAttribute("is_default_profile")) |v| std.mem.eql(u8, v, "true") else false);

        var domain_id: u32 = 0;
        if (elem.getChildInt(u32, "domain_id")) |d| {
            domain_id = d;
        } else if (elem.getAttribute("domain_id")) |d_str| {
            domain_id = std.fmt.parseInt(u32, d_str, 0) catch 0;
        }

        var part_name: ?[]const u8 = elem.getChildTextPath("rtps.name");
        if (part_name == null) {
            part_name = elem.getChildText("name");
        }

        var qos = Qos.DomainParticipantQos{};
        var shm_transport = Qos.ShmTransportQosPolicy{};

        // rtps shm transport
        if (elem.findChildPath("rtps.shm_transport")) |shm| {
            shm_transport.enable = shm.getChildBool("enable") orelse (if (shm.getAttribute("enable")) |v| std.mem.eql(u8, v, "true") else true);
            if (shm.getChildInt(u32, "segment_size")) |sz| {
                shm_transport.segment_size = sz;
            } else if (shm.getAttribute("segment_size")) |sz_str| {
                shm_transport.segment_size = std.fmt.parseInt(u32, sz_str, 0) catch 1048576;
            }
        }

        // entity factory
        if (elem.findChild("entity_factory")) |ef| {
            qos.entity_factory = parseEntityFactoryQos(ef);
        }

        const profile = ParticipantProfile{
            .profile_name = profile_name,
            .is_default = is_def,
            .domain_id = domain_id,
            .participant_name = part_name,
            .shm_transport = shm_transport,
            .qos = qos,
        };

        try self.participant_profiles.put(self.allocator, profile_name, profile);
        if (is_def or self.default_participant_profile == null) {
            self.default_participant_profile = profile_name;
        }
    }

    fn parseTopic(self: *DdsXmlParser, elem: *const Element) !void {
        const profile_name = elem.getAttribute("profile_name") orelse elem.getAttribute("name") orelse "default";
        const topic_name = elem.getChildText("name") orelse elem.getChildText("topic_name") orelse profile_name;
        const type_name = elem.getChildText("data_type") orelse elem.getChildText("type_name");

        var qos = Qos.TopicQos{};
        const qos_container = elem.findChild("qos") orelse elem;

        if (qos_container.findChild("reliability")) |r| qos.reliability = parseReliabilityQos(r);
        if (qos_container.findChild("durability")) |d| qos.durability = parseDurabilityKind(d);
        if (qos_container.findChild("historyQos") orelse qos_container.findChild("history")) |h| qos.history = parseHistoryQos(h);
        if (qos_container.findChild("resource_limits") orelse qos_container.findChild("resourceLimitsQos")) |rl| qos.resource_limits = parseResourceLimitsQos(rl);
        if (qos_container.findChild("liveliness")) |l| qos.liveliness = parseLivelinessQos(l);
        if (qos_container.findChild("deadline")) |dl| qos.deadline = parseDeadlineQos(dl);
        if (qos_container.findChild("lifespan")) |ls| qos.lifespan = parseLifespanQos(ls);
        if (qos_container.findChild("ownership")) |o| qos.ownership = parseOwnershipQos(o);
        if (qos_container.findChild("transport_priority")) |tp| qos.transport_priority.value = tp.getChildInt(i32, "value") orelse 0;

        try self.topic_profiles.put(self.allocator, profile_name, .{
            .profile_name = profile_name,
            .topic_name = topic_name,
            .type_name = type_name,
            .qos = qos,
        });
    }

    fn parseWriter(self: *DdsXmlParser, elem: *const Element) !void {
        const profile_name = elem.getAttribute("profile_name") orelse elem.getAttribute("name") orelse "default";
        const topic_name = elem.getChildText("topic") orelse elem.getChildText("topic_name");

        var qos = Qos.WriterQos{};
        const qos_container = elem.findChild("qos") orelse elem;

        if (qos_container.findChild("reliability")) |r| qos.reliability = parseReliabilityQos(r);
        if (qos_container.findChild("durability")) |d| qos.durability = parseDurabilityKind(d);
        if (qos_container.findChild("historyQos") orelse qos_container.findChild("history")) |h| qos.history = parseHistoryQos(h);
        if (qos_container.findChild("resource_limits") orelse qos_container.findChild("resourceLimitsQos")) |rl| qos.resource_limits = parseResourceLimitsQos(rl);
        if (qos_container.findChild("liveliness")) |l| qos.liveliness = parseLivelinessQos(l);
        if (qos_container.findChild("deadline")) |dl| qos.deadline = parseDeadlineQos(dl);
        if (qos_container.findChild("lifespan")) |ls| qos.lifespan = parseLifespanQos(ls);
        if (qos_container.findChild("ownership")) |o| qos.ownership = parseOwnershipQos(o);
        if (qos_container.findChild("ownership_strength")) |os| qos.ownership_strength.value = os.getChildInt(i32, "value") orelse 0;
        if (qos_container.findChild("writer_data_lifecycle")) |wdl| {
            qos.writer_data_lifecycle.autodispose_unregistered_instances = wdl.getChildBool("autodispose_unregistered_instances") orelse true;
        }
        if (qos_container.findChild("batch")) |b| qos.batch = parseBatchQos(b);
        if (qos_container.findChild("shm_transport") orelse qos_container.findChild("shm")) |st| qos.shm = parseShmTransportQos(st);

        try self.writer_profiles.put(self.allocator, profile_name, .{
            .profile_name = profile_name,
            .topic_name = topic_name,
            .qos = qos,
        });
    }

    fn parseReader(self: *DdsXmlParser, elem: *const Element) !void {
        const profile_name = elem.getAttribute("profile_name") orelse elem.getAttribute("name") orelse "default";
        const topic_name = elem.getChildText("topic") orelse elem.getChildText("topic_name");

        var qos = Qos.ReaderQos{};
        const qos_container = elem.findChild("qos") orelse elem;

        if (qos_container.findChild("reliability")) |r| qos.reliability = parseReliabilityQos(r);
        if (qos_container.findChild("durability")) |d| qos.durability = parseDurabilityKind(d);
        if (qos_container.findChild("historyQos") orelse qos_container.findChild("history")) |h| qos.history = parseHistoryQos(h);
        if (qos_container.findChild("resource_limits") orelse qos_container.findChild("resourceLimitsQos")) |rl| qos.resource_limits = parseResourceLimitsQos(rl);
        if (qos_container.findChild("liveliness")) |l| qos.liveliness = parseLivelinessQos(l);
        if (qos_container.findChild("deadline")) |dl| qos.deadline = parseDeadlineQos(dl);
        if (qos_container.findChild("ownership")) |o| qos.ownership = parseOwnershipQos(o);
        if (qos_container.findChild("time_based_filter")) |tbf| {
            qos.time_based_filter.minimum_separation_ms = tbf.getChildInt(u32, "minimum_separation_ms") orelse 0;
        }

        try self.reader_profiles.put(self.allocator, profile_name, .{
            .profile_name = profile_name,
            .topic_name = topic_name,
            .qos = qos,
        });
    }

    fn parsePublisher(self: *DdsXmlParser, elem: *const Element) !void {
        const profile_name = elem.getAttribute("profile_name") orelse elem.getAttribute("name") orelse "default";
        var qos = Qos.PublisherQos{};
        const qos_container = elem.findChild("qos") orelse elem;

        if (qos_container.findChild("presentation")) |p| qos.presentation = parsePresentationQos(p);
        if (qos_container.findChild("entity_factory")) |ef| qos.entity_factory = parseEntityFactoryQos(ef);

        try self.publisher_profiles.put(self.allocator, profile_name, .{
            .profile_name = profile_name,
            .qos = qos,
        });
    }

    fn parseSubscriber(self: *DdsXmlParser, elem: *const Element) !void {
        const profile_name = elem.getAttribute("profile_name") orelse elem.getAttribute("name") orelse "default";
        var qos = Qos.SubscriberQos{};
        const qos_container = elem.findChild("qos") orelse elem;

        if (qos_container.findChild("presentation")) |p| qos.presentation = parsePresentationQos(p);
        if (qos_container.findChild("entity_factory")) |ef| qos.entity_factory = parseEntityFactoryQos(ef);

        try self.subscriber_profiles.put(self.allocator, profile_name, .{
            .profile_name = profile_name,
            .qos = qos,
        });
    }
};

fn parseReliabilityQos(elem: *const Element) Qos.ReliabilityQosPolicy {
    var policy = Qos.ReliabilityQosPolicy{};
    if (elem.getChildText("kind")) |k| {
        if (std.ascii.eqlIgnoreCase(k, "RELIABLE")) {
            policy.kind = .reliable;
        } else if (std.ascii.eqlIgnoreCase(k, "BEST_EFFORT")) {
            policy.kind = .best_effort;
        }
    }
    if (elem.getChildInt(u32, "max_blocking_time_ms")) |t| {
        policy.max_blocking_time_ms = t;
    }
    return policy;
}

fn parseDurabilityKind(elem: *const Element) Qos.DurabilityKind {
    const k = elem.getChildText("kind") orelse return .@"volatile";
    if (std.ascii.eqlIgnoreCase(k, "TRANSIENT_LOCAL")) return .transient_local;
    if (std.ascii.eqlIgnoreCase(k, "TRANSIENT")) return .transient;
    if (std.ascii.eqlIgnoreCase(k, "PERSISTENT")) return .persistent;
    return .@"volatile";
}

fn parseHistoryQos(elem: *const Element) Qos.HistoryQosPolicy {
    var policy = Qos.HistoryQosPolicy{};
    if (elem.getChildText("kind")) |k| {
        if (std.ascii.eqlIgnoreCase(k, "KEEP_ALL")) {
            policy.kind = .keep_all;
        } else {
            policy.kind = .keep_last;
        }
    }
    if (elem.getChildInt(i32, "depth")) |d| {
        policy.depth = d;
    }
    return policy;
}

fn parseResourceLimitsQos(elem: *const Element) Qos.ResourceLimitsQosPolicy {
    return .{
        .max_samples = elem.getChildInt(i32, "max_samples") orelse -1,
        .max_instances = elem.getChildInt(i32, "max_instances") orelse -1,
        .max_samples_per_instance = elem.getChildInt(i32, "max_samples_per_instance") orelse -1,
    };
}

fn parseLivelinessQos(elem: *const Element) Qos.LivelinessQosPolicy {
    var policy = Qos.LivelinessQosPolicy{};
    if (elem.getChildText("kind")) |k| {
        if (std.ascii.eqlIgnoreCase(k, "MANUAL_BY_PARTICIPANT")) {
            policy.kind = .manual_by_participant;
        } else if (std.ascii.eqlIgnoreCase(k, "MANUAL_BY_TOPIC")) {
            policy.kind = .manual_by_topic;
        } else {
            policy.kind = .automatic;
        }
    }
    if (elem.getChildInt(u32, "lease_duration")) |ld| {
        policy.lease_duration = ld;
    }
    return policy;
}

fn parseDeadlineQos(elem: *const Element) Qos.DeadlineQosPolicy {
    return .{
        .period_ms = elem.getChildInt(u32, "period_ms") orelse 0xFFFFFFFF,
    };
}

fn parseLifespanQos(elem: *const Element) Qos.LifespanQosPolicy {
    return .{
        .duration_ms = elem.getChildInt(u32, "duration_ms") orelse 0xFFFFFFFF,
    };
}

fn parseOwnershipQos(elem: *const Element) Qos.OwnershipQosPolicy {
    var policy = Qos.OwnershipQosPolicy{};
    if (elem.getChildText("kind")) |k| {
        if (std.ascii.eqlIgnoreCase(k, "EXCLUSIVE")) {
            policy.kind = .exclusive;
        } else {
            policy.kind = .shared;
        }
    }
    return policy;
}

fn parseBatchQos(elem: *const Element) Qos.BatchQosPolicy {
    return .{
        .enable = elem.getChildBool("enable") orelse false,
        .max_data_bytes = elem.getChildInt(u32, "max_data_bytes") orelse 1024,
        .max_flush_delay_ms = elem.getChildInt(u32, "max_flush_delay_ms") orelse 100,
    };
}

fn parseShmTransportQos(elem: *const Element) Qos.ShmTransportQosPolicy {
    var policy = Qos.ShmTransportQosPolicy{};
    policy.enable = elem.getChildBool("enable") orelse (if (elem.getAttribute("enable")) |v| std.mem.eql(u8, v, "true") else false);
    if (elem.getChildInt(u32, "segment_size")) |sz| {
        policy.segment_size = sz;
    } else if (elem.getAttribute("segment_size")) |sz_str| {
        policy.segment_size = std.fmt.parseInt(u32, sz_str, 0) catch policy.segment_size;
    }
    return policy;
}

fn parsePresentationQos(elem: *const Element) Qos.PresentationQosPolicy {
    var policy = Qos.PresentationQosPolicy{};
    if (elem.getChildText("access_scope")) |s| {
        if (std.ascii.eqlIgnoreCase(s, "TOPIC")) {
            policy.access_scope = .topic;
        } else if (std.ascii.eqlIgnoreCase(s, "GROUP")) {
            policy.access_scope = .group;
        } else {
            policy.access_scope = .instance;
        }
    }
    policy.coherent_access = elem.getChildBool("coherent_access") orelse false;
    policy.ordered_access = elem.getChildBool("ordered_access") orelse false;
    return policy;
}

fn parseEntityFactoryQos(elem: *const Element) Qos.EntityFactoryQosPolicy {
    return .{
        .autoenable_created_entities = elem.getChildBool("autoenable_created_entities") orelse true,
    };
}

test "DdsXmlParser parses full DDS-XML profile document" {
    const xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<dds xmlns="http://www.omg.org/dds">
        \\    <profiles>
        \\        <participant profile_name="drone_participant" is_default_profile="true">
        \\            <domain_id>7</domain_id>
        \\            <rtps>
        \\                <name>Avionics_FlightComputer</name>
        \\                <shm_transport enable="true" segment_size="2097152"/>
        \\            </rtps>
        \\        </participant>
        \\
        \\        <topic profile_name="telemetry_topic">
        \\            <name>Telemetry/FlightData</name>
        \\            <data_type>TelemetryMsg</data_type>
        \\            <reliability>
        \\                <kind>RELIABLE</kind>
        \\                <max_blocking_time_ms>250</max_blocking_time_ms>
        \\            </reliability>
        \\            <durability>
        \\                <kind>TRANSIENT_LOCAL</kind>
        \\            </durability>
        \\            <history>
        \\                <kind>KEEP_LAST</kind>
        \\                <depth>50</depth>
        \\            </history>
        \\        </topic>
        \\
        \\        <data_writer profile_name="telemetry_writer">
        \\            <topic>Telemetry/FlightData</topic>
        \\            <reliability>
        \\                <kind>RELIABLE</kind>
        \\            </reliability>
        \\            <ownership>
        \\                <kind>EXCLUSIVE</kind>
        \\            </ownership>
        \\            <ownership_strength>
        \\                <value>100</value>
        \\            </ownership_strength>
        \\            <batch>
        \\                <enable>true</enable>
        \\                <max_data_bytes>4096</max_data_bytes>
        \\            </batch>
        \\        </data_writer>
        \\
        \\        <data_reader profile_name="telemetry_reader">
        \\            <topic>Telemetry/FlightData</topic>
        \\            <reliability>
        \\                <kind>BEST_EFFORT</kind>
        \\            </reliability>
        \\            <time_based_filter>
        \\                <minimum_separation_ms>20</minimum_separation_ms>
        \\            </time_based_filter>
        \\        </data_reader>
        \\    </profiles>
        \\</dds>
    ;

    var parser = try DdsXmlParser.parseString(std.testing.allocator, xml);
    defer parser.deinit();

    // Verify participant profile
    const p_prof = parser.getParticipantProfile("drone_participant").?;
    try std.testing.expectEqual(@as(u32, 7), p_prof.domain_id);
    try std.testing.expectEqualStrings("Avionics_FlightComputer", p_prof.participant_name.?);
    try std.testing.expect(p_prof.is_default);
    try std.testing.expect(p_prof.shm_transport.enable);
    try std.testing.expectEqual(@as(u32, 2097152), p_prof.shm_transport.segment_size);

    // Verify topic profile
    const t_prof = parser.getTopicProfile("telemetry_topic").?;
    try std.testing.expectEqualStrings("Telemetry/FlightData", t_prof.topic_name);
    try std.testing.expectEqualStrings("TelemetryMsg", t_prof.type_name.?);
    try std.testing.expectEqual(Qos.ReliabilityKind.reliable, t_prof.qos.reliability.kind);
    try std.testing.expectEqual(@as(u32, 250), t_prof.qos.reliability.max_blocking_time_ms);
    try std.testing.expectEqual(Qos.DurabilityKind.transient_local, t_prof.qos.durability);
    try std.testing.expectEqual(Qos.HistoryKind.keep_last, t_prof.qos.history.kind);
    try std.testing.expectEqual(@as(i32, 50), t_prof.qos.history.depth);

    // Verify writer profile
    const w_prof = parser.getWriterProfile("telemetry_writer").?;
    try std.testing.expectEqualStrings("Telemetry/FlightData", w_prof.topic_name.?);
    try std.testing.expectEqual(Qos.ReliabilityKind.reliable, w_prof.qos.reliability.kind);
    try std.testing.expectEqual(Qos.OwnershipKind.exclusive, w_prof.qos.ownership.kind);
    try std.testing.expectEqual(@as(i32, 100), w_prof.qos.ownership_strength.value);
    try std.testing.expect(w_prof.qos.batch.enable);
    try std.testing.expectEqual(@as(u32, 4096), w_prof.qos.batch.max_data_bytes);

    // Verify reader profile
    const r_prof = parser.getReaderProfile("telemetry_reader").?;
    try std.testing.expectEqualStrings("Telemetry/FlightData", r_prof.topic_name.?);
    try std.testing.expectEqual(Qos.ReliabilityKind.best_effort, r_prof.qos.reliability.kind);
    try std.testing.expectEqual(@as(u32, 20), r_prof.qos.time_based_filter.minimum_separation_ms);
}
