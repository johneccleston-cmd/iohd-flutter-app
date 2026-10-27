import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/api_config.dart';
import '../config/auth_session.dart';
import 'app_dialog.dart';
import 'dashboard_kit.dart' show DashUi, SkeletonPulse;

/// Calls and texts from Quo for one customer or one job. Each conversation (one customer number on one of our Quo lines)
/// is a collapsed row; clicking it opens the conversation in a popup, with who sent every message and a box to text back.
/// History comes from our own database (filled by Quo's webhooks and the import), matched to the customer by phone number.
class QuoActivityPanel extends StatefulWidget {
  /// Give exactly one: [customerId] shows everything with that customer, [jobId] only what belongs to that job or estimate.
  final String? customerId;
  final String? jobId;
  const QuoActivityPanel({super.key, this.customerId, this.jobId}) : assert((customerId == null) != (jobId == null));

  /// Starts loading the calls and texts before the tab is opened (the job and customer pages call this as they load),
  /// so clicking the tab shows them at once instead of waiting for the server. Failures are ignored: the tab then
  /// loads as usual.
  static Future<void> prefetch({String? customerId, String? jobId}) async {
    final url = _activityUrlFor(customerId: customerId, jobId: jobId);
    try {
      final res = await _getActivity(url, share: true);
      if (res.statusCode == 200) _remember(url, json.decode(res.body) as Map<String, dynamic>);
    } catch (_) {
      // best effort
    }
  }

  @visibleForTesting
  static void clearCache() {
    _cache.clear();
    _inFlight.clear();
  }

  @override
  State<QuoActivityPanel> createState() => _QuoActivityPanelState();
}

String _activityUrlFor({String? customerId, String? jobId}) => jobId != null
    ? '$kApiBaseUrl/api/quo/jobs/${Uri.encodeComponent(jobId)}/activity'
    : '$kApiBaseUrl/api/quo/customers/${Uri.encodeComponent(customerId!)}/activity';

/// The last answer per activity URL, for the most recently opened jobs and customers. Opening the tab again shows this
/// copy at once and refreshes it in the background.
final _cache = <String, Map<String, dynamic>>{};
const _cacheMax = 20;

void _remember(String url, Map<String, dynamic> data) {
  _cache.remove(url); // re-added last, so the oldest entry is the first to go
  _cache[url] = data;
  if (_cache.length > _cacheMax) _cache.remove(_cache.keys.first);
}

/// Requests still on their way, so a tab opened while its prefetch is running waits for that answer instead of asking twice.
final _inFlight = <String, Future<http.Response>>{};

/// [share] reuses a request already on its way. Reloads after a send or a move must not: an older request may not
/// include the change yet.
Future<http.Response> _getActivity(String url, {required bool share}) {
  if (share && _inFlight[url] != null) return _inFlight[url]!;
  late final Future<http.Response> f;
  f = http.get(Uri.parse(url), headers: AuthSession.instance.headers()).timeout(const Duration(seconds: 30)).whenComplete(() {
    if (identical(_inFlight[url], f)) _inFlight.remove(url);
  });
  return _inFlight[url] = f;
}

/// One conversation = one customer number on one of our Quo lines. A job can involve several of the customer's numbers,
/// and those must stay separate conversations so a reply goes to the number it is answering.
String _threadKey(Map<String, dynamic> a) => '${a['quo_line_id'] ?? a['conversation_id'] ?? ''}|${a['phone_key'] ?? ''}';

/// "4793411151" -> "(479) 341-1151". Anything else is returned unchanged.
String _formatPhone(String? key) {
  final k = key ?? '';
  if (!RegExp(r'^\d{10}$').hasMatch(k)) return k;
  return '(${k.substring(0, 3)}) ${k.substring(3, 6)}-${k.substring(6)}';
}

class _QuoActivityPanelState extends State<QuoActivityPanel> {
  /// Oldest first. A notifier so an open popup shows new messages as soon as the list reloads.
  final _items = ValueNotifier<List<Map<String, dynamic>>>(const []);
  String? _phone;
  String? _customerId; // who a reply goes to when a conversation has no number of its own
  List<Map<String, dynamic>> _jobs = const []; // this customer's jobs and estimates, for the "move to" picker
  bool _hasPhone = true;
  bool _truncated = false; // the server has more history than it sent
  bool _loading = true;
  String? _error;
  int _loadSeq = 0; // only the newest request may update the screen
  Timer? _poll; // refreshes while a conversation is open, so new texts appear without reopening it

  @override
  void initState() {
    super.initState();
    // The last copy (or the prefetch's answer) shows straight away; the request below only refreshes it.
    final cached = _cache[_activityUrl];
    if (cached != null) _show(cached);
    _load(quiet: cached != null, share: true);
  }

  @override
  void dispose() {
    _poll?.cancel();
    _items.dispose();
    super.dispose();
  }

  String get _activityUrl => _activityUrlFor(customerId: widget.customerId, jobId: widget.jobId);

  /// [quiet] refreshes in the background (after a send, a move, or while a conversation is open): no spinner, and a
  /// failure keeps what is already on screen. [share] waits for a prefetch that is already on its way.
  Future<void> _load({bool quiet = false, bool share = false}) async {
    if (!mounted) return;
    final seq = ++_loadSeq;
    if (!quiet) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final url = _activityUrl;
      final res = await _getActivity(url, share: share);
      if (!mounted || seq != _loadSeq) return;
      if (res.statusCode == 401) {
        AuthSession.instance.logout();
        return;
      }
      if (res.statusCode != 200) {
        if (!quiet) _fail('Server error (${res.statusCode}).');
        return;
      }
      final data = json.decode(res.body) as Map<String, dynamic>;
      _remember(url, data);
      setState(() => _show(data));
    } on TimeoutException {
      if (mounted && seq == _loadSeq && !quiet) _fail('The server is taking too long to respond. Try again in a moment.');
    } catch (_) {
      if (mounted && seq == _loadSeq && !quiet) _fail('Could not reach the server.');
    }
  }

  /// Puts one server answer on screen (call inside setState, except from initState).
  void _show(Map<String, dynamic> data) {
    _items.value = List<Map<String, dynamic>>.from(data['activity'] ?? const []).reversed.toList(); // server sends newest first
    _phone = data['phone']?.toString();
    _customerId = data['customerId']?.toString() ?? widget.customerId;
    _jobs = List<Map<String, dynamic>>.from(data['jobs'] ?? const []);
    _hasPhone = data['hasPhone'] != false;
    _truncated = data['truncated'] == true;
    _loading = false;
    _error = null;
  }

  void _fail(String m) => setState(() {
    _loading = false;
    _error = m;
  });

  /// Moves one call/text to [jobId] (a job id), or 'auto' to remove its link (no job).
  Future<void> _assign(String quoId, String? jobId) async {
    String? problem;
    try {
      final res = await http
          .put(
            Uri.parse('$kApiBaseUrl/api/quo/links'),
            headers: {...AuthSession.instance.headers(), 'Content-Type': 'application/json'},
            body: json.encode({'quoIds': [quoId], 'jobId': jobId}),
          )
          .timeout(const Duration(seconds: 30));
      if (res.statusCode == 401) {
        AuthSession.instance.logout();
        return;
      }
      if (res.statusCode != 200) problem = _errorOf(res) ?? 'Could not save that change (${res.statusCode}).';
    } on TimeoutException {
      problem = 'The server took too long to respond.';
    } catch (_) {
      problem = 'Could not reach the server.';
    }
    if (!mounted) return;
    if (problem != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(problem)));
      return;
    }
    await _load(quiet: true); // in job mode the message leaves this list when it moves elsewhere
  }

  /// Threads newest first; each thread's items stay oldest first.
  List<(String, List<Map<String, dynamic>>)> _threads() {
    final byKey = <String, List<Map<String, dynamic>>>{};
    for (final a in _items.value) {
      byKey.putIfAbsent(_threadKey(a), () => []).add(a);
    }
    final list = byKey.entries.map((e) => (e.key, e.value)).toList();
    list.sort((a, b) => '${b.$2.last['occurred_at']}'.compareTo('${a.$2.last['occurred_at']}'));
    return list;
  }

  final _detailsTried = <String>{}; // calls we already asked Quo about this session, so opening a thread twice never repeats

  /// Recent answered calls whose summary/transcript the server's background filler has not picked up yet: ask for them now,
  /// then refresh. Quietly does nothing on a Quo plan without those features.
  Future<void> _fetchDetails(List<Map<String, dynamic>> thread) async {
    final ids = [
      for (final a in thread.reversed) // newest first
        if (a['kind'] == 'call' &&
            !_missed(a) &&
            (a['ai_summary'] == null || a['has_transcript'] != true) &&
            _detailsTried.add('${a['quo_id']}'))
          '${a['quo_id']}',
    ].take(5).toList();
    var changed = false;
    for (final id in ids) {
      try {
        final res = await http
            .post(Uri.parse('$kApiBaseUrl/api/quo/calls/${Uri.encodeComponent(id)}/details'), headers: AuthSession.instance.headers())
            .timeout(const Duration(seconds: 40));
        if (res.statusCode == 401) {
          AuthSession.instance.logout();
          return;
        }
        if (res.statusCode == 200 && (json.decode(res.body) as Map)['changed'] == true) changed = true;
      } catch (_) {
        // best effort: the call just stays as it is
      }
      if (!mounted) return;
    }
    if (changed) await _load(quiet: true);
  }

  Future<void> _open(String key) async {
    _fetchDetails(_items.value.where((a) => _threadKey(a) == key).toList());
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 15), (_) => _load(quiet: true));
    try {
      await showDialog<void>(
        context: context,
        builder: (_) => _ThreadDialog(
          threadKey: key,
          items: _items,
          customerId: _customerId,
          jobId: widget.jobId,
          jobs: _jobs,
          onSent: () => _load(quiet: true),
          onAssign: _assign,
        ),
      );
    } finally {
      _poll?.cancel();
      _poll = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null && _items.value.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(48),
        child: Column(
          children: [
            const Icon(Icons.cloud_off_rounded, size: 40, color: DashUi.red),
            const SizedBox(height: 12),
            Text(_error!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 15, color: DashUi.slate)),
            const SizedBox(height: 14),
            FilledButton.tonal(onPressed: _load, child: const Text('Try again')),
          ],
        ),
      );
    }
    if (_loading && _items.value.isEmpty) {
      return const Padding(padding: EdgeInsets.all(24), child: SkeletonPulse(child: SizedBox(height: 200, width: double.infinity)));
    }
    // A job can still have linked calls when its customer has no number on file, so only say "no phone" when there are none.
    if (!_hasPhone && _items.value.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(48),
        child: Text(
          widget.jobId != null
              ? "This job's customer has no phone number on file, so there is nothing to match to Quo."
              : 'This customer has no phone number on file, so there is nothing to match to Quo.',
          style: const TextStyle(fontSize: 15, color: DashUi.slate),
        ),
      );
    }
    final threads = _threads();
    if (threads.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
        child: Text(
          widget.jobId != null
              ? "No calls or texts mention this job's address yet, and none have been linked to it by hand. All of the customer's calls and texts are on their Calls & Texts tab, where you can link one to this job."
              : 'No calls or texts with ${_phone ?? 'this number'} yet. New ones appear here as they happen in Quo.',
          style: const TextStyle(fontSize: 15, color: DashUi.slate),
        ),
      );
    }
    // Only name the number on each row when the conversations are with more than one number.
    final manyNumbers = threads.map((t) => t.$2.last['phone_key']).toSet().length > 1;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final t in threads) _threadRow(t.$1, t.$2, showNumber: manyNumbers),
          const Divider(height: 1, color: DashUi.line),
          if (_truncated)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                'Showing the latest ${_items.value.length} calls and texts. Older ones are in Quo.',
                style: const TextStyle(fontSize: 14, color: DashUi.slate),
              ),
            ),
        ],
      ),
    );
  }

  Widget _threadRow(String key, List<Map<String, dynamic>> msgs, {required bool showNumber}) {
    final last = msgs.last;
    final texts = msgs.where((m) => m['kind'] == 'message').length;
    final calls = msgs.length - texts;
    final when = DateTime.tryParse('${last['occurred_at'] ?? ''}')?.toLocal();
    final line = '${last['line_name'] ?? 'Quo line'}';
    final title = showNumber ? '$line  ·  ${_formatPhone(last['phone_key']?.toString())}' : line;
    final counts = [if (texts > 0) '$texts ${texts == 1 ? 'text' : 'texts'}', if (calls > 0) '$calls ${calls == 1 ? 'call' : 'calls'}'].join(' · ');
    final missed = _missedSinceReply(msgs);
    const titleStyle = TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: DashUi.ink);
    return InkWell(
      onTap: () => _open(key),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
        decoration: const BoxDecoration(border: Border(top: BorderSide(color: DashUi.line))),
        child: Row(
          children: [
            // A missed call nobody has answered yet is visible here, without opening the conversation.
            if (missed > 0)
              Tooltip(
                message: missed == 1 ? 'Missed call, no reply yet' : '$missed missed calls, no reply yet',
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: const BoxDecoration(color: DashUi.red, shape: BoxShape.circle),
                  child: const Icon(Icons.phone_missed_rounded, size: 16, color: Colors.white),
                ),
              )
            else
              const SizedBox(width: 26, child: Center(child: Icon(Icons.forum_outlined, size: 22, color: DashUi.ink))),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(
                      style: titleStyle,
                      children: [
                        TextSpan(text: '$title  ·  $counts'),
                        if (missed > 0) TextSpan(text: '  ·  $missed missed', style: const TextStyle(color: DashUi.redText, fontWeight: FontWeight.w800)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${last['sender']}: ${_summaryOf(last)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, color: DashUi.slate),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(when == null ? '' : DateFormat('MMM d, y').format(when), style: const TextStyle(fontSize: 14, color: DashUi.slate)),
            const SizedBox(width: 6),
            const Icon(Icons.chevron_right_rounded, color: DashUi.slate),
          ],
        ),
      ),
    );
  }
}

/// The server's `{"error": "..."}` message, if the response has one.
String? _errorOf(http.Response res) {
  try {
    return (json.decode(res.body) as Map)['error']?.toString();
  } catch (_) {
    return null;
  }
}

/// Picture/attachment links on a text (MMS). Quo sends `media` as [{url, type}].
List<(String, String)> _mediaOf(Map<String, dynamic> a) => [
  if (a['media'] is List)
    for (final m in a['media'] as List)
      if (m is Map && m['url'] is String && (m['url'] as String).isNotEmpty) (m['url'] as String, '${m['type'] ?? ''}'),
];

/// A call nobody picked up. The server's `answered` comes from Quo's answeredAt; a call can ring out or reach voicemail
/// and still have a duration and a "completed" status, so those alone are only the fallback for an older server.
bool _missed(Map<String, dynamic> a) {
  if (a['kind'] != 'call') return false;
  if (a['answered'] is bool) return !(a['answered'] as bool);
  return const {'no-answer', 'canceled', 'busy', 'failed'}.contains(a['status']) || ((a['duration_sec'] as num?) ?? 0) == 0;
}

/// Incoming calls nobody picked up that we have not followed up on: counted back from the newest item of a thread
/// (oldest first) until we reply, by calling or texting out or by an answered call. 0 means nothing needs a call back.
int _missedSinceReply(List<Map<String, dynamic>> msgs) {
  var n = 0;
  for (final a in msgs.reversed) {
    if (a['direction'] == 'outgoing' || (a['kind'] == 'call' && !_missed(a))) break;
    if (_missed(a)) n++;
  }
  return n;
}

/// One-line text for a message or a call.
String _summaryOf(Map<String, dynamic> a) {
  if (a['kind'] == 'call') {
    final secs = (a['duration_sec'] as num?)?.toInt() ?? 0;
    final out = a['direction'] == 'outgoing';
    if (_missed(a)) return out ? 'Outgoing call · no answer' : 'Missed call';
    return '${out ? 'Outgoing' : 'Incoming'} call · ${secs ~/ 60}m ${secs % 60}s';
  }
  final body = '${a['body'] ?? ''}'.replaceAll('\n', ' ').trim();
  if (body.isNotEmpty) return body;
  final media = _mediaOf(a);
  if (media.isEmpty) return '(no text)';
  return media.every((m) => m.$2.startsWith('image/')) ? (media.length == 1 ? 'Picture' : '${media.length} pictures') : 'Attachment';
}

/// The popup: the whole conversation oldest to newest with the sender on every bubble, and a box to text back.
class _ThreadDialog extends StatefulWidget {
  final String threadKey;
  final ValueNotifier<List<Map<String, dynamic>>> items;
  final String? customerId;
  final String? jobId; // set when opened from a job page: replies are linked to it
  final List<Map<String, dynamic>> jobs;
  final Future<void> Function() onSent;
  final Future<void> Function(String quoId, String? jobId) onAssign;
  const _ThreadDialog({
    required this.threadKey,
    required this.items,
    required this.customerId,
    required this.jobId,
    required this.jobs,
    required this.onSent,
    required this.onAssign,
  });

  @override
  State<_ThreadDialog> createState() => _ThreadDialogState();
}

class _ThreadDialogState extends State<_ThreadDialog> {
  final _text = TextEditingController();
  final _scroll = ScrollController();
  bool _sending = false;
  int _shown = -1;

  @override
  void dispose() {
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Sends from this conversation's Quo line to this conversation's number.
  Future<void> _send(String? lineId, String? phoneKey) async {
    final text = _text.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    String? problem;
    try {
      final res = await http
          .post(
            Uri.parse('$kApiBaseUrl/api/quo/send'),
            headers: {...AuthSession.instance.headers(), 'Content-Type': 'application/json'},
            body: json.encode({
              if (phoneKey != null && phoneKey.isNotEmpty) 'to': phoneKey else 'customerId': widget.customerId,
              'text': text,
              if (lineId != null && lineId.isNotEmpty) 'from': lineId,
              if (widget.jobId != null) 'jobId': widget.jobId,
            }),
          )
          .timeout(const Duration(seconds: 30));
      if (res.statusCode == 401) {
        AuthSession.instance.logout();
        return;
      }
      if (res.statusCode != 200) problem = _errorOf(res) ?? 'Could not send (${res.statusCode}).';
    } on TimeoutException {
      problem = 'Quo took too long to respond. Check the conversation before sending again.';
    } catch (_) {
      problem = 'Could not reach the server.';
    }
    if (!mounted) return;
    setState(() => _sending = false);
    if (problem != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(problem)));
      return;
    }
    _text.clear();
    await widget.onSent();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<Map<String, dynamic>>>(
      valueListenable: widget.items,
      builder: (context, all, _) {
        final msgs = all.where((a) => _threadKey(a) == widget.threadKey).toList();
        final lineId = msgs.isEmpty ? null : msgs.last['quo_line_id']?.toString();
        final phoneKey = msgs.isEmpty ? null : msgs.last['phone_key']?.toString();
        final number = _formatPhone(phoneKey);
        final title = msgs.isEmpty ? 'Conversation' : '${msgs.last['line_name'] ?? 'Quo line'}';
        if (msgs.length != _shown) {
          _shown = msgs.length;
          // Twice: list extents are only exact once the bubbles near the end have been laid out.
          void toEnd(int again) => WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!_scroll.hasClients) return;
            _scroll.jumpTo(_scroll.position.maxScrollExtent);
            if (again > 0) toEnd(again - 1);
          });
          toEnd(2);
        }
        void send() => _send(lineId, phoneKey);
        return AppDialog(
          title: title,
          subtitle: number.isEmpty ? null : number,
          icon: Icons.forum_outlined,
          width: 620,
          // Leaves room for the dialog's title, the text box and its padding so the dialog never scrolls the list itself.
          body: SizedBox(
            height: (MediaQuery.sizeOf(context).height - 270).clamp(160.0, 520.0),
            child: ListView(
              controller: _scroll,
              children: [for (final a in msgs) _bubble(a)],
            ),
          ),
          footer: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                // Enter starts a new line (texts are often several lines); Ctrl+Enter sends.
                child: CallbackShortcuts(
                  bindings: {const SingleActivator(LogicalKeyboardKey.enter, control: true): send},
                  child: TextField(
                    controller: _text,
                    minLines: 1,
                    maxLines: 4,
                    maxLength: 1600,
                    enabled: !_sending,
                    decoration: InputDecoration(
                      hintText: 'Text ${number.isEmpty ? 'the customer' : number}  (Ctrl+Enter to send)',
                      counterText: '',
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton.icon(
                onPressed: _sending ? null : send,
                icon: _sending
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.send_rounded, size: 18),
                label: const Text('Send'),
              ),
            ],
          ),
          actions: const [],
        );
      },
    );
  }

  String _jobLabel(Map<String, dynamic> a) {
    final id = a['job_id']?.toString();
    if (id == null || id.isEmpty) return 'No job';
    final j = widget.jobs.where((j) => '${j['job_id']}' == id).firstOrNull;
    return '${j?['is_estimate'] == true ? 'Estimate' : 'Job'} $id';
  }

  /// Which job or estimate does this call/text belong to? Lists the customer's jobs and "No job".
  Future<void> _pickJob(Map<String, dynamic> a) async {
    final current = a['job_id']?.toString();
    final picked = await showDialog<(String?, bool)>(
      context: context,
      builder: (ctx) => AppDialog(
        title: 'Which job is this about?',
        subtitle: 'The call or text shows on the job you pick. It stays on the customer either way.',
        icon: Icons.link_rounded,
        width: 520,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final j in widget.jobs)
              ListTile(
                dense: true,
                selected: '${j['job_id']}' == current,
                title: Text('${j['is_estimate'] == true ? 'Estimate' : 'Job'} ${j['job_id']}  ·  ${j['status'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text('${j['start_date'] ?? ''}  ${j['location'] ?? ''}'.trim(), maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () => Navigator.pop(ctx, ('${j['job_id']}', false)),
              ),
            if (widget.jobs.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('This customer has no jobs or estimates.')),
            ListTile(dense: true, title: const Text('No job'), onTap: () => Navigator.pop(ctx, ('auto', true))),
          ],
        ),
        actions: const [],
      ),
    );
    if (picked == null) return;
    await widget.onAssign('${a['quo_id']}', picked.$1);
  }

  Widget _bubble(Map<String, dynamic> a) {
    final out = a['direction'] == 'outgoing';
    final when = DateTime.tryParse('${a['occurred_at'] ?? ''}')?.toLocal();
    final stamp = when == null ? '' : DateFormat('MMM d, h:mm a').format(when);
    final isCall = a['kind'] == 'call';
    final summary = (a['ai_summary'] is Map ? (a['ai_summary']['summary'] as List?) : null)?.map((e) => '$e').join(' ');
    final nextSteps = (a['ai_summary'] is Map ? (a['ai_summary']['nextSteps'] as List?) : null)?.map((e) => '$e').toList() ?? const <String>[];
    final media = isCall ? const <(String, String)>[] : _mediaOf(a);
    final hasBody = '${a['body'] ?? ''}'.trim().isNotEmpty;
    final fg = out ? Colors.white : DashUi.ink;
    final sub = out ? Colors.white70 : DashUi.slate;
    final missed = _missed(a);
    // Red reads on the light incoming bubble only; an unanswered outgoing call keeps the white text on its dark bubble.
    final callColor = missed && !out ? DashUi.redText : fg;
    return Align(
      alignment: out ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 440),
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(color: out ? DashUi.ink : DashUi.line, borderRadius: BorderRadius.circular(14)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${a['sender'] ?? ''}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: sub)),
            const SizedBox(height: 3),
            if (isCall || hasBody || media.isEmpty)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isCall)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Icon(missed ? Icons.phone_missed_rounded : Icons.phone_rounded, size: 16, color: callColor),
                    ),
                  Flexible(
                    child: SelectableText(
                      isCall ? _summaryOf(a) : (hasBody ? '${a['body']}' : '(no text)'),
                      style: TextStyle(fontSize: 15, fontWeight: missed ? FontWeight.w800 : null, color: isCall ? callColor : (hasBody ? fg : sub)),
                    ),
                  ),
                ],
              ),
            for (final (url, type) in media)
              _LinkRow(
                icon: type.startsWith('image/') ? Icons.image_outlined : Icons.attach_file_rounded,
                label: type.startsWith('image/') ? 'Open picture' : 'Open attachment',
                color: fg,
                onTap: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
              ),
            if (summary != null && summary.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Summary', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: sub)),
              SelectableText(summary, style: TextStyle(fontSize: 14.5, height: 1.35, color: fg)),
            ],
            if (nextSteps.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Next steps', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: sub)),
              for (final n in nextSteps) SelectableText('•  $n', style: TextStyle(fontSize: 14.5, height: 1.35, color: fg)),
            ],
            if (isCall && a['has_transcript'] == true) _TranscriptToggle(quoId: '${a['quo_id']}', fg: fg, sub: sub),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(stamp, style: TextStyle(fontSize: 12.5, color: sub)),
                Tooltip(
                  message: 'Change which job this belongs to',
                  child: InkWell(
                    onTap: () => _pickJob(a),
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                      child: Text(
                        _jobLabel(a),
                        style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: sub, decoration: TextDecoration.underline, decorationColor: sub),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A small icon + underlined label link inside a bubble.
class _LinkRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _LinkRow({required this.icon, required this.label, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: color, decoration: TextDecoration.underline, decorationColor: color)),
        ]),
      ),
    );
  }
}

/// "Show transcript" under a call. The transcript is loaded from the server the first time it is opened, so the
/// conversation list never carries every call's full transcript.
class _TranscriptToggle extends StatefulWidget {
  final String quoId;
  final Color fg;
  final Color sub;
  const _TranscriptToggle({required this.quoId, required this.fg, required this.sub});

  @override
  State<_TranscriptToggle> createState() => _TranscriptToggleState();
}

class _TranscriptToggleState extends State<_TranscriptToggle> {
  bool _open = false;
  bool _loading = false;
  String? _error;
  List<Map<String, dynamic>>? _lines;

  Future<void> _toggle() async {
    setState(() => _open = !_open);
    if (_open && _lines == null && !_loading) await _fetch();
  }

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    String? problem;
    List<Map<String, dynamic>>? lines;
    try {
      final res = await http
          .get(Uri.parse('$kApiBaseUrl/api/quo/calls/${Uri.encodeComponent(widget.quoId)}/transcript'), headers: AuthSession.instance.headers())
          .timeout(const Duration(seconds: 30));
      if (res.statusCode == 401) {
        AuthSession.instance.logout();
        return;
      }
      if (res.statusCode == 200) {
        lines = List<Map<String, dynamic>>.from(((json.decode(res.body) as Map)['lines'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));
      } else {
        problem = _errorOf(res) ?? 'Could not load the transcript (${res.statusCode}).';
      }
    } on TimeoutException {
      problem = 'The server took too long to respond.';
    } catch (_) {
      problem = 'Could not reach the server.';
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _lines = lines;
      _error = problem;
    });
  }

  @override
  Widget build(BuildContext context) {
    final lines = _lines;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 6),
        InkWell(
          onTap: _toggle,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(_open ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 20, color: widget.fg),
              const SizedBox(width: 4),
              Text(_open ? 'Hide transcript' : 'Show transcript', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: widget.fg)),
            ]),
          ),
        ),
        if (_open && _loading)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: widget.fg)),
          ),
        if (_open && _error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Flexible(child: Text(_error!, style: TextStyle(fontSize: 14, color: widget.sub))),
              TextButton(onPressed: _fetch, child: Text('Try again', style: TextStyle(color: widget.fg))),
            ]),
          ),
        if (_open && lines != null && lines.isEmpty)
          Padding(padding: const EdgeInsets.only(top: 6), child: Text('This call has no transcript.', style: TextStyle(fontSize: 14, color: widget.sub))),
        // Headed and ruled down the left so the word-for-word transcript never reads as part of the summary above it.
        if (_open && lines != null && lines.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.only(left: 10),
            decoration: BoxDecoration(border: Border(left: BorderSide(color: widget.sub, width: 2))),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Transcript', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: widget.sub)),
                for (final t in lines)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: SelectableText.rich(TextSpan(children: [
                      TextSpan(text: '${t['speaker'] ?? ''}:  ', style: TextStyle(fontWeight: FontWeight.w800, color: widget.sub)),
                      TextSpan(text: '${t['content'] ?? ''}', style: TextStyle(color: widget.fg)),
                    ]), style: const TextStyle(fontSize: 14.5, height: 1.35)),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
