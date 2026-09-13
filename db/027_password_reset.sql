-- ===========================================================================
--  027_password_reset.sql
--  Taiyabah Masjid · Bolton Central Islamic Society · charity 1041569
--
--  AN ADMINISTRATOR CAN SEND A RESET LINK. AN ADMINISTRATOR CANNOT SET A
--  PASSWORD.
--
--  That distinction is the whole point of the invite link and it is worth
--  writing down properly, because every system the masjid has used lets an
--  administrator type a password into somebody else's record and it looks
--  like a convenience.
--
--  A password an administrator chose is a password an administrator knows.
--  From that moment every sign-in by that person is deniable — "it must have
--  been you, you had the password" stops being answerable, and on a site that
--  will hold children's records that is not a theoretical problem. So the
--  reset link goes to the person's own email address and nobody else ever
--  sees what they choose.
--
--  Changing your OWN password needs nothing here: Supabase's client does it
--  against the session that is already signed in and already at aal2.
--
--  This function sends nothing and touches no auth table. It exists so the
--  act is RECORDED, as the administrator who did it, before the Edge Function
--  generates a link with the service key.
--
--  Apply, then re-run 011_require_two_step.sql. Always.
-- ===========================================================================

begin;

do $$
begin
  if to_regprocedure('public.verified_admin()') is null then
    raise exception 'public.verified_admin() does not exist. Run 011_require_two_step.sql first.';
  end if;
end $$;

create or replace function public.record_password_reset(p_email text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_email text := lower(btrim(p_email));
  v_id    uuid;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator may send a password reset.'
      using errcode = '42501';
  end if;

  --  It must be somebody the masjid already has an account for. Without this
  --  the endpoint would happily generate a recovery link for any address at
  --  all, which is a way of sending masjid-branded "reset your password" mail
  --  to strangers — from the masjid's own domain, with its SPF and DKIM.
  select id into v_id from public.profiles where lower(email) = v_email;
  if v_id is null then
    raise exception 'No account on this site uses that address.'
      using errcode = 'no_data_found';
  end if;

  insert into public.admin_audit (actor, action, detail)
  values (auth.uid(), 'password_reset_sent',
          jsonb_build_object('target', v_id, 'email', v_email));

  return jsonb_build_object('email', v_email, 'id', v_id);
end $$;

revoke all     on function public.record_password_reset(text) from public, anon;
grant  execute on function public.record_password_reset(text) to authenticated;

commit;

-- ===========================================================================
--  REMINDER: re-run 011_require_two_step.sql now.
--
--  This MUST fail, as an administrator at aal2:
--
--    select public.record_password_reset('nobody@example.com');
-- ===========================================================================
