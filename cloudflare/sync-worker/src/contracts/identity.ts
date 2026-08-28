import { validationFailed } from "./error";

/** Canonical space enum. Draft §1.1 forbids case folding and fallback. */
export const SPACES = ["MAC_SPACE", "PHONE_SPACE", "TABLET_SPACE"] as const;
export type SpaceId = (typeof SPACES)[number];

/** Worker boundary keeps integers exact in IEEE-754. Draft §0.3, §2. */
export const MAX_SAFE_SYNC_INTEGER = Number.MAX_SAFE_INTEGER;

/** `<owner>.<entity>.<field>`, each segment `[a-z][a-z0-9_]*`. Draft §3.3. */
export const EXTENSION_KEY_PATTERN = /^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){2}$/;

/** Uppercase hyphenated 36-byte ASCII. E2EE proposal §12.3, API draft §2.1. */
const UUID_PATTERN =
  /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/;

/**
 * RFC 3339 UTC only (trailing `Z`; no numeric offset). API draft §2.1 fixes
 * timestamps as "RFC 3339 UTC", and the wire never carries a local offset.
 */
const RFC3339_UTC_PATTERN =
  /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?Z$/;

export function isSpaceId(value: unknown): value is SpaceId {
  return typeof value === "string" && (SPACES as readonly string[]).includes(value);
}

export function isSafeSyncInteger(value: unknown): boolean {
  return (
    typeof value === "number" &&
    Number.isInteger(value) &&
    value >= 0 &&
    value <= MAX_SAFE_SYNC_INTEGER
  );
}

export function isCanonicalUuid(value: unknown): value is string {
  return typeof value === "string" && UUID_PATTERN.test(value);
}

export function requireSpaceId(value: unknown): SpaceId {
  if (!isSpaceId(value)) {
    throw validationFailed();
  }
  return value;
}

export function requireUuid(value: unknown): string {
  if (!isCanonicalUuid(value)) {
    throw validationFailed();
  }
  return value;
}

export function requireSafeInteger(value: unknown): number {
  if (!isSafeSyncInteger(value)) {
    throw validationFailed();
  }
  return value as number;
}

function daysInMonth(year: number, month: number): number {
  // Day 0 of the following month is the last day of `month`. This delegates
  // leap-year arithmetic (including the 100/400-year exception) to the
  // platform's Gregorian calendar instead of re-deriving it.
  return new Date(Date.UTC(year, month, 0)).getUTCDate();
}

/**
 * Validate that `value` is a real RFC 3339 UTC instant, not merely a string
 * that matches the timestamp shape.
 *
 * A regex alone accepts calendar nonsense like `2026-99-99T99:99:99Z`, and
 * `new Date(...)` alone is not a fix either: `new Date("2026-02-30T00:00:00Z")`
 * silently rolls over to March 2 instead of rejecting the 30th of February.
 * This checks each field against the actual length of its month.
 */
export function requireRfc3339Utc(value: unknown): string {
  if (typeof value !== "string") {
    throw validationFailed();
  }
  const match = RFC3339_UTC_PATTERN.exec(value);
  if (!match) {
    throw validationFailed();
  }
  const [, yearText, monthText, dayText, hourText, minuteText, secondText] = match;
  const year = Number(yearText);
  const month = Number(monthText);
  const day = Number(dayText);
  const hour = Number(hourText);
  const minute = Number(minuteText);
  const second = Number(secondText);

  if (month < 1 || month > 12) {
    throw validationFailed();
  }
  if (day < 1 || day > daysInMonth(year, month)) {
    throw validationFailed();
  }
  if (hour > 23 || minute > 59 || second > 59) {
    throw validationFailed();
  }
  return value;
}

/** Standard padded Base64 charset+padding shape. Necessary, not sufficient. */
const CANONICAL_BASE64_PATTERN =
  /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=|[A-Za-z0-9+/]{4})$/;

/**
 * Decode a Base64 string to raw bytes with the Workers-global `atob`.
 * Internal: the shape check must already have passed.
 */
function decodeToBytes(value: string): Uint8Array {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes;
}

/** Re-encode raw bytes with the standard padded Base64 encoder. */
function encodeFromBytes(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary);
}

/**
 * True only for the single canonical padded-Base64 spelling of some bytes.
 *
 * The charset/padding regex alone is not enough. In a final quantum the bits
 * that fall past the encoded bytes are discarded on decode, so several
 * distinct strings decode to the same value — `"QQ=="` and `"QR=="` both
 * decode to `0x41`. Accepting both would break the "canonical wire
 * representation" contract and, more concretely, the operation replay
 * fingerprint: two byte-different bodies would carry identical ciphertext.
 *
 * So after the shape check this decodes and re-encodes with the standard
 * encoder and requires byte-for-byte equality with the input. Only the
 * spelling the encoder itself produces survives.
 */
export function isCanonicalBase64(value: unknown): value is string {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.length % 4 !== 0 ||
    !CANONICAL_BASE64_PATTERN.test(value)
  ) {
    return false;
  }
  try {
    return encodeFromBytes(decodeToBytes(value)) === value;
  } catch {
    return false;
  }
}

/**
 * Decode canonical Base64 to raw bytes.
 * Callers must confirm `isCanonicalBase64()` first; anything `atob` rejects
 * is turned into `ApiError` rather than escaping as a runtime error.
 */
export function decodeCanonicalBase64(value: string): Uint8Array {
  try {
    return decodeToBytes(value);
  } catch {
    throw validationFailed();
  }
}

/**
 * Nullable worldline -> non-null D1 key column. Draft §14.2.
 *
 * `null` becomes the empty string, never a sentinel UUID, and this value is
 * used only as a storage key: the API and the E2EE AAD keep the nullable
 * `worldline_id` itself.
 */
export function worldlineKey(worldlineId: string | null): string {
  return worldlineId ?? "";
}

export function requireNullableWorldlineId(value: unknown): string | null {
  if (value === null) {
    return null;
  }
  return requireUuid(value);
}
