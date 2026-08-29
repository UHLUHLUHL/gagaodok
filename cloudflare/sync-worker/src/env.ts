/**
 * Bindings declared in `wrangler.jsonc`.
 *
 * Both storage bindings resolve to the local Miniflare simulators during
 * tests. No remote Cloudflare resource is contacted: the D1 `database_id` is
 * the zero UUID and the R2 bucket is named do-not-create.
 *
 * `DB` holds the schema built by `migrations/`: identity, conversation scope,
 * turns and bubbles, versioned AI state, attachment metadata, the device token
 * column the authentication boundary uses, and the M06 operation/change ledger
 * with the account sequence (see `docs/PHASE1_D1_MIGRATION_PLAN.md`).
 *
 * `DB` is read by the device authentication boundary and by every operation
 * transaction, reached through `POST /v1/sync/operations`.
 *
 * `ATTACHMENTS` holds the encrypted attachment envelopes, keyed by the
 * server-generated `r2_object_key` that `create_attachment` recorded in D1.
 * Its only caller is the content upload route,
 * `PUT /v1/attachments/{attachment_id}/content`; the complete and download
 * paths are not implemented.
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
