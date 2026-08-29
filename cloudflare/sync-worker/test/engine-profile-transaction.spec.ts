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
const PROFILE = "C0000000-0000-4000-8000-000000000E01";
const OTHER_PROFILE = "C0000000-0000-4000-8000-000000000E02";
const OPERATION = "90000000-0000-4000-8000-000000000E10";
const OPERATION_2 = "90000000-0000-4000-8000-000000000E11";
const TIMESTAMP = "2026-08-28T00:00:00Z";
const MAC = "MAC_SPACE";
const PHONE = "PHONE_SPACE";
const EXHAUSTED_SENTINEL = 9007199254740992;

const ENCRYPTED_FIELDS = [
  "mode",
  "model_capability",
  "prompt_profile_id",
  "prompt_profile_version",
  "relationship_policy",
  "compaction_profile_id",
  "compaction_contract_fingerprint",
  "cache_policy",
  "repetition_policy",
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
    op: "create_engine_profile",
    entity_type: "engine_profile",
    target: { space_id: MAC, engine_profile_id: PROFILE, profile_revision: 3 },
    metadata_set: {},
    metadata_clear: [],
    set: {},
    clear: [],
    created_at: TIMESTAMP,
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
  for (const table of ["engine_profile", "account", "operation_log", "change_log", "transaction_guard"]) {
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

async function profileRow(revision = 3): Promise<Record<string, unknown> | null> {
  return await db
    .prepare(
      `SELECT * FROM engine_profile
        WHERE account_id = ? AND space_id = ? AND engine_profile_id = ? AND profile_revision = ?`,
    )
    .bind(ACCOUNT, MAC, PROFILE, revision)
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
    "engine_profile",
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
});

describe("create_engine_profile", () => {
  it("creates a sparse profile with only the fields it was given", async () => {
    const result = await applyOperationRequest(
      makeRequest(body({ set: { mode: envelope(1) } })),
      db,
    );
    expect(result.status).toBe("applied");
    expect(result.server_seq).toBe(1);
    // The ledger revision of an immutable row is its identity revision.
    expect(result.revision).toBe(3);

    const row = await profileRow();
    expect(row?.["mode_enc"]).toBe(envelope(1));
    expect(row?.["model_capability_enc"]).toBeNull();
    expect(row?.["compaction_compat_tag"]).toBeNull();
    expect(row?.["server_seq"]).toBe(1);
    expect(await nextSeq()).toBe(2);
    expect(await countOf("transaction_guard")).toBe(0);
  });

  it("creates a full profile across every encrypted field", async () => {
    const set: Record<string, string> = {};
    ENCRYPTED_FIELDS.forEach((field, index) => {
      set[field] = envelope(10 + index);
    });
    await applyOperationRequest(makeRequest(body({ set })), db);
    const row = await profileRow();
    ENCRYPTED_FIELDS.forEach((field, index) => {
      expect(row?.[`${field}_enc`]).toBe(envelope(10 + index));
    });
  });

  it("stores the plaintext compatibility tag", async () => {
    await applyOperationRequest(
      makeRequest(body({ metadata_set: { compaction_compat_tag: "tag-abc" } })),
      db,
    );
    const row = await profileRow();
    expect(row?.["compaction_compat_tag"]).toBe("tag-abc");
  });

  it("records the identity revision in both ledgers", async () => {
    await applyOperationRequest(makeRequest(body()), db);
    const log = await db.prepare("SELECT * FROM operation_log").first<Record<string, unknown>>();
    expect(log?.["entity_type"]).toBe("engine_profile");
    expect(log?.["result_revision"]).toBe(3);

    const change = await db.prepare("SELECT * FROM change_log").first<Record<string, unknown>>();
    expect(change?.["entity_type"]).toBe("engine_profile");
    expect(change?.["revision"]).toBe(3);
    expect(change?.["space_id"]).toBe(MAC);
    expect(change?.["engine_profile_id"]).toBe(PROFILE);
    expect(change?.["profile_revision"]).toBe(3);
    // Every other identity axis must be null for this entity_type.
    expect(change?.["room_id"]).toBeNull();
    expect(change?.["worldline_key"]).toBeNull();
    expect(change?.["persona_snapshot_id"]).toBeNull();
    expect(change?.["checkpoint_id"]).toBeNull();
  });

  it("keeps each profile_revision as a separate immutable row", async () => {
    await applyOperationRequest(makeRequest(body({ set: { mode: envelope(1) } })), db);
    await applyOperationRequest(
      makeRequest(
        body({
          operation_id: OPERATION_2,
          target: { space_id: MAC, engine_profile_id: PROFILE, profile_revision: 4 },
          set: { mode: envelope(2) },
        }),
      ),
      db,
    );
    expect(await countOf("engine_profile")).toBe(2);
    expect((await profileRow(3))?.["mode_enc"]).toBe(envelope(1));
    expect((await profileRow(4))?.["mode_enc"]).toBe(envelope(2));
  });

  it("keeps a different engine_profile_id apart", async () => {
    await applyOperationRequest(makeRequest(body()), db);
    const result = await applyOperationRequest(
      makeRequest(
        body({
          operation_id: OPERATION_2,
          target: { space_id: MAC, engine_profile_id: OTHER_PROFILE, profile_revision: 3 },
        }),
      ),
      db,
    );
    expect(result.status).toBe("applied");
    expect(await countOf("engine_profile")).toBe(2);
  });
});

describe("engine_profile — collisions and replay", () => {
  it("never updates an existing immutable row", async () => {
    await applyOperationRequest(makeRequest(body({ set: { mode: envelope(1) } })), db);
    let caught: unknown;
    try {
      await applyOperationRequest(
        makeRequest(body({ operation_id: OPERATION_2, set: { mode: envelope(2) } })),
        db,
      );
    } catch (error) {
      caught = error;
    }
    expect((caught as { code?: string }).code).toBe("REVISION_CONFLICT");
    expect((caught as { detail?: unknown }).detail).toEqual({ current_revision: 3 });
    // The first write survives untouched: no upsert path exists for this table.
    const row = await profileRow();
    expect(row?.["mode_enc"]).toBe(envelope(1));
    expect(row?.["server_seq"]).toBe(1);
    expect(await countOf("engine_profile")).toBe(1);
    expect(await nextSeq()).toBe(2);
  });

  it("replays a byte-identical retry", async () => {
    const payload = body({ set: { mode: envelope(3) } });
    const first = await applyOperationRequest(makeRequest(payload), db);
    const before = await snapshot();
    const second = await applyOperationRequest(makeRequest(payload), db);
    expect(second.status).toBe("replayed");
    expect(second.server_seq).toBe(first.server_seq);
    expect(second.revision).toBe(3);
    expect(await snapshot()).toBe(before);
  });

  it("rejects the same operation_id with different bytes", async () => {
    await applyOperationRequest(makeRequest(body({ set: { mode: envelope(4) } })), db);
    const before = await snapshot();
    await expectApiError(
      () => applyOperationRequest(makeRequest(body({ set: { mode: envelope(5) } })), db),
      "OPERATION_REPLAY_MISMATCH",
      "fingerprint mismatch",
    );
    expect(await snapshot()).toBe(before);
  });

  it("applies a concurrent identical create exactly once", async () => {
    const payload = body({ set: { mode: envelope(6) } });
    const results = await Promise.all([
      applyOperationRequest(makeRequest(payload), db),
      applyOperationRequest(makeRequest(payload), db),
    ]);
    expect(results.map((r) => r.status).sort()).toEqual(["applied", "replayed"]);
    expect(results[0].server_seq).toBe(results[1].server_seq);
    expect(await countOf("engine_profile")).toBe(1);
    expect(await countOf("change_log")).toBe(1);
    expect(await nextSeq()).toBe(2);
    expect(await countOf("transaction_guard")).toBe(0);
  });

  it("lets only one of two operations create the same identity", async () => {
    const envelopes: Record<string, string> = {
      [OPERATION]: envelope(7),
      [OPERATION_2]: envelope(8),
    };
    const outcomes = await Promise.allSettled([
      applyOperationRequest(makeRequest(body({ set: { mode: envelopes[OPERATION] } })), db),
      applyOperationRequest(
        makeRequest(body({ operation_id: OPERATION_2, set: { mode: envelopes[OPERATION_2] } })),
        db,
      ),
    ]);
    expect(outcomes.filter((o) => o.status === "fulfilled").length).toBe(1);
    const rejected = outcomes.find((o) => o.status === "rejected") as PromiseRejectedResult;
    expect((rejected.reason as { code?: string }).code).toBe("REVISION_CONFLICT");

    expect(await countOf("engine_profile")).toBe(1);
    expect(await countOf("operation_log")).toBe(1);
    expect(await nextSeq()).toBe(2);
    const log = await db.prepare("SELECT operation_id FROM operation_log").first<{ operation_id: string }>();
    const winner = log?.operation_id as string;
    const loser = winner === OPERATION ? OPERATION_2 : OPERATION;
    const row = await profileRow();
    expect(row?.["mode_enc"]).toBe(envelopes[winner]);
    expect(row?.["mode_enc"]).not.toBe(envelopes[loser]);
  });
});

describe("engine_profile — boundaries", () => {
  it("refuses a device writing another space's profile", async () => {
    const before = await snapshot();
    await expectApiError(
      () => applyOperationRequest(makeRequest(body({ device_id: DEVICE_PHONE }), TOKEN_PHONE), db),
      "AUTH_INVALID",
      "cross-space engine_profile",
    );
    expect(await snapshot()).toBe(before);
  });

  it("refuses an extension path", async () => {
    await expectApiError(
      () => applyOperationRequest(makeRequest(body({ set: { "extensions.kakao.engine.x": envelope(9) } })), db),
      "VALIDATION_FAILED",
      "engine_profile has no extension table",
    );
  });

  it("refuses a field with no canonical column", async () => {
    await expectApiError(
      () => applyOperationRequest(makeRequest(body({ set: { title: envelope(9) } })), db),
      "VALIDATION_FAILED",
      "room field on engine_profile",
    );
  });

  it("fails closed when the account sequence is exhausted", async () => {
    await db
      .prepare("UPDATE account SET next_server_seq = ? WHERE account_id = ?")
      .bind(EXHAUSTED_SENTINEL, ACCOUNT)
      .run();
    const before = await snapshot();
    await expectApiError(
      () => applyOperationRequest(makeRequest(body({ set: { mode: envelope(9) } })), db),
      "STORAGE_UNAVAILABLE",
      "sequence sentinel",
    );
    expect(await snapshot()).toBe(before);
  });

  it("keeps the rules in the validator", () => {
    expect(getOperationSpec("create_engine_profile").kind).toBe("create");
    expect(getEntityShape("engine_profile").worldlineRule).toBe("absent");
    expect(getEntityShape("engine_profile").allowsExtensions).toBe(false);
  });
});
