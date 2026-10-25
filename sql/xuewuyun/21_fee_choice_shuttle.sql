-- 名冊只「選」班別與繳費方式（students.fee_choice），並記錄是否需要接送（students.shuttle）；
-- 實際收費設定仍由管理員在學費管理確認。需先套用 20_fee_confirmed.sql。
alter table public.students add column if not exists fee_choice jsonb not null default '{}'::jsonb;
alter table public.students add column if not exists shuttle boolean not null default false;

do $mig$
declare d text;
begin
  d := pg_get_functiondef('public.admin_list_students'::regproc);
  d := replace(d, '''created_at'', s.created_at', '''created_at'', s.created_at, ''fee_confirmed'', s.fee_confirmed, ''fee_choice'', s.fee_choice, ''shuttle'', s.shuttle');
  if d not like '%fee_choice%' then raise exception 'patch failed admin_list_students'; end if;
  execute d;
  d := pg_get_functiondef('public.fee_list_students'::regproc);
  d := replace(d, '''fee_confirmed'', s.fee_confirmed)', '''fee_confirmed'', s.fee_confirmed, ''fee_choice'', s.fee_choice, ''shuttle'', s.shuttle)');
  if d not like '%fee_choice%' then raise exception 'patch failed fee_list_students'; end if;
  execute d;
end $mig$;

create or replace function public.admin_set_student_fee_choice(p_id text, p_choice jsonb, p_shuttle boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not (select private.is_admin()) then raise exception 'admin only' using errcode = '42501'; end if;
  update public.students set fee_choice = coalesce(p_choice, '{}'::jsonb), shuttle = coalesce(p_shuttle, false) where id = p_id;
  if not found then raise exception 'student not found' using errcode = '22023'; end if;
end $$;
revoke all on function public.admin_set_student_fee_choice(text, jsonb, boolean) from public, anon;
grant execute on function public.admin_set_student_fee_choice(text, jsonb, boolean) to authenticated;
