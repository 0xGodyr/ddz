//! @file domain_participant_factory.zig
//! @brief Singleton factory for creating and managing DomainParticipants and defining default QoS profiles.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const DomainParticipant = @import("domain_participant.zig").DomainParticipant;
const Qos = @import("qos.zig");
const DomainParticipantQos = Qos.DomainParticipantQos;
const DomainParticipantFactoryQos = Qos.DomainParticipantFactoryQos;
const SpinLock = @import("wait_set.zig").SpinLock;
const Entity = @import("entity.zig").Entity;
const DdsXmlParser = @import("../xml/dds_xml_parser.zig").DdsXmlParser;

pub const DomainParticipantFactory = struct {
    default_participant_qos: DomainParticipantQos = .{},

    qos: DomainParticipantFactoryQos = .{},
    participants: [256]?*DomainParticipant = std.mem.zeroes([256]?*DomainParticipant),
    participant_count: usize = 0,
    mutex: SpinLock = .{},
    xml_parser: ?DdsXmlParser = null,

    var placeholder_marker: u8 align(@alignOf(DomainParticipant)) = 0;

    var static_factory: DomainParticipantFactory = .{};

    pub fn getDefaultParticipantQos(self: *DomainParticipantFactory) DomainParticipantQos {
        return self.default_participant_qos;
    }

    pub fn setDefaultParticipantQos(self: *DomainParticipantFactory, qos: DomainParticipantQos) !void {
        self.default_participant_qos = qos;
    }

    pub fn getInstance() *DomainParticipantFactory {
        return &static_factory;
    }

    pub fn setQos(self: *DomainParticipantFactory, qos: Qos.DomainParticipantFactoryQos) void {
        self.qos = qos;
    }

    pub fn getQos(self: *DomainParticipantFactory) Qos.DomainParticipantFactoryQos {
        return self.qos;
    }

    pub fn createParticipant(
        self: *DomainParticipantFactory,
        domain_id: u32,
        qos: ?Qos.DomainParticipantQos,
        allocator: std.mem.Allocator,
    ) !*DomainParticipant {
        self.mutex.lock();
        var free_slot: ?usize = null;
        for (&self.participants, 0..) |p, idx| {
            if (p == null) {
                free_slot = idx;
                break;
            }
        }
        const slot_idx = free_slot orelse {
            self.mutex.unlock();
            return error.OutOfMemory;
        };
        // Reserve slot with placeholder to prevent TOCTOU race
        const placeholder: *DomainParticipant = @ptrCast(&placeholder_marker);
        self.participants[slot_idx] = placeholder;
        self.participant_count += 1;
        self.mutex.unlock();

        const participant_id: u32 = @intCast(slot_idx);
        const participant = allocator.create(DomainParticipant) catch |err| {
            self.mutex.lock();
            self.participants[slot_idx] = null;
            self.participant_count -= 1;
            self.mutex.unlock();
            return err;
        };

        const actual_qos = qos orelse Qos.DomainParticipantQos{ .entity_factory = self.qos.entity_factory };

        participant.* = DomainParticipant.init(allocator, domain_id, participant_id, actual_qos) catch |err| {
            self.mutex.lock();
            self.participants[slot_idx] = null;
            self.participant_count -= 1;
            self.mutex.unlock();
            allocator.destroy(participant);
            return err;
        };
        participant.entity = Entity.init(allocator, participant, DomainParticipant.enableImpl);

        self.mutex.lock();
        self.participants[slot_idx] = participant;
        self.mutex.unlock();

        // Respect autoenable
        if (actual_qos.entity_factory.autoenable_created_entities) {
            participant.enable() catch |err| {
                self.mutex.lock();
                self.participants[slot_idx] = null;
                self.participant_count -= 1;
                self.mutex.unlock();
                participant.deinit();
                allocator.destroy(participant);
                return err;
            };
        }

        return participant;
    }

    pub fn deleteParticipant(self: *DomainParticipantFactory, participant: *DomainParticipant, allocator: std.mem.Allocator) !void {
        _ = allocator;
        self.mutex.lock();
        for (&self.participants) |*p| {
            if (p.* == participant) {
                p.* = null;
                self.participant_count -= 1;
                self.mutex.unlock();
                participant.deinit();
                participant.allocator.destroy(participant);
                return;
            }
        }
        self.mutex.unlock();
        return error.ParticipantNotFound;
    }

    pub fn loadProfilesXml(self: *DomainParticipantFactory, xml_content: []const u8, allocator: std.mem.Allocator) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.xml_parser) |*parser| {
            parser.deinit();
            self.xml_parser = null;
        }

        var parser = try DdsXmlParser.parseString(allocator, xml_content);
        if (parser.default_participant_profile) |def_name| {
            if (parser.getParticipantProfile(def_name)) |p_prof| {
                self.default_participant_qos = p_prof.qos;
            }
        }
        self.xml_parser = parser;
    }

    pub fn loadProfilesXmlFile(self: *DomainParticipantFactory, file_path: []const u8, allocator: std.mem.Allocator) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.xml_parser) |*parser| {
            parser.deinit();
            self.xml_parser = null;
        }

        var parser = try DdsXmlParser.parseFile(allocator, file_path);
        if (parser.default_participant_profile) |def_name| {
            if (parser.getParticipantProfile(def_name)) |p_prof| {
                self.default_participant_qos = p_prof.qos;
            }
        }
        self.xml_parser = parser;
    }

    pub fn createParticipantFromConfig(
        self: *DomainParticipantFactory,
        profile_name: ?[]const u8,
        allocator: std.mem.Allocator,
    ) !*DomainParticipant {
        const parser = self.xml_parser orelse return error.XmlProfilesNotLoaded;

        const target_name = profile_name orelse parser.default_participant_profile orelse return error.ProfileNotFound;
        const profile = parser.getParticipantProfile(target_name) orelse return error.ProfileNotFound;

        return self.createParticipant(profile.domain_id, profile.qos, allocator);
    }

    pub fn getTopicQosFromConfig(self: *const DomainParticipantFactory, profile_name: []const u8) ?Qos.TopicQos {
        if (self.xml_parser) |parser| {
            if (parser.getTopicProfile(profile_name)) |tp| {
                return tp.qos;
            }
        }
        return null;
    }

    pub fn getWriterQosFromConfig(self: *const DomainParticipantFactory, profile_name: []const u8) ?Qos.WriterQos {
        if (self.xml_parser) |parser| {
            if (parser.getWriterProfile(profile_name)) |wp| {
                return wp.qos;
            }
        }
        return null;
    }

    pub fn getReaderQosFromConfig(self: *const DomainParticipantFactory, profile_name: []const u8) ?Qos.ReaderQos {
        if (self.xml_parser) |parser| {
            if (parser.getReaderProfile(profile_name)) |rp| {
                return rp.qos;
            }
        }
        return null;
    }
};

test "DomainParticipantFactory singleton and participant lifecycle" {
    var factory = DomainParticipantFactory.getInstance();
    const factory2 = DomainParticipantFactory.getInstance();
    try std.testing.expectEqual(factory, factory2);

    const participant = try factory.createParticipant(0, null, std.testing.allocator);
    try std.testing.expect(participant.entity.is_enabled);

    // Verify deleting participant
    try factory.deleteParticipant(participant, std.testing.allocator);

    // Deleting again should return error.ParticipantNotFound
    try std.testing.expectError(error.ParticipantNotFound, factory.deleteParticipant(participant, std.testing.allocator));
}

test "DomainParticipantFactory createParticipantFromConfig with XML" {
    const xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<dds xmlns="http://www.omg.org/dds">
        \\    <profiles>
        \\        <participant profile_name="xml_robot_participant" is_default_profile="true">
        \\            <domain_id>12</domain_id>
        \\            <rtps>
        \\                <name>XmlConfiguredNode</name>
        \\            </rtps>
        \\        </participant>
        \\        <topic profile_name="xml_sensor_topic">
        \\            <name>Sensors/Imu</name>
        \\            <reliability>
        \\                <kind>RELIABLE</kind>
        \\            </reliability>
        \\        </topic>
        \\    </profiles>
        \\</dds>
    ;

    var factory = DomainParticipantFactory.getInstance();
    try factory.loadProfilesXml(xml, std.testing.allocator);
    defer {
        if (factory.xml_parser) |*parser| {
            parser.deinit();
            factory.xml_parser = null;
        }
    }

    // 1. Create from default profile
    const p1 = try factory.createParticipantFromConfig(null, std.testing.allocator);
    defer factory.deleteParticipant(p1, std.testing.allocator) catch {};
    try std.testing.expectEqual(@as(u32, 12), p1.domain_id);
    try std.testing.expect(p1.entity.is_enabled);

    // 2. Create by explicit profile name
    const p2 = try factory.createParticipantFromConfig("xml_robot_participant", std.testing.allocator);
    defer factory.deleteParticipant(p2, std.testing.allocator) catch {};
    try std.testing.expectEqual(@as(u32, 12), p2.domain_id);

    // 3. Query topic QoS from config
    const topic_qos = factory.getTopicQosFromConfig("xml_sensor_topic").?;
    try std.testing.expectEqual(Qos.ReliabilityKind.reliable, topic_qos.reliability.kind);

    // 4. Non-existent profile returns error.ProfileNotFound
    try std.testing.expectError(error.ProfileNotFound, factory.createParticipantFromConfig("non_existent_profile", std.testing.allocator));
}
