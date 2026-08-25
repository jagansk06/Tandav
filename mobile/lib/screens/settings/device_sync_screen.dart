import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_role.dart';
import '../../core/format.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../sync/cloud_sync.dart';
import '../../widgets/states.dart';

/// Device & Sync.
///
/// One way to sync: every device signs into the **same Google account** and
/// leaves changes for the others in one small file each. Up to
/// [CloudSyncManager.maxDevices] devices share an account — the two studio
/// owners and the attender — and they can be in different cities, because none
/// of them waits for the others to be online.
///
/// A Bluetooth path used to sit below this as a "same room" fast path. It was
/// removed deliberately — see `SYNC.md`. It could never satisfy the actual
/// requirement (the devices are remote), it doubled the number of code paths
/// into the merge engine that had to be trusted, and Safari has no Web
/// Bluetooth so the iPhone could never have used it anyway.
class DeviceSyncScreen extends StatefulWidget {
  const DeviceSyncScreen({super.key});

  @override
  State<DeviceSyncScreen> createState() => _DeviceSyncScreenState();
}

class _DeviceSyncScreenState extends State<DeviceSyncScreen> {
  StreamSubscription<CloudSyncStatus>? _cloudSub;
  CloudSyncStatus _cloud = const CloudSyncStatus(CloudSyncPhase.idle, '');

  String? _deviceId;
  bool _connected = false;
  String? _account;
  List<String> _peers = const [];
  String? _lastSync;
  int _pending = 0;

  @override
  void initState() {
    super.initState();
    final api = context.read<TandavApi>();
    _deviceId = api.syncState.deviceId;
    _cloudSub = api.cloudSync.status.listen((s) {
      if (mounted) setState(() => _cloud = s);
    });
    _restore();
  }

  @override
  void dispose() {
    _cloudSub?.cancel();
    super.dispose();
  }

  /// Reconnect the Google account without any prompt, so a returning user just
  /// sees "Connected as …" instead of a sign-in screen.
  Future<void> _restore() async {
    final api = context.read<TandavApi>();
    final ok = await api.cloudSync.connectSilently();
    if (mounted) setState(() => _connected = ok);
    await _refresh();
  }

  Future<void> _refresh() async {
    final api = context.read<TandavApi>();
    final account = await api.cloudSync.cloudAccount;
    final peers = await api.cloudSync.knownPeers();
    final last = await api.cloudSync.lastCloudSyncAt;
    final pending = await api.cloudSync.pendingRowCount();
    if (!mounted) return;
    setState(() {
      _account = account;
      _peers = peers;
      _lastSync = last;
      _pending = pending;
    });
  }

  Future<void> _connect() async {
    final api = context.read<TandavApi>();
    final error = await api.cloudSync.connect();
    if (!mounted) return;
    if (error != null) {
      Alert.show(context, error, isError: true);
      setState(() => _connected = false);
      return;
    }
    setState(() => _connected = true);
    await _refresh();
    if (!mounted) return;
    // Connecting is only useful once data starts moving, so do it right away.
    await _syncNow();
  }

  Future<void> _syncNow() async {
    final api = context.read<TandavApi>();
    final result = await api.cloudSync.syncNow();
    await _refresh();
    if (!mounted) return;
    Alert.show(context, result.message, isError: !result.ok);
  }

  Future<void> _disconnect() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TandavColors.surface,
        title: const Text('Disconnect sync?'),
        content: const Text(
          'Changes will stop travelling between your devices until you connect '
          'the account again. Nothing on this device is deleted, and the files '
          'already in Drive are left alone.\n\n'
          'This also forgets which devices you sync with, so reconnecting pairs '
          'with whichever devices sync next and sends each of them a full copy '
          'of this device\'s data.',
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
      _connected = false;
      _account = null;
      _peers = const [];
    });
  }

  /// Clear the remembered peers so replacement devices can be adopted.
  ///
  /// Peers are adopted silently on the first sync and matched by exact id
  /// afterwards, so a phone that was replaced or factory-reset comes back with
  /// a new TANDAV-XXXX and never matches again. Without this button the studio
  /// would be stuck: sync fails, and reinstalling to clear it would wipe the
  /// local database — their only copy.
  ///
  /// It forgets **all** of them rather than offering a per-device choice. The
  /// customer pressing this is being told "sync stopped working", not "device
  /// two of three is stale", and re-adopting a device that is still healthy
  /// costs one larger upload and nothing else. A picker would be a decision they
  /// have no way to get right.
  ///
  /// It also re-offers the whole database, because "already sent" was only ever
  /// true of the devices being forgotten (see [CloudSyncManager.forgetCloudPeer]).
  /// The dialog says so: a customer who is told nothing changed except the
  /// pairing has no reason to expect a longer first sync, and no reason to
  /// realise this is also the fix for "the other device is missing everything".
  Future<void> _forgetPeer() async {
    final named = _peers.isEmpty
        ? 'the other devices'
        : _peers.join(' and ');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TandavColors.surface,
        title: Text(
          _peers.length > 1
              ? 'Forget the other devices?'
              : 'Forget the other device?',
        ),
        content: Text(
          'Tandav will stop waiting for $named and will sync with whichever '
          'devices use this Google account next. Use this if a phone was '
          'replaced, reset, or had Tandav reinstalled.'
          '\n\nThe next sync will then send ALL of this device\'s data, so the '
          'new device gets a complete copy and not just recent changes. That '
          'one sync takes a little longer.'
          '\n\nNothing is deleted on any device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Forget',
              style: TextStyle(color: TandavColors.danger),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final problem = await context.read<TandavApi>().cloudSync.forgetCloudPeer();
    await _refresh();
    if (!mounted) return;
    Alert.show(
      context,
      problem ??
          'Forgotten. The next devices to sync will be paired, and will receive '
              'a full copy of this device\'s data.',
      isError: problem != null,
    );
  }

  /// Re-offer the whole local database, for a peer that lost its data.
  ///
  /// This exists because the files in Drive are **deltas, not backups**. Once
  /// this device has delivered everything, its file holds almost nothing — so a
  /// phone that was wiped, replaced or reinstalled has nowhere to restore from,
  /// and there is no server to fall back on. Clearing the "already sent" marks
  /// makes the next upload a full copy again.
  ///
  /// Worded for someone in a bad situation who does not know the internals: it
  /// says what will happen, says it is safe, and names the other button they
  /// probably also need. It must never read like a repair tool that might make
  /// things worse.
  Future<void> _resendEverything() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TandavColors.surface,
        title: const Text('Send everything again?'),
        content: const Text(
          'Normally Tandav only sends what changed recently. This makes the '
          "next sync send ALL of this device's data instead.\n\n"
          'Use it when another device lost its data — it was replaced, reset, '
          'or had Tandav reinstalled — and needs a fresh copy.\n\n'
          'It is safe to use at any time. The other devices keep anything they '
          'edited more recently and ignore what they already have. The only '
          'difference is that this sync takes a little longer.\n\n'
          'If a device came back with a NEW name, use "Forget the other '
          'device" instead — that does this as well as re-pairing.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Send everything'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final api = context.read<TandavApi>();
    final result = await api.cloudSync.resendEverything();
    await _refresh();
    if (!mounted) return;
    Alert.show(context, result.message, isError: !result.ok);
  }

  @override
  Widget build(BuildContext context) {
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
                const SizedBox(height: 8),
                const Text(
                  'Each device has its own id. It names the file this device '
                  'writes in Drive, so the others can tell your changes apart '
                  'from their own.',
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.45,
                    color: TandavColors.textMuted,
                  ),
                ),
                if (roleBadge != null) ...[
                  const SizedBox(height: 10),
                  // The attender build looks identical otherwise, and "which
                  // app is on this phone?" gets asked over the phone during
                  // support. Saying it here, next to the id, means the answer
                  // and the id are read out together.
                  const Text(
                    'This is the ATTENDER app. It holds attendance and fees '
                    'only — the rest of the studio\'s records never reach this '
                    'phone.',
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.45,
                      fontWeight: FontWeight.w600,
                      color: TandavColors.gold,
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                // Printed, not just declared. `roleStamp` has to survive the
                // tree shaker because `tools/verify-apk.ps1` reads that exact
                // string out of the built APK to tell the owner build from the
                // attender build before either reaches a phone — and a constant
                // nothing references is a constant the compiler drops. Rendering
                // it also makes this screen answer the same question on a phone
                // that is already in someone's hand.
                Text(
                  'Build: $roleLabel · $roleStamp',
                  style: const TextStyle(
                    fontSize: 10.5,
                    height: 1.4,
                    letterSpacing: 0.3,
                    color: TandavColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _syncCard(),
          const SizedBox(height: 16),
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _label('HOW IT WORKS'),
                const SizedBox(height: 8),
                const Text(
                  'Tandav syncs on its own — when you open the app, when you '
                  'come back to it, and every few minutes while it is open. '
                  '"Sync now" is only there for when you do not want to wait.\n\n'
                  'Every device must use the SAME Google account. Two different '
                  'accounts are two separate Drives, and nothing can travel '
                  'between them.\n\n'
                  'Up to three devices can share one account. If a fourth ever '
                  'appears, Tandav says so and names the file to delete rather '
                  'than guessing which one to drop.\n\n'
                  'Everything keeps working with no internet at all. Changes '
                  'queue up on this device and go out the next time it can '
                  'reach Drive.\n\n'
                  'Drive carries CHANGES between your devices — it is not a '
                  'backup of your studio. Keep using Backup & Restore for that. '
                  'If another device ever loses its data, use "Send everything '
                  'again" here to rebuild it from this one.',
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.55,
                    color: TandavColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _syncCard() {
    final busy = _cloud.isBusy;
    final connected = _connected;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                connected ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
                size: 18,
                color:
                    connected ? TandavColors.success : TandavColors.textMuted,
              ),
              const SizedBox(width: 8),
              Expanded(child: _label('AUTOMATIC SYNC — WORKS FROM ANYWHERE')),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            connected
                ? 'Connected as ${_account ?? 'your Google account'}'
                // Signed in before, but with no live permission right now. This
                // is the ordinary state of the iPhone version at every launch:
                // Safari keeps the Google permission in memory only, so it is
                // gone after a reload and a fresh one needs a tap. Saying "Not
                // connected" here would tell a customer whose sync is perfectly
                // healthy that they had lost it.
                : _account != null
                    ? 'Signed in as $_account. Tap below to resume syncing — '
                        'the iPhone version asks for this once each time you '
                        'open the app.'
                    : 'Not connected. Sign in with the SAME Google account on '
                        'every device — changes then travel between them on '
                        'their own.',
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
            _kv(
              _peers.length > 1 ? 'Other devices' : 'Other device',
              _peers.isEmpty
                  ? 'Waiting for their first sync'
                  : _peers.join(', '),
            ),
            _kv('Last sync', _ago(_lastSync)),
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
              // A returning user is resuming, not setting up. `_connect()`
              // already runs a sync straight afterwards, so this stays one tap.
              label: _account != null
                  ? 'Resume syncing'
                  : 'Connect Google account',
              onPressed: busy ? null : _connect,
            )
          else ...[
            GoldButton(
              label: busy ? 'Syncing…' : 'Sync now',
              onPressed: busy ? null : _syncNow,
            ),
            // Shown whenever the account is connected, not only once a peer is
            // known: the device that needs rescuing is often one that has not
            // been adopted yet, because it came back from a wipe with a new id.
            const SizedBox(height: 8),
            Center(
              child: TextButton(
                onPressed: busy ? null : _resendEverything,
                child: const Text(
                  'Send everything again',
                  style: TextStyle(color: TandavColors.textSecondary),
                ),
              ),
            ),
            if (_peers.isNotEmpty) ...[
              const SizedBox(height: 8),
              Center(
                child: TextButton(
                  onPressed: busy ? null : _forgetPeer,
                  child: Text(
                    _peers.length > 1
                        ? 'Forget the other devices'
                        : 'Forget the other device',
                    style: const TextStyle(color: TandavColors.danger),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Center(
              child: TextButton(
                onPressed: busy ? null : _disconnect,
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
