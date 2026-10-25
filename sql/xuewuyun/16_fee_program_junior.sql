-- 班別新增「國中班」（學生名冊的「班別・收費」選項）
insert into public.fee_programs (code,name,active,item_type,sort_order,period_rule)
values ('junior','國中班',true,'tuition',25,'[]'::jsonb) on conflict (code) do nothing;
