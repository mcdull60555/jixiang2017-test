-- ============================================================
-- 基翔學務雲：學生名冊（管理員）
--   admin_list_students()            讀取全部學生（含帳號、班級、聯絡電話…，不含密碼）
--   admin_save_student(p jsonb)      新增／修改一位學生；開啟學習通時自動建立登入帳號
--   admin_set_student_pin(id, pin)   重設學生 4 位數密碼（同時更新加密副本，之後可查看）
-- 查看密碼沿用 reveal_student_pin（管理員、主任看全部；老師限自己班）
-- 不提供刪除：離班的學生改成「在學」關閉（active=false），紀錄都保留
-- 先在測試專案 jixiang-supabase-test 執行
-- ============================================================

create or replace function public.admin_list_students()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not (select private.is_admin()) then raise exception 'admin only' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', s.id, 'name', s.name, 'school', s.school, 'grade', s.grade, 'school_class', s.school_class,
      'birthday', s.birthday, 'contacts', s.contacts, 'fixed_off_days', s.fixed_off_days, 'note', s.note,
      'in_rollcall', s.in_rollcall, 'learning_enabled', s.learning_enabled, 'active', s.active,
      'account_code', s.account_code, 'entry_year', s.entry_year,
      'has_login', s.auth_user_id is not null,
      'pin_viewable', exists (select 1 from private.login_pins lp where lp.user_id = s.auth_user_id and lp.pin_enc is not null),
      'class_ids', coalesce((select jsonb_agg(cs.class_id) from public.class_students cs where cs.student_id = s.id), '[]'::jsonb),
      'created_at', s.created_at
    ) order by s.created_at)
    from public.students s
  ), '[]'::jsonb);
end $$;

create or replace function public.admin_save_student(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
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
  v_uid uuid; v_code text;
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
  if v_pin is not null and v_pin !~ '^[0-9]{4}$' then raise exception 'password must be 4 digits' using errcode = '22023'; end if;

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

  -- 開啟學習通、還沒有登入帳號：建立帳號（需要 4 位數密碼）
  select auth_user_id, account_code into v_uid, v_code from public.students where id = v_id;
  if v_learning and v_uid is null then
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

create or replace function public.admin_set_student_pin(p_id text, p_pin text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid;
begin
  if not (select private.is_admin()) then raise exception 'admin only' using errcode = '42501'; end if;
  if p_pin is null or p_pin !~ '^[0-9]{4}$' then raise exception 'password must be 4 digits' using errcode = '22023'; end if;
  select auth_user_id into v_uid from public.students where id = p_id;
  if v_uid is null then raise exception 'student has no login' using errcode = '22023'; end if;
  perform private.set_pin(v_uid, p_pin);
end $$;

revoke execute on function public.admin_list_students(), public.admin_save_student(jsonb), public.admin_set_student_pin(text, text) from anon, public;
grant execute on function public.admin_list_students(), public.admin_save_student(jsonb), public.admin_set_student_pin(text, text) to authenticated;
