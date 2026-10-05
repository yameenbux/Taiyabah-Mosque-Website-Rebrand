-- 134 — Plans and entitlements
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
-- WHY. The platform has no idea what any masjid has bought. `masjids.is_live`
-- says whether they are switched on, and nothing says whether they are on
-- Madrasah or Masjid Complete, so nothing can gate a feature by plan and
-- nothing can be invoiced from the database. With one customer that is
-- invisible. With three it is the thing that makes a mistake expensive.
--
-- WHAT IS DELIBERATELY NOT HERE: PRICES.
-- The money lives in PRICING_BANDS in the website's lib/site.ts and nowhere
-- else — that is a standing rule, and it is the right one. A price stored here
-- too would be a second source of truth that drifts the first time a band
-- changes, and a price change would need a migration. So this stores WHICH
-- BAND a masjid is on, not what that band costs. Multiply at invoice time.
--
-- ADDITIVE ONLY. Nothing existing is altered or dropped, so 001-down.sql
-- restores the database exactly.
--
-- The house pattern is followed throughout: RLS on, no policy, no grants,
-- reached only through SECURITY DEFINER functions that filter on
-- current_masjid(). A table you can SELECT from directly is a table that will
-- eventually be SELECTed from across tenants.

-- ---------------------------------------------------------------------------
-- The catalogue. Rows, not an enum: adding a plan should be an INSERT, and an
-- enum value cannot be removed in Postgres, which would make this migration
-- irreversible on its own.
-- ---------------------------------------------------------------------------
create table public.plans (
  code        text primary key,
  name        text not null,
  /* What the plan unlocks. Checked by masjid_has(). Kept as an array rather
     than a join table because it is read on nearly every request and is a
     handful of short strings. */
  features    text[] not null default '{}',
  /* false hides it from the onboarding picker without deleting the history of
     masajid who are on it. */
  selectable  boolean not null default true,
  sort        int not null default 100,
  created_at  timestamptz not null default now()
);
comment on table public.plans is
  'What a masjid can buy, and what each one unlocks. No prices: those live in the website''s PRICING_BANDS and are deliberately not duplicated here.';

insert into public.plans (code, name, features, sort) values
  ('madrasah', 'Madrasah',
   array['madrasah','parent_access'], 10),
  ('complete', 'Masjid Complete',
   array['madrasah','parent_access','website','app','screens','donations'], 20),
  /* Not selectable yet: nothing behind it is built. It exists so the website
     can advertise it and the onboarding picker cannot accidentally sell it. */
  ('safe', 'MasjidOne Safe',
   array['martyns_law'], 30);
update public.plans set selectable = false where code = 'safe';

-- ---------------------------------------------------------------------------
-- What each masjid is on, WITH HISTORY. A plan change closes the old row and
-- opens a new one rather than overwriting, because "what were they on in
-- March" is a question an invoice query has to answer.
-- ---------------------------------------------------------------------------
create table public.masjid_plan (
  id          uuid primary key default gen_random_uuid(),
  masjid_id   uuid not null references public.masjids(id) on delete cascade,
  plan_code   text not null references public.plans(code),
  /* The size band at signing: 'a'|'b'|'c'|'d', matching PRICING_BANDS ids in
     the website. Deliberately opaque to the database — it is a label to look
     a price up by, not a number to do arithmetic on. */
  band        text,
  started_on  date not null default current_date,
  ended_on    date,
  note        text,
  created_at  timestamptz not null default now(),
  constraint masjid_plan_dates check (ended_on is null or ended_on >= started_on),
  constraint masjid_plan_band check (band is null or band in ('a','b','c','d'))
);
comment on table public.masjid_plan is
  'One row per masjid per plan period. A change closes the old row and opens a new one — an invoice query has to be able to answer what they were on last March.';

/* At most one open plan per masjid. A partial unique index rather than a
   trigger: the database refuses the second one outright, and nothing has to
   remember to check. */
create unique index masjid_plan_one_open
  on public.masjid_plan (masjid_id) where ended_on is null;
create index masjid_plan_masjid on public.masjid_plan (masjid_id, started_on desc);

-- ---------------------------------------------------------------------------
-- Per-masjid overrides, so a feature can be turned on or off for one customer
-- without inventing a plan for them. This is what a pilot, a goodwill
-- arrangement, or an unbuilt module being switched on early looks like.
-- ---------------------------------------------------------------------------
create table public.masjid_feature (
  masjid_id  uuid not null references public.masjids(id) on delete cascade,
  feature    text not null,
  enabled    boolean not null,
  /* Required, and not for tidiness: an override with no reason is one nobody
     dares remove two years later. */
  reason     text not null,
  set_by     uuid,
  set_at     timestamptz not null default now(),
  primary key (masjid_id, feature)
);
comment on table public.masjid_feature is
  'Per-masjid overrides on top of the plan. enabled=false removes something the plan grants; enabled=true adds something it does not. The reason is mandatory.';

alter table public.plans          enable row level security;
alter table public.masjid_plan    enable row level security;
alter table public.masjid_feature enable row level security;
revoke all on public.plans, public.masjid_plan, public.masjid_feature
  from anon, authenticated;

-- ---------------------------------------------------------------------------
-- The only way in.
-- ---------------------------------------------------------------------------

/* DEFINED BEFORE masjid_has(), and the order is load-bearing: masjid_has is
   LANGUAGE sql, which Postgres parses and resolves at CREATE time, so it
   cannot reference a function that does not exist yet. A plpgsql function
   would have deferred the lookup to run time and let this migration apply
   cleanly, then failed on the first call instead. Caught by running it.
   Do not reorder these two. */
/* The same question about a named masjid. Platform admins only — and the
   admin check is inside, not left to the caller. */
/* STABLE, deliberately: this is called on nearly every request and Postgres
   may then cache it within a query. The consequence, found by testing rather
   than reasoning: a statement that calls set_masjid_feature() AND reads this
   back sees the answer from before the write, because a STABLE function reads
   the snapshot taken at the start of the statement. A frontend makes two round
   trips so it never sees this; a migration or a test written as one statement
   will. Read it in a separate statement. */
create or replace function public.masjid_has_for(p_masjid uuid, p_feature text)
returns boolean
language plpgsql stable security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_plan_grants boolean; v_override boolean;
begin
  if p_masjid is null or nullif(btrim(coalesce(p_feature,'')),'') is null then
    return false;
  end if;
  /* Your own masjid, or any masjid if you are platform support. Anything else
     is answered 'no' rather than refused, because a boolean that raises is a
     boolean every caller has to wrap. */
  if p_masjid <> coalesce(public.current_masjid(), '00000000-0000-0000-0000-000000000000'::uuid)
     and not public.is_platform_admin() then
    return false;
  end if;

  /* An override wins over the plan in BOTH directions, which is the point of
     it: switching something off for one masjid must be possible without
     moving them to a smaller plan. */
  select f.enabled into v_override
    from public.masjid_feature f
   where f.masjid_id = p_masjid and f.feature = p_feature;
  if found then return v_override; end if;

  select p_feature = any(pl.features) into v_plan_grants
    from public.masjid_plan mp
    join public.plans pl on pl.code = mp.plan_code
   where mp.masjid_id = p_masjid and mp.ended_on is null;

  return coalesce(v_plan_grants, false);
end $$;

/* The question every feature asks. Scoped to the caller's own masjid, so a
   signed-in teacher cannot ask it about somebody else's. */
create or replace function public.masjid_has(p_feature text)
returns boolean
language sql stable security definer
set search_path to 'public', 'pg_temp'
as $$
  select public.masjid_has_for(public.current_masjid(), p_feature);
$$;

/* Everything a masjid is entitled to, for a settings screen or a support
   console. Same access rule as masjid_has_for. */
create or replace function public.masjid_entitlements(p_masjid uuid default null)
returns jsonb
language plpgsql stable security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_masjid uuid := coalesce(p_masjid, public.current_masjid()); v_out jsonb;
begin
  if v_masjid is null then return '{}'::jsonb; end if;
  if v_masjid <> coalesce(public.current_masjid(), '00000000-0000-0000-0000-000000000000'::uuid)
     and not public.is_platform_admin() then
    raise exception 'Not your masjid.' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'masjid',   m.slug,
    'plan',     mp.plan_code,
    'plan_name', pl.name,
    'band',     mp.band,
    'since',    mp.started_on,
    'features', (
      select coalesce(jsonb_object_agg(f, public.masjid_has_for(v_masjid, f)), '{}'::jsonb)
        from (
          select unnest(pl.features) as f
          union
          select mf.feature from public.masjid_feature mf where mf.masjid_id = v_masjid
        ) all_features
    ))
  into v_out
  from public.masjids m
  left join public.masjid_plan mp on mp.masjid_id = m.id and mp.ended_on is null
  left join public.plans pl on pl.code = mp.plan_code
  where m.id = v_masjid;

  return coalesce(v_out, '{}'::jsonb);
end $$;

/* Move a masjid onto a plan. Closes the open row and opens a new one in one
   transaction, so there is never a moment with two or none. */
create or replace function public.set_masjid_plan(
  p_masjid text, p_plan text, p_band text default null, p_note text default null)
returns jsonb
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_id uuid; v_old text;
begin
  if not public.is_platform_admin() then
    raise exception 'Only MasjidOne support, with two-step completed, may change a plan.'
      using errcode = '42501';
  end if;
  select id into v_id from public.masjids where slug = p_masjid;
  if v_id is null then
    raise exception 'There is no masjid called %.', p_masjid using errcode = '22023';
  end if;
  if not exists (select 1 from public.plans where code = p_plan) then
    raise exception 'There is no plan called %.', p_plan using errcode = '22023';
  end if;

  select plan_code into v_old from public.masjid_plan
   where masjid_id = v_id and ended_on is null;

  update public.masjid_plan set ended_on = current_date
   where masjid_id = v_id and ended_on is null;

  insert into public.masjid_plan (masjid_id, plan_code, band, note)
  values (v_id, p_plan, p_band, p_note);

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_id, auth.uid(), 'plan_changed',
          jsonb_build_object('from', v_old, 'to', p_plan, 'band', p_band, 'note', p_note));

  return jsonb_build_object('masjid', p_masjid, 'plan', p_plan, 'band', p_band,
                            'previous', v_old);
end $$;

/* Turn one feature on or off for one masjid. The reason is required by the
   signature, not just by the column. */
create or replace function public.set_masjid_feature(
  p_masjid text, p_feature text, p_enabled boolean, p_reason text)
returns jsonb
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_id uuid;
begin
  if not public.is_platform_admin() then
    raise exception 'Only MasjidOne support, with two-step completed, may change a feature.'
      using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_reason,'')),'') is null then
    raise exception 'Say why. An override with no reason is one nobody dares remove later.'
      using errcode = '22023';
  end if;
  select id into v_id from public.masjids where slug = p_masjid;
  if v_id is null then
    raise exception 'There is no masjid called %.', p_masjid using errcode = '22023';
  end if;

  insert into public.masjid_feature (masjid_id, feature, enabled, reason, set_by)
  values (v_id, p_feature, p_enabled, btrim(p_reason), auth.uid())
  on conflict (masjid_id, feature) do update
    set enabled = excluded.enabled, reason = excluded.reason,
        set_by = excluded.set_by, set_at = now();

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_id, auth.uid(), 'feature_override_set',
          jsonb_build_object('feature', p_feature, 'enabled', p_enabled, 'reason', p_reason));

  return jsonb_build_object('masjid', p_masjid, 'feature', p_feature, 'enabled', p_enabled);
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
revoke all on function public.masjid_has(text) from public, anon, authenticated;
revoke all on function public.masjid_has_for(uuid, text) from public, anon, authenticated;
revoke all on function public.masjid_entitlements(uuid) from public, anon, authenticated;
revoke all on function public.set_masjid_plan(text, text, text, text) from public, anon, authenticated;
revoke all on function public.set_masjid_feature(text, text, boolean, text) from public, anon, authenticated;
grant execute on function public.masjid_has(text)          to authenticated;
grant execute on function public.masjid_entitlements(uuid) to authenticated;
grant execute on function public.masjid_has_for(uuid, text) to authenticated;
grant execute on function public.set_masjid_plan(text, text, text, text) to authenticated;
grant execute on function public.set_masjid_feature(text, text, boolean, text) to authenticated;

/* Backfill: the founding masjid is on Masjid Complete. Written as a lookup
   rather than a hardcoded id, and a no-op if the row is somehow already there,
   so re-running this migration cannot create a second open plan. */
insert into public.masjid_plan (masjid_id, plan_code, band, note)
select m.id, 'complete', null, 'Backfilled by migration 001 — founding masjid.'
  from public.masjids m
 where not exists (select 1 from public.masjid_plan mp
                    where mp.masjid_id = m.id and mp.ended_on is null);
