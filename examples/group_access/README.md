# Group Access (Presentation QoS) Example

This example demonstrates how to use the **PresentationQosPolicy** with `access_scope = .group` to guarantee both **Coherent Access** and **Ordered Access** across multiple topics.

## What it does
1. Configures a Publisher and Subscriber with `access_scope = .group`, `coherent_access = true`, and `ordered_access = true`.
2. Creates two separate topics: `Position` and `Velocity`.
3. Demonstrates **Coherent Access**:
   - Calls `publisher.beginCoherentChanges()`.
   - Writes samples across both `Position` and `Velocity` topics.
   - Verifies that readers see **no data** while the transaction is open.
   - Calls `publisher.endCoherentChanges()`.
4. Demonstrates **Ordered Access**:
   - Calls `subscriber.beginAccess()`.
   - Calls `subscriber.getDataReaders()` to retrieve readers sorted by source timestamp across all topics.
   - Takes samples using `take()` and `returnLoan()`.
   - Calls `subscriber.endAccess()`.

## Highlighted Feature
**Multi-Topic Atomic Snapshots**: Coherent access ensures that interdependent data (such as position and velocity for a robotic joint) is always delivered and observed together as an atomic transaction, preventing readers from processing partial state updates.

## Running

```bash
zig build run-group_access
```
