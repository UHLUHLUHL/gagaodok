import { applyD1Migrations, env } from "cloudflare:test";
import type { D1Migration } from "cloudflare:test";
import { afterEach, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { applyOperationRequest } from "../src/handlers/operationRequest";
import { setObjectKeyGeneratorForTest } from "../src/storage/operationTransaction";
import { getEntityShape, getOperationSpec } from "../src/contracts/operation";

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

// Synthetic fixtures only. No real account, device, token or attachment.
const ACCOUNT = "A0000000-0000-4000-8000-00000000000A";
const ACCOUNT_B = "A0000000-0000-4000-8000-00000000000B";
const DEVICE_MAC = "B0000000-0000-4000-8000-000000000001";
const DEVICE_PHONE = "B0000000-0000-4000-8000-000000000002";
const ATTACHMENT = "70000000-0000-4000-8000-00000000CA01";
const ATTACHMENT_2 = "70000000-0000-4000-8000-00000000CA02";
const OPERATION = "90000000-0000-4000-8000-00000000CB01";
const OPERATION_2 = "90000000-0000-4000-8000-00000000CB02";
const FIXED_UUID = "E0000000-0000-4000-8000-00000000CC01";
const FIXED_UUID_2 = "E0000000-0000-4000-8000-00000000CC02";
const TIMESTAMP = "2026-08-28T00:00:00Z";
const LATER = "2026-08-29T00:00:00Z";
const MAC = "MAC_SPACE";
const PHONE = "PHONE_SPACE";
const EXHAUSTED_SENTINEL = 9007199254740992;

const SOURCE_SIZE = 100;
const CIPHERTEXT_SIZE = SOURCE_SIZE + 34;
const HASH = "b".repeat(64);

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
const TOKEN_MAC = `gdt1_${base64Url(syntheticTokenBytes(1))}`;
const TOKEN_PHONE = `gdt1_${base64Url(syntheticTokenBytes(33))}`;

function envelope(seed: number): string {
  const bytes = new Uint8Array(34);
  bytes[0] = 1;
  bytes[1] = 1;
  for (let index = 2; index < bytes.length; index += 1) bytes[index] = (seed + index) & 0xff;
  return base64(bytes);
}

const FILE_NAME = envelope(1);
const MIME_TYPE = envelope(2);
const WRAPPED_KEY = envelope(3);

function metadata(extra: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    origin_space_id: MAC,
    kind: "attachment",
    source_byte_size: SOURCE_SIZE,
    ciphertext_byte_size: CIPHERTEXT_SIZE,
    ciphertext_hash: HASH,
    key_generation: 1,
    created_at: TIMESTAMP,
    ...extra,
  };
}

function body(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    protocol_version: 1,
    operation_id: OPERATION,
    device_id: DEVICE_MAC,
    op: "create_attachment",
    entity_type: "attachment",
    target: { space_id: MAC, attachment_id: ATTACHMENT },
    metadata_set: metadata(),
    metadata_clear: [],
    set: { file_name: FILE_NAME, mime_type: MIME_TYPE, wrapped_file_key: WRAPPED_KEY },
    clear: [],
    created_at: LATER,
    ...overrides,
  };
}

function makeRequest(payload: unknown, token: string = TOKEN_MAC): Request {
  return new Request("https://example.test/v1/sync/operations", {
    method: "POST",
    headers: new Headers({ Authorization: `Device ${token}` }),
    body: JSON.stringify(payload),
  });
}

async function expectApiError(run: () => Promise<unknown>, code: string, label: string): Promise<void> {
  let caught: unknown;
  try {
    await run();
  } catch (error) {
    caught = error;
  }
  expect(caught, `${label} was not rejected`).toBeDefined();
  expect((caught as { code?: string }).code, label).toBe(code);
}

async function caughtOf(run: () => Promise<unknown>): Promise<Record<string, unknown>> {
  try {
    await run();
  } catch (error) {
    return error as Record<string, unknown>;
  }
  throw new Error("expected a rejection");
}

async function insertDevice(deviceId: string, spaceId: string, seed: number): Promise<void> {
  await db
    .prepare(
      `INSERT INTO device
         (account_id, device_id, space_id, platform, display_name_enc,
          linked_at, revoked_at, key_generation, token_hash)
       VALUES (?, ?, ?, 'android_phone', NULL, ?, NULL, 1, ?)`,
    )
    .bind(ACCOUNT, deviceId, spaceId, TIMESTAMP, await sha256Hex(syntheticTokenBytes(seed)))
    .run();
}

async function snapshot(): Promise<string> {
  const dump: Record<string, unknown> = {};
  for (const table of ["attachment", "account", "operation_log", "change_log", "transaction_guard"]) {
    dump[table] = (await db.prepare(`SELECT * FROM ${table}`).all()).results;
  }
  return JSON.stringify(dump);
}

async function countOf(table: string): Promise<number> {
  const row = await db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).first<{ n: number }>();
  return row?.n ?? 0;
}

async function nextSeq(): Promise<number> {
  const row = await db
    .prepare("SELECT next_server_seq FROM account WHERE account_id = ?")
    .bind(ACCOUNT)
    .first<{ next_server_seq: number }>();
  return row?.next_server_seq ?? -1;
}

async function attachmentRow(attachmentId = ATTACHMENT): Promise<Record<string, unknown> | null> {
  return await db
    .prepare("SELECT * FROM attachment WHERE account_id = ? AND attachment_id = ?")
    .bind(ACCOUNT, attachmentId)
    .first<Record<string, unknown>>();
}

beforeAll(async () => {
  await applyD1Migrations(db, env.TEST_MIGRATIONS);
});

beforeEach(async () => {
  for (const table of ["transaction_guard", "change_log", "operation_log", "attachment", "device", "account"]) {
    await db.prepare(`DELETE FROM ${table}`).run();
  }
  for (const accountId of [ACCOUNT, ACCOUNT_B]) {
    await db
      .prepare("INSERT INTO account (account_id, created_at) VALUES (?, ?)")
      .bind(accountId, TIMESTAMP)
      .run();
  }
  await insertDevice(DEVICE_MAC, MAC, 1);
  await insertDevice(DEVICE_PHONE, PHONE, 33);
});

afterEach(() => {
  setObjectKeyGeneratorForTest(null);
});

describe("create_attachment", () => {
  it("allocates one row, two ledger rows and one sequence", async () => {
    const result = await applyOperationRequest(makeRequest(body()), db);
    expect(result.status).toBe("applied");
    expect(result.operation_id).toBe(OPERATION);
    expect(result.server_seq).toBe(1);
    // An attachment projection has no revision of its own.
    expect(result.revision).toBeNull();

    const row = await attachmentRow();
    expect(row?.["state"]).toBe("allocated");
    expect(row?.["origin_space_id"]).toBe(MAC);
    expect(row?.["kind"]).toBe("attachment");
    expect(row?.["source_byte_size"]).toBe(SOURCE_SIZE);
    expect(row?.["ciphertext_byte_size"]).toBe(CIPHERTEXT_SIZE);
    expect(row?.["ciphertext_hash"]).toBe(HASH);
    expect(row?.["key_generation"]).toBe(1);
    expect(row?.["created_at"]).toBe(TIMESTAMP);
    expect(row?.["server_seq"]).toBe(1);
    // The envelopes are stored byte for byte.
    expect(row?.["file_name_enc"]).toBe(FILE_NAME);
    expect(row?.["mime_type_enc"]).toBe(MIME_TYPE);
    expect(row?.["wrapped_file_key_enc"]).toBe(WRAPPED_KEY);

    expect(await nextSeq()).toBe(2);
    expect(await countOf("operation_log")).toBe(1);
    expect(await countOf("change_log")).toBe(1);
    expect(await countOf("transaction_guard")).toBe(0);
  });

  it("writes a canonical internal object key", async () => {
    setObjectKeyGeneratorForTest(() => FIXED_UUID);
    await applyOperationRequest(makeRequest(body()), db);
    expect((await attachmentRow())?.["r2_object_key"]).toBe(`obj/${FIXED_UUID}`);
  });

  it("generates a distinct key per attachment without any wire input", async () => {
    await applyOperationRequest(makeRequest(body()), db);
    await applyOperationRequest(
      makeRequest(body({ operation_id: OPERATION_2, target: { space_id: MAC, attachment_id: ATTACHMENT_2 } })),
      db,
    );
    const first = (await attachmentRow())?.["r2_object_key"] as string;
    const second = (await attachmentRow(ATTACHMENT_2))?.["r2_object_key"] as string;
    expect(first).not.toBe(second);
    for (const key of [first, second]) {
      expect(key.startsWith("obj/")).toBe(true);
      expect(key.length).toBe(40);
      expect(key.slice(4)).toMatch(/^[0-9A-F-]{36}$/);
    }
  });

  it("keeps the object key out of the result", async () => {
    setObjectKeyGeneratorForTest(() => FIXED_UUID);
    const result = await applyOperationRequest(makeRequest(body()), db);
    expect(JSON.stringify(result)).not.toContain(FIXED_UUID);
    expect(JSON.stringify(result)).not.toContain("obj/");
  });

  it("records the attachment identity in both ledgers with a null revision", async () => {
    await applyOperationRequest(makeRequest(body()), db);
    const log = await db.prepare("SELECT * FROM operation_log").first<Record<string, unknown>>();
    expect(log?.["entity_type"]).toBe("attachment");
    expect(log?.["result_revision"]).toBeNull();
    expect(log?.["server_seq"]).toBe(1);

    const change = await db.prepare("SELECT * FROM change_log").first<Record<string, unknown>>();
    expect(change?.["entity_type"]).toBe("attachment");
    expect(change?.["revision"]).toBeNull();
    expect(change?.["attachment_id"]).toBe(ATTACHMENT);
    // space_id is origin provenance on the row, never part of the change key.
    expect(change?.["space_id"]).toBeNull();
    expect(change?.["room_id"]).toBeNull();
    expect(change?.["worldline_key"]).toBeNull();
  });
});

describe("create_attachment — replay and conflicts", () => {
  it("replays a byte-identical retry without a new row, key or sequence", async () => {
    setObjectKeyGeneratorForTest(() => FIXED_UUID);
    const first = await applyOperationRequest(makeRequest(body()), db);
    const before = await snapshot();

    setObjectKeyGeneratorForTest(() => FIXED_UUID_2);
    const second = await applyOperationRequest(makeRequest(body()), db);
    expect(second.status).toBe("replayed");
    expect(second.server_seq).toBe(first.server_seq);
    expect(second.revision).toBeNull();
    // A replay does not mint a second object key either.
    expect(await snapshot()).toBe(before);
    expect((await attachmentRow())?.["r2_object_key"]).toBe(`obj/${FIXED_UUID}`);
  });

  it("rejects the same operation_id with different bytes", async () => {
    await applyOperationRequest(makeRequest(body()), db);
    const before = await snapshot();
    await expectApiError(
      () => applyOperationRequest(makeRequest(body({ metadata_set: metadata({ kind: "avatar" }) })), db),
      "OPERATION_REPLAY_MISMATCH",
      "fingerprint mismatch",
    );
    expect(await snapshot()).toBe(before);
  });

  it("refuses a second operation allocating the same attachment identity", async () => {
    await applyOperationRequest(makeRequest(body()), db);
    const before = await snapshot();
    const error = await caughtOf(() =>
      applyOperationRequest(makeRequest(body({ operation_id: OPERATION_2 })), db),
    );
    expect(error["code"]).toBe("ATTACHMENT_STATE_CONFLICT");
    expect(await snapshot()).toBe(before);
  });

  it("reports an internal object key collision as retryable storage failure", async () => {
    setObjectKeyGeneratorForTest(() => FIXED_UUID);
    await applyOperationRequest(makeRequest(body()), db);
    const before = await snapshot();

    // The generator repeats itself for a different attachment: the UNIQUE key
    // stops it, and the client may simply retry.
    const error = await caughtOf(() =>
      applyOperationRequest(
        makeRequest(body({ operation_id: OPERATION_2, target: { space_id: MAC, attachment_id: ATTACHMENT_2 } })),
        db,
      ),
    );
    expect(error["code"]).toBe("STORAGE_UNAVAILABLE");
    expect(error["retryable"]).toBe(true);
    const serialised = JSON.stringify({
      code: error["code"],
      detail: error["detail"],
      message: (error as unknown as Error).message,
    });
    expect(serialised).not.toContain(FIXED_UUID);
    expect(serialised).not.toContain("obj/");
    expect(await snapshot()).toBe(before);
  });

  it("applies a concurrent identical create exactly once", async () => {
    const payload = body();
    const results = await Promise.all([
      applyOperationRequest(makeRequest(payload), db),
      applyOperationRequest(makeRequest(payload), db),
    ]);
    expect(results.map((r) => r.status).sort()).toEqual(["applied", "replayed"]);
    expect(results[0].server_seq).toBe(results[1].server_seq);
    expect(await countOf("attachment")).toBe(1);
    expect(await countOf("change_log")).toBe(1);
    expect(await nextSeq()).toBe(2);
    expect(await countOf("transaction_guard")).toBe(0);
  });

  it("lets only one of two operations allocate the same identity", async () => {
    const outcomes = await Promise.allSettled([
      applyOperationRequest(makeRequest(body()), db),
      applyOperationRequest(makeRequest(body({ operation_id: OPERATION_2 })), db),
    ]);
    expect(outcomes.filter((o) => o.status === "fulfilled").length).toBe(1);
    const rejected = outcomes.find((o) => o.status === "rejected") as PromiseRejectedResult;
    expect((rejected.reason as { code?: string }).code).toBe("ATTACHMENT_STATE_CONFLICT");
    expect(await countOf("attachment")).toBe(1);
    expect(await countOf("operation_log")).toBe(1);
    expect(await nextSeq()).toBe(2);
    expect(await countOf("transaction_guard")).toBe(0);
  });
});

describe("create_attachment — boundaries", () => {
  it("fails closed when the account sequence is exhausted", async () => {
    await db
      .prepare("UPDATE account SET next_server_seq = ? WHERE account_id = ?")
      .bind(EXHAUSTED_SENTINEL, ACCOUNT)
      .run();
    const before = await snapshot();
    await expectApiError(
      () => applyOperationRequest(makeRequest(body()), db),
      "STORAGE_UNAVAILABLE",
      "sequence sentinel",
    );
    expect(await snapshot()).toBe(before);
  });

  it("refuses a device allocating in another space", async () => {
    const before = await snapshot();
    await expectApiError(
      () =>
        applyOperationRequest(
          makeRequest(body({ device_id: DEVICE_PHONE }), TOKEN_PHONE),
          db,
        ),
      "AUTH_INVALID",
      "cross-space attachment",
    );
    expect(await snapshot()).toBe(before);
  });

  it("refuses an origin space that disagrees with the target", async () => {
    const before = await snapshot();
    await expectApiError(
      () => applyOperationRequest(makeRequest(body({ metadata_set: metadata({ origin_space_id: PHONE }) })), db),
      "VALIDATION_FAILED",
      "origin provenance mismatch",
    );
    expect(await snapshot()).toBe(before);
  });

  it("refuses an extension path", async () => {
    await expectApiError(
      () =>
        applyOperationRequest(
          makeRequest(
            body({
              set: {
                file_name: FILE_NAME,
                mime_type: MIME_TYPE,
                wrapped_file_key: WRAPPED_KEY,
                "extensions.kakao.attachment.x": envelope(9),
              },
            }),
          ),
          db,
        ),
      "VALIDATION_FAILED",
      "attachment has no extension table",
    );
  });

  it("keeps the rules in the validator", () => {
    expect(getOperationSpec("create_attachment").kind).toBe("create");
    expect(getEntityShape("attachment").worldlineRule).toBe("absent");
    expect(getEntityShape("attachment").allowsExtensions).toBe(false);
  });
});
