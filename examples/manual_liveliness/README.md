# Manual Liveliness QoS Example

This example demonstrates the **LivelinessQosPolicy** with `kind = .manual_by_topic`, where a DataWriter must actively assert its liveliness within a lease duration.

## What it does
1. Configures both DataWriter and DataReader with `liveliness.kind = .manual_by_topic` and a 2-second `lease_duration`.
2. Registers listeners on both endpoints:
   - `DataReaderListener.on_liveliness_changed` to monitor active writers.
   - `DataWriterListener.on_liveliness_lost` to monitor lease expirations.
3. **Phase 1: Active Assertion**:
   - The writer calls `writer.assertLiveliness()` once per second for 3 cycles.
   - The reader confirms that `alive_count` remains 1.
4. **Phase 2: Lease Expiration**:
   - The writer halts assertions and sleeps for 3 seconds (> 2s lease).
   - The writer's `on_liveliness_lost` callback fires.
   - The reader's `on_liveliness_changed` callback fires with `alive_count = 0`.
5. **Phase 3: Recovery**:
   - The writer resumes `writer.assertLiveliness()`.
   - The reader's listener fires again indicating `alive_count = 1`.

## Highlighted Feature
**Heartbeat-Free Health Monitoring**: Enables high-criticality systems (e.g., flight controllers, medical devices) to verify that publisher worker threads are actively operational without needing to send actual application payload samples.

## Running

```bash
zig build run-manual_liveliness
```
