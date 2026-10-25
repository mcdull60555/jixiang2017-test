-- 晚餐單：臨時加訂當成一位學生計費（已繳／假日加強），以月為單位
create table if not exists public.meal_temp_ledger (
  ym text primary key check (ym ~ '^\d{4}-\d{2}$'),
  paid integer not null default 0,
  extra integer not null default 0,
  updated_at timestamptz not null default now()
);
alter table public.meal_temp_ledger enable row level security;
drop policy if exists meal_temp_ledger_read on public.meal_temp_ledger;
create policy meal_temp_ledger_read on public.meal_temp_ledger for select to authenticated using ((select private.fee_can_view()));

create or replace function public.meal_save_temp_ledger(p_ym text, p_paid integer, p_extra integer)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not (select private.fee_can_edit()) then raise exception 'no fee edit permission' using errcode = '42501'; end if;
  insert into public.meal_temp_ledger(ym, paid, extra, updated_at) values (p_ym, greatest(coalesce(p_paid,0),0), greatest(coalesce(p_extra,0),0), now())
  on conflict (ym) do update set paid = excluded.paid, extra = excluded.extra, updated_at = now();
end $$;
revoke all on function public.meal_save_temp_ledger(text, integer, integer) from public, anon;
grant execute on function public.meal_save_temp_ledger(text, integer, integer) to authenticated;
