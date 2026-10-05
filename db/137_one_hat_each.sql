-- 137 — one hat each: a platform administrator holds no role at a masjid
--
-- WHY. MasjidOne is a supplier. A masjid is a customer. Today one auth account
-- is both: yameen_bee@hotmail.co.uk is the only row in platform_admins AND
-- holds admin and imam at Taiyabah. That is three hats on one login, and it
-- quietly defeats the one control that makes supplier access accountable.
--
-- Look at what set_current_masjid() already does:
--
--     if v_staff and not v_member then
--       insert into admin_audit ... 'masjidone_support_access'
--
-- Support access IS audited — UNLESS you also hold a role there. So an account
-- wearing both hats enters a customer's database and leaves no trace, and the
-- console says so out loud: "this is not support access — you hold a role at
-- Taiyabah Masjid, so you entered as one of their own administrators."
--
-- That is correct behaviour for a committee member. It is the wrong behaviour
-- for the supplier, and the two are indistinguishable while they share a login.
--
-- IT ALSO MAKES THE RELATIONSHIP UNENDABLE. The founder's platform access is
-- permanent — he owns the company. His access to Taiyabah is not: a masjid must
-- be able to remove a person the day he steps back, the way they would remove
-- any other trustee. With one account those are the same act, so neither can
-- happen cleanly. Two accounts make "remove his access" a thing Taiyabah can
-- actually do, and leaves MasjidOne's supplier access exactly where it was,
-- governed by the agreement rather than by a user_roles row.
--
-- WHY A CONSTRAINT RATHER THAN A NOTE. Because the failure is silent and the
-- temptation is practical: it is genuinely convenient to hold a role at a
-- masjid you are supporting. A platform admin does not NEED one — support
-- access already reaches every masjid through set_current_masjid() — so the
-- only thing a role adds is the loss of the audit trail. That is worth refusing
-- rather than documenting.
--
-- WHAT THIS DOES NOT DO: it does not touch existing rows. A trigger fires on
-- what happens next, so nothing breaks on the day it is applied and the
-- current overlap stays visible until it is resolved deliberately. Use
-- access_separation_report() below to see it.

-- ---------------------------------------------------------------------------
create or replace function public.one_hat_each()
returns trigger
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_email text; v_slug text;
begin
  if tg_table_name = 'platform_admins' then
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

  -- user_roles
  if exists (select 1 from public.platform_admins p where p.user_id = new.user_id) then
    select u.email into v_email from auth.users u where u.id = new.user_id;
    select m.slug into v_slug from public.masjids m where m.id = new.masjid_id;
    raise exception
      'That account is a MasjidOne platform administrator, so it cannot also hold the % role at %. Platform support already reaches this masjid without a role, and a role here would stop the visit being recorded as support access. Give the person a separate account at the masjid. (%)',
      new.role, v_slug, coalesce(v_email, new.user_id::text)
      using errcode = '42501';
  end if;
  return new;
end $$;

drop trigger if exists platform_admins_one_hat on public.platform_admins;
create trigger platform_admins_one_hat
  before insert or update of user_id on public.platform_admins
  for each row execute function public.one_hat_each();

drop trigger if exists user_roles_one_hat on public.user_roles;
create trigger user_roles_one_hat
  before insert or update of user_id, masjid_id on public.user_roles
  for each row execute function public.one_hat_each();

-- ---------------------------------------------------------------------------
/* Who is currently wearing more than one hat. Reports rather than fixes: the
   fix needs a second account that only a person can create and sign into, and
   a report that silently repaired this would be moving someone's access
   without them knowing. */
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
  where exists (select 1 from public.user_roles r where r.user_id = p.user_id);

  return jsonb_build_object(
    'as_of', now(),
    'platform_admins', (select count(*) from public.platform_admins),
    'wearing_two_hats', jsonb_array_length(v_rows),
    'detail', v_rows,
    'why', 'A platform administrator who also holds a role at a masjid enters '
        || 'that masjid as one of their own administrators, so the visit is not '
        || 'recorded as masjidone_support_access. Separate the accounts.');
end $$;
revoke all on function public.access_separation_report() from public, anon, authenticated;
grant execute on function public.access_separation_report() to authenticated;
revoke all on function public.one_hat_each() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- HOW TO SEPARATE AN EXISTING ACCOUNT, in the order that cannot lock you out.
--
-- is_platform_admin() requires aal2, so a new account is useless until it has
-- two-step enrolled. Do NOT remove the old platform_admins row first.
--
--   1. Create the new MasjidOne account (a masjidone.co.uk address), sign in,
--      and enrol two-step.
--   2. ADD it, so there are briefly two platform admins and no way to be
--      locked out:
--        insert into public.platform_admins (user_id)
--        select id from auth.users where email = 'you@masjidone.co.uk';
--   3. Sign in as the new account and confirm the support console works.
--   4. ONLY THEN remove the old one:
--        delete from public.platform_admins
--         where user_id = (select id from auth.users
--                           where email = 'old@example.com');
--   5. The old account keeps its roles at the masjid. The masjid can remove
--      them whenever they choose, and nothing about MasjidOne's access changes.
--
-- Step 2 is refused by the trigger above if the new account already holds a
-- role at a masjid — which is the point.
