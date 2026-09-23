//! @file reverse_emitter.zig
//! @brief Reverse engineering emitter generating IDL schemas from Zig source types.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const Ast = @import("../ast/ast.zig");
const BufferWriter = @import("zig_emitter.zig").BufferWriter;

pub const ReverseEmitter = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ReverseEmitter {
        return .{ .allocator = allocator };
    }

    pub fn emitIdl(self: *ReverseEmitter, ast: Ast.AstRoot, module_name: ?[]const u8) ![]const u8 {
        var buffer: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buffer.deinit(self.allocator);

        var writer = BufferWriter{
            .buffer = &buffer,
            .allocator = self.allocator,
        };

        try writer.writeAll(
            \\// Generated automatically by ddz_gen reverse compiler. DO NOT EDIT.
            \\
        );

        if (module_name) |m| {
            try writer.print("#ifndef __{s}_IDL__\n#define __{s}_IDL__\n\n", .{ m, m });
            try writer.print("module {s} {{\n", .{m});
        }

        for (ast.declarations) |decl| {
            try self.emitDeclaration(&writer, decl, if (module_name != null) "    " else "");
            try writer.writeAll("\n");
        }

        if (module_name) |_| {
            try writer.writeAll("};\n\n#endif\n");
        }

        return try buffer.toOwnedSlice(self.allocator);
    }

    fn emitDeclaration(self: *ReverseEmitter, writer: anytype, decl: Ast.Declaration, indent: []const u8) anyerror!void {
        switch (decl) {
            .struct_def => |s| try self.emitStruct(writer, s, indent),
            .enum_def => |e| try self.emitEnum(writer, e, indent),
            .typedef_def => |td| try self.emitTypedef(writer, td, indent),
            .const_def => |cd| try self.emitConst(writer, cd, indent),
            else => {},
        }
    }

    fn emitStruct(self: *ReverseEmitter, writer: anytype, s: Ast.StructDef, indent: []const u8) !void {
        _ = self;
        if (s.doc_comment) |d| {
            try writer.print("{s}// {s}\n", .{ indent, d });
        }
        try writer.print("{s}struct {s} {{\n", .{ indent, s.name });

        for (s.fields) |f| {
            try writer.print("{s}    ", .{indent});
            if (f.isKey()) {
                try writer.writeAll("@key ");
            }
            if (f.type_ref == .array) {
                const arr = f.type_ref.array;
                try emitIdlTypeRef(writer, arr.element_type);
                try writer.print(" {s}", .{f.name});
                for (arr.dimensions) |dim| {
                    try writer.print("[{d}]", .{dim});
                }
                try writer.writeAll(";\n");
            } else {
                try emitIdlTypeRef(writer, f.type_ref);
                try writer.print(" {s};\n", .{f.name});
            }
        }

        try writer.print("{s}}};\n", .{indent});
    }

    fn emitEnum(self: *ReverseEmitter, writer: anytype, e: Ast.EnumDef, indent: []const u8) !void {
        _ = self;
        if (e.doc_comment) |d| {
            try writer.print("{s}// {s}\n", .{ indent, d });
        }
        try writer.print("{s}enum {s} {{\n", .{ indent, e.name });
        for (e.members, 0..) |m, i| {
            try writer.print("{s}    {s}", .{ indent, m.name });
            if (m.value) |v| {
                try writer.print(" = {d}", .{v});
            }
            if (i + 1 < e.members.len) {
                try writer.writeAll(",\n");
            } else {
                try writer.writeAll("\n");
            }
        }
        try writer.print("{s}}};\n", .{indent});
    }

    fn emitTypedef(self: *ReverseEmitter, writer: anytype, td: Ast.TypedefDef, indent: []const u8) !void {
        _ = self;
        try writer.print("{s}typedef ", .{indent});
        try emitIdlTypeRef(writer, td.target_type);
        try writer.print(" {s};\n", .{td.name});
    }

    fn emitConst(self: *ReverseEmitter, writer: anytype, cd: Ast.ConstDef, indent: []const u8) !void {
        _ = self;
        try writer.print("{s}const ", .{indent});
        try emitIdlTypeRef(writer, cd.const_type);
        try writer.print(" {s} = {s};\n", .{ cd.name, cd.value_repr });
    }

    fn emitIdlTypeRef(writer: anytype, type_ref: Ast.TypeRef) anyerror!void {
        switch (type_ref) {
            .primitive => |p| {
                const idl_str: []const u8 = switch (p) {
                    .boolean => "boolean",
                    .octet, .uint8 => "octet",
                    .char => "char",
                    .wchar => "wchar",
                    .short, .int16 => "short",
                    .unsigned_short, .uint16 => "unsigned short",
                    .long, .int32 => "long",
                    .unsigned_long, .uint32 => "unsigned long",
                    .long_long, .int64 => "long long",
                    .unsigned_long_long, .uint64 => "unsigned long long",
                    .float => "float",
                    .double => "double",
                    .long_double => "long double",
                    .string => "string",
                    .wstring => "wstring",
                    .fixed => "fixed",
                    .void => "void",
                    .int8 => "int8",
                };
                try writer.writeAll(idl_str);
            },
            .string_bounded => |bound| {
                try writer.print("string<{d}>", .{bound});
            },
            .wstring_bounded => |bound| {
                try writer.print("wstring<{d}>", .{bound});
            },
            .sequence => |seq| {
                try writer.writeAll("sequence<");
                try emitIdlTypeRef(writer, seq.element_type);
                if (seq.bound) |b| {
                    try writer.print(", {d}>", .{b});
                } else {
                    try writer.writeAll(">");
                }
            },
            .array => |arr| {
                try emitIdlTypeRef(writer, arr.element_type);
                for (arr.dimensions) |dim| {
                    try writer.print("[{d}]", .{dim});
                }
            },
            .scoped_name => |sn| {
                for (sn.segments, 0..) |seg, i| {
                    if (i > 0) try writer.writeAll("::");
                    try writer.writeAll(seg);
                }
            },
        }
    }

    /// Parse basic Zig struct source definitions into AstRoot for reverse compilation
    pub fn parseZigStructs(self: *ReverseEmitter, source: []const u8) !Ast.AstRoot {
        var decls: std.ArrayListUnmanaged(Ast.Declaration) = .empty;
        errdefer decls.deinit(self.allocator);

        var lines = std.mem.splitScalar(u8, source, '\n');
        var in_struct: ?[]const u8 = null;
        var in_enum: ?[]const u8 = null;
        var struct_fields: std.ArrayListUnmanaged(Ast.Field) = .empty;
        var enum_members: std.ArrayListUnmanaged(Ast.EnumMember) = .empty;
        var keys: std.ArrayListUnmanaged([]const u8) = .empty;

        while (lines.next()) |raw_line| {
            var line = raw_line;
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            const trimmed = std.mem.trim(u8, line, " \t");

            if (in_enum) |e_name| {
                if (std.mem.startsWith(u8, trimmed, "};")) {
                    try decls.append(self.allocator, .{
                        .enum_def = .{
                            .name = e_name,
                            .members = try enum_members.toOwnedSlice(self.allocator),
                        },
                    });
                    in_enum = null;
                    continue;
                }

                if (trimmed.len > 0 and !std.mem.startsWith(u8, trimmed, "//")) {
                    var m_name = std.mem.trim(u8, trimmed, " \t,");
                    var m_val: ?i64 = null;
                    if (std.mem.indexOfScalar(u8, m_name, '=')) |eq_idx| {
                        const val_str = std.mem.trim(u8, m_name[eq_idx + 1 ..], " \t,");
                        m_name = std.mem.trim(u8, m_name[0..eq_idx], " \t");
                        m_val = std.fmt.parseInt(i64, val_str, 10) catch null;
                    }
                    try enum_members.append(self.allocator, .{
                        .name = m_name,
                        .value = m_val,
                    });
                }
            } else if (in_struct) |s_name| {
                if (std.mem.startsWith(u8, trimmed, "pub const ddz_keys")) {
                    // Extract keys: [_][]const u8{"id", "foo"}
                    if (std.mem.indexOfScalar(u8, trimmed, '{')) |start_brace| {
                        if (std.mem.lastIndexOfScalar(u8, trimmed, '}')) |end_brace| {
                            const inner = trimmed[start_brace + 1 .. end_brace];
                            var kit = std.mem.tokenizeAny(u8, inner, " \t,\"");
                            while (kit.next()) |key_str| {
                                try keys.append(self.allocator, key_str);
                            }
                        }
                    }
                    continue;
                }

                if (std.mem.startsWith(u8, trimmed, "};")) {
                    // Close struct
                    for (struct_fields.items) |*f| {
                        for (keys.items) |k| {
                            if (std.mem.eql(u8, f.name, k)) {
                                f.annotations = &.{.{ .name = "key" }};
                            }
                        }
                    }

                    // Only emit if it had fields or isn't just an outer namespace wrapper
                    if (struct_fields.items.len > 0) {
                        try decls.append(self.allocator, .{
                            .struct_def = .{
                                .name = s_name,
                                .fields = try struct_fields.toOwnedSlice(self.allocator),
                            },
                        });
                    }

                    keys.clearRetainingCapacity();
                    in_struct = null;
                    continue;
                }

                // Field line: "name: type," or "name: type = default,"
                if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon_pos| {
                    const f_name = std.mem.trim(u8, trimmed[0..colon_pos], " \t");
                    const rest = std.mem.trim(u8, trimmed[colon_pos + 1 ..], " \t,");
                    var type_part = rest;
                    if (std.mem.indexOfScalar(u8, rest, '=')) |eq_pos| {
                        type_part = std.mem.trim(u8, rest[0..eq_pos], " \t");
                    }

                    const f_type = try self.mapZigType(type_part);
                    try struct_fields.append(self.allocator, .{
                        .name = f_name,
                        .type_ref = f_type,
                    });
                }
            } else {
                if (std.mem.indexOf(u8, trimmed, "enum(")) |enum_idx| {
                    if (std.mem.indexOf(u8, trimmed, "const ")) |const_idx| {
                        const name_part = std.mem.trim(u8, trimmed[const_idx + 6 .. enum_idx], " \t=");
                        in_enum = name_part;
                        enum_members = .empty;
                    }
                } else if (std.mem.indexOf(u8, trimmed, "struct {")) |struct_idx| {
                    if (std.mem.indexOf(u8, trimmed, "const ")) |const_idx| {
                        const name_part = std.mem.trim(u8, trimmed[const_idx + 6 .. struct_idx], " \t=");
                        in_struct = name_part;
                        struct_fields = .empty;
                        keys = .empty;
                    }
                }
            }
        }

        return .{ .declarations = try decls.toOwnedSlice(self.allocator) };
    }

    fn mapZigType(self: *ReverseEmitter, zig_type: []const u8) anyerror!Ast.TypeRef {
        if (std.mem.eql(u8, zig_type, "i32")) return .{ .primitive = .long };
        if (std.mem.eql(u8, zig_type, "u32")) return .{ .primitive = .unsigned_long };
        if (std.mem.eql(u8, zig_type, "i16")) return .{ .primitive = .short };
        if (std.mem.eql(u8, zig_type, "u16")) return .{ .primitive = .unsigned_short };
        if (std.mem.eql(u8, zig_type, "i64")) return .{ .primitive = .long_long };
        if (std.mem.eql(u8, zig_type, "u64")) return .{ .primitive = .unsigned_long_long };
        if (std.mem.eql(u8, zig_type, "f32")) return .{ .primitive = .float };
        if (std.mem.eql(u8, zig_type, "f64")) return .{ .primitive = .double };
        if (std.mem.eql(u8, zig_type, "bool")) return .{ .primitive = .boolean };
        if (std.mem.eql(u8, zig_type, "u8")) return .{ .primitive = .octet };
        if (std.mem.startsWith(u8, zig_type, "[:0]const u8") or std.mem.startsWith(u8, zig_type, "[]const u8")) return .{ .primitive = .string };

        // Handle arrays like [4]f32 or [32:0]u8
        if (std.mem.startsWith(u8, zig_type, "[")) {
            if (std.mem.indexOfScalar(u8, zig_type, ']')) |rb| {
                const inner = zig_type[1..rb];
                const elem_part = std.mem.trim(u8, zig_type[rb + 1 ..], " ");
                if (std.mem.indexOfScalar(u8, inner, ':')) |colon_pos| {
                    // e.g. [32:0]u8 -> string<32>
                    const bound = std.fmt.parseInt(u32, inner[0..colon_pos], 10) catch 0;
                    return .{ .string_bounded = bound };
                }
                const dim = std.fmt.parseInt(u32, inner, 10) catch 0;
                const elem_type = try self.mapZigType(elem_part);
                const arr = try self.allocator.create(Ast.ArrayType);
                const dims = try self.allocator.alloc(u32, 1);
                dims[0] = dim;
                arr.* = .{ .element_type = elem_type, .dimensions = dims };
                return .{ .array = arr };
            }
        }

        const segs = try self.allocator.alloc([]const u8, 1);
        segs[0] = try self.allocator.dupe(u8, zig_type);
        return .{ .scoped_name = .{ .segments = segs } };
    }
};

test "ReverseEmitter generates OMG IDL from Zig struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var emitter = ReverseEmitter.init(allocator);

    const zig_code =
        \\pub const SensorPacket = struct {
        \\    sensor_id: i32 = 0,
        \\    temperature: f32 = 0.0,
        \\    humidity: f64 = 0.0,
        \\
        \\    pub const ddz_keys = [_][]const u8{"sensor_id"};
        \\};
    ;

    const ast = try emitter.parseZigStructs(zig_code);
    const idl_out = try emitter.emitIdl(ast, "Sensors");
    defer allocator.free(idl_out);

    try std.testing.expect(std.mem.indexOf(u8, idl_out, "module Sensors {") != null);
    try std.testing.expect(std.mem.indexOf(u8, idl_out, "struct SensorPacket {") != null);
    try std.testing.expect(std.mem.indexOf(u8, idl_out, "@key long sensor_id;") != null);
    try std.testing.expect(std.mem.indexOf(u8, idl_out, "float temperature;") != null);
    try std.testing.expect(std.mem.indexOf(u8, idl_out, "double humidity;") != null);
}
