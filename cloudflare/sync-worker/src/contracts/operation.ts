import { ApiError, validationFailed } from "./error";
import {
  decodeCanonicalBase64,
  isCanonicalBase64,
  requireNullableWorldlineId,
  requireRfc3339Utc,
  requireSafeInteger,
  requireSpaceId,
  requireUuid,
  worldlineKey,
} from "./identity";
import { EXTENSION_KEY_PATTERN } from "./identity";
import type { SpaceId } from "./identity";

export { worldlineKey };

/** API draft §2.1 — exact byte bounds, not approximations. */
export const MAX_OPERATION_BODY_BYTES = 2_000_000;
export const MAX_FIELD_ENVELOPE_BYTES = 1_900_000;

/**
 * Fixed envelope prefix per E2EE proposal §7.1: version(1) + alg(1) +
 * key_generation(4) + nonce(12). A GCM tag is always appended after the
 * ciphertext and is itself 16 bytes, so no valid envelope is ever shorter
 * than 34 bytes even when the plaintext is empty.
 */
const ENVELOPE_PREFIX_BYTES = 1 + 1 + 4 + 12;
const ENVELOPE_MIN_BYTES = ENVELOPE_PREFIX_BYTES + 16;
const SUPPORTED_ENVELOPE_VERSION = 1;
const SUPPORTED_ENVELOPE_ALGORITHM = 1;

// ---------------------------------------------------------------------------
// Operation table — the single source of truth for op/entity/target binding.
//
// `SCHEMA_OPERATIONS` is every operation the canonical schema and Worker API
// draft define. `RUNTIME_ENABLED_OPERATIONS` is the strict subset the v1
// runtime actually accepts today. `delete_turn` is schema-defined (API draft
// §4.1) but withheld from runtime per user decision 15 until edit/delete is
// explicitly enabled — see `docs/2026-08-28-phase1-worker-scaffold-codex-review.md`
// blocker 1. `delete_bubble` is never a schema operation at all.
// ---------------------------------------------------------------------------

type TargetFieldName =
  | "space_id"
  | "room_id"
  | "worldline_id"
  | "turn_id"
  | "message_id"
  | "persona_snapshot_id"
  | "snapshot_revision"
  | "engine_profile_id"
  | "profile_revision"
  | "checkpoint_id"
  | "attachment_id";

type WorldlineRule =
  | "nullable" // conversation-scope entities: null means the default worldline
  | "null-only" // the key is required and must be null: room has no worldline axis
  | "required" // the target IS a specific worldline; null is meaningless here
  | "absent"; // the entity's D1 key has no worldline component at all

interface EntityShape {
  /** Fields every target of this entity must carry (beyond `space_id`). */
  readonly required: readonly TargetFieldName[];
  readonly worldlineRule: WorldlineRule;
  /** Whether `room_id` is part of this entity's identity. */
  readonly roomScoped: boolean;
  /**
   * Whether this entity has an extension table to store an
   * `extensions.<owner>.<entity>.<field>` envelope in (canonical schema §3.3).
   * Only four entities do. An extension path on any other entity has nowhere
   * to go, so it is refused here rather than dropped by a handler.
   */
  readonly allowsExtensions: boolean;
}

const ENTITY_SHAPES = {
  // A room's D1 identity is (account_id, space_id, room_id) — no worldline
  // column. The key stays on the wire so the shape matches the other
  // room-scoped targets, but a non-null value would address one physical row
  // two ways and could not be written to change_log, whose room branch
  // requires worldline_key IS NULL (migration 0008).
  room: {
    required: ["room_id"],
    worldlineRule: "null-only",
    roomScoped: true,
    allowsExtensions: true,
  },
  persona_snapshot: {
    required: ["persona_snapshot_id", "snapshot_revision"],
    worldlineRule: "absent",
    roomScoped: false,
    allowsExtensions: true,
  },
  engine_profile: {
    required: ["engine_profile_id", "profile_revision"],
    worldlineRule: "absent",
    roomScoped: false,
    allowsExtensions: false,
  },
  checkpoint: {
    required: ["room_id", "checkpoint_id"],
    worldlineRule: "nullable",
    roomScoped: true,
    allowsExtensions: false,
  },
  turn: {
    required: ["room_id", "turn_id"],
    worldlineRule: "nullable",
    roomScoped: true,
    allowsExtensions: true,
  },
  bubble: {
    required: ["room_id", "turn_id", "message_id"],
    worldlineRule: "nullable",
    roomScoped: true,
    allowsExtensions: true,
  },
  // A group_state row is room-level: its D1 identity is
  // (account_id, PHONE_SPACE, room_id) with no worldline component. The
  // currently selected worldline lives inside the row as the encrypted
  // `active_worldline_id` field, never in the target. Allowing a target
  // `worldline_id` here would let one row be addressed two ways (null vs a
  // UUID) and leave the handler unable to say which belongs to the identity.
  group_state: {
    required: ["room_id"],
    worldlineRule: "absent",
    roomScoped: true,
    allowsExtensions: false,
  },
  worldline: {
    required: ["room_id", "worldline_id"],
    worldlineRule: "required",
    roomScoped: true,
    allowsExtensions: false,
  },
  attachment: {
    required: ["attachment_id"],
    worldlineRule: "absent",
    roomScoped: false,
    allowsExtensions: false,
  },
} as const satisfies Record<string, EntityShape>;

type EntityType = keyof typeof ENTITY_SHAPES;

interface OperationSpec {
  readonly entityType: EntityType;
  readonly kind: "create" | "patch" | "delete";
  readonly phoneSpaceOnly: boolean;
  readonly requiresBubbleOrder: boolean;
}

const OPERATION_SPECS = {
  create_room: { entityType: "room", kind: "create", phoneSpaceOnly: false, requiresBubbleOrder: false },
  patch_room: { entityType: "room", kind: "patch", phoneSpaceOnly: false, requiresBubbleOrder: false },
  create_persona_snapshot: {
    entityType: "persona_snapshot",
    kind: "create",
    phoneSpaceOnly: false,
    requiresBubbleOrder: false,
  },
  create_engine_profile: {
    entityType: "engine_profile",
    kind: "create",
    phoneSpaceOnly: false,
    requiresBubbleOrder: false,
  },
  create_checkpoint: {
    entityType: "checkpoint",
    kind: "create",
    phoneSpaceOnly: false,
    requiresBubbleOrder: false,
  },
  patch_checkpoint: {
    entityType: "checkpoint",
    kind: "patch",
    phoneSpaceOnly: false,
    requiresBubbleOrder: false,
  },
  create_turn: { entityType: "turn", kind: "create", phoneSpaceOnly: false, requiresBubbleOrder: false },
  patch_turn: { entityType: "turn", kind: "patch", phoneSpaceOnly: false, requiresBubbleOrder: false },
  create_bubble: { entityType: "bubble", kind: "create", phoneSpaceOnly: false, requiresBubbleOrder: true },
  patch_bubble: { entityType: "bubble", kind: "patch", phoneSpaceOnly: false, requiresBubbleOrder: false },
  create_group_state: {
    entityType: "group_state",
    kind: "create",
    phoneSpaceOnly: true,
    requiresBubbleOrder: false,
  },
  patch_group_state: {
    entityType: "group_state",
    kind: "patch",
    phoneSpaceOnly: true,
    requiresBubbleOrder: false,
  },
  create_worldline: {
    entityType: "worldline",
    kind: "create",
    phoneSpaceOnly: true,
    requiresBubbleOrder: false,
  },
  patch_worldline: {
    entityType: "worldline",
    kind: "patch",
    phoneSpaceOnly: true,
    requiresBubbleOrder: false,
  },
  create_attachment: {
    entityType: "attachment",
    kind: "create",
    phoneSpaceOnly: false,
    requiresBubbleOrder: false,
  },
  delete_turn: { entityType: "turn", kind: "delete", phoneSpaceOnly: false, requiresBubbleOrder: false },
} as const satisfies Record<string, OperationSpec>;

export type OperationName = keyof typeof OPERATION_SPECS;

export type { EntityType };

/**
 * Freeze a table and the arrays inside it so a downstream handler cannot
 * widen a rule at runtime. `as const` is a compile-time guarantee only; a
 * D1 handler reached through `getOperationSpec()` would otherwise be able to
 * flip `phoneSpaceOnly` on the very object the validator consults.
 */
function deepFreezeTable<T extends Record<string, Record<string, unknown>>>(table: T): T {
  for (const entry of Object.values(table)) {
    for (const value of Object.values(entry)) {
      if (Array.isArray(value)) {
        Object.freeze(value);
      }
    }
    Object.freeze(entry);
  }
  return Object.freeze(table);
}

deepFreezeTable(ENTITY_SHAPES as unknown as Record<string, Record<string, unknown>>);
deepFreezeTable(OPERATION_SPECS as unknown as Record<string, Record<string, unknown>>);

/**
 * Every operation the schema defines, including ones withheld at runtime.
 *
 * This and `RUNTIME_ENABLED_OPERATIONS` are both derived from
 * `OPERATION_SPECS`, so the two lists cannot drift apart.
 */
export const SCHEMA_OPERATIONS: readonly OperationName[] = Object.freeze(
  Object.keys(OPERATION_SPECS) as OperationName[],
);

/**
 * Operations the v1 runtime actually accepts. `delete_turn` is schema-defined
 * but refused until the delete feature flag opens (user decision 15).
 */
export const RUNTIME_ENABLED_OPERATIONS: readonly OperationName[] = Object.freeze(
  SCHEMA_OPERATIONS.filter((op) => op !== "delete_turn"),
);

const SCHEMA_OPERATION_SET: ReadonlySet<string> = new Set(SCHEMA_OPERATIONS);
const RUNTIME_OPERATION_SET: ReadonlySet<string> = new Set(RUNTIME_ENABLED_OPERATIONS);

export function isSchemaOperation(value: unknown): value is OperationName {
  return typeof value === "string" && SCHEMA_OPERATION_SET.has(value);
}

export function isRuntimeEnabledOperation(value: unknown): value is OperationName {
  return typeof value === "string" && RUNTIME_OPERATION_SET.has(value);
}

/**
 * Read-only accessor for the operation rule table.
 *
 * The D1 handler layer resolves an already-validated operation's entity type,
 * kind, and scope restriction through this instead of re-declaring the rules,
 * so there is exactly one source for the contract. The returned object is
 * frozen.
 */
export function getOperationSpec(op: OperationName): Readonly<OperationSpec> {
  if (!isSchemaOperation(op)) {
    throw validationFailed();
  }
  return OPERATION_SPECS[op];
}

/**
 * Read-only accessor for an entity's target shape: which identity fields the
 * target must carry and how it treats `worldline_id`. Frozen, same reason.
 */
export function getEntityShape(entityType: EntityType): Readonly<EntityShape> {
  if (!Object.prototype.hasOwnProperty.call(ENTITY_SHAPES, entityType)) {
    throw validationFailed();
  }
  return ENTITY_SHAPES[entityType];
}

const PATCH_KINDS = new Set(["patch", "delete"]);

const ALLOWED_TOP_LEVEL_FIELDS = new Set([
  "protocol_version",
  "operation_id",
  "device_id",
  "op",
  "entity_type",
  "target",
  "base_revision",
  "set",
  "clear",
  "created_at",
  "bubble_order",
  "metadata_set",
  "metadata_clear",
]);

// ---------------------------------------------------------------------------
// Plaintext metadata patch — API draft §4.1.0.
//
// `set`/`clear` carry encrypted envelopes and extension keys. The canonical
// metadata D1 must read as identity, foreign key or range cannot be ciphertext,
// so it travels here instead, under a per-operation allowlist with a typed
// parser for every key. Both fields are always present; an operation that
// changes no metadata still spells `{}` and `[]`.
//
// An operation absent from this table allows no metadata at all. The M03
// entities are deliberately left empty: their plaintext columns are set at
// create time by the handler, and inventing a patch surface for them here
// would be a contract this project has not written down.
// ---------------------------------------------------------------------------

type MetadataValue = string | number;

function requireRevisionAtLeastOne(value: unknown): number {
  const revision = requireSafeInteger(value);
  if (revision < 1) {
    // A version chain starts at 1; revision 0 means "no revision yet", which
    // is a head state, never a row.
    throw validationFailed();
  }
  return revision;
}

/** Canonical schema §7.2: source ≤ 12,582,912 and ciphertext = source + 34. */
export const MAX_ATTACHMENT_SOURCE_BYTES = 12_582_912;
export const ATTACHMENT_ENVELOPE_OVERHEAD_BYTES = 34;
export const MAX_ENCRYPTED_OBJECT_BYTES =
  MAX_ATTACHMENT_SOURCE_BYTES + ATTACHMENT_ENVELOPE_OVERHEAD_BYTES;

function requireAttachmentKind(value: unknown): string {
  if (value !== "attachment" && value !== "avatar") {
    throw validationFailed();
  }
  return value;
}

function requireSourceByteSize(value: unknown): number {
  const size = requireSafeInteger(value);
  if (size < 1 || size > MAX_ATTACHMENT_SOURCE_BYTES) {
    throw validationFailed();
  }
  return size;
}

function requireCiphertextByteSize(value: unknown): number {
  const size = requireSafeInteger(value);
  // The equality against source_byte_size is checked once both are parsed;
  // here only the absolute ceiling and the floor of a one-byte payload.
  if (size < 1 + ATTACHMENT_ENVELOPE_OVERHEAD_BYTES || size > MAX_ENCRYPTED_OBJECT_BYTES) {
    throw validationFailed();
  }
  return size;
}

function requireSha256Hex(value: unknown): string {
  // Lowercase hex, exactly 64 characters. The Worker never recomputes this and
  // never treats it as authenticity — the AEAD tag is what proves that, and
  // only the downloading client checks it.
  if (typeof value !== "string" || !/^[0-9a-f]{64}$/.test(value)) {
    throw validationFailed();
  }
  return value;
}

function requireKeyGenerationOne(value: unknown): number {
  if (value !== 1) {
    throw validationFailed();
  }
  return value;
}

function requirePlaintextTag(value: unknown): string {
  // A compat tag is compared for equality and never parsed, so the only rule
  // is that it is a non-empty string of bounded length. No format is imposed.
  if (typeof value !== "string" || value.length === 0 || value.length > 256) {
    throw validationFailed();
  }
  return value;
}

/** A byte count copied from an attachment row: 0 is legal, negatives are not. */
function requireNonNegativeSafeInteger(value: unknown): number {
  const parsed = requireSafeInteger(value);
  if (parsed < 0) {
    throw validationFailed();
  }
  return parsed;
}

const METADATA_PARSERS = {
  engine_profile_id: requireUuid,
  engine_profile_revision: requireRevisionAtLeastOne,
  persona_snapshot_id: requireUuid,
  persona_snapshot_revision: requireRevisionAtLeastOne,
  owner_space_id: requireSpaceId,
  // An attachment records where it was created; unlike owner_space_id this one
  // is provenance only and never enters a key (canonical schema §7.1).
  origin_space_id: requireSpaceId,
  created_by_device_id: requireUuid,
  created_at: requireRfc3339Utc,
  persona_schema_version: requireRevisionAtLeastOne,
  checkpoint_schema_version: requireRevisionAtLeastOne,
  compaction_compat_tag: requirePlaintextTag,
  first_turn_id: requireUuid,
  last_turn_id: requireUuid,
  through_server_seq: requireRevisionAtLeastOne,
  kind: requireAttachmentKind,
  source_byte_size: requireSourceByteSize,
  ciphertext_byte_size: requireCiphertextByteSize,
  ciphertext_hash: requireSha256Hex,
  key_generation: requireKeyGenerationOne,
  // A bubble's own plaintext time, not the sync request's: last_message_time is
  // the maximum of these (E2EE proposal §8.5).
  timestamp: requireRfc3339Utc,
  attachment_ref_attachment_id: requireUuid,
  attachment_ref_byte_size: requireNonNegativeSafeInteger,
} as const satisfies Record<string, (value: unknown) => MetadataValue>;

type MetadataField = keyof typeof METADATA_PARSERS;

/** Fields that are only ever written or cleared together. */
const METADATA_PAIRS: readonly (readonly [MetadataField, MetadataField])[] = [
  ["engine_profile_id", "engine_profile_revision"],
  ["persona_snapshot_id", "persona_snapshot_revision"],
  ["first_turn_id", "last_turn_id"],
  ["attachment_ref_attachment_id", "attachment_ref_byte_size"],
];

interface MetadataRule {
  /** Must be present in `metadata_set`; a create without one is incomplete. */
  readonly required: readonly MetadataField[];
  /** May be present in `metadata_set`. */
  readonly optional: readonly MetadataField[];
  /** May appear in `metadata_clear`. Empty for every create. */
  readonly clearable: readonly MetadataField[];
}

const ROOM_REFERENCE_FIELDS = [
  "engine_profile_id",
  "engine_profile_revision",
  "persona_snapshot_id",
  "persona_snapshot_revision",
] as const;

// The three creation-provenance fields. They appear in create_checkpoint's
// required set and in neither half of patch_checkpoint: who created a
// checkpoint and when is not something a later patch may rewrite or erase.
const CHECKPOINT_PROVENANCE = ["owner_space_id", "created_by_device_id", "created_at"] as const;

const CHECKPOINT_PATCHABLE = [
  "first_turn_id",
  "last_turn_id",
  "through_server_seq",
  "checkpoint_schema_version",
  "compaction_compat_tag",
] as const;

// D1's checkpoint.checkpoint_schema_version is NOT NULL, so clearing it has no
// legal outcome: it would pass validation and then abort inside the batch as an
// opaque storage failure the handler could not tell apart from a real fault.
// Setting a new version stays allowed; only the clear is refused.
const CHECKPOINT_CLEARABLE = CHECKPOINT_PATCHABLE.filter(
  (field) => field !== "checkpoint_schema_version",
);

const METADATA_RULES: Partial<Record<string, MetadataRule>> = {
  create_room: {
    required: [],
    optional: ["origin_space_id"],
    clearable: [],
  },
  patch_room: {
    required: [],
    optional: ROOM_REFERENCE_FIELDS,
    clearable: ROOM_REFERENCE_FIELDS,
  },
  create_engine_profile: {
    required: [],
    optional: ["compaction_compat_tag"],
    clearable: [],
  },
  create_persona_snapshot: {
    required: [
      "owner_space_id",
      "created_by_device_id",
      "created_at",
      "persona_schema_version",
    ],
    optional: [],
    clearable: [],
  },
  create_checkpoint: {
    required: ["checkpoint_schema_version", ...CHECKPOINT_PROVENANCE],
    optional: ["first_turn_id", "last_turn_id", "through_server_seq", "compaction_compat_tag"],
    clearable: [],
  },
  patch_checkpoint: {
    required: [],
    optional: CHECKPOINT_PATCHABLE,
    clearable: CHECKPOINT_CLEARABLE,
  },
  // A turn records which device produced it and when. Both columns are NOT
  // NULL in D1 and neither is derivable from the request envelope, so they
  // travel as explicit metadata rather than being inferred.
  create_turn: {
    required: ["created_by_device_id", "created_at"],
    optional: [],
    clearable: [],
  },
  // `timestamp` is the bubble's own time. The attachment pair is optional and
  // moves together: a size without an ID names nothing, and an ID without a
  // size cannot be checked against the stored ciphertext.
  create_bubble: {
    required: ["timestamp"],
    optional: ["attachment_ref_attachment_id", "attachment_ref_byte_size"],
    clearable: [],
  },
};

const EMPTY_METADATA_RULE: MetadataRule = { required: [], optional: [], clearable: [] };

// create_attachment declares its whole plaintext shape at allocation time. The
// server owns r2_object_key, the initial `allocated` state and server_seq, so
// none of the three is in this list and any of them on the wire is refused as
// an unknown key.
METADATA_RULES.create_attachment = {
  required: [
    "origin_space_id",
    "kind",
    "source_byte_size",
    "ciphertext_byte_size",
    "ciphertext_hash",
    "key_generation",
    "created_at",
  ],
  optional: [],
  clearable: [],
};

/**
 * Operations whose encrypted `set` is a fixed, complete field list rather than
 * a patch. An attachment's name, type and wrapped key are written once at
 * creation; a missing one would leave a row that can never be decrypted.
 */
/**
 * Creates that record creation provenance in plaintext metadata. Both fields
 * must agree with the request itself; see the check in
 * `parseOperationRequest`.
 */
const PROVENANCE_CREATES: ReadonlySet<string> = new Set([
  "create_persona_snapshot",
  "create_checkpoint",
]);

/**
 * Creates that name the device that made the row. A turn has no
 * `owner_space_id` — its space comes from the target — but the device claim
 * must still be the requesting device's own.
 */
const DEVICE_PROVENANCE_CREATES: ReadonlySet<string> = new Set([
  "create_persona_snapshot",
  "create_checkpoint",
  "create_turn",
]);

const REQUIRED_ENCRYPTED_FIELDS: Partial<Record<string, readonly string[]>> = {
  create_attachment: ["file_name", "mime_type", "wrapped_file_key"],
};

export interface OperationTarget {
  space_id: SpaceId;
  room_id?: string;
  worldline_id?: string | null;
  turn_id?: string;
  message_id?: string;
  persona_snapshot_id?: string;
  snapshot_revision?: number;
  engine_profile_id?: string;
  profile_revision?: number;
  checkpoint_id?: string;
  attachment_id?: string;
}

export interface OperationRequest {
  protocol_version: 1;
  operation_id: string;
  device_id: string;
  op: OperationName;
  entity_type: EntityType;
  target: OperationTarget;
  worldline_key: string;
  metadata_set: Record<string, MetadataValue>;
  metadata_clear: string[];
  base_revision?: number;
  bubble_order?: number;
  set: Record<string, string>;
  clear: string[];
  created_at: string;
}

export function normalizeRoomOrigin(targetSpace: SpaceId, supplied?: SpaceId): SpaceId {
  return supplied ?? targetSpace;
}

export function roomOriginAllowsWriter(origin: SpaceId, writer: SpaceId): boolean {
  if (origin === "PHONE_SPACE") return writer === "PHONE_SPACE";
  if (origin === "MAC_SPACE") return writer === "MAC_SPACE" || writer === "PHONE_SPACE";
  return writer === "TABLET_SPACE" || writer === "MAC_SPACE" || writer === "PHONE_SPACE";
}

/**
 * Reject an oversized request before parsing. API draft §2.1.
 *
 * The bound is inclusive: exactly `MAX_OPERATION_BODY_BYTES` is accepted.
 */
export function assertOperationBodySize(byteLength: number): void {
  if (!Number.isInteger(byteLength) || byteLength < 0) {
    throw validationFailed();
  }
  if (byteLength > MAX_OPERATION_BODY_BYTES) {
    throw new ApiError("REQUEST_TOO_LARGE");
  }
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/**
 * Canonical wire field paths use the plain name; `_enc` is a D1 column
 * suffix only (draft §0.2). Extension paths are `extensions.<owner>.<entity>.<field>`.
 */
function assertCanonicalFieldPath(
  path: string,
  allowsExtensions: boolean,
  plaintextNames: ReadonlySet<string>,
): void {
  if (path.length === 0 || path.endsWith("_enc")) {
    throw validationFailed();
  }
  if (path.startsWith("extensions.")) {
    if (!allowsExtensions) {
      // No extension table owns this entity, so there is no row to write.
      throw validationFailed();
    }
    const key = path.slice("extensions.".length);
    if (!EXTENSION_KEY_PATTERN.test(key)) {
      throw validationFailed();
    }
    return;
  }
  if (!/^[a-z][a-z0-9_]*$/.test(path)) {
    throw validationFailed();
  }
  if (plaintextNames.has(path)) {
    // A plaintext metadata field never travels as ciphertext for the same
    // operation: that would give one canonical fact two wire paths, one of
    // which D1 could not read. The set is per-operation, because the same
    // word can name plaintext metadata on one entity and an encrypted field
    // on another — `kind` is attachment metadata and a bubble's own
    // encrypted field (canonical §3.4, §7.1).
    throw validationFailed();
  }
}

/**
 * Verify one `set` value is a real field envelope: canonical padded Base64,
 * a decoded length of at least 34 bytes, and a supported version/algorithm
 * byte. This closes the gap where any string of the right JS `.length` was
 * accepted as ciphertext.
 */
function assertFieldEnvelope(value: unknown): asserts value is string {
  if (typeof value !== "string") {
    throw validationFailed();
  }
  // The field-size bound is checked on the wire (Base64) length, which for a
  // canonical-charset string equals its byte length.
  if (value.length > MAX_FIELD_ENVELOPE_BYTES) {
    throw new ApiError("REQUEST_TOO_LARGE");
  }
  if (!isCanonicalBase64(value)) {
    throw validationFailed();
  }
  const decoded = decodeCanonicalBase64(value);
  if (decoded.length < ENVELOPE_MIN_BYTES) {
    throw validationFailed();
  }
  if (decoded[0] !== SUPPORTED_ENVELOPE_VERSION) {
    throw validationFailed();
  }
  if (decoded[1] !== SUPPORTED_ENVELOPE_ALGORITHM) {
    throw validationFailed();
  }
}

const TARGET_FIELD_PARSERS: Record<
  Exclude<TargetFieldName, "space_id">,
  (value: unknown) => string | number
> = {
  room_id: requireUuid,
  worldline_id: (value) => requireNullableWorldlineId(value) as unknown as string,
  turn_id: requireUuid,
  message_id: requireUuid,
  persona_snapshot_id: requireUuid,
  snapshot_revision: requireSafeInteger,
  engine_profile_id: requireUuid,
  profile_revision: requireSafeInteger,
  checkpoint_id: requireUuid,
  attachment_id: requireUuid,
};

function parseTarget(value: unknown, entityType: EntityType): OperationTarget {
  if (!isPlainObject(value)) {
    throw validationFailed();
  }

  const shape = ENTITY_SHAPES[entityType];
  const allowed = new Set<TargetFieldName>(["space_id", ...shape.required]);
  if (shape.worldlineRule !== "absent") {
    allowed.add("worldline_id");
  }

  for (const key of Object.keys(value)) {
    if (!allowed.has(key as TargetFieldName)) {
      // A field that belongs to a *different* entity (or none) is rejected
      // here, not silently ignored — this is what stops a persona_snapshot_id
      // or turn_id from leaking into a room target.
      throw validationFailed();
    }
  }

  const target: OperationTarget = { space_id: requireSpaceId(value["space_id"]) };

  for (const field of shape.required) {
    if (!(field in value)) {
      throw validationFailed();
    }
    const parser = TARGET_FIELD_PARSERS[field as Exclude<TargetFieldName, "space_id">];
    (target as unknown as Record<string, unknown>)[field] = parser(value[field]);
  }

  if (shape.worldlineRule === "absent") {
    if ("worldline_id" in value) {
      throw validationFailed();
    }
  } else {
    if (!("worldline_id" in value)) {
      // An absent key is ambiguous between "default worldline" and
      // "forgot to specify"; the wire always spells `null` explicitly.
      throw validationFailed();
    }
    const worldlineId = requireNullableWorldlineId(value["worldline_id"]);
    if (shape.worldlineRule === "null-only" && worldlineId !== null) {
      throw validationFailed();
    }
    if (shape.worldlineRule === "required" && worldlineId === null) {
      // A worldline operation addresses a specific worldline row; there is
      // no such thing as creating or patching "the null worldline".
      throw validationFailed();
    }
    if (worldlineId !== null && target.space_id !== "PHONE_SPACE") {
      // A named worldline is a PHONE_SPACE-only entity (canonical schema 11).
      // The null default scope stays legal in every canonical space, so this
      // is narrower than `phoneSpaceOnly`, which bans the whole operation.
      // `worldline` operations are already phoneSpaceOnly, so this is the rule
      // that covers room, checkpoint, turn and bubble targets.
      throw validationFailed();
    }
    target.worldline_id = worldlineId;
  }

  return target;
}

function parseMetadata(
  setValue: unknown,
  clearValue: unknown,
  operation: OperationName,
): { set: Record<string, MetadataValue>; clear: string[] } {
  if (!isPlainObject(setValue) || !Array.isArray(clearValue)) {
    // Both are mandatory and explicit: an absent key would be ambiguous
    // between "no metadata change" and "old client".
    throw validationFailed();
  }
  const rule = METADATA_RULES[operation] ?? EMPTY_METADATA_RULE;
  const settable = new Set<string>([...rule.required, ...rule.optional]);
  const clearable = new Set<string>(rule.clearable);

  const set: Record<string, MetadataValue> = {};
  for (const [key, raw] of Object.entries(setValue)) {
    if (!settable.has(key)) {
      throw validationFailed();
    }
    set[key] = METADATA_PARSERS[key as MetadataField](raw);
  }
  for (const key of rule.required) {
    if (!(key in set)) {
      // A create carries its provenance and schema version or it is not a
      // complete row; the handler must never have to invent one.
      throw validationFailed();
    }
  }

  const clear: string[] = [];
  const seen = new Set<string>();
  for (const key of clearValue) {
    // `clearable` is empty for every create operation, so a non-empty
    // metadata_clear on a create fails here: clearing a field of a row that
    // does not exist yet has no meaning.
    if (typeof key !== "string" || !clearable.has(key) || seen.has(key)) {
      throw validationFailed();
    }
    if (key in set) {
      // The same field cannot be written and cleared by one operation.
      throw validationFailed();
    }
    seen.add(key);
    clear.push(key);
  }

  for (const [left, right] of METADATA_PAIRS) {
    if (!settable.has(left) && !clearable.has(left)) {
      continue;
    }
    // A reference is meaningless as one half: an id without its revision no
    // longer names an exact immutable row.
    if (left in set !== right in set) {
      throw validationFailed();
    }
    if (seen.has(left) !== seen.has(right)) {
      throw validationFailed();
    }
  }

  return { set, clear };
}

function parseSet(
  value: unknown,
  allowsExtensions: boolean,
  plaintextNames: ReadonlySet<string>,
): Record<string, string> {
  if (value === undefined) {
    throw validationFailed();
  }
  if (!isPlainObject(value)) {
    throw validationFailed();
  }
  const result: Record<string, string> = {};
  for (const [path, envelope] of Object.entries(value)) {
    assertCanonicalFieldPath(path, allowsExtensions, plaintextNames);
    assertFieldEnvelope(envelope);
    result[path] = envelope;
  }
  return result;
}

function parseClear(
  value: unknown,
  setPaths: Set<string>,
  allowsExtensions: boolean,
  plaintextNames: ReadonlySet<string>,
): string[] {
  if (!Array.isArray(value)) {
    throw validationFailed();
  }
  const seen = new Set<string>();
  for (const path of value) {
    if (typeof path !== "string") {
      throw validationFailed();
    }
    assertCanonicalFieldPath(path, allowsExtensions, plaintextNames);
    if (seen.has(path)) {
      throw validationFailed();
    }
    // A path cannot be both written and cleared in one operation.
    if (setPaths.has(path)) {
      throw validationFailed();
    }
    seen.add(path);
  }
  return [...seen];
}

/**
 * Validate one sync operation body.
 *
 * Every failure raises an `ApiError` whose message is the bare error code, so
 * no field value can reach a log line. `relationship_policy` never appears at
 * the top level: the Worker cannot see inside an encrypted `engine_profile`
 * payload, so it checks only plaintext entity/space/authority boundaries
 * (`create_group_state`/`patch_group_state`/`create_worldline`/
 * `patch_worldline` restricted to `PHONE_SPACE`) and leaves the encrypted
 * `relationship_policy` enum itself to the client. See
 * `docs/2026-08-27-sync-encryption-proposal.md` §8.2 and the canonical schema
 * draft §4 "통합 결정" for the boundary this enforces on each side.
 */
export function parseOperationRequest(value: unknown): OperationRequest {
  if (!isPlainObject(value)) {
    throw validationFailed();
  }
  for (const key of Object.keys(value)) {
    if (!ALLOWED_TOP_LEVEL_FIELDS.has(key)) {
      throw validationFailed();
    }
  }
  if (value["protocol_version"] !== 1) {
    throw validationFailed();
  }

  const op = value["op"];
  if (typeof op !== "string" || !(RUNTIME_ENABLED_OPERATIONS as readonly string[]).includes(op)) {
    // A schema-defined-but-not-runtime-enabled op (delete_turn) and an
    // entirely unknown op are both rejected the same way: fail closed.
    throw validationFailed();
  }
  const operation = op as OperationName;
  const spec = OPERATION_SPECS[operation];

  if (value["entity_type"] !== spec.entityType) {
    throw validationFailed();
  }

  const target = parseTarget(value["target"], spec.entityType);

  if (spec.phoneSpaceOnly && target.space_id !== "PHONE_SPACE") {
    throw validationFailed();
  }

  const metadata = parseMetadata(value["metadata_set"], value["metadata_clear"], operation);
  if (operation === "create_room") {
    const origin = normalizeRoomOrigin(
      target.space_id,
      metadata.set.origin_space_id as SpaceId | undefined,
    );
    if (!roomOriginAllowsWriter(origin, target.space_id)) {
      throw new ApiError("AUTH_INVALID");
    }
    metadata.set.origin_space_id = origin;
  }
  const entityShape = ENTITY_SHAPES[spec.entityType];
  const rule = METADATA_RULES[operation] ?? EMPTY_METADATA_RULE;
  const plaintextNames: ReadonlySet<string> = new Set<string>([
    ...rule.required,
    ...rule.optional,
    ...rule.clearable,
  ]);
  const parsedSet = parseSet(value["set"], entityShape.allowsExtensions, plaintextNames);

  const requiredEncrypted = REQUIRED_ENCRYPTED_FIELDS[operation];
  if (requiredEncrypted !== undefined) {
    const provided = Object.keys(parsedSet).sort();
    if (provided.length !== requiredEncrypted.length) {
      throw validationFailed();
    }
    for (const [index, field] of [...requiredEncrypted].sort().entries()) {
      if (provided[index] !== field) {
        throw validationFailed();
      }
    }
  }

  const deviceId = requireUuid(value["device_id"]);

  if (DEVICE_PROVENANCE_CREATES.has(operation) && metadata.set.created_by_device_id !== deviceId) {
    // A valid token could otherwise file work under another device's name.
    throw validationFailed();
  }

  if (PROVENANCE_CREATES.has(operation)) {
    // The row records who made it and where. D1 states half of this as
    // CHECK (owner_space_id = space_id), but only as an opaque failure the
    // handler could not tell apart from a storage fault, and it says nothing
    // about the device at all — a valid token could otherwise file a snapshot
    // under another device's name.
    if (metadata.set.owner_space_id !== target.space_id) {
      throw validationFailed();
    }
  }

  if (operation === "create_attachment") {
    // The origin is provenance for the very space that is allocating, so a
    // mismatch means the request describes two different spaces at once.
    if (metadata.set.origin_space_id !== target.space_id) {
      throw validationFailed();
    }
    // v1 encrypts an attachment as one AEAD message with fixed overhead, so
    // this is an equality rather than a bound. Chunked AEAD would need its own
    // manifest contract and is out of scope.
    if (
      metadata.set.ciphertext_byte_size !==
      (metadata.set.source_byte_size as number) + ATTACHMENT_ENVELOPE_OVERHEAD_BYTES
    ) {
      throw validationFailed();
    }
  }
  const parsedClear = parseClear(
    value["clear"],
    new Set(Object.keys(parsedSet)),
    entityShape.allowsExtensions,
    plaintextNames,
  );

  const request: OperationRequest = {
    protocol_version: 1,
    operation_id: requireUuid(value["operation_id"]),
    device_id: deviceId,
    op: operation,
    entity_type: spec.entityType,
    target,
    worldline_key: worldlineKey(target.worldline_id ?? null),
    metadata_set: metadata.set,
    metadata_clear: metadata.clear,
    set: parsedSet,
    clear: parsedClear,
    created_at: requireRfc3339Utc(value["created_at"]),
  };

  if (PATCH_KINDS.has(spec.kind) || operation === "create_persona_snapshot") {
    request.base_revision = requireSafeInteger(value["base_revision"]);
    if (operation === "create_persona_snapshot") {
      // The create carries the head CAS: it inserts an immutable revision and
      // advances persona_snapshot_head in one M06 transaction. The head is 0
      // before the first snapshot exists, so the chain is 0→1 and then always
      // exactly one step (canonical schema §5.1).
      if (request.base_revision < 0) {
        throw validationFailed();
      }
      if (target.snapshot_revision !== request.base_revision + 1) {
        throw validationFailed();
      }
    }
  } else if (value["base_revision"] !== undefined) {
    throw validationFailed();
  }

  if (spec.requiresBubbleOrder) {
    request.bubble_order = requireSafeInteger(value["bubble_order"]);
  } else if (value["bubble_order"] !== undefined) {
    throw validationFailed();
  }

  return request;
}
