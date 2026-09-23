# Deadline QoS Example

This example demonstrates the **DeadlineQosPolicy**, which detects when publishers fail to write data within a specified time window.

## What it does
1. Configures both DataWriter and DataReader with a 1000ms deadline (`deadline.period_ms = 1000`).
2. Configures a `StatusCondition` on the DataReader listening for `requested_deadline_missed` and attaches it to a `WaitSet`.
3. The publisher writes ID 1, ID 2, and ID 3 on time (every 500ms, which is well within the 1000ms deadline).
4. The publisher intentionally stops writing.
5. The reader's `WaitSet` detects the missed deadline and wakes up after 1000ms, printing the updated missed deadline counter (`reader.requested_deadline_missed_status.total_count`).

## Highlighted Feature
**Real-Time Temporal Contract Enforcement**: Deadlines allow safety-critical control systems (e.g. automotive steer-by-wire or drone telemetry) to catch hardware or network stalls immediately without polling timeouts.

## Running

```bash
zig build run-qos_deadline
```
