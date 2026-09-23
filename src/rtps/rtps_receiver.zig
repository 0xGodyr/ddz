//! @file rtps_receiver.zig
//! @brief Background listener thread that ingests, decrypts, and routes inbound RTPS packets.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const rtps = @import("../root.zig").rtps;
const GetTickCount64 = @import("../os.zig").getTickCount64;
const DomainParticipant = @import("../dcps/domain_participant.zig").DomainParticipant;
const Publisher = @import("../dcps/publisher.zig").Publisher;
const Subscriber = @import("../dcps/subscriber.zig").Subscriber;
const DataReader = @import("../dcps/data_reader.zig").DataReader;
const DataWriter = @import("../dcps/data_writer.zig").DataWriter;
const ShmSegment = @import("../transport/shm.zig").ShmSegment;
const Deserializer = @import("../cdr/deserializer.zig").Deserializer;
const SPDPDiscoveredParticipantData = @import("../discovery/spdp.zig").SPDPDiscoveredParticipantData;
const sedp = @import("../discovery/sedp.zig");
const DiscoveredWriterData = sedp.DiscoveredWriterData;
const DiscoveredReaderData = sedp.DiscoveredReaderData;
const IdentityToken = @import("../security/authentication_plugin.zig").IdentityToken;
const Qos = @import("../dcps/qos.zig");

pub const RtpsReceiver = struct {
    pub fn processMessage(participant: *DomainParticipant, buffer: []const u8, source_locator: rtps.types.Locator_t) !void {
        const header = rtps.Message.Header.parse(buffer) catch return;

        // Ignore messages sent by ourselves
        if (std.mem.eql(u8, &header.guid_prefix, &participant.guid_prefix)) return;

        // Check if the source participant is ignored
        const source_participant_guid = rtps.types.GUID_t{ .prefix = header.guid_prefix, .entity_id = rtps.types.EntityId_t.participant };
        const source_participant_handle = rtps.types.guidToInstanceHandle(source_participant_guid);

        participant.registry_lock.lockShared();
        const is_ignored_participant = participant.ignored_participants.contains(source_participant_handle);
        participant.registry_lock.unlockShared();

        if (is_ignored_participant) return;

        var offset: usize = @sizeOf(rtps.Message.Header);
        var current_guid_prefix = header.guid_prefix;
        while (offset < buffer.len) {
            const submsg = rtps.Submessage.SubmessageParser.parse(buffer[offset..]) catch break;

            const sub_header = switch (submsg) {
                .INFO_TS => |ts| ts.header,
                .DATA => |d| d.header,
                .DATA_FRAG => |d| d.header,
                .HEARTBEAT => |hb| hb.header,
                .ACKNACK => |an| an.header,
                .NACK_FRAG => |nf| nf.header,
                .HEARTBEAT_FRAG => |hf| hf.header,
                .INFO_DST => |idst| idst.header,
                .INFO_SRC => |isrc| isrc.header,
                .INFO_REPLY => |irep| irep.header,
                .INFO_SHM => |shm| shm.header,
                .SEC_BODY => |sec| sec.header,
                .PAD => break,
                else => break,
            };
            if (sub_header.submessage_length == 0) {
                offset = buffer.len;
            } else {
                offset += @sizeOf(rtps.Submessage.SubmessageHeader) + sub_header.submessage_length;
            }

            if (submsg == .INFO_DST) {
                const dst = submsg.INFO_DST;
                const zero_prefix = std.mem.zeroes([12]u8);
                if (!std.mem.eql(u8, &dst.guid_prefix, &zero_prefix)) {
                    if (!std.mem.eql(u8, &dst.guid_prefix, &participant.guid_prefix)) {
                        break; // Destination is not us, stop processing
                    }
                }
            } else if (submsg == .INFO_SRC) {
                const src = submsg.INFO_SRC;
                current_guid_prefix = src.guid_prefix;
            } else if (submsg == .INFO_REPLY) {
                // Ignored for now
            } else if (submsg == .INFO_SHM) {
                const shm = submsg.INFO_SHM;
                const len = std.mem.indexOfScalar(u8, &shm.segment_name, 0) orelse shm.segment_name.len;
                const shm_name_str = shm.segment_name[0..len];
                var name_z: [33]u8 = undefined;
                @memcpy(name_z[0..len], shm_name_str);
                name_z[len] = 0;

                if (ShmSegment.open(name_z[0..len :0])) |seg_val| {
                    var seg = seg_val;
                    defer seg.deinit();
                    if (shm.offset + shm.length <= seg.size) {
                        const shm_packet = seg.data[shm.offset .. shm.offset + shm.length];
                        processMessage(participant, shm_packet, source_locator) catch {};
                    }
                } else |_| {}
            } else if (submsg == .HEARTBEAT) {
                const hb = submsg.HEARTBEAT;
                const writer_guid = rtps.types.GUID_t{ .prefix = current_guid_prefix, .entity_id = hb.writer_id };

                participant.registry_lock.lockShared();
                const is_ignored = participant.ignored_publications.contains(rtps.types.guidToInstanceHandle(writer_guid));
                if (!is_ignored) {
                    for (participant.subscribers.items) |sub| {
                        sub.readers_lock.lockShared();
                        defer sub.readers_lock.unlockShared();
                        for (sub.readers.items) |reader| {
                            reader.processHeartbeat(writer_guid, hb) catch |err| {
                                std.log.warn("Error in reader.processHeartbeat: {s}", .{@errorName(err)});
                            };
                        }
                    }
                }
                participant.registry_lock.unlockShared();
            } else if (submsg == .ACKNACK) {
                const an = submsg.ACKNACK;
                const reader_guid = rtps.types.GUID_t{ .prefix = current_guid_prefix, .entity_id = an.reader_id };

                participant.registry_lock.lockShared();
                const is_ignored = participant.ignored_subscriptions.contains(rtps.types.guidToInstanceHandle(reader_guid));
                if (!is_ignored) {
                    for (participant.publishers.items) |p| {
                        p.writers_lock.lockShared();
                        defer p.writers_lock.unlockShared();
                        for (p.writers.items) |writer| {
                            writer.processAckNack(reader_guid, an) catch |err| {
                                std.log.warn("Error in writer.processAckNack: {s}", .{@errorName(err)});
                            };
                        }
                    }
                }
                participant.registry_lock.unlockShared();
            } else if (submsg == .DATA) {
                const data = submsg.DATA;

                // If this is SPDP Builtin discovery DATA
                if (data.writer_id.entity_kind == rtps.types.EntityId_t.participant.entity_kind and
                    data.writer_id.entity_key[0] == rtps.types.EntityId_t.participant.entity_key[0])
                {
                    var is_new_participant = false;
                    {
                        participant.registry_lock.lock();
                        defer participant.registry_lock.unlock();

                        var exists = false;
                        const prefixes = participant.discovered_participants.items(.guid_prefix);
                        const last_seen = participant.discovered_participants.items(.last_seen_msec);
                        const now = @as(i64, @intCast(GetTickCount64()));

                        for (prefixes, 0..) |prefix, i| {
                            if (std.mem.eql(u8, &prefix, &current_guid_prefix)) {
                                exists = true;
                                last_seen[i] = now; // update liveliness!
                                break;
                            }
                        }

                        if (!exists) {
                            var parsed_filter: ?[]const u8 = null;
                            var remote_pub_key: ?[32]u8 = null;

                            if (data.serialized_payload.len > 0) {
                                var des = Deserializer.init(data.serialized_payload, .Little);
                                if (des.deserialize(SPDPDiscoveredParticipantData)) |spdp| {
                                    if (spdp.filter_expression.len > 0) {
                                        parsed_filter = participant.allocator.dupe(u8, spdp.filter_expression) catch null;
                                    }
                                    if (spdp.has_public_key) remote_pub_key = spdp.public_key;
                                } else |_| {}
                            }

                            participant.discovered_participants.append(participant.allocator, .{
                                .guid_prefix = current_guid_prefix,
                                .metatraffic_unicast_locator = source_locator,
                                .last_seen_msec = now,
                                .filter_expression = parsed_filter,
                                .public_key = remote_pub_key,
                            }) catch {
                                if (parsed_filter) |f| participant.allocator.free(f);
                            };
                            is_new_participant = true;
                        }
                    }

                    if (is_new_participant) {
                        var writers_to_notify: std.ArrayListUnmanaged(*DataWriter) = .empty;
                        defer writers_to_notify.deinit(participant.allocator);
                        {
                            participant.registry_lock.lockShared();
                            defer participant.registry_lock.unlockShared();
                            for (participant.publishers.items) |publisher| {
                                publisher.writers_lock.lockShared();
                                defer publisher.writers_lock.unlockShared();
                                for (publisher.writers.items) |writer| {
                                    writers_to_notify.append(participant.allocator, writer) catch {};
                                }
                            }
                        }

                        for (writers_to_notify.items) |writer| {
                            writer.onNewParticipantDiscovered(source_locator) catch {};
                        }

                        participant.announceEndpoints() catch {};

                        // Route SPDP to Built-in Subscriber
                        if (participant.sedp_subscriber) |builtin_sub| {
                            builtin_sub.readers_lock.lockShared();
                            defer builtin_sub.readers_lock.unlockShared();
                            for (builtin_sub.readers.items) |reader| {
                                if (std.mem.eql(u8, reader.topic.name, "DCPSParticipant")) {
                                    const writer_guid = rtps.types.GUID_t{ .prefix = current_guid_prefix, .entity_id = data.writer_id };
                                    reader.processData(writer_guid, data) catch |err| std.log.warn("processData err: {s}", .{@errorName(err)});
                                }
                            }
                        }

                        // DDS-SEC Plugin Handshake triggers here natively instead of X25519
                        if (participant.auth_plugin) |auth| {
                            var remote_id: IdentityToken = undefined;
                            if (auth.validateRemoteIdentity(&remote_id, undefined, undefined, rtps.types.GUID_t{ .prefix = current_guid_prefix, .entity_id = rtps.types.EntityId_t.participant }) == .VALIDATION_PENDING_HANDSHAKE_REQUEST) {}
                        }
                    }
                } else if (std.meta.eql(data.writer_id, rtps.types.EntityId_t.sedp_pub_writer)) {
                    if (participant.sedp_pub_reader) |sedp_reader| {
                        const writer_guid = rtps.types.GUID_t{ .prefix = current_guid_prefix, .entity_id = data.writer_id };
                        sedp_reader.processData(writer_guid, data) catch |err| std.log.warn("sedp_pub_reader processData err: {s}", .{@errorName(err)});
                        if (data.serialized_payload.len > 0) {
                            var des = Deserializer.init(data.serialized_payload, .Little);
                            if (des.deserialize(DiscoveredWriterData)) |dwd| {
                                participant.registry_lock.lockShared();
                                defer participant.registry_lock.unlockShared();
                                for (participant.subscribers.items) |sub| {
                                    sub.readers_lock.lockShared();
                                    defer sub.readers_lock.unlockShared();
                                    for (sub.readers.items) |reader| {
                                        _ = reader.matchRemoteWriter(dwd) catch false;
                                    }
                                }
                            } else |_| {}
                        }
                    }
                } else if (std.meta.eql(data.writer_id, rtps.types.EntityId_t.sedp_sub_writer)) {
                    if (participant.sedp_sub_reader) |sedp_reader| {
                        const writer_guid = rtps.types.GUID_t{ .prefix = current_guid_prefix, .entity_id = data.writer_id };
                        sedp_reader.processData(writer_guid, data) catch |err| std.log.warn("sedp_sub_reader processData err: {s}", .{@errorName(err)});
                        if (data.serialized_payload.len > 0) {
                            var des = Deserializer.init(data.serialized_payload, .Little);
                            if (des.deserialize(DiscoveredReaderData)) |drd| {
                                participant.registry_lock.lockShared();
                                defer participant.registry_lock.unlockShared();
                                for (participant.publishers.items) |publ| {
                                    publ.writers_lock.lockShared();
                                    defer publ.writers_lock.unlockShared();
                                    for (publ.writers.items) |writer| {
                                        _ = writer.matchRemoteReader(drd) catch false;
                                    }
                                }
                            } else |_| {}
                        }
                    }
                } else {
                    // It's User Data. We need to route it.
                    participant.registry_lock.lockShared();
                    defer participant.registry_lock.unlockShared();

                    const writer_guid = rtps.types.GUID_t{ .prefix = current_guid_prefix, .entity_id = data.writer_id };
                    const is_ignored = participant.ignored_publications.contains(rtps.types.guidToInstanceHandle(writer_guid));

                    if (!is_ignored) {
                        // Route to matching Readers
                        for (participant.subscribers.items) |sub| {
                            sub.readers_lock.lockShared();
                            defer sub.readers_lock.unlockShared();
                            for (sub.readers.items) |reader| {
                                var is_matched = false;
                                reader.registry_lock.lock();
                                for (reader.matched_writers.items) |mw| {
                                    if (std.meta.eql(mw, writer_guid)) {
                                        is_matched = true;
                                        break;
                                    }
                                }
                                reader.registry_lock.unlock();

                                if (!is_matched) {
                                    if (participant.findRemoteWriterData(writer_guid)) |rwd| {
                                        if (!std.mem.eql(u8, rwd.topic_name, reader.topic.name)) continue;
                                        if (!Qos.matchPartition(rwd.partition_name, sub.qos.partition.name)) continue;
                                    } else {
                                        continue;
                                    }
                                }
                                reader.processData(writer_guid, data) catch |err| std.log.warn("processData err: {s}", .{@errorName(err)});
                            }
                        }
                    }
                }
            } else if (submsg == .DATA_FRAG) {
                const data_frag = submsg.DATA_FRAG;

                // Route fragmented user data to matching Readers
                participant.registry_lock.lockShared();
                defer participant.registry_lock.unlockShared();

                const writer_guid = rtps.types.GUID_t{ .prefix = current_guid_prefix, .entity_id = data_frag.writer_id };
                const is_ignored = participant.ignored_publications.contains(rtps.types.guidToInstanceHandle(writer_guid));

                if (!is_ignored) {
                    for (participant.subscribers.items) |sub| {
                        sub.readers_lock.lockShared();
                        defer sub.readers_lock.unlockShared();
                        for (sub.readers.items) |reader| {
                            var is_matched = false;
                            reader.registry_lock.lock();
                            for (reader.matched_writers.items) |mw| {
                                if (std.meta.eql(mw, writer_guid)) {
                                    is_matched = true;
                                    break;
                                }
                            }
                            reader.registry_lock.unlock();

                            if (!is_matched) {
                                if (participant.findRemoteWriterData(writer_guid)) |rwd| {
                                    if (!std.mem.eql(u8, rwd.topic_name, reader.topic.name)) continue;
                                    if (!Qos.matchPartition(rwd.partition_name, sub.qos.partition.name)) continue;
                                } else {
                                    continue;
                                }
                            }
                            reader.processDataFrag(writer_guid, data_frag) catch |err| {
                                std.log.warn("Error in reader.processDataFrag: {s}", .{@errorName(err)});
                            };
                        }
                    }
                }
            } else if (submsg == .HEARTBEAT_FRAG) {
                const hf = submsg.HEARTBEAT_FRAG;
                participant.registry_lock.lockShared();
                defer participant.registry_lock.unlockShared();

                const writer_guid = rtps.types.GUID_t{ .prefix = current_guid_prefix, .entity_id = hf.writer_id };
                const is_ignored = participant.ignored_publications.contains(rtps.types.guidToInstanceHandle(writer_guid));

                if (!is_ignored) {
                    for (participant.subscribers.items) |sub| {
                        sub.readers_lock.lockShared();
                        defer sub.readers_lock.unlockShared();
                        for (sub.readers.items) |reader| {
                            if (std.mem.eql(u8, &reader.entity_id.entity_key, &hf.reader_id.entity_key) or
                                hf.reader_id.entity_kind == rtps.types.EntityId_t.unknown.entity_kind)
                            {
                                reader.processHeartbeatFrag(writer_guid, hf) catch |err| {
                                    std.log.warn("Error in reader.processHeartbeatFrag: {s}", .{@errorName(err)});
                                };
                            }
                        }
                    }
                }
            } else if (submsg == .NACK_FRAG) {
                const nack = submsg.NACK_FRAG;
                participant.registry_lock.lockShared();
                defer participant.registry_lock.unlockShared();

                const reader_guid = rtps.types.GUID_t{ .prefix = current_guid_prefix, .entity_id = nack.reader_id };
                const is_ignored = participant.ignored_subscriptions.contains(rtps.types.guidToInstanceHandle(reader_guid));

                if (!is_ignored) {
                    for (participant.publishers.items) |publisher| {
                        publisher.writers_lock.lockShared();
                        defer publisher.writers_lock.unlockShared();
                        for (publisher.writers.items) |writer| {
                            if (std.mem.eql(u8, &writer.entity_id.entity_key, &nack.writer_id.entity_key)) {
                                writer.processNackFrag(reader_guid, nack) catch |err| {
                                    std.log.warn("Error in writer.processNackFrag: {s}", .{@errorName(err)});
                                };
                            }
                        }
                    }
                }
            } else if (submsg == .SEC_BODY) {
                const sec = submsg.SEC_BODY;

                var decrypted_submsg: ?rtps.Submessage.Submessage = null;
                if (participant.crypto_plugin) |crypto| {
                    var plaintext_buf: [65536]u8 = undefined;
                    // KeyID 1 is the mock static key ID
                    if (crypto.decryptSerializedPayload(sec.crypto_payload, 1, &plaintext_buf)) |plaintext| {
                        decrypted_submsg = rtps.Submessage.SubmessageParser.parse(plaintext) catch null;
                    } else |_| {}
                }

                if (decrypted_submsg) |plain_submsg| {
                    if (plain_submsg == .DATA) {
                        const data = plain_submsg.DATA;

                        participant.registry_lock.lockShared();
                        defer participant.registry_lock.unlockShared();

                        const writer_guid = rtps.types.GUID_t{ .prefix = current_guid_prefix, .entity_id = data.writer_id };
                        const is_ignored = participant.ignored_publications.contains(rtps.types.guidToInstanceHandle(writer_guid));

                        if (!is_ignored) {
                            for (participant.subscribers.items) |sub| {
                                sub.readers_lock.lockShared();
                                defer sub.readers_lock.unlockShared();
                                for (sub.readers.items) |reader| {
                                    reader.processData(writer_guid, data) catch |err| std.log.warn("processData err: {s}", .{@errorName(err)});
                                }
                            }
                        }
                    } else if (plain_submsg == .DATA_FRAG) {
                        const data_frag = plain_submsg.DATA_FRAG;
                        participant.registry_lock.lockShared();
                        defer participant.registry_lock.unlockShared();

                        const writer_guid = rtps.types.GUID_t{ .prefix = current_guid_prefix, .entity_id = data_frag.writer_id };
                        const is_ignored = participant.ignored_publications.contains(rtps.types.guidToInstanceHandle(writer_guid));

                        if (!is_ignored) {
                            for (participant.subscribers.items) |sub| {
                                sub.readers_lock.lockShared();
                                defer sub.readers_lock.unlockShared();
                                for (sub.readers.items) |reader| {
                                    reader.processDataFrag(writer_guid, data_frag) catch {};
                                }
                            }
                        }
                    }
                }
            }
        }
    }
};
