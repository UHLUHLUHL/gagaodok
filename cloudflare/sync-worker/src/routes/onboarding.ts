import { authenticateDevice } from "../auth/deviceToken";
import { ApiError, PROTOCOL_VERSION } from "../contracts/error";
import { parseEnrollmentRequest } from "../contracts/onboarding";
import type { Env } from "../env";
import { initializeEnrollment } from "../storage/enrollment";
import { parseRecoveryRedeem, parseRecoveryRotate } from "../contracts/recovery";
import { redeemRecovery, rotateRecovery } from "../storage/recovery";

export async function handleEnrollmentInitialize(request: Request, env: Env): Promise<Response> {
  try {
    const parsed = await parseEnrollmentRequest(request);
    const result = await initializeEnrollment(parsed, env);
    return Response.json(
      { protocol_version: PROTOCOL_VERSION, request_id: parsed.enrollmentId, result },
      { status: result.status === "created" ? 201 : 200 },
    );
  } catch (error) {
    if (error instanceof ApiError) return error.toResponse(null);
    return new ApiError("INTERNAL_ERROR").toResponse(null);
  }
}

export async function handleRecoveryRedeem(request: Request, env: Env): Promise<Response> {
  try {
    const parsed = await parseRecoveryRedeem(request);
    const result = await redeemRecovery(env.DB, parsed);
    return Response.json(
      { protocol_version: PROTOCOL_VERSION, result },
      { status: result.status === "created" ? 201 : 200 },
    );
  } catch (error) {
    if (error instanceof ApiError) return error.toResponse(null);
    return new ApiError("INTERNAL_ERROR").toResponse(null);
  }
}

/**
 * Authenticated recovery rotation. An active device token is the proof — the
 * old phrase is not required and is not accepted here, because the point of a
 * rotation is that the user no longer has it.
 *
 * The response carries the new version and nothing else: no lookup, no wrapped
 * key, no object key, no token.
 */
export async function handleRecoveryRotate(request: Request, env: Env): Promise<Response> {
  const requestId = crypto.randomUUID().toUpperCase();
  try {
    const auth = await authenticateDevice(request, env.DB);
    const parsed = await parseRecoveryRotate(request);
    const result = await rotateRecovery(env, auth.account_id, parsed);
    return Response.json(
      { protocol_version: PROTOCOL_VERSION, request_id: requestId, result },
      { status: result.status === "created" ? 201 : 200 },
    );
  } catch (error) {
    if (error instanceof ApiError) return error.toResponse(requestId);
    return new ApiError("INTERNAL_ERROR").toResponse(requestId);
  }
}
