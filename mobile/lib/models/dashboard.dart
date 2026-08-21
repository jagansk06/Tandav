class DashboardStats {
  final int totalStudents;
  final int activeStudents;
  final int totalBatches;
  final int activeBatches;
  final int totalEvents;
  final int upcomingEvents;
  final int todayPresent;
  final int todayAbsent;
  final int todayLate;
  final int todayUnmarked;

  const DashboardStats({
    required this.totalStudents,
    required this.activeStudents,
    required this.totalBatches,
    required this.activeBatches,
    required this.totalEvents,
    required this.upcomingEvents,
    required this.todayPresent,
    required this.todayAbsent,
    required this.todayLate,
    required this.todayUnmarked,
  });

  factory DashboardStats.fromJson(Map<String, dynamic> json) => DashboardStats(
        totalStudents: json['total_students'] as int? ?? 0,
        activeStudents: json['active_students'] as int? ?? 0,
        totalBatches: json['total_batches'] as int? ?? 0,
        activeBatches: json['active_batches'] as int? ?? 0,
        totalEvents: json['total_events'] as int? ?? 0,
        upcomingEvents: json['upcoming_events'] as int? ?? 0,
        todayPresent: json['today_present'] as int? ?? 0,
        todayAbsent: json['today_absent'] as int? ?? 0,
        todayLate: json['today_late'] as int? ?? 0,
        todayUnmarked: json['today_unmarked'] as int? ?? 0,
      );
}

class DashboardFeeSummary {
  final String month;
  final String totalDue;
  final String totalPaid;
  final String outstanding;
  final int paidCount;
  final int dueCount;
  final int totalRecords;

  const DashboardFeeSummary({
    required this.month,
    required this.totalDue,
    required this.totalPaid,
    required this.outstanding,
    required this.paidCount,
    required this.dueCount,
    required this.totalRecords,
  });

  double get collected => double.tryParse(totalPaid) ?? 0;
  double get due => double.tryParse(totalDue) ?? 0;

  factory DashboardFeeSummary.fromJson(Map<String, dynamic> json) =>
      DashboardFeeSummary(
        month: json['month'] as String,
        totalDue: (json['total_due'] ?? '0').toString(),
        totalPaid: (json['total_paid'] ?? '0').toString(),
        outstanding: (json['outstanding'] ?? '0').toString(),
        paidCount: json['paid_count'] as int? ?? 0,
        dueCount: json['due_count'] as int? ?? 0,
        totalRecords: json['total_records'] as int? ?? 0,
      );
}

class UpcomingEvent {
  final int id;
  final String name;
  final String eventType;
  final String eventDate;
  final String? location;
  final int participantCount;

  const UpcomingEvent({
    required this.id,
    required this.name,
    required this.eventType,
    required this.eventDate,
    this.location,
    this.participantCount = 0,
  });

  factory UpcomingEvent.fromJson(Map<String, dynamic> json) => UpcomingEvent(
        id: json['id'] as int,
        name: json['name'] as String,
        eventType: json['event_type'] as String? ?? '',
        eventDate: json['event_date'] as String,
        location: json['location'] as String?,
        participantCount: json['participant_count'] as int? ?? 0,
      );
}

class RecentStudent {
  final int id;
  final String fullName;
  final String? batchName;
  final String joined;

  const RecentStudent({
    required this.id,
    required this.fullName,
    this.batchName,
    required this.joined,
  });

  factory RecentStudent.fromJson(Map<String, dynamic> json) => RecentStudent(
        id: json['id'] as int,
        fullName: json['full_name'] as String? ?? '',
        batchName: json['batch_name'] as String?,
        joined: json['joined'] as String? ?? '',
      );
}

class DashboardData {
  final DashboardStats stats;
  final DashboardFeeSummary feeSummary;
  final List<Map<String, dynamic>> monthlyAttendance;
  final List<UpcomingEvent> upcomingEvents;
  final List<RecentStudent> recentStudents;

  const DashboardData({
    required this.stats,
    required this.feeSummary,
    required this.monthlyAttendance,
    required this.upcomingEvents,
    required this.recentStudents,
  });

  factory DashboardData.fromJson(Map<String, dynamic> json) => DashboardData(
        stats: DashboardStats.fromJson(json['stats'] as Map<String, dynamic>),
        feeSummary:
            DashboardFeeSummary.fromJson(json['fee_summary'] as Map<String, dynamic>),
        monthlyAttendance: (json['monthly_attendance'] as List? ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList(),
        upcomingEvents: (json['upcoming_events'] as List? ?? [])
            .map((e) => UpcomingEvent.fromJson(e as Map<String, dynamic>))
            .toList(),
        recentStudents: (json['recent_students'] as List? ?? [])
            .map((e) => RecentStudent.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class MonthlyReportRow {
  final int? batchId;
  final String batchName;
  final int totalStudents;
  final int attendanceTotal;
  final int attendancePresent;
  final double attendancePercentage;
  final String feesDue;
  final String feesPaid;
  final String feeOutstanding;
  final double feeCollectionRate;

  const MonthlyReportRow({
    this.batchId,
    required this.batchName,
    required this.totalStudents,
    required this.attendanceTotal,
    required this.attendancePresent,
    required this.attendancePercentage,
    required this.feesDue,
    required this.feesPaid,
    required this.feeOutstanding,
    required this.feeCollectionRate,
  });

  double get dueValue => double.tryParse(feesDue) ?? 0;
  double get paidValue => double.tryParse(feesPaid) ?? 0;

  factory MonthlyReportRow.fromJson(Map<String, dynamic> json) =>
      MonthlyReportRow(
        batchId: json['batch_id'] as int?,
        batchName: json['batch_name'] as String? ?? '',
        totalStudents: json['total_students'] as int? ?? 0,
        attendanceTotal: json['attendance_total'] as int? ?? 0,
        attendancePresent: json['attendance_present'] as int? ?? 0,
        attendancePercentage: (json['attendance_percentage'] as num?)?.toDouble() ?? 0,
        feesDue: (json['fees_due'] ?? '0').toString(),
        feesPaid: (json['fees_paid'] ?? '0').toString(),
        feeOutstanding: (json['fee_outstanding'] ?? '0').toString(),
        feeCollectionRate: (json['fee_collection_rate'] as num?)?.toDouble() ?? 0,
      );
}

class MonthlyReport {
  final String month;
  final List<MonthlyReportRow> rows;

  const MonthlyReport({required this.month, required this.rows});

  factory MonthlyReport.fromJson(Map<String, dynamic> json) => MonthlyReport(
        month: json['month'] as String,
        rows: (json['rows'] as List? ?? [])
            .map((e) => MonthlyReportRow.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}