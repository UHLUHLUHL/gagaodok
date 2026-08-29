import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import {
  ATTACHMENT,
  CIPHERTEXT_BYTES,
  DEVICE_MAC,
  DEVICE_PHONE,
  MAC,
  MESSAGE,
  PHONE,
  ROOM_SHARED,
  TOKEN_MAC,
  TOKEN_PHONE,
  TURN,
  applyMigrations,
  attachmentRow,
  ciphertext,
  completeAttachment,
  createAttachment,
  createBubble,
  createRoom,
  createTurn,
  downloadAttachment,
  drainBootstrap,
  envelope,
  expectNoLeak,
  getChanges,
  nextServerSeq,
  objectBytes,
  operationId,
  postOperation,
  putAttachmentContent,
  resetSyntheticAccount,
} from "./helpers/syntheticSync";

/**
 * Phase 2 — the local synthetic happy path, end to end.
 *
 * Every step goes through the Worker's own routes: the operation endpoint, the
 * three attachment content routes, the account cursor and the bootstrap
 * cursor. Nothing is seeded behind a handler except the account and its
 * devices, so what this file proves is that the pieces agree with each other,
 * not that each one works alone.
 *
 * The identifiers are the ones the Python contract fixture reserves; the
 * envelopes and the "ciphertext" are fixed byte sentinels with no key behind
 * them. The Worker never decrypts them and is not assumed to.
 */

beforeAll(async () => {
  await applyMigrations();
});

beforeEach(async () => {
  await resetSyntheticAccount();
});

describe("the local synthetic sync lifecycle", () => {
  it("carries one account from first write through R2 to both read paths", async () => {
    // 1. The Mac creates the room it owns. Every canonical row below is made
    //    the same way — through the operation route, never seeded behind it.
    const room = await postOperation(createRoom(operationId(1), MAC, ROOM_SHARED, DEVICE_MAC));
    expect(room.status).toBe(200);
    expect(await nextServerSeq()).toBe(2);

    // 2. The phone allocates an attachment in its own space. The write
    //    boundary is per space, so this is the phone's to make and not the
    //    Mac's.
    const allocated = await postOperation(await createAttachment(operationId(2)), TOKEN_PHONE);
    expect(allocated.status).toBe(200);
    expect((await allocated.json()) as Record<string, unknown>).toMatchObject({
      result: { status: "applied", revision: null },
    });
    expect((await attachmentRow())?.state).toBe("allocated");
    const objectKey = (await attachmentRow())?.r2_object_key as string;
    const seqAfterAllocation = await nextServerSeq();

    // 3. The bytes are streamed to R2. A transfer-internal transition: no
    //    sequence, no change event.
    const bytes = ciphertext();
    expect((await putAttachmentContent(ATTACHMENT, bytes)).status).toBe(204);
    expect((await attachmentRow())?.state).toBe("uploaded");
    expect(await nextServerSeq()).toBe(seqAfterAllocation);

    // 4. complete is the transition other devices are waiting for, and the
    //    only one of the two that costs a sequence.
    expect((await completeAttachment(ATTACHMENT)).status).toBe(204);
    expect((await attachmentRow())?.state).toBe("ready");
    expect(await nextServerSeq()).toBe(seqAfterAllocation + 1);

    // 5. The Mac writes the turn and the bubble that references the phone's
    //    attachment. The reference crosses spaces because attachment identity
    //    is account-scoped.
    expect((await postOperation(createTurn(operationId(3)))).status).toBe(200);
    const bubble = await postOperation(createBubble(operationId(4)));
    expect(bubble.status).toBe(200);

    // 6. Another active device of the same account reads the whole ledger.
    //    The phone may not write MAC_SPACE rows, but it must learn about them.
    const changes = await getChanges("?limit=500", TOKEN_PHONE);
    expect(changes.status).toBe(200);
    expect(changes.result.has_more).toBe(false);
    expect(changes.result.scanned_through_seq).toBe(
      changes.result.account_high_watermark_seq,
    );
    expect(changes.result.changes.map((change) => change.entity_type)).toEqual([
      "room",
      "attachment",
      "attachment",
      "turn",
      "bubble",
    ]);

    // 7. The whole account, drained one page at a time.
    const bootstrap = await drainBootstrap(2, TOKEN_PHONE);
    expect(bootstrap.pages).toBeGreaterThan(1);
    expect(bootstrap.items.map((item) => item.entity_type)).toEqual([
      "room",
      "turn",
      "bubble",
      "attachment",
    ]);

    // 8. Both read paths converge on the same current state, field for field.
    //    They share one registry, so this is the assertion that keeps them
    //    from drifting apart.
    for (const item of bootstrap.items) {
      const matching = changes.result.changes.filter(
        (change) =>
          change.entity_type === item.entity_type &&
          JSON.stringify(change.identity) === JSON.stringify(item.identity),
      );
      expect(matching.length, `no change for ${item.entity_type}`).toBeGreaterThan(0);
      const last = matching[matching.length - 1];
      expect(JSON.stringify(last?.projection)).toBe(JSON.stringify(item.projection));
    }

    // 9. The attachment is readable, and it is byte-for-byte what was sent.
    const download = await downloadAttachment(ATTACHMENT, TOKEN_MAC);
    expect(download.status).toBe(200);
    expect(download.headers.get("Content-Type")).toBe("application/octet-stream");
    expect(download.headers.get("Content-Length")).toBe(String(CIPHERTEXT_BYTES));
    expect(download.headers.get("Cache-Control")).toBe("private, no-store");
    expect([...new Uint8Array(await download.arrayBuffer())]).toEqual([...bytes]);
    expect(await objectBytes(objectKey)).toEqual([...bytes]);

    // 10. Nothing along the way described the server-generated object key.
    expectNoLeak(changes.text, objectKey);
    expectNoLeak(JSON.stringify(bootstrap.items), objectKey);
    expect(JSON.stringify([...download.headers])).not.toContain(objectKey);
  });

  it("puts the phone's attachment and the Mac's bubble in one converged view", async () => {
    await postOperation(createRoom(operationId(1), MAC, ROOM_SHARED, DEVICE_MAC));
    await postOperation(await createAttachment(operationId(2)), TOKEN_PHONE);
    await putAttachmentContent(ATTACHMENT, ciphertext());
    await completeAttachment(ATTACHMENT);
    await postOperation(createTurn(operationId(3)));
    await postOperation(createBubble(operationId(4)));

    const { items } = await drainBootstrap(500);
    const bubble = items.find((item) => item.entity_type === "bubble");
    const attachment = items.find((item) => item.entity_type === "attachment");

    // The bubble names the attachment and its ciphertext size; the attachment
    // itself is ready and carries its hash and wrapped key, but never its key
    // in R2.
    expect(bubble?.identity).toEqual({
      space_id: MAC,
      room_id: ROOM_SHARED,
      worldline_id: null,
      turn_id: TURN,
      message_id: MESSAGE,
    });
    expect(bubble?.projection["attachment_ref_attachment_id"]).toBe(ATTACHMENT);
    expect(bubble?.projection["attachment_ref_byte_size"]).toBe(CIPHERTEXT_BYTES);
    expect(bubble?.projection["text"]).toBe(envelope(7));
    expect(attachment?.identity).toEqual({ attachment_id: ATTACHMENT });
    expect(attachment?.projection["state"]).toBe("ready");
    expect(attachment?.projection["origin_space_id"]).toBe(PHONE);
    expect(Object.keys(attachment?.projection ?? {})).not.toContain("r2_object_key");
  });

  it("refuses the bubble reference until the attachment is ready", async () => {
    await postOperation(createRoom(operationId(1), MAC, ROOM_SHARED, DEVICE_MAC));
    await postOperation(await createAttachment(operationId(2)), TOKEN_PHONE);
    await postOperation(createTurn(operationId(3)));

    // allocated: the bytes are not even uploaded.
    const early = await postOperation(createBubble(operationId(4)));
    expect(early.status).toBe(409);

    await putAttachmentContent(ATTACHMENT, ciphertext());
    // uploaded: the bytes are there but nothing has confirmed them.
    const midway = await postOperation(createBubble(operationId(5)));
    expect(midway.status).toBe(409);

    await completeAttachment(ATTACHMENT);
    const accepted = await postOperation(createBubble(operationId(6)));
    expect(accepted.status).toBe(200);
  });

  it("keeps the cursor and the snapshot consistent as the account grows", async () => {
    await postOperation(createRoom(operationId(1), MAC, ROOM_SHARED, DEVICE_MAC));
    await postOperation(createTurn(operationId(2)));

    const first = await getChanges("?limit=500");
    const cursor = first.result.scanned_through_seq;
    expect(first.result.has_more).toBe(false);

    // More writes land, from the other device this time.
    await postOperation(await createAttachment(operationId(3)), TOKEN_PHONE);
    await putAttachmentContent(ATTACHMENT, ciphertext());
    await completeAttachment(ATTACHMENT);

    const second = await getChanges(`?after_seq=${cursor}&limit=500`);
    // Only the new events, and only once.
    expect(second.result.changes.map((change) => change.entity_type)).toEqual([
      "attachment",
      "attachment",
    ]);
    expect(second.result.changes.every((change) => change.change_seq > cursor)).toBe(true);

    // A bootstrap taken now agrees with everything the cursor has reported.
    const { items, watermark } = await drainBootstrap(500);
    expect(watermark).toBe(second.result.account_high_watermark_seq);
    expect(items.map((item) => item.entity_type)).toEqual(["room", "turn", "attachment"]);
  });
});
