//! @file sample_info.zig
//! @brief Metadata structures attached to received data, providing sample state, view state, and source timestamps.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");

/// @brief Sample state kind.
pub const SampleStateKind = enum {
    read,
    not_read,
};

/// @brief View state kind.
pub const ViewStateKind = enum {
    new,
    not_new,
};

/// @brief Instance state kind.
pub const InstanceStateKind = enum {
    alive,
    not_alive_disposed,
    not_alive_no_writers,
};

/// @brief Mask of Sample states.
pub const SampleStateMask = struct {
    read: bool = false,
    not_read: bool = false,

    pub const any = SampleStateMask{ .read = true, .not_read = true };
};

/// @brief Mask of View states.
pub const ViewStateMask = struct {
    new: bool = false,
    not_new: bool = false,

    pub const any = ViewStateMask{ .new = true, .not_new = true };
};

/// @brief Mask of Instance states.
pub const InstanceStateMask = struct {
    alive: bool = false,
    not_alive_disposed: bool = false,
    not_alive_no_writers: bool = false,

    pub const any = InstanceStateMask{ .alive = true, .not_alive_disposed = true, .not_alive_no_writers = true };
};

/// @brief Information accompanying each sample read or taken.
pub const SampleInfo = struct {
    sample_state: SampleStateKind,
    view_state: ViewStateKind,
    instance_state: InstanceStateKind,
    disposed_generation_count: u32,
    no_writers_generation_count: u32,
    sample_rank: u32,
    generation_rank: u32,
    absolute_generation_rank: u32,
    source_timestamp: i64,
    instance_handle: [16]u8,
    publication_handle: [16]u8,
    valid_data: bool,
};

/// @brief Typed sample structure returned by read/take operations.
pub fn DataSample(comptime T: type) type {
    return struct {
        data: T,
        info: SampleInfo,
    };
}
