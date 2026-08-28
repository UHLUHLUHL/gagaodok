-- M06 — atomic write ledger
--
-- Physical migration 0008 and the first physical migration of logical M06.
-- 0007 was the cross-cutting device authentication column, not an M-stage.
--
-- Three things arrive together because none of them is useful alone: the
-- account-wide sequence that orders every change, the two ledgers that record
-- what an operation did, and the scratch table that lets a single D1 batch
-- fail closed on a compare-and-set.
--
-- No handler is implemented here. This migration only makes the shapes
-- storable and the invalid ones unstorable.
--
-- Nothing in this file holds a request body, a token, ciphertext, an envelope
-- or object content. The ledger records identity, ordering and a fingerprint;
-- the replay response is rebuilt from those columns alone (API draft §5.3.1).
--
-- Local-only. No Cloudflare resource is created by this file.

-- The next unallocated sequence, not the last allocated one (API draft §5.3).
-- A handler writes the current value into the canonical row and both ledgers
-- and increments it at the end of the same batch, so a failed batch consumes
-- nothing.
--
-- The column is added, not rebuilt: ALTER TABLE ADD COLUMN is not a constraint
-- change, so every foreign key pointing at account survives untouched. D1
-- ignores PRAGMA foreign_keys = OFF, so a rebuild here would have had to keep
-- them satisfied throughout.
--
-- Allocatable values are 1..2^53-1. The internal range is one larger: 2^53 is
-- the exhausted sentinel, the value the counter reaches after the last real
-- sequence is handed out. It means "there is no next value" and must never
-- appear in a row, a response or a cursor, which is why the two ledgers below
-- stop at 2^53-1 while this column does not.
ALTER TABLE account ADD COLUMN next_server_seq INTEGER NOT NULL DEFAULT 1
    CHECK (
        typeof(next_server_seq) = 'integer'
        AND next_server_seq >= 1
        AND next_server_seq <= 9007199254740992
    );

-- Operation idempotency. The primary key is the idempotency guarantee: a
-- retried operation cannot insert twice, so it is answered from the row that is
-- already there.
--
-- Only the fingerprint of the raw request body is kept, never the body. That is
-- enough for the one question replay asks — "is this the same request?" — and
-- it cannot leak content if the table is ever dumped.
CREATE TABLE operation_log (
    account_id          TEXT NOT NULL
                        CHECK (
                            length(account_id) = 36
                            AND length(replace(account_id, '-', '')) = 32
                            AND substr(account_id,  9, 1) = '-'
                            AND substr(account_id, 14, 1) = '-'
                            AND substr(account_id, 19, 1) = '-'
                            AND substr(account_id, 24, 1) = '-'
                            AND account_id NOT GLOB '*[^0-9A-F-]*'
                        ),
    operation_id        TEXT NOT NULL
                        CHECK (
                            length(operation_id) = 36
                            AND length(replace(operation_id, '-', '')) = 32
                            AND substr(operation_id,  9, 1) = '-'
                            AND substr(operation_id, 14, 1) = '-'
                            AND substr(operation_id, 19, 1) = '-'
                            AND substr(operation_id, 24, 1) = '-'
                            AND operation_id NOT GLOB '*[^0-9A-F-]*'
                        ),

    -- Lowercase SHA-256 hex of the original request bytes, computed before
    -- validation. A semantically equal request that was re-serialised has
    -- different bytes and is a replay mismatch, not a replay.
    request_fingerprint TEXT NOT NULL
                        CHECK (
                            length(request_fingerprint) = 64
                            AND request_fingerprint NOT GLOB '*[^0-9a-f]*'
                        ),

    entity_type         TEXT NOT NULL
                        CHECK (
                            entity_type IN (
                                'room', 'persona_snapshot', 'engine_profile', 'checkpoint',
                                 'turn', 'bubble', 'group_state', 'worldline', 'attachment'
                            )
                        ),
    change_kind         TEXT NOT NULL
                        CHECK (change_kind IN ('upsert', 'tombstone')),

    -- Null exactly when the projection has no revision of its own. attachment
    -- is the only such entity in v1; giving it a number would be inventing one.
    result_revision     INTEGER
                        CHECK (
                            result_revision IS NULL
                            OR (
                                typeof(result_revision) = 'integer'
                                AND result_revision >= 0
                                AND result_revision <= 9007199254740991
                            )
                        ),

    server_seq          INTEGER NOT NULL
                        CHECK (
                            typeof(server_seq) = 'integer'
                            AND server_seq >= 1
                            AND server_seq <= 9007199254740991
                        ),

    CHECK (
        (entity_type = 'attachment' AND result_revision IS NULL)
        OR (entity_type <> 'attachment' AND result_revision IS NOT NULL)
    ),

    PRIMARY KEY (account_id, operation_id),

    -- One sequence is consumed by at most one operation. Without this a retry
    -- storm could hand two operations the same cursor position.
    UNIQUE (account_id, server_seq),

    FOREIGN KEY (account_id) REFERENCES account (account_id)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT
);

-- The pull cursor. One successful operation is one sequence and one row
-- (API draft §5.3.1), so the account-wide sequence is also the primary key.
--
-- Identity is stored as plain nullable columns, one per canonical axis. It is
-- deliberately not a JSON blob, a serialized owner key or a sentinel UUID:
-- those would all make the server keep a value it cannot check. Instead one
-- CHECK per entity_type states exactly which axes are present and, just as
-- importantly, which must be absent — so a bubble identity cannot be filed
-- under a room, and an attachment cannot acquire a space.
--
-- There is no foreign key on the identity columns. A polymorphic reference is
-- not expressible in SQLite, and it is not needed: v1 canonical rows are either
-- immutable or tombstone-preserved, physical delete is forbidden, and the
-- handler writes the change row in the same batch as the row it describes.
CREATE TABLE change_log (
    account_id          TEXT NOT NULL
                        CHECK (
                            length(account_id) = 36
                            AND length(replace(account_id, '-', '')) = 32
                            AND substr(account_id,  9, 1) = '-'
                            AND substr(account_id, 14, 1) = '-'
                            AND substr(account_id, 19, 1) = '-'
                            AND substr(account_id, 24, 1) = '-'
                            AND account_id NOT GLOB '*[^0-9A-F-]*'
                        ),
    server_seq          INTEGER NOT NULL
                        CHECK (
                            typeof(server_seq) = 'integer'
                            AND server_seq >= 1
                            AND server_seq <= 9007199254740991
                        ),

    entity_type         TEXT NOT NULL
                        CHECK (
                            entity_type IN (
                                'room', 'persona_snapshot', 'engine_profile', 'checkpoint',
                                 'turn', 'bubble', 'group_state', 'worldline', 'attachment'
                            )
                        ),
    change_kind         TEXT NOT NULL
                        CHECK (change_kind IN ('upsert', 'tombstone')),
    revision            INTEGER
                        CHECK (
                            revision IS NULL
                            OR (
                                typeof(revision) = 'integer'
                                AND revision >= 0
                                AND revision <= 9007199254740991
                            )
                        ),

    -- Identity axes. Which of these are set is decided by entity_type below.
    space_id            TEXT
                        CHECK (
                            space_id IS NULL
                            OR space_id IN ('MAC_SPACE', 'PHONE_SPACE', 'TABLET_SPACE')
                        ),
    room_id             TEXT
                        CHECK (
                            room_id IS NULL
                            OR (
                                length(room_id) = 36
                                AND length(replace(room_id, '-', '')) = 32
                                AND substr(room_id,  9, 1) = '-'
                                AND substr(room_id, 14, 1) = '-'
                                AND substr(room_id, 19, 1) = '-'
                                AND substr(room_id, 24, 1) = '-'
                                AND room_id NOT GLOB '*[^0-9A-F-]*'
                            )
                        ),
    -- The D1 storage key, not the API value: '' is the default worldline of a
    -- scope, and the projection turns it back into a null worldline_id.
    worldline_key       TEXT
                        CHECK (
                            worldline_key IS NULL
                            OR worldline_key = ''
                            OR (
                                length(worldline_key) = 36
                                AND length(replace(worldline_key, '-', '')) = 32
                                AND substr(worldline_key,  9, 1) = '-'
                                AND substr(worldline_key, 14, 1) = '-'
                                AND substr(worldline_key, 19, 1) = '-'
                                AND substr(worldline_key, 24, 1) = '-'
                                AND worldline_key NOT GLOB '*[^0-9A-F-]*'
                            )
                        ),
    turn_id             TEXT
                        CHECK (
                            turn_id IS NULL
                            OR (
                                length(turn_id) = 36
                                AND length(replace(turn_id, '-', '')) = 32
                                AND substr(turn_id,  9, 1) = '-'
                                AND substr(turn_id, 14, 1) = '-'
                                AND substr(turn_id, 19, 1) = '-'
                                AND substr(turn_id, 24, 1) = '-'
                                AND turn_id NOT GLOB '*[^0-9A-F-]*'
                            )
                        ),
    message_id          TEXT
                        CHECK (
                            message_id IS NULL
                            OR (
                                length(message_id) = 36
                                AND length(replace(message_id, '-', '')) = 32
                                AND substr(message_id,  9, 1) = '-'
                                AND substr(message_id, 14, 1) = '-'
                                AND substr(message_id, 19, 1) = '-'
                                AND substr(message_id, 24, 1) = '-'
                                AND message_id NOT GLOB '*[^0-9A-F-]*'
                            )
                        ),
    persona_snapshot_id TEXT
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
    snapshot_revision   INTEGER
                        CHECK (
                            snapshot_revision IS NULL
                            OR (
                                typeof(snapshot_revision) = 'integer'
                                AND snapshot_revision >= 1
                                AND snapshot_revision <= 9007199254740991
                            )
                        ),
    engine_profile_id   TEXT
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
    profile_revision    INTEGER
                        CHECK (
                            profile_revision IS NULL
                            OR (
                                typeof(profile_revision) = 'integer'
                                AND profile_revision >= 1
                                AND profile_revision <= 9007199254740991
                            )
                        ),
    checkpoint_id       TEXT
                        CHECK (
                            checkpoint_id IS NULL
                            OR (
                                length(checkpoint_id) = 36
                                AND length(replace(checkpoint_id, '-', '')) = 32
                                AND substr(checkpoint_id,  9, 1) = '-'
                                AND substr(checkpoint_id, 14, 1) = '-'
                                AND substr(checkpoint_id, 19, 1) = '-'
                                AND substr(checkpoint_id, 24, 1) = '-'
                                AND checkpoint_id NOT GLOB '*[^0-9A-F-]*'
                            )
                        ),
    attachment_id       TEXT
                        CHECK (
                            attachment_id IS NULL
                            OR (
                                length(attachment_id) = 36
                                AND length(replace(attachment_id, '-', '')) = 32
                                AND substr(attachment_id,  9, 1) = '-'
                                AND substr(attachment_id, 14, 1) = '-'
                                AND substr(attachment_id, 19, 1) = '-'
                                AND substr(attachment_id, 24, 1) = '-'
                                AND attachment_id NOT GLOB '*[^0-9A-F-]*'
                            )
                        ),

    CHECK (
        (entity_type = 'attachment' AND revision IS NULL)
        OR (entity_type <> 'attachment' AND revision IS NOT NULL)
    ),

    -- Exactly one branch matches each entity_type, and each branch names every
    -- axis: the required ones as NOT NULL and every other one as NULL.
    CHECK (
        (entity_type = 'room'
            AND space_id IS NOT NULL
            AND room_id IS NOT NULL
            AND worldline_key IS NULL
            AND turn_id IS NULL
            AND message_id IS NULL
            AND persona_snapshot_id IS NULL
            AND snapshot_revision IS NULL
            AND engine_profile_id IS NULL
            AND profile_revision IS NULL
            AND checkpoint_id IS NULL
            AND attachment_id IS NULL
        )
        OR
        (entity_type = 'group_state'
            AND space_id IS NOT NULL
            AND room_id IS NOT NULL
            AND worldline_key IS NULL
            AND turn_id IS NULL
            AND message_id IS NULL
            AND persona_snapshot_id IS NULL
            AND snapshot_revision IS NULL
            AND engine_profile_id IS NULL
            AND profile_revision IS NULL
            AND checkpoint_id IS NULL
            AND attachment_id IS NULL
        )
        OR
        (entity_type = 'worldline'
            AND space_id IS NOT NULL
            AND room_id IS NOT NULL
            AND worldline_key IS NOT NULL
            AND turn_id IS NULL
            AND message_id IS NULL
            AND persona_snapshot_id IS NULL
            AND snapshot_revision IS NULL
            AND engine_profile_id IS NULL
            AND profile_revision IS NULL
            AND checkpoint_id IS NULL
            AND attachment_id IS NULL
        )
        OR
        (entity_type = 'turn'
            AND space_id IS NOT NULL
            AND room_id IS NOT NULL
            AND worldline_key IS NOT NULL
            AND turn_id IS NOT NULL
            AND message_id IS NULL
            AND persona_snapshot_id IS NULL
            AND snapshot_revision IS NULL
            AND engine_profile_id IS NULL
            AND profile_revision IS NULL
            AND checkpoint_id IS NULL
            AND attachment_id IS NULL
        )
        OR
        (entity_type = 'bubble'
            AND space_id IS NOT NULL
            AND room_id IS NOT NULL
            AND worldline_key IS NOT NULL
            AND turn_id IS NOT NULL
            AND message_id IS NOT NULL
            AND persona_snapshot_id IS NULL
            AND snapshot_revision IS NULL
            AND engine_profile_id IS NULL
            AND profile_revision IS NULL
            AND checkpoint_id IS NULL
            AND attachment_id IS NULL
        )
        OR
        (entity_type = 'persona_snapshot'
            AND space_id IS NOT NULL
            AND persona_snapshot_id IS NOT NULL
            AND snapshot_revision IS NOT NULL
            AND room_id IS NULL
            AND worldline_key IS NULL
            AND turn_id IS NULL
            AND message_id IS NULL
            AND engine_profile_id IS NULL
            AND profile_revision IS NULL
            AND checkpoint_id IS NULL
            AND attachment_id IS NULL
        )
        OR
        (entity_type = 'engine_profile'
            AND space_id IS NOT NULL
            AND engine_profile_id IS NOT NULL
            AND profile_revision IS NOT NULL
            AND room_id IS NULL
            AND worldline_key IS NULL
            AND turn_id IS NULL
            AND message_id IS NULL
            AND persona_snapshot_id IS NULL
            AND snapshot_revision IS NULL
            AND checkpoint_id IS NULL
            AND attachment_id IS NULL
        )
        OR
        (entity_type = 'checkpoint'
            AND space_id IS NOT NULL
            AND room_id IS NOT NULL
            AND worldline_key IS NOT NULL
            AND checkpoint_id IS NOT NULL
            AND turn_id IS NULL
            AND message_id IS NULL
            AND persona_snapshot_id IS NULL
            AND snapshot_revision IS NULL
            AND engine_profile_id IS NULL
            AND profile_revision IS NULL
            AND attachment_id IS NULL
        )
        OR
        (entity_type = 'attachment'
            AND attachment_id IS NOT NULL
            AND space_id IS NULL
            AND room_id IS NULL
            AND worldline_key IS NULL
            AND turn_id IS NULL
            AND message_id IS NULL
            AND persona_snapshot_id IS NULL
            AND snapshot_revision IS NULL
            AND engine_profile_id IS NULL
            AND profile_revision IS NULL
            AND checkpoint_id IS NULL
        )
    ),

    -- A worldline row is named by its own id, so the empty default key is not
    -- a worldline. turn, bubble and checkpoint keep using it for their scope.
    CHECK (entity_type <> 'worldline' OR worldline_key <> ''),

    PRIMARY KEY (account_id, server_seq),

    FOREIGN KEY (account_id) REFERENCES account (account_id)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT
);

-- The scratch table that turns a compare-and-set into something a batch can
-- fail on.
--
-- D1 runs a batch as one transaction and rolls the whole thing back when a
-- statement fails — but a CAS expressed as `UPDATE ... WHERE revision = ?`
-- simply updates zero rows and the batch succeeds. So the handler first inserts
-- the predicate's result here:
--
--   INSERT INTO transaction_guard (account_id, operation_id, ok)
--   VALUES (?, ?, ((SELECT revision FROM room WHERE ...) = ?));
--
-- A matching revision yields 1 and the row inserts. A mismatch yields 0 and
-- CHECK (ok = 1) aborts. A missing entity makes the scalar subquery NULL, and
-- NOT NULL aborts. Two different failures, both fatal to the batch, and neither
-- leaves a row behind because the transaction rolls back.
--
-- The key is (account_id, operation_id) so two concurrent operations of one
-- account never collide on it. The handler deletes its row at the end of a
-- successful batch; the table is permanent schema, the rows are not.
CREATE TABLE transaction_guard (
    account_id   TEXT NOT NULL
                 CHECK (
                     length(account_id) = 36
                     AND length(replace(account_id, '-', '')) = 32
                     AND substr(account_id,  9, 1) = '-'
                     AND substr(account_id, 14, 1) = '-'
                     AND substr(account_id, 19, 1) = '-'
                     AND substr(account_id, 24, 1) = '-'
                     AND account_id NOT GLOB '*[^0-9A-F-]*'
                 ),
    operation_id TEXT NOT NULL
                 CHECK (
                     length(operation_id) = 36
                     AND length(replace(operation_id, '-', '')) = 32
                     AND substr(operation_id,  9, 1) = '-'
                     AND substr(operation_id, 14, 1) = '-'
                     AND substr(operation_id, 19, 1) = '-'
                     AND substr(operation_id, 24, 1) = '-'
                     AND operation_id NOT GLOB '*[^0-9A-F-]*'
                 ),
    ok           INTEGER NOT NULL
                 CHECK (ok = 1),

    PRIMARY KEY (account_id, operation_id),

    FOREIGN KEY (account_id) REFERENCES account (account_id)
        ON DELETE RESTRICT
        ON UPDATE RESTRICT
);
