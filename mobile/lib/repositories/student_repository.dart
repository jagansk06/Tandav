import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../database/db_helpers.dart';
import '../database/tandav_database.dart';
import '../models/student.dart';
import '../platform/app_files.dart';
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
      LEFT JOIN batches b ON b.id = s.batch_id
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
      LEFT JOIN batches b ON b.id = s.batch_id
      WHERE s.id = ? AND s.deleted_at IS NULL
    ''', [id]);
    if (rows.isEmpty) throw RepoException('Student not found');
    return _studentFromRow(rows.first);
  }

  Future<Student> createStudent(Map<String, dynamic> payload) async {
    final d = await _d;
    final id = await d.insert('students', {
      ..._payloadToRow(payload),
      ...SyncStamp.now(db).columns(),
    });
    return getStudent(id);
  }

  Future<Student> updateStudent(int id, Map<String, dynamic> payload) async {
    final d = await _d;
    final row = {
      ..._payloadToRow(payload),
      ...SyncStamp.now(db).touchColumns(),
    };
    final updated = await d.update('students', row,
        where: 'id = ?', whereArgs: [id]);
    if (updated == 0) throw RepoException('Student not found');
    return getStudent(id);
  }

  /// Soft delete: the row becomes a tombstone so the deletion can reach the
  /// other Tandav device during sync instead of vanishing permanently.
  Future<void> deleteStudent(int id) async {
    final d = await _d;
    final stamp = SyncStamp.now(db);
    final updated = await d.update('students', {
      'is_active': 0,
      ...stamp.tombstoneColumns(),
    }, where: 'id = ?', whereArgs: [id]);
    if (updated == 0) throw RepoException('Student not found');
  }

  /// Copy a picked image into app documents and store the local path.
  ///
  /// Takes a path, not a `File`, so this file stays free of `dart:io` and
  /// compiles for the web. Android only — the caller checks
  /// `appFiles.supportsPhotos` first.
  Future<String> savePhoto(
    int studentId,
    String sourcePath,
    String filename,
  ) async {
    final d = await _d;
    final dir = await db.photosDir;
    final ext = p.extension(filename).isEmpty ? '.jpg' : p.extension(filename);
    final dest = p.join(dir, 'student_${studentId}_${DateTime.now().millisecondsSinceEpoch}$ext');
    await appFiles.copyFile(sourcePath, dest);
    await d.update('students', {
      'photo_url': dest,
      ...SyncStamp.now(db).touchColumns(),
    },
        where: 'id = ?', whereArgs: [studentId]);
    return dest;
  }

  Map<String, Object?> _payloadToRow(Map<String, dynamic> payload) => {
        'first_name': (payload['first_name'] as String).trim(),
        'last_name': (payload['last_name'] as String?) ?? '',
        'gender': (payload['gender'] as String?) ?? '',
        'dob': payload['dob'],
        'phone': (payload['phone'] as String?) ?? '',
        'email': payload['email'],
        'address': payload['address'],
        'emergency_contact_name': payload['emergency_contact_name'],
        'emergency_contact_phone': payload['emergency_contact_phone'],
        'batch_id': payload['batch_id'],
        'monthly_fee': _fee(payload['monthly_fee']),
        'join_date': (payload['join_date'] as String?) ?? DbFmt.date(DateTime.now()),
        'is_active': payload['is_active'] == false ? 0 : 1,
        'photo_url': payload['photo_url'],
        'notes': payload['notes'],
      };

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