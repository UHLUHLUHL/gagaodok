import { ApiError } from "../contracts/error";
import { isCanonicalUuid } from "../contracts/identity";
import { uploadAttachmentContent } from "../storage/attachmentContent";
import type { Env } from "../env";

/**
 * Attachment content routes — API draft §6.3.
 *
 * Only the upload half exists: `POST .../complete` and `GET .../content` are
 * separate gates and are not routed here yet.
 */

const CONTENT_SEGMENTS = ["", "v1", "attachments", "", "content"];

/**
 * Return the attachment id in `/v1/attachments/{id}/content`, or null.
 *
 * The match is exact rather than prefix-based: an extra segment, a missing
 * one, or an id that is not a canonical uppercase UUID all yield null, and the
 * caller answers every one of them with the same content-free 404. An id
 * passed as a query parameter never reaches this function, because only the
 * path is inspected.
 */
export function matchAttachmentContentPath(pathname: string): string | null {
  const segments = pathname.split("/");
  if (segments.length !== CONTENT_SEGMENTS.length) {
    return null;
  }
  for (let index = 0; index < CONTENT_SEGMENTS.length; index += 1) {
    const expected = CONTENT_SEGMENTS[index];
    if (expected !== "" && segments[index] !== expected) {
      return null;
    }
  }
  const attachmentId = segments[3] ?? "";
  return isCanonicalUuid(attachmentId) ? attachmentId : null;
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
  try {
    await uploadAttachmentContent(request, env, attachmentId);
    return new Response(null, { status: 204 });
  } catch (error) {
    if (error instanceof ApiError) {
      // There is no client operation id on an HTTP transition, so the envelope
      // never carries a request id here.
      return error.toResponse(null);
    }
    // An unexpected throw says nothing: no stack, no message, no hint of what
    // storage was doing.
    return new ApiError("INTERNAL_ERROR").toResponse(null);
  }
}
