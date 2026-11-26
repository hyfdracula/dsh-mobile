# Third-Party Notices — Agent Mobile (HarmonyOS Client)

Agent Mobile for HarmonyOS (`remote/app-shell`) is original ArkTS software licensed under the Apache License, Version 2.0.

## System & Platform SDKs

- **HarmonyOS / OpenHarmony SDK (`@kit.*`, `@ohos.*`, `@hms.core.*`)** — Provided by the HarmonyOS runtime and DevEco SDK toolchain (`ArkUI`, `AbilityKit`, `CryptoArchitectureKit`, `NetworkKit`, `ArkData`, `ArkWeb`, `CoreFileKit`, `UIDesignKit`, `ScanKit`).

## Public-Domain Specifications Implemented Clean-Room

- **Noise Protocol Framework (Revision 34)** (`Noise_IK_25519_ChaChaPoly_SHA256`, Trevor Perrin, 2018) — Public Domain (CC0 1.0 Universal). Implemented directly using native `@kit.CryptoArchitectureKit` primitives (`X25519`, `ChaCha20|Poly1305`, `SHA256`, `HMAC`).
- **RFC 9562 (UUID Version 7) & RFC 8410 (X25519 ASN.1 SubjectPublicKeyInfo / PKCS#8)**.
