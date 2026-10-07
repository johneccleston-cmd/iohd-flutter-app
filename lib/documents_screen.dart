import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import 'config/api_config.dart';
import 'config/auth_session.dart';
import 'theme/app_theme.dart';
import 'widgets/app_components.dart';
import 'widgets/app_dialog.dart';

/// Browse and search the signed-in person's Google Drive (Shared Drives included).
///
/// The backend reads Drive as the signed-in person (matched by their app email), so they only see what
/// Google already lets them open. The Ask IOHD assistant reads Drive the same way.
class DocumentsScreen extends StatefulWidget {
  const DocumentsScreen({super.key});

  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

enum _Phase { loading, notConfigured, blocked, connected, error }

class _Crumb {
  final String? id; // null = top level (all drives)
  final String name;
  const _Crumb(this.id, this.name);
}

class _DocumentsScreenState extends State<DocumentsScreen> {
  _Phase _phase = _Phase.loading;
  String? _error;
  String? _email;

  final _search = TextEditingController();
  final List<_Crumb> _path = [const _Crumb(null, 'All drives')];
  String _query = '';
  List<Map<String, dynamic>> _items = [];
  String? _nextPage;
  bool _listLoading = false;
  bool _loadingMore = false;
  String? _listError;
  int _requestId = 0; // guards against out-of-order responses

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  // ---- api ----------------------------------------------------------------
  Future<Map<String, dynamic>> _get(String path, [Map<String, String>? query]) async {
    final uri = Uri.parse('$kApiBaseUrl$path').replace(queryParameters: query);
    final res = await http.get(uri, headers: AuthSession.instance.headers()).timeout(const Duration(seconds: 40));
    return _decode(res);
  }

  Map<String, dynamic> _decode(http.Response res) {
    if (res.statusCode == 401) {
      AuthSession.instance.logout(); // sends the app back to the sign-in screen
      throw Exception('Your session expired. Please sign in again.');
    }
    Map<String, dynamic> body = {};
    try {
      body = json.decode(res.body) as Map<String, dynamic>;
    } catch (_) {}
    if (res.statusCode == 503 && body['code'] == 'DRIVE_NOT_CONFIGURED') throw const _NotConfigured();
    if (res.statusCode == 409 && '${body['code']}'.startsWith('DRIVE_')) throw _Blocked(body['error'] as String? ?? 'Google Drive is not available for your account.');
    if (res.statusCode != 200) throw Exception(body['error'] ?? 'Server error (${res.statusCode})');
    return body;
  }

  Future<void> _loadStatus() async {
    setState(() {
      _phase = _Phase.loading;
      _error = null;
    });
    try {
      final s = await _get('/api/drive/status');
      if (!mounted) return;
      if (s['configured'] != true) {
        setState(() => _phase = _Phase.notConfigured);
      } else if (s['connected'] != true) {
        setState(() {
          _phase = _Phase.blocked;
          _error = s['message'] as String? ?? 'Google Drive is not available for your account.';
        });
      } else {
        setState(() {
          _phase = _Phase.connected;
          _email = s['email'] as String?;
        });
        _loadFiles();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _error = _message(e);
      });
    }
  }

  String _message(Object e) => e is TimeoutException
      ? 'The server took too long to answer. Try again.'
      : e.toString().replaceFirst('Exception: ', '');

  Future<void> _loadFiles({bool more = false}) async {
    final id = ++_requestId;
    if (more) {
      if (_nextPage == null) return;
      setState(() => _loadingMore = true);
    } else {
      setState(() {
        _listLoading = true;
        _listError = null;
        _nextPage = null;
      });
    }
    try {
      final folderId = _path.last.id;
      final body = await _get('/api/drive/files', {
        if (_query.isNotEmpty) 'q': _query else 'folderId': ?folderId,
        if (more) 'pageToken': ?_nextPage,
      });
      if (!mounted || id != _requestId) return;
      final rows = List<Map<String, dynamic>>.from(body['items'] ?? const []);
      setState(() {
        _items = more ? [..._items, ...rows] : rows;
        _nextPage = body['nextPageToken'] as String?;
        _listLoading = false;
        _loadingMore = false;
      });
    } on _Blocked catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.blocked;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _listLoading = false;
        _loadingMore = false;
        _listError = _message(e);
      });
    }
  }

  void _toast(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  // ---- navigation ---------------------------------------------------------
  void _open(Map<String, dynamic> item) {
    if (item['isFolder'] == true) {
      _search.clear();
      _query = '';
      _path.add(_Crumb(item['id'] as String, item['name'] as String));
      _loadFiles();
    } else {
      final link = item['webViewLink'] as String?;
      if (link == null) {
        _toast('This file has no link to open.');
      } else {
        launchUrl(Uri.parse(link), mode: LaunchMode.externalApplication);
      }
    }
  }

  void _goTo(int index) {
    _path.removeRange(index + 1, _path.length);
    _search.clear();
    _query = '';
    _loadFiles();
  }

  void _runSearch() {
    final q = _search.text.trim();
    if (q == _query) return;
    _query = q;
    _loadFiles();
  }

  // ---- ui -----------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgColor,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1000),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
            child: switch (_phase) {
              _Phase.loading => const Center(child: CircularProgressIndicator()),
              _Phase.error => _message_(Icons.cloud_off_rounded, 'Could not load Documents', _error ?? '', 'Retry', _loadStatus),
              _Phase.notConfigured => _message_(Icons.settings_suggest_rounded, 'Google Drive is not set up yet',
                  'The server needs its Google service account key before Documents can open. Ask whoever manages the backend.', 'Check again', _loadStatus),
              _Phase.blocked => _message_(Icons.lock_outline_rounded, 'Drive is not available for your account', _error ?? '', 'Try again', _loadStatus),
              _Phase.connected => _browser(),
            },
          ),
        ),
      ),
    );
  }

  Widget _message_(IconData icon, String title, String body, String action, VoidCallback onTap) {
    return Center(
      child: AppCard(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 40, color: AppTheme.secondaryText),
            const SizedBox(height: 12),
            Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: AppTheme.primaryText)),
            const SizedBox(height: 6),
            Text(body, textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.secondaryText)),
            const SizedBox(height: 18),
            FilledButton(onPressed: onTap, child: Text(action)),
          ]),
        ),
      ),
    );
  }

  Widget _browser() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Text('Documents', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: AppTheme.primaryText)),
        const Spacer(),
        if (_email != null) Flexible(child: Text(_email!, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppTheme.secondaryText))),
      ]),
      const SizedBox(height: 12),
      TextField(
        controller: _search,
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => _runSearch(),
        decoration: appFieldDecoration(hint: 'Search file names and contents (press Enter)').copyWith(
          prefixIcon: const Icon(Icons.search_rounded),
          suffixIcon: _search.text.isEmpty && _query.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear search',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () {
                    _search.clear();
                    _runSearch();
                    setState(() {});
                  },
                ),
        ),
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: 10),
      if (_query.isEmpty)
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
          for (var i = 0; i < _path.length; i++) ...[
            if (i > 0) const Icon(Icons.chevron_right_rounded, size: 18, color: AppTheme.sectionLabel),
            TextButton(
              onPressed: i == _path.length - 1 ? null : () => _goTo(i),
              child: Text(_path[i].name),
            ),
          ],
        ])
      else
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text('Results for "$_query", newest first', style: const TextStyle(color: AppTheme.secondaryText)),
        ),
      Expanded(child: _list()),
    ]);
  }

  Widget _list() {
    if (_listLoading) return const Center(child: CircularProgressIndicator());
    if (_listError != null) {
      return _message_(Icons.error_outline_rounded, 'Could not load files', _listError!, 'Retry', _loadFiles);
    }
    if (_items.isEmpty) {
      return Center(
        child: Text(
          _query.isNotEmpty ? 'Nothing matched "$_query".' : 'This folder is empty.',
          style: const TextStyle(color: AppTheme.secondaryText),
        ),
      );
    }
    return AppCard(
      padding: EdgeInsets.zero,
      child: ListView.separated(
        itemCount: _items.length + (_nextPage != null ? 1 : 0),
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) {
          if (i == _items.length) {
            return Padding(
              padding: const EdgeInsets.all(12),
              child: Center(
                child: _loadingMore
                    ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : TextButton(onPressed: () => _loadFiles(more: true), child: const Text('Load more')),
              ),
            );
          }
          final item = _items[i];
          final isFolder = item['isFolder'] == true;
          final modified = DateTime.tryParse('${item['modifiedTime'] ?? ''}')?.toLocal();
          final owner = item['owner'] as String?;
          return ListTile(
            leading: Icon(_iconFor(item), color: isFolder ? AppTheme.notesHeader : AppTheme.secondaryText),
            title: Text('${item['name']}', maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: modified == null && owner == null
                ? null
                : Text([if (modified != null) 'Edited ${DateFormat.yMMMd().format(modified)}', ?owner].join(' · ')),
            trailing: isFolder ? const Icon(Icons.chevron_right_rounded) : const Icon(Icons.open_in_new_rounded, size: 18),
            onTap: () => _open(item),
          );
        },
      ),
    );
  }

  IconData _iconFor(Map<String, dynamic> item) {
    if (item['isFolder'] == true) return item['isDrive'] == true ? Icons.folder_shared_rounded : Icons.folder_rounded;
    final type = '${item['mimeType']}';
    if (type.contains('pdf')) return Icons.picture_as_pdf_rounded;
    if (type.contains('spreadsheet') || type.contains('excel') || type.contains('csv')) return Icons.table_chart_rounded;
    if (type.contains('presentation') || type.contains('powerpoint')) return Icons.slideshow_rounded;
    if (type.startsWith('image/')) return Icons.image_rounded;
    if (type.contains('document') || type.contains('word') || type.startsWith('text/')) return Icons.description_rounded;
    return Icons.insert_drive_file_rounded;
  }
}

class _NotConfigured implements Exception {
  const _NotConfigured();
}

class _Blocked implements Exception {
  final String message;
  const _Blocked(this.message);
}
