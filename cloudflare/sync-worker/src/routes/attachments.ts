import { ApiError } from "../contracts/error";
import { isCanonicalUuid } from "../contracts/identity";
import {
  completeAttachmentUpload,
  uploadAttachmentContent,
} from "../storage/attachmentContent";
import type { Env } from "../env";

/**
 * Attachment content routes — API draft §6.3.
 *
 * The download half is a separate gate and is not routed here yet.
 */

/** The two tails the attachment path may end in. */
export type AttachmentAction = "content" | "complete";

export interface AttachmentRoute {
  attachmentId: string;
  action: AttachmentAction;
}

/**
 * Match `/v1/attachments/{id}/content` or `/v1/attachments/{id}/complete`.
 *
 * The match is exact rather than prefix-based: an extra segment, a missing
 * one, or an id that is not a canonical uppercase UUID all yield null, and the
 * caller answers every one of them with the same content-free 404. An id
 * passed as a query parameter never reaches this function, because only the
 * path is inspected.
 */
export function matchAttachmentPath(pathname: string): AttachmentRoute | null {
  const segments = pathname.split("/");
  if (segments.length !== 5) {
    return null;
  }
  const [empty, version, collection, attachmentId, action] = segments;
  if (empty !== "" || version !== "v1" || collection !== "attachments") {
    return null;
  }
  if (action !== "content" && action !== "complete") {
    return null;
  }
  if (!isCanonicalUuid(attachmentId)) {
    return null;
  }
  return { attachmentId, action };
}

/**
 * Turn a handler outcome into the response.
 *
 * There is no client operation id on an HTTP transition, so the envelope never
 * carries a request id here, and an unexpected throw says nothing at all: no
 * stack, no message, no hint of what storage was doing.
 */
async function respond(run: () => Promise<Response>): Promise<Response> {
  try {
    return await run();
  } catch (error) {
    if (error instanceof ApiError) {
      return error.toResponse(null);
    }
    return new ApiError("INTERNAL_ERROR").toResponse(null);
  }
}

/**
 * `PUT /v1/attachments/{attachment_id}/content`.
 *
 * Success is 204 with an empty body: the client already knows the id and the
 * size it sent, and everything else the server holds — the object key, its
 * ETag, the stored metadata — is not the client's to see.
 */
export async function handleAttachmentUpload(
  request: Request,
  env: Env,
  attachmentId: string,
): Promise<Response> {
  return await respond(async () => {
    await uploadAttachmentContent(request, env, attachmentId);
    return new Response(null, { status: 204 });
  });
}

/**
 * `POST /v1/attachments/{attachment_id}/complete`.
 *
 * Success is 204. The new `server_seq` is deliberately not returned: the
 * client learns about the change through the pull cursor like every other
 * device, rather than through a second, privileged channel.
 */
export async function handleAttachmentComplete(
  request: Request,
  env: Env,
  attachmentId: string,
): Promise<Response> {
  return await respond(async () => {
    await completeAttachmentUpload(request, env, attachmentId);
    return new Response(null, { status: 204 });
  });
}
