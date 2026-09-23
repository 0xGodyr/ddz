//! @file wait_set.zig
//! @brief Implements the DDS WaitSet synchronization mechanism for blocking threads until conditions are met.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const builtin = @import("builtin");
const Condition = @import("condition.zig").Condition;
const sleepMs = @import("../os.zig").sleepMs;
pub const SpinLock = struct {
    state: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// @brief Lock.
    pub fn lock(self: *SpinLock) void {
        var spin_count: u32 = 0;
        while (self.state.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
            spin_count += 1;
            if (spin_count >= 1000) {
                sleepMs(0);
                spin_count = 0;
            }
        }
    }

    /// @brief Unlock.
    pub fn unlock(self: *SpinLock) void {
        self.state.store(false, .release);
    }

    /// @brief Try lock.
    pub fn tryLock(self: *SpinLock) bool {
        return self.state.cmpxchgWeak(false, true, .acquire, .monotonic) == null;
    }
};

pub const LockFreeQueue = struct {
    const capacity = 256;
    buffer: [capacity]*Condition = undefined,
    head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    pub fn push(self: *LockFreeQueue, item: *Condition) bool {
        const current_tail = self.tail.load(.acquire);
        const next_tail = (current_tail + 1) % capacity;
        if (next_tail == self.head.load(.acquire)) return false;
        self.buffer[current_tail] = item;
        self.tail.store(next_tail, .release);
        return true;
    }

    pub fn pop(self: *LockFreeQueue) ?*Condition {
        const current_head = self.head.load(.acquire);
        if (current_head == self.tail.load(.acquire)) return null;
        const item = self.buffer[current_head];
        self.head.store((current_head + 1) % capacity, .release);
        return item;
    }
};

pub const WaitSet = struct {
    allocator: std.mem.Allocator,
    mutex: SpinLock = .{},
    attached_conditions: std.ArrayListUnmanaged(*Condition) = .empty,
    triggered_queue: LockFreeQueue = .{},
    queue_mutex: SpinLock = .{},

    /// @brief Initializes a new instance.
    pub fn init(allocator: std.mem.Allocator) WaitSet {
        return .{
            .allocator = allocator,
        };
    }

    /// @brief Deinitializes the instance.
    pub fn deinit(self: *WaitSet) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.attached_conditions.items) |c| {
            if (c.waitset == self) {
                c.waitset = null;
            }
        }
        self.attached_conditions.deinit(self.allocator);
    }

    /// @brief Attach condition.
    pub fn attachCondition(self: *WaitSet, condition: *Condition) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.attached_conditions.append(self.allocator, condition);
        condition.waitset = self;
    }

    /// @brief Detach condition.
    pub fn detachCondition(self: *WaitSet, condition: *Condition) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.attached_conditions.items, 0..) |c, i| {
            if (c == condition) {
                _ = self.attached_conditions.swapRemove(i);
                condition.waitset = null;
                break;
            }
        }
    }

    pub fn Sleep(ms: u32) void {
        sleepMs(ms);
    }

    /// @brief Wait.
    pub fn wait(self: *WaitSet, timeout_ns: u64) ![]*Condition {
        var waited_ns: u64 = 0;
        const sleep_interval_ns = 1_000_000; // 1 ms

        var active: std.ArrayListUnmanaged(*Condition) = .empty;
        errdefer active.deinit(self.allocator);

        while (waited_ns < timeout_ns) {
            self.queue_mutex.lock();
            while (self.triggered_queue.pop()) |c| {
                if (c.evaluate()) {
                    try active.append(self.allocator, c);
                } else {
                    c.trigger_value.store(false, .release);
                }
            }
            self.queue_mutex.unlock();

            if (active.items.len > 0) break;

            sleepMs(1);
            waited_ns += sleep_interval_ns;
        }

        // Final fallback sweep
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.attached_conditions.items) |c| {
            if (c.evaluate()) {
                var found = false;
                for (active.items) |ac| {
                    if (ac == c) found = true;
                }
                if (!found) try active.append(self.allocator, c);
            } else {
                c.trigger_value.store(false, .release);
            }
        }
        return active.toOwnedSlice(self.allocator);
    }

    /// @brief Signal.
    pub fn signal(self: *WaitSet, condition: *Condition) void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        _ = self.triggered_queue.push(condition);
    }
};

// --- TESTS ---

test "WaitSet basic wait and trigger" {
    var ws = WaitSet.init(std.testing.allocator);
    defer ws.deinit();

    var cond = Condition{ .kind = .status_condition };
    try ws.attachCondition(&cond);

    // Trigger on a background thread
    const Context = struct {
        c: *Condition,
        fn trigger(ctx: *@This()) void {
            ctx.c.setTriggerValue(true);
        }
    };
    var ctx = Context{ .c = &cond };
    const t = try std.Thread.spawn(.{}, Context.trigger, .{&ctx});
    defer t.join();

    const triggered = try ws.wait(1000_000_000); // 1000ms
    try std.testing.expectEqual(@as(usize, 1), triggered.len);
    try std.testing.expectEqual(&cond, triggered[0]);
    defer std.testing.allocator.free(triggered);
}

test "WaitSet timeout" {
    var ws = WaitSet.init(std.testing.allocator);
    defer ws.deinit();

    var cond = Condition{ .kind = .status_condition };
    try ws.attachCondition(&cond);

    // Do NOT trigger, expect timeout
    const result = try ws.wait(10);
    try std.testing.expectEqual(@as(usize, 0), result.len);
    defer std.testing.allocator.free(result);
}
