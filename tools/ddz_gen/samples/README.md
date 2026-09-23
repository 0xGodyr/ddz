# ddz_gen Test Samples

This directory contains representative sample input files for verifying and demonstrating the capabilities of `ddz_gen`.

---

## Sample Files

| File | Type | Feature Demonstrated |
| :--- | :--- | :--- |
| [`SensorData.idl`](sensor_data.idl) | OMG IDL 4.2 | Modules, enums, structs, bounded strings (`string<32>`), bounded sequences (`sequence<float, 4>`), and `@key` annotations. |
| [`MotorService.idl`](motor_service.idl) | OMG IDL 4.2 (RPC) | Service interfaces (`interface MotorService`), methods with `in` parameters, void return types, complex return types (`MotorStatus`), client requester stubs, and server replier dispatch skeleton handlers. |
| [`Twist.msg`](twist.msg) | ROS 2 `.msg` | ROS 2 message definition with nested type references (`Vector3 linear`, `Vector3 angular`). |
| [`Vector3.msg`](vector3.msg) | ROS 2 `.msg` | ROS 2 scalar vector message definition (`float64 x`, `float64 y`, `float64 z`). |
| [`VehicleArchitecture.xmi`](vehicle_architecture.xmi) | OMG DDS-UML XMI | Model-Based Systems Engineering (MBSE) architecture model with `<<Topic>>`, `<<Key>>`, `<<DomainParticipant>>`, `<<DataWriter>>`, and `<<DataReader>>` stereotypes. |

---

## How to Run Them

You can run `ddz_gen` either via the Zig build runner or directly via the compiled binary.

### 1. Compile OMG IDL 4.2 (`SensorData.idl`)

Generate Zig structs and types from standard OMG IDL 4.2:

```bash
# Using zig build runner
zig build run-ddz_gen -- -d src/generated tools/ddz_gen/samples/SensorData.idl

# Or using the built binary directly
./zig-out/bin/ddz_gen -d src/generated tools/ddz_gen/samples/SensorData.idl
```

**Output:** `src/generated/SensorData.zig` containing the `SensorNetwork` module, `SensorType` enum, and `@key`-annotated `SensorReading` struct.

---

### 2. Compile DDS-RPC Service Interface (`MotorService.idl`)

Generate typed Request/Reply structs, synchronous/asynchronous client requesters, and server skeleton handlers with `--rpc`:

```bash
# Using zig build runner
zig build run-ddz_gen -- -d src/generated --rpc tools/ddz_gen/samples/MotorService.idl

# Or using the built binary directly
./zig-out/bin/ddz_gen -d src/generated --rpc tools/ddz_gen/samples/MotorService.idl
```

**Output:** `src/generated/MotorService.zig` containing `Control.MotorStatus`, `Control.MotorServiceClient`, and `Control.MotorServiceServer`.

---

### 3. Compile ROS 2 Messages (`Twist.msg` and `Vector3.msg`)

Generate native Zig structs from ROS 2 `.msg` definitions:

```bash
# Using zig build runner
zig build run-ddz_gen -- -d src/generated --ros2 tools/ddz_gen/samples/Vector3.msg tools/ddz_gen/samples/Twist.msg

# Or using the built binary directly
./zig-out/bin/ddz_gen -d src/generated --ros2 tools/ddz_gen/samples/Vector3.msg tools/ddz_gen/samples/Twist.msg
```

**Output:** `src/generated/Vector3.zig` and `src/generated/Twist.zig`.

---

### 4. Reverse Compilation (Zig Struct $\to$ OMG IDL 4.2)

You can also reverse generate OMG IDL from any existing Zig source file:

```bash
# Reverse generate IDL from a Zig type
zig build run-ddz_gen -- -d idl/ --reverse src/generated/SensorData.zig
```

---

### 5. Compile OMG DDS-UML Models (`VehicleArchitecture.xmi`)

Generate strongly-typed Zig topic structs, complete DDZ application deployment topology scaffolding, and OMG IDL 4.2 schemas directly from standard MBSE XMI exports:

```bash
# Using zig build runner
zig build run-ddz_gen -- -d src/generated --xmi --gen-idl tools/ddz_gen/samples/VehicleArchitecture.xmi

# Or using the built binary directly
./zig-out/bin/ddz_gen -d src/generated --xmi --gen-idl tools/ddz_gen/samples/VehicleArchitecture.xmi
```

**Outputs:**
- `src/generated/VehicleArchitectureTypes.zig`: Typed Zig structs with `@key` support and topic constants.
- `src/generated/VehicleArchitectureTopology.zig`: Pre-wired Participant, Publisher, Subscriber, DataWriter, and DataReader topology scaffolding configured with the modeled QoS (reliability, durability, history, deadline).
- `src/generated/VehicleArchitecture.idl`: Standard OMG IDL 4.2 schema definition.

