import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../sync/bluetooth.dart';
import '../../sync/sync_manager.dart';
import '../../widgets/states.dart';

/// Device & Sync: shows this device's TANDAV id, pairing status, discovered
/// Tandav devices and the live pairing/sync session state, plus actions to
/// pair, sync, unpair and cancel.
class DeviceSyncScreen extends StatefulWidget {
  const DeviceSyncScreen({super.key});

  @override
  State<DeviceSyncScreen> createState() => _DeviceSyncScreenState();
}

class _DeviceSyncScreenState extends State<DeviceSyncScreen> {
  StreamSubscription<TandavSyncStatus>? _sub;
  StreamSubscription<String>? _logSub;
  TandavSyncStatus _last = TandavSyncStatus(SyncPhase.idle, 'Idle');
  final List<String> _bleLog = [];
  String? _deviceId;
  String? _pairedWith;
  String? _lastSyncAt;

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
    _refresh();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _logSub?.cancel();
    super.dispose();
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
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _label('SYNC SESSION'),
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
