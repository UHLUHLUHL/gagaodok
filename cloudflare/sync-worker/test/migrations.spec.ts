import { applyD1Migrations, env } from "cloudflare:test";
import type { D1Migration } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";

// `TEST_MIGRATIONS` is injected by vitest.config.ts, which reads the migration
// files in Node. It exists only in the test runtime, so it is declared here
// rather than in the production `Env` in src/env.ts — a fixture binding must
// never look like something a request handler can rely on.
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
// conversation or token, and no test prints a full identifier.
const ACCOUNT_A = "A0000000-0000-4000-8000-00000000000A";
const ACCOUNT_B = "A0000000-0000-4000-8000-00000000000B";
const DEVICE_1 = "B0000000-0000-4000-8000-000000000001";
const DEVICE_2 = "B0000000-0000-4000-8000-000000000002";
const TIMESTAMP = "2026-08-28T00:00:00Z";

// A stand-in for a base64 field envelope. The bytes carry no meaning: D1 never
// decodes them, it only has to preserve them.
const SYNTHETIC_ENVELOPE = "AQEAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==";

const db = env.DB;

async function insertAccount(accountId: string): Promise<void> {
  await db
    .prepare("INSERT INTO account (account_id, created_at) VALUES (?, ?)")
    .bind(accountId, TIMESTAMP)
    .run();
}

async function insertDevice(
  accountId: string,
  deviceId: string,
  overrides: Partial<{
    spaceId: string;
    platform: string;
    displayNameEnc: string | null;
    revokedAt: string | null;
    keyGeneration: number;
  }> = {},
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO device
         (account_id, device_id, space_id, platform, display_name_enc,
          linked_at, revoked_at, key_generation)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
    )
    .bind(
      accountId,
      deviceId,
      overrides.spaceId ?? "MAC_SPACE",
      overrides.platform ?? "macos",
      overrides.displayNameEnc === undefined ? SYNTHETIC_ENVELOPE : overrides.displayNameEnc,
      TIMESTAMP,
      overrides.revokedAt ?? null,
      overrides.keyGeneration ?? 1,
    )
    .run();
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

beforeAll(async () => {
  await applyD1Migrations(db, env.TEST_MIGRATIONS);
});

// The plugin isolates storage per test *file*. Within this file the tests
// share one database, so each one states its own precondition explicitly
// instead of depending on the order the previous tests happened to run in.
beforeEach(async () => {
  await db.prepare("DELETE FROM device").run();
  await db.prepare("DELETE FROM account").run();
});

describe("M00 — local migration harness", () => {
  it("applies migrations to a local D1 binding", async () => {
    const row = await db
      .prepare("SELECT count(*) AS n FROM sqlite_master WHERE type = 'table' AND name = 'account'")
      .first<{ n: number }>();
    expect(row?.n).toBe(1);
  });

  it("records applied migrations so a re-run is a no-op", async () => {
    const before = await db
      .prepare("SELECT count(*) AS n FROM d1_migrations")
      .first<{ n: number }>();
    expect(before?.n).toBeGreaterThan(0);

    // Applying the same set again must not error and must not re-run the SQL
    // (a second CREATE TABLE would fail).
    await applyD1Migrations(db, env.TEST_MIGRATIONS);

    const after = await db
      .prepare("SELECT count(*) AS n FROM d1_migrations")
      .first<{ n: number }>();
    expect(after?.n).toBe(before?.n);
  });

  it("creates the tables of every applied stage and nothing later", async () => {
    const rows = await db
      .prepare(
        // `_cf_METADATA` is D1's own bookkeeping table and `d1_migrations`
        // is the migration ledger; neither is part of this schema.
        `SELECT name FROM sqlite_master
          WHERE type = 'table'
            AND name NOT LIKE 'sqlite_%'
            AND name NOT GLOB '_cf_*'
            AND name <> 'd1_migrations'
          ORDER BY name`,
      )
      .all<{ name: string }>();
    const names = rows.results.map((row) => row.name);
    // M01..M06 plus the cross-cutting auth (0007) and pairing/recovery
    // boundary (0009). Each stage has its own contract file; this one only
    // pins the latest table set.
    expect(names).toEqual([
      "account",
      "attachment",
      "bubble",
      "bubble_extension_field",
      "change_log",
      "checkpoint",
      "device",
      "engine_profile",
      "enrollment_log",
      "group_state",
      "operation_log",
      "pairing_claim",
      "pairing_session",
      "persona_snapshot",
      "persona_snapshot_extension_field",
      "persona_snapshot_head",
      "recovery_record",
      "room",
      "room_ai_state_ref",
      "room_extension_field",
      "transaction_guard",
      "turn",
      "turn_extension_field",
      "worldline",
    ]);
    // Nothing beyond the applied stages: delete_turn fan-out is not open, so
    // no per-child event table exists.
    for (const later of ["change_log_bubble", "change_log_turn"]) {
      expect(names).not.toContain(later);
    }
  });
});

describe("M01 — schema objects exist", () => {
  it("declares the documented primary keys", async () => {
    const accountPk = await db.prepare("PRAGMA table_info(account)").all<{
      name: string;
      pk: number;
      notnull: number;
    }>();
    const accountKey = accountPk.results.filter((c) => c.pk > 0).map((c) => c.name);
    expect(accountKey).toEqual(["account_id"]);

    const devicePk = await db.prepare("PRAGMA table_info(device)").all<{
      name: string;
      pk: number;
      notnull: number;
    }>();
    const deviceKey = devicePk.results
      .filter((c) => c.pk > 0)
      .sort((a, b) => a.pk - b.pk)
      .map((c) => c.name);
    // account_id leads so a device is only addressable inside its account.
    expect(deviceKey).toEqual(["account_id", "device_id"]);
  });

  it("declares every documented device column", async () => {
    const info = await db.prepare("PRAGMA table_info(device)").all<{ name: string }>();
    const columns = info.results.map((c) => c.name).sort();
    expect(columns).toEqual([
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

  it("marks the encrypted column with the _enc suffix and leaves it nullable", async () => {
    const info = await db.prepare("PRAGMA table_info(device)").all<{
      name: string;
      notnull: number;
    }>();
    const displayName = info.results.find((c) => c.name === "display_name_enc");
    expect(displayName).toBeDefined();
    expect(displayName?.notnull).toBe(0);
    // No plaintext twin of the encrypted column may exist.
    expect(info.results.some((c) => c.name === "display_name")).toBe(false);
  });

  it("creates the active-device index", async () => {
    const row = await db
      .prepare("SELECT count(*) AS n FROM sqlite_master WHERE type = 'index' AND name = ?")
      .bind("device_by_account_active")
      .first<{ n: number }>();
    expect(row?.n).toBe(1);
  });

  it("declares exactly one foreign key from device to account", async () => {
    // 0002_device_account_fk.sql closes the orphan-device hole that 0001
    // deliberately left open until its own constraints were proven. Both
    // files are logical stage M01: the account boundary.
    const fks = await db.prepare("PRAGMA foreign_key_list(device)").all<{
      table: string;
      from: string;
      to: string;
      on_delete: string;
      on_update: string;
    }>();
    expect(fks.results.length).toBe(1);
    const fk = fks.results[0];
    expect(fk?.table).toBe("account");
    expect(fk?.from).toBe("account_id");
    expect(fk?.to).toBe("account_id");
    // RESTRICT, never CASCADE: deleting an account must not silently take a
    // device row with it.
    expect(fk?.on_delete).toBe("RESTRICT");
    // account_id is an immutable primary key, so an update is a bug.
    expect(fk?.on_update).toBe("RESTRICT");
  });

  it("has foreign key enforcement switched on", async () => {
    // D1 enables `foreign_keys` by default, which is why the constraint can
    // be the canonical tenant boundary instead of a handler pre-check.
    const row = await db.prepare("PRAGMA foreign_keys").first<{ foreign_keys: number }>();
    expect(row?.foreign_keys).toBe(1);
  });
});

describe("M01 — account identity", () => {
  it("accepts a canonical account id", async () => {
    await insertAccount(ACCOUNT_A);
    const row = await db
      .prepare("SELECT count(*) AS n FROM account WHERE account_id = ?")
      .bind(ACCOUNT_A)
      .first<{ n: number }>();
    expect(row?.n).toBe(1);
  });

  it("rejects a duplicate account id", async () => {
    await insertAccount(ACCOUNT_B);
    await expectRejected(() => insertAccount(ACCOUNT_B));
  });

  it("rejects a lowercase account id", async () => {
    // The GLOB check is case-sensitive, matching the Worker's canonical
    // uppercase rule. Two spellings would otherwise become two tenants.
    await expectRejected(() =>
      insertAccount("c0000000-0000-4000-8000-00000000000c"),
    );
  });

  it("rejects a malformed account id", async () => {
    for (const bad of ["not-a-uuid", "", "A0000000-0000-4000-8000"]) {
      await expectRejected(() => insertAccount(bad));
    }
  });
});

describe("M01 — device identity is scoped to its account", () => {
  it("stores a device under its account", async () => {
    await insertAccount(ACCOUNT_A);
    await insertDevice(ACCOUNT_A, DEVICE_1);
    const row = await db
      .prepare("SELECT count(*) AS n FROM device WHERE account_id = ? AND device_id = ?")
      .bind(ACCOUNT_A, DEVICE_1)
      .first<{ n: number }>();
    expect(row?.n).toBe(1);
  });

  it("keeps the same device UUID separate under two accounts", async () => {
    await insertAccount(ACCOUNT_A);
    await insertAccount(ACCOUNT_B);
    // Same device UUID, different tenants: two independent rows.
    await insertDevice(ACCOUNT_A, DEVICE_1, { spaceId: "MAC_SPACE", platform: "macos" });
    await insertDevice(ACCOUNT_B, DEVICE_1, {
      spaceId: "PHONE_SPACE",
      platform: "android_phone",
    });

    const total = await db
      .prepare("SELECT count(*) AS n FROM device WHERE device_id = ?")
      .bind(DEVICE_1)
      .first<{ n: number }>();
    expect(total?.n).toBe(2);

    // A per-account read sees exactly one, and not the other tenant's row.
    const forA = await db
      .prepare("SELECT space_id FROM device WHERE account_id = ? AND device_id = ?")
      .bind(ACCOUNT_A, DEVICE_1)
      .all<{ space_id: string }>();
    expect(forA.results.map((r) => r.space_id)).toEqual(["MAC_SPACE"]);

    const forB = await db
      .prepare("SELECT space_id FROM device WHERE account_id = ? AND device_id = ?")
      .bind(ACCOUNT_B, DEVICE_1)
      .all<{ space_id: string }>();
    expect(forB.results.map((r) => r.space_id)).toEqual(["PHONE_SPACE"]);
  });

  it("rejects a duplicate device inside one account", async () => {
    await insertAccount(ACCOUNT_A);
    await insertDevice(ACCOUNT_A, DEVICE_2);
    await expectRejected(() => insertDevice(ACCOUNT_A, DEVICE_2));
  });

  it("allows several devices in the same space of one account", async () => {
    // canonical schema 1.2: space_id is a behaviour/origin area, not a
    // physical device identity, so UNIQUE(account_id, space_id) is not imposed.
    await insertAccount(ACCOUNT_A);
    await insertDevice(ACCOUNT_A, DEVICE_1, { spaceId: "MAC_SPACE" });
    await insertDevice(ACCOUNT_A, DEVICE_2, { spaceId: "MAC_SPACE" });
    const row = await db
      .prepare("SELECT count(*) AS n FROM device WHERE account_id = ? AND space_id = ?")
      .bind(ACCOUNT_A, "MAC_SPACE")
      .first<{ n: number }>();
    expect(row?.n).toBe(2);
  });
});

describe("M01 — device is bound to a real account", () => {
  it("rejects an orphan device", async () => {
    // No account row exists, so the insert must fail at the database rather
    // than relying on a handler remembering to look the account up first.
    await expectRejected(() => insertDevice(ACCOUNT_A, DEVICE_1));

    const row = await db.prepare("SELECT count(*) AS n FROM device").first<{ n: number }>();
    expect(row?.n).toBe(0);
  });

  it("still accepts a device whose account exists", async () => {
    await insertAccount(ACCOUNT_A);
    await insertDevice(ACCOUNT_A, DEVICE_1);
    const row = await db
      .prepare("SELECT count(*) AS n FROM device WHERE account_id = ?")
      .bind(ACCOUNT_A)
      .first<{ n: number }>();
    expect(row?.n).toBe(1);
  });

  it("refuses to delete an account that still has a device", async () => {
    await insertAccount(ACCOUNT_A);
    await insertDevice(ACCOUNT_A, DEVICE_1);

    await expectRejected(() =>
      db.prepare("DELETE FROM account WHERE account_id = ?").bind(ACCOUNT_A).run(),
    );

    // Neither side may be lost: RESTRICT must leave both rows intact.
    const accounts = await db
      .prepare("SELECT count(*) AS n FROM account WHERE account_id = ?")
      .bind(ACCOUNT_A)
      .first<{ n: number }>();
    const devices = await db
      .prepare("SELECT count(*) AS n FROM device WHERE account_id = ?")
      .bind(ACCOUNT_A)
      .first<{ n: number }>();
    expect(accounts?.n).toBe(1);
    expect(devices?.n).toBe(1);
  });

  it("allows deleting the account once its devices are gone", async () => {
    await insertAccount(ACCOUNT_A);
    await insertDevice(ACCOUNT_A, DEVICE_1);

    await db
      .prepare("DELETE FROM device WHERE account_id = ? AND device_id = ?")
      .bind(ACCOUNT_A, DEVICE_1)
      .run();
    await db.prepare("DELETE FROM account WHERE account_id = ?").bind(ACCOUNT_A).run();

    const row = await db
      .prepare("SELECT count(*) AS n FROM account WHERE account_id = ?")
      .bind(ACCOUNT_A)
      .first<{ n: number }>();
    expect(row?.n).toBe(0);
  });

  it("keeps tenants separate: a device may not borrow another account's id", async () => {
    await insertAccount(ACCOUNT_A);
    // ACCOUNT_B was never created, so a device claiming it is an orphan even
    // though ACCOUNT_A exists.
    await expectRejected(() => insertDevice(ACCOUNT_B, DEVICE_1));
  });
});

describe("M01 — device column constraints", () => {
  it("rejects a non-canonical space enum", async () => {
    await insertAccount(ACCOUNT_A);
    for (const bad of ["tablet", "mac_space", "UNKNOWN", ""]) {
      await expectRejected(() => insertDevice(ACCOUNT_A, DEVICE_1, { spaceId: bad }));
    }
  });

  it("rejects an unknown platform", async () => {
    await insertAccount(ACCOUNT_A);
    for (const bad of ["ios", "windows", ""]) {
      await expectRejected(() => insertDevice(ACCOUNT_A, DEVICE_1, { platform: bad }));
    }
  });

  it("rejects a key_generation other than 1", async () => {
    // E2EE proposal 6.2: v1 supports generation 1 only and never silently
    // falls back to another generation.
    await insertAccount(ACCOUNT_A);
    for (const bad of [0, 2, 99]) {
      await expectRejected(() => insertDevice(ACCOUNT_A, DEVICE_1, { keyGeneration: bad }));
    }
  });

  it("rejects a lowercase device id", async () => {
    await insertAccount(ACCOUNT_A);
    await expectRejected(() =>
      insertDevice(ACCOUNT_A, "b0000000-0000-4000-8000-000000000009"),
    );
  });
});

describe("M01 — revocation is stored but not yet enforced", () => {
  it("stores revoked_at without a handler refusing writes", async () => {
    await insertAccount(ACCOUNT_A);
    await insertDevice(ACCOUNT_A, DEVICE_1, { revokedAt: TIMESTAMP });
    const row = await db
      .prepare("SELECT revoked_at FROM device WHERE account_id = ? AND device_id = ?")
      .bind(ACCOUNT_A, DEVICE_1)
      .first<{ revoked_at: string | null }>();
    expect(row?.revoked_at).toBe(TIMESTAMP);
    // M01 only persists the column. The write path that refuses a revoked
    // token arrives with the operation handler, not here.
  });

  it("defaults revoked_at to null for an active device", async () => {
    await insertAccount(ACCOUNT_A);
    await insertDevice(ACCOUNT_A, DEVICE_2);
    const row = await db
      .prepare("SELECT revoked_at FROM device WHERE account_id = ? AND device_id = ?")
      .bind(ACCOUNT_A, DEVICE_2)
      .first<{ revoked_at: string | null }>();
    expect(row?.revoked_at).toBeNull();
  });
});

describe("M01 — envelope bytes are preserved verbatim", () => {
  it("returns the stored envelope byte-for-byte", async () => {
    await insertAccount(ACCOUNT_A);
    await insertDevice(ACCOUNT_A, DEVICE_1, { displayNameEnc: SYNTHETIC_ENVELOPE });
    const row = await db
      .prepare("SELECT display_name_enc FROM device WHERE account_id = ? AND device_id = ?")
      .bind(ACCOUNT_A, DEVICE_1)
      .first<{ display_name_enc: string | null }>();
    // D1 must not decode, re-serialise or normalise the envelope.
    expect(row?.display_name_enc).toBe(SYNTHETIC_ENVELOPE);
  });
});

describe("M00 — storage scope", () => {
  it("gives each test an empty account and device table", async () => {
    // beforeEach truncates, so a test never inherits another test's rows.
    const accounts = await db.prepare("SELECT count(*) AS n FROM account").first<{ n: number }>();
    const devices = await db.prepare("SELECT count(*) AS n FROM device").first<{ n: number }>();
    expect(accounts?.n).toBe(0);
    expect(devices?.n).toBe(0);
  });

  it("keeps the migration ledger across the truncation", async () => {
    // Truncating business rows must not look like "migrations were undone".
    const row = await db.prepare("SELECT count(*) AS n FROM d1_migrations").first<{ n: number }>();
    expect(row?.n).toBeGreaterThan(0);
  });
});
