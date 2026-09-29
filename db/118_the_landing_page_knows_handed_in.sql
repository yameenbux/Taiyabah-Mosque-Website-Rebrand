-- ===========================================================================
--  118 - THE TEACHER'S LANDING PAGE CAN TELL "FULLY MARKED" FROM "HANDED IN"
--  29 September 2026
-- ===========================================================================
--  Final whole-branch review, finding I2 (Important).
--
--  madrasah_my_classes() never referenced madrasah_registers and returned no
--  state, so portal/app.js decided a class was finished with
--  `marked >= on_roll`. A teacher who marks all twelve children and presses
--  Save but NOT Hand-in read "every register taken - nothing left to do" on
--  the one page the spec calls "the only channel a teacher has", while the
--  office was emailed about that very class on Monday.
--
--  THE FIX IS ADDITIVE, exactly as db/110 (madrasah_register_list) and
--  db/113 (madrasah_registers_list) did for their callers: a LEFT JOIN on
--  (class_id, on_date), so a class with nothing saved for p_date returns
--  state and submitted_at as null - draft in everything but name. Two new
--  keys on each row; every caller reads rows by named key, so nothing that
--  ignores them changes. portal/app.js is the other half of this change and
--  reads `state === 'submitted'`.
--
--  madrasah_registers is unique on (class_id, on_date) (both write paths
--  upsert on it), so the join cannot multiply a class's row.
--
--  Read-patch-refuse: the anchor is the tail of the rows subquery as
--  db/090 left it and nothing since has touched. SECURITY DEFINER, owner and
--  search_path are not changed; the grant is restated.
-- ===========================================================================

do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'madrasah_my_classes'
     and pg_get_function_identity_arguments(p.oid) = 'p_date date';
  if v_def is null then
    raise exception '118: madrasah_my_classes(date) does not exist. Nothing changed.';
  end if;
  if position('submitted_at' in v_def) > 0 then
    raise notice '118: madrasah_my_classes() already carries register state.';
    return;
  end if;

  v_new := replace(v_def,
$a$as away
      from public.madrasah_classes c
     where c.masjid_id = v_masjid and c.is_active$a$,
$b$as away,
           --  ADDED BY 118. This evening's register for the class - null
           --  when nothing has been saved yet.
           r.state, r.submitted_at
      from public.madrasah_classes c
      left join public.madrasah_registers r
             on r.class_id = c.id and r.on_date = p_date
     where c.masjid_id = v_masjid and c.is_active$b$);

  if v_new = v_def then
    raise exception '118: could not find the rows subquery. NOT changed.';
  end if;
  execute v_new;
end $mig$;

revoke all on function public.madrasah_my_classes(date) from public, anon;
grant execute on function public.madrasah_my_classes(date) to authenticated;
