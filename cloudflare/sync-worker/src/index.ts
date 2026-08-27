import type { Env } from "./env";
import { ApiError, PROTOCOL_VERSION } from "./contracts/error";

export default {
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "GET" && url.pathname === "/v1/health") {
      return Response.json({ ok: true, protocol_version: PROTOCOL_VERSION });
    }

    return new ApiError("NOT_FOUND").toResponse(null);
  },
} satisfies ExportedHandler<Env>;
