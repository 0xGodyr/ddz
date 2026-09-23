//! @file scope.zig
//! @brief Hierarchical symbol table scoping and namespace resolution for IDL types.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const Ast = @import("../ast/ast.zig");

pub const SymbolKind = enum {
    struct_type,
    enum_type,
    union_type,
    bitmask_type,
    bitset_type,
    typedef_type,
    const_val,
    interface_type,
    module_scope,
};

pub const Symbol = struct {
    name: []const u8,
    kind: SymbolKind,
    decl: Ast.Declaration,
};

pub const Scope = struct {
    name: []const u8,
    parent: ?*Scope = null,
    symbols: std.StringHashMapUnmanaged(Symbol) = .empty,
    children: std.ArrayListUnmanaged(*Scope) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, parent: ?*Scope) Scope {
        return .{
            .allocator = allocator,
            .name = name,
            .parent = parent,
        };
    }

    pub fn deinit(self: *Scope) void {
        self.symbols.deinit(self.allocator);
        for (self.children.items) |child| {
            child.deinit();
            self.allocator.destroy(child);
        }
        self.children.deinit(self.allocator);
    }

    pub fn insert(self: *Scope, name: []const u8, kind: SymbolKind, decl: Ast.Declaration) !void {
        try self.symbols.put(self.allocator, name, .{
            .name = name,
            .kind = kind,
            .decl = decl,
        });
    }

    pub fn createChild(self: *Scope, name: []const u8) !*Scope {
        const child = try self.allocator.create(Scope);
        child.* = Scope.init(self.allocator, name, self);
        try self.children.append(self.allocator, child);
        return child;
    }

    pub fn lookupLocal(self: *const Scope, name: []const u8) ?Symbol {
        return self.symbols.get(name);
    }

    pub fn lookup(self: *const Scope, name: []const u8) ?Symbol {
        if (self.symbols.get(name)) |sym| return sym;
        if (self.parent) |p| return p.lookup(name);
        return null;
    }

    pub fn lookupScoped(self: *const Scope, scoped_name: Ast.ScopedName) ?Symbol {
        if (scoped_name.segments.len == 0) return null;

        if (scoped_name.segments.len == 1) {
            return self.lookup(scoped_name.segments[0]);
        }

        // Find root or top segment
        var current: ?*const Scope = self;
        while (current.?.parent != null) {
            current = current.?.parent;
        }

        var i: usize = 0;
        while (i < scoped_name.segments.len - 1) : (i += 1) {
            const seg = scoped_name.segments[i];
            var found_child: ?*const Scope = null;
            for (current.?.children.items) |child| {
                if (std.mem.eql(u8, child.name, seg)) {
                    found_child = child;
                    break;
                }
            }
            if (found_child) |fc| {
                current = fc;
            } else {
                return null;
            }
        }

        return current.?.lookupLocal(scoped_name.segments[scoped_name.segments.len - 1]);
    }
};

test "Scope symbol hierarchy" {
    var scope = Scope.init(std.testing.allocator, "root", null);
    defer scope.deinit();

    const dummy_decl = Ast.Declaration{ .const_def = .{
        .name = "VAL",
        .const_type = .{ .primitive = .long },
        .value_repr = "42",
    } };

    try scope.insert("GLOBAL_VAL", .const_val, dummy_decl);
    const child = try scope.createChild("SubModule");
    try child.insert("LOCAL_VAL", .const_val, dummy_decl);

    try std.testing.expect(child.lookup("LOCAL_VAL") != null);
    try std.testing.expect(child.lookup("GLOBAL_VAL") != null);
    try std.testing.expect(scope.lookup("LOCAL_VAL") == null);
}
