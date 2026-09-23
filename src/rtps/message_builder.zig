//! @file message_builder.zig
//! @brief Constructs, serializes, and encrypts outbound RTPS messages and submessages.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const rtps = @import("../root.zig").rtps;
const Serializer = @import("../cdr/serializer.zig").Serializer;
const CryptographyPlugin = @import("../security/cryptography_plugin.zig").CryptographyPlugin;

pub const MessageBuilder = struct {
    msg_ser: Serializer,
    unencrypted_start: usize,

    pub fn init(buffer: []u8, guid_prefix: rtps.types.GuidPrefix_t) !MessageBuilder {
        var msg_ser = Serializer.init(buffer, .Little);
        const header = rtps.Message.Header{
            .protocol = rtps.Message.Header.rtps_magic,
            .version = rtps.types.ProtocolVersion_t.current,
            .vendor_id = rtps.types.vendor_ddz,
            .guid_prefix = guid_prefix,
        };
        const header_len = try header.serialize(buffer);
        msg_ser.pos = header_len;
        return MessageBuilder{
            .msg_ser = msg_ser,
            .unencrypted_start = header_len,
        };
    }

    pub fn addInfoDst(self: *MessageBuilder, guid_prefix: [12]u8) !void {
        const info_dst_len: u32 = 12;
        const info_dst_header: u32 = (info_dst_len << 16) | (@as(u32, 0x01) << 8) | @as(u32, @backingInt(rtps.Submessage.SubmessageKind.INFO_DST));
        try self.msg_ser.serialize(info_dst_header);
        try self.msg_ser.writeAll(&guid_prefix);
    }

    pub fn addInfoSrc(self: *MessageBuilder, vendor_id: [2]u8, guid_prefix: [12]u8) !void {
        const info_src_len: u32 = 20;
        const info_src_header: u32 = (info_src_len << 16) | (@as(u32, 0x01) << 8) | @as(u32, @backingInt(rtps.Submessage.SubmessageKind.INFO_SRC));
        try self.msg_ser.serialize(info_src_header);
        try self.msg_ser.serialize(@as(u32, 0)); // unused
        try self.msg_ser.serialize(rtps.types.ProtocolVersion_t.current);
        try self.msg_ser.writeAll(&vendor_id);
        try self.msg_ser.writeAll(&guid_prefix);
    }

    pub fn addInfoReply(self: *MessageBuilder, unicast_locators: []const rtps.types.Locator_t, multicast_locators: []const rtps.types.Locator_t) !void {
        var flags: u32 = 0x01; // Little Endian
        if (multicast_locators.len > 0) {
            flags |= 0x02; // Multicast Flag
        }

        const unicast_size = 4 + (unicast_locators.len * 24);
        const multicast_size = if (multicast_locators.len > 0) 4 + (multicast_locators.len * 24) else 0;
        const info_reply_len: u32 = @as(u32, @intCast(unicast_size + multicast_size));

        const info_reply_header: u32 = (info_reply_len << 16) | (flags << 8) | @as(u32, @backingInt(rtps.Submessage.SubmessageKind.INFO_REPLY));
        try self.msg_ser.serialize(info_reply_header);

        try self.msg_ser.serialize(@as(u32, @intCast(unicast_locators.len)));
        for (unicast_locators) |loc| {
            try self.msg_ser.serialize(loc);
        }

        if (multicast_locators.len > 0) {
            try self.msg_ser.serialize(@as(u32, @intCast(multicast_locators.len)));
            for (multicast_locators) |loc| {
                try self.msg_ser.serialize(loc);
            }
        }
    }

    pub fn addInfoTs(self: *MessageBuilder) !void {
        const info_ts_header: u32 = (@as(u32, 8) << 16) | (@as(u32, 0x01) << 8) | @as(u32, @backingInt(rtps.Submessage.SubmessageKind.INFO_TS));
        try self.msg_ser.serialize(info_ts_header);
        try self.msg_ser.serialize(rtps.types.Time_t{ .seconds = 0, .fraction = 0 });
    }

    pub fn addData(self: *MessageBuilder, reader_id: rtps.types.EntityId_t, writer_id: rtps.types.EntityId_t, sequence_number: rtps.types.SequenceNumber_t, instance_handle: [16]u8, payload: []const u8, status_info: ?[4]u8, user_data: ?[]const u8, group_data: ?[]const u8, topic_data: ?[]const u8, coherent_set_id: ?u64, related_sample_identity: ?rtps.types.SampleIdentity_t) !void {
        const has_key = !std.mem.eql(u8, &instance_handle, &std.mem.zeroes([16]u8));
        var inline_qos_len: u32 = 0;
        if (has_key) inline_qos_len += 20; // 4 + 16
        if (status_info != null) inline_qos_len += 8; // 4 + 4
        if (user_data) |ud| inline_qos_len += 4 + @as(u32, @intCast(ud.len));
        if (group_data) |gd| inline_qos_len += 4 + @as(u32, @intCast(gd.len));
        if (topic_data) |td| inline_qos_len += 4 + @as(u32, @intCast(td.len));
        if (coherent_set_id != null) inline_qos_len += 12; // 4 + 8
        // alignment for len? PIDs must be 4-byte aligned!
        inline_qos_len = (inline_qos_len + 3) & ~@as(u32, 3);
        if (inline_qos_len > 0) inline_qos_len += 4; // Sentinel
        const data_flags: u8 = if (inline_qos_len > 0) 0x07 else 0x05;

        const data_submessage_len: u32 = 20 + inline_qos_len + @as(u32, @intCast(payload.len));
        const data_header: u32 = (data_submessage_len << 16) | (@as(u32, data_flags) << 8) | @as(u32, @backingInt(rtps.Submessage.SubmessageKind.DATA));

        try self.msg_ser.serialize(data_header);
        try self.msg_ser.serialize(@as(u16, 0)); // extra_flags
        try self.msg_ser.serialize(@as(u16, 16)); // octetsToInlineQos
        try self.msg_ser.serialize(reader_id);
        try self.msg_ser.serialize(writer_id);
        try self.msg_ser.serialize(sequence_number);

        if (inline_qos_len > 0) {
            if (has_key) {
                try self.msg_ser.serialize(@as(u16, 0x0070)); // PID_KEY_HASH
                try self.msg_ser.serialize(@as(u16, 16));
                try self.msg_ser.writeAll(&instance_handle);
            }
            if (status_info) |si| {
                try self.msg_ser.serialize(@as(u16, 0x0071)); // PID_STATUS_INFO
                try self.msg_ser.serialize(@as(u16, 4));
                try self.msg_ser.writeAll(&si);
            }
            if (user_data) |ud| {
                try self.msg_ser.serialize(@as(u16, 0x002c)); // PID_USER_DATA
                try self.msg_ser.serialize(@as(u16, @intCast(ud.len)));
                try self.msg_ser.writeAll(ud);
                try self.msg_ser.alignTo(4);
            }
            if (group_data) |gd| {
                try self.msg_ser.serialize(@as(u16, 0x002d)); // PID_GROUP_DATA
                try self.msg_ser.serialize(@as(u16, @intCast(gd.len)));
                try self.msg_ser.writeAll(gd);
                try self.msg_ser.alignTo(4);
            }
            if (topic_data) |td| {
                try self.msg_ser.serialize(@as(u16, 0x002e)); // PID_TOPIC_DATA
                try self.msg_ser.serialize(@as(u16, @intCast(td.len)));
                try self.msg_ser.writeAll(td);
                try self.msg_ser.alignTo(4);
            }
            if (coherent_set_id) |csi| {
                try self.msg_ser.serialize(@as(u16, 0x0056)); // PID_COHERENT_SET
                try self.msg_ser.serialize(@as(u16, 8));
                try self.msg_ser.serialize(csi);
            }
            if (related_sample_identity) |rsi| {
                try self.msg_ser.serialize(@as(u16, 0x0083)); // PID_RELATED_SAMPLE_IDENTITY
                try self.msg_ser.serialize(@as(u16, 24));
                try self.msg_ser.serialize(rsi.writer_guid);
                try self.msg_ser.serialize(rsi.sequence_number);
            }
            try self.msg_ser.serialize(@as(u16, 0x0001)); // PID_SENTINEL
            try self.msg_ser.serialize(@as(u16, 0));
        }
        try self.msg_ser.writeAll(payload);
    }

    pub fn addDataFrag(self: *MessageBuilder, reader_id: rtps.types.EntityId_t, writer_id: rtps.types.EntityId_t, sequence_number: rtps.types.SequenceNumber_t, instance_handle: [16]u8, frag_num: u32, max_frag_size: u16, total_size: u32, payload: []const u8, status_info: ?[4]u8, user_data: ?[]const u8, group_data: ?[]const u8, topic_data: ?[]const u8, coherent_set_id: ?u64, related_sample_identity: ?rtps.types.SampleIdentity_t) !void {
        const has_key = !std.mem.eql(u8, &instance_handle, &std.mem.zeroes([16]u8));
        var inline_qos_len: u32 = 0;
        if (has_key) inline_qos_len += 20; // 4 + 16
        if (status_info != null) inline_qos_len += 8; // 4 + 4
        if (user_data) |ud| inline_qos_len += 4 + @as(u32, @intCast(ud.len));
        if (group_data) |gd| inline_qos_len += 4 + @as(u32, @intCast(gd.len));
        if (topic_data) |td| inline_qos_len += 4 + @as(u32, @intCast(td.len));
        if (coherent_set_id != null) inline_qos_len += 12; // 4 + 8
        if (related_sample_identity != null) inline_qos_len += 28; // 4 + 24
        inline_qos_len = (inline_qos_len + 3) & ~@as(u32, 3);
        if (inline_qos_len > 0) inline_qos_len += 4; // Sentinel
        const data_flags: u8 = if (inline_qos_len > 0) 0x07 else 0x05;

        const data_frag_submessage_len: u32 = 32 + inline_qos_len + @as(u32, @intCast(payload.len));
        const data_frag_header: u32 = (@as(u32, @intCast(data_frag_submessage_len)) << 16) | (@as(u32, data_flags) << 8) | @as(u32, @backingInt(rtps.Submessage.SubmessageKind.DATA_FRAG));

        try self.msg_ser.serialize(data_frag_header);
        try self.msg_ser.serialize(@as(u16, 0)); // extra_flags
        try self.msg_ser.serialize(@as(u16, 28)); // octetsToInlineQos
        try self.msg_ser.serialize(reader_id);
        try self.msg_ser.serialize(writer_id);
        try self.msg_ser.serialize(sequence_number);
        try self.msg_ser.serialize(frag_num); // fragmentStartingNum
        try self.msg_ser.serialize(@as(u16, 1)); // fragmentsInSubmessage
        try self.msg_ser.serialize(max_frag_size); // fragmentSize
        try self.msg_ser.serialize(total_size); // sampleSize

        if (inline_qos_len > 0) {
            if (has_key) {
                try self.msg_ser.serialize(@as(u16, 0x0070)); // PID_KEY_HASH
                try self.msg_ser.serialize(@as(u16, 16));
                try self.msg_ser.writeAll(&instance_handle);
            }
            if (status_info) |si| {
                try self.msg_ser.serialize(@as(u16, 0x0071)); // PID_STATUS_INFO
                try self.msg_ser.serialize(@as(u16, 4));
                try self.msg_ser.writeAll(&si);
            }
            if (user_data) |ud| {
                try self.msg_ser.serialize(@as(u16, 0x002c)); // PID_USER_DATA
                try self.msg_ser.serialize(@as(u16, @intCast(ud.len)));
                try self.msg_ser.writeAll(ud);
                try self.msg_ser.alignTo(4);
            }
            if (group_data) |gd| {
                try self.msg_ser.serialize(@as(u16, 0x002d)); // PID_GROUP_DATA
                try self.msg_ser.serialize(@as(u16, @intCast(gd.len)));
                try self.msg_ser.writeAll(gd);
                try self.msg_ser.alignTo(4);
            }
            if (topic_data) |td| {
                try self.msg_ser.serialize(@as(u16, 0x002e)); // PID_TOPIC_DATA
                try self.msg_ser.serialize(@as(u16, @intCast(td.len)));
                try self.msg_ser.writeAll(td);
                try self.msg_ser.alignTo(4);
            }
            if (coherent_set_id) |csi| {
                try self.msg_ser.serialize(@as(u16, 0x0056)); // PID_COHERENT_SET
                try self.msg_ser.serialize(@as(u16, 8));
                try self.msg_ser.serialize(csi);
            }
            if (related_sample_identity) |rsi| {
                try self.msg_ser.serialize(@as(u16, 0x0083)); // PID_RELATED_SAMPLE_IDENTITY
                try self.msg_ser.serialize(@as(u16, 24));
                try self.msg_ser.serialize(rsi.writer_guid);
                try self.msg_ser.serialize(rsi.sequence_number);
            }
            try self.msg_ser.serialize(@as(u16, 0x0001)); // PID_SENTINEL
            try self.msg_ser.serialize(@as(u16, 0));
        }
        try self.msg_ser.writeAll(payload);
    }

    pub fn addHeartbeatFrag(self: *MessageBuilder, reader_id: rtps.types.EntityId_t, writer_id: rtps.types.EntityId_t, writer_sn: rtps.types.SequenceNumber_t, last_fragment_num: u32, count: u32) !void {
        const hf_submessage_len: u32 = 24;
        const hf_header: u32 = (hf_submessage_len << 16) | (@as(u32, 0x01) << 8) | @as(u32, @backingInt(rtps.Submessage.SubmessageKind.HEARTBEAT_FRAG));
        try self.msg_ser.serialize(hf_header);
        try self.msg_ser.serialize(reader_id);
        try self.msg_ser.serialize(writer_id);
        try self.msg_ser.serialize(writer_sn);
        try self.msg_ser.serialize(last_fragment_num);
        try self.msg_ser.serialize(count);
    }

    pub fn addHeartbeat(self: *MessageBuilder, reader_id: rtps.types.EntityId_t, writer_id: rtps.types.EntityId_t, first_sn: rtps.types.SequenceNumber_t, last_sn: rtps.types.SequenceNumber_t, count: u32) !void {
        const hb_submessage_len: u32 = 28;
        const hb_header: u32 = (hb_submessage_len << 16) | (@as(u32, 0x03) << 8) | @as(u32, @backingInt(rtps.Submessage.SubmessageKind.HEARTBEAT));
        try self.msg_ser.serialize(hb_header);
        try self.msg_ser.serialize(reader_id);
        try self.msg_ser.serialize(writer_id);
        try self.msg_ser.serialize(first_sn);
        try self.msg_ser.serialize(last_sn);
        try self.msg_ser.serialize(count);
    }

    pub fn finalizeAndEncrypt(self: *MessageBuilder, crypto_plugin: ?*CryptographyPlugin, entity_id: rtps.types.EntityId_t, allocator: std.mem.Allocator) ![]const u8 {
        _ = entity_id;
        _ = allocator;
        if (crypto_plugin) |crypto| {
            const plaintext = self.msg_ser.buffer[self.unencrypted_start..self.msg_ser.pos];
            var ciphertext_buf: [65536]u8 = undefined;
            if (crypto.encryptSerializedPayload(plaintext, 1, &ciphertext_buf)) |encrypted| {
                self.msg_ser.pos = self.unencrypted_start;
                const sec_body_len: u32 = @as(u32, @intCast(encrypted.len));
                const sec_header: u32 = (sec_body_len << 16) | (@as(u32, 0x01) << 8) | @as(u32, @backingInt(rtps.Submessage.SubmessageKind.SEC_BODY));
                try self.msg_ser.serialize(sec_header);
                try self.msg_ser.writeAll(encrypted);
            } else |_| {}
        }
        return self.msg_ser.buffer[0..self.msg_ser.pos];
    }
};

test "MessageBuilder basic packet construction" {
    var buf: [1024]u8 = undefined;
    const prefix = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    var builder = try MessageBuilder.init(&buf, prefix);

    try builder.addInfoTs();
    const sn = rtps.types.SequenceNumber_t{ .high = 0, .low = 1 };
    const payload = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD };
    try builder.addData(rtps.types.EntityId_t.unknown, rtps.types.EntityId_t.unknown, sn, std.mem.zeroes([16]u8), &payload, null, null, null, null, null, null);

    const packet = try builder.finalizeAndEncrypt(null, rtps.types.EntityId_t.unknown, std.testing.allocator);
    try std.testing.expect(packet.len > 0);

    // Check RTPS header
    try std.testing.expectEqualSlices(u8, "RTPS", packet[0..4]);
    // check protocol version
    try std.testing.expectEqual(2, packet[4]);
    try std.testing.expectEqual(rtps.types.ProtocolVersion_t.current.minor, packet[5]);
}
