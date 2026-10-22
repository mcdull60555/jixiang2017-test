-- ============================================================
-- 基翔學務雲 第 2b 階段：雲點名網頁改接 Supabase 所需的函式與權限
-- 先在測試專案 jixiang-supabase-test 執行
-- 學生與學校資料透過下列函式讀寫（只限管理員與老師），不開放直接讀學生資料表，
-- 以免學習通老師端看到其他班的學生。
-- ============================================================

-- ---------- 學生（雲點名用）----------
-- 管理員與老師：讀取全部學生的點名用欄位（不含帳號密碼）
create or replace function public.rc_list_students()
returns table (id text, name text, school text, grade text, school_class integer, contacts jsonb,
               fixed_off_days integer[], note text, active boolean, in_rollcall boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not (select private.is_staff()) then raise exception 'staff only' using errcode = '42501'; end if;
  return query
    select s.id, s.name, s.school, s.grade, s.school_class, s.contacts, s.fixed_off_days, s.note, s.active, s.in_rollcall
      from public.students s;
end $$;

-- 管理員：新增或修改學生（有 id 就修改，沒有就新增；新增的學生預設進點名、學習通帳號先停用）
-- p_rows: [{ id?, school, grade(一年級…), school_class, name, contacts, fixed_off_days, note }]
create or replace function public.rc_save_students(p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r jsonb; v_id text; v_ids text[] := '{}';
begin
  if not (select private.is_admin()) then raise exception 'admin only' using errcode = '42501'; end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 300 then
    raise exception 'rows must be an array of up to 300 students' using errcode = '22023';
  end if;
  for r in select value from jsonb_array_elements(p_rows) loop
    if btrim(coalesce(r ->> 'name', '')) = '' or btrim(coalesce(r ->> 'school', '')) = '' then
      raise exception 'student name and school are required' using errcode = '22023';
    end if;
    if nullif(r ->> 'id', '') is not null then
      update public.students set
        name = btrim(r ->> 'name'),
        school = btrim(r ->> 'school'),
        grade = r ->> 'grade',
        school_class = nullif(r ->> 'school_class', '')::int,
        contacts = coalesce(r -> 'contacts', '[]'::jsonb),
        fixed_off_days = coalesce((select array_agg(x::int) from jsonb_array_elements_text(r -> 'fixed_off_days') x), '{}'),
        note = coalesce(r ->> 'note', '')
      where id = r ->> 'id'
      returning id into v_id;
      if v_id is null then raise exception 'student not found' using errcode = '22023'; end if;
    else
      insert into public.students (name, school, grade, school_class, contacts, fixed_off_days, note, in_rollcall, learning_enabled)
      values (btrim(r ->> 'name'), btrim(r ->> 'school'), r ->> 'grade', nullif(r ->> 'school_class', '')::int,
              coalesce(r -> 'contacts', '[]'::jsonb),
              coalesce((select array_agg(x::int) from jsonb_array_elements_text(r -> 'fixed_off_days') x), '{}'),
              coalesce(r ->> 'note', ''), true, false)
      returning id into v_id;
    end if;
    v_ids := v_ids || v_id;
  end loop;
  return jsonb_build_object('ids', to_jsonb(v_ids));
end $$;

-- 管理員：從雲點名移除學生（只是不再出現在點名名單；學生名冊與學習通不受影響）
create or replace function public.rc_remove_students(p_ids text[])
returns integer language plpgsql security definer set search_path = '' as $$
declare v_n integer;
begin
  if not (select private.is_admin()) then raise exception 'admin only' using errcode = '42501'; end if;
  update public.students set in_rollcall = false where id = any(coalesce(p_ids, '{}')) and in_rollcall;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- ---------- 學校 ----------
create or replace function public.rc_add_schools(p_names text[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare n text; v_created text[] := '{}'; v_skipped text[] := '{}';
begin
  if not (select private.is_admin()) then raise exception 'admin only' using errcode = '42501'; end if;
  foreach n in array coalesce(p_names, '{}') loop
    n := btrim(n);
    continue when n = '';
    if exists (select 1 from public.schools where name = n and active) or n = any(v_created) then
      v_skipped := v_skipped || n;
    elsif exists (select 1 from public.schools where name = n) then
      update public.schools set active = true where name = n;     -- 曾經刪除的學校重新啟用
      v_created := v_created || n;
    else
      insert into public.schools (name, sort_order) values (n, (select coalesce(max(sort_order), 0) + 1 from public.schools));
      v_created := v_created || n;
    end if;
  end loop;
  return jsonb_build_object('created', to_jsonb(v_created), 'skipped', to_jsonb(v_skipped));
end $$;

-- 修改校名：學生、點名紀錄、送出紀錄裡的校名一起改
create or replace function public.rc_rename_school(p_id text, p_name text)
returns text language plpgsql security definer set search_path = '' as $$
declare v_old text; v_new text := btrim(coalesce(p_name, ''));
begin
  if not (select private.is_admin()) then raise exception 'admin only' using errcode = '42501'; end if;
  if v_new = '' then return 'NAME_REQUIRED'; end if;
  select name into v_old from public.schools where id = p_id and active;
  if v_old is null then return 'SCHOOL_NOT_FOUND'; end if;
  if v_old = v_new then return 'OK'; end if;
  if exists (select 1 from public.schools where name = v_new) then return 'SCHOOL_EXISTS'; end if;
  update public.schools set name = v_new where id = p_id;
  update public.students set school = v_new where school = v_old;
  update public.rc_attendance set school = v_new where school = v_old;
  update public.rc_submissions set school = v_new where school = v_old;
  return 'OK';
end $$;

-- 刪除學校：標記刪除（歷史紀錄仍看得到校名），該校學生不再出現在點名名單
create or replace function public.rc_close_school(p_id text)
returns integer language plpgsql security definer set search_path = '' as $$
declare v_name text; v_n integer;
begin
  if not (select private.is_admin()) then raise exception 'admin only' using errcode = '42501'; end if;
  select name into v_name from public.schools where id = p_id and active;
  if v_name is null then return -1; end if;
  update public.schools set active = false where id = p_id;
  update public.students set in_rollcall = false where school = v_name and in_rollcall;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

grant execute on function public.rc_list_students(), public.rc_save_students(jsonb), public.rc_remove_students(text[]),
  public.rc_add_schools(text[]), public.rc_rename_school(text, text), public.rc_close_school(text) to authenticated;
revoke execute on function public.rc_list_students(), public.rc_save_students(jsonb), public.rc_remove_students(text[]),
  public.rc_add_schools(text[]), public.rc_rename_school(text, text), public.rc_close_school(text) from anon;

-- ---------- 老師目前在哪間學校（取代原本的快取）----------
create table if not exists public.rc_presence (
  teacher_id uuid primary key references public.profiles (id) on delete cascade,
  name text not null default '',
  school_id text,
  mode text not null default 'view' check (mode in ('view', 'edit')),
  at timestamptz not null default now()
);
alter table public.rc_presence enable row level security;
create policy rc_presence_read on public.rc_presence for select to authenticated using ((select private.is_staff()));
create policy rc_presence_own_insert on public.rc_presence for insert to authenticated with check (teacher_id = (select auth.uid()));
create policy rc_presence_own_update on public.rc_presence for update to authenticated
  using (teacher_id = (select auth.uid())) with check (teacher_id = (select auth.uid()));
grant select, insert, update on public.rc_presence to authenticated;

-- ---------- 刪除權限（只限列表中的資料表，實際範圍由 RLS 決定）----------
-- 預約請假、臨時進班：管理員與老師（老師只能刪尚未開始的，由網頁檢查）
-- 點名日設定：只有管理員
grant delete on public.rc_leave_bookings, public.rc_extra_classes, public.rc_special_days to authenticated;

-- ---------- 每天清理：點名紀錄、送出紀錄、點名日、預約請假與臨時進班超過 40 天才清除 ----------
create or replace function private.rc_cleanup()
returns void language plpgsql security definer set search_path = '' as $$
declare v_cut date := ((now() at time zone 'Asia/Taipei')::date - 40);
begin
  delete from public.rc_attendance where date < v_cut;
  delete from public.rc_submissions where date < v_cut;
  delete from public.rc_special_days where date < v_cut;
  delete from public.rc_leave_bookings where end_date < v_cut;
  delete from public.rc_extra_classes where end_date < v_cut;
  delete from public.rc_presence where at < now() - interval '1 day';
end $$;
select cron.schedule('xuewuyun-rc-cleanup', '5 19 * * *', 'select private.rc_cleanup()');   -- 台灣時間每天 03:05
