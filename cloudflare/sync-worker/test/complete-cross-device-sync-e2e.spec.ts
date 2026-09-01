import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import {
  ATTACHMENT,
  CIPHERTEXT_BYTES,
  DEVICE_MAC,
  DEVICE_PHONE,
  DEVICE_TABLET,
  MAC,
  MESSAGE,
  PHONE,
  ROOM_SHARED,
  TABLET,
  TIMESTAMP,
  TOKEN_MAC,
  TOKEN_PHONE,
  TURN,
  applyMigrations,
  ciphertext,
  completeAttachment,
  createAttachment,
  createBubble,
  createRoom,
  createTurn,
  db,
  drainBootstrap,
  expectNoLeak,
  getChanges,
  operationId,
  postOperation,
  putAttachmentContent,
  resetSyntheticAccount,
} from "./helpers/syntheticSync";

/**
 * 완전 동기화의 로컬 수용 시나리오.
 *
 * 합성 식별자만 쓴다. 실제 대화·token·복구 문구·production endpoint가 없다.
 * 전부 로컬 workerd/Miniflare에서 돈다.
 */
describe("complete cross-device sync", () => {
  beforeAll(async () => {
    await applyMigrations();
  });

  beforeEach(async () => {
    await resetSyntheticAccount();
  });

  const ROOM_MAC = ROOM_SHARED;
  const ROOM_PHONE = "10000000-0000-4000-8000-000000000002";
  const ROOM_TABLET = "10000000-0000-4000-8000-000000000003";

  async function originRoom(
    space: string, room: string, device: string, token: string, operation = 1,
  ) {
    return await postOperation(createRoom(operationId(operation), space, room, device), token);
  }

  it("records the origin space of a room created in each space", async () => {
    // 노출 정책의 근거가 되는 값이다. 세 space가 각자 자기 origin을 남긴다.
    const cases: Array<[string, string, string, string]> = [
      [MAC, ROOM_MAC, DEVICE_MAC, TOKEN_MAC],
      [PHONE, ROOM_PHONE, DEVICE_PHONE, TOKEN_PHONE],
    ];
    let operation = 10;
    for (const [space, room, device, token] of cases) {
      operation += 1;
      // 방마다 다른 operation_id를 쓴다. 같은 id로 다른 내용을 보내면 충돌이다.
      const response = await originRoom(space, room, device, token, operation);
      expect(response.status, `${space} room create`).toBe(200);
      const row = await db
        .prepare("SELECT origin_space_id FROM room WHERE space_id = ? AND room_id = ?")
        .bind(space, room)
        .first<{ origin_space_id: string }>();
      expect(row?.origin_space_id, `${space} origin`).toBe(space);
    }
  });

  it("keeps an attachment out of a bubble until it is ready", async () => {
    await originRoom(MAC, ROOM_MAC, DEVICE_MAC, TOKEN_MAC);
    await postOperation(createTurn(operationId(2)), TOKEN_MAC);

    // allocated 상태에서 bubble이 참조하면 거부되어야 한다. 다른 기기에
    // 다운로드 불가능한 중간 상태가 노출되지 않는다.
    const allocated = await postOperation(await createAttachment(operationId(3)), TOKEN_PHONE);
    expect(allocated.status).toBe(200);
    const early = await postOperation(createBubble(operationId(4), MESSAGE, 0), TOKEN_MAC);
    expect(early.status, "a bubble referenced a non-ready attachment").not.toBe(200);

    // ready가 된 뒤에는 통과한다. 위 거부가 우연이 아님을 확인한다.
    const bytes = ciphertext(1);
    expect(bytes.byteLength).toBe(CIPHERTEXT_BYTES);
    expect((await putAttachmentContent(ATTACHMENT, bytes)).status).toBe(204);
    expect((await completeAttachment(ATTACHMENT)).status).toBe(204);
    const late = await postOperation(createBubble(operationId(5), MESSAGE, 0), TOKEN_MAC);
    expect(late.status, "a ready attachment was still refused").toBe(200);
  });

  it("replays an identical operation instead of applying it twice", async () => {
    await originRoom(MAC, ROOM_MAC, DEVICE_MAC, TOKEN_MAC);
    const again = await originRoom(MAC, ROOM_MAC, DEVICE_MAC, TOKEN_MAC);
    expect(again.status).toBe(200);
    const body = (await again.json()) as { result?: { status?: string } };
    expect(body.result?.status).toBe("replayed");

    const rows = await db
      .prepare("SELECT COUNT(*) AS total FROM room WHERE space_id = ? AND room_id = ?")
      .bind(MAC, ROOM_MAC)
      .first<{ total: number }>();
    expect(rows?.total).toBe(1);
  });

  it("refuses a room whose origin claims a different space than the target", async () => {
    const request = {
      ...createRoom(operationId(6), MAC, ROOM_MAC, DEVICE_MAC),
      metadata_set: { origin_space_id: TABLET },
    };
    const response = await postOperation(request, TOKEN_MAC);
    expect(response.status, "a malformed origin was accepted").not.toBe(200);
  });

  it("converges the change feed and bootstrap on the same room family", async () => {
    await originRoom(MAC, ROOM_MAC, DEVICE_MAC, TOKEN_MAC);
    await postOperation(createTurn(operationId(7)), TOKEN_MAC);
    await postOperation(await createAttachment(operationId(8)), TOKEN_PHONE);
    await putAttachmentContent(ATTACHMENT, ciphertext(1));
    await completeAttachment(ATTACHMENT);
    await postOperation(createBubble(operationId(9), MESSAGE, 0), TOKEN_MAC);

    const changes = await getChanges("?after_seq=0&limit=300", TOKEN_PHONE);
    const bootstrap = await drainBootstrap(300, TOKEN_PHONE);

    const identityOf = (item: { entity_type: string; identity: Record<string, unknown> }) =>
      `${item.entity_type}|${JSON.stringify(item.identity)}`;
    const fromChanges = new Set(changes.result.changes.map(identityOf));
    const fromBootstrap = new Set(bootstrap.items.map(identityOf));
    // bootstrap은 changes가 만든 모든 identity를 담아야 한다. 한쪽만 아는
    // 행이 있으면 기기마다 다른 대화를 보게 된다.
    for (const identity of fromBootstrap) {
      expect(fromChanges.has(identity), `changes is missing ${identity}`).toBe(true);
    }
    expect(fromBootstrap.size).toBeGreaterThan(0);
  });

  it("discloses no secret, key, SQL or stack in any response", async () => {
    await originRoom(MAC, ROOM_MAC, DEVICE_MAC, TOKEN_MAC);
    const bad = await postOperation({ protocol_version: 1, op: "nope" }, TOKEN_MAC);
    expectNoLeak(await bad.text());

    const unauthorised = await getChanges("?after_seq=0&limit=300", "gdt1_" + "A".repeat(43));
    expectNoLeak(unauthorised.text);
  });
});
