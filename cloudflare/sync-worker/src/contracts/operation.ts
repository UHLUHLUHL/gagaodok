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
  | "required" // the target IS a specific worldline; null is meaningless here
  | "absent"; // the entity's D1 key has no worldline component at all

interface EntityShape {
  /** Fields every target of this entity must carry (beyond `space_id`). */
  readonly required: readonly TargetFieldName[];
  readonly worldlineRule: WorldlineRule;
  /** Whether `room_id` is part of this entity's identity. */
  readonly roomScoped: boolean;
}

const ENTITY_SHAPES = {
  room: { required: ["room_id"], worldlineRule: "nullable", roomScoped: true },
  persona_snapshot: {
    required: ["persona_snapshot_id", "snapshot_revision"],
    worldlineRule: "absent",
    roomScoped: false,
  },
  engine_profile: {
    required: ["engine_profile_id", "profile_revision"],
    worldlineRule: "absent",
    roomScoped: false,
  },
  checkpoint: { required: ["room_id", "checkpoint_id"], worldlineRule: "nullable", roomScoped: true },
  turn: { required: ["room_id", "turn_id"], worldlineRule: "nullable", roomScoped: true },
  bubble: {
    required: ["room_id", "turn_id", "message_id"],
    worldlineRule: "nullable",
    roomScoped: true,
  },
  // A group_state row is room-level: its D1 identity is
  // (account_id, PHONE_SPACE, room_id) with no worldline component. The
  // currently selected worldline lives inside the row as the encrypted
  // `active_worldline_id` field, never in the target. Allowing a target
  // `worldline_id` here would let one row be addressed two ways (null vs a
  // UUID) and leave the handler unable to say which belongs to the identity.
  group_state: { required: ["room_id"], worldlineRule: "absent", roomScoped: true },
  worldline: { required: ["room_id", "worldline_id"], worldlineRule: "required", roomScoped: true },
  attachment: { required: ["attachment_id"], worldlineRule: "absent", roomScoped: false },
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
]);

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
  base_revision?: number;
  bubble_order?: number;
  set: Record<string, string>;
  clear: string[];
  created_at: string;
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
function assertCanonicalFieldPath(path: string): void {
  if (path.length === 0 || path.endsWith("_enc")) {
    throw validationFailed();
  }
  if (path.startsWith("extensions.")) {
    const key = path.slice("extensions.".length);
    if (!EXTENSION_KEY_PATTERN.test(key)) {
      throw validationFailed();
    }
    return;
  }
  if (!/^[a-z][a-z0-9_]*$/.test(path)) {
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
    if (shape.worldlineRule === "required" && worldlineId === null) {
      // A worldline operation addresses a specific worldline row; there is
      // no such thing as creating or patching "the null worldline".
      throw validationFailed();
    }
    target.worldline_id = worldlineId;
  }

  return target;
}

function parseSet(value: unknown): Record<string, string> {
  if (value === undefined) {
    throw validationFailed();
  }
  if (!isPlainObject(value)) {
    throw validationFailed();
  }
  const result: Record<string, string> = {};
  for (const [path, envelope] of Object.entries(value)) {
    assertCanonicalFieldPath(path);
    assertFieldEnvelope(envelope);
    result[path] = envelope;
  }
  return result;
}

function parseClear(value: unknown, setPaths: Set<string>): string[] {
  if (!Array.isArray(value)) {
    throw validationFailed();
  }
  const seen = new Set<string>();
  for (const path of value) {
    if (typeof path !== "string") {
      throw validationFailed();
    }
    assertCanonicalFieldPath(path);
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

  const parsedSet = parseSet(value["set"]);
  const parsedClear = parseClear(value["clear"], new Set(Object.keys(parsedSet)));

  const request: OperationRequest = {
    protocol_version: 1,
    operation_id: requireUuid(value["operation_id"]),
    device_id: requireUuid(value["device_id"]),
    op: operation,
    entity_type: spec.entityType,
    target,
    worldline_key: worldlineKey(target.worldline_id ?? null),
    set: parsedSet,
    clear: parsedClear,
    created_at: requireRfc3339Utc(value["created_at"]),
  };

  if (PATCH_KINDS.has(spec.kind)) {
    request.base_revision = requireSafeInteger(value["base_revision"]);
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
