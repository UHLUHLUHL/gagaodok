/** Error codes fixed by PHASE1_WORKER_API_DRAFT.md §2.3. */
export const ERROR_CODES = [
  "VALIDATION_FAILED",
  "AUTH_INVALID",
  "DEVICE_REVOKED",
  "ENTITY_NOT_FOUND",
  "NOT_FOUND",
  "REVISION_CONFLICT",
  "OPERATION_REPLAY_MISMATCH",
  "BUBBLE_ORDER_CONFLICT",
  "ATTACHMENT_STATE_CONFLICT",
  "ENROLLMENT_CONFLICT",
  "REQUEST_TOO_LARGE",
  "PROFILE_UNSUPPORTED",
  "RATE_LIMITED",
  "INTERNAL_ERROR",
  "STORAGE_UNAVAILABLE",
] as const;

export type ErrorCode = (typeof ERROR_CODES)[number];

export const PROTOCOL_VERSION = 1;

const HTTP_STATUS: Record<ErrorCode, number> = {
  VALIDATION_FAILED: 400,
  AUTH_INVALID: 401,
  DEVICE_REVOKED: 403,
  ENTITY_NOT_FOUND: 404,
  NOT_FOUND: 404,
  REVISION_CONFLICT: 409,
  OPERATION_REPLAY_MISMATCH: 409,
  // The requested bubble_order is not the one this scope will accept next.
  // Distinct from REVISION_CONFLICT: nothing about a revision is stale, and
  // the client must re-encrypt because bubble_order is inside the AAD.
  BUBBLE_ORDER_CONFLICT: 409,
  ATTACHMENT_STATE_CONFLICT: 409,
  ENROLLMENT_CONFLICT: 409,
  REQUEST_TOO_LARGE: 413,
  PROFILE_UNSUPPORTED: 422,
  RATE_LIMITED: 429,
  INTERNAL_ERROR: 500,
  STORAGE_UNAVAILABLE: 503,
};

/**
 * A content-free API error.
 *
 * `code` is a fixed enum and `detail` may only hold non-content scalars such
 * as `current_revision`. Nothing derived from plaintext, SQL, stack traces,
 * object keys or tokens is ever attached — see API draft §2.3 and §8.
 */
export class ApiError extends Error {
  readonly code: ErrorCode;
  readonly retryable: boolean;
  readonly detail: Record<string, number | boolean>;
  /**
   * The validated `operation_id`, once one exists.
   *
   * Not a wire field of its own: `toResponse` puts it at the top level of the
   * envelope as `request_id` and never inside `detail`. It stays null for
   * anything raised before the body parsed, so a malformed request cannot echo
   * an unvalidated identifier back.
   */
  requestId: string | null = null;

  constructor(
    code: ErrorCode,
    options: { retryable?: boolean; detail?: Record<string, number | boolean> } = {},
  ) {
    // The Error message is the bare code so that an accidental log line
    // cannot leak content.
    super(code);
    this.name = "ApiError";
    this.code = code;
    this.retryable = options.retryable ?? false;
    this.detail = options.detail ?? {};
  }

  get status(): number {
    return HTTP_STATUS[this.code];
  }

  toResponse(requestId: string | null): Response {
    const body: Record<string, unknown> = {
      protocol_version: PROTOCOL_VERSION,
      error: { code: this.code, retryable: this.retryable, ...this.detail },
    };
    if (requestId !== null) {
      body["request_id"] = requestId;
    }
    return Response.json(body, { status: this.status });
  }
}

export function validationFailed(
  detail: Record<string, number | boolean> = {},
): ApiError {
  return new ApiError("VALIDATION_FAILED", { detail });
}
