/* ---------------------------------------------------------------------------
   Taiyabah Masjid — portal connection settings

   BOTH VALUES BELOW ARE SAFE TO PUBLISH. The anon (publishable) key is
   designed to be visible in the browser; Row Level Security in Postgres is
   what actually protects the data. This key can only do what the policies
   allow — it cannot read a hall booking, a profile or a role without a
   signed-in session that passes those policies.

   NEVER put the service_role / secret key in this file, or anywhere else that
   reaches a browser. It bypasses RLS entirely and would expose every record.
   If GitHub's secret scanning ever blocks a push, do NOT click "Allow secret" —
   cancel, take the key out, and rotate it in Supabase.

   The URL must be the bare project origin. The Supabase dashboard displays it
   with /rest/v1/ on the end; pasting that verbatim has broken this twice.
--------------------------------------------------------------------------- */

window.TAIYABAH_CONFIG = {
  /* WHICH MASJID. The database used to work this out, because there was only
     ever one. From the moment a second masjid exists it refuses to guess, so
     every call that reads or writes this masjid's data has to name it.
     Nothing about Taiyabah changes — this is what keeps it working once it
     has company. */
  MASJID:            "taiyabah",
  SUPABASE_URL:      "https://phenbhmobxwyvdeshvqw.supabase.co",
  SUPABASE_ANON_KEY: "sb_publishable_mOPuQKVP8WCTlBF2Qa1DVw_r_Tra5OO"
};
