//! @file main.zig
//! @brief Round-trip latency and throughput benchmarking CLI utility for DDZ.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const ddz = @import("ddz");
const PublisherRole = @import("publisher_role.zig");
const SubscriberRole = @import("subscriber_role.zig");
const PingMsg = @import("ping_msg.zig").PingMsg;

pub fn main(init: std.process.Init.Minimal) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try init.args.iterateAllocator(allocator);
    defer args.deinit();

    _ = args.skip(); // skip exe name

    var is_pub: ?bool = null;
    var samples_specified = false;
    var samples: u32 = 10;
    var size: u32 = 10;
    var reliable = false;
    var throughput = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-help")) {
            std.debug.print("Usage: ddz_ping [-pub | -sub] [-samples N] [-size N] [-reliable] [-throughput]\n", .{});
            return;
        } else if (std.mem.eql(u8, arg, "-pub")) {
            is_pub = true;
        } else if (std.mem.eql(u8, arg, "-sub")) {
            is_pub = false;
        } else if (std.mem.eql(u8, arg, "-reliable")) {
            reliable = true;
        } else if (std.mem.eql(u8, arg, "-throughput")) {
            throughput = true;
        } else if (std.mem.eql(u8, arg, "-samples")) {
            if (args.next()) |val| {
                samples = try std.fmt.parseInt(u32, val, 10);
                samples_specified = true;
            } else {
                std.debug.print("Missing value for -samples\n", .{});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "-size")) {
            if (args.next()) |val| {
                size = try std.fmt.parseInt(u32, val, 10);
                if (size > 1024) {
                    std.debug.print("Max size supported is 1024 bytes\n", .{});
                    std.process.exit(1);
                }
            } else {
                std.debug.print("Missing value for -size\n", .{});
                std.process.exit(1);
            }
        } else {
            std.debug.print("Unknown argument: {s}\n", .{arg});
            std.debug.print("Usage: ddz_ping [-pub | -sub] [-samples N] [-size N] [-reliable] [-throughput]\n", .{});
            std.process.exit(1);
        }
    }

    if (is_pub == null) {
        std.debug.print("Error: Must specify either -pub or -sub\n\n", .{});
        std.debug.print("Usage: ddz_ping [-pub | -sub] [-samples N] [-size N] [-reliable] [-throughput]\n", .{});
        std.process.exit(1);
    }

    if (throughput and !samples_specified) {
        samples = 10000;
    }

    var factory = ddz.dcps.DomainParticipantFactory.getInstance();
    var participant = try factory.createParticipant(0, null, allocator);
    defer factory.deleteParticipant(participant, allocator) catch {};

    try participant.registerType(PingMsg);

    try participant.enable();

    if (is_pub.?) {
        std.debug.print("Starting DDZ Ping Publisher...\n", .{});
        std.debug.print("Samples: {}, Size: {}, Reliable: {}, Throughput: {}\n", .{ samples, size, reliable, throughput });
        try PublisherRole.run(participant, samples, size, reliable, throughput);
    } else {
        std.debug.print("Starting DDZ Ping Subscriber...\n", .{});
        const max_samples: ?u32 = if (samples_specified) samples else null;
        if (max_samples) |ms| {
            std.debug.print("Max Samples: {}, Reliable: {}, Throughput: {}\n", .{ ms, reliable, throughput });
        } else {
            std.debug.print("Mode: Daemon, Reliable: {}, Throughput: {}\n", .{ reliable, throughput });
        }
        try SubscriberRole.run(participant, reliable, throughput, max_samples);
    }
}
