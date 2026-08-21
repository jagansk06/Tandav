class Student {
  final int id;
  final String firstName;
  final String lastName;
  final String gender;
  final String? dob;
  final String phone;
  final String? email;
  final String? address;
  final String? emergencyContactName;
  final String? emergencyContactPhone;
  final int? batchId;
  final String? batchName;
  final String monthlyFee;
  final String? joinDate;
  final bool isActive;
  final String? photoUrl;
  final String? notes;

  const Student({
    required this.id,
    required this.firstName,
    this.lastName = '',
    this.gender = '',
    this.dob,
    required this.phone,
    this.email,
    this.address,
    this.emergencyContactName,
    this.emergencyContactPhone,
    this.batchId,
    this.batchName,
    this.monthlyFee = '0',
    this.joinDate,
    this.isActive = true,
    this.photoUrl,
    this.notes,
  });

  String get fullName => '$firstName $lastName'.trim();

  factory Student.fromJson(Map<String, dynamic> json) => Student(
        id: json['id'] as int,
        firstName: json['first_name'] as String,
        lastName: json['last_name'] as String? ?? '',
        gender: json['gender'] as String? ?? '',
        dob: json['dob'] as String?,
        phone: json['phone'] as String? ?? '',
        email: json['email'] as String?,
        address: json['address'] as String?,
        emergencyContactName: json['emergency_contact_name'] as String?,
        emergencyContactPhone: json['emergency_contact_phone'] as String?,
        batchId: json['batch_id'] as int?,
        batchName: json['batch_name'] as String?,
        monthlyFee: (json['monthly_fee'] ?? '0').toString(),
        joinDate: json['join_date'] as String?,
        isActive: json['is_active'] as bool? ?? true,
        photoUrl: json['photo_url'] as String?,
        notes: json['notes'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'first_name': firstName,
        'last_name': lastName,
        'gender': gender,
        'dob': dob,
        'phone': phone,
        'email': email,
        'address': address,
        'emergency_contact_name': emergencyContactName,
        'emergency_contact_phone': emergencyContactPhone,
        'batch_id': batchId,
        'monthly_fee': monthlyFee,
        'join_date': joinDate,
        'is_active': isActive,
        'notes': notes,
      };
}

class StudentListResponse {
  final List<Student> items;
  final int total;

  const StudentListResponse({required this.items, required this.total});

  factory StudentListResponse.fromJson(Map<String, dynamic> json) =>
      StudentListResponse(
        items: (json['items'] as List)
            .map((e) => Student.fromJson(e as Map<String, dynamic>))
            .toList(),
        total: json['total'] as int? ?? 0,
      );
}