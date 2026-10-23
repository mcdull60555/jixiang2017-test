-- ============================================================
-- 基翔學務雲 階段 6c：請假折抵試算（先在測試專案 jixiang-supabase-test 執行，需先執行 07_tuition.sql）
--
-- fee_leave_rebate(學生, 月份, 計算基數)：依雲點名的請假紀錄算出該月的請假折抵。
--   規則（使用者 2026-10-23 確認）：
--   1. 連續：以雲點名點名紀錄「請假」的上課日連續滿 3 天才折抵；週六日不影響連續；
--      遇國定假日或颱風日（雲點名 rc_special_days 設為 holiday）就中斷。
--   2. 連續滿 3 天的那一段，每一天都折抵。
--   3. 每天折抵 = 計算基數（月學費）÷ 當月平日天數（週一～週五，國定假日、颱風日仍算）。
--   4. 該段請假日落在「預約請假」且原因含「出國」者，當天折抵金額折半。
--   5. 總額先四捨五入，再取最接近的 5 的倍數（個位數 0 或 5）。
--   事假、病假同樣處理。
-- 回傳：{ month, class_days, per_day, segments:[{start,end,days,abroad_days,amount}], total, covered, data_from }
--   covered = false 表示雲點名點名紀錄（只保留 40 天）已不完整涵蓋該月，結果可能偏低，需人工確認。
-- 只有可修改學費的人（管理員、被開通的老師）能呼叫。
-- ============================================================

create or replace function public.fee_leave_rebate(p_student_id text, p_month date, p_base integer)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_start date := date_trunc('month', p_month)::date;
  v_end date := (date_trunc('month', p_month) + interval '1 month' - interval '1 day')::date;
  v_n integer;
  v_per numeric;
  v_min date;
  r record;
  v_rs date; v_re date; v_len integer := 0; v_ab integer := 0; v_w numeric := 0;
  v_segs jsonb := '[]'::jsonb;
  v_sum numeric := 0;
begin
  if not (select private.fee_can_edit()) then raise exception 'no fee edit permission' using errcode = '42501'; end if;
  if p_month is null then raise exception 'month required' using errcode = '22023'; end if;

  select count(*) into v_n from generate_series(v_start, v_end, interval '1 day') g where extract(isodow from g) <= 5;
  v_per := case when coalesce(p_base, 0) > 0 then p_base::numeric / v_n else 0 end;
  select min(date) into v_min from public.rc_attendance;

  for r in
    select g::date as d,
           exists (select 1 from public.rc_special_days sd where sd.date = g::date and sd.type = 'holiday') as hol,
           exists (select 1 from public.rc_attendance a
                    where a.student_id = p_student_id and a.date = g::date and a.status = 'leave') as lv,
           exists (select 1 from public.rc_leave_bookings b
                    where b.student_id = p_student_id and g::date between b.start_date and b.end_date
                      and b.reason like '%出國%') as abroad
      from generate_series(v_start, v_end, interval '1 day') g
     where extract(isodow from g) <= 5
     order by g
  loop
    if r.lv and not r.hol then
      if v_rs is null then v_rs := r.d; end if;
      v_re := r.d; v_len := v_len + 1;
      if r.abroad then v_ab := v_ab + 1; v_w := v_w + 0.5; else v_w := v_w + 1; end if;
    else
      if v_len >= 3 then
        v_segs := v_segs || jsonb_build_object('start', v_rs, 'end', v_re, 'days', v_len, 'abroad_days', v_ab, 'amount', round(v_w * v_per, 2));
        v_sum := v_sum + v_w * v_per;
      end if;
      v_rs := null; v_re := null; v_len := 0; v_ab := 0; v_w := 0;
    end if;
  end loop;
  if v_len >= 3 then
    v_segs := v_segs || jsonb_build_object('start', v_rs, 'end', v_re, 'days', v_len, 'abroad_days', v_ab, 'amount', round(v_w * v_per, 2));
    v_sum := v_sum + v_w * v_per;
  end if;

  return jsonb_build_object(
    'month', to_char(v_start, 'YYYY-MM'), 'class_days', v_n, 'per_day', round(v_per, 2),
    'segments', v_segs, 'total', (round(v_sum / 5) * 5)::integer,
    'covered', v_min is not null and v_min <= v_start, 'data_from', v_min);
end $$;

revoke all on function public.fee_leave_rebate(text, date, integer) from public, anon;
grant execute on function public.fee_leave_rebate(text, date, integer) to authenticated;
