# RPC over DDS Example

This example demonstrates the OMG **RPC over DDS** standard implementation in DDZ.

It shows how Requester and Replier entities seamlessly encapsulate Request/Reply topics and handle asynchronous message correlation using RTPS SampleIdentity and RelatedSampleIdentity via Inline QoS.

## Running

```bash
zig build run-rpc
```
