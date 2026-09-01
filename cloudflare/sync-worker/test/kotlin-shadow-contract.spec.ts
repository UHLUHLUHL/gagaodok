import { applyD1Migrations, env } from "cloudflare:test";
import { exports } from "cloudflare:workers";
import type { D1Migration } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import fixture from "../../../android/app/src/test/resources/kotlin-shadow-operations.json";

/**
 * Reverse direction: operations the Android writer actually produced.
 *
 * The fixture is emitted by the writer's own unit test, not written here. The
 * forward-direction fixture was once hand-assembled and encoded a wrong guess
 * about the wire, which both sides then agreed on while the real devices
 * decrypted nothing — so nothing in this file describes the payload, it only
 * replays it.
 *
 * Synthetic throughout: a made-up account, a made-up room, two invented lines.
 */

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

interface Fixture {
  account_id: string;
  device_id: string;
  space_id: string;
  room_id: string;
  operations: Array<Record<string, unknown>>;
  continuation_room_operation: Record<string, unknown>;
  expected: { turn_count: number; bubble_count: number; content_hash: string };
}

const data = fixture as Fixture;
const TIMESTAMP = "2026-08-31T00:00:00Z";

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

const PHONE_TOKEN = `gdt1_${base64Url(tokenBytes(1))}`;
const MAC_TOKEN = `gdt1_${base64Url(tokenBytes(65))}`;
const MAC_DEVICE = "B0000000-0000-4000-8000-0000000000AC";

async function send(
  path: string,
  method: string,
  token: string,
  body?: unknown,
): Promise<Response> {
  const headers = new Headers({ Authorization: `Device ${token}` });
  if (body !== undefined) headers.set("Content-Type", "application/json");
  const request = new Request(`https://example.test${path}`, {
    method,
    headers,
    body: body === undefined ? null : JSON.stringify(body),
  }) as unknown as WorkerRequest;
  const response = await worker.fetch?.(request, env as never, {} as never);
  if (response === undefined) throw new Error("worker did not return a response");
  return response;
}

async function count(table: string): Promise<number> {
  const row = await db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).first<{ n: number }>();
  return row?.n ?? 0;
}

beforeAll(async () => {
  await applyD1Migrations(db, env.TEST_MIGRATIONS);
});

beforeEach(async () => {
  for (const table of [
    "rate_limit_bucket", "transaction_guard", "change_log", "operation_log",
    "bubble", "turn", "room", "device", "account",
  ]) {
    await db.prepare(`DELETE FROM ${table}`).run();
  }
  await db.prepare("INSERT INTO account (account_id, created_at) VALUES (?, ?)")
    .bind(data.account_id, TIMESTAMP).run();
  // The writing phone, and a Mac that only reads.
  for (const [deviceId, space, platform, seed] of [
    [data.device_id, data.space_id, "android_phone", 1],
    [MAC_DEVICE, "MAC_SPACE", "macos", 65],
  ] as const) {
    await db.prepare(
      `INSERT INTO device
         (account_id, device_id, space_id, platform, display_name_enc,
          linked_at, revoked_at, key_generation, token_hash)
       VALUES (?, ?, ?, ?, NULL, ?, NULL, 1, ?)`,
    ).bind(data.account_id, deviceId, space, platform, TIMESTAMP, await sha256Hex(tokenBytes(seed))).run();
  }
});

describe("Android writer output against the canonical contract", () => {
  it("pins origin and writer space separately for continuation", () => {
    const operation = data.continuation_room_operation;
    expect((operation["target"] as Record<string, unknown>)["space_id"]).toBe("PHONE_SPACE");
    expect((operation["metadata_set"] as Record<string, unknown>)["origin_space_id"]).toBe(
      "MAC_SPACE",
    );
  });

  it("is accepted operation for operation", async () => {
    for (const operation of data.operations) {
      const response = await send("/v1/sync/operations", "POST", PHONE_TOKEN, operation);
      expect(
        response.status,
        `${String(operation["op"])} was refused with ${response.status}`,
      ).toBe(200);
      const body = await response.json() as { result: { status: string } };
      expect(body.result.status).toBe("applied");
    }
    expect(await count("room")).toBe(1);
    expect(await count("turn")).toBe(data.expected.turn_count);
    expect(await count("bubble")).toBe(data.expected.bubble_count);
  });

  it("refuses the same rows written into another device's space", async () => {
    // The Mac's token cannot file PHONE_SPACE rows. Sharing an account is not
    // authority over another space's canonical state.
    const response = await send("/v1/sync/operations", "POST", MAC_TOKEN, data.operations[0]);
    expect(response.status).toBe(401);
    expect(await count("room")).toBe(0);
  });

  it("hands the Mac every written row under the wire field names", async () => {
    for (const operation of data.operations) {
      await send("/v1/sync/operations", "POST", PHONE_TOKEN, operation);
    }
    // Read as the Mac: a different device, a different space, same account.
    const response = await send("/v1/sync/changes?after_seq=0&limit=300", "GET", MAC_TOKEN);
    expect(response.status).toBe(200);
    const body = await response.json() as {
      result: {
        changes: Array<{
          entity_type: string;
          identity: Record<string, unknown>;
          projection: Record<string, unknown>;
        }>;
      };
    };

    const bubbles = body.result.changes.filter((row) => row.entity_type === "bubble");
    expect(bubbles).toHaveLength(data.expected.bubble_count);
    for (const row of bubbles) {
      // The reader derives its scope key from these three, so they must be
      // exactly what the writer sealed under.
      expect(row.identity["space_id"]).toBe(data.space_id);
      expect(row.identity["room_id"]).toBe(data.room_id);
      // Nullable `worldline_id` on the wire, not the storage key's "".
      expect(row.identity["worldline_id"]).toBeNull();
      expect(Object.keys(row.identity)).not.toContain("worldline_key");
      for (const field of ["sender", "kind", "text"]) {
        // Unsuffixed on the wire — the `_enc` spelling is D1's column name and
        // looking for it is what made a reader see an empty row.
        expect(Object.keys(row.projection)).toContain(field);
        expect(Object.keys(row.projection)).not.toContain(`${field}_enc`);
        expect(typeof row.projection[field]).toBe("string");
      }
    }

    // Every sealed value the phone queued is what the Mac is handed, byte for
    // byte. Anything less and the envelope would not open.
    const queued = data.operations.filter((operation) => operation["op"] === "create_bubble");
    for (const operation of queued) {
      const target = operation["target"] as Record<string, string>;
      const sealed = operation["set"] as Record<string, string>;
      const row = bubbles.find((item) => item.identity["message_id"] === target["message_id"]);
      expect(row, `the Mac was not handed ${target["message_id"]}`).toBeDefined();
      for (const field of ["sender", "kind", "text"]) {
        expect(row!.projection[field]).toBe(sealed[field]);
      }
      expect(row!.projection["bubble_order"]).toBe(operation["bubble_order"]);
    }
  });
});
