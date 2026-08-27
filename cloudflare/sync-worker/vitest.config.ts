import { defineWorkersConfig } from "@cloudflare/vitest-pool-workers/config";

// Runs entirely inside the local workerd/Miniflare runtime that
// @cloudflare/vitest-pool-workers starts. No remote Cloudflare resource is
// contacted: the D1 and R2 bindings resolve to local simulators.
export default defineWorkersConfig({
  test: {
    poolOptions: {
      workers: {
        wrangler: { configPath: "./wrangler.jsonc" },
      },
    },
  },
});
