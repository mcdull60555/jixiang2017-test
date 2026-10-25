-- 國中班科目（英文、數學、社會；國三另有總複習）
alter table public.fee_enrollments add column if not exists subjects text[] not null default '{}';
