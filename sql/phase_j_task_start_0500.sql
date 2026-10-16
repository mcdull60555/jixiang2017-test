-- 基翔小學通：階段 J（同步正式版 2026-10-15 的改動）
-- 1. 預約派發的項目在發布日期當天凌晨 05:00（台灣時間）才生效：學生看得到、能送審、計入跑馬燈
-- 2. 聯絡簿顯示範圍改為過去 7 天（與每日清理一致）
-- 用法：SQL Editor 貼上 → Run（測試專案、正式專案都要跑；可重複執行）

-- 學生只看得到「已生效」的項目
alter policy tasks_select on public.tasks
  using (((class_id = ( SELECT private.my_class_id() AS my_class_id))
          OR ((student_id = ( SELECT private.my_student_id() AS my_student_id))
              AND (date <= (((now() AT TIME ZONE 'Asia/Taipei'::text) - interval '5 hours'))::date))));

CREATE OR REPLACE FUNCTION public.student_submit(p_ids text[])
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $function$
declare
  v_sid text := (select private.my_student_id());
  v_today date := ((now() at time zone 'Asia/Taipei') - interval '5 hours')::date;  -- 生效日（05:00 換日）
  v_id text; r public.tasks%rowtype; v_name text;
  v_changed int := 0; v_skipped text[] := '{}';
begin
  if v_sid is null then raise exception 'only students can submit' using errcode = '42501'; end if;
  if p_ids is null or cardinality(p_ids) = 0 or cardinality(p_ids) > 500 then
    raise exception 'ids must contain 1 to 500 items' using errcode = '22023';
  end if;
  select s.name into v_name from public.students s where s.id = v_sid;
  foreach v_id in array p_ids loop
    select * into r from public.tasks t where t.id = v_id for update;
    if not found or r.student_id <> v_sid or r.teacher_status = '已完成' or r.date > v_today then
      v_skipped := v_skipped || v_id; continue;
    end if;
    if not (r.student_checked and r.pending_review) then
      update public.tasks set student_checked = true, pending_review = true, submitted_at = now() where id = v_id;
      insert into public.submit_log (action, task_id, student_id, student_name, type, subject, title, date, class_id)
      values ('submit', r.id, r.student_id, coalesce(v_name, ''), r.type, r.subject, r.title, r.date, r.class_id);
      v_changed := v_changed + 1;
    end if;
  end loop;
  return jsonb_build_object('changed', v_changed, 'skipped', to_jsonb(v_skipped));
end $function$;

CREATE OR REPLACE FUNCTION public.get_champions()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
declare
  v_today date := (now() at time zone 'Asia/Taipei')::date;
  v_active date := ((now() at time zone 'Asia/Taipei') - interval '5 hours')::date;  -- 項目生效日（05:00 換日）
  v_dow int := extract(isodow from (now() at time zone 'Asia/Taipei'))::int;
  v_start date; v_end date; v_classes text[];
begin
  if (select private.is_teacher()) then
    v_classes := array[(select private.my_class_id())];
  elsif (select private.my_student_id()) is not null then
    v_classes := array(select cs.class_id from public.class_students cs where cs.student_id = (select private.my_student_id()));
  else
    v_classes := '{}';
  end if;
  v_start := v_today - (v_dow - 1) - 7;
  v_end := v_start + 6;
  return jsonb_build_object('weekStart', v_start, 'weekEnd', v_end, 'list', coalesce((
    select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'school', c.school, 'grade', c.grade,
                                        'avatar', c.avatar, 'finishedAt', c.finished_at)
                     order by (c.finished_at is null), c.finished_at, c.name)
      from (
        select s.id, s.name, s.school, s.grade, s.avatar, max(coalesce(t.done_at, t.reviewed_at)) as finished_at
          from public.students s
          join public.tasks t on t.student_id = s.id
         where t.class_id = any(v_classes) and t.date between v_start and v_end and t.date <= v_active
         group by s.id, s.name, s.school, s.grade, s.avatar
        having bool_and(t.teacher_status = '已完成')
      ) c
  ), '[]'::jsonb));
end $function$;

-- 聯絡簿：顯示今天起往前 7 天（超過 7 天的每日清理會刪除）
CREATE OR REPLACE FUNCTION public.get_contact_book()
 RETURNS TABLE(id text, class_id text, date date, weekday text, content text, items jsonb)
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
declare
  v_student public.students%rowtype;
  v_today date := (now() at time zone 'Asia/Taipei')::date;
begin
  if (select private.is_teacher()) then
    return query
      select cb.id, cb.class_id, cb.date, cb.weekday, cb.content, cb.items
        from public.contact_book cb
       where cb.class_id = (select private.my_class_id()) and cb.date >= v_today - 7
       order by cb.date, cb.id;
    return;
  end if;
  select s.* into v_student from public.students s where s.id = (select private.my_student_id());
  if not found then return; end if;
  return query
    select f.id, f.class_id, f.date, f.weekday,
           (select coalesce(string_agg(x.n::text || '. ' || (x.it ->> 'text'), E'\n' order by x.n), '')
              from (select e.it, row_number() over (order by e.ord) as n
                      from jsonb_array_elements(f.items) with ordinality as e(it, ord)) x),
           f.items
      from (
        select cb.id, cb.class_id, cb.date, cb.weekday,
               coalesce((
                 select jsonb_agg(e.it order by e.ord)
                   from jsonb_array_elements(cb.items) with ordinality as e(it, ord)
                  where coalesce(jsonb_array_length(e.it -> 'targets'), 0) = 0
                     or exists (select 1 from jsonb_array_elements(e.it -> 'targets') tg
                                 where tg ->> 'grade' = v_student.grade
                                   and (tg -> 'schools') @> to_jsonb(v_student.school))
               ), '[]'::jsonb) as items
          from public.contact_book cb
         where cb.date >= v_today - 7
           and cb.class_id in (select cs.class_id from public.class_students cs where cs.student_id = v_student.id)
      ) f
     where jsonb_array_length(f.items) > 0
     order by f.date, f.id;
end $function$;
