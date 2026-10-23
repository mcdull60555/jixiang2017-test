-- ============================================================
-- 基翔學務雲 階段 6a：學費管理資料表（先在測試專案 jixiang-supabase-test 執行）
-- 學費單 = 一位學生 × 一個梯次 + 多列明細。
-- 權限：管理員全部；主任唯讀；老師預設看不到，管理員開通「學費權限」後可看可改；
--       學生・家長只能看自己「已發布」的學費單（家長端畫面之後再做）。
-- 收款帳號等實際資料不放在這個檔案（repo 公開），請在學費管理的「設定」輸入，
-- 或執行 D:\Claude\基翔學務雲-資料庫\測試專案_學費設定.sql。
-- 只新增，不刪除既有資料。
-- ============================================================

-- ---------- 學費權限 ----------
alter table public.profiles add column if not exists fee_access boolean not null default false;

create or replace function private.fee_can_view()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles p
                  where p.id = (select auth.uid())
                    and (p.role = 'admin' or (p.role = 'teacher' and (p.title = '主任' or p.fee_access))))
$$;
create or replace function private.fee_can_edit()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles p
                  where p.id = (select auth.uid())
                    and (p.role = 'admin' or (p.role = 'teacher' and p.fee_access)))
$$;
create or replace function private.fee_my_student_id()
returns text language sql stable security definer set search_path = '' as $$
  select p.student_id from public.profiles p where p.id = (select auth.uid()) and p.role = 'student'
$$;
grant execute on function private.fee_can_view(), private.fee_can_edit(), private.fee_my_student_id() to authenticated;

-- 管理員開關老師的學費權限
create or replace function public.admin_set_fee_access(p_id uuid, p_on boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not (select private.is_admin()) then raise exception 'admin only' using errcode = '42501'; end if;
  update public.profiles set fee_access = coalesce(p_on, false) where id = p_id and role = 'teacher';
  if not found then raise exception 'teacher not found' using errcode = '22023'; end if;
end $$;

-- ---------- 收款帳戶（國中部、國小部…） ----------
create table if not exists public.fee_accounts (
  id text primary key default ('fa_' || replace(gen_random_uuid()::text, '-', '')),
  dept text not null check (length(btrim(dept)) > 0),          -- 國小部／國中部
  bank_name text not null default '',
  bank_code text not null default '',
  account_no text not null default '',
  report_note text not null default '',                          -- 繳款回報說明（印在學費單下方）
  active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

-- ---------- 項目種類（sign：1 = 收費、-1 = 折抵） ----------
create table if not exists public.fee_item_types (
  code text primary key,
  name text not null,
  sign integer not null default 1 check (sign in (1, -1)),
  default_counted boolean not null default true,
  active boolean not null default true,
  sort_order integer not null default 0
);
insert into public.fee_item_types (code, name, sign, default_counted, sort_order) values
  ('tuition',  '學費',     1, true, 10),
  ('material', '教材費',   1, true, 20),
  ('meal',     '餐費',     1, true, 30),
  ('transport','車資',     1, true, 40),
  ('activity', '活動費',   1, true, 50),
  ('other',    '其他',     1, true, 60),
  ('deposit',  '已繳訂金', -1, true, 70),
  ('carry',    '溢繳折抵', -1, true, 80),
  ('discount', '優惠折扣', -1, true, 90),
  ('leave',    '請假折抵', -1, true, 100)
on conflict (code) do nothing;

-- ---------- 梯次（115 上學期、2026 暑期…） ----------
create table if not exists public.fee_terms (
  id text primary key default ('ft_' || replace(gen_random_uuid()::text, '-', '')),
  name text not null check (length(btrim(name)) > 0),
  kind text not null default 'regular' check (kind in ('regular', 'summer', 'winter', 'activity', 'other')),
  title text not null default '學費單',                          -- 學費單上的標題
  due_date date,
  active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

-- ---------- 學費單 ----------
create table if not exists public.fee_bills (
  id text primary key default ('fb_' || replace(gen_random_uuid()::text, '-', '')),
  student_id text references public.students (id) on delete set null,
  student_name text not null,                                    -- 單上姓名（國中生可能不在名冊）
  grade_text text not null default '',
  dept text not null default '',
  term_id text references public.fee_terms (id) on delete set null,
  title text not null default '學費單',
  due_date date,
  account_id text references public.fee_accounts (id) on delete set null,
  note text not null default '',
  status text not null default 'draft' check (status in ('draft', 'issued', 'void')),
  total integer not null default 0,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  issued_at timestamptz
);
create index if not exists fee_bills_student on public.fee_bills (student_id);
create index if not exists fee_bills_term on public.fee_bills (term_id);

create table if not exists public.fee_bill_items (
  id text primary key default ('fi_' || replace(gen_random_uuid()::text, '-', '')),
  bill_id text not null references public.fee_bills (id) on delete cascade,
  item_type text not null references public.fee_item_types (code) on update cascade,
  label text not null,
  amount integer not null default 0,                             -- 已帶正負：折抵為負數
  counted boolean not null default true,                         -- false = 只顯示（例如教材費「已繳」），不計入總計
  period_text text not null default '',
  note text not null default '',
  sort_order integer not null default 0
);
create index if not exists fee_bill_items_bill on public.fee_bill_items (bill_id, sort_order);

-- ---------- 權限 ----------
alter table public.fee_accounts enable row level security;
alter table public.fee_item_types enable row level security;
alter table public.fee_terms enable row level security;
alter table public.fee_bills enable row level security;
alter table public.fee_bill_items enable row level security;

-- 設定類：可看學費的人都能讀；只有管理員能改
create policy fee_item_types_read on public.fee_item_types for select to authenticated using ((select private.fee_can_view()));
create policy fee_item_types_admin on public.fee_item_types for all to authenticated
  using ((select private.is_admin())) with check ((select private.is_admin()));
create policy fee_terms_read on public.fee_terms for select to authenticated using ((select private.fee_can_view()));
create policy fee_terms_admin on public.fee_terms for all to authenticated
  using ((select private.is_admin())) with check ((select private.is_admin()));
create policy fee_accounts_read on public.fee_accounts for select to authenticated
  using ((select private.fee_can_view())
         or exists (select 1 from public.fee_bills b
                     where b.account_id = fee_accounts.id and b.status = 'issued'
                       and b.student_id = (select private.fee_my_student_id())));
create policy fee_accounts_admin on public.fee_accounts for all to authenticated
  using ((select private.is_admin())) with check ((select private.is_admin()));

-- 學費單：有權限的人讀；家長只讀自己已發布的；寫入一律走 fee_save_bill
create policy fee_bills_read on public.fee_bills for select to authenticated
  using ((select private.fee_can_view())
         or (status = 'issued' and student_id is not null and student_id = (select private.fee_my_student_id())));
create policy fee_bill_items_read on public.fee_bill_items for select to authenticated
  using (exists (select 1 from public.fee_bills b
                  where b.id = fee_bill_items.bill_id
                    and ((select private.fee_can_view())
                         or (b.status = 'issued' and b.student_id is not null and b.student_id = (select private.fee_my_student_id())))));

grant select on public.fee_accounts, public.fee_item_types, public.fee_terms, public.fee_bills, public.fee_bill_items to authenticated;
grant insert, update on public.fee_accounts, public.fee_item_types, public.fee_terms to authenticated;

-- ---------- 儲存學費單（含明細，一次完成） ----------
-- p: { id?, student_id?, student_name, grade_text, dept, term_id?, title, due_date?, account_id?, note, status,
--      items: [ { item_type, label, amount, counted, period_text, note } ] }
-- 金額一律輸入正數，依項目種類自動帶正負（折抵＝負數）。
create or replace function public.fee_save_bill(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_id text := nullif(p ->> 'id', '');
  v_name text := btrim(coalesce(p ->> 'student_name', ''));
  v_status text := coalesce(nullif(p ->> 'status', ''), 'draft');
  v_total integer := 0;
  v_item jsonb; v_sign integer; v_amt integer; v_i integer := 0;
  v_old text;
begin
  if not (select private.fee_can_edit()) then raise exception 'no fee edit permission' using errcode = '42501'; end if;
  if v_name = '' then raise exception 'name required' using errcode = '22023'; end if;
  if v_status not in ('draft', 'issued', 'void') then raise exception 'bad status' using errcode = '22023'; end if;
  if jsonb_typeof(coalesce(p -> 'items', '[]'::jsonb)) <> 'array' then raise exception 'items must be array' using errcode = '22023'; end if;

  if v_id is null then
    insert into public.fee_bills (student_id, student_name, grade_text, dept, term_id, title, due_date, account_id, note, status,
                                  created_by, issued_at)
    values (nullif(p ->> 'student_id', ''), v_name, coalesce(p ->> 'grade_text', ''), coalesce(p ->> 'dept', ''),
            nullif(p ->> 'term_id', ''), coalesce(nullif(p ->> 'title', ''), '學費單'), nullif(p ->> 'due_date', '')::date,
            nullif(p ->> 'account_id', ''), coalesce(p ->> 'note', ''), v_status, (select auth.uid()),
            case when v_status = 'issued' then now() end)
    returning id into v_id;
  else
    select status into v_old from public.fee_bills where id = v_id;
    if not found then raise exception 'bill not found' using errcode = '22023'; end if;
    update public.fee_bills set
      student_id = nullif(p ->> 'student_id', ''), student_name = v_name, grade_text = coalesce(p ->> 'grade_text', ''),
      dept = coalesce(p ->> 'dept', ''), term_id = nullif(p ->> 'term_id', ''),
      title = coalesce(nullif(p ->> 'title', ''), '學費單'), due_date = nullif(p ->> 'due_date', '')::date,
      account_id = nullif(p ->> 'account_id', ''), note = coalesce(p ->> 'note', ''), status = v_status,
      updated_at = now(),
      issued_at = case when v_status = 'issued' and issued_at is null then now() else issued_at end
    where id = v_id;
    delete from public.fee_bill_items where bill_id = v_id;
  end if;

  for v_item in select * from jsonb_array_elements(coalesce(p -> 'items', '[]'::jsonb)) loop
    select sign into v_sign from public.fee_item_types where code = v_item ->> 'item_type';
    if v_sign is null then raise exception 'unknown item type' using errcode = '22023'; end if;
    v_amt := abs(coalesce(nullif(v_item ->> 'amount', '')::numeric, 0))::integer * v_sign;
    v_i := v_i + 1;
    insert into public.fee_bill_items (bill_id, item_type, label, amount, counted, period_text, note, sort_order)
    values (v_id, v_item ->> 'item_type', coalesce(nullif(btrim(v_item ->> 'label'), ''), '項目'), v_amt,
            coalesce((v_item ->> 'counted')::boolean, true), coalesce(v_item ->> 'period_text', ''),
            coalesce(v_item ->> 'note', ''), v_i);
    if coalesce((v_item ->> 'counted')::boolean, true) then v_total := v_total + v_amt; end if;
  end loop;

  update public.fee_bills set total = v_total where id = v_id;
  return jsonb_build_object('id', v_id, 'total', v_total, 'status', v_status);
end $$;

revoke all on function public.fee_save_bill(jsonb), public.admin_set_fee_access(uuid, boolean) from public, anon;
grant execute on function public.fee_save_bill(jsonb), public.admin_set_fee_access(uuid, boolean) to authenticated;

-- ---------- 開單時選學生：有「修改學費」權限的人可讀在學名單（不含密碼、電話） ----------
create or replace function public.fee_list_students()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not (select private.fee_can_edit()) then raise exception 'no fee edit permission' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'school', s.school, 'grade', s.grade,
                                        'school_class', s.school_class, 'account_code', s.account_code)
                     order by s.account_code nulls last, s.name)
      from public.students s where s.active
  ), '[]'::jsonb);
end $$;
revoke all on function public.fee_list_students() from public, anon;
grant execute on function public.fee_list_students() to authenticated;
