import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

// M00 — local D1 test harness.
//
// Everything runs inside the workerd/Miniflare runtime the plugin starts. No
// remote Cloudflare resource is contacted: the D1 and R2 bindings in
// wrangler.jsonc resolve to local simulators, and migrations are applied to
// that local database only. There is no `--remote` path here and no deploy.
//
// `readD1Migrations()` runs in Node (it reads the filesystem), so the parsed
// migrations are handed to the Workers-side tests through a binding. Tests
// apply them with `applyD1Migrations()` from `cloudflare:test`.
//
// Storage is isolated per test file by the plugin, so one file's rows can
// never leak into another's assertions.
export default defineConfig(async () => {
  const migrations = await readD1Migrations("./migrations");

  return {
    plugins: [
      cloudflareTest({
        wrangler: { configPath: "./wrangler.jsonc" },
        miniflare: {
          bindings: { TEST_MIGRATIONS: migrations },
        },
      }),
    ],
  };
});
