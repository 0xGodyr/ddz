<div align="center">
  <h1>🏓 ddz_ping</h1>
  <p><strong>Standardized Command-Line Diagnostics for DDZ</strong></p>

  [![Status: Alpha](https://img.shields.io/badge/Status-Alpha-orange)](#)
</div>

---

## Overview

ddz_ping is a command-line diagnostic tool included with the DDZ library. It is designed to measure the network latency and throughput of the underlying DDZ RTPS middleware by exchanging Ping/Pong messages between Publisher and Subscriber processes.

Similar to the classic network ping utility, ddz_ping helps you verify that RTPS discovery is working across process boundaries and provides raw metrics on how fast your DDZ configuration can push data.

### Features

- **Latency Testing (RTT):** Measures the precise Round-Trip Time (RTT) of individual samples.
- **Throughput Testing:** Blasts a fixed number of samples and calculates the bandwidth (MB/s) and message rate (samples/sec).
- **QoS Toggling:** Test both Best-Effort (UDP-like) and Reliable (TCP-like) delivery mechanisms.
- **Custom Payload Sizes:** Scale the payload size to test fragmentation and network MTU limits.

---

## Usage

To use ddz_ping, you must run two separate processes: one acting as the **Subscriber** (echo server) and one acting as the **Publisher** (test driver).

### Command-Line Arguments

| Argument | Description | Default |
|---|---|---|
| -sub | Run as the Subscriber (Pong echo server). | (Must specify -pub or -sub) |
| -pub | Run as the Publisher (Ping sender). | (Must specify -pub or -sub) |
| -samples N | Number of ping samples to send. | 10 |
| -size N | Size of the arbitrary byte payload in each ping. | 10 bytes |
| -reliable | Use RELIABLE QoS instead of BEST_EFFORT. | Best-Effort |
| -throughput | Run in throughput mode (do not wait for pongs). | Latency mode |

---

## Examples

### 1. Basic Latency Test

In the first terminal, start the subscriber:
```bash
zig build run-ddz_ping -- -sub
# Or directly:
./zig-out/bin/ddz_ping -sub
```

In the second terminal, run the default latency test (10 samples, best-effort):
```bash
zig build run-ddz_ping -- -pub
# Or directly:
./zig-out/bin/ddz_ping -pub
```

**Output:**
```text
Starting DDZ Ping Publisher...
Samples: 10, Size: 10, Reliable: false, Throughput: false
Waiting for discovery...
Starting latency test...
Got pong seq=0 (expected 0)
Reply from seq=0: time=12.395 ms
Got pong seq=1 (expected 1)
Reply from seq=1: time=11.029 ms
...

--- Ping Statistics ---
10 samples transmitted, 10 received
rtt min/avg/max = 11.029/11.547/12.395 ms
```

### 2. High-Throughput Test

To measure raw bandwidth, use -throughput. The Publisher will blast messages without waiting for Pongs.

Terminal 1:
```bash
zig build run-ddz_ping -- -sub
```

Terminal 2:
```bash
zig build run-ddz_ping -- -pub -samples 50000 -size 1024 -throughput
```

**Output:**
```text
Starting DDZ Ping Publisher...
Samples: 50000, Size: 1024, Reliable: false, Throughput: true
Waiting for discovery...
Starting throughput test...
Throughput: 42161.28 samples/sec (41.83 MB/s)
```

### 3. Reliable Delivery Test

By default, ddz_ping uses BEST_EFFORT QoS (fire-and-forget UDP). You can test DDZ's RTPS reliability protocol (Heartbeats and AckNacks) by adding the -reliable flag to **both** processes.

Terminal 1:
```bash
zig build run-ddz_ping -- -sub -reliable
```

Terminal 2:
```bash
zig build run-ddz_ping -- -pub -reliable -samples 100 -size 1024
```

---

## Building

If you haven't built the tool yet, run the main Zig build command from the root of the DDZ repository:

```bash
zig build
```

The compiled executable will be placed in `zig-out/bin/ddz_ping` (or `ddz_ping.exe` on Windows).
