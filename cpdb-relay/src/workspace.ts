/// <reference types="@cloudflare/workers-types" />
//
// Per-workspace Durable Object. Owns:
//   - Envelope index (DO storage, keyed by stored_at-suffixed)
//   - Replay-protection LRU (in-memory only; safe to lose on
//     migration — clients retry the request)
//   - WebSocket fan-out for online devices
//   - LRU byte-cap eviction
//
// R2 holds the encrypted envelope bytes; this DO holds metadata.
//
// All requests for /v1/<ws>/* land here via Worker forwarding.
// Auth happens at the start of each fetch() call.

import {
    BYTE_CAP,
    PER_ENVELOPE_MAX,
    REPLAY_WINDOW_SECONDS,
    REPLAY_BUCKET_SECONDS,
    isValidEnvelopeId,
    parseRequestHeaders,
    base32Decode,
    type RequestHeaders,
} from "./common";

interface Env {
    ENVELOPES: R2Bucket;
}

interface EnvelopeMeta {
    envelope_id: string; // base32, 26 chars
    size: number;
    stored_at: number; // epoch seconds (float for ms precision)
}

interface ReplayEntry {
    timestamp_ms: number;
    hmac_prefix: string; // hex of first 8 bytes of HMAC
}

export class Workspace implements DurableObject {
    private readonly state: DurableObjectState;
    private readonly env: Env;
    /** Connected device sockets (device_id → WebSocket). */
    private sockets: Map<string, WebSocket> = new Map();
    /** Recent (timestamp_ms, hmac_prefix) tuples for replay
     *  rejection. Pruned on every check. In-memory only. */
    private replayLRU: ReplayEntry[] = [];

    constructor(state: DurableObjectState, env: Env) {
        this.state = state;
        this.env = env;
    }

    async fetch(request: Request): Promise<Response> {
        const url = new URL(request.url);
        const parts = url.pathname.split("/").filter(Boolean);
        // parts: ["v1", "<workspace_id>", "<resource>", ...]
        const workspaceId = parts[1];
        const resource = parts[2] ?? "";

        // WebSocket upgrade: handle BEFORE auth so we can return a
        // 426 cleanly if the client didn't actually request upgrade.
        if (resource === "sync") {
            return this.handleSyncUpgrade(request, workspaceId);
        }

        // All other endpoints require auth + replay-protection. We
        // do auth in the DO (not the Worker) so the replay LRU is
        // strongly consistent within a workspace.
        const auth = await this.authenticate(request, workspaceId);
        if (!auth.ok) return auth.response;

        // Dispatch.
        if (resource === "envelopes" && parts.length === 3) {
            if (request.method === "POST") {
                return this.handleEnvelopePost(request, workspaceId);
            }
            if (request.method === "GET") {
                return this.handleEnvelopeList(request, workspaceId);
            }
        }
        if (resource === "envelopes" && parts.length === 4) {
            const envelopeId = parts[3];
            if (!isValidEnvelopeId(envelopeId)) {
                return jsonError(400, "invalid envelope_id");
            }
            if (request.method === "GET") {
                return this.handleEnvelopeFetch(envelopeId, workspaceId);
            }
            if (request.method === "DELETE") {
                return this.handleEnvelopeDelete(envelopeId, workspaceId, auth.deviceId);
            }
        }
        if (resource === "info" && request.method === "GET") {
            return this.handleInfo();
        }

        return jsonError(404, "no such endpoint");
    }

    // MARK: - Auth + replay protection

    private async authenticate(
        request: Request,
        _workspaceId: string,
    ): Promise<{ ok: true; deviceId: string; headers: RequestHeaders } | { ok: false; response: Response }> {
        const parsed = parseRequestHeaders(request);
        if (!parsed) {
            return { ok: false, response: jsonError(400, "missing or malformed auth headers") };
        }
        const nowMs = Date.now();
        const driftMs = Math.abs(nowMs - parsed.timestamp_ms);
        if (driftMs > REPLAY_WINDOW_SECONDS * 1000) {
            return { ok: false, response: jsonError(401, "timestamp out of window") };
        }
        // Replay check: same (timestamp_ms, hmac_prefix) seen recently?
        this.pruneReplayLRU(nowMs);
        const hmacPrefix = parsed.auth_hex.slice(0, 16);
        const dup = this.replayLRU.find(
            r => r.timestamp_ms === parsed.timestamp_ms && r.hmac_prefix === hmacPrefix,
        );
        if (dup) {
            return { ok: false, response: jsonError(409, "replay") };
        }
        // TODO: actual HMAC verification needs the auth_key, which
        // is itself derived from the PSK. The DO doesn't have the
        // PSK. Two options:
        //   (a) The relay verifies a "proof of PSK knowledge"
        //       challenge-response per session, then trusts the
        //       request stream within that session.
        //   (b) Each request carries the workspace_id (which IS
        //       derived from the PSK), and we trust that anyone who
        //       can produce a valid workspace_id holds the PSK.
        //
        // (b) is much simpler but weaker — a workspace_id leak
        // alone (say in a screenshot) lets the leaker write to
        // your workspace. (a) is right for v1.1; v1.0 we'll just
        // verify the workspace_id is well-formed and the HMAC was
        // produced over the canonical request, with the auth_key
        // delivered out-of-band on first contact.
        //
        // For the protocol stub we record the seen replay entry
        // so the path is exercised end-to-end; full HMAC verify
        // lands before any client cuts over.
        this.replayLRU.push({ timestamp_ms: parsed.timestamp_ms, hmac_prefix: hmacPrefix });
        return { ok: true, deviceId: parsed.device_id, headers: parsed };
    }

    private pruneReplayLRU(nowMs: number): void {
        const cutoff = nowMs - REPLAY_BUCKET_SECONDS * 1000;
        this.replayLRU = this.replayLRU.filter(r => r.timestamp_ms >= cutoff);
    }

    // MARK: - POST /v1/<ws>/envelopes

    private async handleEnvelopePost(request: Request, workspaceId: string): Promise<Response> {
        const body = await request.arrayBuffer();
        if (body.byteLength === 0) {
            return jsonError(400, "empty body");
        }
        if (body.byteLength > PER_ENVELOPE_MAX) {
            return jsonError(413, "envelope exceeds per-envelope max", {
                limit: PER_ENVELOPE_MAX,
                actual: body.byteLength,
            });
        }
        // Envelope ID derivation from body: HMAC(workspace_id, body)
        // truncated to 16 bytes, base32-encoded. The client computes
        // the same value from the same key + body, so this lets us
        // sanity-check that the body matches what the client thought
        // it was uploading.
        //
        // TODO: actually compute. For the stub we trust the client.
        const envelopeId = ""; // placeholder

        // Persist to R2 first; if that fails we don't update the index.
        const r2Key = `${workspaceId}/${envelopeId}`;
        await this.env.ENVELOPES.put(r2Key, body);

        // Update the index, evicting oldest if we're over cap.
        const storedAt = Date.now() / 1000;
        const meta: EnvelopeMeta = {
            envelope_id: envelopeId,
            size: body.byteLength,
            stored_at: storedAt,
        };
        await this.indexUpsert(meta);
        await this.evictIfOverCap(workspaceId);

        // Notify online devices.
        this.broadcast({
            type: "new",
            envelope_id: envelopeId,
            size: body.byteLength,
            stored_at: storedAt,
        });

        return jsonOk({ envelope_id: envelopeId, size: body.byteLength, stored_at: storedAt }, 201);
    }

    // MARK: - GET /v1/<ws>/envelopes

    private async handleEnvelopeList(request: Request, _workspaceId: string): Promise<Response> {
        const url = new URL(request.url);
        const since = parseFloat(url.searchParams.get("since") ?? "0");
        const limit = Math.min(500, parseInt(url.searchParams.get("limit") ?? "100", 10));
        const all = await this.indexAll();
        const filtered = all
            .filter(m => m.stored_at > since)
            .sort((a, b) => a.stored_at - b.stored_at)
            .slice(0, limit + 1);
        const more = filtered.length > limit;
        const page = filtered.slice(0, limit);
        const nextSince = page.length > 0 ? page[page.length - 1].stored_at : since;
        return jsonOk({ envelopes: page, next_since: nextSince, more });
    }

    // MARK: - GET /v1/<ws>/envelopes/<id>

    private async handleEnvelopeFetch(envelopeId: string, workspaceId: string): Promise<Response> {
        const r2Key = `${workspaceId}/${envelopeId}`;
        const obj = await this.env.ENVELOPES.get(r2Key);
        if (!obj) {
            return jsonError(404, "envelope unknown or evicted");
        }
        return new Response(obj.body, {
            status: 200,
            headers: {
                "content-type": "application/octet-stream",
                "content-length": String(obj.size),
            },
        });
    }

    // MARK: - DELETE /v1/<ws>/envelopes/<id>

    private async handleEnvelopeDelete(
        envelopeId: string,
        workspaceId: string,
        _deviceId: string,
    ): Promise<Response> {
        const r2Key = `${workspaceId}/${envelopeId}`;
        await this.env.ENVELOPES.delete(r2Key);
        await this.indexDelete(envelopeId);
        this.broadcast({
            type: "delete",
            envelope_id: envelopeId,
            stored_at: Date.now() / 1000,
        });
        return new Response(null, { status: 204 });
    }

    // MARK: - GET /v1/<ws>/info

    private async handleInfo(): Promise<Response> {
        const all = await this.indexAll();
        const totalBytes = all.reduce((s, m) => s + m.size, 0);
        const oldest = all.length > 0 ? Math.min(...all.map(m => m.stored_at)) : null;
        const latest = all.length > 0 ? Math.max(...all.map(m => m.stored_at)) : null;
        return jsonOk({
            envelope_count: all.length,
            total_bytes: totalBytes,
            byte_cap: BYTE_CAP,
            oldest_stored_at: oldest,
            latest_stored_at: latest,
            online_devices: this.sockets.size,
            protocol: 1,
        });
    }

    // MARK: - WebSocket fan-out

    private async handleSyncUpgrade(request: Request, _workspaceId: string): Promise<Response> {
        if (request.headers.get("upgrade") !== "websocket") {
            return jsonError(426, "websocket upgrade required");
        }
        const auth = await this.authenticate(request, _workspaceId);
        if (!auth.ok) return auth.response;

        const pair = new WebSocketPair();
        const [client, server] = Object.values(pair) as [WebSocket, WebSocket];
        server.accept();
        const deviceId = auth.deviceId;
        this.sockets.set(deviceId, server);
        server.addEventListener("close", () => this.sockets.delete(deviceId));
        server.addEventListener("error", () => this.sockets.delete(deviceId));
        server.addEventListener("message", evt => {
            // Ignore client messages other than pongs. Future: client
            // could send "subscribe filter" or similar, but v1 has
            // no such surface.
            try {
                const msg = JSON.parse(typeof evt.data === "string" ? evt.data : "");
                if (msg.type !== "pong") {
                    // No-op for now.
                }
            } catch {
                // Ignore garbage.
            }
        });
        return new Response(null, { status: 101, webSocket: client });
    }

    private broadcast(message: object): void {
        const payload = JSON.stringify(message);
        for (const ws of this.sockets.values()) {
            try {
                ws.send(payload);
            } catch {
                // socket gone — close handler will cleanup.
            }
        }
    }

    // MARK: - Index storage helpers
    //
    // DO storage is keyed; we use `idx:<stored_at_ms>:<envelope_id>`
    // so list scans are naturally time-sorted. envelope_id appears
    // in the key so two captures within the same millisecond don't
    // collide.

    private async indexUpsert(meta: EnvelopeMeta): Promise<void> {
        const key = `idx:${Math.round(meta.stored_at * 1000)}:${meta.envelope_id}`;
        await this.state.storage.put(key, meta);
    }

    private async indexAll(): Promise<EnvelopeMeta[]> {
        const map = await this.state.storage.list<EnvelopeMeta>({ prefix: "idx:" });
        return Array.from(map.values());
    }

    private async indexDelete(envelopeId: string): Promise<void> {
        const map = await this.state.storage.list<EnvelopeMeta>({ prefix: "idx:" });
        for (const [key, meta] of map.entries()) {
            if (meta.envelope_id === envelopeId) {
                await this.state.storage.delete(key);
                break;
            }
        }
    }

    // MARK: - LRU eviction

    private async evictIfOverCap(workspaceId: string): Promise<void> {
        let entries = await this.indexAll();
        let total = entries.reduce((s, m) => s + m.size, 0);
        if (total <= BYTE_CAP) return;
        // Sort oldest-first.
        entries.sort((a, b) => a.stored_at - b.stored_at);
        for (const meta of entries) {
            if (total <= BYTE_CAP) break;
            await this.env.ENVELOPES.delete(`${workspaceId}/${meta.envelope_id}`);
            await this.indexDelete(meta.envelope_id);
            this.broadcast({
                type: "evicted",
                envelope_id: meta.envelope_id,
                stored_at: meta.stored_at,
            });
            total -= meta.size;
        }
    }
}

// MARK: - Local helpers

function jsonOk(body: object, status: number = 200): Response {
    return new Response(JSON.stringify(body), {
        status,
        headers: { "content-type": "application/json" },
    });
}

function jsonError(status: number, message: string, extra?: object): Response {
    return new Response(
        JSON.stringify({ error: message, ...extra }),
        {
            status,
            headers: { "content-type": "application/json" },
        },
    );
}

// `base32Decode` is exported from common but unused in this stub —
// keep the import once the auth path computes envelope_id from
// hmac(body) so we avoid the lint error.
void base32Decode;
