-- 新增學生要由管理員在學費管理「收費設定」確認：students.fee_confirmed（新學生預設 false，現有學生視為已確認）
alter table public.students add column if not exists fee_confirmed boolean not null default false;
update public.students set fee_confirmed = true;   -- 只在第一次套用時執行；之後新增的學生預設 false

do $mig$
declare d text;
begin
  d := pg_get_functiondef('public.fee_list_students'::regproc);
  d := replace(d, '''account_code'', s.account_code)', '''account_code'', s.account_code, ''fee_confirmed'', s.fee_confirmed)');
  if d not like '%fee_confirmed%' then raise exception 'patch failed'; end if;
  execute d;
end $mig$;

create or replace function public.fee_confirm_student(p_id text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not (select private.fee_can_edit()) then raise exception 'no fee edit permission' using errcode = '42501'; end if;
  update public.students set fee_confirmed = true where id = p_id;
end $$;
revoke all on function public.fee_confirm_student(text) from public, anon;
grant execute on function public.fee_confirm_student(text) to authenticated;
