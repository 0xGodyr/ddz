//! @file main.zig
//! @brief Basic Publish/Subscribe Hello World example.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const ddz = @import("ddz");
const Sleep = ddz.os.sleepMs;

const HelloWorldData = struct {
    message: [32]u8,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("Starting Hello World Example...\n", .{});

    // 1. Initialize DomainParticipant on Domain 0
    var factory = ddz.dcps.DomainParticipantFactory.getInstance();
    var participant = try factory.createParticipant(0, null, allocator);
    defer factory.deleteParticipant(participant, allocator) catch {};
    try participant.enable();

    // 2. Create Publisher & Subscriber
    var publisher = try participant.createPublisher(null);
    var subscriber = try participant.createSubscriber(null);

    // 3. Register Topic
    const topic = ddz.dcps.Topic.init("HelloWorldTopic", "HelloWorldData");

    // 4. Create Writer & Reader
    var writer = try publisher.createDataWriter(topic, .{}, ddz.rtps.types.EntityId_t.unknown);
    var reader = try subscriber.createDataReader(topic, .{}, ddz.rtps.types.EntityId_t.unknown);

    // Give discovery a moment to connect the local endpoints
    Sleep(1000);

    // 5. Write Data
    var data = HelloWorldData{ .message = std.mem.zeroes([32]u8) };
    const text = "Hello from DDZ!";
    @memcpy(data.message[0..text.len], text);

    std.debug.print("Writing message: {s}\n", .{text});
    try writer.write(data);

    // Flush batch if enabled
    try writer.flush();

    // 6. Read Data
    Sleep(100); // Wait for delivery

    const samples = try reader.take(HelloWorldData, 10, .any, .any, .any);
    defer reader.returnLoan(HelloWorldData, samples);

    if (samples.len > 0) {
        for (samples) |sample| {
            std.debug.print("Read message: {s}\n", .{std.mem.sliceTo(&sample.data.message, 0)});
        }
    } else {
        std.debug.print("No message received.\n", .{});
    }

    std.debug.print("Example completed.\n", .{});
}
