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

async function call(
  target: string,
  token: string | null = MAC_TOKEN,
  query = "",
  method = "POST",
): Promise<Response> {
  const headers = new Headers();
  if (token !== null) headers.set("Authorization", `Device ${token}`);
  const request = new Request(`https://example.test${PATH}/${target}/revoke${query}`, { method, headers });
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

describe("POST /v1/account/devices/{device_id}/revoke", () => {
  async function revokedAtOf(device: string): Promise<string | null> {
    const row = await db.prepare("SELECT revoked_at FROM device WHERE device_id = ?")
      .bind(device).first<{ revoked_at: string | null }>();
    return row?.revoked_at ?? null;
  }

  it("takes a sibling device off the account and stops its token working", async () => {
    const response = await call(PHONE_DEVICE);
    expect(response.status).toBe(200);
    const body = await response.json() as { result: { device_id: string; revoked_at: string } };
    expect(body.result.device_id).toBe(PHONE_DEVICE);
    expect(body.result.revoked_at).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
    expect(await revokedAtOf(PHONE_DEVICE)).not.toBeNull();

    // The point of revoking. Enforcement already existed; only the setter was
    // missing, so this asserts the two halves are actually connected.
    const listed = await worker.fetch?.(
      new Request("https://example.test/v1/account/devices", {
        headers: new Headers({ Authorization: `Device ${PHONE_TOKEN}` }),
      }) as unknown as WorkerRequest,
      env as never,
      {} as never,
    );
    expect(listed?.status).toBe(403);
  });

  it("lets a device revoke itself", async () => {
    const response = await call(MAC_DEVICE);
    expect(response.status).toBe(200);
    expect(await revokedAtOf(MAC_DEVICE)).not.toBeNull();
  });

  it("answers success when the device was already revoked", async () => {
    const first = await call(PHONE_DEVICE);
    const firstBody = await first.json() as { result: { revoked_at: string } };
    const second = await call(PHONE_DEVICE);
    expect(second.status).toBe(200);
    const secondBody = await second.json() as { result: { revoked_at: string } };
    // A repeat must not look like a failure, and must not move the timestamp:
    // a client that never saw the first answer has to be able to ask again.
    expect(secondBody.result.revoked_at).toBe(firstBody.result.revoked_at);
  });

  it("cannot reach a device on another account", async () => {
    const response = await call(OTHER_DEVICE);
    expect(response.status).toBe(404);
    expect(JSON.stringify(await response.json())).not.toContain(OTHER_DEVICE);
    expect(await revokedAtOf(OTHER_DEVICE)).toBeNull();
  });

  it("requires a valid active device token", async () => {
    expect((await call(PHONE_DEVICE, null)).status).toBe(401);
    expect((await call(PHONE_DEVICE, REVOKED_TOKEN)).status).toBe(403);
    expect(await revokedAtOf(PHONE_DEVICE)).toBeNull();
  });

  it("rejects a malformed device id, query parameters and wrong methods", async () => {
    expect((await call("not-a-uuid")).status).toBe(404);
    expect((await call(PHONE_DEVICE, MAC_TOKEN, "?force=true")).status).toBe(400);
    expect((await call(PHONE_DEVICE, MAC_TOKEN, "", "GET")).status).toBe(404);
    expect(await revokedAtOf(PHONE_DEVICE)).toBeNull();
  });
});
