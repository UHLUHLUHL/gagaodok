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
function ledgerStatements(
  db: D1Database,
  accountId: string,
  request: OperationRequest,
  fingerprint: string,
  revision: number,
): D1PreparedStatement[] {
  const spaceId = request.target.space_id;
  const roomId = request.target.room_id as string;
  // The worldline axis belongs to the change identity only for entities whose
  // storage key has one. migration 0008 states the same rule as a CHECK: the
  // room and group_state branches require worldline_key IS NULL, the worldline
  // branch requires it non-null and non-empty.
  const identityWorldlineKey =
    getEntityShape(getOperationSpec(request.op).entityType).worldlineRule === "required"
      ? request.worldline_key
      : null;
  // The entity_type comes from the validator's operation table, never from a
  // literal spelled out per handler, so the two ledgers can never disagree
  // about what a given operation wrote.
  const entityType = getOperationSpec(request.op).entityType;
  return [
    db
      .prepare(
        `INSERT INTO operation_log
           (account_id, operation_id, request_fingerprint, entity_type, change_kind,
            result_revision, server_seq)
         VALUES (?, ?, ?, ?, 'upsert', ?, ${CURRENT_SEQ})`,
      )
      .bind(accountId, request.operation_id, fingerprint, entityType, revision, accountId),
    identityWorldlineKey === null
      ? db
          .prepare(
            `INSERT INTO change_log
               (account_id, server_seq, entity_type, change_kind, revision, space_id, room_id)
             VALUES (?, ${CURRENT_SEQ}, ?, 'upsert', ?, ?, ?)`,
          )
          .bind(accountId, accountId, entityType, revision, spaceId, roomId)
      : db
          .prepare(
            `INSERT INTO change_log
               (account_id, server_seq, entity_type, change_kind, revision,
                space_id, room_id, worldline_key)
             VALUES (?, ${CURRENT_SEQ}, ?, 'upsert', ?, ?, ?, ?)`,
          )
          .bind(accountId, accountId, entityType, revision, spaceId, roomId, identityWorldlineKey),
    db
      .prepare("UPDATE account SET next_server_seq = next_server_seq + 1 WHERE account_id = ?")
      .bind(accountId),
    db
      .prepare("DELETE FROM transaction_guard WHERE account_id = ? AND operation_id = ?")
      .bind(accountId, request.operation_id),
  ];
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
  statements.push(...ledgerStatements(db, accountId, request, fingerprint, 0));

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
    ...ledgerStatements(db, accountId, request, fingerprint, 0),
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
    ...ledgerStatements(db, accountId, request, fingerprint, nextRevision),
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
    ...ledgerStatements(db, accountId, request, fingerprint, 0),
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
    ...ledgerStatements(db, accountId, request, fingerprint, nextRevision),
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
