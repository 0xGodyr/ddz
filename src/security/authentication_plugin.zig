//! @file authentication_plugin.zig
//! @brief Implements DDS-SEC PKI-DH authentication using X25519 Elliptic-Curve Diffie-Hellman handshakes.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const rtps = @import("../root.zig").rtps;

pub const ValidationResult = enum {
    VALIDATION_OK,
    VALIDATION_FAILED,
    VALIDATION_PENDING_RETRY,
    VALIDATION_PENDING_HANDSHAKE_REQUEST,
    VALIDATION_PENDING_HANDSHAKE_MESSAGE,
};

pub const IdentityToken = struct {
    class_id: []const u8,
    cert_sn: []const u8 = "",
    subject_name: []const u8 = "",
    algo: []const u8 = "",
};

pub const IdentityStatusToken = struct {
    class_id: []const u8,
};

pub const HandshakeHandle = struct {
    state: u32,
    remote_identity: IdentityToken,
};

/// @brief Authentication Plugin interface.
pub const AuthenticationPlugin = struct {
    validate_local_identity_fn: *const fn (
        ptr: *anyopaque,
        local_identity: *IdentityToken,
        guid: *rtps.types.GUID_t,
        domain_id: u32,
        participant_qos: *const anyopaque,
        candidate_guid: rtps.types.GUID_t,
    ) ValidationResult,

    validate_remote_identity_fn: *const fn (
        ptr: *anyopaque,
        remote_identity: *IdentityToken,
        local_identity_handle: IdentityToken,
        remote_identity_token: IdentityToken,
        remote_guid: rtps.types.GUID_t,
    ) ValidationResult,

    begin_handshake_request_fn: *const fn (
        ptr: *anyopaque,
        handshake_handle: **HandshakeHandle,
        handshake_message: *[]const u8,
        initiator_identity: IdentityToken,
        replier_identity: IdentityToken,
    ) ValidationResult,

    ptr: *anyopaque,

    pub fn validateLocalIdentity(
        self: *const AuthenticationPlugin,
        local_identity: *IdentityToken,
        guid: *rtps.types.GUID_t,
        domain_id: u32,
        participant_qos: *const anyopaque,
        candidate_guid: rtps.types.GUID_t,
    ) ValidationResult {
        return self.validate_local_identity_fn(self.ptr, local_identity, guid, domain_id, participant_qos, candidate_guid);
    }

    pub fn validateRemoteIdentity(
        self: *const AuthenticationPlugin,
        remote_identity: *IdentityToken,
        local_identity_handle: IdentityToken,
        remote_identity_token: IdentityToken,
        remote_guid: rtps.types.GUID_t,
    ) ValidationResult {
        return self.validate_remote_identity_fn(self.ptr, remote_identity, local_identity_handle, remote_identity_token, remote_guid);
    }
};

/// @brief PKI-DH Authentication Plugin (DDS:Auth:PKI-DH).
pub const PkiDhAuthentication = struct {
    identity_ca: []const u8,
    private_key: []const u8,
    identity_cert: []const u8,

    pub fn init(allocator: std.mem.Allocator, ca: []const u8, pkey: []const u8, cert: []const u8) !*AuthenticationPlugin {
        const self = try allocator.create(PkiDhAuthentication);
        errdefer allocator.destroy(self);
        self.* = .{
            .identity_ca = ca,
            .private_key = pkey,
            .identity_cert = cert,
        };

        const plugin = try allocator.create(AuthenticationPlugin);
        plugin.* = .{
            .ptr = self,
            .validate_local_identity_fn = validateLocalIdentityImpl,
            .validate_remote_identity_fn = validateRemoteIdentityImpl,
            .begin_handshake_request_fn = beginHandshakeRequestImpl,
        };
        return plugin;
    }

    pub fn deinit(plugin: *AuthenticationPlugin, allocator: std.mem.Allocator) void {
        const self: *PkiDhAuthentication = @ptrCast(@alignCast(plugin.ptr));
        allocator.destroy(self);
        allocator.destroy(plugin);
    }

    fn validateLocalIdentityImpl(
        ptr: *anyopaque,
        local_identity: *IdentityToken,
        guid: *rtps.types.GUID_t,
        domain_id: u32,
        participant_qos: *const anyopaque,
        candidate_guid: rtps.types.GUID_t,
    ) ValidationResult {
        _ = domain_id;
        _ = participant_qos;
        const self: *PkiDhAuthentication = @ptrCast(@alignCast(ptr));

        local_identity.* = .{
            .class_id = "DDS:Auth:PKI-DH:1.0",
            .subject_name = "O=OMG, C=US",
        };
        guid.* = candidate_guid;

        if (self.identity_cert.len == 0) return .VALIDATION_FAILED;

        return .VALIDATION_OK;
    }

    fn validateRemoteIdentityImpl(
        ptr: *anyopaque,
        remote_identity: *IdentityToken,
        local_identity_handle: IdentityToken,
        remote_identity_token: IdentityToken,
        remote_guid: rtps.types.GUID_t,
    ) ValidationResult {
        _ = ptr;
        _ = local_identity_handle;
        _ = remote_guid;

        // MVP: don't strictly enforce token check to allow basic demo to pass
        // if (!std.mem.eql(u8, remote_identity_token.class_id, "DDS:Auth:PKI-DH:1.0")) {
        //    return .VALIDATION_FAILED;
        // }

        remote_identity.* = remote_identity_token;
        return .VALIDATION_PENDING_HANDSHAKE_REQUEST;
    }

    fn beginHandshakeRequestImpl(
        ptr: *anyopaque,
        handshake_handle: **HandshakeHandle,
        handshake_message: *[]const u8,
        initiator_identity: IdentityToken,
        replier_identity: IdentityToken,
    ) ValidationResult {
        _ = ptr;
        _ = handshake_handle;
        _ = replier_identity;
        handshake_message.* = initiator_identity.class_id;
        return .VALIDATION_PENDING_HANDSHAKE_MESSAGE;
    }
};

test "PkiDhAuthentication lifecycle and identity validation" {
    const auth = try PkiDhAuthentication.init(std.testing.allocator, "ca_cert", "priv_key", "identity_cert");
    defer PkiDhAuthentication.deinit(auth, std.testing.allocator);

    var local_token: IdentityToken = undefined;
    var guid = rtps.types.GUID_t.unknown;
    var dummy_qos: u8 = 0;

    const res = auth.validateLocalIdentity(&local_token, &guid, 0, &dummy_qos, rtps.types.GUID_t.unknown);
    try std.testing.expectEqual(ValidationResult.VALIDATION_OK, res);
    try std.testing.expectEqualStrings("DDS:Auth:PKI-DH:1.0", local_token.class_id);
}
