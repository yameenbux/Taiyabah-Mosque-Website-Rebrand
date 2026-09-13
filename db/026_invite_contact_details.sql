-- ===========================================================================
--  026_invite_contact_details.sql
--  Taiyabah Masjid · Bolton Central Islamic Society · charity 1041569
--
--  WHAT THIS ADDS
--  A staff account is now required to carry three things before it is any use
--  to the masjid: a full name, a contact number and an email address. Until
--  now only the email was ever asked for, which is why all three of the
--  current administrators have no phone number on file — nobody can ring the
--  person whose account is stuck, and handover is a guessing game.
--
--  WHY THE PHONE NUMBER IS *NOT* A DELIVERY CHANNEL
--  It was tempting to text the sign-in link. A text message from an unknown
--  number containing a long link to a site you are asked to sign in to is
--  indistinguishable from a phishing text, and sending them teaches masjid
--  staff that such a text is normal. The number is here so somebody can be
--  RUNG, not so a secret can be sent to them. The link goes by email, which
--  at least has SPF and DKIM behind it, or is handed over in person.
--
--  WHY THE COLUMNS ARE NULLABLE AND THE FUNCTION IS STRICT
--  There is one unclaimed invitation on the database from before this
--  migration. Making the columns NOT NULL would mean either destroying it or
--  inventing a phone number for it, and inventing one is worse than admitting
--  the row is incomplete. So:
--      - the columns allow NULL, and the CHECKs only police non-NULL values
--      - record_invite() REFUSES to write a row without both
--      - claim_pending_access() REFUSES to grant roles from an incomplete row
--  The old invitation therefore cannot quietly turn into an administrator. It
--  has to be re-issued through the screen, which asks for everything.
--
--  Nothing here grants anybody anything. Same as 025: an invite is an
--  intention, roles move across only at claim time and only at aal2.
--
--  Apply, then re-run 011_require_two_step.sql. Always.
-- ===========================================================================

begin;

do $$
begin
  --  Checks for the TABLE, not for record_invite(): this migration drops the
  --  old signature of that function, so a guard naming it would refuse to let
  --  the migration run a second time. A migration you cannot re-run is one you
  --  cannot verify.
  if to_regclass('public.pending_access') is null
     or to_regprocedure('public.verified_admin()') is null then
    raise exception 'Run 011_require_two_step.sql and 025_access_control.sql first.';
  end if;
end $$;


-- ---------------------------------------------------------------------------
--  1. The two new columns
--
--  The phone CHECK is deliberately the SAME rule already used on
--  hall_bookings.phone_shape. Two different ideas of what a valid UK number
--  looks like, in one database, is how you end up with a number that passes
--  on one screen and fails on another.
-- ---------------------------------------------------------------------------
alter table public.pending_access add column if not exists full_name text;
alter table public.pending_access add column if not exists phone     text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'pending_name_real') then
    alter table public.pending_access add constraint pending_name_real
      check (full_name is null or length(btrim(full_name)) >= 2);
  end if;

  if not exists (select 1 from pg_constraint where conname = 'pending_phone_shape') then
    alter table public.pending_access add constraint pending_phone_shape
      check (phone is null
             or regexp_replace(phone, '[^0-9]', '', 'g') ~ '^[0-9]{10,13}$');
  end if;
end $$;

comment on column public.pending_access.full_name is
  'Who this is. Written into profiles when the invitation is claimed.';
comment on column public.pending_access.phone is
  'A number to RING them on. Never used to send the sign-in link — see the header of 026.';


-- ---------------------------------------------------------------------------
--  2. Recording an invitation — now needs all three
--
--  Signature changed, so the old one is dropped explicitly. Leaving both
--  would mean the Edge Function could silently keep calling the lax version
--  after a partial deploy, and the rule would exist only on paper.
-- ---------------------------------------------------------------------------
drop function if exists public.record_invite(text, app_role[], text);

create or replace function public.record_invite(
  p_email     text,
  p_full_name text,
  p_phone     text,
  p_roles     app_role[],
  p_note      text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_email text := lower(btrim(p_email));
  v_name  text := btrim(coalesce(p_full_name, ''));
  v_phone text := btrim(coalesce(p_phone, ''));
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator may invite somebody.' using errcode = '42501';
  end if;
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]{2,}$' then
    raise exception 'That does not look like an email address.' using errcode = 'check_violation';
  end if;
  if length(v_name) < 2 then
    raise exception 'Put their full name in. An account nobody can put a name to is no use at handover.'
      using errcode = 'check_violation';
  end if;
  if regexp_replace(v_phone, '[^0-9]', '', 'g') !~ '^[0-9]{10,13}$' then
    raise exception 'That does not look like a phone number. Somebody has to be able to ring them.'
      using errcode = 'check_violation';
  end if;
  if 'parent' = any(p_roles) then
    raise exception 'The parent role is granted by the madrasah portal, not here.'
      using errcode = 'check_violation';
  end if;

  insert into public.pending_access (email, full_name, phone, roles, invited_by, note)
  values (v_email, v_name, v_phone, p_roles, auth.uid(), p_note)
  on conflict (email) do update
    set full_name = excluded.full_name, phone = excluded.phone,
        roles = excluded.roles, invited_by = excluded.invited_by,
        invited_at = now(), expires_at = now() + interval '14 days',
        claimed_at = null, note = excluded.note;

  --  The number is NOT written into the audit detail. admin_audit is read on
  --  a dashboard by every administrator; the roles are the thing that needs a
  --  name against it, the personal number is not.
  insert into public.admin_audit (actor, action, detail)
  values (auth.uid(), 'invite_sent', jsonb_build_object(
            'email', v_email, 'name', v_name, 'roles', to_jsonb(p_roles)));

  return jsonb_build_object('email', v_email, 'name', v_name, 'roles', to_jsonb(p_roles));
end $$;

revoke all     on function public.record_invite(text, text, text, app_role[], text) from public, anon;
grant  execute on function public.record_invite(text, text, text, app_role[], text) to authenticated;


-- ---------------------------------------------------------------------------
--  3. Claiming it — the details come across with the roles
--
--  profiles.full_name is NOT NULL and is filled by the sign-up trigger with
--  whatever the person typed, which for an invited account is nothing useful.
--  This overwrites it with the name the administrator vouched for, and fills
--  in the number.
--
--  The refusal at the top is the other half of the nullable-columns decision
--  above: an invitation written before 026 has no name and no number, and it
--  will not turn into a role.
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

  if coalesce(btrim(v_inv.full_name), '') = '' or coalesce(btrim(v_inv.phone), '') = '' then
    return jsonb_build_object('claimed', false,
      'why', 'the invitation is missing a name or a contact number — ask for a new one');
  end if;

  insert into public.user_roles (user_id, role, granted_by)
  select auth.uid(), r, v_inv.invited_by
    from unnest(v_inv.roles) r
   where not exists (select 1 from public.user_roles x
                      where x.user_id = auth.uid() and x.role = r);

  --  Only fill in what is not already there. The sign-up trigger writes the
  --  EMAIL ADDRESS into full_name when there is no metadata to use, so "is it
  --  blank?" is not enough of a test — an account invited before this change
  --  would keep "someone@gmail.com" as its name forever. A name that is just
  --  the address is treated as absent. A real one the person set themselves
  --  is left alone; the administrator typed a name to identify them by, not
  --  to correct their spelling of it.
  update public.profiles
     set full_name  = case
                        when coalesce(btrim(full_name), '') = ''
                          or lower(btrim(full_name)) = lower(v_email)
                        then v_inv.full_name else full_name end,
         phone      = coalesce(nullif(btrim(phone), ''), v_inv.phone),
         updated_at = now()
   where id = auth.uid();

  update public.pending_access set claimed_at = now() where email = v_email;

  insert into public.admin_audit (actor, action, detail)
  values (auth.uid(), 'invite_accepted', jsonb_build_object(
            'email', v_email, 'roles', to_jsonb(v_inv.roles)));

  return jsonb_build_object('claimed', true, 'roles', to_jsonb(v_inv.roles));
end $$;

--  025 granted this to `authenticated` but never revoked it from PUBLIC, and
--  `create or replace` keeps existing grants — so `anon` could call it. It
--  returns "not signed in" to an anonymous caller and is therefore harmless,
--  but an endpoint being harmless is not a reason to leave it reachable. This
--  was found by reading the grants back off production, not by reading 025.
revoke all     on function public.claim_pending_access() from public, anon;
grant  execute on function public.claim_pending_access() to authenticated;


-- ---------------------------------------------------------------------------
--  4. Filling in what is missing on an account that already exists
--
--  Unlike set_person_roles(), this one DOES let you edit your own. A phone
--  number is a contact detail, not a privilege: there is nothing to escalate
--  and every reason to let somebody correct their own number without having
--  to find another administrator on a Sunday.
--
--  It cannot touch the email address. That is the account's identity in
--  auth.users — changing it here would put profiles and auth out of step and
--  silently break the invite-claim match, which keys on the address.
-- ---------------------------------------------------------------------------
create or replace function public.set_person_contact(
  p_user uuid, p_full_name text, p_phone text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_name  text := btrim(coalesce(p_full_name, ''));
  v_phone text := btrim(coalesce(p_phone, ''));
  v_email text;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator may change somebody''s contact details.'
      using errcode = '42501';
  end if;
  if length(v_name) < 2 then
    raise exception 'Put their full name in.' using errcode = 'check_violation';
  end if;
  if regexp_replace(v_phone, '[^0-9]', '', 'g') !~ '^[0-9]{10,13}$' then
    raise exception 'That does not look like a phone number.' using errcode = 'check_violation';
  end if;

  select email into v_email from public.profiles where id = p_user;
  if v_email is null then
    raise exception 'No such account.' using errcode = 'no_data_found';
  end if;

  update public.profiles
     set full_name = v_name, phone = v_phone, updated_at = now()
   where id = p_user;

  insert into public.admin_audit (actor, action, detail)
  values (auth.uid(), 'contact_updated', jsonb_build_object(
            'target', p_user, 'email', v_email, 'name', v_name));

  return jsonb_build_object('id', p_user, 'name', v_name, 'phone', v_phone);
end $$;

revoke all     on function public.set_person_contact(uuid, text, text) from public, anon;
grant  execute on function public.set_person_contact(uuid, text, text) to authenticated;


-- ---------------------------------------------------------------------------
--  5. The staff list carries the details, and says which are missing
--
--  'needs' is computed here rather than in JavaScript. A screen that works
--  out for itself what counts as incomplete is a second definition of the
--  rule, and the two drift.
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
               'phone',     p.phone,
               'active',    p.is_active,
               'roles',     coalesce((select array_agg(r.role order by r.role)
                                        from public.user_roles r where r.user_id = p.id),
                                      '{}'::app_role[]),
               'two_step',  exists (select 1 from auth.mfa_factors f
                                     where f.user_id = p.id and f.status = 'verified'),
               'last_in',   (select u.last_sign_in_at from auth.users u where u.id = p.id),
               'since',     p.created_at,
               --  What this account is still missing before it is a proper
               --  staff record. Empty array = nothing outstanding.
               'needs',     (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
                               select 'phone'::text as x
                                where coalesce(btrim(p.phone), '') = ''
                               union all
                               select 'email'
                                where coalesce(btrim(p.email), '') = ''
                               union all
                               select 'two_step'
                                where not exists (select 1 from auth.mfa_factors f
                                                   where f.user_id = p.id and f.status = 'verified')
                             ) q),
               'is_me',     p.id = auth.uid())
             order by p.full_name nulls last, p.email)
        from public.profiles p
       where exists (select 1 from public.user_roles r
                      where r.user_id = p.id and r.role <> 'parent')
    ), '[]'::jsonb),
    'invites', coalesce((
      select jsonb_agg(jsonb_build_object(
               'email',      i.email,
               'name',       i.full_name,
               'phone',      i.phone,
               'roles',      i.roles,
               'invited_at', i.invited_at,
               'expires_at', i.expires_at,
               'expired',    i.expires_at < now(),
               --  An invitation written before 026 has no name and no number.
               --  claim_pending_access() will refuse it, so say so on the card
               --  rather than letting somebody wait for it to work.
               'incomplete', coalesce(btrim(i.full_name), '') = ''
                          or coalesce(btrim(i.phone), '') = '',
               'by',         (select full_name from public.profiles where id = i.invited_by))
             order by i.invited_at desc)
        from public.pending_access i where i.claimed_at is null
    ), '[]'::jsonb))
  end
$$;

revoke all     on function public.staff_list() from public, anon;
grant  execute on function public.staff_list() to authenticated;

commit;

-- ===========================================================================
--  REMINDER: re-run 011_require_two_step.sql now.
--
--  These MUST fail, as an administrator at aal2:
--
--    select public.record_invite('a@b.com', 'X', '07700900000',
--                                '{admin}'::app_role[]);        -- name too short
--    select public.record_invite('a@b.com', 'Abu Bakr', '123',
--                                '{admin}'::app_role[]);        -- not a number
--    select public.set_person_contact(auth.uid(), 'Abu Bakr', 'hello');
-- ===========================================================================
