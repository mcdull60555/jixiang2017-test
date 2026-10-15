-- 基翔小學通 Supabase 測試專案：階段 H 輕量資料版本（省流量）
-- 需先執行階段 E、F、G（可重複執行）。
-- 輪詢時只問這個函式（回傳一段很短的指紋），資料沒變就不必重抓整份資料。
-- 以呼叫者身分執行，所以各人只會算到自己看得到的資料（學生不會被別人的資料影響）。
create or replace function public.get_data_version()
returns text language sql stable security invoker set search_path = '' as $$
  select md5(concat_ws('|',
    (select coalesce(md5(string_agg(concat_ws(',', id, class_id, student_id, type, subject, title, date::text, student_checked::text,
        pending_review::text, teacher_status, submitted_at::text, done_at::text, reviewed_at::text), ';' order by id)), '') from public.tasks),
    (select coalesce(md5(string_agg(concat_ws(',', id, class_id, date::text, weekday, content, items::text), ';' order by id)), '') from public.get_contact_book()),
    (select coalesce(md5(string_agg(concat_ws(',', id, name, school, grade, class_name, avatar), ';' order by id)), '') from public.students),
    (select coalesce(md5(string_agg(class_id || ',' || student_id, ';' order by class_id, student_id)), '') from public.class_students),
    (select coalesce(md5(string_agg(id || ',' || name || ',' || sort_order::text, ';' order by id)), '') from public.classes),
    (select coalesce(md5(string_agg(name || ',' || avatar || ',' || sort_order::text, ';' order by name)), '') from public.grades),
    (select coalesce(md5(string_agg(name || ',' || sort_order::text, ';' order by name)), '') from public.subjects),
    (select coalesce(count(*)::text || ':' || max(id)::text, '') from public.submit_log),
    (select coalesce(md5(string_agg(concat_ws(',', id::text, login_id, display_name, class_id, sort_order::text, array_to_string(allowed_grades, '/')), ';' order by id)), '') from public.profiles)
  ))
$$;
revoke all on function public.get_data_version() from public, anon;
grant execute on function public.get_data_version() to authenticated;
