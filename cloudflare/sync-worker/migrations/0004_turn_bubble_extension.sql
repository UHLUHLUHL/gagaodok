-- M03 — turns, bubbles and extension fields
--
-- Physical migration 0004, logical stage M03. 0001+0002 were M01 (account
-- boundary) and 0003 was M02 (room, group_state, worldline).
--
-- Deliberately absent, each belonging to a later stage:
--   * engine_profile, persona_snapshot, persona_snapshot_head, checkpoint,
--     persona_snapshot_extension_field                       (M04)
--   * attachment                                             (M05)
--   * operation_log, change_log, account.next_server_seq     (M06)
-- `server_seq` is a per-row column here because canonical schema 14.1 gives the
-- row that shape, but nothing allocates one yet: the account sequence and the
-- ledger arrive with M06, so the column stays nullable and unwritten.
--
-- Every table is new, so there is no rebuild, no copy/drop/rename, and the only
-- ordering requirement is parent-before-child: room (0003) → turn → bubble, and
-- each extension table after its owner. That matters because D1 silently
-- ignores both `PRAGMA foreign_keys = OFF` and `PRAGMA defer_foreign_keys = ON`
-- — no migration here may assume foreign keys can be suspended.
--
-- All foreign keys are RESTRICT on delete and update. v1 removes conversation
-- content by tombstone, never physically (canonical schema 9.1), so a cascade
-- would be the wrong shape as well as unsafe.
--
-- What this file does not do: it never decodes, re-encodes or normalises an
-- `_enc` envelope, never assembles or checks AAD, and never looks at a nonce or
-- an AEAD tag. There is no trigger in this migration at all — clearing content
-- when a row is tombstoned, applying CAS, and the atomicity of a set/clear with
-- its parent row are all M06 handler responsibilities.
--
-- Local-only. No Cloudflare resource is created by this file.

-- Turn. Identity is the conversation scope plus turn_id (canonical schema
-- 14.1). `worldline_key` is the materialised non-null key column introduced in
-- 0003: the API and AAD keep using the nullable `worldline_id`, but SQLite does
-- not compare NULLs equal, so the key column is what the primary key can use
-- (canonical schema 14.2).
--
-- There is no foreign key to `worldline`. A default worldline has no row of its
-- own, and MAC_SPACE/TABLET_SPACE rooms have no worldline table entries at all
-- (canonical schema 11), so the room reference is the scope constraint.
CREATE TABLE turn (
    account_id                 TEXT NOT NULL
                               -- Canonical uppercase hyphenated UUID (E2EE
                               -- proposal 12.3), spelled with length/substr and
                               -- one short negated class because a
                               -- per-character GLOB class exceeds SQLite's
                               -- pattern-complexity limit.
                               CHECK (
                                   length(account_id) = 36
                                   AND length(replace(account_id, '-', '')) = 32
                                   AND substr(account_id,  9, 1) = '-'
                                   AND substr(account_id, 14, 1) = '-'
                                   AND substr(account_id, 19, 1) = '-'
                                   AND substr(account_id, 24, 1) = '-'
                                   AND account_id NOT GLOB '*[^0-9A-F-]*'
                               ),
    space_id                   TEXT NOT NULL
                               CHECK (space_id IN ('MAC_SPACE', 'PHONE_SPACE', 'TABLET_SPACE')),
    room_id                    TEXT NOT NULL
                               CHECK (
                                   length(room_id) = 36
                                   AND length(replace(room_id, '-', '')) = 32
                                   AND substr(room_id,  9, 1) = '-'
                                   AND substr(room_id, 14, 1) = '-'
                                   AND substr(room_id, 19, 1) = '-'
                                   AND substr(room_id, 24, 1) = '-'
                                   AND room_id NOT GLOB '*[^0-9A-F-]*'
                               ),
    worldline_id               TEXT
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
    worldline_key              TEXT NOT NULL
                               CHECK (worldline_key = COALESCE(worldline_id, '')),
    turn_id                    TEXT NOT NULL
                               CHECK (
                                   length(turn_id) = 36
                                   AND length(replace(turn_id, '-', '')) = 32
                                   AND substr(turn_id,  9, 1) = '-'
                                   AND substr(turn_id, 14, 1) = '-'
                                   AND substr(turn_id, 19, 1) = '-'
                                   AND substr(turn_id, 24, 1) = '-'
                                   AND turn_id NOT GLOB '*[^0-9A-F-]*'
                               ),

    -- Turn-level source of truth (canonical schema 3.4), each its own opaque
    -- envelope. `_enc` marks a column D1 stores verbatim and never inspects.
    canonical_text_enc         TEXT,
    heart_changes_enc          TEXT,
    generation_profile_ref_enc TEXT,
    fallback_reason_enc        TEXT,

    -- Provenance, not authority: write permission is decided elsewhere
    -- (canonical schema 5.1). The reference is to a device of this same
    -- account, so a turn can never name another tenant's device.
    created_by_device_id       TEXT NOT NULL
                               CHECK (
                                   length(created_by_device_id) = 36
                                   AND length(replace(created_by_device_id, '-', '')) = 32
                                   AND substr(created_by_device_id,  9, 1) = '-'
                                   AND substr(created_by_device_id, 14, 1) = '-'
                                   AND substr(created_by_device_id, 19, 1) = '-'
                                   AND substr(created_by_device_id, 24, 1) = '-'
                                   AND created_by_device_id NOT GLOB '*[^0-9A-F-]*'
                               ),
    created_at                 TEXT NOT NULL,

    revision                   INTEGER NOT NULL DEFAULT 0
                               CHECK (revision >= 0),
    server_seq                 INTEGER
                               CHECK (server_seq IS NULL OR server_seq > 0),

    -- Soft delete (canonical schema 9.1). A tombstoned row keeps its identity;
    -- blanking the encrypted columns is the handler's job, not a trigger's.
    is_tombstoned              INTEGER NOT NULL DEFAULT 0
                               CHECK (is_tombstoned IN (0, 1)),
    tombstoned_at              TEXT,
    tombstone_operation_id     TEXT
                               CHECK (
                                   tombstone_operation_id IS NULL
                                   OR (
                                       length(tombstone_operation_id) = 36
                                       AND length(replace(tombstone_operation_id, '-', '')) = 32
                                       AND substr(tombstone_operation_id,  9, 1) = '-'
                                       AND substr(tombstone_operation_id, 14, 1) = '-'
                                       AND substr(tombstone_operation_id, 19, 1) = '-'
                                       AND substr(tombstone_operation_id, 24, 1) = '-'
                                       AND tombstone_operation_id NOT GLOB '*[^0-9A-F-]*'
                                   )
                               ),

    -- All three tombstone columns move together. Half-written metadata would
    -- make "is this row deleted" depend on which column you looked at.
    CHECK (
        (is_tombstoned = 0
            AND tombstoned_at IS NULL
            AND tombstone_operation_id IS NULL)
        OR (is_tombstoned = 1
            AND tombstoned_at IS NOT NULL
            AND tombstone_operation_id IS NOT NULL)
    ),

    -- A named worldline exists only on the phone (canonical schema 11): Mac and
    -- tablet have no worldline entity at all. The default worldline is the null
    -- id, so it stays legal in every canonical space. The Worker refuses the
    -- same pair on the wire; this CHECK is what makes it true of the database.
    CHECK (worldline_id IS NULL OR space_id = 'PHONE_SPACE'),

    PRIMARY KEY (account_id, space_id, room_id, worldline_key, turn_id),

    FOREIGN KEY (account_id, space_id, room_id)
        REFERENCES room (account_id, space_id, room_id)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT,

    FOREIGN KEY (account_id, created_by_device_id)
        REFERENCES device (account_id, device_id)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT
);

-- Bubble. The primary key is the turn identity plus message_id, but two extra
-- scope-wide unique constraints carry rules the primary key cannot express:
--
--   * a message_id is unique in the whole conversation scope, not merely inside
--     one turn, so the same message cannot be filed under two turns;
--   * bubble_order is unique scope-wide and tombstoned rows keep participating,
--     so a deleted bubble's number is retired for good (canonical schema 2 and
--     9.1). Reusing it would break the AAD of the surviving ciphertext.
CREATE TABLE bubble (
    account_id                   TEXT NOT NULL
                                 CHECK (
                                     length(account_id) = 36
                                     AND length(replace(account_id, '-', '')) = 32
                                     AND substr(account_id,  9, 1) = '-'
                                     AND substr(account_id, 14, 1) = '-'
                                     AND substr(account_id, 19, 1) = '-'
                                     AND substr(account_id, 24, 1) = '-'
                                     AND account_id NOT GLOB '*[^0-9A-F-]*'
                                 ),
    space_id                     TEXT NOT NULL
                                 CHECK (space_id IN ('MAC_SPACE', 'PHONE_SPACE', 'TABLET_SPACE')),
    room_id                      TEXT NOT NULL
                                 CHECK (
                                     length(room_id) = 36
                                     AND length(replace(room_id, '-', '')) = 32
                                     AND substr(room_id,  9, 1) = '-'
                                     AND substr(room_id, 14, 1) = '-'
                                     AND substr(room_id, 19, 1) = '-'
                                     AND substr(room_id, 24, 1) = '-'
                                     AND room_id NOT GLOB '*[^0-9A-F-]*'
                                 ),
    -- The bubble's scope is the turn's scope; the turn reference below is what
    -- keeps the two in agreement, so `worldline_id` is not repeated here.
    worldline_key                TEXT NOT NULL,
    turn_id                      TEXT NOT NULL,
    message_id                   TEXT NOT NULL
                                 CHECK (
                                     length(message_id) = 36
                                     AND length(replace(message_id, '-', '')) = 32
                                     AND substr(message_id,  9, 1) = '-'
                                     AND substr(message_id, 14, 1) = '-'
                                     AND substr(message_id, 19, 1) = '-'
                                     AND substr(message_id, 24, 1) = '-'
                                     AND message_id NOT GLOB '*[^0-9A-F-]*'
                                 ),

    -- 0 .. 2^53-1. The upper bound is JavaScript's safe integer limit, not
    -- SQLite's: the value is carried through the Worker as a Number and is part
    -- of the AAD, so a value D1 could store but JS would round is refused here
    -- rather than silently changing meaning (canonical schema 2).
    -- `typeof` rejects a real or a string that INTEGER affinity did not convert.
    bubble_order                 INTEGER NOT NULL
                                 CHECK (
                                     typeof(bubble_order) = 'integer'
                                     AND bubble_order >= 0
                                     AND bubble_order <= 9007199254740991
                                 ),

    sender_enc                   TEXT,
    kind_enc                     TEXT,
    text_enc                     TEXT,
    speaker_ref_enc              TEXT,
    reactions_enc                TEXT,

    -- R2 identity and byte size only. Filename, MIME type and payload are
    -- encrypted content and never become plaintext columns (canonical schema
    -- 3.4). No foreign key: the attachment table is M05.
    attachment_ref_attachment_id TEXT
                                 CHECK (
                                     attachment_ref_attachment_id IS NULL
                                     OR (
                                         length(attachment_ref_attachment_id) = 36
                                         AND length(replace(attachment_ref_attachment_id, '-', '')) = 32
                                         AND substr(attachment_ref_attachment_id,  9, 1) = '-'
                                         AND substr(attachment_ref_attachment_id, 14, 1) = '-'
                                         AND substr(attachment_ref_attachment_id, 19, 1) = '-'
                                         AND substr(attachment_ref_attachment_id, 24, 1) = '-'
                                         AND attachment_ref_attachment_id NOT GLOB '*[^0-9A-F-]*'
                                     )
                                 ),
    attachment_ref_byte_size     INTEGER
                                 CHECK (attachment_ref_byte_size IS NULL OR attachment_ref_byte_size >= 0),
    timestamp                    TEXT NOT NULL,
    revision                     INTEGER NOT NULL DEFAULT 0
                                 CHECK (revision >= 0),
    server_seq                   INTEGER
                                 CHECK (server_seq IS NULL OR server_seq > 0),

    is_tombstoned                INTEGER NOT NULL DEFAULT 0
                                 CHECK (is_tombstoned IN (0, 1)),
    tombstoned_at                TEXT,
    tombstone_operation_id       TEXT
                                 CHECK (
                                     tombstone_operation_id IS NULL
                                     OR (
                                         length(tombstone_operation_id) = 36
                                         AND length(replace(tombstone_operation_id, '-', '')) = 32
                                         AND substr(tombstone_operation_id,  9, 1) = '-'
                                         AND substr(tombstone_operation_id, 14, 1) = '-'
                                         AND substr(tombstone_operation_id, 19, 1) = '-'
                                         AND substr(tombstone_operation_id, 24, 1) = '-'
                                         AND tombstone_operation_id NOT GLOB '*[^0-9A-F-]*'
                                     )
                                 ),
    CHECK (
        (is_tombstoned = 0
            AND tombstoned_at IS NULL
            AND tombstone_operation_id IS NULL)
        OR (is_tombstoned = 1
            AND tombstoned_at IS NOT NULL
            AND tombstone_operation_id IS NOT NULL)
    ),

    -- An attachment reference is present or absent as a whole; half of one is
    -- a defect. Stated here because a table constraint must follow every
    -- column definition.
    CHECK (
        (attachment_ref_attachment_id IS NULL AND attachment_ref_byte_size IS NULL)
        OR (attachment_ref_attachment_id IS NOT NULL AND attachment_ref_byte_size IS NOT NULL)
    ),

    PRIMARY KEY (account_id, space_id, room_id, worldline_key, turn_id, message_id),

    -- Every column of these two constraints is NOT NULL, so unlike a nullable
    -- unique key they cannot be satisfied twice by two NULLs.
    UNIQUE (account_id, space_id, room_id, worldline_key, message_id),
    UNIQUE (account_id, space_id, room_id, worldline_key, bubble_order),

    FOREIGN KEY (account_id, space_id, room_id, worldline_key, turn_id)
        REFERENCES turn (account_id, space_id, room_id, worldline_key, turn_id)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT
);

-- Extension fields.
--
-- `extension_field` is a logical family name, not a table. Its owners have
-- different identities, and merging them would need nullable owner columns —
-- which SQLite cannot put in a primary key, since two NULLs are not equal — plus
-- a polymorphic foreign key, which SQLite cannot enforce at all. So each owner
-- gets its own physical table whose primary key starts with the owner's real
-- primary key and whose foreign key is a genuine composite reference
-- (canonical schema 3.3 as decided 2026-08-28). There is no `owner_type`
-- column: the table is the owner type. `persona_snapshot_extension_field`
-- arrives in M04 with its owner.
--
-- The key rule is `<owner>.<entity>.<field>`, three lowercase dotted segments
-- matching [a-z][a-z0-9_]* (canonical schema 3.3). The CHECK below spells that
-- without a regex:
--   * exactly two dots, counted by the length lost to replace();
--   * no character outside [a-z0-9._];
--   * the first character, and the character after each dot, is a letter —
--     which also makes every segment non-empty and refuses a trailing dot.
-- instr() locates the second dot relative to the first, so no segment needs to
-- be split out.
--
-- Each row holds exactly one key and one envelope, so patching one key never
-- re-encrypts another and an unknown key survives byte-identical.
--
-- An extension row is owner-dependent storage, not a canonical entity: it is
-- never an operation target, and set/clear always rides on the owning room,
-- turn or bubble patch. So it carries no revision, no server_seq and no
-- updated_at — CAS and account ordering have exactly one source, the owner row.
-- Applying a set/clear together with the owner's revision bump, the operation
-- log and the change log atomically is the M06 handler's job, not a trigger's.
CREATE TABLE room_extension_field (
    account_id    TEXT NOT NULL,
    space_id      TEXT NOT NULL,
    room_id       TEXT NOT NULL,

    extension_key TEXT NOT NULL
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

    -- Opaque. Required: an extension row without an envelope has no meaning.
    envelope_enc  TEXT NOT NULL,

    PRIMARY KEY (account_id, space_id, room_id, extension_key),

    FOREIGN KEY (account_id, space_id, room_id)
        REFERENCES room (account_id, space_id, room_id)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT
);

CREATE TABLE turn_extension_field (
    account_id    TEXT NOT NULL,
    space_id      TEXT NOT NULL,
    room_id       TEXT NOT NULL,
    worldline_key TEXT NOT NULL,
    turn_id       TEXT NOT NULL,

    extension_key TEXT NOT NULL
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

    envelope_enc  TEXT NOT NULL,

    PRIMARY KEY (account_id, space_id, room_id, worldline_key, turn_id, extension_key),

    FOREIGN KEY (account_id, space_id, room_id, worldline_key, turn_id)
        REFERENCES turn (account_id, space_id, room_id, worldline_key, turn_id)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT
);

CREATE TABLE bubble_extension_field (
    account_id    TEXT NOT NULL,
    space_id      TEXT NOT NULL,
    room_id       TEXT NOT NULL,
    worldline_key TEXT NOT NULL,
    turn_id       TEXT NOT NULL,
    message_id    TEXT NOT NULL,

    extension_key TEXT NOT NULL
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

    envelope_enc  TEXT NOT NULL,

    PRIMARY KEY (
        account_id, space_id, room_id, worldline_key, turn_id, message_id, extension_key
    ),

    FOREIGN KEY (account_id, space_id, room_id, worldline_key, turn_id, message_id)
        REFERENCES bubble (account_id, space_id, room_id, worldline_key, turn_id, message_id)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT
);
