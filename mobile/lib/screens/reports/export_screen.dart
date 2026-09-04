import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/export_share.dart';
import '../../core/format.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../database/db_helpers.dart';
import '../../widgets/states.dart';

/// Owner-only spreadsheet export.
///
/// Generates one or more CSV files from the local SQLite database and shares
/// them (Android share sheet / iPhone PWA browser download). The owner can pull
/// students, batches, the fee register and attendance into Excel or Google
/// Sheets. Fully offline and free — no subscription, nothing sent anywhere
/// except the files the owner chooses to forward.
class ExportScreen extends StatefulWidget {
  const ExportScreen({super.key});

  @override
  State<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends State<ExportScreen> {
  final Map<String, bool> _selected = {
    'students': true,
    'batches': true,
    'fees': true,
    'attendance': true,
  };

  String _feeMonth = DbFmt.month(DateTime.now());
  String _attMonth = DbFmt.month(DateTime.now());
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Export to Spreadsheet')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 32),
        children: [
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionHeader(title: 'What to export'),
                const SizedBox(height: 4),
                _check('Students', 'All students with batches, phone, email, '
                    'guardian and monthly fee', 'students'),
                _check('Batches', 'Batch names, style, schedule and default fee',
                    'batches'),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.only(left: 34),
                  child: Text(
                    'CSV files open in Excel and Google Sheets. Everything is '
                    'generated on this phone — no subscription, nothing paid.',
                    style: const TextStyle(
                      color: TandavColors.textMuted,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (_selected['fees'] == true)
            _monthCard('Monthly fee register', 'Pick the month of fees to export',
                _feeMonth, (m) => setState(() => _feeMonth = m)),
          if (_selected['attendance'] == true)
            _monthCard(
                'Monthly attendance summary',
                'Pick the month of attendance to export',
                _attMonth, (m) => setState(() => _attMonth = m)),
          const SizedBox(height: 14),
          _busy
              ? const Center(child: CircularProgressIndicator())
              : GoldButton(
                  label: 'Generate & Share CSV',
                  icon: Icons.ios_share_rounded,
                  expanded: true,
                  onPressed: _anySelected ? _export : null,
                ),
          const SizedBox(height: 8),
          if (!_anySelected)
            const Center(
              child: Text(
                'Select at least one export.',
                style: TextStyle(color: TandavColors.textMuted, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  bool get _anySelected => _selected.values.any((v) => v);

  Widget _card({required Widget child}) => Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        decoration: BoxDecoration(
          color: TandavColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: TandavColors.surfaceBorder),
        ),
        child: child,
      );

  Widget _check(String title, String subtitle, String key) {
    return CheckboxListTile(
      value: _selected[key],
      onChanged: (v) => setState(() => _selected[key] = v ?? false),
      title: Text(
        title,
        style: const TextStyle(
          fontWeight: FontWeight.w700,
          color: TandavColors.textPrimary,
          fontSize: 14.5,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(fontSize: 12, color: TandavColors.textSecondary),
      ),
      contentPadding: EdgeInsets.zero,
      activeColor: TandavColors.gold,
      checkColor: const Color(0xFF141414),
    );
  }

  Widget _monthCard(String title, String subtitle, String month,
      ValueChanged<String> onPicked) {
    return _card(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: TandavColors.textPrimary,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                      fontSize: 12, color: TandavColors.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: () async {
              final initial = DateTime.tryParse(month) ?? DateTime.now();
              final picked = await showDatePicker(
                context: context,
                initialDate: initial,
                firstDate: DateTime(2020),
                lastDate: DateTime(2100),
                helpText: 'Select month',
              );
              if (picked != null) {
                onPicked(DbFmt.month(picked));
              }
            },
            icon: const Icon(Icons.calendar_month_outlined, size: 17),
            label: Text(Fmt.monthLabel(month)),
          ),
        ],
      ),
    );
  }

  Future<void> _export() async {
    setState(() => _busy = true);
    final api = context.read<TandavApi>();
    try {
      final out = <(String, String)>[];
      String stamp() =>
          '${DateTime.now().year}-${DateTime.now().month.toString().padLeft(2, '0')}-${DateTime.now().day.toString().padLeft(2, '0')}';
      if (_selected['students'] == true) {
        out.add(('tandav-students-${stamp()}.csv', await api.exportStudentsCsv()));
      }
      if (_selected['batches'] == true) {
        out.add(('tandav-batches-${stamp()}.csv', await api.exportBatchesCsv()));
      }
      if (_selected['fees'] == true) {
        out.add(('tandav-fees-${stamp()}.csv',
            await api.exportMonthlyFeesCsv(month: _feeMonth)));
      }
      if (_selected['attendance'] == true) {
        out.add(('tandav-attendance-${stamp()}.csv',
            await api.exportAttendanceCsv(month: _attMonth)));
      }
      if (!mounted) return;
      await shareExports(out);
    } on Exception catch (e) {
      if (mounted) {
        Alert.show(context, e.toString().replaceFirst('Exception: ', ''),
            isError: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
