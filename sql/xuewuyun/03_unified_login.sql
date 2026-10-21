-- ============================================================
-- 基翔學務雲 第 3 階段（先做學習通）：統一登入
--   學生、家長改用「學生帳號（JX…）＋4 位數密碼」登入
--   登入前不再公開學生名單；停用或離班的學生不能登入
-- 先在測試專案 jixiang-supabase-test 執行
-- ============================================================

-- 1. 學生的內部登入代號改成「學生帳號」（例：JX115001 → jx115001@school.test）
update auth.users u
   set email = lower(s.account_code) || '@school.test', updated_at = now()
  from public.students s
 where s.auth_user_id = u.id and s.account_code is not null
   and u.email is distinct from lower(s.account_code) || '@school.test';

update auth.identities i
   set identity_data = jsonb_set(i.identity_data, '{email}', to_jsonb(lower(s.account_code) || '@school.test')), updated_at = now()
  from public.students s
 where s.auth_user_id = i.user_id and i.provider = 'email' and s.account_code is not null;

-- 2. 停用學習通或已離班的學生不能登入（其餘規則與原本相同：錯 3 次鎖 1 分鐘）
create or replace function public.login_attempt(p_email text, p_pin text)
 returns jsonb language plpgsql security definer set search_path to '' as $function$
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

  if exists (select 1 from public.students s
              where s.auth_user_id = v_uid and (not s.learning_enabled or not s.active)) then
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

-- 3. 老師新增學生時，登入代號直接用自動產生的學生帳號
create or replace function public.teacher_create_students(p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  r jsonb; v_class text := (select private.my_class_id());
  v_id text; v_name text; v_school text; v_grade text; v_pw text; v_uid uuid; v_code text; v_n int := 0;
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
    values (v_id, v_name, v_school, v_grade, coalesce(r ->> 'className', ''), coalesce(r ->> 'avatar', ''))
    returning account_code into v_code;
    v_uid := private.create_auth_user(lower(coalesce(v_code, v_id)) || '@school.test');
    insert into public.profiles (id, role, student_id) values (v_uid, 'student', v_id);
    perform private.set_pin(v_uid, v_pw);
    update public.students set auth_user_id = v_uid where id = v_id;
    insert into public.class_students (class_id, student_id) values (v_class, v_id);
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('created', v_n);
end $$;

-- 4. 登入前不再公開學生名單（老師名單仍公開，給老師登入的下拉選單用）
revoke select on public.students from anon;
revoke select on public.class_students from anon;
