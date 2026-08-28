import { describe, expect, it } from "vitest";
import {
  MAX_FIELD_ENVELOPE_BYTES,
  MAX_OPERATION_BODY_BYTES,
  RUNTIME_ENABLED_OPERATIONS,
  SCHEMA_OPERATIONS,
  assertOperationBodySize,
  getEntityShape,
  getOperationSpec,
  isRuntimeEnabledOperation,
  isSchemaOperation,
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

/** The metadata every create of these entities must carry (API draft §4.1.0). */
const PERSONA_CREATE_METADATA = {
  owner_space_id: "PHONE_SPACE",
  created_by_device_id: DEVICE,
  created_at: "2026-08-28T00:00:00Z",
  persona_schema_version: 1,
};

function checkpointCreateMetadata(spaceId: string): Record<string, unknown> {
  return {
    checkpoint_schema_version: 1,
    owner_space_id: spaceId,
    created_by_device_id: DEVICE,
    created_at: "2026-08-28T00:00:00Z",
  };
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
    metadata_set: {},
    metadata_clear: [],
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

describe("parseOperationRequest — plaintext metadata is separate from encrypted set", () => {
  // API draft §4.1.0: `set`/`clear` carry encrypted envelopes and extension
  // keys; the plaintext canonical metadata D1 has to check as identity, FK or
  // range travels in `metadata_set`/`metadata_clear`.
  const ENGINE_REF = {
    engine_profile_id: ENGINE_PROFILE,
    engine_profile_revision: 3,
  };

  it("requires both metadata fields to be present explicitly", () => {
    for (const missing of ["metadata_set", "metadata_clear"]) {
      const operation = makeOperation();
      delete operation[missing];
      expect(() => parseOperationRequest(operation)).toThrowError("VALIDATION_FAILED");
    }
  });

  it("accepts empty metadata and returns it as empty, not undefined", () => {
    const parsed = parseOperationRequest(makeOperation());
    expect(parsed.metadata_set).toEqual({});
    expect(parsed.metadata_clear).toEqual([]);
  });

  it("accepts the room reference pair on patch_room", () => {
    const parsed = parseOperationRequest(makeOperation({ metadata_set: ENGINE_REF }));
    expect(parsed.metadata_set).toEqual(ENGINE_REF);
    // The encrypted set is untouched by the metadata path.
    expect(Object.keys(parsed.set)).toEqual(["status_message"]);
  });

  it("rejects an unknown metadata key", () => {
    for (const key of ["room_id", "revision", "server_seq", "title", "engineProfileId"]) {
      expect(() =>
        parseOperationRequest(makeOperation({ metadata_set: { [key]: 1 } })),
      ).toThrowError("VALIDATION_FAILED");
    }
  });

  it("rejects a metadata key on an operation that allows none", () => {
    expect(() =>
      parseOperationRequest(
        makeOperation({
          op: "patch_turn",
          entity_type: "turn",
          target: { space_id: "MAC_SPACE", room_id: ROOM, worldline_id: null, turn_id: TURN },
          metadata_set: ENGINE_REF,
        }),
      ),
    ).toThrowError("VALIDATION_FAILED");
  });

  it("rejects the same field in metadata_set and metadata_clear", () => {
    expect(() =>
      parseOperationRequest(
        makeOperation({
          metadata_set: ENGINE_REF,
          metadata_clear: ["engine_profile_id"],
        }),
      ),
    ).toThrowError("VALIDATION_FAILED");
  });

  it("rejects a duplicate or unknown metadata_clear entry", () => {
    expect(() =>
      parseOperationRequest(
        makeOperation({ metadata_clear: ["engine_profile_id", "engine_profile_id"] }),
      ),
    ).toThrowError("VALIDATION_FAILED");
    expect(() =>
      parseOperationRequest(makeOperation({ metadata_clear: ["nonsense"] })),
    ).toThrowError("VALIDATION_FAILED");
  });

  it("requires an id/revision pair to move together", () => {
    for (const half of [
      { engine_profile_id: ENGINE_PROFILE },
      { engine_profile_revision: 3 },
      { persona_snapshot_id: PERSONA_SNAPSHOT },
      { persona_snapshot_revision: 2 },
    ]) {
      expect(() => parseOperationRequest(makeOperation({ metadata_set: half }))).toThrowError(
        "VALIDATION_FAILED",
      );
    }
    // Clearing is the same rule: a room never keeps half a reference.
    expect(() =>
      parseOperationRequest(makeOperation({ metadata_clear: ["engine_profile_id"] })),
    ).toThrowError("VALIDATION_FAILED");
    const parsed = parseOperationRequest(
      makeOperation({ metadata_clear: ["engine_profile_id", "engine_profile_revision"] }),
    );
    expect(parsed.metadata_clear).toEqual([
      "engine_profile_id",
      "engine_profile_revision",
    ]);
  });

  it("rejects a revision below 1 or not an integer", () => {
    for (const bad of [0, -1, 1.5, "3", null]) {
      expect(() =>
        parseOperationRequest(
          makeOperation({
            metadata_set: { engine_profile_id: ENGINE_PROFILE, engine_profile_revision: bad },
          }),
        ),
      ).toThrowError("VALIDATION_FAILED");
    }
  });

  it("refuses a metadata field smuggled into the encrypted set", () => {
    expect(() =>
      parseOperationRequest(
        makeOperation({ set: { engine_profile_id: validEnvelope() } }),
      ),
    ).toThrowError("VALIDATION_FAILED");
  });
});

describe("parseOperationRequest — the M04 metadata allowlist table", () => {
  // API draft §4.1.0 is the single contract: required set, optional set and
  // allowed clear, per operation.
  const PERSONA_REQUIRED = {
    owner_space_id: "PHONE_SPACE",
    created_by_device_id: DEVICE,
    created_at: "2026-08-28T00:00:00Z",
    persona_schema_version: 1,
  };
  const CHECKPOINT_REQUIRED = {
    checkpoint_schema_version: 1,
    owner_space_id: "MAC_SPACE",
    created_by_device_id: DEVICE,
    created_at: "2026-08-28T00:00:00Z",
  };

  function personaCreate(overrides: Record<string, unknown> = {}): Record<string, unknown> {
    return makeOperation({
      op: "create_persona_snapshot",
      entity_type: "persona_snapshot",
      target: {
        space_id: "PHONE_SPACE",
        persona_snapshot_id: PERSONA_SNAPSHOT,
        snapshot_revision: 1,
      },
      base_revision: 0,
      set: { description: validEnvelope() },
      metadata_set: PERSONA_REQUIRED,
      ...overrides,
    });
  }

  function checkpointOp(
    op: "create_checkpoint" | "patch_checkpoint",
    overrides: Record<string, unknown> = {},
  ): Record<string, unknown> {
    return makeOperation({
      op,
      entity_type: "checkpoint",
      target: {
        space_id: "MAC_SPACE",
        room_id: ROOM,
        worldline_id: null,
        checkpoint_id: CHECKPOINT,
      },
      base_revision: op === "patch_checkpoint" ? 4 : undefined,
      set: { summary_text: validEnvelope() },
      metadata_set: op === "create_checkpoint" ? CHECKPOINT_REQUIRED : {},
      ...overrides,
    });
  }

  it("refuses a non-empty metadata_clear on every create operation", () => {
    // Clearing metadata of a row that does not exist yet has no meaning.
    expect(() =>
      parseOperationRequest(personaCreate({ metadata_clear: ["created_at"] })),
    ).toThrowError("VALIDATION_FAILED");
    expect(() =>
      parseOperationRequest(
        checkpointOp("create_checkpoint", { metadata_clear: ["through_server_seq"] }),
      ),
    ).toThrowError("VALIDATION_FAILED");
    expect(() =>
      parseOperationRequest(
        makeOperation({
          op: "create_engine_profile",
          entity_type: "engine_profile",
          target: {
            space_id: "MAC_SPACE",
            engine_profile_id: ENGINE_PROFILE,
            profile_revision: 2,
          },
          base_revision: undefined,
          set: { mode: validEnvelope() },
          metadata_clear: ["compaction_compat_tag"],
        }),
      ),
    ).toThrowError("VALIDATION_FAILED");
  });

  it("requires every mandatory metadata field on create_persona_snapshot", () => {
    expect(() => parseOperationRequest(personaCreate())).not.toThrow();
    for (const missing of Object.keys(PERSONA_REQUIRED)) {
      const metadata = { ...PERSONA_REQUIRED };
      delete (metadata as Record<string, unknown>)[missing];
      expect(() => parseOperationRequest(personaCreate({ metadata_set: metadata }))).toThrowError(
        "VALIDATION_FAILED",
      );
    }
  });

  it("requires every mandatory metadata field on create_checkpoint", () => {
    expect(() => parseOperationRequest(checkpointOp("create_checkpoint"))).not.toThrow();
    for (const missing of Object.keys(CHECKPOINT_REQUIRED)) {
      const metadata = { ...CHECKPOINT_REQUIRED };
      delete (metadata as Record<string, unknown>)[missing];
      expect(() =>
        parseOperationRequest(checkpointOp("create_checkpoint", { metadata_set: metadata })),
      ).toThrowError("VALIDATION_FAILED");
    }
  });

  it("accepts the optional create_checkpoint metadata as documented", () => {
    const parsed = parseOperationRequest(
      checkpointOp("create_checkpoint", {
        metadata_set: {
          ...CHECKPOINT_REQUIRED,
          first_turn_id: TURN,
          last_turn_id: TURN,
          through_server_seq: 10390,
          compaction_compat_tag: "0000000000000000000000000000legacy",
        },
      }),
    );
    expect(parsed.metadata_set.through_server_seq).toBe(10390);
  });

  it("refuses provenance metadata on patch_checkpoint, set or clear", () => {
    // owner_space_id, created_by_device_id and created_at are creation
    // provenance: a patch may neither rewrite nor erase them.
    for (const key of ["owner_space_id", "created_by_device_id", "created_at"] as const) {
      expect(() =>
        parseOperationRequest(
          checkpointOp("patch_checkpoint", {
            metadata_set: { [key]: CHECKPOINT_REQUIRED[key] },
          }),
        ),
      ).toThrowError("VALIDATION_FAILED");
      expect(() =>
        parseOperationRequest(checkpointOp("patch_checkpoint", { metadata_clear: [key] })),
      ).toThrowError("VALIDATION_FAILED");
    }
  });

  it("allows the documented patch_checkpoint fields, range as a pair", () => {
    expect(() =>
      parseOperationRequest(
        checkpointOp("patch_checkpoint", {
          metadata_set: { through_server_seq: 5, checkpoint_schema_version: 2 },
          metadata_clear: ["first_turn_id", "last_turn_id"],
        }),
      ),
    ).not.toThrow();
    expect(() =>
      parseOperationRequest(
        checkpointOp("patch_checkpoint", { metadata_clear: ["first_turn_id"] }),
      ),
    ).toThrowError("VALIDATION_FAILED");
    expect(() =>
      parseOperationRequest(
        checkpointOp("patch_checkpoint", { metadata_set: { first_turn_id: TURN } }),
      ),
    ).toThrowError("VALIDATION_FAILED");
  });

  it("bounds compaction_compat_tag at 1..256 UTF-16 code units without parsing it", () => {
    const build = (tag: unknown) =>
      makeOperation({
        op: "create_engine_profile",
        entity_type: "engine_profile",
        target: {
          space_id: "MAC_SPACE",
          engine_profile_id: ENGINE_PROFILE,
          profile_revision: 2,
        },
        base_revision: undefined,
        set: { mode: validEnvelope() },
        metadata_set: { compaction_compat_tag: tag },
      });
    expect(() => parseOperationRequest(build("x"))).not.toThrow();
    expect(() => parseOperationRequest(build("y".repeat(256)))).not.toThrow();
    for (const bad of ["", "z".repeat(257), 3, null]) {
      expect(() => parseOperationRequest(build(bad))).toThrowError("VALIDATION_FAILED");
    }
  });
});

describe("parseOperationRequest — create_attachment metadata", () => {
  // API draft §4.1.0 / canonical schema §7. The client declares sizes, hash and
  // key generation as plaintext metadata; r2_object_key, state and server_seq
  // are server-owned and must never arrive on the wire.
  const MAX_SOURCE = 12_582_912;
  const OVERHEAD = 34;

  const REQUIRED = {
    origin_space_id: "PHONE_SPACE",
    kind: "attachment",
    source_byte_size: 1024,
    ciphertext_byte_size: 1024 + OVERHEAD,
    ciphertext_hash: "b".repeat(64),
    key_generation: 1,
    created_at: "2026-08-28T00:00:00Z",
  };

  function attachment(overrides: Record<string, unknown> = {}): Record<string, unknown> {
    return makeOperation({
      op: "create_attachment",
      entity_type: "attachment",
      target: { space_id: "PHONE_SPACE", attachment_id: ATTACHMENT },
      base_revision: undefined,
      set: {
        file_name: validEnvelope(),
        mime_type: validEnvelope(),
        wrapped_file_key: validEnvelope(),
      },
      metadata_set: REQUIRED,
      ...overrides,
    });
  }

  it("accepts the documented shape", () => {
    const parsed = parseOperationRequest(attachment());
    expect(parsed.metadata_set.ciphertext_byte_size).toBe(1024 + OVERHEAD);
    expect(Object.keys(parsed.set).sort()).toEqual([
      "file_name",
      "mime_type",
      "wrapped_file_key",
    ]);
  });

  it("requires every metadata field", () => {
    for (const missing of Object.keys(REQUIRED)) {
      const metadata = { ...REQUIRED };
      delete (metadata as Record<string, unknown>)[missing];
      expect(() => parseOperationRequest(attachment({ metadata_set: metadata }))).toThrowError(
        "VALIDATION_FAILED",
      );
    }
  });

  it("requires origin_space_id to equal the target space", () => {
    expect(() =>
      parseOperationRequest(
        attachment({ metadata_set: { ...REQUIRED, origin_space_id: "MAC_SPACE" } }),
      ),
    ).toThrowError("VALIDATION_FAILED");
  });

  it("binds ciphertext size to exactly source + 34 and bounds both", () => {
    const sized = (source: number, ciphertext: number) =>
      attachment({
        metadata_set: {
          ...REQUIRED,
          source_byte_size: source,
          ciphertext_byte_size: ciphertext,
        },
      });
    expect(() => parseOperationRequest(sized(MAX_SOURCE, MAX_SOURCE + OVERHEAD))).not.toThrow();
    expect(() => parseOperationRequest(sized(1, 1 + OVERHEAD))).not.toThrow();
    for (const [source, ciphertext] of [
      [1024, 1024],
      [1024, 1024 + OVERHEAD - 1],
      [1024, 1024 + OVERHEAD + 1],
      [0, OVERHEAD],
      [-1, OVERHEAD - 1],
      [MAX_SOURCE + 1, MAX_SOURCE + 1 + OVERHEAD],
    ] as ReadonlyArray<readonly [number, number]>) {
      expect(() => parseOperationRequest(sized(source, ciphertext))).toThrowError(
        "VALIDATION_FAILED",
      );
    }
    // A non-integer size is refused before the arithmetic is trusted.
    expect(() =>
      parseOperationRequest(
        attachment({ metadata_set: { ...REQUIRED, source_byte_size: 1024.5 } }),
      ),
    ).toThrowError("VALIDATION_FAILED");
  });

  it("rejects an unknown kind, a bad hash or another key generation", () => {
    for (const kind of ["image", "ATTACHMENT", ""]) {
      expect(() =>
        parseOperationRequest(attachment({ metadata_set: { ...REQUIRED, kind } })),
      ).toThrowError("VALIDATION_FAILED");
    }
    for (const hash of ["B".repeat(64), "b".repeat(63), "b".repeat(65), `${"b".repeat(63)}g`]) {
      expect(() =>
        parseOperationRequest(attachment({ metadata_set: { ...REQUIRED, ciphertext_hash: hash } })),
      ).toThrowError("VALIDATION_FAILED");
    }
    for (const generation of [0, 2, "1"]) {
      expect(() =>
        parseOperationRequest(
          attachment({ metadata_set: { ...REQUIRED, key_generation: generation } }),
        ),
      ).toThrowError("VALIDATION_FAILED");
    }
  });

  it("refuses server-owned fields on the wire", () => {
    for (const [key, value] of [
      ["r2_object_key", "obj/70000000-0000-4000-8000-0000000000FF"],
      ["state", "allocated"],
      ["server_seq", 1],
    ] as ReadonlyArray<readonly [string, unknown]>) {
      expect(() =>
        parseOperationRequest(attachment({ metadata_set: { ...REQUIRED, [key]: value } })),
      ).toThrowError("VALIDATION_FAILED");
    }
  });

  it("refuses a non-empty metadata_clear", () => {
    expect(() =>
      parseOperationRequest(attachment({ metadata_clear: ["ciphertext_hash"] })),
    ).toThrowError("VALIDATION_FAILED");
  });

  it("requires exactly the three encrypted fields", () => {
    for (const missing of ["file_name", "mime_type", "wrapped_file_key"]) {
      const set: Record<string, string> = {
        file_name: validEnvelope(),
        mime_type: validEnvelope(),
        wrapped_file_key: validEnvelope(),
      };
      delete set[missing];
      expect(() => parseOperationRequest(attachment({ set }))).toThrowError("VALIDATION_FAILED");
    }
    // An extra encrypted field, and an extension path, are both refused.
    expect(() =>
      parseOperationRequest(
        attachment({
          set: {
            file_name: validEnvelope(),
            mime_type: validEnvelope(),
            wrapped_file_key: validEnvelope(),
            summary_text: validEnvelope(),
          },
        }),
      ),
    ).toThrowError("VALIDATION_FAILED");
    expect(() =>
      parseOperationRequest(
        attachment({
          set: {
            file_name: validEnvelope(),
            mime_type: validEnvelope(),
            wrapped_file_key: validEnvelope(),
            "android.attachment.extra": validEnvelope(),
          },
        }),
      ),
    ).toThrowError("VALIDATION_FAILED");
    expect(() =>
      parseOperationRequest(attachment({ clear: ["file_name"] })),
    ).toThrowError("VALIDATION_FAILED");
  });
});

describe("parseOperationRequest — create_persona_snapshot head CAS", () => {
  function snapshot(baseRevision: unknown, snapshotRevision: number): Record<string, unknown> {
    return makeOperation({
      op: "create_persona_snapshot",
      entity_type: "persona_snapshot",
      target: {
        space_id: "PHONE_SPACE",
        persona_snapshot_id: PERSONA_SNAPSHOT,
        snapshot_revision: snapshotRevision,
      },
      base_revision: baseRevision,
      set: { description: validEnvelope() },
      metadata_set: {
        owner_space_id: "PHONE_SPACE",
        created_by_device_id: DEVICE,
        created_at: "2026-08-28T00:00:00Z",
        persona_schema_version: 1,
      },
    });
  }

  it("accepts the first snapshot as base 0 → revision 1", () => {
    expect(parseOperationRequest(snapshot(0, 1)).base_revision).toBe(0);
  });

  it("accepts a later snapshot only as base + 1", () => {
    expect(parseOperationRequest(snapshot(4, 5)).base_revision).toBe(4);
    const mismatched: ReadonlyArray<readonly [number, number]> = [
      [0, 2],
      [4, 4],
      [4, 6],
      [5, 1],
    ];
    for (const [base, target] of mismatched) {
      expect(() => parseOperationRequest(snapshot(base, target))).toThrowError(
        "VALIDATION_FAILED",
      );
    }
  });

  it("requires base_revision even though it is a create", () => {
    const operation = snapshot(0, 1);
    delete operation.base_revision;
    expect(() => parseOperationRequest(operation)).toThrowError("VALIDATION_FAILED");
  });

  it("still refuses base_revision on the other create operations", () => {
    expect(() =>
      parseOperationRequest(
        makeOperation({
          op: "create_engine_profile",
          entity_type: "engine_profile",
          target: {
            space_id: "MAC_SPACE",
            engine_profile_id: ENGINE_PROFILE,
            profile_revision: 2,
          },
          base_revision: 1,
          set: { mode: validEnvelope() },
        }),
      ),
    ).toThrowError("VALIDATION_FAILED");
  });
});

describe("parseOperationRequest — a named worldline is PHONE_SPACE only", () => {
  // canonical schema §11: group chats and worldlines exist only on the phone.
  // A null worldline_id is the room's default scope and stays legal in every
  // canonical space; a non-null one names a worldline row, which only
  // PHONE_SPACE can have. D1 states the same rule as a CHECK on `turn`.
  const ROOM_ENTITY: ReadonlyArray<[string, string, Record<string, unknown>]> = [
    ["create_room", "room", {}],
    ["patch_room", "room", {}],
  ];
  // Entities that keep the `nullable` rule: a named worldline is a legal
  // target axis for them on the phone. `room` is not one of them — its D1
  // identity has no worldline column at all (see the null-only describe below).
  const WORLDLINE_NULLABLE: ReadonlyArray<[string, string, Record<string, unknown>]> = [
    ["create_checkpoint", "checkpoint", { checkpoint_id: CHECKPOINT }],
    ["patch_checkpoint", "checkpoint", { checkpoint_id: CHECKPOINT }],
    ["create_turn", "turn", { turn_id: TURN }],
    ["patch_turn", "turn", { turn_id: TURN }],
    ["create_bubble", "bubble", { turn_id: TURN, message_id: MESSAGE }],
    ["patch_bubble", "bubble", { turn_id: TURN, message_id: MESSAGE }],
  ];
  const ROOM_SCOPED = [...ROOM_ENTITY, ...WORLDLINE_NULLABLE];

  function build(
    op: string,
    entityType: string,
    extra: Record<string, unknown>,
    spaceId: string,
    worldlineId: string | null,
  ): Record<string, unknown> {
    const isCreate = op.startsWith("create_");
    return makeOperation({
      op,
      entity_type: entityType,
      target: { space_id: spaceId, room_id: ROOM, worldline_id: worldlineId, ...extra },
      base_revision: isCreate ? undefined : 41,
      bubble_order: op === "create_bubble" ? 3 : undefined,
      set: { title: validEnvelope() },
      metadata_set: op === "create_checkpoint" ? checkpointCreateMetadata(spaceId) : {},
    });
  }

  it.each(ROOM_SCOPED)(
    "rejects %s in MAC_SPACE with a non-null worldline_id",
    (op, entityType, extra) => {
      expect(() =>
        parseOperationRequest(build(op, entityType, extra, "MAC_SPACE", WORLDLINE)),
      ).toThrowError("VALIDATION_FAILED");
    },
  );

  it.each(ROOM_SCOPED)(
    "rejects %s in TABLET_SPACE with a non-null worldline_id",
    (op, entityType, extra) => {
      expect(() =>
        parseOperationRequest(build(op, entityType, extra, "TABLET_SPACE", WORLDLINE)),
      ).toThrowError("VALIDATION_FAILED");
    },
  );

  it.each(ROOM_SCOPED)("accepts %s in MAC_SPACE with a null worldline_id", (op, entityType, extra) => {
    const parsed = parseOperationRequest(build(op, entityType, extra, "MAC_SPACE", null));
    expect(parsed.target.worldline_id).toBeNull();
    expect(parsed.worldline_key).toBe("");
  });

  it.each(ROOM_SCOPED)(
    "accepts %s in TABLET_SPACE with a null worldline_id",
    (op, entityType, extra) => {
      expect(parseOperationRequest(build(op, entityType, extra, "TABLET_SPACE", null)).worldline_key).toBe(
        "",
      );
    },
  );

  it.each(WORLDLINE_NULLABLE)(
    "accepts %s in PHONE_SPACE with a non-null worldline_id",
    (op, entityType, extra) => {
      const parsed = parseOperationRequest(build(op, entityType, extra, "PHONE_SPACE", WORLDLINE));
      expect(parsed.target.worldline_id).toBe(WORLDLINE);
      expect(parsed.worldline_key).toBe(WORLDLINE);
    },
  );

  it("applies the same rule to the schema-only delete_turn shape", () => {
    // delete_turn is refused by the runtime gate regardless; this pins that its
    // entity shape still treats worldline_id as nullable, not required.
    expect(getEntityShape("turn").worldlineRule).toBe("nullable");
  });
});

describe("parseOperationRequest — room targets are worldline null-only", () => {
  // A room's D1 identity is (account_id, space_id, room_id): there is no
  // worldline axis. Accepting a non-null worldline_id would let one physical
  // row be addressed two ways and would produce a change_log identity the
  // 0008 room CHECK forbids (worldline_key must be NULL). This is the same
  // ambiguity §4.1.2 closed for group_state, but room keeps the explicit
  // `null` key so the wire shape and the §4.1 example stay unchanged.
  function roomTarget(op: string, worldline: unknown, omit = false): Record<string, unknown> {
    const target: Record<string, unknown> = { space_id: "PHONE_SPACE", room_id: ROOM };
    if (!omit) {
      target["worldline_id"] = worldline;
    }
    return makeOperation({
      op,
      entity_type: "room",
      target,
      base_revision: op === "patch_room" ? 41 : undefined,
      set: { title: validEnvelope() },
    });
  }

  it.each(["create_room", "patch_room"])("declares %s's entity shape as null-only", () => {
    expect(getEntityShape("room").worldlineRule).toBe("null-only");
  });

  it.each(["create_room", "patch_room"])(
    "rejects a non-null worldline_id on %s even in PHONE_SPACE",
    (op) => {
      expect(() => parseOperationRequest(roomTarget(op, WORLDLINE))).toThrowError("VALIDATION_FAILED");
    },
  );

  it.each(["create_room", "patch_room"])("still requires the explicit key on %s", (op) => {
    expect(() => parseOperationRequest(roomTarget(op, null, true))).toThrowError("VALIDATION_FAILED");
  });

  it.each(["create_room", "patch_room"])("still accepts an explicit null on %s", (op) => {
    const parsed = parseOperationRequest(roomTarget(op, null));
    expect(parsed.target.worldline_id).toBeNull();
    expect(parsed.worldline_key).toBe("");
  });

  it("leaves the other worldline rules untouched", () => {
    expect(getEntityShape("group_state").worldlineRule).toBe("absent");
    expect(getEntityShape("worldline").worldlineRule).toBe("required");
    for (const entity of ["checkpoint", "turn", "bubble"] as const) {
      expect(getEntityShape(entity).worldlineRule).toBe("nullable");
    }
  });
});

describe("parseOperationRequest — safe integers", () => {
  it("rejects a numeric string as bubble_order", () => {
    // D1's INTEGER affinity would convert "3" to 3 before any CHECK could see
    // it, so the wire boundary is the only place this can be refused.
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
          bubble_order: "3",
          set: { text: validEnvelope() },
        }),
      ),
    ).toThrowError("VALIDATION_FAILED");
  });

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
          // The create now carries the head CAS: 0 → 1 for a first snapshot.
          base_revision: 0,
          target: {
            space_id: "PHONE_SPACE",
            persona_snapshot_id: PERSONA_SNAPSHOT,
            snapshot_revision: 1,
          },
          set: { description: validEnvelope() },
          metadata_set: PERSONA_CREATE_METADATA,
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
          metadata_set: checkpointCreateMetadata("MAC_SPACE"),
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
          // The create now declares its whole plaintext and encrypted shape.
          set: {
            file_name: validEnvelope(),
            mime_type: validEnvelope(),
            wrapped_file_key: validEnvelope(),
          },
          metadata_set: {
            origin_space_id: "MAC_SPACE",
            kind: "attachment",
            source_byte_size: 1024,
            ciphertext_byte_size: 1058,
            ciphertext_hash: "c".repeat(64),
            key_generation: 1,
            created_at: "2026-08-28T00:00:00Z",
          },
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
            target: { space_id: space, room_id: ROOM },
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

  it("accepts group_state inside PHONE_SPACE without any worldline_id", () => {
    expect(() =>
      parseOperationRequest(
        makeOperation({
          op: "patch_group_state",
          entity_type: "group_state",
          target: { space_id: "PHONE_SPACE", room_id: ROOM },
        }),
      ),
    ).not.toThrow();
  });
});

describe("R1 — group_state identity has no worldline dimension", () => {
  it("declares group_state as worldline-absent", () => {
    expect(getEntityShape("group_state").worldlineRule).toBe("absent");
  });

  it.each(["create_group_state", "patch_group_state"])(
    "rejects %s when worldline_id is present at all",
    (op) => {
      // A group_state row is room-level: (account_id, PHONE_SPACE, room_id).
      // Allowing worldline_id would let the same row be addressed by two
      // different targets (null vs a UUID), so the handler could not tell
      // which value belongs to the identity.
      for (const worldlineId of [null, WORLDLINE]) {
        expect(() =>
          parseOperationRequest(
            makeOperation({
              op,
              entity_type: "group_state",
              base_revision: op.startsWith("patch") ? 1 : undefined,
              target: { space_id: "PHONE_SPACE", room_id: ROOM, worldline_id: worldlineId },
            }),
          ),
        ).toThrowError("VALIDATION_FAILED");
      }
    },
  );

  it("accepts create_group_state with only space_id and room_id", () => {
    expect(() =>
      parseOperationRequest(
        makeOperation({
          op: "create_group_state",
          entity_type: "group_state",
          base_revision: undefined,
          target: { space_id: "PHONE_SPACE", room_id: ROOM },
        }),
      ),
    ).not.toThrow();
  });

  it("derives an empty worldline_key for group_state", () => {
    const parsed = parseOperationRequest(
      makeOperation({
        op: "patch_group_state",
        entity_type: "group_state",
        target: { space_id: "PHONE_SPACE", room_id: ROOM },
      }),
    );
    expect(parsed.worldline_key).toBe("");
    expect(parsed.target.worldline_id).toBeUndefined();
  });

  it("keeps worldline entities worldline-scoped (contrast with group_state)", () => {
    expect(getEntityShape("worldline").worldlineRule).toBe("required");
  });
});

describe("R2 — canonical Base64 rejects non-zero padding bits", () => {
  it("rejects a two-pad string whose unused bits are not zero", () => {
    // "QQ==" decodes to 0x41. "QR==" decodes to the same byte because the
    // trailing 4 bits of 'R' are discarded, so both are the same value but
    // only "QQ==" is the canonical spelling.
    expect(atob("QQ==")).toBe(atob("QR=="));
    expect(isCanonicalBase64("QQ==")).toBe(true);
    expect(isCanonicalBase64("QR==")).toBe(false);
  });

  it("rejects a one-pad string whose unused bits are not zero", () => {
    // "QUJ=" vs "QUI=": the last 2 bits of the third character are unused.
    expect(atob("QUI=")).toBe(atob("QUJ="));
    expect(isCanonicalBase64("QUI=")).toBe(true);
    expect(isCanonicalBase64("QUJ=")).toBe(false);
  });

  it("accepts every canonical re-encoding round trip", () => {
    for (let length = 1; length <= 32; length += 1) {
      const bytes = new Uint8Array(length);
      for (let index = 0; index < length; index += 1) {
        bytes[index] = (index * 7 + 3) & 0xff;
      }
      let binary = "";
      for (const byte of bytes) binary += String.fromCharCode(byte);
      const encoded = btoa(binary);
      expect(isCanonicalBase64(encoded)).toBe(true);
    }
  });

  it("rejects a non-canonical envelope at the operation boundary", () => {
    // Build a valid 34-byte envelope, then corrupt only its padding bits.
    const canonical = validEnvelope(16);
    expect(isCanonicalBase64(canonical)).toBe(true);
    const decoded = decodeCanonicalBase64(canonical);
    expect(decoded.length).toBe(34);
    // 34 bytes -> 2 leftover bytes -> one '=' of padding, so the character
    // before the pad carries unused bits we can flip.
    expect(canonical.endsWith("=")).toBe(true);
    const padIndex = canonical.indexOf("=");
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const lastChar = canonical[padIndex - 1] as string;
    const lastValue = alphabet.indexOf(lastChar);
    // Set a bit that decoding discards; the byte output is unchanged.
    const corruptedValue = lastValue | 0b000001;
    const corrupted =
      canonical.slice(0, padIndex - 1) +
      (alphabet[corruptedValue] as string) +
      canonical.slice(padIndex);
    if (corrupted !== canonical) {
      expect(atob(corrupted)).toBe(atob(canonical));
      expect(isCanonicalBase64(corrupted)).toBe(false);
      expect(() =>
        parseOperationRequest(makeOperation({ set: { status_message: corrupted } })),
      ).toThrowError("VALIDATION_FAILED");
    }
  });
});

describe("R3 — operation table is exported read-only for handlers", () => {
  it("derives schema and runtime operation lists from one source", () => {
    expect(SCHEMA_OPERATIONS.length).toBe(16);
    expect(RUNTIME_ENABLED_OPERATIONS.length).toBe(15);
    // Runtime is a strict subset of schema, differing only by delete_turn.
    for (const op of RUNTIME_ENABLED_OPERATIONS) {
      expect(SCHEMA_OPERATIONS as readonly string[]).toContain(op);
    }
    const missing = (SCHEMA_OPERATIONS as readonly string[]).filter(
      (op) => !(RUNTIME_ENABLED_OPERATIONS as readonly string[]).includes(op),
    );
    expect(missing).toEqual(["delete_turn"]);
  });

  it("exposes every schema operation through the accessor", () => {
    for (const op of SCHEMA_OPERATIONS) {
      const spec = getOperationSpec(op);
      expect(spec.entityType).toBeTruthy();
      expect(["create", "patch", "delete"]).toContain(spec.kind);
      // Every operation's entity must resolve to a declared shape.
      expect(getEntityShape(spec.entityType).required.length).toBeGreaterThan(0);
    }
  });

  it("reports phone-space restriction through the accessor", () => {
    for (const op of ["create_group_state", "patch_group_state", "create_worldline", "patch_worldline"] as const) {
      expect(getOperationSpec(op).phoneSpaceOnly).toBe(true);
    }
    for (const op of ["patch_room", "create_attachment", "create_turn"] as const) {
      expect(getOperationSpec(op).phoneSpaceOnly).toBe(false);
    }
  });

  it("rejects an unknown operation name through the accessor", () => {
    expect(() => getOperationSpec("not_an_operation" as never)).toThrowError("VALIDATION_FAILED");
    expect(() => getEntityShape("not_an_entity" as never)).toThrowError("VALIDATION_FAILED");
  });

  it("provides membership predicates that agree with the lists", () => {
    expect(isSchemaOperation("delete_turn")).toBe(true);
    expect(isRuntimeEnabledOperation("delete_turn")).toBe(false);
    expect(isSchemaOperation("patch_room")).toBe(true);
    expect(isRuntimeEnabledOperation("patch_room")).toBe(true);
    expect(isSchemaOperation("delete_bubble")).toBe(false);
    expect(isRuntimeEnabledOperation("delete_bubble")).toBe(false);
  });

  it("hands out frozen structures that a handler cannot mutate", () => {
    const spec = getOperationSpec("patch_room");
    expect(Object.isFrozen(spec)).toBe(true);
    const shape = getEntityShape("room");
    expect(Object.isFrozen(shape)).toBe(true);
    expect(Object.isFrozen(shape.required)).toBe(true);
    expect(Object.isFrozen(SCHEMA_OPERATIONS)).toBe(true);
    expect(Object.isFrozen(RUNTIME_ENABLED_OPERATIONS)).toBe(true);
    // A handler that tries to widen a rule must not affect the validator.
    expect(() => {
      (spec as { phoneSpaceOnly: boolean }).phoneSpaceOnly = true;
    }).toThrowError();
    expect(getOperationSpec("patch_room").phoneSpaceOnly).toBe(false);
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
