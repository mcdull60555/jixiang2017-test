-- ============================================================
-- 基翔學務雲 學費管理：快速範本可自訂（先在測試專案 jixiang-supabase-test 執行，需先執行 07、09）
-- fee_presets：開單／梯次設定裡「快速帶入」的範本，管理員可新增、修改、刪除、排序。
-- items：[{ item_type, label, amount, counted, period_text }]
-- kind：對應梯次類型（regular／summer／winter／activity／other，可空）；套用範本時會順便選到該類型的梯次。
-- ============================================================

create table if not exists public.fee_presets (
  id text primary key default ('fp_' || replace(gen_random_uuid()::text, '-', '')),
  name text not null check (length(btrim(name)) > 0),
  kind text check (kind is null or kind in ('regular', 'summer', 'winter', 'activity', 'other')),
  items jsonb not null default '[]'::jsonb check (jsonb_typeof(items) = 'array'),
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);
alter table public.fee_presets enable row level security;
create policy fee_presets_read on public.fee_presets for select to authenticated using ((select private.fee_can_view()));
create policy fee_presets_admin on public.fee_presets for all to authenticated
  using ((select private.is_admin())) with check ((select private.is_admin()));
grant select, insert, update, delete on public.fee_presets to authenticated;

insert into public.fee_presets (name, kind, items, sort_order)
select * from (values
  ('學期／月費單', 'regular',
   '[{"item_type":"tuition","label":"學費"},{"item_type":"material","label":"教材費"},{"item_type":"meal","label":"餐費"},{"item_type":"transport","label":"車資"},{"item_type":"carry","label":"溢繳折抵"},{"item_type":"discount","label":"優惠折扣"}]'::jsonb, 10),
  ('暑期夏令營', 'summer',
   '[{"item_type":"tuition","label":"安親"},{"item_type":"activity","label":"活動"},{"item_type":"material","label":"預習教材費"},{"item_type":"deposit","label":"已繳訂金"},{"item_type":"carry","label":"溢繳折抵"},{"item_type":"discount","label":"優惠折抵"}]'::jsonb, 20),
  ('寒假班', 'winter',
   '[{"item_type":"tuition","label":"寒假班"},{"item_type":"activity","label":"活動"}]'::jsonb, 30)
) v(name, kind, items, sort_order)
where not exists (select 1 from public.fee_presets);
