-- 基翔小學通 Supabase 測試專案：階段 F 老師帳號可排序（需先執行階段 E；可重複執行）
alter table public.profiles add column if not exists sort_order int not null default 1000000;
grant select (sort_order) on public.profiles to authenticated;

-- 登入前的老師名單：依管理者排的順序
create or replace function public.list_teachers()
returns table(login_id text, display_name text, class_id text, class_name text)
language sql stable security definer set search_path = '' as $$
  select p.login_id, coalesce(p.display_name, p.login_id), p.class_id, c.name
    from public.profiles p left join public.classes c on c.id = p.class_id
   where p.role = 'teacher' and p.login_id is not null
   order by p.sort_order, p.created_at, p.login_id
$$;
revoke all on function public.list_teachers() from public;
grant execute on function public.list_teachers() to anon, authenticated;

-- 管理者一次存下老師的新順序（依傳入的 id 順序）
create or replace function public.admin_reorder_teachers(p_ids uuid[])
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not (select private.is_admin()) then raise exception 'admin only' using errcode = '42501'; end if;
  update public.profiles p set sort_order = t.ord
    from unnest(p_ids) with ordinality as t(id, ord)
   where p.id = t.id and p.role = 'teacher';
end $$;
revoke all on function public.admin_reorder_teachers(uuid[]) from public, anon;
grant execute on function public.admin_reorder_teachers(uuid[]) to authenticated;
