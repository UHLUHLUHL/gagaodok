-- M01 (continued) — device references account
--
-- Physical migration 0002, logical stage M01. The number in the filename is
-- only the order in which migrations are applied; the logical stage is the
-- account boundary that 0001_account_device.sql started. Logical M02 is the
-- conversation scope (room, group_state, worldline) and arrives separately.
--
-- Closes the hole 0001 deliberately left open: without a reference constraint a
-- device row could name an account_id that does not exist, which would make the
-- account boundary a convention rather than something the database enforces.
--
-- Why the database and not the handler
--
-- D1 turns SQLite foreign keys on by default: PRAGMA foreign_keys reports 1 and
-- attempting to set it OFF is silently ignored. So the constraint holds for
-- every write path, including future handlers, migrations and fixtures, and it
-- cannot be forgotten in one code path. A handler-side "look the account up
-- first" check would also be racy between the lookup and the insert.
--
-- Why RESTRICT and not CASCADE
--
-- Deleting an account must never silently take conversation-bearing rows with
-- it. RESTRICT makes the delete fail while a device still exists, so removing an
-- account is an explicit, ordered operation. ON UPDATE RESTRICT records that
-- account_id is an immutable primary key.
--
-- Why the table is rebuilt
--
-- SQLite has no ALTER TABLE ... ADD CONSTRAINT, so a new reference constraint
-- means create-copy-drop-rename. No PRAGMA is used to get there. The usual
-- advice is to disable foreign keys around a rebuild, but D1 ignores both
-- PRAGMA foreign_keys = OFF and PRAGMA defer_foreign_keys = ON, and neither is
-- necessary here: the copy only reads rows whose account already exists, and
-- device is the child side, so dropping it violates nothing.
--
-- If a pre-existing orphan device row did exist, the INSERT ... SELECT below
-- would fail and the whole migration would roll back, because
-- applyD1Migrations() runs each migration's statements plus its ledger row in a
-- single transactional batch(). That is the intended behaviour: an orphan is a
-- defect to surface, not something to filter out silently. Phase 1 has no real
-- data, so such a failure means a fixture bug.
--
-- 0001_account_device.sql is already recorded in d1_migrations and is never
-- edited; the schema moves forward here instead.
--
-- Local-only. No Cloudflare resource is created by this file.

CREATE TABLE device_with_account_fk (
    account_id       TEXT NOT NULL
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
                     CHECK (
                         length(device_id) = 36
                         AND length(replace(device_id, '-', '')) = 32
                         AND substr(device_id,  9, 1) = '-'
                         AND substr(device_id, 14, 1) = '-'
                         AND substr(device_id, 19, 1) = '-'
                         AND substr(device_id, 24, 1) = '-'
                         AND device_id NOT GLOB '*[^0-9A-F-]*'
                     ),

    space_id         TEXT NOT NULL
                     CHECK (space_id IN ('MAC_SPACE', 'PHONE_SPACE', 'TABLET_SPACE')),
    platform         TEXT NOT NULL
                     CHECK (platform IN ('macos', 'android_phone', 'android_tablet')),

    display_name_enc TEXT,

    linked_at        TEXT NOT NULL,

    revoked_at       TEXT,

    key_generation   INTEGER NOT NULL DEFAULT 1
                     CHECK (key_generation = 1),

    PRIMARY KEY (account_id, device_id),

    FOREIGN KEY (account_id) REFERENCES account (account_id)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT
);

-- Columns are listed explicitly on both sides. A SELECT * copy would silently
-- depend on declaration order matching, which is exactly the kind of quiet
-- mismatch a migration must not risk.
INSERT INTO device_with_account_fk (
    account_id,
    device_id,
    space_id,
    platform,
    display_name_enc,
    linked_at,
    revoked_at,
    key_generation
)
SELECT
    account_id,
    device_id,
    space_id,
    platform,
    display_name_enc,
    linked_at,
    revoked_at,
    key_generation
FROM device;

DROP TABLE device;

ALTER TABLE device_with_account_fk RENAME TO device;

-- DROP TABLE took the old partial index with it, so it is recreated here with
-- the same name and definition as in 0001.
CREATE INDEX device_by_account_active
    ON device (account_id)
    WHERE revoked_at IS NULL;
