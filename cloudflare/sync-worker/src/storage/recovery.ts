import { ApiError } from "../contracts/error";
import {
  constantTimeHexEqual,
  recoveryVerifier,
  type RecoveryRedeemRequest,
  type RecoveryRotateRequest,
} from "../contracts/recovery";

interface RecoveryRow {
  account_id: string; recovery_version: number; recovery_auth_verifier: string;
  wrapped_master_key_enc: string; key_generation: number; revoked_at: string | null;
}

interface DeviceProjection {
  space_id: string; platform: string; display_name_enc: string | null; token_hash: string | null;
}

export interface RecoveryResult {
  status: "created" | "replayed"; account_id: string; device_id: string;
  recovery_version: number; key_generation: number; wrapped_master_key: string;
}

function invalid(): ApiError { return new ApiError("RECOVERY_INVALID"); }

export async function redeemRecovery(db: D1Database, request: RecoveryRedeemRequest): Promise<RecoveryResult> {
  let row: RecoveryRow | null;
  try {
    row = await db.prepare(
      `SELECT account_id, recovery_version, recovery_auth_verifier,
              wrapped_master_key_enc, key_generation, revoked_at
         FROM recovery_record WHERE recovery_lookup_b64 = ?`,
    ).bind(request.lookup).first<RecoveryRow>();
  } catch { throw new ApiError("STORAGE_UNAVAILABLE", { retryable: true }); }
  if (row === null || row.revoked_at !== null) throw invalid();
  const candidate = await recoveryVerifier(request.authBytes);
  if (!constantTimeHexEqual(candidate, row.recovery_auth_verifier)) throw invalid();

  const existing = await db.prepare(
    `SELECT space_id, platform, display_name_enc, token_hash FROM device
      WHERE account_id = ? AND device_id = ?`,
  ).bind(row.account_id, request.device.deviceId).first<DeviceProjection>();
  let status: "created" | "replayed" = "created";
  if (existing !== null) {
    if (
      existing.space_id !== request.device.spaceId || existing.platform !== request.device.platform ||
      existing.display_name_enc !== request.device.displayName || existing.token_hash !== request.device.tokenHash
    ) throw new ApiError("RECOVERY_CONFLICT");
    status = "replayed";
  } else {
    try {
      await db.prepare(
        `INSERT INTO device
           (account_id, device_id, space_id, platform, display_name_enc, linked_at,
            revoked_at, key_generation, token_hash)
         VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?)`,
      ).bind(
        row.account_id, request.device.deviceId, request.device.spaceId, request.device.platform,
        request.device.displayName, new Date().toISOString(), row.key_generation, request.device.tokenHash,
      ).run();
    } catch {
      const raced = await db.prepare(
        `SELECT space_id, platform, display_name_enc, token_hash FROM device WHERE account_id = ? AND device_id = ?`,
      ).bind(row.account_id, request.device.deviceId).first<DeviceProjection>();
      if (
        raced === null || raced.space_id !== request.device.spaceId || raced.platform !== request.device.platform ||
        raced.display_name_enc !== request.device.displayName || raced.token_hash !== request.device.tokenHash
      ) throw new ApiError("RECOVERY_CONFLICT");
      status = "replayed";
    }
  }
  return {
    status, account_id: row.account_id, device_id: request.device.deviceId,
    recovery_version: row.recovery_version, key_generation: row.key_generation,
    wrapped_master_key: row.wrapped_master_key_enc,
  };
}

interface ActiveRecoveryRow {
  recovery_version: number; key_generation: number;
}

interface VersionedRecoveryRow {
  recovery_lookup_b64: string; recovery_auth_verifier: string;
  wrapped_master_key_enc: string; key_generation: number; revoked_at: string | null;
}

export interface RecoveryRotateResult {
  status: "created" | "replayed";
  recovery_version: number;
  key_generation: number;
}

function storageUnavailable(): ApiError {
  return new ApiError("STORAGE_UNAVAILABLE", { retryable: true });
}

/**
 * Is the row at the requested version the very rotation being asked for?
 *
 * A retry of the same request must succeed rather than lock the account out,
 * but only when every field matches. A different payload at a version that is
 * already taken is a conflict, not a replay — otherwise a second phrase could
 * quietly displace the one the user just wrote down.
 */
function matchesRequest(row: VersionedRecoveryRow, request: RecoveryRotateRequest): boolean {
  return row.recovery_lookup_b64 === request.lookup
    && constantTimeHexEqual(row.recovery_auth_verifier, request.authVerifierHex)
    && row.wrapped_master_key_enc === request.wrappedMasterKey;
}

async function readVersion(
  db: D1Database, accountId: string, version: number,
): Promise<VersionedRecoveryRow | null> {
  try {
    return await db.prepare(
      `SELECT recovery_lookup_b64, recovery_auth_verifier, wrapped_master_key_enc,
              key_generation, revoked_at
         FROM recovery_record WHERE account_id = ? AND recovery_version = ?`,
    ).bind(accountId, version).first<VersionedRecoveryRow>();
  } catch { throw storageUnavailable(); }
}

/**
 * Replace the account's active recovery record with a new one — API draft §4.1.
 *
 * The master key is carried over untouched: only the phrase-derived lookup,
 * verifier and wrapping change, so every already-linked device keeps working
 * and `key_generation` does not move. The revoke and the insert go in one D1
 * batch, and `recovery_one_active_per_account` makes the partial unique index
 * the arbiter — two devices rotating at once cannot both end up active.
 */
export async function rotateRecovery(
  env: { DB: D1Database; ATTACHMENTS: R2Bucket },
  accountId: string,
  request: RecoveryRotateRequest,
): Promise<RecoveryRotateResult> {
  let active: ActiveRecoveryRow | null;
  try {
    active = await env.DB.prepare(
      `SELECT recovery_version, key_generation FROM recovery_record
        WHERE account_id = ? AND revoked_at IS NULL`,
    ).bind(accountId).first<ActiveRecoveryRow>();
  } catch { throw storageUnavailable(); }
  // No active record means there is nothing to rotate from. Enrolment, not
  // rotation, is what creates the first one.
  if (active === null) throw new ApiError("RECOVERY_CONFLICT");

  if (request.version !== active.recovery_version + 1) {
    // Either the caller is behind (its rotation already landed, or someone
    // else's did) or it is guessing ahead. Both are the same content-free
    // conflict: the response must not say which version is current.
    const taken = await readVersion(env.DB, accountId, request.version);
    if (taken !== null && taken.revoked_at === null && matchesRequest(taken, request)) {
      return {
        status: "replayed",
        recovery_version: request.version,
        key_generation: taken.key_generation,
      };
    }
    throw new ApiError("RECOVERY_CONFLICT");
  }

  const objectKey = `recovery/${crypto.randomUUID().toUpperCase()}`;
  try {
    const written = await env.ATTACHMENTS.put(objectKey, request.wrappedMasterKeyBytes, {
      onlyIf: { etagDoesNotMatch: "*" },
    });
    if (written === null) throw storageUnavailable();
  } catch (error) {
    if (error instanceof ApiError) throw error;
    throw storageUnavailable();
  }

  const now = new Date().toISOString();
  try {
    await env.DB.batch([
      // Guarded by revoked_at IS NULL and the exact version: a racing rotation
      // that already revoked this row makes the insert below hit the partial
      // unique index, and the whole batch rolls back.
      env.DB.prepare(
        `UPDATE recovery_record SET revoked_at = ?
          WHERE account_id = ? AND recovery_version = ? AND revoked_at IS NULL`,
      ).bind(now, accountId, active.recovery_version),
      env.DB.prepare(
        `INSERT INTO recovery_record
           (account_id, recovery_version, recovery_lookup_b64, recovery_auth_verifier,
            wrapped_master_key_enc, r2_object_key, key_generation, created_at, revoked_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)`,
      ).bind(
        accountId, request.version, request.lookup, request.authVerifierHex,
        request.wrappedMasterKey, objectKey, active.key_generation, now,
      ),
    ]);
  } catch {
    // The batch is atomic, so the old record is still active here. The R2
    // object written above is now unreferenced and is collected by the Phase 1
    // orphan sweep — it holds only a wrapped key and no plaintext.
    const raced = await readVersion(env.DB, accountId, request.version);
    if (raced !== null && raced.revoked_at === null && matchesRequest(raced, request)) {
      return {
        status: "replayed",
        recovery_version: request.version,
        key_generation: raced.key_generation,
      };
    }
    throw new ApiError("RECOVERY_CONFLICT");
  }

  return {
    status: "created",
    recovery_version: request.version,
    key_generation: active.key_generation,
  };
}
