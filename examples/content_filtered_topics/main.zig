//! @file main.zig
//! @brief Demonstrates ContentFilteredTopic SQL92 filtering on readers and writers.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const ddz = @import("ddz");
const Sleep = ddz.os.sleepMs;

const SensorData = struct {
    sensor_id: u32,
    temperature: i32,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("Starting Content Filtered Topics Example...\n", .{});

    var factory = ddz.dcps.DomainParticipantFactory.getInstance();
    var participant = try factory.createParticipant(0, null, allocator);
    defer factory.deleteParticipant(participant, allocator) catch {};
    try participant.enable();

    var publisher = try participant.createPublisher(null);
    var subscriber = try participant.createSubscriber(null);

    // The physical Topic
    const topic = ddz.dcps.Topic.init("SensorDataTopic", "SensorData");

    // The Content-Filtered Topic (Only accept temperatures > 100)
    const cft = ddz.dcps.ContentFilteredTopic.init("HighTempTopic", topic, "temperature > 100");

    var writer = try publisher.createDataWriter(topic, .{}, ddz.rtps.types.EntityId_t.unknown);
    var reader_qos = ddz.dcps.Qos.ReaderQos{};
    reader_qos.history.depth = 10;
    const reader = try subscriber.createDataReader(cft, reader_qos, ddz.rtps.types.EntityId_t.unknown);

    Sleep(1000);

    var temp: i32 = 95;
    while (temp <= 105) : (temp += 2) {
        std.debug.print("[Publisher] Writing temperature: {}\n", .{temp});
        try writer.write(SensorData{ .sensor_id = 1, .temperature = temp });
        try writer.flush();
    }

    Sleep(1000);

    const samples = try reader.take(SensorData, 10, .any, .any, .any);
    defer reader.returnLoan(SensorData, samples);
    for (samples) |sample| {
        std.debug.print("[Subscriber] Received temperature: {} (Passed Filter!)\n", .{sample.data.temperature});
    }

    std.debug.print("Example completed.\n", .{});
}
