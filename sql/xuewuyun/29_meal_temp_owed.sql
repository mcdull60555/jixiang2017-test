-- 學費管理開單：9、10 月臨時加訂（晚餐單登記的學生姓名）算出每人天數與金額，並回傳臨時列已繳合計（開單時先扣）
create or replace function public.meal_temp_owed(p_ym text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_from date; v_to date; v_paid int; v_rows jsonb;
begin
  if not (select private.fee_can_view()) then raise exception 'no fee view permission' using errcode = '42501'; end if;
  v_to := (to_date(p_ym || '-01', 'YYYY-MM-DD') + interval '1 month - 1 day')::date;
  v_from := (to_date(p_ym || '-01', 'YYYY-MM-DD') - interval '1 month')::date;
  select coalesce(sum(paid), 0)::int into v_paid from public.meal_temp_ledger
   where ym in (to_char(v_from, 'YYYY-MM'), to_char(v_to, 'YYYY-MM'));
  select coalesce(jsonb_agg(jsonb_build_object('name', t.nm, 'days', t.days, 'amount', t.amt, 'first_day', t.fd) order by t.fd, t.nm), '[]'::jsonb) into v_rows
  from (
    select btrim(n) nm, count(*)::int days, min(d.day)::text fd,
           sum(coalesce((select m.price from public.meal_months m where m.ym <= to_char(d.day, 'YYYY-MM') order by m.ym desc limit 1), 100))::int amt
    from public.meal_days d, unnest(regexp_split_to_array(d.extra_names, '[、,，\n]+')) n
    where d.day between v_from and v_to and btrim(n) <> ''
    group by btrim(n)
  ) t;
  return jsonb_build_object('paid', v_paid, 'rows', v_rows);
end $$;
revoke all on function public.meal_temp_owed(text) from public, anon;
grant execute on function public.meal_temp_owed(text) to authenticated;
