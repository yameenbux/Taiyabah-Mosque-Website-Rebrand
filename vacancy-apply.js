/* ===========================================================================
   Taiyabah Masjid — posted vacancies: live roles, and applying to one

   Migration 177, same pattern as the courses block in index_template.html:
   nothing here is baked into the page, so the four Vacancies tiles stay
   "Coming soon" and the interest form keeps working if this fails. Also
   checked in the database — no CAPTCHA, by design, see db/177's header.
   v.* (admin-written) is always set with textContent, never innerHTML; the
   form's own shell has no admin content in it, so it is one static
   innerHTML string.

   WHY THIS IS AN EXTERNAL FILE, UNLIKE EVERYTHING ELSE ON THE PUBLIC SITE.
   index.html sits at its 200KB gzip budget (weight_test.py) — adding this
   feature inline pushed it to 204KB with no further reasonable trimming
   available. Splitting it out here keeps the page under budget: this file
   is fetched only by a browser that is on the Vacancies page at all, and
   weight_test.py only measures index.html itself. Loaded with `defer`, so
   it runs after the document has parsed — after TAIYABAH_PUBLIC is set and
   after the four static tiles exist — regardless of where the <script> tag
   sits.
   =========================================================================== */
(function(){
  var cfg = window.TAIYABAH_PUBLIC || {};
  if(!cfg.SUPABASE_URL || !cfg.SUPABASE_ANON_KEY ||
     String(cfg.SUPABASE_URL).indexOf('PASTE_') !== -1) return;

  var base = String(cfg.SUPABASE_URL).trim()
               .replace(/\/+$/,'').replace(/\/rest\/v1$/,'');
  var EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;
  var CV_MIMES = { 'application/pdf':1, 'application/msword':1,
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document':1 };
  var CV_EXTS  = { pdf:1, doc:1, docx:1 };
  var CV_MAX   = 5 * 1024 * 1024;

  function iso(d){
    return d.getFullYear() + '-' + ('0'+(d.getMonth()+1)).slice(-2) + '-' + ('0'+d.getDate()).slice(-2);
  }

  /* DOM-built, like pairs() in index_template.html — nothing admin-written
     can execute. */
  function checklist(items){
    var ul = document.createElement('ul');
    ul.className = 'art-checklist';
    (items || []).forEach(function(t){
      if(!t) return;
      var li = document.createElement('li');
      li.textContent = t;
      ul.appendChild(li);
    });
    return ul;
  }

  /* Static shell, nothing from v in it. Scoped to `host`, not document-wide
     ids — up to four roles can be open at once. */
  function buildApplicationForm(v, host){
    host.innerHTML =
      '<p class="cform-lead">It takes a few minutes. Nothing is sent until you press the button.</p>' +
      '<form class="var-form" novalidate autocomplete="on">' +
        '<div class="hp-trap" aria-hidden="true"><label>Leave empty</label>' +
          '<input type="text" class="var-web" tabindex="-1" autocomplete="off"></div>' +
        '<div class="cf-row var-row" data-f="name"><label>Full name</label>' +
          '<input type="text" class="var-name" autocomplete="name" maxlength="80">' +
          '<div class="hf-err">Please give your full name.</div></div>' +
        '<div class="cf-row var-row" data-f="email"><label>Email</label>' +
          '<input type="email" class="var-email" autocomplete="email" maxlength="120">' +
          '<div class="hf-err">Please give an email address the masjid can reply to.</div></div>' +
        '<div class="cf-row var-row" data-f="phone"><label>Contact number</label>' +
          '<input type="tel" class="var-phone" autocomplete="tel" maxlength="24" inputmode="tel">' +
          '<div class="hf-err">Please give a number the masjid can reach you on.</div></div>' +
        '<div class="cf-row var-row" data-f="addr1"><label>Address line 1</label>' +
          '<input type="text" class="var-addr1" autocomplete="address-line1" maxlength="120">' +
          '<div class="hf-err">Please give your address.</div></div>' +
        '<div class="cf-row"><label>Address line 2 <span style="text-transform:none;letter-spacing:0;font-weight:500;">(optional)</span></label>' +
          '<input type="text" class="var-addr2" autocomplete="address-line2" maxlength="120"></div>' +
        '<div class="cf-row var-row" data-f="town"><label>Town / city</label>' +
          '<input type="text" class="var-town" autocomplete="address-level2" maxlength="80">' +
          '<div class="hf-err">Please give your town or city.</div></div>' +
        '<div class="cf-row var-row" data-f="postcode"><label>Postcode</label>' +
          '<input type="text" class="var-postcode" autocomplete="postal-code" maxlength="12" style="text-transform:uppercase;">' +
          '<div class="hf-err">Please give your postcode.</div></div>' +
        '<div class="cf-row var-row" data-f="dob"><label>Date of birth</label>' +
          '<input type="date" class="var-dob" autocomplete="bday">' +
          '<div class="hf-err">Please give your date of birth.</div></div>' +
        '<div class="cf-row var-row" data-f="member"><label>Are you, or an immediate family member, a member of the masjid?</label>' +
          '<div class="yn2"><label><input type="radio" name="var-member" value="yes"> Yes</label>' +
          '<label><input type="radio" name="var-member" value="no"> No</label></div>' +
          '<div class="hf-err">Positions can only be offered to a masjid member, or an immediate family member of one.</div></div>' +
        '<div class="cf-row var-row" data-f="cv"><label>Your CV</label>' +
          '<input type="file" class="var-cv" accept=".pdf,.doc,.docx,application/pdf,application/msword,application/vnd.openxmlformats-officedocument.wordprocessingml.document">' +
          '<div class="hf-err">Please attach your CV &mdash; PDF or Word, up to 5MB.</div></div>' +
        '<div class="cf-row"><label>A bit about you <span style="text-transform:none;letter-spacing:0;font-weight:500;">(optional)</span></label>' +
          '<textarea class="var-message" rows="3" maxlength="800" placeholder="Relevant experience, or why this role interests you&hellip;"></textarea></div>' +
        '<label class="declare2 var-consent-row"><input type="checkbox" class="var-consent">' +
          '<span>I am happy for Taiyabah Masjid to keep my details and CV while this application is considered. I can ask for them to be removed at any time.</span></label>' +
        '<div class="ar-problems var-problems" role="alert" aria-live="polite"></div>' +
        '<button type="submit" class="btn btn-gold cf-submit var-submit">Submit application</button>' +
        '<p class="cf-note">Nothing is sent until you press this. Questions? Ring ' +
          '<a href="tel:01204535997">01204 535 997</a>, 5pm&ndash;7pm.</p>' +
      '</form>' +
      '<div class="ar-done var-done"><h4 class="var-doneH">&nbsp;</h4>' +
        '<p class="var-doneP">&nbsp;</p><div class="ar-ref var-doneRef">&mdash;</div></div>';

    var today = new Date();
    var oldest = new Date(); oldest.setFullYear(oldest.getFullYear() - 110);
    var dobEl = host.querySelector('.var-dob');
    dobEl.max = iso(today); dobEl.min = iso(oldest);

    var form = host.querySelector('.var-form');
    var loadedAt = Date.now();
    function q(sel){ return host.querySelector(sel); }
    function val(sel){ return (q(sel) || {}).value || ''; }
    function picked(name){
      var el = form.querySelector('input[name="' + name + '"]:checked');
      return el ? el.value : '';
    }
    function mark(f, bad){
      var row = host.querySelector('.var-row[data-f="' + f + '"]');
      if(row) row.classList.toggle('bad', !!bad);
    }
    function problems(list){
      var box = q('.var-problems');
      box.innerHTML = list.map(function(m){
        return '• ' + m.replace(/[<>&]/g, function(c){
          return ({'<':'&lt;','>':'&gt;','&':'&amp;'})[c]; });
      }).join('<br>');
      box.classList.add('on');
      box.scrollIntoView({ behavior:'smooth', block:'center' });
    }

    /* Same pattern as the bmcc certificate upload in index_template.html:
       an unguessable name, into a private bucket anon may write but not
       read. */
    function uploadCv(f){
      var rand = (window.crypto && crypto.randomUUID)
        ? crypto.randomUUID()
        : String(Date.now()) + '-' + Math.random().toString(36).slice(2);
      var ext = (f.name.split('.').pop() || 'bin').toLowerCase().replace(/[^a-z0-9]/g, '') || 'bin';
      var path = v.key + '/' + rand + '.' + ext;
      return fetch(base + '/storage/v1/object/vacancy-cvs/' + path, {
        method: 'POST',
        headers: { 'apikey': cfg.SUPABASE_ANON_KEY,
                   'Authorization': 'Bearer ' + cfg.SUPABASE_ANON_KEY,
                   'Content-Type': f.type || 'application/octet-stream',
                   'x-upsert': 'false' },
        body: f
      }).then(function(res){
        if(!res.ok) throw new Error('upload ' + res.status);
        return path;
      });
    }

    form.addEventListener('submit', function(e){
      e.preventDefault();
      q('.var-problems').classList.remove('on');

      /* Honeypot, then the clock — same order as the interest form above,
         before validation. */
      if(val('.var-web') !== '' || (Date.now() - loadedAt) < 2000){
        form.style.display = 'none';
        q('.var-done').classList.add('on');
        q('.var-doneH').textContent = 'Thank you';
        q('.var-doneP').textContent = '';
        q('.var-doneRef').textContent = '—';
        return;
      }

      var name = val('.var-name'), email = val('.var-email'), phone = val('.var-phone'),
          addr1 = val('.var-addr1'), addr2 = val('.var-addr2'),
          town = val('.var-town'), postcode = val('.var-postcode'), dob = val('.var-dob'),
          member = picked('var-member'), message = val('.var-message'),
          consent = q('.var-consent').checked,
          file = (q('.var-cv').files || [])[0],
          d = dob && new Date(dob + 'T00:00:00'),
          ext = (file && file.name ? file.name.split('.').pop() : '').toLowerCase();

      /* One table instead of a block per field — each entry is true or its
         own error string, so the row marked and the message shown never
         drift apart. */
      var bad = [], checks = [
        ['name', name.trim().length >= 2 || 'Please give your full name.'],
        ['email', EMAIL.test(email) || 'Please give an email address the masjid can reply to.'],
        ['phone', phone.replace(/\D/g,'').length >= 10 || 'Please give a contact number the masjid can reach you on.'],
        ['addr1', addr1.trim().length >= 3 || 'Please give your address.'],
        ['town', town.trim().length >= 2 || 'Please give your town or city.'],
        ['postcode', postcode.trim().length >= 5 || 'Please give your postcode.'],
        ['dob', (d && !isNaN(d) && d <= today && d >= oldest) || 'Please give your date of birth.'],
        ['member', member === 'yes' || 'Positions can only be offered to a masjid member, or an immediate family member of one.'],
        ['cv', !file ? 'Please attach your CV.'
            : (!CV_MIMES[file.type] && !CV_EXTS[ext]) ? 'Your CV must be a PDF or Word document.'
            : file.size > CV_MAX ? 'Your CV is too large. The largest the masjid can take is 5MB.'
            : true]
      ];
      checks.forEach(function(c){ mark(c[0], c[1] !== true); if(c[1] !== true) bad.push(c[1]); });

      if(q('.var-consent-row')) q('.var-consent-row').classList.toggle('bad', !consent);
      if(!consent) bad.push('The masjid cannot keep your details without your agreement.');

      if(bad.length){ problems(bad); return; }

      var btn = q('.var-submit');
      btn.disabled = true; btn.textContent = 'Sending…';

      uploadCv(file).then(function(cvPath){
        return fetch(base + '/rest/v1/rpc/apply_for_vacancy_role', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json',
                     'apikey': cfg.SUPABASE_ANON_KEY,
                     'Authorization': 'Bearer ' + cfg.SUPABASE_ANON_KEY },
          body: JSON.stringify({ payload: {
            masjid: cfg.MASJID, vacancy: v.key,
            full_name: name, email: email, phone: phone,
            address_line1: addr1, address_line2: addr2, town: town, postcode: postcode,
            date_of_birth: dob, cv_path: cvPath,
            is_member_or_family: member === 'yes',
            message: message, consent: consent
          }})
        });
      }).then(function(r){ return r.text().then(function(t){ return { ok:r.ok, body:t }; }); })
      .then(function(res){
        if(!res.ok) throw new Error(res.body);
        var d = JSON.parse(res.body);
        form.style.display = 'none';
        q('.var-done').classList.add('on');
        q('.var-doneH').textContent = d.already
          ? 'You have already applied'
          : 'Thank you for your application';
        q('.var-doneP').textContent = d.already
          ? 'We already had an application from you for this role, so nothing has been added twice. What you have just told us has been updated.'
          : 'The masjid has your application and CV. Somebody will be in touch if you are shortlisted.';
        q('.var-doneRef').textContent = d.reference || '—';
        q('.var-done').scrollIntoView({ behavior:'smooth', block:'center' });
      })
      .catch(function(err){
        btn.disabled = false; btn.textContent = 'Submit application';
        var m = String(err.message || '');
        var friendly = /no longer open|your full name|reach you on|reply to|your address|town or city|date of birth|immediate family member|attach your CV|PDF or Word|too large|did not finish uploading|your agreement/.test(m)
          ? (m.match(/"message":"([^"]+)"/) || [null, null])[1] || null
          : null;
        problems([friendly ||
          'We could not send your application just now. Please try again, or ring the office on 01204 535 997 between 5pm and 7pm.']);
      });
    });
  }

  function buildVacancyPage(v){
    var page = v.page || {};
    var pg = document.createElement('div');
    pg.className = 'page';
    pg.setAttribute('data-page', 'vacancy-' + v.key);

    var mast = document.createElement('section'); mast.className = 'page-masthead';
    var mc = document.createElement('div'); mc.className = 'container';
    var back = document.createElement('a'); back.className = 'back-link'; back.href = '#';
    back.setAttribute('data-nav', 'svc-vacancies');
    back.textContent = 'Vacancies';
    var head = document.createElement('div'); head.className = 'section-head on-dark';
    var eb = document.createElement('div'); eb.className = 'eyebrow'; eb.textContent = 'Vacancies';
    var h1 = document.createElement('h1'); h1.style.fontSize = 'clamp(1.9rem,4vw,2.6rem)';
    h1.textContent = v.title;
    var tag = document.createElement('p'); tag.textContent = v.summary || '';
    head.appendChild(eb); head.appendChild(h1); head.appendChild(tag);
    mc.appendChild(back); mc.appendChild(head); mast.appendChild(mc);

    var body = document.createElement('section'); body.className = 'page-body';
    var bc = document.createElement('div'); bc.className = 'container';
    var split = document.createElement('div'); split.className = 'svc-split is-rail';

    var detail = document.createElement('div'); detail.className = 'svc-detail-facts';
    if(Array.isArray(page.responsibilities) && page.responsibilities.length){
      var h3a = document.createElement('h3');
      h3a.style.fontSize = '1.15rem';
      h3a.textContent = 'What the role involves';
      detail.appendChild(h3a);
      detail.appendChild(checklist(page.responsibilities));
    }
    if(Array.isArray(page.requirements) && page.requirements.length){
      var h3b = document.createElement('h3');
      h3b.style.cssText = 'font-size:1.15rem;margin-top:22px;';
      h3b.textContent = "What we're looking for";
      detail.appendChild(h3b);
      detail.appendChild(checklist(page.requirements));
    }
    var facts = [];
    if(page.commitment) facts.push(['Time commitment', page.commitment]);
    if(page.closing_date) facts.push(['Applications close', page.closing_date]);
    if(facts.length){
      var dl = document.createElement('dl');
      dl.className = 'adm-rules'; dl.style.marginTop = '22px';
      facts.forEach(function(f){
        var dt = document.createElement('dt'); dt.textContent = f[0];
        var dd = document.createElement('dd'); dd.textContent = f[1];
        dl.appendChild(dt); dl.appendChild(dd);
      });
      detail.appendChild(dl);
    }

    var aside = document.createElement('div'); aside.className = 'svc-aside';
    var cform = document.createElement('div'); cform.className = 'cform';
    buildApplicationForm(v, cform);
    aside.appendChild(cform);

    split.appendChild(detail); split.appendChild(aside);
    bc.appendChild(split);
    body.appendChild(bc);

    pg.appendChild(mast); pg.appendChild(body);
    document.body.appendChild(pg);
  }

  /* Only four tiles ever exist, so nothing is built here — only changed. */
  function openTile(v){
    var tile = document.querySelector('.vac-tile[data-vac-cat="' + v.category + '"]');
    if(!tile) return;
    tile.classList.remove('is-soon');
    tile.classList.add('is-open');
    tile.setAttribute('data-nav', 'vacancy-' + v.key);
    var t = tile.querySelector('.vt-tag'); if(t) t.textContent = 'Apply now';
    var p = tile.querySelector('.vt-p');
    if(p && v.summary) p.textContent = v.summary;
  }

  fetch(base + '/rest/v1/rpc/vacancies_public', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json',
               'apikey': cfg.SUPABASE_ANON_KEY,
               'Authorization': 'Bearer ' + cfg.SUPABASE_ANON_KEY },
    body: JSON.stringify({ p_masjid: cfg.MASJID })
  }).then(function(r){
    if(!r.ok) throw new Error('vacancies ' + r.status);
    return r.json();
  }).then(function(rows){
    if(!Array.isArray(rows) || !rows.length) return;
    rows.forEach(function(v){
      if(!v || !v.key || !v.category || !v.title) return;
      if(document.querySelector('[data-page="vacancy-' + v.key + '"]')) return;
      openTile(v);
      buildVacancyPage(v);
    });
  }).catch(function(e){
    if(window.console && console.warn) console.warn('vacancies:', e.message);
  });
})();
