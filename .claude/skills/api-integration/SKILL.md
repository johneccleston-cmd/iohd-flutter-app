---
name: api-integration
description: Call the IOHD backend from Flutter correctly (auth headers, timeouts, 401/403 handling, JSON parsing, stale-response guards). Use when adding or changing any HTTP request, wiring a screen to real data instead of mock data, or debugging "session expired", empty data or server errors.
---

# Backend calls

Base URL: `kApiBaseUrl` from `lib/config/api_config.dart`. HTTP client: `package:http`.

## The request pattern

```dart
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'config/api_config.dart';
import 'config/auth_session.dart';

final uri = Uri.parse('$kApiBaseUrl/api/things').replace(queryParameters: {
  'q': query,
  'page': '$page',
});
// Generous timeout: Render free instances can take a while to wake up.
final res = await http
    .get(uri, headers: AuthSession.instance.headers())
    .timeout(const Duration(seconds: 40));

if (res.statusCode == 401) {
  AuthSession.instance.logout(); // router redirects to /login
  throw Exception('Your session expired. Please sign in again.');
}
if (res.statusCode == 403) throw Exception('Your account does not have access to this.');
if (res.statusCode != 200) throw Exception('Server error (${res.statusCode})');

final data = json.decode(res.body) as Map<String, dynamic>;
```

Rules:

1. **Always** use `AuthSession.instance.headers()`. It adds the shared bearer key and the user's
   `x-user-token`, and logs out on expiry. Use `headers(json: false)` for GETs with no body.
   A few older files build their own headers (`tech_retainage_screen.dart`, `admin_retainage_screen.dart`,
   `company_pool_screen.dart`, `services/commission_service.dart`). Switch them over when you touch them.
2. **Always** add `.timeout(...)`: 40–60s for reads and anything that may hit a cold start.
3. Build query strings with `Uri.replace(queryParameters:)`, never string concatenation of user input.
4. POST/PUT bodies use `jsonEncode(...)`. `headers()` already sets `Content-Type: application/json`.
5. Never hardcode another base URL. `services/commission_service.dart` still points at a placeholder
   `your-render-app.onrender.com` and is broken until it uses `kApiBaseUrl`.
6. Don't add new secrets to source.

## Parsing defensively

The backend returns numbers as strings sometimes. Use tolerant helpers (as in the dashboards):

```dart
int _parseInt(dynamic v) => v == null ? 0 : (v is num ? v.toInt() : int.tryParse('$v') ?? 0);
double _parseDouble(dynamic v) => v == null ? 0.0 : (v is num ? v.toDouble() : double.tryParse('$v') ?? 0.0);
```

For anything rendered in a list, parse into a small typed model with a `fromJson` factory that
never throws (see `JobStatusHistoryEntry` in `lib/widgets/job_status_timeline.dart`). Don't index
raw maps inside `build()`.

## State-safe loading

- Guard `setState` after `await` with `if (!mounted) return;`.
- When requests can overlap (typing in search, changing year), use a request counter and drop stale
  responses, as `_requestId` does in `customers_screen.dart`.
- Dashboards refetch in `didUpdateWidget` when `selectedYear` changes.
- Show errors with the UI from the `ux-states` skill. Strip the `Exception: ` prefix before showing text.

## Mock data

`payments_screen.dart`, `invoices_screen.dart` and `payroll_sample_data.dart` use hardcoded data.
When wiring them up, keep the UI and replace the list with a fetch that follows this pattern. Ask
the user for the endpoint shape rather than inventing one.
