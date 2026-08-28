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
function partitionFieldNames(names: readonly string[]): {
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
    const column = ROOM_FIELD_COLUMNS[name];
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
  const setFields = partitionFieldNames(setNames);
  const clearFields = partitionFieldNames(request.clear);

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
  return [
    db
      .prepare(
        `INSERT INTO operation_log
           (account_id, operation_id, request_fingerprint, entity_type, change_kind,
            result_revision, server_seq)
         VALUES (?, ?, ?, 'room', 'upsert', ?, ${CURRENT_SEQ})`,
      )
      .bind(accountId, request.operation_id, fingerprint, revision, accountId),
    db
      .prepare(
        `INSERT INTO change_log
           (account_id, server_seq, entity_type, change_kind, revision, space_id, room_id)
         VALUES (?, ${CURRENT_SEQ}, 'room', 'upsert', ?, ?, ?)`,
      )
      .bind(accountId, accountId, revision, spaceId, roomId),
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

  const setFields = partitionFieldNames(Object.keys(request.set));
  // A clear on a row that does not exist yet is just the absent value; the
  // partition still runs so an unmapped name is refused rather than ignored.
  partitionFieldNames(request.clear);

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
