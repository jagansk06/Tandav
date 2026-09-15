class Fee {
  final int id;
  final int studentId;
  final String studentName;
  final String month;
  final String amountDue;
  final String amountPaid;
  final String status;
  final String? paymentDate;
  final String? paymentMethod;
  final String? notes;

  /// The student's total unpaid balance carried forward through [month]
  /// (inclusive) — the sum of `amount_due − amount_paid` over every record up
  /// to and including this month. On the register this is what the owner
  /// actually chases; the row's own `amountDue − amountPaid` is only that
  /// month's share. Blank for rows built outside the register by callers that
  /// did not ask for it ([pendingValue] then falls back to the month's own
  /// amount).
  final String runningOutstanding;

  const Fee({
    required this.id,
    required this.studentId,
    this.studentName = '',
    required this.month,
    required this.amountDue,
    required this.amountPaid,
    required this.status,
    this.paymentDate,
    this.paymentMethod,
    this.notes,
    this.runningOutstanding = '',
  });

  double get dueValue => double.tryParse(amountDue) ?? 0;
  double get paidValue => double.tryParse(amountPaid) ?? 0;
  double get outstanding => (dueValue - paidValue).clamp(0, double.infinity);

  /// The carry-forward balance this student owes as of this row's month, or —
  /// when the row was not annotated with one — this month's own outstanding.
  double get pendingValue =>
      double.tryParse(runningOutstanding) ?? outstanding;

  factory Fee.fromJson(Map<String, dynamic> json) => Fee(
        id: json['id'] as int,
        studentId: json['student_id'] as int,
        studentName: json['student_name'] as String? ?? '',
        month: json['month'] as String,
        amountDue: (json['amount_due'] ?? '0').toString(),
        amountPaid: (json['amount_paid'] ?? '0').toString(),
        status: json['status'] as String? ?? 'due',
        paymentDate: json['payment_date'] as String?,
        paymentMethod: json['payment_method'] as String?,
        notes: json['notes'] as String?,
        runningOutstanding: (json['running_outstanding'] ?? '').toString(),
      );
}

class FeeListResponse {
  final List<Fee> items;
  final int total;

  const FeeListResponse({required this.items, required this.total});

  factory FeeListResponse.fromJson(Map<String, dynamic> json) => FeeListResponse(
        items: (json['items'] as List)
            .map((e) => Fee.fromJson(e as Map<String, dynamic>))
            .toList(),
        total: json['total'] as int? ?? 0,
      );
}

class FeeSummary {
  final String month;
  final String totalDue;
  final String totalPaid;
  final String outstanding;
  final int paidCount;
  final int partialCount;
  final int dueCount;
  final int totalRecords;
  final double collectionRate;

  const FeeSummary({
    required this.month,
    required this.totalDue,
    required this.totalPaid,
    required this.outstanding,
    required this.paidCount,
    required this.partialCount,
    required this.dueCount,
    required this.totalRecords,
    required this.collectionRate,
  });

  double get dueValue => double.tryParse(totalDue) ?? 0;

  factory FeeSummary.fromJson(Map<String, dynamic> json) => FeeSummary(
        month: json['month'] as String,
        totalDue: (json['total_due'] ?? '0').toString(),
        totalPaid: (json['total_paid'] ?? '0').toString(),
        outstanding: (json['outstanding'] ?? '0').toString(),
        paidCount: json['paid_count'] as int? ?? 0,
        partialCount: json['partial_count'] as int? ?? 0,
        dueCount: json['due_count'] as int? ?? 0,
        totalRecords: json['total_records'] as int? ?? 0,
        collectionRate: (json['collection_rate'] as num?)?.toDouble() ?? 0,
      );
}