import type { Env } from "./env";
import { ApiError, PROTOCOL_VERSION } from "./contracts/error";
import {
  handleAttachmentComplete,
  handleAttachmentDownload,
  handleAttachmentUpload,
  matchAttachmentPath,
} from "./routes/attachments";
import { handleBootstrapRequest } from "./routes/bootstrap";
import { handleChangesRequest } from "./routes/changes";
import { handleOperationRequest } from "./routes/operations";
import { handleEnrollmentInitialize, handleRecoveryRedeem } from "./routes/onboarding";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "GET" && url.pathname === "/v1/health") {
      return Response.json({ ok: true, protocol_version: PROTOCOL_VERSION });
    }

    if (request.method === "POST" && url.pathname === "/v1/sync/operations") {
      return await handleOperationRequest(request, env);
    }

    if (request.method === "POST" && url.pathname === "/v1/enrollment/initialize") {
      return await handleEnrollmentInitialize(request, env);
    }

    if (request.method === "POST" && url.pathname === "/v1/recovery/redeem") {
      return await handleRecoveryRedeem(request, env);
    }

    if (request.method === "GET" && url.pathname === "/v1/sync/changes") {
      return await handleChangesRequest(request, env);
    }

    if (request.method === "GET" && url.pathname === "/v1/sync/bootstrap") {
      return await handleBootstrapRequest(request, env);
    }

    const attachment = matchAttachmentPath(url.pathname);
    if (attachment !== null) {
      if (request.method === "PUT" && attachment.action === "content") {
        return await handleAttachmentUpload(request, env, attachment.attachmentId);
      }
      if (request.method === "POST" && attachment.action === "complete") {
        return await handleAttachmentComplete(request, env, attachment.attachmentId);
      }
      if (request.method === "GET" && attachment.action === "content") {
        return await handleAttachmentDownload(request, env, attachment.attachmentId);
      }
    }

    // Anything else — a known path with another method, an attachment path
    // with an extra segment or a non-canonical id — is the same content-free
    // 404 with no request id.
    return new ApiError("NOT_FOUND").toResponse(null);
  },
} satisfies ExportedHandler<Env>;
