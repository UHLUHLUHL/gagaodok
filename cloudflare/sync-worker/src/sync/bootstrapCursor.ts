import { validationFailed } from "../contracts/error";
import { BOOTSTRAP_ENTITY_ORDER } from "./projection";
import type { StorageKey } from "./projection";

/**
 * The bootstrap cursor — API draft 4.3.
 *
 * A cursor is a server-signed position, not a client-chosen one. It names the
 * snapshot watermark, which entity the last page stopped in and the storage
 * key it stopped at, so a resumed bootstrap continues from the same snapshot
 * instead of a fresh one. Without the signature a client could edit the
 * watermark or the account and ask the server to walk someone else's data or
 * a snapshot that never existed.
 */

/** `<canonical base64url payload>.<canonical base64url HMAC>` */
const TOKEN_SEPARATOR = ".";

export const CURSOR_VERSION = 1;
export const CURSOR_TTL_SECONDS = 3600;

/**
 * A MAC key shorter than the digest it produces weakens the tag for no reason.
 * Refusing to sign with one is a server-configuration failure, not something a
 * request can cause.
 */
const MIN_KEY_BYTES = 32;

const BASE64URL_PATTERN = /^[A-Za-z0-9_-]+$/;

export interface BootstrapCursor {
  accountId: string;
  watermark: number;
  entityIndex: number;
  storageKey: StorageKey;
  expiresAt: number;
}

/** Seconds since the epoch. Replaceable so an expiry test is deterministic. */
let clock: () => number = () => Math.floor(Date.now() / 1000);

export function setCursorClockForTest(seconds: (() => number) | null): void {
  clock = seconds ?? (() => Math.floor(Date.now() / 1000));
}

function encodeBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

function decodeBase64Url(value: string): Uint8Array {
  const padded = value.replaceAll("-", "+").replaceAll("_", "/");
  const binary = atob(padded + "=".repeat((4 - (padded.length % 4)) % 4));
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes;
}

/**
 * Decode one canonical Base64URL segment.
 *
 * The charset check is not enough on its own: in a final quantum the bits past
 * the encoded bytes are discarded on decode, so several spellings decode to
 * the same value. Re-encoding and demanding equality accepts only the spelling
 * the encoder itself produces, which is what makes a token have exactly one
 * form — the same rule the field envelope and the device token already apply.
 */
function decodeCanonicalSegment(segment: string): Uint8Array {
  if (segment.length === 0 || !BASE64URL_PATTERN.test(segment)) {
    throw validationFailed();
  }
  let bytes: Uint8Array;
  try {
    bytes = decodeBase64Url(segment);
  } catch {
    throw validationFailed();
  }
  if (encodeBase64Url(bytes) !== segment) {
    throw validationFailed();
  }
  return bytes;
}

async function macKey(secret: string): Promise<CryptoKey> {
  const raw = new TextEncoder().encode(secret);
  if (raw.byteLength < MIN_KEY_BYTES) {
    // A misconfigured server must not issue weak cursors. The client is told
    // only that its request could not be served.
    throw validationFailed();
  }
  return await crypto.subtle.importKey(
    "raw",
    raw as BufferSource,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
}

/**
 * The signed payload, as a canonical JSON array.
 *
 * An array rather than an object: its field order is fixed by position, so
 * there is exactly one byte string to sign and no question of key ordering.
 */
function payloadText(cursor: BootstrapCursor): string {
  return JSON.stringify([
    CURSOR_VERSION,
    cursor.accountId,
    cursor.watermark,
    cursor.entityIndex,
    [...cursor.storageKey],
    cursor.expiresAt,
  ]);
}

export async function issueCursor(
  secret: string,
  accountId: string,
  watermark: number,
  entityIndex: number,
  storageKey: StorageKey,
): Promise<string> {
  const cursor: BootstrapCursor = {
    accountId,
    watermark,
    entityIndex,
    storageKey,
    expiresAt: clock() + CURSOR_TTL_SECONDS,
  };
  const payload = new TextEncoder().encode(payloadText(cursor));
  const signature = await crypto.subtle.sign(
    "HMAC",
    await macKey(secret),
    payload as BufferSource,
  );
  return `${encodeBase64Url(payload)}${TOKEN_SEPARATOR}${encodeBase64Url(new Uint8Array(signature))}`;
}

function isStorageKeyValue(value: unknown): value is string | number {
  return typeof value === "string" || (typeof value === "number" && Number.isSafeInteger(value));
}

/**
 * Verify a cursor and return the position it names.
 *
 * Every failure is the same `VALIDATION_FAILED`: a tampered payload, another
 * account's token, an expired one, an unknown version and a malformed key are
 * indistinguishable to the caller, so the endpoint cannot be used to learn
 * which part of a forged token was wrong.
 */
export async function verifyCursor(
  secret: string,
  token: string,
  accountId: string,
): Promise<BootstrapCursor> {
  const parts = token.split(TOKEN_SEPARATOR);
  if (parts.length !== 2) {
    throw validationFailed();
  }
  const payloadBytes = decodeCanonicalSegment(parts[0] as string);
  const signature = decodeCanonicalSegment(parts[1] as string);

  // Constant-time by construction: the comparison happens inside the platform
  // primitive rather than in a byte loop this module writes.
  const valid = await crypto.subtle.verify(
    "HMAC",
    await macKey(secret),
    signature as BufferSource,
    payloadBytes as BufferSource,
  );
  if (!valid) {
    throw validationFailed();
  }

  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(payloadBytes);
  } catch {
    throw validationFailed();
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw validationFailed();
  }
  if (!Array.isArray(parsed) || parsed.length !== 6) {
    throw validationFailed();
  }
  const [version, tokenAccount, watermark, entityIndex, storageKey, expiresAt] = parsed as [
    unknown,
    unknown,
    unknown,
    unknown,
    unknown,
    unknown,
  ];

  if (version !== CURSOR_VERSION) {
    throw validationFailed();
  }
  // The token is bound to the account it was issued for. A valid signature is
  // not authority over whatever account the caller happens to hold a token for.
  if (typeof tokenAccount !== "string" || tokenAccount !== accountId) {
    throw validationFailed();
  }
  if (typeof watermark !== "number" || !Number.isSafeInteger(watermark) || watermark < 0) {
    throw validationFailed();
  }
  if (
    typeof entityIndex !== "number" ||
    !Number.isSafeInteger(entityIndex) ||
    entityIndex < 0 ||
    entityIndex >= BOOTSTRAP_ENTITY_ORDER.length
  ) {
    throw validationFailed();
  }
  if (!Array.isArray(storageKey) || !storageKey.every(isStorageKeyValue)) {
    throw validationFailed();
  }
  if (typeof expiresAt !== "number" || !Number.isSafeInteger(expiresAt)) {
    throw validationFailed();
  }
  if (clock() >= expiresAt) {
    throw validationFailed();
  }

  const cursor: BootstrapCursor = {
    accountId: tokenAccount,
    watermark,
    entityIndex,
    storageKey: storageKey as StorageKey,
    expiresAt,
  };
  // A payload that signs correctly but is not the canonical spelling of its own
  // values is still a token this server would never have issued.
  if (payloadText(cursor) !== text) {
    throw validationFailed();
  }
  return cursor;
}
