//! @file xmi_parser.zig
//! @brief High-performance OMG DDS-UML XMI (XML Metadata Interchange) model parser.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");
const element = @import("element.zig");
const Element = element.Element;
const Document = element.Document;
const os = @import("../os.zig");

/// Primitive kinds recognized in UML/IDL data modeling.
pub const UmlPrimitiveKind = enum {
    int8,
    int16,
    int32,
    int64,
    uint8,
    uint16,
    uint32,
    uint64,
    float32,
    float64,
    boolean,
    string,
    custom,

    pub fn toZigType(self: UmlPrimitiveKind) []const u8 {
        return switch (self) {
            .int8 => "i8",
            .int16 => "i16",
            .int32 => "i32",
            .int64 => "i64",
            .uint8 => "u8",
            .uint16 => "u16",
            .uint32 => "u32",
            .uint64 => "u64",
            .float32 => "f32",
            .float64 => "f64",
            .boolean => "bool",
            .string => "[]const u8",
            .custom => "[]const u8",
        };
    }

    pub fn toIdlType(self: UmlPrimitiveKind) []const u8 {
        return switch (self) {
            .int8 => "int8",
            .int16 => "short",
            .int32 => "long",
            .int64 => "long long",
            .uint8 => "uint8",
            .uint16 => "unsigned short",
            .uint32 => "unsigned long",
            .uint64 => "unsigned long long",
            .float32 => "float",
            .float64 => "double",
            .boolean => "boolean",
            .string => "string",
            .custom => "string",
        };
    }
};

pub const UmlProperty = struct {
    id: []const u8,
    name: []const u8,
    type_name: []const u8,
    primitive_kind: UmlPrimitiveKind = .int32,
    is_key: bool = false,
    default_value: ?[]const u8 = null,
};

pub const UmlPort = struct {
    id: []const u8,
    name: []const u8,
    type_ref: []const u8 = "",
};

pub const UmlClass = struct {
    id: []const u8,
    name: []const u8,
    is_topic: bool = false,
    topic_name: []const u8 = "",
    extensibility: []const u8 = "APPENDABLE",
    properties: []UmlProperty = &.{},
    ports: []UmlPort = &.{},
};

pub const UmlDataWriter = struct {
    id: []const u8,
    name: []const u8,
    topic_name: []const u8,
    topic_class_name: []const u8 = "",
    reliability: []const u8 = "RELIABLE",
    durability: []const u8 = "VOLATILE",
    history_depth: u32 = 1,
    deadline_ms: u32 = 0,
};

pub const UmlDataReader = struct {
    id: []const u8,
    name: []const u8,
    topic_name: []const u8,
    topic_class_name: []const u8 = "",
    reliability: []const u8 = "BEST_EFFORT",
    durability: []const u8 = "VOLATILE",
    history_depth: u32 = 1,
    deadline_ms: u32 = 0,
};

pub const UmlParticipant = struct {
    id: []const u8,
    name: []const u8,
    domain_id: u32 = 0,
    writers: []UmlDataWriter = &.{},
    readers: []UmlDataReader = &.{},
};

pub const UmlModel = struct {
    arena: std.heap.ArenaAllocator,
    name: []const u8,
    classes: []UmlClass,
    participants: []UmlParticipant,

    pub fn deinit(self: *UmlModel) void {
        self.arena.deinit();
    }
};

pub const XmiParser = struct {
    /// Strips XML namespace prefix (e.g., "uml:Class" -> "Class", "DDS:Topic" -> "Topic").
    pub fn localName(name: []const u8) []const u8 {
        if (std.mem.indexOfScalar(u8, name, ':')) |idx| {
            return name[idx + 1 ..];
        }
        return name;
    }

    /// Maps UML or XMI type name to UmlPrimitiveKind.
    pub fn parsePrimitiveKind(type_str: []const u8) UmlPrimitiveKind {
        var lower_buf: [64]u8 = undefined;
        const len = @min(type_str.len, lower_buf.len);
        for (type_str[0..len], 0..) |c, i| {
            lower_buf[i] = std.ascii.toLower(c);
        }
        const lower = lower_buf[0..len];

        if (std.mem.indexOf(u8, lower, "int8") != null) return .int8;
        if (std.mem.indexOf(u8, lower, "uint8") != null or std.mem.indexOf(u8, lower, "byte") != null or std.mem.indexOf(u8, lower, "octet") != null) return .uint8;
        if (std.mem.indexOf(u8, lower, "int16") != null or std.mem.indexOf(u8, lower, "short") != null) return .int16;
        if (std.mem.indexOf(u8, lower, "uint16") != null or std.mem.indexOf(u8, lower, "ushort") != null) return .uint16;
        if (std.mem.indexOf(u8, lower, "int64") != null or std.mem.indexOf(u8, lower, "longlong") != null) return .int64;
        if (std.mem.indexOf(u8, lower, "uint64") != null or std.mem.indexOf(u8, lower, "ulonglong") != null) return .uint64;
        if (std.mem.indexOf(u8, lower, "uint32") != null or std.mem.indexOf(u8, lower, "uint") != null or std.mem.indexOf(u8, lower, "ulong") != null) return .uint32;
        if (std.mem.indexOf(u8, lower, "int") != null or std.mem.indexOf(u8, lower, "integer") != null or std.mem.indexOf(u8, lower, "long") != null) return .int32;
        if (std.mem.indexOf(u8, lower, "double") != null or std.mem.indexOf(u8, lower, "float64") != null or std.mem.indexOf(u8, lower, "real") != null) return .float64;
        if (std.mem.indexOf(u8, lower, "float") != null or std.mem.indexOf(u8, lower, "float32") != null) return .float32;
        if (std.mem.indexOf(u8, lower, "bool") != null or std.mem.indexOf(u8, lower, "boolean") != null) return .boolean;
        if (std.mem.indexOf(u8, lower, "str") != null or std.mem.indexOf(u8, lower, "string") != null or std.mem.indexOf(u8, lower, "char") != null) return .string;

        return .custom;
    }

    pub const TopicStereotypeInfo = struct {
        topic_name: []const u8,
        extensibility: []const u8,
    };

    pub const EndpointStereotypeInfo = struct {
        base_ref: []const u8,
        topic: []const u8,
        reliability: []const u8,
        durability: []const u8,
        history_depth: u32,
        deadline_ms: u32,
    };

    /// Parses an XMI document string into a UmlModel.
    pub fn parse(allocator: std.mem.Allocator, xml_text: []const u8) !UmlModel {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_alloc = arena.allocator();

        const buffer = try arena_alloc.dupe(u8, xml_text);
        return parseInternal(arena, buffer);
    }

    /// Parses an XMI model from a filesystem file.
    pub fn parseFile(allocator: std.mem.Allocator, file_path: []const u8) !UmlModel {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_alloc = arena.allocator();

        const io = std.Options.debug_io;
        var file = try std.Io.Dir.cwd().openFile(io, file_path, .{});
        defer file.close(io);

        const file_size = try file.length(io);
        const buffer = try arena_alloc.alloc(u8, file_size);

        _ = try file.readPositionalAll(io, buffer, 0);
        return parseInternal(arena, buffer);
    }

    fn parseInternal(arena: std.heap.ArenaAllocator, xml_text: []const u8) !UmlModel {
        var arena_mut = arena;
        const arena_alloc = arena_mut.allocator();

        const doc = try Document.parse(arena_alloc, xml_text);

        var model_name: []const u8 = "Model";
        var raw_classes: std.ArrayListUnmanaged(UmlClass) = .empty;
        var participants: std.ArrayListUnmanaged(UmlParticipant) = .empty;

        // Temporary maps for cross-referencing stereotypes
        var topic_stereotypes: std.StringHashMapUnmanaged(TopicStereotypeInfo) = .empty;
        var key_stereotypes: std.StringHashMapUnmanaged(void) = .empty;
        var participant_stereotypes: std.StringHashMapUnmanaged(u32) = .empty;

        var writer_stereotypes: std.ArrayListUnmanaged(EndpointStereotypeInfo) = .empty;
        var reader_stereotypes: std.ArrayListUnmanaged(EndpointStereotypeInfo) = .empty;

        // 1. Recursive scan for UML elements and top-level stereotypes
        try scanElement(
            arena_alloc,
            doc.root,
            &model_name,
            &raw_classes,
            &topic_stereotypes,
            &key_stereotypes,
            &participant_stereotypes,
            &writer_stereotypes,
            &reader_stereotypes,
        );

        // 2. Apply stereotypes to classes and properties
        for (raw_classes.items) |*cls| {
            if (topic_stereotypes.get(cls.id)) |t_st| {
                cls.is_topic = true;
                cls.topic_name = if (t_st.topic_name.len > 0) t_st.topic_name else cls.name;
                cls.extensibility = t_st.extensibility;
            }

            for (cls.properties) |*prop| {
                if (key_stereotypes.contains(prop.id)) {
                    prop.is_key = true;
                }
            }
        }

        // 3. Build participants from classes that are marked as DomainParticipant
        var class_id_to_name: std.StringHashMapUnmanaged([]const u8) = .empty;
        for (raw_classes.items) |cls| {
            try class_id_to_name.put(arena_alloc, cls.id, cls.name);
        }

        for (raw_classes.items) |cls| {
            const is_part = participant_stereotypes.contains(cls.id);
            if (is_part) {
                const domain_id = participant_stereotypes.get(cls.id) orelse 0;
                var writers: std.ArrayListUnmanaged(UmlDataWriter) = .empty;
                var readers: std.ArrayListUnmanaged(UmlDataReader) = .empty;

                // Match ports or attributes in this participant class to writers/readers
                for (cls.ports) |port| {
                    for (writer_stereotypes.items) |w_st| {
                        if (std.mem.eql(u8, w_st.base_ref, port.id)) {
                            const topic_cls = if (class_id_to_name.get(port.type_ref)) |tname| tname else port.type_ref;
                            const actual_topic = if (w_st.topic.len > 0) w_st.topic else topic_cls;
                            try writers.append(arena_alloc, .{
                                .id = port.id,
                                .name = port.name,
                                .topic_name = actual_topic,
                                .topic_class_name = topic_cls,
                                .reliability = w_st.reliability,
                                .durability = w_st.durability,
                                .history_depth = w_st.history_depth,
                                .deadline_ms = w_st.deadline_ms,
                            });
                        }
                    }

                    for (reader_stereotypes.items) |r_st| {
                        if (std.mem.eql(u8, r_st.base_ref, port.id)) {
                            const topic_cls = if (class_id_to_name.get(port.type_ref)) |tname| tname else port.type_ref;
                            const actual_topic = if (r_st.topic.len > 0) r_st.topic else topic_cls;
                            try readers.append(arena_alloc, .{
                                .id = port.id,
                                .name = port.name,
                                .topic_name = actual_topic,
                                .topic_class_name = topic_cls,
                                .reliability = r_st.reliability,
                                .durability = r_st.durability,
                                .history_depth = r_st.history_depth,
                                .deadline_ms = r_st.deadline_ms,
                            });
                        }
                    }
                }

                try participants.append(arena_alloc, .{
                    .id = cls.id,
                    .name = cls.name,
                    .domain_id = domain_id,
                    .writers = try writers.toOwnedSlice(arena_alloc),
                    .readers = try readers.toOwnedSlice(arena_alloc),
                });
            }
        }

        return UmlModel{
            .arena = arena_mut,
            .name = model_name,
            .classes = try raw_classes.toOwnedSlice(arena_alloc),
            .participants = try participants.toOwnedSlice(arena_alloc),
        };
    }

    fn scanElement(
        allocator: std.mem.Allocator,
        elem: *const Element,
        model_name: *[]const u8,
        classes: *std.ArrayListUnmanaged(UmlClass),
        topic_stereotypes: *std.StringHashMapUnmanaged(TopicStereotypeInfo),
        key_stereotypes: *std.StringHashMapUnmanaged(void),
        participant_stereotypes: *std.StringHashMapUnmanaged(u32),
        writer_stereotypes: *std.ArrayListUnmanaged(EndpointStereotypeInfo),
        reader_stereotypes: *std.ArrayListUnmanaged(EndpointStereotypeInfo),
    ) !void {
        const local = localName(elem.name);

        if (std.mem.eql(u8, local, "Model")) {
            if (elem.getAttribute("name")) |n| {
                model_name.* = n;
            }
        }

        // Stereotype definitions (e.g., <DDS:Topic>, <DDS:Key>, etc.)
        if (std.mem.eql(u8, local, "Topic")) {
            const base_cls = elem.getAttribute("base_Class") orelse elem.getAttribute("base_Element") orelse "";
            if (base_cls.len > 0) {
                const topic_name = elem.getAttribute("topicName") orelse elem.getAttribute("name") orelse "";
                const extensibility = elem.getAttribute("extensibility") orelse "APPENDABLE";
                try topic_stereotypes.put(allocator, base_cls, .{
                    .topic_name = topic_name,
                    .extensibility = extensibility,
                });
            }
        } else if (std.mem.eql(u8, local, "Key")) {
            const base_prop = elem.getAttribute("base_Property") orelse elem.getAttribute("base_Element") orelse "";
            if (base_prop.len > 0) {
                try key_stereotypes.put(allocator, base_prop, {});
            }
        } else if (std.mem.eql(u8, local, "DomainParticipant")) {
            const base_cls = elem.getAttribute("base_Class") orelse elem.getAttribute("base_Element") orelse "";
            if (base_cls.len > 0) {
                var domain_id: u32 = 0;
                if (elem.getAttribute("domainId")) |d_str| {
                    domain_id = std.fmt.parseInt(u32, d_str, 10) catch 0;
                }
                try participant_stereotypes.put(allocator, base_cls, domain_id);
            }
        } else if (std.mem.eql(u8, local, "DataWriter")) {
            const base_port = elem.getAttribute("base_Port") orelse elem.getAttribute("base_Property") orelse elem.getAttribute("base_Element") orelse "";
            if (base_port.len > 0) {
                const topic = elem.getAttribute("topic") orelse elem.getAttribute("topicName") orelse "";
                const reliability = elem.getAttribute("reliability") orelse "RELIABLE";
                const durability = elem.getAttribute("durability") orelse "VOLATILE";
                var history_depth: u32 = 1;
                if (elem.getAttribute("history_depth") orelse elem.getAttribute("historyDepth")) |hd_str| {
                    history_depth = std.fmt.parseInt(u32, hd_str, 10) catch 1;
                }
                var deadline_ms: u32 = 0;
                if (elem.getAttribute("deadline_ms") orelse elem.getAttribute("deadline")) |dl_str| {
                    deadline_ms = std.fmt.parseInt(u32, dl_str, 10) catch 0;
                }
                try writer_stereotypes.append(allocator, .{
                    .base_ref = base_port,
                    .topic = topic,
                    .reliability = reliability,
                    .durability = durability,
                    .history_depth = history_depth,
                    .deadline_ms = deadline_ms,
                });
            }
        } else if (std.mem.eql(u8, local, "DataReader")) {
            const base_port = elem.getAttribute("base_Port") orelse elem.getAttribute("base_Property") orelse elem.getAttribute("base_Element") orelse "";
            if (base_port.len > 0) {
                const topic = elem.getAttribute("topic") orelse elem.getAttribute("topicName") orelse "";
                const reliability = elem.getAttribute("reliability") orelse "BEST_EFFORT";
                const durability = elem.getAttribute("durability") orelse "VOLATILE";
                var history_depth: u32 = 1;
                if (elem.getAttribute("history_depth") orelse elem.getAttribute("historyDepth")) |hd_str| {
                    history_depth = std.fmt.parseInt(u32, hd_str, 10) catch 1;
                }
                var deadline_ms: u32 = 0;
                if (elem.getAttribute("deadline_ms") orelse elem.getAttribute("deadline")) |dl_str| {
                    deadline_ms = std.fmt.parseInt(u32, dl_str, 10) catch 0;
                }
                try reader_stereotypes.append(allocator, .{
                    .base_ref = base_port,
                    .topic = topic,
                    .reliability = reliability,
                    .durability = durability,
                    .history_depth = history_depth,
                    .deadline_ms = deadline_ms,
                });
            }
        }

        // Packaged element Class
        const type_attr = elem.getAttribute("xmi:type") orelse elem.getAttribute("type") orelse "";
        if (std.mem.eql(u8, local, "Class") or std.mem.eql(u8, type_attr, "uml:Class") or std.mem.eql(u8, type_attr, "Class")) {
            const class_id = elem.getAttribute("xmi:id") orelse elem.getAttribute("id") orelse "";
            const class_name = elem.getAttribute("name") orelse "UnnamedClass";

            var properties: std.ArrayListUnmanaged(UmlProperty) = .empty;
            var ports: std.ArrayListUnmanaged(UmlPort) = .empty;

            var is_topic = false;
            var topic_name: []const u8 = "";
            var extensibility: []const u8 = "APPENDABLE";

            // Check inline stereotypes or attributes on class
            if (elem.getAttribute("topicName")) |tn| {
                is_topic = true;
                topic_name = tn;
            }
            if (elem.getAttribute("stereotype")) |st| {
                if (std.mem.indexOf(u8, st, "Topic") != null) is_topic = true;
                if (std.mem.indexOf(u8, st, "DomainParticipant") != null) {
                    try participant_stereotypes.put(allocator, class_id, 0);
                }
            }
            if (elem.getAttribute("domainId")) |did_str| {
                const did = std.fmt.parseInt(u32, did_str, 10) catch 0;
                try participant_stereotypes.put(allocator, class_id, did);
            }
            if (elem.getAttribute("extensibility")) |ext| {
                extensibility = ext;
            }

            for (elem.children) |child| {
                const child_local = localName(child.name);
                const child_type = child.getAttribute("xmi:type") orelse child.getAttribute("type") orelse "";

                if (std.mem.eql(u8, child_local, "ownedAttribute") or std.mem.eql(u8, child_type, "uml:Property") or std.mem.eql(u8, child_local, "Property")) {
                    const prop_id = child.getAttribute("xmi:id") orelse child.getAttribute("id") orelse "";
                    const prop_name = child.getAttribute("name") orelse "unnamed";
                    var prop_type = child.getAttribute("type") orelse "";

                    // Look for nested <type> tag if attribute type was omitted
                    if (prop_type.len == 0) {
                        if (child.findChild("type")) |tchild| {
                            prop_type = tchild.getAttribute("href") orelse tchild.getAttribute("name") orelse tchild.getAttribute("xmi:type") orelse "";
                            if (std.mem.indexOfScalar(u8, prop_type, '#')) |hash_idx| {
                                prop_type = prop_type[hash_idx + 1 ..];
                            }
                        }
                    }

                    var is_key = false;
                    if (child.getAttribute("is_key")) |ik| {
                        is_key = std.mem.eql(u8, ik, "true");
                    }
                    if (child.getAttribute("stereotype")) |st| {
                        if (std.mem.indexOf(u8, st, "Key") != null) is_key = true;
                    }

                    const prim_kind = parsePrimitiveKind(prop_type);

                    try properties.append(allocator, .{
                        .id = prop_id,
                        .name = prop_name,
                        .type_name = prop_type,
                        .primitive_kind = prim_kind,
                        .is_key = is_key,
                    });
                } else if (std.mem.eql(u8, child_local, "ownedPort") or std.mem.eql(u8, child_type, "uml:Port") or std.mem.eql(u8, child_local, "Port")) {
                    const port_id = child.getAttribute("xmi:id") orelse child.getAttribute("id") orelse "";
                    const port_name = child.getAttribute("name") orelse "port";
                    const port_type = child.getAttribute("type") orelse "";

                    try ports.append(allocator, .{
                        .id = port_id,
                        .name = port_name,
                        .type_ref = port_type,
                    });
                }
            }

            try classes.append(allocator, .{
                .id = class_id,
                .name = class_name,
                .is_topic = is_topic,
                .topic_name = topic_name,
                .extensibility = extensibility,
                .properties = try properties.toOwnedSlice(allocator),
                .ports = try ports.toOwnedSlice(allocator),
            });
        }

        // Recurse into children
        for (elem.children) |child| {
            try scanElement(
                allocator,
                child,
                model_name,
                classes,
                topic_stereotypes,
                key_stereotypes,
                participant_stereotypes,
                writer_stereotypes,
                reader_stereotypes,
            );
        }
    }
};

test "XMI Parser basic UML model and DDS stereotypes" {
    const xmi_xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<xmi:XMI xmi:version="2.1" xmlns:xmi="http://schema.omg.org/spec/XMI/2.1" xmlns:uml="http://www.eclipse.org/uml2/3.0.0/UML" xmlns:DDS="http://www.omg.org/spec/DDS-UML/20110301">
        \\  <uml:Model xmi:id="model_vehicle" name="VehicleSystem">
        \\    <packagedElement xmi:type="uml:Class" xmi:id="cls_radar" name="RadarTarget">
        \\      <ownedAttribute xmi:type="uml:Property" xmi:id="attr_target_id" name="target_id" type="Integer"/>
        \\      <ownedAttribute xmi:type="uml:Property" xmi:id="attr_range" name="range" type="Real"/>
        \\      <ownedAttribute xmi:type="uml:Property" xmi:id="attr_detected" name="detected" type="Boolean"/>
        \\    </packagedElement>
        \\    <packagedElement xmi:type="uml:Class" xmi:id="cls_controller" name="RadarApp">
        \\      <ownedPort xmi:type="uml:Port" xmi:id="port_writer" name="target_pub" type="cls_radar"/>
        \\      <ownedPort xmi:type="uml:Port" xmi:id="port_reader" name="target_sub" type="cls_radar"/>
        \\    </packagedElement>
        \\  </uml:Model>
        \\  <DDS:Topic xmi:id="st_topic" base_Class="cls_radar" topicName="RadarTargetTopic" extensibility="MUTABLE"/>
        \\  <DDS:Key xmi:id="st_key" base_Property="attr_target_id"/>
        \\  <DDS:DomainParticipant xmi:id="st_part" base_Class="cls_controller" domainId="42"/>
        \\  <DDS:DataWriter xmi:id="st_writer" base_Port="port_writer" reliability="RELIABLE" durability="TRANSIENT_LOCAL" history_depth="20"/>
        \\  <DDS:DataReader xmi:id="st_reader" base_Port="port_reader" reliability="BEST_EFFORT"/>
        \\</xmi:XMI>
    ;

    var model = try XmiParser.parse(std.testing.allocator, xmi_xml);
    defer model.deinit();

    try std.testing.expectEqualStrings("VehicleSystem", model.name);
    try std.testing.expectEqual(@as(usize, 2), model.classes.len);

    // Verify RadarTarget class and topic stereotype
    const radar_class = &model.classes[0];
    try std.testing.expectEqualStrings("RadarTarget", radar_class.name);
    try std.testing.expect(radar_class.is_topic);
    try std.testing.expectEqualStrings("RadarTargetTopic", radar_class.topic_name);
    try std.testing.expectEqualStrings("MUTABLE", radar_class.extensibility);
    try std.testing.expectEqual(@as(usize, 3), radar_class.properties.len);

    // Verify key property
    try std.testing.expectEqualStrings("target_id", radar_class.properties[0].name);
    try std.testing.expect(radar_class.properties[0].is_key);
    try std.testing.expectEqual(UmlPrimitiveKind.int32, radar_class.properties[0].primitive_kind);

    // Verify float and bool properties
    try std.testing.expectEqualStrings("range", radar_class.properties[1].name);
    try std.testing.expect(!radar_class.properties[1].is_key);
    try std.testing.expectEqual(UmlPrimitiveKind.float64, radar_class.properties[1].primitive_kind);

    try std.testing.expectEqualStrings("detected", radar_class.properties[2].name);
    try std.testing.expectEqual(UmlPrimitiveKind.boolean, radar_class.properties[2].primitive_kind);

    // Verify Participant and Endpoint scaffolding
    try std.testing.expectEqual(@as(usize, 1), model.participants.len);
    const participant = &model.participants[0];
    try std.testing.expectEqualStrings("RadarApp", participant.name);
    try std.testing.expectEqual(@as(u32, 42), participant.domain_id);

    try std.testing.expectEqual(@as(usize, 1), participant.writers.len);
    try std.testing.expectEqualStrings("target_pub", participant.writers[0].name);
    try std.testing.expectEqualStrings("RadarTarget", participant.writers[0].topic_class_name);
    try std.testing.expectEqualStrings("RELIABLE", participant.writers[0].reliability);
    try std.testing.expectEqualStrings("TRANSIENT_LOCAL", participant.writers[0].durability);
    try std.testing.expectEqual(@as(u32, 20), participant.writers[0].history_depth);

    try std.testing.expectEqual(@as(usize, 1), participant.readers.len);
    try std.testing.expectEqualStrings("target_sub", participant.readers[0].name);
    try std.testing.expectEqualStrings("BEST_EFFORT", participant.readers[0].reliability);
}
