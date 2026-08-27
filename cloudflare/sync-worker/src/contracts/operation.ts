import { ApiError, validationFailed } from "./error";
import {
  EXTENSION_KEY_PATTERN,
  requireNullableWorldlineId,
  requireRfc3339Utc,
  requireSafeInteger,
  requireSpaceId,
  requireUuid,
  worldlineKey,
} from "./identity";
import type { SpaceId } from "./identity";

export { worldlineKey };

/** API draft §2.1 — exact byte bounds, not approximations. */
export const MAX_OPERATION_BODY_BYTES = 2_000_000;
export const MAX_FIELD_ENVELOPE_BYTES = 1_900_000;

/** v1 operations, per API draft §4.1. */
export const OPERATIONS = [
  "create_room",
  "patch_room",
  "create_persona_snapshot",
  "create_engine_profile",
  "create_checkpoint",
  "patch_checkpoint",
  "create_turn",
  "patch_turn",
  "create_bubble",
  "patch_bubble",
  "create_group_state",
  "patch_group_state",
  "create_worldline",
  "patch_worldline",
  "create_attachment",
  "delete_turn",
] as const;
export type OperationName = (typeof OPERATIONS)[number];

/** PHONE_SPACE-only writes. Draft §11.1, review decision 6. */
const PHONE_SPACE_ONLY_OPERATIONS = new Set<OperationName>([
  "create_group_state",
  "patch_group_state",
  "create_worldline",
  "patch_worldline",
]);

/** Operations that mutate an existing entity and therefore need CAS. */
const PATCH_OPERATIONS = new Set<OperationName>([
  "patch_room",
  "patch_checkpoint",
  "patch_turn",
  "patch_bubble",
  "patch_group_state",
  "patch_worldline",
  "delete_turn",
]);

/** Operations addressing a single bubble need the full bubble identity. */
const BUBBLE_OPERATIONS = new Set<OperationName>(["create_bubble", "patch_bubble"]);
const TURN_OPERATIONS = new Set<OperationName>(["create_turn", "patch_turn", "delete_turn"]);

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
  "relationship_policy",
]);

const ALLOWED_TARGET_FIELDS = new Set([
  "space_id",
  "room_id",
  "worldline_id",
  "turn_id",
  "message_id",
]);

const RELATIONSHIP_POLICIES = new Set(["none", "personal", "group"]);

export interface OperationTarget {
  space_id: SpaceId;
  room_id: string;
  worldline_id: string | null;
  turn_id?: string;
  message_id?: string;
}

export interface OperationRequest {
  protocol_version: 1;
  operation_id: string;
  device_id: string;
  op: OperationName;
  entity_type: string;
  target: OperationTarget;
  worldline_key: string;
  base_revision?: number;
  bubble_order?: number;
  relationship_policy?: string;
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

function parseTarget(value: unknown, op: OperationName): OperationTarget {
  if (!isPlainObject(value)) {
    throw validationFailed();
  }
  for (const key of Object.keys(value)) {
    if (!ALLOWED_TARGET_FIELDS.has(key)) {
      throw validationFailed();
    }
  }
  // `worldline_id` must be present and explicitly null for the default
  // worldline; an absent key is ambiguous and therefore refused.
  if (!("worldline_id" in value)) {
    throw validationFailed();
  }

  const target: OperationTarget = {
    space_id: requireSpaceId(value["space_id"]),
    room_id: requireUuid(value["room_id"]),
    worldline_id: requireNullableWorldlineId(value["worldline_id"]),
  };

  if (TURN_OPERATIONS.has(op) || BUBBLE_OPERATIONS.has(op)) {
    target.turn_id = requireUuid(value["turn_id"]);
  }
  if (BUBBLE_OPERATIONS.has(op)) {
    target.message_id = requireUuid(value["message_id"]);
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
    if (typeof envelope !== "string") {
      throw validationFailed();
    }
    // Envelopes are base64 text; byte length equals character count here, and
    // the bound is inclusive.
    if (envelope.length > MAX_FIELD_ENVELOPE_BYTES) {
      throw new ApiError("REQUEST_TOO_LARGE");
    }
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
 * no field value can reach a log line.
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
  if (typeof op !== "string" || !(OPERATIONS as readonly string[]).includes(op)) {
    throw validationFailed();
  }
  const operation = op as OperationName;

  const entityType = value["entity_type"];
  if (typeof entityType !== "string" || !/^[a-z][a-z0-9_]*$/.test(entityType)) {
    throw validationFailed();
  }

  const target = parseTarget(value["target"], operation);

  if (PHONE_SPACE_ONLY_OPERATIONS.has(operation) && target.space_id !== "PHONE_SPACE") {
    throw validationFailed();
  }

  const relationshipPolicy = value["relationship_policy"];
  if (relationshipPolicy !== undefined) {
    if (typeof relationshipPolicy !== "string" || !RELATIONSHIP_POLICIES.has(relationshipPolicy)) {
      throw validationFailed();
    }
    if (relationshipPolicy === "group" && target.space_id !== "PHONE_SPACE") {
      throw validationFailed();
    }
  }

  const parsedSet = parseSet(value["set"]);
  const parsedClear = parseClear(value["clear"], new Set(Object.keys(parsedSet)));

  const request: OperationRequest = {
    protocol_version: 1,
    operation_id: requireUuid(value["operation_id"]),
    device_id: requireUuid(value["device_id"]),
    op: operation,
    entity_type: entityType,
    target,
    worldline_key: worldlineKey(target.worldline_id),
    set: parsedSet,
    clear: parsedClear,
    created_at: requireRfc3339Utc(value["created_at"]),
  };

  if (PATCH_OPERATIONS.has(operation)) {
    request.base_revision = requireSafeInteger(value["base_revision"]);
  } else if (value["base_revision"] !== undefined) {
    request.base_revision = requireSafeInteger(value["base_revision"]);
  }

  if (BUBBLE_OPERATIONS.has(operation)) {
    request.bubble_order = requireSafeInteger(value["bubble_order"]);
  } else if (value["bubble_order"] !== undefined) {
    throw validationFailed();
  }

  if (relationshipPolicy !== undefined) {
    request.relationship_policy = relationshipPolicy as string;
  }

  return request;
}
