# Built-in Topics Example

This example demonstrates how to inspect local and remote DDS topology dynamically using standard **Built-in Topics**.

## What it does
1. Creates an enabled `DomainParticipant` on Domain 0.
2. Creates a user publisher with a typed topic (`DummyTopic`) to trigger local discovery announcements.
3. Retrieves the built-in subscriber via `participant.getBuiltinSubscriber()`.
4. Looks up the standard built-in readers:
   - `DCPSPublication` — discovers remote and local DataWriters.
   - `DCPSSubscription` — discovers remote and local DataReaders.
   - `DCPSParticipant` — discovers remote and local DomainParticipants.
5. Attaches `StatusCondition` instances to a `WaitSet` listening for `data_available`.
6. Wakes up when discovery information arrives and reads publication metadata using `read(ddz.builtin.PublicationData, ...)` and `returnLoan()`.

## Highlighted Feature
**Zero-Tooling Introspection**: Standard Built-in Topics allow applications to introspect the entire DDS network topology directly from code, enabling custom discovery monitors, health checks, and debugging agents without third-party tools.

## Running

```bash
zig build run-builtin_topics
```
