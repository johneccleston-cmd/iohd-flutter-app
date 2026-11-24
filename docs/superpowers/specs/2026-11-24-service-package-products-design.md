# Service package: Products Used (design, 2026-11-24)

## Intent
A service package (e.g. Residential Service, Operator Installation) usually uses the same products every time. The
office wants to list those products on the package once, in order, so adding the package to a job brings its products
onto the job's Products & Services table in that order, with today's prices.

## What it is
- A **PRODUCTS USED** section on the service page (`lib/service_detail_screen.dart`), under SERVICE RATES, in the same
  grey-band section style.
- Columns: **PRODUCT NAME**, **QTY**, **PRICE**, **TOTAL** (qty x price).
- **Price is always the product's current catalog price, read-only** (user's choice B). Only the qty and the order are
  set on the package.
- Editing: a **product search** (the job table's catalog search, products only) adds a line at **qty 1**; each line can
  be **removed** and **moved up/down** (row menu, as rate rows: Move up / Move down / Delete). Qty 0 is allowed.
- Saved with the package's Save, as a whole ordered set, like rates.

## On a job
Picking the package in the job's Products & Services search adds its heading, its rate lines ("S"), then its product
lines ("I"), all under the heading, in the package's order. Each product line is what adding that product by hand
gives (catalog price, cost, tax), at the package's qty. **Remove package** removes them too. Line-item editing stays
preview-only (existing user rule).

## Calls (agreed 2026-11-24)
- New lines start at qty 1; 0 allowed and goes on the job at 0.
- "Starts at" on the page includes products at their qty (the header COST sum includes their catalog cost x qty).
- No cost column on the package page; the job line carries the product's catalog cost.
- A product that is inactive or no longer in the catalog stays listed, marked "Not in the catalog", and is left off
  jobs.
- Who can edit: the same permission as the package's rates (Services Catalog > Update).
- Backend changes are built and tested locally; pushed (= deployed) only on the user's OK.

## Approaches
1. **Separate ordered product list per package (picked).** New backend table `service_products (service_key, position,
   product_key, qty)`, a `PUT /api/catalog/services/products` that replaces the set in one statement (as rates), and
   the service entry carries `products: [{key, name, price, cost, taxable, active, qty}]` resolved from the catalog
   when read. Keeps rates and products independent.
2. Products as rows in `service_rates` with a kind flag: fewer pieces, but every rate reader must skip products and
   rate-only fields (commission, description) don't apply.
3. A JSON column on `service_overrides`: quickest, but no way to find packages that use a product.

## Left to the builder
How the product key is resolved to the catalog row, the exact payload shape, test fixtures, and the narrow-window
(stacked) layout of the product rows, following the rates table's.
