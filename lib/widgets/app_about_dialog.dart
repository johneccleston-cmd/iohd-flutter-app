import 'package:flutter/material.dart';

import '../config/app_info.dart';
import 'app_dialog.dart';
import 'dashboard_kit.dart';

/// The About box from the account menu: who makes the app, which build this is, and the copyright.
Future<void> showAppAboutDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AppDialog(
      title: 'About $kAppName',
      icon: Icons.info_outline_rounded,
      width: 420,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Semantics(
              label: kCompanyBrand,
              child: Image.asset('assets/images/iohd_logo.png', height: 72, filterQuality: FilterQuality.medium),
            ),
          ),
          const SizedBox(height: 16),
          _row('Version', kAppVersion),
          _row('Company', kCompanyName),
          _row('Support', kSupportName),
          _row('', kSupportPhone),
          _row('', kSupportEmail),
          const SizedBox(height: 12),
          const Text(
            'The back office for $kCompanyBrand: jobs, estimates, customers, calendar, inventory, payroll and '
            'dashboards. For use by $kCompanyBrand staff only.',
            style: TextStyle(fontSize: 13.5, color: DashUi.slate, height: 1.4),
          ),
          const SizedBox(height: 12),
          Text(
            '${copyrightLine()}. All rights reserved.',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: DashUi.ink),
          ),
        ],
      ),
      actions: [
        AppButton.ghost(
          'Licenses',
          () => showLicensePage(
            context: ctx,
            applicationName: kAppName,
            applicationVersion: kAppVersion,
            applicationLegalese: '${copyrightLine()}. All rights reserved.',
          ),
        ),
        AppButton.ink('Close', () => Navigator.pop(ctx)),
      ],
    ),
  );
}

Widget _row(String label, String value) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 3),
  child: Row(
    children: [
      SizedBox(
        width: 80,
        child: Text(label, style: const TextStyle(fontSize: 13.5, color: DashUi.slate)),
      ),
      Expanded(
        child: SelectableText(value, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: DashUi.ink)),
      ),
    ],
  ),
);
