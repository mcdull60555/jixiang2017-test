-- 價目表增加「科目」（國中班按科目計價）；沒有科目的班別 subject 為空字串
alter table public.fee_prices add column if not exists subject text not null default '';
alter table public.fee_prices drop constraint if exists fee_prices_grade_program_code_billing_key;
alter table public.fee_prices add constraint fee_prices_grade_program_billing_subject_key unique (grade, program_code, billing, subject);
