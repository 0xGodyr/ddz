//! @file json.zig
//! @brief Standardized DDS-JSON payload serialization and deserialization engine.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");

pub const JsonSerializer = @import("json_serializer.zig").JsonSerializer;
pub const JsonDeserializer = @import("json_deserializer.zig").JsonDeserializer;
pub const ENCAPSULATION_HEADER_JSON = JsonSerializer.ENCAPSULATION_HEADER_JSON;

/// Convenience wrappers
pub const serialize = JsonSerializer.serialize;
pub const serializeWire = JsonSerializer.serializeWire;
pub const serializeToBuf = JsonSerializer.serializeToBuf;
pub const serializeWireToBuf = JsonSerializer.serializeWireToBuf;
pub const stringify = JsonSerializer.stringify;

pub const deserialize = JsonDeserializer.deserialize;
pub const deserializeLeaky = JsonDeserializer.deserializeLeaky;
pub const hasWireHeader = JsonDeserializer.hasWireHeader;
pub const stripWireHeader = JsonDeserializer.stripWireHeader;

test "DDS-JSON serialization & deserialization primitives" {
    const PrimitiveData = struct {
        id: u32,
        count: i64,
        ratio: f32,
        active: bool,
    };

    const original = PrimitiveData{
        .id = 42,
        .count = -123456789,
        .ratio = 3.14,
        .active = true,
    };

    const payload = try serialize(std.testing.allocator, original, .{});
    defer std.testing.allocator.free(payload);

    try std.testing.expect(!hasWireHeader(payload));

    const parsed = try deserialize(PrimitiveData, std.testing.allocator, payload, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(original.id, parsed.value.id);
    try std.testing.expectEqual(original.count, parsed.value.count);
    try std.testing.expectApproxEqAbs(original.ratio, parsed.value.ratio, 0.001);
    try std.testing.expectEqual(original.active, parsed.value.active);
}

test "DDS-JSON serialization & deserialization enums and optionals" {
    const Severity = enum {
        info,
        warning,
        critical,
    };

    const AlertData = struct {
        level: Severity,
        code: ?u16,
        description: ?[]const u8,
    };

    const alert1 = AlertData{
        .level = .critical,
        .code = 500,
        .description = "Internal service failure",
    };

    const json_str1 = try serialize(std.testing.allocator, alert1, .{});
    defer std.testing.allocator.free(json_str1);

    const parsed1 = try deserialize(AlertData, std.testing.allocator, json_str1, .{});
    defer parsed1.deinit();

    try std.testing.expectEqual(Severity.critical, parsed1.value.level);
    try std.testing.expectEqual(@as(?u16, 500), parsed1.value.code);
    try std.testing.expectEqualStrings("Internal service failure", parsed1.value.description.?);

    // Test with null fields
    const alert2 = AlertData{
        .level = .info,
        .code = null,
        .description = null,
    };

    const json_str2 = try serialize(std.testing.allocator, alert2, .{});
    defer std.testing.allocator.free(json_str2);

    const parsed2 = try deserialize(AlertData, std.testing.allocator, json_str2, .{});
    defer parsed2.deinit();

    try std.testing.expectEqual(Severity.info, parsed2.value.level);
    try std.testing.expectEqual(@as(?u16, null), parsed2.value.code);
    try std.testing.expectEqual(@as(?[]const u8, null), parsed2.value.description);
}

test "DDS-JSON wire encapsulation header roundtrip" {
    const SensorPacket = struct {
        sensor_id: u32,
        reading: f64,
        location: []const u8,
    };

    const packet = SensorPacket{
        .sensor_id = 9999,
        .reading = 42.0001,
        .location = "Turbine_Zone_A",
    };

    const wire_payload = try serializeWire(std.testing.allocator, packet, .{});
    defer std.testing.allocator.free(wire_payload);

    try std.testing.expect(hasWireHeader(wire_payload));
    try std.testing.expectEqualSlices(u8, &ENCAPSULATION_HEADER_JSON, wire_payload[0..4]);

    const stripped = stripWireHeader(wire_payload);
    try std.testing.expect(stripped.len == wire_payload.len - 4);
    try std.testing.expect(stripped[0] == '{');

    // Deserializing directly from the wire payload (with header) should auto-strip header
    const parsed = try deserialize(SensorPacket, std.testing.allocator, wire_payload, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(packet.sensor_id, parsed.value.sensor_id);
    try std.testing.expectApproxEqAbs(packet.reading, parsed.value.reading, 0.0001);
    try std.testing.expectEqualStrings(packet.location, parsed.value.location);
}

test "DDS-JSON zero-allocation serializeToBuf and serializeWireToBuf" {
    const StatusSample = struct {
        healthy: bool,
        uptime_sec: u64,
    };

    const sample = StatusSample{
        .healthy = true,
        .uptime_sec = 86400,
    };

    // Buffer serialize without header
    var buf: [128]u8 = undefined;
    const json_str = try serializeToBuf(&buf, sample);
    try std.testing.expect(!hasWireHeader(json_str));
    try std.testing.expectEqualStrings("{\"healthy\":true,\"uptime_sec\":86400}", json_str);

    // Buffer serialize with wire header
    var wire_buf: [128]u8 = undefined;
    const wire_bytes = try serializeWireToBuf(&wire_buf, sample);
    try std.testing.expect(hasWireHeader(wire_bytes));
    try std.testing.expectEqualSlices(u8, &ENCAPSULATION_HEADER_JSON, wire_bytes[0..4]);
    try std.testing.expectEqualStrings("{\"healthy\":true,\"uptime_sec\":86400}", wire_bytes[4..]);

    // Parse back
    const parsed = try deserialize(StatusSample, std.testing.allocator, wire_bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(true, parsed.value.healthy);
    try std.testing.expectEqual(@as(u64, 86400), parsed.value.uptime_sec);
}

test "DDS-JSON nested structs and arrays" {
    const Vector3 = struct {
        x: f32,
        y: f32,
        z: f32,
    };

    const Trajectory = struct {
        frame_id: []const u8,
        points: [3]Vector3,
    };

    const traj = Trajectory{
        .frame_id = "world",
        .points = .{
            .{ .x = 0.0, .y = 0.0, .z = 0.0 },
            .{ .x = 1.0, .y = 2.0, .z = 3.0 },
            .{ .x = 4.0, .y = 5.0, .z = 6.0 },
        },
    };

    const wire = try serializeWire(std.testing.allocator, traj, .{});
    defer std.testing.allocator.free(wire);

    const parsed = try deserialize(Trajectory, std.testing.allocator, wire, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("world", parsed.value.frame_id);
    try std.testing.expectEqual(@as(f32, 1.0), parsed.value.points[1].x);
    try std.testing.expectEqual(@as(f32, 5.0), parsed.value.points[2].y);
}

test "DDS-JSON error handling for invalid payloads" {
    const Simple = struct {
        id: u32,
    };

    // Invalid JSON text
    const invalid_json = "not a valid json";
    const result = deserialize(Simple, std.testing.allocator, invalid_json, .{});
    try std.testing.expectError(error.SyntaxError, result);

    // Header too small for buffer
    var tiny_buf: [2]u8 = undefined;
    const buf_result = serializeWireToBuf(&tiny_buf, Simple{ .id = 1 });
    try std.testing.expectError(error.NoSpaceLeft, buf_result);
}
