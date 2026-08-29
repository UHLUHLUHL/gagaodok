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
      TEST_MIGRATIONS: D1Migration[];
    }
  }
}

const worker = (exports as { default: ExportedHandler }).default;
type WorkerRequest = Parameters<NonNullable<ExportedHandler["fetch"]>>[0];
const PATH = "/v1/enrollment/initialize";
const ACCOUNT = "A0000000-0000-4000-8000-00000000000A";
const DEVICE = "B0000000-0000-4000-8000-000000000001";
const ENROLLMENT = "E0000000-0000-4000-8000-000000000001";
const TOKEN_HASH = "a".repeat(64);

function base64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function bytes(length: number, seed: number): Uint8Array {
  return Uint8Array.from({ length }, (_, index) => (seed + index) & 0xff);
}

function envelope(seed: number): string {
  const value = bytes(34, seed);
  value[0] = 1;
  value[1] = 1;
  value[2] = 0;
  value[3] = 0;
  value[4] = 0;
  value[5] = 1;
  return base64(value);
}

function enrollment(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    protocol_version: 1,
    enrollment_id: ENROLLMENT,
    account_id: ACCOUNT,
    device: {
      device_id: DEVICE,
      space_id: "MAC_SPACE",
      platform: "macos",
      display_name: null,
      device_token_hash: TOKEN_HASH,
    },
    recovery: {
      recovery_version: 1,
      recovery_lookup: base64(bytes(32, 40)),
      recovery_auth_verifier: base64(bytes(32, 80)),
      wrapped_master_key: envelope(120),
    },
    ...overrides,
  };
}

async function call(body: unknown, rawBody?: string): Promise<Response> {
  const request = new Request(`https://example.test${PATH}`, {
    method: "POST",
    body: rawBody ?? JSON.stringify(body),
  }) as unknown as WorkerRequest;
  const response = await worker.fetch?.(request, env as never, {} as never);
  if (response === undefined) throw new Error("worker returned no response");
  return response;
}

async function bodyOf(response: Response): Promise<Record<string, unknown>> {
  return (await response.json()) as Record<string, unknown>;
}

async function count(table: string): Promise<number> {
  return (await env.DB.prepare(`SELECT count(*) AS n FROM ${table}`).first<{ n: number }>())?.n ?? -1;
}

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

beforeEach(async () => {
  for (const table of [
    "pairing_claim",
    "pairing_session",
    "enrollment_log",
    "recovery_record",
    "device",
    "account",
  ]) {
    await env.DB.prepare(`DELETE FROM ${table}`).run();
  }
  const objects = await env.ATTACHMENTS.list({ prefix: "recovery/" });
  if (objects.objects.length > 0) {
    await env.ATTACHMENTS.delete(objects.objects.map((object) => object.key));
  }
});

describe("POST /v1/enrollment/initialize", () => {
  it("creates account, device, recovery copies and idempotency ledger", async () => {
    const response = await call(enrollment());
    expect(response.status).toBe(201);
    expect(await bodyOf(response)).toEqual({
      protocol_version: 1,
      request_id: ENROLLMENT,
      result: { status: "created", account_id: ACCOUNT, device_id: DEVICE },
    });
    expect(await count("account")).toBe(1);
    expect(await count("device")).toBe(1);
    expect(await count("recovery_record")).toBe(1);
    expect(await count("enrollment_log")).toBe(1);
    const objects = await env.ATTACHMENTS.list({ prefix: "recovery/" });
    expect(objects.objects).toHaveLength(1);
    expect(objects.objects[0]?.size).toBe(34);
  });

  it("replays byte-identical enrollment without another row or object", async () => {
    const raw = JSON.stringify(enrollment());
    await call({}, raw);
    const response = await call({}, raw);
    expect(response.status).toBe(200);
    expect((await bodyOf(response))["result"]).toEqual({
      status: "replayed",
      account_id: ACCOUNT,
      device_id: DEVICE,
    });
    expect(await count("account")).toBe(1);
    expect((await env.ATTACHMENTS.list({ prefix: "recovery/" })).objects).toHaveLength(1);
  });

  it("rejects one enrollment id reused with different raw bytes", async () => {
    await call(enrollment());
    const response = await call(enrollment({ account_id: "A0000000-0000-4000-8000-00000000000B" }));
    expect(response.status).toBe(409);
    expect(((await bodyOf(response))["error"] as Record<string, unknown>)["code"]).toBe(
      "ENROLLMENT_CONFLICT",
    );
  });

  it("rejects malformed JSON, unknown fields and mismatched platform-space", async () => {
    for (const body of [
      undefined,
      enrollment({ extra: true }),
      enrollment({ device: { ...(enrollment()["device"] as object), platform: "android_phone" } }),
    ]) {
      const response = body === undefined ? await call({}, "{") : await call(body);
      expect(response.status).toBe(400);
    }
    expect(await count("account")).toBe(0);
  });

  it("rejects noncanonical binary and unsupported envelope header", async () => {
    const invalidLookup = enrollment();
    (invalidLookup["recovery"] as Record<string, unknown>)["recovery_lookup"] = "AQ";
    expect((await call(invalidLookup)).status).toBe(400);

    const wrongAlgorithm = bytes(34, 1);
    wrongAlgorithm[0] = 1;
    wrongAlgorithm[1] = 2;
    wrongAlgorithm[5] = 1;
    const invalidEnvelope = enrollment();
    (invalidEnvelope["recovery"] as Record<string, unknown>)["wrapped_master_key"] =
      base64(wrongAlgorithm);
    expect((await call(invalidEnvelope)).status).toBe(400);
    expect(await count("account")).toBe(0);
  });

  it("never returns verifier, token hash, envelope, SQL or R2 object key", async () => {
    const response = await call(enrollment());
    const serialised = JSON.stringify(await bodyOf(response));
    for (const forbidden of [TOKEN_HASH, "recovery/", "SELECT", "INSERT", envelope(120)]) {
      expect(serialised).not.toContain(forbidden);
    }
  });
});
