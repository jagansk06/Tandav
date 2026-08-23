import 'package:sqflite/sqflite.dart' hide Batch;

import '../database/db_helpers.dart';
import '../database/tandav_database.dart';
import '../models/batch.dart';
import '../sync/sync_codec.dart';
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
    if (rows.isEmpty) throw const RepoException('Batch not found');
    return _batchFromRow(rows.first);
  }

  /// Create a batch, or revive one that was deleted under the same name.
  ///
  /// `batches.name` is UNIQUE and a deleted batch keeps its row as a tombstone
  /// (so the deletion can reach the other device), which means a plain insert
  /// fails with a constraint error the moment the studio re-creates a batch it
  /// had removed — and the batch would never appear in the list or in the
  /// Attendance picker. Reviving the tombstone keeps the name usable and keeps
  /// the record's sync identity, so the other device updates its copy instead
  /// of ending up with a duplicate.
  Future<Batch> createBatch(Map<String, dynamic> payload) async {
    final d = await _d;
    final values = _payloadToRow(payload);
    final id = await d.transaction<int>((txn) async {
      final existing = await txn.query('batches',
          columns: ['id', 'deleted_at'],
          where: 'name = ?',
          whereArgs: [values['name']],
          limit: 1);
      if (existing.isEmpty) {
        return txn.insert('batches', {
          ...values,
          ...SyncStamp.now(db).columns(),
        });
      }
      if (existing.first['deleted_at'] == null) {
        throw const RepoException('A batch with that name already exists');
      }
      final revivedId = existing.first['id'] as int;
      await txn.update('batches', {
        ...values,
        'deleted_at': null,
        ...SyncStamp.now(db).touchColumns(),
      }, where: 'id = ?', whereArgs: [revivedId]);
      return revivedId;
    });
    return getBatch(id);
  }

  /// Apply an edit, writing only the fields present in [payload].
  Future<Batch> updateBatch(int id, Map<String, dynamic> payload) async {
    final d = await _d;
    final values = _payloadToRow(payload, partial: true);
    await d.transaction((txn) async {
      final name = values['name'];
      if (name != null) {
        // The UNIQUE index covers tombstones too, so renaming onto a deleted
        // batch's name would fail the constraint. The tombstone's name is dead
        // metadata — the peer matches it by `sync_uuid` — so it is moved out of
        // the way rather than blocking a name the studio wants to reuse.
        final clash = await txn.query('batches',
            columns: ['id', 'deleted_at', 'sync_uuid'],
            where: 'name = ? AND id <> ?',
            whereArgs: [name, id],
            limit: 1);
        if (clash.isNotEmpty) {
          if (clash.first['deleted_at'] == null) {
            throw const RepoException('A batch with that name already exists');
          }
          final freed = clash.first['id'] as int;
          await txn.update(
              'batches',
              {
                'name': SyncCodec.parkedBatchName(
                    freed, clash.first['sync_uuid']),
              },
              where: 'id = ?',
              whereArgs: [freed]);
        }
      }
      final updated = await txn.update('batches', {
        ...values,
        ...SyncStamp.now(db).touchColumns(),
      }, where: 'id = ? AND deleted_at IS NULL', whereArgs: [id]);
      if (updated == 0) throw const RepoException('Batch not found');
    });
    return getBatch(id);
  }

  /// Soft delete: tombstone the batch and unassign its students (matching the
  /// original cascade-SET-NULL behaviour), while keeping the batch row so the
  /// deletion can synchronize to the other device.
  ///
  /// Both writes happen in one transaction, and the students are *stamped* as
  /// changed. Clearing `batch_id` without moving `updated_at` would leave the
  /// unassignment invisible to sync: the other device would apply the batch
  /// tombstone but keep its students pointing at a batch that no longer
  /// exists, so the two devices would disagree about who is in which batch.
  Future<void> deleteBatch(int id) async {
    final d = await _d;
    final updated = await d.transaction((txn) async {
      final stamp = SyncStamp.now(db);
      final rows = await txn.update('batches', {
        'is_active': 0,
        ...stamp.tombstoneColumns(),
      }, where: 'id = ? AND deleted_at IS NULL', whereArgs: [id]);
      if (rows == 0) return 0;
      await txn.update('students', {
        'batch_id': null,
        ...stamp.touchColumns(),
      }, where: 'batch_id = ? AND deleted_at IS NULL', whereArgs: [id]);
      // Events and attendance marks reference the batch too; the FK is
      // ON DELETE SET NULL / CASCADE on a real delete, which a tombstone never
      // triggers, so the reference is cleared explicitly. Attendance history is
      // preserved — only the batch label is dropped.
      await txn.update('events', {
        'batch_id': null,
        ...stamp.touchColumns(),
      }, where: 'batch_id = ? AND deleted_at IS NULL', whereArgs: [id]);
      await txn.update('attendance', {
        'batch_id': null,
        ...stamp.touchColumns(),
      }, where: 'batch_id = ? AND deleted_at IS NULL', whereArgs: [id]);
      return rows;
    });
    if (updated == 0) throw const RepoException('Batch not found');
  }

  /// Map an API payload onto batch columns. With [partial] set, only the keys
  /// the caller actually sent are written, so an edit cannot blank the fields
  /// its form does not carry.
  Map<String, Object?> _payloadToRow(
    Map<String, dynamic> payload, {
    bool partial = false,
  }) {
    final row = <String, Object?>{};
    bool has(String key) => !partial || payload.containsKey(key);

    if (has('name')) {
      // NOT NULL in the schema, so validate instead of casting: an unchecked
      // cast surfaces in the UI as an unreadable type error.
      final name = (payload['name'] as String?)?.trim() ?? '';
      if (name.isEmpty) throw const RepoException('Batch name is required');
      row['name'] = name;
    }
    if (has('dance_style')) row['dance_style'] = payload['dance_style'] ?? '';
    if (has('level')) row['level'] = payload['level'] ?? '';
    if (has('schedule')) row['schedule'] = payload['schedule'] ?? '';
    if (has('monthly_fee')) row['monthly_fee'] = _fee(payload['monthly_fee']);
    if (has('is_active')) {
      row['is_active'] = payload['is_active'] == false ? 0 : 1;
    }
    if (has('notes')) row['notes'] = payload['notes'];
    return row;
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