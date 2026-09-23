//! @file main.zig
//! @brief Demonstrates EXCLUSIVE Ownership QoS and OwnershipStrength arbitration.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const ddz = @import("ddz");

const Sleep = ddz.os.sleepMs;

const SensorData = struct {
    id: i32,
    value: f32,
    pub const ddz_keys = [_][]const u8{"id"}; // id is the key, meaning same id = same instance
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    std.debug.print("Starting Exclusive Ownership QoS Example...\n", .{});

    var factory = ddz.dcps.DomainParticipantFactory.getInstance();
    var participant1 = try factory.createParticipant(0, null, allocator);
    defer factory.deleteParticipant(participant1, allocator) catch {};
    try participant1.enable();

    var participant2 = try factory.createParticipant(0, null, allocator);
    defer factory.deleteParticipant(participant2, allocator) catch {};
    try participant2.enable();

    var participant3 = try factory.createParticipant(0, null, allocator);
    defer factory.deleteParticipant(participant3, allocator) catch {};
    try participant3.enable();

    var topic1 = try ddz.dcps.Topic.initTyped(allocator, "SensorTopic", SensorData);
    defer topic1.deinit(allocator);
    var topic2 = try ddz.dcps.Topic.initTyped(allocator, "SensorTopic", SensorData);
    defer topic2.deinit(allocator);
    var topic3 = try ddz.dcps.Topic.initTyped(allocator, "SensorTopic", SensorData);
    defer topic3.deinit(allocator);

    // 1. Create Subscriber with EXCLUSIVE Ownership QoS (on Participant 1)
    var sub = try participant1.createSubscriber(null);
    var reader_qos = ddz.dcps.Qos.ReaderQos{};
    reader_qos.ownership.kind = .exclusive;
    const reader = try sub.createDataReader(topic1, reader_qos, ddz.rtps.types.EntityId_t.unknown);

    // 2. Create Primary Publisher (Strength 100) (on Participant 2)
    var pub1 = try participant2.createPublisher(null);
    var writer1_qos = ddz.dcps.Qos.WriterQos{};
    writer1_qos.ownership.kind = .exclusive;
    writer1_qos.ownership_strength.value = 100;
    writer1_qos.liveliness.kind = .automatic;
    writer1_qos.liveliness.lease_duration = 2; // 2 seconds lease
    var writer1 = try pub1.createDataWriter(topic2, writer1_qos, ddz.rtps.types.EntityId_t.unknown);

    // 3. Create Backup Publisher (Strength 50) (on Participant 3)
    var pub2 = try participant3.createPublisher(null);
    var writer2_qos = ddz.dcps.Qos.WriterQos{};
    writer2_qos.ownership.kind = .exclusive;
    writer2_qos.ownership_strength.value = 50;
    writer2_qos.liveliness.kind = .automatic;
    writer2_qos.liveliness.lease_duration = 2;
    var writer2 = try pub2.createDataWriter(topic3, writer2_qos, ddz.rtps.types.EntityId_t.unknown);

    // Force immediate discovery announcements so we don't have to wait 10 seconds for the periodic loops
    try participant1.announce();
    try participant2.announce();
    try participant3.announce();
    Sleep(500); // let SPDP process

    try participant1.announceEndpoints();
    try participant2.announceEndpoints();
    try participant3.announceEndpoints();
    Sleep(1000); // let SEDP process

    std.debug.print("--- Both Writers Active ---\n", .{});
    // Write from both. Because writer1 has strength 100 and writer2 has 50,
    // the reader should ONLY accept data from writer1 for instance id=1.
    _ = try writer1.writeWithParams(SensorData{ .id = 1, .value = 99.9 }, null, .ALIVE);
    _ = try writer2.writeWithParams(SensorData{ .id = 1, .value = 11.1 }, null, .ALIVE);

    Sleep(100);

    // Verify what the reader got
    const samples = try reader.take(SensorData, 10, .any, .any, .any);
    defer reader.returnLoan(SensorData, samples);
    for (samples) |sample| {
        std.debug.print("Reader Received: id={d}, value={d}\n", .{ sample.data.id, sample.data.value });
    }

    std.debug.print("--- Primary Writer Dies (Simulating > 2s wait) ---\n", .{});
    // Sleep for 3 seconds. The lease duration is 2 seconds.
    // Since we aren't writing, the reader will mark writer1 as dead.
    Sleep(3000);

    // Now backup writer writes again
    std.debug.print("Backup Writer writes new value...\n", .{});
    _ = try writer2.writeWithParams(SensorData{ .id = 1, .value = 22.2 }, null, .ALIVE);

    Sleep(100);

    // Verify backup writer took over
    const samples2 = try reader.take(SensorData, 10, .any, .any, .any);
    defer reader.returnLoan(SensorData, samples2);
    var latest_val: f32 = 0;
    for (samples2) |sample| {
        latest_val = sample.data.value;
    }
    std.debug.print("Reader Received Latest: value={d}\n", .{latest_val});

    std.debug.print("Example completed successfully.\n", .{});
    participant1.stop();
    participant2.stop();
    participant3.stop();
}
