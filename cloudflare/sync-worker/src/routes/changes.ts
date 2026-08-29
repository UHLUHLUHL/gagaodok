import { authenticateDevice } from "../auth/deviceToken";
import { ApiError, PROTOCOL_VERSION, validationFailed } from "../contracts/error";
import {
  readChangeProjections,
  requireProjection,
  storageKeyOfChange,
} from "../sync/projection";
import type { ChangeRow, EntityType } from "../sync/projection";
import type { Env } from "../env";

/**
 * `GET /v1/sync/changes` — the account cursor (API draft 4.2).
 *
 * A read, and an account-wide one: unlike every write path there is no
 * registered-space equality here. A phone that may not write a MAC_SPACE row
 * still has to learn that the Mac changed it, or the two devices could never
 * converge.
 */

/** One canonical spelling per number: no sign, no leading zero, no exponent. */
const CANONICAL_DECIMAL = /^(?:0|[1-9][0-9]*)$/;

const MAX_SEQ = 9007199254740991;
const DEFAULT_LIMIT = 100;
const MAX_LIMIT = 500;

const QUERY_PARAMETERS = new Set(["after_seq", "limit"]);

interface ChangesQuery {
  afterSeq: number;
  limit: number;
}

/**
 * Read exactly the two parameters this endpoint has, and refuse everything
 * else.
 *
 * Strictness is the point. A misspelled `after_sec` that is quietly ignored
 * looks like a working cursor that silently restarts from zero every call,
 * and a repeated parameter leaves the server choosing which copy it meant.
 */
function parseQuery(url: URL): ChangesQuery {
  for (const name of url.searchParams.keys()) {
    if (!QUERY_PARAMETERS.has(name)) {
      throw validationFailed();
    }
  }
  return {
    afterSeq: readNumber(url, "after_seq", 0, 0, MAX_SEQ),
    limit: readNumber(url, "limit", DEFAULT_LIMIT, 1, MAX_LIMIT),
  };
}

function readNumber(url: URL, name: string, fallback: number, low: number, high: number): number {
  const values = url.searchParams.getAll(name);
  if (values.length === 0) {
    return fallback;
  }
  if (values.length > 1) {
    // Two spellings of the same parameter have no single meaning.
    throw validationFailed();
  }
  const raw = values[0] as string;
  if (!CANONICAL_DECIMAL.test(raw)) {
    throw validationFailed();
  }
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < low || value > high) {
    throw validationFailed();
  }
  return value;
}

function storageUnavailable(): ApiError {
  return new ApiError("STORAGE_UNAVAILABLE", { retryable: true });
}

const CHANGE_COLUMNS = `server_seq, entity_type, change_kind, revision,
                        space_id, room_id, worldline_key, turn_id, message_id,
                        persona_snapshot_id, snapshot_revision,
                        engine_profile_id, profile_revision,
                        checkpoint_id, attachment_id`;

interface WatermarkRow {
  watermark: number;
}

/**
 * Take the high watermark and the page in one `batch()`.
 *
 * `batch()` is a single transaction, so both statements see the same snapshot.
 * That is what makes the cursor safe to advance: a write that lands while this
 * request is running raises `next_server_seq`, but it cannot appear inside a
 * page whose ceiling was fixed before it committed, and the client will still
 * see it on the next call.
 *
 * The page's ceiling is the watermark expression itself rather than a value
 * read first and bound second, because reading it in a separate round trip is
 * exactly where the two could drift apart.
 */
async function readPage(
  db: D1Database,
  accountId: string,
  afterSeq: number,
  limit: number,
): Promise<{ watermark: number; rows: ChangeRow[] }> {
  let results: [D1Result<WatermarkRow>, D1Result<ChangeRow>];
  try {
    results = (await db.batch([
      db
        .prepare("SELECT next_server_seq - 1 AS watermark FROM account WHERE account_id = ?")
        .bind(accountId),
      db
        .prepare(
          `SELECT ${CHANGE_COLUMNS}
             FROM change_log
            WHERE account_id = ?
              AND server_seq > ?
              AND server_seq <= (SELECT next_server_seq - 1 FROM account WHERE account_id = ?)
            ORDER BY server_seq ASC
            LIMIT ?`,
        )
        // One more than asked for, so `has_more` is an observed row rather
        // than a guess from the page being full. A gap in the sequence is not
        // "more" — an operation that rolled back consumed nothing.
        .bind(accountId, afterSeq, accountId, limit + 1),
    ])) as [D1Result<WatermarkRow>, D1Result<ChangeRow>];
  } catch {
    throw storageUnavailable();
  }

  const account = results[0].results[0];
  if (account === undefined) {
    // The token resolved to an account, so its row missing here is a storage
    // condition rather than an answer about the request.
    throw storageUnavailable();
  }
  return { watermark: account.watermark, rows: results[1].results };
}

export interface ChangeItem {
  change_seq: number;
  entity_type: EntityType;
  change_kind: string;
  revision: number | null;
  identity: Record<string, string | number | null>;
  projection: Record<string, unknown>;
}

export interface ChangesResult {
  scanned_through_seq: number;
  account_high_watermark_seq: number;
  has_more: boolean;
  changes: ChangeItem[];
}

async function readChanges(request: Request, env: Env): Promise<ChangesResult> {
  const auth = await authenticateDevice(request, env.DB);
  const query = parseQuery(new URL(request.url));

  const { watermark, rows } = await readPage(env.DB, auth.account_id, query.afterSeq, query.limit);
  if (query.afterSeq > watermark) {
    // A cursor ahead of the account's own sequence is not a position this
    // server ever issued.
    throw validationFailed();
  }

  const hasMore = rows.length > query.limit;
  const page = hasMore ? rows.slice(0, query.limit) : rows;
  const lastRow = page[page.length - 1];

  // With nothing left behind the page, the cursor may advance all the way to
  // the ceiling this request fixed — including for an empty page, where the
  // client has now seen everything up to the watermark. When the page was cut
  // short it advances only as far as the last event actually returned.
  const scannedThrough = hasMore ? (lastRow as ChangeRow).server_seq : watermark;

  const projections = await readChangeProjections(
    env.DB,
    auth.account_id,
    query.afterSeq,
    lastRow === undefined ? query.afterSeq : lastRow.server_seq,
  );

  const changes = page.map((row) => {
    const storageKey = storageKeyOfChange(row);
    const projected = requireProjection(
      projections,
      row.entity_type as EntityType,
      storageKey,
    );
    return {
      change_seq: row.server_seq,
      entity_type: projected.entity_type,
      change_kind: row.change_kind,
      revision: row.revision,
      identity: projected.identity,
      // One row per change, even when several changes share an identity: the
      // client replays the ledger in order, and collapsing them here would
      // hide the order it needs.
      projection: projected.projection,
    };
  });

  return {
    scanned_through_seq: scannedThrough,
    account_high_watermark_seq: watermark,
    has_more: hasMore,
    changes,
  };
}

/**
 * `GET /v1/sync/changes`.
 *
 * The request id is generated here rather than taken from the caller: this
 * endpoint has no client operation id, and echoing something the client chose
 * would put an unvalidated string in every log line and error body. The same
 * id travels with the success envelope and with any failure, so a client
 * report and a server log can be lined up.
 */
export async function handleChangesRequest(request: Request, env: Env): Promise<Response> {
  const requestId = crypto.randomUUID().toUpperCase();
  try {
    const result = await readChanges(request, env);
    return Response.json({
      protocol_version: PROTOCOL_VERSION,
      request_id: requestId,
      result,
    });
  } catch (error) {
    if (error instanceof ApiError) {
      return error.toResponse(requestId);
    }
    return new ApiError("INTERNAL_ERROR").toResponse(requestId);
  }
}
