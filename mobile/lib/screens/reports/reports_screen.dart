import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../models/dashboard.dart';
import '../../widgets/states.dart';

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  DateTime _month = DateTime.now();
  late Future<MonthlyReport> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  String get _iso =>
      '${_month.year.toString().padLeft(4, '0')}-${_month.month.toString().padLeft(2, '0')}-01';

  Future<MonthlyReport> _load() =>
      context.read<TandavApi>().getMonthlyReport(_iso);

  void _reload() {
    setState(() {
      _future = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Monthly Reports'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: OutlinedButton.icon(
              onPressed: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _month,
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2100),
                  helpText: 'Select month',
                );
                if (picked != null) {
                  setState(() => _month = picked);
                  _reload();
                }
              },
              icon: const Icon(Icons.calendar_month_outlined, size: 17),
              label: Text(Fmt.monthLabel(_iso)),
            ),
          ),
        ],
      ),
      body: FutureBuilder<MonthlyReport>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const LoadingView(message: 'Compiling report…');
          }
          if (snapshot.hasError) {
            return ErrorView(
              message: snapshot.error.toString(),
              onRetry: _reload,
            );
          }
          final report = snapshot.data!;
          if (report.rows.isEmpty) {
            return const EmptyView(
              icon: Icons.summarize_outlined,
              title: 'Nothing to report',
              subtitle:
                  'Create batches, students and fees to see monthly summaries.',
            );
          }
          var totalStudents = 0;
          var totalAtt = 0;
          var totalAttPresent = 0;
          var totalFeesDue = 0.0;
          var totalFeesPaid = 0.0;
          for (final r in report.rows) {
            totalStudents += r.totalStudents;
            totalAtt += r.attendanceTotal;
            totalAttPresent += r.attendancePresent;
            totalFeesDue += r.dueValue;
            totalFeesPaid += r.paidValue;
          }
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            color: TandavColors.gold,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                _overviewCard(
                  totalStudents: totalStudents,
                  totalAtt: totalAtt,
                  totalAttPresent: totalAttPresent,
                  totalFeesDue: totalFeesDue,
                  totalFeesPaid: totalFeesPaid,
                ),
                const SectionHeader(title: 'Per Batch Summary'),
                ...report.rows.map((r) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _batchRow(r),
                    )),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _overviewCard({
    required int totalStudents,
    required int totalAtt,
    required int totalAttPresent,
    required double totalFeesDue,
    required double totalFeesPaid,
  }) {
    final attPct = totalAtt == 0
        ? 0.0
        : (totalAttPresent / totalAtt * 100).clamp(0, 100);
    final feePct = totalFeesDue == 0
        ? 0.0
        : (totalFeesPaid / totalFeesDue * 100).clamp(0, 100);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              Fmt.monthLabel(_iso).toUpperCase(),
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
                color: TandavColors.gold,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                    child: _overviewStat('STUDENTS', '$totalStudents')),
                Expanded(
                    child:
                        _overviewStat('CLASS ATTENDANCE', '$totalAtt')),
                Expanded(
                  child: _overviewStat(
                      'FEES COLLECTED',
                      '${feePct.toStringAsFixed(0)}%'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _meter('Attendance', attPct / 100,
                      TandavColors.gold),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _meter('Fees', feePct / 100,
                      TandavColors.yellow),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${Fmt.money(totalFeesPaid)} collected of ${Fmt.money(totalFeesDue)} due',
              style: const TextStyle(
                  fontSize: 12.5, color: TandavColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _overviewStat(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: const TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.w900,
            color: TandavColors.textPrimary,
          ),
        ),
        Text(
          label,
          style: const TextStyle(
            fontSize: 9.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.7,
            color: TandavColors.textMuted,
          ),
        ),
      ],
    );
  }

  Widget _meter(String label, double value, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: const TextStyle(
                  fontSize: 11.5, color: TandavColors.textSecondary),
            ),
            const Spacer(),
            Text(
              '${(value * 100).toStringAsFixed(0)}%',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: value.clamp(0, 1),
            minHeight: 6,
            backgroundColor: TandavColors.surfaceBorder,
            valueColor: AlwaysStoppedAnimation(color),
          ),
        ),
      ],
    );
  }

  Widget _batchRow(MonthlyReportRow r) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    r.batchName,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 14.5,
                      color: TandavColors.textPrimary,
                    ),
                  ),
                ),
                Text(
                  '${r.totalStudents} students',
                  style: const TextStyle(
                      fontSize: 12, color: TandavColors.textSecondary),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _batchStat(
                    'Attendance',
                    r.attendanceTotal == 0
                        ? '—'
                        : '${r.attendancePercentage.toStringAsFixed(0)}%',
                    '${r.attendancePresent}/${r.attendanceTotal} present',
                  ),
                ),
                Expanded(
                  child: _batchStat(
                    'Fees',
                    r.dueValue == 0
                        ? '—'
                        : '${r.feeCollectionRate.toStringAsFixed(0)}%',
                    '${Fmt.money(r.paidValue)} of ${Fmt.money(r.dueValue)}',
                  ),
                ),
                Expanded(
                  child: _batchStat(
                    'Outstanding',
                    Fmt.money(double.tryParse(r.feeOutstanding) ?? 0),
                    '',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: (r.attendancePercentage / 100).clamp(0, 1),
                minHeight: 5,
                backgroundColor: TandavColors.surfaceBorder,
                valueColor: const AlwaysStoppedAnimation(TandavColors.gold),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _batchStat(String label, String value, String sub) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            fontSize: 9.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.7,
            color: TandavColors.textMuted,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w900,
            color: TandavColors.textPrimary,
          ),
        ),
        if (sub.isNotEmpty)
          Text(
            sub,
            style: const TextStyle(
                fontSize: 10.5, color: TandavColors.textMuted),
          ),
      ],
    );
  }
}