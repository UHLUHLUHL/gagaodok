import { ApiError } from "../contracts/error";

export type RateLimitScope =
  | "enrollment" | "recovery" | "pairing_session" | "pairing_claim" | "pairing_approve"
  | "pairing_redeem" | "sync_write" | "sync_read" | "attachment";

const POLICIES: Record<RateLimitScope, { windowMs: number; maximum: number }> = {
  enrollment: { windowMs: 3_600_000, maximum: 5 },
  recovery: { windowMs: 3_600_000, maximum: 5 },
  pairing_session: { windowMs: 300_000, maximum: 30 },
  pairing_claim: { windowMs: 300_000, maximum: 30 },
  pairing_approve: { windowMs: 300_000, maximum: 30 },
  pairing_redeem: { windowMs: 300_000, maximum: 10 },
  sync_write: { windowMs: 60_000, maximum: 600 },
  sync_read: { windowMs: 60_000, maximum: 300 },
  attachment: { windowMs: 3_600_000, maximum: 120 },
};

function hex(bytes: Uint8Array): string {
  return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function subjectHash(request: Request, macKey: string): Promise<string> {
  if (new TextEncoder().encode(macKey).length < 32) throw new ApiError("INTERNAL_ERROR");
  const address = request.headers.get("CF-Connecting-IP") ?? "missing-address";
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(macKey), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  return hex(new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(address))));
}

/** Atomic fixed-window limiter. No address, token, UUID or body is persisted. */
export async function assertRateLimit(
  request: Request,
  db: D1Database,
  macKey: string,
  scope: RateLimitScope,
  now = Date.now(),
): Promise<void> {
  const policy = POLICIES[scope];
  const windowStart = Math.floor(now / policy.windowMs) * policy.windowMs;
  const hash = await subjectHash(request, macKey);
  try {
    const rows = await db.batch([
      db.prepare("DELETE FROM rate_limit_bucket WHERE window_start < ?").bind(now - 86_400_000),
      db.prepare(
        `INSERT INTO rate_limit_bucket (scope, subject_hash, window_start, request_count)
         VALUES (?, ?, ?, 1)
         ON CONFLICT (scope, subject_hash, window_start) DO UPDATE
           SET request_count = request_count + 1
         WHERE request_count < ?
         RETURNING request_count`,
      ).bind(scope, hash, windowStart, policy.maximum),
    ]);
    if (rows[1]?.results.length !== 1) throw new ApiError("RATE_LIMITED");
  } catch (error) {
    if (error instanceof ApiError) throw error;
    throw new ApiError("STORAGE_UNAVAILABLE", { retryable: true });
  }
}
