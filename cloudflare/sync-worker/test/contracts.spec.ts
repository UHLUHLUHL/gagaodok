import { describe, expect, it } from "vitest";
import {
  MAX_FIELD_ENVELOPE_BYTES,
  MAX_OPERATION_BODY_BYTES,
  assertOperationBodySize,
  parseOperationRequest,
  worldlineKey,
} from "../src/contracts/operation";
import { EXTENSION_KEY_PATTERN, SPACES, isSafeSyncInteger } from "../src/contracts/identity";

const ACCOUNT_DEVICE = "80000000-0000-4000-8000-000000000001";
const OPERATION = "90000000-0000-4000-8000-000000000003";
const ROOM = "10000000-0000-4000-8000-000000000002";
const WORLDLINE = "20000000-0000-4000-8000-000000000001";
const TURN = "30000000-0000-4000-8000-000000000007";
// Contains hex letters, so its lowercase spelling is a genuinely different
// string. An all-digit UUID has no case and would silently pass.
const ROOM_WITH_LETTERS = "10000000-0000-4000-8000-0000000000AF";

function makeOperation(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    protocol_version: 1,
    operation_id: OPERATION,
    device_id: ACCOUNT_DEVICE,
    op: "patch_room",
    entity_type: "room",
    target: { space_id: "MAC_SPACE", room_id: ROOM, worldline_id: null },
    base_revision: 41,
    set: { status_message: "QkFTRTY0X0VOVkVMT1BF" },
    clear: [],
    created_at: "2026-08-28T00:00:00Z",
    ...overrides,
  };
}

describe("identity primitives", () => {
  it("exposes exactly the three canonical spaces", () => {
    expect([...SPACES]).toEqual(["MAC_SPACE", "PHONE_SPACE", "TABLET_SPACE"]);
  });

  it("maps a null worldline to the empty D1 key without a sentinel UUID", () => {
    expect(worldlineKey(null)).toBe("");
    expect(worldlineKey(null)).not.toContain("-");
    expect(worldlineKey(WORLDLINE)).toBe(WORLDLINE);
  });

  it("bounds safe integers at 2^53-1", () => {
    expect(isSafeSyncInteger(0)).toBe(true);
    expect(isSafeSyncInteger(9_007_199_254_740_991)).toBe(true);
    expect(isSafeSyncInteger(9_007_199_254_740_992)).toBe(false);
    expect(isSafeSyncInteger(-1)).toBe(false);
    expect(isSafeSyncInteger(1.5)).toBe(false);
  });

  it("accepts only three lowercase dotted extension segments", () => {
    expect(EXTENSION_KEY_PATTERN.test("android.room_profile.base_affection")).toBe(true);
    for (const bad of [
      "Android.room_profile.base_affection",
      "android.room_profile",
      "android.room_profile.base.affection",
      "1android.room_profile.field",
      "android..field",
      "android.room-profile.field",
    ]) {
      expect(EXTENSION_KEY_PATTERN.test(bad)).toBe(false);
    }
  });
});

describe("parseOperationRequest — happy path", () => {
  it("accepts a well-formed patch_room operation", () => {
    const parsed = parseOperationRequest(makeOperation());
    expect(parsed.op).toBe("patch_room");
    expect(parsed.target.space_id).toBe("MAC_SPACE");
    expect(parsed.target.worldline_id).toBeNull();
    expect(parsed.worldline_key).toBe("");
  });

  it("accepts a named worldline and derives its key", () => {
    const parsed = parseOperationRequest(
      makeOperation({
        target: { space_id: "PHONE_SPACE", room_id: ROOM, worldline_id: WORLDLINE },
      }),
    );
    expect(parsed.worldline_key).toBe(WORLDLINE);
  });
});

describe("parseOperationRequest — identity validation", () => {
  it.each([{ space_id: "tablet" }, { space_id: "mac_space" }, { space_id: "UNKNOWN" }, { space_id: "" }])(
    "rejects non-canonical space: %j",
    (target) => {
      expect(() =>
        parseOperationRequest(
          makeOperation({ target: { ...target, room_id: ROOM, worldline_id: null } }),
        ),
      ).toThrowError("VALIDATION_FAILED");
    },
  );

  it("rejects lowercase UUIDs", () => {
    expect(ROOM_WITH_LETTERS.toLowerCase()).not.toBe(ROOM_WITH_LETTERS);
    expect(() =>
      parseOperationRequest(
        makeOperation({
          target: {
            space_id: "MAC_SPACE",
            room_id: ROOM_WITH_LETTERS.toLowerCase(),
            worldline_id: null,
          },
        }),
      ),
    ).toThrowError("VALIDATION_FAILED");
    // The uppercase spelling of the same UUID is accepted.
    expect(() =>
      parseOperationRequest(
        makeOperation({
          target: { space_id: "MAC_SPACE", room_id: ROOM_WITH_LETTERS, worldline_id: null },
        }),
      ),
    ).not.toThrow();
  });

  it("rejects an undefined worldline_id (null must be explicit)", () => {
    expect(() =>
      parseOperationRequest(
        makeOperation({ target: { space_id: "MAC_SPACE", room_id: ROOM } }),
      ),
    ).toThrowError("VALIDATION_FAILED");
  });

  it("rejects the wrong protocol version", () => {
    expect(() => parseOperationRequest(makeOperation({ protocol_version: 2 }))).toThrowError(
      "VALIDATION_FAILED",
    );
  });

  it("rejects unknown top-level fields (fail closed)", () => {
    expect(() => parseOperationRequest(makeOperation({ shadow_field: true }))).toThrowError(
      "VALIDATION_FAILED",
    );
  });
});

describe("parseOperationRequest — safe integers", () => {
  it("rejects an unsafe bubble_order", () => {
    expect(() =>
      parseOperationRequest(
        makeOperation({
          op: "create_bubble",
          entity_type: "bubble",
          target: {
            space_id: "MAC_SPACE",
            room_id: ROOM,
            worldline_id: null,
            turn_id: TURN,
            message_id: "40000000-0000-4000-8000-000000000001",
          },
          bubble_order: 9_007_199_254_740_992,
          set: { text: "QkFTRTY0" },
        }),
      ),
    ).toThrowError("VALIDATION_FAILED");
  });

  it("rejects a negative base_revision", () => {
    expect(() => parseOperationRequest(makeOperation({ base_revision: -1 }))).toThrowError(
      "VALIDATION_FAILED",
    );
  });

  it("rejects a client-supplied server_seq", () => {
    expect(() => parseOperationRequest(makeOperation({ server_seq: 10 }))).toThrowError(
      "VALIDATION_FAILED",
    );
  });
});

describe("parseOperationRequest — operation shape", () => {
  it("rejects whole-object PUT operations", () => {
    for (const op of ["put_room", "put_message", "replace_room"]) {
      expect(() => parseOperationRequest(makeOperation({ op }))).toThrowError("VALIDATION_FAILED");
    }
  });

  it("rejects delete_bubble", () => {
    expect(() =>
      parseOperationRequest(
        makeOperation({ op: "delete_bubble", entity_type: "bubble", set: {}, clear: [] }),
      ),
    ).toThrowError("VALIDATION_FAILED");
  });

  it("requires base_revision on patch operations", () => {
    const operation = makeOperation();
    delete operation["base_revision"];
    expect(() => parseOperationRequest(operation)).toThrowError("VALIDATION_FAILED");
  });

  it("requires a turn target on create_bubble", () => {
    expect(() =>
      parseOperationRequest(
        makeOperation({ op: "create_bubble", entity_type: "bubble", bubble_order: 3 }),
      ),
    ).toThrowError("VALIDATION_FAILED");
  });
});

describe("parseOperationRequest — set/clear", () => {
  it("rejects a path present in both set and clear", () => {
    expect(() =>
      parseOperationRequest(
        makeOperation({ set: { status_message: "QkFTRTY0" }, clear: ["status_message"] }),
      ),
    ).toThrowError("VALIDATION_FAILED");
  });

  it("rejects duplicate clear paths", () => {
    expect(() =>
      parseOperationRequest(makeOperation({ set: {}, clear: ["music_title", "music_title"] })),
    ).toThrowError("VALIDATION_FAILED");
  });

  it("rejects the _enc storage suffix on the wire", () => {
    expect(() =>
      parseOperationRequest(makeOperation({ set: { status_message_enc: "QkFTRTY0" } })),
    ).toThrowError("VALIDATION_FAILED");
  });

  it("accepts a well-formed extension path but rejects a malformed one", () => {
    expect(() =>
      parseOperationRequest(
        makeOperation({ set: { "extensions.android.room_profile.base_affection": "QkFTRTY0" } }),
      ),
    ).not.toThrow();
    expect(() =>
      parseOperationRequest(
        makeOperation({ set: { "extensions.Android.room_profile.base_affection": "QkFTRTY0" } }),
      ),
    ).toThrowError("VALIDATION_FAILED");
  });

  it("requires an empty patch to still be explicit", () => {
    const operation = makeOperation({ set: {}, clear: [] });
    expect(() => parseOperationRequest(operation)).not.toThrow();
  });
});

describe("parseOperationRequest — PHONE_SPACE restriction", () => {
  it.each(["create_group_state", "patch_group_state", "create_worldline", "patch_worldline"])(
    "rejects %s outside PHONE_SPACE",
    (op) => {
      for (const space of ["MAC_SPACE", "TABLET_SPACE"]) {
        expect(() =>
          parseOperationRequest(
            makeOperation({
              op,
              entity_type: op.includes("worldline") ? "worldline" : "group_state",
              target: { space_id: space, room_id: ROOM, worldline_id: null },
            }),
          ),
        ).toThrowError("VALIDATION_FAILED");
      }
    },
  );

  it("accepts group_state inside PHONE_SPACE", () => {
    expect(() =>
      parseOperationRequest(
        makeOperation({
          op: "patch_group_state",
          entity_type: "group_state",
          target: { space_id: "PHONE_SPACE", room_id: ROOM, worldline_id: null },
        }),
      ),
    ).not.toThrow();
  });

  it("rejects relationship_policy=group outside PHONE_SPACE", () => {
    expect(() =>
      parseOperationRequest(
        makeOperation({
          op: "create_engine_profile",
          entity_type: "engine_profile",
          relationship_policy: "group",
          base_revision: undefined,
          target: { space_id: "MAC_SPACE", room_id: ROOM, worldline_id: null },
        }),
      ),
    ).toThrowError("VALIDATION_FAILED");
  });
});

describe("size limits", () => {
  it("fixes the documented bounds", () => {
    expect(MAX_OPERATION_BODY_BYTES).toBe(2_000_000);
    expect(MAX_FIELD_ENVELOPE_BYTES).toBe(1_900_000);
  });

  it("accepts a body exactly at the limit and rejects one byte more", () => {
    expect(() => assertOperationBodySize(MAX_OPERATION_BODY_BYTES)).not.toThrow();
    expect(() => assertOperationBodySize(MAX_OPERATION_BODY_BYTES + 1)).toThrowError(
      "REQUEST_TOO_LARGE",
    );
  });

  it("rejects a single field envelope above the field bound", () => {
    const oversized = "A".repeat(MAX_FIELD_ENVELOPE_BYTES + 1);
    expect(() => parseOperationRequest(makeOperation({ set: { status_message: oversized } }))).toThrowError(
      "REQUEST_TOO_LARGE",
    );
  });

  it("accepts a field envelope exactly at the field bound", () => {
    const exact = "A".repeat(MAX_FIELD_ENVELOPE_BYTES);
    expect(() => parseOperationRequest(makeOperation({ set: { status_message: exact } }))).not.toThrow();
  });
});

describe("error envelope is content-free", () => {
  it("never echoes the offending value", () => {
    const secret = "QkFTRTY0X1NFQ1JFVF9DT05URU5U";
    try {
      parseOperationRequest(
        makeOperation({ target: { space_id: secret, room_id: ROOM, worldline_id: null } }),
      );
      throw new Error("expected a validation failure");
    } catch (error) {
      const serialised = JSON.stringify({
        message: (error as Error).message,
        ...(error as unknown as Record<string, unknown>),
      });
      expect(serialised).not.toContain(secret);
      expect((error as Error).message).toBe("VALIDATION_FAILED");
    }
  });
});
