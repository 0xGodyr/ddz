# Partition QoS Example

This example demonstrates the usage of the **PartitionQosPolicy**, which allows publishers and subscribers to isolate their data traffic within logical namespaces (partitions) over the same Topic.

## Features Demonstrated
1. Assigning a namespace string (e.g., Vehicle/Cars) to a Publisher and Subscriber.
2. Demonstrating that data published in one partition is isolated from readers in other partitions.
3. Using **POSIX Wildcard/Glob matching** (e.g., Vehicle/*) to subscribe to multiple partitions concurrently.

## Running

```bash
zig build run-partition_qos
```
