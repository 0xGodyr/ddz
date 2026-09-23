# Content Filtered Topics (CFT) Example

This example demonstrates how to use the DDS Content-Filtered Topics specification to dramatically reduce network bandwidth by dropping unneeded samples before they are ever transmitted.

## What it does
1. Creates a standard Topic for SensorData.
2. Creates a ContentFilteredTopic named HighTempTopic wrapping the base topic with a SQL-like expression: "temperature > 100".
3. The Publisher writes temperatures ranging from 95 to 105.
4. The Subscriber only receives the temperatures that are 101, 103, and 105.

## Highlighted Feature
**Writer-Side Evaluation**: In DDZ, Content-Filtered Topics are heavily optimized. The filter is evaluated locally on the Publisher's side *during serialization*. If the data does not match the SQL expression, the serialization is aborted and the network packet is never generated, saving massive amounts of CPU and network bandwidth.

## Running

```bash
zig build run-content_filtered_topics
```
