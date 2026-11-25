import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderOffstage;
import 'package:flutter/services.dart' show Clipboard, ClipboardData, FilteringTextInputFormatter, LogicalKeyboardKey, TextInputFormatter;
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import 'config/access.dart';
import 'config/api_config.dart';
import 'config/auth_session.dart';
import 'services/line_items_api.dart';
import 'services/tax_settings_api.dart';
import 'theme/app_theme.dart';
import 'utils/charge_presets.dart';
import 'utils/line_item_math.dart';
import 'utils/status_colors.dart';
import 'widgets/app_dialog.dart';
import 'widgets/quo_activity_panel.dart';
import 'widgets/stripe_mark.dart';
import 'widgets/dashboard_data.dart' show DashClock;
import 'widgets/dashboard_kit.dart';
import 'widgets/catalog_search_field.dart' show CatalogSearchRoom;
import 'widgets/dashboard_panels.dart' show DashPressable, DashSegmented;
import 'widgets/file_viewer.dart';
import 'widgets/flat_page.dart' show BannerMenuItem, PageBanner, PageSheet;
import 'widgets/leave_guard.dart';
import 'widgets/line_items_editor.dart';
import 'widgets/ps_menu.dart';
import 'widgets/record_list_view.dart' show recordDeleted;

part 'job_detail_items.dart';

/// The `/jobs/:id` route (a child of `/jobs`). Keyed by the job number: the Jobs section keeps its page alive, and
/// without a key a different job would reuse the old page's state and keep showing the previous job.
GoRoute jobDetailRoute() => GoRoute(
  path: ':id',
  // Back, or a link to another record in the same section, asks first while an editing preview has changes in it.
  onExit: (context, state) => LeaveGuard.confirm(),
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
  /// The gutter between the blocks, the same both ways: the page is one surface cut into blocks, not cards on a backdrop.
  /// The same width as the standard page edge.
  static const double _gap = PageSheet.edge;

  /// A block: plain white, square, no outline. The gutters around it do the separating.
  static const _blockFill = BoxDecoration(color: Colors.white);

  Map<String, dynamic>? _job;
  Map<String, dynamic>? _customer;
  String? _fromEstimate; // for a job: the estimate it most likely came from
  String? _becameJob; // for an estimate: the job it most likely became
  String? _estimateOwner; // for a job: the opportunity owner on the estimate it came from
  Map<String, String> _techPhotos = const {}; // lower-cased tech name -> photo URL, for the tech avatars
  bool _linkConfirmed = false; // recorded by sending an accepted option, not the best guess
  List<Map<String, dynamic>> _invoices = const []; // Service Fusion invoices matched to this job by PO + customer
  final Map<String, bool> _invoiceOpen = {}; // invoice number -> opened/closed on the Payment tab (default: open if it's the only one)
  List<Map<String, dynamic>> _payments = const [];
  List<Map<String, dynamic>> _stripePayments = const []; // see _stripeMatch; no report counts them yet
  List<Map<String, dynamic>> _history = const [];
  List<Map<String, dynamic>> _ourFiles = const []; // pictures + documents uploaded here (not Service Fusion's)
  bool _filesEnabled = true; // false when the backend says file storage isn't set up
  String? _uploadStatus; // "Uploading 2 of 3..." while an upload runs
  List<Map<String, dynamic>> _ourNotes = const []; // notes added in this app (author known)
  List<Map<String, dynamic>> _ourTasks = const []; // tasks added in this app
  bool _loading = true;
  bool _deleting = false; // the Delete request is out
  bool _visitsExpanded = false; // Site Visits shows only the latest few until this is on
  bool _notesExpanded = false; // the Notes section shows only the newest few until this is on
  String? _error;

  /// The last load came back 404: retrying can't help, so the page offers only a way back to the list.
  bool _notFound = false;
  int _detailsTab = 0; // Summary, Pics, Docs, Takeoffs
  int _infoTab = 0; // Scheduling, Payment, Communications, Activity

  // Line items edited here and estimate options (job_detail_items.dart).
  LineItemsState? _lines;
  String? _linesError;
  String? _option; // the estimate option on show, or 'sf' for Service Fusion's own items
  bool _showSfItems = false; // a job with its own items: look at Service Fusion's copy instead
  final Set<String> _dirty = {}; // option ids with changes in the preview
  // Each option's total and margin as its table works them out (its draft's, while the preview changes it), so its tab
  // shows what its totals show.
  final Map<String, (int, double?)> _liveFigures = {};

  // Edit Job / Edit Estimate: a preview. The lines can be changed on screen, nothing is saved or sent anywhere, and
  // Cancel (or leaving the page) puts back what was there.
  bool _editing = false;
  bool _saveAsked = false; // Save was pressed: the bar says saving isn't available
  List<LineDraft>? _editSfLines; // Service Fusion's lines as they were when editing started, so the draft holds still
  List<int>? _editSfAmounts;
  final _itemsKey = GlobalKey(debugLabel: 'line items');

  /// The Products & Services block's inside, and each of its tables, for its outline ([_TableOutlinePainter]).
  final _itemsOutlineKey = GlobalKey(debugLabel: 'line items outline');
  final _tableKeys = <String, GlobalKey>{};
  GlobalKey _tableKeyFor(String id) => _tableKeys.putIfAbsent(id, () => GlobalKey(debugLabel: 'table $id'));
  String? _busy; // an option action in flight
  LineItemsApi get _api => LineItemsApi(widget.jobId);

  final _money = NumberFormat.currency(symbol: r'$');

  /// Removes this page's leave check (see [_confirmLeave]).
  late final VoidCallback _unguard;

  @override
  void initState() {
    super.initState();
    _job = widget.initial;
    _unguard = LeaveGuard.register(canLeave: _confirmLeave, holdsWork: () => mounted && _editing && _dirty.isNotEmpty);
    // The discount and fee presets for Tax, discounts & fees (the built-in list until the saved ones arrive).
    TaxSettingsStore.instance.addListener(_taxSettingsChanged);
    unawaited(TaxSettingsStore.instance.ensureLoaded());
    _load();
  }

  void _taxSettingsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    TaxSettingsStore.instance.removeListener(_taxSettingsChanged);
    _unguard();
    super.dispose();
  }

  /// Leaving the page (any page change in the app) while the editing preview has changes in it asks first. Saving
  /// isn't available yet (the preview is never saved, user rule 2026-11-12), so the choice is to keep editing or to
  /// drop the changes and go. A preview with no changes in it is left without a question.
  Future<bool> _confirmLeave() async {
    if (!mounted || !_editing || _dirty.isEmpty) return true;
    final what = _isEstimate ? 'estimate' : 'job';
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppDialog(
        title: 'Leave without saving?',
        icon: Icons.edit_note_rounded,
        iconColor: DashUi.amber,
        body: Text(
          "You have changes to this $what's products and services. Editing is a preview for now and can't be saved yet, "
          'so leaving this page drops them and puts back what was there.',
          style: const TextStyle(fontSize: 14, color: DashUi.slate, height: 1.45),
        ),
        actions: [
          Focus(autofocus: true, skipTraversal: true, child: AppButton.ghost('Keep editing', () => Navigator.pop(ctx, false))),
          AppButton.ink('Discard changes', () => Navigator.pop(ctx, true), danger: true),
        ],
      ),
    );
    if (leave != true || !mounted) return false;
    _dirty.clear(); // no "Preview closed" note: the person is on their way to another page
    _stopEditing();
    return true;
  }

  /// setState for the part file (setState itself is protected).
  void _set(VoidCallback fn) {
    if (mounted) setState(fn);
  }

  @override
  void didUpdateWidget(JobDetailScreen old) {
    super.didUpdateWidget(old);
    if (old.jobId != widget.jobId) {
      _job = widget.initial;
      _customer = null;
      _fromEstimate = null;
      _becameJob = null;
      _estimateOwner = null;
      _techPhotos = const {};
      _linkConfirmed = false;
      _invoices = const [];
      _invoiceOpen.clear();
      _lines = null;
      _linesError = null;
      _option = null;
      _showSfItems = false;
      _dirty.clear();
      _editing = false;
      _saveAsked = false;
      _editSfLines = null;
      _editSfAmounts = null;
      _payments = const [];
      _stripePayments = const [];
      _history = const [];
      _ourFiles = const [];
      _ourNotes = const [];
      _ourTasks = const [];
      _taskPending.clear();
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
      _notFound = false;
    });
    // Our files and notes only need the job number, so ask for them now instead of after the job comes back.
    unawaited(_loadFiles());
    unawaited(_loadNotesTasks());
    unawaited(_loadLines());
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
          _error = '${_estimatePage ? 'Estimate' : 'Job'} #${widget.jobId} was not found.';
          _notFound = _job == null;
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
        _estimateOwner = data['fromEstimateOwner']?.toString();
        _techPhotos = {
          if (data['techPhotos'] is Map)
            for (final e in (data['techPhotos'] as Map).entries) e.key.toString().trim().toLowerCase(): e.value.toString(),
        };
        _linkConfirmed = data['linkConfirmed'] == true;
        _invoices = rows('invoices');
        _payments = rows('payments');
        _stripePayments = rows('stripePayments');
        _history = rows('history');
        _loading = false;
        // A Refresh during the preview: Service Fusion's lines on show follow what was loaded, unless they were changed
        // in the preview (then the draft stays, as an option's does). Otherwise the table showed the old lines beside
        // the new record's totals.
        if (_editing && !_dirty.contains('sf')) {
          _editSfLines = _sfLines;
          _editSfAmounts = _sfAmounts;
        }
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

  Future<void> _loadLines() async {
    _set(() => _linesError = null);
    try {
      final s = await _api.load();
      _set(() {
        _lines = s;
        _keepOptionInView();
      });
    } on LineItemsException catch (e) {
      _set(() => _linesError = e.message);
    }
  }

  /// After a load or a change, the option on show still exists, or the best one is picked: the accepted one, then
  /// the recommended one, then the first; Service Fusion's items when there are none yet. (Service Fusion's items have
  /// no tab of their own beside options, so they only stay on show once options exist while a preview of them is open.)
  void _keepOptionInView() {
    final opts = _lines?.options ?? const <LineOption>[];
    _dirty.removeWhere((id) => id != 'sf' && !opts.any((o) => o.id == id));
    // The estimate's own option (Service Fusion's lines, "Estimate Option") has a tab of its own now (round 3,
    // 2026-11-13), so once it is on show it stays on show through a reload; it used to be hidden, with no way back to
    // it, as soon as the estimate had an option of ours. Which option opens first is unchanged: the accepted one, the
    // recommended one, the first, or the estimate's own when there are none.
    if (_option == 'sf') return;
    if (_option != null && opts.any((o) => o.id == _option)) return;
    final pick = opts.where((o) => o.accepted).firstOrNull ?? opts.where((o) => o.isRecommended).firstOrNull ?? opts.firstOrNull;
    _option = pick?.id ?? 'sf';
  }

  bool get _canSeeCost => _lines?.canSeeCost ?? AuthSession.instance.can('line_items', AccessAction.view);
  bool get _canEditLines => (_lines?.canEdit ?? false) && AuthSession.instance.can(_isEstimate ? 'estimates' : 'jobs', AccessAction.update);

  // The Team screen's switches for this record (the server checks the same ones). Update covers notes, tasks, pictures
  // and documents; Delete the ribbon's Delete; Payments > Create the Request payment link.
  String get _recordKey => _isEstimate ? 'estimates' : 'jobs';
  bool get _canUpdate => AuthSession.instance.can(_recordKey, AccessAction.update);
  bool get _canDelete => AuthSession.instance.can(_recordKey, AccessAction.delete);
  bool get _canRequestPayment => AuthSession.instance.can('payments', AccessAction.create);

  /// Opens another record's page: an estimate under /estimates, a job under /jobs (so the right nav item stays lit).
  void _openRecord(String id, {required bool estimate}) =>
      LeaveGuard.leave(() => context.go('/${estimate ? 'estimates' : 'jobs'}/${Uri.encodeComponent(id)}'));

  /// Links and lists can't always know whether a number is a job or an estimate (the calendar, dashboard lists). Once the
  /// record is loaded we know, so if the address is in the wrong section, move it to the right one (same page, no flash).
  void _showInRightSection() {
    final router = GoRouter.maybeOf(context);
    if (router == null || _job == null) return;
    final path = router.routerDelegate.currentConfiguration.uri.path;
    // Only for the page on show: a page kept alive in another section (the nav keeps each section's last page) that
    // finishes loading late must not pull the person back to it.
    if (path != '/jobs/${Uri.encodeComponent(widget.jobId)}' && path != '/estimates/${Uri.encodeComponent(widget.jobId)}') return;
    final wrongSection = (_isEstimate && path.startsWith('/jobs/')) || (!_isEstimate && path.startsWith('/estimates/'));
    if (wrongSection) router.go('/${_isEstimate ? 'estimates' : 'jobs'}/${Uri.encodeComponent(widget.jobId)}', extra: _job);
  }

  // ---- helpers --------------------------------------------------------------

  String _s(String key) => (_job?[key] ?? '').toString().trim();

  static double _n(dynamic v) => double.tryParse(v?.toString() ?? '') ?? 0;

  /// One date style for the whole page: "Oct 6, 2026", the same as the payments, notes and invoices (audit 2026-11-24,
  /// item 11: it was "10/06/2026" here beside the banner's "Tue, Oct 6").
  static final _dateFmt = DateFormat('MMM d, y');

  static DateTime? _ymd(dynamic v) {
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(v?.toString() ?? '');
    if (m == null) return null;
    return DateTime(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
  }

  String _date(dynamic v) {
    final d = _ymd(v);
    return d == null ? '' : _dateFmt.format(d);
  }

  /// "Oct 6 – Oct 7, 2026" (the year once when both days share it), "Dec 30, 2026 – Jan 2, 2027", or one day.
  String _dateRange(dynamic from, dynamic to) {
    final a = _ymd(from);
    final b = _ymd(to);
    if (a == null) return '';
    if (b == null || b == a) return _dateFmt.format(a);
    return a.year == b.year ? '${DateFormat('MMM d').format(a)} – ${_dateFmt.format(b)}' : '${_dateFmt.format(a)} – ${_dateFmt.format(b)}';
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
    return Scaffold(
      backgroundColor: AppTheme.bgColor,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _banner(),
          // The loading bar floats over the top of the body, so the blocks start right under the ribbon. Nothing on the
          // page shades under the pointer (USER RULE 2026-11-24, as on the Details screens): see [_noHoverShading].
          Expanded(
            child: Theme(
              data: _noHoverShading(Theme.of(context)),
              child: Stack(
              children: [
                Positioned.fill(child: job == null ? _bodyWithoutJob() : _content(job)),
                if (_loading)
                  const Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: LinearProgressIndicator(minHeight: 3, color: DashUi.ink, backgroundColor: DashUi.line),
                  ),
              ],
            ),
            ),
          ),
        ],
      ),
    );
  }

  /// The app's theme with nothing shading under the pointer (USER RULE 2026-11-24: "there should be no hover shading on
  /// the job or estimate screens ... it's pointless to shade here"): ink wells, and the text, filled, outlined and icon
  /// buttons, keep their press and keyboard-focus feedback but no hover tint. The pointer cursor says what can be clicked.
  static ThemeData _noHoverShading(ThemeData t) {
    final overlay = WidgetStateProperty.resolveWith<Color?>((s) {
      if (s.contains(WidgetState.pressed)) return DashUi.ink.withValues(alpha: 0.08);
      if (s.contains(WidgetState.focused)) return DashUi.ink.withValues(alpha: 0.08);
      return Colors.transparent;
    });
    ButtonStyle quiet(ButtonStyle? s) => (s ?? const ButtonStyle()).copyWith(overlayColor: overlay);
    return t.copyWith(
      hoverColor: Colors.transparent,
      textButtonTheme: TextButtonThemeData(style: quiet(t.textButtonTheme.style)),
      filledButtonTheme: FilledButtonThemeData(style: quiet(t.filledButtonTheme.style)),
      outlinedButtonTheme: OutlinedButtonThemeData(style: quiet(t.outlinedButtonTheme.style)),
      elevatedButtonTheme: ElevatedButtonThemeData(style: quiet(t.elevatedButtonTheme.style)),
      iconButtonTheme: IconButtonThemeData(style: quiet(t.iconButtonTheme.style)),
    );
  }

  /// Before the record loads it may only be known from the address whether this is an estimate.
  bool get _estimatePage {
    if (_job != null) return _isEstimate;
    final router = GoRouter.maybeOf(context);
    return router != null && router.routerDelegate.currentConfiguration.uri.path.startsWith('/estimates/');
  }

  /// The standard ribbon: "JOB # 123" with the Jobs (or Estimates) menu icon and Refresh. The matching record is a
  /// link in the Summary block, right above PO # (user 2026-11-24).
  Widget _banner() {
    final estimate = _estimatePage;
    return PageBanner(
      title: '${estimate ? 'Estimate' : 'Job'} # ${widget.jobId}',
      icon: accessIcon(estimate ? 'estimates' : 'jobs'),
      actions: [
        // Opens the line items for a preview edit (job_detail_items.dart). Same switch as before: Jobs/Estimates Update.
        if (_job != null && _canEditLines)
          PageBanner.button(
            icon: Icons.edit_outlined,
            label: _editing ? 'Editing' : (estimate ? 'Edit Estimate' : 'Edit Job'),
            onPressed: _editing ? null : _startEditing,
          ),
        // Less-used actions under More (user 2026-11-13). Delete is for a record that was deleted in Service Fusion: the
        // Jobs (or Estimates) Delete switch; the server checks too.
        if (_job != null && _canDelete)
          PageBanner.more(
            label: _deleting ? 'Deleting…' : 'More',
            items: [
              BannerMenuItem(
                icon: Icons.delete_outline_rounded,
                label: estimate ? 'Delete estimate' : 'Delete job',
                danger: true,
                onPressed: _deleting ? null : _deleteRecord,
              ),
            ],
          ),
        PageBanner.refresh(onPressed: _loading ? null : _load),
      ],
    );
  }

  Widget _bodyWithoutJob() {
    if (_loading) return _skeletonPage();
    final estimate = _estimatePage;
    final kind = estimate ? 'estimate' : 'job';
    final list = estimate ? 'estimates' : 'jobs';
    return Padding(
      padding: const EdgeInsets.all(24),
      child: DashErrorPanel(
        icon: _notFound ? Icons.search_off_rounded : Icons.cloud_off_rounded,
        title: _notFound ? '${estimate ? 'Estimate' : 'Job'} #${widget.jobId} was not found' : "This $kind couldn't be loaded",
        message: _notFound
            ? 'It may have been deleted, or the number is wrong.'
            : (_error ?? 'Something went wrong.'),
        hint: _notFound ? null : 'Check your connection, then try again.',
        onRetry: _notFound ? null : _load,
        action: AppButton.ghost('Back to $list', () => context.go('/$list')),
      ),
    );
  }

  Widget _content(Map<String, dynamic> job) {
    final status = _s('status').isEmpty ? 'No status' : _s('status');
    final subStatus = _s('sub_status');
    final notes = _s('notes');

    final contact = _s('contact_name');
    final cust = _customer;
    final custPhone = (cust?['phone'] ?? '').toString().trim();
    final custEmail = (cust?['email'] ?? '').toString().trim();
    final custContact = (cust?['primary_contact'] ?? '').toString().trim();
    // The phone and email belong to the customer's primary contact, so only attach them when that is this job's contact.
    final sameContact = contact.isEmpty || custContact.toLowerCase() == contact.toLowerCase();

    final summaryRows = <Widget>[
      _factRow(
        Icons.business_rounded,
        'Customer',
        _s('customer_name').isEmpty ? null : _factLink(_s('customer_name'), _openCustomer, tip: 'Find this customer', strong: true),
      ),
      _factRow(
        Icons.person_outline_rounded,
        'Primary contact',
        copy: sameContact && custPhone.isNotEmpty ? (custPhone, 'phone number') : null,
        (contact.isEmpty && custContact.isEmpty)
            ? null
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _factText(contact.isEmpty ? custContact : contact),
                  if (sameContact && custPhone.isNotEmpty)
                    _factLink(custPhone, () => _launch(_telUri(custPhone)), tip: 'Call', icon: Icons.call_outlined),
                  if (sameContact && custEmail.isNotEmpty)
                    _factLink(
                      custEmail,
                      () => _launch(Uri(scheme: 'mailto', path: custEmail)),
                      tip: 'Send an email',
                      icon: Icons.mail_outline_rounded,
                    ),
                  if (!sameContact && custContact.isNotEmpty)
                    _factText('Customer main contact: $custContact${custPhone.isEmpty ? '' : '  ·  $custPhone'}', quiet: true),
                ],
              ),
      ),
      _factRow(
        Icons.home_rounded,
        'Service location',
        _s('location').isEmpty
            ? null
            : _factLink(_s('location'), () => _launch(_mapsUri(_s('location'))), tip: 'Open in Google Maps', icon: Icons.map_outlined),
      ),
      _factRow(
        Icons.assignment_outlined,
        _isEstimate ? 'Description' : 'Job description',
        _s('description').isEmpty ? null : _factText(_s('description')),
      ),
      // Only when there is one: an estimate's job, or a job's estimate. Opens it like the other blue links.
      if (_matchId != null)
        _factRow(
          _isEstimate ? Icons.build_rounded : Icons.request_quote_rounded,
          _isEstimate ? 'Became job' : 'Matching estimate',
          _factLink('#$_matchId', () => _openRecord(_matchId!, estimate: !_isEstimate), tip: _isEstimate ? 'Open the job' : 'Open the estimate'),
        ),
      _factRow(
        Icons.edit_note_rounded,
        'PO #',
        _s('po_number').isEmpty ? null : _factText(_s('po_number')),
        copy: _s('po_number').isEmpty ? null : (_s('po_number'), 'PO number'),
      ),
      _factRow(Icons.folder_open_rounded, _isEstimate ? 'Category' : 'Job category', _s('category').isEmpty ? null : _factText(_s('category'))),
      // The sales owner is in Job Info (Scheduling / Sales data) only: it was here too, under a second name (audit
      // 2026-11-24, item 14).
      _tasksSection(),
    ];
    final detailsPanel = _detailsBlock(
      switch (_detailsTab) {
        1 => _picsRows(),
        2 => _docsRows(),
        3 => [
          _detailsEmpty(
            Icons.straighten_rounded,
            'No takeoffs yet',
            'Material and labor takeoffs for this $_kind will show here once they are built.',
            tone: DashUi.indigo,
          ),
        ],
        4 => [
          if (AuthSession.instance.canUseCommunications(AccessAction.view))
            QuoActivityPanel(key: ValueKey('quo-job-${widget.jobId}'), jobId: widget.jobId)
          else
            _noAccess('Calls and texts are switched off for you. An admin can turn them on in Team.'),
        ],
        _ => summaryRows,
      },
      tabs: [
        const _DetailTab('Summary', Icons.format_list_bulleted_rounded),
        _DetailTab('Pics', Icons.photo_camera_outlined, count: (_files('pictures')?.length ?? 0) + _ourFiles.where((f) => f['kind'] == 'pic').length),
        _DetailTab('Docs', Icons.description_outlined, count: (_files('documents')?.length ?? 0) + _ourFiles.where((f) => f['kind'] == 'doc').length),
        const _DetailTab('Takeoffs', Icons.straighten_rounded),
        const _DetailTab('Communications', Icons.forum_outlined),
      ],
    );

    final start = _date(job['start_date']);
    final dates = _dateRange(job['start_date'], job['end_date']);
    final techs = _s('techs_assigned');
    final window = _window(_sf['time_frame_promised_start'], _sf['time_frame_promised_end']);
    final duration = _duration(_sf['duration']);
    final priority = (_sf['priority'] ?? '').toString().trim();
    final requested = _date(job['sf_created_at']);
    final referral = (_sf['source'] ?? '').toString().trim();
    final rating = (_sf['opportunity_rating'] ?? '').toString().trim();
    // The sales owner (Service Fusion's opportunity owner), under one name on both kinds of record (audit 2026-11-24,
    // item 14). A job shows its estimate's, or its own when the server didn't send the estimate's.
    final salesOwner = !_isEstimate && (_estimateOwner ?? '').trim().isNotEmpty ? _estimateOwner!.trim() : _s('opportunity_owner');
    final salesOwnerRow = _sfRow(Icons.hail_rounded, 'Sales owner', salesOwner.isEmpty ? null : _factText(salesOwner));
    // The on-site visit on one line, like a visit row: "Oct 6, 2026  ·  8:00 AM – 10:00 AM (1h)".
    final visitLine = [start, [window, if (duration.isNotEmpty) '($duration)'].where((e) => e.isNotEmpty).join('  ')]
        .where((e) => e.isNotEmpty)
        .join('  ·  ');
    // Estimates mirror Service Fusion's "Sales Data" block; jobs keep the scheduling block.
    final salesRows = <Widget>[
      _sfRow(Icons.calendar_today_rounded, 'Requested on', requested.isEmpty ? null : _factText(requested)),
      _sfRow(
        Icons.emoji_events_outlined,
        'Current status',
        Wrap(
          spacing: 10,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [_statusPill(status, sub: false), _statusPill(subStatus, sub: true)],
        ),
      ),
      _sfRow(Icons.signpost_outlined, 'Referral source', referral.isEmpty ? null : _factText(referral)),
      _sfRow(Icons.star_rounded, 'Opportunity rating', rating.isEmpty ? null : _factText(rating)),
      salesOwnerRow,
      _sfRow(Icons.event_rounded, 'On-site visit', visitLine.isEmpty ? null : _factText(visitLine)),
      _sfRow(Icons.engineering_outlined, 'Assigned techs', _techsValue(techs)),
      _sfRow(Icons.sticky_note_2_outlined, 'Notes for techs', notes.isEmpty ? null : _factText(notes)),
    ];
    final timing = _isEstimate ? null : _timingBanner(job);
    final schedulingRows = <Widget>[
      _sfRow(
        Icons.flag_outlined,
        'Current status',
        Wrap(
          spacing: 10,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [_statusPill(status, sub: false), _statusPill(subStatus, sub: true)],
        ),
      ),
      _sfRow(Icons.event_rounded, _isEstimate ? 'Estimate date' : 'Start & end dates', start.isEmpty ? null : _factText(_isEstimate ? start : dates)),
      if (!_isEstimate && _day(job['closed_at']) != null) _sfRow(Icons.event_available_rounded, 'Closed', _factText(_date(job['closed_at']))),
      _sfRow(Icons.schedule_rounded, 'Arrival time window', window.isEmpty ? null : _factText(window)),
      _sfRow(Icons.timelapse_rounded, 'Estimated duration', duration.isEmpty ? null : _factText(duration)),
      _sfRow(Icons.priority_high_rounded, 'Job priority', priority.isEmpty ? null : _factText(priority)),
      _sfRow(Icons.engineering_outlined, 'Assigned techs', _techsValue(techs)),
      if (!_isEstimate) salesOwnerRow,
      _sfRow(Icons.sticky_note_2_outlined, 'Notes for techs', notes.isEmpty ? null : _factText(notes)),
      // An estimate has no visits to show: don't draw an empty "Site Visits (0)" box on it.
      if (!(_isEstimate && _sfVisits.isEmpty)) _visitsSection(),
    ];
    final infoPanel = _tabbedBlock(
      _isEstimate ? 'Estimate Info' : 'Job Info',
      switch (_infoTab) {
        1 => _paymentRows(job),
        2 => _activityRows(),
        _ => _isEstimate ? salesRows : schedulingRows,
      },
      tabs: [
        _DetailTab(_isEstimate ? 'Sales data' : 'Scheduling', Icons.calendar_month_rounded),
        _DetailTab('Payment', Icons.payments_outlined, count: _payments.length + _stripeMatch.unmatched.length),
        const _DetailTab('Activity', Icons.view_headline_rounded),
      ],
      selected: _infoTab,
      onSelect: (i) => setState(() => _infoTab = i),
      divided: _infoTab == 0,
      lead: switch (_infoTab) {
        0 => timing,
        1 => _isEstimate ? null : _paidSummary(job),
        _ => null,
      },
    );

    // Its own card under Details, outside the tabs, so the notes stay up whichever tab is open.
    final notesCard = Container(decoration: _blockFill, child: _notesSection());

    // A full page, edge to edge like the other full pages: square white blocks that run to the window's edges, split by
    // thin gutters instead of floating as cards. Below the ribbon the page is all blocks, with no margin around them.
    return LayoutBuilder(
      builder: (context, constraints) {
        return ListView(
          // No outer margin at all: the blocks, and their grey title ribbons, run to the same left and right edges as the
          // navy job ribbon above them (user 2026-11-24: "make the gray section ribbon extend edge-to-edge"). The space
          // for the content is inside each block (its 20 px side padding).
          padding: EdgeInsets.zero,
          children: [
            // A Refresh that failed after the record had loaded: a block of its own, square and edge to edge like the
            // others (audit 2026-11-24, item 23: it was a rounded card with its own margins).
            if (_error != null) ...[
              Container(
                padding: const EdgeInsets.fromLTRB(20, 6, 12, 6),
                constraints: const BoxConstraints(minHeight: 48),
                decoration: BoxDecoration(
                  color: Color.alphaBlend(DashUi.amber.withValues(alpha: 0.08), Colors.white),
                  border: Border(bottom: BorderSide(color: DashUi.amber.withValues(alpha: 0.30))),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded, size: 18, color: DashUi.amberText),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        "Couldn't refresh. $_error Showing what was loaded before.",
                        style: const TextStyle(fontSize: 13.5, color: DashUi.ink, height: 1.35),
                      ),
                    ),
                    const SizedBox(width: 12),
                    TextButton.icon(
                      onPressed: _loading ? null : _load,
                      style: TextButton.styleFrom(
                        foregroundColor: DashUi.ink,
                        visualDensity: VisualDensity.compact,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ).copyWith(overlayColor: dashNoHoverOverlay),
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('Retry', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: _gap),
            ],
            LayoutBuilder(
              builder: (context, c) {
                final wide = c.maxWidth >= 900;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (wide)
                      // Each block ends where its content ends: no white padding under the shorter column just to
                      // line its bottom up with the other one (user, 2026-11-12).
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [detailsPanel, const SizedBox(height: _gap), notesCard],
                            ),
                          ),
                          // The gutter between the sections stays (user 2026-11-24): only the outer margin went.
                          const SizedBox(width: _gap),
                          Expanded(child: infoPanel),
                        ],
                      )
                    else ...[
                      detailsPanel,
                      const SizedBox(height: _gap),
                      notesCard,
                      const SizedBox(height: _gap),
                      infoPanel,
                    ],
                    const SizedBox(height: _gap),
                    _isEstimate ? _proposalPanel() : _jobItemsPanel(),
                    // While "Add a line" has the keyboard there is page under it, so its results open in full (they
                    // were cut to about three rows when it sat at the window's bottom: audit 2026-11-24). Nothing
                    // while it doesn't.
                    const CatalogSearchRoom(),
                  ],
                );
              },
            ),
          ],
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
    return '$a – $b'; // an en dash, as in every range on the page
  }

  /// Service Fusion sends durations in seconds: 3600 -> "1h", 5400 -> "1h 30m".
  String _duration(dynamic secs) {
    final n = int.tryParse(secs?.toString() ?? '') ?? 0;
    if (n <= 0) return '';
    final h = n ~/ 3600;
    final m = (n % 3600) ~/ 60;
    return [if (h > 0) '${h}h', if (m > 0) '${m}m'].join(' ');
  }

  /// A tech: their photo (initials when there is none) ringed in their Service Fusion status colour, the name, and the
  /// status pill.
  Widget _techChip(String name, String status) {
    final tone = status.isEmpty ? DashUi.subtle : statusColor(status);
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        DashAvatar(name: name, imageUrl: _techPhotos[name.trim().toLowerCase()] ?? '', size: 26, accent: tone, ringColor: tone, ringWidth: 2),
        Text(
          name,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: DashUi.ink),
        ),
        if (status.isNotEmpty) _visitPill(status),
      ],
    );
  }

  /// A tech's status on a visit, drawn like the Android app's visit pill (StatusStyle.applyPill): a dot in the status's own
  /// colour, then the words in a darkened shade of it, on a 12% tint of it. No solid fill, so a neon green or bright amber
  /// is a point of colour instead of a block.
  Widget _visitPill(String status) {
    final accent = statusColor(status);
    final fill = Color.alphaBlend(accent.withValues(alpha: 31 / 255), Colors.white);
    double contrast(Color a, Color b) {
      final l1 = a.computeLuminance(), l2 = b.computeLuminance();
      return (math.max(l1, l2) + 0.05) / (math.min(l1, l2) + 0.05);
    }

    // Same rule as Android's StatusStyle.textColor: darken bright colours by half, then keep going until it clears 4.5:1.
    var text = accent.computeLuminance() > 0.2 ? Color.lerp(accent, Colors.black, 0.5)! : accent;
    for (var i = 0; i < 10 && contrast(text, fill) < 4.5; i++) {
      text = Color.lerp(text, Colors.black, 0.12)!;
    }
    final label = status.trim().toLowerCase().split(' ').map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}').join(' ');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 7, height: 7, decoration: BoxDecoration(color: accent, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(color: text, fontWeight: FontWeight.w600, fontSize: 12.5)),
        ],
      ),
    );
  }

  /// Techs with their Service Fusion status tag when we have it, else the plain list of names.
  Widget _techsValue(String fallback) {
    final list = _sf['techs'];
    final techs = list is List && list.isNotEmpty
        ? [for (final t in list.whereType<Map>()) ((t['name'] ?? '').toString(), (t['status'] ?? '').toString())]
        : [
            for (final n in fallback.split(','))
              if (n.trim().isNotEmpty) (n.trim(), ''),
          ];
    if (techs.isEmpty) return _factText('Unassigned', quiet: true);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [for (final t in techs) Padding(padding: const EdgeInsets.only(bottom: 6), child: _techChip(t.$1, t.$2))],
    );
  }

  // ---- timing ---------------------------------------------------------------------------------------------------

  /// A record date as a calendar day. Service Fusion's pre-2015 placeholders (closed_at is 1970 on open jobs) are none.
  DateTime? _day(dynamic v) {
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(v?.toString() ?? '');
    if (m == null) return null;
    final d = DateTime(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
    return d.year < 2015 ? null : d;
  }

  DateTime get _today {
    final n = DashClock.now();
    return DateTime(n.year, n.month, n.day);
  }

  /// Whole days from [a] to [b] (negative when [b] is earlier), immune to daylight-saving hours.
  static int _daysFrom(DateTime a, DateTime b) => DateTime.utc(b.year, b.month, b.day).difference(DateTime.utc(a.year, a.month, a.day)).inDays;

  /// "1 day", "12 days", "3 months": the same wording as Collections.
  static String _span(int days) {
    if (days == 1) return '1 day';
    if (days < 60) return '$days days';
    if (days < 730) return '${(days / 30.4).round()} months';
    return '${(days / 365).floor()} years';
  }

  static final _dayFmt = DateFormat('EEE, MMM d');

  /// Where the job stands in time, at the top of Scheduling: closed, on site today, starting soon, finished but not
  /// closed, or not scheduled. Visits count too, so a return trip after the job's dates reads "Next visit in 4 days".
  Widget _timingBanner(Map<String, dynamic> job) {
    final today = _today;
    final start = _day(job['start_date']);
    final end = _day(job['end_date']) ?? start;
    final rawClosed = _day(job['closed_at']);
    // Service Fusion leaves closed_at empty (or a 1970 placeholder) on many jobs that are already Paid & Closed, so the
    // status counts as closed too; otherwise the banner says "Not closed yet" under a Paid & Closed status.
    final closed = rawClosed != null && rawClosed.year >= 2015 ? rawClosed : null;
    final statusClosed = const {'paid & closed', 'paid in full', 'close job', 'google review sent'}
        .contains('${job['status'] ?? ''}'.trim().toLowerCase());
    final visits = [for (final v in _sfVisits) ?_day(v['start_date'])]..sort();
    final window = _window(_sf['time_frame_promised_start'], _sf['time_frame_promised_end']);
    String dates() =>
        start == null ? '' : (end == null || end == start ? _dayFmt.format(start) : '${_dayFmt.format(start)} – ${_dayFmt.format(end)}');
    String join(List<String> parts) => parts.where((p) => p.isNotEmpty).join('  ·  ');

    if (closed != null) {
      final d = _daysFrom(closed, today);
      return _TimingBanner(
        tone: DashUi.emeraldDeep,
        icon: Icons.task_alt_rounded,
        headline: d <= 0 ? 'Closed today' : (d == 1 ? 'Closed yesterday' : 'Closed ${_span(d)} ago'),
        detail: join(['Closed ${_dayFmt.format(closed)}', if (dates().isNotEmpty) 'Worked ${dates()}']),
      );
    }
    if (statusClosed) {
      return _TimingBanner(
        tone: DashUi.emeraldDeep,
        icon: Icons.task_alt_rounded,
        headline: 'Closed',
        detail: join([if (dates().isNotEmpty) 'Worked ${dates()}']),
      );
    }
    final inDates = start != null && end != null && _daysFrom(start, today) >= 0 && _daysFrom(today, end) >= 0;
    if (inDates || visits.any((v) => _daysFrom(v, today) == 0)) {
      final total = start != null && end != null ? _daysFrom(start, end) + 1 : 1;
      return _TimingBanner(
        tone: DashUi.blue,
        icon: Icons.construction_rounded,
        live: true,
        headline: 'On site today',
        detail: join([if (inDates && total > 1) 'Day ${_daysFrom(start, today) + 1} of $total', window]),
      );
    }
    final ahead = [?start, ...visits].where((d) => _daysFrom(today, d) > 0).toList()..sort();
    if (ahead.isNotEmpty) {
      final next = ahead.first;
      final d = _daysFrom(today, next);
      final started = start != null && _daysFrom(start, today) > 0;
      final what = started ? 'Next visit' : 'Starts';
      return _TimingBanner(
        tone: DashUi.indigo,
        icon: Icons.event_available_rounded,
        headline: d == 1 ? '$what tomorrow' : '$what in ${_span(d)}',
        detail: join([started ? _dayFmt.format(next) : dates(), window]),
      );
    }
    final last = [?end, ...visits].fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);
    if (last != null) {
      final d = _daysFrom(last, today);
      return _TimingBanner(
        tone: DashUi.amber,
        icon: Icons.pending_actions_rounded,
        headline: d == 1 ? 'Work finished yesterday' : 'Work finished ${_span(d)} ago',
        detail: join([dates(), 'Not closed yet']),
      );
    }
    return const _TimingBanner(tone: DashUi.amber, icon: Icons.event_busy_rounded, headline: 'Not scheduled yet', detail: 'No start date set');
  }

  /// The status or sub-status, read-only. Changing it isn't saved anywhere yet (nothing is written to the database or
  /// Service Fusion), so this shows the value only, as the same pill as a tech's status on a visit (user, 2026-11-12),
  /// and "Not set" when there is none. Bring back a picker once saving exists.
  Widget _statusPill(String current, {required bool sub}) {
    final has = current.trim().isNotEmpty && current != 'No status';
    if (has) return Semantics(label: '${sub ? 'Sub-status' : 'Status'}: $current', child: _visitPill(current));
    return const Text('Not set', style: TextStyle(fontSize: 13, color: DashUi.subtle));
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
  void _openCustomer() => LeaveGuard.leave(() => context.go('/customers?q=${Uri.encodeQueryComponent(_s('customer_name'))}'));

  /// Money actually received and recorded on the job: the same transaction types Collections counts as cash.
  double get _paid => _payments.fold<double>(0, (s, p) {
    final t = (p['transaction_type'] ?? '').toString().toUpperCase();
    return const {'PAYMENT', 'AUTH_CAPTURE', 'REFUND'}.contains(t) ? s + _n(p['amount']) : s;
  });

  /// "$950.00" in red while something is owed, a green "Paid in full" once the payments on file (Stripe's included)
  /// cover the total, the matched invoice's state when Service Fusion moved the balance to an invoice, or "No payment on
  /// file" when Service Fusion shows $0 due but nothing says it was paid. Worked out by [_moneyState].
  Widget _balanceText(Map<String, dynamic> job) {
    final m = _moneyState(job);
    if (m.total <= 0) {
      final due = _n(job['due_total']);
      return _text(_money.format(due)).withColor(due > 0.005 ? DashUi.redText : AppTheme.primaryText);
    }
    // Money owed is red everywhere on the page, and overpaid reads "Overpaid by $X" everywhere (audit 2026-11-24,
    // items 15 and 16).
    return switch (m.state) {
      'owed' => _text(_money.format(m.owed)).withColor(DashUi.redText),
      'paid' when m.over > 0.005 => _text(_overpaid(m.over), link: false).withColor(DashUi.amberText),
      'paid' => _text('Paid in full', link: false).withColor(AppTheme.successGreen),
      'invoice-paid' => _text('Paid (invoice #${m.invoice!['number']})', link: false).withColor(AppTheme.successGreen),
      'invoice-owed' => _text('${_money.format(m.owed)} on invoice #${m.invoice!['number']}, unpaid').withColor(DashUi.redText),
      _ when m.paid > 0.005 => _text('${_money.format(0)} (only ${_money.format(m.paid)} paid on file)', muted: true),
      _ => _text('${_money.format(0)} (no payment on file)', muted: true),
    };
  }

  /// Placeholder blocks shaped like the page, shown while a job opened by its address (no row to show yet) loads: Details
  /// and Notes on the left, Job Info on the right, Products & Services under them, each with its grey title band, so the
  /// page doesn't jump when it arrives (audit 2026-11-24, item 26).
  Widget _skeletonPage() {
    Widget bar(double w, double h) => Container(
      width: w,
      height: h,
      decoration: BoxDecoration(color: DashUi.line, borderRadius: BorderRadius.circular(6)),
    );
    // The grey title band every block opens with (see [_tabbedBlock]), with the title's place and, for the tabbed
    // blocks, the tab track's.
    Widget band({bool tabs = true}) => Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: const BoxDecoration(
        color: DashUi.faint,
        border: Border(bottom: BorderSide(color: DashUi.line)),
      ),
      child: Row(
        children: [
          bar(110, 14),
          const SizedBox(width: 16),
          Expanded(child: Align(alignment: Alignment.centerRight, child: tabs ? bar(220, 32) : null)),
        ],
      ),
    );
    Widget block({required int rows, bool tabs = true}) => Container(
      decoration: _blockFill,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          band(tabs: tabs),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
            child: Column(
              children: [
                for (var i = 0; i < rows; i++) ...[
                  Row(
                    children: [
                      bar(130, 12),
                      const SizedBox(width: 24),
                      Expanded(child: bar(double.infinity, 12)),
                    ],
                  ),
                  const SizedBox(height: 22),
                ],
              ],
            ),
          ),
        ],
      ),
    );
    final details = block(rows: 7);
    final notes = block(rows: 2, tabs: false);
    final info = block(rows: 9);
    final items = block(rows: 4, tabs: false);
    // The same edge-to-edge blocks and gutters as the page itself. It never scrolls; whatever doesn't fit is cut off.
    return LayoutBuilder(
      builder: (context, c) => SkeletonPulse(
        child: SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (c.maxWidth >= 900)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [details, const SizedBox(height: _gap), notes],
                      ),
                    ),
                    const SizedBox(width: _gap),
                    Expanded(child: info),
                  ],
                )
              else ...[
                details,
                const SizedBox(height: _gap),
                notes,
                const SizedBox(height: _gap),
                info,
              ],
              const SizedBox(height: _gap),
              items,
            ],
          ),
        ),
      ),
    );
  }

  /// How wide [text] lays out in [style] at the window's text size.
  static double _textWidth(BuildContext context, String text, TextStyle style) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: DefaultTextStyle.of(context).style.merge(style)),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final w = tp.width;
    tp.dispose();
    return w.ceilToDouble();
  }

  Widget _text(String v, {bool link = false, bool muted = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 2),
    child: SelectableText(
      v,
      style: TextStyle(fontSize: 14, height: 1.3, color: link ? DashUi.blue : (muted ? AppTheme.sectionLabel : AppTheme.primaryText)),
    ),
  );


  // ---- the Details block -----------------------------------------------------------------------------------------

  /// The Details block: a white panel with its title and the standard sliding tabs flush right (under the title on a
  /// narrow block), then the open tab's rows, which cross-fade in when the tab changes.
  Widget _detailsBlock(List<Widget> rows, {required List<_DetailTab> tabs}) =>
      _tabbedBlock('Details', rows, tabs: tabs, selected: _detailsTab, onSelect: (i) => setState(() => _detailsTab = i), divided: _detailsTab == 0);

  /// The Details and Job Info blocks' shared frame. [divided] draws hairlines between the rows (fact lists, not
  /// galleries or timelines). [lead] is a summary card drawn above the rows (the job's timing, how much is paid).
  Widget _tabbedBlock(
    String heading,
    List<Widget> rows, {
    required List<_DetailTab> tabs,
    required int selected,
    required ValueChanged<int> onSelect,
    required bool divided,
    Widget? lead,
  }) {
    final still = MediaQuery.disableAnimationsOf(context);
    Widget tabBar({bool compact = false}) =>
        _DetailTabs(tabs: tabs, selected: selected, compact: compact, label: '$heading view', onSelect: onSelect);
    // The same grey band as Products & Services (user 2026-11-24: "make the job info and details banners the same gray
    // ribbon too"): the title in 15 px capitals on DashUi.faint, tabs flush right.
    final title = Text(
      heading.toUpperCase(),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: DashUi.ink, letterSpacing: 0.9, height: 1.2),
    );
    return Container(
      decoration: _blockFill,
      clipBehavior: Clip.hardEdge,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, c) {
              // Measured, not a fixed width: the tabs keep their names whenever they fit, beside the title when there
              // is room and under it when not, and drop to icons only when even a full row is too narrow. Never
              // scaled down (at large text sizes a FittedBox shrank them to unreadable).
              final room = c.maxWidth - 40;
              final full = _DetailTabs.fullWidth(context, tabs);
              final inline = full + 16 + _textWidth(context, title.data!, title.style!) <= room;
              final compact = !inline && full > room;
              // Edge to edge across the block (user 2026-11-24: "make the header extend the full block"), square, with a
              // hairline under it.
              return Container(
                constraints: const BoxConstraints(minHeight: 48),
                alignment: Alignment.centerLeft,
                padding: EdgeInsets.symmetric(horizontal: 20, vertical: inline ? 4 : 10),
                decoration: const BoxDecoration(
                  color: DashUi.faint,
                  border: Border(bottom: BorderSide(color: DashUi.line)),
                ),
                child: inline
                    ? Row(
                        children: [
                          Flexible(child: title),
                          const SizedBox(width: 16),
                          const Spacer(),
                          tabBar(),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          title,
                          const SizedBox(height: 10),
                          SingleChildScrollView(scrollDirection: Axis.horizontal, child: tabBar(compact: compact)),
                        ],
                      ),
              );
            },
          ),
          AnimatedSwitcher(
            duration: still ? Duration.zero : const Duration(milliseconds: 220),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            layoutBuilder: (current, previous) => Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
            child: Column(
              key: ValueKey('$heading-tab-$selected'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (lead != null) _RiseIn(index: 0, child: lead),
                for (var i = 0; i < rows.length; i++) ...[
                  if (i > 0 && divided) const Divider(height: 1, indent: 20, endIndent: 20, color: DashUi.line),
                  _RiseIn(index: lead == null ? i : i + 1, child: rows[i]),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// A Summary row: icon and label on the left, the value beside them (under them on a narrow block). The row lights
  /// up softly under the pointer.
  Widget _factRow(IconData icon, String label, Widget? value, {(String, String)? copy}) {
    final shown = value ?? _factText('Not set', quiet: true);
    return _HoverRow(
      builder: (hover) => LayoutBuilder(
        builder: (context, c) {
          final stacked = c.maxWidth < 460;
          Widget copyButton() {
            final (text, what) = copy!;
            return _CopyValue(
              text: text,
              what: what,
              visible: hover,
              onCopy: () async {
                await Clipboard.setData(ClipboardData(text: text));
                _say('Copied $text');
              },
            );
          }
          final labelRow = Row(
            children: [
              Icon(icon, size: 18, color: DashUi.subtle),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: DashUi.slate),
                ),
              ),
            ],
          );
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: stacked
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      labelRow,
                      const SizedBox(height: 4),
                      Padding(
                        padding: const EdgeInsets.only(left: 28),
                        child: copy == null ? shown : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: shown), copyButton()]),
                      ),
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: 180, child: labelRow),
                      const SizedBox(width: 12),
                      Expanded(child: shown),
                      if (copy != null) copyButton(),
                    ],
                  ),
          );
        },
      ),
    );
  }

  /// A Summary value. [quiet] is for "Not set" and side notes.
  Widget _factText(String v, {bool quiet = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 2),
    child: SelectableText(v, style: TextStyle(fontSize: 14, height: 1.4, color: quiet ? DashUi.subtle : DashUi.ink)),
  );

  /// A Summary value that does something (call, email, map, find the customer): blue, underlined under the pointer,
  /// with an optional icon saying what kind of link it is.
  Widget _factLink(String text, VoidCallback onTap, {String? tip, IconData? icon, bool strong = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 2),
    child: _DetailLink(text: text, onTap: onTap, tip: tip, icon: icon, strong: strong),
  );

  /// Pictures / documents Service Fusion has on the job. null = the sync hasn't brought them in yet (so we can say
  /// "not synced yet" instead of claiming there are none).
  List<Map<String, dynamic>>? _files(String key) {
    final v = _sf[key];
    if (v is! List) return null;
    return v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
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

  /// A full web address (not a bare Service Fusion file name).
  static bool _isLink(String url) {
    final uri = Uri.tryParse(url.trim());
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
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

  void _say(String msg, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), action: action));
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
    final ok = await _confirm('Remove this file?', '"${f['name']}" comes off this $_kind for everyone. This cannot be undone.', 'Remove file');
    if (!ok || !mounted) return;
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

  // ---- Details: the Pics and Docs tabs ----------------------------------------------------------------------------

  /// The top of the Pics and Docs tabs: how many there are and where they came from (or the upload in progress, or
  /// why uploads are off), and the Upload button, whose tooltip lists the file types it takes. With none yet it is only
  /// the tab's name and the button: the empty state under it says there are none (audit 2026-11-24, item 27: it was
  /// said three times).
  Widget _filesToolbar({required bool pictures, required int ours, required int sf}) {
    final busy = _uploadStatus != null;
    final total = ours + sf;
    final noun = pictures ? (total == 1 ? 'picture' : 'pictures') : (total == 1 ? 'document' : 'documents');
    final from = [if (ours > 0) '$ours added here', if (sf > 0) '$sf from Service Fusion'].join('  ·  ');
    final Widget? status;
    if (busy) {
      status = Row(
        children: [
          const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: DashUi.ink)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(_uploadStatus!, style: const TextStyle(fontSize: 13, color: DashUi.slate)),
          ),
        ],
      );
    } else if (!_filesEnabled) {
      status = const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(Icons.cloud_off_rounded, size: 15, color: DashUi.amberText),
          ),
          SizedBox(width: 6),
          Flexible(
            child: Text(
              'Uploads are not set up yet: the file storage keys still need to be added on the server.',
              style: TextStyle(fontSize: 13, color: DashUi.amberText, height: 1.35),
            ),
          ),
        ],
      );
    } else {
      status = from.isEmpty ? null : Text(from, style: const TextStyle(fontSize: 13, color: DashUi.slate));
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 16, 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  total == 0 ? (pictures ? 'Pictures' : 'Documents') : '$total $noun',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: DashUi.ink, letterSpacing: -0.2),
                ),
                if (status != null) ...[const SizedBox(height: 2), status],
              ],
            ),
          ),
          const SizedBox(width: 12),
          // The ink button of the app's dialogs, not the theme's brand-red fill, which read as destructive (audit
          // 2026-11-24, item 17).
          if (_canUpdate)
            Tooltip(
              message: pictures ? 'JPG, PNG, WEBP, GIF or HEIC, up to 25 MB each' : 'PDF, Word, Excel, PowerPoint, CSV, TXT or DWG, up to 25 MB each',
              child: AppButton.ink(
                pictures ? 'Upload pictures' : 'Upload documents',
                (busy || !_filesEnabled) ? null : () => _upload(pictures: pictures),
                icon: Icons.upload_rounded,
              ),
            ),
        ],
      ),
    );
  }

  /// An empty Details tab: its icon in a tinted circle that pops in, what is missing, and what to do about it.
  Widget _detailsEmpty(IconData icon, String title, String message, {Color tone = DashUi.blue}) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
    child: Column(
      children: [
        TweenAnimationBuilder<double>(
          tween: Tween(begin: MediaQuery.disableAnimationsOf(context) ? 1 : 0.6, end: 1),
          duration: const Duration(milliseconds: 520),
          curve: Curves.elasticOut,
          builder: (context, k, child) => Transform.scale(scale: k, child: child),
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: tone.withValues(alpha: 0.1),
              border: Border.all(color: tone.withValues(alpha: 0.18), width: 6),
            ),
            child: Icon(icon, size: 26, color: tone),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          title,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: DashUi.ink),
        ),
        const SizedBox(height: 6),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: DashUi.slate, height: 1.45),
          ),
        ),
      ],
    ),
  );

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
        () {
          final isOurs = i < ours.length;
          final f = isOurs ? ours[i] : sf![i - ours.length];
          final url = isOurs ? (f['url'] ?? '').toString() : _resolveFileUrl((f['url'] ?? '').toString(), picture: true);
          return _PicTile(
            url: url,
            name: (f['name'] ?? '').toString(),
            comment: (f['comment'] ?? '').toString().trim(),
            uploadedBy: isOurs ? (f['uploadedBy'] ?? '').toString() : '',
            ours: isOurs,
            onOpen: url.isEmpty ? null : () => showFileViewer(context, viewer, i),
            onRemove: isOurs && _canUpdate ? () => _removeFile(f) : null,
          );
        }(),
    ];
    return [
      _filesToolbar(pictures: true, ours: ours.length, sf: sf?.length ?? 0),
      if (tiles.isNotEmpty)
        LayoutBuilder(
          builder: (context, c) {
            const gap = 12.0;
            final w = c.maxWidth - 40;
            final cols = (w / 190).floor().clamp(2, 6);
            final tileW = ((w - gap * (cols - 1)) / cols).floorToDouble();
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (var i = 0; i < tiles.length; i++)
                    SizedBox(
                      width: tileW,
                      child: _RiseIn(index: i, child: tiles[i]),
                    ),
                ],
              ),
            );
          },
        )
      else
        _detailsEmpty(
          Icons.photo_camera_outlined,
          'No pictures yet',
          _filesEnabled && _canUpdate
              ? (sf == null ? 'Upload one above. Service Fusion pictures appear after the next sync of this $_kind.' : 'Upload one above.')
              : (sf == null ? 'Service Fusion pictures appear after the next sync of this $_kind.' : 'Service Fusion has none on this $_kind either.'),
          tone: DashUi.sky,
        ),
    ];
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
          : [(f['type'] ?? '').toString(), _dateTime(f['created_at']), if (!_isLink(url)) 'Open it in Service Fusion'];
      return _DocRow(
        name: (f['name'] ?? '').toString().isEmpty ? 'Document' : f['name'].toString(),
        comment: (f['comment'] ?? '').toString().trim(),
        meta: meta.where((e) => e.trim().isNotEmpty).join('  ·  '),
        ours: isOurs,
        private: f['is_private'] == true,
        // Ours open in the viewer. Service Fusion's usually come with only a file name, which can't be opened from
        // here, so those don't look clickable at all (no pointer, no open icon) and say where to find them.
        onOpen: isOurs ? () => showFileViewer(context, viewer, index) : (_isLink(url) ? () => _openFile(url) : null),
        onRemove: isOurs && _canUpdate ? () => _removeFile(f) : null,
      );
    }

    final rows = <Widget>[
      for (var i = 0; i < ours.length; i++) row(ours[i], isOurs: true, index: i),
      // Service Fusion's own documents: we only have their file names, not a link, so they can't be opened from here.
      for (final f in sf ?? const <Map<String, dynamic>>[]) row(f, isOurs: false),
    ];
    return [
      _filesToolbar(pictures: false, ours: ours.length, sf: sf?.length ?? 0),
      if (rows.isEmpty)
        _detailsEmpty(
          Icons.description_outlined,
          'No documents yet',
          _filesEnabled && _canUpdate
              ? (sf == null ? 'Upload one above. Service Fusion documents appear after the next sync of this $_kind.' : 'Upload one above.')
              : (sf == null ? 'Service Fusion documents appear after the next sync of this $_kind.' : 'Service Fusion has none on this $_kind either.'),
        )
      else
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0) const Divider(height: 1, indent: 76, endIndent: 20, color: DashUi.line),
                _RiseIn(index: i, child: rows[i]),
              ],
            ],
          ),
        ),
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
    IconData icon = Icons.edit_note_rounded,
    String? subtitle,
    String saveLabel = 'Save',
  }) async {
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _TextDialog(
        title: title,
        hint: hint,
        maxLength: maxLength,
        maxLines: maxLines,
        onSave: onSave,
        icon: icon,
        subtitle: subtitle,
        saveLabel: saveLabel,
      ),
    );
    return saved == true;
  }

  Future<void> _addNote() async {
    final ok = await _textDialog(
      title: 'Add a note',
      subtitle: 'Saved on this $_kind here, with your name. Service Fusion is not changed.',
      icon: Icons.sticky_note_2_outlined,
      hint: 'Write a note about this $_kind',
      saveLabel: 'Save note',
      maxLength: 5000,
      maxLines: 8,
      onSave: (text) => _send('POST', 'notes', {'body': text}),
    );
    if (ok) await _loadNotesTasks();
  }

  Future<void> _addTask() async {
    final ok = await _textDialog(
      title: 'Add a task',
      subtitle: 'Goes on this $_kind\'s task list here. Service Fusion is not changed.',
      icon: Icons.add_task_rounded,
      hint: 'What needs to be done?',
      saveLabel: 'Save task',
      maxLength: 500,
      maxLines: 1,
      onSave: (text) => _send('POST', 'tasks', {'description': text}),
    );
    if (ok) await _loadNotesTasks();
  }

  /// "job" or "estimate", for dialog wording.
  String get _kind => _isEstimate ? 'estimate' : 'job';

  /// Asks before removing something: the title names it, the body says what happens, the red button repeats the
  /// verb. Cancel has the focus, so Enter or Esc straight away keeps it.
  Future<bool> _confirm(String title, String body, String action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppDialog(
        title: title,
        icon: Icons.delete_outline_rounded,
        iconColor: DashUi.red,
        body: Text(body, style: const TextStyle(fontSize: 14, color: DashUi.slate, height: 1.45)),
        actions: [
          Focus(autofocus: true, skipTraversal: true, child: AppButton.ghost('Cancel', () => Navigator.pop(ctx, false))),
          AppButton.ink(action, () => Navigator.pop(ctx, true), danger: true),
        ],
      ),
    );
    return ok == true;
  }

  /// Removes the job or estimate from the IOHD apps (it was deleted in Service Fusion). Nothing is sent to Service
  /// Fusion; the server keeps a backup copy and the sync stops bringing it back. Refused when it has payments or
  /// payroll history, and the server's reason is shown.
  Future<void> _deleteRecord() async {
    final kind = _kind;
    final title = _isEstimate ? 'Estimate' : 'Job';
    final customer = _s('customer_name');
    final whose = customer.isEmpty ? 'This $kind' : "$customer's $kind";
    final ok = await _confirm(
      'Delete $kind #${widget.jobId}?',
      '$whose comes out of the IOHD apps for everyone: lists, calendar, search and dashboards. '
          'Use this when it was deleted in Service Fusion.\n\n'
          'Nothing changes in Service Fusion, and the sync will not bring it back.',
      'Delete $kind',
    );
    if (!ok || !mounted) return;
    setState(() => _deleting = true);
    String? problem;
    try {
      final res = await http
          .delete(Uri.parse('$kApiBaseUrl/api/jobs/${Uri.encodeComponent(widget.jobId)}'), headers: AuthSession.instance.headers())
          .timeout(const Duration(seconds: 30));
      if (!mounted) return;
      if (res.statusCode == 401) {
        AuthSession.instance.logout();
        return;
      }
      if (res.statusCode == 200) {
        recordDeleted.value = widget.jobId;
        _say('$title #${widget.jobId} deleted.');
        context.go(_isEstimate ? '/estimates' : '/jobs');
        return;
      }
      String? msg;
      try {
        msg = (json.decode(res.body) as Map)['error']?.toString();
      } catch (_) {}
      problem = switch (res.statusCode) {
        // Who may delete is the Team screen's Delete switch now, not being an admin (audit 2026-11-24, item 29).
        403 => "You don't have permission to delete ${kind}s. An admin can turn it on in Team.",
        404 => 'It is already gone from the app. Refresh the list.',
        _ => msg ?? 'Server error (${res.statusCode}). Nothing was deleted.',
      };
    } catch (_) {
      problem = 'Could not reach the server. Nothing was deleted.';
    }
    if (!mounted) return;
    setState(() => _deleting = false);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AppDialog(
        title: 'Not deleted',
        icon: Icons.info_outline_rounded,
        iconColor: DashUi.ink,
        body: Text(problem!, style: const TextStyle(fontSize: 14, color: DashUi.slate, height: 1.45)),
        actions: [AppButton.ink('OK', () => Navigator.pop(ctx))],
      ),
    );
  }

  Future<void> _removeNote(Map<String, dynamic> n) async {
    if (!await _confirm('Remove this note?', 'It comes off this $_kind for everyone. This cannot be undone.', 'Remove note')) return;
    final err = await _send('DELETE', 'notes/${Uri.encodeComponent(n['id'].toString())}');
    if (err != null) _say('Could not remove it: $err');
    await _loadNotesTasks();
  }

  Future<void> _removeTask(Map<String, dynamic> t) async {
    final ok = await _confirm(
      'Remove this task?',
      '"${t['description']}" comes off this $_kind\'s task list for everyone. This cannot be undone.',
      'Remove task',
    );
    if (!ok) return;
    final err = await _send('DELETE', 'tasks/${Uri.encodeComponent(t['id'].toString())}');
    if (err != null) _say('Could not remove it: $err');
    await _loadNotesTasks();
  }

  /// Tasks whose tick is on its way to the server (task id), so the tick shows at once and can't be pressed twice.
  final Set<String> _taskPending = {};

  /// Ticks a task off (or back on) straight away and then saves it (audit 2026-11-24, item 28: the tick used to wait
  /// for the server with no sign anything was happening). A failed save puts the tick back and says why.
  Future<void> _toggleTask(Map<String, dynamic> t) async {
    final id = t['id'].toString();
    if (_taskPending.contains(id)) return;
    final done = t['isCompleted'] != true;
    List<Map<String, dynamic>> flipped(bool to) => [
      for (final x in _ourTasks) x['id'].toString() == id ? {...x, 'isCompleted': to} : x,
    ];
    setState(() {
      _taskPending.add(id);
      _ourTasks = flipped(done);
    });
    final err = await _send('PATCH', 'tasks/${Uri.encodeComponent(id)}', {'is_completed': done});
    if (!mounted) return;
    if (err != null) {
      setState(() => _ourTasks = flipped(!done));
      _say('Could not update the task: $err');
    }
    await _loadNotesTasks();
    if (mounted) setState(() => _taskPending.remove(id));
  }

  /// The Add task / Add note button at the right of its block's heading, styled like Request payment. No hover wash
  /// (USER RULE 2026-11-24): `styleFrom(foregroundColor:)` brings its own, which beats the page's theme.
  Widget _addButton(String label, VoidCallback onTap) => TextButton.icon(
    onPressed: onTap,
    style: TextButton.styleFrom(
      foregroundColor: DashUi.blue,
      visualDensity: VisualDensity.compact,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ).copyWith(overlayColor: dashNoHoverOverlay),
    icon: const Icon(Icons.add_rounded, size: 18),
    // Weight on the label, not the button's textStyle, which would replace the app font.
    label: Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
  );

  DateTime? _when(dynamic v) => DateTime.tryParse(v?.toString() ?? '');

  /// Where a section is switched off for this person: one plain line in place of it.
  Widget _noAccess(String text) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
    child: Row(
      children: [
        const Icon(Icons.lock_outline_rounded, size: 18, color: DashUi.subtle),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 14, color: DashUi.slate))),
      ],
    ),
  );

  /// The strip that opens a section (the task list on Details, the Notes card), drawn like Site visits' on Job Info:
  /// icon and "Title (n)", an optional [note] beside it ("1 of 3 done"), the Add button on the right.
  Widget _sectionStrip(IconData icon, String title, {String note = '', Color noteTone = DashUi.subtle, required Widget action}) => Container(
    padding: const EdgeInsets.fromLTRB(20, 2, 8, 2),
    decoration: const BoxDecoration(
      color: DashUi.faint,
      border: Border.symmetric(horizontal: BorderSide(color: DashUi.line)),
    ),
    child: Row(
      children: [
        Icon(icon, size: 16, color: DashUi.subtle),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: DashUi.slate),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            note,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: noteTone, fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ),
        action,
      ],
    ),
  );

  /// The Task List section at the bottom of the Details block's Summary tab attached the way Site
  /// Visits is to Job Info: ours (add, tick off, remove) then Service Fusion's (read-only), with how many are done and a bar that fills
  /// as they are ticked off.
  Widget _tasksSection() {
    final raw = _sf['tasks'];
    final List<Map<String, dynamic>> sfTasks = raw is List ? raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() : const [];
    final action = _canUpdate ? _addButton('Add task', _addTask) : const SizedBox.shrink();

    Widget row({
      required Key key,
      required String text,
      required bool done,
      required String sub,
      bool synced = false,
      bool pending = false,
      VoidCallback? onToggle,
      VoidCallback? onRemove,
    }) =>
        _HoverRow(
          key: key,
          builder: (_) => Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 6, 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _TaskCheck(done: done, pending: pending, onTap: onToggle),
                const SizedBox(width: 4),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 9, bottom: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectableText(
                          text,
                          style: TextStyle(
                            fontSize: 14.5,
                            height: 1.4,
                            color: done ? DashUi.subtle : DashUi.ink,
                            decoration: done ? TextDecoration.lineThrough : null,
                            decorationColor: DashUi.muted,
                          ),
                        ),
                        if (sub.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Row(
                              children: [
                                if (synced) ...[const Icon(Icons.sync_rounded, size: 13, color: DashUi.subtle), const SizedBox(width: 4)],
                                Flexible(
                                  child: Text(sub, style: const TextStyle(fontSize: 12.5, color: DashUi.subtle)),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (onRemove != null)
                  IconButton(
                    tooltip: 'Remove task',
                    color: DashUi.subtle,
                    icon: const Icon(Icons.delete_outline_rounded, size: 19),
                    onPressed: onRemove,
                  ),
              ],
            ),
          ),
        );

    final rows = <Widget>[
      for (final t in _ourTasks)
        row(
          key: ValueKey('task-${t['id']}'),
          text: (t['description'] ?? '').toString(),
          done: t['isCompleted'] == true,
          sub: [
            if ((t['createdBy'] ?? '').toString().isNotEmpty) 'Added by ${t['createdBy']}',
            if (t['isCompleted'] == true && (t['completedBy'] ?? '').toString().isNotEmpty) 'done by ${t['completedBy']}',
          ].join('  ·  '),
          pending: _taskPending.contains(t['id'].toString()),
          onToggle: _canUpdate ? () => _toggleTask(t) : null,
          onRemove: _canUpdate ? () => _removeTask(t) : null,
        ),
      for (var i = 0; i < sfTasks.length; i++)
        row(
          key: ValueKey('sf-task-$i'),
          text: (sfTasks[i]['description'] ?? '').toString(),
          done: sfTasks[i]['is_completed'] == true,
          sub: 'Service Fusion',
          synced: true,
        ),
    ];
    final total = rows.length;
    final done = _ourTasks.where((t) => t['isCompleted'] == true).length + sfTasks.where((t) => t['is_completed'] == true).length;
    final all = total > 0 && done == total;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionStrip(
          Icons.checklist_rounded,
          'Task list ($total)',
          note: total == 0 ? '' : (all ? (total == 1 ? 'Done' : 'All $total done') : '$done of $total done'),
          noteTone: all ? DashUi.emeraldText : DashUi.subtle,
          action: action,
        ),
        if (total == 0)
          Padding(
            padding: const EdgeInsets.all(20),
            child: _factText(
              '${_sf['tasks'] is List ? 'No tasks on this $_kind.' : 'No tasks yet.'}${_canUpdate ? ' Use Add task to add one.' : ''}',
              quiet: true,
            ),
          )
        else ...[
          // No progress bar (user 2026-11-24: it read as an empty bar): the strip's "x of y done" says it.
          const SizedBox(height: 4),
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 20, endIndent: 20, color: DashUi.line),
            _RiseIn(key: rows[i].key, index: i, child: rows[i]),
          ],
          const SizedBox(height: 4),
        ],
      ],
    );
  }

  /// The Notes card under the Details block, newest first: ours show who wrote them; Service Fusion's only
  /// come with a date (the API sends no author).
  static const int _notesCollapsedCount = 2; // notes shown while the section is collapsed

  Widget _notesSection() {
    final raw = _sf['notes'];
    final List<Map<String, dynamic>> sfNotes = raw is List ? raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() : const [];
    final all = <({DateTime? at, Widget Function() build})>[
      for (final n in _ourNotes)
        (
          at: _when(n['createdAt']),
          build: () => _noteRow(
            key: ValueKey('note-${n['id']}'),
            who: (n['author'] ?? '').toString(),
            when: _dateTime(n['createdAt']),
            text: (n['body'] ?? '').toString(),
            onRemove: _canUpdate ? () => _removeNote(n) : null,
          ),
        ),
      for (var i = 0; i < sfNotes.length; i++)
        (
          at: _when(sfNotes[i]['created_at']),
          build: () => _noteRow(
            key: ValueKey('sf-note-$i'),
            who: 'Service Fusion',
            when: _dateTime(sfNotes[i]['created_at']),
            text: (sfNotes[i]['text'] ?? '').toString(),
            synced: true,
          ),
        ),
    ]..sort((a, b) => (b.at ?? DateTime.fromMillisecondsSinceEpoch(0)).compareTo(a.at ?? DateTime.fromMillisecondsSinceEpoch(0)));
    final action = _canUpdate ? _addButton('Add note', _addNote) : const SizedBox.shrink();
    // Collapsed by default when there are more than a couple: the newest few, then a control to show them all.
    final collapsible = all.length > _notesCollapsedCount;
    final shown = (collapsible && !_notesExpanded) ? all.take(_notesCollapsedCount).toList() : all;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionStrip(Icons.sticky_note_2_outlined, 'Notes (${all.length})', action: action),
        if (all.isEmpty)
          Padding(
            padding: const EdgeInsets.all(20),
            child: _factText(
              '${_sf['notes'] is List ? 'No notes on this $_kind.' : 'No notes yet.'}${_canUpdate ? ' Use Add note to write one.' : ''}',
              quiet: true,
            ),
          )
        else ...[
          for (var i = 0; i < shown.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 20, endIndent: 20, color: DashUi.line),
            () {
              final row = shown[i].build();
              return _RiseIn(key: row.key, index: i, child: row);
            }(),
          ],
          if (collapsible)
            _showAllToggle(
              expanded: _notesExpanded,
              label: _notesExpanded ? 'Show fewer notes' : 'Show all ${all.length} notes (${all.length - _notesCollapsedCount} older)',
              onTap: () => setState(() => _notesExpanded = !_notesExpanded),
            ),
          const SizedBox(height: 4),
        ],
      ],
    );
  }

  /// "Show all n notes" / "Show all n visits" under a collapsed list, and "Show fewer" once it is open: the same control,
  /// in the same place, for both lists (audit 2026-11-24, item 34: the visits' one sat above its list).
  Widget _showAllToggle({required bool expanded, required String label, required VoidCallback onTap}) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Divider(height: 1, indent: 20, endIndent: 20, color: DashUi.line),
      InkWell(
        mouseCursor: WidgetStateMouseCursor.clickable,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
          child: Row(
            children: [
              AnimatedRotation(
                turns: expanded ? 0.5 : 0,
                duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                child: const Icon(Icons.expand_more_rounded, size: 20, color: DashUi.blue),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(label, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: DashUi.blue)),
              ),
            ],
          ),
        ),
      ),
    ],
  );

  /// One note: who wrote it (their avatar, or a sync badge for Service Fusion's) and when, then what it says. A note
  /// saved without an author gets a plain person badge, not initials made from the stand-in name (audit 2026-11-24,
  /// item 30: it showed "AH" from "Added here").
  Widget _noteRow({required Key key, required String who, required String when, required String text, bool synced = false, VoidCallback? onRemove}) {
    final anonymous = who.trim().isEmpty;
    final name = anonymous ? 'Added here' : who.trim();
    return _HoverRow(
      key: key,
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 6, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            synced
                ? _infoBadge(Icons.sync_rounded, DashUi.indigo)
                : anonymous
                ? _infoBadge(Icons.person_outline_rounded, DashUi.subtle)
                : DashAvatar(name: name, imageUrl: _techPhotos[name.toLowerCase()] ?? '', size: 30, accent: DashUi.blue),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          name,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: DashUi.ink),
                        ),
                        if (when.isNotEmpty)
                          Text(
                            when,
                            style: const TextStyle(fontSize: 12.5, color: DashUi.subtle, fontFeatures: [FontFeature.tabularFigures()]),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    SelectableText(text, style: const TextStyle(fontSize: 14, height: 1.45, color: DashUi.ink)),
                  ],
                ),
              ),
            ),
            if (onRemove != null)
              IconButton(tooltip: 'Remove note', color: DashUi.subtle, icon: const Icon(Icons.delete_outline_rounded, size: 19), onPressed: onRemove),
          ],
        ),
      ),
    );
  }

  /// A status change in words, with no bare arrow when one side is empty (audit 2026-11-24, item 29).
  static String _statusChange(String from, String to) {
    if (from.isEmpty && to.isEmpty) return 'Status changed';
    if (from.isEmpty) return 'Status set to $to';
    if (to.isEmpty) return 'Status cleared (was $from)';
    return 'Status changed: $from  →  $to';
  }

  /// Activity tab: one timeline, newest first. Anything done in this app names the person; status changes come from
  /// Service Fusion's sync, which does not tell us who made them.
  List<Widget> _activityRows() {
    final events = <({DateTime? at, IconData icon, String who, String what})>[
      for (final h in _history)
        (
          at: _when(h['changed_at']),
          icon: Icons.swap_horiz_rounded,
          who: 'Service Fusion',
          what: _statusChange((h['old_status'] ?? '').toString().trim(), (h['new_status'] ?? '').toString().trim()),
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
      return [
        _detailsEmpty(
          Icons.view_headline_rounded,
          'No activity recorded',
          'Status changes and anything done here show up as they happen.',
          tone: DashUi.indigo,
        ),
      ];
    }
    return [
      const SizedBox(height: 6),
      for (final e in events)
        _HoverRow(
          builder: (_) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _infoBadge(e.icon, DashUi.indigo),
                const SizedBox(width: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Text.rich(
                      TextSpan(
                        style: const TextStyle(fontSize: 14, color: DashUi.ink, height: 1.4),
                        children: [
                          if (e.who.isNotEmpty)
                            TextSpan(
                              text: '${e.who}  ',
                              style: const TextStyle(fontWeight: FontWeight.w700),
                            ),
                          TextSpan(text: e.what),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Padding(
                  padding: const EdgeInsets.only(top: 7),
                  child: Text(
                    e.at == null ? '' : _dateTime(e.at!.toIso8601String()),
                    style: const TextStyle(fontSize: 12.5, color: DashUi.subtle, fontFeatures: [FontFeature.tabularFigures()]),
                  ),
                ),
              ],
            ),
          ),
        ),
      const SizedBox(height: 6),
    ];
  }

  /// A small tinted circle holding a row's icon (Activity events, payments).
  Widget _infoBadge(IconData icon, Color tone) => Container(
    width: 30,
    height: 30,
    decoration: BoxDecoration(shape: BoxShape.circle, color: tone.withValues(alpha: 0.1)),
    child: Icon(icon, size: 16, color: tone),
  );

  /// One payment on file: date and kind on the left, the amount on the right, and (for money that counts) what was
  /// still owed after it. [counted] is false for Stripe rows, which are not in the balance yet and so stay grey.
  Widget _paymentLine(String what, double amount, {bool counted = true, double? left}) => _HoverRow(
    builder: (_) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
      child: Row(
        children: [
          _infoBadge(amount < 0 ? Icons.undo_rounded : Icons.payments_outlined, counted ? DashUi.emeraldDeep : DashUi.subtle),
          const SizedBox(width: 12),
          Expanded(
            child: Text(what, style: const TextStyle(fontSize: 14, color: DashUi.slate, height: 1.4)),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _money.format(amount),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: counted ? DashUi.emeraldText : DashUi.subtle,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              if (left != null) _leftAfter(left),
            ],
          ),
        ],
      ),
    ),
  );

  /// A Stripe payment: what it was for, when, its Stripe reference (opens it in the Stripe dashboard), and the amount,
  /// with the balance [left] after it. When the office has entered it in Service Fusion ([enteredAs], see
  /// [_stripeMatch]) it stands in for that entry: green, with the entry named in the logo's tooltip. Without one it is
  /// Stripe purple and says it is not in Service Fusion: it counts toward this job here, but no report has it yet.
  Widget _stripeLine(Map<String, dynamic> p, {Map<String, dynamic>? enteredAs, double? left}) {
    final refund = p['kind'] == 'refund' || _n(p['amount']) < 0;
    final ref = (p['payment_intent'] ?? '').toString().trim();
    final counted = enteredAs != null;
    final sfType = (enteredAs?['payment_type'] ?? '').toString().trim();
    final sfDay = _day(enteredAs?['received_on']);
    return _HoverRow(
      builder: (_) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            StripeMark(
              size: 30,
              tip: counted
                  ? 'Paid through Stripe. Entered in Service Fusion as ${sfType.isEmpty ? 'a payment' : sfType}'
                        '${sfDay == null ? '' : ' on ${DateFormat('MMM d').format(sfDay)}'}, so it is in the balance.'
                  : '${refund ? 'Refunded' : 'Paid'} through Stripe. Service Fusion has no payment entry for it, so it '
                        'counts on this job but not in reports yet.',
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${stripePaymentLabel(p['memo'], refund: refund)} via Stripe',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: DashUi.ink, height: 1.4),
                  ),
                  Wrap(
                    spacing: 10,
                    runSpacing: 2,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(_dateTime(p['received_on']), style: const TextStyle(fontSize: 13, color: DashUi.slate)),
                      if (ref.isNotEmpty)
                        _DetailLink(
                          text: ref,
                          icon: Icons.open_in_new_rounded,
                          tip: 'Open this payment in Stripe',
                          onTap: () => _launch(stripeDashboardUri(ref)),
                        ),
                      if (!counted) const Text('Not in Service Fusion', style: TextStyle(fontSize: 13, color: kStripeBrand)),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  _money.format(_n(p['amount'])),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: refund ? DashUi.redText : (counted ? DashUi.emeraldText : kStripeBrand),
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                if (left != null) _leftAfter(left),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Which Service Fusion payments are Stripe payments the office entered by hand (they type them "Credit Card
  /// (Offline)"). Same rule as the Payments screen (payments_list.js): a Stripe payment on this job for the same amount
  /// to the cent (the office sometimes types a cent off), within 14 days, or for what is left of it after a partial
  /// refund (the office enters the net); one refunded in full pairs with nothing. A refund pairs with a Service Fusion
  /// refund the same way, and the refunds of a payment paired on its net are already in that entry. Each side pairs at
  /// most once; an entry typed "(Offline)" or with the office's Stripe reference wins, then the closest date. [bySf]
  /// maps a `_payments` index to its Stripe payment; [unmatched] are the Stripe payments Service Fusion has no entry for.
  ({Map<int, Map<String, dynamic>> bySf, List<Map<String, dynamic>> unmatched}) get _stripeMatch {
    final bySf = <int, Map<String, dynamic>>{};
    final unmatched = <Map<String, dynamic>>[];
    bool isRefund(Map<String, dynamic> st) => st['kind'] == 'refund' || _n(st['amount']) < 0;
    String intent(Map<String, dynamic> st) => (st['payment_intent'] ?? '').toString();
    final refunded = <String, double>{}; // payment intent -> its refunds (negative)
    for (final st in _stripePayments) {
      if (isRefund(st) && intent(st).isNotEmpty) refunded[intent(st)] = (refunded[intent(st)] ?? 0) + _n(st['amount']);
    }
    final pairedOnNet = <String>{};
    // Payments first: a refund needs to know how its payment paired.
    for (final refundPass in [false, true]) {
      for (final st in _stripePayments) {
        if (isRefund(st) != refundPass) continue;
        if (refundPass && pairedOnNet.contains(intent(st))) continue;
        final amount = _n(st['amount']);
        final net = refundPass ? amount : amount + (refunded[intent(st)] ?? 0);
        final amounts = refundPass ? [amount] : (net > 0.005 ? [amount, net] : const <double>[]);
        final at = _when(st['received_on']);
        int? best;
        (bool, int)? bestRank;
        for (var i = 0; i < _payments.length; i++) {
          if (bySf.containsKey(i)) continue;
          final p = _payments[i];
          final type = (p['transaction_type'] ?? '').toString().toUpperCase();
          if (refundPass ? type != 'REFUND' : !(type == 'PAYMENT' || type == 'AUTH_CAPTURE')) continue;
          if (!amounts.any((a) => (_n(p['amount']) - a).abs() <= 0.015)) continue;
          final sfAt = _when(p['received_on']);
          if (at == null || sfAt == null) continue;
          final days = at.difference(sfAt).inHours.abs() ~/ 24;
          if (days > 14) continue;
          final office =
              (p['payment_type'] ?? '').toString().toLowerCase().contains('offline') ||
              (p['reference_number'] ?? '').toString().trim() == 'Job Payment Database';
          final rank = (!office, days);
          if (bestRank == null || (rank.$1 == bestRank.$1 ? rank.$2 < bestRank.$2 : !rank.$1)) {
            best = i;
            bestRank = rank;
          }
        }
        if (best == null) {
          unmatched.add(st);
        } else {
          bySf[best] = st;
          if (!refundPass && (_n(_payments[best]['amount']) - amount).abs() > 0.015) pairedOnNet.add(intent(st));
        }
      }
    }
    return (bySf: bySf, unmatched: unmatched);
  }

  /// Stripe money Service Fusion has no payment entry for (refunds negative). Real money, so it counts on this page;
  /// no report has it until the office enters it.
  double get _stripeExtra => _stripeMatch.unmatched.fold<double>(0, (sum, p) => sum + _n(p['amount']));

  static const _countedTypes = {'PAYMENT', 'AUTH_CAPTURE', 'REFUND'}; // the money Collections counts as cash

  /// Where the job's money stands, worked out once for the summary card, the Request button and the payment rows.
  /// Stripe money Service Fusion has no entry for counts too: it is in neither Service Fusion's payments nor its balance.
  /// [paid] stops at the total; [over] is what came in beyond it (a double charge, say), owed back to the customer.
  ({double total, double paid, double owed, double over, String state, Map<String, dynamic>? invoice}) _moneyState(
    Map<String, dynamic> job,
  ) {
    final total = _n(job['total_revenue']);
    final due = _n(job['due_total']);
    final extra = _stripeExtra;
    final unpaid = _invoices.where((i) => i['is_paid'] != true).toList();
    if (due > 0.005) {
      final owed = due - (extra > 0 ? extra : 0);
      return owed > 0.005
          ? (total: total, paid: (total - owed).clamp(0, total).toDouble(), owed: owed, over: 0, state: 'owed', invoice: null)
          : (total: total, paid: total, owed: 0, over: owed < -0.005 ? -owed : 0, state: 'paid', invoice: null);
    }
    final paid = _paid + extra;
    if (total <= 0 || paid >= total - 0.005) {
      return (total: total, paid: total, owed: 0, over: total > 0 && paid > total + 0.005 ? paid - total : 0, state: 'paid', invoice: null);
    }
    if (_invoices.isNotEmpty) {
      final inv = (unpaid.isNotEmpty ? unpaid : _invoices).first;
      return unpaid.isEmpty
          ? (total: total, paid: total, owed: 0, over: 0, state: 'invoice-paid', invoice: inv)
          : (total: total, paid: paid.clamp(0, total).toDouble(), owed: _n(inv['total']), over: 0, state: 'invoice-owed', invoice: inv);
    }
    return (total: total, paid: paid.clamp(0, total).toDouble(), owed: 0, over: 0, state: 'unknown', invoice: null);
  }

  /// The one wording for money paid beyond the total, wherever it shows (audit 2026-11-24, item 15).
  String _overpaid(double over) => 'Overpaid by ${_money.format(over)}';

  /// The balance after a payment in the list: still owed, settled, or paid beyond the total (amber, it is owed back).
  Widget _leftAfter(double left) {
    final over = left < -0.005;
    return Text(
      over ? _overpaid(-left) : (left <= 0.005 ? 'Nothing left to pay' : '${_money.format(left)} left'),
      style: TextStyle(
        fontSize: 12.5,
        color: over ? DashUi.amberText : DashUi.subtle,
        fontWeight: over ? FontWeight.w600 : null,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }

  /// The top of the Payment tab: how much of the job is paid as a bar that fills in, what is left, and for money still
  /// owed how long it has been open (since the work finished, as Collections counts it).
  Widget? _paidSummary(Map<String, dynamic> job) {
    final m = _moneyState(job);
    if (m.total <= 0) return null;
    final share = (m.paid / m.total).clamp(0.0, 1.0);
    final over = m.over > 0.005;
    // Past 100 when overpaid. Held at 99 while anything is owed, so "100% paid" never shows with money still due
    // (99.7% used to round up to it).
    final rawPercent = ((m.paid + m.over) / m.total * 100).round();
    final percent = m.paid < m.total - 0.005 ? math.min(rawPercent, 99) : rawPercent;
    final owing = m.state == 'owed' || m.state == 'invoice-owed';
    final full = m.state == 'paid' || m.state == 'invoice-paid';
    final (String right, Color rightTone) = switch (m.state) {
      'owed' => ('${_money.format(m.owed)} left', DashUi.redText),
      // Owed is red here too, as under Balance due (audit 2026-11-24, item 16).
      'invoice-owed' => ('${_money.format(m.owed)} on invoice #${m.invoice!['number']}', DashUi.redText),
      'invoice-paid' => ('Paid on invoice #${m.invoice!['number']}', DashUi.emeraldText),
      'paid' when over => (_overpaid(m.over), DashUi.amberText),
      'paid' => ('Paid in full', DashUi.emeraldText),
      // Service Fusion shows nothing due, but the payments on file don't cover the total (audit item 29: this said
      // "Rest not on file").
      _ when m.paid > 0.005 => ('${_money.format(m.total - m.paid)} with no payment on file', DashUi.subtle),
      _ => ('No payment on file', DashUi.subtle),
    };
    String? age;
    Color ageTone = DashUi.amberText;
    if (owing) {
      final since = _day(job['end_date']) ?? _day(job['closed_at']) ?? _day(job['start_date']);
      if (since != null) {
        final d = _daysFrom(since, _today);
        if (d >= 0) {
          age = d == 0 ? 'Balance open since today' : 'Balance open ${_span(d)}';
          ageTone = d > 60 ? DashUi.redText : (d > 30 ? DashUi.amberText : DashUi.slate);
        }
      }
    }
    final stripe = _stripeExtra;
    final still = MediaQuery.disableAnimationsOf(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 16, 20, 6),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: DashUi.faint,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: DashUi.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.end,
            spacing: 12,
            runSpacing: 4,
            children: [
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: _money.format(m.paid + m.over),
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: DashUi.ink, letterSpacing: -0.3),
                    ),
                    TextSpan(
                      text: '  of ${_money.format(m.total)} paid',
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: DashUi.slate),
                    ),
                  ],
                ),
                style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
              ),
              Text(
                right,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: rightTone),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Semantics(
            label: '$percent percent paid',
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: SizedBox(
                height: 10,
                child: Stack(
                  children: [
                    Positioned.fill(child: ColoredBox(color: owing ? rightTone.withValues(alpha: 0.16) : DashUi.line)),
                    TweenAnimationBuilder<double>(
                      tween: Tween(begin: still ? share : 0, end: share),
                      duration: still ? Duration.zero : const Duration(milliseconds: 900),
                      curve: Curves.easeOutCubic,
                      builder: (context, k, _) => FractionallySizedBox(
                        widthFactor: k,
                        heightFactor: 1,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(999),
                            gradient: const LinearGradient(colors: [DashUi.emerald, DashUi.emeraldDeep]),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                '$percent% paid',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: over ? DashUi.amberText : DashUi.slate),
              ),
              const Spacer(),
              if (age != null) ...[
                Icon(Icons.hourglass_bottom_rounded, size: 15, color: ageTone),
                const SizedBox(width: 4),
                Text(
                  age,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ageTone),
                ),
              ] else if (full && !over) // overpaid: the callout below carries the one warning icon (audit item 32)
                const Icon(Icons.verified_rounded, size: 17, color: DashUi.emeraldDeep),
            ],
          ),
          // More came in than the job is worth: say so plainly, it is the customer's money.
          if (over) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.fromLTRB(10, 9, 12, 9),
              decoration: BoxDecoration(
                color: DashUi.amberText.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: DashUi.amberText.withValues(alpha: 0.30)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning_amber_rounded, size: 18, color: DashUi.amberText),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '${_money.format(m.over)} more than the job total was paid.',
                            style: const TextStyle(fontWeight: FontWeight.w700, color: DashUi.amberText),
                          ),
                          const TextSpan(
                            text: ' Unless it belongs to another job, it is owed back to the customer. If they were charged '
                                'twice, refund it in Stripe.',
                          ),
                        ],
                      ),
                      style: const TextStyle(fontSize: 13, color: DashUi.slate, height: 1.35),
                    ),
                  ),
                ],
              ),
            ),
          ],
          // Stripe money Service Fusion has no entry for: in the bar above, but no report has it until it is entered.
          if (stripe.abs() > 0.005) ...[
            const SizedBox(height: 10),
            const Divider(height: 1, color: DashUi.line),
            const SizedBox(height: 10),
            Row(
              children: [
                const StripeMark(size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: stripe < 0
                              ? '${_money.format(-stripe)} refunded through Stripe'
                              : '${_money.format(stripe)} paid through Stripe',
                          style: const TextStyle(fontWeight: FontWeight.w700, color: kStripeBrand),
                        ),
                        const TextSpan(text: '. Service Fusion has no payment entry for it yet, so reports leave it out.'),
                      ],
                    ),
                    style: const TextStyle(fontSize: 13, color: DashUi.slate, height: 1.35),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Service Fusion's payment-terms codes, in words. Anything else is shown as Service Fusion has it.
  static const _termWords = {'DUR': 'Due upon receipt', 'COD': 'Cash on delivery'};

  /// An invoice Service Fusion billed this job on: number, date, amount and whether it is paid, and a chevron that opens
  /// its details (when it was emailed, terms, who it was billed to, the QuickBooks number, the work it was for, and its
  /// online invoice). The only invoice on a job starts open.
  Widget _invoiceLine(Map<String, dynamic> inv) {
    final paid = inv['is_paid'] == true;
    final key = (inv['number'] ?? '').toString();
    final hasDetails = inv.containsKey('mail_send_date') || inv.containsKey('pay_online_url');
    final open = hasDetails && (_invoiceOpen[key] ?? _invoices.length == 1);
    final still = MediaQuery.disableAnimationsOf(context);
    String day(dynamic v) {
      final d = _day(v);
      return d == null ? '' : DateFormat('MMM d, y').format(d);
    }

    String str(String k) => (inv[k] ?? '').toString().trim();

    final what = [
      'Invoice #${inv['number']}',
      day(inv['invoice_date']),
      if (!paid && day(inv['due_date']).isNotEmpty) 'due ${day(inv['due_date'])}',
    ].where((e) => e.isNotEmpty).join('  ·  ');
    final tone = paid ? DashUi.emeraldDeep : DashUi.red;

    // "Nov 2, 2026 at 3:58 PM (today)": when Service Fusion emailed it, and how long ago.
    String sent() {
      final at = DateTime.tryParse(str('mail_send_date'))?.toLocal();
      if (at == null) return '';
      final today = DashClock.now();
      final days = DateTime(today.year, today.month, today.day).difference(DateTime(at.year, at.month, at.day)).inDays;
      final ago = days <= 0 ? 'today' : (days == 1 ? 'yesterday' : '$days days ago');
      return '${DateFormat('MMM d, y').format(at)} at ${DateFormat('h:mm a').format(at)} ($ago)';
    }

    final terms = str('terms').isNotEmpty ? str('terms') : str('payment_terms');
    final url = str('pay_online_url');
    final facts = <(IconData, String, String)>[
      // Only when the server sent the field: an older backend leaves it out, which is not the same as "not emailed".
      if (inv.containsKey('mail_send_date')) (Icons.forward_to_inbox_rounded, 'Emailed', sent().isEmpty ? 'Not emailed yet' : sent()),
      if (terms.isNotEmpty) (Icons.event_note_outlined, 'Terms', _termWords[terms.toUpperCase()] ?? terms),
      if (str('customer_contact').isNotEmpty) (Icons.person_outline_rounded, 'Billed to', str('customer_contact')),
      if (str('qbo_invoice_no').isNotEmpty) (Icons.account_balance_outlined, 'QuickBooks', 'Invoice #${str('qbo_invoice_no')}'),
      if (str('notes').isNotEmpty) (Icons.handyman_outlined, 'Work', str('notes').replaceAll(RegExp(r'\n[_\-=\s]{8,}$'), '').trim()),
    ];

    final details = Container(
      margin: const EdgeInsets.fromLTRB(62, 0, 20, 12),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(
        color: DashUi.faint,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: DashUi.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final f in facts)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(f.$1, size: 16, color: DashUi.subtle),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 96,
                    child: Text(
                      f.$2,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: DashUi.slate),
                    ),
                  ),
                  Expanded(
                    child: SelectableText(
                      f.$3,
                      style: TextStyle(fontSize: 13.5, height: 1.4, color: f.$3 == 'Not emailed yet' ? DashUi.subtle : DashUi.ink),
                    ),
                  ),
                ],
              ),
            ),
          if (url.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                TextButton.icon(
                  onPressed: () => _openFile(url),
                  style: TextButton.styleFrom(
                    foregroundColor: DashUi.blue,
                    visualDensity: VisualDensity.compact,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ).copyWith(overlayColor: dashNoHoverOverlay),
                  icon: const Icon(Icons.open_in_new_rounded, size: 16),
                  label: const Text('Open invoice', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                ),
                TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: url));
                    _say('Copied the link to invoice #${inv['number']}');
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: DashUi.slate,
                    visualDensity: VisualDensity.compact,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ).copyWith(overlayColor: dashNoHoverOverlay),
                  icon: const Icon(Icons.link_rounded, size: 16),
                  label: const Text('Copy link', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ],
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _HoverRow(
          builder: (_) => Semantics(
            button: true,
            expanded: hasDetails ? open : null,
            label: '$what, ${_money.format(_n(inv['total']))}, ${paid ? 'paid' : 'unpaid'}',
            excludeSemantics: true,
            onTap: hasDetails ? () => setState(() => _invoiceOpen[key] = !open) : null,
            child: InkWell(
              mouseCursor: WidgetStateMouseCursor.clickable,
              onTap: hasDetails ? () => setState(() => _invoiceOpen[key] = !open) : null,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 9, 12, 9),
                child: Row(
                  children: [
                    _infoBadge(Icons.receipt_long_outlined, tone), // red while unpaid, like its pill (audit item 16)
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(what, style: const TextStyle(fontSize: 14, color: DashUi.slate, height: 1.4)),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      _money.format(_n(inv['total'])),
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: DashUi.ink,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
                      decoration: BoxDecoration(color: tone.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(999)),
                      child: Text(
                        paid ? 'Paid' : 'Unpaid',
                        style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: paid ? DashUi.emeraldText : DashUi.redText),
                      ),
                    ),
                    if (hasDetails) ...[
                      const SizedBox(width: 6),
                      AnimatedRotation(
                        turns: open ? 0.5 : 0,
                        duration: still ? Duration.zero : const Duration(milliseconds: 220),
                        curve: Curves.easeOutCubic,
                        child: const Icon(Icons.expand_more_rounded, size: 20, color: DashUi.subtle),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: still ? Duration.zero : const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: open ? details : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  Widget _sectionHeading(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 14, 20, 2),
    child: Text(
      text,
      style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: DashUi.slate),
    ),
  );

  /// Payment tab: what the job is worth and owes, the invoices it was billed on, then each payment on file.
  List<Widget> _paymentRows(Map<String, dynamic> job) {
    final m = _moneyState(job);
    // A running balance only where Service Fusion's balance and the payments tell the same story.
    final running = !_isEstimate && (m.state == 'owed' || m.state == 'paid') && m.total > 0;
    var left = m.total;
    final match = _stripeMatch;
    final stripeFor = match.bySf;
    // The payments on file and the Stripe payments Service Fusion has no entry for, by date: both count toward the job.
    final order = <({DateTime? at, int seq, int sf, Map<String, dynamic>? stripe})>[
      for (var i = 0; i < _payments.length; i++) (at: _when(_payments[i]['received_on']), seq: i, sf: i, stripe: null),
      for (var j = 0; j < match.unmatched.length; j++)
        (at: _when(match.unmatched[j]['received_on']), seq: _payments.length + j, sf: -1, stripe: match.unmatched[j]),
    ]..sort((a, b) {
        if ((a.at == null) != (b.at == null)) return a.at == null ? 1 : -1;
        final byDate = a.at == null ? 0 : a.at!.compareTo(b.at!);
        return byDate != 0 ? byDate : a.seq.compareTo(b.seq);
      });
    final paymentLines = <Widget>[
      for (final e in order)
        () {
          if (e.stripe != null) {
            left -= _n(e.stripe!['amount']);
            return _stripeLine(e.stripe!, left: running ? left : null);
          }
          final i = e.sf;
          final p = _payments[i];
          final counted = _countedTypes.contains((p['transaction_type'] ?? '').toString().toUpperCase());
          if (counted) left -= _n(p['amount']);
          final stripe = stripeFor[i];
          if (stripe != null) return _stripeLine(stripe, enteredAs: p, left: running && counted ? left : null);
          return _paymentLine(
            [
              _dateTime(p['received_on']),
              (p['payment_type'] ?? '').toString(),
              (p['transaction_type'] ?? '').toString(),
            ].where((e) => e.trim().isNotEmpty).join('  ·  '),
            _n(p['amount']),
            left: running && counted ? left : null,
          );
        }(),
    ];
    // Ask for what is owed; nothing to ask for once it is all paid.
    final ask = _isEstimate ? 0.0 : (m.state == 'owed' ? m.owed : 0.0);
    final showRequest = _isEstimate || !(m.state == 'paid' || m.state == 'invoice-paid');
    return [
      _sfRow(
        Icons.receipt_long_outlined,
        _isEstimate ? 'Estimate total' : 'Job total',
        job['total_revenue'] == null ? null : _factText(_money.format(_n(job['total_revenue']))),
      ),
      // An estimate has no balance: Service Fusion carries the whole quote in that field.
      if (!_isEstimate) ...[
        const Divider(height: 1, indent: 20, endIndent: 20, color: DashUi.line),
        _sfRow(Icons.account_balance_wallet_outlined, 'Balance due', job['due_total'] == null ? null : _balanceText(job)),
      ],
      if (showRequest && _canRequestPayment)
        Padding(
          // 8 + the button's own 12 px start padding puts its icon on the rows' 20 px icon line (audit item 31).
          padding: const EdgeInsets.fromLTRB(8, 4, 14, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => _PaymentLinkDialog(
                  jobId: widget.jobId,
                  estimate: _isEstimate,
                  total: _n(job['total_revenue']),
                  balance: ask,
                ),
              ),
              style: TextButton.styleFrom(
                foregroundColor: DashUi.blue,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ).copyWith(overlayColor: dashNoHoverOverlay),
              icon: const Icon(Icons.link_rounded, size: 18),
              // Weight on the label, not the button's textStyle, which would replace the app font.
              label: Text(
                ask > 0.005 ? 'Request ${_money.format(ask)}' : 'Request payment',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        )
      else
        const SizedBox(height: 8),
      const Divider(height: 1, color: DashUi.line),
      if (_invoices.isNotEmpty) ...[
        _sectionHeading(_invoices.length == 1 ? 'Invoice' : 'Invoices'),
        for (final inv in _invoices) _invoiceLine(inv),
        if (paymentLines.isNotEmpty) _sectionHeading('Payments'),
      ],
      if (paymentLines.isEmpty)
        _detailsEmpty(Icons.payments_outlined, 'No payments recorded', 'Payments show here once they are received.', tone: DashUi.emeraldDeep)
      else ...[
        if (_invoices.isEmpty) const SizedBox(height: 6),
        ...paymentLines,
      ],
      const SizedBox(height: 6),
    ];
  }

  /// A Job Info row, drawn like a Details Summary row. A null value reads "Not set", as on Details (audit 2026-11-24,
  /// item 12).
  Widget _sfRow(IconData icon, String label, Widget? value) => _factRow(icon, label, value);

  /// "Site Visits (n)" strip at the bottom of the Job Info panel. Uses Service Fusion's own visits when synced
  /// (date, arrival window, duration, techs with status, notes); until then, the tech work days we recorded.
  static const int _visitsCollapsedCount = 3; // visits shown while the section is collapsed

  Widget _visitsSection() {
    final visits = _sfVisits; // only what Service Fusion lists: no visit rows from it means no visits
    final count = visits.length;
    // More than a handful of visits: collapsed by default to the latest few (keeping their real numbers, so the
    // hidden ones are the earliest). The control sits under the list, as the Notes card's does (audit item 34).
    final collapsible = count > _visitsCollapsedCount;
    final first = (collapsible && !_visitsExpanded) ? count - _visitsCollapsedCount : 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          decoration: const BoxDecoration(
            color: DashUi.faint,
            border: Border.symmetric(horizontal: BorderSide(color: DashUi.line)),
          ),
          child: Row(
            children: [
              const Icon(Icons.home_repair_service_outlined, size: 16, color: DashUi.subtle),
              const SizedBox(width: 8),
              Text(
                'Site visits ($count)',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: DashUi.slate),
              ),
            ],
          ),
        ),
        if (count == 0)
          Padding(padding: const EdgeInsets.all(20), child: _factText('No visits scheduled.', quiet: true))
        else
          ..._visitTimeline(visits, first),
        if (collapsible)
          _showAllToggle(
            expanded: _visitsExpanded,
            label: _visitsExpanded ? 'Show fewer visits' : 'Show all $count visits ($first earlier)',
            onTap: () => setState(() => _visitsExpanded = !_visitsExpanded),
          ),
      ],
    );
  }

  /// The visits as a timeline: a rail with a dot per visit (done, today, or still to come) and a "Today" marker
  /// where today falls between them. A closed job's visits are all behind it, so it gets no marker at the end.
  List<Widget> _visitTimeline(List<Map<String, dynamic>> visits, int first) {
    final today = _today;
    final closed = _day(_job?['closed_at']) != null;
    final shown = [for (var i = first; i < visits.length; i++) (i, visits[i], _day(visits[i]['start_date']))];
    final anyToday = shown.any((v) => v.$3 != null && _daysFrom(v.$3!, today) == 0);
    // The marker goes before the first visit still to come; after the last one when all are done (unless closed).
    int? markerAt;
    if (!anyToday) {
      final next = shown.indexWhere((v) => v.$3 != null && _daysFrom(today, v.$3!) > 0);
      if (next >= 0) {
        markerAt = next;
      } else if (shown.any((v) => v.$3 != null) && !closed) {
        markerAt = shown.length;
      }
    }
    return [
      const SizedBox(height: 4),
      for (var k = 0; k <= shown.length; k++) ...[
        if (markerAt == k) _todayMarker(today, rails: (top: k > 0, bottom: k < shown.length)),
        if (k < shown.length)
          _HoverRow(
            builder: (_) => _sfVisit(
              shown[k].$1,
              shown[k].$2,
              when: shown[k].$3 == null ? null : _daysFrom(today, shown[k].$3!).sign,
              rails: (top: k > 0 || markerAt == 0, bottom: k < shown.length - 1 || markerAt == shown.length),
            ),
          ),
      ],
      const SizedBox(height: 6),
    ];
  }

  static const double _railX = 30; // the timeline rail's centre, from the panel's left edge

  /// The rail behind a timeline entry: a line above and/or below its dot, whose centre is [dotY] down.
  Widget _rail({required Widget child, required ({bool top, bool bottom}) rails, required double dotY}) => Stack(
    children: [
      if (rails.top)
        Positioned(
          left: _railX - 1,
          top: 0,
          height: dotY,
          width: 2,
          child: const ColoredBox(color: DashUi.line),
        ),
      if (rails.bottom)
        Positioned(
          left: _railX - 1,
          top: dotY,
          bottom: 0,
          width: 2,
          child: const ColoredBox(color: DashUi.line),
        ),
      child,
    ],
  );

  Widget _todayMarker(DateTime today, {required ({bool top, bool bottom}) rails}) => _rail(
    rails: rails,
    dotY: 17,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(_railX - 6, 10, 20, 10),
      child: Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: DashUi.blue,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: [BoxShadow(color: DashUi.blue.withValues(alpha: 0.35), blurRadius: 6)],
            ),
          ),
          const SizedBox(width: 14),
          Text(
            'Today, ${DateFormat('MMM d').format(today)}',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: DashUi.blue),
          ),
          const SizedBox(width: 10),
          Expanded(child: Container(height: 1.5, color: DashUi.blue.withValues(alpha: 0.25))),
        ],
      ),
    ),
  );

  /// One visit on the timeline. [when] is -1 done, 0 today, 1 still to come, null undated.
  Widget _sfVisit(int i, Map<String, dynamic> v, {required int? when, required ({bool top, bool bottom}) rails}) {
    final window = _window(v['time_frame_promised_start'], v['time_frame_promised_end']);
    final dur = _duration(v['duration']);
    final dateText = _date(v['start_date']);
    final timeText = [window, if (dur.isNotEmpty) '($dur)'].where((e) => e.isNotEmpty).join('  ');
    final notes = (v['notes_for_techs'] ?? '').toString().trim();
    final techs = v['techs'] is List ? (v['techs'] as List).whereType<Map>().toList() : <Map>[];
    final Widget dot = switch (when) {
      -1 => Container(
        width: 18,
        height: 18,
        decoration: const BoxDecoration(color: DashUi.emeraldDeep, shape: BoxShape.circle),
        child: const Icon(Icons.check_rounded, size: 12, color: Colors.white),
      ),
      0 => const _LivePulse(color: DashUi.blue, size: 18),
      _ => Container(
        width: 18,
        height: 18,
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          border: Border.all(color: when == 1 ? DashUi.indigo : DashUi.muted, width: 2.5),
        ),
      ),
    };
    // Date and time share the title line, and a visit with no notes doesn't spend a line saying so.
    return _rail(
      rails: rails,
      dotY: 23,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(_railX - 9, 14, 20, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            dot,
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 12,
                    runSpacing: 2,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        'Visit ${i + 1}',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: when == 0 ? DashUi.blue : DashUi.ink),
                      ),
                      _factText(dateText.isEmpty ? 'Not set' : dateText, quiet: dateText.isEmpty),
                      _factText(timeText.isEmpty ? 'No time set' : timeText, quiet: true),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (techs.isEmpty)
                    _factText('Unassigned', quiet: true)
                  else
                    for (final t in techs)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6), // one tech per line
                        child: _techChip((t['name'] ?? '').toString(), (t['status'] ?? '').toString()),
                      ),
                  if (notes.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(top: 2, right: 8),
                            child: Icon(Icons.sticky_note_2_outlined, size: 15, color: DashUi.subtle),
                          ),
                          Expanded(child: _factText(notes)),
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

/// The Add Note / Add Task dialog, in the app's standard pop-up. It owns its
/// text box, so the box is only thrown away once the dialog is fully gone (disposing it right after the dialog closes
/// breaks the closing animation). An empty box is refused under the field; a failed save keeps the text and says why
/// above the buttons. Enter saves a one-line box, Ctrl+Enter a longer one, Esc cancels; nothing closes it mid-save.
class _TextDialog extends StatefulWidget {
  final String title;
  final String hint;
  final int maxLength;
  final int maxLines;
  final Future<String?> Function(String text) onSave;
  final IconData icon;
  final String? subtitle;
  final String saveLabel;
  const _TextDialog({
    required this.title,
    required this.hint,
    required this.maxLength,
    required this.maxLines,
    required this.onSave,
    this.icon = Icons.edit_note_rounded,
    this.subtitle,
    this.saveLabel = 'Save',
  });

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final _controller = TextEditingController();
  String? _empty; // shown under the field
  String? _failed; // shown above the buttons
  bool _saving = false;

  bool get _oneLine => widget.maxLines == 1;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final text = _controller.text.trim();
    if (text.isEmpty) {
      setState(() => _empty = 'Type something first.');
      return;
    }
    setState(() {
      _saving = true;
      _empty = null;
      _failed = null;
    });
    final err = await widget.onSave(text);
    if (!mounted) return;
    if (err == null) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _saving = false;
        _failed = err;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: _controller,
      autofocus: true,
      enabled: !_saving,
      maxLength: widget.maxLength,
      minLines: _oneLine ? 1 : 5,
      maxLines: widget.maxLines,
      textInputAction: _oneLine ? TextInputAction.done : TextInputAction.newline,
      onSubmitted: _oneLine ? (_) => _save() : null,
      onChanged: (_) {
        if (_empty != null) setState(() => _empty = null);
      },
      style: const TextStyle(fontSize: 14.5, color: DashUi.ink, height: 1.45),
      decoration: appFieldDecoration(hint: widget.hint, error: _empty),
    );
    return PopScope(
      canPop: !_saving,
      child: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.enter, control: true): _save},
        child: AppDialog(
          title: widget.title,
          subtitle: widget.subtitle,
          icon: widget.icon,
          width: 520,
          body: field,
          footer: _failed == null
              ? null
              : Container(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  decoration: BoxDecoration(
                    color: DashUi.red.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: DashUi.red.withValues(alpha: 0.25)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.error_outline_rounded, size: 18, color: DashUi.redText),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Not saved: ${_failed!.endsWith('.') ? _failed : '$_failed.'} Your text is still here, so you can try again.',
                          style: const TextStyle(fontSize: 13.5, color: DashUi.redText, height: 1.4),
                        ),
                      ),
                    ],
                  ),
                ),
          actions: [
            AppButton.ghost('Cancel', _saving ? null : () => Navigator.of(context).pop(false)),
            AppButton.ink(_saving ? 'Saving…' : widget.saveLabel, _saving ? null : _save, icon: _saving ? null : Icons.check_rounded),
          ],
        ),
      ),
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
/// office copies it to the customer. The payment lands on the job by itself once Stripe confirms it. In the app's
/// standard pop-up (audit 2026-11-24, item 18): pill choices, a quiet field that only takes a money amount, a warning
/// when the amount is more than is owed, and the server's refusal above the buttons.
class _PaymentLinkDialog extends StatefulWidget {
  final String jobId;
  final bool estimate;
  final double total;
  final double balance;
  const _PaymentLinkDialog({required this.jobId, required this.estimate, required this.total, required this.balance});

  @override
  State<_PaymentLinkDialog> createState() => _PaymentLinkDialogState();
}

class _PaymentLinkDialogState extends State<_PaymentLinkDialog> {
  final _amount = TextEditingController();
  final _amountFocus = FocusNode();
  final _money = NumberFormat.currency(symbol: r'$');

  /// Digits with at most one point and two decimals ("1.2.3" and "1.234" can't be typed).
  static final _moneyShape = RegExp(r'^\d*\.?\d{0,2}$');

  String _kind = 'custom';
  String? _amountError; // under the field
  String? _failed; // the server's refusal, above the buttons
  String? _url;
  bool _busy = false;

  String get _what => widget.estimate ? 'estimate' : 'job';

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
    _amountFocus.dispose();
    super.dispose();
  }

  void _pick(String kind, double amount) {
    _kind = kind;
    _amount.text = amount.toStringAsFixed(2);
    _amountError = null;
  }

  double? get _typed => double.tryParse(_amount.text.trim());

  /// A caution, not a block: a deposit on a bigger job or a combined payment can be right, so it only says so.
  String? get _caution {
    final a = _typed;
    if (a == null) return null;
    if (widget.total > 0 && a > widget.total + 0.005) {
      return 'That is more than the $_what total of ${_money.format(widget.total)}.';
    }
    if (widget.balance > 0 && a > widget.balance + 0.005) {
      return 'That is more than the ${_money.format(widget.balance)} balance due.';
    }
    return null;
  }

  Future<void> _create() async {
    if (_busy) return;
    final amount = _typed;
    if (amount == null || amount < 1) {
      setState(() => _amountError = r'Enter an amount of at least $1.00, like 125.00.');
      return;
    }
    setState(() {
      _busy = true;
      _amountError = null;
      _failed = null;
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
          _failed = body is Map && body['error'] != null ? body['error'].toString() : 'Could not create the link.';
          _busy = false;
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failed = 'Could not reach the server.';
        _busy = false;
      });
    }
  }

  Widget _form() {
    final options = <(String, String)>[
      if (widget.total > 0) ('deposit', '50% deposit'),
      if (widget.balance > 0) ('final', 'Balance due'),
      ('custom', 'Other amount'),
    ];
    final caution = _caution;
    final help = [
      if (widget.total > 0) '${widget.estimate ? 'Estimate' : 'Job'} total ${_money.format(widget.total)}',
      if (widget.balance > 0) '${_money.format(widget.balance)} due',
    ].join('  ·  ');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (options.length > 1) ...[
          AppSegmented<String>(
            value: _kind,
            options: options,
            onChanged: (k) => setState(() {
              switch (k) {
                case 'deposit':
                  _pick('deposit', widget.total / 2);
                case 'final':
                  _pick('final', widget.balance);
                default:
                  _kind = 'custom';
                  _amountFocus.requestFocus();
              }
            }),
          ),
          const SizedBox(height: 16),
        ],
        AppFieldLabel('Amount', help: help.isEmpty ? null : help),
        TextField(
          controller: _amount,
          focusNode: _amountFocus,
          autofocus: true,
          enabled: !_busy,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            TextInputFormatter.withFunction((before, after) => _moneyShape.hasMatch(after.text) ? after : before),
          ],
          textInputAction: TextInputAction.done,
          onChanged: (_) => setState(() {
            _kind = 'custom';
            _amountError = null;
          }),
          onSubmitted: (_) => _create(),
          style: const TextStyle(fontSize: 14.5, color: DashUi.ink, fontFeatures: [FontFeature.tabularFigures()]),
          decoration: appFieldDecoration(hint: '0.00', prefixText: r'$ ', error: _amountError),
        ),
        if (caution != null) ...[
          const SizedBox(height: 10),
          AppNotice(caution, kind: AppNoticeKind.warning),
        ],
      ],
    );
  }

  Widget _result(String url) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'Send this link to the customer for ${_money.format(_typed ?? 0)}:',
        style: const TextStyle(fontSize: 14, color: DashUi.ink, height: 1.4),
      ),
      const SizedBox(height: 10),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: DashUi.faint,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: DashUi.line),
        ),
        child: SelectableText(url, style: const TextStyle(fontSize: 13, color: DashUi.slate, height: 1.4)),
      ),
      const SizedBox(height: 10),
      Text(
        'It stays valid for 30 days. The payment appears on this $_what once the customer pays.',
        style: const TextStyle(fontSize: 13, color: DashUi.slate, height: 1.4),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final url = _url;
    return PopScope(
      canPop: !_busy,
      child: AppDialog(
        title: 'Request payment',
        subtitle: '${widget.estimate ? 'Estimate' : 'Job'} #${widget.jobId}',
        icon: Icons.link_rounded,
        width: 480,
        body: url == null ? _form() : _result(url),
        footer: url == null && _failed != null ? AppNotice(_failed!, kind: AppNoticeKind.error) : null,
        actions: url == null
            ? [
                AppButton.ghost('Cancel', _busy ? null : () => Navigator.of(context).pop()),
                AppButton.ink(_busy ? 'Creating…' : 'Create link', _busy ? null : _create, icon: _busy ? null : Icons.link_rounded),
              ]
            : [
                AppButton.ghost('Close', () => Navigator.of(context).pop()),
                AppButton.ghost('Open', () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)),
                AppButton.ink('Copy link', () async {
                  final messenger = ScaffoldMessenger.of(context);
                  await Clipboard.setData(ClipboardData(text: url));
                  messenger
                    ..hideCurrentSnackBar()
                    ..showSnackBar(const SnackBar(content: Text('Link copied')));
                }, icon: Icons.copy_rounded, autofocus: true),
              ],
      ),
    );
  }
}

/// Rises and fades in, a beat after the row above it (the Details rows when the block opens or its tab changes).
class _RiseIn extends StatelessWidget {
  final int index;
  final Widget child;
  const _RiseIn({super.key, required this.index, required this.child});

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    final delay = 35 * index.clamp(0, 8);
    final total = 260 + delay;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: total),
      curve: Interval(delay / total, 1, curve: Curves.easeOutCubic),
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, (1 - t) * 8), child: child),
      ),
    );
  }
}

/// The card at the top of Scheduling saying where the job stands in time, tinted in its [tone]. A [live] one (on site
/// today) has a pulsing dot in place of its icon.
class _TimingBanner extends StatelessWidget {
  final Color tone;
  final IconData icon;
  final String headline;
  final String detail;
  final bool live;
  const _TimingBanner({required this.tone, required this.icon, required this.headline, required this.detail, this.live = false});

  @override
  Widget build(BuildContext context) {
    final ink = Color.lerp(tone, Colors.black, 0.3)!;
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 16, 20, 6),
      padding: const EdgeInsets.fromLTRB(14, 12, 16, 12),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: tone.withValues(alpha: 0.22)),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: tone.withValues(alpha: 0.12), shape: BoxShape.circle),
            child: live ? _LivePulse(color: tone, size: 14) : Icon(icon, size: 20, color: tone),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  headline,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: ink, letterSpacing: -0.2),
                ),
                if (detail.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(detail, style: const TextStyle(fontSize: 13.5, color: DashUi.slate, height: 1.35)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A dot with a ring that keeps swelling out of it and fading: "this is happening now". Still with reduced motion.
class _LivePulse extends StatefulWidget {
  final Color color;
  final double size;
  const _LivePulse({required this.color, required this.size});

  @override
  State<_LivePulse> createState() => _LivePulseState();
}

class _LivePulseState extends State<_LivePulse> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    final dot = Container(
      width: s,
      height: s,
      decoration: BoxDecoration(
        color: widget.color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
      ),
    );
    return SizedBox(
      width: s,
      height: s,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) {
          final t = Curves.easeOut.transform(_c.value);
          return Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              if (_c.isAnimating)
                Transform.scale(
                  scale: 1 + t * 1.1,
                  child: Container(
                    width: s,
                    height: s,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: widget.color.withValues(alpha: 0.35 * (1 - t)),
                    ),
                  ),
                ),
              child!,
            ],
          );
        },
        child: dot,
      ),
    );
  }
}

/// A task's tick: an empty ring that fills green, with the check popping in, when the task is done. Without [onTap]
/// (Service Fusion's tasks, read-only here) it only shows the state, in grey. While [pending] (the tick is being
/// saved) it already shows the new state, a little faded, and can't be pressed again.
class _TaskCheck extends StatelessWidget {
  final bool done;
  final bool pending;
  final VoidCallback? onTap;
  const _TaskCheck({required this.done, this.pending = false, this.onTap});

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    final tone = onTap == null ? DashUi.muted : DashUi.emerald;
    final mark = AnimatedContainer(
      duration: still ? Duration.zero : const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: done ? tone : Colors.white,
        border: Border.all(color: done ? tone : (onTap == null ? DashUi.muted : DashUi.subtle), width: 2),
      ),
      child: AnimatedSwitcher(
        duration: still ? Duration.zero : const Duration(milliseconds: 260),
        transitionBuilder: (child, a) => ScaleTransition(
          scale: CurvedAnimation(parent: a, curve: Curves.easeOutBack),
          child: child,
        ),
        child: done
            ? const Icon(Icons.check_rounded, key: ValueKey('done'), size: 15, color: Colors.white)
            : const SizedBox.shrink(key: ValueKey('open')),
      ),
    );
    if (onTap == null) {
      return SizedBox(width: 48, height: 48, child: Center(child: mark)); // the same box as the IconButton, so the text lines up
    }
    // Still a live button while saving (a disabled one would drop keyboard focus); a press then does nothing.
    return IconButton(
      tooltip: pending ? 'Saving…' : (done ? 'Mark not done' : 'Mark done'),
      onPressed: pending ? () {} : onTap,
      icon: AnimatedOpacity(opacity: pending ? 0.55 : 1, duration: still ? Duration.zero : const Duration(milliseconds: 150), child: mark),
    );
  }
}

/// A row that knows when the pointer is over it (its builder may darken a label or icon). No shading (USER RULE
/// 2026-11-24: no hover shading on the job and estimate pages).
class _HoverRow extends StatefulWidget {
  final Widget Function(bool hover) builder;
  const _HoverRow({super.key, required this.builder});

  @override
  State<_HoverRow> createState() => _HoverRowState();
}

class _HoverRowState extends State<_HoverRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    child: AnimatedContainer(
      duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 150),
      color: Colors.transparent,
      child: widget.builder(_hover),
    ),
  );
}

/// Blue link text that underlines under the pointer or keyboard focus, with an optional leading icon and a tooltip.
class _DetailLink extends StatefulWidget {
  final String text;
  final VoidCallback onTap;
  final String? tip;
  final IconData? icon;
  final bool strong;
  const _DetailLink({required this.text, required this.onTap, this.tip, this.icon, this.strong = false});

  @override
  State<_DetailLink> createState() => _DetailLinkState();
}

class _DetailLinkState extends State<_DetailLink> {
  bool _lit = false;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      widget.text,
      style: TextStyle(
        fontSize: 14,
        height: 1.4,
        fontWeight: widget.strong ? FontWeight.w600 : FontWeight.w500,
        color: DashUi.blue,
        decoration: _lit ? TextDecoration.underline : TextDecoration.none,
        decorationColor: DashUi.blue,
      ),
    );
    return Tooltip(
      message: widget.tip ?? '',
      waitDuration: const Duration(milliseconds: 600),
      child: InkWell(
        mouseCursor: WidgetStateMouseCursor.clickable,
        onTap: widget.onTap,
        onHover: (v) => setState(() => _lit = v),
        onFocusChange: (v) => setState(() => _lit = v),
        borderRadius: BorderRadius.circular(4),
        hoverColor: Colors.transparent,
        child: widget.icon == null
            ? text
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(widget.icon, size: 15, color: DashUi.blue),
                  const SizedBox(width: 6),
                  Flexible(child: text),
                ],
              ),
      ),
    );
  }
}

/// One tab of the Details block: its name, icon and (for Pics and Docs) how many files it holds.
class _DetailTab {
  final String label;
  final IconData icon;
  final int count;
  const _DetailTab(this.label, this.icon, {this.count = 0});
}

/// The Details block's tabs: a soft track with a white pill that glides (with a touch of overshoot) to the tab picked.
/// Each tab has its icon and, when it holds files, a count badge; the open one is ink with a small pop of its icon,
/// the others brighten under the pointer and show a ring on keyboard focus. Motion is off with reduced motion.
class _DetailTabs extends StatefulWidget {
  final List<_DetailTab> tabs;
  final int selected;
  final ValueChanged<int> onSelect;

  /// A narrow block: tabs that aren't open show only their icon (and count), with the name as a tooltip.
  final bool compact;

  /// What a screen reader calls the tab group ("Details view", "Job Info view").
  final String label;
  const _DetailTabs({required this.tabs, required this.selected, required this.onSelect, this.compact = false, this.label = 'Details view'});

  /// The width of the full tab row (every tab with its name and count), to decide whether names fit.
  static double fullWidth(BuildContext context, List<_DetailTab> tabs) {
    double tw(String t, double size) => _JobDetailScreenState._textWidth(
      context,
      t,
      TextStyle(fontSize: size, fontWeight: FontWeight.w700, letterSpacing: size == 13 ? -0.1 : null, height: 1.2),
    );
    var w = 6.0 + 2; // the track's padding, plus a hair of slack
    for (final t in tabs) {
      w += 24 + 3 + 16 + 6 + tw(t.label, 13); // padding, focus border, icon, gap, name
      if (t.count > 0) w += 6 + (tw(t.count > 999 ? '999+' : '${t.count}', 11) + 10).clamp(18, double.infinity);
    }
    return w;
  }

  @override
  State<_DetailTabs> createState() => _DetailTabsState();
}

class _DetailTabsState extends State<_DetailTabs> {
  final _stack = GlobalKey();
  final _keys = <GlobalKey>[];
  Rect? _pill;
  int? _hover;
  int? _focus;

  void _measure() {
    if (!mounted) return;
    final stack = _stack.currentContext?.findRenderObject() as RenderBox?;
    final i = widget.selected;
    final box = i < 0 || i >= _keys.length ? null : _keys[i].currentContext?.findRenderObject() as RenderBox?;
    if (stack == null || box == null || !stack.hasSize || !box.hasSize) return;
    final r = box.localToGlobal(Offset.zero, ancestor: stack) & box.size;
    if (r != _pill) setState(() => _pill = r);
  }

  @override
  Widget build(BuildContext context) {
    while (_keys.length < widget.tabs.length) {
      _keys.add(GlobalKey());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    final still = MediaQuery.disableAnimationsOf(context);
    final pill = _pill;
    // Not selectable text: the app-wide selection's I-beam would replace the click cursor over the labels.
    return SelectionContainer.disabled(
      child: Semantics(
        container: true,
        label: widget.label,
        // The track: one quiet step darker than the grey ribbon it sits on, with no outline (2026-11-24 polish).
        child: Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(color: DashUi.line, borderRadius: BorderRadius.circular(10)),
          child: Stack(
            key: _stack,
            children: [
              if (pill != null)
                AnimatedPositioned(
                  duration: still ? Duration.zero : const Duration(milliseconds: 340),
                  curve: Curves.easeOutBack,
                  left: pill.left,
                  top: pill.top,
                  width: pill.width,
                  height: pill.height,
                  // The open tab: white, a hairline edge and a soft two-layer lift (a tight contact shadow plus a wide
                  // faint one), corners concentric with the track's.
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(7),
                      border: Border.all(color: DashUi.ink.withValues(alpha: 0.06)),
                      boxShadow: [
                        BoxShadow(color: DashUi.ink.withValues(alpha: 0.10), blurRadius: 2, offset: const Offset(0, 1)),
                        BoxShadow(color: DashUi.ink.withValues(alpha: 0.06), blurRadius: 8, offset: const Offset(0, 2)),
                      ],
                    ),
                  ),
                ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [for (var i = 0; i < widget.tabs.length; i++) _tab(i, still: still, drawPill: pill == null)],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tab(int i, {required bool still, required bool drawPill}) {
    final t = widget.tabs[i];
    final on = i == widget.selected;
    final lit = on || _hover == i;
    final d = still ? Duration.zero : const Duration(milliseconds: 180);
    final color = lit ? DashUi.ink : DashUi.slate;
    final tab = Semantics(
      key: _keys[i],
      button: true,
      selected: on,
      inMutuallyExclusiveGroup: true,
      label: t.count > 0 ? '${t.label}, ${t.count}' : t.label,
      excludeSemantics: true,
      onTap: () => widget.onSelect(i),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = i),
        onExit: (_) => setState(() => _hover = null),
        child: FocusableActionDetector(
          onShowFocusHighlight: (v) => setState(() => _focus = v ? i : (_focus == i ? null : _focus)),
          actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => widget.onSelect(i))},
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => widget.onSelect(i),
            // A fixed 32 px tab (a comfortable target that leaves the track even air in the 48 px ribbon). No hover
            // wash: nothing on this page shades under the pointer (USER RULE 2026-11-24); the label and icon darken.
            child: AnimatedContainer(
              duration: d,
              height: 32,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                // Until the pill is measured (first frame) the open tab draws its own.
                color: on && drawPill ? Colors.white : Colors.white.withValues(alpha: 0),
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: _focus == i ? DashUi.ink.withValues(alpha: 0.55) : Colors.transparent, width: 1.5),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TweenAnimationBuilder<double>(
                    key: ValueKey('icon-$i-$on'),
                    tween: Tween(begin: on && !still ? 0.7 : 1, end: 1),
                    duration: still ? Duration.zero : const Duration(milliseconds: 380),
                    curve: Curves.elasticOut,
                    builder: (context, k, child) => Transform.scale(scale: k, child: child),
                    child: Icon(t.icon, size: 16, color: color),
                  ),
                  if (!widget.compact || on) ...[
                    const SizedBox(width: 6),
                    AnimatedDefaultTextStyle(
                      duration: d,
                      style: DefaultTextStyle.of(context).style.merge(
                        TextStyle(
                          fontSize: 13,
                          fontWeight: on ? FontWeight.w700 : FontWeight.w600,
                          color: color,
                          letterSpacing: -0.1,
                          height: 1.2,
                          leadingDistribution: TextLeadingDistribution.even,
                        ),
                      ),
                      child: Text(t.label),
                    ),
                  ],
                  if (t.count > 0) ...[
                    const SizedBox(width: 6),
                    // The count: a small 18 px capsule, ink on the open tab, a soft grey a step darker than the track
                    // on the others.
                    AnimatedContainer(
                      duration: d,
                      height: 18,
                      constraints: const BoxConstraints(minWidth: 18),
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: on ? DashUi.ink : DashUi.ink.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        t.count > 999 ? '999+' : '${t.count}',
                        textAlign: TextAlign.center,
                        style: DefaultTextStyle.of(context).style.merge(
                          TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: on ? Colors.white : DashUi.slate,
                            height: 1,
                            leadingDistribution: TextLeadingDistribution.even,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return widget.compact && !on ? Tooltip(message: t.label, child: tab) : tab;
  }
}

/// A picture in the Pics grid: 4:3, its name on a soft shade along the bottom, "Added here" on our own uploads and a
/// remove button on them. Under the pointer it lifts, zooms in a touch and gets a blue edge.
class _PicTile extends StatefulWidget {
  final String url;
  final String name;
  final String comment;
  final String uploadedBy;
  final bool ours;
  final VoidCallback? onOpen;
  final VoidCallback? onRemove;
  const _PicTile({
    required this.url,
    required this.name,
    required this.comment,
    required this.uploadedBy,
    required this.ours,
    this.onOpen,
    this.onRemove,
  });

  @override
  State<_PicTile> createState() => _PicTileState();
}

class _PicTileState extends State<_PicTile> {
  bool _hover = false;
  bool _focus = false;

  Widget _placeholder(IconData icon) => Container(
    color: DashUi.faint,
    alignment: Alignment.center,
    child: Icon(icon, color: DashUi.subtle, size: 30),
  );

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    final d = still ? Duration.zero : const Duration(milliseconds: 200);
    final lit = (_hover || _focus) && widget.onOpen != null;
    final name = widget.name.isEmpty ? 'Picture' : widget.name;
    final open = widget.onOpen;
    return Tooltip(
      message: [name, if (widget.uploadedBy.isNotEmpty) 'Uploaded by ${widget.uploadedBy}', if (widget.comment.isNotEmpty) widget.comment].join('\n'),
      waitDuration: const Duration(milliseconds: 500),
      // Opens from the keyboard (Tab to it, Enter or Space) and tells a screen reader what it is, like a button.
      child: Semantics(
        button: open != null,
        image: open == null,
        label: [name, if (widget.comment.isNotEmpty) widget.comment].join(', '),
        hint: open == null ? null : 'Open picture',
        onTap: open,
        child: FocusableActionDetector(
        enabled: open != null,
        mouseCursor: open == null ? MouseCursor.defer : SystemMouseCursors.click,
        onShowFocusHighlight: (v) => setState(() => _focus = v),
        onShowHoverHighlight: (v) => setState(() => _hover = v),
        actions: {if (open != null) ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => open())},
        child: AnimatedSlide(
          duration: d,
          curve: Curves.easeOutCubic,
          offset: Offset(0, lit ? -0.015 : 0),
          child: AnimatedContainer(
            duration: d,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: lit ? DashUi.blue.withValues(alpha: 0.6) : DashUi.line, width: lit ? 1.5 : 1),
              boxShadow: [if (lit) BoxShadow(color: DashUi.ink.withValues(alpha: 0.10), blurRadius: 14, offset: const Offset(0, 6))],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(7),
              child: AspectRatio(
                aspectRatio: 4 / 3,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    GestureDetector(
                      onTap: widget.onOpen,
                      child: AnimatedScale(
                        duration: still ? Duration.zero : const Duration(milliseconds: 320),
                        curve: Curves.easeOutCubic,
                        scale: lit ? 1.05 : 1,
                        child: widget.url.isEmpty
                            ? _placeholder(Icons.image_not_supported_outlined)
                            : Image.network(
                                widget.url,
                                fit: BoxFit.cover,
                                // On the web build the bucket sends no CORS header; this falls back to a plain <img> so thumbnails still show.
                                webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
                                loadingBuilder: (_, child, progress) => progress == null ? child : _placeholder(Icons.image_outlined),
                                errorBuilder: (_, _, _) => _placeholder(Icons.broken_image_outlined), // not an image, or the link needs a login
                              ),
                      ),
                    ),
                    // The name on a shade that fades up from the bottom edge.
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: IgnorePointer(
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(10, 18, 10, 8),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.bottomCenter,
                              end: Alignment.topCenter,
                              colors: [DashUi.ink.withValues(alpha: 0.72), DashUi.ink.withValues(alpha: 0)],
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Colors.white),
                              ),
                              if (widget.comment.isNotEmpty)
                                Text(
                                  widget.comment,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 11.5, color: Colors.white.withValues(alpha: 0.85)),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (widget.ours)
                      Positioned(
                        top: 8,
                        left: 8,
                        child: IgnorePointer(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.92), borderRadius: BorderRadius.circular(999)),
                            child: const Text(
                              'Added here',
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: DashUi.ink),
                            ),
                          ),
                        ),
                      ),
                    if (widget.onRemove != null)
                      Positioned(
                        top: 6,
                        right: 6,
                        child: Tooltip(
                          message: 'Remove',
                          child: Material(
                            // One fill, pointer or not (USER RULE 2026-11-24, audit item 21: it darkened on hover).
                            color: DashUi.ink.withValues(alpha: 0.6),
                            shape: const CircleBorder(),
                            child: InkWell(
                              mouseCursor: WidgetStateMouseCursor.clickable,
                              customBorder: const CircleBorder(),
                              onTap: widget.onRemove,
                              child: const Padding(
                                padding: EdgeInsets.all(5),
                                child: Icon(Icons.close_rounded, size: 16, color: Colors.white),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        ),
      ),
    );
  }
}

/// A document in the Docs list: a tile coloured by its file type, its name, note and details, where it came from, and
/// (for our own) a remove button. The whole row opens it; under the pointer its name and open icon turn link blue, with
/// no shading (USER RULE 2026-11-24).
class _DocRow extends StatefulWidget {
  final String name;
  final String comment;
  final String meta;
  final bool ours;
  final bool private;
  final VoidCallback? onOpen;
  final VoidCallback? onRemove;
  const _DocRow({
    required this.name,
    required this.comment,
    required this.meta,
    required this.ours,
    required this.private,
    this.onOpen,
    this.onRemove,
  });

  @override
  State<_DocRow> createState() => _DocRowState();
}

class _DocRowState extends State<_DocRow> {
  bool _hover = false;

  /// The tile's label, its tint and a text-safe tone for the label, by file extension.
  static (String, Color, Color) _kind(String name) {
    final dot = name.lastIndexOf('.');
    final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    return switch (ext) {
      'pdf' => ('PDF', DashUi.red, DashUi.redText),
      'doc' || 'docx' || 'rtf' => ('DOC', DashUi.blue, DashUi.blue),
      'txt' => ('TXT', DashUi.slate, DashUi.slate),
      'xls' || 'xlsx' => ('XLS', DashUi.emerald, DashUi.emeraldText),
      'csv' => ('CSV', DashUi.emerald, DashUi.emeraldText),
      'ppt' || 'pptx' => ('PPT', DashUi.amber, DashUi.amberText),
      'dwg' || 'dxf' => (ext.toUpperCase(), DashUi.indigo, DashUi.ink),
      '' => ('FILE', DashUi.slate, DashUi.slate),
      _ => (ext.length > 4 ? ext.substring(0, 4).toUpperCase() : ext.toUpperCase(), DashUi.slate, DashUi.slate),
    };
  }

  @override
  Widget build(BuildContext context) {
    final (label, tint, tone) = _kind(widget.name);
    final d = MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 150);
    Widget chip(String text) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: DashUi.faint,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: DashUi.line),
      ),
      child: Text(
        text,
        style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: DashUi.slate),
      ),
    );
    final chips = [if (widget.private) chip('Private'), chip(widget.ours ? 'Added here' : 'Service Fusion')];
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: LayoutBuilder(
        builder: (context, c) {
          final narrow = c.maxWidth < 560;
          return InkWell(
            mouseCursor: WidgetStateMouseCursor.clickable,
            onTap: widget.onOpen,
            hoverColor: Colors.transparent,
            child: AnimatedContainer(
              duration: d,
              color: Colors.transparent,
              padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
              child: Row(
                children: [
                  AnimatedContainer(
                    duration: d,
                    width: 42,
                    height: 42,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: tint.withValues(alpha: 0.12), // no hover tint (audit item 21)
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      label,
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: tone, letterSpacing: 0.4),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: _hover && widget.onOpen != null ? DashUi.blue : DashUi.ink,
                            height: 1.3,
                          ),
                        ),
                        if (widget.comment.isNotEmpty) Text(widget.comment, style: const TextStyle(fontSize: 13, color: DashUi.slate, height: 1.35)),
                        if (widget.meta.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(widget.meta, style: const TextStyle(fontSize: 12, color: DashUi.subtle)),
                          ),
                        if (narrow)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Wrap(spacing: 6, runSpacing: 4, children: chips),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  if (!narrow) ...[for (final w in chips) Padding(padding: const EdgeInsets.only(left: 6), child: w)],
                  const SizedBox(width: 4),
                  if (widget.onRemove != null)
                    IconButton(
                      tooltip: 'Remove',
                      icon: const Icon(Icons.delete_outline_rounded, size: 20, color: DashUi.slate),
                      onPressed: widget.onRemove,
                    ),
                  if (widget.onOpen != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 2, right: 6),
                      child: Icon(Icons.open_in_new_rounded, size: 18, color: _hover ? DashUi.blue : DashUi.subtle),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A copy button that shows beside a Summary value while the pointer is on its row.
class _CopyValue extends StatelessWidget {
  final String text;
  final String what;

  /// The row is under the pointer: the icon darkens from its quiet resting grey. It is always shown (it used to fade
  /// to nothing yet stay clickable and focusable), so keyboard and touch users can find it too.
  final bool visible;
  final VoidCallback onCopy;
  const _CopyValue({required this.text, required this.what, required this.visible, required this.onCopy});

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Copy $what',
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints.tightFor(width: 28, height: 22),
    // No hover wash on this page (USER RULE 2026-11-24); focus and press still show.
    style: IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap).copyWith(overlayColor: dashNoHoverOverlay),
    iconSize: 16,
    icon: Icon(Icons.copy_rounded, color: visible ? DashUi.slate : DashUi.subtle),
    onPressed: onCopy,
  );
}
