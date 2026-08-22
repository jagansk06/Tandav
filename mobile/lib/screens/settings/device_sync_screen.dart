import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../sync/bluetooth.dart';
import '../../sync/cloud_sync.dart';
import '../../sync/sync_manager.dart';
import '../../widgets/states.dart';

/// Device & Sync.
///
/// Two ways to sync, shown in the order customers actually use them:
///
/// 1. **Automatic (Google Drive)** — the everyday path. Both devices sign into
///    the same Google account and leave changes there for each other, so the
///    two masters can be in different cities and never need to meet.
/// 2. **Bluetooth** — the fast path for when the two devices happen to be in
///    the same room, and the fallback when there is no internet at all.
///
/// Both routes feed the same merge engine, so it makes no difference to the
/// data which one delivered a change.
class DeviceSyncScreen extends StatefulWidget {
  const DeviceSyncScreen({super.key});

  @override
  State<DeviceSyncScreen> createState() => _DeviceSyncScreenState();
}

class _DeviceSyncScreenState extends State<DeviceSyncScreen> {
  StreamSubscription<TandavSyncStatus>? _sub;
  StreamSubscription<String>? _logSub;
  StreamSubscription<CloudSyncStatus>? _cloudSub;
  TandavSyncStatus _last = TandavSyncStatus(SyncPhase.idle, 'Idle');
  CloudSyncStatus _cloud = const CloudSyncStatus(CloudSyncPhase.idle, '');
  final List<String> _bleLog = [];
  String? _deviceId;
  String? _pairedWith;
  String? _lastSyncAt;

  // Drive sync state.
  bool _driveConnected = false;
  String? _driveAccount;
  String? _drivePeer;
  String? _driveLastSync;
  int _pending = 0;

  @override
  void initState() {
    super.initState();
    final api = context.read<TandavApi>();
    _sub = api.sync.status.listen((s) {
      if (mounted) setState(() => _last = s);
    });
    _logSub = api.sync.link.log.listen((line) {
      if (!mounted) return;
      setState(() {
        _bleLog.add(line);
        if (_bleLog.length > 6) _bleLog.removeAt(0);
      });
    });
    _cloudSub = api.cloudSync.status.listen((s) {
      if (mounted) setState(() => _cloud = s);
    });
    _refresh();
    _restoreDrive();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _logSub?.cancel();
    _cloudSub?.cancel();
    super.dispose();
  }

  /// Reconnect the Drive account without any prompt, so a returning user just
  /// sees "Connected as …" instead of a sign-in screen.
  Future<void> _restoreDrive() async {
    final api = context.read<TandavApi>();
    final ok = await api.cloudSync.connectSilently();
    if (mounted) setState(() => _driveConnected = ok);
    await _refreshDrive();
  }

  Future<void> _refreshDrive() async {
    final api = context.read<TandavApi>();
    final account = await api.cloudSync.cloudAccount;
    final peer = await api.cloudSync.cloudPeerId;
    final last = await api.cloudSync.lastCloudSyncAt;
    final pending = await api.cloudSync.pendingRowCount();
    if (!mounted) return;
    setState(() {
      _driveAccount = account;
      _drivePeer = peer;
      _driveLastSync = last;
      _pending = pending;
    });
  }

  Future<void> _connectDrive() async {
    final api = context.read<TandavApi>();
    final error = await api.cloudSync.connect();
    if (!mounted) return;
    if (error != null) {
      Alert.show(context, error, isError: true);
      setState(() => _driveConnected = false);
      return;
    }
    setState(() => _driveConnected = true);
    await _refreshDrive();
    if (!mounted) return;
    // Connecting is only useful once data starts moving, so do it right away.
    await _driveSyncNow();
  }

  Future<void> _driveSyncNow() async {
    final api = context.read<TandavApi>();
    final result = await api.cloudSync.syncNow();
    await _refreshDrive();
    if (!mounted) return;
    Alert.show(context, result.message, isError: !result.ok);
  }

  Future<void> _disconnectDrive() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TandavColors.surface,
        title: const Text('Disconnect automatic sync?'),
        content: const Text(
          'Changes will stop travelling between the two devices until you '
          'connect the account again. Nothing on this device is deleted, and '
          'the files already in Drive are left alone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Disconnect',
              style: TextStyle(color: TandavColors.danger),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await context.read<TandavApi>().cloudSync.disconnect();
    if (!mounted) return;
    setState(() {
      _driveConnected = false;
      _driveAccount = null;
    });
  }

  Future<void> _refresh() async {
    final api = context.read<TandavApi>();
    final id = api.syncState.deviceId;
    final paired = await api.syncState.pairedDeviceId;
    final lastSync = await api.syncState.lastSyncAt;
    if (mounted) {
      setState(() {
        _deviceId = id;
        _pairedWith = paired;
        _lastSyncAt = lastSync;
      });
    }
  }

  Future<void> _start({required bool pairing}) async {
    final api = context.read<TandavApi>();
    if (pairing) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: TandavColors.surface,
          title: const Text('Pair this device?'),
          content: Text(
            'Make sure the OTHER Tandav device is unpaired and has this '
            'same "Pair a new device" screen open within Bluetooth range. '
            'Both screens will show a 6-digit code.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text(
                'Continue',
                style: TextStyle(color: TandavColors.gold),
              ),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    await api.sync.startSession(pairing: pairing);
  }

  Future<void> _connectTo(BlePeer peer) async {
    final api = context.read<TandavApi>();
    try {
      await api.sync.connectToPeer(peer);
    } catch (e) {
      if (mounted) {
        Alert.show(context, 'Could not start the connection: $e',
            isError: true);
      }
    }
  }

  Future<void> _confirmPair() async {
    final api = context.read<TandavApi>();
    await api.sync.confirmPairing();
    final id = await api.syncState.pairedDeviceId;
    if (mounted) {
      setState(() => _pairedWith = id);
    }
  }

  Future<void> _cancel() async {
    final api = context.read<TandavApi>();
    await api.sync.cancelSession();
    _bleLog.clear();
    _refresh();
  }

  Future<void> _unpair() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TandavColors.surface,
        title: const Text('Unpair this device?'),
        content: const Text(
          'This only forgets the other device on this phone. '
          'All data on BOTH devices is kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Unpair',
              style: TextStyle(color: TandavColors.danger),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    await context.read<TandavApi>().sync.unpair();
    _refresh();
    if (!mounted) return;
    Alert.show(context, 'This device is unpaired');
  }

  @override
  Widget build(BuildContext context) {
    final paired = _pairedWith != null;
    return Scaffold(
      backgroundColor: TandavColors.background,
      appBar: AppBar(title: const Text('Device & Sync')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _label('THIS DEVICE'),
                Text(
                  _deviceId ?? 'TANDAV-····',
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.5,
                    color: TandavColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 12),
                _label('PAIRED WITH'),
                Text(
                  paired ? '$_pairedWith' : 'No device paired yet',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: paired ? TandavColors.gold : TandavColors.textMuted,
                  ),
                ),
                if (_lastSyncAt != null) ...[
                  const SizedBox(height: 12),
                  _label('LAST SYNC'),
                  Text(
                    Fmt.date(_lastSyncAt),
                    style: const TextStyle(
                      fontSize: 14,
                      color: TandavColors.textMuted,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          _driveCard(),
          const SizedBox(height: 16),
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _label('BLUETOOTH — WHEN BOTH DEVICES ARE TOGETHER'),
                const SizedBox(height: 8),
                _phaseRow(_last.phase),
                Text(
                  _last.message,
                  style: const TextStyle(
                    fontSize: 13.5,
                    color: TandavColors.textPrimary,
                  ),
                ),
                if (_last.peers.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  ..._last.peers.map(
                    (p) => _peerTile(
                      p,
                      enabled:
                          _last.phase == SyncPhase.found && _pairedWith == null,
                    ),
                  ),
                ],
                if (_last.pairingCode != null &&
                    _last.phase == SyncPhase.pairing) ...[
                  const SizedBox(height: 14),
                  Center(
                    child: Text(
                      _last.pairingCode!,
                      style: const TextStyle(
                        fontSize: 34,
                        letterSpacing: 6,
                        fontWeight: FontWeight.w900,
                        color: TandavColors.gold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Text(
                      'Verify this code is identical on the other device, '
                      'then confirm on BOTH devices.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: TandavColors.textMuted,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  GoldButton(
                    label: 'Confirm pairing code',
                    onPressed: _confirmPair,
                  ),
                ],
                if (_bleLog.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  _label('BLE LOG'),
                  ..._bleLog.map(
                    (l) => Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        l,
                        style: const TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: TandavColors.textMuted,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 20),
          if (_last.phase == SyncPhase.idle ||
              _last.phase == SyncPhase.failed ||
              _last.phase == SyncPhase.complete) ...[
            GoldButton(
              label: paired ? 'Sync with $_pairedWith' : 'Pair a new device',
              onPressed: () => _start(pairing: !paired),
            ),
            const SizedBox(height: 10),
            if (paired)
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => _start(pairing: true),
                  icon: const Icon(Icons.sync_rounded),
                  label: const Text('Pair a different device (re-pair)'),
                ),
              ),
          ] else ...[
            GoldButton(label: 'Cancel session', onPressed: _cancel),
          ],
          if (paired) ...[
            const SizedBox(height: 24),
            Center(
              child: TextButton(
                onPressed: _unpair,
                child: const Text(
                  'Forget this device',
                  style: TextStyle(color: TandavColors.danger),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Automatic sync card — the everyday path, so it sits above Bluetooth.
  Widget _driveCard() {
    final busy = _cloud.isBusy;
    final connected = _driveConnected;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                connected
                    ? Icons.cloud_done_rounded
                    : Icons.cloud_off_rounded,
                size: 18,
                color: connected
                    ? TandavColors.success
                    : TandavColors.textMuted,
              ),
              const SizedBox(width: 8),
              Expanded(child: _label('AUTOMATIC SYNC — WORKS FROM ANYWHERE')),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            connected
                ? 'Connected as ${_driveAccount ?? 'your Google account'}'
                : 'Not connected. Sign in with the SAME Google account on both '
                    'devices — changes then travel between them on their own.',
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: connected ? FontWeight.w600 : FontWeight.w400,
              color: connected
                  ? TandavColors.textPrimary
                  : TandavColors.textMuted,
            ),
          ),
          if (connected) ...[
            const SizedBox(height: 12),
            _kv('Other device', _drivePeer ?? 'Waiting for its first sync'),
            _kv('Last sync', _ago(_driveLastSync)),
            _kv(
              'Waiting to send',
              _pending == 0
                  ? 'Nothing — everything is sent'
                  : '$_pending ${_pending == 1 ? 'change' : 'changes'}',
            ),
          ],
          if (_cloud.message.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                if (busy)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: TandavColors.gold,
                    ),
                  )
                else
                  Icon(
                    _cloud.phase == CloudSyncPhase.failed
                        ? Icons.error_rounded
                        : Icons.check_circle_rounded,
                    size: 16,
                    color: _cloud.phase == CloudSyncPhase.failed
                        ? TandavColors.danger
                        : TandavColors.success,
                  ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _cloud.message,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: TandavColors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 14),
          if (!connected)
            GoldButton(
              label: 'Connect Google account',
              onPressed: busy ? null : _connectDrive,
            )
          else ...[
            GoldButton(
              label: busy ? 'Syncing…' : 'Sync now',
              onPressed: busy ? null : _driveSyncNow,
            ),
            const SizedBox(height: 8),
            Center(
              child: TextButton(
                onPressed: busy ? null : _disconnectDrive,
                child: const Text(
                  'Disconnect account',
                  style: TextStyle(color: TandavColors.textMuted),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _kv(String key, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 118,
          child: Text(
            key,
            style: const TextStyle(
              fontSize: 12.5,
              color: TandavColors.textMuted,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: TandavColors.textPrimary,
            ),
          ),
        ),
      ],
    ),
  );

  /// "Never", "Just now", "12 minutes ago", "Yesterday", "14/08/2026".
  String _ago(String? iso) {
    if (iso == null || iso.isEmpty) return 'Never';
    final when = DateTime.tryParse(iso);
    if (when == null) return Fmt.date(iso);
    final diff = DateTime.now().difference(when.toLocal());
    if (diff.isNegative || diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) {
      return '${diff.inMinutes} ${diff.inMinutes == 1 ? 'minute' : 'minutes'} ago';
    }
    if (diff.inHours < 24) {
      return '${diff.inHours} ${diff.inHours == 1 ? 'hour' : 'hours'} ago';
    }
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inDays < 7) return '${diff.inDays} days ago';
    return Fmt.date(iso);
  }

  Widget _peerTile(BlePeer peer, {required bool enabled}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: TandavColors.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: TandavColors.surfaceLight),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.smartphone_rounded,
            color: TandavColors.gold,
            size: 26,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  peer.deviceId,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: TandavColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${peer.platform} · ${peer.isNearby ? 'Nearby' : 'In range'}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: TandavColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          if (enabled)
            OutlinedButton(
              onPressed: () => _connectTo(peer),
              child: const Text('Connect'),
            ),
        ],
      ),
    );
  }

  Widget _phaseRow(SyncPhase phase) {
    final (icon, color) = switch (phase) {
      SyncPhase.idle => (
        Icons.bluetooth_disabled_rounded,
        TandavColors.textMuted,
      ),
      SyncPhase.starting => (Icons.sync_rounded, TandavColors.gold),
      SyncPhase.waitingForPeer => (
        Icons.bluetooth_searching_rounded,
        TandavColors.gold,
      ),
      SyncPhase.found => (Icons.devices_rounded, TandavColors.gold),
      SyncPhase.pairing => (Icons.pin_rounded, TandavColors.gold),
      SyncPhase.paired => (Icons.handshake_rounded, TandavColors.success),
      SyncPhase.connecting => (
        Icons.bluetooth_connected_rounded,
        TandavColors.gold,
      ),
      SyncPhase.exchanging => (Icons.sync_rounded, TandavColors.gold),
      SyncPhase.complete => (Icons.check_circle_rounded, TandavColors.success),
      SyncPhase.failed => (Icons.error_rounded, TandavColors.danger),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Text(
            _phaseLabel(phase),
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  String _phaseLabel(SyncPhase phase) => switch (phase) {
    SyncPhase.idle => 'Idle',
    SyncPhase.starting => 'Starting',
    SyncPhase.waitingForPeer => 'Searching for the other device',
    SyncPhase.found => 'Device found',
    SyncPhase.pairing => 'Pairing — confirm the code on both devices',
    SyncPhase.paired => 'Paired',
    SyncPhase.connecting => 'Authenticating',
    SyncPhase.exchanging => 'Syncing data',
    SyncPhase.complete => 'Complete',
    SyncPhase.failed => 'Failed',
  };

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 10.5,
        letterSpacing: 1.4,
        fontWeight: FontWeight.w700,
        color: TandavColors.textMuted,
      ),
    ),
  );
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: TandavColors.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: child,
    );
  }
}
