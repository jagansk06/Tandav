import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:tandav_mobile/core/services.dart';
import 'package:tandav_mobile/core/theme.dart';
import 'package:tandav_mobile/database/tandav_database.dart';
import 'package:tandav_mobile/models/attendance.dart';
import 'package:tandav_mobile/models/batch.dart';
import 'package:tandav_mobile/screens/attendance/monthly_attendance_screen.dart';

class _FakeApi extends TandavApi {
  _FakeApi() : super(database: TandavDatabase.instance);

  @override
  Future<BatchListResponse> getBatches(
      {String? search, bool activeOnly = false}) async {
    return const BatchListResponse(
      items: [Batch(id: 1, name: 'Monday Gold', studentCount: 2)],
      total: 1,
    );
  }

  @override
  Future<List<MonthlyAttendanceSummary>> getMonthlyAttendance(
      String month,
      {int? batchId}) async {
    return [
      const MonthlyAttendanceSummary(
        studentId: 1,
        studentName: 'Ada Lovelace',
        batchId: 1,
        batchName: 'Monday Gold',
        month: '2026-01',
        totalClasses: 4,
        presents: 4,
        absents: 0,
        lates: 0,
        percentage: 100,
      ),
    ];
  }
}

Widget _host(TandavApi api) => Provider<TandavApi>.value(
      value: api,
      child: MaterialApp(
        theme: TandavTheme.dark,
        home: const MonthlyAttendanceScreen(),
      ),
    );

void main() {
  testWidgets('Monthly Attendance renders without a late-initialization crash',
      (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(_host(api));
    expect(tester.takeException(), isNull);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Monthly Attendance'), findsOneWidget);
    expect(find.text('Ada Lovelace'), findsOneWidget);
  });
}