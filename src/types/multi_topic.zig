//! @file multi_topic.zig
//! @brief Implements SQL-like runtime JOIN operations across multiple DDS topics.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const Topic = @import("../dcps/topic.zig").Topic;
const Subscriber = @import("../dcps/subscriber.zig").Subscriber;
const ReaderQos = @import("../dcps/qos.zig").ReaderQos;
const DynamicDataReader = @import("dynamic_data_reader.zig").DynamicDataReader;
const xtypes = @import("xtypes.zig");
const rtps = @import("../rtps/types.zig");

pub const MultiTopic = struct {
    name: []const u8,
    type_name: []const u8,
    join_expression: []const u8,

    // Parsed info
    topic1_name: []const u8,
    topic2_name: []const u8,
    join_field1: []const u8,
    join_field2: []const u8,

    pub fn init(name: []const u8, type_name: []const u8, join_expression: []const u8) !MultiTopic {
        // e.g. "SELECT * FROM Temp JOIN GPS ON Temp.id = GPS.id"
        // Minimal parser for MVP

        const from_idx = std.mem.indexOf(u8, join_expression, "FROM ") orelse return error.InvalidExpression;
        const join_idx = std.mem.indexOf(u8, join_expression, " JOIN ") orelse return error.InvalidExpression;
        const on_idx = std.mem.indexOf(u8, join_expression, " ON ") orelse return error.InvalidExpression;
        const eq_idx = std.mem.indexOf(u8, join_expression[on_idx..], " = ") orelse return error.InvalidExpression;
        const real_eq_idx = on_idx + eq_idx;

        const topic1 = join_expression[from_idx + 5 .. join_idx];
        const topic2 = join_expression[join_idx + 6 .. on_idx];

        const cond1 = join_expression[on_idx + 4 .. real_eq_idx];
        const cond2 = join_expression[real_eq_idx + 3 ..];

        var field1 = cond1;
        if (std.mem.indexOf(u8, cond1, ".")) |dot| {
            field1 = cond1[dot + 1 ..];
        }
        var field2 = cond2;
        if (std.mem.indexOf(u8, cond2, ".")) |dot| {
            field2 = cond2[dot + 1 ..];
        }

        return MultiTopic{
            .name = name,
            .type_name = type_name,
            .join_expression = join_expression,
            .topic1_name = topic1,
            .topic2_name = topic2,
            .join_field1 = field1,
            .join_field2 = field2,
        };
    }
};

pub const MultiDataReader = struct {
    allocator: std.mem.Allocator,
    multi_topic: MultiTopic,
    reader1: DynamicDataReader,
    reader2: DynamicDataReader,

    // Aggregation cache
    // We store received values indexed by their join field value.
    // For MVP, we assume the join field is a u32.
    cache1: std.AutoHashMapUnmanaged(u32, xtypes.DynamicValue),
    cache2: std.AutoHashMapUnmanaged(u32, xtypes.DynamicValue),

    pub fn init(subscriber: *Subscriber, multi_topic: MultiTopic, qos: ReaderQos) !*MultiDataReader {
        const allocator = subscriber.participant.allocator;

        var reader1 = try DynamicDataReader.init(subscriber, multi_topic.topic1_name, qos);
        errdefer reader1.deinit();
        var reader2 = try DynamicDataReader.init(subscriber, multi_topic.topic2_name, qos);
        errdefer reader2.deinit();

        const self = try allocator.create(MultiDataReader);
        self.* = .{
            .allocator = allocator,
            .multi_topic = multi_topic,
            .reader1 = reader1,
            .reader2 = reader2,
            .cache1 = .empty,
            .cache2 = .empty,
        };
        return self;
    }

    pub fn deinit(self: *MultiDataReader) void {
        self.reader1.deinit();
        self.reader2.deinit();

        var it1 = self.cache1.valueIterator();
        while (it1.next()) |val| val.deinit(self.allocator);
        self.cache1.deinit(self.allocator);

        var it2 = self.cache2.valueIterator();
        while (it2.next()) |val| val.deinit(self.allocator);
        self.cache2.deinit(self.allocator);

        self.allocator.destroy(self);
    }

    pub fn takeDynamic(self: *MultiDataReader) !?xtypes.DynamicValue {
        // Drain reader1
        var sn_list1: std.ArrayListUnmanaged(rtps.SequenceNumber_t) = .empty;
        defer sn_list1.deinit(self.allocator);
        {
            self.reader1.underlying_reader.history_cache.acquireLock();
            defer self.reader1.underlying_reader.history_cache.releaseLock();
            var cur1 = self.reader1.underlying_reader.history_cache.global_head;
            while (cur1) |node| : (cur1 = node.global_next) {
                sn_list1.append(self.allocator, node.change.sequence_number) catch break;
            }
        }

        for (sn_list1.items) |sn| {
            if (try self.reader1.takeDynamic(sn)) |val| {
                var stored = false;
                if (val == .Struct) {
                    if (val.Struct.get(self.multi_topic.join_field1)) |field_val| {
                        if (field_val == .UInt32) {
                            if (try self.cache1.fetchPut(self.allocator, field_val.UInt32, val)) |prev| {
                                var old_val = prev.value;
                                old_val.deinit(self.allocator);
                            }
                            stored = true;
                        }
                    }
                }
                if (!stored) {
                    var mut_val = val;
                    mut_val.deinit(self.allocator);
                }
            }
        }

        // Drain reader2
        var sn_list2: std.ArrayListUnmanaged(rtps.SequenceNumber_t) = .empty;
        defer sn_list2.deinit(self.allocator);
        {
            self.reader2.underlying_reader.history_cache.acquireLock();
            defer self.reader2.underlying_reader.history_cache.releaseLock();
            var cur2 = self.reader2.underlying_reader.history_cache.global_head;
            while (cur2) |node| : (cur2 = node.global_next) {
                sn_list2.append(self.allocator, node.change.sequence_number) catch break;
            }
        }

        for (sn_list2.items) |sn| {
            if (try self.reader2.takeDynamic(sn)) |val| {
                var stored = false;
                if (val == .Struct) {
                    if (val.Struct.get(self.multi_topic.join_field2)) |field_val| {
                        if (field_val == .UInt32) {
                            if (try self.cache2.fetchPut(self.allocator, field_val.UInt32, val)) |prev| {
                                var old_val = prev.value;
                                old_val.deinit(self.allocator);
                            }
                            stored = true;
                        }
                    }
                }
                if (!stored) {
                    var mut_val = val;
                    mut_val.deinit(self.allocator);
                }
            }
        }

        // Attempt to find a join
        var it1 = self.cache1.iterator();
        while (it1.next()) |entry| {
            const key = entry.key_ptr.*;
            if (self.cache2.get(key)) |val2| {
                // We have a match!
                var val1 = entry.value_ptr.*;

                // Construct a joined struct
                var joined = std.StringHashMap(xtypes.DynamicValue).init(self.allocator);
                errdefer {
                    var it_clean = joined.valueIterator();
                    while (it_clean.next()) |v| v.deinit(self.allocator);
                    joined.deinit();
                }

                // Copy fields from val1
                var iter1 = val1.Struct.iterator();
                while (iter1.next()) |f| {
                    try joined.put(f.key_ptr.*, try f.value_ptr.*.clone(self.allocator));
                }

                // Copy fields from val2 (prefixing or just overwriting)
                var iter2 = val2.Struct.iterator();
                while (iter2.next()) |f| {
                    // Don't overwrite join field since it's the same
                    if (std.mem.eql(u8, f.key_ptr.*, self.multi_topic.join_field2)) continue;

                    try joined.put(f.key_ptr.*, try f.value_ptr.*.clone(self.allocator));
                }

                // Remove from caches so we don't yield it again
                // For MVP, we just consume it.
                val1.deinit(self.allocator);
                _ = self.cache1.remove(key);

                var v2_mut = self.cache2.fetchRemove(key).?.value;
                v2_mut.deinit(self.allocator);

                return xtypes.DynamicValue{ .Struct = joined };
            }
        }

        return null;
    }
};

test "MultiTopic SQL join expression parsing" {
    const mt = try MultiTopic.init(
        "SensorJoin",
        "JoinedData",
        "SELECT * FROM Temp JOIN GPS ON Temp.device_id = GPS.device_id",
    );
    try std.testing.expectEqualStrings("SensorJoin", mt.name);
    try std.testing.expectEqualStrings("JoinedData", mt.type_name);
    try std.testing.expectEqualStrings("Temp", mt.topic1_name);
    try std.testing.expectEqualStrings("GPS", mt.topic2_name);
    try std.testing.expectEqualStrings("device_id", mt.join_field1);
    try std.testing.expectEqualStrings("device_id", mt.join_field2);

    // Invalid SQL expressions
    try std.testing.expectError(error.InvalidExpression, MultiTopic.init("J", "T", "SELECT * FROM Temp"));
    try std.testing.expectError(error.InvalidExpression, MultiTopic.init("J", "T", "SELECT * Temp JOIN GPS ON a = b"));
    try std.testing.expectError(error.InvalidExpression, MultiTopic.init("J", "T", "SELECT * FROM Temp JOIN GPS a = b"));
}
