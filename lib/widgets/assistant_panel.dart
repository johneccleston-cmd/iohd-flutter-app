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

// The backend accepts at most 20 messages of 4000 characters each.
const int _maxHistory = 19;
const int _maxChars = 4000;

const List<String> _suggestions = [
  'Who are our top 10 customers by revenue this year?',
  'How many open jobs do we have, by status?',
  'Show completed revenue and profit by month this year.',
  'Which inventory items are low on stock?',
];

// What the person sees under an answer, instead of internal tool names.
const Map<String, String> _toolLabels = {
  'search_jobs': 'Jobs',
  'get_job': 'Job detail',
  'customer_lookup': 'Customers',
  'top_customers_by_revenue': 'Customer revenue',
  'monthly_financials': 'Financials',
  'estimates_summary': 'Estimates',
  'open_jobs_by_status': 'Open jobs',
  'low_stock_items': 'Inventory',
  'list_employees': 'Employees',
};

enum AssistantRole { user, assistant }

class AssistantMessage {
  final AssistantRole role;
  final String text;
  final List<String> sources;
  const AssistantMessage(this.role, this.text, [this.sources = const []]);
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
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (_, _, _) => const Align(alignment: Alignment.centerRight, child: _AssistantPanel()),
    transitionBuilder: (_, animation, _, child) => SlideTransition(
      position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
          .animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: child,
    ),
  );
}

class _AssistantPanel extends StatefulWidget {
  const _AssistantPanel();

  @override
  State<_AssistantPanel> createState() => _AssistantPanelState();
}

class _AssistantPanelState extends State<_AssistantPanel> {
  final _chat = AssistantChat.instance;
  final _input = TextEditingController();
  final _inputFocus = FocusNode();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _chat.addListener(_scrollToEnd);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd(jump: true));
  }

  @override
  void dispose() {
    _chat.removeListener(_scrollToEnd);
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToEnd({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final end = _scroll.position.maxScrollExtent;
      if (jump) {
        _scroll.jumpTo(end);
      } else {
        _scroll.animateTo(end, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
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
    final width = MediaQuery.sizeOf(context).width;
    return Material(
      color: Colors.white,
      elevation: 16,
      child: Container(
        width: width < 480 ? width : 460,
        height: double.infinity,
        decoration: const BoxDecoration(border: Border(left: BorderSide(color: _stroke))),
        child: SafeArea(
          child: Column(
            children: [
              _header(),
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

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 10, 12),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(color: _tint, borderRadius: BorderRadius.circular(10)),
            child: const Icon(Icons.auto_awesome_rounded, size: 18, color: _brandRed),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Ask IOHD',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: _ink, height: 1.2)),
                Text('Read-only. Answers come from your live data.',
                    style: TextStyle(fontSize: 12, color: _slate, height: 1.3)),
              ],
            ),
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

  Widget _emptyState() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(22, 36, 22, 16),
      children: [
        Center(
          child: Container(
            width: 52,
            height: 52,
            decoration: const BoxDecoration(color: _tint, shape: BoxShape.circle),
            child: const Icon(Icons.auto_awesome_rounded, size: 26, color: _brandRed),
          ),
        ),
        const SizedBox(height: 16),
        const Text('Ask about your business',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: _ink)),
        const SizedBox(height: 6),
        const Text(
          'Jobs, customers, revenue, estimates and inventory. It can look things up but cannot change anything.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: _slate, height: 1.45),
        ),
        const SizedBox(height: 24),
        for (final s in _suggestions)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: InkWell(
              onTap: () => _submit(s),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: _fill,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _stroke),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(s, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _ink)),
                    ),
                    const SizedBox(width: 8),
                    const Icon(Icons.arrow_forward_rounded, size: 16, color: _muted),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _thread() {
    final msgs = _chat.messages;
    final extra = (_chat.busy ? 1 : 0) + (_chat.error != null ? 1 : 0);
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      itemCount: msgs.length + extra,
      itemBuilder: (context, i) {
        if (i < msgs.length) return _Bubble(message: msgs[i]);
        if (_chat.busy) return const _Thinking();
        return _ErrorNote(message: _chat.error!, onRetry: _chat.retry);
      },
    );
  }

  Widget _composer() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: _stroke))),
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
                    maxLines: 5,
                    maxLength: _maxChars,
                    style: const TextStyle(fontSize: 13.5, color: _ink),
                    cursorColor: _brandRed,
                    decoration: InputDecoration(
                      hintText: 'Ask a question…',
                      hintStyle: const TextStyle(fontSize: 13.5, color: _muted),
                      counterText: '',
                      filled: true,
                      fillColor: _fill,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                      enabledBorder:
                          OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: _brandRed, width: 1.5),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ListenableBuilder(
                listenable: _chat,
                builder: (context, _) => IconButton.filled(
                  tooltip: 'Send',
                  onPressed: _chat.busy ? null : _submit,
                  icon: const Icon(Icons.arrow_upward_rounded, size: 20),
                  style: IconButton.styleFrom(
                    backgroundColor: _brandRed,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: _stroke,
                    fixedSize: const Size(44, 44),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Answers can be wrong. Check important figures. Enter to send, Shift+Enter for a new line.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: _muted),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final AssistantMessage message;
  const _Bubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == AssistantRole.user;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: isUser ? 340 : double.infinity),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: isUser ? _tint : Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: isUser ? null : Border.all(color: _stroke),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _AnswerText(text: message.text),
                if (message.sources.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Text('Checked', style: TextStyle(fontSize: 11, color: _muted)),
                      for (final s in message.sources)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(color: _fill, borderRadius: BorderRadius.circular(20)),
                          child: Text(s,
                              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _slate)),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

const TextStyle _bodyStyle = TextStyle(fontSize: 13.5, color: _ink, height: 1.45);

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

/// Renders the slice of markdown the assistant uses: **bold**, "- " bullets, ## headings and simple
/// pipe tables. Anything else shows as plain text.
class _AnswerText extends StatelessWidget {
  final String text;
  const _AnswerText({required this.text});

  static final _bullet = RegExp(r'^\s*[-*•]\s+');
  static final _heading = RegExp(r'^\s{0,3}#{1,4}\s+(.*)$');
  static final _dashCell = RegExp(r'^:?-{2,}:?$');

  static bool _isRow(String l) {
    final t = l.trim();
    return t.startsWith('|') && t.endsWith('|') && t.length > 2 && t.split('|').length >= 4;
  }

  static List<String> _cells(String l) {
    var t = l.trim();
    if (t.startsWith('|')) t = t.substring(1);
    if (t.endsWith('|')) t = t.substring(0, t.length - 1);
    return t.split('|').map((c) => c.trim()).toList();
  }

  @override
  Widget build(BuildContext context) {
    final lines = text.split('\n');
    final blocks = <Widget>[];
    var i = 0;
    while (i < lines.length) {
      final line = lines[i].trimRight();

      if (_isRow(line)) {
        final tableLines = <String>[];
        while (i < lines.length && _isRow(lines[i])) {
          tableLines.add(lines[i]);
          i++;
        }
        final rows = [for (final l in tableLines) _cells(l)]
            .where((r) => !r.every((c) => _dashCell.hasMatch(c))) // drop the |---|---| separator
            .toList();
        if (rows.length >= 2) {
          blocks.add(Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: _MdTable(rows: rows)));
        } else {
          for (final l in tableLines) {
            blocks.add(Text(l, style: _bodyStyle));
          }
        }
        continue;
      }

      i++;
      final heading = _heading.firstMatch(line);
      if (line.trim().isEmpty) {
        blocks.add(const SizedBox(height: 6));
      } else if (heading != null) {
        blocks.add(Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 2),
          child: Text.rich(TextSpan(
            style: _bodyStyle.copyWith(fontSize: 14.5, fontWeight: FontWeight.w800),
            children: _inlineSpans(heading.group(1)!, _bodyStyle.copyWith(fontSize: 14.5)),
          )),
        ));
      } else if (_bullet.hasMatch(line)) {
        blocks.add(Padding(
          padding: const EdgeInsets.only(left: 4, top: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('•  ', style: _bodyStyle),
              Expanded(
                child: Text.rich(TextSpan(style: _bodyStyle, children: _inlineSpans(line.replaceFirst(_bullet, ''), _bodyStyle))),
              ),
            ],
          ),
        ));
      } else {
        blocks.add(Text.rich(TextSpan(style: _bodyStyle, children: _inlineSpans(line, _bodyStyle))));
      }
    }
    return SelectionArea(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: blocks),
    );
  }
}

/// A markdown table: shaded header, thin row dividers, number columns right-aligned. Wide tables scroll sideways.
class _MdTable extends StatelessWidget {
  final List<List<String>> rows; // first row is the header
  const _MdTable({required this.rows});

  static final _numeric = RegExp(r'^[\$\-+(]?\s?[\d,]*\.?\d+\s?[%)kKmM]?$');

  @override
  Widget build(BuildContext context) {
    final cols = rows.first.length;
    List<String> fit(List<String> r) =>
        [for (var c = 0; c < cols; c++) c < r.length ? r[c].replaceAll('**', '') : ''];

    final header = fit(rows.first);
    final body = [for (final r in rows.skip(1)) fit(r)];

    // A column is a number column when every non-empty body cell looks like a number or amount.
    final right = [
      for (var c = 0; c < cols; c++)
        body.every((r) => r[c].isEmpty || _numeric.hasMatch(r[c])) && body.any((r) => r[c].isNotEmpty),
    ];

    Widget cell(String t, int c, {bool head = false}) => ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Text(
              t,
              textAlign: right[c] ? TextAlign.right : TextAlign.left,
              style: TextStyle(
                fontSize: head ? 11.5 : 12.5,
                fontWeight: head ? FontWeight.w800 : FontWeight.w500,
                color: head ? _slate : _ink,
                height: 1.3,
                fontFeatures: right[c] ? const [FontFeature.tabularFigures()] : null,
              ),
            ),
          ),
        );

    return Container(
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: _stroke)),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          border: const TableBorder(horizontalInside: BorderSide(color: _stroke)),
          children: [
            TableRow(
              decoration: const BoxDecoration(color: _fill),
              children: [for (var c = 0; c < cols; c++) cell(header[c], c, head: true)],
            ),
            for (final r in body) TableRow(children: [for (var c = 0; c < cols; c++) cell(r[c], c)]),
          ],
        ),
      ),
    );
  }
}

class _Thinking extends StatelessWidget {
  const _Thinking();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(bottom: 12, left: 2),
      child: Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: _brandRed),
          ),
          SizedBox(width: 10),
          Text('Looking that up…', style: TextStyle(fontSize: 13, color: _slate)),
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
