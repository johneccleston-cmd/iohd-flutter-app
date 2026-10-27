import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsService;
import 'package:go_router/go_router.dart';

import '../utils/status_colors.dart';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../config/api_config.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/auth_session.dart';
import '../theme/app_theme.dart';
import 'dashboard_kit.dart';

part 'assistant_workspace.dart';

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
  'search_drive': 'Google Drive',
  'read_drive_file': 'Google Drive',
  'daily_briefing': 'Daily briefing',
  'compare_periods': 'Period comparison',
  'upcoming_materials': 'Materials for upcoming jobs',
  'what_changed': 'What changed',
};

const List<String> _monthNames = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// What a lookup looked at, in words, from its JSON input: "by customer · Sep 1 – Sep 30, 2026 · quiet 7+ days".
/// Ranges arrive with an exclusive end ("to" is the day after), so the last day shown is the one before it.
String _callParams(String tool, String inputJson) {
  var input = <String, dynamic>{};
  try {
    final d = json.decode(inputJson);
    if (d is Map<String, dynamic>) input = d;
  } catch (_) {}
  if (tool == 'run_sql') {
    final purpose = (input['purpose'] ?? '').toString().trim();
    final sql = (input['sql'] ?? '').toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    final shown = sql.length > 220 ? '${sql.substring(0, 220)}…' : sql;
    return purpose.isEmpty ? shown : '$purpose ($shown)';
  }
  DateTime? day(Object? v) => v is String && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(v) ? DateTime.tryParse(v) : null;
  String fmt(DateTime d, {bool year = false}) => '${_monthNames[d.month - 1]} ${d.day}${year ? ', ${d.year}' : ''}';
  String? range(Object? fromV, Object? toV) {
    final from = day(fromV);
    final last = day(toV)?.subtract(const Duration(days: 1));
    if (from != null && last != null) {
      if (!last.isAfter(from)) return fmt(from, year: true);
      return from.year == last.year
          ? '${fmt(from)} – ${fmt(last, year: true)}'
          : '${fmt(from, year: true)} – ${fmt(last, year: true)}';
    }
    if (from != null) return 'from ${fmt(from, year: true)}';
    if (last != null) return 'through ${fmt(last, year: true)}';
    return null;
  }

  final words = <String>[];
  final period = range(input['from'], input['to']);
  if (period != null) words.add(period);
  final earlier = range(input['prev_from'], input['prev_to']);
  if (earlier != null) words.add('vs $earlier');
  const handled = {'from', 'to', 'prev_from', 'prev_to', 'limit', 'purpose'};
  for (final e in input.entries) {
    final v = e.value;
    if (handled.contains(e.key) || v == null || v == false || v.toString().trim().isEmpty) continue;
    final text = v is List ? v.join(' or ') : v.toString();
    words.add(switch (e.key) {
      'group_by' => 'by ${text.replaceAll('_', ' ')}',
      'order_by' => 'sorted by ${text.replaceAll('_', ' ')}',
      'any_of' => 'matching $text',
      'min_days' => '$text+ days',
      'no_change_days' => 'quiet $text+ days',
      'days' => 'next $text days',
      'min_value' => '\$$text+',
      'since' => day(v) != null ? 'since ${fmt(day(v)!, year: true)}' : 'since $text',
      'job_id' => 'job $text',
      'year' => text,
      'query' => 'matching “$text”',
      'customer' => 'for $text',
      _ when v == true => e.key.replaceAll('_', ' '),
      _ => '${e.key.replaceAll('_', ' ')} $text',
    });
  }
  return words.join(' · ');
}

/// One line for "How I got this": what was looked up and with which filters, from the tool name and its JSON input.
String? _describeCall(String tool, String inputJson) {
  if (tool == 'describe_data') return null; // housekeeping, nothing to show
  final label = _toolLabels[tool] ?? tool.replaceAll('_', ' ');
  final params = _callParams(tool, inputJson);
  return params.isEmpty ? label : '$label: $params';
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

  /// Google Drive links that the server's Drive lookups returned for this answer: the only web links it may open.
  final List<String> links;

  /// Each lookup behind an answer, with how it went and how long it took ("How I got this"). Empty for answers saved
  /// before this was kept, which fall back to [calls].
  List<AssistantLookup> lookups = const [];

  /// When the answer came back: the figures in it are as of then, which matters once a chat is a few hours old.
  DateTime? at;

  AssistantMessage(this.role, this.text, [this.sources = const [], this.calls = const [], this.links = const []]);
}

/// One lookup behind an answer: a line in the live checklist while Jarvis works, then a line under "How I got this".
class AssistantLookup {
  AssistantLookup({
    required this.tool,
    this.id = '',
    this.detail = '',
    this.text,
    this.running = false,
    this.ok = true,
    this.partial = false,
    this.ms,
    List<AssistantStep>? steps,
  }) : steps = steps ?? [];

  final String id; // the server's id for it while the question runs
  final String tool;
  final String detail; // what it looked at, in words ("by customer, Oct 1 – Oct 27")
  final String? text; // the server's words while it runs ("Checking what is owed…")
  bool running;
  bool ok;
  bool partial; // it answered, but a part of it could not be read
  int? ms;
  final List<AssistantStep> steps; // the parts of a composite lookup (the briefing's sections)

  String get label => _toolLabels[tool] ?? tool.replaceAll('_', ' ');

  Map<String, dynamic> toJson() => {
    'tool': tool,
    'detail': detail,
    'ok': ok,
    if (partial) 'partial': true,
    'ms': ?ms,
    if (steps.isNotEmpty)
      'steps': [
        for (final s in steps) {'label': s.label, 'ok': s.ok},
      ],
  };

  static AssistantLookup fromJson(Map m) => AssistantLookup(
    tool: '${m['tool'] ?? ''}',
    detail: '${m['detail'] ?? ''}',
    ok: m['ok'] != false,
    partial: m['partial'] == true,
    ms: (m['ms'] as num?)?.toInt(),
    steps: [
      for (final s in (m['steps'] as List? ?? const []))
        if (s is Map) AssistantStep('${s['label'] ?? ''}', running: false, ok: s['ok'] != false),
    ],
  );
}

/// One part of a composite lookup ("Stuck jobs" within the daily briefing).
class AssistantStep {
  AssistantStep(this.label, {this.running = true, this.ok = true});
  final String label;
  bool running;
  bool ok;
}

/// Why the last question failed, so the note can say what to do next.
enum AssistantErrorKind { timeout, busy, offline, session, access, setup, server }

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
    errorKind = null;
    _save();
    notifyListeners();
  }

  /// Puts a failed question back in the box: drops it from the thread (it has no answer) and returns its text.
  String? takeBackFailedQuestion() {
    if (busy || messages.isEmpty || messages.last.role != AssistantRole.user) return null;
    final q = messages.removeLast().text;
    error = null;
    errorKind = null;
    stopped = false;
    _save();
    notifyListeners();
    return q;
  }

  bool busy = false;
  String? status; // what the server says it is doing right now ("Checking what is owed…"), while busy
  http.Client? _client;

  /// The lookups of the question in flight, as the server reports them starting and finishing: the live checklist.
  final List<AssistantLookup> live = [];

  /// Whether the page the panel was opened from goes with each question ("this job", "here"). The chip by the message
  /// box shows it and switches it off.
  bool usePage = true;

  /// What kind of failure [error] is, so the note can offer the right next step.
  AssistantErrorKind? errorKind;

  /// The newest daily briefing answered today, if any: the welcome screen offers to open it again.
  ({int chat, DateTime at})? get lastBriefing {
    final today = now();
    ({int chat, DateTime at})? best;
    for (var c = 0; c < chats.length; c++) {
      final ms = chats[c].messages;
      for (var i = 1; i < ms.length; i++) {
        final at = ms[i].at;
        if (ms[i].role != AssistantRole.assistant || at == null || ms[i - 1].text != _briefingQuestion) continue;
        final sameDay = at.year == today.year && at.month == today.month && at.day == today.day;
        if (sameDay && (best == null || at.isAfter(best.at))) best = (chat: c, at: at);
      }
    }
    return best;
  }

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

  /// The clock behind the greeting ("Good morning"). Tests pin it so the welcome screen looks the same at any hour.
  static DateTime Function() now = DateTime.now;

  /// Opens a Google Drive link from an answer in the browser. Tests replace it.
  static Future<bool> Function(Uri uri) openLink = (uri) => launchUrl(uri, mode: LaunchMode.externalApplication);

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
                [for (final x in (m['links'] as List? ?? const [])) x.toString()],
              )
              ..fresh = false
              ..lookups = [
                for (final l in (m['lookups'] as List? ?? const []))
                  if (l is Map) AssistantLookup.fromJson(l),
              ]
              ..at = DateTime.tryParse('${m['at'] ?? ''}'),
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
                    {
                      'role': m.role.name,
                      'text': m.text,
                      'sources': m.sources,
                      'calls': m.calls,
                      'links': m.links,
                      if (m.lookups.isNotEmpty) 'lookups': [for (final l in m.lookups) l.toJson()],
                      if (m.at != null) 'at': m.at!.toIso8601String(),
                    },
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
    errorKind = null;
    live.clear();
    usePage = true;
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

  /// A lookup started or finished (`{"type":"tool","id":..,"name":..,"state":"start"|"done",...}`).
  void _onToolEvent(Map<String, dynamic> e) {
    final id = '${e['id'] ?? ''}';
    final name = '${e['name'] ?? ''}';
    if (e['state'] == 'start') {
      live.add(
        AssistantLookup(
          id: id,
          tool: name,
          detail: _callParams(name, '${e['input'] ?? '{}'}'),
          text: e['text']?.toString(),
          running: true,
        ),
      );
    } else {
      final l = live.lastWhere(
        (x) => x.id == id,
        orElse: () => AssistantLookup(tool: name, id: id),
      );
      if (!live.contains(l)) live.add(l);
      l
        ..running = false
        ..ok = e['ok'] != false
        ..partial = e['partial'] == true
        ..ms = (e['ms'] as num?)?.toInt();
      for (final s in l.steps) {
        s.running = false; // a part that never reported back is not still running once its lookup is done
      }
    }
    notifyListeners();
  }

  /// A part of a composite lookup started or finished (`{"type":"step","parent":..,"label":..,"state":..,"ok":..}`).
  void _onStepEvent(Map<String, dynamic> e) {
    final parent = live.where((x) => x.id == '${e['parent'] ?? ''}').lastOrNull;
    final label = '${e['label'] ?? ''}'.trim();
    if (parent == null || label.isEmpty) return;
    final step = parent.steps.where((s) => s.label == label).firstOrNull ?? (AssistantStep(label)..running = true);
    if (!parent.steps.contains(step)) parent.steps.add(step);
    if (e['state'] == 'done') {
      step
        ..running = false
        ..ok = e['ok'] != false;
    }
    notifyListeners();
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
        ..body = json.encode({
          'messages': _payload(),
          'stream': true,
          // The answer blocks this build draws; the server turns them into plain markdown for builds that do not say so.
          'formats': const ['priorities', 'compare', 'basis'],
          if (usePage && pageContext.isNotEmpty) 'context': pageContext,
        });
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
        } else if (type == 'tool') {
          _onToolEvent(event);
        } else if (type == 'step') {
          _onStepEvent(event);
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

  /// The lookups behind an answer: the live checklist when the server streamed one (it has the parts of composite
  /// lookups), else what the reply's `calls` say (a server that does not stream, or an older one without timings).
  List<AssistantLookup> _finishedLookups(Map<String, dynamic> body) {
    if (live.isNotEmpty) {
      return [
        for (final l in live)
          if (l.tool != 'describe_data') l..running = false,
      ];
    }
    return [
      for (final c in (body['calls'] as List? ?? const []))
        if (c is Map && c['tool'] != 'describe_data')
          AssistantLookup(
            tool: '${c['tool'] ?? ''}',
            detail: _callParams('${c['tool'] ?? ''}', '${c['input'] ?? '{}'}'),
            ok: c['ok'] != false,
            partial: c['partial'] == true,
            ms: (c['ms'] as num?)?.toInt(),
          ),
    ].take(14).toList();
  }

  Future<void> _ask() async {
    final gen = ++_gen;
    busy = true;
    busySince = DateTime.now();
    stopped = false;
    error = null;
    errorKind = null;
    status = null;
    live.clear();
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
                [
                  for (final l in (body['links'] as List? ?? const []))
                    if (l is String) l,
                ],
              )
              ..fresh = !lastAnswerStreamed
              ..lookups = _finishedLookups(body)
              ..at = now(),
          );
          _save();
        case 401:
          // Set the message first: logout() wipes the chat (and its error) through the auth listener, and an error
          // set afterwards would linger and greet the next person who signs in.
          error = 'Your session expired. Please sign in again.';
          errorKind = AssistantErrorKind.session;
          AuthSession.instance.logout(); // sends the app back to the sign-in screen
        case 403:
          error = 'Your account does not have access to the assistant.';
          errorKind = AssistantErrorKind.access;
        case 503:
          error = 'The assistant is not set up on the server yet.';
          errorKind = AssistantErrorKind.setup;
        default:
          error = (body['error'] ?? 'Server error ($code).').toString();
          errorKind = code == 504
              ? AssistantErrorKind.timeout
              : (code == 429 ? AssistantErrorKind.busy : AssistantErrorKind.server);
      }
    } on TimeoutException {
      _client?.close();
      if (gen == _gen) {
        error = 'That took too long. The server may be waking up, so try again in a moment.';
        errorKind = AssistantErrorKind.timeout;
      }
    } catch (_) {
      if (gen == _gen) {
        error = "Couldn't reach the server. Check your connection and try again.";
        errorKind = AssistantErrorKind.offline;
      }
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
  if (seg.length >= 2 && seg[0] == 'customers') return 'Customer ${seg[1]} detail page'; // Jarvis looks it up by that number
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

/// One `::: priorities` line: "level | what | why it matters | suggested next step".
class _Priority {
  final String level; // high | medium | low
  final String title;
  final String why;
  final String next;
  const _Priority(this.level, this.title, this.why, this.next);
}

class _Priorities extends _Block {
  final List<_Priority> items;
  _Priorities(this.items);
}

/// One `::: compare` row: "measure | current | previous | change | good|bad|neutral".
class _CompareRow {
  final String measure;
  final String current;
  final String previous;
  final String change;
  final String tone; // good | bad | neutral: whether the change is good news for the business
  const _CompareRow(this.measure, this.current, this.previous, this.change, this.tone);
}

class _Compare extends _Block {
  final String title;
  final List<String> periods; // [current, previous] column names
  final List<_CompareRow> rows;
  _Compare(this.title, this.periods, this.rows);
}

class _Parsed {
  final List<_Block> blocks;
  final List<String> followUps;
  final String plain;
  final List<String> basis; // the "dates and definitions" footnote
  _Parsed(this.blocks, this.followUps, this.plain, [this.basis = const []]);
}

/// Splits "a | [b | c](customer:x) | d" on the pipes that are not inside a link's [text] or (target).
List<String> _splitFields(String line) {
  final out = <String>[];
  final buf = StringBuffer();
  var square = 0, round = 0;
  for (final ch in line.split('')) {
    if (ch == '[') square++;
    if (ch == ']' && square > 0) square--;
    if (ch == '(' && square == 0) round++;
    if (ch == ')' && round > 0) round--;
    if (ch == '|' && square == 0 && round == 0) {
      out.add(buf.toString().trim());
      buf.clear();
    } else {
      buf.write(ch);
    }
  }
  out.add(buf.toString().trim());
  return out;
}

final RegExp _bulletRe = RegExp(r'^\s*[-*•]\s+');
final RegExp _numberedRe = RegExp(r'^\s*(\d+)[.)]\s+');
final RegExp _headingRe = RegExp(r'^\s{0,3}#{1,6}\s+(.*)$');
final RegExp _ruleRe = RegExp(r'^\s{0,3}([-*_])(\s*\1){2,}\s*$');
final RegExp _fenceRe = RegExp(r'^\s{0,3}(```|~~~)');
final RegExp _dashCellRe = RegExp(r'^:?-{2,}:?$');
final RegExp _directiveRe = RegExp(r'^\s*:::\s*(stats|followups|chart|priorities|compare|basis)\b.*$', caseSensitive: false);

/// Plain text of a line: **bold**, *italic*, `code` and [links](url) lose their markers. Used where the text is
/// shown without rich formatting (table cells, figures, chart labels, copied text).
String _stripMd(String s) => s.replaceAllMapped(
  _inlineRe,
  (m) => m.group(1) != null
      ? _stripMd(m.group(1)!)
      : (m.group(3) != null ? _stripMd(m.group(3)!) : (m.group(2) ?? m.group(4) ?? '')),
);

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
    case 'priorities':
      return 'Ranking the priorities…';
    case 'compare':
      return 'Lining up the comparison…';
    case 'basis':
      return 'Noting the dates and definitions…';
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
/// pipe tables) plus the directive blocks: `::: stats` ("value | label" lines), `::: chart`, `::: priorities`,
/// `::: compare`, `::: basis` (the dates-and-definitions footnote) and `::: followups`.
_Parsed _parse(String text) {
  final lines = text.split('\n');
  final blocks = <_Block>[];
  final followUps = <String>[];
  final plain = <String>[];
  final basis = <String>[];
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
      // A block ends at its ":::", or where the next block starts if the model forgot to close it.
      while (i < lines.length && lines[i].trim() != ':::' && !_directiveRe.hasMatch(lines[i].trimRight())) {
        if (lines[i].trim().isNotEmpty) body.add(lines[i].trim());
        i++;
      }
      if (i >= lines.length && kind != 'followups' && kind != 'basis') {
        // The model never closed a stats/chart block. Drop just the opening line and read the rest as normal text, instead
        // of swallowing the whole remainder of the answer into a block that then shows nothing. (Follow-ups and the
        // footnote come last, so an unclosed one still reads to the end.)
        i = opened + 1;
        continue;
      }
      if (i < lines.length && lines[i].trim() == ':::') i++; // closing :::
      if (kind == 'priorities') {
        final items = <_Priority>[];
        for (final b in body) {
          final f = _splitFields(b.replaceFirst(_bulletRe, '').replaceFirst(_numberedRe, ''));
          final level = f.first.toLowerCase();
          final rest = const {'high', 'medium', 'low'}.contains(level) ? f.sublist(1) : f;
          if (rest.isEmpty || rest.first.isEmpty) continue;
          items.add(
            _Priority(
              rest.length == f.length ? 'medium' : level,
              rest.first,
              rest.length > 1 ? rest[1] : '',
              rest.length > 2 ? rest.sublist(2).join(' · ') : '',
            ),
          );
        }
        if (items.isNotEmpty) {
          blocks.add(_Priorities(items.take(7).toList()));
          // Copied text: a numbered list with the reason and the suggested step on each line.
          for (var n = 0; n < items.length && n < 7; n++) {
            final p = items[n];
            plain.add(
              '${n + 1}. [${p.level}] ${_stripMd(p.title)}${p.why.isEmpty ? '' : ' — ${_stripMd(p.why)}'}'
              '${p.next.isEmpty ? '' : ' Suggested: ${_stripMd(p.next)}'}',
            );
          }
        }
      } else if (kind == 'compare') {
        var title = '';
        var periods = <String>[];
        final rows = <_CompareRow>[];
        for (final b in body) {
          final kv = RegExp(r'^(title|periods)\s*:\s*(.*)$', caseSensitive: false).firstMatch(b);
          if (kv != null) {
            if (kv.group(1)!.toLowerCase() == 'title') {
              title = _stripMd(kv.group(2)!.trim());
            } else {
              periods = [for (final p in kv.group(2)!.split('|')) _stripMd(p.trim())];
            }
            continue;
          }
          final f = _splitFields(b.replaceFirst(_bulletRe, ''));
          if (f.length < 4 || f.first.isEmpty) continue;
          final tone = f.length > 4 ? f[4].toLowerCase() : 'neutral';
          rows.add(_CompareRow(f[0], f[1], f[2], f[3], const {'good', 'bad'}.contains(tone) ? tone : 'neutral'));
        }
        if (rows.isNotEmpty) {
          blocks.add(_Compare(title, periods, rows.take(12).toList()));
          plain.add('${title.isEmpty ? 'Comparison' : title}${periods.length >= 2 ? ' (${periods[0]} vs ${periods[1]})' : ''}');
          for (final r in rows.take(12)) {
            plain.add('- ${_stripMd(r.measure)}: ${_stripMd(r.current)} vs ${_stripMd(r.previous)} (${_stripMd(r.change)})');
          }
        }
      } else if (kind == 'basis') {
        for (final b in body) {
          final t = b.replaceFirst(_bulletRe, '').trim();
          if (t.isNotEmpty) basis.add(t);
        }
        for (final t in basis) {
          plain.add('Basis: ${_stripMd(t)}');
        }
      } else if (kind == 'chart') {
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
  return _Parsed(blocks, followUps.take(3).toList(), plain.join('\n').trim(), basis.take(4).toList());
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
    if (newAnswer) {
      // The answer may have been written out above the reader's place: say it is there.
      SemanticsService.sendAnnouncement(View.of(context), 'Jarvis answered.', TextDirection.ltr);
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

  /// The server answers admins and owners only (Jarvis can read pay, profit and every customer), so other signed-in staff
  /// are told so up front instead of being handed a box whose every question fails.
  bool get _canAsk => !AuthSession.instance.isLoggedIn || AuthSession.instance.isAdmin;

  /// "Edit question" on a failed one: it goes back into the box, ready to change and send.
  void _editFailed() {
    final q = _chat.takeBackFailedQuestion();
    if (q == null) return;
    _input.text = q;
    _input.selection = TextSelection.collapsed(offset: q.length);
    _inputFocus.requestFocus();
  }

  void _submit([String? text]) {
    final q = (text ?? _input.text).trim();
    if (q.isEmpty || _chat.busy || !_canAsk) return;
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
    // Ctrl+J opens Jarvis from anywhere in the app, so the same keys close it again (Esc does too).
    void close() => Navigator.of(context).maybePop();
    // Material's default purple showed up on text buttons (Retry, Cancel), selection handles and the like.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyJ, control: true): close,
        const SingleActivator(LogicalKeyboardKey.keyJ, meta: true): close,
      },
      child: Theme(
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
    final h = AssistantChat.now().hour;
    final part = h < 12 ? 'Good morning' : (h < 18 ? 'Good afternoon' : 'Good evening');
    final first = AuthSession.instance.name.trim().split(RegExp(r'\s+')).first;
    return first.isEmpty ? part : '$part, $first';
  }

  /// The welcome screen: the daily briefing, questions for the page you came from, and what else Jarvis can look up.
  Widget _emptyState() {
    return _JarvisHome(
      greeting: _greeting(),
      canAsk: _canAsk,
      pagePath: _chat.pagePath,
      pageName: _chat.pageContext,
      lastBriefing: _chat.lastBriefing,
      onAsk: _submit,
      onOpenChat: _chat.selectChat,
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
                  lookups: List.of(_chat.live),
                ),
              if (_chat.stopped && !_chat.busy) _StoppedNote(onRetry: _chat.retry),
              if (_chat.error != null)
                _ErrorNote(message: _chat.error!, kind: _chat.errorKind, onRetry: _chat.retry, onEdit: _editFailed),
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
                    if (!_canAsk) return const SizedBox(height: 16); // no keys to explain when the box is switched off
                    final len = _input.text.length;
                    final near = len >= _maxChars * 0.9;
                    return Text(
                      near
                          ? '$len / $_maxChars characters${len >= _maxChars ? ' · that is the limit, anything longer is cut off' : ''}'
                          : 'Enter to send · Shift+Enter for a new line · ↑ recalls your last question · Ctrl+J closes. '
                                'Read-only: double-check important numbers.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11.5, color: len >= _maxChars ? DashUi.redText : DashUi.subtle, height: 1.4),
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
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_canAsk && _chat.pageContext.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: ListenableBuilder(
              listenable: _chat,
              builder: (context, _) => _ContextChip(
                page: _chat.pageContext,
                on: _chat.usePage,
                onToggle: () => setState(() => _chat.usePage = !_chat.usePage),
              ),
            ),
          ),
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
                  enabled: _canAsk,
                  minLines: 1,
                  maxLines: 6,
                  maxLength: _maxChars,
                  style: const TextStyle(fontSize: 15, color: _ink, height: 1.4),
                  cursorColor: _brandRed,
                  decoration: InputDecoration(
                    hintText: _canAsk ? 'Ask Jarvis about your business…' : 'Jarvis is available to admin accounts',
                    hintStyle: const TextStyle(fontSize: 15, color: _muted),
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
              children: [
                for (final b in blocks) KeyedSubtree(key: ObjectKey(b), child: reveal(_blockView(b))),
                if (_parsed.basis.isNotEmpty)
                  reveal(_BasisNote(lines: _parsed.basis, links: {for (final l in widget.message.links) _linkKey(l)})),
              ],
            ),
          ),
          if (!widget.streaming) reveal(_actions()),
          if (widget.isLast && _parsed.followUps.isNotEmpty) reveal(_followUps()),
        ],
      ),
    );
  }

  Widget _blockView(_Block b) {
    final links = {for (final l in widget.message.links) _linkKey(l)};
    return switch (b) {
      _Para() => Padding(
        padding: EdgeInsets.only(bottom: b.tight ? 4 : 14),
        child: Text.rich(
          TextSpan(
            style: _bodyStyle,
            children: _inlineSpans(b.text, _bodyStyle, links: links),
          ),
        ),
      ),
      _Head() => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 8),
        child: Text.rich(
          TextSpan(
            style: _bodyStyle.copyWith(fontSize: 18, fontWeight: FontWeight.w600, height: 1.35),
            children: _inlineSpans(b.text, _bodyStyle.copyWith(fontSize: 18, height: 1.35), links: links),
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
              child: Text.rich(
                TextSpan(
                  style: _bodyStyle,
                  children: _inlineSpans(b.text, _bodyStyle, links: links),
                ),
              ),
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
      _Priorities() => Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 14),
        child: _PriorityList(items: b.items, links: links, onAsk: widget.streaming ? null : widget.onAsk),
      ),
      _Compare() => Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 14),
        child: _CompareView(compare: b, links: links),
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
    final m = widget.message;
    final detail = m.lookups.isNotEmpty || m.calls.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [_actionRow(m.sources, detail), if (_showCalls && detail) _callsBox(m)],
      ),
    );
  }

  /// "How I got this": each lookup behind the answer, what it looked at, how long it took and whether a part of it could
  /// not be read, so a number can be checked. Answers saved before lookups were kept show the older one-line list.
  Widget _callsBox(AssistantMessage m) {
    final at = m.at;
    return Container(
      margin: const EdgeInsets.only(top: 6, bottom: 2),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      width: double.infinity,
      decoration: BoxDecoration(color: _fill, borderRadius: BorderRadius.circular(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'How I got this',
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: _slate),
              ),
              const Spacer(),
              if (at != null)
                Text(
                  'Looked up ${_answerTime(at, AssistantChat.now())}',
                  style: const TextStyle(fontSize: 11.5, color: DashUi.subtle),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (m.lookups.isNotEmpty)
            for (final l in m.lookups) _LookupLine(lookup: l)
          else
            for (final c in m.calls)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('• $c', style: const TextStyle(fontSize: 11.5, color: _slate, height: 1.4)),
              ),
        ],
      ),
    );
  }

  Widget _actionRow(List<String> sources, bool detail) {
    final m = widget.message;
    final gaps = m.lookups.where((l) => !l.ok || l.partial).length;
    final at = m.at;
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
          if (widget.isLast)
            _MiniAction(icon: Icons.refresh_rounded, label: 'Regenerate', onTap: widget.onRegenerate)
          else if (widget.question != null)
            // An older answer's figures are as of then: asking again gets today's.
            _MiniAction(icon: Icons.replay_rounded, label: 'Ask again', onTap: () => widget.onAsk(widget.question!)),
          _vote('up', Icons.thumb_up_outlined, Icons.thumb_up_rounded, 'Good answer'),
          _vote('down', Icons.thumb_down_outlined, Icons.thumb_down_rounded, 'Not helpful'),
          if (sources.isNotEmpty || detail)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: detail ? () => setState(() => _showCalls = !_showCalls) : null,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        gaps > 0 ? Icons.warning_amber_rounded : Icons.verified_outlined,
                        size: 14,
                        color: gaps > 0 ? DashUi.amberText : DashUi.subtle,
                      ),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          [
                            if (sources.isNotEmpty) 'Checked ${sources.join(' · ')}' else 'How I got this',
                            if (gaps > 0) gaps == 1 ? '1 part not fully read' : '$gaps parts not fully read',
                            if (at != null) _answerTime(at, AssistantChat.now()),
                          ].join(' · '),
                          style: TextStyle(fontSize: 11.5, color: gaps > 0 ? DashUi.amberText : DashUi.subtle),
                        ),
                      ),
                      if (detail)
                        Icon(_showCalls ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 16, color: DashUi.subtle),
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

// A link target may hold spaces only for the app's own records ("customer:Riverside Logistics"); a web address may not.
final RegExp _inlineRe = RegExp(
  r'\*\*(.+?)\*\*|`([^`]+)`|(?<![*\w])\*([^*\s][^*]*?)\*(?![*\w])|\[([^\]]+)\]\(((?:job|estimate|customer|page):[^)\n]+|[^)\s]+)\)',
);

/// **bold**, *italic*, `code` and [links](url) (shown as their text) inside a line of text. [links] holds the keys
/// ([_linkKey]) of the Drive links the server's lookups returned for this answer: only those open.
List<InlineSpan> _inlineSpans(String line, TextStyle base, {Set<String> links = const {}}) {
  final spans = <InlineSpan>[];
  var last = 0;
  for (final m in _inlineRe.allMatches(line)) {
    if (m.start > last) spans.add(TextSpan(text: line.substring(last, m.start)));
    if (m.group(1) != null) {
      // Bold text can hold a link (**[1095809012](job:1095809012)**), so read what is inside it too.
      final bold = base.copyWith(fontWeight: FontWeight.w700);
      spans.add(
        TextSpan(
          style: bold,
          children: _inlineSpans(m.group(1)!, bold, links: links),
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
      final italic = base.copyWith(fontStyle: FontStyle.italic);
      spans.add(
        TextSpan(
          style: italic,
          children: _inlineSpans(m.group(3)!, italic, links: links),
        ),
      );
    } else {
      final url = m.group(5) ?? '';
      final record = _recordLink(url);
      if (record != null) {
        // A job, estimate, customer or page the assistant named: a link that opens it in the app.
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: _RecordLink(route: record.route, what: record.what, label: m.group(4) ?? url, style: base),
          ),
        );
      } else if (_isDriveLink(url) && links.contains(_linkKey(url))) {
        // A Google Drive file its own lookup returned: opens in the browser.
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: _WebLink(uri: Uri.parse(url), label: m.group(4) ?? url, style: base),
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

/// The only web links an answer may open: Google's own Drive / Docs hosts, over https, AND returned by the server's own
/// Drive lookup for that answer (see [AssistantMessage.links]). Any other link (one written into a note, a review or a
/// file and repeated by the model, even a Google Form on the same host) stays plain text.
bool _isDriveLink(String url) {
  final u = Uri.tryParse(url);
  return u != null && u.scheme == 'https' && (u.host == 'docs.google.com' || u.host == 'drive.google.com');
}

/// A Drive link compared without its query (`?usp=drivesdk`), which the model may drop; the path holds the file id.
String _linkKey(String url) {
  final u = Uri.tryParse(url);
  return u == null ? url : '${u.host}${u.path}';
}

/// A Google Drive file in an answer. Opens it in the browser and leaves the panel open.
class _WebLink extends StatefulWidget {
  final Uri uri;
  final String label;
  final TextStyle style;
  const _WebLink({required this.uri, required this.label, required this.style});

  @override
  State<_WebLink> createState() => _WebLinkState();
}

class _WebLinkState extends State<_WebLink> {
  bool _hover = false;

  Future<void> _open() async {
    final ok = await AssistantChat.openLink(widget.uri).catchError((_) => false);
    if (!ok && mounted) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(const SnackBar(content: Text("Couldn't open that file. Try Documents in the app.")));
    }
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style.copyWith(
      color: _brandRed,
      fontWeight: FontWeight.w600,
      decoration: _hover ? TextDecoration.underline : TextDecoration.none,
      decorationColor: _brandRed,
    );
    return Semantics(
      link: true,
      label: '${widget.label}, opens in Google Drive',
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: _open,
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: widget.label),
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 3),
                    child: Icon(Icons.open_in_new_rounded, size: (widget.style.fontSize ?? 15) * 0.8, color: _brandRed),
                  ),
                ),
              ],
            ),
            style: style,
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

  // Each row's cells as written, links kept, for drawing them; the plain text above is what sorts, copies and saves.
  late final Map<List<String>, List<String>> _raw = {
    for (var i = 0; i < _all.length; i++)
      _all[i]: [for (var c = 0; c < _cols; c++) c < widget.rows[i + 1].length ? widget.rows[i + 1][c] : ''],
  };

  late final List<bool> _numeric = [
    for (var c = 0; c < _cols; c++)
      !_isIdColumn(c) && _body.every((r) => r[c].isEmpty || _numericRe.hasMatch(r[c])) && _body.any((r) => r[c].isNotEmpty),
  ];

  /// A column of job or estimate numbers ("Job", "Estimate #"): read as names, left-aligned, not as amounts to total or
  /// chart. A "Jobs" column of counts is still a number.
  static final _idHeaderRe = RegExp(r'^((job|estimate|invoice|po)( ?(#|number|no\.?|id))?|#|id)$', caseSensitive: false);
  bool _isIdColumn(int c) =>
      _idHeaderRe.hasMatch(_header[c].trim()) && _body.every((r) => r[c].isEmpty || RegExp(r'^\d{5,}$').hasMatch(r[c].trim()));

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

  // Text columns share the width by how much they hold, so a column of notes is not squeezed into a sliver beside short
  // ones (a job number, a status). The first column keeps a little extra, as before.
  late final List<double> _flex = [
    for (var c = 0; c < _cols; c++)
      ([_header, ..._body].fold<int>(0, (t, r) => t + r[c].length) / (_body.length + 1) / 9).clamp(c == 0 ? 1.4 : 1.0, 3.2),
  ];

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
      final raw = _raw[r]?[c] ?? t;
      final style = TextStyle(
        fontSize: 13,
        fontWeight: total ? FontWeight.w800 : (c == 0 ? FontWeight.w600 : FontWeight.w500),
        color: _ink,
        height: 1.3,
        fontFeatures: _numeric[c] ? const [FontFeature.tabularFigures()] : null,
      );
      final align = _numeric[c] ? TextAlign.right : TextAlign.left;
      // A job, estimate or customer named in a cell opens like the links in the text around the table.
      Widget text = raw.contains('](')
          ? Text.rich(
              TextSpan(style: style, children: _inlineSpans(raw, style)),
              textAlign: align,
            )
          : Text(t, textAlign: align, style: style);
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
          c: c == barCol ? const FlexColumnWidth(1.1) : (_numeric[c] ? const IntrinsicColumnWidth() : FlexColumnWidth(_flex[c])),
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

  /// What has been looked up so far and what is still running, as the server reports it: shown as a checklist so the
  /// wait says what Jarvis is actually reading.
  final List<AssistantLookup> lookups;
  const _Thinking({
    required this.since,
    required this.onStop,
    this.status,
    this.compact = false,
    this.note,
    this.lookups = const [],
  });

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
                    style: const TextStyle(fontSize: 13, color: _slate),
                  ),
                ),
              ] else if (widget.lookups.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(
                  'Writing the answer from ${widget.lookups.length} ${widget.lookups.length == 1 ? 'lookup' : 'lookups'}',
                  style: const TextStyle(fontSize: 13, color: _slate),
                ),
              ],
            ],
          ),
        ),
      );
    }
    // One summary for screen readers: the ticking seconds would otherwise be read out every second.
    final progress = [
      for (final l in widget.lookups)
        l.steps.isEmpty
            ? '${l.label} ${l.running ? 'running' : 'done'}'
            : '${l.label}: ${l.steps.where((s) => !s.running).length} of ${l.steps.length} parts done',
    ].join('; ');
    return Semantics(
      liveRegion: true,
      excludeSemantics: true,
      label: progress.isEmpty ? 'Jarvis is working on your question' : 'Jarvis is working on your question. $progress',
      child: Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _headline(still, secs, i),
            if (widget.lookups.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 30, top: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [for (final l in widget.lookups) _LookupLine(lookup: l)],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _headline(bool still, int secs, int i) {
    return Row(
      children: [
        ScaleTransition(
          scale: still
              ? const AlwaysStoppedAnimation(1.0)
              : Tween(begin: 0.9, end: 1.08).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut)),
          child: const Icon(Icons.auto_awesome_rounded, size: 20, color: _brandRed),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) => ShaderMask(
              blendMode: BlendMode.srcIn,
              shaderCallback: (r) => LinearGradient(
                colors: const [_slate, _ink, _slate],
                stops: const [0.35, 0.5, 0.65],
                transform: _SlideGradient(still ? 0 : _c.value * 2 - 1),
              ).createShader(r),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: Text(
                  widget.status ?? _phrases[i],
                  key: ValueKey(widget.status ?? i),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          secs >= 12 ? '${secs}s · still working, this can take a minute or two' : (secs >= 3 ? '${secs}s' : ''),
          style: const TextStyle(fontSize: 11.5, color: DashUi.subtle, fontFeatures: [FontFeature.tabularFigures()]),
        ),
      ],
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

/// A question that failed: what happened in a few words, the server's message, what to do about it, and the ways out
/// (ask again, or put the question back in the box to change it). No retry where retrying cannot help.
class _ErrorNote extends StatelessWidget {
  final String message;
  final AssistantErrorKind? kind;
  final VoidCallback onRetry;
  final VoidCallback? onEdit;
  const _ErrorNote({required this.message, required this.onRetry, this.kind, this.onEdit});

  @override
  Widget build(BuildContext context) {
    // The message already says what to do (the server's or the app's own wording), so the title only names what happened.
    final title = switch (kind) {
      AssistantErrorKind.timeout => 'No answer in time',
      AssistantErrorKind.busy => 'Jarvis is busy',
      AssistantErrorKind.offline => 'No connection',
      AssistantErrorKind.session => 'Signed out',
      AssistantErrorKind.access => 'No access',
      AssistantErrorKind.setup => 'Not set up yet',
      _ => 'Something went wrong',
    };
    final canRetry = !const {AssistantErrorKind.access, AssistantErrorKind.setup, AssistantErrorKind.session}.contains(kind);
    return Semantics(
      liveRegion: true,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
        decoration: BoxDecoration(
          color: DashUi.red.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: DashUi.red.withValues(alpha: 0.25)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 1),
              child: Icon(Icons.error_outline_rounded, size: 18, color: DashUi.redText),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: DashUi.redText),
                  ),
                  const SizedBox(height: 2),
                  Text(message, style: const TextStyle(fontSize: 12.5, color: _ink, height: 1.4)),
                  if (canRetry || onEdit != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Wrap(
                        spacing: 4,
                        children: [
                          if (canRetry) TextButton(onPressed: onRetry, child: const Text('Try again')),
                          if (onEdit != null && canRetry) TextButton(onPressed: onEdit, child: const Text('Edit question')),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
