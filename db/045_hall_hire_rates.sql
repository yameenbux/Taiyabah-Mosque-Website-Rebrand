-- ===========================================================================
--  045_hall_hire_rates.sql
--  15 September 2026
--
--  The hall hire rate card was hard-coded in index_template.html. Changing
--  £350 to £375 meant editing a template, running two Python scripts and
--  pushing to GitHub — so in practice it meant ringing Yameen, and in the
--  meantime the website quoted a price the office had stopped charging. A
--  figure on screen that turns out to be wrong is worse than no figure,
--  because somebody books on the strength of it and then argues about it.
--
--  WHAT IS EDITABLE AND WHAT IS NOT, AND WHY THE LINE IS THERE
--  ----------------------------------------------------------
--  Editable: the note at the top, the rate bands, every line in them, and the
--  booking team's names and numbers.
--
--  NOT editable, and deliberately not merely "not offered" but REFUSED by
--  this function: the £100 deposit.
--
--  The deposit is not a number on a page. It is a Stripe Payment Link, fixed
--  at £100 when it was created, and the amount lives at Stripe rather than
--  here. Let somebody change "£100 deposit" to "£150 deposit" on the website
--  and the button underneath still takes £100 — the site would be lying about
--  money, in the one place where being wrong costs the masjid a dispute with
--  a customer rather than an apology. Changing it for real means creating a
--  new Payment Link, which needs the Stripe account.
--
--  So the deposit paragraph stays in the template, the editor says why in
--  those words, and check_hallhire() rejects a body that so much as mentions
--  a deposit. A boundary that is only in the user interface is a boundary
--  that lasts until somebody calls the function directly.
--
--  The bank details in the balance paragraph are out of scope for the same
--  reason and a stronger one: a sort code and account number on a public web
--  page are what a fraudster edits if they ever get in. Those move when
--  somebody has thought about it properly.
-- ===========================================================================

begin;

-- ---------------------------------------------------------------------------
--  1. What a rate card is allowed to be
--
--  Prices are TEXT, not numbers, and that is a decision rather than
--  laziness: the real card says "£350" on one line and "45p per person" on
--  another, and a numeric column cannot hold the second. The cost of text is
--  that somebody could type "ask in the office", so the rule is that a price
--  has to contain a digit — enough to stop a blank or a shrug, loose enough
--  to hold every shape the masjid actually charges in.
-- ---------------------------------------------------------------------------
create or replace function public.check_hallhire(p jsonb)
returns text
language plpgsql
immutable
set search_path = public, pg_temp
as $fn$
declare
  v_band  jsonb;
  v_line  jsonb;
  v_con   jsonb;
  v_intro text := btrim(coalesce(p->>'intro', ''));
  v_n     int;
  v_lines int;
begin
  if p is null or jsonb_typeof(p) <> 'object' then
    return 'The rate card did not arrive as expected. Reload the page and try again.';
  end if;

  --  THE DEPOSIT IS NOT NEGOTIABLE FROM HERE. Refused rather than ignored:
  --  silently dropping a field somebody deliberately sent is how you get a
  --  screen that appears to have saved something it threw away.
  if p ? 'deposit' or p ? 'deposit_p' or p ? 'bank' then
    return 'The £100 deposit and the bank details cannot be changed from this '
        || 'screen. The deposit is a fixed Stripe payment link — changing the '
        || 'number here would leave the button underneath still taking £100.';
  end if;

  if v_intro = '' then
    return 'The line at the top of the rate card cannot be empty.';
  end if;
  if length(v_intro) > 240 then
    return 'The line at the top is ' || length(v_intro) || ' characters. The limit is 240.';
  end if;

  if jsonb_typeof(p->'bands') <> 'array' then
    return 'The rate card needs at least one group of charges.';
  end if;
  v_n := jsonb_array_length(p->'bands');
  if v_n < 1 or v_n > 6 then
    return 'There are ' || v_n || ' groups of charges. There must be between 1 and 6.';
  end if;

  for v_band in select * from jsonb_array_elements(p->'bands') loop
    if btrim(coalesce(v_band->>'when', '')) = '' then
      return 'Every group needs a heading, like "Monday – Thursday".';
    end if;
    if length(btrim(v_band->>'when')) > 48 then
      return 'The group heading "' || left(btrim(v_band->>'when'), 20)
          || '…" is too long. The limit is 48 characters.';
    end if;
    if length(btrim(coalesce(v_band->>'note', ''))) > 200 then
      return 'The note under "' || btrim(v_band->>'when')
          || '" is too long. The limit is 200 characters.';
    end if;

    if jsonb_typeof(v_band->'lines') <> 'array' then
      return 'The group "' || btrim(v_band->>'when') || '" has no charges in it.';
    end if;
    v_lines := jsonb_array_length(v_band->'lines');
    if v_lines < 1 or v_lines > 10 then
      return 'The group "' || btrim(v_band->>'when') || '" has ' || v_lines
          || ' charges. There must be between 1 and 10.';
    end if;

    for v_line in select * from jsonb_array_elements(v_band->'lines') loop
      if btrim(coalesce(v_line->>'n', '')) = '' then
        return 'Every charge needs a description, like "1 hall".';
      end if;
      if length(btrim(v_line->>'n')) > 70 then
        return 'The charge "' || left(btrim(v_line->>'n'), 24)
            || '…" is too long. The limit is 70 characters.';
      end if;
      if btrim(coalesce(v_line->>'p', '')) = '' then
        return 'The charge "' || btrim(v_line->>'n') || '" has no price against it.';
      end if;
      if length(btrim(v_line->>'p')) > 24 then
        return 'The price for "' || btrim(v_line->>'n')
            || '" is too long. The limit is 24 characters.';
      end if;
      --  A price with no digit in it is not a price. "£350" passes, "45p per
      --  person" passes, "ask in the office" does not — and that last one is
      --  exactly what somebody types when they have not decided yet, which
      --  is the moment the website should not be quoting anything.
      if btrim(v_line->>'p') !~ '[0-9]' then
        return 'The price for "' || btrim(v_line->>'n')
            || '" has no number in it. If the charge depends on the booking, '
            || 'take the line out rather than leaving it vague.';
      end if;
    end loop;
  end loop;

  --  Contacts are optional as a group — the office number is in the markup
  --  regardless — but each one has to be usable if it is there.
  if p ? 'contacts' then
    if jsonb_typeof(p->'contacts') <> 'array' then
      return 'The booking contacts did not arrive as expected.';
    end if;
    if jsonb_array_length(p->'contacts') > 8 then
      return 'There are more than 8 booking contacts. Keep it to the people '
          || 'somebody should actually ring.';
    end if;
    for v_con in select * from jsonb_array_elements(p->'contacts') loop
      if btrim(coalesce(v_con->>'n', '')) = '' then
        return 'Every booking contact needs a name.';
      end if;
      if length(btrim(v_con->>'n')) > 48 then
        return 'The contact name "' || left(btrim(v_con->>'n'), 20)
            || '…" is too long. The limit is 48 characters.';
      end if;
      --  Digits only, and no more than fifteen: that is E.164's ceiling, and
      --  it is what goes inside href="tel:". Spaces are for the version
      --  people read, which is a separate field.
      if btrim(coalesce(v_con->>'tel', '')) !~ '^[0-9]{7,15}$' then
        return 'The number for ' || btrim(v_con->>'n')
            || ' must be 7 to 15 digits with no spaces — that is the part the '
            || 'phone dials. Type the readable version in the box beside it.';
      end if;
      if btrim(coalesce(v_con->>'shown', '')) = ''
         or length(btrim(v_con->>'shown')) > 24 then
        return 'The number shown on the page for ' || btrim(v_con->>'n')
            || ' must be between 1 and 24 characters.';
      end if;
    end loop;
  end if;

  --  A ceiling on the whole thing. Every limit above is per field, and
  --  six bands of ten lines each is a lot of small fields; this is the
  --  backstop that stops the rate card becoming a document.
  if length(p::text) > 8000 then
    return 'The rate card is too big. Shorten the notes, or use fewer groups.';
  end if;

  return null;   -- null means fine
end $fn$;

revoke all on function public.check_hallhire(jsonb) from public, anon;

-- ---------------------------------------------------------------------------
--  2. set_site_content(), taught the second key
--
--  Replaced whole. The audit line was written for `newbuild` and reached into
--  the body for `raised_p`, `target_p` and `phases` — against a rate card
--  every one of those is null, so the dashboard would have shown a change
--  nobody could read. It records something meaningful per key now.
-- ---------------------------------------------------------------------------
create or replace function public.set_site_content(p_key text, p_body jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_key    text := lower(btrim(p_key));
  v_why    text;
  v_detail jsonb;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator may change what the website says.'
      using errcode = '42501';
  end if;

  if v_key = 'newbuild' then
    v_why := public.check_newbuild(p_body);
  elsif v_key = 'hallhire' then
    v_why := public.check_hallhire(p_body);
  else
    raise exception 'There is no editable section called %.', v_key
      using errcode = 'check_violation';
  end if;

  if v_why is not null then
    raise exception '%', v_why using errcode = 'check_violation';
  end if;

  insert into public.site_content (key, body, updated_by)
  values (v_key, p_body, auth.uid())
  on conflict (key) do update
    set body = excluded.body, updated_at = now(), updated_by = excluded.updated_by;

  --  What changed, not the whole document. A jsonb blob in an audit table is
  --  unreadable on the dashboard and grows without limit.
  if v_key = 'newbuild' then
    v_detail := jsonb_build_object(
      'key',      v_key,
      'raised_p', p_body -> 'appeal' -> 'raised_p',
      'target_p', p_body -> 'appeal' -> 'target_p',
      'phases',   jsonb_array_length(p_body -> 'timeline'));
  else
    v_detail := jsonb_build_object(
      'key',    v_key,
      'bands',  jsonb_array_length(p_body -> 'bands'),
      --  The prices themselves, flattened onto one line. This is the only
      --  audit entry on the project that records the VALUES rather than a
      --  count, and it earns it: "somebody changed the rate card" is no use
      --  a month later when a customer is holding a screenshot of a price
      --  the masjid says it never charged.
      'prices', (select string_agg(l->>'n' || ' ' || (l->>'p'), ' · ')
                   from jsonb_array_elements(p_body -> 'bands') b,
                        jsonb_array_elements(b -> 'lines') l));
  end if;

  insert into public.admin_audit (actor, action, detail)
  values (auth.uid(), 'site_content_changed', v_detail);

  return jsonb_build_object('key', v_key, 'updated_at', now());
end $fn$;

revoke all     on function public.set_site_content(text, jsonb) from public, anon;
grant  execute on function public.set_site_content(text, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
--  3. The seed — what the page says TODAY
--
--  Taken from the built page on 15 September 2026, so the editor opens
--  showing what is live rather than an empty form. `on conflict do nothing`:
--  re-running this migration must never overwrite what somebody has since
--  typed.
-- ---------------------------------------------------------------------------
insert into public.site_content (key, body) values ('hallhire', jsonb_build_object(
  'intro', 'Every hall booking includes the kitchen and the cleaning. Hire is for the whole day.',
  'bands', jsonb_build_array(
    jsonb_build_object(
      'when', 'Monday – Thursday', 'note', '',
      'lines', jsonb_build_array(
        jsonb_build_object('n', '1 hall',  'p', '£350'),
        jsonb_build_object('n', '2 halls', 'p', '£500'),
        jsonb_build_object('n', '3 halls', 'p', '£600'))),
    jsonb_build_object(
      'when', 'Friday, Saturday & Sunday',
      'note', 'There is no one-hall rate at the weekend.',
      'lines', jsonb_build_array(
        jsonb_build_object('n', '2 halls', 'p', '£600'),
        jsonb_build_object('n', '3 halls', 'p', '£700'))),
    jsonb_build_object(
      'when', 'Kitchen on its own', 'note', '',
      'lines', jsonb_build_array(
        jsonb_build_object('n', 'Kitchen hire',   'p', '£125'),
        jsonb_build_object('n', 'Utility charge', 'p', '45p per person'))),
    jsonb_build_object(
      'when', 'If they apply', 'note', '',
      'lines', jsonb_build_array(
        jsonb_build_object('n', 'Utensils, only if used', 'p', '£100'),
        jsonb_build_object('n', 'Utility charge, if you cook in the kitchen', 'p', '45p per person'),
        jsonb_build_object('n', 'Damage to the venue', 'p', '£100')))),
  'contacts', jsonb_build_array(
    jsonb_build_object('n', 'Masjid office',      'tel', '01204535997', 'shown', '01204 535 997'),
    jsonb_build_object('n', 'Rafiq I Patel',      'tel', '07951795465', 'shown', '07951 795465'),
    jsonb_build_object('n', 'Mustaq Adam',        'tel', '07909973776', 'shown', '07909 973776'),
    jsonb_build_object('n', 'Alibhai Khotiwala',  'tel', '07729297676', 'shown', '07729 297676'))
))
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
--  4. Prove the validator accepts the seed, and refuses what it claims to
--
--  The seed is the one body guaranteed to be tried the moment somebody opens
--  the screen and presses Save without changing anything, so it is the one
--  case that must not fail. The same DO block pattern as 041 and 043.
-- ---------------------------------------------------------------------------
do $check$
declare
  v_seed jsonb;
  v_why  text;
begin
  select body into v_seed from public.site_content where key = 'hallhire';
  v_why := public.check_hallhire(v_seed);
  if v_why is not null then
    raise exception 'check_hallhire() refuses the seed it was written for: %', v_why;
  end if;

  --  And every refusal has to be real, or the message is decoration.
  if public.check_hallhire(v_seed || jsonb_build_object('deposit', '150')) is null then
    raise exception 'a body carrying a deposit was accepted — the whole point of '
                    'this migration is that the deposit is a Stripe link';
  end if;
  if public.check_hallhire(v_seed || jsonb_build_object('intro', '')) is null then
    raise exception 'an empty intro was accepted'; end if;
  if public.check_hallhire(v_seed || jsonb_build_object('bands', '[]'::jsonb)) is null then
    raise exception 'a rate card with no charges at all was accepted'; end if;
  if public.check_hallhire(v_seed || jsonb_build_object('bands', jsonb_build_array(
       jsonb_build_object('when', 'x', 'lines', jsonb_build_array(
         jsonb_build_object('n', 'A hall', 'p', 'ask in the office')))))) is null then
    raise exception 'a price with no number in it was accepted'; end if;
  if public.check_hallhire(v_seed || jsonb_build_object('contacts', jsonb_build_array(
       jsonb_build_object('n', 'Somebody', 'tel', '01204 535 997', 'shown', 'x')))) is null then
    raise exception 'a tel: number with a space in it was accepted'; end if;

  raise notice 'check_hallhire() accepts the seed and refuses all five bad bodies.';
end $check$;

commit;

-- ===========================================================================
--  AFTERWARDS
--
--    select jsonb_pretty(body) from public.site_content where key = 'hallhire';
--
--  And as anon, which must still work — the website reads this table directly
--  and a rate card nobody can read is a blank panel where the prices were:
--
--    select body from public.site_content where key = 'hallhire';   -- 1 row
--    select public.set_site_content('hallhire', '{}'::jsonb);       -- denied
-- ===========================================================================
