-- ============================================================
-- 基翔學務雲 階段 6：刪除學費單（先在測試專案 jixiang-supabase-test 執行，需先執行 07_tuition.sql）
-- fee_delete_bills(ids)：只能刪「草稿」與「已作廢」的學費單（明細隨單刪除）。
--   已發布的單要先作廢，才能刪除，避免誤刪家長已看到的帳單。
-- 可修改學費的人（管理員、被開通的老師）才能呼叫。
-- 回傳 { deleted: 刪除張數, skipped: 略過張數 }
-- ============================================================
create or replace function public.fee_delete_bills(p_ids text[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_n integer; v_total integer;
begin
  if not (select private.fee_can_edit()) then raise exception 'no fee edit permission' using errcode = '42501'; end if;
  v_total := coalesce(array_length(p_ids, 1), 0);
  with d as (
    delete from public.fee_bills where id = any(p_ids) and status in ('draft', 'void') returning 1
  ) select count(*) into v_n from d;
  return jsonb_build_object('deleted', v_n, 'skipped', v_total - v_n);
end $$;
revoke all on function public.fee_delete_bills(text[]) from public, anon;
grant execute on function public.fee_delete_bills(text[]) to authenticated;
