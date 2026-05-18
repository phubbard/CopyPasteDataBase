# Relay sync v2 — accounts, devices, tiers, enterprise (ROADMAP)

**Status: deferred / not started.** This is a captured design from a
planning discussion, parked for a future work cycle. The shipped
`docs/relay-protocol.md` (v1, blind-PSK) and `cpdb-relay/` scaffold
remain the current state. **Do not start building from this doc
without re-confirming scope** — it's a 3-6 month arc, not a sprint.

## Why this exists

The v1 "blind store with 32-byte PSK" design has a clean privacy
story but is fundamentally incompatible with new product
requirements that surfaced after an offline discussion:

1. **Abuse vector.** A pure trust-the-PSK workspace is prone to
   misuse as semi-private image sharing (friend groups passing a
   PSK around). Need to manage users, devices-per-group, and rate
   limits.
2. **Monetization.** If this becomes a product: freemium ("2
   devices free"), and companies will want user + device
   management plus OAuth / SSO.

Server-side accountability is the inverse of "server knows
nothing," so the auth + identity layer needs a rebuild. The
*content* stays end-to-end encrypted.

## Target architecture (Bitwarden / 1Password model)

```
v1:  PSK is identity AND content key, server is blind
v2:  Account is identity, master password derives content key,
     server is zero-knowledge for content but sees identity +
     usage metadata
```

Server sees: who you are (email / OIDC subject), device count +
names + last-seen, storage + request volume, envelope sizes.

Server does NOT see: clipboard content, anything inside envelopes.

Master password → Argon2id (locally) → master key → wraps
per-workspace content key. Server only ever stores the wrapped
(ciphertext) form. Forgotten master password = lost vault (with an
optional printable BIP39 recovery phrase as the escape hatch).

## Server-side schema (new)

| Table | Holds |
|---|---|
| `users` | id, email, server-side auth-token hash (NOT master password), created_at, plan_id, oauth provider/subject |
| `workspaces` | id, owner_user_id, encrypted_workspace_key (wrapped under master key), device_cap, byte_cap |
| `workspace_members` | workspace_id, user_id, role (owner/admin/member) |
| `devices` | id, workspace_id, user_id, device_pubkey, name, platform, last_seen, status |
| `plans` | id, name, device_cap, member_cap, byte_cap, request_cap, price_cents |
| `rate_limits` | user_id, workspace_id, window_start, request_count, byte_count |
| `oauth_providers` | id, kind (google/github/azure/okta), workspace_id, config |

## Endpoint surface (new + changed)

```
# Auth
POST   /v2/auth/register            email + master_password_hash + Argon2id params
POST   /v2/auth/login               → bearer token
POST   /v2/auth/refresh             → rotated bearer token
POST   /v2/auth/oauth/<prov>/start
GET    /v2/auth/oauth/<prov>/callback

# Account
GET    /v2/me                       profile, plan, usage
POST   /v2/me/master-password       rotate (re-wraps all workspace keys)
DELETE /v2/me                       tombstone account + data

# Devices
GET    /v2/workspaces/<ws>/devices
POST   /v2/workspaces/<ws>/devices          add via pairing token
DELETE /v2/workspaces/<ws>/devices/<dev>    revoke (admin-only on team plans)

# Workspaces
POST   /v2/workspaces                       create
GET    /v2/workspaces                       list mine
POST   /v2/workspaces/<ws>/invite           one-time pairing token (Diceware-encoded)
POST   /v2/workspaces/<ws>/share            invite another user (Team+)
DELETE /v2/workspaces/<ws>/share/<user>

# Org / SSO (Enterprise)
POST   /v2/orgs
POST   /v2/orgs/<id>/scim/v2/Users          SCIM provisioning
POST   /v2/orgs/<id>/saml/sso
GET    /v2/orgs/<id>/audit

# Envelopes — same shape as v1, now nested + bearer-auth'd
POST   /v2/workspaces/<ws>/envelopes
GET    /v2/workspaces/<ws>/envelopes?since=&limit=
GET    /v2/workspaces/<ws>/envelopes/<id>
DELETE /v2/workspaces/<ws>/envelopes/<id>
GET    /v2/workspaces/<ws>/info
GET    /v2/workspaces/<ws>/sync              (WebSocket)
```

Auth header changes from PSK-derived HMAC to
`Authorization: Bearer <jwt>` + `X-Cpdb-Device` (still needed for
own-fanout suppression) + `X-Cpdb-Protocol: 2`. JWT carries
user_id + workspace_id + device_id + plan + expiry.

## What survives unchanged from v1

- Envelope frame (XChaCha20-Poly1305 over MessagePack plaintext)
- Per-envelope 5 MB cap
- LRU eviction (now per-tier byte caps)
- WebSocket realtime fan-out (signaling only, never bytes)
- Diceware — repurposed from "sole auth" to "one-time device
  pairing token format" (6 words, 5-min validity, scoped to
  user_id + target workspace_id)

## Pairing flow (v2)

```
First account:   Sign in / register (email + master password)
                  → master key derived locally (Argon2id)
                  → workspace key generated, wrapped under master key
                  → wrapped key uploaded

Add device:       Existing device: Settings → "Add another device"
                  → server returns one-time pairing_code as 6 Diceware words
                  New device: sign in (email + master password)
                  → enter 6 words → server validates (one-time, scoped),
                    enforces device_cap, registers device, delivers
                    encrypted_workspace_key → decrypt locally
```

Two-factor by construction: device count enforced server-side,
master password verified locally. A leaked pairing code alone
grants nothing without the master password.

## Tier defaults (proposed, not final)

| Plan | Devices | Members | Bytes | Req/hr | Pairing tokens/day |
|---|---|---|---|---|---|
| Free | 2 | 1 | 100 MB | 1,000 | 5 |
| Plus ($3/mo) | unlimited | 1 | 1 GB | 10,000 | 50 |
| Team ($5/user/mo) | unlimited | 25 | 5 GB/member | 100,000 | unlimited |
| Enterprise | unlimited | unlimited | negotiated | negotiated | unlimited + audit |

Free tier deliberately tight so "share images with my friend
group" doesn't fly.

## OAuth / enterprise key-escrow split

Personal accounts: master password is the only key, no admin
recovery (optional BIP39 recovery phrase).

Enterprise accounts: admin-controlled key escrow (HSM-backed key
the IT admin controls) — lower friction, and required for
legal-hold / departed-employee decrypt that big-co compliance
expects. Mirrors 1Password's personal-vs-business split.

OIDC complicates the master-password requirement; three known
paths (Bitwarden dual-auth, Standard Notes admin-managed,
deterministic key from OIDC subject). Decision deferred to phase D.

## Phasing

- **Phase A** (DONE): blind-PSK Worker scaffold + v1 protocol doc.
  Wrong long-term architecture; kept as code reference. **Paused.**
- **Phase B** (3-6 wk): personal accounts. Email + master password,
  Argon2id vault-key wrapping, single-user workspaces, Diceware
  device pairing, Free + Plus tiers, Stripe, minimal web sign-up +
  dashboard. Mac "Sync" pane gains substrate selector (iCloud
  legacy vs cpdb account).
- **Phase C** (4-8 wk): Team plan. Multi-user workspaces, roles,
  per-member byte budgets, audit log, admin web console.
- **Phase D** (2-3 mo): Enterprise. OIDC (Google/Azure/Okta),
  SCIM, SAML SSO, admin key escrow, audit export, data residency.

iCloud stays opt-in for Apple users and is insulated from this
churn until phase D, then deprecated on the Apple side.

## Open decisions (need product call before phase B starts)

1. **Argon2id params.** Default to Bitwarden-current
   (`iterations=3, memory=64MB, parallelism=4`) — well-tested,
   acceptable on phone hardware. Revisit if too slow on old iOS.
2. **JWT signing.** Start HS256 (symmetric, simplest); migrate to
   EdDSA if federated auth needs it.
3. **Token lifetime.** Stripe-style: short access (~15 min) + long
   refresh (~30 day) with refresh-rotation on every use.
4. **Recovery.** Optional printable 24-word BIP39 recovery phrase,
   no waiting period. (Bitwarden's delegated emergency-access is a
   later nicety.)
5. **OIDC scope for phase D.** Consumer-enterprise (Google +
   GitHub) ships much faster than real-enterprise (Azure AD +
   Okta). Probably stage them.

## Cost note

The v1 cost model (100 MB/user, ~$5/mo for hundreds of users on
Cloudflare) still roughly holds for storage. Phase B adds the
account/auth surface (D1 for the relational tables, negligible
cost at this scale) and Stripe (2.9% + 30¢/txn — only matters once
there's revenue). Enterprise (phase D) likely needs a real
relational DB + dedicated infra; revisit cost model then.
