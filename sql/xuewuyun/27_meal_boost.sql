-- 晚餐單：標示哪天是假日加強
alter table public.meal_days add column if not exists boost boolean not null default false;
create or replace function public.meal_save_day_boost(p_day date, p_on boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not (select private.fee_can_edit()) then raise exception 'no fee edit permission' using errcode = '42501'; end if;
  insert into public.meal_days(day, extra, teachers, note, boost) values (p_day, 0, 0, '', coalesce(p_on,false))
  on conflict (day) do update set boost = excluded.boost;
end $$;
revoke all on function public.meal_save_day_boost(date, boolean) from public, anon;
grant execute on function public.meal_save_day_boost(date, boolean) to authenticated;
