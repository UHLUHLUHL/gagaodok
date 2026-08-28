import { describe, expect, it } from "vitest";
import {
  MAX_FIELD_ENVELOPE_BYTES,
  MAX_OPERATION_BODY_BYTES,
  RUNTIME_ENABLED_OPERATIONS,
  SCHEMA_OPERATIONS,
  assertOperationBodySize,
  parseOperationRequest,
} from "../src/contracts/operation";
import {
  EXTENSION_KEY_PATTERN,
  SPACES,
  decodeCanonicalBase64,
  isCanonicalBase64,
  isSafeSyncInteger,
  requireRfc3339Utc,
  worldlineKey,
} from "../src/contracts/identity";

const DEVICE = "80000000-0000-4000-8000-000000000001";
const OPERATION = "90000000-0000-4000-8000-000000000003";
const ROOM = "10000000-0000-4000-8000-0000000000AF";
const WORLDLINE = "20000000-0000-4000-8000-0000000000BF";
const TURN = "30000000-0000-4000-8000-0000000000CF";
const MESSAGE = "40000000-0000-4000-8000-0000000000DF";
const PERSONA_SNAPSHOT = "50000000-0000-4000-8000-0000000000EF";
const CHECKPOINT = "60000000-0000-4000-8000-0000000000FA";
const ATTACHMENT = "70000000-0000-4000-8000-0000000000FB";
const ENGINE_PROFILE = "C0000000-0000-4000-8000-0000000000E1";

/**
 * Build a syntactically valid field envelope: version=1, alg=1, a 4-byte
 * key_generation, a 12-byte nonce, and `tagAndCiphertextBytes` bytes of
 * ciphertext+tag. A real GCM tag is always 16 bytes, so the default (16,
 * i.e. empty plaintext) is exactly the 34-byte floor; passing less than 16
 * produces a too-short envelope on purpose for negative tests. Content is
 * arbitrary — these tests check shape, not cryptography.
 */
function validEnvelope(tagAndCiphertextBytes = 16): string {
  const total = 1 + 1 + 4 + 12 + tagAndCiphertextBytes;
  const bytes = new Uint8Array(total);
  bytes[0] = 1; // version
  bytes[1] = 1; // alg = AES-256-GCM
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function makeOperation(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    protocol_version: 1,
    operation_id: OPERATION,
    device_id: DEVICE,
    op: "patch_room",
    entity_type: "room",
    target: { space_id: "MAC_SPACE", room_id: ROOM, worldline_id: null },
    base_revision: 41,
    set: { status_message: validEnvelope() },
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

describe("real RFC 3339 UTC validation", () => {
  it("accepts genuinely valid instants", () => {
    for (const ok of [
      "2026-08-28T00:00:00Z",
      "2026-08-28T00:00:00.123Z",
      "2024-02-29T00:00:00Z", // leap day
      "2000-02-29T00:00:00Z", // divisible by 400: leap
      "2026-08-28T23:59:59Z",
    ]) {
      expect(() => requireRfc3339Utc(ok)).not.toThrow();
    }
  });

  it("rejects a shape that regex alone would accept", () => {
    // The previous validator's regex allowed \d{2} in every slot, so
    // "99-99T99:99:99" satisfied it. This must now fail.
    expect(() => requireRfc3339Utc("2026-99-99T99:99:99Z")).toThrowError("VALIDATION_FAILED");
  });

  it("rejects a day that overflows its month", () => {
    // new Date(...) alone would silently roll this over to March 2 instead
    // of rejecting it.
    expect(() => requireRfc3339Utc("2026-02-30T00:00:00Z")).toThrowError("VALIDATION_FAILED");
  });

  it("rejects February 29 in a non-leap year", () => {
    expect(() => requireRfc3339Utc("2026-02-29T00:00:00Z")).toThrowError("VALIDATION_FAILED");
    expect(() => requireRfc3339Utc("1900-02-29T00:00:00Z")).toThrowError("VALIDATION_FAILED");
  });

  it("rejects an out-of-range month", () => {
    expect(() => requireRfc3339Utc("2026-13-01T00:00:00Z")).toThrowError("VALIDATION_FAILED");
    expect(() => requireRfc3339Utc("2026-00-01T00:00:00Z")).toThrowError("VALIDATION_FAILED");
  });

  it("rejects an out-of-range hour, minute or second", () => {
    expect(() => requireRfc3339Utc("2026-08-28T24:00:00Z")).toThrowError("VALIDATION_FAILED");
    expect(() => requireRfc3339Utc("2026-08-28T00:60:00Z")).toThrowError("VALIDATION_FAILED");
    expect(() => requireRfc3339Utc("2026-08-28T00:00:60Z")).toThrowError("VALIDATION_FAILED");
  });

  it("rejects a numeric UTC offset (only Z is a UTC instant on this wire)", () => {
    expect(() => requireRfc3339Utc("2026-08-28T00:00:00+09:00")).toThrowError("VALIDATION_FAILED");
  });

  it("rejects non-string and malformed input", () => {
    expect(() => requireRfc3339Utc(1234)).toThrowError("VALIDATION_FAILED");
    expect(() => requireRfc3339Utc("not a date")).toThrowError("VALIDATION_FAILED");
  });
});

describe("canonical Base64 envelope validation", () => {
  it("recognises a well-formed envelope", () => {
    const envelope = validEnvelope();
    expect(isCanonicalBase64(envelope)).toBe(true);
    expect(decodeCanonicalBase64(envelope).length).toBeGreaterThanOrEqual(34);
  });

  it("rejects a non-Base64 string outright", () => {
    for (const bad of ["not base64!!", "has spaces here", "emoji🙂string", ""]) {
      expect(isCanonicalBase64(bad)).toBe(false);
    }
  });

  it("rejects a string whose length is not a multiple of four", () => {
    expect(isCanonicalBase64("QUJD")).toBe(true); // 4 chars, valid
    expect(isCanonicalBase64("QUJDR")).toBe(false); // 5 chars
  });

  it("rejects padding in a non-terminal position", () => {
    expect(isCanonicalBase64("QUI=QUJD")).toBe(false);
  });
});

describe("parseOperationRequest — envelope enforcement", () => {
  it("rejects a field value that is not Base64 at all", () => {
    expect(() =>
      parseOperationRequest(makeOperation({ set: { status_message: "not base64 content!!" } })),
    ).toThrowError("VALIDATION_FAILED");
  });

  it("rejects Base64 that decodes to fewer than 34 bytes", () => {
    // A short, syntactically valid Base64 string with no real envelope.
    expect(() =>
      parseOperationRequest(makeOperation({ set: { status_message: "QkFTRTY0" } })),
    ).toThrowError("VALIDATION_FAILED");
  });

  it("accepts an envelope at exactly the 34-byte floor", () => {
    const floor = validEnvelope(16); // tag only, zero plaintext = the floor
    expect(decodeCanonicalBase64(floor).length).toBe(34);
    expect(() =>
      parseOperationRequest(makeOperation({ set: { status_message: floor } })),
    ).not.toThrow();
  });

  it("rejects an envelope one byte short of the floor", () => {
    const tooShort = validEnvelope(15);
    expect(decodeCanonicalBase64(tooShort).length).toBe(33);
    expect(() =>
      parseOperationRequest(makeOperation({ set: { status_message: tooShort } })),
    ).toThrowError("VALIDATION_FAILED");
  });

  it("rejects an unsupported envelope version byte", () => {
    const bytes = new Uint8Array(34);
    bytes[0] = 2; // unsupported version
    bytes[1] = 1;
    let binary = "";
    for (const byte of bytes) binary += String.fromCharCode(byte);
    expect(() =>
      parseOperationRequest(makeOperation({ set: { status_message: btoa(binary) } })),
    ).toThrowError("VALIDATION_FAILED");
  });

  it("rejects an unsupported algorithm byte", () => {
    const bytes = new Uint8Array(34);
    bytes[0] = 1;
    bytes[1] = 9; // unsupported algorithm
    let binary = "";
    for (const byte of bytes) binary += String.fromCharCode(byte);
    expect(() =>
      parseOperationRequest(makeOperation({ set: { status_message: btoa(binary) } })),
    ).toThrowError("VALIDATION_FAILED");
  });

  it("never echoes the offending envelope value in an error", () => {
    const secret = "QkFTRTY0X1NFQ1JFVF9DT05URU5U";
    try {
      parseOperationRequest(makeOperation({ set: { status_message: secret } }));
      throw new Error("expected a validation failure");
    } catch (error) {
      const serialised = JSON.stringify({
        message: (error as Error).message,
        ...(error as unknown as Record<string, unknown>),
      });
      expect(serialised).not.toContain(secret);
    }
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
    expect(ROOM.toLowerCase()).not.toBe(ROOM);
    expect(() =>
      parseOperationRequest(
        makeOperation({
          target: { space_id: "MAC_SPACE", room_id: ROOM.toLowerCase(), worldline_id: null },
        }),
      ),
    ).toThrowError("VALIDATION_FAILED");
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

  it("rejects a plaintext top-level relationship_policy entirely", () => {
    // The Worker cannot see inside the encrypted engine_profile payload, so
    // it must not accept, echo, or gate on a plaintext policy claim.
    expect(() =>
      parseOperationRequest(makeOperation({ relationship_policy: "group" })),
    ).toThrowError("VALIDATION_FAILED");
    expect(() =>
      parseOperationRequest(makeOperation({ relationship_policy: "none" })),
    ).toThrowError("VALIDATION_FAILED");
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
            message_id: MESSAGE,
          },
          base_revision: undefined,
          bubble_order: 9_007_199_254_740_992,
          set: { text: validEnvelope() },
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

  it("rejects delete_bubble outright — it is not a schema operation", () => {
    expect(() =>
      parseOperationRequest(
        makeOperation({ op: "delete_bubble", entity_type: "bubble", set: {}, clear: [] }),
      ),
    ).toThrowError("VALIDATION_FAILED");
    expect(SCHEMA_OPERATIONS as readonly string[]).not.toContain("delete_bubble");
  });

  it("requires base_revision on patch operations", () => {
    const operation = makeOperation();
    delete operation["base_revision"];
    expect(() => parseOperationRequest(operation)).toThrowError("VALIDATION_FAILED");
  });

  it("requires a turn target on create_bubble", () => {
    expect(() =>
      parseOperationRequest(
        makeOperation({
          op: "create_bubble",
          entity_type: "bubble",
          base_revision: undefined,
          bubble_order: 3,
          target: { space_id: "MAC_SPACE", room_id: ROOM, worldline_id: null },
        }),
      ),
    ).toThrowError("VALIDATION_FAILED");
  });
});

describe("parseOperationRequest — delete_turn is schema-only in v1", () => {
  it("is defined in the schema but not enabled at runtime", () => {
    expect(SCHEMA_OPERATIONS as readonly string[]).toContain("delete_turn");
    expect(RUNTIME_ENABLED_OPERATIONS as readonly string[]).not.toContain("delete_turn");
  });

  it("rejects an otherwise well-formed delete_turn", () => {
    expect(() =>
      parseOperationRequest(
        makeOperation({
          op: "delete_turn",
          entity_type: "turn",
          target: { space_id: "PHONE_SPACE", room_id: ROOM, worldline_id: null, turn_id: TURN },
          base_revision: 12,
          set: {},
          clear: [],
        }),
      ),
    ).toThrowError("VALIDATION_FAILED");
  });
});

describe("parseOperationRequest — op/entity_type/target identity binding", () => {
  it("rejects entity_type that does not match op", () => {
    expect(() => parseOperationRequest(makeOperation({ entity_type: "worldline" }))).toThrowError(
      "VALIDATION_FAILED",
    );
  });

  it("rejects a persona_snapshot_id leaking into a room target", () => {
    expect(() =>
      parseOperationRequest(
        makeOperation({
          target: {
            space_id: "MAC_SPACE",
            room_id: ROOM,
            worldline_id: null,
            persona_snapshot_id: PERSONA_SNAPSHOT,
          },
        }),
      ),
    ).toThrowError("VALIDATION_FAILED");
  });

  it("rejects a turn_id on a persona_snapshot operation", () => {
    expect(() =>
      parseOperationRequest(
        makeOperation({
          op: "create_persona_snapshot",
          entity_type: "persona_snapshot",
          base_revision: undefined,
          target: {
            space_id: "PHONE_SPACE",
            persona_snapshot_id: PERSONA_SNAPSHOT,
            snapshot_revision: 1,
            turn_id: TURN,
          },
          set: { description: validEnvelope() },
        }),
      ),
    ).toThrowError("VALIDATION_FAILED");
  });

  it("accepts a well-formed persona_snapshot create (account+space scoped, no room)", () => {
    expect(() =>
      parseOperationRequest(
        makeOperation({
          op: "create_persona_snapshot",
          entity_type: "persona_snapshot",
          base_revision: undefined,
          target: {
            space_id: "PHONE_SPACE",
            persona_snapshot_id: PERSONA_SNAPSHOT,
            snapshot_revision: 1,
          },
          set: { description: validEnvelope() },
        }),
      ),
    ).not.toThrow();
  });

  it("rejects a persona_snapshot target missing snapshot_revision", () => {
    expect(() =>
      parseOperationRequest(
        makeOperation({
          op: "create_persona_snapshot",
          entity_type: "persona_snapshot",
          base_revision: undefined,
          target: { space_id: "PHONE_SPACE", persona_snapshot_id: PERSONA_SNAPSHOT },
          set: { description: validEnvelope() },
        }),
      ),
    ).toThrowError("VALIDATION_FAILED");
  });

  it("accepts a well-formed engine_profile create (account+space scoped, no room)", () => {
    expect(() =>
      parseOperationRequest(
        makeOperation({
          op: "create_engine_profile",
          entity_type: "engine_profile",
          base_revision: undefined,
          target: {
            space_id: "MAC_SPACE",
            engine_profile_id: ENGINE_PROFILE,
            profile_revision: 1,
          },
          set: { mode: validEnvelope() },
        }),
      ),
    ).not.toThrow();
  });

  it("rejects a room_id leaking into an engine_profile target", () => {
    expect(() =>
      parseOperationRequest(
        makeOperation({
          op: "create_engine_profile",
          entity_type: "engine_profile",
          base_revision: undefined,
          target: {
            space_id: "MAC_SPACE",
            engine_profile_id: ENGINE_PROFILE,
            profile_revision: 1,
            room_id: ROOM,
          },
          set: { mode: validEnvelope() },
        }),
      ),
    ).toThrowError("VALIDATION_FAILED");
  });

  it("accepts a well-formed checkpoint create with room+worldline scope", () => {
    expect(() =>
      parseOperationRequest(
        makeOperation({
          op: "create_checkpoint",
          entity_type: "checkpoint",
          base_revision: undefined,
          target: {
            space_id: "MAC_SPACE",
            room_id: ROOM,
            worldline_id: null,
            checkpoint_id: CHECKPOINT,
          },
          set: { summary_text: validEnvelope() },
        }),
      ),
    ).not.toThrow();
  });

  it("rejects an attachment_id leaking into a checkpoint target", () => {
    expect(() =>
      parseOperationRequest(
        makeOperation({
          op: "create_checkpoint",
          entity_type: "checkpoint",
          base_revision: undefined,
          target: {
            space_id: "MAC_SPACE",
            room_id: ROOM,
            worldline_id: null,
            checkpoint_id: CHECKPOINT,
            attachment_id: ATTACHMENT,
          },
          set: { summary_text: validEnvelope() },
        }),
      ),
    ).toThrowError("VALIDATION_FAILED");
  });

  it("accepts a well-formed attachment create (no room, no worldline)", () => {
    expect(() =>
      parseOperationRequest(
        makeOperation({
          op: "create_attachment",
          entity_type: "attachment",
          base_revision: undefined,
          target: { space_id: "MAC_SPACE", attachment_id: ATTACHMENT },
          set: { file_name: validEnvelope() },
        }),
      ),
    ).not.toThrow();
  });

  it("rejects a worldline_id on an attachment target", () => {
    expect(() =>
      parseOperationRequest(
        makeOperation({
          op: "create_attachment",
          entity_type: "attachment",
          base_revision: undefined,
          target: {
            space_id: "MAC_SPACE",
            attachment_id: ATTACHMENT,
            worldline_id: null,
          },
          set: { file_name: validEnvelope() },
        }),
      ),
    ).toThrowError("VALIDATION_FAILED");
  });

  it("requires a non-null worldline_id on worldline operations (identifies the worldline itself)", () => {
    expect(() =>
      parseOperationRequest(
        makeOperation({
          op: "create_worldline",
          entity_type: "worldline",
          base_revision: undefined,
          target: { space_id: "PHONE_SPACE", room_id: ROOM, worldline_id: null },
          set: { name: validEnvelope() },
        }),
      ),
    ).toThrowError("VALIDATION_FAILED");
  });

  it("accepts a well-formed worldline create with a real worldline_id", () => {
    expect(() =>
      parseOperationRequest(
        makeOperation({
          op: "create_worldline",
          entity_type: "worldline",
          base_revision: undefined,
          target: { space_id: "PHONE_SPACE", room_id: ROOM, worldline_id: WORLDLINE },
          set: { name: validEnvelope() },
        }),
      ),
    ).not.toThrow();
  });
});

describe("parseOperationRequest — set/clear", () => {
  it("rejects a path present in both set and clear", () => {
    expect(() =>
      parseOperationRequest(
        makeOperation({ set: { status_message: validEnvelope() }, clear: ["status_message"] }),
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
      parseOperationRequest(makeOperation({ set: { status_message_enc: validEnvelope() } })),
    ).toThrowError("VALIDATION_FAILED");
  });

  it("accepts a well-formed extension path but rejects a malformed one", () => {
    expect(() =>
      parseOperationRequest(
        makeOperation({
          set: { "extensions.android.room_profile.base_affection": validEnvelope() },
        }),
      ),
    ).not.toThrow();
    expect(() =>
      parseOperationRequest(
        makeOperation({
          set: { "extensions.Android.room_profile.base_affection": validEnvelope() },
        }),
      ),
    ).toThrowError("VALIDATION_FAILED");
  });

  it("requires an empty patch to still be explicit", () => {
    const operation = makeOperation({ set: {}, clear: [] });
    expect(() => parseOperationRequest(operation)).not.toThrow();
  });
});

describe("parseOperationRequest — PHONE_SPACE restriction", () => {
  it.each(["create_group_state", "patch_group_state"])("rejects %s outside PHONE_SPACE", (op) => {
    for (const space of ["MAC_SPACE", "TABLET_SPACE"]) {
      expect(() =>
        parseOperationRequest(
          makeOperation({
            op,
            entity_type: "group_state",
            base_revision: op.startsWith("patch") ? 1 : undefined,
            target: { space_id: space, room_id: ROOM, worldline_id: null },
          }),
        ),
      ).toThrowError("VALIDATION_FAILED");
    }
  });

  it.each(["create_worldline", "patch_worldline"])("rejects %s outside PHONE_SPACE", (op) => {
    for (const space of ["MAC_SPACE", "TABLET_SPACE"]) {
      expect(() =>
        parseOperationRequest(
          makeOperation({
            op,
            entity_type: "worldline",
            base_revision: op.startsWith("patch") ? 1 : undefined,
            target: { space_id: space, room_id: ROOM, worldline_id: WORLDLINE },
          }),
        ),
      ).toThrowError("VALIDATION_FAILED");
    }
  });

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
    // Pad a valid envelope's ciphertext until the Base64 string exceeds the
    // bound; it must still be recognised as canonical Base64 first.
    const payloadBytes = MAX_FIELD_ENVELOPE_BYTES; // guarantees overflow after encoding
    const oversized = validEnvelope(payloadBytes);
    expect(oversized.length).toBeGreaterThan(MAX_FIELD_ENVELOPE_BYTES);
    expect(() =>
      parseOperationRequest(makeOperation({ set: { status_message: oversized } })),
    ).toThrowError("REQUEST_TOO_LARGE");
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
