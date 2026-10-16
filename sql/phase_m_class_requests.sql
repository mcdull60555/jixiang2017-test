-- 基翔學習通：階段 M　老師申請新增班級 → 管理者處理
-- 用法：SQL Editor 貼上 → Run（可重複執行）

create table if not exists public.class_requests (
  id bigint generated always as identity primary key,
  teacher_id uuid not null,              -- 老師帳號 id（老師被刪除後申請紀錄保留，畫面顯示「已刪除的老師」）
  class_name text not null check (length(btrim(class_name)) between 1 and 50),
  note text not null default '' check (length(note) <= 300),
  status text not null default 'pending' check (status in ('pending', 'done', 'rejected')),
  created_class_id text,
  created_at timestamptz not null default now(),
  handled_at timestamptz
);
create index if not exists class_requests_status_idx on public.class_requests (status, created_at);

alter table public.class_requests enable row level security;
do $p$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'class_requests' and policyname = 'class_requests_select') then
    create policy class_requests_select on public.class_requests for select to authenticated
      using (teacher_id = (select auth.uid()) or (select private.is_admin()));
  end if;
end $p$;
revoke all on public.class_requests from anon, authenticated;
grant select on public.class_requests to authenticated;

-- 老師送出申請（同一位老師同名的申請還在處理中就不重複建立）
create or replace function public.teacher_request_class(p_name text, p_note text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_name text := btrim(coalesce(p_name, '')); v_id bigint;
begin
  if not (select private.is_teacher()) then raise exception 'only teachers can request classes' using errcode = '42501'; end if;
  if v_name = '' or length(v_name) > 50 then raise exception 'class name must be 1 to 50 characters' using errcode = '22023'; end if;
  if exists (select 1 from public.classes c where c.name = v_name) then
    raise exception 'class already exists' using errcode = '22023';
  end if;
  select r.id into v_id from public.class_requests r
   where r.teacher_id = auth.uid() and r.class_name = v_name and r.status = 'pending';
  if v_id is null then
    insert into public.class_requests (teacher_id, class_name, note)
    values (auth.uid(), v_name, left(btrim(coalesce(p_note, '')), 300))
    returning id into v_id;
  end if;
  return jsonb_build_object('id', v_id);
end $$;

-- 管理者處理：approve＝建立班級並指派給申請的老師；reject＝不處理
create or replace function public.admin_handle_class_request(p_id bigint, p_action text, p_name text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.class_requests%rowtype; v_name text; v_cid text; v_sort int;
begin
  if not (select private.is_admin()) then raise exception 'admin only' using errcode = '42501'; end if;
  select * into r from public.class_requests where id = p_id for update;
  if not found or r.status <> 'pending' then raise exception 'request not found or already handled' using errcode = '22023'; end if;
  if p_action = 'reject' then
    update public.class_requests set status = 'rejected', handled_at = now() where id = p_id;
    return jsonb_build_object('status', 'rejected');
  elsif p_action <> 'approve' then
    raise exception 'invalid action' using errcode = '22023';
  end if;
  v_name := btrim(coalesce(nullif(btrim(coalesce(p_name, '')), ''), r.class_name));
  select c.id into v_cid from public.classes c where c.name = v_name;
  if v_cid is null then
    select coalesce(max(sort_order), 0) + 1 into v_sort from public.classes;
    insert into public.classes (name, sort_order) values (v_name, v_sort) returning id into v_cid;
  end if;
  if exists (select 1 from public.profiles where id = r.teacher_id and role = 'teacher') then
    insert into public.teacher_classes (teacher_id, class_id) values (r.teacher_id, v_cid) on conflict do nothing;
    update public.profiles set class_id = v_cid where id = r.teacher_id and class_id is null;
  end if;
  update public.class_requests set status = 'done', handled_at = now(), created_class_id = v_cid where id = p_id;
  return jsonb_build_object('status', 'done', 'class_id', v_cid);
end $$;

revoke all on function public.teacher_request_class(text, text), public.admin_handle_class_request(bigint, text, text) from public, anon;
grant execute on function public.teacher_request_class(text, text), public.admin_handle_class_request(bigint, text, text) to authenticated, service_role;

-- 資料指紋加上班級申請（管理者處理後，老師畫面會自動更新）
create or replace function public.get_data_version()
 returns text language sql stable set search_path to ''
as $function$
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
    (select coalesce(md5(string_agg(concat_ws(',', id::text, login_id, display_name, class_id, sort_order::text, array_to_string(allowed_grades, '/')), ';' order by id)), '') from public.profiles),
    (select coalesce(md5(string_agg(teacher_id::text || ',' || class_id, ';' order by teacher_id, class_id)), '') from public.teacher_classes),
    (select coalesce(md5(string_agg(id::text || ',' || status, ';' order by id)), '') from public.class_requests)
  ))
$function$;
