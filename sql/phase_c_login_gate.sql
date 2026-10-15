-- 基翔小學通 Supabase 測試專案：階段 C 登入閘門（錯 3 次鎖 1 分鐘）
-- 用法：Supabase 後台 → SQL Editor → 貼上 → Run（可重複執行）
-- 做法：4 位數密碼改存在 private.login_pins，只有 Edge Function「login」（service_role）能驗證，
--       Auth 內的真實密碼改成隨機值，所以繞過閘門直接打 Auth 也猜不到。

-- 1. 密碼表（API 不可見；只有函式能碰）
create table if not exists private.login_pins (
  user_id        uuid primary key references auth.users(id) on delete cascade,
  pin_hash       text not null,
  failed_count   int  not null default 0,
  last_failed_at timestamptz,
  locked_until   timestamptz
);
alter table private.login_pins enable row level security;
revoke all on private.login_pins from anon, authenticated, public;

-- 2. 把現有密碼雜湊搬進去（原本 Auth 內存的就是 crypt('jx'||4碼)），再把 Auth 密碼換成隨機值
insert into private.login_pins (user_id, pin_hash)
select u.id, u.encrypted_password
  from auth.users u
  join public.profiles p on p.id = u.id
on conflict (user_id) do nothing;

update auth.users u
   set encrypted_password = extensions.crypt(gen_random_uuid()::text || gen_random_uuid()::text, extensions.gen_salt('bf')),
       updated_at = now()
  from public.profiles p
 where p.id = u.id;

-- 3. 驗證函式：只給 service_role（Edge Function）呼叫
create or replace function public.login_attempt(p_email text, p_pin text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
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
    perform extensions.crypt('jx' || p_pin, extensions.gen_salt('bf'));  -- 拉平回應時間
    return jsonb_build_object('status', 'denied');
  end if;

  select * into v_row from private.login_pins where user_id = v_uid for update;  -- 同一帳號的猜測一次一個
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

  -- 失敗：鎖定期結束、或上次失敗已超過 15 分鐘，從 1 開始重算
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
end $$;

revoke all on function public.login_attempt(text, text) from public, anon, authenticated;
grant execute on function public.login_attempt(text, text) to service_role;

-- 4. 自己改密碼（學生：4 位數字；老師：4～64 字元）
create or replace function public.change_my_pin(p_pin text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_role text;
begin
  select role into v_role from public.profiles where id = auth.uid();
  if v_role is null then
    raise exception 'not logged in' using errcode = '42501';
  end if;
  if v_role = 'student' and coalesce(p_pin, '') !~ '^[0-9]{4}$' then
    raise exception 'password must be 4 digits' using errcode = '22023';
  end if;
  if v_role = 'teacher' and (p_pin is null or length(p_pin) < 4 or length(p_pin) > 64) then
    raise exception 'password must be 4 to 64 characters' using errcode = '22023';
  end if;
  insert into private.login_pins (user_id, pin_hash)
  values (auth.uid(), extensions.crypt('jx' || p_pin, extensions.gen_salt('bf')))
  on conflict (user_id) do update
    set pin_hash = excluded.pin_hash, failed_count = 0, last_failed_at = null, locked_until = null;
end $$;

revoke all on function public.change_my_pin(text) from public, anon;
grant execute on function public.change_my_pin(text) to authenticated;

-- 5. 老師端函式改寫：密碼寫進 login_pins，Auth 密碼用隨機值
create or replace function public.teacher_create_students(p_rows jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  r jsonb;
  v_id text; v_name text; v_school text; v_grade text; v_pw text;
  v_uid uuid;
  v_n int := 0;
begin
  if not (select private.is_teacher()) then
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
    if v_pw !~ '^[0-9]{4}$' then
      raise exception 'password must be 4 digits' using errcode = '22023';
    end if;

    insert into public.students (id, name, school, grade, class_name, avatar)
    values (v_id, v_name, v_school, v_grade, coalesce(r ->> 'className', ''), coalesce(r ->> 'avatar', ''));

    v_uid := gen_random_uuid();
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      confirmation_token, recovery_token, email_change_token_new, email_change,
      email_change_token_current, reauthentication_token, phone_change, phone_change_token
    ) values (
      '00000000-0000-0000-0000-000000000000', v_uid, 'authenticated', 'authenticated',
      v_id || '@school.test',
      extensions.crypt(gen_random_uuid()::text || gen_random_uuid()::text, extensions.gen_salt('bf')), now(),
      '{"provider":"email","providers":["email"]}', '{}', now(), now(),
      '', '', '', '', '', '', '', ''
    );
    insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
    values (v_uid::text, v_uid,
            jsonb_build_object('sub', v_uid::text, 'email', v_id || '@school.test', 'email_verified', true, 'phone_verified', false),
            'email', now(), now(), now());
    insert into public.profiles (id, role, student_id) values (v_uid, 'student', v_id);
    insert into private.login_pins (user_id, pin_hash)
    values (v_uid, extensions.crypt('jx' || v_pw, extensions.gen_salt('bf')));
    update public.students set auth_user_id = v_uid where id = v_id;
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('created', v_n);
end $$;

create or replace function public.teacher_set_student_passwords(p_rows jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  r jsonb;
  v_n int := 0;
  v_cnt int;
begin
  if not (select private.is_teacher()) then
    raise exception 'only teachers can set passwords' using errcode = '42501';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 or jsonb_array_length(p_rows) > 500 then
    raise exception 'rows must be an array of 1 to 500 items' using errcode = '22023';
  end if;

  for r in select value from jsonb_array_elements(p_rows) loop
    if coalesce(r ->> 'pwd', '') !~ '^[0-9]{4}$' then
      raise exception 'password must be 4 digits' using errcode = '22023';
    end if;
    insert into private.login_pins (user_id, pin_hash)
    select s.auth_user_id, extensions.crypt('jx' || (r ->> 'pwd'), extensions.gen_salt('bf'))
      from public.students s
     where s.id = r ->> 'id' and s.auth_user_id is not null
    on conflict (user_id) do update
      set pin_hash = excluded.pin_hash, failed_count = 0, last_failed_at = null, locked_until = null;
    get diagnostics v_cnt = row_count;
    v_n := v_n + v_cnt;
  end loop;

  return jsonb_build_object('updated', v_n);
end $$;
