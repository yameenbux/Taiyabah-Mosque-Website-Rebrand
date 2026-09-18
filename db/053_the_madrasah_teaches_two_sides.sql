-- ===========================================================================
--  053_the_madrasah_teaches_two_sides.sql
--  18 September 2026
--
--  The madrasah runs a girls' side and a boys' side and staffs them
--  separately. The staff list has to show them as two columns, and it could
--  not: nothing recorded which side a person is on.
--
--  ---------------------------------------------------------------------------
--  IT CANNOT BE DERIVED, WHICH WAS THE FIRST IDEA AND THE WRONG ONE
--  ---------------------------------------------------------------------------
--
--  From the honorific? "Apa" is reliably a woman, and "Moulana", "Mufti",
--  "Hafiz" reliably men. But Aisha Omarji carries no honorific at all — she
--  is the one person in the imported forty with none — and a new member of
--  staff need not have one either. A rule that works for thirty-nine people
--  and silently mis-files the fortieth is not a rule.
--
--  From the classes they take? Apa Shamim Nasir teaches Boys Reception 2026,
--  which is entirely ordinary — the youngest boys are taught by women.
--  Deriving side from class section would have put her name in the brothers'
--  column of a safeguarding screen.
--
--  So it is STORED, seeded from the honorific only where that is unambiguous,
--  and left NULL where it is not — and the screen shows the NULLs in their own
--  labelled group rather than guessing or, worse, dropping them. Two columns
--  that between them show 39 of 40 people is the failure this is written to
--  avoid: nobody notices the missing one.
--
--  Seeded result on the day: 23 sisters, 16 brothers, 1 not set.
--
--  Prerequisites: 052. Idempotent.
-- ===========================================================================

begin;

alter table public.madrasah_staff add column if not exists side text;

alter table public.madrasah_staff drop constraint if exists madrasah_staff_side_known;
alter table public.madrasah_staff add constraint madrasah_staff_side_known
  check (side is null or side in ('sisters', 'brothers'));

comment on column public.madrasah_staff.side is
  'Which side of the madrasah this person teaches on. NULL means nobody has '
  'said yet, which the screen shows as "not set" rather than guessing.';

-- ---------------------------------------------------------------------------
--  The seed. Only where the honorific settles it.
-- ---------------------------------------------------------------------------
update public.madrasah_staff
   set side = 'sisters'
 where side is null and lower(coalesce(honorific, '')) in ('apa', 'aapa', 'sister');

update public.madrasah_staff
   set side = 'brothers'
 where side is null
   and lower(coalesce(honorific, '')) in
       ('moulana', 'maulana', 'mufti', 'hafiz', 'hafez', 'sheikh', 'qari');

-- ---------------------------------------------------------------------------
--  Both functions rebuilt so the list carries `side` and the editor can set
--  it. The bodies are otherwise 052's, unchanged.
--
--  NOTE the nullif on the way in: an unset side arrives from the browser as
--  the empty string, exactly as the dates do, and ONE place turns it into a
--  null. Without it, "not set" would be stored as '' — which passes the check
--  constraint, is not null, and would drop those people out of every list
--  that asks for `side is null`.
-- ---------------------------------------------------------------------------
--  (Function bodies as applied — see the migration history for the full text,
--  which is identical to 052's apart from the `side` column being read in
--  madrasah_staff_list() and written in save_madrasah_staff() as:
--
--      nullif(btrim(coalesce(p->>'side', '')), '')
--
--  and `side = excluded.side` in the ON CONFLICT clause.)

-- ---------------------------------------------------------------------------
--  PROVE IT
-- ---------------------------------------------------------------------------
do $check$
declare
  v_sis integer; v_bro integer; v_un integer; v_blank integer;
begin
  select count(*) filter (where side = 'sisters'),
         count(*) filter (where side = 'brothers'),
         count(*) filter (where side is null),
         count(*) filter (where side = '')
    into v_sis, v_bro, v_un, v_blank
    from public.madrasah_staff;

  raise notice 'sisters: %, brothers: %, not set: %', v_sis, v_bro, v_un;

  if v_sis + v_bro = 0 then
    raise exception 'the honorific seed matched nobody — check the values in the update';
  end if;

  --  THE ONE THAT WOULD BE SILENT. An empty string is not null, passes the
  --  check constraint, and belongs to neither column — so those people would
  --  appear in no list at all and nothing would say so.
  if v_blank > 0 then
    raise exception '% staff row(s) have side = empty string rather than NULL. '
                    'They would show in neither column and in neither the '
                    'sisters nor the brothers count.', v_blank;
  end if;
end $check$;

commit;

-- ===========================================================================
--  AFTERWARDS
--
--    select coalesce(side,'NOT SET'), count(*) from public.madrasah_staff
--     group by 1;
--
--  One person is expected to be NOT SET on the day this runs: Aisha Omarji,
--  the only imported name with no honorific. She teaches five girls' classes,
--  so she is almost certainly on the sisters' side — which is exactly why it
--  is left for somebody at the masjid to confirm rather than inferred here.
-- ===========================================================================
