import type { Env } from "./env";
import { ApiError, PROTOCOL_VERSION } from "./contracts/error";
import { handleOperationRequest } from "./routes/operations";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "GET" && url.pathname === "/v1/health") {
      return Response.json({ ok: true, protocol_version: PROTOCOL_VERSION });
    }

    if (request.method === "POST" && url.pathname === "/v1/sync/operations") {
      return await handleOperationRequest(request, env);
    }

    // Anything else — including the operation path with another method — is
    // the same content-free 404 with no request id.
    return new ApiError("NOT_FOUND").toResponse(null);
  },
} satisfies ExportedHandler<Env>;
