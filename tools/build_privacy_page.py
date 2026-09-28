#!/usr/bin/env python3
"""Write /madrasah-privacy/index.html — the madrasah privacy notice.

WHY THIS FILE HOLDS THE WORDS

The notice existed as a Word document, and on 20 September that document was
true. On 26 September the register import brought in 552 dates of birth, 551
addresses, 38 medical notes, 24 allergies and 11 SEND records, and the document
did not change, because documents do not. By 27 September its opening paragraph
— the one every parent actually reads — told several hundred families that the
madrasah held none of those things.

That is the THIRD time a data protection document here has been made false by a
later migration. v1.0 said the masjid held no parent's name and no fee history;
the fees work made both false overnight.

So the words live here, in the repository, next to the schema they describe:

  * this file generates the PUBLISHED PAGE, which is what parents read;
  * tools/build_privacy_docx.py generates the SIGNED DOCUMENT from the same
    CONTENT below, so the page and the signature cannot drift apart;
  * _test/privacy_notice_test.py reads NOT_HELD below and fails if any of it
    turns out to be a column with data in it.

A claim nothing enforces is a sentence in a document. This is the enforcement.

    python3 tools/build_privacy_page.py
"""
import datetime
import glob
import html
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "madrasah-privacy")

VERSION = "1.4"
ISSUED = "27 September 2026"   # v1.3 same day: attendance
REVIEW = "27 September 2027"

#  ======================================================================
#  WHAT THE MADRASAH DOES NOT HOLD
#
#  THIS LIST IS CHECKED AGAINST THE DATABASE, not merely printed. Each entry
#  names the columns that would make it a lie. _test/privacy_notice_test.py
#  fails if any of them exists with data in it, and the check runs against
#  production rather than against a fixture — a claim about what the masjid
#  holds can only be tested against what the masjid holds.
#
#  Anything removed from this list must be ADDED to WHAT_WE_HOLD in the same
#  edit. Deleting a line here is how the notice stops being wrong and starts
#  being incomplete instead.
#  ======================================================================
NOT_HELD = [
    ("A photograph of your child",
     ["madrasah_pupils.photo", "madrasah_pupils.photo_url",
      "madrasah_pupils.image"]),
    ("Their nationality, ethnicity or first language",
     ["madrasah_pupils.nationality", "madrasah_pupils.ethnicity",
      "madrasah_pupils.language"]),
    ("Behaviour or merit marks",
     ["madrasah_behaviour", "madrasah_merits"]),
    ("Test or examination results",
     ["madrasah_exams", "madrasah_exam_results", "madrasah_assessments"]),
    ("Anything about your child's progress or ability",
     ["madrasah_reports", "madrasah_progress"]),
]

#  The counts in this table are read from production when the page is built,
#  so the notice cannot quietly describe a system it no longer matches. The
#  figures are ROUNDED AND ABOUT THE WHOLE ROLL — no figure here is about an
#  identifiable child.
#  EACH LINE NAMES THE COLUMNS IT COVERS, and build() checks that set against
#  the `described` array in db/081. Those two lists used to be independent: the
#  notice said one thing, the guard checked another, and nothing compared them.
#  That is the same shape of fault as the notice and the schema drifting apart
#  in the first place, one level up, and it would have been just as invisible.
WHAT_WE_HOLD = [
    ("Their name", "Given name and family name, as you gave it to us.",
     ["madrasah_pupils.first_name", "madrasah_pupils.last_name",
      "madrasah_pupils.legacy_ref", "madrasah_pupils.status"]),
    ("Their date of birth",
     "So that two children with the same name are not confused with each "
     "other, and so that a child is put in the right class for their age.",
     ["madrasah_pupils.date_of_birth"]),
    ("Their class", "Which class they are in. If they move class, we change it.",
     []),
    ("Boy or girl",
     "The madrasah teaches boys and girls separately, so the register has to "
     "know which.", ["madrasah_pupils.gender"]),
    ("The dates they joined and left",
     "The date they started, and the date they left. Empty while they are "
     "still with us.",
     ["madrasah_pupils.joined_on", "madrasah_pupils.left_on"]),
    ("Your home address and postcode",
     "Recorded when your child was enrolled. It is how the office knows which "
     "children live at the same address, and it is on the family rather than "
     "on each child.",
     ["madrasah_pupils.address", "madrasah_pupils.postcode",
      "madrasah_households.note", "madrasah_households.name",
      "madrasah_households.reference"]),
    ("Which day school they go to, and which year they are in",
     "Recorded for some children, not all. It helps us place a child in the "
     "right class and know when they will be tired.",
     ["madrasah_pupils.school", "madrasah_pupils.school_year"]),
    ("Whether they were at a madrasah before this one",
     "Recorded for some children.", ["madrasah_pupils.prev_madrasah"]),
    ("Medical information, allergies, and additional needs",
     "Recorded for a small number of children whose parents told us something "
     "we need to know to look after them safely — an allergy, an inhaler, a "
     "condition, or support they receive at school. Most children have "
     "nothing recorded here at all. This is the most sensitive thing the "
     "madrasah holds, and it is treated as such: see “Who can see it”.",
     ["madrasah_pupils.medical", "madrasah_pupils.allergies",
      "madrasah_pupils.send_detail", "madrasah_pupils.ehcp_detail"]),
    ("Whether they may walk home alone",
     "Recorded where a parent has told us.",
     ["madrasah_pupils.walk_home_consent"]),
    ("A note",
     "A short free-text note, used rarely, for something the madrasah needs "
     "to remember about a child.", ["madrasah_pupils.notes"]),

    #  ADDED 27 SEPTEMBER, AND IT SHOULD NOT BE HERE FOR LONG.
    #  307 of the 552 children carry an email address on their OWN row. 207 of
    #  them are the same address already recorded against a parent on the same
    #  family, and 152 are shared between brothers and sisters - so it is the
    #  parent's address, copied onto the child by the import.
    #
    #  That matters beyond tidiness: the whole reason a fee reminder can be
    #  sent without naming a child is that a parent's details sit on the
    #  FAMILY and not on the child. 307 rows quietly break that. It is
    #  described here because it is true today, and described as temporary
    #  because it should not be true next week.
    ("An email address on your child's own record",
     "For about half the children the old system recorded an email address "
     "against the child as well as against the family. It is almost always a "
     "parent's address rather than the child's. We are moving these onto the "
     "family record, where they belong, and removing them from the "
     "child's.", ["madrasah_pupils.email"]),

    #  ADDED AT v1.3, BEFORE THE FIRST MARK WAS MADE.
    #  v1.2 said "we are building an attendance register; when it starts being
    #  used we will issue a new version of this notice and tell you before the
    #  first mark is made, not afterwards." The table exists as of 084 and the
    #  database REFUSES to record a single mark until every family with a child
    #  on the roll has been recorded as told — see attendance_permitted().
    #  That is the promise kept by machinery rather than by remembering.
    ("Whether your child came in, evening by evening",
     "Present, late, away, or away with a reason you have given us. We keep "
     "the reason you tell us and we do not keep an opinion about whether it "
     "was a good enough one. Nobody outside the madrasah sees it.",
     ["madrasah_attendance.mark", "madrasah_attendance.reason",
      "madrasah_attendance.on_date", "madrasah_attendance.source",
      "madrasah_attendance.class_id"]),

    #  ADDED AT v1.4, WITH TEACHER ACCOUNTS. A madrasah where staff have no
    #  way to write a worry down is a madrasah where worries are not written
    #  down. Parents have a right to know the record exists even though, as
    #  the notice says below, they cannot always be shown one.
    ("A safeguarding concern, if a member of staff raises one",
     "If a member of staff is worried about your child, they write down what "
     "they saw or were told and it goes straight to the safeguarding lead. "
     "Most children never have one. It records what happened, when, and who "
     "wrote it \u2014 not an opinion about your family.",
     ["madrasah_concerns.what_happened", "madrasah_concerns.when_it_happened",
      "madrasah_concerns.reference", "madrasah_concerns.status",
      "madrasah_concerns.raised_by_name", "madrasah_concerns.outcome_note",
      "madrasah_concerns.raised_at", "madrasah_concerns.seen_at"]),
]

PARENT_HOLD = [
    ("Your name", "So we know who we are writing to.",
     ["madrasah_guardians.full_name"]),
    ("Your email address", "Where a fee reminder is sent, if you have given us one.",
     ["madrasah_guardians.email"]),
    ("Your telephone number",
     "So the office can ring you instead, if you would rather, or if we have "
     "no email address for you.", ["madrasah_guardians.phone"]),
    ("Your home address",
     "The family's address, recorded when a child was enrolled. It is held "
     "once, on the family, rather than against each child."),
    ("Which family you are",
     "A family name — usually a surname and a street — and a short reference "
     "you quote when you pay."),
    ("Whether you are the first person we ring",
     "One adult per family is the nominated contact. Tell the office if you "
     "would rather it were somebody else.",
     ["madrasah_guardians.is_primary"]),
    ("What has been charged and paid",
     "What the family has been charged, what has been received, and the "
     "reference that appeared on the bank statement."),
]

STAFF_HOLD = [
    ("Your name", "Including your title — Apa, Moulana, Hafiz, Mufti."),
    ("How to reach you", "Home address, telephone number (up to two), email address."),
    ("Date of birth",
     "Held to tell apart two people with the same name, and because a record "
     "of an adult working with children should identify them properly."),
    ("Your role",
     "Which side you teach, employed or volunteer, the date you started and "
     "the date you left."),
    ("When you are in", "Which evenings, and the hours."),
    ("Your classes",
     "Which classes you take and which you are the main teacher for."),
    ("DBS",
     "The date on your certificate, the date we last looked at it, whether "
     "you are on the Update Service, and whether a check is not required for "
     "your role."),
    ("Notes",
     "A free-text note, used rarely, for something the madrasah needs to "
     "record about your role."),
]

RIGHTS = [
    ("Show you what we hold",
     "We will give you a copy of your child's record. It is longer than it "
     "once was — the list above — so allow us a few days rather than a few "
     "minutes."),
    ("Correct something",
     "If a name is spelled wrong, a date of birth is wrong or a class is "
     "wrong, tell us and we will change it straight away. Some dates of birth "
     "came across from the old system looking doubtful and we would be glad "
     "to be corrected."),
    ("Delete it",
     "If your child has left, we will normally agree. While your child is "
     "attending we may need to keep the record in order to teach them safely; "
     "if we say no, we will explain why in writing."),
    ("Stop using it",
     "You can ask us to pause while a disagreement is sorted out. We will "
     "keep the record but not use it."),
    ("Object to us holding it",
     "You can object at any time. We then have to stop unless we can show "
     "compelling reasons that outweigh your child's interests. We will answer "
     "in writing and give our reasons."),
    ("Take the medical information back off us",
     "If you told us about an allergy or a condition and you would rather we "
     "did not keep it written down, say so. We will talk to you about what "
     "that means for looking after your child, and we will do as you ask."),
    ("Take it elsewhere",
     "The right to data portability does not apply here, because it only "
     "covers information held with consent or under a contract. We have said "
     "so plainly rather than leave you to find out when you ask."),
]

GUARD_FROM = []

LEAD_NAME = os.environ.get("DP_LEAD_NAME", "")
LEAD_EMAIL = os.environ.get("DP_LEAD_EMAIL", "")
LEAD_PHONE = os.environ.get("DP_LEAD_PHONE", "")


def e(s):
    return html.escape(str(s), quote=True)


def rows(pairs):
    """Render (label, text) or (label, text, [columns]) alike.

    The column list is for the cross-check against db/081, not for the page: a
    parent has no use for a schema name and would rightly wonder why it was
    there.
    """
    return "".join(
        "<tr><th scope=\"row\">%s</th><td>%s</td></tr>" % (e(r[0]), e(r[1]))
        for r in pairs)


def guard_columns():
    """The `described` array from the LAST migration that defines the guard.

    NOT db/081 BY NAME. It was, and that broke the moment 085 redefined the
    guard to cover attendance: the page went on being checked against a list
    three migrations out of date, which is the same fault this whole mechanism
    exists to prevent, one level further up.

    The last migration wins, because that is what Postgres does with
    `create or replace`.
    """
    defs = sorted(glob.glob(os.path.join(ROOT, "db", "*.sql")))
    latest, where = None, None
    for path in defs:
        src = open(path, encoding="utf-8").read()
        if "madrasah_notice_matches_schema" not in src:
            continue
        block = re.search(r"described text\[\] := array\[(.*?)\];", src, re.S)
        if block:
            latest, where = block.group(1), os.path.basename(path)
    if latest is None:
        sys.exit("No migration defines madrasah_notice_matches_schema with a "
                 "`described` list. Nothing written, because the page cannot "
                 "be checked against anything.")
    GUARD_FROM.append(where)
    return set(re.findall(r"'([a-z_]+\.[a-z_]+)'", latest))


def described_here():
    """The columns the wording above claims to cover."""
    got = set()
    for row in WHAT_WE_HOLD + PARENT_HOLD:
        if len(row) > 2:
            got.update(row[2])
    return got


def build():
    lead_block = (
        '<p class="lead-known"><strong>%s</strong><br>'
        '<a href="mailto:%s">%s</a><br>%s</p>'
        % (e(LEAD_NAME), e(LEAD_EMAIL), e(LEAD_EMAIL), e(LEAD_PHONE))
        if (LEAD_NAME and LEAD_EMAIL) else
        #  A NOTICE THAT DOES NOT SAY WHO TO ASK IS NOT A NOTICE.
        #  Article 13(1)(a) requires the controller's contact details. Rather
        #  than print blank lines on a public web page, the page falls back to
        #  the office, which is a real route a parent can actually use, and
        #  says so.
        '<p>Ask at the masjid office and you will be put in touch with the '
        'right person, or write to <a href="mailto:info@taiyabahmasjid.com">'
        'info@taiyabahmasjid.com</a> marking it <em>for the Data Protection '
        'Lead</em>. You do not need to put it in writing, though it helps us '
        'if you do.</p>')

    not_held = "".join("<li>%s</li>" % e(t) for t, _cols in NOT_HELD)

    page = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Madrasah Privacy Notice &mdash; Taiyabah Masjid</title>
<meta name="description" content="What Taiyabah Masjid madrasah keeps about your child and about our staff, why, who can see it, how long we keep it, and what you can ask us to do.">
<link rel="icon" href="/favicon.ico" sizes="any">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="preload" href="../fonts/fraunces-latin.woff2" as="font" type="font/woff2" crossorigin>
<link rel="preload" href="../fonts/hanken-grotesk-latin.woff2" as="font" type="font/woff2" crossorigin>
<link rel="stylesheet" href="../admin/fonts.css">
<style>
/*  A REAL FOLDER, NOT A HASH ROUTE.
    The signed notice prints taiyabahmasjid.com/madrasah-privacy and several
    hundred parents are going to be given that address. A #fragment is not
    sent to the server, so a typo or a JavaScript failure lands the reader on
    the homepage with no error rather than on a page that says it is missing.
    This is /madrasah-privacy/index.html and it needs no JavaScript at all. */
:root{
  --brand-900:#3C0B2A; --brand-800:#4B1136; --brand-700:#5E1844;
  --gold:#C6A24C; --gold-ink:#7A5D14;
  --paper:#F5F1E8; --card:#FCFAF3; --ink:#261B22;
  --muted:#6E616A; --line:#E4DECF; --danger:#B4532F; --danger-ink:#A0451F;
  --success-ink:#2F5E36; --radius:14px;
}
*{box-sizing:border-box;margin:0;padding:0;}
body{font-family:"Hanken Grotesk",system-ui,-apple-system,sans-serif;
  color:var(--ink);background:var(--paper);line-height:1.62;font-size:17px;
  -webkit-font-smoothing:antialiased;}
h1,h2,h3{font-family:"Fraunces",Georgia,serif;line-height:1.18;font-weight:600;
  letter-spacing:-.01em;}
a{color:var(--brand-700);}
a:hover{color:var(--brand-900);}

.masthead{background:var(--brand-900);color:#F3EFE3;padding:26px 0 30px;}
.wrap{max-width:760px;margin:0 auto;padding:0 22px;}
.masthead .eyebrow{font-size:12px;letter-spacing:.14em;text-transform:uppercase;
  color:var(--gold);font-weight:700;margin-bottom:8px;}
.masthead h1{font-size:clamp(1.8rem,4.4vw,2.5rem);color:#FCFAF3;margin-bottom:6px;}
.masthead p{color:#D9CFD5;font-size:15.5px;max-width:60ch;}
.masthead a{color:var(--gold);}

main{padding:34px 0 60px;}
.card{background:var(--card);border:1px solid var(--line);border-radius:var(--radius);
  padding:24px 26px;margin-bottom:26px;}

.oneline{border-left:4px solid var(--success-ink);background:#F2F6F0;
  border-radius:10px;padding:18px 20px;margin-bottom:26px;}
.oneline h2{font-size:1.05rem;margin-bottom:8px;}
.oneline p+p{margin-top:10px;}

h2{font-size:1.32rem;margin:34px 0 10px;}
h2:first-child{margin-top:0;}
h3{font-size:1.02rem;margin:22px 0 8px;}
p{margin-bottom:12px;max-width:68ch;}
ul{margin:0 0 14px 22px;}
li{margin-bottom:7px;max-width:66ch;}

table{border-collapse:collapse;width:100%;margin:6px 0 18px;font-size:15.5px;}
th,td{text-align:left;vertical-align:top;padding:10px 12px;
  border-bottom:1px solid var(--line);}
th[scope="row"]{width:34%;font-weight:700;color:var(--ink);}
@media (max-width:620px){
  /*  The two-column tables become stacked pairs. At 390px a 34% label column
      left four words per line in the description beside it. */
  table,tbody,tr,th,td{display:block;width:auto;}
  tr{border-bottom:1px solid var(--line);padding:10px 0;}
  th,td{border:0;padding:0;}
  th[scope="row"]{width:auto;margin-bottom:2px;}
}

.meta{font-size:14px;color:var(--muted);}
.meta td,.meta th{padding:6px 12px 6px 0;border:0;}

.callout{border:1px solid var(--line);border-left:4px solid var(--gold-ink);
  background:var(--paper);border-radius:10px;padding:16px 18px;margin:16px 0 20px;}
.callout h3{margin-top:0;}
.callout.warn{border-left-color:var(--danger-ink);background:#FBF1ED;}

.changed{border:1px solid var(--danger-ink);background:#FBF1ED;border-radius:10px;
  padding:16px 18px;margin:0 0 26px;}
.changed h2{margin-top:0;font-size:1.08rem;color:var(--danger-ink);}

footer{border-top:1px solid var(--line);padding:22px 0 50px;font-size:14px;
  color:var(--muted);}
footer a{color:var(--brand-700);}

@media print{
  body{background:#fff;font-size:11pt;}
  .masthead{background:none;color:#000;border-bottom:1.5pt solid #000;padding:0 0 10pt;}
  .masthead h1,.masthead p,.masthead .eyebrow{color:#000;}
  .card{border:0;background:none;padding:0;}
  .wrap{max-width:none;padding:0;}
  a{color:#000;text-decoration:underline;}
  h2{page-break-after:avoid;}
  table{page-break-inside:avoid;}
}
</style>
</head>
<body>

<header class="masthead">
  <div class="wrap">
    <p class="eyebrow">Taiyabah Masjid &middot; Madrasah</p>
    <h1>Madrasah Privacy Notice</h1>
    <p>What we keep about your child, and about our staff. Articles 13 and 14,
       UK General Data Protection Regulation.</p>
  </div>
</header>

<main class="wrap">

  <!-- WHAT CHANGED, AT THE TOP, NAMED.
       The previous version told parents the madrasah held none of this. It
       was true when it was written and stopped being true when 552 records
       were imported. Quietly replacing the page and hoping nobody compares is
       precisely what the "Changes to this notice" section promises not to do,
       so the change is the first thing on the page for as long as it is
       news. -->
  <section class="changed">
    <h2>This notice changed on {{issued}}, and it matters</h2>
    <p><strong>The madrasah has started keeping a register</strong>, and
       <strong>teachers now have their own logins</strong>. We said in earlier
       versions that we would tell you before the first register mark was made
       and before any teacher had an account, rather than afterwards. This is
       us doing both.</p>
    <p>A teacher sees the classes they teach and nothing else &mdash; not
       another class, not your address, not the fees. What they can see, and
       why they can see the medical information, is set out under
       &ldquo;Who can see it&rdquo; below.</p>
    <p>The previous version said the madrasah kept your child&rsquo;s name, class
       and dates only, and held no date of birth, address, telephone number or
       medical information. <strong>That is no longer true, and this version
       says what is actually held.</strong></p>
    <p>Nothing was taken without being given: all of it came from the
       madrasah&rsquo;s own previous records when they were moved into the new
       system in September 2026. What went wrong is that the notice was not
       updated at the same time. We are telling you rather than replacing the
       page quietly.</p>
  </section>

  <section class="oneline">
    <h2>In one paragraph</h2>
    <p>We keep your child&rsquo;s name, date of birth, class, whether they are a
       boy or a girl, the dates they joined and left, and your family&rsquo;s
       address. For a small number of children we also keep medical, allergy or
       additional-needs information that a parent told us, so that staff can
       look after them safely. We keep your name and a way of reaching you, and
       what the family has been charged and paid.</p>
    <p>We do not share any of it with anybody outside the masjid. We keep it for
       three years after your child leaves and then it is deleted
       automatically.</p>
    <p>The rest of this notice explains that properly, tells you what you can
       ask us to do, and tells you how to complain if you are not happy.</p>
  </section>

  <div class="card">
  <table class="meta">
    <tr><th scope="row">Version</th><td>{{version}}</td></tr>
    <tr><th scope="row">Issued</th><td>{{issued}}</td></tr>
    <tr><th scope="row">Next review</th><td>{{review}}</td></tr>
    <tr><th scope="row">Applies to</th><td>The madrasah at Taiyabah Masjid.
        A <a href="../#privacy">separate notice</a> covers the website
        itself.</td></tr>
  </table>
  </div>

  <div class="card">
  <h2>Who we are, and who to ask</h2>
  <p>The madrasah is run by <strong>Bolton Central Islamic Society</strong>, a
     registered charity (number <strong>1041569</strong>), which operates
     <strong>Taiyabah Masjid</strong> in Bolton. In data protection language the
     charity is the <strong>controller</strong> for the records described here
     &mdash; it is the organisation responsible for them, and the organisation
     you can hold to account.</p>
  {{lead}}
  <p>We reply within one month. If your request is complicated we may take up to
     two more months, and we will tell you within the first month if that is
     going to happen. It costs nothing, and we will not ask why.</p>
  </div>

  <div class="card">
  <h2>Part A &mdash; your child&rsquo;s records</h2>

  <h3>What we hold</h3>
  <table>{{hold}}</table>

  <div class="callout">
    <h3>What we do not hold about your child</h3>
    <ul>{{nothold}}</ul>
    <p>None of this is missing by accident. Each was considered and left out,
       because the honest question &mdash; &ldquo;what would the madrasah
       actually do with it?&rdquo; &mdash; had no good answer. Information we
       never collect cannot be lost, leaked or misused.</p>
    <p><strong>We are building an attendance register.</strong> When it starts
       being used we will issue a new version of this notice and tell you
       before the first mark is made, not afterwards.</p>
  </div>

  <h3>Where we got it</h3>
  <p>From you, when you enrolled your child, and from the madrasah&rsquo;s own
     previous record system, which these records replaced in September 2026. We
     did not obtain anything about your child from anywhere else, and we did not
     add anything to it.</p>

  <h3>Why we hold it, and what allows us to</h3>
  <p>We hold it to run the madrasah: to know which children are enrolled, which
     class each child is in, which teacher is responsible for them, how to reach
     their family, and what any of them needs in order to be safe here.</p>
  <table>
    <tr><th scope="row">Our lawful basis</th>
      <td>Legitimate interests &mdash; Article 6(1)(f). Our interest is running
      a madrasah the community asked us to run, and keeping the children in it
      safe. We have weighed that against your child&rsquo;s privacy.</td></tr>
    <tr><th scope="row">Why not consent</th>
      <td>Because consent has to be freely given, and it would not be: if you
      could not refuse without your child losing their place, it is not a real
      choice. Calling it consent would be dishonest.</td></tr>
    <tr><th scope="row">Being on a madrasah roll says something about religion</th>
      <td>The law treats that as needing extra protection (Article 9). We rely
      on <strong>Article 9(2)(d)</strong>, which allows a not-for-profit
      religious body to keep records about its own members and the people who
      come to it regularly &mdash; provided it does not share them outside the
      organisation without consent. We do not share them.</td></tr>
    <tr><th scope="row">Medical, allergy and additional-needs information</th>
      <td>{{article9}}</td></tr>
  </table>
  <p>Because our basis is legitimate interests, you have the right to object to
     it. That is a real right and not a formality &mdash; see
     &ldquo;What you can ask us to do&rdquo;.</p>

  <h3>Do you have to give it to us?</h3>
  <p>There is no law that says you must. We cannot enrol a child without a name,
     a date of birth and a class, and we cannot run a madrasah safely with no
     way of reaching anybody when a child is unwell.</p>
  <p><strong>The medical information is different.</strong> You do not have to
     tell us about an allergy, a condition or an additional need, and your child
     will not lose their place if you do not. We ask because a member of staff
     who does not know cannot act, and because the alternative is finding out
     during the emergency. If you have told us something and want it removed,
     say so and we will remove it.</p>

  <h3>Who can see it</h3>
  <ul>
    <li><strong>Administrators at the masjid, and nobody else.</strong> Today
      that is three people.</li>
    <li>Every one of them has to use a second step to sign in &mdash; a changing
      code from an app on their phone, as well as a password. A stolen password
      on its own is not enough to see anything.</li>
    <li><strong>Lists do not show the sensitive things.</strong> A screen
      listing the children shows a small mark meaning a child has a medical note
      &mdash; not what the note says. Somebody has to open that one child&rsquo;s
      record deliberately to read it, and the system writes down who did and
      when. The same is true of your telephone number and your address.</li>
    <li><strong>Teachers now have accounts, and see only their own
      classes.</strong> The last version of this notice said no teacher had
      one and promised you would be told before that changed. This is us
      doing that. A teacher signs in and can see: the classes they teach, the
      children in those classes, whether each child came in, any medical,
      allergy or additional-needs information for those children, and one
      telephone number to ring. <strong>Nothing else.</strong> Not another
      class, not your address, not the fees, not the roll as a whole. That is
      not a rule the screen follows &mdash; the database refuses to answer a
      teacher who asks for anything more.</li>
    <li><strong>Why a teacher can see the medical information.</strong>
      Because that is why you told us. A teacher who does not know a child
      carries an inhaler cannot act, and the alternative is finding out during
      the emergency. Every time a teacher opens a child&rsquo;s record it is
      written down with their name against it.</li>
    <li>Nobody outside the masjid sees them. We do not share them with any other
      mosque, school, council, charity or company. We do not sell them. We do
      not use them to ask you for money.</li>
  </ul>
  <p>The one exception we must be honest about: if we ever had a serious concern
     about a child&rsquo;s safety, we would share what was necessary with the
     authorities whose job that is. That is a different situation with its own
     legal basis, and we would not need your permission for it. It has nothing
     to do with the ordinary running of the madrasah.</p>
  <div class="callout warn">
    <h3>Safeguarding records work differently, and you should know how</h3>
    <p>A concern raised about a child is read by the safeguarding lead and
       nobody else &mdash; not by the teacher who raised it, once it is sent,
       and not by other staff.</p>
    <p>If you ask to see what we hold about your child, <strong>we may not be
       able to show you a safeguarding record</strong>, and we may not always
       be able to tell you one exists. The law allows that where showing it
       would put a child at risk. We are telling you the rule now rather than
       using it as a surprise later. If it ever applies to you we will say that
       we are withholding something and why, as far as we are able.</p>
  </div>

  <h3>The system we used before</h3>
  <p>Until September 2026 these records were kept in a different system, and
     that copy still exists. The masjid remains responsible for it while it
     does. We are arranging for those records to be deleted at source, and until
     that is done everything in this notice &mdash; your rights included &mdash;
     applies to that copy as well as to this one. If you ask us to delete your
     child&rsquo;s record, we will delete it from both.</p>

  <h3>Where it is kept</h3>
  <p>In a secure database hosted in London, in the United Kingdom. The company
     that provides the hosting is based in the United States and its support
     staff could in principle need access to fix a fault, which is covered by a
     written contract requiring them to protect the data to UK standards and to
     act only on our instructions.</p>

  <h3>How long we keep it</h3>
  <p>Three years after your child leaves the madrasah. Then it is deleted
     permanently, by an automatic process that runs every week. We do not have
     to remember to do it, and we cannot quietly forget.</p>
  <p>Three years is long enough to answer a question raised after the event, or
     to welcome a family back without starting again, and short enough that we
     are not keeping a permanent list of who attended a madrasah. If we remove a
     record by mistake it goes to an archive we can restore it from, and the same
     three-year clock applies to that copy.</p>

  <h3>What you can ask us to do</h3>
  <p>These are your rights in law. You can use any of them by asking the Data
     Protection Lead. We will not charge you and we will not ask why.</p>
  <table>{{rights}}</table>

  <div class="callout">
    <h3>Why we may ask which class your child is in</h3>
    <p>Some children at the madrasah share a name &mdash; twelve names on our
       roll belong to two different children each. So if you ask us about your
       child, we will ask which class they are in before we show you anything or
       change anything. It is not obstruction: it is how we make sure we do not
       show you another family&rsquo;s record, or delete the wrong
       child&rsquo;s.</p>
  </div>

  <p>If your child is old enough to understand the request, we will take their
     view into account before showing their record to anyone, including you. The
     rights belong to the child; a parent exercises them on their behalf while
     the child is too young to do it themselves.</p>

  <h3>Decisions made by computer</h3>
  <p>There are none. Nothing in our system scores, ranks, sorts or decides
     anything about a child. Every decision about your child is made by a
     person.</p>
  </div>

  <div class="card">
  <h2>Part A2 &mdash; what we hold about you, the parent</h2>
  <p>Part A is about your child. This short part is about you.</p>
  <table>{{parent}}</table>
  <p>We do not hold your date of birth, and we hold nothing about your
     relationship to the child beyond your being the family&rsquo;s contact.</p>

  <h3>Why we hold it, and what allows us to</h3>
  <table>
    <tr><th scope="row">Why</th><td>To tell you what the madrasah fees are, to
      take them, to keep the charity&rsquo;s own record of what was charged and
      received, and to be able to reach somebody if your child is unwell.</td></tr>
    <tr><th scope="row">What allows us to</th><td>Article 6(1)(f) &mdash; our
      legitimate interests. The madrasah is paid for by these fees, and we
      cannot ask for them, or tell you your child has been hurt, without a way
      of reaching you.</td></tr>
    <tr><th scope="row">Is this special category data?</th><td>No. It is
      ordinary personal data about an adult. The special rules in Part A apply
      to your child&rsquo;s record, not to yours.</td></tr>
  </table>

  <h3>About the reminders we send</h3>
  <ul>
    <li><strong>One of you, not both.</strong> We write to one nominated adult
      per family. If you would rather it were the other parent, tell the
      office.</li>
    <li><strong>It never names your child.</strong> A reminder says the family,
      the reference and the amount. An email can be forwarded or read by
      somebody else, and what your child attends is nobody else&rsquo;s
      business.</li>
    <li>Not more than once a week, and never if the balance is already clear
      when we press send.</li>
    <li>You can ask us to stop emailing you and to ring you instead. That is an
      objection under Article 21 and we will honour it. We cannot stop telling
      you what is owed &mdash; but we can change how.</li>
  </ul>
  <div class="callout">
    <h3>If money is difficult</h3>
    <p>Tell the office. The madrasah reduces and waives fees for families in
       hardship, and it would far rather have that conversation than have a
       child stop coming. Nothing about asking is recorded against your
       child.</p>
  </div>

  <h3>How long we keep it</h3>
  <p>Your details are deleted when the family&rsquo;s record is &mdash; three
     years after the last child in the family has left. The record of money
     charged and received is kept for six years, because that is how long a
     charity must keep its accounts. That is a legal requirement on us and not a
     choice.</p>
  </div>

  <div class="card">
  <h2>Part B &mdash; if you teach or help at the madrasah</h2>
  <p>This part is for staff and volunteers. Parents do not need to read it.</p>
  <table>{{staff}}</table>

  <h3>DBS &mdash; what we hold and what we do not</h3>
  <p>We record <strong>that</strong> a check was done and <strong>when</strong>.
     Nothing more. No certificate number, no copy of the disclosure, and no note
     of any conviction, caution or offence.</p>
  <ul>
    <li><strong>Why the certificate number is not held:</strong> it does not
      prove a check was clear &mdash; the date and the Update Service status do
      that &mdash; and its main use to somebody else would be pretending to be
      you.</li>
    <li><strong>Why we do not record outcomes:</strong> information about
      convictions and offences is tightly controlled by law and needs its own
      written justification and policy. We have not taken that on, so we do not
      hold it. If that ever changes we will tell you first.</li>
  </ul>
  <p>We also do not hold your National Insurance number, your bank details, or
     your gender.</p>

  <h3>Why we hold it, and what allows us to</h3>
  <table>
    <tr><th scope="row">If you are paid or under an agreement with us</th>
      <td>Article 6(1)(b) &mdash; we need it to perform that agreement.</td></tr>
    <tr><th scope="row">If you volunteer</th><td>Article 6(1)(f), legitimate
      interests &mdash; running the madrasah and keeping children safe. We need
      to be able to identify and contact the adults we put in front of
      children.</td></tr>
    <tr><th scope="row">Is this special category data?</th><td>No. Your record
      is ordinary personal data about an adult.</td></tr>
  </table>

  <h3>Who can see it, and for how long</h3>
  <ul>
    <li>Masjid administrators only, under the same two-step sign-in described in
      Part A.</li>
    <li>Screens that list all staff do not show your address, date of birth or
      hours. They show a small mark meaning &ldquo;on file&rdquo; or &ldquo;not
      on file&rdquo;. Somebody has to open your record deliberately to see the
      details, and that is recorded.</li>
    <li>Kept for three years after you leave, then deleted, the same as a pupil
      record.</li>
  </ul>
  <p>You have the same rights as those in Part A, and you exercise them the same
     way.</p>
  </div>

  <div class="card">
  <h2>Part C &mdash; complaints, security, and changes</h2>

  <h3>If you are not happy</h3>
  <p>Please come to us first. Most things are a misunderstanding or a mistake we
     can put right the same day, and we would rather fix it than have you go
     elsewhere to get it fixed.</p>
  <p>You do not have to, though, and you can complain to the Information
     Commissioner at any time. Complaining to them costs nothing and does not
     affect your child&rsquo;s place at the madrasah in any way.</p>
  <table>
    <tr><th scope="row">Helpline</th><td>0303 123 1113 &mdash; they will talk
      you through it</td></tr>
    <tr><th scope="row">Online</th>
      <td><a href="https://ico.org.uk/make-a-complaint" rel="noopener">ico.org.uk/make-a-complaint</a></td></tr>
    <tr><th scope="row">By post</th><td>The ICO moved offices during 2026.
      Rather than print an address that may be out of date, please take the
      current one from ico.org.uk or ask them on the helpline.</td></tr>
  </table>

  <h3>How we keep it safe</h3>
  <ul>
    <li>Two-step sign-in for every administrator, required by the system itself
      and not just by the page.</li>
    <li>The records cannot be read directly even by somebody inside the system;
      every route to them checks who is asking first.</li>
    <li>A list can never carry a medical note, an allergy or a SEND record.
      That is enforced in the database and checked automatically, not left to
      whoever writes the next screen to remember.</li>
    <li>Who looked at what, and when, is recorded.</li>
    <li>Information travels encrypted, and is stored encrypted.</li>
    <li>Deletion happens automatically on a schedule, so it does not depend on
      anybody remembering.</li>
  </ul>
  <p>If something does go wrong we have a written procedure for it. If a breach
     is likely to put you or your child at serious risk, we will tell you
     directly and tell you what to do. Where the law requires it we will also
     report it to the Information Commissioner within 72 hours.</p>

  <h3>Where this notice lives, and how you were told about it</h3>
  <p>This notice is published at
     <strong>taiyabahmasjid.com/madrasah-privacy</strong> and linked from the
     footer of every page. It is not handed out on paper as a matter of course,
     but ask at the office and you will be given a printed copy &mdash; you
     should not need a computer to find out what is held about your child.</p>
  <p>We will have told you it exists. Putting a notice on a website and waiting
     to be found is not telling anybody anything, and the law asks us to take an
     active step rather than a passive one. So when this notice is published,
     and whenever it materially changes, the masjid writes to parents once to
     say so and records the date it did.</p>
  <p>There is a second, separate notice covering the website itself &mdash; hall
     hire, nik&#0257;&#7717; requests, adult classes and the shop. It is at
     <a href="../#privacy">taiyabahmasjid.com/#privacy</a> and it does not cover
     the madrasah. This one does.</p>

  <h3>Changes to this notice</h3>
  <p>If we start holding something new, share records with somebody new, or keep
     them for longer, we will issue a new version of this notice and tell you
     before the change takes effect &mdash; not afterwards, and not by quietly
     replacing the page and hoping you look. The version number and date are at
     the top.</p>

  <h3>What this notice does not cover</h3>
  <p>This notice is about the madrasah&rsquo;s records only. It does not cover
     the masjid&rsquo;s website, donations and Gift Aid, hall hire,
     nik&#0257;&#7717; bookings, or the masjid&rsquo;s mobile app. Those are
     separate and have their own arrangements.</p>
  </div>

</main>

<footer class="wrap">
  <p>Version {{version}} &middot; issued {{issued}} &middot; next review
     {{review}}<br>
     Issued by the trustees of Bolton Central Islamic Society &middot;
     Registered charity 1041569 &middot;
     <a href="../">Taiyabah Masjid</a></p>
</footer>

</body>
</html>
"""

    #  THE ARTICLE 9 CONDITION FOR HEALTH DATA IS THE CONTROLLER'S DECISION,
    #  NOT THE BUILDER'S. Being on a madrasah roll implies religion and that is
    #  argued under 9(2)(d) above. Medical notes, allergies and SEND records
    #  are separately special category under Article 9(1) in their own right,
    #  and 9(2)(d) has to be argued for them rather than inherited. For a child
    #  collapsing in class the natural condition is 9(2)(c), vital interests.
    #
    #  Both are drafted. Which one the charity relies on is for the trustees
    #  and whoever advises them, so it is set here rather than assumed, and the
    #  page will not build without a choice being made.
    condition = os.environ.get("ARTICLE_9_CONDITION", "").strip()
    drafts = {
        "9(2)(d)":
            "This is health information, which the law protects separately "
            "(Article 9). We rely on the same condition as above &mdash; "
            "<strong>Article 9(2)(d)</strong> &mdash; because it is kept by a "
            "not-for-profit religious body about the children who come to it, "
            "and is not disclosed outside the masjid without your consent. We "
            "hold it only where a parent has told us, only what they told us, "
            "and only so that staff can look after your child safely.",
        "9(2)(c)":
            "This is health information, which the law protects separately "
            "(Article 9). We rely on <strong>Article 9(2)(c)</strong> &mdash; "
            "protecting the vital interests of your child &mdash; because the "
            "reason we hold it is that a member of staff may one evening need "
            "to act on it quickly. We hold it only where a parent has told us, "
            "only what they told us, and it is never included in any list, "
            "export or printed register.",
        "both":
            "This is health information, which the law protects separately "
            "(Article 9). We rely on <strong>Article 9(2)(d)</strong> &mdash; "
            "records kept by a not-for-profit religious body about the children "
            "who come to it, not disclosed outside without consent &mdash; and, "
            "where a child needs help urgently, on <strong>Article "
            "9(2)(c)</strong>, protecting their vital interests. We hold it "
            "only where a parent has told us, only what they told us, and it is "
            "never included in any list, export or printed register.",
    }
    if condition not in drafts:
        sys.exit(
            "Nothing was written.\n\n"
            "The Article 9 condition for the medical, allergy and SEND\n"
            "information has not been chosen. It is a controller's decision,\n"
            "not this script's. Run again with one of:\n\n"
            "  ARTICLE_9_CONDITION=9(2)(d)  python3 tools/build_privacy_page.py\n"
            "  ARTICLE_9_CONDITION=9(2)(c)  python3 tools/build_privacy_page.py\n"
            "  ARTICLE_9_CONDITION=both     python3 tools/build_privacy_page.py\n")

    #  TOKENS, NOT %-FORMATTING.
    #
    #  The template is a stylesheet as well as a document, and a stylesheet is
    #  full of per-cent signs: width:100%, 34%, 4.4vw. %-formatting read
    #  "100%;" as a format specifier and died on it. Escaping every one as %%
    #  would have worked and would have been a trap for whoever next edits the
    #  CSS, because forgetting it fails at build time with a message about
    #  format characters rather than about CSS.
    fields = {
        "version": VERSION, "issued": ISSUED, "review": REVIEW,
        "lead": lead_block,
        "hold": rows(WHAT_WE_HOLD),
        "nothold": not_held,
        "parent": rows(PARENT_HOLD),
        "staff": rows(STAFF_HOLD),
        "rights": rows(RIGHTS),
        "article9": drafts[condition],
    }
    out = page
    for key, value in fields.items():
        token = "{{" + key + "}}"
        if token not in out:
            sys.exit("The template has no %s to fill. Nothing written." % token)
        out = out.replace(token, value)

    #  THE WORDING AND THE GUARD MUST COVER THE SAME COLUMNS.
    #
    #  db/081 fails when the database holds something the notice does not
    #  describe. This fails when the NOTICE and the GUARD disagree about what
    #  that list is - the same fault one level up, and just as invisible: the
    #  guard would go on passing while the page said something else.
    in_guard, in_page = guard_columns(), described_here()
    if in_guard != in_page:
        missing = sorted(in_guard - in_page)
        extra = sorted(in_page - in_guard)
        sys.exit(
            "Nothing written. The published wording and the database guard do "
            "not cover the same columns."
            + ("\n  In db/081 but not described on the page: %s"
               % ", ".join(missing) if missing else "")
            + ("\n  Described on the page but not in db/081: %s"
               % ", ".join(extra) if extra else "")
            + "\n\nChange both, or neither.")

    #  A PAGE WITH A PLACEHOLDER LEFT IN IT IS WORSE THAN NO PAGE.
    for bad in ("______", "TODO", "{{", "XXX"):
        if bad in out:
            sys.exit("A placeholder (%r) survived into the page. "
                     "Nothing written." % bad)

    os.makedirs(OUT, exist_ok=True)
    open(os.path.join(OUT, "index.html"), "w", encoding="utf-8").write(out)
    print("  madrasah-privacy/index.html  %6d bytes" % len(out))
    print("  Article 9 condition: %s" % condition)
    print("  checked against the guard in db/%s" % (GUARD_FROM[-1] if GUARD_FROM else "?"))
    if not LEAD_NAME:
        print("  NOTE: no Data Protection Lead named; the page points at the "
              "office instead.\n        Set DP_LEAD_NAME, DP_LEAD_EMAIL and "
              "DP_LEAD_PHONE to name them.")


if __name__ == "__main__":
    build()
