import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:intl/intl.dart';

/// Typed model for a single history row. The original widget indexed the
/// decoded JSON map directly inside `build()` (`record['new_status']`,
/// `DateTime.parse(record['changed_at'])` with no null check) — any
/// malformed row from the API would throw mid-build and take the whole
/// widget down. Parsing is centralized here and failures are handled once,
/// per-row, instead of crashing the tree.
class JobStatusHistoryEntry {
  final int historyId;
  final String oldStatus;
  final String newStatus;
  final DateTime? changedAt;

  JobStatusHistoryEntry({
    required this.historyId,
    required this.oldStatus,
    required this.newStatus,
    required this.changedAt,
  });

  factory JobStatusHistoryEntry.fromJson(Map<String, dynamic> json) {
    DateTime? parsed;
    final raw = json['changed_at'];
    if (raw is String) {
      parsed = DateTime.tryParse(raw)?.toLocal();
    }
    return JobStatusHistoryEntry(
      historyId: json['history_id'] is int
          ? json['history_id'] as int
          : int.tryParse('${json['history_id']}') ?? -1,
      oldStatus: (json['old_status'] ?? 'Created').toString(),
      newStatus: (json['new_status'] ?? 'Unknown').toString(),
      changedAt: parsed,
    );
  }
}

class JobStatusTimeline extends StatefulWidget {
  final String jobId;
  final String apiBaseUrl;
  final String authToken;

  const JobStatusTimeline({
    super.key,
    required this.jobId,
    required this.apiBaseUrl,
    required this.authToken,
  });

  @override
  State<JobStatusTimeline> createState() => _JobStatusTimelineState();
}

class _JobStatusTimelineState extends State<JobStatusTimeline> {
  late Future<List<JobStatusHistoryEntry>> _historyFuture;

  @override
  void initState() {
    super.initState();
    _historyFuture = fetchJobHistory();
  }

  Future<List<JobStatusHistoryEntry>> fetchJobHistory() async {
    final response = await http
        .get(
          Uri.parse('${widget.apiBaseUrl}/jobs/${widget.jobId}/history'),
          headers: {
            'Authorization': 'Bearer ${widget.authToken}',
            'Content-Type': 'application/json',
          },
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode == 200) {
      final decoded = json.decode(response.body);
      if (decoded is! List) {
        throw const FormatException('Unexpected response shape for job history.');
      }
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(JobStatusHistoryEntry.fromJson)
          .toList();
    } else if (response.statusCode == 401 || response.statusCode == 403) {
      throw Exception('Not authorized to view this job\'s history.');
    } else if (response.statusCode == 404) {
      throw Exception('Job not found.');
    } else {
      throw Exception('Failed to load job history (${response.statusCode}).');
    }
  }

  Future<void> _refresh() async {
    final next = fetchJobHistory();
    setState(() => _historyFuture = next);
    // Surface errors from pull-to-refresh too, without leaving the
    // RefreshIndicator spinning forever if the future rejects.
    await next.catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<JobStatusHistoryEntry>>(
      future: _historyFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return _ErrorState(
            message: snapshot.error.toString(),
            onRetry: _refresh,
          );
        }

        final history = snapshot.data ?? const [];
        if (history.isEmpty) {
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const [
                SizedBox(height: 80),
                Center(child: Text('No status history available.')),
              ],
            ),
          );
        }

        return RefreshIndicator(
          onRefresh: _refresh,
          child: ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: history.length,
            itemBuilder: (context, index) {
              return _TimelineTile(
                entry: history[index],
                isLast: index == history.length - 1,
                isFirst: index == 0,
              );
            },
          ),
        );
      },
    );
  }
}

class _TimelineTile extends StatelessWidget {
  final JobStatusHistoryEntry entry;
  final bool isLast;
  final bool isFirst;

  const _TimelineTile({
    required this.entry,
    required this.isLast,
    required this.isFirst,
  });

  @override
  Widget build(BuildContext context) {
    final formattedDate = entry.changedAt != null
        ? DateFormat('MMM d, yyyy • h:mm a').format(entry.changedAt!)
        : 'Date unavailable';

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Column(
            children: [
              Container(
                margin: const EdgeInsets.only(top: 4),
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isLast ? Colors.green : Colors.blue.shade700,
                  border: Border.all(color: Colors.white, width: 2),
                ),
              ),
              if (!isLast)
                Expanded(
                  child: VerticalDivider(
                    thickness: 2,
                    color: Colors.grey.shade300,
                  ),
                ),
            ],
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.newStatus.toUpperCase(),
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    formattedDate,
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                  ),
                  if (isFirst)
                    Padding(
                      padding: const EdgeInsets.only(top: 4.0),
                      child: Text(
                        'Initial recorded state',
                        style: TextStyle(
                          color: Colors.grey.shade500,
                          fontStyle: FontStyle.italic,
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 32),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.red),
            ),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}