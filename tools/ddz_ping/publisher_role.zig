//! @file publisher_role.zig
//! @brief Publisher role runner for ddz_ping transmitting ping pulses and collecting round-trip stats.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const ddz = @import("ddz");
const PingMsg = @import("ping_msg.zig").PingMsg;

pub fn run(participant: *ddz.dcps.DomainParticipant, samples: u32, size: u32, reliable: bool, throughput: bool) !void {
    var publisher = try participant.createPublisher(null);
    var subscriber = try participant.createSubscriber(null);

    var ping_topic = try ddz.dcps.Topic.initTyped(participant.allocator, "PingTopic", PingMsg);
    defer ping_topic.deinit(participant.allocator);
    var pong_topic = try ddz.dcps.Topic.initTyped(participant.allocator, "PongTopic", PingMsg);
    defer pong_topic.deinit(participant.allocator);

    var writer_qos = ddz.dcps.Qos.WriterQos{};
    if (reliable) writer_qos.reliability.kind = .reliable;

    var reader_qos = ddz.dcps.Qos.ReaderQos{};
    if (reliable) reader_qos.reliability.kind = .reliable;
    reader_qos.history.depth = 100; // Large enough buffer

    const ping_writer = try publisher.createDataWriter(ping_topic, writer_qos, ddz.rtps.types.EntityId_t.unknown);
    const pong_reader = try subscriber.createDataReader(pong_topic, reader_qos, ddz.rtps.types.EntityId_t.unknown);

    std.debug.print("Waiting for discovery...\n", .{});
    participant.announce() catch {};
    participant.announceEndpoints() catch {};

    var discovery_waited: u32 = 0;
    while (discovery_waited < 10000) {
        if (ping_writer.matched_readers.items.len > 0 and (throughput or pong_reader.matched_writers.items.len > 0)) {
            std.debug.print("Discovery complete.\n", .{});
            // Give remote subscriber a moment to complete matching endpoints
            ddz.os.sleepMs(500);
            break;
        }
        ddz.os.sleepMs(50);
        discovery_waited += 50;
        if (discovery_waited % 500 == 0) {
            participant.announce() catch {};
            participant.announceEndpoints() catch {};
        }
    }

    var msg = PingMsg{
        .sequence_num = 0,
        .timestamp_ns = 0,
        .payload_len = size,
        .payload = undefined,
    };
    @memset(&msg.payload, 0);
    for (0..size) |idx| {
        msg.payload[idx] = @truncate(idx % 256);
    }

    var latencies = std.ArrayList(f64).empty;
    defer latencies.deinit(participant.allocator);

    if (throughput) {
        std.debug.print("Starting throughput test ({} samples, {} payload bytes)...\n", .{ samples, size });
        const start_time = ddz.os.getNanoTimestamp();

        var i: u32 = 0;
        while (i < samples) : (i += 1) {
            msg.sequence_num = i;
            msg.timestamp_ns = ddz.os.getNanoTimestamp();
            try ping_writer.write(msg);

            // Minimal sleep occasionally to prevent overflowing UDP buffers completely
            // if we are blasting unreliably. But reliable should handle flow control.
            if (!reliable and i % 1000 == 0) ddz.os.sleepMs(1);
        }

        // Let it flush
        ddz.os.sleepMs(500);

        const end_time = ddz.os.getNanoTimestamp();
        const diff_s: f64 = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000_000.0;
        const total_payload_bytes = samples * (16 + size);
        const total_wire_bytes = samples * @sizeOf(PingMsg);
        const payload_mb_per_sec = (@as(f64, @floatFromInt(total_payload_bytes)) / 1024.0 / 1024.0) / diff_s;
        const wire_mb_per_sec = (@as(f64, @floatFromInt(total_wire_bytes)) / 1024.0 / 1024.0) / diff_s;

        std.debug.print("Throughput: {d:.2} samples/sec ({d:.2} MB/s payload, {d:.2} MB/s wire)\n", .{
            @as(f64, @floatFromInt(samples)) / diff_s,
            payload_mb_per_sec,
            wire_mb_per_sec,
        });
    } else {
        std.debug.print("Starting latency test ({} samples)...\n", .{samples});
        var i: u32 = 0;
        while (i < samples) : (i += 1) {
            msg.sequence_num = i;
            msg.timestamp_ns = ddz.os.getNanoTimestamp();
            try ping_writer.write(msg);

            // Wait for pong
            var pong_received = false;
            var wait_time: u32 = 0;
            while (wait_time < 1000) {
                if (pong_reader.takeNextSample(PingMsg) catch |err| {
                    std.debug.print("TakeErr: {}\n", .{err});
                    return err;
                }) |pong_data| {
                    if (pong_data.data.sequence_num == i) {
                        const recv_time = ddz.os.getNanoTimestamp();
                        const rtt = @as(f64, @floatFromInt(recv_time - pong_data.data.timestamp_ns)) / 1_000_000.0; // ms
                        try latencies.append(participant.allocator, rtt);
                        if (samples <= 20 or i < 10 or (samples > 20 and i % (samples / 10) == 0) or i == samples - 1) {
                            std.debug.print("Reply from seq={}: time={d:.3} ms\n", .{ i, rtt });
                        }
                        pong_received = true;
                        break;
                    }
                }
                ddz.os.sleepMs(1);
                wait_time += 1;
            }

            if (!pong_received) {
                std.debug.print("Timeout on seq={}\n", .{i});
            }
            ddz.os.sleepMs(10); // 10ms interval between pings
        }

        if (latencies.items.len > 0) {
            var min: f64 = latencies.items[0];
            var max: f64 = latencies.items[0];
            var sum: f64 = 0;
            for (latencies.items) |l| {
                if (l < min) min = l;
                if (l > max) max = l;
                sum += l;
            }
            const avg = sum / @as(f64, @floatFromInt(latencies.items.len));

            std.debug.print("\n--- Ping Statistics ---\n", .{});
            std.debug.print("{} samples transmitted, {} received\n", .{ samples, latencies.items.len });
            std.debug.print("rtt min/avg/max = {d:.3}/{d:.3}/{d:.3} ms\n", .{ min, avg, max });
        }
    }
}
