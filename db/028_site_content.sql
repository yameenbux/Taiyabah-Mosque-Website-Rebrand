-- ===========================================================================
--  028_site_content.sql
--  Taiyabah Masjid · Bolton Central Islamic Society · charity 1041569
--
--  WHY THIS EXISTS
--  The new build page is the one part of this website that goes out of date on
--  its own. The appeal figure moves, phases finish, new ones start — and until
--  now every one of those changes needed somebody to edit index_template.html,
--  run build.py and push. That is not a handover; it is a dependency on one
--  person being reachable, and it is exactly the sentence this whole project
--  has been trying to delete.
--
--  THE PERCENTAGE IS NOT STORED. It is computed from raised and target, every
--  time. The template used to carry the figure three times — the words, the
--  bar width, and the ledger row — with a comment warning that they "must not
--  drift". A rule kept by a comment is a rule that gets broken; a number that
--  can only be derived cannot drift from itself.
--
--  MONEY IS PENCE, as integers, like every other amount on this site. £350,000
--  is 35000000. Storing pounds as a decimal here and pence everywhere else is
--  how a £2,500,000 target becomes £25,000 on a bad day.
--
--  WHAT THE PUBLIC PAGE DOES WITH IT
--  The built HTML still carries the last known content, and the page replaces
--  it from here on load IF this answers. So: no JavaScript, or Supabase
--  unreachable, and a visitor still sees the appeal — possibly a version
--  behind, never a blank space where the masjid's fundraising should be.
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


-- ---------------------------------------------------------------------------
--  1. The table
--
--  Keyed by section rather than one table per page. The content portal that
--  is coming will want the same shape for other sections, and a second table
--  with the same three columns is a second set of policies to keep in step.
-- ---------------------------------------------------------------------------
create table if not exists public.site_content (
  key        text primary key,
  body       jsonb       not null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);

comment on table public.site_content is
  'Public page content an administrator can change without a deploy. Readable by anybody.';

alter table public.site_content enable row level security;

--  Readable by ANYBODY, signed in or not. This is the text on a public page:
--  it is already on the internet, and the alternative is the website needing
--  an account to render its own fundraising appeal.
drop policy if exists site_content_read on public.site_content;
create policy site_content_read on public.site_content for select using (true);

--  No write policy at all, and no write grant. Everything goes through
--  set_site_content(), which validates. A table the browser can UPDATE is a
--  table anybody can put anything on the masjid's front page through, because
--  the anon key is in the page source — that is not a hypothetical on this
--  site, it is how the grants on foodbank_volunteers were found to be wrong.
revoke all    on public.site_content from anon;
revoke all    on public.site_content from authenticated;
grant  select on public.site_content to anon, authenticated;


-- ---------------------------------------------------------------------------
--  2. What a valid new build body looks like
--
--  In the database, not in the editor. The editor is the thing being protected
--  from: a check that lives only in JavaScript does not exist, because the
--  anon key is public and anybody can POST straight at PostgREST.
--
--  It is deliberately strict about MONEY and lenient about WORDS. A typo in a
--  sentence is embarrassing and fixable in a minute; a target of zero divides
--  by nothing and puts "Infinity% funded" on a charity's appeal.
-- ---------------------------------------------------------------------------
create or replace function public.check_newbuild(b jsonb)
returns text
language plpgsql
immutable
as $$
declare
  v_item   jsonb;
  v_field  text;
  v_status text;
  v_n      int := 0;
begin
  if b is null or jsonb_typeof(b) <> 'object' then
    return 'The content is missing.';
  end if;

  foreach v_field in array array['tag', 'heading', 'body'] loop
    if coalesce(btrim(b #>> array['appeal', v_field]), '') = '' then
      return 'The appeal needs a ' || v_field || '.';
    end if;
  end loop;

  if jsonb_typeof(b -> 'appeal' -> 'raised_p') <> 'number'
     or jsonb_typeof(b -> 'appeal' -> 'target_p') <> 'number' then
    return 'The raised and target figures must both be numbers.';
  end if;
  if (b -> 'appeal' ->> 'raised_p')::numeric < 0 then
    return 'The amount raised cannot be negative.';
  end if;
  --  Not >= 0. A target of zero would be divided by to draw the bar.
  if (b -> 'appeal' ->> 'target_p')::numeric <= 0 then
    return 'The target must be more than zero.';
  end if;
  --  Raised above target is not refused — an appeal CAN be oversubscribed, and
  --  refusing it would mean the one piece of genuinely good news is the one
  --  thing the screen will not accept. The page caps the bar at 100% instead.

  if jsonb_typeof(b -> 'timeline') <> 'array' then
    return 'The timeline is missing.';
  end if;

  for v_item in select * from jsonb_array_elements(b -> 'timeline') loop
    v_n := v_n + 1;
    if coalesce(btrim(v_item ->> 'date'), '') = ''
       or coalesce(btrim(v_item ->> 'title'), '') = '' then
      return 'Timeline entry ' || v_n || ' needs a date and a title.';
    end if;
    v_status := coalesce(v_item ->> 'status', '');
    if v_status not in ('done', 'active', 'upcoming') then
      return 'Timeline entry ' || v_n || ' must be done, active or upcoming.';
    end if;
  end loop;

  if v_n = 0 then
    return 'The timeline needs at least one entry.';
  end if;

  --  Exactly one current appeal. Two entries marked "Now" is a page that
  --  cannot say what the masjid is raising for, which is the only question
  --  the whole section exists to answer.
  if (select count(*) from jsonb_array_elements(b -> 'timeline') i
       where i ->> 'status' = 'active') <> 1 then
    return 'Exactly one timeline entry must be the current appeal.';
  end if;

  return null;   -- null means fine
end $$;


-- ---------------------------------------------------------------------------
--  3. Writing it
-- ---------------------------------------------------------------------------
create or replace function public.set_site_content(p_key text, p_body jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_key  text := lower(btrim(p_key));
  v_why  text;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator may change what the website says.'
      using errcode = '42501';
  end if;

  if v_key = 'newbuild' then
    v_why := public.check_newbuild(p_body);
    if v_why is not null then
      raise exception '%', v_why using errcode = 'check_violation';
    end if;
  else
    raise exception 'There is no editable section called %.', v_key
      using errcode = 'check_violation';
  end if;

  insert into public.site_content (key, body, updated_by)
  values (v_key, p_body, auth.uid())
  on conflict (key) do update
    set body = excluded.body, updated_at = now(), updated_by = excluded.updated_by;

  --  What changed, not the whole document. A jsonb blob in an audit table is
  --  unreadable on the dashboard and grows without limit.
  insert into public.admin_audit (actor, action, detail)
  values (auth.uid(), 'site_content_changed', jsonb_build_object(
            'key', v_key,
            'raised_p', p_body -> 'appeal' -> 'raised_p',
            'target_p', p_body -> 'appeal' -> 'target_p',
            'phases',   jsonb_array_length(p_body -> 'timeline')));

  return jsonb_build_object('key', v_key, 'updated_at', now());
end $$;

revoke all     on function public.set_site_content(text, jsonb) from public, anon;
grant  execute on function public.set_site_content(text, jsonb) to authenticated;


-- ---------------------------------------------------------------------------
--  4. The seed — what the page says TODAY
--
--  Taken from the built page on 13 September 2026 so the editor opens showing
--  what is live rather than an empty form. Seeded with `on conflict do
--  nothing`: re-running this migration must never overwrite what an
--  administrator has since typed.
-- ---------------------------------------------------------------------------
insert into public.site_content (key, body) values ('newbuild', jsonb_build_object(
  'appeal', jsonb_build_object(
    'tag',      'Current appeal · Phase 3.3',
    'heading',  'Internal fixtures & fittings',
    'body',     'Masjid internal fixtures and fittings — tiling, carpets, heating, electrical works, lighting and décor, completed to a full finish.',
    'raised_p', 35000000,
    'target_p', 250000000,
    'needs',    jsonb_build_array('Tiling','Carpets','Heating','Lighting','Electrical','Decor')),
  'timeline', jsonb_build_array(
    jsonb_build_object('date','2018 – Ramadhan 2019','title','Phase 1','status','done',
      'label','Completed',
      'body','Ground works and superstructure — piling and steel. Funded in full at £800,000, and marked with a site time-lapse shared with the community.'),
    jsonb_build_object('date','From December 2021','title','Phase 2','status','done',
      'label','Completed',
      'body','Watertight and boundary wall, including the domes, windows and doors. Of an anticipated £2,600,000, £2,150,000 had been paid by December 2025, and the remaining £450,000 is in the bank.'),
    jsonb_build_object('date','2022','title','Community fundraiser','status','done',
      'label','Completed',
      'body','A dedicated fundraising campaign held to help carry the build forward.'),
    jsonb_build_object('date','Phases 3.1 & 3.2','title','Madrasah & drainage','status','done',
      'label','Fully funded',
      'body','Classrooms and internal works for the madrasah building at £490,000, and the external drainage installation at £125,000 — both raised in full and in the bank.'),
    jsonb_build_object('date','Now · Phase 3.3','title','Internal fixtures & fittings','status','active',
      'label','Current appeal',
      'body','Tiling, carpets, heating, electrical works, lighting and décor, to a full finish. £350,000 raised of an anticipated £2,500,000 — this is what the masjid is raising for now.'),
    jsonb_build_object('date','What''s next · Phases 3.4, 3.5 & 4','title','Facilities & grounds','status','upcoming',
      'label','Not yet costed',
      'body','Wuḍūʾ khāna, toilets and showers; the jamāʿat kitchen and janāzah khāna; then car parking, landscaping, external lighting, the front and side boundary wall, gates and railings. Costs for these are still to be confirmed.'))
))
on conflict (key) do nothing;

commit;

-- ===========================================================================
--  REMINDER: re-run 011_require_two_step.sql now.
--
--  These MUST fail, as an administrator at aal2:
--
--    select public.set_site_content('newbuild',
--      (select body || '{"appeal":{"target_p":0}}'::jsonb
--         from public.site_content where key='newbuild'));    -- zero target
--    select public.set_site_content('frontpage', '{}'::jsonb); -- no such section
-- ===========================================================================
