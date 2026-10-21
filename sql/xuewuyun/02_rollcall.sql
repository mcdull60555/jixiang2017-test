-- ============================================================
-- 基翔學務雲 第 2a 階段：雲點名資料表（先在測試專案 jixiang-supabase-test 執行）
-- 對應雲點名（Google 試算表）的 Attendance、Submissions、SpecialDays、
-- LeaveBookings、ExtraClasses、Settings。學生、學校、老師改用共用名冊與帳號。
-- 只有管理員與老師能讀寫；學生、家長、未登入者都看不到。
-- ============================================================

-- 搬家對照用：雲點名原本的學生編號
alter table public.students add column if not exists rollcall_id text;
create unique index if not exists students_rollcall_id_key on public.students (rollcall_id) where rollcall_id is not null;

-- 點名紀錄：同一位學生同一天只有一筆
create table if not exists public.rc_attendance (
  id text primary key default ('ra_' || replace(gen_random_uuid()::text, '-', '')),
  date date not null,
  student_id text not null references public.students (id) on delete cascade,
  school text not null,
  status text not null default '' check (status in ('present', 'selfDrop', 'selfWalk', 'leave', 'fixedOff', '')),
  self_drop boolean not null default false,
  self_walk boolean not null default false,
  teacher_id uuid references public.profiles (id) on delete set null,
  teacher_name text not null default '',
  submitted_at timestamptz,
  was_fixed_off boolean not null default false,
  auto boolean not null default false,
  unique (date, student_id)
);
create index if not exists rc_attendance_date_school on public.rc_attendance (date, school);

-- 每次送出點名的紀錄（同一天同一校可能分批送出）
create table if not exists public.rc_submissions (
  id text primary key default ('rs_' || replace(gen_random_uuid()::text, '-', '')),
  date date not null,
  school text not null,
  teacher_id uuid references public.profiles (id) on delete set null,
  teacher_name text not null default '',
  submitted_at timestamptz not null default now(),
  count integer not null default 0
);
create index if not exists rc_submissions_date on public.rc_submissions (date);

-- 點名日設定：workday＝補班補課（週末可點名）、holiday＝國定假日（不能點名）
create table if not exists public.rc_special_days (
  date date primary key,
  type text not null check (type in ('workday', 'holiday')),
  reason text not null default '',
  created_by text not null default '',
  created_at timestamptz not null default now()
);

-- 預約請假
create table if not exists public.rc_leave_bookings (
  id text primary key default ('rb_' || replace(gen_random_uuid()::text, '-', '')),
  student_id text not null references public.students (id) on delete cascade,
  start_date date not null,
  end_date date not null,
  reason text not null default '',
  created_by text not null default '',
  created_role text not null default '',
  created_at timestamptz not null default now(),
  updated_by text not null default '',
  updated_at timestamptz,
  check (end_date >= start_date)
);
create index if not exists rc_leave_bookings_student on public.rc_leave_bookings (student_id, start_date);

-- 臨時進班（固定不進班的學生臨時要進班）
create table if not exists public.rc_extra_classes (
  id text primary key default ('rx_' || replace(gen_random_uuid()::text, '-', '')),
  student_id text not null references public.students (id) on delete cascade,
  start_date date not null,
  end_date date not null,
  reason text not null default '',
  created_by text not null default '',
  created_role text not null default '',
  created_at timestamptz not null default now(),
  updated_by text not null default '',
  updated_at timestamptz,
  check (end_date >= start_date)
);
create index if not exists rc_extra_classes_student on public.rc_extra_classes (student_id, start_date);

-- 系統設定（例如聯絡人稱呼選項）
create table if not exists public.app_settings (
  key text primary key,
  value jsonb not null default 'null'::jsonb,
  updated_at timestamptz not null default now()
);

-- ---------- 權限：只限管理員與老師 ----------
create or replace function private.is_staff()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles p where p.id = (select auth.uid()) and p.role in ('admin', 'teacher'))
$$;
grant execute on function private.is_staff() to authenticated;

alter table public.rc_attendance enable row level security;
alter table public.rc_submissions enable row level security;
alter table public.rc_special_days enable row level security;
alter table public.rc_leave_bookings enable row level security;
alter table public.rc_extra_classes enable row level security;
alter table public.app_settings enable row level security;

create policy rc_attendance_staff on public.rc_attendance for all to authenticated
  using ((select private.is_staff())) with check ((select private.is_staff()));
create policy rc_submissions_staff on public.rc_submissions for all to authenticated
  using ((select private.is_staff())) with check ((select private.is_staff()));
create policy rc_special_days_read on public.rc_special_days for select to authenticated
  using ((select private.is_staff()));
create policy rc_special_days_admin on public.rc_special_days for all to authenticated
  using ((select private.is_admin())) with check ((select private.is_admin()));
create policy rc_leave_bookings_staff on public.rc_leave_bookings for all to authenticated
  using ((select private.is_staff())) with check ((select private.is_staff()));
create policy rc_extra_classes_staff on public.rc_extra_classes for all to authenticated
  using ((select private.is_staff())) with check ((select private.is_staff()));
create policy app_settings_read on public.app_settings for select to authenticated
  using ((select private.is_staff()));
create policy app_settings_admin on public.app_settings for all to authenticated
  using ((select private.is_admin())) with check ((select private.is_admin()));

grant select, insert, update on public.rc_attendance, public.rc_submissions, public.rc_special_days,
  public.rc_leave_bookings, public.rc_extra_classes, public.app_settings to authenticated;
-- 刪除權限與保留天數（點名紀錄 40 天）留到 2b 階段，搭配網頁改寫一起加上
