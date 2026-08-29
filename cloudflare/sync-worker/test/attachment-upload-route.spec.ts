import { applyD1Migrations, env } from "cloudflare:test";
import { exports } from "cloudflare:workers";
import type { D1Migration } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { handleAttachmentUpload } from "../src/routes/attachments";
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

// Synthetic fixtures only. No real account, device, token or object exists.
const ACCOUNT = "A0000000-0000-4000-8000-00000000000A";
const OTHER_ACCOUNT = "A0000000-0000-4000-8000-00000000000B";
const MAC_DEVICE = "B0000000-0000-4000-8000-000000000001";
const PHONE_DEVICE = "B0000000-0000-4000-8000-000000000002";
const REVOKED_DEVICE = "B0000000-0000-4000-8000-000000000003";
const OTHER_ACCOUNT_DEVICE = "B0000000-0000-4000-8000-000000000004";
const ALLOCATED = "70000000-0000-4000-8000-00000000EA01";
const UPLOADED = "70000000-0000-4000-8000-00000000EA02";
const READY = "70000000-0000-4000-8000-00000000EA03";
const TOMBSTONED = "70000000-0000-4000-8000-00000000EA04";
const PHONE_ORIGIN = "70000000-0000-4000-8000-00000000EA05";
const FOREIGN = "70000000-0000-4000-8000-00000000EA06";
const MISSING = "70000000-0000-4000-8000-00000000EA07";
const TIMESTAMP = "2026-08-29T00:00:00Z";

/** Server-generated keys: 'obj/' plus a canonical uppercase UUID (0006 CHECK). */
function objectKeyOf(suffix: string): string {
  return `obj/C0000000-0000-4000-8000-0000000000${suffix}`;
}

const SOURCE_BYTES = 5;
/** v1 encrypts an attachment as one AEAD message with 34 bytes of overhead. */
const CIPHERTEXT_BYTES = SOURCE_BYTES + 34;
const MAX_CIPHERTEXT_BYTES = 12_582_946;

function ciphertext(seed: number): Uint8Array {
  const bytes = new Uint8Array(CIPHERTEXT_BYTES);
  for (let index = 0; index < bytes.length; index += 1) {
    bytes[index] = (seed * 31 + index) & 0xff;
  }
  return bytes;
}

/** Each fixture attachment has one ciphertext, because its stored SHA-256
 * now decides which bytes R2 will accept for it. */
const BODIES = new Map<string, Uint8Array>();
function bodyFor(attachmentId: string): Uint8Array {
  const existing = BODIES.get(attachmentId);
  if (existing !== undefined) {
    return existing;
  }
  const body = ciphertext(attachmentId.charCodeAt(attachmentId.length - 1));
  BODIES.set(attachmentId, body);
  return body;
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

function pathOf(attachmentId: string): string {
  return `/v1/attachments/${attachmentId}/content`;
}

interface CallInit {
  attachmentId?: string;
  path?: string;
  method?: string;
  token?: string | null;
  body?: Uint8Array | null;
  contentLength?: string | null;
}

/** Build the request separately so a test can inspect it after the call. */
function requestFor(init: CallInit): Request {
  const headers = new Headers();
  if (init.token !== null) {
    headers.set("Authorization", `Device ${init.token ?? MAC_TOKEN}`);
  }
  const body =
    init.body === undefined ? bodyFor(init.attachmentId ?? ALLOCATED) : init.body;
  if (init.contentLength !== null) {
    headers.set(
      "Content-Length",
      init.contentLength ?? String(body === null ? 0 : body.byteLength),
    );
  }
  return new Request(`https://example.test${init.path ?? pathOf(init.attachmentId ?? ALLOCATED)}`, {
    method: init.method ?? "PUT",
    headers,
    body: body as BodyInit | null,
  });
}

async function call(init: CallInit = {}): Promise<Response> {
  const response = await worker.fetch?.(
    requestFor(init) as unknown as WorkerRequest,
    env as never,
    {} as never,
  );
  if (response === undefined) {
    throw new Error("worker did not return a response");
  }
  return response;
}

async function errorOf(response: Response): Promise<Record<string, unknown>> {
  const body = (await response.json()) as Record<string, unknown>;
  expect(body["request_id"], "an HTTP transition has no operation id").toBeUndefined();
  expectContentFree(JSON.stringify(body));
  return body["error"] as Record<string, unknown>;
}

/** No key, token, SQL, stack or ciphertext may reach a client. */
function expectContentFree(serialised: string): void {
  for (const leak of [
    "obj/",
    "gdt1_",
    MAC_TOKEN,
    "SELECT",
    "UPDATE",
    "attachment",
    "stack",
    "message",
  ]) {
    expect(serialised, `response leaked ${leak}`).not.toContain(leak);
  }
}

interface AttachmentFixture {
  attachmentId: string;
  state: string;
  objectKey: string;
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
      fixture.objectKey,
      fixture.state,
      SOURCE_BYTES,
      CIPHERTEXT_BYTES,
      // The hash the allocating operation would have recorded for this
      // attachment's one ciphertext. R2 compares against it on every upload.
      await sha256Hex(bodyFor(fixture.attachmentId)),
      TIMESTAMP,
    )
    .run();
}

async function stateOf(attachmentId: string, accountId = ACCOUNT): Promise<string | null> {
  const row = await db
    .prepare("SELECT state FROM attachment WHERE account_id = ? AND attachment_id = ?")
    .bind(accountId, attachmentId)
    .first<{ state: string }>();
  return row?.state ?? null;
}

async function objectBytes(key: string): Promise<number[] | null> {
  const object = await bucket.get(key);
  return object === null ? null : [...new Uint8Array(await object.arrayBuffer())];
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

/** A ledger snapshot, so a test can assert that nothing moved. */
async function ledgerSnapshot(): Promise<Record<string, number>> {
  return {
    next_server_seq: await nextServerSeq(),
    change_log: await countOf("change_log"),
    operation_log: await countOf("operation_log"),
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
      .bind(
        accountId,
        deviceId,
        space,
        platform,
        TIMESTAMP,
        revokedAt,
        await sha256Hex(syntheticTokenBytes(seed)),
      )
      .run();
  }

  await insertAttachment({ attachmentId: ALLOCATED, state: "allocated", objectKey: objectKeyOf("01") });
  await insertAttachment({ attachmentId: UPLOADED, state: "uploaded", objectKey: objectKeyOf("02") });
  await insertAttachment({ attachmentId: READY, state: "ready", objectKey: objectKeyOf("03") });
  await insertAttachment({ attachmentId: TOMBSTONED, state: "tombstoned", objectKey: objectKeyOf("04") });
  await insertAttachment({
    attachmentId: PHONE_ORIGIN,
    state: "allocated",
    objectKey: objectKeyOf("05"),
    originSpace: "PHONE_SPACE",
  });
  await insertAttachment({
    attachmentId: FOREIGN,
    state: "allocated",
    objectKey: objectKeyOf("06"),
    accountId: OTHER_ACCOUNT,
  });
});

describe("PUT /v1/attachments/{id}/content — the allocated upload", () => {
  it("stores the stream in R2, moves D1 to uploaded and answers 204", async () => {
    const before = await ledgerSnapshot();
    const body = bodyFor(ALLOCATED);

    const response = await call({ attachmentId: ALLOCATED, body });

    expect(response.status).toBe(204);
    expect(await response.text()).toBe("");
    expect(await stateOf(ALLOCATED)).toBe("uploaded");
    // Byte-for-byte: the Worker streams the envelope through untouched.
    expect(await objectBytes(objectKeyOf("01"))).toEqual([...body]);
    // A transfer-internal transition consumes no sequence and files no ledger
    // row, and an HTTP transition has no client operation id to log.
    expect(await ledgerSnapshot()).toEqual(before);
  });

  it("returns no key, ETag or metadata on success", async () => {
    const response = await call({ attachmentId: ALLOCATED });
    expect(response.status).toBe(204);
    expect(await response.text()).toBe("");
    expect(response.headers.get("ETag")).toBeNull();
    expectContentFree(JSON.stringify([...response.headers]));
  });
});

describe("PUT /v1/attachments/{id}/content — routing", () => {
  it("refuses a non-canonical attachment id", async () => {
    for (const bad of [
      "not-a-uuid",
      ALLOCATED.toLowerCase(),
      `${ALLOCATED}X`,
      "",
    ]) {
      const response = await call({ path: `/v1/attachments/${bad}/content` });
      expect(response.status, `accepted ${bad}`).toBe(404);
    }
  });

  it("refuses an extra or missing path segment", async () => {
    for (const path of [
      `/v1/attachments/${ALLOCATED}/content/extra`,
      `/v1/attachments/${ALLOCATED}`,
      `/v1/attachments/${ALLOCATED}/complete`,
      "/v1/attachments/content",
      `/v1/attachments/${ALLOCATED}/content/`,
    ]) {
      const response = await call({ path });
      expect(response.status, `accepted ${path}`).toBe(404);
    }
  });

  it("refuses an id smuggled through the query string", async () => {
    const response = await call({ path: `/v1/attachments/content?attachment_id=${ALLOCATED}` });
    expect(response.status).toBe(404);
    expect(await stateOf(ALLOCATED)).toBe("allocated");
  });

  it("refuses the content path with another method", async () => {
    for (const method of ["GET", "POST", "DELETE", "PATCH"]) {
      const response = await call({ attachmentId: ALLOCATED, method, body: null, contentLength: null });
      expect(response.status, `accepted ${method}`).toBe(404);
      expect((await errorOf(response))["code"]).toBe("NOT_FOUND");
    }
  });

  it("leaves the health and operation routes alone", async () => {
    const health = await worker.fetch?.(
      new Request("https://example.test/v1/health") as unknown as WorkerRequest,
      env as never,
      {} as never,
    );
    expect(health?.status).toBe(200);
  });
});

describe("PUT /v1/attachments/{id}/content — authentication", () => {
  it("refuses an unknown token", async () => {
    const response = await call({ attachmentId: ALLOCATED, token: UNKNOWN_TOKEN });
    expect(response.status).toBe(401);
    expect(await errorOf(response)).toEqual({ code: "AUTH_INVALID", retryable: false });
    expect(await stateOf(ALLOCATED)).toBe("allocated");
  });

  it("refuses a missing Authorization header", async () => {
    const response = await call({ attachmentId: ALLOCATED, token: null });
    expect(response.status).toBe(401);
  });

  it("refuses a revoked device", async () => {
    const response = await call({ attachmentId: ALLOCATED, token: REVOKED_TOKEN });
    expect(response.status).toBe(403);
    expect((await errorOf(response))["code"]).toBe("DEVICE_REVOKED");
  });

  it("answers the same 404 for a missing row and another account's attachment", async () => {
    const missing = await call({ attachmentId: MISSING });
    const foreign = await call({ attachmentId: FOREIGN });
    expect(missing.status).toBe(404);
    expect(foreign.status).toBe(404);
    expect(await errorOf(missing)).toEqual(await errorOf(foreign));
    // The other account's attachment is untouched, so the 404 was not a write.
    expect(await stateOf(FOREIGN, OTHER_ACCOUNT)).toBe("allocated");
    expect(await objectBytes(objectKeyOf("06"))).toBeNull();
  });

  it("refuses a device registered in another space than the attachment's origin", async () => {
    const response = await call({ attachmentId: PHONE_ORIGIN, token: MAC_TOKEN });
    expect(response.status).toBe(401);
    // The bare code: naming the expected space would map the account's devices.
    expect(await errorOf(response)).toEqual({ code: "AUTH_INVALID", retryable: false });
    expect(await stateOf(PHONE_ORIGIN)).toBe("allocated");
    expect(await objectBytes(objectKeyOf("05"))).toBeNull();
  });

  it("accepts the origin-space device for the same attachment", async () => {
    const response = await call({ attachmentId: PHONE_ORIGIN, token: PHONE_TOKEN });
    expect(response.status).toBe(204);
    expect(await stateOf(PHONE_ORIGIN)).toBe("uploaded");
  });
});

describe("PUT /v1/attachments/{id}/content — Content-Length", () => {
  it("requires a declared length", async () => {
    const request = requestFor({ attachmentId: ALLOCATED, contentLength: null });
    // A body built from bytes carries no automatic Content-Length here.
    expect(request.headers.get("Content-Length")).toBeNull();
    const response = await handleAttachmentUpload(request, env as unknown as Env, ALLOCATED);
    expect(response.status).toBe(400);
    expect((await errorOf(response))["code"]).toBe("VALIDATION_FAILED");
    expect(request.bodyUsed, "the body must not be read").toBe(false);
  });

  it("requires one canonical decimal spelling", async () => {
    // Leading and trailing OWS never reaches the validator: the Headers API
    // trims a header value before it is stored, exactly as HTTP requires.
    for (const spelling of ["039", "+39", "3_9", "0x27", "39.0", "1e2"]) {
      const response = await call({ attachmentId: ALLOCATED, contentLength: spelling });
      expect(response.status, `accepted ${JSON.stringify(spelling)}`).toBe(400);
    }
    expect(await stateOf(ALLOCATED)).toBe("allocated");
  });

  it("refuses a length the metadata does not agree with", async () => {
    for (const declared of [String(CIPHERTEXT_BYTES - 1), String(CIPHERTEXT_BYTES + 1), "0"]) {
      const response = await call({ attachmentId: ALLOCATED, contentLength: declared });
      expect(response.status, `accepted ${declared}`).toBe(400);
      expect((await errorOf(response))["code"]).toBe("VALIDATION_FAILED");
    }
    expect(await objectBytes(objectKeyOf("01"))).toBeNull();
  });

  it("refuses an over-cap length before reading the body", async () => {
    const request = requestFor({
      attachmentId: ALLOCATED,
      contentLength: String(MAX_CIPHERTEXT_BYTES + 1),
    });
    const response = await handleAttachmentUpload(request, env as unknown as Env, ALLOCATED);
    expect(response.status).toBe(413);
    expect((await errorOf(response))["code"]).toBe("REQUEST_TOO_LARGE");
    expect(request.bodyUsed, "the body must not be read").toBe(false);
    expect(await objectBytes(objectKeyOf("01"))).toBeNull();
    expect(await stateOf(ALLOCATED)).toBe("allocated");
  });

  it("refuses a request with no body at all", async () => {
    // Only a directly constructed request can have a genuinely null body: the
    // runtime hands the route an empty stream instead.
    const request = requestFor({
      attachmentId: ALLOCATED,
      body: null,
      contentLength: String(CIPHERTEXT_BYTES),
    });
    expect(request.body).toBeNull();
    const response = await handleAttachmentUpload(request, env as unknown as Env, ALLOCATED);
    expect(response.status).toBe(400);
    expect((await errorOf(response))["code"]).toBe("VALIDATION_FAILED");
    expect(await objectBytes(objectKeyOf("01"))).toBeNull();
  });

  it("leaves the row allocated when the body is shorter than it declared", async () => {
    // A truncated body is only discovered once R2 has stored what arrived, so
    // the size check there is what catches it. The transition never happens
    // and the client may retry the same PUT.
    const response = await call({
      attachmentId: ALLOCATED,
      body: null,
      contentLength: String(CIPHERTEXT_BYTES),
    });
    expect(response.status).toBe(503);
    expect(await errorOf(response)).toEqual({ code: "STORAGE_UNAVAILABLE", retryable: true });
    expect(await stateOf(ALLOCATED)).toBe("allocated");
  });
});

describe("PUT /v1/attachments/{id}/content — states the contract refuses", () => {
  it("refuses ready, abandoned, tombstoned and garbage_collected before reading the body", async () => {
    await db
      .prepare("UPDATE attachment SET state = 'abandoned' WHERE attachment_id = ?")
      .bind(TOMBSTONED)
      .run();

    for (const [attachmentId, key] of [
      [READY, objectKeyOf("03")],
      [TOMBSTONED, objectKeyOf("04")],
    ] as const) {
      const request = requestFor({ attachmentId });
      const response = await handleAttachmentUpload(request, env as unknown as Env, attachmentId);
      expect(response.status).toBe(409);
      expect(await errorOf(response)).toEqual({
        code: "ATTACHMENT_STATE_CONFLICT",
        retryable: false,
      });
      expect(request.bodyUsed, "the body must not be read").toBe(false);
      expect(await objectBytes(key)).toBeNull();
    }

    for (const state of ["garbage_collected", "ready"]) {
      await db
        .prepare("UPDATE attachment SET state = ? WHERE attachment_id = ?")
        .bind(state, READY)
        .run();
      const response = await call({ attachmentId: READY });
      expect(response.status, `accepted ${state}`).toBe(409);
    }
  });
});

describe("PUT /v1/attachments/{id}/content — the uploaded retry", () => {
  beforeEach(async () => {
    await bucket.put(objectKeyOf("02"), bodyFor(UPLOADED));
  });

  it("succeeds without reading the body or rewriting the object", async () => {
    const before = await ledgerSnapshot();
    const request = requestFor({ attachmentId: UPLOADED, body: ciphertext(99) });

    const response = await handleAttachmentUpload(request, env as unknown as Env, UPLOADED);

    expect(response.status).toBe(204);
    expect(request.bodyUsed, "an idempotent retry must not read the body").toBe(false);
    // The stored bytes are still the first upload's, not this request's.
    expect(await objectBytes(objectKeyOf("02"))).toEqual([...bodyFor(UPLOADED)]);
    expect(await stateOf(UPLOADED)).toBe("uploaded");
    expect(await ledgerSnapshot()).toEqual(before);
  });

  it("is a retryable storage failure when the object is missing", async () => {
    await bucket.delete(objectKeyOf("02"));
    const response = await call({ attachmentId: UPLOADED });
    expect(response.status).toBe(503);
    expect(await errorOf(response)).toEqual({ code: "STORAGE_UNAVAILABLE", retryable: true });
    expect(await stateOf(UPLOADED)).toBe("uploaded");
  });

  it("is a retryable storage failure when the stored size disagrees", async () => {
    await bucket.put(objectKeyOf("02"), new Uint8Array(CIPHERTEXT_BYTES - 1));
    const response = await call({ attachmentId: UPLOADED });
    expect(response.status).toBe(503);
    expect((await errorOf(response))["code"]).toBe("STORAGE_UNAVAILABLE");
  });
});

describe("PUT /v1/attachments/{id}/content — concurrency", () => {
  it("keeps one object when two uploads race", async () => {
    // Both requests carry the one ciphertext this attachment's stored hash
    // accepts, so the race is over which create-only PUT lands first.
    const body = bodyFor(ALLOCATED);
    const before = await ledgerSnapshot();

    const responses = await Promise.all([
      call({ attachmentId: ALLOCATED, body }),
      call({ attachmentId: ALLOCATED, body }),
    ]);

    // Both converge: the loser's create-only PUT was refused, but the object
    // it needed exists at the right size, so there is nothing left to do.
    for (const response of responses) {
      expect(response.status).toBe(204);
    }
    expect(await objectBytes(objectKeyOf("01"))).toEqual([...body]);
    expect(await stateOf(ALLOCATED)).toBe("uploaded");
    expect(await ledgerSnapshot()).toEqual(before);
  });

  it("does not replace an object that already exists at the metadata size", async () => {
    // A same-length object is already stored under this key. The create-only
    // condition must win over a checksum-correct body: the stored bytes are
    // what an existing AAD commits to, whatever this request carries.
    const prior = ciphertext(44);
    expect(prior.byteLength).toBe(CIPHERTEXT_BYTES);
    await bucket.put(objectKeyOf("01"), prior);

    const response = await call({ attachmentId: ALLOCATED });

    expect(response.status).toBe(204);
    expect(await stateOf(ALLOCATED)).toBe("uploaded");
    expect(await objectBytes(objectKeyOf("01"))).toEqual([...prior]);
  });

  it("is a retryable storage failure when the existing object is the wrong size", async () => {
    await bucket.put(objectKeyOf("01"), new Uint8Array(CIPHERTEXT_BYTES + 1));

    const response = await call({ attachmentId: ALLOCATED });

    expect(response.status).toBe(503);
    expect(await errorOf(response)).toEqual({ code: "STORAGE_UNAVAILABLE", retryable: true });
    // The row is left where a retry can still pick it up.
    expect(await stateOf(ALLOCATED)).toBe("allocated");
  });
});

describe("PUT /v1/attachments/{id}/content — storage faults", () => {
  const SENTINEL = "R2 exploded at line 42 while writing obj/ for gdt1_ token";

  /** Only the binding handed to the route is synthetic; production is untouched. */
  function envWith(overrides: Partial<Env>): Env {
    return { DB: db, ATTACHMENTS: bucket, CURSOR_MAC_KEY: "x", ...overrides } as Env;
  }

  it("turns an R2 put failure into a content-free retryable error", async () => {
    const broken = {
      put(): never {
        throw new Error(SENTINEL);
      },
      head: bucket.head.bind(bucket),
    };
    const response = await handleAttachmentUpload(
      requestFor({ attachmentId: ALLOCATED }),
      envWith({ ATTACHMENTS: broken as unknown as R2Bucket }),
      ALLOCATED,
    );
    expect(response.status).toBe(503);
    const serialised = JSON.stringify(await response.json());
    expect(serialised).not.toContain(SENTINEL);
    expect(serialised).not.toContain("exploded");
    expectContentFree(serialised);
    expect(await stateOf(ALLOCATED)).toBe("allocated");
  });

  it("turns a D1 update failure into a content-free retryable error", async () => {
    const real = db;
    const brokenDb = {
      prepare(sql: string) {
        if (sql.includes("UPDATE attachment")) {
          throw new Error(SENTINEL);
        }
        return real.prepare(sql);
      },
    };
    const response = await handleAttachmentUpload(
      requestFor({ attachmentId: ALLOCATED }),
      envWith({ DB: brokenDb as unknown as D1Database }),
      ALLOCATED,
    );
    expect(response.status).toBe(503);
    const serialised = JSON.stringify(await response.json());
    expect(serialised).not.toContain(SENTINEL);
    expectContentFree(serialised);
    // The R2 object written before the failure is deliberately left in place:
    // Phase 1 reports orphans rather than deleting them, and the client's
    // identical retry converges on it.
    expect(await objectBytes(objectKeyOf("01"))).not.toBeNull();
    expect(await stateOf(ALLOCATED)).toBe("allocated");
  });

  it("turns an unexpected non-ApiError into a content-free 500", async () => {
    const brokenDb = {
      prepare(): never {
        throw { notAnError: true };
      },
    };
    const response = await handleAttachmentUpload(
      requestFor({ attachmentId: ALLOCATED }),
      envWith({ DB: brokenDb as unknown as D1Database }),
      ALLOCATED,
    );
    expect(response.status).toBe(500);
    const body = (await response.json()) as Record<string, unknown>;
    expect(body["error"]).toEqual({ code: "INTERNAL_ERROR", retryable: false });
    expect(body["request_id"]).toBeUndefined();
  });
});

describe("PUT /v1/attachments/{id}/content — ciphertext checksum", () => {
  /** Only the binding handed to the route is synthetic; production is untouched. */
  function envWith(overrides: Partial<Env>): Env {
    return { DB: db, ATTACHMENTS: bucket, CURSOR_MAC_KEY: "x", ...overrides } as Env;
  }

  it("stores the object when the body matches the recorded hash", async () => {
    const body = bodyFor(ALLOCATED);
    const response = await call({ attachmentId: ALLOCATED, body });
    expect(response.status).toBe(204);
    expect(await objectBytes(objectKeyOf("01"))).toEqual([...body]);
    expect(await stateOf(ALLOCATED)).toBe("uploaded");
  });

  it("leaves no object when the body is short", async () => {
    const short = bodyFor(ALLOCATED).slice(0, CIPHERTEXT_BYTES - 1);
    // The declared length still has to match, or the size check refuses first.
    const response = await call({
      attachmentId: ALLOCATED,
      body: short,
      contentLength: String(CIPHERTEXT_BYTES),
    });
    expect(response.status).toBe(503);
    expect(await errorOf(response)).toEqual({ code: "STORAGE_UNAVAILABLE", retryable: true });
    expect(await objectBytes(objectKeyOf("01"))).toBeNull();
    expect(await stateOf(ALLOCATED)).toBe("allocated");
  });

  it("leaves no object when the body is a different ciphertext of the same length", async () => {
    const wrong = ciphertext(123);
    expect(wrong.byteLength).toBe(CIPHERTEXT_BYTES);
    expect([...wrong]).not.toEqual([...bodyFor(ALLOCATED)]);

    const response = await call({ attachmentId: ALLOCATED, body: wrong });

    // A size check alone would have accepted this; only the checksum sees it.
    expect(response.status).toBe(503);
    expect(await errorOf(response)).toEqual({ code: "STORAGE_UNAVAILABLE", retryable: true });
    expect(await objectBytes(objectKeyOf("01"))).toBeNull();
    expect(await stateOf(ALLOCATED)).toBe("allocated");
  });

  it("says nothing about the key, the checksum or the body when it refuses", async () => {
    const storedHash = (
      await db
        .prepare("SELECT ciphertext_hash AS h FROM attachment WHERE attachment_id = ?")
        .bind(ALLOCATED)
        .first<{ h: string }>()
    )?.h;
    expect(storedHash).toBeTypeOf("string");

    const response = await call({ attachmentId: ALLOCATED, body: ciphertext(200) });
    const serialised = JSON.stringify(await response.json());

    expect(serialised).not.toContain(storedHash as string);
    expect(serialised).not.toContain(objectKeyOf("01"));
    expect(serialised).not.toContain("sha256");
    expect(serialised).not.toContain("checksum");
    expectContentFree(serialised);
  });

  it("hands R2 the unread request stream rather than a buffered body", async () => {
    let sawStream = false;
    let bodyWasUnread = false;
    let sawChecksum = false;
    const request = requestFor({ attachmentId: ALLOCATED });

    const recording = {
      async put(_key: string, value: unknown, options: R2PutOptions) {
        sawStream = value instanceof ReadableStream;
        // The Worker never read the body itself: R2 is the first consumer.
        bodyWasUnread = request.bodyUsed === false;
        sawChecksum = options.sha256 instanceof Uint8Array && options.sha256.byteLength === 32;
        return await bucket.put(objectKeyOf("01"), bodyFor(ALLOCATED));
      },
      head: bucket.head.bind(bucket),
    };

    const response = await handleAttachmentUpload(
      request,
      envWith({ ATTACHMENTS: recording as unknown as R2Bucket }),
      ALLOCATED,
    );

    expect(response.status).toBe(204);
    expect(sawStream, "the body must reach R2 as a stream").toBe(true);
    expect(bodyWasUnread, "the Worker must not buffer or hash the body").toBe(true);
    expect(sawChecksum, "the recorded hash must travel as 32 raw bytes").toBe(true);
  });
});
