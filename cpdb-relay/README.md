# cpdb-relay

Cloudflare Worker that serves as the cross-platform sync substrate
for cpdb. See [`../docs/relay-protocol.md`](../docs/relay-protocol.md)
for the wire-format contract — this directory is the server-side
implementation of v1.

## Architecture

```
Cloudflare Worker  ──►  Durable Object (one per workspace_id)
     │                        │
     │                        └─► R2 bucket (encrypted envelope bytes)
     │
     └─► WebSocket fan-out for live envelope notifications
```

- Worker handles routing + auth + validation; stateless except for
  config.
- Durable Object holds per-workspace state: envelope index, online
  device sockets, replay-protection LRU.
- R2 holds encrypted envelope bytes keyed by
  `<workspace_id>/<envelope_id>`.

The relay is a **blind store** — it never sees plaintext clipboard
content. Authentication is via HMAC over a PSK that lives only on
paired user devices.

## Local dev

```sh
npm install
npm run dev          # wrangler dev
```

Wrangler exposes the Worker at `http://localhost:8787` with R2 + DO
emulation. `npm test` runs the protocol-level integration tests
under `test/`.

## Deploy

```sh
npm run deploy
```

Pushes to the configured Cloudflare account. One-time setup:

1. `npx wrangler login`
2. `npx wrangler r2 bucket create cpdb-envelopes`
3. Edit `wrangler.toml` to point `account_id` at your Cloudflare account.

## Status

**Phase A — additive beta.** Skeleton + protocol stubs only. Not yet
wired to the macOS/Windows clients.
