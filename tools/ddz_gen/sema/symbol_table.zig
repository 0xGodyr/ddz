//! @file symbol_table.zig
//! @brief Global symbol table tracking declared types, modules, constants, and interfaces.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const Ast = @import("../ast/ast.zig");
const scope_mod = @import("scope.zig");
const Scope = scope_mod.Scope;
const SymbolKind = scope_mod.SymbolKind;
const Diagnostics = @import("../diagnostics.zig");

pub const SymbolTable = struct {
    allocator: std.mem.Allocator,
    root_scope: Scope,
    diagnostics: *Diagnostics.DiagnosticEngine,

    pub fn init(allocator: std.mem.Allocator, diag: *Diagnostics.DiagnosticEngine) SymbolTable {
        return .{
            .allocator = allocator,
            .root_scope = Scope.init(allocator, "::", null),
            .diagnostics = diag,
        };
    }

    pub fn deinit(self: *SymbolTable) void {
        self.root_scope.deinit();
    }

    pub fn populate(self: *SymbolTable, ast: Ast.AstRoot) !void {
        try self.populateScope(&self.root_scope, ast.declarations);
    }

    fn populateScope(self: *SymbolTable, scope: *Scope, decls: []const Ast.Declaration) anyerror!void {
        for (decls) |decl| {
            switch (decl) {
                .module => |mod| {
                    const child_scope = try scope.createChild(mod.name);
                    try scope.insert(mod.name, .module_scope, decl);
                    try self.populateScope(child_scope, mod.declarations);
                },
                .struct_def => |s| {
                    try scope.insert(s.name, .struct_type, decl);
                },
                .enum_def => |e| {
                    try scope.insert(e.name, .enum_type, decl);
                },
                .union_def => |u| {
                    try scope.insert(u.name, .union_type, decl);
                },
                .bitmask_def => |bm| {
                    try scope.insert(bm.name, .bitmask_type, decl);
                },
                .bitset_def => |bs| {
                    try scope.insert(bs.name, .bitset_type, decl);
                },
                .typedef_def => |td| {
                    try scope.insert(td.name, .typedef_type, decl);
                },
                .const_def => |cd| {
                    try scope.insert(cd.name, .const_val, decl);
                },
                .interface_def => |iface| {
                    try scope.insert(iface.name, .interface_type, decl);
                },
            }
        }
    }
};

test "SymbolTable population" {
    var diag = Diagnostics.DiagnosticEngine.init(std.testing.allocator);
    defer diag.deinit();

    var sym_tab = SymbolTable.init(std.testing.allocator, &diag);
    defer sym_tab.deinit();

    const dummy_struct = Ast.Declaration{ .struct_def = .{
        .name = "MyPoint",
        .fields = &.{},
    } };

    try sym_tab.populate(.{ .declarations = &.{dummy_struct} });
    try std.testing.expect(sym_tab.root_scope.lookup("MyPoint") != null);
}
