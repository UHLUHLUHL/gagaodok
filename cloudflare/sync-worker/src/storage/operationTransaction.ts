import { ApiError, validationFailed } from "../contracts/error";
import { getEntityShape, getOperationSpec } from "../contracts/operation";
import type { OperationRequest } from "../contracts/operation";
import type { AuthContext } from "../auth/deviceToken";

/**
 * The M06 atomic write path — first vertical slice: `patch_room`.
 *
 * API draft §5.1/§5.3, canonical schema §14.3. One successful operation makes
 * exactly one revision, one `server_seq` and one `change_log` row, and every
 * table it touches moves in a single `batch()` transaction. A CAS miss is not
 * an `UPDATE 0 rows` that a batch would happily accept: the `transaction_guard`
 * insert turns it into a constraint violation that rolls the whole batch back.
 */

/** The §4.1 result, without the route-level envelope. */
export interface OperationResult {
  status: "applied" | "replayed";
  operation_id: string;
  server_seq: number;
  revision: number | null;
}

/**
 * The only room field names this handler accepts, and the column each one
 * writes. The mapping is fixed on purpose: a column name is never assembled
 * from a request value, so an unexpected field is a refusal rather than a
 * chance to name a column. `avatar_ref` is deliberately absent — the room
 * table has no avatar column and inventing one is out of scope.
 */
const ROOM_FIELD_COLUMNS: Readonly<Record<string, string>> = Object.freeze({
  title: "title_enc",
  status_message: "status_message_enc",
  music_title: "music_title_enc",
  music_artist: "music_artist_enc",
});

/**
 * group_state's canonical encrypted fields (canonical schema §11.1). It has no
 * extension table, so an `extensions.*` path never reaches here — the
 * validator refuses it via `ENTITY_SHAPES.group_state.allowsExtensions`.
 */
const GROUP_STATE_FIELD_COLUMNS: Readonly<Record<string, string>> = Object.freeze({
  participants: "participants_enc",
  active_worldline_id: "active_worldline_id_enc",
});

const EXTENSION_PREFIX = "extensions.";

/** Highest allocatable sequence; `2^53` is the exhausted sentinel (§5.3). */
const MAX_ALLOCATABLE_SEQ = 9007199254740991;
const EXHAUSTED_SENTINEL = 9007199254740992;

const CURRENT_SEQ = "(SELECT next_server_seq FROM account WHERE account_id = ?)";

interface OperationLogRow {
  request_fingerprint: string;
  server_seq: number;
  result_revision: number | null;
}

interface RoomRow {
  revision: number;
}

interface RefRow {
  engine_profile_id: string | null;
  engine_profile_revision: number | null;
  persona_snapshot_id: string | null;
  persona_snapshot_revision: number | null;
}

function storageUnavailable(): ApiError {
  // Never carries the D1 message: a SQL string can quote an identifier or a
  // bound value, and both are content (API draft §8).
  return new ApiError("STORAGE_UNAVAILABLE", { retryable: true });
}

/** Split `set`/`clear` names into canonical room fields and extension keys. */
function partitionFieldNames(
  names: readonly string[],
  mapping: Readonly<Record<string, string>>,
): {
  columns: string[];
  extensionKeys: string[];
} {
  const columns: string[] = [];
  const extensionKeys: string[] = [];
  for (const name of names) {
    if (name.startsWith(EXTENSION_PREFIX)) {
      extensionKeys.push(name.slice(EXTENSION_PREFIX.length));
      continue;
    }
    const column = mapping[name];
    if (column === undefined) {
      // The validator checks the *grammar* of a field path; only the handler
      // knows which names the room table actually has. Ignoring the rest would
      // silently drop half of a patch the client believes was applied.
      throw validationFailed();
    }
    columns.push(column);
  }
  return { columns, extensionKeys };
}

async function readOperationLog(
  db: D1Database,
  accountId: string,
  operationId: string,
): Promise<OperationLogRow | null> {
  return await db
    .prepare(
      `SELECT request_fingerprint, server_seq, result_revision
         FROM operation_log
        WHERE account_id = ? AND operation_id = ?`,
    )
    .bind(accountId, operationId)
    .first<OperationLogRow>();
}

function replayResult(operationId: string, row: OperationLogRow, fingerprint: string): OperationResult {
  if (row.request_fingerprint !== fingerprint) {
    // Same ID, different bytes: the client re-serialised instead of resending
    // the outbox bytes, so the two requests are not the same operation.
    throw new ApiError("OPERATION_REPLAY_MISMATCH");
  }
  return {
    status: "replayed",
    operation_id: operationId,
    server_seq: row.server_seq,
    revision: row.result_revision,
  };
}

/**
 * Apply one validated `patch_room`.
 *
 * `request` has already been through `parseOperationRequest`, and `auth` is the
 * device the token proved. The account never comes from the body.
 */
export async function applyPatchRoom(
  db: D1Database,
  auth: AuthContext,
  request: OperationRequest,
  fingerprint: string,
): Promise<OperationResult> {
  const spec = getOperationSpec(request.op);
  const shape = getEntityShape(spec.entityType);
  if (spec.entityType !== "room" || spec.kind !== "patch" || shape.worldlineRule !== "null-only") {
    // The rules live in the validator; this slice only asserts that the ones
    // it was written against still hold.
    throw validationFailed();
  }

  const accountId = auth.account_id;
  const spaceId = request.target.space_id;
  const roomId = request.target.room_id as string;
  const baseRevision = request.base_revision as number;
  const nextRevision = baseRevision + 1;

  const setNames = Object.keys(request.set);
  const setFields = partitionFieldNames(setNames, ROOM_FIELD_COLUMNS);
  const clearFields = partitionFieldNames(request.clear, ROOM_FIELD_COLUMNS);

  const existing = await readOperationLog(db, accountId, request.operation_id);
  if (existing !== null) {
    return replayResult(request.operation_id, existing, fingerprint);
  }

  const currentRef = await db
    .prepare(
      `SELECT engine_profile_id, engine_profile_revision,
              persona_snapshot_id, persona_snapshot_revision
         FROM room_ai_state_ref
        WHERE account_id = ? AND space_id = ? AND room_id = ?`,
    )
    .bind(accountId, spaceId, roomId)
    .first<RefRow>();

  const statements = buildBatch({
    db,
    accountId,
    spaceId,
    roomId,
    request,
    fingerprint,
    baseRevision,
    nextRevision,
    setFields,
    clearFields,
    currentRef,
  });

  try {
    await db.batch(statements);
  } catch {
    // Nothing from the D1 error is inspected or re-thrown. The cause is
    // re-derived from storage so the classification is deterministic.
    return await classifyFailure(db, accountId, request, fingerprint, baseRevision);
  }

  const applied = await readOperationLog(db, accountId, request.operation_id);
  if (applied === null) {
    throw storageUnavailable();
  }
  return {
    status: "applied",
    operation_id: request.operation_id,
    server_seq: applied.server_seq,
    revision: applied.result_revision,
  };
}

/**
 * The two ledger rows and the sequence bookkeeping every successful room
 * operation writes. Shared so `create_room` and `patch_room` cannot drift
 * into recording the same fact two different ways.
 */
/**
 * The identity axes one change_log row carries. Each handler states its own
 * explicitly rather than having them inferred from the target: migration 0008
 * requires exactly one `entity_type` branch's axes to be non-null and every
 * other axis to be null, and inference by nullable fallthrough is how a new
 * entity silently lands in the wrong branch.
 *
 * The keys are a closed set that matches the column names, so no SQL
 * identifier is ever assembled from a request value.
 */
interface ChangeIdentity {
  // Optional: an attachment's change identity is the attachment alone, and
  // 0008 requires space_id to be NULL on that branch.
  space_id?: string;
  room_id?: string;
  worldline_key?: string;
  turn_id?: string;
  message_id?: string;
  checkpoint_id?: string;
  persona_snapshot_id?: string;
  snapshot_revision?: number;
  engine_profile_id?: string;
  profile_revision?: number;
  attachment_id?: string;
}

const CHANGE_IDENTITY_COLUMNS: readonly (keyof ChangeIdentity)[] = Object.freeze([
  "space_id",
  "room_id",
  "worldline_key",
  "turn_id",
  "message_id",
  "checkpoint_id",
  "persona_snapshot_id",
  "snapshot_revision",
  "engine_profile_id",
  "profile_revision",
  "attachment_id",
]);

function ledgerStatements(
  db: D1Database,
  accountId: string,
  request: OperationRequest,
  fingerprint: string,
  // Null only for a projection that has no revision of its own — attachment is
  // the single such entity, and migration 0008 states the same rule as a CHECK.
  revision: number | null,
  identity: ChangeIdentity,
): D1PreparedStatement[] {
  // The entity_type comes from the validator's operation table, never from a
  // literal spelled out per handler, so the two ledgers can never disagree
  // about what a given operation wrote.
  const entityType = getOperationSpec(request.op).entityType;

  const columns: string[] = [];
  const values: (string | number)[] = [];
  for (const column of CHANGE_IDENTITY_COLUMNS) {
    const value = identity[column];
    if (value !== undefined) {
      columns.push(column);
      values.push(value);
    }
  }

  return [
    db
      .prepare(
        `INSERT INTO operation_log
           (account_id, operation_id, request_fingerprint, entity_type, change_kind,
            result_revision, server_seq)
         VALUES (?, ?, ?, ?, 'upsert', ?, ${CURRENT_SEQ})`,
      )
      .bind(accountId, request.operation_id, fingerprint, entityType, revision, accountId),
    db
      .prepare(
        `INSERT INTO change_log
           (account_id, server_seq, entity_type, change_kind, revision, ${columns.join(", ")})
         VALUES (?, ${CURRENT_SEQ}, ?, 'upsert', ?, ${columns.map(() => "?").join(", ")})`,
      )
      .bind(accountId, accountId, entityType, revision, ...values),
    db
      .prepare("UPDATE account SET next_server_seq = next_server_seq + 1 WHERE account_id = ?")
      .bind(accountId),
    db
      .prepare("DELETE FROM transaction_guard WHERE account_id = ? AND operation_id = ?")
      .bind(accountId, request.operation_id),
  ];
}

/** The change identity of a named worldline row. */
function worldlineIdentity(request: OperationRequest): ChangeIdentity {
  return {
    space_id: request.target.space_id,
    room_id: request.target.room_id as string,
    // The validator already computed this from the target; deriving it a
    // second time here is how it would stop matching D1's
    // CHECK (worldline_key = COALESCE(worldline_id, '')).
    worldline_key: request.worldline_key,
  };
}

/** The change identity of a room-level entity: room, group_state. */
function roomIdentity(request: OperationRequest): ChangeIdentity {
  return { space_id: request.target.space_id, room_id: request.target.room_id as string };
}

/** Upsert one extension envelope; the key is always a bound value. */
function extensionUpsert(
  db: D1Database,
  accountId: string,
  spaceId: string,
  roomId: string,
  key: string,
  envelope: string,
): D1PreparedStatement {
  return db
    .prepare(
      `INSERT INTO room_extension_field
         (account_id, space_id, room_id, extension_key, envelope_enc)
       VALUES (?, ?, ?, ?, ?)
       ON CONFLICT (account_id, space_id, room_id, extension_key)
       DO UPDATE SET envelope_enc = excluded.envelope_enc`,
    )
    .bind(accountId, spaceId, roomId, key, envelope);
}

async function readRoomRevision(
  db: D1Database,
  accountId: string,
  spaceId: string,
  roomId: string,
): Promise<number | null> {
  const row = await db
    .prepare("SELECT revision FROM room WHERE account_id = ? AND space_id = ? AND room_id = ?")
    .bind(accountId, spaceId, roomId)
    .first<RoomRow>();
  return row === null ? null : row.revision;
}

async function sequenceExhausted(db: D1Database, accountId: string): Promise<boolean> {
  const account = await db
    .prepare("SELECT next_server_seq FROM account WHERE account_id = ?")
    .bind(accountId)
    .first<{ next_server_seq: number }>();
  if (account === null) {
    throw new ApiError("ENTITY_NOT_FOUND");
  }
  return account.next_server_seq >= EXHAUSTED_SENTINEL;
}

/**
 * Apply one validated `create_room`.
 *
 * The guard is the mirror of the patch one: the room must *not* exist. A bare
 * INSERT would also fail on the primary key, but the guard states the
 * precondition in the same place as every other operation's, and it is what
 * makes the sentinel check part of the same rollback.
 */
export async function applyCreateRoom(
  db: D1Database,
  auth: AuthContext,
  request: OperationRequest,
  fingerprint: string,
): Promise<OperationResult> {
  const spec = getOperationSpec(request.op);
  const shape = getEntityShape(spec.entityType);
  if (spec.entityType !== "room" || spec.kind !== "create" || shape.worldlineRule !== "null-only") {
    throw validationFailed();
  }

  const accountId = auth.account_id;
  const spaceId = request.target.space_id;
  const roomId = request.target.room_id as string;

  const setFields = partitionFieldNames(Object.keys(request.set), ROOM_FIELD_COLUMNS);
  // A clear on a row that does not exist yet is just the absent value; the
  // partition still runs so an unmapped name is refused rather than ignored.
  partitionFieldNames(request.clear, ROOM_FIELD_COLUMNS);

  const existing = await readOperationLog(db, accountId, request.operation_id);
  if (existing !== null) {
    return replayResult(request.operation_id, existing, fingerprint);
  }

  const statements: D1PreparedStatement[] = [
    db
      .prepare(
        `INSERT INTO transaction_guard (account_id, operation_id, ok)
         VALUES (?, ?,
           ((SELECT COUNT(*) FROM room
              WHERE account_id = ? AND space_id = ? AND room_id = ?) = 0
            AND (SELECT next_server_seq FROM account WHERE account_id = ?) <= ${MAX_ALLOCATABLE_SEQ}))`,
      )
      .bind(accountId, request.operation_id, accountId, spaceId, roomId, accountId),
    db
      .prepare(
        `INSERT INTO room
           (account_id, space_id, room_id, title_enc, status_message_enc,
            music_title_enc, music_artist_enc, revision, server_seq, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, 0, ${CURRENT_SEQ}, ?, ?)`,
      )
      .bind(
        accountId,
        spaceId,
        roomId,
        request.set["title"] ?? null,
        request.set["status_message"] ?? null,
        request.set["music_title"] ?? null,
        request.set["music_artist"] ?? null,
        accountId,
        request.created_at,
        request.created_at,
      ),
  ];
  for (const key of setFields.extensionKeys) {
    const envelope = request.set[`${EXTENSION_PREFIX}${key}`] as string;
    statements.push(extensionUpsert(db, accountId, spaceId, roomId, key, envelope));
  }
  statements.push(...ledgerStatements(db, accountId, request, fingerprint, 0, roomIdentity(request)));

  try {
    await db.batch(statements);
  } catch {
    return await classifyCreateFailure(db, accountId, request, fingerprint);
  }

  const applied = await readOperationLog(db, accountId, request.operation_id);
  if (applied === null) {
    throw storageUnavailable();
  }
  return {
    status: "applied",
    operation_id: request.operation_id,
    server_seq: applied.server_seq,
    revision: applied.result_revision,
  };
}

async function classifyCreateFailure(
  db: D1Database,
  accountId: string,
  request: OperationRequest,
  fingerprint: string,
): Promise<OperationResult> {
  const existing = await readOperationLog(db, accountId, request.operation_id);
  if (existing !== null) {
    return replayResult(request.operation_id, existing, fingerprint);
  }

  const revision = await readRoomRevision(
    db,
    accountId,
    request.target.space_id,
    request.target.room_id as string,
  );
  if (revision !== null) {
    // Another operation already created this room. The only detail is the
    // number the client needs to switch to patching.
    throw new ApiError("REVISION_CONFLICT", { detail: { current_revision: revision } });
  }
  if (await sequenceExhausted(db, accountId)) {
    throw new ApiError("STORAGE_UNAVAILABLE", { retryable: false });
  }
  throw storageUnavailable();
}

/**
 * Split a non-extension entity's field names into columns, refusing any
 * extension path outright.
 *
 * The validator already refuses these (`allowsExtensions: false`); this is the
 * fail-closed assertion that an envelope can never be dropped on the floor if
 * that rule is ever relaxed by accident.
 */
function columnsOnly(
  names: readonly string[],
  mapping: Readonly<Record<string, string>>,
): string[] {
  const partitioned = partitionFieldNames(names, mapping);
  if (partitioned.extensionKeys.length > 0) {
    throw validationFailed();
  }
  return partitioned.columns;
}

/** Bind values for a non-extension entity's encrypted columns, in map order. */
function encryptedValues(
  request: OperationRequest,
  mapping: Readonly<Record<string, string>>,
): (string | null)[] {
  return Object.keys(mapping).map((name) => (request.set[name] as string | undefined) ?? null);
}

/**
 * Apply one validated `create_group_state`.
 *
 * The guard states all three preconditions the contract names — the parent
 * room exists, no group_state exists yet, and the sequence is allocatable — as
 * one boolean, so a miss on any of them aborts the same batch rather than
 * leaving a half-written ledger. The FK on `group_state` would also catch a
 * missing room, but only as an opaque driver failure that cannot be told apart
 * from a storage fault.
 */
export async function applyCreateGroupState(
  db: D1Database,
  auth: AuthContext,
  request: OperationRequest,
  fingerprint: string,
): Promise<OperationResult> {
  const accountId = auth.account_id;
  const spaceId = request.target.space_id;
  const roomId = request.target.room_id as string;

  columnsOnly(Object.keys(request.set), GROUP_STATE_FIELD_COLUMNS);
  columnsOnly(request.clear, GROUP_STATE_FIELD_COLUMNS);

  const existing = await readOperationLog(db, accountId, request.operation_id);
  if (existing !== null) {
    return replayResult(request.operation_id, existing, fingerprint);
  }

  const statements: D1PreparedStatement[] = [
    db
      .prepare(
        `INSERT INTO transaction_guard (account_id, operation_id, ok)
         VALUES (?, ?,
           ((SELECT COUNT(*) FROM room
              WHERE account_id = ? AND space_id = ? AND room_id = ?) = 1
            AND (SELECT COUNT(*) FROM group_state
                  WHERE account_id = ? AND space_id = ? AND room_id = ?) = 0
            AND (SELECT next_server_seq FROM account WHERE account_id = ?) <= ${MAX_ALLOCATABLE_SEQ}))`,
      )
      .bind(
        accountId,
        request.operation_id,
        accountId,
        spaceId,
        roomId,
        accountId,
        spaceId,
        roomId,
        accountId,
      ),
    db
      .prepare(
        `INSERT INTO group_state
           (account_id, space_id, room_id, participants_enc, active_worldline_id_enc,
            revision, server_seq, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, 0, ${CURRENT_SEQ}, ?, ?)`,
      )
      .bind(
        accountId,
        spaceId,
        roomId,
        ...encryptedValues(request, GROUP_STATE_FIELD_COLUMNS),
        accountId,
        request.created_at,
        request.created_at,
      ),
    ...ledgerStatements(db, accountId, request, fingerprint, 0, roomIdentity(request)),
  ];

  return await runBatch(db, accountId, request, fingerprint, statements, () =>
    classifyGroupStateCreateFailure(db, accountId, request, fingerprint),
  );
}

/** Apply one validated `patch_group_state`. */
export async function applyPatchGroupState(
  db: D1Database,
  auth: AuthContext,
  request: OperationRequest,
  fingerprint: string,
): Promise<OperationResult> {
  const accountId = auth.account_id;
  const spaceId = request.target.space_id;
  const roomId = request.target.room_id as string;
  const baseRevision = request.base_revision as number;
  const nextRevision = baseRevision + 1;

  const clearColumns = columnsOnly(request.clear, GROUP_STATE_FIELD_COLUMNS);
  columnsOnly(Object.keys(request.set), GROUP_STATE_FIELD_COLUMNS);

  const existing = await readOperationLog(db, accountId, request.operation_id);
  if (existing !== null) {
    return replayResult(request.operation_id, existing, fingerprint);
  }

  const assignments: string[] = [];
  const bindings: unknown[] = [];
  for (const [name, column] of Object.entries(GROUP_STATE_FIELD_COLUMNS)) {
    if (Object.prototype.hasOwnProperty.call(request.set, name)) {
      assignments.push(`${column} = ?`);
      bindings.push(request.set[name]);
    }
  }
  for (const column of clearColumns) {
    assignments.push(`${column} = NULL`);
  }
  assignments.push("revision = revision + 1", `server_seq = ${CURRENT_SEQ}`, "updated_at = ?");
  bindings.push(accountId, request.created_at);

  const statements: D1PreparedStatement[] = [
    db
      .prepare(
        `INSERT INTO transaction_guard (account_id, operation_id, ok)
         VALUES (?, ?,
           ((SELECT revision FROM group_state
              WHERE account_id = ? AND space_id = ? AND room_id = ?) = ?
            AND (SELECT next_server_seq FROM account WHERE account_id = ?) <= ${MAX_ALLOCATABLE_SEQ}))`,
      )
      .bind(accountId, request.operation_id, accountId, spaceId, roomId, baseRevision, accountId),
    db
      .prepare(
        `UPDATE group_state SET ${assignments.join(", ")}
          WHERE account_id = ? AND space_id = ? AND room_id = ? AND revision = ?`,
      )
      .bind(...bindings, accountId, spaceId, roomId, baseRevision),
    ...ledgerStatements(db, accountId, request, fingerprint, nextRevision, roomIdentity(request)),
  ];

  return await runBatch(db, accountId, request, fingerprint, statements, () =>
    classifyGroupStatePatchFailure(db, accountId, request, fingerprint, baseRevision),
  );
}

async function readGroupStateRevision(
  db: D1Database,
  accountId: string,
  request: OperationRequest,
): Promise<number | null> {
  const row = await db
    .prepare(
      "SELECT revision FROM group_state WHERE account_id = ? AND space_id = ? AND room_id = ?",
    )
    .bind(accountId, request.target.space_id, request.target.room_id)
    .first<RoomRow>();
  return row === null ? null : row.revision;
}

async function classifyGroupStateCreateFailure(
  db: D1Database,
  accountId: string,
  request: OperationRequest,
  fingerprint: string,
): Promise<OperationResult> {
  const existing = await readOperationLog(db, accountId, request.operation_id);
  if (existing !== null) {
    return replayResult(request.operation_id, existing, fingerprint);
  }
  const roomRevision = await readRoomRevision(
    db,
    accountId,
    request.target.space_id,
    request.target.room_id as string,
  );
  if (roomRevision === null) {
    throw new ApiError("ENTITY_NOT_FOUND");
  }
  const revision = await readGroupStateRevision(db, accountId, request);
  if (revision !== null) {
    throw new ApiError("REVISION_CONFLICT", { detail: { current_revision: revision } });
  }
  if (await sequenceExhausted(db, accountId)) {
    throw new ApiError("STORAGE_UNAVAILABLE", { retryable: false });
  }
  throw storageUnavailable();
}

async function classifyGroupStatePatchFailure(
  db: D1Database,
  accountId: string,
  request: OperationRequest,
  fingerprint: string,
  baseRevision: number,
): Promise<OperationResult> {
  const existing = await readOperationLog(db, accountId, request.operation_id);
  if (existing !== null) {
    return replayResult(request.operation_id, existing, fingerprint);
  }
  const revision = await readGroupStateRevision(db, accountId, request);
  if (revision === null) {
    throw new ApiError("ENTITY_NOT_FOUND");
  }
  if (revision !== baseRevision) {
    throw new ApiError("REVISION_CONFLICT", { detail: { current_revision: revision } });
  }
  if (await sequenceExhausted(db, accountId)) {
    throw new ApiError("STORAGE_UNAVAILABLE", { retryable: false });
  }
  throw storageUnavailable();
}

/**
 * Run a prepared batch and turn the outcome into a result.
 *
 * The D1 error object is never inspected: on failure the caller's classifier
 * re-derives the cause from storage, so no driver message or bound value can
 * reach a response.
 */
async function runBatch(
  db: D1Database,
  accountId: string,
  request: OperationRequest,
  fingerprint: string,
  statements: D1PreparedStatement[],
  classify: () => Promise<OperationResult>,
): Promise<OperationResult> {
  try {
    await db.batch(statements);
  } catch {
    return await classify();
  }
  const applied = await readOperationLog(db, accountId, request.operation_id);
  if (applied === null) {
    throw storageUnavailable();
  }
  return {
    status: "applied",
    operation_id: request.operation_id,
    server_seq: applied.server_seq,
    revision: applied.result_revision,
  };
}

/**
 * worldline's canonical encrypted fields (canonical schema §11.1). Like
 * group_state it has no extension table.
 */
const WORLDLINE_FIELD_COLUMNS: Readonly<Record<string, string>> = Object.freeze({
  name: "name_enc",
  participant_hearts: "participant_hearts_enc",
});

/**
 * Apply one validated `create_worldline`.
 *
 * The stored `worldline_key` is the value the validator already computed from
 * the target, never a second derivation here: D1's
 * `CHECK (worldline_key = COALESCE(worldline_id, ''))` and the API's nullable
 * `worldline_id` must agree, and two independent derivations are exactly how
 * they would stop agreeing. The target is `required`, so the key is a non-null
 * UUID and no default-scope row can be created through this path.
 */
export async function applyCreateWorldline(
  db: D1Database,
  auth: AuthContext,
  request: OperationRequest,
  fingerprint: string,
): Promise<OperationResult> {
  const accountId = auth.account_id;
  const spaceId = request.target.space_id;
  const roomId = request.target.room_id as string;
  const worldlineId = request.target.worldline_id as string;
  const key = request.worldline_key;

  columnsOnly(Object.keys(request.set), WORLDLINE_FIELD_COLUMNS);
  columnsOnly(request.clear, WORLDLINE_FIELD_COLUMNS);

  const existing = await readOperationLog(db, accountId, request.operation_id);
  if (existing !== null) {
    return replayResult(request.operation_id, existing, fingerprint);
  }

  const statements: D1PreparedStatement[] = [
    db
      .prepare(
        `INSERT INTO transaction_guard (account_id, operation_id, ok)
         VALUES (?, ?,
           ((SELECT COUNT(*) FROM room
              WHERE account_id = ? AND space_id = ? AND room_id = ?) = 1
            AND (SELECT COUNT(*) FROM worldline
                  WHERE account_id = ? AND space_id = ? AND room_id = ?
                    AND worldline_key = ?) = 0
            AND (SELECT next_server_seq FROM account WHERE account_id = ?) <= ${MAX_ALLOCATABLE_SEQ}))`,
      )
      .bind(
        accountId,
        request.operation_id,
        accountId,
        spaceId,
        roomId,
        accountId,
        spaceId,
        roomId,
        key,
        accountId,
      ),
    db
      .prepare(
        `INSERT INTO worldline
           (account_id, space_id, room_id, worldline_id, worldline_key,
            name_enc, participant_hearts_enc, revision, server_seq, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, 0, ${CURRENT_SEQ}, ?, ?)`,
      )
      .bind(
        accountId,
        spaceId,
        roomId,
        worldlineId,
        key,
        ...encryptedValues(request, WORLDLINE_FIELD_COLUMNS),
        accountId,
        request.created_at,
        request.created_at,
      ),
    ...ledgerStatements(db, accountId, request, fingerprint, 0, worldlineIdentity(request)),
  ];

  return await runBatch(db, accountId, request, fingerprint, statements, () =>
    classifyWorldlineCreateFailure(db, accountId, request, fingerprint),
  );
}

/** Apply one validated `patch_worldline`. */
export async function applyPatchWorldline(
  db: D1Database,
  auth: AuthContext,
  request: OperationRequest,
  fingerprint: string,
): Promise<OperationResult> {
  const accountId = auth.account_id;
  const spaceId = request.target.space_id;
  const roomId = request.target.room_id as string;
  const key = request.worldline_key;
  const baseRevision = request.base_revision as number;
  const nextRevision = baseRevision + 1;

  const clearColumns = columnsOnly(request.clear, WORLDLINE_FIELD_COLUMNS);
  columnsOnly(Object.keys(request.set), WORLDLINE_FIELD_COLUMNS);

  const existing = await readOperationLog(db, accountId, request.operation_id);
  if (existing !== null) {
    return replayResult(request.operation_id, existing, fingerprint);
  }

  const assignments: string[] = [];
  const bindings: unknown[] = [];
  for (const [name, column] of Object.entries(WORLDLINE_FIELD_COLUMNS)) {
    if (Object.prototype.hasOwnProperty.call(request.set, name)) {
      assignments.push(`${column} = ?`);
      bindings.push(request.set[name]);
    }
  }
  for (const column of clearColumns) {
    assignments.push(`${column} = NULL`);
  }
  assignments.push("revision = revision + 1", `server_seq = ${CURRENT_SEQ}`, "updated_at = ?");
  bindings.push(accountId, request.created_at);

  const statements: D1PreparedStatement[] = [
    db
      .prepare(
        `INSERT INTO transaction_guard (account_id, operation_id, ok)
         VALUES (?, ?,
           ((SELECT revision FROM worldline
              WHERE account_id = ? AND space_id = ? AND room_id = ? AND worldline_key = ?) = ?
            AND (SELECT next_server_seq FROM account WHERE account_id = ?) <= ${MAX_ALLOCATABLE_SEQ}))`,
      )
      .bind(accountId, request.operation_id, accountId, spaceId, roomId, key, baseRevision, accountId),
    db
      .prepare(
        `UPDATE worldline SET ${assignments.join(", ")}
          WHERE account_id = ? AND space_id = ? AND room_id = ? AND worldline_key = ?
            AND revision = ?`,
      )
      .bind(...bindings, accountId, spaceId, roomId, key, baseRevision),
    ...ledgerStatements(db, accountId, request, fingerprint, nextRevision, worldlineIdentity(request)),
  ];

  return await runBatch(db, accountId, request, fingerprint, statements, () =>
    classifyWorldlinePatchFailure(db, accountId, request, fingerprint, baseRevision),
  );
}

async function readWorldlineRevision(
  db: D1Database,
  accountId: string,
  request: OperationRequest,
): Promise<number | null> {
  const row = await db
    .prepare(
      `SELECT revision FROM worldline
        WHERE account_id = ? AND space_id = ? AND room_id = ? AND worldline_key = ?`,
    )
    .bind(accountId, request.target.space_id, request.target.room_id, request.worldline_key)
    .first<RoomRow>();
  return row === null ? null : row.revision;
}

async function classifyWorldlineCreateFailure(
  db: D1Database,
  accountId: string,
  request: OperationRequest,
  fingerprint: string,
): Promise<OperationResult> {
  const existing = await readOperationLog(db, accountId, request.operation_id);
  if (existing !== null) {
    return replayResult(request.operation_id, existing, fingerprint);
  }
  const roomRevision = await readRoomRevision(
    db,
    accountId,
    request.target.space_id,
    request.target.room_id as string,
  );
  if (roomRevision === null) {
    throw new ApiError("ENTITY_NOT_FOUND");
  }
  const revision = await readWorldlineRevision(db, accountId, request);
  if (revision !== null) {
    throw new ApiError("REVISION_CONFLICT", { detail: { current_revision: revision } });
  }
  if (await sequenceExhausted(db, accountId)) {
    throw new ApiError("STORAGE_UNAVAILABLE", { retryable: false });
  }
  throw storageUnavailable();
}

async function classifyWorldlinePatchFailure(
  db: D1Database,
  accountId: string,
  request: OperationRequest,
  fingerprint: string,
  baseRevision: number,
): Promise<OperationResult> {
  const existing = await readOperationLog(db, accountId, request.operation_id);
  if (existing !== null) {
    return replayResult(request.operation_id, existing, fingerprint);
  }
  const revision = await readWorldlineRevision(db, accountId, request);
  if (revision === null) {
    throw new ApiError("ENTITY_NOT_FOUND");
  }
  if (revision !== baseRevision) {
    throw new ApiError("REVISION_CONFLICT", { detail: { current_revision: revision } });
  }
  if (await sequenceExhausted(db, accountId)) {
    throw new ApiError("STORAGE_UNAVAILABLE", { retryable: false });
  }
  throw storageUnavailable();
}

const ENGINE_PROFILE_FIELD_COLUMNS: Readonly<Record<string, string>> = Object.freeze({
  mode: "mode_enc",
  model_capability: "model_capability_enc",
  prompt_profile_id: "prompt_profile_id_enc",
  prompt_profile_version: "prompt_profile_version_enc",
  relationship_policy: "relationship_policy_enc",
  compaction_profile_id: "compaction_profile_id_enc",
  compaction_contract_fingerprint: "compaction_contract_fingerprint_enc",
  cache_policy: "cache_policy_enc",
  repetition_policy: "repetition_policy_enc",
});

/**
 * Apply one validated `create_engine_profile`.
 *
 * An engine_profile row is an immutable version: the table has no
 * `revision`, no `created_at` and a BEFORE UPDATE trigger that aborts. So
 * this is a plain INSERT — never an upsert, which would fire that trigger —
 * and the ledger records the identity's own `profile_revision` (contract
 * 7c97146) rather than a mutable revision that does not exist.
 */
export async function applyCreateEngineProfile(
  db: D1Database,
  auth: AuthContext,
  request: OperationRequest,
  fingerprint: string,
): Promise<OperationResult> {
  const accountId = auth.account_id;
  const spaceId = request.target.space_id;
  const profileId = request.target.engine_profile_id as string;
  const profileRevision = request.target.profile_revision as number;

  columnsOnly(Object.keys(request.set), ENGINE_PROFILE_FIELD_COLUMNS);
  columnsOnly(request.clear, ENGINE_PROFILE_FIELD_COLUMNS);

  const existing = await readOperationLog(db, accountId, request.operation_id);
  if (existing !== null) {
    return replayResult(request.operation_id, existing, fingerprint);
  }

  const columns = Object.values(ENGINE_PROFILE_FIELD_COLUMNS);
  const statements: D1PreparedStatement[] = [
    db
      .prepare(
        `INSERT INTO transaction_guard (account_id, operation_id, ok)
         VALUES (?, ?,
           ((SELECT COUNT(*) FROM engine_profile
              WHERE account_id = ? AND space_id = ? AND engine_profile_id = ?
                AND profile_revision = ?) = 0
            AND (SELECT next_server_seq FROM account WHERE account_id = ?) <= ${MAX_ALLOCATABLE_SEQ}))`,
      )
      .bind(accountId, request.operation_id, accountId, spaceId, profileId, profileRevision, accountId),
    db
      .prepare(
        `INSERT INTO engine_profile
           (account_id, space_id, engine_profile_id, profile_revision,
            ${columns.join(", ")}, compaction_compat_tag, server_seq)
         VALUES (?, ?, ?, ?, ${columns.map(() => "?").join(", ")}, ?, ${CURRENT_SEQ})`,
      )
      .bind(
        accountId,
        spaceId,
        profileId,
        profileRevision,
        ...encryptedValues(request, ENGINE_PROFILE_FIELD_COLUMNS),
        request.metadata_set["compaction_compat_tag"] ?? null,
        accountId,
      ),
    ...ledgerStatements(db, accountId, request, fingerprint, profileRevision, {
      space_id: spaceId,
      engine_profile_id: profileId,
      profile_revision: profileRevision,
    }),
  ];

  return await runBatch(db, accountId, request, fingerprint, statements, () =>
    classifyEngineProfileFailure(db, accountId, request, fingerprint),
  );
}

async function classifyEngineProfileFailure(
  db: D1Database,
  accountId: string,
  request: OperationRequest,
  fingerprint: string,
): Promise<OperationResult> {
  const existing = await readOperationLog(db, accountId, request.operation_id);
  if (existing !== null) {
    return replayResult(request.operation_id, existing, fingerprint);
  }
  const profileRevision = request.target.profile_revision as number;
  const row = await db
    .prepare(
      `SELECT 1 AS present FROM engine_profile
        WHERE account_id = ? AND space_id = ? AND engine_profile_id = ? AND profile_revision = ?`,
    )
    .bind(accountId, request.target.space_id, request.target.engine_profile_id, profileRevision)
    .first();
  if (row !== null) {
    // An immutable identity has no mutable revision, so the number the client
    // needs is the identity's own revision (contract 7c97146).
    throw new ApiError("REVISION_CONFLICT", { detail: { current_revision: profileRevision } });
  }
  if (await sequenceExhausted(db, accountId)) {
    throw new ApiError("STORAGE_UNAVAILABLE", { retryable: false });
  }
  throw storageUnavailable();
}

const PERSONA_SNAPSHOT_FIELD_COLUMNS: Readonly<Record<string, string>> = Object.freeze({
  description: "description_enc",
  samples: "samples_enc",
  style_guide: "style_guide_enc",
  is_enabled: "is_enabled_enc",
  content_fingerprint: "content_fingerprint_enc",
});

/**
 * Apply one validated `create_persona_snapshot`.
 *
 * This is the only operation that writes an immutable row and moves a mutable
 * pointer at once. Both, plus the persona extensions, live in one batch: a
 * snapshot whose head never advanced would be invisible, and a head pointing
 * at a row that failed to insert would violate its own foreign key.
 *
 * The head CAS reads a missing head as 0, which is exactly the value the API
 * contract gives `base_revision` before the first snapshot exists — so the
 * first create and every later one are the same predicate, not two cases.
 * The snapshot table has a BEFORE UPDATE trigger, so this INSERT never
 * carries an ON CONFLICT clause; only the head table is upserted.
 */
export async function applyCreatePersonaSnapshot(
  db: D1Database,
  auth: AuthContext,
  request: OperationRequest,
  fingerprint: string,
): Promise<OperationResult> {
  const accountId = auth.account_id;
  const spaceId = request.target.space_id;
  const personaId = request.target.persona_snapshot_id as string;
  const snapshotRevision = request.target.snapshot_revision as number;
  const baseRevision = request.base_revision as number;

  const setFields = partitionFieldNames(Object.keys(request.set), PERSONA_SNAPSHOT_FIELD_COLUMNS);
  partitionFieldNames(request.clear, PERSONA_SNAPSHOT_FIELD_COLUMNS);

  const existing = await readOperationLog(db, accountId, request.operation_id);
  if (existing !== null) {
    return replayResult(request.operation_id, existing, fingerprint);
  }

  const columns = Object.values(PERSONA_SNAPSHOT_FIELD_COLUMNS);
  const statements: D1PreparedStatement[] = [
    db
      .prepare(
        `INSERT INTO transaction_guard (account_id, operation_id, ok)
         VALUES (?, ?,
           (COALESCE((SELECT current_snapshot_revision FROM persona_snapshot_head
                       WHERE account_id = ? AND space_id = ? AND persona_snapshot_id = ?), 0) = ?
            AND (SELECT COUNT(*) FROM persona_snapshot
                  WHERE account_id = ? AND space_id = ? AND persona_snapshot_id = ?
                    AND snapshot_revision = ?) = 0
            AND (SELECT next_server_seq FROM account WHERE account_id = ?) <= ${MAX_ALLOCATABLE_SEQ}))`,
      )
      .bind(
        accountId,
        request.operation_id,
        accountId,
        spaceId,
        personaId,
        baseRevision,
        accountId,
        spaceId,
        personaId,
        snapshotRevision,
        accountId,
      ),
    db
      .prepare(
        `INSERT INTO persona_snapshot
           (account_id, space_id, persona_snapshot_id, snapshot_revision,
            owner_space_id, created_by_device_id, created_at, persona_schema_version,
            ${columns.join(", ")}, server_seq)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ${columns.map(() => "?").join(", ")}, ${CURRENT_SEQ})`,
      )
      .bind(
        accountId,
        spaceId,
        personaId,
        snapshotRevision,
        request.metadata_set["owner_space_id"],
        request.metadata_set["created_by_device_id"],
        request.metadata_set["created_at"],
        request.metadata_set["persona_schema_version"],
        ...encryptedValues(request, PERSONA_SNAPSHOT_FIELD_COLUMNS),
        accountId,
      ),
  ];

  for (const key of setFields.extensionKeys) {
    statements.push(
      db
        .prepare(
          `INSERT INTO persona_snapshot_extension_field
             (account_id, space_id, persona_snapshot_id, snapshot_revision,
              extension_key, envelope_enc)
           VALUES (?, ?, ?, ?, ?, ?)`,
        )
        .bind(
          accountId,
          spaceId,
          personaId,
          snapshotRevision,
          key,
          request.set[`${EXTENSION_PREFIX}${key}`],
        ),
    );
  }

  statements.push(
    db
      .prepare(
        `INSERT INTO persona_snapshot_head
           (account_id, space_id, persona_snapshot_id, current_snapshot_revision)
         VALUES (?, ?, ?, ?)
         ON CONFLICT (account_id, space_id, persona_snapshot_id)
         DO UPDATE SET current_snapshot_revision = excluded.current_snapshot_revision`,
      )
      .bind(accountId, spaceId, personaId, snapshotRevision),
    ...ledgerStatements(db, accountId, request, fingerprint, snapshotRevision, {
      space_id: spaceId,
      persona_snapshot_id: personaId,
      snapshot_revision: snapshotRevision,
    }),
  );

  return await runBatch(db, accountId, request, fingerprint, statements, () =>
    classifyPersonaSnapshotFailure(db, accountId, request, fingerprint, baseRevision),
  );
}

async function classifyPersonaSnapshotFailure(
  db: D1Database,
  accountId: string,
  request: OperationRequest,
  fingerprint: string,
  baseRevision: number,
): Promise<OperationResult> {
  const existing = await readOperationLog(db, accountId, request.operation_id);
  if (existing !== null) {
    return replayResult(request.operation_id, existing, fingerprint);
  }

  const spaceId = request.target.space_id;
  const personaId = request.target.persona_snapshot_id as string;
  const snapshotRevision = request.target.snapshot_revision as number;

  const duplicate = await db
    .prepare(
      `SELECT 1 AS present FROM persona_snapshot
        WHERE account_id = ? AND space_id = ? AND persona_snapshot_id = ?
          AND snapshot_revision = ?`,
    )
    .bind(accountId, spaceId, personaId, snapshotRevision)
    .first();
  if (duplicate !== null) {
    throw new ApiError("REVISION_CONFLICT", { detail: { current_revision: snapshotRevision } });
  }

  const headRow = await db
    .prepare(
      `SELECT current_snapshot_revision FROM persona_snapshot_head
        WHERE account_id = ? AND space_id = ? AND persona_snapshot_id = ?`,
    )
    .bind(accountId, spaceId, personaId)
    .first<{ current_snapshot_revision: number }>();
  const currentHead = headRow?.current_snapshot_revision ?? 0;
  if (currentHead !== baseRevision) {
    throw new ApiError("REVISION_CONFLICT", { detail: { current_revision: currentHead } });
  }

  if (await sequenceExhausted(db, accountId)) {
    throw new ApiError("STORAGE_UNAVAILABLE", { retryable: false });
  }
  throw storageUnavailable();
}

const TURN_FIELD_COLUMNS: Readonly<Record<string, string>> = Object.freeze({
  canonical_text: "canonical_text_enc",
  heart_changes: "heart_changes_enc",
  generation_profile_ref: "generation_profile_ref_enc",
  fallback_reason: "fallback_reason_enc",
});

function turnIdentity(request: OperationRequest): ChangeIdentity {
  return {
    space_id: request.target.space_id,
    room_id: request.target.room_id as string,
    worldline_key: request.worldline_key,
    turn_id: request.target.turn_id as string,
  };
}

/**
 * Upsert or delete one turn extension envelope.
 *
 * The room helper binds (account, space, room, key) and would silently address
 * a different row here: a turn extension's identity also carries the worldline
 * and the turn.
 */
function turnExtensionStatement(
  db: D1Database,
  accountId: string,
  request: OperationRequest,
  key: string,
  envelope: string | null,
): D1PreparedStatement {
  const scope = [
    accountId,
    request.target.space_id,
    request.target.room_id,
    request.worldline_key,
    request.target.turn_id,
  ];
  if (envelope === null) {
    return db
      .prepare(
        `DELETE FROM turn_extension_field
          WHERE account_id = ? AND space_id = ? AND room_id = ? AND worldline_key = ?
            AND turn_id = ? AND extension_key = ?`,
      )
      .bind(...scope, key);
  }
  return db
    .prepare(
      `INSERT INTO turn_extension_field
         (account_id, space_id, room_id, worldline_key, turn_id, extension_key, envelope_enc)
       VALUES (?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT (account_id, space_id, room_id, worldline_key, turn_id, extension_key)
       DO UPDATE SET envelope_enc = excluded.envelope_enc`,
    )
    .bind(...scope, key, envelope);
}

/** Apply one validated `create_turn`. */
export async function applyCreateTurn(
  db: D1Database,
  auth: AuthContext,
  request: OperationRequest,
  fingerprint: string,
): Promise<OperationResult> {
  const accountId = auth.account_id;
  const spaceId = request.target.space_id;
  const roomId = request.target.room_id as string;
  const key = request.worldline_key;
  const turnId = request.target.turn_id as string;

  const setFields = partitionFieldNames(Object.keys(request.set), TURN_FIELD_COLUMNS);
  partitionFieldNames(request.clear, TURN_FIELD_COLUMNS);

  const existing = await readOperationLog(db, accountId, request.operation_id);
  if (existing !== null) {
    return replayResult(request.operation_id, existing, fingerprint);
  }

  const columns = Object.values(TURN_FIELD_COLUMNS);
  const statements: D1PreparedStatement[] = [
    db
      .prepare(
        `INSERT INTO transaction_guard (account_id, operation_id, ok)
         VALUES (?, ?,
           ((SELECT COUNT(*) FROM room
              WHERE account_id = ? AND space_id = ? AND room_id = ?) = 1
            AND (SELECT COUNT(*) FROM turn
                  WHERE account_id = ? AND space_id = ? AND room_id = ? AND worldline_key = ?
                    AND turn_id = ?) = 0
            AND (SELECT next_server_seq FROM account WHERE account_id = ?) <= ${MAX_ALLOCATABLE_SEQ}))`,
      )
      .bind(
        accountId,
        request.operation_id,
        accountId,
        spaceId,
        roomId,
        accountId,
        spaceId,
        roomId,
        key,
        turnId,
        accountId,
      ),
    db
      .prepare(
        `INSERT INTO turn
           (account_id, space_id, room_id, worldline_id, worldline_key, turn_id,
            ${columns.join(", ")}, created_by_device_id, created_at,
            revision, server_seq, is_tombstoned)
         VALUES (?, ?, ?, ?, ?, ?, ${columns.map(() => "?").join(", ")}, ?, ?, 0, ${CURRENT_SEQ}, 0)`,
      )
      .bind(
        accountId,
        spaceId,
        roomId,
        request.target.worldline_id ?? null,
        key,
        turnId,
        ...encryptedValues(request, TURN_FIELD_COLUMNS),
        request.metadata_set["created_by_device_id"],
        request.metadata_set["created_at"],
        accountId,
      ),
  ];
  for (const extensionKey of setFields.extensionKeys) {
    statements.push(
      turnExtensionStatement(
        db,
        accountId,
        request,
        extensionKey,
        request.set[`${EXTENSION_PREFIX}${extensionKey}`] as string,
      ),
    );
  }
  statements.push(...ledgerStatements(db, accountId, request, fingerprint, 0, turnIdentity(request)));

  return await runBatch(db, accountId, request, fingerprint, statements, () =>
    classifyTurnCreateFailure(db, accountId, request, fingerprint),
  );
}

/** Apply one validated `patch_turn`. */
export async function applyPatchTurn(
  db: D1Database,
  auth: AuthContext,
  request: OperationRequest,
  fingerprint: string,
): Promise<OperationResult> {
  const accountId = auth.account_id;
  const spaceId = request.target.space_id;
  const roomId = request.target.room_id as string;
  const key = request.worldline_key;
  const turnId = request.target.turn_id as string;
  const baseRevision = request.base_revision as number;
  const nextRevision = baseRevision + 1;

  const setFields = partitionFieldNames(Object.keys(request.set), TURN_FIELD_COLUMNS);
  const clearFields = partitionFieldNames(request.clear, TURN_FIELD_COLUMNS);

  const existing = await readOperationLog(db, accountId, request.operation_id);
  if (existing !== null) {
    return replayResult(request.operation_id, existing, fingerprint);
  }

  const assignments: string[] = [];
  const bindings: unknown[] = [];
  for (const [name, column] of Object.entries(TURN_FIELD_COLUMNS)) {
    if (Object.prototype.hasOwnProperty.call(request.set, name)) {
      assignments.push(`${column} = ?`);
      bindings.push(request.set[name]);
    }
  }
  for (const column of clearFields.columns) {
    assignments.push(`${column} = NULL`);
  }
  assignments.push("revision = revision + 1", `server_seq = ${CURRENT_SEQ}`);
  bindings.push(accountId);

  const statements: D1PreparedStatement[] = [
    db
      .prepare(
        `INSERT INTO transaction_guard (account_id, operation_id, ok)
         VALUES (?, ?,
           ((SELECT revision FROM turn
              WHERE account_id = ? AND space_id = ? AND room_id = ? AND worldline_key = ?
                AND turn_id = ?) = ?
            AND (SELECT next_server_seq FROM account WHERE account_id = ?) <= ${MAX_ALLOCATABLE_SEQ}))`,
      )
      .bind(accountId, request.operation_id, accountId, spaceId, roomId, key, turnId, baseRevision, accountId),
    db
      .prepare(
        `UPDATE turn SET ${assignments.join(", ")}
          WHERE account_id = ? AND space_id = ? AND room_id = ? AND worldline_key = ?
            AND turn_id = ? AND revision = ?`,
      )
      .bind(...bindings, accountId, spaceId, roomId, key, turnId, baseRevision),
  ];
  for (const extensionKey of setFields.extensionKeys) {
    statements.push(
      turnExtensionStatement(
        db,
        accountId,
        request,
        extensionKey,
        request.set[`${EXTENSION_PREFIX}${extensionKey}`] as string,
      ),
    );
  }
  for (const extensionKey of clearFields.extensionKeys) {
    statements.push(turnExtensionStatement(db, accountId, request, extensionKey, null));
  }
  statements.push(
    ...ledgerStatements(db, accountId, request, fingerprint, nextRevision, turnIdentity(request)),
  );

  return await runBatch(db, accountId, request, fingerprint, statements, () =>
    classifyTurnPatchFailure(db, accountId, request, fingerprint, baseRevision),
  );
}

async function readTurnRevision(
  db: D1Database,
  accountId: string,
  request: OperationRequest,
): Promise<number | null> {
  const row = await db
    .prepare(
      `SELECT revision FROM turn
        WHERE account_id = ? AND space_id = ? AND room_id = ? AND worldline_key = ? AND turn_id = ?`,
    )
    .bind(
      accountId,
      request.target.space_id,
      request.target.room_id,
      request.worldline_key,
      request.target.turn_id,
    )
    .first<RoomRow>();
  return row === null ? null : row.revision;
}

async function classifyTurnCreateFailure(
  db: D1Database,
  accountId: string,
  request: OperationRequest,
  fingerprint: string,
): Promise<OperationResult> {
  const existing = await readOperationLog(db, accountId, request.operation_id);
  if (existing !== null) {
    return replayResult(request.operation_id, existing, fingerprint);
  }
  const roomRevision = await readRoomRevision(
    db,
    accountId,
    request.target.space_id,
    request.target.room_id as string,
  );
  if (roomRevision === null) {
    throw new ApiError("ENTITY_NOT_FOUND");
  }
  const revision = await readTurnRevision(db, accountId, request);
  if (revision !== null) {
    throw new ApiError("REVISION_CONFLICT", { detail: { current_revision: revision } });
  }
  if (await sequenceExhausted(db, accountId)) {
    throw new ApiError("STORAGE_UNAVAILABLE", { retryable: false });
  }
  throw storageUnavailable();
}

async function classifyTurnPatchFailure(
  db: D1Database,
  accountId: string,
  request: OperationRequest,
  fingerprint: string,
  baseRevision: number,
): Promise<OperationResult> {
  const existing = await readOperationLog(db, accountId, request.operation_id);
  if (existing !== null) {
    return replayResult(request.operation_id, existing, fingerprint);
  }
  const revision = await readTurnRevision(db, accountId, request);
  if (revision === null) {
    throw new ApiError("ENTITY_NOT_FOUND");
  }
  if (revision !== baseRevision) {
    throw new ApiError("REVISION_CONFLICT", { detail: { current_revision: revision } });
  }
  if (await sequenceExhausted(db, accountId)) {
    throw new ApiError("STORAGE_UNAVAILABLE", { retryable: false });
  }
  throw storageUnavailable();
}

const BUBBLE_FIELD_COLUMNS: Readonly<Record<string, string>> = Object.freeze({
  sender: "sender_enc",
  kind: "kind_enc",
  text: "text_enc",
  speaker_ref: "speaker_ref_enc",
  reactions: "reactions_enc",
});

/** The highest bubble_order a scope may ever hand out (canonical §2). */
const MAX_BUBBLE_ORDER = 9007199254740991;

function bubbleIdentity(request: OperationRequest): ChangeIdentity {
  return {
    space_id: request.target.space_id,
    room_id: request.target.room_id as string,
    worldline_key: request.worldline_key,
    turn_id: request.target.turn_id as string,
    message_id: request.target.message_id as string,
  };
}

/** Upsert or delete one bubble extension envelope, binding every owner axis. */
function bubbleExtensionStatement(
  db: D1Database,
  accountId: string,
  request: OperationRequest,
  key: string,
  envelope: string | null,
): D1PreparedStatement {
  const scope = [
    accountId,
    request.target.space_id,
    request.target.room_id,
    request.worldline_key,
    request.target.turn_id,
    request.target.message_id,
  ];
  if (envelope === null) {
    return db
      .prepare(
        `DELETE FROM bubble_extension_field
          WHERE account_id = ? AND space_id = ? AND room_id = ? AND worldline_key = ?
            AND turn_id = ? AND message_id = ? AND extension_key = ?`,
      )
      .bind(...scope, key);
  }
  return db
    .prepare(
      `INSERT INTO bubble_extension_field
         (account_id, space_id, room_id, worldline_key, turn_id, message_id,
          extension_key, envelope_enc)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT (account_id, space_id, room_id, worldline_key, turn_id, message_id, extension_key)
       DO UPDATE SET envelope_enc = excluded.envelope_enc`,
    )
    .bind(...scope, key, envelope);
}

/**
 * The order this conversation scope will accept next.
 *
 * Tombstoned rows count and turn boundaries do not: a retired number is never
 * reused (canonical §2, §9.1). `null` means the namespace is exhausted — the
 * successor would be 2^53, which is not a safe integer and must never reach a
 * client.
 */
async function expectedBubbleOrder(
  db: D1Database,
  accountId: string,
  request: OperationRequest,
): Promise<number | null> {
  const row = await db
    .prepare(
      `SELECT COALESCE(MAX(bubble_order), -1) AS highest FROM bubble
        WHERE account_id = ? AND space_id = ? AND room_id = ? AND worldline_key = ?`,
    )
    .bind(accountId, request.target.space_id, request.target.room_id, request.worldline_key)
    .first<{ highest: number }>();
  const highest = row?.highest ?? -1;
  return highest >= MAX_BUBBLE_ORDER ? null : highest + 1;
}

interface AttachmentReference {
  attachmentId: string;
  byteSize: number;
}

function attachmentReferenceOf(request: OperationRequest): AttachmentReference | null {
  const attachmentId = request.metadata_set["attachment_ref_attachment_id"];
  if (attachmentId === undefined) {
    return null;
  }
  return {
    attachmentId: attachmentId as string,
    byteSize: request.metadata_set["attachment_ref_byte_size"] as number,
  };
}

/** Apply one validated `create_bubble`. */
export async function applyCreateBubble(
  db: D1Database,
  auth: AuthContext,
  request: OperationRequest,
  fingerprint: string,
): Promise<OperationResult> {
  const accountId = auth.account_id;
  const spaceId = request.target.space_id;
  const roomId = request.target.room_id as string;
  const key = request.worldline_key;
  const turnId = request.target.turn_id as string;
  const messageId = request.target.message_id as string;
  const order = request.bubble_order as number;
  const reference = attachmentReferenceOf(request);

  const setFields = partitionFieldNames(Object.keys(request.set), BUBBLE_FIELD_COLUMNS);
  partitionFieldNames(request.clear, BUBBLE_FIELD_COLUMNS);

  const existing = await readOperationLog(db, accountId, request.operation_id);
  if (existing !== null) {
    return replayResult(request.operation_id, existing, fingerprint);
  }

  const columns = Object.values(BUBBLE_FIELD_COLUMNS);
  // Every precondition is one boolean inside the batch, so the order the
  // client proposed is checked against the same snapshot the insert uses.
  const guard = `INSERT INTO transaction_guard (account_id, operation_id, ok)
     VALUES (?, ?,
       ((SELECT COUNT(*) FROM turn
          WHERE account_id = ? AND space_id = ? AND room_id = ? AND worldline_key = ?
            AND turn_id = ?) = 1
        AND (SELECT COUNT(*) FROM bubble
              WHERE account_id = ? AND space_id = ? AND room_id = ? AND worldline_key = ?
                AND message_id = ?) = 0
        AND (SELECT COALESCE(MAX(bubble_order), -1) FROM bubble
              WHERE account_id = ? AND space_id = ? AND room_id = ? AND worldline_key = ?) = ?${
          reference === null
            ? ""
            : `
        AND (SELECT COUNT(*) FROM attachment
              WHERE account_id = ? AND attachment_id = ? AND state = 'ready'
                AND ciphertext_byte_size = ?) = 1`
        }
        AND (SELECT next_server_seq FROM account WHERE account_id = ?) <= ${MAX_ALLOCATABLE_SEQ}))`;

  const guardBindings: unknown[] = [
    accountId,
    request.operation_id,
    accountId,
    spaceId,
    roomId,
    key,
    turnId,
    accountId,
    spaceId,
    roomId,
    key,
    messageId,
    accountId,
    spaceId,
    roomId,
    key,
    order - 1,
  ];
  if (reference !== null) {
    guardBindings.push(accountId, reference.attachmentId, reference.byteSize);
  }
  guardBindings.push(accountId);

  const statements: D1PreparedStatement[] = [
    db.prepare(guard).bind(...guardBindings),
    db
      .prepare(
        `INSERT INTO bubble
           (account_id, space_id, room_id, worldline_key, turn_id, message_id, bubble_order,
            ${columns.join(", ")}, attachment_ref_attachment_id, attachment_ref_byte_size,
            timestamp, revision, server_seq, is_tombstoned)
         VALUES (?, ?, ?, ?, ?, ?, ?, ${columns.map(() => "?").join(", ")}, ?, ?, ?, 0, ${CURRENT_SEQ}, 0)`,
      )
      .bind(
        accountId,
        spaceId,
        roomId,
        key,
        turnId,
        messageId,
        order,
        ...encryptedValues(request, BUBBLE_FIELD_COLUMNS),
        reference?.attachmentId ?? null,
        reference?.byteSize ?? null,
        request.metadata_set["timestamp"],
        accountId,
      ),
  ];
  for (const extensionKey of setFields.extensionKeys) {
    statements.push(
      bubbleExtensionStatement(
        db,
        accountId,
        request,
        extensionKey,
        request.set[`${EXTENSION_PREFIX}${extensionKey}`] as string,
      ),
    );
  }
  statements.push(...ledgerStatements(db, accountId, request, fingerprint, 0, bubbleIdentity(request)));

  return await runBatch(db, accountId, request, fingerprint, statements, () =>
    classifyBubbleCreateFailure(db, accountId, request, fingerprint, reference),
  );
}

/** Apply one validated `patch_bubble`. */
export async function applyPatchBubble(
  db: D1Database,
  auth: AuthContext,
  request: OperationRequest,
  fingerprint: string,
): Promise<OperationResult> {
  const accountId = auth.account_id;
  const spaceId = request.target.space_id;
  const roomId = request.target.room_id as string;
  const key = request.worldline_key;
  const turnId = request.target.turn_id as string;
  const messageId = request.target.message_id as string;
  const baseRevision = request.base_revision as number;
  const nextRevision = baseRevision + 1;

  const setFields = partitionFieldNames(Object.keys(request.set), BUBBLE_FIELD_COLUMNS);
  const clearFields = partitionFieldNames(request.clear, BUBBLE_FIELD_COLUMNS);

  const existing = await readOperationLog(db, accountId, request.operation_id);
  if (existing !== null) {
    return replayResult(request.operation_id, existing, fingerprint);
  }

  // bubble_order, timestamp and the attachment reference are absent from the
  // assignment list by construction: the validator refuses them on the wire and
  // this loop only ever names the five encrypted columns.
  const assignments: string[] = [];
  const bindings: unknown[] = [];
  for (const [name, column] of Object.entries(BUBBLE_FIELD_COLUMNS)) {
    if (Object.prototype.hasOwnProperty.call(request.set, name)) {
      assignments.push(`${column} = ?`);
      bindings.push(request.set[name]);
    }
  }
  for (const column of clearFields.columns) {
    assignments.push(`${column} = NULL`);
  }
  assignments.push("revision = revision + 1", `server_seq = ${CURRENT_SEQ}`);
  bindings.push(accountId);

  const statements: D1PreparedStatement[] = [
    db
      .prepare(
        `INSERT INTO transaction_guard (account_id, operation_id, ok)
         VALUES (?, ?,
           ((SELECT revision FROM bubble
              WHERE account_id = ? AND space_id = ? AND room_id = ? AND worldline_key = ?
                AND turn_id = ? AND message_id = ?) = ?
            AND (SELECT next_server_seq FROM account WHERE account_id = ?) <= ${MAX_ALLOCATABLE_SEQ}))`,
      )
      .bind(
        accountId,
        request.operation_id,
        accountId,
        spaceId,
        roomId,
        key,
        turnId,
        messageId,
        baseRevision,
        accountId,
      ),
    db
      .prepare(
        `UPDATE bubble SET ${assignments.join(", ")}
          WHERE account_id = ? AND space_id = ? AND room_id = ? AND worldline_key = ?
            AND turn_id = ? AND message_id = ? AND revision = ?`,
      )
      .bind(...bindings, accountId, spaceId, roomId, key, turnId, messageId, baseRevision),
  ];
  for (const extensionKey of setFields.extensionKeys) {
    statements.push(
      bubbleExtensionStatement(
        db,
        accountId,
        request,
        extensionKey,
        request.set[`${EXTENSION_PREFIX}${extensionKey}`] as string,
      ),
    );
  }
  for (const extensionKey of clearFields.extensionKeys) {
    statements.push(bubbleExtensionStatement(db, accountId, request, extensionKey, null));
  }
  statements.push(
    ...ledgerStatements(db, accountId, request, fingerprint, nextRevision, bubbleIdentity(request)),
  );

  return await runBatch(db, accountId, request, fingerprint, statements, () =>
    classifyBubblePatchFailure(db, accountId, request, fingerprint, baseRevision),
  );
}

/**
 * The revision of the bubble at the exact identity the request named.
 *
 * A patch guard matches on all six axes, so its failure must be explained by
 * the same six. The scope-wide lookup below would find a same-message bubble
 * living under a different turn, agree about its revision, and leave the
 * caller with no reason at all — which fell through to a retryable storage
 * failure for what is really a target that does not exist.
 */
async function readBubbleRevisionByIdentity(
  db: D1Database,
  accountId: string,
  request: OperationRequest,
): Promise<number | null> {
  const row = await db
    .prepare(
      `SELECT revision FROM bubble
        WHERE account_id = ? AND space_id = ? AND room_id = ? AND worldline_key = ?
          AND turn_id = ? AND message_id = ?`,
    )
    .bind(
      accountId,
      request.target.space_id,
      request.target.room_id,
      request.worldline_key,
      request.target.turn_id,
      request.target.message_id,
    )
    .first<RoomRow>();
  return row === null ? null : row.revision;
}

async function readBubbleRevisionByMessage(
  db: D1Database,
  accountId: string,
  request: OperationRequest,
): Promise<number | null> {
  // Scoped by message_id alone: the same message in another turn of this scope
  // is still the same identity (the scope-wide UNIQUE says so).
  const row = await db
    .prepare(
      `SELECT revision FROM bubble
        WHERE account_id = ? AND space_id = ? AND room_id = ? AND worldline_key = ?
          AND message_id = ?`,
    )
    .bind(
      accountId,
      request.target.space_id,
      request.target.room_id,
      request.worldline_key,
      request.target.message_id,
    )
    .first<RoomRow>();
  return row === null ? null : row.revision;
}

async function classifyBubbleCreateFailure(
  db: D1Database,
  accountId: string,
  request: OperationRequest,
  fingerprint: string,
  reference: AttachmentReference | null,
): Promise<OperationResult> {
  const existing = await readOperationLog(db, accountId, request.operation_id);
  if (existing !== null) {
    return replayResult(request.operation_id, existing, fingerprint);
  }

  const parent = await db
    .prepare(
      `SELECT 1 AS present FROM turn
        WHERE account_id = ? AND space_id = ? AND room_id = ? AND worldline_key = ? AND turn_id = ?`,
    )
    .bind(
      accountId,
      request.target.space_id,
      request.target.room_id,
      request.worldline_key,
      request.target.turn_id,
    )
    .first();
  if (parent === null) {
    throw new ApiError("ENTITY_NOT_FOUND");
  }

  const duplicate = await readBubbleRevisionByMessage(db, accountId, request);
  if (duplicate !== null) {
    // Identity beats order: renumbering would not help a message that already
    // exists, so the client must stop rather than retry with a new order.
    throw new ApiError("REVISION_CONFLICT", { detail: { current_revision: duplicate } });
  }

  if (reference !== null) {
    const attachment = await db
      .prepare(
        "SELECT state, ciphertext_byte_size FROM attachment WHERE account_id = ? AND attachment_id = ?",
      )
      .bind(accountId, reference.attachmentId)
      .first<{ state: string; ciphertext_byte_size: number }>();
    if (attachment === null) {
      // Another account's attachment lands here too: the lookup is scoped to
      // this account, so it is simply absent.
      throw new ApiError("ENTITY_NOT_FOUND");
    }
    if (attachment.state !== "ready") {
      throw new ApiError("ATTACHMENT_STATE_CONFLICT");
    }
    if (attachment.ciphertext_byte_size !== reference.byteSize) {
      throw validationFailed();
    }
  }

  const expected = await expectedBubbleOrder(db, accountId, request);
  if (expected === null) {
    // The next order would be 2^53, which is not a safe integer. Nothing about
    // it is put in the response.
    throw new ApiError("STORAGE_UNAVAILABLE", { retryable: false });
  }
  if (expected !== request.bubble_order) {
    throw new ApiError("BUBBLE_ORDER_CONFLICT", { detail: { expected_bubble_order: expected } });
  }

  if (await sequenceExhausted(db, accountId)) {
    throw new ApiError("STORAGE_UNAVAILABLE", { retryable: false });
  }
  throw storageUnavailable();
}

async function classifyBubblePatchFailure(
  db: D1Database,
  accountId: string,
  request: OperationRequest,
  fingerprint: string,
  baseRevision: number,
): Promise<OperationResult> {
  const existing = await readOperationLog(db, accountId, request.operation_id);
  if (existing !== null) {
    return replayResult(request.operation_id, existing, fingerprint);
  }
  const revision = await readBubbleRevisionByIdentity(db, accountId, request);
  if (revision === null) {
    throw new ApiError("ENTITY_NOT_FOUND");
  }
  if (revision !== baseRevision) {
    throw new ApiError("REVISION_CONFLICT", { detail: { current_revision: revision } });
  }
  if (await sequenceExhausted(db, accountId)) {
    throw new ApiError("STORAGE_UNAVAILABLE", { retryable: false });
  }
  throw storageUnavailable();
}

/**
 * The R2 object key generator.
 *
 * The key is server-owned: it never appears in a request, a result, an error
 * detail or a log line, so a client cannot steer where bytes land. Tests
 * replace it to make a deliberate collision reproducible; nothing else does.
 */
let objectKeyUuid: () => string = () => crypto.randomUUID().toUpperCase();

/** Test seam. Pass null to restore the CSPRNG generator. */
export function setObjectKeyGeneratorForTest(generator: (() => string) | null): void {
  objectKeyUuid = generator ?? (() => crypto.randomUUID().toUpperCase());
}

const ATTACHMENT_FIELD_COLUMNS: Readonly<Record<string, string>> = Object.freeze({
  file_name: "file_name_enc",
  mime_type: "mime_type_enc",
  wrapped_file_key: "wrapped_file_key_enc",
});

/**
 * Apply one validated `create_attachment`.
 *
 * This is the only path that allocates attachment metadata: there is no
 * separate allocation endpoint, so the row, both ledgers and the sequence move
 * together like every other operation. The row starts in `allocated`; moving
 * it to `uploaded`/`ready` is the upload path's job and is not implemented
 * here. No R2 call happens in this function.
 */
export async function applyCreateAttachment(
  db: D1Database,
  auth: AuthContext,
  request: OperationRequest,
  fingerprint: string,
): Promise<OperationResult> {
  const accountId = auth.account_id;
  const attachmentId = request.target.attachment_id as string;

  columnsOnly(Object.keys(request.set), ATTACHMENT_FIELD_COLUMNS);
  columnsOnly(request.clear, ATTACHMENT_FIELD_COLUMNS);

  const existing = await readOperationLog(db, accountId, request.operation_id);
  if (existing !== null) {
    return replayResult(request.operation_id, existing, fingerprint);
  }

  const objectKey = `obj/${objectKeyUuid()}`;

  const statements: D1PreparedStatement[] = [
    db
      .prepare(
        `INSERT INTO transaction_guard (account_id, operation_id, ok)
         VALUES (?, ?,
           ((SELECT COUNT(*) FROM attachment
              WHERE account_id = ? AND attachment_id = ?) = 0
            AND (SELECT COUNT(*) FROM attachment
                  WHERE account_id = ? AND r2_object_key = ?) = 0
            AND (SELECT next_server_seq FROM account WHERE account_id = ?) <= ${MAX_ALLOCATABLE_SEQ}))`,
      )
      .bind(
        accountId,
        request.operation_id,
        accountId,
        attachmentId,
        accountId,
        objectKey,
        accountId,
      ),
    db
      .prepare(
        `INSERT INTO attachment
           (account_id, attachment_id, origin_space_id, r2_object_key, kind, state,
            source_byte_size, ciphertext_byte_size, ciphertext_hash, key_generation,
            file_name_enc, mime_type_enc, wrapped_file_key_enc, created_at, server_seq)
         VALUES (?, ?, ?, ?, ?, 'allocated', ?, ?, ?, ?, ?, ?, ?, ?, ${CURRENT_SEQ})`,
      )
      .bind(
        accountId,
        attachmentId,
        request.metadata_set["origin_space_id"],
        objectKey,
        request.metadata_set["kind"],
        request.metadata_set["source_byte_size"],
        request.metadata_set["ciphertext_byte_size"],
        request.metadata_set["ciphertext_hash"],
        request.metadata_set["key_generation"],
        request.set["file_name"],
        request.set["mime_type"],
        request.set["wrapped_file_key"],
        request.metadata_set["created_at"],
        accountId,
      ),
    ...ledgerStatements(db, accountId, request, fingerprint, null, { attachment_id: attachmentId }),
  ];

  return await runBatch(db, accountId, request, fingerprint, statements, () =>
    classifyAttachmentFailure(db, accountId, request, fingerprint, objectKey),
  );
}

async function classifyAttachmentFailure(
  db: D1Database,
  accountId: string,
  request: OperationRequest,
  fingerprint: string,
  objectKey: string,
): Promise<OperationResult> {
  const existing = await readOperationLog(db, accountId, request.operation_id);
  if (existing !== null) {
    return replayResult(request.operation_id, existing, fingerprint);
  }

  const duplicate = await db
    .prepare("SELECT 1 AS present FROM attachment WHERE account_id = ? AND attachment_id = ?")
    .bind(accountId, request.target.attachment_id)
    .first();
  if (duplicate !== null) {
    // The identity is already allocated. It is a state conflict rather than a
    // revision conflict: an attachment has no revision, and the client's next
    // move depends on what state the existing row is in.
    throw new ApiError("ATTACHMENT_STATE_CONFLICT");
  }

  const keyTaken = await db
    .prepare("SELECT 1 AS present FROM attachment WHERE account_id = ? AND r2_object_key = ?")
    .bind(accountId, objectKey)
    .first();
  if (keyTaken !== null) {
    // A server-side random collision. Retrying draws a new key, so this one is
    // retryable — and the key itself is never named in the error.
    throw storageUnavailable();
  }

  if (await sequenceExhausted(db, accountId)) {
    throw new ApiError("STORAGE_UNAVAILABLE", { retryable: false });
  }
  throw storageUnavailable();
}

const CHECKPOINT_FIELD_COLUMNS: Readonly<Record<string, string>> = Object.freeze({
  segments: "segments_enc",
  summary_text: "summary_text_enc",
  compaction_profile_id: "compaction_profile_id_enc",
  compaction_contract_fingerprint: "compaction_contract_fingerprint_enc",
});

/**
 * checkpoint's plaintext metadata columns. Provenance
 * (owner_space_id/created_by_device_id/created_at) is deliberately absent: it
 * is written once at create and the validator's patch allowlist has no way to
 * name it.
 */
const CHECKPOINT_METADATA_COLUMNS: readonly string[] = Object.freeze([
  "checkpoint_schema_version",
  "compaction_compat_tag",
  "first_turn_id",
  "last_turn_id",
  "through_server_seq",
]);

function checkpointIdentity(request: OperationRequest): ChangeIdentity {
  return {
    space_id: request.target.space_id,
    room_id: request.target.room_id as string,
    // The default scope's '' is a real identity value here: migration 0008's
    // checkpoint branch requires worldline_key NOT NULL but, unlike the
    // worldline branch, does not require it to be non-empty.
    worldline_key: request.worldline_key,
    checkpoint_id: request.target.checkpoint_id as string,
  };
}

/** The metadata value this operation leaves in `name`, given the current row. */
function finalMetadata(
  request: OperationRequest,
  name: string,
  current: string | number | null,
): string | number | null {
  if (Object.prototype.hasOwnProperty.call(request.metadata_set, name)) {
    return request.metadata_set[name] as string | number;
  }
  if (request.metadata_clear.includes(name)) {
    return null;
  }
  return current;
}

/**
 * `through_server_seq` names a sequence the account has already issued.
 *
 * The pending operation's own value is not yet issued when the batch starts,
 * so `next_server_seq` is the first inadmissible value. Checking it before the
 * batch means a bad value costs no sequence at all.
 */
async function assertThroughServerSeq(
  db: D1Database,
  accountId: string,
  value: string | number | null,
): Promise<void> {
  if (value === null) {
    return;
  }
  const account = await db
    .prepare("SELECT next_server_seq FROM account WHERE account_id = ?")
    .bind(accountId)
    .first<{ next_server_seq: number }>();
  if (account === null) {
    throw new ApiError("ENTITY_NOT_FOUND");
  }
  if (typeof value !== "number" || value < 1 || value >= account.next_server_seq) {
    throw validationFailed();
  }
}

/** Guard fragment asserting both range turns exist in the checkpoint's scope. */
function turnRangeGuard(request: OperationRequest, first: unknown, last: unknown): string | null {
  if (first === null || first === undefined) {
    return null;
  }
  void request;
  return `(SELECT COUNT(*) FROM turn
            WHERE account_id = ? AND space_id = ? AND room_id = ? AND worldline_key = ?
              AND turn_id IN (?, ?)) = (CASE WHEN ? = ? THEN 1 ELSE 2 END)`;
}

function turnRangeBindings(
  accountId: string,
  request: OperationRequest,
  first: unknown,
  last: unknown,
): unknown[] {
  if (first === null || first === undefined) {
    return [];
  }
  return [
    accountId,
    request.target.space_id,
    request.target.room_id,
    request.worldline_key,
    first,
    last,
    first,
    last,
  ];
}

async function turnRangeMissing(
  db: D1Database,
  accountId: string,
  request: OperationRequest,
  first: unknown,
  last: unknown,
): Promise<boolean> {
  if (first === null || first === undefined) {
    return false;
  }
  const expected = first === last ? 1 : 2;
  const row = await db
    .prepare(
      `SELECT COUNT(*) AS n FROM turn
        WHERE account_id = ? AND space_id = ? AND room_id = ? AND worldline_key = ?
          AND turn_id IN (?, ?)`,
    )
    .bind(accountId, request.target.space_id, request.target.room_id, request.worldline_key, first, last)
    .first<{ n: number }>();
  return (row?.n ?? 0) !== expected;
}

/** Apply one validated `create_checkpoint`. */
export async function applyCreateCheckpoint(
  db: D1Database,
  auth: AuthContext,
  request: OperationRequest,
  fingerprint: string,
): Promise<OperationResult> {
  const accountId = auth.account_id;
  const spaceId = request.target.space_id;
  const roomId = request.target.room_id as string;
  const key = request.worldline_key;
  const checkpointId = request.target.checkpoint_id as string;

  columnsOnly(Object.keys(request.set), CHECKPOINT_FIELD_COLUMNS);
  columnsOnly(request.clear, CHECKPOINT_FIELD_COLUMNS);

  const first = finalMetadata(request, "first_turn_id", null);
  const last = finalMetadata(request, "last_turn_id", null);
  const through = finalMetadata(request, "through_server_seq", null);
  await assertThroughServerSeq(db, accountId, through);

  const existing = await readOperationLog(db, accountId, request.operation_id);
  if (existing !== null) {
    return replayResult(request.operation_id, existing, fingerprint);
  }

  const rangeGuard = turnRangeGuard(request, first, last);
  const statements: D1PreparedStatement[] = [
    db
      .prepare(
        `INSERT INTO transaction_guard (account_id, operation_id, ok)
         VALUES (?, ?,
           ((SELECT COUNT(*) FROM room
              WHERE account_id = ? AND space_id = ? AND room_id = ?) = 1
            AND (SELECT COUNT(*) FROM checkpoint
                  WHERE account_id = ? AND space_id = ? AND room_id = ? AND worldline_key = ?
                    AND checkpoint_id = ?) = 0${rangeGuard === null ? "" : `
            AND ${rangeGuard}`}
            AND (SELECT next_server_seq FROM account WHERE account_id = ?) <= ${MAX_ALLOCATABLE_SEQ}))`,
      )
      .bind(
        accountId,
        request.operation_id,
        accountId,
        spaceId,
        roomId,
        accountId,
        spaceId,
        roomId,
        key,
        checkpointId,
        ...turnRangeBindings(accountId, request, first, last),
        accountId,
      ),
    db
      .prepare(
        `INSERT INTO checkpoint
           (account_id, space_id, room_id, worldline_id, worldline_key, checkpoint_id,
            first_turn_id, last_turn_id, through_server_seq,
            segments_enc, summary_text_enc, checkpoint_schema_version,
            compaction_profile_id_enc, compaction_contract_fingerprint_enc,
            compaction_compat_tag, owner_space_id, created_by_device_id, created_at,
            revision, server_seq)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ${CURRENT_SEQ})`,
      )
      .bind(
        accountId,
        spaceId,
        roomId,
        request.target.worldline_id ?? null,
        key,
        checkpointId,
        first,
        last,
        through,
        request.set["segments"] ?? null,
        request.set["summary_text"] ?? null,
        request.metadata_set["checkpoint_schema_version"],
        request.set["compaction_profile_id"] ?? null,
        request.set["compaction_contract_fingerprint"] ?? null,
        request.metadata_set["compaction_compat_tag"] ?? null,
        request.metadata_set["owner_space_id"],
        request.metadata_set["created_by_device_id"],
        request.metadata_set["created_at"],
        accountId,
      ),
    ...ledgerStatements(db, accountId, request, fingerprint, 0, checkpointIdentity(request)),
  ];

  return await runBatch(db, accountId, request, fingerprint, statements, () =>
    classifyCheckpointCreateFailure(db, accountId, request, fingerprint, first, last),
  );
}

/** Apply one validated `patch_checkpoint`. */
export async function applyPatchCheckpoint(
  db: D1Database,
  auth: AuthContext,
  request: OperationRequest,
  fingerprint: string,
): Promise<OperationResult> {
  const accountId = auth.account_id;
  const spaceId = request.target.space_id;
  const roomId = request.target.room_id as string;
  const key = request.worldline_key;
  const checkpointId = request.target.checkpoint_id as string;
  const baseRevision = request.base_revision as number;
  const nextRevision = baseRevision + 1;

  const clearColumns = columnsOnly(request.clear, CHECKPOINT_FIELD_COLUMNS);
  columnsOnly(Object.keys(request.set), CHECKPOINT_FIELD_COLUMNS);

  const current = await db
    .prepare(
      `SELECT first_turn_id, last_turn_id, through_server_seq FROM checkpoint
        WHERE account_id = ? AND space_id = ? AND room_id = ? AND worldline_key = ?
          AND checkpoint_id = ?`,
    )
    .bind(accountId, spaceId, roomId, key, checkpointId)
    .first<{
      first_turn_id: string | null;
      last_turn_id: string | null;
      through_server_seq: number | null;
    }>();

  const first = finalMetadata(request, "first_turn_id", current?.first_turn_id ?? null);
  const last = finalMetadata(request, "last_turn_id", current?.last_turn_id ?? null);
  // The bound is the final stored value, so a patch that leaves the field
  // alone keeps whatever was already accepted.
  await assertThroughServerSeq(
    db,
    accountId,
    finalMetadata(request, "through_server_seq", current?.through_server_seq ?? null),
  );

  const existing = await readOperationLog(db, accountId, request.operation_id);
  if (existing !== null) {
    return replayResult(request.operation_id, existing, fingerprint);
  }

  const assignments: string[] = [];
  const bindings: unknown[] = [];
  for (const [name, column] of Object.entries(CHECKPOINT_FIELD_COLUMNS)) {
    if (Object.prototype.hasOwnProperty.call(request.set, name)) {
      assignments.push(`${column} = ?`);
      bindings.push(request.set[name]);
    }
  }
  for (const column of clearColumns) {
    assignments.push(`${column} = NULL`);
  }
  for (const name of CHECKPOINT_METADATA_COLUMNS) {
    if (Object.prototype.hasOwnProperty.call(request.metadata_set, name)) {
      assignments.push(`${name} = ?`);
      bindings.push(request.metadata_set[name]);
    } else if (request.metadata_clear.includes(name)) {
      assignments.push(`${name} = NULL`);
    }
  }
  assignments.push("revision = revision + 1", `server_seq = ${CURRENT_SEQ}`);
  bindings.push(accountId);

  const rangeGuard = turnRangeGuard(request, first, last);
  const statements: D1PreparedStatement[] = [
    db
      .prepare(
        `INSERT INTO transaction_guard (account_id, operation_id, ok)
         VALUES (?, ?,
           ((SELECT revision FROM checkpoint
              WHERE account_id = ? AND space_id = ? AND room_id = ? AND worldline_key = ?
                AND checkpoint_id = ?) = ?${rangeGuard === null ? "" : `
            AND ${rangeGuard}`}
            AND (SELECT next_server_seq FROM account WHERE account_id = ?) <= ${MAX_ALLOCATABLE_SEQ}))`,
      )
      .bind(
        accountId,
        request.operation_id,
        accountId,
        spaceId,
        roomId,
        key,
        checkpointId,
        baseRevision,
        ...turnRangeBindings(accountId, request, first, last),
        accountId,
      ),
    db
      .prepare(
        `UPDATE checkpoint SET ${assignments.join(", ")}
          WHERE account_id = ? AND space_id = ? AND room_id = ? AND worldline_key = ?
            AND checkpoint_id = ? AND revision = ?`,
      )
      .bind(...bindings, accountId, spaceId, roomId, key, checkpointId, baseRevision),
    ...ledgerStatements(db, accountId, request, fingerprint, nextRevision, checkpointIdentity(request)),
  ];

  return await runBatch(db, accountId, request, fingerprint, statements, () =>
    classifyCheckpointPatchFailure(db, accountId, request, fingerprint, baseRevision, first, last),
  );
}

async function readCheckpointRevision(
  db: D1Database,
  accountId: string,
  request: OperationRequest,
): Promise<number | null> {
  const row = await db
    .prepare(
      `SELECT revision FROM checkpoint
        WHERE account_id = ? AND space_id = ? AND room_id = ? AND worldline_key = ?
          AND checkpoint_id = ?`,
    )
    .bind(
      accountId,
      request.target.space_id,
      request.target.room_id,
      request.worldline_key,
      request.target.checkpoint_id,
    )
    .first<RoomRow>();
  return row === null ? null : row.revision;
}

async function classifyCheckpointCreateFailure(
  db: D1Database,
  accountId: string,
  request: OperationRequest,
  fingerprint: string,
  first: unknown,
  last: unknown,
): Promise<OperationResult> {
  const existing = await readOperationLog(db, accountId, request.operation_id);
  if (existing !== null) {
    return replayResult(request.operation_id, existing, fingerprint);
  }
  const roomRevision = await readRoomRevision(
    db,
    accountId,
    request.target.space_id,
    request.target.room_id as string,
  );
  if (roomRevision === null) {
    throw new ApiError("ENTITY_NOT_FOUND");
  }
  const revision = await readCheckpointRevision(db, accountId, request);
  if (revision !== null) {
    throw new ApiError("REVISION_CONFLICT", { detail: { current_revision: revision } });
  }
  if (await turnRangeMissing(db, accountId, request, first, last)) {
    throw new ApiError("ENTITY_NOT_FOUND");
  }
  if (await sequenceExhausted(db, accountId)) {
    throw new ApiError("STORAGE_UNAVAILABLE", { retryable: false });
  }
  throw storageUnavailable();
}

async function classifyCheckpointPatchFailure(
  db: D1Database,
  accountId: string,
  request: OperationRequest,
  fingerprint: string,
  baseRevision: number,
  first: unknown,
  last: unknown,
): Promise<OperationResult> {
  const existing = await readOperationLog(db, accountId, request.operation_id);
  if (existing !== null) {
    return replayResult(request.operation_id, existing, fingerprint);
  }
  const revision = await readCheckpointRevision(db, accountId, request);
  if (revision === null) {
    throw new ApiError("ENTITY_NOT_FOUND");
  }
  if (revision !== baseRevision) {
    throw new ApiError("REVISION_CONFLICT", { detail: { current_revision: revision } });
  }
  if (await turnRangeMissing(db, accountId, request, first, last)) {
    throw new ApiError("ENTITY_NOT_FOUND");
  }
  if (await sequenceExhausted(db, accountId)) {
    throw new ApiError("STORAGE_UNAVAILABLE", { retryable: false });
  }
  throw storageUnavailable();
}

interface BatchInput {
  db: D1Database;
  accountId: string;
  spaceId: string;
  roomId: string;
  request: OperationRequest;
  fingerprint: string;
  baseRevision: number;
  nextRevision: number;
  setFields: { columns: string[]; extensionKeys: string[] };
  clearFields: { columns: string[]; extensionKeys: string[] };
  currentRef: RefRow | null;
}

function buildBatch(input: BatchInput): D1PreparedStatement[] {
  const { db, accountId, spaceId, roomId, request, fingerprint, baseRevision, nextRevision } = input;
  const statements: D1PreparedStatement[] = [];

  // 1. Guard. Room existence, the CAS and the sequence sentinel are one
  //    boolean: false is a CHECK violation and a missing row is a NOT NULL
  //    violation, and either aborts the whole batch.
  statements.push(
    db
      .prepare(
        `INSERT INTO transaction_guard (account_id, operation_id, ok)
         VALUES (?, ?,
           ((SELECT revision FROM room
              WHERE account_id = ? AND space_id = ? AND room_id = ?) = ?
            AND (SELECT next_server_seq FROM account WHERE account_id = ?) <= ${MAX_ALLOCATABLE_SEQ}))`,
      )
      .bind(accountId, request.operation_id, accountId, spaceId, roomId, baseRevision, accountId),
  );

  // 2. Room body. Even an operation that only moves an extension or a
  //    reference advances the room's own revision and sequence, because those
  //    rows have no revision of their own.
  const assignments: string[] = [];
  const roomBindings: unknown[] = [];
  for (const [name, column] of Object.entries(ROOM_FIELD_COLUMNS)) {
    if (Object.prototype.hasOwnProperty.call(request.set, name)) {
      assignments.push(`${column} = ?`);
      roomBindings.push(request.set[name]);
    }
  }
  for (const column of input.clearFields.columns) {
    assignments.push(`${column} = NULL`);
  }
  assignments.push("revision = revision + 1", `server_seq = ${CURRENT_SEQ}`, "updated_at = ?");
  roomBindings.push(accountId, request.created_at);
  statements.push(
    db
      .prepare(
        `UPDATE room SET ${assignments.join(", ")}
          WHERE account_id = ? AND space_id = ? AND room_id = ? AND revision = ?`,
      )
      .bind(...roomBindings, accountId, spaceId, roomId, baseRevision),
  );

  // 3. Extensions. The stored key drops the `extensions.` wire prefix; the key
  //    is always a bound value, never part of the statement text.
  for (const key of input.setFields.extensionKeys) {
    statements.push(
      db
        .prepare(
          `INSERT INTO room_extension_field
             (account_id, space_id, room_id, extension_key, envelope_enc)
           VALUES (?, ?, ?, ?, ?)
           ON CONFLICT (account_id, space_id, room_id, extension_key)
           DO UPDATE SET envelope_enc = excluded.envelope_enc`,
        )
        .bind(accountId, spaceId, roomId, key, request.set[`${EXTENSION_PREFIX}${key}`]),
    );
  }
  for (const key of input.clearFields.extensionKeys) {
    statements.push(
      db
        .prepare(
          `DELETE FROM room_extension_field
            WHERE account_id = ? AND space_id = ? AND room_id = ? AND extension_key = ?`,
        )
        .bind(accountId, spaceId, roomId, key),
    );
  }

  // 4. AI references. The pair rules were already enforced by the validator;
  //    here the resulting row is computed from the current one so setting or
  //    clearing one pair cannot disturb the other.
  const refStatement = buildRefStatement(input);
  if (refStatement !== null) {
    statements.push(refStatement);
  }

  // 5-6. The two ledgers, both taking the sequence the account still holds.
  statements.push(
    db
      .prepare(
        `INSERT INTO operation_log
           (account_id, operation_id, request_fingerprint, entity_type, change_kind,
            result_revision, server_seq)
         VALUES (?, ?, ?, 'room', 'upsert', ?, ${CURRENT_SEQ})`,
      )
      .bind(accountId, request.operation_id, fingerprint, nextRevision, accountId),
  );
  statements.push(
    db
      .prepare(
        `INSERT INTO change_log
           (account_id, server_seq, entity_type, change_kind, revision, space_id, room_id)
         VALUES (?, ${CURRENT_SEQ}, 'room', 'upsert', ?, ?, ?)`,
      )
      .bind(accountId, accountId, nextRevision, spaceId, roomId),
  );

  // 7-8. Consume the sequence and drop the guard. A failed batch reaches
  //      neither, so a refused operation costs no sequence value.
  statements.push(
    db
      .prepare("UPDATE account SET next_server_seq = next_server_seq + 1 WHERE account_id = ?")
      .bind(accountId),
  );
  statements.push(
    db
      .prepare("DELETE FROM transaction_guard WHERE account_id = ? AND operation_id = ?")
      .bind(accountId, request.operation_id),
  );

  return statements;
}

function buildRefStatement(input: BatchInput): D1PreparedStatement | null {
  const { db, accountId, spaceId, roomId, request, currentRef } = input;
  const set = request.metadata_set;
  const clear = new Set(request.metadata_clear);
  if (Object.keys(set).length === 0 && clear.size === 0) {
    return null;
  }

  function resolve(field: keyof RefRow): string | number | null {
    if (Object.prototype.hasOwnProperty.call(set, field)) {
      return set[field] as string | number;
    }
    if (clear.has(field)) {
      return null;
    }
    return currentRef?.[field] ?? null;
  }

  const engineId = resolve("engine_profile_id");
  const engineRevision = resolve("engine_profile_revision");
  const personaId = resolve("persona_snapshot_id");
  const personaRevision = resolve("persona_snapshot_revision");

  if (engineId === null && personaId === null) {
    // An all-null side table row carries nothing; deleting it keeps the 1:1
    // table meaning "this room references AI state". A clear against a room
    // that has no row at all is then a no-op rather than an error.
    return db
      .prepare(
        `DELETE FROM room_ai_state_ref
          WHERE account_id = ? AND space_id = ? AND room_id = ?`,
      )
      .bind(accountId, spaceId, roomId);
  }

  return db
    .prepare(
      `INSERT INTO room_ai_state_ref
         (account_id, space_id, room_id, engine_profile_id, engine_profile_revision,
          persona_snapshot_id, persona_snapshot_revision)
       VALUES (?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT (account_id, space_id, room_id) DO UPDATE SET
         engine_profile_id = excluded.engine_profile_id,
         engine_profile_revision = excluded.engine_profile_revision,
         persona_snapshot_id = excluded.persona_snapshot_id,
         persona_snapshot_revision = excluded.persona_snapshot_revision`,
    )
    .bind(accountId, spaceId, roomId, engineId, engineRevision, personaId, personaRevision);
}

/**
 * Re-derive why the batch aborted, by reading storage rather than by reading
 * the D1 error. Every branch is a fresh query, so the answer does not depend on
 * a driver message that could change or could quote content.
 */
async function classifyFailure(
  db: D1Database,
  accountId: string,
  request: OperationRequest,
  fingerprint: string,
  baseRevision: number,
): Promise<OperationResult> {
  const existing = await readOperationLog(db, accountId, request.operation_id);
  if (existing !== null) {
    // Two identical requests raced and the other one won: this is a replay.
    return replayResult(request.operation_id, existing, fingerprint);
  }

  const room = await db
    .prepare("SELECT revision FROM room WHERE account_id = ? AND space_id = ? AND room_id = ?")
    .bind(accountId, request.target.space_id, request.target.room_id)
    .first<RoomRow>();
  if (room === null) {
    throw new ApiError("ENTITY_NOT_FOUND");
  }
  if (room.revision !== baseRevision) {
    // `current_revision` is a number, which is the one kind of detail §2.3
    // allows: it is not derived from plaintext.
    throw new ApiError("REVISION_CONFLICT", { detail: { current_revision: room.revision } });
  }

  const account = await db
    .prepare("SELECT next_server_seq FROM account WHERE account_id = ?")
    .bind(accountId)
    .first<{ next_server_seq: number }>();
  if (account === null) {
    throw new ApiError("ENTITY_NOT_FOUND");
  }
  if (account.next_server_seq >= EXHAUSTED_SENTINEL) {
    // Exhausted, not transient: retrying cannot help, so it is not retryable.
    throw new ApiError("STORAGE_UNAVAILABLE", { retryable: false });
  }

  if (await referencedAiStateMissing(db, accountId, request)) {
    throw new ApiError("ENTITY_NOT_FOUND");
  }

  throw storageUnavailable();
}

async function referencedAiStateMissing(
  db: D1Database,
  accountId: string,
  request: OperationRequest,
): Promise<boolean> {
  const set = request.metadata_set;
  const spaceId = request.target.space_id;

  if (set.engine_profile_id !== undefined) {
    const row = await db
      .prepare(
        `SELECT 1 AS present FROM engine_profile
          WHERE account_id = ? AND space_id = ? AND engine_profile_id = ? AND profile_revision = ?`,
      )
      .bind(accountId, spaceId, set.engine_profile_id, set.engine_profile_revision)
      .first();
    if (row === null) {
      return true;
    }
  }
  if (set.persona_snapshot_id !== undefined) {
    const row = await db
      .prepare(
        `SELECT 1 AS present FROM persona_snapshot
          WHERE account_id = ? AND space_id = ? AND persona_snapshot_id = ? AND snapshot_revision = ?`,
      )
      .bind(accountId, spaceId, set.persona_snapshot_id, set.persona_snapshot_revision)
      .first();
    if (row === null) {
      return true;
    }
  }
  return false;
}
