import { applyD1Migrations, env } from "cloudflare:test";
import { exports } from "cloudflare:workers";
import type { D1Migration } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";

declare global {
  namespace Cloudflare {
    interface Env {
      DB: D1Database;
      ATTACHMENTS: R2Bucket;
      CURSOR_MAC_KEY: string;
      RATE_LIMIT_MAC_KEY: string;
      TEST_MIGRATIONS: D1Migration[];
    }
  }
}

const db = env.DB;
const worker = (exports as { default: ExportedHandler }).default;
type WorkerRequest = Parameters<NonNullable<ExportedHandler["fetch"]>>[0];

const ACCOUNT = "A0000000-0000-4000-8000-00000000000A";
const OTHER_ACCOUNT = "A0000000-0000-4000-8000-00000000000B";
const MAC_DEVICE = "B0000000-0000-4000-8000-000000000001";
const REVOKED_DEVICE = "B0000000-0000-4000-8000-000000000003";
const OTHER_DEVICE = "B0000000-0000-4000-8000-000000000004";
const AT = "2026-08-31T00:00:00Z";
const PATH = "/v1/recovery/rotate";
const OBJECT_V1 = "recovery/0AAAAAAA-0000-4000-8000-00000000000A";
const OBJECT_OTHER = "recovery/0AAAAAAA-0000-4000-8000-00000000000B";

function tokenBytes(seed: number): Uint8Array {
  return Uint8Array.from({ length: 32 }, (_, index) => (seed + index) & 0xff);
}

function base64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function base64Url(bytes: Uint8Array): string {
  return base64(bytes).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes as BufferSource);
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

/** 32 raw bytes, the shape both `recovery_lookup` and the verifier travel in. */
function binary32(seed: number): string {
  return base64(tokenBytes(seed));
}

function hex32(seed: number): string {
  return [...tokenBytes(seed)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

/** A v1 field envelope — the wrapped master key is carried as one. */
function envelope(seed: number): string {
  const bytes = new Uint8Array(48);
  bytes.set([1, 1, 0, 0, 0, 1]);
  for (let index = 6; index < bytes.length; index += 1) bytes[index] = (seed + index) & 0xff;
  return base64(bytes);
}

const MAC_TOKEN = `gdt1_${base64Url(tokenBytes(1))}`;
const REVOKED_TOKEN = `gdt1_${base64Url(tokenBytes(65))}`;
const OTHER_TOKEN = `gdt1_${base64Url(tokenBytes(97))}`;

const NEXT = {
  protocol_version: 1,
  recovery_version: 2,
  recovery_lookup: binary32(200),
  recovery_auth_verifier: binary32(210),
  wrapped_master_key: envelope(220),
};

async function run(sql: string, ...values: (string | number | null)[]): Promise<void> {
  await db.prepare(sql).bind(...values).run();
}

async function call(
  body: unknown = NEXT,
  token: string | null = MAC_TOKEN,
): Promise<Response> {
  const headers = new Headers();
  if (token !== null) headers.set("Authorization", `Device ${token}`);
  const request = new Request(`https://example.test${PATH}`, {
    method: "POST",
    headers,
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
  const response = await worker.fetch?.(request as unknown as WorkerRequest, env as never, {} as never);
  if (response === undefined) throw new Error("worker did not return a response");
  return response;
}

interface RecoveryRow {
  recovery_version: number;
  recovery_lookup_b64: string;
  recovery_auth_verifier: string;
  wrapped_master_key_enc: string;
  r2_object_key: string;
  key_generation: number;
  revoked_at: string | null;
}

async function records(accountId = ACCOUNT): Promise<RecoveryRow[]> {
  const result = await db.prepare(
    `SELECT recovery_version, recovery_lookup_b64, recovery_auth_verifier,
            wrapped_master_key_enc, r2_object_key, key_generation, revoked_at
       FROM recovery_record WHERE account_id = ? ORDER BY recovery_version ASC`,
  ).bind(accountId).all<RecoveryRow>();
  return result.results;
}

beforeAll(async () => {
  await applyD1Migrations(db, env.TEST_MIGRATIONS);
});

beforeEach(async () => {
  await db.prepare("DELETE FROM rate_limit_bucket").run();
  await db.prepare("DELETE FROM recovery_record").run();
  await db.prepare("DELETE FROM device").run();
  await db.prepare("DELETE FROM account").run();
  await run("INSERT INTO account (account_id, created_at) VALUES (?, ?)", ACCOUNT, AT);
  await run("INSERT INTO account (account_id, created_at) VALUES (?, ?)", OTHER_ACCOUNT, AT);

  const devices = [
    [ACCOUNT, MAC_DEVICE, "MAC_SPACE", "macos", null, 1],
    [ACCOUNT, REVOKED_DEVICE, "TABLET_SPACE", "android_tablet", AT, 65],
    [OTHER_ACCOUNT, OTHER_DEVICE, "MAC_SPACE", "macos", null, 97],
  ] as const;
  for (const [account, device, space, platform, revokedAt, seed] of devices) {
    await run(
      `INSERT INTO device
         (account_id, device_id, space_id, platform, display_name_enc, linked_at,
          revoked_at, key_generation, token_hash)
       VALUES (?, ?, ?, ?, NULL, ?, ?, 1, ?)`,
      account, device, space, platform, AT, revokedAt, await sha256Hex(tokenBytes(seed)),
    );
  }

  for (const [account, objectKey, seed] of [
    [ACCOUNT, OBJECT_V1, 100],
    [OTHER_ACCOUNT, OBJECT_OTHER, 150],
  ] as const) {
    await run(
      `INSERT INTO recovery_record
         (account_id, recovery_version, recovery_lookup_b64, recovery_auth_verifier,
          wrapped_master_key_enc, r2_object_key, key_generation, created_at, revoked_at)
       VALUES (?, 1, ?, ?, ?, ?, 1, ?, NULL)`,
      account, binary32(seed), hex32(seed + 1), envelope(seed + 2), objectKey, AT,
    );
  }
});

describe("POST /v1/recovery/rotate", () => {
  it("replaces the active record atomically and keeps the master key generation", async () => {
    const response = await call();
    expect(response.status).toBe(201);
    expect(await response.json()).toEqual({
      protocol_version: 1,
      request_id: expect.stringMatching(/^[0-9A-F-]{36}$/),
      result: { status: "created", recovery_version: 2, key_generation: 1 },
    });

    const rows = await records();
    expect(rows).toHaveLength(2);
    expect(rows[0]?.recovery_version).toBe(1);
    expect(rows[0]?.revoked_at).not.toBeNull();
    expect(rows[1]).toMatchObject({
      recovery_version: 2,
      recovery_lookup_b64: NEXT.recovery_lookup,
      recovery_auth_verifier: hex32(210),
      wrapped_master_key_enc: NEXT.wrapped_master_key,
      // The master key itself did not change, so neither does its generation.
      key_generation: 1,
      revoked_at: null,
    });
    // The old record's R2 object is left in place: an in-flight redeem of the
    // old phrase must fail on the revoked row, not on a missing object.
    expect(rows[1]?.r2_object_key).not.toBe(OBJECT_V1);
    expect(await env.ATTACHMENTS.get(rows[1]!.r2_object_key)).not.toBeNull();
  });

  it("treats an identical retry as a replay rather than a lockout", async () => {
    expect((await call()).status).toBe(201);
    const replay = await call();
    expect(replay.status).toBe(200);
    const body = await replay.json() as { result: { status: string; recovery_version: number } };
    expect(body.result).toEqual({ status: "replayed", recovery_version: 2, key_generation: 1 });
    expect(await records()).toHaveLength(2);
  });

  it("refuses a stale version without saying which one is current", async () => {
    expect((await call()).status).toBe(201);
    const stale = await call();
    expect(stale.status).toBe(200);

    // Version 2 is now taken by a different payload: not a replay, a conflict.
    const collided = await call({ ...NEXT, recovery_lookup: binary32(240) });
    expect(collided.status).toBe(409);
    expect(await collided.json()).toEqual({
      protocol_version: 1,
      request_id: expect.stringMatching(/^[0-9A-F-]{36}$/),
      error: { code: "RECOVERY_CONFLICT", retryable: false },
    });
    expect(await records()).toHaveLength(2);
  });

  it("refuses a version that skips ahead of the active record", async () => {
    const ahead = await call({ ...NEXT, recovery_version: 3 });
    expect(ahead.status).toBe(409);
    expect(await records()).toHaveLength(1);
  });

  it("refuses a revoked device and an unauthenticated caller", async () => {
    expect((await call(NEXT, REVOKED_TOKEN)).status).toBe(403);
    expect((await call(NEXT, null)).status).toBe(401);
    expect(await records()).toHaveLength(1);
  });

  it("rotates only the authenticated account", async () => {
    expect((await call(NEXT, OTHER_TOKEN)).status).toBe(201);
    // The caller's own account moved; the unrelated account did not.
    expect(await records(OTHER_ACCOUNT)).toHaveLength(2);
    const untouched = await records(ACCOUNT);
    expect(untouched).toHaveLength(1);
    expect(untouched[0]?.revoked_at).toBeNull();
  });

  it("lets exactly one of two concurrent rotations win", async () => {
    const [first, second] = await Promise.all([
      call(),
      call({ ...NEXT, recovery_lookup: binary32(250), wrapped_master_key: envelope(260) }),
    ]);
    const statuses = [first.status, second.status].sort();
    expect(statuses).toEqual([201, 409]);

    const rows = await records();
    expect(rows).toHaveLength(2);
    expect(rows.filter((row) => row.revoked_at === null)).toHaveLength(1);
  });

  it("rolls back and keeps the old record active when the insert cannot land", async () => {
    // The other account already owns this lookup, and recovery_lookup_b64 is
    // globally unique — the insert fails and the batch takes the revoke with it.
    const collision = await call({ ...NEXT, recovery_lookup: binary32(150) });
    expect(collision.status).toBe(409);

    const rows = await records();
    expect(rows).toHaveLength(1);
    expect(rows[0]?.recovery_version).toBe(1);
    expect(rows[0]?.revoked_at).toBeNull();
  });

  it("never returns the lookup, wrapped key, object key or verifier", async () => {
    const text = await (await call()).text();
    for (const secret of [
      NEXT.recovery_lookup, NEXT.recovery_auth_verifier, NEXT.wrapped_master_key,
      hex32(210), OBJECT_V1, MAC_TOKEN, "recovery/",
    ]) {
      expect(text).not.toContain(secret);
    }
  });

  // The recovery scope allows five attempts an hour, so the malformed bodies are
  // split across two cases rather than tripping the limiter mid-assertion.
  async function expectAllRejected(bodies: unknown[]): Promise<void> {
    for (const body of bodies) {
      expect((await call(body)).status).toBe(400);
    }
    const rows = await records();
    expect(rows).toHaveLength(1);
    expect(rows[0]?.revoked_at).toBeNull();
  }

  it("refuses a malformed envelope before touching storage", async () => {
    await expectAllRejected([
      "not json",
      { ...NEXT, protocol_version: 2 },
      { ...NEXT, extra: true },
    ]);
  });

  it("refuses a malformed version or key material before touching storage", async () => {
    await expectAllRejected([
      { ...NEXT, recovery_version: 1 },
      { ...NEXT, recovery_version: "2" },
      { ...NEXT, recovery_lookup: base64(new Uint8Array(31)) },
      { ...NEXT, wrapped_master_key: binary32(200) },
    ]);
  });
});
