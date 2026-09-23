//! @file type_validator.zig
//! @brief Semantic analysis pass validating type references, recursion, and struct layouts.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const Ast = @import("../ast/ast.zig");
const SymbolTable = @import("symbol_table.zig").SymbolTable;
const Scope = @import("scope.zig").Scope;
const Diagnostics = @import("../diagnostics.zig");

pub const TypeValidator = struct {
    symbol_table: *const SymbolTable,
    diagnostics: *Diagnostics.DiagnosticEngine,

    pub fn init(sym_tab: *const SymbolTable, diag: *Diagnostics.DiagnosticEngine) TypeValidator {
        return .{
            .symbol_table = sym_tab,
            .diagnostics = diag,
        };
    }

    pub fn validate(self: *TypeValidator, ast: Ast.AstRoot) !void {
        try self.validateScopeDecls(&self.symbol_table.root_scope, ast.declarations);
    }

    fn validateScopeDecls(self: *TypeValidator, scope: *const Scope, decls: []const Ast.Declaration) anyerror!void {
        for (decls) |decl| {
            switch (decl) {
                .module => |mod| {
                    if (scope.lookupLocal(mod.name)) |_| {
                        // Find child scope
                        for (scope.children.items) |child| {
                            if (std.mem.eql(u8, child.name, mod.name)) {
                                try self.validateScopeDecls(child, mod.declarations);
                                break;
                            }
                        }
                    }
                },
                .struct_def => |s| {
                    for (s.fields) |f| {
                        try self.validateTypeRef(scope, f.type_ref, s.name, f.name);
                    }
                },
                .union_def => |u| {
                    try self.validateTypeRef(scope, u.discriminant_type, u.name, "switch");
                    var seen_cases: std.AutoHashMapUnmanaged(i64, void) = .empty;
                    defer seen_cases.deinit(self.symbol_table.allocator);
                    var has_default = false;

                    for (u.cases) |c| {
                        try self.validateTypeRef(scope, c.field.type_ref, u.name, c.field.name);
                        for (c.labels) |lbl| {
                            switch (lbl) {
                                .value => |v| {
                                    if (seen_cases.contains(v)) {
                                        try self.diagnostics.report(.err, .{}, "duplicate case label {d} in union '{s}'", .{ v, u.name });
                                    } else {
                                        try seen_cases.put(self.symbol_table.allocator, v, {});
                                    }
                                },
                                .default_case => {
                                    if (has_default) {
                                        try self.diagnostics.report(.err, .{}, "multiple default cases in union '{s}'", .{u.name});
                                    }
                                    has_default = true;
                                },
                            }
                        }
                    }
                },
                .bitmask_def => |bm| {
                    if (bm.bit_bound > 64 or bm.bit_bound == 0) {
                        try self.diagnostics.report(.err, .{}, "invalid bit_bound {d} in bitmask '{s}', must be <= 64", .{ bm.bit_bound, bm.name });
                    }
                    if (bm.flags.len > bm.bit_bound) {
                        try self.diagnostics.report(.err, .{}, "bitmask '{s}' has {d} flags exceeding bit_bound of {d}", .{ bm.name, bm.flags.len, bm.bit_bound });
                    }
                },
                .typedef_def => |td| {
                    try self.validateTypeRef(scope, td.target_type, td.name, "typedef");
                },
                .interface_def => |iface| {
                    for (iface.operations) |op| {
                        try self.validateTypeRef(scope, op.return_type, iface.name, op.name);
                        for (op.params) |param| {
                            try self.validateTypeRef(scope, param.param_type, iface.name, param.name);
                        }
                    }
                },
                else => {},
            }
        }
    }

    fn validateTypeRef(self: *TypeValidator, scope: *const Scope, type_ref: Ast.TypeRef, context_parent: []const u8, context_field: []const u8) !void {
        switch (type_ref) {
            .primitive => {},
            .string_bounded, .wstring_bounded => {},
            .sequence => |seq| {
                try self.validateTypeRef(scope, seq.element_type, context_parent, context_field);
            },
            .array => |arr| {
                try self.validateTypeRef(scope, arr.element_type, context_parent, context_field);
            },
            .scoped_name => |sn| {
                if (scope.lookupScoped(sn) == null) {
                    try self.diagnostics.report(.err, .{}, "unknown type '{s}' in member '{s}.{s}'", .{ sn.last(), context_parent, context_field });
                }
            },
        }
    }
};

test "TypeValidator validation and errors" {
    var diag = Diagnostics.DiagnosticEngine.init(std.testing.allocator);
    defer diag.deinit();

    var sym_tab = SymbolTable.init(std.testing.allocator, &diag);
    defer sym_tab.deinit();

    const struct_unknown = Ast.Declaration{ .struct_def = .{
        .name = "TestStruct",
        .fields = &.{
            .{
                .name = "missing",
                .type_ref = .{ .scoped_name = .{ .segments = &.{"NonExistentType"} } },
            },
        },
    } };

    try sym_tab.populate(.{ .declarations = &.{struct_unknown} });

    var validator = TypeValidator.init(&sym_tab, &diag);
    try validator.validate(.{ .declarations = &.{struct_unknown} });

    try std.testing.expect(diag.hasErrors());
}
