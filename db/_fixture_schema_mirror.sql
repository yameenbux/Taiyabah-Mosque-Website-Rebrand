-- Local schema fixture for the db/_test_*.sql suites. STRUCTURE ONLY — it holds
-- no data and is never applied to the platform.
--
-- IT LIVES HERE NOW because the tests do. It was written in MasjidOne's
-- gitignored founder/ folder, which meant the only copy of the fixture every
-- test in this folder depends on sat on a container that gets reclaimed.
--
-- IT MUST MIRROR PRODUCTION, NOT THE MINIMUM THAT COMPILES. Twice a stub that
-- was simpler than the real table let a test pass that production would have
-- failed: masjids.town was nullable here and NOT NULL there, and auth.users had
-- no email column, so a trigger's error message failed with "column u.email
-- does not exist" — a failure that does not exist in production. When a test
-- fails for a reason that smells like the fixture, fix the fixture.

-- SCHEMA MIRROR of the live platform, pulled from information_schema and
-- pg_get_functiondef on 5 October 2026. Structure only — NO DATA. Not one row
-- of anybody's records leaves production to make this.
--
-- It replaces the hand-written stub that preceded it, which was wrong in at
-- least one way that mattered: masjids.town is NOT NULL in production and was
-- nullable in the stub, so create_masjid() passed a test it would have failed
-- for real.
create schema if not exists auth;
/* email is here because production's auth.users has it and things read it.
   137's trigger names the offending account in its error message, and with an
   id-only stub that error became "column u.email does not exist" — a test
   failing for a reason that does not exist in production, which is worse than
   no test. Mirror what is really there, not the minimum that compiles. */
create table auth.users (id uuid primary key, email text);

-- Test seam. Production reads auth.uid() and auth.jwt(); here a row stands in
-- for the session so a test can become a different person.
create table public._test_session (uid uuid, aal2 boolean default true);
create or replace function auth.uid() returns uuid language sql stable as
$$ select uid from public._test_session limit 1 $$;
create or replace function public.is_aal2() returns boolean language sql stable as
$$ select coalesce((select aal2 from public._test_session limit 1), false) $$;

create type public.app_role as enum ('admin','teacher','parent','hall_office','madrasah','imam');

create table public.masjids (
  id uuid not null default gen_random_uuid(),
  slug text not null, name text not null, short_name text,
  town text not null,                       -- NOT NULL. The stub had this wrong.
  domain text,
  timezone text not null default 'Europe/London'::text,
  charity_number text,
  theme jsonb not null default '{}'::jsonb,
  logo_url text,
  is_live boolean not null default false,
  created_at timestamptz not null default now(),
  ref_prefix text not null default 'MO'::text
);
create table public.admin_audit (
  id bigserial not null, actor uuid, action text not null, detail jsonb,
  at timestamptz not null default now(), masjid_id uuid not null);
create table public.platform_admins (
  user_id uuid not null, added_at timestamptz not null default now(), note text);
create table public.user_roles (
  user_id uuid not null, role public.app_role not null,
  granted_at timestamptz not null default now(), granted_by uuid, masjid_id uuid not null);
create table public.active_masjid (
  user_id uuid not null, masjid_id uuid not null, set_at timestamptz not null default now());
create table public.pending_access (
  email text not null, roles public.app_role[] not null, invited_by uuid,
  invited_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + '14 days'::interval),
  claimed_at timestamptz, note text, full_name text, phone text, masjid_id uuid not null);
create table public.masjid_profile (
  masjid_id uuid not null, legal_name text, short_name text, address text, postcode text,
  phone text, email text, website text, charity_no text,
  updated_at timestamptz not null default now(), updated_by uuid);
create table public.prayer_years (
  year smallint not null, published boolean not null default false,
  note text not null default ''::text, updated_at timestamptz not null default now(),
  updated_by uuid, masjid_id uuid not null);
create table public.madrasah_settings (
  masjid_id uuid not null, key text not null, value jsonb not null,
  changed_at timestamptz not null default now(), changed_by uuid);
create table public.madrasah_fee_settings (
  masjid_id uuid not null, key text not null, value jsonb not null,
  changed_at timestamptz not null default now(), changed_by uuid);
create table public.madrasah_years (
  id uuid not null default gen_random_uuid(), masjid_id uuid not null, label text not null,
  starts_on date not null, ends_on date not null, is_current boolean not null default false,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create table public.app_settings (
  key text not null, value text not null, masjid_id uuid not null);

alter table public.active_masjid add constraint active_masjid_pkey primary key (user_id);
alter table public.admin_audit add constraint admin_audit_pkey primary key (id);
alter table public.app_settings add constraint app_settings_pkey primary key (masjid_id, key);
alter table public.madrasah_fee_settings add constraint madrasah_fee_settings_pkey primary key (masjid_id, key);
alter table public.madrasah_settings add constraint madrasah_settings_pkey primary key (masjid_id, key);
alter table public.madrasah_years add constraint madrasah_years_pkey primary key (id);
alter table public.masjid_profile add constraint masjid_profile_pkey primary key (masjid_id);
alter table public.masjids add constraint masjids_pkey primary key (id);
alter table public.pending_access add constraint pending_access_pkey primary key (masjid_id, email);
alter table public.platform_admins add constraint platform_admins_pkey primary key (user_id);
alter table public.prayer_years add constraint prayer_years_pkey primary key (masjid_id, year);
alter table public.user_roles add constraint user_roles_pkey primary key (user_id, masjid_id, role);
create unique index masjids_slug_key on public.masjids (slug);

-- Gate functions, copied verbatim from production.
create or replace function public.is_platform_admin() returns boolean
 language sql stable security definer set search_path to 'public','pg_temp' as $function$
  select public.is_aal2()
     and exists (select 1 from public.platform_admins p where p.user_id = auth.uid());
$function$;

create or replace function public.sole_masjid() returns uuid
 language plpgsql stable security definer set search_path to 'public','pg_temp' as $function$
declare v_id uuid; v_n int;
begin
  select count(*) into v_n from public.masjids;
  if v_n = 0 then raise exception 'No masjid has been set up yet.' using errcode='22023'; end if;
  if v_n > 1 then
    raise exception 'This system now runs more than one masjid, so this call has to say which. Update the caller to pass a masjid slug.'
      using errcode='22023'; end if;
  select id into v_id from public.masjids; return v_id;
end $function$;

create or replace function public.masjid_id_for(p_slug text) returns uuid
 language plpgsql stable security definer set search_path to 'public','pg_temp' as $function$
declare v_id uuid;
begin
  select id into v_id from public.masjids where slug = p_slug and is_live;
  if v_id is null then raise exception 'There is no masjid called %.', p_slug using errcode='22023'; end if;
  return v_id;
end $function$;

create or replace function public.current_masjid() returns uuid
 language sql stable security definer set search_path to 'public','pg_temp' as $function$
  with chosen as (
    select 2 as pri, a.masjid_id from public.active_masjid a where a.user_id = auth.uid()
    union all
    select 3, r.masjid_id from public.user_roles r where r.user_id = auth.uid()
     group by r.masjid_id
    having (select count(distinct masjid_id) from public.user_roles where user_id = auth.uid()) = 1)
  select c.masjid_id from chosen c
   where c.masjid_id is not null
     and (exists (select 1 from public.user_roles r
                   where r.user_id = auth.uid() and r.masjid_id = c.masjid_id)
       or public.is_platform_admin())
   order by c.pri limit 1;
$function$;

/* Verbatim from production. 137's tests turn on what this does and does not
   write to admin_audit, so a paraphrase would be testing the paraphrase. */
create table if not exists public.active_masjid (
  user_id uuid primary key, masjid_id uuid not null, set_at timestamptz not null default now());

create or replace function public.set_current_masjid(p_slug text)
returns jsonb language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $fn$
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
end $fn$;
