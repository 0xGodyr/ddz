# DDS-SEC (Security) Example

This example demonstrates how to enable the Official OMG DDS Security plugins for Authentication, Access Control, and Cryptography.

## What it does
1. Initializes the `AuthenticationPlugin.PkiDhAuthentication` and `AccessControlPlugin.PermissionsAccessControl` plugins.
2. Attaches the security plugins to a `DomainParticipant` on Domain 0.
3. Creates a Publisher and Subscriber for `TopSecretTopic`.
4. The Writer serializes the message, encrypts the payload using AES-256-GCM, and sends the ciphertext.
5. The Reader receives the sample, verifies the authentication tag, decrypts the payload, and provides the plaintext to the user.
6. Cleanly deinitializes all security plugins and participant resources upon completion.

## Highlighted Feature
**Transparent Cryptography**: Notice how the application code for writing and reading the data (`writer.write(...)`) remains clean and type-safe! DDZ integrates encryption into the serialization pipeline and ensures all plugin memory is deterministically managed.

## Running

```bash
zig build run-security
```
