-- 國中以上（年級以「國」「高」開頭）沒有接回需求，不進雲點名。
create or replace function private.students_no_rollcall_jh() returns trigger language plpgsql set search_path = '' as $$
begin
  if new.grade ~ '^(國|高)' then new.in_rollcall := false; end if;
  return new;
end $$;
drop trigger if exists students_no_rollcall_jh on public.students;
create trigger students_no_rollcall_jh before insert or update of grade, in_rollcall on public.students
  for each row execute function private.students_no_rollcall_jh();
update public.students set in_rollcall = false where grade ~ '^(國|高)' and in_rollcall;
