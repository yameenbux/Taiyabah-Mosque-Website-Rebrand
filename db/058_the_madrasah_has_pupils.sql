-- ===========================================================================
--  058_the_madrasah_has_pupils.sql
--  18 September 2026
--
--  THE TABLE THIS PROJECT HAS REFUSED TO CREATE FOR A WEEK.
--
--  Migration 052's header says why it did not build this:
--
--      "A madrasah roll reveals a child's religion, which is Article 9 data
--       before anybody adds a note ... So this could be built and the pupil
--       tables could not."
--
--  It is built now because the masjid has confirmed the DPIA is complete and
--  the charity is registered with the ICO. That confirmation is the only thing
--  that changed. "The site is not live yet" was offered as the reason and is
--  not one: the UK GDPR bites at PROCESSING, and writing five hundred children
--  into a database in eu-west-2 is processing whether or not a parent can see
--  it. Not-live prevents disclosure; it does not create a lawful basis.
--
--  ---------------------------------------------------------------------------
--  TWO ANSWERS FROM THE MASJID ARE BUILT INTO THIS FILE
--  ---------------------------------------------------------------------------
--
--  WHO MAY SEE A CHILD. An administrator sees every pupil. Somebody holding
--  the madrasah role sees only the children in classes they are assigned to
--  teach, and nothing else. That is enforced here, in Postgres, by joining
--  auth.uid() through madrasah_staff to madrasah_staff_classes — not by the
--  screen asking for less than it could have.
--
--  It is data minimisation with a number attached: forty teachers against five
--  hundred and forty-three children is 21,720 possible pairings, and scoping
--  to real class assignments cuts that to about 543. If one teacher's account
--  is ever taken, that difference is the whole of the incident.
--
--  A NOTE ON WHAT THIS MEANS TODAY. `madrasah_staff.user_id` is null on all
--  forty imported teachers — none of them has been tied to a sign-in account
--  yet. So a madrasah account presently resolves to NO classes and therefore
--  NO pupils. That is the safe direction to fail in, and it is deliberate: the
--  join is real and the link is simply not made. Nobody sees a child until
--  somebody at the masjid connects that person's staff record to their login.
--
--  HOW LONG A RECORD IS KEPT. Three years after the child leaves, then it is
--  deleted. Not flagged, not archived — deleted, by purge_madrasah_pupils(),
--  on the same timer as every other retention rule in this system.
--
--  SAFEGUARDING RECORDS ARE ON A DIFFERENT CLOCK AND THIS PURGE MUST NEVER
--  TOUCH ONE. A concern or an incident is normally kept far longer than a
--  pupil record — commonly until the child would be 25. Those tables do not
--  exist yet. When they do they must NOT carry `on delete cascade` from this
--  table, or the three-year purge silently becomes a safeguarding purge. There
--  is a check at the bottom of this file that fails if anything ever does.
--
--  ---------------------------------------------------------------------------
--  WHAT IS NOT IN THIS TABLE, AND THAT IS THE POINT
--  ---------------------------------------------------------------------------
--
--  A name, a class, and the dates they joined and left. No date of birth, no
--  address, no parent's telephone number, no medical note, no photograph, no
--  nationality. The import has none of those and this table has no column
--  waiting for them, because an empty column is an invitation and every one of
--  those fields raises what a breach would cost.
--
--  Add a column when a screen genuinely needs it and the DPIA covers it. That
--  is a smaller decision than deleting one that has been quietly filled in.
--
--  Prerequisites: 052 (classes and staff), 055-057. Idempotent.
-- ===========================================================================

begin;

-- ---------------------------------------------------------------------------
--  1. The pupils
-- ---------------------------------------------------------------------------
create table if not exists public.madrasah_pupils (
  id         uuid primary key default gen_random_uuid(),
  masjid_id  uuid not null references public.masjids(id) on delete cascade,

  first_name text not null,
  last_name  text,

  --  Joined and left. `left_on` is what starts the retention clock, and until
  --  it is set the child is current and nothing expires.
  joined_on  date,
  left_on    date,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.madrasah_pupils drop constraint if exists madrasah_pupil_has_a_name;
alter table public.madrasah_pupils add constraint madrasah_pupil_has_a_name
  check (length(btrim(first_name)) between 1 and 80);

alter table public.madrasah_pupils drop constraint if exists madrasah_pupil_left_after_joining;
alter table public.madrasah_pupils add constraint madrasah_pupil_left_after_joining
  check (left_on is null or joined_on is null or left_on >= joined_on);

comment on table public.madrasah_pupils is
  'Children enrolled at the madrasah. Attendance at a madrasah reveals religious '
  'belief, so every row here is Article 9 special category data about a child. '
  'Read only through madrasah_pupils_in_class() and madrasah_pupil(), which scope '
  'a teacher to their own classes. Deleted three years after left_on by '
  'purge_madrasah_pupils().';

-- ---------------------------------------------------------------------------
--  2. Which classes they are in
--
--     Many-to-many on purpose. The girls' side runs OOLA, THAANIYAH,
--     THAALITHAH, RAABI'AH and KHAMISAH as a progression taught by an
--     overlapping group of Apas, and a child can sit in more than one. A
--     single class_id column on the pupil would have forced somebody to
--     duplicate the child to record the truth.
-- ---------------------------------------------------------------------------
create table if not exists public.madrasah_pupil_classes (
  masjid_id uuid not null references public.masjids(id) on delete cascade,
  pupil_id  uuid not null references public.madrasah_pupils(id) on delete cascade,
  class_id  uuid not null references public.madrasah_classes(id) on delete cascade,
  added_at  timestamptz not null default now(),
  primary key (pupil_id, class_id)
);

create index if not exists madrasah_pupil_classes_by_class
  on public.madrasah_pupil_classes (class_id);

-- ---------------------------------------------------------------------------
--  3. Row Level Security. Forced, no policies, reached only through the
--     functions below — the house pattern. GRANT and RLS are different things
--     and both are needed.
-- ---------------------------------------------------------------------------
alter table public.madrasah_pupils        enable row level security;
alter table public.madrasah_pupil_classes enable row level security;
alter table public.madrasah_pupils        force row level security;
alter table public.madrasah_pupil_classes force row level security;
revoke all on public.madrasah_pupils        from anon, authenticated;
revoke all on public.madrasah_pupil_classes from anon, authenticated;

-- ---------------------------------------------------------------------------
--  4. WHICH CLASSES THIS ACCOUNT MAY LOOK INTO.
--
--     One function, used by everything that reads a pupil, so the rule lives
--     in exactly one place. An administrator gets every class at the masjid; a
--     teacher gets the classes their staff record is assigned to.
--
--     Somebody with neither gets an empty set rather than an error, because
--     this answers "which classes" and the refusal belongs to the caller.
-- ---------------------------------------------------------------------------
create or replace function public.madrasah_classes_i_may_see()
returns setof uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select c.id
    from public.madrasah_classes c
   where c.masjid_id = public.current_masjid()
     and public.verified_admin()

  union

  select sc.class_id
    from public.madrasah_staff_classes sc
    join public.madrasah_staff s on s.id = sc.staff_id
   where sc.masjid_id = public.current_masjid()
     and s.user_id = auth.uid()
     and s.user_id is not null
     and public.verified_madrasah();
$fn$;

comment on function public.madrasah_classes_i_may_see() is
  'The classes the signed-in account may look into: all of them for an '
  'administrator, only their own for a teacher. Every pupil read goes through '
  'this. Note that madrasah_staff.user_id is null for every imported teacher, '
  'so a teacher resolves to no classes until somebody ties their staff record '
  'to a login - which is the safe direction to fail in.';

-- ---------------------------------------------------------------------------
--  5. Reading pupils
-- ---------------------------------------------------------------------------
create or replace function public.madrasah_pupils_in_class(p_class uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare v_masjid uuid := public.current_masjid();
begin
  if not public.verified_madrasah() then
    raise exception 'Only madrasah staff who have completed two-step may see the children.'
      using errcode = '42501';
  end if;

  --  THE BOUNDARY, AND IT IS ONE LINE. Asking for a class you do not take is
  --  refused outright rather than answered with an empty list: an empty list
  --  says "there are no children in this class", which is a different and
  --  false statement, and it is the answer that would let somebody map the
  --  madrasah by trying class ids one at a time.
  if not exists (select 1 from public.madrasah_classes_i_may_see() c where c = p_class) then
    raise exception 'That is not one of your classes.' using errcode = '42501';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', p.id,
             'first_name', p.first_name,
             'last_name', p.last_name,
             'name', btrim(concat_ws(' ', p.first_name, p.last_name)),
             'joined_on', p.joined_on,
             'left_on', p.left_on)
           order by lower(coalesce(nullif(btrim(p.last_name), ''), p.first_name)),
                    lower(p.first_name))
      from public.madrasah_pupil_classes pc
      join public.madrasah_pupils p on p.id = pc.pupil_id
     where pc.class_id = p_class
       and pc.masjid_id = v_masjid
       and p.masjid_id = v_masjid), '[]'::jsonb);
end $fn$;

-- ---------------------------------------------------------------------------
--  6. The classes, with the figures the screen needs, in one call
--
--     Headcount and teachers per class. An administrator sees every class;
--     a teacher sees only theirs, so the Classes screen shrinks rather than
--     filling with rows that refuse to open.
-- ---------------------------------------------------------------------------
create or replace function public.madrasah_class_list()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare v_masjid uuid := public.current_masjid();
begin
  if not public.verified_madrasah() then
    raise exception 'Only madrasah staff who have completed two-step may see the classes.'
      using errcode = '42501';
  end if;

  return jsonb_build_object(
    'may_amend', public.verified_admin(),
    'classes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', c.id, 'name', c.name, 'section', c.section,
               'year_label', c.year_label, 'is_active', c.is_active,
               'sort_order', c.sort_order,
               'pupils', (select count(*) from public.madrasah_pupil_classes pc
                           where pc.class_id = c.id and pc.masjid_id = v_masjid),
               'teachers', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'id', s.id,
                          'name', btrim(concat_ws(' ', s.honorific, s.first_name, s.last_name)))
                        order by s.last_name, s.first_name)
                   from public.madrasah_staff_classes sc
                   join public.madrasah_staff s on s.id = sc.staff_id
                  where sc.class_id = c.id and sc.masjid_id = v_masjid), '[]'::jsonb))
             order by c.section, c.sort_order, c.name)
        from public.madrasah_classes c
       where c.masjid_id = v_masjid
         and c.id in (select * from public.madrasah_classes_i_may_see())), '[]'::jsonb));
end $fn$;

-- ---------------------------------------------------------------------------
--  7. Writing a pupil, and moving one between classes
-- ---------------------------------------------------------------------------
create or replace function public.save_madrasah_pupil(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_id     uuid := nullif(p->>'id', '')::uuid;
  v_masjid uuid := public.current_masjid();
  v_first  text := btrim(coalesce(p->>'first_name', ''));
  v_row    public.madrasah_pupils%rowtype;
  v_class  uuid;
begin
  --  WRITING A CHILD IS ADMINISTRATORS ONLY, even though teachers may read
  --  their own. Adding, renaming and removing a pupil is an office job, and a
  --  register that any teacher can rewrite is a register nobody can rely on.
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may change a pupil record.'
      using errcode = '42501';
  end if;
  if v_masjid is null then
    raise exception 'No masjid is selected.' using errcode = '42501';
  end if;
  if v_first = '' then
    raise exception 'A pupil needs at least a first name.' using errcode = 'check_violation';
  end if;

  insert into public.madrasah_pupils as t
    (masjid_id, id, first_name, last_name, joined_on, left_on)
  values (v_masjid, coalesce(v_id, gen_random_uuid()), v_first,
          nullif(btrim(coalesce(p->>'last_name', '')), ''),
          nullif(p->>'joined_on', '')::date,
          nullif(p->>'left_on', '')::date)
  on conflict (id) do update set
    first_name = excluded.first_name, last_name = excluded.last_name,
    joined_on = excluded.joined_on, left_on = excluded.left_on,
    updated_at = now()
  where t.masjid_id = v_masjid
  returning * into v_row;

  if v_row.id is null then
    raise exception 'There is no such pupil at this masjid.' using errcode = 'no_data_found';
  end if;

  --  Classes, if the caller said anything about them. Absent means leave them
  --  alone; an empty array means none, and those are different instructions.
  if p ? 'class_ids' and jsonb_typeof(p->'class_ids') = 'array' then
    delete from public.madrasah_pupil_classes
     where pupil_id = v_row.id and masjid_id = v_masjid;
    insert into public.madrasah_pupil_classes (masjid_id, pupil_id, class_id)
    select v_masjid, v_row.id, c.id
      from jsonb_array_elements_text(p->'class_ids') j
      join public.madrasah_classes c
        on c.id = (j)::uuid and c.masjid_id = v_masjid
    on conflict do nothing;
  end if;

  --  THE AUDIT RECORDS THE ACT, NOT THE CHILD. An admin_audit row is read by
  --  more people and kept longer than the record it describes, so it carries
  --  the pupil's id and never their name.
  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(),
          case when v_id is null then 'madrasah_pupil_added' else 'madrasah_pupil_changed' end,
          jsonb_build_object('id', v_row.id));

  return jsonb_build_object('id', v_row.id);
end $fn$;

create or replace function public.delete_madrasah_pupil(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare v_masjid uuid := public.current_masjid(); v_n integer;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may remove a pupil record.'
      using errcode = '42501';
  end if;
  delete from public.madrasah_pupils where id = p_id and masjid_id = v_masjid;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception 'There is no such pupil at this masjid.' using errcode = 'no_data_found';
  end if;
  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'madrasah_pupil_removed', jsonb_build_object('id', p_id));
  return jsonb_build_object('removed', p_id);
end $fn$;

-- ---------------------------------------------------------------------------
--  8. THE RETENTION RULE, AS A DELETE AND NOT A REMINDER.
--
--     Three years after the child leaves. A policy that says three years while
--     the rows sit there for ten is not a retention period, it is a sentence
--     in a document, and it is the first thing an assessment takes apart.
-- ---------------------------------------------------------------------------
create or replace function public.purge_madrasah_pupils()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare v_m uuid; v_n int; v_total int := 0;
begin
  if auth.uid() is not null and not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may purge pupil records.'
      using errcode = '42501';
  end if;

  for v_m in select * from public.masjids_to_purge() loop
    --  left_on IS NOT NULL is doing real work. A child still at the madrasah
    --  has no leaving date, and `null < anything` is null rather than true —
    --  but relying on that is how a clever condition becomes a disaster when
    --  somebody edits it later. It is said out loud.
    delete from public.madrasah_pupils
     where masjid_id = v_m
       and left_on is not null
       and left_on < (now() at time zone 'Europe/London')::date - interval '3 years';
    get diagnostics v_n = row_count;

    if v_n > 0 then
      insert into public.admin_audit (masjid_id, action, detail)
      values (v_m, 'madrasah_pupils_purged', jsonb_build_object('removed', v_n));
    end if;
    v_total := v_total + v_n;
  end loop;

  return jsonb_build_object('removed', v_total, 'after', '3 years');
end $fn$;

-- ---------------------------------------------------------------------------
--  9. The grants. Revoke first — Postgres grants EXECUTE to PUBLIC.
-- ---------------------------------------------------------------------------
revoke all on function public.madrasah_classes_i_may_see()      from public, anon;
revoke all on function public.madrasah_pupils_in_class(uuid)    from public, anon;
revoke all on function public.madrasah_class_list()             from public, anon;
revoke all on function public.save_madrasah_pupil(jsonb)        from public, anon;
revoke all on function public.delete_madrasah_pupil(uuid)       from public, anon;
revoke all on function public.purge_madrasah_pupils()           from public, anon;

grant execute on function public.madrasah_classes_i_may_see()   to authenticated;
grant execute on function public.madrasah_pupils_in_class(uuid) to authenticated;
grant execute on function public.madrasah_class_list()          to authenticated;
grant execute on function public.save_madrasah_pupil(jsonb)     to authenticated;
grant execute on function public.delete_madrasah_pupil(uuid)    to authenticated;
grant execute on function public.purge_madrasah_pupils()        to authenticated;

-- ---------------------------------------------------------------------------
--  PROVE IT
-- ---------------------------------------------------------------------------
do $check$
declare
  v_cols text;
  v_casc integer;
begin
  --  (a) NOTHING SENSITIVE CREPT INTO THE TABLE. A name, two dates and the
  --      plumbing. Every extra field raises what a breach costs, and the way
  --      they arrive is one at a time because somebody "might as well".
  select string_agg(column_name, ', ' order by column_name) into v_cols
    from information_schema.columns
   where table_schema = 'public' and table_name = 'madrasah_pupils'
     and column_name in ('date_of_birth', 'dob', 'address', 'postcode', 'phone',
                         'email', 'medical', 'medical_notes', 'photo', 'photo_url',
                         'nationality', 'ethnicity', 'nhs_number', 'notes');
  if v_cols is not null then
    raise exception 'madrasah_pupils has grown fields the DPIA did not cover: %. '
                    'Take them out, or widen the assessment first.', v_cols;
  end if;

  --  (b) THE ONE THAT WOULD BE SILENT, AND THE WORST THING IN THIS FILE IF IT
  --      EVER HAPPENED. A safeguarding record must not be deleted by a
  --      three-year pupil purge. Nothing may cascade out of madrasah_pupils
  --      except the class link.
  select count(*) into v_casc
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
   where c.confrelid = 'public.madrasah_pupils'::regclass
     and c.confdeltype = 'c'
     and t.relname <> 'madrasah_pupil_classes';
  if v_casc > 0 then
    raise exception '% table(s) cascade-delete from madrasah_pupils. A concern or '
                    'an incident is kept for many years longer than a pupil record; '
                    'cascading turns the three-year purge into a safeguarding purge '
                    'that nobody would notice.', v_casc;
  end if;

  raise notice 'pupil tables ready; nothing cascades but the class link';
end $check$;

commit;

-- ===========================================================================
--  AFTERWARDS
--
--    select count(*) from public.madrasah_pupils;
--    select count(*) from public.madrasah_pupil_classes;
--
--  AND THE THING THAT STILL HAS TO HAPPEN BEFORE ANY TEACHER SEES A CHILD:
--  madrasah_staff.user_id is null on all forty staff. Until somebody at the
--  masjid ties a teacher's staff record to their sign-in account, a madrasah
--  account resolves to no classes and therefore no pupils. Working as intended,
--  and it will look like a bug to whoever tries it first.
-- ===========================================================================

-- ===========================================================================
--  059_a_class_can_be_removed  (applied separately, 18 September 2026)
--
--  save_madrasah_class() existed since 052; nothing could remove one.
-- ===========================================================================
create or replace function public.delete_madrasah_class(p_id uuid)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp
as $fn$
declare
  v_masjid uuid := public.current_masjid();
  v_row public.madrasah_classes%rowtype;
  v_kids integer;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may remove a class.'
      using errcode = '42501';
  end if;

  select * into v_row from public.madrasah_classes
   where id = p_id and masjid_id = v_masjid;
  if v_row.id is null then
    raise exception 'There is no such class at this masjid.' using errcode = 'no_data_found';
  end if;

  select count(*) into v_kids from public.madrasah_pupil_classes
   where class_id = p_id and masjid_id = v_masjid;

  delete from public.madrasah_classes where id = p_id and masjid_id = v_masjid;

  --  THE COUNT OF BROKEN LINKS GOES IN THE AUDIT. Removing a class with thirty
  --  children in it leaves thirty children in no class; the children are not
  --  touched, only their membership, and somebody should be able to find out
  --  afterwards that it happened.
  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'madrasah_class_removed',
          jsonb_build_object('name', v_row.name, 'pupils_unlinked', v_kids));

  return jsonb_build_object('removed', v_row.name, 'pupils_unlinked', v_kids);
end $fn$;

revoke all on function public.delete_madrasah_class(uuid) from public, anon;
grant execute on function public.delete_madrasah_class(uuid) to authenticated;

-- ===========================================================================
--  THE IMPORT WAS RUN ON 18 SEPTEMBER 2026, AND IT WENT WRONG THE FIRST TIME.
--
--  543 children, 45 classes, from the masjid's own 2026/27 class list. The
--  roll itself is not in this repository and never will be.
--
--  ---------------------------------------------------------------------------
--  THE MISTAKE, WRITTEN DOWN SO IT IS NOT MADE AGAIN
--  ---------------------------------------------------------------------------
--
--  The first attempt inserted the children set-based and then matched them to
--  their classes with:
--
--      row_number() over (order by created_at, id)
--
--  Every one of the 543 rows carries the SAME created_at, because now() is the
--  TRANSACTION timestamp and not the statement timestamp. So the tiebreak was
--  `id` — a random uuid — and the roll came out shuffled. "Boys Year 10" ended
--  up holding two girls from Hafiza B and Class 5B.
--
--  IT PASSED EVERY COUNT. 543 pupils, 543 links, nobody in no class, every
--  class showing exactly the headcount the PDF gave. The totals were perfect
--  and the register was wrong, which is the shape of error that gets accepted.
--
--  What caught it was checking a class against the document by NAME rather
--  than by number — two children in Boys Year 10, and neither was either of
--  the two the document lists.
--
--  THE FIX: carry the source row number ON the pupil for the length of the
--  import (a real column, added and dropped in the same transaction) and join
--  on that. INSERT ... SELECT makes no promise about the order rows are
--  written or handed back, and nothing should be inferred from created_at,
--  ctid or a uuid. If an order matters, store it.
--
--  AND VERIFY WHAT YOU ACTUALLY CARE ABOUT. The second run compared every row
--  to the source on class name, first name and surname, not on counts:
--
--      select count(*) from madrasah_pupils p
--        join <source> r on r.n = p.import_n
--        join madrasah_pupil_classes pc on pc.pupil_id = p.id
--        join madrasah_classes c on c.id = pc.class_id
--       where c.name <> r.cls or p.first_name <> r.f
--          or coalesce(p.last_name,'') <> coalesce(r.l,'');
--
--  Zero. Then per-class counts were reconciled against the PDF independently,
--  outside the database: 45 classes, 543 children, no mismatch.
--
--  ---------------------------------------------------------------------------
--  WHAT IS LEFT FOR THE MADRASAH
--  ---------------------------------------------------------------------------
--    * Ten children share a name with another child. Settle each one:
--
--        select btrim(concat_ws(' ', p.first_name, p.last_name)) as child,
--               count(*) as rows,
--               string_agg(c.name, ' | ' order by c.name) as classes
--          from public.madrasah_pupils p
--          join public.madrasah_pupil_classes pc on pc.pupil_id = p.id
--          join public.madrasah_classes c on c.id = pc.class_id
--         group by 1 having count(*) > 1 order by 1;
--
--      Same child in two classes? Delete one row and link the survivor to
--      both. Two different children? It is already correct.
--
--    * Two children are in "Unlisted — no class heading in the 2026/27 PDF".
--      The document begins part-way through a class, so the heading is simply
--      not there. Somebody has to say which class.
--
--    * No teacher can see any child yet. See the note above about user_id.
-- ===========================================================================
