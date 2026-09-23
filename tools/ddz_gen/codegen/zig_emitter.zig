//! @file zig_emitter.zig
//! @brief Code generation backend producing idiomatic Zig types, CDR serialization, and Topic bindings.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const Ast = @import("../ast/ast.zig");

pub const BufferWriter = struct {
    buffer: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,

    pub fn writeAll(self: *BufferWriter, bytes: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, bytes);
    }

    pub fn writeByte(self: *BufferWriter, byte: u8) !void {
        try self.buffer.append(self.allocator, byte);
    }

    pub fn print(self: *BufferWriter, comptime fmt: []const u8, args: anytype) !void {
        const formatted = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(formatted);
        try self.buffer.appendSlice(self.allocator, formatted);
    }
};

pub const ZigEmitter = struct {
    allocator: std.mem.Allocator,
    indent_level: usize = 0,
    emit_rpc: bool = false,

    pub fn init(allocator: std.mem.Allocator) ZigEmitter {
        return .{
            .allocator = allocator,
        };
    }

    pub fn emitSource(self: *ZigEmitter, ast: Ast.AstRoot) ![]const u8 {
        var buffer: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buffer.deinit(self.allocator);

        var writer = BufferWriter{
            .buffer = &buffer,
            .allocator = self.allocator,
        };

        try writer.writeAll(
            \\//! Generated automatically by ddz_gen. DO NOT EDIT.
            \\const std = @import("std");
            \\const ddz = @import("ddz");
            \\
        );

        // Collect external type references that need file imports
        var local_types = std.StringHashMap(void).init(self.allocator);
        defer local_types.deinit();
        try self.collectLocalTypes(&local_types, ast.declarations);

        var external_imports = std.StringHashMap(void).init(self.allocator);
        defer external_imports.deinit();
        try self.collectExternalTypes(&external_imports, &local_types, ast.declarations);

        var ext_it = external_imports.keyIterator();
        var has_ext = false;
        while (ext_it.next()) |ext_name| {
            try writer.print("const {s} = @import(\"{s}.zig\").{s};\n", .{ ext_name.*, ext_name.*, ext_name.* });
            has_ext = true;
        }
        if (has_ext) {
            try writer.writeAll("\n");
        } else {
            try writer.writeAll("\n");
        }

        for (ast.declarations) |decl| {
            try self.emitDeclaration(&writer, decl);
            try writer.writeAll("\n");
        }

        return try buffer.toOwnedSlice(self.allocator);
    }

    fn collectLocalTypes(self: *ZigEmitter, local_types: *std.StringHashMap(void), decls: []const Ast.Declaration) !void {
        for (decls) |decl| {
            switch (decl) {
                .module => |mod| {
                    try local_types.put(mod.name, {});
                    try self.collectLocalTypes(local_types, mod.declarations);
                },
                .struct_def => |s| try local_types.put(s.name, {}),
                .enum_def => |e| try local_types.put(e.name, {}),
                .union_def => |u| try local_types.put(u.name, {}),
                .bitmask_def => |bm| try local_types.put(bm.name, {}),
                .bitset_def => |bs| try local_types.put(bs.name, {}),
                .typedef_def => |td| try local_types.put(td.name, {}),
                .const_def => |cd| try local_types.put(cd.name, {}),
                .interface_def => |iface| try local_types.put(iface.name, {}),
            }
        }
    }

    fn collectExternalTypes(self: *ZigEmitter, external_imports: *std.StringHashMap(void), local_types: *const std.StringHashMap(void), decls: []const Ast.Declaration) !void {
        for (decls) |decl| {
            switch (decl) {
                .module => |mod| {
                    try self.collectExternalTypes(external_imports, local_types, mod.declarations);
                },
                .struct_def => |s| {
                    for (s.fields) |f| {
                        try self.checkTypeForExternal(external_imports, local_types, f.type_ref);
                    }
                },
                .union_def => |u| {
                    try self.checkTypeForExternal(external_imports, local_types, u.discriminant_type);
                    for (u.cases) |c| {
                        try self.checkTypeForExternal(external_imports, local_types, c.field.type_ref);
                    }
                },
                .typedef_def => |td| {
                    try self.checkTypeForExternal(external_imports, local_types, td.target_type);
                },
                .interface_def => |iface| {
                    for (iface.operations) |op| {
                        try self.checkTypeForExternal(external_imports, local_types, op.return_type);
                        for (op.params) |p| {
                            try self.checkTypeForExternal(external_imports, local_types, p.param_type);
                        }
                    }
                },
                else => {},
            }
        }
    }

    fn checkTypeForExternal(self: *ZigEmitter, external_imports: *std.StringHashMap(void), local_types: *const std.StringHashMap(void), type_ref: Ast.TypeRef) anyerror!void {
        switch (type_ref) {
            .primitive, .string_bounded, .wstring_bounded => {},
            .sequence => |seq| try self.checkTypeForExternal(external_imports, local_types, seq.element_type),
            .array => |arr| try self.checkTypeForExternal(external_imports, local_types, arr.element_type),
            .scoped_name => |sn| {
                if (sn.segments.len == 1) {
                    const name = sn.segments[0];
                    if (!local_types.contains(name)) {
                        try external_imports.put(name, {});
                    }
                }
            },
        }
    }

    fn emitDeclaration(self: *ZigEmitter, writer: anytype, decl: Ast.Declaration) anyerror!void {
        switch (decl) {
            .module => |mod| try self.emitModule(writer, mod),
            .struct_def => |s| try self.emitStruct(writer, s),
            .enum_def => |e| try self.emitEnum(writer, e),
            .union_def => |u| try self.emitUnion(writer, u),
            .bitmask_def => |bm| try self.emitBitmask(writer, bm),
            .bitset_def => |bs| try self.emitBitset(writer, bs),
            .typedef_def => |td| try self.emitTypedef(writer, td),
            .const_def => |cd| try self.emitConst(writer, cd),
            .interface_def => |iface| {
                if (self.emit_rpc) {
                    const RpcEmitter = @import("rpc_emitter.zig").RpcEmitter;
                    var rpc = RpcEmitter.init(self.allocator);
                    try rpc.emitInterfaceWithIndent(writer, iface, self.indent_level);
                }
            },
        }
    }

    fn emitModule(self: *ZigEmitter, writer: anytype, mod: *const Ast.ModuleDef) anyerror!void {
        try self.emitDoc(writer, mod.doc_comment);
        try self.writeIndent(writer);
        try writer.print("pub const {s} = struct {{\n", .{mod.name});

        self.indent_level += 1;
        for (mod.declarations) |sub_decl| {
            try self.emitDeclaration(writer, sub_decl);
            try writer.writeAll("\n");
        }
        self.indent_level -= 1;

        try self.writeIndent(writer);
        try writer.writeAll("};\n");
    }

    fn emitStruct(self: *ZigEmitter, writer: anytype, s: Ast.StructDef) !void {
        try self.emitDoc(writer, s.doc_comment);
        try self.writeIndent(writer);
        try writer.print("pub const {s} = struct {{\n", .{s.name});
        self.indent_level += 1;

        // Emit fields
        for (s.fields) |f| {
            try self.emitDoc(writer, f.doc_comment);
            try self.writeIndent(writer);

            if (f.isOptional()) {
                try writer.print("{s}: ?", .{f.name});
                try self.emitTypeRef(writer, f.type_ref);
                try writer.writeAll(" = null,\n");
            } else {
                try writer.print("{s}: ", .{f.name});
                try self.emitTypeRef(writer, f.type_ref);

                if (f.default_value) |def_val| {
                    try writer.print(" = {s},\n", .{def_val});
                } else {
                    try writer.writeAll(" = ");
                    try self.emitDefaultInitializer(writer, f.type_ref);
                    try writer.writeAll(",\n");
                }
            }
        }

        // Emit ddz_keys if present
        if (s.hasKeys()) {
            try writer.writeAll("\n");
            try self.writeIndent(writer);
            try writer.writeAll("pub const ddz_keys = [_][]const u8{\n");
            self.indent_level += 1;
            for (s.fields) |f| {
                if (f.isKey()) {
                    try self.writeIndent(writer);
                    try writer.print("\"{s}\",\n", .{f.name});
                }
            }
            self.indent_level -= 1;
            try self.writeIndent(writer);
            try writer.writeAll("};\n");
        }

        self.indent_level -= 1;
        try self.writeIndent(writer);
        try writer.writeAll("};\n");
    }

    fn emitEnum(self: *ZigEmitter, writer: anytype, e: Ast.EnumDef) !void {
        try self.emitDoc(writer, e.doc_comment);
        try self.writeIndent(writer);
        try writer.print("pub const {s} = enum(u32) {{\n", .{e.name});
        self.indent_level += 1;

        var next_val: i64 = 0;
        for (e.members) |m| {
            try self.emitDoc(writer, m.doc_comment);
            try self.writeIndent(writer);
            if (m.value) |v| {
                try writer.print("{s} = {d},\n", .{ m.name, v });
                next_val = v + 1;
            } else {
                try writer.print("{s} = {d},\n", .{ m.name, next_val });
                next_val += 1;
            }
        }

        self.indent_level -= 1;
        try self.writeIndent(writer);
        try writer.writeAll("};\n");
    }

    fn emitUnion(self: *ZigEmitter, writer: anytype, u: Ast.UnionDef) !void {
        try self.emitDoc(writer, u.doc_comment);

        // Tag enum
        try self.writeIndent(writer);
        try writer.print("pub const {s}Tag = enum(i32) {{\n", .{u.name});
        self.indent_level += 1;
        for (u.cases) |c| {
            try self.writeIndent(writer);
            var tag_val: i64 = 0;
            if (c.labels.len > 0) {
                switch (c.labels[0]) {
                    .value => |v| tag_val = v,
                    .default_case => tag_val = 0,
                }
            }
            try writer.print("{s} = {d},\n", .{ c.field.name, tag_val });
        }
        self.indent_level -= 1;
        try self.writeIndent(writer);
        try writer.writeAll("};\n\n");

        // Tagged Union
        try self.writeIndent(writer);
        try writer.print("pub const {s} = union({s}Tag) {{\n", .{ u.name, u.name });
        self.indent_level += 1;
        for (u.cases) |c| {
            try self.writeIndent(writer);
            try writer.print("{s}: ", .{c.field.name});
            try self.emitTypeRef(writer, c.field.type_ref);
            try writer.writeAll(",\n");
        }
        self.indent_level -= 1;
        try self.writeIndent(writer);
        try writer.writeAll("};\n");
    }

    fn emitBitmask(self: *ZigEmitter, writer: anytype, bm: Ast.BitmaskDef) !void {
        try self.emitDoc(writer, bm.doc_comment);
        try self.writeIndent(writer);

        const int_type = if (bm.bit_bound <= 8)
            "u8"
        else if (bm.bit_bound <= 16)
            "u16"
        else if (bm.bit_bound <= 32)
            "u32"
        else
            "u64";

        try writer.print("pub const {s} = packed struct({s}) {{\n", .{ bm.name, int_type });
        self.indent_level += 1;

        for (bm.flags) |flag| {
            try self.writeIndent(writer);
            try writer.print("{s}: bool = false,\n", .{flag});
        }

        const padding_bits = bm.bit_bound - @as(u16, @intCast(bm.flags.len));
        if (padding_bits > 0) {
            try self.writeIndent(writer);
            try writer.print("_padding: u{d} = 0,\n", .{padding_bits});
        }

        self.indent_level -= 1;
        try self.writeIndent(writer);
        try writer.writeAll("};\n");
    }

    fn emitBitset(self: *ZigEmitter, writer: anytype, bs: Ast.BitsetDef) !void {
        try self.emitDoc(writer, bs.doc_comment);
        try self.writeIndent(writer);
        try writer.print("pub const {s} = packed struct {{\n", .{bs.name});
        self.indent_level += 1;

        for (bs.fields) |f| {
            try self.writeIndent(writer);
            try writer.print("{s}: u{d} = 0,\n", .{ f.name, f.bit_size });
        }

        self.indent_level -= 1;
        try self.writeIndent(writer);
        try writer.writeAll("};\n");
    }

    fn emitTypedef(self: *ZigEmitter, writer: anytype, td: Ast.TypedefDef) !void {
        try self.emitDoc(writer, td.doc_comment);
        try self.writeIndent(writer);
        try writer.print("pub const {s} = ", .{td.name});
        try self.emitTypeRef(writer, td.target_type);
        try writer.writeAll(";\n");
    }

    fn emitConst(self: *ZigEmitter, writer: anytype, cd: Ast.ConstDef) !void {
        try self.emitDoc(writer, cd.doc_comment);
        try self.writeIndent(writer);
        try writer.print("pub const {s}: ", .{cd.name});
        try self.emitTypeRef(writer, cd.const_type);
        try writer.print(" = {s};\n", .{cd.value_repr});
    }

    pub fn emitTypeRef(self: *ZigEmitter, writer: anytype, type_ref: Ast.TypeRef) anyerror!void {
        switch (type_ref) {
            .primitive => |p| {
                const type_str: []const u8 = switch (p) {
                    .boolean => "bool",
                    .octet, .uint8 => "u8",
                    .char => "u8",
                    .wchar => "u16",
                    .short, .int16 => "i16",
                    .unsigned_short, .uint16 => "u16",
                    .long, .int32 => "i32",
                    .unsigned_long, .uint32 => "u32",
                    .long_long, .int64 => "i64",
                    .unsigned_long_long, .uint64 => "u64",
                    .float => "f32",
                    .double => "f64",
                    .long_double => "f128",
                    .string => "[:0]const u8",
                    .wstring => "[]const u16",
                    .fixed => "f64",
                    .void => "void",
                    .int8 => "i8",
                };
                try writer.writeAll(type_str);
            },
            .string_bounded => |bound| {
                try writer.print("[{d}:0]u8", .{bound});
            },
            .wstring_bounded => |bound| {
                try writer.print("[{d}]u16", .{bound});
            },
            .sequence => |seq| {
                if (seq.bound) |b| {
                    try writer.print("[{d}]", .{b});
                    try self.emitTypeRef(writer, seq.element_type);
                } else {
                    try writer.writeAll("[]const ");
                    try self.emitTypeRef(writer, seq.element_type);
                }
            },
            .array => |arr| {
                for (arr.dimensions) |dim| {
                    try writer.print("[{d}]", .{dim});
                }
                try self.emitTypeRef(writer, arr.element_type);
            },
            .scoped_name => |sn| {
                for (sn.segments, 0..) |seg, i| {
                    if (i > 0) try writer.writeAll(".");
                    try writer.writeAll(seg);
                }
            },
        }
    }

    fn emitDefaultInitializer(self: *ZigEmitter, writer: anytype, type_ref: Ast.TypeRef) anyerror!void {
        _ = self;
        switch (type_ref) {
            .primitive => |p| {
                const init_val: []const u8 = switch (p) {
                    .boolean => "false",
                    .octet, .uint8, .char, .wchar => "0",
                    .short, .int16, .unsigned_short, .uint16 => "0",
                    .long, .int32, .unsigned_long, .uint32 => "0",
                    .long_long, .int64, .unsigned_long_long, .uint64 => "0",
                    .float, .double, .long_double, .fixed => "0.0",
                    .string => "\"\"",
                    .wstring => "&.{}",
                    .void => "{}",
                    .int8 => "0",
                };
                try writer.writeAll(init_val);
            },
            .string_bounded => |bound| {
                try writer.print("std.mem.zeroes([{d}:0]u8)", .{bound});
            },
            .wstring_bounded => |bound| {
                try writer.print("std.mem.zeroes([{d}]u16)", .{bound});
            },
            .sequence => |seq| {
                if (seq.bound) |b| {
                    try writer.print("undefined", .{});
                    _ = b;
                } else {
                    try writer.writeAll("&.{}");
                }
            },
            .array => {
                try writer.writeAll("undefined");
            },
            .scoped_name => {
                try writer.writeAll("undefined");
            },
        }
    }

    fn emitDoc(self: *ZigEmitter, writer: anytype, doc: ?[]const u8) !void {
        if (doc) |d| {
            var lines = std.mem.splitScalar(u8, d, '\n');
            while (lines.next()) |l| {
                try self.writeIndent(writer);
                if (std.mem.startsWith(u8, l, "///")) {
                    try writer.print("{s}\n", .{l});
                } else {
                    try writer.print("/// {s}\n", .{l});
                }
            }
        }
    }

    fn writeIndent(self: *ZigEmitter, writer: anytype) !void {
        var i: usize = 0;
        while (i < self.indent_level * 4) : (i += 1) {
            try writer.writeByte(' ');
        }
    }
};

test "ZigEmitter generates idiomatic Zig structs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var emitter = ZigEmitter.init(allocator);

    const point_struct = Ast.StructDef{
        .name = "Point3D",
        .fields = &.{
            .{ .name = "id", .type_ref = .{ .primitive = .long }, .annotations = &.{.{ .name = "key" }} },
            .{ .name = "x", .type_ref = .{ .primitive = .double } },
            .{ .name = "y", .type_ref = .{ .primitive = .double } },
            .{ .name = "z", .type_ref = .{ .primitive = .double } },
        },
    };

    const ast = Ast.AstRoot{
        .declarations = &.{
            Ast.Declaration{ .struct_def = point_struct },
        },
    };

    const code = try emitter.emitSource(ast);
    defer allocator.free(code);

    try std.testing.expect(std.mem.indexOf(u8, code, "pub const Point3D = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "id: i32 = 0,") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "x: f64 = 0.0,") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "pub const ddz_keys = [_][]const u8{") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "\"id\",") != null);
}
