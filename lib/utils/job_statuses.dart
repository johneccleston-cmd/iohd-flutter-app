/// Every status a job can be given, in the order Service Fusion lists them. A sub-status is picked from this same
/// list. Names must match Service Fusion exactly (the sync and the commission rules compare them as text); the colours
/// are in status_colors.dart. Every status found in the live data on 2026-10-12 is on this list.
const List<String> kJobStatuses = [
  'Final Invoice Sent',
  '14 Day Notice',
  '30 Day Notice',
  '60 Day Notice',
  '90 Day Notice',
  'Check on Payment',
  'Write-Off',
  'Close Job',
  'Verify Delivery',
  'Part Ordered',
  'Google Review Sent',
  'Paid & Closed',
  'Site Check',
  'Scheduled - Full Day',
  'Scheduled - Half Day',
  'Appointment',
  'Delayed',
  'Need To Sell',
  'Cancelled',
  'Need To Warranty',
  'Warranty Work',
  'Callback',
  'Partially Complete',
  'Complete',
  'Need Deposit',
  'Need To Order',
  'Manage Project',
  'Need To Schedule',
];

/// The statuses an estimate can have (the ones in use in the live data on 2026-10-12, plus the Service Fusion estimate
/// statuses the app already colours). An estimate's status and sub-status are picked from this list.
const List<String> kEstimateStatuses = [
  'Estimate Requested',
  'Estimate Follow Up',
  'Estimate Site Check',
  'Estimate Provided',
  'Estimate Accepted',
  'Estimate Won',
  'Lost',
  'Lost - Competitor',
];
