import { applyD1Migrations, env } from "cloudflare:test";
import { exports } from "cloudflare:workers";
import type { D1Migration } from "cloudflare:test";
import { afterEach, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { handleBootstrapRequest } from "../src/routes/bootstrap";
import { setCursorClockForTest } from "../src/sync/bootstrapCursor";
import { BOOTSTRAP_ENTITY_ORDER } from "../src/sync/projection";
import type { Env } from "../src/env";

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

const db = env.DB;
const worker = (exports as { default: ExportedHandler }).default;
type WorkerRequest = Parameters<NonNullable<ExportedHandler["fetch"]>>[0];

// Synthetic fixtures only.
const ACCOUNT = "A0000000-0000-4000-8000-00000000000A";
const OTHER_ACCOUNT = "A0000000-0000-4000-8000-00000000000B";
const MAC_DEVICE = "B0000000-0000-4000-8000-000000000001";
const REVOKED_DEVICE = "B0000000-0000-4000-8000-000000000003";
const OTHER_DEVICE = "B0000000-0000-4000-8000-000000000004";
const ROOM = "10000000-0000-4000-8000-0000000000A1";
const PHONE_ROOM = "10000000-0000-4000-8000-0000000000A3";
const WORLDLINE = "20000000-0000-4000-8000-0000000000B1";
const TURN = "30000000-0000-4000-8000-0000000000C1";
const MESSAGE = "40000000-0000-4000-8000-0000000000D1";
const PROFILE = "50000000-0000-4000-8000-0000000000E1";
const SNAPSHOT = "60000000-0000-4000-8000-0000000000F1";
const CHECKPOINT = "80000000-0000-4000-8000-000000000091";
const ATTACHMENT = "70000000-0000-4000-8000-000000000081";
const MAC = "MAC_SPACE";
const PHONE = "PHONE_SPACE";
const TIMESTAMP = "2026-08-29T00:00:00Z";
const PATH = "/v1/sync/bootstrap";
const MAC_KEY = env.CURSOR_MAC_KEY;

function envelope(seed: number): string {
  const bytes = new Uint8Array(34);
  bytes[0] = 1;
  bytes[1] = 1;
  for (let index = 2; index < bytes.length; index += 1) bytes[index] = (seed + index) & 0xff;
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function syntheticTokenBytes(seed: number): Uint8Array {
  const bytes = new Uint8Array(32);
  for (let index = 0; index < bytes.length; index += 1) bytes[index] = (seed + index) & 0xff;
  return bytes;
}
function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}
async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes as BufferSource);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

const MAC_TOKEN = `gdt1_${base64Url(syntheticTokenBytes(1))}`;
const REVOKED_TOKEN = `gdt1_${base64Url(syntheticTokenBytes(65))}`;
const OTHER_TOKEN = `gdt1_${base64Url(syntheticTokenBytes(97))}`;
const UNKNOWN_TOKEN = `gdt1_${base64Url(syntheticTokenBytes(129))}`;

const CANONICAL_UUID = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/;

interface BootstrapBody {
  protocol_version: number;
  request_id: string;
  result: {
    snapshot_high_watermark_seq: number;
    has_more: boolean;
    next_cursor: string | null;
    items: { entity_type: string; identity: Record<string, unknown>; projection: Record<string, unknown> }[];
  };
}

async function call(query = "", token: string | null = MAC_TOKEN, method = "GET"): Promise<Response> {
  const headers = new Headers();
  if (token !== null) headers.set("Authorization", `Device ${token}`);
  const request = new Request(`https://example.test${PATH}${query}`, { method, headers });
  const response = await worker.fetch?.(request as unknown as WorkerRequest, env as never, {} as never);
  if (response === undefined) throw new Error("worker did not return a response");
  return response;
}

async function bodyOf(response: Response): Promise<BootstrapBody> {
  return (await response.json()) as BootstrapBody;
}

function expectContentFree(serialised: string): void {
  for (const leak of [MAC_KEY, "gdt1_", MAC_TOKEN, "SELECT", "obj/", "worldline_key", "stack"]) {
    expect(serialised, `response leaked ${leak}`).not.toContain(leak);
  }
}

async function run(sql: string, ...values: (string | number | null)[]): Promise<void> {
  await db
    .prepare(sql)
    .bind(...values)
    .run();
}

async function seedRoom(accountId: string, roomId: string, spaceId = MAC): Promise<void> {
  await run(
    `INSERT INTO room
       (account_id, space_id, room_id, origin_space_id, title_enc, status_message_enc, music_title_enc,
        music_artist_enc, revision, server_seq, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, NULL, NULL, NULL, 0, NULL, ?, ?)`,
    accountId,
    spaceId,
    roomId,
    spaceId,
    envelope(1),
    TIMESTAMP,
    TIMESTAMP,
  );
}

/** One row of every entity, in an account that can be walked end to end. */
async function seedEveryEntity(accountId = ACCOUNT): Promise<void> {
  await run(
    `INSERT INTO device
       (account_id, device_id, space_id, platform, display_name_enc,
        linked_at, revoked_at, key_generation, token_hash)
     VALUES (?, ?, ?, 'macos', NULL, ?, NULL, 1, NULL)`,
    accountId,
    "B0000000-0000-4000-8000-0000000000FF",
    MAC,
    TIMESTAMP,
  );
  await seedRoom(accountId, ROOM);
  await seedRoom(accountId, PHONE_ROOM, PHONE);
  await run(
    `INSERT INTO group_state
       (account_id, space_id, room_id, participants_enc, active_worldline_id_enc,
        revision, server_seq, created_at, updated_at)
     VALUES (?, ?, ?, ?, NULL, 0, NULL, ?, ?)`,
    accountId,
    PHONE,
    PHONE_ROOM,
    envelope(3),
    TIMESTAMP,
    TIMESTAMP,
  );
  await run(
    `INSERT INTO worldline
       (account_id, space_id, room_id, worldline_id, worldline_key, name_enc,
        participant_hearts_enc, revision, server_seq, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, NULL, 0, NULL, ?, ?)`,
    accountId,
    PHONE,
    PHONE_ROOM,
    WORLDLINE,
    WORLDLINE,
    envelope(4),
    TIMESTAMP,
    TIMESTAMP,
  );
  await run(
    `INSERT INTO turn
       (account_id, space_id, room_id, worldline_id, worldline_key, turn_id,
        canonical_text_enc, heart_changes_enc, generation_profile_ref_enc, fallback_reason_enc,
        created_by_device_id, created_at, revision, server_seq, is_tombstoned,
        tombstoned_at, tombstone_operation_id)
     VALUES (?, ?, ?, NULL, '', ?, ?, NULL, NULL, NULL, ?, ?, 0, NULL, 0, NULL, NULL)`,
    accountId,
    MAC,
    ROOM,
    TURN,
    envelope(5),
    "B0000000-0000-4000-8000-0000000000FF",
    TIMESTAMP,
  );
  await run(
    `INSERT INTO bubble
       (account_id, space_id, room_id, worldline_key, turn_id, message_id, bubble_order,
        sender_enc, kind_enc, text_enc, speaker_ref_enc, reactions_enc,
        attachment_ref_attachment_id, attachment_ref_byte_size, timestamp, revision,
        server_seq, is_tombstoned, tombstoned_at, tombstone_operation_id)
     VALUES (?, ?, ?, '', ?, ?, 0, ?, NULL, NULL, NULL, NULL, NULL, NULL, ?, 0, NULL, 0, NULL, NULL)`,
    accountId,
    MAC,
    ROOM,
    TURN,
    MESSAGE,
    envelope(6),
    TIMESTAMP,
  );
  await run(
    `INSERT INTO engine_profile
       (account_id, space_id, engine_profile_id, profile_revision, mode_enc, model_capability_enc,
        prompt_profile_id_enc, prompt_profile_version_enc, relationship_policy_enc,
        compaction_profile_id_enc, compaction_contract_fingerprint_enc, cache_policy_enc,
        repetition_policy_enc, compaction_compat_tag, server_seq)
     VALUES (?, ?, ?, 3, ?, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)`,
    accountId,
    MAC,
    PROFILE,
    envelope(8),
  );
  await run(
    `INSERT INTO persona_snapshot
       (account_id, space_id, persona_snapshot_id, snapshot_revision, owner_space_id,
        created_by_device_id, created_at, persona_schema_version, description_enc, samples_enc,
        style_guide_enc, is_enabled_enc, content_fingerprint_enc, server_seq)
     VALUES (?, ?, ?, 7, ?, ?, ?, 1, ?, NULL, NULL, NULL, NULL, NULL)`,
    accountId,
    MAC,
    SNAPSHOT,
    MAC,
    "B0000000-0000-4000-8000-0000000000FF",
    TIMESTAMP,
    envelope(9),
  );
  await run(
    `INSERT INTO persona_snapshot_head
       (account_id, space_id, persona_snapshot_id, current_snapshot_revision)
     VALUES (?, ?, ?, 7)`,
    accountId,
    MAC,
    SNAPSHOT,
  );
  await run(
    `INSERT INTO checkpoint
       (account_id, space_id, room_id, worldline_id, worldline_key, checkpoint_id,
        first_turn_id, last_turn_id, through_server_seq, segments_enc, summary_text_enc,
        checkpoint_schema_version, compaction_profile_id_enc, compaction_contract_fingerprint_enc,
        compaction_compat_tag, owner_space_id, created_by_device_id, created_at, revision, server_seq)
     VALUES (?, ?, ?, NULL, '', ?, ?, ?, 1, ?, NULL, 1, NULL, NULL, NULL, ?, ?, ?, 0, NULL)`,
    accountId,
    MAC,
    ROOM,
    CHECKPOINT,
    TURN,
    TURN,
    envelope(10),
    MAC,
    "B0000000-0000-4000-8000-0000000000FF",
    TIMESTAMP,
  );
  await run(
    `INSERT INTO attachment
       (account_id, attachment_id, origin_space_id, r2_object_key, kind, state,
        source_byte_size, ciphertext_byte_size, ciphertext_hash, key_generation,
        file_name_enc, mime_type_enc, wrapped_file_key_enc, created_at, server_seq)
     VALUES (?, ?, ?, ?, 'attachment', 'ready', 100, 134, ?, 1, ?, ?, ?, ?, NULL)`,
    accountId,
    ATTACHMENT,
    MAC,
    "obj/C0000000-0000-4000-8000-000000000001",
    "a".repeat(64),
    envelope(11),
    envelope(12),
    envelope(13),
    TIMESTAMP,
  );
}

beforeAll(async () => {
  await applyD1Migrations(db, env.TEST_MIGRATIONS);
});

afterEach(() => {
  setCursorClockForTest(null);
});

beforeEach(async () => {
  for (const table of [
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
  ]) {
    await db.prepare(`DELETE FROM ${table}`).run();
  }
  for (const accountId of [ACCOUNT, OTHER_ACCOUNT]) {
    await run("INSERT INTO account (account_id, created_at) VALUES (?, ?)", accountId, TIMESTAMP);
  }
  for (const [accountId, deviceId, seed, revokedAt] of [
    [ACCOUNT, MAC_DEVICE, 1, null],
    [ACCOUNT, REVOKED_DEVICE, 65, TIMESTAMP],
    [OTHER_ACCOUNT, OTHER_DEVICE, 97, null],
  ] as const) {
    await run(
      `INSERT INTO device
         (account_id, device_id, space_id, platform, display_name_enc,
          linked_at, revoked_at, key_generation, token_hash)
       VALUES (?, ?, ?, 'macos', NULL, ?, ?, 1, ?)`,
      accountId,
      deviceId,
      MAC,
      TIMESTAMP,
      revokedAt,
      await sha256Hex(syntheticTokenBytes(seed)),
    );
  }
});

/** Walk every page and return the flattened stream. */
async function drain(limit: number, token = MAC_TOKEN) {
  const items: { entity_type: string; identity: Record<string, unknown> }[] = [];
  let query = `?limit=${limit}`;
  let watermark: number | null = null;
  for (let page = 0; page < 50; page += 1) {
    const body = await bodyOf(await call(query, token));
    if (watermark === null) watermark = body.result.snapshot_high_watermark_seq;
    expect(body.result.snapshot_high_watermark_seq).toBe(watermark);
    expect(body.result.items.length).toBeLessThanOrEqual(limit);
    items.push(...body.result.items);
    if (!body.result.has_more) {
      expect(body.result.next_cursor).toBeNull();
      return { items, watermark };
    }
    expect(body.result.next_cursor).toBeTypeOf("string");
    query = `?cursor=${encodeURIComponent(body.result.next_cursor as string)}&limit=${limit}`;
  }
  throw new Error("bootstrap did not finish");
}

describe("GET /v1/sync/bootstrap — the snapshot", () => {
  it("returns every entity in the fixed order", async () => {
    await seedEveryEntity();
    const body = await bodyOf(await call());
    expect(body.request_id).toMatch(CANONICAL_UUID);
    expect(body.result.has_more).toBe(false);
    expect(body.result.next_cursor).toBeNull();

    const types = body.result.items.map((item) => item.entity_type);
    // Owners before the rows that name them, and the two rooms first.
    expect(types).toEqual([
      "room",
      "room",
      "group_state",
      "worldline",
      "turn",
      "bubble",
      "engine_profile",
      "persona_snapshot",
      "checkpoint",
      "attachment",
    ]);
    expect([...new Set(types)]).toEqual(
      BOOTSTRAP_ENTITY_ORDER.filter((entityType) => types.includes(entityType)),
    );
    expectContentFree(JSON.stringify(body));
  });

  it("completes normally for an empty account", async () => {
    const body = await bodyOf(await call());
    expect(body.result).toEqual({
      snapshot_high_watermark_seq: 0,
      has_more: false,
      next_cursor: null,
      items: [],
    });
  });

  it("pages across entity boundaries without skipping or repeating", async () => {
    await seedEveryEntity();
    const whole = await drain(500);
    for (const limit of [1, 2, 3, 4, 7]) {
      const paged = await drain(limit);
      expect(JSON.stringify(paged.items), `limit ${limit}`).toBe(JSON.stringify(whole.items));
    }
  });

  it("pages a composite key inside one entity", async () => {
    // Five bubbles in one turn: the page boundary falls inside the entity.
    await seedEveryEntity();
    const statements: D1PreparedStatement[] = [];
    for (let index = 0; index < 5; index += 1) {
      statements.push(
        db
          .prepare(
            `INSERT INTO bubble
               (account_id, space_id, room_id, worldline_key, turn_id, message_id, bubble_order,
                sender_enc, kind_enc, text_enc, speaker_ref_enc, reactions_enc,
                attachment_ref_attachment_id, attachment_ref_byte_size, timestamp, revision,
                server_seq, is_tombstoned, tombstoned_at, tombstone_operation_id)
             VALUES (?, ?, ?, '', ?, ?, ?, NULL, NULL, NULL, NULL, NULL, NULL, NULL, ?, 0, NULL, 0, NULL, NULL)`,
          )
          .bind(
            ACCOUNT,
            MAC,
            ROOM,
            TURN,
            `41000000-0000-4000-8000-00000000000${index}`,
            index + 1,
            TIMESTAMP,
          ),
      );
    }
    await db.batch(statements);

    const whole = await drain(500);
    const paged = await drain(2);
    expect(JSON.stringify(paged.items)).toBe(JSON.stringify(whole.items));
    expect(whole.items.filter((item) => item.entity_type === "bubble").length).toBe(6);
  });

  it("changing the limit between pages neither skips nor repeats", async () => {
    await seedEveryEntity();
    const whole = await drain(500);

    const items: { entity_type: string; identity: Record<string, unknown> }[] = [];
    let query = "?limit=1";
    const limits = [3, 1, 5, 2, 500];
    for (let page = 0; page < 50; page += 1) {
      const body = await bodyOf(await call(query));
      items.push(...body.result.items);
      if (!body.result.has_more) break;
      const limit = limits[page % limits.length] as number;
      query = `?cursor=${encodeURIComponent(body.result.next_cursor as string)}&limit=${limit}`;
    }
    expect(JSON.stringify(items)).toBe(JSON.stringify(whole.items));
  });
});

describe("GET /v1/sync/bootstrap — the snapshot boundary", () => {
  it("keeps the first page's watermark and leaves later rows to the cursor", async () => {
    await seedEveryEntity();
    await run("UPDATE account SET next_server_seq = 5 WHERE account_id = ?", ACCOUNT);

    const first = await bodyOf(await call("?limit=1"));
    expect(first.result.snapshot_high_watermark_seq).toBe(4);
    expect(first.result.has_more).toBe(true);

    // A write lands mid-bootstrap, behind the cursor's current position.
    await run("UPDATE account SET next_server_seq = 9 WHERE account_id = ?", ACCOUNT);
    await run(
      `INSERT INTO room
         (account_id, space_id, room_id, origin_space_id, title_enc, status_message_enc, music_title_enc,
          music_artist_enc, revision, server_seq, created_at, updated_at)
       VALUES (?, ?, '10000000-0000-4000-8000-0000000000A0', ?, ?, NULL, NULL, NULL, 0, 5, ?, ?)`,
      ACCOUNT,
      MAC,
      MAC,
      envelope(1),
      TIMESTAMP,
      TIMESTAMP,
    );
    await run(
      `INSERT INTO change_log
         (account_id, server_seq, entity_type, change_kind, revision, space_id, room_id)
       VALUES (?, 5, 'room', 'upsert', 0, ?, '10000000-0000-4000-8000-0000000000A0')`,
      ACCOUNT,
      MAC,
    );

    const second = await bodyOf(
      await call(`?cursor=${encodeURIComponent(first.result.next_cursor as string)}&limit=500`),
    );
    // The snapshot did not move under the client.
    expect(second.result.snapshot_high_watermark_seq).toBe(4);
    const ids = second.result.items.map((item) => item.identity["room_id"]);
    // The row created behind the cursor is not in this bootstrap...
    expect(ids).not.toContain("10000000-0000-4000-8000-0000000000A0");

    // ...and the changes cursor started at the watermark picks it up.
    const changes = (await (
      await worker.fetch?.(
        new Request("https://example.test/v1/sync/changes?after_seq=4", {
          headers: new Headers({ Authorization: `Device ${MAC_TOKEN}` }),
        }) as unknown as WorkerRequest,
        env as never,
        {} as never,
      )
    )?.json()) as { result: { changes: { identity: Record<string, unknown> }[] } };
    expect(changes.result.changes.map((change) => change.identity["room_id"])).toContain(
      "10000000-0000-4000-8000-0000000000A0",
    );
  });

  it("is harmless to re-apply a pulled change over a newer bootstrap projection", async () => {
    // Bootstrap may hand back a projection newer than the watermark. Replaying
    // the older change afterwards writes the same current projection, because
    // both read the same row.
    await seedEveryEntity();
    await run("UPDATE account SET next_server_seq = 2 WHERE account_id = ?", ACCOUNT);
    await run(
      `INSERT INTO change_log
         (account_id, server_seq, entity_type, change_kind, revision, space_id, room_id)
       VALUES (?, 1, 'room', 'upsert', 0, ?, ?)`,
      ACCOUNT,
      MAC,
      ROOM,
    );

    const boot = await bodyOf(await call("?limit=500"));
    const bootRoom = boot.result.items.find(
      (item) => item.entity_type === "room" && item.identity["room_id"] === ROOM,
    );
    const changes = (await (
      await worker.fetch?.(
        new Request("https://example.test/v1/sync/changes?after_seq=0", {
          headers: new Headers({ Authorization: `Device ${MAC_TOKEN}` }),
        }) as unknown as WorkerRequest,
        env as never,
        {} as never,
      )
    )?.json()) as { result: { changes: { projection: Record<string, unknown> }[] } };

    // Byte-identical: one registry, one shape.
    expect(JSON.stringify(changes.result.changes[0]?.projection)).toBe(
      JSON.stringify(bootRoom?.projection),
    );
  });
});

describe("GET /v1/sync/bootstrap — the cursor", () => {
  async function firstCursor(): Promise<string> {
    await seedEveryEntity();
    const body = await bodyOf(await call("?limit=1"));
    return body.result.next_cursor as string;
  }

  it("refuses a tampered payload or signature", async () => {
    const cursor = await firstCursor();
    const [payload, mac] = cursor.split(".") as [string, string];
    for (const forged of [
      `${payload}A.${mac}`,
      `${payload}.${mac}A`,
      `${payload}.${mac.slice(0, -1)}B`,
      payload,
      `${payload}.${mac}.${mac}`,
      `.${mac}`,
      `${payload}.`,
    ]) {
      const response = await call(`?cursor=${encodeURIComponent(forged)}`);
      expect(response.status, `accepted ${forged.slice(0, 24)}`).toBe(400);
      const body = (await response.json()) as Record<string, unknown>;
      expect(body["error"]).toEqual({ code: "VALIDATION_FAILED", retryable: false });
      expect(body["request_id"]).toMatch(CANONICAL_UUID);
      expectContentFree(JSON.stringify(body));
    }
  });

  it("refuses a non-canonical Base64URL spelling", async () => {
    const cursor = await firstCursor();
    const [payload, mac] = cursor.split(".") as [string, string];

    // A final quantum carries bits past the encoded bytes, and they are
    // discarded on decode. Several spellings therefore decode to the same 32
    // bytes, and only the one the encoder produces may be accepted.
    const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    const lastIndex = ALPHABET.indexOf(mac[mac.length - 1] as string);
    const alias = ALPHABET[(lastIndex & ~3) + ((lastIndex + 1) & 3)] as string;
    const aliasedMac = `${mac.slice(0, -1)}${alias}`;
    expect(aliasedMac).not.toBe(mac);

    for (const forged of [
      `${payload}=.${mac}`,
      `${payload.replaceAll("-", "+")}.${mac}`,
      `${payload.replaceAll("_", "/")}.${mac}`,
      `${payload}.${aliasedMac}`,
    ]) {
      if (forged === cursor) continue;
      expect((await call(`?cursor=${encodeURIComponent(forged)}`)).status, forged.slice(-8)).toBe(400);
    }
  });

  it("refuses another account's cursor", async () => {
    const cursor = await firstCursor();
    const response = await call(`?cursor=${encodeURIComponent(cursor)}`, OTHER_TOKEN);
    // The signature is genuine; the account it names is not the caller's.
    expect(response.status).toBe(400);
  });

  it("refuses an expired cursor", async () => {
    const cursor = await firstCursor();
    // One second past the hour the cursor was issued for.
    setCursorClockForTest(() => Math.floor(Date.now() / 1000) + 3601);
    const response = await call(`?cursor=${encodeURIComponent(cursor)}`);
    expect(response.status).toBe(400);
    setCursorClockForTest(null);
    expect((await call(`?cursor=${encodeURIComponent(cursor)}`)).status).toBe(200);
  });

  it("refuses an unknown version and an out-of-range position", async () => {
    await seedEveryEntity();
    const encode = (payload: unknown[]): Promise<string> => signPayload(payload);
    for (const payload of [
      [2, ACCOUNT, 0, 0, [MAC, ROOM], Math.floor(Date.now() / 1000) + 60],
      [1, ACCOUNT, 0, 99, [MAC, ROOM], Math.floor(Date.now() / 1000) + 60],
      [1, ACCOUNT, 0, -1, [MAC, ROOM], Math.floor(Date.now() / 1000) + 60],
      [1, ACCOUNT, -1, 0, [MAC, ROOM], Math.floor(Date.now() / 1000) + 60],
      [1, ACCOUNT, 0, 0, "not-an-array", Math.floor(Date.now() / 1000) + 60],
      [1, ACCOUNT, 0, 0, [{ nested: true }], Math.floor(Date.now() / 1000) + 60],
      [1, ACCOUNT, 0, 0, [MAC, ROOM]],
    ]) {
      const token = await encode(payload as unknown[]);
      const response = await call(`?cursor=${encodeURIComponent(token)}`);
      expect(response.status, `accepted ${JSON.stringify(payload).slice(0, 40)}`).toBe(400);
    }
  });

  it("refuses to issue or verify with a server key that is too short", async () => {
    await seedEveryEntity();
    const shortKeyEnv = { ...env, CURSOR_MAC_KEY: "too-short" } as unknown as Env;
    const response = await handleBootstrapRequest(
      new Request(`https://example.test${PATH}?limit=1`, {
        headers: new Headers({ Authorization: `Device ${MAC_TOKEN}` }),
      }),
      shortKeyEnv,
    );
    expect(response.status).toBe(400);
    const serialised = JSON.stringify(await response.json());
    expect(serialised).not.toContain("too-short");
    expectContentFree(serialised);
  });

  it("never puts the MAC key in a response", async () => {
    await seedEveryEntity();
    const body = await bodyOf(await call("?limit=1"));
    const serialised = JSON.stringify(body);
    expect(serialised).not.toContain(MAC_KEY);
    expect(serialised).not.toContain("CURSOR_MAC_KEY");
  });
});

/** Sign an arbitrary payload with the real server key, for forgery tests. */
async function signPayload(payload: unknown[]): Promise<string> {
  const bytes = new TextEncoder().encode(JSON.stringify(payload));
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(MAC_KEY) as BufferSource,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(await crypto.subtle.sign("HMAC", key, bytes as BufferSource));
  const encode = (raw: Uint8Array): string => {
    let binary = "";
    for (const byte of raw) binary += String.fromCharCode(byte);
    return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
  };
  return `${encode(bytes)}.${encode(signature)}`;
}

describe("GET /v1/sync/bootstrap — the query, authentication and cost", () => {
  it("refuses unknown, repeated and non-canonical parameters", async () => {
    await seedEveryEntity();
    for (const query of [
      "?limit=0",
      "?limit=501",
      "?limit=",
      "?limit=007",
      "?limit=+1",
      "?limit=1.0",
      "?limit=1&limit=2",
      "?cursor=",
      "?unknown=1",
      "?after_seq=1",
    ]) {
      const response = await call(query);
      expect(response.status, `accepted ${query}`).toBe(400);
      expect(((await response.json()) as Record<string, unknown>)["request_id"]).toMatch(
        CANONICAL_UUID,
      );
    }
  });

  it("refuses unknown, missing and revoked tokens", async () => {
    expect((await call("", UNKNOWN_TOKEN)).status).toBe(401);
    expect((await call("", null)).status).toBe(401);
    expect((await call("", REVOKED_TOKEN)).status).toBe(403);
  });

  it("never returns another account's rows", async () => {
    await seedEveryEntity(ACCOUNT);
    const theirs = await bodyOf(await call("", OTHER_TOKEN));
    expect(theirs.result.items).toEqual([]);
  });

  it("refuses the path with another method and gives it no request id", async () => {
    const response = await call("", MAC_TOKEN, "POST");
    expect(response.status).toBe(404);
    expect(((await response.json()) as Record<string, unknown>)["request_id"]).toBeUndefined();
  });

  it("does not query once per item", async () => {
    await seedEveryEntity();
    let prepared = 0;
    const counting = {
      prepare(sql: string) {
        prepared += 1;
        return db.prepare(sql);
      },
      batch: db.batch.bind(db),
    };
    const response = await handleBootstrapRequest(
      new Request(`https://example.test${PATH}?limit=500`, {
        headers: new Headers({ Authorization: `Device ${MAC_TOKEN}` }),
      }),
      { DB: counting as unknown as D1Database, CURSOR_MAC_KEY: MAC_KEY } as Env,
    );
    expect(response.status).toBe(200);
    const body = (await response.json()) as BootstrapBody;
    expect(body.result.items.length).toBe(10);
    // Authentication, the watermark, then one owner read per entity plus the
    // extension, reference and head reads those entities need.
    expect(prepared).toBeLessThanOrEqual(25);
  });
});
