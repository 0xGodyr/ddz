//! @file preprocessor.zig
//! @brief C-style preprocessor handling #include, #define, #ifdef, and include path resolution.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const Diagnostics = @import("../diagnostics.zig");

pub const Preprocessor = struct {
    allocator: std.mem.Allocator,
    include_paths: []const []const u8,
    included_files: std.StringHashMapUnmanaged(void) = .empty,
    defines: std.StringHashMapUnmanaged([]const u8) = .empty,
    diagnostics: *Diagnostics.DiagnosticEngine,

    pub fn init(
        allocator: std.mem.Allocator,
        include_paths: []const []const u8,
        diag: *Diagnostics.DiagnosticEngine,
    ) Preprocessor {
        return .{
            .allocator = allocator,
            .include_paths = include_paths,
            .diagnostics = diag,
        };
    }

    pub fn deinit(self: *Preprocessor) void {
        var fit = self.included_files.iterator();
        while (fit.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.included_files.deinit(self.allocator);

        var dit = self.defines.iterator();
        while (dit.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.defines.deinit(self.allocator);
    }

    pub fn define(self: *Preprocessor, name: []const u8, value: []const u8) !void {
        const name_dup = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_dup);
        const val_dup = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(val_dup);

        try self.defines.put(self.allocator, name_dup, val_dup);
    }

    pub fn processFile(self: *Preprocessor, file_path: []const u8) anyerror![]const u8 {
        const full_path = std.fs.path.resolve(self.allocator, &.{file_path}) catch |err| {
            try self.diagnostics.report(.err, .{ .file_path = file_path, .line = 1, .column = 1 }, "Cannot resolve file path: {}", .{err});
            return err;
        };
        defer self.allocator.free(full_path);

        if (self.included_files.contains(full_path)) {
            // Already included (pragma once / include guard)
            return try self.allocator.dupe(u8, "");
        }

        const canonical = try self.allocator.dupe(u8, full_path);
        try self.included_files.put(self.allocator, canonical, {});

        const io = std.Options.debug_io;
        var file = std.Io.Dir.cwd().openFile(io, file_path, .{}) catch |err| {
            try self.diagnostics.report(.err, .{ .file_path = file_path, .line = 1, .column = 1 }, "Cannot open file '{s}': {}", .{ file_path, err });
            return err;
        };
        defer file.close(io);

        const file_size = try file.length(io);
        const content = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(content);
        const bytes_read = try file.readPositionalAll(io, content, 0);
        if (bytes_read != file_size) return error.UnexpectedEndOfFile;

        return try self.processSource(content, file_path);
    }

    pub fn processSource(self: *Preprocessor, source: []const u8, file_path: []const u8) anyerror![]const u8 {
        var output: std.ArrayListUnmanaged(u8) = .empty;
        errdefer output.deinit(self.allocator);

        var ifdef_stack: std.ArrayListUnmanaged(bool) = .empty;
        defer ifdef_stack.deinit(self.allocator);

        var lines = std.mem.splitScalar(u8, source, '\n');
        var line_num: usize = 0;
        var in_multiline_comment = false;

        while (lines.next()) |raw_line| {
            line_num += 1;
            var line = raw_line;
            if (line.len > 0 and line[line.len - 1] == '\r') {
                line = line[0 .. line.len - 1];
            }

            const trimmed = std.mem.trim(u8, line, " \t");

            // Handle multi-line comments
            if (in_multiline_comment) {
                if (std.mem.indexOf(u8, line, "*/")) |end_pos| {
                    in_multiline_comment = false;
                    line = std.mem.trim(u8, line[end_pos + 2 ..], " \t");
                } else {
                    continue;
                }
            } else if (std.mem.startsWith(u8, trimmed, "/*") and !std.mem.startsWith(u8, trimmed, "/**")) {
                if (std.mem.indexOf(u8, trimmed, "*/")) |end_pos| {
                    line = std.mem.trim(u8, trimmed[end_pos + 2 ..], " \t");
                } else {
                    in_multiline_comment = true;
                    continue;
                }
            }

            // Directives
            if (std.mem.startsWith(u8, trimmed, "#")) {
                const directive = std.mem.trim(u8, trimmed[1..], " \t");

                if (std.mem.startsWith(u8, directive, "ifdef ")) {
                    const sym = std.mem.trim(u8, directive[6..], " \t");
                    const active = if (ifdef_stack.items.len > 0 and !ifdef_stack.items[ifdef_stack.items.len - 1]) false else self.defines.contains(sym);
                    try ifdef_stack.append(self.allocator, active);
                    continue;
                } else if (std.mem.startsWith(u8, directive, "ifndef ")) {
                    const sym = std.mem.trim(u8, directive[7..], " \t");
                    const active = if (ifdef_stack.items.len > 0 and !ifdef_stack.items[ifdef_stack.items.len - 1]) false else !self.defines.contains(sym);
                    try ifdef_stack.append(self.allocator, active);
                    continue;
                } else if (std.mem.eql(u8, directive, "else")) {
                    if (ifdef_stack.items.len == 0) {
                        try self.diagnostics.report(.err, .{ .file_path = file_path, .line = line_num, .column = 1 }, "unmatched #else", .{});
                    } else {
                        const idx = ifdef_stack.items.len - 1;
                        ifdef_stack.items[idx] = !ifdef_stack.items[idx];
                    }
                    continue;
                } else if (std.mem.eql(u8, directive, "endif")) {
                    if (ifdef_stack.items.len == 0) {
                        try self.diagnostics.report(.err, .{ .file_path = file_path, .line = line_num, .column = 1 }, "unmatched #endif", .{});
                    } else {
                        _ = ifdef_stack.pop();
                    }
                    continue;
                }

                // If currently inside an inactive conditional branch, skip
                if (ifdef_stack.items.len > 0 and !ifdef_stack.items[ifdef_stack.items.len - 1]) {
                    continue;
                }

                if (std.mem.startsWith(u8, directive, "define ")) {
                    const rest = std.mem.trim(u8, directive[7..], " \t");
                    var split = std.mem.splitScalar(u8, rest, ' ');
                    const name = split.next() orelse "";
                    const val = if (split.rest().len > 0) std.mem.trim(u8, split.rest(), " \t") else "1";
                    try self.define(name, val);
                    continue;
                } else if (std.mem.startsWith(u8, directive, "undef ")) {
                    const name = std.mem.trim(u8, directive[6..], " \t");
                    if (self.defines.fetchRemove(name)) |kv| {
                        self.allocator.free(kv.key);
                        self.allocator.free(kv.value);
                    }
                    continue;
                } else if (std.mem.eql(u8, directive, "pragma once")) {
                    // Handled at file level
                    continue;
                } else if (std.mem.startsWith(u8, directive, "include ")) {
                    const target = std.mem.trim(u8, directive[8..], " \t");
                    if (target.len >= 2 and ((target[0] == '<' and target[target.len - 1] == '>') or (target[0] == '"' and target[target.len - 1] == '"'))) {
                        const sub_path = target[1 .. target.len - 1];
                        const included_content = try self.resolveAndInclude(sub_path, file_path, line_num);
                        defer self.allocator.free(included_content);
                        try output.appendSlice(self.allocator, included_content);
                        try output.append(self.allocator, '\n');
                    } else {
                        try self.diagnostics.report(.err, .{ .file_path = file_path, .line = line_num, .column = 1 }, "malformed #include directive '{s}'", .{target});
                    }
                    continue;
                }
            }

            // Inactive #ifdef branch
            if (ifdef_stack.items.len > 0 and !ifdef_stack.items[ifdef_stack.items.len - 1]) {
                continue;
            }

            // Preserve doc comments: "///" and "/**"
            if (std.mem.startsWith(u8, trimmed, "//") and !std.mem.startsWith(u8, trimmed, "///")) {
                // Strip normal comments
                try output.append(self.allocator, '\n');
                continue;
            }

            try output.appendSlice(self.allocator, line);
            try output.append(self.allocator, '\n');
        }

        return try output.toOwnedSlice(self.allocator);
    }

    fn resolveAndInclude(self: *Preprocessor, rel_path: []const u8, parent_file: []const u8, line: usize) anyerror![]const u8 {
        // First check relative to parent file
        const parent_dir = std.fs.path.dirname(parent_file) orelse ".";
        const local_cand = try std.fs.path.join(self.allocator, &.{ parent_dir, rel_path });
        defer self.allocator.free(local_cand);

        if (fileExists(local_cand)) {
            return self.processFile(local_cand);
        }

        // Next check all -I include directories
        for (self.include_paths) |inc_dir| {
            const cand = try std.fs.path.join(self.allocator, &.{ inc_dir, rel_path });
            defer self.allocator.free(cand);
            if (fileExists(cand)) {
                return self.processFile(cand);
            }
        }

        try self.diagnostics.report(.err, .{ .file_path = parent_file, .line = line, .column = 1 }, "cannot find include file '{s}'", .{rel_path});
        return error.FileNotFound;
    }

    fn fileExists(path: []const u8) bool {
        const io = std.Options.debug_io;
        var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
        file.close(io);
        return true;
    }
};

test "Preprocessor conditionals and macros" {
    var diag = Diagnostics.DiagnosticEngine.init(std.testing.allocator);
    defer diag.deinit();

    var pp = Preprocessor.init(std.testing.allocator, &.{}, &diag);
    defer pp.deinit();

    const src =
        \\#define FOO
        \\#ifdef FOO
        \\struct Foo { long x; };
        \\#else
        \\struct Bar { long y; };
        \\#endif
        \\#ifndef BAZ
        \\const long VAL = 42;
        \\#endif
    ;

    const res = try pp.processSource(src, "inline.idl");
    defer std.testing.allocator.free(res);

    try std.testing.expect(std.mem.indexOf(u8, res, "struct Foo") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "struct Bar") == null);
    try std.testing.expect(std.mem.indexOf(u8, res, "const long VAL = 42;") != null);
}
