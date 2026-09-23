# Persistent Durability QoS Example

This example demonstrates the **DurabilityQosPolicy** with `kind = .persistent`, allowing topic cache data to survive process terminations and reboots by persisting to disk.

## What it does
1. Configures a DataWriter and DataReader with `durability = .persistent` and `history.kind = .keep_all`.
2. When the DataWriter writes new configuration samples, the changes are stored in memory and committed to disk.
3. When the application runs again, the DataReader loads all historical data previously written from disk.
4. The publisher appends a new configuration sample, which is appended to the persistent history cache.
5. All loaned samples are cleanly returned via `reader.returnLoan()`.

## Highlighted Feature
**Cross-Session History Preservation**: Unlike `transient_local` (which only survives as long as the writer process is alive), `persistent` durability guarantees that critical system configuration, calibration data, and parameter maps remain available even after system reboots.

## Running

```bash
zig build run-persistent_durability
```
