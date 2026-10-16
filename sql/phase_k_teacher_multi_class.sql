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
