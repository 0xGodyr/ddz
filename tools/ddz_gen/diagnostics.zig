//! @file diagnostics.zig
//! @brief Diagnostic reporting and error formatting engine for IDL parsing and semantic analysis.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");

pub const SourceLocation = struct {
    file_path: []const u8 = "<stdin>",
    line: usize = 1,
    column: usize = 1,
};

pub const DiagnosticSeverity = enum {
    err,
    warning,
    note,

    pub fn prefix(self: DiagnosticSeverity) []const u8 {
        return switch (self) {
            .err => "\x1b[1;31merror:\x1b[0m",
            .warning => "\x1b[1;33mwarning:\x1b[0m",
            .note => "\x1b[1;36mnote:\x1b[0m",
        };
    }
};

pub const Diagnostic = struct {
    severity: DiagnosticSeverity,
    location: SourceLocation,
    message: []const u8,
};

pub const DiagnosticEngine = struct {
    allocator: std.mem.Allocator,
    diagnostics: std.ArrayListUnmanaged(Diagnostic) = .empty,
    error_count: usize = 0,
    warning_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) DiagnosticEngine {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DiagnosticEngine) void {
        for (self.diagnostics.items) |diag| {
            self.allocator.free(diag.message);
        }
        self.diagnostics.deinit(self.allocator);
    }

    pub fn report(self: *DiagnosticEngine, severity: DiagnosticSeverity, loc: SourceLocation, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        errdefer self.allocator.free(msg);

        try self.diagnostics.append(self.allocator, .{
            .severity = severity,
            .location = loc,
            .message = msg,
        });

        if (severity == .err) {
            self.error_count += 1;
        } else if (severity == .warning) {
            self.warning_count += 1;
        }
    }

    pub fn printAll(self: *const DiagnosticEngine, writer: anytype) !void {
        for (self.diagnostics.items) |diag| {
            try writer.print("{s}:{d}:{d}: {s} {s}\n", .{
                diag.location.file_path,
                diag.location.line,
                diag.location.column,
                diag.severity.prefix(),
                diag.message,
            });
        }
    }

    pub fn hasErrors(self: *const DiagnosticEngine) bool {
        return self.error_count > 0;
    }
};

test "DiagnosticEngine reporting" {
    var diag = DiagnosticEngine.init(std.testing.allocator);
    defer diag.deinit();

    try diag.report(.err, .{ .file_path = "test.idl", .line = 10, .column = 5 }, "unexpected token '{s}'", .{"foo"});
    try diag.report(.warning, .{ .file_path = "test.idl", .line = 12, .column = 1 }, "unused typedef", .{});

    try std.testing.expectEqual(@as(usize, 1), diag.error_count);
    try std.testing.expectEqual(@as(usize, 1), diag.warning_count);
    try std.testing.expect(diag.hasErrors());
}
