-- =====================================================================
-- 基翔學務雲 31：統一密碼規則（管理員、老師、學生）
-- 規則：至少 6 碼、最多 64 碼；必須同時含英文字母與數字；區分大小寫；不可有空白。
-- 系統自動產生的預設密碼：6 碼英數字，避開容易看錯的字元（0 O o 1 I l）。
-- 只動測試專案。已存在的舊密碼不受影響（登入不檢查格式），只有「新設定／重設」才要符合。
-- 套用順序：接在 30 之後。
-- =====================================================================

-- 1) 密碼格式檢查（所有設定密碼的函式共用）
create or replace function private.pin_ok(p text)
returns boolean
language sql
immutable
set search_path to ''
as $$
  select p is not null
     and length(p) between 6 and 64
     and p ~ '[A-Za-z]'
     and p ~ '[0-9]'
     and p !~ '\s'
$$;

-- 2) 預設密碼產生器：6 碼，英文大小寫＋數字，避開 0 O o 1 I l
create or replace function private.gen_default_password()
returns text
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare
  v_chars constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789';  -- 56 個字
  v_pw text;
  v_b bytea;
  v_i int;
begin
  loop
    v_pw := '';
    while length(v_pw) < 6 loop
      v_b := extensions.gen_random_bytes(12);
      for v_i in 0..11 loop
        exit when length(v_pw) >= 6;
        if get_byte(v_b, v_i) < 224 then   -- 224 = 56 × 4，丟掉多的數值避免偏誤
          v_pw := v_pw || substr(v_chars, 1 + (get_byte(v_b, v_i) % 56), 1);
        end if;
      end loop;
    end loop;
    exit when v_pw ~ '[A-Za-z]' and v_pw ~ '[0-9]';
  end loop;
  return v_pw;
end $$;

-- 3) 學生密碼（管理員重設）
create or replace function public.admin_set_student_pin(p_id text, p_pin text)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare v_uid uuid;
begin
  if not (select private.is_admin()) then raise exception 'admin only' using errcode = '42501'; end if;
  if not private.pin_ok(p_pin) then raise exception 'password must be 6 to 64 characters with letters and digits' using errcode = '22023'; end if;
  select auth_user_id into v_uid from public.students where id = p_id;
  if v_uid is null then raise exception 'student has no login' using errcode = '22023'; end if;
  perform private.set_pin(v_uid, p_pin);
end $$;

-- 4) 老師密碼（管理員重設）
create or replace function public.admin_set_teacher_pin(p_id uuid, p_pin text)
returns void
language plpgsql
security definer
set search_path to ''
as $$
begin
  if not (select private.is_admin()) then raise exception 'admin only' using errcode = '42501'; end if;
  if not private.pin_ok(p_pin) then
    raise exception 'password must be 6 to 64 characters with letters and digits' using errcode = '22023';
  end if;
  if not exists (select 1 from public.profiles where id = p_id and role = 'teacher') then
    raise exception 'teacher not found' using errcode = '22023';
  end if;
  perform private.set_pin(p_id, p_pin);
end $$;

-- 5) 新增老師
create or replace function public.admin_create_teacher(p_login text, p_name text, p_pin text, p_class text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare v_uid uuid;
begin
  if not (select private.is_admin()) then raise exception 'admin only' using errcode = '42501'; end if;
  if p_login is null or p_login !~ '^t_[a-z0-9_-]{1,60}$' then
    raise exception 'teacher id must look like t_name (lowercase letters, digits, - _)' using errcode = '22023';
  end if;
  if btrim(coalesce(p_name, '')) = '' then raise exception 'name required' using errcode = '22023'; end if;
  if not private.pin_ok(p_pin) then
    raise exception 'password must be 6 to 64 characters with letters and digits' using errcode = '22023';
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

-- 6) 自己改密碼（管理員、老師、學生一律同一規則）
create or replace function public.change_my_pin(p_pin text)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare v_role text;
begin
  select role into v_role from public.profiles where id = auth.uid();
  if v_role is null then raise exception 'not logged in' using errcode = '42501'; end if;
  if not private.pin_ok(p_pin) then
    raise exception 'password must be 6 to 64 characters with letters and digits' using errcode = '22023';
  end if;
  perform private.set_pin(auth.uid(), p_pin);
end $$;

-- 7) 老師幫自己班的學生設定密碼（學習通）
create or replace function public.teacher_set_student_passwords(p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare r jsonb; v_class text := (select private.my_class_id()); v_n int := 0; v_uid uuid;
begin
  if not (select private.is_teacher()) or v_class is null then
    raise exception 'only teachers can set passwords' using errcode = '42501';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 or jsonb_array_length(p_rows) > 500 then
    raise exception 'rows must be an array of 1 to 500 items' using errcode = '22023';
  end if;
  for r in select value from jsonb_array_elements(p_rows) loop
    if not private.pin_ok(r ->> 'pwd') then raise exception 'password must be 6 to 64 characters with letters and digits' using errcode = '22023'; end if;
    select s.auth_user_id into v_uid
      from public.students s
     where s.id = r ->> 'id' and s.auth_user_id is not null
       and exists (select 1 from public.class_students cs where cs.student_id = s.id and cs.class_id = v_class);
    if v_uid is not null then
      perform private.set_pin(v_uid, r ->> 'pwd');
      v_n := v_n + 1;
    end if;
  end loop;
  return jsonb_build_object('updated', v_n);
end $$;

-- 8) 學生名冊儲存：新建登入帳號或改密碼時的規則
create or replace function public.admin_save_student(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_id text := nullif(p ->> 'id', '');
  v_name text := btrim(coalesce(p ->> 'name', ''));
  v_school text := btrim(coalesce(p ->> 'school', ''));
  v_grade text := btrim(coalesce(p ->> 'grade', ''));
  v_cls integer := nullif(p ->> 'school_class', '')::integer;
  v_bday date := nullif(p ->> 'birthday', '')::date;
  v_contacts jsonb := coalesce(p -> 'contacts', '[]'::jsonb);
  v_days integer[] := coalesce((select array_agg(distinct x::int order by x::int) from jsonb_array_elements_text(coalesce(p -> 'fixed_off_days', '[]'::jsonb)) x), '{}');
  v_classes text[] := coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p -> 'class_ids', '[]'::jsonb)) x), '{}');
  v_learning boolean := coalesce((p ->> 'learning_enabled')::boolean, true);
  v_pin text := nullif(btrim(coalesce(p ->> 'pin', '')), '');
  v_uid uuid; v_code text; v_act boolean;
begin
  if not (select private.is_admin()) then raise exception 'admin only' using errcode = '42501'; end if;
  if v_name = '' then raise exception 'name required' using errcode = '22023'; end if;
  if v_school = '' then raise exception 'school required' using errcode = '22023'; end if;
  if private.grade_number(v_grade) is null then raise exception 'grade required' using errcode = '22023'; end if;
  if v_cls is not null and (v_cls < 1 or v_cls > 99) then raise exception 'class number 1-99' using errcode = '22023'; end if;
  if jsonb_typeof(v_contacts) <> 'array' or jsonb_array_length(v_contacts) > 3 then
    raise exception 'contacts must be up to 3' using errcode = '22023';
  end if;
  if exists (select 1 from unnest(v_days) d where d < 1 or d > 5) then raise exception 'days must be 1-5' using errcode = '22023'; end if;
  if exists (select 1 from unnest(v_classes) c where not exists (select 1 from public.classes x where x.id = c)) then
    raise exception 'class not found' using errcode = '22023';
  end if;
  if v_pin is not null and not private.pin_ok(v_pin) then raise exception 'password must be 6 to 64 characters with letters and digits' using errcode = '22023'; end if;

  if v_id is null then
    insert into public.students (name, school, grade, school_class, birthday, contacts, fixed_off_days, note,
                                 in_rollcall, learning_enabled, active)
    values (v_name, v_school, v_grade, v_cls, v_bday, v_contacts, v_days, coalesce(p ->> 'note', ''),
            coalesce((p ->> 'in_rollcall')::boolean, true), v_learning, coalesce((p ->> 'active')::boolean, true))
    returning id into v_id;
  else
    update public.students set
      name = v_name, school = v_school, grade = v_grade, school_class = v_cls, birthday = v_bday,
      contacts = v_contacts, fixed_off_days = v_days, note = coalesce(p ->> 'note', ''),
      in_rollcall = coalesce((p ->> 'in_rollcall')::boolean, in_rollcall),
      learning_enabled = v_learning,
      active = coalesce((p ->> 'active')::boolean, active)
    where id = v_id;
    if not found then raise exception 'student not found' using errcode = '22023'; end if;
  end if;

  -- 學習通班級
  delete from public.class_students where student_id = v_id and not (class_id = any(v_classes));
  insert into public.class_students (class_id, student_id) select c, v_id from unnest(v_classes) c on conflict do nothing;

  -- 開啟學習通、還沒有登入帳號：建立帳號（需要初始密碼：6 碼以上、含英文與數字）
  select auth_user_id, account_code, active into v_uid, v_code, v_act from public.students where id = v_id;
  if (v_learning or v_act) and v_uid is null then
    if v_pin is null then raise exception 'pin required for new login' using errcode = '22023'; end if;
    if v_code is null then raise exception 'account code missing' using errcode = '22023'; end if;
    v_uid := private.create_auth_user(lower(v_code) || '@school.test');
    insert into public.profiles (id, role, student_id) values (v_uid, 'student', v_id);
    update public.students set auth_user_id = v_uid where id = v_id;
    perform private.set_pin(v_uid, v_pin);
  elsif v_pin is not null and v_uid is not null then
    perform private.set_pin(v_uid, v_pin);
  end if;

  return jsonb_build_object('id', v_id, 'account_code', v_code);
end $$;

-- 9) 全部在學學生一次換成新的預設密碼（只有管理員；換完到學生名冊印帳密小卡）
create or replace function public.admin_reset_all_student_pins()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare r record; n int := 0;
begin
  if not (select private.is_admin()) then raise exception 'admin only' using errcode = '42501'; end if;
  for r in select auth_user_id from public.students where active and auth_user_id is not null loop
    perform private.set_pin(r.auth_user_id, private.gen_default_password());
    n := n + 1;
  end loop;
  return jsonb_build_object('updated', n);
end $$;

revoke execute on function public.admin_reset_all_student_pins() from public, anon;
grant execute on function public.admin_reset_all_student_pins() to authenticated;
