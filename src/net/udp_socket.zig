//! @file udp_socket.zig
//! @brief High-performance non-blocking UDP socket wrapper supporting unicast and multicast IO.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const builtin = @import("builtin");
const rtps = @import("../root.zig").rtps;

const is_windows = builtin.os.tag == .windows;

const win = struct {
    extern "ws2_32" fn socket(af: i32, type_kind: i32, protocol: i32) callconv(.c) usize;
    extern "ws2_32" fn closesocket(s: usize) callconv(.c) i32;
    extern "ws2_32" fn bind(s: usize, name: *const anyopaque, namelen: i32) callconv(.c) i32;
    extern "ws2_32" fn sendto(s: usize, buf: [*]const u8, len: i32, flags: i32, to: *const anyopaque, tolen: i32) callconv(.c) i32;
    extern "ws2_32" fn recvfrom(s: usize, buf: [*]u8, len: i32, flags: i32, from: *anyopaque, fromlen: *i32) callconv(.c) i32;
    extern "ws2_32" fn setsockopt(s: usize, level: i32, optname: i32, optval: [*]const u8, optlen: i32) callconv(.c) i32;
    extern "ws2_32" fn WSAStartup(wVersionRequired: u16, lpWSAData: *anyopaque) callconv(.c) i32;
    extern "ws2_32" fn WSACleanup() callconv(.c) i32;
    extern "ws2_32" fn WSAIoctl(s: usize, dwIoControlCode: u32, lpvInBuffer: ?*anyopaque, cbInBuffer: u32, lpvOutBuffer: ?*anyopaque, cbOutBuffer: u32, lpcbBytesReturned: *u32, lpOverlapped: ?*anyopaque, lpCompletionRoutine: ?*anyopaque) callconv(.c) i32;
};

const c = struct {
    extern "c" fn socket(af: c_int, type_kind: c_int, protocol: c_int) c_int;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn bind(fd: c_int, addr: *const anyopaque, len: u32) c_int;
    extern "c" fn sendto(fd: c_int, buf: [*]const u8, len: usize, flags: c_int, dest_addr: *const anyopaque, addrlen: u32) isize;
    extern "c" fn recvfrom(fd: c_int, buf: [*]u8, len: usize, flags: c_int, src_addr: *anyopaque, addrlen: *u32) isize;
    extern "c" fn setsockopt(fd: c_int, level: c_int, optname: c_int, optval: *const anyopaque, optlen: u32) c_int;
};

var wsa_ref_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

pub const UdpSocket = struct {
    fd: if (is_windows) usize else c_int,

    pub fn init() !UdpSocket {
        if (is_windows) {
            if (wsa_ref_count.fetchAdd(1, .seq_cst) == 0) {
                var wsa_data: [500]u8 = undefined;
                if (win.WSAStartup(0x202, &wsa_data) != 0) {
                    _ = wsa_ref_count.fetchSub(1, .seq_cst);
                    return error.SocketCreateFailed;
                }
            }
            const fd = win.socket(2, 2, 17); // AF_INET, SOCK_DGRAM, IPPROTO_UDP
            if (fd == std.math.maxInt(usize)) {
                if (wsa_ref_count.fetchSub(1, .seq_cst) == 1) {
                    _ = win.WSACleanup();
                }
                return error.SocketCreateFailed;
            }
            var bNewBehavior: u32 = 0;
            var dwBytesReturned: u32 = 0;
            const SIO_UDP_CONNRESET = 2550136844;
            _ = win.WSAIoctl(fd, SIO_UDP_CONNRESET, @ptrCast(&bNewBehavior), @sizeOf(u32), null, 0, &dwBytesReturned, null, null);
            return UdpSocket{ .fd = fd };
        } else {
            const fd = c.socket(2, 2, 17); // AF_INET, SOCK_DGRAM, IPPROTO_UDP
            if (fd < 0) return error.SocketCreateFailed;
            return UdpSocket{ .fd = fd };
        }
    }

    pub fn bind(self: *UdpSocket, port: u16, bind_ip: ?u32, reuse: bool) !void {
        var addr = std.mem.zeroes([16]u8);
        addr[0] = 2; // AF_INET
        addr[1] = 0;
        const p = std.mem.nativeToBig(u16, port);
        @memcpy(addr[2..4], std.mem.asBytes(&p));
        if (bind_ip) |ip| {
            @memcpy(addr[4..8], std.mem.asBytes(&ip));
        }

        if (is_windows) {
            if (reuse) {
                const optval: i32 = 1;
                _ = win.setsockopt(self.fd, 0xffff, 4, @ptrCast(&optval), 4); // SO_REUSEADDR
            }
            if (win.bind(self.fd, @ptrCast(&addr), 16) != 0) return error.BindFailed;
        } else {
            if (reuse) {
                const optval: c_int = 1;
                _ = c.setsockopt(self.fd, 1, 2, @ptrCast(&optval), 4); // SOL_SOCKET, SO_REUSEADDR
            }
            if (c.bind(self.fd, @ptrCast(&addr), 16) != 0) return error.BindFailed;
        }
    }

    pub fn joinMulticastGroup(self: *UdpSocket, multicast_ip: [4]u8) !void {
        var mreq = std.mem.zeroes([8]u8);
        @memcpy(mreq[0..4], &multicast_ip);
        if (is_windows) {
            if (win.setsockopt(self.fd, 0, 12, @ptrCast(&mreq), 8) != 0) return error.JoinMulticastFailed;
            const loop: i32 = 1;
            _ = win.setsockopt(self.fd, 0, 11, @ptrCast(&loop), 4);
        } else {
            if (c.setsockopt(self.fd, 0, 35, @ptrCast(&mreq), 8) != 0) return error.JoinMulticastFailed; // IPPROTO_IP=0, IP_ADD_MEMBERSHIP=35 on linux usually
            const loop: c_int = 1;
            _ = c.setsockopt(self.fd, 0, 34, @ptrCast(&loop), 4); // IP_MULTICAST_LOOP=34
        }
    }

    pub fn enableMulticastLoop(self: *UdpSocket) !void {
        if (is_windows) {
            const loop: i32 = 1;
            _ = win.setsockopt(self.fd, 0, 11, @ptrCast(&loop), 4);
        } else {
            const loop: c_int = 1;
            _ = c.setsockopt(self.fd, 0, 34, @ptrCast(&loop), 4);
        }
    }

    pub fn sendTo(self: *UdpSocket, buffer: []const u8, locator: rtps.types.Locator_t) !usize {
        var addr = std.mem.zeroes([16]u8);
        addr[0] = 2; // AF_INET
        const p = std.mem.nativeToBig(u16, @intCast(locator.port));
        @memcpy(addr[2..4], std.mem.asBytes(&p));
        addr[4] = locator.address[12];
        addr[5] = locator.address[13];
        addr[6] = locator.address[14];
        addr[7] = locator.address[15];

        if (is_windows) {
            const rc = win.sendto(self.fd, buffer.ptr, @intCast(buffer.len), 0, @ptrCast(&addr), 16);
            if (rc < 0) return error.SendFailed;
            return @intCast(rc);
        } else {
            const rc = c.sendto(self.fd, buffer.ptr, buffer.len, 0, @ptrCast(&addr), 16);
            if (rc < 0) return error.SendFailed;
            return @intCast(rc);
        }
    }

    pub fn receiveFrom(self: *UdpSocket, buffer: []u8, source_locator: *rtps.types.Locator_t) !usize {
        var addr = std.mem.zeroes([16]u8);
        var addrlen: i32 = 16;
        var addrlen_u32: u32 = 16;

        if (is_windows) {
            const rc = win.recvfrom(self.fd, buffer.ptr, @intCast(buffer.len), 0, @ptrCast(&addr), &addrlen);
            if (rc < 0) return error.ReceiveFailed;
            const p = std.mem.readInt(u16, addr[2..4], .big);
            source_locator.* = rtps.types.Locator_t{
                .kind = 1,
                .port = @intCast(p),
                .address = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, addr[4], addr[5], addr[6], addr[7] },
            };
            return @intCast(rc);
        } else {
            const rc = c.recvfrom(self.fd, buffer.ptr, buffer.len, 0, @ptrCast(&addr), &addrlen_u32);
            if (rc < 0) return error.ReceiveFailed;
            const p = std.mem.readInt(u16, addr[2..4], .big);
            source_locator.* = rtps.types.Locator_t{
                .kind = 1,
                .port = @intCast(p),
                .address = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, addr[4], addr[5], addr[6], addr[7] },
            };
            return @intCast(rc);
        }
    }

    pub fn setReceiveTimeout(self: *UdpSocket, timeout_ms: u32) !void {
        if (is_windows) {
            const timeout_val: i32 = @intCast(timeout_ms);
            _ = win.setsockopt(self.fd, 0xffff, 0x1006, @ptrCast(&timeout_val), 4);
        } else {
            const tv = std.posix.timeval{
                .sec = @intCast(timeout_ms / 1000),
                .usec = @intCast((timeout_ms % 1000) * 1000),
            };
            _ = c.setsockopt(self.fd, 1, 20, @ptrCast(&tv), @sizeOf(std.posix.timeval)); // SO_RCVTIMEO
        }
    }

    pub fn setTos(self: *UdpSocket, tos: i32) void {
        if (is_windows) {
            _ = win.setsockopt(self.fd, 0, 3, @ptrCast(&tos), 4);
        } else {
            const tos_val: c_int = @intCast(tos);
            _ = c.setsockopt(self.fd, 0, 1, @ptrCast(&tos_val), 4); // IP_TOS=1
        }
    }

    pub fn deinit(self: *UdpSocket) void {
        if (is_windows) {
            if (self.fd != std.math.maxInt(usize)) {
                _ = win.closesocket(self.fd);
                self.fd = std.math.maxInt(usize);
                if (wsa_ref_count.fetchSub(1, .seq_cst) == 1) {
                    _ = win.WSACleanup();
                }
            }
        } else {
            if (self.fd >= 0) {
                _ = c.close(self.fd);
                self.fd = -1;
            }
        }
    }
};

test "UdpSocket loopback send and receive" {
    var sender = try UdpSocket.init();
    defer sender.deinit();

    var receiver = try UdpSocket.init();
    defer receiver.deinit();

    // Bind receiver to test port on 127.0.0.1
    const test_port: u16 = 25999;
    const loopback_ip = @as(u32, 127) | (@as(u32, 0) << 8) | (@as(u32, 0) << 16) | (@as(u32, 1) << 24);
    try receiver.bind(test_port, loopback_ip, true);
    try receiver.setReceiveTimeout(500);

    const dest_locator = rtps.types.Locator_t{
        .kind = 1,
        .port = test_port,
        .address = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 127, 0, 0, 1 },
    };

    const msg = "DDZ UDP loopback test packet";
    const sent = try sender.sendTo(msg, dest_locator);
    try std.testing.expectEqual(msg.len, sent);

    var recv_buf: [128]u8 = undefined;
    var src_locator: rtps.types.Locator_t = undefined;
    const received = try receiver.receiveFrom(&recv_buf, &src_locator);
    try std.testing.expectEqual(msg.len, received);
    try std.testing.expectEqualStrings(msg, recv_buf[0..received]);
}
