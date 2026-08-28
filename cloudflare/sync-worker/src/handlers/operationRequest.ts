import {
  assertAuthenticatedDeviceId,
  assertAuthenticatedWriteSpace,
  authenticateDevice,
} from "../auth/deviceToken";
import { ApiError, validationFailed } from "../contracts/error";
import { MAX_OPERATION_BODY_BYTES, assertOperationBodySize, parseOperationRequest } from "../contracts/operation";
import { applyPatchRoom } from "../storage/operationTransaction";
import type { OperationResult } from "../storage/operationTransaction";

/**
 * The route-independent entry point for `POST /v1/sync/operations`.
 *
 * No route calls this yet: `src/index.ts` still serves health only. Wrapping
 * the result in the §2.2 envelope and attaching `request_id` belongs to the
 * route step, which is a separate gate.
 *
 * The body is read exactly once, as bytes. The replay fingerprint is the
 * SHA-256 of those bytes and never of a re-serialised object: two encodings of
 * the same JSON are different operations by contract (§4.1).
 */
export type { OperationResult };

const UTF8 = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false });

/**
 * Reject an oversized request before the body is pulled, when the sender
 * declared its length. A declared length is not trusted as *the* length — the
 * real byte count is checked again after reading.
 */
function assertDeclaredLength(request: Request): void {
  const declared = request.headers.get("Content-Length");
  if (declared === null) {
    return;
  }
  if (!/^[0-9]+$/.test(declared)) {
    throw validationFailed();
  }
  const length = Number(declared);
  if (!Number.isSafeInteger(length)) {
    throw new ApiError("REQUEST_TOO_LARGE");
  }
  assertOperationBodySize(length);
}

async function readRawBody(request: Request): Promise<Uint8Array> {
  let buffer: ArrayBuffer;
  try {
    buffer = await request.arrayBuffer();
  } catch {
    // A truncated or aborted body is a malformed request, not a server fault.
    throw validationFailed();
  }
  if (buffer.byteLength > MAX_OPERATION_BODY_BYTES) {
    throw new ApiError("REQUEST_TOO_LARGE");
  }
  return new Uint8Array(buffer);
}

async function fingerprintOf(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes as BufferSource);
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function applyOperationRequest(
  request: Request,
  db: D1Database,
): Promise<OperationResult> {
  const auth = await authenticateDevice(request, db);

  assertDeclaredLength(request);
  const raw = await readRawBody(request);
  const fingerprint = await fingerprintOf(raw);

  let text: string;
  try {
    text = UTF8.decode(raw);
  } catch {
    // Malformed UTF-8 and malformed JSON are the same answer: the body is not
    // a request. Saying which would describe the body back to the sender.
    throw validationFailed();
  }

  let parsedJson: unknown;
  try {
    parsedJson = JSON.parse(text);
  } catch {
    throw validationFailed();
  }

  const operation = parseOperationRequest(parsedJson);
  assertAuthenticatedDeviceId(auth, operation.device_id);
  // Before any storage read. The replay lookup answers with a stored
  // sequence and revision, so running it first would let a phone token read
  // the Mac's ledger by guessing an operation_id.
  assertAuthenticatedWriteSpace(auth, operation.target.space_id);

  if (operation.op !== "patch_room") {
    // This slice implements one operation. Every other runtime-enabled op is
    // refused whole rather than applied in part: a half-applied create is
    // worse than a rejected one.
    throw validationFailed();
  }

  return await applyPatchRoom(db, auth, operation, fingerprint);
}
