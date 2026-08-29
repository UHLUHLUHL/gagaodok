import type { Env } from "../env";

const GRACE_MS = 86_400_000;

export interface MaintenanceReport {
  orphan_objects_deleted: number;
  attachments_abandoned: number;
  pairing_claims_deleted: number;
  pairing_sessions_deleted: number;
}

async function referencedKeys(db: D1Database, keys: string[]): Promise<Set<string>> {
  const found = new Set<string>();
  for (let offset = 0; offset < keys.length; offset += 90) {
    const chunk = keys.slice(offset, offset + 90);
    if (chunk.length === 0) continue;
    const placeholders = chunk.map(() => "?").join(",");
    const rows = await db.prepare(
      `SELECT r2_object_key FROM attachment WHERE r2_object_key IN (${placeholders})
       UNION ALL
       SELECT r2_object_key FROM recovery_record WHERE r2_object_key IN (${placeholders})`,
    ).bind(...chunk, ...chunk).all<{ r2_object_key: string }>();
    for (const row of rows.results) found.add(row.r2_object_key);
  }
  return found;
}

async function deleteOrphanObjects(env: Pick<Env, "DB" | "ATTACHMENTS">, cutoff: number): Promise<number> {
  let deleted = 0;
  for (const prefix of ["obj/", "recovery/"]) {
    let cursor: string | undefined;
    do {
      const page = await env.ATTACHMENTS.list({
        prefix,
        limit: 1_000,
        ...(cursor === undefined ? {} : { cursor }),
      });
      const old = page.objects.filter((object) => object.uploaded.getTime() < cutoff);
      const referenced = await referencedKeys(env.DB, old.map((object) => object.key));
      const orphanKeys = old.map((object) => object.key).filter((key) => !referenced.has(key));
      if (orphanKeys.length > 0) {
        await env.ATTACHMENTS.delete(orphanKeys);
        deleted += orphanKeys.length;
      }
      cursor = page.truncated ? page.cursor : undefined;
    } while (cursor !== undefined);
  }
  return deleted;
}

async function abandonMissingUploads(env: Pick<Env, "DB" | "ATTACHMENTS">, cutoffIso: string): Promise<number> {
  const rows = await env.DB.prepare(
    `SELECT account_id, attachment_id, r2_object_key
       FROM attachment
      WHERE state = 'allocated' AND created_at < ?
      ORDER BY created_at
      LIMIT 100`,
  ).bind(cutoffIso).all<{ account_id: string; attachment_id: string; r2_object_key: string }>();
  let changed = 0;
  for (const row of rows.results) {
    if (await env.ATTACHMENTS.head(row.r2_object_key) !== null) continue;
    const result = await env.DB.prepare(
      `UPDATE attachment SET state = 'abandoned'
        WHERE account_id = ? AND attachment_id = ? AND state = 'allocated'`,
    ).bind(row.account_id, row.attachment_id).run();
    changed += result.meta.changes ?? 0;
  }
  return changed;
}

/** Runs only from the Worker scheduled event; never from a user request. */
export async function runMaintenance(
  env: Pick<Env, "DB" | "ATTACHMENTS">,
  now = Date.now(),
): Promise<MaintenanceReport> {
  const cutoff = now - GRACE_MS;
  const cutoffIso = new Date(cutoff).toISOString();
  const orphanObjects = await deleteOrphanObjects(env, cutoff);
  const abandoned = await abandonMissingUploads(env, cutoffIso);
  const results = await env.DB.batch([
    env.DB.prepare(
      `DELETE FROM pairing_claim
        WHERE session_id IN (SELECT session_id FROM pairing_session WHERE expires_at < ?)`,
    ).bind(cutoffIso),
    env.DB.prepare("DELETE FROM pairing_session WHERE expires_at < ?").bind(cutoffIso),
  ]);
  return {
    orphan_objects_deleted: orphanObjects,
    attachments_abandoned: abandoned,
    pairing_claims_deleted: results[0]?.meta.changes ?? 0,
    pairing_sessions_deleted: results[1]?.meta.changes ?? 0,
  };
}
