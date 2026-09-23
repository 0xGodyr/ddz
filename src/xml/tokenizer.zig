//! @file tokenizer.zig
//! @brief Zero-allocation, streaming XML pull-parser and tokenizer for Zig.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");

pub const SourceLocation = struct {
    line: usize = 1,
    column: usize = 1,
};

pub const Attribute = struct {
    name: []const u8,
    value: []const u8,
};

pub const Token = union(enum) {
    start_element: struct {
        name: []const u8,
        attributes: []const Attribute,
        is_empty: bool, // true for self-closing <tag />
    },
    end_element: struct {
        name: []const u8,
    },
    character_data: []const u8,
    comment: []const u8,
    cdata: []const u8,
    processing_instruction: struct {
        target: []const u8,
        data: []const u8,
    },
    doctype: []const u8,
    eof,
};

pub const Tokenizer = struct {
    source: []const u8,
    cursor: usize = 0,
    line: usize = 1,
    column: usize = 1,

    // Internal attribute buffer for zero-allocation start_element tokens
    attr_buffer: [64]Attribute = undefined,

    // When an empty tag is parsed, if caller requested separate end element tokens
    pending_end_tag: ?[]const u8 = null,

    pub fn init(source: []const u8) Tokenizer {
        return .{
            .source = source,
        };
    }

    pub fn getLocation(self: *const Tokenizer) SourceLocation {
        return .{
            .line = self.line,
            .column = self.column,
        };
    }

    pub fn next(self: *Tokenizer) !Token {
        if (self.pending_end_tag) |end_tag| {
            self.pending_end_tag = null;
            return Token{ .end_element = .{ .name = end_tag } };
        }

        while (self.cursor < self.source.len) {
            const ch = self.source[self.cursor];

            if (ch == '<') {
                return try self.lexTag();
            } else {
                // Character data
                const text_start = self.cursor;
                while (self.cursor < self.source.len and self.source[self.cursor] != '<') {
                    self.advance();
                }
                const raw_text = self.source[text_start..self.cursor];
                return Token{ .character_data = raw_text };
            }
        }

        return .eof;
    }

    fn lexTag(self: *Tokenizer) !Token {
        self.advance(); // consume '<'

        if (self.cursor >= self.source.len) return error.UnexpectedEof;

        const next_ch = self.source[self.cursor];

        // 1. End element: </tag>
        if (next_ch == '/') {
            self.advance(); // consume '/'
            self.skipWhitespace();
            const name_start = self.cursor;
            while (self.cursor < self.source.len and isNameChar(self.source[self.cursor])) {
                self.advance();
            }
            if (name_start == self.cursor) return error.InvalidXmlSyntax;
            const tag_name = self.source[name_start..self.cursor];

            self.skipWhitespace();
            if (self.cursor >= self.source.len or self.source[self.cursor] != '>') {
                return error.UnclosedTag;
            }
            self.advance(); // consume '>'
            return Token{ .end_element = .{ .name = tag_name } };
        }

        // 2. Processing instruction: <?target data?>
        if (next_ch == '?') {
            self.advance(); // consume '?'
            const target_start = self.cursor;
            while (self.cursor < self.source.len and isNameChar(self.source[self.cursor])) {
                self.advance();
            }
            const target = self.source[target_start..self.cursor];
            self.skipWhitespace();

            const data_start = self.cursor;
            while (self.cursor + 1 < self.source.len) {
                if (self.source[self.cursor] == '?' and self.source[self.cursor + 1] == '>') {
                    const data = self.source[data_start..self.cursor];
                    self.advance(); // '?'
                    self.advance(); // '>'
                    return Token{
                        .processing_instruction = .{
                            .target = target,
                            .data = std.mem.trim(u8, data, " \t\r\n"),
                        },
                    };
                }
                self.advance();
            }
            return error.UnexpectedEof;
        }

        // 3. Comments, CDATA, DOCTYPE: <!
        if (next_ch == '!') {
            self.advance(); // consume '!'

            // Comment: <!-- ... -->
            if (self.cursor + 1 < self.source.len and self.source[self.cursor] == '-' and self.source[self.cursor + 1] == '-') {
                self.advance(); // '-'
                self.advance(); // '-'
                const comment_start = self.cursor;
                while (self.cursor + 2 < self.source.len) {
                    if (self.source[self.cursor] == '-' and self.source[self.cursor + 1] == '-' and self.source[self.cursor + 2] == '>') {
                        const comment_text = self.source[comment_start..self.cursor];
                        self.advance(); // '-'
                        self.advance(); // '-'
                        self.advance(); // '>'
                        return Token{ .comment = comment_text };
                    }
                    self.advance();
                }
                return error.UnexpectedEof;
            }

            // CDATA: <![CDATA[ ... ]]>
            const cdata_prefix = "[CDATA[";
            if (self.cursor + cdata_prefix.len <= self.source.len and std.mem.eql(u8, self.source[self.cursor .. self.cursor + cdata_prefix.len], cdata_prefix)) {
                var i: usize = 0;
                while (i < cdata_prefix.len) : (i += 1) {
                    self.advance();
                }
                const cdata_start = self.cursor;
                while (self.cursor + 2 < self.source.len) {
                    if (self.source[self.cursor] == ']' and self.source[self.cursor + 1] == ']' and self.source[self.cursor + 2] == '>') {
                        const cdata_content = self.source[cdata_start..self.cursor];
                        self.advance(); // ']'
                        self.advance(); // ']'
                        self.advance(); // '>'
                        return Token{ .cdata = cdata_content };
                    }
                    self.advance();
                }
                return error.UnexpectedEof;
            }

            // DOCTYPE: <!DOCTYPE ... >
            const doctype_prefix = "DOCTYPE";
            if (self.cursor + doctype_prefix.len <= self.source.len and std.mem.eql(u8, self.source[self.cursor .. self.cursor + doctype_prefix.len], doctype_prefix)) {
                const doc_start = self.cursor;
                var depth: usize = 0;
                while (self.cursor < self.source.len) {
                    if (self.source[self.cursor] == '[') depth += 1;
                    if (self.source[self.cursor] == ']') depth -|= 1;
                    if (self.source[self.cursor] == '>' and depth == 0) {
                        const doc_content = self.source[doc_start..self.cursor];
                        self.advance(); // '>'
                        return Token{ .doctype = doc_content };
                    }
                    self.advance();
                }
                return error.UnexpectedEof;
            }

            return error.InvalidXmlSyntax;
        }

        // 4. Start element: <tag attr="val"> or <tag />
        const name_start = self.cursor;
        while (self.cursor < self.source.len and isNameChar(self.source[self.cursor])) {
            self.advance();
        }
        if (name_start == self.cursor) return error.InvalidXmlSyntax;
        const tag_name = self.source[name_start..self.cursor];

        // Parse attributes
        var attr_count: usize = 0;

        while (self.cursor < self.source.len) {
            self.skipWhitespace();

            if (self.cursor >= self.source.len) return error.UnexpectedEof;

            if (self.source[self.cursor] == '>') {
                self.advance(); // consume '>'
                return Token{
                    .start_element = .{
                        .name = tag_name,
                        .attributes = self.attr_buffer[0..attr_count],
                        .is_empty = false,
                    },
                };
            }

            if (self.source[self.cursor] == '/' and self.cursor + 1 < self.source.len and self.source[self.cursor + 1] == '>') {
                self.advance(); // consume '/'
                self.advance(); // consume '>'
                return Token{
                    .start_element = .{
                        .name = tag_name,
                        .attributes = self.attr_buffer[0..attr_count],
                        .is_empty = true,
                    },
                };
            }

            // Attribute name
            const attr_name_start = self.cursor;
            while (self.cursor < self.source.len and isNameChar(self.source[self.cursor])) {
                self.advance();
            }
            if (attr_name_start == self.cursor) return error.InvalidXmlSyntax;
            const attr_name = self.source[attr_name_start..self.cursor];

            self.skipWhitespace();
            if (self.cursor >= self.source.len or self.source[self.cursor] != '=') {
                return error.InvalidXmlSyntax;
            }
            self.advance(); // consume '='

            self.skipWhitespace();
            if (self.cursor >= self.source.len) return error.UnexpectedEof;

            const quote = self.source[self.cursor];
            if (quote != '"' and quote != '\'') {
                return error.InvalidXmlSyntax;
            }
            self.advance(); // consume quote

            const val_start = self.cursor;
            while (self.cursor < self.source.len and self.source[self.cursor] != quote) {
                self.advance();
            }
            if (self.cursor >= self.source.len) return error.UnclosedQuote;
            const attr_val = self.source[val_start..self.cursor];
            self.advance(); // consume closing quote

            if (attr_count >= self.attr_buffer.len) return error.TooManyAttributes;
            self.attr_buffer[attr_count] = .{
                .name = attr_name,
                .value = attr_val,
            };
            attr_count += 1;
        }

        return error.UnexpectedEof;
    }

    fn skipWhitespace(self: *Tokenizer) void {
        while (self.cursor < self.source.len) {
            const c = self.source[self.cursor];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                self.advance();
            } else {
                break;
            }
        }
    }

    fn advance(self: *Tokenizer) void {
        if (self.cursor < self.source.len) {
            if (self.source[self.cursor] == '\n') {
                self.line += 1;
                self.column = 1;
            } else {
                self.column += 1;
            }
            self.cursor += 1;
        }
    }
};

pub fn isNameStartChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        c == '_' or c == ':';
}

pub fn isNameChar(c: u8) bool {
    return isNameStartChar(c) or
        (c >= '0' and c <= '9') or
        c == '-' or c == '.';
}

/// Decodes standard XML entities (&amp;, &lt;, &gt;, &quot;, &apos;) from raw XML text.
pub fn decodeEntities(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '&') == null) {
        return raw;
    }

    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '&') {
            if (std.mem.startsWith(u8, raw[i..], "&amp;")) {
                try result.append(allocator, '&');
                i += 5;
            } else if (std.mem.startsWith(u8, raw[i..], "&lt;")) {
                try result.append(allocator, '<');
                i += 4;
            } else if (std.mem.startsWith(u8, raw[i..], "&gt;")) {
                try result.append(allocator, '>');
                i += 4;
            } else if (std.mem.startsWith(u8, raw[i..], "&quot;")) {
                try result.append(allocator, '"');
                i += 6;
            } else if (std.mem.startsWith(u8, raw[i..], "&apos;")) {
                try result.append(allocator, '\'');
                i += 6;
            } else {
                try result.append(allocator, raw[i]);
                i += 1;
            }
        } else {
            try result.append(allocator, raw[i]);
            i += 1;
        }
    }

    return try result.toOwnedSlice(allocator);
}

test "Tokenizer basic element parsing" {
    const xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!-- DDS Profile Configuration -->
        \\<dds xmlns="http://www.omg.org/dds">
        \\    <participant profile_name="test_node" domain_id="0">
        \\        <name>AlphaRobot</name>
        \\        <shm_transport enable="true"/>
        \\    </participant>
        \\</dds>
    ;

    var tok = Tokenizer.init(xml);

    // 1. Processing instruction
    const t1 = try tok.next();
    try std.testing.expect(t1 == .processing_instruction);
    try std.testing.expectEqualStrings("xml", t1.processing_instruction.target);

    // 2. Whitespace text
    const t2 = try tok.next();
    try std.testing.expect(t2 == .character_data);

    // 3. Comment
    const t3 = try tok.next();
    try std.testing.expect(t3 == .comment);
    try std.testing.expectEqualStrings(" DDS Profile Configuration ", t3.comment);

    // 4. Whitespace text
    _ = try tok.next();

    // 5. <dds ...>
    const t5 = try tok.next();
    try std.testing.expect(t5 == .start_element);
    try std.testing.expectEqualStrings("dds", t5.start_element.name);
    try std.testing.expectEqual(@as(usize, 1), t5.start_element.attributes.len);
    try std.testing.expectEqualStrings("xmlns", t5.start_element.attributes[0].name);
    try std.testing.expectEqualStrings("http://www.omg.org/dds", t5.start_element.attributes[0].value);
    try std.testing.expect(!t5.start_element.is_empty);

    // 6. Whitespace text
    _ = try tok.next();

    // 7. <participant profile_name="test_node" domain_id="0">
    const t7 = try tok.next();
    try std.testing.expect(t7 == .start_element);
    try std.testing.expectEqualStrings("participant", t7.start_element.name);
    try std.testing.expectEqual(@as(usize, 2), t7.start_element.attributes.len);
    try std.testing.expectEqualStrings("profile_name", t7.start_element.attributes[0].name);
    try std.testing.expectEqualStrings("test_node", t7.start_element.attributes[0].value);
    try std.testing.expectEqualStrings("domain_id", t7.start_element.attributes[1].name);
    try std.testing.expectEqualStrings("0", t7.start_element.attributes[1].value);

    // 8. Whitespace
    _ = try tok.next();

    // 9. <name>
    const t9 = try tok.next();
    try std.testing.expect(t9 == .start_element);
    try std.testing.expectEqualStrings("name", t9.start_element.name);

    // 10. AlphaRobot text
    const t10 = try tok.next();
    try std.testing.expect(t10 == .character_data);
    try std.testing.expectEqualStrings("AlphaRobot", t10.character_data);

    // 11. </name>
    const t11 = try tok.next();
    try std.testing.expect(t11 == .end_element);
    try std.testing.expectEqualStrings("name", t11.end_element.name);

    // 12. Whitespace
    _ = try tok.next();

    // 13. <shm_transport enable="true"/> (self-closing)
    const t13 = try tok.next();
    try std.testing.expect(t13 == .start_element);
    try std.testing.expectEqualStrings("shm_transport", t13.start_element.name);
    try std.testing.expect(t13.start_element.is_empty);
    try std.testing.expectEqual(@as(usize, 1), t13.start_element.attributes.len);
    try std.testing.expectEqualStrings("enable", t13.start_element.attributes[0].name);
    try std.testing.expectEqualStrings("true", t13.start_element.attributes[0].value);

    // 14. Whitespace
    _ = try tok.next();

    // 15. </participant>
    const t15 = try tok.next();
    try std.testing.expect(t15 == .end_element);
    try std.testing.expectEqualStrings("participant", t15.end_element.name);

    // 16. Whitespace
    _ = try tok.next();

    // 17. </dds>
    const t17 = try tok.next();
    try std.testing.expect(t17 == .end_element);
    try std.testing.expectEqualStrings("dds", t17.end_element.name);

    // 18. EOF
    const t18 = try tok.next();
    try std.testing.expect(t18 == .eof);
}

test "decodeEntities handles XML escapes" {
    const raw = "Temp &lt; 100 &amp;&amp; Pressure &gt;= 50 &quot;OK&quot;";
    const decoded = try decodeEntities(std.testing.allocator, raw);
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqualStrings("Temp < 100 && Pressure >= 50 \"OK\"", decoded);
}
