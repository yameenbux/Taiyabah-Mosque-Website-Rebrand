/* ---------------------------------------------------------------------------
   Taiyabah Madrasah Portal — connection settings

   Fill in the two values below from:
     Supabase Dashboard -> Project Settings -> API

   BOTH OF THESE ARE SAFE TO PUBLISH. The anon key is designed to be visible
   in the browser; Row Level Security is what actually protects the data.

   NEVER put the service_role key in this file, or anywhere else in /portal/.
   It bypasses RLS entirely and would expose every record to anyone who
   viewed the page source.
--------------------------------------------------------------------------- */

window.TAIYABAH_CONFIG = {
  // e.g. "https://abcdefghijklmnop.supabase.co"
  SUPABASE_URL: "https://phenbhmobxwyvdeshvqw.supabase.co",

  // the "anon" / "publishable" key — long string starting sb_publishable_ or eyJ...
  SUPABASE_ANON_KEY: "sb_publishable_mOPuQKVP8WCTlBF2Qa1DVw_r_Tra5OO",
};
