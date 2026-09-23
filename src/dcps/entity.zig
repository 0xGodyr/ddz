//! @file entity.zig
//! @brief Base class for all DDS entities, managing status conditions, enablement states, and instance handles.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const StatusCondition = @import("condition.zig").StatusCondition;

pub const Entity = struct {
    is_enabled: bool = false,
    status_condition: ?*StatusCondition = null,
    instance_handle: [16]u8 = std.mem.zeroes([16]u8),

    allocator: std.mem.Allocator,
    ptr: *anyopaque,
    enable_fn: *const fn (ptr: *anyopaque) anyerror!void,

    pub fn init(allocator: std.mem.Allocator, ptr: *anyopaque, enable_fn: *const fn (ptr: *anyopaque) anyerror!void) Entity {
        return .{
            .allocator = allocator,
            .ptr = ptr,
            .enable_fn = enable_fn,
        };
    }

    pub fn deinit(self: *Entity) void {
        if (self.status_condition) |sc| {
            if (sc.condition.waitset) |ws| {
                ws.detachCondition(&sc.condition);
            }
            self.allocator.destroy(sc);
            self.status_condition = null;
        }
    }

    pub fn enable(self: *Entity) !void {
        if (self.is_enabled) return;
        try self.enable_fn(self.ptr);
        self.is_enabled = true;
    }

    pub fn getInstanceHandle(self: *Entity) [16]u8 {
        return self.instance_handle;
    }

    pub fn getStatusCondition(self: *Entity) !*StatusCondition {
        if (self.status_condition == null) {
            const sc = try self.allocator.create(StatusCondition);
            sc.* = StatusCondition.init(self.ptr);
            self.status_condition = sc;
        }
        return self.status_condition.?;
    }
};

test "Entity initialization, enable, and status condition" {
    const Dummy = struct {
        enabled: bool = false,
        fn enableImpl(ptr: *anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.enabled = true;
        }
    };
    var dummy = Dummy{};
    var entity = Entity.init(std.testing.allocator, &dummy, Dummy.enableImpl);
    defer entity.deinit();

    try std.testing.expect(!entity.is_enabled);
    try entity.enable();
    try std.testing.expect(entity.is_enabled);
    try std.testing.expect(dummy.enabled);

    const sc = try entity.getStatusCondition();
    try std.testing.expect(sc.condition.kind == .status_condition);
}
