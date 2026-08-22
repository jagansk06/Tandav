/// Two-master sync over a store-and-forward [SyncMailbox] (e.g. a shared
/// Google Drive account) instead of Bluetooth.
///
/// Why this exists: the BLE path in `sync_manager.dart` is a live conversation
/// and needs both phones in the same room. The two masters here are in
/// different places and are rarely online at the same second, so this path is
/// *asynchronous*: each device leaves a small file behind and picks up the
/// other's whenever it next has internet. Neither device waits for the other,
/// and there is still no server to run and nothing to renew.
///
/// The merge itself is untouched — [SyncEngine.computeOutbound] and
/// [SyncEngine.applyIncoming] are reused exactly as the Bluetooth path uses
/// them, so conflict resolution, tombstones, foreign-key remapping and the
/// per-table watermarks behave identically no matter which carrier delivered
/// the rows.
///
/// ## Order of operations (this order is deliberate)
///
/// 1. **Snapshot** our outbound delta in a read-only transaction.
/// 2. **Upload** it.
/// 3. **Download** the peer's bundle.
/// 4. **Apply** it in one write transaction.
///
/// Snapshotting before applying matters: applying advances the watermarks, and
/// the outbound delta is defined as "rows newer than the watermark". If we
/// merged first, our own older-but-unsent rows would fall behind the freshly
/// advanced watermark and would never reach the peer. Uploading before
/// applying matters too: if the upload fails we have changed nothing locally,
/// so the next attempt recomputes exactly the same delta and nothing is lost.
library;

import 'dart:async';

import '../database/tandav_database.dart';
import 'sync_bundle.dart';
import 'sync_codec.dart';
import 'sync_engine.dart';
import 'sync_mailbox.dart';
import 'sync_state.dart';

enum CloudSyncPhase {
  idle,
  connecting, // signing in / restoring the mailbox connection
  uploading, // sending our own changes
  downloading, // fetching the peer's bundle
  applying, // merging received rows
  complete,
  failed,
}

class CloudSyncStatus {
  const CloudSyncStatus(
    this.phase,
    this.message, {
    this.sent = 0,
    this.applied = 0,
    this.skipped = 0,
    this.peerDeviceId,
  });

  final CloudSyncPhase phase;
  final String message;

  /// Rows we uploaded this run.
  final int sent;

  /// Rows merged into the local database this run.
  final int applied;

  /// Rows deliberately not applied (older than ours, or waiting for a parent).
  final int skipped;

  /// The other master's `TANDAV-XXXX` id, once known.
  final String? peerDeviceId;

  bool get isBusy =>
      phase == CloudSyncPhase.connecting ||
      phase == CloudSyncPhase.uploading ||
      phase == CloudSyncPhase.downloading ||
      phase == CloudSyncPhase.applying;
}

/// Outcome of one [CloudSyncManager.syncNow] run.
class CloudSyncResult {
  CloudSyncResult({
    required this.ok,
    required this.message,
    this.sent = 0,
    this.applied = 0,
    this.skipped = 0,
    this.peerDeviceId,
    this.peerBundleAt,
  });

  final bool ok;
  final String message;
  final int sent;
  final int applied;
  final int skipped;
  final String? peerDeviceId;

  /// When the peer wrote the bundle we just read; null when there was none.
  final DateTime? peerBundleAt;
}

class CloudSyncManager {
  CloudSyncManager({
    required this.db,
    required this.state,
    required this.engine,
    required this.mailbox,
  });

  final TandavDatabase db;
  final SyncState state;
  final SyncEngine engine;
  final SyncMailbox mailbox;

  /// `sync_state` key holding the peer id learned through the mailbox. Kept
  /// separate from the Bluetooth `paired_device_id` on purpose: BLE pairing
  /// also stores an HMAC secret, and writing that key without a secret would
  /// leave the Bluetooth handshake unable to authenticate.
  static const kCloudPeerId = 'cloud_peer_device_id';

  /// Last time a mailbox sync completed (ISO-8601 UTC).
  static const kLastCloudSyncAt = 'cloud_last_sync_at';

  /// Account label of the mailbox, cached for display while offline.
  static const kCloudAccount = 'cloud_account';

  final _status = StreamController<CloudSyncStatus>.broadcast();
  Stream<CloudSyncStatus> get status => _status.stream;

  bool _running = false;
  bool get isRunning => _running;

  String get deviceId => state.deviceId;

  Future<String?> get cloudPeerId => state.read(kCloudPeerId);

  Future<String?> get lastCloudSyncAt => state.read(kLastCloudSyncAt);

  Future<String?> get cloudAccount => state.read(kCloudAccount);

  /// Forget the mailbox peer. Local data and remote files are left alone, so
  /// re-connecting later resumes without re-sending everything.
  Future<void> forgetCloudPeer() => state.write(kCloudPeerId, null);

  void dispose() {
    if (!_status.isClosed) _status.close();
  }

  // ---------------------------------------------------------------- connect

  /// Restore a previous connection with no prompts. Call on app start.
  Future<bool> connectSilently() async {
    try {
      final ok = await mailbox.connectSilently();
      if (ok) await _rememberAccount();
      return ok;
    } on MailboxException {
      return false;
    }
  }

  /// Interactive connect (shows the account chooser / permission screen).
  Future<String?> connect() async {
    _emit(CloudSyncPhase.connecting, 'Connecting…');
    try {
      await mailbox.connect();
      await _rememberAccount();
      _emit(
        CloudSyncPhase.idle,
        'Connected as ${mailbox.accountLabel ?? 'your account'}.',
      );
      return null;
    } on MailboxException catch (e) {
      _emit(CloudSyncPhase.failed, e.message);
      return e.message;
    }
  }

  Future<void> disconnect() async {
    await mailbox.disconnect();
    await state.write(kCloudAccount, null);
    _emit(CloudSyncPhase.idle, 'Disconnected.');
  }

  Future<void> _rememberAccount() async {
    final label = mailbox.accountLabel;
    if (label != null && label.isNotEmpty) {
      await state.write(kCloudAccount, label);
    }
  }

  // ------------------------------------------------------------------- sync

  /// Run one full exchange. Safe to call on app open, on resume and from a
  /// manual button — overlapping calls are ignored rather than queued, so a
  /// user mashing Sync cannot start two merges at once.
  Future<CloudSyncResult> syncNow() async {
    if (_running) {
      return CloudSyncResult(ok: false, message: 'A sync is already running.');
    }
    _running = true;
    try {
      return await _run();
    } on MailboxException catch (e) {
      _emit(CloudSyncPhase.failed, e.message);
      return CloudSyncResult(ok: false, message: e.message);
    } on SyncBundleException catch (e) {
      _emit(CloudSyncPhase.failed, e.message);
      return CloudSyncResult(ok: false, message: e.message);
    } catch (e) {
      final msg = 'Sync could not finish: $e';
      _emit(CloudSyncPhase.failed, msg);
      return CloudSyncResult(ok: false, message: msg);
    } finally {
      _running = false;
    }
  }

  Future<CloudSyncResult> _run() async {
    // 0. Make sure the mailbox is usable before touching the database.
    _emit(CloudSyncPhase.connecting, 'Checking your sync account…');
    if (!await mailbox.isConnected()) {
      final restored = await mailbox.connectSilently();
      if (!restored) {
        throw MailboxException(
          'Connect a sync account first (Settings → Device & Sync).',
          isAuthFailure: true,
        );
      }
    }
    await _rememberAccount();

    // 1. Snapshot our outbound delta BEFORE anything is merged, so applying
    //    the peer's rows cannot interleave with the snapshot it is based on.
    final d = await db.open();
    final delta = await d.transaction((txn) => engine.computeOutbound(txn));
    final sent = delta.rowCount;

    // 2. Upload. Done before the merge so a network failure leaves the local
    //    database completely untouched and the retry is identical.
    _emit(
      CloudSyncPhase.uploading,
      sent == 0 ? 'No local changes to send.' : 'Sending $sent changes…',
      sent: sent,
    );
    final bundle = SyncBundle.encode(deviceId: deviceId, delta: delta);
    await mailbox.writeOwn(deviceId, bundle);

    // 2b. The write succeeded, so these rows ARE delivered: the bundle now sits
    //     in the shared account and the peer will read it whenever it next
    //     syncs. Record that before touching the download half, because
    //     whatever happens below cannot un-send a file that is already there.
    if (sent > 0) {
      await d.transaction((txn) => engine.markDeltaSent(txn, delta));
    }

    // 3. Download whatever the other master left behind.
    _emit(CloudSyncPhase.downloading, 'Checking for changes from the other '
        'device…', sent: sent);
    final peers = await mailbox.peerEntries(deviceId);
    if (peers.isEmpty) {
      await state.write(
        kLastCloudSyncAt,
        DateTime.now().toUtc().toIso8601String(),
      );
      final msg = sent == 0
          ? 'Up to date. The other device has not synced yet.'
          : 'Sent $sent changes. The other device has not synced yet.';
      _emit(CloudSyncPhase.complete, msg, sent: sent);
      return CloudSyncResult(ok: true, message: msg, sent: sent);
    }

    final known = await cloudPeerId;
    final chosen = _choosePeer(peers, known);
    if (chosen == null) {
      final ids = peers.map((p) => p.deviceId).join(', ');
      throw MailboxException(
        'This account already has two Tandav devices. '
        'Ignoring $ids — only two masters are supported.',
      );
    }
    final peerId = chosen.deviceId!;

    final contents = await mailbox.read(chosen);
    final incoming = SyncBundle.decode(contents);
    if (incoming.deviceId != peerId) {
      throw SyncBundleException(
        'The sync file was written by ${incoming.deviceId} but is named for '
        '$peerId. Skipping it to avoid mixing up the two devices.',
      );
    }

    // First bundle from this peer adopts it as our pair. The mailbox itself is
    // the trust boundary — only someone signed into the account can write to
    // it — so no separate pairing code is needed here.
    if (known == null || known.isEmpty) {
      await state.write(kCloudPeerId, peerId);
    }

    if (incoming.isEmpty) {
      await state.write(
        kLastCloudSyncAt,
        DateTime.now().toUtc().toIso8601String(),
      );
      final msg = sent == 0
          ? 'Up to date with $peerId.'
          : 'Sent $sent changes. Nothing new from $peerId.';
      _emit(CloudSyncPhase.complete, msg, sent: sent, peerDeviceId: peerId);
      return CloudSyncResult(
        ok: true,
        message: msg,
        sent: sent,
        peerDeviceId: peerId,
        peerBundleAt: incoming.createdAt,
      );
    }

    // 4. Apply every table of the bundle in ONE transaction, so parents and
    //    children land together and a failure rolls the whole thing back.
    _emit(
      CloudSyncPhase.applying,
      'Merging ${incoming.rowCount} changes from $peerId…',
      sent: sent,
      peerDeviceId: peerId,
    );
    final result = await d.transaction(
      (txn) =>
          engine.applyIncoming(txn, incoming.tables, peerDeviceId: peerId),
    );

    final applied = result.totalApplied;
    final skipped =
        _sum(result.conflictsSkipped) + _sum(result.orphansSkipped);
    await state.write(
      kLastCloudSyncAt,
      DateTime.now().toUtc().toIso8601String(),
    );

    final msg = 'Sync complete — $applied changes received from $peerId, '
        '$sent sent.';
    _emit(
      CloudSyncPhase.complete,
      msg,
      sent: sent,
      applied: applied,
      skipped: skipped,
      peerDeviceId: peerId,
    );
    return CloudSyncResult(
      ok: true,
      message: msg,
      sent: sent,
      applied: applied,
      skipped: skipped,
      peerDeviceId: peerId,
      peerBundleAt: incoming.createdAt,
    );
  }

  /// Pick the bundle to apply: the device we already pair with, or — when we
  /// have no pair yet — the only candidate. Two unknown devices is ambiguous
  /// and is refused rather than guessed at.
  MailboxEntry? _choosePeer(List<MailboxEntry> peers, String? known) {
    if (known != null && known.isNotEmpty) {
      for (final p in peers) {
        if (p.deviceId == known) return p;
      }
      return null;
    }
    return peers.length == 1 ? peers.first : null;
  }

  int _sum(Map<String, int> counts) =>
      counts.values.fold(0, (a, b) => a + b);

  /// Fire-and-forget sync for app start and app resume.
  ///
  /// Deliberately silent: it never prompts, never throws and never reports a
  /// failure, because the customer did not ask for it. If there is no internet
  /// or no connected account it simply does nothing and the next resume tries
  /// again. Throttled so flicking in and out of the app does not hammer Drive.
  Future<void> autoSync() async {
    if (_running) return;
    final now = DateTime.now();
    final last = _lastAutoAttempt;
    if (last != null && now.difference(last) < autoSyncCooldown) return;
    _lastAutoAttempt = now;
    try {
      if (!await mailbox.isConnected()) {
        if (!await mailbox.connectSilently()) return;
      }
      await syncNow();
    } catch (_) {
      // Background work must stay invisible when it cannot run.
    }
  }

  /// Shortest gap between two automatic syncs.
  static const autoSyncCooldown = Duration(minutes: 2);

  DateTime? _lastAutoAttempt;

  /// Rows still waiting to be sent, for the "N changes pending" hint on the
  /// sync screen. Read-only; never advances a watermark.
  Future<int> pendingRowCount() async {
    final d = await db.open();
    final delta = await d.transaction((txn) => engine.computeOutbound(txn));
    return delta.rowCount;
  }

  /// Table-by-table breakdown of what is pending, used by the debug view.
  Future<Map<String, int>> pendingByTable() async {
    final d = await db.open();
    final delta = await d.transaction((txn) => engine.computeOutbound(txn));
    final out = <String, int>{};
    for (final table in SyncCodec.applyOrder) {
      final rows = delta.tables[table];
      if (rows != null && rows.isNotEmpty) out[table] = rows.length;
    }
    return out;
  }

  void _emit(
    CloudSyncPhase phase,
    String message, {
    int sent = 0,
    int applied = 0,
    int skipped = 0,
    String? peerDeviceId,
  }) {
    if (_status.isClosed) return;
    _status.add(
      CloudSyncStatus(
        phase,
        message,
        sent: sent,
        applied: applied,
        skipped: skipped,
        peerDeviceId: peerDeviceId,
      ),
    );
  }
}
