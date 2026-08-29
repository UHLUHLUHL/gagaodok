import { ApiError, PROTOCOL_VERSION } from "../contracts/error";
import { parseEnrollmentRequest } from "../contracts/onboarding";
import type { Env } from "../env";
import { initializeEnrollment } from "../storage/enrollment";

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
