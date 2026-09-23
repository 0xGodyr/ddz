//! @file xml.zig
//! @brief XML subsystem exposing Tokenizer, DOM Element/Document, and DDS-XML profile parser.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const tokenizer = @import("tokenizer.zig");
pub const Tokenizer = tokenizer.Tokenizer;
pub const SourceLocation = tokenizer.SourceLocation;
pub const Attribute = tokenizer.Attribute;
pub const Token = tokenizer.Token;
pub const decodeEntities = tokenizer.decodeEntities;

const element = @import("element.zig");
pub const Element = element.Element;
pub const Document = element.Document;

const dds_xml_parser = @import("dds_xml_parser.zig");
pub const DdsXmlParser = dds_xml_parser.DdsXmlParser;
pub const ParticipantProfile = dds_xml_parser.ParticipantProfile;
pub const TopicProfile = dds_xml_parser.TopicProfile;
pub const WriterProfile = dds_xml_parser.WriterProfile;
pub const ReaderProfile = dds_xml_parser.ReaderProfile;
pub const PublisherProfile = dds_xml_parser.PublisherProfile;
pub const SubscriberProfile = dds_xml_parser.SubscriberProfile;

const xmi_parser = @import("xmi_parser.zig");
pub const XmiParser = xmi_parser.XmiParser;
pub const UmlModel = xmi_parser.UmlModel;
pub const UmlClass = xmi_parser.UmlClass;
pub const UmlProperty = xmi_parser.UmlProperty;
pub const UmlPrimitiveKind = xmi_parser.UmlPrimitiveKind;
pub const UmlParticipant = xmi_parser.UmlParticipant;
pub const UmlDataWriter = xmi_parser.UmlDataWriter;
pub const UmlDataReader = xmi_parser.UmlDataReader;

test {
    _ = tokenizer;
    _ = element;
    _ = dds_xml_parser;
    _ = xmi_parser;
}
