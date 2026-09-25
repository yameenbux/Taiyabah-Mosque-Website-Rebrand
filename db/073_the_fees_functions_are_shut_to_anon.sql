-- ===========================================================================
--  073_the_fees_functions_are_shut_to_anon.sql
--  25 September 2026
--
--  EVERY FEES FUNCTION WAS CALLABLE BY A SIGNED-OUT STRANGER.
--
--  Found by Supabase's own security advisor, minutes after 068-072 were
--  applied to production and after this session had already reported that the
--  gate held. It did not hold in the way that was claimed, and the way the
--  claim was arrived at is the more useful half of this file's story.
--
--  WHAT WAS ACTUALLY WRONG
--
--  Postgres grants EXECUTE on a new function to PUBLIC by default. Forty
--  earlier migrations in this folder know that and write
--
--      revoke all on function public.x(...) from public;
--      grant execute on function public.x(...) to authenticated;
--
--  in that order. 068 to 071 wrote only the grant. So all twenty-six family
--  and fees functions carried PUBLIC's default EXECUTE, which `anon` inherits
--  — while save_madrasah_pupil, delete_madrasah_pupil, save_madrasah_staff
--  and every other madrasah function written before them were properly shut.
--  This is not a house pattern the fees work followed. It is a house pattern
--  the fees work broke, in four files, without noticing.
--
--  WHAT WAS NOT WRONG, AND WHY THAT IS NOT A DEFENCE
--
--  Nothing leaked. Twenty-four of the twenty-six call verified_admin() on
--  their first line and raise 42501 for anybody who is not a signed-in
--  administrator past two-step; the other two are pure text validators that
--  touch no table. A stranger calling madrasah_fee_balances() got an
--  exception, not a list of what every family at the masjid owes.
--
--  But the system is supposed to have two locks on this door and had one.
--  069's own comment admits the weakness of the surviving lock: the checks
--  that assert verified_admin() read a HAND-WRITTEN LIST OF NAMES, and "it
--  cannot catch an omission". The day somebody adds a twenty-seventh fees
--  function and forgets both the check and the list, the privilege grant is
--  what would have stopped them, and it was not there.
--
--  HOW THE WRONG ANSWER WAS REACHED, WHICH IS THE PART WORTH KEEPING
--
--  The verification run before this file existed tried to read the tables and
--  call the functions as `anon`, counted the exceptions, and reported
--  "7 of 7 refused". Every number in it was true and the conclusion drawn
--  from it was false, because it counted TWO DIFFERENT THINGS AS ONE:
--
--      permission denied for function madrasah_fee_balances      (the grant)
--      Only an administrator ... may see what families owe        (the code)
--
--  Both arrive as an exception. Both even carry SQLSTATE 42501, because
--  verified_admin() raises 42501 deliberately to look like what it is. A test
--  that catches `when others` cannot tell the lock from the doorman, and this
--  one did not try. The table half of that run was sound — `revoke all on
--  <table> from anon` is real and the refusals there were real — which is
--  exactly why the result was convincing.
--
--  The rule this file exists to write down: WHEN A CHECK PROVES A NEGATIVE,
--  IT HAS TO NAME THE MECHANISM IT IS PROVING. has_function_privilege() is an
--  answer; "it threw, so we are safe" is a guess that happened to be right.
--
--  Prerequisites: 068-072. Idempotent, and safe to re-run.
-- ===========================================================================

begin;

-- ---------------------------------------------------------------------------
--  1. Shut them
--
--  `from public, anon` and NOT `from authenticated`. The whole fees section
--  is signed-in administrators calling these through PostgREST as the
--  `authenticated` role, so revoking that would take out all eight screens at
--  once and the failure would look like a database outage rather than a
--  permissions change. CHECK 2 below is the guard against exactly that, and
--  it is the half of this file most likely to save somebody.
-- ---------------------------------------------------------------------------
do $shut$
declare
  v_sig text;
begin
  foreach v_sig in array array[
    --  068 — families and who to email
    'public.madrasah_household_list(text)',
    'public.madrasah_household_one(uuid)',
    'public.save_madrasah_household(jsonb)',
    'public.set_pupil_household(uuid, uuid)',
    'public.delete_madrasah_household(uuid)',
    'public.madrasah_pupils_for_family(text, boolean, integer)',
    --  069 — what the madrasah charges
    'public.madrasah_fee_structure()',
    'public.save_madrasah_fee_rate(jsonb)',
    'public.save_madrasah_fee_period(jsonb)',
    'public.save_madrasah_fee_setting(text, jsonb)',
    'public.madrasah_sibling_discount_p(uuid, uuid, integer)',
    'public.madrasah_fee_setting_keys()',
    'public.madrasah_fee_setting_problem(text, text)',
    --  070 — the ledger
    'public.raise_madrasah_charges(uuid)',
    'public.madrasah_fee_balances(boolean, text)',
    'public.madrasah_household_statement(uuid)',
    'public.record_madrasah_payment(jsonb)',
    'public.delete_madrasah_payment(uuid, text)',
    'public.adjust_madrasah_charge(jsonb)',
    'public.cancel_madrasah_charge(uuid, text)',
    'public.add_madrasah_charge(jsonb)',
    --  071 — reminders and reports
    'public.send_madrasah_fee_reminders(uuid[])',
    'public.madrasah_recent_payments(integer, text)',
    'public.madrasah_waivers()',
    'public.madrasah_fees_overview()',
    'public.madrasah_fee_annual_report(date, date)'
  ] loop
    execute format('revoke all on function %s from public, anon', v_sig);
    execute format('grant execute on function %s to authenticated', v_sig);
  end loop;
end $shut$;

commit;

-- ===========================================================================
--  CHECKS
-- ===========================================================================

--  #1  No fees function is reachable by a signed-out stranger.
--
--      THE SET IS COMPUTED, NOT LISTED. Every other check of this kind in
--      068-072 iterates a hand-written array of names and 069 says in terms
--      that such a check "cannot catch an omission". This one asks the
--      catalogue which functions exist, so a twenty-seventh fees function
--      added next year is covered on the day it is created rather than on the
--      day somebody remembers to add it here.
do $c1$
declare v_bad text;
begin
  select string_agg(p.oid::regprocedure::text, ', ' order by p.proname)
    into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and (p.proname like 'madrasah_fee%'      or p.proname like 'madrasah_household%'
       or p.proname like 'madrasah_charge%'   or p.proname like 'madrasah_payment%'
       or p.proname like 'madrasah_waiver%'   or p.proname like 'madrasah_recent_payments'
       or p.proname like 'madrasah_sibling%'  or p.proname like 'madrasah_pupils_for_family'
       or p.proname in ('set_pupil_household', 'raise_madrasah_charges',
                        'send_madrasah_fee_reminders', 'adjust_madrasah_charge',
                        'cancel_madrasah_charge', 'add_madrasah_charge',
                        'record_madrasah_payment', 'delete_madrasah_payment',
                        'delete_madrasah_household', 'save_madrasah_household'))
     and has_function_privilege('anon', p.oid, 'EXECUTE');

  if v_bad is not null then
    raise exception
      'CHECK 1 FAILED: a signed-out stranger may call %. The in-function verified_admin() may still refuse them, but this system is meant to have two locks on the money and would have one.', v_bad;
  end if;
  raise notice 'CHECK 1 passed: no fees or family function is callable by anon.';
end $c1$;

--  #2  THE HONEST HALF, and the one that matters more.
--
--      A revoke that went one role too far would shut the eight fees screens
--      for the people who are supposed to use them, and the symptom — every
--      screen saying it cannot reach the database — reads as an outage rather
--      than as something this file did. CHECK 1 on its own would pass
--      perfectly well in that state, which makes it, alone, the kind of check
--      that cannot fail for the reason that matters.
do $c2$
declare v_shut text; v_n int := 0;
begin
  select string_agg(s, ', '), count(*) into v_shut, v_n from (
    select p.oid::regprocedure::text as s
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('madrasah_household_list','madrasah_household_one',
                         'save_madrasah_household','set_pupil_household',
                         'delete_madrasah_household','madrasah_pupils_for_family',
                         'madrasah_fee_structure','save_madrasah_fee_rate',
                         'save_madrasah_fee_period','save_madrasah_fee_setting',
                         'madrasah_sibling_discount_p','madrasah_fee_setting_keys',
                         'madrasah_fee_setting_problem','raise_madrasah_charges',
                         'madrasah_fee_balances','madrasah_household_statement',
                         'record_madrasah_payment','delete_madrasah_payment',
                         'adjust_madrasah_charge','cancel_madrasah_charge',
                         'add_madrasah_charge','send_madrasah_fee_reminders',
                         'madrasah_recent_payments','madrasah_waivers',
                         'madrasah_fees_overview','madrasah_fee_annual_report')
       and not has_function_privilege('authenticated', p.oid, 'EXECUTE')) t;

  if v_n > 0 then
    raise exception
      'CHECK 2 FAILED: % fees function(s) are no longer callable by a signed-in administrator either — %. Every fees screen would report that it cannot reach the database, and it would look like an outage.', v_n, v_shut;
  end if;
  raise notice 'CHECK 2 passed: all twenty-six are still callable by a signed-in administrator.';
end $c2$;

--  #3  The two functions with no verified_admin() are the two that hold no
--      data, and the check says which they are rather than trusting that the
--      list has not grown.
--
--      madrasah_fee_setting_keys() returns a constant array of setting names.
--      madrasah_fee_setting_problem() is the IMMUTABLE validator 069 pulled
--      out of the setter precisely so that it COULD be called with no auth —
--      that is what makes it testable, and it reads nothing.
do $c3$
declare v_fn text; v_def text; v_line text; v_found boolean; v_bad text := '';
begin
  for v_fn in
    select p.proname
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and (p.proname like 'madrasah_fee%' or p.proname like 'madrasah_household%'
         or p.proname like 'madrasah_waiver%' or p.proname like 'madrasah_sibling%'
         or p.proname like 'madrasah_recent_payments'
         or p.proname in ('raise_madrasah_charges','send_madrasah_fee_reminders',
                          'adjust_madrasah_charge','cancel_madrasah_charge',
                          'add_madrasah_charge','record_madrasah_payment',
                          'delete_madrasah_payment','set_pupil_household',
                          'madrasah_pupils_for_family','save_madrasah_household',
                          'delete_madrasah_household'))
       and p.proname not in ('madrasah_fee_setting_keys', 'madrasah_fee_setting_problem',
                             'reconcile_madrasah_fee_reminders')
  loop
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_fn limit 1;

    v_found := false;
    foreach v_line in array string_to_array(v_def, E'\n') loop
      if btrim(v_line) not like '--%' and v_line like '%public.verified_admin()%' then
        v_found := true; exit;
      end if;
    end loop;
    if not v_found then
      v_bad := v_bad || v_fn || ' ';
    end if;
  end loop;

  if v_bad <> '' then
    raise exception
      'CHECK 3 FAILED: % has no verified_admin() in live code. The grant revoked above is now the only thing between a teacher''s account and the masjid''s money.', v_bad;
  end if;
  raise notice 'CHECK 3 passed: every fees function that touches data checks verified_admin(), and the two that do not hold no data.';
end $c3$;

-- ===========================================================================
--  AFTER APPLYING THIS FILE
--
--  Nothing. It changes no table, no function body and no screen. If the eight
--  fees screens worked before it, they work after it; if CHECK 2 passed, they
--  do.
--
--  Supabase's advisor will still report `rls_enabled_no_policy` for the eight
--  fees tables at INFO. That one is correct and is the house pattern working
--  as designed — forced RLS with no policies means the tables are unreachable
--  and the SECURITY DEFINER functions are the only door. The advisor cannot
--  see the `revoke all ... from anon, authenticated` that does the work.
-- ===========================================================================
