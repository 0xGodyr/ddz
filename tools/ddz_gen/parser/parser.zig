//! @file parser.zig
//! @brief Recursive descent parser constructing AST nodes from IDL token streams.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const Diagnostics = @import("../diagnostics.zig");
const token = @import("../lexer/token.zig");
const Token = token.Token;
const TokenKind = token.TokenKind;
const Lexer = @import("../lexer/lexer.zig").Lexer;
const Ast = @import("../ast/ast.zig");
const ConstEvaluator = @import("const_evaluator.zig").ConstEvaluator;

pub const Parser = struct {
    allocator: std.mem.Allocator,
    lexer: Lexer,
    current_token: Token,
    diagnostics: *Diagnostics.DiagnosticEngine,
    current_doc_comment: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, source: []const u8, file_path: []const u8, diag: *Diagnostics.DiagnosticEngine) Parser {
        const lex = Lexer.init(source, file_path, diag);
        var p = Parser{
            .allocator = allocator,
            .lexer = lex,
            .current_token = undefined,
            .diagnostics = diag,
        };
        p.advance();
        return p;
    }

    fn advance(self: *Parser) void {
        while (true) {
            self.current_token = self.lexer.next();
            if (self.current_token.kind == .doc_comment) {
                self.current_doc_comment = self.current_token.text;
            } else {
                break;
            }
        }
    }

    fn peekKind(self: *const Parser) TokenKind {
        return self.current_token.kind;
    }

    fn consume(self: *Parser, kind: TokenKind, msg: []const u8) !Token {
        if (self.current_token.kind == kind) {
            const tok = self.current_token;
            self.advance();
            return tok;
        }
        try self.diagnostics.report(.err, self.current_token.location, "expected {s}, found '{s}'", .{ msg, self.current_token.text });
        return error.ParseError;
    }

    fn match(self: *Parser, kind: TokenKind) bool {
        if (self.current_token.kind == kind) {
            self.advance();
            return true;
        }
        return false;
    }

    pub fn parseRoot(self: *Parser) !Ast.AstRoot {
        var decls: std.ArrayListUnmanaged(Ast.Declaration) = .empty;
        errdefer decls.deinit(self.allocator);

        while (self.current_token.kind != .eof) {
            if (try self.parseDeclaration()) |decl| {
                try decls.append(self.allocator, decl);
            }
        }

        return .{ .declarations = try decls.toOwnedSlice(self.allocator) };
    }

    pub fn parseDeclaration(self: *Parser) anyerror!?Ast.Declaration {
        const doc = self.consumeDocComment();
        const annotations = try self.parseAnnotations();

        switch (self.current_token.kind) {
            .kw_module => {
                const mod = try self.parseModule(doc);
                return Ast.Declaration{ .module = mod };
            },
            .kw_struct => {
                const s = try self.parseStruct(annotations, doc);
                return Ast.Declaration{ .struct_def = s };
            },
            .kw_enum => {
                const e = try self.parseEnum(annotations, doc);
                return Ast.Declaration{ .enum_def = e };
            },
            .kw_union => {
                const u = try self.parseUnion(annotations, doc);
                return Ast.Declaration{ .union_def = u };
            },
            .kw_bitmask => {
                const bm = try self.parseBitmask(annotations, doc);
                return Ast.Declaration{ .bitmask_def = bm };
            },
            .kw_bitset => {
                const bs = try self.parseBitset(annotations, doc);
                return Ast.Declaration{ .bitset_def = bs };
            },
            .kw_typedef => {
                const td = try self.parseTypedef(doc);
                return Ast.Declaration{ .typedef_def = td };
            },
            .kw_const => {
                const cd = try self.parseConst(doc);
                return Ast.Declaration{ .const_def = cd };
            },
            .kw_interface => {
                const iface = try self.parseInterface(annotations, doc);
                return Ast.Declaration{ .interface_def = iface };
            },
            .semicolon => {
                self.advance();
                return null;
            },
            .eof => return null,
            else => {
                try self.diagnostics.report(.err, self.current_token.location, "unexpected token '{s}' at top level", .{self.current_token.text});
                self.advance();
                return error.ParseError;
            },
        }
    }

    fn parseAnnotations(self: *Parser) ![]const Ast.Annotation {
        var list: std.ArrayListUnmanaged(Ast.Annotation) = .empty;
        errdefer list.deinit(self.allocator);

        while (self.current_token.kind == .annotation_ident) {
            const raw_text = self.current_token.text;
            self.advance();

            // Strip leading '@'
            const name = if (raw_text.len > 0 and raw_text[0] == '@') raw_text[1..] else raw_text;
            var value: ?[]const u8 = null;

            if (self.match(.l_paren)) {
                if (self.current_token.kind != .r_paren) {
                    value = self.current_token.text;
                    self.advance();
                }
                _ = try self.consume(.r_paren, "')' to close annotation");
            }

            try list.append(self.allocator, .{ .name = name, .value = value });
        }

        return try list.toOwnedSlice(self.allocator);
    }

    fn parseModule(self: *Parser, doc: ?[]const u8) anyerror!*Ast.ModuleDef {
        _ = try self.consume(.kw_module, "'module'");
        const name_tok = try self.consume(.identifier, "module name");
        _ = try self.consume(.l_brace, "'{' after module name");

        var decls: std.ArrayListUnmanaged(Ast.Declaration) = .empty;
        errdefer decls.deinit(self.allocator);

        while (self.current_token.kind != .r_brace and self.current_token.kind != .eof) {
            if (try self.parseDeclaration()) |decl| {
                try decls.append(self.allocator, decl);
            }
        }

        _ = try self.consume(.r_brace, "'}' to close module");
        _ = try self.consume(.semicolon, "';' after module closing brace");

        const mod = try self.allocator.create(Ast.ModuleDef);
        mod.* = .{
            .name = name_tok.text,
            .declarations = try decls.toOwnedSlice(self.allocator),
            .doc_comment = doc,
        };
        return mod;
    }

    fn parseStruct(self: *Parser, annotations: []const Ast.Annotation, doc: ?[]const u8) !Ast.StructDef {
        _ = try self.consume(.kw_struct, "'struct'");
        const name_tok = try self.consume(.identifier, "struct name");

        var base_type: ?Ast.ScopedName = null;
        if (self.match(.colon)) {
            base_type = try self.parseScopedName();
        }

        _ = try self.consume(.l_brace, "'{' after struct name");

        var fields: std.ArrayListUnmanaged(Ast.Field) = .empty;
        errdefer fields.deinit(self.allocator);

        while (self.current_token.kind != .r_brace and self.current_token.kind != .eof) {
            const field_doc = self.consumeDocComment();
            const field_annotations = try self.parseAnnotations();

            const field_type = try self.parseTypeRef();
            const field_name_tok = try self.consume(.identifier, "field name");

            // Check for array dimensions e.g. "field[16][32]"
            var dimensions: std.ArrayListUnmanaged(u32) = .empty;
            defer dimensions.deinit(self.allocator);
            while (self.match(.l_bracket)) {
                const dim_tok = try self.consume(.int_literal, "array dimension");
                const dim = ConstEvaluator.parseI64(dim_tok.text) orelse 0;
                try dimensions.append(self.allocator, @intCast(dim));
                _ = try self.consume(.r_bracket, "']'");
            }

            var final_type = field_type;
            if (dimensions.items.len > 0) {
                const arr = try self.allocator.create(Ast.ArrayType);
                arr.* = .{
                    .element_type = field_type,
                    .dimensions = try dimensions.toOwnedSlice(self.allocator),
                };
                final_type = .{ .array = arr };
            }

            var default_val: ?[]const u8 = null;
            if (self.match(.equal)) {
                default_val = self.current_token.text;
                self.advance();
            }

            _ = try self.consume(.semicolon, "';' after field declaration");

            try fields.append(self.allocator, .{
                .name = field_name_tok.text,
                .type_ref = final_type,
                .annotations = field_annotations,
                .doc_comment = field_doc,
                .default_value = default_val,
            });
        }

        _ = try self.consume(.r_brace, "'}' to close struct");
        _ = try self.consume(.semicolon, "';' after struct closing brace");

        return .{
            .name = name_tok.text,
            .base_type = base_type,
            .fields = try fields.toOwnedSlice(self.allocator),
            .annotations = annotations,
            .doc_comment = doc,
        };
    }

    fn parseEnum(self: *Parser, annotations: []const Ast.Annotation, doc: ?[]const u8) !Ast.EnumDef {
        _ = try self.consume(.kw_enum, "'enum'");
        const name_tok = try self.consume(.identifier, "enum name");
        _ = try self.consume(.l_brace, "'{' after enum name");

        var members: std.ArrayListUnmanaged(Ast.EnumMember) = .empty;
        errdefer members.deinit(self.allocator);

        while (self.current_token.kind != .r_brace and self.current_token.kind != .eof) {
            const mem_doc = self.consumeDocComment();
            const mem_name = try self.consume(.identifier, "enum member name");

            var mem_val: ?i64 = null;
            if (self.match(.equal)) {
                const val_tok = self.current_token;
                self.advance();
                mem_val = ConstEvaluator.evalIntExpr(val_tok.text);
            }

            try members.append(self.allocator, .{
                .name = mem_name.text,
                .value = mem_val,
                .doc_comment = mem_doc,
            });

            if (!self.match(.comma)) {
                break;
            }
        }

        _ = try self.consume(.r_brace, "'}' to close enum");
        _ = try self.consume(.semicolon, "';' after enum closing brace");

        return .{
            .name = name_tok.text,
            .members = try members.toOwnedSlice(self.allocator),
            .annotations = annotations,
            .doc_comment = doc,
        };
    }

    fn parseUnion(self: *Parser, annotations: []const Ast.Annotation, doc: ?[]const u8) !Ast.UnionDef {
        _ = try self.consume(.kw_union, "'union'");
        const name_tok = try self.consume(.identifier, "union name");
        _ = try self.consume(.kw_switch, "'switch'");
        _ = try self.consume(.l_paren, "'('");
        const disc_type = try self.parseTypeRef();
        _ = try self.consume(.r_paren, "')'");
        _ = try self.consume(.l_brace, "'{'");

        var cases: std.ArrayListUnmanaged(Ast.UnionCase) = .empty;
        errdefer cases.deinit(self.allocator);

        while (self.current_token.kind != .r_brace and self.current_token.kind != .eof) {
            var labels: std.ArrayListUnmanaged(Ast.UnionCaseLabel) = .empty;
            defer labels.deinit(self.allocator);

            while (self.peekKind() == .kw_case or self.peekKind() == .kw_default) {
                if (self.match(.kw_case)) {
                    const label_tok = self.current_token;
                    self.advance();
                    const val = ConstEvaluator.evalIntExpr(label_tok.text) orelse 0;
                    _ = try self.consume(.colon, "':' after case value");
                    try labels.append(self.allocator, .{ .value = val });
                } else if (self.match(.kw_default)) {
                    _ = try self.consume(.colon, "':' after default");
                    try labels.append(self.allocator, .{ .default_case = {} });
                }
            }

            const field_doc = self.consumeDocComment();
            const field_type = try self.parseTypeRef();
            const field_name = try self.consume(.identifier, "union member name");
            _ = try self.consume(.semicolon, "';'");

            try cases.append(self.allocator, .{
                .labels = try labels.toOwnedSlice(self.allocator),
                .field = .{
                    .name = field_name.text,
                    .type_ref = field_type,
                    .doc_comment = field_doc,
                },
            });
        }

        _ = try self.consume(.r_brace, "'}' to close union");
        _ = try self.consume(.semicolon, "';'");

        return .{
            .name = name_tok.text,
            .discriminant_type = disc_type,
            .cases = try cases.toOwnedSlice(self.allocator),
            .annotations = annotations,
            .doc_comment = doc,
        };
    }

    fn parseBitmask(self: *Parser, annotations: []const Ast.Annotation, doc: ?[]const u8) !Ast.BitmaskDef {
        _ = try self.consume(.kw_bitmask, "'bitmask'");
        const name_tok = try self.consume(.identifier, "bitmask name");
        _ = try self.consume(.l_brace, "'{'");

        var flags: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer flags.deinit(self.allocator);

        while (self.current_token.kind != .r_brace and self.current_token.kind != .eof) {
            const flag_name = try self.consume(.identifier, "bitmask flag identifier");
            try flags.append(self.allocator, flag_name.text);
            if (!self.match(.comma)) break;
        }

        _ = try self.consume(.r_brace, "'}' to close bitmask");
        _ = try self.consume(.semicolon, "';'");

        var bit_bound: u16 = 32;
        for (annotations) |ann| {
            if (std.mem.eql(u8, ann.name, "bit_bound")) {
                if (ann.value) |v| {
                    bit_bound = @intCast(ConstEvaluator.parseI64(v) orelse 32);
                }
            }
        }

        return .{
            .name = name_tok.text,
            .bit_bound = bit_bound,
            .flags = try flags.toOwnedSlice(self.allocator),
            .annotations = annotations,
            .doc_comment = doc,
        };
    }

    fn parseBitset(self: *Parser, annotations: []const Ast.Annotation, doc: ?[]const u8) !Ast.BitsetDef {
        _ = try self.consume(.kw_bitset, "'bitset'");
        const name_tok = try self.consume(.identifier, "bitset name");
        _ = try self.consume(.l_brace, "'{'");

        var fields: std.ArrayListUnmanaged(Ast.BitsetField) = .empty;
        errdefer fields.deinit(self.allocator);

        while (self.current_token.kind != .r_brace and self.current_token.kind != .eof) {
            _ = try self.consume(.identifier, "'bitfield'");
            _ = try self.consume(.l_angle, "'<'");
            const size_tok = try self.consume(.int_literal, "bitfield size");
            const sz: u16 = @intCast(ConstEvaluator.parseI64(size_tok.text) orelse 1);
            _ = try self.consume(.r_angle, "'>'");
            const f_name = try self.consume(.identifier, "bitfield name");
            _ = try self.consume(.semicolon, "';'");

            try fields.append(self.allocator, .{ .name = f_name.text, .bit_size = sz });
        }

        _ = try self.consume(.r_brace, "'}' to close bitset");
        _ = try self.consume(.semicolon, "';'");

        return .{
            .name = name_tok.text,
            .fields = try fields.toOwnedSlice(self.allocator),
            .annotations = annotations,
            .doc_comment = doc,
        };
    }

    fn parseTypedef(self: *Parser, doc: ?[]const u8) !Ast.TypedefDef {
        _ = try self.consume(.kw_typedef, "'typedef'");
        const target = try self.parseTypeRef();
        const alias = try self.consume(.identifier, "typedef alias name");
        _ = try self.consume(.semicolon, "';'");

        return .{
            .name = alias.text,
            .target_type = target,
            .doc_comment = doc,
        };
    }

    fn parseConst(self: *Parser, doc: ?[]const u8) !Ast.ConstDef {
        _ = try self.consume(.kw_const, "'const'");
        const c_type = try self.parseTypeRef();
        const c_name = try self.consume(.identifier, "constant name");
        _ = try self.consume(.equal, "'='");
        const val_tok = self.current_token;
        self.advance();
        _ = try self.consume(.semicolon, "';'");

        const i_val = ConstEvaluator.evalIntExpr(val_tok.text);
        const f_val = ConstEvaluator.parseF64(val_tok.text);

        return .{
            .name = c_name.text,
            .const_type = c_type,
            .value_repr = val_tok.text,
            .int_val = i_val,
            .float_val = f_val,
            .doc_comment = doc,
        };
    }

    fn parseInterface(self: *Parser, annotations: []const Ast.Annotation, doc: ?[]const u8) !Ast.InterfaceDef {
        _ = try self.consume(.kw_interface, "'interface'");
        const name_tok = try self.consume(.identifier, "interface name");

        var base: ?Ast.ScopedName = null;
        if (self.match(.colon)) {
            base = try self.parseScopedName();
        }

        _ = try self.consume(.l_brace, "'{'");

        var ops: std.ArrayListUnmanaged(Ast.Operation) = .empty;
        errdefer ops.deinit(self.allocator);

        while (self.current_token.kind != .r_brace and self.current_token.kind != .eof) {
            const op_doc = self.consumeDocComment();
            var oneway = false;
            if (self.match(.kw_oneway)) {
                oneway = true;
            }

            const ret_type = try self.parseTypeRef();
            const op_name = try self.consume(.identifier, "operation name");
            _ = try self.consume(.l_paren, "'('");

            var params: std.ArrayListUnmanaged(Ast.Parameter) = .empty;
            defer params.deinit(self.allocator);

            while (self.current_token.kind != .r_paren and self.current_token.kind != .eof) {
                var dir: Ast.ParameterDirection = .in;
                if (self.match(.kw_in)) {
                    dir = .in;
                } else if (self.match(.kw_out)) {
                    dir = .out;
                } else if (self.match(.kw_inout)) {
                    dir = .inout;
                }

                const p_type = try self.parseTypeRef();
                const p_name = try self.consume(.identifier, "parameter name");

                try params.append(self.allocator, .{
                    .direction = dir,
                    .param_type = p_type,
                    .name = p_name.text,
                });

                if (!self.match(.comma)) break;
            }

            _ = try self.consume(.r_paren, "')'");
            _ = try self.consume(.semicolon, "';'");

            try ops.append(self.allocator, .{
                .name = op_name.text,
                .return_type = ret_type,
                .params = try params.toOwnedSlice(self.allocator),
                .is_oneway = oneway,
                .doc_comment = op_doc,
            });
        }

        _ = try self.consume(.r_brace, "'}' to close interface");
        _ = try self.consume(.semicolon, "';'");

        return .{
            .name = name_tok.text,
            .base_interface = base,
            .operations = try ops.toOwnedSlice(self.allocator),
            .annotations = annotations,
            .doc_comment = doc,
        };
    }

    pub fn parseTypeRef(self: *Parser) anyerror!Ast.TypeRef {
        switch (self.current_token.kind) {
            .kw_boolean => {
                self.advance();
                return .{ .primitive = .boolean };
            },
            .kw_octet => {
                self.advance();
                return .{ .primitive = .octet };
            },
            .kw_char => {
                self.advance();
                return .{ .primitive = .char };
            },
            .kw_wchar => {
                self.advance();
                return .{ .primitive = .wchar };
            },
            .kw_short => {
                self.advance();
                return .{ .primitive = .short };
            },
            .kw_long => {
                self.advance();
                if (self.match(.kw_long)) {
                    return .{ .primitive = .long_long };
                } else if (self.match(.kw_double)) {
                    return .{ .primitive = .long_double };
                }
                return .{ .primitive = .long };
            },
            .kw_unsigned => {
                self.advance();
                if (self.match(.kw_short)) {
                    return .{ .primitive = .unsigned_short };
                } else if (self.match(.kw_long)) {
                    if (self.match(.kw_long)) {
                        return .{ .primitive = .unsigned_long_long };
                    }
                    return .{ .primitive = .unsigned_long };
                }
                return .{ .primitive = .unsigned_long };
            },
            .kw_float => {
                self.advance();
                return .{ .primitive = .float };
            },
            .kw_double => {
                self.advance();
                return .{ .primitive = .double };
            },
            .kw_void => {
                self.advance();
                return .{ .primitive = .void };
            },
            .kw_int8 => {
                self.advance();
                return .{ .primitive = .int8 };
            },
            .kw_uint8 => {
                self.advance();
                return .{ .primitive = .uint8 };
            },
            .kw_int16 => {
                self.advance();
                return .{ .primitive = .int16 };
            },
            .kw_uint16 => {
                self.advance();
                return .{ .primitive = .uint16 };
            },
            .kw_int32 => {
                self.advance();
                return .{ .primitive = .int32 };
            },
            .kw_uint32 => {
                self.advance();
                return .{ .primitive = .uint32 };
            },
            .kw_int64 => {
                self.advance();
                return .{ .primitive = .int64 };
            },
            .kw_uint64 => {
                self.advance();
                return .{ .primitive = .uint64 };
            },
            .kw_string => {
                self.advance();
                if (self.match(.l_angle)) {
                    const bound_tok = try self.consume(.int_literal, "string bound");
                    const bound: u32 = @intCast(ConstEvaluator.parseI64(bound_tok.text) orelse 0);
                    _ = try self.consume(.r_angle, "'>'");
                    return .{ .string_bounded = bound };
                }
                return .{ .primitive = .string };
            },
            .kw_wstring => {
                self.advance();
                if (self.match(.l_angle)) {
                    const bound_tok = try self.consume(.int_literal, "wstring bound");
                    const bound: u32 = @intCast(ConstEvaluator.parseI64(bound_tok.text) orelse 0);
                    _ = try self.consume(.r_angle, "'>'");
                    return .{ .wstring_bounded = bound };
                }
                return .{ .primitive = .wstring };
            },
            .kw_sequence => {
                self.advance();
                _ = try self.consume(.l_angle, "'<' after 'sequence'");
                const elem = try self.parseTypeRef();
                var bound: ?u32 = null;
                if (self.match(.comma)) {
                    const b_tok = try self.consume(.int_literal, "sequence bound");
                    bound = @intCast(ConstEvaluator.parseI64(b_tok.text) orelse 0);
                }
                _ = try self.consume(.r_angle, "'>' to close sequence");

                const seq = try self.allocator.create(Ast.SequenceType);
                seq.* = .{ .element_type = elem, .bound = bound };
                return .{ .sequence = seq };
            },
            .identifier, .colon_colon => {
                const sn = try self.parseScopedName();
                return .{ .scoped_name = sn };
            },
            else => {
                try self.diagnostics.report(.err, self.current_token.location, "expected type name, found '{s}'", .{self.current_token.text});
                return error.ParseError;
            },
        }
    }

    fn parseScopedName(self: *Parser) !Ast.ScopedName {
        var segs: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer segs.deinit(self.allocator);

        _ = self.match(.colon_colon); // optional leading ::
        const first = try self.consume(.identifier, "identifier in scoped name");
        try segs.append(self.allocator, first.text);

        while (self.match(.colon_colon)) {
            const next_seg = try self.consume(.identifier, "identifier after '::'");
            try segs.append(self.allocator, next_seg.text);
        }

        return .{ .segments = try segs.toOwnedSlice(self.allocator) };
    }

    fn consumeDocComment(self: *Parser) ?[]const u8 {
        const doc = self.current_doc_comment;
        self.current_doc_comment = null;
        return doc;
    }
};

test "Parser complex IDL parsing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var diag = Diagnostics.DiagnosticEngine.init(allocator);
    defer diag.deinit();

    const src =
        \\module Robotics {
        \\    enum MotorState {
        \\        OFF,
        \\        RUNNING = 1,
        \\        FAULT = 99
        \\    };
        \\
        \\    @key struct Telemetry {
        \\        @key long robot_id;
        \\        double battery;
        \\        sequence<float, 10> sensor_readings;
        \\        string<64> model_name;
        \\    };
        \\
        \\    interface MotorController {
        \\        long setSpeed(in float speed);
        \\    };
        \\};
    ;

    var parser = Parser.init(allocator, src, "test.idl", &diag);
    const ast = try parser.parseRoot();

    try std.testing.expectEqual(@as(usize, 1), ast.declarations.len);
    const mod = ast.declarations[0].module;
    try std.testing.expectEqualStrings("Robotics", mod.name);
    try std.testing.expectEqual(@as(usize, 3), mod.declarations.len);

    const enum_decl = mod.declarations[0].enum_def;
    try std.testing.expectEqualStrings("MotorState", enum_decl.name);
    try std.testing.expectEqual(@as(usize, 3), enum_decl.members.len);

    const struct_decl = mod.declarations[1].struct_def;
    try std.testing.expectEqualStrings("Telemetry", struct_decl.name);
    try std.testing.expect(struct_decl.hasKeys());
    try std.testing.expectEqual(@as(usize, 4), struct_decl.fields.len);

    const iface_decl = mod.declarations[2].interface_def;
    try std.testing.expectEqualStrings("MotorController", iface_decl.name);
    try std.testing.expectEqual(@as(usize, 1), iface_decl.operations.len);
}
