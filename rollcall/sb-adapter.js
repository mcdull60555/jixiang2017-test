/* ============================================================
 * 基翔雲點名（學務雲測試版）：Supabase 轉接層
 * 取代原本的 Google Apps Script 後端（Code.gs）。
 * 網頁畫面完全不變：畫面程式照舊呼叫 api(action, payload)，這裡依原本 Code.gs 的邏輯
 * 讀寫 Supabase，回傳相同格式的結果。
 * 資料表：students（共用名冊）、schools、rc_attendance、rc_submissions、rc_special_days、
 *         rc_leave_bookings、rc_extra_classes、rc_presence、app_settings
 * ============================================================ */
(function () {
  'use strict';

  const SUPABASE_URL = 'https://jflnvliefjfxhfwjzqdi.supabase.co';          // 測試專案
  const SUPABASE_KEY = 'sb_publishable_ZVT08ujYz6NmsowKmqBNng_JxBJaVmb';
  const EMAIL_DOMAIN = '@school.test';
  const RETENTION_DAYS = 40;
  const TZ = 'Asia/Taipei';
  const DEFAULT_CONTACT_TYPES = ['爸爸', '媽媽', '住家'];
  const VALID_STATUS = ['present', 'selfDrop', 'selfWalk', 'leave', 'fixedOff', ''];
  const PRESENCE_TTL = 600;
  const BOOKING_MAX_DAYS = 120;
  const BOOKING_BATCH_MAX = 100;
  const LEAVE_STREAK_ALERT = 3;
  const WEEKDAY_NAMES = ['', '一', '二', '三', '四', '五', '六', '日'];
  const GRADE_NAMES = ['', '一年級', '二年級', '三年級', '四年級', '五年級', '六年級'];

  // 與學務雲入口、學習通共用同一份登入狀態（同網域、同分頁）
  const sb = supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false, storage: window.sessionStorage, storageKey: 'jx-auth' }
  });
  const sbAnon = supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false, storageKey: 'jx-anon' }
  });

  /* ---------------- 日期 ---------------- */
  const fmtDate = new Intl.DateTimeFormat('en-CA', { timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit' });
  const ymd = ms => fmtDate.format(new Date(ms));
  function today_() { return ymd(Date.now()); }
  function dateStrDaysAgo_(n) { return ymd(Date.now() - n * 86400000); }
  function weekdayOf(d) { const w = new Date(d + 'T12:00:00+08:00').getUTCDay(); return w === 0 ? 7 : w; }
  function nextDate_(d) { return ymd(Date.parse(d + 'T12:00:00+08:00') + 86400000); }
  function prevDate_(d) { return ymd(Date.parse(d + 'T12:00:00+08:00') - 86400000); }
  function isDateStr_(d) { return /^\d{4}-\d{2}-\d{2}$/.test(String(d || '')) && !isNaN(Date.parse(String(d) + 'T00:00:00Z')); }
  const iso = v => (v ? new Date(v).toISOString() : '');
  const nowIso = () => new Date().toISOString();

  /* ---------------- 小工具 ---------------- */
  function isTrue_(v) { return v === true || String(v).toLowerCase() === 'true'; }
  function isActive_(v) { return v !== false && String(v).toLowerCase() !== 'false'; }
  function fail(code, extra) { return Object.assign({ ok: false, error: code }, extra || {}); }
  function dbErr(res, fallback) {
    if (res && res.error) {
      const m = String(res.error.message || '');
      if (/Failed to fetch|NetworkError|Load failed/i.test(m)) throw new Error('NETWORK_ERROR');
      if (res.error.code === '42501' || /permission denied|admin only|staff only/i.test(m)) throw new Error('FORBIDDEN');
      throw new Error(fallback ? fallback + '：' + m : m || 'DB_ERROR');
    }
    return res ? res.data : null;
  }

  /* ---------------- 年級班級（雲點名用 306 = 三年級 6 班） ---------------- */
  function gradeNum_(g) { const n = parseInt(String(g).trim(), 10); if (isNaN(n)) return 0; return n >= 100 ? Math.floor(n / 100) : n; }
  function classNum_(g) { const n = parseInt(String(g).trim(), 10); if (isNaN(n)) return 0; return n >= 100 ? n % 100 : 0; }
  function gradeCode_(gradeName, cls) {
    const gn = GRADE_NAMES.indexOf(gradeName);
    if (gn <= 0) return '';
    return String(gn * 100 + (cls || 0));
  }
  function splitGrade_(code) {
    const gn = gradeNum_(code), cn = classNum_(code);
    if (gn < 1 || gn > 6) return null;
    return { grade: GRADE_NAMES[gn], school_class: cn || null };
  }

  function sortStudents(list) {
    list.sort((a, b) => {
      const ga = gradeNum_(a.grade), gb = gradeNum_(b.grade);
      if (ga !== gb) return ga - gb;
      const ca = classNum_(a.grade), cb = classNum_(b.grade);
      if (ca !== cb) return ca - cb;
      return String(a.name).localeCompare(String(b.name), 'zh-Hant');
    });
    return list;
  }
  function normalizeContacts(raw) {
    const arr = (Array.isArray(raw) ? raw : []).map(c => {
      c = c || {};
      return { rel: String(c.rel !== undefined ? c.rel : (c.name || '')).trim(), phone: String(c.phone || '').trim(), primary: c.primary === true };
    }).filter(c => c.rel || c.phone).slice(0, 3);
    if (arr.length) {
      let first = arr.findIndex(c => c.primary);
      if (first === -1) first = 0;
      arr.forEach((c, i) => { c.primary = (i === first); });
    }
    return arr;
  }
  function normalizeDays_(arr) {
    const seen = {};
    (Array.isArray(arr) ? arr : []).forEach(d => { d = parseInt(d, 10); if (d >= 1 && d <= 5) seen[d] = true; });
    return Object.keys(seen).map(Number).sort();
  }
  function parseDays_(v) {
    if (Array.isArray(v)) return v.map(Number);
    return String(v === undefined || v === null ? '' : v).split(/[,|]/).filter(String).map(Number);
  }
  function studentOut_(x) {
    return { id: x.id, name: x.name, grade: String(x.grade), gradeNum: gradeNum_(x.grade),
      contacts: normalizeContacts(x.contacts), fixedOffDays: parseDays_(x.fixedOffDays), note: String(x.note || '') };
  }
  function validateStudent_(name, grade, contacts) {
    if (!String(name || '').trim()) return 'NAME_REQUIRED';
    if (!String(grade || '').trim()) return 'GRADE_REQUIRED';
    if (!splitGrade_(String(grade).trim())) return 'GRADE_REQUIRED';
    if (!normalizeContacts(contacts).some(c => c.rel && c.phone)) return 'CONTACT_REQUIRED';
    return null;
  }

  /* ---------------- 登入身分 ---------------- */
  let _me = null;
  async function requireSession(role) {
    const { data } = await sb.auth.getSession();
    const session = data && data.session;
    if (!session) throw new Error('AUTH_EXPIRED');
    if (!_me || _me.userId !== session.user.id) {
      const p = await sb.from('profiles').select('id,role,display_name,login_id,class_id').eq('id', session.user.id).maybeSingle();
      if (p.error) dbErr(p);
      if (!p.data || (p.data.role !== 'admin' && p.data.role !== 'teacher')) throw new Error('AUTH_EXPIRED');
      _me = { userId: p.data.id, role: p.data.role, name: p.data.display_name || p.data.login_id, username: p.data.login_id, classId: p.data.class_id };
    }
    if (role && _me.role !== role) throw new Error('FORBIDDEN');
    return _me;
  }

  /* ---------------- 讀取全部資料（同一次呼叫內共用） ---------------- */
  async function loadAll(need) {
    need = need || {};
    const cutoff = dateStrDaysAgo_(RETENTION_DAYS + 2);
    const q = {
      schools: sb.from('schools').select('id,name,active,sort_order'),
      students: sb.rpc('rc_list_students'),
      special: sb.from('rc_special_days').select('date,type,reason,created_by,created_at'),
      bookings: sb.from('rc_leave_bookings').select('*'),
      extras: sb.from('rc_extra_classes').select('*')
    };
    if (need.attendance !== false) q.attendance = sb.from('rc_attendance').select('*').gte('date', cutoff).limit(20000);
    if (need.submissions !== false) q.submissions = sb.from('rc_submissions').select('*').gte('date', cutoff).limit(5000);
    const keys = Object.keys(q);
    const res = await Promise.all(keys.map(k => q[k]));
    const raw = {};
    keys.forEach((k, i) => { raw[k] = dbErr(res[i]) || []; });

    const schoolIdByName = {}, schools = [];
    raw.schools.forEach(sc => { schoolIdByName[sc.name] = sc.id; schools.push({ id: sc.id, name: sc.name, active: sc.active }); });
    const sid = name => schoolIdByName[name] || ('?' + name);
    const students = raw.students.map(s => ({
      id: s.id, schoolId: sid(s.school), name: s.name, grade: gradeCode_(s.grade, s.school_class),
      contacts: s.contacts || [], fixedOffDays: s.fixed_off_days || [], note: s.note || '',
      active: !!(s.active && s.in_rollcall)
    }));
    const stSchool = {};
    students.forEach(s => { stSchool[s.id] = s.schoolId; });
    const bk = b => ({ id: b.id, schoolId: stSchool[b.student_id] || '', studentId: b.student_id, startDate: b.start_date, endDate: b.end_date,
      reason: b.reason || '', createdBy: b.created_by || '', createdRole: b.created_role || '', createdAt: iso(b.created_at), updatedBy: b.updated_by || '' });
    return {
      schools, students,
      special: raw.special.map(x => ({ date: x.date, type: x.type, reason: x.reason || '', createdBy: x.created_by, createdAt: iso(x.created_at) })),
      bookings: raw.bookings.map(bk),
      extras: raw.extras.map(bk),
      attendance: (raw.attendance || []).map(a => ({
        id: a.id, date: a.date, schoolId: sid(a.school), studentId: a.student_id, status: a.status || '',
        selfDrop: a.self_drop, selfWalk: a.self_walk, teacherId: a.teacher_id || '', teacherName: a.teacher_name || '',
        submittedAt: iso(a.submitted_at), wasFixedOff: a.was_fixed_off, auto: a.auto
      })),
      submissions: (raw.submissions || []).map(l => ({
        id: l.id, date: l.date, schoolId: sid(l.school), teacherId: l.teacher_id || '', teacherName: l.teacher_name || '',
        submittedAt: iso(l.submitted_at), count: l.count
      })),
      schoolName: id => { const sc = schools.find(x => x.id === id); return sc ? sc.name : ''; }
    };
  }

  /* ---------------- 點名日 ---------------- */
  function dayInfo_(date, list) {
    const sp = (list || []).filter(x => x.date === date)[0];
    const wd = weekdayOf(date);
    const base = { date, weekday: wd, reason: sp ? sp.reason : '' };
    if (sp && sp.type === 'workday') return Object.assign(base, { open: true, type: 'workday', label: '補班補課' });
    if (sp && sp.type === 'holiday') return Object.assign(base, { open: false, type: 'holiday', label: '國定假日放假' });
    if (wd >= 6) return Object.assign(base, { open: false, type: 'weekend', label: '例假日（星期' + WEEKDAY_NAMES[wd] + '）放假' });
    return Object.assign(base, { open: true, type: 'normal', label: '' });
  }
  function autoDayType_(date) { return weekdayOf(date) >= 6 ? 'workday' : 'holiday'; }

  /* ---------------- 每位學生每天的狀態（與 Code.gs 相同的判斷） ---------------- */
  function effectiveStatus_(a) {
    const s = String(a.status || '');
    if (!s || s === 'present') {
      if (isTrue_(a.selfDrop)) return 'selfDrop';
      if (isTrue_(a.selfWalk)) return 'selfWalk';
    }
    return s;
  }
  function statusCtx_(D) {
    const today = today_();
    const rec = {};
    D.attendance.forEach(a => { rec[a.date + '|' + a.studentId] = a; });
    const fixed = {}, stMap = {};
    D.students.forEach(st => { fixed[st.id] = parseDays_(st.fixedOffDays); stMap[st.id] = st; });
    const sp = D.special, openCache = {}, wdCache = {};
    const wdOf = d => { if (!(d in wdCache)) wdCache[d] = weekdayOf(d); return wdCache[d]; };
    const isOpen = d => { if (!(d in openCache)) openCache[d] = dayInfo_(d, sp).open; return openCache[d]; };
    const isFixedBase = (sid, d) => (fixed[sid] || []).indexOf(wdOf(d)) !== -1;
    const ex = {};
    D.extras.forEach(b => { (ex[b.studentId] = ex[b.studentId] || []).push(b); });
    const extraOn = (sid, d) => {
      if (!isFixedBase(sid, d) || !isOpen(d)) return null;
      const list = ex[sid] || [];
      for (let i = 0; i < list.length; i++) if (list[i].startDate <= d && d <= list[i].endDate) return list[i];
      return null;
    };
    const isFixed = (sid, d) => isFixedBase(sid, d) && !extraOn(sid, d);
    const bk = {};
    D.bookings.forEach(b => { (bk[b.studentId] = bk[b.studentId] || []).push(b); });
    const bookingOn = (sid, d) => {
      const list = bk[sid] || [];
      for (let i = 0; i < list.length; i++) {
        if (list[i].startDate <= d && d <= list[i].endDate) return (isOpen(d) && !isFixed(sid, d)) ? list[i] : null;
      }
      return null;
    };
    const teacherSet = a => {
      if (!a) return '';
      const v = effectiveStatus_(a);
      return v && v !== 'fixedOff' && !isTrue_(a.auto) ? v : '';
    };
    const status = (sid, d) => {
      const a = rec[d + '|' + sid];
      const mine = teacherSet(a);
      if (mine) return mine;
      if (bookingOn(sid, d)) return 'leave';
      if (d === today) return isFixed(sid, d) ? 'fixedOff' : '';
      const saved = a ? effectiveStatus_(a) : '';
      if (saved === 'fixedOff') return extraOn(sid, d) ? '' : 'fixedOff';
      if (a && isTrue_(a.auto) && saved === 'leave') return '';
      return saved;
    };
    const defaultOf = (sid, d) => bookingOn(sid, d) ? 'leave' : (isFixed(sid, d) ? 'fixedOff' : '');
    return { today, rec, fixed, stMap, isOpen, isFixed, isFixedBase, wdOf, extras: ex, extraOn, bookings: bk, bookingOn, teacherSet, status, defaultOf };
  }
  function leaveStreaks_(date, studentIds, ctx) {
    const out = {};
    if (!studentIds.length) return out;
    const oldest = dateStrDaysAgo_(RETENTION_DAYS + 1);
    studentIds.forEach(sid => {
      if (ctx.status(sid, date) !== 'leave') return;
      let n = 0, d = date;
      while (d >= oldest) {
        const st = ctx.status(sid, d);
        if (st === 'leave') n++;
        else if (st === 'fixedOff') { /* 不中斷也不計入 */ }
        else if (!st && (!ctx.isOpen(d) || ctx.isFixed(sid, d))) { /* 跳過 */ }
        else break;
        d = prevDate_(d);
      }
      out[sid] = n;
    });
    return out;
  }
  function submittersIndex_(D, cutoff, attendanceRows) {
    const idx = {};
    const add = (key, tid, name, at) => {
      if (!name) return;
      const m = idx[key] = idx[key] || {};
      const k = tid || name;
      if (!m[k] || at > m[k].at) m[k] = { name, at };
    };
    const logged = {};
    D.submissions.forEach(l => {
      if (cutoff && l.date < cutoff) return;
      const key = l.date + '|' + l.schoolId;
      logged[key] = true;
      add(key, l.teacherId, l.teacherName, l.submittedAt);
    });
    (attendanceRows || []).forEach(a => {
      const key = a.date + '|' + a.schoolId;
      if (logged[key] || (cutoff && a.date < cutoff)) return;
      add(key, a.teacherId, a.teacherName, a.submittedAt);
    });
    const out = {};
    Object.keys(idx).forEach(key => {
      out[key] = Object.keys(idx[key]).map(k => idx[key][k]).sort((a, b) => a.at.localeCompare(b.at));
    });
    return out;
  }
  const activeStudentsOf_ = (D, schoolId) => D.students.filter(x => x.schoolId === schoolId && isActive_(x.active));

  /* ---------------- 預約請假 / 臨時進班 ---------------- */
  const bkKind_ = k => (k === 'attend' ? 'attend' : 'leave');
  const bkTable_ = kind => (kind === 'attend' ? 'rc_extra_classes' : 'rc_leave_bookings');
  const bookings_ = (D, kind) => (bkKind_(kind) === 'attend' ? D.extras : D.bookings);
  const bookingBrief_ = b => ({ id: b.id, startDate: b.startDate, endDate: b.endDate, reason: b.reason });
  function bookingDays_(ctx, sid, start, end, kind) {
    const out = [];
    for (let d = start; d <= end && out.length <= 400; d = nextDate_(d)) {
      if (!ctx.isOpen(d)) continue;
      if (kind === 'attend' ? ctx.isFixedBase(sid, d) : !ctx.isFixed(sid, d)) out.push(d);
    }
    return out;
  }
  function bookingOut_(D, ctx, b, kind) {
    const st = ctx.stMap[b.studentId];
    const so = st ? studentOut_(st) : { name: '(已刪除的學生)', grade: '' };
    const today = ctx.today;
    const state = b.endDate < today ? 'past' : (b.startDate <= today ? 'ongoing' : 'upcoming');
    return Object.assign(bookingBrief_(b), {
      schoolId: b.schoolId, schoolName: D.schoolName(b.schoolId) || '(已移除的學校)', studentId: b.studentId,
      name: so.name, grade: String(so.grade), days: bookingDays_(ctx, b.studentId, b.startDate, b.endDate, kind).length,
      createdBy: b.createdBy, createdRole: b.createdRole, updatedBy: b.updatedBy, state
    });
  }
  function checkBooking_(s, ctx, kind, input, all) {
    const isAdmin = s.role === 'admin';
    const today = ctx.today;
    const start = String(input.startDate || ''), end = String(input.endDate || input.startDate || '');
    if (!isDateStr_(start) || !isDateStr_(end)) return { error: 'DATE_REQUIRED' };
    if (end < start) return { error: 'BOOKING_RANGE' };
    const st = ctx.stMap[String(input.studentId || '')];
    if (!st || !isActive_(st.active)) return { error: 'STUDENT_NOT_FOUND' };
    if (!isAdmin && input.schoolId && st.schoolId !== input.schoolId) return { error: 'STUDENT_NOT_FOUND' };
    if (kind === 'attend' && !parseDays_(st.fixedOffDays).length) return { error: 'EXTRA_NOT_FIXED' };
    const old = input.id ? all.filter(b => b.id === String(input.id))[0] : null;
    if (input.id && !old) return { error: 'BOOKING_NOT_FOUND' };
    if (!isAdmin) {
      if (old && old.startDate < today) return { error: 'BOOKING_STARTED' };
      if (start < today) return { error: 'BOOKING_PAST' };
    } else if (start < dateStrDaysAgo_(RETENTION_DAYS)) return { error: 'BOOKING_TOO_OLD' };
    if ((Date.parse(end) - Date.parse(start)) / 86400000 + 1 > BOOKING_MAX_DAYS) return { error: 'BOOKING_TOO_LONG' };
    const clash = all.filter(b => b.studentId === st.id && (!old || b.id !== old.id) && b.startDate <= end && start <= b.endDate)[0];
    if (clash) return { error: kind === 'attend' ? 'EXTRA_OVERLAP' : 'BOOKING_OVERLAP', clash: bookingBrief_(clash) };
    const days = bookingDays_(ctx, st.id, start, end, kind);
    if (!days.length) return { error: kind === 'attend' ? 'EXTRA_NO_DAYS' : 'BOOKING_NO_DAYS' };
    return { st, start, end, reason: String(input.reason || '').trim().slice(0, 30), days: days.length, old };
  }
  function bookingRow_(s, c, now) {
    const old = c.old;
    const row = {
      student_id: c.st.id, start_date: c.start, end_date: c.end, reason: c.reason,
      created_by: old ? old.createdBy : s.name, created_role: old ? old.createdRole : s.role,
      updated_by: old ? s.name : '', updated_at: old ? now : null
    };
    if (old) row.id = old.id;
    return row;
  }

  /* ---------------- 老師目前在哪間學校 ---------------- */
  async function presenceList_(D, excludeUserId) {
    const since = new Date(Date.now() - PRESENCE_TTL * 1000).toISOString();
    const r = await sb.from('rc_presence').select('teacher_id,name,school_id,mode,at').gte('at', since).not('school_id', 'is', null);
    const rows = dbErr(r) || [];
    const now = Date.now();
    const out = rows.filter(p => p.teacher_id !== excludeUserId).map(p => ({
      teacherId: p.teacher_id, name: p.name, schoolId: p.school_id, mode: p.mode, at: Date.parse(p.at),
      schoolName: D ? D.schoolName(p.school_id) : '', ago: Math.max(0, Math.round((now - Date.parse(p.at)) / 1000))
    }));
    out.sort((a, b) => String(a.schoolName).localeCompare(String(b.schoolName), 'zh-Hant') || b.at - a.at);
    return out;
  }
  async function putPresence_(s, schoolId, mode) {
    await sb.from('rc_presence').upsert({ teacher_id: s.userId, name: s.name, school_id: schoolId ? String(schoolId) : null,
      mode: mode === 'edit' ? 'edit' : 'view', at: nowIso() }, { onConflict: 'teacher_id' });
  }

  /* ================================================================
   * 各動作（與 Code.gs 同名、同回傳格式）
   * ================================================================ */
  const A = {};

  A.ping = async () => ({ ok: true, time: nowIso() });

  // ---------- 登入 / 帳號 ----------
  A.login = async body => {
    const username = String(body.username || '').trim().toLowerCase();
    const password = String(body.password || '');
    if (!/^[a-z0-9_-]{1,100}$/.test(username) || !password) return fail('INVALID_LOGIN');
    let gate = null;
    for (let i = 0; i < 3; i++) {
      gate = await sbAnon.functions.invoke('login', { body: { email: username + EMAIL_DOMAIN, pin: password } });
      if (!gate.error && gate.data) break;
      const st = gate.error && gate.error.context && gate.error.context.status;
      if ((st && st < 500) || i === 2) break;
      await new Promise(r => setTimeout(r, 700 * (i + 1)));
    }
    if (gate.error || !gate.data) throw new Error('NETWORK_ERROR');
    const g = gate.data;
    if (g.status === 'locked') return fail('LOCKED');
    if (g.status !== 'ok') return fail('INVALID_LOGIN');
    const set = await sb.auth.setSession({ access_token: g.access_token, refresh_token: g.refresh_token });
    if (set.error || !set.data.session) return fail('INVALID_LOGIN');
    _me = null;
    let s;
    try { s = await requireSession(); } catch (e) { await sb.auth.signOut({ scope: 'local' }); return fail('INVALID_LOGIN'); }
    rememberForPortal_(s);
    return { ok: true, token: 'sb', role: s.role, name: s.name, today: today_() };
  };

  A.logout = async () => {
    try { const s = await requireSession(); if (s.role === 'teacher') await putPresence_(s, '', 'view'); } catch (e) { /* 忽略 */ }
    try { await sb.auth.signOut({ scope: 'local' }); } catch (e) { /* 忽略 */ }
    _me = null;
    ['authToken', 'isTeacherLoggedIn', 'loggedInStudentId', 'lastActivityTime', 'jx-me'].forEach(k => { try { sessionStorage.removeItem(k); } catch (e) {} });
    return { ok: true };
  };

  A.listLoginAccounts = async () => {
    const r = await sbAnon.rpc('list_teachers');
    const teachers = (dbErr(r) || []).map(t => ({ username: t.login_id, name: t.display_name || t.login_id, role: 'teacher' }));
    return { ok: true, accounts: [{ username: 'admin', name: '管理員', role: 'admin' }].concat(teachers) };
  };

  A.bootstrap = async () => {
    const s = await requireSession();
    rememberForPortal_(s);
    return { ok: true, role: s.role, name: s.name, today: today_() };
  };

  A.changePwd = async body => {
    const s = await requireSession();
    const newPassword = String(body.newPassword || '');
    if (!newPassword) return fail('PASSWORD_REQUIRED');
    if (newPassword.length < 4) return fail('PASSWORD_TOO_SHORT');
    const chk = await sbAnon.functions.invoke('login', { body: { email: s.username + EMAIL_DOMAIN, pin: String(body.oldPassword || '') } });
    if (chk.error || !chk.data) throw new Error('NETWORK_ERROR');
    if (chk.data.status === 'locked') return fail('LOCKED');
    if (chk.data.status !== 'ok') return fail('WRONG_OLD_PASSWORD');
    dbErr(await sb.rpc('change_my_pin', { p_pin: newPassword }));
    return { ok: true };
  };

  // ---------- 老師帳號（與學習通共用同一組帳號） ----------
  async function teacherRows_() {
    const r = await sb.from('profiles').select('id,login_id,display_name,class_id,sort_order').eq('role', 'teacher');
    return dbErr(r) || [];
  }
  function nextTeacherUsername_(list) {
    const used = {};
    list.forEach(t => { const m = String(t.login_id).match(/^t_teacher(\d+)$/i); if (m) used[parseInt(m[1], 10)] = true; });
    let n = 1;
    while (used[n]) n++;
    return 't_teacher' + (n < 10 ? '0' + n : String(n));
  }
  A.listTeachers = async () => {
    await requireSession('admin');
    const list = await teacherRows_();
    // 順序和學務雲帳號管理、登入選單相同（sort_order）
    list.sort((a, b) => (a.sort_order ?? 1e9) - (b.sort_order ?? 1e9) || String(a.login_id).localeCompare(String(b.login_id)));
    return { ok: true, nextUsername: nextTeacherUsername_(list),
      teachers: list.map(t => ({ id: t.id, username: t.login_id, name: t.display_name || t.login_id, active: true })) };
  };
  A.addTeacher = async body => {
    await requireSession('admin');
    const name = String(body.name || '').trim();
    if (!name) return fail('NAME_REQUIRED');
    let username = String(body.username || '').trim().toLowerCase();
    if (!username) return fail('USERNAME_REQUIRED');
    if (!/^t_/.test(username)) username = 't_' + username;
    if (!/^t_[a-z0-9_-]{1,60}$/.test(username)) return fail('USERNAME_INVALID');
    const list = await teacherRows_();
    if (username === 'admin' || list.some(t => String(t.login_id).toLowerCase() === username)) return fail('USERNAME_TAKEN');
    const r = dbErr(await sb.rpc('admin_create_teacher', { p_login: username, p_name: name, p_pin: String(body.password || '0000'), p_class: null }));
    return { ok: true, id: r && r.id, username };
  };
  A.editTeacher = async body => {
    await requireSession('admin');
    const list = await teacherRows_();
    const t = list.filter(x => x.id === body.teacherId)[0];
    if (!t) return fail('TEACHER_NOT_FOUND');
    const name = String(body.name || '').trim();
    if (!name) return fail('NAME_REQUIRED');
    const username = String(body.username || '').trim().toLowerCase();
    if (!username) return fail('USERNAME_REQUIRED');
    if (username !== String(t.login_id).toLowerCase()) return fail('USERNAME_LOCKED');
    dbErr(await sb.rpc('admin_update_teacher', { p_id: t.id, p_name: name, p_class: t.class_id }));
    const newPwd = String(body.password || '').trim();
    if (newPwd) dbErr(await sb.rpc('admin_set_teacher_pin', { p_id: t.id, p_pin: newPwd }));
    return { ok: true, passwordReset: !!newPwd, loggedOut: 0 };
  };
  A.deleteTeachersBatch = async body => {
    await requireSession('admin');
    const list = await teacherRows_();
    const ids = (body.teacherIds || []).filter(id => list.some(t => t.id === id));
    for (const id of ids) dbErr(await sb.rpc('admin_delete_teacher', { p_id: id }));
    return { ok: true, deleted: ids.length };
  };
  A.deleteTeacher = async body => {
    const r = await A.deleteTeachersBatch({ teacherIds: [body.teacherId] });
    return r.deleted ? { ok: true } : fail('TEACHER_NOT_FOUND');
  };

  // ---------- 老師目前在哪間學校 ----------
  A.setPresence = async body => {
    const s = await requireSession();
    if (s.role === 'teacher') await putPresence_(s, body.schoolId || '', body.mode);
    const sc = dbErr(await sb.from('schools').select('id,name')) || [];
    const map = {}; sc.forEach(x => { map[x.id] = x.name; });
    return { ok: true, presence: await presenceList_({ schoolName: id => map[id] || '' }, s.userId) };
  };

  // ---------- 聯絡人類型 ----------
  async function customContactTypes_() {
    const r = await sb.from('app_settings').select('value').eq('key', 'contactTypes').maybeSingle();
    const v = dbErr(r);
    return v && Array.isArray(v.value) ? v.value.map(String) : [];
  }
  async function contactTypesResult_() {
    const custom = (await customContactTypes_()).filter(c => DEFAULT_CONTACT_TYPES.indexOf(c) === -1);
    return { ok: true, types: DEFAULT_CONTACT_TYPES.concat(custom), custom };
  }
  A.getContactTypes = async () => { await requireSession(); return contactTypesResult_(); };
  A.addContactType = async body => {
    await requireSession('admin');
    const name = String(body.name || '').trim();
    if (!name) return fail('NAME_REQUIRED');
    if (name.length > 12) return fail('NAME_TOO_LONG');
    const custom = await customContactTypes_();
    if (DEFAULT_CONTACT_TYPES.indexOf(name) === -1 && custom.indexOf(name) === -1) {
      custom.push(name);
      dbErr(await sb.from('app_settings').upsert({ key: 'contactTypes', value: custom, updated_at: nowIso() }, { onConflict: 'key' }));
    }
    const r = await contactTypesResult_();
    r.added = name;
    return r;
  };

  // ---------- 學校 ----------
  A.listSchools = async () => {
    await requireSession();
    const D = await loadAll({ attendance: false, submissions: false });
    const counts = {};
    D.students.forEach(st => { if (isActive_(st.active)) counts[st.schoolId] = (counts[st.schoolId] || 0) + 1; });
    const out = D.schools.filter(sc => sc.active).map(sc => ({ id: sc.id, name: sc.name, studentCount: counts[sc.id] || 0 }));
    out.sort((a, b) => String(a.name).localeCompare(String(b.name), 'zh-Hant'));
    return { ok: true, schools: out };
  };
  A.addSchoolsBatch = async body => {
    await requireSession('admin');
    const names = (body.names || []).map(n => String(n || '').trim()).filter(Boolean);
    if (!names.length) return fail('NAME_REQUIRED');
    const r = dbErr(await sb.rpc('rc_add_schools', { p_names: names }));
    return { ok: true, created: r.created || [], skipped: r.skipped || [] };
  };
  A.addSchool = async body => {
    if (!String(body.name || '').trim()) return fail('NAME_REQUIRED');
    const r = await A.addSchoolsBatch({ names: [body.name] });
    if (!r.ok) return r;
    if (!r.created.length) return fail('SCHOOL_EXISTS');
    return { ok: true };
  };
  A.editSchool = async body => {
    await requireSession('admin');
    const code = dbErr(await sb.rpc('rc_rename_school', { p_id: String(body.schoolId || ''), p_name: String(body.name || '') }));
    return code === 'OK' ? { ok: true } : fail(code);
  };
  A.deleteSchool = async body => {
    await requireSession('admin');
    const n = dbErr(await sb.rpc('rc_close_school', { p_id: String(body.schoolId || '') }));
    if (n < 0) return fail('SCHOOL_NOT_FOUND');
    return { ok: true, deletedStudents: n };
  };

  // ---------- 學生 ----------
  A.listStudents = async body => {
    await requireSession();
    const D = await loadAll({ attendance: false, submissions: false });
    const students = activeStudentsOf_(D, body.schoolId).map(studentOut_);
    sortStudents(students);
    return { ok: true, students };
  };
  function studentPayload_(D, schoolId, st, id) {
    const g = splitGrade_(String(st.grade || '').trim());
    return {
      id: id || null, school: D.schoolName(schoolId), grade: g.grade, school_class: g.school_class,
      name: String(st.name || '').trim(), contacts: normalizeContacts(st.contacts),
      fixed_off_days: normalizeDays_(st.fixedOffDays), note: String(st.note || '').trim()
    };
  }
  A.addStudent = async body => {
    await requireSession('admin');
    const err = validateStudent_(body.name, body.grade, body.contacts);
    if (err) return fail(err);
    const D = await loadAll({ attendance: false, submissions: false });
    if (!D.schoolName(body.schoolId)) return fail('SCHOOL_NOT_FOUND');
    const r = dbErr(await sb.rpc('rc_save_students', { p_rows: [studentPayload_(D, body.schoolId, body)] }));
    return { ok: true, id: r.ids[0] };
  };
  A.addStudentsBatch = async body => {
    await requireSession('admin');
    const list = (body.students || []).filter(st => st && String(st.name || '').trim());
    const bad = [];
    list.forEach((st, i) => {
      const err = validateStudent_(st.name, st.grade, st.contacts);
      if (err) bad.push({ index: i, name: String(st.name).trim(), error: err });
    });
    if (bad.length) return fail('INVALID_ROWS', { rows: bad });
    const D = await loadAll({ attendance: false, submissions: false });
    if (!D.schoolName(body.schoolId)) return fail('SCHOOL_NOT_FOUND');
    const existing = {};
    D.students.forEach(x => { if (x.schoolId === body.schoolId && isActive_(x.active)) existing[x.name + '|' + String(x.grade)] = true; });
    const rows = [], skipped = [];
    list.forEach(st => {
      const name = String(st.name || '').trim();
      const key = name + '|' + String(st.grade || '').trim();
      if (existing[key]) { skipped.push(name); return; }
      existing[key] = true;
      rows.push(studentPayload_(D, body.schoolId, st));
    });
    if (rows.length) dbErr(await sb.rpc('rc_save_students', { p_rows: rows }));
    return { ok: true, created: rows.length, skipped };
  };
  A.editStudent = async body => {
    await requireSession('admin');
    const D = await loadAll({ attendance: false, submissions: false });
    const u = D.students.filter(x => x.id === body.studentId)[0];
    if (!u) return fail('STUDENT_NOT_FOUND');
    const name = body.name !== undefined ? String(body.name).trim() : u.name;
    const grade = body.grade !== undefined ? String(body.grade).trim() : String(u.grade);
    const contacts = body.contacts !== undefined ? body.contacts : u.contacts;
    const err = validateStudent_(name, grade, contacts);
    if (err) return fail(err);
    const merged = {
      name, grade, contacts,
      fixedOffDays: body.fixedOffDays !== undefined ? body.fixedOffDays : u.fixedOffDays,
      note: body.note !== undefined ? body.note : u.note
    };
    dbErr(await sb.rpc('rc_save_students', { p_rows: [studentPayload_(D, u.schoolId, merged, u.id)] }));
    return { ok: true };
  };
  A.deleteStudentsBatch = async body => {
    await requireSession('admin');
    const n = dbErr(await sb.rpc('rc_remove_students', { p_ids: body.studentIds || [] }));
    return { ok: true, deleted: n || 0 };
  };
  A.deleteStudent = async body => {
    const r = await A.deleteStudentsBatch({ studentIds: [body.studentId] });
    return r.deleted ? { ok: true } : fail('STUDENT_NOT_FOUND');
  };

  // ---------- 點名日 ----------
  async function specialDays_() {
    const r = dbErr(await sb.from('rc_special_days').select('date,type,reason,created_by,created_at')) || [];
    return r.map(x => ({ date: x.date, type: x.type, reason: x.reason || '', createdBy: x.created_by, createdAt: iso(x.created_at) }));
  }
  A.getDayInfo = async body => {
    await requireSession();
    const date = body.date && /^\d{4}-\d{2}-\d{2}$/.test(body.date) ? body.date : today_();
    return { ok: true, today: today_(), day: dayInfo_(date, await specialDays_()) };
  };
  A.listSpecialDays = async () => {
    await requireSession('admin');
    const list = (await specialDays_()).sort((a, b) => b.date.localeCompare(a.date));
    list.forEach(x => { x.weekday = weekdayOf(x.date); });
    return { ok: true, today: today_(), todayInfo: dayInfo_(today_(), list), days: list };
  };
  A.setSpecialDay = async body => {
    const s = await requireSession('admin');
    const date = String(body.date || '');
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) return fail('DATE_REQUIRED');
    const type = body.type;
    if (type !== 'workday' && type !== 'holiday') return fail('UNKNOWN_ACTION');
    const wd = weekdayOf(date);
    if (type === 'workday' && wd < 6) return fail('NOT_WEEKEND');
    if (type === 'holiday' && wd >= 6) return fail('NOT_WEEKDAY');
    dbErr(await sb.from('rc_special_days').upsert({ date, type, reason: String(body.reason || '').trim().slice(0, 30), created_by: s.name, created_at: nowIso() }, { onConflict: 'date' }));
    return { ok: true, day: dayInfo_(date, await specialDays_()) };
  };
  A.deleteSpecialDay = async body => {
    await requireSession('admin');
    const r = dbErr(await sb.from('rc_special_days').delete().eq('date', String(body.date)).select('date'));
    if (!r || !r.length) return fail('DAY_NOT_FOUND');
    return { ok: true, day: dayInfo_(String(body.date), await specialDays_()) };
  };
  A.setSpecialDaysBatch = async body => {
    const s = await requireSession('admin');
    const input = Array.isArray(body.days) ? body.days : [];
    const map = {}, order = [], bad = [];
    input.forEach((d, i) => {
      const date = String((d && d.date) || '');
      if (!isDateStr_(date)) { bad.push({ row: i + 1, error: 'DATE_REQUIRED' }); return; }
      const wd = weekdayOf(date);
      const type = d.type || autoDayType_(date);
      if (type !== 'workday' && type !== 'holiday') { bad.push({ row: i + 1, date, error: 'UNKNOWN_ACTION' }); return; }
      if (type === 'workday' && wd < 6) { bad.push({ row: i + 1, date, error: 'NOT_WEEKEND' }); return; }
      if (type === 'holiday' && wd >= 6) { bad.push({ row: i + 1, date, error: 'NOT_WEEKDAY' }); return; }
      if (!map[date]) order.push(date);
      map[date] = { type, reason: String(d.reason || '').trim().slice(0, 30) };
    });
    if (bad.length) return fail('INVALID_DAYS', { bad });
    if (!order.length) return fail('DATE_REQUIRED');
    const existing = (await specialDays_()).filter(x => map[x.date]);
    const now = nowIso();
    dbErr(await sb.from('rc_special_days').upsert(order.map(date => ({ date, type: map[date].type, reason: map[date].reason, created_by: s.name, created_at: now })), { onConflict: 'date' }));
    return { ok: true, created: order.length - existing.length, updated: existing.length };
  };
  A.editSpecialDay = async body => {
    const s = await requireSession('admin');
    const date = String(body.date || '');
    const newDate = String(body.newDate || date);
    if (!isDateStr_(newDate)) return fail('DATE_REQUIRED');
    const all = await specialDays_();
    if (!all.some(x => x.date === date)) return fail('DAY_NOT_FOUND');
    if (newDate !== date && all.some(x => x.date === newDate)) return fail('DAY_EXISTS');
    const row = { date: newDate, type: autoDayType_(newDate), reason: String(body.reason || '').trim().slice(0, 30), created_by: s.name, created_at: nowIso() };
    dbErr(await sb.from('rc_special_days').upsert(row, { onConflict: 'date' }));
    if (newDate !== date) dbErr(await sb.from('rc_special_days').delete().eq('date', date));
    return { ok: true, day: dayInfo_(newDate, await specialDays_()) };
  };

  // ---------- 預約請假 / 臨時進班 ----------
  A.listBookings = async body => {
    await requireSession();
    const kind = bkKind_(body.kind);
    const D = await loadAll();
    const ctx = statusCtx_(D);
    const items = bookings_(D, kind).filter(b => {
      const st = ctx.stMap[b.studentId];
      if (!st || !isActive_(st.active)) return false;
      if (body.schoolId && b.schoolId !== body.schoolId) return false;
      return body.includePast || b.endDate >= ctx.today;
    }).map(b => bookingOut_(D, ctx, b, kind));
    const rank = { ongoing: 0, upcoming: 1, past: 2 };
    items.sort((a, b) => (rank[a.state] - rank[b.state]) ||
      (a.state === 'past' ? b.endDate.localeCompare(a.endDate) : a.startDate.localeCompare(b.startDate)) ||
      String(a.schoolName).localeCompare(String(b.schoolName), 'zh-Hant') || (gradeNum_(a.grade) - gradeNum_(b.grade)) ||
      (classNum_(a.grade) - classNum_(b.grade)) || String(a.name).localeCompare(String(b.name), 'zh-Hant'));
    return { ok: true, kind, today: ctx.today, oldest: dateStrDaysAgo_(RETENTION_DAYS), items };
  };
  A.saveBooking = async body => {
    const s = await requireSession();
    const kind = bkKind_(body.kind);
    const D = await loadAll();
    const ctx = statusCtx_(D);
    const c = checkBooking_(s, ctx, kind, body, bookings_(D, kind));
    if (c.error) return fail(c.error, { clash: c.clash });
    const row = bookingRow_(s, c, nowIso());
    const r = c.old
      ? dbErr(await sb.from(bkTable_(kind)).update(row).eq('id', row.id).select('id'))
      : dbErr(await sb.from(bkTable_(kind)).insert(row).select('id'));
    return { ok: true, id: r && r[0] ? r[0].id : row.id, days: c.days, startDate: c.start, endDate: c.end };
  };
  A.saveBookingsBatch = async body => {
    const s = await requireSession();
    const kind = bkKind_(body.kind);
    const items = Array.isArray(body.items) ? body.items : [];
    if (!items.length) return fail('BATCH_EMPTY');
    if (items.length > BOOKING_BATCH_MAX) return fail('BATCH_TOO_MANY');
    const D = await loadAll();
    const ctx = statusCtx_(D);
    const all = bookings_(D, kind).slice();
    const now = nowIso();
    const bad = [], rows = [];
    let totalDays = 0;
    items.forEach((it, i) => {
      const input = { studentId: it && it.studentId, startDate: it && it.startDate, endDate: it && it.endDate, reason: it && it.reason, schoolId: body.schoolId };
      const c = checkBooking_(s, ctx, kind, input, all);
      if (c.error) {
        const inBatch = !!c.clash && String(c.clash.id).indexOf('new_') === 0;
        bad.push({ row: i + 1, error: c.error, clash: c.clash || null, inBatch });
        return;
      }
      const row = bookingRow_(s, c, now);
      rows.push(row);
      all.push({ id: 'new_' + i, studentId: c.st.id, startDate: c.start, endDate: c.end, reason: c.reason });
      totalDays += c.days;
    });
    if (bad.length) return fail('INVALID_BOOKINGS', { bad });
    dbErr(await sb.from(bkTable_(kind)).insert(rows));
    return { ok: true, created: rows.length, days: totalDays };
  };
  A.deleteBooking = async body => {
    const s = await requireSession();
    const kind = bkKind_(body.kind);
    const r = dbErr(await sb.from(bkTable_(kind)).select('id,start_date').eq('id', String(body.id || '')).maybeSingle());
    if (!r) return fail('BOOKING_NOT_FOUND');
    if (s.role !== 'admin' && r.start_date < today_()) return fail('BOOKING_STARTED');
    dbErr(await sb.from(bkTable_(kind)).delete().eq('id', r.id));
    return { ok: true };
  };

  // ---------- 點名 ----------
  A.getRollCall = async body => {
    await requireSession();
    const date = today_();
    const schoolId = body.schoolId;
    const D = await loadAll();
    const attendance = D.attendance.filter(a => a.schoolId === schoolId && a.date === date);
    const attMap = {};
    attendance.forEach(a => { attMap[a.studentId] = a; });
    const ctx = statusCtx_(D);
    const out = activeStudentsOf_(D, schoolId).map(st => {
      const so = studentOut_(st);
      const isFixedOff = ctx.isFixed(st.id, date);
      const exb = ctx.extraOn(st.id, date);
      const existing = attMap[st.id];
      const primary = so.contacts.filter(c => c.primary)[0] || null;
      const status = ctx.status(st.id, date);
      const byTeacher = !!ctx.teacherSet(existing);
      const bk = ctx.bookingOn(st.id, date);
      return {
        id: so.id, name: so.name, grade: so.grade, isFixedOff, primaryContact: primary,
        contacts: so.contacts, note: so.note, status, defaultStatus: ctx.defaultOf(st.id, date), fixedOffDays: so.fixedOffDays,
        booking: bk ? bookingBrief_(bk) : null, extra: exb ? bookingBrief_(exb) : null,
        markedBy: byTeacher ? existing.teacherName : '', markedAt: byTeacher ? existing.submittedAt : ''
      };
    });
    sortStudents(out);
    const submitters = submittersIndex_(D, date, attendance)[date + '|' + schoolId] || [];
    const last = submitters[submitters.length - 1] || null;
    return { ok: true, date, day: dayInfo_(date, D.special), students: out, submitted: submitters.length > 0, submitters,
      submittedAt: last ? last.at : null, submittedBy: last ? last.name : null };
  };

  A.submitAttendance = async body => {
    const s = await requireSession('teacher');
    const date = today_();
    const schoolId = body.schoolId;
    const now = nowIso();
    const D = await loadAll();
    const day = dayInfo_(date, D.special);
    if (!day.open) return fail('DAY_CLOSED', { day });
    const students = activeStudentsOf_(D, schoolId);
    const latestOf = {};
    (body.records || []).forEach(r => { if (r) latestOf[r.studentId] = r; });
    const ctx = statusCtx_(D);
    const valid = {}, fixedToday = {};
    students.forEach(st => { valid[st.id] = true; if (ctx.isFixed(st.id, date)) fixedToday[st.id] = true; });
    const todays = D.attendance.filter(a => a.date === date && a.schoolId === schoolId);
    const attMap = {};
    todays.forEach(a => { attMap[a.studentId] = a; });
    const subs = submittersIndex_(D, date, todays)[date + '|' + schoolId] || [];
    const last = subs[subs.length - 1];
    const latest = last ? last.at : '';
    if (!body.autosave && !body.force && latest !== String(body.baseSubmittedAt || '')) {
      return fail('CONFLICT', { submittedAt: latest, submittedBy: last ? last.name : '' });
    }
    const schoolName = D.schoolName(schoolId);
    const rows = [];
    Object.keys(latestOf).map(k => latestOf[k]).forEach(r => {
      if (!valid[r.studentId]) return;
      const status = VALID_STATUS.indexOf(r.status) === -1 ? '' : (r.status || '');
      const def = ctx.defaultOf(r.studentId, date);
      const auto = !!def && status === def;
      const old = attMap[r.studentId];
      if (old && effectiveStatus_(old) === status && isTrue_(old.auto) === auto) return;
      rows.push({
        date, student_id: r.studentId, school: schoolName, status,
        self_drop: status === 'selfDrop', self_walk: status === 'selfWalk',
        teacher_id: s.userId, teacher_name: s.name, submitted_at: now,
        was_fixed_off: !!fixedToday[r.studentId], auto
      });
    });
    const n = rows.length;
    if (n) dbErr(await sb.from('rc_attendance').upsert(rows, { onConflict: 'date,student_id' }));
    if (body.autosave) {
      if (n) {
        const mine = D.submissions.filter(l => l.date === date && l.schoolId === schoolId && l.teacherId === s.userId)[0];
        if (mine) dbErr(await sb.from('rc_submissions').update({ teacher_name: s.name, submitted_at: now, count: Number(mine.count || 0) + n }).eq('id', mine.id));
        else dbErr(await sb.from('rc_submissions').insert({ date, school: schoolName, teacher_id: s.userId, teacher_name: s.name, submitted_at: now, count: n }));
      }
    } else {
      dbErr(await sb.from('rc_submissions').insert({ date, school: schoolName, teacher_id: s.userId, teacher_name: s.name, submitted_at: now, count: n }));
    }
    return { ok: true, submittedAt: now, count: n };
  };

  A.saveMarks = async body => {
    const r = await A.submitAttendance(Object.assign({}, body, { autosave: true }));
    if (r && r.ok) { try { await putPresence_(await requireSession('teacher'), body.schoolId, 'edit'); } catch (e) { /* 忽略 */ } }
    return r;
  };

  // ---------- 總覽與報表 ----------
  function overviewData_(D, schoolFilter, cutoff) {
    const today = today_();
    const activeIds = D.schools.filter(sc => sc.active).map(sc => sc.id);
    const totals = {};
    D.students.forEach(st => { if (isActive_(st.active)) totals[st.schoolId] = (totals[st.schoolId] || 0) + 1; });
    const attendance = D.attendance;
    const subIdx = submittersIndex_(D, cutoff, attendance);
    const ctx = statusCtx_(D);
    const byDate = {}, leaveIds = {}, hasRec = {};
    const bucket = (d, sid) => {
      byDate[d] = byDate[d] || {};
      return byDate[d][sid] = byDate[d][sid] || { present: 0, selfDrop: 0, selfWalk: 0, leave: 0, fixedOff: 0, marked: 0 };
    };
    const count = (b, d, studentId, schoolId, st) => {
      if (st) { b[st] = (b[st] || 0) + 1; b.marked++; }
      if (st === 'leave') (leaveIds[d] = leaveIds[d] || []).push({ sid: studentId, school: schoolId });
    };
    attendance.forEach(a => {
      const d = a.date;
      if (d < cutoff || d > today) return;
      if (schoolFilter && a.schoolId !== schoolFilter) return;
      hasRec[d + '|' + a.schoolId] = true;
      count(bucket(d, a.schoolId), d, a.studentId, a.schoolId, ctx.status(a.studentId, d));
    });
    Object.keys(ctx.bookings).forEach(sid => {
      const st = ctx.stMap[sid];
      if (!st || !isActive_(st.active) || (schoolFilter && st.schoolId !== schoolFilter)) return;
      ctx.bookings[sid].forEach(bk => {
        const from = bk.startDate < cutoff ? cutoff : bk.startDate, to = bk.endDate > today ? today : bk.endDate;
        for (let d = from; d <= to; d = nextDate_(d)) {
          if (ctx.rec[d + '|' + sid] || d === today || !ctx.bookingOn(sid, d)) continue;
          count(bucket(d, st.schoolId), d, sid, st.schoolId, 'leave');
        }
      });
    });
    const schoolStudents = {};
    D.students.forEach(st => { if (isActive_(st.active)) (schoolStudents[st.schoolId] = schoolStudents[st.schoolId] || []).push(st); });
    activeIds.forEach(sid => {
      if (schoolFilter && schoolFilter !== sid) return;
      const list = schoolStudents[sid] || [];
      const anyBooked = list.some(st => ctx.bookingOn(st.id, today));
      if (!hasRec[today + '|' + sid] && !anyBooked) return;
      const b = { present: 0, selfDrop: 0, selfWalk: 0, leave: 0, fixedOff: 0, marked: 0 };
      leaveIds[today] = (leaveIds[today] || []).filter(x => x.school !== sid);
      list.forEach(st => count(b, today, st.id, sid, ctx.status(st.id, today)));
      byDate[today] = byDate[today] || {};
      byDate[today][sid] = b;
    });
    const longLeave = {};
    Object.keys(leaveIds).forEach(d => {
      const streaks = leaveStreaks_(d, leaveIds[d].map(x => x.sid), ctx);
      leaveIds[d].forEach(x => { if (streaks[x.sid] >= LEAVE_STREAK_ALERT) longLeave[d + '|' + x.school] = (longLeave[d + '|' + x.school] || 0) + 1; });
    });
    byDate[today] = byDate[today] || {};
    const dates = Object.keys(byDate).sort((a, b) => b.localeCompare(a));
    const result = dates.map(date => {
      const ids = Object.keys(byDate[date]);
      if (date === today) activeIds.forEach(sid => { if (ids.indexOf(sid) === -1 && (!schoolFilter || schoolFilter === sid)) ids.push(sid); });
      const schools = ids.map(sid => {
        const b = byDate[date][sid];
        const total = totals[sid] || 0;
        const subs = subIdx[date + '|' + sid] || [];
        const last = subs[subs.length - 1] || null;
        const item = {
          schoolId: sid, schoolName: D.schoolName(sid) || '(已移除的學校)', total, submitted: !!hasRec[date + '|' + sid],
          present: 0, selfDrop: 0, selfWalk: 0, leave: 0, fixedOff: 0, attended: 0,
          unmarked: total, submitters: subs, submittedAt: last ? last.at : null, submittedBy: last ? last.name : null,
          longLeave: longLeave[date + '|' + sid] || 0
        };
        if (b) {
          item.present = b.present; item.selfDrop = b.selfDrop; item.selfWalk = b.selfWalk;
          item.leave = b.leave; item.fixedOff = b.fixedOff;
          item.attended = b.present + b.selfDrop + b.selfWalk;
          item.unmarked = Math.max(0, total - b.marked);
        }
        return item;
      });
      schools.sort((a, b) => String(a.schoolName).localeCompare(String(b.schoolName), 'zh-Hant'));
      return { date, schools };
    });
    return { today, dates: result, attendance, ctx };
  }

  A.getOverview = async body => {
    await requireSession('admin');
    const D = await loadAll();
    const d = overviewData_(D, body.schoolId || null, dateStrDaysAgo_(Number(body.days) || RETENTION_DAYS));
    const special = {};
    D.special.forEach(x => { special[x.date] = { type: x.type, reason: x.reason }; });
    return { ok: true, today: d.today, todayInfo: dayInfo_(d.today, D.special), special, dates: d.dates, presence: await presenceList_(D, null) };
  };

  A.getDayLeaves = async body => {
    await requireSession('admin');
    const date = String(body.date || '');
    const schoolFilter = body.schoolId || null;
    const D = await loadAll();
    const d = overviewData_(D, schoolFilter, date);
    const day = d.dates.filter(x => x.date === date)[0] || { date, schools: [] };
    const ctx = d.ctx, stMap = ctx.stMap;
    const cand = {};
    d.attendance.forEach(a => { if (a.date === date && (!schoolFilter || a.schoolId === schoolFilter)) cand[a.studentId] = a.schoolId; });
    Object.keys(ctx.bookings).forEach(sid => {
      const st = stMap[sid];
      if (st && isActive_(st.active) && (!schoolFilter || st.schoolId === schoolFilter) && ctx.bookingOn(sid, date)) cand[sid] = cand[sid] || st.schoolId;
    });
    if (date === d.today) {
      Object.keys(stMap).forEach(sid => {
        const st = stMap[sid];
        if (isActive_(st.active) && (!schoolFilter || st.schoolId === schoolFilter)) cand[sid] = cand[sid] || st.schoolId;
      });
    }
    const leaves = Object.keys(cand).filter(sid => ctx.status(sid, date) === 'leave').map(sid => {
      const st = stMap[sid], a = ctx.rec[date + '|' + sid];
      const so = st ? studentOut_(st) : { name: '(已刪除的學生)', grade: '', contacts: [], note: '' };
      const mine = !!ctx.teacherSet(a);
      const bk = mine ? null : ctx.bookingOn(sid, date);
      return {
        schoolId: cand[sid], schoolName: D.schoolName(cand[sid]) || '(已移除的學校)',
        id: sid, name: so.name, grade: String(so.grade), contacts: so.contacts, note: so.note,
        markedBy: mine ? a.teacherName : '', markedAt: mine ? a.submittedAt : '', booking: bk ? bookingBrief_(bk) : null
      };
    });
    const streaks = leaveStreaks_(date, leaves.map(x => x.id), ctx);
    leaves.forEach(x => { x.leaveStreak = streaks[x.id] || 0; });
    leaves.sort((a, b) => String(a.schoolName).localeCompare(String(b.schoolName), 'zh-Hant') ||
      (gradeNum_(a.grade) - gradeNum_(b.grade)) || (classNum_(a.grade) - classNum_(b.grade)) ||
      String(a.name).localeCompare(String(b.name), 'zh-Hant'));
    return { ok: true, date, schools: day.schools.filter(s => s.submitted), leaves };
  };

  A.getSchoolDayDetail = async body => {
    await requireSession('admin');
    const D = await loadAll();
    const date = String(body.date);
    const attMap = {}, rows = [];
    D.attendance.forEach(a => { if (a.schoolId === body.schoolId && a.date === date) { attMap[a.studentId] = a; rows.push(a); } });
    const isToday = date === today_();
    const ctx = statusCtx_(D);
    const out = activeStudentsOf_(D, body.schoolId).map(st => {
      const a = attMap[st.id];
      const so = studentOut_(st);
      const fixedNow = ctx.isFixed(st.id, date);
      const exb = ctx.extraOn(st.id, date);
      const status = ctx.status(st.id, date);
      const fixed = isToday || exb ? fixedNow : ((a && a.wasFixedOff !== null && a.wasFixedOff !== undefined) ? isTrue_(a.wasFixedOff) : fixedNow);
      const mine = !!ctx.teacherSet(a);
      const bk = !mine && status === 'leave' ? ctx.bookingOn(st.id, date) : null;
      return {
        id: st.id, name: st.name, grade: String(st.grade), status,
        wasFixedOff: fixed, contacts: so.contacts, note: so.note, booking: bk ? bookingBrief_(bk) : null, extra: exb ? bookingBrief_(exb) : null,
        markedBy: mine ? a.teacherName : '', markedAt: mine ? a.submittedAt : ''
      };
    });
    const streaks = leaveStreaks_(date, out.map(x => x.id), ctx);
    out.forEach(x => { x.leaveStreak = streaks[x.id] || 0; });
    sortStudents(out);
    const submitters = submittersIndex_(D, date, rows)[date + '|' + body.schoolId] || [];
    return { ok: true, students: out, submitters };
  };

  A.listLeaveStreaks = async body => {
    await requireSession('admin');
    const today = today_();
    const minDays = Math.max(1, Number(body.minDays) || LEAVE_STREAK_ALERT);
    const oldest = dateStrDaysAgo_(RETENTION_DAYS);
    const from = isDateStr_(body.from) ? String(body.from) : oldest;
    const to = isDateStr_(body.to) ? String(body.to) : today;
    const D = await loadAll();
    const ctx = statusCtx_(D);
    const cand = {};
    D.attendance.forEach(a => {
      if (effectiveStatus_(a) !== 'leave' || a.date < oldest) return;
      if (body.schoolId && a.schoolId !== body.schoolId) return;
      cand[a.studentId] = a.schoolId;
    });
    Object.keys(ctx.bookings).forEach(sid => {
      ctx.bookings[sid].forEach(b => {
        if (b.endDate < oldest || b.startDate > today) return;
        if (body.schoolId && b.schoolId !== body.schoolId) return;
        cand[sid] = cand[sid] || b.schoolId;
      });
    });
    const stMap = ctx.stMap;
    const dates = [];
    for (let d = oldest; d <= today; d = nextDate_(d)) dates.push(d);
    const out = [];
    Object.keys(cand).forEach(sid => {
      let run = [], booked = [];
      const close = ongoing => {
        if (run.length >= minDays && run[run.length - 1] >= from && run[0] <= to) {
          const st = stMap[sid];
          const so = st ? studentOut_(st) : { name: '(已刪除的學生)', grade: '' };
          out.push({ studentId: sid, schoolId: cand[sid], schoolName: D.schoolName(cand[sid]) || '(已移除的學校)',
            name: so.name, grade: String(so.grade), start: run[0], end: run[run.length - 1],
            days: run.length, dates: run.slice(), bookedDates: booked.slice(), ongoing: !!ongoing });
        }
        run = []; booked = [];
      };
      dates.forEach(d => {
        const s = ctx.status(sid, d);
        if (s === 'leave') { run.push(d); if (ctx.bookingOn(sid, d) && !ctx.teacherSet(ctx.rec[d + '|' + sid])) booked.push(d); }
        else if (s === 'fixedOff') { /* 不中斷 */ }
        else if (!s && (d === today || !ctx.isOpen(d) || ctx.isFixed(sid, d))) { /* 不中斷 */ }
        else close(false);
      });
      close(true);
    });
    out.sort((a, b) => (b.ongoing - a.ongoing) || (b.days - a.days) ||
      String(a.schoolName).localeCompare(String(b.schoolName), 'zh-Hant') ||
      (gradeNum_(a.grade) - gradeNum_(b.grade)) || (classNum_(a.grade) - classNum_(b.grade)) ||
      String(a.name).localeCompare(String(b.name), 'zh-Hant') || a.start.localeCompare(b.start));
    return { ok: true, today, oldest, from, to, minDays, items: out };
  };

  /* ---------------- 與學務雲入口共用登入 ---------------- */
  function rememberForPortal_(s) {
    try { sessionStorage.setItem('jx-me', JSON.stringify({ role: s.role, name: s.name })); } catch (e) { /* 忽略 */ }
  }

  /* ---------------- 對外介面 ---------------- */
  async function call(payload) {
    const action = payload && payload.action;
    const fn = A[action];
    if (!fn) return fail('UNKNOWN_ACTION');
    try {
      return await fn(payload);
    } catch (e) {
      const m = String((e && e.message) || e || '');
      if (/Failed to fetch|NetworkError|Load failed/i.test(m)) throw new Error('NETWORK_ERROR');
      if (m === 'NETWORK_ERROR') throw e;
      console.error('[雲點名]', action, e);
      return fail(m || 'UNKNOWN_ERROR');
    }
  }

  // 從學務雲入口進來（同一分頁已經登入）：直接沿用登入狀態，不必再登入一次
  try {
    const me = JSON.parse(sessionStorage.getItem('jx-me') || 'null');
    if (sessionStorage.getItem('jx-auth') && me && (me.role === 'admin' || me.role === 'teacher')) {
      const cur = JSON.parse(localStorage.getItem('jx_sb_session') || 'null');
      if (!cur || cur.role !== me.role || cur.name !== me.name || Date.now() - (cur.at || 0) > 60 * 60 * 1000) {
        localStorage.setItem('jx_sb_session', JSON.stringify({ token: 'sb', role: me.role, name: me.name, at: Date.now() }));
      }
    }
  } catch (e) { /* 忽略 */ }

  window.RCSB = { call, sb, today: today_ };
})();
