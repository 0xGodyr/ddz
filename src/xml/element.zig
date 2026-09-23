//! @file element.zig
//! @brief Memory-efficient XML DOM Document and Element tree for Zig.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const Tokenizer = tokenizer.Tokenizer;
const Attribute = tokenizer.Attribute;
const decodeEntities = tokenizer.decodeEntities;

pub const Element = struct {
    name: []const u8,
    attributes: []const Attribute,
    text: ?[]const u8 = null,
    children: []const *Element,
    parent: ?*Element = null,

    pub fn getAttribute(self: *const Element, attr_name: []const u8) ?[]const u8 {
        for (self.attributes) |attr| {
            if (std.mem.eql(u8, attr.name, attr_name)) {
                return attr.value;
            }
        }
        return null;
    }

    pub fn findChild(self: *const Element, child_name: []const u8) ?*Element {
        for (self.children) |child| {
            if (std.mem.eql(u8, child.name, child_name)) {
                return child;
            }
        }
        return null;
    }

    pub fn findChildren(self: *const Element, allocator: std.mem.Allocator, child_name: []const u8) ![]*Element {
        var list: std.ArrayListUnmanaged(*Element) = .empty;
        errdefer list.deinit(allocator);

        for (self.children) |child| {
            if (std.mem.eql(u8, child.name, child_name)) {
                try list.append(allocator, child);
            }
        }
        return try list.toOwnedSlice(allocator);
    }

    pub fn findChildPath(self: *const Element, path: []const u8) ?*Element {
        var it = std.mem.splitScalar(u8, path, '.');
        var curr: ?*Element = @constCast(self);
        while (it.next()) |part| {
            if (curr) |c| {
                curr = c.findChild(part);
            } else return null;
        }
        return curr;
    }

    pub fn getChildText(self: *const Element, child_name: []const u8) ?[]const u8 {
        if (self.findChild(child_name)) |child| {
            return child.text;
        }
        return null;
    }

    pub fn getChildTextPath(self: *const Element, path: []const u8) ?[]const u8 {
        if (self.findChildPath(path)) |child| {
            return child.text;
        }
        return null;
    }

    pub fn getChildInt(self: *const Element, comptime T: type, child_name: []const u8) ?T {
        const txt = self.getChildText(child_name) orelse return null;
        return std.fmt.parseInt(T, std.mem.trim(u8, txt, " \t\r\n"), 0) catch null;
    }

    pub fn getChildIntPath(self: *const Element, comptime T: type, path: []const u8) ?T {
        const txt = self.getChildTextPath(path) orelse return null;
        return std.fmt.parseInt(T, std.mem.trim(u8, txt, " \t\r\n"), 0) catch null;
    }

    pub fn getChildFloat(self: *const Element, comptime T: type, child_name: []const u8) ?T {
        const txt = self.getChildText(child_name) orelse return null;
        return std.fmt.parseFloat(T, std.mem.trim(u8, txt, " \t\r\n")) catch null;
    }

    pub fn getChildBool(self: *const Element, child_name: []const u8) ?bool {
        const txt = self.getChildText(child_name) orelse return null;
        const trimmed = std.mem.trim(u8, txt, " \t\r\n");
        if (std.mem.eql(u8, trimmed, "true") or std.mem.eql(u8, trimmed, "1")) return true;
        if (std.mem.eql(u8, trimmed, "false") or std.mem.eql(u8, trimmed, "0")) return false;
        return null;
    }

    pub fn getChildBoolPath(self: *const Element, path: []const u8) ?bool {
        const txt = self.getChildTextPath(path) orelse return null;
        const trimmed = std.mem.trim(u8, txt, " \t\r\n");
        if (std.mem.eql(u8, trimmed, "true") or std.mem.eql(u8, trimmed, "1")) return true;
        if (std.mem.eql(u8, trimmed, "false") or std.mem.eql(u8, trimmed, "0")) return false;
        return null;
    }
};

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    root: *Element,

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }

    const ElementBuilder = struct {
        name: []const u8,
        attributes: []const Attribute,
        text_parts: std.ArrayListUnmanaged([]const u8) = .empty,
        children: std.ArrayListUnmanaged(*Element) = .empty,
        parent: ?*Element = null,
    };

    pub fn parse(allocator: std.mem.Allocator, xml_source: []const u8) !Document {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_alloc = arena.allocator();

        var tok = Tokenizer.init(xml_source);

        var stack: std.ArrayListUnmanaged(*ElementBuilder) = .empty;
        defer stack.deinit(arena_alloc);

        var root_element: ?*Element = null;

        while (true) {
            const token = try tok.next();
            switch (token) {
                .start_element => |se| {
                    const builder = try arena_alloc.create(ElementBuilder);
                    builder.* = .{
                        .name = try arena_alloc.dupe(u8, se.name),
                        .attributes = try arena_alloc.dupe(Attribute, se.attributes),
                        .text_parts = .empty,
                        .children = .empty,
                        .parent = null,
                    };

                    if (se.is_empty) {
                        // Self-closing element: finish it immediately
                        const elem = try arena_alloc.create(Element);
                        elem.* = .{
                            .name = builder.name,
                            .attributes = builder.attributes,
                            .text = null,
                            .children = &.{},
                            .parent = null,
                        };

                        if (stack.items.len > 0) {
                            const top = stack.items[stack.items.len - 1];
                            elem.parent = null; // will be resolved
                            try top.children.append(arena_alloc, elem);
                        } else if (root_element == null) {
                            root_element = elem;
                        }
                    } else {
                        // Open tag: push to stack
                        try stack.append(arena_alloc, builder);
                    }
                },
                .character_data => |cd| {
                    if (stack.items.len > 0) {
                        const trimmed = std.mem.trim(u8, cd, " \t\r\n");
                        if (trimmed.len > 0) {
                            const top = stack.items[stack.items.len - 1];
                            const decoded = try decodeEntities(arena_alloc, trimmed);
                            try top.text_parts.append(arena_alloc, decoded);
                        }
                    }
                },
                .cdata => |cd| {
                    if (stack.items.len > 0) {
                        const top = stack.items[stack.items.len - 1];
                        try top.text_parts.append(arena_alloc, try arena_alloc.dupe(u8, cd));
                    }
                },
                .end_element => |ee| {
                    if (stack.items.len == 0) return error.MismatchedEndTag;

                    const top = stack.pop().?;
                    if (!std.mem.eql(u8, top.name, ee.name)) {
                        return error.MismatchedEndTag;
                    }

                    var combined_text: ?[]const u8 = null;
                    if (top.text_parts.items.len == 1) {
                        combined_text = top.text_parts.items[0];
                    } else if (top.text_parts.items.len > 1) {
                        combined_text = try std.mem.join(arena_alloc, " ", top.text_parts.items);
                    }

                    const elem = try arena_alloc.create(Element);
                    elem.* = .{
                        .name = top.name,
                        .attributes = top.attributes,
                        .text = combined_text,
                        .children = try top.children.toOwnedSlice(arena_alloc),
                        .parent = null,
                    };

                    for (elem.children) |child| {
                        child.parent = elem;
                    }

                    if (stack.items.len > 0) {
                        const parent_builder = stack.items[stack.items.len - 1];
                        try parent_builder.children.append(arena_alloc, elem);
                    } else {
                        root_element = elem;
                    }
                },
                .comment, .processing_instruction, .doctype => {
                    // Ignored metadata
                },
                .eof => break,
            }
        }

        if (stack.items.len > 0) return error.UnclosedTag;
        const root = root_element orelse return error.EmptyDocument;

        return Document{
            .arena = arena,
            .root = root,
        };
    }
};

test "Element Document parsing and DOM navigation" {
    const xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<dds xmlns="http://www.omg.org/dds">
        \\    <profiles>
        \\        <participant profile_name="test_participant">
        \\            <domain_id>42</domain_id>
        \\            <rtps>
        \\                <name>RobotNode</name>
        \\                <shm_transport enable="true"/>
        \\            </rtps>
        \\        </participant>
        \\        <topic profile_name="sensor_topic">
        \\            <name>Sensors/Lidar</name>
        \\            <historyQos>
        \\                <depth>100</depth>
        \\            </historyQos>
        \\        </topic>
        \\    </profiles>
        \\</dds>
    ;

    var doc = try Document.parse(std.testing.allocator, xml);
    defer doc.deinit();

    try std.testing.expectEqualStrings("dds", doc.root.name);
    try std.testing.expectEqualStrings("http://www.omg.org/dds", doc.root.getAttribute("xmlns").?);

    const profiles = doc.root.findChild("profiles").?;
    try std.testing.expectEqual(@as(usize, 2), profiles.children.len);

    // Check participant
    const participant = profiles.findChild("participant").?;
    try std.testing.expectEqualStrings("test_participant", participant.getAttribute("profile_name").?);
    try std.testing.expectEqual(@as(u32, 42), participant.getChildInt(u32, "domain_id").?);

    // Deep path queries
    try std.testing.expectEqualStrings("RobotNode", participant.getChildTextPath("rtps.name").?);
    try std.testing.expectEqual(true, participant.findChildPath("rtps.shm_transport").?.getAttribute("enable").?[0] == 't');

    // Check topic
    const topic = profiles.findChild("topic").?;
    try std.testing.expectEqualStrings("Sensors/Lidar", topic.getChildText("name").?);
    try std.testing.expectEqual(@as(i32, 100), topic.getChildIntPath(i32, "historyQos.depth").?);
}
