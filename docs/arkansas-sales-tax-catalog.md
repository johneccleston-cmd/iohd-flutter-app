# Arkansas sales tax catalog: source, upkeep and history

The Tax, discounts & fees panel (Products & Services on job and estimate pages) offers every Arkansas place with a sales
tax: the state, each county that levies one and each city that does, with the dates each rate took effect. This page says
where those rates come from, how they are kept current, and how a record keeps the rate it was given.

## Where the rates come from

| What | Source | File in the app |
|------|--------|-----------------|
| City and county rates, with effective dates | Arkansas DFA, *Cities and Counties Tax Rates Table* (one XLS per quarter): <https://www.dfa.arkansas.gov/office/taxes/excise-tax-administration/sales-use-tax/sales-use-tax-rates/city-and-county-sales-use-tax-rates/> | `lib/utils/arkansas_sales_tax_data.dart` (generated) |
| Changes announced but not yet in a quarterly table | Arkansas DFA, *Local Sales & Use Tax Rate Changes*: <https://www.dfa.arkansas.gov/office/taxes/excise-tax-administration/sales-use-tax/recent-changes-in-sales-use-tax/recent-changes-for-local-taxes/> | `tool/tax/announced_changes.csv` |
| The state rate (6.5% since Jul 1, 2013) | Arkansas DFA, *State Sales & Use Tax Rates*: <https://www.dfa.arkansas.gov/office/taxes/excise-tax-administration/sales-use-tax/sales-use-tax-rates/state-sales-use-tax-rates/> | `tool/tax/ar_tax_import.dart` (`_stateMilli`) |

**Last verified:** 2026-11-20. Imported every quarterly table DFA posts, January–March 2024 to October–December 2026
(12 files). That gives 75 counties and 351 cities; 73 counties and 350 cities have a tax on Nov 20, 2026 (Monroe and
Saline counties are at 0%, Parkin's was rescinded). The January 2027 changes DFA has announced are included as
future-dated rates: Harrison 1%, Boone County 1%, Lafayette County 1.625%.

DFA also publishes a Streamlined Sales Tax rate file (`ARR…csv`, by FIPS code) and a ZIP-level boundary file on its
[Streamlined Tax Lookup](https://www.dfa.arkansas.gov/office/taxes/excise-tax-administration/sales-use-tax/streamlined-tax-lookup/)
page. Those carry no place names, and the copy on DFA's page was last updated 08/27/2025, so the named quarterly tables
are the source. The boundary file is the way to look a rate up by address later, if that is ever wanted.

## How it is checked

- **Against DFA's own totals.** For every single-county city, the import checks city rate + county rate = the
  table's "Total %" column. It also checks that each city's counties resolve and that no code is listed twice. The
  2026-11-20 run found no problems.
- **Against what Service Fusion actually charged** (production, read-only, 2026-11-20). Every tax name and rate on a
  job since 2024 was compared with the catalog's rate on that job's first and last dates: 50 name/rate pairs, 2,848
  charges. 46 match exactly. The other 4 are all places where DFA changed a rate on Oct 1, 2025 and Service Fusion's
  tax setting was never updated:
  - Madison County went from 2.5% to 3.5%. "State & County, Madison" stayed at 9% until 2026-06-16, Huntsville at 10%
    and St. Paul at 11%: under-collected.
  - Saline County's 0.375% was rescinded. Benton (city) stayed at 9.375% instead of 9%: over-collected.

  Pinned in `test/tax_discounts_fees_test.dart` ("every tax Service Fusion charged since 2024 ...").

## Updating it each quarter

1. Download the new quarter's XLS from the DFA page above (`cityCountyTaxTable_<Mon>_<Mon>_<year>.xls`). Put it in one
   folder with the earlier quarters; keep at least the previous ones, so the history stays complete.
2. Take out of `tool/tax/announced_changes.csv` any rows the new table now covers. The import refuses an announced change
   dated on or before the newest table's quarter, and says which. Add any new announcements from the recent-changes page.
3. Run:
   ```bash
   dart run tool/tax/ar_tax_import.dart --verified YYYY-MM-DD <folder with the .xls files>
   ```
   It prints the quarters it read, the counts, and every place added, removed or changed against the catalog in the app.
   It ends with `No problems found.` or a list of problems (it exits 1 then).
4. Read the changes it lists, run `flutter test test/tax_discounts_fees_test.dart`, and publish the app as usual.

No package is needed: the XLS is read by `tool/tax/xls_reader.dart`.

**Between updates:** a rate change can be typed in on Inventory > Tax, Discounts & Fees ("Rate changes entered here")
with the day it starts. The panel uses it from that day until the next import has it.

## Saved records never change

- A record's own tax (Service Fusion's charge) keeps the rate it was charged at. The panel shows today's DFA rate beside
  it when the two differ, and never changes it.
- A tax added from the catalog keeps its parts, the day its rates were looked up (`SalesTax.asOf`) and its combined
  rate. When saving is turned on, that snapshot is what gets stored, so a later catalog update can't re-price it.
- The catalog keeps every rate period (`TaxPeriod.from` / `to`), so the rate on any past day can be looked up.

## Not modelled (decide before relying on it)

- Arkansas's local-tax treatment of single items over $2,500 (rebates). Taxes are charged on the full amount.
- Reduced state rates (food 0% since 2026-01-01, manufacturing utilities). Garage door work doesn't use them.
- Rates by street address (the boundary file). A city in two counties (Springdale, Elm Springs, ...) asks which county
  the job is in.
