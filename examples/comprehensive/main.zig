//! @file main.zig
//! @brief DDZ Library Entry Point / Demo Application.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr
//! Copyright: (c) 2026 0xGodyr. All rights reserved.

const std = @import("std");
const ddz = @import("ddz");

/// @brief Chat message structure.
const ChatMessage = struct {
    id: u32,
    text: [32]u8,
    pub const ddz_keys = .{"id"};
};

/// @brief Main.
pub fn main() void {
    run() catch |err| {
        std.debug.print("ERROR: {}\n", .{err});
    };
}

fn run() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("Starting DDZ Test Application...\n", .{});

    // 1. Initialize Participants
    // We use different participant IDs (0, 1, 2) to avoid unicast port collisions on the same localhost
    // Initialize DDS-SEC Plugins
    const auth_plugin = try ddz.security.AuthenticationPlugin.PkiDhAuthentication.init(allocator, "mock_ca", "mock_key", "mock_cert");
    defer ddz.security.AuthenticationPlugin.PkiDhAuthentication.deinit(auth_plugin, allocator);
    const access_plugin = try ddz.security.AccessControlPlugin.PermissionsAccessControl.init(allocator, "mock_ca", "<gov></gov>", "<perm></perm>");
    defer ddz.security.AccessControlPlugin.PermissionsAccessControl.deinit(access_plugin, allocator);
    const crypto_plugin = try ddz.security.CryptographyPlugin.AesGcmCryptography.init(allocator);
    defer ddz.security.CryptographyPlugin.AesGcmCryptography.deinit(crypto_plugin, allocator);

    var test_key: [32]u8 = undefined;
    @memset(&test_key, 0xDD);
    // Cast the CryptographyPlugin ptr back to inject the test key
    var aes_crypto: *ddz.security.CryptographyPlugin.AesGcmCryptography = @ptrCast(@alignCast(crypto_plugin.ptr));
    try aes_crypto.keys.put(allocator, 1, test_key);

    const crypto_plugin_sub1 = try ddz.security.CryptographyPlugin.AesGcmCryptography.init(allocator);
    defer ddz.security.CryptographyPlugin.AesGcmCryptography.deinit(crypto_plugin_sub1, allocator);
    var aes_crypto_sub1: *ddz.security.CryptographyPlugin.AesGcmCryptography = @ptrCast(@alignCast(crypto_plugin_sub1.ptr));
    try aes_crypto_sub1.keys.put(allocator, 1, test_key);

    const crypto_plugin_sub2 = try ddz.security.CryptographyPlugin.AesGcmCryptography.init(allocator);
    defer ddz.security.CryptographyPlugin.AesGcmCryptography.deinit(crypto_plugin_sub2, allocator);
    var aes_crypto_sub2: *ddz.security.CryptographyPlugin.AesGcmCryptography = @ptrCast(@alignCast(crypto_plugin_sub2.ptr));
    try aes_crypto_sub2.keys.put(allocator, 1, test_key);

    var factory = ddz.dcps.DomainParticipantFactory.getInstance();
    var pub_participant = try factory.createParticipant(0, null, allocator);
    pub_participant.auth_plugin = auth_plugin;
    pub_participant.access_plugin = access_plugin;
    pub_participant.crypto_plugin = crypto_plugin;
    defer factory.deleteParticipant(pub_participant, allocator) catch {};
    try pub_participant.enable();

    var sub1_participant = try factory.createParticipant(0, null, allocator);
    sub1_participant.auth_plugin = auth_plugin;
    sub1_participant.crypto_plugin = crypto_plugin_sub1;
    sub1_participant.filter_expression = "id >= 3";
    defer factory.deleteParticipant(sub1_participant, allocator) catch {};
    try sub1_participant.enable();

    var sub2_participant = try factory.createParticipant(0, null, allocator);
    sub2_participant.auth_plugin = auth_plugin;
    sub2_participant.crypto_plugin = crypto_plugin_sub2;
    sub2_participant.permissions_doc = "<allow>ChatRoom</allow>";
    defer factory.deleteParticipant(sub2_participant, allocator) catch {};
    try sub2_participant.enable();

    // 2. Create Publishers and Subscribers
    const publisher = try pub_participant.createPublisher(null);

    const sub1 = try sub1_participant.createSubscriber(null);

    const sub2 = try sub2_participant.createSubscriber(null);

    // 3. Create Topic and Entities
    var topic = try ddz.dcps.Topic.initTyped(allocator, "ChatRoom", ChatMessage);
    defer topic.deinit(allocator);

    const writer_qos = ddz.dcps.Qos.WriterQos{
        .reliability = .{ .kind = .reliable },
        .history = .{ .kind = .keep_last, .depth = 10 },
        .batch = .{ .enable = true, .max_data_bytes = 1024, .max_flush_delay_ms = 2000 },
        .shm = .{ .enable = true, .segment_size = 65536 },
        .security_key = test_key,
    };

    const reader_qos = ddz.dcps.Qos.ReaderQos{
        .reliability = .{ .kind = .reliable },
        .history = .{ .kind = .keep_last, .depth = 10 },
        .security_key = test_key,
    };

    const data_writer = try publisher.createDataWriter(topic, writer_qos, ddz.rtps.types.EntityId_t.unknown);

    // Subscriber 1 uses dynamic types!
    var data_reader1 = try ddz.dcps.DynamicDataReader.init(sub1, "ChatRoom", reader_qos);
    defer data_reader1.deinit();

    const cft = ddz.dcps.ContentFilteredTopic.init("ChatRoomFiltered", topic, "id > 2");
    const data_reader2 = try sub2.createDataReader(cft, reader_qos, ddz.rtps.types.EntityId_t.unknown);

    var waitset = ddz.dcps.WaitSet.init(allocator);
    defer waitset.deinit();

    var read_cond2 = try data_reader2.createReadCondition(.any, .any, .any);
    try waitset.attachCondition(&read_cond2.condition);

    std.debug.print("Nodes created. Announcing presence...\n", .{});

    // Register type for TypeLookup Service
    try pub_participant.registerType(ChatMessage);

    // Send initial announcements
    try pub_participant.announce();
    try pub_participant.announceEndpoints();
    try sub1_participant.announce();
    try sub1_participant.announceEndpoints();
    try sub2_participant.announce();
    try sub2_participant.announceEndpoints();

    // Give time for discovery
    ddz.os.sleepMs(500);

    // Main Loop
    var counter: u32 = 1;
    while (counter <= 5) : (counter += 1) {
        std.debug.print("\n--- Loop {} ---\n", .{counter});

        // Re-announce periodically
        try pub_participant.announce();
        try pub_participant.announceEndpoints();

        // Publisher sends a message
        var msg = ChatMessage{ .id = counter, .text = std.mem.zeroes([32]u8) };
        const text_slice = "Hello from Publisher!";
        @memcpy(msg.text[0..text_slice.len], text_slice);

        std.debug.print("[Publisher] Sending message {} to {} discovered participants.\n", .{ counter, pub_participant.discovered_participants.len });
        try data_writer.write(msg);

        // Wait using our new WaitSet engine!
        // We give it 1 second timeout for this loop
        const active_conditions = waitset.wait(std.time.ns_per_s * 1) catch &[_]*ddz.dcps.Condition{};
        defer if (active_conditions.len > 0) allocator.free(active_conditions);

        if (active_conditions.len > 0) {
            // A condition was triggered!
            read_cond2.condition.setTriggerValue(false); // Reset it for the next loop
        }

        // Readers check their history cache
        if (data_reader1.underlying_reader.history_cache.getLen() > 0) {
            const sn = ddz.rtps.types.SequenceNumber_t{ .high = 0, .low = counter };
            if (try data_reader1.takeDynamic(sn)) |val| {
                var dynamic_val = val;
                defer dynamic_val.deinit(allocator);
                if (dynamic_val == .Struct) {
                    const id = dynamic_val.Struct.get("id").?.UInt32;
                    const text_val = dynamic_val.Struct.get("text").?.String;
                    std.debug.print("[Subscriber 1 - DYNAMIC] Received Message ID: {} Text: {s}\n", .{ id, std.mem.sliceTo(text_val, 0) });
                }
            } else {
                std.debug.print("[Subscriber 1 - DYNAMIC] Resolving type object...\n", .{});
            }
        } else {
            std.debug.print("[Subscriber 1] No messages received yet.\n", .{});
        }

        const samples2 = try data_reader2.take(ChatMessage, 10, .any, .any, .any);
        defer data_reader2.returnLoan(ChatMessage, samples2);
        for (samples2) |sample| {
            std.debug.print("[Subscriber 2] [WaitSet Triggered] Received Message ID: {} Text: {s}\n", .{ sample.data.id, std.mem.sliceTo(&sample.data.text, 0) });
        }
    }

    std.debug.print("\nTest completed successfully.\n", .{});

    // Explicitly stop network threads before defers destroy objects
    pub_participant.stop();
    sub1_participant.stop();
    sub2_participant.stop();
}
