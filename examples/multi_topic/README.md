# MultiTopic JOIN Example

This example demonstrates the OMG DDS **MultiTopic** specification, allowing subscribers to correlate and merge data from multiple independent topics using SQL-92 `JOIN` expressions.

## What it does
1. Registers two distinct typed physical topics:
   - `Temp` (`id: u32`, `temp_val: f32`)
   - `GPS` (`id: u32`, `lat: f32`)
2. Creates separate DataWriters for `Temp` and `GPS`.
3. Creates a `MultiTopic` with a relational join expression:
   ```sql
   SELECT * FROM Temp JOIN GPS ON Temp.id = GPS.id
   ```
4. Creates a `MultiDataReader` bound to the `MultiTopic`.
5. Publishes GPS data and Temperature data asynchronously.
6. The `MultiDataReader` correlates matching tuples by their shared `id` key and outputs the combined dynamic record via `takeDynamic()`.

## Highlighted Feature
**Middleware-Level Relational Queries**: Applications do not need to implement custom correlation hash maps or timestamp windowing algorithms in application code. DDZ handles dynamic stream joining directly at the middleware layer.

## Running

```bash
zig build run-multi_topic
```
