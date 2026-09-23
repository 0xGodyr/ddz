//! @file main.zig
//! @brief Demonstrates DDS Security plugins (Authentication, Access Control, Cryptography).
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const ddz = @import("ddz");
const Sleep = ddz.os.sleepMs;

const SecureData = struct {
    secret_code: [32]u8,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("Starting DDS-SEC Example...\n", .{});

    // 1. Initialize DomainParticipant with Security Enabled

    const auth_plugin = try ddz.security.AuthenticationPlugin.PkiDhAuthentication.init(allocator, "mock_ca", "mock_key", "mock_cert");
    defer ddz.security.AuthenticationPlugin.PkiDhAuthentication.deinit(auth_plugin, allocator);
    const access_plugin = try ddz.security.AccessControlPlugin.PermissionsAccessControl.init(allocator, "mock_ca", "<gov></gov>", "<perm></perm>");
    defer ddz.security.AccessControlPlugin.PermissionsAccessControl.deinit(access_plugin, allocator);

    var factory = ddz.dcps.DomainParticipantFactory.getInstance();
    var participant = try factory.createParticipant(0, null, allocator);
    participant.auth_plugin = auth_plugin;
    participant.access_plugin = access_plugin;
    defer factory.deleteParticipant(participant, allocator) catch {};

    try participant.enable();

    var publisher = try participant.createPublisher(null);
    var subscriber = try participant.createSubscriber(null);

    const topic = ddz.dcps.Topic.init("TopSecretTopic", "SecureData");

    var writer = try publisher.createDataWriter(topic, .{}, ddz.rtps.types.EntityId_t.unknown);
    var reader = try subscriber.createDataReader(topic, .{}, ddz.rtps.types.EntityId_t.unknown);

    Sleep(1000); // Allow PKI-DH Handshake to complete

    var data = SecureData{ .secret_code = std.mem.zeroes([32]u8) };
    const text = "Nuclear Launch Code: 12345";
    @memcpy(data.secret_code[0..text.len], text);

    std.debug.print("[Publisher] Writing Encrypted Message: {s}\n", .{text});
    try writer.write(data);
    try writer.flush();

    Sleep(100);

    const samples = try reader.take(SecureData, 10, .any, .any, .any);
    defer reader.returnLoan(SecureData, samples);

    for (samples) |sample| {
        std.debug.print("[Subscriber] Decrypted Message: {s}\n", .{std.mem.sliceTo(&sample.data.secret_code, 0)});
    }

    std.debug.print("Example completed.\n", .{});
}
