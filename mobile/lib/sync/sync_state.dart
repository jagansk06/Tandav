import 'package:sqflite/sqflite.dart';

import '../database/tandav_database.dart';

/// Transaction-capable database executor (either the Database itself or a
/// sqflite Transaction).
typedef SyncExecutor = DatabaseExecutor;

/// Persistent two-device sync state, stored in the `sync_state` key/value
/// table (created at schema v2, alongside the device id itself).
///
/// Keys exposed here:
/// - `device_id`          -> this installation's TANDAV-XXXX id (also on
///                           [TandavDatabase.deviceId])
/// - `paired_device_id`   -> the other master device's TANDAV-XXXX id
/// - `pairing_secret`     -> shared secret established during pairing used by
///                           the AUTH handshake on every sync
/// - `last_sync_at`       -> last successful sync timestamp (ISO-8601)
/// - `watermark.<table>`  -> per-table high-water mark of what we have already
///                           applied from the peer, so the next sync only
///                           transfers records that changed since then
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

  Future<String?> get pairedDeviceId => read('paired_device_id');

  Future<void> setPairedDeviceId(String? id) => write('paired_device_id', id);

  Future<String?> get pairingSecret => read('pairing_secret');

  Future<void> setPairingSecret(String? secret) => write('pairing_secret', secret);

  Future<String?> get lastSyncAt => read('last_sync_at');

  Future<void> setLastSyncAt(String iso) => write('last_sync_at', iso);

  /// True once this device has completed a verified pairing with another
  /// device (i.e. `paired_device_id` is set).
  Future<bool> get isPaired async {
    final id = await pairedDeviceId;
    return id != null && id.isNotEmpty;
  }

  // NOTE: the per-table sync marks deliberately live in SyncEngine
  // (SyncEngine.sentKey / SyncEngine.receivedKey) and are read and written
  // inside the same transaction as the rows they describe. Convenience getters
  // used to sit here and invited the assumption that one mark governs both
  // directions, which cost us a data-loss bug; there are two marks and only
  // `sent.<table>` may gate what we transmit.
}