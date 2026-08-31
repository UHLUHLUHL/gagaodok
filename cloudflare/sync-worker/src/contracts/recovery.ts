import { validationFailed } from "./error";
import {
  bytesToHex,
  requireBinary32,
  requireExactKeys,
  requireRecord,
  requireV1Envelope,
} from "./onboarding";
import { requireSpaceId, requireUuid, type SpaceId } from "./identity";

const LOWERCASE_SHA256 = /^[0-9a-f]{64}$/;
const PLATFORM_BY_SPACE: Record<SpaceId, string> = {
  MAC_SPACE: "macos", PHONE_SPACE: "android_phone", TABLET_SPACE: "android_tablet",
};

export interface RecoveryRedeemRequest {
  lookup: string;
  lookupBytes: Uint8Array;
  authBytes: Uint8Array;
  device: {
    deviceId: string; spaceId: SpaceId; platform: string;
    displayName: string | null; tokenHash: string;
  };
}

function lp(fields: Array<[number, Uint8Array]>): Uint8Array {
  const size = 6 + fields.reduce((sum, [, value]) => sum + 7 + value.length, 0);
  const output = new Uint8Array(size);
  const view = new DataView(output.buffer);
  output.set([0x47, 0x44, 0x4b, 0x31], 0);
  view.setUint16(4, fields.length, false);
  let offset = 6;
  for (const [id, value] of fields) {
    view.setUint16(offset, id, false); offset += 2;
    output[offset] = 1; offset += 1;
    view.setUint32(offset, value.length, false); offset += 4;
    output.set(value, offset); offset += value.length;
  }
  return output;
}

export async function recoveryVerifier(auth: Uint8Array): Promise<string> {
  const encoded = lp([
    [1, new TextEncoder().encode("gagaodok/e2ee/v1/recovery-auth-verifier")],
    [2, auth],
  ]);
  return bytesToHex(new Uint8Array(await crypto.subtle.digest("SHA-256", encoded)));
}

export function constantTimeHexEqual(left: string, right: string): boolean {
  if (left.length !== 64 || right.length !== 64) return false;
  let difference = 0;
  for (let index = 0; index < 64; index += 1) difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  return difference === 0;
}

export async function parseRecoveryRedeem(request: Request): Promise<RecoveryRedeemRequest> {
  let parsed: unknown;
  try {
    const bytes = new Uint8Array(await request.arrayBuffer());
    if (bytes.length === 0 || bytes.length > 65_536) throw validationFailed();
    parsed = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes));
  } catch (error) {
    if (error instanceof Error && error.message === "VALIDATION_FAILED") throw error;
    throw validationFailed();
  }
  const body = requireRecord(parsed);
  requireExactKeys(body, ["protocol_version", "recovery_lookup", "recovery_auth", "device"]);
  if (body.protocol_version !== 1) throw validationFailed();
  const lookup = requireBinary32(body.recovery_lookup);
  const auth = requireBinary32(body.recovery_auth);
  const device = requireRecord(body.device);
  requireExactKeys(device, ["device_id", "space_id", "platform", "display_name", "device_token_hash"]);
  const spaceId = requireSpaceId(device.space_id);
  if (device.platform !== PLATFORM_BY_SPACE[spaceId]) throw validationFailed();
  if (typeof device.device_token_hash !== "string" || !LOWERCASE_SHA256.test(device.device_token_hash)) throw validationFailed();
  const displayName = device.display_name === null ? null : requireV1Envelope(device.display_name).encoded;
  return {
    lookup: lookup.encoded, lookupBytes: lookup.bytes, authBytes: auth.bytes,
    device: {
      deviceId: requireUuid(device.device_id), spaceId, platform: device.platform as string,
      displayName, tokenHash: device.device_token_hash,
    },
  };
}

/**
 * An authenticated recovery rotation — replace the phrase, keep the account.
 *
 * The account master key is not touched. The client derives a fresh lookup,
 * auth verifier and wrap key from new entropy and sends the same master key
 * re-wrapped under the new phrase. The plaintext phrase, its entropy and the
 * master key itself never reach the server.
 */
export interface RecoveryRotateRequest {
  version: number;
  lookup: string;
  authVerifierHex: string;
  wrappedMasterKey: string;
  wrappedMasterKeyBytes: Uint8Array;
}

export async function parseRecoveryRotate(request: Request): Promise<RecoveryRotateRequest> {
  let parsed: unknown;
  try {
    const bytes = new Uint8Array(await request.arrayBuffer());
    if (bytes.length === 0 || bytes.length > 65_536) throw validationFailed();
    parsed = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes));
  } catch (error) {
    if (error instanceof Error && error.message === "VALIDATION_FAILED") throw error;
    throw validationFailed();
  }
  const body = requireRecord(parsed);
  requireExactKeys(body, [
    "protocol_version", "recovery_version", "recovery_lookup",
    "recovery_auth_verifier", "wrapped_master_key",
  ]);
  if (body["protocol_version"] !== 1) throw validationFailed();
  // The next version is stated by the client so that a stale device cannot
  // silently overwrite a rotation it never saw. Which version is actually
  // current is decided in storage, not here.
  const version = body["recovery_version"];
  if (typeof version !== "number" || !Number.isSafeInteger(version) || version < 2 || version > 4_294_967_295) {
    throw validationFailed();
  }
  const lookup = requireBinary32(body["recovery_lookup"]);
  const verifier = requireBinary32(body["recovery_auth_verifier"]);
  const wrapped = requireV1Envelope(body["wrapped_master_key"]);
  return {
    version,
    lookup: lookup.encoded,
    authVerifierHex: bytesToHex(verifier.bytes),
    wrappedMasterKey: wrapped.encoded,
    wrappedMasterKeyBytes: wrapped.bytes,
  };
}
