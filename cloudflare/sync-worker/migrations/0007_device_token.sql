-- Device token storage
--
-- Physical migration 0007. This is not a logical M-stage of the D1 plan: it
-- adds the one column the authentication boundary needs. M01..M05 defined what
-- is stored; nothing so far defined how a request proves which device it is.
--
-- The device table is NOT rebuilt. SQLite's ALTER TABLE ADD COLUMN is not a
-- constraint change, so the account foreign key added by 0002, the composite
-- primary key and the partial index all stay exactly as they are, and the rows
-- already in the table are untouched. That matters here more than usual: a
-- rebuild would have to copy every device row through a table that the account
-- foreign key is live against, and D1 ignores both PRAGMA foreign_keys = OFF
-- and PRAGMA defer_foreign_keys = ON.
--
-- The column is nullable on purpose. A device linked before tokens existed has
-- no hash, and inventing one would either be a forgery or a lockout. Such a row
-- simply cannot authenticate: the lookup is by hash, and a null hash matches
-- nothing.
--
-- What is stored is the SHA-256 of the token's 32 decoded bytes, as lowercase
-- hex. The raw token never reaches D1. A 256-bit CSPRNG token needs no pepper
-- and no slow password hash: there is nothing to guess and nothing to
-- dictionary-attack, and a slow hash on the read path would only make every
-- authenticated request slower.
--
-- Local-only. No Cloudflare resource is created by this file.

ALTER TABLE device ADD COLUMN token_hash TEXT
    -- Lowercase SHA-256 hex. Two spellings of one digest would be two rows for
    -- one token, so the case is fixed here rather than normalised at read time.
    CHECK (
        token_hash IS NULL
        OR (
            length(token_hash) = 64
            AND token_hash NOT GLOB '*[^0-9a-f]*'
        )
    );

-- Global, not per account. The lookup is by hash alone — an authentication
-- request names no account — so one hash resolving to two devices would mean
-- one token resolving to two tenants. The index is partial so that the many
-- devices with no token do not collide with each other on NULL.
CREATE UNIQUE INDEX device_by_token_hash
    ON device (token_hash)
    WHERE token_hash IS NOT NULL;
