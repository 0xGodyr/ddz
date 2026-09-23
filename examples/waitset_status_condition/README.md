# WaitSet & StatusCondition Example

This example demonstrates how to use the DDS **WaitSet** and **StatusCondition** APIs to achieve fully asynchronous, non-polling synchronization between publishers and late-joining subscribers.

## What it does
1. Creates an enabled `DomainParticipant` and a `DataWriter`.
2. Creates a `WaitSet` and attaches the writer's `StatusCondition`.
3. The main thread calls `waitset.wait()`, blocking until a matched reader is discovered.
4. In a separate background thread, a late-joining Subscriber and DataReader are created after a 2-second delay.
5. Once discovery matches the endpoints, the `publication_matched` status bit is set.
6. The `WaitSet` unblocks immediately, joins the background worker thread, and safely publishes data without dropping initial samples.

## Highlighted Feature
**Zero-CPU Event-Driven Synchronization**: Eliminates inefficient `sleep` loops and active polling when waiting for discovery, network matches, or data availability.

## Running

```bash
zig build run-waitset_status_condition
```
