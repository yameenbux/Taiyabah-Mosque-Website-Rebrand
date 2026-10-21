-- ===========================================================================
--  155_create_teacher_login_is_scoped_to_its_own_masjid.sql
--
--  create_teacher_login() resolved v_masjid by reading it FROM the target
--  staff row:
--
--      select s.masjid_id, ... into v_masjid, v_name
--        from public.madrasah_staff s
--       where s.id = p_staff and s.left_on is null;
--
--  with no check that the target row belongs to the caller's own masjid.
--  create_parent_login() — the function this one otherwise mirrors closely —
--  gets this right: it resolves v_masjid := current_masjid() first, then
--  CONSTRAINS its guardian lookup with "and g.masjid_id = v_masjid". This
--  migration brings create_teacher_login() in line with that pattern.
--
--  Consequence of the bug, confirmed against the live function before this
--  fix: an administrator verified at Masjid A who obtains a madrasah_staff.id
--  belonging to Masjid B (these are ordinary UUIDs — they leak through
--  URLs, other RPC responses, a support ticket, a compromised admin
--  anywhere) could call create_teacher_login(that_id, password) and it
--  would create a live Supabase Auth account, bcrypt the chosen password,
--  grant it 'teacher' at MASJID B, and link it to Masjid B's staff row —
--  logged to Masjid B's own admin_audit, attributing the action to the real
--  caller. Not exploitable while only one masjid exists on this platform;
--  live the moment a second one onboards, which the plans/billing/
--  create_masjid() machinery already elsewhere in this schema exists to do.
--
--  cancel_paid_booking() and record_cash_deposit() were checked at the same
--  time, since an earlier audit pass flagged them alongside this function.
--  Both are NOT affected: the live definition of each already reads
--  "where reference = p_reference and masjid_id = v_masjid" with
--  v_masjid := current_masjid(). That guard is correct and is not visible
--  in the committed db/017_paid_is_booked.sql / db/021_unpaid_is_not_booked.sql
--  text — another instance of a committed migration file drifting from what
--  actually shipped, the same pattern already flagged for site_content
--  (db/150) and admission_applications. Noted here, with nothing to fix,
--  so the next reader does not go looking for a bug that was already closed.
--
--  Fix: resolve v_masjid from current_masjid() before the staff lookup, the
--  same way every other admin-facing create_*_login/add_*/delete_*
--  function in this schema already does, then use it to CONSTRAIN the
--  lookup instead of being read FROM it. A staff id belonging to another
--  masjid now matches no row, which already has a correct, existing error
--  message ("No member of staff with that id is on the books.") — so the
--  caller-visible behaviour for a cross-tenant id is now indistinguishable
--  from a made-up id, which is exactly right.
--
--  The function body below is otherwise byte-for-byte the live definition —
--  diffed against pg_get_functiondef() before writing this file. Only the
--  declaration of v_masjid and the staff lookup's WHERE clause changed.
-- ===========================================================================

begin;

create or replace function public.create_teacher_login(p_staff uuid, p_password text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp, extensions
as $$
declare
  v_masjid uuid := public.current_masjid();
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

  select btrim(concat_ws(' ', s.honorific, s.first_name, s.last_name))
    into v_name
    from public.madrasah_staff s
   where s.id = p_staff and s.masjid_id = v_masjid and s.left_on is null;
  if v_name is null then
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

  --  THE ADDRESS RECEIVES NO MAIL, AND IS ON A SUBDOMAIN THE MASJID OWNS so
  --  that it can never collide with a real mailbox somebody else registers.
  v_email := lower(regexp_replace(
               btrim(concat_ws('.', p_staff::text)), '[^a-z0-9.]', '', 'g'));
  select lower(regexp_replace(
           concat_ws('.', s.first_name, s.last_name), '[^A-Za-z0-9.]', '', 'g'))
    into v_email
    from public.madrasah_staff s where s.id = p_staff;
  --  Two teachers can share a name. The staff id's first block keeps them
  --  apart without putting anything meaningful in the address.
  v_email := v_email || '.' || left(replace(p_staff::text, '-', ''), 4)
          || '@staff.taiyabahmasjid.com';

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at,
    confirmation_token, recovery_token, email_change,
    email_change_token_new, email_change_token_current,
    phone_change, phone_change_token, reauthentication_token)
  values (
    v_uid, '00000000-0000-0000-0000-000000000000', 'authenticated',
    'authenticated', v_email,
    extensions.crypt(p_password, extensions.gen_salt('bf')),
    now(),
    jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
    jsonb_build_object('full_name', v_name),
    now(), now(),
    --  NOT NULL. Supabase's auth service scans these into Go strings and
    --  a NULL fails the scan before the password is ever checked. See the
    --  header of db/094.
    '', '', '', '', '', '', '', '');

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
    set full_name = excluded.full_name,
        must_change_password = true;

  insert into public.user_roles (user_id, role, masjid_id, granted_by)
  values (v_uid, 'teacher', v_masjid, auth.uid())
  on conflict do nothing;

  update public.madrasah_staff set user_id = v_uid where id = p_staff;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'teacher_login_created',
          jsonb_build_object('staff', p_staff, 'classes', v_classes));

  --  The password is NOT returned and NOT stored anywhere in plain text. The
  --  caller knows what they set; this function does not hand it back, so a
  --  later reader of the audit trail cannot recover it.
  return jsonb_build_object('staff', p_staff, 'name', v_name,
                            'username', v_email, 'classes', v_classes);
end $$;

-- ---------------------------------------------------------------------------
--  Proof the tenant-scoping predicate itself is correct, run against two
--  throwaway masjid rows and one throwaway staff row, all three deleted
--  before this migration commits. This checks the exact WHERE clause the
--  fixed function now runs, not a full authenticated end-to-end call —
--  simulating a signed-in session inside a migration would mean fabricating
--  JWT claims current_masjid() reads, which is a separate, larger exercise
--  (the audit that found this bug recommended doing that on a disposable
--  Supabase branch, never against this database).
-- ---------------------------------------------------------------------------

do $check$
declare
  v_masjid_a uuid;
  v_masjid_b uuid;
  v_staff_b  uuid;
  v_visible_from_a boolean;
  v_visible_from_b boolean;
begin
  insert into public.masjids (slug, name, town)
  values ('audit-throwaway-a-' || substr(gen_random_uuid()::text, 1, 8),
          'Audit Throwaway A', 'Nowhere')
  returning id into v_masjid_a;

  insert into public.masjids (slug, name, town)
  values ('audit-throwaway-b-' || substr(gen_random_uuid()::text, 1, 8),
          'Audit Throwaway B', 'Nowhere')
  returning id into v_masjid_b;

  insert into public.madrasah_staff (masjid_id, first_name, last_name)
  values (v_masjid_b, 'Throwaway', 'Teacher')
  returning id into v_staff_b;

  -- The exact predicate create_teacher_login() now runs, as if called by
  -- an admin whose current_masjid() resolved to A, against B's staff id.
  select exists (
    select 1 from public.madrasah_staff s
     where s.id = v_staff_b and s.masjid_id = v_masjid_a and s.left_on is null
  ) into v_visible_from_a;

  -- The same predicate, as if called by an admin of B — the legitimate case.
  select exists (
    select 1 from public.madrasah_staff s
     where s.id = v_staff_b and s.masjid_id = v_masjid_b and s.left_on is null
  ) into v_visible_from_b;

  delete from public.madrasah_staff where id = v_staff_b;
  delete from public.masjids where id in (v_masjid_a, v_masjid_b);

  if v_visible_from_a then
    raise exception 'create_teacher_login fix check FAILED: '
      'a Masjid-B staff row is still reachable when scoped to Masjid A.';
  end if;
  if not v_visible_from_b then
    raise exception 'create_teacher_login fix check FAILED: '
      'a Masjid-B staff row is not reachable even when correctly scoped '
      'to Masjid B — the fix broke the legitimate case.';
  end if;

  raise notice 'create_teacher_login tenant-scoping predicate: PASS '
    '(cross-tenant lookup finds nothing; same-tenant lookup finds the row)';
end $check$;

commit;
