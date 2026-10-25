-- 晚餐管理：清掉 2026-09 以前的資料，從 9 月開始沿用；9 月補固定星期讓取消／加訂標記可用
delete from public.meal_orders where day < '2026-09-01';
delete from public.meal_ledger where ym < '2026-09';
delete from public.meal_months where ym < '2026-09';
delete from public.meal_days   where day < '2026-09-01';
insert into public.meal_schedules(student_id, effective_from, weekdays)
select s.student_id, date '2026-09-01', s.weekdays
from (select distinct on (student_id) student_id, weekdays, effective_from from public.meal_schedules order by student_id, effective_from) s
where s.effective_from > date '2026-09-01'
on conflict do nothing;
