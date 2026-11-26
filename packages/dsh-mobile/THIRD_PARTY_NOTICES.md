# Third-Party Notices

This package (`agent-mobile-gateway`) is licensed under the Apache License, Version 2.0.

## Runtime Dependencies

- **qrcode** (`^1.5.4`) — MIT License — SVG QR code rendering in the desktop pairing panel.
- **dijkstrajs** / **pngjs** (transitive via `qrcode`) — MIT License.

## Peer / Host Platform Interfaces

- **React** (`^18.2.0`) — MIT License.
- **Cordis / DSH Client UI Packages** (`@deepseek-ai/cordis`, `@deepseek-ai/dsh-client-*`) — host-provided at runtime.

## Protocol & Cryptography References

- **Noise Protocol Framework (Revision 34)** (`Noise_IK_25519_ChaChaPoly_SHA256`) — Public Domain (CC0 1.0), implemented directly on top of Node.js `node:crypto` primitives (`X25519`, `chacha20-poly1305`, `SHA-256`, `HMAC-SHA256`).
- **Agent Client Protocol (ACP)** — JSON-RPC 2.0 over stdio specification for CLI agents.
