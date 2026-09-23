//! @file test_all.zig
//! @brief Comprehensive test runner for ddz_gen lexer, parser, sema, and codegen suites.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");

pub const Diagnostics = @import("diagnostics.zig");
pub const Options = @import("options.zig");
pub const Preprocessor = @import("preprocessor/preprocessor.zig");
pub const Token = @import("lexer/token.zig");
pub const Lexer = @import("lexer/lexer.zig");
pub const Ast = @import("ast/ast.zig");
pub const ConstEvaluator = @import("parser/const_evaluator.zig");
pub const Parser = @import("parser/parser.zig");
pub const Scope = @import("sema/scope.zig");
pub const SymbolTable = @import("sema/symbol_table.zig");
pub const TypeValidator = @import("sema/type_validator.zig");
pub const ZigEmitter = @import("codegen/zig_emitter.zig");
pub const RpcEmitter = @import("codegen/rpc_emitter.zig");
pub const MsgParser = @import("ros2/msg_parser.zig");
pub const ReverseEmitter = @import("codegen/reverse_emitter.zig");
pub const UmlEmitter = @import("codegen/uml_emitter.zig");

test {
    _ = Diagnostics;
    _ = Options;
    _ = Preprocessor;
    _ = Token;
    _ = Lexer;
    _ = Ast;
    _ = ConstEvaluator;
    _ = Parser;
    _ = Scope;
    _ = SymbolTable;
    _ = TypeValidator;
    _ = ZigEmitter;
    _ = RpcEmitter;
    _ = MsgParser;
    _ = ReverseEmitter;
    _ = UmlEmitter;
}
