import { ApiError } from "../contracts/error";

/**
 * The one canonical wire projection registry — API draft 4.2 and 4.3.
 *
 * `GET /v1/sync/changes` and `GET /v1/sync/bootstrap` both read through this
 * module and neither owns a mapping of its own. A second mapping is exactly
 * how the two endpoints would start disagreeing about what a room is, and a
 * client that bootstrapped one shape and then pulled another would have no way
 * to tell which was right.
 *
 * Everything here is a closed constant. No column name is ever assembled from
 * a request value: an identity the caller did not expect is a refusal, never a
 * chance to name a column.
 */

export const ENTITY_TYPES = [
  "room",
  "group_state",
  "worldline",
  "turn",
  "bubble",
  "engine_profile",
  "persona_snapshot",
  "checkpoint",
  "attachment",
] as const;

export type EntityType = (typeof ENTITY_TYPES)[number];

/**
 * The fixed bootstrap order (4.3). Owners come before the rows that reference
 * them, so a client applying the stream in order never holds a dangling
 * reference: rooms before their turns, turns before their bubbles, and the
 * versioned AI state before the checkpoints that name it.
 */
export const BOOTSTRAP_ENTITY_ORDER: readonly EntityType[] = ENTITY_TYPES;

export function isEntityType(value: unknown): value is EntityType {
  return typeof value === "string" && (ENTITY_TYPES as readonly string[]).includes(value);
}

/** A storage key, in canonical primary-key order and without `account_id`. */
export type StorageKey = readonly (string | number)[];

export type WireValue = string | number | null;

export interface ProjectedEntity {
  entity_type: EntityType;
  identity: Record<string, WireValue>;
  projection: Record<string, unknown>;
}

/** One extension envelope on the wire. */
interface WireExtension {
  key: string;
  value: string;
}

/**
 * A side table that contributes fields to an owner's projection but is keyed
 * by a prefix of the owner's key: the room's AI state reference and the
 * persona snapshot's head pointer.
 */
interface AuxiliarySpec {
  table: string;
  keyColumns: readonly string[];
  columns: readonly string[];
}

interface EntitySpec {
  table: string;
  /**
   * The owner table's primary-key axes without `account_id`, in canonical
   * order. This is both the ordering used by bootstrap and the set of columns
   * a change row is matched on.
   */
  keyColumns: readonly string[];
  /** Every remaining canonical column, in the order the wire object lists them. */
  valueColumns: readonly string[];
  /** The extension table, when this entity has one. */
  extensionTable: string | null;
  auxiliary: AuxiliarySpec | null;
}

/**
 * `worldline_key` is the D1 storage key; `worldline_id` is the wire value.
 * The empty string is the default worldline of a scope and becomes null, never
 * a sentinel UUID, and the key itself is not a wire field at all.
 */
const WORLDLINE_KEY = "worldline_key";
const WORLDLINE_ID = "worldline_id";

const ENTITY_SPECS: Readonly<Record<EntityType, EntitySpec>> = Object.freeze({
  room: {
    table: "room",
    keyColumns: ["space_id", "room_id"],
    valueColumns: [
      "title_enc",
      "status_message_enc",
      "music_title_enc",
      "music_artist_enc",
      "revision",
      "server_seq",
      "created_at",
      "updated_at",
    ],
    extensionTable: "room_extension_field",
    auxiliary: {
      table: "room_ai_state_ref",
      keyColumns: ["space_id", "room_id"],
      columns: [
        "engine_profile_id",
        "engine_profile_revision",
        "persona_snapshot_id",
        "persona_snapshot_revision",
      ],
    },
  },
  group_state: {
    table: "group_state",
    keyColumns: ["space_id", "room_id"],
    valueColumns: [
      "participants_enc",
      "active_worldline_id_enc",
      "revision",
      "server_seq",
      "created_at",
      "updated_at",
    ],
    extensionTable: null,
    auxiliary: null,
  },
  worldline: {
    table: "worldline",
    keyColumns: ["space_id", "room_id", WORLDLINE_KEY],
    valueColumns: [
      "name_enc",
      "participant_hearts_enc",
      "revision",
      "server_seq",
      "created_at",
      "updated_at",
    ],
    extensionTable: null,
    auxiliary: null,
  },
  turn: {
    table: "turn",
    keyColumns: ["space_id", "room_id", WORLDLINE_KEY, "turn_id"],
    valueColumns: [
      "canonical_text_enc",
      "heart_changes_enc",
      "generation_profile_ref_enc",
      "fallback_reason_enc",
      "created_by_device_id",
      "created_at",
      "revision",
      "server_seq",
      "is_tombstoned",
      "tombstoned_at",
      "tombstone_operation_id",
    ],
    extensionTable: "turn_extension_field",
    auxiliary: null,
  },
  bubble: {
    table: "bubble",
    keyColumns: ["space_id", "room_id", WORLDLINE_KEY, "turn_id", "message_id"],
    valueColumns: [
      "bubble_order",
      "sender_enc",
      "kind_enc",
      "text_enc",
      "speaker_ref_enc",
      "reactions_enc",
      "attachment_ref_attachment_id",
      "attachment_ref_byte_size",
      "timestamp",
      "revision",
      "server_seq",
      "is_tombstoned",
      "tombstoned_at",
      "tombstone_operation_id",
    ],
    extensionTable: "bubble_extension_field",
    auxiliary: null,
  },
  engine_profile: {
    table: "engine_profile",
    keyColumns: ["space_id", "engine_profile_id", "profile_revision"],
    valueColumns: [
      "mode_enc",
      "model_capability_enc",
      "prompt_profile_id_enc",
      "prompt_profile_version_enc",
      "relationship_policy_enc",
      "compaction_profile_id_enc",
      "compaction_contract_fingerprint_enc",
      "cache_policy_enc",
      "repetition_policy_enc",
      "compaction_compat_tag",
      "server_seq",
    ],
    extensionTable: null,
    auxiliary: null,
  },
  persona_snapshot: {
    table: "persona_snapshot",
    keyColumns: ["space_id", "persona_snapshot_id", "snapshot_revision"],
    valueColumns: [
      "owner_space_id",
      "created_by_device_id",
      "created_at",
      "persona_schema_version",
      "description_enc",
      "samples_enc",
      "style_guide_enc",
      "is_enabled_enc",
      "content_fingerprint_enc",
      "server_seq",
    ],
    extensionTable: "persona_snapshot_extension_field",
    auxiliary: {
      table: "persona_snapshot_head",
      keyColumns: ["space_id", "persona_snapshot_id"],
      columns: ["current_snapshot_revision"],
    },
  },
  checkpoint: {
    table: "checkpoint",
    keyColumns: ["space_id", "room_id", WORLDLINE_KEY, "checkpoint_id"],
    valueColumns: [
      "first_turn_id",
      "last_turn_id",
      "through_server_seq",
      "segments_enc",
      "summary_text_enc",
      "checkpoint_schema_version",
      "compaction_profile_id_enc",
      "compaction_contract_fingerprint_enc",
      "compaction_compat_tag",
      "owner_space_id",
      "created_by_device_id",
      "created_at",
      "revision",
      "server_seq",
    ],
    extensionTable: null,
    auxiliary: null,
  },
  attachment: {
    table: "attachment",
    keyColumns: ["attachment_id"],
    // `r2_object_key` is deliberately absent: the server-generated object path
    // never reaches a client, in a projection or anywhere else.
    valueColumns: [
      "origin_space_id",
      "kind",
      "state",
      "source_byte_size",
      "ciphertext_byte_size",
      "ciphertext_hash",
      "key_generation",
      "file_name_enc",
      "mime_type_enc",
      "wrapped_file_key_enc",
      "created_at",
      "server_seq",
    ],
    extensionTable: null,
    auxiliary: null,
  },
});

export function getEntitySpec(entityType: EntityType): EntitySpec {
  return ENTITY_SPECS[entityType];
}

/** `title_enc` becomes `title`; every other name is already the wire name. */
function wireFieldName(column: string): string {
  return column.endsWith("_enc") ? column.slice(0, -4) : column;
}

function storageUnavailable(): ApiError {
  return new ApiError("STORAGE_UNAVAILABLE", { retryable: true });
}

/**
 * The map key for one projection.
 *
 * Built from values the schema already constrains — canonical UUIDs, the space
 * enum, integers — with a separator none of them can contain, so two different
 * identities can never collide into one entry.
 */
export function projectionKey(entityType: EntityType, storageKey: StorageKey): string {
  return `${entityType} ${storageKey.join(" ")}`;
}

/** The subset of `change_log` this module reads. */
export interface ChangeRow {
  server_seq: number;
  entity_type: string;
  change_kind: string;
  revision: number | null;
  space_id: string | null;
  room_id: string | null;
  worldline_key: string | null;
  turn_id: string | null;
  message_id: string | null;
  persona_snapshot_id: string | null;
  snapshot_revision: number | null;
  engine_profile_id: string | null;
  profile_revision: number | null;
  checkpoint_id: string | null;
  attachment_id: string | null;
}

/**
 * Read one change row's storage key.
 *
 * Migration 0008 already guarantees, as a CHECK, that exactly the axes of the
 * row's `entity_type` are non-null, so a null here is a corrupt row rather
 * than a request problem — and answering with a retryable storage code is the
 * only thing that does not describe the row back to the caller.
 */
export function storageKeyOfChange(row: ChangeRow): StorageKey {
  if (!isEntityType(row.entity_type)) {
    throw storageUnavailable();
  }
  const spec = ENTITY_SPECS[row.entity_type];
  const key: (string | number)[] = [];
  for (const column of spec.keyColumns) {
    const value = (row as unknown as Record<string, string | number | null>)[column];
    if (value === null || value === undefined) {
      throw storageUnavailable();
    }
    key.push(value);
  }
  return key;
}

/** Build the wire identity object from a storage key. */
function identityOf(entityType: EntityType, storageKey: StorageKey): Record<string, WireValue> {
  const spec = ENTITY_SPECS[entityType];
  const identity: Record<string, WireValue> = {};
  spec.keyColumns.forEach((column, index) => {
    const value = storageKey[index] as string | number;
    if (column === WORLDLINE_KEY) {
      // The storage key never reaches the wire; the nullable API value does.
      identity[WORLDLINE_ID] = value === "" ? null : value;
      return;
    }
    identity[column] = value;
  });
  return identity;
}

type Row = Record<string, unknown>;

/**
 * Turn one owner row plus its side data into the wire projection.
 *
 * The identity fields lead, then every canonical column in schema order, then
 * the merged auxiliary fields, then `extensions` for the four entities that
 * have them. Nothing is dropped for being null: a client that cannot tell an
 * absent field from a null one cannot apply a clear.
 */
function projectRow(
  entityType: EntityType,
  row: Row,
  extensions: WireExtension[] | null,
  auxiliary: Row | null,
): ProjectedEntity {
  const spec = ENTITY_SPECS[entityType];
  const storageKey = spec.keyColumns.map((column) => row[column] as string | number);
  const identity = identityOf(entityType, storageKey);

  const projection: Record<string, unknown> = { ...identity };
  for (const column of spec.valueColumns) {
    projection[wireFieldName(column)] = row[column] ?? null;
  }
  if (spec.auxiliary !== null) {
    for (const column of spec.auxiliary.columns) {
      // A missing side row is the same as one holding nulls: the reference
      // simply has not been set.
      projection[wireFieldName(column)] = auxiliary === null ? null : (auxiliary[column] ?? null);
    }
  }
  if (extensions !== null) {
    projection["extensions"] = extensions;
  }
  return { entity_type: entityType, identity, projection };
}

/** `SELECT` list for an owner row: keys first, then values. */
function selectColumns(spec: EntitySpec): string {
  return [...spec.keyColumns, ...spec.valueColumns].map((column) => `o.${column}`).join(", ");
}

/**
 * The correlated `EXISTS` that ties an owner row to the page's change rows.
 *
 * This is why a 500-item page is a fixed handful of statements rather than one
 * query per owner. D1 caps bound parameters per statement, so an `IN` over 500
 * composite identities is not merely slow — it does not fit. Matching inside
 * SQLite on the page's sequence window costs three parameters no matter how
 * large the page is, and it returns each identity once even when the page
 * changed it many times.
 *
 * The entity literal is interpolated from the closed `ENTITY_TYPES` constant,
 * never from a request value.
 */
function changeExists(spec: EntitySpec, entityType: EntityType, alias: string): string {
  const axes = spec.keyColumns
    .map((column) => `c.${column} = ${alias}.${column}`)
    .join("\n                 AND ");
  return `EXISTS (SELECT 1 FROM change_log c
               WHERE c.account_id = ${alias}.account_id
                 AND c.entity_type = '${entityType}'
                 AND c.server_seq > ? AND c.server_seq <= ?
                 AND ${axes})`;
}

async function allRows(statement: D1PreparedStatement): Promise<Row[]> {
  try {
    return (await statement.all<Row>()).results;
  } catch {
    throw storageUnavailable();
  }
}

/** Group extension rows by the owner key they belong to, already sorted. */
function indexExtensions(spec: EntitySpec, rows: Row[]): Map<string, WireExtension[]> {
  const byKey = new Map<string, WireExtension[]>();
  for (const row of rows) {
    const key = spec.keyColumns.map((column) => String(row[column])).join(" ");
    const list = byKey.get(key) ?? [];
    list.push({ key: row["extension_key"] as string, value: row["envelope_enc"] as string });
    byKey.set(key, list);
  }
  for (const list of byKey.values()) {
    // Ascending by key, so two servers building the same projection produce
    // byte-identical arrays.
    list.sort((left, right) => (left.key < right.key ? -1 : left.key > right.key ? 1 : 0));
  }
  return byKey;
}

function indexAuxiliary(spec: AuxiliarySpec, rows: Row[]): Map<string, Row> {
  const byKey = new Map<string, Row>();
  for (const row of rows) {
    byKey.set(spec.keyColumns.map((column) => String(row[column])).join(" "), row);
  }
  return byKey;
}

function ownerAuxiliaryKey(spec: EntitySpec, row: Row): string {
  const auxiliary = spec.auxiliary as AuxiliarySpec;
  return auxiliary.keyColumns.map((column) => String(row[column])).join(" ");
}

function ownerExtensionKey(spec: EntitySpec, row: Row): string {
  return spec.keyColumns.map((column) => String(row[column])).join(" ");
}

/**
 * Read every projection touched by the change rows in `(afterSeq, throughSeq]`.
 *
 * The window is the page's own range, so the caller passes the sequence of the
 * last row it is actually returning rather than the whole cursor range.
 */
export async function readChangeProjections(
  db: D1Database,
  accountId: string,
  afterSeq: number,
  throughSeq: number,
): Promise<Map<string, ProjectedEntity>> {
  const projections = new Map<string, ProjectedEntity>();
  if (throughSeq <= afterSeq) {
    return projections;
  }

  for (const entityType of ENTITY_TYPES) {
    const spec = ENTITY_SPECS[entityType];
    const owners = await allRows(
      db
        .prepare(
          `SELECT ${selectColumns(spec)}
             FROM ${spec.table} o
            WHERE o.account_id = ?
              AND ${changeExists(spec, entityType, "o")}`,
        )
        .bind(accountId, afterSeq, throughSeq),
    );
    if (owners.length === 0) {
      continue;
    }

    let extensions = new Map<string, WireExtension[]>();
    if (spec.extensionTable !== null) {
      extensions = indexExtensions(
        spec,
        await allRows(
          db
            .prepare(
              `SELECT ${spec.keyColumns.map((column) => `e.${column}`).join(", ")},
                      e.extension_key, e.envelope_enc
                 FROM ${spec.extensionTable} e
                WHERE e.account_id = ?
                  AND ${changeExists(spec, entityType, "e")}`,
            )
            .bind(accountId, afterSeq, throughSeq),
        ),
      );
    }

    let auxiliary = new Map<string, Row>();
    if (spec.auxiliary !== null) {
      const aux = spec.auxiliary;
      const axes = aux.keyColumns
        .map((column) => `c.${column} = a.${column}`)
        .join("\n                   AND ");
      auxiliary = indexAuxiliary(
        aux,
        await allRows(
          db
            .prepare(
              `SELECT ${[...aux.keyColumns, ...aux.columns].map((column) => `a.${column}`).join(", ")}
                 FROM ${aux.table} a
                WHERE a.account_id = ?
                  AND EXISTS (SELECT 1 FROM change_log c
                               WHERE c.account_id = a.account_id
                                 AND c.entity_type = '${entityType}'
                                 AND c.server_seq > ? AND c.server_seq <= ?
                                 AND ${axes})`,
            )
            .bind(accountId, afterSeq, throughSeq),
        ),
      );
    }

    for (const row of owners) {
      const storageKey = spec.keyColumns.map((column) => row[column] as string | number);
      projections.set(
        projectionKey(entityType, storageKey),
        projectRow(
          entityType,
          row,
          spec.extensionTable === null ? null : (extensions.get(ownerExtensionKey(spec, row)) ?? []),
          spec.auxiliary === null ? null : (auxiliary.get(ownerAuxiliaryKey(spec, row)) ?? null),
        ),
      );
    }
  }

  return projections;
}

/**
 * Look one projection up, refusing to guess when it is absent.
 *
 * A change row with no current row could mean a physical delete, but v1 has
 * none: tombstones are rows with `is_tombstoned = 1`. So an absent projection
 * is a storage condition to retry, never a deletion to infer — inferring one
 * would tell a client to drop data the server still holds.
 */
export function requireProjection(
  projections: Map<string, ProjectedEntity>,
  entityType: EntityType,
  storageKey: StorageKey,
): ProjectedEntity {
  const found = projections.get(projectionKey(entityType, storageKey));
  if (found === undefined) {
    throw storageUnavailable();
  }
  return found;
}

export interface BootstrapPage {
  items: ProjectedEntity[];
  /** The storage key of each item, positionally aligned with `items`. */
  keys: StorageKey[];
  lastKey: StorageKey | null;
}

/** `(a, b) > (?, ?)` — a row value, so a composite key pages without gaps. */
function rowValue(columns: readonly string[], alias: string): string {
  return `(${columns.map((column) => `${alias}.${column}`).join(", ")})`;
}

function placeholders(count: number): string {
  return `(${Array.from({ length: count }, () => "?").join(", ")})`;
}

/**
 * Read one entity's bootstrap page in canonical key order.
 *
 * `afterKey` is the last key of the previous page, so paging is a key range
 * rather than an offset: a row inserted behind the cursor cannot shift the
 * window and make the next page skip or repeat an item.
 */
export async function readBootstrapPage(
  db: D1Database,
  accountId: string,
  entityType: EntityType,
  afterKey: StorageKey | null,
  limit: number,
): Promise<BootstrapPage> {
  const spec = ENTITY_SPECS[entityType];
  const order = spec.keyColumns.map((column) => `o.${column} ASC`).join(", ");
  const after =
    afterKey === null
      ? ""
      : ` AND ${rowValue(spec.keyColumns, "o")} > ${placeholders(spec.keyColumns.length)}`;

  const owners = await allRows(
    db
      .prepare(
        `SELECT ${selectColumns(spec)}
           FROM ${spec.table} o
          WHERE o.account_id = ?${after}
          ORDER BY ${order}
          LIMIT ?`,
      )
      .bind(accountId, ...(afterKey ?? []), limit),
  );
  if (owners.length === 0) {
    return { items: [], keys: [], lastKey: null };
  }

  const firstRow = owners[0] as Row;
  const lastRow = owners[owners.length - 1] as Row;
  const firstKey = spec.keyColumns.map((column) => firstRow[column] as string | number);
  const lastKey = spec.keyColumns.map((column) => lastRow[column] as string | number);

  let extensions = new Map<string, WireExtension[]>();
  if (spec.extensionTable !== null) {
    const bounds = rowValue(spec.keyColumns, "e");
    extensions = indexExtensions(
      spec,
      await allRows(
        db
          .prepare(
            `SELECT ${spec.keyColumns.map((column) => `e.${column}`).join(", ")},
                    e.extension_key, e.envelope_enc
               FROM ${spec.extensionTable} e
              WHERE e.account_id = ?
                AND ${bounds} >= ${placeholders(spec.keyColumns.length)}
                AND ${bounds} <= ${placeholders(spec.keyColumns.length)}`,
          )
          .bind(accountId, ...firstKey, ...lastKey),
      ),
    );
  }

  let auxiliary = new Map<string, Row>();
  if (spec.auxiliary !== null) {
    const aux = spec.auxiliary;
    // The side table is keyed by a prefix of the owner key, and a prefix range
    // of an ordered page still covers every row the page needs.
    const width = aux.keyColumns.length;
    const bounds = rowValue(aux.keyColumns, "a");
    auxiliary = indexAuxiliary(
      aux,
      await allRows(
        db
          .prepare(
            `SELECT ${[...aux.keyColumns, ...aux.columns].map((column) => `a.${column}`).join(", ")}
               FROM ${aux.table} a
              WHERE a.account_id = ?
                AND ${bounds} >= ${placeholders(width)}
                AND ${bounds} <= ${placeholders(width)}`,
          )
          .bind(accountId, ...firstKey.slice(0, width), ...lastKey.slice(0, width)),
      ),
    );
  }

  const items = owners.map((row) =>
    projectRow(
      entityType,
      row,
      spec.extensionTable === null ? null : (extensions.get(ownerExtensionKey(spec, row)) ?? []),
      spec.auxiliary === null ? null : (auxiliary.get(ownerAuxiliaryKey(spec, row)) ?? null),
    ),
  );
  const keys = owners.map((row) => spec.keyColumns.map((column) => row[column] as string | number));
  return { items, keys, lastKey };
}
