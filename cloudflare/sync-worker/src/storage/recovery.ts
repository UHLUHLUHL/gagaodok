import { ApiError } from "../contracts/error";
import { constantTimeHexEqual, recoveryVerifier, type RecoveryRedeemRequest } from "../contracts/recovery";

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
