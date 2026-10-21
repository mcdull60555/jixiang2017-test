-- 學務雲：老師批次設定學生密碼時，也同步更新可查看的加密版本（改用 private.set_pin）
create or replace function public.teacher_set_student_passwords(p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r jsonb; v_class text := (select private.my_class_id()); v_n int := 0; v_uid uuid;
begin
  if not (select private.is_teacher()) or v_class is null then
    raise exception 'only teachers can set passwords' using errcode = '42501';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 or jsonb_array_length(p_rows) > 500 then
    raise exception 'rows must be an array of 1 to 500 items' using errcode = '22023';
  end if;
  for r in select value from jsonb_array_elements(p_rows) loop
    if coalesce(r ->> 'pwd', '') !~ '^[0-9]{4}$' then raise exception 'password must be 4 digits' using errcode = '22023'; end if;
    select s.auth_user_id into v_uid
      from public.students s
     where s.id = r ->> 'id' and s.auth_user_id is not null
       and exists (select 1 from public.class_students cs where cs.student_id = s.id and cs.class_id = v_class);
    if v_uid is not null then
      perform private.set_pin(v_uid, r ->> 'pwd');
      v_n := v_n + 1;
    end if;
  end loop;
  return jsonb_build_object('updated', v_n);
end $$;
