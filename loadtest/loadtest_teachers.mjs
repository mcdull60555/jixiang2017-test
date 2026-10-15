// 基翔小學通 多位老師同時審核的負載測試。需要 Node.js 18 以上。
// 用法：node loadtest_teachers.mjs        （8 位老師、每位約 3000 筆項目、持續 2 分鐘）
// 建議同時另開一個視窗跑 node loadtest.mjs（學生），模擬上課時老師與學生一起用。
// 先決條件：已在 SQL Editor 建好 loadt_1～loadt_8（密碼 0000）與他們班的假資料。
const URL_ = process.env.SUPABASE_URL || "https://jflnvliefjfxhfwjzqdi.supabase.co";
const KEY = process.env.SUPABASE_KEY || "sb_publishable_ZVT08ujYz6NmsowKmqBNng_JxBJaVmb";
const T = +(process.env.TEACHERS || 8);
const SECONDS = +(process.env.SECONDS || 120);
const REVIEW_EVERY = +(process.env.REVIEW_EVERY_SECONDS || 8);   // 每幾秒審核一次
const BATCH = +(process.env.REVIEW_BATCH || 20);                 // 每次審核幾筆
const POLL_EVERY = +(process.env.POLL_EVERY_SECONDS || 25);
const RAMP_MS = +(process.env.RAMP_MS || 0);
const SMART = (process.env.SMART || "1") !== "0";   // 1＝新版網頁做法（審核後只補抓動到的項目）；SMART=0 模擬舊版整班重讀

const stats = {}; let bytesIn = 0;
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

async function fetchAllTasks(token) {            // 跟網頁一樣：每頁 1000 筆分頁讀完
  const out = [];
  for (let from = 0; ; from += 1000) {
    const t0 = performance.now();
    const rr = await fetch(URL_ + "/rest/v1/tasks?select=*&order=created_at,id", { headers: { apikey: KEY, Authorization: "Bearer " + token, Range: `${from}-${from + 999}`, "Range-Unit": "items" } });
    const txt = await rr.text(); bytesIn += txt.length;
    const rows = JSON.parse(txt);
    rec("讀全班項目(分頁)", performance.now() - t0, rr.ok, rr.status);
    out.push(...rows);
    if (rows.length < 1000) break;
  }
  return out;
}
async function refreshAfterAction(token) {       // 每次操作後網頁會把最新資料整份讀回來
  const [tasks] = await Promise.all([
    fetchAllTasks(token),
    call("讀聯絡簿", "/rest/v1/rpc/get_contact_book", { method: "POST", body: {}, token }),
    call("讀送審紀錄", "/rest/v1/submit_log?select=*&order=at.desc&limit=1000", { token }),
  ]);
  return tasks;
}

async function teacher(k) {
  if (RAMP_MS) await sleep(Math.random() * RAMP_MS);
  const lg = await call("老師登入(Edge Function)", "/functions/v1/login", { method: "POST", body: { email: `loadt_${k}@school.test`, pin: "0000" } });
  const token = lg.json && lg.json.access_token;
  if (!token) return;
  await Promise.all([
    call("讀學生名單", "/rest/v1/students?select=id,name,school,grade,class_name,avatar&order=id", { token }),
    call("跑馬燈", "/rest/v1/rpc/get_champions", { method: "POST", body: {}, token }),
    call("取資料指紋", "/rest/v1/rpc/get_data_version", { method: "POST", body: {}, token }),
  ]);
  let tasks = await refreshAfterAction(token);
  let pending = tasks.filter(t => t.pending_review).map(t => t.id);
  const end = Date.now() + SECONDS * 1000;
  let nextPoll = Date.now() + Math.random() * POLL_EVERY * 1000;
  while (Date.now() < end) {
    if (Date.now() >= nextPoll) { await call("輪詢指紋", "/rest/v1/rpc/get_data_version", { method: "POST", body: {}, token }); nextPoll = Date.now() + POLL_EVERY * 1000; }
    const ids = pending.splice(0, BATCH);
    if (ids.length) {
      await call("老師審核(RPC)", "/rest/v1/rpc/teacher_review", { method: "POST", body: { p_ids: ids, p_status: "已完成" }, token });
      if (SMART) {
        await Promise.all([
          call("審核後補抓動到的項目", `/rest/v1/tasks?select=*&id=in.(${ids.join(",")})`, { token }),
          call("審核後補抓新紀錄", `/rest/v1/submit_log?select=*&order=at.asc&at=gte.${encodeURIComponent(new Date(Date.now() - 60000).toISOString())}&limit=1000`, { token }),
        ]);
      } else await refreshAfterAction(token);
    }
    await sleep(REVIEW_EVERY * 1000 * (0.7 + Math.random() * 0.6));
  }
}

function pct(a, p) { const s = [...a].sort((x, y) => x - y); return s[Math.min(s.length - 1, Math.floor(s.length * p))]; }
console.log(`開始：${T} 位老師同時登入並審核，持續 ${SECONDS} 秒（每約 ${REVIEW_EVERY} 秒審核 ${BATCH} 筆，${SMART ? '審核後只補抓動到的項目' : '每次審核後重讀全班資料'}）`);
const t0 = Date.now();
await Promise.all(Array.from({ length: T }, (_, i) => teacher(i + 1)));
console.log(`\n結束，共 ${((Date.now() - t0) / 1000).toFixed(0)} 秒，下載資料量 ${(bytesIn / 1024 / 1024).toFixed(1)} MB\n`);
console.log("操作".padEnd(26), "次數".padStart(5), "失敗".padStart(5), "平均ms".padStart(8), "p95 ms".padStart(8), "最慢ms".padStart(8), " 狀態碼");
for (const [k, v] of Object.entries(stats)) {
  const avg = v.t.reduce((a, b) => a + b, 0) / v.t.length;
  console.log(k.padEnd(26), String(v.t.length).padStart(5), String(v.err).padStart(5), avg.toFixed(0).padStart(8), pct(v.t, 0.95).toFixed(0).padStart(8), Math.max(...v.t).toFixed(0).padStart(8), " ", JSON.stringify(v.codes));
}
