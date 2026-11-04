import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
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

  Future<void> _assign(String quoId, String? jobId) => _assignMany([quoId], jobId);

  /// Moves calls/texts to [jobId] (a job id), or null for "deliberately no job" (which also stops the automatic match);
  /// 'auto' deletes the link, so the automatic match applies again.
  Future<bool> _assignMany(List<String> quoIds, String? jobId) async {
    String? problem;
    try {
      final res = await http
          .put(
            Uri.parse('$kApiBaseUrl/api/quo/links'),
            headers: {...AuthSession.instance.headers(), 'Content-Type': 'application/json'},
            body: json.encode({'quoIds': quoIds, 'jobId': jobId}),
          )
          .timeout(const Duration(seconds: 30));
      if (res.statusCode == 401) {
        AuthSession.instance.logout();
        return false;
      }
      if (res.statusCode != 200) problem = _errorOf(res) ?? 'Could not save that change (${res.statusCode}).';
    } on TimeoutException {
      problem = 'The server took too long to respond.';
    } catch (_) {
      problem = 'Could not reach the server.';
    }
    if (!mounted) return false;
    if (problem != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(problem)));
      return false;
    }
    await _load(quiet: true); // in job mode the message leaves this list when it moves elsewhere
    return true;
  }

  /// "Attach to a job or estimate" on a conversation: every call and text in it goes to the one chosen.
  Future<void> _attachThread(List<Map<String, dynamic>> msgs) async {
    final current = {for (final m in msgs) if (m['job_id'] != null) '${m['job_id']}'};
    final picked = await _showJobPicker(
      context,
      _jobs,
      current: current.length == 1 ? current.first : null,
      allowNone: false,
      subtitle: 'The whole conversation shows on the job or estimate you pick. It stays on the customer either way.',
    );
    final jobId = picked?.$1;
    if (jobId == null || !mounted) return;
    final ids = [for (final m in msgs) '${m['quo_id']}'];
    if (!await _assignMany(ids, jobId) || !mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Attached ${ids.length == 1 ? '1 call or text' : '${ids.length} calls and texts'} to ${_labelFor(_jobs, jobId)}.')));
  }

  /// "Delete conversation": removes its calls and texts from IOHD Office for good (Quo keeps its own copy).
  Future<void> _deleteThread(List<Map<String, dynamic>> msgs) async {
    final ids = [for (final m in msgs) '${m['quo_id']}'];
    final n = ids.length;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppDialog(
        title: 'Delete this conversation?',
        icon: Icons.delete_outline_rounded,
        iconColor: const Color(0xFFB91C1C),
        body: Text(
          '${n == 1 ? '1 call or text' : '$n calls and texts'} will be removed from IOHD Office: from this customer, from any job or estimate, and from the reports. '
          'Quo keeps its own copy. This cannot be undone here.',
          style: const TextStyle(fontSize: 14, color: DashUi.slate, height: 1.4),
        ),
        actions: [
          AppButton.ghost('Cancel', () => Navigator.pop(ctx, false)),
          AppButton.ink('Delete', () => Navigator.pop(ctx, true), danger: true),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    String? problem;
    try {
      final res = await http
          .post(
            Uri.parse('$kApiBaseUrl/api/quo/activity/delete'),
            headers: {...AuthSession.instance.headers(), 'Content-Type': 'application/json'},
            body: json.encode({'quoIds': ids}),
          )
          .timeout(const Duration(seconds: 30));
      if (res.statusCode == 401) {
        AuthSession.instance.logout();
        return;
      }
      if (res.statusCode != 200) problem = _errorOf(res) ?? 'Could not delete that (${res.statusCode}).';
    } on TimeoutException {
      problem = 'The server took too long to respond.';
    } catch (_) {
      problem = 'Could not reach the server.';
    }
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
    if (problem != null) {
      messenger.showSnackBar(SnackBar(content: Text(problem)));
      return;
    }
    await _load(quiet: true);
    messenger.showSnackBar(SnackBar(content: Text('Deleted ${n == 1 ? '1 call or text' : '$n calls and texts'}.')));
  }

  /// "Remove from Job X" on a conversation: every call/text of it that is on that job stops belonging to it. Stored as
  /// "no job", so the automatic match does not put it back. Undo deletes those links, which restores what was there.
  Future<void> _unattach(List<Map<String, dynamic>> msgs, String jobId) async {
    final ids = [for (final m in msgs) if ('${m['job_id']}' == jobId) '${m['quo_id']}'];
    if (ids.isEmpty || !await _assignMany(ids, null) || !mounted) return;
    final label = _labelFor(_jobs, jobId);
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text('Removed ${ids.length == 1 ? '1 call or text' : '${ids.length} calls and texts'} from $label.'),
        action: SnackBarAction(label: 'Undo', onPressed: () => _assignMany(ids, 'auto')),
      ),
    );
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
      return const Padding(padding: EdgeInsets.fromLTRB(20, 16, 20, 16), child: SkeletonPulse(child: _ThreadSkeleton()));
    }
    // A job can still have linked calls when its customer has no number on file, so only say "no phone" when there are none.
    if (!_hasPhone && _items.value.isEmpty) {
      return _QuoEmpty(
        icon: Icons.phone_disabled_rounded,
        title: 'No phone number on file',
        message: widget.jobId != null
            ? "This job's customer has no phone number on file, so there is nothing to match to Quo."
            : 'This customer has no phone number on file, so there is nothing to match to Quo.',
      );
    }
    final threads = _threads();
    if (threads.isEmpty) {
      return _QuoEmpty(
        icon: Icons.forum_outlined,
        title: 'No calls or texts yet',
        message: widget.jobId != null
            ? "No calls or texts have been matched to this job yet, and none have been linked to it by hand. All of the customer's calls and texts are on their Communications tab, where you can attach a conversation to this job."
            : 'No calls or texts with ${_phone ?? 'this number'} yet. New ones appear here as they happen in Quo.',
      );
    }
    // Only name the number on each row when the conversations are with more than one number.
    final manyNumbers = threads.map((t) => t.$2.last['phone_key']).toSet().length > 1;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < threads.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 66, endIndent: 12, color: DashUi.line),
            _threadRow(threads[i].$1, threads[i].$2, showNumber: manyNumbers),
          ],
          if (_truncated)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
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
    // The jobs and estimates this conversation is on (usually one), for the "Remove from ..." menu.
    final attached = {for (final m in msgs) if (m['job_id'] != null && '${m['job_id']}'.isNotEmpty) '${m['job_id']}'}.toList();
    const titleStyle = TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: DashUi.ink);
    final lastIsCall = last['kind'] == 'call';
    return InkWell(
      onTap: () => _open(key),
      borderRadius: BorderRadius.circular(10),
      hoverColor: DashUi.faint,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
        child: Row(
          children: [
            // A missed call nobody has answered yet is visible here, without opening the conversation.
            if (missed > 0)
              Tooltip(
                message: missed == 1 ? 'Missed call, no reply yet' : '$missed missed calls, no reply yet',
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: DashUi.red,
                    shape: BoxShape.circle,
                    border: Border.all(color: DashUi.red.withValues(alpha: 0.25), width: 4, strokeAlign: BorderSide.strokeAlignOutside),
                  ),
                  child: const Icon(Icons.phone_missed_rounded, size: 18, color: Colors.white),
                ),
              )
            else
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: DashUi.blue.withValues(alpha: 0.1), shape: BoxShape.circle),
                child: Icon(lastIsCall ? Icons.call_outlined : Icons.sms_outlined, size: 19, color: DashUi.blue),
              ),
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
            Tooltip(
              message: when == null ? '' : DateFormat('EEE, MMM d, y h:mm a').format(when),
              child: Text(_when(when), style: const TextStyle(fontSize: 13, color: DashUi.subtle, fontFeatures: [FontFeature.tabularFigures()])),
            ),
            PopupMenuButton<String>(
              tooltip: 'More',
              icon: const Icon(Icons.more_vert_rounded, color: DashUi.slate),
              onSelected: (v) {
                if (v == 'attach') {
                  _attachThread(msgs);
                } else if (v == 'delete') {
                  _deleteThread(msgs);
                } else if (v.startsWith('remove:')) {
                  _unattach(msgs, v.substring(7));
                }
              },
              itemBuilder: (_) => [
                if (_jobs.isNotEmpty) PopupMenuItem(value: 'attach', child: Text(attached.isEmpty ? 'Attach to a job or estimate...' : 'Move to another job or estimate...')),
                for (final id in attached) PopupMenuItem(value: 'remove:$id', child: Text('Remove from ${_labelFor(_jobs, id)}')),
                const PopupMenuDivider(),
                const PopupMenuItem(value: 'delete', child: Text('Delete conversation', style: TextStyle(color: DashUi.redText))),
              ],
            ),
            const Icon(Icons.chevron_right_rounded, color: DashUi.slate),
          ],
        ),
      ),
    );
  }
}

/// The customer's jobs and estimates to choose from. Returns (jobId, _), with a null jobId for "No job"; null if dismissed.
Future<(String?, bool)?> _showJobPicker(BuildContext context, List<Map<String, dynamic>> jobs, {String? current, required bool allowNone, String? subtitle}) {
  return showDialog<(String?, bool)>(
    context: context,
    builder: (ctx) => AppDialog(
      title: 'Which job is this about?',
      subtitle: subtitle ?? 'The call or text shows on the job you pick. It stays on the customer either way.',
      icon: Icons.link_rounded,
      width: 520,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final j in jobs)
            ListTile(
              dense: true,
              selected: '${j['job_id']}' == current,
              title: Text('${j['is_estimate'] == true ? 'Estimate' : 'Job'} ${j['job_id']}  ·  ${j['status'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text('${j['start_date'] ?? ''}  ${j['location'] ?? ''}'.trim(), maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => Navigator.pop(ctx, ('${j['job_id']}', false)),
            ),
          if (jobs.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('This customer has no jobs or estimates.')),
          if (allowNone) ListTile(dense: true, title: const Text('No job'), onTap: () => Navigator.pop(ctx, (null, true))),
        ],
      ),
      actions: const [],
    ),
  );
}

/// "Job 123" or "Estimate 123" for a job id in the customer's list.
String _labelFor(List<Map<String, dynamic>> jobs, String id) {
  final j = jobs.where((j) => '${j['job_id']}' == id).firstOrNull;
  return '${j?['is_estimate'] == true ? 'Estimate' : 'Job'} $id';
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

        // The conversation, oldest first: a separator at each new day, and messages from the same person a few
        // minutes apart grouped under one name and avatar.
        final rows = <Widget>[];
        for (var i = 0; i < msgs.length; i++) {
          final a = msgs[i];
          final prev = i > 0 ? msgs[i - 1] : null;
          final next = i + 1 < msgs.length ? msgs[i + 1] : null;
          final when = _at(a);
          if (prev == null || !_sameDay(_at(prev), when)) rows.add(_DaySeparator(when));
          final startsGroup = prev == null || !_grouped(prev, a);
          final endsGroup = next == null || !_grouped(a, next);
          rows.add(
            _BubbleIn(
              key: ValueKey('bubble-${a['quo_id']}'),
              delay: (msgs.length - 1 - i).clamp(0, 8),
              child: _bubble(a, startsGroup: startsGroup, endsGroup: endsGroup),
            ),
          );
        }

        return AppDialog(
          title: title,
          subtitle: number.isEmpty ? null : number,
          icon: Icons.forum_outlined,
          width: 660,
          // Leaves room for the dialog's title, the text box and its padding so the dialog never scrolls the list itself.
          body: Container(
            height: (MediaQuery.sizeOf(context).height - 300).clamp(160.0, 540.0),
            decoration: BoxDecoration(
              color: DashUi.faint,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: DashUi.line),
            ),
            clipBehavior: Clip.antiAlias,
            child: ListView(
              controller: _scroll,
              // History is capped by the server, so build well past the view: the jump to the newest message lands
              // exactly, and scrolling back never waits on a bubble being laid out.
              scrollCacheExtent: const ScrollCacheExtent.pixels(4000),
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 14),
              children: rows,
            ),
          ),
          footer: _composer(number, send),
          actions: const [],
        );
      },
    );
  }

  /// The text box with Send inside it, and under it the shortcut and (while typing) how long the text is.
  Widget _composer(String number, VoidCallback send) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _text,
      builder: (context, value, _) {
        final len = value.text.trim().length;
        final parts = len == 0 ? 0 : (len / 160).ceil();
        final ready = len > 0 && !_sending;
        final still = MediaQuery.disableAnimationsOf(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: still ? Duration.zero : const Duration(milliseconds: 160),
              padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: ready ? DashUi.ink.withValues(alpha: 0.35) : DashUi.line, width: ready ? 1.5 : 1),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    // Enter starts a new line (texts are often several lines); Ctrl+Enter sends.
                    child: CallbackShortcuts(
                      bindings: {const SingleActivator(LogicalKeyboardKey.enter, control: true): send},
                      child: TextField(
                        controller: _text,
                        minLines: 1,
                        maxLines: 5,
                        maxLength: 1600,
                        enabled: !_sending,
                        style: const TextStyle(fontSize: 14.5, color: DashUi.ink, height: 1.4),
                        decoration: InputDecoration(
                          hintText: 'Text ${number.isEmpty ? 'the customer' : number}',
                          hintStyle: const TextStyle(color: DashUi.subtle),
                          counterText: '',
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          disabledBorder: InputBorder.none,
                          filled: false,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Tooltip(
                      message: 'Send (Ctrl+Enter)',
                      child: AnimatedScale(
                        duration: still ? Duration.zero : const Duration(milliseconds: 220),
                        curve: Curves.easeOutBack,
                        scale: ready || _sending ? 1 : 0.94,
                        child: FilledButton.icon(
                          onPressed: ready ? send : null,
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(0, 40),
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          icon: _sending
                              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.send_rounded, size: 18),
                          label: const Text('Send'),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
              child: Row(
                children: [
                  const Icon(Icons.keyboard_rounded, size: 14, color: DashUi.subtle),
                  const SizedBox(width: 6),
                  const Text('Ctrl+Enter to send, Enter for a new line', style: TextStyle(fontSize: 12, color: DashUi.subtle)),
                  const Spacer(),
                  if (len > 0)
                    Text(
                      '$len / 1600${parts > 1 ? '  ·  sends as $parts texts' : ''}',
                      style: TextStyle(
                        fontSize: 12,
                        color: len > 1500 ? DashUi.amberText : DashUi.subtle,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  static DateTime? _at(Map<String, dynamic> a) => DateTime.tryParse('${a['occurred_at'] ?? ''}')?.toLocal();

  static bool _sameDay(DateTime? a, DateTime? b) => a != null && b != null && a.year == b.year && a.month == b.month && a.day == b.day;

  /// Two texts in a row from the same person, a few minutes apart: shown as one group (calls always stand alone).
  static bool _grouped(Map<String, dynamic> a, Map<String, dynamic> b) {
    if (a['kind'] == 'call' || b['kind'] == 'call') return false;
    if (a['direction'] != b['direction'] || '${a['sender']}' != '${b['sender']}') return false;
    final x = _at(a), y = _at(b);
    return x != null && y != null && _sameDay(x, y) && y.difference(x).inMinutes.abs() <= 10;
  }

  String _jobLabel(Map<String, dynamic> a) {
    final id = a['job_id']?.toString();
    if (id == null || id.isEmpty) return 'No job';
    return _labelFor(widget.jobs, id);
  }

  /// Which job or estimate does this call/text belong to? Lists the customer's jobs and "No job".
  Future<void> _pickJob(Map<String, dynamic> a) async {
    final picked = await _showJobPicker(context, widget.jobs, current: a['job_id']?.toString(), allowNone: true);
    if (picked == null) return;
    await widget.onAssign('${a['quo_id']}', picked.$1);
  }

  /// Under each call or text: its time, the job it is on (a pill that moves it), and why it is there when the server
  /// worked that out itself.
  Widget _meta(Map<String, dynamic> a, {required bool dark}) {
    final when = _at(a);
    final sub = dark ? Colors.white.withValues(alpha: 0.72) : DashUi.subtle;
    final pillFg = dark ? Colors.white.withValues(alpha: 0.9) : DashUi.slate;
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          when == null ? '' : DateFormat('h:mm a').format(when),
          style: TextStyle(fontSize: 11.5, color: sub, fontFeatures: const [FontFeature.tabularFigures()]),
        ),
        Tooltip(
          message: 'Change which job this belongs to',
          child: Material(
            color: dark ? Colors.white.withValues(alpha: 0.12) : DashUi.faint,
            shape: StadiumBorder(side: BorderSide(color: dark ? Colors.white.withValues(alpha: 0.18) : DashUi.line)),
            child: InkWell(
              onTap: () => _pickJob(a),
              customBorder: const StadiumBorder(),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.link_rounded, size: 13, color: pillFg),
                    const SizedBox(width: 4),
                    Text(_jobLabel(a), style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: pillFg)),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_matchNote(a) case final note?)
          Tooltip(
            message: note,
            triggerMode: TooltipTriggerMode.tap, // hover on a computer, tap on a touch screen
            waitDuration: const Duration(milliseconds: 150),
            child: Padding(padding: const EdgeInsets.all(2), child: Icon(Icons.info_outline_rounded, size: 14, color: sub)),
          ),
      ],
    );
  }

  Widget _bubble(Map<String, dynamic> a, {required bool startsGroup, required bool endsGroup}) {
    final out = a['direction'] == 'outgoing';
    final sender = '${a['sender'] ?? ''}';
    final isCall = a['kind'] == 'call';
    // An avatar beside the first of a group (and the same room kept beside the rest, so they line up).
    final avatar = startsGroup ? _Initials(sender, ours: out) : const SizedBox(width: 30);
    final content = isCall ? _callCard(a, out: out) : _textBubble(a, out: out, startsGroup: startsGroup, endsGroup: endsGroup);
    return Padding(
      padding: EdgeInsets.only(top: startsGroup ? 12 : 3),
      child: Row(
        mainAxisAlignment: out ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!out) ...[avatar, const SizedBox(width: 8)],
          Flexible(
            child: Column(
              crossAxisAlignment: out ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (startsGroup && !isCall)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, right: 4, bottom: 4),
                    child: Text(sender, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: DashUi.slate)),
                  ),
                ConstrainedBox(constraints: const BoxConstraints(maxWidth: 460), child: content),
              ],
            ),
          ),
          if (out) ...[const SizedBox(width: 8), avatar],
        ],
      ),
    );
  }

  Widget _textBubble(Map<String, dynamic> a, {required bool out, required bool startsGroup, required bool endsGroup}) {
    final media = _mediaOf(a);
    final hasBody = '${a['body'] ?? ''}'.trim().isNotEmpty;
    final fg = out ? Colors.white : DashUi.ink;
    final sub = out ? Colors.white.withValues(alpha: 0.72) : DashUi.slate;
    // The corner next to the sender is tucked in at the start of a group, rounded again inside it.
    const big = Radius.circular(16), small = Radius.circular(5);
    final radius = BorderRadius.only(
      topLeft: !out && startsGroup ? small : big,
      topRight: out && startsGroup ? small : big,
      bottomLeft: !out && !endsGroup ? small : big,
      bottomRight: out && !endsGroup ? small : big,
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
      decoration: BoxDecoration(
        gradient: out
            ? LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [DashUi.ink, Color.lerp(DashUi.ink, DashUi.blue, 0.38)!])
            : null,
        color: out ? null : Colors.white,
        borderRadius: radius,
        border: out ? null : Border.all(color: DashUi.line),
        boxShadow: [BoxShadow(color: DashUi.ink.withValues(alpha: out ? 0.12 : 0.04), blurRadius: 6, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasBody || media.isEmpty)
            SelectableText(
              hasBody ? '${a['body']}' : '(no text)',
              style: TextStyle(fontSize: 14.5, height: 1.4, color: hasBody ? fg : sub, fontStyle: hasBody ? null : FontStyle.italic),
            ),
          for (final (url, type) in media) ...[
            if (type.startsWith('image/'))
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: _MediaThumb(url: url, onTap: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)),
              ),
            _LinkRow(
              icon: type.startsWith('image/') ? Icons.open_in_new_rounded : Icons.attach_file_rounded,
              label: type.startsWith('image/') ? 'Open picture' : 'Open attachment',
              color: out ? Colors.white : DashUi.blue,
              onTap: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
            ),
          ],
          const SizedBox(height: 6),
          _meta(a, dark: out),
        ],
      ),
    );
  }

  /// A call stands out from the texts: a card with a round icon (green when answered, red when missed), who it was,
  /// its AI summary and next steps when Quo has them, and the transcript behind a button.
  Widget _callCard(Map<String, dynamic> a, {required bool out}) {
    final missed = _missed(a);
    final summary = (a['ai_summary'] is Map ? (a['ai_summary']['summary'] as List?) : null)?.map((e) => '$e').join(' ');
    final nextSteps = (a['ai_summary'] is Map ? (a['ai_summary']['nextSteps'] as List?) : null)?.map((e) => '$e').toList() ?? const <String>[];
    final tone = missed ? DashUi.red : DashUi.emerald;
    final icon = missed ? Icons.phone_missed_rounded : (out ? Icons.call_made_rounded : Icons.call_received_rounded);
    Widget heading(IconData i, String text, Color c) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(i, size: 15, color: c),
        const SizedBox(width: 6),
        Text(text, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: DashUi.slate)),
      ],
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 14, 10),
      decoration: BoxDecoration(
        color: missed ? Color.alphaBlend(DashUi.red.withValues(alpha: 0.05), Colors.white) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: missed ? DashUi.red.withValues(alpha: 0.35) : DashUi.line),
        boxShadow: [BoxShadow(color: DashUi.ink.withValues(alpha: 0.04), blurRadius: 6, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(color: missed ? DashUi.red : tone.withValues(alpha: 0.14), shape: BoxShape.circle),
                child: Icon(icon, size: 17, color: missed ? Colors.white : DashUi.emeraldText),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SelectableText(
                      _summaryOf(a),
                      style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: missed ? DashUi.redText : DashUi.ink),
                    ),
                    Text('${a['sender'] ?? ''}', style: const TextStyle(fontSize: 12.5, color: DashUi.slate)),
                  ],
                ),
              ),
            ],
          ),
          if ((summary != null && summary.isNotEmpty) || nextSteps.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: 10),
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: BoxDecoration(
                color: DashUi.indigo.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: DashUi.indigo.withValues(alpha: 0.14)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (summary != null && summary.isNotEmpty) ...[
                    heading(Icons.auto_awesome_rounded, 'Summary', DashUi.indigo),
                    const SizedBox(height: 4),
                    SelectableText(summary, style: const TextStyle(fontSize: 14, height: 1.4, color: DashUi.ink)),
                  ],
                  if (nextSteps.isNotEmpty) ...[
                    if (summary != null && summary.isNotEmpty) const SizedBox(height: 10),
                    heading(Icons.checklist_rounded, 'Next steps', DashUi.indigo),
                    for (final n in nextSteps)
                      Padding(
                        padding: const EdgeInsets.only(top: 5),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Padding(
                              padding: EdgeInsets.only(top: 2),
                              child: Icon(Icons.check_circle_outline_rounded, size: 15, color: DashUi.emeraldText),
                            ),
                            const SizedBox(width: 6),
                            Flexible(child: SelectableText(n, style: const TextStyle(fontSize: 14, height: 1.35, color: DashUi.ink))),
                          ],
                        ),
                      ),
                  ],
                ],
              ),
            ),
          if (a['has_transcript'] == true) _TranscriptToggle(quoId: '${a['quo_id']}', fg: DashUi.ink, sub: DashUi.slate),
          const SizedBox(height: 8),
          _meta(a, dark: false),
        ],
      ),
    );
  }

  /// Why the server put this call/text on a job, when it worked that out itself (a person's own choice needs no note).
  String? _matchNote(Map<String, dynamic> a) => switch (a['match']) {
    'address' => 'Matched by address',
    'visit_day' => 'A technician worked this job that day',
    'same_day' => 'Same day it was created',
    'thread' => 'Same conversation as the job',
    'lead_in' => 'Before it was created, same customer',
    'recent' => 'After it was created, same customer',
    'recent_guess' => 'Newest job at the time',
    'only_job' => 'The only job or estimate this customer had',
    _ => null,
  };
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
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: color)),
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
    // Each speaker keeps one colour down the transcript, in the order they first speak.
    const tones = [DashUi.blue, DashUi.emeraldText, DashUi.amberText, DashUi.slate];
    final speakers = <String>[];
    for (final t in lines ?? const <Map<String, dynamic>>[]) {
      final who = '${t['speaker'] ?? ''}';
      if (!speakers.contains(who)) speakers.add(who);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 10),
        Material(
          color: _open ? DashUi.faint : Colors.white,
          shape: const StadiumBorder(side: BorderSide(color: DashUi.line)),
          child: InkWell(
            onTap: _toggle,
            customBorder: const StadiumBorder(),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 5, 12, 5),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(_open ? Icons.expand_less_rounded : Icons.notes_rounded, size: 16, color: widget.fg),
                const SizedBox(width: 6),
                Text(_open ? 'Hide transcript' : 'Show transcript', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: widget.fg)),
              ]),
            ),
          ),
        ),
        if (_open && _loading)
          Padding(
            padding: const EdgeInsets.only(top: 10),
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
            margin: const EdgeInsets.only(top: 10),
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              color: DashUi.faint,
              borderRadius: BorderRadius.circular(10),
              border: const Border(left: BorderSide(color: DashUi.line, width: 3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Transcript', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: widget.sub)),
                for (final t in lines)
                  Padding(
                    padding: const EdgeInsets.only(top: 7),
                    child: SelectableText.rich(
                      TextSpan(children: [
                        TextSpan(
                          text: '${t['speaker'] ?? ''}:  ',
                          style: TextStyle(fontWeight: FontWeight.w800, color: tones[speakers.indexOf('${t['speaker'] ?? ''}') % tones.length]),
                        ),
                        TextSpan(text: '${t['content'] ?? ''}', style: TextStyle(color: widget.fg)),
                      ]),
                      style: const TextStyle(fontSize: 14, height: 1.4),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// A conversation's last activity, short: the time today, "Yesterday", the day this year, the full date before that.
String _when(DateTime? t) {
  if (t == null) return '';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  if (day == today) return DateFormat('h:mm a').format(t);
  if (day == today.subtract(const Duration(days: 1))) return 'Yesterday';
  return t.year == now.year ? DateFormat('MMM d').format(t) : DateFormat('MMM d, y').format(t);
}

/// No conversations to show: the icon in a tinted circle, what is missing and why.
class _QuoEmpty extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  const _QuoEmpty({required this.icon, required this.title, required this.message});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
    child: Column(
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: DashUi.blue.withValues(alpha: 0.1),
            border: Border.all(color: DashUi.blue.withValues(alpha: 0.18), width: 6),
          ),
          child: Icon(icon, size: 26, color: DashUi.blue),
        ),
        const SizedBox(height: 16),
        Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: DashUi.ink)),
        const SizedBox(height: 6),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Text(message, textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, color: DashUi.slate, height: 1.45)),
        ),
      ],
    ),
  );
}

/// Three conversation-shaped placeholders while the list loads.
class _ThreadSkeleton extends StatelessWidget {
  const _ThreadSkeleton();

  @override
  Widget build(BuildContext context) {
    Widget bar(double w, double h) => Container(
      width: w,
      height: h,
      decoration: BoxDecoration(color: DashUi.line, borderRadius: BorderRadius.circular(6)),
    );
    return Column(
      children: [
        for (var i = 0; i < 3; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                Container(width: 40, height: 40, decoration: const BoxDecoration(color: DashUi.line, shape: BoxShape.circle)),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [bar(180, 12), const SizedBox(height: 8), bar(double.infinity, 10)],
                  ),
                ),
                const SizedBox(width: 24),
                bar(48, 10),
              ],
            ),
          ),
      ],
    );
  }
}

/// "Today", "Yesterday" or the date, on a pill between hairlines, where a new day starts in a conversation.
class _DaySeparator extends StatelessWidget {
  final DateTime? day;
  const _DaySeparator(this.day);

  @override
  Widget build(BuildContext context) {
    final d = day;
    String label = '';
    if (d != null) {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final that = DateTime(d.year, d.month, d.day);
      label = that == today
          ? 'Today'
          : that == today.subtract(const Duration(days: 1))
          ? 'Yesterday'
          : DateFormat(d.year == now.year ? 'EEEE, MMM d' : 'EEEE, MMM d, y').format(d);
    }
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 2),
      child: Row(
        children: [
          const Expanded(child: Divider(height: 1, color: DashUi.line)),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 10),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(999), border: Border.all(color: DashUi.line)),
            child: Text(label, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: DashUi.slate)),
          ),
          const Expanded(child: Divider(height: 1, color: DashUi.line)),
        ],
      ),
    );
  }
}

/// Rises and fades in the first time it is shown: the newest messages first when the popup opens ([delay] counts back
/// from the newest), and a message just sent slides in straight away.
class _BubbleIn extends StatelessWidget {
  final int delay;
  final Widget child;
  const _BubbleIn({super.key, required this.delay, required this.child});

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    final wait = 30 * delay;
    final total = 280 + wait;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: total),
      curve: Interval(wait / total, 1, curve: Curves.easeOutCubic),
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, (1 - t) * 10), child: child),
      ),
    );
  }
}

/// Someone's initials in a small circle: blue for the customer, ink for us.
class _Initials extends StatelessWidget {
  final String name;
  final bool ours;
  const _Initials(this.name, {required this.ours});

  @override
  Widget build(BuildContext context) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    final text = parts.isEmpty ? '?' : (parts.length == 1 ? parts.first[0] : '${parts.first[0]}${parts.last[0]}').toUpperCase();
    return Tooltip(
      message: name,
      child: Container(
        width: 30,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: ours ? DashUi.ink : DashUi.blue.withValues(alpha: 0.12),
          border: Border.all(color: ours ? DashUi.ink : DashUi.blue.withValues(alpha: 0.25)),
        ),
        child: Text(text, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: ours ? Colors.white : DashUi.blue)),
      ),
    );
  }
}

/// A picture sent by text, as a thumbnail that opens it; if it can't be shown, a quiet placeholder.
class _MediaThumb extends StatelessWidget {
  final String url;
  final VoidCallback onTap;
  const _MediaThumb({required this.url, required this.onTap});

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    child: GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 240,
          height: 170,
          child: Image.network(
            url,
            fit: BoxFit.cover,
            webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
            loadingBuilder: (_, child, p) => p == null ? child : const ColoredBox(color: DashUi.faint),
            errorBuilder: (_, _, _) => Container(
              color: DashUi.faint,
              alignment: Alignment.center,
              child: const Icon(Icons.image_outlined, size: 32, color: DashUi.subtle),
            ),
          ),
        ),
      ),
    ),
  );
}
