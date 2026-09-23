//! @file main.zig
//! @brief Demonstrates DDS-RPC Request/Reply pattern and remote procedure calls over DDS.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const ddz = @import("ddz");

const Sleep = ddz.os.sleepMs;

const RequestMsg = struct {
    a: i32,
    b: i32,
};

const ReplyMsg = struct {
    sum: i32,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("Starting RPC over DDS Example...\n", .{});

    var factory = ddz.dcps.DomainParticipantFactory.getInstance();
    var participant = try factory.createParticipant(0, null, allocator);
    defer factory.deleteParticipant(participant, allocator) catch {};
    try participant.enable();

    // 1. Create Request and Reply Topics
    var req_topic = try ddz.dcps.Topic.initTyped(allocator, "MathRequestTopic", RequestMsg);
    defer req_topic.deinit(allocator);
    var rep_topic = try ddz.dcps.Topic.initTyped(allocator, "MathReplyTopic", ReplyMsg);
    defer rep_topic.deinit(allocator);

    // 2. Setup Requester
    var req_pub = try participant.createPublisher(null);
    var req_sub = try participant.createSubscriber(null);
    const request_writer = try req_pub.createDataWriter(req_topic, .{}, ddz.rtps.types.EntityId_t.unknown);
    const reply_reader = try req_sub.createDataReader(rep_topic, .{}, ddz.rtps.types.EntityId_t.unknown);

    var requester = ddz.dcps.rpc.Requester(RequestMsg, ReplyMsg).init(request_writer, reply_reader);

    // 3. Setup Replier
    var rep_pub = try participant.createPublisher(null);
    var rep_sub = try participant.createSubscriber(null);
    const request_reader = try rep_sub.createDataReader(req_topic, .{}, ddz.rtps.types.EntityId_t.unknown);
    const reply_writer = try rep_pub.createDataWriter(rep_topic, .{}, ddz.rtps.types.EntityId_t.unknown);

    var replier = ddz.dcps.rpc.Replier(RequestMsg, ReplyMsg).init(allocator, request_reader, reply_writer);
    defer replier.deinit();

    // Give SPDP discovery time to connect
    Sleep(1000);

    var replier_running = std.atomic.Value(bool).init(true);

    // Start Replier in a background thread
    var thread = try std.Thread.spawn(.{}, replierThread, .{ &replier, &replier_running });

    // Make Requests
    var i: i32 = 1;
    while (i <= 3) : (i += 1) {
        const req = RequestMsg{ .a = i * 10, .b = i * 5 };
        std.debug.print("[Requester] Sending Request {d}: {d} + {d}\n", .{ i, req.a, req.b });

        const req_id = try requester.sendRequest(req);

        // Wait up to 5 seconds for a reply
        if (try requester.waitForReply(req_id, 5000)) |rep| {
            std.debug.print("[Requester] Received Reply for Request {d}: sum = {d}\n", .{ i, rep.sum });
        } else {
            std.debug.print("[Requester] ERROR: No reply received for Request {d}\n", .{i});
        }
    }

    replier_running.store(false, .seq_cst);
    thread.join();
    participant.stop();

    std.debug.print("Example completed successfully.\n", .{});
}

fn replierThread(replier: *ddz.dcps.rpc.Replier(RequestMsg, ReplyMsg), running: *std.atomic.Value(bool)) !void {
    std.debug.print("[Replier] Started listening for requests...\n", .{});
    while (running.load(.seq_cst)) {
        if (try replier.receiveRequest(100)) |info| {
            std.debug.print("[Replier] Received Request: {d} + {d}. Processing...\n", .{ info.data.a, info.data.b });

            // Do work
            const rep = ReplyMsg{ .sum = info.data.a + info.data.b };

            std.debug.print("[Replier] Sending Reply: {d}\n", .{rep.sum});
            try replier.sendReply(rep, info.identity);
        }
    }
}
