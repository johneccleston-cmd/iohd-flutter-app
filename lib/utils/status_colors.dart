import 'package:flutter/material.dart';

/// Service Fusion job/estimate status colours. This mirrors STATUS_COLORS in the backend's src/statusRules.js, the
/// source of truth: change a colour there and here together. Every screen that shows a job or estimate status uses
/// this (via [statusColor] or the [StatusPill] widget) so a status looks the same everywhere.
const Map<String, Color> kStatusColors = {
  'need deposit': Color(0xFFA80000),
  'need to order': Color(0xFF00B3FF),
  'manage project': Color(0xFF0051FF),
  'verify delivery': Color(0xFF0051FF),
  'need to schedule': Color(0xFF08EB00),
  'site check': Color(0xFF009E18),
  'scheduled': Color(0xFF009E18),
  'warranty work': Color(0xFF009E18),
  'callback': Color(0xFF009E18),
  'appointment': Color(0xFF00B51B),
  'delayed': Color(0xFFFFAE00),
  'need to warranty': Color(0xFFFFAE00),
  'partially complete': Color(0xFFFFAE00),
  'need to sell': Color(0xFF000AC4),
  'google review sent': Color(0xFF000AC4),
  'cancelled': Color(0xFF592D00),
  'complete': Color(0xFF9C9C9C),
  'final invoice sent': Color(0xFFDB0000),
  'write-off': Color(0xFFD92100),
  'close job': Color(0xFF000000),
  'paid & closed': Color(0xFF000000),
  'part ordered': Color(0xFF7F83EB),
  'estimate requested': Color(0xFFEB36FF),
  'estimate follow up': Color(0xFFEB36FF),
  'estimate accepted': Color(0xFFEB36FF),
  'estimate provided': Color(0xFF5F0069),
  'estimate won': Color(0xFF3C0045),
  'lost': Color(0xFF59320C),
  '14 day notice': Color(0xFFFF0000),
  '30 day notice': Color(0xFFFF0000),
  '60 day notice': Color(0xFFFF0000),
  '90 day notice': Color(0xFFFF0000),
  'check on payment': Color(0xFFFF0000),
};

const Color kStatusFallback = Color(0xFF9C9C9C);

/// The colour for [status], or null when it isn't a status we have a colour for.
///
/// Service Fusion also has sub-variants like "Scheduled - Full Day" and "Lost - Competitor"; they take the colour of the
/// status before the dash ("scheduled", "lost").
Color? knownStatusColor(String? status) {
  if (status == null) return null;
  final t = status.trim().toLowerCase();
  final exact = kStatusColors[t];
  if (exact != null) return exact;
  final dash = t.indexOf(' - ');
  return dash > 0 ? kStatusColors[t.substring(0, dash).trim()] : null;
}

/// The colour for [status]; grey for an unknown or missing one.
Color statusColor(String? status) => knownStatusColor(status) ?? kStatusFallback;
