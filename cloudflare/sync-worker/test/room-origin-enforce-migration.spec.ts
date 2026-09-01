import { applyD1Migrations, env } from "cloudflare:test";
import type { D1Migration } from "cloudflare:test";
import { describe, expect, it } from "vitest";

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
const ROOM = "10000000-0000-4000-8000-000000000001";
const TIMESTAMP = "2026-08-31T00:00:00Z";
const db = env.DB;

function migrationsUpTo(name: string): D1Migration[] {
  const index = env.TEST_MIGRATIONS.findIndex((migration) => migration.name === name);
  expect(index).toBeGreaterThanOrEqual(0);
  return env.TEST_MIGRATIONS.slice(0, index + 1);
}

describe("0012 room origin enforce migration", () => {
  it("aborts atomically when pre-existing shards claim conflicting origins", async () => {
    await applyD1Migrations(db, migrationsUpTo("0011_room_origin_expand.sql"));
    await db
      .prepare("INSERT INTO account (account_id, created_at) VALUES (?, ?)")
      .bind(ACCOUNT, TIMESTAMP)
      .run();
    for (const [space, origin] of [
      ["MAC_SPACE", "MAC_SPACE"],
      ["TABLET_SPACE", "TABLET_SPACE"],
    ] as const) {
      await db
        .prepare(
          `INSERT INTO room
             (account_id, space_id, room_id, origin_space_id, revision, created_at, updated_at)
           VALUES (?, ?, ?, ?, 0, ?, ?)`,
        )
        .bind(ACCOUNT, space, ROOM, origin, TIMESTAMP, TIMESTAMP)
        .run();
    }

    await expect(
      applyD1Migrations(db, migrationsUpTo("0012_room_origin_enforce.sql")),
    ).rejects.toBeDefined();

    const ledger = await db
      .prepare("SELECT count(*) AS n FROM d1_migrations WHERE name = ?")
      .bind("0012_room_origin_enforce.sql")
      .first<{ n: number }>();
    expect(ledger?.n).toBe(0);
    const guard = await db
      .prepare(
        "SELECT count(*) AS n FROM sqlite_master WHERE type = 'table' AND name = '_room_origin_migration_guard'",
      )
      .first<{ n: number }>();
    expect(guard?.n).toBe(0);
  });
});
