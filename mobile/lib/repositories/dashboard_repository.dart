import 'package:sqflite/sqflite.dart';

import '../database/db_helpers.dart';
import '../database/tandav_database.dart';
import '../models/dashboard.dart';
import 'fee_repository.dart';

/// Aggregations for the dashboard and monthly reports — every number is
/// computed live from SQLite data (never hardcoded).
///
/// Every query filters `deleted_at IS NULL`. Deletes are tombstones (rows stay
/// in the table so the other device learns about them), so a query that forgets
/// the filter silently counts deleted students, batches and fees — and the
/// numbers would drift further apart with every sync.
class DashboardRepository {
  final TandavDatabase db;
  final FeeRepository fees;

  DashboardRepository(this.db, this.fees);

  Future<Database> get _d => db.open();

  Future<DashboardData> getDashboard({String? month}) async {
    final d = await _d;
    final today = DateTime.now();
    final todayIso = DbFmt.date(today);
    final target =
        DbFmt.month(month != null ? DateTime.parse(DbFmt.monthStart(month)) : today);

    // Ensure fee records exist for the target month (idempotent).
    await fees.ensureMonthlyFees(today, anchor: DateTime.parse(target));

    final totalStudents = Sqflite.firstIntValue(await d
            .rawQuery('SELECT COUNT(*) FROM students WHERE deleted_at IS NULL')) ??
        0;
    final activeStudents = Sqflite.firstIntValue(await d.rawQuery(
            'SELECT COUNT(*) FROM students '
            'WHERE is_active = 1 AND deleted_at IS NULL')) ??
        0;
    final totalBatches = Sqflite.firstIntValue(await d
            .rawQuery('SELECT COUNT(*) FROM batches WHERE deleted_at IS NULL')) ??
        0;
    final activeBatches = Sqflite.firstIntValue(await d.rawQuery(
            'SELECT COUNT(*) FROM batches '
            'WHERE is_active = 1 AND deleted_at IS NULL')) ??
        0;
    final totalEvents = Sqflite.firstIntValue(await d
            .rawQuery('SELECT COUNT(*) FROM events WHERE deleted_at IS NULL')) ??
        0;
    final upcomingEvents = Sqflite.firstIntValue(await d.rawQuery(
            'SELECT COUNT(*) FROM events '
            'WHERE event_date >= ? AND deleted_at IS NULL',
            [todayIso])) ??
        0;

    final todayMarks = await d.rawQuery('''
      SELECT a.status FROM attendance a
      JOIN students s ON s.id = a.student_id AND s.deleted_at IS NULL
      WHERE a.attendance_date = ? AND a.deleted_at IS NULL
    ''', [todayIso]);
    var todayPresent = 0, todayAbsent = 0, todayLate = 0;
    for (final m in todayMarks) {
      switch (m['status'] as String) {
        case 'present':
          todayPresent++;
        case 'late':
          todayLate++;
        case 'absent':
          todayAbsent++;
      }
    }

    final stats = DashboardStats(
      totalStudents: totalStudents,
      activeStudents: activeStudents,
      totalBatches: totalBatches,
      activeBatches: activeBatches,
      totalEvents: totalEvents,
      upcomingEvents: upcomingEvents,
      todayPresent: todayPresent,
      todayAbsent: todayAbsent,
      todayLate: todayLate,
      todayUnmarked: (activeStudents - todayMarks.length).clamp(0, 1 << 31).toInt(),
    );

    final feeSummary = await fees.getFeeSummary(target);

    // Daily attendance trend for the month (same shape as before).
    final trendRows = await d.rawQuery('''
      SELECT a.attendance_date, a.status, COUNT(*) AS cnt
      FROM attendance a
      JOIN students s ON s.id = a.student_id AND s.deleted_at IS NULL
      WHERE a.attendance_date >= ? AND a.attendance_date < ?
        AND a.deleted_at IS NULL
      GROUP BY a.attendance_date, a.status
      ORDER BY a.attendance_date
    ''', [target, DbFmt.date(DbFmt.addMonths(DateTime.parse(target), 1))]);
    final daily = <String, Map<String, int>>{};
    for (final r in trendRows) {
      final key = r['attendance_date'] as String;
      final entry = daily.putIfAbsent(key, () => {'present': 0, 'absent': 0, 'late': 0});
      final status = r['status'] as String;
      if (entry.containsKey(status)) entry[status] = entry[status]! + (r['cnt'] as int);
    }
    final trend = daily.entries
        .map((e) => <String, dynamic>{'date': e.key, ...e.value})
        .toList();

    final upcoming = await d.rawQuery('''
      SELECT e.*,
             (SELECT COUNT(*) FROM event_participations ep
              WHERE ep.event_id = e.id AND ep.deleted_at IS NULL)
             AS participant_count
      FROM events e
      WHERE e.event_date >= ? AND e.deleted_at IS NULL
      ORDER BY e.event_date ASC
      LIMIT 5
    ''', [todayIso]);
    final upcomingEventsOut = upcoming
        .map((r) => UpcomingEvent(
              id: r['id'] as int,
              name: r['name'] as String,
              eventType: (r['event_type'] as String?) ?? '',
              eventDate: r['event_date'] as String,
              location: r['location'] as String?,
              participantCount: (r['participant_count'] as int?) ?? 0,
            ))
        .toList();

    final recent = await d.rawQuery('''
      SELECT s.*, b.name AS batch_name
      FROM students s
      LEFT JOIN batches b ON b.id = s.batch_id AND b.deleted_at IS NULL
      WHERE s.deleted_at IS NULL
      ORDER BY s.id DESC
      LIMIT 5
    ''');
    final recentOut = recent
        .map((r) => RecentStudent(
              id: r['id'] as int,
              fullName: _names(r),
              batchName: r['batch_name'] as String?,
              joined: (r['join_date'] as String?) ?? '',
            ))
        .toList();

    final summaryOut = DashboardFeeSummary(
      month: target,
      totalDue: feeSummary.totalDue,
      totalPaid: feeSummary.totalPaid,
      outstanding: feeSummary.outstanding,
      paidCount: feeSummary.paidCount,
      dueCount: feeSummary.dueCount + feeSummary.partialCount,
      totalRecords: feeSummary.totalRecords,
    );

    return DashboardData(
      stats: stats,
      feeSummary: summaryOut,
      monthlyAttendance: trend,
      upcomingEvents: upcomingEventsOut,
      recentStudents: recentOut,
    );
  }

  /// Per-batch monthly report, including the "Unassigned" bucket.
  Future<MonthlyReport> getMonthlyReport(String month) async {
    final d = await _d;
    final monthIso = DbFmt.monthStart(month);
    final dateObj = DateTime.parse(monthIso);
    final nextMonth = DbFmt.date(DbFmt.addMonths(dateObj, 1));

    final batches = await d.query('batches',
        where: 'deleted_at IS NULL', orderBy: 'name COLLATE NOCASE');
    final rows = <MonthlyReportRow>[];
    for (final b in batches) {
      rows.add(await _rowForBatch(d, b['id'] as int, b['name'] as String,
          monthIso, nextMonth));
    }
    rows.add(await _rowForBatch(d, null, 'Unassigned', monthIso, nextMonth));
    return MonthlyReport(month: monthIso, rows: rows);
  }

  Future<MonthlyReportRow> _rowForBatch(
    Database d,
    int? batchId,
    String name,
    String monthIso,
    String nextMonth,
  ) async {
    final totalStudents = batchId == null
        ? (Sqflite.firstIntValue(await d.rawQuery(
                'SELECT COUNT(*) FROM students '
                'WHERE batch_id IS NULL AND deleted_at IS NULL')) ??
            0)
        : (Sqflite.firstIntValue(await d.rawQuery(
                'SELECT COUNT(*) FROM students '
                'WHERE batch_id = ? AND deleted_at IS NULL',
                [batchId])) ??
            0);

    final args = <Object?>[monthIso, nextMonth];
    var batchCond = '';
    if (batchId != null) {
      batchCond = 'AND s.batch_id = ?';
      args.add(batchId);
    } else {
      batchCond = 'AND s.batch_id IS NULL';
    }
    final attRows = await d.rawQuery('''
      SELECT a.status FROM attendance a
      JOIN students s ON s.id = a.student_id AND s.deleted_at IS NULL
      WHERE a.attendance_date >= ? AND a.attendance_date < ?
        AND a.deleted_at IS NULL $batchCond
    ''', args);
    final attTotal = attRows.length;
    final attPresent = attRows.where((r) => r['status'] == 'present').length;
    final attLate = attRows.where((r) => r['status'] == 'late').length;
    final attPct = attTotal == 0
        ? 0.0
        : ((attPresent + attLate) / attTotal * 100).clamp(0, 100).toDouble();

    final feeArgs = <Object?>[];
    final batchFilter =
        batchId == null ? 's.batch_id IS NULL' : 's.batch_id = ?';
    if (batchId != null) feeArgs.add(batchId);
    feeArgs.add(monthIso);
    final fees = await d.rawQuery('''
      SELECT f.amount_due, f.amount_paid FROM fees f
      JOIN students s ON s.id = f.student_id AND s.deleted_at IS NULL
      WHERE $batchFilter AND f.month = ? AND f.deleted_at IS NULL
    ''', feeArgs);
    var feesDue = 0.0, feesPaid = 0.0;
    for (final f in fees) {
      feesDue += _fee(f['amount_due']);
      feesPaid += _fee(f['amount_paid']);
    }
    final collectionRate =
        feesDue == 0 ? 0.0 : (feesPaid / feesDue * 100).clamp(0, 100).toDouble();

    return MonthlyReportRow(
      batchId: batchId,
      batchName: name,
      totalStudents: totalStudents,
      attendanceTotal: attTotal,
      attendancePresent: attPresent,
      attendancePercentage: attPct,
      feesDue: feesDue.toStringAsFixed(2),
      feesPaid: feesPaid.toStringAsFixed(2),
      feeOutstanding: (feesDue - feesPaid).toStringAsFixed(2),
      feeCollectionRate: collectionRate,
    );
  }

  double _fee(Object? v) {
    final n = double.tryParse(v?.toString() ?? '');
    return n == null ? 0 : DbFmt.round2(n);
  }

  String _names(Map<String, Object?> row) {
    final first = (row['first_name'] as String?) ?? '';
    final last = (row['last_name'] as String?) ?? '';
    return '$first $last'.trim();
  }
}