-- 晚餐單：每日「實際訂購金額」
alter table public.meal_days add column if not exists actual integer not null default 0;

create or replace function public.meal_save_day_actual(p_day date, p_actual integer)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not private.fee_can_edit() then raise exception 'forbidden'; end if;
  insert into public.meal_days(day, extra, teachers, note, actual)
  values (p_day, 0, 0, '', greatest(coalesce(p_actual,0),0))
  on conflict (day) do update set actual = excluded.actual;
end $$;
revoke all on function public.meal_save_day_actual(date, integer) from public, anon;
grant execute on function public.meal_save_day_actual(date, integer) to authenticated;
