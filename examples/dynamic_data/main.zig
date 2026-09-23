//! @file main.zig
//! @brief DynamicData API Example.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr
//! Copyright: (c) 2026 0xGodyr. All rights reserved.

const std = @import("std");
const ddz = @import("ddz");

pub fn main() void {
    run() catch |err| {
        std.debug.print("ERROR: {}\n", .{err});
    };
}

fn run() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("Starting DynamicData Example...\n", .{});

    var factory = ddz.dcps.DomainParticipantFactory.getInstance();
    var pub_participant = try factory.createParticipant(0, null, allocator);
    defer factory.deleteParticipant(pub_participant, allocator) catch {};
    try pub_participant.enable();

    var sub_participant = try factory.createParticipant(0, null, allocator);
    defer factory.deleteParticipant(sub_participant, allocator) catch {};
    try sub_participant.enable();

    const publisher = try pub_participant.createPublisher(null);
    const subscriber = try sub_participant.createSubscriber(null);

    // 1. Construct TypeObject manually without compile-time structs!
    var type_obj = ddz.xtypes.TypeObject{
        .name = "ShapeType",
        .fields = std.ArrayList(ddz.xtypes.FieldDef).empty,
    };
    try type_obj.fields.append(allocator, .{ .name = "color", .kind = .String, .array_len = 16 });
    try type_obj.fields.append(allocator, .{ .name = "x", .kind = .Int32, .array_len = 0 });
    try type_obj.fields.append(allocator, .{ .name = "y", .kind = .Int32, .array_len = 0 });
    try type_obj.fields.append(allocator, .{ .name = "size", .kind = .Int32, .array_len = 0 });

    const writer_qos = ddz.dcps.Qos.WriterQos{};
    const reader_qos = ddz.dcps.Qos.ReaderQos{};

    // 2. Create DynamicDataWriter
    var dynamic_writer = try ddz.dcps.DynamicDataWriter.init(publisher, "Square", writer_qos, type_obj);
    defer dynamic_writer.deinit();

    // 3. Create DynamicDataReader
    var dynamic_reader = try ddz.dcps.DynamicDataReader.init(subscriber, "Square", reader_qos);
    defer dynamic_reader.deinit();

    // Announce
    try pub_participant.announce();
    try pub_participant.announceEndpoints();
    try sub_participant.announce();
    try sub_participant.announceEndpoints();

    // Give time for discovery
    ddz.os.sleepMs(200);

    // 4. Construct DynamicValue to send
    var struct_map = std.StringHashMap(ddz.xtypes.DynamicValue).init(allocator);
    defer struct_map.deinit();

    try struct_map.put("color", .{ .String = "RED" });
    try struct_map.put("x", .{ .Int32 = 42 });
    try struct_map.put("y", .{ .Int32 = 84 });
    try struct_map.put("size", .{ .Int32 = 100 });

    const val = ddz.xtypes.DynamicValue{ .Struct = struct_map };

    std.debug.print("[Publisher] Writing DynamicValue (color=RED, x=42, y=84, size=100)...\n", .{});
    try dynamic_writer.writeDynamic(val);

    // Wait for delivery
    ddz.os.sleepMs(200);

    // 5. Read dynamically
    if (dynamic_reader.underlying_reader.history_cache.getLen() > 0) {
        var current = dynamic_reader.underlying_reader.history_cache.global_head;
        while (current) |node| {
            const next = node.global_next;
            const sn = node.change.sequence_number;
            std.debug.print("[Subscriber] Found sample with SN: {d}\n", .{sn.low});

            if (try dynamic_reader.takeDynamic(sn)) |read_val| {
                var dynamic_val = read_val;
                defer dynamic_val.deinit(allocator);

                if (dynamic_val == .Struct) {
                    const color = dynamic_val.Struct.get("color").?.String;
                    const x = dynamic_val.Struct.get("x").?.Int32;
                    const y = dynamic_val.Struct.get("y").?.Int32;
                    const size = dynamic_val.Struct.get("size").?.Int32;

                    std.debug.print("[Subscriber] Received DynamicValue: color={s}, x={}, y={}, size={}\n", .{ std.mem.sliceTo(color, 0), x, y, size });
                }
            } else {
                std.debug.print("[Subscriber] takeDynamic returned null for SN {d}\n", .{sn.low});
            }
            current = next;
        }
    } else {
        std.debug.print("[Subscriber] No samples received!\n", .{});
    }

    std.debug.print("Example completed.\n", .{});
    pub_participant.stop();
    sub_participant.stop();
}
