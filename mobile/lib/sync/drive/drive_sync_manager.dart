import 'dart:async';

import 'package:http/http.dart' as http;

import '../../database/tandav_database.dart';
import '../sync_engine.dart';
import '../sync_state.dart';
import 'drive_auth.dart';
import 'drive_client.dart';
import 'drive_config.dart';
import 'sync_payload.dart';

/// Where a sync has got to. Drives the status UI.
enum DriveSyncPhase {
  idle,
  connecting, // talking to Google sign-in
  preparing, // resolving the Tandav folder in Drive
  downloading, // fetching the other devices' data
  merging, // applying it to the local database
  uploading, // publishing this device's data
  complete,
  failed,
  offline, // no usable network; local data is untouched and still usable
}

class DriveSyncStatus {
  final DriveSyncPhase phase;
  final String message;
  final int applied;
  final int skipped;

  const DriveSyncStatus(
    this.phase,
    this.message, {
    this.applied = 0,
    this.skipped = 0,
  });

  bool get isBusy =>
      phase != DriveSyncPhase.idle &&
      phase != DriveSyncPhase.complete &&
      phase != DriveSyncPhase.failed &&
      phase != DriveSyncPhase.offline;
}

/// Everything the Device & Sync screen needs to render, read in one go.
class DriveSyncInfo {
  final String deviceId;
  final bool connected;
  final String? accountEmail;
  final String? lastSyncAt;
  final String? lastError;
  final List<String> peerDevices;

  const DriveSyncInfo({
    required this.deviceId,
    required this.connected,
    this.accountEmail,
    this.lastSyncAt,
    this.lastError,
    this.peerDevices = const [],
  });
}

/// Synchronizes Tandav through a folder in the user's own Google Drive.
///
/// ## Why a folder of per-device files
///
/// ```
/// Google Drive
/// └── Tandav
///     └── sync
///         ├── tandav_sync_data.json      merged snapshot (informational)
///         └── devices
///             ├── TANDAV-A7F3.json       written ONLY by the Android phone
///             └── TANDAV-B291.json       written ONLY by the iPhone web app
/// ```
///
/// Each device writes exactly one file and reads all the others. Because every
/// file has a single writer, two devices syncing at the same moment can never
/// overwrite each other — the classic "download, replace, upload" approach
/// loses whichever device uploaded first, which is exactly the data loss this
/// layout makes structurally impossible.
///
/// A device's file holds every row it currently *owns* (`device_id` = that
/// device), tombstones included. Ownership moves to whichever device edited a
/// row last, so each row lives in exactly one file, the union of the files is
/// the whole dataset, and a stale copy disappears from the previous owner's
/// file on its next sync. Nothing is ever blindly overwritten: incoming rows
/// are **merged** row by row through [SyncEngine], which resolves conflicts by
/// last-write-wins on `updated_at` (ties broken by the higher `device_id`, so
/// both devices always reach the same answer), remaps foreign keys via stable
/// UUIDs, and matches on natural business keys so the same student, batch, fee
/// or attendance record created on both devices merges into one row instead of
/// duplicating.
///
/// The whole merge runs in a single database transaction: a failure rolls back
/// and the local database is never left half-updated.
class DriveSyncManager {
  final TandavDatabase db;
  final SyncState state;
  final SyncEngine engine;
  final DriveAuth auth;

  /// Called after a sync applies remote rows, so screens holding cached query
  /// results (the Attendance batch list, the fee register, the dashboard)
  /// reload and show the newly arrived data without an app restart.
  void Function()? onDataChanged;

  final _status = StreamController<DriveSyncStatus>.broadcast();
  Stream<DriveSyncStatus> get status => _status.stream;

  DriveSyncStatus _last = const DriveSyncStatus(DriveSyncPhase.idle, 'Idle');
  DriveSyncStatus get lastStatus => _last;

  late final DriveClient _drive = DriveClient(
    accessToken: () => auth.accessToken(),
    httpClient: httpClient,
  );

  /// Injected only by tests, so they can serve canned Drive responses without
  /// touching the network.
  final http.Client? httpClient;
  bool _syncing = false;

  DriveSyncManager({
    required this.db,
    required this.state,
    required this.engine,
    DriveAuth? auth,
    this.httpClient,
  }) : auth = auth ?? createDriveAuth();

  String get deviceId => state.deviceId;

  bool get isConnected => auth.isConnected;

  // ------------------------------------------------------------ connection

  /// Reconnect silently at startup if the user already approved this device.
  /// Never shows UI and never throws.
  Future<bool> restore() async {
    try {
      return await auth.restore();
    } on Object {
      return false;
    }
  }

  /// Connect interactively. Must be called straight from a button tap so the
  /// browser does not block the Google popup.
  Future<void> connect() async {
    _emit(DriveSyncPhase.connecting, 'Opening Google sign-in…');
    try {
      await auth.connect();
      final email = await _drive.accountEmail();
      await state.setDriveAccountEmail(email);
      await state.setDriveLastError(null);
      _emit(DriveSyncPhase.idle, 'Connected to ${email ?? 'Google Drive'}.');
    } on DriveAuthException catch (e) {
      if (e.cancelled) {
        _emit(DriveSyncPhase.idle, 'Sign-in cancelled.');
        return;
      }
      await _recordFailure(e.message);
      rethrow;
    } on DriveException catch (e) {
      await _recordFailure(e.message);
      rethrow;
    }
  }

  /// Disconnect this device. Local data is never touched, and the Drive files
  /// are left in place so the other device keeps working.
  Future<void> disconnect() async {
    await auth.disconnect();
    await state.setDriveAccountEmail(null);
    await state.clearDriveFolderCache();
    await state.setDriveLastError(null);
    _emit(DriveSyncPhase.idle, 'Google Drive disconnected.');
  }

  /// Snapshot of the persisted sync state for the UI.
  Future<DriveSyncInfo> info() async {
    return DriveSyncInfo(
      deviceId: state.deviceId,
      connected: auth.isConnected,
      accountEmail: await state.driveAccountEmail,
      lastSyncAt: await state.lastSyncAt,
      lastError: await state.driveLastError,
      peerDevices: await state.drivePeerDevices,
    );
  }

  // ------------------------------------------------------------------ sync

  /// Download every other device's data, merge it into the local database,
  /// then publish this device's data. Safe to call repeatedly.
  Future<void> syncNow() async {
    if (_syncing) return;
    _syncing = true;
    try {
      await _runSync(allowRetry: true);
    } finally {
      _syncing = false;
    }
  }

  Future<void> _runSync({required bool allowRetry}) async {
    try {
      _emit(DriveSyncPhase.preparing, 'Opening your Tandav folder in Drive…');
      final folders = await _ensureFolders();

      // ---- 1. Read every other device's file ----
      _emit(DriveSyncPhase.downloading, 'Checking for changes from your other device…');
      final ourShardName = DriveConfig.shardFileName(deviceId);
      final children = await _drive.listChildren(folders.devicesFolderId);
      final peerFiles =
          children.where((f) => f.name != ourShardName && f.name.endsWith('.json'));

      final payloads = <ParsedPayload>[];
      final peerIds = <String>[];
      for (final file in peerFiles) {
        final text = await _drive.downloadText(file.id);
        final parsed = SyncPayload.decode(text);
        if (parsed.isEmpty) continue;
        payloads.add(parsed);
        if (parsed.deviceId.isNotEmpty) peerIds.add(parsed.deviceId);
      }

      // ---- 2. Merge into the local database, then read back what we own ----
      _emit(DriveSyncPhase.merging, 'Merging changes…');
      final incoming = SyncPayload.combine(payloads);
      final database = await db.open();
      late SyncApplyResult applyResult;
      late SyncDelta ours;
      await database.transaction((txn) async {
        applyResult = incoming.isEmpty
            ? SyncApplyResult()
            : await engine.applyIncoming(txn, incoming,
                peerDeviceId: peerIds.isEmpty ? 'unknown' : peerIds.first);
        // Computed *after* applying, inside the same transaction: rows the
        // other device just took over are no longer ours to publish, and rows
        // we won stay ours. One transaction also means the published snapshot
        // can never disagree with what we just merged.
        ours = await engine.computeOutbound(txn, ownedBy: deviceId);
      });

      final applied = applyResult.totalApplied;
      final skipped = _sumOf(applyResult.conflictsSkipped) +
          _sumOf(applyResult.orphansSkipped);

      if (applied > 0) onDataChanged?.call();

      // ---- 3. Publish our own file, but only if it actually changed ----
      final tables = SyncPayload.encodeTables(ours);
      final hash = SyncPayload.contentHash(tables);
      if (hash != await state.driveShardHash) {
        _emit(DriveSyncPhase.uploading, 'Uploading your changes…',
            applied: applied, skipped: skipped);
        final doc = SyncPayload.encodeShard(
          deviceId: deviceId,
          delta: ours,
          uploadedAt: DateTime.now().toUtc().toIso8601String(),
        );
        await _drive.writeTextFile(
          name: ourShardName,
          parentId: folders.devicesFolderId,
          content: SyncPayload.toJsonString(doc),
        );
        await state.setDriveShardHash(hash);

        // Best-effort merged snapshot at the path the layout advertises. It is
        // never read back in preference to the shards, so if two devices race
        // here the worst case is a momentarily stale convenience file — no
        // business data can be lost.
        await _writeMergedSnapshot(
          folderId: folders.syncFolderId,
          ourTables: tables,
          peers: payloads,
          deviceIds: {deviceId, ...peerIds},
        );
      }

      // ---- 4. Record success ----
      final now = DateTime.now().toUtc().toIso8601String();
      await state.setLastSyncAt(now);
      await state.setDriveLastError(null);
      if (peerIds.isNotEmpty) await state.setDrivePeerDevices(peerIds);
      final email = await state.driveAccountEmail;
      if (email == null) {
        await state.setDriveAccountEmail(await _drive.accountEmail());
      }

      _emit(
        DriveSyncPhase.complete,
        applied == 0 && skipped == 0
            ? 'Synchronization complete ✓ Already up to date.'
            : 'Synchronization complete ✓ $applied change'
                '${applied == 1 ? '' : 's'} applied'
                '${skipped > 0 ? ', $skipped already current' : ''}.',
        applied: applied,
        skipped: skipped,
      );
    } on DriveAuthException catch (e) {
      if (e.cancelled) {
        _emit(DriveSyncPhase.idle, 'Sign-in cancelled.');
        return;
      }
      await _recordFailure(e.message);
    } on DriveException catch (e) {
      // A rejected token or a folder the user moved/deleted are both worth one
      // silent retry before bothering the user.
      if (allowRetry && (e.isUnauthorized || e.isNotFound)) {
        if (e.isUnauthorized) auth.invalidate();
        if (e.isNotFound) await state.clearDriveFolderCache();
        await _runSync(allowRetry: false);
        return;
      }
      await _recordFailure(e.message);
    } on Object catch (e) {
      if (_looksOffline(e)) {
        final last = await state.lastSyncAt;
        _emit(
          DriveSyncPhase.offline,
          last == null
              ? 'Offline — connect to the internet to synchronize. Tandav '
                  'keeps working normally in the meantime.'
              : 'Offline — Tandav keeps working normally. Last synchronized: '
                  '$last',
        );
        return;
      }
      await _recordFailure('Synchronization failed: $e');
    }
  }

  Future<void> _writeMergedSnapshot({
    required String folderId,
    required Map<String, List<Map<String, Object?>>> ourTables,
    required List<ParsedPayload> peers,
    required Set<String> deviceIds,
  }) async {
    try {
      final merged = SyncPayload.combine([
        ...peers,
        ParsedPayload(deviceId: deviceId, uploadedAt: '', tables: ourTables),
      ]);
      final doc = SyncPayload.encodeMergedSnapshot(
        generatedBy: deviceId,
        generatedAt: DateTime.now().toUtc().toIso8601String(),
        devices: deviceIds,
        tables: merged,
      );
      await _drive.writeTextFile(
        name: DriveConfig.mergedFileName,
        parentId: folderId,
        content: SyncPayload.toJsonString(doc),
      );
    } on Object catch (_) {
      // Purely a convenience file — a failure here must not fail the sync,
      // because the authoritative per-device shards are already uploaded.
    }
  }

  /// Resolve (creating if needed) `Tandav/sync` and `Tandav/sync/devices`,
  /// caching the ids so later syncs skip three lookups.
  Future<_SyncFolders> _ensureFolders() async {
    final cachedSync = await state.driveFolderId;
    final cachedDevices = await state.driveDevicesFolderId;
    if (cachedSync != null && cachedDevices != null) {
      return _SyncFolders(syncFolderId: cachedSync, devicesFolderId: cachedDevices);
    }

    final root = await _drive.ensureFolder(DriveConfig.rootFolderName);
    final sync =
        await _drive.ensureFolder(DriveConfig.syncFolderName, parentId: root.id);
    final devices = await _drive.ensureFolder(DriveConfig.devicesFolderName,
        parentId: sync.id);

    await state.setDriveFolderId(sync.id);
    await state.setDriveDevicesFolderId(devices.id);
    return _SyncFolders(syncFolderId: sync.id, devicesFolderId: devices.id);
  }

  /// Network failures must be reported as "offline", not as a hard error, so
  /// the app never looks broken just because Drive is unreachable.
  ///
  /// Detected without importing `dart:io`, which does not exist on the web:
  /// `package:http` raises [http.ClientException] on both platforms, and the
  /// native socket errors are recognised by name.
  bool _looksOffline(Object error) {
    if (error is http.ClientException) return true;
    final text = error.toString();
    return text.contains('SocketException') ||
        text.contains('Failed host lookup') ||
        text.contains('Connection refused') ||
        text.contains('Connection closed') ||
        text.contains('XMLHttpRequest error');
  }

  int _sumOf(Map<String, int> counts) =>
      counts.values.fold(0, (a, b) => a + b);

  Future<void> _recordFailure(String reason) async {
    try {
      await state.setDriveLastError(reason);
    } on Object catch (_) {
      // Never let bookkeeping mask the original failure.
    }
    _emit(DriveSyncPhase.failed, reason);
  }

  void _emit(DriveSyncPhase phase, String message,
      {int applied = 0, int skipped = 0}) {
    _last = DriveSyncStatus(phase, message, applied: applied, skipped: skipped);
    if (!_status.isClosed) _status.add(_last);
  }

  void dispose() {
    _status.close();
    _drive.close();
  }
}

class _SyncFolders {
  final String syncFolderId;
  final String devicesFolderId;
  const _SyncFolders({required this.syncFolderId, required this.devicesFolderId});
}
