import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart' show FaIcon, FontAwesomeIcons;

/// Stripe's own purple: a brand colour, not an app token.
const kStripeBrand = Color(0xFF635BFF);

/// The same purple a shade darker for small text: [kStripeBrand] is under 4.5:1 on a striped row.
const kStripeText = Color(0xFF5A51F5);

/// Stripe's mark (the white "S" on its purple tile), beside Stripe money so it reads as Stripe at a glance. Used on the
/// job page's Payment tab and the Payments screen.
class StripeMark extends StatelessWidget {
  final double size;
  final String? tip;
  const StripeMark({super.key, required this.size, this.tip});

  @override
  Widget build(BuildContext context) {
    final mark = Semantics(
      label: 'Stripe',
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: kStripeBrand, borderRadius: BorderRadius.circular(size * 0.26)),
        child: FaIcon(FontAwesomeIcons.stripeS, size: size * 0.52, color: Colors.white),
      ),
    );
    return tip == null ? mark : Tooltip(message: tip!, waitDuration: const Duration(milliseconds: 400), child: mark);
  }
}

/// What a Stripe payment was for, from the memo the webhook writes ("Stripe Deposit - job #N - Customer", see the
/// backend's stripe_payments.js): "Deposit", "Final Balance", "Full Payment", "Refund", or "Payment".
String stripePaymentLabel(Object? memo, {bool refund = false}) {
  if (refund) return 'Refund';
  final head = (memo ?? '').toString().split(' - ').first.trim();
  final label = head.replaceFirst(RegExp(r'^Stripe\s*', caseSensitive: false), '').trim();
  return label.isEmpty || label.toLowerCase() == 'payment' ? 'Payment' : label[0].toUpperCase() + label.substring(1);
}

/// The customer named in a Stripe memo (the last part, after the job number), or '' when it names none.
String stripeMemoCustomer(Object? memo) {
  final parts = (memo ?? '').toString().split(' - ');
  if (parts.length < 3) return '';
  final last = parts.last.trim();
  return last.toLowerCase().startsWith('job #') || last.toLowerCase() == 'no job number' ? '' : last;
}

/// The payment in Stripe's dashboard.
Uri stripeDashboardUri(String paymentIntent) => Uri.https('dashboard.stripe.com', '/payments/$paymentIntent');
