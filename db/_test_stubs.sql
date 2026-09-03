create extension if not exists pgcrypto;
create schema if not exists auth;
create table auth.users(id uuid primary key default gen_random_uuid());
do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if;
end $$;
create table public.admin_audit(
  id bigserial primary key, action text not null, detail jsonb,
  actor uuid, created_at timestamptz not null default now());
create or replace function public.is_admin() returns boolean
  language sql stable as $$ select current_setting('app.is_admin', true) = 'on' $$;

-- Supabase provides these; the local harness has to stand them in.
create or replace function auth.uid() returns uuid
  language sql stable as $$ select nullif(current_setting('app.uid', true), '')::uuid $$;
create or replace function public.has_role(uid uuid, r text) returns boolean
  language sql stable as $$ select current_setting('app.role_' || r, true) = 'on' $$;

-- Supabase's auth.jwt(). Here it fabricates just the claim migration 011 reads,
-- so a test can say "this session has passed two-step" or "it has not".
create or replace function auth.jwt() returns jsonb language sql stable as $$
  select jsonb_build_object('aal', coalesce(nullif(current_setting('app.aal', true), ''), 'aal1'));
$$;
