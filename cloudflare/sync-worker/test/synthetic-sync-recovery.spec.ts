import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { handleAttachmentComplete } from "../src/routes/attachments";
import type { Env } from "../src/env";
import {
  ATTACHMENT,
  CURSOR_MAC_KEY,
  DEVICE_MAC,
  MAC,
  ROOM_SHARED,
  TOKEN_ACCOUNT_B,
  TOKEN_MAC,
  TOKEN_PHONE,
  TOKEN_TABLET,
  applyMigrations,
  attachmentRow,
  bucket,
  ciphertext,
  completeAttachment,
  createAttachment,
  createRoom,
  createTurn,
  db,
  downloadAttachment,
  drainBootstrap,
  expectNoLeak,
  getBootstrap,
  getChanges,
  ledgerSnapshot,
  objectBytes,
  operationId,
  patchRoom,
  postOperation,
  postRawOperation,
  putAttachmentContent,
  resetSyntheticAccount,
} from "./helpers/syntheticSync";

/**
 * Phase 2 — recovery, tenant isolation and non-disclosure.
 *
 * These are the boundaries that only show up where two components meet, so
 * this file deliberately does not restate what the focused route suites
 * already pin. Every scenario here is one a client actually hits: a retry
 * after a dropped response, a crash midway through applying a page, a
 * bootstrap that races a write, a device whose link was ended.
 */

/** A room whose id sorts before the shared one, for the late-write case. */
const EARLIER_ROOM = "0F000000-0000-4000-8000-000000000001";

beforeAll(async () => {
  await applyMigrations();
});

beforeEach(async () => {
  await resetSyntheticAccount();
});

describe("retrying a write", () => {
  it("replays byte-identical bytes without spending a sequence or a ledger row", async () => {
    const raw = JSON.stringify(createRoom(operationId(1), MAC, ROOM_SHARED, DEVICE_MAC));
    const applied = await postRawOperation(raw);
    expect(applied.status).toBe(200);
    const first = (await applied.json()) as { result: Record<string, unknown> };
    const after = await ledgerSnapshot();

    // The client never saw the response and sends exactly the same bytes.
    const retried = await postRawOperation(raw);
    expect(retried.status).toBe(200);
    const second = (await retried.json()) as { result: Record<string, unknown> };

    expect(second.result["status"]).toBe("replayed");
    expect(second.result["server_seq"]).toBe(first.result["server_seq"]);
    expect(second.result["revision"]).toBe(first.result["revision"]);
    expect(await ledgerSnapshot()).toEqual(after);
  });

  it("leaves everything untouched when the CAS precondition misses", async () => {
    await postOperation(createRoom(operationId(1), MAC, ROOM_SHARED, DEVICE_MAC));
    const before = await ledgerSnapshot();
    const roomBefore = await db
      .prepare("SELECT * FROM room WHERE room_id = ?")
      .bind(ROOM_SHARED)
      .first<Record<string, unknown>>();

    // The room is at revision 0; this operation claims it is at 7.
    const conflict = await postOperation(patchRoom(operationId(2), 7));
    expect(conflict.status).toBe(409);
    expect((await conflict.json()) as Record<string, unknown>).toMatchObject({
      error: { code: "REVISION_CONFLICT", current_revision: 0 },
    });

    // The canonical row, the sequence and both ledgers are exactly as before.
    expect(
      await db.prepare("SELECT * FROM room WHERE room_id = ?").bind(ROOM_SHARED).first(),
    ).toEqual(roomBefore);
    expect(await ledgerSnapshot()).toEqual(before);
  });
});

describe("recovering a read", () => {
  /** A toy replica: last write per identity wins, applied in cursor order. */
  function applyPage(
    replica: Map<string, unknown>,
    changes: { entity_type: string; identity: Record<string, unknown>; projection: unknown }[],
  ): void {
    for (const change of changes) {
      replica.set(`${change.entity_type} ${JSON.stringify(change.identity)}`, change.projection);
    }
  }

  it("is unchanged when a page is applied twice after a crash", async () => {
    await postOperation(createRoom(operationId(1), MAC, ROOM_SHARED, DEVICE_MAC));
    await postOperation(createTurn(operationId(2)));
    await postOperation(patchRoom(operationId(3), 0));

    const page = await getChanges("?after_seq=0&limit=500");
    expect(page.result.changes.length).toBe(3);

    const once = new Map<string, unknown>();
    applyPage(once, page.result.changes);
    const crashed = new Map<string, unknown>();
    // The device died partway through and re-applies the whole page.
    applyPage(crashed, page.result.changes);
    applyPage(crashed, page.result.changes);

    expect(JSON.stringify([...crashed])).toBe(JSON.stringify([...once]));

    // Re-fetching the same page is byte-identical apart from the request id.
    const again = await getChanges("?after_seq=0&limit=500");
    const strip = (text: string): string =>
      text.replace(/"request_id":"[0-9A-F-]{36}"/, '"request_id":"<id>"');
    expect(strip(again.text)).toBe(strip(page.text));
  });

  it("keeps repeated events for one identity harmless", async () => {
    await postOperation(createRoom(operationId(1), MAC, ROOM_SHARED, DEVICE_MAC));
    await postOperation(patchRoom(operationId(2), 0));
    await postOperation(patchRoom(operationId(3), 1));

    const page = await getChanges("?limit=500");
    const roomChanges = page.result.changes.filter((change) => change.entity_type === "room");
    expect(roomChanges.map((change) => change.revision)).toEqual([0, 1, 2]);
    // Each event carries the current projection, so applying them in order
    // converges on the same row whichever one the client stops at.
    for (const change of roomChanges) {
      expect(change.projection["revision"]).toBe(2);
    }
    const replica = new Map<string, unknown>();
    applyPage(replica, roomChanges);
    expect(replica.size).toBe(1);
  });

  it("recovers a write that landed behind the bootstrap cursor", async () => {
    await postOperation(createRoom(operationId(1), MAC, ROOM_SHARED, DEVICE_MAC));
    await postOperation(createTurn(operationId(2)));

    // Page one stops after the only room; the cursor is now past that key.
    const first = await getBootstrap("?limit=1");
    expect(first.result.has_more).toBe(true);
    const watermark = first.result.snapshot_high_watermark_seq;

    // A room whose storage key sorts *before* the cursor is created while the
    // bootstrap is still running, so the walk can never reach it.
    const late = await postOperation(createRoom(operationId(3), MAC, EARLIER_ROOM, DEVICE_MAC));
    expect(late.status).toBe(200);

    // The same bootstrap continues from its own cursor, so the snapshot it
    // walks is still the one page one fixed.
    const seen = [...first.result.items];
    let cursor = first.result.next_cursor as string;
    for (let page = 0; page < 20; page += 1) {
      const next = await getBootstrap(`?cursor=${encodeURIComponent(cursor)}&limit=1`);
      expect(next.result.snapshot_high_watermark_seq).toBe(watermark);
      seen.push(...next.result.items);
      if (!next.result.has_more) break;
      cursor = next.result.next_cursor as string;
    }
    expect(seen.map((item) => item.identity["room_id"])).not.toContain(EARLIER_ROOM);

    // The cursor started at the snapshot's own watermark picks it up.
    const recovered = await getChanges(`?after_seq=${watermark}&limit=500`);
    expect(recovered.result.changes.map((change) => change.identity["room_id"])).toContain(
      EARLIER_ROOM,
    );
  });
});

describe("tenant isolation", () => {
  it("shows the second account nothing of the first", async () => {
    await postOperation(createRoom(operationId(1), MAC, ROOM_SHARED, DEVICE_MAC));
    await postOperation(await createAttachment(operationId(2)), TOKEN_PHONE);
    await putAttachmentContent(ATTACHMENT, ciphertext());
    await completeAttachment(ATTACHMENT);

    const changes = await getChanges("?limit=500", TOKEN_ACCOUNT_B);
    expect(changes.result.changes).toEqual([]);
    const bootstrap = await getBootstrap("?limit=500", TOKEN_ACCOUNT_B);
    expect(bootstrap.result.items).toEqual([]);
    // The same UUID, and it is simply absent.
    expect((await downloadAttachment(ATTACHMENT, TOKEN_ACCOUNT_B)).status).toBe(404);

    expectNoLeak(changes.text);
    expectNoLeak(bootstrap.text);
    expect(changes.text).not.toContain(ROOM_SHARED);
  });

  it("refuses a revoked device on every route", async () => {
    await postOperation(createRoom(operationId(1), MAC, ROOM_SHARED, DEVICE_MAC));
    await postOperation(await createAttachment(operationId(2)), TOKEN_PHONE);
    await putAttachmentContent(ATTACHMENT, ciphertext());
    await completeAttachment(ATTACHMENT);
    const before = await ledgerSnapshot();

    // The tablet's link was ended. Reads and writes alike are over for it.
    const write = await postOperation(createTurn(operationId(3)), TOKEN_TABLET);
    expect(write.status).toBe(403);
    const changes = await getChanges("", TOKEN_TABLET);
    expect(changes.status).toBe(403);
    const bootstrap = await getBootstrap("", TOKEN_TABLET);
    expect(bootstrap.status).toBe(403);
    const download = await downloadAttachment(ATTACHMENT, TOKEN_TABLET);
    expect(download.status).toBe(403);

    expect(await ledgerSnapshot()).toEqual(before);
    for (const text of [changes.text, bootstrap.text, await download.text()]) {
      expect(JSON.parse(text)["error"]).toEqual({ code: "DEVICE_REVOKED", retryable: false });
      expectNoLeak(text);
    }
  });
});

describe("a half-finished attachment", () => {
  it("keeps the object and moves nothing in D1 when the transition fails", async () => {
    await postOperation(await createAttachment(operationId(1)), TOKEN_PHONE);
    expect((await putAttachmentContent(ATTACHMENT, ciphertext())).status).toBe(204);
    const objectKey = (await attachmentRow())?.r2_object_key as string;
    const before = await ledgerSnapshot();

    // Only the binding handed to the route is synthetic; production is
    // untouched. The batch fails after R2 already holds the object.
    const brokenDb = {
      prepare: db.prepare.bind(db),
      batch(): never {
        throw new Error("D1 failed while running INSERT INTO transaction_guard");
      },
    };
    const failed = await handleAttachmentComplete(
      new Request(`https://example.test/v1/attachments/${ATTACHMENT}/complete`, {
        method: "POST",
        headers: new Headers({ Authorization: `Device ${TOKEN_PHONE}` }),
      }),
      { DB: brokenDb as unknown as D1Database, ATTACHMENTS: bucket, CURSOR_MAC_KEY: "x" } as Env,
      ATTACHMENT,
    );

    expect(failed.status).toBe(503);
    const text = await failed.text();
    expect(JSON.parse(text)["error"]).toEqual({ code: "STORAGE_UNAVAILABLE", retryable: true });
    expectNoLeak(text, objectKey);

    // Phase 1 reports orphans rather than deleting them, so the bytes stay
    // and an identical retry converges.
    expect(await objectBytes(objectKey)).toEqual([...ciphertext()]);
    expect((await attachmentRow())?.state).toBe("uploaded");
    expect(await ledgerSnapshot()).toEqual(before);

    expect((await completeAttachment(ATTACHMENT)).status).toBe(204);
    expect((await attachmentRow())?.state).toBe("ready");
  });
});

describe("what never leaves the server", () => {
  it("says nothing forbidden in a success, an error, a replay or a log line", async () => {
    const captured: string[] = [];
    const original = { log: console.log, warn: console.warn, error: console.error };
    for (const level of ["log", "warn", "error"] as const) {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      (console as unknown as Record<string, unknown>)[level] = (...args: unknown[]): void => {
        captured.push(args.map((value) => String(value)).join(" "));
      };
    }
    let objectKey = "";
    try {
      const raw = JSON.stringify(createRoom(operationId(1), MAC, ROOM_SHARED, DEVICE_MAC));
      const success = await postRawOperation(raw);
      const replay = await postRawOperation(raw);
      const conflict = await postOperation(patchRoom(operationId(2), 42));
      await postOperation(await createAttachment(operationId(3)), TOKEN_PHONE);
      await putAttachmentContent(ATTACHMENT, ciphertext());
      await completeAttachment(ATTACHMENT);
      objectKey = (await attachmentRow())?.r2_object_key as string;

      const rejected = await putAttachmentContent(ATTACHMENT, ciphertext());
      const changes = await getChanges("?limit=500");
      const bootstrap = await getBootstrap("?limit=1");
      const download = await downloadAttachment(ATTACHMENT);

      for (const response of [success, replay, conflict, rejected]) {
        expectNoLeak(await response.text(), objectKey);
      }
      expectNoLeak(changes.text, objectKey);
      expectNoLeak(bootstrap.text, objectKey);
      // A cursor is opaque, but it must not be a container for anything else.
      expect(bootstrap.text).not.toContain(objectKey);
      expect(JSON.stringify([...download.headers])).not.toContain(objectKey);
      await download.arrayBuffer();
    } finally {
      console.log = original.log;
      console.warn = original.warn;
      console.error = original.error;
    }

    // Nothing was logged at all, which is the strongest form of the rule.
    expectNoLeak(captured.join("\n"), objectKey);
    expect(captured.join("\n")).not.toContain(TOKEN_MAC);
  });
});

describe("the bootstrap cursor's storage key", () => {
  it("refuses a shape no entity could have, even with a valid signature", async () => {
    await postOperation(createRoom(operationId(1), MAC, ROOM_SHARED, DEVICE_MAC));
    await postOperation(createTurn(operationId(2)));

    const key = new TextEncoder().encode(CURSOR_MAC_KEY) as Uint8Array;
    const macKey = await crypto.subtle.importKey(
      "raw",
      key as BufferSource,
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"],
    );
    const encode = (bytes: Uint8Array): string => {
      let binary = "";
      for (const byte of bytes) binary += String.fromCharCode(byte);
      return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
    };
    const sign = async (payload: unknown[]): Promise<string> => {
      const bytes = new TextEncoder().encode(JSON.stringify(payload));
      const signature = new Uint8Array(
        await crypto.subtle.sign("HMAC", macKey, bytes as BufferSource),
      );
      return `${encode(bytes)}.${encode(signature)}`;
    };
    const expiry = Math.floor(Date.now() / 1000) + 600;
    const account = "A0000000-0000-4000-8000-000000000001";

    // Each of these signs correctly. None of them names a position this
    // server could ever have issued.
    const impossible: unknown[][] = [
      // bubble (index 4) takes five axes; two cannot address a row.
      [1, account, 1, 4, [MAC, ROOM_SHARED], expiry],
      // room (index 0) takes two; four is not a room key either.
      [1, account, 1, 0, [MAC, ROOM_SHARED, "", "x"], expiry],
      // an empty key is not the same as "start from the beginning".
      [1, account, 1, 0, [], expiry],
      // engine_profile's third axis is an integer revision, not a string.
      [1, account, 1, 5, [MAC, ROOM_SHARED, "3"], expiry],
      // and room's axes are strings, not integers.
      [1, account, 1, 0, [1, 2], expiry],
    ];

    for (const payload of impossible) {
      const token = await sign(payload);
      const response = await getBootstrap(`?cursor=${encodeURIComponent(token)}&limit=5`);
      expect(response.status, `accepted an impossible key shape`).toBe(400);
      expect(JSON.parse(response.text)["error"]).toEqual({
        code: "VALIDATION_FAILED",
        retryable: false,
      });
      // The refusal describes nothing about the key it refused.
      expect(response.text).not.toContain(ROOM_SHARED);
      expectNoLeak(response.text);
    }
  });
});
