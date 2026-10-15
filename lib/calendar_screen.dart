import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme/app_theme.dart';

import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import 'config/api_config.dart';
import 'config/auth_session.dart';
import 'utils/status_colors.dart';

// Kept public and unchanged in behavior: other screens may import it.
Color getStatusColor(String? status) => statusColor(status);

// =============================================================================
// THEME + HELPERS
// =============================================================================

const _ink = Color(0xFF1A1C1E);
const _slate = Color(0xFF4B5563);
const _muted = Color(0xFF9CA3AF);
const _line = Color(0xFFE5E7EB);
const _faint = Color(0xFFF3F4F6);
const _bg = AppTheme.bgColor;
const _brand = Color(0xFFCC0007);

/// Shade of the current day: its square is tinted rather than ringed or coloured.
const _todayBg = Color(0xFFE6EDF7);

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// Calendar-safe day math. (Adding Duration(days: 1) to a local DateTime repeats a day
/// when clocks fall back for daylight saving.)
DateTime _addDays(DateTime d, int n) => DateTime(d.year, d.month, d.day + n);

DateTime _dayKey(DateTime d) => DateTime.utc(d.year, d.month, d.day);
bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;
String _ymd(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

Color _onColor(Color c) => c.computeLuminance() > 0.55 ? const Color(0xFF111827) : Colors.white;

String _titleCase(String s) => s.split(RegExp(r'\s+')).map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1)).join(' ');

bool _truthy(dynamic v) => v == true || v == 1 || (v is String && (v.toLowerCase() == 'true' || v == 't' || v == '1'));

class _ChipStyle {
  final Color bg;
  final Color fg;
  final Color bar;
  final Color accent; // status color, for badges and tech dots
  const _ChipStyle(this.bg, this.fg, this.bar, this.accent);
}

_ChipStyle _styleFor(Color c) {
  return _ChipStyle(c.withValues(alpha: 0.12), const Color(0xFF1F2937), c, c);
}

// =============================================================================
// MODEL
// =============================================================================

class _CalEvent {
  final Map<String, dynamic> raw;
  final DateTime day; // UTC midnight of the calendar day
  final String status;
  final String customer;
  final String techs;
  final List<String> techList;
  final bool isEstimate;

  const _CalEvent({
    required this.raw,
    required this.day,
    required this.status,
    required this.customer,
    required this.techs,
    required this.techList,
    required this.isEstimate,
  });

  String get statusKey => status.trim().toLowerCase();

  /// What the status filter matches on. Jobs and estimates keep separate lists of statuses, so a status that
  /// exists on both (say "Scheduled") is two filters, one per kind.
  String get filterKey => '${isEstimate ? 'estimate' : 'job'}|$statusKey';

  String get statusLabel {
    final s = status.trim();
    if (s.isEmpty) return 'No status';
    return s == s.toLowerCase() ? _titleCase(s) : s;
  }

  Color get color => getStatusColor(status);

  /// "9:00 AM" / "9:00 AM - 11:00 AM" from the visit's promised time frame, or null for an all-day job.
  String? get timeLabel {
    String? fmt(dynamic v) {
      final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(v?.toString() ?? '');
      if (m == null) return null;
      final h = int.parse(m.group(1)!), min = m.group(2)!;
      if (h > 23) return null;
      final h12 = h % 12 == 0 ? 12 : h % 12;
      return '$h12:$min ${h < 12 ? 'AM' : 'PM'}';
    }

    final start = fmt(raw['time_start']);
    if (start == null) return null;
    final end = fmt(raw['time_end']);
    return end == null || end == start ? start : '$start - $end';
  }

  /// Minutes after midnight of the visit's start, or null for an all-day job (sorts first).
  int? get startMinutes {
    final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(raw['time_start']?.toString() ?? '');
    if (m == null) return null;
    final h = int.parse(m.group(1)!);
    return h > 23 ? null : h * 60 + int.parse(m.group(2)!);
  }

  /// "9a" / "9:30p" for the tight month chips; null for an all-day job.
  String? get shortTime {
    final s = startMinutes;
    if (s == null) return null;
    final h = s ~/ 60, min = s % 60;
    final h12 = h % 12 == 0 ? 12 : h % 12;
    return '$h12${min == 0 ? '' : ':${min.toString().padLeft(2, '0')}'}${h < 12 ? 'a' : 'p'}';
  }

  /// "Brett, Marcus": first names only, for the month chips; the full names are in the tooltip and the day view.
  String get techFirstNames => techList.map((t) => t.split(' ').first).join(', ');

  String get tooltip => [
    customer,
    statusLabel + (isEstimate ? ' (estimate)' : ''),
    timeLabel ?? 'All day',
    if (techs.isNotEmpty) 'Techs: $techs' else 'No tech assigned',
  ].join('\n');

  /// Reads the date straight from the yyyy-mm-dd prefix, so a timestamp or timezone suffix
  /// from the server can never shift the event onto a neighboring day.
  static DateTime? _parseDay(dynamic v) {
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(v?.toString() ?? '');
    if (m == null) return null;
    return DateTime.utc(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
  }

  static _CalEvent? tryParse(Map<String, dynamic> m) {
    final day = _parseDay(m['event_date']);
    if (day == null) return null;
    final techs = (m['techs'] ?? '').toString().trim();
    final customer = (m['customer_name'] ?? '').toString().trim();
    return _CalEvent(
      raw: m,
      day: day,
      status: (m['status'] ?? '').toString(),
      customer: customer.isEmpty ? 'Unknown Customer' : customer,
      techs: techs,
      techList: techs.isEmpty
          ? const []
          : techs.split(RegExp(r'\s*[,;&/]\s*')).map((t) => t.trim()).where((t) => t.isNotEmpty).toList(),
      isEstimate: _truthy(m['is_estimate']),
    );
  }
}

enum _CalView { month, week }

enum _TypeFilter { all, jobs, estimates }

/// Stands in for "no tech assigned" in the tech filter, so unstaffed jobs can be found.
const _unassigned = 'Unassigned';

// =============================================================================
// SCREEN
// =============================================================================

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  bool _loading = true;
  String? _error;
  int _requestId = 0;

  DateTime _focused = _dateOnly(DateTime.now());
  _CalView _view = _CalView.month;

  Map<DateTime, List<_CalEvent>> _byDay = {};
  DateTime? _loadedStart; // window currently held in memory: [start, end)
  DateTime? _loadedEnd;

  final FocusNode _focusNode = FocusNode();
  final Set<String> _techs = {};
  _TypeFilter _type = _TypeFilter.all;
  final Set<String> _statusFilter = {};

  @override
  void initState() {
    super.initState();
    _ensureLoaded();
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Date ranges
  // ---------------------------------------------------------------------------

  DateTime get _monthStart => DateTime(_focused.year, _focused.month, 1);
  DateTime get _gridStart => _addDays(_monthStart, -(_monthStart.weekday % 7)); // weeks start Sunday
  int get _weeksInGrid {
    final daysInMonth = DateTime(_focused.year, _focused.month + 1, 0).day;
    return ((_monthStart.weekday % 7) + daysInMonth + 6) ~/ 7;
  }

  DateTime get _weekStart => _addDays(_focused, -(_focused.weekday % 7));
  DateTime get _visibleStart => _view == _CalView.month ? _gridStart : _weekStart;
  DateTime get _visibleEnd => _addDays(_visibleStart, _view == _CalView.month ? _weeksInGrid * 7 : 7);

  // ---------------------------------------------------------------------------
  // Data
  // ---------------------------------------------------------------------------

  /// Fetches a 3-month window around the focused month, and only when the visible range
  /// isn't already inside the loaded window, so flipping between neighboring months is instant.
  Future<void> _ensureLoaded({bool force = false}) async {
    final vs = _visibleStart, ve = _visibleEnd;
    if (!force && _loadedStart != null && _loadedEnd != null && !vs.isBefore(_loadedStart!) && !ve.isAfter(_loadedEnd!)) {
      // Already held. Drop any request still in flight for a window we no longer need: if it landed it would
      // replace the data with a window that does not cover this view and leave the grid empty.
      if (_loading || _error != null) {
        _requestId++;
        setState(() {
          _loading = false;
          _error = null;
        });
      }
      return;
    }

    final id = ++_requestId;
    setState(() {
      _loading = true;
      _error = null;
    });

    final windowStart = DateTime(_focused.year, _focused.month - 1, 1);
    final windowEnd = DateTime(_focused.year, _focused.month + 2, 1);

    try {
      final uri = Uri.parse('$kApiBaseUrl/api/calendar/sync')
          .replace(queryParameters: {'start': _ymd(windowStart), 'end': _ymd(windowEnd)});
      final response = await http
          .get(uri, headers: AuthSession.instance.headers())
          .timeout(const Duration(seconds: 60)); // free-tier hosts can take ~30s+ to wake up

      if (!mounted || id != _requestId) {
        return; // a newer request superseded this one
      }
      if (response.statusCode == 401) {
        AuthSession.instance.logout(); // session expired: back to the sign-in screen
        return;
      }
      if (response.statusCode != 200) {
        throw Exception('The server returned status ${response.statusCode}.');
      }

      final dynamic body = json.decode(response.body);
      final dynamic rawList = body is Map ? body['events'] : body;
      final List<dynamic> list = rawList is List ? rawList : const [];

      final grouped = <DateTime, List<_CalEvent>>{};
      for (final item in list) {
        if (item is! Map) continue;
        final e = _CalEvent.tryParse(Map<String, dynamic>.from(item));
        if (e == null) continue;
        (grouped[e.day] ??= []).add(e);
      }
      for (final l in grouped.values) {
        l.sort((a, b) {
          // All-day first, then by start time, then jobs before estimates, then by name.
          final ta = a.startMinutes ?? -1, tb = b.startMinutes ?? -1;
          if (ta != tb) return ta.compareTo(tb);
          if (a.isEstimate != b.isEstimate) {
            return a.isEstimate ? 1 : -1;
          }
          return a.customer.toLowerCase().compareTo(b.customer.toLowerCase());
        });
      }

      setState(() {
        _byDay = grouped;
        _loadedStart = windowStart;
        _loadedEnd = windowEnd;
        _loading = false;
      });
    } on TimeoutException {
      _fail(id, 'The server took too long to respond.');
    } catch (e) {
      _fail(id, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  void _fail(int id, String message) {
    if (!mounted || id != _requestId) return;
    setState(() {
      _error = message;
      _loading = false;
    });
  }

  // ---------------------------------------------------------------------------
  // Filtering
  // ---------------------------------------------------------------------------

  bool _passes(_CalEvent e, {bool ignoreStatus = false}) {
    if (_type == _TypeFilter.jobs && e.isEstimate) return false;
    if (_type == _TypeFilter.estimates && !e.isEstimate) return false;
    if (_techs.isNotEmpty && !(e.techList.isEmpty ? const [_unassigned] : e.techList).any(_techs.contains)) {
      return false;
    }
    // Each kind is narrowed only by the statuses picked for that kind: choosing a job status leaves estimates alone.
    if (!ignoreStatus && _kindFiltered(e.isEstimate) && !_statusFilter.contains(e.filterKey)) return false;
    return true;
  }

  bool _kindFiltered(bool estimate) => _statusFilter.any((k) => k.startsWith(estimate ? 'estimate|' : 'job|'));

  List<_CalEvent> _eventsFor(DateTime day, {bool ignoreStatus = false}) {
    final list = _byDay[_dayKey(day)];
    if (list == null) return const [];
    return list.where((e) => _passes(e, ignoreStatus: ignoreStatus)).toList();
  }

  List<String> get _allTechs {
    final set = <String>{};
    var anyUnassigned = false;
    for (final l in _byDay.values) {
      for (final e in l) {
        set.addAll(e.techList);
        if (e.techList.isEmpty) anyUnassigned = true;
      }
    }
    return set.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()))
      ..addAll([if (anyUnassigned || _techs.contains(_unassigned)) _unassigned]);
  }

  /// Button label style from the app theme (a bare TextStyle would drop the theme's font on these buttons).
  TextStyle _buttonText(BuildContext context) =>
      (Theme.of(context).textTheme.labelLarge ?? const TextStyle()).copyWith(fontSize: 13, fontWeight: FontWeight.w700);

  /// The tech menu's checkboxes in black rather than the app's red accent.
  ThemeData _blackChecks(BuildContext context) => Theme.of(context).copyWith(
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? _ink : Colors.transparent),
      checkColor: const WidgetStatePropertyAll(Colors.white),
      side: const BorderSide(color: _slate, width: 1.5),
    ),
  );

  bool get _filtersActive => _techs.isNotEmpty || _type != _TypeFilter.all || _statusFilter.isNotEmpty;

  void _clearFilters() => setState(() {
    _techs.clear();
    _statusFilter.clear();
    _type = _TypeFilter.all;
  });

  // ---------------------------------------------------------------------------
  // Navigation
  // ---------------------------------------------------------------------------

  void _go(int dir) {
    setState(() {
      _focused = _view == _CalView.month ? DateTime(_focused.year, _focused.month + dir, 1) : _addDays(_focused, 7 * dir);
    });
    _ensureLoaded();
  }

  void _goToday() {
    setState(() => _focused = _dateOnly(DateTime.now()));
    _ensureLoaded();
  }

  void _setView(_CalView v) {
    if (v == _view) return;
    setState(() {
      _view = v;
      final today = _dateOnly(DateTime.now());
      // Month -> week: land on today's week when viewing the current month, else the 1st.
      if (v == _CalView.week && today.year == _focused.year && today.month == _focused.month) {
        _focused = today;
      }
    });
    _ensureLoaded();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _focused,
      firstDate: DateTime(2015),
      lastDate: DateTime(2100),
      helpText: 'JUMP TO DATE',
    );
    if (picked == null || !mounted) return;
    setState(() => _focused = _dateOnly(picked));
    _ensureLoaded();
  }

  bool _isTyping() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    return ctx?.findAncestorWidgetOfExactType<EditableText>() != null || ctx?.widget is EditableText;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || _isTyping()) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _go(-1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _go(1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyT) {
      _goToday();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  String get _periodTitle {
    if (_view == _CalView.month) {
      return DateFormat('MMMM yyyy').format(_focused);
    }
    final s = _weekStart;
    final e = _addDays(s, 6);
    if (s.month == e.month) {
      return '${DateFormat('MMM d').format(s)} – ${e.day}, ${e.year}';
    }
    return '${DateFormat('MMM d').format(s)} – ${DateFormat('MMM d, y').format(e)}';
  }

  // ---------------------------------------------------------------------------
  // Dialogs
  // ---------------------------------------------------------------------------

  void _openEvent(_CalEvent e) {
    final jobId = (e.raw['job_number'] ?? '').toString().trim();
    if (jobId.isNotEmpty) {
      context.go(
        '/jobs/${Uri.encodeComponent(jobId)}',
        extra: <String, dynamic>{
          'job_id': jobId,
          'customer_name': e.raw['customer_name'],
          'status': e.status,
          'is_estimate': e.isEstimate,
          'techs_assigned': e.techs,
        },
      );
      return;
    }
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.white,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460, maxHeight: 640),
          child: _EventDetails(event: e, onClose: () => Navigator.of(ctx).pop()),
        ),
      ),
    );
  }

  void _openDay(DateTime day) {
    final events = _eventsFor(day);
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.white,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480, maxHeight: 660),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 18, 10, 14),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            DateFormat('EEEE').format(day).toUpperCase(),
                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: _muted, letterSpacing: 1),
                          ),
                          Text(
                            DateFormat('MMMM d, y').format(day),
                            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: _ink),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            events.isEmpty ? 'Nothing scheduled' : '${events.length} ${events.length == 1 ? 'event' : 'events'}',
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _slate),
                          ),
                        ],
                      ),
                    ),
                    IconButton(onPressed: () => Navigator.of(ctx).pop(), icon: const Icon(Icons.close_rounded)),
                  ],
                ),
              ),
              const Divider(height: 1, color: _line),
              if (events.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(36),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.event_available_rounded, size: 40, color: Color(0xFFD1D5DB)),
                        SizedBox(height: 8),
                        Text(
                          'Nothing on the schedule',
                          style: TextStyle(color: _muted, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                )
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.all(16),
                    itemCount: events.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (_, i) => _EventCard(
                      event: events[i],
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _openEvent(events[i]);
                      },
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: _bg,
        body: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _header(),
              const SizedBox(height: 12),
              Expanded(child: _panel()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() {
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Calendar',
          style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: _ink),
        ),
      ],
    );

    final controls = Wrap(
      spacing: 10,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Theme(
          data: _blackChecks(context),
          child: MenuAnchor(
            menuChildren: [
              MenuItemButton(
                onPressed: _techs.isEmpty ? null : () => setState(() => _techs.clear()),
                child: const Text('All techs'),
              ),
              ..._allTechs.map(
                (t) => CheckboxMenuButton(
                  closeOnActivate: false,
                  value: _techs.contains(t),
                  onChanged: (on) => setState(() {
                    if (on == true) {
                      _techs.add(t);
                    } else {
                      _techs.remove(t);
                    }
                  }),
                  child: Text(t),
                ),
              ),
            ],
            builder: (context, controller, _) => Tooltip(
              message: 'Filter by tech (select several)',
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => controller.isOpen ? controller.close() : controller.open(),
                child: Container(
                  width: 200, // fixed, so ticking names never resizes the button and shifts the menu under it
                  height: 40,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: _techs.isNotEmpty ? _faint : Colors.white,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: _techs.isNotEmpty ? _muted : _line),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.max,
                    children: [
                      Icon(Icons.person_outline_rounded, size: 18, color: _techs.isNotEmpty ? _ink : _slate),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _techs.isEmpty ? 'All techs' : (_techs.toList()..sort()).join(', '),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _techs.isNotEmpty ? _ink : _slate),
                        ),
                      ),
                      const SizedBox(width: 2),
                      const Icon(Icons.expand_more_rounded, size: 18, color: _muted),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        _SegToggle<_TypeFilter>(
          options: const [(_TypeFilter.all, 'All'), (_TypeFilter.jobs, 'Jobs'), (_TypeFilter.estimates, 'Estimates')],
          value: _type,
          onChanged: (v) => setState(() => _type = v),
        ),
        _SegToggle<_CalView>(
          options: const [(_CalView.month, 'Month'), (_CalView.week, 'Week')],
          value: _view,
          onChanged: _setView,
        ),
        _IconPill(icon: Icons.refresh_rounded, tooltip: 'Refresh', onTap: () => _ensureLoaded(force: true)),
      ],
    );

    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth > 1000) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              title,
              const SizedBox(width: 24),
              Expanded(
                child: Align(alignment: Alignment.centerRight, child: controls),
              ),
            ],
          );
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [title, const SizedBox(height: 12), controls]);
      },
    );
  }

  Widget _panel() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Padding(padding: const EdgeInsets.fromLTRB(16, 10, 16, 6), child: _navRow()),
          SizedBox(
            height: 2,
            child: _loading
                ? const LinearProgressIndicator(color: _brand, backgroundColor: Colors.transparent, minHeight: 2)
                : null,
          ),
          if (_error != null) _errorBanner(),
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) {
                final grid = _withStatus(_view == _CalView.month ? _monthGrid() : _weekGrid());
                if (c.maxWidth < 760) {
                  return Column(
                    children: [
                      _legend(),
                      const Divider(height: 1, color: _line),
                      Expanded(child: grid),
                    ],
                  );
                }
                return Column(
                  children: [
                    const Divider(height: 1, color: _line),
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(width: 210, child: _legend(vertical: true)),
                          const VerticalDivider(width: 1, color: _line),
                          Expanded(child: grid),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// Loading pill while a window is fetching, and a note over a grid with nothing in it, so a quiet period or a
  /// filter that hides everything never looks like a broken page.
  Widget _withStatus(Widget grid) {
    var visible = 0;
    for (var d = _visibleStart; d.isBefore(_visibleEnd); d = _addDays(d, 1)) {
      visible += _eventsFor(d).length;
    }
    final empty = !_loading && _error == null && visible == 0;
    return Stack(
      fit: StackFit.expand,
      children: [
        grid,
        if (_loading)
          Positioned(
            top: 10,
            left: 0,
            right: 0,
            child: Center(
              child: Material(
                color: Colors.white,
                elevation: 2,
                shadowColor: Colors.black26,
                borderRadius: BorderRadius.circular(20),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: _brand)),
                      SizedBox(width: 10),
                      Text(
                        'Loading schedule…',
                        style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: _slate),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        if (empty)
          Center(
            // Only the note itself takes clicks (for "Clear filters"); the empty days behind it stay clickable.
            child: IgnorePointer(
              ignoring: !_filtersActive,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: _line),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.event_available_rounded, size: 30, color: _muted),
                    const SizedBox(height: 6),
                    Text(
                      _filtersActive
                          ? 'Nothing matches these filters'
                          : 'Nothing scheduled this ${_view == _CalView.month ? 'month' : 'week'}',
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _slate),
                    ),
                    if (_filtersActive) TextButton(onPressed: _clearFilters, child: const Text('Clear filters')),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _navRow() {
    return Stack(
      alignment: Alignment.center,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _NavBtn(
                icon: Icons.chevron_left_rounded,
                tooltip: _view == _CalView.month ? 'Previous month (←)' : 'Previous week (←)',
                onTap: () => _go(-1),
              ),
              const SizedBox(width: 4),
              _NavBtn(
                icon: Icons.chevron_right_rounded,
                tooltip: _view == _CalView.month ? 'Next month (→)' : 'Next week (→)',
                onTap: () => _go(1),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: 'Jump to today (T)',
                child: OutlinedButton(
                  onPressed: _goToday,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _ink,
                    side: const BorderSide(color: _line),
                    minimumSize: const Size(0, 38),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    textStyle: _buttonText(context),
                  ),
                  child: const Text('Today'),
                ),
              ),
            ],
          ),
        ),
        // Out here, not in the header, so showing it never moves the controls the user is clicking.
        if (_filtersActive)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _clearFilters,
              icon: const Icon(Icons.filter_alt_off_outlined, size: 17),
              label: const Text('Clear filters'),
              style: TextButton.styleFrom(
                foregroundColor: _slate,
                minimumSize: const Size(0, 38),
                textStyle: _buttonText(context),
              ),
            ),
          ),
        // Centered between the arrows; the side padding keeps it clear of them.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 170),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: _pickDate,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        _periodTitle,
                        maxLines: 1,
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: _ink),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.expand_more_rounded, color: _muted),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _errorBanner() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFFECACA)),
      ),
      child: Row(
        children: [
          const Icon(Icons.cloud_off_rounded, size: 18, color: Color(0xFFB91C1C)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _loadedStart == null
                  ? "Couldn't load the calendar. ${_error ?? ''}"
                  : "Couldn't refresh the calendar. ${_error ?? ''} Showing the last loaded data.",
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF991B1B)),
            ),
          ),
          TextButton(onPressed: () => _ensureLoaded(force: true), child: const Text('Retry')),
        ],
      ),
    );
  }

  Widget _legend({bool vertical = false}) {
    final counts = <String, int>{};
    final labels = <String, String>{};
    for (var d = _visibleStart; d.isBefore(_visibleEnd); d = _addDays(d, 1)) {
      for (final e in _eventsFor(d, ignoreStatus: true)) {
        counts[e.filterKey] = (counts[e.filterKey] ?? 0) + 1;
        labels[e.filterKey] = e.statusLabel;
      }
    }
    // A status picked earlier stays listed (at 0) after you move to a period without it, so the filter that is
    // hiding everything can always be switched off here.
    for (final k in _statusFilter) {
      counts.putIfAbsent(k, () => 0);
      labels.putIfAbsent(k, () => _titleCase(k.split('|').last));
    }
    if (counts.isEmpty) return const SizedBox.shrink();

    // Job statuses and estimate statuses are separate lists, each busiest first.
    List<String> keysOf(String kind) =>
        counts.keys.where((k) => k.startsWith('$kind|')).toList()..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    final groups = [
      ('JOB STATUS', 'Jobs', keysOf('job')),
      ('ESTIMATE STATUS', 'Estimates', keysOf('estimate')),
    ].where((g) => g.$3.isNotEmpty).toList();

    Widget chip(String k, {bool expand = false}) => _LegendChip(
      label: labels[k]!,
      color: getStatusColor(k.split('|').last),
      count: counts[k]!,
      selected: _statusFilter.contains(k),
      dimmed: _kindFiltered(k.startsWith('estimate|')) && !_statusFilter.contains(k),
      expand: expand,
      onTap: () => setState(() {
        if (!_statusFilter.remove(k)) _statusFilter.add(k);
      }),
    );

    if (vertical) {
      return ListView(
        padding: const EdgeInsets.all(12),
        children: [
          for (var i = 0; i < groups.length; i++) ...[
            Padding(
              padding: EdgeInsets.fromLTRB(4, i == 0 ? 0 : 14, 4, 10),
              child: Text(
                groups[i].$1,
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w900, color: _ink, letterSpacing: 0.8),
              ),
            ),
            for (final k in groups[i].$3) Padding(padding: const EdgeInsets.only(bottom: 6), child: chip(k, expand: true)),
          ],
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 2, 0, 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            for (var i = 0; i < groups.length; i++) ...[
              Padding(
                padding: EdgeInsets.only(left: i == 0 ? 0 : 10, right: 8),
                child: Text(
                  groups[i].$2.toUpperCase(),
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w900, color: _ink, letterSpacing: 0.8),
                ),
              ),
              for (final k in groups[i].$3) Padding(padding: const EdgeInsets.only(right: 8), child: chip(k)),
            ],
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Month view
  // ---------------------------------------------------------------------------

  static const _minRowH = 104.0;
  static const _chipGap = 3.0;
  static const _dayHeaderH = 26.0;

  /// Weekday header stays put. Every event on a day is shown (never "+N more"): each week is as tall as its busiest
  /// day needs, and at least tall enough to fill the window, so a quiet month fits and a busy one scrolls.
  Widget _monthGrid() {
    const days = ['SUN', 'MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT'];
    const headerH = 34.0;

    return LayoutBuilder(
      builder: (context, c) {
        final weeks = _weeksInGrid;
        final start = _gridStart;
        final twoLine = c.maxWidth / 7 >= 170; // roomy cells show the tech names under the customer
        final chipH = twoLine ? 36.0 : 22.0;
        final fill = math.max(_minRowH, ((c.maxHeight - headerH) / weeks).floorToDouble());

        double rowHeight(int w) {
          var most = 0;
          for (var d = 0; d < 7; d++) {
            most = math.max(most, _eventsFor(_addDays(start, w * 7 + d)).length);
          }
          // top and bottom padding (4 + 3), the day number, then a chip and its gap per event
          return math.max(fill, 4 + 3 + _dayHeaderH + most * (chipH + _chipGap) + 2);
        }

        return Column(
          children: [
            Container(
              height: headerH,
              decoration: const BoxDecoration(
                color: Color(0xFFF9FAFB),
                border: Border(bottom: BorderSide(color: _line)),
              ),
              child: Row(
                children: [
                  for (final d in days)
                    Expanded(
                      child: Center(
                        child: Text(
                          d,
                          style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: _slate, letterSpacing: 1.2),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (var w = 0; w < weeks; w++)
                      SizedBox(
                        height: rowHeight(w),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (var d = 0; d < 7; d++)
                              Expanded(
                                child: _monthCell(_addDays(start, w * 7 + d), d == 6, twoLine: twoLine, chipH: chipH),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _monthCell(DateTime day, bool lastCol, {required bool twoLine, required double chipH}) {
    final inMonth = day.month == _focused.month;
    final isToday = _sameDay(day, DateTime.now());
    final events = _eventsFor(day);

    final bg = isToday ? _todayBg : (!inMonth ? const Color(0xFFF9FAFB) : Colors.white);

    return Material(
      color: bg,
      child: InkWell(
        onTap: () => _openDay(day),
        hoverColor: _faint.withValues(alpha: 0.7),
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              right: lastCol ? BorderSide.none : const BorderSide(color: _line),
              bottom: const BorderSide(color: _line),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(5, 4, 5, 3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: _dayHeaderH,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 24),
                    height: 24,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    decoration: null,
                    child: Center(
                      widthFactor: 1,
                      child: FittedBox(
                        fit: BoxFit.scaleDown, // "Oct 1" must shrink, not overflow, in phone-width cells
                        child: Text(
                          day.day == 1 ? '${DateFormat('MMM').format(day)} 1' : '${day.day}',
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: isToday ? FontWeight.w800 : FontWeight.w700,
                            color: inMonth ? _ink : _muted,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              for (final e in events)
                Padding(
                  padding: const EdgeInsets.only(bottom: _chipGap),
                  child: SizedBox(
                    height: chipH,
                    child: _EventChip(event: e, twoLine: twoLine, dimmed: !inMonth, onTap: () => _openEvent(e)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Week view
  // ---------------------------------------------------------------------------

  Widget _weekGrid() {
    return LayoutBuilder(
      builder: (context, c) {
        final colW = math.max(140.0, c.maxWidth / 7); // seven days fit a 1280 window without sideways scrolling
        final start = _weekStart;
        final row = SizedBox(
          width: colW * 7,
          height: c.maxHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (var i = 0; i < 7; i++) Expanded(child: _weekColumn(_addDays(start, i), i == 6))],
          ),
        );
        if (colW * 7 > c.maxWidth + 0.5) {
          return SingleChildScrollView(scrollDirection: Axis.horizontal, child: row);
        }
        return row;
      },
    );
  }

  Widget _weekColumn(DateTime day, bool last) {
    final isToday = _sameDay(day, DateTime.now());
    final events = _eventsFor(day);
    return Container(
      decoration: BoxDecoration(
        color: isToday ? _todayBg : (day.weekday >= 6 ? const Color(0xFFFCFCFD) : Colors.white),
        border: Border(right: last ? BorderSide.none : const BorderSide(color: _line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => _openDay(day),
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: _line)),
              ),
              child: Row(
                children: [
                  Container(
                    constraints: const BoxConstraints(minWidth: 34),
                    height: 34,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: _faint, borderRadius: BorderRadius.circular(10)),
                    child: Text(
                      '${day.day}',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: _ink),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          DateFormat('EEE').format(day).toUpperCase(),
                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: _slate, letterSpacing: 1),
                        ),
                        Text(
                          events.isEmpty ? 'No events' : '${events.length} ${events.length == 1 ? 'event' : 'events'}',
                          style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: _muted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: events.isEmpty
                ? const Center(
                    child: Text(
                      'No events',
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: _muted),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(10),
                    itemCount: events.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (_, i) => _EventCard(event: events[i], onTap: () => _openEvent(events[i])),
                  ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// EVENT WIDGETS
// =============================================================================

/// Compact chip for the month grid: one line (time + customer), or two (customer, then time and techs) in roomy cells.
class _EventChip extends StatelessWidget {
  final _CalEvent event;
  final bool twoLine;
  final bool dimmed; // days outside the focused month
  final VoidCallback onTap;
  const _EventChip({required this.event, required this.twoLine, required this.onTap, this.dimmed = false});

  @override
  Widget build(BuildContext context) {
    final st = _styleFor(event.color);
    final techs = event.techs.isEmpty ? 'No tech' : event.techFirstNames;

    return Opacity(
      opacity: dimmed ? 0.6 : 1,
      child: Tooltip(
        message: event.tooltip,
        waitDuration: const Duration(milliseconds: 450),
        child: Material(
          color: st.bg,
          borderRadius: BorderRadius.circular(6),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 3.5, color: st.bar),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, c) => Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      // Phone-width cells are ~60px: just the name, the rest is in the tooltip and the day view.
                      child: _text(st, techs, micro: c.maxWidth < 96),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _text(_ChipStyle st, String techs, {required bool micro}) {
    final time = micro ? null : event.shortTime;
    return micro
        ? Align(
            alignment: Alignment.centerLeft,
            child: Text(
              event.customer,
              maxLines: 1,
              overflow: TextOverflow.clip,
              softWrap: false,
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: st.fg),
            ),
          )
        : twoLine
        ? Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      event.customer,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: st.fg, height: 1.15),
                    ),
                  ),
                  if (event.isEstimate) ...[const SizedBox(width: 4), _EstBadge(color: st.fg)],
                ],
              ),
              Text(
                [event.timeLabel ?? 'All day', techs].join('  ·  '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: st.fg.withValues(alpha: 0.7), height: 1.2),
              ),
            ],
          )
        : Row(
            children: [
              if (time != null) ...[
                Text(
                  time,
                  style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: st.fg.withValues(alpha: 0.7)),
                ),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: Text(
                  event.customer,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: st.fg),
                ),
              ),
              if (event.isEstimate) ...[const SizedBox(width: 4), _EstBadge(color: st.fg)],
            ],
          );
  }
}

/// Larger card used in the week view and the day dialog.
class _EventCard extends StatelessWidget {
  final _CalEvent event;
  final VoidCallback onTap;
  const _EventCard({required this.event, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final st = _styleFor(event.color);
    final pillBg = event.color;
    final pillFg = _onColor(event.color);

    return Material(
      color: st.bg,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 5, color: st.bar),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 9, 10, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(color: pillBg, borderRadius: BorderRadius.circular(5)),
                              child: Text(
                                event.statusLabel.toUpperCase(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, color: pillFg, letterSpacing: 0.5),
                              ),
                            ),
                          ),
                          if (event.isEstimate) ...[const SizedBox(width: 6), _EstBadge(color: st.fg)],
                        ],
                      ),
                      const SizedBox(height: 6),
                      // When the visit is; all-day jobs say so, so every card answers "when" the same way.
                      Text(
                        event.timeLabel ?? 'All day',
                        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: st.fg.withValues(alpha: 0.7)),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        event.customer,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: st.fg, height: 1.2),
                      ),
                      if (event.techs.isEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          'No tech assigned',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            fontStyle: FontStyle.italic,
                            color: st.fg.withValues(alpha: 0.6),
                          ),
                        ),
                      ] else ...[
                        const SizedBox(height: 6),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.person_outline_rounded, size: 14, color: st.fg.withValues(alpha: 0.75)),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                event.techs,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: st.fg.withValues(alpha: 0.85),
                                  height: 1.2,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EstBadge extends StatelessWidget {
  final Color color;
  const _EstBadge({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        'EST',
        style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.w800, color: color, letterSpacing: 0.4, height: 1.2),
      ),
    );
  }
}

// =============================================================================
// EVENT DETAILS DIALOG
// =============================================================================

class _EventDetails extends StatelessWidget {
  final _CalEvent event;
  final VoidCallback onClose;
  const _EventDetails({required this.event, required this.onClose});

  static const _known = {'event_date', 'status', 'is_estimate', 'customer_name', 'techs'};

  static String _prettyKey(String k) => _titleCase(k.replaceAll(RegExp(r'[_\-]+'), ' ').trim());

  @override
  Widget build(BuildContext context) {
    final c = event.color;
    final on = _onColor(c);

    final extras = <MapEntry<String, String>>[];
    event.raw.forEach((k, v) {
      if (_known.contains(k) || v == null || v is Map || v is List) return;
      final s = v.toString().trim();
      if (s.isEmpty) return;
      extras.add(MapEntry(_prettyKey(k), s));
    });

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 20),
          color: c,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                    decoration: BoxDecoration(color: on.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(6)),
                    child: Text(
                      event.statusLabel.toUpperCase(),
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: on, letterSpacing: 0.6),
                    ),
                  ),
                  if (event.isEstimate) ...[const SizedBox(width: 8), _EstBadge(color: on)],
                ],
              ),
              const SizedBox(height: 12),
              Text(
                event.customer,
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: on, height: 1.15),
              ),
            ],
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _DetailRow(icon: Icons.event_rounded, label: 'Date', value: DateFormat('EEEE, MMMM d, y').format(event.day)),
                _DetailRow(icon: Icons.assignment_outlined, label: 'Type', value: event.isEstimate ? 'Estimate' : 'Job'),
                _DetailRow(
                  icon: Icons.engineering_outlined,
                  label: event.techList.length > 1 ? 'Techs' : 'Tech',
                  value: event.techs.isEmpty ? 'Unassigned' : event.techs,
                ),
                for (final x in extras) _DetailRow(icon: Icons.notes_rounded, label: x.key, value: x.value),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          child: Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: onClose, child: const Text('Close')),
          ),
        ),
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _DetailRow({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 30, child: Icon(icon, size: 18, color: _muted)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label.toUpperCase(),
                  style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: _muted, letterSpacing: 0.7),
                ),
                const SizedBox(height: 2),
                SelectableText(
                  value,
                  style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: _ink),
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
// CONTROLS
// =============================================================================

class _SegToggle<T> extends StatelessWidget {
  final List<(T, String)> options;
  final T value;
  final ValueChanged<T> onChanged;
  const _SegToggle({required this.options, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: _faint, borderRadius: BorderRadius.circular(10)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final o in options)
            Semantics(
              button: true,
              selected: o.$1 == value,
              label: o.$2,
              excludeSemantics: true,
              child: InkWell(
                // A real InkWell, so the toggle can be reached and switched with the keyboard.
                borderRadius: BorderRadius.circular(8),
                onTap: () => onChanged(o.$1),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: o.$1 == value ? Colors.white : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: o.$1 == value ? _line : Colors.transparent),
                  ),
                  child: Text(
                    o.$2,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: o.$1 == value ? FontWeight.w800 : FontWeight.w600,
                      color: o.$1 == value ? _ink : _slate,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _IconPill extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _IconPill({required this.icon, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: _line),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: SizedBox(width: 40, height: 40, child: Icon(icon, size: 19, color: _slate)),
        ),
      ),
    );
  }
}

class _NavBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _NavBtn({required this.icon, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: _faint,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: SizedBox(width: 38, height: 38, child: Icon(icon, size: 24, color: _ink)),
        ),
      ),
    );
  }
}

class _LegendChip extends StatelessWidget {
  final String label;
  final Color color;
  final int count;
  final bool selected;
  final bool dimmed;
  final bool expand; // fill the row (sidebar) instead of hugging the text (wrapped strip)
  final VoidCallback onTap;
  const _LegendChip({
    required this.label,
    required this.color,
    required this.count,
    required this.selected,
    required this.dimmed,
    required this.onTap,
    this.expand = false,
  });

  @override
  Widget build(BuildContext context) {
    final chip = AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: selected ? color.withValues(alpha: 0.14) : Colors.white,
        borderRadius: BorderRadius.circular(expand ? 10 : 20),
        border: Border.all(color: selected ? color : _line, width: selected ? 1.5 : 1),
      ),
      child: Row(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(color: dimmed ? color.withValues(alpha: 0.35) : color, shape: BoxShape.circle), // fade the dot, never the text
          ),
          const SizedBox(width: 8),
          // In the sidebar the label takes every spare pixel (a Spacer here would split them and cut the label short).
          if (expand)
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: _ink),
              ),
            )
          else
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: _ink),
              ),
            ),
          const SizedBox(width: 8),
          Text(
            '$count',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: dimmed ? _muted : _slate),
          ),
        ],
      ),
    );
    return Semantics(
      button: true,
      selected: selected,
      label: '$label, $count',
      excludeSemantics: true,
      child: Tooltip(
        message: selected ? 'Showing only $label. Click to remove' : 'Show only $label',
        waitDuration: const Duration(milliseconds: 600),
        child: InkWell(
          borderRadius: BorderRadius.circular(expand ? 10 : 20),
          onTap: onTap,
          child: chip,
        ),
      ),
    );
  }
}
