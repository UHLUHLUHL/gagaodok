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

const MIGRATION = "0009_pairing_recovery.sql";
const ACCOUNT = "A0000000-0000-4000-8000-00000000000A";
const DEVICE = "B0000000-0000-4000-8000-000000000001";
const SESSION = "C0000000-0000-4000-8000-000000000001";
const CLAIM = "D0000000-0000-4000-8000-000000000001";
const ENROLLMENT = "E0000000-0000-4000-8000-000000000001";
const NOW = "2026-08-29T00:00:00Z";
const LATER = "2026-08-29T00:05:00Z";
const LOOKUP = `${"A".repeat(43)}=`;
const LOOKUP_2 = `${"B".repeat(43)}=`;
const HASH = "a".repeat(64);
const HASH_2 = "b".repeat(64);
const ENVELOPE = "AQEAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==";

const db = env.DB;

function migrationsUpTo(name: string): D1Migration[] {
  const index = env.TEST_MIGRATIONS.findIndex((migration) => migration.name === name);
  expect(index).toBeGreaterThanOrEqual(0);
  return env.TEST_MIGRATIONS.slice(0, index + 1);
}

async function expectRejected(run: () => Promise<unknown>): Promise<void> {
  let rejected = false;
  try {
    await run();
  } catch {
    rejected = true;
  }
  expect(rejected).toBe(true);
}

async function seedAccountAndDevice(): Promise<void> {
  await db
    .prepare("INSERT INTO account (account_id, created_at) VALUES (?, ?)")
    .bind(ACCOUNT, NOW)
    .run();
  await db
    .prepare(
      `INSERT INTO device
         (account_id, device_id, space_id, platform, linked_at, key_generation, token_hash)
       VALUES (?, ?, 'MAC_SPACE', 'macos', ?, 1, ?)`,
    )
    .bind(ACCOUNT, DEVICE, NOW, HASH)
    .run();
}

async function insertRecovery(version: number, lookup = LOOKUP, revokedAt: string | null = null) {
  return db
    .prepare(
      `INSERT INTO recovery_record
         (account_id, recovery_version, recovery_lookup_b64, recovery_auth_verifier,
          wrapped_master_key_enc, r2_object_key, key_generation, created_at, revoked_at)
       VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)`,
    )
    .bind(
      ACCOUNT,
      version,
      lookup,
      HASH,
      ENVELOPE,
      `recovery/F0000000-0000-4000-8000-${String(version).padStart(12, "0")}`,
      NOW,
      revokedAt,
    )
    .run();
}

async function insertSession(sessionId = SESSION, lookupHash = HASH) {
  return db
    .prepare(
      `INSERT INTO pairing_session
         (session_id, account_id, session_lookup_hash, created_by_device_id,
          created_at, expires_at, closed_at)
       VALUES (?, ?, ?, ?, ?, ?, NULL)`,
    )
    .bind(sessionId, ACCOUNT, lookupHash, DEVICE, NOW, LATER)
    .run();
}

beforeAll(async () => {
  await applyD1Migrations(db, migrationsUpTo(MIGRATION));
});

beforeEach(async () => {
  await db.prepare("DELETE FROM pairing_claim").run();
  await db.prepare("DELETE FROM pairing_session").run();
  await db.prepare("DELETE FROM enrollment_log").run();
  await db.prepare("DELETE FROM recovery_record").run();
  await db.prepare("DELETE FROM device").run();
  await db.prepare("DELETE FROM account").run();
});

describe("0009 pairing and recovery tables", () => {
  it("creates only the four expected security-boundary tables", async () => {
    const rows = await db
      .prepare(
        `SELECT name FROM sqlite_master
          WHERE type = 'table'
            AND name IN ('enrollment_log', 'recovery_record', 'pairing_session', 'pairing_claim')
          ORDER BY name`,
      )
      .all<{ name: string }>();
    expect(rows.results.map((row) => row.name)).toEqual([
      "enrollment_log",
      "pairing_claim",
      "pairing_session",
      "recovery_record",
    ]);
  });

  it("records nine migrations and replays without changing the ledger", async () => {
    const before = await db.prepare("SELECT count(*) AS n FROM d1_migrations").first<{ n: number }>();
    expect(before?.n).toBe(9);
    await applyD1Migrations(db, migrationsUpTo(MIGRATION));
    const after = await db.prepare("SELECT count(*) AS n FROM d1_migrations").first<{ n: number }>();
    expect(after?.n).toBe(9);
  });
});

describe("recovery_record invariants", () => {
  it("allows one active version and keeps a revoked predecessor", async () => {
    await seedAccountAndDevice();
    await insertRecovery(1, LOOKUP, NOW);
    await insertRecovery(2, LOOKUP_2, null);
    const rows = await db
      .prepare("SELECT recovery_version, revoked_at FROM recovery_record ORDER BY recovery_version")
      .all<{ recovery_version: number; revoked_at: string | null }>();
    expect(rows.results).toEqual([
      { recovery_version: 1, revoked_at: NOW },
      { recovery_version: 2, revoked_at: null },
    ]);
  });

  it("rejects a second active record and a reused global lookup", async () => {
    await seedAccountAndDevice();
    await insertRecovery(1);
    await expectRejected(() => insertRecovery(2, LOOKUP_2));
    await db.prepare("UPDATE recovery_record SET revoked_at = ? WHERE account_id = ?").bind(NOW, ACCOUNT).run();
    await expectRejected(() => insertRecovery(2, LOOKUP, null));
  });

  it("rejects invalid version, verifier, envelope and R2 key shapes", async () => {
    await seedAccountAndDevice();
    const statement = db.prepare(
      `INSERT INTO recovery_record
         (account_id, recovery_version, recovery_lookup_b64, recovery_auth_verifier,
          wrapped_master_key_enc, r2_object_key, key_generation, created_at, revoked_at)
       VALUES (?, ?, ?, ?, ?, ?, 1, ?, NULL)`,
    );
    for (const values of [
      [0, LOOKUP, HASH, ENVELOPE, "recovery/00000000-0000-4000-8000-000000000001"],
      [1, LOOKUP, "A".repeat(64), ENVELOPE, "recovery/00000000-0000-4000-8000-000000000001"],
      [1, LOOKUP, HASH, "not-base64", "recovery/00000000-0000-4000-8000-000000000001"],
      [1, LOOKUP, HASH, ENVELOPE, "wrong-prefix"],
    ] as const) {
      await expectRejected(() => statement.bind(ACCOUNT, ...values, NOW).run());
    }
  });
});

describe("pairing session and claim invariants", () => {
  it("requires the session creator to be an account device", async () => {
    await db.prepare("INSERT INTO account (account_id, created_at) VALUES (?, ?)").bind(ACCOUNT, NOW).run();
    await expectRejected(() => insertSession());
  });

  it("keeps session lookup hashes globally unique", async () => {
    await seedAccountAndDevice();
    await insertSession();
    await expectRejected(() => insertSession("C0000000-0000-4000-8000-000000000002", HASH));
  });

  it("stores submitted claims without approved device material", async () => {
    await seedAccountAndDevice();
    await insertSession();
    await db
      .prepare(
        `INSERT INTO pairing_claim
           (session_id, account_id, claim_id, claim_lookup_b64, claim_envelope,
            claim_redeem_verifier, state, submitted_at)
         VALUES (?, ?, ?, ?, ?, ?, 'submitted', ?)`,
      )
      .bind(SESSION, ACCOUNT, CLAIM, LOOKUP, ENVELOPE, HASH_2, NOW)
      .run();
    const row = await db
      .prepare("SELECT state, delivery_envelope, device_token_hash FROM pairing_claim")
      .first<{ state: string; delivery_envelope: string | null; device_token_hash: string | null }>();
    expect(row).toEqual({ state: "submitted", delivery_envelope: null, device_token_hash: null });
  });

  it("rejects an approved state unless every delivery and device field is present", async () => {
    await seedAccountAndDevice();
    await insertSession();
    await expectRejected(() =>
      db
        .prepare(
          `INSERT INTO pairing_claim
             (session_id, account_id, claim_id, claim_lookup_b64, claim_envelope,
              claim_redeem_verifier, state, submitted_at, approved_at)
           VALUES (?, ?, ?, ?, ?, ?, 'approved', ?, ?)`,
        )
        .bind(SESSION, ACCOUNT, CLAIM, LOOKUP, ENVELOPE, HASH_2, NOW, NOW)
        .run(),
    );
  });

  it("rejects consumed_at before the approved claim is consumed", async () => {
    await seedAccountAndDevice();
    await insertSession();
    await expectRejected(() =>
      db
        .prepare(
          `INSERT INTO pairing_claim
             (session_id, account_id, claim_id, claim_lookup_b64, claim_envelope,
              claim_redeem_verifier, state, submitted_at, consumed_at)
           VALUES (?, ?, ?, ?, ?, ?, 'submitted', ?, ?)`,
        )
        .bind(SESSION, ACCOUNT, CLAIM, LOOKUP, ENVELOPE, HASH_2, NOW, NOW)
        .run(),
    );
  });
});

describe("enrollment idempotency ledger", () => {
  it("binds one enrollment id and fingerprint to one account", async () => {
    await seedAccountAndDevice();
    await db
      .prepare(
        `INSERT INTO enrollment_log
           (account_id, enrollment_id, request_fingerprint, created_at)
         VALUES (?, ?, ?, ?)`,
      )
      .bind(ACCOUNT, ENROLLMENT, HASH_2, NOW)
      .run();
    await expectRejected(() =>
      db
        .prepare(
          `INSERT INTO enrollment_log
             (account_id, enrollment_id, request_fingerprint, created_at)
           VALUES (?, ?, ?, ?)`,
        )
        .bind(ACCOUNT, "E0000000-0000-4000-8000-000000000002", HASH, NOW)
        .run(),
    );
  });
});
