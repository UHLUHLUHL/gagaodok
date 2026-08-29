import { validationFailed } from "./error";
import {
  decodeCanonicalBase64,
  isCanonicalBase64,
  requireSpaceId,
  requireUuid,
  type SpaceId,
} from "./identity";

const MAX_BODY_BYTES = 65_536;
const LOWERCASE_SHA256 = /^[0-9a-f]{64}$/;
const PLATFORM_BY_SPACE: Record<SpaceId, string> = {
  MAC_SPACE: "macos",
  PHONE_SPACE: "android_phone",
  TABLET_SPACE: "android_tablet",
};

export interface EnrollmentRequest {
  rawBytes: Uint8Array;
  fingerprint: string;
  enrollmentId: string;
  accountId: string;
  device: {
    deviceId: string;
    spaceId: SpaceId;
    platform: string;
    displayName: string | null;
    tokenHash: string;
  };
  recovery: {
    version: number;
    lookup: string;
    authVerifierHex: string;
    wrappedMasterKey: string;
    wrappedMasterKeyBytes: Uint8Array;
  };
}

export function requireRecord(value: unknown): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw validationFailed();
  return value as Record<string, unknown>;
}

export function requireExactKeys(value: Record<string, unknown>, expected: readonly string[]): void {
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (actual.length !== wanted.length || actual.some((key, index) => key !== wanted[index])) {
    throw validationFailed();
  }
}

export function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function requireBinary32(value: unknown): { encoded: string; bytes: Uint8Array } {
  if (!isCanonicalBase64(value)) throw validationFailed();
  const decoded = decodeCanonicalBase64(value);
  if (decoded.length !== 32) throw validationFailed();
  return { encoded: value, bytes: decoded };
}

export function requireV1Envelope(value: unknown): { encoded: string; bytes: Uint8Array } {
  if (!isCanonicalBase64(value)) throw validationFailed();
  const decoded = decodeCanonicalBase64(value);
  if (
    decoded.length < 34 ||
    decoded[0] !== 1 ||
    decoded[1] !== 1 ||
    decoded[2] !== 0 ||
    decoded[3] !== 0 ||
    decoded[4] !== 0 ||
    decoded[5] !== 1
  ) {
    throw validationFailed();
  }
  return { encoded: value, bytes: decoded };
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  return bytesToHex(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)));
}

export async function parseEnrollmentRequest(request: Request): Promise<EnrollmentRequest> {
  const declared = request.headers.get("Content-Length");
  if (declared !== null && (!/^(?:0|[1-9][0-9]*)$/.test(declared) || Number(declared) > MAX_BODY_BYTES)) {
    throw validationFailed();
  }

  const rawBytes = new Uint8Array(await request.arrayBuffer());
  if (rawBytes.length === 0 || rawBytes.length > MAX_BODY_BYTES) throw validationFailed();

  let parsed: unknown;
  try {
    parsed = JSON.parse(
      new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(rawBytes),
    );
  } catch {
    throw validationFailed();
  }
  const body = requireRecord(parsed);
  requireExactKeys(body, ["protocol_version", "enrollment_id", "account_id", "device", "recovery"]);
  if (body["protocol_version"] !== 1) throw validationFailed();

  const device = requireRecord(body["device"]);
  requireExactKeys(device, ["device_id", "space_id", "platform", "display_name", "device_token_hash"]);
  const spaceId = requireSpaceId(device["space_id"]);
  if (device["platform"] !== PLATFORM_BY_SPACE[spaceId]) throw validationFailed();
  if (typeof device["device_token_hash"] !== "string" || !LOWERCASE_SHA256.test(device["device_token_hash"])) {
    throw validationFailed();
  }
  let displayName: string | null = null;
  if (device["display_name"] !== null) displayName = requireV1Envelope(device["display_name"]).encoded;

  const recovery = requireRecord(body["recovery"]);
  requireExactKeys(recovery, ["recovery_version", "recovery_lookup", "recovery_auth_verifier", "wrapped_master_key"]);
  if (recovery["recovery_version"] !== 1) throw validationFailed();
  const lookup = requireBinary32(recovery["recovery_lookup"]);
  const verifier = requireBinary32(recovery["recovery_auth_verifier"]);
  const wrapped = requireV1Envelope(recovery["wrapped_master_key"]);

  return {
    rawBytes,
    fingerprint: await sha256Hex(rawBytes),
    enrollmentId: requireUuid(body["enrollment_id"]),
    accountId: requireUuid(body["account_id"]),
    device: {
      deviceId: requireUuid(device["device_id"]),
      spaceId,
      platform: device["platform"] as string,
      displayName,
      tokenHash: device["device_token_hash"],
    },
    recovery: {
      version: 1,
      lookup: lookup.encoded,
      authVerifierHex: bytesToHex(verifier.bytes),
      wrappedMasterKey: wrapped.encoded,
      wrappedMasterKeyBytes: wrapped.bytes,
    },
  };
}
