//! @file ping_msg.zig
//! @brief Latency and sequence payload definition for ddz_ping benchmark traffic.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

pub const PingMsg = struct {
    sequence_num: u32,
    timestamp_ns: i64,
    payload_len: u32,
    payload: [1024]u8, // Fixed size to satisfy the simple serializer, we will send up to payload_len
};
