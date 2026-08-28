import { applyD1Migrations, env } from "cloudflare:test";
import type { D1Migration } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";

// Test-only binding injected by vitest.config.ts. Declared here rather than in
// the production `Env` so a fixture binding can never look like something a
// request handler may rely on.
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

// Synthetic identifiers only. Nothing here comes from a real account, device,
// room, conversation or token, and no assertion prints a full identifier.
const ACCOUNT_A = "A0000000-0000-4000-8000-00000000000A";
const ACCOUNT_B = "A0000000-0000-4000-8000-00000000000B";
const DEVICE_1 = "B0000000-0000-4000-8000-000000000001";
const ROOM_1 = "10000000-0000-4000-8000-000000000001";
const ROOM_2 = "10000000-0000-4000-8000-000000000002";
const WORLDLINE_1 = "20000000-0000-4000-8000-000000000001";
const WORLDLINE_2 = "20000000-0000-4000-8000-000000000002";
const TIMESTAMP = "2026-08-28T00:00:00Z";

// Stand-in for a base64 field envelope. The bytes carry no meaning: D1 never
// decodes them, it only has to preserve them.
const SYNTHETIC_ENVELOPE = "AQEAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==";

const CONVERSATION_SCOPE_MIGRATION = "0003_conversation_scope.sql";

const db = env.DB;

// This file is a *stage* contract: it applies the migrations up to and
// including its own and no further, so a later stage adding tables, triggers or
// ledger rows cannot invalidate what it asserts about this one.
const STAGE_MIGRATIONS = () => migrationsUpTo("0003_conversation_scope.sql");

function migrationsUpTo(name: string): D1Migration[] {
  const index = env.TEST_MIGRATIONS.findIndex((migration) => migration.name === name);
  expect(index).toBeGreaterThanOrEqual(0);
  return env.TEST_MIGRATIONS.slice(0, index + 1);
}

/** Assert a statement fails, without echoing the offending value. */
async function expectRejected(run: () => Promise<unknown>): Promise<void> {
  let threw = false;
  try {
    await run();
  } catch {
    threw = true;
  }
  expect(threw).toBe(true);
}

async function insertAccount(accountId: string): Promise<void> {
  await db
    .prepare("INSERT INTO account (account_id, created_at) VALUES (?, ?)")
    .bind(accountId, TIMESTAMP)
    .run();
}

async function insertRoom(
  accountId: string,
  spaceId: string,
  roomId: string,
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO room
         (account_id, space_id, room_id, title_enc, status_message_enc,
          music_title_enc, music_artist_enc, revision, server_seq,
          created_at, updated_at)
       VALUES (?, ?, ?, ?, NULL, NULL, NULL, 0, NULL, ?, ?)`,
    )
    .bind(accountId, spaceId, roomId, SYNTHETIC_ENVELOPE, TIMESTAMP, TIMESTAMP)
    .run();
}

async function insertGroupState(
  accountId: string,
  spaceId: string,
  roomId: string,
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO group_state
         (account_id, space_id, room_id, participants_enc,
          active_worldline_id_enc, revision, server_seq, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, 0, NULL, ?, ?)`,
    )
    .bind(
      accountId,
      spaceId,
      roomId,
      SYNTHETIC_ENVELOPE,
      SYNTHETIC_ENVELOPE,
      TIMESTAMP,
      TIMESTAMP,
    )
    .run();
}

async function insertWorldline(
  accountId: string,
  spaceId: string,
  roomId: string,
  worldlineId: string | null,
  worldlineKey: string,
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO worldline
         (account_id, space_id, room_id, worldline_id, worldline_key,
          name_enc, participant_hearts_enc, revision, server_seq,
          created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, 0, NULL, ?, ?)`,
    )
    .bind(
      accountId,
      spaceId,
      roomId,
      worldlineId,
      worldlineKey,
      SYNTHETIC_ENVELOPE,
      SYNTHETIC_ENVELOPE,
      TIMESTAMP,
      TIMESTAMP,
    )
    .run();
}

// Rows written under the account boundary (0001 + 0002) before the
// conversation scope exists. 0003 must leave them exactly as they are.
beforeAll(async () => {
  await applyD1Migrations(db, migrationsUpTo("0002_device_account_fk.sql"));

  await insertAccount(ACCOUNT_A);
  await db
    .prepare(
      `INSERT INTO device
         (account_id, device_id, space_id, platform, display_name_enc,
          linked_at, revoked_at, key_generation)
       VALUES (?, ?, ?, ?, ?, ?, NULL, 1)`,
    )
    .bind(ACCOUNT_A, DEVICE_1, "PHONE_SPACE", "android_phone", SYNTHETIC_ENVELOPE, TIMESTAMP)
    .run();

  // No conversation table may exist yet.
  const before = await db
    .prepare("SELECT count(*) AS n FROM sqlite_master WHERE type = 'table' AND name = 'room'")
    .first<{ n: number }>();
  expect(before?.n).toBe(0);

  await applyD1Migrations(db, STAGE_MIGRATIONS());
});

// The plugin isolates storage per test *file*. Within this file the tests
// share one database, so each one states its own precondition explicitly.
// Children are cleared before parents: RESTRICT means the reverse order fails.
beforeEach(async () => {
  await db.prepare("DELETE FROM worldline").run();
  await db.prepare("DELETE FROM group_state").run();
  await db.prepare("DELETE FROM room").run();
  await db.prepare("DELETE FROM device").run();
  await db.prepare("DELETE FROM account").run();
});

describe("M02 — 0001 → 0002 → 0003 applies in order", () => {
  it("records the three migrations in order, once each", async () => {
    const rows = await db
      .prepare("SELECT name FROM d1_migrations ORDER BY id")
      .all<{ name: string }>();
    expect(rows.results.map((row) => row.name)).toEqual([
      "0001_account_device.sql",
      "0002_device_account_fk.sql",
      CONVERSATION_SCOPE_MIGRATION,
    ]);
  });

  it("is a no-op when applied again", async () => {
    await applyD1Migrations(db, STAGE_MIGRATIONS());
    const row = await db.prepare("SELECT count(*) AS n FROM d1_migrations").first<{ n: number }>();
    expect(row?.n).toBe(3);
  });

  it("creates exactly the M02 tables and nothing from M03..M06", async () => {
    const rows = await db
      .prepare(
        `SELECT name FROM sqlite_master
          WHERE type = 'table'
            AND name NOT LIKE 'sqlite_%'
            AND name NOT GLOB '_cf_*'
            AND name <> 'd1_migrations'
          ORDER BY name`,
      )
      .all<{ name: string }>();
    const names = rows.results.map((row) => row.name);
    expect(names).toEqual(["account", "device", "group_state", "room", "worldline"]);
    for (const later of [
      "turn",
      "bubble",
      "extension_field",
      "attachment",
      "operation_log",
      "change_log",
    ]) {
      expect(names).not.toContain(later);
    }
  });

  it("leaves no rebuild scaffolding behind", async () => {
    const rows = await db
      .prepare(
        `SELECT name FROM sqlite_master
          WHERE type = 'table' AND name GLOB '*_with_*'`,
      )
      .all<{ name: string }>();
    expect(rows.results).toEqual([]);
  });

  it("does not add account.next_server_seq, which belongs to M06", async () => {
    const info = await db.prepare("PRAGMA table_info(account)").all<{ name: string }>();
    expect(info.results.map((column) => column.name).sort()).toEqual([
      "account_id",
      "created_at",
    ]);
  });
});

describe("M02 — the account boundary rows survive", () => {
  it("preserves the account and device written before 0003", async () => {
    // beforeEach truncates, so this reads the ledger-independent fact that
    // the tables themselves were never rebuilt or dropped by 0003.
    const info = await db.prepare("PRAGMA table_info(device)").all<{ name: string }>();
    expect(info.results.map((column) => column.name).sort()).toEqual([
      "account_id",
      "device_id",
      "display_name_enc",
      "key_generation",
      "linked_at",
      "platform",
      "revoked_at",
      "space_id",
    ]);
    const fks = await db.prepare("PRAGMA foreign_key_list(device)").all<{ table: string }>();
    expect(fks.results.length).toBe(1);
    expect(fks.results[0]?.table).toBe("account");
  });
});

describe("M02 — room identity", () => {
  it("stores a room under an existing account", async () => {
    await insertAccount(ACCOUNT_A);
    await insertRoom(ACCOUNT_A, "MAC_SPACE", ROOM_1);
    const row = await db
      .prepare("SELECT count(*) AS n FROM room WHERE account_id = ? AND room_id = ?")
      .bind(ACCOUNT_A, ROOM_1)
      .first<{ n: number }>();
    expect(row?.n).toBe(1);
  });

  it("rejects an orphan room whose account does not exist", async () => {
    await expectRejected(() => insertRoom(ACCOUNT_A, "MAC_SPACE", ROOM_1));
    const row = await db.prepare("SELECT count(*) AS n FROM room").first<{ n: number }>();
    expect(row?.n).toBe(0);
  });

  it("keys the room by (account_id, space_id, room_id)", async () => {
    const info = await db.prepare("PRAGMA table_info(room)").all<{
      name: string;
      pk: number;
    }>();
    const key = info.results
      .filter((column) => column.pk > 0)
      .sort((a, b) => a.pk - b.pk)
      .map((column) => column.name);
    expect(key).toEqual(["account_id", "space_id", "room_id"]);
  });

  it("keeps the same room UUID separate under two accounts", async () => {
    await insertAccount(ACCOUNT_A);
    await insertAccount(ACCOUNT_B);
    await insertRoom(ACCOUNT_A, "MAC_SPACE", ROOM_1);
    await insertRoom(ACCOUNT_B, "MAC_SPACE", ROOM_1);

    const total = await db
      .prepare("SELECT count(*) AS n FROM room WHERE room_id = ?")
      .bind(ROOM_1)
      .first<{ n: number }>();
    expect(total?.n).toBe(2);

    const forA = await db
      .prepare("SELECT count(*) AS n FROM room WHERE account_id = ? AND room_id = ?")
      .bind(ACCOUNT_A, ROOM_1)
      .first<{ n: number }>();
    expect(forA?.n).toBe(1);
  });

  it("keeps the same room UUID separate in two spaces of one account", async () => {
    await insertAccount(ACCOUNT_A);
    await insertRoom(ACCOUNT_A, "MAC_SPACE", ROOM_1);
    await insertRoom(ACCOUNT_A, "PHONE_SPACE", ROOM_1);
    const row = await db
      .prepare("SELECT count(*) AS n FROM room WHERE account_id = ? AND room_id = ?")
      .bind(ACCOUNT_A, ROOM_1)
      .first<{ n: number }>();
    expect(row?.n).toBe(2);
  });

  it("rejects a duplicate room inside one account and space", async () => {
    await insertAccount(ACCOUNT_A);
    await insertRoom(ACCOUNT_A, "MAC_SPACE", ROOM_1);
    await expectRejected(() => insertRoom(ACCOUNT_A, "MAC_SPACE", ROOM_1));
  });

  it("rejects a non-canonical space enum and a lowercase room id", async () => {
    await insertAccount(ACCOUNT_A);
    for (const bad of ["tablet", "phone_space", ""]) {
      await expectRejected(() => insertRoom(ACCOUNT_A, bad, ROOM_1));
    }
    await expectRejected(() =>
      insertRoom(ACCOUNT_A, "MAC_SPACE", "10000000-0000-4000-8000-00000000000a"),
    );
  });

  it("refuses to delete an account that still owns a room", async () => {
    await insertAccount(ACCOUNT_A);
    await insertRoom(ACCOUNT_A, "MAC_SPACE", ROOM_1);
    await expectRejected(() =>
      db.prepare("DELETE FROM account WHERE account_id = ?").bind(ACCOUNT_A).run(),
    );
    const rooms = await db.prepare("SELECT count(*) AS n FROM room").first<{ n: number }>();
    expect(rooms?.n).toBe(1);
  });

  it("preserves the encrypted envelope byte-for-byte", async () => {
    await insertAccount(ACCOUNT_A);
    await insertRoom(ACCOUNT_A, "MAC_SPACE", ROOM_1);
    const row = await db
      .prepare("SELECT title_enc FROM room WHERE account_id = ? AND space_id = ? AND room_id = ?")
      .bind(ACCOUNT_A, "MAC_SPACE", ROOM_1)
      .first<{ title_enc: string | null }>();
    expect(row?.title_enc).toBe(SYNTHETIC_ENVELOPE);
  });
});

describe("M02 — group_state is a room-level PHONE_SPACE row", () => {
  it("has no worldline dimension in its columns", async () => {
    const info = await db.prepare("PRAGMA table_info(group_state)").all<{ name: string }>();
    const columns = info.results.map((column) => column.name);
    // `active_worldline_id_enc` is an encrypted payload field, not identity;
    // no plaintext worldline axis may exist on this table at all.
    expect(columns).not.toContain("worldline_id");
    expect(columns).not.toContain("worldline_key");
  });

  it("keys group_state by (account_id, space_id, room_id) only", async () => {
    const info = await db.prepare("PRAGMA table_info(group_state)").all<{
      name: string;
      pk: number;
    }>();
    const key = info.results
      .filter((column) => column.pk > 0)
      .sort((a, b) => a.pk - b.pk)
      .map((column) => column.name);
    expect(key).toEqual(["account_id", "space_id", "room_id"]);
  });

  it("stores one group_state for a PHONE_SPACE room", async () => {
    await insertAccount(ACCOUNT_A);
    await insertRoom(ACCOUNT_A, "PHONE_SPACE", ROOM_1);
    await insertGroupState(ACCOUNT_A, "PHONE_SPACE", ROOM_1);
    const row = await db
      .prepare("SELECT count(*) AS n FROM group_state WHERE account_id = ?")
      .bind(ACCOUNT_A)
      .first<{ n: number }>();
    expect(row?.n).toBe(1);
  });

  it("rejects group_state outside PHONE_SPACE even with a real parent room", async () => {
    await insertAccount(ACCOUNT_A);
    for (const space of ["MAC_SPACE", "TABLET_SPACE"]) {
      await insertRoom(ACCOUNT_A, space, ROOM_1);
      await expectRejected(() => insertGroupState(ACCOUNT_A, space, ROOM_1));
    }
  });

  it("rejects group_state whose parent room does not exist", async () => {
    await insertAccount(ACCOUNT_A);
    await expectRejected(() => insertGroupState(ACCOUNT_A, "PHONE_SPACE", ROOM_1));
  });

  it("rejects group_state pointing at another account's room", async () => {
    await insertAccount(ACCOUNT_A);
    await insertAccount(ACCOUNT_B);
    await insertRoom(ACCOUNT_B, "PHONE_SPACE", ROOM_1);
    // The room UUID exists, but not under ACCOUNT_A.
    await expectRejected(() => insertGroupState(ACCOUNT_A, "PHONE_SPACE", ROOM_1));
  });

  it("refuses to delete a room that still has group_state", async () => {
    await insertAccount(ACCOUNT_A);
    await insertRoom(ACCOUNT_A, "PHONE_SPACE", ROOM_1);
    await insertGroupState(ACCOUNT_A, "PHONE_SPACE", ROOM_1);
    await expectRejected(() =>
      db
        .prepare("DELETE FROM room WHERE account_id = ? AND space_id = ? AND room_id = ?")
        .bind(ACCOUNT_A, "PHONE_SPACE", ROOM_1)
        .run(),
    );
    const row = await db.prepare("SELECT count(*) AS n FROM group_state").first<{ n: number }>();
    expect(row?.n).toBe(1);
  });
});

describe("M02 — worldline key materialisation", () => {
  it("keys worldline by scope plus worldline_key", async () => {
    const info = await db.prepare("PRAGMA table_info(worldline)").all<{
      name: string;
      pk: number;
    }>();
    const key = info.results
      .filter((column) => column.pk > 0)
      .sort((a, b) => a.pk - b.pk)
      .map((column) => column.name);
    expect(key).toEqual(["account_id", "space_id", "room_id", "worldline_key"]);
  });

  it("keeps worldline_id nullable and worldline_key non-null", async () => {
    const info = await db.prepare("PRAGMA table_info(worldline)").all<{
      name: string;
      notnull: number;
    }>();
    expect(info.results.find((c) => c.name === "worldline_id")?.notnull).toBe(0);
    expect(info.results.find((c) => c.name === "worldline_key")?.notnull).toBe(1);
  });

  it("accepts a null worldline_id with an empty worldline_key", async () => {
    await insertAccount(ACCOUNT_A);
    await insertRoom(ACCOUNT_A, "PHONE_SPACE", ROOM_1);
    await insertWorldline(ACCOUNT_A, "PHONE_SPACE", ROOM_1, null, "");
    const row = await db
      .prepare(
        `SELECT worldline_id, worldline_key FROM worldline
          WHERE account_id = ? AND space_id = ? AND room_id = ?`,
      )
      .bind(ACCOUNT_A, "PHONE_SPACE", ROOM_1)
      .first<{ worldline_id: string | null; worldline_key: string }>();
    expect(row?.worldline_id).toBeNull();
    expect(row?.worldline_key).toBe("");
  });

  it("accepts a UUID worldline_id whose key is exactly the same string", async () => {
    await insertAccount(ACCOUNT_A);
    await insertRoom(ACCOUNT_A, "PHONE_SPACE", ROOM_1);
    await insertWorldline(ACCOUNT_A, "PHONE_SPACE", ROOM_1, WORLDLINE_1, WORLDLINE_1);
    const row = await db
      .prepare("SELECT worldline_key FROM worldline WHERE worldline_id = ?")
      .bind(WORLDLINE_1)
      .first<{ worldline_key: string }>();
    expect(row?.worldline_key).toBe(WORLDLINE_1);
  });

  it("rejects every mismatch between worldline_id and worldline_key", async () => {
    await insertAccount(ACCOUNT_A);
    await insertRoom(ACCOUNT_A, "PHONE_SPACE", ROOM_1);
    // null id with a non-empty key
    await expectRejected(() =>
      insertWorldline(ACCOUNT_A, "PHONE_SPACE", ROOM_1, null, WORLDLINE_1),
    );
    // UUID id with an empty key
    await expectRejected(() =>
      insertWorldline(ACCOUNT_A, "PHONE_SPACE", ROOM_1, WORLDLINE_1, ""),
    );
    // UUID id with a different UUID as the key
    await expectRejected(() =>
      insertWorldline(ACCOUNT_A, "PHONE_SPACE", ROOM_1, WORLDLINE_1, WORLDLINE_2),
    );
    const row = await db.prepare("SELECT count(*) AS n FROM worldline").first<{ n: number }>();
    expect(row?.n).toBe(0);
  });

  it("rejects a lowercase worldline_id", async () => {
    await insertAccount(ACCOUNT_A);
    await insertRoom(ACCOUNT_A, "PHONE_SPACE", ROOM_1);
    const lower = "20000000-0000-4000-8000-00000000000a";
    await expectRejected(() => insertWorldline(ACCOUNT_A, "PHONE_SPACE", ROOM_1, lower, lower));
  });

  it("stores the default worldline and a named one side by side", async () => {
    // The empty key is what stops two default worldlines from both inserting:
    // NULL would not compare equal to NULL in the primary key.
    await insertAccount(ACCOUNT_A);
    await insertRoom(ACCOUNT_A, "PHONE_SPACE", ROOM_1);
    await insertWorldline(ACCOUNT_A, "PHONE_SPACE", ROOM_1, null, "");
    await insertWorldline(ACCOUNT_A, "PHONE_SPACE", ROOM_1, WORLDLINE_1, WORLDLINE_1);
    await expectRejected(() => insertWorldline(ACCOUNT_A, "PHONE_SPACE", ROOM_1, null, ""));
    const row = await db.prepare("SELECT count(*) AS n FROM worldline").first<{ n: number }>();
    expect(row?.n).toBe(2);
  });
});

describe("M02 — worldline scope", () => {
  it("rejects a worldline outside PHONE_SPACE", async () => {
    await insertAccount(ACCOUNT_A);
    for (const space of ["MAC_SPACE", "TABLET_SPACE"]) {
      await insertRoom(ACCOUNT_A, space, ROOM_1);
      await expectRejected(() =>
        insertWorldline(ACCOUNT_A, space, ROOM_1, WORLDLINE_1, WORLDLINE_1),
      );
    }
  });

  it("rejects a worldline whose parent room does not exist", async () => {
    await insertAccount(ACCOUNT_A);
    await insertRoom(ACCOUNT_A, "PHONE_SPACE", ROOM_1);
    await expectRejected(() =>
      insertWorldline(ACCOUNT_A, "PHONE_SPACE", ROOM_2, WORLDLINE_1, WORLDLINE_1),
    );
  });

  it("rejects a worldline pointing at another account's room", async () => {
    await insertAccount(ACCOUNT_A);
    await insertAccount(ACCOUNT_B);
    await insertRoom(ACCOUNT_B, "PHONE_SPACE", ROOM_1);
    await expectRejected(() =>
      insertWorldline(ACCOUNT_A, "PHONE_SPACE", ROOM_1, WORLDLINE_1, WORLDLINE_1),
    );
  });

  it("refuses to delete a room that still has a worldline", async () => {
    await insertAccount(ACCOUNT_A);
    await insertRoom(ACCOUNT_A, "PHONE_SPACE", ROOM_1);
    await insertWorldline(ACCOUNT_A, "PHONE_SPACE", ROOM_1, WORLDLINE_1, WORLDLINE_1);
    await expectRejected(() =>
      db
        .prepare("DELETE FROM room WHERE account_id = ? AND space_id = ? AND room_id = ?")
        .bind(ACCOUNT_A, "PHONE_SPACE", ROOM_1)
        .run(),
    );
    const row = await db.prepare("SELECT count(*) AS n FROM worldline").first<{ n: number }>();
    expect(row?.n).toBe(1);
  });

  it("declares RESTRICT, never CASCADE, on every foreign key", async () => {
    for (const table of ["room", "group_state", "worldline"]) {
      const fks = await db.prepare(`PRAGMA foreign_key_list(${table})`).all<{
        table: string;
        on_delete: string;
        on_update: string;
      }>();
      expect(fks.results.length).toBeGreaterThan(0);
      for (const fk of fks.results) {
        expect(fk.on_delete).toBe("RESTRICT");
        expect(fk.on_update).toBe("RESTRICT");
      }
    }
  });
});

describe("M02 — a failing migration leaves nothing behind", () => {
  it("rolls back both the partial schema and the ledger row", async () => {
    // A migration is applied as one transactional batch together with its
    // ledger row, so a later statement failing must undo the earlier CREATE.
    // This is what lets 0003 be re-run from empty after a defect is fixed.
    const failing: D1Migration = {
      name: "9999_intentionally_failing.sql",
      queries: [
        "CREATE TABLE scratch_should_not_survive (x TEXT NOT NULL)",
        "INSERT INTO scratch_should_not_survive (x) SELECT x FROM table_that_does_not_exist",
      ],
    };

    await expectRejected(() =>
      applyD1Migrations(db, [...STAGE_MIGRATIONS(), failing]),
    );

    const table = await db
      .prepare(
        "SELECT count(*) AS n FROM sqlite_master WHERE type = 'table' AND name = 'scratch_should_not_survive'",
      )
      .first<{ n: number }>();
    expect(table?.n).toBe(0);

    const ledger = await db
      .prepare("SELECT name FROM d1_migrations ORDER BY id")
      .all<{ name: string }>();
    expect(ledger.results.map((row) => row.name)).toEqual([
      "0001_account_device.sql",
      "0002_device_account_fk.sql",
      CONVERSATION_SCOPE_MIGRATION,
    ]);
  });
});
