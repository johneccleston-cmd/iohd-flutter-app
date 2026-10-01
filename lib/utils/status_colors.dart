
import 'package:flutter/material.dart';
Color _getStatusColor(String status) {
  switch (status.trim().toLowerCase()) {
    case 'need deposit':
      return const Color(0xFFA80000);
    case 'need to order':
      return const Color(0xFF00B3FF);
    case 'manage project':
    case 'verify delivery':
      return const Color(0xFF0051FF);
    case 'need to schedule':
      return const Color(0xFF08EB00);
    case 'site check':
    case 'scheduled':
    case 'warranty work':
    case 'callback':
      return const Color(0xFF009E18);
    case 'appointment':
      return const Color(0xFF00B51B);
    case 'delayed':
    case 'need to warranty':
    case 'partially complete':
      return const Color(0xFFFFAE00);
    case 'need to sell':
    case 'google review sent':
      return const Color(0xFF000AC4);
    case 'cancelled':
      return const Color(0xFF592D00);
    case 'complete':
      return const Color(0xFF9C9C9C);
    case 'final invoice sent':
      return const Color(0xFFDB0000);
    case 'write-off':
      return const Color(0xFFD92100);
    case 'close job':
    case 'paid & closed':
      return const Color(0xFF000000);
    case 'part ordered':
      return const Color(0xFF7F83EB);
    case 'estimate requested':
    case 'estimate follow up':
    case 'estimate accepted':
      return const Color(0xFFEB36FF);
    case 'estimate provided':
      return const Color(0xFF5F0069);
    case 'estimate won':
      return const Color(0xFF3C0045);
    case 'lost':
      return const Color(0xFF59320C);
    case '14 day notice':
    case '30 day notice':
    case '60 day notice':
    case '90 day notice':
    case 'check on payment':
      return const Color(0xFFFF0000);
    default:
      return const Color(0xFF9C9C9C);
  }
}