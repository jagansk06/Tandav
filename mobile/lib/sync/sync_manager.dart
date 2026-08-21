/// Orchestrates pairing and incremental two-device sync over the [BlesLink].
///
/// Both devices are equal masters. While a session is open BOTH phones
/// advertise their Tandav identity, so there is always a discoverable Tandav
/// device whenever another Tandav device is scanning — it is impossible for
/// both phones to sit in "scan mode" waiting for each other.
///
/// Once a peer is discovered, temporary BLE roles are assigned
/// deterministically from the TANDAV-XXXX ids (never permanently): the device
/// with the lower id becomes the central (scans + connects), the one with the
/// higher id keeps advertising and waits for the connection. The user never
/// sees these roles.
///
/// When pairing: both screens show the same 6-digit verification code derived
/// from the two device ids, and the pairing secret is only exchanged after
/// BOTH humans confirm. An already-paired device answering an unknown peer
/// rejects it immediately.
///
/// Every Bluetooth/platform failure is converted into a user-friendly message
/// ("Bluetooth permission is required…", "No Tandav device found nearby." …)
/// so the app never crashes on a BLE error.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../database/tandav_database.dart';
import 'bluetooth.dart';
import 'protocol.dart';
import 'sync_codec.dart';
import 'sync_engine.dart';
import 'sync_state.dart';

enum SyncPhase {
  idle,
  starting, // preparing bluetooth/advertising
  waitingForPeer, // advertising + scanning, nothing found yet
  found, // one or more Tandav devices discovered
  connecting, // talking to the peer
  pairing, // 6-digit code on both screens, awaiting confirmation
  paired, // shared secret established
  exchanging, // transferring and applying increments
  complete, // everything applied on both sides
  failed,
}

class TandavSyncStatus {
  final SyncPhase phase;
  final String message;
  final String? pairingCode;
  final List<BlePeer> peers;
  final int applied;
  final int skipped;
  TandavSyncStatus(
    this.phase,
    this.message, {
    this.pairingCode,
    this.peers = const [],
    this.applied = 0,
    this.skipped = 0,
  });
}

class SyncManager {
  final TandavDatabase db;
  final SyncState state;
  final SyncEngine engine;
  final BlesLink link;

  final _status = StreamController<TandavSyncStatus>.broadcast();
  Stream<TandavSyncStatus> get status => _status.stream;

  final Random _rng = Random.secure();

  String? _peerId; // TANDAV-XXXX of the other side
  bool _client = false; // true: we initiated the BLE connection
  bool _roleDecided = false;
  bool _pairing = false;
  bool _pairLocalOk = false;
  bool _pairRemoteOk = false;
  bool _secretSent = false;
  String? _serverNonce;
  String? _peerDoneFrom;
  bool _ownDoneSent = false;
  int _applied = 0;
  int _skipped = 0;
  Timer? _sessionTimer;
  Timer? _autoConnectTimer;
  bool _sessionActive = false;

  Future<void> _queue = Future.value();

  SyncManager({required this.db, required this.state, required this.engine})
    : link = BlesLink() {
    link.frames.listen((frame) => _enqueue(() => _handleFrame(frame)));
  }

  // ------------------------------------------------------------- public API

  String get deviceId => state.deviceId;

  /// Start a session. When [pairing] is true we accept a new pair (the two
  /// devices must both be unpaired); otherwise we synchronize with the
  /// already-paired peer. Only one session runs at a time.
  Future<void> startSession({bool pairing = false}) async {
    if (_sessionActive) return;
    _sessionActive = true;
    _pairing = pairing;
    _pairedIdCache = await state.pairedDeviceId;
    _lastPeers = const [];
    _lastEmittedIds = const [];
    _peerId = null;
    _client = false;
    _roleDecided = false;
    _pairLocalOk = false;
    _pairRemoteOk = false;
    _secretSent = false;
    _serverNonce = null;
    _peerDoneFrom = null;
    _ownDoneSent = false;
    _applied = 0;
    _skipped = 0;

    _emit(SyncPhase.starting, 'Checking Bluetooth…');
    _sessionTimer = Timer(const Duration(seconds: 180), () {
      if (!_sessionActive) return;
      _emit(SyncPhase.failed, 'Timed out waiting for the other Tandav device.');
      _teardown();
    });

    // 1. Permissions and Bluetooth state before any BLE operation.
    final readyErr = await link.ensureBluetoothReady();
    if (readyErr != null) {
      _emit(SyncPhase.failed, readyErr);
      _teardown();
      return;
    }

    // 2. Become discoverable: advertising starts before anything else so
    //    another Tandav device has something to find.
    final outcome = await link.startAdvertising('Tandav $deviceId');
    if (!outcome.ok) {
      _emit(SyncPhase.failed, outcome.message);
      _teardown();
      return;
    }

    // 3. Scan for other Tandav devices (only devices advertising the Tandav
    //    BLE service are ever shown).
    _emit(
      SyncPhase.waitingForPeer,
      'Now findable as $deviceId. Looking for other Tandav devices…',
    );
    final scanErr = await link.startDiscovering(_onPeers);
    if (scanErr != null) {
      _emit(SyncPhase.failed, scanErr);
      _teardown();
      return;
    }
    _scheduleAutoConnectCheck();
  }

  /// The human asks to connect to [peer] (the [Connect] button on a
  /// discovered device). The temporary central/peripheral role is assigned
  /// here, so the user never needs to know BLE terminology.
  Future<void> connectToPeer(BlePeer peer) async {
    if (!_sessionActive || _roleDecided) return;
    _decideRoles(peer);
  }

  /// The human confirms the 6-digit pair code shown on this screen.
  Future<void> confirmPairing() async {
    _pairLocalOk = true;
    _maybeSendSecret();
    if (_pairing && _client && _peerId != null) {
      await _send({
        ...envelope(SyncMsgType.pairRequest),
        'deviceId': state.deviceId,
        'code': pairingCode(state.deviceId, _peerId!),
      });
    }
  }

  Future<void> cancelSession() async {
    _sessionActive = false;
    _sessionTimer?.cancel();
    _autoConnectTimer?.cancel();
    await link.disconnectAll();
    await link.stopAdvertising();
    if (!_status.isClosed) {
      _emit(SyncPhase.idle, 'Session cancelled.');
    }
  }

  /// Forget the paired device (local data is never touched).
  Future<void> unpair() async {
    await state.setPairedDeviceId(null);
    await state.setPairingSecret(null);
  }

  void dispose() {
    cancelSession();
    _status.close();
    link.dispose();
  }

  // ------------------------------------------------------------- internals

  void _enqueue(Future<void> Function() op) {
    _queue = _queue.then((_) async {
      try {
        await op();
      } catch (e) {
        _emit(SyncPhase.failed, 'Sync error: $e');
        _teardown();
      }
    });
  }

  /// Discovery callback: a refreshed list of nearby Tandav devices.
  void _onPeers(List<BlePeer> peers) {
    if (!_sessionActive || _roleDecided) return;
    if (peers.isEmpty) {
      // every peer left: forget, so a reappearing device is re-emitted
      _lastEmittedIds = const [];
      return;
    }

    final ids = peers.map((p) => p.id).toList()..sort();
    if (_sameIds(ids, _lastEmittedIds)) return; // no change, nothing to do
    _lastEmittedIds = ids;

    _lastPeers = peers;
    final pairedId = _pairedIdCache;
    final candidates = pairedId == null
        ? peers
        : peers.where((p) => p.deviceId == pairedId).toList();

    if (_pairing) {
      _emit(
        SyncPhase.found,
        peers.length == 1
            ? 'Found ${peers.first.deviceId} nearby.'
            : 'Found ${peers.length} Tandav devices nearby.',
      );
    } else if (candidates.isNotEmpty) {
      _emit(
        SyncPhase.found,
        'Found your paired device ${candidates.first.deviceId}.',
      );
    } else {
      _emit(
        SyncPhase.found,
        'Only other Tandav devices nearby — not your paired device '
        '$pairedId.',
      );
    }
    _scheduleAutoConnectCheck();
  }

  bool _sameIds(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  String? _pairedIdCache;

  /// Auto-connect when exactly one Tandav device is around, so the user does
  /// not have to reason about who scans and who advertises — the roles are
  /// almost always decided automatically.
  void _scheduleAutoConnectCheck() {
    _autoConnectTimer?.cancel();
    if (!_sessionActive || _roleDecided || _client) return;
    final peers = _lastPeers;
    if (peers.length != 1) return;
    _autoConnectTimer = Timer(const Duration(seconds: 3), () {
      if (!_sessionActive || _roleDecided) return;
      _decideRoles(peers.first);
    });
  }

  List<BlePeer> _lastPeers = const [];
  List<String> _lastEmittedIds = const [];

  /// Deterministic temporary role assignment from the two device ids.
  void _decideRoles(BlePeer peer) {
    if (!_sessionActive || _roleDecided) return;
    if (peer.deviceId == state.deviceId) return;
    _roleDecided = true;
    _autoConnectTimer?.cancel();
    _peerId = peer.deviceId;
    _lastPeers = [peer];
    if (state.deviceId.compareTo(peer.deviceId) < 0) {
      _client = true;
      unawaited(_becomeClient(peer));
    } else {
      _client = false;
      link.stopDiscovering();
      _emit(
        SyncPhase.waitingForPeer,
        'Found ${peer.deviceId} — it will connect to this device.',
      );
    }
  }

  Future<void> _becomeClient(BlePeer peer) async {
    link.stopDiscovering();
    _emit(SyncPhase.connecting, 'Connecting to ${peer.deviceId}…');
    final err = await link.connectCentral(peer);
    if (!_sessionActive) return;
    if (err != null) {
      _emit(SyncPhase.failed, err);
      _teardown();
      return;
    }
    _client = true;
    if (_pairing) {
      _emit(
        SyncPhase.pairing,
        'Verify the code below and confirm on BOTH devices.',
        pairingCode: pairingCode(state.deviceId, _peerId!),
      );
    }
    await _sendHello();
    return;
  }

  /// HELLO: identify ourselves (deviceId, platform, protocol version).
  Future<void> _sendHello() async {
    await _send({
      ...envelope(SyncMsgType.hello),
      'deviceId': state.deviceId,
      'platform': _platformName(),
      if (_pairing) 'code': pairingCode(state.deviceId, _peerId!),
    });
  }

  bool _protocolCompatible(Map<String, Object?> msg) {
    final v = protocolVersionOf(msg);
    return v != null && v == syncProtocolVersion;
  }

  String _platformName() {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return 'unknown';
  }

  Future<void> _send(Map<String, Object?> msg) async {
    await link.sendFrame(utf8.encode(jsonEncode(msg)));
  }

  Future<void> _handleFrame(Uint8List frame) async {
    Map<String, Object?> msg;
    try {
      msg = jsonDecode(utf8.decode(frame)) as Map<String, Object?>;
    } catch (_) {
      return;
    }
    switch (typeOf(msg)) {
      case SyncMsgType.hello:
        await _onHello(msg);
      case SyncMsgType.helloAck:
        await _onHelloAck(msg);
      case SyncMsgType.pairRequest:
        await _onPairRequest(msg);
      case SyncMsgType.pairResponse:
        await _onPairResponse(msg);
      case SyncMsgType.auth:
        await _onAuth(msg);
      case SyncMsgType.authOk:
        await _onAuthOk();
      case SyncMsgType.syncRequest:
        await _onSyncRequest();
      case SyncMsgType.syncData:
        await _onSyncData(msg);
      case SyncMsgType.syncDone:
        await _onSyncDone(msg);
      case SyncMsgType.error:
        final reason = msg['reason'] as String? ?? 'unknown error';
        _emit(SyncPhase.failed, 'Peer reported: $reason');
        _teardown();
      default:
        break;
    }
  }

  // ------------------------------------------------------------ peripheral

  Future<void> _onHello(Map<String, Object?> msg) async {
    // Receiving a HELLO means a peer connected to US (we are the designated
    // advertiser) — stop scanning and act as the temporary peripheral.
    if (!_roleDecided) {
      _roleDecided = true;
      _autoConnectTimer?.cancel();
      link.stopDiscovering();
    }
    final remote = (msg['deviceId'] as String?) ?? '';
    if (remote.isEmpty || remote == state.deviceId) {
      await _sendError('invalid_identity');
      return;
    }
    if (!_protocolCompatible(msg)) {
      await _sendError('protocol_mismatch');
      if (_sessionActive) {
        _emit(
          SyncPhase.failed,
          '$remote uses an incompatible Tandav app version.',
        );
        _teardown();
      }
      return;
    }
    final paired = await state.pairedDeviceId;
    if (paired != null && paired != remote) {
      // A third device is trying to join — reject it.
      await _sendError('already_paired');
      return;
    }
    if (_peerId != null && _peerId != remote) {
      await _sendError('busy_pairing');
      return;
    }
    _peerId = remote;
    _client = false;
    if (paired != null) {
      // Normal sync hello from our pair: reply with our identity + nonce.
      _emit(SyncPhase.connecting, '$remote connected — authenticating…');
      _serverNonce = _nonce();
      await _send(
        envelope(SyncMsgType.helloAck, {
          'deviceId': state.deviceId,
          'platform': _platformName(),
          'nonce': _serverNonce,
        }),
      );
      return;
    }
    // First-time pairing: the code must match what we derive too.
    final sentCode = (msg['code'] as String?) ?? '';
    final expected = pairingCode(state.deviceId, remote);
    if (sentCode != expected) {
      await _sendError('bad_code');
      return;
    }
    _emit(
      SyncPhase.pairing,
      'Pair with $remote — verify the code below and confirm on BOTH devices.',
      pairingCode: expected,
    );
    _maybeSendSecret();
  }

  Future<void> _onPairRequest(Map<String, Object?> msg) async {
    final remote = (msg['deviceId'] as String?) ?? '';
    final code = (msg['code'] as String?) ?? '';
    if (remote != _peerId || code != pairingCode(state.deviceId, remote)) {
      await _sendError('bad_code');
      return;
    }
    _pairRemoteOk = true;
    _maybeSendSecret();
  }

  /// The temporary peripheral stores the pairing only after BOTH humans
  /// confirmed (our tap + the pair request that arrives after the other
  /// device's tap), then hands the shared secret to the connector.
  Future<void> _maybeSendSecret() async {
    if (!_pairing || _secretSent || _client) return;
    if (!_pairLocalOk || !_pairRemoteOk || _peerId == null) return;
    _secretSent = true;
    final secret = _nonce();
    _serverNonce = _nonce();
    await state.setPairingSecret(secret);
    await state.setPairedDeviceId(_peerId);
    _emit(
      SyncPhase.paired,
      'Paired with $_peerId.',
      pairingCode: pairingCode(state.deviceId, _peerId!),
    );
    await _send({
      ...envelope(SyncMsgType.pairResponse),
      'secret': secret,
      'nonce': _serverNonce,
    });
  }

  Future<void> _onAuth(Map<String, Object?> msg) async {
    final remote = (msg['deviceId'] as String?) ?? '';
    final token = (msg['token'] as String?) ?? '';
    final secret = await state.pairingSecret;
    final nonce = _serverNonce;
    // The token is bound to the *authenticating* device's id, so verify with
    // the id the peer claimed in the AUTH message.
    if (remote != _peerId ||
        secret == null ||
        nonce == null ||
        token != authToken(remote, secret, nonce)) {
      await _sendError('auth_failed');
      return;
    }
    _emit(SyncPhase.connecting, 'Authenticated $_peerId — syncing…');
    await _send(envelope(SyncMsgType.authOk));
    await _send(envelope(SyncMsgType.syncRequest));
  }

  // --------------------------------------------------------------- central

  Future<void> _onHelloAck(Map<String, Object?> msg) async {
    final remote = (msg['deviceId'] as String?) ?? '';
    if (remote.isNotEmpty && _peerId != null && remote != _peerId) {
      await _sendError('invalid_identity');
      return;
    }
    if (!_protocolCompatible(msg)) {
      if (_sessionActive) {
        _emit(
          SyncPhase.failed,
          '$_peerId uses an incompatible Tandav app version.',
        );
        _teardown();
      }
      return;
    }
    _serverNonce = (msg['nonce'] as String?) ?? '';
    if (_pairing) {
      // Pairing code is already on both screens; the secret flows only after
      // both humans confirm (see confirmPairing/pairRequest).
      return;
    }
    await _sendAuth();
  }

  Future<void> _onPairResponse(Map<String, Object?> msg) async {
    final secret = (msg['secret'] as String?) ?? '';
    _serverNonce = (msg['nonce'] as String?) ?? _nonce();
    if (secret.isEmpty) {
      _emit(SyncPhase.failed, 'Pairing failed on the other device.');
      _teardown();
      return;
    }
    await state.setPairingSecret(secret);
    await state.setPairedDeviceId(_peerId);
    _emit(SyncPhase.paired, 'Paired with $_peerId.');
    await _sendAuth();
  }

  Future<void> _sendAuth() async {
    final secret = await state.pairingSecret;
    if (secret == null) {
      _emit(SyncPhase.failed, 'No pairing secret available.');
      _teardown();
      return;
    }
    await _send({
      ...envelope(SyncMsgType.auth),
      'deviceId': state.deviceId,
      'token': authToken(state.deviceId, secret, _serverNonce ?? _nonce()),
    });
  }

  Future<void> _onAuthOk() async {
    _emit(SyncPhase.exchanging, 'Exchange started…');
    await _send(envelope(SyncMsgType.syncRequest));
  }

  // ------------------------------------------------------------------ exchange

  Future<void> _onSyncRequest() => _sendDelta();

  Future<void> _sendDelta() async {
    final d = await db.open();
    final delta = await d.transaction((txn) => engine.computeOutbound(txn));
    for (final table in SyncCodec.applyOrder) {
      final rows = delta.tables[table];
      if (rows == null || rows.isEmpty) continue;
      await _send({
        ...envelope(SyncMsgType.syncData),
        'table': table,
        'rows': SyncCodec.encodeRowsToJson(table, rows),
      });
    }
    _ownDoneSent = true;
    _emit(
      SyncPhase.exchanging,
      'Sent changes — $_applied applied, $_skipped skipped.',
    );
    await _send({
      ...envelope(SyncMsgType.syncDone),
      'from': state.deviceId,
      'applied': _applied,
      'skipped': _skipped,
    });
    await _maybeComplete();
  }

  Future<void> _onSyncData(Map<String, Object?> msg) async {
    final table = (msg['table'] as String?) ?? '';
    final payload = (msg['rows'] as String?) ?? '';
    if (table.isEmpty || payload.isEmpty) return;
    final (decodedTable, rows) = SyncCodec.decodeRows(payload);
    if (decodedTable != table || rows.isEmpty) return;
    final d = await db.open();
    final result = await d.transaction(
      (txn) =>
          engine.applyIncoming(txn, {table: rows}, peerDeviceId: _peerId ?? ''),
    );
    _applied += result.totalApplied;
    for (final counts in result.conflictsSkipped.values) {
      _skipped += counts;
    }
    for (final counts in result.orphansSkipped.values) {
      _skipped += counts;
    }
    _emit(SyncPhase.exchanging, 'Applied $table — $_applied total.');
  }

  Future<void> _onSyncDone(Map<String, Object?> msg) async {
    _peerDoneFrom = (msg['from'] as String?) ?? '';
    await _maybeComplete();
  }

  Future<void> _maybeComplete() async {
    if (!_ownDoneSent || _peerDoneFrom == null || !_sessionActive) return;
    await state.setLastSyncAt(DateTime.now().toUtc().toIso8601String());
    _emit(
      SyncPhase.complete,
      'Sync complete — $_applied changes applied, $_skipped skipped.',
    );
    _teardown();
  }

  Future<void> _sendError(String reason) =>
      _send(envelope(SyncMsgType.error, {'reason': reason}));

  void _teardown() {
    _sessionTimer?.cancel();
    _sessionTimer = null;
    _autoConnectTimer?.cancel();
    _autoConnectTimer = null;
    _sessionActive = false;
    _ownDoneSent = false;
    _peerDoneFrom = null;
    link.disconnectAll();
    link.stopAdvertising();
  }

  String _nonce() {
    final bytes = List<int>.generate(32, (_) => _rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  void _emit(SyncPhase phase, String message, {String? pairingCode}) {
    if (!_status.isClosed) {
      _status.add(
        TandavSyncStatus(
          phase,
          message,
          pairingCode: pairingCode,
          peers: phase == SyncPhase.found ? _lastPeers : const [],
          applied: _applied,
          skipped: _skipped,
        ),
      );
    }
  }
}
