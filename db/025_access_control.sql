-- ===========================================================================
--  025_access_control.sql — the masjid manages its own staff accounts
--
--  12 September 2026. Planned on 8 September (claude/user-access-screen.md);
--  built now because the admin dashboard put "1 without 2FA" on the front
--  page and there was nowhere to go and fix it.
--
--  THE POINT is to delete the sentence "ring Yameen to add a volunteer" from
--  the masjid's operating procedure, without handing anybody a way to make
--  themselves an administrator.
--
--  THE TRAP THIS MIGRATION IS SHAPED AROUND
--  ----------------------------------------
--  011_require_two_step.sql REFUSES TO RUN while any account holding admin,
--  hall_office or teacher lacks a verified authenticator — deliberately, and
--  it is the rule that makes two-step real. The standing rule is to re-run 011
--  after every migration.
--
--  So a naive invite screen breaks database work outright: invite somebody,
--  grant them hall_office on the spot, they do not enrol for a fortnight, and
--  for that fortnight NOTHING can be migrated. That is not hypothetical — as
--  this was written TWO admin accounts had no authenticator and 011 had been
--  unrunnable for four days.
--
--  The fix falls out of the constraint rather than fighting it:
--
--      AN INVITE RECORDS THE ROLE THAT IS INTENDED.
--      THE ROLE IS NOT GRANTED UNTIL THE PERSON HAS ENROLLED.
--
--  Invites write to pending_access, never to user_roles. claim_pending_access()
--  moves them across on the first visit at aal2. An invite nobody accepts
--  therefore never creates a privileged account, and expires on its own.
--
--  Prerequisites: 011, 024. Idempotent.
--
--  *** STANDING RULE: re-run 011_require_two_step.sql after this. ***
-- ===========================================================================

begin;

do $$
begin
  if to_regprocedure('public.verified_admin()') is null then
    raise exception 'public.verified_admin() does not exist. Run 011_require_two_step.sql first.';
  end if;
end $$;


-- ---------------------------------------------------------------------------
--  1. Invitations
--
--  An invite is an INTENTION, not an entitlement. Nothing in this table
--  grants anybody anything.
-- ---------------------------------------------------------------------------
create table if not exists public.pending_access (
  email        text        primary key,
  roles        app_role[]  not null,
  invited_by   uuid        references auth.users(id),
  invited_at   timestamptz not null default now(),
  expires_at   timestamptz not null default now() + interval '14 days',
  claimed_at   timestamptz,
  note         text
);

do $$
begin
  --  coalesce is load-bearing. array_length('{}'::app_role[], 1) is NULL, not
  --  0, so `>= 1` evaluated to NULL and the CHECK passed — an invite carrying
  --  no roles at all was accepted. Caught by the test, not by reading it. The
  --  same NULL-swallows-the-assertion family that left four SQL suites on this
  --  project silently passing for weeks.
  if not exists (select 1 from pg_constraint where conname = 'pending_roles_not_empty') then
    alter table public.pending_access add constraint pending_roles_not_empty
      check (coalesce(array_length(roles, 1), 0) >= 1);
  end if;
  --  'parent' is granted by the madrasah portal when a family is enrolled, not
  --  by an administrator ticking a box. Letting it be invited here would make
  --  two routes to the same thing, and the other one has the real checks.
  if not exists (select 1 from pg_constraint where conname = 'pending_roles_grantable') then
    alter table public.pending_access add constraint pending_roles_grantable
      check (not ('parent' = any(roles)));
  end if;
end $$;

alter table public.pending_access enable row level security;
drop policy if exists pending_read on public.pending_access;
create policy pending_read on public.pending_access
  for select using (public.verified_admin());

revoke all on public.pending_access from anon;
revoke all on public.pending_access from authenticated;
grant select on public.pending_access to authenticated;

comment on table public.pending_access is
  'Roles INTENDED for somebody invited. Nothing here grants access — see claim_pending_access().';


-- ---------------------------------------------------------------------------
--  2. The floor: never fewer than two administrators
--
--  Deleting the only admin cascades away its roles and profile with no
--  recovery — a hazard already written down on this project, and one nobody
--  discovers until the masjid is locked out of its own database on a Sunday.
--
--  A TRIGGER, not a check in the function that removes roles. A CHECK
--  constraint cannot see other rows, and a rule that lives only in the
--  function it guards is one careless UPDATE away from being gone.
-- ---------------------------------------------------------------------------
create or replace function public.keep_two_admins()
returns trigger
language plpgsql
as $$
declare v_left int;
begin
  if old.role <> 'admin' then
    return old;
  end if;

  select count(*) into v_left from public.user_roles where role = 'admin';

  if v_left <= 2 then
    raise exception
      'The masjid must keep at least two administrators. There are % — add another before removing this one.',
      v_left
      using errcode = 'check_violation';
  end if;

  return old;
end $$;

drop trigger if exists trg_keep_two_admins on public.user_roles;
create trigger trg_keep_two_admins
  before delete on public.user_roles
  for each row execute function public.keep_two_admins();


-- ---------------------------------------------------------------------------
--  3. Who can see the staff list
--
--  Names, email addresses, whether each person has two-step on, and when they
--  last signed in. Administrators only, at aal2.
-- ---------------------------------------------------------------------------
create or replace function public.staff_list()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case when not public.verified_admin() then jsonb_build_object('allowed', false)
  else jsonb_build_object(
    'allowed', true,
    'me', auth.uid(),
    'admins', (select count(*) from public.user_roles where role = 'admin'),
    'people', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id',        p.id,
               'name',      p.full_name,
               'email',     p.email,
               'active',    p.is_active,
               'roles',     coalesce((select array_agg(r.role order by r.role)
                                        from public.user_roles r where r.user_id = p.id),
                                      '{}'::app_role[]),
               'two_step',  exists (select 1 from auth.mfa_factors f
                                     where f.user_id = p.id and f.status = 'verified'),
               'last_in',   (select u.last_sign_in_at from auth.users u where u.id = p.id),
               'is_me',     p.id = auth.uid())
             order by p.full_name nulls last, p.email)
        from public.profiles p
        --  Only people who have, or are meant to have, a staff role. The
        --  shop accounts are customers; listing them on a staff screen
        --  invites somebody to tick a box next to one.
       where exists (select 1 from public.user_roles r
                      where r.user_id = p.id and r.role <> 'parent')
    ), '[]'::jsonb),
    'invites', coalesce((
      select jsonb_agg(jsonb_build_object(
               'email',      i.email,
               'roles',      i.roles,
               'invited_at', i.invited_at,
               'expires_at', i.expires_at,
               'expired',    i.expires_at < now(),
               'by',         (select full_name from public.profiles where id = i.invited_by))
             order by i.invited_at desc)
        from public.pending_access i where i.claimed_at is null
    ), '[]'::jsonb))
  end
$$;

revoke all     on function public.staff_list() from public, anon;
grant  execute on function public.staff_list() to authenticated;


-- ---------------------------------------------------------------------------
--  4. Changing what somebody can do
--
--  NOBODY EDITS THEIR OWN ROLES. Not to escalate, not to remove. It stops
--  accidental self-lockout, and it means every privilege change on this site
--  has a second name against it in the audit trail.
-- ---------------------------------------------------------------------------
create or replace function public.set_person_roles(p_user uuid, p_roles app_role[])
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_before app_role[];
  v_email  text;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator may change what somebody can do.'
      using errcode = '42501';
  end if;

  if p_user = auth.uid() then
    raise exception 'You cannot change your own access. Ask another administrator.'
      using errcode = '42501';
  end if;

  if 'parent' = any(p_roles) then
    raise exception 'The parent role is granted by the madrasah portal, not here.'
      using errcode = 'check_violation';
  end if;

  select email into v_email from public.profiles where id = p_user;
  if v_email is null then
    raise exception 'No such account.' using errcode = 'no_data_found';
  end if;

  select coalesce(array_agg(role order by role), '{}'::app_role[]) into v_before
    from public.user_roles where user_id = p_user and role <> 'parent';

  --  Deleting first lets the two-admin trigger fire on the way past, which is
  --  the whole point of it being a trigger: taking admin away here is refused
  --  by the same rule that refuses it from the SQL editor.
  delete from public.user_roles
   where user_id = p_user and role <> 'parent'
     and not (role = any(p_roles));

  insert into public.user_roles (user_id, role, granted_by)
  select p_user, r, auth.uid()
    from unnest(p_roles) r
   where not exists (select 1 from public.user_roles x
                      where x.user_id = p_user and x.role = r);

  insert into public.admin_audit (actor, action, detail)
  values (auth.uid(), 'roles_changed', jsonb_build_object(
            'target', p_user, 'email', v_email,
            'before', to_jsonb(v_before), 'after', to_jsonb(p_roles)));

  return jsonb_build_object('email', v_email,
                            'before', to_jsonb(v_before), 'after', to_jsonb(p_roles));
end $$;

revoke all     on function public.set_person_roles(uuid, app_role[]) from public, anon;
grant  execute on function public.set_person_roles(uuid, app_role[]) to authenticated;


-- ---------------------------------------------------------------------------
--  5. Suspend, do not delete
--
--  Taking the roles away removes access instantly and keeps the account and
--  its audit trail. A volunteer who leaves and comes back should not mean a
--  hole in the record of who did what.
-- ---------------------------------------------------------------------------
create or replace function public.set_person_active(p_user uuid, p_active boolean)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_email text;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator may suspend an account.' using errcode = '42501';
  end if;
  if p_user = auth.uid() then
    raise exception 'You cannot suspend your own account.' using errcode = '42501';
  end if;

  select email into v_email from public.profiles where id = p_user;
  if v_email is null then
    raise exception 'No such account.' using errcode = 'no_data_found';
  end if;

  --  Suspending takes the roles away, and that passes the two-admin trigger.
  --  Suspending the second-to-last administrator is refused for the same
  --  reason removing their role would be.
  if not p_active then
    delete from public.user_roles where user_id = p_user and role <> 'parent';
  end if;

  update public.profiles set is_active = p_active where id = p_user;

  insert into public.admin_audit (actor, action, detail)
  values (auth.uid(), case when p_active then 'account_restored' else 'account_suspended' end,
          jsonb_build_object('target', p_user, 'email', v_email));

  return jsonb_build_object('email', v_email, 'active', p_active);
end $$;

revoke all     on function public.set_person_active(uuid, boolean) from public, anon;
grant  execute on function public.set_person_active(uuid, boolean) to authenticated;


-- ---------------------------------------------------------------------------
--  6. Recording an invitation
--
--  Called by the Edge Function AFTER it has created the auth account, because
--  creating one needs the service key and that key must never reach a browser.
--  This half is only the intention.
-- ---------------------------------------------------------------------------
create or replace function public.record_invite(p_email text, p_roles app_role[], p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_email text := lower(btrim(p_email));
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator may invite somebody.' using errcode = '42501';
  end if;
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]{2,}$' then
    raise exception 'That does not look like an email address.' using errcode = 'check_violation';
  end if;
  if 'parent' = any(p_roles) then
    raise exception 'The parent role is granted by the madrasah portal, not here.'
      using errcode = 'check_violation';
  end if;

  insert into public.pending_access (email, roles, invited_by, note)
  values (v_email, p_roles, auth.uid(), p_note)
  on conflict (email) do update
    set roles = excluded.roles, invited_by = excluded.invited_by,
        invited_at = now(), expires_at = now() + interval '14 days',
        claimed_at = null, note = excluded.note;

  insert into public.admin_audit (actor, action, detail)
  values (auth.uid(), 'invite_sent', jsonb_build_object(
            'email', v_email, 'roles', to_jsonb(p_roles)));

  return jsonb_build_object('email', v_email, 'roles', to_jsonb(p_roles));
end $$;

revoke all     on function public.record_invite(text, app_role[], text) from public, anon;
grant  execute on function public.record_invite(text, app_role[], text) to authenticated;


-- ---------------------------------------------------------------------------
--  7. Claiming it — the half that keeps 011 runnable
--
--  Called by every portal page on load. If the signed-in person has an invite
--  waiting AND has reached aal2 — which means they have enrolled an
--  authenticator — the roles move across. Until then they have nothing, and
--  011 has nothing to refuse.
--
--  Deliberately callable by any signed-in user: it can only ever grant what an
--  administrator already wrote down for that exact email address, and only
--  once the caller has proved two-step. There is no argument to tamper with.
-- ---------------------------------------------------------------------------
create or replace function public.claim_pending_access()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_email text;
  v_inv   record;
begin
  if auth.uid() is null then
    return jsonb_build_object('claimed', false, 'why', 'not signed in');
  end if;
  if not public.is_aal2() then
    return jsonb_build_object('claimed', false, 'why', 'two-step not completed');
  end if;

  select lower(email) into v_email from auth.users where id = auth.uid();
  if v_email is null then
    return jsonb_build_object('claimed', false, 'why', 'no email');
  end if;

  select * into v_inv from public.pending_access
   where email = v_email and claimed_at is null and expires_at > now();
  if not found then
    return jsonb_build_object('claimed', false, 'why', 'nothing waiting');
  end if;

  insert into public.user_roles (user_id, role, granted_by)
  select auth.uid(), r, v_inv.invited_by
    from unnest(v_inv.roles) r
   where not exists (select 1 from public.user_roles x
                      where x.user_id = auth.uid() and x.role = r);

  update public.pending_access set claimed_at = now() where email = v_email;

  insert into public.admin_audit (actor, action, detail)
  values (auth.uid(), 'invite_accepted', jsonb_build_object(
            'email', v_email, 'roles', to_jsonb(v_inv.roles)));

  return jsonb_build_object('claimed', true, 'roles', to_jsonb(v_inv.roles));
end $$;

grant execute on function public.claim_pending_access() to authenticated;

create or replace function public.cancel_invite(p_email text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator may cancel an invitation.' using errcode = '42501';
  end if;
  delete from public.pending_access where email = lower(btrim(p_email)) and claimed_at is null;
  insert into public.admin_audit (actor, action, detail)
  values (auth.uid(), 'invite_cancelled', jsonb_build_object('email', lower(btrim(p_email))));
end $$;

revoke all     on function public.cancel_invite(text) from public, anon;
grant  execute on function public.cancel_invite(text) to authenticated;


-- ---------------------------------------------------------------------------
--  8. Expired invitations clear themselves
-- ---------------------------------------------------------------------------
create or replace function public.purge_expired_invites()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_n int;
begin
  delete from public.pending_access
   where claimed_at is null and expires_at < now() - interval '30 days';
  get diagnostics v_n = row_count;
  if v_n > 0 then
    insert into public.admin_audit (action, detail)
    values ('invites_purged', jsonb_build_object('deleted', v_n));
  end if;
  return jsonb_build_object('deleted', v_n);
end $$;

revoke all on function public.purge_expired_invites() from public, anon, authenticated;

commit;

select cron.unschedule('purge-invites')
 where exists (select 1 from cron.job where jobname = 'purge-invites');
select cron.schedule('purge-invites', '35 3 * * *',
                     $$select public.purge_expired_invites()$$);

-- ===========================================================================
--  REMINDER: re-run 011_require_two_step.sql now — and it will only pass once
--  every account holding a staff role has an authenticator. That is the rule
--  this migration is built to protect, not to work around.
--
--  These MUST fail, as an administrator at aal2:
--
--    select public.set_person_roles(auth.uid(), '{admin}'::app_role[]);   -- your own
--    delete from public.user_roles where role = 'admin';                  -- the floor
-- ===========================================================================
