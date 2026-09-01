import { applyD1Migrations, env } from "cloudflare:test";
import type { D1Migration } from "cloudflare:test";
import { beforeAll, describe, expect, it } from "vitest";

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

const ACCOUNT = "A0000000-0000-4000-8000-00000000000A";
const MAC_ROOM = "10000000-0000-4000-8000-000000000001";
const PHONE_ROOM = "10000000-0000-4000-8000-000000000002";
const TIMESTAMP = "2026-08-31T00:00:00Z";
const ENVELOPE = "AQEAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==";
const db = env.DB;

function migrationsUpTo(name: string): D1Migration[] {
  const index = env.TEST_MIGRATIONS.findIndex((migration) => migration.name === name);
  expect(index).toBeGreaterThanOrEqual(0);
  return env.TEST_MIGRATIONS.slice(0, index + 1);
}

type LegacyRoom = {
  account_id: string;
  space_id: string;
  room_id: string;
  title_enc: string | null;
  status_message_enc: string | null;
  music_title_enc: string | null;
  music_artist_enc: string | null;
  revision: number;
  server_seq: number | null;
  created_at: string;
  updated_at: string;
};

const LEGACY_ROOMS: LegacyRoom[] = [
  {
    account_id: ACCOUNT,
    space_id: "MAC_SPACE",
    room_id: MAC_ROOM,
    title_enc: ENVELOPE,
    status_message_enc: null,
    music_title_enc: ENVELOPE,
    music_artist_enc: null,
    revision: 0,
    server_seq: null,
    created_at: TIMESTAMP,
    updated_at: TIMESTAMP,
  },
  {
    account_id: ACCOUNT,
    space_id: "PHONE_SPACE",
    room_id: PHONE_ROOM,
    title_enc: null,
    status_message_enc: ENVELOPE,
    music_title_enc: null,
    music_artist_enc: ENVELOPE,
    revision: 3,
    server_seq: 7,
    created_at: TIMESTAMP,
    updated_at: "2026-08-31T00:00:01Z",
  },
];

beforeAll(async () => {
  await applyD1Migrations(db, migrationsUpTo("0010_rate_limit.sql"));
  await db
    .prepare("INSERT INTO account (account_id, created_at) VALUES (?, ?)")
    .bind(ACCOUNT, TIMESTAMP)
    .run();
  for (const room of LEGACY_ROOMS) {
    await db
      .prepare(
        `INSERT INTO room
           (account_id, space_id, room_id, title_enc, status_message_enc,
            music_title_enc, music_artist_enc, revision, server_seq, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .bind(
        room.account_id,
        room.space_id,
        room.room_id,
        room.title_enc,
        room.status_message_enc,
        room.music_title_enc,
        room.music_artist_enc,
        room.revision,
        room.server_seq,
        room.created_at,
        room.updated_at,
      )
      .run();
  }
  await applyD1Migrations(db, migrationsUpTo("0011_room_origin_expand.sql"));
});

describe("0011 room origin expand migration", () => {
  it("backfills every legacy room from its writer space", async () => {
    const rows = await db
      .prepare("SELECT room_id, origin_space_id FROM room ORDER BY room_id")
      .all<{ room_id: string; origin_space_id: string | null }>();
    expect(rows.results).toEqual([
      { room_id: MAC_ROOM, origin_space_id: "MAC_SPACE" },
      { room_id: PHONE_ROOM, origin_space_id: "PHONE_SPACE" },
    ]);
  });

  it("preserves every pre-existing room value byte-for-byte", async () => {
    const rows = await db
      .prepare(
        `SELECT account_id, space_id, room_id, title_enc, status_message_enc,
                music_title_enc, music_artist_enc, revision, server_seq, created_at, updated_at
           FROM room ORDER BY room_id`,
      )
      .all<LegacyRoom>();
    expect(rows.results).toEqual(LEGACY_ROOMS);
  });

  it("records the expand migration exactly once", async () => {
    await applyD1Migrations(db, migrationsUpTo("0011_room_origin_expand.sql"));
    const row = await db
      .prepare("SELECT count(*) AS n FROM d1_migrations WHERE name = ?")
      .bind("0011_room_origin_expand.sql")
      .first<{ n: number }>();
    expect(row?.n).toBe(1);
  });

  it("keeps the transition column nullable for old workers", async () => {
    const info = await db.prepare("PRAGMA table_info(room)").all<{
      name: string;
      notnull: number;
    }>();
    expect(info.results.find((column) => column.name === "origin_space_id")?.notnull).toBe(0);
  });
});
