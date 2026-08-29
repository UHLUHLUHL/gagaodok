import { ApiError } from "../contracts/error";
import { applyOperationRequest } from "../handlers/operationRequest";
import type { Env } from "../env";

/**
 * `POST /v1/sync/operations` — API draft §4.1.
 *
 * The route owns the envelope and nothing else: `applyOperationRequest` stays
 * the single execution path, and the body is handed to it untouched so it is
 * read exactly once as bytes. Cloning it to peek at the operation id would
 * change the very bytes the replay fingerprint is computed over.
 */
export async function handleOperationRequest(request: Request, env: Env): Promise<Response> {
  try {
    const result = await applyOperationRequest(request, env.DB);
    return Response.json({
      protocol_version: 1,
      request_id: result.operation_id,
      result,
    });
  } catch (error) {
    if (error instanceof ApiError) {
      // `requestId` is null for anything raised before the body parsed, which
      // is what keeps an unvalidated identifier from being echoed back.
      return error.toResponse(error.requestId);
    }
    // An unexpected throw says nothing to the client: no stack, no message, no
    // hint of what the storage layer was doing.
    return new ApiError("INTERNAL_ERROR").toResponse(null);
  }
}
