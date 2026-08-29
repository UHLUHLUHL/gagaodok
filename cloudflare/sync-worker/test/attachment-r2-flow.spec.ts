import { applyD1Migrations, env } from "cloudflare:test";
import { exports } from "cloudflare:workers";
import type { D1Migration } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { handleAttachmentComplete } from "../src/routes/attachments";
import type { Env } from "../src/env";

/**
 * The whole local R2 lifecycle over the real HTTP routes:
 * `create_attachment` → PUT content → POST complete → GET content.
 *
 * Every step goes through the Worker entrypoint, so this is the one place
 * where the operation ledger, the two storage bindings and the three
 * attachment routes are exercised against each other rather than in isolation.
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

const db = env.DB;
const bucket = env.ATTACHMENTS;
const worker = (exports as { default: ExportedHandler }).default;
type WorkerRequest = Parameters<NonNullable<ExportedHandler["fetch"]>>[0];

// Synthetic fixtures only.
const ACCOUNT = "A0000000-0000-4000-8000-00000000000A";
const OTHER_ACCOUNT = "A0000000-0000-4000-8000-00000000000B";
const MAC_DEVICE = "B0000000-0000-4000-8000-000000000001";
const PHONE_DEVICE = "B0000000-0000-4000-8000-000000000002";
const OTHER_ACCOUNT_DEVICE = "B0000000-0000-4000-8000-000000000004";
const ROOM = "10000000-0000-4000-8000-0000000000C1";
const TURN = "30000000-0000-4000-8000-0000000000C2";
const MESSAGE = "40000000-0000-4000-8000-0000000000C3";
const MESSAGE_2 = "40000000-0000-4000-8000-0000000000C4";
const ATTACHMENT = "70000000-0000-4000-8000-0000000000C5";
const OP_CREATE = "90000000-0000-4000-8000-0000000000D1";
const OP_BUBBLE_EARLY = "90000000-0000-4000-8000-0000000000D2";
const OP_BUBBLE_LATE = "90000000-0000-4000-8000-0000000000D3";
const TIMESTAMP = "2026-08-29T00:00:00Z";
const MAC = "MAC_SPACE";

const SOURCE_BYTES = 100;
const CIPHERTEXT_BYTES = SOURCE_BYTES + 34;

/** The one ciphertext this attachment will ever accept. */
const CIPHERTEXT = (() => {
  const bytes = new Uint8Array(CIPHERTEXT_BYTES);
  for (let index = 0; index < bytes.length; index += 1) bytes[index] = (index * 7 + 3) & 0xff;
  return bytes;
})();

function syntheticTokenBytes(seed: number): Uint8Array {
  const bytes = new Uint8Array(32);
  for (let index = 0; index < bytes.length; index += 1) bytes[index] = (seed + index) & 0xff;
  return bytes;
}
function base64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}
function base64Url(bytes: Uint8Array): string {
  return base64(bytes).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}
async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes as BufferSource);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
function envelope(seed: number): string {
  const bytes = new Uint8Array(34);
  bytes[0] = 1;
  bytes[1] = 1;
  for (let index = 2; index < bytes.length; index += 1) bytes[index] = (seed + index) & 0xff;
  return base64(bytes);
}

const MAC_TOKEN = `gdt1_${base64Url(syntheticTokenBytes(1))}`;
const PHONE_TOKEN = `gdt1_${base64Url(syntheticTokenBytes(33))}`;
const OTHER_ACCOUNT_TOKEN = `gdt1_${base64Url(syntheticTokenBytes(97))}`;

async function fetchWorker(request: Request): Promise<Response> {
  const response = await worker.fetch?.(request as unknown as WorkerRequest, env as never, {} as never);
  if (response === undefined) throw new Error("worker did not return a response");
  return response;
}

function authHeaders(token: string, extra: Record<string, string> = {}): Headers {
  return new Headers({ Authorization: `Device ${token}`, ...extra });
}

async function postOperation(payload: unknown, token = MAC_TOKEN): Promise<Response> {
  return await fetchWorker(
    new Request("https://example.test/v1/sync/operations", {
      method: "POST",
      headers: authHeaders(token),
      body: JSON.stringify(payload),
    }),
  );
}

async function putContent(body: Uint8Array, token = MAC_TOKEN): Promise<Response> {
  return await fetchWorker(
    new Request(`https://example.test/v1/attachments/${ATTACHMENT}/content`, {
      method: "PUT",
      headers: authHeaders(token, { "Content-Length": String(body.byteLength) }),
      body,
    }),
  );
}

async function postComplete(token = MAC_TOKEN): Promise<Response> {
  return await fetchWorker(
    new Request(`https://example.test/v1/attachments/${ATTACHMENT}/complete`, {
      method: "POST",
      headers: authHeaders(token),
    }),
  );
}

async function getContent(token = MAC_TOKEN): Promise<Response> {
  return await fetchWorker(
    new Request(`https://example.test/v1/attachments/${ATTACHMENT}/content`, {
      method: "GET",
      headers: authHeaders(token),
    }),
  );
}

async function createAttachmentBody(): Promise<Record<string, unknown>> {
  return {
    protocol_version: 1,
    operation_id: OP_CREATE,
    device_id: MAC_DEVICE,
    op: "create_attachment",
    entity_type: "attachment",
    target: { space_id: MAC, attachment_id: ATTACHMENT },
    metadata_set: {
      origin_space_id: MAC,
      kind: "attachment",
      source_byte_size: SOURCE_BYTES,
      ciphertext_byte_size: CIPHERTEXT_BYTES,
      ciphertext_hash: await sha256Hex(CIPHERTEXT),
      key_generation: 1,
      created_at: TIMESTAMP,
    },
    metadata_clear: [],
    set: { file_name: envelope(2), mime_type: envelope(3), wrapped_file_key: envelope(4) },
    clear: [],
    created_at: TIMESTAMP,
  };
}

function createBubbleBody(operationId: string, messageId: string, order: number): Record<string, unknown> {
  return {
    protocol_version: 1,
    operation_id: operationId,
    device_id: MAC_DEVICE,
    op: "create_bubble",
    entity_type: "bubble",
    target: { space_id: MAC, room_id: ROOM, worldline_id: null, turn_id: TURN, message_id: messageId },
    bubble_order: order,
    metadata_set: {
      timestamp: TIMESTAMP,
      attachment_ref_attachment_id: ATTACHMENT,
      attachment_ref_byte_size: CIPHERTEXT_BYTES,
    },
    metadata_clear: [],
    set: {},
    clear: [],
    created_at: TIMESTAMP,
  };
}

async function attachmentRow(): Promise<{ state: string; server_seq: number | null } | null> {
  return await db
    .prepare("SELECT state, server_seq FROM attachment WHERE account_id = ? AND attachment_id = ?")
    .bind(ACCOUNT, ATTACHMENT)
    .first();
}

async function nextServerSeq(): Promise<number> {
  const row = await db
    .prepare("SELECT next_server_seq AS n FROM account WHERE account_id = ?")
    .bind(ACCOUNT)
    .first<{ n: number }>();
  return row?.n ?? 0;
}

async function attachmentEvents(): Promise<Record<string, unknown>[]> {
  const result = await db
    .prepare("SELECT server_seq, revision, attachment_id FROM change_log WHERE entity_type = 'attachment'")
    .all<Record<string, unknown>>();
  return result.results;
}

async function objectKey(): Promise<string> {
  const row = await db
    .prepare("SELECT r2_object_key AS k FROM attachment WHERE account_id = ? AND attachment_id = ?")
    .bind(ACCOUNT, ATTACHMENT)
    .first<{ k: string }>();
  return row?.k ?? "";
}

/** No key, token, SQL, stack or whole ciphertext may reach a client. */
function expectContentFree(serialised: string, key: string): void {
  for (const leak of [key, "obj/", "gdt1_", MAC_TOKEN, "SELECT", "INSERT", "UPDATE", "stack", base64(CIPHERTEXT)]) {
    expect(serialised, `response leaked ${leak}`).not.toContain(leak);
  }
}

beforeAll(async () => {
  await applyD1Migrations(db, env.TEST_MIGRATIONS);
});

beforeEach(async () => {
  const listed = await bucket.list();
  if (listed.objects.length > 0) {
    await bucket.delete(listed.objects.map((object) => object.key));
  }
  for (const table of [
    "transaction_guard",
    "change_log",
    "operation_log",
    "bubble",
    "attachment",
    "turn",
    "room",
    "device",
    "account",
  ]) {
    await db.prepare(`DELETE FROM ${table}`).run();
  }
  for (const accountId of [ACCOUNT, OTHER_ACCOUNT]) {
    await db
      .prepare("INSERT INTO account (account_id, created_at) VALUES (?, ?)")
      .bind(accountId, TIMESTAMP)
      .run();
  }
  for (const [accountId, deviceId, space, platform, seed] of [
    [ACCOUNT, MAC_DEVICE, MAC, "macos", 1],
    [ACCOUNT, PHONE_DEVICE, "PHONE_SPACE", "android_phone", 33],
    [OTHER_ACCOUNT, OTHER_ACCOUNT_DEVICE, MAC, "macos", 97],
  ] as const) {
    await db
      .prepare(
        `INSERT INTO device
           (account_id, device_id, space_id, platform, display_name_enc,
            linked_at, revoked_at, key_generation, token_hash)
         VALUES (?, ?, ?, ?, NULL, ?, NULL, 1, ?)`,
      )
      .bind(accountId, deviceId, space, platform, TIMESTAMP, await sha256Hex(syntheticTokenBytes(seed)))
      .run();
  }
  await db
    .prepare(
      `INSERT INTO room
         (account_id, space_id, room_id, title_enc, status_message_enc, music_title_enc,
          music_artist_enc, revision, server_seq, created_at, updated_at)
       VALUES (?, ?, ?, NULL, NULL, NULL, NULL, 0, NULL, ?, ?)`,
    )
    .bind(ACCOUNT, MAC, ROOM, TIMESTAMP, TIMESTAMP)
    .run();
  await db
    .prepare(
      `INSERT INTO turn
         (account_id, space_id, room_id, worldline_id, worldline_key, turn_id,
          created_by_device_id, created_at, revision, server_seq, is_tombstoned)
       VALUES (?, ?, ?, NULL, '', ?, ?, ?, 0, NULL, 0)`,
    )
    .bind(ACCOUNT, MAC, ROOM, TURN, MAC_DEVICE, TIMESTAMP)
    .run();
});

describe("the local R2 attachment lifecycle", () => {
  it("carries one attachment from create through upload, complete and download", async () => {
    // 1. create_attachment — the only allocation path. It consumes a sequence
    //    and files the attachment's first change event.
    const created = await postOperation(await createAttachmentBody());
    expect(created.status).toBe(200);
    const createdBody = (await created.json()) as Record<string, unknown>;
    expect((createdBody["result"] as Record<string, unknown>)["revision"]).toBeNull();
    expect((await attachmentRow())?.state).toBe("allocated");
    const afterCreateSeq = await nextServerSeq();
    expect(afterCreateSeq).toBe(2);
    const key = await objectKey();
    // The server-generated key never travels to the client.
    expectContentFree(JSON.stringify(createdBody), key);

    // 2. PUT — a transfer-internal transition: no sequence, no change event.
    const uploaded = await putContent(CIPHERTEXT);
    expect(uploaded.status).toBe(204);
    expect((await attachmentRow())?.state).toBe("uploaded");
    expect(await nextServerSeq()).toBe(afterCreateSeq);
    expect((await attachmentEvents()).length).toBe(1);

    // 3. A bubble may not reference it yet: uploaded is not readable.
    const early = await postOperation(createBubbleBody(OP_BUBBLE_EARLY, MESSAGE, 0));
    expect(early.status).toBe(409);
    const earlyText = await early.text();
    expect(JSON.parse(earlyText)["error"]).toMatchObject({
      code: "ATTACHMENT_STATE_CONFLICT",
    });

    // 4. complete — the transition other devices are waiting for.
    const completed = await postComplete();
    expect(completed.status).toBe(204);
    const readyRow = await attachmentRow();
    expect(readyRow?.state).toBe("ready");
    expect(readyRow?.server_seq).toBe(afterCreateSeq);
    expect(await nextServerSeq()).toBe(afterCreateSeq + 1);
    const events = await attachmentEvents();
    expect(events.length).toBe(2);
    expect(events[1]).toEqual({
      server_seq: afterCreateSeq,
      revision: null,
      attachment_id: ATTACHMENT,
    });

    // 5. The bytes come back exactly as they went in.
    const downloaded = await getContent();
    expect(downloaded.status).toBe(200);
    expect(downloaded.headers.get("Content-Type")).toBe("application/octet-stream");
    expect(downloaded.headers.get("Content-Length")).toBe(String(CIPHERTEXT_BYTES));
    expect(downloaded.headers.get("Cache-Control")).toBe("private, no-store");
    expect([...new Uint8Array(await downloaded.arrayBuffer())]).toEqual([...CIPHERTEXT]);

    // 6. Download is account-scoped: the phone never uploaded anything here.
    const fromPhone = await getContent(PHONE_TOKEN);
    expect(fromPhone.status).toBe(200);
    expect([...new Uint8Array(await fromPhone.arrayBuffer())]).toEqual([...CIPHERTEXT]);

    // 7. Another account sees nothing at all.
    const foreign = await getContent(OTHER_ACCOUNT_TOKEN);
    expect(foreign.status).toBe(404);

    // 8. Completing again changes nothing.
    const again = await postComplete();
    expect(again.status).toBe(204);
    expect(await nextServerSeq()).toBe(afterCreateSeq + 1);
    expect((await attachmentEvents()).length).toBe(2);

    // 9. A PUT after ready is refused; the stored object is untouched.
    const late = await putContent(CIPHERTEXT);
    expect(late.status).toBe(409);
    const lateText = await late.text();
    const stored = await bucket.get(key);
    expect([...new Uint8Array(await stored!.arrayBuffer())]).toEqual([...CIPHERTEXT]);

    // 10. Now the bubble reference is accepted.
    const accepted = await postOperation(createBubbleBody(OP_BUBBLE_LATE, MESSAGE_2, 0));
    expect(accepted.status).toBe(200);
    const bubble = await db
      .prepare(
        `SELECT attachment_ref_attachment_id AS a, attachment_ref_byte_size AS s
           FROM bubble WHERE account_id = ? AND message_id = ?`,
      )
      .bind(ACCOUNT, MESSAGE_2)
      .first<{ a: string; s: number }>();
    expect(bubble).toEqual({ a: ATTACHMENT, s: CIPHERTEXT_BYTES });

    // Nothing along the way described the object key or the ciphertext.
    expectContentFree(earlyText + lateText, key);
  });

  it("keeps the object and converges on a retry when complete fails after the upload", async () => {
    await postOperation(await createAttachmentBody());
    expect((await putContent(CIPHERTEXT)).status).toBe(204);
    const key = await objectKey();
    const seqBefore = await nextServerSeq();

    // A D1 batch failure after R2 already holds the object. Only the binding
    // handed to the route is synthetic; production is untouched.
    const brokenDb = {
      prepare: db.prepare.bind(db),
      batch(): never {
        throw new Error("D1 exploded during INSERT INTO transaction_guard");
      },
    };
    const failed = await handleAttachmentComplete(
      new Request(`https://example.test/v1/attachments/${ATTACHMENT}/complete`, {
        method: "POST",
        headers: authHeaders(MAC_TOKEN),
      }),
      { DB: brokenDb as unknown as D1Database, ATTACHMENTS: bucket, CURSOR_MAC_KEY: "x" } as Env,
      ATTACHMENT,
    );
    expect(failed.status).toBe(503);
    expectContentFree(JSON.stringify(await failed.json()), key);

    // The object is deliberately left in place — Phase 1 reports orphans
    // rather than deleting them — and nothing in D1 moved.
    expect(await bucket.head(key)).not.toBeNull();
    expect((await attachmentRow())?.state).toBe("uploaded");
    expect(await nextServerSeq()).toBe(seqBefore);

    // The same request against real storage converges.
    expect((await postComplete()).status).toBe(204);
    expect((await attachmentRow())?.state).toBe("ready");
    expect(await nextServerSeq()).toBe(seqBefore + 1);
    const downloaded = await getContent();
    expect([...new Uint8Array(await downloaded.arrayBuffer())]).toEqual([...CIPHERTEXT]);
  });

  it("leaves no synthetic object behind once a run finishes", async () => {
    await postOperation(await createAttachmentBody());
    await putContent(CIPHERTEXT);
    const listed = await bucket.list();
    // One object per attachment, and only for this local run's fixtures.
    expect(listed.objects.map((object) => object.key)).toEqual([await objectKey()]);
  });
});
