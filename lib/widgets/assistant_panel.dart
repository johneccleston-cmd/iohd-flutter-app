import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../config/auth_session.dart';

// --- Design tokens (same palette as the top bar) -------------------------------
const Color _brandRed = Color(0xFFCC0007);
const Color _ink = Color(0xFF181B1F);
const Color _slate = Color(0xFF5B6572);
const Color _muted = Color(0xFF9199A6);
const Color _stroke = Color(0xFFE4E7EC);
const Color _tint = Color(0xFFFCEEEE);
const Color _fill = Color(0xFFF6F7F9);

const Color _good = Color(0xFF16A34A);
const Color _warn = Color(0xFFD97706);
const Color _bad = Color(0xFFDC2626);
const Color _info = Color(0xFF4F46E5);
const Color _teal = Color(0xFF0891B2);

// The backend accepts at most 20 messages of 4000 characters each.
const int _maxHistory = 19;
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
};

enum AssistantRole { user, assistant }

class AssistantMessage {
  final AssistantRole role;
  final String text;
  final List<String> sources;

  /// True until the panel has shown this message once, so a new answer animates in and a re-opened
  /// conversation does not replay.
  bool fresh = true;

  AssistantMessage(this.role, this.text, [this.sources = const []]);
}

/// The conversation lives here, in memory only, so it survives closing the panel but not a sign-out
/// or an app restart. Nothing is written to disk.
class AssistantChat extends ChangeNotifier {
  AssistantChat._() {
    AuthSession.instance.addListener(_onAuthChanged);
  }
  static final AssistantChat instance = AssistantChat._();

  final List<AssistantMessage> messages = [];
  bool busy = false;
  String? error;

  void _onAuthChanged() {
    if (!AuthSession.instance.isLoggedIn) clear();
  }

  void clear() {
    messages.clear();
    busy = false;
    error = null;
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
    while (list.length > _maxHistory) {
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

  Future<void> _ask() async {
    busy = true;
    error = null;
    notifyListeners();

    try {
      final res = await http
          .post(
            Uri.parse('$kApiBaseUrl/api/assistant'),
            headers: AuthSession.instance.headers(),
            body: json.encode({'messages': _payload()}),
          )
          .timeout(const Duration(seconds: 120)); // free-tier hosts wake slowly and answers can take a few lookups

      Map<String, dynamic> body = const {};
      try {
        body = json.decode(res.body) as Map<String, dynamic>;
      } catch (_) {}

      switch (res.statusCode) {
        case 200:
          final answer = (body['answer'] ?? '').toString().trim();
          final tools = <String>{
            for (final t in (body['toolsUsed'] as List? ?? const [])) if (_toolLabels[t] != null) _toolLabels[t]!,
          }.toList();
          messages.add(AssistantMessage(
            AssistantRole.assistant,
            answer.isEmpty ? "I couldn't put together an answer. Try rephrasing." : answer,
            tools,
          ));
        case 401:
          AuthSession.instance.logout(); // sends the app back to the sign-in screen
          error = 'Your session expired. Please sign in again.';
        case 403:
          error = 'Your account does not have access to the assistant.';
        case 503:
          error = 'The assistant is not set up on the server yet.';
        default:
          error = (body['error'] ?? 'Server error (${res.statusCode}).').toString();
      }
    } on TimeoutException {
      error = 'That took too long. The server may be waking up, so try again in a moment.';
    } catch (_) {
      error = "Couldn't reach the server. Check your connection and try again.";
    } finally {
      busy = false;
      notifyListeners();
    }
  }
}

/// Opens the assistant as a panel sliding in from the right, over whatever screen you are on.
Future<void> showAssistantPanel(BuildContext context) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close assistant',
    barrierColor: Colors.black.withValues(alpha: 0.25),
    transitionDuration: const Duration(milliseconds: 240),
    pageBuilder: (_, _, _) => const Align(alignment: Alignment.centerRight, child: _AssistantPanel()),
    transitionBuilder: (_, animation, _, child) => SlideTransition(
      position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
          .animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: child,
    ),
  );
}

// =============================================================================
// Answer parsing
// =============================================================================

sealed class _Block {}

class _Para extends _Block {
  final String text;
  _Para(this.text);
}

class _Head extends _Block {
  final String text;
  _Head(this.text);
}

class _Item extends _Block {
  final String text;
  final String? number; // null = bullet
  _Item(this.text, this.number);
}

class _Table extends _Block {
  final List<List<String>> rows; // first row is the header
  _Table(this.rows);
}

class _Stats extends _Block {
  final List<(String value, String label)> items;
  _Stats(this.items);
}

class _Parsed {
  final List<_Block> blocks;
  final List<String> followUps;
  final String plain;
  _Parsed(this.blocks, this.followUps, this.plain);
}

final RegExp _bulletRe = RegExp(r'^\s*[-*•]\s+');
final RegExp _numberedRe = RegExp(r'^\s*(\d+)[.)]\s+');
final RegExp _headingRe = RegExp(r'^\s{0,3}#{1,4}\s+(.*)$');
final RegExp _dashCellRe = RegExp(r'^:?-{2,}:?$');
final RegExp _directiveRe = RegExp(r'^\s*:::\s*(stats|followups)\s*$', caseSensitive: false);

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
  var i = 0;
  while (i < lines.length) {
    final line = lines[i].trimRight();

    final directive = _directiveRe.firstMatch(line);
    if (directive != null) {
      final kind = directive.group(1)!.toLowerCase();
      final body = <String>[];
      i++;
      while (i < lines.length && lines[i].trim() != ':::') {
        if (lines[i].trim().isNotEmpty) body.add(lines[i].trim());
        i++;
      }
      i++; // closing :::
      if (kind == 'stats') {
        final items = <(String, String)>[];
        for (final b in body) {
          final parts = b.split('|');
          if (parts.length >= 2) items.add((parts.first.trim(), parts.sublist(1).join('|').trim()));
        }
        if (items.isNotEmpty) blocks.add(_Stats(items.take(4).toList()));
      } else {
        for (final b in body) {
          final q = b.replaceFirst(_bulletRe, '').trim();
          if (q.isNotEmpty) followUps.add(q);
        }
      }
      continue;
    }

    if (_isRow(line)) {
      final tableLines = <String>[];
      while (i < lines.length && _isRow(lines[i])) {
        tableLines.add(lines[i]);
        plain.add(lines[i]);
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

    i++;
    plain.add(line);
    final heading = _headingRe.firstMatch(line);
    final numbered = _numberedRe.firstMatch(line);
    if (line.trim().isEmpty) continue;
    if (heading != null) {
      blocks.add(_Head(heading.group(1)!));
    } else if (_bulletRe.hasMatch(line)) {
      blocks.add(_Item(line.replaceFirst(_bulletRe, ''), null));
    } else if (numbered != null) {
      blocks.add(_Item(line.replaceFirst(_numberedRe, ''), numbered.group(1)));
    } else {
      blocks.add(_Para(line));
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

  final _chat = AssistantChat.instance;
  final _input = TextEditingController();
  final _inputFocus = FocusNode();
  final _scroll = ScrollController();
  final _lastAnswerKey = GlobalKey();
  int _seen = 0;

  @override
  void initState() {
    super.initState();
    _seen = _chat.messages.length;
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

  void _onChat() {
    final n = _chat.messages.length;
    final newAnswer = n > _seen && _chat.messages.last.role == AssistantRole.assistant;
    _seen = n;
    if (newAnswer) {
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
    _input.clear();
    _chat.send(q);
    _inputFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context).width;
    final target = _wide ? (screen - 80).clamp(560.0, 880.0) : 560.0;
    final width = screen < 560 ? screen : target;
    return Material(
      color: Colors.white,
      elevation: 16,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        width: width,
        height: double.infinity,
        decoration: const BoxDecoration(border: Border(left: BorderSide(color: _stroke))),
        child: SafeArea(
          child: Column(
            children: [
              _header(screen),
              const Divider(height: 1, color: _stroke),
              Expanded(
                child: ListenableBuilder(
                  listenable: _chat,
                  builder: (context, _) => _chat.messages.isEmpty && !_chat.busy ? _emptyState() : _thread(),
                ),
              ),
              _composer(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(double screen) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 10, 12),
      child: Row(
        children: [
          const _Mark(size: 34),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Ask IOHD', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: _ink, height: 1.2)),
                Text('Read-only. Answers come from your live data.',
                    style: TextStyle(fontSize: 12, color: _slate, height: 1.3)),
              ],
            ),
          ),
          if (screen >= 700)
            IconButton(
              tooltip: _wide ? 'Narrow view' : 'Wide view',
              onPressed: () => setState(() => _wide = !_wide),
              icon: Icon(_wide ? Icons.close_fullscreen_rounded : Icons.open_in_full_rounded, size: 18),
              color: _slate,
            ),
          ListenableBuilder(
            listenable: _chat,
            builder: (context, _) => IconButton(
              tooltip: 'New conversation',
              onPressed: _chat.messages.isEmpty || _chat.busy ? null : _chat.clear,
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
      padding: const EdgeInsets.fromLTRB(24, 44, 24, 16),
      children: [
        const Center(child: _Mark(size: 46)),
        const SizedBox(height: 18),
        Text(_greeting(),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: _ink, letterSpacing: -0.3)),
        const SizedBox(height: 6),
        const Text(
          'Ask about jobs, customers, revenue, estimates or inventory.\nI can look things up but I can’t change anything.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13.5, color: _slate, height: 1.5),
        ),
        const SizedBox(height: 28),
        for (final s in _suggestions)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _SuggestionCard(suggestion: s, onTap: () => _submit(s.question)),
          ),
      ],
    );
  }

  Widget _thread() {
    final msgs = _chat.messages;
    return SingleChildScrollView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < msgs.length; i++)
            if (msgs[i].role == AssistantRole.user)
              _UserMessage(key: ObjectKey(msgs[i]), message: msgs[i])
            else
              _AnswerView(
                key: i == msgs.length - 1 && !_chat.busy ? _lastAnswerKey : ObjectKey(msgs[i]),
                message: msgs[i],
                isLast: i == msgs.length - 1 && !_chat.busy && _chat.error == null,
                onAsk: _submit,
                onRegenerate: _chat.regenerate,
              ),
          if (_chat.busy) const _Thinking(),
          if (_chat.error != null) _ErrorNote(message: _chat.error!, onRetry: _chat.retry),
        ],
      ),
    );
  }

  Widget _composer() {
    final focused = _inputFocus.hasFocus;
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 6, 14, 6),
      padding: const EdgeInsets.fromLTRB(16, 4, 6, 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: focused ? _brandRed : _stroke, width: focused ? 1.5 : 1),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 14, offset: const Offset(0, 4))],
      ),
      child: Column(
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
                        event.logicalKey == LogicalKeyboardKey.enter &&
                        !HardwareKeyboard.instance.isShiftPressed) {
                      _submit();
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
                    style: const TextStyle(fontSize: 14, color: _ink, height: 1.4),
                    cursorColor: _brandRed,
                    decoration: const InputDecoration(
                      hintText: 'Ask anything about your business…',
                      hintStyle: TextStyle(fontSize: 14, color: _muted),
                      counterText: '',
                      isDense: true,
                      filled: false,
                      contentPadding: EdgeInsets.symmetric(vertical: 12),
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
                    final ready = !_chat.busy && _input.text.trim().isNotEmpty;
                    return IconButton.filled(
                      tooltip: 'Send',
                      onPressed: ready ? _submit : null,
                      icon: const Icon(Icons.arrow_upward_rounded, size: 19),
                      style: IconButton.styleFrom(
                        backgroundColor: _brandRed,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: _stroke,
                        disabledForegroundColor: Colors.white,
                        fixedSize: const Size(36, 36),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Mark extends StatelessWidget {
  final double size;
  const _Mark({required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFE0252C), _brandRed],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(size * 0.32),
        boxShadow: [BoxShadow(color: _brandRed.withValues(alpha: 0.25), blurRadius: 10, offset: const Offset(0, 3))],
      ),
      child: Icon(Icons.auto_awesome_rounded, size: size * 0.5, color: Colors.white),
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  final _Suggestion suggestion;
  final VoidCallback onTap;
  const _SuggestionCard({required this.suggestion, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        hoverColor: _fill,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: _stroke)),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(color: _tint, borderRadius: BorderRadius.circular(10)),
                child: Icon(suggestion.icon, size: 19, color: _brandRed),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(suggestion.title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: _ink)),
                    const SizedBox(height: 2),
                    Text(suggestion.question, style: const TextStyle(fontSize: 12.5, color: _slate, height: 1.35)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.arrow_forward_rounded, size: 16, color: _muted),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Messages
// =============================================================================

class _UserMessage extends StatelessWidget {
  final AssistantMessage message;
  const _UserMessage({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18, left: 40),
      child: Align(
        alignment: Alignment.centerRight,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
          decoration: BoxDecoration(color: _fill, borderRadius: BorderRadius.circular(18)),
          child: SelectableText(message.text, style: const TextStyle(fontSize: 14, color: _ink, height: 1.45)),
        ),
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
  const _AnswerView({
    super.key,
    required this.message,
    required this.isLast,
    required this.onAsk,
    required this.onRegenerate,
  });

  @override
  State<_AnswerView> createState() => _AnswerViewState();
}

class _AnswerViewState extends State<_AnswerView> {
  late final _Parsed _parsed = _parse(widget.message.text);
  late final bool _animate = widget.message.fresh;
  bool _copied = false;
  Timer? _copiedTimer;

  @override
  void initState() {
    super.initState();
    widget.message.fresh = false;
  }

  @override
  void dispose() {
    _copiedTimer?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _parsed.plain.replaceAll('**', '')));
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
      padding: const EdgeInsets.only(bottom: 22),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(padding: EdgeInsets.only(top: 1), child: _Mark(size: 26)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectionArea(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final b in blocks) reveal(_blockView(b)),
                    ],
                  ),
                ),
                reveal(_actions()),
                if (widget.isLast && _parsed.followUps.isNotEmpty) reveal(_followUps()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _blockView(_Block b) {
    return switch (b) {
      _Para() => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text.rich(TextSpan(style: _bodyStyle, children: _inlineSpans(b.text, _bodyStyle))),
        ),
      _Head() => Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 6),
          child: Text.rich(TextSpan(
            style: _bodyStyle.copyWith(fontSize: 15.5, fontWeight: FontWeight.w800, letterSpacing: -0.1),
            children: _inlineSpans(b.text, _bodyStyle.copyWith(fontSize: 15.5)),
          )),
        ),
      _Item() => Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 20,
                child: b.number == null
                    ? const Padding(
                        padding: EdgeInsets.only(top: 9, left: 4),
                        child: DecoratedBox(
                          decoration: BoxDecoration(color: _brandRed, shape: BoxShape.circle),
                          child: SizedBox(width: 5, height: 5),
                        ),
                      )
                    : Text('${b.number}.', style: _bodyStyle.copyWith(color: _slate, fontWeight: FontWeight.w600)),
              ),
              Expanded(child: Text.rich(TextSpan(style: _bodyStyle, children: _inlineSpans(b.text, _bodyStyle)))),
            ],
          ),
        ),
      _Table() => Padding(padding: const EdgeInsets.only(top: 4, bottom: 14), child: _ChatTable(rows: b.rows)),
      _Stats() => Padding(padding: const EdgeInsets.only(top: 2, bottom: 14), child: _StatRow(items: b.items, animate: _animate)),
    };
  }

  Widget _actions() {
    final sources = widget.message.sources;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
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
          if (widget.isLast) _MiniAction(icon: Icons.refresh_rounded, label: 'Retry', onTap: widget.onRegenerate),
          if (sources.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.verified_outlined, size: 14, color: _muted),
                  const SizedBox(width: 5),
                  Text('Checked ${sources.join(' · ')}', style: const TextStyle(fontSize: 11.5, color: _muted)),
                ],
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
        children: [
          for (final q in _parsed.followUps) _FollowUpChip(text: q, onTap: () => widget.onAsk(q)),
        ],
      ),
    );
  }
}

class _MiniAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;
  final VoidCallback onTap;
  const _MiniAction({required this.icon, required this.label, required this.onTap, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? _slate;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      hoverColor: _fill,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: c),
            const SizedBox(width: 5),
            Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c)),
          ],
        ),
      ),
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
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        hoverColor: _tint,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 7, 10, 7),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), border: Border.all(color: _stroke)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(text, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: _ink, height: 1.3)),
              ),
              const SizedBox(width: 6),
              const Icon(Icons.arrow_outward_rounded, size: 13, color: _brandRed),
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

const TextStyle _bodyStyle = TextStyle(fontSize: 14, color: _ink, height: 1.55);

/// **bold** inside a line of text.
List<InlineSpan> _inlineSpans(String line, TextStyle base) {
  final spans = <InlineSpan>[];
  var last = 0;
  for (final m in RegExp(r'\*\*(.+?)\*\*').allMatches(line)) {
    if (m.start > last) spans.add(TextSpan(text: line.substring(last, m.start)));
    spans.add(TextSpan(text: m.group(1), style: base.copyWith(fontWeight: FontWeight.w800)));
    last = m.end;
  }
  if (last < line.length) spans.add(TextSpan(text: line.substring(last)));
  return spans;
}

class _StatRow extends StatelessWidget {
  final List<(String value, String label)> items;
  final bool animate;
  const _StatRow({required this.items, required this.animate});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final cols = c.maxWidth >= 150.0 * items.length ? items.length : (c.maxWidth >= 300 ? 2 : 1);
      const gap = 10.0;
      final w = (c.maxWidth - gap * (cols - 1)) / cols;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (var i = 0; i < items.length; i++)
            SizedBox(
              width: w,
              child: Container(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                decoration: BoxDecoration(
                  color: i == 0 ? _tint : _fill,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: i == 0 ? _brandRed.withValues(alpha: 0.18) : _stroke),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _CountUp(
                      value: items[i].$1,
                      animate: animate,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.5,
                        color: i == 0 ? _brandRed : _ink,
                        height: 1.15,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(items[i].$2, style: const TextStyle(fontSize: 12, color: _slate, height: 1.3)),
                  ],
                ),
              ),
            ),
        ],
      );
    });
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

Color _statusColor(String s) {
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
  static final _numericRe = RegExp(r'^[\$\-+(]?\s?[\d,]*\.?\d+\s?[%)kKmM]?$');

  late final int _cols = widget.rows.first.length;
  late final List<String> _header = _fit(widget.rows.first);
  late final List<List<String>> _all = [for (final r in widget.rows.skip(1)) _fit(r)];
  late final List<List<String>> _body = _all.where((r) => !_isTotal(r)).toList();
  late final List<List<String>> _totals = _all.where(_isTotal).toList();

  late final List<bool> _numeric = [
    for (var c = 0; c < _cols; c++) _body.every((r) => r[c].isEmpty || _numericRe.hasMatch(r[c])) && _body.any((r) => r[c].isNotEmpty),
  ];

  /// Last column whose cells are all dollar amounts: that one gets the data bars.
  late final int? _barCol = () {
    for (var c = _cols - 1; c >= 0; c--) {
      if (_numeric[c] && _body.every((r) => r[c].isEmpty || r[c].trim().startsWith(r'$')) && _body.any((r) => r[c].isNotEmpty)) return c;
    }
    return null;
  }();

  late final bool _statusCol = RegExp(r'status|stage').hasMatch(_header.first.toLowerCase());

  int? _sortCol;
  bool _asc = true;
  bool _expanded = false;
  bool _copied = false;
  Timer? _timer;

  List<String> _fit(List<String> r) => [for (var c = 0; c < _cols; c++) c < r.length ? r[c].replaceAll('**', '') : ''];

  bool _isTotal(List<String> r) => RegExp(r'^(grand\s+)?total\b', caseSensitive: false).hasMatch(r.first.trim());

  static double _num(String s) {
    var t = s.trim();
    final neg = t.startsWith('-') || (t.startsWith('(') && t.endsWith(')'));
    final mult = RegExp(r'[kK]$').hasMatch(t) ? 1e3 : (RegExp(r'[mM]$').hasMatch(t) ? 1e6 : 1.0);
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

  Future<void> _copy() async {
    final text = [_header, ..._all].map((r) => r.join('\t')).join('\n');
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
                Text(_header[c].toUpperCase(),
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                      color: _sortCol == c ? _brandRed : _slate,
                    )),
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
      if (c == 0 && _statusCol && !total) {
        text = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: _statusColor(t), shape: BoxShape.circle)),
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
        TableRow(decoration: const BoxDecoration(color: _fill), children: [for (var c = 0; c < _cols; c++) headCell(c)]),
        for (final r in shown) TableRow(children: [for (var c = 0; c < _cols; c++) cell(r, c)]),
        for (final r in _totals)
          TableRow(
            decoration: BoxDecoration(color: _tint.withValues(alpha: 0.6)),
            children: [for (var c = 0; c < _cols; c++) cell(r, c, total: true)],
          ),
      ],
    );

    return Container(
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: _stroke)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          table,
          Container(
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: _stroke))),
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
                    child: Text('${sorted.length} ${sorted.length == 1 ? 'row' : 'rows'}',
                        style: const TextStyle(fontSize: 11.5, color: _muted)),
                  ),
                const Spacer(),
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
  const _Thinking();

  @override
  State<_Thinking> createState() => _ThinkingState();
}

class _ThinkingState extends State<_Thinking> with SingleTickerProviderStateMixin {
  static const _phrases = ['Looking through your jobs…', 'Checking the numbers…', 'Putting it together…'];
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))..repeat();
  Timer? _timer;
  int _i = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 3200), (_) {
      if (mounted) setState(() => _i = (_i + 1).clamp(0, _phrases.length - 1));
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Row(
        children: [
          ScaleTransition(
            scale: still ? const AlwaysStoppedAnimation(1.0) : Tween(begin: 0.9, end: 1.08).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut)),
            child: const _Mark(size: 26),
          ),
          const SizedBox(width: 12),
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
                child: Text(_phrases[_i], key: ValueKey(_i), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            ),
          ),
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
