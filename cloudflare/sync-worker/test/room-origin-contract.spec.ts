import { applyD1Migrations, env } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import {
  normalizeRoomOrigin,
  parseOperationRequest,
  roomOriginAllowsWriter,
} from "../src/contracts/operation";
import { applyOperationRequest } from "../src/handlers/operationRequest";

const ACCOUNT = "A0000000-0000-4000-8000-00000000000A";
const DEVICE_MAC = "B0000000-0000-4000-8000-000000000001";
const DEVICE_PHONE = "B0000000-0000-4000-8000-000000000002";
const DEVICE_TABLET = "B0000000-0000-4000-8000-000000000003";
const ROOM = "10000000-0000-4000-8000-000000000001";
const OPERATION = "E0000000-0000-4000-8000-000000000001";
const TIMESTAMP = "2026-08-31T00:00:00Z";
const TOKEN_MAC = `gdt1_${Buffer.from(Uint8Array.from({ length: 32 }, (_, i) => i + 1)).toString("base64url")}`;
const TOKEN_PHONE = `gdt1_${Buffer.from(Uint8Array.from({ length: 32 }, (_, i) => i + 33)).toString("base64url")}`;
const TOKEN_TABLET = `gdt1_${Buffer.from(Uint8Array.from({ length: 32 }, (_, i) => i + 65)).toString("base64url")}`;
const db = env.DB;

async function sha256Hex(token: string): Promise<string> {
  const bytes = Uint8Array.from(Buffer.from(token.slice(5), "base64url"));
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function body(writer: string, origin?: string, operationId = OPERATION): Record<string, unknown> {
  return {
    protocol_version: 1,
    operation_id: operationId,
    device_id:
      writer === "MAC_SPACE" ? DEVICE_MAC : writer === "PHONE_SPACE" ? DEVICE_PHONE : DEVICE_TABLET,
    op: "create_room",
    entity_type: "room",
    target: { space_id: writer, room_id: ROOM, worldline_id: null },
    metadata_set: origin === undefined ? {} : { origin_space_id: origin },
    metadata_clear: [],
    set: {},
    clear: [],
    created_at: TIMESTAMP,
  };
}

function request(payload: unknown, token: string): Request {
  return new Request("https://example.test/v1/sync/operations", {
    method: "POST",
    headers: { Authorization: `Device ${token}` },
    body: JSON.stringify(payload),
  });
}

async function insertDevice(device: string, space: string, token: string): Promise<void> {
  await db
    .prepare(
      `INSERT INTO device
         (account_id, device_id, space_id, platform, linked_at, key_generation, token_hash)
       VALUES (?, ?, ?, 'macos', ?, 1, ?)`,
    )
    .bind(ACCOUNT, device, space, TIMESTAMP, await sha256Hex(token))
    .run();
}

async function expectCode(run: () => Promise<unknown>, code: string): Promise<void> {
  let caught: unknown;
  try {
    await run();
  } catch (error) {
    caught = error;
  }
  expect((caught as { code?: string } | undefined)?.code).toBe(code);
}

beforeAll(async () => {
  await applyD1Migrations(db, env.TEST_MIGRATIONS);
});

beforeEach(async () => {
  for (const table of [
    "transaction_guard",
    "change_log",
    "operation_log",
    "room_extension_field",
    "room",
    "device",
    "account",
  ]) {
    await db.prepare(`DELETE FROM ${table}`).run();
  }
  await db
    .prepare("INSERT INTO account (account_id, created_at) VALUES (?, ?)")
    .bind(ACCOUNT, TIMESTAMP)
    .run();
  await insertDevice(DEVICE_MAC, "MAC_SPACE", TOKEN_MAC);
  await insertDevice(DEVICE_PHONE, "PHONE_SPACE", TOKEN_PHONE);
  await insertDevice(DEVICE_TABLET, "TABLET_SPACE", TOKEN_TABLET);
});

describe("room origin normalization and shard matrix", () => {
  it("normalizes an omitted legacy origin to the target space", () => {
    expect(normalizeRoomOrigin("MAC_SPACE")).toBe("MAC_SPACE");
    expect(parseOperationRequest(body("MAC_SPACE")).metadata_set.origin_space_id).toBe("MAC_SPACE");
  });

  it("accepts exactly the documented writer matrix", () => {
    expect(roomOriginAllowsWriter("PHONE_SPACE", "PHONE_SPACE")).toBe(true);
    expect(roomOriginAllowsWriter("PHONE_SPACE", "MAC_SPACE")).toBe(false);
    expect(roomOriginAllowsWriter("MAC_SPACE", "MAC_SPACE")).toBe(true);
    expect(roomOriginAllowsWriter("MAC_SPACE", "PHONE_SPACE")).toBe(true);
    expect(roomOriginAllowsWriter("MAC_SPACE", "TABLET_SPACE")).toBe(false);
    expect(roomOriginAllowsWriter("TABLET_SPACE", "TABLET_SPACE")).toBe(true);
    expect(roomOriginAllowsWriter("TABLET_SPACE", "MAC_SPACE")).toBe(true);
    expect(roomOriginAllowsWriter("TABLET_SPACE", "PHONE_SPACE")).toBe(true);
  });

  it("refuses a writer shard outside the matrix", () => {
    expect(() => parseOperationRequest(body("TABLET_SPACE", "MAC_SPACE"))).toThrow();
  });
});

describe("create_room family storage", () => {
  it("stores the normalized legacy origin", async () => {
    await applyOperationRequest(request(body("MAC_SPACE"), TOKEN_MAC), db);
    const row = await db
      .prepare("SELECT origin_space_id FROM room WHERE account_id = ? AND space_id = ? AND room_id = ?")
      .bind(ACCOUNT, "MAC_SPACE", ROOM)
      .first<{ origin_space_id: string }>();
    expect(row?.origin_space_id).toBe("MAC_SPACE");
  });

  it("rejects direct null inserts and origin identity updates", async () => {
    await expect(
      db
        .prepare(
          `INSERT INTO room
             (account_id, space_id, room_id, origin_space_id, revision, created_at, updated_at)
           VALUES (?, 'MAC_SPACE', ?, NULL, 0, ?, ?)`,
        )
        .bind(ACCOUNT, ROOM, TIMESTAMP, TIMESTAMP)
        .run(),
    ).rejects.toBeDefined();

    await applyOperationRequest(request(body("MAC_SPACE"), TOKEN_MAC), db);
    await expect(
      db
        .prepare(
          `UPDATE room SET origin_space_id = 'TABLET_SPACE'
            WHERE account_id = ? AND space_id = 'MAC_SPACE' AND room_id = ?`,
        )
        .bind(ACCOUNT, ROOM)
        .run(),
    ).rejects.toBeDefined();
  });

  it("allows a phone continuation only after the MAC origin exists", async () => {
    await expectCode(
      () => applyOperationRequest(request(body("PHONE_SPACE", "MAC_SPACE"), TOKEN_PHONE), db),
      "ENTITY_NOT_FOUND",
    );
    await applyOperationRequest(request(body("MAC_SPACE"), TOKEN_MAC), db);
    const continuation = body(
      "PHONE_SPACE",
      "MAC_SPACE",
      "E0000000-0000-4000-8000-000000000002",
    );
    const result = await applyOperationRequest(request(continuation, TOKEN_PHONE), db);
    expect(result.status).toBe("applied");
  });

  it("refuses a conflicting origin without consuming a sequence", async () => {
    await applyOperationRequest(request(body("MAC_SPACE"), TOKEN_MAC), db);
    const before = await db
      .prepare("SELECT next_server_seq FROM account WHERE account_id = ?")
      .bind(ACCOUNT)
      .first<{ next_server_seq: number }>();
    await expectCode(
      () =>
        applyOperationRequest(
          request(
            body("TABLET_SPACE", "TABLET_SPACE", "E0000000-0000-4000-8000-000000000003"),
            TOKEN_TABLET,
          ),
          db,
        ),
      "AUTH_INVALID",
    );
    const after = await db
      .prepare("SELECT next_server_seq FROM account WHERE account_id = ?")
      .bind(ACCOUNT)
      .first<{ next_server_seq: number }>();
    expect(after).toEqual(before);
  });
});
