-- 學生帳號：在學就建立（家長端看學費單用）；學習通是否開通只決定能不能進學習通。
-- 1) admin_save_student：在學或開啟學習通且還沒有帳號時，建立帳號（需 4 位數密碼）
-- 2) login_attempt：只擋離班(不在學)的學生，不再因為沒開通學習通就擋登入
do $mig$
declare d text;
begin
  d := pg_get_functiondef('public.admin_save_student'::regproc);
  d := replace(d, 'v_uid uuid; v_code text;', 'v_uid uuid; v_code text; v_act boolean;');
  d := replace(d, 'select auth_user_id, account_code into v_uid, v_code from public.students where id = v_id;', 'select auth_user_id, account_code, active into v_uid, v_code, v_act from public.students where id = v_id;');
  d := replace(d, 'if v_learning and v_uid is null then', 'if (v_learning or v_act) and v_uid is null then');
  if d not like '%v_learning or v_act%' then raise exception 'patch failed admin_save_student'; end if;
  execute d;
  d := pg_get_functiondef('public.login_attempt'::regproc);
  d := replace(d, '(not s.learning_enabled or not s.active)', 'not s.active');
  if d like '%learning_enabled%' then raise exception 'patch failed login_attempt'; end if;
  execute d;
end $mig$;
