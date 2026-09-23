//! @file main.zig
//! @brief Demonstrates Deadline QoS policy and deadline missed notification handling.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const ddz = @import("ddz");
const Sleep = ddz.os.sleepMs;

const MessageData = struct {
    id: u32,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("Starting Deadline QoS Example...\n", .{});

    var factory = ddz.dcps.DomainParticipantFactory.getInstance();
    var participant = try factory.createParticipant(0, null, allocator);
    defer factory.deleteParticipant(participant, allocator) catch {};
    try participant.enable();

    var publisher = try participant.createPublisher(null);
    var subscriber = try participant.createSubscriber(null);

    const topic = ddz.dcps.Topic.init("DeadlineTopic", "MessageData");

    // 1. Configure Writer with a 1000ms deadline
    var writer_qos = ddz.dcps.Qos.WriterQos{};
    writer_qos.deadline.period_ms = 1000;
    var writer = try publisher.createDataWriter(topic, writer_qos, ddz.rtps.types.EntityId_t.unknown);

    // 2. Configure Reader with a 1000ms deadline
    var reader_qos = ddz.dcps.Qos.ReaderQos{};
    reader_qos.deadline.period_ms = 1000;
    var reader = try subscriber.createDataReader(topic, reader_qos, ddz.rtps.types.EntityId_t.unknown);

    // Setup Status Condition to trigger WaitSet on Deadline Missed
    var ws = ddz.dcps.WaitSet.init(allocator);
    defer ws.deinit();

    var status_cond = try reader.getStatusCondition();
    status_cond.setEnabledStatuses(@backingInt(ddz.dcps.StatusKind.requested_deadline_missed));
    try ws.attachCondition(&status_cond.condition);

    Sleep(2000); // Wait for discovery

    // Write some data on time
    std.debug.print("[Publisher] Writing ID: 1\n", .{});
    try writer.write(MessageData{ .id = 1 });
    std.debug.print("[Publisher] Wrote ID: 1\n", .{});
    Sleep(500); // 500ms is < 1000ms deadline

    std.debug.print("[Publisher] Writing ID: 2\n", .{});
    try writer.write(MessageData{ .id = 2 });
    Sleep(500); // 500ms is < 1000ms deadline

    std.debug.print("[Publisher] Writing ID: 3\n", .{});
    try writer.write(MessageData{ .id = 3 });

    // Now, intentionally stop writing to simulate a missed deadline!
    std.debug.print("[Publisher] Stopped writing. Waiting for deadline to be missed...\n", .{});

    const triggered_conditions = try ws.wait(3000 * 1000 * 1000); // 3 seconds in nanoseconds // Wait up to 3s
    defer allocator.free(triggered_conditions);
    if (triggered_conditions.len > 0) {
        std.debug.print("[Subscriber] WaitSet Triggered! Deadline was Missed!\n", .{});
        std.debug.print("[Subscriber] Missed Count: {d}\n", .{reader.requested_deadline_missed_status.total_count});
    } else {
        std.debug.print("[Subscriber] WaitSet timed out without a deadline miss.\n", .{});
    }

    std.debug.print("Example completed.\n", .{});
}
