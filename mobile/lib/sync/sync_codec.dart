import 'dart:convert';

/// Sync column definitions for every synchronized table.
///
/// The local integer `id` is deliberately excluded — it differs on every
/// device and is re-mapped during merge using `sync_uuid`. The sync columns
/// (`sync_uuid`, `device_id`, `updated_at`, `deleted_at`) are carried in the
/// payload so the receiver can merge, resolve conflicts and tombstone.
class SyncSchema {
  const SyncSchema({
    required this.columns,
    this.naturalKeys = const [],
  });

  /// Business columns transferred (the `id` column is never transferred).
  final List<String> columns;

  /// Unique columns that can be used to match an incoming row when no
  /// `sync_uuid` exists yet on the receiver (prevents duplicates when the
  /// same logical record was created independently on both devices).
  final List<String> naturalKeys;

  /// Parent-ish tables this table depends on; used for FK remap ordering.
  final List<String> dependsOn = const [];

  static const Map<String, SyncSchema> all = {
    'batches': SyncSchema(columns: [
      'name', 'dance_style', 'level', 'schedule', 'monthly_fee', 'is_active',
      'notes', 'created_at', 'updated_at', 'sync_uuid', 'device_id',
      'deleted_at',
    ], naturalKeys: ['name']),
    'students': SyncSchema(columns: [
      'first_name', 'last_name', 'gender', 'dob', 'phone', 'email', 'address',
      'emergency_contact_name', 'emergency_contact_phone', 'batch_id',
      'monthly_fee', 'join_date', 'is_active', 'photo_url', 'notes',
      'created_at', 'updated_at', 'sync_uuid', 'device_id', 'deleted_at',
    ], naturalKeys: []),
    'attendance': SyncSchema(columns: [
      'student_id', 'batch_id', 'attendance_date', 'status', 'notes',
      'marked_at', 'updated_at', 'sync_uuid', 'device_id', 'deleted_at',
    ], naturalKeys: ['student_id', 'attendance_date']),
    'monthly_attendance': SyncSchema(columns: [
      'student_id', 'month', 'total_classes', 'presents', 'absents', 'lates',
      'percentage', 'updated_at', 'sync_uuid', 'device_id', 'deleted_at',
    ], naturalKeys: ['student_id', 'month']),
    'fees': SyncSchema(columns: [
      'student_id', 'month', 'amount_due', 'amount_paid', 'status',
      'payment_date', 'payment_method', 'notes', 'created_at', 'updated_at',
      'sync_uuid', 'device_id', 'deleted_at',
    ], naturalKeys: ['student_id', 'month']),
    'fee_payments': SyncSchema(columns: [
      'fee_id', 'student_id', 'amount', 'payment_date', 'payment_method',
      'notes', 'created_at', 'updated_at', 'sync_uuid', 'device_id',
      'deleted_at',
    ], naturalKeys: []),
    'events': SyncSchema(columns: [
      'name', 'description', 'event_type', 'event_date', 'location',
      'batch_id', 'is_active', 'created_at', 'updated_at', 'sync_uuid',
      'device_id', 'deleted_at',
    ], naturalKeys: []),
    'event_participations': SyncSchema(columns: [
      'event_id', 'student_id', 'source', 'is_costume_required',
      'costume_fee_due', 'costume_fee_paid', 'costume_status',
      'costume_paid_date', 'costume_payment_method', 'notes', 'registered_at',
      'updated_at', 'sync_uuid', 'device_id', 'deleted_at',
    ], naturalKeys: ['event_id', 'student_id']),
    'monthly_progress': SyncSchema(columns: [
      'student_id', 'month', 'skill_rating', 'performance_rating',
      'discipline_rating', 'attendance_percentage', 'remarks', 'updated_at',
      'sync_uuid', 'device_id', 'deleted_at',
    ], naturalKeys: ['student_id', 'month']),
  };
}

/// Serialisation helpers shared by the sync engine and the protocol.
class SyncCodec {
  /// Rows must be applied in an order where referenced rows already exist, so
  /// foreign keys can be re-mapped.
  static const applyOrder = [
    'batches',
    'students',
    'attendance',
    'monthly_attendance',
    'fees',
    'fee_payments',
    'events',
    'event_participations',
    'monthly_progress',
  ];

  static List<String> columnsFor(String table) =>
      SyncSchema.all[table]!.columns;

  static List<String> naturalKeysFor(String table) =>
      SyncSchema.all[table]!.naturalKeys;

  /// Format a row for transfer: JSON-safe map of the table's sync columns,
  /// with numbers rounded and booleans stored as SQLite ints, plus a copy of
  /// the record's stable identity for convenience.
  static Map<String, Object?> encodeRow(Map<String, Object?> row) {
    final out = <String, Object?>{};
    if (row['_fk'] is Map) out['_fk'] = row['_fk'];
    for (final c in columnsFor(row['_table'] as String)) {
      final v = row[c];
      if (v == null) {
        out[c] = null;
      } else if (v is num) {
        out[c] = v is double ? double.parse(v.toStringAsFixed(4)) : v;
      } else {
        out[c] = v;
      }
    }
    return out;
  }

  static String encodeRowsToJson(String table, List<Map<String, Object?>> rows) {
    final payload = {
      'table': table,
      'rows': rows.map((r) => encodeRow(r)).toList(),
    };
    return jsonEncode(payload);
  }

  /// Parse a table payload produced by [encodeRowsToJson].
  static (String, List<Map<String, Object?>>) decodeRows(String jsonString) {
    final decoded = jsonDecode(jsonString) as Map<String, dynamic>;
    final table = decoded['table'] as String;
    final rows =
        (decoded['rows'] as List).cast<Map<String, dynamic>>().toList();
    return (table, rows);
  }

  static String encodeSyncUuid(int epochMillis, int suffix) =>
      'sync-$epochMillis-$suffix';
}