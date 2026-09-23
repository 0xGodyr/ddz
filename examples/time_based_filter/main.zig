//! @file main.zig
//! @brief Demonstrates TimeBasedFilter QoS minimum separation and sample throttling.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const ddz = @import("ddz");
const Sleep = ddz.os.sleepMs;

pub const SensorData = struct {
    sensor_id: u32,
    value: f32,
};

pub fn main() !void {
    std.debug.print("Starting DDZ Time-Based Filter Example...\n", .{});

    var factory = ddz.dcps.DomainParticipantFactory.getInstance();
    var participant = try factory.createParticipant(0, null, std.heap.page_allocator);
    defer factory.deleteParticipant(participant, std.heap.page_allocator) catch {};
    try participant.enable();

    const topic = ddz.dcps.Topic.init("SensorTopic", "SensorData");

    var publisher = try participant.createPublisher(null);
    var subscriber = try participant.createSubscriber(null);

    // Fast Writer (Spams data)
    const writer_qos = ddz.dcps.Qos.WriterQos{};
    const writer = try publisher.createDataWriter(topic, writer_qos, ddz.rtps.types.EntityId_t.unknown);

    // Slow Reader (Filters data to max 1 sample every 200ms)
    var reader_qos = ddz.dcps.Qos.ReaderQos{};
    reader_qos.time_based_filter.minimum_separation_ms = 200;
    reader_qos.history.depth = 10; // Keep up to 10 samples so the loop doesn't overwrite them
    const reader = try subscriber.createDataReader(topic, reader_qos, ddz.rtps.types.EntityId_t.unknown);

    var ws = ddz.dcps.WaitSet.init(std.heap.page_allocator);
    defer ws.deinit();

    try ws.attachCondition(&(try reader.getStatusCondition()).condition);

    std.debug.print("Nodes created. Writer will publish every 10ms, Reader will downsample to 200ms.\n", .{});

    // Let discovery complete
    Sleep(1000);

    var data = SensorData{ .sensor_id = 1, .value = 0.0 };

    for (0..50) |i| {
        data.value = @as(f32, @floatFromInt(i)) * 1.5;
        try writer.write(data);
        Sleep(10); // Spam every 10ms
    }

    std.debug.print("Finished writing 50 samples.\n", .{});

    // The reader should have only received ~2-3 samples (since 50 * 10ms = 500ms total time, bounded by 200ms filter)
    var samples_received: u32 = 0;
    while (true) {
        if (try reader.takeNextSample(SensorData)) |received_data| {
            std.debug.print("Reader Received Sample! sensor_id: {}, value: {d:.1}\n", .{ received_data.data.sensor_id, received_data.data.value });
            samples_received += 1;
        } else {
            break;
        }
    }

    std.debug.print("Total samples received by reader: {} (Expected ~3 out of 50)\n", .{samples_received});
    std.debug.print("Time-Based Filter Test completed successfully.\n", .{});
}
