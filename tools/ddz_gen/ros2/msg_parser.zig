//! @file msg_parser.zig
//! @brief Parser for ROS2 .msg and .srv interface definition files.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const Ast = @import("../ast/ast.zig");
const Diagnostics = @import("../diagnostics.zig");
const ConstEvaluator = @import("../parser/const_evaluator.zig").ConstEvaluator;

pub const MsgParser = struct {
    allocator: std.mem.Allocator,
    diagnostics: *Diagnostics.DiagnosticEngine,

    pub fn init(allocator: std.mem.Allocator, diag: *Diagnostics.DiagnosticEngine) MsgParser {
        return .{
            .allocator = allocator,
            .diagnostics = diag,
        };
    }

    pub fn parseMsg(self: *MsgParser, source: []const u8, pkg_name: []const u8, msg_name: []const u8) !Ast.StructDef {
        var fields: std.ArrayListUnmanaged(Ast.Field) = .empty;
        errdefer fields.deinit(self.allocator);

        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |raw_line| {
            var line = raw_line;
            if (line.len > 0 and line[line.len - 1] == '\r') {
                line = line[0 .. line.len - 1];
            }

            // Strip comments '#'
            if (std.mem.indexOfScalar(u8, line, '#')) |comment_idx| {
                line = line[0..comment_idx];
            }

            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len == 0) continue;

            // Check for constant definition: "type NAME=value"
            if (std.mem.indexOfScalar(u8, trimmed, '=')) |_| {
                // Constant - can skip or handle as const
                continue;
            }

            // Parse field: "<type> <name> [default]"
            var tokens = std.mem.tokenizeAny(u8, trimmed, " \t");
            const type_token = tokens.next() orelse continue;
            const name_token = tokens.next() orelse continue;
            const def_val = tokens.next();

            const field_type = try self.resolveRosType(type_token);

            try fields.append(self.allocator, .{
                .name = name_token,
                .type_ref = field_type,
                .default_value = def_val,
            });
        }

        _ = pkg_name;
        return .{
            .name = msg_name,
            .fields = try fields.toOwnedSlice(self.allocator),
        };
    }

    pub fn parseSrv(self: *MsgParser, source: []const u8, pkg_name: []const u8, srv_name: []const u8) !struct { request: Ast.StructDef, response: Ast.StructDef } {
        // Split by "---"
        const sep = "---";
        const sep_pos = std.mem.indexOf(u8, source, sep);

        const req_src = if (sep_pos) |pos| source[0..pos] else source;
        const resp_src = if (sep_pos) |pos| source[pos + sep.len ..] else "";

        const req_name = try std.fmt.allocPrint(self.allocator, "{s}_Request", .{srv_name});
        const resp_name = try std.fmt.allocPrint(self.allocator, "{s}_Response", .{srv_name});

        const req_def = try self.parseMsg(req_src, pkg_name, req_name);
        const resp_def = try self.parseMsg(resp_src, pkg_name, resp_name);

        return .{
            .request = req_def,
            .response = resp_def,
        };
    }

    fn resolveRosType(self: *MsgParser, token: []const u8) anyerror!Ast.TypeRef {
        // Check for array bounds e.g. "int32[5]" or "int32[]" or "int32[<=10]"
        if (std.mem.indexOfScalar(u8, token, '[')) |l_br| {
            const r_br = std.mem.indexOfScalar(u8, token, ']') orelse return error.InvalidRosType;
            const base_type_str = token[0..l_br];
            const bound_str = token[l_br + 1 .. r_br];

            const base_type = try self.resolveRosScalarType(base_type_str);

            if (bound_str.len == 0) {
                // Dynamic array -> unbounded sequence
                const seq = try self.allocator.create(Ast.SequenceType);
                seq.* = .{ .element_type = base_type, .bound = null };
                return .{ .sequence = seq };
            } else if (std.mem.startsWith(u8, bound_str, "<=")) {
                // Bounded sequence
                const b_val = ConstEvaluator.parseI64(bound_str[2..]) orelse 0;
                const seq = try self.allocator.create(Ast.SequenceType);
                seq.* = .{ .element_type = base_type, .bound = @intCast(b_val) };
                return .{ .sequence = seq };
            } else {
                // Fixed-size array
                const dim = ConstEvaluator.parseI64(bound_str) orelse 0;
                const arr = try self.allocator.create(Ast.ArrayType);
                const dims = try self.allocator.alloc(u32, 1);
                dims[0] = @intCast(dim);
                arr.* = .{ .element_type = base_type, .dimensions = dims };
                return .{ .array = arr };
            }
        }

        return self.resolveRosScalarType(token);
    }

    fn resolveRosScalarType(self: *MsgParser, token: []const u8) !Ast.TypeRef {
        if (std.mem.eql(u8, token, "bool")) return .{ .primitive = .boolean };
        if (std.mem.eql(u8, token, "byte") or std.mem.eql(u8, token, "uint8")) return .{ .primitive = .octet };
        if (std.mem.eql(u8, token, "char") or std.mem.eql(u8, token, "int8")) return .{ .primitive = .int8 };
        if (std.mem.eql(u8, token, "float32")) return .{ .primitive = .float };
        if (std.mem.eql(u8, token, "float64")) return .{ .primitive = .double };
        if (std.mem.eql(u8, token, "int16")) return .{ .primitive = .short };
        if (std.mem.eql(u8, token, "uint16")) return .{ .primitive = .unsigned_short };
        if (std.mem.eql(u8, token, "int32")) return .{ .primitive = .long };
        if (std.mem.eql(u8, token, "uint32")) return .{ .primitive = .unsigned_long };
        if (std.mem.eql(u8, token, "int64")) return .{ .primitive = .long_long };
        if (std.mem.eql(u8, token, "uint64")) return .{ .primitive = .unsigned_long_long };
        if (std.mem.eql(u8, token, "string")) return .{ .primitive = .string };
        if (std.mem.eql(u8, token, "wstring")) return .{ .primitive = .wstring };

        // Complex type (e.g. "geometry_msgs/Point" or "Header")
        var segs: std.ArrayListUnmanaged([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, token, '/');
        while (it.next()) |part| {
            try segs.append(self.allocator, part);
        }

        return .{ .scoped_name = .{ .segments = try segs.toOwnedSlice(self.allocator) } };
    }
};

test "MsgParser parses ROS 2 message definitions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var diag = Diagnostics.DiagnosticEngine.init(allocator);
    defer diag.deinit();

    var parser = MsgParser.init(allocator, &diag);

    const twist_msg =
        \\# A representation of velocity in free space broken into its linear and angular parts.
        \\Vector3  linear
        \\Vector3  angular
        \\float64  speed_limit 10.5
        \\int32[]  wheel_ids
        \\uint8[4] status_flags
    ;

    const s = try parser.parseMsg(twist_msg, "geometry_msgs", "Twist");

    try std.testing.expectEqualStrings("Twist", s.name);
    try std.testing.expectEqual(@as(usize, 5), s.fields.len);
    try std.testing.expectEqualStrings("linear", s.fields[0].name);
    try std.testing.expectEqualStrings("angular", s.fields[1].name);
    try std.testing.expectEqualStrings("speed_limit", s.fields[2].name);
    try std.testing.expectEqualStrings("wheel_ids", s.fields[3].name);
    try std.testing.expectEqualStrings("status_flags", s.fields[4].name);
}

test "MsgParser parses ROS 2 service definitions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var diag = Diagnostics.DiagnosticEngine.init(allocator);
    defer diag.deinit();

    var parser = MsgParser.init(allocator, &diag);

    const add_two_ints_srv =
        \\int64 a
        \\int64 b
        \\---
        \\int64 sum
    ;

    const srv = try parser.parseSrv(add_two_ints_srv, "example_interfaces", "AddTwoInts");

    try std.testing.expectEqualStrings("AddTwoInts_Request", srv.request.name);
    try std.testing.expectEqual(@as(usize, 2), srv.request.fields.len);

    try std.testing.expectEqualStrings("AddTwoInts_Response", srv.response.name);
    try std.testing.expectEqual(@as(usize, 1), srv.response.fields.len);
}
