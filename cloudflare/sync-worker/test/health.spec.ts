import { exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

const worker = (exports as { default: ExportedHandler }).default;

type WorkerRequest = Parameters<NonNullable<ExportedHandler["fetch"]>>[0];

async function fetchAs(worker_: ExportedHandler, path: string, init?: RequestInit): Promise<Response> {
  const request = new Request(`https://example.test${path}`, init) as unknown as WorkerRequest;
  const response = await worker_.fetch?.(request, {} as never, {} as never);
  if (response === undefined) {
    throw new Error("worker did not return a response");
  }
  return response;
}

describe("GET /v1/health", () => {
  it("returns the protocol version and no storage content", async () => {
    const response = await fetchAs(worker, "/v1/health");
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, protocol_version: 1 });
  });

  it("returns a content-free error envelope for unknown routes", async () => {
    const response = await fetchAs(worker, "/v1/nope");
    expect(response.status).toBe(404);
    const body = (await response.json()) as Record<string, unknown>;
    expect(body).toMatchObject({
      protocol_version: 1,
      error: { code: "NOT_FOUND", retryable: false },
    });
    // The envelope must never carry a free-text detail channel.
    expect(JSON.stringify(body)).not.toContain("message");
  });

  it("rejects a non-GET health request", async () => {
    const response = await fetchAs(worker, "/v1/health", { method: "POST" });
    expect(response.status).toBe(404);
  });
});
