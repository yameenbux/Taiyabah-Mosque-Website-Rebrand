--  =====================================================================
--  094 - THE LOGINS COULD NEVER HAVE WORKED
--  28 September 2026
--  =====================================================================
--
--  Thirty-nine teacher accounts were created on 27 September, checked
--  thoroughly, and written onto a printed slip ready to hand out. Every
--  one of them was dead.
--
--  create_teacher_login() inserts straight into auth.users. It set the
--  columns that obviously matter - id, email, encrypted_password, aud,
--  role, email_confirmed_at - and left the rest to their defaults. Four
--  of those defaults are NULL:
--
--      confirmation_token
--      recovery_token
--      email_change
--      email_change_token_new
--
--  Supabase's auth service is written in Go and scans that row into a
--  struct whose fields are plain strings, not nullable ones. A NULL in
--  any of them fails the scan. The service never reaches the password
--  check, and what the person sees on the sign-in screen is:
--
--      Database error querying schema
--
--  which names neither the column, nor the row, nor the account. An
--  account created this way looks perfect from inside the database and
--  cannot be signed in to from outside it.
--
--  WHY EVERY CHECK PASSED.
--
--  Last night I verified, as one of these accounts: the role, the staff
--  link, the scoping predicate, the classes returned, the register rows,
--  the medical note reaching the right teacher, and nine separate
--  refusals of data the account must not see. All correct. All still
--  correct.
--
--  Every one of those checks ran INSIDE Postgres, with the account's
--  identity simulated by set_config('request.jwt.claims', ...). Not one
--  of them went near the auth service, because this machine has no
--  network route to it. I even verified the password by comparing it
--  against the stored hash - which proves the hash is right, and proves
--  nothing whatsoever about whether the front door opens.
--
--  I wrote in the go-live checklist that "all 39 show
--  must_change_password, and that figure reads the same whether the
--  accounts work perfectly or do not work at all". That was correct and
--  it was not enough. Knowing a measurement is uninformative is not the
--  same as getting an informative one, and the only informative one here
--  was a person typing a password into the real page. It took ninety
--  seconds and it found what a night of database-side proof could not.
--
--  THE GENERAL SHAPE, worth keeping: when a system has a boundary this
--  session cannot cross, every check on this side of it is evidence
--  about this side only. The checks were not wrong. They were complete
--  about the wrong half.
--
--  ---------------------------------------------------------------------
--  1. THE BACKFILL. Applied ahead of this file, to unblock the accounts
--     immediately; repeated here so the record is complete and so that
--     re-running the file is safe. coalesce to '' is exactly what
--     Supabase's own signup path writes.
--  ---------------------------------------------------------------------
update auth.users u set
  confirmation_token         = coalesce(u.confirmation_token, ''),
  recovery_token             = coalesce(u.recovery_token, ''),
  email_change               = coalesce(u.email_change, ''),
  email_change_token_new     = coalesce(u.email_change_token_new, ''),
  email_change_token_current = coalesce(u.email_change_token_current, ''),
  phone_change               = coalesce(u.phone_change, ''),
  phone_change_token         = coalesce(u.phone_change_token, ''),
  reauthentication_token     = coalesce(u.reauthentication_token, '')
where u.confirmation_token is null
   or u.recovery_token is null
   or u.email_change is null
   or u.email_change_token_new is null
   or u.email_change_token_current is null
   or u.phone_change is null
   or u.phone_change_token is null
   or u.reauthentication_token is null;

--  ---------------------------------------------------------------------
--  2. THE GENERATOR. Patched by reading the live definition and splicing
--     the eight columns into the insert, rather than restating a hundred
--     lines of function here. Restating it would mean this file and the
--     database could disagree, which is the failure db/081 was written
--     about. If the splice matches nothing the file refuses rather than
--     silently leaving the bug in place.
--  ---------------------------------------------------------------------
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'create_teacher_login';

  if v_def is null then
    raise exception 'create_teacher_login() is not there to patch.';
  end if;

  if position('reauthentication_token' in v_def) > 0 then
    raise notice '094: create_teacher_login already patched, leaving it alone.';
    return;
  end if;

  v_new := replace(v_def,
$a$    created_at, updated_at)
  values ($a$,
$b$    created_at, updated_at,
    confirmation_token, recovery_token, email_change,
    email_change_token_new, email_change_token_current,
    phone_change, phone_change_token, reauthentication_token)
  values ($b$);

  if v_new = v_def then
    raise exception '094: the column list did not match. Do not assume the '
                    'patch applied - read create_teacher_login() by hand.';
  end if;

  v_def := v_new;
  v_new := replace(v_def,
$c$    jsonb_build_object('full_name', v_name),
    now(), now());$c$,
$d$    jsonb_build_object('full_name', v_name),
    now(), now(),
    --  NOT NULL. Supabase's auth service scans these into Go strings and
    --  a NULL fails the scan before the password is ever checked. See the
    --  header of db/094.
    '', '', '', '', '', '', '', '');$d$);

  if v_new = v_def then
    raise exception '094: the values list did not match. The function is now '
                    'half-patched in memory and was NOT written. Read it by hand.';
  end if;

  execute v_new;
  raise notice '094: create_teacher_login patched.';
end $mig$;

--  ---------------------------------------------------------------------
--  3. THE CHECK. A guard that fails while any account exists that cannot
--     sign in, so that the next person to create one the wrong way finds
--     out from health_check() rather than from a teacher standing at a
--     screen that says "Database error querying schema".
--
--     This is the check that should have existed yesterday. It could not
--     have caught the original fault by reasoning - it catches it by
--     naming the exact condition the auth service cannot tolerate.
--  ---------------------------------------------------------------------
create or replace function public.auth_rows_readable()
returns jsonb language sql stable security definer
set search_path = public, pg_temp, auth as $$
  select jsonb_build_object(
    'check', 'auth_rows_readable',
    'ok',    count(*) = 0,
    'detail', case when count(*) = 0
      then 'Every account has readable token columns.'
      else count(*) || ' account' || case when count(*) = 1 then '' else 's' end
           || ' cannot be signed in to. A NULL in confirmation_token, '
           || 'recovery_token, email_change or email_change_token_new makes '
           || 'the auth service fail before it checks the password, and the '
           || 'person sees only "Database error querying schema". Fix with '
           || 'the update at the top of db/094.' end)
    from auth.users u
   where u.confirmation_token is null
      or u.recovery_token is null
      or u.email_change is null
      or u.email_change_token_new is null
      or u.email_change_token_current is null
      or u.phone_change is null
      or u.phone_change_token is null
      or u.reauthentication_token is null;
$$;

revoke all on function public.auth_rows_readable() from public, anon;

--  Splice it into health_check() the same way db/081 spliced the notice
--  guard in: read the live definition, add a block, refuse if the anchor
--  is not found.
--
--  I GOT THIS WRONG ONCE, AND THE WAY IT FAILED IS THE POINT. The first
--  attempt anchored on the function CALL and produced
--
--      v_jrow := public.madrasah_notice_matches_schema(), public.auth_rows_readable();
--
--  which is not two checks. It is one assignment with two source columns,
--  and PL/pgSQL rejects it at run time with "assignment source returned 2
--  columns". Both the splice and the migration reported success, because
--  replace() found its anchor and execute() compiled the function -- the
--  fault only appears when the line RUNS.
--
--  What caught it was that health_check's notice block wraps its call in
--  "exception when others", so instead of a silent pass it reported
--
--      notice_matches_the_schema  ok=false
--      the notice check itself failed: assignment source returned 2 columns
--
--  A guard that reports its own breakage is worth more than one that is
--  merely correct, because the way guards actually die is somebody editing
--  around them. The new block below wraps itself the same way.
--
--  The anchor is now the END of the notice block - the array_append line -
--  so the new check is appended as its own block rather than folded into
--  somebody else's assignment.
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'health_check';

  if v_def is null then
    raise exception '094: health_check() is not there to patch.';
  end if;

  --  Undo the bad splice if this file is being run over a database that
  --  already received it.
  v_new := replace(v_def,
    'public.madrasah_notice_matches_schema(), public.auth_rows_readable()',
    'public.madrasah_notice_matches_schema()');
  if v_new <> v_def then
    raise notice '094: removed the earlier bad splice from health_check.';
    v_def := v_new;
    execute v_def;
  end if;

  if position('auth_rows_readable' in v_def) > 0 then
    raise notice '094: health_check already has the auth check.';
    return;
  end if;

  v_new := replace(v_def,
$e$  if not v_ok then v_failing := array_append(v_failing, 'notice_matches_the_schema'); end if;$e$,
$f$  if not v_ok then v_failing := array_append(v_failing, 'notice_matches_the_schema'); end if;

  --  CAN THESE ACCOUNTS ACTUALLY BE SIGNED IN TO? Added by 094, after all
  --  thirty-nine teacher logins turned out to be unusable while every
  --  database-side check on them passed.
  begin
    v_jrow := public.auth_rows_readable();
    v_ok := (v_jrow ->> 'ok')::boolean;
    v_detail := v_jrow ->> 'detail';
  exception when others then
    v_ok := false;
    v_detail := 'the auth row check itself failed: ' || sqlerrm;
  end;
  v_checks := v_checks || jsonb_build_object('check','auth_rows_readable',
                                             'ok',v_ok,'detail',v_detail);
  if not v_ok then v_failing := array_append(v_failing, 'auth_rows_readable'); end if;$f$);

  if v_new = v_def then
    raise exception '094: the anchor at the end of the notice block was not found. '
                    'health_check was NOT changed.';
  end if;

  execute v_new;
  raise notice '094: health_check now includes auth_rows_readable.';
end $mig$;

--  ---------------------------------------------------------------------
--  PROVED, not assumed. With a throwaway auth.users row carrying a NULL
--  confirmation_token:
--
--      before        auth_rows_readable  ok=true
--      with fault    auth_rows_readable  ok=false  "1 account cannot be
--                                                   signed in to..."
--      after         auth_rows_readable  ok=true
--      throwaway rows left behind: 0
--
--  and health_check's only remaining failure is the deliberate one about
--  the four import_ landing tables. A real account was never broken to
--  test this.
--  ---------------------------------------------------------------------

