class Batch {
  final int id;
  final String name;
  final String danceStyle;
  final String level;
  final String schedule;
  final String monthlyFee;
  final bool isActive;
  final String? notes;
  final int studentCount;

  const Batch({
    required this.id,
    required this.name,
    this.danceStyle = '',
    this.level = '',
    this.schedule = '',
    this.monthlyFee = '0',
    this.isActive = true,
    this.notes,
    this.studentCount = 0,
  });

  factory Batch.fromJson(Map<String, dynamic> json) => Batch(
        id: json['id'] as int,
        name: json['name'] as String,
        danceStyle: json['dance_style'] as String? ?? '',
        level: json['level'] as String? ?? '',
        schedule: json['schedule'] as String? ?? '',
        monthlyFee: (json['monthly_fee'] ?? '0').toString(),
        isActive: json['is_active'] as bool? ?? true,
        notes: json['notes'] as String?,
        studentCount: json['student_count'] as int? ?? 0,
      );

  Map<String, dynamic> toJson({bool includeId = false}) => {
        if (includeId) 'id': id,
        'name': name,
        'dance_style': danceStyle,
        'level': level,
        'schedule': schedule,
        'monthly_fee': monthlyFee,
        'is_active': isActive,
        'notes': notes,
      };
}

class BatchListResponse {
  final List<Batch> items;
  final int total;

  const BatchListResponse({required this.items, required this.total});

  factory BatchListResponse.fromJson(Map<String, dynamic> json) => BatchListResponse(
        items: (json['items'] as List)
            .map((e) => Batch.fromJson(e as Map<String, dynamic>))
            .toList(),
        total: json['total'] as int? ?? 0,
      );
}