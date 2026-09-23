//! @file cryptography_plugin.zig
//! @brief Implements DDS-SEC payload and submessage encryption using AES-256-GCM.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const rtps = @import("../root.zig").rtps;
const getNanoTimestamp = @import("../os.zig").getNanoTimestamp;

pub const CryptoKeyId = u32;

/// @brief Cryptography Plugin interface.
pub const CryptographyPlugin = struct {
    encrypt_serialized_payload_fn: *const fn (
        ptr: *anyopaque,
        payload: []const u8,
        key_id: CryptoKeyId,
        out_buffer: []u8,
    ) anyerror![]const u8,

    decrypt_serialized_payload_fn: *const fn (
        ptr: *anyopaque,
        secure_payload: []const u8,
        key_id: CryptoKeyId,
        out_buffer: []u8,
    ) anyerror![]const u8,

    ptr: *anyopaque,

    pub fn encryptSerializedPayload(
        self: *const CryptographyPlugin,
        payload: []const u8,
        key_id: CryptoKeyId,
        out_buffer: []u8,
    ) anyerror![]const u8 {
        return self.encrypt_serialized_payload_fn(self.ptr, payload, key_id, out_buffer);
    }

    pub fn decryptSerializedPayload(
        self: *const CryptographyPlugin,
        secure_payload: []const u8,
        key_id: CryptoKeyId,
        out_buffer: []u8,
    ) anyerror![]const u8 {
        return self.decrypt_serialized_payload_fn(self.ptr, secure_payload, key_id, out_buffer);
    }

    pub fn registerKey(self: *const CryptographyPlugin, key_id: CryptoKeyId, key: [32]u8) !void {
        const crypto: *AesGcmCryptography = @ptrCast(@alignCast(self.ptr));
        try crypto.registerKey(key_id, key);
    }
};

/// @brief AES-GCM-GMAC Plugin (DDS:Crypto:AES-GCM-GMAC).
pub const AesGcmCryptography = struct {
    keys: std.AutoHashMapUnmanaged(CryptoKeyId, [32]u8),
    allocator: std.mem.Allocator,
    nonce_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),
    base_nonce: [4]u8,

    pub fn registerKey(self: *AesGcmCryptography, key_id: CryptoKeyId, key: [32]u8) !void {
        try self.keys.put(self.allocator, key_id, key);
    }

    pub fn init(allocator: std.mem.Allocator) !*CryptographyPlugin {
        const self = try allocator.create(AesGcmCryptography);
        errdefer allocator.destroy(self);
        var salt: [4]u8 = undefined;
        const ts = @as(u64, @bitCast(getNanoTimestamp()));
        @memcpy(&salt, std.mem.asBytes(&ts)[0..4]);
        self.* = .{
            .keys = .empty,
            .allocator = allocator,
            .base_nonce = salt,
        };

        const plugin = try allocator.create(CryptographyPlugin);
        plugin.* = .{
            .ptr = self,
            .encrypt_serialized_payload_fn = encryptSerializedPayloadImpl,
            .decrypt_serialized_payload_fn = decryptSerializedPayloadImpl,
        };
        return plugin;
    }

    pub fn deinit(plugin: *CryptographyPlugin, allocator: std.mem.Allocator) void {
        const self: *AesGcmCryptography = @ptrCast(@alignCast(plugin.ptr));
        self.keys.deinit(allocator);
        allocator.destroy(self);
        allocator.destroy(plugin);
    }

    fn encryptSerializedPayloadImpl(
        ptr: *anyopaque,
        payload: []const u8,
        key_id: CryptoKeyId,
        out_buffer: []u8,
    ) anyerror![]const u8 {
        const self: *AesGcmCryptography = @ptrCast(@alignCast(ptr));
        const key = self.keys.get(key_id) orelse return error.KeyNotFound;

        var nonce: [12]u8 = undefined;
        @memcpy(nonce[0..4], &self.base_nonce);
        const cnt = self.nonce_counter.fetchAdd(1, .monotonic);
        @memcpy(nonce[4..12], std.mem.asBytes(&cnt));

        var tag: [16]u8 = undefined;

        if (out_buffer.len < payload.len + nonce.len + tag.len) return error.BufferTooSmall;

        std.crypto.aead.aes_gcm.Aes256Gcm.encrypt(out_buffer[28 .. 28 + payload.len], &tag, payload, &[_]u8{}, nonce, key);

        @memcpy(out_buffer[0..12], &nonce);
        @memcpy(out_buffer[12..28], &tag);

        return out_buffer[0 .. 28 + payload.len];
    }

    fn decryptSerializedPayloadImpl(
        ptr: *anyopaque,
        secure_payload: []const u8,
        key_id: CryptoKeyId,
        out_buffer: []u8,
    ) anyerror![]const u8 {
        const self: *AesGcmCryptography = @ptrCast(@alignCast(ptr));
        const key = self.keys.get(key_id) orelse return error.KeyNotFound;

        if (secure_payload.len < 28) return error.BufferTooSmall;
        const nonce_bytes = secure_payload[0..12];
        const tag_bytes = secure_payload[12..28];
        const ciphertext = secure_payload[28..];

        var tag: [16]u8 = undefined;
        @memcpy(&tag, tag_bytes);
        var nonce: [12]u8 = undefined;
        @memcpy(&nonce, nonce_bytes);

        if (out_buffer.len < ciphertext.len) return error.BufferTooSmall;

        try std.crypto.aead.aes_gcm.Aes256Gcm.decrypt(out_buffer[0..ciphertext.len], ciphertext, tag, &[_]u8{}, nonce, key);
        return out_buffer[0..ciphertext.len];
    }
};

test "AesGcmCryptography encryption and decryption round-trip" {
    const crypto_plugin = try AesGcmCryptography.init(std.testing.allocator);
    defer AesGcmCryptography.deinit(crypto_plugin, std.testing.allocator);

    const key_id: CryptoKeyId = 101;
    const test_key: [32]u8 = @splat(0x42);
    try crypto_plugin.registerKey(key_id, test_key);

    const plaintext = "Top secret DDS message payload with high security!";
    var enc_buf: [256]u8 = undefined;
    const encrypted = try crypto_plugin.encryptSerializedPayload(plaintext, key_id, &enc_buf);

    // Encrypted payload should have 12-byte nonce + 16-byte tag + plaintext
    try std.testing.expectEqual(plaintext.len + 28, encrypted.len);
    try std.testing.expect(!std.mem.eql(u8, plaintext, encrypted[28..]));

    var dec_buf: [256]u8 = undefined;
    const decrypted = try crypto_plugin.decryptSerializedPayload(encrypted, key_id, &dec_buf);
    try std.testing.expectEqualStrings(plaintext, decrypted);

    // Corrupted tag should fail decryption with error.AuthenticationFailed
    var corrupted_buf: [256]u8 = undefined;
    @memcpy(corrupted_buf[0..encrypted.len], encrypted);
    corrupted_buf[15] ^= 0xFF; // Flip bit in tag
    try std.testing.expectError(error.AuthenticationFailed, crypto_plugin.decryptSerializedPayload(corrupted_buf[0..encrypted.len], key_id, &dec_buf));
}
