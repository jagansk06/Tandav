import 'package:sqflite/sqflite.dart';

import '../database/tandav_database.dart';

/// Transaction-capable database executor (either the Database itself or a
/// sqflite Transaction).
typedef SyncExecutor = DatabaseExecutor;

/// Persistent sync state, stored in the `sync_state` key/value table (created
/// at schema v2, alongside the device id itself).
///
/// Both devices remain equal masters — there is no master/slave and no
/// permanent pairing. The device id is kept purely as sync *metadata* (it
/// stamps every row so conflicts can be resolved deterministically and so each
/// device knows which rows it published); it is never used to restrict who may
/// synchronize.
///
/// Keys exposed here:
/// - `device_id`            -> this installation's TANDAV-XXXX id (also on
///                             [TandavDatabase.deviceId])
/// - `last_sync_at`         -> last successful sync timestamp (ISO-8601 UTC)
/// - `watermark.<table>`    -> per-table high-water mark of what we have
///                             already applied from peers
/// - `drive_account_email`  -> Google account currently connected (display only)
/// - `drive_folder_id`      -> cached id of the `Tandav/sync` Drive folder
/// - `drive_devices_folder_id` -> cached id of `Tandav/sync/devices`
/// - `drive_shard_hash`     -> hash of the payload we last uploaded, so an
///                             unchanged database costs no upload
/// - `drive_last_error`     -> reason for the last failed sync (shown in the UI)
/// - `drive_peer_devices`   -> comma-separated peer ids seen in the Drive folder
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

  Future<String?> get lastSyncAt => read('last_sync_at');

  Future<void> setLastSyncAt(String iso) => write('last_sync_at', iso);

  /// Per-table watermark: the newest `updated_at` we have already merged from
  /// a peer. Records newer than this are the incremental delta.
  Future<String> watermark(String table) async {
    return (await read('watermark.$table')) ?? '';
  }

  Future<void> setWatermark(String table, String maxUpdatedAt) =>
      write('watermark.$table', maxUpdatedAt);

  // ---------------------------------------------------------- Google Drive

  /// The Google account this device is connected to. Display only — no token,
  /// password or credential is ever persisted in the database.
  Future<String?> get driveAccountEmail => read('drive_account_email');

  Future<void> setDriveAccountEmail(String? email) =>
      write('drive_account_email', email);

  Future<String?> get driveFolderId => read('drive_folder_id');

  Future<void> setDriveFolderId(String? id) => write('drive_folder_id', id);

  Future<String?> get driveDevicesFolderId => read('drive_devices_folder_id');

  Future<void> setDriveDevicesFolderId(String? id) =>
      write('drive_devices_folder_id', id);

  Future<String?> get driveShardHash => read('drive_shard_hash');

  Future<void> setDriveShardHash(String? hash) =>
      write('drive_shard_hash', hash);

  Future<String?> get driveLastError => read('drive_last_error');

  Future<void> setDriveLastError(String? reason) =>
      write('drive_last_error', reason);

  /// Peer device ids we have merged data from, so the UI can show which other
  /// Tandav devices share this Drive folder.
  Future<List<String>> get drivePeerDevices async {
    final raw = await read('drive_peer_devices') ?? '';
    return raw.split(',').where((s) => s.isNotEmpty).toList();
  }

  Future<void> setDrivePeerDevices(Iterable<String> ids) =>
      write('drive_peer_devices', ids.toSet().join(','));

  /// Cached folder ids are only hints. If the user deletes the Tandav folder
  /// in Drive the ids go stale, so the sync manager clears them and re-resolves
  /// by name.
  Future<void> clearDriveFolderCache() async {
    await setDriveFolderId(null);
    await setDriveDevicesFolderId(null);
  }
}
