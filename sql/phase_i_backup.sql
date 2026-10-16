-- 基翔小學通 Supabase 測試專案：階段 I 備份下載
-- 用法：Supabase 後台 → SQL Editor → 貼上 → Run（可重複執行）
-- backup_data()：
--   管理者 → 全校所有資料（年級、科目、班級、老師帳號、學生、作業考卷、聯絡簿、送審紀錄）
--   老師   → 只有自己班級的資料
--   學生或未登入 → 拒絕
-- 不包含任何密碼（private.login_pins），還原到新專案後需重設密碼。

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

revoke all on function public.backup_data() from public, anon;
grant execute on function public.backup_data() to authenticated;
