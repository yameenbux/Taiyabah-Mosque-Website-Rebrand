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
