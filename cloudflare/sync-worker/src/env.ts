/**
 * Bindings declared in `wrangler.jsonc`.
 *
 * Both storage bindings resolve to the local Miniflare simulators during
 * tests. No remote Cloudflare resource is referenced: the D1 `database_id`
 * is the zero UUID and the R2 bucket is named do-not-create.
 *
 * `DB` holds the schema built by `migrations/`. As of M01 that is the
 * `account` and `device` identity tables only — room, turn, bubble,
 * attachment and the operation ledger arrive in M02..M06 (see
 * `docs/PHASE1_D1_MIGRATION_PLAN.md`). No request handler reads or writes
 * `DB` yet; the binding exists so migrations and their local fixtures can
 * run against it.
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
