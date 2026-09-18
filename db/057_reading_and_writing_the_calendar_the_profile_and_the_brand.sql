-- ===========================================================================
--  057_reading_and_writing_the_calendar_the_profile_and_the_brand.sql
--  18 September 2026
--
--  The functions for 056's tables, and the storage bucket the masjid's own
--  images live in.
--
--  ---------------------------------------------------------------------------
--  ONE OF THESE IS PUBLIC AND THE REST ARE NOT
--  ---------------------------------------------------------------------------
--
--  madrasah_calendar() may be executed by anon. That is deliberate and it is
--  the point of the whole exercise: the Holiday Planner on the public website
--  is going to read the madrasah's dates from here instead of from an array
--  typed into index_template.html, so that the committee can change a holiday
--  without a developer and a deployment.
--
--  It returns closures, Islamic dates and the academic year. Nothing else.
--  There is no pupil, no member of staff, no contact detail and no id that
--  leads to one — this is the same information already printed on a page that
--  needs no sign-in, and a function that leaks is one that returns more than
--  the page it feeds.
--
--  masjid_brand() is public for the same kind of reason: an email banner has
--  to be fetchable by a mail client that is signed in to nothing.
--
--  Everything else asks verified_admin().
--
--  ---------------------------------------------------------------------------
--  THE ADMIN STAFF SCREEN SHOWS AND DOES NOT GRANT
--  ---------------------------------------------------------------------------
--
--  madrasah_people() answers "who can open this portal, and why". It is READ
--  ONLY, and there is deliberately no matching writer in this file. Granting
--  and revoking stay in one place — the Admin Centre's access screen and
--  set_person_roles() — because two screens that both grant access is how
--  somebody is removed in one and quietly left in the other.
--
--  Prerequisites: 055, 056. Idempotent.
-- ===========================================================================

begin;

-- ---------------------------------------------------------------------------
--  1. The calendar, read by anybody
-- ---------------------------------------------------------------------------
create or replace function public.madrasah_calendar(p_from date default null,
                                                    p_to   date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_masjid uuid := coalesce(public.current_masjid(), public.sole_masjid());
  v_from   date;
  v_to     date;
  v_year   public.madrasah_years%rowtype;
begin
  if v_masjid is null then
    return jsonb_build_object('year', null, 'closures', '[]'::jsonb,
                              'events', '[]'::jsonb);
  end if;

  select * into v_year from public.madrasah_years
   where masjid_id = v_masjid and is_current;

  --  Absent dates mean the current academic year, which is what the planner
  --  wants and saves every caller repeating it. A year with no current row
  --  falls back to twelve months from today rather than returning everything
  --  ever recorded.
  v_from := coalesce(p_from, v_year.starts_on, current_date);
  v_to   := coalesce(p_to,   v_year.ends_on,   current_date + 365);

  return jsonb_build_object(
    'year', case when v_year.id is null then null else jsonb_build_object(
              'label', v_year.label, 'starts_on', v_year.starts_on,
              'ends_on', v_year.ends_on) end,
    'from', v_from,
    'to',   v_to,
    'closures', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', c.id, 'name', c.name, 'note', c.note,
               'starts_on', c.starts_on, 'ends_on', c.ends_on)
             order by c.starts_on, c.name)
        from public.madrasah_closures c
       where c.masjid_id = v_masjid
         and c.ends_on >= v_from and c.starts_on <= v_to), '[]'::jsonb),
    'events', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', e.id, 'name', e.name, 'hijri_label', e.hijri_label,
               'on_date', e.on_date, 'is_estimated', e.is_estimated)
             order by e.on_date, e.name)
        from public.madrasah_events e
       where e.masjid_id = v_masjid
         and e.on_date between v_from and v_to), '[]'::jsonb));
end $fn$;

-- ---------------------------------------------------------------------------
--  2. Amending a closure
-- ---------------------------------------------------------------------------
create or replace function public.save_madrasah_closure(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_id     uuid := nullif(p->>'id', '')::uuid;
  v_masjid uuid := public.current_masjid();
  v_name   text := btrim(coalesce(p->>'name', ''));
  v_from   date := nullif(p->>'starts_on', '')::date;
  v_to     date := nullif(p->>'ends_on', '')::date;
  v_row    public.madrasah_closures%rowtype;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may change the madrasah calendar.'
      using errcode = '42501';
  end if;
  if v_masjid is null then
    raise exception 'No masjid is selected, so there is nowhere to put this.'
      using errcode = '42501';
  end if;
  if v_name = '' then
    raise exception 'A closure needs a name — that is what a parent reads on the calendar.'
      using errcode = 'check_violation';
  end if;
  if v_from is null then
    raise exception 'A closure needs a first day.' using errcode = 'check_violation';
  end if;

  --  ONE DAY IS A CLOSURE TOO. Leaving the end blank means "just that day"
  --  rather than being an error, because a single insert day is the commonest
  --  entry on this calendar and making somebody type the same date twice is
  --  how the second one ends up wrong.
  v_to := coalesce(v_to, v_from);

  if v_to < v_from then
    raise exception 'That closure ends before it begins.' using errcode = 'check_violation';
  end if;

  insert into public.madrasah_closures as c
    (masjid_id, id, name, note, starts_on, ends_on)
  values (v_masjid, coalesce(v_id, gen_random_uuid()), v_name,
          nullif(btrim(coalesce(p->>'note', '')), ''), v_from, v_to)
  on conflict (id) do update set
    name = excluded.name, note = excluded.note,
    starts_on = excluded.starts_on, ends_on = excluded.ends_on,
    updated_at = now()
  where c.masjid_id = v_masjid
  returning * into v_row;

  if v_row.id is null then
    raise exception 'There is no such closure at this masjid.' using errcode = 'no_data_found';
  end if;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(),
          case when v_id is null then 'madrasah_closure_added' else 'madrasah_closure_changed' end,
          jsonb_build_object('id', v_row.id, 'name', v_row.name,
                             'from', v_row.starts_on, 'to', v_row.ends_on));
  return jsonb_build_object('id', v_row.id);
end $fn$;

create or replace function public.delete_madrasah_closure(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_masjid uuid := public.current_masjid();
  v_row    public.madrasah_closures%rowtype;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may change the madrasah calendar.'
      using errcode = '42501';
  end if;
  delete from public.madrasah_closures
   where id = p_id and masjid_id = v_masjid
  returning * into v_row;
  if v_row.id is null then
    raise exception 'There is no such closure at this masjid.' using errcode = 'no_data_found';
  end if;
  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'madrasah_closure_removed',
          jsonb_build_object('name', v_row.name, 'from', v_row.starts_on,
                             'to', v_row.ends_on));
  return jsonb_build_object('removed', v_row.name);
end $fn$;

-- ---------------------------------------------------------------------------
--  3. Amending an Islamic date
-- ---------------------------------------------------------------------------
create or replace function public.save_madrasah_event(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_id     uuid := nullif(p->>'id', '')::uuid;
  v_masjid uuid := public.current_masjid();
  v_name   text := btrim(coalesce(p->>'name', ''));
  v_on     date := nullif(p->>'on_date', '')::date;
  v_row    public.madrasah_events%rowtype;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may change the madrasah calendar.'
      using errcode = '42501';
  end if;
  if v_masjid is null then
    raise exception 'No masjid is selected, so there is nowhere to put this.'
      using errcode = '42501';
  end if;
  if v_name = '' then
    raise exception 'The date needs a name.' using errcode = 'check_violation';
  end if;
  if v_on is null then
    raise exception 'The date needs a day.' using errcode = 'check_violation';
  end if;

  insert into public.madrasah_events as e
    (masjid_id, id, name, hijri_label, on_date, is_estimated)
  values (v_masjid, coalesce(v_id, gen_random_uuid()), v_name,
          nullif(btrim(coalesce(p->>'hijri_label', '')), ''), v_on,
          --  ABSENT MEANS ESTIMATED. Only an explicit false from the screen
          --  turns a calculated date into a confirmed one, because the safe
          --  default is the one that admits the moon has not been sighted.
          coalesce((p->>'is_estimated')::boolean, true))
  on conflict (id) do update set
    name = excluded.name, hijri_label = excluded.hijri_label,
    on_date = excluded.on_date, is_estimated = excluded.is_estimated,
    updated_at = now()
  where e.masjid_id = v_masjid
  returning * into v_row;

  if v_row.id is null then
    raise exception 'There is no such date at this masjid.' using errcode = 'no_data_found';
  end if;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(),
          case when v_id is null then 'madrasah_event_added' else 'madrasah_event_changed' end,
          jsonb_build_object('id', v_row.id, 'name', v_row.name,
                             'on', v_row.on_date, 'estimated', v_row.is_estimated));
  return jsonb_build_object('id', v_row.id);
end $fn$;

create or replace function public.delete_madrasah_event(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_masjid uuid := public.current_masjid();
  v_row    public.madrasah_events%rowtype;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may change the madrasah calendar.'
      using errcode = '42501';
  end if;
  delete from public.madrasah_events
   where id = p_id and masjid_id = v_masjid
  returning * into v_row;
  if v_row.id is null then
    raise exception 'There is no such date at this masjid.' using errcode = 'no_data_found';
  end if;
  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'madrasah_event_removed',
          jsonb_build_object('name', v_row.name, 'on', v_row.on_date));
  return jsonb_build_object('removed', v_row.name);
end $fn$;

-- ---------------------------------------------------------------------------
--  4. The academic year
-- ---------------------------------------------------------------------------
create or replace function public.madrasah_years_list()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare v_masjid uuid := public.current_masjid();
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may see the madrasah years.'
      using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', y.id, 'label', y.label, 'starts_on', y.starts_on,
             'ends_on', y.ends_on, 'is_current', y.is_current)
           order by y.starts_on desc)
      from public.madrasah_years y where y.masjid_id = v_masjid), '[]'::jsonb);
end $fn$;

create or replace function public.save_madrasah_year(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_id     uuid := nullif(p->>'id', '')::uuid;
  v_masjid uuid := public.current_masjid();
  v_label  text := btrim(coalesce(p->>'label', ''));
  v_from   date := nullif(p->>'starts_on', '')::date;
  v_to     date := nullif(p->>'ends_on', '')::date;
  v_cur    boolean := coalesce((p->>'is_current')::boolean, false);
  v_row    public.madrasah_years%rowtype;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may change the madrasah year.'
      using errcode = '42501';
  end if;
  if v_masjid is null then
    raise exception 'No masjid is selected.' using errcode = '42501';
  end if;
  if v_label = '' or v_from is null or v_to is null then
    raise exception 'A year needs a name, a first day and a last day.'
      using errcode = 'check_violation';
  end if;
  if v_to < v_from then
    raise exception 'That year ends before it begins.' using errcode = 'check_violation';
  end if;

  --  THE OLD CURRENT YEAR IS STOOD DOWN FIRST, IN THE SAME TRANSACTION.
  --  There is a unique index allowing one current year per masjid, so without
  --  this the second one fails on the index and the screen reports a database
  --  error at somebody who did nothing wrong.
  if v_cur then
    update public.madrasah_years set is_current = false, updated_at = now()
     where masjid_id = v_masjid and is_current
       and (v_id is null or id <> v_id);
  end if;

  insert into public.madrasah_years as y
    (masjid_id, id, label, starts_on, ends_on, is_current)
  values (v_masjid, coalesce(v_id, gen_random_uuid()), v_label, v_from, v_to, v_cur)
  on conflict (id) do update set
    label = excluded.label, starts_on = excluded.starts_on,
    ends_on = excluded.ends_on, is_current = excluded.is_current,
    updated_at = now()
  where y.masjid_id = v_masjid
  returning * into v_row;

  if v_row.id is null then
    raise exception 'There is no such year at this masjid.' using errcode = 'no_data_found';
  end if;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'madrasah_year_saved',
          jsonb_build_object('id', v_row.id, 'label', v_row.label,
                             'current', v_row.is_current));
  return jsonb_build_object('id', v_row.id);
end $fn$;

-- ---------------------------------------------------------------------------
--  5. The masjid's particulars
-- ---------------------------------------------------------------------------
create or replace function public.masjid_profile_get()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_masjid uuid := public.current_masjid();
  v_row    public.masjid_profile%rowtype;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may see the masjid profile.'
      using errcode = '42501';
  end if;
  select * into v_row from public.masjid_profile where masjid_id = v_masjid;
  return jsonb_build_object(
    'legal_name', v_row.legal_name, 'short_name', v_row.short_name,
    'address', v_row.address, 'postcode', v_row.postcode,
    'phone', v_row.phone, 'email', v_row.email, 'website', v_row.website,
    'charity_no', v_row.charity_no, 'updated_at', v_row.updated_at,
    'images', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', i.id, 'kind', i.kind, 'path', i.storage_path,
               'alt_text', i.alt_text, 'bytes', i.bytes,
               'content_type', i.content_type, 'is_current', i.is_current,
               'uploaded_at', i.uploaded_at)
             order by i.kind, i.is_current desc, i.uploaded_at desc)
        from public.masjid_images i where i.masjid_id = v_masjid), '[]'::jsonb));
end $fn$;

create or replace function public.save_masjid_profile(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare v_masjid uuid := public.current_masjid();
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may change the masjid profile.'
      using errcode = '42501';
  end if;
  if v_masjid is null then
    raise exception 'No masjid is selected.' using errcode = '42501';
  end if;

  insert into public.masjid_profile as m
    (masjid_id, legal_name, short_name, address, postcode, phone, email,
     website, charity_no, updated_at, updated_by)
  values (v_masjid,
    nullif(btrim(coalesce(p->>'legal_name', '')), ''),
    nullif(btrim(coalesce(p->>'short_name', '')), ''),
    nullif(btrim(coalesce(p->>'address', '')), ''),
    nullif(btrim(coalesce(p->>'postcode', '')), ''),
    nullif(btrim(coalesce(p->>'phone', '')), ''),
    nullif(btrim(coalesce(p->>'email', '')), ''),
    nullif(btrim(coalesce(p->>'website', '')), ''),
    nullif(btrim(coalesce(p->>'charity_no', '')), ''),
    now(), auth.uid())
  on conflict (masjid_id) do update set
    legal_name = excluded.legal_name, short_name = excluded.short_name,
    address = excluded.address, postcode = excluded.postcode,
    phone = excluded.phone, email = excluded.email,
    website = excluded.website, charity_no = excluded.charity_no,
    updated_at = now(), updated_by = auth.uid();

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'masjid_profile_saved', '{}'::jsonb);
  return jsonb_build_object('saved', true);
end $fn$;

-- ---------------------------------------------------------------------------
--  6. The brand images
-- ---------------------------------------------------------------------------
create or replace function public.masjid_brand()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare v_masjid uuid := coalesce(public.current_masjid(), public.sole_masjid());
begin
  --  PUBLIC, AND ONLY THE CURRENT ONES. A mail client fetching a banner is
  --  signed in to nothing. It gets the picture and the words under it, and no
  --  list of what else the masjid has uploaded.
  if v_masjid is null then return '{}'::jsonb; end if;
  return coalesce((
    select jsonb_object_agg(i.kind, jsonb_build_object(
             'path', i.storage_path, 'alt_text', i.alt_text))
      from public.masjid_images i
     where i.masjid_id = v_masjid and i.is_current), '{}'::jsonb);
end $fn$;

create or replace function public.record_masjid_image(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_masjid uuid := public.current_masjid();
  v_kind   text := btrim(coalesce(p->>'kind', ''));
  v_path   text := btrim(coalesce(p->>'storage_path', ''));
  v_cur    boolean := coalesce((p->>'is_current')::boolean, false);
  v_row    public.masjid_images%rowtype;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may change the masjid images.'
      using errcode = '42501';
  end if;
  if v_masjid is null then
    raise exception 'No masjid is selected.' using errcode = '42501';
  end if;
  if v_kind not in ('logo', 'email_banner', 'letterhead') then
    raise exception 'That is not a kind of image this masjid keeps.'
      using errcode = 'check_violation';
  end if;
  if v_path = '' then
    raise exception 'The image was not uploaded, so there is nothing to record.'
      using errcode = 'check_violation';
  end if;

  if v_cur then
    update public.masjid_images set is_current = false
     where masjid_id = v_masjid and kind = v_kind and is_current;
  end if;

  insert into public.masjid_images
    (masjid_id, kind, storage_path, alt_text, bytes, content_type,
     is_current, uploaded_by)
  values (v_masjid, v_kind, v_path,
          nullif(btrim(coalesce(p->>'alt_text', '')), ''),
          nullif(p->>'bytes', '')::integer,
          nullif(btrim(coalesce(p->>'content_type', '')), ''),
          v_cur, auth.uid())
  returning * into v_row;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'masjid_image_added',
          jsonb_build_object('id', v_row.id, 'kind', v_row.kind,
                             'current', v_row.is_current));
  return jsonb_build_object('id', v_row.id);
end $fn$;

create or replace function public.set_current_masjid_image(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_masjid uuid := public.current_masjid();
  v_row    public.masjid_images%rowtype;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may change the masjid images.'
      using errcode = '42501';
  end if;
  select * into v_row from public.masjid_images
   where id = p_id and masjid_id = v_masjid;
  if v_row.id is null then
    raise exception 'There is no such image at this masjid.' using errcode = 'no_data_found';
  end if;

  update public.masjid_images set is_current = false
   where masjid_id = v_masjid and kind = v_row.kind and is_current and id <> p_id;
  update public.masjid_images set is_current = true where id = p_id;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'masjid_image_set_current',
          jsonb_build_object('id', p_id, 'kind', v_row.kind));
  return jsonb_build_object('id', p_id, 'kind', v_row.kind);
end $fn$;

create or replace function public.delete_masjid_image(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_masjid uuid := public.current_masjid();
  v_row    public.masjid_images%rowtype;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may change the masjid images.'
      using errcode = '42501';
  end if;
  select * into v_row from public.masjid_images
   where id = p_id and masjid_id = v_masjid;
  if v_row.id is null then
    raise exception 'There is no such image at this masjid.' using errcode = 'no_data_found';
  end if;
  --  THE ONE IN USE IS NOT DELETED BY ACCIDENT. Every letter and every email
  --  points at it; removing it leaves a broken picture in mail already sent.
  --  Choose another one first and this becomes allowed.
  if v_row.is_current then
    raise exception 'That is the one in use. Set another as current first, then remove this one.'
      using errcode = 'check_violation';
  end if;
  delete from public.masjid_images where id = p_id;
  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'masjid_image_removed',
          jsonb_build_object('kind', v_row.kind, 'path', v_row.storage_path));
  return jsonb_build_object('removed', v_row.storage_path);
end $fn$;

-- ---------------------------------------------------------------------------
--  7. Who can open the madrasah portal, and why. READ ONLY — see the header.
-- ---------------------------------------------------------------------------
create or replace function public.madrasah_people()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare v_masjid uuid := public.current_masjid();
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may see who can open the madrasah.'
      using errcode = '42501';
  end if;
  return jsonb_build_object(
    'me', auth.uid(),
    'people', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', p.id, 'name', p.full_name, 'email', p.email,
               'active', p.is_active,
               'roles', (select array_agg(r.role::text order by r.role)
                           from public.user_roles r
                          where r.user_id = p.id and r.masjid_id = v_masjid),
               --  WHY they can get in, worked out here rather than on the
               --  screen, so that the reason and the rule cannot drift apart.
               'reach', case
                 when exists (select 1 from public.user_roles r
                               where r.user_id = p.id and r.masjid_id = v_masjid
                                 and r.role = 'admin') then 'everything'
                 else 'madrasah only' end,
               'two_step', exists (select 1 from auth.mfa_factors f
                                    where f.user_id = p.id and f.status = 'verified'),
               'last_in', (select u.last_sign_in_at from auth.users u where u.id = p.id),
               'is_me', p.id = auth.uid())
             order by p.full_name nulls last, p.email)
        from public.profiles p
       where exists (select 1 from public.user_roles r
                      where r.user_id = p.id and r.masjid_id = v_masjid
                        and r.role in ('admin', 'madrasah'))
    ), '[]'::jsonb));
end $fn$;

-- ---------------------------------------------------------------------------
--  8. The grants. Revoke first — Postgres grants EXECUTE to PUBLIC.
-- ---------------------------------------------------------------------------
revoke all on function public.verified_madrasah()                from public, anon;
revoke all on function public.madrasah_calendar(date, date)      from public;
revoke all on function public.save_madrasah_closure(jsonb)       from public, anon;
revoke all on function public.delete_madrasah_closure(uuid)      from public, anon;
revoke all on function public.save_madrasah_event(jsonb)         from public, anon;
revoke all on function public.delete_madrasah_event(uuid)        from public, anon;
revoke all on function public.madrasah_years_list()              from public, anon;
revoke all on function public.save_madrasah_year(jsonb)          from public, anon;
revoke all on function public.masjid_profile_get()               from public, anon;
revoke all on function public.save_masjid_profile(jsonb)         from public, anon;
revoke all on function public.masjid_brand()                     from public;
revoke all on function public.record_masjid_image(jsonb)         from public, anon;
revoke all on function public.set_current_masjid_image(uuid)     from public, anon;
revoke all on function public.delete_masjid_image(uuid)          from public, anon;
revoke all on function public.madrasah_people()                  from public, anon;

grant execute on function public.verified_madrasah()             to authenticated;
grant execute on function public.save_madrasah_closure(jsonb)    to authenticated;
grant execute on function public.delete_madrasah_closure(uuid)   to authenticated;
grant execute on function public.save_madrasah_event(jsonb)      to authenticated;
grant execute on function public.delete_madrasah_event(uuid)     to authenticated;
grant execute on function public.madrasah_years_list()           to authenticated;
grant execute on function public.save_madrasah_year(jsonb)       to authenticated;
grant execute on function public.masjid_profile_get()            to authenticated;
grant execute on function public.save_masjid_profile(jsonb)      to authenticated;
grant execute on function public.record_masjid_image(jsonb)      to authenticated;
grant execute on function public.set_current_masjid_image(uuid)  to authenticated;
grant execute on function public.delete_masjid_image(uuid)       to authenticated;
grant execute on function public.madrasah_people()               to authenticated;

--  THE TWO PUBLIC ONES, named on their own line so that adding a third is a
--  decision somebody has to write down rather than a line in a list.
grant execute on function public.madrasah_calendar(date, date) to anon, authenticated;
grant execute on function public.masjid_brand()                to anon, authenticated;

commit;

-- ---------------------------------------------------------------------------
--  THE STORAGE BUCKET. Outside the transaction because storage.buckets is
--  managed by the Storage extension and an insert here is not part of the
--  schema change above.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('brand', 'brand', true)
on conflict (id) do update set public = true;

drop policy if exists brand_images_insert on storage.objects;
drop policy if exists brand_images_update on storage.objects;
drop policy if exists brand_images_delete on storage.objects;
drop policy if exists brand_images_list   on storage.objects;

create policy brand_images_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'brand' and public.verified_admin());
create policy brand_images_update on storage.objects for update to authenticated
  using (bucket_id = 'brand' and public.verified_admin())
  with check (bucket_id = 'brand' and public.verified_admin());
create policy brand_images_delete on storage.objects for delete to authenticated
  using (bucket_id = 'brand' and public.verified_admin());
create policy brand_images_list on storage.objects for select to authenticated
  using (bucket_id = 'brand' and public.verified_admin());

-- ===========================================================================
--  AFTERWARDS
--
--    select jsonb_pretty(public.madrasah_calendar());
--
--  Should return the academic year 2026/27, eight closures and ten Islamic
--  dates — the same list the public Holiday Planner prints today.
--
--  NEXT, AND IT IS THE POINT OF ALL THIS: the planner in index_template.html
--  still reads its own hard-coded array. Until it calls madrasah_calendar()
--  there are two lists of holidays and they will disagree the first time
--  somebody amends one.
-- ===========================================================================
