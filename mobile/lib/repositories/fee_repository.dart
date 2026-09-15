import 'package:sqflite/sqflite.dart';

import '../database/db_helpers.dart';
import '../database/tandav_database.dart';
import '../models/fee.dart';
import '../sync/sync_meta.dart';

/// Monthly fee system backed by SQLite.
///
/// - One row per student per month (`UNIQUE (student_id, month)`); each row's
///   `amount_due` is the student's **fixed monthly fee** — unpaid months carry
///   forward as an outstanding balance instead of inflating the next month.
/// - [ensureMonthlyFees] guarantees a fee record for the current month for
///   EVERY eligible active student — regardless of the generation watermark —
///   plus backfills any months missed while the app was closed. Idempotent,
///   runs locally on app start/resume and whenever the Fees screen opens
///   (no server, no cron).
/// - Payments settle the **oldest unpaid month first** (FIFO). [markFeePaid]
///   clears a student's whole outstanding up to the tapped month in one step;
///   [recordFeePayment] applies a specific amount oldest-first across months.
///   Every payment updates the per-month `amount_paid` columns and appends one
///   `fee_payments` ledger entry (the audit trail), so history and paid dates
///   are never lost.
class FeeRepository {
  final TandavDatabase db;
  FeeRepository(this.db);

  static const _watermarkKey = 'fee_watermark_month';

  /// `app_settings` key holding the fixed rupee amount added to the following
  /// month's fee when a student has not paid the previous month's fee.
  ///
  /// Retained read/write for backwards compatibility (an existing value stays
  /// in `app_settings` untouched), but **no longer applied**: unpaid months
  /// now carry forward as an outstanding balance and a month's fee stays fixed.
  static const lateFeePenaltyKey = 'late_fee_penalty';

  /// Default late-fee penalty when none has been configured (₹ 100).
  static const double defaultLateFeePenalty = 100;

  Future<Database> get _d => db.open();

  /// Read the configured late-fee penalty. Legacy: kept for compatibility but
  /// never applied to generated fees — unpaid months carry forward instead.
  Future<double> getLateFeePenalty() async {
    final d = await _d;
    final rows = await d.query('app_settings',
        where: 'key = ?', whereArgs: [lateFeePenaltyKey], limit: 1);
    if (rows.isEmpty) return defaultLateFeePenalty;
    final v = double.tryParse(rows.first['value']?.toString() ?? '');
    return v == null || v < 0 ? defaultLateFeePenalty : v;
  }

  /// Set the late-fee penalty. Legacy: the value is stored for backwards
  /// compatibility but never applied to generated fees.
  Future<void> setLateFeePenalty(double amount) async {
    final d = await _d;
    await d.insert('app_settings', {
      'key': lateFeePenaltyKey,
      'value': DbFmt.round2(amount < 0 ? 0 : amount).toString(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// `app_settings` key holding the studio's UPI ID (VPA), e.g.
  /// `tandav@okhdfcbank`. This is what a student scans/taps in the WhatsApp
  /// reminder to pay the fee into the studio's account.
  static const upiVpaKey = 'upi_vpa';

  /// `app_settings` key holding the payee display name shown on the UPI payment
  /// (normally the studio name, e.g. "Tandav Studio").
  static const upiPayeeKey = 'upi_payee';

  /// Read the studio's configured UPI ID, or null when none has been set.
  Future<String?> getUpiVpa() async {
    final d = await _d;
    final rows = await d.query('app_settings',
        where: 'key = ?', whereArgs: [upiVpaKey], limit: 1);
    if (rows.isEmpty) return null;
    final v = rows.first['value']?.toString().trim() ?? '';
    return v.isEmpty ? null : v;
  }

  /// Store the studio's UPI ID. An empty value clears it.
  Future<void> setUpiVpa(String vpa) async {
    final d = await _d;
    await d.insert('app_settings', {
      'key': upiVpaKey,
      'value': vpa.trim(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Read the payee display name shown on UPI payments, or null when unset.
  Future<String?> getUpiPayee() async {
    final d = await _d;
    final rows = await d.query('app_settings',
        where: 'key = ?', whereArgs: [upiPayeeKey], limit: 1);
    if (rows.isEmpty) return null;
    final v = rows.first['value']?.toString().trim() ?? '';
    return v.isEmpty ? null : v;
  }

  /// Store the payee display name. An empty value clears it.
  Future<void> setUpiPayee(String payee) async {
    final d = await _d;
    await d.insert('app_settings', {
      'key': upiPayeeKey,
      'value': payee.trim(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static String feeStatus(double due, double paid) {
    if (due > 0 && paid >= due - 0.001) return 'paid';
    if (paid > 0) return 'partial';
    return 'due';
  }

  /// Generate missing fee records for every month between the generation
  /// watermark and [now] (inclusive), and ALWAYS ensure the current month has
  /// a record for every eligible active student — students added to a batch
  /// mid-month appear in the fee register without any manual fee creation.
  /// Each month is inserted with INSERT OR IGNORE so duplicates are
  /// impossible. Returns the number of new records created.
  Future<int> ensureMonthlyFees(DateTime now, {DateTime? anchor}) async {
    final d = await _d;
    final target = DbFmt.firstOfMonth(now);

    final settingRows = await d.query('app_settings',
        where: 'key = ?', whereArgs: [_watermarkKey], limit: 1);
    DateTime? lastGenerated;
    final raw = settingRows.isEmpty ? null : settingRows.first['value'] as String?;
    if (raw != null) {
      final parsed = DateTime.tryParse(raw);
      if (parsed != null && parsed.isAfter(target)) {
        // The watermark is already ahead of the requested month (e.g. the
        // user is viewing an older month): nothing to generate, and we must
        // never move the watermark backwards.
        return 0;
      }
      if (parsed != null) lastGenerated = parsed;
    }

    // Months to fill: from the month after the watermark (or the anchor/target
    // if no watermark yet) through the target.
    final start =
        lastGenerated == null ? (anchor ?? target) : DbFmt.addMonths(lastGenerated, 1);

    var created = 0;
    await d.transaction((txn) async {
      // Backfill any months missed while the app was closed (and the target
      // month when it has not been generated yet).
      for (final m in DbFmt.monthsBetween(start, target)) {
        created += await _insertMonthFees(txn, m);
      }
      // Current-month guarantee: every eligible active student must have a
      // record for the target month even if they were added after the month's
      // records were first generated (the watermark already moved past the
      // backfill window). INSERT OR IGNORE keeps this idempotent.
      created += await _insertMonthFees(txn, target);
      await txn.insert('app_settings', {'key': _watermarkKey, 'value': DbFmt.month(target)},
          conflictAlgorithm: ConflictAlgorithm.replace);
    });
    return created;
  }

  /// Create DUE fee records for [month] for every active student with a
  /// non-zero fee who joined on or before that month. Returns the number of
  /// newly inserted rows (existing records are never duplicated).
  ///
  /// `amount_due` is always the student's fixed monthly fee (the value on the
  /// student record at generation time). Unpaid earlier months are NOT added
  /// on top: the outstanding balance carries forward separately, so the total
  /// the register shows grows month to month while each row's own fee stays
  /// legible.
  Future<int> _insertMonthFees(Transaction txn, DateTime month) async {
    final nextMonth = DbFmt.addMonths(month, 1);
    final students = await txn.query('students',
        where: 'is_active = 1 AND monthly_fee > 0 AND join_date < ?',
        whereArgs: [DbFmt.date(nextMonth)]);
    var created = 0;
    for (final s in students) {
      final inserted = await txn.insert('fees', {
        'student_id': s['id'],
        'month': DbFmt.month(month),
        'amount_due': _fee(s['monthly_fee']),
        'amount_paid': 0,
        'status': 'due',
        ...SyncStamp.now(db).columns(),
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      if (inserted != 0) created++;
    }
    return created;
  }

  Future<FeeListResponse> getFees({
    String? month,
    int? studentId,
    int? batchId,
    String? status,
    String? q,
  }) async {
    if (month != null) {
      await ensureMonthWithFees(month);
    }
    final d = await _d;
    final where = <String>[];
    final args = <Object?>[];
    if (month != null) {
      where.add('f.month = ?');
      args.add(_monthIso(month));
    }
    if (studentId != null) {
      where.add('f.student_id = ?');
      args.add(studentId);
    }
    if (batchId != null) {
      where.add('s.batch_id = ?');
      args.add(batchId);
    }
    if (status != null && status.isNotEmpty) {
      where.add('f.status = ?');
      args.add(status);
    }
    if (q != null && q.trim().isNotEmpty) {
      final like = '%${q.trim()}%';
      where.add('(s.first_name LIKE ? OR s.last_name LIKE ?)');
      args.addAll([like, like]);
    }
    final rows = await d.rawQuery('''
      SELECT f.*, s.first_name, s.last_name
      FROM fees f
      JOIN students s ON s.id = f.student_id
      WHERE f.deleted_at IS NULL AND s.deleted_at IS NULL
      ${where.isEmpty ? '' : 'AND ${where.join(' AND ')}'}
      ORDER BY f.month DESC, s.first_name COLLATE NOCASE
    ''', args);
    // Each row carries the student's carry-forward balance through the month —
    // the figure the register actually chases — alongside its own due/paid.
    final items = <Fee>[];
    for (final r in rows) {
      final running = await _runningOutstanding(
          d, r['student_id'] as int, (r['month'] as String?) ?? '');
      items.add(_feeFromRow(r, s: _names(r), runningOutstanding: running));
    }
    return FeeListResponse(
      items: items,
      total: rows.length,
    );
  }

  Future<FeeSummary> getFeeSummary(String month, {int? batchId}) async {
    await ensureMonthWithFees(month);
    final d = await _d;
    final args = <Object?>[];
    var join = '';
    if (batchId != null) {
      join = 'JOIN students s ON s.id = f.student_id AND s.batch_id = ?';
      args.add(batchId);
    }
    args.add(_monthIso(month));
    final rows = await d.rawQuery('''
      SELECT f.* FROM fees f $join WHERE f.month = ? AND f.deleted_at IS NULL
    ''', args);
    var totalDue = 0.0, totalPaid = 0.0, pending = 0.0;
    var paid = 0, partial = 0, due = 0;
    for (final r in rows) {
      final dueV = _fee(r['amount_due']);
      final paidV = _fee(r['amount_paid']);
      totalDue += dueV;
      totalPaid += paidV;
      // Carry-forward: what this batch/studio is really owed through this
      // month is every student's running unpaid balance, not just this
      // month's shortfall.
      pending = DbFmt.round2(pending +
          await _runningOutstanding(
              d, r['student_id'] as int, (r['month'] as String?) ?? ''));
      final st = feeStatus(dueV, paidV);
      if (st == 'paid') paid++;
      if (st == 'partial') partial++;
      if (st == 'due') due++;
    }
    return FeeSummary(
      month: _monthIso(month),
      totalDue: totalDue.toStringAsFixed(2),
      totalPaid: totalPaid.toStringAsFixed(2),
      outstanding: pending.toStringAsFixed(2),
      paidCount: paid,
      partialCount: partial,
      dueCount: due,
      totalRecords: rows.length,
      collectionRate:
          totalDue == 0 ? 0.0 : (totalPaid / totalDue * 100).clamp(0, 100).toDouble(),
    );
  }

  /// Fee records for a specific student's *current* month (auto-created if the
  /// student is eligible), used by student profiles.
  Future<Fee> studentFeeForMonth(int studentId, DateTime month) async {
    final target = DbFmt.month(month);
    final d = await _d;
    var rows = await d.query('fees',
        where: 'student_id = ? AND month = ?',
        whereArgs: [studentId, target]);
    if (rows.isEmpty) {
      final students = await d.query('students',
          where: 'id = ? AND is_active = 1 AND monthly_fee > 0',
          whereArgs: [studentId]);
      if (students.isNotEmpty) {
        await d.insert('fees', {
          'student_id': studentId,
          'month': target,
          'amount_due': _fee(students.first['monthly_fee']),
          'amount_paid': 0,
          'status': 'due',
          ...SyncStamp.now(db).columns(),
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
        rows = await d.query('fees',
            where: 'student_id = ? AND month = ?',
            whereArgs: [studentId, target]);
      }
    }
    if (rows.isEmpty) {
      throw RepoException('Fee record not found for this month');
    }
    final row = rows.first;
    final s = await d.query('students',
        where: 'id = ?', whereArgs: [studentId], limit: 1);
    final studentName = s.isEmpty ? '' : _names(s.first);
    final running =
        await _runningOutstanding(d, studentId, row['month'] as String? ?? '');
    return _feeFromRow(row, s: studentName, runningOutstanding: running);
  }

  /// The student's unpaid balance carried forward through [monthStart]
  /// (inclusive): the sum of `amount_due − amount_paid` over every non-deleted
  /// record up to and including that month.
  Future<double> _runningOutstanding(
      DatabaseExecutor d, int studentId, String monthStart) async {
    if (monthStart.isEmpty) return 0;
    final rows = await d.rawQuery('''
      SELECT COALESCE(SUM(amount_due - amount_paid), 0) AS total
      FROM fees
      WHERE student_id = ? AND month <= ? AND deleted_at IS NULL
    ''', [studentId, monthStart]);
    return _fee(rows.isEmpty ? null : rows.first['total']);
  }

  /// The student's non-deleted fee rows through [monthStart], oldest month
  /// first, for FIFO payment allocation.
  Future<List<Map<String, Object?>>> _unpaidUpTo(
      Transaction txn, int studentId, String monthStart) async {
    final unpaid = await txn.rawQuery('''
      SELECT f.* FROM fees f
      WHERE f.student_id = ? AND f.month <= ? AND f.deleted_at IS NULL
      ORDER BY f.month ASC
    ''', [studentId, monthStart]);
    return unpaid
        .where((r) => _fee(r['amount_due']) - _fee(r['amount_paid']) > 0.001)
        .toList();
  }

  /// Build the [Fee] for [row] from inside a transaction, attaching the
  /// student's carry-forward balance through that row's month.
  Future<Fee> _feeWithStudent(
      Transaction txn, Map<String, Object?> row) async {
    final studentId = row['student_id'] as int;
    final monthStart = (row['month'] as String?) ?? '';
    final s = await txn.query('students',
        where: 'id = ?', whereArgs: [studentId], limit: 1);
    return _feeFromRow(row,
        s: s.isEmpty ? '' : _names(s.first),
        runningOutstanding: monthStart.isEmpty
            ? null
            : await _runningOutstanding(txn, studentId, monthStart));
  }

  Future<Fee> createFee(int studentId, String month, String amountDue) async {
    final monthIso = _monthIso(month);
    final d = await _d;
    final existing = await d.query('fees',
        where: 'student_id = ? AND month = ?',
        whereArgs: [studentId, monthIso]);
    if (existing.isNotEmpty) {
      throw RepoException(
          'A fee record already exists for this student and month');
    }
    final students = await d.query('students',
        where: 'id = ?', whereArgs: [studentId], limit: 1);
    if (students.isEmpty) throw RepoException('Student not found');
    final due = double.tryParse(amountDue) ?? 0;
    if (due <= 0) throw RepoException('Amount due must be greater than zero');
    final id = await d.insert('fees', {
      'student_id': studentId,
      'month': monthIso,
      'amount_due': DbFmt.round2(due),
      'amount_paid': 0,
      'status': 'due',
      ...SyncStamp.now(db).columns(),
    });
    final rows = await d.query('fees', where: 'id = ?', whereArgs: [id]);
    final row = rows.first;
    final s = await d.query('students',
        where: 'id = ?', whereArgs: [studentId], limit: 1);
    return _feeFromRow(row, s: s.isEmpty ? '' : _names(s.first));
  }

  /// One-tap "Mark Paid": settle a student's **entire outstanding balance**
  /// through the tapped row's month — every unpaid month up to and including
  /// it, oldest first (FIFO) — stamp the phone's current date and append a
  /// single ledger entry on the tapped row. Idempotent: a student with nothing
  /// outstanding is returned untouched.
  Future<Fee> markFeePaid(int feeId) async {
    final d = await _d;
    return d.transaction((txn) async {
      final rows = await txn.query('fees', where: 'id = ?', whereArgs: [feeId]);
      if (rows.isEmpty) throw RepoException('Fee record not found');
      final row = rows.first;
      final studentId = row['student_id'] as int;
      final monthStart = (row['month'] as String?) ?? '';

      final outstanding = await _runningOutstanding(txn, studentId, monthStart);
      if (outstanding <= 0.001) return _feeWithStudent(txn, row);

      final unpaid = await _unpaidUpTo(txn, studentId, monthStart);
      final today = DbFmt.date(DateTime.now());
      var collected = 0.0;
      for (final r in unpaid) {
        final due = _fee(r['amount_due']);
        collected = DbFmt.round2(collected + _fee(r['amount_due']) - _fee(r['amount_paid']));
        await txn.update('fees', {
          'amount_paid': due,
          'status': 'paid',
          'payment_date': today,
          'payment_method': 'cash',
          ...SyncStamp.now(db).touchColumns(),
        }, where: 'id = ?', whereArgs: [r['id']]);
      }
      await txn.insert('fee_payments', {
        'fee_id': feeId,
        'student_id': studentId,
        'amount': collected,
        'payment_date': today,
        'payment_method': 'cash',
        ...SyncStamp.now(db).columns(),
      });
      final updated = await txn.query('fees',
          where: 'id = ?', whereArgs: [feeId]);
      return _feeWithStudent(txn, updated.first);
    });
  }

  /// One-tap "Mark Due": fully reverse this one row's payment — its amount is
  /// removed from the monthly collected totals, its status returns to due, its
  /// payment date is cleared, and the ledger entries attached to it are
  /// tombstoned. Under FIFO a bulk payment may have settled several months in
  /// one tap; marking each of those months due in turn undoes it. Older months
  /// are never disturbed.
  Future<Fee> markFeeDue(int feeId) async {
    final d = await _d;
    return d.transaction((txn) async {
      final rows = await txn.query('fees', where: 'id = ?', whereArgs: [feeId]);
      if (rows.isEmpty) throw RepoException('Fee record not found');
      final row = rows.first;
      final stamp = SyncStamp.now(db);
      await txn.update('fee_payments', {
        ...stamp.tombstoneColumns(),
      }, where: 'fee_id = ? AND deleted_at IS NULL', whereArgs: [feeId]);
      await txn.update('fees', {
        'amount_paid': 0,
        'status': 'due',
        'payment_date': null,
        'payment_method': null,
        ...stamp.touchColumns(),
      }, where: 'id = ?', whereArgs: [feeId]);
      final updated = await txn.query('fees',
          where: 'id = ?', whereArgs: [feeId]);
      return _feeWithStudent(txn, updated.first);
    });
  }

  /// Record a payment of [amount] for the tapped row's month, applied across
  /// the student's unpaid months oldest-first (FIFO). Each touched month's
  /// `amount_paid` absorbs as much of the remaining payment as it still owns;
  /// statuses recompute per month, and one ledger entry rides the tapped row.
  Future<Fee> recordFeePayment(
    int feeId,
    double amount,
    String paymentDate,
    String method,
  ) async {
    final d = await _d;
    return d.transaction((txn) async {
      final rows = await txn.query('fees', where: 'id = ?', whereArgs: [feeId]);
      if (rows.isEmpty) throw RepoException('Fee record not found');
      final row = rows.first;
      final studentId = row['student_id'] as int;
      final monthStart = (row['month'] as String?) ?? '';
      if (amount <= 0) throw RepoException('Payment amount must be positive');
      final outstanding = await _runningOutstanding(txn, studentId, monthStart);
      if (amount > outstanding + 0.001) {
        throw RepoException(
            'Payment exceeds remaining dues of ${outstanding.toStringAsFixed(2)}');
      }
      var left = amount;
      final unpaid = await _unpaidUpTo(txn, studentId, monthStart);
      for (final r in unpaid) {
        if (left <= 0.001) break;
        final due = _fee(r['amount_due']);
        final paid = _fee(r['amount_paid']);
        final remaining = DbFmt.round2(due - paid);
        if (remaining <= 0.001) continue;
        final chunk = DbFmt.round2(left < remaining ? left : remaining);
        final newPaid = DbFmt.round2(paid + chunk);
        await txn.update('fees', {
          'amount_paid': newPaid,
          'status': feeStatus(due, newPaid),
          'payment_date': paymentDate,
          'payment_method': method,
          ...SyncStamp.now(db).touchColumns(),
        }, where: 'id = ?', whereArgs: [r['id']]);
        left = DbFmt.round2(left - chunk);
      }
      await txn.insert('fee_payments', {
        'fee_id': feeId,
        'student_id': studentId,
        'amount': DbFmt.round2(amount),
        'payment_date': paymentDate,
        'payment_method': method,
        ...SyncStamp.now(db).columns(),
      });
      final updated = await txn.query('fees',
          where: 'id = ?', whereArgs: [feeId]);
      return _feeWithStudent(txn, updated.first);
    });
  }

  /// Payment history ledger for a student (newest first).
  Future<List<Map<String, dynamic>>> paymentHistory(int studentId) async {
    final d = await _d;
    final rows = await d.rawQuery('''
      SELECT fp.*, f.month, s.first_name, s.last_name
      FROM fee_payments fp
      JOIN fees f ON f.id = fp.fee_id
      JOIN students s ON s.id = fp.student_id
      WHERE fp.student_id = ? AND fp.deleted_at IS NULL AND f.deleted_at IS NULL
      ORDER BY fp.payment_date DESC, fp.id DESC
    ''', [studentId]);
    return rows.map((r) {
      final feeFmt = _fee(r['amount']);
      return {
        'id': r['id'] as int,
        'fee_id': r['fee_id'] as int,
        'month': r['month'] as String,
        'amount': feeFmt.toStringAsFixed(2),
        'payment_date': r['payment_date'] as String,
        'payment_method': r['payment_method'] as String? ?? 'cash',
        'student_name': _names({'first_name': r['first_name'], 'last_name': r['last_name']}),
      };
    }).toList();
  }

  Future<Fee> updateFee(int feeId, {String? amountDue}) async {
    final d = await _d;
    final rows = await d.query('fees', where: 'id = ?', whereArgs: [feeId]);
    if (rows.isEmpty) throw RepoException('Fee record not found');
    final row = rows.first;
    final due = amountDue != null ? (double.tryParse(amountDue) ?? 0) : _fee(row['amount_due']);
    final paid = _fee(row['amount_paid']);
    if (due < paid) {
      throw RepoException('Amount due cannot be less than amount already paid');
    }
    await d.update('fees', {
      'amount_due': DbFmt.round2(due),
      'status': feeStatus(due, paid),
      ...SyncStamp.now(db).touchColumns(),
    }, where: 'id = ?', whereArgs: [feeId]);
    return getFee(feeId);
  }

  Future<Fee> getFee(int feeId) async {
    final d = await _d;
    final rows = await d.rawQuery('''
      SELECT f.*, s.first_name, s.last_name FROM fees f
      JOIN students s ON s.id = f.student_id
      WHERE f.id = ?
    ''', [feeId]);
    if (rows.isEmpty) throw RepoException('Fee record not found');
    return _feeFromRow(rows.first, s: _names(rows.first));
  }

  Future<void> deleteFee(int feeId) async {
    final d = await _d;
    final updated = await d.update('fees', {
      ...SyncStamp.now(db).tombstoneColumns(),
    }, where: 'id = ?', whereArgs: [feeId]);
    if (updated == 0) throw RepoException('Fee record not found');
  }

  /// Ensure the given month has records for every eligible active student —
  /// the list shown in the Fee screen is always backed by records, so this is
  /// called before listing/aggregating a month. Idempotent.
  Future<void> ensureMonthWithFees(String month) async {
    final requested = DateTime.tryParse(_monthIso(month));
    if (requested == null) return;
    await ensureMonthlyFees(DateTime.now(), anchor: requested);
    // Guarantee coverage for the requested month itself as well (students
    // added after that month's records were first generated).
    final d = await _d;
    await d.transaction((txn) async {
      await _insertMonthFees(txn, DbFmt.firstOfMonth(requested));
    });
  }

  String _monthIso(String month) =>
      month.replaceFirst(RegExp(r'-\d{2}$'), '-01');

  double _fee(Object? v) {
    final n = double.tryParse(v?.toString() ?? '');
    return n == null ? 0 : DbFmt.round2(n);
  }

  Fee _feeFromRow(Map<String, Object?> row,
      {String? s, double? runningOutstanding}) => Fee(
        id: row['id'] as int,
        studentId: row['student_id'] as int,
        studentName: s ?? '',
        month: row['month'] as String,
        amountDue: (_fee(row['amount_due'])).toStringAsFixed(2),
        amountPaid: (_fee(row['amount_paid'])).toStringAsFixed(2),
        status: (row['status'] as String?) ?? 'due',
        paymentDate: row['payment_date'] as String?,
        paymentMethod: row['payment_method'] as String?,
        notes: row['notes'] as String?,
        runningOutstanding:
            runningOutstanding?.toStringAsFixed(2) ?? '',
      );

  String _names(Map<String, Object?> row) {
    final first = (row['first_name'] as String?) ?? '';
    final last = (row['last_name'] as String?) ?? '';
    return '$first $last'.trim();
  }
}