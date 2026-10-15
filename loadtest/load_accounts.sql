-- 為負載測試的假學生（load_1～load_100）建立可登入帳號，密碼都是 0000。可重複執行。
do $$
declare g int; v_id text; v_uid uuid;
begin
  for g in 1..100 loop
    v_id := 'load_' || g;
    if exists (select 1 from public.students where id = v_id and auth_user_id is null) then
      v_uid := private.create_auth_user(v_id || '@school.test');
      insert into public.profiles (id, role, student_id) values (v_uid, 'student', v_id);
      perform private.set_pin(v_uid, '0000');
      update public.students set auth_user_id = v_uid where id = v_id;
    end if;
  end loop;
end $$;
select count(*) as 可登入的假學生 from public.students where id like 'load_%' and auth_user_id is not null;

-- 清除（測完執行）：刪帳號後，學生資料與項目另用 load_test_seed.sql 最下面的清除語句
-- delete from auth.users where email like 'load\_%@school.test';
