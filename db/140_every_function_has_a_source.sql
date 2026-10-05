-- ===========================================================================
--  140 — every function has a source
--
--  Taiyabah Masjid · 5 October 2026
--
--  WHAT THIS FILE IS, AND WHY IT IS NOT A CHANGE
--  ---------------------------------------------
--  Thirty-five functions were running in this database with no CREATE
--  statement anywhere in db/ — counted by listing pg_proc and grepping the
--  numbered migrations for each name, not by remembering. They were written
--  straight into the Supabase SQL editor and never came back.
--
--  Thirty-four of them are below, read out of pg_get_functiondef() on
--  5 October 2026 and recorded verbatim. The thirty-fifth is masjid_theme(text),
--  which is left out on purpose — see the foot of this file.
--
--  Applying it to production changes nothing, and that is the test of whether
--  it is right. Every statement is CREATE OR REPLACE over a body that is
--  already there, so md5(prosrc) is the same before and after. If applying it
--  moves a fingerprint, the capture is wrong and the right response is to fix
--  this file, not the database.
--
--  SO IT DOES NOT NEED APPLYING, and that is not laziness. It was verified by
--  reconstruction instead, which is the stronger check: a throwaway local
--  database was built from this file alone, and then every function's
--  md5(prosrc) and its language, volatility, SECURITY DEFINER flag,
--  strictness, return type, search_path, grants and comment were compared
--  against production, one by one. All thirty-four agree. Thirty-two agree to
--  the byte; the two named below differ only in line endings. All eight
--  trigger definitions agree too. Nothing is pending — it is simply true now
--  that db/ can rebuild these.
--
--  WHY IT MATTERED. A function with no source cannot be reviewed in a diff,
--  cannot be rebuilt after a restore, and cannot be tested honestly.
--  db/_fixture_schema_mirror.sql carries hand-written stand-ins for four of
--  these under a comment claiming they are verbatim, and one had drifted: its
--  current_masjid() had no JWT branch, while production's reads
--  app_metadata.masjid_id first. Nothing re-creates that function in any
--  suite, so every test that turned on which masjid a caller belongs to was
--  testing the paraphrase. Corrected in the same commit as this file; the 148
--  assertions in the four fixture-based suites still pass.
--
--  THE GRANTS ARE HALF THE CAPTURE, AND THE HALF THAT GETS LOST
--  ------------------------------------------------------------
--  A function created fresh has EXECUTE granted to PUBLIC. CREATE OR REPLACE
--  keeps whatever grants are already there — so on this database the REVOKEs
--  below do nothing, while on a rebuilt one they are the only thing standing
--  between anon and a SECURITY DEFINER function. db/134 and db/135 were both
--  applied with that hole open, because their revokes said `from anon,
--  authenticated` and a PUBLIC grant is not either of those. Every revoke here
--  names public first for that reason.
--
--  THREE FUNCTIONS ARE DELIBERATELY LEFT EXECUTABLE BY PUBLIC, and a later
--  reader will want to "fix" them: current_masjid(), sole_masjid() and
--  shares_current_masjid(). Ten RLS policies — on admin_audit, profiles,
--  user_roles, foodbank_volunteers, nikah_people and pending_access — are
--  declared TO PUBLIC and call current_masjid() in their USING clause. A
--  policy expression is evaluated as the querying role, so revoking EXECUTE
--  from PUBLIC without granting it back to anon and authenticated by name
--  would make those tables unreadable to everyone. Leave them.
--
--  ONE DIFFERENCE FROM PRODUCTION, STATED SO IT IS NOT A SURPRISE: the bodies
--  of handle_new_user() and touch_updated_at() are stored with CRLF line
--  endings, from a paste into the dashboard years ago. They are written here
--  with LF. Nothing in plpgsql reads a line ending, so the behaviour is
--  identical, but their md5(prosrc) will change the first time this file is
--  applied and will then be stable. No other body differs by a byte.
--
--  WHAT IS NOT HERE: masjid_theme(text). It is still in production with
--  EXECUTE revoked from every role and a comment marked DEAD, and it is the
--  one function that should not be rebuilt — it is a signpost towards the
--  templated-masjid model this product does not have. Its definition is kept
--  at the foot of this file as a comment, so the DROP it is waiting for stays
--  reversible, and so that a rebuild from db/ simply does not have it.
-- ===========================================================================

begin;

-- ---------------------------------------------------------------------------
--  1. Which masjid is this? The tenancy gates.
--
--  These are the functions every other one leans on, and they were the least
--  written down. sole_masjid() is the one that fails closed: the day a second
--  masjid exists it stops guessing and raises, which is why the call sites had
--  to start passing a slug.
-- ---------------------------------------------------------------------------

create or replace function public.sole_masjid()
 returns uuid
 language plpgsql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_id uuid; v_n int;
begin
  select count(*) into v_n from public.masjids;
  if v_n = 0 then
    raise exception 'No masjid has been set up yet.' using errcode = '22023';
  end if;
  if v_n > 1 then
    raise exception 'This system now runs more than one masjid, so this call has to say which. Update the caller to pass a masjid slug.'
      using errcode = '22023';
  end if;
  select id into v_id from public.masjids;
  return v_id;
end $function$;

/* EXECUTE stays with PUBLIC — see the header. */

create or replace function public.masjid_id_for(p_slug text)
 returns uuid
 language plpgsql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_id uuid;
begin
  select id into v_id from public.masjids where slug = p_slug and is_live;
  if v_id is null then
    raise exception 'There is no masjid called %.', p_slug using errcode = '22023';
  end if;
  return v_id;
end $function$;

revoke execute on function public.masjid_id_for(text) from public;
grant  execute on function public.masjid_id_for(text) to anon, authenticated;

create or replace function public.masjid_or_sole(p_slug text)
 returns uuid
 language plpgsql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
begin
  if nullif(btrim(coalesce(p_slug, '')), '') is not null then
    return public.masjid_id_for(p_slug);
  end if;
  return public.sole_masjid();
end $function$;

revoke execute on function public.masjid_or_sole(text) from public;
grant  execute on function public.masjid_or_sole(text) to anon, authenticated;

create or replace function public.masjid_is_live(p_masjid uuid)
 returns boolean
 language sql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select exists (select 1 from public.masjids m where m.id = p_masjid and m.is_live);
$function$;

/* This one keeps its PUBLIC grant as well as the named ones, as in production. */
grant execute on function public.masjid_is_live(uuid) to anon, authenticated;

create or replace function public.masjid_by_slug(p_slug text)
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select jsonb_build_object(
           'slug', m.slug, 'name', m.name,
           'short_name', m.short_name, 'town', m.town,
           'theme', m.theme, 'logo_url', m.logo_url)
    from public.masjids m
   where m.slug = p_slug and m.is_live;
$function$;

revoke execute on function public.masjid_by_slug(text) from public;
grant  execute on function public.masjid_by_slug(text) to anon, authenticated;

-- The JWT branch is the part the test fixture never had. An app_metadata
-- masjid_id wins over the active_masjid row, which wins over "you only have a
-- role at one of them".
create or replace function public.current_masjid()
 returns uuid
 language sql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
  with chosen as (
    select 1 as pri, nullif(current_setting('request.jwt.claims', true)::jsonb
                    -> 'app_metadata' ->> 'masjid_id', '')::uuid as id
    union all
    select 2, a.masjid_id from public.active_masjid a where a.user_id = auth.uid()
    union all
    select 3, r.masjid_id from public.user_roles r
     where r.user_id = auth.uid()
     group by r.masjid_id
    having (select count(distinct masjid_id) from public.user_roles
             where user_id = auth.uid()) = 1
  )
  select c.id from chosen c
   where c.id is not null
     and (exists (select 1 from public.user_roles r
                   where r.user_id = auth.uid() and r.masjid_id = c.id)
       or public.is_platform_admin())
   order by c.pri
   limit 1;
$function$;

/* EXECUTE stays with PUBLIC — ten RLS policies depend on it. See the header. */

create or replace function public.shares_current_masjid(p_user uuid)
 returns boolean
 language sql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select public.current_masjid() is not null
     and exists (select 1 from public.user_roles r
                  where r.user_id = p_user
                    and r.masjid_id = public.current_masjid());
$function$;

/* EXECUTE stays with PUBLIC — see the header. */

create or replace function public.my_masjids()
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'slug', m.slug, 'name', m.name, 'town', m.town,
           'current', m.id = public.current_masjid(),
           'support', not exists (select 1 from public.user_roles r
                                   where r.user_id = auth.uid() and r.masjid_id = m.id))
         order by m.name), '[]'::jsonb)
    from public.masjids m
   where auth.uid() is not null
     and (public.is_platform_admin()
       or exists (select 1 from public.user_roles r
                   where r.user_id = auth.uid() and r.masjid_id = m.id));
$function$;

revoke execute on function public.my_masjids() from public;
grant  execute on function public.my_masjids() to authenticated;

-- The one that writes masjidone_support_access into a masjid's own audit
-- trail. 137's tests turn on exactly what it does and does not write, which is
-- why the fixture copy of this one has to stay in step with this.
create or replace function public.set_current_masjid(p_slug text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_masjid uuid;
  v_member boolean;
  v_staff  boolean;
begin
  if auth.uid() is null then
    raise exception 'Not signed in.' using errcode = '42501';
  end if;

  v_masjid := public.masjid_id_for(p_slug);

  select exists (select 1 from public.user_roles
                  where user_id = auth.uid() and masjid_id = v_masjid)
    into v_member;

  v_staff := public.is_platform_admin();

  if not v_member and not v_staff then
    raise exception 'You do not belong to %.', p_slug using errcode = '42501';
  end if;

  insert into public.active_masjid (user_id, masjid_id, set_at)
  values (auth.uid(), v_masjid, now())
  on conflict (user_id) do update set masjid_id = excluded.masjid_id,
                                      set_at = excluded.set_at;

  if v_staff and not v_member then
    insert into public.admin_audit (masjid_id, actor, action, detail)
    values (v_masjid, auth.uid(), 'masjidone_support_access',
            jsonb_build_object('masjid', p_slug));
  end if;

  return jsonb_build_object('masjid', p_slug, 'support_access', v_staff and not v_member);
end $function$;

revoke execute on function public.set_current_masjid(text) from public;
grant  execute on function public.set_current_masjid(text) to authenticated;

-- ---------------------------------------------------------------------------
--  2. Who may do what.
--
--  has_role() is scoped to current_masjid(), which is what makes a role at one
--  masjid worth nothing at another. is_admin() and can_see_bookings() both
--  let a platform admin through, which is the supplier's support access and
--  the reason db/137 refuses to let one account hold both hats.
-- ---------------------------------------------------------------------------

create or replace function public.has_role(_user_id uuid, _role app_role)
 returns boolean
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select exists (
    select 1 from public.user_roles
     where user_id   = _user_id
       and role      = _role
       and masjid_id = public.current_masjid()
  );
$function$;

revoke execute on function public.has_role(uuid, app_role) from public;
grant  execute on function public.has_role(uuid, app_role) to authenticated, service_role;

create or replace function public.is_admin()
 returns boolean
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select public.has_role(auth.uid(), 'admin') or public.is_platform_admin();
$function$;

revoke execute on function public.is_admin() from public;
grant  execute on function public.is_admin() to authenticated, service_role;

create or replace function public.can_see_bookings()
 returns boolean
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select public.has_role(auth.uid(), 'admin')
      or public.has_role(auth.uid(), 'hall_office')
      or public.is_platform_admin();
$function$;

comment on function public.can_see_bookings() is
  'True for venue office staff and for administrators. Used by the hall_bookings policies so that hall hire access does not require full admin rights.';

revoke execute on function public.can_see_bookings() from public;
grant  execute on function public.can_see_bookings() to authenticated;

-- ---------------------------------------------------------------------------
--  3. What the public website reads.
--
--  Both of these replace a view of the same name that still exists and still
--  calls sole_masjid() — see section 8. These take the slug, so they survive a
--  second masjid; the views do not.
--
--  hall_availability() returns dates and nothing else. That is deliberate: the
--  booking calendar on the website needs to know which days are taken, and
--  must not be able to learn who took them or what for.
-- ---------------------------------------------------------------------------

create or replace function public.hall_availability(p_masjid text)
 returns table(booking_date date)
 language sql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select b.booking_date
    from public.hall_bookings b
   where b.masjid_id = public.masjid_id_for(p_masjid)
     and b.booking_date >= (now() at time zone 'Europe/London')::date
     and b.status <> 'declined'
     and b.status <> 'cancelled'
     and (b.status = 'confirmed'
       or b.deposit_status = 'paid'
       or (b.hold_expires_at is not null and b.hold_expires_at > now()))
   group by b.booking_date;
$function$;

revoke execute on function public.hall_availability(text) from public;
grant  execute on function public.hall_availability(text) to anon, authenticated;

create or replace function public.notices_live(p_masjid text)
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(to_jsonb(x) order by x.sort_at desc), '[]'::jsonb)
    from (
      select n.id, n.created_at, n.topic, n.title, n.body,
             n.image_url, n.image_w, n.image_h, n.event_at,
             coalesce(n.event_at, n.created_at) as sort_at
        from public.notices n
       where n.masjid_id = public.masjid_id_for(p_masjid)
         and n.published
         and (n.expires_at is null or n.expires_at > now())
    ) x;
$function$;

revoke execute on function public.notices_live(text) from public;
grant  execute on function public.notices_live(text) to anon, authenticated;

-- ---------------------------------------------------------------------------
--  4. The madrasah.
--
--  Everything in this section is behind verified_madrasah() or
--  verified_admin() — a role plus two-step, checked in the function body
--  rather than in a policy, because these read across half a dozen tables and
--  a policy per table would be six chances to forget one.
--
--  The _for(p_masjid uuid) functions are the inner halves of pairs whose outer
--  half takes no argument and uses current_masjid(). Only the inner half is
--  here; the outer ones already had a source.
-- ---------------------------------------------------------------------------

create or replace function public.register_days_for(p_masjid uuid)
 returns text[]
 language sql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(
    (select array(select jsonb_array_elements_text(value))
       from public.madrasah_settings
      where masjid_id = p_masjid and key = 'register_days'),
    '{}'::text[]);
$function$;

revoke execute on function public.register_days_for(uuid) from public, anon, authenticated;

create or replace function public.register_due_for(p_masjid uuid, p_class uuid, p_date date)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_masjid uuid := p_masjid;
  v_days text[] := public.register_days_for(p_masjid);
  v_dow text := lower(to_char(p_date, 'Dy'));
  v_closure text;
begin
  if array_length(v_days, 1) is null then
    return jsonb_build_object('due', false,
      'why', 'Nobody has said which evenings the madrasah runs yet.');
  end if;
  if not exists (select 1 from public.madrasah_years y
                  where y.masjid_id = v_masjid and y.is_current
                    and p_date between y.starts_on and y.ends_on) then
    return jsonb_build_object('due', false,
      'why', 'That date is outside the academic year.');
  end if;
  if not (v_dow = any(v_days)) then
    return jsonb_build_object('due', false,
      --  FIXED BY 113 (ruling C). to_char(p_date,'Day') right-pads to nine
      --  characters, so this read "...on a Sunday   ." with two spaces
      --  before the full stop. 'FMDay' (fill mode) suppresses the
      --  padding. Nothing else about register_due() changes.
      'why', 'The madrasah does not run on a ' || to_char(p_date, 'FMDay') || '.');
  end if;
  --  INCLUSIVE AT BOTH ENDS, which is how madrasah_closures is written.
  select c.name into v_closure from public.madrasah_closures c
   where c.masjid_id = v_masjid and p_date between c.starts_on and c.ends_on
   limit 1;
  if v_closure is not null then
    return jsonb_build_object('due', false, 'why', v_closure || '.');
  end if;
  if not exists (select 1 from public.madrasah_classes c
                  where c.id = p_class and c.masjid_id = v_masjid and c.is_active
                    and exists (select 1 from public.madrasah_pupil_classes pc
                                  join public.madrasah_pupils p on p.id = pc.pupil_id
                                 where pc.class_id = c.id and p.left_on is null
                                   and p.status = 'on_roll')) then
    return jsonb_build_object('due', false,
      'why', 'That class is not running, or has nobody on its roll.');
  end if;
  return jsonb_build_object('due', true, 'why', '');
end $function$;

revoke execute on function public.register_due_for(uuid, uuid, date) from public, anon, authenticated;

-- The promise in the privacy notice is that parents are told the register is
-- being kept BEFORE the first mark is made. This is what enforces it, and it
-- counts families, not pupils, because the notice goes to a household.
create or replace function public.attendance_permitted_for(p_masjid uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_masjid uuid := p_masjid;
  v_families int;
  v_told int;
begin
  select count(*) into v_families
    from public.madrasah_households h
   where h.masjid_id = v_masjid
     and exists (select 1 from public.madrasah_pupils p
                  where p.household_id = h.id and p.left_on is null);

  select count(distinct n.household_id) into v_told
    from public.madrasah_parent_notices n
    join public.madrasah_households h on h.id = n.household_id
   where n.masjid_id = v_masjid
     and n.kind = 'attendance_notice'
     and exists (select 1 from public.madrasah_pupils p
                  where p.household_id = h.id and p.left_on is null);

  return jsonb_build_object(
    'permitted', (v_families > 0 and v_told >= v_families),
    'families', v_families,
    'told', v_told,
    'outstanding', greatest(v_families - v_told, 0),
    'why', case
      when v_families = 0 then 'There are no families with a child on the roll.'
      when v_told >= v_families then 'Every family has been told the register is being kept.'
      else 'The privacy notice promises parents they will be told before the '
           || 'first mark is made. ' || (v_families - v_told)
           || ' famil' || case when v_families - v_told = 1 then 'y has' else 'ies have' end
           || ' not been told yet.' end);
end $function$;

revoke execute on function public.attendance_permitted_for(uuid) from public, anon, authenticated;

create or replace function public.madrasah_pupil_one(p_id uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_m uuid := public.current_masjid(); v jsonb;
begin
  if not public.verified_madrasah() then
    raise exception 'Only madrasah staff who have completed two-step may open a pupil.'
      using errcode = '42501';
  end if;

  select jsonb_build_object(
    'id', p.id, 'legacy_ref', p.legacy_ref,
    'first_name', p.first_name, 'last_name', p.last_name,
    'name', btrim(concat_ws(' ', p.first_name, p.last_name)),
    'date_of_birth', p.date_of_birth, 'gender', p.gender, 'email', p.email,
    'age', case when p.date_of_birth is not null
                then extract(year from age(p.date_of_birth))::int end,
    'address', p.address, 'postcode', p.postcode,
    'school', p.school, 'school_year', p.school_year,
    'prev_madrasah', p.prev_madrasah,
    'medical', p.medical, 'allergies', p.allergies,
    'send_detail', p.send_detail, 'ehcp_detail', p.ehcp_detail,
    'walk_home_consent', p.walk_home_consent, 'notes', p.notes,
    'joined_on', p.joined_on, 'left_on', p.left_on,
    'household', case when h.id is null then null else jsonb_build_object(
        'id', h.id, 'reference', h.reference, 'name', h.name,
        'guardians', coalesce((select jsonb_agg(jsonb_build_object(
              'id', g.id, 'name', g.full_name, 'email', g.email,
              'phone', g.phone, 'is_primary', g.is_primary)
            order by g.is_primary desc, g.full_name)
          from public.madrasah_guardians g where g.household_id = h.id), '[]'::jsonb),
        'siblings', coalesce((select jsonb_agg(jsonb_build_object(
              'id', s.id, 'name', btrim(concat_ws(' ', s.first_name, s.last_name)))
            order by s.first_name)
          from public.madrasah_pupils s
          where s.household_id = h.id and s.id <> p.id), '[]'::jsonb)) end,
    'classes', coalesce((select jsonb_agg(jsonb_build_object(
          'id', c.id, 'name', c.name, 'section', c.section,
          'teacher', btrim(concat_ws(' ', st.honorific, st.first_name, st.last_name)))
        order by c.sort_order)
      from public.madrasah_pupil_classes pc
      join public.madrasah_classes c on c.id = pc.class_id
      left join public.madrasah_staff st on st.id = c.main_teacher_id
      where pc.pupil_id = p.id), '[]'::jsonb),
    'fee_rate', (select jsonb_build_object('id', fr.id, 'name', fr.name,
                                           'amount_p', fr.amount_p)
                 from public.madrasah_fee_rates fr where fr.id = p.fee_rate_id)
  ) into v
  from public.madrasah_pupils p
  left join public.madrasah_households h on h.id = p.household_id
  where p.id = p_id and p.masjid_id = v_m;

  if v is null then
    raise exception 'That pupil is not one of this madrasah''s.' using errcode = '42501';
  end if;

  --  WRITTEN DOWN BECAUSE OF WHAT IS IN IT. A record may carry a medical
  --  note, an allergy or a SEND note. Reading one is a thing that should
  --  leave a trace, the same as opening an application does.
  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_m, auth.uid(), 'pupil_opened',
          jsonb_build_object('pupil', p_id, 'reference', v->>'legacy_ref',
                             'sensitive', (v->>'medical') is not null
                                       or (v->>'allergies') is not null
                                       or (v->>'send_detail') is not null));
  return v;
end $function$;

revoke execute on function public.madrasah_pupil_one(uuid) from public, anon;
grant  execute on function public.madrasah_pupil_one(uuid) to authenticated;

create or replace function public.madrasah_roll_health()
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select case when not public.verified_madrasah() then jsonb_build_object('allowed', false)
  else (
    with p as (select * from public.madrasah_pupils
               where masjid_id = public.current_masjid() and left_on is null)
    select jsonb_build_object('allowed', true,
      'on_roll',        (select count(*) from p),
      'no_family',      (select count(*) from p where household_id is null),
      'no_contact',     (select count(*) from p
                          where coalesce(btrim(p.email), '') = ''
                            and (household_id is null
                             or not exists (select 1 from public.madrasah_guardians g
                                             where g.household_id = p.household_id
                                               and (g.phone is not null or g.email is not null)))),
      'no_class',       (select count(*) from p where not exists
                          (select 1 from public.madrasah_pupil_classes pc where pc.pupil_id = p.id)),
      'no_teacher',     (select count(*) from p where not exists
                          (select 1 from public.madrasah_pupil_classes pc
                           join public.madrasah_classes c on c.id = pc.class_id
                           where pc.pupil_id = p.id and c.main_teacher_id is not null)),
      'no_dob',         (select count(*) from p where date_of_birth is null),
      'no_gender',      (select count(*) from p where gender is null),
      'no_fee_rate',    (select count(*) from p where fee_rate_id is null),
      'with_medical',   (select count(*) from p where medical is not null),
      'with_allergy',   (select count(*) from p where allergies is not null),
      'with_send',      (select count(*) from p where send_detail is not null),
      'dob_to_check',   coalesce(jsonb_array_length(
                          public.madrasah_dob_to_check() -> 'rows'), 0),
      'open_sibling_suggestions',
        (select count(*) from public.madrasah_sibling_suggestions s
          where s.masjid_id = public.current_masjid() and s.state = 'open')) ) end;
$function$;

revoke execute on function public.madrasah_roll_health() from public, anon;
grant  execute on function public.madrasah_roll_health() to authenticated;

create or replace function public.madrasah_sibling_suggestions_list()
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select case when not public.verified_madrasah() then jsonb_build_object('allowed', false)
    else jsonb_build_object('allowed', true, 'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', s.id, 'why', s.why,
        'a', jsonb_build_object('id', a.id, 'name', btrim(concat_ws(' ', a.first_name, a.last_name)),
                                'family', ha.name, 'postcode', a.postcode),
        'b', jsonb_build_object('id', b.id, 'name', btrim(concat_ws(' ', b.first_name, b.last_name)),
                                'family', hb.name, 'postcode', b.postcode))
        order by a.last_name, a.first_name)
      from public.madrasah_sibling_suggestions s
      join public.madrasah_pupils a on a.id = s.pupil_a
      join public.madrasah_pupils b on b.id = s.pupil_b
      left join public.madrasah_households ha on ha.id = a.household_id
      left join public.madrasah_households hb on hb.id = b.household_id
      where s.masjid_id = public.current_masjid() and s.state = 'open'), '[]'::jsonb)) end;
$function$;

revoke execute on function public.madrasah_sibling_suggestions_list() from public, anon;
grant  execute on function public.madrasah_sibling_suggestions_list() to authenticated;

-- Writes the fact of an export, never its contents. The 'columns' string is
-- the list of headings that went out, so a subject access request can be
-- answered without keeping a copy of 553 children's details in the log.
create or replace function public.madrasah_audit_export(p_masjid uuid, p_detail boolean, p_rows integer, p_who text, p_when timestamp with time zone, p_said text, p_filter jsonb)
 returns void
 language sql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (p_masjid, auth.uid(),
          case when p_detail then 'roll_exported_full' else 'roll_exported_register' end,
          jsonb_build_object(
            'rows', p_rows,
            'taken_by', p_who,
            'taken_at', p_when,
            'filter_said', p_said,
            'columns', case when p_detail
                       then 'reference, name, class, teacher, status, date of birth, '
                            || 'gender, address, postcode, family, guardian, telephone, email'
                       else 'reference, name, class, teacher, status' end,
            'filter', p_filter,
            'note', 'no medical, allergy, SEND or EHCP column is ever included'));
$function$;

revoke execute on function public.madrasah_audit_export(uuid, boolean, integer, text, timestamp with time zone, text, jsonb) from public, anon, authenticated;

-- A one-off from 18 September 2026, kept because it refuses rather than
-- deletes: a pupil without a reference number who has a charge or a sibling
-- decision against them is somebody's record, not a leftover.
create or replace function public.clear_unreferenced_pupils()
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_m uuid := public.current_masjid(); n_p int; n_c int; blocked int;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may do this.'
      using errcode = '42501';
  end if;

  select count(*) into blocked
  from public.madrasah_pupils p
  where p.masjid_id = v_m and p.legacy_ref is null
    and (exists (select 1 from public.madrasah_charges c where c.pupil_id = p.id)
      or exists (select 1 from public.madrasah_sibling_suggestions s
                  where s.pupil_a = p.id or s.pupil_b = p.id));
  if blocked > 0 then
    raise exception 'Refusing to clear: % pupils without a reference number have '
                    'charges or decisions against them. Those are somebody''s '
                    'records, not leftovers.', blocked;
  end if;

  delete from public.madrasah_pupil_classes pc
   where pc.masjid_id = v_m
     and pc.pupil_id in (select id from public.madrasah_pupils
                          where masjid_id = v_m and legacy_ref is null);
  get diagnostics n_c = row_count;

  delete from public.madrasah_pupils
   where masjid_id = v_m and legacy_ref is null;
  get diagnostics n_p = row_count;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_m, auth.uid(), 'pupils_without_a_reference_cleared',
          jsonb_build_object('pupils', n_p, 'class_places', n_c,
                             'why', 'loaded 18 September with names only; '
                                 || 'replaced by the register import'));

  return jsonb_build_object('pupils_removed', n_p, 'class_places_removed', n_c);
end $function$;

revoke execute on function public.clear_unreferenced_pupils() from public, anon;
grant  execute on function public.clear_unreferenced_pupils() to authenticated;

create or replace function public.madrasah_roll()
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select case when not public.verified_madrasah() then jsonb_build_object('allowed', false)
  else jsonb_build_object('allowed', true, 'rows', coalesce((
    select jsonb_agg(jsonb_build_object(
        'id',            p.id,
        'legacy_ref',    p.legacy_ref,
        'name',          btrim(concat_ws(' ', p.first_name, p.last_name)),
        'gender',        p.gender,
        'status',        p.status,
        'date_of_birth', p.date_of_birth,
        'age',           case when p.date_of_birth is null then null
                         else date_part('year', age(current_date, p.date_of_birth))::int end,
        'postcode',      p.postcode,
        'family',        h.name,
        'classes',       coalesce((select jsonb_agg(c.name order by c.sort_order)
                                   from public.madrasah_pupil_classes pc
                                   join public.madrasah_classes c on c.id = pc.class_id
                                   where pc.pupil_id = p.id), '[]'::jsonb),
        'class_ids',     coalesce((select jsonb_agg(pc.class_id)
                                   from public.madrasah_pupil_classes pc
                                   where pc.pupil_id = p.id), '[]'::jsonb),
        'teacher',       (select btrim(concat_ws(' ', st.honorific, st.first_name, st.last_name))
                          from public.madrasah_pupil_classes pc
                          join public.madrasah_classes c on c.id = pc.class_id
                          join public.madrasah_staff st on st.id = c.main_teacher_id
                          where pc.pupil_id = p.id order by c.sort_order limit 1),
        --  WHETHER. Never what.
        'has_medical',   p.medical     is not null,
        'has_allergy',   p.allergies   is not null,
        'has_send',      p.send_detail is not null or p.ehcp_detail is not null,
        'has_fee_rate',  p.fee_rate_id is not null,
        'has_teacher',   exists (select 1 from public.madrasah_pupil_classes pc
                                 join public.madrasah_classes c on c.id = pc.class_id
                                 where pc.pupil_id = p.id and c.main_teacher_id is not null),
        'has_contact',   coalesce(btrim(p.email), '') <> ''
                         or exists (select 1 from public.madrasah_guardians g
                                    where g.household_id = p.household_id
                                      and (g.phone is not null or g.email is not null)))
      order by p.last_name nulls last, p.first_name)
    --  EVERY pupil, not only those on roll. The screen filters by status now,
    --  and a roll that silently drops a suspended child is how somebody is
    --  forgotten rather than dealt with.
    from public.madrasah_pupils p
    left join public.madrasah_households h on h.id = p.household_id
    where p.masjid_id = public.current_masjid()), '[]'::jsonb)) end;
$function$;

revoke execute on function public.madrasah_roll() from public, anon;
grant  execute on function public.madrasah_roll() to authenticated;

-- NOTE, kept because it is in production: `function_note text` is declared and
-- never used. It is harmless and it is recorded here verbatim rather than
-- tidied, because this file's whole claim is that applying it changes nothing.
-- Remove it in a migration of its own if it ever bothers anybody.
create or replace function public.save_madrasah_pupil_details(p jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_m uuid := public.current_masjid(); v_id uuid := (p->>'id')::uuid; v_before jsonb;
  function_note text;
begin
  if not public.verified_madrasah() then
    raise exception 'Only madrasah staff who have completed two-step may amend a pupil.'
      using errcode = '42501';
  end if;
  if v_id is null then raise exception 'Which pupil?'; end if;

  select to_jsonb(x) - 'masjid_id' into v_before
  from public.madrasah_pupils x where x.id = v_id and x.masjid_id = v_m;
  if v_before is null then
    raise exception 'That pupil is not one of this madrasah''s.' using errcode = '42501';
  end if;

  update public.madrasah_pupils set
    first_name    = case when p ? 'first_name'    then coalesce(nullif(btrim(p->>'first_name'),''), first_name) else first_name end,
    last_name     = case when p ? 'last_name'     then nullif(btrim(coalesce(p->>'last_name','')),'')     else last_name end,
    date_of_birth = case when p ? 'date_of_birth' then nullif(btrim(coalesce(p->>'date_of_birth','')),'')::date else date_of_birth end,
    gender        = case when p ? 'gender'        then nullif(btrim(coalesce(p->>'gender','')),'')        else gender end,
    email         = case when p ? 'email'         then nullif(btrim(coalesce(p->>'email','')),'')         else email end,
    address       = case when p ? 'address'       then nullif(btrim(coalesce(p->>'address','')),'')       else address end,
    postcode      = case when p ? 'postcode'      then nullif(upper(btrim(coalesce(p->>'postcode',''))),'') else postcode end,
    school        = case when p ? 'school'        then nullif(btrim(coalesce(p->>'school','')),'')        else school end,
    school_year   = case when p ? 'school_year'   then nullif(btrim(coalesce(p->>'school_year','')),'')   else school_year end,
    prev_madrasah = case when p ? 'prev_madrasah' then nullif(btrim(coalesce(p->>'prev_madrasah','')),'') else prev_madrasah end,
    medical       = case when p ? 'medical'       then nullif(btrim(coalesce(p->>'medical','')),'')       else medical end,
    allergies     = case when p ? 'allergies'     then nullif(btrim(coalesce(p->>'allergies','')),'')     else allergies end,
    send_detail   = case when p ? 'send_detail'   then nullif(btrim(coalesce(p->>'send_detail','')),'')   else send_detail end,
    ehcp_detail   = case when p ? 'ehcp_detail'   then nullif(btrim(coalesce(p->>'ehcp_detail','')),'')   else ehcp_detail end,
    notes         = case when p ? 'notes'         then nullif(btrim(coalesce(p->>'notes','')),'')         else notes end,
    joined_on     = case when p ? 'joined_on'     then nullif(btrim(coalesce(p->>'joined_on','')),'')::date else joined_on end,
    left_on       = case when p ? 'left_on'       then nullif(btrim(coalesce(p->>'left_on','')),'')::date   else left_on end,
    walk_home_consent = case when p ? 'walk_home_consent'
                             then (p->>'walk_home_consent')::boolean else walk_home_consent end,
    updated_at = now()
  where id = v_id and masjid_id = v_m;

  --  WHAT CHANGED, not that something did. An audit line saying "a pupil was
  --  amended" is no use to anybody asking which field somebody altered.
  insert into public.admin_audit (masjid_id, actor, action, detail)
  select v_m, auth.uid(), 'pupil_amended',
         jsonb_build_object('pupil', v_id,
           'changed', (select jsonb_object_agg(k, jsonb_build_object('was', v_before->k, 'now', a.v))
                       from jsonb_each(to_jsonb(x) - 'masjid_id') a(k, v)
                       where a.v is distinct from v_before->a.k
                         and k not in ('updated_at')))
  from public.madrasah_pupils x where x.id = v_id;

  return public.madrasah_pupil_one(v_id);
end $function$;

revoke execute on function public.save_madrasah_pupil_details(jsonb) from public, anon;
grant  execute on function public.save_madrasah_pupil_details(jsonb) to authenticated;

create or replace function public.settle_sibling_suggestion(p_id uuid, p_join boolean)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_m uuid := public.current_masjid(); r record; v_keep uuid; v_move uuid;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may join two families.'
      using errcode = '42501';
  end if;
  select * into r from public.madrasah_sibling_suggestions
   where id = p_id and masjid_id = v_m and state = 'open';
  if r is null then raise exception 'That suggestion is not open.'; end if;

  if p_join then
    --  The family that already has the most children keeps its reference, so
    --  that a statement somebody has already sent does not change its number.
    select household_id into v_keep from public.madrasah_pupils where id = r.pupil_a;
    select household_id into v_move from public.madrasah_pupils where id = r.pupil_b;
    if v_keep is null or v_move is null or v_keep = v_move then
      update public.madrasah_pupils set household_id = coalesce(v_keep, v_move)
       where id in (r.pupil_a, r.pupil_b);
    else
      if (select count(*) from public.madrasah_pupils where household_id = v_move)
         > (select count(*) from public.madrasah_pupils where household_id = v_keep) then
        v_keep := v_move;
        select household_id into v_move from public.madrasah_pupils where id = r.pupil_a;
      end if;
      update public.madrasah_guardians set household_id = v_keep where household_id = v_move;
      --  ADDED BY 125. The household deleted below takes its conversations with it
      --  (ON DELETE CASCADE) unless they are moved first.
      update public.madrasah_threads set household_id = v_keep where household_id = v_move;
      update public.madrasah_pupils    set household_id = v_keep where household_id = v_move;
      delete from public.madrasah_households where id = v_move and masjid_id = v_m;
    end if;
  end if;

  update public.madrasah_sibling_suggestions
     set state = case when p_join then 'joined' else 'dismissed' end,
         decided_by = auth.uid(), decided_at = now()
   where id = p_id;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_m, auth.uid(), case when p_join then 'siblings_joined' else 'siblings_kept_apart' end,
          jsonb_build_object('suggestion', p_id, 'a', r.pupil_a, 'b', r.pupil_b));
  return jsonb_build_object('ok', true);
end $function$;

revoke execute on function public.settle_sibling_suggestion(uuid, boolean) from public, anon;
grant  execute on function public.settle_sibling_suggestion(uuid, boolean) to authenticated;

-- The one-shot that loaded 553 children on 19 September 2026, kept for the
-- shape of its guard rather than because it will run again: it counts what the
-- landing tables hold, does the work, counts what is actually there
-- afterwards, and raises if the two disagree. A silent partial import of a
-- madrasah roll is the failure that would not be noticed for a term.
create or replace function public.import_the_register()
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_m uuid; r record; v_id uuid; v_cls uuid; v_cleared jsonb; problem text;
  n_staff int := 0; n_class int := 0; n_hh int := 0; n_guard int := 0;
  n_pupil int := 0; n_sib int := 0; next_ref int;
  n_before int; want_pupils int; got_pupils int; dupes int; no_ref int;
  want_places int; got_places int;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may load the register.'
      using errcode = '42501';
  end if;
  select public.current_masjid() into v_m;
  if v_m is null then raise exception 'No masjid in context.'; end if;

  select count(*) into n_before from public.madrasah_pupils where masjid_id = v_m;
  select count(*) into want_pupils from (
    select distinct btrim(legacy_id) x from public.import_pupils
     where coalesce(btrim(legacy_id),'') <> '') q;
  if want_pupils = 0 then
    raise exception 'The landing tables are empty. Upload the four files first.';
  end if;
  select count(*) into want_places from (
    select distinct btrim(legacy_id) a, lower(btrim(class_name)) b
    from public.import_pupils where coalesce(btrim(class_name),'') <> '') q;

  problem := public.register_import_problem(n_before, want_pupils, want_pupils,
                                            0, 0, want_places, want_places);
  if problem is not null then
    raise exception '% Nothing has been changed.', problem;
  end if;

  v_cleared := public.clear_unreferenced_pupils();

  --  TEACHERS
  for r in select distinct teacher_honorific h, teacher_first f, teacher_last l, teacher_side s
           from public.import_classes where coalesce(nullif(btrim(teacher_first),''),'') <> ''
  loop
    if not exists (select 1 from public.madrasah_staff x where x.masjid_id = v_m
      and lower(btrim(coalesce(x.honorific,'')||' '||x.first_name||' '||coalesce(x.last_name,'')))
        = lower(btrim(coalesce(r.h,'')||' '||r.f||' '||coalesce(r.l,'')))) then
      insert into public.madrasah_staff (masjid_id, honorific, first_name, last_name,
        employment, side, dbs_not_required, note)
      values (v_m, nullif(btrim(r.h),''), btrim(r.f), nullif(btrim(r.l),''),
              'employed', nullif(btrim(r.s),''), false, 'Imported from the madrasah register');
      n_staff := n_staff + 1;
    end if;
  end loop;

  --  CLASSES
  for r in select * from public.import_classes loop
    select id into v_id from public.madrasah_staff x where x.masjid_id = v_m
      and lower(btrim(coalesce(x.honorific,'')||' '||x.first_name||' '||coalesce(x.last_name,'')))
        = lower(btrim(coalesce(r.teacher_honorific,'')||' '||coalesce(r.teacher_first,'')
                      ||' '||coalesce(r.teacher_last,''))) limit 1;
    if exists (select 1 from public.madrasah_classes c where c.masjid_id = v_m
               and lower(c.name) = lower(btrim(r.class_name))) then
      update public.madrasah_classes set section = r.section,
             main_teacher_id = coalesce(v_id, main_teacher_id),
             sort_order = coalesce(nullif(btrim(r.sort_order),'')::int, sort_order)
       where masjid_id = v_m and lower(name) = lower(btrim(r.class_name));
    else
      insert into public.madrasah_classes (masjid_id, name, section, year_label,
        is_active, sort_order, main_teacher_id)
      values (v_m, btrim(r.class_name), r.section, '2026/27', true,
              coalesce(nullif(btrim(r.sort_order),'')::int, 100), v_id);
      n_class := n_class + 1;
    end if;
  end loop;

  --  FAMILIES, numbered in order and remembered by key.
  select coalesce(max(nullif(regexp_replace(reference,'\D','','g'),'')::int), 0) + 1
    into next_ref from public.madrasah_households where masjid_id = v_m;

  for r in select distinct family_key k, family_label l, family_address a
           from public.import_guardians where coalesce(btrim(family_key),'') <> ''
           order by 1
  loop
    if not exists (select 1 from public.madrasah_households h
                   where h.masjid_id = v_m and h.import_key = r.k) then
      insert into public.madrasah_households (masjid_id, reference, name, note, import_key)
      values (v_m, 'MF-' || lpad(next_ref::text, 4, '0'),
              btrim(r.l) || ' family',
              nullif(btrim(coalesce(r.a,'')),''), r.k);
      next_ref := next_ref + 1;
      n_hh := n_hh + 1;
    end if;
  end loop;

  --  GUARDIANS
  for r in select * from public.import_guardians
           where coalesce(btrim(full_name),'') <> '' loop
    select id into v_id from public.madrasah_households h
     where h.masjid_id = v_m and h.import_key = r.family_key;
    if v_id is not null and not exists (select 1 from public.madrasah_guardians g
        where g.household_id = v_id and lower(g.full_name) = lower(btrim(r.full_name))) then
      insert into public.madrasah_guardians (masjid_id, household_id, full_name,
        email, phone, is_primary)
      values (v_m, v_id, btrim(r.full_name), nullif(btrim(coalesce(r.email,'')),''),
              nullif(btrim(coalesce(r.phone,'')),''), coalesce(btrim(r.is_primary)='true', false));
      n_guard := n_guard + 1;
    end if;
  end loop;

  --  PUPILS
  for r in select distinct on (btrim(legacy_id)) * from public.import_pupils
           where coalesce(btrim(legacy_id),'') <> '' order by btrim(legacy_id) loop
    select id into v_id from public.madrasah_households h
     where h.masjid_id = v_m and h.import_key = r.family_key;
    insert into public.madrasah_pupils
      (masjid_id, legacy_ref, first_name, last_name, date_of_birth, gender, email,
       address, postcode, school, school_year, prev_madrasah, medical, allergies,
       send_detail, ehcp_detail, walk_home_consent, notes, joined_on, household_id)
    values (v_m, btrim(r.legacy_id), coalesce(nullif(btrim(r.first_name),''),'?'),
            nullif(btrim(coalesce(r.last_name,'')),''),
            nullif(btrim(coalesce(r.dob,'')),'')::date,
            nullif(btrim(coalesce(r.gender,'')),''),
            nullif(btrim(coalesce(r.email,'')),''),
            nullif(btrim(coalesce(r.address,'')),''),
            nullif(btrim(coalesce(r.postcode,'')),''),
            nullif(btrim(coalesce(r.school,'')),''),
            nullif(btrim(coalesce(r.school_year,'')),''),
            nullif(btrim(coalesce(r.prev_madrasah,'')),''),
            nullif(btrim(coalesce(r.medical,'')),''),
            nullif(btrim(coalesce(r.allergies,'')),''),
            nullif(btrim(coalesce(r.send_detail,'')),''),
            nullif(btrim(coalesce(r.ehcp_detail,'')),''),
            case when btrim(coalesce(r.walk_home,''))='true' then true
                 when btrim(coalesce(r.walk_home,''))='false' then false end,
            nullif(btrim(coalesce(r.notes,'')),''),
            nullif(btrim(coalesce(r.joined_on,'')),'')::date, v_id)
    on conflict (masjid_id, legacy_ref) where legacy_ref is not null do update set
      first_name=excluded.first_name, last_name=excluded.last_name,
      date_of_birth=excluded.date_of_birth, gender=excluded.gender, email=excluded.email,
      address=excluded.address, postcode=excluded.postcode, school=excluded.school,
      school_year=excluded.school_year, prev_madrasah=excluded.prev_madrasah,
      medical=excluded.medical, allergies=excluded.allergies,
      send_detail=excluded.send_detail, ehcp_detail=excluded.ehcp_detail,
      walk_home_consent=excluded.walk_home_consent, notes=excluded.notes,
      joined_on=excluded.joined_on,
      household_id=coalesce(excluded.household_id, madrasah_pupils.household_id);
    n_pupil := n_pupil + 1;
  end loop;

  --  PUPIL -> CLASS
  for r in select * from public.import_pupils
           where coalesce(btrim(class_name),'') <> '' loop
    select id into v_id  from public.madrasah_pupils  p
     where p.masjid_id = v_m and p.legacy_ref = btrim(r.legacy_id);
    select id into v_cls from public.madrasah_classes c
     where c.masjid_id = v_m and lower(c.name) = lower(btrim(r.class_name));
    if v_id is not null and v_cls is not null then
      insert into public.madrasah_pupil_classes (masjid_id, pupil_id, class_id)
      values (v_m, v_id, v_cls) on conflict do nothing;
    end if;
  end loop;

  --  TEACHER -> CLASS
  insert into public.madrasah_staff_classes (masjid_id, staff_id, class_id)
  select v_m, c.main_teacher_id, c.id from public.madrasah_classes c
  where c.masjid_id = v_m and c.main_teacher_id is not null on conflict do nothing;

  --  THE PAIRS SOMEBODY HAS TO SETTLE
  for r in select * from public.import_siblings loop
    insert into public.madrasah_sibling_suggestions (masjid_id, pupil_a, pupil_b, why)
    select v_m, least(a.id,b.id), greatest(a.id,b.id), r.why
    from public.madrasah_pupils a, public.madrasah_pupils b
    where a.masjid_id = v_m and b.masjid_id = v_m
      and a.legacy_ref = btrim(r.legacy_a) and b.legacy_ref = btrim(r.legacy_b)
      and a.id <> b.id on conflict do nothing;
    n_sib := n_sib + 1;
  end loop;

  --  AND THE GUARD AGAIN, against what was actually made.
  select count(*) into got_pupils from public.madrasah_pupils where masjid_id = v_m;
  select count(*) into no_ref from public.madrasah_pupils
   where masjid_id = v_m and legacy_ref is null;
  select count(*) into got_places from public.madrasah_pupil_classes where masjid_id = v_m;
  select count(*) into dupes from (
    select lower(btrim(first_name)) f, lower(btrim(coalesce(last_name,''))) l, date_of_birth d
    from public.madrasah_pupils where masjid_id = v_m and date_of_birth is not null
    group by 1,2,3 having count(*) > 1) q;

  problem := public.register_import_problem(0, want_pupils, got_pupils, dupes,
                                            no_ref, want_places, got_places);
  if problem is not null then
    raise exception '% Nothing has been saved.', problem;
  end if;

  insert into public.admin_audit (masjid_id, action, detail)
  values (v_m, 'register_imported',
          jsonb_build_object('pupils', n_pupil, 'families', n_hh, 'classes', n_class,
                             'teachers', n_staff, 'guardians', n_guard, 'cleared', v_cleared));

  return jsonb_build_object(
    'cleared_first', v_cleared, 'teachers_added', n_staff, 'classes_added', n_class,
    'families_added', n_hh, 'guardians_added', n_guard, 'pupils_loaded', n_pupil,
    'class_places', got_places, 'sibling_suggestions', n_sib,
    'checked', jsonb_build_object('was_before', n_before, 'file_holds', want_pupils,
                                  'now_present', got_pupils, 'same_child_twice', dupes,
                                  'places_expected', want_places, 'places_present', got_places));
end $function$;

revoke execute on function public.import_the_register() from public, anon;
grant  execute on function public.import_the_register() to authenticated;

-- ---------------------------------------------------------------------------
--  5. Is anything broken?
--
--  health_check() is the one function in this file that was most expensive to
--  have no source for: it is eighteen assertions about the whole system, half
--  of them added after something went wrong once, and the reason each exists
--  is written beside it. Losing it would have meant losing the reasons.
--
--  health_watch() wraps it and only speaks on a CHANGE of state, which is why
--  a check that has been failing since Tuesday does not send two hundred
--  identical messages.
-- ---------------------------------------------------------------------------

create or replace function public.health_check()
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_checks  jsonb := '[]'::jsonb;
  v_failing text[] := '{}';
  v_ok      boolean;
  v_detail  text;
  v_n       int;
  v_row     record;
  v_jrow    jsonb;
begin
  --  db/122: internal. The scheduler and the database's owner have no
  --  session; anybody with one must be a verified administrator.
  if auth.uid() is not null and not public.verified_admin() then
    raise exception 'That is for the masjid''s administrators.'
      using errcode = '42501';
  end if;
  begin
    select count(*) into v_n from cron.job_run_details
     where start_time > now() - interval '24 hours' and status <> 'succeeded';
    v_ok := (v_n = 0);
    v_detail := v_n || ' failed scheduled run(s) in the last 24 hours';
  exception when others then
    v_ok := false; v_detail := 'could not read cron history: ' || sqlerrm;
  end;
  v_checks := v_checks || jsonb_build_object('check','scheduled_jobs_succeeding','ok',v_ok,'detail',v_detail);
  if not v_ok then v_failing := array_append(v_failing, 'scheduled_jobs_succeeding'); end if;

  begin
    select count(*) into v_n from cron.job where not active;
    v_ok := (v_n = 0);
    v_detail := v_n || ' scheduled job(s) disabled';
  exception when others then
    v_ok := false; v_detail := 'could not read cron jobs: ' || sqlerrm;
  end;
  v_checks := v_checks || jsonb_build_object('check','scheduled_jobs_enabled','ok',v_ok,'detail',v_detail);
  if not v_ok then v_failing := array_append(v_failing, 'scheduled_jobs_enabled'); end if;

  begin
    select count(*) into v_n from cron.job_run_details d join cron.job j on j.jobid=d.jobid
     where j.command like '%purge_expired_holds%' and d.start_time > now() - interval '35 minutes';
    v_ok := (v_n > 0);
    v_detail := case when v_ok then 'the ten-minute job ran within the last 35 minutes'
                     else 'the ten-minute job has not run for over 35 minutes - the scheduler may be stalled' end;
  exception when others then
    v_ok := false; v_detail := 'could not read cron history: ' || sqlerrm;
  end;
  v_checks := v_checks || jsonb_build_object('check','scheduler_alive','ok',v_ok,'detail',v_detail);
  if not v_ok then v_failing := array_append(v_failing, 'scheduler_alive'); end if;

  select count(*) into v_n from public.masjids mj
   where mj.is_live and (select count(*) from public.app_settings s
                          where s.masjid_id = mj.id
                            and s.key in ('notify_url','notify_key','notify_secret')) < 3;
  v_ok := (v_n = 0);
  v_checks := v_checks || jsonb_build_object('check','notify_configured','ok',v_ok,
    'detail', v_n || ' live masjid(s) missing notify settings - their forms would reach nobody');
  if not v_ok then v_failing := array_append(v_failing, 'notify_configured'); end if;

  select count(*) into v_n from public.masjids mj
   where (select count(*) from public.user_roles r
           where r.masjid_id = mj.id and r.role = 'admin') < 2;
  v_ok := (v_n = 0);
  v_checks := v_checks || jsonb_build_object('check','two_admins_each','ok',v_ok,
    'detail', v_n || ' masjid(s) with fewer than two administrators');
  if not v_ok then v_failing := array_append(v_failing, 'two_admins_each'); end if;

  select count(*) into v_n from public.masjids mj
   where mj.is_live and not exists (
     select 1 from public.prayer_years y
      where y.masjid_id = mj.id
        and y.year = extract(year from (now() at time zone 'Europe/London'))::int
        and y.published);
  v_ok := (v_n = 0);
  v_checks := v_checks || jsonb_build_object('check','prayer_times_published','ok',v_ok,
    'detail', v_n || ' live masjid(s) with no published timetable for this year');
  if not v_ok then v_failing := array_append(v_failing, 'prayer_times_published'); end if;

  v_ok := true; v_detail := 'every live masjid answers on all four public calls';
  for v_row in select slug from public.masjids where is_live loop
    begin
      perform public.courses_public(v_row.slug);
      perform public.notices_live(v_row.slug);
      perform (select count(*) from public.hall_availability(v_row.slug));
      perform public.prayer_year(v_row.slug, extract(year from now())::int);
    exception when others then
      v_ok := false;
      v_detail := v_row.slug || ' fails a public call: ' || sqlerrm;
    end;
  end loop;
  v_checks := v_checks || jsonb_build_object('check','public_surface','ok',v_ok,'detail',v_detail);
  if not v_ok then v_failing := array_append(v_failing, 'public_surface'); end if;

  select count(*) into v_n from information_schema.columns
   where table_schema='public' and column_name='masjid_id' and is_nullable='YES';
  v_ok := (v_n = 0);
  v_checks := v_checks || jsonb_build_object('check','tenancy_enforced','ok',v_ok,
    'detail', v_n || ' table(s) allow a row with no masjid');
  if not v_ok then v_failing := array_append(v_failing, 'tenancy_enforced'); end if;

  select count(*) into v_n from public.masjids;
  v_ok := (v_n <= 1);
  v_checks := v_checks || jsonb_build_object('check','compatibility_shims','ok',v_ok,
    'detail', case when v_n <= 1
      then 'one masjid, so the old single-masjid calls still resolve'
      else v_n || ' masjids - every caller must now pass a slug, and any that does not is failing' end);
  if not v_ok then v_failing := array_append(v_failing, 'compatibility_shims'); end if;

  select coalesce(string_agg(c.relname, ', ' order by c.relname), '') into v_detail
    from pg_class c
   where c.relnamespace = 'public'::regnamespace
     and c.relkind = 'r'
     and c.relname not in ('masjids','platform_admins','health_state','profiles','active_masjid',
           'import_pupils','import_guardians','import_classes','import_siblings')
     and not exists (select 1 from pg_attribute a
                      where a.attrelid = c.oid and a.attname = 'masjid_id'
                        and not a.attisdropped);
  v_ok := (v_detail = '');
  v_checks := v_checks || jsonb_build_object('check','every_table_has_a_masjid','ok',v_ok,
    'detail', case when v_ok
      then 'every table in public belongs to a masjid, or is on the exempt list'
      else 'table(s) with no masjid_id at all, added outside the tenancy work: ' || v_detail end);
  if not v_ok then v_failing := array_append(v_failing, 'every_table_has_a_masjid'); end if;


  --  THE LIST/RECORD SPLIT, CHECKED RATHER THAN ASSERTED ONCE.
  --  077 asserted this in a DO block that ran once at migration time and is
  --  long gone. Nothing re-ran it, so nothing would have stopped a detail
  --  column being added to madrasah_roll() afterwards. This runs whenever
  --  health is read.
  begin
    v_jrow := public.madrasah_list_minimisation();
    v_ok := (v_jrow ->> 'ok')::boolean;
    v_detail := v_jrow ->> 'detail';
  exception when others then
    v_ok := false; v_detail := 'the minimisation guard itself failed: ' || sqlerrm;
  end;
  v_checks := v_checks || jsonb_build_object('check','lists_carry_marks_not_detail',
                                             'ok',v_ok,'detail',v_detail);
  if not v_ok then v_failing := array_append(v_failing, 'lists_carry_marks_not_detail'); end if;

  --  THE PUBLISHED PRIVACY NOTICE, CHECKED AGAINST THE SCHEMA.
  --  Added by 081. Three versions of that notice have been made false by
  --  a later migration and every one was found by a person happening to
  --  look. This runs whenever health is read.
  begin
    v_jrow := public.madrasah_notice_matches_schema();
    v_ok := (v_jrow ->> 'ok')::boolean;
    v_detail := v_jrow ->> 'detail';
  exception when others then
    v_ok := false;
    v_detail := 'the notice check itself failed: ' || sqlerrm;
  end;
  v_checks := v_checks || jsonb_build_object('check','notice_matches_the_schema',
                                             'ok',v_ok,'detail',v_detail);
  if not v_ok then v_failing := array_append(v_failing, 'notice_matches_the_schema'); end if;

  --  CAN THESE ACCOUNTS ACTUALLY BE SIGNED IN TO? Added by 094, after all
  --  thirty-nine teacher logins turned out to be unusable while every
  --  database-side check on them passed.
  begin
    v_jrow := public.auth_rows_readable();
    v_ok := (v_jrow ->> 'ok')::boolean;
    v_detail := v_jrow ->> 'detail';
  exception when others then
    v_ok := false;
    v_detail := 'the auth row check itself failed: ' || sqlerrm;
  end;
  v_checks := v_checks || jsonb_build_object('check','auth_rows_readable',
                                             'ok',v_ok,'detail',v_detail);
  if not v_ok then v_failing := array_append(v_failing, 'auth_rows_readable'); end if;

  --  CAN EVERY PARENT LOGIN REACH ITS FAMILY, AND ONLY ITS FAMILY? Added by
  --  119. A login that reaches nothing is how a family gets told to sign in
  --  to an empty screen; a login that also holds a staff grant reaches too
  --  much.
  begin
    v_jrow := public.parent_logins_reach_something();
    v_ok := (v_jrow ->> 'ok')::boolean;
    v_detail := v_jrow ->> 'detail';
  exception when others then
    v_ok := false;
    v_detail := 'the parent login check itself failed: ' || sqlerrm;
  end;
  v_checks := v_checks || jsonb_build_object('check','parent_logins_reach_something',
                                             'ok',v_ok,'detail',v_detail);
  if not v_ok then v_failing := array_append(v_failing, 'parent_logins_reach_something'); end if;

  --  A CHILD ON TWO ACTIVE ROLLS CAN HOLD ONLY ONE MARK. Added by 102,
  --  after the reviewer found submit_register can read complete on
  --  another class's marking for exactly these children. See the long
  --  comment above pupils_on_two_active_rolls() in db/102.
  begin
    v_jrow := public.pupils_on_two_active_rolls();
    v_ok := (v_jrow ->> 'ok')::boolean;
    v_detail := v_jrow ->> 'detail';
  exception when others then
    v_ok := false;
    v_detail := 'the shared-roll check itself failed: ' || sqlerrm;
  end;
  v_checks := v_checks || jsonb_build_object('check','pupils_on_two_active_rolls',
                                             'ok',v_ok,'detail',v_detail);
  if not v_ok then v_failing := array_append(v_failing, 'pupils_on_two_active_rolls'); end if;


  select count(*) into v_n from pg_class c
   where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
     and c.relname in ('import_pupils','import_guardians','import_classes','import_siblings');
  v_ok := (v_n = 0);
  v_checks := v_checks || jsonb_build_object('check','register_landing_tables_dropped',
    'ok', v_ok, 'detail', case when v_ok
      then 'the register landing tables are gone, as they should be'
      else v_n || ' landing tables still hold a second copy of the register, '
           || 'medical notes included. Sealed, but keep them only while the '
           || 'questionable dates and sibling pairs are still being settled.' end);
  if not v_ok then v_failing := array_append(v_failing, 'register_landing_tables_dropped'); end if;

  return jsonb_build_object(
    'status', case when array_length(v_failing,1) is null then 'ok' else 'fail' end,
    'failing', to_jsonb(v_failing),
    'checked_at', now(),
    'checks', v_checks);
end $function$;

revoke execute on function public.health_check() from public, anon;
grant  execute on function public.health_check() to authenticated;

create or replace function public.health_watch()
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_res     jsonb;
  v_failing text[];
  v_prev    public.health_state%rowtype;
  v_changed boolean;
  v_url text; v_key text; v_secret text;
begin
  v_res := public.health_check();
  v_failing := array(select jsonb_array_elements_text(v_res->'failing'));

  select * into v_prev from public.health_state where id;
  v_changed := v_prev.status is distinct from (v_res->>'status')
            or coalesce(v_prev.failing,'{}') is distinct from coalesce(v_failing,'{}');

  insert into public.health_state (id, status, failing, checked_at)
  values (true, v_res->>'status', coalesce(v_failing,'{}'), now())
  on conflict (id) do update
    set status = excluded.status, failing = excluded.failing, checked_at = now();

  -- Only on a CHANGE. A check that has been failing for three days should not
  -- send two hundred and eighty-eight identical messages.
  if not v_changed then
    return jsonb_build_object('status', v_res->>'status', 'changed', false);
  end if;

  insert into public.admin_audit (masjid_id, action, detail)
  select id, 'health_' || (v_res->>'status'), v_res from public.masjids order by slug limit 1;

  if v_res->>'status' = 'fail' then
    select value into v_url    from public.app_settings where key='notify_url'    order by masjid_id limit 1;
    select value into v_key    from public.app_settings where key='notify_key'    order by masjid_id limit 1;
    select value into v_secret from public.app_settings where key='notify_secret' order by masjid_id limit 1;
    if v_url is not null and v_key is not null and v_secret is not null then
      perform net.http_post(
        url     := v_url,
        body    := v_res || jsonb_build_object('kind','health_alert'),
        headers := jsonb_build_object('Content-type','application/json',
                     'Authorization','Bearer ' || v_key, 'x-notify-secret', v_secret));
    end if;
  end if;

  update public.health_state set alerted_at = now() where id;
  return jsonb_build_object('status', v_res->>'status', 'changed', true,
                            'failing', v_res->'failing');
end $function$;

revoke execute on function public.health_watch() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
--  6. Housekeeping, and the thing that keeps a purge honest.
--
--  masjids_to_purge() is the small idea that makes every retention job
--  multi-masjid without rewriting any of them: called with no session — which
--  is how pg_cron calls it — it yields every masjid; called by a signed-in
--  person it yields exactly theirs, and raises if they are acting for none.
--  So the scheduled purge covers the lot and a human purge cannot reach into
--  somebody else's records.
-- ---------------------------------------------------------------------------

create or replace function public.masjids_to_purge()
 returns setof uuid
 language plpgsql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_m uuid;
begin
  if auth.uid() is null then
    return query select id from public.masjids order by slug;
  else
    v_m := public.current_masjid();
    if v_m is null then
      raise exception 'You are signed in but not acting for any masjid, so there is nothing to purge.'
        using errcode = '42501';
    end if;
    return next v_m;
  end if;
end $function$;

revoke execute on function public.masjids_to_purge() from public, anon, authenticated;

create or replace function public.purge_old_hall_bookings()
 returns integer
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_m uuid; v_n int; v_total int := 0;
begin
  if auth.uid() is not null and not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may purge hall bookings.'
      using errcode = '42501';
  end if;

  for v_m in select * from public.masjids_to_purge() loop
    delete from public.hall_bookings
     where masjid_id = v_m
       and (booking_date < (now() at time zone 'Europe/London')::date - interval '6 months'
         or (status in ('declined','cancelled') and created_at < now() - interval '3 months'));
    get diagnostics v_n = row_count;
    v_total := v_total + v_n;
  end loop;

  return v_total;
end $function$;

comment on function public.purge_old_hall_bookings() is
  'Deletes hall hire requests six months after the event date, and rejected requests after three. Whatever period the trustees settle on must match the wording of the privacy notice on the website.';

revoke execute on function public.purge_old_hall_bookings() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
--  7. The trigger functions, and the triggers themselves.
--
--  Four triggers also had no source: on_auth_user_created, the five copies of
--  notify_the_office_trg, profiles_touch_updated_at and
--  hall_bookings_rate_limit_trg. A trigger function recorded without its
--  trigger is the worse half of a capture, because the rebuilt database looks
--  complete and quietly does nothing.
--
--  notify_the_office() is the one worth reading twice: when a masjid has not
--  been given its notify settings it writes notify_not_configured to the audit
--  trail and returns, rather than raising. A raise here would turn a
--  misconfiguration into a visitor being told their form failed. The form is
--  saved either way; what is lost is only the alert, and the audit row is what
--  makes that loss findable.
-- ---------------------------------------------------------------------------

create or replace function public.notify_the_office()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_url    text;
  v_key    text;
  v_secret text;
begin
  select value into v_url    from public.app_settings
   where masjid_id = new.masjid_id and key = 'notify_url';
  select value into v_key    from public.app_settings
   where masjid_id = new.masjid_id and key = 'notify_key';
  select value into v_secret from public.app_settings
   where masjid_id = new.masjid_id and key = 'notify_secret';

  if v_url is null or v_key is null or v_secret is null then
    insert into public.admin_audit (masjid_id, action, detail)
    values (new.masjid_id, 'notify_not_configured',
            jsonb_build_object('table', TG_TABLE_NAME,
                               'missing',
                               case when v_url    is null then 'notify_url'
                                    when v_key    is null then 'notify_key'
                                    else 'notify_secret' end));
    return new;
  end if;

  perform net.http_post(
    url     := v_url,
    body    := jsonb_build_object(
                 'type',       TG_OP,
                 'table',      TG_TABLE_NAME,
                 'schema',     TG_TABLE_SCHEMA,
                 'record',     to_jsonb(new),
                 'old_record', null),
    headers := jsonb_build_object(
                 'Content-type',    'application/json',
                 'Authorization',   'Bearer ' || v_key,
                 'x-notify-secret', v_secret));

  return new;
end $function$;

revoke execute on function public.notify_the_office() from public, anon, authenticated;

create or replace function public.hall_bookings_rate_limit()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare recent int;
begin
  select count(*) into recent
    from public.hall_bookings
   where masjid_id = new.masjid_id
     and phone = new.phone
     and created_at > now() - interval '24 hours';

  if recent >= 5 then
    raise exception 'Too many booking requests from this number today. Please ring the masjid office.'
      using errcode = 'check_violation';
  end if;

  return new;
end $function$;

revoke execute on function public.hall_bookings_rate_limit() from public, anon, authenticated;

create or replace function public.touch_updated_at()
 returns trigger
 language plpgsql
 set search_path to 'public', 'pg_temp'
as $function$
begin
  new.updated_at = now();
  return new;
end;
$function$;

revoke execute on function public.touch_updated_at() from public, anon, authenticated;

create or replace function public.handle_new_user()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  insert into public.profiles (id, full_name, email)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', new.email),
    new.email
  );
  return new;
end;
$function$;

revoke execute on function public.handle_new_user() from public, anon, authenticated;

-- CREATE OR REPLACE TRIGGER needs PostgreSQL 14 or later. This project is on
-- 17, and the alternative — drop then create — leaves a window in which a
-- form submission reaches nobody.
create or replace trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace trigger profiles_touch_updated_at
  before update on public.profiles
  for each row execute function public.touch_updated_at();

create or replace trigger hall_bookings_rate_limit_trg
  before insert on public.hall_bookings
  for each row execute function public.hall_bookings_rate_limit();

create or replace trigger notify_the_office_trg
  after insert on public.admission_applications
  for each row execute function public.notify_the_office();

create or replace trigger notify_the_office_trg
  after insert on public.charity_collections
  for each row execute function public.notify_the_office();

create or replace trigger notify_the_office_trg
  after insert on public.course_registrations
  for each row execute function public.notify_the_office();

create or replace trigger notify_the_office_trg
  after insert on public.foodbank_volunteers
  for each row execute function public.notify_the_office();

create or replace trigger notify_the_office_trg
  after insert on public.nikah_requests
  for each row execute function public.notify_the_office();

commit;

-- ===========================================================================
--  WHAT IS STILL NOT WRITTEN DOWN, after this file
--  ---------------------------------------------------------------------------
--  1. THE TWO VIEWS, DELIBERATELY NOT TOUCHED HERE.
--
--     public.hall_availability and public.notices_live still exist as VIEWS
--     alongside the functions of the same name captured above, and their live
--     bodies no longer match db/014, db/016 or db/040 — both now read
--     `masjid_id = sole_masjid()`. That makes them a dated fuse: sole_masjid()
--     raises the day a second masjid exists, so anything still selecting from
--     either view starts failing then, with an error about passing a slug.
--
--     CHECKED ON 5 OCTOBER 2026, and the answer is yes: the congregation app
--     reads BOTH views directly, over REST, with the publishable key —
--     `GET /rest/v1/notices_live?select=*` and
--     `GET /rest/v1/hall_availability?select=booking_date`. So both views are
--     load-bearing today and both stop working the day a second masjid exists.
--
--     The app's fix is small, because notices_live(text) and
--     hall_availability(text) already exist and return the same shapes: change
--     the two GETs to POSTs against /rest/v1/rpc/ with {"p_masjid":"taiyabah"}.
--     Once that ships, neither view has a consumer and both can be dropped,
--     which removes the fuse rather than resetting it.
--
--     Audited at the same time and CLEAN: the website (four call sites, all
--     naming a masjid), the Stripe webhook (every money function gets
--     p_masjid from one shared args object), and both screen repositories,
--     which turn out not to touch Supabase at all — the interactive screens
--     read a static foyer-content.json and the home screen only caches.
--
--  2. masjid_theme(text), below, which should be dropped rather than captured.
-- ===========================================================================

-- DEAD, AND KEPT ONLY SO THE DROP IS REVERSIBLE. Do not uncomment this.
--
-- It was added on a wrong reading of the product — that a masjid is one system
-- wearing a palette — and reverted the same day. EXECUTE is revoked from every
-- role, masjids.theme is back to {}, and the comment on it in production says
-- DEAD. It is left out of this capture on purpose, so that a database rebuilt
-- from db/ simply does not have it.
--
-- The one statement it is waiting for, which has to be run by hand because the
-- tooling that revoked it times out on a DROP:
--
--     drop function public.masjid_theme(text);
--
-- The body, so nothing is lost by dropping it:
--
--   create or replace function public.masjid_theme(p_masjid text)
--    returns jsonb
--    language sql
--    stable security definer
--    set search_path to 'public', 'pg_temp'
--   as $function$
--     select coalesce(m.theme, '{}'::jsonb)
--       from public.masjids m
--      where m.id = public.masjid_id_for(p_masjid);
--   $function$;
