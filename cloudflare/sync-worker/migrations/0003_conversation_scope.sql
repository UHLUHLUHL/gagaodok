-- M02 — conversation scope
--
-- Physical migration 0003, logical stage M02: the room, group_state and
-- worldline tables from PHASE1_D1_MIGRATION_PLAN.md. 0001 and 0002 together
-- were logical M01, the account boundary; the number in a filename is only the
-- order migrations are applied in.
--
-- Deliberately absent, each belonging to a later stage:
--   * turn, bubble, extension_field                        (M03)
--   * engine_profile, persona_snapshot, checkpoint         (M04)
--   * attachment                                           (M05)
--   * operation_log, change_log, account.next_server_seq   (M06)
-- `server_seq` exists here as a per-row column because the canonical row shape
-- in canonical schema 14.1 has it, but nothing allocates it yet: the account
-- sequence and the ledger that consume it arrive with M06, so the column stays
-- nullable and unwritten until then.
--
-- Why no rebuild and no PRAGMA
--
-- Every table here is new, so there is nothing to copy, drop or rename and no
-- ordering hazard: `room` is created before the two tables that reference it,
-- which is the only ordering this migration needs. That matters because D1
-- silently ignores both `PRAGMA foreign_keys = OFF` and
-- `PRAGMA defer_foreign_keys = ON` — a migration that needed foreign keys
-- suspended could not get that here, so the order is what has to be correct.
--
-- If a statement below fails, applyD1Migrations() runs a migration's
-- statements plus its ledger row in a single transactional batch(), so the
-- partially created schema and the ledger row are rolled back together and the
-- migration can be re-applied from empty once the defect is fixed.
--
-- Why RESTRICT everywhere and never CASCADE
--
-- These rows carry conversations. Deleting an account or a room must never
-- silently take its group state or worldlines with it: RESTRICT makes such a
-- delete fail so removing a scope is an explicit, ordered operation. v1 also
-- deletes conversation content by tombstone rather than physically (canonical
-- schema 9), so a cascade would be the wrong shape even if it were safe.
-- ON UPDATE RESTRICT records that identity columns are immutable.
--
-- Local-only. No Cloudflare resource is created by this file.

-- Room. Identity is (account_id, space_id, room_id): space_id is part of the
-- key so the same room UUID can exist in two spaces without colliding
-- (canonical schema 14.1). Only canonical fields live here — unread_count,
-- is_pinned and the other per-device state are local-only (canonical schema
-- 3.1) and must never gain a column.
CREATE TABLE room (
    account_id         TEXT NOT NULL
                       -- Canonical uppercase hyphenated UUID (E2EE proposal
                       -- 12.3), expressed with length/substr plus one short
                       -- negated class because a per-character GLOB class
                       -- exceeds SQLite's pattern-complexity limit.
                       CHECK (
                           length(account_id) = 36
                           AND length(replace(account_id, '-', '')) = 32
                           AND substr(account_id,  9, 1) = '-'
                           AND substr(account_id, 14, 1) = '-'
                           AND substr(account_id, 19, 1) = '-'
                           AND substr(account_id, 24, 1) = '-'
                           AND account_id NOT GLOB '*[^0-9A-F-]*'
                       ),

    -- Canonical space enum, same three values as `device` (canonical schema
    -- 1.1). Never inferred from a build flavour.
    space_id           TEXT NOT NULL
                       CHECK (space_id IN ('MAC_SPACE', 'PHONE_SPACE', 'TABLET_SPACE')),

    room_id            TEXT NOT NULL
                       CHECK (
                           length(room_id) = 36
                           AND length(replace(room_id, '-', '')) = 32
                           AND substr(room_id,  9, 1) = '-'
                           AND substr(room_id, 14, 1) = '-'
                           AND substr(room_id, 19, 1) = '-'
                           AND substr(room_id, 24, 1) = '-'
                           AND room_id NOT GLOB '*[^0-9A-F-]*'
                       ),

    -- `_enc` marks a column holding an opaque base64 field envelope. D1 stores
    -- the bytes it was handed and never decodes, re-encodes or inspects them,
    -- and never checks AAD or nonce (canonical schema 0.2).
    title_enc          TEXT,
    status_message_enc TEXT,
    music_title_enc    TEXT,
    music_artist_enc   TEXT,

    -- CAS. The compare-and-set itself is a handler concern (M06); the column
    -- is the canonical row's own field (canonical schema 14.3).
    revision           INTEGER NOT NULL DEFAULT 0
                       CHECK (revision >= 0),

    -- Allocated by the account-wide sequence in M06. Null until then.
    server_seq         INTEGER
                       CHECK (server_seq IS NULL OR server_seq > 0),

    created_at         TEXT NOT NULL,
    updated_at         TEXT NOT NULL,

    PRIMARY KEY (account_id, space_id, room_id),

    FOREIGN KEY (account_id) REFERENCES account (account_id)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT
);

-- Group state. One row per PHONE_SPACE room, with no worldline dimension at
-- all (canonical schema 11.1, Worker API 4.1.2): allowing one would let the
-- same room-level row be addressed both as worldline_id null and as a UUID.
-- The currently selected worldline exists only as the encrypted
-- `active_worldline_id_enc` payload field, which the Worker never reads.
--
-- The space CHECK is narrower than room's three-value enum on purpose: group
-- chats and worldlines exist only on the phone (canonical schema 11), so a
-- MAC_SPACE or TABLET_SPACE group_state row is a defect, not a possibility.
CREATE TABLE group_state (
    account_id              TEXT NOT NULL
                            CHECK (
                                length(account_id) = 36
                                AND length(replace(account_id, '-', '')) = 32
                                AND substr(account_id,  9, 1) = '-'
                                AND substr(account_id, 14, 1) = '-'
                                AND substr(account_id, 19, 1) = '-'
                                AND substr(account_id, 24, 1) = '-'
                                AND account_id NOT GLOB '*[^0-9A-F-]*'
                            ),

    space_id                TEXT NOT NULL
                            CHECK (space_id = 'PHONE_SPACE'),

    room_id                 TEXT NOT NULL
                            CHECK (
                                length(room_id) = 36
                                AND length(replace(room_id, '-', '')) = 32
                                AND substr(room_id,  9, 1) = '-'
                                AND substr(room_id, 14, 1) = '-'
                                AND substr(room_id, 19, 1) = '-'
                                AND substr(room_id, 24, 1) = '-'
                                AND room_id NOT GLOB '*[^0-9A-F-]*'
                            ),

    participants_enc        TEXT,
    active_worldline_id_enc TEXT,

    revision                INTEGER NOT NULL DEFAULT 0
                            CHECK (revision >= 0),
    server_seq              INTEGER
                            CHECK (server_seq IS NULL OR server_seq > 0),

    created_at              TEXT NOT NULL,
    updated_at              TEXT NOT NULL,

    PRIMARY KEY (account_id, space_id, room_id),

    -- Two references, not one. The room reference already carries account_id,
    -- but stating the account reference explicitly means a row is bound to a
    -- real tenant by the database itself rather than by transitivity through
    -- whichever parent happens to exist.
    FOREIGN KEY (account_id) REFERENCES account (account_id)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT,

    -- account_id leads the referenced key, so a group_state row can only point
    -- at a room of its own account and its own space.
    FOREIGN KEY (account_id, space_id, room_id)
        REFERENCES room (account_id, space_id, room_id)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT
);

-- Worldline. Identity is the conversation scope plus `worldline_key`.
--
-- The API, canonical object and E2EE AAD all use the nullable `worldline_id`
-- (canonical schema 14.2). It cannot be the key: in SQLite two NULLs are not
-- equal, so a nullable key column would let the same default worldline insert
-- twice. A sentinel UUID was rejected because it could collide with a real id.
-- Instead the key is a materialised non-null column whose agreement with
-- worldline_id the database checks. `worldline_key = ''` is an internal
-- representation only — it never appears in the API, AAD, outbox or an R2 key.
--
-- A generated column cannot be part of a primary key in SQLite, so the writer
-- binds both values and the CHECK below refuses any pair that disagrees.
CREATE TABLE worldline (
    account_id             TEXT NOT NULL
                           CHECK (
                               length(account_id) = 36
                               AND length(replace(account_id, '-', '')) = 32
                               AND substr(account_id,  9, 1) = '-'
                               AND substr(account_id, 14, 1) = '-'
                               AND substr(account_id, 19, 1) = '-'
                               AND substr(account_id, 24, 1) = '-'
                               AND account_id NOT GLOB '*[^0-9A-F-]*'
                           ),

    space_id               TEXT NOT NULL
                           CHECK (space_id = 'PHONE_SPACE'),

    room_id                TEXT NOT NULL
                           CHECK (
                               length(room_id) = 36
                               AND length(replace(room_id, '-', '')) = 32
                               AND substr(room_id,  9, 1) = '-'
                               AND substr(room_id, 14, 1) = '-'
                               AND substr(room_id, 19, 1) = '-'
                               AND substr(room_id, 24, 1) = '-'
                               AND room_id NOT GLOB '*[^0-9A-F-]*'
                           ),

    -- Nullable: null is the room's default worldline.
    worldline_id           TEXT
                           CHECK (
                               worldline_id IS NULL
                               OR (
                                   length(worldline_id) = 36
                                   AND length(replace(worldline_id, '-', '')) = 32
                                   AND substr(worldline_id,  9, 1) = '-'
                                   AND substr(worldline_id, 14, 1) = '-'
                                   AND substr(worldline_id, 19, 1) = '-'
                                   AND substr(worldline_id, 24, 1) = '-'
                                   AND worldline_id NOT GLOB '*[^0-9A-F-]*'
                               )
                           ),

    worldline_key          TEXT NOT NULL
                           CHECK (worldline_key = COALESCE(worldline_id, '')),

    name_enc               TEXT,
    participant_hearts_enc TEXT,

    revision               INTEGER NOT NULL DEFAULT 0
                           CHECK (revision >= 0),
    server_seq             INTEGER
                           CHECK (server_seq IS NULL OR server_seq > 0),

    created_at             TEXT NOT NULL,
    updated_at             TEXT NOT NULL,

    PRIMARY KEY (account_id, space_id, room_id, worldline_key),

    FOREIGN KEY (account_id) REFERENCES account (account_id)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT,

    FOREIGN KEY (account_id, space_id, room_id)
        REFERENCES room (account_id, space_id, room_id)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT
);
