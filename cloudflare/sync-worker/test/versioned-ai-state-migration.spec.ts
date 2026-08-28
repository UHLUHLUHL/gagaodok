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
// persona, attachment or token appears here, and no assertion prints one.
const ACCOUNT_A = "A0000000-0000-4000-8000-00000000000A";
const ACCOUNT_B = "A0000000-0000-4000-8000-00000000000B";
const DEVICE_A = "B0000000-0000-4000-8000-00000000000A";
const DEVICE_B = "B0000000-0000-4000-8000-00000000000B";
const ROOM_1 = "10000000-0000-4000-8000-000000000001";
const ROOM_2 = "10000000-0000-4000-8000-000000000002";
const WORLDLINE_1 = "20000000-0000-4000-8000-000000000001";
const TURN_1 = "30000000-0000-4000-8000-000000000001";
const TURN_2 = "30000000-0000-4000-8000-000000000002";
const PERSONA_1 = "50000000-0000-4000-8000-000000000001";
const CHECKPOINT_1 = "60000000-0000-4000-8000-000000000001";
const ENGINE_1 = "C0000000-0000-4000-8000-0000000000E1";
const TIMESTAMP = "2026-08-28T00:00:00Z";
const COMPAT_TAG = "6f5c2b1ad0e94f3182c7a6d5e4b39c81";

const ENVELOPE_A = "AQEAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==";
const ENVELOPE_B = "AQECAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==";

const AI_STATE_MIGRATION = "0005_versioned_ai_state.sql";
const MAX_SAFE = 9007199254740991;

const db = env.DB;

function migrationsUpTo(name: string): D1Migration[] {
  const index = env.TEST_MIGRATIONS.findIndex((migration) => migration.name === name);
  expect(index).toBeGreaterThanOrEqual(0);
  return env.TEST_MIGRATIONS.slice(0, index + 1);
}

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

async function insertRoom(accountId: string, spaceId: string, roomId: string): Promise<void> {
  await db
    .prepare(
      `INSERT INTO room
         (account_id, space_id, room_id, title_enc, status_message_enc,
          music_title_enc, music_artist_enc, revision, server_seq,
          created_at, updated_at)
       VALUES (?, ?, ?, NULL, NULL, NULL, NULL, 0, NULL, ?, ?)`,
    )
    .bind(accountId, spaceId, roomId, TIMESTAMP, TIMESTAMP)
    .run();
}

async function insertTurn(
  accountId: string,
  spaceId: string,
  roomId: string,
  turnId: string,
  worldlineId: string | null = null,
  deviceId = DEVICE_A,
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO turn
         (account_id, space_id, room_id, worldline_id, worldline_key, turn_id,
          canonical_text_enc, heart_changes_enc, generation_profile_ref_enc,
          fallback_reason_enc, created_by_device_id, created_at, revision,
          server_seq, is_tombstoned, tombstoned_at, tombstone_operation_id)
       VALUES (?, ?, ?, ?, ?, ?, NULL, NULL, NULL, NULL, ?, ?, 0, NULL, 0, NULL, NULL)`,
    )
    .bind(
      accountId,
      spaceId,
      roomId,
      worldlineId,
      worldlineId ?? "",
      turnId,
      deviceId,
      TIMESTAMP,
    )
    .run();
}

async function insertEngineProfile(
  accountId: string,
  spaceId: string,
  engineProfileId: string,
  profileRevision: unknown,
  compatTag: string | null = COMPAT_TAG,
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO engine_profile
         (account_id, space_id, engine_profile_id, profile_revision,
          mode_enc, model_capability_enc, prompt_profile_id_enc,
          prompt_profile_version_enc, relationship_policy_enc,
          compaction_profile_id_enc, compaction_contract_fingerprint_enc,
          cache_policy_enc, repetition_policy_enc, compaction_compat_tag,
          server_seq)
       VALUES (?, ?, ?, ?, ?, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, ?, NULL)`,
    )
    .bind(accountId, spaceId, engineProfileId, profileRevision, ENVELOPE_A, compatTag)
    .run();
}

async function insertPersonaSnapshot(
  accountId: string,
  spaceId: string,
  personaSnapshotId: string,
  snapshotRevision: unknown,
  overrides: Partial<{ ownerSpaceId: string; deviceId: string; schemaVersion: number }> = {},
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO persona_snapshot
         (account_id, space_id, persona_snapshot_id, snapshot_revision,
          owner_space_id, created_by_device_id, created_at,
          persona_schema_version, description_enc, samples_enc,
          style_guide_enc, is_enabled_enc, content_fingerprint_enc, server_seq)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, NULL, NULL)`,
    )
    .bind(
      accountId,
      spaceId,
      personaSnapshotId,
      snapshotRevision,
      overrides.ownerSpaceId ?? spaceId,
      overrides.deviceId ?? DEVICE_A,
      TIMESTAMP,
      overrides.schemaVersion ?? 1,
      ENVELOPE_A,
    )
    .run();
}

async function insertPersonaHead(
  accountId: string,
  spaceId: string,
  personaSnapshotId: string,
  currentRevision: number,
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO persona_snapshot_head
         (account_id, space_id, persona_snapshot_id, current_snapshot_revision)
       VALUES (?, ?, ?, ?)`,
    )
    .bind(accountId, spaceId, personaSnapshotId, currentRevision)
    .run();
}

async function insertPersonaExtension(
  accountId: string,
  spaceId: string,
  personaSnapshotId: string,
  snapshotRevision: number,
  key: string,
  envelope = ENVELOPE_A,
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO persona_snapshot_extension_field
         (account_id, space_id, persona_snapshot_id, snapshot_revision,
          extension_key, envelope_enc)
       VALUES (?, ?, ?, ?, ?, ?)`,
    )
    .bind(accountId, spaceId, personaSnapshotId, snapshotRevision, key, envelope)
    .run();
}

type CheckpointOverrides = Partial<{
  worldlineId: string | null;
  firstTurnId: string | null;
  lastTurnId: string | null;
  throughServerSeq: unknown;
  revision: number;
  ownerSpaceId: string;
  deviceId: string;
  schemaVersion: number;
}>;

async function insertCheckpoint(
  accountId: string,
  spaceId: string,
  roomId: string,
  checkpointId: string,
  overrides: CheckpointOverrides = {},
): Promise<void> {
  const worldlineId = overrides.worldlineId === undefined ? null : overrides.worldlineId;
  await db
    .prepare(
      `INSERT INTO checkpoint
         (account_id, space_id, room_id, worldline_id, worldline_key,
          checkpoint_id, first_turn_id, last_turn_id, through_server_seq,
          segments_enc, summary_text_enc, checkpoint_schema_version,
          compaction_profile_id_enc, compaction_contract_fingerprint_enc,
          compaction_compat_tag, owner_space_id, created_by_device_id,
          created_at, revision, server_seq)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, NULL, ?, ?, ?, ?, ?, NULL)`,
    )
    .bind(
      accountId,
      spaceId,
      roomId,
      worldlineId,
      worldlineId ?? "",
      checkpointId,
      overrides.firstTurnId ?? null,
      overrides.lastTurnId ?? null,
      overrides.throughServerSeq ?? null,
      ENVELOPE_B,
      overrides.schemaVersion ?? 1,
      ENVELOPE_A,
      COMPAT_TAG,
      overrides.ownerSpaceId ?? spaceId,
      overrides.deviceId ?? DEVICE_A,
      TIMESTAMP,
      overrides.revision ?? 0,
    )
    .run();
}

async function insertRoomAiStateRef(
  accountId: string,
  spaceId: string,
  roomId: string,
  engine: [string, number] | null,
  persona: [string, number] | null,
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO room_ai_state_ref
         (account_id, space_id, room_id, engine_profile_id,
          engine_profile_revision, persona_snapshot_id, persona_snapshot_revision)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
    )
    .bind(
      accountId,
      spaceId,
      roomId,
      engine?.[0] ?? null,
      engine?.[1] ?? null,
      persona?.[0] ?? null,
      persona?.[1] ?? null,
    )
    .run();
}

/** account + device + one room, the common precondition. */
async function seedScope(
  accountId = ACCOUNT_A,
  spaceId = "PHONE_SPACE",
  roomId = ROOM_1,
): Promise<void> {
  await insertAccount(accountId);
  await insertDevice(accountId, accountId === ACCOUNT_A ? DEVICE_A : DEVICE_B);
  await insertRoom(accountId, spaceId, roomId);
}

const survivingRows: Record<string, number> = {};

beforeAll(async () => {
  // Rows written under M01..M03 before the versioned AI state exists.
  await applyD1Migrations(db, migrationsUpTo("0004_turn_bubble_extension.sql"));
  await insertAccount(ACCOUNT_A);
  await insertDevice(ACCOUNT_A, DEVICE_A);
  await insertRoom(ACCOUNT_A, "PHONE_SPACE", ROOM_1);
  await insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1);

  const before = await db
    .prepare(
      "SELECT count(*) AS n FROM sqlite_master WHERE type = 'table' AND name = 'engine_profile'",
    )
    .first<{ n: number }>();
  expect(before?.n).toBe(0);

  await applyD1Migrations(db, env.TEST_MIGRATIONS);

  for (const table of ["account", "device", "room", "turn"]) {
    const row = await db.prepare(`SELECT count(*) AS n FROM ${table}`).first<{ n: number }>();
    survivingRows[table] = row?.n ?? -1;
  }
});

// Children before parents: every foreign key here is RESTRICT.
beforeEach(async () => {
  for (const table of [
    "room_ai_state_ref",
    "checkpoint",
    "persona_snapshot_extension_field",
    "persona_snapshot_head",
    "persona_snapshot",
    "engine_profile",
    "bubble",
    "turn",
    "room",
    "device",
    "account",
  ]) {
    await db.prepare(`DELETE FROM ${table}`).run();
  }
});

describe("M04 — migration order and preservation", () => {
  it("keeps the M01..M03 rows written before 0005", () => {
    expect(survivingRows).toEqual({ account: 1, device: 1, room: 1, turn: 1 });
  });

  it("records the five migrations in order, once each", async () => {
    const rows = await db
      .prepare("SELECT name FROM d1_migrations ORDER BY id")
      .all<{ name: string }>();
    expect(rows.results.map((row) => row.name)).toEqual([
      "0001_account_device.sql",
      "0002_device_account_fk.sql",
      "0003_conversation_scope.sql",
      "0004_turn_bubble_extension.sql",
      AI_STATE_MIGRATION,
    ]);
  });

  it("is a no-op when applied again", async () => {
    await applyD1Migrations(db, env.TEST_MIGRATIONS);
    const row = await db.prepare("SELECT count(*) AS n FROM d1_migrations").first<{ n: number }>();
    expect(row?.n).toBe(5);
  });

  it("adds exactly the six M04 tables and nothing from M05..M06", async () => {
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
    for (const added of [
      "engine_profile",
      "persona_snapshot",
      "persona_snapshot_head",
      "persona_snapshot_extension_field",
      "checkpoint",
      "room_ai_state_ref",
    ]) {
      expect(names).toContain(added);
    }
    for (const later of ["attachment", "operation_log", "change_log", "engine_profile_head"]) {
      expect(names).not.toContain(later);
    }
    // No table was rebuilt away and no scaffolding was left behind.
    expect(names.filter((name) => name.includes("_with_") || name.endsWith("_new"))).toEqual([]);
  });

  it("declares the documented primary key of every new table", async () => {
    const expected: Record<string, string[]> = {
      engine_profile: ["account_id", "space_id", "engine_profile_id", "profile_revision"],
      persona_snapshot: ["account_id", "space_id", "persona_snapshot_id", "snapshot_revision"],
      persona_snapshot_head: ["account_id", "space_id", "persona_snapshot_id"],
      persona_snapshot_extension_field: [
        "account_id",
        "space_id",
        "persona_snapshot_id",
        "snapshot_revision",
        "extension_key",
      ],
      checkpoint: ["account_id", "space_id", "room_id", "worldline_key", "checkpoint_id"],
      room_ai_state_ref: ["account_id", "space_id", "room_id"],
    };
    for (const [table, key] of Object.entries(expected)) {
      const info = await db.prepare(`PRAGMA table_info(${table})`).all<{
        name: string;
        pk: number;
      }>();
      const actual = info.results
        .filter((column) => column.pk > 0)
        .sort((a, b) => a.pk - b.pk)
        .map((column) => column.name);
      expect(actual).toEqual(key);
    }
  });

  it("uses RESTRICT on every new foreign key", async () => {
    for (const table of [
      "engine_profile",
      "persona_snapshot",
      "persona_snapshot_head",
      "persona_snapshot_extension_field",
      "checkpoint",
      "room_ai_state_ref",
    ]) {
      const fks = await db.prepare(`PRAGMA foreign_key_list(${table})`).all<{
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

  it("rolls back a failing migration without leaving schema or a ledger row", async () => {
    const failing: D1Migration = {
      name: "9999_intentionally_failing.sql",
      queries: [
        "CREATE TABLE scratch_should_not_survive (x TEXT NOT NULL)",
        "INSERT INTO scratch_should_not_survive (x) SELECT x FROM table_that_does_not_exist",
      ],
    };
    await expectRejected(() => applyD1Migrations(db, [...env.TEST_MIGRATIONS, failing]));
    const table = await db
      .prepare(
        "SELECT count(*) AS n FROM sqlite_master WHERE type = 'table' AND name = 'scratch_should_not_survive'",
      )
      .first<{ n: number }>();
    expect(table?.n).toBe(0);
    const ledger = await db
      .prepare("SELECT count(*) AS n FROM d1_migrations")
      .first<{ n: number }>();
    expect(ledger?.n).toBe(5);
  });
});

describe("M04 — engine_profile is an immutable revision", () => {
  it("stores a revision under an existing account", async () => {
    await insertAccount(ACCOUNT_A);
    await insertEngineProfile(ACCOUNT_A, "MAC_SPACE", ENGINE_1, 1);
    const row = await db
      .prepare("SELECT compaction_compat_tag FROM engine_profile WHERE engine_profile_id = ?")
      .bind(ENGINE_1)
      .first<{ compaction_compat_tag: string | null }>();
    // The tag is plaintext and stored exactly as given; no new format is derived.
    expect(row?.compaction_compat_tag).toBe(COMPAT_TAG);
  });

  it("returns the encrypted field byte-for-byte", async () => {
    await insertAccount(ACCOUNT_A);
    await insertEngineProfile(ACCOUNT_A, "MAC_SPACE", ENGINE_1, 1);
    const row = await db
      .prepare("SELECT mode_enc FROM engine_profile WHERE engine_profile_id = ?")
      .bind(ENGINE_1)
      .first<{ mode_enc: string | null }>();
    expect(row?.mode_enc).toBe(ENVELOPE_A);
  });

  it("rejects a profile_revision below 1, above the safe integer bound or non-integer", async () => {
    await insertAccount(ACCOUNT_A);
    for (const bad of [0, -1, MAX_SAFE + 1, 1.5]) {
      await expectRejected(() => insertEngineProfile(ACCOUNT_A, "MAC_SPACE", ENGINE_1, bad));
    }
  });

  it("rejects an orphan profile and a duplicate revision", async () => {
    await expectRejected(() => insertEngineProfile(ACCOUNT_A, "MAC_SPACE", ENGINE_1, 1));
    await insertAccount(ACCOUNT_A);
    await insertEngineProfile(ACCOUNT_A, "MAC_SPACE", ENGINE_1, 1);
    await expectRejected(() => insertEngineProfile(ACCOUNT_A, "MAC_SPACE", ENGINE_1, 1));
    // A new revision of the same profile is how a change is recorded.
    await insertEngineProfile(ACCOUNT_A, "MAC_SPACE", ENGINE_1, 2);
  });

  it("refuses every UPDATE of an existing revision", async () => {
    await insertAccount(ACCOUNT_A);
    await insertEngineProfile(ACCOUNT_A, "MAC_SPACE", ENGINE_1, 1);
    await expectRejected(() =>
      db
        .prepare("UPDATE engine_profile SET mode_enc = ? WHERE engine_profile_id = ?")
        .bind(ENVELOPE_B, ENGINE_1)
        .run(),
    );
    await expectRejected(() =>
      db
        .prepare("UPDATE engine_profile SET compaction_compat_tag = 'x' WHERE engine_profile_id = ?")
        .bind(ENGINE_1)
        .run(),
    );
    const row = await db
      .prepare("SELECT mode_enc FROM engine_profile WHERE engine_profile_id = ?")
      .bind(ENGINE_1)
      .first<{ mode_enc: string | null }>();
    expect(row?.mode_enc).toBe(ENVELOPE_A);
  });

  it("has no engine profile head table", async () => {
    const row = await db
      .prepare(
        "SELECT count(*) AS n FROM sqlite_master WHERE type = 'table' AND name LIKE 'engine%head%'",
      )
      .first<{ n: number }>();
    expect(row?.n).toBe(0);
  });
});

describe("M04 — persona_snapshot and its head", () => {
  it("stores a snapshot whose owner space matches its space", async () => {
    await seedScope();
    await insertPersonaSnapshot(ACCOUNT_A, "PHONE_SPACE", PERSONA_1, 1);
    const row = await db
      .prepare("SELECT count(*) AS n FROM persona_snapshot")
      .first<{ n: number }>();
    expect(row?.n).toBe(1);
  });

  it("rejects an owner_space_id different from space_id", async () => {
    await seedScope();
    await expectRejected(() =>
      insertPersonaSnapshot(ACCOUNT_A, "PHONE_SPACE", PERSONA_1, 1, {
        ownerSpaceId: "MAC_SPACE",
      }),
    );
  });

  it("rejects a created_by_device_id from another account", async () => {
    await seedScope(ACCOUNT_A);
    await insertAccount(ACCOUNT_B);
    await insertDevice(ACCOUNT_B, DEVICE_B);
    await expectRejected(() =>
      insertPersonaSnapshot(ACCOUNT_A, "PHONE_SPACE", PERSONA_1, 1, { deviceId: DEVICE_B }),
    );
  });

  it("rejects a snapshot_revision below 1 or above the safe bound", async () => {
    await seedScope();
    for (const bad of [0, -1, MAX_SAFE + 1]) {
      await expectRejected(() => insertPersonaSnapshot(ACCOUNT_A, "PHONE_SPACE", PERSONA_1, bad));
    }
  });

  it("refuses every UPDATE of an existing snapshot revision", async () => {
    await seedScope();
    await insertPersonaSnapshot(ACCOUNT_A, "PHONE_SPACE", PERSONA_1, 1);
    await expectRejected(() =>
      db
        .prepare("UPDATE persona_snapshot SET description_enc = ? WHERE persona_snapshot_id = ?")
        .bind(ENVELOPE_B, PERSONA_1)
        .run(),
    );
  });

  it("points the head at an exact existing revision", async () => {
    await seedScope();
    await insertPersonaSnapshot(ACCOUNT_A, "PHONE_SPACE", PERSONA_1, 1);
    await insertPersonaHead(ACCOUNT_A, "PHONE_SPACE", PERSONA_1, 1);
    // Revision 2 does not exist yet, so the head cannot point at it.
    await expectRejected(() =>
      db
        .prepare(
          `UPDATE persona_snapshot_head SET current_snapshot_revision = 2
            WHERE account_id = ? AND space_id = ? AND persona_snapshot_id = ?`,
        )
        .bind(ACCOUNT_A, "PHONE_SPACE", PERSONA_1)
        .run(),
    );
    // Once it exists, advancing the head is allowed: the head is mutable.
    await insertPersonaSnapshot(ACCOUNT_A, "PHONE_SPACE", PERSONA_1, 2);
    await db
      .prepare(
        `UPDATE persona_snapshot_head SET current_snapshot_revision = 2
          WHERE account_id = ? AND space_id = ? AND persona_snapshot_id = ?`,
      )
      .bind(ACCOUNT_A, "PHONE_SPACE", PERSONA_1)
      .run();
    const row = await db
      .prepare("SELECT current_snapshot_revision AS r FROM persona_snapshot_head")
      .first<{ r: number }>();
    expect(row?.r).toBe(2);
  });

  it("rejects a head whose snapshot does not exist or belongs elsewhere", async () => {
    await seedScope(ACCOUNT_A);
    await insertPersonaSnapshot(ACCOUNT_A, "PHONE_SPACE", PERSONA_1, 1);
    await expectRejected(() => insertPersonaHead(ACCOUNT_A, "PHONE_SPACE", PERSONA_1, 2));
    await expectRejected(() => insertPersonaHead(ACCOUNT_A, "MAC_SPACE", PERSONA_1, 1));
    await insertAccount(ACCOUNT_B);
    await expectRejected(() => insertPersonaHead(ACCOUNT_B, "PHONE_SPACE", PERSONA_1, 1));
  });

  it("carries no head_revision, server_seq or updated_at column", async () => {
    const info = await db.prepare("PRAGMA table_info(persona_snapshot_head)").all<{
      name: string;
    }>();
    expect(info.results.map((column) => column.name).sort()).toEqual([
      "account_id",
      "current_snapshot_revision",
      "persona_snapshot_id",
      "space_id",
    ]);
  });

  it("refuses to delete a snapshot revision the head still points at", async () => {
    await seedScope();
    await insertPersonaSnapshot(ACCOUNT_A, "PHONE_SPACE", PERSONA_1, 1);
    await insertPersonaHead(ACCOUNT_A, "PHONE_SPACE", PERSONA_1, 1);
    await expectRejected(() =>
      db.prepare("DELETE FROM persona_snapshot WHERE persona_snapshot_id = ?").bind(PERSONA_1).run(),
    );
  });
});

describe("M04 — persona_snapshot_extension_field", () => {
  it("stores only owner identity, key and envelope", async () => {
    const info = await db.prepare("PRAGMA table_info(persona_snapshot_extension_field)").all<{
      name: string;
    }>();
    expect(info.results.map((column) => column.name).sort()).toEqual([
      "account_id",
      "envelope_enc",
      "extension_key",
      "persona_snapshot_id",
      "snapshot_revision",
      "space_id",
    ]);
  });

  it("binds the extension to one exact snapshot revision", async () => {
    await seedScope();
    await insertPersonaSnapshot(ACCOUNT_A, "PHONE_SPACE", PERSONA_1, 1);
    await insertPersonaExtension(
      ACCOUNT_A,
      "PHONE_SPACE",
      PERSONA_1,
      1,
      "android.persona_style.sample_evidence",
      ENVELOPE_B,
    );
    const row = await db
      .prepare("SELECT envelope_enc FROM persona_snapshot_extension_field")
      .first<{ envelope_enc: string }>();
    expect(row?.envelope_enc).toBe(ENVELOPE_B);
    // Revision 2 has no row of its own, so it cannot own this key.
    await expectRejected(() =>
      insertPersonaExtension(ACCOUNT_A, "PHONE_SPACE", PERSONA_1, 2, "android.persona_style.a"),
    );
  });

  it("applies the same key grammar as the M03 extension tables", async () => {
    await seedScope();
    await insertPersonaSnapshot(ACCOUNT_A, "PHONE_SPACE", PERSONA_1, 1);
    await insertPersonaExtension(ACCOUNT_A, "PHONE_SPACE", PERSONA_1, 1, "a.b.c");
    for (const bad of [
      "Android.persona_style.a",
      "android.persona_style",
      "android.persona.style.a",
      "android..a",
      "android.persona_style.",
      "android.persona-style.a",
      "",
    ]) {
      await expectRejected(() =>
        insertPersonaExtension(ACCOUNT_A, "PHONE_SPACE", PERSONA_1, 1, bad),
      );
    }
    await expectRejected(() =>
      insertPersonaExtension(ACCOUNT_A, "PHONE_SPACE", PERSONA_1, 1, "a.b.c"),
    );
  });
});

describe("M04 — checkpoint", () => {
  it("accepts a default-worldline checkpoint in every canonical space", async () => {
    await insertAccount(ACCOUNT_A);
    await insertDevice(ACCOUNT_A, DEVICE_A);
    for (const space of ["MAC_SPACE", "PHONE_SPACE", "TABLET_SPACE"]) {
      await insertRoom(ACCOUNT_A, space, ROOM_1);
      await insertCheckpoint(ACCOUNT_A, space, ROOM_1, CHECKPOINT_1);
    }
    const row = await db.prepare("SELECT count(*) AS n FROM checkpoint").first<{ n: number }>();
    expect(row?.n).toBe(3);
  });

  it("rejects a named-worldline checkpoint outside PHONE_SPACE", async () => {
    await insertAccount(ACCOUNT_A);
    await insertDevice(ACCOUNT_A, DEVICE_A);
    for (const space of ["MAC_SPACE", "TABLET_SPACE"]) {
      await insertRoom(ACCOUNT_A, space, ROOM_1);
      await expectRejected(() =>
        insertCheckpoint(ACCOUNT_A, space, ROOM_1, CHECKPOINT_1, { worldlineId: WORLDLINE_1 }),
      );
    }
    await insertRoom(ACCOUNT_A, "PHONE_SPACE", ROOM_1);
    await insertCheckpoint(ACCOUNT_A, "PHONE_SPACE", ROOM_1, CHECKPOINT_1, {
      worldlineId: WORLDLINE_1,
    });
  });

  it("rejects an orphan checkpoint and one borrowing another account's room", async () => {
    await seedScope(ACCOUNT_A);
    await expectRejected(() => insertCheckpoint(ACCOUNT_A, "PHONE_SPACE", ROOM_2, CHECKPOINT_1));
    await insertAccount(ACCOUNT_B);
    await insertDevice(ACCOUNT_B, DEVICE_B);
    await insertRoom(ACCOUNT_B, "PHONE_SPACE", ROOM_2);
    await expectRejected(() => insertCheckpoint(ACCOUNT_A, "PHONE_SPACE", ROOM_2, CHECKPOINT_1));
  });

  it("requires the turn range to be both-null or both-non-null", async () => {
    await seedScope();
    await insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1);
    await expectRejected(() =>
      insertCheckpoint(ACCOUNT_A, "PHONE_SPACE", ROOM_1, CHECKPOINT_1, { firstTurnId: TURN_1 }),
    );
    await expectRejected(() =>
      insertCheckpoint(ACCOUNT_A, "PHONE_SPACE", ROOM_1, CHECKPOINT_1, { lastTurnId: TURN_1 }),
    );
    // A legacy digest has no range at all, and that is legal.
    await insertCheckpoint(ACCOUNT_A, "PHONE_SPACE", ROOM_1, CHECKPOINT_1);
  });

  it("binds a non-null range to turns of the very same scope", async () => {
    await seedScope();
    await insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1);
    await insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_2);
    await insertCheckpoint(ACCOUNT_A, "PHONE_SPACE", ROOM_1, CHECKPOINT_1, {
      firstTurnId: TURN_1,
      lastTurnId: TURN_2,
    });
    // Same turn UUID but in the named worldline: a different scope, so it is
    // not a legal range endpoint for a default-worldline checkpoint.
    await insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1, WORLDLINE_1);
    await expectRejected(() =>
      insertCheckpoint(ACCOUNT_A, "PHONE_SPACE", ROOM_1, CHECKPOINT_1, {
        worldlineId: WORLDLINE_1,
        firstTurnId: TURN_2,
        lastTurnId: TURN_2,
      }),
    );
  });

  it("allows a null through_server_seq and refuses a value below 1", async () => {
    await seedScope();
    await insertCheckpoint(ACCOUNT_A, "PHONE_SPACE", ROOM_1, CHECKPOINT_1, {
      throughServerSeq: null,
    });
    for (const bad of [0, -1, MAX_SAFE + 1, 1.5]) {
      await expectRejected(() =>
        insertCheckpoint(ACCOUNT_A, "PHONE_SPACE", ROOM_1, CHECKPOINT_1, {
          throughServerSeq: bad,
        }),
      );
    }
  });

  it("starts revision at 0 and refuses a negative revision", async () => {
    await seedScope();
    await insertCheckpoint(ACCOUNT_A, "PHONE_SPACE", ROOM_1, CHECKPOINT_1, { revision: 0 });
    await expectRejected(() =>
      insertCheckpoint(ACCOUNT_A, "PHONE_SPACE", ROOM_2, CHECKPOINT_1, { revision: -1 }),
    );
  });

  it("rejects an owner_space_id or device outside its own scope", async () => {
    await seedScope(ACCOUNT_A);
    await expectRejected(() =>
      insertCheckpoint(ACCOUNT_A, "PHONE_SPACE", ROOM_1, CHECKPOINT_1, {
        ownerSpaceId: "MAC_SPACE",
      }),
    );
    await insertAccount(ACCOUNT_B);
    await insertDevice(ACCOUNT_B, DEVICE_B);
    await expectRejected(() =>
      insertCheckpoint(ACCOUNT_A, "PHONE_SPACE", ROOM_1, CHECKPOINT_1, { deviceId: DEVICE_B }),
    );
  });

  it("keeps a checkpoint mutable, unlike the immutable revision tables", async () => {
    await seedScope();
    await insertCheckpoint(ACCOUNT_A, "PHONE_SPACE", ROOM_1, CHECKPOINT_1);
    await db
      .prepare("UPDATE checkpoint SET revision = 1, summary_text_enc = ? WHERE checkpoint_id = ?")
      .bind(ENVELOPE_B, CHECKPOINT_1)
      .run();
    const row = await db
      .prepare("SELECT revision FROM checkpoint WHERE checkpoint_id = ?")
      .bind(CHECKPOINT_1)
      .first<{ revision: number }>();
    expect(row?.revision).toBe(1);
  });
});

describe("M04 — room_ai_state_ref", () => {
  it("carries no revision, timestamp or server_seq of its own", async () => {
    const info = await db.prepare("PRAGMA table_info(room_ai_state_ref)").all<{ name: string }>();
    expect(info.results.map((column) => column.name).sort()).toEqual([
      "account_id",
      "engine_profile_id",
      "engine_profile_revision",
      "persona_snapshot_id",
      "persona_snapshot_revision",
      "room_id",
      "space_id",
    ]);
  });

  it("accepts both pairs null, one pair set, or both set", async () => {
    await seedScope();
    await insertEngineProfile(ACCOUNT_A, "PHONE_SPACE", ENGINE_1, 3);
    await insertPersonaSnapshot(ACCOUNT_A, "PHONE_SPACE", PERSONA_1, 2);
    await insertRoomAiStateRef(ACCOUNT_A, "PHONE_SPACE", ROOM_1, null, null);
    await db.prepare("DELETE FROM room_ai_state_ref").run();
    await insertRoomAiStateRef(ACCOUNT_A, "PHONE_SPACE", ROOM_1, [ENGINE_1, 3], null);
    await db.prepare("DELETE FROM room_ai_state_ref").run();
    await insertRoomAiStateRef(ACCOUNT_A, "PHONE_SPACE", ROOM_1, [ENGINE_1, 3], [PERSONA_1, 2]);
    const row = await db
      .prepare("SELECT count(*) AS n FROM room_ai_state_ref")
      .first<{ n: number }>();
    expect(row?.n).toBe(1);
  });

  it("rejects a half-written pair", async () => {
    await seedScope();
    await insertEngineProfile(ACCOUNT_A, "PHONE_SPACE", ENGINE_1, 3);
    await expectRejected(() =>
      db
        .prepare(
          `INSERT INTO room_ai_state_ref
             (account_id, space_id, room_id, engine_profile_id,
              engine_profile_revision, persona_snapshot_id, persona_snapshot_revision)
           VALUES (?, ?, ?, ?, NULL, NULL, NULL)`,
        )
        .bind(ACCOUNT_A, "PHONE_SPACE", ROOM_1, ENGINE_1)
        .run(),
    );
    await expectRejected(() =>
      db
        .prepare(
          `INSERT INTO room_ai_state_ref
             (account_id, space_id, room_id, engine_profile_id,
              engine_profile_revision, persona_snapshot_id, persona_snapshot_revision)
           VALUES (?, ?, ?, NULL, 3, NULL, NULL)`,
        )
        .bind(ACCOUNT_A, "PHONE_SPACE", ROOM_1)
        .run(),
    );
  });

  it("rejects a dangling or wrong-space revision reference", async () => {
    await seedScope();
    await insertEngineProfile(ACCOUNT_A, "PHONE_SPACE", ENGINE_1, 3);
    // Revision 4 does not exist.
    await expectRejected(() =>
      insertRoomAiStateRef(ACCOUNT_A, "PHONE_SPACE", ROOM_1, [ENGINE_1, 4], null),
    );
    // The profile exists in PHONE_SPACE, but this room is in MAC_SPACE.
    await insertRoom(ACCOUNT_A, "MAC_SPACE", ROOM_1);
    await expectRejected(() =>
      insertRoomAiStateRef(ACCOUNT_A, "MAC_SPACE", ROOM_1, [ENGINE_1, 3], null),
    );
  });

  it("is one row per room and refuses to outlive its room or its revision", async () => {
    await seedScope();
    await insertEngineProfile(ACCOUNT_A, "PHONE_SPACE", ENGINE_1, 3);
    await insertRoomAiStateRef(ACCOUNT_A, "PHONE_SPACE", ROOM_1, [ENGINE_1, 3], null);
    await expectRejected(() =>
      insertRoomAiStateRef(ACCOUNT_A, "PHONE_SPACE", ROOM_1, [ENGINE_1, 3], null),
    );
    await expectRejected(() =>
      db
        .prepare("DELETE FROM engine_profile WHERE engine_profile_id = ?")
        .bind(ENGINE_1)
        .run(),
    );
    await expectRejected(() =>
      db
        .prepare("DELETE FROM room WHERE account_id = ? AND space_id = ? AND room_id = ?")
        .bind(ACCOUNT_A, "PHONE_SPACE", ROOM_1)
        .run(),
    );
  });
});
