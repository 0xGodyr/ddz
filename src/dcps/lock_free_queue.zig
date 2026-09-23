//! @file lock_free_queue.zig
//! @brief High-performance, thread-safe SPSC ring buffer used for WaitSet condition signaling.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");

pub fn SpscQueue(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        buffer: [capacity]T = undefined,
        head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        pub fn push(self: *Self, item: T) bool {
            const current_tail = self.tail.load(.acquire);
            const next_tail = (current_tail + 1) % capacity;

            if (next_tail == self.head.load(.acquire)) {
                return false; // Queue full
            }

            self.buffer[current_tail] = item;
            self.tail.store(next_tail, .release);
            return true;
        }

        pub fn pop(self: *Self) ?T {
            const current_head = self.head.load(.acquire);

            if (current_head == self.tail.load(.acquire)) {
                return null; // Queue empty
            }

            const item = self.buffer[current_head];
            self.head.store((current_head + 1) % capacity, .release);
            return item;
        }
    };
}
