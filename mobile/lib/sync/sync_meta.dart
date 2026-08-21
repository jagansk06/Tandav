import '../database/tandav_database.dart';

/// Per-record synchronization metadata written on every create/update/delete.
///
/// - [uuid] is a stable identity that lets the same logical record be mapped
///   across both devices (their local integer ids will differ).
/// - [deviceId] records which device last modified the record (used as the
///   tie-breaker for conflict resolution and to avoid echoing changes back).
/// - [updatedAt] is a UTC ISO-8601 timestamp used for last-write-wins.
class SyncStamp {
  final String uuid;
  final String deviceId;
  final String updatedAt;

  const SyncStamp({
    required this.uuid,
    required this.deviceId,
    required this.updatedAt,
  });

  /// Column values to merge with the business payload on insert.
  Map<String, Object?> columns() => {
        'sync_uuid': uuid,
        'device_id': deviceId,
        'updated_at': updatedAt,
      };

  /// Column values to set on update. [uuid] and origin [deviceId] never
  /// change once a record exists — only the modifying device and time do.
  Map<String, Object?> touchColumns() => {
        'device_id': deviceId,
        'updated_at': updatedAt,
      };

  /// Column values for a tombstone (soft delete) — same as an update plus the
  /// `deleted_at` timestamp.
  Map<String, Object?> tombstoneColumns() => {
        'device_id': deviceId,
        'updated_at': updatedAt,
        'deleted_at': updatedAt,
      };

  static SyncStamp now(TandavDatabase db) => SyncStamp(
        uuid: TandavDatabase.generateSyncUuid(),
        deviceId: db.deviceId,
        updatedAt: DateTime.now().toUtc().toIso8601String(),
      );
}