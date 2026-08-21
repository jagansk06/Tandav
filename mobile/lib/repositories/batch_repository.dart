import 'package:sqflite/sqflite.dart' hide Batch;

import '../database/db_helpers.dart';
import '../database/tandav_database.dart';
import '../models/batch.dart';
import '../sync/sync_meta.dart';

class BatchRepository {
  final TandavDatabase db;
  BatchRepository(this.db);

  Future<Database> get _d => db.open();

  Future<BatchListResponse> getBatches({String? search, bool activeOnly = false}) async {
    final d = await _d;
    final where = <String>['b.deleted_at IS NULL'];
    final args = <Object?>[];
    if (search != null && search.trim().isNotEmpty) {
      where.add('b.name LIKE ?');
      args.add('%${search.trim()}%');
    }
    if (activeOnly) {
      where.add('b.is_active = 1');
    }
    final rows = await d.rawQuery('''
      SELECT b.*,
             (SELECT COUNT(*) FROM students s
              WHERE s.batch_id = b.id AND s.deleted_at IS NULL) AS student_count
      FROM batches b
      WHERE ${where.join(' AND ')}
      ORDER BY b.name COLLATE NOCASE
    ''', args);
    return BatchListResponse(
      items: rows.map(_batchFromRow).toList(),
      total: rows.length,
    );
  }

  Future<Batch> getBatch(int id) async {
    final d = await _d;
    final rows = await d.rawQuery('''
      SELECT b.*,
             (SELECT COUNT(*) FROM students s
              WHERE s.batch_id = b.id AND s.deleted_at IS NULL) AS student_count
      FROM batches b
      WHERE b.id = ? AND b.deleted_at IS NULL
    ''', [id]);
    if (rows.isEmpty) throw RepoException('Batch not found');
    return _batchFromRow(rows.first);
  }

  Future<Batch> createBatch(Map<String, dynamic> payload) async {
    final d = await _d;
    final id = await d.insert('batches', {
      'name': (payload['name'] as String).trim(),
      'dance_style': payload['dance_style'] ?? '',
      'level': payload['level'] ?? '',
      'schedule': payload['schedule'] ?? '',
      'monthly_fee': _fee(payload['monthly_fee']),
      'is_active': payload['is_active'] == false ? 0 : 1,
      'notes': payload['notes'],
      ...SyncStamp.now(db).columns(),
    });
    return getBatch(id);
  }

  Future<Batch> updateBatch(int id, Map<String, dynamic> payload) async {
    final d = await _d;
    final updated = await d.update('batches', {
      'name': (payload['name'] as String).trim(),
      'dance_style': payload['dance_style'] ?? '',
      'level': payload['level'] ?? '',
      'schedule': payload['schedule'] ?? '',
      'monthly_fee': _fee(payload['monthly_fee']),
      'is_active': payload['is_active'] == false ? 0 : 1,
      'notes': payload['notes'],
      ...SyncStamp.now(db).touchColumns(),
    }, where: 'id = ?', whereArgs: [id]);
    if (updated == 0) throw RepoException('Batch not found');
    return getBatch(id);
  }

  /// Soft delete: tombstone the batch and unassign its students (matching the
  /// original cascade-SET-NULL behaviour), while keeping the batch row so the
  /// deletion can synchronize to the other device.
  Future<void> deleteBatch(int id) async {
    final d = await _d;
    final stamp = SyncStamp.now(db);
    final updated = await d.update('batches', {
      'is_active': 0,
      ...stamp.tombstoneColumns(),
    }, where: 'id = ?', whereArgs: [id]);
    if (updated == 0) throw RepoException('Batch not found');
    await d.update('students', {'batch_id': null},
        where: 'batch_id = ?', whereArgs: [id]);
  }

  Batch _batchFromRow(Map<String, Object?> row) => Batch(
        id: row['id'] as int,
        name: row['name'] as String,
        danceStyle: (row['dance_style'] as String?) ?? '',
        level: (row['level'] as String?) ?? '',
        schedule: (row['schedule'] as String?) ?? '',
        monthlyFee: ((row['monthly_fee'] as num?) ?? 0).toString(),
        isActive: (row['is_active'] as int? ?? 1) == 1,
        notes: row['notes'] as String?,
        studentCount: (row['student_count'] as int?) ?? 0,
      );

  double _fee(Object? v) {
    final n = double.tryParse(v?.toString() ?? '');
    return n == null ? 0 : DbFmt.round2(n);
  }
}