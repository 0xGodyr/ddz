# Comprehensive DDZ Test

This is the primary integration test application used to test the full feature set of DDZ working in tandem.

## Features Tested
- **Multi-Participant Network**: Instantiates 3 distinct `DomainParticipant` nodes (1 Publisher + 2 Subscribers) on Domain 0.
- **DDS Security (DDS-SEC)**: Initializes PKI-DH authentication, XML permissions access control, and AES-256-GCM encryption across all endpoints.
- **XTypes Dynamic Data**: Subscriber 1 uses `DynamicDataReader` to dynamically resolve type schemas via TypeLookup RPC without compile-time types.
- **Content-Filtered Topics (CFT)**: Subscriber 2 subscribes via a `ContentFilteredTopic` with a SQL-92 predicate (`id > 2`).
- **WaitSet & ReadCondition**: Uses `WaitSet` attached to a `ReadCondition` for asynchronous wakeups.
- **Batching & Shared Memory**: Writer is configured with batching (`max_data_bytes = 1024`) and zero-copy shared memory (`shm.enable = true`).
- **Clean Shutdown**: Explicitly joins network threads, terminates participants, and deinits security plugins deterministically.

## Running

```bash
zig build run-comprehensive
# Or using the shorthand alias:
zig build run
```
