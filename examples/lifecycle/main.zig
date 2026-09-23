//! @file main.zig
//! @brief Demonstrates entity lifecycle and state transition management.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const ddz = @import("ddz");
const Sleep = ddz.os.sleepMs;

const SensorData = struct {
    id: u32,
    value: f32,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("Starting Instance Lifecycle Example...\n", .{});

    var factory = ddz.dcps.DomainParticipantFactory.getInstance();
    var participant = try factory.createParticipant(0, null, allocator);
    defer factory.deleteParticipant(participant, allocator) catch {};
    try participant.enable();

    var publisher = try participant.createPublisher(null);
    var sub = try participant.createSubscriber(null);

    const topic = ddz.dcps.Topic.init("SensorTopic", "SensorData");

    var writer = try publisher.createDataWriter(topic, .{}, ddz.rtps.types.EntityId_t.unknown);
    var reader = try sub.createDataReader(topic, .{}, ddz.rtps.types.EntityId_t.unknown);

    Sleep(1000); // Wait for discovery

    // Register instance
    const data = SensorData{ .id = 1, .value = 10.5 };
    std.debug.print("[Publisher] Registering & Writing instance ID: {}\n", .{data.id});
    try writer.registerInstance(data);

    Sleep(1000); // Let it propagate

    // Read it
    var samples = try reader.take(SensorData, 10, .any, .any, .any);
    for (samples) |sample| {
        std.debug.print("[Subscriber] Read instance state: {s}, data value: {d}\n", .{ @tagName(sample.info.instance_state), sample.data.value });
    }
    reader.returnLoan(SensorData, samples);

    // Dispose it
    std.debug.print("[Publisher] Disposing instance ID: {}\n", .{data.id});
    try writer.dispose(data, null);

    Sleep(1000); // Let it propagate

    // Read disposed state
    samples = try reader.read(SensorData, 10, .any, .any, .any);
    for (samples) |sample| {
        std.debug.print("[Subscriber] Read instance state: {s}, disposed count: {}\n", .{ @tagName(sample.info.instance_state), sample.info.disposed_generation_count });
    }
    reader.returnLoan(SensorData, samples);

    // Unregister it
    std.debug.print("[Publisher] Unregistering instance ID: {}\n", .{data.id});
    try writer.unregisterInstance(data, null);

    Sleep(1000); // Let it propagate

    // Read unregistered state
    samples = try reader.read(SensorData, 10, .any, .any, .any);
    for (samples) |sample| {
        std.debug.print("[Subscriber] Read instance state: {s}, no_writers count: {}\n", .{ @tagName(sample.info.instance_state), sample.info.no_writers_generation_count });
    }
    reader.returnLoan(SensorData, samples);

    std.debug.print("Example completed.\n", .{});
}
