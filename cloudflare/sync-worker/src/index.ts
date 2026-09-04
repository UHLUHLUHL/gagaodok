import type { Env } from "./env";
import { ApiError, PROTOCOL_VERSION } from "./contracts/error";
import { isCanonicalUuid } from "./contracts/identity";
import {
  handleAttachmentComplete,
  handleAttachmentDownload,
  handleAttachmentUpload,
  matchAttachmentPath,
} from "./routes/attachments";
import { handleBootstrapRequest } from "./routes/bootstrap";
import { handleChangesRequest } from "./routes/changes";
import { handleDeviceListRequest, handleDeviceRevokeRequest } from "./routes/devices";
import { handleOperationRequest } from "./routes/operations";
import {
  handleEnrollmentInitialize,
  handleRecoveryRedeem,
  handleRecoveryRotate,
} from "./routes/onboarding";
import { handlePairingMatch, handlePairingSession, matchPairingPath } from "./routes/pairing";
import { assertRateLimit, type RateLimitScope } from "./security/rateLimit";
import { runMaintenance } from "./maintenance/cleanup";

async function limited(
  request: Request,
  env: Env,
  scope: RateLimitScope,
  run: () => Promise<Response>,
): Promise<Response> {
  try {
    await assertRateLimit(request, env.DB, env.RATE_LIMIT_MAC_KEY, scope);
    return await run();
  } catch (error) {
    if (error instanceof ApiError) return error.toResponse(null);
    return new ApiError("INTERNAL_ERROR").toResponse(null);
  }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "GET" && url.pathname === "/v1/health") {
      return Response.json({ ok: true, protocol_version: PROTOCOL_VERSION });
    }

    if (request.method === "POST" && url.pathname === "/v1/sync/operations") {
      return await limited(request, env, "sync_write", () => handleOperationRequest(request, env));
    }

    if (request.method === "POST" && url.pathname === "/v1/enrollment/initialize") {
      return await limited(request, env, "enrollment", () => handleEnrollmentInitialize(request, env));
    }

    if (request.method === "POST" && url.pathname === "/v1/recovery/redeem") {
      return await limited(request, env, "recovery", () => handleRecoveryRedeem(request, env));
    }

    if (request.method === "POST" && url.pathname === "/v1/recovery/rotate") {
      return await limited(request, env, "recovery", () => handleRecoveryRotate(request, env));
    }

    if (request.method === "POST" && url.pathname === "/v1/pairing/sessions") {
      return await limited(request, env, "pairing_session", () => handlePairingSession(request, env));
    }

    const pairing = matchPairingPath(url.pathname);
    if (pairing !== null) {
      const scope: RateLimitScope = pairing.action === "claims"
        ? "pairing_claim"
        : pairing.action === "approve" ? "pairing_approve" : "pairing_redeem";
      return await limited(request, env, scope, () => handlePairingMatch(request, env, pairing));
    }

    if (request.method === "GET" && url.pathname === "/v1/sync/changes") {
      return await limited(request, env, "sync_read", () => handleChangesRequest(request, env));
    }

    if (request.method === "GET" && url.pathname === "/v1/sync/bootstrap") {
      return await limited(request, env, "sync_read", () => handleBootstrapRequest(request, env));
    }

    if (request.method === "GET" && url.pathname === "/v1/account/devices") {
      return await limited(request, env, "sync_read", () => handleDeviceListRequest(request, env));
    }

    const revoke = /^\/v1\/account\/devices\/([^/]+)\/revoke$/.exec(url.pathname);
    const revokeTarget = revoke?.[1];
    if (request.method === "POST" && revokeTarget !== undefined && isCanonicalUuid(revokeTarget)) {
      return await limited(request, env, "sync_read", () => handleDeviceRevokeRequest(request, env, revokeTarget));
    }

    const attachment = matchAttachmentPath(url.pathname);
    if (attachment !== null) {
      if (request.method === "PUT" && attachment.action === "content") {
        return await limited(request, env, "attachment", () => handleAttachmentUpload(request, env, attachment.attachmentId));
      }
      if (request.method === "POST" && attachment.action === "complete") {
        return await limited(request, env, "attachment", () => handleAttachmentComplete(request, env, attachment.attachmentId));
      }
      if (request.method === "GET" && attachment.action === "content") {
        return await limited(request, env, "attachment", () => handleAttachmentDownload(request, env, attachment.attachmentId));
      }
    }

    // Anything else — a known path with another method, an attachment path
    // with an extra segment or a non-canonical id — is the same content-free
    // 404 with no request id.
    return new ApiError("NOT_FOUND").toResponse(null);
  },
  async scheduled(_controller: ScheduledController, env: Env): Promise<void> {
    await runMaintenance(env);
  },
} satisfies ExportedHandler<Env>;
