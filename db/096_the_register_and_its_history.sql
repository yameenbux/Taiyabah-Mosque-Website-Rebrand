--  =====================================================================
--  096 - THE REGISTER, AND EVERYTHING IT HAS EVER SAID
--  =====================================================================
--  madrasah_attendance is UNIQUE (pupil_id, on_date) and is updated in
--  place, so a mark changed is a mark gone. For a Tuesday that is fine.
--  For "where was this child on the evening in question", which is what
--  a safeguarding enquiry asks, "it says present and we cannot tell you
--  whether it always did" is not an answer.
--
--  So: attendance stays the CURRENT state and every screen keeps reading
--  it unchanged. The log holds what it used to say.

create table if not exists public.madrasah_registers (
  id             uuid primary key default gen_random_uuid(),
  masjid_id      uuid not null references public.masjids(id) on delete cascade,
  class_id       uuid not null references public.madrasah_classes(id) on delete cascade,
  on_date        date not null,
  state          text not null default 'draft' check (state in ('draft','submitted')),
  expected_count int  not null default 0,   --  what was true then. NOT what submit checks.
  marked_count   int  not null default 0,
  submitted_by   uuid references auth.users(id),
  submitted_at   timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (class_id, on_date)
);
alter table public.madrasah_registers enable row level security;
revoke all on public.madrasah_registers from anon, authenticated;

--  APPEND ONLY. pupil_id cascades exactly as madrasah_attendance does, so
--  the log is deleted with the child three years after they leave and the
--  notice's promise holds without a purge rule of its own.
create table if not exists public.madrasah_attendance_log (
  id         uuid primary key default gen_random_uuid(),
  masjid_id  uuid not null references public.masjids(id) on delete cascade,
  pupil_id   uuid not null references public.madrasah_pupils(id) on delete cascade,
  class_id   uuid references public.madrasah_classes(id) on delete set null,
  on_date    date not null,
  mark       text not null,
  reason     text,
  source     text not null,
  was_mark   text,          --  null on the first mark of the evening
  was_reason text,
  was_source text,
  written_by uuid references auth.users(id),
  written_at timestamptz not null default now()
);
alter table public.madrasah_attendance_log enable row level security;
revoke all on public.madrasah_attendance_log from anon, authenticated;

create index if not exists madrasah_attendance_log_find
  on public.madrasah_attendance_log (class_id, on_date, written_at desc);

--  THE LOG IS WRITTEN BY A TRIGGER, NOT BY THE CALLER.
--  Every path that touches attendance - the register, the office, a
--  correction, anything added later - is logged without having to
--  remember to. A log you have to remember to write is a log with holes.
create or replace function public.log_attendance_change()
returns trigger language plpgsql security definer
set search_path = public, pg_temp as $$
begin
  insert into public.madrasah_attendance_log
    (masjid_id, pupil_id, class_id, on_date, mark, reason, source,
     was_mark, was_reason, was_source, written_by)
  values (new.masjid_id, new.pupil_id, new.class_id, new.on_date,
          new.mark, new.reason, new.source,
          case when tg_op = 'UPDATE' then old.mark   end,
          case when tg_op = 'UPDATE' then old.reason end,
          case when tg_op = 'UPDATE' then old.source end,
          auth.uid());
  return new;
end $$;

--  Revoked from public/anon like every function here - the blanket rule,
--  not because a grant would let a client forge a log row. It would not:
--  this function RETURNS TRIGGER, and Postgres's executor refuses to call
--  any trigger-returning function except from an actual trigger firing
--  ("trigger functions can only be called as triggers"), whatever the
--  privileges say. There is no "grant execute to authenticated" because
--  a client invoking it directly was never possible in the first place,
--  not because we are withholding a grant that would otherwise work.
--
--  Worth recording here, since it is exactly the kind of thing an ACL
--  audit needs and a schema diff will not show you: pg_default_acl grants
--  authenticated=arwdDxtm on every new table in this schema automatically
--  (role postgres, "r" on public - checked directly against the catalogue,
--  not assumed). So the "revoke all ... from anon, authenticated" on
--  madrasah_registers and madrasah_attendance_log above are not decoration
--  restating what RLS already does - without them, authenticated would
--  have table-level read/write on both from the moment they are created,
--  before any policy exists to restrict it.
revoke all on function public.log_attendance_change() from public, anon;

drop trigger if exists madrasah_attendance_logged on public.madrasah_attendance;
create trigger madrasah_attendance_logged
  after insert or update on public.madrasah_attendance
  for each row execute function public.log_attendance_change();
