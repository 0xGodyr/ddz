# Instance Lifecycle Example

This example demonstrates the complete **DDS Instance Lifecycle**, showcasing how keyed data instances transition through states when registered, updated, disposed, and unregistered.

## What it does
1. Creates a DataWriter and DataReader for a keyed `SensorData` topic.
2. **Registration & Write (`.ALIVE`)**:
   - The writer registers and writes an instance with `id = 1`.
   - The reader inspects the sample's `SampleInfo.instance_state` and observes the `.alive` state.
3. **Disposal (`.NOT_ALIVE_DISPOSED`)**:
   - The writer disposes the instance via `writer.dispose(data, null)`.
   - The reader observes `instance_state = .not_alive_disposed` and checks `disposed_generation_count`.
4. **Unregistration (`.NOT_ALIVE_NO_WRITERS`)**:
   - The writer unregisters the instance via `writer.unregisterInstance(data, null)`.
   - The reader observes `instance_state = .not_alive_no_writers` and checks `no_writers_generation_count`.

## Highlighted Feature
**Explicit State Machine Tracking**: Unlike simple message queues, DDS maintains stateful instance lifecycles. Readers can distinguish between a sensor sending an update, a sensor explicitly reporting a hardware failure (disposed), and a publisher terminating its interest in an asset (unregistered).

## Running

```bash
zig build run-lifecycle
```
