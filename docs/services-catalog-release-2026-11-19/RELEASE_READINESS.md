# Services Catalog Phase 2: release-readiness review (2026-11-19)

**Status: NOT approved for release.** Nothing here has been merged, deployed or published, no production migration has
run, and `SERVICE_CATALOG_V2` stays off. Job/Estimate line editing stays a preview (never saved). This review is the
input for a separate release decision.

## 1. What is being released

| Repo | Branch | Commit to release | Base it was cut from |
|---|---|---|---|
| integrity-backend | `services-catalog-phase1` | `0e6417575fd5e1fc9e1400e6ec1d9a027f6faa7e` | `030f3b90` (= `main` today) |
| iohd_desktop (app) | `services-catalog-phase1` | `08f74c529a79ca482fb8f82a291b93ef0b91d2c5` (code), plus the commit that adds this file (docs only) | `26b798e5` (`main` is `7a2d7f0`) |

Backend commits on the branch: `9539f17e` (Phases 1-2, 2026-11-18), `0e641757` (Decisions A and C, 2026-11-19).
App commits: `e53a1ef` (Phase 2 app, 2026-11-18), `08f74c5` (Decision A, two stale tests), then this review.

`main` in the app repo is one commit ahead of the branch base (`7a2d7f0`, the Stock Levels audit): 47 added files under
`docs/stock-levels-audit-2026-11-18/`, none of which the Services branch touches, so the merge is conflict-free.

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

**Beyond the literal wording (please confirm).** The rule is generalized in two ways:
- The item's name is its most common billed name. As the 18-month window rolls, the Dispatch rename will out-bill
  the old name (about spring 2027) and the two swap places: the old $199 name becomes the "variant". The rule therefore
  lets the original be the taker too, so the old name stays retired instead of coming back as a variant.
- By the same rule, a short-lived rename the office stopped using is retired while its original carries on.
- The thresholds (5 newest, 30 days) are my proposal; nothing in the decision fixed them.

### Decision C: search ranking

Per-item services are ranked in tiers (`serviceMatchScore`, `src/catalog.js`). Each tier's top is below the next tier's
floor, so the bonus for use (at most +50) orders services inside a tier and never across tiers.

| Tier | Match | Score (+ use, max 50) |
|---|---|---|
| 1 | exact name, billed, settled, no warning | 500 (500-550) |
| 2 | exact name, billed, with a warning: recent price change, price varies, billed once, tax varies | 440 (440-490) |
| 3 | strong match, billed: group is the search 380, name starts with 300, group starts with 260, name contains 220, another name it was billed under / a replaced name is the search 160 | 160-430 |
| 4 | exact name, never billed (only quoted, $0 or nothing) | 150 |
| 5 | anything else: a never-billed strong match 80, a word of the name starts with the search 60, another name starts with it 40 | 40-130 |

"Billed" = billed at least once in the catalog's 18 months. Never-billed services stay in the results (searched on its
own, a never-billed service is still the first result). "Another name" scores at most 210, below "name contains"
(220), so a rename never outranks a match on an item's own name, as before. Products are scored exactly as they always
were (the Phase 2 "Product Catalog boundary" test still compares every query with the pre-Phase-2 code), and the
service tiers sit on the products' scale, so products and services interleave as before. With
`SERVICE_CATALOG_V2` off none of this is reached: the picker serves the old per-type service rows.

Test cases (`test/service_catalog_takeover_ranking.test.js`):

| Case | What it pins down |
|---|---|
| Exact-name collision | Three services named the same: settled first, recent-change second, a billed "starts with" third, the never-billed one fourth, fuzzy last; case, spaces and leading symbols don't matter |
| Never-billed services | "Spring Replacement" (never billed) below billed "Spring Replacement \| Torsion \| Pair" and a billed group match, above fuzzy matches; still found; first when it is the only match |
| Recent price change | Below the settled exact match, above every non-exact billed match (even with 200 uses); its rate stays null |
| Other warnings | Price varies, billed once, tax varies and recent change each rank in tier 2 |
| Tiers never cross | Tier bounds asserted; one service per tier with the most use in the lower tiers still sorts 1-5 |
| Renamed variants | Door Removal: each exact name ranks its own item first. Dispatch: the old name and the old alias find the replacement first; a replacement never outranks an active item whose own name matches; the superseded original never appears |
| Built from real lines | Via `buildItems` + `pickerEntry`: a never-billed exact name sits below the billed strong match |

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

## 10. Test environment

The Linux VM used for Phases 1-2 can't be reached from this machine, and its Phase 2 review
(`audits/services-catalog-2026-11-18/PHASE2_REVIEW.md`) was never pushed, so its environment details aren't
available here. Everything below was run on this machine:

| | |
|---|---|
| OS | Windows 11 Pro 10.0.26300 |
| Flutter | 3.47.4 stable (framework 9584c6713b, 2026-09-10), Dart 3.13.3 |
| Node / npm | v24.14.0 / 11.12.1 (production runs Node 22) |
| Postgres for SQL tests | 18.6, a throwaway cluster on localhost:54329 created for this run (never production) |
| Worktrees | `C:\Users\opera\integrity-backend-services-phase1`, `C:\Users\opera\iohd-flutter-app-services-phase1`, plus clean comparison worktrees at `030f3b90`, `e53a1ef` and `7a2d7f0` |

**Flutter tests (full suite):**

| Tree | Passed | Skipped | Failed |
|---|---|---|---|
| `main` 7a2d7f0 | 1,887 | 12 | 81 |
| Phase 2 head e53a1ef | 1,919 | 12 | 85 (the 81 + 4 below) |
| This release 08f74c5 | 1,925 | 12 | 83 (the 81 + the 2 Team permissions goldens) |

The 81 failures are the same on all three trees (stale goldens and date-dependent tests, known per CLAUDE.md). The
Phase 2 head added four: the two stale tests fixed here, and two **Team permissions goldens** (`team_permissions.png`,
`team_permissions_900.png`) whose only difference is the Services Catalog row's longer help text. Regenerating them
needs your OK (CLAUDE.md), so they are left failing. Nothing passes on `main` and fails here except those two.

`flutter analyze`: 22 issues (20 infos, 2 warnings, no errors), the identical set on `main`, the Phase 2 head and this
release, none in a file this work changes. (CLAUDE.md asks for a clean analyze before committing; `main` isn't clean
either.)

**Web build:** `flutter build web --release` of 08f74c5 into a scratch folder (not `build/web_release`, not copied to
the backend): built in 60 s, `main.dart.js` 6.4 MB, `flutter_bootstrap.js` parses (`node --check`).

**Backend full suite** (`node --test --test-concurrency=1 test/*.test.js`, Postgres as above):

| Tree | Tests | Passed | Failed | Skipped |
|---|---|---|---|---|
| Baseline `main` 030f3b90 | 589 | 576 | 13 | 0 |
| Branch before today, 9539f17e | 662 | 650 | 12 | 0 |
| This release, 0e641757 | 679 | 667 | 12 | 0 |

The release's 12 failures are exactly the baseline's 13 minus one; nothing fails on the branch that passes on the
baseline. The one fixed is "the keys match the office app", which fails on `main` because `main`'s server doesn't know
`services_catalog` (the bug Phase 2 fixes). The 12 shared failures are environmental on this machine and identical
when run in parallel or one file at a time: seven Jarvis payroll what-if counts in `assistant_review_sql.test.js` (one
test with five failing subtests, the runner counting the parent too, plus "a week that already has a finalized payroll
run"; all "payroll_preview: The database query failed" against Postgres 18), two payments-list tests, the
callback-rate test (date-dependent), and two Product Catalog tests (a fixture checked out with CRLF line endings by
Windows git; "a product edited in the app keeps every edit"). The 17 new tests are the Decisions A and C file. An earlier run of the branch, made while three Flutter suites ran in parallel, hung in
`test/outbound_clients.test.js` (two timing tests failed under that load); it was stopped and re-run on an idle
machine, where it passes as on the baseline.

## 11. Deployment order, checks and rollback

Each step needs its own approval; none has been given.

0. **Before.** Confirm in the Render dashboard that `SERVICE_CATALOG_V2` is not set (it can't be read with the tools
   used here). Save the permission-list snapshot and re-run the fingerprints (section 4).
1. **Backend.** Merge `services-catalog-phase1` into `main` and push (Render auto-deploys `main` only; previews are off).
   Start-up adds the two columns and runs the permission migration.
2. **Check the backend.** The log line above; `app_migrations` has `2026-11-18-services-catalog-off`; the five lists
   contain `services_catalog.view`; both fingerprints unchanged; `/api/catalog/search?q=spring` returns the same
   products as before; with V2 off, services are the old `sf:` rows.
3. **App.** Merge the app branch, `flutter build web --release --output build/web_release`, check that
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

1. Confirm the takeover rule's thresholds (5 newest billed lines, 30 days) and its two generalizations (section 2).
2. OK to regenerate the two Team permissions goldens?
3. Linux VM environment details and its Phase 2 test record, if they should be part of the release record.
4. A variant's key follows the most common billed name, so after the Dispatch swap (about spring 2027) the keys move:
   `sfr:10792835` will mean the $109 service. Saved lines keep their old keys, which are informational only.
5. Mixed-version window: until the new web build is published, the five saved users see a load error on the Services
   Catalog page instead of the "no access" state.
