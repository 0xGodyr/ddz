//! @file const_evaluator.zig
//! @brief Constant expression evaluator for IDL constant definitions and array bound sizing.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");

pub const ConstEvaluator = struct {
    pub fn parseI64(text: []const u8) ?i64 {
        const trimmed = std.mem.trim(u8, text, " \t\r\n()");
        if (trimmed.len == 0) return null;

        // Check for hex "0x"
        if (std.mem.startsWith(u8, trimmed, "0x") or std.mem.startsWith(u8, trimmed, "0X")) {
            return std.fmt.parseInt(i64, trimmed[2..], 16) catch null;
        }

        // Check for octal "0"
        if (trimmed.len > 1 and trimmed[0] == '0' and trimmed[1] >= '0' and trimmed[1] <= '7') {
            return std.fmt.parseInt(i64, trimmed[1..], 8) catch null;
        }

        // Check for binary "0b"
        if (std.mem.startsWith(u8, trimmed, "0b") or std.mem.startsWith(u8, trimmed, "0B")) {
            return std.fmt.parseInt(i64, trimmed[2..], 2) catch null;
        }

        // Standard decimal
        return std.fmt.parseInt(i64, trimmed, 10) catch null;
    }

    pub fn parseF64(text: []const u8) ?f64 {
        const trimmed = std.mem.trim(u8, text, " \t\r\n()");
        if (trimmed.len == 0) return null;

        var clean = trimmed;
        if (clean[clean.len - 1] == 'f' or clean[clean.len - 1] == 'F') {
            clean = clean[0 .. clean.len - 1];
        }

        return std.fmt.parseFloat(f64, clean) catch null;
    }

    /// Basic constant arithmetic evaluator for expressions like "1024 * 2" or "(1 << 4)"
    pub fn evalIntExpr(expr: []const u8) ?i64 {
        const trimmed = std.mem.trim(u8, expr, " \t\r\n");
        if (trimmed.len == 0) return null;

        // Direct parse
        if (parseI64(trimmed)) |val| {
            return val;
        }

        // Look for basic binary operators with lowest precedence first: <<, >>, +, -, *, /, %
        if (findOp(trimmed, "<<")) |idx| {
            const left = evalIntExpr(trimmed[0..idx]) orelse return null;
            const right = evalIntExpr(trimmed[idx + 2 ..]) orelse return null;
            if (right < 0 or right >= 64) return null;
            return left << @intCast(right);
        }

        if (findOp(trimmed, ">>")) |idx| {
            const left = evalIntExpr(trimmed[0..idx]) orelse return null;
            const right = evalIntExpr(trimmed[idx + 2 ..]) orelse return null;
            if (right < 0 or right >= 64) return null;
            return left >> @intCast(right);
        }

        if (findOp(trimmed, "+")) |idx| {
            const left = evalIntExpr(trimmed[0..idx]) orelse return null;
            const right = evalIntExpr(trimmed[idx + 1 ..]) orelse return null;
            return left + right;
        }

        if (findOp(trimmed, "-")) |idx| {
            // Ensure not unary minus
            if (idx > 0) {
                const left = evalIntExpr(trimmed[0..idx]) orelse return null;
                const right = evalIntExpr(trimmed[idx + 1 ..]) orelse return null;
                return left - right;
            }
        }

        if (findOp(trimmed, "*")) |idx| {
            const left = evalIntExpr(trimmed[0..idx]) orelse return null;
            const right = evalIntExpr(trimmed[idx + 1 ..]) orelse return null;
            return left * right;
        }

        if (findOp(trimmed, "/")) |idx| {
            const left = evalIntExpr(trimmed[0..idx]) orelse return null;
            const right = evalIntExpr(trimmed[idx + 1 ..]) orelse return null;
            if (right == 0) return null;
            return @divTrunc(left, right);
        }

        return null;
    }

    fn findOp(text: []const u8, op: []const u8) ?usize {
        var paren_depth: usize = 0;
        var i: usize = text.len;
        while (i > 0) {
            i -= 1;
            const c = text[i];
            if (c == ')') {
                paren_depth += 1;
            } else if (c == '(') {
                if (paren_depth > 0) paren_depth -= 1;
            } else if (paren_depth == 0) {
                if (i + op.len <= text.len and std.mem.eql(u8, text[i .. i + op.len], op)) {
                    return i;
                }
            }
        }
        return null;
    }
};

test "ConstEvaluator arithmetic" {
    try std.testing.expectEqual(@as(?i64, 42), ConstEvaluator.evalIntExpr("42"));
    try std.testing.expectEqual(@as(?i64, 2048), ConstEvaluator.evalIntExpr("1024 * 2"));
    try std.testing.expectEqual(@as(?i64, 16), ConstEvaluator.evalIntExpr("1 << 4"));
    try std.testing.expectEqual(@as(?i64, 255), ConstEvaluator.parseI64("0xFF"));
}
