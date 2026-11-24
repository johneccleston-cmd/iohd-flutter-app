# Service Package Products Used Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A service package lists the products it uses (qty + order, catalog price read-only); adding the package to a job adds those products under its heading, after its rates, in that order.

**Architecture:** Backend gets a `service_products` table (ordered set per service, like `service_rates`) and `PUT /api/catalog/services/products`; the service entry carries `products`, each resolved against the live catalog when read. The desktop `CatalogEntry` parses them into `ServiceProduct`s, the job editor appends them in `toPackageLines`, and the service page gains a PRODUCTS USED section.

**Tech Stack:** Node/Express + Postgres (`C:\Users\opera\integrity-backend`, `node --test`), Flutter desktop (`c:\iohd_desktop`, `flutter test`).

**Spec:** `docs/superpowers/specs/2026-11-24-service-package-products-design.md`

## Global Constraints

- Price on the package page is the product's current catalog price, read-only. Only qty and order are stored.
- New product line starts at qty 1; qty 0 allowed (goes on the job at 0).
- "Starts at" (and the backend list price of a package) includes products at qty x catalog price; the header COST includes qty x catalog cost.
- A product inactive or gone from the catalog stays listed, marked `Not in the catalog`, and is left off jobs.
- Edit permission = the rates' (`serviceWrite`: Services Catalog > Update + Line Items & Costs > View).
- Never write to Service Fusion. Backend: build and test locally; do NOT push (push = deploy) without the user's OK.
- UI: all text `DashUi.ink`; section in the grey band (`_section`); headings one line 12 px (`_tHeader` style); columns PRODUCT NAME / QTY / PRICE / TOTAL; render shots and look before reporting.
- At most 50 products per package (`MAX_PRODUCTS = 50`).
- Commits only when the user asks (repo rule overrides the per-task commit steps: stage, don't commit).

## Review Focus

1. The same product picked twice: bump that line's qty by 1 (and flash it) instead of adding a second line (my call). Test in Task 5.
2. A package with products but no rates: still a package on a job (heading + product lines). Test in Task 4.
3. A product that went inactive after being added: page shows `Not in the catalog`, job skips it, Save still keeps it. Tests in Tasks 1 and 4.
4. Someone without cost view reading a package: product `cost` absent from the payload. Test in Task 1.
5. Qty box holding text or a negative: `Enter a quantity.` error, nothing sent. Test in Task 5.

---

### Task 1: Backend storage, cleaning and overlay

**Files:**
- Modify: `integrity-backend/src/serviceOverrides.js` (schema, `cleanProducts`, `productRowToJson`, `applyServiceOverrides`, `applyRates`, `hideOverrideCost`, exports)
- Test: `integrity-backend/test/service_overrides.test.js`

**Interfaces:**
- Produces: table `service_products (id SERIAL PK, service_key TEXT NOT NULL, position INT NOT NULL, product_key TEXT NOT NULL, product_name TEXT NOT NULL, qty NUMERIC(12,2) NOT NULL DEFAULT 1, updated_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_by TEXT)` + index `(service_key, position)`, created in `ensureServiceOverridesSchema`.
- Produces: `MAX_PRODUCTS = 50`; `cleanProducts(input) -> [{ key, name, qty }]` (throws `ServiceOverrideError`: not a list, > 50, missing key, bad qty `Product N: the quantity must be ...` via `cleanMoney`; qty default 1).
- Produces: `applyServiceOverrides(list, rows, rateRows = [], productRows = [])`. Each service with product rows gets `products: [{ key, name, qty, available, entry }]`: `entry` = the list's product entry for `key` (kind `product`, active) or `null`; `available = entry !== null`; `name` = entry's name, else the stored `product_name`. `editedFields` gains `'products'`.
- Produces: package price/cost: `startsAt` over rates + available products (`qty * entry.rate` / `entry.cost`).
- Produces: `hideOverrideCost` also strips `cost`/`costSource`/`vendors` from each `products[].entry`.

- [ ] **Step 1: Write failing tests** in `test/service_overrides.test.js`:
  - `cleanProducts` keeps order, defaults qty 1, accepts 0, rejects `-1`, rejects 51 items, rejects a missing key.
  - `applyServiceOverrides(list, [], [], [{service_key:'svc:a', position:1, product_key:'cat:2', product_name:'Opener', qty:2}, {service_key:'svc:a', position:0, product_key:'cat:1', product_name:'Spring', qty:1}])` with list holding `svc:a` and products `cat:1` (rate 40, cost 10, active) and `cat:2` (active:false) → `products` keys `['cat:1','cat:2']`, `available` `[true,false]`, the second's `entry` null and name `'Opener'`.
  - Package `svc:a` with one rate (qty 1, rate 100, cost 30) and product `cat:1` at qty 2 → `rate` 180, `cost` 50.
  - `hideOverrideCost` of that entry → `products[0].entry.cost` undefined.
- [ ] **Step 2:** `cd C:\Users\opera\integrity-backend && node --test test/service_overrides.test.js` → the new tests FAIL.
- [ ] **Step 3: Implement** the Interfaces above in `src/serviceOverrides.js`. `applyRates(e, rates, products)` computes price/cost from both; a service with products only also goes through it.
- [ ] **Step 4:** same command → PASS; `npm test` → all pass.
- [ ] **Step 5:** stage `src/serviceOverrides.js test/service_overrides.test.js`.

### Task 2: Backend route and cache

**Files:**
- Modify: `integrity-backend/src/catalog.js:527-540` (`serviceOverrideRows` also reads `service_products ORDER BY service_key, position`; returns `{ rows, rates, products }`), `:511` (pass `o.products`), new route beside `PUT /api/catalog/services/rates` (~line 990), `DELETE /api/catalog/services/override` also deletes `service_products`.
- Test: `integrity-backend/test/service_overrides.test.js` (same file the rates route tests live in)

**Interfaces:**
- Consumes: `cleanProducts`, `applyServiceOverrides(..., productRows)` from Task 1.
- Produces: `PUT /api/catalog/services/products` body `{ key, products: [{ key, name, qty }] }` → `{ service }` (the entry as it now reads). `...serviceWrite` guard; 404 for an unknown service; one statement `WITH gone AS (DELETE ...) INSERT ... FROM jsonb_to_recordset(...)` like rates; `overridesChanged()` after.

- [ ] **Step 1: Write failing route tests** (follow the file's existing rates-route harness): PUT with two products saves them in order and returns `service.products` in that order; empty list removes all; unknown service → 404; a user without `services_catalog/update` → 403.
- [ ] **Step 2:** `node --test test/service_overrides.test.js` → FAIL.
- [ ] **Step 3: Implement** the route and cache change.
- [ ] **Step 4:** `npm test` → all pass.
- [ ] **Step 5:** stage. Do not push.

### Task 3: Desktop model and API

**Files:**
- Modify: `lib/services/line_items_api.dart` (new `ServiceProduct`, `CatalogEntry.products`, `fromJson`, `startsAt`, `isPackage`, `toPackageLines`, `LineItemsApi.saveServiceProducts`)
- Modify: `lib/utils/line_item_math.dart` (`LineDraft.copyWith` gains `packageId`/`packageName` if absent)
- Test: `test/service_catalog_entry_test.dart`

**Interfaces:**
- Produces: `class ServiceProduct { final String key; final String name; final double qty; final CatalogEntry? entry; bool get available => entry != null; double? get price => entry?.rate; double? get total; factory ServiceProduct.fromJson(Map<String, dynamic>); Map<String, dynamic> toJson() => {'key','name','qty'}; ServiceProduct copyWith({double? qty}); }`
- Produces: `CatalogEntry.products` (`List<ServiceProduct>`, default const []); `isPackage => isService && (rates.isNotEmpty || products.isNotEmpty)`; package `rate`/`cost` in `fromJson` = rates' `startsAt` + available products' qty x price/cost.
- Produces: `toPackageLines(id)` = rate lines, then for each available product `p.entry!.toLine().copyWith(quantity: p.qty, packageId: id, packageName: name)`.
- Produces: `static Future<CatalogEntry> saveServiceProducts(String key, List<ServiceProduct> products)` → `PUT /api/catalog/services/products`.

- [ ] **Step 1: Write failing tests:** `fromJson` reads `products` in order with `available`; a package of 1 rate (1 x 100, cost 30) + product (2 x 40, cost 10) → `rate` 180, `cost` 50; `toPackageLines('p1')` → names `[rate, product]`, product line `service == false`, `quantity == 2`, `packageId == 'p1'`; an unavailable product is not in the lines; a service with products and no rates → `isPackage` true.
- [ ] **Step 2:** `flutter test test/service_catalog_entry_test.dart` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** same → PASS; `flutter analyze` clean.
- [ ] **Step 5:** stage.

### Task 4: Job editor

**Files:**
- Modify: `lib/widgets/line_items_editor.dart:772` only if Task 3 doesn't already cover it (it should: `_addPackage` uses `toPackageLines`); heading count text counts all lines.
- Test: `test/service_package_lines_test.dart`

**Interfaces:**
- Consumes: `CatalogEntry.toPackageLines`, `isPackage` (Task 3).

- [ ] **Step 1: Write failing tests:** the fixture package gets `'products': [{'key':'cat:spring','name':'Torsion Spring','qty':2,'available':true,'entry':{...product json, rate 60}}, {'key':'cat:gone','name':'Old Remote','qty':1,'available':false,'entry':null}]`. Picking it adds the 8 rate lines then `Torsion Spring` (qty 2, "I" mark) under the heading; `Old Remote` is absent; Remove package removes the spring too. A second package with products only adds a heading + its product lines.
- [ ] **Step 2:** `flutter test test/service_package_lines_test.dart` → FAIL.
- [ ] **Step 3: Implement** whatever the tests show is missing.
- [ ] **Step 4:** PASS; review picture `build/job_shots/package_*.png` looked at.
- [ ] **Step 5:** stage.

### Task 5: Service page PRODUCTS USED section

**Files:**
- Modify: `lib/service_detail_screen.dart` (new widget param `productsSaver`, product drafts, `_productsRead`, `_productsEdit`, `_section('PRODUCTS USED', ...)` after SERVICE RATES, save step after rates, Starts at/COST facts via `CatalogEntry` figures)
- Modify: `lib/widgets/catalog_search_field.dart` (param `bool allowCustom = true`; false hides "Add a custom line")
- Test: `test/service_detail_test.dart`; shots via `test/services_catalog_shots_test.dart` (fixture `kServiceWithRates` gets two products)

**Interfaces:**
- Consumes: `ServiceProduct`, `CatalogEntry.products`, `LineItemsApi.saveServiceProducts` (Task 3).
- Produces: `ServiceDetailScreen({..., Future<CatalogEntry> Function(String key, List<ServiceProduct> products)? productsSaver, Future<List<CatalogEntry>> Function(String q)? productSearch})`.

Layout: band `PRODUCTS USED`; table headings `PRODUCT NAME | QTY | PRICE | TOTAL` (+ menu column while editing), same row shell/stripes/heights as the rates table; QTY is the rates' qty box with arrows while editing; PRICE and TOTAL plain text (TOTAL in the grey `_figureBox` while editing); unavailable rows read `Not in the catalog` in the PRICE cell, TOTAL `—`. Row menu: `Move up` / `Move down` / `Delete` (as rates). Under the table while editing: `CatalogSearchField(showCost: false, allowCustom: false, search: products-only)` labelled `Add a product`. Read with no products: `No products yet` line (+ ` Add some with Edit.` when `_canEdit`). Narrow (`!cols.fits`): stacked rows like the rates'.

- [ ] **Step 1: Write failing tests** in `test/service_detail_test.dart`:
  - reads: `PRODUCTS USED`, `PRODUCT NAME`, product names in order, `$120.00` for 2 x $60, `Not in the catalog` for the unavailable one.
  - edit: search `spring`, pick → new line qty 1 at the end; pick the same product again → that line qty 2, no new line; Move up reorders; Delete removes; Save → `productsSaver` gets keys in the new order with their qtys; nothing sent when products unchanged.
  - qty `abc` → `Enter a quantity.`, Save sends nothing.
  - Starts at includes products (fixture: rates $315 + 2 x $60 → `$435.00`).
- [ ] **Step 2:** `flutter test test/service_detail_test.dart` → FAIL.
- [ ] **Step 3: Implement.** Products dirty-check joins `_changed`; Esc/cancel restores them; the leave guard covers them.
- [ ] **Step 4:** `flutter test test/service_detail_test.dart test/ps_round2_final_service_test.dart test/service_package_lines_test.dart test/services_catalog_test.dart` → PASS; `flutter analyze` clean.
- [ ] **Step 5:** `flutter test test/services_catalog_shots_test.dart --dart-define=SHOTS=products --plain-name detail_` → no overflow; look at view + edit at 1366 and 1920 and t130.
- [ ] **Step 6:** stage; report to the user with the shots; ask before committing or pushing the backend.
