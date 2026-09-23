//! @file subscriber_role.zig
//! @brief Subscriber role runner for ddz_ping echoing received pulses back to the publisher.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const ddz = @import("ddz");
const PingMsg = @import("ping_msg.zig").PingMsg;

pub fn run(participant: *ddz.dcps.DomainParticipant, reliable: bool, throughput: bool, max_samples: ?u32) !void {
    var publisher = try participant.createPublisher(null);
    var subscriber = try participant.createSubscriber(null);

    var ping_topic = try ddz.dcps.Topic.initTyped(participant.allocator, "PingTopic", PingMsg);
    defer ping_topic.deinit(participant.allocator);
    var pong_topic = try ddz.dcps.Topic.initTyped(participant.allocator, "PongTopic", PingMsg);
    defer pong_topic.deinit(participant.allocator);

    var reader_qos = ddz.dcps.Qos.ReaderQos{};
    if (reliable) reader_qos.reliability.kind = .reliable;
    reader_qos.history.depth = 100;

    var writer_qos = ddz.dcps.Qos.WriterQos{};
    if (reliable) writer_qos.reliability.kind = .reliable;

    const ping_reader = try subscriber.createDataReader(ping_topic, reader_qos, ddz.rtps.types.EntityId_t.unknown);
    const pong_writer = try publisher.createDataWriter(pong_topic, writer_qos, ddz.rtps.types.EntityId_t.unknown);

    participant.announce() catch {};
    participant.announceEndpoints() catch {};

    std.debug.print("Waiting for pings...\n", .{});

    var received_count: u32 = 0;
    var total_received: u32 = 0;
    const start_time = ddz.os.getNanoTimestamp();
    var last_print = start_time;

    while (true) {
        if (ping_reader.takeNextSample(PingMsg) catch |err| {
            std.debug.print("takeNextSample error: {}\n", .{err});
            return err;
        }) |ping_data| {
            received_count += 1;
            total_received += 1;

            if (!throughput) {
                // Echo back for latency measurement (quiet to prevent adding terminal I/O latency to RTT)
                try pong_writer.write(ping_data.data);
            }

            if (max_samples) |limit| {
                if (total_received >= limit) {
                    if (throughput) {
                        std.debug.print("Completed receiving {} samples.\n", .{total_received});
                    } else {
                        std.debug.print("Echoed {} ping samples. Exiting.\n", .{total_received});
                    }
                    return;
                }
            }
        } else {
            ddz.os.sleepMs(1);
        }

        const now = ddz.os.getNanoTimestamp();
        if (now - last_print > 1_000_000_000) { // 1 second
            if (throughput and received_count > 0) {
                std.debug.print("Received {} samples/sec\n", .{received_count});
            }
            received_count = 0;
            last_print = now;
        }
    }
}
