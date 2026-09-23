//! @file main.zig
//! @brief Demonstrates Durability QoS TRANSIENT_LOCAL late-joiner catch-up.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const ddz = @import("ddz");
const Sleep = ddz.os.sleepMs;

const SetupData = struct {
    config_id: u32,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("Starting Durability QoS Example...\n", .{});

    var factory = ddz.dcps.DomainParticipantFactory.getInstance();
    var pub_participant = try factory.createParticipant(0, null, allocator);
    defer factory.deleteParticipant(pub_participant, allocator) catch {};
    try pub_participant.enable();
    var publisher = try pub_participant.createPublisher(null);

    const topic = ddz.dcps.Topic.init("ConfigTopic", "SetupData");

    // 1. Create Writer with TRANSIENT_LOCAL Durability
    var writer_qos = ddz.dcps.Qos.WriterQos{};
    writer_qos.durability = .transient_local;
    var writer = try publisher.createDataWriter(topic, writer_qos, ddz.rtps.types.EntityId_t.unknown);

    // 2. Write Data BEFORE Reader exists!
    std.debug.print("[Publisher] Writing Config ID: 42...\n", .{});
    try writer.write(SetupData{ .config_id = 42 });
    try writer.flush();

    // 3. Wait 2 seconds (simulate a Late Joiner starting up later)
    std.debug.print("Waiting 2 seconds before creating Reader (Late Joiner)...\n", .{});
    Sleep(2000);

    var sub_participant = try factory.createParticipant(0, null, allocator);
    defer factory.deleteParticipant(sub_participant, allocator) catch {};
    var subscriber = try sub_participant.createSubscriber(null);

    // 4. Create Reader with TRANSIENT_LOCAL Durability
    var reader_qos = ddz.dcps.Qos.ReaderQos{};
    reader_qos.durability = .transient_local;
    const sub_topic = ddz.dcps.Topic.init("ConfigTopic", "SetupData");
    var reader = try subscriber.createDataReader(sub_topic, reader_qos, ddz.rtps.types.EntityId_t.unknown);

    try sub_participant.enable(); // START SPDP NOW SO IT TRIGGERS THE HACK AFTER READER EXISTS!

    // Allow SEDP discovery and historical sync
    var waited: u32 = 0;
    while (waited < 5000 and reader.history_cache.getLen() == 0) {
        Sleep(100);
        waited += 100;
    }

    // 5. Read Data (The Late Joiner receives the historical data!)
    std.debug.print("Checking cache len: {}\n", .{reader.history_cache.getLen()});
    const samples = try reader.take(SetupData, 10, .any, .any, .any);
    defer reader.returnLoan(SetupData, samples);

    if (samples.len > 0) {
        for (samples) |sample| {
            std.debug.print("[Subscriber] Late Joiner received historical Config ID: {}\n", .{sample.data.config_id});
        }
    } else {
        std.debug.print("[Subscriber] Error: Did not receive historical data.\n", .{});
    }

    std.debug.print("Example completed.\n", .{});
}
