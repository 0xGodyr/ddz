# DDZ Examples

This directory contains 19 runnable examples demonstrating different DDZ features and QoS policies.

## Running Examples

```bash
# Run any example with:
zig build run-<example_name>
```

## Example Index

| Example | Command | QoS / Feature | Description |
|---|---|---|---|
| [Hello World](hello_world/) | `zig build run-hello_world` | Basic pub/sub | Minimal publisher/subscriber. Writes a `HelloWorldData` struct, reads it back with `take()`. Good starting point for new users. |
| [IDL Interop](idl_interop/) | `zig build run-idl_interop` | OMG IDL 4.2 | Demonstrates pub/sub and DDS-RPC using Zig types and stubs generated from OMG IDL schemas via `ddz_gen`. |
| [Comprehensive](comprehensive/) | `zig build run-comprehensive` | Multiple QoS | Integration test exercising reliability, history depth, deadline, liveliness, fragmentation, batching, shared memory, and content filtering in a single program. |
| [Built-in Topics](builtin_topics/) | `zig build run-builtin_topics` | Built-in Topics | Accesses the built-in subscriber and readers (`DCPSPublication`, `DCPSSubscription`, `DCPSParticipant`) to inspect discovery and topology changes. |
| [Content Filtered Topics](content_filtered_topics/) | `zig build run-content_filtered_topics` | ContentFilteredTopic | Creates a `ContentFilteredTopic` with a SQL-like expression (`id > 5`). Only samples matching the filter reach the reader — filtering happens writer-side before serialization. |
| [Dynamic Data](dynamic_data/) | `zig build run-dynamic_data` | XTypes Dynamic Data | Dynamically constructs and transmits data using `TypeObject` and `DynamicValue` without needing compile-time Zig structs. |
| [Group Access](group_access/) | `zig build run-group_access` | Presentation QoS | Demonstrates coherent changes (`beginCoherentChanges()` / `endCoherentChanges()`) where samples are withheld until the set completes, and ordered access (`beginAccess()` / `endAccess()`) where readers are returned sorted by source timestamp. |
| [Lifecycle](lifecycle/) | `zig build run-lifecycle` | Data Lifecycle QoS | Tests `WriterDataLifecycleQos` (auto-dispose on unregister) and `ReaderDataLifecycleQos` (autopurge delays for disposed and no-writer samples). |
| [Manual Liveliness](manual_liveliness/) | `zig build run-manual_liveliness` | Liveliness QoS | Tests `manual_by_topic` liveliness assertion and verifies that reader detects lease expiration and restoration. |
| [Multi-Topic](multi_topic/) | `zig build run-multi_topic` | MultiTopic JOIN | Joins data from two separate topics (e.g., `Temperature` and `GPS`) using a SQL-like expression `SELECT * FROM Temp JOIN GPS ON Temp.id = GPS.id`. Data is correlated at runtime by a shared key field. |
| [Ownership](ownership/) | `zig build run-ownership` | Exclusive Ownership | Two writers with different `ownership_strength` values compete for the same keyed instance. Only the highest-strength writer's samples are delivered to the reader. |
| [Partition QoS](partition_qos/) | `zig build run-partition_qos` | Partition | Demonstrates namespace-based isolation using partition names with glob matching. A writer in `Vehicle/Cars` is only received by readers in `Vehicle/Cars` or `Vehicle/*`, not `Vehicle/Trucks`. |
| [Persistent Durability](persistent_durability/) | `zig build run-persistent_durability` | Persistent Durability | Data survives process restart. The writer serializes its HistoryCache to a `.bin` file on disk. On re-launch, historical data is loaded from disk and delivered to late-joining readers. |
| [Deadline QoS](qos_deadline/) | `zig build run-qos_deadline` | Deadline | Writer publishes at configured intervals. If a sample is not received within the deadline period, the reader fires `on_requested_deadline_missed` and the writer fires `on_offered_deadline_missed`. |
| [Durability QoS](qos_durability/) | `zig build run-qos_durability` | Transient-Local Durability | A writer publishes data, then a reader joins late. With `transient_local` durability, the late-joining reader receives the historical data that was published before it existed. |
| [RPC](rpc/) | `zig build run-rpc` | Request/Reply | Implements the DDS-RPC pattern. A client sends an `AddRequest{a, b}` and a server responds with `AddReply{sum}`. Correlation is handled via `SampleIdentity_t`. |
| [Security](security/) | `zig build run-security` | DDS-SEC | Configures `AuthenticationPlugin` (PKI-DH), `AccessControlPlugin` (XML permissions), and `CryptographyPlugin` (AES-256-GCM). Demonstrates encrypted pub/sub with access control enforcement. |
| [Time-Based Filter](time_based_filter/) | `zig build run-time_based_filter` | Time-Based Filter | Reader configures `minimum_separation_ms` to rate-limit incoming high-frequency streams. |
| [WaitSet StatusCondition](waitset_status_condition/) | `zig build run-waitset_status_condition` | WaitSet & StatusCondition | Blocks the calling thread until an asynchronous entity status change (`publication_matched`) triggers the Condition. |

## Prerequisites

- [Zig compiler](https://ziglang.org/download/) `0.17.0-dev` or later
- Cross-platform: Windows 10/11, Linux (x86_64), macOS (ARM64)
