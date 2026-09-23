//! @file main.zig
//! @brief Demonstrates Partition QoS policy matching and domain partition isolation.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const ddz = @import("ddz");

const Message = struct {
    id: u32,
    text: [32]u8,
};

const Sleep = ddz.os.sleepMs;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var factory = ddz.dcps.DomainParticipantFactory.getInstance();
    var participant = try factory.createParticipant(0, null, allocator);
    defer factory.deleteParticipant(participant, allocator) catch {};
    try participant.enable();

    var topic = try ddz.dcps.Topic.initTyped(allocator, "PartitionTopic", Message);
    defer topic.deinit(allocator);

    // Publisher in Partition "Vehicle/Cars"
    var pub_cars = try participant.createPublisher(.{ .partition = .{ .name = "Vehicle/Cars" } });
    var writer_cars = try pub_cars.createDataWriter(topic, .{}, ddz.rtps.types.EntityId_t.unknown);

    // Publisher in Partition "Vehicle/Trucks"
    var pub_trucks = try participant.createPublisher(.{ .partition = .{ .name = "Vehicle/Trucks" } });
    var writer_trucks = try pub_trucks.createDataWriter(topic, .{}, ddz.rtps.types.EntityId_t.unknown);

    // Subscriber in Partition "Vehicle/Cars"
    var sub_cars = try participant.createSubscriber(.{ .partition = .{ .name = "Vehicle/Cars" } });
    const reader_cars = try sub_cars.createDataReader(topic, .{}, ddz.rtps.types.EntityId_t.unknown);

    // Subscriber in wildcard Partition "Vehicle/*"
    var sub_all = try participant.createSubscriber(.{ .partition = .{ .name = "Vehicle/*" } });
    const reader_all = try sub_all.createDataReader(topic, .{ .history = .{ .kind = .keep_last, .depth = 10 } }, ddz.rtps.types.EntityId_t.unknown);

    std.debug.print("Starting Partition QoS Example...\n", .{});

    // Give SPDP discovery time to find localhost
    Sleep(1000);

    // Write to Cars
    var msg_cars = Message{ .id = 1, .text = std.mem.zeroes([32]u8) };
    const text_cars = "Hello from Cars!";
    @memcpy(msg_cars.text[0..text_cars.len], text_cars);
    try writer_cars.write(msg_cars);

    // Write to Trucks
    var msg_trucks = Message{ .id = 2, .text = std.mem.zeroes([32]u8) };
    const text_trucks = "Hello from Trucks!";
    @memcpy(msg_trucks.text[0..text_trucks.len], text_trucks);
    try writer_trucks.write(msg_trucks);

    // Data is delivered synchronously to local participants

    std.debug.print("\n--- Checking Reader for 'Vehicle/Cars' ---\n", .{});
    const car_samples = try reader_cars.take(Message, 10, .any, .any, .any);
    defer reader_cars.returnLoan(Message, car_samples);
    for (car_samples) |sample| {
        std.debug.print("Cars Reader received ID {d}\n", .{sample.data.id});
    }

    std.debug.print("\n--- Checking Reader for 'Vehicle/*' (Wildcard) ---\n", .{});
    const all_samples = try reader_all.take(Message, 10, .any, .any, .any);
    defer reader_all.returnLoan(Message, all_samples);
    for (all_samples) |sample| {
        std.debug.print("Wildcard Reader received ID {d}\n", .{sample.data.id});
    }

    std.debug.print("\nExample completed successfully.\n", .{});
}
