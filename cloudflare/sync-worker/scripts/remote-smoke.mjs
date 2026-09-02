/**
 * The remote synthetic smoke run.
 *
 * Drives the deployed synthetic Worker over HTTPS with synthetic fixtures only.
 * Reporting is by status code, error code and invariant: no response body,
 * ciphertext, device token or object key is ever printed, and a failure says
 * which invariant broke rather than dumping what came back.
 *
 * Modes:
 *   node scripts/remote-smoke.mjs --reset    write the synthetic reset SQL to stdout
 *   node scripts/remote-smoke.mjs --seed     write the fixture seed SQL to stdout
 *   node scripts/remote-smoke.mjs            run the smoke suite
 *   node scripts/remote-smoke.mjs --race N   one racer process (used internally)
 *
 * SYNTHETIC_WORKER_URL must name the synthetic Worker. Nothing here is
 * hardcoded to an account, and nothing reads real conversation storage.
 */

import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import {
  ACCOUNT_A,
  ACCOUNT_B,
  ATTACHMENT,
  CIPHERTEXT_BYTES,
  DEVICE_B_MAC,
  DEVICE_MAC,
  DEVICE_PHONE,
  DEVICE_TABLET,
  MAC,
  PHONE,
  TABLET,
  ROOM_SHARED,
  TIMESTAMP,
  TURN_MAIN,
  assertNoLeak,
  call,
  ciphertext,
  createAttachment,
  createBubble,
  createRoom,
  createTurn,
  enrollmentBody,
  errorCode,
  messageId,
  operationId,
  patchRoom,
  requireBaseUrl,
  syntheticToken,
} from "./remote-smoke-lib.mjs";

const TOKEN_SEED_MAC = 1;
const TOKEN_SEED_TABLET = 65;
const TOKEN_SEED_B = 97;
const TOKEN_SEED_PHONE = 129;
const ENROLLMENT_A = "B0000000-0000-4000-8000-0000000000E1";

const checks = [];
let failures = 0;

function record(name, ok, detail = "") {
  checks.push({ name, ok, detail });
  if (!ok) failures += 1;
  process.stdout.write(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? ` — ${detail}` : ""}\n`);
}

function expect(name, condition, detail = "") {
  record(name, Boolean(condition), condition ? "" : detail);
}

/**
 * Fixture rows that do not come from an enrollment.
 *
 * The revoked tablet and the second account are seeded directly because the
 * enrollment endpoint is rate limited to five calls an hour and creates one
 * account per call. Everything they contain is synthetic.
 */
async function printSeedSql() {
  const tablet = await syntheticToken(TOKEN_SEED_TABLET);
  const accountB = await syntheticToken(TOKEN_SEED_B);
  const phone = await syntheticToken(TOKEN_SEED_PHONE);
  const rows = [
    `INSERT OR IGNORE INTO account (account_id, created_at) VALUES ('${ACCOUNT_B}', '${TIMESTAMP}');`,
    `INSERT OR IGNORE INTO device (account_id, device_id, space_id, platform, display_name_enc, linked_at, revoked_at, key_generation, token_hash) VALUES ('${ACCOUNT_B}', '${DEVICE_B_MAC}', 'MAC_SPACE', 'macos', NULL, '${TIMESTAMP}', NULL, 1, '${accountB.tokenHash}');`,
    `INSERT OR IGNORE INTO device (account_id, device_id, space_id, platform, display_name_enc, linked_at, revoked_at, key_generation, token_hash) VALUES ('${ACCOUNT_A}', '${DEVICE_TABLET}', 'TABLET_SPACE', 'android_tablet', NULL, '${TIMESTAMP}', '${TIMESTAMP}', 1, '${tablet.tokenHash}');`,
    // 두 번째 활성 기기. origin 노출 matrix와 답장 수렴은 한 계정에 기기가
    // 둘 있어야 시험할 수 있고, enrollment는 시간당 다섯 번으로 묶여 있다.
    `INSERT OR IGNORE INTO device (account_id, device_id, space_id, platform, display_name_enc, linked_at, revoked_at, key_generation, token_hash) VALUES ('${ACCOUNT_A}', '${DEVICE_PHONE}', 'PHONE_SPACE', 'android_phone', NULL, '${TIMESTAMP}', NULL, 1, '${phone.tokenHash}');`,
  ];
  process.stdout.write(`${rows.join("\n")}\n`);
}

/**
 * Every data table of the synthetic database, in an order foreign keys allow.
 *
 * d1_migrations is deliberately absent: the schema stays, only the synthetic
 * rows go. Nothing here can reach a production database — the caller runs it
 * against the synthetic config, and this database has never held real data.
 */
const RESET_TABLES = [
  "transaction_guard",
  "change_log",
  "operation_log",
  "rate_limit_bucket",
  "enrollment_log",
  "pairing_claim",
  "pairing_session",
  "recovery_record",
  "bubble_extension_field",
  "bubble",
  "turn_extension_field",
  "checkpoint",
  "turn",
  "worldline",
  "group_state",
  "room_extension_field",
  "room_ai_state_ref",
  "room",
  "persona_snapshot_extension_field",
  "persona_snapshot_head",
  "persona_snapshot",
  "engine_profile",
  "attachment",
  "device",
  "account",
];

/**
 * SQL that returns the synthetic database to an empty schema.
 *
 * A smoke run is only repeatable if it starts from a known state: the second
 * run of a create operation is a replay, not an apply, and asserting "applied"
 * against a populated account would be asserting the wrong thing. Clearing the
 * rate limit buckets is part of that — the enrollment endpoint allows five
 * calls an hour, and a rerun must not be blocked by the previous rerun.
 */
function printResetSql() {
  process.stdout.write(`${RESET_TABLES.map((table) => `DELETE FROM ${table};`).join("\n")}\n`);
}

/** One racer: posts a single operation and reports only its status. */
async function runRacer(payloadJson, token) {
  const baseUrl = requireBaseUrl();
  const response = await call(baseUrl, "/v1/sync/operations", {
    method: "POST",
    token,
    headers: { "Content-Type": "application/json" },
    body: payloadJson,
  });
  process.stdout.write(
    `${JSON.stringify({
      status: response.status,
      code: errorCode(response),
      result: response.json?.result?.status ?? null,
      revision: response.json?.result?.revision ?? null,
    })}\n`,
  );
}

/** Spawn two independent OS processes so the requests are genuinely separate. */
async function race(payloads, token) {
  const script = fileURLToPath(import.meta.url);
  const runs = payloads.map(
    (payload) =>
      new Promise((resolve) => {
        const child = spawn(process.execPath, [script, "--race"], {
          env: { ...process.env, RACE_PAYLOAD: payload, RACE_TOKEN: token },
          stdio: ["ignore", "pipe", "inherit"],
        });
        let out = "";
        child.stdout.on("data", (chunk) => {
          out += chunk;
        });
        child.on("close", () => {
          try {
            resolve(JSON.parse(out.trim().split("\n").pop()));
          } catch {
            resolve({ status: 0, code: "SPAWN_FAILED", result: null, revision: null });
          }
        });
      }),
  );
  return await Promise.all(runs);
}

/** The next bubble_order this turn will accept, read from the read path. */
async function nextBubbleOrder(baseUrl, token) {
  const page = await call(baseUrl, "/v1/sync/changes?limit=500", { token });
  const orders = (page.json?.result?.changes ?? [])
    .filter((change) => change.entity_type === "bubble" && change.identity.turn_id === TURN_MAIN)
    .map((change) => change.projection.bubble_order);
  return orders.length === 0 ? 0 : Math.max(...orders) + 1;
}

async function main() {
  const baseUrl = requireBaseUrl();
  const mac = await syntheticToken(TOKEN_SEED_MAC);
  const tablet = await syntheticToken(TOKEN_SEED_TABLET);
  const accountB = await syntheticToken(TOKEN_SEED_B);
  const secrets = [mac.token, tablet.token, accountB.token];

  // ── 1. health and content-free routing ─────────────────────────────────────
  const health = await call(baseUrl, "/v1/health");
  expect("health returns 200", health.status === 200, `status ${health.status}`);
  expect("health names protocol 1", health.json?.protocol_version === 1);
  expect("health is https", baseUrl.startsWith("https://"));

  const unknown = await call(baseUrl, "/v1/nope");
  expect("unknown path is 404", unknown.status === 404, `status ${unknown.status}`);
  expect("unknown path is content-free", errorCode(unknown) === "NOT_FOUND");
  const wrongMethod = await call(baseUrl, "/v1/sync/operations", { method: "GET" });
  expect("wrong method is 404", wrongMethod.status === 404, `status ${wrongMethod.status}`);
  assertNoLeak("routing errors", unknown.text + wrongMethod.text, secrets);
  record("routing errors disclose nothing", true);

  // ── 2. enrollment and its replay ───────────────────────────────────────────
  const skipEnrollment = process.env["SMOKE_SKIP_ENROLLMENT"] === "1";
  const enrollRaw = await enrollmentBody({
    accountId: ACCOUNT_A,
    deviceId: DEVICE_MAC,
    spaceId: MAC,
    platform: "macos",
    tokenHash: mac.tokenHash,
    enrollmentId: ENROLLMENT_A,
    seed: 11,
  });
  if (skipEnrollment) {
    record("enrollment skipped this run (rate-limited endpoint, proved earlier)", true);
  } else {
    const enrolled = await call(baseUrl, "/v1/enrollment/initialize", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: enrollRaw,
    });
    const enrolledOk = enrolled.status === 201 || enrolled.status === 200;
    expect("enrollment succeeds", enrolledOk, `status ${enrolled.status} ${errorCode(enrolled) ?? ""}`);

    // The identical bytes again: a client that never saw the first response.
    const replayed = await call(baseUrl, "/v1/enrollment/initialize", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: enrollRaw,
    });
    expect("enrollment replay is accepted", replayed.status === 200, `status ${replayed.status}`);
    expect("enrollment replay is marked replayed", replayed.json?.result?.status === "replayed");
    assertNoLeak("enrollment responses", enrolled.text + replayed.text, secrets);
  }

  // ── 3. device token authentication ─────────────────────────────────────────
  const noToken = await call(baseUrl, "/v1/sync/changes");
  expect("changes without a token is 401", noToken.status === 401, `status ${noToken.status}`);
  const authed = await call(baseUrl, "/v1/sync/changes?limit=1", { token: mac.token });
  expect("changes with the enrolled token is 200", authed.status === 200, `status ${authed.status}`);

  // ── 4. operations: create, replay, CAS ─────────────────────────────────────
  const roomRaw = JSON.stringify(createRoom(operationId(1), MAC, ROOM_SHARED, DEVICE_MAC));
  const room = await call(baseUrl, "/v1/sync/operations", {
    method: "POST",
    token: mac.token,
    headers: { "Content-Type": "application/json" },
    body: roomRaw,
  });
  expect("create_room applies", room.json?.result?.status === "applied", `status ${room.status} ${errorCode(room) ?? ""}`);

  const roomReplay = await call(baseUrl, "/v1/sync/operations", {
    method: "POST",
    token: mac.token,
    headers: { "Content-Type": "application/json" },
    body: roomRaw,
  });
  expect("identical operation bytes replay", roomReplay.json?.result?.status === "replayed");
  expect(
    "replay returns the original sequence",
    roomReplay.json?.result?.server_seq === room.json?.result?.server_seq,
  );

  const patched = await call(baseUrl, "/v1/sync/operations", {
    method: "POST",
    token: mac.token,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(patchRoom(operationId(2), 0, DEVICE_MAC)),
  });
  expect("patch_room at the current revision applies", patched.json?.result?.status === "applied");

  const beforeStale = await call(baseUrl, "/v1/sync/changes?limit=500", { token: mac.token });
  const stale = await call(baseUrl, "/v1/sync/operations", {
    method: "POST",
    token: mac.token,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(patchRoom(operationId(3), 0, DEVICE_MAC, 9)),
  });
  expect("stale CAS is refused", stale.status === 409, `status ${stale.status}`);
  expect("stale CAS names the conflict", errorCode(stale) === "REVISION_CONFLICT");
  const afterStale = await call(baseUrl, "/v1/sync/changes?limit=500", { token: mac.token });
  expect(
    "stale CAS leaves the ledger untouched",
    afterStale.json?.result?.account_high_watermark_seq ===
      beforeStale.json?.result?.account_high_watermark_seq,
  );

  // ── 5. attachment: allocate, upload, complete, download ────────────────────
  const bytes = ciphertext();
  const allocate = await call(baseUrl, "/v1/sync/operations", {
    method: "POST",
    token: mac.token,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(await createAttachment(operationId(4), DEVICE_MAC, MAC)),
  });
  expect("create_attachment applies", allocate.json?.result?.status === "applied", `status ${allocate.status} ${errorCode(allocate) ?? ""}`);
  expect("attachment carries no revision", allocate.json?.result?.revision === null);

  const uploaded = await call(baseUrl, `/v1/attachments/${ATTACHMENT}/content`, {
    method: "PUT",
    token: mac.token,
    headers: { "Content-Length": String(bytes.byteLength) },
    body: bytes,
  });
  expect("attachment upload is 204", uploaded.status === 204, `status ${uploaded.status} ${errorCode(uploaded) ?? ""}`);

  const completed = await call(baseUrl, `/v1/attachments/${ATTACHMENT}/complete`, {
    method: "POST",
    token: mac.token,
  });
  expect("attachment complete is 204", completed.status === 204, `status ${completed.status} ${errorCode(completed) ?? ""}`);

  const download = await fetch(`${baseUrl}/v1/attachments/${ATTACHMENT}/content`, {
    headers: { Authorization: `Device ${mac.token}` },
  });
  expect("attachment download is 200", download.status === 200, `status ${download.status}`);
  expect(
    "download is opaque octet-stream",
    download.headers.get("content-type") === "application/octet-stream",
  );
  expect("download is not cached", download.headers.get("cache-control") === "private, no-store");
  const downloaded = new Uint8Array(await download.arrayBuffer());
  expect("download length matches the metadata", downloaded.byteLength === CIPHERTEXT_BYTES);
  expect(
    "downloaded bytes equal the uploaded bytes",
    Buffer.from(downloaded).equals(Buffer.from(bytes)),
  );
  assertNoLeak("download headers", JSON.stringify([...download.headers]), secrets);

  // ── 6. turn and the bubble that references the ready attachment ────────────
  const turn = await call(baseUrl, "/v1/sync/operations", {
    method: "POST",
    token: mac.token,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(createTurn(operationId(5), DEVICE_MAC)),
  });
  expect("create_turn applies", turn.json?.result?.status === "applied", `status ${turn.status} ${errorCode(turn) ?? ""}`);

  const firstOrder = await nextBubbleOrder(baseUrl, mac.token);
  const bubble = await call(baseUrl, "/v1/sync/operations", {
    method: "POST",
    token: mac.token,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(
      createBubble(operationId(6), DEVICE_MAC, messageId(1 + firstOrder), firstOrder, ATTACHMENT),
    ),
  });
  expect("bubble referencing a ready attachment applies", bubble.json?.result?.status === "applied", `status ${bubble.status} ${errorCode(bubble) ?? ""}`);

  // ── 7. changes and bootstrap agree ─────────────────────────────────────────
  const changes = await call(baseUrl, "/v1/sync/changes?limit=500", { token: mac.token });
  expect("changes drains in one page", changes.json?.result?.has_more === false);
  expect(
    "changes reaches the watermark",
    changes.json?.result?.scanned_through_seq ===
      changes.json?.result?.account_high_watermark_seq,
  );

  const items = [];
  let query = "?limit=2";
  let pages = 0;
  let watermark = null;
  for (let page = 0; page < 50; page += 1) {
    const bootstrap = await call(baseUrl, `/v1/sync/bootstrap${query}`, { token: mac.token });
    if (bootstrap.status !== 200) {
      break;
    }
    pages += 1;
    watermark ??= bootstrap.json.result.snapshot_high_watermark_seq;
    items.push(...bootstrap.json.result.items);
    if (!bootstrap.json.result.has_more) break;
    query = `?cursor=${encodeURIComponent(bootstrap.json.result.next_cursor)}&limit=2`;
  }
  expect("bootstrap pages more than once", pages > 1, `pages ${pages}`);
  expect("bootstrap holds a stable snapshot", watermark !== null);

  let mismatched = 0;
  for (const item of items) {
    const matching = (changes.json?.result?.changes ?? []).filter(
      (change) =>
        change.entity_type === item.entity_type &&
        JSON.stringify(change.identity) === JSON.stringify(item.identity),
    );
    const last = matching[matching.length - 1];
    if (!last || JSON.stringify(last.projection) !== JSON.stringify(item.projection)) {
      mismatched += 1;
    }
  }
  expect(
    "changes and bootstrap agree on every identity",
    mismatched === 0 && items.length > 0,
    `${mismatched} of ${items.length} disagreed`,
  );
  assertNoLeak("read pages", changes.text + JSON.stringify(items), secrets);

  // ── 8. revoked device and tenant isolation ─────────────────────────────────
  const revokedWrite = await call(baseUrl, "/v1/sync/operations", {
    method: "POST",
    token: tablet.token,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(createTurn(operationId(7), DEVICE_TABLET, TURN_MAIN)),
  });
  const revokedChanges = await call(baseUrl, "/v1/sync/changes", { token: tablet.token });
  const revokedBootstrap = await call(baseUrl, "/v1/sync/bootstrap", { token: tablet.token });
  const revokedDownload = await call(baseUrl, `/v1/attachments/${ATTACHMENT}/content`, {
    token: tablet.token,
  });
  expect(
    "a revoked device is refused everywhere",
    [revokedWrite, revokedChanges, revokedBootstrap, revokedDownload].every(
      (response) => response.status === 403 && errorCode(response) === "DEVICE_REVOKED",
    ),
    `${revokedWrite.status}/${revokedChanges.status}/${revokedBootstrap.status}/${revokedDownload.status}`,
  );

  const otherChanges = await call(baseUrl, "/v1/sync/changes?limit=500", { token: accountB.token });
  const otherBootstrap = await call(baseUrl, "/v1/sync/bootstrap?limit=500", {
    token: accountB.token,
  });
  const otherDownload = await call(baseUrl, `/v1/attachments/${ATTACHMENT}/content`, {
    token: accountB.token,
  });
  expect("the second account sees no changes", otherChanges.json?.result?.changes?.length === 0);
  expect("the second account sees no snapshot", otherBootstrap.json?.result?.items?.length === 0);
  expect("the second account cannot read the attachment", otherDownload.status === 404);
  expect(
    "the second account is shown nothing of the first",
    !otherChanges.text.includes(ROOM_SHARED) && !otherBootstrap.text.includes(ROOM_SHARED),
  );
  assertNoLeak(
    "isolation responses",
    otherChanges.text + otherBootstrap.text + revokedChanges.text,
    secrets,
  );
  record("no response disclosed a token, key, SQL or stack", true);

  // ── 9. independent remote request concurrency ──────────────────────────────
  // Two separate OS processes, so these are genuinely independent HTTP clients
  // rather than two promises in one event loop. Whether Cloudflare served them
  // from two isolates is not observable from here and is not claimed.
  const currentRevision = (await call(baseUrl, "/v1/sync/changes?limit=500", { token: mac.token }))
    .json.result.changes.filter((change) => change.entity_type === "room")
    .pop()?.projection?.revision;

  const casRace = await race(
    [
      JSON.stringify(patchRoom(operationId(20), currentRevision, DEVICE_MAC, 21)),
      JSON.stringify(patchRoom(operationId(21), currentRevision, DEVICE_MAC, 22)),
    ],
    mac.token,
  );
  const casWinners = casRace.filter((result) => result.result === "applied").length;
  const casLosers = casRace.filter((result) => result.code === "REVISION_CONFLICT").length;
  expect(
    "exactly one CAS patch commits",
    casWinners === 1 && casLosers === 1,
    `${casWinners} applied, ${casLosers} conflicted`,
  );

  // Both racers ask for the order the scope will actually accept next, so the
  // contest is real rather than two requests losing to a stale expectation.
  const contested = await nextBubbleOrder(baseUrl, mac.token);
  const orderRace = await race(
    [
      JSON.stringify(
        createBubble(operationId(22), DEVICE_MAC, messageId(200 + contested), contested, null, 23),
      ),
      JSON.stringify(
        createBubble(operationId(23), DEVICE_MAC, messageId(300 + contested), contested, null, 24),
      ),
    ],
    mac.token,
  );
  const orderWinners = orderRace.filter((result) => result.result === "applied").length;
  const orderLosers = orderRace.filter(
    (result) => result.code === "BUBBLE_ORDER_CONFLICT" || result.code === "REVISION_CONFLICT",
  ).length;
  expect(
    "exactly one bubble takes the contested order",
    orderWinners === 1 && orderLosers === 1,
    `${orderWinners} applied, ${orderLosers} conflicted`,
  );

  const sameBytes = JSON.stringify(patchRoom(operationId(24), currentRevision + 1, DEVICE_MAC, 25));
  const sameRace = await race([sameBytes, sameBytes], mac.token);
  expect(
    "identical bytes under the same id never apply twice",
    sameRace.filter((result) => result.result === "applied").length <= 1 &&
      sameRace.every((result) => result.status === 200),
    sameRace.map((result) => result.result ?? result.code).join("/"),
  );

  const differentBytes = await call(baseUrl, "/v1/sync/operations", {
    method: "POST",
    token: mac.token,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(patchRoom(operationId(24), currentRevision + 1, DEVICE_MAC, 99)),
  });
  expect(
    "different bytes under a used id are a replay mismatch",
    errorCode(differentBytes) === "OPERATION_REPLAY_MISMATCH",
    `${differentBytes.status} ${errorCode(differentBytes) ?? ""}`,
  );

  // The ledger, not a guess, decides what survived the races.
  const settled = await call(baseUrl, "/v1/sync/changes?limit=500", { token: mac.token });
  const settledBootstrap = [];
  let settleQuery = "?limit=500";
  for (let page = 0; page < 50; page += 1) {
    const response = await call(baseUrl, `/v1/sync/bootstrap${settleQuery}`, { token: mac.token });
    settledBootstrap.push(...response.json.result.items);
    if (!response.json.result.has_more) break;
    settleQuery = `?cursor=${encodeURIComponent(response.json.result.next_cursor)}&limit=500`;
  }
  let settledMismatch = 0;
  for (const item of settledBootstrap) {
    const matching = settled.json.result.changes.filter(
      (change) =>
        change.entity_type === item.entity_type &&
        JSON.stringify(change.identity) === JSON.stringify(item.identity),
    );
    const last = matching[matching.length - 1];
    if (!last || JSON.stringify(last.projection) !== JSON.stringify(item.projection)) {
      settledMismatch += 1;
    }
  }
  expect(
    "both read paths agree after the races",
    settledMismatch === 0,
    `${settledMismatch} disagreed`,
  );

  // ── 9b. room family origin과 답장 수렴 ───────────────────────────────────
  //
  // 0011·0012가 강제하는 규칙이 배포본에서 실제로 도는지 본다. 강제 migration을
  // 넣고 강제를 확인하지 않을 수는 없다.
  const phone = await syntheticToken(TOKEN_SEED_PHONE);
  const ROOM_ORIGIN_MAC = "10000000-0000-4000-8000-000000000011";
  const ROOM_PHONE_ORIGIN = "10000000-0000-4000-8000-000000000012";

  const macOrigin = await call(baseUrl, "/v1/sync/operations", {
    method: "POST",
    token: mac.token,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(createRoom(operationId(70), MAC, ROOM_ORIGIN_MAC, DEVICE_MAC)),
  });
  expect(
    "a MAC-origin room is created by the MAC device",
    macOrigin.json?.result?.status === "applied",
    `status ${macOrigin.status} ${errorCode(macOrigin) ?? ""}`,
  );

  const phoneOrigin = await call(baseUrl, "/v1/sync/operations", {
    method: "POST",
    token: phone.token,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(createRoom(operationId(71), PHONE, ROOM_PHONE_ORIGIN, DEVICE_PHONE)),
  });
  expect(
    "a PHONE-origin room is created by the PHONE device",
    phoneOrigin.json?.result?.status === "applied",
    `status ${phoneOrigin.status} ${errorCode(phoneOrigin) ?? ""}`,
  );

  // 자기 space가 아닌 origin을 주장하면 거부해야 한다. 0012의 트리거 자리다.
  const forged = await call(baseUrl, "/v1/sync/operations", {
    method: "POST",
    token: phone.token,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      ...createRoom(operationId(72), PHONE, "10000000-0000-4000-8000-000000000013", DEVICE_PHONE),
      metadata_set: { origin_space_id: TABLET },
    }),
  });
  expect(
    "a room claiming another space as its origin is refused",
    forged.json?.result?.status !== "applied",
    `status ${forged.status} ${errorCode(forged) ?? ""}`,
  );
  // 거부 자체는 body가 깨져도 일어난다. 잘 만든 요청이 통과하는 것을 함께
  // 확인해야 이 거부가 origin 때문임이 증명된다.
  const honest = await call(baseUrl, "/v1/sync/operations", {
    method: "POST",
    token: phone.token,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(
      createRoom(operationId(73), PHONE, "10000000-0000-4000-8000-000000000014", DEVICE_PHONE),
    ),
  });
  expect(
    "the same shape without a forged origin is accepted",
    honest.json?.result?.status === "applied",
    `status ${honest.status} ${errorCode(honest) ?? ""}`,
  );

  // 두 기기가 각자 쓴 뒤 서로의 change feed가 같은 identity 집합을 본다.
  // 어긋나면 기기마다 다른 대화를 보게 된다.
  const macFeed = await call(baseUrl, "/v1/sync/changes?after_seq=0&limit=500", { token: mac.token });
  const phoneFeed = await call(baseUrl, "/v1/sync/changes?after_seq=0&limit=500", { token: phone.token });
  const identitySet = (response) =>
    new Set(
      (response.json?.result?.changes ?? []).map(
        (change) => `${change.entity_type}|${JSON.stringify(change.identity)}`,
      ),
    );
  const macIdentities = identitySet(macFeed);
  const phoneIdentities = identitySet(phoneFeed);
  const onlyMac = [...macIdentities].filter((identity) => !phoneIdentities.has(identity));
  const onlyPhone = [...phoneIdentities].filter((identity) => !macIdentities.has(identity));
  expect(
    "both devices converge on the same identities",
    onlyMac.length === 0 && onlyPhone.length === 0,
    `${onlyMac.length} mac-only, ${onlyPhone.length} phone-only`,
  );
  expect("the converged feed is not empty", macIdentities.size > 0, `${macIdentities.size} identities`);

  const originRows = (macFeed.json?.result?.changes ?? []).filter(
    (change) => change.entity_type === "room",
  );
  const originOf = (roomId) =>
    originRows.find((row) => row.identity?.room_id === roomId)?.projection?.origin_space_id;
  expect("the MAC-origin room reports MAC_SPACE", originOf(ROOM_ORIGIN_MAC) === MAC, String(originOf(ROOM_ORIGIN_MAC)));
  expect("the PHONE-origin room reports PHONE_SPACE", originOf(ROOM_PHONE_ORIGIN) === PHONE, String(originOf(ROOM_PHONE_ORIGIN)));

  // ── 10. summary ────────────────────────────────────────────────────────────
  process.stdout.write(`\n${checks.length - failures}/${checks.length} checks passed\n`);
  if (failures > 0) process.exitCode = 1;
}

/**
 * 운영 데이터만 지우고 account·device·enrollment_log·rate_limit_bucket을 남긴다.
 *
 * 전체 초기화 뒤에는 seed가 걸린다. 폐기된 태블릿이 account A에 속하는데 그
 * account를 만드는 것이 enrollment이기 때문이다. 다시 돌릴 때는 계정과 기기를
 * 남기고 대화만 지우는 이 모드를 쓰고 SMOKE_SKIP_ENROLLMENT=1로 실행한다.
 */
function printPartialResetSql() {
  const keep = new Set(["account", "device", "enrollment_log", "rate_limit_bucket"]);
  const tables = RESET_TABLES.filter((table) => !keep.has(table));
  process.stdout.write(`${tables.map((table) => `DELETE FROM ${table};`).join("\n")}\n`);
}

const mode = process.argv[2];
if (mode === "--reset") {
  printResetSql();
} else if (mode === "--partial-reset") {
  printPartialResetSql();
} else if (mode === "--seed") {
  await printSeedSql();
} else if (mode === "--race") {
  await runRacer(process.env["RACE_PAYLOAD"], process.env["RACE_TOKEN"]);
} else {
  await main();
}
