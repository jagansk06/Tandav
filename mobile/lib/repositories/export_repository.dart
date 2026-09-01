import 'package:sqflite/sqflite.dart';

import '../database/db_helpers.dart';
import '../database/tandav_database.dart';

/// CSV exports so the studio can pull its data into Excel / Google Sheets.
///
/// Everything here is generated locally from SQLite and returned as CSV text —
/// no server, no paid library, no subscription. Each method takes the live
/// [Database] (open every call) so the export always reflects what is on this
/// phone right now.
///
/// CSV escaping follows the spreadsheet convention: fields containing a comma,
/// a double-quote or a line break are wrapped in double-quotes, and embedded
/// quotes are doubled.
class ExportRepository {
  final TandavDatabase db;
  ExportRepository(this.db);

  Future<Database> get _d => db.open();

  /// A header + BOM so Excel opens UTF-8 (₹ and accented names) correctly.
  String get _preamble => '\uFEFF';

  /// Escape a single CSV field per RFC 4180.
  String _f(Object? value) {
    final s = value?.toString() ?? '';
    if (s.contains(',') || s.contains('"') || s.contains('\n') || s.contains('\r')) {
      return '"${s.replaceAll('"', '""')}"';
    }
    return s;
  }

  String _row(List<Object?> cells) =>
      '${cells.map(_f).join(',')}\r\n';

  /// Every student with their batch, contact details and monthly fee —
  /// the master contact sheet.
  Future<String> exportStudents() async {
    final d = await _d;
    final rows = await d.rawQuery('''
      SELECT s.*, b.name AS batch_name, b.dance_style, b.schedule,
             b.monthly_fee AS batch_fee
      FROM students s
      LEFT JOIN batches b ON b.id = s.batch_id
      WHERE s.deleted_at IS NULL
      ORDER BY s.first_name COLLATE NOCASE
    ''');
    final out = StringBuffer(_preamble);
    out.write(_row([
      'Student Name', 'Gender', 'Date of Birth', 'Phone', 'Email', 'Address',
      'Batch', 'Dance Style', 'Schedule', 'Student Monthly Fee',
      'Guardian Name', 'Guardian Phone', 'Join Date', 'Status', 'Notes',
    ]));
    for (final r in rows) {
      out.write(_row([
        _name(r), r['gender'], r['dob'], r['phone'], r['email'], r['address'],
        r['batch_name'], r['dance_style'], r['schedule'],
        r['monthly_fee'], r['emergency_contact_name'],
        r['emergency_contact_phone'], r['join_date'],
        (r['is_active'] as int? ?? 1) == 1 ? 'Active' : 'Inactive',
        r['notes'],
      ]));
    }
    return out.toString();
  }

  /// Every batch with its default monthly fee and student headcount.
  Future<String> exportBatches() async {
    final d = await _d;
    final rows = await d.rawQuery('''
      SELECT b.*,
             (SELECT COUNT(*) FROM students s
              WHERE s.batch_id = b.id AND s.deleted_at IS NULL
                AND s.is_active = 1) AS student_count
      FROM batches b
      WHERE b.deleted_at IS NULL
      ORDER BY b.name COLLATE NOCASE
    ''');
    final out = StringBuffer(_preamble);
    out.write(_row([
      'Batch', 'Dance Style', 'Level', 'Schedule', 'Default Monthly Fee',
      'Active Students', 'Notes',
    ]));
    for (final r in rows) {
      out.write(_row([
        r['name'], r['dance_style'], r['level'], r['schedule'],
        r['monthly_fee'], r['student_count'], r['notes'],
      ]));
    }
    return out.toString();
  }

  /// Monthly fee register: one row per student-month with status and the
  /// amounts, so outstanding dues are easy to chase in a spreadsheet.
  Future<String> exportMonthlyFees({String? month}) async {
    final d = await _d;
    final where = <String>['f.deleted_at IS NULL', 's.deleted_at IS NULL'];
    final args = <Object?>[];
    if (month != null) {
      where.add('f.month = ?');
      args.add(_monthIso(month));
    }
    final rows = await d.rawQuery('''
      SELECT f.*, s.first_name, s.last_name, s.phone, b.name AS batch_name
      FROM fees f
      JOIN students s ON s.id = f.student_id
      LEFT JOIN batches b ON b.id = s.batch_id
      WHERE ${where.join(' AND ')}
      ORDER BY f.month DESC, s.first_name COLLATE NOCASE
    ''', args);
    final out = StringBuffer(_preamble);
    out.write(_row([
      'Month', 'Student Name', 'Batch', 'Phone', 'Amount Due',
      'Amount Paid', 'Outstanding', 'Status', 'Payment Date', 'Payment Method',
    ]));
    for (final r in rows) {
      final due = _fee(r['amount_due']);
      final paid = _fee(r['amount_paid']);
      out.write(_row([
        r['month'], _name(r), r['batch_name'], r['phone'],
        due.toStringAsFixed(2), paid.toStringAsFixed(2),
        (due - paid).toStringAsFixed(2), r['status'], r['payment_date'],
        r['payment_method'],
      ]));
    }
    return out.toString();
  }

  /// Attendance summary per student-month across a given month.
  Future<String> exportAttendance({String? month, int? batchId}) async {
    final d = await _d;
    final conditions = <String>['ma.month = ?'];
    final args = <Object?>[_monthIso(month ?? DbFmt.month(DateTime.now()))];
    if (batchId != null) {
      conditions.add('s.batch_id = ?');
      args.insert(0, batchId);
    }
    final rows = await d.rawQuery('''
      SELECT ma.*, s.first_name, s.last_name, s.phone, b.name AS batch_name
      FROM monthly_attendance ma
      JOIN students s ON s.id = ma.student_id
      LEFT JOIN batches b ON b.id = s.batch_id
      WHERE ${conditions.join(' AND ')}
      ORDER BY s.first_name COLLATE NOCASE
    ''', args);
    final out = StringBuffer(_preamble);
    out.write(_row([
      'Month', 'Student Name', 'Batch', 'Phone', 'Total Classes',
      'Present', 'Late', 'Absent', 'Attendance %',
    ]));
    for (final r in rows) {
      out.write(_row([
        r['month'], _name(r), r['batch_name'], r['phone'],
        r['total_classes'], r['presents'], r['lates'], r['absents'],
        r['percentage'],
      ]));
    }
    return out.toString();
  }

  String _name(Map<String, Object?> r) {
    final first = (r['first_name'] as String?) ?? '';
    final last = (r['last_name'] as String?) ?? '';
    return '$first $last'.trim();
  }

  double _fee(Object? v) {
    final n = double.tryParse(v?.toString() ?? '');
    return n == null ? 0 : DbFmt.round2(n);
  }

  String _monthIso(String month) =>
      month.replaceFirst(RegExp(r'-\d{2}$'), '-01');
}
