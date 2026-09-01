-- Room-family origin, enforce phase.
--
-- The compatible Worker normalizes every create before this migration lands.
-- Backfill once more for rows written by an older Worker during the deployment
-- window, prove the whole existing graph is coherent, then enforce future
-- inserts and identity immutability with triggers. No table rebuild and no FK
-- PRAGMA are used.

UPDATE room
   SET origin_space_id = space_id
 WHERE origin_space_id IS NULL;

CREATE TABLE _room_origin_migration_guard (
    ok INTEGER NOT NULL CHECK (ok = 1)
);

INSERT INTO _room_origin_migration_guard (ok)
SELECT CASE WHEN EXISTS (
    SELECT 1
      FROM room AS shard
     WHERE
       NOT (
         (shard.origin_space_id = 'PHONE_SPACE' AND shard.space_id = 'PHONE_SPACE')
         OR (shard.origin_space_id = 'MAC_SPACE' AND shard.space_id IN ('MAC_SPACE', 'PHONE_SPACE'))
         OR (shard.origin_space_id = 'TABLET_SPACE' AND shard.space_id IN ('TABLET_SPACE', 'MAC_SPACE', 'PHONE_SPACE'))
       )
       OR EXISTS (
         SELECT 1
           FROM room AS sibling
          WHERE sibling.account_id = shard.account_id
            AND sibling.room_id = shard.room_id
            AND sibling.origin_space_id <> shard.origin_space_id
       )
       OR (
         shard.space_id <> shard.origin_space_id
         AND NOT EXISTS (
           SELECT 1
             FROM room AS origin
            WHERE origin.account_id = shard.account_id
              AND origin.space_id = shard.origin_space_id
              AND origin.room_id = shard.room_id
              AND origin.origin_space_id = shard.origin_space_id
         )
       )
) THEN 0 ELSE 1 END;

DROP TABLE _room_origin_migration_guard;

CREATE TRIGGER room_origin_insert_guard
BEFORE INSERT ON room
WHEN
  NEW.origin_space_id IS NULL
  OR NOT (
    (NEW.origin_space_id = 'PHONE_SPACE' AND NEW.space_id = 'PHONE_SPACE')
    OR (NEW.origin_space_id = 'MAC_SPACE' AND NEW.space_id IN ('MAC_SPACE', 'PHONE_SPACE'))
    OR (NEW.origin_space_id = 'TABLET_SPACE' AND NEW.space_id IN ('TABLET_SPACE', 'MAC_SPACE', 'PHONE_SPACE'))
  )
  OR EXISTS (
    SELECT 1 FROM room AS sibling
     WHERE sibling.account_id = NEW.account_id
       AND sibling.room_id = NEW.room_id
       AND sibling.origin_space_id <> NEW.origin_space_id
  )
  OR (
    NEW.space_id <> NEW.origin_space_id
    AND NOT EXISTS (
      SELECT 1 FROM room AS origin
       WHERE origin.account_id = NEW.account_id
         AND origin.space_id = NEW.origin_space_id
         AND origin.room_id = NEW.room_id
         AND origin.origin_space_id = NEW.origin_space_id
    )
  )
BEGIN
  SELECT RAISE(ABORT, 'room origin invariant');
END;

CREATE TRIGGER room_origin_identity_immutable
BEFORE UPDATE OF account_id, space_id, room_id, origin_space_id ON room
WHEN
  NEW.account_id <> OLD.account_id
  OR NEW.space_id <> OLD.space_id
  OR NEW.room_id <> OLD.room_id
  OR NEW.origin_space_id <> OLD.origin_space_id
  OR NEW.origin_space_id IS NULL
BEGIN
  SELECT RAISE(ABORT, 'room origin identity is immutable');
END;
