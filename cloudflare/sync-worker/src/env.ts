/**
 * Bindings declared in `wrangler.jsonc`.
 *
 * Both storage bindings resolve to the local Miniflare simulators during
 * tests. No remote Cloudflare resource is referenced: the D1 `database_id`
 * is the zero UUID and the R2 bucket is named do-not-create.
 */
export interface Env {
  DB: D1Database;
  ATTACHMENTS: R2Bucket;
  CURSOR_MAC_KEY: string;
}
