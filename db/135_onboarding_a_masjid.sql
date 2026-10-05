-- 135 — Onboarding a masjid
--
-- WHERE THIS CAME FROM, AND WHY IT MOVED HERE. This was written in MasjidOne's
-- own `founder/` folder, which is gitignored. That was the wrong home for it:
-- the folder is excluded because it holds margins, break-even counts and
-- commercial workings that must never reach a public repository — and this file
-- holds none of those. It deliberately holds NO PRICES at all; it stores which
-- BAND a masjid is on, and the money stays in PRICING_BANDS in the website.
--
-- Meanwhile `db/` is the migration history of the very database this alters,
-- and it already describes the whole schema in public across 133 files. Keeping
-- one migration outside that history is how a schema and its record drift
-- apart — the same failure that let the deployed stripe-webhook run three days
-- ahead of what git believed. So it lives where every other migration lives.
--
-- APPLIED to production on 5 October 2026, statement group by statement group,
-- because the MCP tooling times out on a file this size. Verified afterwards:
-- three tables with RLS on and no policies, nine functions, nothing readable or
-- executable from a browser, and PUBLIC holding EXECUTE on none of them.
--
-- WHY. There is no create_masjid, onboard, provision or seed function anywhere
-- in 280 public functions. Masjid #2 is hand-written SQL across 54 tables with
-- no rollback, done once, under time pressure, against a database holding
-- children's records. That is the single most dangerous hour in this business's
-- future and it is entirely avoidable.
--
-- WHAT THIS DOES AND DOES NOT DO — read this before trusting it.
--
-- It creates the parts whose shape is verified: the masjid row, its plan, the
-- first administrator's invitation, and the audit trail. It creates the masjid
-- NOT LIVE, because going live is a decision somebody should make on purpose
-- rather than a side effect of typing a name.
--
-- It does NOT write the per-module setup rows — masjid_profile,
-- madrasah_settings, madrasah_years, madrasah_fee_settings, prayer_years,
-- app_settings. Six tables need one, and inventing defaults for columns
-- without reading each table's constraints would be guessing dressed as
-- automation. Instead masjid_setup_checklist() REPORTS what is missing, so an
-- incomplete onboarding is visible on a screen rather than discovered by a
-- committee on their first Friday. Fill those in, then extend this function
-- and delete this paragraph.
--
-- THERE IS DELIBERATELY NO delete_masjid(). A masjid's rows include children's
-- attendance and safeguarding records with statutory retention. Taking a
-- customer off the platform is masjid_take_offline() plus an export plus a
-- decision about retention — not one function anybody can call at 11pm.

-- ---------------------------------------------------------------------------
create or replace function public.create_masjid(payload jsonb)
returns jsonb
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_slug  text := lower(btrim(coalesce(payload->>'slug','')));
  v_name  text := btrim(coalesce(payload->>'name',''));
  v_plan  text := coalesce(nullif(btrim(coalesce(payload->>'plan','')),''), 'complete');
  v_band  text := nullif(btrim(coalesce(payload->>'band','')),'');
  v_email text := lower(btrim(coalesce(payload->>'admin_email','')));
  v_id    uuid;
begin
  if not public.is_platform_admin() then
    raise exception 'Only MasjidOne support, with two-step completed, may create a masjid.'
      using errcode = '42501';
  end if;

  /* The slug ends up in URLs, in reference prefixes and in the app's own
     requests. Getting it wrong is not a cosmetic problem later, it is a
     migration, so it is validated here rather than trusted. */
  if v_slug !~ '^[a-z][a-z0-9-]{2,30}$' then
    raise exception 'A slug must be 3 to 31 characters, start with a letter, and use only lowercase letters, numbers and hyphens. Got "%".', v_slug
      using errcode = '22023';
  end if;
  if v_name = '' then
    raise exception 'A masjid needs a name.' using errcode = '22023';
  end if;
  /* masjids.town is NOT NULL in production. Caught by mirroring the real
     schema: the earlier hand-written stub had it nullable, so this function
     passed a test it would have failed against the real database with a raw
     constraint violation instead of a sentence anybody could act on. */
  if btrim(coalesce(payload->>'town','')) = '' then
    raise exception 'A masjid needs a town — the column is required, and it is what tells two masajid of the same name apart.'
      using errcode = '22023';
  end if;
  if exists (select 1 from public.masjids where slug = v_slug) then
    raise exception 'There is already a masjid with the slug "%".', v_slug
      using errcode = '23505';
  end if;
  if not exists (select 1 from public.plans where code = v_plan) then
    raise exception 'There is no plan called "%".', v_plan using errcode = '22023';
  end if;
  if v_email <> '' and v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'That does not look like an email address: "%".', v_email
      using errcode = '22023';
  end if;

  /* NOT LIVE. masjid_id_for() only resolves live masjids, so until somebody
     calls masjid_go_live() this masjid is invisible to every public read —
     which is what you want while you are still loading their timetable. */
  insert into public.masjids (slug, name, short_name, town, domain, timezone,
                              charity_number, ref_prefix, is_live)
  values (v_slug, v_name,
          nullif(btrim(coalesce(payload->>'short_name','')),''),
          btrim(payload->>'town'),
          nullif(btrim(coalesce(payload->>'domain','')),''),
          coalesce(nullif(btrim(coalesce(payload->>'timezone','')),''), 'Europe/London'),
          nullif(btrim(coalesce(payload->>'charity_number','')),''),
          upper(coalesce(nullif(btrim(coalesce(payload->>'ref_prefix','')),''),
                         upper(substr(v_slug, 1, 3)))),
          false)
  returning id into v_id;

  insert into public.masjid_plan (masjid_id, plan_code, band, note)
  values (v_id, v_plan, v_band, 'Set at onboarding.');

  /* The first administrator. An invitation, not an account: pending_access
     grants nothing until the person signs up and claims it, which is the
     existing design and the right one. */
  if v_email <> '' then
    insert into public.pending_access
      (masjid_id, email, roles, invited_by, invited_at, expires_at, full_name, phone, note)
    values (v_id, v_email, array['admin']::public.app_role[], auth.uid(), now(),
            now() + interval '30 days',
            nullif(btrim(coalesce(payload->>'admin_name','')),''),
            nullif(btrim(coalesce(payload->>'admin_phone','')),''),
            'First administrator, created with the masjid.');
  end if;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_id, auth.uid(), 'masjid_created',
          jsonb_build_object('slug', v_slug, 'name', v_name, 'plan', v_plan,
                             'band', v_band, 'admin_invited', v_email <> ''));

  return jsonb_build_object(
    'id', v_id, 'slug', v_slug, 'name', v_name, 'plan', v_plan, 'band', v_band,
    'is_live', false,
    'admin_invited', case when v_email <> '' then v_email else null end,
    'next', 'Complete the setup checklist, then call masjid_go_live(''' || v_slug || ''').');
end $$;

-- ---------------------------------------------------------------------------
/* What is still missing before this masjid can open. Reports rather than
   fixes, because a checklist that silently repairs things teaches you nothing
   about what onboarding actually needs. */
create or replace function public.masjid_setup_checklist(p_slug text)
returns jsonb
language plpgsql stable security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_id uuid; v_items jsonb := '[]'::jsonb; v_missing int := 0;
begin
  if not public.is_platform_admin() then
    raise exception 'Only MasjidOne support may read a setup checklist.'
      using errcode = '42501';
  end if;
  select id into v_id from public.masjids where slug = p_slug;
  if v_id is null then
    raise exception 'There is no masjid called %.', p_slug using errcode = '22023';
  end if;

  /* Each per-masjid table that needs exactly one row before the masjid works.
     Checked by looking, not by assuming — a table added later and forgotten
     here shows up as a masjid that half works. */
  declare
    t record;
    v_n int;
  begin
    for t in
      select * from (values
        ('masjid_profile',       'The masjid''s own details: address, contact, about.'),
        ('prayer_years',         'A published prayer timetable year. Without it the app, the screens and the reminders have nothing to show.'),
        ('madrasah_settings',    'Madrasah settings, including which days the register runs.'),
        ('madrasah_years',       'A madrasah year, or no register can be taken.'),
        ('madrasah_fee_settings','Fee settings, before anything can be charged.'),
        ('app_settings',         'The notify endpoint and its secret, or no push notification will send.')
      ) as x(tbl, why)
    loop
      /* prayer_years is judged on `published`, not on existence: a drafted
         year shows a congregation nothing. The others are judged on having
         any row. */
      execute format('select count(*) from public.%I where masjid_id = $1%s',
                     t.tbl, case when t.tbl = 'prayer_years' then ' and published' else '' end)
        into v_n using v_id;
      if v_n = 0 then v_missing := v_missing + 1; end if;
      v_items := v_items || jsonb_build_object(
        'item', t.tbl, 'done', v_n > 0, 'why', t.why);
    end loop;
  end;

  return jsonb_build_object(
    'masjid',  p_slug,
    'is_live', (select is_live from public.masjids where id = v_id),
    'plan',    (select plan_code from public.masjid_plan
                 where masjid_id = v_id and ended_on is null),
    'admin_invited', exists (select 1 from public.pending_access
                              where masjid_id = v_id and claimed_at is null),
    'admin_active',  exists (select 1 from public.user_roles
                              where masjid_id = v_id and role = 'admin'),
    'missing', v_missing,
    'ready',   v_missing = 0,
    'items',   v_items);
end $$;

-- ---------------------------------------------------------------------------
/* Going live is its own decision, and it refuses while the checklist is
   incomplete. A masjid switched on with no timetable is a congregation
   looking at a blank screen. */
create or replace function public.masjid_go_live(p_slug text, p_force boolean default false)
returns jsonb
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_id uuid; v_check jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Only MasjidOne support, with two-step completed, may take a masjid live.'
      using errcode = '42501';
  end if;
  select id into v_id from public.masjids where slug = p_slug;
  if v_id is null then
    raise exception 'There is no masjid called %.', p_slug using errcode = '22023';
  end if;

  v_check := public.masjid_setup_checklist(p_slug);
  if not (v_check->>'ready')::boolean and not p_force then
    raise exception 'Not ready: % of the setup items are still missing. Read masjid_setup_checklist(%), or pass p_force to override and say why in the audit.',
      v_check->>'missing', quote_literal(p_slug) using errcode = '22023';
  end if;
  if not (v_check->>'admin_active')::boolean and not p_force then
    raise exception 'Nobody at this masjid can sign in yet — no admin has claimed their invitation.'
      using errcode = '22023';
  end if;

  update public.masjids set is_live = true where id = v_id;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_id, auth.uid(), 'masjid_went_live',
          jsonb_build_object('slug', p_slug, 'forced', p_force, 'checklist', v_check));

  return jsonb_build_object('masjid', p_slug, 'is_live', true, 'forced', p_force);
end $$;

/* The reverse. Reversible on purpose: this hides a masjid from every public
   read without touching one row of their data. */
create or replace function public.masjid_take_offline(p_slug text, p_reason text)
returns jsonb
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_id uuid;
begin
  if not public.is_platform_admin() then
    raise exception 'Only MasjidOne support, with two-step completed, may take a masjid offline.'
      using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_reason,'')),'') is null then
    raise exception 'Say why. This switches off a congregation''s prayer times.'
      using errcode = '22023';
  end if;
  select id into v_id from public.masjids where slug = p_slug;
  if v_id is null then
    raise exception 'There is no masjid called %.', p_slug using errcode = '22023';
  end if;

  update public.masjids set is_live = false where id = v_id;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_id, auth.uid(), 'masjid_taken_offline',
          jsonb_build_object('slug', p_slug, 'reason', btrim(p_reason)));

  return jsonb_build_object('masjid', p_slug, 'is_live', false, 'reason', btrim(p_reason));
end $$;

/* `from public`, NOT `from anon, authenticated` — and this distinction is the
   whole reason this comment exists.

   A function in Postgres is created with EXECUTE granted to PUBLIC. On top of
   that, Supabase's default privileges for this schema grant EXECUTE to anon,
   authenticated and service_role by name. Revoking from anon removes only the
   named grant; anon still holds EXECUTE **through PUBLIC**, so the revoke
   reads as though it worked and changes nothing.

   This was not theoretical. Applying 001 on 5 October left all five of its
   functions callable by anon, with an ACL of `=X/postgres` — the leading `=`
   being PUBLIC. Caught by checking has_function_privilege('anon', ...) after
   applying, rather than trusting that the revoke had done what it said.

   So: revoke from PUBLIC first, then grant to the roles that should have it. */
revoke all on function public.create_masjid(jsonb) from public, anon, authenticated;
revoke all on function public.masjid_setup_checklist(text) from public, anon, authenticated;
revoke all on function public.masjid_go_live(text, boolean) from public, anon, authenticated;
revoke all on function public.masjid_take_offline(text, text) from public, anon, authenticated;
grant execute on function public.create_masjid(jsonb)            to authenticated;
grant execute on function public.masjid_setup_checklist(text)    to authenticated;
grant execute on function public.masjid_go_live(text, boolean)   to authenticated;
grant execute on function public.masjid_take_offline(text, text) to authenticated;
