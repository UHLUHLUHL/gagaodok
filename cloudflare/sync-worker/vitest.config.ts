import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

// Runs entirely inside the local workerd/Miniflare runtime that
// @cloudflare/vitest-plugin starts. No remote Cloudflare resource is
// contacted: the D1 and R2 bindings resolve to local simulators.
export default defineConfig({
  plugins: [cloudflareTest({ wrangler: { configPath: "./wrangler.jsonc" } })],
});
