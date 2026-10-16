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
