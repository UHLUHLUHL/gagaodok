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

// Synthetic identifiers and synthetic hashes only. No real device, account or
// token appears here, and no assertion prints a whole token or hash.
const ACCOUNT_A = "A0000000-0000-4000-8000-00000000000A";
const ACCOUNT_B = "A0000000-0000-4000-8000-00000000000B";
const DEVICE_1 = "B0000000-0000-4000-8000-000000000001";
const DEVICE_2 = "B0000000-0000-4000-8000-000000000002";
const TIMESTAMP = "2026-08-28T00:00:00Z";
const HASH_A = "a".repeat(64);
const HASH_B = `${"b".repeat(63)}c`;

const TOKEN_MIGRATION = "0007_device_token.sql";

const db = env.DB;

function migrationsUpTo(name: string): D1Migration[] {
  const index = env.TEST_MIGRATIONS.findIndex((migration) => migration.name === name);
  expect(index).toBeGreaterThanOrEqual(0);
  return env.TEST_MIGRATIONS.slice(0, index + 1);
}

// Stage contract: this file applies migrations up to and including its own and
// no further (AGENTS.md stage-spec rule).
const STAGE_MIGRATIONS = () => migrationsUpTo(TOKEN_MIGRATION);

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

async function insertDevice(
  accountId: string,
  deviceId: string,
  tokenHash: string | null = null,
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO device
         (account_id, device_id, space_id, platform, display_name_enc,
          linked_at, revoked_at, key_generation, token_hash)
       VALUES (?, ?, 'PHONE_SPACE', 'android_phone', NULL, ?, NULL, 1, ?)`,
    )
    .bind(accountId, deviceId, TIMESTAMP, tokenHash)
    .run();
}

// Captured while 0007 is applied: beforeEach truncates, so the fact that a
// pre-existing row survived has to be recorded here.
let legacyRowCount = -1;
let legacyTokenHash: string | null | undefined;
let deviceFkCountAfterUpgrade = -1;

beforeAll(async () => {
  await applyD1Migrations(db, migrationsUpTo("0006_attachment.sql"));
  await insertAccount(ACCOUNT_A);
  await db
    .prepare(
      `INSERT INTO device
         (account_id, device_id, space_id, platform, display_name_enc,
          linked_at, revoked_at, key_generation)
       VALUES (?, ?, 'MAC_SPACE', 'macos', NULL, ?, NULL, 1)`,
    )
    .bind(ACCOUNT_A, DEVICE_1, TIMESTAMP)
    .run();

  await applyD1Migrations(db, STAGE_MIGRATIONS());

  const row = await db
    .prepare("SELECT count(*) AS n FROM device")
    .first<{ n: number }>();
  legacyRowCount = row?.n ?? -1;
  const legacy = await db
    .prepare("SELECT token_hash FROM device WHERE device_id = ?")
    .bind(DEVICE_1)
    .first<{ token_hash: string | null }>();
  legacyTokenHash = legacy?.token_hash;
  const fks = await db.prepare("PRAGMA foreign_key_list(device)").all<{ table: string }>();
  deviceFkCountAfterUpgrade = fks.results.length;
});

beforeEach(async () => {
  await db.prepare("DELETE FROM device").run();
  await db.prepare("DELETE FROM account").run();
});

describe("0007 — the column is added without rebuilding device", () => {
  it("keeps the pre-existing row and gives it a null token_hash", () => {
    expect(legacyRowCount).toBe(1);
    // A device linked before tokens existed cannot authenticate, but it must
    // not be deleted or given an invented hash.
    expect(legacyTokenHash).toBeNull();
  });

  it("keeps the account foreign key intact", () => {
    // ADD COLUMN is not a rebuild, so the 0002 constraint must be untouched.
    expect(deviceFkCountAfterUpgrade).toBe(1);
  });

  it("adds token_hash and nothing else to the device columns", async () => {
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
      "token_hash",
    ]);
  });

  it("records seven migrations and replays as a no-op", async () => {
    const ledger = await db
      .prepare("SELECT name FROM d1_migrations ORDER BY id")
      .all<{ name: string }>();
    expect(ledger.results.length).toBe(7);
    expect(ledger.results.map((row) => row.name).at(-1)).toBe(TOKEN_MIGRATION);
    await applyD1Migrations(db, STAGE_MIGRATIONS());
    const after = await db
      .prepare("SELECT count(*) AS n FROM d1_migrations")
      .first<{ n: number }>();
    expect(after?.n).toBe(7);
  });

  it("rolls back a failing migration without leaving schema or a ledger row", async () => {
    const failing: D1Migration = {
      name: "9999_intentionally_failing.sql",
      queries: [
        "CREATE TABLE scratch_should_not_survive (x TEXT NOT NULL)",
        "INSERT INTO scratch_should_not_survive (x) SELECT x FROM table_that_does_not_exist",
      ],
    };
    await expectRejected(() => applyD1Migrations(db, [...STAGE_MIGRATIONS(), failing]));
    const table = await db
      .prepare(
        "SELECT count(*) AS n FROM sqlite_master WHERE type = 'table' AND name = 'scratch_should_not_survive'",
      )
      .first<{ n: number }>();
    expect(table?.n).toBe(0);
    const ledger = await db
      .prepare("SELECT count(*) AS n FROM d1_migrations")
      .first<{ n: number }>();
    expect(ledger?.n).toBe(7);
  });
});

describe("0007 — token_hash values", () => {
  it("accepts a lowercase 64-character hex hash", async () => {
    await insertAccount(ACCOUNT_A);
    await insertDevice(ACCOUNT_A, DEVICE_1, HASH_A);
    const row = await db
      .prepare("SELECT count(*) AS n FROM device WHERE token_hash IS NOT NULL")
      .first<{ n: number }>();
    expect(row?.n).toBe(1);
  });

  it("still accepts a null hash for a device with no token", async () => {
    await insertAccount(ACCOUNT_A);
    await insertDevice(ACCOUNT_A, DEVICE_1, null);
    const row = await db
      .prepare("SELECT token_hash FROM device WHERE device_id = ?")
      .bind(DEVICE_1)
      .first<{ token_hash: string | null }>();
    expect(row?.token_hash).toBeNull();
  });

  it("rejects uppercase hex, a wrong length or a non-hex character", async () => {
    await insertAccount(ACCOUNT_A);
    for (const bad of [
      "A".repeat(64),
      "a".repeat(63),
      "a".repeat(65),
      `${"a".repeat(63)}g`,
      "",
    ]) {
      await expectRejected(() => insertDevice(ACCOUNT_A, DEVICE_1, bad));
    }
  });

  it("keeps a hash globally unique, including across accounts", async () => {
    await insertAccount(ACCOUNT_A);
    await insertAccount(ACCOUNT_B);
    await insertDevice(ACCOUNT_A, DEVICE_1, HASH_A);
    // Same account, second device.
    await expectRejected(() => insertDevice(ACCOUNT_A, DEVICE_2, HASH_A));
    // Different account: still refused, because lookup is by hash alone and a
    // collision would make one token resolve to two tenants.
    await expectRejected(() => insertDevice(ACCOUNT_B, DEVICE_2, HASH_A));
    await insertDevice(ACCOUNT_B, DEVICE_2, HASH_B);
    const row = await db
      .prepare("SELECT count(*) AS n FROM device WHERE token_hash IS NOT NULL")
      .first<{ n: number }>();
    expect(row?.n).toBe(2);
  });

  it("allows several devices to have no token at once", async () => {
    // The unique index is partial: null is not a value that can collide.
    await insertAccount(ACCOUNT_A);
    await insertDevice(ACCOUNT_A, DEVICE_1, null);
    await insertDevice(ACCOUNT_A, DEVICE_2, null);
    const row = await db.prepare("SELECT count(*) AS n FROM device").first<{ n: number }>();
    expect(row?.n).toBe(2);
  });
});
