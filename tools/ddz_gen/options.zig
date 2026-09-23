//! @file options.zig
//! @brief Command-line option parsing and configuration settings for ddz_gen.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");

pub const Options = struct {
    output_dir: []const u8 = ".",
    include_dirs: std.ArrayListUnmanaged([]const u8) = .empty,
    package_name: ?[]const u8 = null,
    input_files: std.ArrayListUnmanaged([]const u8) = .empty,
    generate_rpc: bool = false,
    ros2_mode: bool = false,
    reverse_mode: bool = false,
    xmi_mode: bool = false,
    generate_idl: bool = false,
    type_objects: bool = false,
    replace_existing: bool = false,
    no_fmt: bool = false,
    verbose: bool = false,

    pub fn deinit(self: *Options, allocator: std.mem.Allocator) void {
        self.include_dirs.deinit(allocator);
        self.input_files.deinit(allocator);
    }
};
