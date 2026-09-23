# IDL Interoperability Example

This example demonstrates how to integrate Zig types generated from standard OMG IDL 4.2 definitions using the built-in `ddz_gen` compiler.

## What it does
1. Ingests [`SensorData.idl`](sensor_data.idl) compiled to Zig via `ddz_gen`.
2. Registers the generated `SensorNetwork.SensorReading` type with a `DomainParticipant`.
3. Publishes structured sensor telemetry (enums, arrays, floats, fixed strings).
4. Subscribes and reads the data sample back via a strongly-typed `DataReader`.

## Generating Code
To regenerate [`SensorData.zig`](sensor_data.zig) from [`SensorData.idl`](sensor_data.idl):

```bash
zig build run-ddz_gen -- -d examples/idl_interop examples/idl_interop/SensorData.idl
```

## Running

```bash
zig build run-idl_interop
```
