//! @file main.zig
//! @brief Demonstrates Presentation QoS Group Access and Coherent Changes.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const ddz = @import("ddz");
const Sleep = ddz.os.sleepMs;

pub const Position = struct {
    id: u32,
    x: f32,
    y: f32,
};

pub const Velocity = struct {
    id: u32,
    vx: f32,
    vy: f32,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("Starting Group Access (Coherent & Ordered) QoS Example...\n", .{});

    var factory = ddz.dcps.DomainParticipantFactory.getInstance();
    var participant = try factory.createParticipant(0, null, allocator);
    defer factory.deleteParticipant(participant, allocator) catch {};
    try participant.enable();

    try participant.registerType(Position);
    try participant.registerType(Velocity);

    var pub_qos = ddz.dcps.Qos.PublisherQos{};
    pub_qos.presentation.access_scope = .group;
    pub_qos.presentation.coherent_access = true;
    pub_qos.presentation.ordered_access = true;
    var publisher = try participant.createPublisher(pub_qos);

    var sub_qos = ddz.dcps.Qos.SubscriberQos{};
    sub_qos.presentation.access_scope = .group;
    sub_qos.presentation.coherent_access = true;
    sub_qos.presentation.ordered_access = true;
    const subscriber = try participant.createSubscriber(sub_qos);

    var pos_topic = try ddz.dcps.Topic.initTyped(allocator, "Position", Position);
    defer pos_topic.deinit(allocator);
    var vel_topic = try ddz.dcps.Topic.initTyped(allocator, "Velocity", Velocity);
    defer vel_topic.deinit(allocator);

    var writer_qos = ddz.dcps.Qos.WriterQos{};
    writer_qos.history.depth = 10;
    const pos_writer = try publisher.createDataWriter(pos_topic, writer_qos, ddz.rtps.types.EntityId_t.unknown);
    const vel_writer = try publisher.createDataWriter(vel_topic, writer_qos, ddz.rtps.types.EntityId_t.unknown);

    var reader_qos = ddz.dcps.Qos.ReaderQos{};
    reader_qos.history.depth = 10;
    _ = try subscriber.createDataReader(pos_topic, reader_qos, ddz.rtps.types.EntityId_t.unknown);
    _ = try subscriber.createDataReader(vel_topic, reader_qos, ddz.rtps.types.EntityId_t.unknown);

    // Give discovery a moment (though it's intra-participant here, it's good practice)
    Sleep(500);

    std.debug.print("Writing coherent set across multiple topics...\n", .{});

    // Begin Coherent Set
    try publisher.beginCoherentChanges();

    _ = try pos_writer.write(Position{ .id = 1, .x = 10.0, .y = 20.0 });
    Sleep(10); // Artificial delay to ensure ordered source timestamps
    _ = try vel_writer.write(Velocity{ .id = 1, .vx = 5.0, .vy = 5.0 });
    Sleep(10);
    _ = try pos_writer.write(Position{ .id = 2, .x = 100.0, .y = 200.0 });
    Sleep(10);
    _ = try vel_writer.write(Velocity{ .id = 2, .vx = 50.0, .vy = 50.0 });

    // Check if readers can see it before endCoherentChanges
    var early_readers = try subscriber.getDataReaders(.{ .not_read = true }, .any, .any);
    defer early_readers.deinit(allocator);
    if (early_readers.items.len > 0) {
        std.debug.print("ERROR: Readers have data BEFORE endCoherentChanges!\n", .{});
        return error.Failed;
    } else {
        std.debug.print("Success: No data visible before endCoherentChanges (Coherent Access).\n", .{});
    }

    // End Coherent Set
    try publisher.endCoherentChanges();
    Sleep(100);

    // Now access it
    try subscriber.beginAccess();
    var active_readers = try subscriber.getDataReaders(.{ .not_read = true }, .any, .any);
    defer active_readers.deinit(allocator);

    std.debug.print("Got {} active readers (Ordered Access).\n", .{active_readers.items.len});

    for (active_readers.items) |reader| {
        if (std.mem.eql(u8, reader.topic.name, "Position")) {
            const samples = try reader.take(Position, 10, .{ .not_read = true }, .any, .any);
            defer reader.returnLoan(Position, samples);
            for (samples) |s| {
                if (s.info.valid_data) std.debug.print("Took Position: id={}, x={d}\n", .{ s.data.id, s.data.x });
            }
        } else if (std.mem.eql(u8, reader.topic.name, "Velocity")) {
            const samples = try reader.take(Velocity, 10, .{ .not_read = true }, .any, .any);
            defer reader.returnLoan(Velocity, samples);
            for (samples) |s| {
                if (s.info.valid_data) std.debug.print("Took Velocity: id={}, vx={d}\n", .{ s.data.id, s.data.vx });
            }
        }
    }
    try subscriber.endAccess();

    // Take remaining samples (getDataReaders only returned 2 because we only took 1 sample per reader)
    try subscriber.beginAccess();
    var active_readers2 = try subscriber.getDataReaders(.{ .not_read = true }, .any, .any);
    defer active_readers2.deinit(allocator);
    for (active_readers2.items) |reader| {
        if (std.mem.eql(u8, reader.topic.name, "Position")) {
            const samples = try reader.take(Position, 10, .{ .not_read = true }, .any, .any);
            defer reader.returnLoan(Position, samples);
            for (samples) |s| {
                if (s.info.valid_data) std.debug.print("Took Position: id={}, x={d}\n", .{ s.data.id, s.data.x });
            }
        } else if (std.mem.eql(u8, reader.topic.name, "Velocity")) {
            const samples = try reader.take(Velocity, 10, .{ .not_read = true }, .any, .any);
            defer reader.returnLoan(Velocity, samples);
            for (samples) |s| {
                if (s.info.valid_data) std.debug.print("Took Velocity: id={}, vx={d}\n", .{ s.data.id, s.data.vx });
            }
        }
    }
    try subscriber.endAccess();

    std.debug.print("Group Access Example completed.\n", .{});
}
