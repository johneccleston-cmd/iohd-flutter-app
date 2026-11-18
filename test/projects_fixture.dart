// A fake /api/projects for the Project Tracker tests: an in-memory list that answers GET, POST, PUT and DELETE the way
// integrity-backend/src/projects.js does (same field names, same validation messages, `project` returned on save).
// Also builds realistic project sets: the mix mirrors production on 2026-11-12 (61 projects, 26 open, most of them in
// Planning, few with a deadline, one person owning most of the work), with made-up names and notes.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/config/auth_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

const kProjectStatuses = ['Planning', 'In Progress', 'In Review', 'On Hold', 'Complete'];
const kProjectPriorities = ['Urgent', 'High', 'Medium', 'Low'];

String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime _today() {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}

Map<String, dynamic> fakeProject(
  int id,
  String name, {
  String owner = '',
  String support = '',
  String requestedBy = '',
  String priority = 'Medium',
  String status = 'Planning',
  int? dueInDays,
  String notes = '',
  List<Map<String, String>> files = const [],
  int updatedDaysAgo = 3,
}) => {
  'id': id,
  'name': name,
  'owner': owner,
  'support': support,
  'requestedBy': requestedBy,
  'priority': priority,
  'status': status,
  'deadline': dueInDays == null ? null : _iso(_today().add(Duration(days: dueInDays))),
  'notes': notes,
  'files': files,
  'updatedAt': DateTime.now().toUtc().subtract(Duration(days: updatedDaysAgo, hours: 2)).toIso8601String(),
};

/// A large board: 61 projects like production (17 Planning, 7 In Progress, 2 In Review, 35 Complete), three of the
/// open ones late, one due this week, one with no owner, one very long name.
List<Map<String, dynamic>> manyProjects() {
  final out = <Map<String, dynamic>>[];
  var id = 100;
  Map<String, dynamic> add(
    String name, {
    String owner = 'John Eccleston',
    String support = '',
    String requestedBy = 'Ryan Schwartz',
    String priority = 'Medium',
    String status = 'Planning',
    int? due,
    String notes = '',
    List<Map<String, String>> files = const [],
    int updated = 3,
  }) {
    final p = fakeProject(
      ++id,
      name,
      owner: owner,
      support: support,
      requestedBy: requestedBy,
      priority: priority,
      status: status,
      dueInDays: due,
      notes: notes,
      files: files,
      updatedDaysAgo: updated,
    );
    out.add(p);
    return p;
  }

  const doc = [
    {'name': 'Project outline', 'url': 'https://docs.google.com/document/d/abc/edit'},
  ];
  // In Progress (7)
  add(
    'Warehouse Reorganization',
    owner: 'Daniel Baty',
    support: 'Zac Clemens',
    priority: 'High',
    status: 'In Progress',
    due: -9,
    notes: 'Racking on the north wall is in. Still to do:\n- Label every bay\n- Move springs to the front\n- Count after the move',
    files: doc,
    updated: 1,
  );
  add(
    'KPI\'s, Reporting & Dashboards',
    priority: 'High',
    status: 'In Progress',
    notes: 'Dashboards are live. Next: weekly email of the scorecards.',
    files: doc,
    updated: 0,
  );
  add('New Technician Onboarding Program', owner: 'Ryan Schwartz', support: 'Heather Vera', priority: 'Medium', status: 'In Progress', due: 5, updated: 6);
  add('Fleet GPS and Fuel Card Rollout', owner: 'Zac Clemens', priority: 'Medium', status: 'In Progress', updated: 12);
  add('Vendors & Parts', priority: 'Low', status: 'In Progress', notes: 'Price list from the second supplier still missing.', updated: 20);
  add('Customer Review Requests After Every Job', owner: 'Ryan Schwartz', support: 'Bella Hansberger', priority: 'High', status: 'In Progress', updated: 2);
  add('Commercial Service Agreements', owner: 'Zac Clemens', requestedBy: '', priority: 'Urgent', status: 'In Progress', due: 18, updated: 4);
  // In Review (2)
  add(
    'Sales Process Changes',
    owner: 'Ryan Schwartz',
    priority: 'High',
    status: 'In Review',
    due: -181,
    notes: 'Build new Residential Estimate Template from the Residential Sales Process.\n- Add a team photo to our residential estimate template.\n- May need a residential sales process like the commercial one but smaller.',
    files: const [
      {'name': 'Project Outlines Sales Process', 'url': 'https://docs.google.com/document/d/def/edit'},
      {'name': 'Residential template draft', 'url': ''},
    ],
    updated: 31,
  );
  add('Website Refresh and Online Booking', priority: 'Medium', status: 'In Review', updated: 8);
  // Planning (17)
  add(
    'Need to collect on accounts receivable and look into selling the debt to a collections agency or filing liens and getting insurance for future AR',
    owner: 'Ryan Schwartz',
    priority: 'High',
    notes: 'Talk to two agencies first.',
    updated: 15,
  );
  add('Get GC License', priority: 'Medium', due: -22, updated: 40);
  add('Hire Second Install Crew', owner: 'Zac Clemens', priority: 'High', due: 40, updated: 5);
  add('Quarterly Safety Training', owner: '', requestedBy: 'Ryan Schwartz', priority: 'Medium', updated: 9);
  add('IOHD Master Technician Program', owner: 'Ryan Schwartz', requestedBy: '', priority: 'Low', updated: 25);
  for (final n in [
    'Spring Inventory Minimums',
    'Opener Install Checklist',
    'Showroom Door Display',
    'Annual Maintenance Plan Pricing',
    'Truck Stock Standard List',
    'Bring Accounting In-House',
    'Paperless Work Orders',
    'Builder Partnerships Program',
    'After-Hours Call Routing',
    'Photo Standards for Site Checks',
    'Warranty Claim Process',
    'Employee Handbook Update',
  ]) {
    add(n, priority: (n.length % 3 == 0) ? 'Low' : 'Medium', updated: 10 + n.length % 30);
  }
  // Complete (35)
  for (var i = 0; i < 35; i++) {
    add(
      'Finished project ${i + 1}: ${['Phone system move', 'Uniform order', 'Insurance renewal', 'Yard cleanup', 'Hiring ads'][i % 5]}',
      owner: ['John Eccleston', 'Ryan Schwartz', 'Heather Vera'][i % 3],
      priority: ['High', 'Medium', 'Low'][i % 3],
      status: 'Complete',
      due: i % 4 == 0 ? -(30 + i * 7) : null,
      updated: 30 + i * 4,
    );
  }
  return out;
}

/// A small board: three open projects and one finished one.
List<Map<String, dynamic>> fewProjects() => [
  fakeProject(
    1,
    'Get GC License',
    owner: 'John Eccleston',
    requestedBy: 'Ryan Schwartz',
    priority: 'High',
    status: 'In Progress',
    dueInDays: 12,
    updatedDaysAgo: 1,
  ),
  fakeProject(2, 'Showroom Door Display', owner: 'Zac Clemens', priority: 'Medium', status: 'Planning', updatedDaysAgo: 7),
  fakeProject(3, 'Employee Handbook Update', owner: '', priority: '', status: 'On Hold', notes: 'Waiting on the lawyer.', updatedDaysAgo: 44),
  fakeProject(4, 'Uniform order', owner: 'Heather Vera', priority: 'Low', status: 'Complete', updatedDaysAgo: 60),
];

/// Answers /api/projects like the backend, from an in-memory list. Records what was sent.
class FakeProjectsServer {
  final List<Map<String, dynamic>> projects;
  final requests = <http.Request>[];

  /// Set to make the next calls fail with this status (and [failMessage]).
  int? failWith;
  String failMessage = 'Could not complete that. Try again.';

  /// Set to make only GET fail (a refresh failure over a list that is already on screen).
  int? failGetWith;

  /// Leave `project` out of POST/PUT answers, like an older server.
  bool omitProjectInSave = false;

  /// Throw this instead of answering (a dropped connection).
  Object? throwError;

  /// Never answer (a server that hangs, so the app's own timeout fires).
  bool hang = false;

  FakeProjectsServer(List<Map<String, dynamic>> seed) : projects = [for (final p in seed) Map<String, dynamic>.of(p)];

  int _nextId = 10000;

  Iterable<http.Request> get writes => requests.where((r) => r.method != 'GET');

  http.Response _json(Object body, [int code = 200]) =>
      http.Response.bytes(utf8.encode(json.encode(body)), code, headers: {'content-type': 'application/json; charset=utf-8'});

  String? _validate(Map<String, dynamic> b) {
    if ('${b['name'] ?? ''}'.trim().isEmpty) return 'A project needs a name.';
    final status = '${b['status'] ?? ''}'.trim();
    if (status.isNotEmpty && !kProjectStatuses.contains(status)) return 'Status must be one of: ${kProjectStatuses.join(', ')}.';
    final priority = '${b['priority'] ?? ''}'.trim();
    if (priority.isNotEmpty && !kProjectPriorities.contains(priority)) return 'Priority must be one of: ${kProjectPriorities.join(', ')}.';
    for (final f in (b['files'] as List? ?? const [])) {
      final url = '${(f as Map)['url'] ?? ''}'.trim();
      if (url.isNotEmpty && !RegExp(r'^https?://', caseSensitive: false).hasMatch(url)) {
        return '"${f['name']}" needs a link that starts with http:// or https://.';
      }
    }
    return null;
  }

  Map<String, dynamic> _shape(int id, Map<String, dynamic> b) => {
    'id': id,
    'name': '${b['name']}'.trim(),
    'owner': '${b['owner'] ?? ''}'.trim(),
    'support': '${b['support'] ?? ''}'.trim(),
    'requestedBy': '${b['requestedBy'] ?? ''}'.trim(),
    'priority': '${b['priority'] ?? ''}'.trim(),
    'status': '${b['status'] ?? ''}'.trim().isEmpty ? 'Planning' : '${b['status']}'.trim(),
    'deadline': '${b['deadline'] ?? ''}'.trim().isEmpty ? null : '${b['deadline']}'.trim(),
    'notes': '${b['notes'] ?? ''}'.trim(),
    'files': [for (final f in (b['files'] as List? ?? const [])) Map<String, dynamic>.of(f as Map<String, dynamic>)],
    'updatedAt': DateTime.now().toUtc().toIso8601String(),
  };

  http.Client client() => MockClient(handle);

  /// One request, answered like the backend.
  Future<http.Response> handle(http.Request req) async {
    requests.add(req);
    final err = throwError;
    if (err != null) throw err;
    if (hang) return Completer<http.Response>().future;
    final path = req.url.path;
    if (!path.startsWith('/api/projects')) return _json({'error': 'no fixture for $path'}, 404);
    final code = failWith ?? (req.method == 'GET' ? failGetWith : null);
    if (code != null) return _json({'success': false, 'error': failMessage}, code);

    if (req.method == 'GET' && path == '/api/projects') return _json({'success': true, 'projects': projects});
    if (req.method == 'POST' && path == '/api/projects/import-sheet') return _json({'success': true, 'imported': 0, 'total': 0});

    final body = req.body.isEmpty ? <String, dynamic>{} : json.decode(req.body) as Map<String, dynamic>;
    if (req.method == 'POST' && path == '/api/projects') {
      final err = _validate(body);
      if (err != null) return _json({'success': false, 'error': err}, 400);
      final p = _shape(++_nextId, body);
      projects.add(p);
      return _json({'success': true, if (!omitProjectInSave) 'project': p}, 201);
    }
    final id = int.tryParse(path.split('/').last);
    final i = projects.indexWhere((p) => p['id'] == id);
    if (i < 0) return _json({'success': false, 'error': 'That project no longer exists.'}, 404);
    if (req.method == 'PUT') {
      final err = _validate(body);
      if (err != null) return _json({'success': false, 'error': err}, 400);
      // The backend's guard: a save made from an older copy is refused instead of overwriting someone else's.
      final since = body['ifUnchangedSince'];
      if (since != null && since != projects[i]['updatedAt']) {
        return _json({'success': false, 'code': 'CHANGED', 'error': 'Someone else changed this project after you opened it.'}, 409);
      }
      projects[i] = _shape(id!, body);
      return _json({'success': true, if (!omitProjectInSave) 'project': projects[i]});
    }
    if (req.method == 'DELETE') {
      projects.removeAt(i);
      return _json({'success': true});
    }
    return _json({'error': 'unexpected ${req.method} $path'}, 405);
  }
}

/// Signs in as an office user through the saved-session path, with [denied] Team switches off (e.g. 'projects.update').
/// Admins can do everything, so permission tests use a non-admin.
Future<void> projectsSignIn({String name = 'John Eccleston', bool admin = false, List<String> denied = const []}) async {
  AuthSession.instance.logout();
  final payload = base64Url.encode(utf8.encode(json.encode({'exp': DateTime(2100).millisecondsSinceEpoch})));
  SharedPreferences.setMockInitialValues({
    'iohd_auth_session': json.encode({'token': '$payload.sig', 'name': name, 'role': admin ? 'Admin' : 'Office', 'is_admin': admin, 'denied': denied}),
  });
  await AuthSession.instance.restore();
}

/// The Team switches that make Projects view-only.
const kProjectsViewOnly = ['projects.create', 'projects.update', 'projects.delete'];

/// Someone else saves the project with [id] on the server (a newer updatedAt and whatever [changes]).
void editElsewhere(FakeProjectsServer s, int id, Map<String, dynamic> changes) {
  final i = s.projects.indexWhere((p) => p['id'] == id);
  s.projects[i] = {...s.projects[i], ...changes, 'updatedAt': DateTime.now().toUtc().add(const Duration(seconds: 1)).toIso8601String()};
}
