# DDZ Gen (`ddz_gen`) — OMG IDL 4.2 & ROS 2 Compiler for DDZ

`ddz_gen` is the official OMG IDL 4.2 and ROS 2 interface code-generation tool for the **DDZ (Data Distribution Zervice)** library.

---

## 1. Why `ddz_gen` When Zig Has `comptime`?

In pure Zig applications, DDZ leverages Zig's compile-time reflection (`@typeInfo`) to provide zero-overhead CDR serialization, instance key hashing (`ddz_keys`), and XTypes discovery without requiring an IDL compiler.

However, in multi-language enterprise environments (aerospace, defense, automotive AUTOSAR, ROS 2 robotics), **OMG IDL is the Single Source of Truth (SSoT)** shared across C++, Python, Rust, and C nodes. `ddz_gen` eliminates manual, error-prone translation of IDL files into Zig structs, automating:
- Strict OMG IDL 4.2 to Zig wire-layout compliance.
- Standard annotations (`@key`, `@id`, `@optional`, `@default`, `@extensibility`).
- Complex discriminated unions with multi-case branches and default labels.
- Sized bitsets and bitmasks mapped to Zig `packed struct`s.
- Bounded and unbounded sequences and strings.
- DDS-RPC typed client `Requester` stubs and server `Replier` dispatchers.
- Direct parsing of ROS 2 `.msg` and `.srv` interface definitions.
- Automatic dependency imports for nested ROS 2 message types.
- Reverse compilation: export standardized OMG IDL 4.2 from existing Zig structs.

---

## 2. Command-Line Reference

```
Usage: ddz_gen [options] <idl-or-msg-files...>

Options:
  -d, --output-dir <dir>       Directory for generated source files (default: .)
  -I, --include <dir>          Add directory to search path for #include directives
  -p, --package <name>         Package/module namespace override
  --rpc                        Generate DDS-RPC Client Requesters and Server Repliers
  --ros2                       Parse input files as ROS 2 .msg or .srv definitions
  --xmi, --uml                 Parse input files as OMG DDS-UML XMI models
  --gen-idl                    Emit OMG IDL 4.2 schema definition alongside Zig code
  --reverse                    Reverse mode: inspect Zig structs and emit OMG IDL 4.2
  --replace                    Overwrite existing files
  --no-fmt                     Do not invoke 'zig fmt' on output files
  -v, --verbose                Enable verbose compilation output
  -h, --help                   Display this help message and exit
  --version                    Display ddz_gen version

Examples:
  ddz_gen -d src/generated/ idl/SensorData.idl
  ddz_gen -d src/generated/ --rpc idl/MotorService.idl
  ddz_gen -d src/generated/ --ros2 msg/Twist.msg
  ddz_gen -d src/generated/ --xmi models/VehicleArchitecture.xmi
  ddz_gen --reverse src/types/Sensor.zig
```

---

## 3. Quickstart with Sample Files

The [`samples/`](samples/) directory contains ready-to-use sample definitions demonstrating each major compiler feature.

| File | Type | Feature Demonstrated |
| :--- | :--- | :--- |
| [`SensorData.idl`](samples/sensor_data.idl) | OMG IDL 4.2 | Modules, enums, `@key` annotations, bounded sequences (`sequence<float, 4>`), and bounded strings (`string<32>`). |
| [`MotorService.idl`](samples/motor_service.idl) | OMG IDL 4.2 (RPC) | Service interfaces (`interface MotorService`), status structs (`MotorStatus`), methods with `in` parameters, void returns (`emergency_stop`), and complex struct returns (`get_status`). |
| [`Twist.msg`](samples/twist.msg) | ROS 2 `.msg` | Velocity message with nested type dependencies (`Vector3 linear`, `Vector3 angular`). |
| [`Vector3.msg`](samples/vector3.msg) | ROS 2 `.msg` | 3D coordinate vector (`float64 x`, `float64 y`, `float64 z`). |
| [`VehicleArchitecture.xmi`](samples/vehicle_architecture.xmi) | OMG DDS-UML XMI | MBSE system model generating typed topics and pre-configured Participant/Publisher/Subscriber topology scaffolding. |

### 3.1 Compiling OMG IDL 4.2 (`SensorData.idl`)

Generate native Zig structs and enumerations with `ddz_keys`:

```bash
# Using the zig build runner
zig build run-ddz_gen -- -d src/generated tools/ddz_gen/samples/SensorData.idl

# Or using the compiled binary directly
./zig-out/bin/ddz_gen -d src/generated tools/ddz_gen/samples/SensorData.idl
```

**Output:** `src/generated/SensorData.zig`
```zig
pub const SensorNetwork = struct {
    pub const SensorType = enum(u32) {
        TEMPERATURE = 0,
        PRESSURE = 1,
        ACCELEROMETER = 2,
    };

    pub const SensorReading = struct {
        sensor_id: i32 = 0,
        type: SensorType = undefined,
        reading: f64 = 0.0,
        calibration_factors: [4]f32 = undefined,
        device_name: [32:0]u8 = std.mem.zeroes([32:0]u8),

        pub const ddz_keys = [_][]const u8{
            "sensor_id",
        };
    };
};
```

---

### 3.2 Compiling DDS-RPC Services (`MotorService.idl`)

Generate typed Request/Reply structs, client `Requester` stubs, and server `Replier` dispatch handlers using the `--rpc` flag:

```bash
# Using the zig build runner
zig build run-ddz_gen -- -d src/generated --rpc tools/ddz_gen/samples/MotorService.idl

# Or using the compiled binary directly
./zig-out/bin/ddz_gen -d src/generated --rpc tools/ddz_gen/samples/MotorService.idl
```

**Output:** `src/generated/MotorService.zig`
- `Control.MotorStatus`: Value struct
- `Control.MotorService_..._Request` / `Reply`: Operation wire payloads
- `Control.MotorServiceClient`: Strongly typed synchronous and asynchronous client requester methods
- `Control.MotorServiceServer` & `Control.MotorServiceHandler`: Server skeleton dispatch handlers

---

### 3.3 Compiling ROS 2 Messages (`Vector3.msg` & `Twist.msg`)

Generate idiomatic Zig structs from ROS 2 `.msg` files using the `--ros2` flag. Cross-file type references (such as `Vector3` within `Twist`) automatically emit the appropriate `@import("Vector3.zig").Vector3`:

```bash
# Using the zig build runner
zig build run-ddz_gen -- -d src/generated --ros2 tools/ddz_gen/samples/Vector3.msg tools/ddz_gen/samples/Twist.msg

# Or using the compiled binary directly
./zig-out/bin/ddz_gen -d src/generated --ros2 tools/ddz_gen/samples/Vector3.msg tools/ddz_gen/samples/Twist.msg
```

**Output:**
- `src/generated/Vector3.zig`:
  ```zig
  pub const Vector3 = struct {
      x: f64 = 0.0,
      y: f64 = 0.0,
      z: f64 = 0.0,
  };
  ```
- `src/generated/Twist.zig`:
  ```zig
  const Vector3 = @import("Vector3.zig").Vector3;

  pub const Twist = struct {
      linear: Vector3 = undefined,
      angular: Vector3 = undefined,
  };
  ```

---

### 3.4 Reverse Generation (Zig Struct $\to$ OMG IDL 4.2)

Inspect existing Zig structs and export standardized OMG IDL 4.2 files:

```bash
# Using the zig build runner
zig build run-ddz_gen -- -d idl/ --reverse src/generated/SensorData.zig

# Or using the compiled binary directly
./zig-out/bin/ddz_gen -d idl/ --reverse src/generated/SensorData.zig
```

---

### 3.5 Compiling OMG DDS-UML Models (`VehicleArchitecture.xmi`)

Generate typed Zig topic structs, pre-configured DDZ deployment topology scaffolding, and OMG IDL 4.2 definitions directly from enterprise MBSE XMI exports:

```bash
# Using the zig build runner
zig build run-ddz_gen -- -d src/generated --xmi --gen-idl tools/ddz_gen/samples/VehicleArchitecture.xmi

# Or using the compiled binary directly
./zig-out/bin/ddz_gen -d src/generated --xmi --gen-idl tools/ddz_gen/samples/VehicleArchitecture.xmi
```

**Generated Artifacts:**
- `<ModelName>Types.zig`: Strongly typed Zig structs with `@key` support, topic metadata, and key hashing routines.
- `<ModelName>Topology.zig`: Pre-wired Participant, Publisher, Subscriber, DataWriter, and DataReader topology with modeled QoS.
- `<ModelName>.idl`: Standard OMG IDL 4.2 schema definition.

---

## 4. Supported Features & IDL 4.2 Syntax

### 4.1 Topic Structs & Key Annotations
```idl
module Telemetry {
    @key struct DroneStatus {
        @key long drone_id;
        double latitude;
        double longitude;
        float altitude;
        sequence<float, 8> motor_rpms;
        string<32> callsign;
    };
};
```

### 4.2 Discriminated Unions
```idl
union SensorPayload switch (short) {
    case 1:
        float temperature;
    case 2:
    case 3:
        long pressure;
    default:
        octet raw_data[16];
};
```

### 4.3 Bitmasks & Bitsets
```idl
@bit_bound(16)
bitmask SystemAlerts {
    LOW_BATTERY,
    HIGH_TEMP,
    GPS_LOSS,
    MOTOR_FAILURE
};
```

### 4.4 DDS-RPC Interfaces (`--rpc`)
```idl
interface CameraService {
    boolean captureFrame(in long resolution_preset, out string image_uri);
};
```
Generates:
- `CameraService_captureFrame_Request`
- `CameraService_captureFrame_Reply`
- `CameraServiceClient` (with synchronous and asynchronous call helpers)
- `CameraServiceServer` & `CameraServiceHandler` skeleton dispatch tables

### 4.5 ROS 2 `.msg` and `.srv` Support (`--ros2`)
```
# Twist.msg
Vector3 linear
Vector3 angular
```
Compiles directly into native Zig structs matching ROS 2 DDS type conventions with automatic dependency resolution.

### 4.6 Reverse IDL Mode (`--reverse`)
Inspects existing Zig structs and emits standardized OMG IDL 4.2 files:
```bash
ddz_gen --reverse -d idl/ src/types/SensorData.zig
```

---

## 5. `build.zig` Integration

Add IDL compilation directly to your project's `build.zig`:

```zig
const ddz_gen_step = b.addRunArtifact(ddz_gen_exe);
ddz_gen_step.addArg("-d");
ddz_gen_step.addDirectoryArg(b.path("src/generated"));
ddz_gen_step.addFileArg(b.path("idl/SensorData.idl"));

my_app.step.dependOn(&ddz_gen_step.step);
```
