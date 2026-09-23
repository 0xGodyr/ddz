# Durability QoS (Late Joiner) Example

This example demonstrates how DDS inherently decouples publishers and subscribers in time using the DurabilityQosPolicy.

## What it does
1. Creates a DataWriter configured with TRANSIENT_LOCAL durability.
2. The Publisher writes a configuration message (Config ID: 42).
3. The program sleeps for 2 seconds. At this point, no readers exist!
4. The system creates a "Late Joiner" DataReader (also configured with TRANSIENT_LOCAL durability).
5. The Subscriber automatically receives the historical data that was sent before it even existed.

## Highlighted Feature
**O(1) History Cache Synchronizations**: When configured for TRANSIENT_LOCAL, DDZ preserves the HistoryCache for a topic even when there are no active readers. When a Late Joiner is discovered via SEDP, the RTPS State Machine automatically iterates the pre-allocated Ring Buffer and synchronizes the historical CacheChanges to the new Reader instantly.

## Running

```bash
zig build run-qos_durability
```
