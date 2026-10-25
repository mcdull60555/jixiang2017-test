-- 國中教材費：依國中班選的科數計價（價目表自行填寫），一學期收一次（9~2月、3~8月）
insert into public.fee_programs (code,name,active,item_type,sort_order,period_rule)
values ('mat_junior','國中教材費',true,'material',45,'[{"from":9,"to":2},{"from":3,"to":8}]'::jsonb) on conflict (code) do nothing;
