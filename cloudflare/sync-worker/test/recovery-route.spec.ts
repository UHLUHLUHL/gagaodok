import { applyD1Migrations, env } from "cloudflare:test";
import { exports } from "cloudflare:workers";
import type { D1Migration } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import vectors from "../../../tools/fixtures/e2ee_contract_vectors.json";

declare global {
  namespace Cloudflare {
    interface Env { DB: D1Database; ATTACHMENTS: R2Bucket; CURSOR_MAC_KEY: string; TEST_MIGRATIONS: D1Migration[]; }
  }
}

const worker = (exports as { default: ExportedHandler }).default;
type WorkerRequest = Parameters<NonNullable<ExportedHandler["fetch"]>>[0];
const ACCOUNT = "A0000000-0000-4000-8000-00000000000A";
const DEVICE = "B0000000-0000-4000-8000-000000000002";
const NOW = "2026-08-29T00:00:00.000Z";
const recovery = vectors.recovery;

function b64(hex: string): string {
  const bytes = Uint8Array.from(hex.match(/../g) ?? [], (value) => Number.parseInt(value, 16));
  return btoa(String.fromCharCode(...bytes));
}

function body(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    protocol_version: 1,
    recovery_lookup: b64(recovery.recovery_lookup_hex),
    recovery_auth: b64(recovery.recovery_auth_hex),
    device: {
      device_id: DEVICE,
      space_id: "PHONE_SPACE",
      platform: "android_phone",
      display_name: null,
      device_token_hash: "b".repeat(64),
    },
    ...overrides,
  };
}

async function call(value: unknown): Promise<Response> {
  const request = new Request("https://example.test/v1/recovery/redeem", {
    method: "POST", body: JSON.stringify(value),
  }) as unknown as WorkerRequest;
  const response = await worker.fetch?.(request, env as never, {} as never);
  if (!response) throw new Error("no response");
  return response;
}

beforeAll(async () => { await applyD1Migrations(env.DB, env.TEST_MIGRATIONS); });
beforeEach(async () => {
  await env.DB.prepare("DELETE FROM device").run();
  await env.DB.prepare("DELETE FROM recovery_record").run();
  await env.DB.prepare("DELETE FROM enrollment_log").run();
  await env.DB.prepare("DELETE FROM account").run();
  await env.DB.prepare("INSERT INTO account (account_id, created_at) VALUES (?, ?)").bind(ACCOUNT, NOW).run();
  await env.DB.prepare(
    `INSERT INTO recovery_record
       (account_id, recovery_version, recovery_lookup_b64, recovery_auth_verifier,
        wrapped_master_key_enc, r2_object_key, key_generation, created_at, revoked_at)
     VALUES (?, 1, ?, ?, ?, ?, 1, ?, NULL)`,
  ).bind(
    ACCOUNT, b64(recovery.recovery_lookup_hex), recovery.recovery_auth_verifier_hex,
    recovery.envelope_base64, "recovery/90000000-0000-4000-8000-000000000001", NOW,
  ).run();
});

describe("POST /v1/recovery/redeem", () => {
  it("links a new device and returns only the wrapped key package", async () => {
    const response = await call(body());
    expect(response.status).toBe(201);
    expect(await response.json()).toEqual({
      protocol_version: 1,
      result: {
        status: "created", account_id: ACCOUNT, device_id: DEVICE,
        recovery_version: 1, key_generation: 1, wrapped_master_key: recovery.envelope_base64,
      },
    });
  });

  it("replays an identical device identity without another row", async () => {
    await call(body());
    const response = await call(body());
    expect(response.status).toBe(200);
    expect((await response.json() as { result: { status: string } }).result.status).toBe("replayed");
    expect((await env.DB.prepare("SELECT count(*) AS n FROM device").first<{ n: number }>())?.n).toBe(1);
  });

  it("returns one indistinguishable error for missing, wrong and revoked credentials", async () => {
    const wrongAuth = body({ recovery_auth: b64("00".repeat(32)) });
    const missing = body({ recovery_lookup: b64("01".repeat(32)) });
    for (const value of [wrongAuth, missing]) {
      const response = await call(value);
      expect(response.status).toBe(401);
      expect(await response.json()).toEqual({ protocol_version: 1, error: { code: "RECOVERY_INVALID", retryable: false } });
    }
    await env.DB.prepare("UPDATE recovery_record SET revoked_at = ?").bind(NOW).run();
    expect((await call(body())).status).toBe(401);
  });

  it("rejects the same device identity with a different token hash", async () => {
    await call(body());
    const changed = body();
    (changed.device as Record<string, unknown>).device_token_hash = "c".repeat(64);
    const response = await call(changed);
    expect(response.status).toBe(409);
    expect((await response.json() as { error: { code: string } }).error.code).toBe("RECOVERY_CONFLICT");
  });

  it("rejects unknown fields and noncanonical binary before writing", async () => {
    expect((await call({ ...body(), extra: true })).status).toBe(400);
    expect((await call({ ...body(), recovery_auth: "AQ" })).status).toBe(400);
    expect((await env.DB.prepare("SELECT count(*) AS n FROM device").first<{ n: number }>())?.n).toBe(0);
  });

  it("does not echo auth, verifier, token hash, SQL or object key", async () => {
    const response = await call(body({ recovery_auth: b64("00".repeat(32)) }));
    const text = JSON.stringify(await response.json());
    for (const forbidden of [recovery.recovery_auth_hex, recovery.recovery_auth_verifier_hex, "b".repeat(64), "SELECT", "recovery/"]) {
      expect(text).not.toContain(forbidden);
    }
  });
});
