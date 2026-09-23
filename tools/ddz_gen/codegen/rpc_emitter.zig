//! @file rpc_emitter.zig
//! @brief Code generation backend producing DDS-RPC client/service stubs from IDL service interfaces.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const Ast = @import("../ast/ast.zig");
const zig_emitter = @import("zig_emitter.zig");
const ZigEmitter = zig_emitter.ZigEmitter;
const BufferWriter = zig_emitter.BufferWriter;

pub const RpcEmitter = struct {
    allocator: std.mem.Allocator,
    zig_emitter: ZigEmitter,

    pub fn init(allocator: std.mem.Allocator) RpcEmitter {
        return .{
            .allocator = allocator,
            .zig_emitter = ZigEmitter.init(allocator),
        };
    }

    pub fn emitRpcSource(self: *RpcEmitter, ast: Ast.AstRoot) ![]const u8 {
        var buffer: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buffer.deinit(self.allocator);

        var writer = BufferWriter{
            .buffer = &buffer,
            .allocator = self.allocator,
        };

        try self.emitRpcDecls(&writer, ast.declarations, 0);
        return try buffer.toOwnedSlice(self.allocator);
    }

    pub fn emitRpcDecls(self: *RpcEmitter, writer: anytype, decls: []const Ast.Declaration, indent: usize) anyerror!void {
        for (decls) |decl| {
            switch (decl) {
                .module => |mod| {
                    try self.writeIndent(writer, indent);
                    try writer.print("pub const {s}_RPC = struct {{\n", .{mod.name});
                    try self.emitRpcDecls(writer, mod.declarations, indent + 1);
                    try self.writeIndent(writer, indent);
                    try writer.writeAll("};\n\n");
                },
                .interface_def => |iface| {
                    try self.emitInterfaceWithIndent(writer, iface, indent);
                },
                else => {},
            }
        }
    }

    pub fn emitInterfaceWithIndent(self: *RpcEmitter, writer: anytype, iface: Ast.InterfaceDef, indent: usize) anyerror!void {
        // 1. Request and Reply structs for each operation
        for (iface.operations) |op| {
            // Request struct
            try self.writeIndent(writer, indent);
            try writer.print("pub const {s}_{s}_Request = struct {{\n", .{ iface.name, op.name });
            for (op.params) |p| {
                if (p.direction == .in or p.direction == .inout) {
                    try self.writeIndent(writer, indent + 1);
                    try writer.print("{s}: ", .{p.name});
                    try self.zig_emitter.emitTypeRef(writer, p.param_type);
                    try writer.writeAll(",\n");
                }
            }
            try self.writeIndent(writer, indent);
            try writer.writeAll("};\n\n");

            // Reply struct
            try self.writeIndent(writer, indent);
            try writer.print("pub const {s}_{s}_Reply = struct {{\n", .{ iface.name, op.name });
            if (op.return_type != .primitive or op.return_type.primitive != .void) {
                try self.writeIndent(writer, indent + 1);
                try writer.writeAll("return_value: ");
                try self.zig_emitter.emitTypeRef(writer, op.return_type);
                try writer.writeAll(",\n");
            }
            for (op.params) |p| {
                if (p.direction == .out or p.direction == .inout) {
                    try self.writeIndent(writer, indent + 1);
                    try writer.print("{s}: ", .{p.name});
                    try self.zig_emitter.emitTypeRef(writer, p.param_type);
                    try writer.writeAll(",\n");
                }
            }
            try self.writeIndent(writer, indent);
            try writer.writeAll("};\n\n");
        }

        // 2. Client Stub
        try self.writeIndent(writer, indent);
        try writer.print("pub const {s}Client = struct {{\n", .{iface.name});
        try self.writeIndent(writer, indent + 1);
        try writer.writeAll("allocator: std.mem.Allocator,\n\n");

        for (iface.operations) |op| {
            try self.writeIndent(writer, indent + 1);
            try writer.print("pub fn {s}(self: *{s}Client, ", .{ op.name, iface.name });
            for (op.params) |p| {
                if (p.direction == .in or p.direction == .inout) {
                    try writer.print("{s}: ", .{p.name});
                    try self.zig_emitter.emitTypeRef(writer, p.param_type);
                    try writer.writeAll(", ");
                }
            }
            try writer.writeAll("requester: anytype, timeout_ms: u32) !");
            if (op.return_type != .primitive or op.return_type.primitive != .void) {
                try self.zig_emitter.emitTypeRef(writer, op.return_type);
            } else {
                try writer.writeAll("void");
            }
            try writer.writeAll(" {\n");
            try self.writeIndent(writer, indent + 2);
            try writer.writeAll("_ = self;\n");

            // Build request
            try self.writeIndent(writer, indent + 2);
            try writer.print("const req = {s}_{s}_Request{{\n", .{ iface.name, op.name });
            for (op.params) |p| {
                if (p.direction == .in or p.direction == .inout) {
                    try self.writeIndent(writer, indent + 3);
                    try writer.print(".{s} = {s},\n", .{ p.name, p.name });
                }
            }
            try self.writeIndent(writer, indent + 2);
            try writer.writeAll("};\n");
            try self.writeIndent(writer, indent + 2);
            try writer.writeAll("const req_id = try requester.sendRequest(req);\n");

            if (op.return_type != .primitive or op.return_type.primitive != .void) {
                try self.writeIndent(writer, indent + 2);
                try writer.writeAll("if (try requester.waitForReply(req_id, timeout_ms)) |reply| {\n");
                try self.writeIndent(writer, indent + 3);
                try writer.writeAll("return reply.return_value;\n");
                try self.writeIndent(writer, indent + 2);
                try writer.writeAll("}\n");
            } else {
                try self.writeIndent(writer, indent + 2);
                try writer.writeAll("if (try requester.waitForReply(req_id, timeout_ms)) |_| {\n");
                try self.writeIndent(writer, indent + 3);
                try writer.writeAll("return;\n");
                try self.writeIndent(writer, indent + 2);
                try writer.writeAll("}\n");
            }

            try self.writeIndent(writer, indent + 2);
            try writer.writeAll("return error.Timeout;\n");
            try self.writeIndent(writer, indent + 1);
            try writer.writeAll("}\n\n");
        }
        try self.writeIndent(writer, indent);
        try writer.writeAll("};\n\n");

        // 3. Server Skeleton & Handler
        try self.writeIndent(writer, indent);
        try writer.print("pub const {s}Handler = struct {{\n", .{iface.name});
        try self.writeIndent(writer, indent + 1);
        try writer.writeAll("ctx: *anyopaque,\n");
        for (iface.operations) |op| {
            try self.writeIndent(writer, indent + 1);
            try writer.print("{s}: *const fn (ctx: *anyopaque, req: {s}_{s}_Request) anyerror!", .{ op.name, iface.name, op.name });
            if (op.return_type != .primitive or op.return_type.primitive != .void) {
                try self.zig_emitter.emitTypeRef(writer, op.return_type);
            } else {
                try writer.writeAll("void");
            }
            try writer.writeAll(",\n");
        }
        try self.writeIndent(writer, indent);
        try writer.writeAll("};\n\n");

        try self.writeIndent(writer, indent);
        try writer.print("pub const {s}Server = struct {{\n", .{iface.name});
        try self.writeIndent(writer, indent + 1);
        try writer.print("handler: {s}Handler,\n\n", .{iface.name});
        try self.writeIndent(writer, indent + 1);
        try writer.print("pub fn init(handler: {s}Handler) {s}Server {{\n", .{ iface.name, iface.name });
        try self.writeIndent(writer, indent + 2);
        try writer.writeAll("return .{ .handler = handler };\n");
        try self.writeIndent(writer, indent + 1);
        try writer.writeAll("}\n");
        try self.writeIndent(writer, indent);
        try writer.writeAll("};\n\n");
    }

    fn writeIndent(self: *RpcEmitter, writer: anytype, indent: usize) !void {
        _ = self;
        var i: usize = 0;
        while (i < indent * 4) : (i += 1) {
            try writer.writeByte(' ');
        }
    }
};

test "RpcEmitter generates stubs and skeletons" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var rpc_emitter = RpcEmitter.init(allocator);

    const calc_iface = Ast.InterfaceDef{
        .name = "Calculator",
        .operations = &.{
            .{
                .name = "add",
                .return_type = .{ .primitive = .long },
                .params = &.{
                    .{ .direction = .in, .param_type = .{ .primitive = .long }, .name = "a" },
                    .{ .direction = .in, .param_type = .{ .primitive = .long }, .name = "b" },
                },
            },
        },
    };

    const ast = Ast.AstRoot{
        .declarations = &.{
            Ast.Declaration{ .interface_def = calc_iface },
        },
    };

    const code = try rpc_emitter.emitRpcSource(ast);
    defer allocator.free(code);

    try std.testing.expect(std.mem.indexOf(u8, code, "pub const Calculator_add_Request = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "pub const Calculator_add_Reply = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "pub const CalculatorClient = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "pub const CalculatorHandler = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "pub const CalculatorServer = struct {") != null);
}
