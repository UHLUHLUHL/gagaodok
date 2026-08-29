import { ApiError } from "../contracts/error";
import type { EnrollmentRequest } from "../contracts/onboarding";
import type { Env } from "../env";

export interface EnrollmentResult {
  status: "created" | "replayed";
  account_id: string;
  device_id: string;
}

interface EnrollmentRow {
  account_id: string;
  request_fingerprint: string;
}

function storageUnavailable(): ApiError {
  return new ApiError("STORAGE_UNAVAILABLE", { retryable: true });
}

async function readEnrollment(db: D1Database, enrollmentId: string): Promise<EnrollmentRow | null> {
  try {
    return await db
      .prepare(`SELECT account_id, request_fingerprint FROM enrollment_log WHERE enrollment_id = ?`)
      .bind(enrollmentId)
      .first<EnrollmentRow>();
  } catch {
    throw storageUnavailable();
  }
}

function replayOrConflict(row: EnrollmentRow, request: EnrollmentRequest): EnrollmentResult {
  if (row.account_id !== request.accountId || row.request_fingerprint !== request.fingerprint) {
    throw new ApiError("ENROLLMENT_CONFLICT");
  }
  return { status: "replayed", account_id: request.accountId, device_id: request.device.deviceId };
}

export async function initializeEnrollment(
  request: EnrollmentRequest,
  env: Pick<Env, "DB" | "ATTACHMENTS">,
): Promise<EnrollmentResult> {
  const existing = await readEnrollment(env.DB, request.enrollmentId);
  if (existing !== null) return replayOrConflict(existing, request);

  const objectKey = `recovery/${crypto.randomUUID().toUpperCase()}`;
  try {
    const written = await env.ATTACHMENTS.put(objectKey, request.recovery.wrappedMasterKeyBytes, {
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
      env.DB.prepare(`INSERT INTO account (account_id, created_at) VALUES (?, ?)`).bind(request.accountId, now),
      env.DB.prepare(
        `INSERT INTO device
           (account_id, device_id, space_id, platform, display_name_enc, linked_at,
            revoked_at, key_generation, token_hash)
         VALUES (?, ?, ?, ?, ?, ?, NULL, 1, ?)`,
      ).bind(
        request.accountId,
        request.device.deviceId,
        request.device.spaceId,
        request.device.platform,
        request.device.displayName,
        now,
        request.device.tokenHash,
      ),
      env.DB.prepare(
        `INSERT INTO recovery_record
           (account_id, recovery_version, recovery_lookup_b64, recovery_auth_verifier,
            wrapped_master_key_enc, r2_object_key, key_generation, created_at, revoked_at)
         VALUES (?, ?, ?, ?, ?, ?, 1, ?, NULL)`,
      ).bind(
        request.accountId,
        request.recovery.version,
        request.recovery.lookup,
        request.recovery.authVerifierHex,
        request.recovery.wrappedMasterKey,
        objectKey,
        now,
      ),
      env.DB.prepare(
        `INSERT INTO enrollment_log
           (account_id, enrollment_id, request_fingerprint, created_at)
         VALUES (?, ?, ?, ?)`,
      ).bind(request.accountId, request.enrollmentId, request.fingerprint, now),
    ]);
  } catch {
    const raced = await readEnrollment(env.DB, request.enrollmentId);
    if (raced !== null) return replayOrConflict(raced, request);
    throw new ApiError("ENROLLMENT_CONFLICT");
  }

  return { status: "created", account_id: request.accountId, device_id: request.device.deviceId };
}
