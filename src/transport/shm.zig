//! @file shm.zig
//! @brief Shared memory transport subsystem for zero-copy intra-host message exchange.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const builtin = @import("builtin");

pub extern "kernel32" fn CreateFileMappingA(
    hFile: std.os.windows.HANDLE,
    lpFileMappingAttributes: ?*anyopaque,
    flProtect: u32,
    dwMaximumSizeHigh: u32,
    dwMaximumSizeLow: u32,
    lpName: ?[*:0]const u8,
) callconv(.c) ?std.os.windows.HANDLE;

pub extern "kernel32" fn OpenFileMappingA(
    dwDesiredAccess: u32,
    bInheritHandle: std.os.windows.BOOL,
    lpName: ?[*:0]const u8,
) callconv(.c) ?std.os.windows.HANDLE;

pub extern "kernel32" fn MapViewOfFile(
    hFileMappingObject: std.os.windows.HANDLE,
    dwDesiredAccess: u32,
    dwFileOffsetHigh: u32,
    dwFileOffsetLow: u32,
    dwNumberOfBytesToMap: usize,
) callconv(.c) ?*anyopaque;

pub extern "kernel32" fn UnmapViewOfFile(
    lpBaseAddress: *anyopaque,
) callconv(.c) std.os.windows.BOOL;

pub extern "kernel32" fn CloseHandle(
    hObject: std.os.windows.HANDLE,
) callconv(.c) std.os.windows.BOOL;

const PAGE_READWRITE = 0x04;
const FILE_MAP_ALL_ACCESS = 0xF001F;
const INVALID_HANDLE_VALUE = @as(std.os.windows.HANDLE, @ptrFromInt(std.math.maxInt(usize)));

pub const ShmHeader = extern struct {
    write_offset: std.atomic.Value(u32),
    capacity: u32,
};

const c = struct {
    extern "c" fn open(path: [*]const u8, oflag: c_int, mode: c_int) c_int;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn ftruncate(fd: c_int, length: isize) c_int;
    extern "c" fn mmap(addr: ?*anyopaque, len: usize, prot: c_int, flags: c_int, fd: c_int, offset: isize) ?*anyopaque;
    extern "c" fn munmap(addr: *anyopaque, len: usize) c_int;
    extern "c" fn unlink(path: [*]const u8) c_int;
};

pub const ShmSegment = struct {
    handle: if (builtin.os.tag == .windows) std.os.windows.HANDLE else c_int,
    ptr: *anyopaque,
    size: u32,
    header: *ShmHeader,
    data: []u8,
    is_owner: bool,
    path_buf: [256]u8 = std.mem.zeroes([256]u8),
    path_len: u8 = 0,

    pub fn create(name: [:0]const u8, size: u32) !ShmSegment {
        if (builtin.os.tag == .windows) {
            const handle = CreateFileMappingA(INVALID_HANDLE_VALUE, null, PAGE_READWRITE, 0, size, name.ptr) orelse return error.CreateShmFailed;

            const ptr = MapViewOfFile(handle, FILE_MAP_ALL_ACCESS, 0, 0, size) orelse {
                _ = CloseHandle(handle);
                return error.MapShmFailed;
            };

            const header: *ShmHeader = @ptrCast(@alignCast(ptr));
            header.write_offset.store(@sizeOf(ShmHeader), .release);
            header.capacity = size;

            const data_ptr: [*]u8 = @ptrCast(ptr);
            return .{
                .handle = handle,
                .ptr = ptr,
                .size = size,
                .header = header,
                .data = data_ptr[0..size],
                .is_owner = true,
            };
        } else {
            var path_buf: [256]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "/tmp/{s}", .{name});
            path_buf[path.len] = 0;

            const O_RDWR: c_int = 2;
            const O_CREAT: c_int = 64;
            const O_TRUNC: c_int = 512;
            const fd = c.open(path.ptr, O_RDWR | O_CREAT | O_TRUNC, 0o666);
            if (fd < 0) return error.CreateShmFailed;

            if (c.ftruncate(fd, size) != 0) {
                _ = c.close(fd);
                return error.CreateShmFailed;
            }

            const PROT_READ = 1;
            const PROT_WRITE = 2;
            const MAP_SHARED = 1;
            const ptr = c.mmap(null, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
            if (ptr == @as(?*anyopaque, @ptrFromInt(std.math.maxInt(usize)))) {
                _ = c.close(fd);
                return error.MapShmFailed;
            }

            const header: *ShmHeader = @ptrCast(@alignCast(ptr.?));
            header.write_offset.store(@sizeOf(ShmHeader), .release);
            header.capacity = size;

            const data_ptr: [*]u8 = @ptrCast(ptr.?);
            var segment = ShmSegment{
                .handle = fd,
                .ptr = ptr.?,
                .size = size,
                .header = header,
                .data = data_ptr[0..size],
                .is_owner = true,
                .path_len = @intCast(path.len),
            };
            @memcpy(segment.path_buf[0 .. path.len + 1], path_buf[0 .. path.len + 1]);
            return segment;
        }
    }

    pub fn open(name: [:0]const u8) !ShmSegment {
        if (builtin.os.tag == .windows) {
            const handle = OpenFileMappingA(FILE_MAP_ALL_ACCESS, .FALSE, name.ptr) orelse return error.OpenShmFailed;

            const ptr = MapViewOfFile(handle, FILE_MAP_ALL_ACCESS, 0, 0, 0) orelse {
                _ = CloseHandle(handle);
                return error.MapShmFailed;
            };

            const header: *ShmHeader = @ptrCast(@alignCast(ptr));
            const size = header.capacity;

            const data_ptr: [*]u8 = @ptrCast(ptr);
            return .{
                .handle = handle,
                .ptr = ptr,
                .size = size,
                .header = header,
                .data = data_ptr[0..size],
                .is_owner = false,
            };
        } else {
            var path_buf: [256]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "/tmp/{s}", .{name});
            path_buf[path.len] = 0;

            const O_RDWR: c_int = 2;
            const fd = c.open(path.ptr, O_RDWR, 0o666);
            if (fd < 0) return error.OpenShmFailed;

            const PROT_READ = 1;
            const PROT_WRITE = 2;
            const MAP_SHARED = 1;

            const temp_ptr = c.mmap(null, @sizeOf(ShmHeader), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
            if (temp_ptr == @as(?*anyopaque, @ptrFromInt(std.math.maxInt(usize)))) {
                _ = c.close(fd);
                return error.MapShmFailed;
            }

            const temp_header: *ShmHeader = @ptrCast(@alignCast(temp_ptr.?));
            const size = temp_header.capacity;
            _ = c.munmap(temp_ptr.?, @sizeOf(ShmHeader));

            const ptr = c.mmap(null, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
            if (ptr == @as(?*anyopaque, @ptrFromInt(std.math.maxInt(usize)))) {
                _ = c.close(fd);
                return error.MapShmFailed;
            }

            const header: *ShmHeader = @ptrCast(@alignCast(ptr.?));
            const data_ptr: [*]u8 = @ptrCast(ptr.?);
            return .{
                .handle = fd,
                .ptr = ptr.?,
                .size = size,
                .header = header,
                .data = data_ptr[0..size],
                .is_owner = false,
            };
        }
    }

    pub fn deinit(self: *ShmSegment) void {
        if (builtin.os.tag == .windows) {
            _ = UnmapViewOfFile(self.ptr);
            _ = CloseHandle(self.handle);
        } else {
            _ = c.munmap(self.ptr, self.size);
            _ = c.close(self.handle);
            if (self.is_owner and self.path_len > 0) {
                _ = c.unlink(self.path_buf[0 .. self.path_len + 1].ptr);
            }
        }
    }

    pub fn allocate(self: *ShmSegment, len: u32) !u32 {
        var current = self.header.write_offset.load(.acquire);
        while (true) {
            const next_candidate = std.math.add(u32, current, len) catch null;
            if (next_candidate == null or next_candidate.? > self.size) {
                const wrap_candidate = std.math.add(u32, @sizeOf(ShmHeader), len) catch return error.OutOfMemory;
                if (wrap_candidate > self.size) return error.OutOfMemory;

                if (self.header.write_offset.cmpxchgWeak(current, wrap_candidate, .release, .acquire)) |val| {
                    current = val;
                } else {
                    return @sizeOf(ShmHeader);
                }
            } else {
                const next = next_candidate.?;
                if (self.header.write_offset.cmpxchgWeak(current, next, .release, .acquire)) |val| {
                    current = val;
                } else {
                    return current;
                }
            }
        }
    }
};

test "ShmSegment create, allocate, and deinit" {
    var segment = try ShmSegment.create("ddz_test_shm_segment", 4096);
    defer segment.deinit();

    try std.testing.expectEqual(@as(u32, 4096), segment.size);
    try std.testing.expect(segment.is_owner);

    // Allocate 128 bytes
    const off1 = try segment.allocate(128);
    try std.testing.expectEqual(@as(u32, @sizeOf(ShmHeader)), off1);

    // Allocate another 128 bytes
    const off2 = try segment.allocate(128);
    try std.testing.expectEqual(off1 + 128, off2);

    // Writing and reading from the allocated slice
    const slice = segment.data[off1 .. off1 + 128];
    @memset(slice, 0xAA);
    try std.testing.expectEqual(@as(u8, 0xAA), segment.data[off1]);

    // Requesting allocation larger than segment size should fail
    try std.testing.expectError(error.OutOfMemory, segment.allocate(5000));
}
