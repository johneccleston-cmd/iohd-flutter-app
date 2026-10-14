import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/auth_session.dart';
import '../theme/app_theme.dart';

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

/// Opens the viewer in a dialog over the current page. [index] is the file to show first; with more than one file
/// there are Previous / Next arrows (and the left / right keys).
Future<void> showFileViewer(BuildContext context, List<ViewerFile> files, int index) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black87,
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

class _FileViewerState extends State<_FileViewer> {
  late int _i = widget.index;
  bool _downloading = false;
  final Map<int, Future<Uint8List>> _bytes = {}; // per file, so flipping back and forth doesn't refetch

  ViewerFile get _f => widget.files[_i];

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

  void _go(int delta) {
    final n = _i + delta;
    if (n < 0 || n >= widget.files.length) return;
    setState(() => _i = n);
  }

  @override
  Widget build(BuildContext context) {
    final f = _f;
    final many = widget.files.length > 1;
    final size = MediaQuery.sizeOf(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _go(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _go(1),
      },
      child: Focus(
        autofocus: true,
        child: Dialog(
          backgroundColor: AppTheme.surfaceColor,
          insetPadding: const EdgeInsets.all(20),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              // Header: name, position, Download, Close
              Container(
                color: const Color(0xFFF3F4F6),
                padding: const EdgeInsets.fromLTRB(18, 8, 8, 8),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppTheme.primaryText)),
                      Text([if (many) '${_i + 1} of ${widget.files.length}', f.meta].where((e) => e.isNotEmpty).join('  ·  '),
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, color: AppTheme.secondaryText)),
                    ]),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: _downloading ? null : _download,
                    icon: _downloading
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.download_rounded, size: 18),
                    label: const Text('Download'),
                  ),
                  const SizedBox(width: 4),
                  IconButton(tooltip: 'Close', icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.of(context).pop()),
                ]),
              ),
              const Divider(height: 1, color: AppTheme.strokeBorder),
              Expanded(
                child: Stack(children: [
                  Positioned.fill(child: _body(f)),
                  if (many && _i > 0) Positioned(left: 8, top: 0, bottom: 0, child: Center(child: _arrow(Icons.chevron_left_rounded, 'Previous', () => _go(-1)))),
                  if (many && _i < widget.files.length - 1) Positioned(right: 8, top: 0, bottom: 0, child: Center(child: _arrow(Icons.chevron_right_rounded, 'Next', () => _go(1)))),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _arrow(IconData icon, String tip, VoidCallback onTap) => Material(
        color: Colors.black54,
        shape: const CircleBorder(),
        child: IconButton(tooltip: tip, icon: Icon(icon, color: Colors.white, size: 30), onPressed: onTap),
      );

  Widget _message(IconData icon, String title, String hint) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 48, color: AppTheme.sectionLabel),
            const SizedBox(height: 12),
            Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.secondaryText)),
            const SizedBox(height: 6),
            Text(hint, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13.5, color: AppTheme.sectionLabel)),
          ]),
        ),
      );

  Widget _body(ViewerFile f) {
    if (f.isPicture) {
      final url = f.previewUrl;
      if (url == null) return _message(Icons.image_not_supported_outlined, 'No picture to show', 'Use Download to save it.');
      return Container(
        color: const Color(0xFF111827),
        child: InteractiveViewer(
          maxScale: 6,
          child: Center(
            child: Image.network(
              url,
              key: ValueKey(url),
              fit: BoxFit.contain,
              // The bucket sends no CORS header, so on the web build this falls back to a plain <img>.
              webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
              loadingBuilder: (_, child, progress) => progress == null ? child : const Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
              errorBuilder: (_, _, _) => Container(
                color: AppTheme.surfaceColor,
                child: _message(Icons.broken_image_outlined, 'This picture cannot be shown here', f.ext == 'heic' || f.ext == 'heif' ? 'HEIC pictures need a viewer that supports them. Use Download.' : 'Use Download to save it.'),
              ),
            ),
          ),
        ),
      );
    }
    if (f.isPdf || f.isText) {
      return FutureBuilder<Uint8List>(
        key: ValueKey('${f.name}-$_i'),
        future: _bytesFor(_i),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
          if (snap.hasError || snap.data == null) {
            return _message(Icons.error_outline_rounded, 'Could not load this file', snap.error.toString().replaceFirst('Exception: ', ''));
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
              scrollViewDecoration: const BoxDecoration(color: Color(0xFFE5E7EB)),
              onError: (_, _) => _message(Icons.picture_as_pdf_outlined, 'This PDF cannot be shown here', 'Use Download to open it in your PDF viewer.'),
            );
          }
          final cut = bytes.length > 300 * 1024;
          final text = utf8.decode(cut ? bytes.sublist(0, 300 * 1024) : bytes, allowMalformed: true);
          return Scrollbar(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: SelectableText(
                cut ? '$text\n\n… (showing the first 300 KB, use Download for the rest)' : text,
                style: const TextStyle(fontSize: 13, height: 1.45, fontFamily: 'Consolas', fontFamilyFallback: ['Menlo', 'Courier New', 'monospace'], color: AppTheme.primaryText),
              ),
            ),
          );
        },
      );
    }
    return _message(Icons.insert_drive_file_outlined, 'No preview for .${f.ext.isEmpty ? 'this' : f.ext} files', 'Use Download to open it in the program that made it.');
  }
}
