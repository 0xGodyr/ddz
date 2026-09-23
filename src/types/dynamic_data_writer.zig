//! @file dynamic_data_writer.zig
//! @brief DataWriter wrapper supporting runtime type encoding via XTypes TypeObjects.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const DomainParticipant = @import("../dcps/domain_participant.zig").DomainParticipant;
const rtps = @import("../root.zig").rtps;
const Topic = @import("../dcps/topic.zig").Topic;
const Publisher = @import("../dcps/publisher.zig").Publisher;
const DataWriter = @import("../dcps/data_writer.zig").DataWriter;
const WriterQos = @import("../dcps/qos.zig").WriterQos;
const xtypes = @import("xtypes.zig");

/// @brief Dynamic data writer structure.
pub const DynamicDataWriter = struct {
    allocator: std.mem.Allocator,
    publisher: *Publisher,
    participant: *DomainParticipant,
    underlying_writer: *DataWriter,
    type_obj: xtypes.TypeObject,
    topic_name: []const u8,

    /// @brief Initializes a new instance.
    pub fn init(publisher: *Publisher, topic_name: []const u8, qos: WriterQos, type_obj: xtypes.TypeObject) !DynamicDataWriter {
        var topic = Topic.init(topic_name, type_obj.name);

        // Serialize TypeObject into the topic so it gets broadcasted during discovery
        const cdr_bytes = try xtypes.serializeTypeObject(publisher.allocator, type_obj);
        errdefer publisher.allocator.free(cdr_bytes);
        topic.type_object_cdr = cdr_bytes;

        const writer = try publisher.createDataWriter(topic, qos, rtps.types.EntityId_t.unknown);

        return .{
            .allocator = publisher.allocator,
            .publisher = publisher,
            .participant = publisher.participant,
            .underlying_writer = writer,
            .type_obj = type_obj, // Takes ownership, caller should not deinit if passed by value (wait, struct passed by value, we clone it or take it. Let's assume we take ownership of its internals).
            .topic_name = topic_name,
        };
    }

    /// @brief Deinitializes the instance.
    pub fn deinit(self: *DynamicDataWriter) void {
        if (self.underlying_writer.topic.type_object_cdr.len > 0) {
            self.allocator.free(self.underlying_writer.topic.type_object_cdr);
            self.underlying_writer.topic.type_object_cdr = "";
        }
        self.type_obj.deinit(self.allocator);
        self.publisher.deleteDataWriter(self.underlying_writer) catch {};
    }

    /// @brief Write dynamic value.
    pub fn writeDynamic(self: *DynamicDataWriter, val: xtypes.DynamicValue) !void {
        // Serialize the value into a payload based on the type_obj
        const cdr_bytes = try xtypes.serializeDynamic(self.allocator, val, &self.type_obj);
        defer self.allocator.free(cdr_bytes);

        // Write to underlying writer
        _ = try self.underlying_writer.writeWithParams(cdr_bytes, null, .ALIVE);
    }
};
