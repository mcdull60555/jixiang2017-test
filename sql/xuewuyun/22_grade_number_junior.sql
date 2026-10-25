-- 國中、高中、幼稚園年級也能建立學生：
-- 1) private.grade_number：國一～國三＝7～9、高一～高三＝10～12、大班＝0（用來算「國小一年級入學學年」與帳號）
-- 2) 學習通 grades 表（students.grade 的外鍵）補上名冊年級清單裡有、但還沒有的年級；之後名冊新增年級也會同步補一筆
create or replace function private.grade_number(p_grade text)
returns integer language sql immutable set search_path = '' as $$
  select case
    when coalesce(p_grade, '') ~ '^國[一二三]' then 6 + case substr(p_grade, 2, 1) when '一' then 1 when '二' then 2 else 3 end
    when coalesce(p_grade, '') ~ '^高[一二三]' then 9 + case substr(p_grade, 2, 1) when '一' then 1 when '二' then 2 else 3 end
    when coalesce(p_grade, '') ~ '^大班' then 0
    when coalesce(p_grade, '') ~ '^中班' then -1
    when coalesce(p_grade, '') ~ '^小班' then -2
    else case left(coalesce(p_grade, ''), 1)
      when '一' then 1 when '二' then 2 when '三' then 3
      when '四' then 4 when '五' then 5 when '六' then 6 end
  end
$$;

insert into public.grades (name, avatar, sort_order)
select g.name,
       (array['🐥','🦁','🐯','🐲','🦅','🦈','🐬','🦄','🐢','🦋'])[1 + (row_number() over (order by g.sort_order) - 1)::int % 10],
       (select coalesce(max(sort_order), 0) from public.grades) + row_number() over (order by g.sort_order)
  from public.grade_list g
 where not exists (select 1 from public.grades x where x.name = g.name);

do $mig$
declare d text;
begin
  d := pg_get_functiondef('public.admin_add_grade'::regproc);
  d := replace(d, 'update public.grade_list set active = true where name = n; return ''OK'';',
    'update public.grade_list set active = true where name = n; insert into public.grades (name, avatar, sort_order) select n, ''🦔'', (select coalesce(max(sort_order), 0) + 1 from public.grades) where not exists (select 1 from public.grades where name = n); return ''OK'';');
  d := replace(d, 'values (n, (select coalesce(max(sort_order), 0) + 1 from public.grade_list));',
    'values (n, (select coalesce(max(sort_order), 0) + 1 from public.grade_list)); insert into public.grades (name, avatar, sort_order) select n, ''🦔'', (select coalesce(max(sort_order), 0) + 1 from public.grades) where not exists (select 1 from public.grades where name = n);');
  if d not like '%public.grades%' then raise exception 'patch failed'; end if;
  execute d;
end $mig$;
