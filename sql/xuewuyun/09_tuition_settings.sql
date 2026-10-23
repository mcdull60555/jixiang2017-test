-- ============================================================
-- 基翔學務雲 學費管理：設定可刪除、梯次範本（先在測試專案 jixiang-supabase-test 執行，需先執行 07_tuition.sql）
-- 1. fee_terms.template：梯次的開單範本（明細列：種類、名稱、預設金額、期間、是否計入）
-- 2. 管理員可刪除收款帳戶、梯次、項目種類
--    - 刪除梯次／帳戶：已開的學費單保留，只是梯次／帳戶變成「未指定」
--    - 刪除項目種類：已有學費單明細使用時資料庫會拒絕（請改成停用）
-- ============================================================

alter table public.fee_terms add column if not exists template jsonb not null default '[]'::jsonb;
alter table public.fee_terms drop constraint if exists fee_terms_template_array;
alter table public.fee_terms add constraint fee_terms_template_array check (jsonb_typeof(template) = 'array');

grant delete on public.fee_accounts, public.fee_terms, public.fee_item_types to authenticated;
