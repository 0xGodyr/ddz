//! @file topic.zig
//! @brief Implements the DDS Topic and ContentFilteredTopic entities linking publishers and subscribers via type schemas.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const InconsistentTopicStatus = @import("status.zig").InconsistentTopicStatus;
const xtypes = @import("../types/xtypes.zig");
const InstanceHandle_t = @import("../rtps/types.zig").InstanceHandle_t;

/// @brief Topic structure.
/// @brief Topic listener structure.
pub const TopicListener = struct {
    context: ?*anyopaque = null,
    on_inconsistent_topic: ?*const fn (context: ?*anyopaque, topic: *Topic, status: InconsistentTopicStatus) void = null,
};

pub const Topic = struct {
    name: []const u8,
    type_name: []const u8,
    listener: ?TopicListener = null,
    type_object_cdr: []const u8 = "",

    /// @brief Initializes a new instance.
    pub fn init(name: []const u8, type_name: []const u8) Topic {
        return .{
            .name = name,
            .type_name = type_name,
        };
    }

    /// @brief Init typed.
    pub fn initTyped(allocator: std.mem.Allocator, name: []const u8, comptime T: type) !Topic {
        var type_obj = try xtypes.generateTypeObject(allocator, T);
        defer type_obj.deinit(allocator);

        const cdr_str = try xtypes.serializeTypeObject(allocator, type_obj);

        return .{
            .name = name,
            .type_name = @typeName(T),
            .type_object_cdr = cdr_str,
        };
    }

    /// @brief Deinitializes resources associated with this Topic.
    pub fn deinit(self: *Topic, allocator: std.mem.Allocator) void {
        if (self.type_object_cdr.len > 0) {
            allocator.free(self.type_object_cdr);
            self.type_object_cdr = "";
        }
    }

    /// @brief Gets the administrative instance handle for this Topic based on its name.
    pub fn getInstanceHandle(self: Topic) InstanceHandle_t {
        var hash = std.hash.CityHash64.hash(self.name);
        var handle = std.mem.zeroes(InstanceHandle_t);
        @memcpy(handle[0..8], std.mem.asBytes(&hash));
        return handle;
    }
};

/// @brief Content filtered topic structure.
pub const ContentFilteredTopic = struct {
    name: []const u8,
    listener: ?TopicListener = null,
    related_topic: Topic,
    filter_expression: []const u8,
    expression_parameters: std.ArrayListUnmanaged([]const u8) = .empty,

    /// @brief Initializes a new instance without parameters.
    pub fn init(name: []const u8, related_topic: Topic, filter_expression: []const u8) ContentFilteredTopic {
        return .{
            .name = name,
            .related_topic = related_topic,
            .filter_expression = filter_expression,
            .expression_parameters = .empty,
        };
    }

    /// @brief Initializes a new instance with dynamic expression parameters.
    pub fn initWithParams(allocator: std.mem.Allocator, name: []const u8, related_topic: Topic, filter_expression: []const u8, params: []const []const u8) !ContentFilteredTopic {
        var cft = init(name, related_topic, filter_expression);
        for (params) |p| {
            const copy = try allocator.dupe(u8, p);
            try cft.expression_parameters.append(allocator, copy);
        }
        return cft;
    }

    /// @brief Deinitializes expression parameters.
    pub fn deinit(self: *ContentFilteredTopic, allocator: std.mem.Allocator) void {
        for (self.expression_parameters.items) |p| {
            allocator.free(p);
        }
        self.expression_parameters.deinit(allocator);
    }

    /// @brief Returns the slice of current expression parameters.
    pub fn get_expression_parameters(self: *const ContentFilteredTopic) []const []const u8 {
        return self.expression_parameters.items;
    }

    /// @brief Replaces current expression parameters without recreating the topic.
    pub fn set_expression_parameters(self: *ContentFilteredTopic, allocator: std.mem.Allocator, params: []const []const u8) !void {
        for (self.expression_parameters.items) |p| {
            allocator.free(p);
        }
        self.expression_parameters.clearRetainingCapacity();
        for (params) |p| {
            const copy = try allocator.dupe(u8, p);
            try self.expression_parameters.append(allocator, copy);
        }
    }
};

test "Topic and ContentFilteredTopic initialization and parameters" {
    const topic = Topic.init("SensorTopic", "SensorType");
    try std.testing.expectEqualStrings("SensorTopic", topic.name);
    try std.testing.expectEqualStrings("SensorType", topic.type_name);

    const handle = topic.getInstanceHandle();
    try std.testing.expect(!std.mem.eql(u8, &handle, &std.mem.zeroes(InstanceHandle_t)));

    var cft = try ContentFilteredTopic.initWithParams(std.testing.allocator, "FilteredSensors", topic, "temp > %0", &.{"100.0"});
    defer cft.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("FilteredSensors", cft.name);
    try std.testing.expectEqualStrings("SensorTopic", cft.related_topic.name);
    try std.testing.expectEqualStrings("temp > %0", cft.filter_expression);
    try std.testing.expectEqual(@as(usize, 1), cft.get_expression_parameters().len);
    try std.testing.expectEqualStrings("100.0", cft.get_expression_parameters()[0]);

    // Mutate parameters
    try cft.set_expression_parameters(std.testing.allocator, &.{"250.0"});
    try std.testing.expectEqualStrings("250.0", cft.get_expression_parameters()[0]);
}

test "Topic initTyped dynamic generation" {
    const SensorData = struct { id: u32, temp: f32 };
    var typed_topic = try Topic.initTyped(std.testing.allocator, "TypedSensorTopic", SensorData);
    defer typed_topic.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("TypedSensorTopic", typed_topic.name);
    try std.testing.expect(typed_topic.type_object_cdr.len > 0);
}
