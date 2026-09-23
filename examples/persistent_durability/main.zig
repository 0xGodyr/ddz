//! @file main.zig
//! @brief Demonstrates Durability QoS PERSISTENT and TRANSIENT history caches.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const ddz = @import("ddz");

pub const Config = struct { id: u32 };

const Sleep = ddz.os.sleepMs;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var factory = ddz.dcps.DomainParticipantFactory.getInstance();
    var participant = try factory.createParticipant(0, null, allocator);
    defer factory.deleteParticipant(participant, allocator) catch {};
    try participant.enable();
    try participant.registerType(Config);

    // Remove the cache file to simulate a fresh start if we wanted,
    // but we WANT to test persistence. We will just let it accumulate!

    const pub_qos = ddz.dcps.Qos.PublisherQos{};
    const publisher = try participant.createPublisher(pub_qos);

    const sub_qos = ddz.dcps.Qos.SubscriberQos{};
    const subscriber = try participant.createSubscriber(sub_qos);

    var topic = try ddz.dcps.Topic.initTyped(allocator, "PersistentConfig", Config);
    defer topic.deinit(allocator);

    std.debug.print("Starting Persistent Durability QoS Example...\n", .{});

    var writer_qos = ddz.dcps.Qos.WriterQos{};
    writer_qos.durability = .persistent;
    writer_qos.history.kind = .keep_all;
    writer_qos.reliability.kind = .reliable;
    const writer = try publisher.createDataWriter(topic, writer_qos, ddz.rtps.types.EntityId_t.unknown);

    // Wait a moment for any loading to finish
    Sleep(100);

    var reader_qos = ddz.dcps.Qos.ReaderQos{};
    reader_qos.durability = .persistent;
    reader_qos.history.kind = .keep_all;
    reader_qos.reliability.kind = .reliable;
    const reader = try subscriber.createDataReader(topic, reader_qos, ddz.rtps.types.EntityId_t.unknown);

    // Give discovery time
    Sleep(500);

    // Read all historical data loaded from disk
    const samples = try reader.take(Config, 100, .any, .any, .any);
    defer reader.returnLoan(Config, samples);

    var highest_id: u32 = 0;
    for (samples) |s| {
        if (s.info.valid_data) {
            std.debug.print("[Subscriber] Read historical Config ID: {}\n", .{s.data.id});
            if (s.data.id > highest_id) {
                highest_id = s.data.id;
            }
        }
    }

    // Now write a new one
    const new_id = highest_id + 1;
    std.debug.print("[Publisher] Writing NEW Config ID: {}\n", .{new_id});
    _ = try writer.write(Config{ .id = new_id });

    Sleep(500);

    const new_samples = try reader.take(Config, 100, .any, .any, .any);
    defer reader.returnLoan(Config, new_samples);
    for (new_samples) |s| {
        if (s.info.valid_data) {
            std.debug.print("[Subscriber] Read NEW Config ID: {}\n", .{s.data.id});
        }
    }

    std.debug.print("Example completed.\n", .{});
}
