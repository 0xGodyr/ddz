//! @file token.zig
//! @brief Token definitions, keywords, and punctuation kinds for OMG IDL 4.2 lexing.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const Diagnostics = @import("../diagnostics.zig");

pub const TokenKind = enum {
    // Keywords - Declarations
    kw_module,
    kw_struct,
    kw_union,
    kw_switch,
    kw_case,
    kw_default,
    kw_enum,
    kw_bitset,
    kw_bitmask,
    kw_typedef,
    kw_const,
    kw_interface,
    kw_sequence,
    kw_string,
    kw_wstring,
    kw_fixed,
    kw_map,

    // Keywords - Primitive Types
    kw_octet,
    kw_short,
    kw_long,
    kw_unsigned,
    kw_float,
    kw_double,
    kw_boolean,
    kw_char,
    kw_wchar,
    kw_void,
    kw_int8,
    kw_uint8,
    kw_int16,
    kw_uint16,
    kw_int32,
    kw_uint32,
    kw_int64,
    kw_uint64,

    // Keywords - RPC / Operations
    kw_in,
    kw_out,
    kw_inout,
    kw_oneway,

    // Boolean literals
    kw_true,
    kw_false,

    // Annotations (starts with @)
    at_sign, // '@'
    annotation_ident, // e.g. @key, @id, @optional

    // Identifiers & Literals
    identifier,
    int_literal,
    float_literal,
    string_literal,
    char_literal,

    // Doc comments
    doc_comment,

    // Delimiters & Punctuation
    l_brace, // '{'
    r_brace, // '}'
    l_paren, // '('
    r_paren, // ')'
    l_bracket, // '['
    r_bracket, // ']'
    l_angle, // '<'
    r_angle, // '>'
    semicolon, // ';'
    colon, // ':'
    colon_colon, // '::'
    comma, // ','
    equal, // '='
    plus, // '+'
    minus, // '-'
    asterisk, // '*'
    slash, // '/'
    percent, // '%'
    tilde, // '~'
    ampersand, // '&'
    pipe, // '|'
    caret, // '^'
    shl, // '<<'
    shr, // '>>'

    // Special
    eof,
    invalid,
};

pub const Token = struct {
    kind: TokenKind,
    text: []const u8,
    location: Diagnostics.SourceLocation,
};
