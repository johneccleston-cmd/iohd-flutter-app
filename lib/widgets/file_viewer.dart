import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/auth_session.dart';
import 'dashboard_kit.dart' show DashUi;

/// One file the viewer can show.
class ViewerFile {
  final String name;

  /// Direct link a picture can be drawn from (a signed bucket link, or Service Fusion's public one).
  final String? previewUrl;

  /// Backend link that streams the file for signed-in users (our uploads). Used for Download and for PDF / text
  /// previews, so they work in the browser build too. Null for Service Fusion's own files.
  final String? contentUrl;

  /// "2.3 MB  ·  Uploaded by Dana  ·  Oct 12, 2026", shown under the name.
  final String meta;

  const ViewerFile({required this.name, this.previewUrl, this.contentUrl, this.meta = ''});

  String get ext {
    final i = name.lastIndexOf('.');
    return i < 0 ? '' : name.substring(i + 1).toLowerCase();
  }

  bool get isPicture => const {'jpg', 'jpeg', 'png', 'webp', 'gif', 'heic', 'heif', 'bmp'}.contains(ext);
  bool get isPdf => ext == 'pdf';
  bool get isText => ext == 'txt' || ext == 'csv';
  String get mime => isPdf
      ? 'application/pdf'
      : isText
          ? (ext == 'csv' ? 'text/csv' : 'text/plain')
          : isPicture
              ? 'image/${ext == 'jpg' ? 'jpeg' : ext}'
              : 'application/octet-stream';
}

/// Opens the viewer over the current page. [index] is the file to show first; with more than one file there are
/// Previous / Next arrows (and the left / right keys) and a filmstrip of all of them along the bottom.
Future<void> showFileViewer(BuildContext context, List<ViewerFile> files, int index) {
  return showDialog<void>(
    context: context,
    barrierColor: DashUi.ink.withValues(alpha: 0.82),
    builder: (_) => _FileViewer(files: files, index: index.clamp(0, files.length - 1)),
  );
}

class _FileViewer extends StatefulWidget {
  final List<ViewerFile> files;
  final int index;
  const _FileViewer({required this.files, required this.index});

  @override
  State<_FileViewer> createState() => _FileViewerState();
}

class _FileViewerState extends State<_FileViewer> with SingleTickerProviderStateMixin {
  late int _i = widget.index;
  bool _downloading = false;
  final Map<int, Future<Uint8List>> _bytes = {}; // per file, so flipping back and forth doesn't refetch

  // Zoom on a picture: the viewer's transform, animated when it is changed by a button, a key or a double-click.
  final _zoom = TransformationController();
  late final AnimationController _zoomAnim = AnimationController(vsync: this, duration: const Duration(milliseconds: 240));
  Animation<Matrix4>? _zoomTween;
  Size _stage = Size.zero;
  Offset? _doubleTapAt;
  final _strip = ScrollController();

  static const _minScale = 1.0;
  static const _maxScale = 6.0;

  ViewerFile get _f => widget.files[_i];
  double get _scale => _zoom.value.getMaxScaleOnAxis();

  @override
  void initState() {
    super.initState();
    _zoom.addListener(() => setState(() {}));
    _zoomAnim.addListener(() {
      final t = _zoomTween;
      if (t != null) _zoom.value = t.value;
    });
  }

  @override
  void dispose() {
    _zoomAnim.dispose();
    _zoom.dispose();
    _strip.dispose();
    super.dispose();
  }

  Future<Uint8List> _load(ViewerFile f) async {
    final authed = f.contentUrl != null;
    final url = f.contentUrl ?? f.previewUrl;
    if (url == null) throw Exception('This file has no link.');
    final res = await http.get(Uri.parse(url), headers: authed ? AuthSession.instance.headers(json: false) : const {}).timeout(const Duration(seconds: 60));
    if (res.statusCode == 401) {
      AuthSession.instance.logout(); // sends the app back to the sign-in screen
      throw Exception('Your session expired. Please sign in again.');
    }
    if (res.statusCode != 200) throw Exception('Could not load the file (${res.statusCode}).');
    return res.bodyBytes;
  }

  Future<Uint8List> _bytesFor(int i) => _bytes.putIfAbsent(i, () => _load(widget.files[i]));

  void _say(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _download() async {
    if (_downloading) return;
    final f = _f;
    setState(() => _downloading = true);
    try {
      final bytes = await _bytesFor(_i);
      final saved = await FilePicker.saveFile(fileName: f.name, bytes: bytes, mimeType: f.mime, dialogTitle: 'Save ${f.name}');
      if (saved != null) _say('Saved ${f.name}.');
    } catch (_) {
      _bytes.remove(_i);
      final link = f.previewUrl;
      // Service Fusion's pictures live on another site the browser may not let us read; hand the link to the browser.
      if (f.contentUrl == null && link != null && await launchUrl(Uri.parse(link), mode: LaunchMode.externalApplication)) {
        _say('Opened in your browser: save it from there.');
      } else {
        _say('Could not download ${f.name}.');
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  void _go(int delta) => _show(_i + delta);

  void _show(int n) {
    if (n < 0 || n >= widget.files.length || n == _i) return;
    _zoomAnim.stop();
    _zoom.value = Matrix4.identity();
    setState(() => _i = n);
    // Keep the filmstrip's current picture in view.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_strip.hasClients) return;
      final target = (n * (_thumbW + _thumbGap)) - (_strip.position.viewportDimension - _thumbW) / 2;
      _strip.animateTo(
        target.clamp(0, _strip.position.maxScrollExtent),
        duration: MediaQuery.disableAnimationsOf(context) ? const Duration(milliseconds: 1) : const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    });
  }

  /// Moves the zoom to [target], animated unless reduced motion is on.
  void _zoomTo(Matrix4 target) {
    if (MediaQuery.disableAnimationsOf(context)) {
      _zoom.value = target;
      return;
    }
    _zoomTween = Matrix4Tween(begin: _zoom.value.clone(), end: target).animate(CurvedAnimation(parent: _zoomAnim, curve: Curves.easeOutCubic));
    _zoomAnim.forward(from: 0);
  }

  /// Zooms by [factor] around [focus] (the middle of the picture when not given), kept between 1x and 6x.
  void _zoomBy(double factor, [Offset? focus]) {
    final c = focus ?? _stage.center(Offset.zero);
    final next = (_scale * factor).clamp(_minScale, _maxScale);
    final f = next / _scale;
    if ((f - 1).abs() < 0.001) return;
    final m = Matrix4.identity()
      ..translateByDouble(c.dx, c.dy, 0, 1)
      ..scaleByDouble(f, f, 1, 1)
      ..translateByDouble(-c.dx, -c.dy, 0, 1);
    _zoomTo(next <= _minScale + 0.001 ? Matrix4.identity() : m.multiplied(_zoom.value));
  }

  void _resetZoom() => _zoomTo(Matrix4.identity());

  static const double _thumbW = 72;
  static const double _thumbGap = 8;

  @override
  Widget build(BuildContext context) {
    final f = _f;
    final many = widget.files.length > 1;
    final still = MediaQuery.disableAnimationsOf(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _go(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _go(1),
        if (f.isPicture) ...{
          const SingleActivator(LogicalKeyboardKey.equal): () => _zoomBy(1.5),
          const SingleActivator(LogicalKeyboardKey.add): () => _zoomBy(1.5),
          const SingleActivator(LogicalKeyboardKey.numpadAdd): () => _zoomBy(1.5),
          const SingleActivator(LogicalKeyboardKey.minus): () => _zoomBy(1 / 1.5),
          const SingleActivator(LogicalKeyboardKey.numpadSubtract): () => _zoomBy(1 / 1.5),
          const SingleActivator(LogicalKeyboardKey.digit0): _resetZoom,
        },
      },
      child: Focus(
        autofocus: true,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: still ? 1 : 0.96, end: 1),
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          builder: (context, k, child) => Transform.scale(scale: k, child: child),
          child: Dialog(
            backgroundColor: DashUi.ink,
            insetPadding: const EdgeInsets.all(20),
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
            child: SizedBox.expand(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _header(f, many),
                  Expanded(
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: AnimatedSwitcher(
                            duration: still ? Duration.zero : const Duration(milliseconds: 220),
                            switchInCurve: Curves.easeOutCubic,
                            transitionBuilder: (child, a) => FadeTransition(
                              opacity: a,
                              child: ScaleTransition(scale: Tween(begin: 0.985, end: 1.0).animate(a), child: child),
                            ),
                            child: KeyedSubtree(key: ValueKey('file-$_i'), child: _body(f)),
                          ),
                        ),
                        if (many && _i > 0)
                          Positioned(left: 16, top: 0, bottom: 0, child: Center(child: _NavArrow(icon: Icons.chevron_left_rounded, tip: 'Previous', onTap: () => _go(-1)))),
                        if (many && _i < widget.files.length - 1)
                          Positioned(right: 16, top: 0, bottom: 0, child: Center(child: _NavArrow(icon: Icons.chevron_right_rounded, tip: 'Next', onTap: () => _go(1)))),
                        if (f.isPicture && f.previewUrl != null)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 14,
                            child: IgnorePointer(
                              child: Center(
                                child: AnimatedOpacity(
                                  opacity: _scale <= 1.01 ? 1 : 0,
                                  duration: still ? Duration.zero : const Duration(milliseconds: 200),
                                  child: _glassChip(Icons.zoom_in_rounded, 'Double-click or scroll to zoom'),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (many) _filmstrip(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The bar along the top: what the file is, where it is in the set, zoom (pictures), Download and Close.
  Widget _header(ViewerFile f, bool many) {
    final (badge, tone) = _badgeFor(f);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
      decoration: BoxDecoration(
        color: DashUi.ink,
        border: Border(bottom: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: tone.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(10)),
            child: f.isPicture
                ? Icon(Icons.image_rounded, size: 20, color: Color.lerp(tone, Colors.white, 0.45))
                : Text(badge, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: Color.lerp(tone, Colors.white, 0.45), letterSpacing: 0.4)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: Colors.white)),
                if (f.meta.isNotEmpty)
                  Text(f.meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: Colors.white.withValues(alpha: 0.66))),
              ],
            ),
          ),
          if (many) ...[
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(999)),
              child: Text(
                '${_i + 1} of ${widget.files.length}',
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Colors.white, fontFeatures: [FontFeature.tabularFigures()]),
              ),
            ),
          ],
          if (f.isPicture && f.previewUrl != null) ...[
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(10)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _barIcon(Icons.remove_rounded, 'Zoom out (-)', _scale > _minScale + 0.01 ? () => _zoomBy(1 / 1.5) : null),
                  SizedBox(
                    width: 46,
                    child: Text(
                      '${(_scale * 100).round()}%',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Colors.white, fontFeatures: [FontFeature.tabularFigures()]),
                    ),
                  ),
                  _barIcon(Icons.add_rounded, 'Zoom in (+)', _scale < _maxScale - 0.01 ? () => _zoomBy(1.5) : null),
                  _barIcon(Icons.fit_screen_rounded, 'Fit to window (0)', _scale > 1.01 ? _resetZoom : null),
                ],
              ),
            ),
          ],
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: _downloading ? null : _download,
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: DashUi.ink,
              disabledBackgroundColor: Colors.white.withValues(alpha: 0.6),
              minimumSize: const Size(0, 38),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: _downloading
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: DashUi.ink))
                : const Icon(Icons.download_rounded, size: 18),
            label: const Text('Download', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 6),
          _barIcon(Icons.close_rounded, 'Close', () => Navigator.of(context).pop(), size: 22),
        ],
      ),
    );
  }

  Widget _barIcon(IconData icon, String tip, VoidCallback? onTap, {double size = 19}) => IconButton(
    tooltip: tip,
    onPressed: onTap,
    iconSize: size,
    color: Colors.white,
    disabledColor: Colors.white.withValues(alpha: 0.3),
    hoverColor: Colors.white.withValues(alpha: 0.12),
    icon: Icon(icon),
  );

  Widget _glassChip(IconData icon, String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(color: DashUi.ink.withValues(alpha: 0.72), borderRadius: BorderRadius.circular(999), border: Border.all(color: Colors.white.withValues(alpha: 0.12))),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: Colors.white.withValues(alpha: 0.85)),
        const SizedBox(width: 6),
        Text(text, style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.85))),
      ],
    ),
  );

  /// A short type label and its tint, for the header badge and the filmstrip.
  static (String, Color) _badgeFor(ViewerFile f) {
    if (f.isPicture) return ('IMG', DashUi.sky);
    return switch (f.ext) {
      'pdf' => ('PDF', DashUi.red),
      'doc' || 'docx' || 'rtf' => ('DOC', DashUi.blue),
      'xls' || 'xlsx' || 'csv' => (f.ext == 'csv' ? 'CSV' : 'XLS', DashUi.emerald),
      'ppt' || 'pptx' => ('PPT', DashUi.amber),
      'dwg' || 'dxf' => (f.ext.toUpperCase(), DashUi.indigo),
      'txt' => ('TXT', DashUi.muted),
      '' => ('FILE', DashUi.muted),
      _ => (f.ext.length > 4 ? f.ext.substring(0, 4).toUpperCase() : f.ext.toUpperCase(), DashUi.muted),
    };
  }

  /// Every file in the set along the bottom: the open one ringed in white, the rest dimmed until hovered.
  Widget _filmstrip() {
    return Container(
      height: 76,
      decoration: BoxDecoration(
        color: DashUi.ink,
        border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
      ),
      child: Center(
        child: ListView.separated(
          controller: _strip,
          shrinkWrap: true,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          itemCount: widget.files.length,
          separatorBuilder: (_, _) => const SizedBox(width: _thumbGap),
          itemBuilder: (context, i) => _Thumb(
            file: widget.files[i],
            selected: i == _i,
            width: _thumbW,
            badge: _badgeFor(widget.files[i]),
            onTap: () => _show(i),
          ),
        ),
      ),
    );
  }

  Widget _message(IconData icon, String title, String hint, {bool dark = true}) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 440),
        padding: const EdgeInsets.fromLTRB(28, 28, 28, 24),
        decoration: BoxDecoration(
          color: dark ? Colors.white.withValues(alpha: 0.06) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: dark ? Colors.white.withValues(alpha: 0.10) : DashUi.line),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(shape: BoxShape.circle, color: (dark ? Colors.white : DashUi.blue).withValues(alpha: 0.1)),
              child: Icon(icon, size: 28, color: dark ? Colors.white.withValues(alpha: 0.85) : DashUi.blue),
            ),
            const SizedBox(height: 14),
            Text(title, textAlign: TextAlign.center, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: dark ? Colors.white : DashUi.ink)),
            const SizedBox(height: 6),
            Text(hint, textAlign: TextAlign.center, style: TextStyle(fontSize: 13.5, height: 1.45, color: dark ? Colors.white.withValues(alpha: 0.7) : DashUi.slate)),
          ],
        ),
      ),
    ),
  );

  Widget _spinner({bool dark = true}) =>
      Center(child: SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5, color: dark ? Colors.white : DashUi.ink)));

  Widget _body(ViewerFile f) {
    if (f.isPicture) {
      final url = f.previewUrl;
      if (url == null) return _message(Icons.image_not_supported_outlined, 'No picture to show', 'Use Download to save it.');
      return LayoutBuilder(
        builder: (context, c) {
          _stage = c.biggest;
          return DecoratedBox(
            // A soft light behind the picture, darker toward the edges.
            decoration: BoxDecoration(
              gradient: RadialGradient(
                radius: 0.9,
                colors: [Color.lerp(DashUi.ink, DashUi.slate, 0.35)!, DashUi.ink],
              ),
            ),
            child: GestureDetector(
              onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
              onDoubleTap: () => _scale > 1.01 ? _resetZoom() : _zoomBy(2.5, _doubleTapAt),
              child: InteractiveViewer(
                transformationController: _zoom,
                minScale: _minScale,
                maxScale: _maxScale,
                child: SizedBox.expand(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Image.network(
                      url,
                      key: ValueKey(url),
                      fit: BoxFit.contain,
                      // The bucket sends no CORS header, so on the web build this falls back to a plain <img>.
                      webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
                      loadingBuilder: (_, child, progress) => progress == null ? child : _spinner(),
                      frameBuilder: (_, child, frame, sync) => sync
                          ? child
                          : AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: const Duration(milliseconds: 220), child: child),
                      errorBuilder: (_, _, _) => _message(
                        Icons.broken_image_outlined,
                        'This picture cannot be shown here',
                        f.ext == 'heic' || f.ext == 'heif' ? 'HEIC pictures need a viewer that supports them. Use Download.' : 'Use Download to save it.',
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
    }
    if (f.isPdf || f.isText) {
      return ColoredBox(
        color: DashUi.faint,
        child: FutureBuilder<Uint8List>(
          key: ValueKey('${f.name}-$_i'),
          future: _bytesFor(_i),
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) return _spinner(dark: false);
            if (snap.hasError || snap.data == null) {
              return _message(Icons.error_outline_rounded, 'Could not load this file', snap.error.toString().replaceFirst('Exception: ', ''), dark: false);
            }
            final bytes = snap.data!;
            if (f.isPdf) {
              return PdfPreview(
                build: (_) async => bytes,
                useActions: false,
                canChangePageFormat: false,
                canChangeOrientation: false,
                canDebug: false,
                allowPrinting: false,
                allowSharing: false,
                scrollViewDecoration: const BoxDecoration(color: DashUi.faint),
                onError: (_, _) => _message(Icons.picture_as_pdf_outlined, 'This PDF cannot be shown here', 'Use Download to open it in your PDF viewer.', dark: false),
              );
            }
            final cut = bytes.length > 300 * 1024;
            final text = utf8.decode(cut ? bytes.sublist(0, 300 * 1024) : bytes, allowMalformed: true);
            // The text on a white page, like a sheet of paper on the desk.
            return Scrollbar(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
                child: Center(
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 900),
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(36, 32, 36, 36),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: DashUi.line),
                      boxShadow: [BoxShadow(color: DashUi.ink.withValues(alpha: 0.06), blurRadius: 18, offset: const Offset(0, 6))],
                    ),
                    child: SelectableText(
                      cut ? '$text\n\n… (showing the first 300 KB, use Download for the rest)' : text,
                      style: const TextStyle(fontSize: 13.5, height: 1.55, fontFamily: 'Consolas', fontFamilyFallback: ['Menlo', 'Courier New', 'monospace'], color: DashUi.ink),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      );
    }
    return _message(Icons.insert_drive_file_outlined, 'No preview for .${f.ext.isEmpty ? 'this' : f.ext} files', 'Use Download to open it in the program that made it.');
  }
}

/// Previous / Next: a large round glass button that brightens under the pointer.
class _NavArrow extends StatefulWidget {
  final IconData icon;
  final String tip;
  final VoidCallback onTap;
  const _NavArrow({required this.icon, required this.tip, required this.onTap});

  @override
  State<_NavArrow> createState() => _NavArrowState();
}

class _NavArrowState extends State<_NavArrow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final d = MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 160);
    return Tooltip(
      message: widget.tip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedScale(
            duration: d,
            scale: _hover ? 1.08 : 1,
            child: AnimatedContainer(
              duration: d,
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _hover ? Colors.white.withValues(alpha: 0.22) : DashUi.ink.withValues(alpha: 0.55),
                border: Border.all(color: Colors.white.withValues(alpha: _hover ? 0.4 : 0.16)),
              ),
              child: Icon(widget.icon, size: 30, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}

/// One file in the filmstrip: the picture itself, or its type label for a document.
class _Thumb extends StatefulWidget {
  final ViewerFile file;
  final bool selected;
  final double width;
  final (String, Color) badge;
  final VoidCallback onTap;
  const _Thumb({required this.file, required this.selected, required this.width, required this.badge, required this.onTap});

  @override
  State<_Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<_Thumb> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final f = widget.file;
    final (label, tone) = widget.badge;
    final d = MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 160);
    final placeholder = Container(
      color: tone.withValues(alpha: 0.18),
      alignment: Alignment.center,
      child: f.isPicture
          ? Icon(Icons.image_rounded, size: 20, color: Colors.white.withValues(alpha: 0.7))
          : Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Color.lerp(tone, Colors.white, 0.45))),
    );
    return Tooltip(
      message: f.name,
      waitDuration: const Duration(milliseconds: 400),
      child: Semantics(
        button: true,
        selected: widget.selected,
        label: f.name,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            onTap: widget.onTap,
            child: AnimatedOpacity(
              duration: d,
              opacity: widget.selected ? 1 : (_hover ? 0.85 : 0.5),
              child: AnimatedContainer(
                duration: d,
                width: widget.width,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: widget.selected ? Colors.white : Colors.white.withValues(alpha: 0.14), width: widget.selected ? 2 : 1),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(7),
                  child: f.isPicture && f.previewUrl != null
                      ? Image.network(
                          f.previewUrl!,
                          fit: BoxFit.cover,
                          webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
                          errorBuilder: (_, _, _) => placeholder,
                          loadingBuilder: (_, child, p) => p == null ? child : placeholder,
                        )
                      : placeholder,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
