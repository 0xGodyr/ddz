//! @file lexer.zig
//! @brief Lexical analyzer and token stream generator for OMG IDL 4.2.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const Diagnostics = @import("../diagnostics.zig");
const token = @import("token.zig");
const Token = token.Token;
const TokenKind = token.TokenKind;

pub const Lexer = struct {
    source: []const u8,
    file_path: []const u8,
    cursor: usize = 0,
    line: usize = 1,
    col: usize = 1,
    diagnostics: *Diagnostics.DiagnosticEngine,

    pub fn init(source: []const u8, file_path: []const u8, diag: *Diagnostics.DiagnosticEngine) Lexer {
        return .{
            .source = source,
            .file_path = file_path,
            .diagnostics = diag,
        };
    }

    pub fn next(self: *Lexer) Token {
        self.skipWhitespace();

        if (self.isAtEnd()) {
            return .{
                .kind = .eof,
                .text = "",
                .location = self.currentLoc(),
            };
        }

        const start_loc = self.currentLoc();
        const start_pos = self.cursor;
        const c = self.advance();

        // Doc comment "///"
        if (c == '/' and self.peek() == '/' and self.peekNext() == '/') {
            _ = self.advance();
            _ = self.advance();
            while (!self.isAtEnd() and self.peek() != '\n') {
                _ = self.advance();
            }
            return .{
                .kind = .doc_comment,
                .text = self.source[start_pos..self.cursor],
                .location = start_loc,
            };
        }

        // Annotations e.g. @key, @id, @optional
        if (c == '@') {
            if (isAlpha(self.peek()) or self.peek() == '_') {
                while (!self.isAtEnd() and (isAlNum(self.peek()) or self.peek() == '_')) {
                    _ = self.advance();
                }
                return .{
                    .kind = .annotation_ident,
                    .text = self.source[start_pos..self.cursor],
                    .location = start_loc,
                };
            }
            return .{
                .kind = .at_sign,
                .text = "@",
                .location = start_loc,
            };
        }

        // Punctuation & Delimiters
        switch (c) {
            '{' => return .{ .kind = .l_brace, .text = "{", .location = start_loc },
            '}' => return .{ .kind = .r_brace, .text = "}", .location = start_loc },
            '(' => return .{ .kind = .l_paren, .text = "(", .location = start_loc },
            ')' => return .{ .kind = .r_paren, .text = ")", .location = start_loc },
            '[' => return .{ .kind = .l_bracket, .text = "[", .location = start_loc },
            ']' => return .{ .kind = .r_bracket, .text = "]", .location = start_loc },
            ';' => return .{ .kind = .semicolon, .text = ";", .location = start_loc },
            ',' => return .{ .kind = .comma, .text = ",", .location = start_loc },
            '=' => return .{ .kind = .equal, .text = "=", .location = start_loc },
            '+' => return .{ .kind = .plus, .text = "+", .location = start_loc },
            '-' => return .{ .kind = .minus, .text = "-", .location = start_loc },
            '*' => return .{ .kind = .asterisk, .text = "*", .location = start_loc },
            '/' => return .{ .kind = .slash, .text = "/", .location = start_loc },
            '%' => return .{ .kind = .percent, .text = "%", .location = start_loc },
            '~' => return .{ .kind = .tilde, .text = "~", .location = start_loc },
            '&' => return .{ .kind = .ampersand, .text = "&", .location = start_loc },
            '|' => return .{ .kind = .pipe, .text = "|", .location = start_loc },
            '^' => return .{ .kind = .caret, .text = "^", .location = start_loc },
            ':' => {
                if (self.peek() == ':') {
                    _ = self.advance();
                    return .{ .kind = .colon_colon, .text = "::", .location = start_loc };
                }
                return .{ .kind = .colon, .text = ":", .location = start_loc };
            },
            '<' => {
                if (self.peek() == '<') {
                    _ = self.advance();
                    return .{ .kind = .shl, .text = "<<", .location = start_loc };
                }
                return .{ .kind = .l_angle, .text = "<", .location = start_loc };
            },
            '>' => {
                if (self.peek() == '>') {
                    _ = self.advance();
                    return .{ .kind = .shr, .text = ">>", .location = start_loc };
                }
                return .{ .kind = .r_angle, .text = ">", .location = start_loc };
            },
            '"' => {
                // String literal
                while (!self.isAtEnd() and self.peek() != '"') {
                    if (self.peek() == '\\') {
                        _ = self.advance();
                    }
                    if (!self.isAtEnd()) {
                        _ = self.advance();
                    }
                }
                if (!self.isAtEnd() and self.peek() == '"') {
                    _ = self.advance();
                    return .{
                        .kind = .string_literal,
                        .text = self.source[start_pos..self.cursor],
                        .location = start_loc,
                    };
                }
                self.diagnostics.report(.err, start_loc, "unterminated string literal", .{}) catch {};
                return .{ .kind = .invalid, .text = self.source[start_pos..self.cursor], .location = start_loc };
            },
            '\'' => {
                // Char literal
                if (!self.isAtEnd()) {
                    if (self.peek() == '\\') {
                        _ = self.advance();
                    }
                    _ = self.advance();
                    if (!self.isAtEnd() and self.peek() == '\'') {
                        _ = self.advance();
                        return .{
                            .kind = .char_literal,
                            .text = self.source[start_pos..self.cursor],
                            .location = start_loc,
                        };
                    }
                }
                self.diagnostics.report(.err, start_loc, "unterminated char literal", .{}) catch {};
                return .{ .kind = .invalid, .text = self.source[start_pos..self.cursor], .location = start_loc };
            },
            else => {},
        }

        // Numbers (hex, octal, decimal, float)
        if (isDigit(c)) {
            if (c == '0' and (self.peek() == 'x' or self.peek() == 'X')) {
                // Hex
                _ = self.advance();
                while (!self.isAtEnd() and isHexDigit(self.peek())) {
                    _ = self.advance();
                }
                return .{
                    .kind = .int_literal,
                    .text = self.source[start_pos..self.cursor],
                    .location = start_loc,
                };
            }

            var is_float = false;
            while (!self.isAtEnd() and isDigit(self.peek())) {
                _ = self.advance();
            }

            if (!self.isAtEnd() and self.peek() == '.' and isDigit(self.peekNext())) {
                is_float = true;
                _ = self.advance(); // '.'
                while (!self.isAtEnd() and isDigit(self.peek())) {
                    _ = self.advance();
                }
            }

            if (!self.isAtEnd() and (self.peek() == 'e' or self.peek() == 'E')) {
                is_float = true;
                _ = self.advance();
                if (!self.isAtEnd() and (self.peek() == '+' or self.peek() == '-')) {
                    _ = self.advance();
                }
                while (!self.isAtEnd() and isDigit(self.peek())) {
                    _ = self.advance();
                }
            }

            if (!self.isAtEnd() and (self.peek() == 'f' or self.peek() == 'F')) {
                is_float = true;
                _ = self.advance();
            }

            return .{
                .kind = if (is_float) .float_literal else .int_literal,
                .text = self.source[start_pos..self.cursor],
                .location = start_loc,
            };
        }

        // Identifiers & Keywords
        if (isAlpha(c) or c == '_') {
            while (!self.isAtEnd() and (isAlNum(self.peek()) or self.peek() == '_')) {
                _ = self.advance();
            }
            const ident_text = self.source[start_pos..self.cursor];
            const kind = checkKeyword(ident_text);
            return .{
                .kind = kind,
                .text = ident_text,
                .location = start_loc,
            };
        }

        self.diagnostics.report(.err, start_loc, "unexpected character '{c}'", .{c}) catch {};
        return .{
            .kind = .invalid,
            .text = self.source[start_pos..self.cursor],
            .location = start_loc,
        };
    }

    fn checkKeyword(text: []const u8) TokenKind {
        const keywords = std.StaticStringMap(TokenKind).initComptime(.{
            .{ "module", .kw_module },
            .{ "struct", .kw_struct },
            .{ "union", .kw_union },
            .{ "switch", .kw_switch },
            .{ "case", .kw_case },
            .{ "default", .kw_default },
            .{ "enum", .kw_enum },
            .{ "bitset", .kw_bitset },
            .{ "bitmask", .kw_bitmask },
            .{ "typedef", .kw_typedef },
            .{ "const", .kw_const },
            .{ "interface", .kw_interface },
            .{ "sequence", .kw_sequence },
            .{ "string", .kw_string },
            .{ "wstring", .kw_wstring },
            .{ "fixed", .kw_fixed },
            .{ "map", .kw_map },
            .{ "octet", .kw_octet },
            .{ "short", .kw_short },
            .{ "long", .kw_long },
            .{ "unsigned", .kw_unsigned },
            .{ "float", .kw_float },
            .{ "double", .kw_double },
            .{ "boolean", .kw_boolean },
            .{ "char", .kw_char },
            .{ "wchar", .kw_wchar },
            .{ "void", .kw_void },
            .{ "int8", .kw_int8 },
            .{ "uint8", .kw_uint8 },
            .{ "int16", .kw_int16 },
            .{ "uint16", .kw_uint16 },
            .{ "int32", .kw_int32 },
            .{ "uint32", .kw_uint32 },
            .{ "int64", .kw_int64 },
            .{ "uint64", .kw_uint64 },
            .{ "in", .kw_in },
            .{ "out", .kw_out },
            .{ "inout", .kw_inout },
            .{ "oneway", .kw_oneway },
            .{ "TRUE", .kw_true },
            .{ "FALSE", .kw_false },
        });

        return keywords.get(text) orelse .identifier;
    }

    fn skipWhitespace(self: *Lexer) void {
        while (!self.isAtEnd()) {
            const c = self.peek();
            switch (c) {
                ' ', '\t', '\r' => {
                    _ = self.advance();
                },
                '\n' => {
                    self.line += 1;
                    self.col = 1;
                    self.cursor += 1;
                },
                else => break,
            }
        }
    }

    fn peek(self: *const Lexer) u8 {
        if (self.isAtEnd()) return 0;
        return self.source[self.cursor];
    }

    fn peekNext(self: *const Lexer) u8 {
        if (self.cursor + 1 >= self.source.len) return 0;
        return self.source[self.cursor + 1];
    }

    fn advance(self: *Lexer) u8 {
        const c = self.source[self.cursor];
        self.cursor += 1;
        self.col += 1;
        return c;
    }

    fn isAtEnd(self: *const Lexer) bool {
        return self.cursor >= self.source.len;
    }

    fn currentLoc(self: *const Lexer) Diagnostics.SourceLocation {
        return .{
            .file_path = self.file_path,
            .line = self.line,
            .column = self.col,
        };
    }

    fn isAlpha(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
    }

    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    fn isAlNum(c: u8) bool {
        return isAlpha(c) or isDigit(c);
    }

    fn isHexDigit(c: u8) bool {
        return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
    }
};

test "Lexer tokenization" {
    var diag = Diagnostics.DiagnosticEngine.init(std.testing.allocator);
    defer diag.deinit();

    const src =
        \\module Geometry {
        \\    @key struct Point3D {
        \\        long id;
        \\        double x;
        \\        double y;
        \\        double z;
        \\    };
        \\};
    ;

    var lexer = Lexer.init(src, "Geometry.idl", &diag);

    var tokens: std.ArrayListUnmanaged(TokenKind) = .empty;
    defer tokens.deinit(std.testing.allocator);

    while (true) {
        const tok = lexer.next();
        try tokens.append(std.testing.allocator, tok.kind);
        if (tok.kind == .eof) break;
    }

    try std.testing.expectEqual(TokenKind.kw_module, tokens.items[0]);
    try std.testing.expectEqual(TokenKind.identifier, tokens.items[1]);
    try std.testing.expectEqual(TokenKind.l_brace, tokens.items[2]);
    try std.testing.expectEqual(TokenKind.annotation_ident, tokens.items[3]);
    try std.testing.expectEqual(TokenKind.kw_struct, tokens.items[4]);
}
