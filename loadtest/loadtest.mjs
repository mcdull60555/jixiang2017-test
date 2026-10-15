// 基翔小學通 負載測試：模擬 N 位學生登入、讀資料、輪詢、送出作業。
// 需要 Node.js 18 以上。用法：
//   node loadtest.mjs                 （預設 100 人、同時登入、輪詢 2 分鐘）
//   STUDENTS=50 POLL_SECONDS=60 node loadtest.mjs
// 只連你的 Supabase 測試專案，只用 load_1～load_N 假帳號（密碼 0000）。
const URL_ = process.env.SUPABASE_URL || "https://jflnvliefjfxhfwjzqdi.supabase.co";
const KEY = process.env.SUPABASE_KEY || "sb_publishable_ZVT08ujYz6NmsowKmqBNng_JxBJaVmb";
const N = +(process.env.STUDENTS || 100);
const POLL_SECONDS = +(process.env.POLL_SECONDS || 120);
const POLL_EVERY = +(process.env.POLL_EVERY_SECONDS || 22);   // 網頁實際約 20～25 秒
const SUBMITS = +(process.env.SUBMITS_PER_STUDENT || 3);
const RAMP_MS = +(process.env.RAMP_MS || 0);                   // 0＝全部同一秒登入（最嚴苛）

const stats = {};
let bytesIn = 0;
function rec(name, ms, ok, status) { (stats[name] ||= { t: [], err: 0, codes: {} }); stats[name].t.push(ms); if (!ok) stats[name].err++; stats[name].codes[status] = (stats[name].codes[status] || 0) + 1; }
async function call(name, path, { method = "GET", body, token } = {}) {
  const t0 = performance.now();
  try {
    const r = await fetch(URL_ + path, { method, headers: { apikey: KEY, Authorization: "Bearer " + (token || KEY), "Content-Type": "application/json" }, body: body ? JSON.stringify(body) : undefined });
    const txt = await r.text(); bytesIn += txt.length;
    rec(name, performance.now() - t0, r.ok, r.status);
    let j = null; try { j = JSON.parse(txt); } catch (_) {}
    return { ok: r.ok, status: r.status, json: j };
  } catch (e) { rec(name, performance.now() - t0, false, "網路錯誤"); return { ok: false, status: 0, json: null }; }
}
const sleep = ms => new Promise(r => setTimeout(r, ms));

async function student(i) {
  if (RAMP_MS) await sleep(Math.random() * RAMP_MS);
  const sid = "load_" + i;
  const lg = await call("登入(Edge Function)", "/functions/v1/login", { method: "POST", body: { email: sid + "@school.test", pin: "0000" } });
  const token = lg.json && lg.json.access_token;
  if (!token) return;
  const q = (name, p, o = {}) => call(name, p, { token, ...o });
  // 登入後網頁會做的事：取指紋、讀自己的項目、學生資料、班級、聯絡簿
  await Promise.all([
    q("取資料指紋", "/rest/v1/rpc/get_data_version", { method: "POST", body: {} }),
    q("讀自己的項目", `/rest/v1/tasks?select=*&student_id=eq.${sid}&order=created_at`),
    q("讀聯絡簿", "/rest/v1/rpc/get_contact_book", { method: "POST", body: {} }),
    q("讀班級名單", "/rest/v1/class_students?select=class_id,student_id"),
  ]);
  // 送出幾項作業
  const t = await q("讀項目id", `/rest/v1/tasks?select=id&student_id=eq.${sid}&student_checked=eq.false&limit=${SUBMITS}`);
  const ids = (t.json || []).map(x => x.id);
  if (ids.length) await q("送出審核(RPC)", "/rest/v1/rpc/student_submit", { method: "POST", body: { p_ids: ids } });
  // 上課期間輪詢
  const end = Date.now() + POLL_SECONDS * 1000;
  await sleep(Math.random() * POLL_EVERY * 1000);
  while (Date.now() < end) {
    await q("輪詢指紋", "/rest/v1/rpc/get_data_version", { method: "POST", body: {} });
    await sleep(POLL_EVERY * 1000);
  }
}

function pct(a, p) { const s = [...a].sort((x, y) => x - y); return s[Math.min(s.length - 1, Math.floor(s.length * p))]; }
console.log(`開始：${N} 位學生，${RAMP_MS ? "分散在 " + RAMP_MS / 1000 + " 秒內登入" : "同一秒同時登入"}，輪詢 ${POLL_SECONDS} 秒（每 ${POLL_EVERY} 秒一次）`);
const t0 = Date.now();
await Promise.all(Array.from({ length: N }, (_, i) => student(i + 1)));
console.log(`\n結束，共 ${((Date.now() - t0) / 1000).toFixed(0)} 秒，下載資料量 ${(bytesIn / 1024).toFixed(0)} KB\n`);
console.log("操作".padEnd(22), "次數".padStart(5), "失敗".padStart(5), "平均ms".padStart(8), "p95 ms".padStart(8), "最慢ms".padStart(8), " 狀態碼");
for (const [k, v] of Object.entries(stats)) {
  const avg = v.t.reduce((a, b) => a + b, 0) / v.t.length;
  console.log(k.padEnd(22), String(v.t.length).padStart(5), String(v.err).padStart(5), avg.toFixed(0).padStart(8), pct(v.t, 0.95).toFixed(0).padStart(8), Math.max(...v.t).toFixed(0).padStart(8), " ", JSON.stringify(v.codes));
}
const loginErr = stats["登入(Edge Function)"]?.err || 0;
console.log(loginErr ? `\n⚠️ 有 ${loginErr} 次登入失敗：可能被限速（狀態碼 429）或伺服器忙，可改用 RAMP_MS=10000 分散登入再試。` : "\n登入全部成功。");
