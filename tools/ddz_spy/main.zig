//! @file main.zig
//! @brief Real-time network monitoring and traffic introspection tool (ddz_spy) for DDZ.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const ddz = @import("ddz");

// Keep track of which topics we've dynamically subscribed to
var spied_topics: std.StringHashMap(*ddz.dcps.DynamicDataReader) = undefined;

pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.page_allocator;

    var domain_id: u32 = 0;

    var args = try init.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.skip(); // skip executable name

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print(
                \\Usage: ddz_spy [options]
                \\
                \\A passive DDS network sniffer and discovery dissection tool.
                \\
                \\Options:
                \\  -d, --domain <id>  Domain ID to monitor (default: 0)
                \\  -h, --help         Display this help message and exit
                \\
            , .{});
            return;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--domain")) {
            if (args.next()) |d_str| {
                domain_id = std.fmt.parseInt(u32, d_str, 10) catch {
                    std.debug.print("Error: invalid domain ID '{s}'\n", .{d_str});
                    return;
                };
            }
        }
    }

    std.debug.print("=========================================\n", .{});
    std.debug.print("=        DDZ SPY - Network Sniffer      =\n", .{});
    std.debug.print("=========================================\n", .{});

    spied_topics = std.StringHashMap(*ddz.dcps.DynamicDataReader).init(allocator);
    defer {
        var sit = spied_topics.iterator();
        while (sit.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
            allocator.destroy(entry.value_ptr.*);
        }
        spied_topics.deinit();
    }

    var factory = ddz.dcps.DomainParticipantFactory.getInstance();
    var participant = try factory.createParticipant(domain_id, null, allocator);
    defer factory.deleteParticipant(participant, allocator) catch {};

    try participant.enable();
    std.debug.print("[Spy] DomainParticipant enabled (Domain {d}).\n", .{domain_id});

    var waitset = ddz.dcps.WaitSet.init(allocator);
    defer waitset.deinit();

    // 1. Attach to SEDP Publisher Reader (Discovers new Writers/Topics)
    if (participant.sedp_pub_reader) |pub_reader| {
        const cond = try pub_reader.createReadCondition(.{ .not_read = true }, .any, .any);
        try waitset.attachCondition(&cond.condition);
        std.debug.print("[Spy] Attached to SEDP Pub Discovery.\n", .{});
    } else {
        std.debug.print("Error: SEDP Pub Reader not found.\n", .{});
        return;
    }

    // 2. Attach to SEDP Subscriber Reader (Discovers new Readers)
    if (participant.sedp_sub_reader) |sub_reader| {
        const cond = try sub_reader.createReadCondition(.{ .not_read = true }, .any, .any);
        try waitset.attachCondition(&cond.condition);
        std.debug.print("[Spy] Attached to SEDP Sub Discovery.\n", .{});
    } else {
        std.debug.print("Error: SEDP Sub Reader not found.\n", .{});
        return;
    }

    const subscriber = try participant.createSubscriber(null);

    std.debug.print("[Spy] Waiting for network traffic...\n\n", .{});

    // 3. Event Loop
    while (true) {
        const active_conditions = try waitset.wait(5 * std.time.ns_per_s);

        defer allocator.free(active_conditions);

        if (active_conditions.len == 0) {
            continue; // timeout
        }

        for (active_conditions) |cond| {
            if (cond.kind == .read_condition) {
                const rc: *ddz.dcps.ReadCondition = @ptrCast(@alignCast(cond));
                if (rc.reader == participant.sedp_pub_reader.?) {
                    try processDiscoveredWriter(allocator, participant.sedp_pub_reader.?, subscriber, &waitset);
                } else if (rc.reader == participant.sedp_sub_reader.?) {
                    try processDiscoveredReader(participant.sedp_sub_reader.?);
                } else {
                    try processDynamicData(rc);
                }
            }
        }
    }
}

fn processDiscoveredWriter(allocator: std.mem.Allocator, sedp_reader: *ddz.dcps.DataReader, subscriber: *ddz.dcps.Subscriber, waitset: *ddz.dcps.WaitSet) !void {
    const samples = try sedp_reader.read(ddz.builtin.PublicationData, 100, .{ .not_read = true }, .any, .any);
    defer sedp_reader.returnLoan(ddz.builtin.PublicationData, samples);

    for (samples) |sample| {
        if (!sample.info.valid_data) continue;
        const data = sample.data;
        const topic_name = data.topic_name;
        const type_name = data.type_name;

        std.debug.print("[Discovery] New Publisher -> Topic: '{s}', Type: '{s}'\n", .{ topic_name, type_name });

        // If we haven't seen this topic yet, create a dynamic reader for it
        if (!spied_topics.contains(topic_name)) {
            std.debug.print("            Subscribing dynamically to '{s}'...\n", .{topic_name});

            // Allocate topic name to store in the map persistently
            const persistent_topic = try allocator.dupe(u8, topic_name);

            const dyn_reader = try allocator.create(ddz.dcps.DynamicDataReader);
            dyn_reader.* = try ddz.dcps.DynamicDataReader.init(subscriber, persistent_topic, .{});

            try spied_topics.put(persistent_topic, dyn_reader);

            const cond = try dyn_reader.underlying_reader.createReadCondition(.{ .not_read = true }, .any, .any);
            try waitset.attachCondition(&cond.condition);
        }
    }
}

fn processDiscoveredReader(sedp_reader: *ddz.dcps.DataReader) !void {
    const samples = try sedp_reader.read(ddz.builtin.SubscriptionData, 100, .{ .not_read = true }, .any, .any);
    defer sedp_reader.returnLoan(ddz.builtin.SubscriptionData, samples);

    for (samples) |sample| {
        if (!sample.info.valid_data) continue;
        const data = sample.data;
        std.debug.print("[Discovery] New Subscriber -> Topic: '{s}', Type: '{s}'\n", .{ data.topic_name, data.type_name });
    }
}

fn processDynamicData(rc: *ddz.dcps.ReadCondition) !void {
    // Find which dynamic reader this belongs to
    var it = spied_topics.iterator();
    while (it.next()) |entry| {
        const dyn_reader = entry.value_ptr.*;
        if (rc.reader == dyn_reader.underlying_reader) {
            var cache = &dyn_reader.underlying_reader.history_cache;

            // Collect unread payloads with lock held, then process outside lock
            const PayloadItem = struct {
                data: []const u8,
                kind: ddz.rtps.ChangeKind,
            };
            var payloads: std.ArrayListUnmanaged(PayloadItem) = .empty;
            defer payloads.deinit(dyn_reader.allocator);

            while (cache.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
                std.atomic.spinLoopHint();
            }

            var current = cache.global_head;
            while (current) |node| : (current = node.global_next) {
                if (node.sample_state == .not_read) {
                    node.sample_state = .read;
                    payloads.append(dyn_reader.allocator, .{
                        .data = node.change.data_value,
                        .kind = node.change.kind,
                    }) catch {};
                }
            }
            cache.lock.store(false, .release);

            // Now decode without holding cache.lock!
            for (payloads.items) |item| {
                if (dyn_reader.takeDynamicPayload(item.data) catch @as(?ddz.xtypes.DynamicValue, null)) |dyn_val_val| {
                    var dyn_val = dyn_val_val;
                    defer dyn_val.deinit(dyn_reader.allocator);
                    std.debug.print("[Data] [{s}] Payload:\n", .{dyn_reader.topic_name});
                    try printDynamicValue(dyn_val, 2);
                    std.debug.print("\n", .{});
                } else {
                    if (item.kind == .ALIVE) {
                        std.debug.print("[Data] [{s}] Unrecognized Payload ({} bytes)\n", .{ dyn_reader.topic_name, item.data.len });
                    } else {
                        std.debug.print("[Data] [{s}] Instance State Changed: {}\n", .{ dyn_reader.topic_name, item.kind });
                    }
                }
            }
            return;
        }
    }
}

fn printIndent(indent: usize) void {
    var i: usize = 0;
    while (i < indent) : (i += 1) {
        std.debug.print(" ", .{});
    }
}

fn printDynamicValue(val: ddz.xtypes.DynamicValue, indent: usize) !void {
    switch (val) {
        .UInt8 => |v| std.debug.print("{d}", .{v}),
        .UInt16 => |v| std.debug.print("{d}", .{v}),
        .UInt32 => |v| std.debug.print("{d}", .{v}),
        .UInt64 => |v| std.debug.print("{d}", .{v}),
        .Int8 => |v| std.debug.print("{d}", .{v}),
        .Int16 => |v| std.debug.print("{d}", .{v}),
        .Int32 => |v| std.debug.print("{d}", .{v}),
        .Int64 => |v| std.debug.print("{d}", .{v}),
        .Float32 => |v| std.debug.print("{d}", .{v}),
        .Float64 => |v| std.debug.print("{d}", .{v}),
        .Bool => |v| std.debug.print("{}", .{v}),
        .String => |v| std.debug.print("\"{s}\"", .{v}),
        .Void => std.debug.print("null", .{}),
        .Optional => |opt| {
            if (opt) |inner| {
                try printDynamicValue(inner.*, indent);
            } else {
                std.debug.print("null", .{});
            }
        },
        .Struct => |*s| {
            std.debug.print("{{\n", .{});
            var sit = s.iterator();
            var i: usize = 0;
            const count = s.count();
            while (sit.next()) |entry| {
                printIndent(indent);
                std.debug.print("  \"{s}\": ", .{entry.key_ptr.*});
                try printDynamicValue(entry.value_ptr.*, indent + 2);
                if (i < count - 1) {
                    std.debug.print(",\n", .{});
                } else {
                    std.debug.print("\n", .{});
                }
                i += 1;
            }
            printIndent(indent);
            std.debug.print("}}", .{});
        },
        .Array => |*a| {
            std.debug.print("[\n", .{});
            for (a.items, 0..) |item, i| {
                printIndent(indent);
                std.debug.print("  ", .{});
                try printDynamicValue(item, indent + 2);
                if (i < a.items.len - 1) {
                    std.debug.print(",\n", .{});
                } else {
                    std.debug.print("\n", .{});
                }
            }
            printIndent(indent);
            std.debug.print("]", .{});
        },
        else => std.debug.print("\"<unsupported>\"", .{}),
    }
}
