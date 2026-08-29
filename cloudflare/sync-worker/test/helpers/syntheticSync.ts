import { applyD1Migrations, env } from "cloudflare:test";
import { exports } from "cloudflare:workers";
import type { D1Migration } from "cloudflare:test";
import { expect } from "vitest";

/**
 * Shared fixtures for the Phase 2 local synthetic sync suites.
 *
 * The identifiers below are the ones `tools/synthetic_sync_fixture.py` already
 * reserves, so the Worker suites and the Python contract fixture talk about the
 * same synthetic account. Only the identifiers and the scenario meanings are
 * carried across — the fixture itself is never imported, executed or
 * reimplemented here.
 *
 * Nothing in this module is real. There is no real account, device, token,
 * conversation or ciphertext: envelopes are fixed-shape sentinels, and the
 * "ciphertext" is a byte pattern with no key behind it.
 */

declare global {
  namespace Cloudflare {
    interface Env {
      DB: D1Database;
      ATTACHMENTS: R2Bucket;
      CURSOR_MAC_KEY: string;
      TEST_MIGRATIONS: D1Migration[];
    }
  }
}

export const db = env.DB;
export const bucket = env.ATTACHMENTS;
const worker = (exports as { default: ExportedHandler }).default;
type WorkerRequest = Parameters<NonNullable<ExportedHandler["fetch"]>>[0];

/** Reserved synthetic identifiers (tools/synthetic_sync_fixture.py). */
export const ACCOUNT_A = "A0000000-0000-4000-8000-000000000001";
export const ACCOUNT_B = "A0000000-0000-4000-8000-000000000002";
export const DEVICE_MAC = "80000000-0000-4000-8000-000000000001";
export const DEVICE_PHONE = "80000000-0000-4000-8000-000000000002";
/** The fixture keeps the tablet revoked, so it is the revoked-device case. */
export const DEVICE_TABLET = "80000000-0000-4000-8000-000000000003";
export const DEVICE_B_MAC = "80000000-0000-4000-8000-000000000004";
export const ROOM_SHARED = "10000000-0000-4000-8000-000000000001";
export const ATTACHMENT = "70000000-0000-4000-8000-000000000001";

export const TURN = "30000000-0000-4000-8000-000000000001";
export const MESSAGE = "40000000-0000-4000-8000-000000000001";

export const MAC = "MAC_SPACE";
export const PHONE = "PHONE_SPACE";
export const TABLET = "TABLET_SPACE";
export const TIMESTAMP = "2026-01-01T00:00:00Z";
export const REVOKED_AT = "2026-01-01T00:00:00Z";

export const SOURCE_BYTES = 96;
export const ATTACHMENT_ENVELOPE_OVERHEAD = 34;
export const CIPHERTEXT_BYTES = SOURCE_BYTES + ATTACHMENT_ENVELOPE_OVERHEAD;

/** A fixed-shape opaque envelope. Deliberately not encrypted. */
export function envelope(seed: number): string {
  const bytes = new Uint8Array(34);
  bytes[0] = 1;
  bytes[1] = 1;
  for (let index = 2; index < bytes.length; index += 1) {
    bytes[index] = (seed * 17 + index) & 0xff;
  }
  return base64(bytes);
}

/** The attachment "ciphertext": a byte sentinel with no key behind it. */
export function ciphertext(seed = 1): Uint8Array {
  const bytes = new Uint8Array(CIPHERTEXT_BYTES);
  for (let index = 0; index < bytes.length; index += 1) {
    bytes[index] = (seed * 31 + index * 7) & 0xff;
  }
  return bytes;
}

export function base64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function base64Url(bytes: Uint8Array): string {
  return base64(bytes).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

function tokenBytes(seed: number): Uint8Array {
  const bytes = new Uint8Array(32);
  for (let index = 0; index < bytes.length; index += 1) bytes[index] = (seed + index) & 0xff;
  return bytes;
}

export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes as BufferSource);
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export const TOKEN_MAC = `gdt1_${base64Url(tokenBytes(1))}`;
export const TOKEN_PHONE = `gdt1_${base64Url(tokenBytes(33))}`;
export const TOKEN_TABLET = `gdt1_${base64Url(tokenBytes(65))}`;
export const TOKEN_ACCOUNT_B = `gdt1_${base64Url(tokenBytes(97))}`;
export const TOKEN_UNKNOWN = `gdt1_${base64Url(tokenBytes(129))}`;

export const CANONICAL_UUID = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/;

export async function fetchWorker(request: Request): Promise<Response> {
  const response = await worker.fetch?.(
    request as unknown as WorkerRequest,
    env as never,
    {} as never,
  );
  if (response === undefined) {
    throw new Error("worker did not return a response");
  }
  return response;
}

function authorized(token: string | null, extra: Record<string, string> = {}): Headers {
  const headers = new Headers(extra);
  if (token !== null) {
    headers.set("Authorization", `Device ${token}`);
  }
  return headers;
}

/**
 * Post an operation as raw bytes.
 *
 * The body is serialised once and sent verbatim so a replay can be a
 * byte-identical retry, which is what the fingerprint is computed over.
 */
export async function postOperation(payload: unknown, token = TOKEN_MAC): Promise<Response> {
  return await fetchWorker(
    new Request("https://example.test/v1/sync/operations", {
      method: "POST",
      headers: authorized(token),
      body: JSON.stringify(payload),
    }),
  );
}

export async function postRawOperation(raw: string, token = TOKEN_MAC): Promise<Response> {
  return await fetchWorker(
    new Request("https://example.test/v1/sync/operations", {
      method: "POST",
      headers: authorized(token),
      body: raw,
    }),
  );
}

export async function putAttachmentContent(
  attachmentId: string,
  body: Uint8Array,
  token = TOKEN_PHONE,
): Promise<Response> {
  return await fetchWorker(
    new Request(`https://example.test/v1/attachments/${attachmentId}/content`, {
      method: "PUT",
      headers: authorized(token, { "Content-Length": String(body.byteLength) }),
      body,
    }),
  );
}

export async function completeAttachment(
  attachmentId: string,
  token = TOKEN_PHONE,
): Promise<Response> {
  return await fetchWorker(
    new Request(`https://example.test/v1/attachments/${attachmentId}/complete`, {
      method: "POST",
      headers: authorized(token),
    }),
  );
}

export async function downloadAttachment(
  attachmentId: string,
  token = TOKEN_MAC,
): Promise<Response> {
  return await fetchWorker(
    new Request(`https://example.test/v1/attachments/${attachmentId}/content`, {
      method: "GET",
      headers: authorized(token),
    }),
  );
}

export interface ChangeItem {
  change_seq: number;
  entity_type: string;
  change_kind: string;
  revision: number | null;
  identity: Record<string, unknown>;
  projection: Record<string, unknown>;
}

export interface ChangesResult {
  scanned_through_seq: number;
  account_high_watermark_seq: number;
  has_more: boolean;
  changes: ChangeItem[];
}

export async function getChanges(
  query = "",
  token = TOKEN_MAC,
): Promise<{ status: number; text: string; result: ChangesResult; requestId: string }> {
  const response = await fetchWorker(
    new Request(`https://example.test/v1/sync/changes${query}`, { headers: authorized(token) }),
  );
  const text = await response.text();
  const body = JSON.parse(text) as { request_id: string; result: ChangesResult };
  return { status: response.status, text, result: body.result, requestId: body.request_id };
}

export interface BootstrapItem {
  entity_type: string;
  identity: Record<string, unknown>;
  projection: Record<string, unknown>;
}

export interface BootstrapResult {
  snapshot_high_watermark_seq: number;
  has_more: boolean;
  next_cursor: string | null;
  items: BootstrapItem[];
}

export async function getBootstrap(
  query = "",
  token = TOKEN_MAC,
): Promise<{ status: number; text: string; result: BootstrapResult }> {
  const response = await fetchWorker(
    new Request(`https://example.test/v1/sync/bootstrap${query}`, { headers: authorized(token) }),
  );
  const text = await response.text();
  const body = JSON.parse(text) as { result: BootstrapResult };
  return { status: response.status, text, result: body.result };
}

/** Walk every bootstrap page, asserting the snapshot never moves. */
export async function drainBootstrap(
  limit: number,
  token = TOKEN_MAC,
): Promise<{ items: BootstrapItem[]; watermark: number; pages: number }> {
  const items: BootstrapItem[] = [];
  let query = `?limit=${limit}`;
  let watermark: number | null = null;
  for (let page = 1; page <= 100; page += 1) {
    const { result } = await getBootstrap(query, token);
    if (watermark === null) {
      watermark = result.snapshot_high_watermark_seq;
    }
    if (result.snapshot_high_watermark_seq !== watermark) {
      throw new Error("bootstrap snapshot moved between pages");
    }
    items.push(...result.items);
    if (!result.has_more) {
      return { items, watermark, pages: page };
    }
    query = `?cursor=${encodeURIComponent(result.next_cursor as string)}&limit=${limit}`;
  }
  throw new Error("bootstrap did not finish");
}

/** Every table the synthetic suites touch, in an order foreign keys allow. */
const TABLES = [
  "transaction_guard",
  "change_log",
  "operation_log",
  "bubble_extension_field",
  "bubble",
  "turn_extension_field",
  "checkpoint",
  "turn",
  "worldline",
  "group_state",
  "room_extension_field",
  "room_ai_state_ref",
  "room",
  "persona_snapshot_extension_field",
  "persona_snapshot_head",
  "persona_snapshot",
  "engine_profile",
  "attachment",
  "device",
  "account",
];

export async function applyMigrations(): Promise<void> {
  await applyD1Migrations(db, env.TEST_MIGRATIONS);
}

/**
 * Reset to the synthetic starting point: two accounts, three devices on the
 * first (one of them revoked), one on the second, and no rows anywhere else.
 * Every canonical row the suites need is then created through the real
 * operation route rather than seeded behind it.
 */
export async function resetSyntheticAccount(): Promise<void> {
  const listed = await bucket.list();
  if (listed.objects.length > 0) {
    await bucket.delete(listed.objects.map((object) => object.key));
  }
  for (const table of TABLES) {
    await db.prepare(`DELETE FROM ${table}`).run();
  }
  for (const accountId of [ACCOUNT_A, ACCOUNT_B]) {
    await db
      .prepare("INSERT INTO account (account_id, created_at) VALUES (?, ?)")
      .bind(accountId, TIMESTAMP)
      .run();
  }
  for (const [accountId, deviceId, space, platform, seed, revokedAt] of [
    [ACCOUNT_A, DEVICE_MAC, MAC, "macos", 1, null],
    [ACCOUNT_A, DEVICE_PHONE, PHONE, "android_phone", 33, null],
    [ACCOUNT_A, DEVICE_TABLET, TABLET, "android_tablet", 65, REVOKED_AT],
    [ACCOUNT_B, DEVICE_B_MAC, MAC, "macos", 97, null],
  ] as const) {
    await db
      .prepare(
        `INSERT INTO device
           (account_id, device_id, space_id, platform, display_name_enc,
            linked_at, revoked_at, key_generation, token_hash)
         VALUES (?, ?, ?, ?, NULL, ?, ?, 1, ?)`,
      )
      .bind(accountId, deviceId, space, platform, TIMESTAMP, revokedAt, await sha256Hex(tokenBytes(seed)))
      .run();
  }
}

/** A synthetic operation id, distinct per label. */
export function operationId(index: number): string {
  return `90000000-0000-4000-8000-${index.toString(16).toUpperCase().padStart(12, "0")}`;
}

export function createRoom(operation: string, spaceId: string, roomId: string, deviceId: string) {
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

export function patchRoom(operation: string, baseRevision: number, deviceId = DEVICE_MAC) {
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
    set: { status_message: envelope(2) },
    clear: [],
    created_at: TIMESTAMP,
  };
}

export async function createAttachment(operation: string, attachmentId = ATTACHMENT) {
  return {
    protocol_version: 1,
    operation_id: operation,
    device_id: DEVICE_PHONE,
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

export function createTurn(operation: string, turnId = TURN) {
  return {
    protocol_version: 1,
    operation_id: operation,
    device_id: DEVICE_MAC,
    op: "create_turn",
    entity_type: "turn",
    target: { space_id: MAC, room_id: ROOM_SHARED, worldline_id: null, turn_id: turnId },
    metadata_set: { created_by_device_id: DEVICE_MAC, created_at: TIMESTAMP },
    metadata_clear: [],
    set: { canonical_text: envelope(6) },
    clear: [],
    created_at: TIMESTAMP,
  };
}

export function createBubble(
  operation: string,
  messageId = MESSAGE,
  order = 0,
  attachmentId: string | null = ATTACHMENT,
) {
  const reference =
    attachmentId === null
      ? {}
      : {
          attachment_ref_attachment_id: attachmentId,
          attachment_ref_byte_size: CIPHERTEXT_BYTES,
        };
  return {
    protocol_version: 1,
    operation_id: operation,
    device_id: DEVICE_MAC,
    op: "create_bubble",
    entity_type: "bubble",
    target: {
      space_id: MAC,
      room_id: ROOM_SHARED,
      worldline_id: null,
      turn_id: TURN,
      message_id: messageId,
    },
    bubble_order: order,
    metadata_set: { timestamp: TIMESTAMP, ...reference },
    metadata_clear: [],
    set: { text: envelope(7) },
    clear: [],
    created_at: TIMESTAMP,
  };
}

export async function nextServerSeq(accountId = ACCOUNT_A): Promise<number> {
  const row = await db
    .prepare("SELECT next_server_seq AS n FROM account WHERE account_id = ?")
    .bind(accountId)
    .first<{ n: number }>();
  return row?.n ?? 0;
}

export async function countOf(table: string): Promise<number> {
  const row = await db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).first<{ n: number }>();
  return row?.n ?? 0;
}

/** Everything a scenario must leave untouched when it fails. */
export async function ledgerSnapshot(): Promise<Record<string, number>> {
  return {
    next_server_seq: await nextServerSeq(),
    operation_log: await countOf("operation_log"),
    change_log: await countOf("change_log"),
    transaction_guard: await countOf("transaction_guard"),
  };
}

export async function attachmentRow(
  attachmentId = ATTACHMENT,
  accountId = ACCOUNT_A,
): Promise<{ state: string; server_seq: number | null; r2_object_key: string } | null> {
  return await db
    .prepare(
      `SELECT state, server_seq, r2_object_key
         FROM attachment WHERE account_id = ? AND attachment_id = ?`,
    )
    .bind(accountId, attachmentId)
    .first();
}

export async function objectBytes(key: string): Promise<number[] | null> {
  const object = await bucket.get(key);
  return object === null ? null : [...new Uint8Array(await object.arrayBuffer())];
}

/**
 * Assert that a serialised response says nothing it must not.
 *
 * The object key is passed in rather than guessed, because it is generated by
 * the server and is the single most important thing that must never travel.
 */
export function expectNoLeak(serialised: string, objectKey: string | null = null): void {
  const forbidden = [
    "gdt1_",
    TOKEN_MAC,
    TOKEN_PHONE,
    "obj/",
    "SELECT ",
    "INSERT ",
    "UPDATE ",
    "worldline_key",
    "account_id",
    "stack",
    base64(ciphertext()),
  ];
  if (objectKey !== null) {
    forbidden.push(objectKey);
  }
  for (const leak of forbidden) {
    // The label names the rule, never the value that would have leaked.
    expect(serialised.includes(leak), `response leaked a forbidden value`).toBe(false);
  }
}
