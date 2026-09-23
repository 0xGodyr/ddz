# DDZ Spy (Network Sniffer)

`ddz_spy` is a terminal-based diagnostic tool for the DDZ ecosystem that acts as an autonomous network sniffer. It discovers active DDZ participants, readers, and writers dynamically using the SPDP and SEDP discovery protocols, and intercepts user data across all topics.

## Features

- **Passive Discovery:** Uses standard SPDP and SEDP to discover all endpoints on Domain 0 without interfering with their operations.
- **Dynamic Type Resolution:** Automatically receives and decodes type schemas inline during SEDP announcement or issues standard RPC `TypeLookup` requests if needed.
- **JSON Payload Dissection:** Decodes raw binary CDR data dynamically and prints human-readable JSON payloads to the terminal.
- **Protocol Tracking:** Tracks lifecycle events, such as a participant joining or leaving the domain, and logs unrecognized payloads.

## Usage

Run the tool using Zig's build system or the compiled executable.

```bash
# Using zig build
zig build run-ddz_spy

# Or running the executable directly
./zig-out/bin/ddz_spy # (or .\zig-out\bin\ddz_spy.exe on Windows)
```

## Output Example

When `ddz_spy` is running alongside `ddz_ping`, you will see output similar to this:

```
=========================================
=        DDZ SPY - Network Sniffer      =
=========================================
[Spy] DomainParticipant enabled (Domain 0).
[Spy] Attached to SEDP Pub Discovery.
[Spy] Attached to SEDP Sub Discovery.
[Spy] Waiting for network traffic...

[Discovery] New Publisher -> Topic: 'PingTopic', Type: 'PingMsg.PingMsg'
            Subscribing dynamically to 'PingTopic'...
[Discovery] New Subscriber -> Topic: 'PongTopic', Type: 'PingMsg.PingMsg'

[Data] [PongTopic] Payload:
{
  "payload": "                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        ",
  "sequence_num": 0,
  "payload_len": 10,
  "timestamp_ns": 22373669130100
}
```

## How It Works

1. `ddz_spy` initializes a `DomainParticipant` on Domain 0.
2. It sets up `WaitSet` instances on the built-in SEDP discovery readers (`sedp_pub_reader` and `sedp_sub_reader`).
3. Whenever a new Publisher is discovered, it inspects the `DiscoveredWriterData` payload.
4. It dynamically instantiates a generic `DataReader` and subscribes to the discovered topic.
5. Incoming data on these dynamically subscribed topics is deserialized using the resolved `TypeObject` and printed to the terminal.
