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

// Synthetic fixtures only. No real account, device, room or token appears
// here, and nothing prints a whole envelope or a whole token.
const ACCOUNT = "A0000000-0000-4000-8000-00000000000A";
const DEVICE_PHONE = "B0000000-0000-4000-8000-000000000001";
const DEVICE_MAC = "B0000000-0000-4000-8000-000000000004";
const ROOM = "10000000-0000-4000-8000-0000000000E1";
const MAC_ROOM = "10000000-0000-4000-8000-0000000000E2";
const MISSING_ROOM = "10000000-0000-4000-8000-0000000000E3";
const OPERATION = "90000000-0000-4000-8000-000000000020";
const OPERATION_2 = "90000000-0000-4000-8000-000000000021";
const TIMESTAMP = "2026-08-28T00:00:00Z";
const LATER = "2026-08-29T00:00:00Z";
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

function body(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    protocol_version: 1,
    operation_id: OPERATION,
    device_id: DEVICE_PHONE,
    op: "create_group_state",
    entity_type: "group_state",
    target: { space_id: PHONE, room_id: ROOM },
    metadata_set: {},
    metadata_clear: [],
    set: {},
    clear: [],
    created_at: TIMESTAMP,
    ...overrides,
  };
}

function patchBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return body({ op: "patch_group_state", base_revision: 0, created_at: LATER, ...overrides });
}

function makeRequest(payload: unknown, token: string = TOKEN_PHONE): Request {
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
         (account_id, space_id, room_id, origin_space_id, title_enc, status_message_enc,
          music_title_enc, music_artist_enc, revision, server_seq, created_at, updated_at)
       VALUES (?, ?, ?, ?, NULL, NULL, NULL, NULL, 0, NULL, ?, ?)`,
    )
    .bind(ACCOUNT, spaceId, roomId, spaceId, TIMESTAMP, TIMESTAMP)
    .run();
}

async function snapshot(): Promise<string> {
  const tables = ["room", "group_state", "room_extension_field", "account", "operation_log", "change_log"];
  const dump: Record<string, unknown> = {};
  for (const table of tables) {
    const rows = await db.prepare(`SELECT * FROM ${table}`).all();
    dump[table] = rows.results;
  }
  const guards = await db.prepare("SELECT * FROM transaction_guard").all();
  dump["transaction_guard"] = guards.results;
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

async function groupRow(): Promise<Record<string, unknown> | null> {
  return await db
    .prepare("SELECT * FROM group_state WHERE account_id = ? AND space_id = ? AND room_id = ?")
    .bind(ACCOUNT, PHONE, ROOM)
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
    "group_state",
    "room_extension_field",
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
  await insertDevice(DEVICE_PHONE, PHONE, 1);
  await insertDevice(DEVICE_MAC, MAC, 33);
  await insertRoom(PHONE, ROOM);
  await insertRoom(MAC, MAC_ROOM);
});

describe("create_group_state", () => {
  it("creates the row at revision 0 with the first sequence", async () => {
    const result = await applyOperationRequest(
      makeRequest(body({ set: { participants: envelope(1), active_worldline_id: envelope(2) } })),
      db,
    );
    expect(result.status).toBe("applied");
    expect(result.revision).toBe(0);
    expect(result.server_seq).toBe(1);

    const row = await groupRow();
    expect(row?.["participants_enc"]).toBe(envelope(1));
    expect(row?.["active_worldline_id_enc"]).toBe(envelope(2));
    expect(row?.["revision"]).toBe(0);
    expect(row?.["server_seq"]).toBe(1);
    expect(row?.["created_at"]).toBe(TIMESTAMP);
    expect(row?.["updated_at"]).toBe(TIMESTAMP);

    expect(await nextSeq()).toBe(2);
    expect(await countOf("transaction_guard")).toBe(0);

    const change = await db.prepare("SELECT * FROM change_log").first<Record<string, unknown>>();
    expect(change?.["entity_type"]).toBe("group_state");
    expect(change?.["change_kind"]).toBe("upsert");
    expect(change?.["revision"]).toBe(0);
    expect(change?.["space_id"]).toBe(PHONE);
    expect(change?.["room_id"]).toBe(ROOM);
    // A group_state row is room-level: it has no worldline axis at all.
    expect(change?.["worldline_key"]).toBeNull();

    const log = await db.prepare("SELECT * FROM operation_log").first<Record<string, unknown>>();
    expect(log?.["entity_type"]).toBe("group_state");
    expect(log?.["result_revision"]).toBe(0);
  });

  it("leaves the room's own revision and sequence alone", async () => {
    await applyOperationRequest(makeRequest(body()), db);
    const room = await db
      .prepare("SELECT revision, server_seq FROM room WHERE space_id = ? AND room_id = ?")
      .bind(PHONE, ROOM)
      .first<{ revision: number; server_seq: number | null }>();
    expect(room?.revision).toBe(0);
    expect(room?.server_seq).toBeNull();
  });

  it("reports a missing parent room as ENTITY_NOT_FOUND", async () => {
    const before = await snapshot();
    await expectApiError(
      () =>
        applyOperationRequest(
          makeRequest(body({ target: { space_id: PHONE, room_id: MISSING_ROOM } })),
          db,
        ),
      "ENTITY_NOT_FOUND",
      "missing parent room",
    );
    expect(await snapshot()).toBe(before);
  });

  it("reports an existing row as a conflict carrying only its revision", async () => {
    await applyOperationRequest(makeRequest(body()), db);
    const before = await snapshot();
    let caught: unknown;
    try {
      await applyOperationRequest(makeRequest(body({ operation_id: OPERATION_2 })), db);
    } catch (error) {
      caught = error;
    }
    expect((caught as { code?: string }).code).toBe("REVISION_CONFLICT");
    expect((caught as { detail?: unknown }).detail).toEqual({ current_revision: 0 });
    expect(await snapshot()).toBe(before);
  });

  it("applies a concurrent identical create exactly once", async () => {
    const payload = body({ set: { participants: envelope(40) } });
    const results = await Promise.all([
      applyOperationRequest(makeRequest(payload), db),
      applyOperationRequest(makeRequest(payload), db),
    ]);

    expect(results.map((r) => r.status).sort()).toEqual(["applied", "replayed"]);
    expect(results[0].server_seq).toBe(results[1].server_seq);
    expect(results[0].revision).toBe(results[1].revision);
    expect(results[0].revision).toBe(0);

    expect(await countOf("group_state")).toBe(1);
    expect(await countOf("operation_log")).toBe(1);
    expect(await countOf("change_log")).toBe(1);
    // One operation, one sequence: the account moved from 1 to 2, not to 3.
    expect(await nextSeq()).toBe(2);
    expect(await countOf("transaction_guard")).toBe(0);
  });

  it("lets only one of two operations create the same identity", async () => {
    // Distinct envelopes so the stored row proves which operation won and
    // that the loser's ciphertext was never written.
    const envelopes: Record<string, string> = {
      [OPERATION]: envelope(41),
      [OPERATION_2]: envelope(42),
    };
    const outcomes = await Promise.allSettled([
      applyOperationRequest(makeRequest(body({ set: { participants: envelopes[OPERATION] } })), db),
      applyOperationRequest(
        makeRequest(body({ operation_id: OPERATION_2, set: { participants: envelopes[OPERATION_2] } })),
        db,
      ),
    ]);

    expect(outcomes.filter((o) => o.status === "fulfilled").length).toBe(1);
    const rejected = outcomes.find((o) => o.status === "rejected") as PromiseRejectedResult;
    expect((rejected.reason as { code?: string }).code).toBe("REVISION_CONFLICT");

    expect(await countOf("group_state")).toBe(1);
    expect(await countOf("operation_log")).toBe(1);
    expect(await countOf("change_log")).toBe(1);
    expect(await nextSeq()).toBe(2);
    expect(await countOf("transaction_guard")).toBe(0);

    const log = await db.prepare("SELECT operation_id FROM operation_log").first<{ operation_id: string }>();
    const winner = log?.operation_id as string;
    const loser = winner === OPERATION ? OPERATION_2 : OPERATION;
    const row = await groupRow();
    expect(row?.["participants_enc"]).toBe(envelopes[winner]);
    expect(row?.["participants_enc"]).not.toBe(envelopes[loser]);
  });
});

describe("patch_group_state", () => {
  beforeEach(async () => {
    await applyOperationRequest(
      makeRequest(body({ set: { participants: envelope(1), active_worldline_id: envelope(2) } })),
      db,
    );
  });

  it("advances the revision and clears a field", async () => {
    const result = await applyOperationRequest(
      makeRequest(
        patchBody({ operation_id: OPERATION_2, set: { participants: envelope(3) }, clear: ["active_worldline_id"] }),
      ),
      db,
    );
    expect(result.status).toBe("applied");
    expect(result.revision).toBe(1);
    expect(result.server_seq).toBe(2);

    const row = await groupRow();
    expect(row?.["participants_enc"]).toBe(envelope(3));
    expect(row?.["active_worldline_id_enc"]).toBeNull();
    expect(row?.["revision"]).toBe(1);
    expect(row?.["server_seq"]).toBe(2);
    expect(row?.["created_at"]).toBe(TIMESTAMP);
    expect(row?.["updated_at"]).toBe(LATER);
    expect(await nextSeq()).toBe(3);
  });

  it("refuses a stale base_revision and changes nothing", async () => {
    const before = await snapshot();
    await expectApiError(
      () => applyOperationRequest(makeRequest(patchBody({ operation_id: OPERATION_2, base_revision: 5 })), db),
      "REVISION_CONFLICT",
      "stale base_revision",
    );
    expect(await snapshot()).toBe(before);
    expect(await countOf("transaction_guard")).toBe(0);
  });

  it("reports a missing entity as ENTITY_NOT_FOUND", async () => {
    await db.prepare("DELETE FROM group_state").run();
    const before = await snapshot();
    await expectApiError(
      () => applyOperationRequest(makeRequest(patchBody({ operation_id: OPERATION_2 })), db),
      "ENTITY_NOT_FOUND",
      "missing group_state",
    );
    expect(await snapshot()).toBe(before);
  });

  it("returns the first result for a byte-identical retry", async () => {
    const payload = patchBody({ operation_id: OPERATION_2, set: { participants: envelope(4) } });
    const first = await applyOperationRequest(makeRequest(payload), db);
    const before = await snapshot();
    const second = await applyOperationRequest(makeRequest(payload), db);
    expect(second.status).toBe("replayed");
    expect(second.server_seq).toBe(first.server_seq);
    expect(second.revision).toBe(first.revision);
    expect(await snapshot()).toBe(before);
  });

  it("rejects the same operation_id with different bytes", async () => {
    await applyOperationRequest(
      makeRequest(patchBody({ operation_id: OPERATION_2, set: { participants: envelope(5) } })),
      db,
    );
    const before = await snapshot();
    await expectApiError(
      () =>
        applyOperationRequest(
          makeRequest(patchBody({ operation_id: OPERATION_2, set: { participants: envelope(6) } })),
          db,
        ),
      "OPERATION_REPLAY_MISMATCH",
      "fingerprint mismatch",
    );
    expect(await snapshot()).toBe(before);
  });

  it("applies concurrent identical patches exactly once", async () => {
    const payload = patchBody({ operation_id: OPERATION_2, set: { participants: envelope(7) } });
    const results = await Promise.all([
      applyOperationRequest(makeRequest(payload), db),
      applyOperationRequest(makeRequest(payload), db),
    ]);
    expect(results.map((r) => r.status).sort()).toEqual(["applied", "replayed"]);
    expect(await nextSeq()).toBe(3);
    expect(await countOf("change_log")).toBe(2);
    expect(await countOf("transaction_guard")).toBe(0);
  });

  it("lets only one of two patches share the same base revision", async () => {
    const outcomes = await Promise.allSettled([
      applyOperationRequest(makeRequest(patchBody({ operation_id: OPERATION_2, set: { participants: envelope(8) } })), db),
      applyOperationRequest(
        makeRequest(
          patchBody({
            operation_id: "90000000-0000-4000-8000-000000000022",
            set: { participants: envelope(9) },
          }),
        ),
        db,
      ),
    ]);
    expect(outcomes.filter((o) => o.status === "fulfilled").length).toBe(1);
    const rejected = outcomes.find((o) => o.status === "rejected") as PromiseRejectedResult;
    expect((rejected.reason as { code?: string }).code).toBe("REVISION_CONFLICT");
    const row = await groupRow();
    expect(row?.["revision"]).toBe(1);
    expect(await nextSeq()).toBe(3);
    expect(await countOf("change_log")).toBe(2);
  });
});

describe("group_state — boundaries", () => {
  it("refuses a MAC device writing a PHONE_SPACE group_state", async () => {
    const before = await snapshot();
    await expectApiError(
      () => applyOperationRequest(makeRequest(body({ device_id: DEVICE_MAC }), TOKEN_MAC), db),
      "AUTH_INVALID",
      "cross-space group_state",
    );
    expect(await snapshot()).toBe(before);
  });

  it("refuses a non-PHONE target outright", async () => {
    await expectApiError(
      () =>
        applyOperationRequest(
          makeRequest(body({ device_id: DEVICE_MAC, target: { space_id: MAC, room_id: MAC_ROOM } }), TOKEN_MAC),
          db,
        ),
      "VALIDATION_FAILED",
      "group_state outside PHONE_SPACE",
    );
  });

  it("refuses an extension path before the handler sees it", async () => {
    const before = await snapshot();
    await expectApiError(
      () =>
        applyOperationRequest(
          makeRequest(body({ set: { "extensions.kakao.group.mood": envelope(10) } })),
          db,
        ),
      "VALIDATION_FAILED",
      "group_state has no extension table",
    );
    expect(await snapshot()).toBe(before);
  });

  it("refuses a field with no canonical column", async () => {
    await expectApiError(
      () => applyOperationRequest(makeRequest(body({ set: { title: envelope(11) } })), db),
      "VALIDATION_FAILED",
      "room field on group_state",
    );
  });

  it("fails closed when the account sequence is exhausted", async () => {
    await db
      .prepare("UPDATE account SET next_server_seq = ? WHERE account_id = ?")
      .bind(EXHAUSTED_SENTINEL, ACCOUNT)
      .run();
    const before = await snapshot();
    await expectApiError(
      () => applyOperationRequest(makeRequest(body({ set: { participants: envelope(12) } })), db),
      "STORAGE_UNAVAILABLE",
      "sequence sentinel",
    );
    expect(await snapshot()).toBe(before);
  });

  it("keeps the rules in the validator", () => {
    expect(getOperationSpec("create_group_state").phoneSpaceOnly).toBe(true);
    expect(getEntityShape("group_state").worldlineRule).toBe("absent");
    expect(getEntityShape("group_state").allowsExtensions).toBe(false);
  });
});
