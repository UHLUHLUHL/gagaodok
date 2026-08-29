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

// Synthetic fixtures only.
const ACCOUNT = "A0000000-0000-4000-8000-00000000000A";
const DEVICE_MAC = "B0000000-0000-4000-8000-000000000001";
const DEVICE_PHONE = "B0000000-0000-4000-8000-000000000002";
const ROOM = "10000000-0000-4000-8000-000000000C01";
const PHONE_ROOM = "10000000-0000-4000-8000-000000000C02";
const MISSING_ROOM = "10000000-0000-4000-8000-000000000C03";
const CHECKPOINT = "60000000-0000-4000-8000-000000000C10";
const TURN_A = "30000000-0000-4000-8000-000000000C20";
const TURN_B = "30000000-0000-4000-8000-000000000C21";
const PHONE_TURN = "30000000-0000-4000-8000-000000000C22";
const WORLDLINE = "20000000-0000-4000-8000-000000000C30";
const OPERATION = "90000000-0000-4000-8000-000000000C40";
const OPERATION_2 = "90000000-0000-4000-8000-000000000C41";
const OPERATION_3 = "90000000-0000-4000-8000-000000000C42";
const TIMESTAMP = "2026-08-28T00:00:00Z";
const LATER = "2026-08-29T00:00:00Z";
const MAC = "MAC_SPACE";
const PHONE = "PHONE_SPACE";
const EXHAUSTED_SENTINEL = 9007199254740992;

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

function createMetadata(extra: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    checkpoint_schema_version: 1,
    owner_space_id: MAC,
    created_by_device_id: DEVICE_MAC,
    created_at: TIMESTAMP,
    ...extra,
  };
}

function body(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    protocol_version: 1,
    operation_id: OPERATION,
    device_id: DEVICE_MAC,
    op: "create_checkpoint",
    entity_type: "checkpoint",
    target: { space_id: MAC, room_id: ROOM, worldline_id: null, checkpoint_id: CHECKPOINT },
    metadata_set: createMetadata(),
    metadata_clear: [],
    set: {},
    clear: [],
    created_at: LATER,
    ...overrides,
  };
}

function patchBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return body({
    op: "patch_checkpoint",
    operation_id: OPERATION_2,
    base_revision: 0,
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

async function insertTurn(
  spaceId: string,
  roomId: string,
  turnId: string,
  worldlineId: string | null,
  deviceId: string,
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO turn
         (account_id, space_id, room_id, worldline_id, worldline_key, turn_id,
          created_by_device_id, created_at, revision, server_seq, is_tombstoned)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, NULL, 0)`,
    )
    .bind(ACCOUNT, spaceId, roomId, worldlineId, worldlineId ?? "", turnId, deviceId, TIMESTAMP)
    .run();
}

async function snapshot(): Promise<string> {
  const dump: Record<string, unknown> = {};
  for (const table of ["checkpoint", "room", "turn", "account", "operation_log", "change_log", "transaction_guard"]) {
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

async function checkpointRow(): Promise<Record<string, unknown> | null> {
  return await db
    .prepare(
      `SELECT * FROM checkpoint
        WHERE account_id = ? AND space_id = ? AND room_id = ? AND worldline_key = ?
          AND checkpoint_id = ?`,
    )
    .bind(ACCOUNT, MAC, ROOM, "", CHECKPOINT)
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
  await insertRoom(MAC, ROOM);
  await insertRoom(PHONE, PHONE_ROOM);
  await insertTurn(MAC, ROOM, TURN_A, null, DEVICE_MAC);
  await insertTurn(MAC, ROOM, TURN_B, null, DEVICE_MAC);
  await insertTurn(PHONE, PHONE_ROOM, PHONE_TURN, null, DEVICE_PHONE);
});

describe("create_checkpoint", () => {
  it("stores the encrypted payload, the metadata and revision 0", async () => {
    const result = await applyOperationRequest(
      makeRequest(
        body({
          set: { segments: envelope(1), summary_text: envelope(2), compaction_profile_id: envelope(3) },
          metadata_set: createMetadata({ compaction_compat_tag: "tag-1" }),
        }),
      ),
      db,
    );
    expect(result.status).toBe("applied");
    expect(result.revision).toBe(0);
    expect(result.server_seq).toBe(1);

    const row = await checkpointRow();
    expect(row?.["segments_enc"]).toBe(envelope(1));
    expect(row?.["summary_text_enc"]).toBe(envelope(2));
    expect(row?.["compaction_profile_id_enc"]).toBe(envelope(3));
    expect(row?.["compaction_contract_fingerprint_enc"]).toBeNull();
    expect(row?.["checkpoint_schema_version"]).toBe(1);
    expect(row?.["compaction_compat_tag"]).toBe("tag-1");
    expect(row?.["owner_space_id"]).toBe(MAC);
    expect(row?.["created_by_device_id"]).toBe(DEVICE_MAC);
    // The row's provenance timestamp is the metadata value, not the
    // operation's own created_at.
    expect(row?.["created_at"]).toBe(TIMESTAMP);
    expect(row?.["revision"]).toBe(0);
    expect(row?.["worldline_key"]).toBe("");
    expect(row?.["worldline_id"]).toBeNull();

    const change = await db.prepare("SELECT * FROM change_log").first<Record<string, unknown>>();
    expect(change?.["entity_type"]).toBe("checkpoint");
    expect(change?.["revision"]).toBe(0);
    expect(change?.["space_id"]).toBe(MAC);
    expect(change?.["room_id"]).toBe(ROOM);
    // The default scope's empty key is a real identity value, not a null.
    expect(change?.["worldline_key"]).toBe("");
    expect(change?.["checkpoint_id"]).toBe(CHECKPOINT);
    expect(change?.["turn_id"]).toBeNull();
    expect(await countOf("transaction_guard")).toBe(0);
  });

  it("accepts a legacy checkpoint with no range and no through sequence", async () => {
    await applyOperationRequest(makeRequest(body()), db);
    const row = await checkpointRow();
    expect(row?.["first_turn_id"]).toBeNull();
    expect(row?.["last_turn_id"]).toBeNull();
    expect(row?.["through_server_seq"]).toBeNull();
  });

  it("stores a turn range in the same scope", async () => {
    await applyOperationRequest(
      makeRequest(body({ metadata_set: createMetadata({ first_turn_id: TURN_A, last_turn_id: TURN_B }) })),
      db,
    );
    const row = await checkpointRow();
    expect(row?.["first_turn_id"]).toBe(TURN_A);
    expect(row?.["last_turn_id"]).toBe(TURN_B);
  });

  it("reports a range turn from another room as ENTITY_NOT_FOUND", async () => {
    const before = await snapshot();
    await expectApiError(
      () =>
        applyOperationRequest(
          makeRequest(body({ metadata_set: createMetadata({ first_turn_id: PHONE_TURN, last_turn_id: TURN_B }) })),
          db,
        ),
      "ENTITY_NOT_FOUND",
      "cross-scope turn range",
    );
    expect(await snapshot()).toBe(before);
  });

  it("reports an unknown range turn as ENTITY_NOT_FOUND", async () => {
    await expectApiError(
      () =>
        applyOperationRequest(
          makeRequest(
            body({
              metadata_set: createMetadata({
                first_turn_id: "30000000-0000-4000-8000-000000000CFF",
                last_turn_id: TURN_B,
              }),
            }),
          ),
          db,
        ),
      "ENTITY_NOT_FOUND",
      "unknown turn",
    );
  });

  it("reports a missing parent room as ENTITY_NOT_FOUND", async () => {
    const before = await snapshot();
    await expectApiError(
      () =>
        applyOperationRequest(
          makeRequest(
            body({ target: { space_id: MAC, room_id: MISSING_ROOM, worldline_id: null, checkpoint_id: CHECKPOINT } }),
          ),
          db,
        ),
      "ENTITY_NOT_FOUND",
      "missing room",
    );
    expect(await snapshot()).toBe(before);
  });

  it("refuses provenance that does not match the request", async () => {
    const before = await snapshot();
    await expectApiError(
      () => applyOperationRequest(makeRequest(body({ metadata_set: createMetadata({ owner_space_id: PHONE }) })), db),
      "VALIDATION_FAILED",
      "owner_space_id mismatch",
    );
    await expectApiError(
      () =>
        applyOperationRequest(
          makeRequest(body({ metadata_set: createMetadata({ created_by_device_id: DEVICE_PHONE }) })),
          db,
        ),
      "VALIDATION_FAILED",
      "created_by_device_id mismatch",
    );
    expect(await snapshot()).toBe(before);
  });

  it("reports an existing checkpoint as a conflict at revision 0", async () => {
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
});

describe("checkpoint — through_server_seq", () => {
  it("accepts a sequence already issued", async () => {
    // Consume sequence 1 with an unrelated checkpoint so 1 is in the past.
    await applyOperationRequest(makeRequest(body()), db);
    const result = await applyOperationRequest(
      makeRequest(
        body({
          operation_id: OPERATION_2,
          target: {
            space_id: MAC,
            room_id: ROOM,
            worldline_id: null,
            checkpoint_id: "60000000-0000-4000-8000-000000000C11",
          },
          metadata_set: createMetadata({ through_server_seq: 1 }),
        }),
      ),
      db,
    );
    expect(result.status).toBe("applied");
    expect(result.server_seq).toBe(2);
  });

  it("refuses the sequence this very operation would take", async () => {
    const before = await snapshot();
    await expectApiError(
      () =>
        applyOperationRequest(makeRequest(body({ metadata_set: createMetadata({ through_server_seq: 1 }) })), db),
      "VALIDATION_FAILED",
      "through_server_seq is the pending sequence",
    );
    expect(await snapshot()).toBe(before);
    expect(await nextSeq()).toBe(1);
  });

  it("refuses a future sequence and consumes nothing", async () => {
    const before = await snapshot();
    await expectApiError(
      () =>
        applyOperationRequest(makeRequest(body({ metadata_set: createMetadata({ through_server_seq: 99 }) })), db),
      "VALIDATION_FAILED",
      "future through_server_seq",
    );
    expect(await snapshot()).toBe(before);
    expect(await nextSeq()).toBe(1);
  });
});

describe("patch_checkpoint", () => {
  beforeEach(async () => {
    await applyOperationRequest(
      makeRequest(body({ set: { segments: envelope(1) }, metadata_set: createMetadata({ compaction_compat_tag: "tag-1" }) })),
      db,
    );
  });

  it("advances the revision and rewrites payload and metadata", async () => {
    const result = await applyOperationRequest(
      makeRequest(
        patchBody({
          set: { summary_text: envelope(4) },
          clear: ["segments"],
          metadata_set: { compaction_compat_tag: "tag-2" },
        }),
      ),
      db,
    );
    expect(result.status).toBe("applied");
    expect(result.revision).toBe(1);
    const row = await checkpointRow();
    expect(row?.["summary_text_enc"]).toBe(envelope(4));
    expect(row?.["segments_enc"]).toBeNull();
    expect(row?.["compaction_compat_tag"]).toBe("tag-2");
    expect(row?.["revision"]).toBe(1);
    // Provenance is untouched by a patch.
    expect(row?.["created_at"]).toBe(TIMESTAMP);
    expect(row?.["owner_space_id"]).toBe(MAC);
  });

  it("clears a metadata pair together", async () => {
    await applyOperationRequest(
      makeRequest(patchBody({ metadata_set: { first_turn_id: TURN_A, last_turn_id: TURN_B } })),
      db,
    );
    await applyOperationRequest(
      makeRequest(
        patchBody({
          operation_id: OPERATION_3,
          base_revision: 1,
          metadata_clear: ["first_turn_id", "last_turn_id"],
        }),
      ),
      db,
    );
    const row = await checkpointRow();
    expect(row?.["first_turn_id"]).toBeNull();
    expect(row?.["last_turn_id"]).toBeNull();
  });

  it("keeps an unmentioned through_server_seq as it is", async () => {
    await applyOperationRequest(
      makeRequest(patchBody({ metadata_set: { through_server_seq: 1 } })),
      db,
    );
    await applyOperationRequest(
      makeRequest(patchBody({ operation_id: OPERATION_3, base_revision: 1, set: { summary_text: envelope(5) } })),
      db,
    );
    const row = await checkpointRow();
    expect(row?.["through_server_seq"]).toBe(1);
    expect(row?.["revision"]).toBe(2);
  });

  it("refuses a patch that would set a future through_server_seq", async () => {
    const before = await snapshot();
    await expectApiError(
      () => applyOperationRequest(makeRequest(patchBody({ metadata_set: { through_server_seq: 50 } })), db),
      "VALIDATION_FAILED",
      "future through_server_seq on patch",
    );
    expect(await snapshot()).toBe(before);
  });

  it("refuses to clear the schema version and leaves everything untouched", async () => {
    const before = await snapshot();
    await expectApiError(
      () => applyOperationRequest(makeRequest(patchBody({ metadata_clear: ["checkpoint_schema_version"] })), db),
      "VALIDATION_FAILED",
      "clearing a NOT NULL schema version",
    );
    // The refusal happens before any statement runs, so the row, its revision,
    // both ledgers, the sequence and the guard table are all as they were.
    expect(await snapshot()).toBe(before);
    expect((await checkpointRow())?.["revision"]).toBe(0);
    expect((await checkpointRow())?.["checkpoint_schema_version"]).toBe(1);
    expect(await countOf("operation_log")).toBe(1);
    expect(await countOf("change_log")).toBe(1);
    expect(await nextSeq()).toBe(2);
    expect(await countOf("transaction_guard")).toBe(0);
  });

  it("still accepts a new schema version", async () => {
    await applyOperationRequest(
      makeRequest(patchBody({ metadata_set: { checkpoint_schema_version: 2 } })),
      db,
    );
    expect((await checkpointRow())?.["checkpoint_schema_version"]).toBe(2);
  });

  it("refuses a stale base_revision", async () => {
    const before = await snapshot();
    await expectApiError(
      () => applyOperationRequest(makeRequest(patchBody({ base_revision: 7 })), db),
      "REVISION_CONFLICT",
      "stale base_revision",
    );
    expect(await snapshot()).toBe(before);
  });

  it("reports a missing checkpoint as ENTITY_NOT_FOUND", async () => {
    await db.prepare("DELETE FROM checkpoint").run();
    await expectApiError(
      () => applyOperationRequest(makeRequest(patchBody()), db),
      "ENTITY_NOT_FOUND",
      "missing checkpoint",
    );
  });

  it("replays a byte-identical retry and rejects different bytes", async () => {
    const payload = patchBody({ set: { summary_text: envelope(6) } });
    const first = await applyOperationRequest(makeRequest(payload), db);
    const before = await snapshot();
    const second = await applyOperationRequest(makeRequest(payload), db);
    expect(second.status).toBe("replayed");
    expect(second.server_seq).toBe(first.server_seq);
    expect(await snapshot()).toBe(before);

    await expectApiError(
      () => applyOperationRequest(makeRequest(patchBody({ set: { summary_text: envelope(7) } })), db),
      "OPERATION_REPLAY_MISMATCH",
      "fingerprint mismatch",
    );
  });

  it("lets only one of two patches share a base revision", async () => {
    const outcomes = await Promise.allSettled([
      applyOperationRequest(makeRequest(patchBody({ set: { summary_text: envelope(8) } })), db),
      applyOperationRequest(
        makeRequest(patchBody({ operation_id: OPERATION_3, set: { summary_text: envelope(9) } })),
        db,
      ),
    ]);
    expect(outcomes.filter((o) => o.status === "fulfilled").length).toBe(1);
    const rejected = outcomes.find((o) => o.status === "rejected") as PromiseRejectedResult;
    expect((rejected.reason as { code?: string }).code).toBe("REVISION_CONFLICT");
    expect(await nextSeq()).toBe(3);
    expect(await countOf("change_log")).toBe(2);
    expect(await countOf("transaction_guard")).toBe(0);
  });
});

describe("checkpoint — boundaries", () => {
  it("applies a concurrent identical create exactly once", async () => {
    const payload = body({ set: { segments: envelope(10) } });
    const results = await Promise.all([
      applyOperationRequest(makeRequest(payload), db),
      applyOperationRequest(makeRequest(payload), db),
    ]);
    expect(results.map((r) => r.status).sort()).toEqual(["applied", "replayed"]);
    expect(results[0].server_seq).toBe(results[1].server_seq);
    expect(await countOf("checkpoint")).toBe(1);
    expect(await countOf("change_log")).toBe(1);
    expect(await nextSeq()).toBe(2);
    expect(await countOf("transaction_guard")).toBe(0);
  });

  it("refuses a named worldline outside PHONE_SPACE", async () => {
    await expectApiError(
      () =>
        applyOperationRequest(
          makeRequest(
            body({ target: { space_id: MAC, room_id: ROOM, worldline_id: WORLDLINE, checkpoint_id: CHECKPOINT } }),
          ),
          db,
        ),
      "VALIDATION_FAILED",
      "named worldline in MAC_SPACE",
    );
  });

  it("refuses a device writing another space's checkpoint", async () => {
    const before = await snapshot();
    await expectApiError(
      () =>
        applyOperationRequest(
          makeRequest(
            body({
              device_id: DEVICE_PHONE,
              target: { space_id: MAC, room_id: ROOM, worldline_id: null, checkpoint_id: CHECKPOINT },
              metadata_set: createMetadata({ created_by_device_id: DEVICE_PHONE }),
            }),
            TOKEN_PHONE,
          ),
          db,
        ),
      "AUTH_INVALID",
      "cross-space checkpoint",
    );
    expect(await snapshot()).toBe(before);
  });

  it("refuses an extension path", async () => {
    await expectApiError(
      () => applyOperationRequest(makeRequest(body({ set: { "extensions.kakao.checkpoint.x": envelope(11) } })), db),
      "VALIDATION_FAILED",
      "checkpoint has no extension table",
    );
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

  it("keeps the rules in the validator", () => {
    expect(getOperationSpec("create_checkpoint").entityType).toBe("checkpoint");
    expect(getEntityShape("checkpoint").worldlineRule).toBe("nullable");
    expect(getEntityShape("checkpoint").allowsExtensions).toBe(false);
  });
});
