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
const DEVICE_MAC = "B0000000-0000-4000-8000-000000000001";
const DEVICE_PHONE = "B0000000-0000-4000-8000-000000000002";
const MAC_ROOM = "10000000-0000-4000-8000-000000000T01".replace("T", "A");
const PHONE_ROOM = "10000000-0000-4000-8000-00000000AA02";
const MISSING_ROOM = "10000000-0000-4000-8000-00000000AA03";
const TURN = "30000000-0000-4000-8000-00000000AB01";
const TURN_2 = "30000000-0000-4000-8000-00000000AB02";
const WORLDLINE = "20000000-0000-4000-8000-00000000AC01";
const OPERATION = "90000000-0000-4000-8000-00000000AD01";
const OPERATION_2 = "90000000-0000-4000-8000-00000000AD02";
const OPERATION_3 = "90000000-0000-4000-8000-00000000AD03";
const CHECKPOINT = "60000000-0000-4000-8000-00000000AE01";
const TIMESTAMP = "2026-08-28T00:00:00Z";
const LATER = "2026-08-29T00:00:00Z";
const MAC = "MAC_SPACE";
const PHONE = "PHONE_SPACE";
const EXHAUSTED_SENTINEL = 9007199254740992;

const ENCRYPTED_FIELDS = [
  "canonical_text",
  "heart_changes",
  "generation_profile_ref",
  "fallback_reason",
] as const;

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

function body(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    protocol_version: 1,
    operation_id: OPERATION,
    device_id: DEVICE_MAC,
    op: "create_turn",
    entity_type: "turn",
    target: { space_id: MAC, room_id: MAC_ROOM, worldline_id: null, turn_id: TURN },
    metadata_set: { created_by_device_id: DEVICE_MAC, created_at: TIMESTAMP },
    metadata_clear: [],
    set: {},
    clear: [],
    created_at: LATER,
    ...overrides,
  };
}

function patchBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return body({ op: "patch_turn", operation_id: OPERATION_2, base_revision: 0, metadata_set: {}, ...overrides });
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
         (account_id, space_id, room_id, title_enc, status_message_enc, music_title_enc,
          music_artist_enc, revision, server_seq, created_at, updated_at)
       VALUES (?, ?, ?, NULL, NULL, NULL, NULL, 0, NULL, ?, ?)`,
    )
    .bind(ACCOUNT, spaceId, roomId, TIMESTAMP, TIMESTAMP)
    .run();
}

async function snapshot(): Promise<string> {
  const dump: Record<string, unknown> = {};
  for (const table of [
    "turn",
    "turn_extension_field",
    "room",
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

async function turnRow(key = "", turnId = TURN, spaceId = MAC, roomId = MAC_ROOM) {
  return await db
    .prepare(
      `SELECT * FROM turn
        WHERE account_id = ? AND space_id = ? AND room_id = ? AND worldline_key = ? AND turn_id = ?`,
    )
    .bind(ACCOUNT, spaceId, roomId, key, turnId)
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
    "checkpoint",
    "turn_extension_field",
    "turn",
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
  await insertDevice(DEVICE_MAC, MAC, 1);
  await insertDevice(DEVICE_PHONE, PHONE, 33);
  await insertRoom(MAC, MAC_ROOM);
  await insertRoom(PHONE, PHONE_ROOM);
});

describe("create_turn", () => {
  it("creates a sparse turn at revision 0 with its own provenance", async () => {
    const result = await applyOperationRequest(
      makeRequest(body({ set: { canonical_text: envelope(1) } })),
      db,
    );
    expect(result.status).toBe("applied");
    expect(result.revision).toBe(0);
    expect(result.server_seq).toBe(1);

    const row = await turnRow();
    expect(row?.["canonical_text_enc"]).toBe(envelope(1));
    expect(row?.["heart_changes_enc"]).toBeNull();
    expect(row?.["created_by_device_id"]).toBe(DEVICE_MAC);
    // The metadata timestamp, not the operation's own created_at.
    expect(row?.["created_at"]).toBe(TIMESTAMP);
    expect(row?.["worldline_id"]).toBeNull();
    expect(row?.["worldline_key"]).toBe("");
    expect(row?.["revision"]).toBe(0);
    expect(row?.["server_seq"]).toBe(1);
    expect(row?.["is_tombstoned"]).toBe(0);
    expect(row?.["tombstoned_at"]).toBeNull();
    expect(row?.["tombstone_operation_id"]).toBeNull();

    expect(await nextSeq()).toBe(2);
    expect(await countOf("transaction_guard")).toBe(0);
  });

  it("creates a turn across every encrypted field", async () => {
    const set: Record<string, string> = {};
    ENCRYPTED_FIELDS.forEach((field, index) => {
      set[field] = envelope(10 + index);
    });
    await applyOperationRequest(makeRequest(body({ set })), db);
    const row = await turnRow();
    ENCRYPTED_FIELDS.forEach((field, index) => {
      expect(row?.[`${field}_enc`]).toBe(envelope(10 + index));
    });
  });

  it("records the turn identity in the ledgers", async () => {
    await applyOperationRequest(makeRequest(body()), db);
    const log = await db.prepare("SELECT * FROM operation_log").first<Record<string, unknown>>();
    expect(log?.["entity_type"]).toBe("turn");
    expect(log?.["result_revision"]).toBe(0);

    const change = await db.prepare("SELECT * FROM change_log").first<Record<string, unknown>>();
    expect(change?.["entity_type"]).toBe("turn");
    expect(change?.["revision"]).toBe(0);
    expect(change?.["space_id"]).toBe(MAC);
    expect(change?.["room_id"]).toBe(MAC_ROOM);
    expect(change?.["worldline_key"]).toBe("");
    expect(change?.["turn_id"]).toBe(TURN);
    expect(change?.["message_id"]).toBeNull();
    expect(change?.["checkpoint_id"]).toBeNull();
  });

  it("creates a named-worldline turn with no worldline row present", async () => {
    expect(await countOf("worldline")).toBe(0);
    const result = await applyOperationRequest(
      makeRequest(
        body({
          device_id: DEVICE_PHONE,
          target: { space_id: PHONE, room_id: PHONE_ROOM, worldline_id: WORLDLINE, turn_id: TURN },
          metadata_set: { created_by_device_id: DEVICE_PHONE, created_at: TIMESTAMP },
        }),
        TOKEN_PHONE,
      ),
      db,
    );
    expect(result.status).toBe("applied");
    const row = await turnRow(WORLDLINE, TURN, PHONE, PHONE_ROOM);
    expect(row?.["worldline_id"]).toBe(WORLDLINE);
    expect(row?.["worldline_key"]).toBe(WORLDLINE);
    // Still no worldline row: turn references room only.
    expect(await countOf("worldline")).toBe(0);
  });

  it("keeps the default and named scopes apart", async () => {
    await applyOperationRequest(
      makeRequest(
        body({
          device_id: DEVICE_PHONE,
          target: { space_id: PHONE, room_id: PHONE_ROOM, worldline_id: null, turn_id: TURN },
          metadata_set: { created_by_device_id: DEVICE_PHONE, created_at: TIMESTAMP },
        }),
        TOKEN_PHONE,
      ),
      db,
    );
    const result = await applyOperationRequest(
      makeRequest(
        body({
          operation_id: OPERATION_2,
          device_id: DEVICE_PHONE,
          target: { space_id: PHONE, room_id: PHONE_ROOM, worldline_id: WORLDLINE, turn_id: TURN },
          metadata_set: { created_by_device_id: DEVICE_PHONE, created_at: TIMESTAMP },
        }),
        TOKEN_PHONE,
      ),
      db,
    );
    expect(result.status).toBe("applied");
    expect(await countOf("turn")).toBe(2);
  });

  it("stores turn extensions in the same transaction", async () => {
    await applyOperationRequest(
      makeRequest(body({ set: { "extensions.kakao.turn.mood": envelope(2) } })),
      db,
    );
    const row = await db.prepare("SELECT * FROM turn_extension_field").first<Record<string, unknown>>();
    expect(row?.["extension_key"]).toBe("kakao.turn.mood");
    expect(row?.["turn_id"]).toBe(TURN);
    expect(row?.["worldline_key"]).toBe("");
    expect(await countOf("change_log")).toBe(1);
    expect(await nextSeq()).toBe(2);
  });

  it("reports a missing parent room as ENTITY_NOT_FOUND", async () => {
    const before = await snapshot();
    await expectApiError(
      () =>
        applyOperationRequest(
          makeRequest(body({ target: { space_id: MAC, room_id: MISSING_ROOM, worldline_id: null, turn_id: TURN } })),
          db,
        ),
      "ENTITY_NOT_FOUND",
      "missing room",
    );
    expect(await snapshot()).toBe(before);
  });

  it("refuses provenance naming another device", async () => {
    const before = await snapshot();
    await expectApiError(
      () =>
        applyOperationRequest(
          makeRequest(body({ metadata_set: { created_by_device_id: DEVICE_PHONE, created_at: TIMESTAMP } })),
          db,
        ),
      "VALIDATION_FAILED",
      "device provenance mismatch",
    );
    expect(await snapshot()).toBe(before);
  });

  it("refuses a field with no canonical column", async () => {
    await expectApiError(
      () => applyOperationRequest(makeRequest(body({ set: { title: envelope(3) } })), db),
      "VALIDATION_FAILED",
      "room field on turn",
    );
  });

  it.each(["is_tombstoned", "tombstoned_at", "tombstone_operation_id"])(
    "cannot reach the %s column",
    async (field) => {
      await expectApiError(
        () => applyOperationRequest(makeRequest(body({ set: { [field]: envelope(4) } })), db),
        "VALIDATION_FAILED",
        `${field} is not a wire field`,
      );
    },
  );

  it("reports an existing turn as a conflict at its revision", async () => {
    await applyOperationRequest(makeRequest(body()), db);
    let caught: unknown;
    try {
      await applyOperationRequest(makeRequest(body({ operation_id: OPERATION_2 })), db);
    } catch (error) {
      caught = error;
    }
    expect((caught as { code?: string }).code).toBe("REVISION_CONFLICT");
    expect((caught as { detail?: unknown }).detail).toEqual({ current_revision: 0 });
  });

  it("applies a concurrent identical create exactly once", async () => {
    const payload = body({ set: { canonical_text: envelope(5) } });
    const results = await Promise.all([
      applyOperationRequest(makeRequest(payload), db),
      applyOperationRequest(makeRequest(payload), db),
    ]);
    expect(results.map((r) => r.status).sort()).toEqual(["applied", "replayed"]);
    expect(results[0].server_seq).toBe(results[1].server_seq);
    expect(await countOf("turn")).toBe(1);
    expect(await countOf("change_log")).toBe(1);
    expect(await nextSeq()).toBe(2);
    expect(await countOf("transaction_guard")).toBe(0);
  });

  it("lets only one of two operations create the same turn", async () => {
    const envelopes: Record<string, string> = { [OPERATION]: envelope(6), [OPERATION_2]: envelope(7) };
    const outcomes = await Promise.allSettled([
      applyOperationRequest(makeRequest(body({ set: { canonical_text: envelopes[OPERATION] } })), db),
      applyOperationRequest(
        makeRequest(body({ operation_id: OPERATION_2, set: { canonical_text: envelopes[OPERATION_2] } })),
        db,
      ),
    ]);
    expect(outcomes.filter((o) => o.status === "fulfilled").length).toBe(1);
    const rejected = outcomes.find((o) => o.status === "rejected") as PromiseRejectedResult;
    expect((rejected.reason as { code?: string }).code).toBe("REVISION_CONFLICT");
    expect(await countOf("turn")).toBe(1);
    expect(await nextSeq()).toBe(2);
    const log = await db.prepare("SELECT operation_id FROM operation_log").first<{ operation_id: string }>();
    const winner = log?.operation_id as string;
    const loser = winner === OPERATION ? OPERATION_2 : OPERATION;
    expect((await turnRow())?.["canonical_text_enc"]).toBe(envelopes[winner]);
    expect((await turnRow())?.["canonical_text_enc"]).not.toBe(envelopes[loser]);
  });

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

describe("patch_turn", () => {
  beforeEach(async () => {
    await applyOperationRequest(
      makeRequest(
        body({ set: { canonical_text: envelope(1), "extensions.kakao.turn.mood": envelope(2) } }),
      ),
      db,
    );
  });

  it("advances the revision, rewrites content and leaves provenance alone", async () => {
    const result = await applyOperationRequest(
      makeRequest(patchBody({ set: { heart_changes: envelope(3) }, clear: ["canonical_text"] })),
      db,
    );
    expect(result.revision).toBe(1);
    const row = await turnRow();
    expect(row?.["heart_changes_enc"]).toBe(envelope(3));
    expect(row?.["canonical_text_enc"]).toBeNull();
    expect(row?.["revision"]).toBe(1);
    expect(row?.["created_by_device_id"]).toBe(DEVICE_MAC);
    expect(row?.["created_at"]).toBe(TIMESTAMP);
    expect(row?.["is_tombstoned"]).toBe(0);
  });

  it("replaces and clears an extension", async () => {
    await applyOperationRequest(
      makeRequest(patchBody({ set: { "extensions.kakao.turn.mood": envelope(4) } })),
      db,
    );
    expect(
      (await db.prepare("SELECT envelope_enc FROM turn_extension_field").first<{ envelope_enc: string }>())
        ?.envelope_enc,
    ).toBe(envelope(4));

    await applyOperationRequest(
      makeRequest(
        patchBody({ operation_id: OPERATION_3, base_revision: 1, clear: ["extensions.kakao.turn.mood"] }),
      ),
      db,
    );
    expect(await countOf("turn_extension_field")).toBe(0);
  });

  it("refuses a stale base revision", async () => {
    const before = await snapshot();
    await expectApiError(
      () => applyOperationRequest(makeRequest(patchBody({ base_revision: 5 })), db),
      "REVISION_CONFLICT",
      "stale base_revision",
    );
    expect(await snapshot()).toBe(before);
  });

  it("reports a missing turn as ENTITY_NOT_FOUND", async () => {
    await db.prepare("DELETE FROM turn_extension_field").run();
    await db.prepare("DELETE FROM turn").run();
    await expectApiError(
      () => applyOperationRequest(makeRequest(patchBody()), db),
      "ENTITY_NOT_FOUND",
      "missing turn",
    );
  });

  it("replays a byte-identical retry and rejects different bytes", async () => {
    const payload = patchBody({ set: { heart_changes: envelope(5) } });
    const first = await applyOperationRequest(makeRequest(payload), db);
    const before = await snapshot();
    const second = await applyOperationRequest(makeRequest(payload), db);
    expect(second.status).toBe("replayed");
    expect(second.server_seq).toBe(first.server_seq);
    expect(await snapshot()).toBe(before);

    await expectApiError(
      () => applyOperationRequest(makeRequest(patchBody({ set: { heart_changes: envelope(6) } })), db),
      "OPERATION_REPLAY_MISMATCH",
      "fingerprint mismatch",
    );
  });

  it("lets only one of two patches share a base revision", async () => {
    const outcomes = await Promise.allSettled([
      applyOperationRequest(makeRequest(patchBody({ set: { heart_changes: envelope(7) } })), db),
      applyOperationRequest(
        makeRequest(patchBody({ operation_id: OPERATION_3, set: { heart_changes: envelope(8) } })),
        db,
      ),
    ]);
    expect(outcomes.filter((o) => o.status === "fulfilled").length).toBe(1);
    const rejected = outcomes.find((o) => o.status === "rejected") as PromiseRejectedResult;
    expect((rejected.reason as { code?: string }).code).toBe("REVISION_CONFLICT");
    expect((await turnRow())?.["revision"]).toBe(1);
    expect(await nextSeq()).toBe(3);
    expect(await countOf("transaction_guard")).toBe(0);
  });
});

describe("turn — integration boundaries", () => {
  it("refuses a device writing another space's turn", async () => {
    const before = await snapshot();
    await expectApiError(
      () =>
        applyOperationRequest(
          makeRequest(
            body({
              device_id: DEVICE_PHONE,
              metadata_set: { created_by_device_id: DEVICE_PHONE, created_at: TIMESTAMP },
            }),
            TOKEN_PHONE,
          ),
          db,
        ),
      "AUTH_INVALID",
      "cross-space turn",
    );
    expect(await snapshot()).toBe(before);
  });

  it("produces turns a checkpoint range can reference", async () => {
    await applyOperationRequest(makeRequest(body()), db);
    await applyOperationRequest(
      makeRequest(
        body({
          operation_id: OPERATION_2,
          target: { space_id: MAC, room_id: MAC_ROOM, worldline_id: null, turn_id: TURN_2 },
        }),
      ),
      db,
    );

    const result = await applyOperationRequest(
      makeRequest({
        protocol_version: 1,
        operation_id: OPERATION_3,
        device_id: DEVICE_MAC,
        op: "create_checkpoint",
        entity_type: "checkpoint",
        target: { space_id: MAC, room_id: MAC_ROOM, worldline_id: null, checkpoint_id: CHECKPOINT },
        metadata_set: {
          checkpoint_schema_version: 1,
          owner_space_id: MAC,
          created_by_device_id: DEVICE_MAC,
          created_at: TIMESTAMP,
          first_turn_id: TURN,
          last_turn_id: TURN_2,
        },
        metadata_clear: [],
        set: {},
        clear: [],
        created_at: LATER,
      }),
      db,
    );
    expect(result.status).toBe("applied");
    const checkpoint = await db
      .prepare("SELECT first_turn_id, last_turn_id FROM checkpoint")
      .first<{ first_turn_id: string; last_turn_id: string }>();
    expect(checkpoint?.first_turn_id).toBe(TURN);
    expect(checkpoint?.last_turn_id).toBe(TURN_2);
  });

  it("keeps the rules in the validator", () => {
    expect(getOperationSpec("create_turn").entityType).toBe("turn");
    expect(getEntityShape("turn").worldlineRule).toBe("nullable");
    expect(getEntityShape("turn").allowsExtensions).toBe(true);
  });
});
