import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:tandav_mobile/core/services.dart';
import 'package:tandav_mobile/database/db_helpers.dart';
import 'package:tandav_mobile/database/tandav_database.dart';

void main() {
  sqfliteFfiInit();

  late Directory tempDir;
  late String dbPath;
  late int dbSeq;

  // Months are relative to "now" so date-based assertions never depend on
  // the machine's actual clock.
  final now = DateTime.now();
  final base = DbFmt.firstOfMonth(now);
  final next = DbFmt.addMonths(base, 1);
  final baseIso = DbFmt.month(base);
  final nextIso = DbFmt.month(next);

  Future<TandavApi> freshApi() async {
    final db = TandavDatabase.instance;
    await db.close();
    dbPath = p.join(tempDir.path, 'test_${dbSeq++}.db');
    if (await File(dbPath).exists()) {
      await File(dbPath).delete();
    }
    db.configureForTest(factory: databaseFactoryFfi, overridePath: dbPath);
    final api = TandavApi(database: db);
    await db.open();
    return api;
  }

  Future<int> createStudent(TandavApi api,
      {required String name, String fee = '1500', String? joinDate, int? batchId, bool active = true}) async {
    final s = await api.students.createStudent({
      'first_name': name,
      'phone': '9${name.hashCode.abs() % 10000000000}',
      'monthly_fee': fee,
      'join_date': joinDate ?? DbFmt.date(DbFmt.addMonths(base, -3)),
      'batch_id': batchId,
      'is_active': active,
    });
    return s.id;
  }

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('tandav_test_');
    dbSeq = 0;
  });

  tearDownAll(() async {
    await TandavDatabase.instance.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('admin account is seeded and auth verifies against hashes', () async {
    final api = await freshApi();
    final user = await api.auth.verifyLogin('admin', 'admin123');
    expect(user, isNotNull);
    expect(user!.username, 'admin');
    expect(await api.auth.verifyLogin('admin', 'wrong'), isNull);

    await api.auth.changePassword('admin', 'admin123', 'newpass123');
    expect(await api.auth.verifyLogin('admin', 'admin123'), isNull);
    expect(await api.auth.verifyLogin('admin', 'newpass123'), isNotNull);

    expect(
      () => api.auth.changePassword('admin', 'bad', 'x'),
      throwsA(isA<RepoException>()),
    );
  });

  test('batches CRUD and student counts', () async {
    final api = await freshApi();
    final b = await api.createBatch({
      'name': 'Classical',
      'dance_style': 'Bharatanatyam',
      'level': 'Advanced',
      'schedule': 'Mon/Wed 6pm',
      'monthly_fee': '1800',
    });
    expect(b.name, 'Classical');
    expect(double.parse(b.monthlyFee), 1800);
    expect(await api.getBatch(b.id), isNotNull);

    final updated =
        await api.updateBatch(b.id, {'name': 'Classical 2', 'monthly_fee': '2000'});
    expect(updated.name, 'Classical 2');
    expect(double.parse(updated.monthlyFee), 2000);

    expect((await api.getBatches(search: 'Classical')).total, 1);
    expect((await api.getBatches(search: 'nope')).total, 0);

    await createStudent(api, name: 'Meera', fee: '1800', batchId: b.id);
    expect((await api.getBatch(b.id)).studentCount, 1);

    await api.deleteBatch(b.id);
    expect((await api.getBatches()).total, 0);
    // FK ON DELETE SET NULL: the student survives without a batch.
    expect((await api.getStudents()).items.single.batchId, isNull);
  });

  test('students CRUD, search and filters', () async {
    final api = await freshApi();
    final b = await api.createBatch({'name': 'Hip Hop'});
    await api.students.createStudent({
      'first_name': 'Rohan',
      'last_name': 'Sharma',
      'gender': 'male',
      'phone': '9200000002',
      'monthly_fee': '1200',
      'batch_id': b.id,
      'join_date': DbFmt.date(DbFmt.addMonths(base, -3)),
    });
    await api.students.createStudent({
      'first_name': 'Ishita',
      'gender': 'female',
      'monthly_fee': '1200',
      'join_date': DbFmt.date(DbFmt.addMonths(base, -3)),
      'is_active': false,
    });

    expect((await api.getStudents()).total, 2);
    expect((await api.getStudents(q: 'rohan')).total, 1);
    expect((await api.getStudents(gender: 'female')).total, 1);
    expect((await api.getStudents(batchId: b.id)).total, 1);
    expect((await api.getStudents(activeOnly: true)).total, 1);

    final s = (await api.getStudents(q: 'rohan')).items.single;
    final moved = await api.students.updateStudent(s.id, {
      'first_name': 'Rohan',
      'last_name': 'Verma',
      'phone': '9200000002',
      'monthly_fee': '1400',
      'batch_id': null,
      'join_date': DbFmt.date(DbFmt.addMonths(base, -3)),
    });
    expect(moved.lastName, 'Verma');
    expect(double.parse(moved.monthlyFee), 1400);
    expect(moved.batchId, isNull);

    await api.students.deleteStudent(s.id);
    expect((await api.getStudents()).total, 1);
  });

  test('fee accounts auto-generate monthly records, backfill gaps, never duplicate',
      () async {
    final api = await freshApi();
    final studentId =
        await createStudent(api, name: 'Aarav', joinDate: DbFmt.date(DbFmt.addMonths(base, -3)));

    // App opened at the start of this month: one record for this month only.
    expect(await api.fees.ensureMonthlyFees(base), 1);
    expect((await api.getFees()).total, 1);
    final thisMonth = (await api.getFees(month: baseIso)).items.single;
    expect(thisMonth.month, baseIso);
    expect(thisMonth.amountDue, '1500.00');
    expect(thisMonth.status, 'due');

    // App stayed closed for a month; opening next month backfills the gap.
    expect(await api.fees.ensureMonthlyFees(next), 1);
    expect((await api.getFees(studentId: studentId)).total, 2);

    // Idempotent: repeated runs create nothing new and never duplicate.
    expect(await api.fees.ensureMonthlyFees(DbFmt.addMonths(next, 15)), 15);
    expect(await api.fees.ensureMonthlyFees(DbFmt.addMonths(next, 15)), 0);
    expect((await api.getFees(studentId: studentId)).total, 17);
  });

  test('fee generation respects join date, active flag, and non-zero fee',
      () async {
    final api = await freshApi();
    // Joins next month: not eligible for this month.
    await createStudent(api, name: 'Joiner', joinDate: DbFmt.date(next));
    // Zero fee and inactive students never get records.
    await createStudent(api, name: 'Free', fee: '0');
    await createStudent(api, name: 'Left', active: false);

    expect(await api.fees.ensureMonthlyFees(base), 0);
    expect((await api.getFees(month: baseIso)).items, isEmpty);

    expect(await api.fees.ensureMonthlyFees(next), 1);
    expect((await api.getFees(month: nextIso)).total, 1);
  });

  test('creating a student generates fees from the join month', () async {
    final api = await freshApi();
    final s = await api.students.createStudent({
      'first_name': 'Kavya',
      'phone': '9500000007',
      'monthly_fee': '1600',
      'join_date': DbFmt.date(DbFmt.addMonths(base, -2)),
    });
    final got = await api.fees.studentFeeForMonth(s.id, DbFmt.addMonths(base, -2));
    expect(got.month, DbFmt.month(DbFmt.addMonths(base, -2)));
    expect(got.amountDue, '1600.00');
  });

  test('payments: partial then paid, ledger history, overpayment rejected',
      () async {
    final api = await freshApi();
    final studentId = await createStudent(api, name: 'Payal', fee: '2000');
    await api.fees.ensureMonthlyFees(base);
    final fee = (await api.getFees(month: baseIso)).items.single;

    final partial =
        await api.recordFeePayment(fee.id, 800, DbFmt.date(base), 'upi');
    expect(partial.status, 'partial');
    expect(partial.amountPaid, '800.00');

    final done =
        await api.recordFeePayment(fee.id, 1200, DbFmt.date(next), 'cash');
    expect(done.status, 'paid');
    expect(done.paidValue, 2000);

    expect(
      () => api.recordFeePayment(fee.id, 100, DbFmt.date(next), 'cash'),
      throwsA(isA<RepoException>()),
    );

    expect((await api.getFees()).items.single.status, 'paid');
    final summary = await api.getFeeSummary(baseIso);
    expect(summary.paidCount, 1);
    expect(summary.dueCount, 0);
    expect(summary.totalDue, '2000.00');
    expect(summary.collectionRate, 100.0);

    final history = await api.paymentHistory(studentId);
    expect(history.length, 2);
    expect(history.first['month'], baseIso);
    expect(history.first['amount'], '1200.00');

    // No record may be created twice for the same student + month.
    expect(
      () => api.createFee(studentId, baseIso, '2000'),
      throwsA(isA<RepoException>()),
    );
    // Amount due may never drop below what is already paid.
    expect(
      () => api.updateFee(fee.id, amountDue: '1500'),
      throwsA(isA<RepoException>()),
    );
  });

  test('attendance day is built, saved, upserted and aggregated by month',
      () async {
    final api = await freshApi();
    final b = await api.createBatch({'name': 'Contemporary'});
    final studentId = await createStudent(api, name: 'Ananya', fee: '1100', batchId: b.id);
    await api.fees.ensureMonthlyFees(base);

    final d1 = DbFmt.date(base);
    final d2 = DbFmt.date(base.add(const Duration(days: 7)));

    final empty = await api.getAttendanceDay(d1, batchId: b.id);
    expect(empty.total, 1);
    expect(empty.unmarked, 1);

    final saved = await api.saveAttendanceDay(
      date: d1,
      batchId: b.id,
      records: [
        {'student_id': studentId, 'status': 'present'},
      ],
    );
    expect(saved.present, 1);
    expect(saved.unmarked, 0);

    // Re-saving the same day replaces the mark instead of duplicating.
    final resaved = await api.saveAttendanceDay(
      date: d1,
      batchId: b.id,
      records: [
        {'student_id': studentId, 'status': 'late'},
      ],
    );
    expect(resaved.late, 1);
    expect(resaved.total, 1);

    await api.saveAttendanceDay(
      date: d2,
      batchId: b.id,
      records: [
        {'student_id': studentId, 'status': 'present'},
      ],
    );

    final monthly = await api.getMonthlyAttendance(baseIso);
    expect(monthly.single.totalClasses, 2);
    expect(monthly.single.presents, 1);
    expect(monthly.single.lates, 1);
    expect(monthly.single.percentage, 100.0);

    // Duplicate student_id inside one save is rejected.
    expect(
      () => api.saveAttendanceDay(
        date: d2,
        batchId: b.id,
        records: [
          {'student_id': studentId, 'status': 'present'},
          {'student_id': studentId, 'status': 'absent'},
        ],
      ),
      throwsA(isA<RepoException>()),
    );
  });

  test('progress records ratings, prevents duplicates and mirrors attendance',
      () async {
    final api = await freshApi();
    final b = await api.createBatch({'name': 'Freestyle'});
    final studentId = await createStudent(api, name: 'Divya', fee: '1300', batchId: b.id);

    final progress = await api.createProgress(studentId, {
      'month': baseIso,
      'skill_rating': 80,
      'performance_rating': 90,
      'discipline_rating': 70,
      'remarks': 'Keep it up',
    });
    expect(progress.overallScore, 80.0);
    expect(progress.attendancePercentage, isNull);
    expect(
      () => api.createProgress(studentId, {'month': baseIso}),
      throwsA(isA<RepoException>()),
    );

    await api.saveAttendanceDay(
      date: DbFmt.date(base),
      batchId: b.id,
      records: [
        {'student_id': studentId, 'status': 'present'},
      ],
    );
    expect(
        (await api.getProgress(studentId: studentId)).items.single.attendancePercentage,
        100.0);
  });

  test('events: batch add, costume payments and participation history',
      () async {
    final api = await freshApi();
    final b = await api.createBatch({'name': 'Kaathak'});
    final s1 = await createStudent(api, name: 'Vanya', fee: '900', batchId: b.id);
    await createStudent(api, name: 'Samyak', fee: '900', batchId: b.id);

    final event = await api.createEvent({
      'name': 'Annual Day 2026',
      'event_type': 'performance',
      'event_date': DbFmt.date(next),
      'location': 'Community Hall',
    });

    await api.addBatchParticipants(event.id, b.id, costumeFee: '500');
    var participants = await api.getParticipants(event.id);
    expect(participants.total, 2);

    // Adding the batch again is a no-op.
    await api.addBatchParticipants(event.id, b.id, costumeFee: '500');
    expect((await api.getParticipants(event.id)).total, 2);

    // A new student added individually with costume requirement lands as due.
    final s3 = await createStudent(api, name: 'Nitya', fee: '900', batchId: b.id);
    await api.addParticipants(event.id, [s3],
        isCostumeRequired: true, costumeFee: '500');
    var parts = (await api.getParticipants(event.id)).items;
    expect(parts.length, 3);
    expect(parts.firstWhere((p) => p.studentName.contains('Nitya')).costumeStatus,
        'due');

    final p1 = parts.first.id;
    final paid = await api.updateParticipation(p1, {
      'is_costume_required': true,
      'costume_fee_due': '500',
      'costume_fee_paid': '500',
      'costume_paid_date': DbFmt.date(base),
      'costume_payment_method': 'cash',
    });
    expect(paid.costumeStatus, 'paid');

    parts = (await api.getParticipants(event.id)).items;
    final p2 = parts.last;
    await api.updateParticipation(p2.id, {
      'is_costume_required': true,
      'costume_fee_due': '500',
      'costume_fee_paid': '250',
    });
    expect((await api.getParticipants(event.id, costumeStatus: 'partial')).total, 1);

    final summary = await api.getCostumeSummary(event.id);
    expect(summary.totalDue, '1500.00');
    expect(summary.totalPaid, '750.00');
    expect(summary.outstanding, '750.00');

    expect((await api.studentParticipationHistory(s1)).total, 1);
    expect((await api.getEvents(q: 'Annual')).total, 1);
    expect((await api.getEvents(upcomingOnly: true)).total, 1);

    await api.removeParticipant(p2.id);
    expect((await api.getParticipants(event.id)).total, 2);
  });

  test('dashboard numbers and monthly report are computed from SQLite',
      () async {
    final api = await freshApi();
    final b = await api.createBatch({'name': 'Semi-Classical'});
    final studentId = await createStudent(api, name: 'Harsh', fee: '1700', batchId: b.id);
    await api.fees.ensureMonthlyFees(base);
    final fee = (await api.getFees(month: baseIso)).items.single;
    await api.recordFeePayment(fee.id, 1700, DbFmt.date(base), 'cash');
    await api.saveAttendanceDay(
      date: DbFmt.date(base),
      batchId: b.id,
      records: [
        {'student_id': studentId, 'status': 'present'},
      ],
    );

    final dashboard = await api.getDashboard(month: baseIso);
    expect(dashboard.stats.totalStudents, 1);
    expect(dashboard.stats.activeStudents, 1);
    expect(dashboard.stats.totalBatches, 1);
    expect(dashboard.feeSummary.totalDue, '1700.00');
    expect(dashboard.feeSummary.totalPaid, '1700.00');
    expect(dashboard.feeSummary.paidCount, 1);
    expect(dashboard.feeSummary.dueCount, 0);
    expect(dashboard.monthlyAttendance, isNotEmpty);

    final report = await api.getMonthlyReport(baseIso);
    expect(report.rows.length, 2); // the batch + Unassigned (no extra students)
    final batchRow = report.rows.firstWhere((r) => r.batchName == 'Semi-Classical');
    expect(batchRow.totalStudents, 1);
    expect(batchRow.feesDue, '1700.00');
    expect(batchRow.feesPaid, '1700.00');
    expect(batchRow.feeCollectionRate, 100.0);
    final unassigned = report.rows.firstWhere((r) => r.batchName == 'Unassigned');
    expect(unassigned.totalStudents, 0);
  });

  test('data survives a close/reopen cycle and fee generation stays idempotent',
      () async {
    final db = TandavDatabase.instance;
    final api1 = await freshApi();
    final studentId = await createStudent(api1, name: 'Persist', fee: '1250');
    await api1.fees.ensureMonthlyFees(base);

    await db.close();
    final api2 = TandavApi(database: db);
    await db.open();

    expect((await api2.getStudents()).total, 1);
    expect((await api2.getStudents()).items.single.id, studentId);
    expect((await api2.getFees(studentId: studentId)).total, 1);
    // Reopening must not create duplicates for already-generated months.
    expect(await api2.fees.ensureMonthlyFees(base), 0);
    expect((await api2.getFees(studentId: studentId)).total, 1);
  });

  test('one-tap markFeePaid settles the month and markFeeDue reverses it',
      () async {
    final api = await freshApi();
    final studentId = await createStudent(api, name: 'Regan', fee: '1500');
    await api.fees.ensureMonthlyFees(base);
    final fee = (await api.getFees(month: baseIso)).items.single;
    expect(fee.status, 'due');

    // Mark PAID: full amount, today's date, ledger entry, summary updated.
    final paid = await api.markFeePaid(fee.id);
    expect(paid.status, 'paid');
    expect(paid.amountPaid, '1500.00');
    expect(paid.paymentDate, DbFmt.date(now));

    final afterPaid = await api.getFeeSummary(baseIso);
    expect(afterPaid.totalPaid, '1500.00');
    expect(afterPaid.paidCount, 1);
    expect(afterPaid.dueCount, 0);
    expect((await api.paymentHistory(studentId)).length, 1);

    // Idempotent: already-paid record is untouched, no extra ledger entry.
    final again = await api.markFeePaid(fee.id);
    expect(again.status, 'paid');
    expect((await api.paymentHistory(studentId)).length, 1);

    // Mark DUE: reversal removes amount and ledger entry, clears the date.
    final due = await api.markFeeDue(fee.id);
    expect(due.status, 'due');
    expect(due.amountPaid, '0.00');
    expect(due.paymentDate, isNull);

    final afterDue = await api.getFeeSummary(baseIso);
    expect(afterDue.totalPaid, '0.00');
    expect(afterDue.paidCount, 0);
    expect(afterDue.dueCount, 1);
    expect(await api.paymentHistory(studentId), isEmpty);
  });

  test('markFeePaid completes a partial payment with a single remaining entry',
      () async {
    final api = await freshApi();
    final studentId = await createStudent(api, name: 'Parth', fee: '1200');
    await api.fees.ensureMonthlyFees(base);
    final fee = (await api.getFees(month: baseIso)).items.single;

    await api.recordFeePayment(fee.id, 400, DbFmt.date(base), 'cash');
    final done = await api.markFeePaid(fee.id);
    expect(done.status, 'paid');
    expect(done.amountPaid, '1200.00');

    final summary = await api.getFeeSummary(baseIso);
    expect(summary.totalPaid, '1200.00');
    final history = await api.paymentHistory(studentId);
    expect(history.length, 2);
    expect(history.first['amount'], '800.00');
  });

  test('fee register shows every active student and respects search/filters',
      () async {
    final api = await freshApi();
    await createStudent(api, name: 'Aarushi', fee: '1500');
    await createStudent(api, name: 'Manav', fee: '1200');
    final inactiveId =
        await createStudent(api, name: 'Gone', fee: '1000', active: false);

    await api.fees.ensureMonthlyFees(base);
    var items = (await api.getFees(month: baseIso)).items;
    expect(items.length, 2);
    expect(items.any((f) => f.studentId == inactiveId), isFalse);

    await api.markFeePaid(items.firstWhere((f) => f.studentName.contains('Aarushi')).id);
    expect((await api.getFees(month: baseIso, status: 'paid')).total, 1);
    expect((await api.getFees(month: baseIso, status: 'due')).total, 1);
    expect((await api.getFees(month: baseIso, q: 'manav')).total, 1);
    expect((await api.getFees(month: baseIso, q: 'zzz')).total, 0);

    final summary = await api.getFeeSummary(baseIso);
    expect(summary.totalDue, '2700.00');
    expect(summary.totalPaid, '1500.00');
    expect(summary.outstanding, '1200.00');
    expect(summary.paidCount, 1);
    expect(summary.dueCount, 1);
  });

  test('student added to a batch mid-month appears in the fee register '
      'without manual fee creation', () async {
    final api = await freshApi();
    final b = await api.createBatch(
        {'name': 'Bollywood Groove', 'monthly_fee': '1500'});

    // App was already opened this month, so the watermark covers the
    // current month when the new student is added later in the month.
    await createStudent(api, name: 'Early Bird', fee: '1500', batchId: b.id);
    await api.fees.ensureMonthlyFees(base);

    final newStudent = await api.students.createStudent({
      'first_name': 'Ananya',
      'last_name': 'Mehta',
      'monthly_fee': '1500',
      'batch_id': b.id,
      'join_date': DbFmt.date(base.add(const Duration(days: 17))),
    });
    final newId = newStudent.id;

    // Opening Fees (current month, "Bollywood Groove" selected) must show
    // both students — no manual fee-record creation involved.
    final fees = await api.getFees(month: baseIso, batchId: b.id);
    expect(fees.total, 2);
    final a = fees.items.firstWhere((f) => f.studentId == newId);
    expect(a.studentName, 'Ananya Mehta');
    expect(a.amountDue, '1500.00');
    expect(a.status, 'due');
    expect(a.paymentDate, isNull);

    // One-tap workflow: MARK PAID then MARK DUE.
    final paid = await api.markFeePaid(a.id);
    expect(paid.status, 'paid');
    expect((await api.getFeeSummary(baseIso, batchId: b.id)).totalPaid,
        '1500.00');
    final due = await api.markFeeDue(a.id);
    expect(due.status, 'due');
    expect((await api.getFeeSummary(baseIso, batchId: b.id)).totalPaid,
        '0.00');

    // No duplicates on repeated opens/refreshes.
    expect(await api.fees.ensureMonthlyFees(base), 0);
    expect((await api.getFees(month: baseIso, batchId: b.id)).total, 2);

    // A student added to a *different* batch stays under their own batch.
    final b2 = await api.createBatch({'name': 'Hip Hop', 'monthly_fee': '1200'});
    await api.students.createStudent({
      'first_name': 'Diya',
      'last_name': 'Singh',
      'monthly_fee': '1200',
      'batch_id': b2.id,
      'join_date': DbFmt.date(base.add(const Duration(days: 20))),
    });
    expect((await api.getFees(month: baseIso, batchId: b.id)).total, 2);
    expect((await api.getFees(month: baseIso, batchId: b2.id)).total, 1);
    expect((await api.getFees(month: baseIso)).total, 3);

    // Viewing an older month keeps history intact: Early Bird (joined months
    // ago) gets an August record; Ananya (joined this month) does not owe
    // August; September payments are untouched and never duplicated.
    final prev = DbFmt.addMonths(base, -1);
    final prevIso = DbFmt.month(prev);
    expect(await api.fees.ensureMonthlyFees(prev), 0);
    final prevFees = await api.getFees(month: prevIso, batchId: b.id);
    expect(prevFees.total, 1);
    expect(prevFees.items.single.studentName, 'Early Bird');
    expect(prevFees.items.single.status, 'due');
    expect(
        (await api.getFees(month: baseIso, batchId: b.id))
            .items
            .firstWhere((f) => f.studentId == newId)
            .status,
        'due');
  });

  test('backup and restore round-trips all data', () async {
    final api = await freshApi();
    final studentId = await createStudent(api, name: 'Neha', fee: '1350');
    await api.fees.ensureMonthlyFees(base);

    final backup = await api.createBackup();
    expect(await api.listBackups(), isNotEmpty);

    await api.students.deleteStudent(studentId);
    expect((await api.getStudents()).total, 0);

    final restored = await api.restoreFromBackup(backup);
    expect(restored, isTrue);
    final again = await api.getStudents();
    expect(again.total, 1);
    expect(again.items.single.firstName, 'Neha');
    expect((await api.getFees(studentId: studentId)).total, 1);
  });
}