import 'package:sqflite/sqflite.dart';

import '../database/db_helpers.dart';
import '../database/tandav_database.dart';
import '../models/dashboard.dart';
import 'fee_repository.dart';

/// Aggregations for the dashboard and monthly reports — every number is
/// computed live from SQLite data (never hardcoded).
class DashboardRepository {
  final TandavDatabase db;
  final FeeRepository fees;

  DashboardRepository(this.db, this.fees);

  Future<Database> get _d => db.open();

  Future<DashboardData> getDashboard({String? month}) async {
    final d = await _d;
    final today = DateTime.now();
    final todayIso = DbFmt.date(today);
    final target = DbFmt.month(month != null ? DateTime.parse(_monthIso(month)) : today);

    // Ensure fee records exist for the target month (idempotent).
    await fees.ensureMonthlyFees(today, anchor: DateTime.parse(target));

    final totalStudents = Sqflite.firstIntValue(
            await d.rawQuery('SELECT COUNT(*) FROM students')) ??
        0;
    final activeStudents = Sqflite.firstIntValue(
            await d.rawQuery('SELECT COUNT(*) FROM students WHERE is_active = 1')) ??
        0;
    final totalBatches =
        Sqflite.firstIntValue(await d.rawQuery('SELECT COUNT(*) FROM batches')) ?? 0;
    final activeBatches = Sqflite.firstIntValue(
            await d.rawQuery('SELECT COUNT(*) FROM batches WHERE is_active = 1')) ??
        0;
    final totalEvents =
        Sqflite.firstIntValue(await d.rawQuery('SELECT COUNT(*) FROM events')) ?? 0;
    final upcomingEvents = Sqflite.firstIntValue(
            await d.rawQuery('SELECT COUNT(*) FROM events WHERE event_date >= ?',
                [todayIso])) ??
        0;

    final todayMarks = await d.query('attendance',
        where: 'attendance_date = ?', whereArgs: [todayIso]);
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
      SELECT attendance_date, status, COUNT(*) AS cnt
      FROM attendance
      WHERE attendance_date >= ? AND attendance_date < ?
      GROUP BY attendance_date, status
      ORDER BY attendance_date
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
              WHERE ep.event_id = e.id) AS participant_count
      FROM events e
      WHERE e.event_date >= ?
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
      LEFT JOIN batches b ON b.id = s.batch_id
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
    final monthIso = _monthIso(month);
    final dateObj = DateTime.parse(monthIso);
    final nextMonth = DbFmt.date(DbFmt.addMonths(dateObj, 1));

    final batches = await d.query('batches', orderBy: 'name COLLATE NOCASE');
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
                'SELECT COUNT(*) FROM students WHERE batch_id IS NULL')) ??
            0)
        : (Sqflite.firstIntValue(await d.rawQuery(
                'SELECT COUNT(*) FROM students WHERE batch_id = ?', [batchId])) ??
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
      SELECT a.* FROM attendance a
      JOIN students s ON s.id = a.student_id
      WHERE a.attendance_date >= ? AND a.attendance_date < ? $batchCond
    ''', args);
    final attTotal = attRows.length;
    final attPresent = attRows.where((r) => r['status'] == 'present').length;
    final attLate = attRows.where((r) => r['status'] == 'late').length;
    final attPct = attTotal == 0
        ? 0.0
        : ((attPresent + attLate) / attTotal * 100).clamp(0, 100).toDouble();

    final feeArgs = <Object?>[];
    var feeJoin = '';
    if (batchId != null) {
      feeJoin = 'JOIN students s ON s.id = f.student_id AND s.batch_id = ?';
      feeArgs.add(batchId);
    } else {
      feeJoin = 'JOIN students s ON s.id = f.student_id AND s.batch_id IS NULL';
    }
    feeArgs.add(monthIso);
    final fees = await d.rawQuery(
        'SELECT * FROM fees f $feeJoin WHERE f.month = ?', feeArgs);
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

  String _monthIso(String month) =>
      month.replaceFirst(RegExp(r'-\d{2}$'), '-01');

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