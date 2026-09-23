//! @file os.zig
//! @brief OS timing and sleep abstractions supporting Windows and POSIX targets.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;

const win = struct {
    extern "kernel32" fn GetTickCount64() callconv(.c) u64;
    extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.c) void;
    extern "kernel32" fn QueryPerformanceFrequency(lpFrequency: *i64) callconv(.c) i32;
    extern "kernel32" fn QueryPerformanceCounter(lpPerformanceCount: *i64) callconv(.c) i32;
};

const posix_c = struct {
    const Timespec = extern struct {
        tv_sec: isize,
        tv_nsec: isize,
    };
    extern "c" fn clock_gettime(clk_id: c_int, tp: *Timespec) c_int;
    extern "c" fn nanosleep(req: *const Timespec, rem: ?*Timespec) c_int;
};

pub fn getTickCount64() u64 {
    if (is_windows) {
        return win.GetTickCount64();
    } else {
        var ts = std.mem.zeroes(posix_c.Timespec);
        _ = posix_c.clock_gettime(1, &ts); // CLOCK_MONOTONIC = 1
        return @as(u64, @intCast(ts.tv_sec)) * 1000 + @as(u64, @intCast(ts.tv_nsec)) / 1000000;
    }
}

pub fn sleepMs(ms: u32) void {
    if (is_windows) {
        win.Sleep(ms);
    } else {
        const req = posix_c.Timespec{
            .tv_sec = @intCast(ms / 1000),
            .tv_nsec = @intCast((ms % 1000) * 1000000),
        };
        _ = posix_c.nanosleep(&req, null);
    }
}

pub fn getNanoTimestamp() i64 {
    if (is_windows) {
        var count: i64 = 0;
        var freq: i64 = 0;
        _ = win.QueryPerformanceFrequency(&freq);
        _ = win.QueryPerformanceCounter(&count);
        if (freq == 0) return 0;
        return @as(i64, @intCast(@divTrunc(@as(i128, count) * 1_000_000_000, @as(i128, freq))));
    } else {
        var ts = std.mem.zeroes(posix_c.Timespec);
        _ = posix_c.clock_gettime(1, &ts); // CLOCK_MONOTONIC = 1
        return @as(i64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(i64, @intCast(ts.tv_nsec));
    }
}
