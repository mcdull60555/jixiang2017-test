-- ============================================================
-- 基翔學務雲 學費管理：價目表、班別與期繳規則、學生收費設定
-- （先在測試專案 jixiang-supabase-test 執行，需先執行 07、09、10）
--
-- fee_programs    班別／收費項目（安親班、數學班、英文班、教材費…）與「期繳」的期間規則
--                 period_rule：[{ "from": 3, "to": 6 }, …]（月份；to < from 表示跨年，例如 11~1）
-- fee_prices      價目表：年級 × 班別 × 繳費方式（month 月繳＝每月金額；period 期繳＝一期金額）
-- fee_enrollments 每位學生上哪些班、月繳或期繳、每月優惠金額
-- 權限：價目表、班別只有管理員能改；學生收費設定管理員與被開通的老師能改；可看學費的人都能讀。
-- ============================================================

create table if not exists public.fee_programs (
  code text primary key default ('p' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10)),
  name text not null check (length(btrim(name)) > 0),
  item_type text not null default 'tuition' references public.fee_item_types (code) on update cascade,
  period_rule jsonb not null default '[]'::jsonb check (jsonb_typeof(period_rule) = 'array'),
  sort_order integer not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.fee_prices (
  id text primary key default ('pr_' || replace(gen_random_uuid()::text, '-', '')),
  grade text not null check (length(btrim(grade)) > 0),
  program_code text not null references public.fee_programs (code) on update cascade on delete cascade,
  billing text not null check (billing in ('month', 'period')),
  amount integer check (amount is null or amount >= 0),
  unique (grade, program_code, billing)
);

create table if not exists public.fee_enrollments (
  id text primary key default ('en_' || replace(gen_random_uuid()::text, '-', '')),
  student_id text not null references public.students (id) on delete cascade,
  program_code text not null references public.fee_programs (code) on update cascade on delete cascade,
  billing text not null default 'month' check (billing in ('month', 'period')),
  discount integer not null default 0 check (discount >= 0),          -- 每月優惠金額（元）
  active boolean not null default true,
  note text not null default '',
  created_at timestamptz not null default now(),
  unique (student_id, program_code)
);
create index if not exists fee_enrollments_student on public.fee_enrollments (student_id);

alter table public.fee_programs enable row level security;
alter table public.fee_prices enable row level security;
alter table public.fee_enrollments enable row level security;

create policy fee_programs_read on public.fee_programs for select to authenticated using ((select private.fee_can_view()));
create policy fee_programs_admin on public.fee_programs for all to authenticated
  using ((select private.is_admin())) with check ((select private.is_admin()));
create policy fee_prices_read on public.fee_prices for select to authenticated using ((select private.fee_can_view()));
create policy fee_prices_admin on public.fee_prices for all to authenticated
  using ((select private.is_admin())) with check ((select private.is_admin()));
create policy fee_enrollments_read on public.fee_enrollments for select to authenticated using ((select private.fee_can_view()));
create policy fee_enrollments_edit on public.fee_enrollments for all to authenticated
  using ((select private.fee_can_edit())) with check ((select private.fee_can_edit()));

grant select, insert, update on public.fee_programs, public.fee_prices, public.fee_enrollments to authenticated;

-- 預設班別與期繳期間（可在「學費管理 → 收費設定」修改）
insert into public.fee_programs (code, name, item_type, period_rule, sort_order)
select * from (values
  ('care',        '安親班',     'tuition',  '[{"from":3,"to":6},{"from":9,"to":12}]'::jsonb, 10),
  ('math',        '數學班',     'tuition',  '[{"from":9,"to":2},{"from":3,"to":8}]'::jsonb, 20),
  ('english',     '英文班',     'tuition',  '[{"from":11,"to":1},{"from":2,"to":4},{"from":5,"to":7},{"from":8,"to":10}]'::jsonb, 30),
  ('mat_primary', '國小教材費', 'material', '[{"from":9,"to":2},{"from":3,"to":8}]'::jsonb, 40),
  ('mat_english', '英文教材費', 'material', '[{"from":11,"to":1},{"from":2,"to":4},{"from":5,"to":7},{"from":8,"to":10}]'::jsonb, 50)
) v(code, name, item_type, period_rule, sort_order)
where not exists (select 1 from public.fee_programs);
