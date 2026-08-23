import 'package:sqflite/sqflite.dart';

import '../database/db_helpers.dart';
import '../database/tandav_database.dart';
import '../models/attendance.dart';
import '../sync/sync_meta.dart';

class AttendanceRepository {
  final TandavDatabase db;
  AttendanceRepository(this.db);

  Future<Database> get _d => db.open();

  /// Build the attendance board for [date] and an optional [batchId].
  /// Lists active students (optionally filtered by batch) merged with any
  /// existing marks for that date, exactly like the previous API contract.
  Future<AttendanceDay> getAttendanceDay(String date, {int? batchId}) async {
    final d = await _d;
    final marks = await d.query('attendance',
        where: 'attendance_date = ? AND deleted_at IS NULL',
        whereArgs: [date]);

    final studentsWhere = <String>['s.is_active = 1', 's.deleted_at IS NULL'];
    final studentsArgs = <Object?>[];
    if (batchId != null) {
      studentsWhere.add('s.batch_id = ?');
      studentsArgs.add(batchId);
    }
    final students = await d.rawQuery('''
      SELECT s.*, b.name AS batch_name
      FROM students s
      LEFT JOIN batches b ON b.id = s.batch_id AND b.deleted_at IS NULL
      WHERE ${studentsWhere.join(' AND ')}
      ORDER BY s.first_name COLLATE NOCASE
    ''', studentsArgs);

    final marksByStudent = {for (final m in marks) m['student_id'] as int: m};
    String? batchName;
    if (batchId != null) {
      final b = await d.query('batches',
          where: 'id = ? AND deleted_at IS NULL',
          whereArgs: [batchId],
          limit: 1);
      if (b.isEmpty) throw RepoException('Batch not found');
      batchName = b.first['name'] as String;
    } else {
      batchName = 'All batches';
    }

    var present = 0, absent = 0, late = 0, unmarked = 0;
    final records = <AttendanceStudentRow>[];
    for (final s in students) {
      final mark = marksByStudent[s['id'] as int];
      final status = mark?['status'] as String?;
      switch (status) {
        case 'present':
          present++;
        case 'late':
          late++;
        case 'absent':
          absent++;
        default:
          unmarked++;
      }
      records.add(AttendanceStudentRow(
        studentId: s['id'] as int,
        studentName: _names(s),
        batchId: s['batch_id'] as int?,
        batchName: (s['batch_name'] as String?) ?? batchName,
        status: status,
        attendanceId: mark == null ? null : mark['id'] as int,
        notes: mark?['notes'] as String?,
      ));
    }
    // Group by batch while keeping the alphabetical order inside each batch
    // (Dart's sort is not stable, so the name is part of the comparison).
    records.sort((a, b) {
      final byBatch = (a.batchName ?? '').compareTo(b.batchName ?? '');
      if (byBatch != 0) return byBatch;
      return a.studentName.toLowerCase().compareTo(b.studentName.toLowerCase());
    });
    final total = records.length;
    return AttendanceDay(
      date: date,
      batchId: batchId ?? 0,
      batchName: batchName,
      total: total,
      present: present,
      absent: absent,
      late: late,
      unmarked: unmarked,
      percentage: total == 0 ? 0 : ((present + late) / total * 100).clamp(0, 100).toDouble(),
      records: records,
    );
  }

  /// Upsert attendance marks for a batch/date; recompute monthly aggregates
  /// inside the same transaction so summaries are always consistent.
  Future<AttendanceDay> saveAttendanceDay({
    required String date,
    required int batchId,
    required List<Map<String, dynamic>> records,
  }) async {
    final d = await _d;
    await d.transaction((txn) async {
      final batch = await txn.query('batches',
          where: 'id = ? AND deleted_at IS NULL',
          whereArgs: [batchId],
          limit: 1);
      if (batch.isEmpty) throw RepoException('Batch not found');

      final seen = <int>{};
      for (final r in records) {
        final studentId = r['student_id'] as int;
        if (!seen.add(studentId)) {
          throw RepoException('Duplicate student_id $studentId');
        }
        final student = await txn.query('students',
            where: 'id = ? AND deleted_at IS NULL',
            whereArgs: [studentId],
            limit: 1);
        if (student.isEmpty) {
          throw RepoException('Student $studentId does not exist');
        }
        final status = r['status'] as String? ?? '';
        if (!const {'present', 'absent', 'late'}.contains(status)) {
          throw RepoException('Invalid attendance status "$status"');
        }
        // Deliberately NOT filtered on deleted_at: `attendance` is UNIQUE
        // (student_id, attendance_date), so a previously deleted mark has to be
        // found and revived here. Inserting a second row would fail, and
        // updating without clearing deleted_at would save a mark that no screen
        // can see.
        final existing = await txn.query('attendance',
            where: 'student_id = ? AND attendance_date = ?',
            whereArgs: [studentId, date],
            limit: 1);
        if (existing.isEmpty) {
          await txn.insert('attendance', {
            'student_id': studentId,
            'batch_id': batchId,
            'attendance_date': date,
            'status': status,
            'notes': r['notes'],
            ...SyncStamp.now(db).columns(),
          });
        } else {
          await txn.update('attendance', {
            'status': status,
            'batch_id': batchId,
            'notes': r['notes'] ?? existing.first['notes'],
            'deleted_at': null,
            ...SyncStamp.now(db).touchColumns(),
          }, where: 'id = ?', whereArgs: [existing.first['id']]);
        }
      }
      await _recomputeMonth(txn, date);
    });
    return getAttendanceDay(date, batchId: batchId);
  }

  Future<void> updateAttendanceStatus(int attendanceId, String status) async {
    final d = await _d;
    await d.transaction((txn) async {
      final rows = await txn.query('attendance',
          where: 'id = ? AND deleted_at IS NULL',
          whereArgs: [attendanceId],
          limit: 1);
      if (rows.isEmpty) throw RepoException('Attendance record not found');
      if (!const {'present', 'absent', 'late'}.contains(status)) {
        throw RepoException('Invalid attendance status "$status"');
      }
      await txn.update('attendance', {
        'status': status,
        ...SyncStamp.now(db).touchColumns(),
      },
          where: 'id = ?', whereArgs: [attendanceId]);
      await _recomputeMonth(txn, rows.first['attendance_date'] as String);
    });
  }

  Future<void> deleteAttendanceRecord(int attendanceId) async {
    final d = await _d;
    await d.transaction((txn) async {
      final rows = await txn.query('attendance',
          where: 'id = ? AND deleted_at IS NULL',
          whereArgs: [attendanceId],
          limit: 1);
      if (rows.isEmpty) throw RepoException('Attendance record not found');
      final date = rows.first['attendance_date'] as String;
      await txn.update('attendance', SyncStamp.now(db).tombstoneColumns(),
          where: 'id = ?', whereArgs: [attendanceId]);
      await _recomputeMonth(txn, date);
    });
  }

  /// Monthly aggregates for a month (optionally scoped to a batch).
  /// Recomputes from daily rows first so the numbers are always fresh.
  Future<List<MonthlyAttendanceSummary>> getMonthlyAttendance(
    String month, {
    int? batchId,
  }) async {
    final d = await _d;
    final monthIso = DbFmt.monthStart(month);
    await d.transaction((txn) async {
      await _recomputeMonth(txn, monthIso);
    });
    final conditions = <String>[
      'ma.month = ?',
      'ma.deleted_at IS NULL',
      's.deleted_at IS NULL',
    ];
    final args = <Object?>[monthIso];
    if (batchId != null) {
      conditions.add('s.batch_id = ?');
      // Appended, not inserted: the placeholders are bound in the order the
      // conditions appear, so inserting at the front would swap month and batch
      // and the batch filter would never match anything.
      args.add(batchId);
    }
    final rows = await d.rawQuery('''
      SELECT ma.*, s.first_name, s.last_name, s.batch_id,
             b.name AS batch_name
      FROM monthly_attendance ma
      JOIN students s ON s.id = ma.student_id
      LEFT JOIN batches b ON b.id = s.batch_id AND b.deleted_at IS NULL
      WHERE ${conditions.join(' AND ')}
      ORDER BY s.first_name COLLATE NOCASE
    ''', args);
    return rows
        .map((r) => MonthlyAttendanceSummary(
              studentId: r['student_id'] as int,
              studentName: _names(r),
              batchId: r['batch_id'] as int?,
              batchName: r['batch_name'] as String?,
              month: monthIso,
              totalClasses: (r['total_classes'] as int?) ?? 0,
              presents: (r['presents'] as int?) ?? 0,
              absents: (r['absents'] as int?) ?? 0,
              lates: (r['lates'] as int?) ?? 0,
              percentage: ((r['percentage'] as num?) ?? 0).toDouble(),
            ))
        .toList();
  }

  /// Recompute the monthly aggregate for a date's month for every student
  /// with marks in that month, and mirror the attendance percentage into
  /// monthly_progress (same behaviour as the previous backend).
  Future<void> _recomputeMonth(Transaction txn, String date) async {
    final dateObj = DateTime.tryParse(date);
    if (dateObj == null) return;
    final start = DbFmt.month(dateObj);
    final end = DbFmt.date(DbFmt.addMonths(dateObj, 1));

    // Students with marks in the month UNION students that already have an
    // aggregate for it. The second half matters after a deletion: without it a
    // student whose last mark for the month was removed would keep the old
    // totals forever, because nothing would visit their row again.
    final studentRows = await txn.rawQuery('''
      SELECT student_id FROM attendance
      WHERE deleted_at IS NULL
        AND attendance_date >= ? AND attendance_date < ?
      UNION
      SELECT student_id FROM monthly_attendance
      WHERE deleted_at IS NULL AND month = ?
    ''', [start, end, start]);

    for (final sr in studentRows) {
      final studentId = sr['student_id'] as int;
      final marks = await txn.query('attendance',
          where: 'student_id = ? AND deleted_at IS NULL '
              'AND attendance_date >= ? AND attendance_date < ?',
          whereArgs: [studentId, start, end]);
      var presents = 0, lates = 0, absents = 0;
      for (final m in marks) {
        switch (m['status'] as String) {
          case 'present':
            presents++;
          case 'late':
            lates++;
          case 'absent':
            absents++;
        }
      }
      final total = marks.length;
      final pct =
          total == 0 ? 0.0 : ((presents + lates) / total * 100).clamp(0, 100).toDouble();
      // No deleted_at filter: `monthly_attendance` is UNIQUE
      // (student_id, month), so a tombstoned aggregate must be found and
      // revived rather than inserted alongside.
      final existing = await txn.query('monthly_attendance',
          where: 'student_id = ? AND month = ?',
          whereArgs: [studentId, start],
          limit: 1);
      final stamp = SyncStamp.now(db);
      if (total == 0) {
        // Every mark for the month is gone: retire the aggregate instead of
        // leaving a "0 classes" row in the monthly summary.
        if (existing.isNotEmpty && existing.first['deleted_at'] == null) {
          await txn.update('monthly_attendance', stamp.tombstoneColumns(),
              where: 'id = ?', whereArgs: [existing.first['id']]);
        }
      } else if (existing.isEmpty) {
        await txn.insert('monthly_attendance', {
          'student_id': studentId,
          'month': start,
          'total_classes': total,
          'presents': presents,
          'absents': absents,
          'lates': lates,
          'percentage': pct,
          ...stamp.columns(),
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      } else {
        await txn.update('monthly_attendance', {
          'total_classes': total,
          'presents': presents,
          'absents': absents,
          'lates': lates,
          'percentage': pct,
          'deleted_at': null,
          ...stamp.touchColumns(),
        }, where: 'id = ?', whereArgs: [existing.first['id']]);
      }
      // Sync attendance percentage into that month's progress record if any.
      // `updated_at` moves with it, otherwise the peer would keep the stale
      // percentage after the next merge.
      await txn.rawUpdate('''
        UPDATE monthly_progress SET attendance_percentage = ?,
               updated_at = ?, device_id = ?
        WHERE student_id = ? AND month = ? AND deleted_at IS NULL
      ''', [pct, stamp.updatedAt, stamp.deviceId, studentId, start]);
    }
  }

  String _names(Map<String, Object?> row) {
    final first = (row['first_name'] as String?) ?? '';
    final last = (row['last_name'] as String?) ?? '';
    return '$first $last'.trim();
  }
}