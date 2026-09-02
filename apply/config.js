/* ---------------------------------------------------------------------------
   Taiyabah Masjid — madrasah application form, connection settings.

   Both values below are safe to publish. The publishable key is designed to be
   visible in a browser; the database decides what it may do. In this case that
   is exactly one thing: call submit_admission_application(). It holds no table
   privileges at all, so it cannot read, change or delete a single application
   even if a policy were written wrongly.

   NEVER put the service_role / secret key in this file. If GitHub's secret
   scanning blocks a push, do NOT click "Allow secret" — cancel, remove the key
   and rotate it in Supabase.

   The URL must be the bare project origin, with no /rest/v1/ on the end.
--------------------------------------------------------------------------- */

window.TAIYABAH_CONFIG = {
  SUPABASE_URL:      "https://phenbhmobxwyvdeshvqw.supabase.co",
  SUPABASE_ANON_KEY: "sb_publishable_mOPuQKVP8WCTlBF2Qa1DVw_r_Tra5OO"
};

/* ---------------------------------------------------------------------------
   ADMISSIONS SETTINGS — the madrasah office edits this block, nothing else.

   Update it once a year. Every date-of-birth window, the academic year and the
   deadline live here so that no year is ever hardcoded into the page itself —
   which is how the old IBEUK form ended up advertising a deadline three months
   after it had passed.
--------------------------------------------------------------------------- */

window.TAIYABAH_ADMISSIONS = {
  academicYear: "2027/2028",
  deadline:     "2027-05-31",

  // dobFrom / dobTo are inclusive. Leave both null where a class has no window.
  classes: [
    { key:"pray_and_play", label:"Pray and Play",              dobFrom:"2023-09-01", dobTo:"2024-08-31" },
    { key:"boys_reception",label:"Boys Reception",             dobFrom:"2022-09-01", dobTo:"2023-08-31" },
    { key:"girls_reception",label:"Girls Reception",           dobFrom:"2022-09-01", dobTo:"2023-08-31" },
    { key:"boys_year1",    label:"Boys Year 1",                dobFrom:"2021-09-01", dobTo:"2022-08-31" },
    { key:"girls_year1",   label:"Girls Year 1",               dobFrom:"2021-09-01", dobTo:"2022-08-31" },
    { key:"hifz_boys",     label:"Hifz — Boys",   dobFrom:null, dobTo:null, note:"Admission is subject to the headteacher's approval." },
    { key:"hifz_girls",    label:"Hifz — Girls",  dobFrom:null, dobTo:null, note:"Admission is subject to the headteacher's approval." },
    { key:"boys_alimiyyah",label:"Boys Alimiyyah",dobFrom:null, dobTo:null },
    { key:"girls_alimah",  label:"Girls Alimah",  dobFrom:null, dobTo:null },
    { key:"boys_nazra",    label:"Boys Nazra — all other classes",  dobFrom:null, dobTo:null, note:"These classes are currently full. Applicants join the waiting list and are contacted when a space comes up." },
    { key:"girls_nazra",   label:"Girls Nazra — all other classes", dobFrom:null, dobTo:null, note:"These classes are currently full. Applicants join the waiting list and are contacted when a space comes up." }
  ]
};
