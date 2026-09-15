-- ===========================================================================
--  033_notify_charity_collections.sql — make a collection request email
--  somebody
--
--  *** APPLIED TO PRODUCTION 14 September 2026. ***
--
--  Yameen submitted the first charity collection request through the new form
--  — CC-26-0001 — and no email arrived. The row was written correctly. The
--  portal showed it. Nothing told a human it existed.
--
--  THE FORM WAS BUILT AND THE BELL WAS NEVER WIRED UP.
--
--  030 created the table, the function and the policies. 031 put it on the
--  dashboard. The Edge Function was taught to write the email. Every piece
--  was there except the one that connects a row appearing to a message being
--  sent, and because every individual piece worked when tested on its own,
--  nothing failed loudly enough to notice.
--
--  A nikāḥ request emails the office because of a trigger called
--  notify-nikah on nikah_requests, created in the Supabase dashboard rather
--  than by a migration. So there was no file to copy, no line in this folder
--  to notice was missing, and no test that could have caught it: the gap was
--  the absence of a thing nobody had written down.
--
--  THAT IS THE REAL LESSON HERE, and it is not about charity collections.
--  Anything configured through a dashboard instead of a migration is
--  invisible to this folder, invisible to code review, and invisible to
--  whoever inherits this after Yameen. Both of these triggers now exist only
--  in the database. This file is the closest thing to a record of them that
--  can safely be committed — see below for why it cannot simply contain the
--  trigger definition.
--
--  WHY THIS FILE COPIES A TRIGGER INSTEAD OF WRITING ONE
--  ----------------------------------------------------
--  A Supabase database webhook is an ordinary trigger calling
--  supabase_functions.http_request(url, method, headers, params, timeout).
--  The HEADERS ARGUMENT CONTAINS TWO SECRETS IN PLAIN TEXT: a service_role
--  JWT and the NOTIFY_SECRET. Writing the trigger out by hand means writing
--  those into a file, and this repository is a public GitHub Pages site.
--
--  So the definition is read out of the existing notify-nikah trigger inside
--  the database, has its name and table substituted, and is executed there.
--  The secrets never leave Postgres and never appear in this file, in a
--  terminal, or in anybody's scrollback.
--
--  The side effect is that this is self-correcting: if the NOTIFY_SECRET is
--  ever rotated, whoever rotates it must update notify-nikah, and re-running
--  this file copies the new value across rather than restoring an old one.
--
--  PREREQUISITE: the notify-nikah trigger must already exist on
--  nikah_requests. If it does not, this raises rather than creating a
--  half-configured trigger that posts nowhere.
--
--  CONSEQUENCE. Every INSERT into charity_collections now sends TWO emails:
--  one to MAIL_TO (the office) and one to the address on the form. That is
--  handled by the notify function; see supabase/functions/notify/messages.ts.
--  The trustee's name, number and email are deliberately in neither.
-- ===========================================================================

do $$
declare
  def text;
begin
  select pg_get_triggerdef(oid) into def
    from pg_trigger
   where tgname   = 'notify-nikah'
     and tgrelid  = 'public.nikah_requests'::regclass;

  if def is null then
    raise exception
      'notify-nikah does not exist on nikah_requests, so there is nothing to '
      'copy. Create the nikah database webhook first; a collection trigger '
      'built from guesswork would post to the wrong place or to nowhere.';
  end if;

  -- Only the trigger's own name and the table it hangs off change. The URL,
  -- the headers, the timeout and the secrets are carried across untouched
  -- and unread.
  def := replace(def, 'notify-nikah',          'notify-charity-collection');
  def := replace(def, 'public.nikah_requests', 'public.charity_collections');

  execute def;
end $$;

-- ---------------------------------------------------------------------------
--  PROVING IT WORKS WITHOUT EMAILING ANYBODY
--
--  A trigger that exists is not a trigger that fires. This inserts a row,
--  counts what landed in pg_net's queue, and then deliberately raises so the
--  whole thing rolls back: no row, no reference consumed, no email sent. The
--  numbers come back in the error message.
--
--  Expected: 'delta=1'. A delta of 0 means the trigger is not firing.
--
--  begin;
--  do $probe$
--  declare before_n bigint; after_n bigint;
--  begin
--    select count(*) into before_n from net.http_request_queue;
--    insert into public.charity_collections
--      (reference, requested_date, org_name, org_address, org_phone, org_email,
--       charity_number, collector_name, collector_role, collector_paid,
--       trustee_name, trustee_phone, trustee_email,
--       rules_version, rules_accepted, signed_name, privacy_accepted)
--    values
--      ('CC-TRIGGER-PROBE', current_date + 200, 'Probe (rolled back)',
--       'nowhere', '00000000000', 'probe@example.invalid', null, 'Probe',
--       'volunteer', false, 'Probe Trustee', '00000000000',
--       'probe2@example.invalid', '2026-09-14', true, 'Probe', true);
--    select count(*) into after_n from net.http_request_queue;
--    raise exception 'DELIBERATE ROLLBACK -- before=% after=% delta=%',
--                    before_n, after_n, after_n - before_n;
--  end $probe$;
--
--  Run 14 September 2026: before=0 after=1 delta=1.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
--  SENDING THE EMAIL FOR A REQUEST THAT CAME IN BEFORE THIS FILE EXISTED
--
--  CC-26-0001 was submitted while there was no trigger, so nothing was ever
--  sent for it. A trigger cannot reach backwards. This posts the same payload
--  the trigger would have posted, using the trigger's own URL and headers so
--  the secrets stay inside the database.
--
--  IT SENDS REAL EMAIL. Change the reference before running it, and do not
--  run it twice for the same one.
--
--  with t as (
--    select string_to_array(encode(tgargs,'escape'), '\000') as a
--      from pg_trigger
--     where tgname  = 'notify-charity-collection'
--       and tgrelid = 'public.charity_collections'::regclass)
--  select net.http_post(
--    url     := (select a[1] from t),
--    body    := jsonb_build_object(
--                 'type','INSERT','table','charity_collections',
--                 'schema','public','old_record', null,
--                 'record', (select to_jsonb(cc)
--                              from public.charity_collections cc
--                             where cc.reference = 'CC-26-0001')),
--    headers := (select a[3] from t)::jsonb,
--    timeout_milliseconds := 8000);
--
--  The answer arrives a few seconds later in net._http_response, matched on
--  the id that call returns. Run 14 September 2026 for CC-26-0001:
--      status_code 200, {"ok":true,"note":"office:sent hirer:sent"}
-- ---------------------------------------------------------------------------
