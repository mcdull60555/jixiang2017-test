-- ============================================================
-- 基翔小學通 正式專案（jixiang-production）：建立資料庫結構
-- 用法：Supabase 後台 → 選 jixiang-production 專案 → SQL Editor → 貼上整份 → Run
-- 內容與測試專案相同（已含多班級、登入閘門、7 天清理、年級鎖定、資料指紋、備份）。
-- 只能在「全新、空白」的專案執行一次。
-- ============================================================

create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_cron;

create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

-- ---------- 資料表 ----------
create table public.grades (name text not null, avatar text default '🦔'::text not null, sort_order integer default 0 not null);
create table public.subjects (name text not null, sort_order integer default 0 not null);
create table public.classes (id text default ('c_'::text || replace((gen_random_uuid())::text, '-'::text, ''::text)) not null, name text not null, sort_order integer default 0 not null, created_at timestamp with time zone default now() not null);
create table public.students (id text default ('s_'::text || replace((gen_random_uuid())::text, '-'::text, ''::text)) not null, name text not null, school text not null, grade text not null, class_name text default ''::text not null, avatar text default ''::text not null, auth_user_id uuid, created_at timestamp with time zone default now() not null);
create table public.class_students (class_id text not null, student_id text not null);
create table public.profiles (id uuid not null, role text not null, student_id text, created_at timestamp with time zone default now() not null, class_id text, login_id text, display_name text, sort_order integer default 1000000 not null, allowed_grades text[]);
create table public.tasks (id text default ('t_'::text || replace((gen_random_uuid())::text, '-'::text, ''::text)) not null, student_id text not null, type text not null, subject text not null, title text not null, date date not null, student_checked boolean default false not null, pending_review boolean default false not null, teacher_status text default '未完成'::text not null, submitted_at timestamp with time zone, done_at timestamp with time zone, reviewed_at timestamp with time zone, created_at timestamp with time zone default now() not null, class_id text not null);
create table public.contact_book (id text default ('cb_'::text || replace((gen_random_uuid())::text, '-'::text, ''::text)) not null, date date not null, weekday text default ''::text not null, content text default ''::text not null, items jsonb default '[]'::jsonb not null, created_at timestamp with time zone default now() not null, class_id text not null);
create table public.submit_log (id bigint generated always as identity not null, at timestamp with time zone default now() not null, action text not null, task_id text not null, student_id text, student_name text default ''::text not null, type text, subject text, title text, date date, status text, class_id text);
create table private.login_pins (user_id uuid not null, pin_hash text not null, failed_count integer default 0 not null, last_failed_at timestamp with time zone, locked_until timestamp with time zone);

alter table public.classes add constraint classes_pkey PRIMARY KEY (id);
alter table public.class_students add constraint class_students_pkey PRIMARY KEY (class_id, student_id);
alter table public.grades add constraint grades_pkey PRIMARY KEY (name);
alter table public.subjects add constraint subjects_pkey PRIMARY KEY (name);
alter table public.students add constraint students_pkey PRIMARY KEY (id);
alter table public.profiles add constraint profiles_pkey PRIMARY KEY (id);
alter table public.tasks add constraint tasks_pkey PRIMARY KEY (id);
alter table public.contact_book add constraint contact_book_pkey PRIMARY KEY (id);
alter table public.submit_log add constraint submit_log_pkey PRIMARY KEY (id);
alter table private.login_pins add constraint login_pins_pkey PRIMARY KEY (user_id);
alter table public.tasks add constraint tasks_student_class_type_subject_title_date_key UNIQUE (student_id, class_id, type, subject, title, date);
alter table public.classes add constraint classes_name_key UNIQUE (name);
alter table public.students add constraint students_auth_user_id_key UNIQUE (auth_user_id);
alter table public.profiles add constraint profiles_student_id_key UNIQUE (student_id);
alter table public.tasks add constraint tasks_student_id_fkey FOREIGN KEY (student_id) REFERENCES public.students(id) ON DELETE CASCADE;
alter table public.tasks add constraint tasks_subject_fkey FOREIGN KEY (subject) REFERENCES public.subjects(name) ON UPDATE CASCADE ON DELETE CASCADE;
alter table public.profiles add constraint profiles_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;
alter table public.profiles add constraint profiles_class_id_fkey FOREIGN KEY (class_id) REFERENCES public.classes(id) ON DELETE SET NULL;
alter table private.login_pins add constraint login_pins_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
alter table public.class_students add constraint class_students_student_id_fkey FOREIGN KEY (student_id) REFERENCES public.students(id) ON DELETE CASCADE;
alter table public.students add constraint students_grade_fkey FOREIGN KEY (grade) REFERENCES public.grades(name) ON UPDATE CASCADE ON DELETE RESTRICT;
alter table public.students add constraint students_auth_user_id_fkey FOREIGN KEY (auth_user_id) REFERENCES auth.users(id) ON DELETE SET NULL;
alter table public.class_students add constraint class_students_class_id_fkey FOREIGN KEY (class_id) REFERENCES public.classes(id) ON DELETE CASCADE;
alter table public.tasks add constraint tasks_class_id_fkey FOREIGN KEY (class_id) REFERENCES public.classes(id) ON DELETE CASCADE;
alter table public.profiles add constraint profiles_student_id_fkey FOREIGN KEY (student_id) REFERENCES public.students(id) ON DELETE CASCADE;
alter table public.submit_log add constraint submit_log_class_id_fkey FOREIGN KEY (class_id) REFERENCES public.classes(id) ON DELETE CASCADE;
alter table public.contact_book add constraint contact_book_class_id_fkey FOREIGN KEY (class_id) REFERENCES public.classes(id) ON DELETE CASCADE;
alter table public.classes add constraint classes_name_check CHECK ((length(btrim(name)) > 0));
alter table public.students add constraint students_name_check CHECK ((length(btrim(name)) > 0));
alter table public.students add constraint students_school_check CHECK ((length(btrim(school)) > 0));
alter table public.tasks add constraint tasks_type_check CHECK ((type = ANY (ARRAY['作業'::text, '考卷'::text])));
alter table public.tasks add constraint tasks_title_check CHECK ((length(btrim(title)) > 0));
alter table public.tasks add constraint tasks_teacher_status_check CHECK ((teacher_status = ANY (ARRAY['未完成'::text, '待訂正'::text, '已完成'::text])));
alter table public.profiles add constraint profiles_role_check CHECK ((role = ANY (ARRAY['teacher'::text, 'student'::text, 'admin'::text])));
alter table public.contact_book add constraint contact_book_items_check CHECK (((jsonb_typeof(items) = 'array'::text) AND (jsonb_array_length(items) > 0)));
alter table public.submit_log add constraint submit_log_action_check CHECK ((action = ANY (ARRAY['submit'::text, 'withdraw'::text, 'review'::text])));
alter table public.profiles add constraint profiles_check CHECK ((((role = ANY (ARRAY['teacher'::text, 'admin'::text])) AND (student_id IS NULL)) OR ((role = 'student'::text) AND (student_id IS NOT NULL))));
CREATE INDEX class_students_student_idx ON public.class_students USING btree (student_id);
CREATE INDEX tasks_date_idx ON public.tasks USING btree (date);
CREATE INDEX contact_book_class_idx ON public.contact_book USING btree (class_id);
CREATE INDEX contact_book_date_idx ON public.contact_book USING btree (date);
CREATE INDEX tasks_subject_idx ON public.tasks USING btree (subject);
CREATE INDEX submit_log_at_idx ON public.submit_log USING btree (at);
CREATE INDEX tasks_class_idx ON public.tasks USING btree (class_id);
CREATE INDEX students_grade_idx ON public.students USING btree (grade);
CREATE UNIQUE INDEX profiles_login_id_key ON public.profiles USING btree (login_id) WHERE (login_id IS NOT NULL);

-- ---------- private 輔助函式 ----------
CREATE OR REPLACE FUNCTION private.is_admin()
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
  select exists (select 1 from public.profiles p where p.id = (select auth.uid()) and p.role = 'admin')
$function$;

CREATE OR REPLACE FUNCTION private.is_teacher()
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
  select exists (select 1 from public.profiles p where p.id = (select auth.uid()) and p.role = 'teacher')
$function$;

CREATE OR REPLACE FUNCTION private.my_class_id()
 RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
  select p.class_id from public.profiles p where p.id = (select auth.uid()) and p.role = 'teacher'
$function$;

CREATE OR REPLACE FUNCTION private.my_student_id()
 RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
  select p.student_id from public.profiles p where p.id = (select auth.uid()) and p.role = 'student'
$function$;

CREATE OR REPLACE FUNCTION private.teacher_grade_ok(p_grade text)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
  select coalesce((
    select p.allowed_grades is null or cardinality(p.allowed_grades) = 0 or p_grade = any(p.allowed_grades)
      from public.profiles p where p.id = (select auth.uid()) and p.role = 'teacher'
  ), true)
$function$;

CREATE OR REPLACE FUNCTION private.set_pin(p_uid uuid, p_pin text)
 RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path TO ''
AS $function$
  insert into private.login_pins (user_id, pin_hash)
  values (p_uid, extensions.crypt('jx' || p_pin, extensions.gen_salt('bf')))
  on conflict (user_id) do update
    set pin_hash = excluded.pin_hash, failed_count = 0, last_failed_at = null, locked_until = null
$function$;

CREATE OR REPLACE FUNCTION private.create_auth_user(p_email text)
 RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION private.students_grade_guard()
 RETURNS trigger LANGUAGE plpgsql SET search_path TO ''
AS $function$
begin
  if tg_op = 'UPDATE' and new.grade is not distinct from old.grade then return new; end if;
  if not private.teacher_grade_ok(new.grade) then
    raise exception 'grade not allowed for this teacher: %', new.grade;
  end if;
  return new;
end $function$;

CREATE OR REPLACE FUNCTION private.cleanup_old_records()
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
declare
  v_log int; v_cap int; v_cb int; v_task int;
  v_today date := (now() at time zone 'Asia/Taipei')::date;
begin
  delete from public.submit_log where at < now() - interval '7 days';
  get diagnostics v_log = row_count;
  delete from public.submit_log
   where id in (select id from public.submit_log order by at desc, id desc offset 1000);
  get diagnostics v_cap = row_count;
  delete from public.contact_book where date < v_today - 7;
  get diagnostics v_cb = row_count;
  -- 歸檔項目：同一班、同一項（類型／科目／名稱／派發日）所有學生都已完成，且派發日超過 7 天
  delete from public.tasks t
   using (select class_id, type, subject, title, date from public.tasks
           group by class_id, type, subject, title, date
          having bool_and(teacher_status = '已完成') and date < v_today - 7) a
   where t.class_id = a.class_id and t.type = a.type and t.subject = a.subject and t.title = a.title and t.date = a.date;
  get diagnostics v_task = row_count;
  return jsonb_build_object('submit_log_old', v_log, 'submit_log_over_cap', v_cap, 'contact_book', v_cb, 'archived_tasks', v_task);
end $function$;

CREATE TRIGGER students_grade_guard BEFORE INSERT OR UPDATE ON public.students FOR EACH ROW EXECUTE FUNCTION private.students_grade_guard();

-- ---------- 登入 ----------
CREATE OR REPLACE FUNCTION public.login_attempt(p_email text, p_pin text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
declare
  v_uid uuid;
  v_row private.login_pins%rowtype;
  v_n int;
  v_wait int;
begin
  if p_email is null or p_pin is null or length(p_pin) > 64 then
    return jsonb_build_object('status', 'denied');
  end if;

  select id into v_uid from auth.users where email = lower(p_email);
  if v_uid is null then
    perform extensions.crypt('jx' || p_pin, extensions.gen_salt('bf'));
    return jsonb_build_object('status', 'denied');
  end if;

  select * into v_row from private.login_pins where user_id = v_uid for update;
  if not found then
    return jsonb_build_object('status', 'denied');
  end if;

  if v_row.locked_until is not null and v_row.locked_until > now() then
    v_wait := ceil(extract(epoch from (v_row.locked_until - now())))::int;
    return jsonb_build_object('status', 'locked', 'retry_after', v_wait);
  end if;

  if v_row.pin_hash = extensions.crypt('jx' || p_pin, v_row.pin_hash) then
    update private.login_pins
       set failed_count = 0, last_failed_at = null, locked_until = null
     where user_id = v_uid;
    return jsonb_build_object('status', 'ok', 'user_id', v_uid);
  end if;

  if v_row.locked_until is not null
     or v_row.last_failed_at is null
     or v_row.last_failed_at < now() - interval '15 minutes' then
    v_n := 1;
  else
    v_n := v_row.failed_count + 1;
  end if;

  if v_n >= 3 then
    update private.login_pins
       set failed_count = v_n, last_failed_at = now(), locked_until = now() + interval '1 minute'
     where user_id = v_uid;
    return jsonb_build_object('status', 'locked', 'retry_after', 60);
  end if;

  update private.login_pins
     set failed_count = v_n, last_failed_at = now(), locked_until = null
   where user_id = v_uid;
  return jsonb_build_object('status', 'denied', 'remaining', 3 - v_n);
end $function$;

CREATE OR REPLACE FUNCTION public.change_my_pin(p_pin text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION public.list_teachers()
 RETURNS TABLE(login_id text, display_name text, class_id text, class_name text)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
  select p.login_id, coalesce(p.display_name, p.login_id), p.class_id, c.name
    from public.profiles p left join public.classes c on c.id = p.class_id
   where p.role = 'teacher' and p.login_id is not null
   order by p.sort_order, p.created_at, p.login_id
$function$;

-- ---------- 學生 ----------
CREATE OR REPLACE FUNCTION public.student_submit(p_ids text[])
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION public.student_withdraw(p_ids text[])
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
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
end $function$;

-- ---------- 老師 ----------
CREATE OR REPLACE FUNCTION public.teacher_review(p_ids text[], p_status text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
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
end $function$;

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

CREATE OR REPLACE FUNCTION public.teacher_add_students_to_class(p_ids text[])
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
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
end $function$;

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

-- ---------- 聯絡簿、跑馬燈、資料指紋、備份 ----------
CREATE OR REPLACE FUNCTION public.get_contact_book()
 RETURNS TABLE(id text, class_id text, date date, weekday text, content text, items jsonb)
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION public.get_champions()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION public.get_data_version()
 RETURNS text LANGUAGE sql STABLE SET search_path TO ''
AS $function$
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
$function$;

-- ---------- 管理者 ----------
CREATE OR REPLACE FUNCTION public.admin_create_teacher(p_login text, p_name text, p_pin text, p_class text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION public.admin_update_teacher(p_id uuid, p_name text, p_class text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
begin
  if not (select private.is_admin()) then raise exception 'admin only' using errcode = '42501'; end if;
  if btrim(coalesce(p_name, '')) = '' then raise exception 'name required' using errcode = '22023'; end if;
  if p_class is not null and not exists (select 1 from public.classes where id = p_class) then
    raise exception 'class not found' using errcode = '22023';
  end if;
  update public.profiles set display_name = btrim(p_name), class_id = p_class where id = p_id and role = 'teacher';
end $function$;

CREATE OR REPLACE FUNCTION public.admin_set_teacher_pin(p_id uuid, p_pin text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
begin
  if not (select private.is_admin()) then raise exception 'admin only' using errcode = '42501'; end if;
  if p_pin is null or length(p_pin) < 4 or length(p_pin) > 64 then
    raise exception 'password must be 4 to 64 characters' using errcode = '22023';
  end if;
  if not exists (select 1 from public.profiles where id = p_id and role = 'teacher') then
    raise exception 'teacher not found' using errcode = '22023';
  end if;
  perform private.set_pin(p_id, p_pin);
end $function$;

CREATE OR REPLACE FUNCTION public.admin_delete_teacher(p_id uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
begin
  if not (select private.is_admin()) then raise exception 'admin only' using errcode = '42501'; end if;
  if not exists (select 1 from public.profiles where id = p_id and role = 'teacher') then
    raise exception 'teacher not found' using errcode = '22023';
  end if;
  delete from auth.users where id = p_id;
end $function$;

CREATE OR REPLACE FUNCTION public.admin_reorder_teachers(p_ids uuid[])
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
begin
  if not (select private.is_admin()) then raise exception 'admin only' using errcode = '42501'; end if;
  update public.profiles p set sort_order = t.ord
    from unnest(p_ids) with ordinality as t(id, ord)
   where p.id = t.id and p.role = 'teacher';
end $function$;

CREATE OR REPLACE FUNCTION public.admin_set_grade_avatar(p_grade text, p_avatar text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
begin
  if not (select private.is_admin()) then raise exception 'admin only' using errcode = '42501'; end if;
  if p_avatar is null or btrim(p_avatar) = '' then raise exception 'avatar required' using errcode = '22023'; end if;
  update public.grades set avatar = p_avatar where name = p_grade;
  update public.students set avatar = p_avatar where grade = p_grade;
end $function$;

CREATE OR REPLACE FUNCTION public.admin_set_teacher_grades(p_id uuid, p_grades text[])
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
begin
  if not (select private.is_admin()) then raise exception 'admin only' using errcode = '42501'; end if;
  if not exists (select 1 from public.profiles where id = p_id and role = 'teacher') then
    raise exception 'teacher not found' using errcode = '22023';
  end if;
  if p_grades is not null and exists (select 1 from unnest(p_grades) g where not exists (select 1 from public.grades x where x.name = g)) then
    raise exception 'unknown grade' using errcode = '22023';
  end if;
  update public.profiles set allowed_grades = case when p_grades is null or cardinality(p_grades) = 0 then null else p_grades end where id = p_id;
end $function$;

create or replace function public.backup_data()
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_role text;
  v_class text;
  v_out jsonb;
begin
  select p.role, p.class_id into v_role, v_class
    from public.profiles p where p.id = auth.uid();

  if v_role = 'admin' then
    v_out := jsonb_build_object(
      'scope', 'all',
      'grades',         coalesce((select jsonb_agg(to_jsonb(x) order by x.sort_order) from public.grades x), '[]'),
      'subjects',       coalesce((select jsonb_agg(to_jsonb(x) order by x.sort_order) from public.subjects x), '[]'),
      'classes',        coalesce((select jsonb_agg(to_jsonb(x) order by x.sort_order) from public.classes x), '[]'),
      'profiles',       coalesce((select jsonb_agg(to_jsonb(x) order by x.role, x.sort_order) from public.profiles x), '[]'),
      'students',       coalesce((select jsonb_agg(to_jsonb(x) order by x.id) from public.students x), '[]'),
      'class_students', coalesce((select jsonb_agg(to_jsonb(x)) from public.class_students x), '[]'),
      'tasks',          coalesce((select jsonb_agg(to_jsonb(x) order by x.class_id, x.date, x.id) from public.tasks x), '[]'),
      'contact_book',   coalesce((select jsonb_agg(to_jsonb(x) order by x.class_id, x.date) from public.contact_book x), '[]'),
      'submit_log',     coalesce((select jsonb_agg(to_jsonb(x) order by x.at) from public.submit_log x), '[]')
    );
  elsif v_role = 'teacher' then
    if v_class is null then
      raise exception 'teacher has no class';
    end if;
    v_out := jsonb_build_object(
      'scope', 'class',
      'grades',         coalesce((select jsonb_agg(to_jsonb(x) order by x.sort_order) from public.grades x), '[]'),
      'subjects',       coalesce((select jsonb_agg(to_jsonb(x) order by x.sort_order) from public.subjects x), '[]'),
      'classes',        coalesce((select jsonb_agg(to_jsonb(x)) from public.classes x where x.id = v_class), '[]'),
      'students',       coalesce((select jsonb_agg(to_jsonb(s) order by s.id) from public.students s
                                  where s.id in (select cs.student_id from public.class_students cs where cs.class_id = v_class)), '[]'),
      'class_students', coalesce((select jsonb_agg(to_jsonb(x)) from public.class_students x where x.class_id = v_class), '[]'),
      'tasks',          coalesce((select jsonb_agg(to_jsonb(x) order by x.date, x.id) from public.tasks x where x.class_id = v_class), '[]'),
      'contact_book',   coalesce((select jsonb_agg(to_jsonb(x) order by x.date) from public.contact_book x where x.class_id = v_class), '[]'),
      'submit_log',     coalesce((select jsonb_agg(to_jsonb(x) order by x.at) from public.submit_log x where x.class_id = v_class), '[]')
    );
  else
    raise exception 'not allowed';
  end if;

  return jsonb_build_object(
    'app', '基翔小學通',
    'format', 1,
    'created_at', now(),
    'role', v_role
  ) || v_out;
end $$;

-- ---------- RLS ----------
alter table public.tasks enable row level security;
alter table public.contact_book enable row level security;
alter table public.grades enable row level security;
alter table public.subjects enable row level security;
alter table public.students enable row level security;
alter table public.profiles enable row level security;
alter table public.submit_log enable row level security;
alter table public.classes enable row level security;
alter table public.class_students enable row level security;
alter table private.login_pins enable row level security;

create policy grades_select on public.grades as PERMISSIVE for SELECT to anon, authenticated using (true);
create policy grades_insert on public.grades as PERMISSIVE for INSERT to authenticated with check (( SELECT private.is_admin() AS is_admin));
create policy grades_update on public.grades as PERMISSIVE for UPDATE to authenticated using (( SELECT private.is_admin() AS is_admin)) with check (( SELECT private.is_admin() AS is_admin));
create policy grades_delete on public.grades as PERMISSIVE for DELETE to authenticated using (( SELECT private.is_admin() AS is_admin));
create policy subjects_select on public.subjects as PERMISSIVE for SELECT to anon, authenticated using (true);
create policy subjects_insert on public.subjects as PERMISSIVE for INSERT to authenticated with check (( SELECT private.is_admin() AS is_admin));
create policy subjects_update on public.subjects as PERMISSIVE for UPDATE to authenticated using (( SELECT private.is_admin() AS is_admin)) with check (( SELECT private.is_admin() AS is_admin));
create policy subjects_delete on public.subjects as PERMISSIVE for DELETE to authenticated using (( SELECT private.is_admin() AS is_admin));
create policy classes_select on public.classes as PERMISSIVE for SELECT to anon, authenticated using (true);
create policy classes_insert on public.classes as PERMISSIVE for INSERT to authenticated with check (( SELECT private.is_admin() AS is_admin));
create policy classes_update on public.classes as PERMISSIVE for UPDATE to authenticated using (( SELECT private.is_admin() AS is_admin)) with check (( SELECT private.is_admin() AS is_admin));
create policy classes_delete on public.classes as PERMISSIVE for DELETE to authenticated using (( SELECT private.is_admin() AS is_admin));
create policy class_students_select on public.class_students as PERMISSIVE for SELECT to anon, authenticated using (true);
create policy profiles_select on public.profiles as PERMISSIVE for SELECT to authenticated using (((id = ( SELECT auth.uid() AS uid)) OR ( SELECT private.is_admin() AS is_admin)));
create policy students_select_anon on public.students as PERMISSIVE for SELECT to anon using (true);
create policy students_select_auth on public.students as PERMISSIVE for SELECT to authenticated using (((id = ( SELECT private.my_student_id() AS my_student_id)) OR (EXISTS ( SELECT 1
   FROM public.class_students cs
  WHERE ((cs.student_id = students.id) AND (cs.class_id = ( SELECT private.my_class_id() AS my_class_id)))))));
create policy students_update on public.students as PERMISSIVE for UPDATE to authenticated using ((( SELECT private.is_teacher() AS is_teacher) AND (EXISTS ( SELECT 1
   FROM public.class_students cs
  WHERE ((cs.student_id = students.id) AND (cs.class_id = ( SELECT private.my_class_id() AS my_class_id))))))) with check ((( SELECT private.is_teacher() AS is_teacher) AND (EXISTS ( SELECT 1
   FROM public.class_students cs
  WHERE ((cs.student_id = students.id) AND (cs.class_id = ( SELECT private.my_class_id() AS my_class_id)))))));
create policy tasks_select on public.tasks as PERMISSIVE for SELECT to authenticated using (((class_id = ( SELECT private.my_class_id() AS my_class_id)) OR ((student_id = ( SELECT private.my_student_id() AS my_student_id)) AND (date <= ((now() AT TIME ZONE 'Asia/Taipei'::text))::date))));
create policy tasks_insert on public.tasks as PERMISSIVE for INSERT to authenticated with check ((( SELECT private.is_teacher() AS is_teacher) AND (class_id = ( SELECT private.my_class_id() AS my_class_id)) AND (EXISTS ( SELECT 1
   FROM public.class_students cs
  WHERE ((cs.student_id = tasks.student_id) AND (cs.class_id = tasks.class_id))))));
create policy tasks_update on public.tasks as PERMISSIVE for UPDATE to authenticated using ((( SELECT private.is_teacher() AS is_teacher) AND (class_id = ( SELECT private.my_class_id() AS my_class_id)))) with check ((( SELECT private.is_teacher() AS is_teacher) AND (class_id = ( SELECT private.my_class_id() AS my_class_id))));
create policy tasks_delete on public.tasks as PERMISSIVE for DELETE to authenticated using ((( SELECT private.is_teacher() AS is_teacher) AND (class_id = ( SELECT private.my_class_id() AS my_class_id))));
create policy contact_book_select on public.contact_book as PERMISSIVE for SELECT to authenticated using ((( SELECT private.is_teacher() AS is_teacher) AND (class_id = ( SELECT private.my_class_id() AS my_class_id))));
create policy contact_book_insert on public.contact_book as PERMISSIVE for INSERT to authenticated with check ((( SELECT private.is_teacher() AS is_teacher) AND (class_id = ( SELECT private.my_class_id() AS my_class_id))));
create policy contact_book_update on public.contact_book as PERMISSIVE for UPDATE to authenticated using ((( SELECT private.is_teacher() AS is_teacher) AND (class_id = ( SELECT private.my_class_id() AS my_class_id)))) with check ((( SELECT private.is_teacher() AS is_teacher) AND (class_id = ( SELECT private.my_class_id() AS my_class_id))));
create policy contact_book_delete on public.contact_book as PERMISSIVE for DELETE to authenticated using ((( SELECT private.is_teacher() AS is_teacher) AND (class_id = ( SELECT private.my_class_id() AS my_class_id))));
create policy submit_log_select on public.submit_log as PERMISSIVE for SELECT to authenticated using ((( SELECT private.is_teacher() AS is_teacher) AND (class_id = ( SELECT private.my_class_id() AS my_class_id))));

-- ---------- 權限（先全部收回，再逐項開放，與測試專案相同） ----------
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;
revoke all on all functions in schema private from public, anon, authenticated;
revoke all on all tables in schema private from anon, authenticated;

grant select, delete on public.tasks to authenticated;
grant insert (id, student_id, type, subject, title, date, class_id) on public.tasks to authenticated;
grant update (type, subject, title, date) on public.tasks to authenticated;
grant select, insert, update, delete on public.contact_book to authenticated;
grant select on public.grades to anon;
grant select, insert, update, delete on public.grades to authenticated;
grant select on public.subjects to anon;
grant select, insert, update, delete on public.subjects to authenticated;
grant select, insert, update, delete on public.students to authenticated;
grant select (id, name, school, grade, class_name) on public.students to anon;
grant select on public.profiles to authenticated;
grant select on public.submit_log to authenticated;
grant delete on public.classes to authenticated;
grant select (id, name, sort_order) on public.classes to anon;
grant select (id) , insert (id) on public.classes to authenticated;
grant select (name, sort_order), insert (name, sort_order), update (name, sort_order) on public.classes to authenticated;
grant select (class_id, student_id) on public.class_students to anon, authenticated;

grant execute on function private.is_admin(), private.is_teacher(), private.my_class_id(), private.my_student_id(), private.teacher_grade_ok(text) to authenticated;
grant execute on function public.login_attempt(text, text) to service_role;
grant execute on function public.list_teachers() to anon, authenticated, service_role;
grant execute on function
  public.change_my_pin(text), public.student_submit(text[]), public.student_withdraw(text[]),
  public.teacher_review(text[], text), public.teacher_update_tasks(jsonb), public.teacher_create_students(jsonb),
  public.teacher_add_students_to_class(text[]), public.teacher_delete_students(text[]), public.teacher_set_student_passwords(jsonb),
  public.get_contact_book(), public.get_champions(), public.get_data_version(), public.backup_data(),
  public.admin_create_teacher(text, text, text, text), public.admin_update_teacher(uuid, text, text),
  public.admin_set_teacher_pin(uuid, text), public.admin_delete_teacher(uuid), public.admin_reorder_teachers(uuid[]),
  public.admin_set_grade_avatar(text, text), public.admin_set_teacher_grades(uuid, text[])
to authenticated, service_role;

-- 之後新建的資料表與函式預設不開放給 anon/authenticated
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on functions from public, anon, authenticated;

-- ---------- 每日清理（台灣時間凌晨 3:00） ----------
select cron.schedule('jixiang-daily-cleanup', '0 19 * * *', 'select private.cleanup_old_records()');

-- ===== 階段 J：預約項目 05:00 生效、聯絡簿 7 天（2026-10-16 加入） =====
-- 基翔小學通：階段 J（同步正式版 2026-10-15 的改動）
-- 1. 預約派發的項目在發布日期當天凌晨 05:00（台灣時間）才生效：學生看得到、能送審、計入跑馬燈
-- 2. 聯絡簿顯示範圍改為過去 7 天（與每日清理一致）
-- 用法：SQL Editor 貼上 → Run（測試專案、正式專案都要跑；可重複執行）

-- 學生只看得到「已生效」的項目
alter policy tasks_select on public.tasks
  using (((class_id = ( SELECT private.my_class_id() AS my_class_id))
          OR ((student_id = ( SELECT private.my_student_id() AS my_student_id))
              AND (date <= (((now() AT TIME ZONE 'Asia/Taipei'::text) - interval '5 hours'))::date))));

CREATE OR REPLACE FUNCTION public.student_submit(p_ids text[])
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
declare
  v_sid text := (select private.my_student_id());
  v_today date := ((now() at time zone 'Asia/Taipei') - interval '5 hours')::date;  -- 生效日（05:00 換日）
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
end $function$;

CREATE OR REPLACE FUNCTION public.get_champions()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
declare
  v_today date := (now() at time zone 'Asia/Taipei')::date;
  v_active date := ((now() at time zone 'Asia/Taipei') - interval '5 hours')::date;  -- 項目生效日（05:00 換日）
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
         where t.class_id = any(v_classes) and t.date between v_start and v_end and t.date <= v_active
         group by s.id, s.name, s.school, s.grade, s.avatar
        having bool_and(t.teacher_status = '已完成')
      ) c
  ), '[]'::jsonb));
end $function$;

-- 聯絡簿：顯示今天起往前 7 天（超過 7 天的每日清理會刪除）
CREATE OR REPLACE FUNCTION public.get_contact_book()
 RETURNS TABLE(id text, class_id text, date date, weekday text, content text, items jsonb)
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
declare
  v_student public.students%rowtype;
  v_today date := (now() at time zone 'Asia/Taipei')::date;
begin
  if (select private.is_teacher()) then
    return query
      select cb.id, cb.class_id, cb.date, cb.weekday, cb.content, cb.items
        from public.contact_book cb
       where cb.class_id = (select private.my_class_id()) and cb.date >= v_today - 7
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
         where cb.date >= v_today - 7
           and cb.class_id in (select cs.class_id from public.class_students cs where cs.student_id = v_student.id)
      ) f
     where jsonb_array_length(f.items) > 0
     order by f.date, f.id;
end $function$;

-- ===== 階段 K：一位老師負責多個班級（2026-10-16 加入） =====
-- 基翔學習通：階段 K　一位老師可以負責多個班級
-- 做法：teacher_classes 記錄老師負責哪些班；profiles.class_id 當作「目前正在看的班」。
--       老師在畫面上切換班級時，只改 profiles.class_id，其餘權限與函式完全沿用（都以目前的班為準）。
-- 用法：SQL Editor 貼上 → Run（可重複執行）

create table if not exists public.teacher_classes (
  teacher_id uuid not null references public.profiles(id) on delete cascade,
  class_id   text not null references public.classes(id) on delete cascade,
  primary key (teacher_id, class_id)
);
create index if not exists teacher_classes_class_idx on public.teacher_classes (class_id);

-- 既有老師：把現在的班級放進去
insert into public.teacher_classes (teacher_id, class_id)
select p.id, p.class_id from public.profiles p
 where p.role = 'teacher' and p.class_id is not null
on conflict do nothing;

alter table public.teacher_classes enable row level security;
drop policy if exists teacher_classes_select on public.teacher_classes;
create policy teacher_classes_select on public.teacher_classes for select to authenticated
  using (teacher_id = (select auth.uid()) or (select private.is_admin()));
revoke all on public.teacher_classes from anon, authenticated;
grant select on public.teacher_classes to authenticated;

-- 老師切換目前的班級（只能切到自己負責的班）
create or replace function public.teacher_switch_class(p_class text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not (select private.is_teacher()) then raise exception 'only teachers can switch class' using errcode = '42501'; end if;
  if not exists (select 1 from public.teacher_classes where teacher_id = auth.uid() and class_id = p_class) then
    raise exception 'class not assigned to this teacher' using errcode = '42501';
  end if;
  update public.profiles set class_id = p_class where id = auth.uid();
end $$;

-- 管理者：一次儲存老師的姓名與負責的班級（可多個）
create or replace function public.admin_save_teacher(p_id uuid, p_name text, p_classes text[])
returns void language plpgsql security definer set search_path = '' as $$
declare v_cur text; v_list text[] := coalesce(p_classes, '{}');
begin
  if not (select private.is_admin()) then raise exception 'admin only' using errcode = '42501'; end if;
  if not exists (select 1 from public.profiles where id = p_id and role = 'teacher') then
    raise exception 'teacher not found' using errcode = '22023';
  end if;
  if btrim(coalesce(p_name, '')) = '' then raise exception 'name required' using errcode = '22023'; end if;
  if exists (select 1 from unnest(v_list) c where not exists (select 1 from public.classes x where x.id = c)) then
    raise exception 'class not found' using errcode = '22023';
  end if;
  delete from public.teacher_classes where teacher_id = p_id and not (class_id = any(v_list));
  insert into public.teacher_classes (teacher_id, class_id) select p_id, c from unnest(v_list) c on conflict do nothing;
  select class_id into v_cur from public.profiles where id = p_id;
  update public.profiles
     set display_name = btrim(p_name),
         class_id = case when v_cur = any(v_list) then v_cur else v_list[1] end
   where id = p_id;
end $$;

-- 新增老師時也寫入 teacher_classes
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
  if p_class is not null then
    insert into public.teacher_classes (teacher_id, class_id) values (v_uid, p_class);
  end if;
  perform private.set_pin(v_uid, p_pin);
  return jsonb_build_object('id', v_uid);
end $$;

-- 舊的單一班級修改：同步寫入 teacher_classes（保持相容）
create or replace function public.admin_update_teacher(p_id uuid, p_name text, p_class text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not (select private.is_admin()) then raise exception 'admin only' using errcode = '42501'; end if;
  if btrim(coalesce(p_name, '')) = '' then raise exception 'name required' using errcode = '22023'; end if;
  if p_class is not null and not exists (select 1 from public.classes where id = p_class) then
    raise exception 'class not found' using errcode = '22023';
  end if;
  update public.profiles set display_name = btrim(p_name), class_id = p_class where id = p_id and role = 'teacher';
  if p_class is not null then
    insert into public.teacher_classes (teacher_id, class_id) values (p_id, p_class) on conflict do nothing;
  end if;
end $$;

-- 班級被刪除後，老師目前的班會變成空的：自動換到他負責的另一個班
create or replace function private.teacher_class_fallback()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.profiles p
     set class_id = (select tc.class_id from public.teacher_classes tc where tc.teacher_id = p.id order by tc.class_id limit 1)
   where p.role = 'teacher' and p.class_id is null
     and exists (select 1 from public.teacher_classes tc where tc.teacher_id = p.id);
  return null;
end $$;
drop trigger if exists classes_teacher_fallback on public.classes;
create trigger classes_teacher_fallback after delete on public.classes
  for each statement execute function private.teacher_class_fallback();

-- 資料指紋加上老師負責的班級（管理者調整後，老師畫面會自動更新）
create or replace function public.get_data_version()
 returns text language sql stable set search_path to ''
as $function$
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
    (select coalesce(md5(string_agg(concat_ws(',', id::text, login_id, display_name, class_id, sort_order::text, array_to_string(allowed_grades, '/')), ';' order by id)), '') from public.profiles),
    (select coalesce(md5(string_agg(teacher_id::text || ',' || class_id, ';' order by teacher_id, class_id)), '') from public.teacher_classes)
  ))
$function$;

revoke all on function public.teacher_switch_class(text), public.admin_save_teacher(uuid, text, text[]) from public, anon;
grant execute on function public.teacher_switch_class(text), public.admin_save_teacher(uuid, text, text[]) to authenticated, service_role;
revoke all on function private.teacher_class_fallback() from public, anon, authenticated;

-- 全校備份加入「老師負責的班級」
create or replace function public.backup_data()
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_role text;
  v_class text;
  v_out jsonb;
begin
  select p.role, p.class_id into v_role, v_class
    from public.profiles p where p.id = auth.uid();

  if v_role = 'admin' then
    v_out := jsonb_build_object(
      'scope', 'all',
      'grades',         coalesce((select jsonb_agg(to_jsonb(x) order by x.sort_order) from public.grades x), '[]'),
      'subjects',       coalesce((select jsonb_agg(to_jsonb(x) order by x.sort_order) from public.subjects x), '[]'),
      'classes',        coalesce((select jsonb_agg(to_jsonb(x) order by x.sort_order) from public.classes x), '[]'),
      'profiles',       coalesce((select jsonb_agg(to_jsonb(x) order by x.role, x.sort_order) from public.profiles x), '[]'),
      'students',       coalesce((select jsonb_agg(to_jsonb(x) order by x.id) from public.students x), '[]'),
      'class_students', coalesce((select jsonb_agg(to_jsonb(x)) from public.class_students x), '[]'),
      'teacher_classes', coalesce((select jsonb_agg(to_jsonb(x)) from public.teacher_classes x), '[]'),
      'tasks',          coalesce((select jsonb_agg(to_jsonb(x) order by x.class_id, x.date, x.id) from public.tasks x), '[]'),
      'contact_book',   coalesce((select jsonb_agg(to_jsonb(x) order by x.class_id, x.date) from public.contact_book x), '[]'),
      'submit_log',     coalesce((select jsonb_agg(to_jsonb(x) order by x.at) from public.submit_log x), '[]')
    );
  elsif v_role = 'teacher' then
    if v_class is null then
      raise exception 'teacher has no class';
    end if;
    v_out := jsonb_build_object(
      'scope', 'class',
      'grades',         coalesce((select jsonb_agg(to_jsonb(x) order by x.sort_order) from public.grades x), '[]'),
      'subjects',       coalesce((select jsonb_agg(to_jsonb(x) order by x.sort_order) from public.subjects x), '[]'),
      'classes',        coalesce((select jsonb_agg(to_jsonb(x)) from public.classes x where x.id = v_class), '[]'),
      'students',       coalesce((select jsonb_agg(to_jsonb(s) order by s.id) from public.students s
                                  where s.id in (select cs.student_id from public.class_students cs where cs.class_id = v_class)), '[]'),
      'class_students', coalesce((select jsonb_agg(to_jsonb(x)) from public.class_students x where x.class_id = v_class), '[]'),
      'tasks',          coalesce((select jsonb_agg(to_jsonb(x) order by x.date, x.id) from public.tasks x where x.class_id = v_class), '[]'),
      'contact_book',   coalesce((select jsonb_agg(to_jsonb(x) order by x.date) from public.contact_book x where x.class_id = v_class), '[]'),
      'submit_log',     coalesce((select jsonb_agg(to_jsonb(x) order by x.at) from public.submit_log x where x.class_id = v_class), '[]')
    );
  else
    raise exception 'not allowed';
  end if;

  return jsonb_build_object(
    'app', '基翔學習通',
    'format', 1,
    'created_at', now(),
    'role', v_role
  ) || v_out;
end $$;

revoke all on function public.backup_data() from public, anon;
grant execute on function public.backup_data() to authenticated;

-- ===== 階段 L：統一由管理者備份＋備份紀錄（2026-10-16 加入） =====
-- 基翔學習通：階段 L　統一由管理者備份＋記錄最後備份時間（用來每週提醒）
-- 用法：SQL Editor 貼上 → Run（可重複執行）

create table if not exists public.backup_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  by_user uuid
);
alter table public.backup_log enable row level security;
revoke all on public.backup_log from anon, authenticated;

-- 管理者查詢最後一次備份時間
create or replace function public.get_last_backup()
returns timestamptz language sql stable security definer set search_path = '' as $$
  select case when (select private.is_admin()) then (select max(at) from public.backup_log) end
$$;
revoke all on function public.get_last_backup() from public, anon;
grant execute on function public.get_last_backup() to authenticated;

-- 備份：只有管理者能下載；每次下載記錄時間
create or replace function public.backup_data()
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_role text;
  v_class text;
  v_out jsonb;
begin
  select p.role, p.class_id into v_role, v_class
    from public.profiles p where p.id = auth.uid();

  if v_role = 'admin' then
    insert into public.backup_log (by_user) values (auth.uid());
    v_out := jsonb_build_object(
      'scope', 'all',
      'grades',         coalesce((select jsonb_agg(to_jsonb(x) order by x.sort_order) from public.grades x), '[]'),
      'subjects',       coalesce((select jsonb_agg(to_jsonb(x) order by x.sort_order) from public.subjects x), '[]'),
      'classes',        coalesce((select jsonb_agg(to_jsonb(x) order by x.sort_order) from public.classes x), '[]'),
      'profiles',       coalesce((select jsonb_agg(to_jsonb(x) order by x.role, x.sort_order) from public.profiles x), '[]'),
      'students',       coalesce((select jsonb_agg(to_jsonb(x) order by x.id) from public.students x), '[]'),
      'class_students', coalesce((select jsonb_agg(to_jsonb(x)) from public.class_students x), '[]'),
      'teacher_classes', coalesce((select jsonb_agg(to_jsonb(x)) from public.teacher_classes x), '[]'),
      'tasks',          coalesce((select jsonb_agg(to_jsonb(x) order by x.class_id, x.date, x.id) from public.tasks x), '[]'),
      'contact_book',   coalesce((select jsonb_agg(to_jsonb(x) order by x.class_id, x.date) from public.contact_book x), '[]'),
      'submit_log',     coalesce((select jsonb_agg(to_jsonb(x) order by x.at) from public.submit_log x), '[]')
    );
  else
    raise exception 'only admin can download backups';
  end if;

  return jsonb_build_object(
    'app', '基翔學習通',
    'format', 1,
    'created_at', now(),
    'role', v_role
  ) || v_out;
end $$;

revoke all on function public.backup_data() from public, anon;
grant execute on function public.backup_data() to authenticated;
