-- ===========================================================================
--  042_committee_can_attach_a_picture.sql
--  15 September 2026
--
--  The `notices` storage bucket exists, is public, caps uploads at 5 MB and
--  accepts jpeg, png and webp. One picture is in it. And `storage.objects` has
--  RLS on with NOT ONE POLICY, which means nobody can put anything in it
--  through the API at all — the picture that is there was uploaded through the
--  Supabase dashboard, as the service role.
--
--  So the picture field on the notices screen would have been a box asking a
--  volunteer for an "https:// web address", with no way to produce one. The
--  honest options were to remove the field or to make it work. A masjid
--  announces things with posters — Eid times, a fundraising night, a janāzah
--  notice — so it is made to work.
--
--  WHAT THIS GRANTS, EXACTLY
--  -------------------------
--  Writing to ONE bucket, by a verified administrator, and nothing else. Not
--  `authenticated` — a parent with an account on the madrasah portal is
--  `authenticated`. verified_admin(), which is 011's rule and requires
--  two-step, is the same gate as every other write on this project.
--
--  Reading is not granted here and does not need to be: a public bucket is
--  served from /object/public/ without consulting RLS. That is the point of
--  the bucket being public, and it is correct — these are posters meant to be
--  on a public web page.
--
--  WHAT A PUBLIC BUCKET MEANS, SAID PLAINLY
--  ----------------------------------------
--  Anything uploaded here is on the internet, immediately, to anybody with the
--  address, whether or not the notice is ever published. There is no draft
--  state for a file. The editor says so next to the button. Nothing
--  confidential goes in this bucket, and nothing does today: it holds posters.
-- ===========================================================================

begin;

-- ---------------------------------------------------------------------------
--  Writing. Insert, update and delete, all behind the same gate.
--
--  `bucket_id = 'notices'` is load-bearing. Without it these policies apply to
--  every bucket the project ever gains, including ones created later for
--  something private, and the person creating that bucket would have no reason
--  to look in this file.
-- ---------------------------------------------------------------------------
drop policy if exists notices_pictures_insert on storage.objects;
create policy notices_pictures_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'notices' and public.verified_admin());

drop policy if exists notices_pictures_update on storage.objects;
create policy notices_pictures_update on storage.objects
  for update to authenticated
  using      (bucket_id = 'notices' and public.verified_admin())
  with check (bucket_id = 'notices' and public.verified_admin());

--  Deleting matters more than it looks. Without it, every picture ever
--  attached to a notice stays in the bucket for ever, including the four
--  somebody uploaded while getting the crop right.
drop policy if exists notices_pictures_delete on storage.objects;
create policy notices_pictures_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'notices' and public.verified_admin());

--  Listing, so the editor can show what is already there rather than
--  re-uploading the same poster every week.
drop policy if exists notices_pictures_list on storage.objects;
create policy notices_pictures_list on storage.objects
  for select to authenticated
  using (bucket_id = 'notices' and public.verified_admin());

commit;

-- ===========================================================================
--  AFTERWARDS
--
--    select policyname, cmd, roles::text
--      from pg_policies where schemaname = 'storage' and tablename = 'objects';
--
--  Four rows, every one of them naming bucket 'notices'. If a policy appears
--  here that does NOT test bucket_id, it applies to every bucket in the
--  project and wants reading carefully.
--
--  The check that matters, run with an anon key:
--
--    POST /storage/v1/object/notices/probe.jpg   ->  403
--
--  and with a signed-in account that is not a verified administrator, also
--  403. If either succeeds, anybody can put an image on the masjid's front
--  page, and the anon key is in the page source of every page on this site.
-- ===========================================================================
