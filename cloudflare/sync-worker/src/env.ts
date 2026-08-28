/**
 * Bindings declared in `wrangler.jsonc`.
 *
 * Both storage bindings resolve to the local Miniflare simulators during
 * tests. No remote Cloudflare resource is referenced: the D1 `database_id`
 * is the zero UUID and the R2 bucket is named do-not-create.
 *
 * `DB` holds the schema built by `migrations/`. As of M05 that is identity,
 * conversation scope, turns and bubbles, versioned AI state and attachment
 * metadata, plus the device token column the authentication boundary uses.
 * The operation and change ledger and the account sequence arrive with M06
 * (see `docs/PHASE1_D1_MIGRATION_PLAN.md`).
 *
 * The only code that reads `DB` today is `src/auth/deviceToken.ts`, and no
 * route calls it yet: the sole endpoint is public health. The attachment
 * endpoints are the first callers.
 *
 * The test-only `TEST_MIGRATIONS` binding is *not* declared here: it is
 * injected by `vitest.config.ts` and typed inside `test/migrations.spec.ts`
 * so a test fixture can never be mistaken for a production binding.
 */
export interface Env {
  DB: D1Database;
  ATTACHMENTS: R2Bucket;
  CURSOR_MAC_KEY: string;
}
