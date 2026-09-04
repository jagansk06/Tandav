import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../widgets/states.dart';

class StudentDailyAttendanceScreen extends StatefulWidget {
  final int studentId;
  final String studentName;
  final String month;
  const StudentDailyAttendanceScreen({
    super.key,
    required this.studentId,
    required this.studentName,
    required this.month,
  });

  @override
  State<StudentDailyAttendanceScreen> createState() =>
      _StudentDailyAttendanceScreenState();
}

class _StudentDailyAttendanceScreenState
    extends State<StudentDailyAttendanceScreen> {
  late Future<List<Map<String, dynamic>>> _recordsFuture;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    setState(() {
      _recordsFuture = context
          .read<TandavApi>()
          .getStudentDailyAttendance(widget.studentId, widget.month);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.studentName),
            Text(
              Fmt.monthLabel(widget.month),
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w400),
            ),
          ],
        ),
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _recordsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const LoadingView(message: 'Loading…');
          }
          if (snapshot.hasError) {
            return ErrorView(
              message: snapshot.error.toString(),
              onRetry: _reload,
            );
          }
          final records = snapshot.data!;
          if (records.isEmpty) {
            return const EmptyView(
              icon: Icons.event_busy_outlined,
              title: 'No attendance records',
              subtitle: 'No attendance was marked for this student this month.',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            itemCount: records.length,
            separatorBuilder: (_, _) => const SizedBox(height: 6),
            itemBuilder: (ctx, i) => _row(records[i]),
          );
        },
      ),
    );
  }

  Widget _row(Map<String, dynamic> r) {
    final date = r['attendance_date'] as String;
    final status = r['status'] as String? ?? 'unmarked';
    final notes = r['notes'] as String?;

    final (color, icon, label) = switch (status) {
      'present' => (TandavColors.success, Icons.check_circle_outline, 'Present'),
      'late' => (TandavColors.yellow, Icons.schedule, 'Late'),
      'absent' => (TandavColors.danger, Icons.cancel_outlined, 'Absent'),
      _ => (TandavColors.textMuted, Icons.help_outline, 'Unmarked'),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    Fmt.date(date),
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: TandavColors.textPrimary,
                    ),
                  ),
                  if (notes != null && notes.isNotEmpty)
                    Text(
                      notes,
                      style: const TextStyle(
                        fontSize: 12,
                        color: TandavColors.textMuted,
                      ),
                    ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                label,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
