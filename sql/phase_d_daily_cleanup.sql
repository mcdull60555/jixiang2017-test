-- 基翔小學通 Supabase 測試專案：階段 D 每日自動清理（改為 7 天；需先執行階段 E）
-- 用法：Supabase 後台 → SQL Editor → 貼上 → Run（可重複執行）
-- 規則：送審紀錄保留 7 天且最多 1000 筆；聯絡簿超過 7 天刪除；100% 完成（歸檔）的項目超過 7 天刪除。每天台灣時間 03:00 執行。

create extension if not exists pg_cron with schema pg_catalog;

create or replace function private.cleanup_old_records()
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_log int; v_cap int; v_cb int; v_task int;
  v_today date := (now() at time zone 'Asia/Taipei')::date;
begin
  delete from public.submit_log where at < now() - interval '7 days';
  get diagnostics v_log = row_count;
  delete from public.submit_log
   where id in (select id from public.submit_log order by at desc, id desc offset 1000);
  get diagnostics v_cap = row_count;
  delete from public.contact_book where date < v_today - 7;
  get diagnostics v_cb = row_count;
  -- 歸檔項目：同一班、同一項（類型／科目／名稱／派發日）所有學生都已完成，且派發日超過 7 天
  delete from public.tasks t
   using (select class_id, type, subject, title, date from public.tasks
           group by class_id, type, subject, title, date
          having bool_and(teacher_status = '已完成') and date < v_today - 7) a
   where t.class_id = a.class_id and t.type = a.type and t.subject = a.subject and t.title = a.title and t.date = a.date;
  get diagnostics v_task = row_count;
  return jsonb_build_object('submit_log_old', v_log, 'submit_log_over_cap', v_cap, 'contact_book', v_cb, 'archived_tasks', v_task);
end $$;
revoke all on function private.cleanup_old_records() from public, anon, authenticated;

select cron.unschedule(jobid) from cron.job where jobname = 'jixiang-daily-cleanup';
select cron.schedule('jixiang-daily-cleanup', '0 19 * * *', $job$select private.cleanup_old_records()$job$);  -- UTC 19:00 = 台灣 03:00

-- 檢查：select jobname, schedule, active from cron.job;
-- 手動試跑：select private.cleanup_old_records();
