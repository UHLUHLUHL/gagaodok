-- Local rate-limit persistence for public and authenticated HTTP routes.
-- Stores only a keyed hash of the request address, never the address itself.
-- The production RATE_LIMIT_MAC_KEY is a Worker secret supplied only at the
-- later remote connection gate; local tests use the non-secret placeholder.

CREATE TABLE rate_limit_bucket (
    scope         TEXT NOT NULL CHECK (scope IN (
                      'enrollment', 'recovery', 'pairing_session',
                      'pairing_claim', 'pairing_approve', 'pairing_redeem',
                      'sync_write', 'sync_read', 'attachment'
                  )),
    subject_hash  TEXT NOT NULL CHECK (
                      length(subject_hash) = 64
                      AND subject_hash NOT GLOB '*[^0-9a-f]*'
                  ),
    window_start  INTEGER NOT NULL CHECK (window_start >= 0),
    request_count INTEGER NOT NULL CHECK (request_count >= 1),
    PRIMARY KEY (scope, subject_hash, window_start)
);

CREATE INDEX rate_limit_bucket_by_window ON rate_limit_bucket (window_start);
