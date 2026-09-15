import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../widgets/states.dart';

/// Owner-only settings for how monthly fees behave.
///
/// Fees now run on automatic monthly carry-forward: every month's fee record
/// is the student's *fixed* monthly fee, unpaid months accumulate into an
/// outstanding balance, and payments clear the oldest unpaid month first. The
/// old "late-fee increment" (an extra amount added to the next month's fee) is
/// gone — this screen is now a plain explanation of the current behaviour,
/// because there is nothing left to configure.
class FeeSettingsScreen extends StatelessWidget {
  const FeeSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Fee Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 36),
        children: [
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionHeader(title: 'Automatic monthly carry-forward'),
                const SizedBox(height: 8),
                const Text(
                  'Every month\'s fee record is the student\'s fixed monthly '
                  'fee — nothing is ever added on top of it. When a month is '
                  'not paid, that amount carries forward: the total the student '
                  'owes grows month to month, automatically, until it is paid.',
                  style: TextStyle(
                    color: TandavColors.textSecondary,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionHeader(title: 'How it works'),
                const SizedBox(height: 8),
                const _Bullet(
                    'The monthly fee you set on a student is the fee for every '
                    'month — it never changes and never gets an increment.'),
                const _Bullet(
                    'An unpaid month rolls forward into the next month\'s '
                    'total automatically. A student who skipped September and '
                    'October shows a pending balance of ₹2,000 plus November\'s '
                    'fee in the November register.'),
                const _Bullet(
                    'Payments settle the oldest unpaid month first. A ₹2,000 '
                    'payment in November clears September and October; '
                    'November\'s own fee remains to collect.'),
                const _Bullet(
                    'Once everything up to a month is settled, that month shows '
                    '"paid" and the pending balance for the next month starts '
                    'fresh at the monthly fee.'),
                const _Bullet(
                    'Fees are only ever generated from the month a student '
                    'joined — nothing is owed for months before they were a '
                    'student.'),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionHeader(title: 'Example'),
                const SizedBox(height: 8),
                const Text(
                  'A student\'s monthly fee is ₹1,000. They do not pay for '
                  'September or October. In November the register shows '
                  '₹3,000 pending (Sep ₹1,000 + Oct ₹1,000 + Nov ₹1,000). '
                  'Mark them paid with ₹3,000 and all three months are cleared; '
                  'December starts again at ₹1,000.',
                  style: TextStyle(
                    color: TandavColors.textSecondary,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _card({required Widget child}) => Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
        decoration: BoxDecoration(
          color: TandavColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: TandavColors.surfaceBorder),
        ),
        child: child,
      );
}

class _Bullet extends StatelessWidget {
  final String text;
  const _Bullet(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 5),
            child: Icon(Icons.check_circle_outline,
                size: 14, color: TandavColors.gold),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: TandavColors.textSecondary,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}