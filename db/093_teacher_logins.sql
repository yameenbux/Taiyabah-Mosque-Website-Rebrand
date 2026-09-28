--  =====================================================================
--  093 - TEACHER LOGINS
--  27 September 2026
--  =====================================================================
--
--  NOT ONE OF THE FORTY STAFF HAS AN EMAIL ADDRESS. So the invite flow -
--  send a link, let them set their own password - cannot be used for
--  anybody, and the accounts have to be made with an address that receives
--  no mail. That has a consequence worth stating plainly rather than
--  discovering later: THERE IS NO SELF-SERVICE PASSWORD RESET. A teacher who
--  forgets theirs needs an administrator, and that is the price of not having
--  their email address.
--
--  THE INITIAL PASSWORD IS NOT A PASSWORD, IT IS A TICKET. It is handed over
--  on paper, which means it exists in a drawer, in a message, and in whatever
--  the office used to print it. So it is single-use by design:
--  profiles.must_change_password is set, and the portal will not show a
--  teacher anything until they have chosen their own.
--
--  A slip of paper with a permanent password on it is a shared login waiting
--  to happen, and a shared login destroys both the audit trail and the
--  scoping at once - the two things db/090 exists to provide.
--
--  THE SHAPE WAS COPIED FROM THE ACCOUNTS THAT ALREADY WORK, not guessed:
--  auth.users with instance_id all zeros, aud and role 'authenticated', a
--  bcrypt password, email_confirmed_at set (there is no mailbox to confirm
--  from), provider 'email'; and one auth.identities row per user with
--  identity_data carrying sub, email, email_verified, phone_verified and
--  full_name. Checked against the live administrator accounts first.
--
--  WHAT COULD NOT BE PROVED FROM HERE. The container has no route to
--  supabase.co, so no sign-in was ever performed. The stored hash was
--  verified against the printed password with crypt(), the role, the staff
--  link and the scoping were all exercised as the real account - but nobody
--  has signed in over HTTP. THE FIRST THING THE MASJID SHOULD DO IS SIGN IN
--  AS ONE OF THESE, before handing any of them out.

alter table public.profiles
  add column if not exists must_change_password boolean not null default false;

comment on column public.profiles.must_change_password is
  'Set when an account is created with an initial password somebody else chose. The portal refuses to show anything until it is cleared.';

--  Built as a function rather than 39 hand-written INSERTs so the shape is
--  decided once. It refuses to run twice for the same member of staff, and
--  refuses to make an account for somebody who teaches nothing: a login that
--  can see no classes teaches its owner that the system is broken.
create or replace function public.create_teacher_login(
  p_staff uuid, p_password text)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp, extensions as $$
declare
  v_masjid uuid;
  v_uid uuid := gen_random_uuid();
  v_name text;
  v_email text;
  v_classes int;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may '
                    'create a login.' using errcode = '42501';
  end if;
  if length(coalesce(p_password, '')) < 12 then
    raise exception 'An initial password must be at least 12 characters.'
      using errcode = '22023';
  end if;

  select s.masjid_id,
         btrim(concat_ws(' ', s.honorific, s.first_name, s.last_name))
    into v_masjid, v_name
    from public.madrasah_staff s
   where s.id = p_staff and s.left_on is null;
  if v_masjid is null then
    raise exception 'No member of staff with that id is on the books.'
      using errcode = '22023';
  end if;

  if exists (select 1 from public.madrasah_staff s
              where s.id = p_staff and s.user_id is not null) then
    raise exception '% already has a login.', v_name using errcode = '23505';
  end if;

  select count(*) into v_classes
    from public.madrasah_classes c
   where c.is_active
     and (c.main_teacher_id = p_staff
       or exists (select 1 from public.madrasah_staff_classes sc
                   where sc.staff_id = p_staff and sc.class_id = c.id));
  if v_classes = 0 then
    raise exception '% does not teach an active class, so a login would show '
                    'them nothing. Put them against a class first.', v_name
      using errcode = '22023';
  end if;

  --  THE ADDRESS RECEIVES NO MAIL, and sits on a subdomain the masjid owns so
  --  it can never collide with a real mailbox somebody else registers. Two
  --  teachers can share a name, so the staff id's first block keeps them
  --  apart without putting anything meaningful in the address.
  select lower(regexp_replace(
           concat_ws('.', s.first_name, s.last_name), '[^A-Za-z0-9.]', '', 'g'))
    into v_email
    from public.madrasah_staff s where s.id = p_staff;
  v_email := v_email || '.' || left(replace(p_staff::text, '-', ''), 4)
          || '@staff.taiyabahmasjid.com';

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at)
  values (
    v_uid, '00000000-0000-0000-0000-000000000000', 'authenticated',
    'authenticated', v_email,
    extensions.crypt(p_password, extensions.gen_salt('bf')),
    now(),
    jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
    jsonb_build_object('full_name', v_name),
    now(), now());

  insert into auth.identities (
    id, user_id, provider_id, provider, identity_data,
    last_sign_in_at, created_at, updated_at)
  values (
    gen_random_uuid(), v_uid, v_uid::text, 'email',
    jsonb_build_object('sub', v_uid::text, 'email', v_email,
                       'email_verified', true, 'phone_verified', false,
                       'full_name', v_name),
    null, now(), now());

  insert into public.profiles (id, full_name, email, must_change_password)
  values (v_uid, v_name, v_email, true)
  on conflict (id) do update
    set full_name = excluded.full_name, must_change_password = true;

  insert into public.user_roles (user_id, role, masjid_id, granted_by)
  values (v_uid, 'teacher', v_masjid, auth.uid())
  on conflict do nothing;

  update public.madrasah_staff set user_id = v_uid where id = p_staff;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'teacher_login_created',
          jsonb_build_object('staff', p_staff, 'classes', v_classes));

  --  The password is NOT returned and NOT stored in plain text. The caller
  --  knows what they set; this function does not hand it back, so a later
  --  reader of the audit trail cannot recover it.
  return jsonb_build_object('staff', p_staff, 'name', v_name,
                            'username', v_email, 'classes', v_classes);
end $$;

revoke all on function public.create_teacher_login(uuid, text) from public, anon;
grant execute on function public.create_teacher_login(uuid, text) to authenticated;

create or replace function public.clear_must_change_password()
returns void language sql security definer
set search_path = public, pg_temp as $$
  update public.profiles set must_change_password = false where id = auth.uid();
$$;

revoke all on function public.clear_must_change_password() from public, anon;
grant execute on function public.clear_must_change_password() to authenticated;

create or replace function public.must_change_password()
returns boolean language sql stable security definer
set search_path = public, pg_temp as $$
  select coalesce((select p.must_change_password from public.profiles p
                    where p.id = auth.uid()), false);
$$;

revoke all on function public.must_change_password() from public, anon;
grant execute on function public.must_change_password() to authenticated;

--  APPLIED 27 September 2026: 39 logins created, one per member of staff who
--  teaches an active class, covering 70 classes. The fortieth teaches nothing
--  and was deliberately skipped. The plaintext passwords were written to a
--  printable slip sheet, handed to the masjid once, and the table holding
--  them was dropped in the same session.
