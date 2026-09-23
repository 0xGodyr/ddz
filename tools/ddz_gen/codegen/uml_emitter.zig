//! @file uml_emitter.zig
//! @brief Code generation backend translating parsed DDS-UML XMI models into Zig types, IDL 4.2 schemas, and DDZ topology scaffolding.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const ddz = @import("ddz");
const UmlModel = ddz.xml.UmlModel;
const UmlClass = ddz.xml.UmlClass;
const UmlProperty = ddz.xml.UmlProperty;
const UmlPrimitiveKind = ddz.xml.UmlPrimitiveKind;
const UmlParticipant = ddz.xml.UmlParticipant;
const UmlDataWriter = ddz.xml.UmlDataWriter;
const UmlDataReader = ddz.xml.UmlDataReader;

pub const BufferWriter = struct {
    buffer: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,

    pub fn writeAll(self: *BufferWriter, bytes: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, bytes);
    }

    pub fn writeByte(self: *BufferWriter, byte: u8) !void {
        try self.buffer.append(self.allocator, byte);
    }

    pub fn print(self: *BufferWriter, comptime fmt: []const u8, args: anytype) !void {
        const formatted = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(formatted);
        try self.buffer.appendSlice(self.allocator, formatted);
    }
};

pub const UmlEmitter = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) UmlEmitter {
        return .{ .allocator = allocator };
    }

    /// Emits strongly-typed Zig structs for all classes/topics in the UML model.
    pub fn emitTypes(self: *UmlEmitter, model: UmlModel) ![]const u8 {
        var buffer: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buffer.deinit(self.allocator);

        var writer = BufferWriter{
            .buffer = &buffer,
            .allocator = self.allocator,
        };

        try writer.writeAll(
            \\//! Generated automatically by ddz_gen from DDS-UML XMI model. DO NOT EDIT.
            \\const std = @import("std");
            \\const ddz = @import("ddz");
            \\
            \\
        );

        for (model.classes) |cls| {
            try writer.print("pub const {s} = struct {{\n", .{cls.name});

            if (cls.is_topic) {
                try writer.print("    pub const ddz_extensibility = \"{s}\";\n", .{cls.extensibility});
                const topic_name = if (cls.topic_name.len > 0) cls.topic_name else cls.name;
                try writer.print("    pub const ddz_topic_name = \"{s}\";\n", .{topic_name});
            }

            var has_key = false;
            for (cls.properties) |prop| {
                if (prop.is_key) has_key = true;
                const zig_type = prop.primitive_kind.toZigType();
                if (prop.is_key) {
                    try writer.print("    /// @key\n    {s}: {s},\n", .{ prop.name, zig_type });
                } else {
                    try writer.print("    {s}: {s},\n", .{ prop.name, zig_type });
                }
            }

            // Generate helper key getter if any key fields exist
            if (has_key) {
                try writer.writeAll(
                    \\
                    \\    pub fn getKey(self: *const @This()) u64 {
                    \\        var hasher = std.hash.Wyhash.init(0);
                    \\
                );
                for (cls.properties) |prop| {
                    if (prop.is_key) {
                        if (prop.primitive_kind == .string) {
                            try writer.print("        hasher.update(self.{s});\n", .{prop.name});
                        } else {
                            try writer.print("        hasher.update(std.mem.asBytes(&self.{s}));\n", .{prop.name});
                        }
                    }
                }
                try writer.writeAll(
                    \\        return hasher.final();
                    \\    }
                    \\
                );
            }

            try writer.writeAll("};\n\n");
        }

        return try buffer.toOwnedSlice(self.allocator);
    }

    /// Emits complete Zig DDZ topology scaffolding (DomainParticipants, Publishers, Subscribers, DataWriters, DataReaders).
    pub fn emitTopology(self: *UmlEmitter, model: UmlModel, types_module_name: []const u8) ![]const u8 {
        var buffer: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buffer.deinit(self.allocator);

        var writer = BufferWriter{
            .buffer = &buffer,
            .allocator = self.allocator,
        };

        try writer.print(
            \\//! Generated automatically by ddz_gen from DDS-UML XMI model. DO NOT EDIT.
            \\const std = @import("std");
            \\const ddz = @import("ddz");
            \\const types = @import("{s}");
            \\
            \\
        , .{types_module_name});

        for (model.participants) |part| {
            try writer.print("pub const {s}Topology = struct {{\n", .{part.name});
            try writer.writeAll(
                \\    participant: *ddz.dcps.DomainParticipant,
                \\    publisher: *ddz.dcps.Publisher,
                \\    subscriber: *ddz.dcps.Subscriber,
                \\
            );

            // Writer fields
            for (part.writers) |w| {
                try writer.print("    {s}: *ddz.dcps.DataWriter,\n", .{w.name});
            }

            // Reader fields
            for (part.readers) |r| {
                try writer.print("    {s}: *ddz.dcps.DataReader,\n", .{r.name});
            }

            try writer.writeAll("\n");

            // Initialization function
            try writer.writeAll(
                \\    pub fn init(factory: *ddz.dcps.DomainParticipantFactory, allocator: std.mem.Allocator) !@This() {
                \\
            );
            try writer.print("        const participant = try factory.createParticipant({d}, null, allocator);\n", .{part.domain_id});
            try writer.writeAll(
                \\        errdefer factory.deleteParticipant(participant, allocator) catch {};
                \\
                \\        const publisher = try participant.createPublisher(null);
                \\        const subscriber = try participant.createSubscriber(null);
                \\
            );

            // Initialize writers
            for (part.writers) |w| {
                const topic_type = if (w.topic_class_name.len > 0) w.topic_class_name else w.topic_name;
                const topic_var = try std.fmt.allocPrint(self.allocator, "topic_{s}", .{w.name});
                defer self.allocator.free(topic_var);

                try writer.print("        const {s} = ddz.dcps.Topic.init(\"{s}\", \"{s}\");\n", .{ topic_var, w.topic_name, topic_type });
                try writer.print("        var {s}_qos = ddz.dcps.Qos.WriterQos{{}};\n", .{w.name});

                const rel = mapReliability(w.reliability);
                const dur = mapDurability(w.durability);
                try writer.print("        {s}_qos.reliability.kind = .{s};\n", .{ w.name, rel });
                try writer.print("        {s}_qos.durability = .{s};\n", .{ w.name, dur });
                if (w.history_depth > 1) {
                    try writer.print("        {s}_qos.history.depth = {d};\n", .{ w.name, w.history_depth });
                }
                if (w.deadline_ms > 0) {
                    try writer.print("        {s}_qos.deadline.period_ms = {d};\n", .{ w.name, w.deadline_ms });
                }

                try writer.print("        const writer_{s} = try publisher.createDataWriter({s}, {s}_qos, ddz.rtps.types.EntityId_t.unknown);\n", .{ w.name, topic_var, w.name });
            }

            // Initialize readers
            for (part.readers) |r| {
                const topic_type = if (r.topic_class_name.len > 0) r.topic_class_name else r.topic_name;
                const topic_var = try std.fmt.allocPrint(self.allocator, "topic_{s}", .{r.name});
                defer self.allocator.free(topic_var);

                try writer.print("        const {s} = ddz.dcps.Topic.init(\"{s}\", \"{s}\");\n", .{ topic_var, r.topic_name, topic_type });
                try writer.print("        var {s}_qos = ddz.dcps.Qos.ReaderQos{{}};\n", .{r.name});

                const rel = mapReliability(r.reliability);
                const dur = mapDurability(r.durability);
                try writer.print("        {s}_qos.reliability.kind = .{s};\n", .{ r.name, rel });
                try writer.print("        {s}_qos.durability = .{s};\n", .{ r.name, dur });
                if (r.history_depth > 1) {
                    try writer.print("        {s}_qos.history.depth = {d};\n", .{ r.name, r.history_depth });
                }
                if (r.deadline_ms > 0) {
                    try writer.print("        {s}_qos.deadline.period_ms = {d};\n", .{ r.name, r.deadline_ms });
                }

                try writer.print("        const reader_{s} = try subscriber.createDataReader({s}, {s}_qos, ddz.rtps.types.EntityId_t.unknown);\n", .{ r.name, topic_var, r.name });
            }

            // Return struct instance
            try writer.writeAll(
                \\
                \\        return @This(){
                \\            .participant = participant,
                \\            .publisher = publisher,
                \\            .subscriber = subscriber,
                \\
            );

            for (part.writers) |w| {
                try writer.print("            .{s} = writer_{s},\n", .{ w.name, w.name });
            }
            for (part.readers) |r| {
                try writer.print("            .{s} = reader_{s},\n", .{ r.name, r.name });
            }

            try writer.writeAll(
                \\        };
                \\    }
                \\
                \\    pub fn deinit(self: *@This(), factory: *ddz.dcps.DomainParticipantFactory, allocator: std.mem.Allocator) void {
                \\        factory.deleteParticipant(self.participant, allocator) catch {};
                \\    }
                \\};
                \\
                \\
            );
        }

        return try buffer.toOwnedSlice(self.allocator);
    }

    /// Emits OMG IDL 4.2 file from the UML classes.
    pub fn emitIdl(self: *UmlEmitter, model: UmlModel) ![]const u8 {
        var buffer: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buffer.deinit(self.allocator);

        var writer = BufferWriter{
            .buffer = &buffer,
            .allocator = self.allocator,
        };

        try writer.print(
            \\// Generated automatically by ddz_gen from DDS-UML XMI model: {s}
            \\// DO NOT EDIT.
            \\
            \\
        , .{model.name});

        for (model.classes) |cls| {
            if (cls.is_topic) {
                try writer.print("@extensibility({s})\n", .{cls.extensibility});
            }
            try writer.print("struct {s} {{\n", .{cls.name});

            for (cls.properties) |prop| {
                const idl_type = prop.primitive_kind.toIdlType();
                if (prop.is_key) {
                    try writer.print("    @key {s} {s};\n", .{ idl_type, prop.name });
                } else {
                    try writer.print("    {s} {s};\n", .{ idl_type, prop.name });
                }
            }

            try writer.writeAll("};\n\n");
        }

        return try buffer.toOwnedSlice(self.allocator);
    }

    fn mapReliability(rel_str: []const u8) []const u8 {
        if (std.mem.indexOf(u8, rel_str, "BEST") != null) return "best_effort";
        return "reliable";
    }

    fn mapDurability(dur_str: []const u8) []const u8 {
        if (std.mem.indexOf(u8, dur_str, "TRANSIENT_LOCAL") != null) return "transient_local";
        if (std.mem.indexOf(u8, dur_str, "TRANSIENT") != null) return "transient";
        if (std.mem.indexOf(u8, dur_str, "PERSISTENT") != null) return "persistent";
        return "@\"volatile\"";
    }
};

test "UmlEmitter types, topology, and IDL code generation" {
    const xmi_xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<xmi:XMI xmi:version="2.1" xmlns:xmi="http://schema.omg.org/spec/XMI/2.1" xmlns:uml="http://www.eclipse.org/uml2/3.0.0/UML" xmlns:DDS="http://www.omg.org/spec/DDS-UML/20110301">
        \\  <uml:Model xmi:id="model_vehicle" name="VehicleSystem">
        \\    <packagedElement xmi:type="uml:Class" xmi:id="cls_radar" name="RadarTarget">
        \\      <ownedAttribute xmi:type="uml:Property" xmi:id="attr_target_id" name="target_id" type="Integer"/>
        \\      <ownedAttribute xmi:type="uml:Property" xmi:id="attr_range" name="range" type="Real"/>
        \\    </packagedElement>
        \\    <packagedElement xmi:type="uml:Class" xmi:id="cls_controller" name="RadarController">
        \\      <ownedPort xmi:type="uml:Port" xmi:id="port_writer" name="target_pub" type="cls_radar"/>
        \\    </packagedElement>
        \\  </uml:Model>
        \\  <DDS:Topic xmi:id="st_topic" base_Class="cls_radar" topicName="RadarTargetTopic" extensibility="MUTABLE"/>
        \\  <DDS:Key xmi:id="st_key" base_Property="attr_target_id"/>
        \\  <DDS:DomainParticipant xmi:id="st_part" base_Class="cls_controller" domainId="0"/>
        \\  <DDS:DataWriter xmi:id="st_writer" base_Port="port_writer" reliability="RELIABLE" durability="TRANSIENT_LOCAL" history_depth="5"/>
        \\</xmi:XMI>
    ;

    var model = try ddz.xml.XmiParser.parse(std.testing.allocator, xmi_xml);
    defer model.deinit();

    var emitter = UmlEmitter.init(std.testing.allocator);

    // 1. Emit Types
    const types_src = try emitter.emitTypes(model);
    defer std.testing.allocator.free(types_src);

    try std.testing.expect(std.mem.indexOf(u8, types_src, "pub const RadarTarget = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, types_src, "ddz_extensibility = \"MUTABLE\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, types_src, "target_id: i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, types_src, "range: f64") != null);
    try std.testing.expect(std.mem.indexOf(u8, types_src, "pub fn getKey") != null);

    // 2. Emit Topology Scaffolding
    const topo_src = try emitter.emitTopology(model, "RadarTargetTypes.zig");
    defer std.testing.allocator.free(topo_src);

    try std.testing.expect(std.mem.indexOf(u8, topo_src, "pub const RadarControllerTopology = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, topo_src, "createParticipant(0, null, allocator)") != null);
    try std.testing.expect(std.mem.indexOf(u8, topo_src, "target_pub: *ddz.dcps.DataWriter") != null);
    try std.testing.expect(std.mem.indexOf(u8, topo_src, "reliability.kind = .reliable") != null);
    try std.testing.expect(std.mem.indexOf(u8, topo_src, "durability = .transient_local") != null);

    // 3. Emit IDL
    const idl_src = try emitter.emitIdl(model);
    defer std.testing.allocator.free(idl_src);

    try std.testing.expect(std.mem.indexOf(u8, idl_src, "@extensibility(MUTABLE)") != null);
    try std.testing.expect(std.mem.indexOf(u8, idl_src, "struct RadarTarget {") != null);
    try std.testing.expect(std.mem.indexOf(u8, idl_src, "@key long target_id;") != null);
    try std.testing.expect(std.mem.indexOf(u8, idl_src, "double range;") != null);
}
