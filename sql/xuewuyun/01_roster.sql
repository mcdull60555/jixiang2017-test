-- ============================================================
-- 基翔學務雲 第 1 階段：共用學生名冊（先在測試專案 jixiang-supabase-test 執行）
-- 只新增欄位、資料表與函式，不刪除任何資料；學習通既有功能不受影響。
-- ============================================================

-- ---------- 學校 ----------
create table if not exists public.schools (
  id text primary key default ('sc_' || replace(gen_random_uuid()::text, '-', '')),
  name text not null unique check (length(btrim(name)) > 0),
  active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);
alter table public.schools enable row level security;
grant select on public.schools to authenticated;
create policy schools_select on public.schools for select to authenticated using (true);

-- ---------- 學生名冊欄位 ----------
alter table public.students
  add column if not exists account_code text,
  add column if not exists entry_year integer,
  add column if not exists school_class integer,
  add column if not exists birthday date,
  add column if not exists contacts jsonb not null default '[]'::jsonb,
  add column if not exists fixed_off_days integer[] not null default '{}',
  add column if not exists in_rollcall boolean not null default true,
  add column if not exists learning_enabled boolean not null default true,
  add column if not exists active boolean not null default true,
  add column if not exists note text not null default '';

create unique index if not exists students_account_code_key on public.students (account_code) where account_code is not null;
alter table public.students
  add constraint students_account_code_format check (account_code is null or account_code ~ '^JX[0-9]{3}[0-9]{3}$'),
  add constraint students_contacts_array check (jsonb_typeof(contacts) = 'array'),
  add constraint students_school_class_range check (school_class is null or school_class between 1 and 99);

-- ---------- 帳號編號：JX + 國小一年級入學學年（民國）+ 流水號 ----------
-- 目前學年：8 月 1 日起算新學年
create or replace function private.current_school_year()
returns integer language sql stable set search_path = '' as $$
  select (extract(year from (now() at time zone 'Asia/Taipei'))::int - 1911)
         - case when extract(month from (now() at time zone 'Asia/Taipei')) < 8 then 1 else 0 end
$$;

create or replace function private.grade_number(p_grade text)
returns integer language sql immutable set search_path = '' as $$
  select case left(coalesce(p_grade, ''), 1)
    when '一' then 1 when '二' then 2 when '三' then 3
    when '四' then 4 when '五' then 5 when '六' then 6 end
$$;

create or replace function private.next_account_code(p_entry_year integer)
returns text language plpgsql security definer set search_path = '' as $$
declare v_prefix text := 'JX' || lpad(p_entry_year::text, 3, '0'); v_next integer;
begin
  perform pg_advisory_xact_lock(hashtext('jx_account_' || p_entry_year));
  select coalesce(max(substr(account_code, 6)::int), 0) + 1 into v_next
    from public.students where account_code like v_prefix || '%';
  if v_next > 999 then raise exception '學年 % 的流水號已用完', p_entry_year; end if;
  return v_prefix || lpad(v_next::text, 3, '0');
end $$;

-- 新增學生時自動補上入學學年與帳號（學習通原本的新增學生功能也會自動套用）
create or replace function private.students_assign_account()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.entry_year is null and private.grade_number(new.grade) is not null then
    new.entry_year := private.current_school_year() - (private.grade_number(new.grade) - 1);
  end if;
  if new.account_code is null and new.entry_year is not null then
    new.account_code := private.next_account_code(new.entry_year);
  end if;
  return new;
end $$;

create trigger students_assign_account before insert on public.students
  for each row execute function private.students_assign_account();

-- ---------- 可解密的密碼（只有伺服器能解開） ----------
alter table private.login_pins add column if not exists pin_enc bytea;

select vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'jx_pin_key', '學生密碼加解密金鑰')
 where not exists (select 1 from vault.secrets where name = 'jx_pin_key');

create or replace function private.pin_key()
returns text language sql stable security definer set search_path = '' as $$
  select decrypted_secret from vault.decrypted_secrets where name = 'jx_pin_key'
$$;
revoke all on function private.pin_key() from public, anon, authenticated;

-- 設定密碼時同時存一份加密版本（只限學生帳號）
create or replace function private.set_pin(p_uid uuid, p_pin text)
returns void language sql security definer set search_path = '' as $$
  insert into private.login_pins (user_id, pin_hash, pin_enc)
  values (p_uid, extensions.crypt('jx' || p_pin, extensions.gen_salt('bf')),
          case when exists (select 1 from public.profiles where id = p_uid and role = 'student')
               then extensions.pgp_sym_encrypt(p_pin, private.pin_key()) end)
  on conflict (user_id) do update
    set pin_hash = excluded.pin_hash, pin_enc = excluded.pin_enc,
        failed_count = 0, last_failed_at = null, locked_until = null
$$;

-- 查看學生密碼：管理員可看全部；老師只能看自己負責班級的學生。一次查一位，不留紀錄。
create or replace function public.reveal_student_pin(p_student_id text)
returns text language plpgsql security definer set search_path = '' as $$
declare v_uid uuid; v_enc bytea;
begin
  if not (
    (select private.is_admin())
    or exists (
      select 1 from public.teacher_classes tc
        join public.class_students cs on cs.class_id = tc.class_id
       where tc.teacher_id = (select auth.uid()) and cs.student_id = p_student_id)
  ) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select s.auth_user_id into v_uid from public.students s where s.id = p_student_id;
  select lp.pin_enc into v_enc from private.login_pins lp where lp.user_id = v_uid;
  if v_enc is null then return null; end if;   -- 舊密碼無法還原，需重設後才看得到
  return extensions.pgp_sym_decrypt(v_enc, private.pin_key());
end $$;
revoke all on function public.reveal_student_pin(text) from public, anon;
grant execute on function public.reveal_student_pin(text) to authenticated;
