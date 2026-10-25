-- 晚餐結算：拿掉 10 月「只帶補繳、不帶溢繳」的 Excel 特例，9 月溢繳也自動轉入 10 月（與晚餐管理畫面一致）
do $$
declare d text;
begin
  d := pg_get_functiondef('public.meal_settle_balance'::regproc);
  d := replace(d, '(case when p_ym = ''2026-10'' then least(p.v, 0) else p.v end)', 'p.v');
  if d like '%least(p.v, 0)%' then raise exception 'patch failed'; end if;
  execute d;
end $$;
