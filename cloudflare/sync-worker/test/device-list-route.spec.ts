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
const PHONE_DEVICE = "B0000000-0000-4000-8000-000000000002";
const REVOKED_DEVICE = "B0000000-0000-4000-8000-000000000003";
const OTHER_DEVICE = "B0000000-0000-4000-8000-000000000004";
const LINKED_AT = "2026-08-31T00:00:00Z";
const PATH = "/v1/account/devices";

function tokenBytes(seed: number): Uint8Array {
  return Uint8Array.from({ length: 32 }, (_, index) => (seed + index) & 0xff);
}

function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes as BufferSource);
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function envelope(seed: number): string {
  const bytes = new Uint8Array(34);
  bytes.set([1, 1, 0, 0, 0, 1]);
  for (let index = 6; index < bytes.length; index += 1) bytes[index] = (seed + index) & 0xff;
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

const MAC_TOKEN = `gdt1_${base64Url(tokenBytes(1))}`;
const PHONE_TOKEN = `gdt1_${base64Url(tokenBytes(33))}`;
const REVOKED_TOKEN = `gdt1_${base64Url(tokenBytes(65))}`;

async function run(sql: string, ...values: (string | number | null)[]): Promise<void> {
  await db.prepare(sql).bind(...values).run();
}

async function call(token: string | null = MAC_TOKEN, query = "", method = "GET"): Promise<Response> {
  const headers = new Headers();
  if (token !== null) headers.set("Authorization", `Device ${token}`);
  const request = new Request(`https://example.test${PATH}${query}`, { method, headers });
  const response = await worker.fetch?.(request as unknown as WorkerRequest, env as never, {} as never);
  if (response === undefined) throw new Error("worker did not return a response");
  return response;
}

beforeAll(async () => {
  await applyD1Migrations(db, env.TEST_MIGRATIONS);
});

beforeEach(async () => {
  await db.prepare("DELETE FROM rate_limit_bucket").run();
  await db.prepare("DELETE FROM device").run();
  await db.prepare("DELETE FROM account").run();
  await run("INSERT INTO account (account_id, created_at) VALUES (?, ?)", ACCOUNT, LINKED_AT);
  await run("INSERT INTO account (account_id, created_at) VALUES (?, ?)", OTHER_ACCOUNT, LINKED_AT);

  const rows = [
    [ACCOUNT, MAC_DEVICE, "MAC_SPACE", "macos", envelope(1), LINKED_AT, null, 1],
    [ACCOUNT, PHONE_DEVICE, "PHONE_SPACE", "android_phone", null, "2026-08-31T00:01:00Z", null, 33],
    [ACCOUNT, REVOKED_DEVICE, "TABLET_SPACE", "android_tablet", envelope(3), LINKED_AT, LINKED_AT, 65],
    [OTHER_ACCOUNT, OTHER_DEVICE, "MAC_SPACE", "macos", envelope(4), LINKED_AT, null, 97],
  ] as const;
  for (const [account, device, space, platform, displayName, linkedAt, revokedAt, seed] of rows) {
    await run(
      `INSERT INTO device
         (account_id, device_id, space_id, platform, display_name_enc, linked_at,
          revoked_at, key_generation, token_hash)
       VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?)`,
      account,
      device,
      space,
      platform,
      displayName,
      linkedAt,
      revokedAt,
      await sha256Hex(tokenBytes(seed)),
    );
  }
});

describe("GET /v1/account/devices", () => {
  it("returns only active devices from the authenticated account", async () => {
    const response = await call();
    expect(response.status).toBe(200);
    const body = await response.json() as {
      protocol_version: number;
      request_id: string;
      result: { devices: Array<Record<string, unknown>> };
    };

    expect(body.protocol_version).toBe(1);
    expect(body.request_id).toMatch(/^[0-9A-F-]{36}$/);
    expect(body.result.devices).toEqual([
      {
        device_id: MAC_DEVICE,
        space_id: "MAC_SPACE",
        platform: "macos",
        display_name: envelope(1),
        linked_at: LINKED_AT,
        is_current: true,
      },
      {
        device_id: PHONE_DEVICE,
        space_id: "PHONE_SPACE",
        platform: "android_phone",
        display_name: null,
        linked_at: "2026-08-31T00:01:00Z",
        is_current: false,
      },
    ]);
    const serialised = JSON.stringify(body);
    for (const leak of [OTHER_DEVICE, REVOKED_DEVICE, "token_hash", "revoked_at", "account_id", "gdt1_"]) {
      expect(serialised).not.toContain(leak);
    }
  });

  it("marks the calling phone rather than trusting a query value", async () => {
    const response = await call(PHONE_TOKEN);
    const body = await response.json() as { result: { devices: Array<{ device_id: string; is_current: boolean }> } };
    expect(response.status).toBe(200);
    expect(body.result.devices.find((device) => device.is_current)?.device_id).toBe(PHONE_DEVICE);
  });

  it("requires a valid active device token", async () => {
    expect((await call(null)).status).toBe(401);
    expect((await call("gdt1_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")).status).toBe(401);
    expect((await call(REVOKED_TOKEN)).status).toBe(403);
  });

  it("rejects query parameters and wrong methods without echoing them", async () => {
    const queryResponse = await call(MAC_TOKEN, "?include_tokens=true");
    expect(queryResponse.status).toBe(400);
    expect(JSON.stringify(await queryResponse.json())).not.toContain("include_tokens");
    expect((await call(MAC_TOKEN, "", "POST")).status).toBe(404);
  });

  it("fails closed when an encrypted display name in storage is malformed", async () => {
    await run(
      "UPDATE device SET display_name_enc = ? WHERE account_id = ? AND device_id = ?",
      "not-an-envelope",
      ACCOUNT,
      PHONE_DEVICE,
    );
    const response = await call();
    expect(response.status).toBe(503);
    const serialised = JSON.stringify(await response.json());
    expect(serialised).not.toContain("not-an-envelope");
    expect(serialised).not.toContain(PHONE_DEVICE);
  });
});
