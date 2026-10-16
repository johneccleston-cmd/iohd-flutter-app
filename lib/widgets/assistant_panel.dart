import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../utils/status_colors.dart';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../config/api_config.dart';

import 'package:shared_preferences/shared_preferences.dart';

import '../config/auth_session.dart';
import '../theme/app_theme.dart';
import 'dashboard_kit.dart';

// --- Design tokens (same palette as the top bar) -------------------------------
const Color _brandRed = AppTheme.brandRed;
const Color _paper = AppTheme.surfaceColor; // page background
const Color _sidebarBg = DashUi.faint;
const Color _ink = AppTheme.primaryText;
const Color _slate = AppTheme.secondaryText;
const Color _muted = AppTheme.sectionLabel;
const Color _stroke = AppTheme.strokeBorder;
// Opaque on purpose: callers apply their own alpha with withValues, which replaces this one rather than multiplying.
final Color _tint = Color.alphaBlend(AppTheme.brandRed.withValues(alpha: 0.08), AppTheme.surfaceColor);
const Color _fill = DashUi.faint;
const Color _fillStrong = DashUi.line; // selected row in the sidebar, which is already _fill

const Color _good = Color(0xFF16A34A);
const Color _warn = Color(0xFFD97706);
const Color _bad = Color(0xFFDC2626);
const Color _info = Color(0xFF4F46E5);
const Color _teal = Color(0xFF0891B2);

// The backend accepts at most 20 messages of 4000 characters each, but only the last 8 are sent: every
// message sent is billed as input tokens on every question, so the cap keeps an old tab cheap.
const int _sendMessages = 8;
const int _maxChars = 4000;

class _Suggestion {
  final IconData icon;
  final String title;
  final String question;
  const _Suggestion(this.icon, this.title, this.question);
}

const List<_Suggestion> _suggestions = [
  _Suggestion(Icons.request_quote_outlined, 'Unpaid jobs', 'Which jobs from the last 30 days are not paid in full?'),
  _Suggestion(Icons.groups_outlined, 'Top customers', 'Who are our top 10 customers by revenue this year?'),
  _Suggestion(Icons.show_chart_rounded, 'Monthly trend', 'Show completed revenue and profit by month this year.'),
  _Suggestion(Icons.inventory_2_outlined, 'Low stock', 'Which inventory items are low on stock?'),
  _Suggestion(Icons.handshake_outlined, 'Open estimates', 'What is our open estimate pipeline and win rate this year?'),
  _Suggestion(Icons.event_available_outlined, 'This week', 'What is scheduled for the technicians this week?'),
];

// What the person sees under an answer, instead of internal tool names.
const Map<String, String> _toolLabels = {
  'search_jobs': 'Jobs',
  'get_job': 'Job detail',
  'jobs_summary': 'Jobs',
  'customer_lookup': 'Customers',
  'top_customers_by_revenue': 'Customer revenue',
  'monthly_financials': 'Financials',
  'estimates_summary': 'Estimates',
  'open_jobs_by_status': 'Open jobs',
  'low_stock_items': 'Inventory',
  'list_employees': 'Employees',
  'outstanding_balances': 'Balances',
  'oldest_unpaid_jobs': 'Unpaid invoices',
  'payments_received': 'Payments',
  'tech_activity': 'Technicians',
  'expenses_summary': 'Expenses',
  'inventory_lookup': 'Inventory',
  'status_changes': 'Job history',
  'search_estimates': 'Estimates',
  'never_converted': 'Estimates',
  'pipeline_forecast': 'Pipeline',
  'lapsed_customers': 'Customers',
  'customer_exposure': 'Customers',
  'new_customers': 'Customers',
  'payment_speed': 'Payments',
  'schedule': 'Schedule',
  'revenue_mix': 'Revenue',
  'line_item_sales': 'Line items',
  'writeoffs_summary': 'Write-offs',
  'jobs_stuck': 'Stuck jobs',
  'commission_corrections': 'Commissions',
  'job_commission': 'Commissions',
  'payroll_runs': 'Payroll',
  'payroll_preview': 'Payroll',
  'advance_balances': 'Payroll',
  'retainage_and_pool': 'Payroll',
  'job_notes_tasks': 'Job notes',
  'job_files_list': 'Job files',
  'google_reviews': 'Google reviews',
  'cycle_count_status': 'Cycle counts',
  'balance_history': 'Balance history',
  'run_sql': 'Custom query',
};

/// One line for "How I got this": what was looked up and with which filters, from the tool name and its JSON input.
String? _describeCall(String tool, String inputJson) {
  if (tool == 'describe_data') return null; // housekeeping, nothing to show
  var input = <String, dynamic>{};
  try {
    final d = json.decode(inputJson);
    if (d is Map<String, dynamic>) input = d;
  } catch (_) {}
  final label = _toolLabels[tool] ?? tool.replaceAll('_', ' ');
  if (tool == 'run_sql') {
    final purpose = (input['purpose'] ?? '').toString().trim();
    final sql = (input['sql'] ?? '').toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    final shown = sql.length > 220 ? '${sql.substring(0, 220)}…' : sql;
    return purpose.isEmpty ? '$label: $shown' : '$label: $purpose ($shown)';
  }
  final params = [
    for (final e in input.entries)
      if (e.key != 'limit' && e.value != null && e.value.toString().trim().isNotEmpty) '${e.key.replaceAll('_', ' ')} ${e.value}',
  ];
  return params.isEmpty ? label : '$label: ${params.join(', ')}';
}

enum AssistantRole { user, assistant }

/// One saved chat: its messages and an optional name the user gave it (otherwise its first question).
class AssistantConversation {
  final List<AssistantMessage> messages = [];
  String? title;

  String get label {
    if (title != null) return title!;
    final first = messages.where((m) => m.role == AssistantRole.user).firstOrNull;
    if (first == null) return 'New chat';
    final t = first.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length > 40 ? '${t.substring(0, 40).trimRight()}…' : t;
  }
}

class AssistantMessage {
  final AssistantRole role;
  final String text;
  final List<String> sources;
  final List<String> calls; // what was looked up, one line each, shown under "How I got this"

  /// True until the panel has shown this message once, so a new answer animates in and a re-opened
  /// conversation does not replay.
  bool fresh = true;

  AssistantMessage(this.role, this.text, [this.sources = const [], this.calls = const []]);
}

/// The conversation lives here. It survives closing the panel and, via SharedPreferences, an app restart.
/// Sign-out, "New conversation" or a different user signing in wipes it.
class AssistantChat extends ChangeNotifier {
  AssistantChat._() {
    AuthSession.instance.addListener(_onAuthChanged);
  }
  static final AssistantChat instance = AssistantChat._();

  /// Saved chats, shown in the sidebar and capped at [maxChats]. Only the active one is ever sent to the
  /// server, and only its last [_sendMessages] messages, so an old or idle chat costs nothing until used.
  static const maxChats = 10;
  final List<AssistantConversation> chats = [AssistantConversation()];
  int active = 0;
  int chatChanges = 0; // bumped on every switch so the panel can jump to the end instead of animating

  List<AssistantMessage> get messages => chats[active].messages;

  /// The screen the panel was opened from, sent with each question so "this job" and "here" make sense, and used to
  /// pick suggestions on the welcome screen. Set by [showAssistantPanel].
  String pageContext = '';
  String pagePath = '';

  /// Thumbs up / down on an answer. Fire and forget: the server only logs it, so a failure is not worth showing.
  Future<void> sendFeedback(String rating, String? question, String answer) async {
    try {
      await http
          .post(
            Uri.parse('$kApiBaseUrl/api/assistant/feedback'),
            headers: AuthSession.instance.headers(),
            body: json.encode({'rating': rating, 'question': question, 'answer': answer}),
          )
          .timeout(const Duration(seconds: 15));
    } catch (_) {}
  }

  bool get canAddChat => !busy && messages.isNotEmpty && chats.length < maxChats;

  /// Starts a fresh chat. If the current one is still empty there is nothing to start.
  void newChat() {
    if (!canAddChat) return;
    chats.add(AssistantConversation());
    _switchTo(chats.length - 1);
  }

  /// Called when the panel opens: lands on the welcome screen while the earlier chat stays in the side list. Reuses an
  /// empty chat if there is one. Does nothing while a question is in flight, when the current chat is already empty, or
  /// when the list is full of used chats.
  void openFresh() {
    if (busy || messages.isEmpty) return;
    final empty = chats.indexWhere((c) => c.messages.isEmpty && c.title == null);
    if (empty >= 0) {
      selectChat(empty);
    } else {
      newChat();
    }
  }

  void selectChat(int i) {
    if (busy || i < 0 || i >= chats.length || i == active) return;
    _switchTo(i);
  }

  void renameChat(int i, String name) {
    if (i < 0 || i >= chats.length) return;
    final t = name.trim();
    chats[i].title = t.isEmpty ? null : (t.length > 60 ? t.substring(0, 60) : t);
    _save();
    notifyListeners();
  }

  void deleteChat(int i) {
    if (busy || i < 0 || i >= chats.length) return;
    chats.removeAt(i);
    if (chats.isEmpty) chats.add(AssistantConversation());
    active = active > i || active >= chats.length ? (active - 1).clamp(0, chats.length - 1) : active;
    _switchTo(active);
  }

  void _switchTo(int i) {
    active = i;
    chatChanges++;
    stopped = false;
    error = null;
    _save();
    notifyListeners();
  }

  bool busy = false;
  String? status; // what the server says it is doing right now ("Checking what is owed…"), while busy
  http.Client? _client;

  /// The answer as written so far. Text that arrives (a stream, or a whole answer from a server that does not stream) goes
  /// into [_streamPending] and is written out to [streamText] at a steady pace, so it reads like typing even when the
  /// network or the model delivers it in one burst. Cleared when the answer lands, when a lookup starts (that turn was
  /// not the answer) and on stop.
  String streamText = '';
  String _streamPending = '';
  Timer? _typeTimer;
  Completer<void>? _caughtUp;
  bool lastAnswerStreamed = false; // the newest answer was already on screen as it arrived, so it must not replay

  /// Whether an answer from a server that does not stream is also written out gradually. Tests switch this off.
  static bool animateAnswers = true;

  void _streamReset() {
    _typeTimer?.cancel();
    _typeTimer = null;
    _streamPending = '';
    streamText = '';
    _caughtUp?.complete();
    _caughtUp = null;
  }

  void _typeFrom(String text) {
    _streamPending += text;
    _typeTimer ??= Timer.periodic(const Duration(milliseconds: 33), (_) => _typeTick());
  }

  /// Reveals a little more of what has arrived: at least ~90 characters a second, and faster when far behind, so the
  /// view is never more than a couple of seconds behind the text.
  void _typeTick() {
    final backlog = _streamPending.length - streamText.length;
    if (backlog <= 0) {
      _typeTimer?.cancel();
      _typeTimer = null;
      _caughtUp?.complete();
      _caughtUp = null;
      return;
    }
    final int step = math.max<int>(3, backlog ~/ 60);
    int end = math.min<int>(_streamPending.length, streamText.length + step);
    final unit = _streamPending.codeUnitAt(end - 1);
    if (end < _streamPending.length && unit >= 0xD800 && unit <= 0xDBFF) end++; // never split an emoji in half
    streamText = _streamPending.substring(0, end);
    notifyListeners();
  }

  Future<void> _typeUntilCaughtUp() async {
    if (streamText.length >= _streamPending.length) return;
    final done = _caughtUp = Completer<void>();
    await done.future.timeout(const Duration(seconds: 12), onTimeout: () {});
  }

  String? error;
  DateTime? busySince;
  bool stopped = false; // the last question was cancelled by the user
  int _gen = 0; // bumped by stop() so a late reply to a cancelled question is ignored

  /// Cancels the question in flight. The server may still finish it, but the reply is dropped.
  void stop() {
    if (!busy) return;
    _gen++;
    _client?.close(); // drops the connection, so a streaming answer stops being read
    _streamReset();
    busy = false;
    busySince = null;
    status = null;
    stopped = true;
    notifyListeners();
  }

  void _onAuthChanged() {
    if (!AuthSession.instance.isLoggedIn) clear();
  }

  // --- Saved conversation ----------------------------------------------------------
  // The thread is kept on this device so it is still there after a restart. It is tied to the signed-in
  // name and wiped on sign-out, "New conversation" and when someone else signs in.
  static const _storeKey = 'iohd_assistant_chat';
  static const _keepMessages = 40;
  Future<void>? _loading;
  bool get loadDone => _loadDone;
  bool _loadDone = false; // nothing is written to storage until the saved thread has been read, or it would be overwritten
  int _loadGen = 0; // bumped by clear() so a read that finishes after a sign-out cannot bring the old thread back

  /// Brings back the saved thread once per app run. Safe to call every time the panel opens. A question asked before
  /// it finishes is kept: the saved chats are placed before it instead of replacing it.
  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    final gen = _loadGen;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storeKey);
      if (raw == null || gen != _loadGen) return;
      final d = json.decode(raw) as Map<String, dynamic>;
      if (d['user'] != AuthSession.instance.name) return;
      // Older saves hold one thread under "messages", then a list of message lists under "tabs"; the
      // current format is a list of {title, messages} under "tabs".
      final saved = d['tabs'] is List ? d['tabs'] as List : [d['messages'] ?? const []];
      final loaded = <AssistantConversation>[];
      for (final t in saved.take(maxChats)) {
        final convo = AssistantConversation();
        if (t is Map) convo.title = (t['title'] as String?)?.trim().isEmpty ?? true ? null : t['title'] as String;
        for (final m in ((t is Map ? t['messages'] : t) as List? ?? const [])) {
          final role = m['role'] == 'user' ? AssistantRole.user : AssistantRole.assistant;
          final text = (m['text'] ?? '').toString();
          if (text.isEmpty) continue;
          convo.messages.add(
            AssistantMessage(
              role,
              text,
              [for (final x in (m['sources'] as List? ?? const [])) x.toString()],
              [for (final x in (m['calls'] as List? ?? const [])) x.toString()],
            )..fresh = false,
          );
        }
        while (convo.messages.isNotEmpty && convo.messages.first.role != AssistantRole.user) {
          convo.messages.removeAt(0);
        }
        loaded.add(convo);
      }
      if (loaded.isEmpty) return;
      final mine = chats.where((c) => c.messages.isNotEmpty).toList();
      if (mine.isEmpty) {
        chats
          ..clear()
          ..addAll(loaded);
        active = ((d['active'] as num?)?.toInt() ?? 0).clamp(0, chats.length - 1);
      } else {
        // The person started typing before the saved thread arrived: keep what they have, with the saved chats first.
        final current = chats[active];
        final room = (maxChats - mine.length).clamp(0, maxChats);
        chats
          ..clear()
          ..addAll(loaded.take(room))
          ..addAll(mine);
        active = chats.indexOf(current).clamp(0, chats.length - 1);
      }
      chatChanges++;
      notifyListeners();
    } catch (_) {
      // unreadable storage: start with an empty chat
    } finally {
      if (gen == _loadGen) {
        _loadDone = true;
        if (chats.any((c) => c.messages.isNotEmpty)) _save(); // writes the merged thread, if there is one
      }
    }
  }

  Future<void> _save() async {
    if (!_loadDone) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (chats.every((c) => c.messages.isEmpty && c.title == null)) {
        await prefs.remove(_storeKey);
        return;
      }
      await prefs.setString(
        _storeKey,
        json.encode({
          'user': AuthSession.instance.name,
          'active': active,
          'tabs': [
            for (final c in chats)
              {
                'title': c.title,
                'messages': [
                  for (final m
                      in (c.messages.length > _keepMessages ? c.messages.sublist(c.messages.length - _keepMessages) : c.messages))
                    {'role': m.role.name, 'text': m.text, 'sources': m.sources, 'calls': m.calls},
                ],
              },
          ],
        }),
      );
    } catch (_) {}
  }

  /// Replaces an earlier question with new wording and asks again. Everything after it is dropped, since
  /// those answers were to the old question.
  Future<void> editAndResend(int index, String text) {
    final q = text.trim();
    if (busy || q.isEmpty || index < 0 || index >= messages.length || messages[index].role != AssistantRole.user) {
      return Future.value();
    }
    if (q.length > _maxChars) {
      error = 'That question is too long. Keep it under $_maxChars characters.';
      notifyListeners();
      return Future.value();
    }
    messages.removeRange(index, messages.length);
    return send(q);
  }

  /// Wipes every chat (sign-out, a different user). Use [deleteChat] to drop just one.
  void clear() {
    _gen++;
    _client?.close();
    _streamReset();
    status = null;
    _loadGen++;
    _loadDone = true; // there is nothing left to read back
    _loading ??= Future.value();
    chats
      ..clear()
      ..add(AssistantConversation());
    active = 0;
    chatChanges++;
    stopped = false;
    busy = false;
    error = null;
    _save();
    notifyListeners();
  }

  Future<void> send(String text) async {
    final q = text.trim();
    if (q.isEmpty || busy) return;
    if (q.length > _maxChars) {
      error = 'That question is too long. Keep it under $_maxChars characters.';
      notifyListeners();
      return;
    }
    messages.add(AssistantMessage(AssistantRole.user, q));
    await _ask();
  }

  Future<void> retry() => busy ? Future.value() : _ask();

  /// Drops the last answer and asks again.
  Future<void> regenerate() {
    if (busy || messages.isEmpty) return Future.value();
    if (messages.last.role == AssistantRole.assistant) messages.removeLast();
    return _ask();
  }

  List<Map<String, String>> _payload() {
    final list = List<AssistantMessage>.from(messages);
    while (list.length > _sendMessages) {
      list.removeAt(0);
    }
    while (list.isNotEmpty && list.first.role != AssistantRole.user) {
      list.removeAt(0);
    }
    return [
      for (final m in list)
        {
          'role': m.role == AssistantRole.user ? 'user' : 'assistant',
          'content': m.text.length > _maxChars ? m.text.substring(0, _maxChars) : m.text,
        },
    ];
  }

  /// Sends the question and returns the status code and JSON body. Asks the server for progress events and shows them
  /// as they arrive; a server that does not stream (older build, or an error before the answer starts) replies with
  /// plain JSON, which is handled the same way.
  Future<(int, Map<String, dynamic>)> _exchange(int gen) async {
    final client = http.Client();
    _client = client;
    try {
      final req = http.Request('POST', Uri.parse('$kApiBaseUrl/api/assistant'))
        ..headers.addAll(AuthSession.instance.headers())
        ..body = json.encode({'messages': _payload(), 'stream': true, if (pageContext.isNotEmpty) 'context': pageContext});
      final started = DateTime.now();
      // Debug runs only: when each piece of the stream reaches the app, so "it all appears at once" can be told apart from
      // "it arrives piece by piece but is not drawn" in the console.
      void trace(String what) {
        if (kDebugMode) debugPrint('[assistant stream] +${DateTime.now().difference(started).inMilliseconds}ms $what');
      }

      final res = await client.send(req);
      trace('response started, content-type=${res.headers['content-type']}');
      if (!(res.headers['content-type'] ?? '').contains('text/event-stream')) {
        Map<String, dynamic> body = const {};
        try {
          body = json.decode(await res.stream.bytesToString()) as Map<String, dynamic>;
        } catch (_) {}
        return (res.statusCode, body);
      }
      (int, Map<String, dynamic>)? result;
      await for (final line in res.stream.transform(utf8.decoder).transform(const LineSplitter())) {
        if (gen != _gen) break;
        if (!line.startsWith('data:')) continue; // heartbeat comments and blank separators
        final Map<String, dynamic> event;
        try {
          event = json.decode(line.substring(5)) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }
        final type = event['type'];
        trace(type == 'delta' ? 'delta (${(event['text'] ?? '').toString().length} chars)' : '$type');
        if (type == 'status') {
          status = event['text']?.toString();
          notifyListeners();
        } else if (type == 'delta') {
          _typeFrom(event['text']?.toString() ?? '');
        } else if (type == 'reset') {
          _streamReset(); // that turn was a lookup, not the answer
          notifyListeners();
        } else if (type == 'done' || type == 'error') {
          result = ((event['status'] as num?)?.toInt() ?? 200, event); // the server closes the stream right after this
        }
      }
      return result ?? (502, const {'error': 'The connection closed before the answer arrived. Try again.'});
    } finally {
      client.close();
      if (identical(_client, client)) _client = null;
    }
  }

  Future<void> _ask() async {
    final gen = ++_gen;
    busy = true;
    busySince = DateTime.now();
    stopped = false;
    error = null;
    status = null;
    lastAnswerStreamed = false;
    _streamReset();
    notifyListeners();

    try {
      // free-tier hosts wake slowly and answers can take a few lookups
      final (code, body) = await _exchange(gen).timeout(const Duration(seconds: 120));

      if (gen != _gen) return; // cancelled while waiting

      // A server that sent the answer in one piece: write it out like the streamed ones. Then let any streamed text finish
      // writing before the finished answer takes its place.
      if (code == 200 && animateAnswers && streamText.isEmpty && _streamPending.isEmpty) {
        final whole = (body['answer'] ?? '').toString().trim();
        if (whole.isNotEmpty) _typeFrom(whole);
      }
      await _typeUntilCaughtUp();
      if (gen != _gen) return;

      switch (code) {
        case 200:
          final answer = (body['answer'] ?? '').toString().trim();
          final tools = <String>{
            for (final t in (body['toolsUsed'] as List? ?? const []))
              if (_toolLabels[t] != null) _toolLabels[t]!,
          }.toList();
          final calls = <String>[
            for (final c in (body['calls'] as List? ?? const []))
              if (c is Map) ?_describeCall(c['tool']?.toString() ?? '', c['input']?.toString() ?? ''),
          ];
          // An answer that was already on screen as it was written must not fade in a second time.
          lastAnswerStreamed = streamText.isNotEmpty;
          messages.add(
            AssistantMessage(
              AssistantRole.assistant,
              answer.isEmpty ? "I couldn't put together an answer. Try rephrasing." : answer,
              tools,
              calls.take(14).toList(),
            )..fresh = !lastAnswerStreamed,
          );
          _save();
        case 401:
          // Set the message first: logout() wipes the chat (and its error) through the auth listener, and an error
          // set afterwards would linger and greet the next person who signs in.
          error = 'Your session expired. Please sign in again.';
          AuthSession.instance.logout(); // sends the app back to the sign-in screen
        case 403:
          error = 'Your account does not have access to the assistant.';
        case 503:
          error = 'The assistant is not set up on the server yet.';
        default:
          error = (body['error'] ?? 'Server error ($code).').toString();
      }
    } on TimeoutException {
      _client?.close();
      if (gen == _gen) error = 'That took too long. The server may be waking up, so try again in a moment.';
    } catch (_) {
      if (gen == _gen) error = "Couldn't reach the server. Check your connection and try again.";
    } finally {
      if (gen == _gen) {
        _streamReset();
        busy = false;
        busySince = null;
        status = null;
        notifyListeners();
      }
    }
  }
}

/// Opens the assistant as a panel sliding in from the right, over whatever screen you are on.
Future<void> showAssistantPanel(BuildContext context) {
  final chat = AssistantChat.instance;
  try {
    final uri = GoRouterState.of(context).uri;
    chat.pagePath = uri.path;
    chat.pageContext = _pageLabel(uri);
  } catch (_) {
    chat.pagePath = ''; // not under a router (tests, previews)
    chat.pageContext = '';
  }
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close assistant',
    barrierColor: Colors.black.withValues(alpha: 0.25),
    transitionDuration: const Duration(milliseconds: 240),
    pageBuilder: (_, _, _) => const Align(alignment: Alignment.centerRight, child: _AssistantPanel()),
    transitionBuilder: (_, animation, _, child) => SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: child,
    ),
  );
}

/// A plain-English name for the screen the person is on, for the assistant ("Job 1096719829 detail page").
String _pageLabel(Uri uri) {
  final seg = uri.pathSegments;
  if (seg.length >= 2 && (seg[0] == 'jobs' || seg[0] == 'estimates')) {
    return '${seg[0] == 'jobs' ? 'Job' : 'Estimate'} ${seg[1]} detail page';
  }
  if (seg.length >= 3 && seg[0] == 'hr' && seg[1] == 'kpis') return 'One employee\'s KPI page';
  const names = {
    '/dashboards/financial': 'Financial dashboard',
    '/dashboards/commissions': 'Commissions dashboard',
    '/dashboards/technicians': 'Technicians dashboard',
    '/dashboards/inventory': 'Inventory dashboard',
    '/dashboards/jobs': 'Jobs dashboard',
    '/dashboards/estimates': 'Estimates dashboard',
    '/dashboards/sales': 'Sales dashboard',
    '/dashboards/collections': 'Collections dashboard',
    '/jobs': 'Jobs list',
    '/estimates': 'Estimates list',
    '/customers': 'Customers list',
    '/calendar': 'Calendar',
    '/inventory': 'Inventory list',
    '/documents': 'Documents',
    '/hr/payroll': 'Payroll',
    '/hr/kpis': 'Employee KPIs',
    '/hr/team': 'Team admin',
    '/hr/corrections': 'Commission corrections',
  };
  return names[uri.path] ?? (seg.isEmpty ? '' : '${seg.join(' / ')} page');
}

/// Welcome-screen suggestions: a few for the page you are on, then the general ones to fill six.
List<_Suggestion> _suggestionsFor(String path) {
  const pages = <String, List<_Suggestion>>{
    '/dashboards/collections': [
      _Suggestion(Icons.warning_amber_rounded, 'Over 90 days', 'Which customers have balances over 90 days, and how much?'),
      _Suggestion(Icons.trending_up_rounded, 'Balance trend', 'How has our outstanding balance changed over the last 30 days?'),
    ],
    '/dashboards/financial': [
      _Suggestion(Icons.show_chart_rounded, 'Profit by month', 'Show completed revenue and profit by month this year.'),
      _Suggestion(
        Icons.pie_chart_outline_rounded,
        'Revenue mix',
        'What is our revenue mix between residential and commercial this year?',
      ),
    ],
    '/dashboards/jobs': [
      _Suggestion(Icons.hourglass_bottom_rounded, 'Stuck jobs', 'Which active jobs have been in the same status the longest?'),
      _Suggestion(Icons.list_alt_rounded, 'Open by status', 'How many open jobs are in each status right now?'),
    ],
    '/dashboards/estimates': [
      _Suggestion(Icons.handshake_outlined, 'Win rate', 'What is our estimate win rate by month this year?'),
      _Suggestion(Icons.hourglass_empty_rounded, 'No follow-up', 'Which open estimates have not changed status in over 14 days?'),
    ],
    '/dashboards/sales': [
      _Suggestion(Icons.leaderboard_outlined, 'By salesperson', 'How are the salespeople doing on estimates this year?'),
      _Suggestion(Icons.door_front_door_outlined, 'Door types', 'Which door styles do we win the most revenue on this year?'),
    ],
    '/dashboards/technicians': [
      _Suggestion(Icons.engineering_outlined, 'Tech activity', 'How many days and visits did each technician work this month?'),
      _Suggestion(Icons.undo_rounded, 'Callbacks', 'How many callbacks have we had this month and who were they on?'),
    ],
    '/dashboards/commissions': [
      _Suggestion(Icons.payments_outlined, 'This week\'s pay', 'What does payroll look like for this week?'),
      _Suggestion(Icons.savings_outlined, 'Pool balance', 'What is in the retainage and company pool right now?'),
    ],
    '/dashboards/inventory': [
      _Suggestion(Icons.inventory_2_outlined, 'Low stock', 'Which inventory items are low on stock?'),
      _Suggestion(Icons.fact_check_outlined, 'Cycle counts', 'Where are we on this month\'s cycle counts?'),
    ],
    '/customers': [
      _Suggestion(Icons.person_search_outlined, 'Lapsed customers', 'Which good customers have not had a job in the last year?'),
      _Suggestion(Icons.groups_outlined, 'Top customers', 'Who are our top 10 customers by revenue this year?'),
    ],
    '/calendar': [_Suggestion(Icons.event_available_outlined, 'This week', 'What is scheduled for the technicians this week?')],
    '/hr/kpis': [
      _Suggestion(Icons.star_outline_rounded, 'Reviews', 'How are our Google reviews doing, and which techs are mentioned most?'),
    ],
  };
  final seg = path.split('/').where((s) => s.isNotEmpty).toList();
  final here = (seg.length >= 2 && seg[0] == 'jobs')
      ? const [
          _Suggestion(
            Icons.summarize_outlined,
            'Summarize this job',
            'Summarize this job: status, what is owed, payments, and any notes or tasks.',
          ),
          _Suggestion(Icons.history_rounded, 'Status history', 'Show the status history of this job.'),
        ]
      : (pages[path] ?? const <_Suggestion>[]);
  final out = [...here];
  for (final s in _suggestions) {
    if (out.length >= 6) break;
    if (!out.any((o) => o.title == s.title)) out.add(s);
  }
  return out;
}

// =============================================================================
// Answer parsing
// =============================================================================

sealed class _Block {}

class _Para extends _Block {
  final String text;
  bool tight = false; // the next line continues straight on, so only a small gap follows
  _Para(this.text);
}

class _Rule extends _Block {}

class _Code extends _Block {
  final String text;
  _Code(this.text);
}

class _Head extends _Block {
  final String text;
  _Head(this.text);
}

class _Item extends _Block {
  final String text;
  final String? number; // null = bullet
  final int level; // nesting depth, 0 = top level
  _Item(this.text, this.number, [this.level = 0]);
}

class _Table extends _Block {
  final List<List<String>> rows; // first row is the header
  _Table(this.rows);
}

class _Stats extends _Block {
  final List<(String value, String label)> items;
  _Stats(this.items);
}

/// A `::: chart` block: one or more series over labelled points (months, customers, ...).
class _Chart extends _Block {
  final String kind; // line | bar | hbar
  final String title;
  final String format; // money | count | percent
  final List<String> series;
  final List<(String label, List<double> values)> points;
  _Chart(this.kind, this.title, this.format, this.series, this.points);
}

class _Parsed {
  final List<_Block> blocks;
  final List<String> followUps;
  final String plain;
  _Parsed(this.blocks, this.followUps, this.plain);
}

final RegExp _bulletRe = RegExp(r'^\s*[-*•]\s+');
final RegExp _numberedRe = RegExp(r'^\s*(\d+)[.)]\s+');
final RegExp _headingRe = RegExp(r'^\s{0,3}#{1,6}\s+(.*)$');
final RegExp _ruleRe = RegExp(r'^\s{0,3}([-*_])(\s*\1){2,}\s*$');
final RegExp _fenceRe = RegExp(r'^\s{0,3}(```|~~~)');
final RegExp _dashCellRe = RegExp(r'^:?-{2,}:?$');
final RegExp _directiveRe = RegExp(r'^\s*:::\s*(stats|followups|chart)\b.*$', caseSensitive: false);

/// Plain text of a line: **bold**, *italic*, `code` and [links](url) lose their markers. Used where the text is
/// shown without rich formatting (table cells, figures, chart labels, copied text).
String _stripMd(String s) => s.replaceAllMapped(_inlineRe, (m) => m.group(1) ?? m.group(2) ?? m.group(3) ?? m.group(4) ?? '');

/// Reads the body of a `::: chart` block:
///   type: line | bar | hbar      title: ...      format: money | count | percent      series: Revenue | Profit
///   then one "label | value | value" line per point. Returns null when there are fewer than two usable points.
_Chart? _parseChart(List<String> body) {
  var kind = 'bar';
  var title = '';
  var format = 'count';
  var series = <String>[];
  final points = <(String, List<double>)>[];
  for (final b in body) {
    final kv = RegExp(r'^(type|title|format|series)\s*:\s*(.*)$', caseSensitive: false).firstMatch(b);
    if (kv != null) {
      final k = kv.group(1)!.toLowerCase();
      final v = kv.group(2)!.trim();
      if (k == 'type') kind = v.toLowerCase();
      if (k == 'title') title = _stripMd(v);
      if (k == 'format') format = v.toLowerCase();
      if (k == 'series') series = v.split('|').map((s) => _stripMd(s.trim())).where((s) => s.isNotEmpty).toList();
      continue;
    }
    final parts = b.split('|').map((p) => p.trim()).toList();
    if (parts.length < 2) continue;
    final values = <double>[];
    for (final p in parts.skip(1)) {
      final n = double.tryParse(p.replaceAll(RegExp(r'[\$,%\s]'), ''));
      if (n != null && n.isFinite) values.add(n); // "NaN" and "Infinity" parse as numbers and would break the axis
    }
    if (values.isEmpty) continue;
    points.add((_stripMd(parts.first), values));
  }
  if (points.length < 2) return null;
  final width = points.map((p) => p.$2.length).reduce((a, b) => a < b ? a : b).clamp(1, 3);
  final trimmed = [for (final p in points.take(24)) (p.$1, p.$2.take(width).toList())];
  if (!const {'line', 'bar', 'hbar'}.contains(kind)) kind = 'bar';
  if (kind == 'hbar' && width > 1) kind = 'bar';
  if (series.length != width) series = width == 1 ? [] : [for (var i = 0; i < width; i++) 'Series ${i + 1}'];
  return _Chart(kind, title, format, series, trimmed);
}

/// The part of a half-written answer that is safe to draw: no half-typed line of markdown, and no stats / chart block or
/// table until it is complete, so nothing flashes raw "::: chart" text or jumps from paragraph to table.
String _streamSafe(String text) {
  final lines = text.split('\n');
  // The last line is still being typed unless the text ends with a newline: show it up to any marker that is not closed yet
  // (a bold, italic, code or link still open), and none of it if it is the start of a table row or directive.
  if (lines.isNotEmpty && lines.last.isNotEmpty) {
    final l = lines.last;
    if (l.trimLeft().startsWith(':') || l.trimLeft().startsWith('|')) {
      lines.removeLast();
    } else {
      final off = _bulletRe.firstMatch(l)?.end ?? 0; // a leading "* " bullet is not an italic marker
      final rest = l.substring(off);
      var cut = rest.length;
      void openAt(int i) {
        if (i >= 0 && i < cut) cut = i;
      }

      if ('**'.allMatches(rest).length.isOdd) openAt(rest.lastIndexOf('**'));
      if ('`'.allMatches(rest).length.isOdd) openAt(rest.lastIndexOf('`'));
      final lb = rest.lastIndexOf('[');
      if (lb >= 0 && rest.indexOf(')', lb) < 0) openAt(lb);
      if (rest.replaceAll('**', '').split('*').length.isEven) openAt(rest.lastIndexOf(RegExp(r'(?<!\*)\*(?!\*)')));
      lines[lines.length - 1] = l.substring(0, off + cut);
    }
  }
  // an opened directive block with no closing ::: yet
  int? open;
  for (var i = 0; i < lines.length; i++) {
    if (_directiveRe.hasMatch(lines[i].trimRight())) {
      open = i;
    } else if (open != null && lines[i].trim() == ':::') {
      open = null;
    }
  }
  if (open != null) lines.removeRange(open, lines.length);
  // a table with only its header so far
  var end = lines.length;
  while (end > 0 && _isRow(lines[end - 1])) {
    end--;
  }
  final tail = lines.sublist(end).where((l) => !_cells(l).every((c) => _dashCellRe.hasMatch(c))).length;
  if (end < lines.length && tail < 2) lines.removeRange(end, lines.length);
  return lines.join('\n');
}

/// What [_streamSafe] is keeping off screen right now, in words ("Drawing the chart…"), or null when nothing is held back.
String? _streamHolding(String text) {
  final lines = text.split('\n');
  String? open;
  for (final l in lines) {
    final m = _directiveRe.firstMatch(l.trimRight());
    if (m != null) {
      open = m.group(1)!.toLowerCase();
    } else if (open != null && l.trim() == ':::') {
      open = null;
    }
  }
  switch (open) {
    case 'chart':
      return 'Drawing the chart…';
    case 'stats':
      return 'Adding the key figures…';
    default:
      break;
  }
  var end = lines.length;
  while (end > 0 && _isRow(lines[end - 1])) {
    end--;
  }
  if (end < lines.length) return 'Building the table…';
  return null;
}

bool _isRow(String l) {
  final t = l.trim();
  return t.startsWith('|') && t.endsWith('|') && t.length > 2 && t.split('|').length >= 4;
}

List<String> _cells(String l) {
  var t = l.trim();
  if (t.startsWith('|')) t = t.substring(1);
  if (t.endsWith('|')) t = t.substring(0, t.length - 1);
  return t.split('|').map((c) => c.trim()).toList();
}

/// Understands the slice of markdown the assistant uses (**bold**, bullets, numbered lists, ## headings,
/// pipe tables) plus two directive blocks: `::: stats` ("value | label" lines) and `::: followups`.
_Parsed _parse(String text) {
  final lines = text.split('\n');
  final blocks = <_Block>[];
  final followUps = <String>[];
  final plain = <String>[];
  _Para? prevPara; // the previous plain line, when nothing but a line break separates it from this one
  var i = 0;
  while (i < lines.length) {
    final line = lines[i].trimRight();

    final directive = _directiveRe.firstMatch(line);
    if (directive != null) {
      prevPara = null;
      final kind = directive.group(1)!.toLowerCase();
      final body = <String>[];
      final opened = i;
      i++;
      while (i < lines.length && lines[i].trim() != ':::') {
        if (lines[i].trim().isNotEmpty) body.add(lines[i].trim());
        i++;
      }
      if (i >= lines.length && kind != 'followups') {
        // The model never closed a stats/chart block. Drop just the opening line and read the rest as normal text, instead
        // of swallowing the whole remainder of the answer into a block that then shows nothing. (Follow-ups are always
        // last, so an unclosed one still reads to the end.)
        i = opened + 1;
        continue;
      }
      i++; // closing :::
      if (kind == 'chart') {
        final chart = _parseChart(body);
        if (chart != null) {
          if (chart.points.length < (chart.kind == 'hbar' ? 5 : 4)) {
            // Too few points to be worth drawing (a chart of three bars says less than a sentence): show the numbers as a list.
            if (chart.title.isNotEmpty) blocks.add(_Para('**${chart.title}**')..tight = true);
            for (final p in chart.points) {
              final values = [
                for (var i = 0; i < p.$2.length; i++)
                  '${chart.series.length > i ? '${chart.series[i]} ' : ''}${_chartFull(p.$2[i], chart.format)}',
              ];
              blocks.add(_Item('${p.$1}: ${values.join(', ')}', null));
            }
          } else {
            blocks.add(chart);
          }
          // Copied text: the chart as a small list with formatted values, e.g. "Jan: Revenue $213,573, Profit $111,840".
          plain.add(chart.title.isEmpty ? 'Chart' : chart.title);
          for (final p in chart.points) {
            final values = [
              for (var s = 0; s < p.$2.length; s++)
                '${chart.series.length > s ? '${chart.series[s]} ' : ''}${_chartFull(p.$2[s], chart.format)}',
            ];
            plain.add('- ${p.$1}: ${values.join(', ')}');
          }
        }
      } else if (kind == 'stats') {
        final items = <(String, String)>[];
        for (final b in body) {
          final parts = b.split('|');
          if (parts.length >= 2) items.add((_stripMd(parts.first.trim()), _stripMd(parts.sublist(1).join('|').trim())));
        }
        if (items.length == 1) {
          // One headline number is a sentence, not a scoreboard.
          blocks.add(_Para('**${items.first.$2}:** ${items.first.$1}'));
        } else if (items.isNotEmpty) {
          blocks.add(_Stats(items.take(4).toList()));
          // Copied text: one "label: value" line per card, instead of the cards vanishing or running together.
          for (final it in items.take(4)) {
            plain.add('${it.$2}: ${it.$1}');
          }
        }
      } else {
        for (final b in body) {
          final q = b.replaceFirst(_bulletRe, '').trim();
          if (q.isNotEmpty) followUps.add(q);
        }
      }
      continue;
    }

    if (_isRow(line)) {
      prevPara = null;
      final tableLines = <String>[];
      while (i < lines.length && _isRow(lines[i])) {
        tableLines.add(lines[i]);
        plain.add(_stripMd(lines[i]));
        i++;
      }
      final rows = [for (final l in tableLines) _cells(l)].where((r) => !r.every((c) => _dashCellRe.hasMatch(c))).toList();
      if (rows.length >= 2) {
        blocks.add(_Table(rows));
      } else {
        for (final l in tableLines) {
          blocks.add(_Para(l));
        }
      }
      continue;
    }

    if (_fenceRe.hasMatch(line)) {
      // A code fence: shown as-is in a monospace box, not read as bullets and headings.
      final code = <String>[];
      i++;
      while (i < lines.length && !_fenceRe.hasMatch(lines[i])) {
        code.add(lines[i].trimRight());
        i++;
      }
      if (i < lines.length) i++; // closing fence
      if (code.isNotEmpty) {
        blocks.add(_Code(code.join('\n')));
        plain.addAll(code);
      }
      prevPara = null;
      continue;
    }

    i++;
    final heading = _headingRe.firstMatch(line);
    final numbered = _numberedRe.firstMatch(line);
    plain.add(_stripMd(heading != null ? heading.group(1)! : line));
    if (line.trim().isEmpty) {
      prevPara = null;
      continue;
    }
    int level() => ((line.length - line.trimLeft().length) ~/ 2).clamp(0, 3);
    if (_ruleRe.hasMatch(line)) {
      blocks.add(_Rule());
      prevPara = null;
    } else if (heading != null) {
      blocks.add(_Head(heading.group(1)!));
      prevPara = null;
    } else if (_bulletRe.hasMatch(line)) {
      blocks.add(_Item(line.replaceFirst(_bulletRe, ''), null, level()));
      prevPara = null;
    } else if (numbered != null) {
      blocks.add(_Item(line.replaceFirst(_numberedRe, ''), numbered.group(1), level()));
      prevPara = null;
    } else {
      final para = _Para(line.replaceFirst(RegExp(r'^\s*>\s?'), '')); // a stray "> quote" marker is not shown
      prevPara?.tight = true;
      blocks.add(para);
      prevPara = para;
    }
  }
  return _Parsed(blocks, followUps.take(3).toList(), plain.join('\n').trim());
}

// =============================================================================
// Panel
// =============================================================================

class _AssistantPanel extends StatefulWidget {
  const _AssistantPanel();

  @override
  State<_AssistantPanel> createState() => _AssistantPanelState();
}

class _AssistantPanelState extends State<_AssistantPanel> {
  static bool _wide = false; // remembered while the app is open
  static double? _userWidth; // set by dragging the left edge
  bool _dragging = false;
  static String _draft = ''; // an unsent question survives closing the panel

  final _chat = AssistantChat.instance;
  final _input = TextEditingController();
  final _inputFocus = FocusNode();
  final _scroll = ScrollController();
  final _lastAnswerKey = GlobalKey();
  int _seen = 0;
  int _seenTab = 0;
  bool _wasBusy = false;
  String? _lastError;
  int _lastStream = 0;
  static bool? _sideChoice; // set when the person toggles the chat list; remembered while the app is open

  /// The chat list starts open on a roomy window and closed on a narrow one, where it would leave the chat a sliver.
  bool _sideOpen(double screen) => _sideChoice ?? screen >= 760;
  static const _sideWidth = 200.0;
  bool _showJump = false; // scrolled away from the bottom of a long thread

  @override
  void initState() {
    super.initState();
    _input.text = _draft;
    // Start on the welcome screen once the saved chats are in. When they already are (the panel was opened before this
    // run), that is right away rather than after the load future.
    var fresh = false;
    void openFresh() {
      if (!mounted || fresh) return;
      fresh = true;
      _chat.openFresh();
      _scrollToEnd(jump: true);
    }

    if (_chat.loadDone) WidgetsBinding.instance.addPostFrameCallback((_) => openFresh());
    _chat.ensureLoaded().then((_) => openFresh());
    _input.addListener(() => _draft = _input.text);
    _scroll.addListener(_onScroll);
    _seen = _chat.messages.length;
    _seenTab = _chat.chatChanges;
    _wasBusy = _chat.busy;
    _lastError = _chat.error;
    _chat.addListener(_onChat);
    _inputFocus.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd(jump: true));
  }

  @override
  void dispose() {
    _chat.removeListener(_onChat);
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final away = _scroll.position.maxScrollExtent - _scroll.offset > 160;
    if (away != _showJump) setState(() => _showJump = away);
  }

  /// Up arrow in an empty box brings back the last question, like a terminal.
  void _recallLast() {
    final last = _chat.messages.lastWhere(
      (m) => m.role == AssistantRole.user,
      orElse: () => AssistantMessage(AssistantRole.user, ''),
    );
    if (last.text.isEmpty) return;
    _input.text = last.text;
    _input.selection = TextSelection.collapsed(offset: last.text.length);
  }

  Future<void> _rename(int i) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(initial: _chat.chats[i].title ?? ''), // not the shortened auto-label, which ends in "…"
    );
    if (name != null) _chat.renameChat(i, name);
  }

  Future<void> _delete(int i) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this chat?'),
        content: Text('"${_chat.chats[i].label}" will be removed from this computer. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _bad),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) _chat.deleteChat(i);
  }

  /// Left list of saved chats: start a new one, switch, rename or delete.
  Widget _sidebar() {
    return Container(
      width: _sideWidth,
      decoration: const BoxDecoration(
        color: _sidebarBg,
        border: Border(right: BorderSide(color: _stroke)),
      ),
      child: ListenableBuilder(
        listenable: _chat,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 14, 10, 6),
              child: _NewChatButton(onTap: _chat.canAddChat ? _chat.newChat : null),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(18, 10, 16, 4),
              child: Text(
                'Recents',
                style: TextStyle(fontSize: 12, color: _muted, fontWeight: FontWeight.w500),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                children: [
                  for (var i = _chat.chats.length - 1; i >= 0; i--)
                    _ChatRow(
                      label: _chat.chats[i].label,
                      selected: i == _chat.active,
                      enabled: !_chat.busy,
                      onTap: () => _chat.selectChat(i),
                      onRename: () => _rename(i),
                      onDelete: () => _delete(i),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
              child: Text(
                _chat.chats.length >= AssistantChat.maxChats
                    ? 'Chat limit reached. Delete one to start another.'
                    : '${_chat.chats.length} of ${AssistantChat.maxChats} chats',
                style: const TextStyle(fontSize: 11, color: _muted),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _onChat() {
    if (_chat.chatChanges != _seenTab) {
      // A different conversation: show it from the bottom without treating it as a new answer.
      _seenTab = _chat.chatChanges;
      _seen = _chat.messages.length;
      _wasBusy = _chat.busy;
      _lastError = _chat.error;
      // An empty chat has nothing to scroll, so the "Latest" button would be left hanging with no list to jump in.
      if (_chat.messages.isEmpty && _showJump) setState(() => _showJump = false);
      _scrollToEnd(jump: true);
      return;
    }
    final n = _chat.messages.length;
    final newAnswer = n > _seen && _chat.messages.last.role == AssistantRole.assistant;
    final streamLen = _chat.streamText.length;
    final streaming = streamLen != _lastStream;
    final changed = n != _seen || _chat.busy != _wasBusy || _chat.error != _lastError || streaming;
    _seen = n;
    _wasBusy = _chat.busy;
    _lastError = _chat.error;
    _lastStream = streamLen;
    if (!changed) return; // a rename or other metadata change should not move the thread
    if (streaming) {
      // follow the words as they are written, unless the person has scrolled up to read something
      if (!_showJump) _scrollToEnd(jump: true);
      return;
    }
    if (newAnswer && !_chat.lastAnswerStreamed) {
      // Start reading a new answer at its first line, not its last.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _lastAnswerKey.currentContext;
        if (ctx != null && ctx.mounted) {
          Scrollable.ensureVisible(ctx, alignment: 0.0, duration: const Duration(milliseconds: 350), curve: Curves.easeOutCubic);
        }
      });
    } else {
      _scrollToEnd();
    }
  }

  void _scrollToEnd({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final end = _scroll.position.maxScrollExtent;
      if (jump) {
        _scroll.jumpTo(end);
      } else {
        _scroll.animateTo(end, duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
      }
    });
  }

  void _submit([String? text]) {
    final q = (text ?? _input.text).trim();
    if (q.isEmpty || _chat.busy) return;
    if (text == null) _input.clear(); // a suggestion or follow-up chip must not wipe what is being typed
    _chat.send(q);
    _inputFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context).width;
    // The panel is a share of the window, so it grows and shrinks with it. Dragging the left edge sets an
    // exact width instead, until the wide/narrow button is pressed.
    final sideOpen = _sideOpen(screen);
    final minWidth = (sideOpen ? 680.0 : 480.0).clamp(0.0, screen);
    final auto = screen * (_wide ? 0.92 : 0.62);
    final width = (_userWidth ?? auto).clamp(minWidth, screen);
    final base = Theme.of(context);
    // Material's default purple showed up on text buttons (Retry, Cancel), selection handles and the like.
    return Theme(
      data: base.copyWith(
        colorScheme: base.colorScheme.copyWith(primary: _brandRed),
        textSelectionTheme: TextSelectionThemeData(
          cursorColor: _brandRed,
          selectionHandleColor: const Color(0xFF1A73E8),
          selectionColor: const Color(0x663390FF),
        ),
      ),
      child: Material(
        color: _paper,
        elevation: 16,
        child: Stack(
          children: [
            AnimatedContainer(
              duration: _dragging ? Duration.zero : const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              width: width,
              height: double.infinity,
              decoration: const BoxDecoration(
                border: Border(left: BorderSide(color: _stroke)),
              ),
              child: SafeArea(
                child: Row(
                  children: [
                    if (sideOpen) _sidebar(),
                    Expanded(child: _chatColumn(screen)),
                  ],
                ),
              ),
            ),
            // drag handle on the left edge
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 8,
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeLeftRight,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragStart: (_) => setState(() => _dragging = true),
                  onHorizontalDragUpdate: (d) => setState(() => _userWidth = (width - d.delta.dx).clamp(minWidth, screen)),
                  onHorizontalDragEnd: (_) => setState(() => _dragging = false),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chatColumn(double screen) {
    return Column(
      children: [
        _header(screen),
        Expanded(
          child: Stack(
            children: [
              ListenableBuilder(
                listenable: _chat,
                builder: (context, _) => _chat.messages.isEmpty && !_chat.busy ? _emptyState() : _thread(),
              ),
              // soft edge above the message box, so text fades out instead of being sliced by it
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                height: 22,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [_paper.withValues(alpha: 0), _paper],
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                bottom: 10,
                left: 0,
                right: 0,
                child: Center(
                  child: AnimatedSlide(
                    duration: const Duration(milliseconds: 180),
                    offset: _showJump ? Offset.zero : const Offset(0, 1.6),
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 180),
                      opacity: _showJump ? 1 : 0,
                      child: IgnorePointer(
                        ignoring: !_showJump,
                        child: Material(
                          color: Colors.white,
                          elevation: 2,
                          shadowColor: Colors.black.withValues(alpha: 0.12),
                          shape: const StadiumBorder(side: BorderSide(color: _stroke)),
                          child: InkWell(
                            customBorder: const StadiumBorder(),
                            onTap: _scrollToEnd,
                            child: const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.arrow_downward_rounded, size: 15, color: _slate),
                                  SizedBox(width: 6),
                                  Text(
                                    'Latest',
                                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _slate),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // soft edge so scrolled content fades under the header instead of hitting the divider
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: 14,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [_paper, _paper.withValues(alpha: 0)],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        _composer(),
      ],
    );
  }

  Widget _header(double screen) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 10, 12),
      child: Row(
        children: [
          IconButton(
            tooltip: _sideOpen(screen) ? 'Hide chats' : 'Show chats',
            onPressed: () => setState(() => _sideChoice = !_sideOpen(screen)),
            icon: Icon(_sideOpen(screen) ? Icons.menu_open_rounded : Icons.menu_rounded, size: 20),
            color: _slate,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: ListenableBuilder(
              listenable: _chat,
              builder: (context, _) {
                final current = _chat.chats[_chat.active];
                final title = current.messages.isEmpty && current.title == null ? 'Jarvis' : current.label;
                return Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, color: _ink, height: 1.2),
                );
              },
            ),
          ),
          if (screen >= 700)
            IconButton(
              tooltip: _wide ? 'Narrow view' : 'Wide view',
              onPressed: () => setState(() {
                _wide = !_wide;
                _userWidth = null;
              }),
              icon: Icon(_wide ? Icons.close_fullscreen_rounded : Icons.open_in_full_rounded, size: 18),
              color: _slate,
            ),
          ListenableBuilder(
            listenable: _chat,
            builder: (context, _) => IconButton(
              tooltip: _chat.chats.length >= AssistantChat.maxChats
                  ? 'Delete a chat to start another (${AssistantChat.maxChats} max)'
                  : 'New chat',
              onPressed: _chat.canAddChat ? _chat.newChat : null,
              icon: const Icon(Icons.add_comment_outlined, size: 19),
              color: _slate,
            ),
          ),
          IconButton(
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close_rounded, size: 20),
            color: _slate,
          ),
        ],
      ),
    );
  }

  String _greeting() {
    final h = DateTime.now().hour;
    final part = h < 12 ? 'Good morning' : (h < 18 ? 'Good afternoon' : 'Good evening');
    final first = AuthSession.instance.name.trim().split(RegExp(r'\s+')).first;
    return first.isEmpty ? part : '$part, $first';
  }

  Widget _emptyState() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 72, 28, 16),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.auto_awesome_rounded, size: 30, color: _brandRed),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        _greeting(),
                        textAlign: TextAlign.center,
                        style: _serifStyle.copyWith(fontSize: 30, fontWeight: FontWeight.w600, letterSpacing: -0.6, height: 1.15),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  'Ask about jobs, customers, revenue, estimates, inventory, payroll, reviews or the schedule. I can look things up but I can’t change anything.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14.5, color: _slate, height: 1.5),
                ),
                const SizedBox(height: 28),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final sug in _suggestionsFor(_chat.pagePath))
                      _SuggestionCard(suggestion: sug, onTap: () => _submit(sug.question)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String get _safeStream => _chat.busy ? _streamSafe(_chat.streamText) : '';

  /// The answer as it is being written, drawn like the finished one but without its buttons.
  List<Widget> _liveAnswer() {
    final text = _safeStream;
    if (text.isEmpty) return const [];
    return [
      _AnswerView(
        key: const ValueKey('live-answer'),
        message: AssistantMessage(AssistantRole.assistant, text)..fresh = false,
        streaming: true,
        isLast: false,
        onAsk: _submit,
        onRegenerate: _chat.regenerate,
        onRate: _chat.sendFeedback,
      ),
    ];
  }

  Widget _thread() {
    final msgs = _chat.messages;
    return SingleChildScrollView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 10),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < msgs.length; i++)
                if (msgs[i].role == AssistantRole.user)
                  _UserMessage(
                    key: ObjectKey(msgs[i]),
                    message: msgs[i],
                    canEdit: !_chat.busy,
                    onResend: (t) => _chat.editAndResend(i, t),
                  )
                else
                  _AnswerView(
                    key: ObjectKey(msgs[i]), // stable, so a sorted or expanded table survives the next question
                    anchorKey: i == msgs.length - 1 && !_chat.busy ? _lastAnswerKey : null,
                    message: msgs[i],
                    question: i > 0 && msgs[i - 1].role == AssistantRole.user ? msgs[i - 1].text : null,
                    onRate: _chat.sendFeedback,
                    isLast: i == msgs.length - 1 && !_chat.busy && _chat.error == null,
                    onAsk: _submit,
                    onRegenerate: _chat.regenerate,
                  ),
              ..._liveAnswer(),
              if (_chat.busy)
                _Thinking(
                  since: _chat.busySince,
                  status: _chat.status,
                  compact: _safeStream.isNotEmpty,
                  note: _streamHolding(_chat.streamText),
                  onStop: _chat.stop,
                ),
              if (_chat.stopped && !_chat.busy) _StoppedNote(onRetry: _chat.retry),
              if (_chat.error != null) _ErrorNote(message: _chat.error!, onRetry: _chat.retry),
            ],
          ),
        ),
      ),
    );
  }

  Widget _composer() {
    final focused = _inputFocus.hasFocus;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                padding: const EdgeInsets.fromLTRB(20, 6, 10, 10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(26),
                  border: Border.all(color: focused ? _brandRed.withValues(alpha: 0.4) : _stroke),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: focused ? 0.07 : 0.04),
                      blurRadius: focused ? 22 : 14,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: _composerField(),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 8, 0, 10),
                child: AnimatedBuilder(
                  animation: _input,
                  builder: (context, _) {
                    final len = _input.text.length;
                    final near = len >= _maxChars * 0.9;
                    return Text(
                      near
                          ? '$len / $_maxChars characters${len >= _maxChars ? ' · that is the limit, anything longer is cut off' : ''}'
                          : 'Enter to send · Shift+Enter for a new line · ↑ recalls your last question. '
                                'It only looks things up, but double-check important numbers.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11.5, color: len >= _maxChars ? _bad : _muted, height: 1.4),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _composerField() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Focus(
                // Enter sends, Shift+Enter adds a new line.
                onKeyEvent: (node, event) {
                  if (event is KeyDownEvent &&
                      (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter) &&
                      !HardwareKeyboard.instance.isShiftPressed) {
                    _submit();
                    return KeyEventResult.handled;
                  }
                  if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.arrowUp && _input.text.isEmpty) {
                    _recallLast();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: TextField(
                  controller: _input,
                  focusNode: _inputFocus,
                  autofocus: true,
                  minLines: 1,
                  maxLines: 6,
                  maxLength: _maxChars,
                  style: const TextStyle(fontSize: 15, color: _ink, height: 1.4),
                  cursorColor: _brandRed,
                  decoration: const InputDecoration(
                    hintText: 'Ask Jarvis about your business…',
                    hintStyle: TextStyle(fontSize: 15, color: _muted),
                    counterText: '',
                    isDense: true,
                    filled: false,
                    contentPadding: EdgeInsets.symmetric(vertical: 14),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: AnimatedBuilder(
                animation: Listenable.merge([_chat, _input]),
                builder: (context, _) {
                  if (_chat.busy) {
                    return IconButton.filled(
                      tooltip: 'Stop',
                      onPressed: _chat.stop,
                      icon: const Icon(Icons.stop_rounded, size: 20),
                      style: IconButton.styleFrom(
                        backgroundColor: _ink,
                        foregroundColor: Colors.white,
                        fixedSize: const Size(36, 36),
                        shape: const CircleBorder(),
                      ),
                    );
                  }
                  final ready = _input.text.trim().isNotEmpty;
                  return IconButton.filled(
                    tooltip: 'Send',
                    onPressed: ready ? _submit : null,
                    icon: const Icon(Icons.arrow_upward_rounded, size: 19),
                    style: IconButton.styleFrom(
                      backgroundColor: _brandRed,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: _fill,
                      disabledForegroundColor: _muted,
                      fixedSize: const Size(36, 36),
                      shape: const CircleBorder(),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _RenameDialog extends StatefulWidget {
  final String initial;
  const _RenameDialog({required this.initial});

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _c = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename chat'),
      content: TextField(
        controller: _c,
        autofocus: true,
        maxLength: 60,
        decoration: const InputDecoration(hintText: 'Chat name'),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.of(context).pop(_c.text), child: const Text('Save')),
      ],
    );
  }
}

class _ChatRow extends StatefulWidget {
  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  const _ChatRow({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  @override
  State<_ChatRow> createState() => _ChatRowState();
}

class _ChatRowState extends State<_ChatRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final sel = widget.selected;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Material(
          color: sel ? _fillStrong : (_hover ? _fillStrong.withValues(alpha: 0.5) : Colors.transparent),
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: widget.enabled ? widget.onTap : null,
            child: Padding(
              padding: const EdgeInsets.only(left: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w400, color: sel ? _ink : _slate),
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Chat options',
                    enabled: widget.enabled,
                    padding: EdgeInsets.zero,
                    iconSize: 18,
                    iconColor: _hover || sel ? _slate : _muted,
                    icon: const Icon(Icons.more_horiz_rounded),
                    onSelected: (v) => v == 'rename' ? widget.onRename() : widget.onDelete(),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'rename', child: Text('Rename')),
                      PopupMenuItem(value: 'delete', child: Text('Delete')),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NewChatButton extends StatefulWidget {
  final VoidCallback? onTap;
  const _NewChatButton({required this.onTap});

  @override
  State<_NewChatButton> createState() => _NewChatButtonState();
}

class _NewChatButtonState extends State<_NewChatButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.onTap != null;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Material(
        color: _hover && on ? _fillStrong.withValues(alpha: 0.5) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(color: on ? _brandRed : _muted.withValues(alpha: 0.5), shape: BoxShape.circle),
                  child: const Icon(Icons.add_rounded, size: 18, color: Colors.white),
                ),
                const SizedBox(width: 10),
                Text(
                  'New chat',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: on ? _ink : _muted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A rounded suggestion chip on the empty screen; the full question shows as a tooltip.
class _SuggestionCard extends StatelessWidget {
  final _Suggestion suggestion;
  final VoidCallback onTap;
  const _SuggestionCard({required this.suggestion, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: suggestion.question,
      waitDuration: const Duration(milliseconds: 500),
      child: Material(
        color: Colors.white,
        shape: const StadiumBorder(side: BorderSide(color: _stroke)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          hoverColor: _fill,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 18, 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(suggestion.icon, size: 17, color: _slate),
                const SizedBox(width: 8),
                Text(suggestion.title, style: const TextStyle(fontSize: 13.5, color: _ink)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Messages
// =============================================================================

class _UserMessage extends StatefulWidget {
  final AssistantMessage message;
  final bool canEdit;
  final ValueChanged<String> onResend;
  const _UserMessage({super.key, required this.message, required this.canEdit, required this.onResend});

  @override
  State<_UserMessage> createState() => _UserMessageState();
}

class _UserMessageState extends State<_UserMessage> {
  bool _hover = false;
  bool _editing = false;
  late final TextEditingController _c = TextEditingController(text: widget.message.text);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _send() {
    final t = _c.text.trim();
    if (t.isEmpty) return;
    setState(() => _editing = false);
    widget.onResend(t);
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.message.text;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18, left: 40),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: _editing ? _editor() : _bubble(text),
      ),
    );
  }

  Widget _bubble(String text) {
    // Touch has no hover, so on phones and tablets the actions are simply always there.
    final touch = const {TargetPlatform.android, TargetPlatform.iOS, TargetPlatform.fuchsia}.contains(Theme.of(context).platform);
    final show = _hover || touch;
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        AnimatedOpacity(
          duration: const Duration(milliseconds: 120),
          opacity: show ? 1 : 0,
          child: ExcludeFocus(
            excluding: !show, // invisible buttons must not be tab stops
            child: IgnorePointer(
              ignoring: !show,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Copy',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => Clipboard.setData(ClipboardData(text: text)),
                    icon: const Icon(Icons.content_copy_rounded, size: 15),
                    color: _muted,
                  ),
                  if (widget.canEdit)
                    IconButton(
                      tooltip: 'Edit and ask again',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => setState(() {
                        _c.text = text;
                        _editing = true;
                      }),
                      icon: const Icon(Icons.edit_outlined, size: 16),
                      color: _muted,
                    ),
                ],
              ),
            ),
          ),
        ),
        Flexible(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
            decoration: BoxDecoration(color: _fill, borderRadius: BorderRadius.circular(18)),
            child: SelectableText(text, style: const TextStyle(fontSize: 15, color: _ink, height: 1.5)),
          ),
        ),
      ],
    );
  }

  Widget _editor() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 8, 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _brandRed.withValues(alpha: 0.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Focus(
            onKeyEvent: (node, event) {
              if (event is! KeyDownEvent) return KeyEventResult.ignored;
              if (event.logicalKey == LogicalKeyboardKey.escape) {
                setState(() => _editing = false);
                return KeyEventResult.handled;
              }
              if ((event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter) &&
                  !HardwareKeyboard.instance.isShiftPressed) {
                _send();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: TextField(
              controller: _c,
              autofocus: true,
              minLines: 1,
              maxLines: 6,
              maxLength: _maxChars,
              cursorColor: _brandRed,
              style: const TextStyle(fontSize: 14, color: _ink, height: 1.45),
              decoration: const InputDecoration(
                counterText: '',
                isDense: true,
                filled: false,
                contentPadding: EdgeInsets.symmetric(vertical: 8),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
              ),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              const Expanded(
                child: Text('Answers below this question will be replaced.', style: TextStyle(fontSize: 11, color: _muted)),
              ),
              TextButton(onPressed: () => setState(() => _editing = false), child: const Text('Cancel')),
              const SizedBox(width: 4),
              FilledButton(
                onPressed: _send,
                style: FilledButton.styleFrom(
                  backgroundColor: _brandRed,
                  visualDensity: VisualDensity.compact,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: const Text('Send'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Fades and lifts its child in after [delay]. Skips straight to the end when [animate] is false or the
/// system asks for reduced motion.
class _Reveal extends StatefulWidget {
  final bool animate;
  final int delayMs;
  final Widget child;
  const _Reveal({required this.animate, required this.delayMs, required this.child});

  @override
  State<_Reveal> createState() => _RevealState();
}

class _RevealState extends State<_Reveal> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (!widget.animate) {
      _c.value = 1;
    } else {
      _timer = Timer(Duration(milliseconds: widget.delayMs), () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) _c.value = 1;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
    return FadeTransition(
      opacity: curve,
      child: SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, 0.04), end: Offset.zero).animate(curve),
        child: widget.child,
      ),
    );
  }
}

class _AnswerView extends StatefulWidget {
  final AssistantMessage message;
  final bool isLast;
  final ValueChanged<String> onAsk;
  final VoidCallback onRegenerate;
  final GlobalKey? anchorKey; // marks the top of the newest answer, so the thread can scroll to it
  final bool streaming; // still being written: no buttons yet
  final String? question; // what was asked, sent along with a thumbs up / down
  final Future<void> Function(String rating, String? question, String answer) onRate;
  const _AnswerView({
    super.key,
    required this.message,
    required this.onRate,
    this.streaming = false,
    this.question,
    required this.isLast,
    required this.onAsk,
    required this.onRegenerate,
    this.anchorKey,
  });

  @override
  State<_AnswerView> createState() => _AnswerViewState();
}

class _AnswerViewState extends State<_AnswerView> {
  late _Parsed _parsed = _parse(widget.message.text);
  late bool _animate = widget.message.fresh;
  bool _copied = false;
  Timer? _copiedTimer;
  String? _rating; // 'up' | 'down' once the person has voted on this answer
  bool _showCalls = false;

  void _rate(String r) {
    if (_rating != null) return;
    setState(() => _rating = r);
    widget.onRate(r, widget.question, widget.message.text);
  }

  @override
  void initState() {
    super.initState();
    widget.message.fresh = false;
  }

  @override
  void didUpdateWidget(_AnswerView old) {
    super.didUpdateWidget(old);
    // The newest answer shares one GlobalKey, so a replaced answer can arrive in the same element.
    if (!identical(old.message, widget.message)) {
      _parsed = _parse(widget.message.text);
      _animate = widget.message.fresh;
      widget.message.fresh = false;
    }
  }

  @override
  void dispose() {
    _copiedTimer?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _parsed.plain));
    if (!mounted) return;
    setState(() => _copied = true);
    _copiedTimer?.cancel();
    _copiedTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final blocks = _parsed.blocks;
    var step = 0;
    int next() => (step++ * 90).clamp(0, 900);

    Widget reveal(Widget child) => _Reveal(animate: _animate, delayMs: next(), child: child);

    return Padding(
      padding: const EdgeInsets.only(bottom: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox.shrink(key: widget.anchorKey),
          SelectionArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [for (final b in blocks) KeyedSubtree(key: ObjectKey(b), child: reveal(_blockView(b)))],
            ),
          ),
          if (!widget.streaming) reveal(_actions()),
          if (widget.isLast && _parsed.followUps.isNotEmpty) reveal(_followUps()),
        ],
      ),
    );
  }

  Widget _blockView(_Block b) {
    return switch (b) {
      _Para() => Padding(
        padding: EdgeInsets.only(bottom: b.tight ? 4 : 14),
        child: Text.rich(TextSpan(style: _bodyStyle, children: _inlineSpans(b.text, _bodyStyle))),
      ),
      _Head() => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 8),
        child: Text.rich(
          TextSpan(
            style: _bodyStyle.copyWith(fontSize: 18, fontWeight: FontWeight.w600, height: 1.35),
            children: _inlineSpans(b.text, _bodyStyle.copyWith(fontSize: 18, height: 1.35)),
          ),
        ),
      ),
      _Rule() => const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Divider(height: 1, color: _stroke),
      ),
      _Code() => Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 14),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: _fill, borderRadius: BorderRadius.circular(8)),
          child: Text(
            b.text,
            style: const TextStyle(
              fontFamily: 'Consolas',
              fontFamilyFallback: ['Menlo', 'Courier New', 'monospace'],
              fontSize: 13,
              height: 1.45,
              color: _ink,
            ),
          ),
        ),
      ),
      _Item() => Padding(
        padding: EdgeInsets.only(left: 2 + b.level * 18.0, bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 22,
              child: b.number == null
                  ? const Padding(
                      padding: EdgeInsets.only(top: 12, left: 5),
                      child: DecoratedBox(
                        decoration: BoxDecoration(color: _slate, shape: BoxShape.circle),
                        child: SizedBox(width: 4.5, height: 4.5),
                      ),
                    )
                  : Text(
                      '${b.number}.',
                      style: _bodyStyle.copyWith(color: _slate, fontWeight: FontWeight.w600),
                    ),
            ),
            Expanded(
              child: Text.rich(TextSpan(style: _bodyStyle, children: _inlineSpans(b.text, _bodyStyle))),
            ),
          ],
        ),
      ),
      _Table() => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 14),
        child: _ChatTable(rows: b.rows),
      ),
      _Stats() => Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 14),
        child: _StatRow(items: b.items, animate: _animate),
      ),
      _Chart() => Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 14),
        child: _ChatChart(chart: b, animate: _animate),
      ),
    };
  }

  Widget _vote(String r, IconData off, IconData on, String tip) {
    final chosen = _rating == r;
    return IconButton(
      tooltip: _rating == null ? tip : (chosen ? 'Thanks for the feedback' : tip),
      onPressed: _rating == null ? () => _rate(r) : null,
      visualDensity: VisualDensity.compact,
      iconSize: 16,
      color: chosen ? _brandRed : _muted,
      disabledColor: chosen ? _brandRed : _muted.withValues(alpha: 0.4),
      icon: Icon(chosen ? on : off),
    );
  }

  Widget _actions() {
    final sources = widget.message.sources;
    final calls = widget.message.calls;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [_actionRow(sources, calls), if (_showCalls && calls.isNotEmpty) _callsBox(calls)],
      ),
    );
  }

  /// "How I got this": what was looked up and with which filters, so a number can be checked.
  Widget _callsBox(List<String> calls) {
    return Container(
      margin: const EdgeInsets.only(top: 6, bottom: 2),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      width: double.infinity,
      decoration: BoxDecoration(color: _fill, borderRadius: BorderRadius.circular(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'How I got this',
            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: _slate),
          ),
          const SizedBox(height: 6),
          for (final c in calls)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('• $c', style: const TextStyle(fontSize: 11.5, color: _slate, height: 1.4)),
            ),
        ],
      ),
    );
  }

  Widget _actionRow(List<String> sources, List<String> calls) {
    return Padding(
      padding: EdgeInsets.zero,
      child: Wrap(
        spacing: 2,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _MiniAction(
            icon: _copied ? Icons.check_rounded : Icons.content_copy_rounded,
            label: _copied ? 'Copied' : 'Copy',
            color: _copied ? _good : null,
            onTap: _copy,
          ),
          if (widget.isLast) _MiniAction(icon: Icons.refresh_rounded, label: 'Regenerate', onTap: widget.onRegenerate),
          _vote('up', Icons.thumb_up_outlined, Icons.thumb_up_rounded, 'Good answer'),
          _vote('down', Icons.thumb_down_outlined, Icons.thumb_down_rounded, 'Not helpful'),
          if (sources.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: calls.isEmpty ? null : () => setState(() => _showCalls = !_showCalls),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.verified_outlined, size: 14, color: _muted),
                      const SizedBox(width: 5),
                      Text('Checked ${sources.join(' · ')}', style: const TextStyle(fontSize: 11.5, color: _muted)),
                      if (calls.isNotEmpty)
                        Icon(_showCalls ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 16, color: _muted),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _followUps() {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [for (final q in _parsed.followUps) _FollowUpChip(text: q, onTap: () => widget.onAsk(q))],
      ),
    );
  }
}

class _MiniAction extends StatelessWidget {
  final IconData icon;
  final String label; // shown next to the icon, so it reads on touch and web where there is no hover
  final Color? color;
  final VoidCallback onTap;
  const _MiniAction({required this.icon, required this.label, required this.onTap, this.color});

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
      style: TextButton.styleFrom(
        foregroundColor: color ?? _slate,
        iconColor: color ?? _slate,
        minimumSize: const Size(34, 34),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        visualDensity: VisualDensity.compact,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ).copyWith(overlayColor: WidgetStatePropertyAll(_fill)),
    );
  }
}

class _FollowUpChip extends StatelessWidget {
  final String text;
  final VoidCallback onTap;
  const _FollowUpChip({required this.text, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        hoverColor: _fill,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 7, 10, 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: _stroke),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(text, style: const TextStyle(fontSize: 13.5, color: _ink, height: 1.3)),
              ),
              const SizedBox(width: 6),
              const Icon(Icons.arrow_outward_rounded, size: 13, color: _muted),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Rich text, stats and tables
// =============================================================================

/// Jarvis's own text uses the app font. (A serif looked right in desktop tests but Flutter web only uses bundled fonts,
/// so it silently became Roboto there.)
const TextStyle _serifStyle = TextStyle(color: _ink);
final TextStyle _bodyStyle = _serifStyle.copyWith(fontSize: 15.5, height: 1.6);

final RegExp _inlineRe = RegExp(r'\*\*(.+?)\*\*|`([^`]+)`|(?<![*\w])\*([^*\s][^*]*?)\*(?![*\w])|\[([^\]]+)\]\(([^)\s]+)\)');

/// **bold**, *italic*, `code` and [links](url) (shown as their text) inside a line of text.
List<InlineSpan> _inlineSpans(String line, TextStyle base) {
  final spans = <InlineSpan>[];
  var last = 0;
  for (final m in _inlineRe.allMatches(line)) {
    if (m.start > last) spans.add(TextSpan(text: line.substring(last, m.start)));
    if (m.group(1) != null) {
      spans.add(
        TextSpan(
          text: m.group(1),
          style: base.copyWith(fontWeight: FontWeight.w700),
        ),
      );
    } else if (m.group(2) != null) {
      spans.add(
        TextSpan(
          text: m.group(2),
          style: base.copyWith(
            fontFamily: 'Consolas',
            fontFamilyFallback: const ['Menlo', 'Courier New', 'monospace'],
            fontSize: (base.fontSize ?? 14) * 0.9,
            backgroundColor: _fill,
          ),
        ),
      );
    } else if (m.group(3) != null) {
      spans.add(
        TextSpan(
          text: m.group(3),
          style: base.copyWith(fontStyle: FontStyle.italic),
        ),
      );
    } else {
      final url = m.group(5) ?? '';
      if (url.startsWith('job:') && RegExp(r'^[A-Za-z0-9\-]{3,40}$').hasMatch(url.substring(4))) {
        // A job the assistant named: a link that opens it in the app.
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: _JobLink(jobId: url.substring(4), label: m.group(4) ?? url.substring(4), style: base),
          ),
        );
      } else {
        spans.add(TextSpan(text: m.group(4)));
      }
    }
    last = m.end;
  }
  if (last < line.length) spans.add(TextSpan(text: line.substring(last)));
  return spans;
}

/// A job number in an answer. Closes the panel and opens that job.
class _JobLink extends StatefulWidget {
  final String jobId;
  final String label;
  final TextStyle style;
  const _JobLink({required this.jobId, required this.label, required this.style});

  @override
  State<_JobLink> createState() => _JobLinkState();
}

class _JobLinkState extends State<_JobLink> {
  bool _hover = false;

  void _open() {
    GoRouter? router;
    try {
      router = GoRouter.of(context);
    } catch (_) {}
    Navigator.of(context).pop(); // the panel sits on top of the page, so close it first
    router?.go('/jobs/${Uri.encodeComponent(widget.jobId)}');
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: _open,
        child: Text(
          widget.label,
          style: widget.style.copyWith(
            color: _brandRed,
            fontWeight: FontWeight.w600,
            decoration: _hover ? TextDecoration.underline : TextDecoration.none,
            decorationColor: _brandRed,
          ),
        ),
      ),
    );
  }
}

/// Key figures as a borderless strip (big number over a small label, hairlines between), so they read as part of
/// the answer instead of a row of scorecards.
class _StatRow extends StatelessWidget {
  final List<(String value, String label)> items;
  final bool animate;
  const _StatRow({required this.items, required this.animate});

  Widget _figure(int i, {required bool divider}) {
    return Container(
      padding: EdgeInsets.fromLTRB(divider ? 20 : 0, 0, 12, 0),
      decoration: BoxDecoration(
        border: divider ? const Border(left: BorderSide(color: _stroke)) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // label on top (any wrapping stays above), value pinned to the bottom so the numbers line up across figures
          Text(
            items[i].$2,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12.5, color: _slate, height: 1.3),
          ),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: _CountUp(
              value: items[i].$1,
              animate: animate,
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.6,
                color: _ink,
                height: 1.1,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Dragging a selection across the figures glued values and labels together ("$19.747$12.64..."), so they sit
    // out of drag-selection; the Copy button writes them as "label: value" lines instead.
    return SelectionContainer.disabled(
      child: LayoutBuilder(
        builder: (context, c) {
          final fitsInRow = c.maxWidth >= 150.0 * items.length;
          if (fitsInRow) {
            return Container(
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: const BoxDecoration(
                border: Border(
                  top: BorderSide(color: _stroke),
                  bottom: BorderSide(color: _stroke),
                ),
              ),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [for (var i = 0; i < items.length; i++) Expanded(child: _figure(i, divider: i > 0))],
                ),
              ),
            );
          }
          // narrow: two per row, no dividers
          final w = c.maxWidth >= 300 ? (c.maxWidth - 12) / 2 : c.maxWidth;
          return Container(
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: const BoxDecoration(
              border: Border(
                top: BorderSide(color: _stroke),
                bottom: BorderSide(color: _stroke),
              ),
            ),
            child: Wrap(
              spacing: 12,
              runSpacing: 14,
              children: [for (var i = 0; i < items.length; i++) SizedBox(width: w, child: _figure(i, divider: false))],
            ),
          );
        },
      ),
    );
  }
}

/// Counts a number up from zero while keeping its prefix/suffix ("$230,669", "87.6%").
class _CountUp extends StatelessWidget {
  final String value;
  final bool animate;
  final TextStyle style;
  const _CountUp({required this.value, required this.animate, required this.style});

  static final _re = RegExp(r'^(\D*?)(-?\d[\d,]*(?:\.\d+)?)(.*)$');

  static String _fmt(double v, int decimals, bool commas) {
    var s = v.toStringAsFixed(decimals);
    if (!commas) return s;
    final parts = s.split('.');
    final digits = parts[0];
    final buf = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0 && digits[i - 1] != '-') buf.write(',');
      buf.write(digits[i]);
    }
    return parts.length > 1 ? '$buf.${parts[1]}' : buf.toString();
  }

  @override
  Widget build(BuildContext context) {
    final m = _re.firstMatch(value.trim());
    if (m == null || !animate || MediaQuery.disableAnimationsOf(context)) return Text(value, style: style);
    final raw = m.group(2)!;
    final target = double.tryParse(raw.replaceAll(',', ''));
    if (target == null) return Text(value, style: style);
    final decimals = raw.contains('.') ? raw.split('.').last.length : 0;
    final commas = raw.contains(',');
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: target),
      duration: const Duration(milliseconds: 1100),
      curve: Curves.easeOutCubic,
      builder: (_, v, _) => Text('${m.group(1)}${_fmt(v, decimals, commas)}${m.group(3)}', style: style),
    );
  }
}

String _chartFull(double v, String format) {
  final neg = v < 0;
  final a = v.abs();
  var s = _CountUp._fmt(a, a % 1 == 0 ? 0 : 2, true); // keep cents instead of rounding them away
  if (format != 'money' && s.contains('.')) s = s.replaceFirst(RegExp(r'\.?0+$'), '');
  final body = switch (format) {
    'money' => '\$$s',
    'percent' => '$s%',
    _ => s,
  };
  return neg ? '-$body' : body;
}

String _chartCompact(double v, String format) {
  final neg = v < 0;
  final a = v.abs();
  // Axis steps like 2.5 x 10^n land on values such as 12,500 and 1.25M, so keep a decimal or two instead of rounding.
  String trim(double v, int dec) {
    final t = v.toStringAsFixed(dec);
    return t.contains('.') ? t.replaceFirst(RegExp(r'\.?0+$'), '') : t;
  }

  String s;
  if (a >= 1e6) {
    s = '${trim(a / 1e6, a >= 1e8 ? 0 : (a >= 1e7 ? 1 : 2))}M';
  } else if (a >= 1e3) {
    s = '${trim(a / 1e3, a >= 1e5 ? 0 : (a >= 1e4 ? 1 : 2))}K';
  } else {
    s = a % 1 == 0 ? a.toStringAsFixed(0) : a.toStringAsFixed(1);
  }
  final body = switch (format) {
    'money' => '\$$s',
    'percent' => '$s%',
    _ => s,
  };
  return neg ? '-$body' : body;
}

/// A chart the assistant asked for with a `::: chart` block: line or vertical bars (several series allowed)
/// for trends and comparisons, horizontal bars for rankings. Hover shows exact values.
class _ChatChart extends StatefulWidget {
  final _Chart chart;
  final bool animate;
  const _ChatChart({required this.chart, required this.animate});

  @override
  State<_ChatChart> createState() => _ChatChartState();
}

class _ChatChartState extends State<_ChatChart> {
  static const _palette = [_brandRed, _info, _teal];
  static const double _plotHeight = 210;
  int? _hover;

  _Chart get c => widget.chart;

  String get _summary =>
      '${c.title.isEmpty ? 'Chart' : c.title}. ${[
        for (final p in c.points) '${p.$1}: ${[for (var i = 0; i < p.$2.length; i++) '${c.series.isEmpty ? '' : '${c.series[i]} '}${_chartFull(p.$2[i], c.format)}'].join(', ')}',
      ].join('; ')}';

  @override
  Widget build(BuildContext context) {
    final animate = widget.animate && !MediaQuery.disableAnimationsOf(context);
    return Semantics(
      label: _summary,
      child: ExcludeSemantics(
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _stroke),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (c.title.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    c.title,
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: _ink),
                  ),
                ),
              if (c.series.length > 1)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Wrap(
                    spacing: 14,
                    runSpacing: 4,
                    children: [
                      for (var i = 0; i < c.series.length; i++)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 9,
                              height: 9,
                              decoration: BoxDecoration(color: _palette[i], borderRadius: BorderRadius.circular(3)),
                            ),
                            const SizedBox(width: 6),
                            Text(c.series[i], style: const TextStyle(fontSize: 12, color: _slate)),
                          ],
                        ),
                    ],
                  ),
                ),
              if (c.kind == 'hbar') _hbars(animate) else _plot(animate),
            ],
          ),
        ),
      ),
    );
  }

  Widget _hbars(bool animate) {
    final maxV = c.points.map((p) => p.$2.first.abs()).fold<double>(0, (a, b) => b > a ? b : a);
    return LayoutBuilder(
      builder: (context, box) {
        // 98 = the value column plus the two gaps; the label takes a share of what is left, so a narrow panel does not overflow
        final labelW = ((box.maxWidth - 98) * 0.42).clamp(56.0, 150.0);
        return _hbarRows(animate, maxV, labelW);
      },
    );
  }

  Widget _hbarRows(bool animate, double maxV, double labelW) {
    return Column(
      children: [
        for (var i = 0; i < c.points.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3.5),
            child: Row(
              children: [
                SizedBox(
                  width: labelW,
                  child: Text(
                    c.points[i].$1,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5, color: _ink),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: animate ? 0 : 1, end: 1),
                    duration: Duration(milliseconds: 650 + i * 40),
                    curve: Curves.easeOutCubic,
                    builder: (_, t, _) => Align(
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: maxV <= 0 ? 0.0 : ((c.points[i].$2.first.abs() / maxV) * t).clamp(0.0, 1.0),
                        child: Container(
                          height: 16,
                          decoration: BoxDecoration(
                            color: c.points[i].$2.first < 0 ? _bad : (i == 0 ? _brandRed : _brandRed.withValues(alpha: 0.55)),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 78,
                  child: Text(
                    _chartFull(c.points[i].$2.first, c.format),
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: _ink,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _plot(bool animate) {
    return SizedBox(
      height: _plotHeight,
      child: LayoutBuilder(
        builder: (context, box) {
          final geo = _ChartGeometry(Size(box.maxWidth, _plotHeight), c);
          return TweenAnimationBuilder<double>(
            tween: Tween(begin: animate ? 0 : 1, end: 1),
            duration: const Duration(milliseconds: 750),
            curve: Curves.easeOutCubic,
            builder: (_, t, _) => MouseRegion(
              onHover: (e) => setState(() => _hover = geo.indexAt(e.localPosition.dx)),
              onExit: (_) => setState(() => _hover = null),
              // touch has no hover, so a tap shows the same values (tapping the same spot again hides them)
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) {
                  final i = geo.indexAt(d.localPosition.dx);
                  setState(() => _hover = i == _hover ? null : i);
                },
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      child: CustomPaint(painter: _ChartPainter(c, geo, t, _hover, DefaultTextStyle.of(context).style)),
                    ),
                    if (_hover != null) _tooltip(geo, _hover!),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _tooltip(_ChartGeometry geo, int i) {
    final p = c.points[i];
    final x = geo.xCenter(i);
    const w = 150.0;
    // Beside the hovered column, not over it, so the bar being read stays visible.
    final room = (geo.size.width - w).clamp(0.0, double.infinity);
    final left = (x < geo.size.width / 2 ? x + geo.slot / 2 + 4 : x - geo.slot / 2 - w - 4).clamp(0.0, room);
    return Positioned(
      left: left,
      top: 0,
      width: w,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: _ink,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 10, offset: const Offset(0, 3))],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(p.$1, style: const TextStyle(fontSize: 11.5, color: Colors.white70)),
              for (var s = 0; s < p.$2.length; s++)
                Text(
                  c.series.isEmpty ? _chartFull(p.$2[s], c.format) : '${c.series[s]}  ${_chartFull(p.$2[s], c.format)}',
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Colors.white),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shared layout maths for the plot, so hover hit-testing and painting agree.
class _ChartGeometry {
  static const double left = 46, right = 8, top = 8, bottom = 24;
  final Size size;
  final _Chart chart;
  late final double lo;
  late final double hi;
  late final int ticks; // number of gridline intervals between lo and hi

  _ChartGeometry(this.size, this.chart) {
    var maxV = 0.0, minV = 0.0;
    for (final p in chart.points) {
      for (final v in p.$2) {
        if (v > maxV) maxV = v;
        if (v < minV) minV = v;
      }
    }
    // Round the axis to a tidy step (1, 2, 2.5, 5 x 10^n), going below zero when there are negative values.
    final range = maxV - minV <= 0 ? 1.0 : maxV - minV;
    final step = _niceCeil(range / 5);
    lo = (minV / step).floor() * step;
    var top = (maxV / step).ceil() * step;
    if (top <= lo) top = lo + step;
    hi = top;
    ticks = ((hi - lo) / step).round().clamp(1, 8);
  }

  static double _niceCeil(double v) {
    if (v <= 0) return 1;
    var pow = 1.0;
    while (v / pow >= 10) {
      pow *= 10;
    }
    while (v / pow < 1) {
      pow /= 10;
    }
    final f = v / pow;
    final nice = f <= 1
        ? 1
        : f <= 2
        ? 2
        : f <= 2.5
        ? 2.5
        : f <= 5
        ? 5
        : 10;
    return nice * pow;
  }

  double get plotW => (size.width - left - right).clamp(1.0, double.infinity);
  double get plotH => (size.height - top - bottom).clamp(1.0, double.infinity);
  int get n => chart.points.length;
  double get slot => plotW / n;
  double xCenter(int i) => left + slot * (i + 0.5);
  double y(double v) => top + plotH * (1 - (v - lo) / (hi - lo));
  int? indexAt(double dx) {
    if (dx < left || dx > size.width - right) return null;
    return ((dx - left) / slot).floor().clamp(0, n - 1);
  }
}

class _ChartPainter extends CustomPainter {
  final _Chart chart;
  final _ChartGeometry g;
  final double t; // 0..1 grow-in
  final int? hover;
  final TextStyle base; // the app's text style, so axis labels use the same font as the rest of the answer
  _ChartPainter(this.chart, this.g, this.t, this.hover, this.base);

  static const _colors = _ChatChartState._palette;

  void _text(Canvas canvas, String s, Offset at, {bool rightAlign = false, bool centre = false, Color color = _muted}) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: base.copyWith(
          fontSize: 11,
          color: color,
          fontWeight: color == _muted ? FontWeight.w400 : FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final dx = rightAlign ? at.dx - tp.width : (centre ? at.dx - tp.width / 2 : at.dx);
    tp.paint(canvas, Offset(dx, at.dy - tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = _stroke
      ..strokeWidth = 1;
    for (var k = 0; k <= g.ticks; k++) {
      final v = g.lo + (g.hi - g.lo) * k / g.ticks;
      final yy = g.y(v);
      canvas.drawLine(Offset(_ChartGeometry.left, yy), Offset(size.width - _ChartGeometry.right, yy), grid);
      _text(canvas, _chartCompact(v, chart.format), Offset(_ChartGeometry.left - 8, yy), rightAlign: true);
    }
    if (g.lo < 0 && g.hi >= 0) {
      // the zero line, so bars above and below it read correctly
      canvas.drawLine(
        Offset(_ChartGeometry.left, g.y(0)),
        Offset(size.width - _ChartGeometry.right, g.y(0)),
        Paint()
          ..color = _slate.withValues(alpha: 0.55)
          ..strokeWidth = 1.2,
      );
    }

    // x labels: long ones are shortened, and the row is thinned by how wide they really are so they never overlap
    String shorten(String l) => l.length > 14 ? '${l.substring(0, 13)}…' : l;
    final longest = chart.points.map((p) => shorten(p.$1).length).fold<int>(1, (a, b) => b > a ? b : a);
    final step = (g.n * (longest * 6.2 + 12) / g.plotW).ceil().clamp(1, g.n);
    for (var i = 0; i < g.n; i += step) {
      _text(canvas, shorten(chart.points[i].$1), Offset(g.xCenter(i), size.height - 9), centre: true);
    }

    if (hover != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(_ChartGeometry.left + g.slot * hover!, _ChartGeometry.top, g.slot, g.plotH),
          const Radius.circular(6),
        ),
        Paint()..color = _fill,
      );
      // grid lines sit under the highlight; redraw them lightly so the band does not hide them
      for (var k = 0; k <= g.ticks; k++) {
        final yy = g.y(g.lo + (g.hi - g.lo) * k / g.ticks);
        canvas.drawLine(
          Offset(_ChartGeometry.left + g.slot * hover!, yy),
          Offset(_ChartGeometry.left + g.slot * (hover! + 1), yy),
          grid,
        );
      }
    }

    final seriesCount = chart.points.first.$2.length;
    final base = g.y(g.lo < 0 ? 0 : g.lo);
    double grow(double v) => base + (g.y(v) - base) * t;

    if (chart.kind == 'line') {
      for (var s = 0; s < seriesCount; s++) {
        final color = _colors[s];
        final path = Path();
        for (var i = 0; i < g.n; i++) {
          final p = Offset(g.xCenter(i), grow(chart.points[i].$2[s]));
          i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
        }
        if (seriesCount == 1) {
          final area = Path.from(path)
            ..lineTo(g.xCenter(g.n - 1), base)
            ..lineTo(g.xCenter(0), base)
            ..close();
          canvas.drawPath(
            area,
            Paint()
              ..shader = LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [color.withValues(alpha: 0.16), color.withValues(alpha: 0.0)],
              ).createShader(Rect.fromLTWH(0, _ChartGeometry.top, size.width, g.plotH)),
          );
        }
        canvas.drawPath(
          path,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5
            ..strokeJoin = StrokeJoin.round
            ..strokeCap = StrokeCap.round,
        );
        for (var i = 0; i < g.n; i++) {
          final p = Offset(g.xCenter(i), grow(chart.points[i].$2[s]));
          final on = hover == i;
          if (g.n <= 14 || on) {
            canvas.drawCircle(p, on ? 5 : 3.5, Paint()..color = Colors.white);
            canvas.drawCircle(
              p,
              on ? 5 : 3.5,
              Paint()
                ..color = color
                ..style = PaintingStyle.stroke
                ..strokeWidth = 2,
            );
          }
        }
      }
    } else {
      final groupW = g.slot * 0.68;
      final barW = (groupW / seriesCount).clamp(4.0, 30.0);
      for (var i = 0; i < g.n; i++) {
        final startX = g.xCenter(i) - barW * seriesCount / 2;
        for (var s = 0; s < seriesCount; s++) {
          final v = chart.points[i].$2[s];
          final top = grow(v);
          final rect = Rect.fromLTRB(
            startX + barW * s + 1,
            v >= 0 ? top : base,
            startX + barW * (s + 1) - 1,
            v >= 0 ? base : top,
          );
          final dim = hover == null || hover == i ? 1.0 : 0.45;
          final color = _colors[s];
          canvas.drawRRect(
            RRect.fromRectAndCorners(
              rect,
              topLeft: v >= 0 ? const Radius.circular(5) : Radius.zero,
              topRight: v >= 0 ? const Radius.circular(5) : Radius.zero,
              bottomLeft: v < 0 ? const Radius.circular(5) : Radius.zero,
              bottomRight: v < 0 ? const Radius.circular(5) : Radius.zero,
            ),
            Paint()
              ..shader = LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  color.withValues(alpha: dim),
                  color.withValues(alpha: 0.72 * dim),
                ],
              ).createShader(rect),
          );
          // Short single-series charts read faster with the value printed on the bar.
          if (seriesCount == 1 && g.n <= 8 && t > 0.98 && v != 0) {
            final label = _chartCompact(v, chart.format);
            final above = v >= 0 ? rect.top - 9 : rect.bottom + 9;
            _text(
              canvas,
              label,
              Offset(startX + barW / 2, above.clamp(_ChartGeometry.top + 2, size.height - _ChartGeometry.bottom - 2)),
              centre: true,
              color: _slate,
            );
          }
        }
      }
    }
  }

  @override
  bool shouldRepaint(_ChartPainter old) => old.t != t || old.hover != hover || old.chart != chart || old.base != base;
}

Color _statusColor(String s) {
  final known = knownStatusColor(s);
  if (known != null) return known;
  final t = s.toLowerCase();
  if (RegExp(r'delay|cancel|lost|write-off|overdue|90 day|60 day').hasMatch(t)) return _bad;
  if (RegExp(r'paid|closed|review sent|won').hasMatch(t)) return _good;
  if (RegExp(r'invoice|awaiting|deposit|payment|notice|pending').hasMatch(t)) return _warn;
  if (RegExp(r'complete').hasMatch(t)) return _teal;
  if (RegExp(r'schedul|appointment|manage').hasMatch(t)) return _info;
  return _muted;
}

/// A markdown table made interactive: tap a header to sort, money columns get a data bar, status
/// columns get a colour dot, long tables fold, and the whole thing copies as tab-separated text.
class _ChatTable extends StatefulWidget {
  final List<List<String>> rows; // first row is the header
  const _ChatTable({required this.rows});

  @override
  State<_ChatTable> createState() => _ChatTableState();
}

class _ChatTableState extends State<_ChatTable> {
  static const int _fold = 8;
  static final _numericRe = RegExp(r'^\(?[-+]?\s?\$?\s?[-+]?[\d,]*\.?\d+\s?[%kKmM]?\)?$');

  late final int _cols = widget.rows.first.length;
  late final List<String> _header = _fit(widget.rows.first);
  late final List<List<String>> _all = [for (final r in widget.rows.skip(1)) _fit(r)];
  late final List<List<String>> _body = _all.where((r) => !_isTotal(r)).toList();
  late final List<List<String>> _totals = _all.where(_isTotal).toList();

  late final List<bool> _numeric = [
    for (var c = 0; c < _cols; c++)
      _body.every((r) => r[c].isEmpty || _numericRe.hasMatch(r[c])) && _body.any((r) => r[c].isNotEmpty),
  ];

  /// Last column whose cells are all dollar amounts: that one gets the data bars.
  late final int? _barCol = () {
    for (var c = _cols - 1; c >= 0; c--) {
      final dollars =
          _body.every((r) => r[c].isEmpty || RegExp(r'^[(\-+]?\s?\$').hasMatch(r[c].trim())) && _body.any((r) => r[c].isNotEmpty);
      if (_numeric[c] && dollars) return c;
    }
    return null;
  }();

  /// The first column headed Status or Stage gets a colour dot, wherever it sits in the table.
  late final int? _statusIdx = () {
    for (var c = 0; c < _cols; c++) {
      if (RegExp(r'status|stage').hasMatch(_header[c].toLowerCase())) return c;
    }
    return null;
  }();

  int? _sortCol;
  bool _asc = true;
  bool _expanded = false;
  bool _copied = false;
  Timer? _timer;

  List<String> _fit(List<String> r) => [for (var c = 0; c < _cols; c++) c < r.length ? _stripMd(r[c]) : ''];

  bool _isTotal(List<String> r) => RegExp(r'^(grand\s+)?total\b', caseSensitive: false).hasMatch(r.first.trim());

  static double _num(String s) {
    var t = s.trim();
    final neg = t.contains('-') || (t.startsWith('(') && t.endsWith(')'));
    final unit = t.replaceAll(')', '');
    final mult = RegExp(r'[kK]$').hasMatch(unit) ? 1e3 : (RegExp(r'[mM]$').hasMatch(unit) ? 1e6 : 1.0);
    t = t.replaceAll(RegExp(r'[\$,%()\s\-+kKmM]'), '');
    final v = (double.tryParse(t) ?? 0) * mult;
    return neg ? -v : v;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _sortBy(int c) {
    setState(() {
      if (_sortCol != c) {
        _sortCol = c;
        _asc = !_numeric[c]; // numbers start high-to-low, text starts A-Z
      } else if ((_asc && !_numeric[c]) || (!_asc && _numeric[c])) {
        _asc = !_asc;
      } else {
        _sortCol = null;
      }
    });
  }

  List<List<String>> _sorted() {
    final rows = List<List<String>>.from(_body);
    final c = _sortCol;
    if (c != null) {
      rows.sort((a, b) {
        final r = _numeric[c] ? _num(a[c]).compareTo(_num(b[c])) : a[c].toLowerCase().compareTo(b[c].toLowerCase());
        return _asc ? r : -r;
      });
    }
    return rows;
  }

  /// Saves the table as a CSV that opens in Excel (with a byte-order mark so accents and symbols survive).
  Future<void> _saveCsv() async {
    String cell(String v) => v.contains(RegExp(r'[",\n]')) ? '"${v.replaceAll('"', '""')}"' : v;
    final csv = [_header, ..._sorted(), ..._totals].map((r) => r.map(cell).join(',')).join('\r\n');
    try {
      await FilePicker.saveFile(
        fileName: 'jarvis-table.csv',
        bytes: Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(csv)]),
        mimeType: 'text/csv',
        dialogTitle: 'Save table as CSV',
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(const SnackBar(content: Text("Couldn't save the file. Try Copy table instead.")));
      }
    }
  }

  Future<void> _copy() async {
    final text = [_header, ..._sorted(), ..._totals].map((r) => r.join('\t')).join('\n'); // in the order on screen
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() => _copied = true);
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final sorted = _sorted();
    final folded = !_expanded && sorted.length > _fold + 1;
    final shown = folded ? sorted.take(_fold).toList() : sorted;

    double maxBar = 0;
    final barCol = _barCol;
    if (barCol != null) {
      for (final r in _body) {
        final v = _num(r[barCol]);
        if (v > maxBar) maxBar = v;
      }
    }

    Widget headCell(int c) => InkWell(
      onTap: () => _sortBy(c),
      hoverColor: Colors.black.withValues(alpha: 0.04),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          mainAxisAlignment: _numeric[c] ? MainAxisAlignment.end : MainAxisAlignment.start,
          children: [
            Flexible(
              child: Text(
                _header[c].toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                  color: _sortCol == c ? _brandRed : _slate,
                ),
              ),
            ),
            if (_sortCol == c) ...[
              const SizedBox(width: 3),
              Icon(_asc ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, size: 12, color: _brandRed),
            ],
          ],
        ),
      ),
    );

    Widget cell(List<String> r, int c, {bool total = false}) {
      final t = r[c];
      Widget text = Text(
        t,
        textAlign: _numeric[c] ? TextAlign.right : TextAlign.left,
        style: TextStyle(
          fontSize: 13,
          fontWeight: total ? FontWeight.w800 : (c == 0 ? FontWeight.w600 : FontWeight.w500),
          color: _ink,
          height: 1.3,
          fontFeatures: _numeric[c] ? const [FontFeature.tabularFigures()] : null,
        ),
      );
      if (c == _statusIdx && !total) {
        text = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: _statusColor(t), shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Flexible(child: text),
          ],
        );
      }
      Widget padded = Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10), child: text);
      if (c == _barCol && !total && maxBar > 0) {
        final f = (_num(t) / maxBar).clamp(0.0, 1.0);
        padded = Stack(
          children: [
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: f,
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: _brandRed.withValues(alpha: 0.09), borderRadius: BorderRadius.circular(5)),
                      child: const SizedBox(height: double.infinity),
                    ),
                  ),
                ),
              ),
            ),
            padded,
          ],
        );
      }
      return padded;
    }

    // Label columns share the width and wrap; number columns hug their content, except the bar column
    // which needs room for its bar. So the table always fits the panel without side-scrolling.
    final table = Table(
      columnWidths: {
        for (var c = 0; c < _cols; c++)
          c: c == barCol
              ? const FlexColumnWidth(1.1)
              : (_numeric[c] ? const IntrinsicColumnWidth() : FlexColumnWidth(c == 0 ? 2 : 1.4)),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      border: const TableBorder(horizontalInside: BorderSide(color: _stroke)),
      children: [
        TableRow(
          decoration: const BoxDecoration(color: _fill),
          children: [for (var c = 0; c < _cols; c++) headCell(c)],
        ),
        for (final r in shown) TableRow(children: [for (var c = 0; c < _cols; c++) cell(r, c)]),
        for (final r in _totals)
          TableRow(
            decoration: BoxDecoration(color: _tint.withValues(alpha: 0.6)),
            children: [for (var c = 0; c < _cols; c++) cell(r, c, total: true)],
          ),
      ],
    );

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _stroke),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, box) {
              final minW = _cols * 110.0;
              if (box.maxWidth >= minW) return table;
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(width: minW, child: table),
              );
            },
          ),
          Container(
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: _stroke)),
            ),
            padding: const EdgeInsets.fromLTRB(8, 2, 4, 2),
            child: Row(
              children: [
                if (sorted.length > _fold + 1)
                  _MiniAction(
                    icon: folded ? Icons.unfold_more_rounded : Icons.unfold_less_rounded,
                    label: folded ? 'Show all ${sorted.length} rows' : 'Show fewer',
                    onTap: () => setState(() => _expanded = !_expanded),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                    child: Text(
                      '${sorted.length} ${sorted.length == 1 ? 'row' : 'rows'}',
                      style: const TextStyle(fontSize: 11.5, color: _muted),
                    ),
                  ),
                const Spacer(),
                _MiniAction(icon: Icons.download_rounded, label: 'CSV', onTap: _saveCsv),
                _MiniAction(
                  icon: _copied ? Icons.check_rounded : Icons.table_rows_outlined,
                  label: _copied ? 'Copied' : 'Copy table',
                  color: _copied ? _good : null,
                  onTap: _copy,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Thinking + error
// =============================================================================

class _SlideGradient extends GradientTransform {
  final double p;
  const _SlideGradient(this.p);

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) => Matrix4.translationValues(bounds.width * p, 0, 0);
}

class _Thinking extends StatefulWidget {
  final DateTime? since;
  final String? status; // the server's own words for what it is doing; the rotating phrases are the fallback
  final VoidCallback onStop;

  /// True once the answer itself is being written out above: the row shrinks to the pulsing mark (like Claude's chat), which
  /// stays until the answer is finished so it is always clear whether more is coming.
  final bool compact;
  final String? note; // in compact mode, what is being held back ("Drawing the chart…")
  const _Thinking({required this.since, required this.onStop, this.status, this.compact = false, this.note});

  @override
  State<_Thinking> createState() => _ThinkingState();
}

class _ThinkingState extends State<_Thinking> with SingleTickerProviderStateMixin {
  static const _phrases = ['Looking through your jobs…', 'Checking the numbers…', 'Putting it together…'];
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))..repeat();
  Timer? _timer;
  int get _secs => widget.since == null ? 0 : DateTime.now().difference(widget.since!).inSeconds;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    final secs = _secs;
    final i = (secs ~/ 4).clamp(0, _phrases.length - 1);
    if (widget.compact) {
      return Semantics(
        liveRegion: true,
        excludeSemantics: true,
        label: 'Jarvis is still writing',
        child: Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 18),
          child: Row(
            children: [
              ScaleTransition(
                scale: still
                    ? const AlwaysStoppedAnimation(1.0)
                    : Tween(begin: 0.85, end: 1.1).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut)),
                child: const Icon(Icons.auto_awesome_rounded, size: 18, color: _brandRed),
              ),
              if (widget.note != null) ...[
                const SizedBox(width: 8),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: Text(
                    widget.note!,
                    key: ValueKey(widget.note),
                    style: const TextStyle(fontSize: 13, color: _muted),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return Semantics(
      liveRegion: true,
      excludeSemantics: true, // the ticking seconds would otherwise be read out every second
      label: 'Jarvis is working on your question',
      child: Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: Row(
          children: [
            ScaleTransition(
              scale: still
                  ? const AlwaysStoppedAnimation(1.0)
                  : Tween(begin: 0.9, end: 1.08).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut)),
              child: const Icon(Icons.auto_awesome_rounded, size: 20, color: _brandRed),
            ),
            const SizedBox(width: 10),
            AnimatedBuilder(
              animation: _c,
              builder: (context, _) => ShaderMask(
                blendMode: BlendMode.srcIn,
                shaderCallback: (r) => LinearGradient(
                  colors: const [_muted, _ink, _muted],
                  stops: const [0.35, 0.5, 0.65],
                  transform: _SlideGradient(still ? 0 : _c.value * 2 - 1),
                ).createShader(r),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: Text(
                    widget.status ?? _phrases[i],
                    key: ValueKey(widget.status ?? i),
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              secs >= 12 ? '${secs}s · still working, this can take a minute or two' : (secs >= 3 ? '${secs}s' : ''),
              style: const TextStyle(fontSize: 11.5, color: _muted, fontFeatures: [FontFeature.tabularFigures()]),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown after the person stops a question, so the thread does not just end on their message.
class _StoppedNote extends StatelessWidget {
  final VoidCallback onRetry;
  const _StoppedNote({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Row(
        children: [
          const Icon(Icons.stop_circle_outlined, size: 18, color: _muted),
          const SizedBox(width: 8),
          const Text('Stopped.', style: TextStyle(fontSize: 13, color: _slate)),
          const SizedBox(width: 4),
          TextButton(onPressed: onRetry, child: const Text('Ask again')),
        ],
      ),
    );
  }
}

class _ErrorNote extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorNote({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFECACA)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, size: 18, color: Color(0xFFB91C1C)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message, style: const TextStyle(fontSize: 12.5, color: Color(0xFF7F1D1D), height: 1.35)),
          ),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}
