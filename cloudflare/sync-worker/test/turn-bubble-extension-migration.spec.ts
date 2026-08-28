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
// room, conversation, attachment or token, and no assertion prints a full
// identifier.
const ACCOUNT_A = "A0000000-0000-4000-8000-00000000000A";
const ACCOUNT_B = "A0000000-0000-4000-8000-00000000000B";
const DEVICE_A = "B0000000-0000-4000-8000-00000000000A";
const DEVICE_B = "B0000000-0000-4000-8000-00000000000B";
const ROOM_1 = "10000000-0000-4000-8000-000000000001";
const ROOM_2 = "10000000-0000-4000-8000-000000000002";
const WORLDLINE_1 = "20000000-0000-4000-8000-000000000001";
const TURN_1 = "30000000-0000-4000-8000-000000000001";
const TURN_2 = "30000000-0000-4000-8000-000000000002";
const MESSAGE_1 = "40000000-0000-4000-8000-000000000001";
const MESSAGE_2 = "40000000-0000-4000-8000-000000000002";
const ATTACHMENT_1 = "70000000-0000-4000-8000-000000000001";
const OPERATION_1 = "90000000-0000-4000-8000-000000000001";
const TIMESTAMP = "2026-08-28T00:00:00Z";
const TOMBSTONED_AT = "2026-08-28T12:00:00Z";

// Stand-ins for base64 field envelopes. The bytes carry no meaning: D1 never
// decodes them, it only has to hand back the exact spelling it was given.
const ENVELOPE_A = "AQEAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==";
const ENVELOPE_B = "AQECAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==";

const TURN_BUBBLE_MIGRATION = "0004_turn_bubble_extension.sql";
const MAX_BUBBLE_ORDER = 9007199254740991;

const db = env.DB;

// Row counts and one envelope read immediately after 0004 is applied. beforeEach
// truncates before every test, so survival has to be captured, not re-read.
const survivingRows: Record<string, number> = {};
let survivingGroupStateEnvelope: string | null = null;

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

type TurnOverrides = Partial<{
  worldlineId: string | null;
  worldlineKey: string;
  createdByDeviceId: string;
  canonicalTextEnc: string | null;
  isTombstoned: number;
  tombstonedAt: string | null;
  tombstoneOperationId: string | null;
}>;

async function insertTurn(
  accountId: string,
  spaceId: string,
  roomId: string,
  turnId: string,
  overrides: TurnOverrides = {},
): Promise<void> {
  const worldlineId = overrides.worldlineId === undefined ? null : overrides.worldlineId;
  await db
    .prepare(
      `INSERT INTO turn
         (account_id, space_id, room_id, worldline_id, worldline_key, turn_id,
          canonical_text_enc, heart_changes_enc, generation_profile_ref_enc,
          fallback_reason_enc, created_by_device_id, created_at, revision,
          server_seq, is_tombstoned, tombstoned_at, tombstone_operation_id)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, NULL, ?, ?, ?)`,
    )
    .bind(
      accountId,
      spaceId,
      roomId,
      worldlineId,
      overrides.worldlineKey === undefined ? (worldlineId ?? "") : overrides.worldlineKey,
      turnId,
      overrides.canonicalTextEnc === undefined ? ENVELOPE_A : overrides.canonicalTextEnc,
      ENVELOPE_B,
      ENVELOPE_A,
      null,
      overrides.createdByDeviceId ?? DEVICE_A,
      TIMESTAMP,
      overrides.isTombstoned ?? 0,
      overrides.tombstonedAt ?? null,
      overrides.tombstoneOperationId ?? null,
    )
    .run();
}

type BubbleOverrides = Partial<{
  worldlineKey: string;
  bubbleOrder: unknown;
  textEnc: string | null;
  attachmentId: string | null;
  attachmentByteSize: number | null;
  isTombstoned: number;
  tombstonedAt: string | null;
  tombstoneOperationId: string | null;
}>;

async function insertBubble(
  accountId: string,
  spaceId: string,
  roomId: string,
  turnId: string,
  messageId: string,
  overrides: BubbleOverrides = {},
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO bubble
         (account_id, space_id, room_id, worldline_key, turn_id, message_id,
          bubble_order, sender_enc, kind_enc, text_enc, speaker_ref_enc,
          reactions_enc, attachment_ref_attachment_id, attachment_ref_byte_size,
          timestamp, revision, server_seq, is_tombstoned, tombstoned_at,
          tombstone_operation_id)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, NULL, ?, ?, ?)`,
    )
    .bind(
      accountId,
      spaceId,
      roomId,
      overrides.worldlineKey ?? "",
      turnId,
      messageId,
      overrides.bubbleOrder === undefined ? 0 : overrides.bubbleOrder,
      ENVELOPE_A,
      ENVELOPE_A,
      overrides.textEnc === undefined ? ENVELOPE_B : overrides.textEnc,
      null,
      null,
      overrides.attachmentId ?? null,
      overrides.attachmentByteSize ?? null,
      TIMESTAMP,
      overrides.isTombstoned ?? 0,
      overrides.tombstonedAt ?? null,
      overrides.tombstoneOperationId ?? null,
    )
    .run();
}

async function insertRoomExtension(
  accountId: string,
  spaceId: string,
  roomId: string,
  key: string,
  envelope = ENVELOPE_A,
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO room_extension_field
         (account_id, space_id, room_id, extension_key, envelope_enc,
          revision, server_seq, updated_at)
       VALUES (?, ?, ?, ?, ?, 0, NULL, ?)`,
    )
    .bind(accountId, spaceId, roomId, key, envelope, TIMESTAMP)
    .run();
}

async function insertTurnExtension(
  accountId: string,
  spaceId: string,
  roomId: string,
  worldlineKey: string,
  turnId: string,
  key: string,
  envelope = ENVELOPE_A,
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO turn_extension_field
         (account_id, space_id, room_id, worldline_key, turn_id, extension_key,
          envelope_enc, revision, server_seq, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, 0, NULL, ?)`,
    )
    .bind(accountId, spaceId, roomId, worldlineKey, turnId, key, envelope, TIMESTAMP)
    .run();
}

async function insertBubbleExtension(
  accountId: string,
  spaceId: string,
  roomId: string,
  worldlineKey: string,
  turnId: string,
  messageId: string,
  key: string,
  envelope = ENVELOPE_A,
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO bubble_extension_field
         (account_id, space_id, room_id, worldline_key, turn_id, message_id,
          extension_key, envelope_enc, revision, server_seq, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, NULL, ?)`,
    )
    .bind(
      accountId,
      spaceId,
      roomId,
      worldlineKey,
      turnId,
      messageId,
      key,
      envelope,
      TIMESTAMP,
    )
    .run();
}

/** account + phone device + one PHONE_SPACE room, the common precondition. */
async function seedScope(accountId = ACCOUNT_A, roomId = ROOM_1): Promise<void> {
  await insertAccount(accountId);
  await insertDevice(accountId, accountId === ACCOUNT_A ? DEVICE_A : DEVICE_B);
  await insertRoom(accountId, "PHONE_SPACE", roomId);
}

beforeAll(async () => {
  // Rows written under M01+M02 before the conversation content exists. 0004
  // must not rebuild, drop or disturb any of them.
  await applyD1Migrations(db, migrationsUpTo("0003_conversation_scope.sql"));

  await insertAccount(ACCOUNT_A);
  await insertDevice(ACCOUNT_A, DEVICE_A);
  await insertRoom(ACCOUNT_A, "PHONE_SPACE", ROOM_1);
  await db
    .prepare(
      `INSERT INTO group_state
         (account_id, space_id, room_id, participants_enc,
          active_worldline_id_enc, revision, server_seq, created_at, updated_at)
       VALUES (?, 'PHONE_SPACE', ?, ?, NULL, 0, NULL, ?, ?)`,
    )
    .bind(ACCOUNT_A, ROOM_1, ENVELOPE_A, TIMESTAMP, TIMESTAMP)
    .run();
  await db
    .prepare(
      `INSERT INTO worldline
         (account_id, space_id, room_id, worldline_id, worldline_key, name_enc,
          participant_hearts_enc, revision, server_seq, created_at, updated_at)
       VALUES (?, 'PHONE_SPACE', ?, ?, ?, ?, NULL, 0, NULL, ?, ?)`,
    )
    .bind(ACCOUNT_A, ROOM_1, WORLDLINE_1, WORLDLINE_1, ENVELOPE_B, TIMESTAMP, TIMESTAMP)
    .run();

  const before = await db
    .prepare("SELECT count(*) AS n FROM sqlite_master WHERE type = 'table' AND name = 'turn'")
    .first<{ n: number }>();
  expect(before?.n).toBe(0);

  await applyD1Migrations(db, env.TEST_MIGRATIONS);

  for (const table of ["account", "device", "room", "group_state", "worldline"]) {
    const row = await db.prepare(`SELECT count(*) AS n FROM ${table}`).first<{ n: number }>();
    survivingRows[table] = row?.n ?? -1;
  }
  const envelope = await db
    .prepare("SELECT participants_enc FROM group_state WHERE account_id = ?")
    .bind(ACCOUNT_A)
    .first<{ participants_enc: string | null }>();
  survivingGroupStateEnvelope = envelope?.participants_enc ?? null;
});

describe("M03 — the M01/M02 rows survive 0004", () => {
  it("keeps the account, device, room, group_state and worldline rows", () => {
    expect(survivingRows).toEqual({
      account: 1,
      device: 1,
      room: 1,
      group_state: 1,
      worldline: 1,
    });
    // 0004 must not have rebuilt an owner table and dropped its envelope.
    expect(survivingGroupStateEnvelope).toBe(ENVELOPE_A);
  });
});

// Children first: RESTRICT means the reverse order fails.
beforeEach(async () => {
  for (const table of [
    "bubble_extension_field",
    "turn_extension_field",
    "room_extension_field",
    "bubble",
    "turn",
    "worldline",
    "group_state",
    "room",
    "device",
    "account",
  ]) {
    await db.prepare(`DELETE FROM ${table}`).run();
  }
});

describe("M03 — migration order and stability", () => {
  it("records the four migrations in order, once each", async () => {
    const rows = await db
      .prepare("SELECT name FROM d1_migrations ORDER BY id")
      .all<{ name: string }>();
    expect(rows.results.map((row) => row.name)).toEqual([
      "0001_account_device.sql",
      "0002_device_account_fk.sql",
      "0003_conversation_scope.sql",
      TURN_BUBBLE_MIGRATION,
    ]);
  });

  it("is a no-op when applied again", async () => {
    await applyD1Migrations(db, env.TEST_MIGRATIONS);
    const row = await db.prepare("SELECT count(*) AS n FROM d1_migrations").first<{ n: number }>();
    expect(row?.n).toBe(4);
  });

  it("creates exactly the M03 tables and nothing from M04..M06", async () => {
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
    expect(names).toEqual([
      "account",
      "bubble",
      "bubble_extension_field",
      "device",
      "group_state",
      "room",
      "room_extension_field",
      "turn",
      "turn_extension_field",
      "worldline",
    ]);
    for (const later of [
      "engine_profile",
      "persona_snapshot",
      "persona_snapshot_head",
      "persona_snapshot_extension_field",
      "checkpoint",
      "attachment",
      "operation_log",
      "change_log",
    ]) {
      expect(names).not.toContain(later);
    }
    // The logical family name must not exist as a physical table.
    expect(names).not.toContain("extension_field");
  });

  it("does not add account.next_server_seq, which belongs to M06", async () => {
    const info = await db.prepare("PRAGMA table_info(account)").all<{ name: string }>();
    expect(info.results.map((column) => column.name).sort()).toEqual([
      "account_id",
      "created_at",
    ]);
  });

  it("rolls back both the partial schema and the ledger row on failure", async () => {
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
    expect(ledger?.n).toBe(4);
  });
});

describe("M03 — turn identity", () => {
  it("keys the turn by scope plus turn_id", async () => {
    const info = await db.prepare("PRAGMA table_info(turn)").all<{ name: string; pk: number }>();
    const key = info.results
      .filter((column) => column.pk > 0)
      .sort((a, b) => a.pk - b.pk)
      .map((column) => column.name);
    expect(key).toEqual([
      "account_id",
      "space_id",
      "room_id",
      "worldline_key",
      "turn_id",
    ]);
  });

  it("accepts a turn in the default worldline", async () => {
    await seedScope();
    await insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1);
    const row = await db
      .prepare("SELECT worldline_id, worldline_key FROM turn WHERE turn_id = ?")
      .bind(TURN_1)
      .first<{ worldline_id: string | null; worldline_key: string }>();
    expect(row?.worldline_id).toBeNull();
    expect(row?.worldline_key).toBe("");
  });

  it("accepts a turn in a named worldline", async () => {
    await seedScope();
    await insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1, { worldlineId: WORLDLINE_1 });
    const row = await db
      .prepare("SELECT worldline_key FROM turn WHERE turn_id = ?")
      .bind(TURN_1)
      .first<{ worldline_key: string }>();
    expect(row?.worldline_key).toBe(WORLDLINE_1);
  });

  it("rejects a worldline_id that disagrees with worldline_key", async () => {
    await seedScope();
    await expectRejected(() =>
      insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1, {
        worldlineId: null,
        worldlineKey: WORLDLINE_1,
      }),
    );
    await expectRejected(() =>
      insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1, {
        worldlineId: WORLDLINE_1,
        worldlineKey: "",
      }),
    );
  });

  it("rejects a turn whose parent room does not exist", async () => {
    await seedScope();
    await expectRejected(() => insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_2, TURN_1));
  });

  it("rejects a turn that borrows another account's room", async () => {
    await seedScope(ACCOUNT_A);
    await insertAccount(ACCOUNT_B);
    await insertDevice(ACCOUNT_B, DEVICE_B);
    await insertRoom(ACCOUNT_B, "PHONE_SPACE", ROOM_2);
    await expectRejected(() =>
      insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_2, TURN_1),
    );
  });

  it("rejects a created_by_device_id from another account", async () => {
    await seedScope(ACCOUNT_A);
    await insertAccount(ACCOUNT_B);
    await insertDevice(ACCOUNT_B, DEVICE_B);
    await expectRejected(() =>
      insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1, { createdByDeviceId: DEVICE_B }),
    );
  });

  it("rejects a duplicate turn_id in the same scope", async () => {
    await seedScope();
    await insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1);
    await expectRejected(() => insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1));
  });

  it("keeps the same turn_id separate across accounts, spaces and worldlines", async () => {
    await seedScope(ACCOUNT_A);
    await insertRoom(ACCOUNT_A, "MAC_SPACE", ROOM_1);
    await insertAccount(ACCOUNT_B);
    await insertDevice(ACCOUNT_B, DEVICE_B);
    await insertRoom(ACCOUNT_B, "PHONE_SPACE", ROOM_1);

    await insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1);
    await insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1, { worldlineId: WORLDLINE_1 });
    await insertTurn(ACCOUNT_A, "MAC_SPACE", ROOM_1, TURN_1);
    await insertTurn(ACCOUNT_B, "PHONE_SPACE", ROOM_1, TURN_1, {
      createdByDeviceId: DEVICE_B,
    });

    const row = await db
      .prepare("SELECT count(*) AS n FROM turn WHERE turn_id = ?")
      .bind(TURN_1)
      .first<{ n: number }>();
    expect(row?.n).toBe(4);
  });

  it("returns every encrypted envelope byte-for-byte", async () => {
    await seedScope();
    await insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1);
    const row = await db
      .prepare(
        `SELECT canonical_text_enc, heart_changes_enc, generation_profile_ref_enc
           FROM turn WHERE turn_id = ?`,
      )
      .bind(TURN_1)
      .first<{
        canonical_text_enc: string | null;
        heart_changes_enc: string | null;
        generation_profile_ref_enc: string | null;
      }>();
    expect(row?.canonical_text_enc).toBe(ENVELOPE_A);
    expect(row?.heart_changes_enc).toBe(ENVELOPE_B);
    expect(row?.generation_profile_ref_enc).toBe(ENVELOPE_A);
  });

  it("refuses to delete a room that still has a turn", async () => {
    await seedScope();
    await insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1);
    await expectRejected(() =>
      db
        .prepare("DELETE FROM room WHERE account_id = ? AND space_id = ? AND room_id = ?")
        .bind(ACCOUNT_A, "PHONE_SPACE", ROOM_1)
        .run(),
    );
  });
});

describe("M03 — bubble identity and ordering", () => {
  it("keys the bubble by scope, turn and message", async () => {
    const info = await db.prepare("PRAGMA table_info(bubble)").all<{ name: string; pk: number }>();
    const key = info.results
      .filter((column) => column.pk > 0)
      .sort((a, b) => a.pk - b.pk)
      .map((column) => column.name);
    expect(key).toEqual([
      "account_id",
      "space_id",
      "room_id",
      "worldline_key",
      "turn_id",
      "message_id",
    ]);
  });

  it("accepts a bubble under an existing turn", async () => {
    await seedScope();
    await insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1);
    await insertBubble(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1, MESSAGE_1);
    const row = await db.prepare("SELECT count(*) AS n FROM bubble").first<{ n: number }>();
    expect(row?.n).toBe(1);
  });

  it("rejects a bubble whose parent turn does not exist", async () => {
    await seedScope();
    await expectRejected(() =>
      insertBubble(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1, MESSAGE_1),
    );
  });

  it("rejects a bubble that borrows a turn from another tenant or scope", async () => {
    await seedScope(ACCOUNT_A);
    await insertAccount(ACCOUNT_B);
    await insertDevice(ACCOUNT_B, DEVICE_B);
    await insertRoom(ACCOUNT_B, "PHONE_SPACE", ROOM_1);
    await insertTurn(ACCOUNT_B, "PHONE_SPACE", ROOM_1, TURN_1, {
      createdByDeviceId: DEVICE_B,
    });
    // The turn exists, but under ACCOUNT_B.
    await expectRejected(() =>
      insertBubble(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1, MESSAGE_1),
    );
    // And the same turn_id in another worldline of ACCOUNT_B is a different turn.
    await expectRejected(() =>
      insertBubble(ACCOUNT_B, "PHONE_SPACE", ROOM_1, TURN_1, MESSAGE_1, {
        worldlineKey: WORLDLINE_1,
      }),
    );
  });

  it("rejects a duplicate message_id anywhere in the scope", async () => {
    await seedScope();
    await insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1);
    await insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_2);
    await insertBubble(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1, MESSAGE_1, { bubbleOrder: 0 });
    // Same message id under a *different* turn of the same scope: the primary
    // key would allow it, the scope-wide unique must not.
    await expectRejected(() =>
      insertBubble(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_2, MESSAGE_1, { bubbleOrder: 1 }),
    );
  });

  it("rejects a duplicate bubble_order anywhere in the scope", async () => {
    await seedScope();
    await insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1);
    await insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_2);
    await insertBubble(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1, MESSAGE_1, { bubbleOrder: 7 });
    await expectRejected(() =>
      insertBubble(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_2, MESSAGE_2, { bubbleOrder: 7 }),
    );
  });

  it("allows the same message_id and bubble_order in a different scope", async () => {
    await seedScope(ACCOUNT_A);
    await insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1);
    await insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1, { worldlineId: WORLDLINE_1 });
    await insertBubble(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1, MESSAGE_1, { bubbleOrder: 3 });
    await insertBubble(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1, MESSAGE_1, {
      worldlineKey: WORLDLINE_1,
      bubbleOrder: 3,
    });
    const row = await db
      .prepare("SELECT count(*) AS n FROM bubble WHERE message_id = ?")
      .bind(MESSAGE_1)
      .first<{ n: number }>();
    expect(row?.n).toBe(2);
  });

  it("accepts both ends of the documented bubble_order range", async () => {
    await seedScope();
    await insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1);
    await insertBubble(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1, MESSAGE_1, { bubbleOrder: 0 });
    await insertBubble(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1, MESSAGE_2, {
      bubbleOrder: MAX_BUBBLE_ORDER,
    });
    const row = await db.prepare("SELECT count(*) AS n FROM bubble").first<{ n: number }>();
    expect(row?.n).toBe(2);
  });

  it("rejects a negative, out-of-range or non-integer bubble_order", async () => {
    await seedScope();
    await insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1);
    // A numeric string is NOT in this list: INTEGER affinity converts '3' to
    // the integer 3 before any CHECK sees it, so refusing it is the Worker
    // validator's job, not the column's.
    for (const bad of [-1, MAX_BUBBLE_ORDER + 1, 1.5, "three", null]) {
      await expectRejected(() =>
        insertBubble(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1, MESSAGE_1, { bubbleOrder: bad }),
      );
    }
  });

  it("stores the attachment reference as identity and byte size only", async () => {
    await seedScope();
    await insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1);
    await insertBubble(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1, MESSAGE_1, {
      attachmentId: ATTACHMENT_1,
      attachmentByteSize: 274146,
    });
    const info = await db.prepare("PRAGMA table_info(bubble)").all<{ name: string }>();
    const columns = info.results.map((column) => column.name);
    // Filename and MIME type are encrypted content, never plaintext columns.
    for (const forbidden of [
      "attachment_ref_file_name",
      "attachment_ref_mime_type",
      "attachment_ref_r2_object_key",
    ]) {
      expect(columns).not.toContain(forbidden);
    }
    // No FK to an attachment table: that table is M05.
    const fks = await db.prepare("PRAGMA foreign_key_list(bubble)").all<{ table: string }>();
    expect(fks.results.map((fk) => fk.table)).not.toContain("attachment");
  });

  it("rejects a half-written attachment reference", async () => {
    await seedScope();
    await insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1);
    await expectRejected(() =>
      insertBubble(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1, MESSAGE_1, {
        attachmentId: ATTACHMENT_1,
        attachmentByteSize: null,
      }),
    );
  });

  it("returns the bubble envelopes byte-for-byte", async () => {
    await seedScope();
    await insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1);
    await insertBubble(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1, MESSAGE_1);
    const row = await db
      .prepare("SELECT sender_enc, text_enc FROM bubble WHERE message_id = ?")
      .bind(MESSAGE_1)
      .first<{ sender_enc: string | null; text_enc: string | null }>();
    expect(row?.sender_enc).toBe(ENVELOPE_A);
    expect(row?.text_enc).toBe(ENVELOPE_B);
  });

  it("refuses to delete a turn that still has a bubble", async () => {
    await seedScope();
    await insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1);
    await insertBubble(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1, MESSAGE_1);
    await expectRejected(() =>
      db.prepare("DELETE FROM turn WHERE turn_id = ?").bind(TURN_1).run(),
    );
  });
});

describe("M03 — tombstone metadata", () => {
  it("rejects tombstone metadata on an active row", async () => {
    await seedScope();
    await expectRejected(() =>
      insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1, {
        isTombstoned: 0,
        tombstonedAt: TOMBSTONED_AT,
        tombstoneOperationId: OPERATION_1,
      }),
    );
    await insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1);
    await expectRejected(() =>
      insertBubble(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1, MESSAGE_1, {
        isTombstoned: 0,
        tombstonedAt: TOMBSTONED_AT,
        tombstoneOperationId: null,
      }),
    );
  });

  it("rejects a tombstoned row with missing metadata", async () => {
    await seedScope();
    await expectRejected(() =>
      insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1, {
        isTombstoned: 1,
        tombstonedAt: null,
        tombstoneOperationId: OPERATION_1,
      }),
    );
    await expectRejected(() =>
      insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1, {
        isTombstoned: 1,
        tombstonedAt: TOMBSTONED_AT,
        tombstoneOperationId: null,
      }),
    );
  });

  it("keeps a tombstoned turn and bubble occupying their identity", async () => {
    await seedScope();
    await insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1, {
      isTombstoned: 1,
      tombstonedAt: TOMBSTONED_AT,
      tombstoneOperationId: OPERATION_1,
      canonicalTextEnc: null,
    });
    await insertBubble(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1, MESSAGE_1, {
      bubbleOrder: 4,
      isTombstoned: 1,
      tombstonedAt: TOMBSTONED_AT,
      tombstoneOperationId: OPERATION_1,
      textEnc: null,
    });
    // The identity is still taken: re-creating either row must fail.
    await expectRejected(() => insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1));
    await expectRejected(() =>
      insertBubble(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1, MESSAGE_1, { bubbleOrder: 9 }),
    );
  });

  it("keeps a tombstoned bubble inside the bubble_order unique constraint", async () => {
    await seedScope();
    await insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1);
    await insertBubble(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1, MESSAGE_1, {
      bubbleOrder: 4,
      isTombstoned: 1,
      tombstonedAt: TOMBSTONED_AT,
      tombstoneOperationId: OPERATION_1,
      textEnc: null,
    });
    // A deleted bubble's order is retired for good: a new bubble may not reuse it.
    await expectRejected(() =>
      insertBubble(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1, MESSAGE_2, { bubbleOrder: 4 }),
    );
  });

  it("does not transform content when a row is written as tombstoned", async () => {
    // Clearing the ciphertext is the M06 handler's job. The DDL must not have
    // a trigger that decodes, rewrites or blanks the envelope on its own.
    await seedScope();
    await insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1, {
      isTombstoned: 1,
      tombstonedAt: TOMBSTONED_AT,
      tombstoneOperationId: OPERATION_1,
      canonicalTextEnc: ENVELOPE_A,
    });
    const row = await db
      .prepare("SELECT canonical_text_enc FROM turn WHERE turn_id = ?")
      .bind(TURN_1)
      .first<{ canonical_text_enc: string | null }>();
    expect(row?.canonical_text_enc).toBe(ENVELOPE_A);

    const triggers = await db
      .prepare("SELECT count(*) AS n FROM sqlite_master WHERE type = 'trigger'")
      .first<{ n: number }>();
    expect(triggers?.n).toBe(0);
  });
});

describe("M03 — extension tables are one per owner", () => {
  it("declares the documented primary key order for each table", async () => {
    const expected: Record<string, string[]> = {
      room_extension_field: ["account_id", "space_id", "room_id", "extension_key"],
      turn_extension_field: [
        "account_id",
        "space_id",
        "room_id",
        "worldline_key",
        "turn_id",
        "extension_key",
      ],
      bubble_extension_field: [
        "account_id",
        "space_id",
        "room_id",
        "worldline_key",
        "turn_id",
        "message_id",
        "extension_key",
      ],
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

  it("references its own owner table with a real composite foreign key", async () => {
    const expected: Record<string, { table: string; columns: string[] }> = {
      room_extension_field: {
        table: "room",
        columns: ["account_id", "space_id", "room_id"],
      },
      turn_extension_field: {
        table: "turn",
        columns: ["account_id", "space_id", "room_id", "worldline_key", "turn_id"],
      },
      bubble_extension_field: {
        table: "bubble",
        columns: [
          "account_id",
          "space_id",
          "room_id",
          "worldline_key",
          "turn_id",
          "message_id",
        ],
      },
    };
    for (const [table, owner] of Object.entries(expected)) {
      const fks = await db.prepare(`PRAGMA foreign_key_list(${table})`).all<{
        id: number;
        table: string;
        from: string;
        on_delete: string;
        on_update: string;
      }>();
      const ownerFk = fks.results.filter((fk) => fk.table === owner.table);
      expect(ownerFk.map((fk) => fk.from).sort()).toEqual([...owner.columns].sort());
      for (const fk of fks.results) {
        expect(fk.on_delete).toBe("RESTRICT");
        expect(fk.on_update).toBe("RESTRICT");
      }
    }
  });

  it("has no owner_type, owner_key or identity blob column", async () => {
    for (const table of [
      "room_extension_field",
      "turn_extension_field",
      "bubble_extension_field",
    ]) {
      const info = await db.prepare(`PRAGMA table_info(${table})`).all<{
        name: string;
        notnull: number;
      }>();
      const columns = info.results.map((column) => column.name);
      for (const forbidden of ["owner_type", "owner_key", "owner_identity", "owner_id"]) {
        expect(columns).not.toContain(forbidden);
      }
      // The envelope is required: an extension row without one is meaningless.
      expect(info.results.find((column) => column.name === "envelope_enc")?.notnull).toBe(1);
    }
  });

  it("stores an extension on each owner and keeps the envelope byte-for-byte", async () => {
    await seedScope();
    await insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1);
    await insertBubble(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1, MESSAGE_1);

    await insertRoomExtension(
      ACCOUNT_A,
      "PHONE_SPACE",
      ROOM_1,
      "android.room_profile.base_affection",
      ENVELOPE_B,
    );
    await insertTurnExtension(
      ACCOUNT_A,
      "PHONE_SPACE",
      ROOM_1,
      "",
      TURN_1,
      "android.turn.sample_evidence",
    );
    await insertBubbleExtension(
      ACCOUNT_A,
      "PHONE_SPACE",
      ROOM_1,
      "",
      TURN_1,
      MESSAGE_1,
      "android.bubble.speaker_room_id",
    );

    const room = await db
      .prepare("SELECT envelope_enc FROM room_extension_field WHERE extension_key = ?")
      .bind("android.room_profile.base_affection")
      .first<{ envelope_enc: string }>();
    expect(room?.envelope_enc).toBe(ENVELOPE_B);
    const bubble = await db
      .prepare("SELECT count(*) AS n FROM bubble_extension_field")
      .first<{ n: number }>();
    expect(bubble?.n).toBe(1);
  });

  it("keeps different keys of one owner as separate rows", async () => {
    await seedScope();
    await insertRoomExtension(ACCOUNT_A, "PHONE_SPACE", ROOM_1, "android.room_profile.a", ENVELOPE_A);
    await insertRoomExtension(ACCOUNT_A, "PHONE_SPACE", ROOM_1, "android.room_profile.b", ENVELOPE_B);
    const rows = await db
      .prepare(
        "SELECT extension_key, envelope_enc FROM room_extension_field ORDER BY extension_key",
      )
      .all<{ extension_key: string; envelope_enc: string }>();
    expect(rows.results).toEqual([
      { extension_key: "android.room_profile.a", envelope_enc: ENVELOPE_A },
      { extension_key: "android.room_profile.b", envelope_enc: ENVELOPE_B },
    ]);
  });

  it("rejects the same key twice on one owner but allows it on another", async () => {
    await seedScope();
    await insertRoom(ACCOUNT_A, "MAC_SPACE", ROOM_1);
    const key = "android.room_profile.base_affection";
    await insertRoomExtension(ACCOUNT_A, "PHONE_SPACE", ROOM_1, key);
    await expectRejected(() => insertRoomExtension(ACCOUNT_A, "PHONE_SPACE", ROOM_1, key));
    // Same key, different owner row: allowed.
    await insertRoomExtension(ACCOUNT_A, "MAC_SPACE", ROOM_1, key);
    const row = await db
      .prepare("SELECT count(*) AS n FROM room_extension_field")
      .first<{ n: number }>();
    expect(row?.n).toBe(2);
  });

  it("accepts only three lowercase dotted segments", async () => {
    await seedScope();
    for (const good of ["a.b.c", "android.room_profile.base_affection", "x1.y_2.z_3"]) {
      await insertRoomExtension(ACCOUNT_A, "PHONE_SPACE", ROOM_1, good);
    }
    for (const bad of [
      "Android.room_profile.base_affection",
      "android.room_profile.baseAffection",
      "android.room_profile",
      "android.room_profile.base.affection",
      "android..base_affection",
      ".room_profile.base_affection",
      "android.room_profile.",
      "android.room-profile.base_affection",
      "1android.room_profile.base_affection",
      "android.room_profile._base",
      "",
    ]) {
      await expectRejected(() => insertRoomExtension(ACCOUNT_A, "PHONE_SPACE", ROOM_1, bad));
    }
  });
});

describe("M03 — extension rows cannot leave their owner", () => {
  it("rejects an extension whose owner row does not exist", async () => {
    await seedScope();
    await expectRejected(() =>
      insertRoomExtension(ACCOUNT_A, "PHONE_SPACE", ROOM_2, "android.room_profile.a"),
    );
    await expectRejected(() =>
      insertTurnExtension(ACCOUNT_A, "PHONE_SPACE", ROOM_1, "", TURN_1, "android.turn.a"),
    );
    await expectRejected(() =>
      insertBubbleExtension(
        ACCOUNT_A,
        "PHONE_SPACE",
        ROOM_1,
        "",
        TURN_1,
        MESSAGE_1,
        "android.bubble.a",
      ),
    );
  });

  it("rejects an extension that borrows another account's owner", async () => {
    await seedScope(ACCOUNT_A);
    await insertAccount(ACCOUNT_B);
    await insertDevice(ACCOUNT_B, DEVICE_B);
    await insertRoom(ACCOUNT_B, "PHONE_SPACE", ROOM_2);
    await insertTurn(ACCOUNT_B, "PHONE_SPACE", ROOM_2, TURN_1, {
      createdByDeviceId: DEVICE_B,
    });
    await expectRejected(() =>
      insertRoomExtension(ACCOUNT_A, "PHONE_SPACE", ROOM_2, "android.room_profile.a"),
    );
    await expectRejected(() =>
      insertTurnExtension(ACCOUNT_A, "PHONE_SPACE", ROOM_2, "", TURN_1, "android.turn.a"),
    );
  });

  it("rejects an extension that names another space or worldline of its own account", async () => {
    await seedScope(ACCOUNT_A);
    await insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1);
    // Right room UUID, wrong space.
    await expectRejected(() =>
      insertRoomExtension(ACCOUNT_A, "MAC_SPACE", ROOM_1, "android.room_profile.a"),
    );
    // Right turn UUID, wrong worldline.
    await expectRejected(() =>
      insertTurnExtension(
        ACCOUNT_A,
        "PHONE_SPACE",
        ROOM_1,
        WORLDLINE_1,
        TURN_1,
        "android.turn.a",
      ),
    );
  });

  it("rejects a bubble extension that names the wrong turn or message", async () => {
    await seedScope();
    await insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1);
    await insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_2);
    await insertBubble(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1, MESSAGE_1);
    // The bubble lives under TURN_1, so TURN_2 is not its owner.
    await expectRejected(() =>
      insertBubbleExtension(
        ACCOUNT_A,
        "PHONE_SPACE",
        ROOM_1,
        "",
        TURN_2,
        MESSAGE_1,
        "android.bubble.a",
      ),
    );
    await expectRejected(() =>
      insertBubbleExtension(
        ACCOUNT_A,
        "PHONE_SPACE",
        ROOM_1,
        "",
        TURN_1,
        MESSAGE_2,
        "android.bubble.a",
      ),
    );
  });

  it("refuses to physically delete an owner that still has an extension", async () => {
    await seedScope();
    await insertTurn(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1);
    await insertBubble(ACCOUNT_A, "PHONE_SPACE", ROOM_1, TURN_1, MESSAGE_1);
    await insertRoomExtension(ACCOUNT_A, "PHONE_SPACE", ROOM_1, "android.room_profile.a");
    await insertTurnExtension(ACCOUNT_A, "PHONE_SPACE", ROOM_1, "", TURN_1, "android.turn.a");
    await insertBubbleExtension(
      ACCOUNT_A,
      "PHONE_SPACE",
      ROOM_1,
      "",
      TURN_1,
      MESSAGE_1,
      "android.bubble.a",
    );

    await expectRejected(() =>
      db.prepare("DELETE FROM bubble WHERE message_id = ?").bind(MESSAGE_1).run(),
    );
    await expectRejected(() =>
      db.prepare("DELETE FROM turn WHERE turn_id = ?").bind(TURN_1).run(),
    );
    await expectRejected(() =>
      db
        .prepare("DELETE FROM room WHERE account_id = ? AND space_id = ? AND room_id = ?")
        .bind(ACCOUNT_A, "PHONE_SPACE", ROOM_1)
        .run(),
    );
  });
});
