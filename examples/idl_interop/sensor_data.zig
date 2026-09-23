//! @file sensor_data.zig
//! @brief Generated Zig data structures from sensor_data.idl.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr
//! Generated automatically by ddz_gen. DO NOT EDIT.
const std = @import("std");
const ddz = @import("ddz");

pub const SensorNetwork = struct {
    pub const SensorType = enum(u32) {
        TEMPERATURE = 0,
        PRESSURE = 1,
        ACCELEROMETER = 2,
    };

    pub const SensorReading = struct {
        sensor_id: i32 = 0,
        type: SensorType = undefined,
        reading: f64 = 0.0,
        calibration_factors: [4]f32 = undefined,
        device_name: [32:0]u8 = std.mem.zeroes([32:0]u8),

        pub const ddz_keys = [_][]const u8{
            "sensor_id",
        };
    };
};
