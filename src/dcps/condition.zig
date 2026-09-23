//! @file condition.zig
//! @brief Implements DDS synchronization primitives including GuardCondition, StatusCondition, ReadCondition, and QueryCondition.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const WaitSet = @import("wait_set.zig").WaitSet;
const SampleInfo = @import("sample_info.zig");
const DataReader = @import("data_reader.zig").DataReader;

/// @brief Condition kind structure.
pub const ConditionKind = enum {
    read_condition,
    query_condition,
    status_condition,
    guard_condition,
};

/// @brief Condition structure.
pub const Condition = struct {
    kind: ConditionKind,
    trigger_value: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    waitset: ?*WaitSet = null,

    /// @brief Check if condition is actually true (evaluates state).
    pub fn evaluate(self: *Condition) bool {
        if (self.kind == .read_condition or self.kind == .query_condition) {
            const rc: *ReadCondition = @ptrCast(@alignCast(self));
            return rc.reader.hasData(rc.sample_states, rc.view_states, rc.instance_states, if (self.kind == .query_condition) @ptrCast(@alignCast(self)) else null);
        }
        return self.trigger_value.load(.acquire);
    }

    /// @brief Set trigger value.
    pub fn setTriggerValue(self: *Condition, value: bool) void {
        const prev = self.trigger_value.swap(value, .release);
        if (value and !prev) {
            if (self.waitset) |ws| {
                ws.signal(self);
            }
        }
    }
};

/// @brief Read condition structure.
pub const ReadCondition = struct {
    condition: Condition,
    reader: *DataReader,
    sample_states: SampleInfo.SampleStateMask,
    view_states: SampleInfo.ViewStateMask,
    instance_states: SampleInfo.InstanceStateMask,

    /// @brief Initializes a new instance.
    pub fn init(reader: *DataReader, sample_states: SampleInfo.SampleStateMask, view_states: SampleInfo.ViewStateMask, instance_states: SampleInfo.InstanceStateMask) ReadCondition {
        return .{
            .condition = .{ .kind = .read_condition },
            .reader = reader,
            .sample_states = sample_states,
            .view_states = view_states,
            .instance_states = instance_states,
        };
    }
};

/// @brief Query condition structure.
pub const QueryCondition = struct {
    read_condition: ReadCondition,
    query_expression: []const u8,
    query_parameters: std.ArrayListUnmanaged([]const u8) = .empty,

    /// @brief Initializes a new instance without parameters.
    pub fn init(reader: *DataReader, sample_states: SampleInfo.SampleStateMask, view_states: SampleInfo.ViewStateMask, instance_states: SampleInfo.InstanceStateMask, query_expression: []const u8) QueryCondition {
        return .{
            .read_condition = .{
                .condition = .{ .kind = .query_condition },
                .reader = reader,
                .sample_states = sample_states,
                .view_states = view_states,
                .instance_states = instance_states,
            },
            .query_expression = query_expression,
            .query_parameters = .empty,
        };
    }

    /// @brief Initializes a new instance with dynamic query parameters.
    pub fn initWithParams(allocator: std.mem.Allocator, reader: *DataReader, sample_states: SampleInfo.SampleStateMask, view_states: SampleInfo.ViewStateMask, instance_states: SampleInfo.InstanceStateMask, query_expression: []const u8, params: []const []const u8) !QueryCondition {
        var qc = init(reader, sample_states, view_states, instance_states, query_expression);
        for (params) |p| {
            const copy = try allocator.dupe(u8, p);
            try qc.query_parameters.append(allocator, copy);
        }
        return qc;
    }

    /// @brief Deinitializes query parameters.
    pub fn deinit(self: *QueryCondition, allocator: std.mem.Allocator) void {
        for (self.query_parameters.items) |p| {
            allocator.free(p);
        }
        self.query_parameters.deinit(allocator);
    }

    /// @brief Returns the slice of current query parameters.
    pub fn get_query_parameters(self: *const QueryCondition) []const []const u8 {
        return self.query_parameters.items;
    }

    /// @brief Replaces current query parameters without destroying the condition.
    pub fn set_query_parameters(self: *QueryCondition, allocator: std.mem.Allocator, params: []const []const u8) !void {
        for (self.query_parameters.items) |p| {
            allocator.free(p);
        }
        self.query_parameters.clearRetainingCapacity();
        for (params) |p| {
            const copy = try allocator.dupe(u8, p);
            try self.query_parameters.append(allocator, copy);
        }
    }
};

/// @brief Guard condition structure.
pub const GuardCondition = struct {
    condition: Condition,

    pub fn init() GuardCondition {
        return .{
            .condition = .{ .kind = .guard_condition },
        };
    }

    pub fn setTriggerValue(self: *GuardCondition, value: bool) void {
        self.condition.setTriggerValue(value);
    }
};

/// @brief Status condition structure.
pub const StatusCondition = struct {
    condition: Condition,
    entity: *anyopaque, // Type erased Entity pointer
    enabled_statuses: u32 = 0xFFFFFFFF,

    pub fn init(entity: *anyopaque) StatusCondition {
        return .{
            .condition = .{ .kind = .status_condition },
            .entity = entity,
        };
    }

    pub fn setEnabledStatuses(self: *StatusCondition, mask: u32) void {
        self.enabled_statuses = mask;
    }
};

test "Condition - GuardCondition trigger and waitset interaction" {
    var guard = GuardCondition.init();
    try std.testing.expectEqual(ConditionKind.guard_condition, guard.condition.kind);
    try std.testing.expect(!guard.condition.evaluate());

    var waitset = WaitSet.init(std.testing.allocator);
    defer waitset.deinit();

    try waitset.attachCondition(&guard.condition);
    defer waitset.detachCondition(&guard.condition);

    guard.setTriggerValue(true);
    try std.testing.expect(guard.condition.evaluate());

    const active = try waitset.wait(10 * std.time.ns_per_ms);
    defer std.testing.allocator.free(active);
    try std.testing.expectEqual(@as(usize, 1), active.len);
    try std.testing.expectEqual(&guard.condition, active[0]);
}

test "Condition - StatusCondition initialization and status mask" {
    var dummy: u32 = 42;
    var sc = StatusCondition.init(&dummy);
    try std.testing.expectEqual(ConditionKind.status_condition, sc.condition.kind);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), sc.enabled_statuses);

    sc.setEnabledStatuses(0x00000005);
    try std.testing.expectEqual(@as(u32, 0x00000005), sc.enabled_statuses);
}

test "Condition - QueryCondition parameters and mutation" {
    var dummy_reader: DataReader = undefined;
    var qc = try QueryCondition.initWithParams(
        std.testing.allocator,
        &dummy_reader,
        SampleInfo.SampleStateMask.any,
        SampleInfo.ViewStateMask.any,
        SampleInfo.InstanceStateMask.any,
        "id = %0",
        &.{"42"},
    );
    defer qc.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("id = %0", qc.query_expression);
    try std.testing.expectEqual(@as(usize, 1), qc.get_query_parameters().len);
    try std.testing.expectEqualStrings("42", qc.get_query_parameters()[0]);

    // Mutate parameter
    try qc.set_query_parameters(std.testing.allocator, &.{"999"});
    try std.testing.expectEqualStrings("999", qc.get_query_parameters()[0]);
}
