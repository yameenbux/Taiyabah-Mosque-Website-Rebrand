--  =====================================================================
--  080 — THE FAMILIES SCREEN, AND A GUARD THAT COVERS MORE THAN TWO LISTS
--  27 September 2026
--  =====================================================================
--
--  The Families screen is almost entirely a screen-only job: 079 and earlier
--  left behind everything it needs to read and write —
--
--      madrasah_household_list(p_q)          330 families, as a jsonb array
--      madrasah_household_one(p_id)          one family, with its people
--      set_pupil_household(p_pupil, p_id)    move a child
--      save_madrasah_household(p)            create or amend
--      madrasah_sibling_suggestions_list()   the pairs from the import
--      settle_sibling_suggestion(p_id, p_join)
--
--  Two things were missing, and this migration adds them.
--
--  =====================================================================
--  ONE. TAKING A LIST OF FAMILIES AWAY
--  =====================================================================
--
--  Same shape as madrasah_roll_export, and deliberately so: the office should
--  not have to learn two export dialogs. Same two levels, same audit, same
--  heading block written into the file.
--
--  WHAT IS DIFFERENT, AND WHY IT IS DIFFERENT. The pupil export withholds
--  telephone numbers and addresses behind p_detail because they belong to the
--  family, not the child. Here they ARE the point — a family list without a
--  way to reach anybody is a list of names. So the plain level still gives no
--  contact details at all, and the detailed level gives the FIRST guardian
--  only, not all of them.
--
--  That last restriction is worth stating because it looks like laziness. A
--  family with four guardians has four telephone numbers; a spreadsheet of
--  all of them, sitting in somebody's Downloads folder, is four times the
--  breach for no extra use. Whoever needs the second number can open the
--  family, which is one click and is written down.

create or replace function public.madrasah_audit_family_export(
  p_masjid uuid, p_detail boolean, p_rows integer,
  p_who text, p_when timestamptz, p_said text, p_filter jsonb)
returns void language sql security definer
set search_path = public, pg_temp as $$
  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (p_masjid, auth.uid(),
          case when p_detail then 'families_exported_full'
                             else 'families_exported_list' end,
          jsonb_build_object(
            'rows', p_rows,
            'taken_by', p_who,
            'taken_at', p_when,
            'filter_said', p_said,
            'columns', case when p_detail
                       then 'reference, family, children, guardians, contactable, '
                            || 'first guardian, telephone, email, address'
                       else 'reference, family, children, guardians, contactable' end,
            'filter', p_filter,
            'note', 'no child is named in either level of this file'));
$$;

revoke all on function public.madrasah_audit_family_export(
  uuid, boolean, integer, text, timestamptz, text, jsonb) from public, anon;

--  NO CHILD IS NAMED IN THIS FILE, at either level, and that is not an
--  oversight to be helpfully corrected later. A spreadsheet that puts a
--  child's name next to their home address and their mother's mobile number
--  is the single worst artefact this system could produce, and the reason the
--  register export was built the way it was. A family list says "the Ashrafi
--  family, three children". Whoever needs to know which three opens the
--  family.
--
--  SURNAME REDACTED, 28 September 2026. A real family's surname stood where
--  "Ashrafi" now does - in a file whose own heading says no child is named in
--  it, in a repository that is PUBLIC, written the same day as the paragraph
--  above arguing that a name next to an address is the worst artefact this
--  system could produce. It had been there since 27 September. The example
--  never needed a real name to make its point, which is the point.

create or replace function public.madrasah_family_export(
  p_detail boolean default false,
  p_filter jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_masjid uuid := public.current_masjid();
  v_need   text := nullif(p_filter ->> 'need', '');
  v_rows   jsonb;
  v_n      int;
  v_who    text;
  v_name   text;
  v_said   text;
  v_when   timestamptz := now();
begin
  if p_detail then
    if not public.verified_admin() then
      raise exception 'A list with telephone numbers and addresses is for '
                      'administrators who have completed two-step.'
        using errcode = '42501';
    end if;
  else
    if not public.verified_madrasah() then
      raise exception 'Only madrasah staff may take a list of families.'
        using errcode = '42501';
    end if;
  end if;

  --  The screen's own four filters, and nothing else. An unknown value is
  --  refused rather than ignored: a filter that silently does nothing hands
  --  somebody a file of 330 families when they asked for the 6 with nobody to
  --  ring, and the heading would agree with them.
  if v_need is not null and v_need not in ('noone','nophone','single','big') then
    raise exception 'That is not a filter this screen offers.' using errcode = '22023';
  end if;

  v_said := case v_need
              when 'noone'   then 'families with no telephone number and no email address'
              when 'nophone' then 'families with an email address but no telephone number'
              when 'single'  then 'families with one child'
              when 'big'     then 'families with four or more children'
              else 'every family on the register' end;

  select coalesce(nullif(btrim(pr.full_name), ''), 'a member of staff')
    into v_who from public.profiles pr where pr.id = auth.uid();
  v_who := coalesce(v_who, 'a member of staff');

  select coalesce(m.name, 'Taiyabah Masjid') into v_name
    from public.masjids m where m.id = v_masjid;

  with h as (
    select hh.id, hh.reference, hh.name, hh.note,
           (select count(*) from public.madrasah_pupils pu
             where pu.household_id = hh.id and pu.left_on is null) as kids,
           (select count(*) from public.madrasah_guardians g
             where g.household_id = hh.id) as guards,
           exists (select 1 from public.madrasah_guardians g
                    where g.household_id = hh.id
                      and nullif(btrim(g.phone), '') is not null) as any_phone,
           exists (select 1 from public.madrasah_guardians g
                    where g.household_id = hh.id
                      and nullif(btrim(g.email), '') is not null) as any_email
      from public.madrasah_households hh
     where hh.masjid_id = v_masjid
  )
  select jsonb_agg(to_jsonb(x) order by x.family), count(*)
    into v_rows, v_n
  from (
    select h.reference,
           h.name as family,
           h.kids   as children,
           h.guards as guardians,
           case when h.any_phone then 'Telephone'
                when h.any_email then 'Email only'
                else 'NOBODY TO RING' end as contactable,
           case when p_detail then
             (select g.full_name from public.madrasah_guardians g
               where g.household_id = h.id
               order by g.is_primary desc nulls last, g.full_name limit 1)
           end as first_guardian,
           case when p_detail then
             (select g.phone from public.madrasah_guardians g
               where g.household_id = h.id
                 and nullif(btrim(g.phone), '') is not null
               order by g.is_primary desc nulls last, g.full_name limit 1)
           end as telephone,
           case when p_detail then
             (select g.email from public.madrasah_guardians g
               where g.household_id = h.id
                 and nullif(btrim(g.email), '') is not null
               order by g.is_primary desc nulls last, g.full_name limit 1)
           end as email,
           case when p_detail then h.note end as address
      from h
     where (v_need is null)
        or (v_need = 'noone'   and not h.any_phone and not h.any_email)
        or (v_need = 'nophone' and not h.any_phone and h.any_email)
        or (v_need = 'single'  and h.kids = 1)
        or (v_need = 'big'     and h.kids >= 4)
  ) x;

  perform public.madrasah_audit_family_export(
    v_masjid, p_detail, coalesce(v_n, 0), v_who, v_when, v_said,
    jsonb_strip_nulls(jsonb_build_object('need', v_need)));

  return jsonb_build_object('allowed', true,
    'detail', p_detail,
    'rows', coalesce(v_rows, '[]'::jsonb),
    'count', coalesce(v_n, 0),
    'heading', jsonb_build_object(
      'masjid',  v_name || ' — Madrasah',
      'what',    case when p_detail then 'Families, with contact details'
                      else 'Families' end,
      'taken',   'Taken ' || to_char(v_when at time zone 'Europe/London',
                                     'DD Month YYYY "at" HH24:MI') || ' by ' || v_who,
      'filter',  'Showing: ' || v_said,
      'count',   v_n || case when v_n = 1 then ' family' else ' families' end,
      'note',    'No child is named in this file.'));
end $$;

revoke all on function public.madrasah_family_export(boolean, jsonb) from public, anon;
grant execute on function public.madrasah_family_export(boolean, jsonb) to authenticated;

--  =====================================================================
--  TWO. THE GUARD WAS WATCHING TWO LISTS OUT OF FIVE
--  =====================================================================
--
--  079 gave madrasah_list_minimisation a default of exactly the two lists
--  that existed when it was written:
--
--      array['madrasah_roll', 'madrasah_roll_export']
--
--  health_check() calls it with no arguments, so that default IS the coverage.
--  Every list function added since — the family list, the family export, the
--  pupils-for-family picker — was outside it, and would have been outside it
--  for good, because nothing about adding a list reminds anybody to widen a
--  default argument three migrations back.
--
--  That is the same failure as the DPIA's: a check written against the system
--  as it stood, with nothing to notice the system moving. The difference here
--  is that it is cheap to fix properly.
--
--  So the default is no longer a list of names. It is every function whose
--  name says it is a list, discovered from the catalogue. A list added next
--  month is covered on the day it is created, by nobody.

create or replace function public.madrasah_list_minimisation(
  p_lists text[] default null)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare
  detail text[] := array['medical', 'allergies', 'send_detail', 'ehcp_detail'];
  fn text; col text; src text; bad text[] := '{}'; seen int := 0;
  hits int; tested int;
  v_lists text[];
begin
  --  DISCOVERED, NOT LISTED. Anything madrasah_* that reads like a list or an
  --  export, minus the two that are deliberately records rather than lists:
  --  madrasah_pupil_one and madrasah_admission_one are ALLOWED to carry
  --  medical notes — that is the whole point of the list/record split.
  if p_lists is null then
    select array_agg(p.proname order by p.proname) into v_lists
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname like 'madrasah%'
       and (p.proname like '%\_list' or p.proname like '%\_export'
            or p.proname = 'madrasah_roll'
            or p.proname like '%_for_family');
    v_lists := coalesce(v_lists, '{}');
  else
    v_lists := p_lists;
  end if;

  foreach fn in array v_lists loop
    select pg_get_functiondef(p.oid) into src
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = fn limit 1;
    if src is null then continue; end if;
    seen := seen + 1;
    --  A function may SAY "no medical column is ever included"; it may not
    --  select one. So the commentary is stripped before looking.
    src := regexp_replace(src, '--[^\n]*', '', 'g');
    foreach col in array detail loop
      select count(*) into hits from regexp_matches(
        src, '\m[a-z_]+\.' || col || '\M', 'gi') m;
      select count(*) into tested from regexp_matches(
        src, '\m[a-z_]+\.' || col || '\M\s+is\s+(not\s+)?null', 'gi') m;
      if hits > tested then
        bad := bad || (fn || ' returns ' || col || ' ('
                    || (hits - tested) || ' mention(s) that are not a null test)');
      end if;
    end loop;
  end loop;

  return jsonb_build_object(
    'ok', array_length(bad, 1) is null,
    'checked', seen,
    'lists', to_jsonb(v_lists),
    'detail', case when array_length(bad, 1) is null
      then seen || ' list function(s) test detail columns but never return them'
      else 'A LIST HAS LEARNED A DETAIL COLUMN: ' || array_to_string(bad, '; ') end);
end $$;

revoke all on function public.madrasah_list_minimisation(text[]) from public, anon;
grant execute on function public.madrasah_list_minimisation(text[]) to authenticated;
