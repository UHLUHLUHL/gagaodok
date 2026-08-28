-- M05 — attachment metadata and the bubble reference it completes
--
-- Physical migration 0006, logical stage M05. Two things happen here and they
-- have to happen together:
--
--   1. the `attachment` metadata table is created;
--   2. `bubble.attachment_ref_attachment_id`, which M03 had to leave
--      unreferenced because no attachment table existed yet, gains its real
--      account-scoped foreign key.
--
-- Payload bytes never enter D1. R2 holds the encrypted object; this table holds
-- only metadata and the wrapped key (user decision 2, canonical schema 7.1).
-- D1 never decrypts anything here and never inspects AAD, a nonce or a GCM tag.
--
-- Size contract (canonical schema 7.2 as fixed 2026-08-28). The R2 object is the
-- E2EE §7.1 binary envelope stored without Base64, so its fixed overhead is
-- version 1 + alg 1 + key_generation 4 + nonce 12 + GCM tag 16 = 34 bytes:
--
--   MAX_ATTACHMENT_SOURCE_BYTES = 12,582,912
--   MAX_ENCRYPTED_OBJECT_BYTES  = 12,582,946
--   ciphertext_byte_size        = source_byte_size + 34, exactly
--
-- Chunked AEAD would need a different manifest contract and is out of v1 scope,
-- which is why the relation can be an equality rather than a bound.
--
-- Lifecycle: the six states are stored here, but their *order* is not enforced
-- by this migration. A CHECK cannot see the previous row and a transition
-- trigger would duplicate the handler's CAS rules in a second place, so M05
-- stores the enum and the handler owns the edges. A row is never physically
-- deleted for lifecycle reasons; `abandoned`, `tombstoned` and
-- `garbage_collected` stay so audit and dangling-reference checks keep working.
--
-- Why bubble is rebuilt, and why the order below is the only safe one
--
-- SQLite has no ALTER TABLE ... ADD CONSTRAINT, so a new foreign key means
-- create-copy-drop-rename. D1 silently ignores both PRAGMA foreign_keys = OFF
-- and PRAGMA defer_foreign_keys = ON, so the constraints stay live throughout
-- and the order has to be valid on its own. `bubble_extension_field` is the
-- only table that references `bubble` (checkpoint and the turn extension point
-- at `turn`; nothing else points at a bubble, and no trigger exists on either),
-- so the rebuild surface is exactly these two tables.
--
-- A legacy non-null `attachment_ref_attachment_id` cannot have a parent: the
-- attachment table is being created in this very migration. The copy below
-- therefore fails on such a row, and because applyD1Migrations() runs a
-- migration's statements and its ledger row in one transactional batch, the
-- whole thing rolls back. That is deliberate: a placeholder attachment or a
-- silently nulled reference would destroy the fact that a message had a file.
--
-- Local-only. No Cloudflare resource is created by this file.

-- Attachment metadata. Identity is (account_id, attachment_id) with no
-- space_id: one attachment may be referenced from several rooms, and download
-- permission is decided by a valid device token of the same account rather than
-- by the space it came from (canonical schema 7.1). `origin_space_id` records
-- that origin as plaintext metadata without entering any key.
CREATE TABLE attachment (
    account_id           TEXT NOT NULL
                          CHECK (
                              length(account_id) = 36
                              AND length(replace(account_id, '-', '')) = 32
                              AND substr(account_id,  9, 1) = '-'
                              AND substr(account_id, 14, 1) = '-'
                              AND substr(account_id, 19, 1) = '-'
                              AND substr(account_id, 24, 1) = '-'
                              AND account_id NOT GLOB '*[^0-9A-F-]*'
                          ),
    attachment_id        TEXT NOT NULL
                          CHECK (
                              length(attachment_id) = 36
                              AND length(replace(attachment_id, '-', '')) = 32
                              AND substr(attachment_id,  9, 1) = '-'
                              AND substr(attachment_id, 14, 1) = '-'
                              AND substr(attachment_id, 19, 1) = '-'
                              AND substr(attachment_id, 24, 1) = '-'
                              AND attachment_id NOT GLOB '*[^0-9A-F-]*'
                          ),

    origin_space_id      TEXT NOT NULL
                         CHECK (origin_space_id IN ('MAC_SPACE', 'PHONE_SPACE', 'TABLET_SPACE')),

    -- Server-generated and content-free: 'obj/' followed by a canonical
    -- uppercase UUID. A client never chooses this value, and it never appears
    -- in a public URL.
    r2_object_key        TEXT NOT NULL
                         CHECK (
                             length(r2_object_key) = 40
                             AND substr(r2_object_key, 1, 4) = 'obj/'
                             AND length(replace(substr(r2_object_key, 5), '-', '')) = 32
                             AND substr(r2_object_key, 13, 1) = '-'
                             AND substr(r2_object_key, 18, 1) = '-'
                             AND substr(r2_object_key, 23, 1) = '-'
                             AND substr(r2_object_key, 28, 1) = '-'
                             AND substr(r2_object_key, 5) NOT GLOB '*[^0-9A-F-]*'
                         ),

    kind                 TEXT NOT NULL
                         CHECK (kind IN ('attachment', 'avatar')),

    -- Stored, not ordered: see the lifecycle note above.
    state                TEXT NOT NULL
                         CHECK (
                             state IN (
                                 'allocated',
                                 'uploaded',
                                 'ready',
                                 'abandoned',
                                 'tombstoned',
                                 'garbage_collected'
                             )
                         ),

    source_byte_size     INTEGER NOT NULL
                         CHECK (
                             typeof(source_byte_size) = 'integer'
                             AND source_byte_size >= 1
                             AND source_byte_size <= 12582912
                         ),
    ciphertext_byte_size INTEGER NOT NULL
                         CHECK (
                             typeof(ciphertext_byte_size) = 'integer'
                             AND ciphertext_byte_size <= 12582946
                         ),

    -- Lowercase SHA-256 hex. D1 compares bytes; it never recomputes the hash
    -- and never uses it as an authenticity check — that is the AEAD tag's job,
    -- and only the downloading client verifies that.
    ciphertext_hash      TEXT NOT NULL
                         CHECK (
                             length(ciphertext_hash) = 64
                             AND ciphertext_hash NOT GLOB '*[^0-9a-f]*'
                         ),

    key_generation       INTEGER NOT NULL
                         CHECK (key_generation = 1),

    -- Opaque envelopes, required: an attachment with no wrapped file key could
    -- never be decrypted, and one with no name or type is not a file.
    file_name_enc        TEXT NOT NULL,
    mime_type_enc        TEXT NOT NULL,
    wrapped_file_key_enc TEXT NOT NULL,

    created_at           TEXT NOT NULL,
    server_seq           INTEGER
                         CHECK (
                             server_seq IS NULL
                             OR (
                                 typeof(server_seq) = 'integer'
                                 AND server_seq >= 1
                                 AND server_seq <= 9007199254740991
                             )
                         ),

    -- The equality, not a bound: v1 encrypts an attachment as one AEAD message
    -- with a fixed 34-byte overhead.
    CHECK (ciphertext_byte_size = source_byte_size + 34),

    PRIMARY KEY (account_id, attachment_id),

    -- One object path per account. Two metadata rows pointing at one R2 object
    -- would make deletion and garbage collection ambiguous.
    UNIQUE (account_id, r2_object_key),

    FOREIGN KEY (account_id) REFERENCES account (account_id)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT
);

-- Step 2 — the rebuilt bubble. Every column, CHECK, key and unique constraint
-- is the 0004 definition unchanged; the only addition is the attachment
-- foreign key at the end.
CREATE TABLE bubble_staging (
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
        ON UPDATE RESTRICT,

    -- The one addition of this migration. account_id leads the referenced key,
    -- so a bubble can only ever name an attachment of its own account.
    FOREIGN KEY (account_id, attachment_ref_attachment_id)
        REFERENCES attachment (account_id, attachment_id)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT
);

-- Step 3 — copy. Columns are listed explicitly on both sides: a SELECT * would
-- silently depend on declaration order matching. A legacy non-null reference
-- has no parent attachment and fails here, rolling back the whole migration.
INSERT INTO bubble_staging (
    account_id,
    space_id,
    room_id,
    worldline_key,
    turn_id,
    message_id,
    bubble_order,
    sender_enc,
    kind_enc,
    text_enc,
    speaker_ref_enc,
    reactions_enc,
    attachment_ref_attachment_id,
    attachment_ref_byte_size,
    timestamp,
    revision,
    server_seq,
    is_tombstoned,
    tombstoned_at,
    tombstone_operation_id
)
SELECT
    account_id,
    space_id,
    room_id,
    worldline_key,
    turn_id,
    message_id,
    bubble_order,
    sender_enc,
    kind_enc,
    text_enc,
    speaker_ref_enc,
    reactions_enc,
    attachment_ref_attachment_id,
    attachment_ref_byte_size,
    timestamp,
    revision,
    server_seq,
    is_tombstoned,
    tombstoned_at,
    tombstone_operation_id
FROM bubble;

-- Step 4 — the child, pointed at the staging parent for now. The rename in
-- step 8 makes SQLite rewrite this reference to `bubble`.
CREATE TABLE bubble_extension_field_staging (
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
        REFERENCES bubble_staging (account_id, space_id, room_id, worldline_key, turn_id, message_id)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT
);

-- Step 5 — copy the extension rows.
INSERT INTO bubble_extension_field_staging (
    account_id,
    space_id,
    room_id,
    worldline_key,
    turn_id,
    message_id,
    extension_key,
    envelope_enc
)
SELECT
    account_id,
    space_id,
    room_id,
    worldline_key,
    turn_id,
    message_id,
    extension_key,
    envelope_enc
FROM bubble_extension_field;

-- Steps 6 and 7 — child before parent. The reverse order would violate the old
-- child's foreign key, and no PRAGMA can suspend it on D1.
DROP TABLE bubble_extension_field;

DROP TABLE bubble;

-- Steps 8 and 9 — the staging tables take the canonical names.
ALTER TABLE bubble_staging RENAME TO bubble;

ALTER TABLE bubble_extension_field_staging RENAME TO bubble_extension_field;
