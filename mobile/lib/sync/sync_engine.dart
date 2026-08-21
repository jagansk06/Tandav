import 'package:sqflite/sqflite.dart';

import '../database/tandav_database.dart';
import 'sync_codec.dart';
import 'sync_state.dart';

/// Result of computing/sending our own changed rows.
class SyncDelta {
  /// table -> rows we have changed since the peer last saw our data.
  final Map<String, List<Map<String, Object?>>> tables = {};

  bool get isEmpty => tables.values.every((rows) => rows.isEmpty);

  int get rowCount => tables.values.fold(0, (sum, rows) => sum + rows.length);
}

/// Result of applying changes received from the peer.
class SyncApplyResult {
  final Map<String, int> applied = {}; // table -> rows applied (new or updated)
  final Map<String, int> conflictsSkipped = {}; // table -> older rows skipped
  final Map<String, int> orphansSkipped = {}; // table -> rows with missing parent

  int get totalApplied => applied.values.fold(0, (a, b) => a + b);
}

/// The incremental, conflict-resolving merge engine.
///
/// Strategy:
/// - **Incremental** – every table keeps a per-table watermark of the newest
///   `updated_at` value we have received from the peer. We only send records
///   newer than that watermark, so a full database dump is never transferred.
/// - **Conflict resolution** – last-write-wins by `updated_at` (UTC ISO-8601).
///   On equal timestamps the lexicographically higher `device_id` wins
///   (deterministic and stable across both devices).
/// - **Identity** – every record carries a stable `sync_uuid`; local integer
///   ids differ per device and are re-mapped on merge via FK->uuid resolution.
/// - **Deletions** – records are soft-deleted (tombstoned with `deleted_at`),
///   so a deletion reaches the peer instead of vanishing permanently.
/// - **Atomicity** – all inbound rows for all tables are applied inside one
///   transaction with the watermark advances; a failure rolls everything back
///   and the local database is never left half-updated.
class SyncEngine {
  final TandavDatabase db;
  final SyncState state;
  SyncEngine(this.db, this.state);

  /// Foreign-key columns per table: column name -> parent table.
  static const Map<String, Map<String, String>> fkMap = {
    'students': {'batch_id': 'batches'},
    'attendance': {'student_id': 'students', 'batch_id': 'batches'},
    'monthly_attendance': {'student_id': 'students'},
    'fees': {'student_id': 'students'},
    'fee_payments': {'fee_id': 'fees', 'student_id': 'students'},
    'events': {'batch_id': 'batches'},
    'event_participations': {'event_id': 'events', 'student_id': 'students'},
    'monthly_progress': {'student_id': 'students'},
  };

  /// Rows we must send to the peer: everything newer than the watermark.
  ///
  /// Called with a read-only transaction so the snapshot is consistent with
  /// the watermark it is based on.
  Future<SyncDelta> computeOutbound(Transaction txn) async {
    final delta = SyncDelta();
    for (final table in SyncCodec.applyOrder) {
      final wm = await state.readWithin(txn, 'watermark.$table') ?? '';
      final rows = wm.isEmpty
          ? await _selectAll(txn, table)
          : await txn.query(table, where: 'updated_at > ?', whereArgs: [wm]);
      if (rows.isEmpty) continue;
      final out = <Map<String, Object?>>[];
      for (final r in rows) {
        final copy = Map<String, Object?>.from(r);
        copy['_table'] = table;
        copy['_fk'] = await _fkUuids(txn, table, copy);
        out.add(copy);
      }
      delta.tables[table] = out;
    }
    return delta;
  }

  /// Apply rows received from the peer inside one transaction.
  Future<SyncApplyResult> applyIncoming(
    Transaction txn,
    Map<String, List<Map<String, Object?>>> incoming, {
    required String peerDeviceId,
  }) async {
    final result = SyncApplyResult();
    // uuid -> local id, built as parent tables are applied first so child
    // foreign keys can be resolved.
    final uuidMap = <String, Map<String, int>>{};

    for (final table in SyncCodec.applyOrder) {
      final rows = incoming[table];
      if (rows == null || rows.isEmpty) continue;
      result.applied[table] = 0;
      result.conflictsSkipped[table] = 0;
      result.orphansSkipped[table] = 0;
      final tableUuids = uuidMap.putIfAbsent(table, () => {});
      var orphans = false;
      List<String> advanceable = [];

      for (final raw in rows) {
        final row = Map<String, Object?>.from(raw);
        final uuid = (row['sync_uuid'] as String?) ?? '';
        if (uuid.isEmpty) continue;
        final updatedAt = (row['updated_at'] as String?) ?? '';

        final remapped = <String, Object?>{};
        for (final entry in row.entries) {
          if (entry.key == '_fk' || entry.key == '_table') continue;
          if (entry.key == 'id') continue; // local-only
          remapped[entry.key] = entry.value;
        }

        // Resolve foreign keys: peer id -> our local id via uuid.
        var orphaned = false;
        final fks = fkMap[table] ?? const <String, String>{};
        final fkUuidRows = row['_fk'] as Map<String, Object?>? ?? const {};
        for (final entry in fks.entries) {
          final parent = entry.value;
          final parentUuid = fkUuidRows[parent] as String?;
          if (parentUuid == null || parentUuid.isEmpty) {
            if (row[entry.key] != null) {
              orphaned = true;
              break;
            }
            remapped[entry.key] = null;
            continue;
          }
          final localParentId = uuidMap[parent]?[parentUuid];
          if (localParentId == null) {
            orphaned = true;
            break;
          }
          remapped[entry.key] = localParentId;
        }
        if (orphaned) {
          orphans = true;
          result.orphansSkipped[table] = result.orphansSkipped[table]! + 1;
          continue;
        }

        // Find the local counterpart.
        final existing = await _findByUuid(txn, table, tableUuids, uuid, remapped);
        if (existing == null) {
          final id = await txn.insert(table, remapped);
          tableUuids[uuid] = id;
          result.applied[table] = result.applied[table]! + 1;
          _maxOf(advanceable, updatedAt);
        } else {
          final localUpdatedAt = (existing['updated_at'] as String?) ?? '';
          final localDeviceId = (existing['device_id'] as String?) ?? '';
          remapped['sync_uuid'] = uuid;
          remapped['device_id'] = (row['device_id'] as String?) ?? peerDeviceId;
          final incomingDevice = (row['device_id'] as String?) ?? peerDeviceId;
          if (_newerThan(updatedAt, incomingDevice, localUpdatedAt, localDeviceId)) {
            await txn.update(table, remapped,
                where: 'id = ?', whereArgs: [existing['id']]);
            tableUuids[uuid] = existing['id'] as int;
            result.applied[table] = result.applied[table]! + 1;
            _maxOf(advanceable, updatedAt);
          } else if (updatedAt.compareTo(localUpdatedAt) < 0 ||
              (incomingDevice == localDeviceId &&
                  updatedAt.compareTo(localUpdatedAt) == 0)) {
            // Incoming is strictly older (our newer version wins), or it is
            // an exact echo of the local winner (same writer, same time).
            // Either way the peer will settle on our row, so it is safe to
            // advance the watermark past this record.
            tableUuids[uuid] = existing['id'] as int;
            result.conflictsSkipped[table] =
                result.conflictsSkipped[table]! + 1;
            _maxOf(advanceable, updatedAt);
          } else {
            // Perfect tie between two devices: the winner (higher device id)
            // must be re-transmitted, so do not advance the watermark past
            // this record yet.
            tableUuids[uuid] = existing['id'] as int;
            result.conflictsSkipped[table] =
                result.conflictsSkipped[table]! + 1;
          }
        }
      }

      // Advance the watermark only if nothing was orphaned — an orphaned row
      // may need the parent to arrive in a future sync, so it must be retried.
      if (advanceable.isNotEmpty && !orphans) {
        final current = await state.readWithin(txn, 'watermark.$table') ?? '';
        final maxSeen = advanceable.reduce((a, b) => a.compareTo(b) > 0 ? a : b);
        if (maxSeen.compareTo(current) > 0) {
          await state.writeWithin(txn, 'watermark.$table', maxSeen);
        }
      }
    }
    await state.writeWithin(txn, 'last_sync_at', DateTime.now().toUtc().toIso8601String());
    return result;
  }

  void _maxOf(List<String> list, String value) {
    if (value.compareTo(list.isEmpty ? '' : list.last) > 0) list.add(value);
  }

  /// Last-write-wins: newer `updatedAt` wins; on ties the higher `deviceId`
  /// wins (deterministic on both devices).
  bool _newerThan(String incomingAt, String incomingDevice,
      String localAt, String localDevice) {
    final cmp = incomingAt.compareTo(localAt);
    if (cmp != 0) return cmp > 0;
    final devCmp = incomingDevice.compareTo(localDevice);
    if (devCmp != 0) return devCmp > 0;
    return false; // identical row — nothing to change.
  }

  Future<List<Map<String, Object?>>> _selectAll(Transaction txn, String table) async {
    final rows = await txn.query(table);
    return rows.map((r) => Map<String, Object?>.from(r)).toList();
  }

  /// Match a row by uuid first, then by the table's natural unique key (so
  /// the same logical record created independently on both devices merges
  /// into one row instead of duplicating).
  Future<Map<String, Object?>?> _findByUuid(
    Transaction txn,
    String table,
    Map<String, int> tableUuids,
    String uuid,
    Map<String, Object?> remapped,
  ) async {
    final localId = tableUuids[uuid];
    if (localId != null) {
      final rows = await txn.query(table, where: 'id = ?', whereArgs: [localId]);
      return rows.isEmpty ? null : Map<String, Object?>.from(rows.first);
    }
    final rows = await txn.query(table,
        where: 'sync_uuid = ?', whereArgs: [uuid], limit: 1);
    if (rows.isNotEmpty) return Map<String, Object?>.from(rows.first);

    final natural = SyncCodec.naturalKeysFor(table);
    if (natural.isNotEmpty) {
      final conditions = <String>[];
      final args = <Object?>[];
      for (final key in natural) {
        conditions.add('$key = ?');
        args.add(remapped[key]);
      }
      conditions.add('deleted_at IS NULL');
      final nat = await txn.query(table,
          where: conditions.join(' AND '), whereArgs: args, limit: 1);
      if (nat.isNotEmpty) return Map<String, Object?>.from(nat.first);
    }
    return null;
  }

  /// Build the {parentTable: uuid} map for a row's foreign keys so the peer
  /// can resolve its local ids on the other side.
  Future<Map<String, Object?>> _fkUuids(
      Transaction txn, String table, Map<String, Object?> row) async {
    final out = <String, Object?>{};
    final fks = fkMap[table] ?? const <String, String>{};
    for (final entry in fks.entries) {
      final id = row[entry.key];
      if (id == null) continue;
      final parent = entry.value;
      final rows = await txn.query(parent,
          where: 'id = ?', whereArgs: [id], limit: 1);
      if (rows.isNotEmpty) out[parent] = rows.first['sync_uuid'];
    }
    return out;
  }
}