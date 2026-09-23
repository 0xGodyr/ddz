# Exclusive Ownership QoS Example

This example demonstrates OwnershipQosPolicy (.exclusive) combined with OwnershipStrengthQosPolicy and LivelinessQosPolicy.

## Behavior
1. A Reader connects with EXCLUSIVE ownership.
2. A Primary Writer connects with strength 100.
3. A Backup Writer connects with strength 50.
4. Both write data to the same instance (same ID). The Reader gracefully drops the data from the backup writer because a higher strength writer is active.
5. We simulate the Primary Writer dying by waiting 3 seconds (exceeding the 2 second lease_duration).
6. The Backup Writer writes again, and because the Primary Writer's liveliness expired, the Backup Writer automatically takes over ownership of the instance and the Reader accepts the new data!

## Running

```bash
zig build run-ownership
```
