import { applyD1Migrations, env } from "cloudflare:test";
import type { D1Migration } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { applyOperationRequest } from "../src/handlers/operationRequest";
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

const ACCOUNT = "A0000000-0000-4000-8000-00000000000A";
const ACCOUNT_B = "A0000000-0000-4000-8000-00000000000B";
const DEVICE_MAC = "B0000000-0000-4000-8000-000000000001";
const DEVICE_PHONE = "B0000000-0000-4000-8000-000000000002";
const ROOM = "10000000-0000-4000-8000-00000000BA01";
const PHONE_ROOM = "10000000-0000-4000-8000-00000000BA02";
const TURN = "30000000-0000-4000-8000-00000000BB01";
const TURN_2 = "30000000-0000-4000-8000-00000000BB02";
const PHONE_TURN = "30000000-0000-4000-8000-00000000BB03";
const MISSING_TURN = "30000000-0000-4000-8000-00000000BB04";
const MESSAGE = "40000000-0000-4000-8000-00000000BC01";
const MESSAGE_2 = "40000000-0000-4000-8000-00000000BC02";
const MESSAGE_3 = "40000000-0000-4000-8000-00000000BC03";
const ATTACHMENT = "70000000-0000-4000-8000-00000000BD01";
const OTHER_ATTACHMENT = "70000000-0000-4000-8000-00000000BD02";
const OPERATION = "90000000-0000-4000-8000-00000000BE01";
const OPERATION_2 = "90000000-0000-4000-8000-00000000BE02";
const OPERATION_3 = "90000000-0000-4000-8000-00000000BE03";
const TIMESTAMP = "2026-08-28T00:00:00Z";
const LATER = "2026-08-29T00:00:00Z";
const MAC = "MAC_SPACE";
const PHONE = "PHONE_SPACE";
const EXHAUSTED_SENTINEL = 9007199254740992;
const MAX_ORDER = 9007199254740991;

const ENCRYPTED_FIELDS = ["sender", "kind", "text", "speaker_ref", "reactions"] as const;
const NON_READY_STATES = ["allocated", "uploaded", "abandoned", "tombstoned", "garbage_collected"] as const;

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

const CIPHERTEXT_SIZE = 134;

function body(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    protocol_version: 1,
    operation_id: OPERATION,
    device_id: DEVICE_MAC,
    op: "create_bubble",
    entity_type: "bubble",
    target: { space_id: MAC, room_id: ROOM, worldline_id: null, turn_id: TURN, message_id: MESSAGE },
    bubble_order: 0,
    metadata_set: { timestamp: TIMESTAMP },
    metadata_clear: [],
    set: {},
    clear: [],
    created_at: LATER,
    ...overrides,
  };
}

function patchBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return body({
    op: "patch_bubble",
    operation_id: OPERATION_2,
    base_revision: 0,
    bubble_order: undefined,
    metadata_set: {},
    ...overrides,
  });
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

async function insertRoom(spaceId: string, roomId: string): Promise<void> {
  await db
    .prepare(
      `INSERT INTO room
         (account_id, space_id, room_id, origin_space_id, title_enc, status_message_enc, music_title_enc,
          music_artist_enc, revision, server_seq, created_at, updated_at)
       VALUES (?, ?, ?, ?, NULL, NULL, NULL, NULL, 0, NULL, ?, ?)`,
    )
    .bind(ACCOUNT, spaceId, roomId, spaceId, TIMESTAMP, TIMESTAMP)
    .run();
}

async function insertTurn(spaceId: string, roomId: string, turnId: string, deviceId: string): Promise<void> {
  await db
    .prepare(
      `INSERT INTO turn
         (account_id, space_id, room_id, worldline_id, worldline_key, turn_id,
          created_by_device_id, created_at, revision, server_seq, is_tombstoned)
       VALUES (?, ?, ?, NULL, '', ?, ?, ?, 0, NULL, 0)`,
    )
    .bind(ACCOUNT, spaceId, roomId, turnId, deviceId, TIMESTAMP)
    .run();
}

async function insertAttachment(
  accountId: string,
  attachmentId: string,
  state: string,
  ciphertextSize = CIPHERTEXT_SIZE,
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO attachment
         (account_id, attachment_id, origin_space_id, r2_object_key, kind, state,
          source_byte_size, ciphertext_byte_size, ciphertext_hash, key_generation,
          file_name_enc, mime_type_enc, wrapped_file_key_enc, created_at, server_seq)
       VALUES (?, ?, ?, ?, 'attachment', ?, ?, ?, ?, 1, ?, ?, ?, ?, NULL)`,
    )
    .bind(
      accountId,
      attachmentId,
      MAC,
      `obj/${attachmentId}`,
      state,
      ciphertextSize - 34,
      ciphertextSize,
      "a".repeat(64),
      envelope(90),
      envelope(91),
      envelope(92),
      TIMESTAMP,
    )
    .run();
}

/** Insert a bubble directly, to set up an order landscape without the handler. */
async function seedBubble(turnId: string, messageId: string, order: number): Promise<void> {
  await db
    .prepare(
      `INSERT INTO bubble
         (account_id, space_id, room_id, worldline_key, turn_id, message_id, bubble_order,
          timestamp, revision, server_seq, is_tombstoned)
       VALUES (?, ?, ?, '', ?, ?, ?, ?, 0, NULL, 0)`,
    )
    .bind(ACCOUNT, MAC, ROOM, turnId, messageId, order, TIMESTAMP)
    .run();
}

async function snapshot(): Promise<string> {
  const dump: Record<string, unknown> = {};
  for (const table of [
    "bubble",
    "bubble_extension_field",
    "turn",
    "attachment",
    "account",
    "operation_log",
    "change_log",
    "transaction_guard",
  ]) {
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

async function bubbleRow(messageId = MESSAGE): Promise<Record<string, unknown> | null> {
  return await db
    .prepare(
      `SELECT * FROM bubble
        WHERE account_id = ? AND space_id = ? AND room_id = ? AND worldline_key = ''
          AND message_id = ?`,
    )
    .bind(ACCOUNT, MAC, ROOM, messageId)
    .first<Record<string, unknown>>();
}

beforeAll(async () => {
  await applyD1Migrations(db, env.TEST_MIGRATIONS);
});

beforeEach(async () => {
  for (const table of [
    "transaction_guard",
    "change_log",
    "operation_log",
    "bubble_extension_field",
    "bubble",
    "attachment",
    "turn",
    "room",
    "device",
    "account",
  ]) {
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
  await insertRoom(MAC, ROOM);
  await insertRoom(PHONE, PHONE_ROOM);
  await insertTurn(MAC, ROOM, TURN, DEVICE_MAC);
  await insertTurn(MAC, ROOM, TURN_2, DEVICE_MAC);
  await insertTurn(PHONE, PHONE_ROOM, PHONE_TURN, DEVICE_PHONE);
});

describe("create_bubble", () => {
  it("creates the first bubble of a scope at order 0", async () => {
    const result = await applyOperationRequest(makeRequest(body({ set: { text: envelope(1) } })), db);
    expect(result.status).toBe("applied");
    expect(result.revision).toBe(0);
    expect(result.server_seq).toBe(1);

    const row = await bubbleRow();
    expect(row?.["text_enc"]).toBe(envelope(1));
    expect(row?.["sender_enc"]).toBeNull();
    expect(row?.["bubble_order"]).toBe(0);
    expect(row?.["timestamp"]).toBe(TIMESTAMP);
    expect(row?.["turn_id"]).toBe(TURN);
    expect(row?.["worldline_key"]).toBe("");
    expect(row?.["attachment_ref_attachment_id"]).toBeNull();
    expect(row?.["attachment_ref_byte_size"]).toBeNull();
    expect(row?.["is_tombstoned"]).toBe(0);
    expect(await nextSeq()).toBe(2);
    expect(await countOf("transaction_guard")).toBe(0);
  });

  it("stores every encrypted field", async () => {
    const set: Record<string, string> = {};
    ENCRYPTED_FIELDS.forEach((field, index) => {
      set[field] = envelope(10 + index);
    });
    await applyOperationRequest(makeRequest(body({ set })), db);
    const row = await bubbleRow();
    ENCRYPTED_FIELDS.forEach((field, index) => {
      expect(row?.[`${field}_enc`]).toBe(envelope(10 + index));
    });
  });

  it("records the bubble identity in the ledgers", async () => {
    await applyOperationRequest(makeRequest(body()), db);
    const log = await db.prepare("SELECT * FROM operation_log").first<Record<string, unknown>>();
    expect(log?.["entity_type"]).toBe("bubble");
    expect(log?.["result_revision"]).toBe(0);
    const change = await db.prepare("SELECT * FROM change_log").first<Record<string, unknown>>();
    expect(change?.["entity_type"]).toBe("bubble");
    expect(change?.["revision"]).toBe(0);
    expect(change?.["space_id"]).toBe(MAC);
    expect(change?.["room_id"]).toBe(ROOM);
    expect(change?.["worldline_key"]).toBe("");
    expect(change?.["turn_id"]).toBe(TURN);
    expect(change?.["message_id"]).toBe(MESSAGE);
    expect(change?.["checkpoint_id"]).toBeNull();
  });

  it("stores bubble extensions in the same transaction", async () => {
    await applyOperationRequest(
      makeRequest(body({ set: { "extensions.kakao.bubble.mood": envelope(2) } })),
      db,
    );
    const row = await db.prepare("SELECT * FROM bubble_extension_field").first<Record<string, unknown>>();
    expect(row?.["extension_key"]).toBe("kakao.bubble.mood");
    expect(row?.["turn_id"]).toBe(TURN);
    expect(row?.["message_id"]).toBe(MESSAGE);
    expect(await countOf("change_log")).toBe(1);
  });

  it("reports a missing parent turn as ENTITY_NOT_FOUND", async () => {
    const before = await snapshot();
    await expectApiError(
      () =>
        applyOperationRequest(
          makeRequest(
            body({
              target: { space_id: MAC, room_id: ROOM, worldline_id: null, turn_id: MISSING_TURN, message_id: MESSAGE },
            }),
          ),
          db,
        ),
      "ENTITY_NOT_FOUND",
      "missing parent turn",
    );
    expect(await snapshot()).toBe(before);
  });

  it("reports a parent turn from another room as ENTITY_NOT_FOUND", async () => {
    await expectApiError(
      () =>
        applyOperationRequest(
          makeRequest(
            body({
              target: { space_id: MAC, room_id: ROOM, worldline_id: null, turn_id: PHONE_TURN, message_id: MESSAGE },
            }),
          ),
          db,
        ),
      "ENTITY_NOT_FOUND",
      "cross-scope parent turn",
    );
  });

  it.each(["is_tombstoned", "tombstoned_at", "bubble_order", "timestamp"])(
    "cannot reach the %s column through set",
    async (field) => {
      await expectApiError(
        () => applyOperationRequest(makeRequest(body({ set: { [field]: envelope(3) } })), db),
        "VALIDATION_FAILED",
        `${field} is not an encrypted wire field`,
      );
    },
  );

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
});

describe("create_bubble — bubble_order", () => {
  it("counts scope-wide across turns, tombstones included", async () => {
    await seedBubble(TURN, MESSAGE_2, 0);
    await seedBubble(TURN_2, MESSAGE_3, 7);
    await db.prepare("UPDATE bubble SET is_tombstoned = 1, tombstoned_at = ?, tombstone_operation_id = ? WHERE bubble_order = 7")
      .bind(TIMESTAMP, OPERATION_3)
      .run();

    const result = await applyOperationRequest(makeRequest(body({ bubble_order: 8 })), db);
    expect(result.status).toBe("applied");
    expect((await bubbleRow())?.["bubble_order"]).toBe(8);
  });

  it("refuses a reused lower order and names the expected one", async () => {
    await seedBubble(TURN, MESSAGE_2, 0);
    const before = await snapshot();
    const error = await caughtOf(() => applyOperationRequest(makeRequest(body({ bubble_order: 0 })), db));
    expect(error["code"]).toBe("BUBBLE_ORDER_CONFLICT");
    expect(error["retryable"]).toBe(false);
    expect(error["detail"]).toEqual({ expected_bubble_order: 1 });
    expect(await snapshot()).toBe(before);
  });

  it("refuses a gap above the expected order", async () => {
    await seedBubble(TURN, MESSAGE_2, 0);
    const error = await caughtOf(() => applyOperationRequest(makeRequest(body({ bubble_order: 5 })), db));
    expect(error["code"]).toBe("BUBBLE_ORDER_CONFLICT");
    expect(error["detail"]).toEqual({ expected_bubble_order: 1 });
  });

  it("keeps a message identity collision ahead of an order conflict", async () => {
    // The same message_id already exists in this scope AND the proposed order
    // is stale. Identity wins: the client must stop, not renumber.
    await seedBubble(TURN, MESSAGE, 0);
    const error = await caughtOf(() => applyOperationRequest(makeRequest(body({ bubble_order: 0 })), db));
    expect(error["code"]).toBe("REVISION_CONFLICT");
    expect(error["detail"]).toEqual({ current_revision: 0 });
  });

  it("treats the same message_id in another turn as an identity collision", async () => {
    await seedBubble(TURN_2, MESSAGE, 0);
    const error = await caughtOf(() => applyOperationRequest(makeRequest(body({ bubble_order: 1 })), db));
    expect(error["code"]).toBe("REVISION_CONFLICT");
  });

  it("lets only one of two operations take the same next order", async () => {
    const outcomes = await Promise.allSettled([
      applyOperationRequest(makeRequest(body({ set: { text: envelope(4) } })), db),
      applyOperationRequest(
        makeRequest(
          body({
            operation_id: OPERATION_2,
            target: { space_id: MAC, room_id: ROOM, worldline_id: null, turn_id: TURN, message_id: MESSAGE_2 },
            set: { text: envelope(5) },
          }),
        ),
        db,
      ),
    ]);
    expect(outcomes.filter((o) => o.status === "fulfilled").length).toBe(1);
    const rejected = outcomes.find((o) => o.status === "rejected") as PromiseRejectedResult;
    const reason = rejected.reason as Record<string, unknown>;
    expect(reason["code"]).toBe("BUBBLE_ORDER_CONFLICT");
    expect(reason["detail"]).toEqual({ expected_bubble_order: 1 });

    expect(await countOf("bubble")).toBe(1);
    expect(await countOf("operation_log")).toBe(1);
    expect(await countOf("change_log")).toBe(1);
    expect(await nextSeq()).toBe(2);
    expect(await countOf("transaction_guard")).toBe(0);
  });

  it("fails closed when the order namespace is exhausted", async () => {
    await seedBubble(TURN, MESSAGE_2, MAX_ORDER);
    const before = await snapshot();
    const error = await caughtOf(() => applyOperationRequest(makeRequest(body({ bubble_order: 0 })), db));
    expect(error["code"]).toBe("STORAGE_UNAVAILABLE");
    expect(error["retryable"]).toBe(false);
    // The unsafe max + 1 is never handed back to a client.
    expect(JSON.stringify(error["detail"])).not.toContain("9007199254740992");
    expect(await snapshot()).toBe(before);
  });
});

describe("create_bubble — attachment reference", () => {
  it("accepts a ready attachment of the same account", async () => {
    await insertAttachment(ACCOUNT, ATTACHMENT, "ready");
    await applyOperationRequest(
      makeRequest(
        body({
          metadata_set: {
            timestamp: TIMESTAMP,
            attachment_ref_attachment_id: ATTACHMENT,
            attachment_ref_byte_size: CIPHERTEXT_SIZE,
          },
        }),
      ),
      db,
    );
    const row = await bubbleRow();
    expect(row?.["attachment_ref_attachment_id"]).toBe(ATTACHMENT);
    expect(row?.["attachment_ref_byte_size"]).toBe(CIPHERTEXT_SIZE);
  });

  it("reports an unknown attachment as ENTITY_NOT_FOUND", async () => {
    const before = await snapshot();
    await expectApiError(
      () =>
        applyOperationRequest(
          makeRequest(
            body({
              metadata_set: {
                timestamp: TIMESTAMP,
                attachment_ref_attachment_id: ATTACHMENT,
                attachment_ref_byte_size: CIPHERTEXT_SIZE,
              },
            }),
          ),
          db,
        ),
      "ENTITY_NOT_FOUND",
      "unknown attachment",
    );
    expect(await snapshot()).toBe(before);
  });

  it("cannot reference another account's attachment", async () => {
    await insertAttachment(ACCOUNT_B, OTHER_ATTACHMENT, "ready");
    await expectApiError(
      () =>
        applyOperationRequest(
          makeRequest(
            body({
              metadata_set: {
                timestamp: TIMESTAMP,
                attachment_ref_attachment_id: OTHER_ATTACHMENT,
                attachment_ref_byte_size: CIPHERTEXT_SIZE,
              },
            }),
          ),
          db,
        ),
      "ENTITY_NOT_FOUND",
      "cross-account attachment",
    );
  });

  it.each(NON_READY_STATES)("refuses an attachment in state %s", async (state) => {
    await insertAttachment(ACCOUNT, ATTACHMENT, state);
    const before = await snapshot();
    await expectApiError(
      () =>
        applyOperationRequest(
          makeRequest(
            body({
              metadata_set: {
                timestamp: TIMESTAMP,
                attachment_ref_attachment_id: ATTACHMENT,
                attachment_ref_byte_size: CIPHERTEXT_SIZE,
              },
            }),
          ),
          db,
        ),
      "ATTACHMENT_STATE_CONFLICT",
      `attachment state ${state}`,
    );
    expect(await snapshot()).toBe(before);
  });

  it("refuses a byte size that disagrees with the stored ciphertext", async () => {
    await insertAttachment(ACCOUNT, ATTACHMENT, "ready");
    const before = await snapshot();
    await expectApiError(
      () =>
        applyOperationRequest(
          makeRequest(
            body({
              metadata_set: {
                timestamp: TIMESTAMP,
                attachment_ref_attachment_id: ATTACHMENT,
                attachment_ref_byte_size: CIPHERTEXT_SIZE + 1,
              },
            }),
          ),
          db,
        ),
      "VALIDATION_FAILED",
      "byte size mismatch",
    );
    expect(await snapshot()).toBe(before);
  });
});

describe("patch_bubble", () => {
  beforeEach(async () => {
    await applyOperationRequest(
      makeRequest(body({ set: { text: envelope(1), "extensions.kakao.bubble.mood": envelope(2) } })),
      db,
    );
  });

  it("advances the revision and leaves order, timestamp and attachment alone", async () => {
    const result = await applyOperationRequest(
      makeRequest(patchBody({ set: { sender: envelope(3) }, clear: ["text"] })),
      db,
    );
    expect(result.revision).toBe(1);
    const row = await bubbleRow();
    expect(row?.["sender_enc"]).toBe(envelope(3));
    expect(row?.["text_enc"]).toBeNull();
    expect(row?.["bubble_order"]).toBe(0);
    expect(row?.["timestamp"]).toBe(TIMESTAMP);
    expect(row?.["attachment_ref_attachment_id"]).toBeNull();
    expect(row?.["revision"]).toBe(1);
  });

  it("replaces and clears an extension", async () => {
    await applyOperationRequest(
      makeRequest(patchBody({ set: { "extensions.kakao.bubble.mood": envelope(4) } })),
      db,
    );
    expect(
      (await db.prepare("SELECT envelope_enc FROM bubble_extension_field").first<{ envelope_enc: string }>())
        ?.envelope_enc,
    ).toBe(envelope(4));
    await applyOperationRequest(
      makeRequest(
        patchBody({ operation_id: OPERATION_3, base_revision: 1, clear: ["extensions.kakao.bubble.mood"] }),
      ),
      db,
    );
    expect(await countOf("bubble_extension_field")).toBe(0);
  });

  it("refuses a bubble_order or attachment change", async () => {
    await expectApiError(
      () => applyOperationRequest(makeRequest(patchBody({ bubble_order: 5 })), db),
      "VALIDATION_FAILED",
      "bubble_order on patch",
    );
    await expectApiError(
      () =>
        applyOperationRequest(
          makeRequest(
            patchBody({
              metadata_set: { attachment_ref_attachment_id: ATTACHMENT, attachment_ref_byte_size: 134 },
            }),
          ),
          db,
        ),
      "VALIDATION_FAILED",
      "attachment reference on patch",
    );
  });

  it("refuses a stale base revision", async () => {
    const before = await snapshot();
    await expectApiError(
      () => applyOperationRequest(makeRequest(patchBody({ base_revision: 4 })), db),
      "REVISION_CONFLICT",
      "stale base_revision",
    );
    expect(await snapshot()).toBe(before);
  });

  it("reports a missing bubble as ENTITY_NOT_FOUND", async () => {
    await db.prepare("DELETE FROM bubble_extension_field").run();
    await db.prepare("DELETE FROM bubble").run();
    await expectApiError(
      () => applyOperationRequest(makeRequest(patchBody()), db),
      "ENTITY_NOT_FOUND",
      "missing bubble",
    );
  });

  it("reports a target naming the wrong turn as ENTITY_NOT_FOUND", async () => {
    // The bubble really lives in TURN. This patch names TURN_2 with the same
    // message_id and the *correct* base revision, so a scope-wide lookup would
    // find the row, agree about the revision, and fall through to a retryable
    // storage failure. The identity the client asked for does not exist.
    const before = await snapshot();
    await expectApiError(
      () =>
        applyOperationRequest(
          makeRequest(
            patchBody({
              target: {
                space_id: MAC,
                room_id: ROOM,
                worldline_id: null,
                turn_id: TURN_2,
                message_id: MESSAGE,
              },
              base_revision: 0,
              set: { sender: envelope(20) },
            }),
          ),
          db,
        ),
      "ENTITY_NOT_FOUND",
      "patch target names another turn",
    );
    expect(await snapshot()).toBe(before);
    expect((await bubbleRow())?.["revision"]).toBe(0);
    expect(await countOf("bubble_extension_field")).toBe(1);
    expect(await countOf("operation_log")).toBe(1);
    expect(await countOf("change_log")).toBe(1);
    expect(await nextSeq()).toBe(2);
    expect(await countOf("transaction_guard")).toBe(0);
  });

  it("replays a byte-identical retry and rejects different bytes", async () => {
    const payload = patchBody({ set: { sender: envelope(5) } });
    const first = await applyOperationRequest(makeRequest(payload), db);
    const before = await snapshot();
    const second = await applyOperationRequest(makeRequest(payload), db);
    expect(second.status).toBe("replayed");
    expect(second.server_seq).toBe(first.server_seq);
    expect(await snapshot()).toBe(before);
    await expectApiError(
      () => applyOperationRequest(makeRequest(patchBody({ set: { sender: envelope(6) } })), db),
      "OPERATION_REPLAY_MISMATCH",
      "fingerprint mismatch",
    );
  });

  it("lets only one of two patches share a base revision", async () => {
    const outcomes = await Promise.allSettled([
      applyOperationRequest(makeRequest(patchBody({ set: { sender: envelope(7) } })), db),
      applyOperationRequest(
        makeRequest(patchBody({ operation_id: OPERATION_3, set: { sender: envelope(8) } })),
        db,
      ),
    ]);
    expect(outcomes.filter((o) => o.status === "fulfilled").length).toBe(1);
    const rejected = outcomes.find((o) => o.status === "rejected") as PromiseRejectedResult;
    expect((rejected.reason as { code?: string }).code).toBe("REVISION_CONFLICT");
    expect((await bubbleRow())?.["revision"]).toBe(1);
    expect(await countOf("transaction_guard")).toBe(0);
  });
});

describe("bubble — concurrency and boundaries", () => {
  it("applies a concurrent identical create exactly once", async () => {
    const payload = body({ set: { text: envelope(9), "extensions.kakao.bubble.a": envelope(10) } });
    const results = await Promise.all([
      applyOperationRequest(makeRequest(payload), db),
      applyOperationRequest(makeRequest(payload), db),
    ]);
    expect(results.map((r) => r.status).sort()).toEqual(["applied", "replayed"]);
    expect(results[0].server_seq).toBe(results[1].server_seq);
    expect(await countOf("bubble")).toBe(1);
    expect(await countOf("bubble_extension_field")).toBe(1);
    expect(await countOf("change_log")).toBe(1);
    expect(await nextSeq()).toBe(2);
    expect(await countOf("transaction_guard")).toBe(0);
  });

  it("leaves nothing behind when an order conflict loses", async () => {
    await seedBubble(TURN, MESSAGE_2, 0);
    const before = await snapshot();
    await expectApiError(
      () =>
        applyOperationRequest(
          makeRequest(
            body({ bubble_order: 0, set: { text: envelope(11), "extensions.kakao.bubble.b": envelope(12) } }),
          ),
          db,
        ),
      "BUBBLE_ORDER_CONFLICT",
      "loser leaves no ciphertext",
    );
    expect(await snapshot()).toBe(before);
    expect(await countOf("bubble_extension_field")).toBe(0);
  });

  it("refuses a device writing another space's bubble", async () => {
    const before = await snapshot();
    await expectApiError(
      () => applyOperationRequest(makeRequest(body({ device_id: DEVICE_PHONE }), TOKEN_PHONE), db),
      "AUTH_INVALID",
      "cross-space bubble",
    );
    expect(await snapshot()).toBe(before);
  });

  it("keeps the rules in the validator", () => {
    expect(getOperationSpec("create_bubble").requiresBubbleOrder).toBe(true);
    expect(getOperationSpec("patch_bubble").requiresBubbleOrder).toBe(false);
    expect(getEntityShape("bubble").allowsExtensions).toBe(true);
  });
});
