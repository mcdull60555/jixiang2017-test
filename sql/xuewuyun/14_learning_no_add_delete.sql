-- 學習通不再新增／刪除學生：學生一律由「學生名冊」(admin_save_student) 建立與停用。
-- 老師在學習通仍可修改既有學生的姓名、學校、年級、頭像、密碼（與名冊共用 students 表，自動同步）。
create or replace function public.teacher_create_students(p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  raise exception '學習通不能新增學生，請到「學生名冊」新增' using errcode = '42501';
end $$;

create or replace function public.teacher_delete_students(p_ids text[])
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  raise exception '學習通不能刪除學生，請到「學生名冊」處理' using errcode = '42501';
end $$;
