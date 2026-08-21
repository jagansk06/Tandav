import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:tandav_mobile/core/services.dart';
import 'package:tandav_mobile/core/theme.dart';
import 'package:tandav_mobile/database/tandav_database.dart';
import 'package:tandav_mobile/models/attendance.dart';
import 'package:tandav_mobile/screens/attendance/attendance_screen.dart';

class _FakeApi extends TandavApi {
  _FakeApi() : super(database: TandavDatabase.instance);

  List<Map<String, dynamic>>? lastRecords;

  @override
  Future<AttendanceDay> saveAttendanceDay({
    required String date,
    required int batchId,
    required List<Map<String, dynamic>> records,
  }) async {
    lastRecords = records;
    return AttendanceDay(
      date: date,
      batchId: batchId,
      batchName: 'Batch A',
      total: 2,
      present: 0,
      absent: 0,
      late: 0,
      unmarked: 0,
      percentage: 0.0,
      records: const [],
    );
  }
}

AttendanceDay _unmarkedDay() => AttendanceDay(
      date: '2026-08-10',
      batchId: 1,
      batchName: 'Batch A',
      total: 2,
      present: 0,
      absent: 0,
      late: 0,
      unmarked: 2,
      percentage: 0.0,
      records: const [
        AttendanceStudentRow(studentId: 1, studentName: 'Ada'),
        AttendanceStudentRow(studentId: 2, studentName: 'Bob'),
      ],
    );

Color? _buttonColor(WidgetTester tester, IconData icon, int index) {
  final container = tester.widget<Container>(
    find
        .ancestor(
            of: find.byIcon(icon).at(index), matching: find.byType(Container))
        .first,
  );
  return (container.decoration as BoxDecoration?)?.color;
}

void main() {
  testWidgets(
      'unmarked students have no status selected; taps mark and report live',
      (tester) async {
    final api = _FakeApi();
    Map<int, String>? reported;
    var savedCount = 0;

    await tester.pumpWidget(
      Provider<TandavApi>.value(
        value: api,
        child: MaterialApp(
          theme: TandavTheme.dark,
          home: Scaffold(
            body: AttendanceDayEditor(
              day: _unmarkedDay(),
              onSaved: () => savedCount++,
              onStatusChanged: (m) => reported = Map.of(m),
            ),
          ),
        ),
      ),
    );

    expect(_buttonColor(tester, Icons.check_rounded, 0),
        isNot(TandavColors.success));
    expect(_buttonColor(tester, Icons.check_rounded, 1),
        isNot(TandavColors.success));

    await tester.tap(find.byIcon(Icons.check_rounded).first);
    await tester.pump();
    expect(reported?[1], 'present');
    expect(reported?[2], 'unmarked');
    expect(_buttonColor(tester, Icons.check_rounded, 0),
        TandavColors.success);

    await tester.tap(find.byIcon(Icons.schedule_rounded).first);
    await tester.pump();
    expect(reported?[1], 'late');
    expect(_buttonColor(tester, Icons.schedule_rounded, 0),
        TandavColors.yellow);

    await tester.tap(find.byIcon(Icons.close_rounded).at(1));
    await tester.pump();
    expect(reported?[1], 'late');
    expect(reported?[2], 'absent');
    expect(_buttonColor(tester, Icons.close_rounded, 1), TandavColors.danger);
  });

  testWidgets('save sends only marked students and calls onSaved',
      (tester) async {
    final api = _FakeApi();
    var savedCount = 0;

    await tester.pumpWidget(
      Provider<TandavApi>.value(
        value: api,
        child: MaterialApp(
          theme: TandavTheme.dark,
          home: Scaffold(
            body: AttendanceDayEditor(
              day: _unmarkedDay(),
              onSaved: () => savedCount++,
              onStatusChanged: (_) {},
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.check_rounded).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();

    expect(savedCount, 1);
    expect(api.lastRecords, [
      {'student_id': 1, 'status': 'present'},
    ]);
  });
}
