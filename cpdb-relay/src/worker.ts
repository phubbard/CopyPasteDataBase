/// <reference types="@cloudflare/workers-types" />
//
// cpdb-relay Worker entrypoint. Routes /v1/<workspace_id>/<...>
// requests to the per-workspace Durable Object. Performs zero
// auth or business logic — all that lives in the DO so the
// per-workspace replay-protection state stays consistent.
//
// See ../docs/relay-protocol.md for the full wire format.

export { Workspace } from "./workspace";

interface Env {
    WORKSPACE: DurableObjectNamespace;
    ENVELOPES: R2Bucket;
}

const PROTOCOL_VERSION = 1;

export default {
    async fetch(request: Request, env: Env): Promise<Response> {
        const url = new URL(request.url);
        const parts = url.pathname.split("/").filter(Boolean);

        // /v1/<workspace_id>/<rest...>
        if (parts.length < 2 || parts[0] !== `v${PROTOCOL_VERSION}`) {
            return jsonError(400, "unsupported protocol", {
                supported: [PROTOCOL_VERSION],
            });
        }

        const workspaceId = parts[1];
        if (!isValidWorkspaceId(workspaceId)) {
            return jsonError(400, "invalid workspace_id");
        }

        // Forward everything past /v1/<ws>/ to the DO. We pass the
        // original request through so the DO can re-derive auth +
        // body without us having to buffer.
        const id = env.WORKSPACE.idFromName(workspaceId);
        const stub = env.WORKSPACE.get(id);
        return stub.fetch(request);
    },
};

/**
 * Workspace IDs are base32-encoded 16-byte HMAC truncations
 * (see relay-protocol.md § Derived keys). Base32 alphabet is
 * `a-z2-7` and the encoded length is exactly 26 chars (16 bytes
 * → ceil(16*8/5) = 26 chars, no padding).
 */
function isValidWorkspaceId(id: string): boolean {
    return id.length === 26 && /^[a-z2-7]+$/.test(id);
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
