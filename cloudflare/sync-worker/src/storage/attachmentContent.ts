import {
  assertAuthenticatedWriteSpace,
  authenticateDevice,
} from "../auth/deviceToken";
import { ApiError, validationFailed } from "../contracts/error";
import { isSpaceId } from "../contracts/identity";
import type { Env } from "../env";

/**
 * `PUT /v1/attachments/{attachment_id}/content` — API draft §6.1 and §6.3.
 *
 * The ciphertext is streamed straight from the request into R2. The Worker
 * never buffers or hashes the 12MiB envelope: the AEAD tag is the downloading
 * client's business, and D1 keeps only the size and hash the allocating
 * operation recorded.
 *
 * Nothing in this module is written to a log, and the R2 object key never
 * leaves it: not in a response, not in an error detail, not in a URL.
 */

/** 12,582,912 source bytes plus the fixed 34-byte envelope. Draft §6.1. */
const MAX_CIPHERTEXT_BYTES = 12_582_946;

/** No leading zero, sign, whitespace or exponent — one canonical spelling. */
const CANONICAL_DECIMAL = /^(?:0|[1-9][0-9]*)$/;

interface AttachmentRow {
  r2_object_key: string;
  origin_space_id: string;
  state: string;
  ciphertext_byte_size: number;
  ciphertext_hash: string;
}

/** Lowercase SHA-256 hex, as the 0006 CHECK stores it. */
const LOWERCASE_SHA256_HEX = /^[0-9a-f]{64}$/;

/**
 * Decode the stored ciphertext hash into the 32 raw bytes R2 compares against.
 *
 * The hash is what the allocating operation recorded, so a value that is not
 * 64 lowercase hex digits is a corrupt row rather than a bad request. It is
 * reported as an unexplained storage condition: saying more would describe the
 * row back to a caller who has no business seeing it.
 */
function decodeCiphertextHash(hash: string): Uint8Array {
  if (!LOWERCASE_SHA256_HEX.test(hash)) {
    throw storageUnavailable();
  }
  const bytes = new Uint8Array(32);
  for (let index = 0; index < bytes.length; index += 1) {
    bytes[index] = Number.parseInt(hash.slice(index * 2, index * 2 + 2), 16);
  }
  return bytes;
}

/**
 * A failure the client may retry unchanged.
 *
 * Used for every outcome this handler cannot explain: a driver throw, an
 * object that is missing when the metadata says it should exist, or a size
 * that does not match. None of them say anything about storage internals.
 */
function storageUnavailable(): ApiError {
  return new ApiError("STORAGE_UNAVAILABLE", { retryable: true });
}

/**
 * Read the attachment by account and id only.
 *
 * Scoping the query to the authenticated account is what makes another
 * account's attachment indistinguishable from one that does not exist: both
 * come back as no row, so the same content-free `NOT_FOUND` answers both and
 * the endpoint cannot be used to probe for foreign identifiers.
 */
async function readAttachment(
  db: D1Database,
  accountId: string,
  attachmentId: string,
): Promise<AttachmentRow | null> {
  try {
    return await db
      .prepare(
        `SELECT r2_object_key, origin_space_id, state, ciphertext_byte_size, ciphertext_hash
           FROM attachment
          WHERE account_id = ? AND attachment_id = ?`,
      )
      .bind(accountId, attachmentId)
      .first<AttachmentRow>();
  } catch {
    throw storageUnavailable();
  }
}

/**
 * Check the declared length against the metadata before the body is touched.
 *
 * Every branch here runs before a single byte is pulled, which is the point:
 * a request that cannot be right must not be allowed to spend 12MiB of
 * transfer proving it.
 */
function assertDeclaredContentLength(request: Request, expected: number): void {
  const declared = request.headers.get("Content-Length");
  if (declared === null) {
    // Chunked transfer without a declared length lands here as well. There is
    // no size to compare, so there is no way to accept the body.
    throw validationFailed();
  }
  if (!CANONICAL_DECIMAL.test(declared)) {
    throw validationFailed();
  }
  const length = Number(declared);
  if (!Number.isSafeInteger(length)) {
    throw validationFailed();
  }
  if (length > MAX_CIPHERTEXT_BYTES) {
    throw new ApiError("REQUEST_TOO_LARGE");
  }
  if (length < 1) {
    throw validationFailed();
  }
  if (length !== expected) {
    // The allocating operation fixed the ciphertext size. A body of any other
    // length is not this attachment.
    throw validationFailed();
  }
}

async function headObject(bucket: R2Bucket, key: string): Promise<R2Object | null> {
  try {
    return await bucket.head(key);
  } catch {
    throw storageUnavailable();
  }
}

/** True when R2 holds exactly the object the metadata describes. */
async function objectMatchesMetadata(
  bucket: R2Bucket,
  key: string,
  expectedSize: number,
): Promise<boolean> {
  const head = await headObject(bucket, key);
  return head !== null && head.size === expectedSize;
}

/**
 * The `allocated` branch — the only one that writes bytes.
 *
 * The PUT is create-only (`etagDoesNotMatch: "*"`). Two devices uploading the
 * same attachment at once therefore cannot overwrite each other: R2 keeps the
 * first object and answers the loser with `null` instead of replacing content
 * that an existing AAD already commits to.
 *
 * It also carries the `sha256` the allocating operation recorded. R2 hashes
 * the stream as it stores it and refuses to keep an object whose digest does
 * not match, so a truncated or altered body never becomes a stored object —
 * and the Worker still never buffers or hashes the 12MiB envelope itself.
 */
async function uploadAllocatedObject(
  request: Request,
  bucket: R2Bucket,
  row: AttachmentRow,
): Promise<void> {
  const checksum = decodeCiphertextHash(row.ciphertext_hash);
  let written: R2Object | null;
  try {
    written = await bucket.put(row.r2_object_key, request.body, {
      onlyIf: { etagDoesNotMatch: "*" },
      sha256: checksum as BufferSource,
    });
  } catch {
    // A checksum mismatch surfaces here as a driver throw. Its message is not
    // read: every R2 failure is the same content-free, retryable answer, and
    // R2 has already discarded the rejected object.
    throw storageUnavailable();
  }

  if (written === null) {
    // The precondition failed, so some other PUT created this object first.
    // That is a success to converge on, not an error — but only if what is
    // actually stored is the object this metadata describes.
    if (!(await objectMatchesMetadata(bucket, row.r2_object_key, row.ciphertext_byte_size))) {
      throw storageUnavailable();
    }
    return;
  }

  if (written.size !== row.ciphertext_byte_size) {
    // The declared length was checked, so a different stored size means the
    // body did not match what it declared. The row stays `allocated`.
    throw storageUnavailable();
  }
}

/**
 * Move `allocated` to `uploaded`, or explain why it could not move.
 *
 * The UPDATE carries its own precondition, so two concurrent uploads race in
 * D1 rather than in the handler: exactly one changes a row and the other is
 * classified by re-reading storage. The transition is deliberately silent —
 * §6.3 makes `uploaded` a transfer-internal state, so it consumes no account
 * sequence and writes no `change_log` row. There is no client operation id
 * here either, so no `operation_log` row exists to write.
 */
async function markUploaded(
  db: D1Database,
  accountId: string,
  attachmentId: string,
  bucket: R2Bucket,
  row: AttachmentRow,
): Promise<void> {
  let changes: number;
  try {
    const result = await db
      .prepare(
        `UPDATE attachment
            SET state = 'uploaded'
          WHERE account_id = ? AND attachment_id = ? AND state = 'allocated'`,
      )
      .bind(accountId, attachmentId)
      .run();
    changes = result.meta.changes ?? 0;
  } catch {
    throw storageUnavailable();
  }

  if (changes > 0) {
    return;
  }

  // Nothing moved, so the row changed under this request. Ask storage what it
  // is now rather than guessing from the driver.
  const current = await readAttachment(db, accountId, attachmentId);
  if (current === null) {
    throw new ApiError("NOT_FOUND");
  }
  if (current.state === "uploaded") {
    // A concurrent upload of the same attachment already converged.
    if (!(await objectMatchesMetadata(bucket, row.r2_object_key, row.ciphertext_byte_size))) {
      throw storageUnavailable();
    }
    return;
  }
  if (current.state === "allocated") {
    // Still allocated after a conditional update that matched allocated: the
    // storage layer did something this handler cannot account for.
    throw storageUnavailable();
  }
  throw new ApiError("ATTACHMENT_STATE_CONFLICT");
}

/**
 * Apply one content upload.
 *
 * Resolves when the attachment is `uploaded` and R2 holds its object; every
 * other outcome throws an `ApiError`. The caller turns that into the response,
 * so nothing here formats a body.
 */
export async function uploadAttachmentContent(
  request: Request,
  env: Env,
  attachmentId: string,
): Promise<void> {
  const auth = await authenticateDevice(request, env.DB);

  const row = await readAttachment(env.DB, auth.account_id, attachmentId);
  if (row === null) {
    throw new ApiError("NOT_FOUND");
  }

  if (!isSpaceId(row.origin_space_id)) {
    // The column has a CHECK, so this is a corrupt row rather than a request
    // problem. Failing closed is still the only safe answer.
    throw new ApiError("AUTH_INVALID");
  }
  // §6.3: content is uploaded by the space the attachment came from, not by
  // any device that happens to share the account. Download is the wider,
  // account-scoped permission; this is the write side.
  assertAuthenticatedWriteSpace(auth, row.origin_space_id);

  assertDeclaredContentLength(request, row.ciphertext_byte_size);
  if (request.body === null) {
    // A non-zero declared length with no body at all is not a request this
    // handler can complete.
    throw validationFailed();
  }

  switch (row.state) {
    case "allocated":
      await uploadAllocatedObject(request, env.ATTACHMENTS, row);
      await markUploaded(env.DB, auth.account_id, attachmentId, env.ATTACHMENTS, row);
      return;

    case "uploaded":
      // An idempotent retry. The object is already there, so the body is left
      // unread and the existing object is never re-written: overwriting it
      // would replace bytes an existing AAD is already committed to.
      if (!(await objectMatchesMetadata(env.ATTACHMENTS, row.r2_object_key, row.ciphertext_byte_size))) {
        throw storageUnavailable();
      }
      return;

    default:
      // ready, abandoned, tombstoned, garbage_collected — §6.3 refuses all of
      // them before the body is read.
      throw new ApiError("ATTACHMENT_STATE_CONFLICT");
  }
}

/**
 * `POST /v1/attachments/{attachment_id}/complete` — API draft §6.3.
 *
 * Where the upload is transfer-internal, this is the transition other devices
 * are waiting for: it is the point at which the attachment becomes readable,
 * so it is the only one of the two that consumes an account sequence and files
 * a `change_log` row.
 */

/** Highest allocatable sequence; `2^53` is the exhausted sentinel (§5.3). */
const MAX_ALLOCATABLE_SEQ = 9007199254740991;
const EXHAUSTED_SENTINEL = 9007199254740992;

const CURRENT_SEQ = "(SELECT next_server_seq FROM account WHERE account_id = ?)";

/**
 * Refuse a request that carries a body.
 *
 * The body is never read: `complete` takes all of its meaning from the path
 * and the token, and a handler that parsed a body here would be a second,
 * undeclared way to say what to do. A declared length is the whole check.
 */
function assertNoRequestBody(request: Request): void {
  const declared = request.headers.get("Content-Length");
  if (declared !== null && declared !== "0") {
    throw validationFailed();
  }
  if (request.body !== null) {
    // A body with no declared length — chunked, or a directly constructed
    // request — is refused on sight rather than drained and ignored.
    throw validationFailed();
  }
}

async function sequenceExhausted(db: D1Database, accountId: string): Promise<boolean> {
  try {
    const account = await db
      .prepare("SELECT next_server_seq FROM account WHERE account_id = ?")
      .bind(accountId)
      .first<{ next_server_seq: number }>();
    return account !== null && account.next_server_seq >= EXHAUSTED_SENTINEL;
  } catch {
    throw storageUnavailable();
  }
}

/**
 * Explain a batch that did not apply, by asking storage rather than the driver.
 *
 * The D1 error object is never inspected: a bound value or a constraint name
 * in a message would describe the row back to the caller.
 */
async function classifyCompleteFailure(
  db: D1Database,
  accountId: string,
  attachmentId: string,
): Promise<void> {
  const current = await readAttachment(db, accountId, attachmentId);
  if (current === null) {
    throw new ApiError("NOT_FOUND");
  }
  if (current.state === "ready") {
    // A concurrent complete won the race. Both callers wanted the same end
    // state, and exactly one sequence was consumed to reach it.
    return;
  }
  if (current.state !== "uploaded") {
    throw new ApiError("ATTACHMENT_STATE_CONFLICT");
  }
  if (await sequenceExhausted(db, accountId)) {
    // Not retryable: no later attempt can allocate a sequence either, and D1
    // is left exactly as it was.
    throw new ApiError("STORAGE_UNAVAILABLE", { retryable: false });
  }
  throw storageUnavailable();
}

/**
 * Move `uploaded` to `ready` in one transaction.
 *
 * `batch()` is a single transaction, so a CAS miss must be a constraint
 * violation rather than an `UPDATE 0 rows` the batch would happily accept —
 * that is what the `transaction_guard` insert is for, exactly as the operation
 * handlers use it. Its `operation_id` is a server-generated UUID because an
 * HTTP transition has no client operation id; it lives only for the length of
 * the batch and never reaches a response, an error or a log.
 *
 * No `operation_log` row is written for the same reason: that table is keyed
 * by the client's operation id and exists to answer replays, and there is no
 * replay identity here to answer with.
 */
async function markReady(
  db: D1Database,
  accountId: string,
  attachmentId: string,
): Promise<void> {
  const guardId = crypto.randomUUID().toUpperCase();

  try {
    await db.batch([
      db
        .prepare(
          `INSERT INTO transaction_guard (account_id, operation_id, ok)
           VALUES (?, ?,
             ((SELECT COUNT(*) FROM attachment
                WHERE account_id = ? AND attachment_id = ? AND state = 'uploaded') = 1
              AND ${CURRENT_SEQ} <= ${MAX_ALLOCATABLE_SEQ}))`,
        )
        .bind(accountId, guardId, accountId, attachmentId, accountId),
      db
        .prepare(
          `UPDATE attachment
              SET state = 'ready', server_seq = ${CURRENT_SEQ}
            WHERE account_id = ? AND attachment_id = ? AND state = 'uploaded'`,
        )
        .bind(accountId, accountId, attachmentId),
      db
        .prepare(
          `INSERT INTO change_log
             (account_id, server_seq, entity_type, change_kind, revision, attachment_id)
           VALUES (?, ${CURRENT_SEQ}, 'attachment', 'upsert', NULL, ?)`,
        )
        .bind(accountId, accountId, attachmentId),
      db
        .prepare("UPDATE account SET next_server_seq = next_server_seq + 1 WHERE account_id = ?")
        .bind(accountId),
      db
        .prepare("DELETE FROM transaction_guard WHERE account_id = ? AND operation_id = ?")
        .bind(accountId, guardId),
    ]);
  } catch {
    await classifyCompleteFailure(db, accountId, attachmentId);
    return;
  }

  const applied = await readAttachment(db, accountId, attachmentId);
  if (applied === null || applied.state !== "ready") {
    throw storageUnavailable();
  }
}

/**
 * Apply one completion.
 *
 * Resolves when the attachment is `ready`; every other outcome throws an
 * `ApiError`. The caller turns that into the response.
 */
export async function completeAttachmentUpload(
  request: Request,
  env: Env,
  attachmentId: string,
): Promise<void> {
  const auth = await authenticateDevice(request, env.DB);
  assertNoRequestBody(request);

  const row = await readAttachment(env.DB, auth.account_id, attachmentId);
  if (row === null) {
    throw new ApiError("NOT_FOUND");
  }
  if (!isSpaceId(row.origin_space_id)) {
    throw new ApiError("AUTH_INVALID");
  }
  // §6.3: like the upload, completion belongs to the space the attachment came
  // from. Download is the wider, account-scoped permission.
  assertAuthenticatedWriteSpace(auth, row.origin_space_id);

  switch (row.state) {
    case "ready":
      // Idempotent: R2 is not written again and no second sequence is spent.
      return;

    case "uploaded":
      // The object must actually be there, at the size the metadata fixed,
      // before anything is told it can be read.
      if (!(await objectMatchesMetadata(env.ATTACHMENTS, row.r2_object_key, row.ciphertext_byte_size))) {
        throw storageUnavailable();
      }
      await markReady(env.DB, auth.account_id, attachmentId);
      return;

    default:
      // allocated, abandoned, tombstoned, garbage_collected.
      throw new ApiError("ATTACHMENT_STATE_CONFLICT");
  }
}
