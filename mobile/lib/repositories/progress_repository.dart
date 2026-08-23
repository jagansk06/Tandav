import 'package:sqflite/sqflite.dart';

import '../database/db_helpers.dart';
import '../database/tandav_database.dart';
import '../models/progress.dart';
import '../sync/sync_meta.dart';

class ProgressRepository {
  final TandavDatabase db;
  ProgressRepository(this.db);

  Future<Database> get _d => db.open();

  static double overallScore(int skill, int performance, int discipline) {
    final scores = [skill, performance, discipline].where((s) => s > 0).toList();
    if (scores.isEmpty) return 0;
    return (scores.reduce((a, b) => a + b) / scores.length).clamp(0, 100).toDouble();
  }

  Future<MonthlyProgress> createProgress(int studentId, Map<String, dynamic> payload) async {
    final d = await _d;
    final month =
        DbFmt.monthStart(payload['month'] as String? ?? DbFmt.month(DateTime.now()));
    final students = await d.query('students',
        where: 'id = ? AND deleted_at IS NULL',
        whereArgs: [studentId],
        limit: 1);
    if (students.isEmpty) throw const RepoException('Student not found');
    // Not filtered on deleted_at: `monthly_progress` is UNIQUE
    // (student_id, month), so a deleted record has to be found and revived —
    // rejecting it as a duplicate would make that month unrecordable forever.
    final existing = await d.query('monthly_progress',
        where: 'student_id = ? AND month = ?',
        whereArgs: [studentId, month], limit: 1);
    if (existing.isNotEmpty && existing.first['deleted_at'] == null) {
      throw const RepoException('Progress already recorded for this month');
    }
    final skill = _rating(payload['skill_rating']);
    final perf = _rating(payload['performance_rating']);
    final disc = _rating(payload['discipline_rating']);
    final values = {
      'skill_rating': skill,
      'performance_rating': perf,
      'discipline_rating': disc,
      'attendance_percentage': await _attendancePct(d, studentId, month),
      'remarks': payload['remarks'],
    };
    final int id;
    if (existing.isEmpty) {
      id = await d.insert('monthly_progress', {
        'student_id': studentId,
        'month': month,
        ...values,
        ...SyncStamp.now(db).columns(),
      });
    } else {
      id = existing.first['id'] as int;
      await d.update('monthly_progress', {
        ...values,
        'deleted_at': null,
        ...SyncStamp.now(db).touchColumns(),
      }, where: 'id = ?', whereArgs: [id]);
    }
    final rows = await d.query('monthly_progress', where: 'id = ?', whereArgs: [id]);
    return _progressFromRow(rows.first);
  }

  Future<MonthlyProgress> updateProgress(
      int studentId, String month, Map<String, dynamic> payload) async {
    final d = await _d;
    final monthIso = DbFmt.monthStart(month);
    final existing = await d.query('monthly_progress',
        where: 'student_id = ? AND month = ? AND deleted_at IS NULL',
        whereArgs: [studentId, monthIso], limit: 1);
    if (existing.isEmpty) throw const RepoException('Progress record not found');
    final skill = _rating(payload['skill_rating'] ?? existing.first['skill_rating']);
    final perf = _rating(payload['performance_rating'] ?? existing.first['performance_rating']);
    final disc = _rating(payload['discipline_rating'] ?? existing.first['discipline_rating']);
    await d.update('monthly_progress', {
      'skill_rating': skill,
      'performance_rating': perf,
      'discipline_rating': disc,
      'remarks': payload['remarks'] ?? existing.first['remarks'],
      ...SyncStamp.now(db).touchColumns(),
    }, where: 'id = ?', whereArgs: [existing.first['id']]);
    final rows = await d.query('monthly_progress',
        where: 'id = ?', whereArgs: [existing.first['id']]);
    return _progressFromRow(rows.first);
  }

  Future<ProgressListResponse> getProgress({
    String? month,
    int? studentId,
    int? batchId,
  }) async {
    final d = await _d;
    final conditions = <String>[];
    final args = <Object?>[];
    if (month != null) {
      conditions.add('mp.month = ?');
      args.add(DbFmt.monthStart(month));
    }
    if (studentId != null) {
      conditions.add('mp.student_id = ?');
      args.add(studentId);
    }
    if (batchId != null) {
      conditions.add('s.batch_id = ?');
      args.add(batchId);
    }
    final rows = await d.rawQuery('''
      SELECT mp.*, s.first_name, s.last_name
      FROM monthly_progress mp
      JOIN students s ON s.id = mp.student_id
      ${conditions.isEmpty ? 'WHERE mp.deleted_at IS NULL AND s.deleted_at IS NULL' : 'WHERE ${conditions.join(' AND ')} AND mp.deleted_at IS NULL AND s.deleted_at IS NULL'}
      ORDER BY mp.month DESC, s.first_name COLLATE NOCASE
      LIMIT 500
    ''', args);
    return ProgressListResponse(
      items: rows.map(_progressFromRow).toList(),
      total: rows.length,
    );
  }

  Future<void> deleteProgress(int studentId, String month) async {
    final d = await _d;
    await d.update('monthly_progress', {
      ...SyncStamp.now(db).tombstoneColumns(),
    }, where: 'student_id = ? AND month = ? AND deleted_at IS NULL',
        whereArgs: [studentId, DbFmt.monthStart(month)]);
  }

  Future<double?> _attendancePct(Database d, int studentId, String month) async {
    final rows = await d.query('monthly_attendance',
        where: 'student_id = ? AND month = ? AND deleted_at IS NULL',
        whereArgs: [studentId, DbFmt.monthStart(month)], limit: 1);
    return rows.isEmpty ? null : (rows.first['percentage'] as num?)?.toDouble();
  }

  int _rating(Object? v) {
    final n = int.tryParse(v?.toString() ?? '');
    if (n == null) return 0;
    return n.clamp(0, 100);
  }

  MonthlyProgress _progressFromRow(Map<String, Object?> row) {
    final skill = (row['skill_rating'] as int?) ?? 0;
    final perf = (row['performance_rating'] as int?) ?? 0;
    final disc = (row['discipline_rating'] as int?) ?? 0;
    return MonthlyProgress(
      id: row['id'] as int,
      studentId: row['student_id'] as int,
      studentName: _names(row),
      month: row['month'] as String,
      skillRating: skill,
      performanceRating: perf,
      disciplineRating: disc,
      overallScore: overallScore(skill, perf, disc),
      attendancePercentage: (row['attendance_percentage'] as num?)?.toDouble(),
      remarks: row['remarks'] as String?,
    );
  }

  String _names(Map<String, Object?> row) {
    final first = (row['first_name'] as String?) ?? '';
    final last = (row['last_name'] as String?) ?? '';
    return '$first $last'.trim();
  }
}