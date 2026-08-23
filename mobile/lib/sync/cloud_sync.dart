/// Two-master sync over a store-and-forward [SyncMailbox] — in practice a
/// shared Google Drive account. This is the app's **only** sync transport.
///
/// Why it is the only one: a Bluetooth LE path used to live in
/// `sync_manager.dart` as a "same room" fast path. It was a live conversation
/// and needed both phones within a few metres of each other, which is not the
/// situation the app is actually sold into — the two masters are in different
/// places and are rarely online at the same second. So this path is
/// *asynchronous*: each device leaves a small file behind and picks up the
/// other's whenever it next has internet. Neither device waits for the other,
/// and there is still no server to run and nothing to renew. The BLE code was
/// deleted rather than kept as a shortcut, because a second route into the
/// merge engine is a second route that has to be trusted with a paying
/// studio's records — and Safari has no Web Bluetooth, so the iPhone could
/// never have used it anyway.
///
/// The merge itself was never carrier-specific — [SyncEngine.computeOutbound]
/// and [SyncEngine.applyIncoming] are the same code the Bluetooth path called,
/// so conflict resolution, tombstones, foreign-key remapping and the per-table
/// watermarks are unchanged by the removal.
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
    this.syncTimeout = const Duration(seconds: 90),
  });

  final TandavDatabase db;
  final SyncState state;
  final SyncEngine engine;
  final SyncMailbox mailbox;

  /// Longest a single exchange may take before it is abandoned.
  ///
  /// This exists because of a UI failure mode, not a network one. The sync
  /// screen disables its button while the last emitted phase is a busy one, so
  /// a Drive call that never returns used to leave the button dead with no
  /// message at all — the only way out being to force-close the app. Every
  /// other exit from [_run] emits a terminal phase, so capping the wait is
  /// enough to guarantee the UI always recovers.
  ///
  /// Note that [Future.timeout] does not cancel the underlying HTTP request; it
  /// only stops us waiting on it. An abandoned run may still finish quietly,
  /// which is safe: the upload overwrites one file in place, and the per-table
  /// `sent` marks only advance after a confirmed write, so the next attempt
  /// recomputes exactly the same delta.
  ///
  /// Injectable so tests can use a few milliseconds instead of a minute and a
  /// half.
  final Duration syncTimeout;

  /// `sync_state` key holding the peer id learned through the mailbox.
  ///
  /// **Do not "simplify" this to `paired_device_id`.** That key belonged to the
  /// deleted Bluetooth transport and may still hold a value in any database
  /// written by an older build. Reusing it would make a fresh Drive pairing
  /// read back a stale BLE peer id — or the reverse — on exactly the devices
  /// that have been in the field longest.
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

  /// Forget the mailbox peer **and** everything we believed it already had.
  ///
  /// Called from the sync screen's "Forget the other device". It must stay
  /// reachable from the UI: [kCloudPeerId] is adopted silently and then matched
  /// by exact id, so without a way to clear it a replaced phone locks sync out
  /// permanently. See [disconnect].
  ///
  /// ## Why it clears the sent marks as well
  ///
  /// `sent.<table>` does not mean "uploaded". It means **"the peer already holds
  /// everything up to this timestamp"** — that is the whole reason
  /// [SyncEngine.markDeltaSent] may only run after a confirmed delivery. The
  /// moment the peer is forgotten that sentence stops being true: the next
  /// device to be adopted is a *different* device, and it holds nothing.
  ///
  /// Leaving the marks behind was a silent data hole rather than an error. The
  /// replacement device would be adopted normally, both devices would report a
  /// successful sync, and the new one would receive only rows edited from that
  /// moment onwards — the studio's entire history stayed invisible, on both
  /// sides, with nothing on screen to suggest anything was wrong. It cost a full
  /// debugging session on real hardware, because the two symptoms it produces
  /// ("the phone is not sending" and "the iPhone is not sending") look like two
  /// separate faults and are one.
  ///
  /// So forgetting a peer implies a full re-offer, and the customer no longer
  /// has to know to press "Send everything again" afterwards. The cost is one
  /// larger upload; [SyncEngine.clearSentMarks] documents why that is always
  /// safe (the peer skips rows it already has and keeps anything it edited more
  /// recently).
  ///
  /// Both writes go in **one transaction**, so there is no instant where the
  /// peer is forgotten but the marks still claim delivery. And `_running` is
  /// held while it happens, for the same reason [resendEverything] holds it: a
  /// resume or the five-minute timer could otherwise slip a sync into the gap
  /// and its `markDeltaSent` — computed from a delta snapshotted before the
  /// clear — would put the marks straight back.
  ///
  /// Returns null on success, or a message to show the user when nothing was
  /// done.
  Future<String?> forgetCloudPeer() async {
    if (_running) {
      return 'A sync is running right now. Wait for it to finish, then try '
          'again.';
    }
    _running = true;
    try {
      final d = await db.open();
      await d.transaction((txn) async {
        await state.writeWithin(txn, kCloudPeerId, null);
        await engine.clearSentMarks(txn);
      });
      return null;
    } finally {
      _running = false;
    }
  }

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

  /// Forget the mailbox account on this device.
  ///
  /// This also clears [kCloudPeerId], which matters more than it looks. The
  /// peer id is adopted automatically on the first bundle we read and is then
  /// matched by *exact* id. If the other phone is replaced, factory-reset or
  /// has the app reinstalled it comes back as a different `TANDAV-XXXX`, stops
  /// matching, and every later sync fails. Clearing it here (and via
  /// [forgetCloudPeer]) is the only escape hatch; without one the alternative
  /// for the customer is reinstalling, which destroys the local database — and
  /// on a local-first app that is their only copy of the data.
  ///
  /// And because it clears the peer id, it must clear the per-table sent marks
  /// too — they are a claim about *that* peer. See [forgetCloudPeer] for the
  /// full argument. Reconnecting therefore re-offers the whole database once,
  /// which is the right trade: the account may well be reconnected against a
  /// second device that is not the one this device was talking to before, and
  /// that case has to be correct without the customer diagnosing it.
  Future<void> disconnect() async {
    await mailbox.disconnect();
    await state.write(kCloudAccount, null);
    final d = await db.open();
    await d.transaction((txn) async {
      await state.writeWithin(txn, kCloudPeerId, null);
      await engine.clearSentMarks(txn);
    });
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
  ///
  /// Always settles within [syncTimeout] and always emits a terminal phase,
  /// even if the carrier hangs. The sync screen derives its button's enabled
  /// state from the last emitted phase, so that guarantee is load-bearing.
  Future<CloudSyncResult> syncNow() async {
    if (_running) {
      return CloudSyncResult(ok: false, message: 'A sync is already running.');
    }
    _running = true;
    try {
      return await _run().timeout(syncTimeout);
    } on TimeoutException {
      const msg = 'Sync timed out. Check your internet connection and try '
          'again — nothing has been lost, and the next sync will send exactly '
          'the same changes.';
      _emit(CloudSyncPhase.failed, msg);
      return CloudSyncResult(ok: false, message: msg);
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
      throw MailboxException(_peerProblem(peers, known));
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
  ///
  /// Returning null covers two completely different situations, which
  /// [_peerProblem] separates before anything reaches the user.
  MailboxEntry? _choosePeer(List<MailboxEntry> peers, String? known) {
    if (known != null && known.isNotEmpty) {
      for (final p in peers) {
        if (p.deviceId == known) return p;
      }
      return null;
    }
    return peers.length == 1 ? peers.first : null;
  }

  /// Explain a null from [_choosePeer] in terms the studio owner can act on.
  ///
  /// The two causes need opposite remedies, and conflating them was itself the
  /// bug: a *missing* partner used to be reported as "this account already has
  /// two devices", which is both untrue and unactionable. Each message now
  /// names the ids involved and states the one thing to do next.
  String _peerProblem(List<MailboxEntry> peers, String? known) {
    if (known != null && known.isNotEmpty) {
      final found = peers.map((p) => p.deviceId).join(', ');
      return 'This device syncs with $known, which has not left anything in '
          'this account. Found $found instead. If the other device was '
          'replaced or reset, tap "Forget the other device" below and sync '
          'again — no data is lost.';
    }
    // Name the files rather than the device ids, and say when each was last
    // written. The remedy is "delete one of these in Drive", and a bare
    // TANDAV-XXXX is not something the customer can point at — the file name is.
    // The near-universal cause is a leftover bundle from tools/fake-peer.html,
    // which is always the oldest of the three, so the dates do the choosing.
    final listed = peers
        .map((p) => '• ${p.name}${_writtenAt(p.modifiedAt)}')
        .join('\n');
    return 'This account holds bundles from more than one other device, and '
        'Tandav syncs two devices in total. Open the "Tandav Sync" folder in '
        'Google Drive and delete the file belonging to the device you no '
        'longer use — usually the oldest one, or one left behind by a test:'
        '\n\n$listed\n\n'
        'Then sync again. Deleting a file there loses nothing: the folder '
        'carries changes in transit, not your data.';
  }

  /// ", last written 3 days ago" — or nothing at all when the mailbox did not
  /// report a time, because an invented date is worse than none on the one
  /// screen someone reads while trying to decide which file to delete.
  String _writtenAt(DateTime? when) {
    if (when == null) return '';
    final age = DateTime.now().toUtc().difference(when);
    if (age.isNegative || age.inMinutes < 60) return ', written just now';
    if (age.inHours < 24) {
      return ', written ${age.inHours} ${age.inHours == 1 ? 'hour' : 'hours'} ago';
    }
    return ', written ${age.inDays} ${age.inDays == 1 ? 'day' : 'days'} ago';
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

  /// Offer this device's **entire** database to the peer, then sync.
  ///
  /// The recovery path for a peer that lost its data: a phone that was wiped,
  /// replaced or reinstalled, or an iPhone whose PWA storage Safari evicted.
  /// Without it such a device can never be restored, because the files in Drive
  /// are *deltas* — once everything has been delivered our file holds almost
  /// nothing, so there is no full copy anywhere for a blank device to read. The
  /// app has no server, so if this button does not exist, nothing does.
  ///
  /// Safe to press at any time. See [SyncEngine.clearSentMarks]: the peer skips
  /// rows it already has and keeps any row it has edited more recently, so the
  /// only cost is a bigger upload.
  ///
  /// Two ordering details matter:
  ///
  /// - The marks are cleared **before** [syncNow], not merged into it, and the
  ///   `_running` flag is held while clearing. Otherwise a resume or the
  ///   five-minute timer could start a sync in the gap, and its `markDeltaSent`
  ///   — which writes marks computed from the delta it snapshotted *before* the
  ///   clear — would put them straight back, leaving a button that reports
  ///   success and did nothing.
  /// - Clearing persists even if the sync then fails (no internet, timeout).
  ///   That is intentional: the customer's request is recorded in the database,
  ///   so whichever sync succeeds next carries the full copy. They do not have
  ///   to remember to come back and press it again.
  Future<CloudSyncResult> resendEverything() async {
    if (_running) {
      return CloudSyncResult(
        ok: false,
        message: 'A sync is already running. Wait for it to finish, then try '
            'again.',
      );
    }
    _running = true;
    try {
      final d = await db.open();
      await d.transaction((txn) => engine.clearSentMarks(txn));
    } finally {
      _running = false;
    }
    final result = await syncNow();
    if (result.ok) return result;
    return CloudSyncResult(
      ok: false,
      message: '${result.message}\n\nThe request is remembered — the next sync '
          'that goes through will still send everything.',
      sent: result.sent,
      applied: result.applied,
      skipped: result.skipped,
      peerDeviceId: result.peerDeviceId,
      peerBundleAt: result.peerBundleAt,
    );
  }

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
