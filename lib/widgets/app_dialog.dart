import 'package:flutter/material.dart';

import 'dashboard_kit.dart';

// One look for every pop-up in the app: white card, soft corners, bold tight title, ink buttons,
// pill selectors and quiet filled fields. It matches the Team screen's dialogs and the dashboards.
//
//   showDialog(context: context, builder: (ctx) => AppDialog(
//     title: 'Unlock this job?',
//     icon: Icons.lock_open_rounded,
//     body: ...,
//     actions: [AppButton.ghost('Cancel', () => Navigator.pop(ctx)), AppButton.ink('Unlock', () => ...)],
//   ));

class AppDialog extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData? icon;
  final Color iconColor;
  final Widget body;
  final List<Widget> actions;
  final double width;

  const AppDialog({
    super.key,
    required this.title,
    required this.body,
    required this.actions,
    this.subtitle,
    this.icon,
    this.iconColor = DashUi.ink,
    this.width = 460,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shadowColor: Colors.black.withValues(alpha: 0.18),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: DashUi.line),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (icon != null) ...[
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: iconColor.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: Icon(icon, size: 20, color: iconColor),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(top: subtitle == null && icon != null ? 8 : 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              color: DashUi.ink,
                              letterSpacing: -0.3,
                              height: 1.2,
                            ),
                          ),
                          if (subtitle != null) ...[
                            const SizedBox(height: 3),
                            Text(subtitle!, style: const TextStyle(fontSize: 13, color: DashUi.slate, height: 1.3)),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Close',
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints.tightFor(width: 32, height: 32),
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.close_rounded, size: 19, color: DashUi.muted),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Flexible(child: SingleChildScrollView(child: body)),
              const SizedBox(height: 20),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: actions,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AppButton {
  AppButton._();

  static Widget ink(String label, VoidCallback? onPressed, {IconData? icon, bool danger = false}) {
    final style = FilledButton.styleFrom(
      backgroundColor: danger ? const Color(0xFFB91C1C) : DashUi.ink,
      disabledBackgroundColor: DashUi.line,
      foregroundColor: Colors.white,
      disabledForegroundColor: DashUi.muted,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    );
    final text = Text(label, style: const TextStyle(fontWeight: FontWeight.w700));
    return icon == null
        ? FilledButton(onPressed: onPressed, style: style, child: text)
        : FilledButton.icon(onPressed: onPressed, style: style, icon: Icon(icon, size: 18), label: text);
  }

  static Widget ghost(String label, VoidCallback? onPressed) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: DashUi.slate,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
    );
  }
}

/// Quiet filled field, dark focus ring.
InputDecoration appFieldDecoration({String? hint, String? label, String? helper, String? error, String? prefixText}) {
  OutlineInputBorder border(Color c, [double w = 1]) =>
      OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: c, width: w));
  return InputDecoration(
    isDense: true,
    filled: true,
    fillColor: const Color(0xFFF8FAFC),
    hintText: hint,
    labelText: label,
    helperText: helper,
    helperMaxLines: 2,
    errorText: error,
    errorMaxLines: 3,
    prefixText: prefixText,
    hintStyle: const TextStyle(fontSize: 14, color: DashUi.muted, fontWeight: FontWeight.w500),
    helperStyle: const TextStyle(fontSize: 12, color: DashUi.slate),
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
    border: border(DashUi.line),
    enabledBorder: border(DashUi.line),
    focusedBorder: border(DashUi.ink),
    errorBorder: border(const Color(0xFFDC2626)),
    focusedErrorBorder: border(const Color(0xFFDC2626), 1.5),
  );
}

/// Label with an optional one-line explanation underneath.
class AppFieldLabel extends StatelessWidget {
  final String label;
  final String? help;
  const AppFieldLabel(this.label, {super.key, this.help});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: DashUi.ink)),
          if (help != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(help!, style: const TextStyle(fontSize: 12, color: DashUi.slate, height: 1.35)),
            ),
        ],
      ),
    );
  }
}

/// Pill selector, same as the toggles on the dashboards.
class AppSegmented<V> extends StatelessWidget {
  final V value;
  final List<(V, String)> options;
  final ValueChanged<V> onChanged;
  final Color activeColor;

  const AppSegmented({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.activeColor = DashUi.ink,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(10)),
      child: Row(
        children: [
          for (final o in options)
            Expanded(
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onChanged(o.$1),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: o.$1 == value ? Colors.white : Colors.white.withValues(alpha: 0),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: o.$1 == value ? DashUi.line : DashUi.line.withValues(alpha: 0)),
                    ),
                    child: Text(
                      o.$2,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: o.$1 == value ? FontWeight.w800 : FontWeight.w600,
                        color: o.$1 == value ? activeColor : DashUi.slate,
                      ),
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

enum AppNoticeKind { info, warning, error, success }

/// Small banner for hints, cautions and errors.
class AppNotice extends StatelessWidget {
  final String text;
  final AppNoticeKind kind;
  const AppNotice(this.text, {super.key, this.kind = AppNoticeKind.info});

  @override
  Widget build(BuildContext context) {
    final (IconData icon, Color fg, Color bg, Color border) = switch (kind) {
      AppNoticeKind.info => (Icons.info_outline_rounded, DashUi.slate, const Color(0xFFF8FAFC), DashUi.line),
      AppNoticeKind.warning => (Icons.warning_amber_rounded, const Color(0xFF92400E), const Color(0xFFFFFBEB), const Color(0xFFFDE68A)),
      AppNoticeKind.error => (Icons.error_outline_rounded, const Color(0xFFB91C1C), const Color(0xFFFEF2F2), const Color(0xFFFECACA)),
      AppNoticeKind.success => (Icons.check_circle_outline_rounded, const Color(0xFF047857), const Color(0xFFECFDF5), const Color(0xFFA7F3D0)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 16, color: fg)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(fontSize: 12.5, color: fg, fontWeight: FontWeight.w600, height: 1.4)),
          ),
        ],
      ),
    );
  }
}

/// Small rounded tag, e.g. "Verified" or "Weight 1.5".
class AppTag extends StatelessWidget {
  final String text;
  final Color color;
  const AppTag(this.text, {super.key, this.color = DashUi.slate});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.09), borderRadius: BorderRadius.circular(20)),
      child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color)),
    );
  }
}
