import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../models/attendance.dart';
import '../../models/batch.dart';
import '../../widgets/states.dart';
import 'student_daily_attendance_screen.dart';

class MonthlyAttendanceScreen extends StatefulWidget {
  const MonthlyAttendanceScreen({super.key});

  @override
  State<MonthlyAttendanceScreen> createState() => _MonthlyAttendanceScreenState();
}

class _MonthlyAttendanceScreenState extends State<MonthlyAttendanceScreen> {
  late Future<List<Batch>> _batchesFuture;
  List<Batch> _batches = [];
  int? _batchId;
  DateTime _month = DateTime.now();
  late Future<List<MonthlyAttendanceSummary>> _rowsFuture;

  @override
  void initState() {
    super.initState();
    _batchesFuture =
        context.read<TandavApi>().getBatches().then((r) => r.items);
    _rowsFuture =
        context.read<TandavApi>().getMonthlyAttendance(_iso, batchId: _batchId);
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await _batchesFuture;
      if (mounted) setState(() => _batches = res);
    } catch (_) {}
  }

  String get _iso =>
      '${_month.year.toString().padLeft(4, '0')}-${_month.month.toString().padLeft(2, '0')}-01';

  void _reload() {
    setState(() {
      _rowsFuture =
          context.read<TandavApi>().getMonthlyAttendance(_iso, batchId: _batchId);
    });
  }

  Future<void> _pickMonth() async {
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
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Monthly Attendance')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: FutureBuilder<List<Batch>>(
                    future: _batchesFuture,
                    builder: (context, snapshot) {
                      final batches = snapshot.data ?? _batches;
                      return DropdownButtonFormField<int?>(
                        initialValue: _batchId,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Batch',
                          prefixIcon: Icon(Icons.grid_view_outlined),
                        ),
                        items: [
                          const DropdownMenuItem<int?>(
                            value: null,
                            child: Text('All batches'),
                          ),
                          ...batches.map(
                            (b) => DropdownMenuItem<int?>(
                              value: b.id,
                              child: Text(b.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                            ),
                          ),
                        ],
                        onChanged: (v) {
                          setState(() => _batchId = v);
                          _reload();
                        },
                      );
                    },
                  ),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: _pickMonth,
                  icon: const Icon(Icons.calendar_month_outlined, size: 18),
                  label: Text(Fmt.monthLabel(_iso)),
                ),
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder<List<MonthlyAttendanceSummary>>(
              future: _rowsFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const LoadingView(message: 'Calculating…');
                }
                if (snapshot.hasError) {
                  return ErrorView(
                    message: snapshot.error.toString(),
                    onRetry: _reload,
                  );
                }
                final rows = snapshot.data!;
                if (rows.isEmpty) {
                  return const EmptyView(
                    icon: Icons.calculate_outlined,
                    title: 'No attendance for this month',
                    subtitle:
                        'Mark daily attendance and the monthly summary is calculated automatically.',
                  );
                }
                rows.sort((a, b) => a.studentName.compareTo(b.studentName));
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (ctx, i) => _row(rows[i]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(MonthlyAttendanceSummary r) {
    final pct = r.percentage;
    final color = pct >= 85
        ? TandavColors.success
        : pct >= 60
            ? TandavColors.yellow
            : TandavColors.danger;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => StudentDailyAttendanceScreen(
              studentId: r.studentId,
              studentName: r.studentName,
              month: r.month,
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 52,
                padding: const EdgeInsets.symmetric(vertical: 6),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  children: [
                    Text(
                      '${pct.toStringAsFixed(0)}%',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 15,
                        color: color,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      r.studentName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14.5,
                        color: TandavColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${r.totalClasses} classes · ${r.presents} P · ${r.lates} L · ${r.absents} A',
                      style: const TextStyle(
                          fontSize: 12, color: TandavColors.textSecondary),
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: (pct / 100).clamp(0, 1),
                        minHeight: 5,
                        backgroundColor: TandavColors.surfaceBorder,
                        valueColor: AlwaysStoppedAnimation(color),
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded,
                  color: TandavColors.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}