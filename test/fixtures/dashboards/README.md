# Dashboard fixtures

One saved response per dashboard endpoint, plus an `_empty` variant (a year with nothing in it):

| File | Endpoint |
| --- | --- |
| `financial.json` | `GET /api/financial_dashboard?year=2026` |
| `commissions.json` | `GET /api/commissions_stats?year=2026` |
| `technicians.json` | `GET /api/tech_stats?year=2026` |
| `inventory.json` | `GET /api/dashboards/inventory` |
| `sales.json` | `GET /api/dashboards/sales?year=2026` |
| `collections.json` | `GET /api/dashboards/collections?year=2026` |
| `jobs.json` | `GET /api/dashboards/jobs?year=2026` |
| `estimates.json` | `GET /api/dashboards/estimates?year=2026` |

- **Scrubbed.** Every person, customer and job number is made up. Nothing here comes from the live database.
- **Shaped like the real thing.** Field names and types match the backend responses as of 2026-10-22, and the
  magnitudes are in the range production showed that day.
- **Internally consistent.** Each total equals the series it summarizes (for example Collected = the monthly
  collected values; Outstanding = the stage amounts; Revenue + deposits = the four revenue segments), so tests can
  reconcile a headline figure against its parts.
- **Pinned to 2026-10-22.** October is the month in progress (22 of 31 days); January to September are complete.
  Tests pin `DashClock` to that date (see `test/dashboard_harness.dart`).
- **Edge cases built in.** Commissions only start in October (the Oct 5 go-live). One sales-role person has real
  pool pay. Lost estimates are mostly plain "Lost". Inventory dead stock and accuracy are `null` (not tracked).

Regenerate after changing the generator (from the repo root):

```bash
node test/fixtures/dashboards/generate_fixtures.js test/fixtures/dashboards
```
