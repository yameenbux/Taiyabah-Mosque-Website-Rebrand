-- =============================================================================
--  LOCAL TEST ONLY — NEVER RUN AGAINST SUPABASE.
--
--  A stand-in for the parts of Supabase the migrations depend on, so that
--  policies can be proved against a real Postgres before anything is applied to
--  the live project.
--
--  It must stay FAITHFUL. Two bugs have already been caused by it drifting:
--    * missing GRANTs on public tables (migration 002 shipped broken)
--    * missing `usage` on schema auth, and a missing raw_user_meta_data column,
--      which made every role check silently fail and every test lie.
--  If a test fails in a way that smells like plumbing, suspect this file first.
-- =============================================================================

create extension if not exists pgcrypto;

do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon')          then create role anon nologin;          end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname='service_role')  then create role service_role nologin;  end if;
end $$;

create schema if not exists auth;

-- Same columns the migrations actually touch, including the metadata field
-- that handle_new_user() reads.
create table if not exists auth.users (
  id                 uuid primary key,
  email              text,
  raw_user_meta_data jsonb default '{}'::jsonb,
  email_confirmed_at timestamptz,
  created_at         timestamptz default now()
);

-- Supabase's auth.uid(). Here it reads a session variable so a test can say
-- "now behave as this person".
create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('test.uid', true), '')::uuid
$$;

-- Supabase grants these; without them auth.uid() throws inside every policy
-- and all access silently collapses to "denied".
grant usage on schema auth to anon, authenticated, service_role;
grant select on auth.users  to authenticated, service_role;

-- Supabase's auth.jwt(). Here it fabricates just the claim migration 011 reads,
-- so a test can say "this session has passed two-step" or "it has not".
create or replace function auth.jwt() returns jsonb language sql stable as $$
  select jsonb_build_object('aal', coalesce(nullif(current_setting('test.aal', true), ''), 'aal1'));
$$;
