//! @file main.zig
//! @brief Demonstrates WaitSet and StatusCondition synchronization.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const ddz = @import("ddz");
const Sleep = ddz.os.sleepMs;

pub const SystemStatus = struct {
    ready: bool,
};

pub fn main() !void {
    std.debug.print("Starting DDZ WaitSet StatusCondition Example...\n", .{});

    var factory = ddz.dcps.DomainParticipantFactory.getInstance();
    var participant = try factory.createParticipant(0, null, std.heap.page_allocator);
    defer factory.deleteParticipant(participant, std.heap.page_allocator) catch {};
    try participant.enable();

    const topic = ddz.dcps.Topic.init("SystemStatusTopic", "SystemStatus");

    var publisher = try participant.createPublisher(null);
    const writer = try publisher.createDataWriter(topic, ddz.dcps.Qos.WriterQos{}, ddz.rtps.types.EntityId_t.unknown);

    var ws = ddz.dcps.WaitSet.init(std.heap.page_allocator);
    defer ws.deinit();

    try ws.attachCondition(&(try writer.getStatusCondition()).condition);

    std.debug.print("Writer created. Blocking main thread until a Reader discovers us...\n", .{});

    // In a background thread (or later in the script), we create a Subscriber.
    // To simulate a late-joiner, we'll wait 2 seconds before creating the subscriber.
    const SubscriberThread = struct {
        p: *ddz.dcps.DomainParticipant,
        t: ddz.dcps.Topic,
        fn run(ctx: *@This()) void {
            Sleep(2000);
            std.debug.print("[Late-Joiner] Creating Subscriber now...\n", .{});
            var sub = ctx.p.createSubscriber(null) catch return;
            _ = sub.createDataReader(ctx.t, ddz.dcps.Qos.ReaderQos{}, ddz.rtps.types.EntityId_t.unknown) catch return;
        }
    };
    var sub_ctx = SubscriberThread{ .p = participant, .t = topic };
    var thread = try std.Thread.spawn(.{}, SubscriberThread.run, .{&sub_ctx});

    // Block here until publication matched!
    while (true) {
        const active_conditions = try ws.wait(100_000_000); // 100ms timeout
        defer ws.allocator.free(active_conditions);
        if (active_conditions.len > 0) {
            const changes = writer.status_changes.load(.monotonic);
            if ((changes & @backingInt(ddz.dcps.Status.StatusKind.publication_matched)) != 0) {
                std.debug.print("Success! publication_matched status triggered! We have a matched reader.\n", .{});
                break;
            }
        }
    }

    thread.join();

    std.debug.print("Now it is safe to write data without dropping it.\n", .{});
    try writer.write(SystemStatus{ .ready = true });

    std.debug.print("WaitSet StatusCondition Test completed successfully.\n", .{});
}
