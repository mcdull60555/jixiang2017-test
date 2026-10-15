-- 基翔小學通 Supabase 測試專案：負載測試假資料（只放測試專案！）
-- 用法：SQL Editor 貼上 → Run。想改規模，改下面兩個數字。
--   n_students：假學生人數   n_items：每位學生的作業／考卷數（整個班項目數 = 人數 × 項目數）
-- 假學生編號都以 load_ 開頭，不含登入帳號（只用來測資料量與載入速度）。
-- 清除：執行最下面的清除語句。

do $$
declare
  n_students int := 100;
  n_items    int := 50;
  v_class    text := (select id from public.classes order by sort_order limit 1);
  v_grades   text[] := (select array_agg(name order by sort_order) from public.grades);
  v_subjects text[] := (select array_agg(name order by sort_order) from public.subjects);
  v_today    date := (now() at time zone 'Asia/Taipei')::date;
begin
  if v_class is null or v_grades is null or v_subjects is null then
    raise exception '需要先有班級、年級、科目';
  end if;

  insert into public.students (id, name, school, grade, class_name)
  select 'load_' || g, '負載生' || lpad(g::text, 3, '0'), '測試國小', v_grades[1 + (g % cardinality(v_grades))], ''
    from generate_series(1, n_students) g
  on conflict do nothing;

  insert into public.class_students (class_id, student_id)
  select v_class, 'load_' || g from generate_series(1, n_students) g
  on conflict do nothing;

  insert into public.tasks (student_id, class_id, type, subject, title, date)
  select 'load_' || s, v_class,
         case when i % 5 = 0 then '考卷' else '作業' end,
         v_subjects[1 + (i % cardinality(v_subjects))],
         '負載測試項目' || i,
         v_today - (i % 7)
    from generate_series(1, n_students) s, generate_series(1, n_items) i
  on conflict do nothing;
end $$;

-- 看結果與資料庫大小
select (select count(*) from public.students where id like 'load_%') as 假學生,
       (select count(*) from public.tasks where student_id like 'load_%') as 假項目,
       pg_size_pretty(pg_database_size(current_database())) as 資料庫大小;

-- ===== 清除（測完再執行；刪學生會連動刪掉他們的項目與班級關聯）=====
-- delete from public.students where id like 'load_%';
