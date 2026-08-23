import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../database/db_helpers.dart';
import '../database/tandav_database.dart';
import '../models/student.dart';
import '../platform/tandav_platform.dart';
import '../sync/sync_meta.dart';

class StudentRepository {
  final TandavDatabase db;
  StudentRepository(this.db);

  Future<Database> get _d => db.open();

  Future<StudentListResponse> getStudents({
    String? q,
    int? batchId,
    bool activeOnly = false,
    String? gender,
  }) async {
    final d = await _d;
    final where = <String>[];
    final args = <Object?>[];
    if (q != null && q.trim().isNotEmpty) {
      final like = '%${q.trim()}%';
      where.add(
          '(s.first_name LIKE ? OR s.last_name LIKE ? OR s.phone LIKE ? OR '
          's.email LIKE ?)');
      args.addAll([like, like, like, like]);
    }
    if (batchId != null) {
      where.add('s.batch_id = ?');
      args.add(batchId);
    }
    if (activeOnly) {
      where.add('s.is_active = 1');
    }
    if (gender != null && gender.isNotEmpty) {
      where.add('s.gender = ?');
      args.add(gender);
    }
    final rows = await d.rawQuery('''
      SELECT s.*, b.name AS batch_name
      FROM students s
      LEFT JOIN batches b ON b.id = s.batch_id AND b.deleted_at IS NULL
      WHERE s.deleted_at IS NULL
      ${where.isEmpty ? '' : 'AND ${where.join(' AND ')}'}
      ORDER BY s.first_name COLLATE NOCASE
    ''', args);
    return StudentListResponse(
      items: rows.map(_studentFromRow).toList(),
      total: rows.length,
    );
  }

  Future<Student> getStudent(int id) async {
    final d = await _d;
    final rows = await d.rawQuery('''
      SELECT s.*, b.name AS batch_name
      FROM students s
      LEFT JOIN batches b ON b.id = s.batch_id AND b.deleted_at IS NULL
      WHERE s.id = ? AND s.deleted_at IS NULL
    ''', [id]);
    if (rows.isEmpty) throw const RepoException('Student not found');
    return _studentFromRow(rows.first);
  }

  Future<Student> createStudent(Map<String, dynamic> payload) async {
    final d = await _d;
    final row = _payloadToRow(payload);
    await _assertBatchExists(d, row['batch_id']);
    final id = await d.insert('students', {
      ...row,
      ...SyncStamp.now(db).columns(),
    });
    return getStudent(id);
  }

  /// Apply an edit. Only the fields present in [payload] are written, so a
  /// screen that does not carry a column (the form has no photo field, for
  /// instance) cannot blank it out.
  Future<Student> updateStudent(int id, Map<String, dynamic> payload) async {
    final d = await _d;
    final row = {
      ..._payloadToRow(payload, partial: true),
      ...SyncStamp.now(db).touchColumns(),
    };
    if (payload.containsKey('batch_id')) {
      await _assertBatchExists(d, row['batch_id']);
    }
    final updated = await d.update('students', row,
        where: 'id = ? AND deleted_at IS NULL', whereArgs: [id]);
    if (updated == 0) throw const RepoException('Student not found');
    return getStudent(id);
  }

  /// A batch that was deleted (possibly on the other device, arriving in a sync
  /// while the form was open) would otherwise fail as a foreign-key error or
  /// leave the student pointing at a tombstone.
  Future<void> _assertBatchExists(Database d, Object? batchId) async {
    if (batchId == null) return;
    final rows = await d.query('batches',
        columns: ['id'],
        where: 'id = ? AND deleted_at IS NULL',
        whereArgs: [batchId],
        limit: 1);
    if (rows.isEmpty) {
      throw const RepoException(
          'That batch no longer exists. Pick another batch.');
    }
  }

  /// Soft delete: the row becomes a tombstone so the deletion can reach the
  /// other Tandav device during sync instead of vanishing permanently.
  ///
  /// The student's own records are tombstoned in the same transaction. The
  /// schema cascades on a real DELETE, but a soft delete triggers nothing — so
  /// without this the attendance marks, fees and payments of a deleted student
  /// would stay live, ship to the other device and keep turning up in totals
  /// there as rows whose student no longer exists.
  Future<void> deleteStudent(int id) async {
    final d = await _d;
    final updated = await d.transaction((txn) async {
      final stamp = SyncStamp.now(db);
      final rows = await txn.update('students', {
        'is_active': 0,
        ...stamp.tombstoneColumns(),
      }, where: 'id = ? AND deleted_at IS NULL', whereArgs: [id]);
      if (rows == 0) return 0;
      for (final table in const [
        'attendance',
        'monthly_attendance',
        'fees',
        'fee_payments',
        'event_participations',
        'monthly_progress',
      ]) {
        await txn.update(table, stamp.tombstoneColumns(),
            where: 'student_id = ? AND deleted_at IS NULL', whereArgs: [id]);
      }
      return rows;
    });
    if (updated == 0) throw const RepoException('Student not found');
  }

  /// Store a picked image for this student and remember where it went.
  ///
  /// The returned handle is a file path in the Android app and inline image
  /// bytes in the browser — the platform decides. It stays on this device:
  /// `photo_url` is never uploaded to Drive, because the other device cannot
  /// use it and photos are not part of the studio data being synchronized.
  Future<String> savePhoto(
    int studentId,
    Uint8List bytes,
    String filename,
  ) async {
    final d = await _d;
    final handle = await tandavPlatform.storePhoto(
      studentId: studentId,
      bytes: bytes,
      filename: filename,
    );
    await d.update(
      'students',
      {
        'photo_url': handle,
        ...SyncStamp.now(db).touchColumns(),
      },
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: [studentId],
    );
    return handle;
  }

  /// Map an API payload onto student columns.
  ///
  /// With [partial] set, only the keys the caller actually sent are written —
  /// what an edit needs. Writing the whole row on an update would blank every
  /// column the caller omitted; `photo_url` is the one that hurts, since the
  /// student form has no photo field and would therefore erase the photo on
  /// every save.
  Map<String, Object?> _payloadToRow(
    Map<String, dynamic> payload, {
    bool partial = false,
  }) {
    final row = <String, Object?>{};
    bool has(String key) => !partial || payload.containsKey(key);

    if (has('first_name')) {
      final first = (payload['first_name'] as String?)?.trim() ?? '';
      if (first.isEmpty) throw const RepoException('First name is required');
      row['first_name'] = first;
    }
    if (has('last_name')) {
      row['last_name'] = (payload['last_name'] as String?)?.trim() ?? '';
    }
    if (has('gender')) row['gender'] = (payload['gender'] as String?) ?? '';
    if (has('dob')) row['dob'] = payload['dob'];
    if (has('phone')) {
      row['phone'] = (payload['phone'] as String?)?.trim() ?? '';
    }
    if (has('email')) row['email'] = payload['email'];
    if (has('address')) row['address'] = payload['address'];
    if (has('emergency_contact_name')) {
      row['emergency_contact_name'] = payload['emergency_contact_name'];
    }
    if (has('emergency_contact_phone')) {
      row['emergency_contact_phone'] = payload['emergency_contact_phone'];
    }
    if (has('batch_id')) row['batch_id'] = payload['batch_id'];
    if (has('monthly_fee')) row['monthly_fee'] = _fee(payload['monthly_fee']);
    if (has('join_date')) {
      row['join_date'] =
          (payload['join_date'] as String?) ?? DbFmt.date(DateTime.now());
    }
    if (has('is_active')) {
      row['is_active'] = payload['is_active'] == false ? 0 : 1;
    }
    if (has('photo_url')) row['photo_url'] = payload['photo_url'];
    if (has('notes')) row['notes'] = payload['notes'];
    return row;
  }

  double _fee(Object? v) {
    final n = double.tryParse(v?.toString() ?? '');
    return n == null ? 0 : DbFmt.round2(n);
  }

  Student _studentFromRow(Map<String, Object?> row) => Student(
        id: row['id'] as int,
        firstName: row['first_name'] as String,
        lastName: (row['last_name'] as String?) ?? '',
        gender: (row['gender'] as String?) ?? '',
        dob: row['dob'] as String?,
        phone: (row['phone'] as String?) ?? '',
        email: row['email'] as String?,
        address: row['address'] as String?,
        emergencyContactName: row['emergency_contact_name'] as String?,
        emergencyContactPhone: row['emergency_contact_phone'] as String?,
        batchId: row['batch_id'] as int?,
        batchName: row['batch_name'] as String?,
        monthlyFee: ((row['monthly_fee'] as num?) ?? 0).toString(),
        joinDate: row['join_date'] as String?,
        isActive: (row['is_active'] as int? ?? 1) == 1,
        photoUrl: row['photo_url'] as String?,
        notes: row['notes'] as String?,
      );
}