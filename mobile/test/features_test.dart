import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:tandav_mobile/core/services.dart';
import 'package:tandav_mobile/core/whatsapp.dart';
import 'package:tandav_mobile/database/db_helpers.dart';
import 'package:tandav_mobile/database/tandav_database.dart';

void main() {
  sqfliteFfiInit();

  late Directory tempDir;
  late String dbPath;
  late int dbSeq;

  final now = DateTime.now();
  final base = DbFmt.firstOfMonth(now);
  final prev = DbFmt.addMonths(base, -1);
  final prevIso = DbFmt.month(prev);
  final baseIso = DbFmt.month(base);
  final next = DbFmt.addMonths(base, 1);
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

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('tandav_features_');
    dbSeq = 0;
  });

  tearDownAll(() async {
    await TandavDatabase.instance.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<int> createStudent(TandavApi api,
      {required String name,
      String fee = '1500',
      String? joinDate,
      String? emergencyContactPhone}) async {
    final s = await api.students.createStudent({
      'first_name': name,
      'phone': '9${name.hashCode.abs() % 10000000000}',
      'emergency_contact_phone': emergencyContactPhone,
      'monthly_fee': fee,
      'join_date': joinDate ?? DbFmt.date(DbFmt.addMonths(base, -3)),
    });
    return s.id;
  }

  group('fee increment for unpaid months', () {
    test('default penalty is 100 and lives in app_settings', () async {
      final api = await freshApi();
      expect(await api.getLateFeePenalty(), 100);
      await api.setLateFeePenalty(250);
      expect(await api.getLateFeePenalty(), 250);
      await api.setLateFeePenalty(0);
      expect(await api.getLateFeePenalty(), 0);
    });

    test('unpaid previous month adds the penalty to the next month', () async {
      final api = await freshApi();
      await createStudent(api, name: 'Aarav', fee: '1500');

      // Generate the previous month, leave it unpaid (due), then generate the
      // current month — the increment is added on top of the base fee.
      await api.fees.ensureMonthlyFees(prev);
      expect((await api.getFees(month: prevIso)).items.single.status, 'due');
      await api.fees.ensureMonthlyFees(base);
      final thisMonth = (await api.getFees(month: baseIso)).items.single;
      expect(thisMonth.amountDue, '1600.00'); // 1500 + 100 default penalty
    });

    test('paid previous month earns no increment; reverts the month after',
        () async {
      final api = await freshApi();
      await createStudent(api, name: 'Payal', fee: '2000');

      // Previous month unpaid -> current month incremented.
      await api.fees.ensureMonthlyFees(prev);
      await api.fees.ensureMonthlyFees(base);
      expect((await api.getFees(month: baseIso)).items.single.amountDue, '2100.00');

      // Mark the month that immediately precedes "next" (base) paid; the
      // following month reverts to the plain monthly fee.
      final baseFee = (await api.getFees(month: baseIso)).items.single;
      await api.markFeePaid(baseFee.id);
      await api.fees.ensureMonthlyFees(next);
      expect((await api.getFees(month: nextIso)).items.single.amountDue, '2000.00');
    });

    test('partial payment still counts as unpaid for the increment', () async {
      final api = await freshApi();
      await createStudent(api, name: 'Parth', fee: '1200');
      await api.fees.ensureMonthlyFees(prev);
      final prevFee = (await api.getFees(month: prevIso)).items.single;
      await api.recordFeePayment(prevFee.id, 300, DbFmt.date(prev), 'cash');
      await api.fees.ensureMonthlyFees(base);
      expect((await api.getFees(month: baseIso)).items.single.amountDue, '1300.00');
    });

    test('disabled penalty (0) produces no increment', () async {
      final api = await freshApi();
      await api.setLateFeePenalty(0);
      await createStudent(api, name: 'Zero', fee: '1500');
      await api.fees.ensureMonthlyFees(prev);
      await api.fees.ensureMonthlyFees(base);
      expect((await api.getFees(month: baseIso)).items.single.amountDue, '1500.00');
    });

    test('fees are only ever generated from the student\'s join month', () async {
      final api = await freshApi();
      // Joins THIS month -> no record for the previous month, and the current
      // month's fee is the base fee (no previous month to be unpaid).
      final id = await createStudent(api,
          name: 'Joiner', fee: '1500', joinDate: DbFmt.date(base));
      await api.fees.ensureMonthlyFees(prev);
      await api.fees.ensureMonthlyFees(base);
      final fees = (await api.getFees(studentId: id)).items;
      expect(fees.length, 1); // only this month, not the month before joining
      expect(fees.single.month, baseIso);
      expect(fees.single.amountDue, '1500.00');
    });

    test('backfill after a closed-app gap increments the freshly generated '
        'month when the preceding month is unpaid', () async {
      final api = await freshApi();
      await createStudent(api, name: 'Ranveer', fee: '1000');
      // App was last open in the previous month (unpaid). Reopening this month
      // backfills the current month and, because the previous month is due,
      // applies the increment to it.
      await api.fees.ensureMonthlyFees(prev);
      expect((await api.getFees(month: prevIso)).items.single.status, 'due');
      await api.fees.ensureMonthlyFees(base);
      expect((await api.getFees(month: baseIso)).items.single.amountDue, '1100.00');
      // The gap month itself is never incremented: it has no predecessor.
      expect((await api.getFees(month: prevIso)).items.single.amountDue, '1000.00');
    });
  });

  group('CSV export', () {
    test('students CSV carries contacts, batch and fee', () async {
      final api = await freshApi();
      final b = await api.createBatch({
        'name': 'Classical',
        'dance_style': 'Bharatanatyam',
        'schedule': 'Mon/Wed 6pm',
        'monthly_fee': '1800',
      });
      await api.students.createStudent({
        'first_name': 'Meera',
        'last_name': 'Rao',
        'phone': '9876543210',
        'email': 'meera@example.com',
        'emergency_contact_name': 'Kavita Rao',
        'emergency_contact_phone': '9812345678',
        'monthly_fee': '1800',
        'batch_id': b.id,
        'join_date': DbFmt.date(base),
      });

      final csv = await api.exportStudentsCsv();
      expect(csv, contains('Student Name'));
      expect(csv, contains('Meera Rao'));
      expect(csv, contains('9876543210'));
      expect(csv, contains('meera@example.com'));
      expect(csv, contains('9812345678'));
      expect(csv, contains('Classical'));
      expect(csv, contains('Kavita Rao'));
    });

    test('batches CSV shows the default fee and headcount', () async {
      final api = await freshApi();
      final b = await api.createBatch({
        'name': 'Hip Hop',
        'dance_style': 'Hip-Hop',
        'monthly_fee': '1200',
      });
      await api.students.createStudent({
        'first_name': 'Rohan',
        'phone': '9200000002',
        'monthly_fee': '1200',
        'batch_id': b.id,
        'join_date': DbFmt.date(base),
      });

      final csv = await api.exportBatchesCsv();
      expect(csv, contains('Hip Hop'));
      expect(csv, contains('1200'));
      expect(csv, contains('1')); // student_count for the batch
    });

    test('fees CSV shows status, due, paid and outstanding', () async {
      final api = await freshApi();
      await createStudent(api, name: 'Aaravin', fee: '1500');
      await api.fees.ensureMonthlyFees(base);
      final fee = (await api.getFees(month: baseIso)).items.single;
      await api.recordFeePayment(fee.id, 500, DbFmt.date(base), 'upi');

      final csv = await api.exportMonthlyFeesCsv(month: baseIso);
      expect(csv, contains('Month'));
      expect(csv, contains('Aaravin'));
      expect(csv, contains('1500.00'));
      expect(csv, contains('500.00'));
      expect(csv, contains('1000.00')); // outstanding
      expect(csv, contains('partial'));
      expect(csv, contains('upi'));
    });

    test('attendance CSV reflects monthly aggregates', () async {
      final api = await freshApi();
      final b = await api.createBatch({'name': 'Contemporary'});
      final studentId = await createStudent(api,
          name: 'Ananya', fee: '1100', joinDate: DbFmt.date(prev));
      await api.saveAttendanceDay(
        date: DbFmt.date(base),
        batchId: b.id,
        records: [
          {'student_id': studentId, 'status': 'present'},
          // a second unmarked student is not in this batch's roster here
        ],
      );

      final csv = await api.exportAttendanceCsv(month: baseIso);
      expect(csv, contains('Total Classes'));
      expect(csv, contains('Ananya'));
      expect(csv, contains('1')); // total_classes
      expect(csv, contains('100')); // attendance %
    });
  });

  group('UPI payment config', () {
    test('VPA and payee persist in app_settings; empty clears them', () async {
      final api = await freshApi();
      expect(await api.getUpiVpa(), isNull);
      expect(await api.getUpiPayee(), isNull);

      await api.setUpiVpa('tandav@okhdfcbank');
      await api.setUpiPayee('Tandav Studio');
      expect(await api.getUpiVpa(), 'tandav@okhdfcbank');
      expect(await api.getUpiPayee(), 'Tandav Studio');

      await api.setUpiVpa('  ');
      await api.setUpiPayee('');
      expect(await api.getUpiVpa(), isNull);
      expect(await api.getUpiPayee(), isNull);
    });
  });

  group('UPI link helpers', () {
    test('normalizeVpa accepts common spellings and unwinds a pasted link',
        () {
      expect(WhatsAppService.normalizeVpa('tandav@okhdfcbank'),
          'tandav@okhdfcbank');
      expect(WhatsAppService.normalizeVpa('  name@ybl  '), 'name@ybl');
      expect(
        WhatsAppService.normalizeVpa(
            'upi://pay?pa=studio@sbi&pn=Studio&am=100&cu=INR'),
        'studio@sbi',
      );
      expect(WhatsAppService.normalizeVpa('noathere'), isNull);
      expect(WhatsAppService.normalizeVpa('@missinghandle'), isNull);
      expect(WhatsAppService.normalizeVpa(''), isNull);
    });

    test('upiPayLink pre-fills pa/pn/am/cu/tn', () {
      final link = WhatsAppService.upiPayLink(
        vpa: 'tandav@okhdfcbank',
        payee: 'Tandav Studio',
        amount: 1600,
        note: 'Aarav · fee Jul',
      );
      expect(link, isNotNull);
      expect(link, startsWith('upi://pay?'));
      expect(link, contains('pa=tandav%40okhdfcbank'));
      expect(link, contains('pn=Tandav%20Studio'));
      expect(link, contains('am=1600.00'));
      expect(link, contains('cu=INR'));
      expect(link, contains('tn=Aarav%20%C2%B7%20fee%20Jul'));
    });

    test('upiPayLink returns null for an invalid vpa', () {
      expect(
        WhatsAppService.upiPayLink(
            vpa: 'notavalid vpa', amount: 100, note: 'x'),
        isNull,
      );
    });
  });

  group('reminder message embeds the UPI pay link', () {
    test('reminderMessage keeps its wording without a link', () {
      final msg = WhatsAppService.reminderMessage(
        studentName: 'Aarav',
        monthLabel: 'July',
        amountDue: 1600,
      );
      expect(msg, contains('Amount Due: ₹1,600'));
      expect(msg, isNot(contains('Tap to pay now')));
    });

    test('reminderMessage appends the pay-now line when a link is given', () {
      final msg = WhatsAppService.reminderMessage(
        studentName: 'Aarav',
        monthLabel: 'July',
        amountDue: 1600,
        upiLink:
            'upi://pay?pa=tandav%40okhdfcbank&am=1600.00&cu=INR&tn=Aarav',
      );
      expect(msg, contains('Amount Due: ₹1,600'));
      expect(msg, contains('Tap to pay now via UPI'));
      expect(msg, contains('upi://pay?'));
    });
  });
}
