-- ============================================================
-- 基翔學務雲：老師職稱（老師／主任）
-- 主任：
--   1. 學習通可以切換到任何班級「瀏覽」；只有自己負責的班級可以修改
--      （派發、審核、聯絡簿、學生資料、學生密碼都一樣）。
--   2. 可以查看全部學生的密碼（和管理員相同）。
-- 唯讀由資料庫觸發器把關：主任目前所在的班級不是自己負責的班級時，所有寫入都會被拒絕。
-- 先在測試專案 jixiang-supabase-test 執行
-- ============================================================

alter table public.profiles add column if not exists title text not null default '老師';
alter table public.profiles add constraint profiles_title_check check (title in ('老師', '主任'));

-- 目前登入者是不是主任
create or replace function private.is_director()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles p
                  where p.id = (select auth.uid()) and p.role = 'teacher' and p.title = '主任')
$$;

-- 目前所在的班級是不是自己負責的班級（一般老師一定是；主任瀏覽別班時不是）
create or replace function private.in_own_class()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles p
                   join public.teacher_classes tc on tc.teacher_id = p.id and tc.class_id = p.class_id
                  where p.id = (select auth.uid()))
$$;

-- 主任瀏覽別班時禁止寫入（學生密碼表只擋改別人的，主任改自己的密碼不受影響）
create or replace function private.guard_director_readonly()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (select private.is_director()) and not (select private.in_own_class()) then
    if tg_table_name = 'login_pins' and tg_level = 'ROW'
       and coalesce(new.user_id, old.user_id) = (select auth.uid()) then
      return coalesce(new, old);
    end if;
    raise exception 'director read only: this class is not assigned to you' using errcode = '42501';
  end if;
  if tg_level = 'ROW' then return coalesce(new, old); end if;
  return null;
end $$;

create trigger jx_director_readonly before insert or update or delete on public.tasks
  for each statement execute function private.guard_director_readonly();
create trigger jx_director_readonly before insert or update or delete on public.contact_book
  for each statement execute function private.guard_director_readonly();
create trigger jx_director_readonly before insert or update or delete on public.class_students
  for each statement execute function private.guard_director_readonly();
create trigger jx_director_readonly before insert or update or delete on public.students
  for each statement execute function private.guard_director_readonly();
create trigger jx_director_readonly before insert or update or delete on private.login_pins
  for each row execute function private.guard_director_readonly();

-- 切換班級：一般老師只能切到自己負責的班；主任可以切到任何班（別班只能瀏覽）
create or replace function public.teacher_switch_class(p_class text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not (select private.is_teacher()) then raise exception 'only teachers can switch class' using errcode = '42501'; end if;
  if (select private.is_director()) then
    if not exists (select 1 from public.classes where id = p_class) then
      raise exception 'class not found' using errcode = '22023';
    end if;
  elsif not exists (select 1 from public.teacher_classes where teacher_id = auth.uid() and class_id = p_class) then
    raise exception 'class not assigned to this teacher' using errcode = '42501';
  end if;
  update public.profiles set class_id = p_class where id = auth.uid();
end $$;

-- 查看學生密碼：管理員、主任看全部；老師限自己負責班級
create or replace function public.reveal_student_pin(p_student_id text)
returns text language plpgsql security definer set search_path = '' as $$
declare v_uid uuid; v_enc bytea;
begin
  if not (
    (select private.is_admin())
    or (select private.is_director())
    or exists (
      select 1 from public.teacher_classes tc
        join public.class_students cs on cs.class_id = tc.class_id
       where tc.teacher_id = (select auth.uid()) and cs.student_id = p_student_id)
  ) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select s.auth_user_id into v_uid from public.students s where s.id = p_student_id;
  select lp.pin_enc into v_enc from private.login_pins lp where lp.user_id = v_uid;
  if v_enc is null then return null; end if;
  return extensions.pgp_sym_decrypt(v_enc, private.pin_key());
end $$;

-- 管理員：設定職稱
create or replace function public.admin_set_teacher_title(p_id uuid, p_title text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not (select private.is_admin()) then raise exception 'admin only' using errcode = '42501'; end if;
  if p_title is null or p_title not in ('老師', '主任') then raise exception 'unknown title' using errcode = '22023'; end if;
  if not exists (select 1 from public.profiles where id = p_id and role = 'teacher') then
    raise exception 'teacher not found' using errcode = '22023';
  end if;
  update public.profiles set title = p_title where id = p_id;
end $$;
revoke execute on function public.admin_set_teacher_title(uuid, text) from anon, public;
grant execute on function public.admin_set_teacher_title(uuid, text) to authenticated;
