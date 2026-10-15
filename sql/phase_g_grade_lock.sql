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
