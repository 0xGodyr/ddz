//! @file history_cache.zig
//! @brief High-performance O(1) eviction cache managing data samples, fragments, and QoS lifecycle policies.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const types = @import("types.zig");
const SampleInfo = @import("../dcps/sample_info.zig");
const Qos = @import("../dcps/qos.zig");
const os = @import("../os.zig");
const getTickCount64 = os.getTickCount64;
const sleepMs = os.sleepMs;

/// @brief Change kind structure.
pub const ChangeKind = enum {
    ALIVE,
    NOT_ALIVE_DISPOSED,
    NOT_ALIVE_UNREGISTERED,
};

/// @brief Cache change structure.
pub const CacheChange = struct {
    kind: ChangeKind,
    writer_guid: types.GUID_t,
    instance_handle: types.InstanceHandle_t,
    sequence_number: types.SequenceNumber_t,
    data_value: []const u8,
    is_pooled: bool = false,
    withheld: bool = false,
    coherent_set_id: u64 = 0,
    related_sample_identity: ?types.SampleIdentity_t = null,
    source_timestamp_ms: i64 = 0,
};

/// @brief Payload block structure.
pub const PayloadBlock = struct {
    bytes: [2048]u8 align(8),
};

/// @brief Partial sample structure.
pub const PartialSample = struct {
    writer_guid: types.GUID_t,
    sequence_number: types.SequenceNumber_t,
    buffer: []u8,
    received_bytes: u32,
    received_frags: u64,
    timestamp_ms: i64 = 0,
};

/// @brief Node for O(1) Linked List History Cache.
pub const CacheChangeNode = struct {
    change: CacheChange,
    global_prev: ?*CacheChangeNode = null,
    global_next: ?*CacheChangeNode = null,
    instance_prev: ?*CacheChangeNode = null,
    instance_next: ?*CacheChangeNode = null,
    sample_state: SampleInfo.SampleStateKind = .not_read,
};

/// @brief Instance Pointers for O(1) access.
pub const InstancePointers = struct {
    head: ?*CacheChangeNode = null,
    tail: ?*CacheChangeNode = null,
    count: usize = 0,
    view_state: SampleInfo.ViewStateKind = .new,
    instance_state: SampleInfo.InstanceStateKind = .alive,
    disposed_generation_count: u32 = 0,
    no_writers_generation_count: u32 = 0,
    last_accepted_timestamp_ms: i64 = 0,
    not_alive_timestamp_ms: i64 = 0,
};

/// @brief History cache structure.
pub const HistoryCache = struct {
    allocator: std.mem.Allocator,
    lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    node_pool: std.heap.MemoryPool(CacheChangeNode),
    payload_pool: std.heap.MemoryPool(PayloadBlock),

    global_head: ?*CacheChangeNode = null,
    global_tail: ?*CacheChangeNode = null,
    global_count: usize = 0,

    instance_map: std.AutoHashMapUnmanaged(types.InstanceHandle_t, InstancePointers) = .empty,
    partial_samples: std.ArrayListUnmanaged(PartialSample) = .empty,

    history_qos: Qos.HistoryQosPolicy = .{},
    resource_limits_qos: Qos.ResourceLimitsQosPolicy = .{},
    lifespan_qos: Qos.LifespanQosPolicy = .{},
    time_based_filter_qos: Qos.TimeBasedFilterQosPolicy = .{},
    destination_order_qos: Qos.DestinationOrderQosPolicy = .{},
    reader_data_lifecycle_qos: Qos.ReaderDataLifecycleQosPolicy = .{},
    persistent_file_path: ?[]const u8 = null,

    /// @brief Initializes a new instance.
    pub fn init(
        allocator: std.mem.Allocator,
        history_qos: Qos.HistoryQosPolicy,
        resource_limits_qos: Qos.ResourceLimitsQosPolicy,
        lifespan_qos: Qos.LifespanQosPolicy,
        time_based_filter_qos: Qos.TimeBasedFilterQosPolicy,
        destination_order_qos: Qos.DestinationOrderQosPolicy,
        reader_data_lifecycle_qos: Qos.ReaderDataLifecycleQosPolicy,
        persistent_file_path: ?[]const u8,
    ) HistoryCache {
        return .{
            .allocator = allocator,
            .node_pool = .{ .arena_state = .{}, .free_list = .{} },
            .payload_pool = .{ .arena_state = .{}, .free_list = .{} },
            .history_qos = history_qos,
            .resource_limits_qos = resource_limits_qos,
            .lifespan_qos = lifespan_qos,
            .time_based_filter_qos = time_based_filter_qos,
            .destination_order_qos = destination_order_qos,
            .reader_data_lifecycle_qos = reader_data_lifecycle_qos,
            .persistent_file_path = persistent_file_path,
        };
    }

    pub fn acquireLock(self: *HistoryCache) void {
        var spin_count: u32 = 0;
        while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
            spin_count += 1;
            if (spin_count >= 1000) {
                sleepMs(0);
                spin_count = 0;
            }
        }
    }

    pub fn releaseLock(self: *HistoryCache) void {
        self.lock.store(false, .release);
    }

    /// @brief Deinitializes the instance.
    pub fn releaseCoherentSet(self: *HistoryCache, coherent_set_id: u64) void {
        self.acquireLock();
        defer self.releaseLock();

        var current = self.global_head;
        while (current) |node| : (current = node.global_next) {
            if (node.change.withheld and node.change.coherent_set_id == coherent_set_id) {
                node.change.withheld = false;
            }
        }
    }

    pub fn deinit(self: *@This()) void {
        self.acquireLock();
        defer self.releaseLock();

        var current = self.global_head;
        while (current) |node| {
            const next = node.global_next;
            self.freeNodeMemory(node);
            self.node_pool.destroy(node);
            current = next;
        }

        self.instance_map.deinit(self.allocator);
        self.node_pool.deinit(self.allocator);
        self.payload_pool.deinit(self.allocator);

        for (self.partial_samples.items) |p| {
            self.allocator.free(p.buffer);
        }
        self.partial_samples.deinit(self.allocator);
    }

    pub fn freeNodeMemory(self: *HistoryCache, node: *CacheChangeNode) void {
        if (node.change.is_pooled) {
            const ptr: *PayloadBlock = @ptrCast(@alignCast(@constCast(node.change.data_value.ptr)));
            self.payload_pool.destroy(ptr);
        } else if (node.change.data_value.len > 0) {
            self.allocator.free(node.change.data_value);
        }
    }

    /// @brief Get history cache length.
    pub fn getLen(self: *const HistoryCache) usize {
        const mut_self: *HistoryCache = @constCast(self);
        mut_self.acquireLock();
        defer mut_self.releaseLock();
        return self.global_count;
    }

    /// @brief Remove specific node in O(1).
    pub fn unlinkNode(self: *HistoryCache, node: *CacheChangeNode) void {
        // Unlink global
        if (node.global_prev) |p| p.global_next = node.global_next else self.global_head = node.global_next;
        if (node.global_next) |n| n.global_prev = node.global_prev else self.global_tail = node.global_prev;
        self.global_count -= 1;

        // Unlink instance
        if (self.instance_map.getPtr(node.change.instance_handle)) |inst| {
            if (node.instance_prev) |p| p.instance_next = node.instance_next else inst.head = node.instance_next;
            if (node.instance_next) |n| n.instance_prev = node.instance_prev else inst.tail = node.instance_prev;
            inst.count -= 1;
            if (inst.count == 0 and (inst.instance_state == .not_alive_disposed or inst.instance_state == .not_alive_no_writers)) {
                _ = self.instance_map.remove(node.change.instance_handle);
            }
        }
    }

    pub fn removeNode(self: *HistoryCache, node: *CacheChangeNode) void {
        self.unlinkNode(node);

        self.freeNodeMemory(node);
        self.node_pool.destroy(node);
    }

    pub fn enforceLifecycleQos(self: *HistoryCache) void {
        if (self.reader_data_lifecycle_qos.autopurge_nowriter_samples_delay_ms != 0xFFFFFFFF or
            self.reader_data_lifecycle_qos.autopurge_disposed_samples_delay_ms != 0xFFFFFFFF)
        {
            const now = @as(i64, @intCast(GetTickCount64()));

            var to_remove = std.ArrayListUnmanaged(types.InstanceHandle_t).empty;
            defer to_remove.deinit(self.allocator);

            var iter = self.instance_map.iterator();
            while (iter.next()) |entry| {
                const inst = entry.value_ptr.*;
                if (inst.instance_state == .not_alive_no_writers and
                    self.reader_data_lifecycle_qos.autopurge_nowriter_samples_delay_ms != 0xFFFFFFFF)
                {
                    if (now - inst.not_alive_timestamp_ms >= self.reader_data_lifecycle_qos.autopurge_nowriter_samples_delay_ms) {
                        var curr = inst.head;
                        while (curr) |node| {
                            const next = node.instance_next;
                            self.removeNode(node);
                            curr = next;
                        }
                        to_remove.append(self.allocator, entry.key_ptr.*) catch {};
                    }
                } else if (inst.instance_state == .not_alive_disposed and
                    self.reader_data_lifecycle_qos.autopurge_disposed_samples_delay_ms != 0xFFFFFFFF)
                {
                    if (now - inst.not_alive_timestamp_ms >= self.reader_data_lifecycle_qos.autopurge_disposed_samples_delay_ms) {
                        var curr = inst.head;
                        while (curr) |node| {
                            const next = node.instance_next;
                            self.removeNode(node);
                            curr = next;
                        }
                        to_remove.append(self.allocator, entry.key_ptr.*) catch {};
                    }
                }
            }

            for (to_remove.items) |h| {
                _ = self.instance_map.remove(h);
            }
        }
    }

    /// @brief Enforce qos limits.
    fn enforceQosLimits(self: *HistoryCache, instance: types.InstanceHandle_t) !void {
        // Enforce Lifespan QoS (time-based eviction)
        if (self.lifespan_qos.duration_ms != 0xFFFFFFFF) {
            const now = @as(i64, @intCast(GetTickCount64()));
            var current = self.global_head;
            while (current) |node| {
                const next = node.global_next;
                if (now - node.change.source_timestamp_ms > self.lifespan_qos.duration_ms) {
                    self.removeNode(node);
                }
                current = next;
            }
        }

        // Enforce History depth if KEEP_LAST (per instance) in O(1)
        if (self.history_qos.kind == .keep_last) {
            const depth: usize = @intCast(self.history_qos.depth);
            if (self.instance_map.get(instance)) |inst| {
                var current = inst.head;
                var current_count = inst.count;
                while (current_count > depth and current != null) {
                    const next = current.?.instance_next;
                    self.removeNode(current.?);
                    current = next;
                    current_count -= 1;
                }
            }
        }

        // Enforce ResourceLimits max_instances
        if (self.resource_limits_qos.max_instances != -1) {
            const max_instances: usize = @intCast(self.resource_limits_qos.max_instances);
            if (self.instance_map.count() > max_instances) {
                return error.ResourceLimitReached;
            }
        }

        // Enforce ResourceLimits max_samples_per_instance
        if (self.resource_limits_qos.max_samples_per_instance != -1) {
            const max_samples_per_instance: usize = @intCast(self.resource_limits_qos.max_samples_per_instance);
            if (self.instance_map.get(instance)) |inst| {
                if (self.history_qos.kind == .keep_all and inst.count > max_samples_per_instance) {
                    return error.ResourceLimitReached;
                }
                var current = inst.head;
                var current_count = inst.count;
                while (current_count > max_samples_per_instance and current != null) {
                    const next = current.?.instance_next;
                    self.removeNode(current.?);
                    current = next;
                    current_count -= 1;
                }
            }
        }

        // Enforce ResourceLimits max_samples (global) in O(1)
        if (self.resource_limits_qos.max_samples != -1) {
            const max_samples: usize = @intCast(self.resource_limits_qos.max_samples);
            if (self.history_qos.kind == .keep_all and self.global_count > max_samples) {
                return error.ResourceLimitReached;
            }
            while (self.global_count > max_samples) {
                if (self.global_head) |head| {
                    self.removeNode(head);
                } else break;
            }
        }
    }

    /// @brief Get tick count64.
    pub fn GetTickCount64() u64 {
        return getTickCount64();
    }

    /// @brief Add change.
    fn readIntU32(buf: []const u8, offset: *usize) u32 {
        const val = std.mem.readInt(u32, buf[offset.* .. offset.* + 4][0..4], .little);
        offset.* += 4;
        return val;
    }

    fn readIntI32(buf: []const u8, offset: *usize) i32 {
        const val = std.mem.readInt(i32, buf[offset.* .. offset.* + 4][0..4], .little);
        offset.* += 4;
        return val;
    }

    fn readIntI64(buf: []const u8, offset: *usize) i64 {
        const val = std.mem.readInt(i64, buf[offset.* .. offset.* + 8][0..8], .little);
        offset.* += 8;
        return val;
    }

    pub fn saveToDisk(self: *HistoryCache) !void {
        if (self.persistent_file_path == null) return;
        const io = std.Options.debug_io;
        var file = try std.Io.Dir.cwd().createFile(io, self.persistent_file_path.?, .{});
        defer file.close(io);

        var out_list = std.ArrayListUnmanaged(u8).empty;
        defer out_list.deinit(self.allocator);

        try out_list.appendSlice(self.allocator, "DDZC");

        var u32_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &u32_buf, @intCast(self.global_count), .little);
        try out_list.appendSlice(self.allocator, &u32_buf);

        var current = self.global_head;
        while (current) |node| {
            const kind_val: u8 = switch (node.change.kind) {
                .ALIVE => 0,
                .NOT_ALIVE_DISPOSED => 1,
                .NOT_ALIVE_UNREGISTERED => 2,
            };
            try out_list.append(self.allocator, kind_val);

            try out_list.appendSlice(self.allocator, &node.change.writer_guid.prefix);
            try out_list.appendSlice(self.allocator, &node.change.writer_guid.entity_id.entity_key);
            try out_list.append(self.allocator, node.change.writer_guid.entity_id.entity_kind);

            try out_list.appendSlice(self.allocator, &node.change.instance_handle);

            std.mem.writeInt(i32, &u32_buf, node.change.sequence_number.high, .little);
            try out_list.appendSlice(self.allocator, &u32_buf);

            std.mem.writeInt(u32, &u32_buf, node.change.sequence_number.low, .little);
            try out_list.appendSlice(self.allocator, &u32_buf);

            var i64_buf: [8]u8 = undefined;
            std.mem.writeInt(i64, &i64_buf, node.change.source_timestamp_ms, .little);
            try out_list.appendSlice(self.allocator, &i64_buf);

            std.mem.writeInt(u32, &u32_buf, @intCast(node.change.data_value.len), .little);
            try out_list.appendSlice(self.allocator, &u32_buf);

            try out_list.appendSlice(self.allocator, node.change.data_value);

            current = node.global_next;
        }

        _ = try file.writeStreamingAll(io, out_list.items);
    }

    pub fn loadFromDisk(self: *HistoryCache) !void {
        if (self.persistent_file_path == null) return;
        const io = std.Options.debug_io;
        var file = std.Io.Dir.cwd().openFile(io, self.persistent_file_path.?, .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer file.close(io);

        const file_size = try file.length(io);
        if (file_size < 8) return error.InvalidFormat;
        const data = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(data);
        const bytes_read = try file.readPositionalAll(io, data, 0);
        if (bytes_read != file_size) return error.UnexpectedEndOfFile;
        if (!std.mem.eql(u8, data[0..4], "DDZC")) return error.InvalidFormat;

        var offset: usize = 4;
        const count = readIntU32(data, &offset);

        var i: u32 = 0;
        while (i < count) : (i += 1) {
            if (offset + 53 > data.len) return error.InvalidFormat;

            const kind_val = data[offset];
            offset += 1;
            const kind: ChangeKind = switch (kind_val) {
                0 => .ALIVE,
                1 => .NOT_ALIVE_DISPOSED,
                2 => .NOT_ALIVE_UNREGISTERED,
                else => return error.InvalidFormat,
            };

            var writer_guid: types.GUID_t = undefined;
            @memcpy(&writer_guid.prefix, data[offset .. offset + 12]);
            offset += 12;
            @memcpy(&writer_guid.entity_id.entity_key, data[offset .. offset + 3]);
            offset += 3;
            writer_guid.entity_id.entity_kind = data[offset];
            offset += 1;

            var instance_handle: [16]u8 = undefined;
            @memcpy(&instance_handle, data[offset .. offset + 16]);
            offset += 16;

            const sn_high = readIntI32(data, &offset);
            const sn_low = readIntU32(data, &offset);
            const timestamp = readIntI64(data, &offset);

            const payload_len = readIntU32(data, &offset);
            if (offset + payload_len > data.len) return error.InvalidFormat;
            const payload = data[offset .. offset + payload_len];
            offset += payload_len;

            // Add change (addChange copies data_value, so no extra allocation here)
            try self.addChange(.{
                .kind = kind,
                .writer_guid = writer_guid,
                .instance_handle = instance_handle,
                .sequence_number = .{ .high = sn_high, .low = sn_low },
                .source_timestamp_ms = timestamp,
                .data_value = payload,
            });
        }
    }

    pub fn addChange(self: *HistoryCache, change: CacheChange) !void {
        var new_change = change;
        if (new_change.source_timestamp_ms == 0) {
            new_change.source_timestamp_ms = @as(i64, @intCast(GetTickCount64()));
        }

        self.acquireLock();
        defer self.releaseLock();

        const gop = try self.instance_map.getOrPut(self.allocator, new_change.instance_handle);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }

        if (self.time_based_filter_qos.minimum_separation_ms > 0) {
            const now = @as(i64, @intCast(GetTickCount64()));
            if (now - gop.value_ptr.last_accepted_timestamp_ms < self.time_based_filter_qos.minimum_separation_ms) {
                return;
            }
        }

        if (self.destination_order_qos.kind == .by_source_timestamp) {
            if (gop.value_ptr.tail) |inst_tail| {
                if (new_change.source_timestamp_ms < inst_tail.change.source_timestamp_ms) {
                    return;
                }
            }
        }

        if (change.data_value.len == 0) {
            new_change.data_value = &.{};
            new_change.is_pooled = false;
        } else if (change.data_value.len <= 2048) {
            const block = try self.payload_pool.create(self.allocator);
            @memcpy(block.bytes[0..change.data_value.len], change.data_value);
            new_change.data_value = block.bytes[0..change.data_value.len];
            new_change.is_pooled = true;
        } else {
            new_change.data_value = try self.allocator.dupe(u8, change.data_value);
            new_change.is_pooled = false;
        }

        const node = self.node_pool.create(self.allocator) catch |err| {
            if (new_change.is_pooled) {
                const ptr: *PayloadBlock = @ptrCast(@alignCast(@constCast(new_change.data_value.ptr)));
                self.payload_pool.destroy(ptr);
            } else if (new_change.data_value.len > 0) {
                self.allocator.free(new_change.data_value);
            }
            return err;
        };
        node.* = .{
            .change = new_change,
            .global_prev = self.global_tail,
        };

        // Link globally
        if (self.global_tail) |tail| {
            tail.global_next = node;
        } else {
            self.global_head = node;
        }
        self.global_tail = node;
        self.global_count += 1;

        // Link instance
        if (new_change.kind == .NOT_ALIVE_DISPOSED) {
            if (gop.value_ptr.instance_state == .alive) {
                gop.value_ptr.disposed_generation_count += 1;
            }
            gop.value_ptr.instance_state = .not_alive_disposed;
            gop.value_ptr.not_alive_timestamp_ms = @as(i64, @intCast(GetTickCount64()));
        } else if (new_change.kind == .NOT_ALIVE_UNREGISTERED) {
            if (gop.value_ptr.instance_state == .alive) {
                gop.value_ptr.no_writers_generation_count += 1;
            }
            gop.value_ptr.instance_state = .not_alive_no_writers;
            gop.value_ptr.not_alive_timestamp_ms = @as(i64, @intCast(GetTickCount64()));
        } else {
            gop.value_ptr.instance_state = .alive;
        }
        gop.value_ptr.last_accepted_timestamp_ms = @as(i64, @intCast(GetTickCount64()));
        const inst = gop.value_ptr;
        node.instance_prev = inst.tail;
        if (inst.tail) |tail| {
            tail.instance_next = node;
        } else {
            inst.head = node;
        }
        inst.tail = node;
        inst.count += 1;

        self.enforceQosLimits(new_change.instance_handle) catch |err| {
            self.removeNode(node);
            return err;
        };
        self.saveToDisk() catch |err| {
            self.removeNode(node);
            return err;
        };
    }

    /// @brief Add fragment.
    pub fn addFragment(self: *HistoryCache, change_kind: ChangeKind, writer_guid: types.GUID_t, sn: types.SequenceNumber_t, frag_start: u32, frag_size: u16, sample_size: u32, payload: []const u8) !bool {
        if (frag_start == 0) return error.InvalidFragment;

        self.acquireLock();
        defer self.releaseLock();

        const now = @as(i64, @intCast(GetTickCount64()));

        // Prune stale uncompleted partial samples older than 10 seconds
        var p_scan: usize = 0;
        while (p_scan < self.partial_samples.items.len) {
            const p = &self.partial_samples.items[p_scan];
            if (p.timestamp_ms > 0 and now - p.timestamp_ms > 10000) {
                self.allocator.free(p.buffer);
                _ = self.partial_samples.swapRemove(p_scan);
            } else {
                p_scan += 1;
            }
        }

        var found_idx: ?usize = null;
        for (self.partial_samples.items, 0..) |*p, i| {
            if (p.sequence_number.high == sn.high and p.sequence_number.low == sn.low and
                std.meta.eql(p.writer_guid, writer_guid))
            {
                found_idx = i;
                break;
            }
        }

        if (found_idx == null) {
            const buffer = try self.allocator.alloc(u8, sample_size);
            errdefer self.allocator.free(buffer);
            try self.partial_samples.append(self.allocator, .{
                .writer_guid = writer_guid,
                .sequence_number = sn,
                .buffer = buffer,
                .received_bytes = 0,
                .received_frags = 0,
                .timestamp_ms = now,
            });
            found_idx = self.partial_samples.items.len - 1;
        }

        const partial = &self.partial_samples.items[found_idx.?];
        const frag_idx = frag_start - 1;
        const offset = frag_idx * frag_size;

        if (frag_idx < 64) {
            const frag_mask = @as(u64, 1) << @intCast(frag_idx);
            if ((partial.received_frags & frag_mask) == 0) {
                if (offset + payload.len <= partial.buffer.len) {
                    @memcpy(partial.buffer[offset .. offset + payload.len], payload);
                    partial.received_bytes += @intCast(payload.len);
                    partial.received_frags |= frag_mask;
                }
            }
        } else {
            if (offset + payload.len <= partial.buffer.len) {
                @memcpy(partial.buffer[offset .. offset + payload.len], payload);
                partial.received_bytes += @intCast(payload.len);
            }
        }

        if (partial.received_bytes >= sample_size) {
            const new_change = CacheChange{
                .kind = change_kind,
                .writer_guid = partial.writer_guid,
                .instance_handle = std.mem.zeroes([16]u8),
                .sequence_number = partial.sequence_number,
                .data_value = partial.buffer,
                .is_pooled = false,
                .source_timestamp_ms = @as(i64, @intCast(GetTickCount64())),
            };

            const gop = try self.instance_map.getOrPut(self.allocator, new_change.instance_handle);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{};
            }

            var drop = false;
            if (self.time_based_filter_qos.minimum_separation_ms > 0) {
                if (now - gop.value_ptr.last_accepted_timestamp_ms < self.time_based_filter_qos.minimum_separation_ms) {
                    drop = true;
                }
            }

            if (self.destination_order_qos.kind == .by_source_timestamp) {
                if (gop.value_ptr.tail) |inst_tail| {
                    if (new_change.source_timestamp_ms < inst_tail.change.source_timestamp_ms) {
                        drop = true;
                    }
                }
            }

            if (drop) {
                self.allocator.free(partial.buffer);
                _ = self.partial_samples.swapRemove(found_idx.?);
                return true;
            }

            const node = try self.node_pool.create(self.allocator);
            node.* = .{
                .change = new_change,
                .global_prev = self.global_tail,
            };

            if (self.global_tail) |tail| {
                tail.global_next = node;
            } else {
                self.global_head = node;
            }
            self.global_tail = node;
            self.global_count += 1;

            if (new_change.kind == .NOT_ALIVE_DISPOSED) {
                if (gop.value_ptr.instance_state == .alive) {
                    gop.value_ptr.disposed_generation_count += 1;
                }
                gop.value_ptr.instance_state = .not_alive_disposed;
                gop.value_ptr.not_alive_timestamp_ms = @as(i64, @intCast(GetTickCount64()));
            } else if (new_change.kind == .NOT_ALIVE_UNREGISTERED) {
                if (gop.value_ptr.instance_state == .alive) {
                    gop.value_ptr.no_writers_generation_count += 1;
                }
                gop.value_ptr.instance_state = .not_alive_no_writers;
                gop.value_ptr.not_alive_timestamp_ms = @as(i64, @intCast(GetTickCount64()));
            } else {
                gop.value_ptr.instance_state = .alive;
            }
            gop.value_ptr.last_accepted_timestamp_ms = @as(i64, @intCast(GetTickCount64()));
            const inst = gop.value_ptr;
            node.instance_prev = inst.tail;
            if (inst.tail) |tail| {
                tail.instance_next = node;
            } else {
                inst.head = node;
            }
            inst.tail = node;
            inst.count += 1;

            _ = self.partial_samples.swapRemove(found_idx.?);
            self.enforceQosLimits(new_change.instance_handle) catch |err| {
                self.removeNode(node);
                return err;
            };
            self.saveToDisk() catch |err| {
                self.removeNode(node);
                return err;
            };
            return true;
        }
        return false;
    }

    /// @brief Get change.
    pub fn getChange(self: *const HistoryCache, seq_num: types.SequenceNumber_t) ?CacheChange {
        const lock_ptr: *std.atomic.Value(bool) = @constCast(&self.lock);
        while (lock_ptr.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
        defer lock_ptr.store(false, .release);

        var current = self.global_tail;
        while (current) |node| {
            const sn = node.change.sequence_number;
            if (sn.high == seq_num.high and sn.low == seq_num.low) {
                if (node.change.withheld) return null;
                return node.change;
            }
            current = node.global_prev;
        }
        return null;
    }
};

// --- TESTS ---
test "HistoryCache basic add and traversal" {
    const allocator = std.testing.allocator;
    var cache = HistoryCache.init(allocator, .{}, .{}, .{}, .{}, .{}, .{}, null);
    defer cache.deinit();

    const change = CacheChange{
        .kind = .ALIVE,
        .writer_guid = std.mem.zeroes(types.GUID_t),
        .instance_handle = std.mem.zeroes([16]u8),
        .sequence_number = .{ .high = 0, .low = 1 },
        .data_value = "hello",
    };

    try cache.addChange(change);
    try std.testing.expectEqual(@as(u32, 1), cache.getLen());

    var count: u32 = 0;
    var current = cache.global_head;
    while (current) |node| : (current = node.global_next) {
        try std.testing.expectEqualStrings("hello", node.change.data_value);
        count += 1;
    }
    try std.testing.expectEqual(@as(u32, 1), count);
}

test "HistoryCache depth limit enforcement" {
    const allocator = std.testing.allocator;
    var cache = HistoryCache.init(allocator, .{ .depth = 2 }, .{}, .{}, .{}, .{}, .{}, null);
    defer cache.deinit();

    try cache.addChange(.{
        .kind = .ALIVE,
        .writer_guid = std.mem.zeroes(types.GUID_t),
        .instance_handle = std.mem.zeroes([16]u8),
        .sequence_number = .{ .high = 0, .low = 1 },
        .data_value = "1",
    });
    try cache.addChange(.{
        .kind = .ALIVE,
        .writer_guid = std.mem.zeroes(types.GUID_t),
        .instance_handle = std.mem.zeroes([16]u8),
        .sequence_number = .{ .high = 0, .low = 2 },
        .data_value = "2",
    });
    try cache.addChange(.{
        .kind = .ALIVE,
        .writer_guid = std.mem.zeroes(types.GUID_t),
        .instance_handle = std.mem.zeroes([16]u8),
        .sequence_number = .{ .high = 0, .low = 3 },
        .data_value = "3",
    });

    try std.testing.expectEqual(@as(u32, 2), cache.getLen());

    // First should be "2", then "3"
    var current = cache.global_head;
    try std.testing.expect(current != null);
    try std.testing.expectEqualStrings("2", current.?.change.data_value);

    current = current.?.global_next;
    try std.testing.expect(current != null);
    try std.testing.expectEqualStrings("3", current.?.change.data_value);
}

test "HistoryCache remove change and pointer stability" {
    const allocator = std.testing.allocator;
    var cache = HistoryCache.init(allocator, .{ .depth = 10 }, .{}, .{}, .{}, .{}, .{}, null);
    defer cache.deinit();

    const change = CacheChange{
        .kind = .ALIVE,
        .writer_guid = std.mem.zeroes(types.GUID_t),
        .instance_handle = std.mem.zeroes([16]u8),
        .sequence_number = .{ .high = 0, .low = 1 },
        .data_value = "hello memory",
    };

    try cache.addChange(change);
    try std.testing.expectEqual(@as(u32, 1), cache.getLen());

    const head = cache.global_head.?;
    const data_ptr = head.change.data_value.ptr;

    // Add another
    try cache.addChange(.{
        .kind = .ALIVE,
        .writer_guid = std.mem.zeroes(types.GUID_t),
        .instance_handle = std.mem.zeroes([16]u8),
        .sequence_number = .{ .high = 0, .low = 2 },
        .data_value = "another",
    });

    try std.testing.expectEqual(@as(u32, 2), cache.getLen());
    // The previous pointer should still be perfectly valid and unchanged
    try std.testing.expectEqual(data_ptr, cache.global_head.?.change.data_value.ptr);

    cache.removeNode(cache.global_head.?);
    try std.testing.expectEqual(@as(u32, 1), cache.getLen());
}

test "HistoryCache large payloads" {
    const allocator = std.testing.allocator;
    var cache = HistoryCache.init(allocator, .{}, .{}, .{}, .{}, .{}, .{}, null);
    defer cache.deinit();

    const large_data = try allocator.alloc(u8, 3000);
    defer allocator.free(large_data);
    @memset(large_data, 0xAB);

    try cache.addChange(.{
        .kind = .ALIVE,
        .writer_guid = std.mem.zeroes(types.GUID_t),
        .instance_handle = std.mem.zeroes([16]u8),
        .sequence_number = .{ .high = 0, .low = 1 },
        .data_value = large_data,
    });

    try std.testing.expectEqual(@as(u32, 1), cache.getLen());
    try std.testing.expectEqual(@as(usize, 3000), cache.global_head.?.change.data_value.len);
    try std.testing.expectEqual(@as(u8, 0xAB), cache.global_head.?.change.data_value[0]);
}
