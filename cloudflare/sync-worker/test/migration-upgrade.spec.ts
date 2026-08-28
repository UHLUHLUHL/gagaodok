import { applyD1Migrations, env } from "cloudflare:test";
import type { D1Migration } from "cloudflare:test";
import { beforeAll, describe, expect, it } from "vitest";

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
// conversation or token, and no assertion prints a full identifier.
const ACCOUNT_A = "A0000000-0000-4000-8000-00000000000A";
const ACCOUNT_B = "A0000000-0000-4000-8000-00000000000B";
const DEVICE_1 = "B0000000-0000-4000-8000-000000000001";
const DEVICE_2 = "B0000000-0000-4000-8000-000000000002";
const LINKED_AT = "2026-08-28T00:00:00Z";
const REVOKED_AT = "2026-08-28T12:00:00Z";

// Stand-in for a base64 field envelope. The bytes carry no meaning: the point
// is that a migration must hand them back unchanged.
const SYNTHETIC_ENVELOPE = "AQEAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==";

const db = env.DB;

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

// Two rows written under the 0001 schema, before the foreign key exists. They
// cover the nullable and non-null spelling of every optional column so the
// rebuild has something to lose if it copies carelessly.
const LEGACY_ROWS = [
  {
    account_id: ACCOUNT_A,
    device_id: DEVICE_1,
    space_id: "MAC_SPACE",
    platform: "macos",
    display_name_enc: SYNTHETIC_ENVELOPE,
    linked_at: LINKED_AT,
    revoked_at: null as string | null,
    key_generation: 1,
  },
  {
    account_id: ACCOUNT_B,
    device_id: DEVICE_2,
    space_id: "PHONE_SPACE",
    platform: "android_phone",
    display_name_enc: null as string | null,
    linked_at: LINKED_AT,
    revoked_at: REVOKED_AT,
    key_generation: 1,
  },
];

beforeAll(async () => {
  // Step 1 — apply only 0001, the schema that has no foreign key.
  await applyD1Migrations(db, migrationsUpTo("0001_account_device.sql"));

  const beforeFks = await db.prepare("PRAGMA foreign_key_list(device)").all();
  expect(beforeFks.results.length).toBe(0);

  // Step 2 — write rows the way an existing database would already hold them.
  for (const accountId of [ACCOUNT_A, ACCOUNT_B]) {
    await db
      .prepare("INSERT INTO account (account_id, created_at) VALUES (?, ?)")
      .bind(accountId, LINKED_AT)
      .run();
  }
  for (const row of LEGACY_ROWS) {
    await db
      .prepare(
        `INSERT INTO device
           (account_id, device_id, space_id, platform, display_name_enc,
            linked_at, revoked_at, key_generation)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .bind(
        row.account_id,
        row.device_id,
        row.space_id,
        row.platform,
        row.display_name_enc,
        row.linked_at,
        row.revoked_at,
        row.key_generation,
      )
      .run();
  }

  // Step 3 — upgrade to 0002, which rebuilds `device` to add the foreign key.
  // Still logical stage M01; only the physical migration number moves.
  await applyD1Migrations(db, env.TEST_MIGRATIONS);
});

describe("0001 → 0002 upgrade preserves existing rows", () => {
  it("carries every row across the table rebuild", async () => {
    const row = await db.prepare("SELECT count(*) AS n FROM device").first<{ n: number }>();
    expect(row?.n).toBe(LEGACY_ROWS.length);
  });

  it("preserves every column value of every row", async () => {
    const rows = await db
      .prepare(
        `SELECT account_id, device_id, space_id, platform, display_name_enc,
                linked_at, revoked_at, key_generation
           FROM device
          ORDER BY account_id, device_id`,
      )
      .all<(typeof LEGACY_ROWS)[number]>();

    const expected = [...LEGACY_ROWS].sort((a, b) =>
      a.account_id === b.account_id
        ? a.device_id.localeCompare(b.device_id)
        : a.account_id.localeCompare(b.account_id),
    );
    // Whole-row comparison: a rebuild that shifted columns or dropped a
    // nullable value would show up here rather than in a single spot check.
    expect(rows.results).toEqual(expected);
  });

  it("returns the encrypted envelope byte-for-byte", async () => {
    const row = await db
      .prepare("SELECT display_name_enc FROM device WHERE account_id = ? AND device_id = ?")
      .bind(ACCOUNT_A, DEVICE_1)
      .first<{ display_name_enc: string | null }>();
    // The migration must not decode, re-encode or normalise the envelope.
    expect(row?.display_name_enc).toBe(SYNTHETIC_ENVELOPE);
  });

  it("preserves a null envelope as null rather than an empty string", async () => {
    const row = await db
      .prepare("SELECT display_name_enc FROM device WHERE account_id = ? AND device_id = ?")
      .bind(ACCOUNT_B, DEVICE_2)
      .first<{ display_name_enc: string | null }>();
    expect(row?.display_name_enc).toBeNull();
  });

  it("preserves a non-null revoked_at", async () => {
    const row = await db
      .prepare("SELECT revoked_at FROM device WHERE account_id = ? AND device_id = ?")
      .bind(ACCOUNT_B, DEVICE_2)
      .first<{ revoked_at: string | null }>();
    expect(row?.revoked_at).toBe(REVOKED_AT);
  });

  it("leaves the account rows untouched", async () => {
    const row = await db.prepare("SELECT count(*) AS n FROM account").first<{ n: number }>();
    expect(row?.n).toBe(2);
  });
});

describe("0002 leaves the 0001 schema guarantees intact", () => {
  it("keeps the composite primary key in the same order", async () => {
    const info = await db.prepare("PRAGMA table_info(device)").all<{
      name: string;
      pk: number;
    }>();
    const key = info.results
      .filter((column) => column.pk > 0)
      .sort((a, b) => a.pk - b.pk)
      .map((column) => column.name);
    expect(key).toEqual(["account_id", "device_id"]);
  });

  it("keeps every column", async () => {
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
  });

  it("recreates the active-device partial index", async () => {
    const row = await db
      .prepare("SELECT sql FROM sqlite_master WHERE type = 'index' AND name = ?")
      .bind("device_by_account_active")
      .first<{ sql: string }>();
    expect(row?.sql).toBeTruthy();
    // Still partial, still on the same column.
    expect(row?.sql).toContain("revoked_at IS NULL");
    expect(row?.sql).toContain("account_id");
  });

  it("keeps the CHECK constraints working after the rebuild", async () => {
    // The rebuild re-declares these; if one were dropped, a bad value would
    // now be accepted.
    await expectRejected(() =>
      db
        .prepare(
          `INSERT INTO device
             (account_id, device_id, space_id, platform, display_name_enc,
              linked_at, revoked_at, key_generation)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
        )
        .bind(ACCOUNT_A, DEVICE_2, "tablet", "macos", null, LINKED_AT, null, 1)
        .run(),
    );
    await expectRejected(() =>
      db
        .prepare(
          `INSERT INTO device
             (account_id, device_id, space_id, platform, display_name_enc,
              linked_at, revoked_at, key_generation)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
        )
        .bind(ACCOUNT_A, DEVICE_2, "MAC_SPACE", "macos", null, LINKED_AT, null, 2)
        .run(),
    );
  });

  it("keeps the primary key rejecting a duplicate device", async () => {
    await expectRejected(() =>
      db
        .prepare(
          `INSERT INTO device
             (account_id, device_id, space_id, platform, display_name_enc,
              linked_at, revoked_at, key_generation)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
        )
        .bind(ACCOUNT_A, DEVICE_1, "MAC_SPACE", "macos", null, LINKED_AT, null, 1)
        .run(),
    );
  });
});

describe("0002 starts enforcing the account reference", () => {
  it("now rejects an orphan device that 0001 would have accepted", async () => {
    const unknownAccount = "A0000000-0000-4000-8000-00000000000F";
    await expectRejected(() =>
      db
        .prepare(
          `INSERT INTO device
             (account_id, device_id, space_id, platform, display_name_enc,
              linked_at, revoked_at, key_generation)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
        )
        .bind(unknownAccount, DEVICE_1, "MAC_SPACE", "macos", null, LINKED_AT, null, 1)
        .run(),
    );
  });

  it("reports the foreign key with RESTRICT on both actions", async () => {
    const fks = await db.prepare("PRAGMA foreign_key_list(device)").all<{
      table: string;
      from: string;
      to: string;
      on_delete: string;
      on_update: string;
    }>();
    expect(fks.results.length).toBe(1);
    expect(fks.results[0]?.table).toBe("account");
    expect(fks.results[0]?.from).toBe("account_id");
    expect(fks.results[0]?.to).toBe("account_id");
    expect(fks.results[0]?.on_delete).toBe("RESTRICT");
    expect(fks.results[0]?.on_update).toBe("RESTRICT");
  });

  it("records every applied migration in the ledger exactly once", async () => {
    const rows = await db
      .prepare("SELECT name FROM d1_migrations ORDER BY name")
      .all<{ name: string }>();
    expect(rows.results.map((row) => row.name)).toEqual([
      "0001_account_device.sql",
      "0002_device_account_fk.sql",
      "0003_conversation_scope.sql",
      "0004_turn_bubble_extension.sql",
    ]);
  });

  it("is a no-op when applied again", async () => {
    await applyD1Migrations(db, env.TEST_MIGRATIONS);
    const rows = await db.prepare("SELECT count(*) AS n FROM d1_migrations").first<{ n: number }>();
    expect(rows?.n).toBe(env.TEST_MIGRATIONS.length);
    // The rebuild must not have run twice and lost the rows.
    const devices = await db.prepare("SELECT count(*) AS n FROM device").first<{ n: number }>();
    expect(devices?.n).toBe(LEGACY_ROWS.length);
  });

  it("leaves no rebuild scaffolding table behind", async () => {
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
    // The rebuild scaffolding table 0002 creates must be gone; the later
    // conversation-scope tables are expected to be here.
    expect(rows.results.map((row) => row.name)).toEqual([
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
  });
});
