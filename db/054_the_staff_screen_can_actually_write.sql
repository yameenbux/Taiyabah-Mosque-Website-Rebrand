-- ===========================================================================
--  054_the_staff_screen_can_actually_write.sql
--  18 September 2026
--
--  Two faults, one cause, plus one thing the masjid asked for.
--
--  ---------------------------------------------------------------------------
--  1. NOBODY COULD SAVE ANYBODY. THIS PROJECT BROKE IT IN 053.
--  ---------------------------------------------------------------------------
--
--  Reported from the screen:
--
--      Nothing was saved — null value in column "masjid_id" of relation
--      "madrasah_staff" violates not-null constraint
--
--  Every table in this database carries `masjid_id not null` with NO DEFAULT,
--  and every write function is expected to fill it from current_masjid().
--  save_madrasah_class() does. save_madrasah_staff() did too — until 053
--  rebuilt it from the text in 052, which predates the tenancy columns, and
--  silently dropped the masjid_id out of the insert. The same rebuild dropped
--  the `where s.masjid_id = current_masjid()` out of madrasah_staff_list().
--
--  Proof it was the rebuild and not the original:
--
--      proname               scoped
--      madrasah_classes_list  true    -- 053 did not touch it
--      save_madrasah_class    true    -- 053 did not touch it
--      madrasah_staff_list    FALSE   -- 053 rebuilt it
--      save_madrasah_staff    FALSE   -- 053 rebuilt it
--
--  Exactly the two functions 053 rewrote are exactly the two that lost it.
--
--  It failed on AMEND as well as on ADD, which is worth saying plainly: the
--  not-null is checked on the proposed row before ON CONFLICT ever looks for a
--  conflict, so `insert ... on conflict (id) do update` throws before it can
--  find the existing record. Not one save has ever succeeded on that screen.
--
--  THE LESSON, WRITTEN DOWN WHERE THE NEXT MIGRATION WILL SEE IT: 053's file
--  says "(Function bodies as applied — see the migration history for the full
--  text)" instead of carrying them. That is why nobody could read the diff and
--  see a column go missing. A migration that rebuilds a function prints the
--  function. This file does.
--
--  ---------------------------------------------------------------------------
--  2. THE OLD SYSTEM'S NAME COMES OFF THE RECORDS
--  ---------------------------------------------------------------------------
--
--  All forty imported rows had a sentence sitting in `note`, the madrasah's
--  own free-text field, which opened by naming the software they came out of
--  and went on to report what it had said about that person's DBS and that no
--  certificate date came across with them.
--
--  The masjid asked for that name to come off the records. Two things were
--  wrong with the sentence beyond the name. It squats in a field that
--  belongs to whoever is using this system — open anybody's record and
--  the notes box is already full of somebody else's sentence. And the first
--  volunteer to type a real note over it destroys the only record of what the
--  previous system said about that person's DBS.
--
--  That fact is worth keeping. Every one of the forty shows "Nothing on file"
--  today, because no certificate date was in the export and none was invented.
--  So the screen cannot presently tell apart the twenty-two who probably hold
--  a valid certificate from the sixteen who appear to hold none — and those
--  sixteen are the actual safeguarding question. Deleting the notes outright
--  would have thrown that away.
--
--  So it moves to a column of its own, `prior_dbs`, holding one word, with no
--  vendor named anywhere; `note` is handed back empty. The column clears
--  itself the moment somebody keys in a real certificate date or ticks "not
--  required", because from then on it is a stale claim about a question this
--  system can now answer for itself.
--
--  Prerequisites: 052, 053. Idempotent.
-- ===========================================================================

begin;

-- ---------------------------------------------------------------------------
--  1. What the previous system recorded, in its own column
-- ---------------------------------------------------------------------------
alter table public.madrasah_staff add column if not exists prior_dbs text;

alter table public.madrasah_staff drop constraint if exists madrasah_staff_prior_dbs_known;
alter table public.madrasah_staff add constraint madrasah_staff_prior_dbs_known
  check (prior_dbs is null or prior_dbs in ('valid', 'none', 'expired'));

comment on column public.madrasah_staff.prior_dbs is
  'What the system this madrasah used before recorded about this person''s DBS, '
  'as one word, brought over at import. It is NOT evidence and NOT a state - '
  'dbs_state() ignores it. It exists only so that "we have nothing on file" can '
  'be told apart from "the old records said there was nothing". Cleared by '
  'save_madrasah_staff() as soon as a real certificate date is entered.';

--  The backfill reads the sentence the import left behind. Matched on the word
--  after "DBS: " rather than on the whole sentence, so a row somebody has
--  already edited around still gets read correctly.
update public.madrasah_staff
   set prior_dbs = case
         when note ~* 'DBS:\s*Valid'   then 'valid'
         when note ~* 'DBS:\s*Expired' then 'expired'
         when note ~* 'DBS:\s*None'    then 'none'
       end
 where prior_dbs is null
   and note is not null
   and note ~* 'DBS:\s*(Valid|Expired|None)';

--  And the note is handed back. Only where it is the import's own sentence —
--  a note somebody has since written is theirs and is not touched.
update public.madrasah_staff
   set note = null
 where note is not null
   and note ~* 'certificate DATE was not in the export'
   and prior_dbs is not null;

-- ---------------------------------------------------------------------------
--  2. Reading the staff list. Scoped to this masjid, and carrying prior_dbs.
-- ---------------------------------------------------------------------------
create or replace function public.madrasah_staff_list()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_masjid uuid := public.current_masjid();
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may see the madrasah staff.'
      using errcode = '42501';
  end if;

  --  No masjid selected is an empty list, not an error and NOT everybody's
  --  staff. A null v_masjid compared with `=` matches no row, but saying so
  --  out loud beats relying on that.
  if v_masjid is null then
    return '[]'::jsonb;
  end if;

  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.sort_last, x.sort_first)
      from (
        select s.id, s.honorific, s.first_name, s.last_name, s.side,
               btrim(concat_ws(' ', s.honorific, s.first_name, s.last_name)) as display_name,
               s.employment, s.started_on, s.left_on, s.work_days,
               s.dbs_issued, s.dbs_update_service, s.dbs_last_checked,
               s.dbs_not_required,
               public.dbs_state(s.dbs_issued, s.dbs_update_service,
                                s.dbs_last_checked, s.dbs_not_required) as dbs,
               s.prior_dbs,
               s.email, s.phone, s.note,
               --  Their classes, as names, so the screen needs one call. The
               --  join is scoped too: a class id from another masjid must not
               --  turn into a class name here.
               coalesce((
                 select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name)
                                  order by c.sort_order, c.name)
                   from public.madrasah_staff_classes sc
                   join public.madrasah_classes c
                     on c.id = sc.class_id and c.masjid_id = v_masjid
                  where sc.staff_id = s.id
                    and sc.masjid_id = v_masjid), '[]'::jsonb) as classes,
               --  Sorted by SURNAME. See 052's header.
               lower(coalesce(nullif(btrim(s.last_name), ''), s.first_name)) as sort_last,
               lower(s.first_name) as sort_first
          from public.madrasah_staff s
         where s.masjid_id = v_masjid
      ) x
  ), '[]'::jsonb);
end $fn$;

-- ---------------------------------------------------------------------------
--  3. Writing one. The masjid_id goes in, which is the whole bug.
-- ---------------------------------------------------------------------------
create or replace function public.save_madrasah_staff(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_id     uuid := nullif(p->>'id', '')::uuid;
  v_first  text := btrim(coalesce(p->>'first_name', ''));
  v_days   text[];
  v_row    public.madrasah_staff%rowtype;
  v_masjid uuid := public.current_masjid();
  v_issued date := nullif(p->>'dbs_issued', '')::date;
  v_nr     boolean := coalesce((p->>'dbs_not_required')::boolean, false);
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may change the madrasah staff.'
      using errcode = '42501';
  end if;

  if v_masjid is null then
    raise exception 'No masjid is selected, so there is nowhere to put this person.'
      using errcode = '42501';
  end if;

  if v_first = '' then
    raise exception 'A member of staff needs at least a first name.'
      using errcode = 'check_violation';
  end if;

  if p ? 'work_days' and jsonb_typeof(p->'work_days') = 'array' then
    select array_agg(lower(btrim(d))) into v_days
      from jsonb_array_elements_text(p->'work_days') d;
  end if;

  insert into public.madrasah_staff as s (
    masjid_id, id, honorific, first_name, last_name, side, employment,
    started_on, left_on, work_days, dbs_issued, dbs_update_service,
    dbs_last_checked, dbs_not_required, email, phone, note)
  values (
    v_masjid,
    coalesce(v_id, gen_random_uuid()),
    nullif(btrim(coalesce(p->>'honorific', '')), ''),
    v_first,
    nullif(btrim(coalesce(p->>'last_name', '')), ''),
    nullif(btrim(coalesce(p->>'side', '')), ''),
    coalesce(nullif(p->>'employment', ''), 'employed'),
    nullif(p->>'started_on', '')::date,
    nullif(p->>'left_on', '')::date,
    v_days,
    v_issued,
    coalesce((p->>'dbs_update_service')::boolean, false),
    nullif(p->>'dbs_last_checked', '')::date,
    v_nr,
    nullif(btrim(coalesce(p->>'email', '')), ''),
    nullif(btrim(coalesce(p->>'phone', '')), ''),
    nullif(btrim(coalesce(p->>'note', '')), ''))
  on conflict (id) do update set
    honorific = excluded.honorific,
    first_name = excluded.first_name,
    last_name = excluded.last_name,
    side = excluded.side,
    employment = excluded.employment,
    started_on = excluded.started_on,
    left_on = excluded.left_on,
    work_days = excluded.work_days,
    dbs_issued = excluded.dbs_issued,
    dbs_update_service = excluded.dbs_update_service,
    dbs_last_checked = excluded.dbs_last_checked,
    dbs_not_required = excluded.dbs_not_required,
    email = excluded.email,
    phone = excluded.phone,
    note = excluded.note,
    --  ONCE THIS SYSTEM KNOWS, THE OLD SYSTEM'S WORD IS STALE. A certificate
    --  date or a "not required" answers the question outright, so the note
    --  about what somebody else's records used to say stops being shown and
    --  stops being kept. Take either away again and it does NOT come back,
    --  which is correct: it was only ever a stand-in for not knowing.
    prior_dbs = case
      when excluded.dbs_issued is not null or excluded.dbs_not_required
        then null else s.prior_dbs end,
    updated_at = now()
  --  The tenancy guard on the UPDATE half. Without it, anybody who could
  --  guess a uuid could amend another masjid's staff record through this
  --  function, because ON CONFLICT finds the row by primary key alone.
  where s.masjid_id = v_masjid
  returning * into v_row;

  --  A conflict that the WHERE then rejected updates nothing and returns
  --  nothing. Saying so is the difference between "you cannot do that" and a
  --  screen that reports success over a record it never wrote.
  if v_row.id is null then
    raise exception 'There is no such member of staff at this masjid.'
      using errcode = 'no_data_found';
  end if;

  --  The classes, if the caller said anything about them. Absent means
  --  "leave them alone"; an empty array means "none", and those are
  --  different instructions.
  if p ? 'class_ids' and jsonb_typeof(p->'class_ids') = 'array' then
    delete from public.madrasah_staff_classes
     where staff_id = v_row.id and masjid_id = v_masjid;

    --  The join to madrasah_classes is not decoration: it is what stops a
    --  class id belonging to another masjid being attached to this person.
    insert into public.madrasah_staff_classes (masjid_id, staff_id, class_id)
    select v_masjid, v_row.id, c.id
      from jsonb_array_elements_text(p->'class_ids') j
      join public.madrasah_classes c
        on c.id = (j)::uuid and c.masjid_id = v_masjid
    on conflict do nothing;
  end if;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(),
          case when v_id is null then 'madrasah_staff_added' else 'madrasah_staff_changed' end,
          jsonb_build_object('id', v_row.id,
                             'name', btrim(concat_ws(' ', v_row.honorific,
                                                     v_row.first_name, v_row.last_name))));

  return jsonb_build_object('id', v_row.id);
end $fn$;

-- ---------------------------------------------------------------------------
--  4. The grants. Revoke first — Postgres grants EXECUTE to PUBLIC.
-- ---------------------------------------------------------------------------
revoke all on function public.madrasah_staff_list()      from public, anon;
revoke all on function public.save_madrasah_staff(jsonb) from public, anon;
grant execute on function public.madrasah_staff_list()      to authenticated;
grant execute on function public.save_madrasah_staff(jsonb) to authenticated;

-- ---------------------------------------------------------------------------
--  PROVE IT
-- ---------------------------------------------------------------------------
do $check$
declare
  v_named  integer;
  v_prior  integer;
  v_left   integer;
  v_scoped boolean;
begin
  --  (a) The old system's name is gone from every record.
  --
  --      THE ONE PLACE IT STILL APPEARS IN THIS REPOSITORY IS THE NEXT LINE,
  --      and it has to, because a check for "that word is absent" cannot be
  --      written without the word. Nothing renders this file and nothing
  --      displays it; it runs once, against the database, and fails the
  --      migration if a single record still carries the name.
  select count(*) into v_named
    from public.madrasah_staff
   where coalesce(note, '') ~* 'ibeams';
  if v_named > 0 then
    raise exception '% staff note(s) still name the old system.', v_named;
  end if;

  --  (b) And what it said was kept, not deleted. Forty rows were imported and
  --      every one of them carried a DBS word.
  select count(*) filter (where prior_dbs is not null),
         count(*) filter (where note is not null)
    into v_prior, v_left
    from public.madrasah_staff;
  raise notice 'prior DBS words kept: %, notes still holding text: %', v_prior, v_left;
  if v_prior = 0 then
    raise exception 'the notes were cleared without keeping what they said about DBS';
  end if;

  --  (c) THE ONE THAT WOULD HAVE CAUGHT 053. Both functions name
  --      current_masjid(); neither can be rebuilt without it again in silence.
  select bool_and(pg_get_functiondef(p.oid) like '%current_masjid%')
    into v_scoped
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('madrasah_staff_list', 'save_madrasah_staff');
  if not coalesce(v_scoped, false) then
    raise exception 'a madrasah staff function is not scoped to a masjid';
  end if;
end $check$;

commit;

-- ===========================================================================
--  AFTERWARDS
--
--    select coalesce(prior_dbs,'(none recorded)'), count(*)
--      from public.madrasah_staff group by 1 order by 2 desc;
--
--  Expected on the day this runs: valid 22, expired 2, none 16.
--
--  Those SIXTEEN are the job. They are people working with children for whom
--  the previous system held nothing, and this one holds nothing either. The
--  twenty-two still need their certificate dates keyed in before the screen
--  can say anything about them under its own authority.
-- ===========================================================================
