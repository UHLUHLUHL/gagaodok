import { applyD1Migrations, env } from "cloudflare:test";
import type { D1Migration } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import {
  BOOTSTRAP_ENTITY_ORDER,
  projectionKey,
  readBootstrapPage,
  readChangeProjections,
  requireProjection,
  storageKeyOfChange,
} from "../src/sync/projection";
import type { ChangeRow, EntityType } from "../src/sync/projection";

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
const OTHER_ACCOUNT = "A0000000-0000-4000-8000-00000000000B";
const DEVICE = "B0000000-0000-4000-8000-000000000001";
const ROOM = "10000000-0000-4000-8000-0000000000A1";
const ROOM_2 = "10000000-0000-4000-8000-0000000000A2";
// Worldlines are a PHONE_SPACE-only concept (migration 0003), so the named
// worldline fixture needs a room of its own there.
const PHONE = "PHONE_SPACE";
const PHONE_ROOM = "10000000-0000-4000-8000-0000000000A3";
const WORLDLINE = "20000000-0000-4000-8000-0000000000B1";
const TURN = "30000000-0000-4000-8000-0000000000C1";
const MESSAGE = "40000000-0000-4000-8000-0000000000D1";
const PROFILE = "50000000-0000-4000-8000-0000000000E1";
const SNAPSHOT = "60000000-0000-4000-8000-0000000000F1";
const CHECKPOINT = "80000000-0000-4000-8000-000000000091";
const ATTACHMENT = "70000000-0000-4000-8000-000000000081";
const MAC = "MAC_SPACE";
const TIMESTAMP = "2026-08-29T00:00:00Z";

function envelope(seed: number): string {
  const bytes = new Uint8Array(34);
  bytes[0] = 1;
  bytes[1] = 1;
  for (let index = 2; index < bytes.length; index += 1) bytes[index] = (seed + index) & 0xff;
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

/** Count how many statements a call prepares, without changing behaviour. */
function countingDb(): { db: D1Database; count: () => number } {
  let prepared = 0;
  const proxy = {
    prepare(sql: string) {
      prepared += 1;
      return db.prepare(sql);
    },
  };
  return { db: proxy as unknown as D1Database, count: () => prepared };
}

async function run(sql: string, ...values: (string | number | null)[]): Promise<void> {
  await db
    .prepare(sql)
    .bind(...values)
    .run();
}

async function seedAccount(accountId: string): Promise<void> {
  await run("INSERT INTO account (account_id, created_at) VALUES (?, ?)", accountId, TIMESTAMP);
}

async function seedRoom(
  accountId: string,
  roomId: string,
  revision = 1,
  spaceId: string = MAC,
): Promise<void> {
  await run(
    `INSERT INTO room
       (account_id, space_id, room_id, title_enc, status_message_enc, music_title_enc,
        music_artist_enc, revision, server_seq, created_at, updated_at)
     VALUES (?, ?, ?, ?, NULL, ?, NULL, ?, ?, ?, ?)`,
    accountId,
    spaceId,
    roomId,
    envelope(1),
    envelope(2),
    revision,
    10,
    TIMESTAMP,
    TIMESTAMP,
  );
}

async function seedChange(
  accountId: string,
  serverSeq: number,
  entityType: string,
  columns: Record<string, string | number | null>,
  revision: number | null = 0,
  changeKind = "upsert",
): Promise<void> {
  const names = Object.keys(columns);
  await run(
    `INSERT INTO change_log
       (account_id, server_seq, entity_type, change_kind, revision${names.map((n) => `, ${n}`).join("")})
     VALUES (?, ?, ?, ?, ?${names.map(() => ", ?").join("")})`,
    accountId,
    serverSeq,
    entityType,
    changeKind,
    revision,
    ...names.map((name) => columns[name] as string | number | null),
  );
}

beforeAll(async () => {
  await applyD1Migrations(db, env.TEST_MIGRATIONS);
});

beforeEach(async () => {
  for (const table of [
    "transaction_guard",
    "change_log",
    "operation_log",
    "bubble_extension_field",
    "bubble",
    "turn_extension_field",
    // checkpoint names turns, so it goes before them.
    "checkpoint",
    "turn",
    "worldline",
    "group_state",
    "room_extension_field",
    "room_ai_state_ref",
    "room",
    "persona_snapshot_extension_field",
    "persona_snapshot_head",
    "persona_snapshot",
    "engine_profile",
    "attachment",
    "device",
    "account",
  ]) {
    await db.prepare(`DELETE FROM ${table}`).run();
  }
  await seedAccount(ACCOUNT);
  await seedAccount(OTHER_ACCOUNT);
});

/** Seed one row of every entity, plus a change event for each. */
async function seedEveryEntity(accountId = ACCOUNT): Promise<void> {
  await run(
    `INSERT INTO device
       (account_id, device_id, space_id, platform, display_name_enc,
        linked_at, revoked_at, key_generation, token_hash)
     VALUES (?, ?, ?, 'macos', NULL, ?, NULL, 1, NULL)`,
    accountId,
    DEVICE,
    MAC,
    TIMESTAMP,
  );
  await seedRoom(accountId, ROOM);
  // group_state and worldline are PHONE_SPACE-only (migration 0003).
  await seedRoom(accountId, PHONE_ROOM, 1, PHONE);
  await run(
    `INSERT INTO group_state
       (account_id, space_id, room_id, participants_enc, active_worldline_id_enc,
        revision, server_seq, created_at, updated_at)
     VALUES (?, ?, ?, ?, NULL, 2, 11, ?, ?)`,
    accountId,
    PHONE,
    PHONE_ROOM,
    envelope(3),
    TIMESTAMP,
    TIMESTAMP,
  );
  await run(
    `INSERT INTO worldline
       (account_id, space_id, room_id, worldline_id, worldline_key, name_enc,
        participant_hearts_enc, revision, server_seq, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, NULL, 0, 12, ?, ?)`,
    accountId,
    PHONE,
    PHONE_ROOM,
    WORLDLINE,
    WORLDLINE,
    envelope(4),
    TIMESTAMP,
    TIMESTAMP,
  );
  await run(
    `INSERT INTO turn
       (account_id, space_id, room_id, worldline_id, worldline_key, turn_id,
        canonical_text_enc, heart_changes_enc, generation_profile_ref_enc, fallback_reason_enc,
        created_by_device_id, created_at, revision, server_seq, is_tombstoned,
        tombstoned_at, tombstone_operation_id)
     VALUES (?, ?, ?, NULL, '', ?, ?, NULL, NULL, NULL, ?, ?, 0, 13, 0, NULL, NULL)`,
    accountId,
    MAC,
    ROOM,
    TURN,
    envelope(5),
    DEVICE,
    TIMESTAMP,
  );
  await run(
    `INSERT INTO bubble
       (account_id, space_id, room_id, worldline_key, turn_id, message_id, bubble_order,
        sender_enc, kind_enc, text_enc, speaker_ref_enc, reactions_enc,
        attachment_ref_attachment_id, attachment_ref_byte_size, timestamp, revision,
        server_seq, is_tombstoned, tombstoned_at, tombstone_operation_id)
     VALUES (?, ?, ?, '', ?, ?, 0, ?, NULL, ?, NULL, NULL, NULL, NULL, ?, 0, 14, 0, NULL, NULL)`,
    accountId,
    MAC,
    ROOM,
    TURN,
    MESSAGE,
    envelope(6),
    envelope(7),
    TIMESTAMP,
  );
  await run(
    `INSERT INTO engine_profile
       (account_id, space_id, engine_profile_id, profile_revision, mode_enc, model_capability_enc,
        prompt_profile_id_enc, prompt_profile_version_enc, relationship_policy_enc,
        compaction_profile_id_enc, compaction_contract_fingerprint_enc, cache_policy_enc,
        repetition_policy_enc, compaction_compat_tag, server_seq)
     VALUES (?, ?, ?, 3, ?, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, ?, 15)`,
    accountId,
    MAC,
    PROFILE,
    envelope(8),
    "tag-1",
  );
  await run(
    `INSERT INTO persona_snapshot
       (account_id, space_id, persona_snapshot_id, snapshot_revision, owner_space_id,
        created_by_device_id, created_at, persona_schema_version, description_enc, samples_enc,
        style_guide_enc, is_enabled_enc, content_fingerprint_enc, server_seq)
     VALUES (?, ?, ?, 7, ?, ?, ?, 1, ?, NULL, NULL, NULL, NULL, 16)`,
    accountId,
    MAC,
    SNAPSHOT,
    MAC,
    DEVICE,
    TIMESTAMP,
    envelope(9),
  );
  await run(
    `INSERT INTO persona_snapshot_head
       (account_id, space_id, persona_snapshot_id, current_snapshot_revision)
     VALUES (?, ?, ?, 7)`,
    accountId,
    MAC,
    SNAPSHOT,
  );
  // The reference row comes after the rows it points at.
  await run(
    `INSERT INTO room_ai_state_ref
       (account_id, space_id, room_id, engine_profile_id, engine_profile_revision,
        persona_snapshot_id, persona_snapshot_revision)
     VALUES (?, ?, ?, ?, ?, ?, ?)`,
    accountId,
    MAC,
    ROOM,
    PROFILE,
    3,
    SNAPSHOT,
    7,
  );
  await run(
    `INSERT INTO checkpoint
       (account_id, space_id, room_id, worldline_id, worldline_key, checkpoint_id,
        first_turn_id, last_turn_id, through_server_seq, segments_enc, summary_text_enc,
        checkpoint_schema_version, compaction_profile_id_enc, compaction_contract_fingerprint_enc,
        compaction_compat_tag, owner_space_id, created_by_device_id, created_at, revision, server_seq)
     VALUES (?, ?, ?, NULL, '', ?, ?, ?, 9, ?, NULL, 1, NULL, NULL, NULL, ?, ?, ?, 0, 17)`,
    accountId,
    MAC,
    ROOM,
    CHECKPOINT,
    TURN,
    TURN,
    envelope(10),
    MAC,
    DEVICE,
    TIMESTAMP,
  );
  await run(
    `INSERT INTO attachment
       (account_id, attachment_id, origin_space_id, r2_object_key, kind, state,
        source_byte_size, ciphertext_byte_size, ciphertext_hash, key_generation,
        file_name_enc, mime_type_enc, wrapped_file_key_enc, created_at, server_seq)
     VALUES (?, ?, ?, ?, 'attachment', 'ready', 100, 134, ?, 1, ?, ?, ?, ?, 18)`,
    accountId,
    ATTACHMENT,
    MAC,
    `obj/C0000000-0000-4000-8000-000000000001`,
    "a".repeat(64),
    envelope(11),
    envelope(12),
    envelope(13),
    TIMESTAMP,
  );

  const events: [string, Record<string, string | number | null>, number | null][] = [
    ["room", { space_id: MAC, room_id: ROOM }, 1],
    ["group_state", { space_id: PHONE, room_id: PHONE_ROOM }, 2],
    ["worldline", { space_id: PHONE, room_id: PHONE_ROOM, worldline_key: WORLDLINE }, 0],
    ["turn", { space_id: MAC, room_id: ROOM, worldline_key: "", turn_id: TURN }, 0],
    [
      "bubble",
      { space_id: MAC, room_id: ROOM, worldline_key: "", turn_id: TURN, message_id: MESSAGE },
      0,
    ],
    ["engine_profile", { space_id: MAC, engine_profile_id: PROFILE, profile_revision: 3 }, 0],
    ["persona_snapshot", { space_id: MAC, persona_snapshot_id: SNAPSHOT, snapshot_revision: 7 }, 0],
    [
      "checkpoint",
      { space_id: MAC, room_id: ROOM, worldline_key: "", checkpoint_id: CHECKPOINT },
      0,
    ],
    ["attachment", { attachment_id: ATTACHMENT }, null],
  ];
  let seq = 1;
  for (const [entityType, columns, revision] of events) {
    await seedChange(accountId, seq, entityType, columns, revision);
    seq += 1;
  }
}

async function projectionsOf(accountId = ACCOUNT, after = 0, through = 100) {
  return await readChangeProjections(db, accountId, after, through);
}

function get(
  projections: Map<string, { projection: Record<string, unknown> }>,
  entityType: EntityType,
  key: (string | number)[],
): Record<string, unknown> {
  const found = projections.get(projectionKey(entityType, key));
  expect(found, `no projection for ${entityType}`).toBeDefined();
  return (found as { projection: Record<string, unknown> }).projection;
}

describe("the shared projection registry", () => {
  it("projects all nine entities from one page of changes", async () => {
    await seedEveryEntity();
    const projections = await projectionsOf();
    expect(projections.size).toBe(9);
    for (const entityType of BOOTSTRAP_ENTITY_ORDER) {
      expect([...projections.values()].some((p) => p.entity_type === entityType)).toBe(true);
    }
  });

  it("strips the _enc suffix and returns the envelope spelling untouched", async () => {
    await seedEveryEntity();
    const room = get(await projectionsOf(), "room", [MAC, ROOM]);
    expect(room["title"]).toBe(envelope(1));
    expect(room["music_title"]).toBe(envelope(2));
    // The storage column name never reaches the wire.
    expect(Object.keys(room)).not.toContain("title_enc");
    expect(room["status_message"]).toBeNull();
  });

  it("maps the empty worldline key to a null worldline_id and hides the key", async () => {
    await seedEveryEntity();
    const projections = await projectionsOf();

    const turn = get(projections, "turn", [MAC, ROOM, "", TURN]);
    expect(turn["worldline_id"]).toBeNull();
    const named = get(projections, "worldline", [PHONE, PHONE_ROOM, WORLDLINE]);
    expect(named["worldline_id"]).toBe(WORLDLINE);

    for (const projection of projections.values()) {
      expect(Object.keys(projection.projection)).not.toContain("worldline_key");
      expect(Object.keys(projection.identity)).not.toContain("worldline_key");
      expect(Object.keys(projection.projection)).not.toContain("account_id");
    }
  });

  it("merges the room AI state reference, nulls included", async () => {
    await seedEveryEntity();
    const room = get(await projectionsOf(), "room", [MAC, ROOM]);
    expect(room["engine_profile_id"]).toBe(PROFILE);
    expect(room["engine_profile_revision"]).toBe(3);
    expect(room["persona_snapshot_id"]).toBe(SNAPSHOT);
    expect(room["persona_snapshot_revision"]).toBe(7);

    // A room with no reference row still carries the four fields as null.
    await seedRoom(ACCOUNT, ROOM_2);
    await seedChange(ACCOUNT, 20, "room", { space_id: MAC, room_id: ROOM_2 }, 1);
    const without = get(await projectionsOf(), "room", [MAC, ROOM_2]);
    expect(without["engine_profile_id"]).toBeNull();
    expect(without["persona_snapshot_revision"]).toBeNull();
  });

  it("merges the persona snapshot head pointer", async () => {
    await seedEveryEntity();
    const snapshot = get(await projectionsOf(), "persona_snapshot", [MAC, SNAPSHOT, 7]);
    expect(snapshot["current_snapshot_revision"]).toBe(7);
    expect(snapshot["snapshot_revision"]).toBe(7);
  });

  it("returns extensions sorted by key, and an empty array when there are none", async () => {
    await seedEveryEntity();
    for (const key of ["zeta.room.late", "alpha.room.early", "middle.room.mid"]) {
      await run(
        `INSERT INTO room_extension_field
           (account_id, space_id, room_id, extension_key, envelope_enc)
         VALUES (?, ?, ?, ?, ?)`,
        ACCOUNT,
        MAC,
        ROOM,
        key,
        envelope(key.length),
      );
    }
    const projections = await projectionsOf();
    const room = get(projections, "room", [MAC, ROOM]);
    expect(room["extensions"]).toEqual([
      { key: "alpha.room.early", value: envelope("alpha.room.early".length) },
      { key: "middle.room.mid", value: envelope("middle.room.mid".length) },
      { key: "zeta.room.late", value: envelope("zeta.room.late".length) },
    ]);
    // The turn has none, and says so with an empty array rather than silence.
    expect(get(projections, "turn", [MAC, ROOM, "", TURN])["extensions"]).toEqual([]);
    // Entities without an extension table do not grow the field at all.
    for (const entityType of ["group_state", "worldline", "engine_profile", "checkpoint", "attachment"] as const) {
      const projection = [...projections.values()].find((p) => p.entity_type === entityType);
      expect(Object.keys(projection?.projection ?? {}), entityType).not.toContain("extensions");
    }
  });

  it("keeps the attachment's hash, size, state and wrapped key but never its R2 key", async () => {
    await seedEveryEntity();
    const attachment = get(await projectionsOf(), "attachment", [ATTACHMENT]);
    expect(attachment["ciphertext_hash"]).toBe("a".repeat(64));
    expect(attachment["ciphertext_byte_size"]).toBe(134);
    expect(attachment["source_byte_size"]).toBe(100);
    expect(attachment["state"]).toBe("ready");
    expect(attachment["wrapped_file_key"]).toBe(envelope(13));
    expect(attachment["file_name"]).toBe(envelope(11));
    expect(Object.keys(attachment)).not.toContain("r2_object_key");
    expect(JSON.stringify(attachment)).not.toContain("obj/");
  });

  it("preserves tombstone metadata and the null content beside it", async () => {
    await seedEveryEntity();
    await run(
      `UPDATE turn SET is_tombstoned = 1, tombstoned_at = ?, tombstone_operation_id = ?,
              canonical_text_enc = NULL WHERE account_id = ? AND turn_id = ?`,
      TIMESTAMP,
      "90000000-0000-4000-8000-000000000001",
      ACCOUNT,
      TURN,
    );
    const turn = get(await projectionsOf(), "turn", [MAC, ROOM, "", TURN]);
    expect(turn["is_tombstoned"]).toBe(1);
    expect(turn["tombstoned_at"]).toBe(TIMESTAMP);
    expect(turn["tombstone_operation_id"]).toBe("90000000-0000-4000-8000-000000000001");
    // The cleared content is null, not missing: a client must be able to apply it.
    expect(turn).toHaveProperty("canonical_text");
    expect(turn["canonical_text"]).toBeNull();
  });

  it("never crosses accounts", async () => {
    await seedEveryEntity(ACCOUNT);
    await seedEveryEntity(OTHER_ACCOUNT);
    const mine = await projectionsOf(ACCOUNT);
    expect(mine.size).toBe(9);
    for (const projection of mine.values()) {
      expect(JSON.stringify(projection)).not.toContain(OTHER_ACCOUNT);
    }
    const theirs = await projectionsOf(OTHER_ACCOUNT);
    expect(theirs.size).toBe(9);
  });

  it("reads a repeated identity once, however many times the page changed it", async () => {
    await seedRoom(ACCOUNT, ROOM);
    for (let seq = 1; seq <= 6; seq += 1) {
      await seedChange(ACCOUNT, seq, "room", { space_id: MAC, room_id: ROOM }, seq);
    }
    const counting = countingDb();
    const projections = await readChangeProjections(counting.db, ACCOUNT, 0, 6);
    // One entry, not six, and the statement count does not grow with the page.
    expect(projections.size).toBe(1);
    expect(counting.count()).toBeLessThanOrEqual(25);
  });

  it("stays inside the statement budget for a 500-change page", async () => {
    await seedEveryEntity();
    // 500 bubbles in one turn, each with its own change event.
    const statements: D1PreparedStatement[] = [];
    for (let index = 0; index < 500; index += 1) {
      // A prefix of its own, so a generated id cannot collide with MESSAGE.
      const messageId = `41000000-0000-4000-8000-${index.toString(16).toUpperCase().padStart(12, "0")}`;
      statements.push(
        db
          .prepare(
            `INSERT INTO bubble
               (account_id, space_id, room_id, worldline_key, turn_id, message_id, bubble_order,
                sender_enc, kind_enc, text_enc, speaker_ref_enc, reactions_enc,
                attachment_ref_attachment_id, attachment_ref_byte_size, timestamp, revision,
                server_seq, is_tombstoned, tombstoned_at, tombstone_operation_id)
             VALUES (?, ?, ?, '', ?, ?, ?, NULL, NULL, NULL, NULL, NULL, NULL, NULL, ?, 0, ?, 0, NULL, NULL)`,
          )
          .bind(ACCOUNT, MAC, ROOM, TURN, messageId, index + 1, TIMESTAMP, 100 + index),
      );
      statements.push(
        db
          .prepare(
            `INSERT INTO change_log
               (account_id, server_seq, entity_type, change_kind, revision,
                space_id, room_id, worldline_key, turn_id, message_id)
             VALUES (?, ?, 'bubble', 'upsert', 0, ?, ?, '', ?, ?)`,
          )
          .bind(ACCOUNT, 100 + index, MAC, ROOM, TURN, messageId),
      );
    }
    await db.batch(statements);

    const counting = countingDb();
    const projections = await readChangeProjections(counting.db, ACCOUNT, 99, 599);

    expect(projections.size).toBe(500);
    // Nine owners plus their extension, reference and head reads — a fixed
    // number of statements, not one per item.
    expect(counting.count()).toBeLessThanOrEqual(25);
  });
});

describe("change identity", () => {
  it("reads the storage key of every entity's change row", async () => {
    await seedEveryEntity();
    const rows = (
      await db.prepare("SELECT * FROM change_log ORDER BY server_seq").all<ChangeRow>()
    ).results;
    const keys = rows.map((row) => [row.entity_type, ...storageKeyOfChange(row)]);
    expect(keys).toEqual([
      ["room", MAC, ROOM],
      ["group_state", PHONE, PHONE_ROOM],
      ["worldline", PHONE, PHONE_ROOM, WORLDLINE],
      ["turn", MAC, ROOM, "", TURN],
      ["bubble", MAC, ROOM, "", TURN, MESSAGE],
      ["engine_profile", MAC, PROFILE, 3],
      ["persona_snapshot", MAC, SNAPSHOT, 7],
      ["checkpoint", MAC, ROOM, "", CHECKPOINT],
      ["attachment", ATTACHMENT],
    ]);
  });

  it("refuses to infer a delete when a projection is missing", async () => {
    await seedEveryEntity();
    // A checkpoint is referenced by nothing, so it can leave a change row
    // behind with no current projection.
    await run("DELETE FROM checkpoint WHERE account_id = ? AND checkpoint_id = ?", ACCOUNT, CHECKPOINT);
    const projections = await projectionsOf();
    let caught: unknown;
    try {
      requireProjection(projections, "checkpoint", [MAC, ROOM, "", CHECKPOINT]);
    } catch (error) {
      caught = error;
    }
    expect((caught as { code?: string })?.code).toBe("STORAGE_UNAVAILABLE");
    expect((caught as { retryable?: boolean })?.retryable).toBe(true);
  });
});

describe("bootstrap pages", () => {
  it("returns owner rows in canonical key order with the same projection shape", async () => {
    await seedEveryEntity();
    const page = await readBootstrapPage(db, ACCOUNT, "room", null, 10);
    // MAC_SPACE sorts before PHONE_SPACE, so the two fixture rooms come back
    // in the order the cursor will page them.
    expect(page.items.map((item) => item.identity)).toEqual([
      { space_id: MAC, room_id: ROOM },
      { space_id: PHONE, room_id: PHONE_ROOM },
    ]);
    expect(page.items[0]?.projection["title"]).toBe(envelope(1));
    expect(page.items[0]?.projection["engine_profile_id"]).toBe(PROFILE);
    expect(page.lastKey).toEqual([PHONE, PHONE_ROOM]);

    // The change path and the bootstrap path agree, field for field.
    const viaChanges = get(await projectionsOf(), "room", [MAC, ROOM]);
    expect(page.items[0]?.projection).toEqual(viaChanges);
  });

  it("pages a composite key without repeating or skipping a row", async () => {
    await seedRoom(ACCOUNT, ROOM);
    await seedRoom(ACCOUNT, ROOM_2);
    const first = await readBootstrapPage(db, ACCOUNT, "room", null, 1);
    expect(first.items.map((item) => item.identity["room_id"])).toEqual([ROOM]);
    const second = await readBootstrapPage(db, ACCOUNT, "room", first.lastKey, 1);
    expect(second.items.map((item) => item.identity["room_id"])).toEqual([ROOM_2]);
    const third = await readBootstrapPage(db, ACCOUNT, "room", second.lastKey, 1);
    expect(third.items).toEqual([]);
    expect(third.lastKey).toBeNull();
  });

  it("carries extensions and the head pointer into a bootstrap page", async () => {
    await seedEveryEntity();
    await run(
      `INSERT INTO persona_snapshot_extension_field
         (account_id, space_id, persona_snapshot_id, snapshot_revision, extension_key, envelope_enc)
       VALUES (?, ?, ?, 7, ?, ?)`,
      ACCOUNT,
      MAC,
      SNAPSHOT,
      "vendor.persona.tone",
      envelope(21),
    );
    const page = await readBootstrapPage(db, ACCOUNT, "persona_snapshot", null, 10);
    expect(page.items[0]?.projection["current_snapshot_revision"]).toBe(7);
    expect(page.items[0]?.projection["extensions"]).toEqual([
      { key: "vendor.persona.tone", value: envelope(21) },
    ]);
  });

  it("never returns another account's rows", async () => {
    await seedEveryEntity(OTHER_ACCOUNT);
    for (const entityType of BOOTSTRAP_ENTITY_ORDER) {
      const page = await readBootstrapPage(db, ACCOUNT, entityType, null, 500);
      expect(page.items, entityType).toEqual([]);
    }
  });

  it("stays inside the statement budget for a full page", async () => {
    await seedEveryEntity();
    const counting = countingDb();
    for (const entityType of BOOTSTRAP_ENTITY_ORDER) {
      await readBootstrapPage(counting.db, ACCOUNT, entityType, null, 500);
    }
    // Nine owner reads plus the extension, reference and head reads they need.
    expect(counting.count()).toBeLessThanOrEqual(25);
  });
});
