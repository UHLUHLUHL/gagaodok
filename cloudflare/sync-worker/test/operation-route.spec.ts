import { applyD1Migrations, env } from "cloudflare:test";
import { exports } from "cloudflare:workers";
import type { D1Migration } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { handleOperationRequest } from "../src/routes/operations";
import type { Env } from "../src/env";

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

const db = env.DB;
const worker = (exports as { default: ExportedHandler }).default;
type WorkerRequest = Parameters<NonNullable<ExportedHandler["fetch"]>>[0];

const PATH = "/v1/sync/operations";

// Synthetic fixtures only.
const ACCOUNT = "A0000000-0000-4000-8000-00000000000A";
const DEVICE = "B0000000-0000-4000-8000-000000000001";
const OTHER_DEVICE = "B0000000-0000-4000-8000-000000000002";
const ROOM = "10000000-0000-4000-8000-00000000DA01";
const MISSING_ROOM = "10000000-0000-4000-8000-00000000DA02";
const ATTACHMENT = "70000000-0000-4000-8000-00000000DB01";
const OPERATION = "90000000-0000-4000-8000-00000000DC01";
const OPERATION_2 = "90000000-0000-4000-8000-00000000DC02";
const TIMESTAMP = "2026-08-28T00:00:00Z";
const SPACE = "MAC_SPACE";

function syntheticTokenBytes(seed: number): Uint8Array {
  const bytes = new Uint8Array(32);
  for (let index = 0; index < bytes.length; index += 1) bytes[index] = (seed + index) & 0xff;
  return bytes;
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
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
const TOKEN = `gdt1_${base64Url(syntheticTokenBytes(1))}`;
const UNKNOWN_TOKEN = `gdt1_${base64Url(syntheticTokenBytes(99))}`;

function envelope(seed: number): string {
  const bytes = new Uint8Array(34);
  bytes[0] = 1;
  bytes[1] = 1;
  for (let index = 2; index < bytes.length; index += 1) bytes[index] = (seed + index) & 0xff;
  return base64(bytes);
}

function patchRoom(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    protocol_version: 1,
    operation_id: OPERATION,
    device_id: DEVICE,
    op: "patch_room",
    entity_type: "room",
    target: { space_id: SPACE, room_id: ROOM, worldline_id: null },
    base_revision: 0,
    metadata_set: {},
    metadata_clear: [],
    set: { title: envelope(1) },
    clear: [],
    created_at: TIMESTAMP,
    ...overrides,
  };
}

function createAttachment(): Record<string, unknown> {
  return {
    protocol_version: 1,
    operation_id: OPERATION_2,
    device_id: DEVICE,
    op: "create_attachment",
    entity_type: "attachment",
    target: { space_id: SPACE, attachment_id: ATTACHMENT },
    metadata_set: {
      origin_space_id: SPACE,
      kind: "attachment",
      source_byte_size: 100,
      ciphertext_byte_size: 134,
      ciphertext_hash: "b".repeat(64),
      key_generation: 1,
      created_at: TIMESTAMP,
    },
    metadata_clear: [],
    set: { file_name: envelope(2), mime_type: envelope(3), wrapped_file_key: envelope(4) },
    clear: [],
    created_at: TIMESTAMP,
  };
}

async function call(
  init: { method?: string; path?: string; body?: unknown; rawBody?: string; token?: string | null } = {},
): Promise<Response> {
  const headers = new Headers();
  if (init.token !== null) {
    headers.set("Authorization", `Device ${init.token ?? TOKEN}`);
  }
  const body = init.rawBody ?? (init.body === undefined ? null : JSON.stringify(init.body));
  const request = new Request(`https://example.test${init.path ?? PATH}`, {
    method: init.method ?? "POST",
    headers,
    body,
  }) as unknown as WorkerRequest;
  const response = await worker.fetch?.(request, env as never, {} as never);
  if (response === undefined) {
    throw new Error("worker did not return a response");
  }
  return response;
}

async function bodyOf(response: Response): Promise<Record<string, unknown>> {
  return (await response.json()) as Record<string, unknown>;
}

/** No SQL, stack, token, ciphertext or free-form message may reach a client. */
function expectContentFree(serialised: string): void {
  for (const leak of [TOKEN, "gdt1_", "SELECT", "UPDATE", "INSERT", "obj/", "message", "stack", envelope(1)]) {
    expect(serialised, `response leaked ${leak}`).not.toContain(leak);
  }
}

async function countOf(table: string): Promise<number> {
  const row = await db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).first<{ n: number }>();
  return row?.n ?? 0;
}

beforeAll(async () => {
  await applyD1Migrations(db, env.TEST_MIGRATIONS);
});

beforeEach(async () => {
  for (const table of [
    "transaction_guard",
    "change_log",
    "operation_log",
    "attachment",
    "room",
    "device",
    "account",
  ]) {
    await db.prepare(`DELETE FROM ${table}`).run();
  }
  await db
    .prepare("INSERT INTO account (account_id, created_at) VALUES (?, ?)")
    .bind(ACCOUNT, TIMESTAMP)
    .run();
  for (const [deviceId, seed] of [
    [DEVICE, 1],
    [OTHER_DEVICE, 33],
  ] as const) {
    await db
      .prepare(
        `INSERT INTO device
           (account_id, device_id, space_id, platform, display_name_enc,
            linked_at, revoked_at, key_generation, token_hash)
         VALUES (?, ?, ?, 'macos', NULL, ?, NULL, 1, ?)`,
      )
      .bind(ACCOUNT, deviceId, SPACE, TIMESTAMP, await sha256Hex(syntheticTokenBytes(seed)))
      .run();
  }
  await db
    .prepare(
      `INSERT INTO room
         (account_id, space_id, room_id, origin_space_id, title_enc, status_message_enc, music_title_enc,
          music_artist_enc, revision, server_seq, created_at, updated_at)
       VALUES (?, ?, ?, ?, NULL, NULL, NULL, NULL, 0, NULL, ?, ?)`,
    )
    .bind(ACCOUNT, SPACE, ROOM, SPACE, TIMESTAMP, TIMESTAMP)
    .run();
});

describe("POST /v1/sync/operations — success", () => {
  it("returns the §2.2 envelope for an applied operation", async () => {
    const response = await call({ body: patchRoom() });
    expect(response.status).toBe(200);
    expect(await bodyOf(response)).toEqual({
      protocol_version: 1,
      request_id: OPERATION,
      result: { status: "applied", operation_id: OPERATION, server_seq: 1, revision: 1 },
    });
  });

  it("returns replayed with the same request id for a byte-identical retry", async () => {
    await call({ body: patchRoom() });
    const response = await call({ body: patchRoom() });
    expect(response.status).toBe(200);
    const body = await bodyOf(response);
    expect(body["request_id"]).toBe(OPERATION);
    expect(body["result"]).toEqual({
      status: "replayed",
      operation_id: OPERATION,
      server_seq: 1,
      revision: 1,
    });
    expect(await countOf("change_log")).toBe(1);
  });

  it("passes a null revision through for an attachment", async () => {
    const response = await call({ body: createAttachment() });
    expect(response.status).toBe(200);
    const body = await bodyOf(response);
    expect((body["result"] as Record<string, unknown>)["revision"]).toBeNull();
    expect(body["request_id"]).toBe(OPERATION_2);
    expectContentFree(JSON.stringify(body));
  });
});

describe("POST /v1/sync/operations — errors that carry the request id", () => {
  it("names the operation on a CAS conflict", async () => {
    const response = await call({ body: patchRoom({ base_revision: 7 }) });
    expect(response.status).toBe(409);
    const body = await bodyOf(response);
    expect(body["request_id"]).toBe(OPERATION);
    expect(body["error"]).toEqual({ code: "REVISION_CONFLICT", retryable: false, current_revision: 0 });
    // The id lives at the top level only, never inside the error detail.
    expect(JSON.stringify(body["error"])).not.toContain(OPERATION);
  });

  it("names the operation when the entity is missing", async () => {
    const response = await call({
      body: patchRoom({ target: { space_id: SPACE, room_id: MISSING_ROOM, worldline_id: null } }),
    });
    expect(response.status).toBe(404);
    const body = await bodyOf(response);
    expect(body["request_id"]).toBe(OPERATION);
    expect(body["error"]).toEqual({ code: "ENTITY_NOT_FOUND", retryable: false });
  });

  it("names the operation on a replay mismatch", async () => {
    await call({ body: patchRoom() });
    const response = await call({ body: patchRoom({ set: { title: envelope(5) } }) });
    expect(response.status).toBe(409);
    const body = await bodyOf(response);
    expect(body["request_id"]).toBe(OPERATION);
    expect((body["error"] as Record<string, unknown>)["code"]).toBe("OPERATION_REPLAY_MISMATCH");
  });

  it("names the operation when the body device is not the authenticated one", async () => {
    const response = await call({ body: patchRoom({ device_id: OTHER_DEVICE }) });
    expect(response.status).toBe(401);
    const body = await bodyOf(response);
    expect(body["request_id"]).toBe(OPERATION);
    expect((body["error"] as Record<string, unknown>)["code"]).toBe("AUTH_INVALID");
  });
});

describe("POST /v1/sync/operations — errors with no request id", () => {
  it("refuses an unknown token before any parse", async () => {
    const response = await call({ body: patchRoom(), token: UNKNOWN_TOKEN });
    expect(response.status).toBe(401);
    const body = await bodyOf(response);
    expect(body["request_id"]).toBeUndefined();
    expect(body["error"]).toEqual({ code: "AUTH_INVALID", retryable: false });
    expectContentFree(JSON.stringify(body));
  });

  it("refuses a missing Authorization header", async () => {
    const response = await call({ body: patchRoom(), token: null });
    expect(response.status).toBe(401);
    expect((await bodyOf(response))["request_id"]).toBeUndefined();
  });

  it("refuses malformed JSON", async () => {
    const response = await call({ rawBody: "{not json" });
    expect(response.status).toBe(400);
    const body = await bodyOf(response);
    expect(body["request_id"]).toBeUndefined();
    expect((body["error"] as Record<string, unknown>)["code"]).toBe("VALIDATION_FAILED");
  });

  it("refuses a body the validator rejects", async () => {
    const response = await call({ body: patchRoom({ op: "nope" }) });
    expect(response.status).toBe(400);
    expect((await bodyOf(response))["request_id"]).toBeUndefined();
  });

  it("refuses an oversized declared length", async () => {
    const headers = new Headers({
      Authorization: `Device ${TOKEN}`,
      "Content-Length": String(2_000_001),
    });
    const request = new Request(`https://example.test${PATH}`, {
      method: "POST",
      headers,
      body: "{}",
    }) as unknown as WorkerRequest;
    const response = await worker.fetch?.(request, env as never, {} as never);
    expect(response?.status).toBe(413);
    const body = (await response?.json()) as Record<string, unknown>;
    expect(body["request_id"]).toBeUndefined();
  });
});

describe("POST /v1/sync/operations — unexpected failure", () => {
  it("answers a content-free 500 and says nothing about the cause", async () => {
    // A storage double that throws a plain Error rather than an ApiError. The
    // production path is untouched: only the binding handed to the route is
    // synthetic, and the throw happens inside device authentication.
    const SENTINEL = "storage exploded at line 42 while running SELECT token_hash";
    const brokenEnv = {
      DB: {
        prepare(): never {
          throw new Error(SENTINEL);
        },
      },
    };
    const request = new Request(`https://example.test${PATH}`, {
      method: "POST",
      headers: new Headers({ Authorization: `Device ${TOKEN}` }),
      body: JSON.stringify(patchRoom()),
    });

    // The exported worker resolves its own bindings, so the double has to be
    // handed to the route function itself.
    const response = await handleOperationRequest(request, brokenEnv as unknown as Env);
    expect(response.status).toBe(500);
    const body = (await response.json()) as Record<string, unknown>;
    expect(body["error"]).toEqual({ code: "INTERNAL_ERROR", retryable: false });
    expect(body["request_id"]).toBeUndefined();

    const serialised = JSON.stringify(body);
    expect(serialised).not.toContain(SENTINEL);
    expect(serialised).not.toContain("exploded");
    expect(serialised).not.toContain("line 42");
    expectContentFree(serialised);
  });
});

describe("routing", () => {
  it("keeps the health endpoint unchanged", async () => {
    const response = await call({ method: "GET", path: "/v1/health", token: null });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, protocol_version: 1 });
  });

  it("refuses the operation path with the wrong method", async () => {
    const response = await call({ method: "GET" });
    expect(response.status).toBe(404);
    const body = await bodyOf(response);
    expect(body["request_id"]).toBeUndefined();
    expect((body["error"] as Record<string, unknown>)["code"]).toBe("NOT_FOUND");
  });

  it("refuses an unknown path", async () => {
    const response = await call({ path: "/v1/sync/nope", body: patchRoom() });
    expect(response.status).toBe(404);
    expect((await bodyOf(response))["request_id"]).toBeUndefined();
  });

  it("does not consume the body twice", async () => {
    // A body that can be read exactly once: a second read would throw and the
    // route would answer 500 instead of applying the operation.
    const encoded = new TextEncoder().encode(JSON.stringify(patchRoom()));
    let pulls = 0;
    const stream = new ReadableStream<Uint8Array>({
      pull(controller) {
        pulls += 1;
        controller.enqueue(encoded);
        controller.close();
      },
    });
    const request = new Request(`https://example.test${PATH}`, {
      method: "POST",
      headers: new Headers({ Authorization: `Device ${TOKEN}` }),
      body: stream,
      // @ts-expect-error duplex is required for a streaming request body
      duplex: "half",
    }) as unknown as WorkerRequest;
    const response = await worker.fetch?.(request, env as never, {} as never);
    expect(response?.status).toBe(200);
    expect(pulls).toBe(1);
  });
});
