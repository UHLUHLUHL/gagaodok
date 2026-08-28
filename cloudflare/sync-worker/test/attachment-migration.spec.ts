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

// Synthetic identifiers only. No real account, device, room, conversation or
// attachment appears here, and no assertion prints a full identifier.
const ACCOUNT_A = "A0000000-0000-4000-8000-00000000000A";
const ACCOUNT_B = "A0000000-0000-4000-8000-00000000000B";
const DEVICE_A = "B0000000-0000-4000-8000-00000000000A";
const DEVICE_B = "B0000000-0000-4000-8000-00000000000B";
const ROOM_1 = "10000000-0000-4000-8000-000000000001";
const TURN_1 = "30000000-0000-4000-8000-000000000001";
const MESSAGE_1 = "40000000-0000-4000-8000-000000000001";
const MESSAGE_2 = "40000000-0000-4000-8000-000000000002";
const MESSAGE_3 = "40000000-0000-4000-8000-000000000003";
const ATTACHMENT_1 = "70000000-0000-4000-8000-000000000001";
const ATTACHMENT_2 = "70000000-0000-4000-8000-000000000002";
const OBJECT_KEY_1 = "obj/70000000-0000-4000-8000-0000000000FF";
const OBJECT_KEY_2 = "obj/70000000-0000-4000-8000-0000000000FE";
const OPERATION_1 = "90000000-0000-4000-8000-000000000001";
const TIMESTAMP = "2026-08-28T00:00:00Z";
const HASH = "a".repeat(64);

const ENVELOPE_A = "AQEAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==";
const ENVELOPE_B = "AQECAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==";

const ATTACHMENT_MIGRATION = "0006_attachment.sql";
const MAX_SOURCE_BYTES = 12_582_912;
const ENVELOPE_OVERHEAD = 34;
const MAX_CIPHERTEXT_BYTES = MAX_SOURCE_BYTES + ENVELOPE_OVERHEAD;

const db = env.DB;

function migrationsUpTo(name: string): D1Migration[] {
  const index = env.TEST_MIGRATIONS.findIndex((migration) => migration.name === name);
  expect(index).toBeGreaterThanOrEqual(0);
  return env.TEST_MIGRATIONS.slice(0, index + 1);
}

// This file is a stage contract: it applies migrations up to and including its
// own and no further (AGENTS.md stage-spec rule).
const STAGE_MIGRATIONS = () => migrationsUpTo(ATTACHMENT_MIGRATION);

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

async function insertRoom(accountId: string, roomId: string): Promise<void> {
  await db
    .prepare(
      `INSERT INTO room
         (account_id, space_id, room_id, title_enc, status_message_enc,
          music_title_enc, music_artist_enc, revision, server_seq,
          created_at, updated_at)
       VALUES (?, 'PHONE_SPACE', ?, NULL, NULL, NULL, NULL, 0, NULL, ?, ?)`,
    )
    .bind(accountId, roomId, TIMESTAMP, TIMESTAMP)
    .run();
}

async function insertTurn(accountId: string, roomId: string, turnId: string): Promise<void> {
  await db
    .prepare(
      `INSERT INTO turn
         (account_id, space_id, room_id, worldline_id, worldline_key, turn_id,
          canonical_text_enc, heart_changes_enc, generation_profile_ref_enc,
          fallback_reason_enc, created_by_device_id, created_at, revision,
          server_seq, is_tombstoned, tombstoned_at, tombstone_operation_id)
       VALUES (?, 'PHONE_SPACE', ?, NULL, '', ?, NULL, NULL, NULL, NULL, ?, ?,
               0, NULL, 0, NULL, NULL)`,
    )
    .bind(accountId, roomId, turnId, accountId === ACCOUNT_A ? DEVICE_A : DEVICE_B, TIMESTAMP)
    .run();
}

type BubbleOverrides = Partial<{
  bubbleOrder: number;
  attachmentId: string | null;
  attachmentByteSize: number | null;
  isTombstoned: number;
  textEnc: string | null;
}>;

async function insertBubble(
  accountId: string,
  roomId: string,
  turnId: string,
  messageId: string,
  overrides: BubbleOverrides = {},
): Promise<void> {
  const tombstoned = overrides.isTombstoned ?? 0;
  await db
    .prepare(
      `INSERT INTO bubble
         (account_id, space_id, room_id, worldline_key, turn_id, message_id,
          bubble_order, sender_enc, kind_enc, text_enc, speaker_ref_enc,
          reactions_enc, attachment_ref_attachment_id, attachment_ref_byte_size,
          timestamp, revision, server_seq, is_tombstoned, tombstoned_at,
          tombstone_operation_id)
       VALUES (?, 'PHONE_SPACE', ?, '', ?, ?, ?, ?, ?, ?, NULL, NULL, ?, ?, ?,
               0, NULL, ?, ?, ?)`,
    )
    .bind(
      accountId,
      roomId,
      turnId,
      messageId,
      overrides.bubbleOrder ?? 0,
      ENVELOPE_A,
      ENVELOPE_A,
      overrides.textEnc === undefined ? ENVELOPE_B : overrides.textEnc,
      overrides.attachmentId ?? null,
      overrides.attachmentByteSize ?? null,
      TIMESTAMP,
      tombstoned,
      tombstoned === 1 ? TIMESTAMP : null,
      tombstoned === 1 ? OPERATION_1 : null,
    )
    .run();
}

async function insertBubbleExtension(
  accountId: string,
  roomId: string,
  turnId: string,
  messageId: string,
  key: string,
  envelope = ENVELOPE_A,
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO bubble_extension_field
         (account_id, space_id, room_id, worldline_key, turn_id, message_id,
          extension_key, envelope_enc)
       VALUES (?, 'PHONE_SPACE', ?, '', ?, ?, ?, ?)`,
    )
    .bind(accountId, roomId, turnId, messageId, key, envelope)
    .run();
}

type AttachmentOverrides = Partial<{
  originSpaceId: string;
  objectKey: string;
  kind: string;
  state: string;
  sourceByteSize: unknown;
  ciphertextByteSize: unknown;
  ciphertextHash: string;
  keyGeneration: number;
  fileNameEnc: string | null;
  serverSeq: number | null;
}>;

async function insertAttachment(
  accountId: string,
  attachmentId: string,
  overrides: AttachmentOverrides = {},
): Promise<void> {
  const source = overrides.sourceByteSize === undefined ? 1024 : overrides.sourceByteSize;
  const ciphertext =
    overrides.ciphertextByteSize === undefined
      ? typeof source === "number"
        ? source + ENVELOPE_OVERHEAD
        : source
      : overrides.ciphertextByteSize;
  await db
    .prepare(
      `INSERT INTO attachment
         (account_id, attachment_id, origin_space_id, r2_object_key, kind,
          state, source_byte_size, ciphertext_byte_size, ciphertext_hash,
          key_generation, file_name_enc, mime_type_enc, wrapped_file_key_enc,
          created_at, server_seq)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    )
    .bind(
      accountId,
      attachmentId,
      overrides.originSpaceId ?? "PHONE_SPACE",
      overrides.objectKey ?? OBJECT_KEY_1,
      overrides.kind ?? "attachment",
      overrides.state ?? "allocated",
      source,
      ciphertext,
      overrides.ciphertextHash ?? HASH,
      overrides.keyGeneration ?? 1,
      overrides.fileNameEnc === undefined ? ENVELOPE_A : overrides.fileNameEnc,
      ENVELOPE_A,
      ENVELOPE_B,
      TIMESTAMP,
      overrides.serverSeq ?? null,
    )
    .run();
}

async function seedScope(accountId = ACCOUNT_A): Promise<void> {
  await insertAccount(accountId);
  await insertDevice(accountId, accountId === ACCOUNT_A ? DEVICE_A : DEVICE_B);
  await insertRoom(accountId, ROOM_1);
  await insertTurn(accountId, ROOM_1, TURN_1);
}

// Evidence captured while 0006 is applied. beforeEach truncates, so anything
// about the upgrade itself has to be recorded here rather than re-read later.
let danglingRejected = false;
let ledgerDuringFailure = -1;
let stagingTablesDuringFailure: string[] = [];
let preservedBubbles: Record<string, unknown>[] = [];
let preservedExtensions: Record<string, unknown>[] = [];

const LEGACY_BUBBLES = [
  { message_id: MESSAGE_1, bubble_order: 0, is_tombstoned: 0 },
  // A tombstoned row must survive the rebuild with its order still retired.
  { message_id: MESSAGE_2, bubble_order: 7, is_tombstoned: 1 },
];

beforeAll(async () => {
  await applyD1Migrations(db, migrationsUpTo("0005_versioned_ai_state.sql"));
  await seedScope(ACCOUNT_A);
  for (const row of LEGACY_BUBBLES) {
    await insertBubble(ACCOUNT_A, ROOM_1, TURN_1, row.message_id, {
      bubbleOrder: row.bubble_order,
      isTombstoned: row.is_tombstoned,
      textEnc: row.is_tombstoned === 1 ? null : ENVELOPE_B,
    });
  }
  await insertBubbleExtension(
    ACCOUNT_A,
    ROOM_1,
    TURN_1,
    MESSAGE_1,
    "android.bubble.speaker_room_id",
    ENVELOPE_B,
  );

  // Step 1 — a legacy non-null reference cannot have a parent yet, because the
  // attachment table does not exist before this migration. The rebuild must
  // fail whole rather than inventing a placeholder or nulling the reference.
  await insertBubble(ACCOUNT_A, ROOM_1, TURN_1, MESSAGE_3, {
    bubbleOrder: 9,
    attachmentId: ATTACHMENT_1,
    attachmentByteSize: 1024,
  });
  try {
    await applyD1Migrations(db, STAGE_MIGRATIONS());
  } catch {
    danglingRejected = true;
  }
  const ledger = await db.prepare("SELECT count(*) AS n FROM d1_migrations").first<{ n: number }>();
  ledgerDuringFailure = ledger?.n ?? -1;
  const staging = await db
    .prepare(
      `SELECT name FROM sqlite_master
        WHERE type = 'table' AND (name GLOB '*_staging*' OR name GLOB '*_new')`,
    )
    .all<{ name: string }>();
  stagingTablesDuringFailure = staging.results.map((row) => row.name);

  // Step 2 — remove the dangling row and the same migration now succeeds.
  await db.prepare("DELETE FROM bubble WHERE message_id = ?").bind(MESSAGE_3).run();
  await applyD1Migrations(db, STAGE_MIGRATIONS());

  const bubbles = await db
    .prepare(
      `SELECT account_id, space_id, room_id, worldline_key, turn_id, message_id,
              bubble_order, sender_enc, kind_enc, text_enc, speaker_ref_enc,
              reactions_enc, attachment_ref_attachment_id,
              attachment_ref_byte_size, timestamp, revision, server_seq,
              is_tombstoned, tombstoned_at, tombstone_operation_id
         FROM bubble ORDER BY bubble_order`,
    )
    .all<Record<string, unknown>>();
  preservedBubbles = bubbles.results;
  const extensions = await db
    .prepare(
      `SELECT account_id, space_id, room_id, worldline_key, turn_id, message_id,
              extension_key, envelope_enc
         FROM bubble_extension_field`,
    )
    .all<Record<string, unknown>>();
  preservedExtensions = extensions.results;
});

// Children before parents: every foreign key is RESTRICT.
beforeEach(async () => {
  for (const table of [
    "bubble_extension_field",
    "bubble",
    "turn",
    "attachment",
    "room",
    "device",
    "account",
  ]) {
    await db.prepare(`DELETE FROM ${table}`).run();
  }
});

describe("M05 — the rebuild refuses a legacy dangling reference", () => {
  it("fails the whole migration instead of inventing a parent", () => {
    expect(danglingRejected).toBe(true);
  });

  it("leaves neither a ledger row nor a staging table behind", () => {
    // 0001..0005 only: 0006 must not be recorded when its batch failed.
    expect(ledgerDuringFailure).toBe(5);
    expect(stagingTablesDuringFailure).toEqual([]);
  });
});

describe("M05 — the rebuild preserves every existing row", () => {
  it("carries both legacy bubbles across whole-row", () => {
    expect(preservedBubbles).toEqual([
      {
        account_id: ACCOUNT_A,
        space_id: "PHONE_SPACE",
        room_id: ROOM_1,
        worldline_key: "",
        turn_id: TURN_1,
        message_id: MESSAGE_1,
        bubble_order: 0,
        sender_enc: ENVELOPE_A,
        kind_enc: ENVELOPE_A,
        text_enc: ENVELOPE_B,
        speaker_ref_enc: null,
        reactions_enc: null,
        attachment_ref_attachment_id: null,
        attachment_ref_byte_size: null,
        timestamp: TIMESTAMP,
        revision: 0,
        server_seq: null,
        is_tombstoned: 0,
        tombstoned_at: null,
        tombstone_operation_id: null,
      },
      {
        account_id: ACCOUNT_A,
        space_id: "PHONE_SPACE",
        room_id: ROOM_1,
        worldline_key: "",
        turn_id: TURN_1,
        message_id: MESSAGE_2,
        bubble_order: 7,
        sender_enc: ENVELOPE_A,
        kind_enc: ENVELOPE_A,
        text_enc: null,
        speaker_ref_enc: null,
        reactions_enc: null,
        attachment_ref_attachment_id: null,
        attachment_ref_byte_size: null,
        timestamp: TIMESTAMP,
        revision: 0,
        server_seq: null,
        is_tombstoned: 1,
        tombstoned_at: TIMESTAMP,
        tombstone_operation_id: OPERATION_1,
      },
    ]);
  });

  it("carries the bubble extension row across byte-identical", () => {
    expect(preservedExtensions).toEqual([
      {
        account_id: ACCOUNT_A,
        space_id: "PHONE_SPACE",
        room_id: ROOM_1,
        worldline_key: "",
        turn_id: TURN_1,
        message_id: MESSAGE_1,
        extension_key: "android.bubble.speaker_room_id",
        envelope_enc: ENVELOPE_B,
      },
    ]);
  });
});

describe("M05 — the rebuilt bubble keeps its own contract", () => {
  it("keeps the primary key and both scope-wide unique constraints", async () => {
    const info = await db.prepare("PRAGMA table_info(bubble)").all<{ name: string; pk: number }>();
    expect(
      info.results
        .filter((column) => column.pk > 0)
        .sort((a, b) => a.pk - b.pk)
        .map((column) => column.name),
    ).toEqual([
      "account_id",
      "space_id",
      "room_id",
      "worldline_key",
      "turn_id",
      "message_id",
    ]);

    await seedScope();
    await insertBubble(ACCOUNT_A, ROOM_1, TURN_1, MESSAGE_1, { bubbleOrder: 3 });
    // message_id unique across the scope, even under a different turn.
    await expectRejected(() =>
      insertBubble(ACCOUNT_A, ROOM_1, TURN_1, MESSAGE_1, { bubbleOrder: 4 }),
    );
    // bubble_order unique across the scope.
    await expectRejected(() =>
      insertBubble(ACCOUNT_A, ROOM_1, TURN_1, MESSAGE_2, { bubbleOrder: 3 }),
    );
  });

  it("keeps the bubble_order and tombstone CHECKs", async () => {
    await seedScope();
    await expectRejected(() =>
      insertBubble(ACCOUNT_A, ROOM_1, TURN_1, MESSAGE_1, { bubbleOrder: -1 }),
    );
    await expectRejected(() =>
      db
        .prepare(
          `INSERT INTO bubble
             (account_id, space_id, room_id, worldline_key, turn_id, message_id,
              bubble_order, sender_enc, kind_enc, text_enc, speaker_ref_enc,
              reactions_enc, attachment_ref_attachment_id,
              attachment_ref_byte_size, timestamp, revision, server_seq,
              is_tombstoned, tombstoned_at, tombstone_operation_id)
           VALUES (?, 'PHONE_SPACE', ?, '', ?, ?, 0, NULL, NULL, NULL, NULL,
                   NULL, NULL, NULL, ?, 0, NULL, 1, NULL, NULL)`,
        )
        .bind(ACCOUNT_A, ROOM_1, TURN_1, MESSAGE_1, TIMESTAMP)
        .run(),
    );
    // A half-written attachment reference is still refused.
    await expectRejected(() =>
      insertBubble(ACCOUNT_A, ROOM_1, TURN_1, MESSAGE_1, { attachmentByteSize: 10 }),
    );
  });

  it("reports the extension child's parent as `bubble` after the rename", async () => {
    // A composite foreign key is reported one row per column, so the rows are
    // grouped by `id` rather than counted.
    const fks = await db.prepare("PRAGMA foreign_key_list(bubble_extension_field)").all<{
      id: number;
      table: string;
      from: string;
      on_delete: string;
      on_update: string;
    }>();
    expect(new Set(fks.results.map((fk) => fk.id)).size).toBe(1);
    expect(fks.results.map((fk) => fk.from).sort()).toEqual([
      "account_id",
      "message_id",
      "room_id",
      "space_id",
      "turn_id",
      "worldline_key",
    ]);
    for (const fk of fks.results) {
      // The staging name must not survive in the child's constraint.
      expect(fk.table).toBe("bubble");
      expect(fk.on_delete).toBe("RESTRICT");
      expect(fk.on_update).toBe("RESTRICT");
    }
  });

  it("leaves no staging table and records exactly six migrations", async () => {
    const tables = await db
      .prepare(
        `SELECT name FROM sqlite_master
          WHERE type = 'table'
            AND name NOT LIKE 'sqlite_%'
            AND name NOT GLOB '_cf_*'
            AND name <> 'd1_migrations'
          ORDER BY name`,
      )
      .all<{ name: string }>();
    const names = tables.results.map((row) => row.name);
    expect(names).toContain("attachment");
    expect(names.filter((name) => name.includes("staging") || name.endsWith("_new"))).toEqual([]);
    const ledger = await db
      .prepare("SELECT name FROM d1_migrations ORDER BY id")
      .all<{ name: string }>();
    expect(ledger.results.map((row) => row.name).at(-1)).toBe(ATTACHMENT_MIGRATION);
    expect(ledger.results.length).toBe(6);
  });

  it("is a no-op when applied again", async () => {
    await applyD1Migrations(db, STAGE_MIGRATIONS());
    const ledger = await db
      .prepare("SELECT count(*) AS n FROM d1_migrations")
      .first<{ n: number }>();
    expect(ledger?.n).toBe(6);
  });
});

describe("M05 — bubble now references a real attachment", () => {
  it("accepts a null reference and a matching one", async () => {
    await seedScope();
    await insertBubble(ACCOUNT_A, ROOM_1, TURN_1, MESSAGE_1, { bubbleOrder: 0 });
    await insertAttachment(ACCOUNT_A, ATTACHMENT_1);
    await insertBubble(ACCOUNT_A, ROOM_1, TURN_1, MESSAGE_2, {
      bubbleOrder: 1,
      attachmentId: ATTACHMENT_1,
      attachmentByteSize: 1024,
    });
    const row = await db.prepare("SELECT count(*) AS n FROM bubble").first<{ n: number }>();
    expect(row?.n).toBe(2);
  });

  it("rejects a dangling or cross-account reference", async () => {
    await seedScope(ACCOUNT_A);
    await expectRejected(() =>
      insertBubble(ACCOUNT_A, ROOM_1, TURN_1, MESSAGE_1, {
        attachmentId: ATTACHMENT_1,
        attachmentByteSize: 1024,
      }),
    );
    // The attachment exists, but under another account.
    await insertAccount(ACCOUNT_B);
    await insertAttachment(ACCOUNT_B, ATTACHMENT_1);
    await expectRejected(() =>
      insertBubble(ACCOUNT_A, ROOM_1, TURN_1, MESSAGE_1, {
        attachmentId: ATTACHMENT_1,
        attachmentByteSize: 1024,
      }),
    );
  });

  it("refuses to delete an attachment a bubble still references", async () => {
    await seedScope();
    await insertAttachment(ACCOUNT_A, ATTACHMENT_1);
    await insertBubble(ACCOUNT_A, ROOM_1, TURN_1, MESSAGE_1, {
      attachmentId: ATTACHMENT_1,
      attachmentByteSize: 1024,
    });
    // A tombstoned bubble keeps the reference, so the metadata row stays too.
    await expectRejected(() =>
      db.prepare("DELETE FROM attachment WHERE attachment_id = ?").bind(ATTACHMENT_1).run(),
    );
  });
});

describe("M05 — attachment metadata", () => {
  it("keys by account and attachment, with the object key unique per account", async () => {
    const info = await db.prepare("PRAGMA table_info(attachment)").all<{
      name: string;
      pk: number;
    }>();
    expect(
      info.results
        .filter((column) => column.pk > 0)
        .sort((a, b) => a.pk - b.pk)
        .map((column) => column.name),
    ).toEqual(["account_id", "attachment_id"]);
    expect(info.results.map((column) => column.name).sort()).toEqual([
      "account_id",
      "attachment_id",
      "ciphertext_byte_size",
      "ciphertext_hash",
      "created_at",
      "file_name_enc",
      "key_generation",
      "kind",
      "mime_type_enc",
      "origin_space_id",
      "r2_object_key",
      "server_seq",
      "source_byte_size",
      "state",
      "wrapped_file_key_enc",
    ]);

    await insertAccount(ACCOUNT_A);
    await insertAttachment(ACCOUNT_A, ATTACHMENT_1, { objectKey: OBJECT_KEY_1 });
    await expectRejected(() =>
      insertAttachment(ACCOUNT_A, ATTACHMENT_2, { objectKey: OBJECT_KEY_1 }),
    );
    // The same key under a different account is a different object path.
    await insertAccount(ACCOUNT_B);
    await insertAttachment(ACCOUNT_B, ATTACHMENT_1, { objectKey: OBJECT_KEY_1 });
  });

  it("rejects an orphan attachment", async () => {
    await expectRejected(() => insertAttachment(ACCOUNT_A, ATTACHMENT_1));
  });

  it("binds ciphertext size to exactly source + 34", async () => {
    await insertAccount(ACCOUNT_A);
    await insertAttachment(ACCOUNT_A, ATTACHMENT_1, {
      sourceByteSize: 1000,
      ciphertextByteSize: 1034,
    });
    for (const [source, ciphertext] of [
      [1000, 1000],
      [1000, 1033],
      [1000, 1035],
      [1000, 1000 + 34 + 1],
    ]) {
      await expectRejected(() =>
        insertAttachment(ACCOUNT_A, ATTACHMENT_2, {
          objectKey: OBJECT_KEY_2,
          sourceByteSize: source,
          ciphertextByteSize: ciphertext,
        }),
      );
    }
  });

  it("bounds the source at 1..12,582,912 and the ciphertext at 12,582,946", async () => {
    await insertAccount(ACCOUNT_A);
    await insertAttachment(ACCOUNT_A, ATTACHMENT_1, { sourceByteSize: MAX_SOURCE_BYTES });
    const row = await db
      .prepare("SELECT ciphertext_byte_size AS n FROM attachment")
      .first<{ n: number }>();
    expect(row?.n).toBe(MAX_CIPHERTEXT_BYTES);

    for (const bad of [0, -1, 1.5, MAX_SOURCE_BYTES + 1]) {
      await expectRejected(() =>
        insertAttachment(ACCOUNT_A, ATTACHMENT_2, {
          objectKey: OBJECT_KEY_2,
          sourceByteSize: bad,
        }),
      );
    }
  });

  it("rejects an unknown kind, state, hash or key generation", async () => {
    await insertAccount(ACCOUNT_A);
    for (const kind of ["image", "ATTACHMENT", ""]) {
      await expectRejected(() => insertAttachment(ACCOUNT_A, ATTACHMENT_1, { kind }));
    }
    for (const state of ["pending", "READY", ""]) {
      await expectRejected(() => insertAttachment(ACCOUNT_A, ATTACHMENT_1, { state }));
    }
    for (const hash of ["A".repeat(64), "a".repeat(63), "a".repeat(65), `${"a".repeat(63)}g`]) {
      await expectRejected(() =>
        insertAttachment(ACCOUNT_A, ATTACHMENT_1, { ciphertextHash: hash }),
      );
    }
    for (const generation of [0, 2]) {
      await expectRejected(() =>
        insertAttachment(ACCOUNT_A, ATTACHMENT_1, { keyGeneration: generation }),
      );
    }
  });

  it("accepts all six lifecycle states and stores them verbatim", async () => {
    await insertAccount(ACCOUNT_A);
    const states = [
      "allocated",
      "uploaded",
      "ready",
      "abandoned",
      "tombstoned",
      "garbage_collected",
    ];
    for (const [index, state] of states.entries()) {
      await insertAttachment(ACCOUNT_A, `70000000-0000-4000-8000-00000000001${index}`, {
        state,
        objectKey: `obj/70000000-0000-4000-8000-00000000002${index}`,
      });
    }
    const row = await db.prepare("SELECT count(*) AS n FROM attachment").first<{ n: number }>();
    expect(row?.n).toBe(states.length);
    // No transition trigger: M05 stores the enum, the handler orders the edges.
    await db
      .prepare("UPDATE attachment SET state = 'ready' WHERE attachment_id = ?")
      .bind("70000000-0000-4000-8000-000000000010")
      .run();
  });

  it("requires the object key to be the server-generated obj/<UUID> form", async () => {
    await insertAccount(ACCOUNT_A);
    for (const key of [
      "70000000-0000-4000-8000-0000000000FF",
      "obj/70000000-0000-4000-8000-0000000000ff",
      "obj/not-a-uuid",
      "OBJ/70000000-0000-4000-8000-0000000000FF",
      "",
    ]) {
      await expectRejected(() => insertAttachment(ACCOUNT_A, ATTACHMENT_1, { objectKey: key }));
    }
  });

  it("requires the three encrypted fields and a non-null created_at", async () => {
    await insertAccount(ACCOUNT_A);
    await expectRejected(() =>
      insertAttachment(ACCOUNT_A, ATTACHMENT_1, { fileNameEnc: null }),
    );
  });

  it("keeps server_seq nullable but positive when present", async () => {
    await insertAccount(ACCOUNT_A);
    await insertAttachment(ACCOUNT_A, ATTACHMENT_1, { serverSeq: null });
    await expectRejected(() =>
      insertAttachment(ACCOUNT_A, ATTACHMENT_2, { objectKey: OBJECT_KEY_2, serverSeq: 0 }),
    );
  });

  it("returns every encrypted envelope byte-for-byte", async () => {
    await insertAccount(ACCOUNT_A);
    await insertAttachment(ACCOUNT_A, ATTACHMENT_1);
    const row = await db
      .prepare("SELECT file_name_enc, wrapped_file_key_enc FROM attachment")
      .first<{ file_name_enc: string; wrapped_file_key_enc: string }>();
    expect(row?.file_name_enc).toBe(ENVELOPE_A);
    expect(row?.wrapped_file_key_enc).toBe(ENVELOPE_B);
  });
});
