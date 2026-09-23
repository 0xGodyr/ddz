//! @file root.zig
//! @brief Root module exposing DCPS, RTPS, network, security, and type APIs.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");

/// @brief Rtps structure.
pub const rtps = struct {
    pub const types = @import("rtps/types.zig");
    pub const Message = @import("rtps/message.zig");
    pub const MessageBuilder = @import("rtps/message_builder.zig").MessageBuilder;
    pub const RtpsReceiver = @import("rtps/rtps_receiver.zig").RtpsReceiver;
    pub const Submessage = @import("rtps/submessage.zig");
    const history_cache = @import("rtps/history_cache.zig");
    pub const HistoryCache = history_cache.HistoryCache;
    pub const ChangeKind = history_cache.ChangeKind;
};

/// @brief Net structure.
pub const net = struct {
    pub const UdpSocket = @import("net/udp_socket.zig").UdpSocket;
};

/// @brief Cdr structure.
pub const cdr = struct {
    pub const Serializer = @import("cdr/serializer.zig").Serializer;
    pub const Deserializer = @import("cdr/deserializer.zig").Deserializer;
};

/// @brief Dcps structure.
pub const dcps = struct {
    pub const DomainParticipantFactory = @import("dcps/domain_participant_factory.zig").DomainParticipantFactory;
    pub const DomainParticipant = @import("dcps/domain_participant.zig").DomainParticipant;
    pub const Entity = @import("dcps/entity.zig").Entity;
    pub const RemoteParticipant = @import("dcps/remote_participant.zig").RemoteParticipant;
    pub const Publisher = @import("dcps/publisher.zig").Publisher;
    pub const Subscriber = @import("dcps/subscriber.zig").Subscriber;

    const data_writer = @import("dcps/data_writer.zig");
    pub const DataWriter = data_writer.DataWriter;
    pub const DataWriterListener = data_writer.DataWriterListener;

    const data_reader = @import("dcps/data_reader.zig");
    pub const DataReader = data_reader.DataReader;
    pub const DataReaderListener = data_reader.DataReaderListener;

    const topic = @import("dcps/topic.zig");
    pub const Topic = topic.Topic;
    pub const ContentFilteredTopic = topic.ContentFilteredTopic;

    const multi_topic = @import("types/multi_topic.zig");
    pub const MultiTopic = multi_topic.MultiTopic;
    pub const MultiDataReader = multi_topic.MultiDataReader;

    pub const Qos = @import("dcps/qos.zig");
    pub const WaitSet = @import("dcps/wait_set.zig").WaitSet;
    pub const Sql = @import("dcps/sql.zig").Sql;
    pub const Sql92 = Sql;

    const sample_info = @import("dcps/sample_info.zig");
    pub const SampleInfo = sample_info.SampleInfo;
    pub const SampleStateKind = sample_info.SampleStateKind;
    pub const ViewStateKind = sample_info.ViewStateKind;
    pub const InstanceStateKind = sample_info.InstanceStateKind;
    pub const SampleStateMask = sample_info.SampleStateMask;
    pub const ViewStateMask = sample_info.ViewStateMask;
    pub const InstanceStateMask = sample_info.InstanceStateMask;

    const status = @import("dcps/status.zig");
    pub const Status = status;
    pub const StatusKind = status.StatusKind;
    pub const SampleRejectedStatusKind = status.SampleRejectedStatusKind;
    pub const SampleRejectedStatus = status.SampleRejectedStatus;
    pub const DeadlineMissedStatus = status.DeadlineMissedStatus;
    pub const LivelinessChangedStatus = status.LivelinessChangedStatus;
    pub const LivelinessLostStatus = status.LivelinessLostStatus;
    pub const MatchedStatus = status.MatchedStatus;

    const condition = @import("dcps/condition.zig");
    pub const Condition = condition.Condition;
    pub const ReadCondition = condition.ReadCondition;

    pub const DynamicDataReader = @import("types/dynamic_data_reader.zig").DynamicDataReader;
    pub const DynamicDataWriter = @import("types/dynamic_data_writer.zig").DynamicDataWriter;
    pub const rpc = @import("rpc/rpc.zig");
};

pub const xtypes = @import("types/xtypes.zig");

pub const builtin = struct {
    const spdp = @import("discovery/spdp.zig");
    pub const ParticipantData = spdp.SPDPDiscoveredParticipantData;
    pub const TopicData = spdp.DiscoveredTopicData;

    const sedp = @import("discovery/sedp.zig");
    pub const PublicationData = sedp.DiscoveredWriterData;
    pub const SubscriptionData = sedp.DiscoveredReaderData;
};

/// @brief Security structure.
pub const security = struct {
    pub const AuthenticationPlugin = @import("security/authentication_plugin.zig");
    pub const AccessControlPlugin = @import("security/access_control_plugin.zig");
    pub const CryptographyPlugin = @import("security/cryptography_plugin.zig");
};

pub const xml = @import("xml/xml.zig");
pub const json = @import("json/json.zig");

test {
    std.testing.refAllDecls(@This());
}

test {
    _ = @import("rtps/types.zig");
    _ = @import("rtps/message.zig");
    _ = @import("rtps/submessage.zig");
    _ = @import("rtps/history_cache.zig");
    _ = @import("net/udp_socket.zig");
    _ = @import("cdr/serializer.zig");
    _ = @import("cdr/deserializer.zig");
    _ = @import("dcps/domain_participant.zig");
    _ = @import("dcps/publisher.zig");
    _ = @import("dcps/subscriber.zig");
    _ = @import("dcps/data_writer.zig");
    _ = @import("dcps/data_reader.zig");
    _ = @import("dcps/topic.zig");
    _ = @import("dcps/wait_set.zig");
    _ = @import("dcps/qos.zig");
    _ = @import("dcps/condition.zig");
    _ = @import("dcps/entity.zig");
    _ = @import("dcps/domain_participant_factory.zig");
    _ = @import("dcps/sql.zig");
    _ = @import("types/dynamic_data_reader.zig");
    _ = @import("types/dynamic_data_writer.zig");
    _ = @import("types/xtypes.zig");
    _ = @import("types/multi_topic.zig");
    _ = @import("transport/shm.zig");
    _ = @import("security/authentication_plugin.zig");
    _ = @import("security/access_control_plugin.zig");
    _ = @import("security/cryptography_plugin.zig");
    _ = @import("xml/xml.zig");
    _ = @import("json/json.zig");
}
pub const os = @import("os.zig");
