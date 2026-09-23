//! @file main.zig
//! @brief Demonstrates MultiTopic runtime SQL JOIN operations across multiple topics.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const ddz = @import("ddz");
const Sleep = ddz.os.sleepMs;

pub const TempData = struct {
    id: u32,
    temp_val: f32,
};

pub const GPSData = struct {
    id: u32,
    lat: f32,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("Starting DDZ MultiTopic Example...\n", .{});

    var factory = ddz.dcps.DomainParticipantFactory.getInstance();
    var participant = try factory.createParticipant(0, null, allocator);
    defer factory.deleteParticipant(participant, allocator) catch {};
    try participant.enable();

    // Register types
    try participant.registerType(TempData);
    try participant.registerType(GPSData);

    var publisher = try participant.createPublisher(null);
    const subscriber = try participant.createSubscriber(null);

    // Physical topics
    var temp_topic = try ddz.dcps.Topic.initTyped(allocator, "Temp", TempData);
    defer temp_topic.deinit(allocator);
    var gps_topic = try ddz.dcps.Topic.initTyped(allocator, "GPS", GPSData);
    defer gps_topic.deinit(allocator);

    // Writers
    const writer_qos = ddz.dcps.Qos.WriterQos{};
    const temp_writer = try publisher.createDataWriter(temp_topic, writer_qos, ddz.rtps.types.EntityId_t.unknown);
    const gps_writer = try publisher.createDataWriter(gps_topic, writer_qos, ddz.rtps.types.EntityId_t.unknown);

    // MultiTopic JOIN
    const multi = try ddz.dcps.MultiTopic.init(
        "JoinedSensorData",
        "JoinedRow",
        "SELECT * FROM Temp JOIN GPS ON Temp.id = GPS.id",
    );

    const reader_qos = ddz.dcps.Qos.ReaderQos{};
    var multi_reader = try ddz.dcps.MultiDataReader.init(subscriber, multi, reader_qos);
    defer multi_reader.deinit();

    std.debug.print("Publishing parts of joined row...\n", .{});

    // Write GPS data (out of order, wait for Temp)
    const g1 = GPSData{ .id = 42, .lat = 37.7749 };
    _ = try gps_writer.write(g1);

    Sleep(100);

    const t1 = TempData{ .id = 42, .temp_val = 22.5 };
    _ = try temp_writer.write(t1);

    Sleep(1500);

    if (try multi_reader.takeDynamic()) |mut_val| {
        var val = mut_val;
        defer val.deinit(allocator);
        std.debug.print("Got joined data!\n", .{});
        if (val == .Struct) {
            const temp_val = val.Struct.get("temp_val").?.Float32;
            const lat = val.Struct.get("lat").?.Float32;
            std.debug.print("Joined: temp={d}, lat={d}\n", .{ temp_val, lat });
        }
    } else {
        std.debug.print("Failed to get joined data!\n", .{});
    }

    std.debug.print("Example completed successfully.\n", .{});
}
