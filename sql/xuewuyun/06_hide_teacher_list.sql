-- 基翔學務雲：登入前不再公開老師名單（老師、管理員改成自己輸入帳號）
-- 雲點名、學習通沒登入時一律轉到學務雲登入頁，不再需要匿名讀取老師名單
revoke execute on function public.list_teachers() from anon, public;
grant execute on function public.list_teachers() to authenticated;
