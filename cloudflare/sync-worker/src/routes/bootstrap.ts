import { authenticateDevice } from "../auth/deviceToken";
import { ApiError, PROTOCOL_VERSION, validationFailed } from "../contracts/error";
import { issueCursor, verifyCursor } from "../sync/bootstrapCursor";
import { BOOTSTRAP_ENTITY_ORDER, readBootstrapPage } from "../sync/projection";
import type { ProjectedEntity, StorageKey } from "../sync/projection";
import type { Env } from "../env";

/**
 * `GET /v1/sync/bootstrap` — the first full read (API draft 4.3).
 *
 * Like the cursor endpoint this is account-wide: a new device downloads the
 * whole account, not the slice of it its own space may write.
 */

const CANONICAL_DECIMAL = /^(?:0|[1-9][0-9]*)$/;
const DEFAULT_LIMIT = 200;
const MAX_LIMIT = 500;
const QUERY_PARAMETERS = new Set(["cursor", "limit"]);

interface BootstrapQuery {
  cursor: string | null;
  limit: number;
}

function parseQuery(url: URL): BootstrapQuery {
  for (const name of url.searchParams.keys()) {
    if (!QUERY_PARAMETERS.has(name)) {
      throw validationFailed();
    }
  }
  return { cursor: readCursor(url), limit: readLimit(url) };
}

function readCursor(url: URL): string | null {
  const values = url.searchParams.getAll("cursor");
  if (values.length === 0) {
    return null;
  }
  if (values.length > 1) {
    throw validationFailed();
  }
  const value = values[0] as string;
  if (value.length === 0) {
    throw validationFailed();
  }
  return value;
}

function readLimit(url: URL): number {
  const values = url.searchParams.getAll("limit");
  if (values.length === 0) {
    return DEFAULT_LIMIT;
  }
  if (values.length > 1) {
    throw validationFailed();
  }
  const raw = values[0] as string;
  if (!CANONICAL_DECIMAL.test(raw)) {
    throw validationFailed();
  }
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < 1 || value > MAX_LIMIT) {
    throw validationFailed();
  }
  return value;
}

function storageUnavailable(): ApiError {
  return new ApiError("STORAGE_UNAVAILABLE", { retryable: true });
}

/** The account's own sequence, fixed once as the snapshot's watermark. */
async function readWatermark(db: D1Database, accountId: string): Promise<number> {
  let row: { watermark: number } | null;
  try {
    row = await db
      .prepare("SELECT next_server_seq - 1 AS watermark FROM account WHERE account_id = ?")
      .bind(accountId)
      .first<{ watermark: number }>();
  } catch {
    throw storageUnavailable();
  }
  if (row === null) {
    throw storageUnavailable();
  }
  return row.watermark;
}

export interface BootstrapItem {
  entity_type: string;
  identity: Record<string, string | number | null>;
  projection: Record<string, unknown>;
}

export interface BootstrapResult {
  snapshot_high_watermark_seq: number;
  has_more: boolean;
  next_cursor: string | null;
  items: BootstrapItem[];
}

async function readBootstrap(request: Request, env: Env): Promise<BootstrapResult> {
  const auth = await authenticateDevice(request, env.DB);
  const query = parseQuery(new URL(request.url));

  // A resumed bootstrap keeps the first page's watermark. Re-reading it would
  // silently move the snapshot under the client, and the changes cursor it
  // starts from afterwards would then skip whatever landed in between.
  const position =
    query.cursor === null
      ? { watermark: await readWatermark(env.DB, auth.account_id), entityIndex: 0, storageKey: null }
      : await resume(env, auth.account_id, query.cursor);

  const items: ProjectedEntity[] = [];
  let entityIndex = position.entityIndex;
  let afterKey: StorageKey | null = position.storageKey;
  let lastEntityIndex = position.entityIndex;
  let lastKey: StorageKey | null = null;
  let hasMore = false;

  while (entityIndex < BOOTSTRAP_ENTITY_ORDER.length) {
    const wanted = query.limit - items.length;
    // One more than needed, so the end of a page is an observed row rather
    // than an inference from the page being full. With `wanted` at zero this
    // is a single-row probe: it answers "is there anything left" without
    // returning it.
    const page = await readBootstrapPage(
      env.DB,
      auth.account_id,
      BOOTSTRAP_ENTITY_ORDER[entityIndex] as (typeof BOOTSTRAP_ENTITY_ORDER)[number],
      afterKey,
      wanted + 1,
    );

    if (page.items.length > wanted) {
      const kept = page.items.slice(0, wanted);
      if (kept.length > 0) {
        items.push(...kept);
        lastEntityIndex = entityIndex;
        lastKey = page.keys[kept.length - 1] as StorageKey;
      }
      hasMore = true;
      break;
    }

    if (page.items.length > 0) {
      items.push(...page.items);
      lastEntityIndex = entityIndex;
      lastKey = page.lastKey;
    }
    // This entity is exhausted; the next one starts at its own beginning.
    entityIndex += 1;
    afterKey = null;
  }

  const nextCursor =
    hasMore && lastKey !== null
      ? await issueCursor(
          env.CURSOR_MAC_KEY,
          auth.account_id,
          position.watermark,
          lastEntityIndex,
          lastKey,
        )
      : null;

  return {
    snapshot_high_watermark_seq: position.watermark,
    has_more: hasMore,
    next_cursor: nextCursor,
    items: items.map((item) => ({
      entity_type: item.entity_type,
      identity: item.identity,
      projection: item.projection,
    })),
  };
}

async function resume(
  env: Env,
  accountId: string,
  token: string,
): Promise<{ watermark: number; entityIndex: number; storageKey: StorageKey }> {
  const cursor = await verifyCursor(env.CURSOR_MAC_KEY, token, accountId);
  return {
    watermark: cursor.watermark,
    entityIndex: cursor.entityIndex,
    storageKey: cursor.storageKey,
  };
}

/**
 * `GET /v1/sync/bootstrap`.
 *
 * The request id is server-generated for the same reason as on the cursor
 * endpoint, and travels with success and failure alike.
 */
export async function handleBootstrapRequest(request: Request, env: Env): Promise<Response> {
  const requestId = crypto.randomUUID().toUpperCase();
  try {
    const result = await readBootstrap(request, env);
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
