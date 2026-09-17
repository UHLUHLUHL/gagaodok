#!/usr/bin/env node
// 실제 요청 순서를 폰 캐시 규칙으로 다시 돌려 TTL별 입력 비용을 비교한다.
//
// 캐시 수명은 마지막 요청이 아니라 캐시를 만든 시각부터 흐르므로, 간격 분포만으로는
// 어떤 TTL이 싼지 정할 수 없다. 요청 순서를 그대로 다시 돌린다.
//
// 입력 두 가지:
//   node tools/ttl_replay.js ledger <optimization_measurements.json>
//     측정 장부의 요청 기록(requestLog). 실제 입력 토큰을 쓰고, MEMORY 요청을 요약 시점으로 본다.
//   node tools/ttl_replay.js messages <대화 폴더> [<대화 폴더> ...]
//     room_*_messages.json의 사용자 메시지 시각만 읽는다(본문은 읽지 않는다). 재생성·삭제된
//     요청은 빠지고, 입력 토큰은 P(기본 27,000)와 교환당 G(기본 400)로 어림한다.
//
// 흉내 내는 규칙(android/.../service/AIServicePrefixCache.kt `refreshPrefixCache`):
//   - 캐시 갱신은 답을 받은 뒤에 한다. 이번 요청은 그 전의 캐시로 나간다.
//   - 캐시가 없으면 직전 요청이 5분 안일 때만 만든다(NOT_BURST).
//   - 캐시가 있으면 새로 붙은 꼬리가 max(2,000, 캐시/5) 이상이거나 만료 4분 전일 때만 새로 만든다.
//   - 요약이 바뀌면 앞부분이 달라져 캐시를 못 쓴다.
//   - 생성은 청구되지 않고, 보관료는 산 시간만큼(교체되면 그 시각까지) 붙는다.
// 흉내 내지 않는 것: 서버의 암묵 캐시, 재생성 보호(두 칸 물림), 출력 요금(TTL과 무관).
const fs = require("fs");
const path = require("path");

const KRW = Number(process.env.KRW || 1383);
const UNCACHED = 0.75 / 1e6 * KRW, CACHED = 0.075 / 1e6 * KRW, STORE = 0.5 / 1e6 * KRW;
const BURST = 300, FLOOR = 240, MIN_TAIL = 2000;
const TTLS = (process.env.TTLS || "5,10,15,20,25,30,45,60").split(",").map(m => Number(m) * 60);
const P = Number(process.env.P || 27000);
const G = Number(process.env.G || 400);
const COMPACT_EVERY = 80;

// 각 방: [{ t(초), input(토큰), compacted(이 요청 전에 요약이 바뀌었는가) }]
function fromLedger(file) {
  const ledger = JSON.parse(fs.readFileSync(file));
  const runs = [...(ledger.completedRuns || []), ...(ledger.activeRun ? [ledger.activeRun] : [])];
  const byRoom = {};
  for (const run of runs) for (const e of run.requestLog || []) (byRoom[e.roomKey.toLowerCase()] ||= []).push(e);
  const rooms = [];
  for (const [id, entries] of Object.entries(byRoom)) {
    entries.sort((a, b) => a.atMillis - b.atMillis);
    const requests = [];
    let pendingCompaction = false;
    for (const e of entries) {
      if (e.workload === "MEMORY") { pendingCompaction = true; continue; }
      if (e.unreported) continue;
      requests.push({ t: e.atMillis / 1000, input: e.inputTokens, compacted: pendingCompaction });
      pendingCompaction = false;
    }
    if (requests.length) rooms.push({ id: id.slice(0, 8), group: "ledger", requests });
  }
  return rooms;
}

function fromMessages(dirs) {
  const rooms = [];
  for (const dir of dirs) {
    let meta = {};
    try {
      const list = JSON.parse(fs.readFileSync(path.join(dir, "rooms_list.json")));
      meta = Object.fromEntries((Array.isArray(list) ? list : list.rooms).map(r => [r.id.toUpperCase(), r]));
    } catch {}
    for (const f of fs.readdirSync(dir).filter(f => /^room_.*_messages\.json$/.test(f))) {
      let arr;
      try { arr = JSON.parse(fs.readFileSync(path.join(dir, f))); } catch { continue; }
      if (!Array.isArray(arr)) continue;
      const times = arr.filter(m => m.sender === "user").map(m => m.timestamp + 978307200).sort((a, b) => a - b);
      if (!times.length) continue;
      const id = f.slice(5, 41).toUpperCase();
      const requests = times.map((t, i) => ({ t, input: null, compacted: i > 0 && i % COMPACT_EVERY === 0 }));
      rooms.push({ id: id.slice(0, 8), group: `${path.basename(dir)}/${(meta[id] || {}).modeIdentifier || "?"}`, requests });
    }
  }
  return rooms;
}

function simulate(requests, ttl) {
  let input = 0, store = 0, hits = 0, creates = 0, cache = null;
  const settle = until => {
    store += cache.size * Math.max(0, Math.min(until, cache.exp) - cache.created) / 3600 * STORE;
    cache = null;
  };
  requests.forEach((r, i) => {
    const size = r.input ?? P;
    if (cache && r.compacted) settle(r.t);
    if (cache && r.t >= cache.exp) settle(cache.exp);
    // 요청 기록에서는 대화가 캐시보다 짧아지면(재생성·요약) 캐시를 못 쓴다.
    if (cache && r.input !== null && size < cache.size) settle(r.t);
    const tail = cache ? (r.input !== null ? size - cache.size : G * (i - cache.idx)) : 0;
    if (cache) { hits++; input += cache.size * CACHED + tail * UNCACHED; }
    else input += size * UNCACHED;

    const prev = i > 0 ? requests[i - 1].t : null;
    if (!cache) {
      if (prev === null || r.t - prev > BURST) return;
    } else {
      const worth = tail >= Math.max(MIN_TAIL, cache.size / 5);
      const soon = cache.exp <= r.t + FLOOR;
      if (!worth && !soon) return;
      settle(r.t);
    }
    cache = { created: r.t, exp: r.t + ttl, size, idx: i };
    creates++;
  });
  if (cache) settle(cache.exp);
  return { input, store, hits, creates, n: requests.length };
}

function report(rooms) {
  const gaps = rooms.flatMap(r => r.requests.slice(1).map((q, i) => q.t - r.requests[i].t));
  const count = (lo, hi) => gaps.filter(g => g > lo * 60 && g <= hi * 60).length;
  console.log(`요청 ${rooms.reduce((s, r) => s + r.requests.length, 0)}건, 방 ${rooms.length}개`);
  console.log("간격(분):", [[0, 5], [5, 10], [10, 15], [15, 20], [20, 25], [25, 30], [30, 45], [45, 60], [60, Infinity]]
    .map(([a, b]) => `${a}~${b === Infinity ? "" : b} ${count(a, b)}`).join(" | "));
  console.log("1분 단위 0~60분:", Array.from({ length: 60 }, (_, m) => count(m, m + 1)).join(","));
  const groups = {};
  for (const r of rooms) (groups[r.group] ||= []).push(r);
  for (const [group, rs] of Object.entries(groups)) {
    const n = rs.reduce((s, r) => s + r.requests.length, 0);
    console.log(`\n[${group}] 방 ${rs.length}개, 요청 ${n}건`);
    for (const ttl of TTLS) {
      const s = rs.map(r => simulate(r.requests, ttl)).reduce((a, b) =>
        Object.fromEntries(Object.keys(a).map(k => [k, a[k] + b[k]])));
      const per = v => (v / s.n * 100).toFixed(0);
      console.log(`  TTL ${String(ttl / 60).padStart(2)}분: 100요청당 ${per(s.input + s.store).padStart(5)}원` +
        ` (입력 ${per(s.input)}, 보관 ${per(s.store)}) 캐시 ${(s.hits / s.n * 100).toFixed(1)}% 생성 ${s.creates}회`);
    }
  }
}

const [mode, ...args] = process.argv.slice(2);
if (mode === "ledger" && args.length === 1) report(fromLedger(args[0]));
else if (mode === "messages" && args.length >= 1) report(fromMessages(args));
else {
  console.error("사용법: ttl_replay.js ledger <장부.json> | messages <대화 폴더>...");
  process.exit(2);
}
