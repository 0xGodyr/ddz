//! @file main.zig
//! @brief Demonstrates OMG IDL code generation and interop with generated types.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const ddz = @import("ddz");
const Sleep = ddz.os.sleepMs;
const SensorNetwork = @import("sensor_data.zig").SensorNetwork;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("Starting DDZ IDL Interoperability Example...\n", .{});

    var factory = ddz.dcps.DomainParticipantFactory.getInstance();
    var participant = try factory.createParticipant(0, null, allocator);
    defer factory.deleteParticipant(participant, allocator) catch {};
    try participant.enable();

    // Register type generated from SensorData.idl
    try participant.registerType(SensorNetwork.SensorReading);

    var publisher = try participant.createPublisher(null);
    var subscriber = try participant.createSubscriber(null);

    var topic = try ddz.dcps.Topic.initTyped(allocator, "SensorTopic", SensorNetwork.SensorReading);
    defer topic.deinit(allocator);

    const writer_qos = ddz.dcps.Qos.WriterQos{};
    const reader_qos = ddz.dcps.Qos.ReaderQos{};

    const writer = try publisher.createDataWriter(topic, writer_qos, ddz.rtps.types.EntityId_t.unknown);
    const reader = try subscriber.createDataReader(topic, reader_qos, ddz.rtps.types.EntityId_t.unknown);

    Sleep(500); // Wait for discovery

    // Publish sample
    var sample = SensorNetwork.SensorReading{
        .sensor_id = 101,
        .type = .PRESSURE,
        .reading = 1013.25,
        .calibration_factors = [4]f32{ 0.98, 1.01, 1.00, 0.99 },
        .device_name = std.mem.zeroes([32:0]u8),
    };
    const name = "Barometer_X1";
    @memcpy(sample.device_name[0..name.len], name);

    std.debug.print("[Publisher] Writing sample for sensor_id: {d}, type: {}, reading: {d:.2}\n", .{
        sample.sensor_id,
        sample.type,
        sample.reading,
    });

    try writer.write(sample);
    try writer.flush();

    Sleep(200);

    // Read sample
    const samples = try reader.take(SensorNetwork.SensorReading, 10, .any, .any, .any);
    defer reader.returnLoan(SensorNetwork.SensorReading, samples);

    if (samples.len > 0) {
        for (samples) |s| {
            std.debug.print("[Subscriber] Received IDL Generated Sample!\n", .{});
            std.debug.print("  Sensor ID: {d}\n", .{s.data.sensor_id});
            std.debug.print("  Type: {}\n", .{s.data.type});
            std.debug.print("  Reading: {d:.2}\n", .{s.data.reading});
            std.debug.print("  Device Name: {s}\n", .{std.mem.sliceTo(&s.data.device_name, 0)});
        }
    } else {
        std.debug.print("[Subscriber] Error: No samples received.\n", .{});
    }

    std.debug.print("IDL Interoperability Example completed successfully.\n", .{});
}
