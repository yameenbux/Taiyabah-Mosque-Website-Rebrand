-- ===========================================================================
--  150_ramadan_countdown.sql
--  18 October 2026
--
--  WHY THIS EXISTS
--  The Ramadan countdown is subject to moon sighting — the date moves by a
--  day most years, and the one time it genuinely matters that the website
--  agree with the masjid is the one time a hard-coded date is guaranteed to
--  be a day behind. site_content already solves exactly this for the new
--  build appeal and the hall hire rate card: a row the office can change
--  without a deploy. This gives the countdown the same thing.
--
--  WRITTEN AGAINST WHAT IS ACTUALLY LIVE, NOT AGAINST db/028 OR db/045 AS
--  COMMITTED. Both files in this repo still show set_site_content() with a
--  single-column key primary key and no masjid scoping; the live function
--  already takes site_content through current_masjid() and a composite
--  (masjid_id, key) primary key — multi-tenancy that reached production
--  without a matching file landing in db/. This migration is written to
--  match the live shape (confirmed against pg_proc and pg_constraint before
--  writing a line of it), not the stale copy in git history. Whoever next
--  touches site_content should know the committed 028/045 files are no
--  longer the truth and probably want a migration that brings db/ back in
--  line with what the database has actually been running.
--
--  THE SEED DATE IS AN ASTRONOMICAL ESTIMATE, NOT AN ANNOUNCEMENT. 8 February
--  2027 is the commonly published calculated date for 1 Ramadan 1448 AH —
--  moon sighting still decides the real one. The admin screen this migration
--  enables exists so the office can correct it the moment a sighting is
--  announced, rather than waiting on a developer.
-- ===========================================================================

begin;

do $$
begin
  if to_regprocedure('public.set_site_content(text, jsonb)') is null then
    raise exception 'public.set_site_content(text, jsonb) does not exist.';
  end if;
  if to_regprocedure('public.current_masjid()') is null then
    raise exception 'public.current_masjid() does not exist — this migration assumes multi-tenant site_content, which is not what it finds.';
  end if;
end $$;

-- ---------------------------------------------------------------------------
--  1. What a Ramadan countdown body is allowed to be
--
--  Two fields. starts_on drives the countdown's arithmetic, so it is held to
--  a real calendar date, not merely a string that looks like one. note is
--  the one piece of free text, for exactly the kind of thing that changes
--  the plan without changing the date: "moon not yet sighted", "confirmed
--  by the committee", and so on.
-- ---------------------------------------------------------------------------
create or replace function public.check_ramadan(p jsonb)
returns text
language plpgsql
immutable
set search_path = public, pg_temp
as $fn$
declare
  v_raw  text := btrim(coalesce(p ->> 'starts_on', ''));
  v_note text := btrim(coalesce(p ->> 'note', ''));
  v_date date;
begin
  if p is null or jsonb_typeof(p) <> 'object' then
    return 'The countdown did not arrive as expected. Reload the page and try again.';
  end if;

  if v_raw = '' then
    return 'The date Ramadan is expected to start cannot be empty.';
  end if;
  if v_raw !~ '^\d{4}-\d{2}-\d{2}$' then
    return 'The date must be in the form YYYY-MM-DD, like 2027-02-08.';
  end if;

  --  A string of the right SHAPE is not a real date — "2027-02-30" matches
  --  the regex above and still is not the 30th of February. Caught here
  --  rather than left to crash the countdown on somebody's phone.
  begin
    v_date := v_raw::date;
  exception when others then
    return '"' || v_raw || '" is not a real date.';
  end;

  if length(v_note) > 200 then
    return 'The note is ' || length(v_note) || ' characters. The limit is 200.';
  end if;

  return null;   -- null means fine
end $fn$;

revoke all on function public.check_ramadan(jsonb) from public, anon;

-- ---------------------------------------------------------------------------
--  2. set_site_content(), taught the third key
--
--  Replaced whole, matching the live definition exactly (current_masjid(),
--  the composite on-conflict target, masjid_id on the audit row) plus the
--  ramadan branch.
-- ---------------------------------------------------------------------------
create or replace function public.set_site_content(p_key text, p_body jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_key    text := lower(btrim(p_key));
  v_why    text;
  v_detail jsonb;
  v_masjid uuid := public.current_masjid();
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator may change what the website says.'
      using errcode = '42501';
  end if;

  if v_key = 'newbuild' then
    v_why := public.check_newbuild(p_body);
  elsif v_key = 'hallhire' then
    v_why := public.check_hallhire(p_body);
  elsif v_key = 'ramadan' then
    v_why := public.check_ramadan(p_body);
  else
    raise exception 'There is no editable section called %.', v_key
      using errcode = 'check_violation';
  end if;

  if v_why is not null then
    raise exception '%', v_why using errcode = 'check_violation';
  end if;

  insert into public.site_content (masjid_id, key, body, updated_by)
  values (v_masjid, v_key, p_body, auth.uid())
  on conflict (masjid_id, key) do update
    set body = excluded.body, updated_at = now(), updated_by = excluded.updated_by;

  if v_key = 'newbuild' then
    v_detail := jsonb_build_object(
      'key',      v_key,
      'raised_p', p_body -> 'appeal' -> 'raised_p',
      'target_p', p_body -> 'appeal' -> 'target_p',
      'phases',   jsonb_array_length(p_body -> 'timeline'));
  elsif v_key = 'hallhire' then
    v_detail := jsonb_build_object(
      'key',    v_key,
      'bands',  jsonb_array_length(p_body -> 'bands'),
      'prices', (select string_agg(l->>'n' || ' ' || (l->>'p'), ' · ')
                   from jsonb_array_elements(p_body -> 'bands') b,
                        jsonb_array_elements(b -> 'lines') l));
  else
    v_detail := jsonb_build_object(
      'key',       v_key,
      'starts_on', p_body ->> 'starts_on',
      'note',      p_body ->> 'note');
  end if;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'site_content_changed', v_detail);

  return jsonb_build_object('key', v_key, 'updated_at', now());
end $fn$;

revoke all     on function public.set_site_content(text, jsonb) from public, anon;
grant  execute on function public.set_site_content(text, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
--  3. The seed
--
--  Same masjid_id the newbuild and hallhire rows already carry — read from
--  one of them rather than hardcoded, so this migration still does the
--  right thing if that id ever turns out to differ from what was assumed
--  while writing it. `on conflict do nothing`: re-running this migration
--  must never overwrite a date the office has since set.
-- ---------------------------------------------------------------------------
insert into public.site_content (masjid_id, key, body)
select masjid_id, 'ramadan', jsonb_build_object(
  'starts_on', '2027-02-08',
  'note', 'Astronomical estimate — subject to moon sighting. We will confirm here as soon as the committee announces it.'
)
from public.site_content where key = 'newbuild'
on conflict (masjid_id, key) do nothing;

-- ---------------------------------------------------------------------------
--  4. Prove the validator accepts the seed, and refuses what it claims to
-- ---------------------------------------------------------------------------
do $check$
declare
  v_seed jsonb;
  v_why  text;
begin
  select body into v_seed from public.site_content where key = 'ramadan';
  v_why := public.check_ramadan(v_seed);
  if v_why is not null then
    raise exception 'check_ramadan() refuses the seed it was written for: %', v_why;
  end if;

  if public.check_ramadan(v_seed || jsonb_build_object('starts_on', '')) is null then
    raise exception 'an empty date was accepted'; end if;
  if public.check_ramadan(v_seed || jsonb_build_object('starts_on', '8 February 2027')) is null then
    raise exception 'a non-ISO date was accepted'; end if;
  if public.check_ramadan(v_seed || jsonb_build_object('starts_on', '2027-02-30')) is null then
    raise exception 'the 30th of February was accepted'; end if;
  if public.check_ramadan(v_seed || jsonb_build_object('note', repeat('x', 201))) is null then
    raise exception 'a 201-character note was accepted'; end if;

  raise notice 'check_ramadan() accepts the seed and refuses all four bad bodies.';
end $check$;

commit;

-- ===========================================================================
--  AFTERWARDS
--
--    select body from public.site_content where key = 'ramadan';
--
--  And as anon, which must still work — the website reads this table
--  directly and a countdown nobody can read is a blank panel:
--
--    select body from public.site_content where key = 'ramadan';   -- 1 row
--    select public.set_site_content('ramadan', '{}'::jsonb);       -- denied
-- ===========================================================================
