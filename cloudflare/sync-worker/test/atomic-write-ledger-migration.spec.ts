import { applyD1Migrations, env } from "cloudflare:test";
import type { D1Migration } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";

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

// Synthetic identifiers only. No real account, device, room, conversation,
// attachment or token appears here, and no assertion prints a whole value.
const ACCOUNT_A = "A0000000-0000-4000-8000-00000000000A";
const ACCOUNT_B = "A0000000-0000-4000-8000-00000000000B";
const DEVICE_A = "B0000000-0000-4000-8000-00000000000A";
const ROOM_1 = "10000000-0000-4000-8000-000000000001";
const WORLDLINE_1 = "20000000-0000-4000-8000-000000000001";
const TURN_1 = "30000000-0000-4000-8000-000000000001";
const MESSAGE_1 = "40000000-0000-4000-8000-000000000001";
const PERSONA_1 = "50000000-0000-4000-8000-000000000001";
const CHECKPOINT_1 = "60000000-0000-4000-8000-000000000001";
const ATTACHMENT_1 = "70000000-0000-4000-8000-000000000001";
const ENGINE_1 = "C0000000-0000-4000-8000-0000000000E1";
const OPERATION_1 = "90000000-0000-4000-8000-000000000001";
const OPERATION_2 = "90000000-0000-4000-8000-000000000002";
// Carries hex letters on purpose: an all-digit UUID is unchanged by
// toLowerCase(), so it cannot test the canonical-uppercase rule.
const OPERATION_MIXED = "9000000A-0000-4000-8000-00000000000B";
const TIMESTAMP = "2026-08-28T00:00:00Z";
const FINGERPRINT = "a".repeat(64);
const ENVELOPE = "AQEAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==";

const LEDGER_MIGRATION = "0008_atomic_write_ledger.sql";
const MAX_SEQ = 9_007_199_254_740_991;
const EXHAUSTED_SENTINEL = 9_007_199_254_740_992;

const db = env.DB;

function migrationsUpTo(name: string): D1Migration[] {
  const index = env.TEST_MIGRATIONS.findIndex((migration) => migration.name === name);
  expect(index).toBeGreaterThanOrEqual(0);
  return env.TEST_MIGRATIONS.slice(0, index + 1);
}

// Stage contract: apply migrations up to and including this stage's own and no
// further (AGENTS.md stage-spec rule).
const STAGE_MIGRATIONS = () => migrationsUpTo(LEDGER_MIGRATION);

/** Assert a statement fails. `label` names the case without echoing a value. */
async function expectRejected(run: () => Promise<unknown>, label = ""): Promise<void> {
  let threw = false;
  try {
    await run();
  } catch {
    threw = true;
  }
  expect(threw, label).toBe(true);
}

async function insertAccount(accountId: string): Promise<void> {
  await db
    .prepare("INSERT INTO account (account_id, created_at) VALUES (?, ?)")
    .bind(accountId, TIMESTAMP)
    .run();
}

async function insertDevice(accountId: string, deviceId: string): Promise<void> {
  await db
    .prepare(
      `INSERT INTO device
         (account_id, device_id, space_id, platform, display_name_enc,
          linked_at, revoked_at, key_generation)
       VALUES (?, ?, 'PHONE_SPACE', 'android_phone', NULL, ?, NULL, 1)`,
    )
    .bind(accountId, deviceId, TIMESTAMP)
    .run();
}

async function insertRoom(accountId: string, roomId: string): Promise<void> {
  await db
    .prepare(
      `INSERT INTO room
         (account_id, space_id, room_id, title_enc, status_message_enc,
          music_title_enc, music_artist_enc, revision, server_seq,
          created_at, updated_at)
       VALUES (?, 'PHONE_SPACE', ?, ?, NULL, NULL, NULL, 4, NULL, ?, ?)`,
    )
    .bind(accountId, roomId, ENVELOPE, TIMESTAMP, TIMESTAMP)
    .run();
}

type OperationLogOverrides = Partial<{
  operationId: string;
  fingerprint: string;
  entityType: string;
  changeKind: string;
  resultRevision: number | null;
  serverSeq: unknown;
}>;

async function insertOperationLog(
  accountId: string,
  overrides: OperationLogOverrides = {},
): Promise<void> {
  const entityType = overrides.entityType ?? "room";
  await db
    .prepare(
      `INSERT INTO operation_log
         (account_id, operation_id, request_fingerprint, entity_type,
          change_kind, result_revision, server_seq)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
    )
    .bind(
      accountId,
      overrides.operationId ?? OPERATION_1,
      overrides.fingerprint ?? FINGERPRINT,
      entityType,
      overrides.changeKind ?? "upsert",
      overrides.resultRevision === undefined
        ? entityType === "attachment"
          ? null
          : 5
        : overrides.resultRevision,
      overrides.serverSeq ?? 1,
    )
    .run();
}

/** Exactly the identity axes each entity_type must carry (API draft §5.3.1). */
const IDENTITY_SHAPES: Record<string, Record<string, string | number>> = {
  room: { space_id: "PHONE_SPACE", room_id: ROOM_1 },
  group_state: { space_id: "PHONE_SPACE", room_id: ROOM_1 },
  worldline: { space_id: "PHONE_SPACE", room_id: ROOM_1, worldline_key: WORLDLINE_1 },
  turn: {
    space_id: "PHONE_SPACE",
    room_id: ROOM_1,
    worldline_key: "",
    turn_id: TURN_1,
  },
  bubble: {
    space_id: "PHONE_SPACE",
    room_id: ROOM_1,
    worldline_key: "",
    turn_id: TURN_1,
    message_id: MESSAGE_1,
  },
  persona_snapshot: {
    space_id: "PHONE_SPACE",
    persona_snapshot_id: PERSONA_1,
    snapshot_revision: 2,
  },
  engine_profile: {
    space_id: "MAC_SPACE",
    engine_profile_id: ENGINE_1,
    profile_revision: 3,
  },
  checkpoint: {
    space_id: "PHONE_SPACE",
    room_id: ROOM_1,
    worldline_key: "",
    checkpoint_id: CHECKPOINT_1,
  },
  attachment: { attachment_id: ATTACHMENT_1 },
};

const IDENTITY_COLUMNS = [
  "space_id",
  "room_id",
  "worldline_key",
  "turn_id",
  "message_id",
  "persona_snapshot_id",
  "snapshot_revision",
  "engine_profile_id",
  "profile_revision",
  "checkpoint_id",
  "attachment_id",
] as const;

async function insertChangeLog(
  accountId: string,
  entityType: string,
  identity: Record<string, string | number | null>,
  overrides: Partial<{ serverSeq: unknown; changeKind: string; revision: number | null }> = {},
): Promise<void> {
  const values = IDENTITY_COLUMNS.map((column) => identity[column] ?? null);
  await db
    .prepare(
      `INSERT INTO change_log
         (account_id, server_seq, entity_type, change_kind, revision,
          ${IDENTITY_COLUMNS.join(", ")})
       VALUES (?, ?, ?, ?, ?, ${IDENTITY_COLUMNS.map(() => "?").join(", ")})`,
    )
    .bind(
      accountId,
      overrides.serverSeq ?? 1,
      entityType,
      overrides.changeKind ?? "upsert",
      overrides.revision === undefined ? (entityType === "attachment" ? null : 5) : overrides.revision,
      ...values,
    )
    .run();
}

// Captured while 0008 is applied: beforeEach truncates business rows.
let legacyAccountCount = -1;
let legacyNextServerSeq = -1;
let legacyRoomEnvelope: string | null | undefined;
let accountFkCountAfterUpgrade = -1;

beforeAll(async () => {
  await applyD1Migrations(db, migrationsUpTo("0007_device_token.sql"));
  await insertAccount(ACCOUNT_A);
  await insertDevice(ACCOUNT_A, DEVICE_A);
  await insertRoom(ACCOUNT_A, ROOM_1);

  const before = await db
    .prepare(
      "SELECT count(*) AS n FROM sqlite_master WHERE type = 'table' AND name = 'operation_log'",
    )
    .first<{ n: number }>();
  expect(before?.n).toBe(0);

  await applyD1Migrations(db, STAGE_MIGRATIONS());

  const accounts = await db.prepare("SELECT count(*) AS n FROM account").first<{ n: number }>();
  legacyAccountCount = accounts?.n ?? -1;
  const seq = await db
    .prepare("SELECT next_server_seq AS n FROM account WHERE account_id = ?")
    .bind(ACCOUNT_A)
    .first<{ n: number }>();
  legacyNextServerSeq = seq?.n ?? -1;
  const room = await db
    .prepare("SELECT title_enc FROM room WHERE room_id = ?")
    .bind(ROOM_1)
    .first<{ title_enc: string | null }>();
  legacyRoomEnvelope = room?.title_enc;
  const fks = await db.prepare("PRAGMA foreign_key_list(device)").all<{ table: string }>();
  accountFkCountAfterUpgrade = fks.results.length;
});

// Children before parents: every foreign key here is RESTRICT.
beforeEach(async () => {
  for (const table of [
    "transaction_guard",
    "change_log",
    "operation_log",
    "room",
    "device",
    "account",
  ]) {
    await db.prepare(`DELETE FROM ${table}`).run();
  }
});

describe("A — 0007 → 0008 upgrade", () => {
  it("preserves the existing rows and their envelopes", () => {
    expect(legacyAccountCount).toBe(1);
    expect(legacyRoomEnvelope).toBe(ENVELOPE);
  });

  it("gives an existing account the initial next unallocated sequence", () => {
    expect(legacyNextServerSeq).toBe(1);
  });

  it("leaves the account foreign key graph untouched", () => {
    // ADD COLUMN is not a rebuild, so 0002's device → account constraint stays.
    expect(accountFkCountAfterUpgrade).toBe(1);
  });

  it("adds next_server_seq and nothing else to account", async () => {
    const info = await db.prepare("PRAGMA table_info(account)").all<{ name: string }>();
    expect(info.results.map((column) => column.name).sort()).toEqual([
      "account_id",
      "created_at",
      "next_server_seq",
    ]);
  });
});

describe("B — account sequence range", () => {
  it("defaults a new account to 1", async () => {
    await insertAccount(ACCOUNT_A);
    const row = await db
      .prepare("SELECT next_server_seq AS n FROM account")
      .first<{ n: number }>();
    expect(row?.n).toBe(1);
  });

  it("accepts 1 and the exhausted sentinel but nothing outside the internal range", async () => {
    await insertAccount(ACCOUNT_A);
    for (const value of [1, MAX_SEQ, EXHAUSTED_SENTINEL]) {
      await db
        .prepare("UPDATE account SET next_server_seq = ? WHERE account_id = ?")
        .bind(value, ACCOUNT_A)
        .run();
    }
    // 2^53 + 1 is not representable as a double and rounds back to the
    // sentinel, so the first value above the range that a client could
    // actually send is 2^53 + 2.
    for (const bad of [0, -1, EXHAUSTED_SENTINEL + 2, 1.5]) {
      await expectRejected(() =>
        db
          .prepare("UPDATE account SET next_server_seq = ? WHERE account_id = ?")
          .bind(bad, ACCOUNT_A)
          .run(),
      );
    }
  });

  it("refuses the sentinel as an allocated ledger sequence", async () => {
    // 2^53 means "exhausted"; it is never a value a row or cursor may carry.
    await insertAccount(ACCOUNT_A);
    await expectRejected(() =>
      insertOperationLog(ACCOUNT_A, { serverSeq: EXHAUSTED_SENTINEL }),
    );
    await expectRejected(() =>
      insertChangeLog(ACCOUNT_A, "room", IDENTITY_SHAPES.room as never, {
        serverSeq: EXHAUSTED_SENTINEL,
      }),
    );
  });
});

describe("C — operation_log", () => {
  it("stores a well-formed row", async () => {
    await insertAccount(ACCOUNT_A);
    await insertOperationLog(ACCOUNT_A);
    const row = await db
      .prepare("SELECT count(*) AS n FROM operation_log")
      .first<{ n: number }>();
    expect(row?.n).toBe(1);
  });

  it("keeps one row per operation and one sequence per account", async () => {
    await insertAccount(ACCOUNT_A);
    await insertOperationLog(ACCOUNT_A, { operationId: OPERATION_1, serverSeq: 1 });
    // Same operation id again: idempotency is a primary key, not a convention.
    await expectRejected(() =>
      insertOperationLog(ACCOUNT_A, { operationId: OPERATION_1, serverSeq: 2 }),
    );
    // Two operations may not share a sequence.
    await expectRejected(() =>
      insertOperationLog(ACCOUNT_A, { operationId: OPERATION_2, serverSeq: 1 }),
    );
    await insertOperationLog(ACCOUNT_A, { operationId: OPERATION_2, serverSeq: 2 });
  });

  it("keeps the same operation id and sequence separate under another account", async () => {
    await insertAccount(ACCOUNT_A);
    await insertAccount(ACCOUNT_B);
    await insertOperationLog(ACCOUNT_A, { operationId: OPERATION_1, serverSeq: 1 });
    await insertOperationLog(ACCOUNT_B, { operationId: OPERATION_1, serverSeq: 1 });
    const row = await db
      .prepare("SELECT count(*) AS n FROM operation_log")
      .first<{ n: number }>();
    expect(row?.n).toBe(2);
  });

  it("rejects an orphan row and a malformed fingerprint, uuid, entity or kind", async () => {
    await expectRejected(() => insertOperationLog(ACCOUNT_A));
    await insertAccount(ACCOUNT_A);
    for (const [index, fingerprint] of ["A".repeat(64), "a".repeat(63), `${"a".repeat(63)}g`, ""].entries()) {
      await expectRejected(() => insertOperationLog(ACCOUNT_A, { fingerprint }), `fingerprint#${index}`);
    }
    await expectRejected(() =>
      insertOperationLog(ACCOUNT_A, { operationId: OPERATION_MIXED.toLowerCase() }),
      "lowercase operation id",
    );
    for (const entityType of ["Room", "message", ""]) {
      await expectRejected(() => insertOperationLog(ACCOUNT_A, { entityType }), `entity:${entityType}`);
    }
    for (const changeKind of ["delete", "UPSERT", ""]) {
      await expectRejected(() => insertOperationLog(ACCOUNT_A, { changeKind }), `kind:${changeKind}`);
    }
    for (const [index, serverSeq] of [0, -1, MAX_SEQ + 1, 1.5].entries()) {
      await expectRejected(() => insertOperationLog(ACCOUNT_A, { serverSeq }), `seq#${index}`);
    }
  });

  it("ties result_revision nullability to the entity", async () => {
    await insertAccount(ACCOUNT_A);
    // attachment has no revision column at all, so a value would be invented.
    await insertOperationLog(ACCOUNT_A, {
      entityType: "attachment",
      resultRevision: null,
      serverSeq: 1,
    });
    await expectRejected(() =>
      insertOperationLog(ACCOUNT_A, {
        operationId: OPERATION_2,
        entityType: "attachment",
        resultRevision: 3,
        serverSeq: 2,
      }),
    );
    // Every other v1 entity does have one.
    await expectRejected(() =>
      insertOperationLog(ACCOUNT_A, {
        operationId: OPERATION_2,
        entityType: "room",
        resultRevision: null,
        serverSeq: 2,
      }),
    );
    await expectRejected(() =>
      insertOperationLog(ACCOUNT_A, {
        operationId: OPERATION_2,
        entityType: "room",
        resultRevision: -1,
        serverSeq: 2,
      }),
    );
  });

  it("stores no request body, token or ciphertext column", async () => {
    const info = await db.prepare("PRAGMA table_info(operation_log)").all<{ name: string }>();
    expect(info.results.map((column) => column.name).sort()).toEqual([
      "account_id",
      "change_kind",
      "entity_type",
      "operation_id",
      "request_fingerprint",
      "result_revision",
      "server_seq",
    ]);
  });
});

describe("D — change_log identity", () => {
  it("accepts exactly the documented shape for every entity type", async () => {
    await insertAccount(ACCOUNT_A);
    let seq = 1;
    for (const [entityType, identity] of Object.entries(IDENTITY_SHAPES)) {
      await insertChangeLog(ACCOUNT_A, entityType, identity, { serverSeq: seq });
      seq += 1;
    }
    const row = await db.prepare("SELECT count(*) AS n FROM change_log").first<{ n: number }>();
    expect(row?.n).toBe(Object.keys(IDENTITY_SHAPES).length);
  });

  it("refuses a shape missing one required axis", async () => {
    await insertAccount(ACCOUNT_A);
    for (const [entityType, identity] of Object.entries(IDENTITY_SHAPES)) {
      for (const axis of Object.keys(identity)) {
        const partial = { ...identity } as Record<string, string | number | null>;
        delete partial[axis];
        await expectRejected(() => insertChangeLog(ACCOUNT_A, entityType, partial));
      }
    }
  });

  it("refuses a shape carrying an axis that belongs to another entity", async () => {
    await insertAccount(ACCOUNT_A);
    const extras: Record<string, string | number> = {
      turn_id: TURN_1,
      message_id: MESSAGE_1,
      attachment_id: ATTACHMENT_1,
      persona_snapshot_id: PERSONA_1,
      checkpoint_id: CHECKPOINT_1,
    };
    for (const [entityType, identity] of Object.entries(IDENTITY_SHAPES)) {
      for (const [column, value] of Object.entries(extras)) {
        if (column in identity) continue;
        await expectRejected(() =>
          insertChangeLog(ACCOUNT_A, entityType, { ...identity, [column]: value }),
        );
      }
    }
  });

  it("allows the default worldline empty key where the scope has one", async () => {
    await insertAccount(ACCOUNT_A);
    // turn, bubble and checkpoint all live in a scope whose default worldline
    // is the empty storage key.
    let seq = 1;
    for (const entityType of ["turn", "bubble", "checkpoint"]) {
      await insertChangeLog(
        ACCOUNT_A,
        entityType,
        { ...IDENTITY_SHAPES[entityType], worldline_key: "" } as never,
        { serverSeq: seq },
      );
      seq += 1;
    }
  });

  it("refuses an empty worldline_key on the worldline entity itself", async () => {
    // A worldline row is named by its own id; there is no default worldline row.
    await insertAccount(ACCOUNT_A);
    await expectRejected(() =>
      insertChangeLog(ACCOUNT_A, "worldline", {
        ...IDENTITY_SHAPES.worldline,
        worldline_key: "",
      } as never),
    );
  });

  it("enforces the primary key, the sequence range and the account reference", async () => {
    await expectRejected(() =>
      insertChangeLog(ACCOUNT_A, "room", IDENTITY_SHAPES.room as never),
    );
    await insertAccount(ACCOUNT_A);
    await insertAccount(ACCOUNT_B);
    await insertChangeLog(ACCOUNT_A, "room", IDENTITY_SHAPES.room as never, { serverSeq: 1 });
    await expectRejected(() =>
      insertChangeLog(ACCOUNT_A, "room", IDENTITY_SHAPES.room as never, { serverSeq: 1 }),
    );
    // The same sequence under another account is a different cursor position.
    await insertChangeLog(ACCOUNT_B, "room", IDENTITY_SHAPES.room as never, { serverSeq: 1 });
    for (const serverSeq of [0, -1, MAX_SEQ + 1]) {
      await expectRejected(() =>
        insertChangeLog(ACCOUNT_A, "room", IDENTITY_SHAPES.room as never, { serverSeq }),
      );
    }
  });

  it("ties revision nullability to the entity, as operation_log does", async () => {
    await insertAccount(ACCOUNT_A);
    await insertChangeLog(ACCOUNT_A, "attachment", IDENTITY_SHAPES.attachment as never, {
      revision: null,
      serverSeq: 1,
    });
    await expectRejected(() =>
      insertChangeLog(ACCOUNT_A, "attachment", IDENTITY_SHAPES.attachment as never, {
        revision: 1,
        serverSeq: 2,
      }),
    );
    await expectRejected(() =>
      insertChangeLog(ACCOUNT_A, "room", IDENTITY_SHAPES.room as never, {
        revision: null,
        serverSeq: 2,
      }),
    );
  });

  it("stores identity as plain columns, never as a blob or owner key", async () => {
    const info = await db.prepare("PRAGMA table_info(change_log)").all<{ name: string }>();
    const columns = info.results.map((column) => column.name);
    expect(columns.sort()).toEqual(
      [
        "account_id",
        "server_seq",
        "entity_type",
        "change_kind",
        "revision",
        ...IDENTITY_COLUMNS,
      ].sort(),
    );
    for (const forbidden of ["identity", "identity_json", "owner_key", "storage_key", "payload"]) {
      expect(columns).not.toContain(forbidden);
    }
  });
});

describe("E — transaction_guard", () => {
  it("inserts when the scalar revision predicate holds", async () => {
    await insertAccount(ACCOUNT_A);
    await insertRoom(ACCOUNT_A, ROOM_1);
    await db
      .prepare(
        `INSERT INTO transaction_guard (account_id, operation_id, ok)
         VALUES (?, ?, ((SELECT revision FROM room
                          WHERE account_id = ? AND space_id = 'PHONE_SPACE' AND room_id = ?) = 4))`,
      )
      .bind(ACCOUNT_A, OPERATION_1, ACCOUNT_A, ROOM_1)
      .run();
    const row = await db
      .prepare("SELECT ok FROM transaction_guard WHERE operation_id = ?")
      .bind(OPERATION_1)
      .first<{ ok: number }>();
    expect(row?.ok).toBe(1);
  });

  it("fails the statement when the revision does not match", async () => {
    await insertAccount(ACCOUNT_A);
    await insertRoom(ACCOUNT_A, ROOM_1);
    // A CAS mismatch must not be a silent zero-row update.
    await expectRejected(() =>
      db
        .prepare(
          `INSERT INTO transaction_guard (account_id, operation_id, ok)
           VALUES (?, ?, ((SELECT revision FROM room
                            WHERE account_id = ? AND space_id = 'PHONE_SPACE' AND room_id = ?) = 99))`,
        )
        .bind(ACCOUNT_A, OPERATION_1, ACCOUNT_A, ROOM_1)
        .run(),
    );
    const row = await db
      .prepare("SELECT count(*) AS n FROM transaction_guard")
      .first<{ n: number }>();
    expect(row?.n).toBe(0);
  });

  it("fails the statement when the entity does not exist", async () => {
    // The scalar subquery is NULL, so NOT NULL rejects it. Existence and CAS
    // failure are two different constraints, and both abort.
    await insertAccount(ACCOUNT_A);
    await expectRejected(() =>
      db
        .prepare(
          `INSERT INTO transaction_guard (account_id, operation_id, ok)
           VALUES (?, ?, ((SELECT revision FROM room
                            WHERE account_id = ? AND space_id = 'PHONE_SPACE' AND room_id = ?) = 4))`,
        )
        .bind(ACCOUNT_A, OPERATION_1, ACCOUNT_A, ROOM_1)
        .run(),
    );
  });

  it("keys guard rows per account and operation, and lets them be deleted", async () => {
    await insertAccount(ACCOUNT_A);
    await insertAccount(ACCOUNT_B);
    await db
      .prepare("INSERT INTO transaction_guard (account_id, operation_id, ok) VALUES (?, ?, 1)")
      .bind(ACCOUNT_A, OPERATION_1)
      .run();
    // Concurrent operations of one account do not collide; two accounts may
    // hold the same operation id.
    await db
      .prepare("INSERT INTO transaction_guard (account_id, operation_id, ok) VALUES (?, ?, 1)")
      .bind(ACCOUNT_A, OPERATION_2)
      .run();
    await db
      .prepare("INSERT INTO transaction_guard (account_id, operation_id, ok) VALUES (?, ?, 1)")
      .bind(ACCOUNT_B, OPERATION_1)
      .run();
    await expectRejected(() =>
      db
        .prepare("INSERT INTO transaction_guard (account_id, operation_id, ok) VALUES (?, ?, 1)")
        .bind(ACCOUNT_A, OPERATION_1)
        .run(),
    );
    // The handler clears its row at the end of a successful batch.
    await db
      .prepare("DELETE FROM transaction_guard WHERE account_id = ? AND operation_id = ?")
      .bind(ACCOUNT_A, OPERATION_1)
      .run();
    const row = await db
      .prepare("SELECT count(*) AS n FROM transaction_guard")
      .first<{ n: number }>();
    expect(row?.n).toBe(2);
  });

  it("refuses ok = 0 and refuses to lose an account that still has a guard row", async () => {
    await insertAccount(ACCOUNT_A);
    await expectRejected(() =>
      db
        .prepare("INSERT INTO transaction_guard (account_id, operation_id, ok) VALUES (?, ?, 0)")
        .bind(ACCOUNT_A, OPERATION_1)
        .run(),
    );
    await db
      .prepare("INSERT INTO transaction_guard (account_id, operation_id, ok) VALUES (?, ?, 1)")
      .bind(ACCOUNT_A, OPERATION_1)
      .run();
    await expectRejected(() =>
      db.prepare("DELETE FROM account WHERE account_id = ?").bind(ACCOUNT_A).run(),
    );
  });

  it("needs no temp table, trigger or deferred foreign key", async () => {
    const triggers = await db
      .prepare("SELECT count(*) AS n FROM sqlite_master WHERE type = 'trigger' AND tbl_name = ?")
      .bind("transaction_guard")
      .first<{ n: number }>();
    expect(triggers?.n).toBe(0);
  });
});

describe("F — migration contract", () => {
  it("records eight migrations and replays as a no-op", async () => {
    const ledger = await db
      .prepare("SELECT name FROM d1_migrations ORDER BY id")
      .all<{ name: string }>();
    expect(ledger.results.length).toBe(8);
    expect(ledger.results.map((row) => row.name).at(-1)).toBe(LEDGER_MIGRATION);
    await applyD1Migrations(db, STAGE_MIGRATIONS());
    const after = await db
      .prepare("SELECT count(*) AS n FROM d1_migrations")
      .first<{ n: number }>();
    expect(after?.n).toBe(8);
  });

  it("rolls back a failing migration and leaves no scaffolding", async () => {
    const failing: D1Migration = {
      name: "9999_intentionally_failing.sql",
      queries: [
        "CREATE TABLE scratch_should_not_survive (x TEXT NOT NULL)",
        "INSERT INTO scratch_should_not_survive (x) SELECT x FROM table_that_does_not_exist",
      ],
    };
    await expectRejected(() => applyD1Migrations(db, [...STAGE_MIGRATIONS(), failing]));
    const tables = await db
      .prepare(
        `SELECT name FROM sqlite_master
          WHERE type = 'table'
            AND (name = 'scratch_should_not_survive'
                 OR name GLOB '*_staging*' OR name GLOB '*_new')`,
      )
      .all<{ name: string }>();
    expect(tables.results).toEqual([]);
    const ledger = await db
      .prepare("SELECT count(*) AS n FROM d1_migrations")
      .first<{ n: number }>();
    expect(ledger?.n).toBe(8);
  });
});
