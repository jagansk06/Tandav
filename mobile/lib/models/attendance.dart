class AttendanceStudentRow {
  final int studentId;
  final String studentName;
  final int? batchId;
  final String? batchName;
  final String? status;
  final int? attendanceId;
  final String? notes;

  const AttendanceStudentRow({
    required this.studentId,
    required this.studentName,
    this.batchId,
    this.batchName,
    this.status,
    this.attendanceId,
    this.notes,
  });

  factory AttendanceStudentRow.fromJson(Map<String, dynamic> json) =>
      AttendanceStudentRow(
        studentId: json['student_id'] as int,
        studentName: json['student_name'] as String? ?? '',
        batchId: json['batch_id'] as int?,
        batchName: json['batch_name'] as String?,
        status: json['status'] as String?,
        attendanceId: json['attendance_id'] as int?,
        notes: json['notes'] as String?,
      );
}

class AttendanceDay {
  final String date;
  final int batchId;
  final String batchName;
  final int total;
  final int present;
  final int absent;
  final int late;
  final int unmarked;
  final double percentage;
  final List<AttendanceStudentRow> records;

  const AttendanceDay({
    required this.date,
    required this.batchId,
    required this.batchName,
    required this.total,
    required this.present,
    required this.absent,
    required this.late,
    required this.unmarked,
    required this.percentage,
    required this.records,
  });

  factory AttendanceDay.fromJson(Map<String, dynamic> json) => AttendanceDay(
        date: json['date'] as String,
        batchId: json['batch_id'] as int? ?? 0,
        batchName: json['batch_name'] as String? ?? '',
        total: json['total'] as int? ?? 0,
        present: json['present'] as int? ?? 0,
        absent: json['absent'] as int? ?? 0,
        late: json['late'] as int? ?? 0,
        unmarked: json['unmarked'] as int? ?? 0,
        percentage: (json['percentage'] as num?)?.toDouble() ?? 0,
        records: (json['records'] as List? ?? [])
            .map((e) => AttendanceStudentRow.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class MonthlyAttendanceSummary {
  final int studentId;
  final String studentName;
  final int? batchId;
  final String? batchName;
  final String month;
  final int totalClasses;
  final int presents;
  final int absents;
  final int lates;
  final double percentage;

  const MonthlyAttendanceSummary({
    required this.studentId,
    required this.studentName,
    this.batchId,
    this.batchName,
    required this.month,
    required this.totalClasses,
    required this.presents,
    required this.absents,
    required this.lates,
    required this.percentage,
  });

  factory MonthlyAttendanceSummary.fromJson(Map<String, dynamic> json) =>
      MonthlyAttendanceSummary(
        studentId: json['student_id'] as int,
        studentName: json['student_name'] as String? ?? '',
        batchId: json['batch_id'] as int?,
        batchName: json['batch_name'] as String?,
        month: json['month'] as String,
        totalClasses: json['total_classes'] as int? ?? 0,
        presents: json['presents'] as int? ?? 0,
        absents: json['absents'] as int? ?? 0,
        lates: json['lates'] as int? ?? 0,
        percentage: (json['percentage'] as num?)?.toDouble() ?? 0,
      );
}