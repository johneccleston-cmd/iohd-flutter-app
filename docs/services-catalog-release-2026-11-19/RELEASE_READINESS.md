# Services Catalog Phase 2: release-readiness review (2026-11-19, final)

**Status: reviewed and pushed to the feature branches only. NOT approved for merge or release.** Nothing here has been
merged into `main`, deployed or published, no production migration has run, and `SERVICE_CATALOG_V2` stays off.
Job/Estimate line editing stays a preview (never saved). Merging and deploying each need a separate approval
(section 11).

Approved on 2026-11-19: Decision A (the 5-newest-billed-lines / 30-day supersession rule, with the safeguards in
section 2), Decision C (the five-tier ranking, as documented and tested in section 2), regenerating the two Team
permissions goldens (help text only, section 10), and pushing both feature branches. Approved after the push: the
**final ranking rule**, under which a billed service always ranks above a never-billed one (section 2). It is built and
tested, then committed and pushed to the feature branches after your review (backend `d311619e`).

## 1. What is being released

| Repo | Branch (local = remote feature branch) | Head | Base it was cut from |
|---|---|---|---|
| integrity-backend | `services-catalog-phase1` → `origin/services-catalog-phase1` | `d311619e` | `030f3b90` (= `origin/main` on 2026-11-19) |
| iohd_desktop (app) | `services-catalog-phase1` → `origin/services-catalog-phase1` | `cba712a` (code and tests), plus the commit that adds this revision (docs only) | `26b798e5` (`origin/main` is `7a2d7f0`) |

Backend commits on the branch, oldest first:

| Commit | What | Pushed before today? |
|---|---|---|
| `9539f17e` | Services Catalog Phases 1-2 (2026-11-18) | yes (the remote branch's head this morning) |
| `0e641757` | Decisions A and C (2026-11-19) | no |
| `29b2d14d` | Decision C: the ranking comment states tier 5's floor (0) and the tie-breaks; three tests pin them. No behaviour change | no |
| `d311619e` | The final ranking rule: `billedServicesFirst` in `src/catalog.js`; four tests updated and five added in `test/service_catalog_takeover_ranking.test.js` | no (pushed with this revision) |

App commits on the branch, oldest first:

| Commit | What | Pushed before today? |
|---|---|---|
| `e53a1ef` | Services Catalog Phase 2 app (2026-11-18) | yes (the remote branch's head this morning) |
| `08f74c5` | Decision A in the app; two stale Phase 2 tests updated | no |
| `ffe3376` | This review, first revision (docs only) | no |
| `cba712a` | The two Team permissions goldens regenerated; a test that the page search finds a superseded service by its old name | no |
| (this revision) | This review, final revision (docs only) | no |

**Production effects already identified** (from the read-only checks of 2026-11-19; details in the sections named):
- Backend deploy, V2 still off: two nullable columns on `record_line_items` (section 4); five saved non-admin lists
  (ids 31, 34, 36, 37, 40) get the Services Catalog page switched off (section 5); three old per-type service rows go
  from taxed to untaxed by the "No Sales Tax Applied" rule, and no Product Catalog product changes (section 7); the
  current web app shows those five people a load error on the Services Catalog page until the new app is published.
- Enabling V2 later (its own approval): the picker serves per-item services ranked by Decision C; two entries are
  superseded and not offered (10792835 Commercial Service Call, 10792892 Commercial Service Labor; section 2).
- Never: no saved job/estimate line rewritten, nothing written to Service Fusion, nothing deleted (sections 2 and 9).

`main` in the app repo is one commit ahead of the branch base (`7a2d7f0`, the Stock Levels audit): 47 added files under
`docs/stock-levels-audit-2026-11-18/`, none of which the Services branch touches, so the merge is conflict-free. Backend
`main` is still the branch base. The remote feature branches were the 2026-11-18 heads (`e53a1ef`, `9539f17e`) when
checked before the push, and both pushes were fast-forwards.

## 2. The decisions of 2026-11-19, as built

### Decision A: superseded originals

Rule (`takeoverTest`, `src/serviceCatalog.js`), worked out on every catalog build. Within one Service Fusion rate id
(the original item plus its renamed variants), one entry **takes over** and every other entry of that rate id that
has stopped is **superseded** when all three hold:

1. the taker is a verified replacement: it offers its own usual price (settled, no recent price change) and is a priced
   entry of its own (a variant that passed the variant test, or the original);
2. the taker has every one of the rate id's **5 newest billed lines**;
3. the superseded entry's newest billed line is **more than 30 days** older than the taker's.

A superseded entry is `active: false` (the picker lists active entries only), carries `supersededBy {key, name}` and
the flag `superseded`, and keeps everything else: billed history, median, range, Service Fusion rate id, aliases,
variant links, quotes, the item detail route. The taker carries `replaces [{key, name}]`, and the replaced entries'
names and aliases are added to its search terms (`formerNames`), so typing the old name finds the replacement.
Nothing is deleted, nothing is written to Service Fusion, and saved job/estimate lines are never read or rewritten.
If a superseded name is billed again, the test fails on the next build and the entry is offered again.
How it looks (test renders, fixture data): `services_catalog_page_1366.png` (the superseded row last, muted, "Not
offered", history kept; its replacement says "Replaces …") and `picker_replacement_row.png` (the add-line picker).

**Production today (read-only, 2026-11-19):** exactly the two entries the decision names are superseded.

| Rate id | Superseded (kept, not offered) | Replacement (offered) | Original last billed | Replacement newest | Gap |
|---|---|---|---|---|---|
| 10792835 | Scope of Work \| Commercial Service Call ($199) | Commercial Service Dispatch & Evaluation ($109) | 2026-09-15 | 2026-11-13 | 59 days; 12 billed in a row |
| 10792892 | Commercial Service \| Labor \| Per Technician \| Per Hour ($99) | Commercial Service Labor \| per hr, per technician ($155) | 2026-09-15 | 2026-11-13 | 59 days; 10 billed in a row |

Not superseded, both still offered: Door Removal (10793054: the $59 original billed 2026-10-29, inside the newest 5)
and Operator Installation (11258524: the original billed most recently, 2026-10-30). Every other rate id was screened
in SQL for "the newest 5 billed lines are one renamed line": two more matched, and neither is a priced variant
(10792855 Panel -> Section Replacement is not settled, 33% within +/-5%; 11274174 LENNAR 16x7 rename bills the same
$300, so it stays an alias).

**Final rule (approved 2026-11-19).** The thresholds are fixed at **5 newest billed lines** and **more than 30 days**.
Two consequences of the rule, as built, both inside one rate id:
- The item's name is its most common billed name. As the 18-month window rolls, the Dispatch rename will out-bill
  the old name (about spring 2027) and the two swap places: the old $199 name becomes the "variant". The rule therefore
  lets the original be the taker too, so the old name stays retired instead of coming back as a variant.
- By the same rule, a short-lived rename the office stopped using is retired while its original carries on.

**Safeguards and where each is enforced.**

| Safeguard | As built | Test (backend `test/service_catalog_takeover_ranking.test.js` unless named) |
|---|---|---|
| Retire only with a genuine replacement | Taker and superseded entry share one Service Fusion rate id; the taker has its own settled usual price, no recent price change, and all 5 newest billed lines | "A boundaries", "A: an unverified replacement never retires the original" |
| Never retire on low use alone | No use count appears in the rule; a rate id with one entry (no variant) can never supersede anything; different rate ids are never compared | "A: both renamed lines still in use", "A boundaries" |
| Never delete history, prices, SF ids, variant links, saved lines | Superseded = `active: false` + `supersededBy`; every field stays; the catalog sends no write statement and never reads `record_line_items` | "A: nothing is written" (records every SQL statement) |
| Superseded stays visible and searchable by old names | Services Catalog page lists it (last, "Superseded by …", "Not offered", history kept) and its own search finds it by name; the picker finds its replacement by the old name and its aliases | "A in the picker"; app `test/services_catalog_test.dart` "a superseded service is kept…" (page search added today) |
| Comes back if billed again | Worked out on every build | "A: billed again under the original name, the original is offered again" |
| V2 off = no effect | The picker serves the old per-type rows | "A off" |

Production effect: only the two entries above are superseded (the read-only check made earlier on 2026-11-19; it was
not re-run in the final pass, and it must be re-run before V2 is enabled, section 11 step 5).

### Decision C: search ranking (approved 2026-11-19; exact rules)

Code: `serviceMatchScore`, `SERVICE_TIER` and `searchCatalog` in backend `src/catalog.js`. It applies only to per-item
services (entries with a `group`, served when `SERVICE_CATALOG_V2` is on). With V2 off none of this is reached: the
picker serves the old per-type service rows, scored as before.

**Which entries are ranked at all.** The search text is lower-cased, trimmed and its spaces collapsed; it is split into
words. A service is a result only when **every word** appears somewhere in its name, SKU, category/group, the other
names it was billed under (aliases) or the names of entries it replaced (`formerNames`). Superseded services are not
in the picker's list, so they are never ranked. "Whole" below = the full search text; names have leading symbols
removed ("+ Travel Charge" = "travel charge").

**Definitions.** *Billed* = at least one billed line in the catalog's 18 months (`uses > 0`); *never billed* = only
quoted, billed at $0, or nothing (`uses = 0`). *Warned* = billed, and the price status is not `settled` (recent price
change, price varies, billed once) or the tax default is `mixed`.

**The five tiers, in order** (score, then the use bonus = min(billed lines, 200) / 4, so at most +50):

| Order | Tier | Matching criteria (first that applies) | Score | With use |
|---|---|---|---|---|
| 1 | Exact, settled | name = whole; billed; settled price; tax not mixed | 500 | 500-550 |
| 2 | Exact, warned | name = whole; billed; warned (see above) | 440 | 440-490 |
| 3 | Strong, billed | billed, and: group = whole **380**; else name starts with whole **300**; else group starts with whole **260**; else name contains whole **220**; else an alias or replaced name = whole **160** | 160-380 | 160.25-430 |
| 4 | Exact, never billed | name = whole; never billed | 150 | 150 (no use) |
| 5 | Everything else | a tier-3 match that was never billed **80**; else a word of the name starts with the first search word **60**; else an alias or replaced name starts with whole **40**; else (found only through the group, SKU or scattered words) **0** | 0-80 | 0-110 |

Tiers never cross: 490 < 500, 430 < 440, 150 < 160.25 (a billed service has at least one line), 110 < 150. Inside
tier 3 the strengths can cross by use (for example a group that starts with the search, 260 + 50, passes a name that
starts with it, 300 + 0.25), except that an alias or replaced name tops out at 210, below "name contains" (220), so a
rename never outranks a match on an item's own name.

**Ties.** Higher total score first; equal totals sort by name A-Z (`localeCompare`); equal score and name keep the
catalog's build order (the sort is stable): most billed lines (not capped), then most quotes, then group A-Z
(`serviceCatalog.js` `buildItems`).

**The final rule: billed services first** (approved 2026-11-19, after the push; `billedServicesFirst`). After the
tier sort, every never-billed per-item service that sits above a billed per-item service moves down to just below the
lowest-ranked billed one, keeping its order among the never-billed. Nothing else moves. In effect the service order is:
tiers 1, 2, 3, the billed part of tier 5, then tier 4, then the never-billed part of tier 5. Scores, tiers, matching
criteria and tie rules are unchanged, and the picker's limit (25, at most 40) is applied after the rule.

**Never-billed services.** Always found when every word matches, never hidden, and always after **every** billed
service in the results, whatever the match. When no billed service is in the results, they keep their old places
(searched on its own, a never-billed service is the first result).

**Exact-name collisions** (several services with the name = the search, e.g. the same name under two Service Fusion
types): settled billed first (tier 1), then billed with a warning (tier 2), then billed strong matches (tier 3), then
billed weak matches, then the never-billed exact names (tier 4), then never-billed strong and weak matches. Inside a
tier, more use first, then the tie rules. Case, extra spaces and leading symbols don't change the order.

**Recent price change.** Ranks in tier 2: below a settled exact match whatever its use, above every non-exact billed
match. No price is filled in (`usualPrice`/`rate` null); the picker row says "Recent price change", and the line editor
shows the 18-month median and the newest billed prices with "No price is filled in; check it before quoting."
(`catalog_search_field.dart`, `line_items_editor.dart` `_catalogHints`). Material = at least 4 billed lines, each of
the 3 newest more than 5% from the 18-month median, and a shift rather than ordinary variation (Phase 2 Decision 2).
Price varies, billed once and tax varies rank in tier 2 the same way and show their own hint.

**Products unchanged.** Products (and the old per-type service rows) are scored exactly as before Phase 2: SKU = search
+1000, SKU starts with +600, name = search +500, name starts with +300, a word starts with the first search word +100,
plus the same use bonus. The "Product Catalog boundary" test (`test/service_catalog_access.test.js`) compares 14
queries against a copy of the pre-Phase-2 function and gets the same order. The service tiers sit on the products'
scale, so a product named exactly as the search (500+) and a tier-1 service interleave by use. The final rule never
moves a product or a billed service: products keep their order among themselves and against every billed service, and
the old per-type service rows (V2 off) are not touched by it.

#### Ranking before and after the final rule

| Case | Before (`29b2d14d`) | After (`d311619e`) |
|---|---|---|
| Billed exact (tiers 1, 2) and billed strong (tier 3) | above every never-billed service | unchanged |
| Billed weak (tier 5, 0-110) vs never-billed exact (tier 4, 150) | never-billed exact first | **billed weak first** |
| Billed weak vs never-billed strong (tier 5, 80) | by score: never-billed first unless the billed one had more than 80 lines ("word starts") or 160 ("alias starts"); a group-only match never | **billed weak first, always** |
| Billed weak vs never-billed weak (60 / 40 / 0) | by score: either could be first | **billed weak first, always** |
| Never-billed among themselves | exact 150 > strong 80 > word 60 > alias 40 > 0, then A-Z | unchanged |
| A never-billed service vs a product | by score | unchanged unless a billed service ranks below that product; then the never-billed service moves below the billed one (so below that product too) |
| Products among themselves, and vs billed services | by score | unchanged |
| Ties, recent price change, warnings | as above | unchanged |
| V2 off (old per-type rows) | as before Phase 2 | unchanged |

Examples: "service call \| dispatch & evaluation" used to list a never-billed exact name above the billed
"Evaluation & Dispatch \| Service Call" (every word, not the name); it now lists the billed one first. For
"commercial tune", a never-billed "Commercial Tune-Up Visit" (80) used to sit above the billed "Tune-Up \| Commercial"
(60 + use) and the billed "Tune-Up" in group "Commercial Service" (0 + use); both billed ones now come first.

Why it isn't done by lowering the never-billed scores: billed weak matches start at 0.25 (0 + one line), so every
never-billed score would have to go below that. That would also drop never-billed services below **every** matching
product, even with no billed service in the results, and on busy searches they could fall off the 25-row picker. The
rule above moves them only as far as it must.

Test cases (`test/service_catalog_takeover_ranking.test.js`):

| Case | What it pins down |
|---|---|
| Exact-name collision (updated for the rule) | Three services named the same: settled first, recent-change second, a billed "starts with" third, the billed fuzzy match fourth, the never-billed one last; case, spaces and leading symbols don't matter |
| Never-billed services (updated) | "Spring Replacement" (never billed) below every billed match, including the billed fuzzy one; still found; first when it is the only match |
| Recent price change | Below the settled exact match, above every non-exact billed match (even with 200 uses); its rate stays null |
| Other warnings | Price varies, billed once, tax varies and recent change each rank in tier 2 |
| Tiers never cross (updated) | Tier score bounds asserted; one service per tier with the most use in the lower tiers sorts 1, 2, 3, then the billed tier-5 one, then the never-billed tier-4 one |
| Renamed variants | Door Removal: each exact name ranks its own item first. Dispatch: the old name and the old alias find the replacement first; a replacement never outranks an active item whose own name matches; the superseded original never appears |
| Built from real lines | Via `buildItems` + `pickerEntry`: a never-billed exact name sits below the billed strong match |
| Ties (added in the final pass) | Equal scores sort A-Z; equal score and name keep input order; use counts up to 200 lines |
| Tier 3 strengths (final pass) | Use can lift a group-starts match past a name-starts match; an alias/replaced name stays below "name contains" |
| Tier 5 floor (updated) | A match only through the group scores 0 + use and still ranks above a never-billed strong match; one billed line is enough; a missing word is no match |
| Rule: weak billed > never-billed exact (new) | Billed group-starts, word-starts and scattered matches with one line each all rank above a never-billed exact name |
| Rule: weak billed > never-billed strong (new) | A billed word-starts match (one line) ranks above never-billed name-starts and group-is matches (A-Z between those two) |
| Rule: billed exact/strong keep priority (new) | Settled, warned (by use), recent change, strong, weak, then never-billed exact, strong, weak; removing the never-billed changes nothing for the billed |
| Rule: never-billed discoverable (new) | Alone or among other never-billed: as before; with only products, keeps its place above a weak product; with a billed service, after it but still listed; the limit drops never-billed first |
| Rule: products unchanged (new) | Products and billed services in exactly the order of the same search without the never-billed; the never-billed right after the last billed service; an old per-type row (V2 off) stays put |

Decision A cases in the same file: both production cases; both "still in use" cases; the 5-newest and 30-day
boundaries (30 days exactly = not yet; 31 = superseded); an unverified replacement (recent price change) never retires
anything; billed again = offered again; input order never changes the outcome; the swap; the picker and list routes
for an admin and for someone who edits lines without the page; no write statement is ever issued.

## 3. Backend and app compatibility

- **Picker contract.** Every field `pickerEntry` sends is read by `CatalogEntry.fromJson`, including the new
  `active`, `supersededBy`, `replaces`; `formerNames` is search-only and the app ignores it. An older server sends none
  of them and the app treats every service as active (tested).
- **Services Catalog page.** The app now asks `/api/catalog/list?kind=service&includeInactive=1`, so superseded
  entries stay on the page (listed last, "Superseded by …", "Not offered" in Usual Price, history kept); the stats
  count offered services only. An older server ignores `includeInactive` for services.
- **Shared line-item math fixture** (`scripts/line_item_math_cases.json` and `test/fixtures/line_item_math_cases.json`):
  byte-identical at both commits (md5 `4c09179a5aa5dd9092f3983e1173f80b`).
- **Permission keys.** The backend test that parses the app's `access.dart` passes against the app branch
  (`IOHD_APP_DIR` pointed at the app worktree): same resources, same actions, same default-off set.
- **confirm-zero.** App `POST /api/jobs/:jobId/options/:id/items/:itemId/confirm-zero {version}` matches the route.
- **Mixed versions.** The backend can run with the currently published app: V2 off keeps the old per-type services;
  the only visible change is that the five saved users get a 403 on the Services Catalog page, which the old app shows
  as a load error rather than the new "no access" state. The new app must not be published before the backend
  (confirm-zero would 404 and `includeInactive` would have no superseded rows to show). Order: backend first.

## 4. Database migrations

Both run automatically at start-up; nothing else in the schema changes. The catalog code only reads.

```sql
-- (a) src/line_items.js ensureSchema: two nullable columns. Metadata-only in Postgres (no default, no rewrite);
--     the 13 saved lines get NULL. IF NOT EXISTS makes it idempotent.
ALTER TABLE record_line_items ADD COLUMN IF NOT EXISTS zero_price_confirmed_by TEXT;
ALTER TABLE record_line_items ADD COLUMN IF NOT EXISTS zero_price_confirmed_at TIMESTAMPTZ;

-- (b) src/admin_users.js addAccessKeysOffOnce('2026-11-18-services-catalog-off'): once, in one transaction, rows locked.
INSERT INTO app_migrations (name) VALUES ('2026-11-18-services-catalog-off') ON CONFLICT DO NOTHING RETURNING name;
-- only if that inserted a row:
SELECT id, role, access_denied FROM users WHERE access_denied IS NOT NULL ORDER BY id FOR UPDATE;
-- for each non-admin row: access_denied := sorted(distinct(access_denied + {'services_catalog.view'}))
UPDATE users SET access_denied = $2 WHERE id = $1;
```

Expected log line: `🔐 [ACCESS] The Services Catalog switch added as OFF to 5 saved permission list(s) (2026-11-18-services-catalog-off).`

**Production state before deploy (read-only, 2026-11-19 13:39 UTC):** `app_migrations` holds only
`2026-11-10-admin-switches`; the two columns don't exist; `record_line_items` has 13 lines on 4 options (last change
2026-11-12), none at $0, 9 with old `sf:` keys, none with `sfr:` keys.

Fingerprints over today's columns (re-run after deploy; they must not change):

```sql
SELECT md5(string_agg(concat_ws('|', id, option_id, position, kind, name, description, sku, unit, quantity, rate, cost, taxable,
           inventory_item_id, catalog_key, catalog_rate, catalog_cost, source, created_at), E'\n' ORDER BY id)) FROM record_line_items;
-- 726b6b97c9d2541c0e96c2646d26b2c8
SELECT md5(string_agg(concat_ws('|', id, job_id, kind, name, position, is_recommended, tax_rate, notes, version, source,
           accepted_at, converted_job_id, updated_at, deleted_at), E'\n' ORDER BY id)) FROM record_options;
-- 2fe3364705f8b181a871cad4d23edb38
```

**Rollback.**
- (a) Leave the columns: they are nullable and the old code never reads them. Only if they must go, after the code is
  rolled back: `ALTER TABLE record_line_items DROP COLUMN IF EXISTS zero_price_confirmed_at, DROP COLUMN IF EXISTS zero_price_confirmed_by;`
  (this loses any $0 confirmations made in between).
- (b) Needed if the backend is rolled back: the old server doesn't know `services_catalog.view` and refuses a Team save
  that contains it, so any edit to those five people's permissions would fail. Snapshot first, then:
  ```sql
  -- before deploy: keep this output
  SELECT id, access_denied FROM users WHERE access_denied IS NOT NULL ORDER BY id;
  -- rollback
  UPDATE users SET access_denied = array_remove(access_denied, 'services_catalog.view') WHERE access_denied @> ARRAY['services_catalog.view'];
  DELETE FROM app_migrations WHERE name = '2026-11-18-services-catalog-off'; -- so a later re-deploy runs it again
  ```

## 5. Permission migration: the five saved non-admin lists

Production (read-only, 2026-11-19). Each list has 53 keys switched off, already including Product Catalog, Line Items
& Costs > View and Line Items & Costs > Update. None has `services_catalog.view` yet; today's server doesn't know the
key, so nothing stops the Services Catalog page for them.

| Id | Person | Role | After the migration |
|---|---|---|---|
| 31 | Dennis Gray | warehouse | Services Catalog page hidden (nav) and refused (403) until an admin grants it |
| 34 | Heather Vera | Office Manager | same |
| 36 | Zac Clemens | Sales Rep | same |
| 37 | Bella Hansberger | Office | same |
| 40 | Warehouse (shared login) | Warehouse | same |

Picker: no practical change for any of them. Services reach the add-line picker only with the page or Line Items &
Costs > Update, and all five already have Update off, which also keeps the line editor closed to them.

Lists never saved (NULL), who get the defaults: John Eccleston (Admin) and Ryan Schwartz (Owner) are admins and keep
everything. Daniel Baty and Nick Smith (Lead Technician) can't sign in to the office app (technician roles, both app
and server). Charlotte Miller (Office, inactive) would start with the Services Catalog off if reactivated.

## 6. Page access vs picker access

| Who | Services Catalog page | Services in the picker | Costs |
|---|---|---|---|
| Admin / Owner | yes | yes | yes |
| Page switch on | yes | yes | per Line Items > View |
| Page off, Line Items > Update on | 403 | yes | per Line Items > View |
| Page off, Line Items > Update off (the five) | 403 | no | per Line Items > View |
| Never saved | off by default | off by default | off by default |
| Technician | refused by the office app | refused | refused |

`canSeeServicesPage = services_catalog.view`; `canPickServices = page || line_items.update` (`src/catalog.js`).
`/api/catalog/list?kind=service` and `/api/services/catalog*` follow the page; `/api/catalog/search` follows
`canPickServices`; products are never affected. Covered by `test/service_catalog_access.test.js` and
`test/service_catalog_routes.test.js`, and the app side by `test/nav_session_test.dart` and
`test/services_catalog_test.dart` (403 = "no access" state).

## 7. Product Catalog regression

- Backend: every Product Catalog test has the same result as on `main`. The two that fail do so on `main` too
  (CRLF in a fixture on this Windows checkout; "a product edited in the app keeps every edit"). The "Product Catalog
  boundary" test (products rank exactly as the pre-Phase-2 code for 14 queries) passes.
- App: no Product Catalog test changed result.
- **Tax-code correction** (approved; `src/sfTax.js`: "No Sales Tax Applied" is exempt, not taxed), measured on
  production: 135 lines carry that code, **0 of the 829 Product Catalog products** change their taxable flag, and
  3 old per-type service rows (live while V2 is off) go from taxed to untaxed:
  "LiftMaster | 14' TDC7S1BMC Trolley Operator Installation | Taxable" (2 lines, 1 now taxed),
  "LiftMaster | 7' 84505 Operator Installation | Taxable" (1 line) and "Operator Installation" (1 line). The names
  say "Taxable" but Service Fusion billed them exempt; the rule reads the code, never the name.

## 8. Job and Estimate editor

- Editor test files (`line_items_editor_test`, `line_items_zero_price_test`, `line_items_round2_test`,
  `line_item_math_test`, `estimate_pdf_test`, `service_picker_test`, `service_catalog_entry_test`): all pass.
- Two Phase 2 tests had not been updated for its approved margin rule and failed on the Phase 2 head (they pass on
  `main`); both now pass:
  - `job_page_behavior_test`: the Service Fusion tab now shows profit "—" and "1 line has no cost" (the install line's
    cost is 0 = not entered) instead of $591.12 / 36.4%.
  - `line_items_final_test` (1920 wide): the seeded options had no costs, so their tabs lost the margin and all fit;
    the fixture now gives them a cost so the "+N more" case is still exercised.
- Saving stays off: the line editor's Save is a preview (`_previewSave` only marks "save asked"); nothing posts
  line edits. Write paths that exist on saved options: rename, delete, accept, unaccept (already on `main`) and Phase
  2's confirm-zero, which only stamps who/when on a saved $0 line. Production has no saved $0 lines, so it has nothing
  to act on; it needs Line Items & Costs > Update plus Jobs/Estimates > Update.

## 9. Saved jobs and estimates stay unchanged

- No code path rewrites `record_line_items` except confirm-zero (above) and the option actions already on `main`.
- The column migration doesn't rewrite rows; the permission migration touches `users.access_denied` only.
- The catalog only reads: a test records every SQL statement the picker, list and Services Catalog routes send and
  finds no INSERT/UPDATE/DELETE and no `record_line_items` access.
- Copying Service Fusion items into an option (an explicit action) now keys service lines `sfr:<rate id>`; existing
  lines keep their keys (`sf:`), which are informational only.
- Nothing is written to Service Fusion.
- Post-deploy check: the two fingerprints in section 4.

## 10. Test results (final pass, 2026-11-19)

Run on this Windows machine; the Linux VM was not available (section 15).

| | |
|---|---|
| OS | Windows 11 Pro 10.0.26300 |
| Flutter | 3.47.4 stable (framework 9584c6713b, 2026-09-10), Dart 3.13.3 |
| Node / npm | v24.14.0 / 11.12.1 (production runs Node 22) |
| Postgres for SQL tests | 18.6, a throwaway cluster on 127.0.0.1:54329 created in a scratch folder for this run (never production) |
| Trees | the two Services worktrees (`C:\Users\opera\integrity-backend-services-phase1`, `C:\Users\opera\iohd-flutter-app-services-phase1`) and clean detached comparison worktrees at backend `030f3b90` and app `7a2d7f0`, in a scratch folder. `C:\iohd_desktop` was not used or changed |

**Flutter full suite.** Command: `flutter test --reporter expanded` (in each tree).

| Tree | Passed | Skipped | Failed |
|---|---|---|---|
| `main` 7a2d7f0 | 1,887 | 12 | 81 |
| Phase 2 head e53a1ef (first review) | 1,919 | 12 | 85 |
| First review 08f74c5 (first review) | 1,925 | 12 | 83 |
| **Final `cba712a`** | **1,927** | **12** | **81** |

The 81 failing tests on the final branch are **the same 81, name for name**, as on `main` (stale goldens and
date-dependent tests: calendar, payroll, commission dashboard, job detail, inventory, Jarvis and others; known per
CLAUDE.md, none in a file this branch changes). **No new failure.** The two Team permissions goldens now pass. The
page-search check added to `test/services_catalog_test.dart` passes inside its existing test.

**Team permissions goldens** (`flutter test test/team_permissions_render_test.dart --update-goldens`, then the same
without the flag: 3 passed). Only `test/shots/team_permissions.png` and `team_permissions_900.png` changed; no other
golden was regenerated or accepted (the file has only these two). Checked pixel by pixel before accepting:
- 1440 x 5000: identical above the Services Catalog row; the help text wraps to a second line; everything below is
  identical once moved down 16 px (one line); the bottom identical.
- 900 x 5600: the only differing pixels are the two help lines (x 372-551); the checkbox column is unchanged.
- Bella's saved switches still read through (the test's own assertions), and Services Catalog is ticked in both,
  because her saved list doesn't deny it. `defaultOff` only affects never-saved lists, which the
  "someone never saved" test covers (it passes).

**`flutter analyze`**: 22 issues (20 infos, 2 warnings, no errors) on both `main` and the branch; none in a file this
branch changes. (CLAUDE.md asks for a clean analyze; `main` isn't clean either.)

**Web release build** of the final branch: `flutter build web --release --output <scratch folder>`. It compiled in 56 s,
`main.dart.js` is 6.40 MB, and `node --check flutter_bootstrap.js` passes. It was not built into `build/web_release` and
not copied to the backend.

**Backend full suite.** Command: `TEST_DATABASE_URL=postgres://tester@127.0.0.1:54329/iohd_test node --test
--test-concurrency=1 test/*.test.js` (run one after the other, on an idle machine).

| Tree | Tests | Passed | Failed | Skipped |
|---|---|---|---|---|
| Baseline `main` 030f3b90 | 589 | 576 | 13 | 0 |
| First review 0e641757 (first review) | 679 | 667 | 12 | 0 |
| **Final `29b2d14d`** | **682** | **669** | **13** | **0** |
| Final, the keys test pointed at the app branch | | +1 | **12** | |

Failure-by-failure: the branch fails exactly the tests `main` fails. The one extra failure in the plain run is "the
keys match the office app": by default it parses `C:/iohd_desktop/lib/config/access.dart` (`main`'s copy, which doesn't
know `services_catalog`). Run with `IOHD_APP_DIR=C:/Users/opera/iohd-flutter-app-services-phase1` it passes, as it does
once the app branch is merged. The shared failures are environmental on this machine, the same as in the first review:
the Jarvis payroll what-if tests in `assistant_review_sql.test.js` ("payroll_preview: The database query failed"
against Postgres 18; the runner counts the parent and its subtests), two payments-list tests, the callback-rate test
(date-dependent), the commission "jobs that paid nothing" test, and two Product Catalog tests (a fixture checked out
with CRLF line endings; "a product edited in the app keeps every edit"). The three new tests are the Decision C
documentation tests (section 2); the ranking file passes 20 of 20.

**Final ranking rule (`d311619e`).** Backend only; the app, its goldens and the web build don't change.

| Run | Command | Tests | Passed | Failed | Skipped |
|---|---|---|---|---|---|
| Ranking file | `node --test test/service_catalog_takeover_ranking.test.js` | 25 | 25 | 0 | 0 |
| Focused Services set | `IOHD_APP_DIR=<app worktree> node --test` on `service_catalog_takeover_ranking`, `service_catalog_access`, `service_catalog`, `service_catalog_phase2`, `service_catalog_routes`, `service_catalog_sql`, `action_permissions` (no database) | 89 | 84 | 0 | 5 (the SQL file needs `TEST_DATABASE_URL`) |
| **Full suite** | `TEST_DATABASE_URL=… IOHD_APP_DIR=<app worktree> node --test --test-concurrency=1 test/*.test.js` | **687** | **675** | **12** | **0** |

Against the pushed branch (`29b2d14d`: 682 / 669 / 13) and `main` (589 / 576 / 13): no test fails now that passes on
either. The 12 are the same environmental failures listed above; "the keys match the office app" passes because this
run points it at the app branch. The five extra tests are the new rule tests. With the rule in place, four earlier
tests failed because they pinned the old order (a never-billed match above a billed weak one). They were updated
to the approved rule: exact-name collisions, never-billed services, tiers never cross, and tier 5 floor. The Product
Catalog boundary test passes unchanged.

## 11. Next steps: merge, deployment order, checks and rollback

Each step needs its own approval; none has been given. Pushing the feature branches (done) deploys nothing: Render
deploys `main` only, and previews are off.

Before the merge:
- **Re-check the base.** `git fetch`; backend `origin/main` must still be `030f3b90` and app `origin/main` `7a2d7f0`
  (or re-run the suites on whatever they have become).
- **Coordinate with the uncommitted Product Catalog work** in `C:\iohd_desktop` (section 14). Don't merge the app branch
  in that working tree while it has uncommitted changes.

0. **Before deploy.** Confirm in the Render dashboard that `SERVICE_CATALOG_V2` is not set (it can't be read with the
   tools used here). Save the permission-list snapshot and re-run the fingerprints (section 4).
1. **Backend.** Merge `services-catalog-phase1` into `main` (a fast-forward while `main` is `030f3b90`) and push: this is
   the deploy. Start-up adds the two columns and runs the permission migration.
2. **Check the backend.** The log line above; `app_migrations` has `2026-11-18-services-catalog-off`; the five lists
   contain `services_catalog.view`; both fingerprints unchanged; `/api/catalog/search?q=spring` returns the same
   products as before; with V2 off, services are the old `sf:` rows.
3. **App.** Merge the app branch into `main` (a merge commit: `main` has `7a2d7f0`, docs only, no overlap), re-run
   `flutter analyze` and the suite, `flutter build web --release --output build/web_release`, check that
   `flutter_bootstrap.js` parses, copy into `integrity-backend/src/public`, push the backend (a deploy).
4. **Check the app.** Services Catalog page for an admin; the "no access" state for one of the five; Edit Job/Estimate
   still a preview; Product Catalog unchanged.
5. **SERVICE_CATALOG_V2** (a later, separate approval): first run `node scripts/service_catalog_preview.js --db`
   (read-only transaction) and check that the variants, recent changes and the two superseded entries are as listed
   here; then set the variable. Check the picker for "commercial service".

**Rollback.**
- V2: unset `SERVICE_CATALOG_V2` (restart): the picker goes straight back to the old per-type rows.
- App: re-publish the previous web build (revert the publish commit in `integrity-backend/src/public`).
- Backend: revert the merge on `main` (auto-deploys), then run the permission rollback SQL in section 4; leave the two
  columns.

## 12. Stock Levels untouched

- Backend: the Services branch changes 19 files (`src/serviceCatalog.js`, `catalog.js`, `sfTax.js`, `accessKeys.js`,
  `admin_users.js`, `line_items.js`, `lineItemMath.js`, scripts and tests). The `stock-phase1` branch changes
  `src/inventory.js`, `src/stockQuantity.js`, `src/stockSheet.js` and three stock tests. No file in common; both
  branch from `030f3b90`; `stock-phase1` (983535d7) is untouched.
- App: no Stock Levels or inventory file is changed (the Services files are the line-item editor, the catalog search
  field and API, the Services Catalog page, `access.dart`, and their tests).
- Behaviour: the services code reads only `jobs.raw_items`; the Product Catalog's inventory linking is unchanged; the
  catalog's only query change is the tax expression.

## 13. Open items for the release decision

Closed on 2026-11-19: the takeover thresholds and generalizations (Decision A approved), the five tiers (Decision C
approved), the Team permissions goldens (regenerated, section 10).

1. **Final ranking rule**: decided (billed always first), built, tested (section 10), committed (`d311619e`) and pushed
   to the feature branch.
2. **Linux VM validation** has not been done (section 15).
3. A variant's key follows the most common billed name, so after the Dispatch swap (about spring 2027) the keys move:
   `sfr:10792835` will mean the $109 service. Saved lines keep their old keys, which are informational only.
4. Mixed-version window: until the new web build is published, the five saved users see a load error on the Services
   Catalog page instead of the "no access" state.
5. At 900 px the Team screen shows the new Services Catalog help in two lines, cut off ("…Anyone who can edi…"); the
   full text shows at 1,440 px (two lines). This is the approved wording, so it was not changed here.

## 14. Merge-conflict warning: `lib/services/line_items_api.dart`

Another session's **uncommitted** Product Catalog work in `C:\iohd_desktop` (on `main`) also changes
`lib/services/line_items_api.dart` (+8/-4: `CatalogEntry.hasBorrowedCost` and a `dropBorrowedCost` option on
`withChange`). This pass did not touch that working tree. A three-way merge of copies (base `7a2d7f0`, this branch, a
read-only copy of that working file) merges **cleanly with no conflict**, and the merged `withChange` still copies every
field this branch adds (`priceStatus` … `supersededBy`, `replaces`). Its other changed files (`lib/main.dart`,
`lib/product_catalog_screen.dart`, `lib/utils/product_csv.dart`, `lib/widgets/page_selection.dart`, Product Catalog
tests and goldens) aren't touched by this branch. Risks that remain:
- the other session may change the file again before it commits: re-check when both are ready;
- whichever lands second must re-run `flutter analyze` and the Product Catalog and line-item tests on the merged tree;
- don't resolve it by editing the other working tree: commit the Product Catalog work first (its own approval), then
  merge this branch into `main`.

## 15. Linux VM limitation

The Linux VM used for Phases 1-2 is not reachable from this machine, and its Phase 2 review
(`audits/services-catalog-2026-11-18/PHASE2_REVIEW.md`) was never pushed. **Linux VM validation has not been
completed**, and nothing here claims it passed. No remote access was attempted and no VM setting was changed.

Verified on Windows (this machine, section 10): the backend full suite on Node 24 with a scratch Postgres 18.6; the
Flutter full suite, `flutter analyze` and the web release build on Flutter 3.47.4; the golden comparison; the
merge-conflict check.

Still outstanding on Linux:
- the backend suite on Linux, ideally on Node 22 (production's version), including the tests that fail here only for
  Windows reasons: the CRLF Product Catalog fixture, and the Postgres-18 payroll what-if queries;
- the VM's own Phase 2 test record and environment details (OS, Node, Postgres versions) for the release record;
- the Flutter goldens are rendered with Windows fonts (Segoe UI) and are not expected to match on Linux; the Linux
  check is the non-golden suite;
- whatever `PHASE2_REVIEW.md` recorded that isn't repeated here, once the VM is reachable.

## 16. Changed files (branch vs base)

**Backend** (`030f3b90..d311619e`, 19 files):

```
M  scripts/line_item_math_cases.json
A  scripts/service_catalog_preview.js
M  scripts/smoke_line_items.js
M  src/accessKeys.js
M  src/admin_users.js
M  src/catalog.js
M  src/lineItemMath.js
M  src/line_items.js
A  src/serviceCatalog.js
A  src/sfTax.js
M  test/action_permissions.test.js
A  test/line_item_math.test.js
A  test/line_items_zero_price.test.js
A  test/service_catalog.test.js
A  test/service_catalog_access.test.js
A  test/service_catalog_phase2.test.js
A  test/service_catalog_routes.test.js
A  test/service_catalog_sql.test.js
A  test/service_catalog_takeover_ranking.test.js
```

**App** (`26b798e5..` this revision, 25 files):

```
A  docs/services-catalog-release-2026-11-19/RELEASE_READINESS.md
A  docs/services-catalog-release-2026-11-19/picker_replacement_row.png
A  docs/services-catalog-release-2026-11-19/services_catalog_page_1366.png
M  lib/config/access.dart
M  lib/job_detail_items.dart
M  lib/services/line_items_api.dart
M  lib/services_catalog_screen.dart
M  lib/utils/line_item_math.dart
M  lib/widgets/catalog_search_field.dart
M  lib/widgets/line_items_editor.dart
M  test/estimate_pdf_test.dart
M  test/fixtures/line_item_math_cases.json
M  test/job_page_behavior_test.dart
M  test/job_page_fixture.dart
M  test/line_item_math_test.dart
M  test/line_items_editor_test.dart
M  test/line_items_final_test.dart
M  test/line_items_round2_test.dart
A  test/line_items_zero_price_test.dart
M  test/nav_session_test.dart
A  test/service_catalog_entry_test.dart
A  test/service_picker_test.dart
M  test/services_catalog_test.dart
M  test/shots/team_permissions.png
M  test/shots/team_permissions_900.png
```
