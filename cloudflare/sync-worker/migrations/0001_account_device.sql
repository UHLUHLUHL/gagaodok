-- M01 — account boundary
--
-- Creates only the two identity tables. Room, turn, bubble, attachment and the
-- operation ledger belong to M02..M06 and are deliberately absent here; see
-- docs/PHASE1_D1_MIGRATION_PLAN.md for the ordering and its invariants.
--
-- Re-run policy: migrations are applied by `applyD1Migrations()`, which records
-- each applied migration in the `d1_migrations` table and skips anything already
-- recorded. Re-running the suite is therefore a no-op rather than an error, and
-- this file is never edited after it has been applied — a schema change becomes
-- a new numbered migration. Phase 1 "rollback" means discarding the local
-- synthetic database and applying every migration again from empty.
--
-- Local-only. No Cloudflare resource is created by this file.

-- Tenant root. Every business row in later migrations hangs off `account_id`.
CREATE TABLE account (
    account_id  TEXT NOT NULL
                -- Canonical uppercase hyphenated UUID (E2EE proposal 12.3).
                     --   * exactly 36 characters
                     --   * exactly 4 hyphens, at positions 9/14/19/24
                     --   * every other character is an uppercase hex digit
                     -- A single long GLOB class per character exceeds SQLite's
                     -- pattern-complexity limit, so the same rule is expressed
                     -- with length/substr plus one short negated class.
                     CHECK (
                         length(account_id) = 36
                         AND length(replace(account_id, '-', '')) = 32
                         AND substr(account_id,  9, 1) = '-'
                         AND substr(account_id, 14, 1) = '-'
                         AND substr(account_id, 19, 1) = '-'
                         AND substr(account_id, 24, 1) = '-'
                         AND account_id NOT GLOB '*[^0-9A-F-]*'
                     ),
    created_at  TEXT NOT NULL,

    PRIMARY KEY (account_id)
);

-- Devices linked to an account.
--
-- `account_id` leads the primary key so a device is only ever addressable
-- inside its account: the same device UUID under two accounts is two distinct
-- rows that can never be confused for one another.
--
-- No FOREIGN KEY yet. PHASE1_D1_MIGRATION_PLAN.md fixes the order as
-- "prove primary/unique/CHECK with fixtures first, add reference constraints
-- afterwards", so referential integrity between device and account is added in
-- a later migration once these constraints are proven.
CREATE TABLE device (
    account_id       TEXT NOT NULL
                     -- Canonical uppercase hyphenated UUID (E2EE proposal 12.3).
                     --   * exactly 36 characters
                     --   * exactly 4 hyphens, at positions 9/14/19/24
                     --   * every other character is an uppercase hex digit
                     -- A single long GLOB class per character exceeds SQLite's
                     -- pattern-complexity limit, so the same rule is expressed
                     -- with length/substr plus one short negated class.
                     CHECK (
                         length(account_id) = 36
                         AND length(replace(account_id, '-', '')) = 32
                         AND substr(account_id,  9, 1) = '-'
                         AND substr(account_id, 14, 1) = '-'
                         AND substr(account_id, 19, 1) = '-'
                         AND substr(account_id, 24, 1) = '-'
                         AND account_id NOT GLOB '*[^0-9A-F-]*'
                     ),
    device_id        TEXT NOT NULL
                     -- Canonical uppercase hyphenated UUID (E2EE proposal 12.3).
                     --   * exactly 36 characters
                     --   * exactly 4 hyphens, at positions 9/14/19/24
                     --   * every other character is an uppercase hex digit
                     -- A single long GLOB class per character exceeds SQLite's
                     -- pattern-complexity limit, so the same rule is expressed
                     -- with length/substr plus one short negated class.
                     CHECK (
                         length(device_id) = 36
                         AND length(replace(device_id, '-', '')) = 32
                         AND substr(device_id,  9, 1) = '-'
                         AND substr(device_id, 14, 1) = '-'
                         AND substr(device_id, 19, 1) = '-'
                         AND substr(device_id, 24, 1) = '-'
                         AND device_id NOT GLOB '*[^0-9A-F-]*'
                     ),

    -- Canonical space enum. Never inferred from build flavor: the value is
    -- fixed when the device is linked (canonical schema 1.1).
    space_id         TEXT NOT NULL
                     CHECK (space_id IN ('MAC_SPACE', 'PHONE_SPACE', 'TABLET_SPACE')),
    platform         TEXT NOT NULL
                     CHECK (platform IN ('macos', 'android_phone', 'android_tablet')),

    -- User-chosen device label, so it is encrypted. `_enc` marks a column that
    -- holds a base64 envelope, never plaintext (canonical schema 0.2).
    display_name_enc TEXT,

    linked_at        TEXT NOT NULL,

    -- Non-null means the device token must be refused. M01 stores the column;
    -- the handler that enforces it arrives with the write path.
    revoked_at       TEXT,

    -- v1 supports generation 1 only (E2EE proposal 6.2). A different value is
    -- a spec error rather than something to fall back from.
    key_generation   INTEGER NOT NULL DEFAULT 1
                     CHECK (key_generation = 1),

    PRIMARY KEY (account_id, device_id)
);

-- Listing an account's devices is the common read; the primary key already
-- orders by account, so this index only helps the revocation sweep.
CREATE INDEX device_by_account_active
    ON device (account_id)
    WHERE revoked_at IS NULL;
