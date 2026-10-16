import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme/app_theme.dart';

import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config/api_config.dart';
import 'config/auth_session.dart';
import 'utils/status_colors.dart';
import 'widgets/dashboard_kit.dart' show SkeletonPulse;

// Kept public and unchanged in behavior: other screens may import it.
Color getStatusColor(String? status) => statusColor(status);

// =============================================================================
// THEME + HELPERS
// =============================================================================

const _ink = AppTheme.primaryText;
const _slate = AppTheme.secondaryText;
const _muted = AppTheme.sectionLabel;

/// For muted text people actually read (counts, empty-state notes, field labels). `_muted` is only ~2.5:1 on white.
const _mutedText = AppTheme.mutedText;
const _line = AppTheme.strokeBorder;
const _faint = AppTheme.subtleFill;
const _faintLight = AppTheme.subtleFillLight;
const _brand = AppTheme.brandRed;

/// Shade of the current day: its square is tinted rather than ringed or coloured.
const _todayBg = AppTheme.todayTint;

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// Calendar-safe day math. (Adding Duration(days: 1) to a local DateTime repeats a day
/// when clocks fall back for daylight saving.)
DateTime _addDays(DateTime d, int n) => DateTime(d.year, d.month, d.day + n);

DateTime _dayKey(DateTime d) => DateTime.utc(d.year, d.month, d.day);
bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;
String _ymd(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

String _titleCase(String s) =>
    s.split(RegExp(r'\s+')).map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1)).join(' ');

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

/// A load failure whose message is already fit to show. Anything else (a dropped connection, a malformed reply) is
/// described in plain words instead of printing the raw exception, which includes the request URL.
class _CalendarError implements Exception {
  final String message;
  const _CalendarError(this.message);
}

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
    if (end == null || end == start) return start;
    // "9:30–11:00 AM" when both fall in the same half of the day: short enough never to wrap awkwardly.
    if (start.endsWith('AM') == end.endsWith('AM')) {
      return '${start.substring(0, start.length - 3)}–$end';
    }
    return '$start – $end';
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
  /// A first name shared by two people on the schedule ([ambiguous]) gets the last initial ("Brett H.").
  String shortTechs(Set<String> ambiguous) => techList
      .map((t) {
        final parts = t.split(RegExp(r'\s+'));
        final first = parts.first;
        if (parts.length > 1 && ambiguous.contains(first.toLowerCase())) return '$first ${parts.last[0]}.';
        return first;
      })
      .join(', ');

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
    var techs = (m['techs'] ?? '').toString().trim();
    // The server writes "Unassigned" when a job has no tech; that is the absence of a name, not a person called that.
    if (techs.toLowerCase() == 'unassigned') techs = '';
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
  Timer? _slowTimer;
  Timer? _refreshTimer;
  bool _slowLoad = false; // still loading after a few seconds: the free-tier server is probably waking up
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

  /// First names shared by more than one tech on the loaded schedule; month chips add a last initial for them.
  Set<String> _ambiguous = const {};

  /// A background refresh failed, so what is on screen may be out of date (and when it was last good).
  bool _stale = false;
  DateTime? _loadedAt;

  @override
  void initState() {
    super.initState();
    _restoreTechs();
    _ensureLoaded();
    // Pick up changes made elsewhere (new jobs, rescheduled visits) and roll "today" over at midnight, without a spinner.
    _refreshTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      if (!mounted) return;
      if (!_loading) _ensureLoaded(force: true, quiet: true);
      setState(() {});
    });
  }

  @override
  void dispose() {
    _slowTimer?.cancel();
    _refreshTimer?.cancel();
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
  ///
  /// [quiet] is for the background refresh: no loading indicator, and a failure keeps what is on screen.
  Future<void> _ensureLoaded({bool force = false, bool quiet = false}) async {
    final vs = _visibleStart, ve = _visibleEnd;
    if (!force &&
        _loadedStart != null &&
        _loadedEnd != null &&
        !vs.isBefore(_loadedStart!) &&
        !ve.isAfter(_loadedEnd!)) {
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
    if (!quiet) {
      setState(() {
        _loading = true;
        _slowLoad = false;
        _error = null;
      });
      _slowTimer?.cancel();
      _slowTimer = Timer(const Duration(seconds: 8), () {
        if (mounted && id == _requestId && _loading) setState(() => _slowLoad = true);
      });
    }

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
      if (response.statusCode == 403) {
        throw const _CalendarError("Your account doesn't have access to the calendar.");
      }
      if (response.statusCode != 200) {
        throw _CalendarError('The server returned status ${response.statusCode}.');
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

      final firstNames = <String, Set<String>>{};
      for (final l in grouped.values) {
        for (final e in l) {
          for (final t in e.techList) {
            (firstNames[t.split(RegExp(r'\s+')).first.toLowerCase()] ??= {}).add(t.toLowerCase());
          }
        }
      }
      setState(() {
        _byDay = grouped;
        _ambiguous = {
          for (final k in firstNames.entries)
            if (k.value.length > 1) k.key,
        };
        _loadedStart = windowStart;
        _loadedEnd = windowEnd;
        _loadedAt = DateTime.now();
        _loading = false;
        _error = null;
        _stale = false;
      });
      // The window is centred on the month that was focused when this request started. If you moved on within the old
      // window while it ran (a background refresh does this), what is on screen may now fall outside the new one.
      if (_visibleStart.isBefore(windowStart) || _visibleEnd.isAfter(windowEnd)) _ensureLoaded();
    } on TimeoutException {
      _fail(id, 'The server took too long to respond.', quiet: quiet);
    } on _CalendarError catch (e) {
      _fail(id, e.message, quiet: quiet);
    } on FormatException {
      _fail(id, 'The server sent a reply the calendar could not read.', quiet: quiet);
    } catch (_) {
      _fail(id, "Couldn't reach the server. Check your connection and try again.", quiet: quiet);
    }
  }

  void _fail(int id, String message, {bool quiet = false}) {
    if (!mounted || id != _requestId) return;
    if (quiet) {
      // The background refresh failed: keep what is on screen, but say it may be out of date.
      setState(() => _stale = true);
      return;
    }
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
    // A tech saved from an earlier visit stays listed even with nothing in these months, so it can be unticked.
    final set = <String>{..._techs}..remove(_unassigned);
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
    // The app's red seed tints popup surfaces pink; the filter menus are plain white.
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll(Colors.white),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        side: const WidgetStatePropertyAll(BorderSide(color: _line)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? _ink : Colors.transparent),
      checkColor: const WidgetStatePropertyAll(Colors.white),
      side: const BorderSide(color: _slate, width: 1.5),
    ),
  );

  // The techs you pick stay picked: a page reload or reopening the app brings the same selection back. It is kept per
  // person on this device (the other filters are quick toggles and reset).
  String get _techsKey => 'calendar_techs_${AuthSession.instance.name}';

  Future<void> _restoreTechs() async {
    try {
      final saved = (await SharedPreferences.getInstance()).getStringList(_techsKey);
      if (saved == null || saved.isEmpty || !mounted) return;
      setState(() => _techs.addAll(saved));
    } catch (_) {
      // storage unavailable: start with every tech
    }
  }

  Future<void> _saveTechs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_techs.isEmpty) {
        await prefs.remove(_techsKey);
      } else {
        await prefs.setStringList(_techsKey, _techs.toList());
      }
    } catch (_) {}
  }

  bool get _filtersActive => _techs.isNotEmpty || _type != _TypeFilter.all || _statusFilter.isNotEmpty;

  void _clearFilters() => setState(() {
    _techs.clear();
    _saveTechs();
    _statusFilter.clear();
    _type = _TypeFilter.all;
  });

  // ---------------------------------------------------------------------------
  // Navigation
  // ---------------------------------------------------------------------------

  void _go(int dir) {
    setState(() {
      _focused = _view == _CalView.month
          ? DateTime(_focused.year, _focused.month + dir, 1)
          : _addDays(_focused, 7 * dir);
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
      // The picker paints its selected day, header and buttons in the theme's primary (the app's red): use black here.
      builder: (context, child) {
        final theme = Theme.of(context);
        return Theme(
          data: theme.copyWith(
            colorScheme: theme.colorScheme.copyWith(
              primary: _ink,
              onPrimary: Colors.white,
              // The red seed also tints the dialog's surface pink; plain white instead.
              surface: Colors.white,
              surfaceTint: Colors.transparent,
              surfaceContainerHigh: Colors.white,
              surfaceContainerHighest: _faint,
              onSurface: _ink,
              onSurfaceVariant: _slate,
              outline: _muted,
              outlineVariant: _line,
            ),
            datePickerTheme: const DatePickerThemeData(
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.transparent,
            ),
            textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: _ink)),
          ),
          child: child!,
        );
      },
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
      // An estimate opens under Estimates so that menu item stays lit, a job under Jobs.
      context.go(
        '/${e.isEstimate ? 'estimates' : 'jobs'}/${Uri.encodeComponent(jobId)}',
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
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: _muted,
                              letterSpacing: 1,
                            ),
                          ),
                          Text(
                            DateFormat('MMMM d, y').format(day),
                            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: _ink),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            events.isEmpty
                                ? 'Nothing scheduled'
                                : '${events.length} ${events.length == 1 ? 'event' : 'events'}',
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _slate),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(ctx).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
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
                        Icon(Icons.event_available_rounded, size: 40, color: _line),
                        SizedBox(height: 8),
                        Text(
                          'Nothing on the schedule',
                          style: TextStyle(color: _mutedText, fontWeight: FontWeight.w600),
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
        // One full-bleed screen, not a card floating on a grey page.
        backgroundColor: Colors.white,
        body: _panel(),
      ),
    );
  }

  /// Hands the keyboard back to the page after a click on a control, so the arrow keys and T keep working.
  void _refocus() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted && !_isTyping()) _focusNode.requestFocus();
  });

  Widget _panel() {
    return Container(
      color: Colors.white,
      child: Column(
        children: [
          Padding(padding: const EdgeInsets.fromLTRB(20, 12, 20, 10), child: _toolbar()),
          SizedBox(
            height: 2,
            child: _loading
                ? const LinearProgressIndicator(color: _slate, backgroundColor: Colors.transparent, minHeight: 2)
                : null,
          ),
          if (_loading && _slowLoad)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
              color: _faint,
              child: const Text(
                'Waking up the server, this can take up to a minute.',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _slate),
              ),
            ),
          if (_error != null) _errorBanner() else if (_stale) _staleBanner(),
          const Divider(height: 1, color: _line),
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) {
                // Phone-width: a day-by-day list reads better than seven squeezed columns.
                final agenda = c.maxWidth < 700;
                final body = agenda ? _agenda() : (_view == _CalView.month ? _monthGrid() : _weekGrid());
                return _withStatus(
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 160),
                    layoutBuilder: (current, previous) =>
                        Stack(fit: StackFit.expand, children: [...previous, ?current]),
                    child: KeyedSubtree(key: ValueKey('$_view|$agenda|${_ymd(_visibleStart)}'), child: body),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// A note over a grid with nothing in it, so a quiet period or a filter that hides everything never looks like a
  /// broken page.
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

  // ---------------------------------------------------------------------------
  // Toolbar: navigation, period, filters and view in one row
  // ---------------------------------------------------------------------------

  Widget _toolbar() {
    final nav = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _NavBtn(
          icon: Icons.chevron_left_rounded,
          tooltip: _view == _CalView.month ? 'Previous month (←)' : 'Previous week (←)',
          onTap: () {
            _go(-1);
            _refocus();
          },
        ),
        const SizedBox(width: 4),
        _NavBtn(
          icon: Icons.chevron_right_rounded,
          tooltip: _view == _CalView.month ? 'Next month (→)' : 'Next week (→)',
          onTap: () {
            _go(1);
            _refocus();
          },
        ),
        const SizedBox(width: 8),
        Tooltip(
          message: 'Jump to today (T)',
          child: OutlinedButton(
            onPressed: () {
              _goToday();
              _refocus();
            },
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
    );

    final title = InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: _pickDate,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                _periodTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: _ink),
              ),
            ),
            const SizedBox(width: 2),
            const Icon(Icons.expand_more_rounded, color: _muted),
          ],
        ),
      ),
    );

    final clear = TextButton.icon(
      onPressed: () {
        _clearFilters();
        _refocus();
      },
      icon: const Icon(Icons.filter_alt_off_outlined, size: 17),
      label: const Text('Clear filters'),
      style: TextButton.styleFrom(
        foregroundColor: _slate,
        minimumSize: const Size(0, 38),
        textStyle: _buttonText(context),
      ),
    );

    final filters = <Widget>[
      _techMenu(),
      _statusMenu(),
      _SegToggle<_TypeFilter>(
        options: const [(_TypeFilter.all, 'All'), (_TypeFilter.jobs, 'Jobs'), (_TypeFilter.estimates, 'Estimates')],
        value: _type,
        onChanged: (v) {
          setState(() => _type = v);
          _refocus();
        },
      ),
      _SegToggle<_CalView>(
        options: const [(_CalView.month, 'Month'), (_CalView.week, 'Week')],
        value: _view,
        onChanged: (v) {
          _setView(v);
          _refocus();
        },
      ),
      _IconPill(
        icon: Icons.refresh_rounded,
        tooltip: 'Refresh',
        onTap: () {
          _ensureLoaded(force: true);
          _refocus();
        },
      ),
    ];

    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth >= 1100) {
          // Everything on one line. "Clear filters" sits at the left of the right-aligned group, so showing or
          // hiding it never moves the controls the user is clicking.
          return Row(
            children: [
              nav,
              const SizedBox(width: 12),
              Flexible(
                child: Align(alignment: Alignment.centerLeft, child: title),
              ),
              const SizedBox(width: 12),
              if (_filtersActive) ...[clear, const SizedBox(width: 6)],
              for (var i = 0; i < filters.length; i++) ...[if (i > 0) const SizedBox(width: 8), filters[i]],
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                nav,
                const SizedBox(width: 8),
                Flexible(child: title),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [...filters, if (_filtersActive) clear],
            ),
          ],
        );
      },
    );
  }

  /// A filter button in the toolbar's style, used by the tech and status menus.
  Widget _filterButton({required IconData icon, required String label, required bool active, required bool open}) {
    return Container(
      width: 150, // fixed, so ticking names never resizes the button and shifts the menu under it
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: active ? _faint : Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: active ? _muted : _line),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: active ? _ink : _slate),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: active ? _ink : _slate),
            ),
          ),
          const SizedBox(width: 2),
          Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 18, color: _muted),
        ],
      ),
    );
  }

  Widget _techMenu() {
    return Theme(
      data: _blackChecks(context),
      child: MenuAnchor(
        onClose: _refocus,
        menuChildren: [
          MenuItemButton(
            onPressed: _techs.isEmpty
                ? null
                : () => setState(() {
                    _techs.clear();
                    _saveTechs();
                  }),
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
                _saveTechs();
              }),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  t == _unassigned
                      ? const Icon(Icons.person_off_outlined, size: 22, color: _slate)
                      : _Initials(name: t, size: 22, color: _slate),
                  const SizedBox(width: 8),
                  Text(t),
                ],
              ),
            ),
          ),
        ],
        builder: (context, controller, _) => Tooltip(
          message: 'Filter by tech (select several)',
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => controller.isOpen ? controller.close() : controller.open(),
            child: _filterButton(
              icon: Icons.person_outline_rounded,
              label: _techs.isEmpty ? 'All techs' : (_techs.length == 1 ? _techs.first : '${_techs.length} techs'),
              active: _techs.isNotEmpty,
              open: controller.isOpen,
            ),
          ),
        ),
      ),
    );
  }

  /// Status counts for the period on screen. Jobs and estimates keep separate lists, so "Scheduled" can appear in
  /// both.
  ({Map<String, int> counts, Map<String, String> labels}) _statusCounts() {
    final counts = <String, int>{};
    final labels = <String, String>{};
    for (var d = _visibleStart; d.isBefore(_visibleEnd); d = _addDays(d, 1)) {
      // The greyed days from the neighbouring months are not this month's, so they are not counted either.
      if (_view == _CalView.month && d.month != _focused.month) continue;
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
    return (counts: counts, labels: labels);
  }

  Widget _statusMenu() {
    final data = _statusCounts();
    final counts = data.counts, labels = data.labels;
    List<String> keysOf(String kind) =>
        counts.keys.where((k) => k.startsWith('$kind|')).toList()..sort((a, b) => counts[b]!.compareTo(counts[a]!));

    Widget heading(String text, {bool first = false}) => Padding(
      padding: EdgeInsets.fromLTRB(16, first ? 6 : 14, 16, 4),
      child: Text(
        text,
        style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w900, color: _mutedText, letterSpacing: 0.8),
      ),
    );

    final children = <Widget>[];
    if (counts.isEmpty) {
      children.add(
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('Nothing to filter in this period', style: TextStyle(fontSize: 13, color: _mutedText)),
        ),
      );
    } else {
      children.add(
        MenuItemButton(
          onPressed: _statusFilter.isEmpty ? null : () => setState(_statusFilter.clear),
          child: const Text('All statuses'),
        ),
      );
      var first = true;
      for (final g in [('JOB STATUS', 'job'), ('ESTIMATE STATUS', 'estimate')]) {
        final keys = keysOf(g.$2);
        if (keys.isEmpty) continue;
        children.add(heading(g.$1, first: first));
        first = false;
        for (final k in keys) {
          children.add(
            CheckboxMenuButton(
              closeOnActivate: false,
              value: _statusFilter.contains(k),
              onChanged: (_) => setState(() {
                if (!_statusFilter.remove(k)) _statusFilter.add(k);
              }),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 190),
                child: Row(
                  children: [
                    Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(color: getStatusColor(k.split('|').last), shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(labels[k]!)),
                    const SizedBox(width: 12),
                    Text(
                      '${counts[k]}',
                      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: _slate),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
      }
    }

    final label = _statusFilter.isEmpty
        ? 'All statuses'
        : (_statusFilter.length == 1 ? (labels[_statusFilter.first] ?? 'Status') : '${_statusFilter.length} statuses');
    return Theme(
      data: _blackChecks(context),
      child: MenuAnchor(
        onClose: _refocus,
        menuChildren: children,
        builder: (context, controller, _) => Tooltip(
          message: 'Filter by status (select several)',
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => controller.isOpen ? controller.close() : controller.open(),
            child: _filterButton(
              icon: Icons.filter_list_rounded,
              label: label,
              active: _statusFilter.isNotEmpty,
              open: controller.isOpen,
            ),
          ),
        ),
      ),
    );
  }

  Widget _errorBanner() {
    final red = _brand;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: red.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: red.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off_rounded, size: 18, color: red),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _loadedStart == null
                  ? "Couldn't load the calendar. ${_error ?? ''}"
                  : "Couldn't refresh the calendar. ${_error ?? ''} Showing the last loaded data.",
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _ink),
            ),
          ),
          TextButton(onPressed: () => _ensureLoaded(force: true), child: const Text('Retry')),
        ],
      ),
    );
  }

  /// The 5-minute background refresh failed. Nothing was lost, but the schedule on screen may be out of date.
  Widget _staleBanner() {
    final at = _loadedAt == null ? '' : ' from ${DateFormat('h:mm a').format(_loadedAt!)}';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(color: _faint, borderRadius: BorderRadius.circular(10)),
      child: Row(
        children: [
          const Icon(Icons.sync_problem_rounded, size: 18, color: _slate),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              "Couldn't refresh in the background. Showing the schedule$at.",
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _slate),
            ),
          ),
          TextButton(onPressed: () => _ensureLoaded(force: true), child: const Text('Retry')),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Agenda (narrow screens)
  // ---------------------------------------------------------------------------

  Widget _agenda() {
    final days = <DateTime>[];
    for (var d = _visibleStart; d.isBefore(_visibleEnd); d = _addDays(d, 1)) {
      if (_view == _CalView.month && d.month != _focused.month) continue;
      if (_eventsFor(d).isNotEmpty) days.add(d);
    }
    if (days.isEmpty) return const SizedBox.expand(); // _withStatus puts the "nothing scheduled" note over it
    return _VScroll(
      builder: (controller) => ListView.builder(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
        itemCount: days.length,
        itemBuilder: (_, i) {
          final day = days[i];
          final events = _eventsFor(day);
          final isToday = _sameDay(day, DateTime.now());
          return Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(
                  header: true,
                  child: Row(
                    children: [
                      _DayNumber(day: day.day, isToday: isToday, size: 32, fontSize: 15),
                      const SizedBox(width: 10),
                      Text(
                        DateFormat('EEEE, MMM d').format(day),
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: _ink),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${events.length} ${events.length == 1 ? 'event' : 'events'}',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _mutedText),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                for (final e in events)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _EventCard(event: e, onTap: () => _openEvent(e)),
                  ),
              ],
            ),
          );
        },
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
        // Chip and day-number heights follow the text size, so a larger system font is not clipped.
        final f = MediaQuery.textScalerOf(context).scale(14) / 14;
        final grow = f.clamp(1.0, 1.8);
        final chipH = (twoLine ? 36.0 : 22.0) * grow;
        final dayH = _dayHeaderH * grow;
        final fill = math.max(_minRowH, ((c.maxHeight - headerH) / weeks).floorToDouble());

        double rowHeight(int w) {
          var most = 0;
          for (var d = 0; d < 7; d++) {
            most = math.max(most, _eventsFor(_addDays(start, w * 7 + d)).length);
          }
          // top and bottom padding (4 + 3), the day number, then a chip and its gap per event
          return math.max(fill, 4 + 3 + dayH + most * (chipH + _chipGap) + 2);
        }

        return Column(
          children: [
            Container(
              height: headerH,
              decoration: const BoxDecoration(
                color: _faintLight,
                border: Border(bottom: BorderSide(color: _line)),
              ),
              child: Row(
                children: [
                  for (final d in days)
                    Expanded(
                      child: Center(
                        child: Text(
                          d,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            color: _slate,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              // The scrollbar stays visible whenever a busy month runs past the window, so it is clear there is more.
              child: _VScroll(
                builder: (controller) => SingleChildScrollView(
                  controller: controller,
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
                                  child: _monthCell(
                                    _addDays(start, w * 7 + d),
                                    d == 6,
                                    twoLine: twoLine,
                                    chipH: chipH,
                                    dayH: dayH,
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _monthCell(DateTime day, bool lastCol, {required bool twoLine, required double chipH, required double dayH}) {
    final inMonth = day.month == _focused.month;
    final isToday = _sameDay(day, DateTime.now());
    final events = _eventsFor(day);
    // First load, nothing to show yet: faint placeholder bars (a different number per day) instead of an empty grid.
    final skeleton = _loading && _loadedStart == null;

    final bg = isToday ? _todayBg : (!inMonth ? _faintLight : Colors.white);

    return Semantics(
      button: events.isNotEmpty,
      label:
          '${DateFormat('EEEE, MMMM d').format(day)}${isToday ? ', today' : ''}, '
          '${events.isEmpty ? 'nothing scheduled' : '${events.length} ${events.length == 1 ? 'event' : 'events'}'}',
      child: Material(
        color: bg,
        child: InkWell(
          onTap: events.isEmpty ? null : () => _openDay(day), // an empty day has nothing to show
          hoverColor: events.isEmpty ? Colors.transparent : _faint.withValues(alpha: 0.7),
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
                  height: dayH,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _DayNumber(
                      day: day.day,
                      label: day.day == 1 ? '${DateFormat('MMM').format(day)} 1' : null,
                      isToday: isToday,
                      muted: !inMonth,
                      size: dayH - 2,
                      fontSize: 14.5,
                    ),
                  ),
                ),
                if (skeleton)
                  SkeletonPulse(
                    child: Column(
                      children: [
                        for (var i = 0; i < (day.day * 7 % 3); i++)
                          Container(
                            height: 14,
                            margin: const EdgeInsets.only(bottom: 4),
                            decoration: BoxDecoration(color: _faint, borderRadius: BorderRadius.circular(6)),
                          ),
                      ],
                    ),
                  ),
                if (!skeleton)
                  for (final e in events)
                    Padding(
                      padding: const EdgeInsets.only(bottom: _chipGap),
                      child: SizedBox(
                        height: chipH,
                        child: _EventChip(
                          event: e,
                          twoLine: twoLine,
                          dimmed: !inMonth,
                          ambiguous: _ambiguous,
                          onTap: () => _openEvent(e),
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
        color: isToday ? _todayBg : (day.weekday >= 6 ? _faintLight : Colors.white),
        border: Border(right: last ? BorderSide.none : const BorderSide(color: _line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: events.isNotEmpty,
            label:
                '${DateFormat('EEEE, MMMM d').format(day)}${isToday ? ', today' : ''}, '
                '${events.isEmpty ? 'nothing scheduled' : '${events.length} ${events.length == 1 ? 'event' : 'events'}'}',
            excludeSemantics: true,
            child: InkWell(
              onTap: events.isEmpty ? null : () => _openDay(day),
              child: Container(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: _line)),
                ),
                child: Row(
                  children: [
                    _DayNumber(day: day.day, isToday: isToday, size: 34, fontSize: 16, rounded: true),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            DateFormat('EEE').format(day).toUpperCase(),
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: _slate,
                              letterSpacing: 1,
                            ),
                          ),
                          Text(
                            events.isEmpty
                                ? 'No events'
                                : '${events.length} ${events.length == 1 ? 'event' : 'events'}',
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _mutedText),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // An empty day says "No events" once, in its header; the column below is simply left quiet.
          Expanded(
            child: events.isEmpty
                ? const SizedBox.expand()
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
  final Set<String> ambiguous; // first names shared by two techs, which get a last initial
  final VoidCallback onTap;
  const _EventChip({
    required this.event,
    required this.twoLine,
    required this.onTap,
    this.dimmed = false,
    this.ambiguous = const {},
  });

  @override
  Widget build(BuildContext context) {
    final st = _styleFor(event.color);
    final techs = event.techs.isEmpty ? 'No tech' : event.shortTechs(ambiguous);

    return Opacity(
      opacity: dimmed ? 0.5 : 1,
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
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: st.fg),
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
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: st.fg.withValues(alpha: 0.7),
                  height: 1.2,
                ),
              ),
            ],
          )
        : Row(
            children: [
              if (time != null) ...[
                Text(
                  time,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: st.fg.withValues(alpha: 0.7)),
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

/// Larger card used in the week view, the day dialog and the narrow-screen agenda. When first, then who, then the
/// status as a small dot and plain words (a solid, shouted pill cut off in narrow columns).
class _EventCard extends StatelessWidget {
  final _CalEvent event;
  final VoidCallback onTap;
  const _EventCard({required this.event, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final st = _styleFor(event.color);

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
                      // When the visit is; all-day jobs say so, so every card answers "when" the same way.
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              event.timeLabel ?? 'All day',
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w800,
                                color: st.fg.withValues(alpha: 0.75),
                              ),
                            ),
                          ),
                          if (event.isEstimate) ...[const SizedBox(width: 6), _EstBadge(color: st.fg)],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        event.customer,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: st.fg, height: 1.2),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(color: event.color, shape: BoxShape.circle),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              event.statusLabel,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: st.fg.withValues(alpha: 0.85),
                                height: 1.2,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      if (event.techs.isEmpty)
                        Text(
                          'No tech assigned',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            fontStyle: FontStyle.italic,
                            color: st.fg.withValues(alpha: 0.6),
                          ),
                        )
                      else
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _InitialsStack(names: event.techList, color: st.fg),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                event.techs,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: st.fg.withValues(alpha: 0.85),
                                  height: 1.35,
                                ),
                              ),
                            ),
                          ],
                        ),
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

/// A tech's initials in a small circle ("BH"), so who is on a job can be spotted at a glance.
class _Initials extends StatelessWidget {
  final String name;
  final double size;
  final Color color;
  const _Initials({required this.name, required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    final text = parts.isEmpty
        ? '?'
        : (parts.length == 1 ? parts.first[0] : parts.first[0] + parts.last[0]).toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 1.5),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: math.max(10, size * 0.45), fontWeight: FontWeight.w800, color: color, height: 1),
      ),
    );
  }
}

/// Overlapping initials for up to three techs, with "+N" for the rest.
class _InitialsStack extends StatelessWidget {
  final List<String> names;
  final Color color;
  const _InitialsStack({required this.names, required this.color});

  @override
  Widget build(BuildContext context) {
    const size = 24.0, step = 17.0;
    final shown = names.take(3).toList();
    final extra = names.length - shown.length;
    final count = shown.length + (extra > 0 ? 1 : 0);
    return ExcludeSemantics(
      child: SizedBox(
        width: size + step * (count - 1),
        height: size,
        child: Stack(
          children: [
            for (var i = 0; i < shown.length; i++)
              Positioned(
                left: i * step,
                child: _Initials(name: shown[i], size: size, color: color),
              ),
            if (extra > 0)
              Positioned(
                left: shown.length * step,
                child: Container(
                  width: size,
                  height: size,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                  child: Text(
                    '+$extra',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: color, height: 1),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The day number. Today is the one filled dark circle (or rounded square in the week view), the standard cue, so it
/// is found at a glance without relying on a faint tint.
class _DayNumber extends StatelessWidget {
  final int day;
  final String? label; // "Oct 1" on the first of a month
  final bool isToday;
  final bool muted; // a day from the neighbouring month
  final double size;
  final double fontSize;
  final bool rounded;
  const _DayNumber({
    required this.day,
    required this.isToday,
    required this.size,
    required this.fontSize,
    this.label,
    this.muted = false,
    this.rounded = false,
  });

  @override
  Widget build(BuildContext context) {
    final fg = isToday ? Colors.white : (muted ? _muted : _ink);
    return Container(
      constraints: BoxConstraints(minWidth: size),
      height: size,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: isToday ? _ink : (rounded ? _faint : null),
        borderRadius: BorderRadius.circular(rounded ? 10 : size / 2),
      ),
      child: Center(
        widthFactor: 1,
        child: FittedBox(
          fit: BoxFit.scaleDown, // "Oct 1" must shrink, not overflow, in phone-width cells
          child: Text(
            label ?? '$day',
            maxLines: 1,
            style: TextStyle(fontSize: fontSize, fontWeight: isToday ? FontWeight.w800 : FontWeight.w700, color: fg),
          ),
        ),
      ),
    );
  }
}

/// A vertical scroll area with an always-visible scrollbar. It owns its controller, so two of them can exist at once
/// while the grid cross-fades between months.
class _VScroll extends StatefulWidget {
  final Widget Function(ScrollController controller) builder;
  const _VScroll({required this.builder});

  @override
  State<_VScroll> createState() => _VScrollState();
}

class _VScrollState extends State<_VScroll> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(controller: _controller, thumbVisibility: true, child: widget.builder(_controller));
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
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: color, letterSpacing: 0.4, height: 1.2),
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

  static const _known = {'event_date', 'status', 'is_estimate', 'customer_name', 'techs', 'job_number'};

  /// Fields that are shown properly elsewhere in the dialog (the time) or are only ids and timestamps.
  static final _internal = RegExp(
    r'(^|_)(id|ids|uuid)$|^time_(start|end)$|(^|_)(created|updated|synced)(_at)?$|^raw',
    caseSensitive: false,
  );

  static String _prettyKey(String k) => _titleCase(k.replaceAll(RegExp(r'[_\-]+'), ' ').trim());

  @override
  Widget build(BuildContext context) {
    final c = event.color;

    final extras = <MapEntry<String, String>>[];
    event.raw.forEach((k, v) {
      if (_known.contains(k) || v == null || v is Map || v is List) return;
      if (_internal.hasMatch(k)) return; // ids, raw time columns and bookkeeping are not for people
      final s = v.toString().trim();
      if (s.isEmpty) return;
      extras.add(MapEntry(_prettyKey(k), s));
    });

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A thin strip in the status colour, then a plain header: a full block of lime or pink was garish.
        Container(height: 6, color: c),
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(
                      color: c.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(color: c, shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          event.statusLabel,
                          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: _ink),
                        ),
                      ],
                    ),
                  ),
                  if (event.isEstimate) ...[const SizedBox(width: 8), const _EstBadge(color: _slate)],
                ],
              ),
              const SizedBox(height: 12),
              Text(
                event.customer,
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: _ink, height: 1.15),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: _line),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _DetailRow(
                  icon: Icons.event_rounded,
                  label: 'Date',
                  value: DateFormat('EEEE, MMMM d, y').format(event.day),
                ),
                _DetailRow(icon: Icons.schedule_rounded, label: 'Time', value: event.timeLabel ?? 'All day'),
                _DetailRow(
                  icon: Icons.assignment_outlined,
                  label: 'Type',
                  value: event.isEstimate ? 'Estimate' : 'Job',
                ),
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
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: _mutedText,
                    letterSpacing: 0.7,
                  ),
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
                  padding: const EdgeInsets.symmetric(horizontal: 10),
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
