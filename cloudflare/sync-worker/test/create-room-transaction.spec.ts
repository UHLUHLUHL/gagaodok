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

// Synthetic fixtures only: no real account, device, room or token appears
// here, and nothing prints a whole envelope or a whole token.
const ACCOUNT = "A0000000-0000-4000-8000-00000000000A";
const ACCOUNT_B = "A0000000-0000-4000-8000-00000000000B";
const DEVICE_PHONE = "B0000000-0000-4000-8000-000000000001";
const DEVICE_MAC = "B0000000-0000-4000-8000-000000000004";
const NEW_ROOM = "10000000-0000-4000-8000-0000000000D1";
const EXISTING_ROOM = "10000000-0000-4000-8000-0000000000D2";
const OPERATION = "90000000-0000-4000-8000-000000000010";
const OPERATION_2 = "90000000-0000-4000-8000-000000000011";
const TIMESTAMP = "2026-08-28T00:00:00Z";
const PHONE = "PHONE_SPACE";
const MAC = "MAC_SPACE";
const EXHAUSTED_SENTINEL = 9007199254740992;

function syntheticTokenBytes(seed: number): Uint8Array {
  const bytes = new Uint8Array(32);
  for (let index = 0; index < bytes.length; index += 1) {
    bytes[index] = (seed + index) & 0xff;
  }
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

const TOKEN_PHONE = `gdt1_${base64Url(syntheticTokenBytes(1))}`;
const TOKEN_MAC = `gdt1_${base64Url(syntheticTokenBytes(33))}`;

function envelope(seed: number): string {
  const bytes = new Uint8Array(34);
  bytes[0] = 1;
  bytes[1] = 1;
  for (let index = 2; index < bytes.length; index += 1) {
    bytes[index] = (seed + index) & 0xff;
  }
  return base64(bytes);
}

function createRoomBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    protocol_version: 1,
    operation_id: OPERATION,
    device_id: DEVICE_PHONE,
    op: "create_room",
    entity_type: "room",
    target: { space_id: PHONE, room_id: NEW_ROOM, worldline_id: null },
    metadata_set: {},
    metadata_clear: [],
    set: {},
    clear: [],
    created_at: TIMESTAMP,
    ...overrides,
  };
}

function makeRequest(body: unknown, token: string = TOKEN_PHONE): Request {
  return new Request("https://example.test/v1/sync/operations", {
    method: "POST",
    headers: new Headers({ Authorization: `Device ${token}` }),
    body: JSON.stringify(body),
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

async function insertDevice(
  accountId: string,
  deviceId: string,
  spaceId: string,
  tokenSeed: number,
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO device
         (account_id, device_id, space_id, platform, display_name_enc,
          linked_at, revoked_at, key_generation, token_hash)
       VALUES (?, ?, ?, 'android_phone', NULL, ?, NULL, 1, ?)`,
    )
    .bind(accountId, deviceId, spaceId, TIMESTAMP, await sha256Hex(syntheticTokenBytes(tokenSeed)))
    .run();
}

async function insertRoom(accountId: string, spaceId: string, roomId: string): Promise<void> {
  await db
    .prepare(
      `INSERT INTO room
         (account_id, space_id, room_id, origin_space_id, title_enc, status_message_enc,
          music_title_enc, music_artist_enc, revision, server_seq, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, NULL, NULL, NULL, 3, NULL, ?, ?)`,
    )
    .bind(accountId, spaceId, roomId, spaceId, envelope(100), TIMESTAMP, TIMESTAMP)
    .run();
}

/** Every surface a create may touch, for before/after comparison. */
async function snapshot(): Promise<string> {
  const rooms = await db.prepare("SELECT * FROM room ORDER BY account_id, space_id, room_id").all();
  const extensions = await db
    .prepare("SELECT * FROM room_extension_field ORDER BY space_id, room_id, extension_key")
    .all();
  const refs = await db.prepare("SELECT * FROM room_ai_state_ref").all();
  const accounts = await db.prepare("SELECT * FROM account ORDER BY account_id").all();
  const operations = await db.prepare("SELECT * FROM operation_log ORDER BY account_id, operation_id").all();
  const changes = await db.prepare("SELECT * FROM change_log ORDER BY account_id, server_seq").all();
  const guards = await db.prepare("SELECT * FROM transaction_guard").all();
  return JSON.stringify({
    rooms: rooms.results,
    extensions: extensions.results,
    refs: refs.results,
    accounts: accounts.results,
    operations: operations.results,
    changes: changes.results,
    guards: guards.results,
  });
}

async function countOf(table: string): Promise<number> {
  const row = await db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).first<{ n: number }>();
  return row?.n ?? 0;
}

async function nextSeq(accountId: string = ACCOUNT): Promise<number> {
  const row = await db
    .prepare("SELECT next_server_seq FROM account WHERE account_id = ?")
    .bind(accountId)
    .first<{ next_server_seq: number }>();
  return row?.next_server_seq ?? -1;
}

beforeAll(async () => {
  await applyD1Migrations(db, env.TEST_MIGRATIONS);
});

beforeEach(async () => {
  for (const table of [
    "transaction_guard",
    "change_log",
    "operation_log",
    "room_ai_state_ref",
    "room_extension_field",
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
  await insertDevice(ACCOUNT, DEVICE_PHONE, PHONE, 1);
  await insertDevice(ACCOUNT, DEVICE_MAC, MAC, 33);
  // A room that already exists, and the same UUID owned by another account.
  await insertRoom(ACCOUNT, PHONE, EXISTING_ROOM);
  await insertRoom(ACCOUNT_B, PHONE, NEW_ROOM);
});

describe("applyOperationRequest — create_room", () => {
  it("creates an empty room at revision 0 and the first sequence", async () => {
    const result = await applyOperationRequest(makeRequest(createRoomBody()), db);

    expect(result.status).toBe("applied");
    expect(result.revision).toBe(0);
    expect(result.server_seq).toBe(1);

    const room = await db
      .prepare("SELECT * FROM room WHERE account_id = ? AND space_id = ? AND room_id = ?")
      .bind(ACCOUNT, PHONE, NEW_ROOM)
      .first<Record<string, unknown>>();
    expect(room?.["revision"]).toBe(0);
    expect(room?.["server_seq"]).toBe(1);
    expect(room?.["created_at"]).toBe(TIMESTAMP);
    expect(room?.["updated_at"]).toBe(TIMESTAMP);
    expect(room?.["title_enc"]).toBeNull();
    expect(room?.["origin_space_id"]).toBe(PHONE);

    expect(await nextSeq()).toBe(2);
    expect(await countOf("operation_log")).toBe(1);
    expect(await countOf("change_log")).toBe(1);
    expect(await countOf("transaction_guard")).toBe(0);
    // A create never invents an AI reference row.
    expect(await countOf("room_ai_state_ref")).toBe(0);

    const change = await db.prepare("SELECT * FROM change_log").first<Record<string, unknown>>();
    expect(change?.["entity_type"]).toBe("room");
    expect(change?.["change_kind"]).toBe("upsert");
    expect(change?.["revision"]).toBe(0);
    expect(change?.["space_id"]).toBe(PHONE);
    expect(change?.["room_id"]).toBe(NEW_ROOM);
    expect(change?.["worldline_key"]).toBeNull();

    const log = await db.prepare("SELECT * FROM operation_log").first<Record<string, unknown>>();
    expect(log?.["result_revision"]).toBe(0);
    expect(log?.["server_seq"]).toBe(1);
  });

  it("stores encrypted room fields and leaves cleared ones null", async () => {
    await applyOperationRequest(
      makeRequest(
        createRoomBody({
          set: { title: envelope(1), music_title: envelope(2) },
          clear: ["status_message"],
        }),
      ),
      db,
    );
    const room = await db
      .prepare("SELECT * FROM room WHERE account_id = ? AND space_id = ? AND room_id = ?")
      .bind(ACCOUNT, PHONE, NEW_ROOM)
      .first<Record<string, unknown>>();
    expect(room?.["title_enc"]).toBe(envelope(1));
    expect(room?.["music_title_enc"]).toBe(envelope(2));
    // A clear on a row that is being created is simply the absent value.
    expect(room?.["status_message_enc"]).toBeNull();
    expect(room?.["music_artist_enc"]).toBeNull();
  });

  it("writes extension envelopes in the same transaction and no-ops a clear", async () => {
    await applyOperationRequest(
      makeRequest(
        createRoomBody({
          set: { "extensions.kakao.room.mood": envelope(3) },
          clear: ["extensions.kakao.room.absent"],
        }),
      ),
      db,
    );
    const rows = await db.prepare("SELECT * FROM room_extension_field").all();
    expect(rows.results.length).toBe(1);
    expect((rows.results[0] as Record<string, unknown>)["extension_key"]).toBe("kakao.room.mood");
    // The extension rides the room's revision; it mints none of its own.
    expect(await nextSeq()).toBe(2);
    expect(await countOf("change_log")).toBe(1);
  });

  it("rejects a room field name with no canonical column", async () => {
    const before = await snapshot();
    await expectApiError(
      () => applyOperationRequest(makeRequest(createRoomBody({ set: { avatar_ref: envelope(4) } })), db),
      "VALIDATION_FAILED",
      "unmapped room field",
    );
    expect(await snapshot()).toBe(before);
  });
});

describe("create_room — identity and authority", () => {
  it("takes the account from the token, not from anything in the body", async () => {
    await applyOperationRequest(makeRequest(createRoomBody()), db);
    const mine = await db
      .prepare("SELECT account_id FROM room WHERE space_id = ? AND room_id = ? ORDER BY account_id")
      .bind(PHONE, NEW_ROOM)
      .all();
    // Account B's identically-named room predates this and is untouched.
    expect(mine.results.map((row) => (row as Record<string, unknown>)["account_id"])).toEqual([
      ACCOUNT,
      ACCOUNT_B,
    ]);
    const other = await db
      .prepare("SELECT revision FROM room WHERE account_id = ? AND room_id = ?")
      .bind(ACCOUNT_B, NEW_ROOM)
      .first<{ revision: number }>();
    expect(other?.revision).toBe(3);
  });

  it("stores a continuation shard separately under the same room UUID", async () => {
    await applyOperationRequest(
      makeRequest(
        createRoomBody({
          device_id: DEVICE_MAC,
          target: { space_id: MAC, room_id: NEW_ROOM, worldline_id: null },
        }),
        TOKEN_MAC,
      ),
      db,
    );
    const result = await applyOperationRequest(
      makeRequest(
        createRoomBody({
          operation_id: OPERATION_2,
          metadata_set: { origin_space_id: MAC },
        }),
      ),
      db,
    );
    expect(result.status).toBe("applied");
    expect(result.server_seq).toBe(2);
    expect(await countOf("room")).toBe(4);
  });

  it("refuses a phone device creating a MAC_SPACE room", async () => {
    const before = await snapshot();
    await expectApiError(
      () =>
        applyOperationRequest(
          makeRequest(createRoomBody({ target: { space_id: MAC, room_id: NEW_ROOM, worldline_id: null } })),
          db,
        ),
      "AUTH_INVALID",
      "cross-space create",
    );
    expect(await snapshot()).toBe(before);
  });
});

describe("create_room — replay, conflict and concurrency", () => {
  it("returns the first result for a byte-identical retry", async () => {
    const body = createRoomBody({ set: { title: envelope(5) } });
    const first = await applyOperationRequest(makeRequest(body), db);
    const before = await snapshot();
    const second = await applyOperationRequest(makeRequest(body), db);

    expect(second.status).toBe("replayed");
    expect(second.server_seq).toBe(first.server_seq);
    expect(second.revision).toBe(0);
    expect(await snapshot()).toBe(before);
  });

  it("rejects the same operation_id with different bytes", async () => {
    await applyOperationRequest(makeRequest(createRoomBody({ set: { title: envelope(6) } })), db);
    const before = await snapshot();
    await expectApiError(
      () => applyOperationRequest(makeRequest(createRoomBody({ set: { title: envelope(7) } })), db),
      "OPERATION_REPLAY_MISMATCH",
      "fingerprint mismatch",
    );
    expect(await snapshot()).toBe(before);
  });

  it("reports an already existing room as a conflict, with only its revision", async () => {
    const before = await snapshot();
    let caught: unknown;
    try {
      await applyOperationRequest(
        makeRequest(createRoomBody({ target: { space_id: PHONE, room_id: EXISTING_ROOM, worldline_id: null } })),
        db,
      );
    } catch (error) {
      caught = error;
    }
    expect((caught as { code?: string }).code).toBe("REVISION_CONFLICT");
    expect((caught as { detail?: unknown }).detail).toEqual({ current_revision: 3 });
    expect(await snapshot()).toBe(before);
  });

  it("applies a concurrent identical create exactly once", async () => {
    const body = createRoomBody({ set: { title: envelope(8) } });
    const results = await Promise.all([
      applyOperationRequest(makeRequest(body), db),
      applyOperationRequest(makeRequest(body), db),
    ]);
    expect(results.map((r) => r.status).sort()).toEqual(["applied", "replayed"]);
    expect(results[0].server_seq).toBe(results[1].server_seq);
    expect(await nextSeq()).toBe(2);
    expect(await countOf("change_log")).toBe(1);
    expect(await countOf("transaction_guard")).toBe(0);
  });

  it("lets only one of two different operations create the same room", async () => {
    const outcomes = await Promise.allSettled([
      applyOperationRequest(makeRequest(createRoomBody()), db),
      applyOperationRequest(makeRequest(createRoomBody({ operation_id: OPERATION_2 })), db),
    ]);
    const fulfilled = outcomes.filter((o) => o.status === "fulfilled");
    const rejected = outcomes.filter((o) => o.status === "rejected");
    expect(fulfilled.length).toBe(1);
    expect(rejected.length).toBe(1);
    expect(((rejected[0] as PromiseRejectedResult).reason as { code?: string }).code).toBe(
      "REVISION_CONFLICT",
    );
    expect(await nextSeq()).toBe(2);
    expect(await countOf("change_log")).toBe(1);
    expect(await countOf("operation_log")).toBe(1);
    expect(await countOf("transaction_guard")).toBe(0);
  });
});

describe("create_room — refusals consume nothing", () => {
  it("fails closed when the account sequence is exhausted", async () => {
    await db
      .prepare("UPDATE account SET next_server_seq = ? WHERE account_id = ?")
      .bind(EXHAUSTED_SENTINEL, ACCOUNT)
      .run();
    const before = await snapshot();
    await expectApiError(
      () => applyOperationRequest(makeRequest(createRoomBody({ set: { title: envelope(9) } })), db),
      "STORAGE_UNAVAILABLE",
      "sequence sentinel",
    );
    expect(await snapshot()).toBe(before);
  });

  it("rejects a malformed extension key before touching storage", async () => {
    const before = await snapshot();
    await expectApiError(
      () =>
        applyOperationRequest(
          makeRequest(createRoomBody({ set: { "extensions.KAKAO.room.mood": envelope(10) } })),
          db,
        ),
      "VALIDATION_FAILED",
      "malformed extension key",
    );
    expect(await snapshot()).toBe(before);
  });

  it("rejects a base_revision on a create", async () => {
    const before = await snapshot();
    await expectApiError(
      () => applyOperationRequest(makeRequest(createRoomBody({ base_revision: 0 })), db),
      "VALIDATION_FAILED",
      "base_revision on create",
    );
    expect(await snapshot()).toBe(before);
  });

  it("keeps the room family rules in the validator, not in the handler", () => {
    expect(getOperationSpec("create_room").entityType).toBe("room");
    expect(getOperationSpec("create_room").kind).toBe("create");
    expect(getEntityShape("room").worldlineRule).toBe("null-only");
  });
});
