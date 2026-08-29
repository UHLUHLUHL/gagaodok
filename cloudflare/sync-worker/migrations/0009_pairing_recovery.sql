-- Cross-cutting onboarding, pairing and recovery persistence.
--
-- Physical migration 0009 is not a new conversation M-stage. It supplies the
-- security boundary needed to create the first account, connect another device
-- and recover after every linked device is lost. No row stores a raw device
-- token, recovery auth, pairing secret or claim redeem auth.
--
-- Local-only. No Cloudflare resource is created by this file.

CREATE TABLE enrollment_log (
    account_id          TEXT NOT NULL,
    enrollment_id       TEXT NOT NULL
                        CHECK (
                            length(enrollment_id) = 36
                            AND length(replace(enrollment_id, '-', '')) = 32
                            AND substr(enrollment_id, 9, 1) = '-'
                            AND substr(enrollment_id, 14, 1) = '-'
                            AND substr(enrollment_id, 19, 1) = '-'
                            AND substr(enrollment_id, 24, 1) = '-'
                            AND enrollment_id NOT GLOB '*[^0-9A-F-]*'
                        ),
    request_fingerprint TEXT NOT NULL
                        CHECK (
                            length(request_fingerprint) = 64
                            AND request_fingerprint NOT GLOB '*[^0-9a-f]*'
                        ),
    created_at          TEXT NOT NULL,

    PRIMARY KEY (account_id),
    UNIQUE (enrollment_id),
    FOREIGN KEY (account_id) REFERENCES account (account_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT
);

CREATE TABLE recovery_record (
    account_id                  TEXT NOT NULL,
    recovery_version            INTEGER NOT NULL
                                CHECK (
                                    typeof(recovery_version) = 'integer'
                                    AND recovery_version >= 1
                                    AND recovery_version <= 4294967295
                                ),
    recovery_lookup_b64         TEXT NOT NULL
                                CHECK (
                                    length(recovery_lookup_b64) = 44
                                    AND substr(recovery_lookup_b64, 44, 1) = '='
                                    AND recovery_lookup_b64 NOT GLOB '*[^A-Za-z0-9+/=]*'
                                ),
    recovery_auth_verifier      TEXT NOT NULL
                                CHECK (
                                    length(recovery_auth_verifier) = 64
                                    AND recovery_auth_verifier NOT GLOB '*[^0-9a-f]*'
                                ),
    wrapped_master_key_enc      TEXT NOT NULL
                                CHECK (
                                    length(wrapped_master_key_enc) >= 48
                                    AND length(wrapped_master_key_enc) % 4 = 0
                                    AND wrapped_master_key_enc NOT GLOB '*[^A-Za-z0-9+/=]*'
                                ),
    r2_object_key               TEXT NOT NULL
                                CHECK (
                                    length(r2_object_key) = 45
                                    AND substr(r2_object_key, 1, 9) = 'recovery/'
                                    AND substr(r2_object_key, 18, 1) = '-'
                                    AND substr(r2_object_key, 23, 1) = '-'
                                    AND substr(r2_object_key, 28, 1) = '-'
                                    AND substr(r2_object_key, 33, 1) = '-'
                                    AND substr(r2_object_key, 10) NOT GLOB '*[^0-9A-F-]*'
                                ),
    key_generation              INTEGER NOT NULL CHECK (key_generation = 1),
    created_at                  TEXT NOT NULL,
    revoked_at                  TEXT,

    PRIMARY KEY (account_id, recovery_version),
    UNIQUE (recovery_lookup_b64),
    UNIQUE (r2_object_key),
    FOREIGN KEY (account_id) REFERENCES account (account_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT
);

CREATE UNIQUE INDEX recovery_one_active_per_account
    ON recovery_record (account_id)
    WHERE revoked_at IS NULL;

CREATE TABLE pairing_session (
    session_id              TEXT NOT NULL
                            CHECK (
                                length(session_id) = 36
                                AND length(replace(session_id, '-', '')) = 32
                                AND substr(session_id, 9, 1) = '-'
                                AND substr(session_id, 14, 1) = '-'
                                AND substr(session_id, 19, 1) = '-'
                                AND substr(session_id, 24, 1) = '-'
                                AND session_id NOT GLOB '*[^0-9A-F-]*'
                            ),
    account_id              TEXT NOT NULL,
    session_lookup_hash     TEXT NOT NULL
                            CHECK (
                                length(session_lookup_hash) = 64
                                AND session_lookup_hash NOT GLOB '*[^0-9a-f]*'
                            ),
    created_by_device_id    TEXT NOT NULL,
    created_at              TEXT NOT NULL,
    expires_at              TEXT NOT NULL,
    closed_at               TEXT,

    CHECK (expires_at > created_at),
    PRIMARY KEY (session_id),
    UNIQUE (session_lookup_hash),
    UNIQUE (session_id, account_id),
    FOREIGN KEY (account_id, created_by_device_id)
        REFERENCES device (account_id, device_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT
);

CREATE INDEX pairing_session_by_account_open
    ON pairing_session (account_id, expires_at)
    WHERE closed_at IS NULL;

CREATE TABLE pairing_claim (
    session_id                 TEXT NOT NULL,
    account_id                 TEXT NOT NULL,
    claim_id                   TEXT NOT NULL
                               CHECK (
                                   length(claim_id) = 36
                                   AND length(replace(claim_id, '-', '')) = 32
                                   AND substr(claim_id, 9, 1) = '-'
                                   AND substr(claim_id, 14, 1) = '-'
                                   AND substr(claim_id, 19, 1) = '-'
                                   AND substr(claim_id, 24, 1) = '-'
                                   AND claim_id NOT GLOB '*[^0-9A-F-]*'
                               ),
    claim_lookup_b64           TEXT NOT NULL
                               CHECK (
                                   length(claim_lookup_b64) = 44
                                   AND substr(claim_lookup_b64, 44, 1) = '='
                                   AND claim_lookup_b64 NOT GLOB '*[^A-Za-z0-9+/=]*'
                               ),
    claim_envelope             TEXT NOT NULL
                               CHECK (
                                   length(claim_envelope) >= 48
                                   AND length(claim_envelope) % 4 = 0
                                   AND claim_envelope NOT GLOB '*[^A-Za-z0-9+/=]*'
                               ),
    claim_redeem_verifier      TEXT NOT NULL
                               CHECK (
                                   length(claim_redeem_verifier) = 64
                                   AND claim_redeem_verifier NOT GLOB '*[^0-9a-f]*'
                               ),
    state                      TEXT NOT NULL
                               CHECK (state IN ('submitted', 'approved', 'consumed')),
    submitted_at               TEXT NOT NULL,
    approved_at                TEXT,
    consumed_at                TEXT,
    approved_by_device_id      TEXT,
    delivery_envelope          TEXT
                               CHECK (
                                   delivery_envelope IS NULL
                                   OR (
                                       length(delivery_envelope) >= 48
                                       AND length(delivery_envelope) % 4 = 0
                                       AND delivery_envelope NOT GLOB '*[^A-Za-z0-9+/=]*'
                                   )
                               ),
    new_device_id              TEXT,
    new_device_space_id        TEXT
                               CHECK (
                                   new_device_space_id IS NULL
                                   OR new_device_space_id IN ('MAC_SPACE', 'PHONE_SPACE', 'TABLET_SPACE')
                               ),
    new_device_platform        TEXT
                               CHECK (
                                   new_device_platform IS NULL
                                   OR new_device_platform IN ('macos', 'android_phone', 'android_tablet')
                               ),
    new_device_display_name_enc TEXT,
    device_token_hash          TEXT
                               CHECK (
                                   device_token_hash IS NULL
                                   OR (
                                       length(device_token_hash) = 64
                                       AND device_token_hash NOT GLOB '*[^0-9a-f]*'
                                   )
                               ),
    linked_at                  TEXT,

    CHECK (
        (state = 'submitted'
         AND approved_at IS NULL AND consumed_at IS NULL
         AND approved_by_device_id IS NULL AND delivery_envelope IS NULL
         AND new_device_id IS NULL AND new_device_space_id IS NULL
         AND new_device_platform IS NULL AND new_device_display_name_enc IS NULL
         AND device_token_hash IS NULL AND linked_at IS NULL)
        OR
        (state = 'approved'
         AND approved_at IS NOT NULL AND consumed_at IS NULL
         AND approved_by_device_id IS NOT NULL AND delivery_envelope IS NOT NULL
         AND new_device_id IS NOT NULL AND new_device_space_id IS NOT NULL
         AND new_device_platform IS NOT NULL
         AND device_token_hash IS NOT NULL AND linked_at IS NOT NULL)
        OR
        (state = 'consumed'
         AND approved_at IS NOT NULL AND consumed_at IS NOT NULL
         AND approved_by_device_id IS NOT NULL AND delivery_envelope IS NOT NULL
         AND new_device_id IS NOT NULL AND new_device_space_id IS NOT NULL
         AND new_device_platform IS NOT NULL
         AND device_token_hash IS NOT NULL AND linked_at IS NOT NULL)
    ),

    PRIMARY KEY (session_id, claim_id),
    UNIQUE (claim_lookup_b64),
    FOREIGN KEY (session_id, account_id)
        REFERENCES pairing_session (session_id, account_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    FOREIGN KEY (account_id, approved_by_device_id)
        REFERENCES device (account_id, device_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT
);

CREATE INDEX pairing_claim_by_session_state
    ON pairing_claim (session_id, state, submitted_at);
