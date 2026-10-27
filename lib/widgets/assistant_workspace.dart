part of 'assistant_panel.dart';

// =============================================================================
// Jarvis workspace (2026-10-27): the welcome screen with the daily briefing and the questions Jarvis can answer, links
// to the records an answer names, the live checklist of lookups, and the answer blocks for priorities, comparisons and
// the dates-and-definitions note.
// =============================================================================

/// The daily briefing's question. The welcome screen asks it, and spots an earlier answer to it from today.
const String _briefingQuestion = "Give me today's priorities and tell me why each one matters.";

/// Questions grouped by what they are about, so the welcome screen shows what Jarvis can look up. Each one maps to a
/// lookup the server has (see the tool guide in the backend prompt).
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
  ]),
  _Area('Jobs', Icons.handyman_outlined, [
    _Suggestion(Icons.hourglass_bottom_rounded, 'Stuck jobs', 'Which jobs are stuck, and what is holding them up?'),
    _Suggestion(Icons.event_available_outlined, 'This week', 'What is scheduled for the technicians this week?'),
    _Suggestion(Icons.update_rounded, 'Since yesterday', 'What changed in our business since yesterday?'),
  ]),
  _Area('Sales', Icons.handshake_outlined, [
    _Suggestion(Icons.mark_email_unread_outlined, 'Follow-ups', 'Which estimates need follow-up first?'),
    _Suggestion(
      Icons.compare_arrows_rounded,
      'Month vs last',
      'Compare this month with last month and explain the major differences.',
    ),
    _Suggestion(Icons.filter_alt_outlined, 'Pipeline', 'What is our open estimate pipeline and win rate this year?'),
  ]),
  _Area('Team', Icons.engineering_outlined, [
    _Suggestion(
      Icons.trending_up_rounded,
      'Tech trends',
      'How are our technicians performing, and what trends should I know about?',
    ),
    _Suggestion(Icons.star_outline_rounded, 'Reviews', 'How are our Google reviews doing, and which techs are mentioned most?'),
    _Suggestion(Icons.receipt_long_outlined, 'This week’s pay', 'What does payroll look like for this week?'),
  ]),
  _Area('Stock', Icons.inventory_2_outlined, [
    _Suggestion(Icons.report_gmailerrorred_outlined, 'Upcoming shortages', 'What inventory issues could affect upcoming jobs?'),
    _Suggestion(Icons.inventory_outlined, 'Low stock', 'Which inventory items are low on stock?'),
    _Suggestion(
      Icons.door_front_door_outlined,
      'Doors on upcoming jobs',
      'How many Clopay doors are on upcoming jobs, by model?',
    ),
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

/// "yesterday", or "Friday" on a weekend or a Monday: how far back the briefing's "what changed" looks.
String _sinceWords(DateTime now) => (now.weekday == DateTime.monday || now.weekday >= DateTime.saturday) ? 'Friday' : 'yesterday';

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
  final ({int chat, DateTime at})? lastBriefing;
  final ValueChanged<String> onAsk;
  final ValueChanged<int> onOpenChat;
  const _JarvisHome({
    required this.greeting,
    required this.canAsk,
    required this.pagePath,
    required this.pageName,
    required this.lastBriefing,
    required this.onAsk,
    required this.onOpenChat,
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
    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 16),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(color: _tint, shape: BoxShape.circle),
                      child: const Icon(Icons.auto_awesome_rounded, size: 21, color: _brandRed),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Semantics(
                        header: true,
                        child: Text(
                          widget.greeting,
                          textAlign: TextAlign.center,
                          style: _serifStyle.copyWith(
                            fontSize: 28,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.6,
                            height: 1.15,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  widget.canAsk
                      ? 'Ask about money owed, jobs, estimates, the team or stock. I look it up in your live data, show how I '
                            'got each answer, and can’t change anything.'
                      : 'Jarvis is only for admin and owner accounts, because it can read pay, profit and every customer. Ask an admin if you need something looked up.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 14.5, color: _slate, height: 1.5),
                ),
                if (widget.canAsk) ...[
                  const SizedBox(height: 18),
                  _BriefingCard(
                    last: widget.lastBriefing,
                    onRun: () => widget.onAsk(_briefingQuestion),
                    onOpen: widget.lastBriefing == null ? null : () => widget.onOpenChat(widget.lastBriefing!.chat),
                  ),
                  if (here.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    _HomeHeading(_pageHeading(widget.pageName)),
                    for (final s in here) _QuestionRow(suggestion: s, onTap: () => widget.onAsk(s.question)),
                  ],
                  const SizedBox(height: 16),
                  const _HomeHeading('Explore what Jarvis can look up'),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (var i = 0; i < _areas.length; i++)
                        _AreaChip(area: _areas[i], selected: i == _area, onTap: () => setState(() => _area = i)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  for (final s in area.questions) _QuestionRow(suggestion: s, onTap: () => widget.onAsk(s.question)),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _HomeHeading extends StatelessWidget {
  final String text;
  const _HomeHeading(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 6),
    child: Semantics(
      header: true,
      child: Text(
        text,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _slate),
      ),
    ),
  );
}

/// The daily briefing entry point: one click for today's priorities with the reasons behind them.
class _BriefingCard extends StatelessWidget {
  final ({int chat, DateTime at})? last;
  final VoidCallback onRun;
  final VoidCallback? onOpen;
  const _BriefingCard({required this.last, required this.onRun, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final now = AssistantChat.now();
    final ran = last;
    return Material(
      color: Color.alphaBlend(_brandRed.withValues(alpha: 0.045), _paper),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: _brandRed.withValues(alpha: 0.2)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onRun,
        hoverColor: _brandRed.withValues(alpha: 0.04),
        focusColor: _brandRed.withValues(alpha: 0.08),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: _brandRed.withValues(alpha: 0.2)),
                ),
                child: const Icon(Icons.wb_twilight_rounded, size: 22, color: _brandRed),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Today’s priorities',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _ink),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'What to act on first and why: money owed, stuck jobs, quiet estimates, stock for booked jobs and what '
                      'changed since ${_sinceWords(now)}.',
                      style: const TextStyle(fontSize: 13.5, color: _slate, height: 1.4),
                    ),
                    if (ran != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(
                          children: [
                            const Icon(Icons.history_rounded, size: 14, color: _slate),
                            const SizedBox(width: 4),
                            Text('Last run ${_answerTime(ran.at, now)}', style: const TextStyle(fontSize: 12.5, color: _slate)),
                            const SizedBox(width: 2),
                            TextButton(
                              onPressed: onOpen,
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(horizontal: 6),
                                minimumSize: const Size(32, 28),
                              ),
                              child: const Text('Open it', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // Looks like a button, but the whole card is the one tab stop and click target.
              ExcludeSemantics(
                child: Container(
                  padding: const EdgeInsets.fromLTRB(12, 8, 14, 8),
                  decoration: BoxDecoration(color: _brandRed, borderRadius: BorderRadius.circular(20)),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.play_arrow_rounded, size: 18, color: Colors.white),
                      const SizedBox(width: 4),
                      Text(
                        ran == null ? 'Run briefing' : 'Run again',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white),
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

class _AreaChip extends StatelessWidget {
  final _Area area;
  final bool selected;
  final VoidCallback onTap;
  const _AreaChip({required this.area, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '${area.name} questions',
      excludeSemantics: true,
      child: Material(
        color: selected ? _tint : Colors.white,
        shape: StadiumBorder(side: BorderSide(color: selected ? _brandRed.withValues(alpha: 0.45) : _stroke)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          hoverColor: _fill,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 7, 14, 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(area.icon, size: 16, color: selected ? _brandRed : _slate),
                const SizedBox(width: 6),
                Text(
                  area.name,
                  style: TextStyle(fontSize: 13, fontWeight: selected ? FontWeight.w600 : FontWeight.w500, color: _ink),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A question you can ask, with its short name over the full wording, so it is clear what it will look up.
class _QuestionRow extends StatelessWidget {
  final _Suggestion suggestion;
  final VoidCallback onTap;
  const _QuestionRow({required this.suggestion, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          hoverColor: _fill,
          focusColor: _fill,
          child: Semantics(
            button: true,
            label: 'Ask: ${suggestion.question}',
            excludeSemantics: true,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(color: _fill, borderRadius: BorderRadius.circular(9)),
                    child: Icon(suggestion.icon, size: 17, color: _slate),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          suggestion.title,
                          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: _ink),
                        ),
                        const SizedBox(height: 1),
                        Text(suggestion.question, style: const TextStyle(fontSize: 13, color: _slate, height: 1.35)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.arrow_outward_rounded, size: 15, color: DashUi.subtle),
                ],
              ),
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

/// Shows which page goes with each question ("Using: Collections dashboard"), and lets the person switch it off.
class _ContextChip extends StatelessWidget {
  final String page;
  final bool on;
  final VoidCallback onToggle;
  const _ContextChip({required this.page, required this.on, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: on
          ? 'Questions are sent with the page you are on, so "this job" and "here" work. Click to stop.'
          : 'Send the page you are on with your questions',
      waitDuration: const Duration(milliseconds: 500),
      child: Material(
        color: on ? _fill : Colors.transparent,
        shape: StadiumBorder(side: BorderSide(color: on ? Colors.transparent : _stroke)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onToggle,
          child: Semantics(
            button: true,
            toggled: on,
            label: on ? 'Using this page: $page' : 'Use this page: $page',
            excludeSemantics: true,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(on ? Icons.place_outlined : Icons.add_location_alt_outlined, size: 14, color: _slate),
                  const SizedBox(width: 4),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 260),
                    child: Text(
                      on ? 'Using: $page' : 'Use this page',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _slate),
                    ),
                  ),
                  if (on) ...[const SizedBox(width: 4), const Icon(Icons.close_rounded, size: 13, color: _slate)],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
