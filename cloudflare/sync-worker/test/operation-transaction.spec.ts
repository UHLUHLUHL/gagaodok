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

// Every identifier here is a synthetic fixture value, never a real account,
// device, room or token. Nothing in this file prints a whole envelope or a
// whole token.
const ACCOUNT = "A0000000-0000-4000-8000-00000000000A";
const DEVICE = "B0000000-0000-4000-8000-000000000001";
const DEVICE_OTHER = "B0000000-0000-4000-8000-000000000002";
const DEVICE_REVOKED = "B0000000-0000-4000-8000-000000000003";
const ROOM = "10000000-0000-4000-8000-0000000000AF";
const MISSING_ROOM = "10000000-0000-4000-8000-0000000000B0";
const MAC_ROOM = "10000000-0000-4000-8000-0000000000C1";
const ENGINE_PROFILE = "C0000000-0000-4000-8000-0000000000E1";
const PERSONA_SNAPSHOT = "50000000-0000-4000-8000-0000000000EF";
const OPERATION = "90000000-0000-4000-8000-000000000003";
const OPERATION_2 = "90000000-0000-4000-8000-000000000004";
const TIMESTAMP = "2026-08-28T00:00:00Z";
const SPACE = "PHONE_SPACE";
const OTHER_SPACE = "MAC_SPACE";
const EXHAUSTED_SENTINEL = 9007199254740992;

function syntheticTokenBytes(seed: number): Uint8Array {
  const bytes = new Uint8Array(32);
  for (let index = 0; index < bytes.length; index += 1) {
    bytes[index] = (seed + index) & 0xff;
  }
  return bytes;
}

function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

function base64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes as BufferSource);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

const TOKEN = `gdt1_${base64Url(syntheticTokenBytes(1))}`;
const TOKEN_REVOKED = `gdt1_${base64Url(syntheticTokenBytes(9))}`;
const TOKEN_OTHER = `gdt1_${base64Url(syntheticTokenBytes(17))}`;

/** A structurally valid field envelope: version 1, alg 1, then 30 more bytes. */
function envelope(seed: number): string {
  const bytes = new Uint8Array(34);
  bytes[0] = 1;
  bytes[1] = 1;
  for (let index = 2; index < bytes.length; index += 1) {
    bytes[index] = (seed + index) & 0xff;
  }
  return base64(bytes);
}

interface BodyOverrides {
  [key: string]: unknown;
}

function patchRoomBody(overrides: BodyOverrides = {}): Record<string, unknown> {
  return {
    protocol_version: 1,
    operation_id: OPERATION,
    device_id: DEVICE,
    op: "patch_room",
    entity_type: "room",
    target: { space_id: SPACE, room_id: ROOM, worldline_id: null },
    base_revision: 4,
    metadata_set: {},
    metadata_clear: [],
    set: {},
    clear: [],
    created_at: TIMESTAMP,
    ...overrides,
  };
}

function makeRequest(
  body: unknown,
  options: { token?: string; contentLength?: number; rawBody?: string } = {},
): Request {
  const raw = options.rawBody ?? JSON.stringify(body);
  const headers = new Headers({ Authorization: `Device ${options.token ?? TOKEN}` });
  if (options.contentLength !== undefined) {
    headers.set("Content-Length", String(options.contentLength));
  }
  return new Request("https://example.test/v1/sync/operations", {
    method: "POST",
    headers,
    body: raw,
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

async function insertFixtures(): Promise<void> {
  await db.prepare("INSERT INTO account (account_id, created_at) VALUES (?, ?)").bind(ACCOUNT, TIMESTAMP).run();
  const devices: ReadonlyArray<[string, string, string | null]> = [
    [DEVICE, await sha256Hex(syntheticTokenBytes(1)), null],
    [DEVICE_REVOKED, await sha256Hex(syntheticTokenBytes(9)), "2026-08-28T12:00:00Z"],
    [DEVICE_OTHER, await sha256Hex(syntheticTokenBytes(17)), null],
  ];
  for (const [deviceId, tokenHash, revokedAt] of devices) {
    await db
      .prepare(
        `INSERT INTO device
           (account_id, device_id, space_id, platform, display_name_enc,
            linked_at, revoked_at, key_generation, token_hash)
         VALUES (?, ?, ?, 'android_phone', NULL, ?, ?, 1, ?)`,
      )
      .bind(ACCOUNT, deviceId, SPACE, TIMESTAMP, revokedAt, tokenHash)
      .run();
  }
  await db
    .prepare(
      `INSERT INTO room
         (account_id, space_id, room_id, title_enc, status_message_enc,
          music_title_enc, music_artist_enc, revision, server_seq, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, NULL, NULL, 4, NULL, ?, ?)`,
    )
    .bind(ACCOUNT, SPACE, ROOM, envelope(200), envelope(210), TIMESTAMP, TIMESTAMP)
    .run();
  await db
    .prepare(
      `INSERT INTO room
         (account_id, space_id, room_id, title_enc, status_message_enc,
          music_title_enc, music_artist_enc, revision, server_seq, created_at, updated_at)
       VALUES (?, ?, ?, ?, NULL, NULL, NULL, 4, NULL, ?, ?)`,
    )
    .bind(ACCOUNT, OTHER_SPACE, MAC_ROOM, envelope(220), TIMESTAMP, TIMESTAMP)
    .run();
  await db
    .prepare(
      `INSERT INTO engine_profile (account_id, space_id, engine_profile_id, profile_revision)
       VALUES (?, ?, ?, 1)`,
    )
    .bind(ACCOUNT, SPACE, ENGINE_PROFILE)
    .run();
  await db
    .prepare(
      `INSERT INTO persona_snapshot
         (account_id, space_id, persona_snapshot_id, snapshot_revision, owner_space_id,
          created_by_device_id, created_at, persona_schema_version)
       VALUES (?, ?, ?, 1, ?, ?, ?, 1)`,
    )
    .bind(ACCOUNT, SPACE, PERSONA_SNAPSHOT, SPACE, DEVICE, TIMESTAMP)
    .run();
}

/** The whole mutable surface of this slice, for before/after comparison. */
async function snapshot(): Promise<string> {
  const rooms = await db.prepare("SELECT * FROM room ORDER BY space_id, room_id").all();
  const extensions = await db
    .prepare("SELECT * FROM room_extension_field ORDER BY extension_key")
    .all();
  const ref = await db.prepare("SELECT * FROM room_ai_state_ref").all();
  const account = await db.prepare("SELECT next_server_seq FROM account WHERE account_id = ?").bind(ACCOUNT).first();
  const operations = await db.prepare("SELECT * FROM operation_log ORDER BY operation_id").all();
  const changes = await db.prepare("SELECT * FROM change_log ORDER BY server_seq").all();
  const guards = await db.prepare("SELECT * FROM transaction_guard").all();
  return JSON.stringify({
    rooms: rooms.results,
    extensions: extensions.results,
    ref: ref.results,
    account,
    operations: operations.results,
    changes: changes.results,
    guards: guards.results,
  });
}

async function guardCount(): Promise<number> {
  const row = await db.prepare("SELECT COUNT(*) AS n FROM transaction_guard").first<{ n: number }>();
  return row?.n ?? 0;
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
    "persona_snapshot",
    "engine_profile",
    "device",
    "account",
  ]) {
    await db.prepare(`DELETE FROM ${table}`).run();
  }
  await insertFixtures();
});

describe("applyOperationRequest — a new patch_room", () => {
  it("applies the room body, one revision and one sequence", async () => {
    const result = await applyOperationRequest(
      makeRequest(patchRoomBody({ set: { status_message: envelope(1) }, clear: ["title"] })),
      db,
    );

    expect(result.status).toBe("applied");
    expect(result.operation_id).toBe(OPERATION);
    expect(result.revision).toBe(5);
    expect(result.server_seq).toBe(1);

    const room = await db
      .prepare("SELECT * FROM room WHERE account_id = ? AND space_id = ? AND room_id = ?")
      .bind(ACCOUNT, SPACE, ROOM)
      .first<Record<string, unknown>>();
    expect(room?.["status_message_enc"]).toBe(envelope(1));
    expect(room?.["title_enc"]).toBeNull();
    expect(room?.["revision"]).toBe(5);
    expect(room?.["server_seq"]).toBe(1);
    expect(room?.["updated_at"]).toBe(TIMESTAMP);

    const account = await db
      .prepare("SELECT next_server_seq FROM account WHERE account_id = ?")
      .bind(ACCOUNT)
      .first<{ next_server_seq: number }>();
    expect(account?.next_server_seq).toBe(2);

    const log = await db.prepare("SELECT * FROM operation_log").first<Record<string, unknown>>();
    expect(log?.["entity_type"]).toBe("room");
    expect(log?.["change_kind"]).toBe("upsert");
    expect(log?.["result_revision"]).toBe(5);
    expect(log?.["server_seq"]).toBe(1);

    const change = await db.prepare("SELECT * FROM change_log").first<Record<string, unknown>>();
    expect(change?.["entity_type"]).toBe("room");
    expect(change?.["revision"]).toBe(5);
    expect(change?.["server_seq"]).toBe(1);
    expect(change?.["space_id"]).toBe(SPACE);
    expect(change?.["room_id"]).toBe(ROOM);
    expect(change?.["worldline_key"]).toBeNull();
    expect(change?.["turn_id"]).toBeNull();
    expect(change?.["attachment_id"]).toBeNull();

    expect(await guardCount()).toBe(0);
  });

  it("writes and clears extension envelopes in the same transaction", async () => {
    await applyOperationRequest(
      makeRequest(
        patchRoomBody({ set: { "extensions.kakao.room.mood": envelope(2) } }),
      ),
      db,
    );
    const row = await db
      .prepare("SELECT * FROM room_extension_field")
      .first<Record<string, unknown>>();
    // The `extensions.` wire prefix is not part of the stored key.
    expect(row?.["extension_key"]).toBe("kakao.room.mood");
    expect(row?.["envelope_enc"]).toBe(envelope(2));

    await applyOperationRequest(
      makeRequest(
        patchRoomBody({
          operation_id: OPERATION_2,
          base_revision: 5,
          clear: ["extensions.kakao.room.mood"],
        }),
      ),
      db,
    );
    const after = await db.prepare("SELECT COUNT(*) AS n FROM room_extension_field").first<{ n: number }>();
    expect(after?.n).toBe(0);
    // Extensions never mint their own revision or sequence.
    const changes = await db.prepare("SELECT COUNT(*) AS n FROM change_log").first<{ n: number }>();
    expect(changes?.n).toBe(2);
  });

  it("sets and clears the AI reference pairs without touching the other pair", async () => {
    await applyOperationRequest(
      makeRequest(
        patchRoomBody({
          metadata_set: { engine_profile_id: ENGINE_PROFILE, engine_profile_revision: 1 },
        }),
      ),
      db,
    );
    await applyOperationRequest(
      makeRequest(
        patchRoomBody({
          operation_id: OPERATION_2,
          base_revision: 5,
          metadata_set: { persona_snapshot_id: PERSONA_SNAPSHOT, persona_snapshot_revision: 1 },
        }),
      ),
      db,
    );
    const both = await db.prepare("SELECT * FROM room_ai_state_ref").first<Record<string, unknown>>();
    expect(both?.["engine_profile_id"]).toBe(ENGINE_PROFILE);
    expect(both?.["persona_snapshot_id"]).toBe(PERSONA_SNAPSHOT);

    await applyOperationRequest(
      makeRequest(
        patchRoomBody({
          operation_id: "90000000-0000-4000-8000-000000000005",
          base_revision: 6,
          metadata_clear: ["engine_profile_id", "engine_profile_revision"],
        }),
      ),
      db,
    );
    const kept = await db.prepare("SELECT * FROM room_ai_state_ref").first<Record<string, unknown>>();
    expect(kept?.["engine_profile_id"]).toBeNull();
    expect(kept?.["persona_snapshot_id"]).toBe(PERSONA_SNAPSHOT);

    await applyOperationRequest(
      makeRequest(
        patchRoomBody({
          operation_id: "90000000-0000-4000-8000-000000000006",
          base_revision: 7,
          metadata_clear: ["persona_snapshot_id", "persona_snapshot_revision"],
        }),
      ),
      db,
    );
    const gone = await db.prepare("SELECT COUNT(*) AS n FROM room_ai_state_ref").first<{ n: number }>();
    expect(gone?.n).toBe(0);
  });

  it("treats a clear against a missing reference row as a no-op", async () => {
    const result = await applyOperationRequest(
      makeRequest(
        patchRoomBody({ metadata_clear: ["engine_profile_id", "engine_profile_revision"] }),
      ),
      db,
    );
    expect(result.status).toBe("applied");
    const rows = await db.prepare("SELECT COUNT(*) AS n FROM room_ai_state_ref").first<{ n: number }>();
    expect(rows?.n).toBe(0);
  });

  it("consumes exactly one sequence even when body, extension and reference all change", async () => {
    await applyOperationRequest(
      makeRequest(
        patchRoomBody({
          set: { title: envelope(3), "extensions.kakao.room.mood": envelope(4) },
          metadata_set: { engine_profile_id: ENGINE_PROFILE, engine_profile_revision: 1 },
        }),
      ),
      db,
    );
    const account = await db
      .prepare("SELECT next_server_seq FROM account WHERE account_id = ?")
      .bind(ACCOUNT)
      .first<{ next_server_seq: number }>();
    expect(account?.next_server_seq).toBe(2);
    const changes = await db.prepare("SELECT COUNT(*) AS n FROM change_log").first<{ n: number }>();
    expect(changes?.n).toBe(1);
  });
});

describe("applyOperationRequest — replay", () => {
  it("returns the first result for a byte-identical retry", async () => {
    const body = patchRoomBody({ set: { title: envelope(5) } });
    const first = await applyOperationRequest(makeRequest(body), db);
    const before = await snapshot();
    const second = await applyOperationRequest(makeRequest(body), db);

    expect(second.status).toBe("replayed");
    expect(second.server_seq).toBe(first.server_seq);
    expect(second.revision).toBe(first.revision);
    expect(await snapshot()).toBe(before);
  });

  it("rejects the same operation_id with different bytes", async () => {
    await applyOperationRequest(makeRequest(patchRoomBody({ set: { title: envelope(6) } })), db);
    const before = await snapshot();
    await expectApiError(
      () => applyOperationRequest(makeRequest(patchRoomBody({ set: { title: envelope(7) } })), db),
      "OPERATION_REPLAY_MISMATCH",
      "fingerprint mismatch",
    );
    expect(await snapshot()).toBe(before);
  });

  it("applies a concurrent identical request exactly once", async () => {
    const body = patchRoomBody({ set: { title: envelope(8) } });
    const results = await Promise.all([
      applyOperationRequest(makeRequest(body), db),
      applyOperationRequest(makeRequest(body), db),
    ]);
    const statuses = results.map((result) => result.status).sort();
    expect(statuses).toEqual(["applied", "replayed"]);
    expect(results[0].server_seq).toBe(results[1].server_seq);

    const room = await db
      .prepare("SELECT revision FROM room WHERE account_id = ? AND space_id = ? AND room_id = ?")
      .bind(ACCOUNT, SPACE, ROOM)
      .first<{ revision: number }>();
    expect(room?.revision).toBe(5);
    const changes = await db.prepare("SELECT COUNT(*) AS n FROM change_log").first<{ n: number }>();
    expect(changes?.n).toBe(1);
    expect(await guardCount()).toBe(0);
  });
});

describe("applyOperationRequest — refusals leave nothing behind", () => {
  it("rejects a base revision mismatch and changes nothing", async () => {
    const before = await snapshot();
    await expectApiError(
      () => applyOperationRequest(makeRequest(patchRoomBody({ base_revision: 3 })), db),
      "REVISION_CONFLICT",
      "stale base_revision",
    );
    expect(await snapshot()).toBe(before);
    expect(await guardCount()).toBe(0);
  });

  it("reports a missing room as ENTITY_NOT_FOUND", async () => {
    const before = await snapshot();
    await expectApiError(
      () =>
        applyOperationRequest(
          makeRequest(
            patchRoomBody({ target: { space_id: SPACE, room_id: MISSING_ROOM, worldline_id: null } }),
          ),
          db,
        ),
      "ENTITY_NOT_FOUND",
      "missing room",
    );
    expect(await snapshot()).toBe(before);
  });

  it("rolls back entirely when a referenced AI revision does not exist", async () => {
    const before = await snapshot();
    await expectApiError(
      () =>
        applyOperationRequest(
          makeRequest(
            patchRoomBody({
              set: { title: envelope(9) },
              metadata_set: { engine_profile_id: ENGINE_PROFILE, engine_profile_revision: 99 },
            }),
          ),
          db,
        ),
      "ENTITY_NOT_FOUND",
      "missing engine_profile revision",
    );
    expect(await snapshot()).toBe(before);
    expect(await guardCount()).toBe(0);
  });

  it("refuses a revoked device before touching storage", async () => {
    const before = await snapshot();
    await expectApiError(
      () =>
        applyOperationRequest(
          makeRequest(patchRoomBody({ device_id: DEVICE_REVOKED }), { token: TOKEN_REVOKED }),
          db,
        ),
      "DEVICE_REVOKED",
      "revoked device",
    );
    expect(await snapshot()).toBe(before);
  });

  it("refuses a body device_id that is not the authenticated device", async () => {
    const before = await snapshot();
    await expectApiError(
      () => applyOperationRequest(makeRequest(patchRoomBody(), { token: TOKEN_OTHER }), db),
      "AUTH_INVALID",
      "device_id mismatch",
    );
    expect(await snapshot()).toBe(before);
  });

  it("fails closed when the account sequence is exhausted", async () => {
    await db
      .prepare("UPDATE account SET next_server_seq = ? WHERE account_id = ?")
      .bind(EXHAUSTED_SENTINEL, ACCOUNT)
      .run();
    const before = await snapshot();
    await expectApiError(
      () => applyOperationRequest(makeRequest(patchRoomBody({ set: { title: envelope(10) } })), db),
      "STORAGE_UNAVAILABLE",
      "sequence sentinel",
    );
    expect(await snapshot()).toBe(before);
    expect(await guardCount()).toBe(0);
  });

  it("does not partially apply an operation with no transaction service", async () => {
    // create_attachment is the last runtime-enabled operation with no
    // transaction service; it is refused whole rather than half-written.
    const before = await snapshot();
    await expectApiError(
      () =>
        applyOperationRequest(
          makeRequest(
            patchRoomBody({
              op: "create_attachment",
              entity_type: "attachment",
              base_revision: undefined,
              target: {
                space_id: SPACE,
                attachment_id: "70000000-0000-4000-8000-0000000000FB",
              },
              set: {
                file_name: envelope(11),
                mime_type: envelope(12),
                wrapped_file_key: envelope(13),
              },
              metadata_set: {
                origin_space_id: SPACE,
                kind: "image",
                source_byte_size: 100,
                ciphertext_byte_size: 134,
                ciphertext_hash: "a".repeat(64),
                key_generation: 1,
                created_at: TIMESTAMP,
              },
            }),
          ),
          db,
        ),
      "VALIDATION_FAILED",
      "create_attachment has no service in this slice",
    );
    expect(await snapshot()).toBe(before);
  });

  it("rejects a non-null worldline_id on a room target", async () => {
    await expectApiError(
      () =>
        applyOperationRequest(
          makeRequest(
            patchRoomBody({
              target: {
                space_id: SPACE,
                room_id: ROOM,
                worldline_id: "20000000-0000-4000-8000-0000000000BF",
              },
            }),
          ),
          db,
        ),
      "VALIDATION_FAILED",
      "room worldline null-only",
    );
  });

  it("rejects a room field name that has no canonical column", async () => {
    await expectApiError(
      () => applyOperationRequest(makeRequest(patchRoomBody({ set: { avatar_ref: envelope(12) } })), db),
      "VALIDATION_FAILED",
      "unmapped room field",
    );
  });
});

describe("applyOperationRequest — registered space boundary", () => {
  // The token proves one device in one space. Same account is not authority:
  // a phone token that could patch the Mac's canonical rows would let one
  // compromised device rewrite every space (API draft §3, contract bdccd5c).
  function crossSpaceBody(overrides: BodyOverrides = {}): Record<string, unknown> {
    return patchRoomBody({
      // The body device_id is the authenticated phone device and the target
      // worldline is null, so target space is the only thing wrong here.
      target: { space_id: OTHER_SPACE, room_id: MAC_ROOM, worldline_id: null },
      ...overrides,
    });
  }

  it("refuses a phone token patching a MAC_SPACE room", async () => {
    const before = await snapshot();
    await expectApiError(
      () => applyOperationRequest(makeRequest(crossSpaceBody()), db),
      "AUTH_INVALID",
      "cross-space write",
    );
    expect(await snapshot()).toBe(before);
  });

  it("leaves every ledger, sequence and guard untouched", async () => {
    const before = await snapshot();
    await expectApiError(
      () =>
        applyOperationRequest(
          makeRequest(
            crossSpaceBody({
              set: { title: envelope(30), "extensions.kakao.room.mood": envelope(31) },
              metadata_set: { engine_profile_id: ENGINE_PROFILE, engine_profile_revision: 1 },
            }),
          ),
          db,
        ),
      "AUTH_INVALID",
      "cross-space write with a full payload",
    );
    expect(await snapshot()).toBe(before);
    expect(await guardCount()).toBe(0);
    const account = await db
      .prepare("SELECT next_server_seq FROM account WHERE account_id = ?")
      .bind(ACCOUNT)
      .first<{ next_server_seq: number }>();
    expect(account?.next_server_seq).toBe(1);
  });

  it("refuses before the replay lookup, so it is not a ledger oracle", async () => {
    // A pre-existing log row for this operation_id in the other space. If the
    // space check ran after the replay lookup, this would answer with that
    // row's sequence and revision — a read of another space's ledger.
    await db
      .prepare(
        `INSERT INTO operation_log
           (account_id, operation_id, request_fingerprint, entity_type, change_kind,
            result_revision, server_seq)
         VALUES (?, ?, ?, 'room', 'upsert', 41, 7)`,
      )
      .bind(ACCOUNT, OPERATION, "a".repeat(64))
      .run();

    let caught: unknown;
    try {
      await applyOperationRequest(makeRequest(crossSpaceBody()), db);
    } catch (error) {
      caught = error;
    }
    expect((caught as { code?: string }).code).toBe("AUTH_INVALID");
    const serialised = JSON.stringify({
      code: (caught as { code?: string }).code,
      detail: (caught as { detail?: unknown }).detail,
      message: (caught as Error).message,
    });
    for (const leak of ["41", "7", MAC_ROOM, OTHER_SPACE, ACCOUNT, "a".repeat(8)]) {
      expect(serialised).not.toContain(leak);
    }
  });

  it("still allows a patch inside the device's own space", async () => {
    const result = await applyOperationRequest(
      makeRequest(patchRoomBody({ set: { title: envelope(32) } })),
      db,
    );
    expect(result.status).toBe("applied");
  });
});

describe("applyOperationRequest — body boundary", () => {
  it("rejects an oversized Content-Length before reading the body", async () => {
    // The body never produces a byte and never ends. workerd pulls a stream
    // body once while constructing the Request, so a "was it pulled" flag
    // cannot tell us anything about the handler; a body that can never
    // complete can. If the handler awaited it, this would hang and the race
    // below would win.
    const body = new ReadableStream<Uint8Array>({
      pull() {
        return new Promise<void>(() => {});
      },
    });
    const request = new Request("https://example.test/v1/sync/operations", {
      method: "POST",
      headers: new Headers({
        Authorization: `Device ${TOKEN}`,
        "Content-Length": String(2_000_001),
      }),
      body,
      // @ts-expect-error duplex is required for a streaming request body
      duplex: "half",
    });

    const outcome = await Promise.race([
      applyOperationRequest(request, db).then(
        () => "resolved",
        (error: unknown) => (error as { code?: string }).code,
      ),
      new Promise<string>((resolve) => setTimeout(() => resolve("read the body"), 250)),
    ]);
    expect(outcome).toBe("REQUEST_TOO_LARGE");
  });

  it("rejects an actually oversized body", async () => {
    const padding = "x".repeat(2_000_001);
    await expectApiError(
      () => applyOperationRequest(makeRequest(null, { rawBody: `"${padding}"` }), db),
      "REQUEST_TOO_LARGE",
      "oversized body",
    );
  });

  it("rejects malformed JSON and malformed UTF-8 the same way", async () => {
    await expectApiError(
      () => applyOperationRequest(makeRequest(null, { rawBody: "{not json" }), db),
      "VALIDATION_FAILED",
      "malformed JSON",
    );
    const invalidUtf8 = new Uint8Array([0x7b, 0xff, 0x7d]);
    const request = new Request("https://example.test/v1/sync/operations", {
      method: "POST",
      headers: new Headers({ Authorization: `Device ${TOKEN}` }),
      body: invalidUtf8,
    });
    await expectApiError(() => applyOperationRequest(request, db), "VALIDATION_FAILED", "malformed UTF-8");
  });

  it("keeps token, body and envelope out of every error it raises", async () => {
    let caught: unknown;
    try {
      await applyOperationRequest(makeRequest(patchRoomBody({ base_revision: 3 })), db);
    } catch (error) {
      caught = error;
    }
    const serialised = JSON.stringify({
      code: (caught as { code?: string }).code,
      detail: (caught as { detail?: unknown }).detail,
      message: (caught as Error).message,
      stack: undefined,
    });
    for (const secret of [TOKEN, "gdt1_", envelope(200), ROOM, ACCOUNT, "UPDATE", "SELECT"]) {
      expect(serialised).not.toContain(secret);
    }
    // A conflict may carry the current revision, and nothing else.
    expect((caught as { detail?: Record<string, unknown> }).detail).toEqual({ current_revision: 4 });
  });
});

describe("applyOperationRequest — contract reuse", () => {
  it("reads the operation rules from the validator rather than restating them", () => {
    // The handler branches on getOperationSpec(...).entityType/kind, so these
    // are the exact values it consults; a change here is a handler change.
    expect(getOperationSpec("patch_room").entityType).toBe("room");
    expect(getOperationSpec("patch_room").kind).toBe("patch");
    expect(getEntityShape("room").worldlineRule).toBe("null-only");
    expect(getEntityShape("room").roomScoped).toBe(true);
  });
});
