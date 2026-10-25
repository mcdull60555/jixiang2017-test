-- 晚餐單：臨時加訂可記錄多位不在名單的學生姓名
alter table public.meal_days add column if not exists extra_names text not null default '';

create or replace function public.meal_save_day_extra(p_day date, p_extra integer, p_names text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not (select private.fee_can_edit()) then raise exception 'no fee edit permission' using errcode = '42501'; end if;
  insert into public.meal_days(day, extra, teachers, note, extra_names)
  values (p_day, greatest(coalesce(p_extra,0),0), 0, '', coalesce(p_names,''))
  on conflict (day) do update set extra = excluded.extra, extra_names = excluded.extra_names;
end $$;
revoke all on function public.meal_save_day_extra(date, integer, text) from public, anon;
grant execute on function public.meal_save_day_extra(date, integer, text) to authenticated;
