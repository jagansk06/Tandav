class MonthlyProgress {
  final int id;
  final int studentId;
  final String studentName;
  final String month;
  final int skillRating;
  final int performanceRating;
  final int disciplineRating;
  final double overallScore;
  final double? attendancePercentage;
  final String? remarks;

  const MonthlyProgress({
    required this.id,
    required this.studentId,
    this.studentName = '',
    required this.month,
    required this.skillRating,
    required this.performanceRating,
    required this.disciplineRating,
    required this.overallScore,
    this.attendancePercentage,
    this.remarks,
  });

  factory MonthlyProgress.fromJson(Map<String, dynamic> json) => MonthlyProgress(
        id: json['id'] as int,
        studentId: json['student_id'] as int,
        studentName: json['student_name'] as String? ?? '',
        month: json['month'] as String,
        skillRating: json['skill_rating'] as int? ?? 0,
        performanceRating: json['performance_rating'] as int? ?? 0,
        disciplineRating: json['discipline_rating'] as int? ?? 0,
        overallScore: (json['overall_score'] as num?)?.toDouble() ?? 0,
        attendancePercentage: (json['attendance_percentage'] as num?)?.toDouble(),
        remarks: json['remarks'] as String?,
      );
}

class ProgressListResponse {
  final List<MonthlyProgress> items;
  final int total;

  const ProgressListResponse({required this.items, required this.total});

  factory ProgressListResponse.fromJson(Map<String, dynamic> json) =>
      ProgressListResponse(
        items: (json['items'] as List)
            .map((e) => MonthlyProgress.fromJson(e as Map<String, dynamic>))
            .toList(),
        total: json['total'] as int? ?? 0,
      );
}