import { applyD1Migrations, env } from "cloudflare:test";
import { exports } from "cloudflare:workers";
import type { D1Migration } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";

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
const PHONE_DEVICE = "B0000000-0000-4000-8000-000000000002";
const REVOKED_DEVICE = "B0000000-0000-4000-8000-000000000003";
const OTHER_DEVICE = "B0000000-0000-4000-8000-000000000004";
const ROOM = "10000000-0000-4000-8000-0000000000A1";
const ROOM_2 = "10000000-0000-4000-8000-0000000000A2";
const ATTACHMENT = "70000000-0000-4000-8000-000000000081";
const MAC = "MAC_SPACE";
const TIMESTAMP = "2026-08-29T00:00:00Z";
const PATH = "/v1/sync/changes";

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
const PHONE_TOKEN = `gdt1_${base64Url(syntheticTokenBytes(33))}`;
const REVOKED_TOKEN = `gdt1_${base64Url(syntheticTokenBytes(65))}`;
const OTHER_TOKEN = `gdt1_${base64Url(syntheticTokenBytes(97))}`;
const UNKNOWN_TOKEN = `gdt1_${base64Url(syntheticTokenBytes(129))}`;

const CANONICAL_UUID = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/;

async function call(query = "", token: string | null = MAC_TOKEN, method = "GET"): Promise<Response> {
  const headers = new Headers();
  if (token !== null) {
    headers.set("Authorization", `Device ${token}`);
  }
  const request = new Request(`https://example.test${PATH}${query}`, { method, headers });
  const response = await worker.fetch?.(request as unknown as WorkerRequest, env as never, {} as never);
  if (response === undefined) throw new Error("worker did not return a response");
  return response;
}

interface ChangesBody {
  protocol_version: number;
  request_id: string;
  result: {
    scanned_through_seq: number;
    account_high_watermark_seq: number;
    has_more: boolean;
    changes: {
      change_seq: number;
      entity_type: string;
      change_kind: string;
      revision: number | null;
      identity: Record<string, unknown>;
      projection: Record<string, unknown>;
    }[];
  };
}

async function bodyOf(response: Response): Promise<ChangesBody> {
  return (await response.json()) as ChangesBody;
}

function expectContentFree(serialised: string): void {
  for (const leak of ["gdt1_", MAC_TOKEN, "SELECT", "obj/", "worldline_key", "account_id", "stack"]) {
    expect(serialised, `response leaked ${leak}`).not.toContain(leak);
  }
}

async function run(sql: string, ...values: (string | number | null)[]): Promise<void> {
  await db
    .prepare(sql)
    .bind(...values)
    .run();
}

async function seedRoom(accountId: string, roomId: string, revision = 0): Promise<void> {
  await run(
    `INSERT INTO room
       (account_id, space_id, room_id, title_enc, status_message_enc, music_title_enc,
        music_artist_enc, revision, server_seq, created_at, updated_at)
     VALUES (?, ?, ?, ?, NULL, NULL, NULL, ?, NULL, ?, ?)`,
    accountId,
    MAC,
    roomId,
    envelope(1),
    revision,
    TIMESTAMP,
    TIMESTAMP,
  );
}

async function seedRoomChange(
  accountId: string,
  serverSeq: number,
  roomId: string,
  revision = 0,
): Promise<void> {
  await run(
    `INSERT INTO change_log
       (account_id, server_seq, entity_type, change_kind, revision, space_id, room_id)
     VALUES (?, ?, 'room', 'upsert', ?, ?, ?)`,
    accountId,
    serverSeq,
    revision,
    MAC,
    roomId,
  );
}

async function setSequence(accountId: string, next: number): Promise<void> {
  await run("UPDATE account SET next_server_seq = ? WHERE account_id = ?", next, accountId);
}

beforeAll(async () => {
  await applyD1Migrations(db, env.TEST_MIGRATIONS);
});

beforeEach(async () => {
  for (const table of [
    "transaction_guard",
    "change_log",
    "operation_log",
    "attachment",
    "room_extension_field",
    "room_ai_state_ref",
    "room",
    "device",
    "account",
  ]) {
    await db.prepare(`DELETE FROM ${table}`).run();
  }
  for (const accountId of [ACCOUNT, OTHER_ACCOUNT]) {
    await run("INSERT INTO account (account_id, created_at) VALUES (?, ?)", accountId, TIMESTAMP);
  }
  for (const [accountId, deviceId, space, platform, seed, revokedAt] of [
    [ACCOUNT, MAC_DEVICE, MAC, "macos", 1, null],
    [ACCOUNT, PHONE_DEVICE, "PHONE_SPACE", "android_phone", 33, null],
    [ACCOUNT, REVOKED_DEVICE, MAC, "macos", 65, TIMESTAMP],
    [OTHER_ACCOUNT, OTHER_DEVICE, MAC, "macos", 97, null],
  ] as const) {
    await run(
      `INSERT INTO device
         (account_id, device_id, space_id, platform, display_name_enc,
          linked_at, revoked_at, key_generation, token_hash)
       VALUES (?, ?, ?, ?, NULL, ?, ?, 1, ?)`,
      accountId,
      deviceId,
      space,
      platform,
      TIMESTAMP,
      revokedAt,
      await sha256Hex(syntheticTokenBytes(seed)),
    );
  }
});

/** Three room changes at sequences 1..3, with the account sequence past them. */
async function seedThreeChanges(): Promise<void> {
  await seedRoom(ACCOUNT, ROOM, 3);
  for (let seq = 1; seq <= 3; seq += 1) {
    await seedRoomChange(ACCOUNT, seq, ROOM, seq);
  }
  await setSequence(ACCOUNT, 4);
}

describe("GET /v1/sync/changes — the page", () => {
  it("returns every change up to the watermark with the default query", async () => {
    await seedThreeChanges();
    const response = await call();
    expect(response.status).toBe(200);
    const body = await bodyOf(response);

    expect(body.protocol_version).toBe(1);
    expect(body.request_id).toMatch(CANONICAL_UUID);
    expect(body.result.account_high_watermark_seq).toBe(3);
    expect(body.result.has_more).toBe(false);
    expect(body.result.scanned_through_seq).toBe(3);
    expect(body.result.changes.map((change) => change.change_seq)).toEqual([1, 2, 3]);
    expect(body.result.changes[0]).toMatchObject({
      entity_type: "room",
      change_kind: "upsert",
      revision: 1,
      identity: { space_id: MAC, room_id: ROOM },
    });
    expect(body.result.changes[0]?.projection["title"]).toBe(envelope(1));
    expectContentFree(JSON.stringify(body));
  });

  it("honours limit 1 and limit 500", async () => {
    await seedThreeChanges();

    const one = await bodyOf(await call("?limit=1"));
    expect(one.result.changes.map((change) => change.change_seq)).toEqual([1]);
    expect(one.result.has_more).toBe(true);
    // The cursor only advances as far as the client actually got.
    expect(one.result.scanned_through_seq).toBe(1);

    const all = await bodyOf(await call("?limit=500"));
    expect(all.result.changes.length).toBe(3);
    expect(all.result.has_more).toBe(false);
  });

  it("pages in a stable order across the whole ledger", async () => {
    await seedRoom(ACCOUNT, ROOM, 10);
    for (let seq = 1; seq <= 10; seq += 1) {
      await seedRoomChange(ACCOUNT, seq, ROOM, seq);
    }
    await setSequence(ACCOUNT, 11);

    const seen: number[] = [];
    let after = 0;
    for (let page = 0; page < 10; page += 1) {
      const body = await bodyOf(await call(`?after_seq=${after}&limit=3`));
      seen.push(...body.result.changes.map((change) => change.change_seq));
      after = body.result.scanned_through_seq;
      if (!body.result.has_more) break;
    }
    expect(seen).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
  });

  it("treats a gap in the sequence as nothing to fetch, not as more", async () => {
    // 1 and 5 exist; 2..4 were consumed by operations that rolled back.
    await seedRoom(ACCOUNT, ROOM, 2);
    await seedRoomChange(ACCOUNT, 1, ROOM, 1);
    await seedRoomChange(ACCOUNT, 5, ROOM, 2);
    await setSequence(ACCOUNT, 9);

    const body = await bodyOf(await call("?limit=2"));
    expect(body.result.changes.map((change) => change.change_seq)).toEqual([1, 5]);
    expect(body.result.has_more).toBe(false);
    // Nothing is left behind, so the cursor moves to the ceiling itself.
    expect(body.result.account_high_watermark_seq).toBe(8);
    expect(body.result.scanned_through_seq).toBe(8);
  });

  it("advances an empty page to the watermark", async () => {
    await seedThreeChanges();
    const body = await bodyOf(await call("?after_seq=3"));
    expect(body.result.changes).toEqual([]);
    expect(body.result.has_more).toBe(false);
    expect(body.result.scanned_through_seq).toBe(3);
    expect(body.result.account_high_watermark_seq).toBe(3);
  });

  it("answers an account with no ledger at all", async () => {
    const body = await bodyOf(await call());
    expect(body.result).toEqual({
      scanned_through_seq: 0,
      account_high_watermark_seq: 0,
      has_more: false,
      changes: [],
    });
  });

  it("does not mix in writes that land after the watermark was taken", async () => {
    await seedThreeChanges();
    const body = await bodyOf(await call());
    expect(body.result.account_high_watermark_seq).toBe(3);

    // A write commits after that page was built.
    await seedRoom(ACCOUNT, ROOM_2, 1);
    await seedRoomChange(ACCOUNT, 4, ROOM_2, 1);
    await setSequence(ACCOUNT, 5);

    // The already-returned page is unaffected, and the next call picks it up
    // from exactly where the cursor stopped.
    const next = await bodyOf(await call(`?after_seq=${body.result.scanned_through_seq}`));
    expect(next.result.changes.map((change) => change.change_seq)).toEqual([4]);
    expect(next.result.account_high_watermark_seq).toBe(4);
  });

  it("keeps one item per change when an identity changes repeatedly", async () => {
    await seedThreeChanges();
    const body = await bodyOf(await call());
    expect(body.result.changes.length).toBe(3);
    // Same identity three times, each with its own revision, all carrying the
    // one current projection.
    for (const change of body.result.changes) {
      expect(change.identity).toEqual({ space_id: MAC, room_id: ROOM });
      expect(change.projection["revision"]).toBe(3);
    }
    expect(body.result.changes.map((change) => change.revision)).toEqual([1, 2, 3]);
  });

  it("carries an attachment ready event with a null revision", async () => {
    await run(
      `INSERT INTO attachment
         (account_id, attachment_id, origin_space_id, r2_object_key, kind, state,
          source_byte_size, ciphertext_byte_size, ciphertext_hash, key_generation,
          file_name_enc, mime_type_enc, wrapped_file_key_enc, created_at, server_seq)
       VALUES (?, ?, ?, ?, 'attachment', 'ready', 100, 134, ?, 1, ?, ?, ?, ?, 1)`,
      ACCOUNT,
      ATTACHMENT,
      MAC,
      "obj/C0000000-0000-4000-8000-000000000001",
      "a".repeat(64),
      envelope(2),
      envelope(3),
      envelope(4),
      TIMESTAMP,
    );
    await run(
      `INSERT INTO change_log
         (account_id, server_seq, entity_type, change_kind, revision, attachment_id)
       VALUES (?, 1, 'attachment', 'upsert', NULL, ?)`,
      ACCOUNT,
      ATTACHMENT,
    );
    await setSequence(ACCOUNT, 2);

    const body = await bodyOf(await call());
    const change = body.result.changes[0];
    expect(change?.entity_type).toBe("attachment");
    expect(change?.revision).toBeNull();
    expect(change?.identity).toEqual({ attachment_id: ATTACHMENT });
    expect(change?.projection["state"]).toBe("ready");
    expect(JSON.stringify(body)).not.toContain("obj/");
  });
});

describe("GET /v1/sync/changes — replay", () => {
  /** A toy replica: last write per identity wins, applied in cursor order. */
  function applyPage(replica: Map<string, unknown>, body: ChangesBody): void {
    for (const change of body.result.changes) {
      replica.set(`${change.entity_type} ${JSON.stringify(change.identity)}`, change.projection);
    }
  }

  it("is byte-identical apart from the request id when a page is fetched twice", async () => {
    await seedThreeChanges();
    const first = await (await call("?after_seq=0&limit=2")).text();
    const second = await (await call("?after_seq=0&limit=2")).text();

    const stripId = (text: string): string =>
      text.replace(/"request_id":"[0-9A-F-]{36}"/, '"request_id":"<id>"');
    expect(stripId(first)).toBe(stripId(second));
    expect(first).not.toBe(second);
  });

  it("leaves the replica unchanged when the same page is applied twice", async () => {
    await seedThreeChanges();
    const body = await bodyOf(await call());

    const once = new Map<string, unknown>();
    applyPage(once, body);
    const twice = new Map<string, unknown>();
    applyPage(twice, body);
    applyPage(twice, body);

    expect(JSON.stringify([...twice])).toBe(JSON.stringify([...once]));
  });
});

describe("GET /v1/sync/changes — the query", () => {
  it("refuses every non-canonical spelling", async () => {
    await seedThreeChanges();
    for (const query of [
      "?after_seq=",
      "?after_seq=01",
      "?after_seq=+1",
      "?after_seq=-1",
      "?after_seq=1.0",
      "?after_seq=1e2",
      "?after_seq=0x1",
      "?after_seq=%201",
      "?limit=0",
      "?limit=501",
      "?limit=",
      "?limit=007",
      "?after_seq=1&after_seq=2",
      "?limit=1&limit=2",
      "?unknown=1",
      "?after_seq=1&nope=2",
      `?after_seq=${9007199254740991 + 1}`,
    ]) {
      const response = await call(query);
      expect(response.status, `accepted ${query}`).toBe(400);
      const body = (await response.json()) as Record<string, unknown>;
      expect(body["error"]).toEqual({ code: "VALIDATION_FAILED", retryable: false });
      expect(body["request_id"]).toMatch(CANONICAL_UUID);
    }
  });

  it("refuses a cursor ahead of the account's own sequence", async () => {
    await seedThreeChanges();
    const response = await call("?after_seq=4");
    expect(response.status).toBe(400);
    expect(((await response.json()) as Record<string, unknown>)["error"]).toMatchObject({
      code: "VALIDATION_FAILED",
    });
    // The watermark itself is still a valid position.
    expect((await call("?after_seq=3")).status).toBe(200);
  });
});

describe("GET /v1/sync/changes — authentication and routing", () => {
  it("serves every linked device of the account, whatever space it is in", async () => {
    await seedThreeChanges();
    for (const token of [MAC_TOKEN, PHONE_TOKEN]) {
      const body = await bodyOf(await call("", token));
      // Account-wide: the phone reads MAC_SPACE changes it may not write.
      expect(body.result.changes.length).toBe(3);
    }
  });

  it("refuses unknown, missing and revoked tokens", async () => {
    expect((await call("", UNKNOWN_TOKEN)).status).toBe(401);
    expect((await call("", null)).status).toBe(401);
    const revoked = await call("", REVOKED_TOKEN);
    expect(revoked.status).toBe(403);
    const body = (await revoked.json()) as Record<string, unknown>;
    expect(body["error"]).toEqual({ code: "DEVICE_REVOKED", retryable: false });
    expect(body["request_id"]).toMatch(CANONICAL_UUID);
    expectContentFree(JSON.stringify(body));
  });

  it("never shows one account another's ledger", async () => {
    await seedThreeChanges();
    await seedRoom(OTHER_ACCOUNT, ROOM_2, 1);
    await seedRoomChange(OTHER_ACCOUNT, 1, ROOM_2, 1);
    await setSequence(OTHER_ACCOUNT, 2);

    const theirs = await bodyOf(await call("", OTHER_TOKEN));
    expect(theirs.result.changes.map((change) => change.identity["room_id"])).toEqual([ROOM_2]);
    expect(JSON.stringify(theirs)).not.toContain(ROOM);
  });

  it("refuses the path with another method and gives it no request id", async () => {
    const response = await call("", MAC_TOKEN, "POST");
    expect(response.status).toBe(404);
    const body = (await response.json()) as Record<string, unknown>;
    expect(body["error"]).toEqual({ code: "NOT_FOUND", retryable: false });
    expect(body["request_id"]).toBeUndefined();
  });

  it("neither reads nor returns the v1-forbidden sync headers", async () => {
    await seedThreeChanges();
    const headers = new Headers({
      Authorization: `Device ${MAC_TOKEN}`,
      "X-Sync-Bookmark": "should-be-ignored",
      "X-Protocol-Version": "99",
    });
    const request = new Request(`https://example.test${PATH}`, { headers });
    const response = await worker.fetch?.(
      request as unknown as WorkerRequest,
      env as never,
      {} as never,
    );
    expect(response?.status).toBe(200);
    expect(response?.headers.get("X-Sync-Bookmark")).toBeNull();
    expect(response?.headers.get("X-Protocol-Version")).toBeNull();
    const body = (await response?.json()) as ChangesBody;
    expect(body.result.changes.length).toBe(3);
  });
});

describe("GET /v1/sync/changes — cost", () => {
  it("does not query once per change", async () => {
    await seedRoom(ACCOUNT, ROOM, 300);
    const statements: D1PreparedStatement[] = [];
    for (let seq = 1; seq <= 300; seq += 1) {
      statements.push(
        db
          .prepare(
            `INSERT INTO change_log
               (account_id, server_seq, entity_type, change_kind, revision, space_id, room_id)
             VALUES (?, ?, 'room', 'upsert', ?, ?, ?)`,
          )
          .bind(ACCOUNT, seq, seq, MAC, ROOM),
      );
    }
    await db.batch(statements);
    await setSequence(ACCOUNT, 301);

    let prepared = 0;
    const counting = {
      prepare(sql: string) {
        prepared += 1;
        return db.prepare(sql);
      },
      batch: db.batch.bind(db),
    };
    const { handleChangesRequest } = await import("../src/routes/changes");
    const response = await handleChangesRequest(
      new Request(`https://example.test${PATH}?limit=300`, {
        headers: new Headers({ Authorization: `Device ${MAC_TOKEN}` }),
      }),
      { DB: counting as unknown as D1Database } as never,
    );
    expect(response.status).toBe(200);
    const body = (await response.json()) as ChangesBody;
    expect(body.result.changes.length).toBe(300);
    // Authentication, the batched watermark and page, then the fixed set of
    // projection reads. Nothing scales with the number of changes.
    expect(prepared).toBeLessThanOrEqual(25);
  });
});
