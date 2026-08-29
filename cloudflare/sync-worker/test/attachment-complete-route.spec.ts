import { applyD1Migrations, env } from "cloudflare:test";
import { exports } from "cloudflare:workers";
import type { D1Migration } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { handleAttachmentComplete } from "../src/routes/attachments";
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
const REVOKED_DEVICE = "B0000000-0000-4000-8000-000000000003";
const OTHER_ACCOUNT_DEVICE = "B0000000-0000-4000-8000-000000000004";
const UPLOADED = "70000000-0000-4000-8000-00000000FA01";
const READY = "70000000-0000-4000-8000-00000000FA02";
const ALLOCATED = "70000000-0000-4000-8000-00000000FA03";
const TOMBSTONED = "70000000-0000-4000-8000-00000000FA04";
const PHONE_ORIGIN = "70000000-0000-4000-8000-00000000FA05";
const FOREIGN = "70000000-0000-4000-8000-00000000FA06";
const MISSING = "70000000-0000-4000-8000-00000000FA07";
const TIMESTAMP = "2026-08-29T00:00:00Z";

const SOURCE_BYTES = 5;
const CIPHERTEXT_BYTES = SOURCE_BYTES + 34;

function objectKeyOf(suffix: string): string {
  return `obj/D0000000-0000-4000-8000-0000000000${suffix}`;
}

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
const REVOKED_TOKEN = `gdt1_${base64Url(syntheticTokenBytes(65))}`;
const OTHER_ACCOUNT_TOKEN = `gdt1_${base64Url(syntheticTokenBytes(97))}`;
const UNKNOWN_TOKEN = `gdt1_${base64Url(syntheticTokenBytes(129))}`;

const KEYS: Record<string, string> = {
  [UPLOADED]: objectKeyOf("01"),
  [READY]: objectKeyOf("02"),
  [ALLOCATED]: objectKeyOf("03"),
  [TOMBSTONED]: objectKeyOf("04"),
  [PHONE_ORIGIN]: objectKeyOf("05"),
  [FOREIGN]: objectKeyOf("06"),
};

interface CallInit {
  attachmentId?: string;
  path?: string;
  method?: string;
  token?: string | null;
  body?: Uint8Array | string | null;
}

function requestFor(init: CallInit): Request {
  const headers = new Headers();
  if (init.token !== null) {
    headers.set("Authorization", `Device ${init.token ?? MAC_TOKEN}`);
  }
  const path = init.path ?? `/v1/attachments/${init.attachmentId ?? UPLOADED}/complete`;
  return new Request(`https://example.test${path}`, {
    method: init.method ?? "POST",
    headers,
    body: (init.body ?? null) as BodyInit | null,
  });
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

/** No key, token, SQL, stack or ciphertext may reach a client. */
function expectContentFree(serialised: string): void {
  for (const leak of ["obj/", "gdt1_", MAC_TOKEN, "SELECT", "UPDATE", "INSERT", "stack", "message"]) {
    expect(serialised, `response leaked ${leak}`).not.toContain(leak);
  }
}

async function errorOf(response: Response): Promise<Record<string, unknown>> {
  const body = (await response.json()) as Record<string, unknown>;
  expect(body["request_id"], "an HTTP transition has no operation id").toBeUndefined();
  expectContentFree(JSON.stringify(body));
  return body["error"] as Record<string, unknown>;
}

interface AttachmentFixture {
  attachmentId: string;
  state: string;
  accountId?: string;
  originSpace?: string;
  serverSeq?: number | null;
}

async function insertAttachment(fixture: AttachmentFixture): Promise<void> {
  await db
    .prepare(
      `INSERT INTO attachment
         (account_id, attachment_id, origin_space_id, r2_object_key, kind, state,
          source_byte_size, ciphertext_byte_size, ciphertext_hash, key_generation,
          file_name_enc, mime_type_enc, wrapped_file_key_enc, created_at, server_seq)
       VALUES (?, ?, ?, ?, 'attachment', ?, ?, ?, ?, 1, 'e1', 'e2', 'e3', ?, ?)`,
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
      fixture.serverSeq ?? null,
    )
    .run();
}

interface AttachmentState {
  state: string;
  server_seq: number | null;
}

async function rowOf(attachmentId: string, accountId = ACCOUNT): Promise<AttachmentState | null> {
  return await db
    .prepare("SELECT state, server_seq FROM attachment WHERE account_id = ? AND attachment_id = ?")
    .bind(accountId, attachmentId)
    .first<AttachmentState>();
}

async function countOf(table: string): Promise<number> {
  const row = await db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).first<{ n: number }>();
  return row?.n ?? 0;
}

async function nextServerSeq(): Promise<number> {
  const row = await db
    .prepare("SELECT next_server_seq AS n FROM account WHERE account_id = ?")
    .bind(ACCOUNT)
    .first<{ n: number }>();
  return row?.n ?? 0;
}

async function ledgerSnapshot(): Promise<Record<string, number>> {
  return {
    next_server_seq: await nextServerSeq(),
    change_log: await countOf("change_log"),
    operation_log: await countOf("operation_log"),
    transaction_guard: await countOf("transaction_guard"),
  };
}

beforeAll(async () => {
  await applyD1Migrations(db, env.TEST_MIGRATIONS);
});

beforeEach(async () => {
  const listed = await bucket.list();
  if (listed.objects.length > 0) {
    await bucket.delete(listed.objects.map((object) => object.key));
  }
  for (const table of [
    "transaction_guard",
    "change_log",
    "operation_log",
    "attachment",
    "device",
    "account",
  ]) {
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

  await insertAttachment({ attachmentId: UPLOADED, state: "uploaded" });
  await insertAttachment({ attachmentId: READY, state: "ready", serverSeq: 1 });
  await insertAttachment({ attachmentId: ALLOCATED, state: "allocated" });
  await insertAttachment({ attachmentId: TOMBSTONED, state: "tombstoned", serverSeq: 1 });
  await insertAttachment({ attachmentId: PHONE_ORIGIN, state: "uploaded", originSpace: "PHONE_SPACE" });
  await insertAttachment({ attachmentId: FOREIGN, state: "uploaded", accountId: OTHER_ACCOUNT });

  // Every uploaded fixture has its object in place.
  for (const attachmentId of [UPLOADED, READY, PHONE_ORIGIN, FOREIGN]) {
    await bucket.put(KEYS[attachmentId] as string, ciphertext(1));
  }
});

describe("POST /v1/attachments/{id}/complete — the ready transition", () => {
  it("verifies the object, flips to ready and files exactly one change event", async () => {
    const before = await ledgerSnapshot();

    const response = await call({ attachmentId: UPLOADED });

    expect(response.status).toBe(204);
    expect(await response.text()).toBe("");
    const row = await rowOf(UPLOADED);
    expect(row?.state).toBe("ready");
    expect(row?.server_seq).toBe(before["next_server_seq"]);

    const after = await ledgerSnapshot();
    expect(after["next_server_seq"]).toBe((before["next_server_seq"] as number) + 1);
    expect(after["change_log"]).toBe((before["change_log"] as number) + 1);
    // An HTTP transition has no client operation id to answer replays with.
    expect(after["operation_log"]).toBe(before["operation_log"]);
    // The guard exists only for the length of the batch.
    expect(after["transaction_guard"]).toBe(0);
  });

  it("files the attachment change event with only the attachment axis set", async () => {
    await call({ attachmentId: UPLOADED });

    const event = await db
      .prepare(
        `SELECT entity_type, change_kind, revision, attachment_id, space_id, room_id,
                worldline_key, turn_id, message_id, persona_snapshot_id, snapshot_revision,
                engine_profile_id, profile_revision, checkpoint_id, server_seq
           FROM change_log`,
      )
      .first<Record<string, unknown>>();

    expect(event).toEqual({
      entity_type: "attachment",
      change_kind: "upsert",
      revision: null,
      attachment_id: UPLOADED,
      space_id: null,
      room_id: null,
      worldline_key: null,
      turn_id: null,
      message_id: null,
      persona_snapshot_id: null,
      snapshot_revision: null,
      engine_profile_id: null,
      profile_revision: null,
      checkpoint_id: null,
      server_seq: 1,
    });
  });

  it("is idempotent once ready", async () => {
    await call({ attachmentId: UPLOADED });
    const after = await ledgerSnapshot();
    const stored = await bucket.get(KEYS[UPLOADED] as string);
    const bytes = [...new Uint8Array(await stored!.arrayBuffer())];

    const response = await call({ attachmentId: UPLOADED });

    expect(response.status).toBe(204);
    // No second sequence, no duplicate event, and R2 untouched.
    expect(await ledgerSnapshot()).toEqual(after);
    const again = await bucket.get(KEYS[UPLOADED] as string);
    expect([...new Uint8Array(await again!.arrayBuffer())]).toEqual(bytes);
  });

  it("consumes one sequence and one event when two completes race", async () => {
    const before = await ledgerSnapshot();

    const responses = await Promise.all([
      call({ attachmentId: UPLOADED }),
      call({ attachmentId: UPLOADED }),
    ]);

    for (const response of responses) {
      expect(response.status).toBe(204);
    }
    const after = await ledgerSnapshot();
    expect(after["next_server_seq"]).toBe((before["next_server_seq"] as number) + 1);
    expect(after["change_log"]).toBe(1);
    expect(after["transaction_guard"]).toBe(0);
    expect((await rowOf(UPLOADED))?.state).toBe("ready");
  });
});

describe("POST /v1/attachments/{id}/complete — routing", () => {
  it("refuses a non-canonical id, an extra segment and the wrong method", async () => {
    for (const path of [
      "/v1/attachments/not-a-uuid/complete",
      `/v1/attachments/${UPLOADED.toLowerCase()}/complete`,
      `/v1/attachments/${UPLOADED}/complete/extra`,
      `/v1/attachments/${UPLOADED}`,
      "/v1/attachments/complete",
    ]) {
      const response = await call({ path });
      expect(response.status, `accepted ${path}`).toBe(404);
    }
    for (const method of ["PUT", "DELETE", "PATCH"]) {
      const response = await call({ attachmentId: UPLOADED, method });
      expect(response.status, `accepted ${method}`).toBe(404);
      expect((await errorOf(response))["code"]).toBe("NOT_FOUND");
    }
    expect((await rowOf(UPLOADED))?.state).toBe("uploaded");
  });

  it("refuses a request that carries a body", async () => {
    // A real client that sends a body declares its length, and that is the
    // signal the handler refuses on. A body with no declared length cannot be
    // told apart from the empty stream a bodyless POST arrives as.
    const headers = new Headers({ Authorization: `Device ${MAC_TOKEN}`, "Content-Length": "2" });
    const request = new Request(`https://example.test/v1/attachments/${UPLOADED}/complete`, {
      method: "POST",
      headers,
      body: "{}",
    });
    const response = await handleAttachmentComplete(request, env as unknown as Env, UPLOADED);
    expect(response.status).toBe(400);
    expect((await errorOf(response))["code"]).toBe("VALIDATION_FAILED");
    // The body is refused, never parsed.
    expect(request.bodyUsed).toBe(false);
    expect((await rowOf(UPLOADED))?.state).toBe("uploaded");
  });

  it("accepts a bodyless request with an explicit zero length", async () => {
    const headers = new Headers({ Authorization: `Device ${MAC_TOKEN}`, "Content-Length": "0" });
    const request = new Request(`https://example.test/v1/attachments/${UPLOADED}/complete`, {
      method: "POST",
      headers,
    });
    const response = await handleAttachmentComplete(request, env as unknown as Env, UPLOADED);
    expect(response.status).toBe(204);
  });
});

describe("POST /v1/attachments/{id}/complete — authentication", () => {
  it("refuses unknown and revoked tokens", async () => {
    expect((await call({ attachmentId: UPLOADED, token: UNKNOWN_TOKEN })).status).toBe(401);
    expect((await call({ attachmentId: UPLOADED, token: null })).status).toBe(401);
    expect((await call({ attachmentId: UPLOADED, token: REVOKED_TOKEN })).status).toBe(403);
    expect((await rowOf(UPLOADED))?.state).toBe("uploaded");
  });

  it("answers the same 404 for a missing row and another account's attachment", async () => {
    const missing = await call({ attachmentId: MISSING });
    const foreign = await call({ attachmentId: FOREIGN });
    expect(missing.status).toBe(404);
    expect(foreign.status).toBe(404);
    expect(await errorOf(missing)).toEqual(await errorOf(foreign));
    expect((await rowOf(FOREIGN, OTHER_ACCOUNT))?.state).toBe("uploaded");
  });

  it("requires the origin-space device", async () => {
    const response = await call({ attachmentId: PHONE_ORIGIN, token: MAC_TOKEN });
    expect(response.status).toBe(401);
    expect(await errorOf(response)).toEqual({ code: "AUTH_INVALID", retryable: false });
    expect((await rowOf(PHONE_ORIGIN))?.state).toBe("uploaded");

    const allowed = await call({ attachmentId: PHONE_ORIGIN, token: PHONE_TOKEN });
    expect(allowed.status).toBe(204);
    expect((await rowOf(PHONE_ORIGIN))?.state).toBe("ready");
  });

  it("does not let another account's device complete its own attachment through this account", async () => {
    const response = await call({ attachmentId: UPLOADED, token: OTHER_ACCOUNT_TOKEN });
    expect(response.status).toBe(404);
    expect((await rowOf(UPLOADED))?.state).toBe("uploaded");
  });
});

describe("POST /v1/attachments/{id}/complete — states and storage", () => {
  it("refuses allocated, abandoned, tombstoned and garbage_collected", async () => {
    for (const state of ["allocated", "abandoned", "tombstoned", "garbage_collected"]) {
      await db
        .prepare("UPDATE attachment SET state = ? WHERE attachment_id = ?")
        .bind(state, ALLOCATED)
        .run();
      const response = await call({ attachmentId: ALLOCATED });
      expect(response.status, `accepted ${state}`).toBe(409);
      expect(await errorOf(response)).toEqual({
        code: "ATTACHMENT_STATE_CONFLICT",
        retryable: false,
      });
    }
    expect(await countOf("change_log")).toBe(0);
  });

  it("is a retryable storage failure when the object is missing", async () => {
    await bucket.delete(KEYS[UPLOADED] as string);
    const before = await ledgerSnapshot();

    const response = await call({ attachmentId: UPLOADED });

    expect(response.status).toBe(503);
    expect(await errorOf(response)).toEqual({ code: "STORAGE_UNAVAILABLE", retryable: true });
    // Nothing is told it can be read, and nothing moved.
    expect((await rowOf(UPLOADED))?.state).toBe("uploaded");
    expect(await ledgerSnapshot()).toEqual(before);
  });

  it("is a retryable storage failure when the stored size disagrees", async () => {
    await bucket.put(KEYS[UPLOADED] as string, new Uint8Array(CIPHERTEXT_BYTES - 1));
    const response = await call({ attachmentId: UPLOADED });
    expect(response.status).toBe(503);
    expect((await errorOf(response))["code"]).toBe("STORAGE_UNAVAILABLE");
    expect((await rowOf(UPLOADED))?.state).toBe("uploaded");
  });

  it("refuses without retry when the sequence is exhausted, and changes nothing", async () => {
    await db
      .prepare("UPDATE account SET next_server_seq = ? WHERE account_id = ?")
      .bind(9007199254740992, ACCOUNT)
      .run();
    const before = await ledgerSnapshot();

    const response = await call({ attachmentId: UPLOADED });

    expect(response.status).toBe(503);
    expect(await errorOf(response)).toEqual({ code: "STORAGE_UNAVAILABLE", retryable: false });
    expect(await ledgerSnapshot()).toEqual(before);
    expect((await rowOf(UPLOADED))?.state).toBe("uploaded");
  });

  it("turns an R2 head failure into a content-free retryable error", async () => {
    const SENTINEL = "R2 exploded reading obj/ for gdt1_ token";
    const broken = {
      head(): never {
        throw new Error(SENTINEL);
      },
    };
    const response = await handleAttachmentComplete(
      requestFor({ attachmentId: UPLOADED }),
      { DB: db, ATTACHMENTS: broken as unknown as R2Bucket, CURSOR_MAC_KEY: "x" } as Env,
      UPLOADED,
    );
    expect(response.status).toBe(503);
    const serialised = JSON.stringify(await response.json());
    expect(serialised).not.toContain(SENTINEL);
    expectContentFree(serialised);
    expect((await rowOf(UPLOADED))?.state).toBe("uploaded");
  });

  it("turns a D1 batch failure into a content-free retryable error and leaves no guard", async () => {
    const SENTINEL = "D1 exploded during INSERT INTO transaction_guard";
    const brokenDb = {
      prepare: db.prepare.bind(db),
      batch(): never {
        throw new Error(SENTINEL);
      },
    };
    const before = await ledgerSnapshot();
    const response = await handleAttachmentComplete(
      requestFor({ attachmentId: UPLOADED }),
      { DB: brokenDb as unknown as D1Database, ATTACHMENTS: bucket, CURSOR_MAC_KEY: "x" } as Env,
      UPLOADED,
    );
    expect(response.status).toBe(503);
    const serialised = JSON.stringify(await response.json());
    expect(serialised).not.toContain(SENTINEL);
    expectContentFree(serialised);
    expect(await ledgerSnapshot()).toEqual(before);
  });
});

describe("POST /v1/attachments/{id}/complete — a real bodyless request", () => {
  it("accepts the shape a real HTTP client sends", async () => {
    // Over the wire a bodyless POST does not arrive with `body === null`: the
    // runtime hands the handler an empty stream and, when the client declared
    // one, a `Content-Length: 0`. A locally constructed Request has a null
    // body, which is why this shape has to be built explicitly.
    const empty = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.close();
      },
    });
    const request = new Request(`https://example.test/v1/attachments/${UPLOADED}/complete`, {
      method: "POST",
      headers: new Headers({ Authorization: `Device ${MAC_TOKEN}`, "Content-Length": "0" }),
      body: empty,
      // @ts-expect-error duplex is required for a streaming request body
      duplex: "half",
    });
    expect(request.body, "the fixture must not have a null body").not.toBeNull();

    const response = await handleAttachmentComplete(request, env as unknown as Env, UPLOADED);

    expect(response.status).toBe(204);
    expect((await rowOf(UPLOADED))?.state).toBe("ready");
  });
});
