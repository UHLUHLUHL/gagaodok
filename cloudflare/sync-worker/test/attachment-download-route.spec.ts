import { applyD1Migrations, env } from "cloudflare:test";
import { exports } from "cloudflare:workers";
import type { D1Migration } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { handleAttachmentDownload } from "../src/routes/attachments";
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
const bucket = env.ATTACHMENTS;
const worker = (exports as { default: ExportedHandler }).default;
type WorkerRequest = Parameters<NonNullable<ExportedHandler["fetch"]>>[0];

// Synthetic fixtures only.
const ACCOUNT = "A0000000-0000-4000-8000-00000000000A";
const OTHER_ACCOUNT = "A0000000-0000-4000-8000-00000000000B";
const MAC_DEVICE = "B0000000-0000-4000-8000-000000000001";
const PHONE_DEVICE = "B0000000-0000-4000-8000-000000000002";
const TABLET_DEVICE = "B0000000-0000-4000-8000-000000000005";
const REVOKED_DEVICE = "B0000000-0000-4000-8000-000000000003";
const OTHER_ACCOUNT_DEVICE = "B0000000-0000-4000-8000-000000000004";
const READY = "70000000-0000-4000-8000-0000000000B1";
const UPLOADED = "70000000-0000-4000-8000-0000000000B2";
const ALLOCATED = "70000000-0000-4000-8000-0000000000B3";
const FOREIGN_READY = "70000000-0000-4000-8000-0000000000B4";
const MISSING = "70000000-0000-4000-8000-0000000000B5";
const TIMESTAMP = "2026-08-29T00:00:00Z";

const SOURCE_BYTES = 5;
const CIPHERTEXT_BYTES = SOURCE_BYTES + 34;

function objectKeyOf(suffix: string): string {
  return `obj/E0000000-0000-4000-8000-0000000000${suffix}`;
}
const KEYS: Record<string, string> = {
  [READY]: objectKeyOf("01"),
  [UPLOADED]: objectKeyOf("02"),
  [ALLOCATED]: objectKeyOf("03"),
  [FOREIGN_READY]: objectKeyOf("04"),
};

function ciphertext(seed: number): Uint8Array {
  const bytes = new Uint8Array(CIPHERTEXT_BYTES);
  for (let index = 0; index < bytes.length; index += 1) bytes[index] = (seed * 31 + index) & 0xff;
  return bytes;
}

function syntheticTokenBytes(seed: number): Uint8Array {
  const bytes = new Uint8Array(32);
  for (let index = 0; index < bytes.length; index += 1) bytes[index] = (seed + index) & 0xff;
  return bytes;
}
function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}
async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes as BufferSource);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

const MAC_TOKEN = `gdt1_${base64Url(syntheticTokenBytes(1))}`;
const PHONE_TOKEN = `gdt1_${base64Url(syntheticTokenBytes(33))}`;
const TABLET_TOKEN = `gdt1_${base64Url(syntheticTokenBytes(129))}`;
const REVOKED_TOKEN = `gdt1_${base64Url(syntheticTokenBytes(65))}`;
const OTHER_ACCOUNT_TOKEN = `gdt1_${base64Url(syntheticTokenBytes(97))}`;
const UNKNOWN_TOKEN = `gdt1_${base64Url(syntheticTokenBytes(161))}`;

interface CallInit {
  attachmentId?: string;
  path?: string;
  method?: string;
  token?: string | null;
  range?: string;
}

function requestFor(init: CallInit): Request {
  const headers = new Headers();
  if (init.token !== null) {
    headers.set("Authorization", `Device ${init.token ?? MAC_TOKEN}`);
  }
  if (init.range !== undefined) {
    headers.set("Range", init.range);
  }
  const path = init.path ?? `/v1/attachments/${init.attachmentId ?? READY}/content`;
  return new Request(`https://example.test${path}`, { method: init.method ?? "GET", headers });
}

async function call(init: CallInit = {}): Promise<Response> {
  const response = await worker.fetch?.(
    requestFor(init) as unknown as WorkerRequest,
    env as never,
    {} as never,
  );
  if (response === undefined) throw new Error("worker did not return a response");
  return response;
}

function expectContentFree(serialised: string): void {
  for (const leak of ["obj/", "gdt1_", MAC_TOKEN, "SELECT", "UPDATE", "stack", "message"]) {
    expect(serialised, `response leaked ${leak}`).not.toContain(leak);
  }
}

async function errorOf(response: Response): Promise<Record<string, unknown>> {
  const body = (await response.json()) as Record<string, unknown>;
  expect(body["request_id"]).toBeUndefined();
  expectContentFree(JSON.stringify(body));
  return body["error"] as Record<string, unknown>;
}

interface AttachmentFixture {
  attachmentId: string;
  state: string;
  accountId?: string;
  originSpace?: string;
}

async function insertAttachment(fixture: AttachmentFixture): Promise<void> {
  await db
    .prepare(
      `INSERT INTO attachment
         (account_id, attachment_id, origin_space_id, r2_object_key, kind, state,
          source_byte_size, ciphertext_byte_size, ciphertext_hash, key_generation,
          file_name_enc, mime_type_enc, wrapped_file_key_enc, created_at, server_seq)
       VALUES (?, ?, ?, ?, 'attachment', ?, ?, ?, ?, 1, 'e1', 'e2', 'e3', ?, NULL)`,
    )
    .bind(
      fixture.accountId ?? ACCOUNT,
      fixture.attachmentId,
      fixture.originSpace ?? "MAC_SPACE",
      KEYS[fixture.attachmentId] ?? objectKeyOf("99"),
      fixture.state,
      SOURCE_BYTES,
      CIPHERTEXT_BYTES,
      await sha256Hex(ciphertext(1)),
      TIMESTAMP,
    )
    .run();
}

beforeAll(async () => {
  await applyD1Migrations(db, env.TEST_MIGRATIONS);
});

beforeEach(async () => {
  const listed = await bucket.list();
  if (listed.objects.length > 0) {
    await bucket.delete(listed.objects.map((object) => object.key));
  }
  for (const table of ["transaction_guard", "change_log", "operation_log", "attachment", "device", "account"]) {
    await db.prepare(`DELETE FROM ${table}`).run();
  }
  for (const accountId of [ACCOUNT, OTHER_ACCOUNT]) {
    await db
      .prepare("INSERT INTO account (account_id, created_at) VALUES (?, ?)")
      .bind(accountId, TIMESTAMP)
      .run();
  }
  for (const [accountId, deviceId, space, platform, seed, revokedAt] of [
    [ACCOUNT, MAC_DEVICE, "MAC_SPACE", "macos", 1, null],
    [ACCOUNT, PHONE_DEVICE, "PHONE_SPACE", "android_phone", 33, null],
    [ACCOUNT, TABLET_DEVICE, "TABLET_SPACE", "android_tablet", 129, null],
    [ACCOUNT, REVOKED_DEVICE, "MAC_SPACE", "macos", 65, TIMESTAMP],
    [OTHER_ACCOUNT, OTHER_ACCOUNT_DEVICE, "MAC_SPACE", "macos", 97, null],
  ] as const) {
    await db
      .prepare(
        `INSERT INTO device
           (account_id, device_id, space_id, platform, display_name_enc,
            linked_at, revoked_at, key_generation, token_hash)
         VALUES (?, ?, ?, ?, NULL, ?, ?, 1, ?)`,
      )
      .bind(accountId, deviceId, space, platform, TIMESTAMP, revokedAt, await sha256Hex(syntheticTokenBytes(seed)))
      .run();
  }

  await insertAttachment({ attachmentId: READY, state: "ready" });
  await insertAttachment({ attachmentId: UPLOADED, state: "uploaded" });
  await insertAttachment({ attachmentId: ALLOCATED, state: "allocated" });
  await insertAttachment({ attachmentId: FOREIGN_READY, state: "ready", accountId: OTHER_ACCOUNT });

  for (const attachmentId of [READY, UPLOADED, FOREIGN_READY]) {
    await bucket.put(KEYS[attachmentId] as string, ciphertext(1));
  }
});

describe("GET /v1/attachments/{id}/content — the ready object", () => {
  it("streams the stored ciphertext with the metadata's own headers", async () => {
    const response = await call({ attachmentId: READY });

    expect(response.status).toBe(200);
    expect(response.headers.get("Content-Type")).toBe("application/octet-stream");
    expect(response.headers.get("Content-Length")).toBe(String(CIPHERTEXT_BYTES));
    expect(response.headers.get("Cache-Control")).toBe("private, no-store");
    expect([...new Uint8Array(await response.arrayBuffer())]).toEqual([...ciphertext(1)]);
  });

  it("returns no ETag, R2 metadata or object key", async () => {
    const response = await call({ attachmentId: READY });
    expect(response.headers.get("ETag")).toBeNull();
    const headers = JSON.stringify([...response.headers]);
    expect(headers).not.toContain("obj/");
    expect(headers).not.toContain("etag");
    expectContentFree(headers);
    await response.arrayBuffer();
  });

  it("serves every linked device of the account, whatever space it is in", async () => {
    for (const token of [MAC_TOKEN, PHONE_TOKEN, TABLET_TOKEN]) {
      const response = await call({ attachmentId: READY, token });
      // The attachment's origin is MAC_SPACE; download is account-scoped.
      expect(response.status).toBe(200);
      expect([...new Uint8Array(await response.arrayBuffer())]).toEqual([...ciphertext(1)]);
    }
  });
});

describe("GET /v1/attachments/{id}/content — identity and authentication", () => {
  it("refuses unknown, missing and revoked tokens", async () => {
    expect((await call({ attachmentId: READY, token: UNKNOWN_TOKEN })).status).toBe(401);
    expect((await call({ attachmentId: READY, token: null })).status).toBe(401);
    expect((await call({ attachmentId: READY, token: REVOKED_TOKEN })).status).toBe(403);
  });

  it("answers the same 404 for a missing row and another account's ready attachment", async () => {
    const missing = await call({ attachmentId: MISSING });
    const foreign = await call({ attachmentId: FOREIGN_READY });
    expect(missing.status).toBe(404);
    expect(foreign.status).toBe(404);
    expect(await errorOf(missing)).toEqual(await errorOf(foreign));
  });

  it("does not serve this account's attachment to another account's device", async () => {
    const response = await call({ attachmentId: READY, token: OTHER_ACCOUNT_TOKEN });
    expect(response.status).toBe(404);
  });

  it("refuses a non-canonical id, an extra segment and the wrong method", async () => {
    for (const path of [
      "/v1/attachments/not-a-uuid/content",
      `/v1/attachments/${READY.toLowerCase()}/content`,
      `/v1/attachments/${READY}/content/extra`,
      `/v1/attachments/${READY}`,
    ]) {
      expect((await call({ path })).status, `accepted ${path}`).toBe(404);
    }
    for (const method of ["DELETE", "PATCH"]) {
      expect((await call({ attachmentId: READY, method })).status, `accepted ${method}`).toBe(404);
    }
  });
});

describe("GET /v1/attachments/{id}/content — states and storage", () => {
  it("refuses every state but ready", async () => {
    for (const [attachmentId, state] of [
      [UPLOADED, "uploaded"],
      [ALLOCATED, "allocated"],
    ] as const) {
      const response = await call({ attachmentId });
      expect(response.status, `served ${state}`).toBe(409);
      expect(await errorOf(response)).toEqual({
        code: "ATTACHMENT_STATE_CONFLICT",
        retryable: false,
      });
    }
    for (const state of ["abandoned", "tombstoned", "garbage_collected"]) {
      await db.prepare("UPDATE attachment SET state = ? WHERE attachment_id = ?").bind(state, ALLOCATED).run();
      expect((await call({ attachmentId: ALLOCATED })).status, `served ${state}`).toBe(409);
    }
  });

  it("refuses a Range request", async () => {
    const response = await call({ attachmentId: READY, range: "bytes=0-10" });
    expect(response.status).toBe(400);
    expect(await errorOf(response)).toEqual({ code: "VALIDATION_FAILED", retryable: false });
  });

  it("is a retryable storage failure when the object is missing", async () => {
    await bucket.delete(KEYS[READY] as string);
    const response = await call({ attachmentId: READY });
    expect(response.status).toBe(503);
    expect(await errorOf(response)).toEqual({ code: "STORAGE_UNAVAILABLE", retryable: true });
  });

  it("is a retryable storage failure when the stored size disagrees with the metadata", async () => {
    await bucket.put(KEYS[READY] as string, new Uint8Array(CIPHERTEXT_BYTES + 1));
    const response = await call({ attachmentId: READY });
    expect(response.status).toBe(503);
    expect((await errorOf(response))["code"]).toBe("STORAGE_UNAVAILABLE");
  });

  it("turns an R2 get failure into a content-free retryable error", async () => {
    const SENTINEL = "R2 exploded reading obj/ for gdt1_ token";
    const broken = {
      get(): never {
        throw new Error(SENTINEL);
      },
    };
    const response = await handleAttachmentDownload(
      requestFor({ attachmentId: READY }),
      { DB: db, ATTACHMENTS: broken as unknown as R2Bucket, CURSOR_MAC_KEY: "x" } as Env,
      READY,
    );
    expect(response.status).toBe(503);
    const serialised = JSON.stringify(await response.json());
    expect(serialised).not.toContain(SENTINEL);
    expectContentFree(serialised);
  });
});
