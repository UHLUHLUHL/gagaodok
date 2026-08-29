import type { Env } from "./env";
import { ApiError, PROTOCOL_VERSION } from "./contracts/error";
import { handleAttachmentUpload, matchAttachmentContentPath } from "./routes/attachments";
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

    if (request.method === "PUT") {
      const attachmentId = matchAttachmentContentPath(url.pathname);
      if (attachmentId !== null) {
        return await handleAttachmentUpload(request, env, attachmentId);
      }
    }

    // Anything else — the operation path with another method, an attachment
    // path with an extra segment or a non-canonical id — is the same
    // content-free 404 with no request id.
    return new ApiError("NOT_FOUND").toResponse(null);
  },
} satisfies ExportedHandler<Env>;
