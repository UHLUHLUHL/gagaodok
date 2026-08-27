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

/** RFC 3339 UTC, as fixed by API draft §2.1. */
const RFC3339_UTC_PATTERN = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/;

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

export function requireRfc3339Utc(value: unknown): string {
  if (typeof value !== "string" || !RFC3339_UTC_PATTERN.test(value)) {
    throw validationFailed();
  }
  return value;
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
