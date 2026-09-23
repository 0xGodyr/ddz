//! @file main.zig
//! @brief Demonstrates Builtin Topics discovery introspection.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const ddz = @import("ddz");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("Starting Built-in Topics Example...\n", .{});

    var factory = ddz.dcps.DomainParticipantFactory.getInstance();
    var participant = try factory.createParticipant(0, null, allocator);
    defer factory.deleteParticipant(participant, allocator) catch {};
    try participant.enable();

    // Create a dummy user publisher to trigger discovery
    const publisher = try participant.createPublisher(null);
    var topic = try ddz.dcps.Topic.initTyped(allocator, "DummyTopic", struct {
        id: u32,
        pub const ddz_keys = .{"id"};
    });
    defer topic.deinit(allocator);
    _ = try publisher.createDataWriter(topic, .{}, ddz.rtps.types.EntityId_t.unknown);

    try participant.announce();
    // Try announce after waitset setup

    // Access Built-in Subscriber
    var builtin_sub = participant.getBuiltinSubscriber().?;

    // Get the Built-in Readers
    const pub_reader = builtin_sub.lookupDataReader("DCPSPublication").?;
    const sub_reader = builtin_sub.lookupDataReader("DCPSSubscription").?;
    const part_reader = builtin_sub.lookupDataReader("DCPSParticipant").?;

    // Setup a WaitSet to wait for Built-in Topic Data (Discovery)
    var ws = ddz.dcps.WaitSet.init(allocator);
    defer ws.deinit();

    var pub_cond = try pub_reader.getStatusCondition();
    pub_cond.setEnabledStatuses(@backingInt(ddz.dcps.StatusKind.data_available));
    try ws.attachCondition(&pub_cond.condition);

    var sub_cond = try sub_reader.getStatusCondition();
    sub_cond.setEnabledStatuses(@backingInt(ddz.dcps.StatusKind.data_available));
    try ws.attachCondition(&sub_cond.condition);

    var part_cond = try part_reader.getStatusCondition();
    part_cond.setEnabledStatuses(@backingInt(ddz.dcps.StatusKind.data_available));
    try ws.attachCondition(&part_cond.condition);

    try participant.announce();
    try participant.announceEndpoints();

    std.debug.print("Waiting for local discovery via Built-in Topics...\n", .{});
    const triggered = try ws.wait(2000 * 1000 * 1000); // Wait 2s
    defer allocator.free(triggered);
    std.debug.print("Triggered conditions: {}\n", .{triggered.len});

    // Read DCPSPublication
    const pub_samples = try pub_reader.read(ddz.builtin.PublicationData, 10, ddz.dcps.SampleStateMask.any, ddz.dcps.ViewStateMask.any, ddz.dcps.InstanceStateMask.any);
    defer pub_reader.returnLoan(ddz.builtin.PublicationData, pub_samples);
    std.debug.print("pub_samples.len = {}\n", .{pub_samples.len});
    for (pub_samples) |sample| {
        std.debug.print("Found DCPSPublication data: topic='{s}', type='{s}'\n", .{ sample.data.topic_name, sample.data.type_name });
    }

    std.debug.print("Built-in Topics Example completed successfully.\n", .{});
}
