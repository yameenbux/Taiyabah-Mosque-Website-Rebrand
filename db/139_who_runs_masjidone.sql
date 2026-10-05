-- 139 — who runs MasjidOne: adding and retiring platform administrators safely
--
-- WHY. Separating the founder's MasjidOne login from his Taiyabah login is a
-- handover: add the new account, prove it works, retire the old one. Done by
-- hand that is three statements against a live database with one chance to get
-- the order wrong, and getting it wrong locks the owner out of his own company.
--
-- THE TRAP IS TWO-STEP. is_platform_admin() is
--
--     is_aal2() AND exists(select 1 from platform_admins where user_id = auth.uid())
--
-- so a platform_admins row on an account with no verified second factor grants
-- NOTHING. Add such an account, retire the old one, and there is now no way into
-- the support console at all — the row is there, the sign-in works, and every
-- call still refuses. That is the failure this file exists to make impossible:
-- platform_admin_add() refuses an account that cannot pass aal2, and
-- platform_admin_remove() refuses to leave nobody who can.
--
-- NOBODY IS DELETED, THEY ARE RETIRED. revoked_at, not a DELETE, because "who
-- could run the platform in March" is a question an access-control table should
-- be able to answer. A deleted row answers nothing, and access history is
-- exactly the kind of record you want when somebody asks later who had the keys.
--
-- WHY PLATFORM EVENTS DO NOT GO IN admin_audit. That table is a MASJID's audit
-- trail — masjid_id is NOT NULL, and rightly so. Who runs MasjidOne is the
-- supplier's own business and has no place in a customer's record; writing it
-- there would be both a schema lie and a disclosure. Hence platform_audit.

alter table public.platform_admins
  add column if not exists revoked_at timestamptz,
  add column if not exists revoked_by uuid;
comment on column public.platform_admins.revoked_at is
  'When this account stopped being able to run MasjidOne. Null means active. The row is kept so the history of who held the keys survives.';

create table if not exists public.platform_audit (
  id      bigserial primary key,
  at      timestamptz not null default now(),
  actor   uuid,
  action  text not null,
  detail  jsonb not null default '{}'::jsonb
);
alter table public.platform_audit enable row level security;
revoke all on public.platform_audit from public, anon, authenticated;
comment on table public.platform_audit is
  'MasjidOne''s own events — who may run the platform. Deliberately NOT admin_audit, which is a masjid''s record and has no business holding the supplier''s.';

-- ---------------------------------------------------------------------------
/* THE GATE. One conjunct added: a retired row grants nothing.
   With no retired rows this is behaviourally identical to what it replaces,
   which is what makes it safe to apply before any handover happens. */
create or replace function public.is_platform_admin()
returns boolean
language sql stable security definer
set search_path to 'public', 'pg_temp'
as $$
  select public.is_aal2()
     and exists (select 1 from public.platform_admins p
                  where p.user_id = auth.uid() and p.revoked_at is null);
$$;

/* Can this account actually be a platform administrator? Separated out because
   both functions below need the same answer, and a second copy of this rule is
   a second chance to get it wrong. */
create or replace function public.can_be_platform_admin(p_user uuid)
returns boolean
language sql stable security definer
set search_path to 'public', 'pg_temp', 'auth'
as $$
  select exists (select 1 from auth.mfa_factors f
                  where f.user_id = p_user and f.status = 'verified');
$$;

-- ---------------------------------------------------------------------------
create or replace function public.platform_admin_add(p_email text)
returns jsonb
language plpgsql security definer
set search_path to 'public', 'pg_temp', 'auth'
as $$
declare v_uid uuid; v_email text := lower(btrim(coalesce(p_email,''))); v_roles text; v_back boolean := false;
begin
  if not public.is_platform_admin() then
    raise exception 'Only MasjidOne support, with two-step completed, may add a platform administrator.'
      using errcode = '42501';
  end if;

  select id into v_uid from auth.users where lower(email) = v_email;
  if v_uid is null then
    raise exception 'There is no account for %. Create it and sign in once before adding it here.', v_email
      using errcode = '22023';
  end if;

  if exists (select 1 from public.platform_admins
              where user_id = v_uid and revoked_at is null) then
    raise exception '% is already a platform administrator.', v_email using errcode = '23505';
  end if;

  /* The one-hat rule from 137. The trigger would refuse an insert too; saying
     it here means the person gets the reason rather than a trigger's shout. */
  select string_agg(distinct m.slug, ', ') into v_roles
    from public.user_roles r join public.masjids m on m.id = r.masjid_id
   where r.user_id = v_uid;
  if v_roles is not null then
    raise exception 'That account holds a role at %, so it cannot also run MasjidOne. Support access already reaches every masjid without one — use a separate account.', v_roles
      using errcode = '42501';
  end if;

  /* THE RAIL THAT MATTERS. Without a verified second factor this row grants
     nothing, and adding it would look like a successful handover right up
     until the old account is retired. */
  if not public.can_be_platform_admin(v_uid) then
    raise exception 'Two-step is not set up on %, so a platform_admins row would grant it nothing — is_platform_admin() requires aal2. Sign in as that account, enrol two-step, then add it.', v_email
      using errcode = '22023';
  end if;

  /* Somebody retired can come back, and the row they already have is theirs —
     user_id is the key, so a second insert would collide. */
  update public.platform_admins
     set revoked_at = null, revoked_by = null, added_at = now()
   where user_id = v_uid and revoked_at is not null;
  if found then
    v_back := true;
  else
    insert into public.platform_admins (user_id) values (v_uid);
  end if;

  insert into public.platform_audit (actor, action, detail)
  values (auth.uid(), 'platform_admin_added',
          jsonb_build_object('email', v_email, 'user_id', v_uid, 'reinstated', v_back));

  return jsonb_build_object('email', v_email, 'added', true, 'reinstated', v_back,
    'platform_admins', (select count(*) from public.platform_admins where revoked_at is null));
end $$;

-- ---------------------------------------------------------------------------
create or replace function public.platform_admin_remove(p_email text)
returns jsonb
language plpgsql security definer
set search_path to 'public', 'pg_temp', 'auth'
as $$
declare v_uid uuid; v_email text := lower(btrim(coalesce(p_email,''))); v_left int;
begin
  if not public.is_platform_admin() then
    raise exception 'Only MasjidOne support, with two-step completed, may retire a platform administrator.'
      using errcode = '42501';
  end if;

  select id into v_uid from auth.users where lower(email) = v_email;
  if v_uid is null or not exists (select 1 from public.platform_admins
                                   where user_id = v_uid and revoked_at is null) then
    raise exception '% is not a platform administrator.', v_email using errcode = '22023';
  end if;

  /* Count who would be LEFT AND ABLE. Not "how many rows remain" — a row
     without two-step is not a way back in, so counting rows would happily
     leave the company locked out and report success. */
  select count(*) into v_left
    from public.platform_admins p
   where p.user_id <> v_uid and p.revoked_at is null
     and public.can_be_platform_admin(p.user_id);

  if v_left = 0 then
    raise exception 'That would leave nobody able to run MasjidOne. Add another account with two-step enrolled first, and confirm it works.'
      using errcode = '42501';
  end if;

  update public.platform_admins
     set revoked_at = now(), revoked_by = auth.uid()
   where user_id = v_uid and revoked_at is null;

  insert into public.platform_audit (actor, action, detail)
  values (auth.uid(), 'platform_admin_removed',
          jsonb_build_object('email', v_email, 'user_id', v_uid, 'left_able', v_left));

  return jsonb_build_object('email', v_email, 'removed', true, 'still_able', v_left);
end $$;

-- ---------------------------------------------------------------------------
/* Who runs MasjidOne, whether each of them actually can, and who used to. */
create or replace function public.platform_admins_list()
returns jsonb
language plpgsql stable security definer
set search_path to 'public', 'pg_temp', 'auth'
as $$
declare v jsonb; v_former jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Only MasjidOne support may read this.' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'email', u.email,
           'user_id', p.user_id,
           'two_step', public.can_be_platform_admin(p.user_id),
           'is_you', p.user_id = auth.uid(),
           'since', p.added_at,
           'roles_at_masajid', (select coalesce(jsonb_agg(jsonb_build_object(
                                  'masjid', m.slug, 'role', r.role) order by m.slug), '[]'::jsonb)
                                  from public.user_roles r
                                  join public.masjids m on m.id = r.masjid_id
                                 where r.user_id = p.user_id))
         order by u.email), '[]'::jsonb)
    into v
  from public.platform_admins p left join auth.users u on u.id = p.user_id
  where p.revoked_at is null;

  select coalesce(jsonb_agg(jsonb_build_object(
           'email', u.email, 'retired_at', p.revoked_at) order by p.revoked_at desc), '[]'::jsonb)
    into v_former
  from public.platform_admins p left join auth.users u on u.id = p.user_id
  where p.revoked_at is not null;

  return jsonb_build_object('as_of', now(), 'admins', v, 'former', v_former,
    'able', (select count(*) from public.platform_admins p
              where p.revoked_at is null and public.can_be_platform_admin(p.user_id)));
end $$;

grant execute on function public.platform_admin_add(text)    to authenticated;
grant execute on function public.platform_admin_remove(text) to authenticated;
grant execute on function public.platform_admins_list()      to authenticated;
revoke all on function public.can_be_platform_admin(uuid)    from public, anon, authenticated;
revoke all on function public.platform_admin_add(text)       from public, anon;
revoke all on function public.platform_admin_remove(text)    from public, anon;
revoke all on function public.platform_admins_list()         from public, anon;

-- ---------------------------------------------------------------------------
/* 137's rule, now aware that a retired administrator is not an administrator.
 *
 * This matters for the handover it exists to support. Once the founder's old
 * account is retired from MasjidOne, it is just a person at a masjid again —
 * and Taiyabah must be able to give it another role without the platform
 * refusing on the strength of a row that no longer grants anything. Without
 * this, retiring somebody would quietly freeze their roles at every masjid
 * for ever.
 */
create or replace function public.one_hat_each()
returns trigger
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_email text; v_slug text;
begin
  if tg_table_name = 'platform_admins' then
    if new.revoked_at is not null then
      return new;                      -- retiring somebody is always allowed
    end if;
    select u.email into v_email from auth.users u where u.id = new.user_id;
    if exists (select 1 from public.user_roles r where r.user_id = new.user_id) then
      select string_agg(distinct m.slug, ', ') into v_slug
        from public.user_roles r join public.masjids m on m.id = r.masjid_id
       where r.user_id = new.user_id;
      raise exception
        'That account holds a role at % , so it cannot also be a MasjidOne platform administrator. Use a separate MasjidOne account: support access already reaches every masjid, and keeping them apart is what keeps masjidone_support_access in the customer''s audit trail. (%)',
        v_slug, coalesce(v_email, new.user_id::text)
        using errcode = '42501';
    end if;
    return new;
  end if;

  if exists (select 1 from public.platform_admins p
              where p.user_id = new.user_id and p.revoked_at is null) then
    select u.email into v_email from auth.users u where u.id = new.user_id;
    select m.slug into v_slug from public.masjids m where m.id = new.masjid_id;
    raise exception
      'That account is a MasjidOne platform administrator, so it cannot also hold the % role at %. Platform support already reaches this masjid without a role, and a role here would stop the visit being recorded as support access. Give the person a separate account at the masjid. (%)',
      new.role, v_slug, coalesce(v_email, new.user_id::text)
      using errcode = '42501';
  end if;
  return new;
end $$;
revoke all on function public.one_hat_each() from public, anon, authenticated;

/* Same correction: somebody retired is not wearing two hats. */
create or replace function public.access_separation_report()
returns jsonb
language plpgsql stable security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Only MasjidOne support may read the access separation report.'
      using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'user_id', p.user_id,
           'email',   u.email,
           'roles',   (select jsonb_agg(jsonb_build_object('masjid', m.slug, 'role', r.role)
                                        order by m.slug, r.role)
                         from public.user_roles r
                         join public.masjids m on m.id = r.masjid_id
                        where r.user_id = p.user_id))
         order by u.email), '[]'::jsonb)
    into v_rows
  from public.platform_admins p
  left join auth.users u on u.id = p.user_id
  where p.revoked_at is null
    and exists (select 1 from public.user_roles r where r.user_id = p.user_id);

  return jsonb_build_object(
    'as_of', now(),
    'platform_admins', (select count(*) from public.platform_admins where revoked_at is null),
    'wearing_two_hats', jsonb_array_length(v_rows),
    'detail', v_rows,
    'why', 'A platform administrator who also holds a role at a masjid enters '
        || 'that masjid as one of their own administrators, so the visit is not '
        || 'recorded as masjidone_support_access. Separate the accounts.');
end $$;
grant execute on function public.access_separation_report() to authenticated;
revoke all on function public.access_separation_report() from public, anon;
