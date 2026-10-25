-- 價目表增加「科目」（國中班按科目計價）；沒有科目的班別 subject 為空字串
alter table public.fee_prices add column if not exists subject text not null default '';
alter table public.fee_prices drop constraint if exists fee_prices_grade_program_code_billing_key;
alter table public.fee_prices add constraint fee_prices_grade_program_billing_subject_key unique (grade, program_code, billing, subject);

-- 國中班依「選幾科」計價：subject 欄位存科數（'1'～'4'），金額是該科數的總價（月繳）。2023 補習班價目表
delete from public.fee_prices where program_code='junior';
insert into public.fee_prices (grade, program_code, billing, subject, amount)
select g, 'junior', 'month', n::text, a from (values
 ('國一',1,3000),('國一',2,5500),('國一',3,7500),('國一',4,9000),
 ('國二',1,3000),('國二',2,5500),('國二',3,7500),('國二',4,9000),
 ('國三',1,3500),('國三',2,6500),('國三',3,9000),('國三',4,11000)) v(g,n,a);
