//! @file rpc.zig
//! @brief Implements Request/Reply remote procedure call (RPC) patterns over standard DDS topics.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const rtps = @import("../rtps/types.zig");
const DataWriter = @import("../dcps/data_writer.zig").DataWriter;
const DataReader = @import("../dcps/data_reader.zig").DataReader;
const Deserializer = @import("../cdr/deserializer.zig").Deserializer;
const sleepMs = @import("../os.zig").sleepMs;

pub fn Requester(comptime ReqType: type, comptime RepType: type) type {
    return struct {
        const Self = @This();

        request_writer: *DataWriter,
        reply_reader: *DataReader,

        pub fn init(request_writer: *DataWriter, reply_reader: *DataReader) Self {
            return .{
                .request_writer = request_writer,
                .reply_reader = reply_reader,
            };
        }

        /// @brief Send a request and return the SampleIdentity used.
        pub fn sendRequest(self: *Self, req_data: ReqType) !rtps.SampleIdentity_t {
            return try self.request_writer.writeWithParams(req_data, null, .ALIVE);
        }

        /// @brief Wait for a reply matching the request identity.
        pub fn waitForReply(self: *Self, req_id: rtps.SampleIdentity_t, timeout_ms: u32) !?RepType {
            var waited: u32 = 0;
            while (waited < timeout_ms) {
                var found_rep: ?RepType = null;
                {
                    self.reply_reader.history_cache.acquireLock();
                    defer self.reply_reader.history_cache.releaseLock();

                    var current = self.reply_reader.history_cache.global_head;
                    while (current) |node| : (current = node.global_next) {
                        if (node.change.related_sample_identity) |rsi| {
                            if (std.meta.eql(rsi.writer_guid, req_id.writer_guid) and
                                rsi.sequence_number.high == req_id.sequence_number.high and
                                rsi.sequence_number.low == req_id.sequence_number.low)
                            {
                                var des = Deserializer.init(node.change.data_value, .Little);
                                if (des.deserialize(RepType)) |rep| {
                                    found_rep = rep;
                                    break;
                                } else |_| {
                                    continue;
                                }
                            }
                        }
                    }
                }
                if (found_rep) |rep| return rep;

                sleepMs(1);
                waited += 1;
            }
            return null;
        }
    };
}

pub fn Replier(comptime ReqType: type, comptime RepType: type) type {
    return struct {
        const Self = @This();

        request_reader: *DataReader,
        reply_writer: *DataWriter,
        allocator: std.mem.Allocator,
        last_processed: std.AutoHashMapUnmanaged(rtps.GUID_t, i64) = .empty,

        pub fn init(allocator: std.mem.Allocator, request_reader: *DataReader, reply_writer: *DataWriter) Self {
            return .{
                .allocator = allocator,
                .request_reader = request_reader,
                .reply_writer = reply_writer,
            };
        }

        pub fn deinit(self: *Self) void {
            self.last_processed.deinit(self.allocator);
        }

        pub const RequestInfo = struct {
            data: ReqType,
            identity: rtps.SampleIdentity_t,
        };

        /// @brief Receive the next unread request.
        pub fn receiveRequest(self: *Self, timeout_ms: u32) !?RequestInfo {
            var waited: u32 = 0;
            while (waited < timeout_ms) {
                var found_req: ?RequestInfo = null;
                {
                    self.request_reader.history_cache.acquireLock();
                    defer self.request_reader.history_cache.releaseLock();

                    var current = self.request_reader.history_cache.global_head;
                    while (current) |node| : (current = node.global_next) {
                        const sn_i64: i64 = (@as(i64, node.change.sequence_number.high) << 32) | @as(i64, node.change.sequence_number.low);

                        const last_sn = self.last_processed.get(node.change.writer_guid) orelse -1;
                        if (sn_i64 > last_sn) {
                            // Found a new request
                            try self.last_processed.put(self.allocator, node.change.writer_guid, sn_i64);

                            var des = Deserializer.init(node.change.data_value, .Little);
                            if (des.deserialize(ReqType)) |req| {
                                found_req = RequestInfo{
                                    .data = req,
                                    .identity = rtps.SampleIdentity_t{
                                        .writer_guid = node.change.writer_guid,
                                        .sequence_number = node.change.sequence_number,
                                    },
                                };
                                break;
                            } else |_| {
                                continue;
                            }
                        }
                    }
                }
                if (found_req) |req| return req;

                if (timeout_ms == 0) return null;
                sleepMs(1);
                waited += 1;
            }
            return null;
        }

        /// @brief Send a reply tied to a request identity.
        pub fn sendReply(self: *Self, reply_data: RepType, req_id: rtps.SampleIdentity_t) !void {
            _ = try self.reply_writer.writeWithParams(reply_data, req_id, .ALIVE);
        }
    };
}

test "RPC Request and Reply basics" {}
