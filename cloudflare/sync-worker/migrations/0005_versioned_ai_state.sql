-- M04 — versioned AI state
--
-- Physical migration 0005, logical stage M04. 0001+0002 were M01 (account
-- boundary), 0003 was M02 (conversation scope) and 0004 was M03 (turn, bubble
-- and owner extension tables).
--
-- Six new tables, created parent-before-child:
--   engine_profile → persona_snapshot → persona_snapshot_head →
--   persona_snapshot_extension_field → checkpoint → room_ai_state_ref
--
-- Nothing existing is rebuilt. That is the point of `room_ai_state_ref`: the
-- room's engine/persona reference has to be plaintext so D1 can enforce an
-- exact-revision foreign key, but adding those columns to `room` would mean a
-- create-copy-drop-rename of room while group_state, worldline, turn,
-- room_extension_field — and below turn, bubble and two more extension tables —
-- all reference it. D1 ignores PRAGMA foreign_keys = OFF and
-- defer_foreign_keys = ON, so that rebuild could not suspend the constraints
-- and would have to reconstruct the whole descendant graph. A 1:1 side table
-- keyed by the room identity gets the same enforcement for none of that risk.
-- The wire projection still hands the reference back inside the room object.
--
-- Still absent: attachment and R2 (M05); operation_log, change_log,
-- account.next_server_seq and every transactional handler (M06). `server_seq`
-- columns exist where the canonical row shape has them but stay null: nothing
-- allocates a sequence until M06.
--
-- Immutability is enforced by BEFORE UPDATE triggers on the two revision
-- tables, not by convention. The migration loader keeps a BEGIN…END trigger
-- body intact rather than splitting it at the inner semicolons, which is what
-- makes this safe to state here rather than deferring it to the handler.
--
-- No trigger reads, decodes or rewrites ciphertext; the ones below only refuse
-- a statement. AAD, nonce and AEAD tags are never examined anywhere in D1.
--
-- Local-only. No Cloudflare resource is created by this file.

-- Engine profile. An immutable revision row (canonical schema 4): a change is a
-- new `profile_revision`, never an edit, and a room points at the exact pair.
-- Several rooms may share one revision, so there is no head table and no
-- back-reference — one room's change must not reach another room implicitly.
CREATE TABLE engine_profile (
    account_id                        TEXT NOT NULL
                                      CHECK (
                                          length(account_id) = 36
                                          AND length(replace(account_id, '-', '')) = 32
                                          AND substr(account_id,  9, 1) = '-'
                                          AND substr(account_id, 14, 1) = '-'
                                          AND substr(account_id, 19, 1) = '-'
                                          AND substr(account_id, 24, 1) = '-'
                                          AND account_id NOT GLOB '*[^0-9A-F-]*'
                                      ),
    space_id                          TEXT NOT NULL
                                      CHECK (space_id IN ('MAC_SPACE', 'PHONE_SPACE', 'TABLET_SPACE')),
    engine_profile_id                 TEXT NOT NULL
                                      CHECK (
                                          length(engine_profile_id) = 36
                                          AND length(replace(engine_profile_id, '-', '')) = 32
                                          AND substr(engine_profile_id,  9, 1) = '-'
                                          AND substr(engine_profile_id, 14, 1) = '-'
                                          AND substr(engine_profile_id, 19, 1) = '-'
                                          AND substr(engine_profile_id, 24, 1) = '-'
                                          AND engine_profile_id NOT GLOB '*[^0-9A-F-]*'
                                      ),
    -- 1-based: revision 0 does not exist for an immutable version chain.
    profile_revision                  INTEGER NOT NULL
                                      CHECK (
                                          typeof(profile_revision) = 'integer'
                                          AND profile_revision >= 1
                                          AND profile_revision <= 9007199254740991
                                      ),

    -- Encrypted contract fields (canonical schema 4). Opaque to D1.
    mode_enc                          TEXT,
    model_capability_enc              TEXT,
    prompt_profile_id_enc             TEXT,
    prompt_profile_version_enc        TEXT,
    relationship_policy_enc           TEXT,
    compaction_profile_id_enc         TEXT,
    compaction_contract_fingerprint_enc TEXT,
    cache_policy_enc                  TEXT,
    repetition_policy_enc             TEXT,

    -- The one plaintext compatibility value: the server compares it for
    -- equality and never parses it. Stored exactly as received; this migration
    -- invents no format, length or hash rule for it.
    compaction_compat_tag             TEXT,

    server_seq                        INTEGER
                                      CHECK (
                                          server_seq IS NULL
                                          OR (
                                              typeof(server_seq) = 'integer'
                                              AND server_seq >= 1
                                              AND server_seq <= 9007199254740991
                                          )
                                      ),

    PRIMARY KEY (account_id, space_id, engine_profile_id, profile_revision),

    FOREIGN KEY (account_id) REFERENCES account (account_id)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT
);

-- An immutable row is immutable in the database, not merely by agreement.
-- Without this a handler bug could edit a revision that rooms already point at,
-- silently changing the AI contract of every one of them.
CREATE TRIGGER engine_profile_is_immutable
BEFORE UPDATE ON engine_profile
BEGIN
    SELECT RAISE(ABORT, 'engine_profile revisions are immutable');
END;

-- Persona snapshot. Also an immutable revision row (canonical schema 5).
-- `owner_space_id` decides write permission and v1 requires it to equal
-- `space_id`; `created_by_device_id` is provenance only and is bound to a
-- device of the same account.
CREATE TABLE persona_snapshot (
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
                           CHECK (space_id IN ('MAC_SPACE', 'PHONE_SPACE', 'TABLET_SPACE')),
    persona_snapshot_id    TEXT NOT NULL
                                  CHECK (
                                      length(persona_snapshot_id) = 36
                                      AND length(replace(persona_snapshot_id, '-', '')) = 32
                                      AND substr(persona_snapshot_id,  9, 1) = '-'
                                      AND substr(persona_snapshot_id, 14, 1) = '-'
                                      AND substr(persona_snapshot_id, 19, 1) = '-'
                                      AND substr(persona_snapshot_id, 24, 1) = '-'
                                      AND persona_snapshot_id NOT GLOB '*[^0-9A-F-]*'
                                  ),
    snapshot_revision      INTEGER NOT NULL
                                  CHECK (
                                      typeof(snapshot_revision) = 'integer'
                                      AND snapshot_revision >= 1
                                      AND snapshot_revision <= 9007199254740991
                                  ),

    owner_space_id         TEXT NOT NULL
                           CHECK (owner_space_id = space_id),
    created_by_device_id   TEXT NOT NULL
                                  CHECK (
                                      length(created_by_device_id) = 36
                                      AND length(replace(created_by_device_id, '-', '')) = 32
                                      AND substr(created_by_device_id,  9, 1) = '-'
                                      AND substr(created_by_device_id, 14, 1) = '-'
                                      AND substr(created_by_device_id, 19, 1) = '-'
                                      AND substr(created_by_device_id, 24, 1) = '-'
                                      AND created_by_device_id NOT GLOB '*[^0-9A-F-]*'
                                  ),
    created_at             TEXT NOT NULL,

    persona_schema_version INTEGER NOT NULL
                                  CHECK (
                                      typeof(persona_schema_version) = 'integer'
                                      AND persona_schema_version >= 1
                                      AND persona_schema_version <= 9007199254740991
                                  ),

    description_enc        TEXT,
    samples_enc            TEXT,
    style_guide_enc        TEXT,
    is_enabled_enc         TEXT,
    content_fingerprint_enc TEXT,

    server_seq             INTEGER
                                  CHECK (
                                      server_seq IS NULL
                                      OR (
                                          typeof(server_seq) = 'integer'
                                          AND server_seq >= 1
                                          AND server_seq <= 9007199254740991
                                      )
                                  ),

    PRIMARY KEY (account_id, space_id, persona_snapshot_id, snapshot_revision),

    FOREIGN KEY (account_id) REFERENCES account (account_id)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT,

    FOREIGN KEY (account_id, created_by_device_id)
        REFERENCES device (account_id, device_id)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT
);

CREATE TRIGGER persona_snapshot_is_immutable
BEFORE UPDATE ON persona_snapshot
BEGIN
    SELECT RAISE(ABORT, 'persona_snapshot revisions are immutable');
END;

-- Persona head. The only mutable part of the snapshot chain, and the only CAS
-- version it has: `current_snapshot_revision` is compared against a request's
-- `base_revision` and advanced in the same M06 transaction that inserts the new
-- immutable row. There is deliberately no second head_revision, no server_seq
-- and no updated_at — a second version column would be a second source of
-- truth for the same fact.
CREATE TABLE persona_snapshot_head (
    account_id               TEXT NOT NULL,
    space_id                 TEXT NOT NULL,
    persona_snapshot_id      TEXT NOT NULL,
    -- The head can only ever name a revision that exists, and the reference
    -- carries account and space, so it cannot borrow another tenant's chain.
    current_snapshot_revision INTEGER NOT NULL,

    PRIMARY KEY (account_id, space_id, persona_snapshot_id),

    FOREIGN KEY (account_id, space_id, persona_snapshot_id, current_snapshot_revision)
        REFERENCES persona_snapshot
            (account_id, space_id, persona_snapshot_id, snapshot_revision)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT
);

-- Persona extension. Owner is one exact snapshot revision, following the M03
-- owner-table contract: the table is the owner type, the primary key starts
-- with the owner's real key, and there is no independent revision, server_seq
-- or updated_at. The key grammar is the same three lowercase dotted segments.
CREATE TABLE persona_snapshot_extension_field (
    account_id          TEXT NOT NULL,
    space_id            TEXT NOT NULL,
    persona_snapshot_id TEXT NOT NULL,
    snapshot_revision   INTEGER NOT NULL,

    extension_key       TEXT NOT NULL
                        CHECK (
                            length(extension_key) - length(replace(extension_key, '.', '')) = 2
                            AND extension_key NOT GLOB '*[^a-z0-9._]*'
                            AND substr(extension_key, 1, 1) GLOB '[a-z]'
                            AND substr(extension_key, instr(extension_key, '.') + 1, 1) GLOB '[a-z]'
                            AND substr(
                                    extension_key,
                                    instr(extension_key, '.')
                                        + instr(substr(extension_key, instr(extension_key, '.') + 1), '.')
                                        + 1,
                                    1
                                ) GLOB '[a-z]'
                        ),

    envelope_enc        TEXT NOT NULL,

    PRIMARY KEY (account_id, space_id, persona_snapshot_id, snapshot_revision, extension_key),

    FOREIGN KEY (account_id, space_id, persona_snapshot_id, snapshot_revision)
        REFERENCES persona_snapshot
            (account_id, space_id, persona_snapshot_id, snapshot_revision)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT
);

-- Checkpoint. Long-term memory, not a provider cache (canonical schema 6). It
-- uses the same conversation scope as turn and bubble, including the
-- materialised `worldline_key` and the rule that a named worldline is
-- PHONE_SPACE only. Unlike the two revision tables above it is mutable: create
-- writes revision 0 and every extension is a CAS patch (M06).
--
-- A legacy unversioned digest needs no table of its own: it is this row with a
-- null turn range, a null through_server_seq, an encrypted
-- `legacy_unversioned` profile id and a plaintext compat tag.
CREATE TABLE checkpoint (
    account_id                      TEXT NOT NULL
                                    CHECK (
                                        length(account_id) = 36
                                        AND length(replace(account_id, '-', '')) = 32
                                        AND substr(account_id,  9, 1) = '-'
                                        AND substr(account_id, 14, 1) = '-'
                                        AND substr(account_id, 19, 1) = '-'
                                        AND substr(account_id, 24, 1) = '-'
                                        AND account_id NOT GLOB '*[^0-9A-F-]*'
                                    ),
    space_id                        TEXT NOT NULL
                                    CHECK (space_id IN ('MAC_SPACE', 'PHONE_SPACE', 'TABLET_SPACE')),
    room_id                         TEXT NOT NULL
                                    CHECK (
                                        length(room_id) = 36
                                        AND length(replace(room_id, '-', '')) = 32
                                        AND substr(room_id,  9, 1) = '-'
                                        AND substr(room_id, 14, 1) = '-'
                                        AND substr(room_id, 19, 1) = '-'
                                        AND substr(room_id, 24, 1) = '-'
                                        AND room_id NOT GLOB '*[^0-9A-F-]*'
                                    ),
    worldline_id                    TEXT
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
    worldline_key                   TEXT NOT NULL
                                    CHECK (worldline_key = COALESCE(worldline_id, '')),
    checkpoint_id                   TEXT NOT NULL
                                    CHECK (
                                        length(checkpoint_id) = 36
                                        AND length(replace(checkpoint_id, '-', '')) = 32
                                        AND substr(checkpoint_id,  9, 1) = '-'
                                        AND substr(checkpoint_id, 14, 1) = '-'
                                        AND substr(checkpoint_id, 19, 1) = '-'
                                        AND substr(checkpoint_id, 24, 1) = '-'
                                        AND checkpoint_id NOT GLOB '*[^0-9A-F-]*'
                                    ),

    -- Coverage. Both endpoints are present or neither is; a half-open range
    -- would not say what the checkpoint actually covers.
    first_turn_id                   TEXT
                                    CHECK (
                                        first_turn_id IS NULL
                                        OR (
                                            length(first_turn_id) = 36
                                            AND length(replace(first_turn_id, '-', '')) = 32
                                            AND substr(first_turn_id,  9, 1) = '-'
                                            AND substr(first_turn_id, 14, 1) = '-'
                                            AND substr(first_turn_id, 19, 1) = '-'
                                            AND substr(first_turn_id, 24, 1) = '-'
                                            AND first_turn_id NOT GLOB '*[^0-9A-F-]*'
                                        )
                                    ),
    last_turn_id                    TEXT
                                    CHECK (
                                        last_turn_id IS NULL
                                        OR (
                                            length(last_turn_id) = 36
                                            AND length(replace(last_turn_id, '-', '')) = 32
                                            AND substr(last_turn_id,  9, 1) = '-'
                                            AND substr(last_turn_id, 14, 1) = '-'
                                            AND substr(last_turn_id, 19, 1) = '-'
                                            AND substr(last_turn_id, 24, 1) = '-'
                                            AND last_turn_id NOT GLOB '*[^0-9A-F-]*'
                                        )
                                    ),
    -- Allocated by the account sequence in M06, so null until then.
    through_server_seq              INTEGER
                                    CHECK (
                                        through_server_seq IS NULL
                                        OR (
                                            typeof(through_server_seq) = 'integer'
                                            AND through_server_seq >= 1
                                            AND through_server_seq <= 9007199254740991
                                        )
                                    ),

    segments_enc                    TEXT,
    summary_text_enc                TEXT,

    checkpoint_schema_version       INTEGER NOT NULL
                                    CHECK (
                                        typeof(checkpoint_schema_version) = 'integer'
                                        AND checkpoint_schema_version >= 1
                                        AND checkpoint_schema_version <= 9007199254740991
                                    ),
    compaction_profile_id_enc       TEXT,
    compaction_contract_fingerprint_enc TEXT,
    compaction_compat_tag           TEXT,

    owner_space_id                  TEXT NOT NULL
                                    CHECK (owner_space_id = space_id),
    created_by_device_id            TEXT NOT NULL
                                    CHECK (
                                        length(created_by_device_id) = 36
                                        AND length(replace(created_by_device_id, '-', '')) = 32
                                        AND substr(created_by_device_id,  9, 1) = '-'
                                        AND substr(created_by_device_id, 14, 1) = '-'
                                        AND substr(created_by_device_id, 19, 1) = '-'
                                        AND substr(created_by_device_id, 24, 1) = '-'
                                        AND created_by_device_id NOT GLOB '*[^0-9A-F-]*'
                                    ),
    created_at                      TEXT NOT NULL,

    -- Mutable CAS version, starting at 0 on create.
    revision                        INTEGER NOT NULL DEFAULT 0
                                    CHECK (
                                        typeof(revision) = 'integer'
                                        AND revision >= 0
                                        AND revision <= 9007199254740991
                                    ),
    server_seq                      INTEGER
                                    CHECK (
                                        server_seq IS NULL
                                        OR (
                                            typeof(server_seq) = 'integer'
                                            AND server_seq >= 1
                                            AND server_seq <= 9007199254740991
                                        )
                                    ),

    CHECK (worldline_id IS NULL OR space_id = 'PHONE_SPACE'),
    CHECK (
        (first_turn_id IS NULL AND last_turn_id IS NULL)
        OR (first_turn_id IS NOT NULL AND last_turn_id IS NOT NULL)
    ),

    PRIMARY KEY (account_id, space_id, room_id, worldline_key, checkpoint_id),

    FOREIGN KEY (account_id, space_id, room_id)
        REFERENCES room (account_id, space_id, room_id)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT,

    FOREIGN KEY (account_id, created_by_device_id)
        REFERENCES device (account_id, device_id)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT,

    -- Each endpoint is a turn of this very scope, worldline included. SQLite
    -- treats a composite reference with a null column as satisfied, so the
    -- null range above passes without a second rule.
    FOREIGN KEY (account_id, space_id, room_id, worldline_key, first_turn_id)
        REFERENCES turn (account_id, space_id, room_id, worldline_key, turn_id)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT,

    FOREIGN KEY (account_id, space_id, room_id, worldline_key, last_turn_id)
        REFERENCES turn (account_id, space_id, room_id, worldline_key, turn_id)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT
);

-- Room AI state reference. One row per room at most, keyed by the room's own
-- identity so the reference cannot drift to another room or tenant. Each pair
-- is present or absent as a whole and, when present, names an exact immutable
-- revision in the same account and space.
--
-- No revision, timestamp or server_seq: the owning fact is the room's, and M06
-- puts the room's CAS bump and this row's change in one batch.
CREATE TABLE room_ai_state_ref (
    account_id               TEXT NOT NULL,
    space_id                 TEXT NOT NULL,
    room_id                  TEXT NOT NULL,

    engine_profile_id        TEXT
                             CHECK (
                                 engine_profile_id IS NULL
                                 OR (
                                     length(engine_profile_id) = 36
                                     AND length(replace(engine_profile_id, '-', '')) = 32
                                     AND substr(engine_profile_id,  9, 1) = '-'
                                     AND substr(engine_profile_id, 14, 1) = '-'
                                     AND substr(engine_profile_id, 19, 1) = '-'
                                     AND substr(engine_profile_id, 24, 1) = '-'
                                     AND engine_profile_id NOT GLOB '*[^0-9A-F-]*'
                                 )
                             ),
    engine_profile_revision  INTEGER
                             CHECK (
                                 engine_profile_revision IS NULL
                                 OR (
                                     typeof(engine_profile_revision) = 'integer'
                                     AND engine_profile_revision >= 1
                                     AND engine_profile_revision <= 9007199254740991
                                 )
                             ),

    persona_snapshot_id      TEXT
                             CHECK (
                                 persona_snapshot_id IS NULL
                                 OR (
                                     length(persona_snapshot_id) = 36
                                     AND length(replace(persona_snapshot_id, '-', '')) = 32
                                     AND substr(persona_snapshot_id,  9, 1) = '-'
                                     AND substr(persona_snapshot_id, 14, 1) = '-'
                                     AND substr(persona_snapshot_id, 19, 1) = '-'
                                     AND substr(persona_snapshot_id, 24, 1) = '-'
                                     AND persona_snapshot_id NOT GLOB '*[^0-9A-F-]*'
                                 )
                             ),
    persona_snapshot_revision INTEGER
                             CHECK (
                                 persona_snapshot_revision IS NULL
                                 OR (
                                     typeof(persona_snapshot_revision) = 'integer'
                                     AND persona_snapshot_revision >= 1
                                     AND persona_snapshot_revision <= 9007199254740991
                                 )
                             ),

    CHECK (
        (engine_profile_id IS NULL AND engine_profile_revision IS NULL)
        OR (engine_profile_id IS NOT NULL AND engine_profile_revision IS NOT NULL)
    ),
    CHECK (
        (persona_snapshot_id IS NULL AND persona_snapshot_revision IS NULL)
        OR (persona_snapshot_id IS NOT NULL AND persona_snapshot_revision IS NOT NULL)
    ),

    PRIMARY KEY (account_id, space_id, room_id),

    FOREIGN KEY (account_id, space_id, room_id)
        REFERENCES room (account_id, space_id, room_id)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT,

    FOREIGN KEY (account_id, space_id, engine_profile_id, engine_profile_revision)
        REFERENCES engine_profile
            (account_id, space_id, engine_profile_id, profile_revision)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT,

    FOREIGN KEY (account_id, space_id, persona_snapshot_id, persona_snapshot_revision)
        REFERENCES persona_snapshot
            (account_id, space_id, persona_snapshot_id, snapshot_revision)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT
);
