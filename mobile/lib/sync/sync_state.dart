import 'package:sqflite/sqflite.dart';

import '../database/tandav_database.dart';

/// Transaction-capable database executor (either the Database itself or a
/// sqflite Transaction).
typedef SyncExecutor = DatabaseExecutor;

/// Persistent sync state, stored in the `sync_state` key/value table (created
/// at schema v2, alongside the device id itself).
///
/// Keys exposed here:
/// - `device_id`          -> this installation's TANDAV-XXXX id (also on
///                           [TandavDatabase.deviceId])
///
/// Keys owned by [CloudSyncManager] and read through it, not here:
/// `cloud_account`, `cloud_peer_device_id`, `cloud_last_sync_at`.
///
/// Keys that may still exist in databases written by older builds and are now
/// dead: `paired_device_id`, `pairing_secret`, `last_sync_at`. They belonged to
/// the Bluetooth transport. Nothing reads them; they are left in place rather
/// than migrated away because deleting rows buys nothing and a migration that
/// touches `sync_state` risks the identity the whole sync design rests on.
class SyncState {
  final TandavDatabase db;
  SyncState(this.db);

  Future<Database> get _d => db.open();

  Future<String?> read(String key) async {
    final d = await _d;
    final rows =
        await d.query('sync_state', where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> write(String key, String? value) async {
    final d = await _d;
    if (value == null) {
      await d.delete('sync_state', where: 'key = ?', whereArgs: [key]);
    } else {
      await d.insert('sync_state', {'key': key, 'value': value},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  /// Read a key inside an open transaction so watermark updates are atomic
  /// with the rows they describe.
  Future<String?> readWithin(SyncExecutor ex, String key) async {
    final rows = await ex
        .query('sync_state', where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> writeWithin(SyncExecutor ex, String key, String? value) async {
    if (value == null) {
      await ex.delete('sync_state', where: 'key = ?', whereArgs: [key]);
    } else {
      await ex.insert('sync_state', {'key': key, 'value': value},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  String get deviceId => db.deviceId;

  // NOTE: the per-table sync marks deliberately live in SyncEngine
  // (SyncEngine.sentKey / SyncEngine.receivedKey) and are read and written
  // inside the same transaction as the rows they describe. Convenience getters
  // used to sit here and invited the assumption that one mark governs both
  // directions, which cost us a data-loss bug; there are two marks and only
  // `sent.<table>` may gate what we transmit.
}