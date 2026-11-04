part of 'assistant_panel.dart';

// =============================================================================
// Jarvis workspace (2026-10-27): the welcome screen with the daily briefing and the questions Jarvis can answer, links
// to the records an answer names, the live checklist of lookups, and the answer blocks for priorities, comparisons and
// the dates-and-definitions note.
// =============================================================================

/// The daily briefing's question. The welcome screen asks it, and spots an earlier answer to it from today.
const String _briefingQuestion = "Give me today's priorities and tell me why each one matters.";

/// Questions grouped by what they are about, so the welcome screen shows what Jarvis can look up. Each one maps to a
/// lookup the server has (see the tool guide in the backend prompt). After each group's first three come the questions
/// the dashboards already offer on that subject (see [_pageSuggestions]), word for word, so no group asks anything new.
class _Area {
  final String name;
  final IconData icon;
  final List<_Suggestion> questions;
  const _Area(this.name, this.icon, this.questions);
}

const List<_Area> _areas = [
  _Area('Money', Icons.payments_outlined, [
    _Suggestion(
      Icons.account_balance_wallet_outlined,
      'Who owes us',
      'Which customers owe us the most money, especially overdue balances?',
    ),
    _Suggestion(Icons.request_quote_outlined, 'Unpaid jobs', 'Which jobs from the last 30 days are not paid in full?'),
    _Suggestion(Icons.show_chart_rounded, 'Monthly trend', 'Show completed revenue and profit by month this year.'),
    _Suggestion(Icons.warning_amber_rounded, 'Over 90 days', 'Which customers have balances over 90 days, and how much?'),
    _Suggestion(Icons.trending_up_rounded, 'Balance trend', 'How has our outstanding balance changed over the last 30 days?'),
    _Suggestion(
      Icons.pie_chart_outline_rounded,
      'Revenue mix',
      'What is our revenue mix between residential and commercial this year?',
    ),
  ]),
  _Area('Jobs', Icons.handyman_outlined, [
    _Suggestion(Icons.hourglass_bottom_rounded, 'Stuck jobs', 'Which jobs are stuck, and what is holding them up?'),
    _Suggestion(Icons.event_available_outlined, 'This week', 'What is scheduled for the technicians this week?'),
    _Suggestion(Icons.update_rounded, 'Since yesterday', 'What changed in our business since yesterday?'),
    _Suggestion(Icons.list_alt_rounded, 'Open by status', 'How many open jobs are in each status right now?'),
    _Suggestion(Icons.undo_rounded, 'Callbacks', 'How many callbacks have we had this month and who were they on?'),
  ]),
  _Area('Sales', Icons.handshake_outlined, [
    _Suggestion(Icons.mark_email_unread_outlined, 'Follow-ups', 'Which estimates need follow-up first?'),
    _Suggestion(
      Icons.compare_arrows_rounded,
      'Month vs last',
      'Compare this month with last month and explain the major differences.',
    ),
    _Suggestion(Icons.filter_alt_outlined, 'Pipeline', 'What is our open estimate pipeline and win rate this year?'),
    _Suggestion(Icons.handshake_outlined, 'Win rate', 'What is our estimate win rate by month this year?'),
    _Suggestion(Icons.leaderboard_outlined, 'By salesperson', 'How are the salespeople doing on estimates this year?'),
    _Suggestion(Icons.door_front_door_outlined, 'Door types', 'Which door styles do we win the most revenue on this year?'),
  ]),
  _Area('Team', Icons.engineering_outlined, [
    _Suggestion(
      Icons.trending_up_rounded,
      'Tech trends',
      'How are our technicians performing, and what trends should I know about?',
    ),
    _Suggestion(Icons.star_outline_rounded, 'Reviews', 'How are our Google reviews doing, and which techs are mentioned most?'),
    _Suggestion(Icons.receipt_long_outlined, 'This week’s pay', 'What does payroll look like for this week?'),
    _Suggestion(Icons.savings_outlined, 'Pool balance', 'What is in the retainage and company pool right now?'),
  ]),
  _Area('Stock', Icons.inventory_2_outlined, [
    _Suggestion(Icons.report_gmailerrorred_outlined, 'Upcoming shortages', 'What inventory issues could affect upcoming jobs?'),
    _Suggestion(Icons.inventory_outlined, 'Low stock', 'Which inventory items are low on stock?'),
    _Suggestion(
      Icons.door_front_door_outlined,
      'Doors on upcoming jobs',
      'How many Clopay doors are on upcoming jobs, by model?',
    ),
    _Suggestion(Icons.fact_check_outlined, 'Cycle counts', 'Where are we on this month’s cycle counts?'),
  ]),
];

/// Questions for the page the panel was opened from (the general ones are under "Explore").
List<_Suggestion> _pageSuggestions(String path) {
  const pages = <String, List<_Suggestion>>{
    '/dashboards/collections': [
      _Suggestion(Icons.warning_amber_rounded, 'Over 90 days', 'Which customers have balances over 90 days, and how much?'),
      _Suggestion(Icons.trending_up_rounded, 'Balance trend', 'How has our outstanding balance changed over the last 30 days?'),
    ],
    '/dashboards/financial': [
      _Suggestion(
        Icons.compare_arrows_rounded,
        'Month vs last',
        'Compare this month with last month and explain the major differences.',
      ),
      _Suggestion(
        Icons.pie_chart_outline_rounded,
        'Revenue mix',
        'What is our revenue mix between residential and commercial this year?',
      ),
    ],
    '/dashboards/jobs': [
      _Suggestion(Icons.hourglass_bottom_rounded, 'Stuck jobs', 'Which jobs are stuck, and what is holding them up?'),
      _Suggestion(Icons.list_alt_rounded, 'Open by status', 'How many open jobs are in each status right now?'),
    ],
    '/dashboards/estimates': [
      _Suggestion(Icons.mark_email_unread_outlined, 'Follow-ups', 'Which estimates need follow-up first?'),
      _Suggestion(Icons.handshake_outlined, 'Win rate', 'What is our estimate win rate by month this year?'),
    ],
    '/dashboards/sales': [
      _Suggestion(Icons.leaderboard_outlined, 'By salesperson', 'How are the salespeople doing on estimates this year?'),
      _Suggestion(Icons.door_front_door_outlined, 'Door types', 'Which door styles do we win the most revenue on this year?'),
    ],
    '/dashboards/technicians': [
      _Suggestion(
        Icons.trending_up_rounded,
        'Tech trends',
        'How are our technicians performing, and what trends should I know about?',
      ),
      _Suggestion(Icons.undo_rounded, 'Callbacks', 'How many callbacks have we had this month and who were they on?'),
    ],
    '/dashboards/commissions': [
      _Suggestion(Icons.payments_outlined, 'This week’s pay', 'What does payroll look like for this week?'),
      _Suggestion(Icons.savings_outlined, 'Pool balance', 'What is in the retainage and company pool right now?'),
    ],
    '/dashboards/inventory': [
      _Suggestion(Icons.report_gmailerrorred_outlined, 'Upcoming shortages', 'What inventory issues could affect upcoming jobs?'),
      _Suggestion(Icons.fact_check_outlined, 'Cycle counts', 'Where are we on this month’s cycle counts?'),
    ],
    '/inventory': [
      _Suggestion(Icons.report_gmailerrorred_outlined, 'Upcoming shortages', 'What inventory issues could affect upcoming jobs?'),
      _Suggestion(Icons.inventory_outlined, 'Low stock', 'Which inventory items are low on stock?'),
    ],
    '/customers': [
      _Suggestion(Icons.person_search_outlined, 'Lapsed customers', 'Which good customers have not had a job in the last year?'),
      _Suggestion(Icons.groups_outlined, 'Top customers', 'Who are our top 10 customers by revenue this year?'),
    ],
    '/estimates': [_Suggestion(Icons.mark_email_unread_outlined, 'Follow-ups', 'Which estimates need follow-up first?')],
    '/jobs': [_Suggestion(Icons.hourglass_bottom_rounded, 'Stuck jobs', 'Which jobs are stuck, and what is holding them up?')],
    '/calendar': [_Suggestion(Icons.event_available_outlined, 'This week', 'What is scheduled for the technicians this week?')],
    '/hr/kpis': [
      _Suggestion(
        Icons.trending_up_rounded,
        'Tech trends',
        'How are our technicians performing, and what trends should I know about?',
      ),
      _Suggestion(Icons.star_outline_rounded, 'Reviews', 'How are our Google reviews doing, and which techs are mentioned most?'),
    ],
  };
  final seg = path.split('/').where((s) => s.isNotEmpty).toList();
  if (seg.length >= 2 && seg[0] == 'jobs') {
    return const [
      _Suggestion(
        Icons.summarize_outlined,
        'Summarize this job',
        'Summarize this job: status, what is owed, payments, and any notes or tasks.',
      ),
      _Suggestion(Icons.history_rounded, 'Status history', 'Show the status history of this job.'),
    ];
  }
  if (seg.length >= 2 && seg[0] == 'estimates') {
    return const [
      _Suggestion(
        Icons.summarize_outlined,
        'Summarize this estimate',
        'Summarize this estimate: value, owner, status and how long it has been open.',
      ),
    ];
  }
  if (seg.length >= 2 && seg[0] == 'customers') {
    return const [
      _Suggestion(
        Icons.summarize_outlined,
        'Summarize this customer',
        'Summarize this customer: what they owe, their open estimates and their recent jobs.',
      ),
    ];
  }
  return pages[path] ?? const [];
}

/// The heading over the page's own questions: "For this job" on a job's page, "For the Collections dashboard" on a screen.
String _pageHeading(String pageName) {
  final detail = RegExp(r'^(Job|Estimate|Customer) \S+ detail page$').firstMatch(pageName);
  if (detail != null) return 'For this ${detail.group(1)!.toLowerCase()}';
  if (pageName.isEmpty || pageName.endsWith(' page')) return 'For this page';
  return 'For the $pageName';
}

/// "2:41 PM" today, "Yesterday 2:41 PM", else "Oct 24, 2:41 PM": when an answer's figures were looked up.
String _answerTime(DateTime at, DateTime now) {
  final h = at.hour % 12 == 0 ? 12 : at.hour % 12;
  final clock = '$h:${at.minute.toString().padLeft(2, '0')} ${at.hour < 12 ? 'AM' : 'PM'}';
  final day = DateTime(at.year, at.month, at.day);
  final today = DateTime(now.year, now.month, now.day);
  if (day == today) return clock;
  if (today.difference(day).inDays == 1) return 'Yesterday $clock';
  return '${_monthNames[at.month - 1]} ${at.day}, $clock';
}

String _seconds(int ms) => ms < 100 ? '<0.1 s' : '${(ms / 1000).toStringAsFixed(1)} s';

// --- Links to records ----------------------------------------------------------------------------------------------

/// App pages an answer may link to as [name](page:key). Anything else stays plain text.
const Map<String, (String, String)> _appPages = {
  'collections': ('/dashboards/collections', 'the Collections dashboard'),
  'financial': ('/dashboards/financial', 'the Financial dashboard'),
  'jobs-dashboard': ('/dashboards/jobs', 'the Jobs dashboard'),
  'estimates-dashboard': ('/dashboards/estimates', 'the Estimates dashboard'),
  'sales': ('/dashboards/sales', 'the Sales dashboard'),
  'technicians': ('/dashboards/technicians', 'the Technicians dashboard'),
  'commissions': ('/dashboards/commissions', 'the Commissions dashboard'),
  'inventory-dashboard': ('/dashboards/inventory', 'the Inventory dashboard'),
  'jobs': ('/jobs', 'Jobs'),
  'estimates': ('/estimates', 'Estimates'),
  'customers': ('/customers', 'Customers'),
  'inventory': ('/inventory', 'Inventory'),
  'payroll': ('/hr/payroll', 'Payroll'),
  'calendar': ('/calendar', 'the Calendar'),
  'invoices': ('/invoices', 'Invoices'),
  'payments': ('/payments', 'Payments'),
};

final RegExp _recordIdRe = RegExp(r'^[A-Za-z0-9\-]{3,40}$');

/// Where a record link in an answer goes, and how to say it ("Open job 1095809012"); null if it is not one the app
/// knows, which then shows as plain text. Jobs and estimates by number, customers by their page id (digits) or by name
/// (opens Customers searched for it), and the pages above.
({String route, String what})? _recordLink(String url) {
  final colon = url.indexOf(':');
  if (colon <= 0) return null;
  final kind = url.substring(0, colon);
  final target = url.substring(colon + 1).trim();
  switch (kind) {
    case 'job':
      return _recordIdRe.hasMatch(target) ? (route: '/jobs/${Uri.encodeComponent(target)}', what: 'Open job $target') : null;
    case 'estimate':
      return _recordIdRe.hasMatch(target)
          ? (route: '/estimates/${Uri.encodeComponent(target)}', what: 'Open estimate $target')
          : null;
    case 'customer':
      if (RegExp(r'^\d{1,20}$').hasMatch(target)) return (route: '/customers/$target', what: 'Open this customer');
      if (target.length < 2 || target.length > 100 || RegExp(r'[\u0000-\u001f<>]').hasMatch(target)) return null;
      return (route: Uri(path: '/customers', queryParameters: {'q': target}).toString(), what: 'Find $target in Customers');
    case 'page':
      final p = _appPages[target.toLowerCase()];
      return p == null ? null : (route: p.$1, what: 'Open ${p.$2}');
  }
  return null;
}

/// A record named in an answer. Closes the panel and opens it; reachable by Tab and opened with Enter, like any link.
class _RecordLink extends StatefulWidget {
  final String route;
  final String what;
  final String label;
  final TextStyle style;
  const _RecordLink({required this.route, required this.what, required this.label, required this.style});

  @override
  State<_RecordLink> createState() => _RecordLinkState();
}

class _RecordLinkState extends State<_RecordLink> {
  bool _hover = false;
  bool _focus = false;

  void _open() {
    GoRouter? router;
    try {
      router = GoRouter.of(context);
    } catch (_) {}
    Navigator.of(context).pop(); // the panel sits on top of the page, so close it first
    router?.go(widget.route);
  }

  @override
  Widget build(BuildContext context) {
    final lit = _hover || _focus;
    return Tooltip(
      message: widget.what,
      waitDuration: const Duration(milliseconds: 600),
      child: Semantics(
        link: true,
        label: '${widget.label}. ${widget.what}',
        excludeSemantics: true,
        child: FocusableActionDetector(
          mouseCursor: SystemMouseCursors.click,
          onShowHoverHighlight: (v) => setState(() => _hover = v),
          onShowFocusHighlight: (v) => setState(() => _focus = v),
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                _open();
                return null;
              },
            ),
          },
          child: GestureDetector(
            onTap: _open,
            child: DecoratedBox(
              decoration: BoxDecoration(color: _focus ? _tint : null, borderRadius: BorderRadius.circular(3)),
              child: Text(
                widget.label,
                style: widget.style.copyWith(
                  color: _brandRed,
                  fontWeight: FontWeight.w600,
                  decoration: lit ? TextDecoration.underline : TextDecoration.none,
                  decorationColor: _brandRed,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// --- The welcome screen ----------------------------------------------------------------------------------------------

class _JarvisHome extends StatefulWidget {
  final String greeting;
  final bool canAsk;
  final String pagePath;
  final String pageName; // "Collections dashboard", or '' when the panel was not opened from a known page
  final ValueChanged<String> onAsk;
  const _JarvisHome({
    required this.greeting,
    required this.canAsk,
    required this.pagePath,
    required this.pageName,
    required this.onAsk,
  });

  @override
  State<_JarvisHome> createState() => _JarvisHomeState();
}

class _JarvisHomeState extends State<_JarvisHome> {
  static int _area = 0; // the "Explore" group last looked at, remembered while the app is open

  @override
  Widget build(BuildContext context) {
    final here = widget.canAsk ? _pageSuggestions(widget.pagePath) : const <_Suggestion>[];
    final area = _areas[_area.clamp(0, _areas.length - 1)];
    // a question already offered for this page is not repeated in its group
    final asked = {for (final s in here) s.question};
    final questions = [for (final s in area.questions) if (!asked.contains(s.question)) s];
    // Layout decisions use the width in "unscaled" pixels, so large text gets fewer columns instead of clipped cards.
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return LayoutBuilder(
      builder: (context, view) {
        // the same side padding and width as the message box under it, so their edges line up
        const side = 20.0;
        final room = (view.maxWidth - side * 2).clamp(0.0, _homeWidth) / scale;
        final tabs = _AreaTabs(selected: _area, onSelect: (i) => setState(() => _area = i));
        const explore = Text(
          'Explore what Jarvis can look up',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: _navy),
        );
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(side, view.maxHeight < 640 ? 20 : 36, side, 24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _homeWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _HomeHeader(greeting: widget.greeting, canAsk: widget.canAsk),
                  if (widget.canAsk) ...[
                    if (here.isNotEmpty) ...[
                      const SizedBox(height: 24),
                      _Arrive(
                        begin: 0.34,
                        end: 0.76,
                        child: _PageQuestions(
                          heading: _pageHeading(widget.pageName),
                          questions: here,
                          onAsk: widget.onAsk,
                        ),
                      ),
                    ],
                    const SizedBox(height: 28),
                    // the heading and the group switcher share a row when there is room for both
                    _Arrive(
                      begin: 0.38,
                      end: 0.8,
                      child: room >= 600
                          ? Row(
                              children: [
                                Expanded(child: Semantics(header: true, child: explore)),
                                tabs,
                              ],
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Semantics(header: true, child: explore),
                                const SizedBox(height: 10),
                                tabs,
                              ],
                            ),
                    ),
                    const SizedBox(height: 14),
                    _Arrive(
                      begin: 0.42,
                      end: 0.9,
                      rise: 16,
                      child: _QuestionGrid(
                        questions: questions,
                        columns: room >= 600 ? 3 : (room >= 380 ? 2 : 1),
                        onAsk: widget.onAsk,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// How wide the welcome screen (and the message box under it) grows.
const double _homeWidth = 880;

/// Jarvis's mark: a four-point star (navy, or white on the nav bar's navy button) with a smaller red one over its right
/// arm. [twinkle] runs 0 to 1 to turn the red star a quarter turn, swelling a little halfway, for the button's hover.
class JarvisMark extends StatelessWidget {
  final double size;
  final Color color;
  final double twinkle;
  const JarvisMark({super.key, required this.size, this.color = _navy, this.twinkle = 0});

  @override
  Widget build(BuildContext context) =>
      ExcludeSemantics(child: CustomPaint(size: Size.square(size), painter: _JarvisMarkPainter(color, twinkle)));
}

class _JarvisMarkPainter extends CustomPainter {
  final Color color;
  final double twinkle;
  const _JarvisMarkPainter(this.color, this.twinkle);

  static Path _star(Offset c, double r) {
    final k = r * 0.24; // how far the waist sits from the centre: smaller for longer, sharper points
    return Path()
      ..moveTo(c.dx, c.dy - r)
      ..lineTo(c.dx + k, c.dy - k)
      ..lineTo(c.dx + r, c.dy)
      ..lineTo(c.dx + k, c.dy + k)
      ..lineTo(c.dx, c.dy + r)
      ..lineTo(c.dx - k, c.dy + k)
      ..lineTo(c.dx - r, c.dy)
      ..lineTo(c.dx - k, c.dy - k)
      ..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    canvas.drawPath(_star(Offset(s * 0.42, s * 0.54), s * 0.42), Paint()..color = color);
    // a quarter turn brings a four-point star back to where it started, so hovering in and out never leaves it askew
    canvas
      ..save()
      ..translate(s * 0.66, s * 0.44)
      ..rotate(twinkle * math.pi / 2)
      ..drawPath(_star(Offset.zero, s * 0.3 * (1 + 0.2 * math.sin(math.pi * twinkle))), Paint()..color = _brandRed)
      ..restore();
  }

  @override
  bool shouldRepaint(_JarvisMarkPainter old) => old.color != color || old.twinkle != twinkle;
}

/// Fades [child] in over the [begin]..[end] stretch of the panel's opening (see [_JarvisRoute]), rising [rise] pixels,
/// or, with [pop], swelling up from half size while turning a quarter turn; so the contents settle in once the panel
/// has grown out of the Ask Jarvis button, and leave first on close. Outside that route it is just [child].
class _Arrive extends StatelessWidget {
  final double begin;
  final double end;
  final double rise;
  final bool pop;
  final Widget child;
  const _Arrive({required this.begin, required this.end, this.rise = 10, this.pop = false, required this.child});

  @override
  Widget build(BuildContext context) {
    final route = ModalRoute.of(context);
    if (route is! _JarvisRoute) return child;
    final anim = route.animation!;
    final curve = Interval(begin, end, curve: pop ? Curves.easeOutBack : Curves.easeOutCubic);
    // The same widgets at every value, even at rest, so nothing below loses its state when the motion ends.
    return AnimatedBuilder(
      animation: anim,
      child: child,
      builder: (context, child) {
        final v = curve.transform(anim.value);
        return Opacity(
          opacity: v.clamp(0.0, 1.0),
          child: Transform(
            alignment: Alignment.center,
            transform: pop
                ? (Matrix4.identity()
                  ..rotateZ(-(1 - v) * math.pi / 2)
                  ..scaleByDouble(0.5 + 0.5 * v, 0.5 + 0.5 * v, 1, 1))
                : Matrix4.translationValues(0, rise * (1 - v), 0),
            child: child,
          ),
        );
      },
    );
  }
}

/// The mark, the greeting, and one line on what Jarvis does.
class _HomeHeader extends StatelessWidget {
  final String greeting;
  final bool canAsk;
  const _HomeHeader({required this.greeting, required this.canAsk});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Arrive(
          begin: 0.24,
          end: 0.86,
          pop: true,
          child: Container(
            width: 44,
            height: 44,
            decoration: const BoxDecoration(color: _fill, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: const JarvisMark(size: 24),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: _Arrive(
            begin: 0.28,
            end: 0.7,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    greeting,
                    style: _serifStyle.copyWith(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                      height: 1.2,
                      color: _navy,
                    ),
                  ),
                ),
                if (!canAsk) ...[
                  const SizedBox(height: 3),
                  const Text(
                    'Jarvis is only for admin and owner accounts, because it can read pay, profit and every customer. Ask an admin if you need something looked up.',
                    style: TextStyle(fontSize: 14, color: _slate, height: 1.45),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The questions for the page the panel was opened from, as a row of small buttons under the greeting. Each button shows
/// the question's short name; the full wording is its tooltip and what a screen reader says.
class _PageQuestions extends StatelessWidget {
  final String heading;
  final List<_Suggestion> questions;
  final ValueChanged<String> onAsk;
  const _PageQuestions({required this.heading, required this.questions, required this.onAsk});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 6),
          child: Semantics(
            header: true,
            child: Text(
              heading,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _slate),
            ),
          ),
        ),
        for (final s in questions)
          Tooltip(
            message: s.question,
            waitDuration: const Duration(milliseconds: 400),
            child: Semantics(
              button: true,
              label: 'Ask: ${s.question}',
              excludeSemantics: true,
              child: Material(
                color: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: _stroke)),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => onAsk(s.question),
                  hoverColor: _fill,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(9, 6, 11, 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(s.icon, size: 14, color: _navy),
                        const SizedBox(width: 6),
                        Text(
                          s.title,
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: _navy),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The question groups (Money, Jobs, Sales, Team, Stock) as a small switcher; the open group is navy.
class _AreaTabs extends StatelessWidget {
  final int selected;
  final ValueChanged<int> onSelect;
  const _AreaTabs({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    // Not selectable text: the app-wide selection's I-beam would replace the click cursor over the labels.
    return SelectionContainer.disabled(
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(color: _fill, borderRadius: BorderRadius.circular(10)),
        child: Wrap(
          spacing: 2,
          runSpacing: 2,
          children: [
            for (var i = 0; i < _areas.length; i++)
              _AreaChip(area: _areas[i], selected: i == selected, onTap: () => onSelect(i)),
          ],
        ),
      ),
    );
  }
}

class _AreaChip extends StatefulWidget {
  final _Area area;
  final bool selected;
  final VoidCallback onTap;
  const _AreaChip({required this.area, required this.selected, required this.onTap});

  @override
  State<_AreaChip> createState() => _AreaChipState();
}

class _AreaChipState extends State<_AreaChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.selected;
    final fg = on ? Colors.white : (_hover ? _navy : _slate);
    return Semantics(
      button: true,
      selected: on,
      label: '${widget.area.name} questions',
      excludeSemantics: true,
      child: Material(
        color: on ? _navy : (_hover ? Colors.white : Colors.transparent),
        borderRadius: BorderRadius.circular(7),
        child: InkWell(
          borderRadius: BorderRadius.circular(7),
          onTap: widget.onTap,
          mouseCursor: SystemMouseCursors.click,
          onHover: (v) => setState(() => _hover = v),
          hoverColor: Colors.transparent,
          focusColor: on ? Colors.white.withValues(alpha: 0.14) : _navy.withValues(alpha: 0.06),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(9, 5, 11, 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.area.icon, size: 15, color: fg),
                const SizedBox(width: 6),
                Text(
                  widget.area.name,
                  style: TextStyle(fontSize: 13, fontWeight: on ? FontWeight.w600 : FontWeight.w500, color: fg, height: 1.3),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Questions as cards in rows of equal height, so the full wording of each is visible at a glance.
class _QuestionGrid extends StatelessWidget {
  final List<_Suggestion> questions;
  final int columns;
  final ValueChanged<String> onAsk;
  const _QuestionGrid({required this.questions, required this.columns, required this.onAsk});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var start = 0; start < questions.length; start += columns)
          Padding(
            padding: EdgeInsets.only(top: start == 0 ? 0 : 10),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = start; i < start + columns; i++) ...[
                    if (i > start) const SizedBox(width: 10),
                    Expanded(
                      child: i < questions.length
                          ? _QuestionCard(suggestion: questions[i], onTap: () => onAsk(questions[i].question))
                          : const SizedBox(),
                    ),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// A question you can ask, with its short name over the full wording, so it is clear what it will look up.
class _QuestionCard extends StatefulWidget {
  final _Suggestion suggestion;
  final VoidCallback onTap;
  const _QuestionCard({required this.suggestion, required this.onTap});

  @override
  State<_QuestionCard> createState() => _QuestionCardState();
}

class _QuestionCardState extends State<_QuestionCard> {
  bool _lit = false; // hovered or focused

  @override
  Widget build(BuildContext context) {
    final s = widget.suggestion;
    final radius = BorderRadius.circular(10);
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: _lit ? _navy.withValues(alpha: 0.3) : _stroke),
      ),
      child: InkWell(
        onTap: widget.onTap,
        onHover: (v) => setState(() => _lit = v),
        onFocusChange: (v) => setState(() => _lit = v),
        borderRadius: radius,
        hoverColor: _navy.withValues(alpha: 0.02),
        focusColor: _navy.withValues(alpha: 0.04),
        child: Semantics(
          button: true,
          label: 'Ask: ${s.question}',
          excludeSemantics: true,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(s.icon, size: 16, color: _navy),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        s.title,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _navy, height: 1.3),
                      ),
                    ),
                    Icon(Icons.chevron_right_rounded, size: 17, color: _lit ? _brandRed : DashUi.muted),
                  ],
                ),
                const SizedBox(height: 6),
                Text(s.question, style: const TextStyle(fontSize: 13, color: _slate, height: 1.45)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// --- The checklist of lookups ----------------------------------------------------------------------------------------

/// One lookup: running (a small spinner), done, failed or only partly read, with what it looked at and how long it took.
/// Live while Jarvis works, and the same line under "How I got this" afterwards.
class _LookupLine extends StatelessWidget {
  final AssistantLookup lookup;
  const _LookupLine({required this.lookup});

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    final Widget icon;
    if (lookup.running) {
      icon = still
          ? const Icon(Icons.more_horiz_rounded, size: 15, color: _slate)
          : const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 1.8, color: _slate));
    } else if (!lookup.ok) {
      icon = const Icon(Icons.error_outline_rounded, size: 15, color: DashUi.redText);
    } else if (lookup.partial) {
      icon = const Icon(Icons.warning_amber_rounded, size: 15, color: DashUi.amberText);
    } else {
      icon = const Icon(Icons.check_circle_rounded, size: 15, color: DashUi.emeraldDeep);
    }
    final problem = lookup.running ? null : (!lookup.ok ? 'could not be read' : (lookup.partial ? 'partly read' : null));
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 16, height: 18, child: Center(child: icon)),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: lookup.label,
                        style: const TextStyle(fontWeight: FontWeight.w600, color: _ink),
                      ),
                      if (lookup.detail.isNotEmpty) TextSpan(text: '  ${lookup.detail}'),
                      if (lookup.running && lookup.steps.isNotEmpty)
                        TextSpan(text: '  · ${lookup.steps.where((s) => !s.running).length} of ${lookup.steps.length} parts'),
                      if (problem != null)
                        TextSpan(
                          text: '  · $problem',
                          style: TextStyle(fontWeight: FontWeight.w600, color: lookup.ok ? DashUi.amberText : DashUi.redText),
                        ),
                    ],
                  ),
                  style: const TextStyle(fontSize: 13, color: _slate, height: 1.4),
                ),
              ),
              if (!lookup.running && lookup.ms != null) ...[
                const SizedBox(width: 8),
                Text(
                  _seconds(lookup.ms!),
                  style: const TextStyle(fontSize: 12, color: DashUi.subtle, fontFeatures: [FontFeature.tabularFigures()]),
                ),
              ],
            ],
          ),
          if (lookup.steps.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 24, top: 5),
              child: Wrap(spacing: 6, runSpacing: 5, children: [for (final s in lookup.steps) _StepPill(step: s)]),
            ),
        ],
      ),
    );
  }
}

class _StepPill extends StatelessWidget {
  final AssistantStep step;
  const _StepPill({required this.step});

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    final Widget icon = step.running
        ? (still
              ? const Icon(Icons.more_horiz_rounded, size: 12, color: _slate)
              : const SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5, color: _slate)))
        : Icon(
            step.ok ? Icons.check_rounded : Icons.close_rounded,
            size: 13,
            color: step.ok ? DashUi.emeraldDeep : DashUi.redText,
          );
    return Semantics(
      label: '${step.label}, ${step.running ? 'checking' : (step.ok ? 'done' : 'could not be read')}',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(7, 3, 9, 3),
        decoration: BoxDecoration(
          color: step.ok || step.running ? _fill : DashUi.red.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: 13, height: 13, child: Center(child: icon)),
            const SizedBox(width: 4),
            Text(step.label, style: const TextStyle(fontSize: 12, color: _slate)),
          ],
        ),
      ),
    );
  }
}

// --- Answer blocks -----------------------------------------------------------------------------------------------------

/// `::: priorities`: what to act on first, ranked, each with the facts behind it and a suggested next step (labelled as a
/// suggestion, so advice never reads as data). One container like a table, rows split by hairlines.
class _PriorityList extends StatelessWidget {
  final List<_Priority> items;
  final Set<String> links;
  final ValueChanged<String>? onAsk; // null while the answer is still being written
  const _PriorityList({required this.items, required this.links, this.onAsk});

  @override
  Widget build(BuildContext context) {
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
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const Divider(height: 1, thickness: 1, color: _stroke),
            _PriorityRow(rank: i + 1, item: items[i], links: links, onAsk: onAsk),
          ],
        ],
      ),
    );
  }
}

class _PriorityRow extends StatelessWidget {
  final int rank;
  final _Priority item;
  final Set<String> links;
  final ValueChanged<String>? onAsk;
  const _PriorityRow({required this.rank, required this.item, required this.links, this.onAsk});

  @override
  Widget build(BuildContext context) {
    const title = TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: _ink, height: 1.4);
    const why = TextStyle(fontSize: 13.5, color: _slate, height: 1.45);
    const next = TextStyle(fontSize: 13.5, color: _ink, height: 1.45);
    final (dot, text, word) = switch (item.level) {
      'high' => (DashUi.red, DashUi.redText, 'High'),
      'low' => (DashUi.subtle, _slate, 'Low'),
      _ => (DashUi.amber, DashUi.amberText, 'Medium'),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 22,
            child: Text(
              '$rank',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _slate, height: 1.3),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2, right: 8),
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(6, 1, 8, 1),
                        decoration: BoxDecoration(color: dot.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                            ),
                            const SizedBox(width: 5),
                            Text(
                              word,
                              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: text, height: 1.4),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          style: title,
                          children: _inlineSpans(item.title, title, links: links),
                        ),
                      ),
                    ),
                  ],
                ),
                if (item.why.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text.rich(
                      TextSpan(
                        style: why,
                        children: _inlineSpans(item.why, why, links: links),
                      ),
                    ),
                  ),
                if (item.next.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 2, right: 6),
                          child: Icon(Icons.lightbulb_outline_rounded, size: 15, color: _brandRed),
                        ),
                        Expanded(
                          child: Text.rich(
                            TextSpan(
                              style: next,
                              children: [
                                const TextSpan(
                                  text: 'Suggested: ',
                                  style: TextStyle(fontWeight: FontWeight.w600, color: _brandRed),
                                ),
                                ..._inlineSpans(item.next, next, links: links),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          if (onAsk != null)
            IconButton(
              tooltip: 'Ask more about this',
              visualDensity: VisualDensity.compact,
              iconSize: 17,
              color: _slate,
              onPressed: () => onAsk!('Tell me more about: ${_stripMd(item.title)}'),
              icon: const Icon(Icons.forum_outlined),
            ),
        ],
      ),
    );
  }
}

/// `::: compare`: two periods side by side. The change carries its sign and an arrow as well as colour (green when it is
/// good for the business, red when bad), so it reads without relying on colour.
class _CompareView extends StatelessWidget {
  final _Compare compare;
  final Set<String> links;
  const _CompareView({required this.compare, required this.links});

  static int _direction(String change) {
    final t = _stripMd(change).trim();
    if (t.isEmpty || RegExp(r'^n/?a', caseSensitive: false).hasMatch(t)) return 0;
    if (t.startsWith('-') || t.startsWith('−') || t.startsWith('(')) return -1;
    final n = double.tryParse(t.replaceAll(RegExp(r'[^0-9.]'), ''));
    return n == null || n == 0 ? 0 : 1;
  }

  @override
  Widget build(BuildContext context) {
    final cur = compare.periods.isNotEmpty && compare.periods[0].isNotEmpty ? compare.periods[0] : 'Now';
    final prev = compare.periods.length > 1 && compare.periods[1].isNotEmpty ? compare.periods[1] : 'Before';
    const head = TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 0.5, color: _slate);
    const cellPad = EdgeInsets.symmetric(horizontal: 12, vertical: 9);
    const nums = [FontFeature.tabularFigures()];
    Widget headCell(String t, {bool end = true}) => Padding(
      padding: cellPad,
      child: Text(t.toUpperCase(), textAlign: end ? TextAlign.right : TextAlign.left, style: head),
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
          if (compare.title.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
              child: Text(
                compare.title,
                style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: _ink),
              ),
            ),
          Table(
            columnWidths: const {
              0: FlexColumnWidth(2),
              1: IntrinsicColumnWidth(),
              2: IntrinsicColumnWidth(),
              3: IntrinsicColumnWidth(),
            },
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            border: const TableBorder(horizontalInside: BorderSide(color: _stroke)),
            children: [
              TableRow(
                decoration: const BoxDecoration(color: _fill),
                children: [headCell('Measure', end: false), headCell(cur), headCell(prev), headCell('Change')],
              ),
              for (final r in compare.rows)
                TableRow(
                  children: [
                    Padding(
                      padding: cellPad,
                      child: Text.rich(
                        TextSpan(
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _ink, height: 1.3),
                          children: _inlineSpans(
                            r.measure,
                            const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                            links: links,
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: cellPad,
                      child: Text(
                        _stripMd(r.current),
                        textAlign: TextAlign.right,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _ink, fontFeatures: nums),
                      ),
                    ),
                    Padding(
                      padding: cellPad,
                      child: Text(
                        _stripMd(r.previous),
                        textAlign: TextAlign.right,
                        style: const TextStyle(fontSize: 13, color: _slate, fontFeatures: nums),
                      ),
                    ),
                    _changeCell(r),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _changeCell(_CompareRow r) {
    final dir = _direction(r.change);
    final color = switch (r.tone) {
      'good' => DashUi.emeraldText,
      'bad' => DashUi.redText,
      _ => _slate,
    };
    final word = switch (r.tone) {
      'good' => 'better',
      'bad' => 'worse',
      _ => '',
    };
    return Semantics(
      label: '${_stripMd(r.change)}${word.isEmpty ? '' : ', $word'}',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              dir > 0 ? Icons.arrow_upward_rounded : (dir < 0 ? Icons.arrow_downward_rounded : Icons.remove_rounded),
              size: 13,
              color: color,
            ),
            const SizedBox(width: 3),
            Text(
              _stripMd(r.change),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: color,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// `::: basis`: the dates an answer covers and how its measures are defined, so a figure can be checked and is not
/// mistaken for a different one ("money owed" here is invoiced jobs only).
class _BasisNote extends StatelessWidget {
  final List<String> lines;
  final Set<String> links;
  const _BasisNote({required this.lines, required this.links});

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(fontSize: 12.5, color: _slate, height: 1.45);
    return Container(
      margin: const EdgeInsets.only(top: 2, bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
      decoration: BoxDecoration(color: _fill, borderRadius: BorderRadius.circular(10)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(Icons.info_outline_rounded, size: 15, color: _slate),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Dates and definitions',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _slate, height: 1.4),
                ),
                for (final l in lines)
                  Text.rich(
                    TextSpan(
                      style: style,
                      children: _inlineSpans(l, style, links: links),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
