/**
 * Shared fixtures and helpers for the remote synthetic smoke run.
 *
 * Everything here is synthetic. The identifiers are the reserved fixture UUIDs,
 * the "ciphertext" is a fixed byte pattern with no key behind it, and the
 * envelopes are shape sentinels that satisfy the v1 header check without ever
 * having been encrypted. No real conversation, attachment, device token or
 * recovery phrase is constructed, read or uploaded by this module.
 *
 * The Worker endpoint is never hardcoded: it is read from the environment, so
 * this file stays committable and account-neutral.
 */

/** Read the synthetic Worker base URL. Refuses anything that is not https. */
export function requireBaseUrl() {
  const raw = process.env["SYNTHETIC_WORKER_URL"];
  if (typeof raw !== "string" || raw.length === 0) {
    throw new Error("SYNTHETIC_WORKER_URL is not set");
  }
  const url = new URL(raw);
  if (url.protocol !== "https:") {
    throw new Error("SYNTHETIC_WORKER_URL must be https");
  }
  return raw.replace(/\/+$/, "");
}

// ── Synthetic identifiers ────────────────────────────────────────────────────
// The same reserved values tools/synthetic_sync_fixture.py uses, so the remote
// run, the local suites and the Python contract fixture describe one account.

export const ACCOUNT_A = "A0000000-0000-4000-8000-000000000001";
export const ACCOUNT_B = "A0000000-0000-4000-8000-000000000002";
export const DEVICE_MAC = "80000000-0000-4000-8000-000000000001";
export const DEVICE_PHONE = "80000000-0000-4000-8000-000000000002";
export const DEVICE_TABLET = "80000000-0000-4000-8000-000000000003";
export const DEVICE_B_MAC = "80000000-0000-4000-8000-000000000004";
export const ROOM_SHARED = "10000000-0000-4000-8000-000000000001";
export const TURN_MAIN = "30000000-0000-4000-8000-000000000001";
export const ATTACHMENT = "70000000-0000-4000-8000-000000000001";

export const MAC = "MAC_SPACE";
export const PHONE = "PHONE_SPACE";
export const TABLET = "TABLET_SPACE";
export const TIMESTAMP = "2026-01-01T00:00:00Z";

export const SOURCE_BYTES = 96;
export const CIPHERTEXT_BYTES = SOURCE_BYTES + 34;

/** `90000000-…` operation ids, one per index. */
export function operationId(index) {
  return `90000000-0000-4000-8000-${index.toString(16).toUpperCase().padStart(12, "0")}`;
}

/** `40000000-…` message ids, one per index. */
export function messageId(index) {
  return `40000000-0000-4000-8000-${index.toString(16).toUpperCase().padStart(12, "0")}`;
}

// ── Byte helpers ─────────────────────────────────────────────────────────────

export function base64(bytes) {
  return Buffer.from(bytes).toString("base64");
}

export function base64Url(bytes) {
  return Buffer.from(bytes).toString("base64url");
}

export function hex(bytes) {
  return Buffer.from(bytes).toString("hex");
}

export async function sha256(bytes) {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
}

export async function sha256Hex(bytes) {
  return hex(await sha256(bytes));
}

/**
 * A v1 envelope sentinel: the 6-byte header the contract checks, then filler.
 *
 * Deliberately not encrypted. The Worker never decrypts an envelope and never
 * inspects its nonce or tag, so a fixed pattern exercises the wire contract
 * exactly as a real envelope would.
 */
export function envelope(seed, length = 34) {
  const bytes = new Uint8Array(length);
  bytes[0] = 1;
  bytes[1] = 1;
  bytes[2] = 0;
  bytes[3] = 0;
  bytes[4] = 0;
  bytes[5] = 1;
  for (let index = 6; index < bytes.length; index += 1) {
    bytes[index] = (seed * 17 + index) & 0xff;
  }
  return base64(bytes);
}

/** Fixed 32 bytes, for the recovery lookup and verifier slots. */
export function binary32(seed) {
  const bytes = new Uint8Array(32);
  for (let index = 0; index < bytes.length; index += 1) {
    bytes[index] = (seed * 29 + index) & 0xff;
  }
  return base64(bytes);
}

/** The attachment payload: a byte sentinel with no key behind it. */
export function ciphertext(seed = 1) {
  const bytes = new Uint8Array(CIPHERTEXT_BYTES);
  for (let index = 0; index < bytes.length; index += 1) {
    bytes[index] = (seed * 31 + index * 7) & 0xff;
  }
  return bytes;
}

/**
 * A synthetic device token and the hash the server stores for it.
 *
 * The token is derived from a fixed seed rather than a CSPRNG so a rerun can
 * reuse the same synthetic device without a second enrollment. It authenticates
 * nothing but this throwaway synthetic account.
 */
export async function syntheticToken(seed) {
  const bytes = new Uint8Array(32);
  for (let index = 0; index < bytes.length; index += 1) {
    bytes[index] = (seed + index) & 0xff;
  }
  return { token: `gdt1_${base64Url(bytes)}`, tokenHash: await sha256Hex(bytes) };
}

// ── HTTP ─────────────────────────────────────────────────────────────────────

/**
 * One request against the synthetic Worker.
 *
 * The response body is read as text and returned for invariant checks, but the
 * caller never prints it: reporting is by status, error code and request id.
 */
export async function call(baseUrl, path, options = {}) {
  const headers = new Headers(options.headers ?? {});
  if (options.token) {
    headers.set("Authorization", `Device ${options.token}`);
  }
  const response = await fetch(`${baseUrl}${path}`, {
    method: options.method ?? "GET",
    headers,
    body: options.body ?? null,
  });
  const text = await response.text();
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {
    json = null;
  }
  return { status: response.status, headers: response.headers, text, json };
}

/** The error code of a failed response, or null when the body carried none. */
export function errorCode(response) {
  return response.json?.error?.code ?? null;
}

// ── Request bodies ───────────────────────────────────────────────────────────

export async function enrollmentBody({ accountId, deviceId, spaceId, platform, tokenHash, enrollmentId, seed }) {
  return JSON.stringify({
    protocol_version: 1,
    enrollment_id: enrollmentId,
    account_id: accountId,
    device: {
      device_id: deviceId,
      space_id: spaceId,
      platform,
      display_name: envelope(seed),
      device_token_hash: tokenHash,
    },
    recovery: {
      recovery_version: 1,
      recovery_lookup: binary32(seed),
      recovery_auth_verifier: binary32(seed + 1),
      wrapped_master_key: envelope(seed + 2, 64),
    },
  });
}

export function createRoom(operation, spaceId, roomId, deviceId) {
  return {
    protocol_version: 1,
    operation_id: operation,
    device_id: deviceId,
    op: "create_room",
    entity_type: "room",
    target: { space_id: spaceId, room_id: roomId, worldline_id: null },
    metadata_set: {},
    metadata_clear: [],
    set: { title: envelope(1) },
    clear: [],
    created_at: TIMESTAMP,
  };
}

export function patchRoom(operation, baseRevision, deviceId, seed = 2) {
  return {
    protocol_version: 1,
    operation_id: operation,
    device_id: deviceId,
    op: "patch_room",
    entity_type: "room",
    target: { space_id: MAC, room_id: ROOM_SHARED, worldline_id: null },
    base_revision: baseRevision,
    metadata_set: {},
    metadata_clear: [],
    set: { status_message: envelope(seed) },
    clear: [],
    created_at: TIMESTAMP,
  };
}

export async function createAttachment(operation, deviceId, attachmentId = ATTACHMENT) {
  return {
    protocol_version: 1,
    operation_id: operation,
    device_id: deviceId,
    op: "create_attachment",
    entity_type: "attachment",
    target: { space_id: PHONE, attachment_id: attachmentId },
    metadata_set: {
      origin_space_id: PHONE,
      kind: "attachment",
      source_byte_size: SOURCE_BYTES,
      ciphertext_byte_size: CIPHERTEXT_BYTES,
      ciphertext_hash: await sha256Hex(ciphertext()),
      key_generation: 1,
      created_at: TIMESTAMP,
    },
    metadata_clear: [],
    set: { file_name: envelope(3), mime_type: envelope(4), wrapped_file_key: envelope(5) },
    clear: [],
    created_at: TIMESTAMP,
  };
}

export function createTurn(operation, deviceId, turnId = TURN_MAIN) {
  return {
    protocol_version: 1,
    operation_id: operation,
    device_id: deviceId,
    op: "create_turn",
    entity_type: "turn",
    target: { space_id: MAC, room_id: ROOM_SHARED, worldline_id: null, turn_id: turnId },
    metadata_set: { created_by_device_id: deviceId, created_at: TIMESTAMP },
    metadata_clear: [],
    set: { canonical_text: envelope(6) },
    clear: [],
    created_at: TIMESTAMP,
  };
}

export function createBubble(operation, deviceId, message, order, attachmentId = null, seed = 7) {
  const reference =
    attachmentId === null
      ? {}
      : { attachment_ref_attachment_id: attachmentId, attachment_ref_byte_size: CIPHERTEXT_BYTES };
  return {
    protocol_version: 1,
    operation_id: operation,
    device_id: deviceId,
    op: "create_bubble",
    entity_type: "bubble",
    target: {
      space_id: MAC,
      room_id: ROOM_SHARED,
      worldline_id: null,
      turn_id: TURN_MAIN,
      message_id: message,
    },
    bubble_order: order,
    metadata_set: { timestamp: TIMESTAMP, ...reference },
    metadata_clear: [],
    set: { text: envelope(seed) },
    clear: [],
    created_at: TIMESTAMP,
  };
}

// ── Non-disclosure ───────────────────────────────────────────────────────────

/**
 * Assert that a serialised response says nothing it must not.
 *
 * The labels name the rule, never the value that would have leaked, so a
 * failure report stays as content-free as the responses it is checking.
 */
export function assertNoLeak(label, serialised, secrets) {
  const forbidden = [
    ["a device token", "gdt1_"],
    ["an R2 object key", "obj/"],
    ["a recovery object key", "recovery/"],
    ["SQL", "SELECT "],
    ["SQL", "INSERT "],
    ["SQL", "UPDATE "],
    ["a storage column", "worldline_key"],
    ["a stack trace", "\n    at "],
    ["a stack trace", "stack"],
  ];
  for (const [rule, needle] of forbidden) {
    if (serialised.includes(needle)) {
      throw new Error(`${label} leaked ${rule}`);
    }
  }
  for (const secret of secrets ?? []) {
    if (secret && serialised.includes(secret)) {
      throw new Error(`${label} leaked a synthetic secret value`);
    }
  }
}
