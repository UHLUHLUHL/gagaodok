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
const PERSONA = "50000000-0000-4000-8000-000000000P01".replace("P", "F");
const OPERATION = "90000000-0000-4000-8000-000000000F10";
const OPERATION_2 = "90000000-0000-4000-8000-000000000F11";
const OPERATION_3 = "90000000-0000-4000-8000-000000000F12";
const TIMESTAMP = "2026-08-28T00:00:00Z";
const MAC = "MAC_SPACE";
const PHONE = "PHONE_SPACE";
const EXHAUSTED_SENTINEL = 9007199254740992;

const ENCRYPTED_FIELDS = [
  "description",
  "samples",
  "style_guide",
  "is_enabled",
  "content_fingerprint",
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

function metadata(extra: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    owner_space_id: MAC,
    created_by_device_id: DEVICE_MAC,
    created_at: TIMESTAMP,
    persona_schema_version: 1,
    ...extra,
  };
}

function body(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    protocol_version: 1,
    operation_id: OPERATION,
    device_id: DEVICE_MAC,
    op: "create_persona_snapshot",
    entity_type: "persona_snapshot",
    target: { space_id: MAC, persona_snapshot_id: PERSONA, snapshot_revision: 1 },
    base_revision: 0,
    metadata_set: metadata(),
    metadata_clear: [],
    set: {},
    clear: [],
    created_at: "2026-08-29T00:00:00Z",
    ...overrides,
  };
}

/** The follow-up create that advances the head from `base` to `base + 1`. */
function nextBody(base: number, overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return body({
    operation_id: OPERATION_2,
    target: { space_id: MAC, persona_snapshot_id: PERSONA, snapshot_revision: base + 1 },
    base_revision: base,
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

async function snapshot(): Promise<string> {
  const dump: Record<string, unknown> = {};
  for (const table of [
    "persona_snapshot",
    "persona_snapshot_head",
    "persona_snapshot_extension_field",
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

async function head(): Promise<number | null> {
  const row = await db
    .prepare(
      `SELECT current_snapshot_revision FROM persona_snapshot_head
        WHERE account_id = ? AND space_id = ? AND persona_snapshot_id = ?`,
    )
    .bind(ACCOUNT, MAC, PERSONA)
    .first<{ current_snapshot_revision: number }>();
  return row === null ? null : row.current_snapshot_revision;
}

async function snapshotRow(revision: number): Promise<Record<string, unknown> | null> {
  return await db
    .prepare(
      `SELECT * FROM persona_snapshot
        WHERE account_id = ? AND space_id = ? AND persona_snapshot_id = ? AND snapshot_revision = ?`,
    )
    .bind(ACCOUNT, MAC, PERSONA, revision)
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
    "persona_snapshot_head",
    "persona_snapshot_extension_field",
    "persona_snapshot",
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

describe("create_persona_snapshot — the head chain", () => {
  it("creates the first snapshot and its head at 0 -> 1", async () => {
    const result = await applyOperationRequest(
      makeRequest(body({ set: { description: envelope(1) } })),
      db,
    );
    expect(result.status).toBe("applied");
    // The ledger revision of an immutable row is its identity revision.
    expect(result.revision).toBe(1);
    expect(result.server_seq).toBe(1);

    const row = await snapshotRow(1);
    expect(row?.["description_enc"]).toBe(envelope(1));
    expect(row?.["owner_space_id"]).toBe(MAC);
    expect(row?.["created_by_device_id"]).toBe(DEVICE_MAC);
    // The row's timestamp is the metadata value, not the operation's own.
    expect(row?.["created_at"]).toBe(TIMESTAMP);
    expect(row?.["persona_schema_version"]).toBe(1);
    expect(row?.["server_seq"]).toBe(1);

    expect(await head()).toBe(1);
    expect(await nextSeq()).toBe(2);
    expect(await countOf("change_log")).toBe(1);
    expect(await countOf("transaction_guard")).toBe(0);
  });

  it("advances the chain 1 -> 2 and leaves the old revision immutable", async () => {
    await applyOperationRequest(makeRequest(body({ set: { description: envelope(1) } })), db);
    const result = await applyOperationRequest(
      makeRequest(nextBody(1, { set: { description: envelope(2) } })),
      db,
    );
    expect(result.revision).toBe(2);
    expect(await head()).toBe(2);
    expect((await snapshotRow(1))?.["description_enc"]).toBe(envelope(1));
    expect((await snapshotRow(2))?.["description_enc"]).toBe(envelope(2));
    expect(await countOf("persona_snapshot")).toBe(2);
    expect(await countOf("persona_snapshot_head")).toBe(1);
  });

  it("stores every encrypted field and the persona extensions in one transaction", async () => {
    const set: Record<string, string> = {};
    ENCRYPTED_FIELDS.forEach((field, index) => {
      set[field] = envelope(10 + index);
    });
    set["extensions.kakao.persona.suppressed"] = envelope(30);
    set["extensions.kakao.persona.evidence"] = envelope(31);

    await applyOperationRequest(makeRequest(body({ set })), db);

    const row = await snapshotRow(1);
    ENCRYPTED_FIELDS.forEach((field, index) => {
      expect(row?.[`${field}_enc`]).toBe(envelope(10 + index));
    });
    const extensions = await db
      .prepare("SELECT * FROM persona_snapshot_extension_field ORDER BY extension_key")
      .all();
    expect(
      extensions.results.map((r) => (r as Record<string, unknown>)["extension_key"]),
    ).toEqual(["kakao.persona.evidence", "kakao.persona.suppressed"]);
    expect((extensions.results[1] as Record<string, unknown>)["envelope_enc"]).toBe(envelope(30));
    expect((extensions.results[0] as Record<string, unknown>)["snapshot_revision"]).toBe(1);
    // Extensions ride the snapshot's own sequence and change event.
    expect(await nextSeq()).toBe(2);
    expect(await countOf("change_log")).toBe(1);
  });

  it("records the snapshot revision and identity in both ledgers", async () => {
    await applyOperationRequest(makeRequest(body()), db);
    const log = await db.prepare("SELECT * FROM operation_log").first<Record<string, unknown>>();
    expect(log?.["entity_type"]).toBe("persona_snapshot");
    expect(log?.["result_revision"]).toBe(1);

    const change = await db.prepare("SELECT * FROM change_log").first<Record<string, unknown>>();
    expect(change?.["entity_type"]).toBe("persona_snapshot");
    expect(change?.["revision"]).toBe(1);
    expect(change?.["space_id"]).toBe(MAC);
    expect(change?.["persona_snapshot_id"]).toBe(PERSONA);
    expect(change?.["snapshot_revision"]).toBe(1);
    expect(change?.["room_id"]).toBeNull();
    expect(change?.["worldline_key"]).toBeNull();
    expect(change?.["engine_profile_id"]).toBeNull();
  });

  it("refuses a target that is not base + 1", async () => {
    await expectApiError(
      () =>
        applyOperationRequest(
          makeRequest(
            body({ target: { space_id: MAC, persona_snapshot_id: PERSONA, snapshot_revision: 3 } }),
          ),
          db,
        ),
      "VALIDATION_FAILED",
      "target skips a revision",
    );
  });

  it("refuses provenance that does not match the request", async () => {
    const before = await snapshot();
    await expectApiError(
      () => applyOperationRequest(makeRequest(body({ metadata_set: metadata({ owner_space_id: PHONE }) })), db),
      "VALIDATION_FAILED",
      "owner_space_id mismatch",
    );
    await expectApiError(
      () =>
        applyOperationRequest(
          makeRequest(body({ metadata_set: metadata({ created_by_device_id: DEVICE_PHONE }) })),
          db,
        ),
      "VALIDATION_FAILED",
      "created_by_device_id mismatch",
    );
    expect(await snapshot()).toBe(before);
  });
});

describe("create_persona_snapshot — CAS and collisions", () => {
  beforeEach(async () => {
    await applyOperationRequest(makeRequest(body({ set: { description: envelope(1) } })), db);
  });

  it("refuses a stale head and changes nothing", async () => {
    const before = await snapshot();
    await expectApiError(
      () =>
        applyOperationRequest(
          makeRequest(
            body({
              operation_id: OPERATION_2,
              target: { space_id: MAC, persona_snapshot_id: PERSONA, snapshot_revision: 1 },
              base_revision: 0,
              set: { description: envelope(2) },
            }),
          ),
          db,
        ),
      "REVISION_CONFLICT",
      "stale head",
    );
    expect(await snapshot()).toBe(before);
  });

  it("reports the current head when the base is stale", async () => {
    await applyOperationRequest(makeRequest(nextBody(1)), db);
    let caught: unknown;
    try {
      await applyOperationRequest(
        makeRequest(
          body({
            operation_id: OPERATION_3,
            target: { space_id: MAC, persona_snapshot_id: PERSONA, snapshot_revision: 2 },
            base_revision: 1,
          }),
        ),
        db,
      );
    } catch (error) {
      caught = error;
    }
    expect((caught as { code?: string }).code).toBe("REVISION_CONFLICT");
    // The snapshot identity already exists, so the number is that identity's
    // own revision.
    expect((caught as { detail?: unknown }).detail).toEqual({ current_revision: 2 });
  });

  it("replays a byte-identical retry without touching the head", async () => {
    const payload = nextBody(1, { set: { description: envelope(3) } });
    const first = await applyOperationRequest(makeRequest(payload), db);
    const before = await snapshot();
    const second = await applyOperationRequest(makeRequest(payload), db);
    expect(second.status).toBe("replayed");
    expect(second.server_seq).toBe(first.server_seq);
    expect(second.revision).toBe(2);
    expect(await snapshot()).toBe(before);
  });

  it("rejects the same operation_id with different bytes", async () => {
    await applyOperationRequest(makeRequest(nextBody(1, { set: { description: envelope(4) } })), db);
    const before = await snapshot();
    await expectApiError(
      () => applyOperationRequest(makeRequest(nextBody(1, { set: { description: envelope(5) } })), db),
      "OPERATION_REPLAY_MISMATCH",
      "fingerprint mismatch",
    );
    expect(await snapshot()).toBe(before);
  });

  it("applies a concurrent identical create exactly once", async () => {
    const payload = nextBody(1, { set: { description: envelope(6) } });
    const results = await Promise.all([
      applyOperationRequest(makeRequest(payload), db),
      applyOperationRequest(makeRequest(payload), db),
    ]);
    expect(results.map((r) => r.status).sort()).toEqual(["applied", "replayed"]);
    expect(results[0].server_seq).toBe(results[1].server_seq);
    expect(await head()).toBe(2);
    expect(await countOf("persona_snapshot")).toBe(2);
    expect(await nextSeq()).toBe(3);
    expect(await countOf("transaction_guard")).toBe(0);
  });

  it("lets only one of two operations advance the same head", async () => {
    const envelopes: Record<string, string> = {
      [OPERATION_2]: envelope(7),
      [OPERATION_3]: envelope(8),
    };
    const outcomes = await Promise.allSettled([
      applyOperationRequest(
        makeRequest(nextBody(1, { set: { description: envelopes[OPERATION_2], "extensions.kakao.persona.a": envelope(20) } })),
        db,
      ),
      applyOperationRequest(
        makeRequest(
          nextBody(1, {
            operation_id: OPERATION_3,
            set: { description: envelopes[OPERATION_3], "extensions.kakao.persona.b": envelope(21) },
          }),
        ),
        db,
      ),
    ]);
    expect(outcomes.filter((o) => o.status === "fulfilled").length).toBe(1);
    const rejected = outcomes.find((o) => o.status === "rejected") as PromiseRejectedResult;
    expect((rejected.reason as { code?: string }).code).toBe("REVISION_CONFLICT");

    expect(await head()).toBe(2);
    expect(await countOf("persona_snapshot")).toBe(2);
    expect(await countOf("operation_log")).toBe(2);
    expect(await countOf("change_log")).toBe(2);
    expect(await nextSeq()).toBe(3);
    expect(await countOf("transaction_guard")).toBe(0);

    // The loser left neither a snapshot body nor an extension row.
    const log = await db
      .prepare("SELECT operation_id FROM operation_log WHERE result_revision = 2")
      .first<{ operation_id: string }>();
    const winner = log?.operation_id as string;
    const loser = winner === OPERATION_2 ? OPERATION_3 : OPERATION_2;
    expect((await snapshotRow(2))?.["description_enc"]).toBe(envelopes[winner]);
    expect((await snapshotRow(2))?.["description_enc"]).not.toBe(envelopes[loser]);
    const extensions = await db.prepare("SELECT extension_key FROM persona_snapshot_extension_field").all();
    expect(extensions.results.length).toBe(1);
    expect((extensions.results[0] as Record<string, unknown>)["extension_key"]).toBe(
      winner === OPERATION_2 ? "kakao.persona.a" : "kakao.persona.b",
    );
  });
});

describe("persona_snapshot — boundaries", () => {
  it("refuses a device writing another space's snapshot", async () => {
    const before = await snapshot();
    await expectApiError(
      () =>
        applyOperationRequest(
          makeRequest(
            body({
              device_id: DEVICE_PHONE,
              metadata_set: metadata({ created_by_device_id: DEVICE_PHONE }),
            }),
            TOKEN_PHONE,
          ),
          db,
        ),
      "AUTH_INVALID",
      "cross-space persona_snapshot",
    );
    expect(await snapshot()).toBe(before);
  });

  it("refuses a field with no canonical column", async () => {
    await expectApiError(
      () => applyOperationRequest(makeRequest(body({ set: { title: envelope(9) } })), db),
      "VALIDATION_FAILED",
      "room field on persona_snapshot",
    );
  });

  it("fails closed when the account sequence is exhausted", async () => {
    await db
      .prepare("UPDATE account SET next_server_seq = ? WHERE account_id = ?")
      .bind(EXHAUSTED_SENTINEL, ACCOUNT)
      .run();
    const before = await snapshot();
    await expectApiError(
      () => applyOperationRequest(makeRequest(body({ set: { description: envelope(9) } })), db),
      "STORAGE_UNAVAILABLE",
      "sequence sentinel",
    );
    expect(await snapshot()).toBe(before);
  });

  it("keeps the rules in the validator", () => {
    expect(getOperationSpec("create_persona_snapshot").kind).toBe("create");
    expect(getEntityShape("persona_snapshot").worldlineRule).toBe("absent");
    expect(getEntityShape("persona_snapshot").allowsExtensions).toBe(true);
  });
});
