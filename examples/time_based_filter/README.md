# Time-Based Filter QoS Example

This example demonstrates the **TimeBasedFilterQosPolicy**, which allows subscribers to downsample high-frequency data streams to match their local processing capabilities.

## What it does
1. Creates a fast DataWriter that publishes 50 sensor updates at 100 Hz (one sample every 10ms).
2. Creates a DataReader configured with `minimum_separation_ms = 200` and `history.depth = 10`.
3. The writer emits 50 samples in ~500ms.
4. The reader's filter discards incoming updates that arrive less than 200ms after the last accepted sample.
5. The reader only receives ~3-4 samples out of the 50 sent, perfectly respecting the 200ms separation window.

## Highlighted Feature
**Subscriber-Side Rate Throttling**: Ideal for low-power display displays, GUI dashboards, or cloud telemetry gateways that subscribe to high-frequency sensor streams (e.g. 1 kHz IMUs) but only need updates at human-readable rates (e.g. 5-10 Hz).

## Running

```bash
zig build run-time_based_filter
```
