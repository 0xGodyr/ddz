# Dynamic Data (XTypes) Example

This example demonstrates how to define, publish, and subscribe to data dynamically at runtime using the **OMG DDS-XTypes (Extensible and Dynamic Topic Types)** API without compile-time Zig structs.

## What it does
1. Dynamically constructs a `TypeObject` for `ShapeType` with runtime field definitions (`color: String`, `x: Int32`, `y: Int32`, `size: Int32`).
2. Creates a `DynamicDataWriter` that serializes the `TypeObject` into CDR metadata.
3. Creates a `DynamicDataReader` on a separate subscriber participant.
4. Constructs a `DynamicValue` (a runtime map of fields to values) and writes it via `dynamic_writer.writeDynamic(val)`.
5. The `DynamicDataReader` reads the raw CDR payload from its cache and deserializes it dynamically into a `DynamicValue` struct using `takeDynamic()`.

## Highlighted Feature
**Schema-Less Data Distribution**: Enables generic bridges, web gateways, recording tools, and data visualizers to inspect and publish DDS data without having access to compile-time struct declarations or pre-compiled IDL files.

## Running

```bash
zig build run-dynamic_data
```
