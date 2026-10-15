-- 基翔小學通 Supabase 測試專案：階段 E 多班級／多老師／管理者
-- 用法：Supabase 後台 → SQL Editor → 貼上 → Run（只在測試專案；可重複執行）
-- 重點：
--   * 學生可同時加入多個班級（classes / class_students），一組帳號通用
--   * 作業、考卷、聯絡簿、送審紀錄都記錄 class_id；老師只能碰自己班
--   * 管理者只管老師、班級、年級、科目；看不到班級內的學生作業與聯絡簿
--   * 年級、科目全校共用，只有管理者能改

-- ========== 1. 班級資料表 ==========
create table if not exists public.classes (
  id         text primary key default ('c_' || replace(gen_random_uuid()::text, '-', '')),
  name       text not null check (length(btrim(name)) > 0),
  sort_order int  not null default 0,
  created_at timestamptz not null default now(),
  unique (name)
);
alter table public.classes enable row level security;
revoke all on public.classes from anon, authenticated, public;

create table if not exists public.class_students (
  class_id   text not null references public.classes(id)  on delete cascade,
  student_id text not null references public.students(id) on delete cascade,
  primary key (class_id, student_id)
);
create index if not exists class_students_student_idx on public.class_students (student_id);
alter table public.class_students enable row level security;
revoke all on public.class_students from anon, authenticated, public;

-- 預設班級（既有測試資料全部放進「測試班」）
insert into public.classes (id, name, sort_order) values ('c_default', '測試班', 1), ('c_math', '數學班', 2)
on conflict (id) do nothing;
insert into public.class_students (class_id, student_id)
select 'c_default', s.id from public.students s on conflict do nothing;

-- ========== 2. 新欄位 ==========
alter table public.profiles add column if not exists class_id     text references public.classes(id) on delete set null;
alter table public.profiles add column if not exists login_id     text;
alter table public.profiles add column if not exists display_name text;
create unique index if not exists profiles_login_id_key on public.profiles (login_id) where login_id is not null;

alter table public.profiles drop constraint if exists profiles_check;
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check check (role in ('teacher', 'student', 'admin'));
alter table public.profiles add constraint profiles_check check (
  (role in ('teacher', 'admin') and student_id is null) or (role = 'student' and student_id is not null));

alter table public.tasks add column if not exists class_id text references public.classes(id) on delete cascade;
update public.tasks set class_id = 'c_default' where class_id is null;
alter table public.tasks alter column class_id set not null;
alter table public.tasks drop constraint if exists tasks_student_id_type_subject_title_date_key;
alter table public.tasks drop constraint if exists tasks_student_class_type_subject_title_date_key;
alter table public.tasks add constraint tasks_student_class_type_subject_title_date_key
  unique (student_id, class_id, type, subject, title, date);
create index if not exists tasks_class_idx on public.tasks (class_id);

alter table public.contact_book add column if not exists class_id text references public.classes(id) on delete cascade;
update public.contact_book set class_id = 'c_default' where class_id is null;
alter table public.contact_book alter column class_id set not null;
create index if not exists contact_book_class_idx on public.contact_book (class_id);

alter table public.submit_log add column if not exists class_id text references public.classes(id) on delete cascade;
update public.submit_log set class_id = 'c_default' where class_id is null;

-- ========== 3. 輔助函式 ==========
create or replace function private.is_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles p where p.id = (select auth.uid()) and p.role = 'admin')
$$;

create or replace function private.my_class_id()
returns text language sql stable security definer set search_path = '' as $$
  select p.class_id from public.profiles p where p.id = (select auth.uid()) and p.role = 'teacher'
$$;

-- 建立登入帳號（Auth 內的真實密碼是隨機值；4 位數密碼存在 private.login_pins）
create or replace function private.create_auth_user(p_email text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := gen_random_uuid();
begin
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change,
    email_change_token_current, reauthentication_token, phone_change, phone_change_token
  ) values (
    '00000000-0000-0000-0000-000000000000', v_uid, 'authenticated', 'authenticated', p_email,
    extensions.crypt(gen_random_uuid()::text || gen_random_uuid()::text, extensions.gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}', '{}', now(), now(),
    '', '', '', '', '', '', '', ''
  );
  insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (v_uid::text, v_uid,
          jsonb_build_object('sub', v_uid::text, 'email', p_email, 'email_verified', true, 'phone_verified', false),
          'email', now(), now(), now());
  return v_uid;
end $$;

create or replace function private.set_pin(p_uid uuid, p_pin text)
returns void language sql security definer set search_path = '' as $$
  insert into private.login_pins (user_id, pin_hash)
  values (p_uid, extensions.crypt('jx' || p_pin, extensions.gen_salt('bf')))
  on conflict (user_id) do update
    set pin_hash = excluded.pin_hash, failed_count = 0, last_failed_at = null, locked_until = null
$$;

revoke all on function private.is_admin(), private.my_class_id(), private.create_auth_user(text), private.set_pin(uuid, text)
  from public, anon, authenticated;
grant execute on function private.is_admin(), private.my_class_id() to authenticated;
grant usage on schema private to authenticated;

-- ========== 4. 欄位權限 ==========
grant select (class_id) on public.tasks to authenticated;
grant insert (class_id) on public.tasks to authenticated;
grant select (class_id) on public.contact_book to authenticated;
grant insert (class_id) on public.contact_book to authenticated;
grant select (class_id) on public.submit_log to authenticated;
grant select (class_id, login_id, display_name) on public.profiles to authenticated;

grant select (id, name, sort_order) on public.classes to anon, authenticated;
grant insert (id, name, sort_order) on public.classes to authenticated;
grant update (name, sort_order) on public.classes to authenticated;
grant delete on public.classes to authenticated;
grant select (class_id, student_id) on public.class_students to anon, authenticated;

-- ========== 5. 權限規則（RLS） ==========
-- classes / class_students：名單公開（學生登入前要選班級）；只有管理者能改班級
drop policy if exists classes_select on public.classes;
drop policy if exists classes_insert on public.classes;
drop policy if exists classes_update on public.classes;
drop policy if exists classes_delete on public.classes;
create policy classes_select on public.classes for select to anon, authenticated using (true);
create policy classes_insert on public.classes for insert to authenticated with check ((select private.is_admin()));
create policy classes_update on public.classes for update to authenticated
  using ((select private.is_admin())) with check ((select private.is_admin()));
create policy classes_delete on public.classes for delete to authenticated using ((select private.is_admin()));

drop policy if exists class_students_select on public.class_students;
create policy class_students_select on public.class_students for select to anon, authenticated using (true);

-- profiles：自己，或管理者
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (id = (select auth.uid()) or (select private.is_admin()));

-- students：老師只看得到自己班的學生；新增／刪除一律走函式
drop policy if exists students_select_auth on public.students;
drop policy if exists students_update on public.students;
drop policy if exists students_insert on public.students;
drop policy if exists students_delete on public.students;
create policy students_select_auth on public.students for select to authenticated using (
  id = (select private.my_student_id())
  or exists (select 1 from public.class_students cs
              where cs.student_id = students.id and cs.class_id = (select private.my_class_id())));
create policy students_update on public.students for update to authenticated
  using ((select private.is_teacher()) and exists (select 1 from public.class_students cs
          where cs.student_id = students.id and cs.class_id = (select private.my_class_id())))
  with check ((select private.is_teacher()) and exists (select 1 from public.class_students cs
          where cs.student_id = students.id and cs.class_id = (select private.my_class_id())));

-- tasks
drop policy if exists tasks_select on public.tasks;
drop policy if exists tasks_insert on public.tasks;
drop policy if exists tasks_update on public.tasks;
drop policy if exists tasks_delete on public.tasks;
create policy tasks_select on public.tasks for select to authenticated using (
  class_id = (select private.my_class_id())
  or (student_id = (select private.my_student_id()) and date <= ((now() at time zone 'Asia/Taipei')::date)));
create policy tasks_insert on public.tasks for insert to authenticated with check (
  (select private.is_teacher()) and class_id = (select private.my_class_id())
  and exists (select 1 from public.class_students cs
               where cs.student_id = tasks.student_id and cs.class_id = tasks.class_id));
create policy tasks_update on public.tasks for update to authenticated
  using ((select private.is_teacher()) and class_id = (select private.my_class_id()))
  with check ((select private.is_teacher()) and class_id = (select private.my_class_id()));
create policy tasks_delete on public.tasks for delete to authenticated
  using ((select private.is_teacher()) and class_id = (select private.my_class_id()));

-- contact_book
drop policy if exists contact_book_select on public.contact_book;
drop policy if exists contact_book_insert on public.contact_book;
drop policy if exists contact_book_update on public.contact_book;
drop policy if exists contact_book_delete on public.contact_book;
create policy contact_book_select on public.contact_book for select to authenticated
  using ((select private.is_teacher()) and class_id = (select private.my_class_id()));
create policy contact_book_insert on public.contact_book for insert to authenticated
  with check ((select private.is_teacher()) and class_id = (select private.my_class_id()));
create policy contact_book_update on public.contact_book for update to authenticated
  using ((select private.is_teacher()) and class_id = (select private.my_class_id()))
  with check ((select private.is_teacher()) and class_id = (select private.my_class_id()));
create policy contact_book_delete on public.contact_book for delete to authenticated
  using ((select private.is_teacher()) and class_id = (select private.my_class_id()));

-- submit_log
drop policy if exists submit_log_select on public.submit_log;
create policy submit_log_select on public.submit_log for select to authenticated
  using ((select private.is_teacher()) and class_id = (select private.my_class_id()));

-- grades / subjects：大家可讀，只有管理者能改
do $$
declare t text;
begin
  foreach t in array array['grades', 'subjects'] loop
    execute format('drop policy if exists %I on public.%I', t || '_insert', t);
    execute format('drop policy if exists %I on public.%I', t || '_update', t);
    execute format('drop policy if exists %I on public.%I', t || '_delete', t);
    execute format('create policy %I on public.%I for insert to authenticated with check ((select private.is_admin()))', t || '_insert', t);
    execute format('create policy %I on public.%I for update to authenticated using ((select private.is_admin())) with check ((select private.is_admin()))', t || '_update', t);
    execute format('create policy %I on public.%I for delete to authenticated using ((select private.is_admin()))', t || '_delete', t);
  end loop;
end $$;

-- ========== 6. 學生／老師函式 ==========
create or replace function public.student_submit(p_ids text[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_sid text := (select private.my_student_id());
  v_today date := (now() at time zone 'Asia/Taipei')::date;
  v_id text; r public.tasks%rowtype; v_name text;
  v_changed int := 0; v_skipped text[] := '{}';
begin
  if v_sid is null then raise exception 'only students can submit' using errcode = '42501'; end if;
  if p_ids is null or cardinality(p_ids) = 0 or cardinality(p_ids) > 500 then
    raise exception 'ids must contain 1 to 500 items' using errcode = '22023';
  end if;
  select s.name into v_name from public.students s where s.id = v_sid;
  foreach v_id in array p_ids loop
    select * into r from public.tasks t where t.id = v_id for update;
    if not found or r.student_id <> v_sid or r.teacher_status = '已完成' or r.date > v_today then
      v_skipped := v_skipped || v_id; continue;
    end if;
    if not (r.student_checked and r.pending_review) then
      update public.tasks set student_checked = true, pending_review = true, submitted_at = now() where id = v_id;
      insert into public.submit_log (action, task_id, student_id, student_name, type, subject, title, date, class_id)
      values ('submit', r.id, r.student_id, coalesce(v_name, ''), r.type, r.subject, r.title, r.date, r.class_id);
      v_changed := v_changed + 1;
    end if;
  end loop;
  return jsonb_build_object('changed', v_changed, 'skipped', to_jsonb(v_skipped));
end $$;

create or replace function public.student_withdraw(p_ids text[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_sid text := (select private.my_student_id());
  v_id text; r public.tasks%rowtype; v_name text;
  v_changed int := 0; v_skipped text[] := '{}';
begin
  if v_sid is null then raise exception 'only students can withdraw' using errcode = '42501'; end if;
  if p_ids is null or cardinality(p_ids) = 0 or cardinality(p_ids) > 500 then
    raise exception 'ids must contain 1 to 500 items' using errcode = '22023';
  end if;
  select s.name into v_name from public.students s where s.id = v_sid;
  foreach v_id in array p_ids loop
    select * into r from public.tasks t where t.id = v_id for update;
    if not found or r.student_id <> v_sid or r.teacher_status = '已完成' then
      v_skipped := v_skipped || v_id; continue;
    end if;
    if r.student_checked or r.pending_review then
      update public.tasks set student_checked = false, pending_review = false, submitted_at = null where id = v_id;
      insert into public.submit_log (action, task_id, student_id, student_name, type, subject, title, date, class_id)
      values ('withdraw', r.id, r.student_id, coalesce(v_name, ''), r.type, r.subject, r.title, r.date, r.class_id);
      v_changed := v_changed + 1;
    elsif r.submitted_at is not null then
      update public.tasks set submitted_at = null where id = v_id;
    end if;
  end loop;
  return jsonb_build_object('changed', v_changed, 'skipped', to_jsonb(v_skipped));
end $$;

create or replace function public.teacher_review(p_ids text[], p_status text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_class text := (select private.my_class_id());
  v_id text; r public.tasks%rowtype; v_name text; v_checked boolean;
  v_changed int := 0; v_skipped text[] := '{}';
begin
  if not (select private.is_teacher()) or v_class is null then
    raise exception 'only teachers can review' using errcode = '42501';
  end if;
  if p_status is null or p_status not in ('未完成', '待訂正', '已完成') then
    raise exception 'invalid status' using errcode = '22023';
  end if;
  if p_ids is null or cardinality(p_ids) = 0 or cardinality(p_ids) > 500 then
    raise exception 'ids must contain 1 to 500 items' using errcode = '22023';
  end if;
  v_checked := (p_status = '已完成');
  foreach v_id in array p_ids loop
    select * into r from public.tasks t where t.id = v_id and t.class_id = v_class for update;
    if not found then v_skipped := v_skipped || v_id; continue; end if;
    if r.teacher_status is distinct from p_status or r.pending_review or r.student_checked is distinct from v_checked then
      update public.tasks
         set teacher_status = p_status, pending_review = false, student_checked = v_checked, reviewed_at = now(),
             done_at = case when p_status = '已完成' and r.teacher_status <> '已完成' then now()
                            when p_status <> '已完成' then null else r.done_at end
       where id = v_id;
      select s.name into v_name from public.students s where s.id = r.student_id;
      insert into public.submit_log (action, task_id, student_id, student_name, type, subject, title, date, status, class_id)
      values ('review', r.id, r.student_id, coalesce(v_name, ''), r.type, r.subject, r.title, r.date, p_status, r.class_id);
      v_changed := v_changed + 1;
    end if;
  end loop;
  return jsonb_build_object('changed', v_changed, 'skipped', to_jsonb(v_skipped));
end $$;

create or replace function public.teacher_update_tasks(p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_n int; v_class text := (select private.my_class_id());
begin
  if not (select private.is_teacher()) or v_class is null then
    raise exception 'only teachers can update tasks' using errcode = '42501';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 or jsonb_array_length(p_rows) > 2000 then
    raise exception 'rows must be an array of 1 to 2000 items' using errcode = '22023';
  end if;
  update public.tasks t
     set type = r.type, subject = r.subject, title = r.title, date = r.date
    from jsonb_to_recordset(p_rows) as r(id text, type text, subject text, title text, date date)
   where t.id = r.id and t.class_id = v_class
     and (t.type, t.subject, t.title, t.date) is distinct from (r.type, r.subject, r.title, r.date);
  get diagnostics v_n = row_count;
  return jsonb_build_object('updated', v_n);
end $$;

-- 新增全新的學生（同時加入老師自己的班）
create or replace function public.teacher_create_students(p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  r jsonb; v_class text := (select private.my_class_id());
  v_id text; v_name text; v_school text; v_grade text; v_pw text; v_uid uuid; v_n int := 0;
begin
  if not (select private.is_teacher()) or v_class is null then
    raise exception 'only teachers can create students' using errcode = '42501';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 or jsonb_array_length(p_rows) > 200 then
    raise exception 'rows must be an array of 1 to 200 students' using errcode = '22023';
  end if;
  for r in select value from jsonb_array_elements(p_rows) loop
    v_id := r ->> 'id';
    v_name := btrim(coalesce(r ->> 'name', ''));
    v_school := btrim(coalesce(r ->> 'school', ''));
    v_grade := r ->> 'grade';
    v_pw := coalesce(nullif(btrim(r ->> 'pwd'), ''), '0000');
    if v_id is null or v_id !~ '^[a-z0-9_-]{1,100}$' then
      raise exception 'invalid student id: %', coalesce(v_id, '(null)') using errcode = '22023';
    end if;
    if v_name = '' or v_school = '' then
      raise exception 'student name and school are required' using errcode = '22023';
    end if;
    if v_pw !~ '^[0-9]{4}$' then raise exception 'password must be 4 digits' using errcode = '22023'; end if;

    insert into public.students (id, name, school, grade, class_name, avatar)
    values (v_id, v_name, v_school, v_grade, coalesce(r ->> 'className', ''), coalesce(r ->> 'avatar', ''));
    v_uid := private.create_auth_user(v_id || '@school.test');
    insert into public.profiles (id, role, student_id) values (v_uid, 'student', v_id);
    perform private.set_pin(v_uid, v_pw);
    update public.students set auth_user_id = v_uid where id = v_id;
    insert into public.class_students (class_id, student_id) values (v_class, v_id);
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('created', v_n);
end $$;

-- 把已存在的學生（例如在別班已建立）加入自己的班
create or replace function public.teacher_add_students_to_class(p_ids text[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_class text := (select private.my_class_id()); v_n int;
begin
  if not (select private.is_teacher()) or v_class is null then
    raise exception 'only teachers can add students' using errcode = '42501';
  end if;
  if p_ids is null or cardinality(p_ids) = 0 or cardinality(p_ids) > 200 then
    raise exception 'ids must contain 1 to 200 items' using errcode = '22023';
  end if;
  insert into public.class_students (class_id, student_id)
  select v_class, s.id from public.students s where s.id = any(p_ids)
  on conflict do nothing;
  get diagnostics v_n = row_count;
  return jsonb_build_object('added', v_n);
end $$;

-- 把學生移出自己的班（該班的作業一併刪除）；若學生已不屬於任何班，才刪除其帳號
create or replace function public.teacher_delete_students(p_ids text[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_class text := (select private.my_class_id()); v_ids text[]; v_orphans text[]; v_removed int; v_deleted int := 0;
begin
  if not (select private.is_teacher()) or v_class is null then
    raise exception 'only teachers can remove students' using errcode = '42501';
  end if;
  if p_ids is null or cardinality(p_ids) = 0 or cardinality(p_ids) > 500 then
    raise exception 'ids must contain 1 to 500 items' using errcode = '22023';
  end if;
  select coalesce(array_agg(cs.student_id), '{}') into v_ids
    from public.class_students cs where cs.class_id = v_class and cs.student_id = any(p_ids);
  delete from public.tasks where class_id = v_class and student_id = any(v_ids);
  delete from public.class_students where class_id = v_class and student_id = any(v_ids);
  get diagnostics v_removed = row_count;
  select coalesce(array_agg(s.id), '{}') into v_orphans
    from public.students s
   where s.id = any(v_ids) and not exists (select 1 from public.class_students cs where cs.student_id = s.id);
  if cardinality(v_orphans) > 0 then
    delete from auth.users where id in (select s.auth_user_id from public.students s where s.id = any(v_orphans) and s.auth_user_id is not null);
    delete from public.students where id = any(v_orphans);
    get diagnostics v_deleted = row_count;
  end if;
  return jsonb_build_object('removed', v_removed, 'deleted', v_deleted);
end $$;

create or replace function public.teacher_set_student_passwords(p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r jsonb; v_class text := (select private.my_class_id()); v_n int := 0; v_cnt int;
begin
  if not (select private.is_teacher()) or v_class is null then
    raise exception 'only teachers can set passwords' using errcode = '42501';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 or jsonb_array_length(p_rows) > 500 then
    raise exception 'rows must be an array of 1 to 500 items' using errcode = '22023';
  end if;
  for r in select value from jsonb_array_elements(p_rows) loop
    if coalesce(r ->> 'pwd', '') !~ '^[0-9]{4}$' then raise exception 'password must be 4 digits' using errcode = '22023'; end if;
    insert into private.login_pins (user_id, pin_hash)
    select s.auth_user_id, extensions.crypt('jx' || (r ->> 'pwd'), extensions.gen_salt('bf'))
      from public.students s
     where s.id = r ->> 'id' and s.auth_user_id is not null
       and exists (select 1 from public.class_students cs where cs.student_id = s.id and cs.class_id = v_class)
    on conflict (user_id) do update
      set pin_hash = excluded.pin_hash, failed_count = 0, last_failed_at = null, locked_until = null;
    get diagnostics v_cnt = row_count;
    v_n := v_n + v_cnt;
  end loop;
  return jsonb_build_object('updated', v_n);
end $$;

-- 聯絡簿：老師看自己班；學生看自己所屬各班（再依年級／學校過濾）
drop function if exists public.get_contact_book();
create function public.get_contact_book()
returns table(id text, class_id text, date date, weekday text, content text, items jsonb)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_student public.students%rowtype;
  v_today date := (now() at time zone 'Asia/Taipei')::date;
begin
  if (select private.is_teacher()) then
    return query
      select cb.id, cb.class_id, cb.date, cb.weekday, cb.content, cb.items
        from public.contact_book cb
       where cb.class_id = (select private.my_class_id()) and cb.date >= v_today - 10
       order by cb.date, cb.id;
    return;
  end if;
  select s.* into v_student from public.students s where s.id = (select private.my_student_id());
  if not found then return; end if;
  return query
    select f.id, f.class_id, f.date, f.weekday,
           (select coalesce(string_agg(x.n::text || '. ' || (x.it ->> 'text'), E'\n' order by x.n), '')
              from (select e.it, row_number() over (order by e.ord) as n
                      from jsonb_array_elements(f.items) with ordinality as e(it, ord)) x),
           f.items
      from (
        select cb.id, cb.class_id, cb.date, cb.weekday,
               coalesce((
                 select jsonb_agg(e.it order by e.ord)
                   from jsonb_array_elements(cb.items) with ordinality as e(it, ord)
                  where coalesce(jsonb_array_length(e.it -> 'targets'), 0) = 0
                     or exists (select 1 from jsonb_array_elements(e.it -> 'targets') tg
                                 where tg ->> 'grade' = v_student.grade
                                   and (tg -> 'schools') @> to_jsonb(v_student.school))
               ), '[]'::jsonb) as items
          from public.contact_book cb
         where cb.date >= v_today - 10
           and cb.class_id in (select cs.class_id from public.class_students cs where cs.student_id = v_student.id)
      ) f
     where jsonb_array_length(f.items) > 0
     order by f.date, f.id;
end $$;
revoke all on function public.get_contact_book() from public, anon;
grant execute on function public.get_contact_book() to authenticated;

-- 跑馬燈：只計算「看的人所屬班級」內的項目
create or replace function public.get_champions()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_today date := (now() at time zone 'Asia/Taipei')::date;
  v_dow int := extract(isodow from (now() at time zone 'Asia/Taipei'))::int;
  v_start date; v_end date; v_classes text[];
begin
  if (select private.is_teacher()) then
    v_classes := array[(select private.my_class_id())];
  elsif (select private.my_student_id()) is not null then
    v_classes := array(select cs.class_id from public.class_students cs where cs.student_id = (select private.my_student_id()));
  else
    v_classes := '{}';
  end if;
  v_start := v_today - (v_dow - 1) - 7;
  v_end := v_start + 6;
  return jsonb_build_object('weekStart', v_start, 'weekEnd', v_end, 'list', coalesce((
    select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'school', c.school, 'grade', c.grade,
                                        'avatar', c.avatar, 'finishedAt', c.finished_at)
                     order by (c.finished_at is null), c.finished_at, c.name)
      from (
        select s.id, s.name, s.school, s.grade, s.avatar, max(coalesce(t.done_at, t.reviewed_at)) as finished_at
          from public.students s
          join public.tasks t on t.student_id = s.id
         where t.class_id = any(v_classes) and t.date between v_start and v_end and t.date <= v_today
         group by s.id, s.name, s.school, s.grade, s.avatar
        having bool_and(t.teacher_status = '已完成')
      ) c
  ), '[]'::jsonb));
end $$;

-- 登入前的老師名單（只有顯示名稱、登入代號、班級）
create or replace function public.list_teachers()
returns table(login_id text, display_name text, class_id text, class_name text)
language sql stable security definer set search_path = '' as $$
  select p.login_id, coalesce(p.display_name, p.login_id), p.class_id, c.name
    from public.profiles p left join public.classes c on c.id = p.class_id
   where p.role = 'teacher' and p.login_id is not null
   order by coalesce(p.display_name, p.login_id)
$$;
revoke all on function public.list_teachers() from public;
grant execute on function public.list_teachers() to anon, authenticated;

-- 改自己的密碼（學生 4 位數字；老師／管理者 4～64 字元）
create or replace function public.change_my_pin(p_pin text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_role text;
begin
  select role into v_role from public.profiles where id = auth.uid();
  if v_role is null then raise exception 'not logged in' using errcode = '42501'; end if;
  if v_role = 'student' and coalesce(p_pin, '') !~ '^[0-9]{4}$' then
    raise exception 'password must be 4 digits' using errcode = '22023';
  end if;
  if v_role in ('teacher', 'admin') and (p_pin is null or length(p_pin) < 4 or length(p_pin) > 64) then
    raise exception 'password must be 4 to 64 characters' using errcode = '22023';
  end if;
  perform private.set_pin(auth.uid(), p_pin);
end $$;
revoke all on function public.change_my_pin(text) from public, anon;
grant execute on function public.change_my_pin(text) to authenticated;

-- ========== 7. 管理者函式 ==========
create or replace function public.admin_create_teacher(p_login text, p_name text, p_pin text, p_class text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid;
begin
  if not (select private.is_admin()) then raise exception 'admin only' using errcode = '42501'; end if;
  if p_login is null or p_login !~ '^t_[a-z0-9_-]{1,60}$' then
    raise exception 'teacher id must look like t_name (lowercase letters, digits, - _)' using errcode = '22023';
  end if;
  if btrim(coalesce(p_name, '')) = '' then raise exception 'name required' using errcode = '22023'; end if;
  if p_pin is null or length(p_pin) < 4 or length(p_pin) > 64 then
    raise exception 'password must be 4 to 64 characters' using errcode = '22023';
  end if;
  if p_class is not null and not exists (select 1 from public.classes where id = p_class) then
    raise exception 'class not found' using errcode = '22023';
  end if;
  v_uid := private.create_auth_user(p_login || '@school.test');
  insert into public.profiles (id, role, login_id, display_name, class_id)
  values (v_uid, 'teacher', p_login, btrim(p_name), p_class);
  perform private.set_pin(v_uid, p_pin);
  return jsonb_build_object('id', v_uid);
end $$;

create or replace function public.admin_update_teacher(p_id uuid, p_name text, p_class text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not (select private.is_admin()) then raise exception 'admin only' using errcode = '42501'; end if;
  if btrim(coalesce(p_name, '')) = '' then raise exception 'name required' using errcode = '22023'; end if;
  if p_class is not null and not exists (select 1 from public.classes where id = p_class) then
    raise exception 'class not found' using errcode = '22023';
  end if;
  update public.profiles set display_name = btrim(p_name), class_id = p_class where id = p_id and role = 'teacher';
end $$;

create or replace function public.admin_set_teacher_pin(p_id uuid, p_pin text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not (select private.is_admin()) then raise exception 'admin only' using errcode = '42501'; end if;
  if p_pin is null or length(p_pin) < 4 or length(p_pin) > 64 then
    raise exception 'password must be 4 to 64 characters' using errcode = '22023';
  end if;
  if not exists (select 1 from public.profiles where id = p_id and role = 'teacher') then
    raise exception 'teacher not found' using errcode = '22023';
  end if;
  perform private.set_pin(p_id, p_pin);
end $$;

create or replace function public.admin_delete_teacher(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not (select private.is_admin()) then raise exception 'admin only' using errcode = '42501'; end if;
  if not exists (select 1 from public.profiles where id = p_id and role = 'teacher') then
    raise exception 'teacher not found' using errcode = '22023';
  end if;
  delete from auth.users where id = p_id;
end $$;

-- 函式執行權限：只有登入者；匿名一律不行（list_teachers 例外）
revoke all on function
  public.student_submit(text[]), public.student_withdraw(text[]), public.teacher_review(text[], text),
  public.teacher_update_tasks(jsonb), public.teacher_create_students(jsonb), public.teacher_add_students_to_class(text[]),
  public.teacher_delete_students(text[]), public.teacher_set_student_passwords(jsonb), public.get_champions(),
  public.admin_create_teacher(text, text, text, text), public.admin_update_teacher(uuid, text, text),
  public.admin_set_teacher_pin(uuid, text), public.admin_delete_teacher(uuid)
  from public, anon;
grant execute on function
  public.student_submit(text[]), public.student_withdraw(text[]), public.teacher_review(text[], text),
  public.teacher_update_tasks(jsonb), public.teacher_create_students(jsonb), public.teacher_add_students_to_class(text[]),
  public.teacher_delete_students(text[]), public.teacher_set_student_passwords(jsonb), public.get_champions(),
  public.admin_create_teacher(text, text, text, text), public.admin_update_teacher(uuid, text, text),
  public.admin_set_teacher_pin(uuid, text), public.admin_delete_teacher(uuid)
  to authenticated;

-- ========== 8. 測試帳號（只在測試專案） ==========
-- 既有老師改名為 t_demo（示範老師，測試班），密碼維持原本的
do $$
declare v_uid uuid;
begin
  select id into v_uid from auth.users where email = 'teacher@school.test';
  if v_uid is not null then
    update auth.users set email = 't_demo@school.test', updated_at = now() where id = v_uid;
    update auth.identities
       set identity_data = identity_data || jsonb_build_object('email', 't_demo@school.test')
     where user_id = v_uid;
    update public.profiles set login_id = 't_demo', display_name = '示範老師', class_id = 'c_default' where id = v_uid;
  end if;

  -- 管理者：admin，密碼 8888
  if not exists (select 1 from auth.users where email = 'admin@school.test') then
    v_uid := private.create_auth_user('admin@school.test');
    insert into public.profiles (id, role, login_id, display_name) values (v_uid, 'admin', 'admin', '管理者');
    perform private.set_pin(v_uid, '8888');
  end if;

  -- 數學班老師：t_math，密碼 7777
  if not exists (select 1 from auth.users where email = 't_math@school.test') then
    v_uid := private.create_auth_user('t_math@school.test');
    insert into public.profiles (id, role, login_id, display_name, class_id) values (v_uid, 'teacher', 't_math', '數學老師', 'c_math');
    perform private.set_pin(v_uid, '7777');
  end if;

  -- 讓其中一位學生同時加入數學班，並放一份數學班作業
  if exists (select 1 from public.students where id = 's_test05') then
    insert into public.class_students (class_id, student_id) values ('c_math', 's_test05') on conflict do nothing;
    insert into public.tasks (student_id, class_id, type, subject, title, date)
    select 's_test05', 'c_math', '作業', s.name, '數學班示範作業', (now() at time zone 'Asia/Taipei')::date
      from public.subjects s order by s.sort_order, s.name limit 1
    on conflict do nothing;
  end if;
end $$;
-- 基翔小學通 Supabase 測試專案：階段 F 老師帳號可排序（需先執行階段 E；可重複執行）
alter table public.profiles add column if not exists sort_order int not null default 1000000;
grant select (sort_order) on public.profiles to authenticated;

-- 登入前的老師名單：依管理者排的順序
create or replace function public.list_teachers()
returns table(login_id text, display_name text, class_id text, class_name text)
language sql stable security definer set search_path = '' as $$
  select p.login_id, coalesce(p.display_name, p.login_id), p.class_id, c.name
    from public.profiles p left join public.classes c on c.id = p.class_id
   where p.role = 'teacher' and p.login_id is not null
   order by p.sort_order, p.created_at, p.login_id
$$;
revoke all on function public.list_teachers() from public;
grant execute on function public.list_teachers() to anon, authenticated;

-- 管理者一次存下老師的新順序（依傳入的 id 順序）
create or replace function public.admin_reorder_teachers(p_ids uuid[])
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not (select private.is_admin()) then raise exception 'admin only' using errcode = '42501'; end if;
  update public.profiles p set sort_order = t.ord
    from unnest(p_ids) with ordinality as t(id, ord)
   where p.id = t.id and p.role = 'teacher';
end $$;
revoke all on function public.admin_reorder_teachers(uuid[]) from public, anon;
grant execute on function public.admin_reorder_teachers(uuid[]) to authenticated;
-- 基翔小學通 Supabase 測試專案：階段 G 老師可限制年級、管理者換年級頭像
-- 需先執行階段 E（可重複執行）
alter table public.profiles add column if not exists allowed_grades text[];
grant select (allowed_grades) on public.profiles to authenticated;

-- 目前登入的老師可不可以使用這個年級（沒設限制＝全部可以）
create or replace function private.teacher_grade_ok(p_grade text)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((
    select p.allowed_grades is null or cardinality(p.allowed_grades) = 0 or p_grade = any(p.allowed_grades)
      from public.profiles p where p.id = (select auth.uid()) and p.role = 'teacher'
  ), true)
$$;
revoke all on function private.teacher_grade_ok(text) from public, anon;
grant execute on function private.teacher_grade_ok(text) to authenticated;

-- 新增學生、或把學生改成不被允許的年級 → 擋下
create or replace function private.students_grade_guard()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and new.grade is not distinct from old.grade then return new; end if;
  if not private.teacher_grade_ok(new.grade) then
    raise exception 'grade not allowed for this teacher: %', new.grade;
  end if;
  return new;
end $$;
drop trigger if exists students_grade_guard on public.students;
create trigger students_grade_guard before insert or update on public.students
  for each row execute function private.students_grade_guard();

-- 加入現有學生：不被允許的年級不能加
create or replace function public.teacher_add_students_to_class(p_ids text[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_class text := (select private.my_class_id()); v_n int;
begin
  if not (select private.is_teacher()) or v_class is null then
    raise exception 'only teachers can add students' using errcode = '42501';
  end if;
  if p_ids is null or cardinality(p_ids) = 0 or cardinality(p_ids) > 200 then
    raise exception 'ids must contain 1 to 200 items' using errcode = '22023';
  end if;
  if exists (select 1 from public.students s where s.id = any(p_ids) and not private.teacher_grade_ok(s.grade)) then
    raise exception 'grade not allowed for this teacher';
  end if;
  insert into public.class_students (class_id, student_id)
  select v_class, s.id from public.students s where s.id = any(p_ids)
  on conflict do nothing;
  get diagnostics v_n = row_count;
  return jsonb_build_object('added', v_n);
end $$;

-- 管理者設定老師可用的年級（空陣列＝不限制）
create or replace function public.admin_set_teacher_grades(p_id uuid, p_grades text[])
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not (select private.is_admin()) then raise exception 'admin only' using errcode = '42501'; end if;
  if not exists (select 1 from public.profiles where id = p_id and role = 'teacher') then
    raise exception 'teacher not found' using errcode = '22023';
  end if;
  if p_grades is not null and exists (select 1 from unnest(p_grades) g where not exists (select 1 from public.grades x where x.name = g)) then
    raise exception 'unknown grade' using errcode = '22023';
  end if;
  update public.profiles set allowed_grades = case when p_grades is null or cardinality(p_grades) = 0 then null else p_grades end where id = p_id;
end $$;
revoke all on function public.admin_set_teacher_grades(uuid, text[]) from public, anon;
grant execute on function public.admin_set_teacher_grades(uuid, text[]) to authenticated;

-- 管理者換年級頭像：該年級現有學生的頭像一起換
create or replace function public.admin_set_grade_avatar(p_grade text, p_avatar text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not (select private.is_admin()) then raise exception 'admin only' using errcode = '42501'; end if;
  if p_avatar is null or btrim(p_avatar) = '' then raise exception 'avatar required' using errcode = '22023'; end if;
  update public.grades set avatar = p_avatar where name = p_grade;
  update public.students set avatar = p_avatar where grade = p_grade;
end $$;
revoke all on function public.admin_set_grade_avatar(text, text) from public, anon;
grant execute on function public.admin_set_grade_avatar(text, text) to authenticated;
-- 基翔小學通 Supabase 測試專案：階段 H 輕量資料版本（省流量）
-- 需先執行階段 E、F、G（可重複執行）。
-- 輪詢時只問這個函式（回傳一段很短的指紋），資料沒變就不必重抓整份資料。
-- 以呼叫者身分執行，所以各人只會算到自己看得到的資料（學生不會被別人的資料影響）。
create or replace function public.get_data_version()
returns text language sql stable security invoker set search_path = '' as $$
  select md5(concat_ws('|',
    (select coalesce(md5(string_agg(concat_ws(',', id, class_id, student_id, type, subject, title, date::text, student_checked::text,
        pending_review::text, teacher_status, submitted_at::text, done_at::text, reviewed_at::text), ';' order by id)), '') from public.tasks),
    (select coalesce(md5(string_agg(concat_ws(',', id, class_id, date::text, weekday, content, items::text), ';' order by id)), '') from public.get_contact_book()),
    (select coalesce(md5(string_agg(concat_ws(',', id, name, school, grade, class_name, avatar), ';' order by id)), '') from public.students),
    (select coalesce(md5(string_agg(class_id || ',' || student_id, ';' order by class_id, student_id)), '') from public.class_students),
    (select coalesce(md5(string_agg(id || ',' || name || ',' || sort_order::text, ';' order by id)), '') from public.classes),
    (select coalesce(md5(string_agg(name || ',' || avatar || ',' || sort_order::text, ';' order by name)), '') from public.grades),
    (select coalesce(md5(string_agg(name || ',' || sort_order::text, ';' order by name)), '') from public.subjects),
    (select coalesce(count(*)::text || ':' || max(id)::text, '') from public.submit_log),
    (select coalesce(md5(string_agg(concat_ws(',', id::text, login_id, display_name, class_id, sort_order::text, array_to_string(allowed_grades, '/')), ';' order by id)), '') from public.profiles)
  ))
$$;
revoke all on function public.get_data_version() from public, anon;
grant execute on function public.get_data_version() to authenticated;
