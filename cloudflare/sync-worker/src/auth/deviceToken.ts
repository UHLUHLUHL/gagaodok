import { ApiError } from "../contracts/error";
import { isSpaceId } from "../contracts/identity";
import type { SpaceId } from "../contracts/identity";

/**
 * Device authentication — API draft §2.1 and §3.
 *
 * A request proves which device it is with one header and nothing else. There
 * is no query-parameter fallback and no second path: a token in a URL ends up
 * in logs, proxies and browser history (API draft §2.1).
 */

/** The resolved identity of the calling device. API draft §3. */
export interface AuthContext {
  account_id: string;
  device_id: string;
  registered_space_id: SpaceId;
  key_generation: number;
  revoked_at: string | null;
}

const AUTH_SCHEME = "Device ";
const TOKEN_PREFIX = "gdt1_";
const TOKEN_PAYLOAD_LENGTH = 43;
const TOKEN_LENGTH = TOKEN_PREFIX.length + TOKEN_PAYLOAD_LENGTH;
const TOKEN_BYTES = 32;

const BASE64URL_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

function authInvalid(): ApiError {
  // Always the bare code. Which of the checks below failed is not the caller's
  // business, and saying so would turn this into an oracle.
  return new ApiError("AUTH_INVALID");
}

/**
 * Decode 43 unpadded Base64URL characters into exactly 32 bytes.
 *
 * The last quantum holds 32 bytes' worth of bits plus two spare ones. A
 * spelling that sets those spare bits decodes to the same 32 bytes, so two
 * different strings would authenticate one device. Re-encoding and comparing
 * refuses every spelling but the canonical one — the same rule the field
 * envelope validator applies to standard Base64.
 */
function decodeCanonicalBase64Url(payload: string): Uint8Array {
  if (payload.length !== TOKEN_PAYLOAD_LENGTH) {
    throw authInvalid();
  }

  const bytes = new Uint8Array(TOKEN_BYTES);
  let accumulator = 0;
  let bits = 0;
  let written = 0;

  for (const character of payload) {
    const value = BASE64URL_ALPHABET.indexOf(character);
    if (value < 0) {
      // Rejects '+', '/', '=', whitespace and anything else in one place.
      throw authInvalid();
    }
    accumulator = (accumulator << 6) | value;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      if (written >= TOKEN_BYTES) {
        throw authInvalid();
      }
      bytes[written] = (accumulator >> bits) & 0xff;
      written += 1;
    }
  }

  if (written !== TOKEN_BYTES) {
    throw authInvalid();
  }
  // The two leftover bits must be zero, which is what makes the spelling
  // canonical rather than merely decodable.
  if ((accumulator & ((1 << bits) - 1)) !== 0) {
    throw authInvalid();
  }
  return bytes;
}

/**
 * Read `Authorization: Device gdt1_<43 chars>` and return the token's 32 bytes.
 *
 * Everything about the header is exact: one header, the scheme spelled
 * `Device` with one space, no leading or trailing whitespace, no comma-joined
 * second credential, no other prefix or version.
 */
export function parseDeviceAuthorization(request: Request): Uint8Array {
  const header = request.headers.get("Authorization");
  if (header === null) {
    throw authInvalid();
  }
  // `Headers` joins repeated Authorization headers with ", ", so a duplicate
  // header and a comma-joined value are refused by the same check.
  if (!header.startsWith(AUTH_SCHEME)) {
    throw authInvalid();
  }
  const token = header.slice(AUTH_SCHEME.length);
  if (token.length !== TOKEN_LENGTH) {
    throw authInvalid();
  }
  if (!token.startsWith(TOKEN_PREFIX)) {
    throw authInvalid();
  }
  return decodeCanonicalBase64Url(token.slice(TOKEN_PREFIX.length));
}

/** SHA-256 of the token's decoded bytes, as lowercase hex. */
export async function hashDeviceToken(tokenBytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", tokenBytes as BufferSource);
  let hex = "";
  for (const byte of new Uint8Array(digest)) {
    hex += byte.toString(16).padStart(2, "0");
  }
  return hex;
}

interface DeviceRow {
  account_id: string;
  device_id: string;
  space_id: string;
  key_generation: number;
  revoked_at: string | null;
}

/**
 * Resolve the calling device: parse the header, hash the token, look the row up
 * by that hash alone, and refuse a revoked device.
 *
 * The account is never taken from the request. `token_hash` is globally unique,
 * so the hash identifies exactly one device and its account — which is why a
 * body or target that names a different account cannot widen anything.
 *
 * No timing-safe comparison is needed: nothing here compares a raw secret. The
 * hash is an indexed lookup, and the token has 256 bits of entropy.
 */
export async function authenticateDevice(
  request: Request,
  db: D1Database,
): Promise<AuthContext> {
  const tokenBytes = parseDeviceAuthorization(request);
  const tokenHash = await hashDeviceToken(tokenBytes);

  const row = await db
    .prepare(
      `SELECT account_id, device_id, space_id, key_generation, revoked_at
         FROM device
        WHERE token_hash = ?`,
    )
    .bind(tokenHash)
    .first<DeviceRow>();

  if (row === null) {
    // A device with a null token_hash lands here too: null never equals the
    // hash, so it can hold a row without being able to authenticate.
    throw authInvalid();
  }
  if (!isSpaceId(row.space_id)) {
    // The column has a CHECK, so this is a corrupt row rather than a request
    // problem; failing closed is still the only safe answer.
    throw authInvalid();
  }
  if (row.revoked_at !== null) {
    // Distinct from AUTH_INVALID by contract: a revoked device is told that its
    // link was ended rather than being left to retry a valid token forever.
    throw new ApiError("DEVICE_REVOKED");
  }

  return {
    account_id: row.account_id,
    device_id: row.device_id,
    registered_space_id: row.space_id,
    key_generation: row.key_generation,
    revoked_at: null,
  };
}

/**
 * An operation body may repeat its `device_id`; if it does it must be the
 * device the token proved (API draft §3). Otherwise a valid token could file
 * work under another device's provenance.
 */
export function assertAuthenticatedDeviceId(auth: AuthContext, requestDeviceId: string): void {
  if (auth.device_id !== requestDeviceId) {
    throw authInvalid();
  }
}

/**
 * A v1 device writes canonical rows for the space it is registered in, and no
 * other (API draft §3).
 *
 * Sharing an account is not authority: a phone token that could patch a
 * MAC_SPACE row would let one compromised or misconfigured device rewrite
 * every space's canonical state, and the write would be indistinguishable
 * from the Mac's own. Read paths are a separate question — this is the write
 * boundary only.
 *
 * The refusal is the bare AUTH_INVALID that a device_id mismatch produces, for
 * the same reason: saying which space was expected turns the error into a map
 * of the account's other devices. Delegated writers (an "active writer" that
 * may act for another space) need their own contract and do not exist in v1.
 */
export function assertAuthenticatedWriteSpace(auth: AuthContext, targetSpaceId: SpaceId): void {
  if (auth.registered_space_id !== targetSpaceId) {
    throw authInvalid();
  }
}
