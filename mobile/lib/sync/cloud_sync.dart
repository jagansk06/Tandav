/// Multi-master sync over a store-and-forward [SyncMailbox] — in practice a
/// shared Google Drive account. This is the app's **only** sync transport.
///
/// Up to [CloudSyncManager.maxDevices] devices share one account: the two studio
/// owners and the attender. There is no primary and no server; every device is a
/// master that leaves one file behind and reads everyone else's.
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
/// 1. **List** the other devices' files and settle who we sync with.
/// 2. **Snapshot** our outbound delta in a read-only transaction.
/// 3. **Upload** it.
/// 4. **Record** delivery against each peer.
/// 5. **Apply** each peer's bundle, one write transaction per peer.
///
/// Listing first is what makes three devices work: the delta in step 2 is
/// computed against the *set* of peers, so a device adopted in step 1 is
/// included in the very snapshot that is about to be uploaded. Listing merges
/// nothing, so moving it ahead of the snapshot costs the invariant below
/// nothing.
///
/// Snapshotting before applying matters: applying advances the watermarks, and
/// the outbound delta is defined as "rows newer than the marks". If we merged
/// first, our own older-but-unsent rows would fall behind the freshly advanced
/// marks and would never reach the peers. Uploading before applying matters
/// too: if the upload fails we have changed nothing locally, so the next attempt
/// recomputes exactly the same delta and nothing is lost.
///
/// Recording delivery (step 4) before applying (step 5) is also deliberate — a
/// bundle that fails to decode must not leave us believing our own rows are
/// still pending, because the file we wrote is sitting in the folder either way.
library;

import 'dart:async';

import '../database/tandav_database.dart';
import 'sync_bundle.dart';
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

  /// The `TANDAV-XXXX` id this phase concerns — the peer currently being merged,
  /// or the only peer there is. Null while the run is not about one device in
  /// particular. With three devices the run touches several, so this is a label
  /// for the message, not the full picture; [CloudSyncResult.peerDeviceIds] is.
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
    this.peerDeviceIds = const [],
    this.peerBundleAt,
  });

  final bool ok;
  final String message;
  final int sent;
  final int applied;
  final int skipped;

  /// Every peer whose bundle this run read, in the order they were read.
  final List<String> peerDeviceIds;

  /// The first peer read, kept because most callers and messages want one name.
  String? get peerDeviceId =>
      peerDeviceIds.isEmpty ? null : peerDeviceIds.first;

  /// When the **most recently written** bundle we read was written; null when
  /// there was none. One timestamp for a run that may have read three files is a
  /// simplification, and the newest is the useful one — it answers "is this
  /// account moving at all?", which is what the sync screen shows it for.
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

  /// `sync_state` key holding the peer ids learned through the mailbox, comma
  /// separated.
  ///
  /// **Do not "simplify" this to `paired_device_id`.** That key belonged to the
  /// deleted Bluetooth transport and may still hold a value in any database
  /// written by an older build. Reusing it would make a fresh Drive pairing
  /// read back a stale BLE peer id — or the reverse — on exactly the devices
  /// that have been in the field longest.
  static const kCloudPeerIds = 'cloud_peer_device_ids';

  /// The pre-three-device key, holding a single peer id.
  ///
  /// Still **read** — [knownPeers] folds it into the set — because every
  /// device in the field has one and dropping it would un-pair working studios
  /// on upgrade. Never written; the first write of [kCloudPeerIds] supersedes it
  /// and it is cleared when the peers are forgotten.
  static const kCloudPeerId = 'cloud_peer_device_id';

  /// How many Tandav devices one Google account may hold, this one included.
  ///
  /// Three, because the studio has three people: the two owners and the
  /// attender. The number is a real constraint rather than a preference — each
  /// device leaves one file in the folder and reads everyone else's, so the
  /// exchange grows with every device added, and the cap is what keeps
  /// "something is wrong with sync" a question with a small, checkable answer.
  static const maxDevices = 3;

  /// Peers this device may adopt: everyone else in [maxDevices].
  static const maxPeers = maxDevices - 1;

  /// Last time a mailbox sync completed (ISO-8601 UTC).
  static const kLastCloudSyncAt = 'cloud_last_sync_at';

  /// Account label of the mailbox, cached for display while offline.
  static const kCloudAccount = 'cloud_account';

  final _status = StreamController<CloudSyncStatus>.broadcast();
  Stream<CloudSyncStatus> get status => _status.stream;

  bool _running = false;
  bool get isRunning => _running;

  String get deviceId => state.deviceId;

  /// Every peer this device has adopted, oldest adoption first.
  ///
  /// Folds in the legacy single-peer key so a device upgrading from the
  /// two-device build keeps its pair instead of silently re-adopting it (which
  /// would work, but would also let a stranger's file take the slot first).
  /// De-duplicated because the legacy key and the list will normally name the
  /// same device once both have been written.
  Future<List<String>> knownPeers() async {
    final out = <String>[];
    final raw = await state.read(kCloudPeerIds);
    if (raw != null) {
      for (final part in raw.split(',')) {
        final id = part.trim();
        if (id.isNotEmpty && !out.contains(id)) out.add(id);
      }
    }
    final legacy = await state.read(kCloudPeerId);
    if (legacy != null && legacy.isNotEmpty && !out.contains(legacy)) {
      out.add(legacy);
    }
    return out;
  }

  Future<void> _writePeers(SyncExecutor ex, List<String> peers) =>
      state.writeWithin(ex, kCloudPeerIds, peers.isEmpty ? null : peers.join(','));

  /// The first adopted peer, for screens that show a single "other device".
  ///
  /// Kept so [device_sync_screen] and the older tests do not have to care that
  /// there may now be two. Prefer [knownPeers] in anything new.
  Future<String?> get cloudPeerId async {
    final peers = await knownPeers();
    return peers.isEmpty ? null : peers.first;
  }

  Future<String?> get lastCloudSyncAt => state.read(kLastCloudSyncAt);

  Future<String?> get cloudAccount => state.read(kCloudAccount);

  /// Forget every mailbox peer **and** everything we believed they already had.
  ///
  /// Called from the sync screen's "Forget the other device". It must stay
  /// reachable from the UI: peers are adopted silently and then matched by exact
  /// id, so without a way to clear them a replaced phone locks sync out
  /// permanently. See [disconnect].
  ///
  /// ## Why it clears the sent marks as well
  ///
  /// `sent.<peerId>.<table>` does not mean "uploaded". It means **"that peer
  /// already holds everything up to this timestamp"** — that is the whole reason
  /// [SyncEngine.markDeltaSent] may only run after a confirmed delivery. The
  /// moment a peer is forgotten that sentence stops being true: the next device
  /// adopted is a *different* device, and it holds nothing.
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
  /// It clears marks for **all** peers, not just the forgotten ones, and it does
  /// so by prefix — so marks left by a peer whose id we can no longer name (the
  /// exact situation that sends people to this button) go too. Over-clearing is
  /// free; under-clearing is the data hole above.
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
        await state.writeWithin(txn, kCloudPeerIds, null);
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
  /// This also clears the adopted peer ids, which matters more than it looks. A
  /// peer id is adopted automatically on the first bundle we read and is then
  /// matched by *exact* id. If another phone is replaced, factory-reset or has
  /// the app reinstalled it comes back as a different `TANDAV-XXXX`, stops
  /// matching, and every later sync fails. Clearing them here (and via
  /// [forgetCloudPeer]) is the only escape hatch; without one the alternative
  /// for the customer is reinstalling, which destroys the local database — and
  /// on a local-first app that is their only copy of the data.
  ///
  /// And because it clears the peer ids, it must clear the per-peer sent marks
  /// too — each is a claim about *one* of those peers. See [forgetCloudPeer] for
  /// the full argument. Reconnecting therefore re-offers the whole database once,
  /// which is the right trade: the account may well be reconnected against
  /// devices that are not the ones this device was talking to before, and that
  /// case has to be correct without the customer diagnosing it.
  Future<void> disconnect() async {
    await mailbox.disconnect();
    await state.write(kCloudAccount, null);
    final d = await db.open();
    await d.transaction((txn) async {
      await state.writeWithin(txn, kCloudPeerIds, null);
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

    final d = await db.open();

    // 1. Settle who we are syncing with, BEFORE snapshotting. The delta is
    //    computed against the peer set, so a device adopted here is included in
    //    the very upload that follows. Listing and naming files merges nothing,
    //    so this cannot disturb the snapshot-before-apply invariant.
    _emit(CloudSyncPhase.connecting, 'Looking for your other devices…');
    final present = await mailbox.peerEntries(deviceId);
    final known = await knownPeers();
    final matched = present.where((p) => known.contains(p.deviceId)).toList();
    final strangers =
        present.where((p) => !known.contains(p.deviceId)).toList();
    final slots = maxPeers - known.length;

    // Adopt strangers only when they all fit. Picking a subset would mean
    // guessing which unfamiliar device is the studio's, and the wrong guess
    // burns the last slot silently — refusing is louder and undoable.
    final adopted = strangers.length <= slots
        ? strangers
        : const <MailboxEntry>[];
    final toRead = [...matched, ...adopted];
    if (present.isNotEmpty && toRead.isEmpty) {
      throw MailboxException(_peerProblem(present, known));
    }

    // Adopting from the file name rather than after decoding is deliberate: the
    // peer set has to be fixed before the snapshot below. A file named for one
    // device but written by another is caught at read time and never merged; the
    // only cost is a slot held by a name that does not exist, which "Forget the
    // other device" releases.
    final peerIds = <String>{
      ...known,
      for (final p in adopted) p.deviceId!,
    };
    if (adopted.isNotEmpty) {
      await d.transaction((txn) => _writePeers(txn, peerIds.toList()));
    }

    // 2. Snapshot our outbound delta BEFORE anything is merged, so applying
    //    another device's rows cannot interleave with the snapshot it is based
    //    on. The floor is the *least* caught-up peer's mark: one file serves
    //    every reader, so it has to satisfy whoever is furthest behind.
    final delta =
        await d.transaction((txn) => engine.computeOutbound(txn, peers: peerIds));
    final sent = delta.rowCount;

    // 3. Upload. Done before the merge so a network failure leaves the local
    //    database completely untouched and the retry is identical.
    _emit(
      CloudSyncPhase.uploading,
      sent == 0 ? 'No local changes to send.' : 'Sending $sent changes…',
      sent: sent,
    );
    final bundle = SyncBundle.encode(deviceId: deviceId, delta: delta);
    await mailbox.writeOwn(deviceId, bundle);

    // 3b. The write succeeded, so these rows ARE delivered to every peer: the
    //     bundle now sits in the shared account and each of them will read it
    //     whenever it next syncs. Record that before touching the download half,
    //     because whatever happens below cannot un-send a file that is already
    //     there. With no peers there is nobody to record it against, and
    //     markDeltaSent refuses — see its doc; claiming delivery to nobody used
    //     to lose the first device's entire history.
    if (sent > 0 && peerIds.isNotEmpty) {
      await d.transaction((txn) => engine.markDeltaSent(txn, delta, peers: peerIds));
    }

    // 4. Read and merge each device's bundle, one transaction per device.
    if (toRead.isEmpty) {
      await _stampSynced();
      final msg = sent == 0
          ? 'Up to date. Your other device has not synced yet.'
          : 'Sent $sent changes. Your other device has not synced yet.';
      _emit(CloudSyncPhase.complete, msg, sent: sent);
      return CloudSyncResult(ok: true, message: msg, sent: sent);
    }

    _emit(
      CloudSyncPhase.downloading,
      toRead.length == 1
          ? 'Checking for changes from the other device…'
          : 'Checking for changes from ${toRead.length} other devices…',
      sent: sent,
    );

    final readIds = <String>[];
    var applied = 0;
    var skipped = 0;
    DateTime? newestBundleAt;

    for (final entry in toRead) {
      final peerId = entry.deviceId!;
      final contents = await mailbox.read(entry);
      final incoming = SyncBundle.decode(contents);
      if (incoming.deviceId != peerId) {
        throw SyncBundleException(
          'The sync file was written by ${incoming.deviceId} but is named for '
          '$peerId. Skipping it to avoid mixing up the two devices.',
        );
      }
      readIds.add(peerId);
      final at = incoming.createdAt;
      if (at != null && (newestBundleAt == null || at.isAfter(newestBundleAt))) {
        newestBundleAt = at;
      }
      if (incoming.isEmpty) continue;

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
      applied += result.totalApplied;
      skipped += _sum(result.conflictsSkipped) + _sum(result.orphansSkipped);
    }

    await _stampSynced();

    final who = readIds.length == 1 ? readIds.first : '${readIds.length} devices';
    final msg = applied == 0
        ? (sent == 0 ? 'Up to date with $who.' : 'Sent $sent changes. Nothing new from $who.')
        : 'Sync complete — $applied changes received from $who, $sent sent.';
    _emit(
      CloudSyncPhase.complete,
      msg,
      sent: sent,
      applied: applied,
      skipped: skipped,
      peerDeviceId: readIds.isEmpty ? null : readIds.first,
    );
    return CloudSyncResult(
      ok: true,
      message: msg,
      sent: sent,
      applied: applied,
      skipped: skipped,
      peerDeviceIds: readIds,
      peerBundleAt: newestBundleAt,
    );
  }

  Future<void> _stampSynced() => state.write(
        kLastCloudSyncAt,
        DateTime.now().toUtc().toIso8601String(),
      );

  /// Explain, in terms the studio owner can act on, why none of the files in the
  /// account can be read.
  ///
  /// The two causes need opposite remedies, and conflating them was itself the
  /// bug: a *missing* partner used to be reported as "this account already has
  /// too many devices", which is both untrue and unactionable. Each message
  /// names the ids involved and states the one thing to do next.
  String _peerProblem(List<MailboxEntry> present, List<String> known) {
    if (known.isNotEmpty) {
      final found = present.map((p) => p.deviceId).join(', ');
      final mine = known.join(' and ');
      return 'This device syncs with $mine, which left nothing in this '
          'account. Found $found instead. If a device was replaced or reset, '
          'tap "Forget the other device" below and sync again — no data is '
          'lost.';
    }
    // Name the files rather than the device ids, and say when each was last
    // written. The remedy is "delete one of these in Drive", and a bare
    // TANDAV-XXXX is not something the customer can point at — the file name is.
    // The near-universal cause is a leftover bundle from tools/fake-peer.html,
    // which is always the oldest, so the dates do the choosing.
    final listed = present
        .map((p) => '• ${p.name}${_writtenAt(p.modifiedAt)}')
        .join('\n');
    return 'This account holds bundles from ${present.length} other devices, '
        'and Tandav syncs $maxDevices devices in total. Open the "Tandav Sync" '
        'folder in Google Drive and delete the file belonging to a device you '
        'no longer use — usually the oldest one, or one left behind by a test:'
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
      peerDeviceIds: result.peerDeviceIds,
      peerBundleAt: result.peerBundleAt,
    );
  }

  /// Rows still waiting to be sent, for the "N changes pending" hint on the
  /// sync screen. Read-only; never advances a mark.
  ///
  /// With no peer adopted yet this reports the whole database, because that is
  /// the truth: nothing has been delivered to anybody. The number drops to zero
  /// on the first sync after another device appears.
  Future<int> pendingRowCount() async {
    final d = await db.open();
    final peers = (await knownPeers()).toSet();
    final delta =
        await d.transaction((txn) => engine.computeOutbound(txn, peers: peers));
    return delta.rowCount;
  }

  /// Table-by-table breakdown of what is pending, used by the debug view.
  ///
  /// Iterates the engine's own table list rather than every table there is, so
  /// on the attender build it reports only the tables that build actually holds.
  Future<Map<String, int>> pendingByTable() async {
    final d = await db.open();
    final peers = (await knownPeers()).toSet();
    final delta =
        await d.transaction((txn) => engine.computeOutbound(txn, peers: peers));
    final out = <String, int>{};
    for (final table in engine.tables) {
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
