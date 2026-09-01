-- Room-family origin, expand phase.
--
-- This migration is intentionally additive and keeps the new column nullable.
-- During the compatibility deployment window an older Worker may still create
-- a room without the new metadata; 0012 backfills that gap and enforces the
-- final invariant only after the compatible Worker is live.

ALTER TABLE room ADD COLUMN origin_space_id TEXT
  CHECK (
    origin_space_id IS NULL
    OR origin_space_id IN ('MAC_SPACE', 'PHONE_SPACE', 'TABLET_SPACE')
  );

UPDATE room
   SET origin_space_id = space_id
 WHERE origin_space_id IS NULL;
