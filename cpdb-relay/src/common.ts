/// <reference types="@cloudflare/workers-types" />
//
// Shared constants + helpers for the cpdb-relay Worker. Each
// constant matches a corresponding section of
// docs/relay-protocol.md — keep them in sync.

/** Per-envelope size limit. See § Eviction rules. */
export const PER_ENVELOPE_MAX = 5 * 1024 * 1024;

/** Per-workspace soft byte cap. LRU evicts oldest first. */
export const BYTE_CAP = 100 * 1024 * 1024;

/** Allowed timestamp drift between client and server, seconds. */
export const REPLAY_WINDOW_SECONDS = 300;

/** How long the replay-protection LRU keeps entries. Slightly
 *  larger than the window so an at-edge replay still gets
 *  rejected. */
export const REPLAY_BUCKET_SECONDS = 600;

/** Header field names used in the wire protocol. Keep these
 *  capitalisation-insensitive with what clients send; we
 *  read via `Headers.get(...)` which lowercases internally. */
export const HEADER_WORKSPACE = "x-cpdb-workspace";
export const HEADER_DEVICE = "x-cpdb-device";
export const HEADER_TIMESTAMP = "x-cpdb-timestamp";
export const HEADER_AUTH = "x-cpdb-auth";
export const HEADER_PROTOCOL = "x-cpdb-protocol";

export interface RequestHeaders {
    workspace_id: string;
    device_id: string;
    timestamp_ms: number;
    auth_hex: string;
}

/** Parse + validate the v1 protocol headers. Returns null if any
 *  required field is missing or malformed. Doesn't verify the
 *  HMAC — the DO does that against the auth_key. */
export function parseRequestHeaders(request: Request): RequestHeaders | null {
    const ws = request.headers.get(HEADER_WORKSPACE);
    const dev = request.headers.get(HEADER_DEVICE);
    const ts = request.headers.get(HEADER_TIMESTAMP);
    const auth = request.headers.get(HEADER_AUTH);
    const proto = request.headers.get(HEADER_PROTOCOL);
    if (proto !== "1") return null;
    if (!ws || !dev || !ts || !auth) return null;
    const tsMs = parseInt(ts, 10);
    if (Number.isNaN(tsMs) || tsMs <= 0) return null;
    if (!isValidWorkspaceId(ws)) return null;
    if (!isValidDeviceId(dev)) return null;
    if (auth.length !== 64 || !/^[0-9a-f]+$/i.test(auth)) return null;
    return {
        workspace_id: ws,
        device_id: dev,
        timestamp_ms: tsMs,
        auth_hex: auth.toLowerCase(),
    };
}

/** Workspace IDs: 16 random bytes → base32 (a-z2-7) → 26 chars. */
export function isValidWorkspaceId(id: string): boolean {
    return id.length === 26 && /^[a-z2-7]+$/.test(id);
}

/** Device IDs: 16 random bytes → base32 → 26 chars. Same shape. */
export function isValidDeviceId(id: string): boolean {
    return isValidWorkspaceId(id);
}

/** Envelope IDs: same shape — HMAC truncated to 16 bytes. */
export function isValidEnvelopeId(id: string): boolean {
    return isValidWorkspaceId(id);
}

/** RFC 4648 base32 (lowercase, no padding). The Worker only
 *  needs to *validate* base32 strings via the regex above; full
 *  decode is here for future use (envelope_id verification).
 *
 *  Returns null on malformed input. */
export function base32Decode(input: string): Uint8Array | null {
    const lower = input.toLowerCase();
    if (!/^[a-z2-7]+$/.test(lower)) return null;
    const alphabet = "abcdefghijklmnopqrstuvwxyz234567";
    let bits = 0;
    let value = 0;
    const out: number[] = [];
    for (const ch of lower) {
        const i = alphabet.indexOf(ch);
        if (i < 0) return null;
        value = (value << 5) | i;
        bits += 5;
        if (bits >= 8) {
            bits -= 8;
            out.push((value >>> bits) & 0xff);
        }
    }
    return new Uint8Array(out);
}
