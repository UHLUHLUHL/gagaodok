import { applyD1Migrations, env } from "cloudflare:test";
import { exports } from "cloudflare:workers";
import type { D1Migration } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import fixture from "./fixtures/swift-shadow-operations.json";
import replicaFixture from "../../../android/app/src/test/resources/swift-shadow-replica.json";

/**
 * Cross-language contract: operations the macOS shadow importer actually
 * produced, replayed against this Worker.
 *
 * The fixture is emitted by the Swift importer, not written here. A TypeScript
 * hand-built body would only prove that this file agrees with itself — the
 * point is to catch the Swift side drifting from the canonical contract, which
 * is exactly the class of failure a local Worker suite otherwise misses until
 * a real device tries it.
 *
 * Everything in the fixture is synthetic: a made-up account, a made-up room and
 * two invented lines. No real conversation is involved.
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
  operations: Array<Record<string, unknown>>;
  continuation_room_operation: Record<string, unknown>;
  manifest: {
    rooms: Array<{
      room_id: string;
      turn_count: number;
      bubble_count: number;
      content_hash: string;
    }>;
  };
}

const data = fixture as Fixture;
const TIMESTAMP = "2026-08-31T00:00:00Z";
const SPACE = "MAC_SPACE";

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

const TOKEN = `gdt1_${base64Url(tokenBytes(1))}`;

async function post(body: unknown): Promise<Response> {
  const request = new Request("https://example.test/v1/sync/operations", {
    method: "POST",
    headers: new Headers({ Authorization: `Device ${TOKEN}`, "Content-Type": "application/json" }),
    body: JSON.stringify(body),
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
  await db.prepare(
    `INSERT INTO device
       (account_id, device_id, space_id, platform, display_name_enc,
        linked_at, revoked_at, key_generation, token_hash)
     VALUES (?, ?, ?, 'macos', NULL, ?, NULL, 1, ?)`,
  ).bind(data.account_id, data.device_id, SPACE, TIMESTAMP, await sha256Hex(tokenBytes(1))).run();
});

describe("macOS shadow importer output against the canonical contract", () => {
  it("pins origin and writer space separately for continuation", () => {
    const operation = data.continuation_room_operation;
    expect((operation["target"] as Record<string, unknown>)["space_id"]).toBe("PHONE_SPACE");
    expect((operation["metadata_set"] as Record<string, unknown>)["origin_space_id"]).toBe(
      "MAC_SPACE",
    );
  });

  it("is accepted operation for operation", async () => {
    for (const operation of data.operations) {
      const response = await post(operation);
      // On a refusal the code alone is reported. The body holds ciphertext, so
      // it must not be echoed into a test failure message either.
      expect(
        response.status,
        `${String(operation["op"])} was refused with ${response.status}`,
      ).toBe(200);
      const body = await response.json() as { result: { status: string } };
      expect(body.result.status, `${String(operation["op"])} was not a first write`).toBe("applied");
    }
  });

  it("lands exactly the rows the manifest counted", async () => {
    for (const operation of data.operations) await post(operation);

    const expected = data.manifest.rooms[0]!;
    expect(await count("room")).toBe(1);
    expect(await count("turn")).toBe(expected.turn_count);
    expect(await count("bubble")).toBe(expected.bubble_count);
    // One change_log entry per accepted operation: the projection a second
    // device pulls is the same size as what was queued.
    expect(await count("change_log")).toBe(data.operations.length);
  });

  it("stores every meaningful field as ciphertext and nothing else", async () => {
    for (const operation of data.operations) await post(operation);

    const bubbles = await db.prepare(
      `SELECT sender_enc, kind_enc, text_enc, bubble_order FROM bubble ORDER BY bubble_order ASC`,
    ).all<{ sender_enc: string | null; kind_enc: string | null; text_enc: string | null; bubble_order: number }>();

    expect(bubbles.results).toHaveLength(expected(data).bubble_count);
    expect(bubbles.results.map((row) => row.bubble_order)).toEqual(
      Array.from({ length: expected(data).bubble_count }, (_, index) => index),
    );
    for (const row of bubbles.results) {
      for (const value of [row.sender_enc, row.kind_enc, row.text_enc]) {
        expect(value).not.toBeNull();
        // A v1 field envelope, not readable text: version 1, algorithm 1.
        const bytes = Uint8Array.from(atob(value!), (character) => character.charCodeAt(0));
        expect([bytes[0], bytes[1]]).toEqual([1, 1]);
        expect(bytes.length).toBeGreaterThanOrEqual(34);
      }
      // The two words the fixture actually contains must not be anywhere in
      // the stored row.
      expect(row.text_enc).not.toContain("합성");
    }

    const room = await db.prepare(`SELECT title_enc FROM room`).first<{ title_enc: string | null }>();
    expect(room?.title_enc).not.toBeNull();
  });

  it("names projected fields the way the Android fixture expects", async () => {
    for (const operation of data.operations) await post(operation);

    const request = new Request("https://example.test/v1/sync/changes?after_seq=0&limit=300", {
      method: "GET",
      headers: new Headers({ Authorization: `Device ${TOKEN}` }),
    }) as unknown as WorkerRequest;
    const response = await worker.fetch?.(request, env as never, {} as never);
    const body = await response!.json() as {
      result: {
        changes: Array<{
          entity_type: string;
          identity: Record<string, unknown>;
          projection: Record<string, unknown>;
        }>;
      };
    };
    const liveBubble = body.result.changes.find((row) => row.entity_type === "bubble");
    expect(liveBubble, "no bubble came back from the change feed").toBeDefined();

    // The Android replica fixture is hand-assembled from operation bodies, so
    // nothing else stops it from encoding an assumption about the wire that is
    // simply wrong — which is exactly what happened: the fixture said
    // `text_enc`, the wire says `text`, and a cross-language test built on that
    // fixture passed while the real devices decrypted nothing. Pin the names
    // against a real projection so the next drift fails here instead of on a
    // phone.
    const fixtureBubble = (replicaFixture as {
      entries: Array<{
        entity_type: string;
        identity: Record<string, unknown>;
        projection: Record<string, unknown>;
      }>;
    }).entries.find((entry) => entry.entity_type === "bubble");
    expect(fixtureBubble, "the Android fixture has no bubble").toBeDefined();

    const live = Object.keys(liveBubble!.projection);
    for (const key of Object.keys(fixtureBubble!.projection)) {
      expect(live, `the wire has no projected field named ${key}`).toContain(key);
    }
    // Identity too, and not only projection. Checking one and not the other is
    // what let `worldline_key` — a storage-key name the wire never uses — sit
    // in the fixture unnoticed, harmless only because these rows have no
    // worldline at all.
    const liveIdentity = Object.keys(liveBubble!.identity);
    for (const key of Object.keys(fixtureBubble!.identity)) {
      expect(liveIdentity, `the wire identity has no field named ${key}`).toContain(key);
    }
    expect(liveIdentity).not.toContain("worldline_key");

    // And the fields that actually carry the ciphertext are present under the
    // unsuffixed names, not the D1 column names.
    for (const field of ["sender", "kind", "text"]) {
      expect(live).toContain(field);
      expect(live).not.toContain(`${field}_enc`);
      expect(fixtureBubble!.projection[field]).toBe(liveBubble!.projection[field]);
    }
  });

  it("replays without duplicating anything", async () => {
    for (const operation of data.operations) await post(operation);
    const before = await count("change_log");

    // The same operation ids again: idempotency is what makes a crashed
    // importer safe to restart, and a duplicate row would be silent corruption.
    for (const operation of data.operations) {
      const response = await post(operation);
      expect(response.status).toBe(200);
      const body = await response.json() as { result: { status: string } };
      expect(body.result.status).toBe("replayed");
    }
    expect(await count("change_log")).toBe(before);
    expect(await count("bubble")).toBe(expected(data).bubble_count);
    expect(await count("turn")).toBe(expected(data).turn_count);
  });
});

function expected(source: Fixture) {
  return source.manifest.rooms[0]!;
}
