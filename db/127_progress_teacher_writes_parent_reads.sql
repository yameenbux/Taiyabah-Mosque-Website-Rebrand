--  =====================================================================
--  127 - A TEACHER RECORDS HOW A CHILD IS GETTING ON, AND THE PARENT READS
--        WHAT THE TEACHER CHOSE TO SHARE
--  29 September 2026
--  =====================================================================
--
--  Slice 3 of the parents' portal (docs/superpowers/specs/2026-09-29-the-
--  parents-portal-and-messages-design.md, section Progress). The last piece
--  the masjid asked for by name.
--
--  NOT EVERYTHING A TEACHER WRITES IS FOR A FAMILY, and that distinction is in
--  the data, not in a habit. An entry has two notes and a switch:
--      note_for_parent   what the teacher would say to the family
--      note_internal     the teacher's own working note. NEVER leaves staff.
--      shared            false until the teacher says otherwise
--  A teacher can keep a working note and publish nothing.
--
--  THE ONE GUARANTEE THAT MATTERS, AND HOW IT IS MADE TO HOLD
--  parent_progress() returns shared = true rows, and its body does not
--  contain the name of the staff-only column at all: not selected, not
--  filtered, not mentioned. It cannot be returned by an accident of
--  refactoring, because nothing in that function knows the column exists. The
--  proof at the foot reads the INSTALLED definition (pg_get_functiondef) and
--  asserts the name is absent - and asserts the staff-side function DOES carry
--  it (a control, so the check is known to be able to fail), and turns the
--  same check on a deliberately bad throwaway function to watch it fire.
--  (No comment inside parent_progress() names the column either, for the same
--  reason: a comment is part of the installed definition.)
--
--  THE TABLE IS REACHED ONLY THROUGH FUNCTIONS. RLS on, no policy, every grant
--  revoked. Every function is SECURITY DEFINER with search_path = public,
--  pg_temp, and anon has EXECUTE on none of them. Each revoke/grant is
--  restated per function on purpose (Supabase's default privileges grant
--  EXECUTE to anon directly; "revoke from public" alone leaves the door open).
--
--  WHO MAY WRITE. may_take_register(class) is the precedent and the gate: the
--  teacher of that class (main teacher or listed against it), or the office
--  with two-step (verified_madrasah()). Both the pupil AND the class are named
--  and the pupil must be on that class's roll now, so a teacher cannot reach a
--  child outside their classes by guessing an id, and a class they do teach
--  cannot be used to reach a child who is not in it. A refusal is
--  {"allowed": false} and never an empty list: a foreign pupil, a pupil that
--  does not exist, a caller who is not staff and a parent all get the SAME
--  answer.
--
--  WHO MAY READ. A teacher reads the entries written against their own class;
--  a child who has moved class does not carry the old class's working notes to
--  the new teacher. A parent reads shared entries about their own children
--  only, through my_parent_children() via require_my_child() ('not yours' /
--  42501, one message for "not your child", "no such child" and "not a
--  parent", the shape db/124 used).
--
--  EVERY WRITE IS AUDITED (db/089). The row names the entry, the child and the
--  class - three ids - and whether it is shared; never a word of any note,
--  never the sabaq. Publishing to a family is its own action so it can be
--  found: progress_saved / progress_shared / progress_unshared.
--
--  DEPARTURES FROM THE SPEC'S TABLE SHAPE, both deliberate:
--    * `term_or_date` is `on_date date`. The parent's screen is newest first
--      "with the date"; a column that might hold a term name cannot be sorted
--      or shown as a date. A term is not modelled.
--    * `written_by` has no foreign key to auth.users (the same choice as
--      madrasah_messages.author_user): a teacher leaving and their login
--      being removed must neither be blocked by nor alter what they wrote.
--    * No CHECK constraints on the note columns. A failed CHECK prints the
--      whole failing row - including the staff-only note - into the server
--      log (CLAUDE.md, on madrasah_pupils). The functions validate first and
--      are the only writers.
--
--  THE PUBLISHED PRIVACY NOTICE SAYS THE MADRASAH DOES NOT HOLD THIS.
--  "Anything about your child's progress or ability" is on the list of things
--  NOT held (tools/build_privacy_page.py NOT_HELD), and
--  madrasah_notice_matches_schema() lists madrasah_progress under absent_tables:
--  the moment ONE row exists, health_check() goes red on it. That is the guard
--  doing its job, and this file does not silence it. The table is created
--  EMPTY, the proof rolls back everything it writes, and the notice must be
--  reissued (v1.7, with the messages wording) BEFORE any teacher saves a real
--  entry. See the slice report.
--
--  RETENTION is the cascade: pupil_id is ON DELETE CASCADE, the same as
--  attendance, so an entry goes with the child (three years after leaving).
--
--  NOTHING IN THE PROOF PRINTS A PERSON. Every check is a count, a boolean, a
--  sqlstate, or a fixed sentence written in this file. It writes only against
--  the invented test family and (read-only, by id, never printed) one child
--  in another class to prove the refusals.
--
--  TO REMOVE: drop table public.madrasah_progress; drop the six functions
--  named in the grants below (five granted, one helper).
--  =====================================================================

--  ---------------------------------------------------------------------
--  1. THE TABLE
--  ---------------------------------------------------------------------
create table if not exists public.madrasah_progress (
  id               uuid primary key default gen_random_uuid(),
  masjid_id        uuid not null references public.masjids(id) on delete cascade,
  pupil_id         uuid not null references public.madrasah_pupils(id) on delete cascade,
  class_id         uuid references public.madrasah_classes(id) on delete set null,
  on_date          date not null,
  sabaq            text,
  sabqi            text,
  manzil           text,
  note_for_parent  text,
  note_internal    text,
  shared           boolean not null default false,
  written_by       uuid,
  written_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create index if not exists madrasah_progress_pupil_idx
  on public.madrasah_progress (pupil_id, on_date desc);
create index if not exists madrasah_progress_class_idx
  on public.madrasah_progress (class_id, pupil_id);

alter table public.madrasah_progress enable row level security;
revoke all on table public.madrasah_progress from public, anon, authenticated;

comment on table public.madrasah_progress is
  'How a child is getting on, written by their teacher. shared=false is a working note that never reaches a family. No policy, no grants: reached only through functions. Deleted with the child (ON DELETE CASCADE).';
comment on column public.madrasah_progress.note_internal is
  'The teacher''s own note. Staff only. parent_progress() must never select it; the proof in db/127 reads the installed definition to check.';

--  ---------------------------------------------------------------------
--  2. THE ONE PREDICATE THE STAFF FUNCTIONS SHARE
--     Callable by nobody but the owner (and so by the SECURITY DEFINER
--     functions below).
--  ---------------------------------------------------------------------
create or replace function public.progress_may_write(p_pupil uuid, p_class uuid)
returns boolean language sql stable security definer
set search_path = public, pg_temp as $$
  select p_pupil is not null and p_class is not null
     and public.current_masjid() is not null
     and public.may_take_register(p_class)
     and exists (
       select 1
         from public.madrasah_pupil_classes pc
         join public.madrasah_pupils p on p.id = pc.pupil_id and p.masjid_id = pc.masjid_id
         join public.madrasah_classes c on c.id = pc.class_id and c.masjid_id = pc.masjid_id
        where pc.pupil_id = p_pupil and pc.class_id = p_class
          and pc.masjid_id = public.current_masjid()
          and c.is_active and p.left_on is null and p.status = 'on_roll');
$$;

--  ---------------------------------------------------------------------
--  3. THE STAFF'S FUNCTIONS
--  ---------------------------------------------------------------------
create or replace function public.progress_my_classes()
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_masjid uuid := public.current_masjid();
begin
  if v_masjid is null or not (public.is_teacher() or public.verified_madrasah()) then
    return jsonb_build_object('allowed', false);
  end if;
  if not public.verified_madrasah() and public.my_staff_id() is null then
    --  Said in words rather than returned empty: a teacher whose login is not
    --  joined to a staff row would otherwise see a working screen with no
    --  classes on it and conclude the system had lost them (db/090).
    return jsonb_build_object('allowed', true, 'classes', '[]'::jsonb,
      'why', 'This login is not linked to a member of staff yet, so the madrasah does not know which classes are yours. Ask the office.');
  end if;
  return jsonb_build_object('allowed', true, 'classes', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', c.id, 'name', c.name,
             'children', (select count(*) from public.madrasah_pupil_classes pc
                            join public.madrasah_pupils p on p.id = pc.pupil_id
                           where pc.class_id = c.id and p.left_on is null and p.status = 'on_roll'))
           order by c.sort_order, c.name, c.id)
      from public.madrasah_classes c
     where c.masjid_id = v_masjid and c.is_active and public.may_take_register(c.id)),
    '[]'::jsonb));
end $$;

--  The children of ONE class. Names are this function's job (a register does
--  the same), so it is gated on the class and a count-only sibling is not
--  needed: nothing here answers a "how many" question.
create or replace function public.progress_class_children(p_class uuid)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_masjid uuid := public.current_masjid(); v_name text;
begin
  if v_masjid is null or p_class is null or not public.may_take_register(p_class) then
    return jsonb_build_object('allowed', false);
  end if;
  select c.name into v_name from public.madrasah_classes c
   where c.id = p_class and c.masjid_id = v_masjid and c.is_active;
  if v_name is null then
    return jsonb_build_object('allowed', false);
  end if;
  return jsonb_build_object('allowed', true, 'class', jsonb_build_object('id', p_class, 'name', v_name),
    'children', coalesce((
      select jsonb_agg(jsonb_build_object(
               'pupil_id', p.id, 'first_name', p.first_name, 'last_name', p.last_name,
               'entries', (select count(*) from public.madrasah_progress e
                            where e.pupil_id = p.id and e.class_id = p_class),
               'shared',  (select count(*) from public.madrasah_progress e
                            where e.pupil_id = p.id and e.class_id = p_class and e.shared),
               'last_on', (select max(e.on_date) from public.madrasah_progress e
                            where e.pupil_id = p.id and e.class_id = p_class))
             order by p.first_name, p.last_name, p.id)
        from public.madrasah_pupil_classes pc
        join public.madrasah_pupils p on p.id = pc.pupil_id and p.masjid_id = pc.masjid_id
       where pc.class_id = p_class and pc.masjid_id = v_masjid
         and p.left_on is null and p.status = 'on_roll'), '[]'::jsonb));
end $$;

--  ONE CHILD IN ONE CLASS, with what has been written against them there.
--  This is the staff side, so it carries the working note.
create or replace function public.progress_child(p_pupil uuid, p_class uuid)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_masjid uuid := public.current_masjid();
begin
  if not public.progress_may_write(p_pupil, p_class) then
    return jsonb_build_object('allowed', false);
  end if;
  return jsonb_build_object('allowed', true,
    'child', (select jsonb_build_object('first_name', p.first_name, 'last_name', p.last_name)
                from public.madrasah_pupils p where p.id = p_pupil and p.masjid_id = v_masjid),
    'class', (select jsonb_build_object('id', c.id, 'name', c.name)
                from public.madrasah_classes c where c.id = p_class and c.masjid_id = v_masjid),
    'entries', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', e.id, 'on_date', e.on_date,
               'sabaq', e.sabaq, 'sabqi', e.sabqi, 'manzil', e.manzil,
               'note_for_parent', e.note_for_parent, 'note_internal', e.note_internal,
               'shared', e.shared, 'written_at', e.written_at, 'updated_at', e.updated_at,
               'written_by_name', (select nullif(btrim(concat_ws(' ', s.honorific, s.first_name, s.last_name)), '')
                                     from public.madrasah_staff s
                                    where s.user_id = e.written_by and s.masjid_id = e.masjid_id
                                    order by (s.left_on is null) desc, s.id limit 1))
             order by e.on_date desc, e.written_at desc, e.id)
        from public.madrasah_progress e
       where e.pupil_id = p_pupil and e.class_id = p_class and e.masjid_id = v_masjid), '[]'::jsonb));
end $$;

--  WRITE (create, or amend when p_id is given). VOLATILE: it writes an audit
--  row.
create or replace function public.progress_save(
  p_pupil uuid, p_class uuid, p_on date,
  p_sabaq text, p_sabqi text, p_manzil text,
  p_note_for_parent text, p_note_internal text,
  p_shared boolean, p_id uuid default null)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_masjid uuid := public.current_masjid();
  v_today  date := (now() at time zone 'Europe/London')::date;
  v_on     date := coalesce(p_on, (now() at time zone 'Europe/London')::date);
  v_sabaq  text := nullif(btrim(coalesce(p_sabaq, '')), '');
  v_sabqi  text := nullif(btrim(coalesce(p_sabqi, '')), '');
  v_manzil text := nullif(btrim(coalesce(p_manzil, '')), '');
  v_forp   text := nullif(btrim(coalesce(p_note_for_parent, '')), '');
  v_mine   text := nullif(btrim(coalesce(p_note_internal, '')), '');
  v_shared boolean := coalesce(p_shared, false);
  v_old    public.madrasah_progress%rowtype;
  v_id     uuid;
  v_created boolean := p_id is null;
  v_action text;
begin
  --  THE SCOPE COMES FIRST, before anything sent is looked at, so a child
  --  outside the caller's classes is refused identically whatever was sent.
  if not public.progress_may_write(p_pupil, p_class) then
    return jsonb_build_object('allowed', false);
  end if;
  if p_id is not null then
    select * into v_old from public.madrasah_progress e
     where e.id = p_id and e.pupil_id = p_pupil and e.class_id = p_class
       and e.masjid_id = v_masjid for update;
    if v_old.id is null then
      return jsonb_build_object('allowed', false);
    end if;
  end if;

  if v_on > v_today then
    raise exception 'That date has not come yet. Choose today or an earlier day.' using errcode = '22023';
  end if;
  if length(coalesce(v_sabaq, '')) > 200 or length(coalesce(v_sabqi, '')) > 200
     or length(coalesce(v_manzil, '')) > 200 then
    raise exception 'Please keep sabaq, sabqi and manzil to 200 characters each.' using errcode = '22023';
  end if;
  if length(coalesce(v_forp, '')) > 2000 or length(coalesce(v_mine, '')) > 2000 then
    raise exception 'Please keep each note to 2,000 characters.' using errcode = '22023';
  end if;
  if v_sabaq is null and v_sabqi is null and v_manzil is null and v_forp is null and v_mine is null then
    raise exception 'Write something first: where the child is up to, or a note.' using errcode = '22023';
  end if;
  if v_shared and v_sabaq is null and v_sabqi is null and v_manzil is null and v_forp is null then
    raise exception 'There is nothing to share with the family yet. Add where the child is up to, or a note for the parent, or leave it unshared.'
      using errcode = '22023';
  end if;

  if p_id is null then
    insert into public.madrasah_progress
      (masjid_id, pupil_id, class_id, on_date, sabaq, sabqi, manzil,
       note_for_parent, note_internal, shared, written_by)
    values (v_masjid, p_pupil, p_class, v_on, v_sabaq, v_sabqi, v_manzil,
            v_forp, v_mine, v_shared, auth.uid())
    returning id into v_id;
  else
    update public.madrasah_progress
       set on_date = v_on, sabaq = v_sabaq, sabqi = v_sabqi, manzil = v_manzil,
           note_for_parent = v_forp, note_internal = v_mine, shared = v_shared,
           updated_at = now()
     where id = p_id;
    v_id := p_id;
  end if;

  v_action := case when v_shared and (v_created or not v_old.shared) then 'progress_shared'
                   when not v_shared and not v_created and v_old.shared then 'progress_unshared'
                   else 'progress_saved' end;
  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), v_action,
          jsonb_build_object('progress', v_id, 'pupil', p_pupil, 'class', p_class,
                             'shared', v_shared,
                             'was_shared', case when v_created then null else v_old.shared end,
                             'created', v_created));
  return jsonb_build_object('allowed', true, 'id', v_id, 'shared', v_shared);
end $$;

--  ---------------------------------------------------------------------
--  4. THE PARENT'S FUNCTION
--     The staff-only column is not selected, not filtered and not named. No
--     row-to-json shortcut either: every key returned is written out.
--  ---------------------------------------------------------------------
create or replace function public.parent_progress(p_pupil uuid)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
begin
  perform public.require_my_child(p_pupil);
  return jsonb_build_object(
    'first_name', (select p.first_name from public.madrasah_pupils p
                     join public.my_parent_children() mc on mc.pupil_id = p.id and mc.masjid_id = p.masjid_id
                    where p.id = p_pupil),
    'entries', coalesce((
      select jsonb_agg(jsonb_build_object(
               'on_date', e.on_date,
               'sabaq',   e.sabaq,
               'sabqi',   e.sabqi,
               'manzil',  e.manzil,
               'note',    e.note_for_parent,
               'class',   c.name,
               'teacher', (select nullif(btrim(concat_ws(' ', s.honorific, s.first_name, s.last_name)), '')
                             from public.madrasah_staff s
                            where s.user_id = e.written_by and s.masjid_id = e.masjid_id
                            order by (s.left_on is null) desc, s.id limit 1))
             order by e.on_date desc, e.updated_at desc, e.id)
        from public.madrasah_progress e
        join public.my_parent_children() mc on mc.pupil_id = e.pupil_id and mc.masjid_id = e.masjid_id
        left join public.madrasah_classes c on c.id = e.class_id and c.masjid_id = e.masjid_id
       where e.pupil_id = p_pupil and e.shared = true), '[]'::jsonb));
end $$;

--  ---------------------------------------------------------------------
--  5. GRANTS - restated per function
--  ---------------------------------------------------------------------
revoke all on function public.progress_may_write(uuid, uuid)          from public, anon, authenticated;
revoke all on function public.progress_my_classes()                   from public, anon;
revoke all on function public.progress_class_children(uuid)           from public, anon;
revoke all on function public.progress_child(uuid, uuid)              from public, anon;
revoke all on function public.progress_save(uuid, uuid, date, text, text, text, text, text, boolean, uuid) from public, anon;
revoke all on function public.parent_progress(uuid)                   from public, anon;
grant execute on function public.progress_my_classes()                to authenticated;
grant execute on function public.progress_class_children(uuid)        to authenticated;
grant execute on function public.progress_child(uuid, uuid)           to authenticated;
grant execute on function public.progress_save(uuid, uuid, date, text, text, text, text, text, boolean, uuid) to authenticated;
grant execute on function public.parent_progress(uuid)                to authenticated;

--  =====================================================================
--  THE PROOF. Runs inside a subtransaction that ends by raising a sentinel,
--  so NOTHING it writes survives (checked at the end). Any assertion that
--  fails raises a different error, and the block aborts.
--
--  It runs AS THE REAL ACCOUNTS - the test teacher, the test parent and an
--  administrator, by setting the same request.jwt.claims the API would - and
--  every call goes through the database role `authenticated` (or `anon`), the
--  way the API reaches it.
--
--  The proof is a separate statement from the DDL above so it can be re-run
--  on its own. It is skipped, not failed, if a real progress entry exists.
--  =====================================================================
create or replace function pg_temp.px_as(p_uid uuid, p_aal text)
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', case when p_uid is null then '{}'
    else jsonb_build_object('sub', p_uid, 'role', 'authenticated', 'aal', p_aal)::text end, true);
end $$;

create or replace function pg_temp.px_ok(p_cond boolean, p_label text)
returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'PROOF FAILED: %', p_label; end if;
end $$;

--  Run a statement that returns jsonb, as the database role `authenticated`.
create or replace function pg_temp.px_j(p_sql text)
returns jsonb language plpgsql as $$
declare r jsonb;
begin
  set local role authenticated;
  begin execute p_sql into r;
  exception when others then reset role; raise;
  end;
  reset role;
  return r;
end $$;

--  Run a statement as a role; require an exact sqlstate and (optionally) a
--  fragment of the refusal's own sentence.
create or replace function pg_temp.px_expect(p_sql text, p_state text, p_has text, p_label text, p_role text default 'authenticated')
returns void language plpgsql as $$
declare v_state text := 'none'; v_msg text := '';
begin
  execute format('set local role %I', p_role);
  begin execute p_sql;
  exception when others then v_state := sqlstate; v_msg := sqlerrm;
  end;
  reset role;
  if v_state <> p_state then
    raise exception 'PROOF FAILED: % (wanted %, got %)', p_label, p_state, v_state;
  end if;
  if p_has is not null and position(p_has in v_msg) = 0 then
    raise exception 'PROOF FAILED: % (the refusal does not say "%")', p_label, p_has;
  end if;
end $$;

create or replace function pg_temp.px_keys(p_j jsonb)
returns text language sql as $$
  select coalesce(string_agg(k, ',' order by k collate "C"), '') from jsonb_object_keys(p_j) k;
$$;

--  "Does this installed function's definition contain the staff-only column?"
--  The whole promise rests on this one predicate, so it is a function the
--  proof can point at a real function AND at a deliberately bad one.
create or replace function pg_temp.px_leaks(p_fn regprocedure)
returns boolean language sql as $$
  select position('note_internal' in pg_get_functiondef(p_fn)) > 0;
$$;

do $proof$
declare
  v_teacher constant uuid := '42a0f447-f2b6-4a31-86c3-8bc2bddaad1b';
  c_int  constant text := 'ZZ-INTERNAL-MARKER-7f3a91';
  c_int2 constant text := 'ZZ-INTERNAL-EDITED-4be208';
  c_par  constant text := 'ZZ-PARENT-MARKER-9c1d55';
  c_test_class constant text := 'ZZ TEST CLASS - not a real class';
  v_masjid uuid; v_hh uuid; v_parent uuid; v_admin uuid; v_child uuid; v_class uuid; v_staff uuid;
  v_other_pupil uuid; v_other_class uuid;
  v_stranger uuid := gen_random_uuid(); v_ghost uuid := gen_random_uuid();
  v_j jsonb; v_e jsonb; v_id uuid; v_id2 uuid; v_id3 uuid;
  v_n int; v_n0 int; v_state text; v_fn text; v_today date := (now() at time zone 'Europe/London')::date;
  v_audit_before int; v_skip boolean := false;
begin
  begin   --  <<< the subtransaction the sentinel rolls back

  select h.id, h.masjid_id into v_hh, v_masjid from public.madrasah_households h
   where h.reference = 'MF-999999' and h.name = 'Zzzfamily test household';
  if v_hh is null then
    raise notice '127 proof: no test family here - the proof is skipped.';
    v_skip := true;
    raise exception 'SENTINEL' using errcode = 'P0999';
  end if;
  if (select count(*) from public.madrasah_progress) <> 0 then
    raise notice '127 proof: there are real progress entries here - the proof is skipped.';
    v_skip := true;
    raise exception 'SENTINEL' using errcode = 'P0999';
  end if;

  select l.user_id into v_parent from public.madrasah_parent_logins l
    join public.madrasah_guardians g on g.id = l.guardian_id where g.household_id = v_hh limit 1;
  select r.user_id into v_admin from public.user_roles r where r.role = 'admin' order by r.user_id limit 1;
  select p.id into v_child from public.madrasah_pupils p where p.household_id = v_hh order by p.created_at, p.id limit 1;
  select c.id into v_class from public.madrasah_classes c where c.masjid_id = v_masjid and c.name = c_test_class;
  select s.id into v_staff from public.madrasah_staff s
   where s.user_id = v_teacher and s.masjid_id = v_masjid and s.left_on is null limit 1;
  if v_parent is null or v_admin is null or v_child is null or v_class is null or v_staff is null then
    raise exception '127 proof: the fixtures are missing (parent %, admin %, child %, class %, staff %)',
      v_parent is null, v_admin is null, v_child is null, v_class is null, v_staff is null;
  end if;
  --  A child in a class the test teacher does NOT teach, in another household.
  --  Read by id and never printed.
  select pc.pupil_id, pc.class_id into v_other_pupil, v_other_class
    from public.madrasah_pupil_classes pc
    join public.madrasah_pupils p on p.id = pc.pupil_id
    join public.madrasah_classes c on c.id = pc.class_id
   where pc.masjid_id = v_masjid and c.is_active and p.left_on is null and p.status = 'on_roll'
     and pc.class_id <> v_class and p.household_id <> v_hh
     and c.main_teacher_id is distinct from v_staff
     and not exists (select 1 from public.madrasah_staff_classes sc where sc.class_id = c.id and sc.staff_id = v_staff)
   order by pc.class_id, pc.pupil_id limit 1;
  if v_other_pupil is null then raise exception '127 proof: no child in another class to test the refusals with'; end if;
  select count(*) into v_audit_before from public.admin_audit where action like 'progress\_%';

  --  ==== 0. THE TABLE AND THE FUNCTIONS ====================================
  perform pg_temp.px_ok((select relrowsecurity from pg_class where oid = 'public.madrasah_progress'::regclass), 'RLS is on');
  perform pg_temp.px_ok((select count(*) from pg_policies where tablename = 'madrasah_progress') = 0, 'a policy exists');
  perform pg_temp.px_ok(not (has_table_privilege('anon', 'public.madrasah_progress', 'select,insert,update,delete')
                          or has_table_privilege('authenticated', 'public.madrasah_progress', 'select,insert,update,delete')),
                        'a table grant survived');
  perform pg_temp.px_ok((select confdeltype from pg_constraint where conrelid = 'public.madrasah_progress'::regclass
                            and confrelid = 'public.madrasah_pupils'::regclass) = 'c', 'progress -> pupil is not ON DELETE CASCADE');
  foreach v_state in array array['authenticated', 'anon'] loop
    perform pg_temp.px_expect('select 1 from public.madrasah_progress limit 1', '42501', null, 'role ' || v_state || ' read the table', v_state);
    perform pg_temp.px_expect('insert into public.madrasah_progress (masjid_id, pupil_id, on_date) values (gen_random_uuid(), gen_random_uuid(), current_date)',
                              '42501', null, 'role ' || v_state || ' wrote the table', v_state);
  end loop;
  perform pg_temp.px_ok(not (
       has_function_privilege('anon', 'public.progress_my_classes()', 'execute')
    or has_function_privilege('anon', 'public.progress_class_children(uuid)', 'execute')
    or has_function_privilege('anon', 'public.progress_child(uuid,uuid)', 'execute')
    or has_function_privilege('anon', 'public.progress_save(uuid,uuid,date,text,text,text,text,text,boolean,uuid)', 'execute')
    or has_function_privilege('anon', 'public.parent_progress(uuid)', 'execute')
    or has_function_privilege('anon', 'public.progress_may_write(uuid,uuid)', 'execute')
    or has_function_privilege('authenticated', 'public.progress_may_write(uuid,uuid)', 'execute')),
    'anon can execute a progress function, or the helper is open');
  perform pg_temp.px_ok(
       has_function_privilege('authenticated', 'public.parent_progress(uuid)', 'execute')
   and has_function_privilege('authenticated', 'public.progress_save(uuid,uuid,date,text,text,text,text,text,boolean,uuid)', 'execute'),
   'CONTROL: a signed-in user has no execute at all (so the anon check above proves nothing)');
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('progress_may_write','progress_my_classes','progress_class_children','progress_child','progress_save','parent_progress')
     and p.prosecdef and array_to_string(p.proconfig, ',') like '%search_path=public, pg_temp%';
  perform pg_temp.px_ok(v_n = 6, 'a progress function is not SECURITY DEFINER with search_path = public, pg_temp');

  --  ==== 1. THE PROMISE: the parent function does not know the column ======
  create function pg_temp.parent_progress_bad(p_pupil uuid) returns jsonb language sql as
    $f$ select to_jsonb(e.note_internal) from public.madrasah_progress e where e.shared $f$;
  perform pg_temp.px_ok(pg_temp.px_leaks('pg_temp.parent_progress_bad(uuid)'::regprocedure),
    'THE DETECTOR CANNOT FIRE: it did not flag a function that selects the staff-only column');
  perform pg_temp.px_ok(pg_temp.px_leaks('public.progress_child(uuid,uuid)'::regprocedure),
    'CONTROL: the staff-side function does not carry the staff-only column, so the check below proves nothing');
  perform pg_temp.px_ok(not pg_temp.px_leaks('public.parent_progress(uuid)'::regprocedure),
    'THE INSTALLED parent_progress() NAMES THE STAFF-ONLY COLUMN');
  v_fn := pg_get_functiondef('public.parent_progress(uuid)'::regprocedure);
  perform pg_temp.px_ok(position('to_jsonb' in v_fn) = 0 and position('row_to_json' in v_fn) = 0 and position('e.*' in v_fn) = 0
                        and position('select *' in v_fn) = 0, 'parent_progress() builds its answer from a whole row');
  perform pg_temp.px_ok(position('e.shared = true' in v_fn) > 0, 'parent_progress() does not filter on shared = true');
  perform pg_temp.px_ok(not exists (
      select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
         and position('madrasah_progress' in p.prosrc) > 0
         and p.proname <> 'parent_progress' and p.proname not like 'progress\_%'
         --  the privacy guard lists the table by NAME (absent_tables) and counts it
         and p.proname <> 'madrasah_notice_matches_schema'),
    'some other function reads madrasah_progress');

  --  ==== 2. THE ROUND TRIP =================================================
  --  ---- the teacher writes an entry with BOTH notes and does NOT share it ----
  perform pg_temp.px_as(v_teacher, 'aal1');
  v_j := pg_temp.px_j(format('select public.progress_save(%L, %L, null, %L, %L, %L, %L, %L, false, null)',
           v_child, v_class, 'Surah al-Mulk, verses 1-10', 'Surah an-Naba, 1-15', 'Juz Amma', c_par, c_int));
  perform pg_temp.px_ok((v_j ->> 'allowed')::boolean and (v_j ->> 'shared')::boolean is false, 'the teacher could not write an entry');
  v_id := (v_j ->> 'id')::uuid;
  perform pg_temp.px_ok((select count(*) from public.madrasah_progress) = 1, 'one entry should exist');

  --  the teacher sees it, working note included
  v_j := pg_temp.px_j(format('select public.progress_child(%L, %L)', v_child, v_class));
  perform pg_temp.px_ok((v_j ->> 'allowed')::boolean and jsonb_array_length(v_j -> 'entries') = 1, 'the teacher cannot read their own entry');
  v_e := v_j -> 'entries' -> 0;
  perform pg_temp.px_ok(v_e ->> 'note_internal' = c_int and v_e ->> 'note_for_parent' = c_par and (v_e ->> 'shared')::boolean is false
                        and v_e ->> 'sabaq' = 'Surah al-Mulk, verses 1-10', 'the teacher does not see what they wrote');
  perform pg_temp.px_ok(pg_temp.px_keys(v_e) = 'id,manzil,note_for_parent,note_internal,on_date,sabaq,sabqi,shared,updated_at,written_at,written_by_name',
                        'the staff entry has different keys from the screen fixtures: ' || pg_temp.px_keys(v_e));
  perform pg_temp.px_ok(pg_temp.px_keys(v_j) = 'allowed,child,class,entries', 'progress_child keys: ' || pg_temp.px_keys(v_j));
  perform pg_temp.px_ok(coalesce(v_e ->> 'written_by_name', '') <> '', 'the entry does not carry the teacher''s name');
  v_j := pg_temp.px_j(format('select public.progress_class_children(%L)', v_class));
  perform pg_temp.px_ok((v_j ->> 'allowed')::boolean and jsonb_array_length(v_j -> 'children') = 1
                        and (v_j -> 'children' -> 0 ->> 'entries')::int = 1 and (v_j -> 'children' -> 0 ->> 'shared')::int = 0,
                        'the class list does not say one entry, none shared');
  perform pg_temp.px_ok(pg_temp.px_keys(v_j -> 'children' -> 0) = 'entries,first_name,last_name,last_on,pupil_id,shared',
                        'class child keys: ' || pg_temp.px_keys(v_j -> 'children' -> 0));
  v_j := pg_temp.px_j('select public.progress_my_classes()');
  select count(*) into v_n from public.madrasah_classes c
   where c.masjid_id = v_masjid and c.is_active
     and (c.main_teacher_id = v_staff or exists (select 1 from public.madrasah_staff_classes sc where sc.class_id = c.id and sc.staff_id = v_staff));
  perform pg_temp.px_ok((v_j ->> 'allowed')::boolean and jsonb_array_length(v_j -> 'classes') = v_n and v_n >= 1
                        and exists (select 1 from jsonb_array_elements(v_j -> 'classes') x where x ->> 'id' = v_class::text),
                        'the teacher''s class list is not exactly their classes');
  perform pg_temp.px_ok(pg_temp.px_keys(v_j -> 'classes' -> 0) = 'children,id,name', 'class keys: ' || pg_temp.px_keys(v_j -> 'classes' -> 0));

  --  ---- the parent sees NOTHING ----
  perform pg_temp.px_as(v_parent, 'aal1');
  v_j := pg_temp.px_j(format('select public.parent_progress(%L)', v_child));
  perform pg_temp.px_ok(jsonb_array_length(v_j -> 'entries') = 0 and coalesce(v_j ->> 'first_name', '') <> '', 'the parent was shown an unshared entry (or lost the child''s name)');
  perform pg_temp.px_ok(position(c_int in v_j::text) = 0 and position(c_par in v_j::text) = 0 and position('Al-Mulk' in v_j::text) = 0
                        and position('al-Mulk' in v_j::text) = 0, 'unshared words reached the parent');
  perform pg_temp.px_ok(pg_temp.px_keys(v_j) = 'entries,first_name', 'parent keys: ' || pg_temp.px_keys(v_j));

  --  ---- the teacher SHARES it ----
  perform pg_temp.px_as(v_teacher, 'aal1');
  v_j := pg_temp.px_j(format('select public.progress_save(%L, %L, null, %L, %L, %L, %L, %L, true, %L)',
           v_child, v_class, 'Surah al-Mulk, verses 1-10', 'Surah an-Naba, 1-15', 'Juz Amma', c_par, c_int, v_id));
  perform pg_temp.px_ok((v_j ->> 'allowed')::boolean and (v_j ->> 'shared')::boolean and (v_j ->> 'id')::uuid = v_id, 'the teacher could not share');
  perform pg_temp.px_ok((select count(*) from public.madrasah_progress) = 1, 'sharing made a second entry instead of amending');

  --  ---- the parent sees the PARENT note and NEVER the internal one ----
  perform pg_temp.px_as(v_parent, 'aal1');
  v_j := pg_temp.px_j(format('select public.parent_progress(%L)', v_child));
  perform pg_temp.px_ok(jsonb_array_length(v_j -> 'entries') = 1, 'the parent does not see the shared entry');
  v_e := v_j -> 'entries' -> 0;
  perform pg_temp.px_ok(v_e ->> 'note' = c_par and v_e ->> 'sabaq' = 'Surah al-Mulk, verses 1-10' and v_e ->> 'sabqi' = 'Surah an-Naba, 1-15'
                        and v_e ->> 'manzil' = 'Juz Amma' and (v_e ->> 'on_date')::date = v_today
                        and v_e ->> 'class' = c_test_class, 'the parent sees the wrong content');
  perform pg_temp.px_ok(coalesce(v_e ->> 'teacher', '') <> '', 'the parent is not told the teacher''s name');
  perform pg_temp.px_ok(pg_temp.px_keys(v_e) = 'class,manzil,note,on_date,sabaq,sabqi,teacher', 'parent entry keys: ' || pg_temp.px_keys(v_e));
  perform pg_temp.px_ok(position(c_int in v_j::text) = 0 and position('note_internal' in v_j::text) = 0,
                        'THE INTERNAL NOTE REACHED THE PARENT');

  --  ---- the teacher amends ONLY the working note; the parent sees no change ----
  perform pg_temp.px_as(v_teacher, 'aal1');
  v_j := pg_temp.px_j(format('select public.progress_save(%L, %L, null, %L, %L, %L, %L, %L, true, %L)',
           v_child, v_class, 'Surah al-Mulk, verses 1-10', 'Surah an-Naba, 1-15', 'Juz Amma', c_par, c_int2, v_id));
  perform pg_temp.px_ok((v_j ->> 'allowed')::boolean, 'the teacher could not amend');
  perform pg_temp.px_as(v_parent, 'aal1');
  v_j := pg_temp.px_j(format('select public.parent_progress(%L)', v_child));
  perform pg_temp.px_ok(jsonb_array_length(v_j -> 'entries') = 1 and v_j -> 'entries' -> 0 ->> 'note' = c_par
                        and position(c_int2 in v_j::text) = 0 and position(c_int in v_j::text) = 0, 'an amended working note reached the parent');

  --  ---- the teacher UN-shares: it leaves the family, stays with the teacher ----
  perform pg_temp.px_as(v_teacher, 'aal1');
  v_j := pg_temp.px_j(format('select public.progress_save(%L, %L, null, %L, %L, %L, %L, %L, false, %L)',
           v_child, v_class, 'Surah al-Mulk, verses 1-10', 'Surah an-Naba, 1-15', 'Juz Amma', c_par, c_int2, v_id));
  perform pg_temp.px_ok((v_j ->> 'allowed')::boolean and (v_j ->> 'shared')::boolean is false, 'the teacher could not un-share');
  perform pg_temp.px_as(v_parent, 'aal1');
  v_j := pg_temp.px_j(format('select public.parent_progress(%L)', v_child));
  perform pg_temp.px_ok(jsonb_array_length(v_j -> 'entries') = 0 and position(c_par in v_j::text) = 0, 'an un-shared entry is still shown to the parent');
  perform pg_temp.px_as(v_teacher, 'aal1');
  v_j := pg_temp.px_j(format('select public.progress_child(%L, %L)', v_child, v_class));
  perform pg_temp.px_ok(v_j -> 'entries' -> 0 ->> 'note_internal' = c_int2, 'un-sharing lost the teacher''s own note');

  --  ---- a WORKING NOTE ALONE: kept, and refused if the teacher tries to publish it ----
  v_j := pg_temp.px_j(format('select public.progress_save(%L, %L, null, null, null, null, null, %L, false, null)', v_child, v_class, c_int));
  perform pg_temp.px_ok((v_j ->> 'allowed')::boolean, 'a working note on its own was refused');
  v_id2 := (v_j ->> 'id')::uuid;
  perform pg_temp.px_expect(format('select public.progress_save(%L, %L, null, null, null, null, null, %L, true, %L)', v_child, v_class, c_int, v_id2),
                            '22023', 'nothing to share', 'sharing a working note with nothing to say');
  perform pg_temp.px_as(v_parent, 'aal1');
  v_j := pg_temp.px_j(format('select public.parent_progress(%L)', v_child));
  perform pg_temp.px_ok(jsonb_array_length(v_j -> 'entries') = 0 and position(c_int in v_j::text) = 0, 'a working note reached the parent');

  --  ---- the audit: every write, by the teacher, ids only ----
  select count(*) into v_n from public.admin_audit where action like 'progress\_%';
  perform pg_temp.px_ok(v_n - v_audit_before = 5, 'expected five audit rows for five writes, got ' || (v_n - v_audit_before));
  perform pg_temp.px_ok((select count(*) from public.admin_audit where action = 'progress_saved') = 3
                    and (select count(*) from public.admin_audit where action = 'progress_shared') = 1
                    and (select count(*) from public.admin_audit where action = 'progress_unshared') = 1,
                        'the audit actions are not saved x3, shared x1, unshared x1');
  perform pg_temp.px_ok((select count(*) from public.admin_audit where action like 'progress\_%' and actor = v_teacher) = 5, 'an audit row does not record who');
  perform pg_temp.px_ok((select count(distinct pg_temp.px_keys(a.detail)) from public.admin_audit a where a.action like 'progress\_%') = 1
                    and (select pg_temp.px_keys(a.detail) from public.admin_audit a where a.action = 'progress_shared') = 'class,created,progress,pupil,shared,was_shared',
                        'the audit detail is not exactly ids and flags');
  perform pg_temp.px_ok((select count(*) from public.admin_audit a where a.action like 'progress\_%'
                          and (position(c_int in a.detail::text) > 0 or position(c_par in a.detail::text) > 0 or position('Mulk' in a.detail::text) > 0)) = 0,
                        'a note or a sabaq reached the audit log');

  --  ---- validation: refused in words, and nothing is written ----
  perform pg_temp.px_as(v_teacher, 'aal1');
  select count(*) into v_n0 from public.madrasah_progress;
  perform pg_temp.px_expect(format('select public.progress_save(%L, %L, %L, %L, null, null, null, null, false, null)', v_child, v_class, v_today + 2, 'x'),
                            '22023', 'has not come yet', 'a date in the future');
  perform pg_temp.px_expect(format('select public.progress_save(%L, %L, null, %L, null, null, null, null, false, null)', v_child, v_class, repeat('s', 201)),
                            '22023', '200 characters', 'sabaq of 201');
  perform pg_temp.px_expect(format('select public.progress_save(%L, %L, null, null, null, null, %L, null, false, null)', v_child, v_class, repeat('n', 2001)),
                            '22023', '2,000 characters', 'a note of 2001');
  perform pg_temp.px_expect(format('select public.progress_save(%L, %L, null, %L, null, null, null, null, false, null)', v_child, v_class, '   '),
                            '22023', 'Write something first', 'an entry with nothing in it');
  perform pg_temp.px_expect(format('select public.progress_save(%L, %L, null, null, null, null, null, null, true, null)', v_child, v_class),
                            '22023', 'Write something first', 'an empty entry, shared');
  perform pg_temp.px_ok((select count(*) from public.madrasah_progress) = v_n0, 'a refused save wrote a row');

  --  ==== 3. THE REFUSALS ====================================================
  --  ---- a teacher reaching a child OUTSIDE their classes ----
  perform pg_temp.px_as(v_teacher, 'aal1');
  perform pg_temp.px_ok(public.teaches_class(v_class) and not public.teaches_class(v_other_class),
                        'CONTROL: the test teacher does not teach the test class and only that (so the refusals below prove nothing)');
  perform pg_temp.px_ok((pg_temp.px_j(format('select public.progress_save(%L, %L, null, %L, null, null, null, null, false, null)', v_other_pupil, v_other_class, 'x')) ->> 'allowed')::boolean is false,
                        'a teacher wrote to a child outside their classes');
  perform pg_temp.px_ok((pg_temp.px_j(format('select public.progress_save(%L, %L, null, %L, null, null, null, null, false, null)', v_other_pupil, v_class, 'x')) ->> 'allowed')::boolean is false,
                        'a teacher used their own class to reach a child who is not in it');
  perform pg_temp.px_ok((pg_temp.px_j(format('select public.progress_save(%L, %L, null, %L, null, null, null, null, false, null)', v_child, v_other_class, 'x')) ->> 'allowed')::boolean is false,
                        'a teacher used another class to reach their own child');
  perform pg_temp.px_ok((pg_temp.px_j(format('select public.progress_save(%L, %L, null, %L, null, null, null, null, false, %L)', v_other_pupil, v_other_class, 'x', v_id)) ->> 'allowed')::boolean is false,
                        'a teacher amended an entry through a child outside their classes');
  perform pg_temp.px_ok((pg_temp.px_j(format('select public.progress_child(%L, %L)', v_other_pupil, v_other_class)) ->> 'allowed')::boolean is false,
                        'a teacher read a child outside their classes');
  perform pg_temp.px_ok((pg_temp.px_j(format('select public.progress_class_children(%L)', v_other_class)) ->> 'allowed')::boolean is false,
                        'a teacher listed a class they do not teach');
  perform pg_temp.px_ok((pg_temp.px_j(format('select public.progress_class_children(%L)', v_ghost)) ->> 'allowed')::boolean is false
                    and (pg_temp.px_j(format('select public.progress_child(%L, %L)', v_ghost, v_ghost)) ->> 'allowed')::boolean is false,
                        'an id that does not exist is answered differently');
  perform pg_temp.px_ok((select count(*) from public.madrasah_progress) = v_n0, 'a refused teacher write left a row');

  --  ---- a parent, an administrator without two-step, a stranger and nobody: the staff functions ----
  foreach v_state in array array['parent/aal1', 'admin/aal1', 'stranger/aal2', 'nobody/none'] loop
    if v_state = 'parent/aal1' then perform pg_temp.px_as(v_parent, 'aal1');
    elsif v_state = 'admin/aal1' then perform pg_temp.px_as(v_admin, 'aal1');
    elsif v_state = 'stranger/aal2' then perform pg_temp.px_as(v_stranger, 'aal2');
    else perform pg_temp.px_as(null, null); end if;
    perform pg_temp.px_ok((pg_temp.px_j('select public.progress_my_classes()') ->> 'allowed')::boolean is false, v_state || ' opened the class list');
    perform pg_temp.px_ok((pg_temp.px_j(format('select public.progress_class_children(%L)', v_class)) ->> 'allowed')::boolean is false, v_state || ' listed the test class');
    perform pg_temp.px_ok((pg_temp.px_j(format('select public.progress_child(%L, %L)', v_child, v_class)) ->> 'allowed')::boolean is false, v_state || ' read the test child''s entries');
    perform pg_temp.px_ok((pg_temp.px_j(format('select public.progress_save(%L, %L, null, %L, null, null, null, null, false, null)', v_child, v_class, 'x')) ->> 'allowed')::boolean is false, v_state || ' wrote an entry');
  end loop;
  perform pg_temp.px_ok((select count(*) from public.madrasah_progress) = v_n0, 'a refused non-teacher write left a row');

  --  ---- the parent's function: another household's child, no such child, NULL, and who is not a parent ----
  perform pg_temp.px_as(v_parent, 'aal1');
  perform pg_temp.px_expect(format('select public.parent_progress(%L)', v_other_pupil), '42501', 'not yours', 'a parent read another household''s child');
  perform pg_temp.px_expect(format('select public.parent_progress(%L)', v_ghost), '42501', 'not yours', 'a parent read a child that does not exist');
  perform pg_temp.px_expect('select public.parent_progress(null)', '42501', 'not yours', 'a parent read NULL');
  perform pg_temp.px_ok(jsonb_array_length(pg_temp.px_j(format('select public.parent_progress(%L)', v_child)) -> 'entries') = 0,
                        'CONTROL: the parent cannot read their own child either, so the refusals above prove nothing');
  foreach v_state in array array['teacher/aal1', 'admin/aal2', 'stranger/aal2', 'nobody/none'] loop
    if v_state = 'teacher/aal1' then perform pg_temp.px_as(v_teacher, 'aal1');
    elsif v_state = 'admin/aal2' then perform pg_temp.px_as(v_admin, 'aal2');
    elsif v_state = 'stranger/aal2' then perform pg_temp.px_as(v_stranger, 'aal2');
    else perform pg_temp.px_as(null, null); end if;
    perform pg_temp.px_expect(format('select public.parent_progress(%L)', v_child), '42501', 'not yours', v_state || ' read a parent''s view of the test child');
  end loop;

  --  ---- anon: every function, refused by the database itself ----
  perform pg_temp.px_as(null, null);
  perform pg_temp.px_expect('select public.progress_my_classes()', '42501', null, 'anon opened the class list', 'anon');
  perform pg_temp.px_expect(format('select public.progress_class_children(%L)', v_class), '42501', null, 'anon listed a class', 'anon');
  perform pg_temp.px_expect(format('select public.progress_child(%L, %L)', v_child, v_class), '42501', null, 'anon read a child', 'anon');
  perform pg_temp.px_expect(format('select public.progress_save(%L, %L, null, %L, null, null, null, null, false, null)', v_child, v_class, 'x'), '42501', null, 'anon wrote', 'anon');
  perform pg_temp.px_expect(format('select public.parent_progress(%L)', v_child), '42501', null, 'anon read the parent view', 'anon');

  --  ---- CONTROL for the scope guard: the SAME call, from the office with two-step, succeeds ----
  perform pg_temp.px_as(v_admin, 'aal2');
  v_j := pg_temp.px_j(format('select public.progress_save(%L, %L, null, %L, null, null, null, null, false, null)', v_other_pupil, v_other_class, 'x'));
  perform pg_temp.px_ok((v_j ->> 'allowed')::boolean, 'CONTROL: the office with two-step could not write to the child the teacher was refused, so the teacher''s refusal was not the scope guard');
  delete from public.madrasah_progress where id = (v_j ->> 'id')::uuid;

  --  ---- the sentinel: roll it all back ------------------------------------
  perform pg_temp.px_as(null, null);
  raise exception 'SENTINEL' using errcode = 'P0999';
  exception when sqlstate 'P0999' then
    perform set_config('request.jwt.claims', '{}', true);
    reset role;
  end;

  --  ---- NOTHING SURVIVED ----------------------------------------------------
  if v_skip then return; end if;
  if (select count(*) from public.madrasah_progress) <> 0
     or (select count(*) from public.admin_audit where action like 'progress\_%') <> v_audit_before then
    raise exception 'PROOF FAILED: something the proof wrote survived it';
  end if;
  raise notice '127 proof: every check held and nothing survived.';
end $proof$;
