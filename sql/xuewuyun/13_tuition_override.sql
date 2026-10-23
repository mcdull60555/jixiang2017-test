-- ============================================================
-- 基翔學務雲 階段 6：學生個別月費（先在測試專案執行，需先執行 11_tuition_pricing.sql）
--   fee_enrollments.amount：這位學生這個班的「每月金額」；留空＝依價目表。
--     期繳時，一期金額 = 每月金額 × 該期月數。
--   新增班別「車資」（項目種類：車資），每位學生的車資金額填在 amount。
-- ============================================================
alter table public.fee_enrollments add column if not exists amount integer check (amount is null or amount >= 0);

insert into public.fee_programs (code, name, item_type, period_rule, sort_order)
select 'transport', '車資', 'transport', '[]'::jsonb, 60
where not exists (select 1 from public.fee_programs where code = 'transport');
