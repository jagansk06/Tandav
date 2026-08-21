class EventItem {
  final int id;
  final String name;
  final String? description;
  final String eventType;
  final String eventDate;
  final String? location;
  final int? batchId;
  final String? batchName;
  final bool isActive;
  final int participantCount;

  const EventItem({
    required this.id,
    required this.name,
    this.description,
    this.eventType = '',
    required this.eventDate,
    this.location,
    this.batchId,
    this.batchName,
    this.isActive = true,
    this.participantCount = 0,
  });

  factory EventItem.fromJson(Map<String, dynamic> json) => EventItem(
        id: json['id'] as int,
        name: json['name'] as String,
        description: json['description'] as String?,
        eventType: json['event_type'] as String? ?? '',
        eventDate: json['event_date'] as String,
        location: json['location'] as String?,
        batchId: json['batch_id'] as int?,
        batchName: json['batch_name'] as String?,
        isActive: json['is_active'] as bool? ?? true,
        participantCount: json['participant_count'] as int? ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'event_type': eventType,
        'event_date': eventDate,
        'location': location,
        'batch_id': batchId,
        'is_active': isActive,
      };
}

class EventListResponse {
  final List<EventItem> items;
  final int total;

  const EventListResponse({required this.items, required this.total});

  factory EventListResponse.fromJson(Map<String, dynamic> json) =>
      EventListResponse(
        items: (json['items'] as List)
            .map((e) => EventItem.fromJson(e as Map<String, dynamic>))
            .toList(),
        total: json['total'] as int? ?? 0,
      );
}

class EventParticipation {
  final int id;
  final int eventId;
  final int studentId;
  final String studentName;
  final String? batchName;
  final String source;
  final bool isCostumeRequired;
  final String costumeFeeDue;
  final String costumeFeePaid;
  final String costumeStatus;
  final String? costumePaidDate;
  final String? costumePaymentMethod;
  final String? notes;
  final String registeredAt;

  const EventParticipation({
    required this.id,
    required this.eventId,
    required this.studentId,
    this.studentName = '',
    this.batchName,
    this.source = 'individual',
    this.isCostumeRequired = false,
    this.costumeFeeDue = '0',
    this.costumeFeePaid = '0',
    this.costumeStatus = 'none',
    this.costumePaidDate,
    this.costumePaymentMethod,
    this.notes,
    this.registeredAt = '',
  });

  double get dueValue => double.tryParse(costumeFeeDue) ?? 0;
  double get paidValue => double.tryParse(costumeFeePaid) ?? 0;
  double get outstanding => (dueValue - paidValue).clamp(0, double.infinity);

  factory EventParticipation.fromJson(Map<String, dynamic> json) =>
      EventParticipation(
        id: json['id'] as int,
        eventId: json['event_id'] as int,
        studentId: json['student_id'] as int,
        studentName: json['student_name'] as String? ?? '',
        batchName: json['batch_name'] as String?,
        source: json['source'] as String? ?? 'individual',
        isCostumeRequired: json['is_costume_required'] as bool? ?? false,
        costumeFeeDue: (json['costume_fee_due'] ?? '0').toString(),
        costumeFeePaid: (json['costume_fee_paid'] ?? '0').toString(),
        costumeStatus: json['costume_status'] as String? ?? 'none',
        costumePaidDate: json['costume_paid_date'] as String?,
        costumePaymentMethod: json['costume_payment_method'] as String?,
        notes: json['notes'] as String?,
        registeredAt: json['registered_at'] as String? ?? '',
      );
}

class ParticipationListResponse {
  final List<EventParticipation> items;
  final int total;

  const ParticipationListResponse({required this.items, required this.total});

  factory ParticipationListResponse.fromJson(Map<String, dynamic> json) =>
      ParticipationListResponse(
        items: (json['items'] as List)
            .map((e) => EventParticipation.fromJson(e as Map<String, dynamic>))
            .toList(),
        total: json['total'] as int? ?? 0,
      );
}

class CostumeSummary {
  final String totalDue;
  final String totalPaid;
  final String outstanding;

  const CostumeSummary({
    required this.totalDue,
    required this.totalPaid,
    required this.outstanding,
  });

  factory CostumeSummary.fromJson(Map<String, dynamic> json) => CostumeSummary(
        totalDue: (json['total_costume_due'] ?? '0').toString(),
        totalPaid: (json['total_costume_paid'] ?? '0').toString(),
        outstanding: (json['outstanding'] ?? '0').toString(),
      );
}