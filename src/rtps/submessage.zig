//! @file submessage.zig
//! @brief Parsers and definitions for RTPS submessages (DATA, HEARTBEAT, ACKNACK, INFO_DST, etc.).
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const serializer = @import("../cdr/serializer.zig");
const Serializer = serializer.Serializer;
const Endianness = serializer.Endianness;
const Deserializer = @import("../cdr/deserializer.zig").Deserializer;

/// @brief Submessage kind structure.
pub const SubmessageKind = enum(u8) {
    PAD = 0x01,
    ACKNACK = 0x06,
    HEARTBEAT = 0x07,
    GAP = 0x08,
    INFO_TS = 0x09,
    INFO_SRC = 0x0c,
    INFO_REPLY_IP4 = 0x0d,
    INFO_DST = 0x0e,
    INFO_REPLY = 0x0f,
    NACK_FRAG = 0x12,
    HEARTBEAT_FRAG = 0x13,
    DATA = 0x15,
    DATA_FRAG = 0x16,
    SEC_BODY = 0x30,
    SEC_PREFIX = 0x31,
    SEC_POSTFIX = 0x32,
    INFO_SHM = 0x40,
    _,
};

/// @brief Submessage header structure.
pub const SubmessageHeader = packed struct {
    submessage_id: u8,
    flags: u8,
    submessage_length: u16,
};

/// @brief Submessage structure.
pub const Submessage = union(SubmessageKind) {
    PAD: void,
    ACKNACK: AckNack,
    HEARTBEAT: Heartbeat,
    GAP: void,
    INFO_TS: InfoTimestamp,
    INFO_SRC: InfoSource,
    INFO_REPLY_IP4: void,
    INFO_DST: InfoDestination,
    INFO_REPLY: InfoReply,
    NACK_FRAG: NackFrag,
    HEARTBEAT_FRAG: HeartbeatFrag,
    DATA: Data,
    DATA_FRAG: DataFrag,
    SEC_BODY: SecBody,
    SEC_PREFIX: void,
    SEC_POSTFIX: void,
    INFO_SHM: InfoShm,
};

/// @brief Info destination structure.
pub const InfoDestination = struct {
    header: SubmessageHeader,
    guid_prefix: [12]u8,
};

/// @brief Info source structure.
pub const InfoSource = struct {
    header: SubmessageHeader,
    unused: u32,
    version: types.ProtocolVersion_t,
    vendor_id: [2]u8,
    guid_prefix: [12]u8,
};

/// @brief Info reply structure.
pub const InfoReply = struct {
    header: SubmessageHeader,
    unicast_locator_list: []const types.Locator_t,
    multicast_locator_list: []const types.Locator_t,
};

/// @brief Info shm structure.
pub const InfoShm = struct {
    header: SubmessageHeader,
    segment_name: [32]u8,
    offset: u32,
    length: u32,
};

/// @brief Sec body structure.
pub const SecBody = struct {
    header: SubmessageHeader,
    crypto_payload: []const u8,
};

/// @brief Info timestamp structure.
pub const InfoTimestamp = struct {
    header: SubmessageHeader,
    timestamp: types.Time_t,
};

/// @brief Heartbeat structure.
pub const Heartbeat = struct {
    header: SubmessageHeader,
    reader_id: types.EntityId_t,
    writer_id: types.EntityId_t,
    first_sn: types.SequenceNumber_t,
    last_sn: types.SequenceNumber_t,
    count: types.Count_t,
};

/// @brief Ack nack structure.
pub const AckNack = struct {
    header: SubmessageHeader,
    reader_id: types.EntityId_t,
    writer_id: types.EntityId_t,
    reader_sn_state: types.SequenceNumberSet,
    count: types.Count_t,
};

/// @brief Data structure.
pub const Data = struct {
    header: SubmessageHeader,
    extra_flags: u16,
    octets_to_inline_qos: u16,
    reader_id: types.EntityId_t,
    writer_id: types.EntityId_t,
    writer_sn: types.SequenceNumber_t,
    instance_handle: ?[16]u8 = null,
    status_info: ?[4]u8 = null,
    // inline_qos and serialized_payload will be slices into the original buffer to avoid allocation
    serialized_payload: []const u8,
    coherent_set_id: ?u64 = null,
    related_sample_identity: ?types.SampleIdentity_t = null,
    user_data: ?[]const u8 = null,
    group_data: ?[]const u8 = null,
    topic_data: ?[]const u8 = null,
};

/// @brief Data frag structure.
pub const DataFrag = struct {
    header: SubmessageHeader,
    extra_flags: u16,
    octets_to_inline_qos: u16,
    reader_id: types.EntityId_t,
    writer_id: types.EntityId_t,
    writer_sn: types.SequenceNumber_t,
    fragment_starting_num: u32,
    fragments_in_submessage: u16,
    fragment_size: u16,
    sample_size: u32,
    serialized_payload: []const u8,
    coherent_set_id: ?u64 = null,
    related_sample_identity: ?types.SampleIdentity_t = null,
};

/// @brief Submessage parser structure.
pub const SubmessageParser = struct {
    /// @brief Parse header.
    pub fn parseHeader(buffer: []const u8) !SubmessageHeader {
        if (buffer.len < @sizeOf(SubmessageHeader)) return error.BufferTooSmall;

        var header: SubmessageHeader = undefined;
        @memcpy(std.mem.asBytes(&header), buffer[0..@sizeOf(SubmessageHeader)]);

        // Handle endianness flag (bit 0 of flags). 0 = Big, 1 = Little
        const is_little_endian = (header.flags & 0x01) != 0;

        if (is_little_endian and builtin_endian == .big) {
            header.submessage_length = @byteSwap(header.submessage_length);
        } else if (!is_little_endian and builtin_endian == .little) {
            header.submessage_length = @byteSwap(header.submessage_length);
        }

        return header;
    }

    /// @brief Parse.
    pub fn parse(buffer: []const u8) !Submessage {
        const header = try parseHeader(buffer);
        if (header.submessage_length > 0 and buffer.len < @sizeOf(SubmessageHeader) + header.submessage_length) {
            return error.BufferTooSmall;
        }

        const is_little_endian = (header.flags & 0x01) != 0;
        const endianness = if (is_little_endian) Endianness.Little else Endianness.Big;

        const kind: SubmessageKind = std.enums.fromInt(SubmessageKind, header.submessage_id) orelse return error.UnsupportedSubmessage;

        return switch (kind) {
            .HEARTBEAT => Submessage{ .HEARTBEAT = try parseHeartbeat(header, buffer, endianness) },
            .ACKNACK => Submessage{ .ACKNACK = try parseAckNack(header, buffer, endianness) },
            .DATA => Submessage{ .DATA = try parseData(header, buffer, endianness) },
            .DATA_FRAG => Submessage{ .DATA_FRAG = try parseDataFrag(header, buffer, endianness) },
            .NACK_FRAG => Submessage{ .NACK_FRAG = try parseNackFrag(header, buffer, endianness) },
            .HEARTBEAT_FRAG => Submessage{ .HEARTBEAT_FRAG = try parseHeartbeatFrag(header, buffer, endianness) },
            .INFO_TS => Submessage{ .INFO_TS = try parseInfoTimestamp(header, buffer, endianness) },
            .INFO_DST => Submessage{ .INFO_DST = try parseInfoDst(header, buffer, endianness) },
            .INFO_SRC => Submessage{ .INFO_SRC = try parseInfoSrc(header, buffer, endianness) },
            .INFO_REPLY => Submessage{ .INFO_REPLY = try parseInfoReply(header, buffer, endianness) },
            .INFO_SHM => Submessage{ .INFO_SHM = try parseInfoShm(header, buffer, endianness) },
            .PAD => Submessage{ .PAD = undefined },
            .SEC_BODY => {
                const sub_len = if (header.submessage_length == 0) buffer.len - @sizeOf(SubmessageHeader) else header.submessage_length;
                const payload_end = @sizeOf(SubmessageHeader) + sub_len;
                if (payload_end > buffer.len) return error.BufferTooSmall;
                return Submessage{ .SEC_BODY = .{
                    .header = header,
                    .crypto_payload = buffer[@sizeOf(SubmessageHeader)..payload_end],
                } };
            },
            else => error.UnsupportedSubmessage,
        };
    }

    fn parseHeartbeat(header: SubmessageHeader, buffer: []const u8, endianness: Endianness) !Heartbeat {
        var des = Deserializer.init(buffer[@sizeOf(SubmessageHeader)..], endianness);
        const reader_id = try des.deserialize(types.EntityId_t);
        const writer_id = try des.deserialize(types.EntityId_t);
        const first_sn = try des.deserialize(types.SequenceNumber_t);
        const last_sn = try des.deserialize(types.SequenceNumber_t);
        const count = try des.deserialize(types.Count_t);
        return Heartbeat{
            .header = header,
            .reader_id = reader_id,
            .writer_id = writer_id,
            .first_sn = first_sn,
            .last_sn = last_sn,
            .count = count,
        };
    }

    fn parseAckNack(header: SubmessageHeader, buffer: []const u8, endianness: Endianness) !AckNack {
        var des = Deserializer.init(buffer[@sizeOf(SubmessageHeader)..], endianness);
        const reader_id = try des.deserialize(types.EntityId_t);
        const writer_id = try des.deserialize(types.EntityId_t);
        const reader_sn_state_base = try des.deserialize(types.SequenceNumber_t);
        const num_bits = try des.deserialize(u32);

        var sn_set = types.SequenceNumberSet{
            .base = reader_sn_state_base,
            .num_bits = num_bits,
        };
        const num_longs = (num_bits + 31) / 32;
        var i: usize = 0;
        while (i < num_longs and i < 8) : (i += 1) {
            sn_set.bitmap[i] = try des.deserialize(u32);
        }
        const count = try des.deserialize(types.Count_t);
        return AckNack{
            .header = header,
            .reader_id = reader_id,
            .writer_id = writer_id,
            .reader_sn_state = sn_set,
            .count = count,
        };
    }

    fn parseData(header: SubmessageHeader, buffer: []const u8, endianness: Endianness) !Data {
        var des = Deserializer.init(buffer[@sizeOf(SubmessageHeader)..], endianness);
        const extra_flags = try des.deserialize(u16);
        const octets_to_inline_qos = try des.deserialize(u16);
        const reader_id = try des.deserialize(types.EntityId_t);
        const writer_id = try des.deserialize(types.EntityId_t);
        const writer_sn = try des.deserialize(types.SequenceNumber_t);

        const inline_qos_flag = (header.flags & 0x02) != 0;
        const data_flag = (header.flags & 0x04) != 0;

        var instance_handle: ?[16]u8 = null;
        var status_info: ?[4]u8 = null;
        var user_data: ?[]const u8 = null;
        var group_data: ?[]const u8 = null;
        var topic_data: ?[]const u8 = null;
        var coherent_set_id: ?u64 = null;
        var related_sample_identity: ?types.SampleIdentity_t = null;
        var payload_start: usize = @sizeOf(SubmessageHeader) + 4 + octets_to_inline_qos;

        if (inline_qos_flag) {
            if (payload_start < buffer.len) {
                var qos_des = Deserializer.init(buffer[payload_start..], endianness);
                while (qos_des.pos + 4 <= qos_des.buffer.len) {
                    const pid = qos_des.deserialize(u16) catch break;
                    const plen = qos_des.deserialize(u16) catch break;
                    if (pid == 0x0001) { // PID_SENTINEL
                        payload_start += @intCast(qos_des.pos);
                        break;
                    }
                    if (qos_des.pos + plen > qos_des.buffer.len) break;
                    if (pid == 0x0070) { // PID_KEY_HASH
                        if (plen == 16) {
                            instance_handle = qos_des.deserialize([16]u8) catch null;
                        } else {
                            qos_des.pos += plen;
                        }
                    } else if (pid == 0x0056) { // PID_COHERENT_SET
                        if (plen == 8) {
                            coherent_set_id = qos_des.deserialize(u64) catch null;
                        } else {
                            qos_des.pos += plen;
                        }
                    } else if (pid == 0x002c) { // PID_USER_DATA
                        if (plen > 0) {
                            user_data = qos_des.buffer[qos_des.pos .. qos_des.pos + plen];
                        }
                        qos_des.pos += plen;
                    } else if (pid == 0x002d) { // PID_GROUP_DATA
                        if (plen > 0) {
                            group_data = qos_des.buffer[qos_des.pos .. qos_des.pos + plen];
                        }
                        qos_des.pos += plen;
                    } else if (pid == 0x002e) { // PID_TOPIC_DATA
                        if (plen > 0) {
                            topic_data = qos_des.buffer[qos_des.pos .. qos_des.pos + plen];
                        }
                        qos_des.pos += plen;
                    } else if (pid == 0x0083) { // PID_RELATED_SAMPLE_IDENTITY
                        if (plen == 24) { // GUID_t (16) + SequenceNumber_t (8) = 24 bytes
                            const rsi_guid = qos_des.deserialize(types.GUID_t) catch null;
                            const rsi_sn = qos_des.deserialize(types.SequenceNumber_t) catch null;
                            if (rsi_guid != null and rsi_sn != null) {
                                related_sample_identity = types.SampleIdentity_t{
                                    .writer_guid = rsi_guid.?,
                                    .sequence_number = rsi_sn.?,
                                };
                            }
                        } else {
                            qos_des.pos += plen;
                        }
                    } else if (pid == 0x0071) { // PID_STATUS_INFO
                        if (plen == 4) {
                            status_info = qos_des.deserialize([4]u8) catch null;
                        } else {
                            qos_des.pos += plen;
                        }
                    } else {
                        qos_des.pos += plen;
                    }
                }
            }
        }

        var payload: []const u8 = &[_]u8{};
        if (data_flag) {
            const sub_len = if (header.submessage_length == 0) buffer.len - @sizeOf(SubmessageHeader) else header.submessage_length;
            const end = @sizeOf(SubmessageHeader) + sub_len;
            if (payload_start <= end and end <= buffer.len) {
                payload = buffer[payload_start..end];
            }
        }

        return Data{
            .header = header,
            .extra_flags = extra_flags,
            .octets_to_inline_qos = octets_to_inline_qos,
            .reader_id = reader_id,
            .writer_id = writer_id,
            .writer_sn = writer_sn,
            .instance_handle = instance_handle,
            .status_info = status_info,
            .user_data = user_data,
            .group_data = group_data,
            .topic_data = topic_data,
            .coherent_set_id = coherent_set_id,
            .serialized_payload = payload,
            .related_sample_identity = related_sample_identity,
        };
    }

    fn parseInfoDst(header: SubmessageHeader, buffer: []const u8, endianness: Endianness) !InfoDestination {
        var des = Deserializer.init(buffer[@sizeOf(SubmessageHeader)..], endianness);
        const guid_prefix = try des.deserialize([12]u8);
        return InfoDestination{ .header = header, .guid_prefix = guid_prefix };
    }

    fn parseInfoSrc(header: SubmessageHeader, buffer: []const u8, endianness: Endianness) !InfoSource {
        var des = Deserializer.init(buffer[@sizeOf(SubmessageHeader)..], endianness);
        const unused = try des.deserialize(u32);
        const version = try des.deserialize(types.ProtocolVersion_t);
        const vendor_id = try des.deserialize([2]u8);
        const guid_prefix = try des.deserialize([12]u8);
        return InfoSource{ .header = header, .unused = unused, .version = version, .vendor_id = vendor_id, .guid_prefix = guid_prefix };
    }

    fn parseInfoReply(header: SubmessageHeader, buffer: []const u8, endianness: Endianness) !InfoReply {
        var des = Deserializer.init(buffer[@sizeOf(SubmessageHeader)..], endianness);

        const num_unicast = try des.deserialize(u32);
        const unicast_list = if (num_unicast > 0) try des.readAll(num_unicast * @sizeOf(types.Locator_t)) else &[_]u8{};
        if (num_unicast > 0 and !std.mem.isAligned(@intFromPtr(unicast_list.ptr), @alignOf(types.Locator_t))) {
            return error.MalformedSubmessage;
        }
        const unicast_locs = if (num_unicast > 0) @as([*]const types.Locator_t, @ptrCast(@alignCast(unicast_list.ptr)))[0..num_unicast] else &[_]types.Locator_t{};

        var multicast_locs: []const types.Locator_t = &[_]types.Locator_t{};
        if ((header.flags & 0x02) != 0) { // Multicast flag
            const num_multicast = try des.deserialize(u32);
            const multicast_list = if (num_multicast > 0) try des.readAll(num_multicast * @sizeOf(types.Locator_t)) else &[_]u8{};
            if (num_multicast > 0 and !std.mem.isAligned(@intFromPtr(multicast_list.ptr), @alignOf(types.Locator_t))) {
                return error.MalformedSubmessage;
            }
            multicast_locs = if (num_multicast > 0) @as([*]const types.Locator_t, @ptrCast(@alignCast(multicast_list.ptr)))[0..num_multicast] else &[_]types.Locator_t{};
        }

        return InfoReply{ .header = header, .unicast_locator_list = unicast_locs, .multicast_locator_list = multicast_locs };
    }

    fn parseDataFrag(header: SubmessageHeader, buffer: []const u8, endianness: Endianness) !DataFrag {
        var des = Deserializer.init(buffer[@sizeOf(SubmessageHeader)..], endianness);
        const extra_flags = try des.deserialize(u16);
        const octets_to_inline_qos = try des.deserialize(u16);
        const reader_id = try des.deserialize(types.EntityId_t);
        const writer_id = try des.deserialize(types.EntityId_t);
        const writer_sn = try des.deserialize(types.SequenceNumber_t);
        const fragment_starting_num = try des.deserialize(u32);
        const fragments_in_submessage = try des.deserialize(u16);
        const fragment_size = try des.deserialize(u16);
        const sample_size = try des.deserialize(u32);

        const payload_start = @sizeOf(SubmessageHeader) + 4 + octets_to_inline_qos;
        const sub_len = if (header.submessage_length == 0) buffer.len - @sizeOf(SubmessageHeader) else header.submessage_length;
        const payload_end = @sizeOf(SubmessageHeader) + sub_len;

        var payload: []const u8 = &[_]u8{};
        if (payload_start <= payload_end and payload_end <= buffer.len) {
            payload = buffer[payload_start..payload_end];
        }

        return DataFrag{
            .header = header,
            .extra_flags = extra_flags,
            .octets_to_inline_qos = octets_to_inline_qos,
            .reader_id = reader_id,
            .writer_id = writer_id,
            .writer_sn = writer_sn,
            .fragment_starting_num = fragment_starting_num,
            .fragments_in_submessage = fragments_in_submessage,
            .fragment_size = fragment_size,
            .sample_size = sample_size,
            .serialized_payload = payload,
        };
    }

    fn parseHeartbeatFrag(header: SubmessageHeader, buffer: []const u8, endianness: Endianness) !HeartbeatFrag {
        var des = Deserializer.init(buffer[@sizeOf(SubmessageHeader)..], endianness);
        const reader_id = try des.deserialize(types.EntityId_t);
        const writer_id = try des.deserialize(types.EntityId_t);
        const writer_sn = try des.deserialize(types.SequenceNumber_t);
        const last_fragment_num = try des.deserialize(u32);
        const count = try des.deserialize(types.Count_t);

        return HeartbeatFrag{
            .header = header,
            .reader_id = reader_id,
            .writer_id = writer_id,
            .writer_sn = writer_sn,
            .last_fragment_num = last_fragment_num,
            .count = count,
        };
    }

    fn parseNackFrag(header: SubmessageHeader, buffer: []const u8, endianness: Endianness) !NackFrag {
        var des = Deserializer.init(buffer[@sizeOf(SubmessageHeader)..], endianness);
        const reader_id = try des.deserialize(types.EntityId_t);
        const writer_id = try des.deserialize(types.EntityId_t);
        const writer_sn = try des.deserialize(types.SequenceNumber_t);
        const base = try des.deserialize(types.SequenceNumber_t);
        const num_bits = try des.deserialize(u32);

        var sn_set = types.SequenceNumberSet{
            .base = base,
            .num_bits = num_bits,
        };
        const num_longs = (num_bits + 31) / 32;
        var i: usize = 0;
        while (i < num_longs and i < 8) : (i += 1) {
            sn_set.bitmap[i] = try des.deserialize(u32);
        }
        const count = try des.deserialize(types.Count_t);

        return NackFrag{
            .header = header,
            .reader_id = reader_id,
            .writer_id = writer_id,
            .writer_sn = writer_sn,
            .fragment_number_state = sn_set,
            .count = count,
        };
    }

    fn parseInfoTimestamp(header: SubmessageHeader, buffer: []const u8, endianness: Endianness) !InfoTimestamp {
        var des = Deserializer.init(buffer[@sizeOf(SubmessageHeader)..], endianness);
        const time = try des.deserialize(types.Time_t);
        return InfoTimestamp{
            .header = header,
            .timestamp = time,
        };
    }

    fn parseInfoShm(header: SubmessageHeader, buffer: []const u8, endianness: Endianness) !InfoShm {
        var des = Deserializer.init(buffer[@sizeOf(SubmessageHeader)..], endianness);
        var segment_name: [32]u8 = undefined;
        @memset(&segment_name, 0);
        const str_len = try des.deserialize(u32);
        const max_len = @min(str_len, 32);
        @memcpy(segment_name[0..max_len], des.buffer[des.pos .. des.pos + max_len]);
        des.pos += str_len;
        const offset = try des.deserialize(u32);
        const length = try des.deserialize(u32);
        return InfoShm{
            .header = header,
            .segment_name = segment_name,
            .offset = offset,
            .length = length,
        };
    }
};

const builtin_endian = builtin.target.cpu.arch.endian();

test "Parse INFO_TS Submessage" {
    const buf = &[_]u8{
        0x09, 0x01, 0x08, 0x00, // INFO_TS (0x09), Flags (0x01=LittleEndian), Length (8)
        0x01, 0x00, 0x00, 0x00, // seconds: 1
        0x02, 0x00, 0x00, 0x00, // fraction: 2
    };

    const submsg = try SubmessageParser.parse(buf);

    switch (submsg) {
        .INFO_TS => |ts| {
            try std.testing.expectEqual(@as(i32, 1), ts.timestamp.seconds);
            try std.testing.expectEqual(@as(u32, 2), ts.timestamp.fraction);
        },
        else => return error.UnexpectedSubmessageType,
    }
}

/// @brief Heartbeat frag structure.
pub const HeartbeatFrag = struct {
    header: SubmessageHeader,
    reader_id: types.EntityId_t,
    writer_id: types.EntityId_t,
    writer_sn: types.SequenceNumber_t,
    last_fragment_num: u32,
    count: i32,
};

/// @brief Nack frag structure.
pub const NackFrag = struct {
    header: SubmessageHeader,
    reader_id: types.EntityId_t,
    writer_id: types.EntityId_t,
    writer_sn: types.SequenceNumber_t,
    fragment_number_state: types.SequenceNumberSet,
    count: i32,
};

// --- TESTS ---

test "SubmessageParser DATA missing D flag" {
    // 0x03 = Endianness | InlineQoS (No D flag)
    const header = SubmessageHeader{
        .submessage_id = @backingInt(SubmessageKind.DATA),
        .flags = 0x03,
        .submessage_length = 24, // Enough length
    };

    // extra flags(2), inline_qos(2), reader_id(4), writer_id(4), SN(8) = 20 bytes
    var msg_buf = std.mem.zeroes([64]u8);
    msg_buf[0] = header.submessage_id;
    msg_buf[1] = header.flags;
    msg_buf[2] = 24;
    msg_buf[3] = 0; // length

    const submsg = try SubmessageParser.parse(&msg_buf);
    try std.testing.expectEqual(SubmessageKind.DATA, std.meta.activeTag(submsg));
    try std.testing.expectEqual(@as(usize, 0), submsg.DATA.serialized_payload.len);
}

test "SubmessageParser DATA with D flag and Inline QoS" {
    // 0x07 = Endianness | InlineQoS | Data
    // Submessage length = 20 + 24 (QoS) + 4 (Payload) = 48
    var msg_buf = std.mem.zeroes([128]u8);
    msg_buf[0] = @backingInt(SubmessageKind.DATA);
    msg_buf[1] = 0x07;
    msg_buf[2] = 48;
    msg_buf[3] = 0; // length

    var pos: usize = 4;
    // Extra flags
    msg_buf[pos] = 0;
    msg_buf[pos + 1] = 0;
    pos += 2;
    // OctetsToInlineQos (16)
    msg_buf[pos] = 16;
    msg_buf[pos + 1] = 0;
    pos += 2;
    // ReaderId (unknown)
    pos += 4;
    // WriterId (unknown)
    pos += 4;
    // SN
    msg_buf[pos] = 0;
    pos += 8; // high/low = 0

    // Inline QoS
    msg_buf[pos] = 0x70;
    msg_buf[pos + 1] = 0x00;
    pos += 2; // PID_KEY_HASH
    msg_buf[pos] = 16;
    msg_buf[pos + 1] = 0;
    pos += 2; // length = 16
    pos += 16; // key hash bytes
    msg_buf[pos] = 0x01;
    msg_buf[pos + 1] = 0x00;
    pos += 2; // PID_SENTINEL
    msg_buf[pos] = 0;
    msg_buf[pos + 1] = 0;
    pos += 2; // len = 0

    // Payload (4 bytes)
    msg_buf[pos] = 0xAA;
    msg_buf[pos + 1] = 0xBB;
    msg_buf[pos + 2] = 0xCC;
    msg_buf[pos + 3] = 0xDD;

    const submsg = try SubmessageParser.parse(&msg_buf);
    try std.testing.expectEqual(SubmessageKind.DATA, std.meta.activeTag(submsg));
    try std.testing.expectEqual(@as(usize, 4), submsg.DATA.serialized_payload.len);
    try std.testing.expectEqual(@as(u8, 0xAA), submsg.DATA.serialized_payload[0]);
}

test "SubmessageParser DATA BufferTooSmall" {
    // Invalid length
    var msg_buf = std.mem.zeroes([8]u8);
    msg_buf[0] = @backingInt(SubmessageKind.DATA);
    msg_buf[1] = 0x07;
    msg_buf[2] = 48;
    msg_buf[3] = 0; // Length claims 48, but buffer is 8

    const result = SubmessageParser.parse(&msg_buf);
    try std.testing.expectError(error.BufferTooSmall, result);
}
