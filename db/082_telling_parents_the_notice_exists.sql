--  =====================================================================
--  082 - TELLING PARENTS THE NOTICE EXISTS, AND PROVING IT
--  27 September 2026.  DPIA actions A1, A10 and A11.
--  =====================================================================
--
--  PUBLISHING IS NOT PROVIDING. Articles 13 and 14 require the controller to
--  INFORM people. The ICO's position is that you must take an ACTIVE STEP to
--  bring privacy information to somebody's attention; putting a page on a
--  website and waiting to be found informs nobody. The masjid's own notice
--  says so in as many words.
--
--  So the duty is two things:
--      1. publish the notice        - done, /madrasah-privacy/
--      2. TELL PARENTS IT IS THERE, and RECORD THE DATE
--
--  That record is not administration. It is the evidence the duty was
--  discharged, and without it the masjid's position is "we think we told
--  people", which is not a position.
--
--  WHAT THIS DOES NOT DO: send the email. That needs a new message type in
--  the notify Edge Function, which sends every email on the site - bookings,
--  invites, receipts, reminders. That is a deploy to make at the start of a
--  session with room to test it, not at the end of one. The letter is printed
--  from the Notices screen and recorded here, which discharges the duty on
--  its own; the email is a convenience on top.

create table if not exists public.madrasah_parent_notices (
  id            uuid primary key default gen_random_uuid(),
  masjid_id     uuid not null references public.masjids(id) on delete cascade,
  household_id  uuid not null references public.madrasah_households(id) on delete cascade,
  --  What they were told about. 'privacy_notice' is A1; a materially changed
  --  notice later is another row with the same kind and a later date, which
  --  is exactly what "we will tell you before the change takes effect" needs.
  kind          text not null default 'privacy_notice',
  notice_version text not null,
  --  HOW they were told. A letter counts. An email counts. Being handed a
  --  printed copy at the door counts. What does not count is nothing.
  how           text not null check (how in ('letter','email','in_person')),
  told_on       date not null default current_date,
  recorded_by   uuid references auth.users(id),
  recorded_at   timestamptz not null default now(),
  note          text
);

comment on table public.madrasah_parent_notices is
  'Evidence that a family was told the privacy notice exists (UK GDPR Art 13/14, DPIA A1/A10). One row per family per telling.';

create index if not exists madrasah_parent_notices_household_idx
  on public.madrasah_parent_notices (household_id, kind, told_on desc);

alter table public.madrasah_parent_notices enable row level security;

--  NO POLICY IS DELIBERATE. Nothing reaches this table except through the
--  functions below, which check who is asking first. The same rule as every
--  other madrasah table: the records cannot be read directly even by somebody
--  inside the system.
revoke all on public.madrasah_parent_notices from anon, authenticated;

--  =====================================================================
--  WHO HAS BEEN TOLD, AND WHO HAS NOT
--  =====================================================================
--
--  A LIST, so it says WHETHER and not WHAT: the family, whether it can be
--  reached, and whether it has been told. No telephone number, no email
--  address, no home address. Those are on the family's own record, which is a
--  deliberate thing to open. 080's guard discovers this function from the
--  catalogue by its _list suffix and checks it, which is why it is named one.

create or replace function public.madrasah_parent_notice_list(
  p_kind text default 'privacy_notice')
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare
  v_masjid uuid := public.current_masjid();
  v_rows jsonb;
begin
  if not public.verified_madrasah() then
    return jsonb_build_object('allowed', false);
  end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.family), '[]'::jsonb)
    into v_rows
  from (
    select h.id,
           h.reference,
           h.name as family,
           (select count(*) from public.madrasah_pupils pu
             where pu.household_id = h.id and pu.left_on is null) as children,
           exists (select 1 from public.madrasah_guardians g
                    where g.household_id = h.id
                      and nullif(btrim(g.email), '') is not null) as has_email,
           exists (select 1 from public.madrasah_guardians g
                    where g.household_id = h.id
                      and nullif(btrim(g.phone), '') is not null) as has_phone,
           (select max(n.told_on) from public.madrasah_parent_notices n
             where n.household_id = h.id and n.kind = p_kind)      as told_on,
           (select n.how from public.madrasah_parent_notices n
             where n.household_id = h.id and n.kind = p_kind
             order by n.told_on desc limit 1)                      as told_how
      from public.madrasah_households h
     where h.masjid_id = v_masjid
  ) x;

  return jsonb_build_object('allowed', true, 'kind', p_kind, 'rows', v_rows);
end $$;

revoke all on function public.madrasah_parent_notice_list(text) from public, anon;
grant execute on function public.madrasah_parent_notice_list(text) to authenticated;

--  =====================================================================
--  RECORDING THAT A FAMILY HAS BEEN TOLD
--  =====================================================================
--
--  DELIBERATELY NOT idempotent-by-silence. Telling a family twice is not a
--  fault and the second row is not an error; what would be a fault is the
--  office pressing the button and not knowing whether anything happened. The
--  function says how many rows it wrote.

create or replace function public.record_parents_told(
  p_households uuid[],
  p_how text,
  p_version text default '1.2',
  p_kind text default 'privacy_notice',
  p_note text default null)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_masjid uuid := public.current_masjid();
  v_n int := 0;
  v_skipped int := 0;
  v_h uuid;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may '
                    'record that parents have been told.' using errcode = '42501';
  end if;
  if p_how not in ('letter','email','in_person') then
    raise exception 'A family is told by letter, by email or in person. "%" is '
                    'none of those.', p_how using errcode = '22023';
  end if;
  if p_households is null or array_length(p_households, 1) is null then
    return jsonb_build_object('recorded', 0, 'skipped', 0);
  end if;

  foreach v_h in array p_households loop
    if not exists (select 1 from public.madrasah_households h
                    where h.id = v_h and h.masjid_id = v_masjid) then
      v_skipped := v_skipped + 1;
      continue;
    end if;
    insert into public.madrasah_parent_notices
      (masjid_id, household_id, kind, notice_version, how, recorded_by, note)
    values (v_masjid, v_h, p_kind, p_version, p_how, auth.uid(), p_note);
    v_n := v_n + 1;
  end loop;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'parents_told_about_notice',
          jsonb_build_object('families', v_n, 'skipped', v_skipped,
                             'how', p_how, 'kind', p_kind,
                             'notice_version', p_version));

  return jsonb_build_object('recorded', v_n, 'skipped', v_skipped, 'how', p_how);
end $$;

revoke all on function public.record_parents_told(uuid[], text, text, text, text)
  from public, anon;
grant execute on function public.record_parents_told(uuid[], text, text, text, text)
  to authenticated;

--  =====================================================================
--  A11, ENFORCED RATHER THAN WRITTEN DOWN
--  =====================================================================
--
--  DPIA action A11: "Reminders must not be switched on until the notice has
--  reached parents. Writing to somebody about money using contact details
--  they were never told you held is the wrong order."
--
--  Until now that was a sentence in a document, and this repository has spent
--  a fortnight learning what those are worth: the retention policy that had
--  never run, the "sent" that meant nothing, three privacy notices made false
--  by later migrations. Every one was a claim nothing enforced.
--
--  So it is enforced, and PER FAMILY rather than as one switch. A global flag
--  would let the masjid tell 300 families and then write to all 330. This
--  refuses to write to a family that has not been told, records the refusal
--  with its reason, and reports it in the same shape as the existing
--  'no_contact' and 'too_soon' outcomes - so the screen needs no new
--  vocabulary to explain it. See 083: that outcome also had to be added to
--  the table's CHECK constraint, and the only reason anybody found out was
--  that this was exercised rather than read.
--
--  SPLICED, NOT REWRITTEN. The live definition is read and patched, so this
--  migration cannot silently revert whatever else has changed in that
--  function since. If the anchor has moved, nothing changes and it fails.

do $splice$
declare
  src text;
  patched text;
  anchor text := '    if v_bal <= 0 then';
  addition text;
begin
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'send_madrasah_fee_reminders';
  if src is null then
    raise exception 'send_madrasah_fee_reminders() does not exist. Nothing changed.';
  end if;
  if position('not_yet_told' in src) > 0 then
    raise notice 'A11 is already enforced there; left alone.';
    return;
  end if;

  addition :=
    E'    --  A11: a family that has not been told the privacy notice exists\n'
    '    --  is not written to about money. See 082.\n'
    '    if not exists (select 1 from public.madrasah_parent_notices n\n'
    '                    where n.household_id = v_h\n'
    '                      and n.kind = ''privacy_notice'') then\n'
    '      v_reason := ''not_yet_told''; v_no := v_no + 1;\n'
    '    elsif v_bal <= 0 then';

  patched := replace(src, anchor, addition);
  if patched = src then
    raise exception 'The anchor in send_madrasah_fee_reminders() has moved. '
                    'NOTHING was changed, so that it is not rewritten wrongly.';
  end if;
  execute patched;
end $splice$;
