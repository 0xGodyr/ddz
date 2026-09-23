# Hello World Example

This is the absolute most minimal example of creating a DDS application using DDZ. 

## What it does
1. Creates a single DomainParticipant on Domain 0.
2. Sets up a basic Publisher and Subscriber.
3. Creates a strongly-typed DataWriter and DataReader for a HelloWorldData topic.
4. Writes a single message and reads it directly from the HistoryCache.

## Highlighted Feature
**Zero-Copy Localhost Routing**: Notice how fast the message goes from Writer to Reader! Because both endpoints are on the same Participant, DDZ entirely bypasses the UDP network stack and delivers the pointer directly via local memory.

## Running

```bash
zig build run-hello_world
```
