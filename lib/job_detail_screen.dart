import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData, FilteringTextInputFormatter;
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import 'config/api_config.dart';
import 'config/auth_session.dart';
import 'theme/app_theme.dart';
import 'utils/job_statuses.dart';
import 'utils/status_colors.dart';
import 'widgets/quo_activity_panel.dart';
import 'widgets/dashboard_kit.dart' show SkeletonPulse;
import 'widgets/file_viewer.dart';

/// The `/jobs/:id` route (a child of `/jobs`). Keyed by the job number: the Jobs section keeps its page alive, and
/// without a key a different job would reuse the old page's state and keep showing the previous job.
GoRoute jobDetailRoute() => GoRoute(
  path: ':id',
  builder: (context, state) {
    final id = state.pathParameters['id'] ?? '';
    return JobDetailScreen(key: ValueKey('job-$id'), jobId: id, initial: state.extra is Map ? Map<String, dynamic>.from(state.extra as Map) : null);
  },
);

/// Full-page view of one job (or estimate). Opened from the Jobs list and the Calendar at `/job/:id`.
/// Laid out like the Service Fusion job page: a Details panel and a Job Info panel side by side.
/// [initial] is the row the caller already had, shown right away while the full record loads.
class JobDetailScreen extends StatefulWidget {
  final String jobId;
  final Map<String, dynamic>? initial;
  const JobDetailScreen({super.key, required this.jobId, this.initial});

  @override
  State<JobDetailScreen> createState() => _JobDetailScreenState();
}

class _JobDetailScreenState extends State<JobDetailScreen> {
  static const _link = Color(0xFF2563EB);
  static const _headerBar = Color(0xFFF3F4F6);
  static const double _maxTaskWidth = 520; // Task List panel
  static const double _maxNotesWidth = 640; // Notes panel
  static const double _maxPageWidth = 1600; // same cap as the dashboards (_DashTokens.maxContentWidth) and Payroll

  Map<String, dynamic>? _job;
  Map<String, dynamic>? _customer;
  String? _fromEstimate; // for a job: the estimate it most likely came from
  String? _becameJob; // for an estimate: the job it most likely became
  List<Map<String, dynamic>> _payments = const [];
  List<Map<String, dynamic>> _stripePayments = const []; // shown, but not counted in any total yet
  List<Map<String, dynamic>> _history = const [];
  List<Map<String, dynamic>> _ourFiles = const []; // pictures + documents uploaded here (not Service Fusion's)
  bool _filesEnabled = true; // false when the backend says file storage isn't set up
  String? _uploadStatus; // "Uploading 2 of 3..." while an upload runs
  List<Map<String, dynamic>> _ourNotes = const []; // notes added in this app (author known)
  List<Map<String, dynamic>> _ourTasks = const []; // tasks added in this app
  bool _loading = true;
  bool _visitsExpanded = false; // Site Visits shows only the latest few until this is on
  bool _notesExpanded = false; // the Notes section shows only the newest few until this is on
  String? _error;
  int _detailsTab = 0; // Summary, Pics, Docs, Takeoffs
  int _infoTab = 0; // Scheduling, Payment, Communications, Activity

  final _money = NumberFormat.currency(symbol: r'$');

  @override
  void initState() {
    super.initState();
    _job = widget.initial;
    _load();
  }

  @override
  void didUpdateWidget(JobDetailScreen old) {
    super.didUpdateWidget(old);
    if (old.jobId != widget.jobId) {
      _job = widget.initial;
      _customer = null;
      _fromEstimate = null;
      _becameJob = null;
      _payments = const [];
      _stripePayments = const [];
      _history = const [];
      _ourFiles = const [];
      _ourNotes = const [];
      _ourTasks = const [];
      _detailsTab = 0;
      _infoTab = 0;
      _notesExpanded = false;
      _visitsExpanded = false;
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    // Our files and notes only need the job number, so ask for them now instead of after the job comes back.
    unawaited(_loadFiles());
    unawaited(_loadNotesTasks());
    unawaited(QuoActivityPanel.prefetch(jobId: widget.jobId)); // so the Communications tab opens with its calls and texts
    try {
      final res = await http
          .get(Uri.parse('$kApiBaseUrl/api/jobs/${Uri.encodeComponent(widget.jobId)}'), headers: AuthSession.instance.headers(json: false))
          .timeout(const Duration(seconds: 40));
      if (!mounted) return;
      if (res.statusCode == 401) {
        AuthSession.instance.logout(); // sends the app back to the sign-in screen
        return;
      }
      if (res.statusCode == 404) {
        setState(() {
          _loading = false;
          _error = 'Job #${widget.jobId} was not found.';
        });
        return;
      }
      if (res.statusCode != 200) {
        setState(() {
          _loading = false;
          _error = 'Server error (${res.statusCode}).';
        });
        return;
      }
      final data = json.decode(res.body) as Map<String, dynamic>;
      List<Map<String, dynamic>> rows(String k) => List<Map<String, dynamic>>.from(data[k] ?? const []);
      setState(() {
        _job = Map<String, dynamic>.from(data['job'] as Map);
        _customer = data['customer'] is Map ? Map<String, dynamic>.from(data['customer'] as Map) : null;
        _fromEstimate = data['fromEstimate']?.toString();
        _becameJob = data['becameJob']?.toString();
        _payments = rows('payments');
        _stripePayments = rows('stripePayments');
        _history = rows('history');
        _loading = false;
      });
      _showInRightSection();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not reach the server.';
      });
    }
  }

  /// Opens another record's page: an estimate under /estimates, a job under /jobs (so the right nav item stays lit).
  void _openRecord(String id, {required bool estimate}) => context.go('/${estimate ? 'estimates' : 'jobs'}/${Uri.encodeComponent(id)}');

  /// Links and lists can't always know whether a number is a job or an estimate (the calendar, dashboard lists). Once the
  /// record is loaded we know, so if the address is in the wrong section, move it to the right one (same page, no flash).
  void _showInRightSection() {
    final router = GoRouter.maybeOf(context);
    if (router == null || _job == null) return;
    final path = router.routerDelegate.currentConfiguration.uri.path;
    final wrongSection = (_isEstimate && path.startsWith('/jobs/')) || (!_isEstimate && path.startsWith('/estimates/'));
    if (wrongSection) router.go('/${_isEstimate ? 'estimates' : 'jobs'}/${Uri.encodeComponent(widget.jobId)}', extra: _job);
  }

  // ---- helpers --------------------------------------------------------------

  String _s(String key) => (_job?[key] ?? '').toString().trim();

  double _n(dynamic v) => double.tryParse(v?.toString() ?? '') ?? 0;

  String _date(dynamic v) {
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(v?.toString() ?? '');
    if (m == null) return '';
    return DateFormat('MM/dd/yyyy').format(DateTime(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!)));
  }

  String _dateTime(dynamic v) {
    final d = DateTime.tryParse(v?.toString() ?? '');
    return d == null ? '' : DateFormat('MMM d, y h:mm a').format(d.toLocal());
  }

  bool get _isEstimate => _job?['is_estimate'] == true;

  /// The record on the other side of the job/estimate pair, when we found one.
  String? get _matchId {
    final id = _isEstimate ? _becameJob : _fromEstimate;
    return (id == null || id.isEmpty) ? null : id;
  }

  // ---- build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final job = _job;
    return Scaffold(backgroundColor: AppTheme.bgColor, body: job == null ? _bodyWithoutJob() : _content(job));
  }

  Widget _bodyWithoutJob() {
    if (_loading) return _skeletonPage();
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline_rounded, size: 40, color: AppTheme.sectionLabel),
          const SizedBox(height: 10),
          Text(_error ?? 'Something went wrong.', style: const TextStyle(color: AppTheme.secondaryText)),
          const SizedBox(height: 14),
          OutlinedButton.icon(onPressed: _load, icon: const Icon(Icons.refresh_rounded), label: const Text('Retry')),
        ],
      ),
    );
  }

  Widget _content(Map<String, dynamic> job) {
    final status = _s('status').isEmpty ? 'No status' : _s('status');
    final subStatus = _s('sub_status');
    final notes = _s('notes');
    final lineItems = (job['raw_items'] is List)
        ? List<Map<String, dynamic>>.from((job['raw_items'] as List).whereType<Map>().map(Map<String, dynamic>.from))
        : <Map<String, dynamic>>[];

    final contact = _s('contact_name');
    final cust = _customer;
    final custPhone = (cust?['phone'] ?? '').toString().trim();
    final custEmail = (cust?['email'] ?? '').toString().trim();
    final custContact = (cust?['primary_contact'] ?? '').toString().trim();
    // The phone and email belong to the customer's primary contact, so only attach them when that is this job's contact.
    final sameContact = contact.isEmpty || custContact.toLowerCase() == contact.toLowerCase();

    final summaryRows = <Widget>[
      _sfRow(
        Icons.business_rounded,
        'Customer',
        _s('customer_name').isEmpty ? null : _linkText(_s('customer_name'), _openCustomer, tip: 'Find this customer'),
      ),
      _sfRow(
        Icons.person_outline_rounded,
        'Primary Contact',
        (contact.isEmpty && custContact.isEmpty)
            ? null
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _text(contact.isEmpty ? custContact : contact),
                  if (sameContact && custPhone.isNotEmpty) _linkText(custPhone, () => _launch(_telUri(custPhone)), tip: 'Call'),
                  if (sameContact && custEmail.isNotEmpty)
                    _linkText(
                      custEmail,
                      () => _launch(Uri(scheme: 'mailto', path: custEmail)),
                      tip: 'Send an email',
                    ),
                  if (!sameContact && custContact.isNotEmpty)
                    _text('Customer main contact: $custContact${custPhone.isEmpty ? '' : '  ·  $custPhone'}', muted: true),
                ],
              ),
      ),
      _sfRow(
        Icons.home_rounded,
        'Service Location',
        _s('location').isEmpty ? null : _linkText(_s('location'), () => _launch(_mapsUri(_s('location'))), tip: 'Open in Google Maps'),
      ),
      _sfRow(Icons.assignment_outlined, 'Job Description', _s('description').isEmpty ? null : _text(_s('description'))),
      _sfRow(Icons.edit_note_rounded, 'PO #', _s('po_number').isEmpty ? null : _text(_s('po_number'))),
      _sfRow(Icons.folder_open_rounded, 'Job Category', _s('category').isEmpty ? null : _text(_s('category'))),
      if (_s('opportunity_owner').isNotEmpty) _sfRow(Icons.badge_outlined, 'Sales Owner', _text(_s('opportunity_owner'))),
    ];
    final detailsPanel = _panel(
      'Details',
      switch (_detailsTab) {
        1 => _picsRows(),
        2 => _docsRows(),
        3 => [_emptyTab(Icons.straighten_rounded, 'No takeoffs yet', 'Takeoffs for this job will show here once they are built.')],
        4 => [QuoActivityPanel(key: ValueKey('quo-job-${widget.jobId}'), jobId: widget.jobId)],
        _ => summaryRows,
      },
      tabs: [
        ('Summary', Icons.format_list_bulleted_rounded),
        (_countLabel('Pics', _files('pictures'), _ourFiles.where((f) => f['kind'] == 'pic').length), Icons.photo_camera_outlined),
        (_countLabel('Docs', _files('documents'), _ourFiles.where((f) => f['kind'] == 'doc').length), Icons.description_outlined),
        ('Takeoffs', Icons.straighten_rounded),
        ('Communications', Icons.forum_outlined),
      ],
      selected: _detailsTab,
      onTab: (i) => setState(() => _detailsTab = i),
    );

    final start = _date(job['start_date']);
    final end = _date(job['end_date']);
    final dates = start.isEmpty ? '' : (end.isEmpty || end == start ? start : '$start - $end');
    final techs = _s('techs_assigned');
    final window = _window(_sf['time_frame_promised_start'], _sf['time_frame_promised_end']);
    final duration = _duration(_sf['duration']);
    final priority = (_sf['priority'] ?? '').toString().trim();
    final requested = _date(job['sf_created_at']);
    final referral = (_sf['source'] ?? '').toString().trim();
    final rating = (_sf['opportunity_rating'] ?? '').toString().trim();
    // Estimates mirror Service Fusion's "Sales Data" block; jobs keep the scheduling block.
    final salesRows = <Widget>[
      _sfRow(Icons.calendar_today_rounded, 'Requested On', requested.isEmpty ? null : _text(requested)),
      _sfRow(
        Icons.emoji_events_outlined,
        'Current Status',
        Wrap(
          spacing: 10,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [_statusPicker(status, sub: false), _statusPicker(subStatus, sub: true)],
        ),
      ),
      _sfRow(Icons.signpost_outlined, 'Referral Source', referral.isEmpty ? null : _text(referral)),
      _sfRow(Icons.star_rounded, 'Opportunity Rating', rating.isEmpty ? null : _text(rating)),
      _sfRow(Icons.hail_rounded, 'Opportunity Owner', _s('opportunity_owner').isEmpty ? null : _text(_s('opportunity_owner'))),
      _sfRow(
        Icons.event_rounded,
        'On-Site Visit',
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            start.isEmpty ? _text('Not Set', muted: true) : _text(start),
            const SizedBox(height: 6),
            window.isEmpty ? _text('Not Set', muted: true) : _text(window),
            const SizedBox(height: 6),
            duration.isEmpty ? _text('Not Set', muted: true) : _text(duration),
          ],
        ),
      ),
      _sfRow(Icons.engineering_outlined, 'Assigned Techs', _techsValue(techs)),
      _sfRow(Icons.sticky_note_2_outlined, 'Notes For Techs', notes.isEmpty ? null : _text(notes)),
    ];
    final schedulingRows = <Widget>[
      _sfRow(
        Icons.flag_outlined,
        'Current Status',
        Wrap(
          spacing: 10,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [_statusPicker(status, sub: false), _statusPicker(subStatus, sub: true)],
        ),
      ),
      _sfRow(Icons.event_rounded, _isEstimate ? 'Estimate Date' : 'Start & End Dates', start.isEmpty ? null : _text(_isEstimate ? start : dates)),
      if (!_isEstimate && _date(job['closed_at']).isNotEmpty) _sfRow(Icons.event_available_rounded, 'Closed', _text(_date(job['closed_at']))),
      _sfRow(Icons.schedule_rounded, 'Arrival Time Window', window.isEmpty ? null : _text(window)),
      _sfRow(Icons.timelapse_rounded, 'Estimated Duration', duration.isEmpty ? null : _text(duration)),
      _sfRow(Icons.priority_high_rounded, 'Job Priority', priority.isEmpty ? null : _text(priority)),
      _sfRow(Icons.engineering_outlined, 'Assigned Techs', _techsValue(techs)),
      _sfRow(Icons.sticky_note_2_outlined, 'Notes For Techs', notes.isEmpty ? null : _text(notes)),
      // An estimate has no visits to show: don't draw an empty "Site Visits (0)" box on it.
      if (!(_isEstimate && _sfVisits.isEmpty)) _visitsSection(),
    ];
    final infoPanel = _panel(
      _isEstimate ? 'Estimate Info' : 'Job Info',
      switch (_infoTab) {
        1 => _paymentRows(job),
        2 => _activityRows(),
        _ => _isEstimate ? salesRows : schedulingRows,
      },
      tabs: [
        (_isEstimate ? 'Sales Data' : 'Scheduling', Icons.calendar_month_rounded),
        ('Payment', Icons.payments_outlined),
        ('Activity', Icons.view_headline_rounded),
      ],
      selected: _infoTab,
      onTab: (i) => setState(() => _infoTab = i),
    );

    // Same sizing as the dashboards and Payroll: content capped at 1600 px, side padding 12 / 16 / 24 by window width.
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final pad = w < 600 ? 12.0 : (w < 1000 ? 16.0 : 24.0);
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _maxPageWidth),
            child: ListView(
              padding: EdgeInsets.fromLTRB(pad, (pad * 0.6).roundToDouble() + 4, pad, 24),
              children: [
                if (_loading) const Padding(padding: EdgeInsets.only(bottom: 12), child: LinearProgressIndicator(minHeight: 2)),
                if (_error != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.notesBg,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppTheme.notesStroke),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text('$_error Showing what we already have.', style: const TextStyle(color: AppTheme.notesText)),
                        ),
                        TextButton(onPressed: _load, child: const Text('Retry')),
                      ],
                    ),
                  ),
                // Header, like Service Fusion: "Job # 123 (Matching estimate #456)".
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Wrap(
                        crossAxisAlignment: WrapCrossAlignment.end,
                        spacing: 10,
                        children: [
                          SelectableText(
                            _isEstimate ? 'Estimate # ${widget.jobId}' : 'Job # ${widget.jobId}',
                            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: AppTheme.primaryText),
                          ),
                          if (_matchId != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _isEstimate ? '(Became job ' : '(Matching estimate ',
                                    style: const TextStyle(fontSize: 14, color: AppTheme.secondaryText),
                                  ),
                                  InkWell(
                                    onTap: () => _openRecord(_matchId!, estimate: !_isEstimate),
                                    child: Text(
                                      '#$_matchId',
                                      style: const TextStyle(fontSize: 14, color: _link, fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                  const Text(')', style: TextStyle(fontSize: 14, color: AppTheme.secondaryText)),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                    IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh_rounded), onPressed: _loading ? null : _load),
                  ],
                ),
                const SizedBox(height: 16),
                LayoutBuilder(
                  builder: (context, c) {
                    final wide = c.maxWidth >= 900;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (wide)
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: detailsPanel),
                              const SizedBox(width: 20),
                              Expanded(child: infoPanel),
                            ],
                          )
                        else ...[
                          detailsPanel,
                          const SizedBox(height: 16),
                          infoPanel,
                        ],
                        const SizedBox(height: 16),
                        if (wide)
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Capped so the text stays a readable length; on smaller windows they shrink to share the row.
                              Flexible(
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(maxWidth: _maxTaskWidth),
                                  child: _taskListPanel(),
                                ),
                              ),
                              const SizedBox(width: 20),
                              Flexible(
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(maxWidth: _maxNotesWidth),
                                  child: _notesPanel(),
                                ),
                              ),
                            ],
                          )
                        else ...[
                          _taskListPanel(),
                          const SizedBox(height: 16),
                          _notesPanel(),
                        ],
                        const SizedBox(height: 16),
                        _lineItemsPanel(lineItems),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ---- pieces ---------------------------------------------------------------

  /// Service Fusion's extra job fields (priority, duration, arrival window, visits, per-tech status).
  Map<String, dynamic> get _sf => _job?['sf_details'] is Map ? Map<String, dynamic>.from(_job!['sf_details'] as Map) : const {};

  List<Map<String, dynamic>> get _sfVisits {
    final v = _sf['visits'];
    return v is List ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() : const [];
  }

  /// "08:00:00" -> "8:00 AM". Anything that isn't a plain clock time is shown as sent.
  String _clock(dynamic v) {
    final raw = (v ?? '').toString().trim();
    final m = RegExp(r'^(\d{1,2}):(\d{2})(?::\d{2})?$').firstMatch(raw);
    if (m == null) return raw;
    return DateFormat('h:mm a').format(DateTime(2000, 1, 1, int.parse(m.group(1)!), int.parse(m.group(2)!)));
  }

  String _window(dynamic start, dynamic end) {
    final a = _clock(start);
    final b = _clock(end);
    if (a.isEmpty && b.isEmpty) return '';
    if (b.isEmpty) return a;
    if (a.isEmpty) return b;
    return '$a - $b';
  }

  /// Service Fusion sends durations in seconds: 3600 -> "1h", 5400 -> "1h 30m".
  String _duration(dynamic secs) {
    final n = int.tryParse(secs?.toString() ?? '') ?? 0;
    if (n <= 0) return '';
    final h = n ~/ 3600;
    final m = (n % 3600) ~/ 60;
    return [if (h > 0) '${h}h', if (m > 0) '${m}m'].join(' ');
  }

  Widget _techChip(String name, String status) => Wrap(
    spacing: 8,
    runSpacing: 4,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Text(name, style: const TextStyle(fontSize: 15, color: _link)),
      if (status.isNotEmpty) _pill(status),
    ],
  );

  /// Techs with their Service Fusion status tag when we have it, else the plain comma list.
  Widget _techsValue(String fallback) {
    final list = _sf['techs'];
    if (list is List && list.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final t in list.whereType<Map>())
            Padding(padding: const EdgeInsets.only(bottom: 4), child: _techChip((t['name'] ?? '').toString(), (t['status'] ?? '').toString())),
        ],
      );
    }
    return _text(fallback.isEmpty ? 'Unassigned' : fallback, link: fallback.isNotEmpty, muted: fallback.isEmpty);
  }

  /// Click-to-change status. Shows every status in a list; picking one is not saved yet (nothing is written to the
  /// database or Service Fusion), so the screen keeps showing the real value and says so.
  Widget _statusPicker(String current, {required bool sub}) {
    final has = current.trim().isNotEmpty && current != 'No status';
    final Widget face = sub
        ? (has ? _pill(current) : const Text('set sub-status', style: TextStyle(fontSize: 13, color: _link)))
        : Text(
            current,
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: statusColor(current)),
          );
    return PopupMenuButton<String>(
      tooltip: sub ? 'Change sub-status' : 'Change status',
      constraints: const BoxConstraints(maxHeight: 460, minWidth: 240),
      position: PopupMenuPosition.under,
      offset: const Offset(0, 6),
      onSelected: (picked) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('Changing ${sub ? 'sub-status' : 'status'} to "$picked" is not saved yet.')));
      },
      itemBuilder: (_) => [
        for (final name in (_isEstimate ? kEstimateStatuses : kJobStatuses))
          PopupMenuItem<String>(
            value: name,
            height: 38,
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(color: statusColor(name), shape: BoxShape.circle),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(name, style: TextStyle(fontWeight: name == current ? FontWeight.w800 : FontWeight.w500)),
                ),
                if (name == current) const Icon(Icons.check_rounded, size: 16),
              ],
            ),
          ),
      ],
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: face),
            const SizedBox(width: 2),
            const Icon(Icons.arrow_drop_down_rounded, size: 20, color: AppTheme.sectionLabel),
          ],
        ),
      ),
    );
  }

  // ---- links, key facts, loading skeleton -----------------------------------

  Future<void> _launch(Uri uri) async {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication).catchError((_) => false);
    if (ok) return;
    final what = switch (uri.scheme) {
      'mailto' => 'your email program',
      'tel' => 'the phone app',
      _ => 'that link',
    };
    _say('Could not open $what.');
  }

  Uri _telUri(String phone) => Uri(scheme: 'tel', path: phone.replaceAll(RegExp(r'[^0-9+]'), ''));

  Uri _mapsUri(String address) => Uri.https('www.google.com', '/maps/search/', {'api': '1', 'query': address});

  /// The Customers screen, searched for this customer's name (the same hand-off the nav bar search uses).
  void _openCustomer() => context.go('/customers?q=${Uri.encodeQueryComponent(_s('customer_name'))}');

  /// Blue text that does something when clicked, with a hover tooltip saying what.
  Widget _linkText(String text, VoidCallback onTap, {String? tip}) => Padding(
    padding: const EdgeInsets.only(bottom: 2),
    child: Tooltip(
      message: tip ?? '',
      waitDuration: const Duration(milliseconds: 600),
      child: InkWell(
        onTap: onTap,
        child: Text(
          text,
          style: const TextStyle(fontSize: 14, height: 1.3, color: _link, decoration: TextDecoration.underline, decorationColor: Color(0x662563EB)),
        ),
      ),
    ),
  );

  /// "$950.00" in red while something is owed, or a green "Paid in full".
  Widget _balanceText(Map<String, dynamic> job) {
    final due = _n(job['due_total']);
    if (due <= 0.005 && _n(job['total_revenue']) > 0) return _text('Paid in full', link: false).withColor(AppTheme.successGreen);
    return _text(_money.format(due)).withColor(due > 0.005 ? const Color(0xFFB91C1C) : AppTheme.primaryText);
  }

  /// Placeholder cards shaped like the page, shown while a job opened by its address (no row to show yet) loads.
  Widget _skeletonPage() {
    Widget bar(double w, double h) => Container(
      width: w,
      height: h,
      decoration: BoxDecoration(color: const Color(0xFFCBD5E1), borderRadius: BorderRadius.circular(6)),
    );
    Widget card({int rows = 6}) => Container(
      decoration: BoxDecoration(
        color: AppTheme.surfaceColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.strokeBorder),
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          bar(120, 16),
          const SizedBox(height: 18),
          for (var i = 0; i < rows; i++) ...[
            Row(
              children: [
                bar(130, 12),
                const SizedBox(width: 24),
                Expanded(child: bar(double.infinity, 12)),
              ],
            ),
            const SizedBox(height: 18),
          ],
        ],
      ),
    );
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _maxPageWidth),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          child: SkeletonPulse(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                bar(300, 30),
                const SizedBox(height: 16),
                LayoutBuilder(
                  builder: (context, c) => c.maxWidth >= 900
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: card()),
                            const SizedBox(width: 20),
                            Expanded(child: card(rows: 8)),
                          ],
                        )
                      : card(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _text(String v, {bool link = false, bool muted = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 2),
    child: SelectableText(
      v,
      style: TextStyle(fontSize: 14, height: 1.3, color: link ? _link : (muted ? AppTheme.sectionLabel : AppTheme.primaryText)),
    ),
  );

  /// Solid, Service-Fusion-style pill (white text on the status colour), for sub-status and per-tech status.
  Widget _pill(String text) {
    final c = statusColor(text);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(20)),
      child: Text(
        text,
        style: TextStyle(color: c.computeLuminance() > 0.55 ? const Color(0xFF111827) : Colors.white, fontWeight: FontWeight.w800, fontSize: 12),
      ),
    );
  }

  Widget _badge(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color.withValues(alpha: 0.3)),
    ),
    child: Text(
      text,
      style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 11, letterSpacing: 0.5),
    ),
  );

  /// Service-Fusion-style panel: a grey title bar, then (when it has tabs) a separate tab strip, then rows separated by
  /// hairlines. The title and the tabs are deliberately different things: the title is a heading, the tabs are underlined.
  Widget _panel(String title, List<Widget> rows, {List<(String, IconData)>? tabs, int selected = 0, ValueChanged<int>? onTab, Widget? action}) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surfaceColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.strokeBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: _headerBar,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppTheme.primaryText),
                  ),
                ),
                ?action,
              ],
            ),
          ),
          if (tabs != null) ...[
            const Divider(height: 1, color: AppTheme.strokeBorder),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [for (var i = 0; i < tabs.length; i++) _tabButton(tabs[i].$1, tabs[i].$2, i == selected, () => onTab?.call(i))]),
            ),
          ],
          const Divider(height: 1, color: AppTheme.strokeBorder),
          for (var i = 0; i < rows.length; i++) ...[if (i > 0) const Divider(height: 1, color: AppTheme.strokeBorder), rows[i]],
        ],
      ),
    );
  }

  /// A tab: icon + label with a red underline when it is the open one. No box, so it never reads as a heading.
  Widget _tabButton(String label, IconData icon, bool active, VoidCallback onTap) {
    return Semantics(
      button: true,
      selected: active,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: active ? AppTheme.brandRed : Colors.transparent, width: 2)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: active ? AppTheme.brandRed : AppTheme.sectionLabel),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: active ? FontWeight.w800 : FontWeight.w500,
                  color: active ? AppTheme.primaryText : AppTheme.secondaryText,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _emptyTab(IconData icon, String title, String hint) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 36),
      child: Column(
        children: [
          Icon(icon, size: 36, color: AppTheme.sectionLabel),
          const SizedBox(height: 10),
          Text(
            title,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.secondaryText),
          ),
          const SizedBox(height: 4),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: AppTheme.sectionLabel),
          ),
        ],
      ),
    );
  }

  /// Pictures / documents Service Fusion has on the job. null = the sync hasn't brought them in yet (so we can say
  /// "not synced yet" instead of claiming there are none).
  List<Map<String, dynamic>>? _files(String key) {
    final v = _sf[key];
    if (v is! List) return null;
    return v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  String _countLabel(String label, List<Map<String, dynamic>>? files, int ours) {
    final n = (files?.length ?? 0) + ours;
    return n == 0 ? label : '$label ($n)';
  }

  /// Service Fusion's API gives only the stored file name. Pictures are public at this S3 folder (checked on real
  /// jobs: every picture, job or estimate, is under images/estimates). The documents folder is not known yet, so a
  /// document name stays unresolved and says so when clicked.
  static const _pictureBase = 'https://servicefusion.s3.amazonaws.com/images/estimates/';

  String _resolveFileUrl(String stored, {required bool picture}) {
    final u = stored.trim();
    if (u.isEmpty) return '';
    final uri = Uri.tryParse(u);
    if (uri != null && uri.hasScheme) return u;
    return picture ? '$_pictureBase${Uri.encodeComponent(u)}' : u;
  }

  Future<void> _openFile(String url) async {
    void say(String msg) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(msg)));
    }

    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      // Service Fusion's API gives only the stored file name (e.g. "c93ed5....jpg"), not a web address.
      say('Service Fusion only sent the file name ($url), not a link, so this file cannot be opened from here yet.');
      return;
    }
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) say('Could not open that file.');
  }

  // ---- our own uploads ------------------------------------------------------

  static const _pictureExts = ['jpg', 'jpeg', 'png', 'webp', 'gif', 'heic', 'heif'];
  static const _documentExts = ['pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'csv', 'txt', 'rtf', 'dwg', 'dxf'];
  static const _maxUploadBytes = 25 * 1024 * 1024;

  String get _filesUrl => '$kApiBaseUrl/api/jobs/${Uri.encodeComponent(widget.jobId)}/files';

  void _say(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _loadFiles() async {
    try {
      final res = await http.get(Uri.parse(_filesUrl), headers: AuthSession.instance.headers(json: false)).timeout(const Duration(seconds: 30));
      if (!mounted || res.statusCode != 200) return;
      final data = json.decode(res.body) as Map<String, dynamic>;
      setState(() {
        _filesEnabled = data['enabled'] != false;
        _ourFiles = List<Map<String, dynamic>>.from((data['files'] as List? ?? const []).whereType<Map>().map(Map<String, dynamic>.from));
      });
    } catch (_) {
      // Our uploads just don't show this time; the rest of the page is unaffected.
    }
  }

  String _serverMessage(http.Response res) {
    try {
      final m = json.decode(res.body);
      if (m is Map && m['error'] != null) return m['error'].toString();
    } catch (_) {}
    return 'server error ${res.statusCode}';
  }

  Future<void> _upload({required bool pictures}) async {
    if (_uploadStatus != null) return;
    List<PlatformFile> picked;
    try {
      picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: pictures ? _pictureExts : _documentExts);
    } catch (_) {
      _say('Could not open the file picker.');
      return;
    }
    if (picked.isEmpty || !mounted) return;

    var done = 0;
    final failed = <String>[];
    for (final f in picked) {
      if (!mounted) return;
      setState(() => _uploadStatus = 'Uploading ${done + failed.length + 1} of ${picked.length}…');
      try {
        final bytes = await f.readAsBytes();
        if (bytes.length > _maxUploadBytes) {
          failed.add('${f.name} (over 25 MB)');
          continue;
        }
        final req = http.MultipartRequest('POST', Uri.parse(_filesUrl))
          ..headers.addAll(AuthSession.instance.headers(json: false))
          ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: f.name));
        final res = await http.Response.fromStream(await req.send().timeout(const Duration(minutes: 3)));
        if (res.statusCode == 401) {
          AuthSession.instance.logout(); // sends the app back to the sign-in screen
          return;
        }
        if (res.statusCode == 201) {
          done++;
          continue;
        }
        failed.add('${f.name} (${_serverMessage(res)})');
        if (res.statusCode == 503) break; // storage isn't set up: no point trying the rest
      } catch (_) {
        failed.add('${f.name} (could not reach the server)');
      }
    }
    if (!mounted) return;
    setState(() => _uploadStatus = null);
    await _loadFiles();
    if (failed.isEmpty) {
      _say(done == 1 ? 'Uploaded 1 file.' : 'Uploaded $done files.');
    } else {
      _say('${done > 0 ? 'Uploaded $done. ' : ''}Could not upload: ${failed.join('; ')}');
    }
  }

  Future<void> _removeFile(Map<String, dynamic> f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove this file?'),
        content: Text('"${f['name']}" will be removed from this job.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final res = await http
          .delete(Uri.parse('$_filesUrl/${Uri.encodeComponent(f['id'].toString())}'), headers: AuthSession.instance.headers(json: false))
          .timeout(const Duration(seconds: 30));
      if (res.statusCode == 401) {
        AuthSession.instance.logout();
        return;
      }
      if (res.statusCode != 200) {
        _say('Could not remove it: ${_serverMessage(res)}');
        return;
      }
      await _loadFiles();
    } catch (_) {
      _say('Could not reach the server.');
    }
  }

  /// The Upload button row at the top of the Pics and Docs tabs.
  Widget _uploadBar({required bool pictures}) {
    final busy = _uploadStatus != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
      child: Row(
        children: [
          FilledButton.icon(
            onPressed: (busy || !_filesEnabled) ? null : () => _upload(pictures: pictures),
            icon: const Icon(Icons.upload_rounded, size: 18),
            label: Text(pictures ? 'Upload pictures' : 'Upload documents'),
          ),
          const SizedBox(width: 12),
          if (busy) ...[
            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 8),
            Text(_uploadStatus!, style: const TextStyle(fontSize: 13, color: AppTheme.secondaryText)),
          ] else if (!_filesEnabled)
            const Flexible(
              child: Text(
                'Uploads are not set up yet: the file storage keys still need to be added on the server.',
                style: TextStyle(fontSize: 13, color: AppTheme.sectionLabel),
              ),
            )
          else
            Flexible(
              child: Text(
                pictures ? 'JPG, PNG, WEBP, GIF or HEIC, up to 25 MB each' : 'PDF, Word, Excel, PowerPoint, CSV, TXT or DWG, up to 25 MB each',
                style: const TextStyle(fontSize: 12.5, color: AppTheme.sectionLabel),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _picsRows() {
    final ours = _ourFiles.where((f) => f['kind'] == 'pic').toList();
    final sf = _files('pictures');
    // One list for the viewer, in the same order as the tiles, so Previous / Next walk through every picture.
    final viewer = <ViewerFile>[
      for (final f in ours) _ourViewerFile(f),
      for (final f in sf ?? const <Map<String, dynamic>>[])
        ViewerFile(
          name: (f['name'] ?? 'Picture').toString(),
          previewUrl: _resolveFileUrl((f['url'] ?? '').toString(), picture: true),
          meta: _dateTime(f['created_at']),
        ),
    ];
    final tiles = <Widget>[
      for (var i = 0; i < viewer.length; i++)
        _picTile(i < ours.length ? ours[i] : sf![i - ours.length], ours: i < ours.length, onOpen: () => showFileViewer(context, viewer, i)),
    ];
    return [
      _uploadBar(pictures: true),
      if (tiles.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
          child: Wrap(spacing: 12, runSpacing: 12, children: tiles),
        )
      else if (sf == null)
        _emptyTab(Icons.photo_camera_outlined, 'No pictures yet', 'Upload one above. Service Fusion pictures appear after the next sync of this job.')
      else
        _emptyTab(Icons.photo_camera_outlined, 'No pictures on this job', 'Upload one above.'),
    ];
  }

  Widget _picTile(Map<String, dynamic> f, {bool ours = false, VoidCallback? onOpen}) {
    final url = ours ? (f['url'] ?? '').toString() : _resolveFileUrl((f['url'] ?? '').toString(), picture: true);
    final name = (f['name'] ?? '').toString();
    final comment = (f['comment'] ?? '').toString().trim();
    Widget placeholder(IconData icon) => Container(
      color: _headerBar,
      alignment: Alignment.center,
      child: Icon(icon, color: AppTheme.sectionLabel, size: 30),
    );
    return Tooltip(
      message: [
        name,
        if (ours && (f['uploadedBy'] ?? '').toString().isNotEmpty) 'Uploaded by ${f['uploadedBy']}',
        if (comment.isNotEmpty) comment,
      ].join('\n'),
      child: SizedBox(
        width: 150,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                InkWell(
                  onTap: url.isEmpty ? null : onOpen,
                  borderRadius: BorderRadius.circular(8),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 150,
                      height: 110,
                      child: url.isEmpty
                          ? placeholder(Icons.image_not_supported_outlined)
                          : Image.network(
                              url,
                              fit: BoxFit.cover,
                              // On the web build the bucket sends no CORS header; this falls back to a plain <img> so thumbnails still show.
                              webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
                              loadingBuilder: (_, child, progress) => progress == null ? child : placeholder(Icons.image_outlined),
                              errorBuilder: (_, _, _) => placeholder(Icons.broken_image_outlined), // not an image, or the link needs a login
                            ),
                    ),
                  ),
                ),
                if (ours)
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Material(
                      color: Colors.black54,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => _removeFile(f),
                        child: const Padding(
                          padding: EdgeInsets.all(4),
                          child: Icon(Icons.close_rounded, size: 16, color: Colors.white),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            InkWell(
              onTap: url.isEmpty ? null : onOpen,
              child: Text(
                name.isEmpty ? 'Picture' : name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, color: AppTheme.secondaryText),
              ),
            ),
          ],
        ),
      ),
    );
  }

  ViewerFile _ourViewerFile(Map<String, dynamic> f) => ViewerFile(
    name: (f['name'] ?? 'File').toString(),
    previewUrl: (f['url'] ?? '').toString().isEmpty ? null : f['url'].toString(),
    contentUrl: '$_filesUrl/${Uri.encodeComponent(f['id'].toString())}/content',
    meta: [
      _size(f['size']),
      if ((f['uploadedBy'] ?? '').toString().isNotEmpty) 'Uploaded by ${f['uploadedBy']}',
      _dateTime(f['createdAt']),
    ].where((e) => e.isNotEmpty).join('  ·  '),
  );

  String _size(dynamic bytes) {
    final n = (bytes is num) ? bytes.toDouble() : (double.tryParse('$bytes') ?? 0);
    if (n <= 0) return '';
    if (n < 1024 * 1024) return '${(n / 1024).ceil()} KB';
    return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  List<Widget> _docsRows() {
    final ours = _ourFiles.where((f) => f['kind'] == 'doc').toList();
    final sf = _files('documents');
    final viewer = [for (final f in ours) _ourViewerFile(f)];
    Widget row(Map<String, dynamic> f, {required bool isOurs, int index = 0}) {
      final url = (f['url'] ?? '').toString();
      final meta = isOurs
          ? [_size(f['size']), if ((f['uploadedBy'] ?? '').toString().isNotEmpty) 'Uploaded by ${f['uploadedBy']}', _dateTime(f['createdAt'])]
          : [(f['type'] ?? '').toString(), _dateTime(f['created_at'])];
      return InkWell(
        // Ours open in the viewer; Service Fusion's only have a file name, so they just explain that.
        onTap: isOurs ? () => showFileViewer(context, viewer, index) : (url.isEmpty ? null : () => _openFile(url)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.insert_drive_file_outlined, size: 20, color: AppTheme.secondaryText),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      (f['name'] ?? '').toString().isEmpty ? 'Document' : f['name'].toString(),
                      style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: _link),
                    ),
                    if ((f['comment'] ?? '').toString().trim().isNotEmpty)
                      Text(f['comment'].toString().trim(), style: const TextStyle(fontSize: 13, color: AppTheme.secondaryText, height: 1.3)),
                    Text(meta.where((e) => e.trim().isNotEmpty).join('  ·  '), style: const TextStyle(fontSize: 12, color: AppTheme.sectionLabel)),
                  ],
                ),
              ),
              if (f['is_private'] == true) _badge('PRIVATE', AppTheme.secondaryText),
              if (isOurs) IconButton(tooltip: 'Remove', icon: const Icon(Icons.delete_outline_rounded, size: 20), onPressed: () => _removeFile(f)),
            ],
          ),
        ),
      );
    }

    return [
      _uploadBar(pictures: false),
      if (ours.isEmpty && (sf == null || sf.isEmpty))
        _emptyTab(
          Icons.description_outlined,
          sf == null ? 'No documents yet' : 'No documents on this job',
          sf == null ? 'Upload one above. Service Fusion documents appear after the next sync of this job.' : 'Upload one above.',
        )
      else ...[
        for (var i = 0; i < ours.length; i++) row(ours[i], isOurs: true, index: i),
        // Service Fusion's own documents: we only have their file names, not a link, so they can't be opened from here.
        for (final f in sf ?? const <Map<String, dynamic>>[]) row(f, isOurs: false),
      ],
    ];
  }

  String get _jobUrl => '$kApiBaseUrl/api/jobs/${Uri.encodeComponent(widget.jobId)}';

  Future<void> _loadNotesTasks() async {
    try {
      final res = await http
          .get(Uri.parse('$_jobUrl/notes-tasks'), headers: AuthSession.instance.headers(json: false))
          .timeout(const Duration(seconds: 30));
      if (!mounted || res.statusCode != 200) return;
      final data = json.decode(res.body) as Map<String, dynamic>;
      List<Map<String, dynamic>> rows(String k) => (data[k] as List? ?? const []).whereType<Map>().map(Map<String, dynamic>.from).toList();
      setState(() {
        _ourNotes = rows('notes');
        _ourTasks = rows('tasks');
      });
    } catch (_) {
      // Ours just don't show this time; Service Fusion's and the rest of the page are unaffected.
    }
  }

  /// Sends one change and returns an error message, or null when it worked.
  Future<String?> _send(String method, String path, [Map<String, dynamic>? body]) async {
    try {
      final req = http.Request(method, Uri.parse('$_jobUrl/$path'))..headers.addAll(AuthSession.instance.headers());
      if (body != null) req.body = json.encode(body);
      final res = await http.Response.fromStream(await req.send().timeout(const Duration(seconds: 30)));
      if (res.statusCode == 401) {
        AuthSession.instance.logout(); // sends the app back to the sign-in screen
        return 'Your session expired. Please sign in again.';
      }
      if (res.statusCode >= 200 && res.statusCode < 300) return null;
      return _serverMessage(res);
    } catch (_) {
      return 'Could not reach the server.';
    }
  }

  /// A small "type it, Save it" dialog. [onSave] returns an error to show in the dialog, or null to close it.
  Future<bool> _textDialog({
    required String title,
    required String hint,
    required int maxLength,
    required int maxLines,
    required Future<String?> Function(String text) onSave,
  }) async {
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _TextDialog(title: title, hint: hint, maxLength: maxLength, maxLines: maxLines, onSave: onSave),
    );
    return saved == true;
  }

  Future<void> _addNote() async {
    final ok = await _textDialog(
      title: 'Add Note',
      hint: 'Write a note about this job',
      maxLength: 5000,
      maxLines: 8,
      onSave: (text) => _send('POST', 'notes', {'body': text}),
    );
    if (ok) await _loadNotesTasks();
  }

  Future<void> _addTask() async {
    final ok = await _textDialog(
      title: 'Add Task',
      hint: 'What needs to be done?',
      maxLength: 500,
      maxLines: 1,
      onSave: (text) => _send('POST', 'tasks', {'description': text}),
    );
    if (ok) await _loadNotesTasks();
  }

  Future<bool> _confirm(String title, String body, String action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _removeNote(Map<String, dynamic> n) async {
    if (!await _confirm('Remove this note?', 'It will be removed from this job.', 'Remove')) return;
    final err = await _send('DELETE', 'notes/${Uri.encodeComponent(n['id'].toString())}');
    if (err != null) _say('Could not remove it: $err');
    await _loadNotesTasks();
  }

  Future<void> _removeTask(Map<String, dynamic> t) async {
    if (!await _confirm('Remove this task?', '"${t['description']}" will be removed from this job.', 'Remove')) return;
    final err = await _send('DELETE', 'tasks/${Uri.encodeComponent(t['id'].toString())}');
    if (err != null) _say('Could not remove it: $err');
    await _loadNotesTasks();
  }

  Future<void> _toggleTask(Map<String, dynamic> t) async {
    final err = await _send('PATCH', 'tasks/${Uri.encodeComponent(t['id'].toString())}', {'is_completed': t['isCompleted'] != true});
    if (err != null) _say('Could not update the task: $err');
    await _loadNotesTasks();
  }

  Widget _addButton(String label, VoidCallback onTap) => Padding(
    padding: const EdgeInsets.only(left: 8),
    child: OutlinedButton.icon(
      onPressed: onTap,
      icon: const Icon(Icons.add_rounded, size: 18),
      label: Text(label),
      style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
    ),
  );

  DateTime? _when(dynamic v) => DateTime.tryParse(v?.toString() ?? '');

  /// Task List: ours (add, tick off, remove) then Service Fusion's (read-only). Completed ones are struck through on a light blue row.
  Widget _taskListPanel() {
    final raw = _sf['tasks'];
    final List<Map<String, dynamic>> sfTasks = raw is List ? raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() : const [];
    final action = _addButton('Add Task', _addTask);

    Widget row({required String text, required bool done, required String sub, VoidCallback? onToggle, VoidCallback? onRemove}) => Container(
      color: done ? const Color(0xFFE8F4FD) : null,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          onToggle == null
              ? Padding(
                  padding: const EdgeInsets.all(8),
                  child: Icon(done ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded, size: 20, color: AppTheme.sectionLabel),
                )
              : IconButton(
                  tooltip: done ? 'Mark not done' : 'Mark done',
                  icon: Icon(
                    done ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                    size: 22,
                    color: done ? AppTheme.successGreen : AppTheme.secondaryText,
                  ),
                  onPressed: onToggle,
                ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 9, bottom: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    text,
                    style: TextStyle(
                      fontSize: 14.5,
                      height: 1.35,
                      color: done ? AppTheme.secondaryText : AppTheme.primaryText,
                      decoration: done ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  if (sub.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(sub, style: const TextStyle(fontSize: 12, color: AppTheme.sectionLabel)),
                    ),
                ],
              ),
            ),
          ),
          if (onRemove != null) IconButton(tooltip: 'Remove task', icon: const Icon(Icons.delete_outline_rounded, size: 20), onPressed: onRemove),
        ],
      ),
    );

    final rows = <Widget>[
      for (final t in _ourTasks)
        row(
          text: (t['description'] ?? '').toString(),
          done: t['isCompleted'] == true,
          sub: [
            if ((t['createdBy'] ?? '').toString().isNotEmpty) 'Added by ${t['createdBy']}',
            if (t['isCompleted'] == true && (t['completedBy'] ?? '').toString().isNotEmpty) 'done by ${t['completedBy']}',
          ].join('  ·  '),
          onToggle: () => _toggleTask(t),
          onRemove: () => _removeTask(t),
        ),
      for (final t in sfTasks) row(text: (t['description'] ?? '').toString(), done: t['is_completed'] == true, sub: 'Service Fusion'),
    ];
    if (rows.isEmpty) {
      return _panel('Task List', [
        _emptyTab(Icons.checklist_rounded, _sf['tasks'] is List ? 'No tasks on this job' : 'No tasks yet', 'Use Add Task to add one.'),
      ], action: action);
    }
    return _panel('Task List', rows, action: action);
  }

  /// Notes, newest first: ours show who wrote them; Service Fusion's only come with a date (the API sends no author).
  static const int _notesCollapsedCount = 2; // notes shown while the section is collapsed

  Widget _notesPanel() {
    final raw = _sf['notes'];
    final List<Map<String, dynamic>> sfNotes = raw is List ? raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() : const [];
    final all = <({DateTime? at, Widget Function() build})>[
      for (final n in _ourNotes)
        (
          at: _when(n['createdAt']),
          build: () => _noteRow(
            head: [
              _dateTime(n['createdAt']),
              if ((n['author'] ?? '').toString().isNotEmpty) 'by ${n['author']}',
            ].where((e) => e.isNotEmpty).join(' '),
            text: (n['body'] ?? '').toString(),
            onRemove: () => _removeNote(n),
          ),
        ),
      for (final n in sfNotes)
        (
          at: _when(n['created_at']),
          build: () => _noteRow(
            head: [_dateTime(n['created_at']), '·  Service Fusion'].where((e) => e.isNotEmpty).join('  '),
            text: (n['text'] ?? '').toString(),
          ),
        ),
    ]..sort((a, b) => (b.at ?? DateTime.fromMillisecondsSinceEpoch(0)).compareTo(a.at ?? DateTime.fromMillisecondsSinceEpoch(0)));
    final action = _addButton('Add Notes', _addNote);
    if (all.isEmpty) {
      return _panel('Notes', [
        _emptyTab(Icons.sticky_note_2_outlined, _sf['notes'] is List ? 'No notes on this job' : 'No notes yet', 'Use Add Notes to write one.'),
      ], action: action);
    }
    // Collapsed by default when there are more than a couple: the newest few, then a control to show them all.
    final collapsible = all.length > _notesCollapsedCount;
    final shown = (collapsible && !_notesExpanded) ? all.take(_notesCollapsedCount).toList() : all;
    return _panel('Notes', [
      for (final n in shown) n.build(),
      if (collapsible)
        InkWell(
          onTap: () => setState(() => _notesExpanded = !_notesExpanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            child: Row(
              children: [
                Icon(_notesExpanded ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 20, color: _link),
                const SizedBox(width: 6),
                Text(
                  _notesExpanded ? 'Show fewer notes' : 'Show all ${all.length} notes (${all.length - _notesCollapsedCount} older)',
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: _link),
                ),
              ],
            ),
          ),
        ),
    ], action: action);
  }

  Widget _noteRow({required String head, required String text, VoidCallback? onRemove}) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 14, 8, 14),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (head.isNotEmpty)
                Text(
                  head,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: AppTheme.primaryText),
                ),
              const SizedBox(height: 4),
              SelectableText(text, style: const TextStyle(fontSize: 14.5, height: 1.4, color: AppTheme.secondaryText)),
            ],
          ),
        ),
        if (onRemove != null) IconButton(tooltip: 'Remove note', icon: const Icon(Icons.delete_outline_rounded, size: 20), onPressed: onRemove),
      ],
    ),
  );

  /// Activity tab: one timeline, newest first. Anything done in this app names the person; status changes come from
  /// Service Fusion's sync, which does not tell us who made them.
  List<Widget> _activityRows() {
    final events = <({DateTime? at, IconData icon, String who, String what})>[
      for (final h in _history)
        (
          at: _when(h['changed_at']),
          icon: Icons.swap_horiz_rounded,
          who: 'Service Fusion',
          what: 'Status ${(h['old_status'] ?? '').toString()}  →  ${(h['new_status'] ?? '').toString()}',
        ),
      for (final n in _ourNotes)
        (at: _when(n['createdAt']), icon: Icons.sticky_note_2_outlined, who: (n['author'] ?? '').toString(), what: 'Added a note'),
      for (final t in _ourTasks) ...[
        (at: _when(t['createdAt']), icon: Icons.add_task_rounded, who: (t['createdBy'] ?? '').toString(), what: 'Added task "${t['description']}"'),
        if (t['isCompleted'] == true && t['completedAt'] != null)
          (
            at: _when(t['completedAt']),
            icon: Icons.check_circle_outline_rounded,
            who: (t['completedBy'] ?? '').toString(),
            what: 'Completed task "${t['description']}"',
          ),
      ],
      for (final f in _ourFiles)
        (
          at: _when(f['createdAt']),
          icon: f['kind'] == 'pic' ? Icons.photo_camera_outlined : Icons.description_outlined,
          who: (f['uploadedBy'] ?? '').toString(),
          what: 'Uploaded ${f['name']}',
        ),
    ]..sort((a, b) => (b.at ?? DateTime.fromMillisecondsSinceEpoch(0)).compareTo(a.at ?? DateTime.fromMillisecondsSinceEpoch(0)));

    if (events.isEmpty) {
      return [_emptyTab(Icons.view_headline_rounded, 'No activity recorded', 'Status changes and anything done here show up as they happen.')];
    }
    return [
      for (final e in events)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(e.icon, size: 18, color: AppTheme.secondaryText),
              const SizedBox(width: 10),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    style: const TextStyle(fontSize: 14, color: AppTheme.primaryText, height: 1.35),
                    children: [
                      if (e.who.isNotEmpty)
                        TextSpan(
                          text: '${e.who}  ',
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      TextSpan(text: e.what),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(e.at == null ? '' : _dateTime(e.at!.toIso8601String()), style: const TextStyle(fontSize: 12.5, color: AppTheme.sectionLabel)),
            ],
          ),
        ),
    ];
  }

  /// Payment tab: what the job is worth and owes, then each payment we have on file.
  List<Widget> _paymentRows(Map<String, dynamic> job) {
    return [
      _sfRow(
        Icons.receipt_long_outlined,
        _isEstimate ? 'Estimate Total' : 'Job Total',
        job['total_revenue'] == null ? null : _text(_money.format(_n(job['total_revenue']))),
      ),
      // An estimate has no balance: Service Fusion carries the whole quote in that field.
      if (!_isEstimate) _sfRow(Icons.account_balance_wallet_outlined, 'Balance Due', job['due_total'] == null ? null : _balanceText(job)),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => _PaymentLinkDialog(
                jobId: widget.jobId,
                total: _n(job['total_revenue']),
                balance: _isEstimate ? 0 : _n(job['due_total']),
              ),
            ),
            icon: const Icon(Icons.link, size: 18),
            label: const Text('Request payment'),
          ),
        ),
      ),
      if (_payments.isEmpty)
        _emptyTab(Icons.payments_outlined, 'No payments recorded', 'Payments show here once they are received.')
      else
        for (final p in _payments)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    [
                      _dateTime(p['received_on']),
                      (p['payment_type'] ?? '').toString(),
                      (p['transaction_type'] ?? '').toString(),
                    ].where((e) => e.trim().isNotEmpty).join('  ·  '),
                    style: const TextStyle(fontSize: 14, color: AppTheme.secondaryText),
                  ),
                ),
                Text(
                  _money.format(_n(p['amount'])),
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppTheme.successGreen),
                ),
              ],
            ),
          ),
      if (_stripePayments.isNotEmpty) ...[
        const Padding(
          padding: EdgeInsets.fromLTRB(18, 14, 18, 2),
          child: Text(
            'Stripe payments (not counted in the balance or reports yet)',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppTheme.primaryText),
          ),
        ),
        for (final p in _stripePayments)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    [_dateTime(p['received_on']), p['kind'] == 'refund' ? 'Stripe refund' : 'Stripe']
                        .where((e) => e.trim().isNotEmpty)
                        .join('  ·  '),
                    style: const TextStyle(fontSize: 14, color: AppTheme.secondaryText),
                  ),
                ),
                Text(
                  _money.format(_n(p['amount'])),
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppTheme.secondaryText),
                ),
              ],
            ),
          ),
      ],
    ];
  }

  /// One icon + bold label + value row. A null value reads "Not Set", like Service Fusion. On a narrow window the value
  /// moves under its label instead of squeezing beside it.
  Widget _sfRow(IconData icon, String label, Widget? value) {
    final labelStyle = const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppTheme.primaryText);
    return LayoutBuilder(
      builder: (context, c) {
        final stacked = c.maxWidth < 460;
        final labelRow = Row(
          children: [
            Icon(icon, size: 17, color: AppTheme.secondaryText),
            const SizedBox(width: 8),
            Expanded(child: Text(label, style: labelStyle)),
          ],
        );
        final shown = value ?? _text('Not Set', muted: true);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          child: stacked
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    labelRow,
                    const SizedBox(height: 4),
                    Padding(padding: const EdgeInsets.only(left: 25), child: shown),
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 182, child: labelRow),
                    const SizedBox(width: 12),
                    Expanded(child: shown),
                  ],
                ),
        );
      },
    );
  }

  /// "Site Visits (n)" strip at the bottom of the Job Info panel. Uses Service Fusion's own visits when synced
  /// (date, arrival window, duration, techs with status, notes); until then, the tech work days we recorded.
  static const int _visitsCollapsedCount = 3; // visits shown while the section is collapsed

  Widget _visitsSection() {
    final visits = _sfVisits; // only what Service Fusion lists: no visit rows from it means no visits
    final count = visits.length;
    // More than a handful of visits: collapsed by default to the latest few (keeping their real numbers, so the
    // hidden ones are the earliest). The control sits right under the heading, where the hidden ones would start.
    final collapsible = count > _visitsCollapsedCount;
    final first = (collapsible && !_visitsExpanded) ? count - _visitsCollapsedCount : 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
          color: _headerBar,
          child: Text(
            'Site Visits ($count)',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: AppTheme.secondaryText),
          ),
        ),
        if (collapsible)
          InkWell(
            onTap: () => setState(() => _visitsExpanded = !_visitsExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
              child: Row(
                children: [
                  Icon(_visitsExpanded ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 20, color: _link),
                  const SizedBox(width: 6),
                  Text(
                    _visitsExpanded ? 'Show fewer visits' : 'Show all $count visits ($first earlier)',
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: _link),
                  ),
                ],
              ),
            ),
          ),
        if (count == 0)
          Padding(padding: const EdgeInsets.all(18), child: _text('No visits scheduled.', muted: true))
        else
          for (var i = first; i < visits.length; i++) ...[
            if (i > first || collapsible) const Divider(height: 1, color: AppTheme.strokeBorder),
            _sfVisit(i, visits[i]),
          ],
      ],
    );
  }

  Widget _sfVisit(int i, Map<String, dynamic> v) {
    final window = _window(v['time_frame_promised_start'], v['time_frame_promised_end']);
    final dur = _duration(v['duration']);
    final dateText = _date(v['start_date']);
    final timeText = [window, if (dur.isNotEmpty) '($dur)'].where((e) => e.isNotEmpty).join('  ');
    final notes = (v['notes_for_techs'] ?? '').toString().trim();
    final techs = v['techs'] is List ? (v['techs'] as List).whereType<Map>().toList() : <Map>[];
    Widget line(IconData icon, Widget child) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 26,
            child: Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(icon, size: 16, color: AppTheme.secondaryText),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
    // Date and time share one line, and a visit with no notes doesn't spend a line saying so.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text('Visit ${i + 1}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                line(
                  Icons.event_rounded,
                  Wrap(
                    spacing: 14,
                    children: [
                      _text(dateText.isEmpty ? 'Not Set' : dateText, muted: dateText.isEmpty),
                      _text(timeText.isEmpty ? 'No time set' : timeText, muted: timeText.isEmpty),
                    ],
                  ),
                ),
                line(
                  Icons.groups_rounded,
                  techs.isEmpty
                      ? _text('Unassigned', muted: true)
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final t in techs)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 4), // one tech per line
                                child: _techChip((t['name'] ?? '').toString(), (t['status'] ?? '').toString()),
                              ),
                          ],
                        ),
                ),
                if (notes.isNotEmpty) line(Icons.sticky_note_2_outlined, _text(notes)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Line items as a table (item, qty, rate, amount) with the charges and the total underneath, so the maths is visible.
  Widget _lineItemsPanel(List<Map<String, dynamic>> items) {
    final sorted = [...items]..sort((a, b) => _n(a['item_index']).compareTo(_n(b['item_index'])));
    final charges = (_job?['other_charges'] is List)
        ? (_job!['other_charges'] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
        : <Map<String, dynamic>>[];
    final subtotal = sorted.fold<double>(0, (sum, it) => sum + _n(it['total']));
    double signed(Map<String, dynamic> c) => c['is_discount'] == true ? -_n(c['total']).abs() : _n(c['total']);
    final chargeSum = charges.fold<double>(0, (sum, c) => sum + signed(c));
    final hasTotal = _job?['total_revenue'] != null;
    final total = _n(_job?['total_revenue']);
    final leftover = hasTotal ? total - (subtotal + chargeSum) : 0.0; // labor, expenses etc. that aren't line items

    return LayoutBuilder(
      builder: (context, c) {
        final narrow = c.maxWidth < 560;
        const qtyW = 56.0, rateW = 96.0, amtW = 104.0;
        const head = TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: AppTheme.secondaryText, letterSpacing: 0.6);
        Widget cell(String t, double w, {bool right = true}) => SizedBox(
          width: w,
          child: Text(t, textAlign: right ? TextAlign.right : TextAlign.left, style: head),
        );
        Widget moneyRow(String label, double amount, {bool bold = false, Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 13.5, fontWeight: bold ? FontWeight.w800 : FontWeight.w500, color: color ?? AppTheme.secondaryText),
                ),
              ),
              SizedBox(
                width: amtW,
                child: Text(
                  _money.format(amount),
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: bold ? 15 : 14,
                    fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
                    color: color ?? AppTheme.primaryText,
                  ),
                ),
              ),
            ],
          ),
        );

        return _panel('Line Items', [
          if (sorted.isEmpty)
            Padding(padding: const EdgeInsets.all(18), child: _text('No line items.', muted: true))
          else ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              child: Row(
                children: [
                  const Expanded(child: Text('ITEM', style: head)),
                  if (!narrow) cell('QTY', qtyW),
                  if (!narrow) cell('RATE', rateW),
                  cell('AMOUNT', amtW),
                ],
              ),
            ),
            for (final it in sorted)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: SelectableText(
                        (it['name'] ?? it['product'] ?? it['service'] ?? 'Item').toString(),
                        style: const TextStyle(fontSize: 14, color: AppTheme.primaryText, height: 1.3),
                      ),
                    ),
                    if (!narrow)
                      SizedBox(
                        width: qtyW,
                        child: Text(
                          _n(it['multiplier']) == 0 ? '1' : _n(it['multiplier']).toStringAsFixed(_n(it['multiplier']) % 1 == 0 ? 0 : 2),
                          textAlign: TextAlign.right,
                          style: const TextStyle(fontSize: 14, color: AppTheme.secondaryText),
                        ),
                      ),
                    if (!narrow)
                      SizedBox(
                        width: rateW,
                        child: Text(
                          it['rate'] == null ? '—' : _money.format(_n(it['rate'])),
                          textAlign: TextAlign.right,
                          style: const TextStyle(fontSize: 14, color: AppTheme.secondaryText),
                        ),
                      ),
                    SizedBox(
                      width: amtW,
                      child: Text(
                        narrow && _n(it['multiplier']) > 1
                            ? '${_n(it['multiplier']).toStringAsFixed(0)} × ${_money.format(_n(it['rate']))}\n${_money.format(_n(it['total']))}'
                            : _money.format(_n(it['total'])),
                        textAlign: TextAlign.right,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              ),
            const Divider(height: 1, color: AppTheme.strokeBorder),
            moneyRow('Items subtotal', subtotal),
            for (final ch in charges) moneyRow((ch['name'] ?? ch['other_charge'] ?? 'Charge').toString(), signed(ch)),
            if (hasTotal && leftover.abs() > 0.01) moneyRow(_isEstimate ? 'Tax and other charges' : 'Other (not itemized above)', leftover),
            if (hasTotal) moneyRow(_isEstimate ? 'Estimate total' : 'Job total', total, bold: true),
          ],
        ]);
      },
    );
  }
}

/// The Add Note / Add Task dialog. It owns its text box, so the box is only thrown away once the dialog is fully gone
/// (disposing it right after the dialog closes breaks the closing animation).
class _TextDialog extends StatefulWidget {
  final String title;
  final String hint;
  final int maxLength;
  final int maxLines;
  final Future<String?> Function(String text) onSave;
  const _TextDialog({required this.title, required this.hint, required this.maxLength, required this.maxLines, required this.onSave});

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  final _controller = TextEditingController();
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      setState(() => _error = 'Type something first.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final err = await widget.onSave(text);
    if (!mounted) return;
    if (err == null) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _saving = false;
        _error = err;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 480,
        child: TextField(
          controller: _controller,
          autofocus: true,
          enabled: !_saving,
          maxLength: widget.maxLength,
          minLines: widget.maxLines == 1 ? 1 : 4,
          maxLines: widget.maxLines,
          textInputAction: widget.maxLines == 1 ? TextInputAction.done : TextInputAction.newline,
          onSubmitted: widget.maxLines == 1 ? (_) => _save() : null,
          decoration: InputDecoration(hintText: widget.hint, errorText: _error, border: const OutlineInputBorder()),
        ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('Save'),
        ),
      ],
    );
  }
}

extension _Recolor on Widget {
  /// _text() builds Padding(SelectableText); this swaps its colour (used for the green "Paid in full" / red balance).
  Widget withColor(Color color) {
    final self = this;
    if (self is Padding && self.child is SelectableText) {
      final t = self.child as SelectableText;
      return Padding(
        padding: self.padding,
        child: SelectableText(
          t.data ?? '',
          style: (t.style ?? const TextStyle()).copyWith(color: color, fontWeight: FontWeight.w700),
        ),
      );
    }
    return self;
  }
}

/// "Request payment": the office picks an amount, the backend returns a signed Stripe pay link for this job, and the
/// office copies it to the customer. The payment lands on the job by itself once Stripe confirms it.
class _PaymentLinkDialog extends StatefulWidget {
  final String jobId;
  final double total;
  final double balance;
  const _PaymentLinkDialog({required this.jobId, required this.total, required this.balance});

  @override
  State<_PaymentLinkDialog> createState() => _PaymentLinkDialogState();
}

class _PaymentLinkDialogState extends State<_PaymentLinkDialog> {
  final _amount = TextEditingController();
  final _money = NumberFormat.currency(symbol: r'$');
  String _kind = 'custom';
  String? _error;
  String? _url;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Most requests are the 50% deposit or the remaining balance, so start on whichever applies.
    if (widget.balance > 0) {
      _pick('final', widget.balance);
    } else if (widget.total > 0) {
      _pick('deposit', widget.total / 2);
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  void _pick(String kind, double amount) {
    _kind = kind;
    _amount.text = amount.toStringAsFixed(2);
  }

  Future<void> _create() async {
    final amount = double.tryParse(_amount.text.trim());
    if (amount == null || amount < 1) {
      setState(() => _error = 'Enter an amount of at least \$1.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await http
          .post(
            Uri.parse('$kApiBaseUrl/api/jobs/${Uri.encodeComponent(widget.jobId)}/payment-link'),
            headers: AuthSession.instance.headers(),
            body: json.encode({'amount': amount, 'type': _kind}),
          )
          .timeout(const Duration(seconds: 30));
      if (!mounted) return;
      if (res.statusCode == 401) {
        AuthSession.instance.logout(); // sends the app back to the sign-in screen
        return;
      }
      final body = res.body.isEmpty ? <String, dynamic>{} : json.decode(res.body);
      if (res.statusCode >= 200 && res.statusCode < 300 && body is Map && body['url'] != null) {
        setState(() {
          _url = body['url'].toString();
          _busy = false;
        });
      } else {
        setState(() {
          _error = body is Map && body['error'] != null ? body['error'].toString() : 'Could not create the link.';
          _busy = false;
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not reach the server.';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = _url;
    return AlertDialog(
      title: Text('Request payment · Job # ${widget.jobId}'),
      content: SizedBox(
        width: 480,
        child: url != null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Send this link to the customer for ${_money.format(double.tryParse(_amount.text) ?? 0)}:'),
                  const SizedBox(height: 10),
                  SelectableText(url, style: const TextStyle(fontSize: 13, color: AppTheme.secondaryText)),
                  const SizedBox(height: 10),
                  const Text('It stays valid for 30 days. The payment appears on this job once the customer pays.', style: TextStyle(fontSize: 13)),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    children: [
                      if (widget.total > 0)
                        ChoiceChip(
                          label: Text('50% deposit ${_money.format(widget.total / 2)}'),
                          selected: _kind == 'deposit',
                          onSelected: (_) => setState(() => _pick('deposit', widget.total / 2)),
                        ),
                      if (widget.balance > 0)
                        ChoiceChip(
                          label: Text('Balance ${_money.format(widget.balance)}'),
                          selected: _kind == 'final',
                          onSelected: (_) => setState(() => _pick('final', widget.balance)),
                        ),
                      ChoiceChip(
                        label: const Text('Other amount'),
                        selected: _kind == 'custom',
                        onSelected: (_) => setState(() => _kind = 'custom'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _amount,
                    autofocus: true,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                    onChanged: (_) => setState(() => _kind = 'custom'),
                    onSubmitted: (_) => _busy ? null : _create(),
                    decoration: InputDecoration(labelText: 'Amount', prefixText: r'$ ', errorText: _error),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: Text(url == null ? 'Cancel' : 'Close')),
        if (url == null)
          FilledButton(
            onPressed: _busy ? null : _create,
            child: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Create link'),
          )
        else ...[
          TextButton(
            onPressed: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
            child: const Text('Open'),
          ),
          FilledButton(
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              await Clipboard.setData(ClipboardData(text: url));
              messenger
                ..hideCurrentSnackBar()
                ..showSnackBar(const SnackBar(content: Text('Link copied')));
            },
            child: const Text('Copy link'),
          ),
        ],
      ],
    );
  }
}
