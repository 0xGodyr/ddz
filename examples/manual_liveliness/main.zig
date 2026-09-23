//! @file main.zig
//! @brief Liveliness MANUAL_BY_TOPIC QoS Example.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr
//! Copyright: (c) 2026 0xGodyr. All rights reserved.

const std = @import("std");
const ddz = @import("ddz");
const Sleep = ddz.os.sleepMs;

const HeartbeatData = struct {
    id: u32,
    pub const ddz_keys = .{"id"};
};

pub fn main() void {
    run() catch |err| {
        std.debug.print("ERROR: {}\n", .{err});
    };
}

fn run() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("Starting Manual Liveliness QoS Example...\n", .{});

    var factory = ddz.dcps.DomainParticipantFactory.getInstance();
    var participant = try factory.createParticipant(0, null, allocator);
    defer factory.deleteParticipant(participant, allocator) catch {};
    try participant.enable();

    const publisher = try participant.createPublisher(null);
    const subscriber = try participant.createSubscriber(null);
    var topic = try ddz.dcps.Topic.initTyped(allocator, "HeartbeatTopic", HeartbeatData);
    defer topic.deinit(allocator);

    const writer_qos = ddz.dcps.Qos.WriterQos{
        .liveliness = .{ .kind = .manual_by_topic, .lease_duration = 2 },
    };
    const reader_qos = ddz.dcps.Qos.ReaderQos{
        .liveliness = .{ .kind = .manual_by_topic, .lease_duration = 2 },
    };

    var writer = try publisher.createDataWriter(topic, writer_qos, ddz.rtps.types.EntityId_t.unknown);
    var reader = try subscriber.createDataReader(topic, reader_qos, ddz.rtps.types.EntityId_t.unknown);

    const listener = ddz.dcps.DataReaderListener{
        .on_liveliness_changed = struct {
            fn cb(_: ?*anyopaque, _: *ddz.dcps.DataReader, status: ddz.dcps.Status.LivelinessChangedStatus) void {
                std.debug.print("[Subscriber] Liveliness Changed! Alive count: {}\n", .{status.alive_count});
            }
        }.cb,
    };
    reader.listener = listener;

    const w_listener = ddz.dcps.DataWriterListener{
        .on_liveliness_lost = struct {
            fn cb(_: ?*anyopaque, _: *ddz.dcps.DataWriter, status: ddz.dcps.Status.LivelinessLostStatus) void {
                std.debug.print("[Publisher] Liveliness Lost! Total count: {}\n", .{status.total_count});
            }
        }.cb,
    };
    writer.listener = w_listener;

    try participant.announce();
    try participant.announceEndpoints();

    std.debug.print("Sleeping to let Discovery complete...\n", .{});
    Sleep(1000);

    std.debug.print("\n--- Phase 1: Asserting Liveliness ---\n", .{});
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        std.debug.print("Asserting Liveliness...\n", .{});
        try writer.assertLiveliness();
        Sleep(1000);
    }

    std.debug.print("\n--- Phase 2: Not Asserting Liveliness (Waiting 3s) ---\n", .{});
    Sleep(3000);

    std.debug.print("\n--- Phase 3: Asserting Liveliness Again ---\n", .{});
    try writer.assertLiveliness();
    Sleep(1000);

    std.debug.print("Example completed successfully.\n", .{});
    participant.stop();
}
