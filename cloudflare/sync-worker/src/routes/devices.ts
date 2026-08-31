import { authenticateDevice } from "../auth/deviceToken";
import { ApiError, PROTOCOL_VERSION, validationFailed } from "../contracts/error";
import { isCanonicalUuid, isSpaceId, requireRfc3339Utc } from "../contracts/identity";
import { requireV1Envelope } from "../contracts/onboarding";
import type { SpaceId } from "../contracts/identity";
import type { Env } from "../env";

interface DeviceRow {
  device_id: string;
  space_id: string;
  platform: string;
  display_name_enc: string | null;
  linked_at: string;
}

export interface AccountDevice {
  device_id: string;
  space_id: SpaceId;
  platform: "macos" | "android_phone" | "android_tablet";
  display_name: string | null;
  linked_at: string;
  is_current: boolean;
}

const PLATFORM_BY_SPACE: Record<SpaceId, AccountDevice["platform"]> = {
  MAC_SPACE: "macos",
  PHONE_SPACE: "android_phone",
  TABLET_SPACE: "android_tablet",
};

function storageUnavailable(): ApiError {
  return new ApiError("STORAGE_UNAVAILABLE", { retryable: true });
}

function validateStoredDevice(row: DeviceRow, currentDeviceId: string): AccountDevice {
  try {
    if (!isCanonicalUuid(row.device_id) || !isSpaceId(row.space_id)) throw storageUnavailable();
    if (row.platform !== PLATFORM_BY_SPACE[row.space_id]) throw storageUnavailable();
    const linkedAt = requireRfc3339Utc(row.linked_at);
    const displayName = row.display_name_enc === null
      ? null
      : requireV1Envelope(row.display_name_enc).encoded;
    return {
      device_id: row.device_id,
      space_id: row.space_id,
      platform: row.platform,
      display_name: displayName,
      linked_at: linkedAt,
      is_current: row.device_id === currentDeviceId,
    };
  } catch {
    // A malformed persisted row is not a request error. Do not return it and
    // do not reveal which field was corrupt.
    throw storageUnavailable();
  }
}

async function readDevices(request: Request, env: Env): Promise<AccountDevice[]> {
  const auth = await authenticateDevice(request, env.DB);
  const url = new URL(request.url);
  if ([...url.searchParams.keys()].length !== 0) throw validationFailed();

  let rows: DeviceRow[];
  try {
    const result = await env.DB.prepare(
      `SELECT device_id, space_id, platform, display_name_enc, linked_at
         FROM device
        WHERE account_id = ? AND revoked_at IS NULL
        ORDER BY linked_at ASC, device_id ASC`,
    ).bind(auth.account_id).all<DeviceRow>();
    rows = result.results;
  } catch {
    throw storageUnavailable();
  }
  return rows.map((row) => validateStoredDevice(row, auth.device_id));
}

/** Authenticated active-device inventory. Token hashes and revocation metadata never leave D1. */
export async function handleDeviceListRequest(request: Request, env: Env): Promise<Response> {
  const requestId = crypto.randomUUID().toUpperCase();
  try {
    const devices = await readDevices(request, env);
    return Response.json({
      protocol_version: PROTOCOL_VERSION,
      request_id: requestId,
      result: { devices },
    });
  } catch (error) {
    if (error instanceof ApiError) return error.toResponse(requestId);
    return new ApiError("INTERNAL_ERROR").toResponse(requestId);
  }
}
